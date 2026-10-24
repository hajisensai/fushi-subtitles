// AsrCuePostProcessor 的行为测试：从 Fushi 的 cue_energy_snapper_test /
// cue_display_margins_test / cue_fragment_merger_test 搬来，改走本包的原生链路。
// 原生库是硬依赖：找不到库时这些测试失败，不 skip。
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:test/test.dart';

/// 20 ms 一帧：默认 [fill]，[spans] 里的毫秒区间换成 [spanDb]。
Int8List _energy(int totalMs, List<(int, int)> spans, {bool voiced = true}) {
  final int fill = voiced ? -20 : -70;
  final int spanDb = voiced ? -70 : -20;
  final Int8List e = Int8List(totalMs ~/ 20)..fillRange(0, totalMs ~/ 20, fill);
  for (final (int a, int b) in spans) {
    e.fillRange(a ~/ 20, b ~/ 20, spanDb);
  }
  return e;
}

AsrPostCue _cue(
  int start,
  int end, {
  String text = 'x',
  List<int>? offsets,
  int section = -1,
  int from = -1,
  int to = -1,
  int file = 0,
}) =>
    AsrPostCue(
      startMs: start,
      endMs: end,
      audioFileIndex: file,
      text: text,
      tokenOffsetsMs: offsets,
      sectionIndex: section,
      normCharStart: from,
      normCharEnd: to,
    );

const Set<AsrCuePostStage> _snapOnly = <AsrCuePostStage>{AsrCuePostStage.snap};
const Set<AsrCuePostStage> _refineOnly = <AsrCuePostStage>{
  AsrCuePostStage.refineEdges,
};
const Set<AsrCuePostStage> _mergeOnly = <AsrCuePostStage>{
  AsrCuePostStage.mergeFragments,
};
const Set<AsrCuePostStage> _marginsOnly = <AsrCuePostStage>{
  AsrCuePostStage.displayMargins,
};

List<(int, int)> _times(AsrCuePostResult r) => <(int, int)>[
      for (final AsrPostCueGroup g in r.groups) (g.startMs, g.endMs),
    ];

void main() {
  final AsrCuePostProcessor post = AsrCuePostProcessor();

  test('原生库可加载且 ABI 对得上', () {
    final AsrCuePostLibrary lib = AsrCuePostLibrary.instance;
    expect(AsrCuePostLibrary.bindError(lib.library), isNull);
  });

  group('snap', () {
    test('紧挨着的切点吸到停顿：前句收在谷起点 + 80，后句从谷终点 − 40 起', () {
      // 真实停顿在 [2300, 2700)，token 推算的切点在 2000。
      final AsrCuePostResult r = AsrCuePostProcessor(
        snap: const AsrEnergySnapOptions(cutBiasMs: 0),
      ).process(
        <AsrPostCue>[_cue(0, 2000), _cue(2000, 5000)],
        _energy(6000, <(int, int)>[(2300, 2700)]),
        stages: _snapOnly,
      );
      expect(r.snappedBoundaries, 1);
      expect(_times(r), <(int, int)>[(0, 2380), (2660, 5000)]);
    });

    test('附近没有足够长的停顿（只有 60 ms 的塞音闭塞）：不动', () {
      final AsrCuePostResult r = post.process(
        <AsrPostCue>[_cue(0, 2000), _cue(2000, 5000)],
        _energy(6000, <(int, int)>[(2000, 2060)]),
        stages: _snapOnly,
      );
      expect(r.snappedBoundaries, 0);
      expect(_times(r), <(int, int)>[(0, 2000), (2000, 5000)]);
    });

    test('两条 cue 之间已有 VAD 切开的大空隙：不动', () {
      final AsrCuePostResult r = post.process(
        <AsrPostCue>[_cue(0, 2000), _cue(2600, 5000)],
        _energy(6000, <(int, int)>[(2100, 2500)]),
        stages: _snapOnly,
      );
      expect(r.snappedBoundaries, 0);
    });

    test('谷远在后句首 token + tokenGuardMs 之后：吸过去会吃掉字头，不动', () {
      final AsrCuePostResult r = AsrCuePostProcessor(
        snap: const AsrEnergySnapOptions(tokenGuardMs: 200),
      ).process(
        <AsrPostCue>[
          _cue(0, 2000),
          _cue(2000, 5000, offsets: <int>[50]),
        ],
        _energy(6000, <(int, int)>[(2400, 2600)]),
        stages: _snapOnly,
      );
      expect(r.snappedBoundaries, 0);
      expect(r.groups[1].startMs, 2000);
    });

    test('默认：RNN-T 首 token 比开口早几百毫秒，真实停顿照样吸过去', () {
      // token 推算的切点 2000，真实句间停顿 [2400, 2600)，首 token 2050（偏早）。
      final AsrCuePostResult r = post.process(
        <AsrPostCue>[
          _cue(0, 2000),
          _cue(2000, 5000, offsets: <int>[50, 900]),
        ],
        _energy(6000, <(int, int)>[(2400, 2600)]),
        stages: _snapOnly,
      );
      expect(r.snappedBoundaries, 1);
      expect(_times(r), <(int, int)>[(0, 2480), (2560, 5000)]);
      // 起点后挪 560：token 偏移跟着平移、夹到 ≥ 0。
      expect(r.groups[1].tokenOffsetsMs, <int>[0, 340]);
    });

    test('吸附后一侧短于 500 ms：不动', () {
      final AsrCuePostResult r = post.process(
        <AsrPostCue>[_cue(0, 2000), _cue(2000, 2800)],
        _energy(3000, <(int, int)>[(2300, 2500)]),
        stages: _snapOnly,
      );
      expect(r.snappedBoundaries, 0);
    });

    test('包络未知（0）的帧按有声处理，不会凭空造谷', () {
      final AsrCuePostResult r = post.process(
        <AsrPostCue>[_cue(0, 2000), _cue(2000, 5000)],
        Int8List(300),
        stages: _snapOnly,
      );
      expect(r.snappedBoundaries, 0);
    });
  });

  group('refineEdges', () {
    AsrCuePostResult refine(
      AsrPostCue cue,
      Int8List energy, {
      AsrCuePostProcessor? processor,
    }) =>
        (processor ?? post).process(
          <AsrPostCue>[cue],
          energy,
          stages: _refineOnly,
        );

    test('起点落在静音里：挪到开口 − 150 ms', () {
      final AsrCuePostResult r = refine(
        _cue(1000, 4000),
        _energy(6000, <(int, int)>[(0, 1500)]),
      );
      expect(r.refinedEdges, 1);
      expect(_times(r), <(int, int)>[(1350, 4000)]);
    });

    test('终点落在静音里：收到收声 + 80 ms', () {
      final AsrCuePostResult r = refine(
        _cue(1000, 4000),
        _energy(6000, <(int, int)>[(3500, 6000)]),
      );
      expect(r.refinedEdges, 1);
      expect(r.groups.single.endMs, 3580);
    });

    test('开口在 600 ms 之外：不动', () {
      final AsrCuePostResult r = refine(
        _cue(1000, 4000),
        _energy(6000, <(int, int)>[(0, 2000)]),
      );
      expect(r.refinedEdges, 0);
      expect(r.groups.single.startMs, 1000);
    });

    test('静音里 40 ms 的噪声尖峰不算开口', () {
      final Int8List e = _energy(6000, <(int, int)>[(0, 1500)])
        ..fillRange(1100 ~/ 20, 1140 ~/ 20, -20);
      expect(refine(_cue(1000, 4000), e).groups.single.startMs, 1350);
    });

    test('收终点会早于末 token − tokenGuardMs：不动', () {
      // 收声 3500 → 本该收到 3580，但末 token 在 3900（守卫线 3700）。
      final AsrCuePostResult r = refine(
        _cue(1000, 4000, offsets: <int>[0, 2900]),
        _energy(6000, <(int, int)>[(3500, 6000)]),
        processor: AsrCuePostProcessor(
          snap: const AsrEnergySnapOptions(tokenGuardMs: 200),
        ),
      );
      expect(r.refinedEdges, 0);
      expect(r.groups.single.endMs, 4000);
    });

    test('收完短于 500 ms：不动', () {
      final AsrCuePostResult r = refine(
        _cue(1000, 1800),
        _energy(3000, <(int, int)>[(0, 1500)]),
      );
      expect(r.refinedEdges, 0);
    });
  });

  group('mergeFragments', () {
    AsrCuePostResult merge(
      List<AsrPostCue> cues, {
      AsrCuePostProcessor? processor,
    }) =>
        (processor ?? post).process(cues, Int8List(0), stages: _mergeOnly);

    test('句内短碎片并进下一条：文本、区间、token 时间首尾相接', () {
      final AsrCuePostResult r = merge(<AsrPostCue>[
        _cue(1000, 1500,
            text: '何か、', offsets: <int>[0, 200], section: 0, from: 0, to: 2),
        _cue(1800, 3000,
            text: 'おかしい。', offsets: <int>[0, 300], section: 0, from: 2, to: 6),
      ]);
      expect(r.mergedFragments, 1);
      final AsrPostCueGroup g = r.groups.single;
      expect((g.firstIndex, g.lastIndex, g.isMerged), (0, 1, true));
      expect(g.text, '何か、おかしい。');
      expect((g.startMs, g.endMs), (1000, 3000));
      expect(g.tokenOffsetsMs, <int>[0, 200, 800, 1100]);
    });

    test('任一条没有 token 时间：合并后也没有', () {
      final AsrCuePostResult r = merge(<AsrPostCue>[
        _cue(0, 500,
            text: 'だが、', offsets: <int>[0], section: 0, from: 0, to: 3),
        _cue(600, 1500, text: 'つづき。', section: 0, from: 3, to: 7),
      ]);
      expect(r.groups.single.tokenOffsetsMs, isNull);
    });

    test('前一条是句末、两侧都够长、停顿太长、跨章或区间不相接时不并', () {
      int count(String a, int aEnd, int bStart, int bEnd,
              {int s2 = 0, int from2 = 2}) =>
          merge(<AsrPostCue>[
            _cue(0, aEnd, text: a, section: 0, from: 0, to: 2),
            _cue(bStart, bEnd, text: 'つづき。', section: s2, from: from2, to: 6),
          ]).mergedFragments;

      expect(count('はい。', 500, 600, 1500), 0);
      expect(count('はい」', 500, 600, 1500), 0);
      expect(count('だが、', 2000, 2100, 4000), 0);
      expect(count('だが、', 500, 2600, 3000), 0);
      expect(count('だが、', 500, 600, 1500, s2: 1), 0);
      expect(count('だが、', 500, 600, 1500, from2: 3), 0);
      expect(count('だが、', 500, 600, 1500), 1);
    });

    test('未命中 / 跨音频文件的 cue 不参与', () {
      expect(
        merge(<AsrPostCue>[
          _cue(0, 500, text: 'だが、', section: 0, from: 0, to: 2),
          _cue(600, 900, text: 'うん'),
        ]).mergedFragments,
        0,
      );
      expect(
        merge(<AsrPostCue>[
          _cue(0, 500, text: 'だが、', section: 0, from: 0, to: 2),
          _cue(600, 900, text: 'うん', section: 0, from: 2, to: 4, file: 1),
        ]).mergedFragments,
        0,
      );
    });

    test('拉丁缩写后的句点不算句末：Ｍｓ．并进名字；全角句点算', () {
      int count(String a) => merge(<AsrPostCue>[
            _cue(0, 500, text: a, section: 0, from: 0, to: 3),
            _cue(600, 1500, text: 'ヒビヤ。', section: 0, from: 3, to: 7),
          ]).mergedFragments;
      expect(count('Ｍｓ．'), 1);
      expect(count('Mr.'), 1);
      expect(count('そうだ．'), 0);
      expect(count('だが──'), 1);
      expect(count('「む？」'), 0);
    });

    test('连锁合并多段，但不超过字数上限', () {
      final List<AsrPostCue> cues = <AsrPostCue>[
        _cue(0, 400, text: 'あ、', section: 0, from: 0, to: 1),
        _cue(500, 900, text: 'い、', section: 0, from: 1, to: 2),
        _cue(1000, 1400, text: 'う。', section: 0, from: 2, to: 3),
      ];
      expect(merge(cues).groups.single.text, 'あ、い、う。');
      final AsrCuePostResult r2 = merge(
        cues,
        processor: AsrCuePostProcessor(
          merge: const AsrFragmentMergeOptions(maxChars: 4),
        ),
      );
      expect(
        r2.groups.map((AsrPostCueGroup g) => g.text),
        <String>['あ、い、', 'う。'],
      );
    });
  });

  group('displayMargins', () {
    final Int8List energy = _energy(
        9000,
        <(int, int)>[
          (1000, 3000),
          (5000, 7000),
        ],
        voiced: false);

    test('慢语速前后各留一段，token 绝对时刻不变', () {
      // 「ゆっくり話す。」6 个发音字 / 2 s = 3 cps → 慢档：头 120、尾封顶 250。
      final AsrCuePostResult r = post.process(<AsrPostCue>[
        _cue(1000, 3080, text: 'ゆっくり話す。', offsets: <int>[0, 500]),
        _cue(5000, 7080, text: '次の文。'),
      ], energy, stages: _marginsOnly);
      expect(r.displayMarginEdges, 4);
      expect(_times(r), <(int, int)>[(880, 3250), (4880, 7250)]);
      expect(r.groups[0].tokenOffsetsMs, <int>[120, 620]);
    });

    test('快语速几乎不加：终点保持吸附结果', () {
      // 24 个发音字 / 2 s = 12 cps → 快档：头 40，尾 20（原终点更晚，不内收）。
      final AsrCuePostResult r = post.process(<AsrPostCue>[
        _cue(1000, 3080, text: 'あいうえおかきくけこさしすせそたちつてとなにぬね'),
      ], energy, stages: _marginsOnly);
      expect(_times(r), <(int, int)>[(960, 3080)]);
    });

    test('字速只数字母 / 数字 / 假名 / 汉字：标点再多也是慢档', () {
      // 「──何か、おかしい。」只有 6 个发音字 → 3 cps 慢档（按全部码元算会是快档）。
      final AsrCuePostResult r = post.process(<AsrPostCue>[
        _cue(1000, 3080, text: '「──何か、おかしい。」……………………………'),
      ], energy, stages: _marginsOnly);
      expect(r.groups.single.startMs, 880);
    });

    test('没有包络不动', () {
      final AsrCuePostResult r = post.process(<AsrPostCue>[
        _cue(1000, 2000, text: 'はい。'),
      ], Int8List(0), stages: _marginsOnly);
      expect(r.displayMarginEdges, 0);
      expect(_times(r), <(int, int)>[(1000, 2000)]);
    });
  });

  test('参数非法抛 ArgumentError', () {
    expect(
      () => AsrCuePostProcessor(
        margins: const AsrDisplayMarginOptions(slowCps: 8),
      ).process(<AsrPostCue>[_cue(0, 1000)], Int8List(10)),
      throwsArgumentError,
    );
    expect(
      () => AsrCuePostProcessor(
        snap: const AsrEnergySnapOptions(frameMs: 0),
      ).process(<AsrPostCue>[_cue(0, 1000)], Int8List(10)),
      throwsArgumentError,
    );
  });

  test('没有 cue：空结果', () {
    final AsrCuePostResult r = post.process(<AsrPostCue>[], Int8List(100));
    expect(r.groups, isEmpty);
    expect(r.mergedFragments, 0);
  });
}
