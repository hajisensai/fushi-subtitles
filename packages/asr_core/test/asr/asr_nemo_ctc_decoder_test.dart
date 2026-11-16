import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_nemo_ctc_decoder.dart';
import 'package:fushi_asr_core/src/asr/asr_nemo_mel.dart';
import 'package:fushi_asr_core/src/asr/asr_sliding_window.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart';
import 'package:fushi_asr_core/src/asr/asr_transcription_service.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// sherpa-onnx NeMo 词表形态：`<blk>` 在**末位**（Parakeet 日语是 3072）。
const String _kTokens = '<unk> 0\nあ 1\nい 2\nう 3\n。 4\n<blk> 5\n';
const int _kVocab = 6;
const int _kBlank = 5;

/// fake NeMo CTC：`audio_signal[N, 80, T]` + `length[N]` → `logprobs[N, T', V]`。
/// 输出帧数故意按**批内最长**补齐（真模型也是），第 r 行第 f 帧的 argmax 由
/// [plan] 给出；补齐区一律发 'あ'，解码器必须按 `ceil(length/8)` 截掉。
class _NemoSession implements OnnxSession {
  _NemoSession(this.plan);

  final int Function(int row, int frame) plan;
  final List<List<int>> shapes = <List<int>>[];
  final List<List<int>> lengths = <List<int>>[];
  Float32List? lastSignal;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor x = inputs[AsrModelIo.nemoInputAudioSignal]!;
    final OnnxTensor len = inputs[AsrModelIo.nemoInputLength]!;
    expect(x.type, OnnxTensorType.float32);
    expect(len.type, OnnxTensorType.int64);
    shapes.add(List<int>.from(x.shape));
    lengths.add(List<int>.from(len.intData!));
    lastSignal = x.floatData;
    final int rows = x.shape[0];
    final int outFrames = (x.shape[2] + 7) ~/ 8;
    final Float32List logp = Float32List(rows * outFrames * _kVocab);
    for (int r = 0; r < rows; r++) {
      final int real = (len.intData![r] + 7) ~/ 8;
      for (int f = 0; f < outFrames; f++) {
        final int target = f < real ? plan(r, f) : 1;
        final int base = (r * outFrames + f) * _kVocab;
        for (int v = 0; v < _kVocab; v++) {
          logp[base + v] = v == target ? -0.1 : -9;
        }
      }
    }
    return <String, OnnxTensor>{
      AsrModelIo.nemoOutputLogprobs:
          OnnxTensor.float32(logp, <int>[rows, outFrames, _kVocab]),
    };
  }

  @override
  Future<void> close() async {}
}

AsrSpeechSegment _seg(double seconds, {int start = 0}) {
  final Float32List s = Float32List((seconds * kAsrSampleRate).round());
  for (int i = 0; i < s.length; i++) {
    s[i] = ((i * 7919) % 2000 - 1000) / 4000; // 确定性的类噪声信号
  }
  return AsrSpeechSegment(startSample: start, samples: s);
}

void main() {
  final AsrTokenTable tokens = AsrTokenTable.parse(_kTokens);

  test('词表末位 <blk> 被认作 blank', () {
    expect(tokens.blankId, _kBlank);
    expect(tokens.size, _kVocab);
  });

  test('输入是 [N, 80, T] 转置的 NeMo mel，length 传有效帧数', () async {
    final _NemoSession session = _NemoSession((int r, int f) => _kBlank);
    final AsrNemoCtcDecoder decoder =
        AsrNemoCtcDecoder(model: session, tokens: tokens);
    final List<AsrSpeechSegment> segs = <AsrSpeechSegment>[
      _seg(1.0),
      _seg(0.5)
    ];
    await decoder.decodeBatch(segs);
    expect(session.shapes.single, <int>[2, 80, AsrNemoMel.frameCount(16000)]);
    expect(session.lengths.single, <int>[100, 50]);
    // 第 0 行第 7 维第 3 帧 = 逐段特征（mel 主序 [80, valid]）的 [7][3]。
    final Float32List f = AsrNemoMel.slaney80.compute(segs[0].samples);
    final int t = AsrNemoMel.frameCount(16000);
    final int valid = AsrNemoMel.validFrameCount(16000);
    expect(session.lastSignal![7 * t + 3], f[7 * valid + 3]);
    // 短的那行补齐帧为 0。
    expect(session.lastSignal![80 * t + 7 * t + 60], 0);
  });

  test('折叠：去重复、去 blank，时间 = 输出帧 × 80 ms；补齐帧不解码', () async {
    // 行 0（1 s = 100 有效帧 → 13 输出帧）：あ あ blk い blk blk う 。…
    const List<int> row0 = <int>[1, 1, _kBlank, 2, _kBlank, _kBlank, 3, 4];
    final _NemoSession session = _NemoSession(
      (int r, int f) => r == 0 && f < row0.length
          ? row0[f]
          : (r == 1 && f == 2 ? 2 : _kBlank),
    );
    final AsrNemoCtcDecoder decoder =
        AsrNemoCtcDecoder(model: session, tokens: tokens);
    final List<AsrDecodedSegment> out =
        await decoder.decodeBatch(<AsrSpeechSegment>[_seg(1.0), _seg(0.5)]);
    expect(out[0].tokens, <String>['あ', 'い', 'う', '。']);
    expect(out[0].tokenOffsetsMs, <int>[0, 240, 480, 560]);
    // 终点 = 同 id 末帧的结束：あ 占帧 0–1 → 160；之后的 blank 不算它的。
    expect(out[0].tokenEndOffsetsMs, <int>[160, 320, 560, 640]);
    expect(kAsrNemoFrameMs, 80);
    // 行 1 只有 0.5 s（50 有效帧 → 7 输出帧）：补齐区的 'あ' 不得出现。
    expect(out[1].tokens, <String>['い']);
    expect(out[1].tokenOffsetsMs, <int>[160]);
    expect(out[1].tokenEndOffsetsMs, <int>[240]);
  });

  test('统计记账：真实帧 = 各行 ceil(length/8) 之和', () async {
    final _NemoSession session = _NemoSession((int r, int f) => _kBlank);
    final AsrNemoCtcDecoder decoder =
        AsrNemoCtcDecoder(model: session, tokens: tokens);
    await decoder.decodeBatch(<AsrSpeechSegment>[_seg(1.0), _seg(0.5)]);
    expect(decoder.stats.realFrames, 13 + 7);
    expect(decoder.stats.segments, 2);
  });

  test('没有 blank 的词表直接拒绝', () {
    expect(
      () => AsrNemoCtcDecoder(
        model: _NemoSession((int r, int f) => 0),
        tokens: AsrTokenTable.parse('a 0\nb 1\n'),
      ),
      throwsArgumentError,
    );
  });

  // Fushi issue #3380：6 GB 的 3060 Laptop 上 CUDA 转录在首个 Run 卡死。任务侧的
  // 动态预算一批发 42 个 15 s 窗口，Parakeet 0.6B fp32 要约 10 GB 显存。
  group('GPU 成批上限', () {
    const int mib = 1024 * 1024;
    // Parakeet 0.6B ja fp32：model.onnx + model.onnx_data。
    const int weights = 953841 + 2484355076;
    const int window = 15 * kAsrSampleRate;

    int rows(int? budgetBytes, {int samples = window}) => asrNemoGpuBatchRows(
          longestSamples: samples,
          budget: AsrNemoGpuBatchBudget(
            weightBytes: weights,
            budgetBytes: budgetBytes,
          ),
        );

    test('按显存预算算行数，封顶 $kAsrNemoGpuMaxBatchRows，至少 1', () {
      // 12 GB 卡：显存再多也不超过上限（批再大没有吞吐收益）。
      expect(rows(11000 * mib), kAsrNemoGpuMaxBatchRows);
      // 6 GB 卡（预算约 5.3 GB）：峰值 ≈ 2.6 GB 权重 + 8 × 0.2 GB，装得下。
      expect(rows(5400 * mib), 8);
      // 刚过 fp32 门槛的 4 GiB 预算：只剩 3 行。
      expect(rows(4096 * mib), 3);
      // 预算比权重还小：仍发 1 行（单行也得解，不能卡在 0）。
      expect(rows(2000 * mib), 1);
      expect(rows(0), 1);
    });

    test('窗口越长行数越少；预算未知按 60 s 音频一批', () {
      expect(rows(4096 * mib, samples: 30 * kAsrSampleRate), 1);
      expect(rows(null), 4);
      expect(rows(null, samples: 30 * kAsrSampleRate), 2);
      expect(rows(null, samples: 120 * kAsrSampleRate), 1);
      // 不足 1 s 的尾窗按 1 s 计，不除零、不超上限。
      expect(rows(null, samples: 100), kAsrNemoGpuMaxBatchRows);
    });

    test('CPU 会话（不给预算）不封顶，GPU 会话 batchCapFor 给出行数', () {
      final _NemoSession session = _NemoSession((int r, int f) => _kBlank);
      expect(
        AsrNemoCtcDecoder(model: session, tokens: tokens).batchCapFor(window),
        isNull,
      );
      expect(
        AsrNemoCtcDecoder(
          model: session,
          tokens: tokens,
          gpuBatchBudget: const AsrNemoGpuBatchBudget(
            weightBytes: weights,
            budgetBytes: 4096 * mib,
          ),
        ).batchCapFor(window),
        3,
      );
    });

    group('整条任务（滑窗 + GPU 默认 batchSize）', () {
      late Directory tmp;
      setUp(() => tmp = Directory.systemTemp.createTempSync('asr_nemo_cap_'));
      tearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      Future<List<int>> batchRows(AsrNemoGpuBatchBudget? budget) async {
        final _NemoSession session = _NemoSession((int r, int f) => _kBlank);
        final AsrTranscribeJob job = AsrTranscribeJob(
          jobDir: Directory(p.join(tmp.path, budget == null ? 'cpu' : 'gpu')),
          audioPaths: const <String>['a.mkv'],
          modelId: 'm',
          pcm: _SilencePcm(seconds: 780),
          segmenter: AsrSlidingWindowSegmenter(),
          decoder: AsrNemoCtcDecoder(
            model: session,
            tokens: tokens,
            gpuBatchBudget: budget,
          ),
          batchSize: AsrTranscriptionService.defaultBatchSizeFor(
            OnnxExecutionProvider.cuda,
          ),
          progressInterval: Duration.zero,
        );
        final List<AsrTranscribeEvent> events = await job.run().toList();
        expect(events.last, isA<AsrTranscribeFinishedEvent>());
        return <int>[for (final List<int> s in session.shapes) s[0]];
      }

      test('不封顶时一批 42 行（复现）；封顶后每批 ≤ 上限且窗口一个不少', () async {
        // 780 s、步长 12 s → 65 个窗口。
        final List<int> uncapped = await batchRows(null);
        expect(uncapped.reduce((int a, int b) => a + b), 65);
        expect(uncapped.first, 42, reason: '动态预算 640 s ÷ 15 s');

        final List<int> capped = await batchRows(
          const AsrNemoGpuBatchBudget(
            weightBytes: weights,
            budgetBytes: 5400 * mib,
          ),
        );
        expect(capped.reduce((int a, int b) => a + b), 65);
        expect(capped.every((int n) => n <= kAsrNemoGpuMaxBatchRows), isTrue);
        expect(capped.first, kAsrNemoGpuMaxBatchRows);
      });
    });
  });
}

/// 一整条静音 PCM（按 [chunkSeconds] 分块）。
class _SilencePcm implements AsrPcmSource {
  _SilencePcm({required this.seconds});
  final int seconds;

  @override
  Future<int?> probeDurationMs(String audioPath) async => seconds * 1000;

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) async* {
    final int total = seconds * kAsrSampleRate;
    final int step = chunkSeconds * kAsrSampleRate;
    for (int at = startSample; at < total; at += step) {
      final int end = at + step < total ? at + step : total;
      yield AsrPcmChunk(startSample: at, samples: Float32List(end - at));
    }
  }
}
