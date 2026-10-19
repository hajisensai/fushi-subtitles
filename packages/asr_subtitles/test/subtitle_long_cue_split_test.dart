import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;
import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:test/test.dart';

SubtitleCue _cue(int startMs, int endMs, String text, {int index = 1}) =>
    SubtitleCue(index: index, startMs: startMs, endMs: endMs, text: text);

/// 每个字一个 token，开始时刻依次取 [offsetsMs]。
AsrCueTokenTiming _perChar(String text, List<int> offsetsMs) {
  final List<String> chars =
      text.runes.map(String.fromCharCode).toList(growable: false);
  expect(chars.length, offsetsMs.length, reason: '测试数据：每字一个偏移');
  return AsrCueTokenTiming(tokens: chars, offsetsMs: offsetsMs);
}

List<(int, int, String)> _flat(List<SubtitleCue> cues) => <(int, int, String)>[
      for (final SubtitleCue c in cues) (c.startMs, c.endMs, c.text),
    ];

/// asr_bench 真实数据（K-ON 第 1 集，`consA` 终稿 + 760M 词级时间戳只留起点，
/// 即 `transcript.tokens.jsonl` 能给的信息），`expected` 是 `subsplit.split_aligned`
/// 在同一份缩减输入上的输出。终稿经过 LLM 校对，与 token 文本不同
/// （ユイ→唯、良く→よく、ほう→方、キャッ! 被删）。
const List<
    ({
      int startMs,
      int endMs,
      String text,
      List<String> tokens,
      List<int> offsetsMs,
      List<(int, int, String)> expected,
    })> _realCues = <({
  int startMs,
  int endMs,
  String text,
  List<String> tokens,
  List<int> offsetsMs,
  List<(int, int, String)> expected,
})>[
  (
    startMs: 340130,
    endMs: 349100,
    text: 'うーん、安いのは1万円台からあるけど、あんまり安すぎるのもよくないからな。5万円くらいがいいかも',
    tokens: <String>[
      'う',
      'ーん、',
      '安',
      'い',
      'のは',
      '1',
      '万',
      '円',
      '台',
      'から',
      'ある',
      'けど、',
      'あ',
      'ん',
      'まり',
      '安',
      'す',
      'ぎ',
      'る',
      'の',
      'も',
      '良',
      'く',
      'ない',
      'から',
      'な。',
      '5',
      '万',
      '円',
      'く',
      'らい',
      'が',
      'いい',
      'か',
      'も'
    ],
    offsetsMs: <int>[
      0,
      100,
      960,
      1540,
      1800,
      2020,
      2240,
      2460,
      2660,
      2800,
      3020,
      3200,
      3740,
      4120,
      4260,
      4360,
      4620,
      4740,
      4880,
      4980,
      5080,
      5180,
      5320,
      5440,
      5640,
      5820,
      6680,
      7040,
      7180,
      7420,
      7600,
      7760,
      7940,
      8100,
      8280
    ],
    expected: <(int, int, String)>[
      (340130, 346810, 'うーん、安いのは1万円台からあるけど、あんまり安すぎるのもよくないからな。'),
      (346810, 349100, '5万円くらいがいいかも'),
    ],
  ),
  (
    startMs: 726390,
    endMs: 737090,
    text: 'やる前から無理だとかダメだとかばかり言ってる。唯のギターを買うためなのに。それは軽音部のためでもあるのに。乗り越えないと自分を。',
    tokens: <String>[
      'や',
      'る',
      '前',
      'から',
      '無',
      '理',
      'だ',
      'とか',
      'ダ',
      'メ',
      'だ',
      'とか',
      'ば',
      'か',
      'り',
      '言',
      'ってる。',
      'ユ',
      'イ',
      'の',
      'ギ',
      'ター',
      'を',
      '買',
      'う',
      'ため',
      'な',
      'の',
      'に。',
      'それは',
      '軽',
      '音',
      '部',
      'の',
      'ため',
      'でも',
      'ある',
      'の',
      'に。',
      '乗',
      'り',
      '越',
      'え',
      'ない',
      'と、',
      '自',
      '分',
      'を',
      '……'
    ],
    offsetsMs: <int>[
      0,
      100,
      200,
      380,
      560,
      780,
      900,
      1000,
      1160,
      1500,
      1520,
      1640,
      1800,
      2020,
      2160,
      2280,
      2380,
      3460,
      3740,
      3800,
      3840,
      4080,
      4120,
      4260,
      4380,
      4500,
      4660,
      4820,
      4960,
      5580,
      5860,
      6640,
      6720,
      6880,
      6980,
      7160,
      7360,
      7600,
      7720,
      8520,
      8800,
      8840,
      8940,
      9060,
      9140,
      9440,
      9980,
      10140,
      10280
    ],
    expected: <(int, int, String)>[
      (726390, 730130, 'やる前から無理だとかダメだとかばかり言ってる。'),
      (730130, 731970, '唯のギターを買うためなのに。'),
      (731970, 734910, 'それは軽音部のためでもあるのに。'),
      (734910, 737090, '乗り越えないと自分を。'),
    ],
  ),
  (
    startMs: 957540,
    endMs: 964830,
    text: '本当にありがとね！あたし、ギター買ったら……毎日練習するね！',
    tokens: <String>[
      '本当',
      'に',
      'あり',
      'が',
      'と',
      'ね!',
      'あ',
      'た',
      'し、',
      'ギ',
      'ター',
      '買',
      'った',
      'ら',
      '……',
      '毎',
      '日',
      '練',
      '習',
      'する',
      'ね',
      '〜!'
    ],
    offsetsMs: <int>[
      0,
      240,
      440,
      680,
      760,
      880,
      1620,
      2100,
      2260,
      2660,
      3280,
      3380,
      3620,
      3740,
      3940,
      4220,
      5300,
      5440,
      5740,
      6000,
      6240,
      6480
    ],
    expected: <(int, int, String)>[
      (957540, 959160, '本当にありがとね！'),
      (959160, 961760, 'あたし、ギター買ったら……'),
      (961760, 964830, '毎日練習するね！'),
    ],
  ),
];

void main() {
  group('不需要拆', () {
    test('7 s 与 40 字都不超（等于不算超）→ 原样', () {
      final SubtitleCue c = _cue(0, 7000, '${'あ' * 19}。${'い' * 19}。');
      expect(subtitleCueNeedsSplit(c), isFalse);
      expect(splitLongSubtitleCue(c), <SubtitleCue>[c]);
    });

    test('超长但只有一句、也没有 token 时间 → 原样', () {
      final SubtitleCue c = _cue(0, 9000, 'あいうえおかきくけこ');
      expect(splitLongSubtitleCue(c), <SubtitleCue>[c]);
    });
  });

  group('按句末拆', () {
    test('切点 = 下一句首字开始时刻（−0.1 s，但不早于上一字结束）', () {
      const String text = 'あいうえお。かきくけこ。';
      final List<SubtitleCue> out = splitLongSubtitleCue(
        _cue(10000, 18000, text),
        tokenTiming: _perChar(text, <int>[
          0, 200, 400, 600, 800, 1000, //
          5000, 5200, 5400, 5600, 5800, 6000,
        ]),
      );
      // sidecar 只有起点：「。」的终点就是「か」的起点，所以 −0.1 s 被「不早于
      // 上一字结束」顶回到 5000。
      expect(_flat(out), <(int, int, String)>[
        (10000, 15000, 'あいうえお。'),
        (15000, 18000, 'かきくけこ。'),
      ]);
    });

    test('多字 token 内部切：字符按 token 时长均分，切点落在 token 内部', () {
      // 一个 token 装了两句。字符时间首尾相接（上一字结束 = 下一字开始），所以
      // 「−0.1 s」照样被「不早于上一字结束」顶回去。
      const String text = 'あいうえお。かきくけこ。';
      final List<SubtitleCue> out = splitLongSubtitleCue(
        _cue(0, 8000, text),
        tokenTiming: AsrCueTokenTiming(
          tokens: <String>['あいうえお。かきくけこ。'],
          offsetsMs: <int>[0],
        ),
      );
      // 每字 8000/12 ms；「か」开始于 6 × 666.67 = 4000，减 100 = 3900，
      // 不早于「。」结束（= 4000）→ 仍是 4000。
      expect(out.map((SubtitleCue c) => c.startMs).toList(), <int>[0, 4000]);
    });

    test('碎片合并：短于 4 字的句子并进前一句', () {
      const String text = 'あいうえお。はい。かきくけこ。';
      final List<SubtitleCue> out = splitLongSubtitleCue(_cue(0, 14000, text));
      expect(out.map((SubtitleCue c) => c.text).toList(), <String>[
        'あいうえお。はい。',
        'かきくけこ。',
      ]);
      expect(subtitleSentenceCuts('えっ。そうなんだ。'), isEmpty,
          reason: '「えっ。」太短，后一句并进来');
    });

    test('句末后的闭合括号留在前一句', () {
      final List<SubtitleCue> out =
          splitLongSubtitleCue(_cue(0, 8000, '「行くよ。」「うん、わかった。」'));
      expect(out.map((SubtitleCue c) => c.text).toList(), <String>[
        '「行くよ。」',
        '「うん、わかった。」',
      ]);
    });

    test('LLM 改过的文本照样对齐到 token 时间（增删改都容忍）', () {
      // 识别稿「ユイの」→ 终稿「唯の」，「ほう」→「方」。
      const String spoken = 'ユイのギター。ほうがいいよ。';
      final List<SubtitleCue> out = splitLongSubtitleCue(
        _cue(0, 9000, '唯のギター。方がいいよ。'),
        tokenTiming: _perChar(spoken, <int>[
          0, 300, 600, 900, 1200, 1500, 1800, //
          6000, 6300, 6600, 6900, 7200, 7500, 7800,
        ]),
      );
      // 2 字换 1 字（ほう→方）时「方」对齐到后一个字「う」（6300），与原型的
      // rapidfuzz 对齐同一取向——真实数据里「ユイ→唯」也是对到「イ」，见下面
      // 真实数据第 2 条的 730130。
      expect(_flat(out), <(int, int, String)>[
        (0, 6300, '唯のギター。'),
        (6300, 9000, '方がいいよ。'),
      ]);
    });
  });

  group('无句末：在最长停顿处拆', () {
    test('最长的 token 起点间隔 ≥ 0.35 s → 在那里切', () {
      const String text = 'あいうえおかきくけこ';
      final List<SubtitleCue> out = splitLongSubtitleCue(
        _cue(0, 9000, text),
        tokenTiming: _perChar(text, <int>[
          0, 300, 600, 900, 1200, //
          4000, 4300, 4600, 4900, 5200,
        ]),
      );
      expect(_flat(out), <(int, int, String)>[
        (0, 4000, 'あいうえお'),
        (4000, 9000, 'かきくけこ'),
      ]);
    });

    test('最长间隔不到 0.35 s → 不切', () {
      const String text = 'あいうえおかきくけこ';
      final SubtitleCue c = _cue(0, 9000, text);
      expect(
        splitLongSubtitleCue(
          c,
          tokenTiming: _perChar(
            text,
            <int>[0, 300, 600, 900, 1200, 1500, 1800, 2100, 2400, 2700],
          ),
        ),
        <SubtitleCue>[c],
      );
    });

    test('只超字数、不超时长 → 不找停顿', () {
      final String text = 'あ' * 45;
      final SubtitleCue c = _cue(0, 5000, text);
      expect(
        splitLongSubtitleCue(
          c,
          tokenTiming: _perChar(
              text, List<int>.generate(45, (int i) => i < 20 ? i * 10 : 3000)),
        ),
        <SubtitleCue>[c],
      );
    });
  });

  group('没有 token 时间：按字数比例', () {
    test('切点 = 起点 + 时长 × 偏移 / 总字数', () {
      final List<SubtitleCue> out =
          splitLongSubtitleCue(_cue(1000, 13000, 'あいうえお。かきくけこ。'));
      expect(_flat(out), <(int, int, String)>[
        (1000, 7000, 'あいうえお。'),
        (7000, 13000, 'かきくけこ。'),
      ]);
    });
  });

  group('夹紧', () {
    test('切点夹在 [起点+0.3 s, 终点−0.3 s]，相邻至少隔 0.3 s', () {
      final List<SubtitleCue> out = splitLongSubtitleCue(
        _cue(0, 8000, 'あいうえ。かきくけ。さしすせ。'),
        tokenTiming: AsrCueTokenTiming(
          tokens: <String>['あいうえ。', 'かきくけ。', 'さしすせ。'],
          offsetsMs: <int>[0, 50, 100],
        ),
      );
      expect(_flat(out), <(int, int, String)>[
        (0, 300, 'あいうえ。'),
        (300, 600, 'かきくけ。'),
        (600, 8000, 'さしすせ。'),
      ]);
    });

    test('切点贴着终点：夹到终点前 0.3 s', () {
      final List<SubtitleCue> out = splitLongSubtitleCue(
        _cue(0, 8000, 'あいうえお。かきくけこ。'),
        tokenTiming: AsrCueTokenTiming(
          tokens: <String>['あいうえお。', 'かきくけこ。'],
          offsetsMs: <int>[0, 7950],
        ),
      );
      expect(out.map((SubtitleCue c) => c.startMs).toList(), <int>[0, 7700]);
    });

    test('切点被挤出 cue 之外 → 丢掉该切点（相邻两片合并），不出负时长', () {
      const String sentence = 'あいうえおかきく。';
      final List<SubtitleCue> out = splitLongSubtitleCue(
        _cue(0, 1000, sentence * 5),
        tokenTiming: AsrCueTokenTiming(
          tokens: <String>[sentence, sentence, sentence, sentence, sentence],
          offsetsMs: <int>[0, 1, 2, 3, 4],
        ),
      );
      expect(_flat(out), <(int, int, String)>[
        (0, 300, sentence),
        (300, 600, sentence),
        (600, 900, sentence),
        (900, 1000, sentence * 2),
      ]);
    });
  });

  group('真实数据：与 Python 原型逐条一致', () {
    for (final ({
      int startMs,
      int endMs,
      String text,
      List<String> tokens,
      List<int> offsetsMs,
      List<(int, int, String)> expected,
    }) c in _realCues) {
      test('${c.startMs} ms', () {
        final List<SubtitleCue> out = splitLongSubtitleCue(
          _cue(c.startMs, c.endMs, c.text),
          tokenTiming:
              AsrCueTokenTiming(tokens: c.tokens, offsetsMs: c.offsetsMs),
        );
        expect(_flat(out), c.expected);
      });
    }
  });

  group('splitLongSubtitleCues', () {
    test('整份拆完重新编号；token 行与 cue 一一对应', () {
      final List<SubtitleCue> out = splitLongSubtitleCues(
        <SubtitleCue>[
          _cue(0, 2000, 'こんにちは。', index: 1),
          _cue(3000, 15000, 'あいうえお。かきくけこ。', index: 2),
          _cue(16000, 17000, 'うん。', index: 3),
        ],
        tokenTimings: <AsrCueTokenTiming?>[null, null, null],
      );
      expect(
        out.map((SubtitleCue c) => (c.index, c.text)).toList(),
        <(int, String)>[
          (1, 'こんにちは。'),
          (2, 'あいうえお。'),
          (3, 'かきくけこ。'),
          (4, 'うん。'),
        ],
      );
    });

    test('token 行数与 cue 数不符 → 抛（错位比没有更糟）', () {
      expect(
        () => splitLongSubtitleCues(
          <SubtitleCue>[_cue(0, 1000, 'あ')],
          tokenTimings: const <AsrCueTokenTiming?>[],
        ),
        throwsArgumentError,
      );
    });
  });

  test('normalizeSubtitlePunctuationToFullWidth：只把 ! ? 换成全角', () {
    expect(
      normalizeSubtitlePunctuationToFullWidth('え!? 本当? すごい!…, ok.'),
      'え！？ 本当？ すごい！…, ok.',
    );
  });
}
