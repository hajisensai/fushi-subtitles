/// 有声书 ASR 的 PCM 来源：经 [FfmpegBackend] 把任意音频文件（m4b/mp3/flac/…）
/// 解码成 16 kHz 单声道 float32 块流（[AsrPcmSource] 的 ffmpeg 实现）。
///
/// 设计要点（全部有实测数据支撑，见 `test/asr/asr_pcm_source_test.dart`）：
///
/// * **分块**：每块一次 ffmpeg，解码到临时文件再读回；块之间无重叠、无空洞。这样
///   10 小时的书不会在内存/磁盘里同时存 1 GB 的 PCM，也让上层能边解码边转录。
/// * **定位精度**：单独用输入端 `-ss`（放在 `-i` 前）**不是**样本精确的——mp3 靠 bit
///   reservoir 解码，跳到帧边界后第一帧缺上文，实测每块开头约 570~610 个样本
///   （≈36 ms）失真、峰值误差 4602/32768；AAC(m4b) 每块开头约 200 个样本失真（含
///   `-ss 0`），是 priming / 编辑列表裁剪在寻址后走了不同路径。单独用输出端 `-ss`
///   （放在 `-i` 后）逐样本精确，但要从文件头解码到目标点，10 小时书按 600 s 分块
///   是 O(n²) 的解码量。本实现取两者之长：输入端 `-ss` 粗跳到 **目标前
///   [kAsrPcmSeekPreRollSeconds] 秒**（让解码器有足够上文热身），再用输出端 `-ss`
///   精确裁掉这段预滚。实测 mp3(CBR/VBR/带封面)、m4b 与整段一次性解码逐样本一致
///   （|diff| = 0），仅 m4b **文件末尾**最后 ~240 个样本有 ≤ 12/32768 的差异（AAC 在
///   寻址后 EOF 冲洗的舍入不同，与预滚长度无关），对 ASR 无影响。
/// * **毫秒对齐**：所有 `-ss` / `-t` 以整毫秒表达（16 kHz 下 1 ms = 16 个样本，整数），
///   避免 62.5 µs 一个样本在 ffmpeg 的微秒时间基里被舍入。调用方给的 `startSample`
///   不是 16 的倍数时，向下取整到毫秒去寻址、多要 1 ms、在 Dart 侧丢掉多出的头部并
///   截到整块长度，块边界因此仍逐样本精确。
/// * **尾部余量**：`-t` 限制的是时间戳，不保证重采样后的样本数。MKV 的毫秒时间基
///   可让 AAC 的 300 s 块少 5 个样本；每块多解码 [kAsrPcmDecodeTailMs] ms，再按样本
///   截到目标长度。块起点始终按源文件绝对时间计算，不通过累加短块长度移动时间轴。
/// * **输出容器**：首选 `-f s16le` 裸 PCM。桌面捆绑的最小化 ffmpeg-min 至今
///   （n7.1.5，`third_party/ffmpeg-min/windows/ffmpeg.exe`）**没有** `s16le`/`wav`
///   muxer——`tool/ffmpeg-min/build-ffmpeg-min.sh` 的白名单已补上，但入库二进制要等
///   CI `ffmpeg-min.yml` 重建后另行 vendor。过渡期回退 `-f mov -c:a pcm_s16le`，
///   读回后按 ISO BMFF box 结构取 `mdat` payload（单音轨 pcm_s16le 的 mdat 就是连续
///   PCM，实测与 s16le 直出逐字节一致）。**清理条件：`ffmpeg-min` 重建带 `s16le,wav`
///   并 vendor 入库后，删除 [AsrPcmContainer.mov] 分支与 [extractMovMdatPayload]。**
/// * **能力探测**：`ffmpeg -muxers` / `-h muxer=s16le` 都写 **stdout**，而
///   [FfmpegBackend.run] 只收集 stderr（桌面 CLI 后端 drain 掉 stdout），无法据此判断。
///   故探测走真实工作：第一块先按 s16le 跑，ffmpeg 在打开输出阶段以
///   `Requested output format 's16le' is not known` 失败（stderr，尚未解码、代价可忽略）
///   即切到 mov 并重跑该块；结果缓存在实例上，之后的块与 [decode] 调用不再试探。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'dart:typed_data';
import 'package:meta/meta.dart';
import 'package:fushi_asr_core/src/util/log.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/ffmpeg/ffmpeg_backend.dart';

/// 输入端 `-ss` 的预滚秒数：粗跳到目标前这么多秒，让 mp3 bit reservoir / AAC 重叠加窗
/// 有足够上文热身，再由输出端 `-ss` 精确裁掉。实测 mp3 需 ≥ 1 帧（26 ms）+ 解码延迟，
/// AAC 需 1~2 帧；2 s 是宽裕值，相对 600 s 的块只多解码 0.3%。
const int kAsrPcmSeekPreRollSeconds = 2;

/// 16 kHz 下每毫秒的样本数（整数 16），是「毫秒对齐」策略成立的前提。
const int kAsrPcmSamplesPerMs = kAsrSampleRate ~/ 1000;

/// 覆盖容器时间戳量化及重采样舍入的解码尾部余量；多出的真实 PCM 只用于凑足目标块。
const int kAsrPcmDecodeTailMs = 10;

/// 相邻两块之间容忍的样本级接缝偏差（4 帧 AAC = 4096 样本 ≈ 256 ms）。
///
/// 每块是独立的 ffmpeg 进程、按名义毫秒偏移寻址。章节重排/拼接过的 m4b 在拼接点
/// 常短几百个样本（编码器 padding 被吃掉；实测某卷 2400 s 处短 212 样本 = 13 ms），
/// 严格接续会让整本转不了。这个量级远小于一个音节，下一块仍按名义偏移寻址、不会累积；
/// 超过上限（整块缺几秒）仍按解码故障抛出。
const int kAsrPcmMaxBlockDriftSamples = 4096;

/// 判「0 样本块 = 文件末尾」时允许离探测时长的距离（毫秒）。
///
/// `-ss` 落在最后一帧附近时 ffmpeg 会正常产出空块，那是真 EOF；离末尾还远的空块是
/// 解码故障（音频数据损坏 / 未下载完的文件预分配的全零区 / ffmpeg 内存不足时
/// 正常退出却写空文件），当 EOF 收尾会把整本静默截成残卷（见 [FfmpegAsrPcmSource.decode]）。
const int kAsrPcmEofSlackMs = 1000;

/// 每块 ffmpeg 的超时下限（秒）。
const int kAsrPcmChunkTimeoutFloorSeconds = 60;

/// 同时在跑的 ffmpeg 块数默认值：每 4 个逻辑核一块，1~4。ffmpeg 解一块 300 s
/// 的 mp3 约 170 ms 单线程，4 块并行把 30 分钟的解码从 940 ms 压到 240 ms
/// （2026-09-07 实测）；再多进程只是多占内存（每块 float32 ≈ 19 MB）。
int defaultAsrPcmParallelism() =>
    (Platform.numberOfProcessors ~/ 4).clamp(1, 4);

/// 抛 [AsrPcmDecodeException] 时附带的 ffmpeg 日志尾部长度（真因在日志末尾，见
/// `extractFfmpegFailureReason` 的说明）。
const int kAsrPcmLogTailChars = 500;

/// PCM 块的落盘容器。见文件头「输出容器」。
enum AsrPcmContainer {
  /// `-f s16le`：裸小端 16 位 PCM，读回即样本。
  s16le,

  /// `-f mov -c:a pcm_s16le`：临时兼容层（捆绑 ffmpeg-min 缺 s16le/wav muxer），
  /// 读回后取 `mdat` payload。ffmpeg-min 重建带 `s16le,wav` 后删除。
  mov,
}

/// **纯函数**：ffmpeg 输出打开失败、且原因正是「没有 `s16le` muxer」的判据。
///
/// 匹配 libavformat 的固定文案 `Requested output format 's16le' is not known`
/// （stderr，error 级别，`-loglevel error` 下仍打印）。只认这一条：其它非零退出
/// （输入损坏、无音频流、权限）都不该触发容器切换。
bool isMissingS16leMuxerFailure(FfmpegRunResult result) {
  if (result.returnCode == null || result.returnCode == 0) return false;
  return RegExp(
    "Requested output format 's16le' is not known",
    caseSensitive: false,
  ).hasMatch(result.output);
}

/// **纯函数**：按块长度给宽裕超时——`chunkSeconds × 2 + 30 s`，下限
/// [kAsrPcmChunkTimeoutFloorSeconds]。解码到 PCM 远快于实时（mp3/AAC 百倍以上），
/// 2 倍块长已覆盖冷缓存 + 播放 IO 争用的慢盘。
Duration asrPcmChunkTimeout(int chunkSeconds) {
  final int seconds = math.max(
    kAsrPcmChunkTimeoutFloorSeconds,
    chunkSeconds * 2 + 30,
  );
  return Duration(seconds: seconds);
}

/// **纯函数**：构造解码一块 PCM 的 ffmpeg 参数（无 IO，可单测）。
///
/// * [startMs] 块起点（毫秒，相对文件起点）；[durationMs] 块长（毫秒）。
/// * 输入端 `-ss max(0, startMs - preRoll)`（整秒，`-i` 之前）粗跳；输出端
///   `-ss (startMs - 输入跳点)`（`-i` 之后）精裁——两者都为 0 时省略。
/// * `-map 0:a:0` + `-vn -sn -dn`：只取第一条音轨。很多有声书 mp3/m4b 带封面图
///   （attached_pic 视频流），不排除会被 mov muxer 当视频流封进去（或 s16le muxer
///   直接拒绝多流），三个 `-xn` 兜住没被 `-map` 排除的字幕/数据流。
/// * `-map_chapters -1 -map_metadata -1`：**不要**把输入的章节/元数据复制到输出。
///   ffmpeg 默认复制章节，`-f mov` 输出时章节变成一条 `text` 轨，其样本（章节标题）
///   与 PCM **交错写进同一个 mdat**；[extractMovMdatPayload] 把 mdat 当纯 PCM，标题
///   字节数为奇数的章节就让整块样本错位成白噪声（BUG-2164：無職転生 12/13 卷 m4b
///   十几个章节里奇数字节标题的整章转出来全是「あ」，匹配率 0%）。`-map` 只管流，
///   管不到章节，必须单独关。s16le 裸输出没有容器，天然免疫。
/// * `-ac 1 -ar 16000 -c:a pcm_s16le`：下混单声道、重采样 16 kHz、16 位小端。
/// * `-f s16le` / `-f mov`：见 [AsrPcmContainer]。
List<String> buildAsrPcmChunkArgs({
  required String inputPath,
  required String outputPath,
  required int startMs,
  required int durationMs,
  required AsrPcmContainer container,
  int preRollSeconds = kAsrPcmSeekPreRollSeconds,
}) {
  assert(startMs >= 0 && durationMs > 0);
  final int preRollMs = math.max(0, preRollSeconds) * 1000;
  // 输入端跳点取整秒（预滚本身就是粗跳，整秒最稳），不为负。
  final int inputSeekMs = math.max(0, (startMs - preRollMs) ~/ 1000 * 1000);
  final int outputSeekMs = startMs - inputSeekMs;
  return <String>[
    '-hide_banner',
    '-nostats',
    '-loglevel',
    'error',
    '-y',
    if (inputSeekMs > 0) ...<String>['-ss', _formatMs(inputSeekMs)],
    '-i',
    inputPath,
    if (outputSeekMs > 0) ...<String>['-ss', _formatMs(outputSeekMs)],
    '-t',
    _formatMs(durationMs),
    '-map',
    '0:a:0',
    '-vn',
    '-sn',
    '-dn',
    '-map_chapters',
    '-1',
    '-map_metadata',
    '-1',
    '-ac',
    '1',
    '-ar',
    '$kAsrSampleRate',
    '-c:a',
    'pcm_s16le',
    '-f',
    container == AsrPcmContainer.s16le ? 's16le' : 'mov',
    outputPath,
  ];
}

/// 毫秒 → ffmpeg 时间串（秒，固定 3 位小数，如 `12.345`）。
String _formatMs(int ms) => (ms / 1000).toStringAsFixed(3);

/// 毫秒 → 报错信息里给人看的 `H:MM:SS`。
String _formatClock(int ms) {
  final int total = ms ~/ 1000;
  final String mm = (total ~/ 60 % 60).toString().padLeft(2, '0');
  final String ss = (total % 60).toString().padLeft(2, '0');
  return '${total ~/ 3600}:$mm:$ss';
}

/// **纯函数**：构造 ffprobe 时长探测参数（`format.duration` 以 JSON 写 stdout）。
List<String> buildAsrProbeDurationArgs({required String inputPath}) {
  return <String>[
    '-v',
    'quiet',
    '-print_format',
    'json',
    '-show_entries',
    'format=duration',
    inputPath,
  ];
}

/// **纯函数**：从 `ffprobe -show_entries format=duration -print_format json` 的 stdout
/// 解析时长（毫秒，四舍五入）。缺字段 / 非数字 / 非 JSON / 非正值 → null（不抛）。
int? parseFfprobeDurationMs(String probeStdout) {
  final String trimmed = probeStdout.trim();
  if (trimmed.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final Object? format = decoded['format'];
  if (format is! Map) return null;
  final Object? duration = format['duration'];
  final double? seconds = switch (duration) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s),
    _ => null,
  };
  if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
  return (seconds * 1000).round();
}

/// **纯函数**：从 `ffmpeg -i <file>` 的 stderr 横幅解析 `Duration: HH:MM:SS.xx`（毫秒）。
///
/// 没有 ffprobe 时的时长兜底：截断对账以探测时长为前提，ffprobe 缺失时直接返回 null
/// 会让对账整体静默失效；而 ffmpeg 是解码必需品，能解码就能探出时长。
/// `Duration: N/A` / 解析不出 / 非正值 → null（不抛）。
int? parseFfmpegDurationBannerMs(String ffmpegStderr) {
  final RegExpMatch? m = RegExp(
    r'Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)',
  ).firstMatch(ffmpegStderr);
  if (m == null) return null;
  final int hours = int.parse(m.group(1)!);
  final int minutes = int.parse(m.group(2)!);
  final double seconds = double.parse(m.group(3)!);
  final int ms = ((hours * 3600 + minutes * 60 + seconds) * 1000).round();
  return ms > 0 ? ms : null;
}

/// libavformat 按码率**估算**时长时写进日志的那句话（`estimate_timings`）。
const String kFfmpegDurationEstimatedMarker =
    'Estimating duration from bitrate';

/// **纯函数**：`ffmpeg -i <file>` 的 stderr 是否表明容器时长只是按码率估出来的。
///
/// 没有 Xing/VBRI/Info 头的 VBR MP3 就是这样：ffprobe 拿首帧码率 × 文件大小推时长，
/// 实测一个 220 s 的文件报 431 s。这种时长不能当「文件应有多长」的证据——拿它对账，
/// 完好的文件会在真 EOF 处被判成截断、整本转录失败。
bool isFfmpegDurationEstimated(String ffmpegStderr) =>
    ffmpegStderr.contains(kFfmpegDurationEstimatedMarker);

/// **纯函数**：在 ISO BMFF（QuickTime/MP4）字节流里找第一个 `mdat` box，返回其
/// payload 视图（不拷贝）。
///
/// box 头：32 位大端 size + 4 字节 type。`size == 1` 时紧跟 64 位 `largesize`
/// （movenc 在 mdat 超 4 GB 时改写成这种；它预留的 `wide` 占位 box 就是为此），
/// `size == 0` 表示延伸到文件尾。ffmpeg 的 mov 输出是 `ftyp` `wide` `mdat` … `moov`
/// （moov 在尾部），逐个 box 跳到 mdat 即可；单音轨 pcm_s16le 的 mdat payload 就是
/// 连续的 s16le 样本。找不到 mdat / box 头越界 / size 小于头长 → [FormatException]。
Uint8List extractMovMdatPayload(Uint8List bytes) {
  final ByteData view = ByteData.sublistView(bytes);
  final int length = bytes.length;
  int offset = 0;
  Uint8List? mdat;
  int trackCount = 0;
  bool sawMoov = false;
  bool mdatToEof = false;
  while (offset + 8 <= length) {
    int size = view.getUint32(offset);
    int headerLength = 8;
    final String type = ascii.decode(
      Uint8List.sublistView(bytes, offset + 4, offset + 8),
      allowInvalid: true,
    );
    if (size == 1) {
      if (offset + 16 > length) {
        throw FormatException(
          'truncated largesize box header at offset $offset',
        );
      }
      final int large = view.getUint64(offset + 8);
      // 大于 Dart int 安全范围或超出文件长度的 largesize 都按到文件尾处理不了，直接判坏。
      if (large < 16 || large > length - offset) {
        throw FormatException(
          'largesize $large out of range at offset $offset (file $length)',
        );
      }
      size = large;
      headerLength = 16;
    } else if (size == 0) {
      size = length - offset;
      mdatToEof = type == 'mdat';
    }
    if (size < headerLength) {
      throw FormatException(
        'box "$type" size $size < header at offset $offset',
      );
    }
    if (type == 'mdat') {
      final int end = math.min(offset + size, length);
      mdat = Uint8List.sublistView(bytes, offset + headerLength, end);
      // size==0 的 mdat 延伸到文件尾（不可 seek 的输出），后面不可能再有 moov，
      // 轨数无从校验——按纯 PCM 接受。
      if (mdatToEof) break;
    } else if (type == 'moov') {
      sawMoov = true;
      trackCount = _countMovTracks(
        view,
        offset + headerLength,
        math.min(offset + size, length),
      );
    }
    offset += size;
  }
  if (mdat == null) throw const FormatException('no mdat box found');
  // mdat 是所有轨的样本交错区。多于一条轨（章节 text 轨 / 封面 / 元数据轨）意味着
  // payload 里混着非 PCM 字节——宁可在这里炸掉，也不能把错位的样本当语音喂给模型
  // （BUG-2164）。没有 moov（ffmpeg 被中断、文件截断）同样判坏。
  if (mdatToEof) return mdat;
  // 空 mdat（块起点已在文件尾之外，ffmpeg 一个样本都没写）：没有可被错位的字节，
  // 此时 moov 里也没有 trak，照常返回空 payload 让调用方按 0 样本收尾。
  if (mdat.isEmpty) return mdat;
  if (!sawMoov) {
    throw const FormatException('no moov box found (truncated mov output)');
  }
  if (trackCount != 1) {
    throw FormatException(
      'mov has $trackCount tracks, expected exactly 1 PCM track; '
      'chapter/metadata tracks would interleave into mdat',
    );
  }
  return mdat;
}

/// 数 `moov` 直接子层里的 `trak` 盒。子盒尺寸不合法就停止计数（当前值即结果），
/// 不抛——调用方以「≠ 1」判坏。
int _countMovTracks(ByteData view, int start, int end) {
  int count = 0;
  int offset = start;
  while (offset + 8 <= end) {
    final int size = view.getUint32(offset);
    if (size < 8 || offset + size > end) break;
    final int a = view.getUint8(offset + 4);
    final int b = view.getUint8(offset + 5);
    final int c = view.getUint8(offset + 6);
    final int d = view.getUint8(offset + 7);
    if (a == 0x74 && b == 0x72 && c == 0x61 && d == 0x6B) count++; // 'trak'
    offset += size;
  }
  return count;
}

/// **纯函数**：s16le 小端字节 → float32（`/32768`，范围 [-1, 1)）。奇数尾字节丢弃。
Float32List pcmS16leToFloat32(Uint8List bytes) {
  final int count = bytes.length ~/ 2;
  final Float32List out = Float32List(count);
  // ByteData 视图不要求 2 字节对齐（mdat payload 的偏移未必是偶数），逐样本读。
  final ByteData view = ByteData.sublistView(bytes, 0, count * 2);
  for (int i = 0; i < count; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// [AsrPcmSource] 的 ffmpeg 实现。见文件头设计说明。
class FfmpegAsrPcmSource implements AsrPcmSource {
  /// [backend] 缺省为 [resolveFfmpegBackend]（桌面 CLI / 移动端 ffmpeg-kit，按平台
  /// 分流，惰性取以免构造期就固定后端）；[tempDir] 缺省 [Directory.systemTemp]，每次
  /// [decode] 在其下 `createTemp('fushi_asr_pcm_')`。
  FfmpegAsrPcmSource({
    FfmpegBackend? backend,
    Directory? tempDir,
    this.preRollSeconds = kAsrPcmSeekPreRollSeconds,
    int? parallelism,
  })  : _backend = backend,
        _tempDir = tempDir ?? Directory.systemTemp,
        parallelism = parallelism ?? defaultAsrPcmParallelism() {
    if (this.parallelism < 1) {
      throw ArgumentError.value(parallelism, 'parallelism', '至少 1');
    }
  }

  final FfmpegBackend? _backend;
  final Directory _tempDir;

  /// 输入端预滚秒数（见 [kAsrPcmSeekPreRollSeconds]）。
  final int preRollSeconds;

  /// 同时在跑的 ffmpeg 块数（见 [defaultAsrPcmParallelism]）。
  final int parallelism;

  /// 已探明可用的输出容器；null 表示还没试过（首块按 s16le 试探）。
  AsrPcmContainer? _container;

  /// 本实例探到过的时长（按路径）。转录任务开跑前会经同一实例探一遍，[decode]
  /// 判「空块是不是文件末尾」时直接复用，不再多起一个进程。
  final Map<String, int> _probedMs = <String, int>{};

  /// 按路径缓存「容器时长是不是按码率估的」（见 [isFfmpegDurationEstimated]）。
  final Map<String, bool> _durationEstimated = <String, bool>{};

  /// 时长是估算值、且 [decode] 已经在真 EOF 处收尾的文件：实际解出的长度（毫秒）。
  /// 此后 [probeDurationMs] 报它而不是那个估算值——任务收尾对账、多文件偏移都以它为准。
  final Map<String, int> _decodedLengthMs = <String, int>{};

  FfmpegBackend get _resolvedBackend => _backend ?? resolveFfmpegBackend();

  /// 当前已探明的输出容器（测试断言用；生产代码不需要读）。
  @visibleForTesting
  AsrPcmContainer? get resolvedContainer => _container;

  @override
  Future<int?> probeDurationMs(String audioPath) async {
    if (!File(audioPath).existsSync()) return null;
    final int? decoded = _decodedLengthMs[audioPath];
    if (decoded != null) return decoded;
    final int? ms = await _probe(audioPath);
    if (ms != null) _probedMs[audioPath] = ms;
    return ms;
  }

  Future<int?> _probe(String audioPath) async {
    try {
      final FfmpegRunResult result = await _resolvedBackend.runProbe(
        buildAsrProbeDurationArgs(inputPath: audioPath),
        const Duration(seconds: 30),
      );
      if (result.returnCode != 0) {
        asrLog(
          '[asr-pcm] ffprobe duration failed for "$audioPath": '
          '${result.failureSummary}',
        );
        return null;
      }
      return parseFfprobeDurationMs(result.output);
    } on ProcessException catch (e) {
      // ffprobe 不在（桌面未捆绑且 PATH 没有）：退回 ffmpeg 横幅。只返回 null 会让
      // [decode] 的 EOF 判据与任务收尾的截断对账一起静默失效。
      asrLog(
        '[asr-pcm] ffprobe unavailable: '
        '${describeFfmpegProcessException(e)}; '
        'falling back to the ffmpeg banner',
      );
      return _probeViaFfmpegBanner(audioPath);
    }
  }

  /// `ffmpeg -hide_banner -i <file>`：没有输出文件，退出码非 0 属正常，
  /// `Duration:` 横幅在 stderr（即 [FfmpegRunResult.output]）。任何失败 → null。
  Future<int?> _probeViaFfmpegBanner(String audioPath) async {
    try {
      final FfmpegRunResult result = await _resolvedBackend.run(
        <String>['-hide_banner', '-i', audioPath],
        const Duration(seconds: 30),
      );
      _durationEstimated[audioPath] = isFfmpegDurationEstimated(result.output);
      return parseFfmpegDurationBannerMs(result.output);
    } on ProcessException catch (e) {
      asrLog(
        '[asr-pcm] ffmpeg duration fallback failed: '
        '${describeFfmpegProcessException(e)}',
      );
      return null;
    }
  }

  /// 探测时长是不是按码率估出来的。只在解码比探测时长**提前**结束时才问（正常文件
  /// 不多起进程）；ffprobe 的 JSON 里没有这条信息，要看 `ffmpeg -i` 的日志。
  /// 起不了 ffmpeg 时按「可信」处理：宁可响亮失败，也不把真截断静默放过。
  Future<bool> _isDurationEstimated(String audioPath) async {
    final bool? cached = _durationEstimated[audioPath];
    if (cached != null) return cached;
    bool estimated = false;
    try {
      final FfmpegRunResult result = await _resolvedBackend.run(
        <String>['-hide_banner', '-i', audioPath],
        const Duration(seconds: 30),
      );
      estimated = isFfmpegDurationEstimated(result.output);
    } on ProcessException catch (e) {
      asrLog(
        '[asr-pcm] duration-estimate check failed: '
        '${describeFfmpegProcessException(e)}',
      );
    }
    return _durationEstimated[audioPath] = estimated;
  }

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) async* {
    if (startSample < 0) {
      throw ArgumentError.value(startSample, 'startSample', 'must be >= 0');
    }
    if (chunkSeconds <= 0) {
      throw ArgumentError.value(chunkSeconds, 'chunkSeconds', 'must be > 0');
    }
    if (!File(audioPath).existsSync()) {
      throw AsrPcmDecodeException(audioPath, 'input file does not exist');
    }
    // 文件时长：区分「空块 = 真 EOF」与「空块 = 解码故障」。探不出时退化为旧行为。
    final int? totalMs =
        _probedMs[audioPath] ?? await probeDurationMs(audioPath);
    final Directory work = await _tempDir.createTemp('fushi_asr_pcm_');
    try {
      final int chunkSamples = chunkSeconds * kAsrSampleRate;
      // startSample 不是整毫秒时：寻址向下取整到毫秒，多要 1 ms，丢掉头部多出的样本。
      // 块长是整秒（16 的倍数），所以每块的余数相同。
      final int dropLeading = startSample % kAsrPcmSamplesPerMs;
      final int durationMs =
          chunkSeconds * 1000 + (dropLeading > 0 ? 1 : 0) + kAsrPcmDecodeTailMs;
      // 并行：最多 [parallelism] 块同时在解（每块一个 ffmpeg 进程），按块序出。
      // ffmpeg 解 mp3/aac 是单线程的，30 分钟 6 块串行 940 ms、并行 240 ms
      // （2026-09-07 实测）；消费方每拉一块这里就再补一块，块只在被拉时才前进，
      // 内存最多 parallelism 块。EOF 后多发出的块解出空样本、进程立刻退出。
      final List<Future<Float32List>> inFlight = <Future<Float32List>>[];
      int spawned = 0;
      Future<Float32List> spawn() {
        final int index = spawned++;
        return _decodeBlock(
          audioPath: audioPath,
          workDir: work,
          index: index,
          startMs: (startSample + index * chunkSamples) ~/ kAsrPcmSamplesPerMs,
          durationMs: durationMs,
        );
      }

      int blockStart = startSample;
      int expectedStart = startSample;
      try {
        while (true) {
          while (inFlight.length < parallelism) {
            inFlight.add(spawn());
          }
          final Float32List raw = await inFlight.removeAt(0);
          Float32List samples = raw;
          if (dropLeading > 0) {
            samples = raw.length > dropLeading
                ? Float32List.sublistView(raw, dropLeading)
                : Float32List(0);
          }
          if (samples.length > chunkSamples) {
            samples = Float32List.sublistView(samples, 0, chunkSamples);
          }
          // 契约：某块 0 样本即文件末尾（超出 EOF 的 -ss 让 ffmpeg 正常退出、输出为空）。
          // 但只有离探测时长不远时才是：音频数据损坏、未下载完的文件（预分配的全零区，
          // 实测某 6 小时 m4b 87.5% 是零，前 4 分半之后一个包都解不出）或 ffmpeg 内存
          // 不足时，ffmpeg 同样正常退出、输出为空。当 EOF 收尾 = 任务报完成、产物是
          // 前几分钟的残卷，用户只能看到一个莫名其妙的低匹配率。
          //
          // 例外是时长本身靠不住：没有 Xing/VBRI 头的 VBR MP3，时长按码率估，常比
          // 实际长出几成。那时「提前」的空块就是真 EOF，记下实际长度后正常收尾。
          if (samples.isEmpty) {
            final bool endsEarly = totalMs != null &&
                expectedStart <
                    (totalMs - kAsrPcmEofSlackMs) * kAsrPcmSamplesPerMs;
            if (endsEarly && await _isDurationEstimated(audioPath)) {
              // 估算时长不算证据：实际解出的长度才是这个文件的长度。记下来，任务
              // 收尾对账（经 [probeDurationMs]）与多文件偏移都改用它。
              final int decodedMs = expectedStart ~/ kAsrPcmSamplesPerMs;
              asrLog(
                '[asr-pcm] "$audioPath": container duration ${totalMs}ms is a '
                'bitrate estimate; stream really ends at ${decodedMs}ms',
              );
              _decodedLengthMs[audioPath] = decodedMs;
              _probedMs[audioPath] = decodedMs;
              break;
            }
            if (totalMs == null ||
                blockStart >=
                    (totalMs - kAsrPcmEofSlackMs) * kAsrPcmSamplesPerMs) {
              break;
            }
            throw AsrPcmDecodeException(
              audioPath,
              'audio stops decoding at '
              '${_formatClock(expectedStart ~/ kAsrPcmSamplesPerMs)} of '
              '${_formatClock(totalMs)}: ffmpeg returned no samples for the '
              'block at ${_formatClock(blockStart ~/ kAsrPcmSamplesPerMs)}; the '
              '$kAsrIncompleteAudioMarker (e.g. a download that has not '
              'finished), or ffmpeg ran out of memory',
            );
          }
          // 真 EOF 的最后一块可以不足目标长度。若后面仍有音频，则不能把短块之后
          // 的源音频提前，也不能悄悄补静音掩盖丢失的语音；在 PCM 层报出具体缺口。
          // 例外是 [kAsrPcmMaxBlockDriftSamples] 以内的接缝偏差：逻辑位置跟随实际
          // 解码长度（不补静音、不丢样本），下一块仍按名义偏移寻址，不累积。
          int chunkStart = blockStart;
          if (blockStart != expectedStart) {
            final int gap = blockStart - expectedStart;
            if (gap.abs() > kAsrPcmMaxBlockDriftSamples) {
              throw AsrPcmDecodeException(
                audioPath,
                'ffmpeg produced a short non-final PCM block: '
                'expected next startSample=$expectedStart, actual $blockStart '
                '(gap=$gap samples) around '
                '${_formatClock(expectedStart ~/ kAsrPcmSamplesPerMs)}; the '
                '$kAsrIncompleteAudioMarker',
              );
            }
            asrLog(
              '[asr-pcm] block seam drift of $gap samples at '
              '${blockStart ~/ kAsrPcmSamplesPerMs} ms tolerated',
            );
            chunkStart = expectedStart;
          }
          yield AsrPcmChunk(startSample: chunkStart, samples: samples);
          expectedStart = chunkStart + samples.length;
          blockStart += chunkSamples;
        }
      } finally {
        // 还在跑的块等它们结束再删目录；它们的结果（EOF 之后的空块 / 取消后的
        // 多余块）不要，错误也不算（本流已经结束或已抛过）。
        for (final Future<Float32List> f in inFlight) {
          try {
            await f;
          } catch (_) {
            // 见上。
          }
        }
      }
    } finally {
      // 取消 / 异常 / 正常结束都走这里：块文件读完即删，目录整体兜底清理。
      try {
        if (work.existsSync()) work.deleteSync(recursive: true);
      } catch (e) {
        asrLog('[asr-pcm] failed to clean temp dir ${work.path}: $e');
      }
    }
  }

  /// 解码一块，返回 float32 样本（可能为空 = EOF）。失败抛 [AsrPcmDecodeException]。
  Future<Float32List> _decodeBlock({
    required String audioPath,
    required Directory workDir,
    required int index,
    required int startMs,
    required int durationMs,
  }) async {
    final AsrPcmContainer container = _container ?? AsrPcmContainer.s16le;
    final String ext = container == AsrPcmContainer.s16le ? 'pcm' : 'mov';
    final File output = File(
      '${workDir.path}${Platform.pathSeparator}'
      'chunk_$index.$ext',
    );
    final Duration timeout = asrPcmChunkTimeout((durationMs / 1000).ceil());
    final FfmpegRunResult result;
    try {
      result = await _resolvedBackend.run(
        buildAsrPcmChunkArgs(
          inputPath: audioPath,
          outputPath: output.path,
          startMs: startMs,
          durationMs: durationMs,
          container: container,
          preRollSeconds: preRollSeconds,
        ),
        timeout,
      );
    } on ProcessException catch (e) {
      _deleteQuietly(output);
      throw AsrPcmDecodeException(audioPath, describeFfmpegProcessException(e));
    }
    try {
      if (result.returnCode == null) {
        throw AsrPcmDecodeException(
          audioPath,
          'ffmpeg timed out after ${timeout.inSeconds}s decoding block $index '
          '(startMs=$startMs, durationMs=$durationMs)',
        );
      }
      if (result.returnCode != 0) {
        if (container == AsrPcmContainer.s16le &&
            _container != AsrPcmContainer.s16le &&
            isMissingS16leMuxerFailure(result)) {
          // 临时兼容层（见文件头）：捆绑 ffmpeg-min 没有 s16le muxer → 切 mov 重跑本块。
          // 探明后缓存在实例上；并行时前几块都是按 s16le 起跑的，每块各自重跑一次
          // （`_container` 已被别的块切成 mov 也照样重跑，别把它当成本块的失败）。
          _container = AsrPcmContainer.mov;
          asrLog(
            '[asr-pcm] ffmpeg has no s16le muxer '
            '(executable=${result.executable}); falling back to mov container',
          );
          _deleteQuietly(output);
          return _decodeBlock(
            audioPath: audioPath,
            workDir: workDir,
            index: index,
            startMs: startMs,
            durationMs: durationMs,
          );
        }
        throw AsrPcmDecodeException(
          audioPath,
          'ffmpeg exit ${result.returnCode} decoding block $index '
          '(startMs=$startMs, durationMs=$durationMs, '
          'executable=${result.executable}); log tail: '
          '${_logTail(result.output)}',
        );
      }
      _container ??= container;
      if (!output.existsSync()) {
        throw AsrPcmDecodeException(
          audioPath,
          'ffmpeg exit 0 but produced no output file for block $index '
          '(startMs=$startMs); log tail: ${_logTail(result.output)}',
        );
      }
      final Uint8List bytes = await output.readAsBytes();
      final Uint8List pcm;
      switch (container) {
        case AsrPcmContainer.s16le:
          pcm = bytes;
        case AsrPcmContainer.mov:
          try {
            pcm = extractMovMdatPayload(bytes);
          } on FormatException catch (e) {
            throw AsrPcmDecodeException(
              audioPath,
              'mov fallback output for block $index is not parseable '
              '(${bytes.length} bytes): ${e.message}',
            );
          }
      }
      return pcmS16leToFloat32(pcm);
    } finally {
      _deleteQuietly(output);
    }
  }

  static String _logTail(String output) {
    final String trimmed = output.trim();
    if (trimmed.length <= kAsrPcmLogTailChars) return trimmed;
    return trimmed.substring(trimmed.length - kAsrPcmLogTailChars);
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      asrLog('[asr-pcm] failed to delete ${file.path}: $e');
    }
  }
}
