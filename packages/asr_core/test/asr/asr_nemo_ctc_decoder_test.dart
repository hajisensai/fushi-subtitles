import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_nemo_ctc_decoder.dart';
import 'package:fushi_asr_core/src/asr/asr_nemo_mel.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';
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
    expect(kAsrNemoFrameMs, 80);
    // 行 1 只有 0.5 s（50 有效帧 → 7 输出帧）：补齐区的 'あ' 不得出现。
    expect(out[1].tokens, <String>['い']);
    expect(out[1].tokenOffsetsMs, <int>[160]);
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
}
