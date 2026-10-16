import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:fushi_asr_core/src/asr/asr_ctc_decoder.dart';
import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_nemo_mel.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';

/// Kitsune 形态的 HF tokenizer.json：BPE vocab 字典 + added_tokens
/// （`<unk>`=0、`<blank>`=最后一个 id）。
final String _kTokenizerJson = jsonEncode(<String, Object?>{
  'model': <String, Object?>{
    'type': 'BPE',
    'vocab': <String, int>{
      '<unk>': 0,
      '▁': 1,
      '▁今日': 2,
      'は': 3,
      '。': 4,
      '「': 5,
    },
  },
  'added_tokens': <Object>[
    <String, Object>{'id': 0, 'content': '<unk>', 'special': true},
    <String, Object>{'id': 6, 'content': '<blank>', 'special': true},
  ],
});

/// 伪 Kitsune 图：按 [plan] 逐输出帧给 id；`ids` 以 int64（FFI）或 float32
/// （插件后端把 int64 读成 float）返回。
class _KitsuneSession implements OnnxSession {
  _KitsuneSession(this.plan, {this.floatIds = false, this.logitsOnly = false});

  final int Function(int row, int frame) plan;
  final bool floatIds;
  final bool logitsOnly;
  final List<List<int>> featureShapes = <List<int>>[];
  final List<List<int>> lengths = <List<int>>[];

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor f = inputs[AsrModelIo.ctcInputFeatures]!;
    final OnnxTensor l = inputs[AsrModelIo.ctcInputLengths]!;
    expect(f.type, OnnxTensorType.float32);
    expect(l.type, OnnxTensorType.int64);
    featureShapes.add(List<int>.from(f.shape));
    lengths.add(List<int>.from(l.intData!));
    final int rows = f.shape[0];
    final int outT = (f.shape[2] - 1) ~/ 8 + 1;
    final Int64List outLens = Int64List.fromList(<int>[
      for (final int n in l.intData!) (n - 1) ~/ 8 + 1,
    ]);
    if (logitsOnly) {
      const int vocab = 7;
      final Float32List logits = Float32List(rows * outT * vocab);
      for (int r = 0; r < rows; r++) {
        for (int t = 0; t < outT; t++) {
          logits[(r * outT + t) * vocab + plan(r, t)] = 5;
        }
      }
      return <String, OnnxTensor>{
        AsrModelIo.ctcOutputLogits: OnnxTensor.float32(logits, <int>[
          rows,
          outT,
          vocab,
        ]),
      };
    }
    final List<int> ids = <int>[
      for (int r = 0; r < rows; r++)
        for (int t = 0; t < outT; t++) plan(r, t),
    ];
    return <String, OnnxTensor>{
      AsrModelIo.ctcOutputIds:
          floatIds
              ? OnnxTensor.float32(
                Float32List.fromList(<double>[
                  for (final int v in ids) v * 1.0,
                ]),
                <int>[rows, outT],
              )
              : OnnxTensor.int64(Int64List.fromList(ids), <int>[rows, outT]),
      AsrModelIo.ctcOutputLengths:
          floatIds
              ? OnnxTensor.float32(
                Float32List.fromList(<double>[
                  for (final int v in outLens) v * 1.0,
                ]),
                <int>[rows],
              )
              : OnnxTensor.int64(outLens, <int>[rows]),
    };
  }

  @override
  Future<void> close() async {}
}

AsrNemoMel _mel() {
  final Float32List fb = Float32List(257 * 80);
  for (int m = 0; m < 80; m++) {
    fb[(3 * m + 5) * 80 + m] = 0.1;
  }
  return AsrNemoMel(fb, 80);
}

AsrSpeechSegment _segment(int samples) {
  final Float32List x = Float32List(samples);
  for (int i = 0; i < samples; i++) {
    x[i] = 0.2 * ((i * 37) % 101 - 50) / 50;
  }
  return AsrSpeechSegment(startSample: 0, samples: x);
}

/// 帧 0 `「`、帧 1 `▁今日`（帧 2 重复）、帧 3 纯 `▁`、帧 5 `は`、帧 9 `。`，其余 blank。
int _plan(int row, int t) => switch (t) {
  0 => 5,
  1 || 2 => 2,
  3 => 1,
  5 => 3,
  9 => 4,
  _ => 6,
};

void main() {
  final AsrTokenTable tokens = AsrTokenTable.parse(
    _kTokenizerJson,
    blankToken: '<blank>',
  );

  test('tokenizer.json：vocab + added_tokens，blank / unk 认对', () {
    expect(tokens.size, 7);
    expect(tokens.blankId, 6);
    expect(tokens.unkId, 0);
    expect(tokens.isSpecial(6), isTrue);
    expect(tokens.tokenAt(2), '▁今日');
    expect(tokens.isSentencePiece, isTrue);
  });

  test('字时：多字 token 摊开、纯 ▁ 丢弃、标点归前一个发音字、领头标点归首字', () {
    final AsrDecodedSegment d = kitsuneCharTiming(
      table: tokens,
      ids: <int>[5, 2, 1, 3, 4],
      frames: <int>[0, 1, 3, 5, 9],
      frameMs: 80,
      segmentMs: 1000,
    );
    expect(d.tokens, <String>['「', '今', '日', 'は', '。']);
    // 今 = 帧 1；日 = 帧 1 + min(3-1, 2)/2 帧；は = 帧 5；。归は；「归今。
    expect(d.tokenOffsetsMs, <int>[80, 80, 160, 400, 400]);
  });

  test('字时：夹进段长并单调', () {
    final AsrDecodedSegment d = kitsuneCharTiming(
      table: tokens,
      ids: <int>[2, 3],
      frames: <int>[10, 20],
      frameMs: 80,
      segmentMs: 1000,
    );
    expect(d.tokenOffsetsMs, <int>[800, 880, 1000]);
  });

  for (final bool floatIds in <bool>[false, true]) {
    test(
      'mel 前端解码（ids 为 ${floatIds ? 'float32（插件）' : 'int64（FFI）'}）',
      () async {
        final _KitsuneSession session = _KitsuneSession(
          _plan,
          floatIds: floatIds,
        );
        final AsrCtcDecoder d = AsrCtcDecoder(
          model: session,
          tokens: tokens,
          nemoMel: _mel(),
          melWorkers: 1,
        );
        final List<AsrSpeechSegment> segs = <AsrSpeechSegment>[
          _segment(kAsrSampleRate + 3200),
          _segment(kAsrSampleRate ~/ 2),
        ];
        final List<AsrDecodedSegment> out = await d.search(
          await d.encode(segs, features: await d.computeFeaturesAsync(segs)),
        );
        // 一批一次 run：最长 1.2 s 向上取整到 2 s → T = 201；有效帧 = 样本 / 160。
        expect(session.featureShapes, <List<int>>[
          <int>[2, 80, 201],
        ]);
        expect(session.lengths, <List<int>>[
          <int>[120, 50],
        ]);
        expect(out[0].text, '「今日は。');
        expect(out[0].tokenOffsetsMs, <int>[80, 80, 160, 400, 400]);
        // 第二段只有 7 个输出帧：帧 9 的「。」被 out_lengths 截掉。
        expect(out[1].text, '「今日は');
      },
    );
  }

  test('导出没有图内 argmax 时退回读 logits', () async {
    final AsrCtcDecoder d = AsrCtcDecoder(
      model: _KitsuneSession(_plan, logitsOnly: true),
      tokens: tokens,
      nemoMel: _mel(),
    );
    final List<AsrDecodedSegment> out = await d.decodeBatch(<AsrSpeechSegment>[
      _segment(kAsrSampleRate),
    ]);
    expect(out.single.text, '「今日は。');
  });

  test('Kitsune 包：mel 前端、滤波器组随两种变体下载、JSON 往返', () {
    expect(kAsrKitsunePack.ctcFrontend, AsrCtcFrontend.nemoMel80);
    expect(kAsrModelPacks, isNot(contains(kAsrKitsunePack)));
    for (final AsrEncoderVariant v in AsrEncoderVariant.values) {
      expect(
        kAsrKitsunePack.filesFor(v).map((AsrModelFile f) => f.role),
        contains(AsrModelRole.melFilterbank),
      );
    }
    final AsrModelPack back = AsrModelPack.fromJson(
      jsonDecode(jsonEncode(kAsrKitsunePack.toJson())),
    );
    expect(back.ctcFrontend, AsrCtcFrontend.nemoMel80);
    expect(back.license, 'CC BY-NC 4.0');
    expect(back.blankToken, '<blank>');
    expect(kAsrOmnilingualPack.toJson(), isNot(contains('ctcFrontend')));
  });
}
