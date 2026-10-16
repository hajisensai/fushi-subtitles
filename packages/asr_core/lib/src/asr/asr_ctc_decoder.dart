/// CTC 解码：原始波形 → 单个编码器 → 逐帧 argmax → 折叠。给 Omnilingual ASR
/// （`asr_model_manifest.dart` 的 [AsrModelArchitecture.ctc] 包）。
///
/// 与 transducer 路径共用任务流水线（[AsrPipelinedDecoder] 三段）与静态桶池
/// （`asr_encoder_buckets.dart`，桶以**样本数**为时间轴、无哨兵行）：
/// 1. [computeFeatures]：逐段零均值单位方差归一化（对齐 sherpa-onnx
///    `OfflineOmnilingualAsrCtcModel::NormalizeFeatures`），这一步就是本架构的
///    「特征」——没有 fbank；
/// 2. [encode]：有静态桶就把整批填成 `[N_b, S_b]`（多余行喂零、输出丢弃），否则
///    **逐段**动态会话跑精确长度（CPU 上 padding 直接等于算力，不值得为批处理付）；
///    读回 `logits[N, T, V]` 后立刻逐帧 argmax 成 `int32[T]`，主机侧只留 id；
/// 3. [search]：CTC 折叠（去重复、去 blank），token 时间 = 帧号 × 每帧样本数。
///
/// 每帧样本数从输出反推（`num_samples / num_frames`，Omnilingual 为 320 = 20 ms），
/// 不写死——换模型不必改代码。
///
/// 传了 [AsrCtcDecoder.new] 的 `nemoMel` 就走 NeMo mel 前端（Kitsune，
/// `AsrCtcFrontend.nemoMel80`）：特征是逐段 log-mel（isolate 池），一批补零拼成
/// `features[N, 80, T]` + `lengths[N]`，读图内 argmax 的 `ids` / `out_lengths`；
/// 字时按 [kitsuneCharTiming]（多字 token 摊开、标点归前一个发音字）。
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'dart:typed_data';
import 'package:meta/meta.dart';
import 'package:fushi_asr_core/src/asr/asr_encoder_buckets.dart';
import 'package:fushi_asr_core/src/asr/asr_nemo_mel.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart'
    show
        AsrBatchDecoder,
        AsrBatchShaper,
        AsrPipelinedDecoder,
        AsrSegmentDecoder;
import 'package:fushi_asr_core/src/asr/asr_transducer_decoder.dart'
    show AsrBatchFeatures, AsrDecodeStats, AsrEncodedBatch;
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';

/// CTC 模型在 GPU 上的静态桶（时间轴 = 样本数；无哨兵行）：6 / 12 / 21 s，
/// 盖住 VAD 默认 20 s 段上限 + 两侧 pad。行数随长度递减，`N × S` 面积相近。
const List<AsrEncoderBucket> kAsrCtcGpuBuckets = <AsrEncoderBucket>[
  AsrEncoderBucket(frames: 6 * kAsrSampleRate, batch: 8, sentinel: false),
  AsrEncoderBucket(frames: 12 * kAsrSampleRate, batch: 4, sentinel: false),
  AsrEncoderBucket(frames: 21 * kAsrSampleRate, batch: 2, sentinel: false),
];

/// Omnilingual 导出的两个符号维名（`x[N, num_samples]`，已用 onnx 核实）。
const String kAsrCtcBatchDim = 'N';
const String kAsrCtcSamplesDim = 'num_samples';

class AsrCtcDecoder
    implements
        AsrBatchDecoder,
        AsrBatchShaper,
        AsrPipelinedDecoder,
        AsrSegmentDecoder {
  AsrCtcDecoder({
    required OnnxSession model,
    required AsrTokenTable tokens,
    AsrStaticEncoderPool? staticSessions,
    AsrNemoMel? nemoMel,
    int? melWorkers,
    this.melPadToSamples = kAsrSampleRate,
  })  : _model = model,
        _tokens = tokens,
        _static = nemoMel == null ? staticSessions : null,
        _mel = nemoMel,
        _melWorkers = nemoMel == null
            ? null
            : AsrNemoMelWorkers(nemoMel, workers: melWorkers) {
    if (tokens.blankId < 0) {
      throw ArgumentError.value(tokens, 'tokens', '词表缺少 blank 记号');
    }
  }

  final OnnxSession _model;
  final AsrTokenTable _tokens;
  final AsrStaticEncoderPool? _static;
  final AsrNemoMel? _mel;
  final AsrNemoMelWorkers? _melWorkers;

  /// mel 前端：批内最长段向上取整到这个样本数的倍数，压低 GPU EP 见到的不同
  /// 输入形状数（每个新形状 DML 要重新编译一次）。
  final int melPadToSamples;

  AsrDecodeStats _stats = const AsrDecodeStats();

  @override
  AsrDecodeStats get stats => _stats;

  @override
  int? batchCapFor(int longestSamples) => _static?.batchCapFor(longestSamples);

  @override
  int? bucketKeyFor(int longestSamples) =>
      _static?.bucketFor(longestSamples)?.frames;

  @override
  Future<List<AsrDecodedSegment>> decodeBatch(
    List<AsrSpeechSegment> segments,
  ) async {
    if (segments.isEmpty) return <AsrDecodedSegment>[];
    final int? cap = _capFor(segments);
    if (cap != null && segments.length > cap) {
      final List<AsrDecodedSegment> out = <AsrDecodedSegment>[];
      for (int i = 0; i < segments.length; i += cap) {
        final int end = math.min(i + cap, segments.length);
        out.addAll(await decodeBatch(segments.sublist(i, end)));
      }
      return out;
    }
    return search(await encode(segments));
  }

  int? _capFor(List<AsrSpeechSegment> segments) {
    final AsrStaticEncoderPool? pool = _static;
    if (pool == null || segments.length <= 1) return null;
    int longest = 0;
    for (final AsrSpeechSegment s in segments) {
      longest = math.max(longest, s.samples.length);
    }
    return pool.batchCapFor(longest);
  }

  final Set<AsrEncoderBucket> _warmed = <AsrEncoderBucket>{};

  /// 已发出 warm-up 的桶数（测试用）。
  int get warmedBucketCount => _warmed.length;

  @override
  void warmUp() {
    final AsrStaticEncoderPool? pool = _static;
    if (pool == null) return;
    for (final AsrStaticEncoderSession s in pool.readySessions) {
      if (!_warmed.add(s.bucket)) continue;
      final int rows = s.bucket.batch;
      final int cols = s.bucket.frames;
      final Future<Map<String, OnnxTensor>> run = s.session.run(
        <String, OnnxTensor>{
          AsrModelIo.ctcInputX: OnnxTensor.float32(
            Float32List(rows * cols),
            <int>[rows, cols],
          ),
        },
      );
      unawaited(
        run.then<void>((_) {}).catchError((Object error, StackTrace stack) {
          developer.log(
            'ASR CTC warm-up on ${s.bucket} failed (ignored)',
            name: kAsrLogName,
            error: error,
            stackTrace: stack,
          );
        }),
      );
    }
  }

  /// 波形前端的归一化只是一遍线性扫描（30 分钟约 30 ms），不值得过 isolate；
  /// mel 前端是逐帧 FFT，走 isolate 池。
  @override
  Future<AsrBatchFeatures> computeFeaturesAsync(
    List<AsrSpeechSegment> segments,
  ) async {
    final AsrNemoMelWorkers? workers = _melWorkers;
    if (workers == null) return computeFeatures(segments);
    final Stopwatch clock = Stopwatch()..start();
    final List<Float32List> features = await workers.computeAll(
      <Float32List>[for (final AsrSpeechSegment s in segments) s.samples],
    );
    return _packFeatures(segments, features, clock);
  }

  /// 波形前端：逐段零均值单位方差归一化（double 累加，float32 输出）；
  /// mel 前端：逐段 `[80, valid]` log-mel。两者「帧」都按样本数计。
  @override
  AsrBatchFeatures computeFeatures(List<AsrSpeechSegment> segments) {
    final Stopwatch clock = Stopwatch()..start();
    final AsrNemoMel? mel = _mel;
    return _packFeatures(
      segments,
      <Float32List>[
        for (final AsrSpeechSegment s in segments)
          mel == null ? normalizeWaveform(s.samples) : mel.compute(s.samples),
      ],
      clock,
    );
  }

  static AsrBatchFeatures _packFeatures(
    List<AsrSpeechSegment> segments,
    List<Float32List> features,
    Stopwatch clock,
  ) {
    final Int64List counts = Int64List(segments.length);
    int maxSamples = 0;
    int total = 0;
    for (int i = 0; i < segments.length; i++) {
      final Float32List x = segments[i].samples;
      counts[i] = x.length;
      total += x.length;
      maxSamples = math.max(maxSamples, x.length);
    }
    return AsrBatchFeatures.raw(
      segments: segments,
      features: features,
      frameCounts: counts,
      maxFrames: maxSamples,
      realFrames: total,
      fbankTime: clock.elapsed,
    );
  }

  /// `(x - mean) / sqrt(var + 1e-5)`；方差用中心化后的值算（float32 下
  /// `E[x²] - E[x]²` 会灾难性抵消，sherpa-onnx 同样这么做）。
  @visibleForTesting
  static Float32List normalizeWaveform(Float32List x) {
    if (x.isEmpty) return Float32List(0);
    double sum = 0;
    for (final double v in x) {
      sum += v;
    }
    final double mean = sum / x.length;
    double sq = 0;
    for (final double v in x) {
      final double d = v - mean;
      sq += d * d;
    }
    final double inv = 1 / math.sqrt(sq / x.length + 1e-5);
    final Float32List out = Float32List(x.length);
    for (int i = 0; i < x.length; i++) {
      out[i] = (x[i] - mean) * inv;
    }
    return out;
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
    if (feats.maxFrames == 0) {
      return AsrCtcEncodedBatch._empty(segments, feats.fbankTime);
    }
    final Stopwatch clock = Stopwatch()..start();
    final AsrNemoMel? mel = _mel;
    if (mel != null) return _encodeMel(mel, segments, feats, clock);
    final AsrStaticEncoderPool? pool = _static;
    final AsrStaticEncoderSession? fixed =
        pool == null ? null : await pool.sessionFor(feats.maxFrames);
    if (fixed != null && segments.length > fixed.bucket.realRows) {
      throw ArgumentError.value(
        segments.length,
        'segments',
        '超过静态桶容量 ${fixed.bucket.realRows}（调用方按 batchCapFor 封顶，或用 decodeBatch）',
      );
    }
    final List<Int32List> ids = <Int32List>[];
    int paddedSamples = 0;
    bool usedStatic = false;
    if (fixed != null) {
      final int rows = fixed.bucket.batch;
      final int cols = fixed.bucket.frames;
      final Float32List x = Float32List(rows * cols);
      for (int i = 0; i < segments.length; i++) {
        x.setRange(
            i * cols, i * cols + feats.features[i].length, feats.features[i]);
      }
      try {
        ids.addAll(
          await _runArgmax(fixed.session, x, rows, cols, segments.length),
        );
        usedStatic = true;
        paddedSamples = rows * cols;
      } catch (error, stack) {
        // 桶建得起来但跑不动：标不可用、本批回退动态会话，任务不中断。
        pool!.markUnavailable(fixed.bucket, error, stack);
        return encode(segments, features: feats);
      }
    } else {
      // 动态会话逐段跑精确长度：零 padding。
      for (int i = 0; i < segments.length; i++) {
        final Float32List f = feats.features[i];
        ids.addAll(await _runArgmax(_model, f, 1, f.length, 1));
        paddedSamples += f.length;
      }
    }
    // 每帧样本数：从首段反推（同一模型恒定）。
    int frameSamples = 1;
    for (int i = 0; i < segments.length; i++) {
      if (ids[i].isNotEmpty) {
        final int cols = fixed?.bucket.frames ?? feats.features[i].length;
        frameSamples = math.max(1, cols ~/ ids[i].length);
        break;
      }
    }
    return AsrCtcEncodedBatch._(
      segments: segments,
      frameIds: ids,
      frameSamples: frameSamples,
      realFrames: feats.realFrames ~/ frameSamples,
      paddedFrames: paddedSamples ~/ frameSamples,
      fbankTime: feats.fbankTime,
      encoderTime: clock.elapsed,
      isStatic: usedStatic,
    );
  }

  /// mel 前端：一批补零拼成 `[N, 80, T]`，一次 run；读 `ids` / `out_lengths`
  /// （导出没做图内 argmax 时退回读 `logits` 主机侧 argmax）。
  Future<AsrCtcEncodedBatch> _encodeMel(
    AsrNemoMel mel,
    List<AsrSpeechSegment> segments,
    AsrBatchFeatures feats,
    Stopwatch clock,
  ) async {
    final AsrNemoMelBatch b = AsrNemoMel.assemble(
      feats.features,
      <int>[for (final AsrSpeechSegment s in segments) s.samples.length],
      mel.nMels,
      padTo: melPadToSamples,
    );
    final Map<String, OnnxTensor> out = await _model.run(<String, OnnxTensor>{
      AsrModelIo.ctcInputFeatures: OnnxTensor.float32(
        b.features,
        <int>[b.batch, b.nMels, b.frames],
      ),
      AsrModelIo.ctcInputLengths: OnnxTensor.int64(b.lengths, <int>[b.batch]),
    });
    final OnnxTensor? idsTensor = out[AsrModelIo.ctcOutputIds];
    final List<Int32List> ids = <Int32List>[];
    final int outFrames;
    if (idsTensor != null) {
      if (idsTensor.shape.length != 2 || idsTensor.shape[0] != b.batch) {
        throw StateError('ids 形状异常：${idsTensor.shape}（rows=${b.batch}）');
      }
      outFrames = idsTensor.shape[1];
      final List<int> flat = _intsOf(idsTensor);
      final OnnxTensor? lensTensor = out[AsrModelIo.ctcOutputLengths];
      final List<int>? lens = lensTensor == null ? null : _intsOf(lensTensor);
      for (int r = 0; r < b.batch; r++) {
        final int n = math.max(
          0,
          math.min(lens == null ? outFrames : lens[r], outFrames),
        );
        ids.add(
          Int32List.fromList(flat.sublist(r * outFrames, r * outFrames + n)),
        );
      }
    } else {
      final OnnxTensor? logits = out[AsrModelIo.ctcOutputLogits];
      final Float32List? data = logits?.floatData;
      if (logits == null || data == null || logits.shape.length != 3) {
        throw StateError('模型既没有 ids 也没有 float logits 输出：${out.keys}');
      }
      outFrames = logits.shape[1];
      final int vocab = logits.shape[2];
      for (int r = 0; r < b.batch; r++) {
        final Int32List row = Int32List(outFrames);
        for (int t = 0; t < outFrames; t++) {
          row[t] = _argmax(data, (r * outFrames + t) * vocab, vocab);
        }
        ids.add(row);
      }
    }
    // 子采样倍数：输入帧 / 输出帧（Kitsune 8 → 80 ms）。
    final int subsample =
        outFrames == 0 ? 1 : math.max(1, (b.frames / outFrames).round());
    final int frameSamples = AsrNemoMelParams.hop * subsample;
    return AsrCtcEncodedBatch._(
      segments: segments,
      frameIds: ids,
      frameSamples: frameSamples,
      realFrames: feats.realFrames ~/ frameSamples,
      paddedFrames: b.batch * b.frames ~/ subsample,
      fbankTime: feats.fbankTime,
      encoderTime: clock.elapsed,
      isStatic: false,
    );
  }

  /// int64 输出：FFI 后端给 `intData`；插件后端统一读成 float32（整数值落在
  /// float 里）；也认 int32。
  static List<int> _intsOf(OnnxTensor t) {
    final Int64List? i64 = t.intData;
    if (i64 != null) return i64;
    final Int32List? i32 = t.int32Data;
    if (i32 != null) return i32;
    final Float32List? f = t.floatData;
    if (f != null) {
      return <int>[for (final double v in f) v.round()];
    }
    throw StateError('整型输出没有数据：${t.type}');
  }

  /// 一段波形一次 run（动态会话、精确长度），返回完整的原始 `logits[T, V]`
  /// 与每帧样本数——强制对齐（`asr_ctc_align.dart`）要整张矩阵做 Viterbi，
  /// 不能像转录那样当场 argmax。20 s 段 ≈ 1000 帧 × 10288 × 4 B ≈ 41 MB，
  /// 调用方逐段拿、用完即弃。
  Future<AsrCtcLogits> runLogits(Float32List samples) async {
    if (samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', '空段');
    }
    final Float32List x = normalizeWaveform(samples);
    final Map<String, OnnxTensor> out = await _model.run(<String, OnnxTensor>{
      AsrModelIo.ctcInputX: OnnxTensor.float32(x, <int>[1, x.length]),
    });
    final OnnxTensor? logits = out[AsrModelIo.ctcOutputLogits];
    if (logits == null) {
      throw StateError('模型没有输出 ${AsrModelIo.ctcOutputLogits}：${out.keys}');
    }
    if (logits.shape.length != 3 || logits.shape[0] != 1) {
      throw StateError('logits 形状异常：${logits.shape}');
    }
    final Float32List? data = logits.floatData;
    if (data == null) {
      throw StateError('logits 不是 float32：${logits.type}');
    }
    final int frames = logits.shape[1];
    return AsrCtcLogits(
      logits: data,
      frames: frames,
      vocab: logits.shape[2],
      frameSamples: frames == 0 ? 1 : math.max(1, x.length ~/ frames),
    );
  }

  /// 跑一次模型并对前 [realRows] 行逐帧 argmax。
  Future<List<Int32List>> _runArgmax(
    OnnxSession session,
    Float32List x,
    int rows,
    int cols,
    int realRows,
  ) async {
    final Map<String, OnnxTensor> out = await session.run(<String, OnnxTensor>{
      AsrModelIo.ctcInputX: OnnxTensor.float32(x, <int>[rows, cols]),
    });
    final OnnxTensor? logits = out[AsrModelIo.ctcOutputLogits];
    if (logits == null) {
      throw StateError('模型没有输出 ${AsrModelIo.ctcOutputLogits}：${out.keys}');
    }
    if (logits.shape.length != 3 || logits.shape[0] != rows) {
      throw StateError('logits 形状异常：${logits.shape}（rows=$rows）');
    }
    final Float32List? data = logits.floatData;
    if (data == null) {
      throw StateError('logits 不是 float32：${logits.type}');
    }
    final int frames = logits.shape[1];
    final int vocab = logits.shape[2];
    final List<Int32List> result = <Int32List>[];
    for (int r = 0; r < realRows; r++) {
      final Int32List ids = Int32List(frames);
      int base = r * frames * vocab;
      for (int t = 0; t < frames; t++, base += vocab) {
        ids[t] = _argmax(data, base, vocab);
      }
      result.add(ids);
    }
    return result;
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

  /// CTC 折叠：连续相同 id 只算一次，blank / 特殊符号不发射。
  @override
  Future<List<AsrDecodedSegment>> search(AsrEncodedBatch encodedBatch) async {
    final AsrCtcEncodedBatch encoded = encodedBatch as AsrCtcEncodedBatch;
    final Stopwatch clock = Stopwatch()..start();
    final List<AsrDecodedSegment> out = <AsrDecodedSegment>[];
    for (int i = 0; i < encoded.segments.length; i++) {
      final Int32List ids =
          i < encoded.frameIds.length ? encoded.frameIds[i] : Int32List(0);
      final List<int> emitted = <int>[];
      final List<int> frames = <int>[];
      int prev = -1;
      for (int t = 0; t < ids.length; t++) {
        final int id = ids[t];
        if (id != prev && !_tokens.isSpecial(id)) {
          emitted.add(id);
          frames.add(t);
        }
        prev = id;
      }
      if (_mel != null) {
        out.add(
          kitsuneCharTiming(
            table: _tokens,
            ids: emitted,
            frames: frames,
            frameMs: encoded.frameSamples * 1000 / kAsrSampleRate,
            segmentMs: encoded.segments[i].lengthMs,
          ),
        );
        continue;
      }
      out.add(
        AsrDecodedSegment.fromTokenIds(
          table: _tokens,
          ids: emitted,
          offsetsMs: <int>[
            for (final int t in frames)
              t * encoded.frameSamples * 1000 ~/ kAsrSampleRate,
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
      usedStaticBucket: encoded.isStatic,
    );
    return out;
  }
}

/// 子词 CTC（Kitsune）的逐字时间，对齐 SubThx 评测脚本：
/// - token 去掉 `▁` 后 trim，空的（纯 `▁`）丢弃——日语不需要词间空格；
/// - 发射帧时刻 = 帧号 × [frameMs]；多字 token 的字在
///   `min(下一发射帧 − 本帧, 字数)` 帧内线性摊开；
/// - 夹进 `[0, segmentMs]` 并保持单调；
/// - 标点 / 符号 / 空白（Unicode P / S / Z）没有声学时刻：取前一个发音字的
///   时刻（领头的取首个发音字）。CTC 的句末「。」常晚发射到下一次停顿之后，
///   不归位会把 cue 终点拖进静音。
@visibleForTesting
AsrDecodedSegment kitsuneCharTiming({
  required AsrTokenTable table,
  required List<int> ids,
  required List<int> frames,
  required double frameMs,
  required int segmentMs,
}) {
  final List<String> chars = <String>[];
  final List<double> times = <double>[];
  for (int j = 0; j < ids.length; j++) {
    final String text = table
        .tokenAt(ids[j])
        .replaceAll(AsrTokenTable.sentencePieceSpace, '')
        .trim();
    final List<String> runes = <String>[
      for (final int r in text.runes) String.fromCharCode(r),
    ];
    if (runes.isEmpty) continue;
    final int fr = frames[j];
    final int next = j + 1 < ids.length ? frames[j + 1] : fr + runes.length;
    final double span = math.min(next - fr, runes.length) * frameMs;
    final double t0 = fr * frameMs;
    for (int q = 0; q < runes.length; q++) {
      chars.add(runes[q]);
      times.add(t0 + span * q / runes.length);
    }
  }
  final List<int> ms = <int>[];
  int pv = 0;
  for (final double x in times) {
    final int v =
        math.min(math.max(x, pv.toDouble()), segmentMs.toDouble()).round();
    ms.add(v);
    pv = v;
  }
  int? firstSpoken;
  for (int k = 0; k < chars.length; k++) {
    if (_isSpoken(chars[k])) {
      firstSpoken = ms[k];
      break;
    }
  }
  int? last;
  for (int k = 0; k < chars.length; k++) {
    if (_isSpoken(chars[k])) {
      last = ms[k];
    } else if (last != null) {
      ms[k] = last;
    } else if (firstSpoken != null) {
      ms[k] = firstSpoken;
    }
  }
  return AsrDecodedSegment(
    tokens: List<String>.unmodifiable(chars),
    tokenOffsetsMs: List<int>.unmodifiable(ms),
  );
}

final RegExp _kNonSpoken = RegExp(r'^[\p{P}\p{S}\p{Z}]$', unicode: true);

bool _isSpoken(String c) => !_kNonSpoken.hasMatch(c);

/// [AsrCtcDecoder.runLogits] 的产物：一段的原始 `logits[frames × vocab]`
/// （行主序、未 softmax）与每帧样本数（Omnilingual 320 = 20 ms）。
class AsrCtcLogits {
  const AsrCtcLogits({
    required this.logits,
    required this.frames,
    required this.vocab,
    required this.frameSamples,
  });

  final Float32List logits;
  final int frames;
  final int vocab;
  final int frameSamples;

  /// 一帧的毫秒数。
  double get frameMs => frameSamples * 1000 / kAsrSampleRate;
}

/// [AsrCtcDecoder.encode] 的产物：每段逐帧 argmax 后的 id 与每帧样本数。
class AsrCtcEncodedBatch extends AsrEncodedBatch {
  AsrCtcEncodedBatch._({
    required super.segments,
    required this.frameIds,
    required this.frameSamples,
    required super.realFrames,
    required super.paddedFrames,
    required super.fbankTime,
    required super.encoderTime,
    required super.isStatic,
  }) : super(isEmpty: frameIds.isEmpty);

  AsrCtcEncodedBatch._empty(List<AsrSpeechSegment> segments, Duration fbankTime)
      : this._(
          segments: segments,
          frameIds: const <Int32List>[],
          frameSamples: 1,
          realFrames: 0,
          paddedFrames: 0,
          fbankTime: fbankTime,
          encoderTime: Duration.zero,
          isStatic: false,
        );

  final List<Int32List> frameIds;
  final int frameSamples;
}
