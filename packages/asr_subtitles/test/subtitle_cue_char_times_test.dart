import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;
import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:test/test.dart';

SubtitleCue _cue(int startMs, int endMs, String text) =>
    SubtitleCue(index: 1, startMs: startMs, endMs: endMs, text: text);

/// 每个 token 一个起点；终点取 [endsMs]（null = 用下一 token 起点）。
AsrCueTokenTiming _timing(
  List<String> tokens,
  List<int> offsetsMs, [
  List<int>? endsMs,
]) =>
    AsrCueTokenTiming(
      tokens: tokens,
      offsetsMs: offsetsMs,
      endOffsetsMs: endsMs,
    );

void _expectMonotonic(List<SubtitleCharTime> t, int durationMs) {
  int prev = 0;
  for (final SubtitleCharTime c in t) {
    expect(c.startMs, greaterThanOrEqualTo(prev));
    expect(c.endMs, greaterThanOrEqualTo(c.startMs));
    expect(c.endMs, lessThanOrEqualTo(durationMs));
    prev = c.endMs;
  }
}

void main() {
  test('文本与 token 完全一致：逐字取 token 内均分的时段', () {
    final SubtitleCue cue = _cue(10000, 12000, '夕焼けの空');
    final List<SubtitleCharTime>? t = subtitleCueCharTimes(
      _timing(
          <String>['夕焼け', 'の', '空'], <int>[0, 600, 900], <int>[600, 900, 1800]),
      cue,
    );
    expect(t, isNotNull);
    expect(t!.length, cue.text.runes.length);
    expect(t.map((SubtitleCharTime c) => (c.startMs, c.endMs)).toList(), <(
      int,
      int
    )>[(0, 200), (200, 400), (400, 600), (600, 900), (900, 1800)]);
  });

  test('没有终点时取下一 token 起点，末 token 取 cue 时长', () {
    final List<SubtitleCharTime>? t = subtitleCueCharTimes(
      _timing(<String>['あ', 'い'], <int>[100, 500]),
      _cue(0, 1000, 'あい'),
    );
    expect(t!.map((SubtitleCharTime c) => (c.startMs, c.endMs)).toList(),
        <(int, int)>[(100, 500), (500, 1000)]);
  });

  test('校对补进来的标点零时长，粘在前一个字终点；结果单调', () {
    final SubtitleCue cue = _cue(0, 2000, 'あい、うえ！');
    final List<SubtitleCharTime>? t = subtitleCueCharTimes(
      _timing(<String>['あい', 'うえ'], <int>[0, 1000], <int>[800, 1600]),
      cue,
    );
    expect(t, isNotNull);
    expect(t!.length, 6);
    expect((t[2].startMs, t[2].endMs), (800, 800));
    expect((t[5].startMs, t[5].endMs), (1600, 1600));
    _expectMonotonic(t, 2000);
  });

  test('个别字被校对改掉（替换）仍出时间，且取被替换字的时段', () {
    final List<SubtitleCharTime>? t = subtitleCueCharTimes(
      _timing(
          <String>['きみ', 'の', 'こえ'], <int>[0, 400, 600], <int>[400, 600, 1000]),
      _cue(0, 1000, 'きみの声え'),
    );
    expect(t, isNotNull);
    expect((t![3].startMs, t[3].endMs), (600, 800));
  });

  test('歌词被整段替换（匹配不足 60%）→ null', () {
    expect(
      subtitleCueCharTimes(
        _timing(<String>['ら', 'ら', 'ら', 'る'], <int>[0, 200, 400, 600]),
        _cue(0, 1000, '明日へ走れ'),
      ),
      isNull,
    );
  });

  test('全是空白 token（没有有效字符）→ null', () {
    expect(
      subtitleCueCharTimes(
        _timing(<String>[' ', ''], <int>[0, 10]),
        _cue(0, 1000, 'あい'),
      ),
      isNull,
    );
  });

  test('偏移越过 cue 时长与倒序偏移被夹紧，仍单调', () {
    final List<SubtitleCharTime>? t = subtitleCueCharTimes(
      _timing(
          <String>['あ', 'い', 'う'], <int>[500, 300, 900], <int>[700, 400, 1500]),
      _cue(0, 1000, 'あいう'),
    );
    expect(t, isNotNull);
    _expectMonotonic(t!, 1000);
  });
}
