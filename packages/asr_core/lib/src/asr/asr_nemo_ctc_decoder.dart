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

class AsrNemoCtcDecoder implements AsrSegmentDecoder {
  AsrNemoCtcDecoder({
    required OnnxSession model,
    required AsrTokenTable tokens,
    AsrNemoMel mel = const AsrNemoMel(),
  })  : _model = model,
        _tokens = tokens,
        _mel = mel {
    if (tokens.blankId < 0) {
      throw ArgumentError.value(tokens, 'tokens', '词表缺少 blank 记号');
    }
  }

  final OnnxSession _model;
  final AsrTokenTable _tokens;
  final AsrNemoMel _mel;

  AsrDecodeStats _stats = const AsrDecodeStats();

  @override
  AsrDecodeStats get stats => _stats;

  /// 动态会话、无静态桶：滑窗的输入长度本身就恒定（15 s），不需要桶来钉形状。
  @override
  int? batchCapFor(int longestSamples) => null;

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

  /// 每段一份帧主序 `[frames, 80]` 特征；`frameCounts` 记**有效帧数**（喂给
  /// `length`），总帧数 = `features[i].length / 80`。
  @override
  AsrBatchFeatures computeFeatures(List<AsrSpeechSegment> segments) {
    final Stopwatch clock = Stopwatch()..start();
    final List<Float32List> features = <Float32List>[];
    final Int64List valid = Int64List(segments.length);
    int maxFrames = 0;
    int real = 0;
    for (int i = 0; i < segments.length; i++) {
      final AsrNemoMelFeatures f = _mel.compute(segments[i].samples);
      features.add(f.features);
      valid[i] = f.validFrames;
      real += f.validFrames;
      maxFrames = math.max(maxFrames, f.frames);
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
    const int dim = AsrNemoMel.numMels;
    // [N, T, 80] → [N, 80, T]，补齐帧为 0（与特征提取器的补齐语义一致）。
    final Float32List x = Float32List(rows * dim * t);
    for (int r = 0; r < rows; r++) {
      final Float32List f = feats.features[r];
      final int frames = f.length ~/ dim;
      final int base = r * dim * t;
      for (int frame = 0; frame < frames; frame++) {
        final int src = frame * dim;
        for (int m = 0; m < dim; m++) {
          x[base + m * t + frame] = f[src + m];
        }
      }
    }
    final Map<String, OnnxTensor> out = await _model.run(<String, OnnxTensor>{
      AsrModelIo.nemoInputAudioSignal:
          OnnxTensor.float32(x, <int>[rows, dim, t]),
      AsrModelIo.nemoInputLength:
          OnnxTensor.int64(Int64List.fromList(feats.frameCounts), <int>[rows]),
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

  /// CTC 折叠：连续相同 id 只发一次，blank / 特殊符号不发射；时间 = 首帧 × 80 ms。
  @override
  Future<List<AsrDecodedSegment>> search(AsrEncodedBatch encodedBatch) async {
    final AsrNemoCtcEncodedBatch encoded =
        encodedBatch as AsrNemoCtcEncodedBatch;
    final Stopwatch clock = Stopwatch()..start();
    final List<AsrDecodedSegment> out = <AsrDecodedSegment>[];
    for (final Int32List ids in encoded.frameIds) {
      final List<int> emitted = <int>[];
      final List<int> offsets = <int>[];
      int prev = -1;
      for (int f = 0; f < ids.length; f++) {
        final int id = ids[f];
        if (id != prev && !_tokens.isSpecial(id)) {
          emitted.add(id);
          offsets.add(f * kAsrNemoFrameMs);
        }
        prev = id;
      }
      out.add(
        AsrDecodedSegment.fromTokenIds(
          table: _tokens,
          ids: emitted,
          offsetsMs: offsets,
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
