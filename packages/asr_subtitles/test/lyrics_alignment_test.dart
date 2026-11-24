import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;
import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:test/test.dart';

class _Transcription implements RetimingTranscription {
  const _Transcription(this.cues, this.tokenTimings);

  @override
  final List<SubtitleCue> cues;

  @override
  final List<AsrCueTokenTiming>? tokenTimings;
}

RetimingTranscription asr(List<(String, int, int)> cues,
        {List<AsrCueTokenTiming>? tokens}) =>
    _Transcription(<SubtitleCue>[
      for (int i = 0; i < cues.length; i++)
        SubtitleCue(
            index: i + 1,
            startMs: cues[i].$2,
            endMs: cues[i].$3,
            text: cues[i].$1),
    ], tokens);

List<int?> starts(LyricsAlignment a) =>
    <int?>[for (final AlignedLyricsLine l in a.lines) l.startMs];

void expectNear(int? actual, int expected, {int tolerance = 300}) {
  expect(actual, isNotNull);
  expect((actual! - expected).abs(), lessThanOrEqualTo(tolerance),
      reason: 'expected ~$expected, got $actual');
}

void expectMonotonic(LyricsAlignment a) {
  final List<AlignedLyricsLine> sung = <AlignedLyricsLine>[
    for (final AlignedLyricsLine l in a.lines)
      if (l.kind == LyricsLineKind.sung) l,
  ];
  for (int i = 0; i < sung.length; i++) {
    expect(sung[i].startMs, isNotNull);
    expect(sung[i].endMs! > sung[i].startMs!, isTrue);
    if (i > 0) {
      expect(sung[i].startMs! > sung[i - 1].startMs!, isTrue,
          reason: 'line ${sung[i].index} starts before the previous line');
      expect(sung[i - 1].endMs! <= sung[i].startMs!, isTrue,
          reason: 'line ${sung[i - 1].index} overlaps the next line');
    }
  }
}

void main() {
  test('identical text: every line anchored at its cue', () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>['きみのなまえをよんだ', 'とおいそらのしたで', 'またあえるひまで'],
      asr(<(String, int, int)>[
        ('きみのなまえをよんだ', 12000, 15000),
        ('とおいそらのしたで', 16000, 19000),
        ('またあえるひまで', 21000, 24000),
      ]),
    );
    expect(a.isReliable, isTrue);
    expect(a.anchoredLines, 3);
    expectNear(a.lines[0].startMs, 12000, tolerance: 50);
    expectNear(a.lines[1].startMs, 16000, tolerance: 50);
    expectNear(a.lines[2].startMs, 21000, tolerance: 50);
    expectMonotonic(a);
  });

  test('sustained notes and long-vowel marks do not break the match', () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>['あいたいよ', 'ずっとそばにいて', 'はなさないで'],
      asr(<(String, int, int)>[
        ('あいたいよおおおー', 5000, 9000),
        ('ずっとそばにいてええ', 10000, 14000),
        ('はなさないでーーー', 15000, 19000),
      ]),
    );
    expect(a.anchoredLines, 3);
    expectNear(a.lines[0].startMs, 5000, tolerance: 100);
    expectNear(a.lines[1].startMs, 10000, tolerance: 100);
    expectNear(a.lines[2].startMs, 15000, tolerance: 100);
  });

  test('backing vocals in the transcript and unsung harmony in the lyrics', () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>[
        'きょうもあしたもうたうよ（ラララ）',
        '(Oh yeah) ほしがながれるよる',
        'てをつないであるこう',
      ],
      asr(<(String, int, int)>[
        ('きょうもあしたもうたうよ', 3000, 7000),
        ('ふぉーふぉー', 7200, 8000), // 背景喊声，歌词里没有
        ('ほしがながれるよる', 9000, 12000),
        ('てをつないで', 13000, 15000),
        ('はいはい', 15100, 15500), // 和声
        ('あるこう', 15600, 17000),
      ]),
    );
    expect(a.anchoredLines, 3);
    expectNear(a.lines[0].startMs, 3000, tolerance: 100);
    // 行首括号里的英文没被识别：起点按字速往前推一点，但不会跑到上一行之前。
    expect(a.lines[1].startMs! > a.lines[0].startMs!, isTrue);
    expectNear(a.lines[1].startMs, 9000, tolerance: 2500);
    expectNear(a.lines[2].startMs, 13000, tolerance: 100);
    expectMonotonic(a);
  });

  test('a repeated chorus lands on its own repetition', () {
    const String chorus = 'さくらまうはるのひに';
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>['ひとりきりのよるをこえて', chorus, 'なつのかぜがふいたあと', chorus],
      asr(<(String, int, int)>[
        ('ひとりきりのよるをこえて', 10000, 14000),
        (chorus, 15000, 19000),
        ('なつのかぜがふいたあと', 40000, 44000),
        (chorus, 45000, 49000),
      ]),
    );
    expect(a.anchoredLines, 4);
    expectNear(a.lines[1].startMs, 15000, tolerance: 50);
    expectNear(a.lines[3].startMs, 45000, tolerance: 50);
  });

  test('a chorus sung more times than written: monotonic, later lines follow',
      () {
    const String chorus = 'さくらまうはるのひに';
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>['ひとりきりのよるをこえて', chorus, 'なつのかぜがふいたあと'],
      asr(<(String, int, int)>[
        ('ひとりきりのよるをこえて', 10000, 14000),
        (chorus, 15000, 19000),
        (chorus, 20000, 24000), // 歌词只写了一遍
        ('なつのかぜがふいたあと', 40000, 44000),
      ]),
    );
    expect(a.anchoredLines, 3);
    expectNear(a.lines[0].startMs, 10000, tolerance: 50);
    expect(
        a.lines[1].startMs! >= 15000 && a.lines[1].startMs! <= 20000, isTrue);
    expectNear(a.lines[2].startMs, 40000, tolerance: 50);
    expectMonotonic(a);
  });

  test('section markers and blank lines get no time', () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>[
        '[Verse 1]',
        'きみのなまえをよんだ',
        '',
        '【サビ】',
        'とおいそらのしたで',
        '♪',
      ],
      asr(<(String, int, int)>[
        ('きみのなまえをよんだ', 12000, 15000),
        ('とおいそらのしたで', 16000, 19000),
      ]),
    );
    expect(<LyricsLineKind>[
      for (final l in a.lines) l.kind
    ], <LyricsLineKind>[
      LyricsLineKind.marker,
      LyricsLineKind.sung,
      LyricsLineKind.blank,
      LyricsLineKind.marker,
      LyricsLineKind.sung,
      LyricsLineKind.marker,
    ]);
    expect(starts(a)[0], isNull);
    expect(starts(a)[2], isNull);
    expect(starts(a)[3], isNull);
    expect(starts(a)[5], isNull);
    expect(a.lines[0].timing, LyricsLineTiming.none);
    expectNear(a.lines[1].startMs, 12000, tolerance: 50);
    expectNear(a.lines[4].startMs, 16000, tolerance: 50);
    expect(a.sungLines, 2);
  });

  test('kanji lyrics against kana transcript: lines between anchors estimated',
      () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>[
        'きみのなまえをよんだ',
        '遠い空',
        'またあえるひまで',
      ],
      asr(<(String, int, int)>[
        ('きみのなまえをよんだ', 12000, 15000),
        ('とおいそら', 17000, 19000),
        ('またあえるひまで', 21000, 24000),
      ]),
    );
    expect(a.lines[0].timing, LyricsLineTiming.anchored);
    expect(a.lines[1].timing, LyricsLineTiming.estimated);
    expect(a.lines[2].timing, LyricsLineTiming.anchored);
    expect(a.lines[1].startMs! >= 15000 && a.lines[1].startMs! < 21000, isTrue,
        reason: 'got ${a.lines[1].startMs}');
    expectMonotonic(a);
  });

  test('intro chatter and outro are skipped for free', () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>['きみのなまえをよんだ', 'とおいそらのしたで'],
      asr(<(String, int, int)>[
        ('ありがとうございます', 0, 3000),
        ('きみのなまえをよんだ', 30000, 33000),
        ('とおいそらのしたで', 34000, 37000),
        ('ありがとう', 200000, 202000),
      ]),
    );
    expectNear(a.lines[0].startMs, 30000, tolerance: 50);
    expectNear(a.lines[1].startMs, 34000, tolerance: 50);
    expect(a.lines[1].endMs! <= 40000, isTrue);
  });

  test('a different song is reported as unreliable', () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>['きみのなまえをよんだ', 'とおいそらのしたで', 'またあえるひまで'],
      asr(<(String, int, int)>[
        ('ぜんぜんちがううたです', 1000, 4000),
        ('なにもかさならない', 5000, 8000),
      ]),
    );
    expect(a.isReliable, isFalse);
    expectMonotonic(a);
  });

  test('lines before the first anchor pack right against it', () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>['序', 'きみのなまえをよんだ', 'とおいそらのしたで'],
      asr(<(String, int, int)>[
        ('きみのなまえをよんだ', 60000, 63000),
        ('とおいそらのしたで', 64000, 67000),
      ]),
    );
    expect(a.lines[0].timing, LyricsLineTiming.estimated);
    expect(a.lines[0].startMs! > 55000, isTrue,
        reason: 'a short unmatched first line should sit just before the '
            'first anchored line, not at 0 (got ${a.lines[0].startMs})');
    expectMonotonic(a);
  });

  test('token timings place a line that starts mid-cue', () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>['きみのなまえ', 'そらのしたで'],
      asr(
        <(String, int, int)>[('きみのなまえそらのしたで', 10000, 20000)],
        tokens: <AsrCueTokenTiming>[
          AsrCueTokenTiming(
            tokens: <String>['きみの', 'なまえ', 'そらの', 'したで'],
            offsetsMs: <int>[0, 1000, 7000, 8000],
          ),
        ],
      ),
    );
    expectNear(a.lines[0].startMs, 10000, tolerance: 50);
    expectNear(a.lines[1].startMs, 17000, tolerance: 50);
  });

  test('Latin lyrics are case- and punctuation-insensitive', () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>['Hello, darkness, my old friend', "I've come to talk again"],
      asr(<(String, int, int)>[
        ('hello darkness my old friend', 2000, 6000),
        ('ive come to talk again', 7000, 10000),
      ]),
    );
    expect(a.anchoredLines, 2);
    expectNear(a.lines[0].startMs, 2000, tolerance: 50);
    expectNear(a.lines[1].startMs, 7000, tolerance: 50);
  });

  test('empty transcript: everything estimated and unreliable', () {
    final LyricsAlignment a = alignLyricsToTranscriptSync(
      <String>['きみのなまえをよんだ', 'とおいそらのしたで'],
      asr(const <(String, int, int)>[]),
      durationMs: 60000,
    );
    expect(a.isReliable, isFalse);
    expectMonotonic(a);
  });

  test('rejects oversized input instead of allocating the table', () {
    final String long = 'あい' * 4000;
    expect(
      () => alignLyricsToTranscriptSync(
        <String>[long],
        asr(<(String, int, int)>[(('かき' * 6000), 0, 1000)]),
      ),
      throwsFormatException,
    );
  });

  test('background isolate entry point returns the same result', () async {
    final RetimingTranscription t = asr(<(String, int, int)>[
      ('きみのなまえをよんだ', 12000, 15000),
      ('とおいそらのしたで', 16000, 19000),
    ]);
    final List<String> lines = <String>['きみのなまえをよんだ', 'とおいそらのしたで'];
    final LyricsAlignment sync = alignLyricsToTranscriptSync(lines, t);
    final LyricsAlignment async = await alignLyricsToTranscript(lines, t,
        cancellation: TranscribeCancellation());
    expect(starts(async), starts(sync));
  });
}
