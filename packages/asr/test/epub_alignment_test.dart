import 'package:fushi_asr/asr.dart';
import 'package:fushi_asr_align/asr_align.dart';
import 'package:test/test.dart';

void main() {
  test(
      'replaces matched text with book punctuation, preserves unmatched text and native timings',
      () async {
    final book = EpubBook(title: 'Example', language: 'ja', sections: [
      EpubSection(index: 0, href: 'ch.xhtml', text: '今日はいい天気ですね。明日は学校へ行きます。')
    ]);
    final original = TranscribeOutcome(
        text: 'unused',
        cues: [
          SubtitleCue(index: 1, startMs: 100, endMs: 2000, text: '今日はいい天気ですね'),
          SubtitleCue(
              index: 2, startMs: 2200, endMs: 3200, text: 'XXXXXXXXXXXXXXXX'),
        ],
        elapsed: Duration.zero,
        audioMs: 4000,
        engine: 'apple-speechtranscriber');
    final aligned =
        await alignTranscriptionWithBook(book, original, SubtitleFormat.srt);
    final cues = parseSrt(aligned.text);
    expect(cues.first.text, '今日はいい天気ですね。');
    expect(cues.first.startMs, 100);
    expect(cues.first.endMs, 2000);
    expect(cues.last.text, 'XXXXXXXXXXXXXXXX');
    expect(aligned.stats['matchedCues'], 1);
    expect(aligned.stats['unmatchedCues'], 1);
    expect(aligned.stats['timingMode'], 'segment-preserved');
    expect(original.cues.first.text, '今日はいい天気ですね');
  });

  group('alignCuesWithBook', () {
    // 正文三句；听写一条 cue 横跨第二、三句且没有句号。
    final book = EpubBook(title: 'Example', language: 'ja', sections: [
      const EpubSection(
          index: 0, href: 'ch.xhtml', text: 'たとえば、夢見る時がある。転入生がやってくる。その子は素敵な子。')
    ]);
    const String heard = '夢見る時がある転入生がやってくる';
    final cues = [
      const SubtitleCue(index: 1, startMs: 10000, endMs: 13500, text: heard),
    ];
    final timing = AsrCueTokenTiming(tokens: heard.split(''), offsetsMs: [
      for (int i = 0; i < 7; i++) 100 + i * 100,
      for (int i = 0; i < 9; i++) 2000 + i * 100,
    ]);

    test('with per-token timing: resegments at book sentence boundary',
        () async {
      final aligned =
          await alignCuesWithBook(book, cues, [timing], SubtitleFormat.srt);
      final out = parseSrt(aligned.text);
      expect(out.map((c) => c.text), ['夢見る時がある。', '転入生がやってくる。']);
      expect(out.first.startMs, 10000);
      expect(out.last.endMs, 13500);
      expect(aligned.stats['timingMode'], 'token-resegmented');
      expect(aligned.stats['boundariesAdded'], 1);
    });

    test('without timing: text replaced, cue count and timings unchanged',
        () async {
      final aligned =
          await alignCuesWithBook(book, cues, null, SubtitleFormat.srt);
      final out = parseSrt(aligned.text);
      expect(out, hasLength(1));
      expect(out.single.text, '夢見る時がある。転入生がやってくる。');
      expect(out.single.startMs, 10000);
      expect(out.single.endMs, 13500);
      expect(aligned.stats['timingMode'], 'segment-preserved');
    });

    test('timing list length != cue count: none attached, reported honestly',
        () async {
      final aligned = await alignCuesWithBook(
          book, cues, [timing, timing], SubtitleFormat.srt);
      expect(parseSrt(aligned.text), hasLength(1));
      expect(aligned.stats['timingMode'], 'segment-preserved');
    });

    test('alignTranscriptionWithBook is the same path fed from an outcome',
        () async {
      final outcome = TranscribeOutcome(
          text: 'unused',
          cues: cues,
          tokenTimings: [timing],
          elapsed: Duration.zero,
          audioMs: 14000);
      final a =
          await alignTranscriptionWithBook(book, outcome, SubtitleFormat.srt);
      final b =
          await alignCuesWithBook(book, cues, [timing], SubtitleFormat.srt);
      expect(a.text, b.text);
    });

    test('matches: one per output cue, positions in the book, unmatched = -1',
        () async {
      final noise = [
        ...cues,
        const SubtitleCue(
            index: 2, startMs: 20000, endMs: 21000, text: 'zzzz qqqq xxxx'),
      ];
      final aligned =
          await alignCuesWithBook(book, noise, null, SubtitleFormat.srt);
      final out = parseSrt(aligned.text);
      expect(aligned.matches, hasLength(out.length));
      final CueMatch hit = aligned.matches.first;
      expect(hit.matched, isTrue);
      expect(hit.sectionIndex, 0);
      // 归一化正文里「夢見る時がある。転入生がやってくる。」的区间：起点在
      // 「たとえば、」之后，终点不超过本节长度。
      expect(hit.normCharStart, greaterThan(0));
      expect(hit.normCharEnd, greaterThan(hit.normCharStart));
      expect(
          hit.normCharEnd, lessThanOrEqualTo(book.sections.single.text.length));
      expect(aligned.matches.last, same(CueMatch.unmatched));
      expect(out.last.text, 'zzzz qqqq xxxx', reason: '未命中保留听写');
    });

    test('default options: auto-probe over 50/200/350, stats say which won',
        () async {
      final aligned =
          await alignCuesWithBook(book, cues, null, SubtitleFormat.srt);
      final probe = aligned.stats['probeWindows'] as Map<String, Object?>;
      expect(probe.keys, unorderedEquals(['50', '200', '350']));
      expect(EpubCueMatcher.defaultProbeWindows,
          contains(aligned.stats['searchWindow']));
      expect(aligned.stats['similarityThreshold'],
          EpubSrtMatcher.defaultSimilarityThreshold);
    });

    test('explicit window: no probe, stats echo the parameters', () async {
      final aligned = await alignCuesWithBook(
          book, cues, null, SubtitleFormat.srt,
          options: const BookAlignOptions(
              searchWindow: 120,
              similarityThreshold: 0.9,
              maxConsecutiveMisses: 7));
      expect(aligned.stats['searchWindow'], 120);
      expect(aligned.stats['probeWindows'], isNull);
      expect(aligned.stats['similarityThreshold'], 0.9);
      expect(aligned.stats['maxConsecutiveMisses'], 7);
      expect(parseSrt(aligned.text).single.text, '夢見る時がある。転入生がやってくる。');
    });
  });
}
