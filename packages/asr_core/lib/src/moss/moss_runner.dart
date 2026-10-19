/// MOSS-Transcribe-Diarize 分段后端：经 audio.cpp CLI 产出带说话人的句级时间轴。
///
/// 移植自 asr_bench 已验证的 `run_moss.py`（K-ON 等 12 集），行为逐项对齐：
/// 1. 整段音频按约 [MossRunner.chunkSeconds]（默认 300 s）在最安静的 400 ms 处
///    切块（[asrQuietCuts]）；
/// 2. 每块写成 16 kHz PCM_16 wav 临时文件，调一次 `audiocpp_cli --task asr
///    --family moss_transcribe_diarize`；
/// 3. 解析 `--text-out` 的原始流 `[s][Sxx]正文[e]`（不用 `--segments-out`：那份
///    丢了说话人标签）为句级 cue：`start = 块起点 + s`，
///    `end = 块起点 + max(e, s + 0.2)`，正文为空的丢弃，说话人记作
///    `<块序号>:<Sxx>`（MOSS 的 Sxx 只在块内有意义，跨块不能当同一个人）；
/// 4. 进程非零退出、stderr 含 `max_tokens`、且块长 > [MossRunner.splitMinSeconds]
///    （默认 40 s）：这是解码陷入重复循环撞到输出上限，在块内最安静处二分
///    （search = 块长 / 4）后两半重跑；其它错误抛 [MossRunException]，带 stderr
///    尾部；
/// 5. 结果按 start 排序（稳定）。
///
/// 空音频（0 个样本）直接返回空结果，不起 CLI——一个只有 44 字节头的 wav 喂给
/// CLI 只会失败。
///
/// 后端与设备：不传 [MossRunner.backend] 时按清单取这个平台实际发布了 CLI 的
/// 后端（[defaultMossBackendFor]：Windows = cuda、Linux = vulkan）；要结合显卡
/// 探测选，用 [chooseMossBackend]，或直接 [MossRunner.forRuntime] 跟着已下载的
/// 运行库走。CUDA 后端且不传 [MossRunner.device] 时，第一次真要起 CLI 前跑一次
/// `--list-devices`，选计算能力达标的卡显式传 `--device`
/// （[selectMossCudaDevice]），与 [judgeMossCudaAvailability] 判可用的口径一致；
/// 一张都不达标抛 [MossRunException]。
///
/// 进程一律经注入的 [AsrProcessStarter] 启动——宿主（Fushi）要把它登记进自己的
/// 子进程表，本包不依赖那一套。
///
/// 续跑：每块的结果（包括「这块要二分」的决定）缓存到调用方给的工作目录，键是
/// 块的样本区间，并带一个指纹（模型文件、请求参数、该块 PCM 的摘要）；指纹不符
/// 的缓存当作没有。临时 wav / txt / seg 用完即删。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/moss/asr_quiet_cuts.dart';
import 'package:fushi_asr_core/src/moss/audiocpp_manifest.dart';
import 'package:fushi_asr_core/src/moss/audiocpp_store.dart';
import 'package:fushi_asr_core/src/moss/nvidia_gpu_probe.dart';
import 'package:fushi_asr_core/src/util/asr_process.dart';

/// audio.cpp 里 MOSS 的 family 名。
const String kMossAudioCppFamily = 'moss_transcribe_diarize';

/// 缓存格式版本：缓存内容或解析口径变了就 +1，旧缓存自动作废。
const int kMossChunkCacheVersion = 1;

/// 撞上限时报错里出现的标记。
const String kMossMaxTokensMarker = 'max_tokens';

/// 原始流里的一句：`[起点][Sxx]正文[终点]`（秒，相对块起点）。
final RegExp _kMossRawCue = RegExp(
  r'\[(\d+(?:\.\d+)?)\]\[(S\d+)\](.*?)\[(\d+(?:\.\d+)?)\]',
  dotAll: true,
);

/// 原始流里解析出的一句（块内相对时间）。
class MossRawCue {
  const MossRawCue({
    required this.startSeconds,
    required this.endSeconds,
    required this.label,
    required this.text,
  });

  final double startSeconds;

  /// 原始终点（未做 `max(e, s + 0.2)` 修正）。
  final double endSeconds;

  /// `S01` 之类。
  final String label;

  /// 已去首尾空白，可能为空。
  final String text;

  Map<String, Object?> toJson() => <String, Object?>{
        's': startSeconds,
        'e': endSeconds,
        'label': label,
        'text': text,
      };

  factory MossRawCue.fromJson(Map<String, Object?> json) => MossRawCue(
        startSeconds: (json['s']! as num).toDouble(),
        endSeconds: (json['e']! as num).toDouble(),
        label: json['label']! as String,
        text: json['text']! as String,
      );
}

/// 解析 `--text-out` 的原始流（纯函数）。
List<MossRawCue> parseMossRawTranscript(String raw) => <MossRawCue>[
      for (final RegExpMatch m in _kMossRawCue.allMatches(raw))
        MossRawCue(
          startSeconds: double.parse(m.group(1)!),
          endSeconds: double.parse(m.group(4)!),
          label: m.group(2)!,
          text: m.group(3)!.trim(),
        ),
    ];

/// 一条句级 cue（毫秒，相对整段音频起点）。
class MossCue {
  const MossCue({
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.speaker,
  });

  final int startMs;
  final int endMs;
  final String text;

  /// `<块序号>:<Sxx>`，块序号从 1 起。
  final String speaker;

  Map<String, Object?> toJson() => <String, Object?>{
        'startMs': startMs,
        'endMs': endMs,
        'text': text,
        'speaker': speaker,
      };

  factory MossCue.fromJson(Map<String, Object?> json) => MossCue(
        startMs: json['startMs']! as int,
        endMs: json['endMs']! as int,
        text: json['text']! as String,
        speaker: json['speaker']! as String,
      );

  @override
  String toString() => 'MossCue($startMs–$endMs $speaker $text)';
}

/// 把一块的原始句换成整段时间轴上的 cue（纯函数，口径见文件头第 3 条）。
List<MossCue> mossCuesFromRaw(
  List<MossRawCue> raw, {
  required double chunkStartSeconds,
  required int chunkOrdinal,
}) =>
    <MossCue>[
      for (final MossRawCue c in raw)
        if (c.text.isNotEmpty)
          MossCue(
            startMs: ((chunkStartSeconds + c.startSeconds) * 1000).round(),
            endMs: ((chunkStartSeconds +
                        math.max(c.endSeconds, c.startSeconds + 0.2)) *
                    1000)
                .round(),
            text: c.text,
            speaker: '$chunkOrdinal:${c.label}',
          ),
    ];

/// 整段的结果。
class MossTranscript {
  const MossTranscript({
    required this.cues,
    required this.chunkEdgesSeconds,
    required this.chunkCount,
    required this.splitCount,
    required this.audioSeconds,
  });

  /// 按 start 稳定排序。
  final List<MossCue> cues;

  /// 初始切块的边界（含 0 与总时长），与原型 `cuts` 字段同义。
  final List<double> chunkEdgesSeconds;

  /// 初始块数（= 边界数 − 1，不含二分出来的）。
  final int chunkCount;

  /// 因撞 `max_tokens` 二分的次数。
  final int splitCount;

  final double audioSeconds;

  Map<String, Object?> toJson() => <String, Object?>{
        'cues': <Object?>[for (final MossCue c in cues) c.toJson()],
        'cuts': chunkEdgesSeconds,
        'chunkCount': chunkCount,
        'splitCount': splitCount,
        'audioSeconds': audioSeconds,
      };
}

/// 进度：已完成的音频秒数 / 总秒数。
class MossProgress {
  const MossProgress({
    required this.processedSeconds,
    required this.totalSeconds,
    required this.completedChunks,
    required this.splitCount,
  });

  final double processedSeconds;
  final double totalSeconds;

  /// 已完成（含命中缓存）的块数，二分出来的半块各算一块。
  final int completedChunks;
  final int splitCount;

  double get fraction =>
      totalSeconds <= 0 ? 1 : (processedSeconds / totalSeconds).clamp(0, 1);
}

/// CLI 失败（不是可二分重跑的那一种）。
class MossRunException implements Exception {
  const MossRunException({
    required this.message,
    required this.exitCode,
    required this.stderrTail,
    required this.chunkStartSeconds,
    required this.chunkEndSeconds,
  });

  final String message;
  final int exitCode;

  /// stderr 末尾（最多 800 字符）。
  final String stderrTail;
  final double chunkStartSeconds;
  final double chunkEndSeconds;

  @override
  String toString() => 'MossRunException($message, exit $exitCode, chunk '
      '${chunkStartSeconds.toStringAsFixed(2)}–'
      '${chunkEndSeconds.toStringAsFixed(2)} s): $stderrTail';
}

/// 16 kHz 单声道 float32 → PCM_16 wav 字节（`×32768` 取整夹紧：由 s16 解出的
/// float 原样还原成同一组整数）。
Uint8List encodePcm16Wav(Float32List samples,
    {int sampleRate = kAsrSampleRate}) {
  final int dataBytes = samples.length * 2;
  final ByteData out = ByteData(44 + dataBytes);
  void ascii(int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  out.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // 单声道
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  out.setUint32(40, dataBytes, Endian.little);
  for (int i = 0; i < samples.length; i++) {
    final int v = (samples[i] * 32768).round().clamp(-32768, 32767);
    out.setInt16(44 + i * 2, v, Endian.little);
  }
  return out.buffer.asUint8List();
}

/// 一块待跑的样本区间。
class _Chunk {
  const _Chunk(this.start, this.end);

  final int start;
  final int end;

  double get startSeconds => start / kAsrSampleRate;
  double get endSeconds => end / kAsrSampleRate;
  double get seconds => (end - start) / kAsrSampleRate;
}

/// 一块的结果：要么句列表，要么「需要二分」。
class _ChunkOutcome {
  const _ChunkOutcome.cues(this.raw) : split = false;
  const _ChunkOutcome.split()
      : raw = const <MossRawCue>[],
        split = true;

  final List<MossRawCue> raw;
  final bool split;
}

/// MOSS 运行器。一次 [run] 处理一段完整音频。
class MossRunner {
  MossRunner({
    required this.cliPath,
    required this.modelPath,
    AudioCppBackend? backend,
    this.threads = 8,
    this.maxTokens = 8192,
    this.chunkSeconds = 300,
    this.splitMinSeconds = 40,
    this.instruct,
    this.device,
    AsrProcessStarter? startProcess,
  })  : backend = backend ?? defaultMossBackendFor(currentAudioCppPlatform()),
        _startProcess = startProcess ?? defaultAsrProcessStarter {
    if (!modelPath.toLowerCase().endsWith('.gguf')) {
      // audio.cpp 按扩展名认格式：不是 .gguf 结尾会被当成别的格式加载失败。
      throw ArgumentError.value(modelPath, 'modelPath', '必须以 .gguf 结尾');
    }
  }

  /// `audiocpp_cli` 可执行文件。
  final String cliPath;

  /// 跟着已下载的运行库走：CLI 取 [AudioCppRuntimeStore.executable]，后端取
  /// 运行库自己的后端（[AudioCppRuntimePack.backend]），两者不会对不上。
  factory MossRunner.forRuntime(
    AudioCppRuntimeStore runtime, {
    required String modelPath,
    int threads = 8,
    int maxTokens = 8192,
    double chunkSeconds = 300,
    double splitMinSeconds = 40,
    String? instruct,
    int? device,
    AsrProcessStarter? startProcess,
  }) =>
      MossRunner(
        cliPath: runtime.executable.path,
        modelPath: modelPath,
        backend: runtime.pack.backend,
        threads: threads,
        maxTokens: maxTokens,
        chunkSeconds: chunkSeconds,
        splitMinSeconds: splitMinSeconds,
        instruct: instruct,
        device: device,
        startProcess: startProcess,
      );

  /// MOSS GGUF 权重。
  final String modelPath;

  /// `--backend`。构造时不传则为 [defaultMossBackendFor] 当前平台的值。
  final AudioCppBackend backend;
  final int threads;

  /// `--request-option max_tokens=`：每块的输出 token 上限。
  final int maxTokens;

  /// 目标块长（秒）。
  final double chunkSeconds;

  /// 撞上限时块长超过它才二分；否则当作真错误抛出。
  final double splitMinSeconds;

  /// 可选 `--instruct`（如带热词提示的转写指令）；null = 模型默认指令。
  final String? instruct;

  /// 可选 `--device`（CLI 后端内的设备序号）。CUDA 后端不传时自动选达标的卡，
  /// 见文件头「后端与设备」；其它后端不传就交给 CLI 默认。
  final int? device;

  final AsrProcessStarter _startProcess;

  /// CUDA 自动选出的设备序号（每个 runner 只探一次）。
  int? _autoCudaDevice;

  /// 跑完整段 [samples]（16 kHz 单声道 float32）。
  ///
  /// [workDir] 放每块缓存与临时文件；同一段音频续跑传同一个目录，已完成的块
  /// 不重跑。[cancellation] 触发时杀掉当前子进程并抛 [AsrCancelledException]。
  Future<MossTranscript> run(
    Float32List samples, {
    required Directory workDir,
    AsrCancellationToken? cancellation,
    void Function(MossProgress progress)? onProgress,
  }) async {
    if (samples.isEmpty) {
      onProgress?.call(const MossProgress(
        processedSeconds: 0,
        totalSeconds: 0,
        completedChunks: 0,
        splitCount: 0,
      ));
      return const MossTranscript(
        cues: <MossCue>[],
        chunkEdgesSeconds: <double>[0],
        chunkCount: 0,
        splitCount: 0,
        audioSeconds: 0,
      );
    }
    await workDir.create(recursive: true);
    final double total = samples.length / kAsrSampleRate;
    final List<double> cuts =
        asrQuietCuts(samples, targetSeconds: chunkSeconds);
    final List<double> edges = <double>[0, ...cuts, total];
    final List<_Chunk> work = <_Chunk>[
      for (int i = 0; i + 1 < edges.length; i++)
        _Chunk(_toSample(edges[i]),
            i + 2 == edges.length ? samples.length : _toSample(edges[i + 1])),
    ];
    final String config = _configFingerprint();

    final List<(int, MossCue)> collected = <(int, MossCue)>[];
    int ordinal = 0;
    int splits = 0;
    int completed = 0;
    double processed = 0;
    onProgress?.call(MossProgress(
      processedSeconds: 0,
      totalSeconds: total,
      completedChunks: 0,
      splitCount: 0,
    ));
    while (work.isNotEmpty) {
      cancellation?.throwIfCancelled();
      final _Chunk chunk = work.removeAt(0);
      ordinal++;
      final Float32List pcm =
          Float32List.sublistView(samples, chunk.start, chunk.end);
      final _ChunkOutcome outcome =
          await _runChunk(chunk, pcm, workDir, config, cancellation);
      if (outcome.split) {
        final _Chunk? halves = _splitPoint(chunk, pcm);
        if (halves == null) {
          // 块长已过 splitMinSeconds 却找不到切点：只可能是参数病态，不能把
          // 这一块静默丢掉。
          throw MossRunException(
            message: '撞上 max_tokens 且无法在块内找到二分点',
            exitCode: -1,
            stderrTail: '',
            chunkStartSeconds: chunk.startSeconds,
            chunkEndSeconds: chunk.endSeconds,
          );
        }
        work.insertAll(0, <_Chunk>[
          _Chunk(chunk.start, halves.start),
          _Chunk(halves.start, chunk.end),
        ]);
        splits++;
        continue;
      }
      for (final MossCue c in mossCuesFromRaw(
        outcome.raw,
        chunkStartSeconds: chunk.startSeconds,
        chunkOrdinal: ordinal,
      )) {
        collected.add((collected.length, c));
      }
      completed++;
      processed += chunk.seconds;
      onProgress?.call(MossProgress(
        processedSeconds: processed,
        totalSeconds: total,
        completedChunks: completed,
        splitCount: splits,
      ));
    }
    // 稳定排序：同一起点保持产出顺序（与原型 Python sort 一致）。
    collected.sort(((int, MossCue) a, (int, MossCue) b) {
      final int byStart = a.$2.startMs.compareTo(b.$2.startMs);
      return byStart != 0 ? byStart : a.$1.compareTo(b.$1);
    });
    return MossTranscript(
      cues: <MossCue>[for (final (int, MossCue) e in collected) e.$2],
      chunkEdgesSeconds: edges,
      chunkCount: edges.length - 1,
      splitCount: splits,
      audioSeconds: total,
    );
  }

  static int _toSample(double seconds) => (seconds * kAsrSampleRate).round();

  /// 块内二分点：最安静处（target = 块长 / 2，search = 块长 / 4）。返回的
  /// `_Chunk.start` 是二分点样本；找不到切点（块病态地短）返回 null。
  _Chunk? _splitPoint(_Chunk chunk, Float32List pcm) {
    final double len = chunk.seconds;
    final List<double> mid = asrQuietCuts(
      pcm,
      targetSeconds: len / 2,
      searchSeconds: len / 4,
    );
    if (mid.isEmpty) return null;
    final int at = chunk.start + _toSample(mid.first);
    if (at <= chunk.start || at >= chunk.end) return null;
    return _Chunk(at, at);
  }

  /// 与结果有关的参数指纹（后端 / 线程数不影响输出，不进指纹）。
  String _configFingerprint() {
    final File model = File(modelPath);
    return jsonEncode(<String, Object?>{
      'v': kMossChunkCacheVersion,
      'model': p.basename(modelPath),
      'modelBytes': model.existsSync() ? model.lengthSync() : -1,
      'maxTokens': maxTokens,
      'instruct': instruct ?? '',
    });
  }

  Future<_ChunkOutcome> _runChunk(
    _Chunk chunk,
    Float32List pcm,
    Directory workDir,
    String config,
    AsrCancellationToken? cancellation,
  ) async {
    final String stem = 'moss_${chunk.start}_${chunk.end}';
    final File cache = File(p.join(workDir.path, '$stem.json'));
    final String fingerprint = _fingerprint(config, pcm);
    final _ChunkOutcome? cached = _readCache(cache, fingerprint);
    if (cached != null) return cached;

    final File wav = File(p.join(workDir.path, '$stem.wav'));
    final File txt = File(p.join(workDir.path, '$stem.txt'));
    final File seg = File(p.join(workDir.path, '$stem.seg.json'));
    final int? deviceArg = await _deviceArgument(cancellation);
    try {
      await wav.writeAsBytes(encodePcm16Wav(pcm), flush: true);
      _deleteIfExists(txt);
      final AsrProcessResult result = await runAsrProcess(
        cliPath,
        <String>[
          '--task',
          'asr',
          '--family',
          kMossAudioCppFamily,
          '--model',
          modelPath,
          '--backend',
          backend.cliValue,
          if (deviceArg != null) ...<String>['--device', '$deviceArg'],
          '--threads',
          '$threads',
          '--audio',
          wav.path,
          '--text-out',
          txt.path,
          '--segments-out',
          seg.path,
          '--request-option',
          'max_tokens=$maxTokens',
          if (instruct != null && instruct!.isNotEmpty) ...<String>[
            '--instruct',
            instruct!,
          ],
        ],
        startProcess: _startProcess,
        cancellation: cancellation,
      );
      final _ChunkOutcome outcome;
      if (result.exitCode != 0) {
        if (result.stderr.contains(kMossMaxTokensMarker) &&
            chunk.seconds > splitMinSeconds) {
          // 解码陷入重复循环撞到输出上限：交给调用方二分重跑。
          outcome = const _ChunkOutcome.split();
        } else {
          throw MossRunException(
            message: 'audiocpp_cli 失败',
            exitCode: result.exitCode,
            stderrTail: _tail(result.stderr, 800),
            chunkStartSeconds: chunk.startSeconds,
            chunkEndSeconds: chunk.endSeconds,
          );
        }
      } else {
        if (!txt.existsSync()) {
          throw MossRunException(
            message: 'audiocpp_cli 退出 0 但没写出 --text-out',
            exitCode: 0,
            stderrTail: _tail(result.stderr, 800),
            chunkStartSeconds: chunk.startSeconds,
            chunkEndSeconds: chunk.endSeconds,
          );
        }
        final String raw = await txt.readAsString();
        outcome = _ChunkOutcome.cues(parseMossRawTranscript(raw));
      }
      await _writeCache(cache, fingerprint, outcome);
      return outcome;
    } finally {
      _deleteIfExists(wav);
      _deleteIfExists(txt);
      _deleteIfExists(seg);
    }
  }

  /// 本次要传的 `--device`：显式给了就用；CUDA 后端没给时经 `--list-devices`
  /// 选达标的卡（结果缓存在 runner 上）；其它后端为 null（CLI 默认）。
  Future<int?> _deviceArgument(AsrCancellationToken? cancellation) async {
    if (device != null) return device;
    if (backend != AudioCppBackend.cuda) return null;
    final int? cached = _autoCudaDevice;
    if (cached != null) return cached;
    final List<AudioCppCudaDevice> devices = await listAudioCppCudaDevices(
      cliPath,
      startProcess: _startProcess,
      cancellation: cancellation,
    );
    final AudioCppCudaDevice? chosen = selectMossCudaDevice(devices);
    if (chosen == null) {
      throw MossRunException(
        message: devices.isEmpty
            ? 'audiocpp_cli --list-devices 没有列出任何 CUDA 设备'
            : 'CUDA 设备计算能力都低于 7.5：${devices.join('、')}',
        exitCode: -1,
        stderrTail: '',
        chunkStartSeconds: 0,
        chunkEndSeconds: 0,
      );
    }
    return _autoCudaDevice = chosen.index;
  }

  /// 块指纹：参数 + 该块 PCM 字节的 sha256（分块喂入，不复制 PCM）。
  static String _fingerprint(String config, Float32List pcm) {
    final _DigestSink sink = _DigestSink();
    final ByteConversionSink input = crypto.sha256.startChunkedConversion(sink);
    input.add(utf8.encode(config));
    input.add(Uint8List.sublistView(pcm));
    input.close();
    return sink.value.toString();
  }

  _ChunkOutcome? _readCache(File cache, String fingerprint) {
    if (!cache.existsSync()) return null;
    try {
      final Object? json = jsonDecode(cache.readAsStringSync());
      if (json is! Map<String, Object?>) return null;
      if (json['fingerprint'] != fingerprint) return null;
      if (json['split'] == true) return const _ChunkOutcome.split();
      final Object? cues = json['cues'];
      if (cues is! List<Object?>) return null;
      return _ChunkOutcome.cues(<MossRawCue>[
        for (final Object? c in cues)
          MossRawCue.fromJson(c! as Map<String, Object?>),
      ]);
    } on Object {
      // 坏缓存（截断、手改、旧格式）：当作没有，重跑这一块。
      return null;
    }
  }

  Future<void> _writeCache(
    File cache,
    String fingerprint,
    _ChunkOutcome outcome,
  ) async {
    final String body = jsonEncode(<String, Object?>{
      'fingerprint': fingerprint,
      'split': outcome.split,
      'cues': <Object?>[for (final MossRawCue c in outcome.raw) c.toJson()],
    });
    // 先写临时名再 rename：中途被杀不留半个缓存。
    final File tmp = File('${cache.path}.part');
    await tmp.writeAsString(body, flush: true);
    await tmp.rename(cache.path);
  }

  static void _deleteIfExists(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // 删不掉的临时文件不影响结果。
    }
  }

  static String _tail(String s, int n) =>
      s.length <= n ? s : s.substring(s.length - n);
}

/// 收 [crypto.sha256] 分块转换结果的 sink。
class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
