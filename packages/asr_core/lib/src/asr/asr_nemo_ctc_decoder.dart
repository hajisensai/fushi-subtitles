/// NeMo CTC 解码：NeMo log-mel → FastConformer CTC → 逐帧 argmax → 折叠。给
/// [AsrModelArchitecture.nemoCtc] 包（Parakeet 日语等）。
///
/// 模型 IO（sherpa-onnx / onnx-asr 两家导出一致，2026-10-15 用 onnx 核实）：
///
/// ```text
/// audio_signal[N, 80, T] f32, length[N] i64 -> logprobs[N, ceil(length/8), V]
/// ```
///
/// 时间轴：特征 10 ms/帧，编码器 8 倍下采样 → 输出 80 ms/帧；输出帧数按
/// `ceil(length / 8)` 截（导出不带输出长度；尾部补齐帧不参与 argmax）。
/// 与 [AsrCtcDecoder]（Omnilingual，吃原始波形）共用折叠语义，只是特征与 IO 不同。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_nemo_mel.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart'
    show AsrSegmentDecoder;
import 'package:fushi_asr_core/src/asr/asr_transducer_decoder.dart'
    show AsrBatchFeatures, AsrDecodeStats, AsrEncodedBatch;
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';

/// 编码器时间下采样倍数（FastConformer `subsampling_factor`）。
const int kAsrNemoSubsampling = 8;

/// 输出帧时长（毫秒）：10 ms 特征帧 × 8。
const int kAsrNemoFrameMs = kAsrFrameShiftMs * kAsrNemoSubsampling;

/// GPU 会话一批的行数上限（显存再多也不超过它）。
///
/// 2026-11-13 在 RTX 4070 Ti（CUDA EP）上量 Parakeet 0.6B ja fp32、15 s 窗口：
/// 每行耗时 8 行 15 ms、16 行 15 ms、42 行 17 ms——批再大没有任何吞吐收益，只多占
/// 显存。所以上限取 8，而不是「显存装得下多少就发多少」。
const int kAsrNemoGpuMaxBatchRows = 8;

/// 一秒音频在 GPU 上的激活开销（字节 / 行）。
///
/// FastConformer 的卷积下采样前端先把 `[N, 80, T]` 升到 256 通道、只降一半分辨率，
/// 这一层的激活随 `N × T` 线性增长，是显存的大头。同一次测量（按需增长的 arena）：
/// 8 行 +1639 MiB、16 行 +2870 MiB、42 行 +7534 MiB，即每行（15 s）180～205 MiB
/// ≈ 13.7 MiB/s。取 16 MiB/s 给 ORT 默认的 2 的幂增长 arena 留余量。
const int kAsrNemoGpuBytesPerAudioSecond = 16 * 1024 * 1024;

/// 留给驱动、cuDNN 工作区与本进程其它显存占用的余量。
const int kAsrNemoGpuReserveBytes = 512 * 1024 * 1024;

/// 显存预算未知时一批的音频总长（秒）：4 个 15 s 窗口，峰值约 3.3 GB。
const int kAsrNemoGpuUnknownBudgetAudioSeconds = 60;

/// [AsrNemoCtcDecoder] 跑在 GPU EP 上时算成批上限要用的两个量。
class AsrNemoGpuBatchBudget {
  const AsrNemoGpuBatchBudget({
    required this.weightBytes,
    required this.budgetBytes,
  });

  /// 模型权重的磁盘字节数（`model.onnx` + 外置权重）。
  final int weightBytes;

  /// 本进程的 GPU 显存预算（`OnnxSessionFactory.deviceMemoryBudgetBytes`）；
  /// null = 平台答不上来。
  final int? budgetBytes;
}

/// GPU 上一批最多几行（纯函数，至少 1 行）。
///
/// 为什么必须封顶：任务侧的动态成批预算（`AsrTranscribeJob.batchSize` × 20 s，
/// GPU 默认 640 s）是按 zipformer 调的，只看音频总长、不看显存。Parakeet 的滑窗
/// 恒 15 s，于是一批 42 行、要约 10 GB 显存；6 GB 的卡装不下，NVIDIA 驱动把超出
/// 部分放进共享系统内存，一次 Run 从 0.7 s 变成几十秒到几分钟，整台机器的 GPU
/// 被拖住、界面跟着卡死（Fushi issue #3380）。
///
/// 权重常驻显存按磁盘字节的 9/8 计（实测 2369 MiB 的权重装载后占 2555 MiB）。
int asrNemoGpuBatchRows({
  required int longestSamples,
  required AsrNemoGpuBatchBudget budget,
}) {
  final int seconds = math.max(
    1,
    (longestSamples + kAsrSampleRate - 1) ~/ kAsrSampleRate,
  );
  final int? budgetBytes = budget.budgetBytes;
  final int rows;
  if (budgetBytes == null) {
    rows = kAsrNemoGpuUnknownBudgetAudioSeconds ~/ seconds;
  } else {
    final int usable = budgetBytes -
        (budget.weightBytes + budget.weightBytes ~/ 8) -
        kAsrNemoGpuReserveBytes;
    rows = usable <= 0
        ? 1
        : usable ~/ (kAsrNemoGpuBytesPerAudioSecond * seconds);
  }
  return rows.clamp(1, kAsrNemoGpuMaxBatchRows);
}

class AsrNemoCtcDecoder implements AsrSegmentDecoder {
  AsrNemoCtcDecoder({
    required OnnxSession model,
    required AsrTokenTable tokens,
    AsrNemoMel? mel,
    AsrNemoGpuBatchBudget? gpuBatchBudget,
  })  : _model = model,
        _tokens = tokens,
        _mel = mel ?? AsrNemoMel.slaney80,
        _gpuBatchBudget = gpuBatchBudget {
    if (tokens.blankId < 0) {
      throw ArgumentError.value(tokens, 'tokens', '词表缺少 blank 记号');
    }
  }

  final OnnxSession _model;
  final AsrTokenTable _tokens;
  final AsrNemoMel _mel;

  /// 非 null = 会话在 GPU EP 上，一批的行数按显存封顶（[asrNemoGpuBatchRows]）。
  final AsrNemoGpuBatchBudget? _gpuBatchBudget;

  AsrDecodeStats _stats = const AsrDecodeStats();

  @override
  AsrDecodeStats get stats => _stats;

  /// 动态会话、无静态桶：滑窗的输入长度本身就恒定（15 s），不需要桶来钉形状。
  /// CPU 上不封顶（null，走任务侧的动态预算）；GPU 上按显存封顶。
  @override
  int? batchCapFor(int longestSamples) {
    final AsrNemoGpuBatchBudget? budget = _gpuBatchBudget;
    if (budget == null) return null;
    return asrNemoGpuBatchRows(longestSamples: longestSamples, budget: budget);
  }

  @override
  int? bucketKeyFor(int longestSamples) => null;

  @override
  void warmUp() {}

  @override
  Future<List<AsrDecodedSegment>> decodeBatch(
    List<AsrSpeechSegment> segments,
  ) async {
    if (segments.isEmpty) return <AsrDecodedSegment>[];
    return search(await encode(segments));
  }

  @override
  Future<AsrBatchFeatures> computeFeaturesAsync(
    List<AsrSpeechSegment> segments,
  ) =>
      Future<AsrBatchFeatures>.value(computeFeatures(segments));

  /// 每段一份 mel 主序 `[80, valid]` 特征（[AsrNemoMel.compute]）；
  /// `frameCounts` 记**有效帧数**（喂给 `length`），[AsrBatchFeatures.maxFrames]
  /// 是批内补齐后的总帧数 `1 + L/160`（[AsrNemoMel.frameCount]）。
  @override
  AsrBatchFeatures computeFeatures(List<AsrSpeechSegment> segments) {
    final Stopwatch clock = Stopwatch()..start();
    final List<Float32List> features = <Float32List>[];
    final Int64List valid = Int64List(segments.length);
    int maxFrames = 0;
    int real = 0;
    for (int i = 0; i < segments.length; i++) {
      final Float32List samples = segments[i].samples;
      features.add(_mel.compute(samples));
      final int v = AsrNemoMel.validFrameCount(samples.length);
      valid[i] = v;
      real += v;
      maxFrames = math.max(maxFrames, AsrNemoMel.frameCount(samples.length));
    }
    return AsrBatchFeatures.raw(
      segments: segments,
      features: features,
      frameCounts: valid,
      maxFrames: maxFrames,
      realFrames: real,
      fbankTime: clock.elapsed,
    );
  }

  @override
  Future<AsrEncodedBatch> encode(
    List<AsrSpeechSegment> segments, {
    AsrBatchFeatures? features,
  }) async {
    if (segments.isEmpty) {
      throw ArgumentError.value(segments, 'segments', '空批');
    }
    final AsrBatchFeatures feats =
        features != null && identical(features.segments, segments)
            ? features
            : computeFeatures(segments);
    final int rows = segments.length;
    final int t = feats.maxFrames;
    if (t == 0) {
      return AsrNemoCtcEncodedBatch._(
        segments: segments,
        frameIds: <Int32List>[for (int i = 0; i < rows; i++) Int32List(0)],
        realFrames: 0,
        paddedFrames: 0,
        fbankTime: feats.fbankTime,
        encoderTime: Duration.zero,
      );
    }
    final Stopwatch clock = Stopwatch()..start();
    // 逐段 [80, valid] 拼成 [N, 80, T]，补齐帧为 0（与特征提取器的补齐语义一致）。
    final AsrNemoMelBatch b = AsrNemoMel.assemble(
      feats.features,
      <int>[for (final AsrSpeechSegment s in segments) s.samples.length],
      _mel.nMels,
    );
    final Map<String, OnnxTensor> out = await _model.run(<String, OnnxTensor>{
      AsrModelIo.nemoInputAudioSignal: OnnxTensor.float32(
        b.features,
        <int>[b.batch, b.nMels, b.frames],
      ),
      AsrModelIo.nemoInputLength: OnnxTensor.int64(b.lengths, <int>[rows]),
    });
    final OnnxTensor? logprobs = out[AsrModelIo.nemoOutputLogprobs];
    if (logprobs == null) {
      throw StateError('模型没有输出 ${AsrModelIo.nemoOutputLogprobs}：${out.keys}');
    }
    if (logprobs.shape.length != 3 || logprobs.shape[0] != rows) {
      throw StateError('logprobs 形状异常：${logprobs.shape}（rows=$rows）');
    }
    final Float32List? data = logprobs.floatData;
    if (data == null) {
      throw StateError('logprobs 不是 float32：${logprobs.type}');
    }
    final int outFrames = logprobs.shape[1];
    final int vocab = logprobs.shape[2];
    final List<Int32List> ids = <Int32List>[];
    int real = 0;
    for (int r = 0; r < rows; r++) {
      final int n = math.min(
        outFrames,
        (feats.frameCounts[r] + kAsrNemoSubsampling - 1) ~/ kAsrNemoSubsampling,
      );
      real += n;
      final Int32List row = Int32List(n);
      int base = r * outFrames * vocab;
      for (int f = 0; f < n; f++, base += vocab) {
        row[f] = _argmax(data, base, vocab);
      }
      ids.add(row);
    }
    return AsrNemoCtcEncodedBatch._(
      segments: segments,
      frameIds: ids,
      realFrames: real,
      paddedFrames: rows * outFrames,
      fbankTime: feats.fbankTime,
      encoderTime: clock.elapsed,
    );
  }

  static int _argmax(Float32List data, int offset, int length) {
    int best = 0;
    double bestValue = data[offset];
    for (int v = 1; v < length; v++) {
      final double value = data[offset + v];
      if (value > bestValue) {
        bestValue = value;
        best = v;
      }
    }
    return best;
  }

  /// CTC 折叠（[ctcCollapseFrames]）：连续相同 id 只发一次，blank / 特殊符号不
  /// 发射；起点 = 首帧 × 80 ms，终点 = 同 id 末帧的结束 × 80 ms。
  @override
  Future<List<AsrDecodedSegment>> search(AsrEncodedBatch encodedBatch) async {
    final AsrNemoCtcEncodedBatch encoded =
        encodedBatch as AsrNemoCtcEncodedBatch;
    final Stopwatch clock = Stopwatch()..start();
    final List<AsrDecodedSegment> out = <AsrDecodedSegment>[];
    for (final Int32List ids in encoded.frameIds) {
      final ({List<int> ids, List<int> startFrames, List<int> endFrames}) c =
          ctcCollapseFrames(ids, _tokens.isSpecial);
      out.add(
        AsrDecodedSegment.fromTokenIds(
          table: _tokens,
          ids: c.ids,
          offsetsMs: <int>[
            for (final int f in c.startFrames) f * kAsrNemoFrameMs
          ],
          endOffsetsMs: <int>[
            for (final int f in c.endFrames) f * kAsrNemoFrameMs,
          ],
        ),
      );
    }
    _stats = _stats.add(
      segments: encoded.segments.length,
      realFrames: encoded.realFrames,
      paddedFrames: encoded.paddedFrames,
      fbank: encoded.fbankTime,
      encoder: encoded.encoderTime,
      search: clock.elapsed,
      usedStaticBucket: false,
    );
    return out;
  }
}

/// [AsrNemoCtcDecoder.encode] 的产物：每段截到有效输出帧的逐帧 argmax id。
class AsrNemoCtcEncodedBatch extends AsrEncodedBatch {
  AsrNemoCtcEncodedBatch._({
    required super.segments,
    required this.frameIds,
    required super.realFrames,
    required super.paddedFrames,
    required super.fbankTime,
    required super.encoderTime,
  }) : super(isStatic: false, isEmpty: realFrames == 0);

  final List<Int32List> frameIds;
}
