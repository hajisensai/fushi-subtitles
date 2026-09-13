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
  });
}
