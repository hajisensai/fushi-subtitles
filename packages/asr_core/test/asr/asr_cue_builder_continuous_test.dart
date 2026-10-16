import 'package:fushi_asr_core/src/asr/asr_cue_builder.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:test/test.dart';

/// 一个滑窗中心区产物：[tokens] 与绝对时间 [times]。
AsrTranscribedSegment _core(
  int startMs,
  int endMs,
  List<String> tokens,
  List<int> times, {
  int file = 0,
}) =>
    AsrTranscribedSegment(
      audioFileIndex: file,
      startMs: startMs,
      endMs: endMs,
      tokens: tokens,
      tokenTimesMs: times,
      continuous: true,
    );

void main() {
  test('跨窗口网格的一句话拼回同一条 cue，不在 12 s 网格处断开', () {
    // 一句话 11.6 s ~ 12.4 s，正好跨过 12 s 的中心区接缝。
    final List<AsrCue> cues =
        const AsrCueBuilder().build(<AsrTranscribedSegment>[
      _core(0, 12000, <String>['お', 'は'], <int>[11600, 11760]),
      _core(12000, 24000, <String>['よ', 'う', '。'], <int>[12080, 12240, 12400]),
    ]);
    expect(cues, hasLength(1));
    expect(cues.single.text, 'おはよう。');
    expect(cues.single.startMs, 11600 - 120);
    expect(cues.single.endMs, 12400 + 400);
  });

  test('静音超过 680 ms 切成两条，各自留首 120 ms / 尾 400 ms，不越过下一条起点', () {
    final List<AsrTranscribedSegment> pseudo =
        AsrCueBuilder.resplitContinuousSegments(<AsrTranscribedSegment>[
      _core(0, 12000, <String>['あ', 'い', 'う', 'え'],
          <int>[1000, 1160, 2000, 2160]),
    ]);
    expect(pseudo, hasLength(2));
    expect(pseudo[0].tokens, <String>['あ', 'い']);
    expect(pseudo[0].startMs, 880);
    expect(pseudo[0].rawStartMs, 880);
    // 1160 + 400 = 1560 > 下一段起点 2000 − 120 = 1880？没有越过，取 1560。
    expect(pseudo[0].endMs, 1560);
    expect(pseudo[1].startMs, 1880);
    expect(pseudo[1].endMs, 2560);
    expect(pseudo.every((AsrTranscribedSegment s) => !s.continuous), isTrue);
  });

  test('尾留白不越过下一段起点；首留白不早于拼接区起点', () {
    final List<AsrTranscribedSegment> pseudo =
        AsrCueBuilder.resplitContinuousSegments(<AsrTranscribedSegment>[
      _core(0, 12000, <String>['あ', 'い'], <int>[50, 800]),
    ]);
    // 800 − 50 = 750 > 680：切开。第一段 50 + 400 = 450 不越过 800 − 120 = 680。
    expect(pseudo.map((AsrTranscribedSegment s) => (s.startMs, s.endMs)),
        <(int, int)>[(0, 450), (680, 1200)]);
  });

  test('不同文件的滑窗段各自拼接，不跨文件', () {
    final List<AsrTranscribedSegment> pseudo =
        AsrCueBuilder.resplitContinuousSegments(<AsrTranscribedSegment>[
      _core(0, 12000, <String>['あ'], <int>[11900]),
      _core(0, 12000, <String>['い'], <int>[100], file: 1),
    ]);
    expect(pseudo, hasLength(2));
    expect(pseudo[0].audioFileIndex, 0);
    expect(pseudo[1].audioFileIndex, 1);
    expect(pseudo[1].startMs, 0);
  });

  test('没有 token 的滑窗段（纯音乐）不产生段；VAD 段原样保留', () {
    final AsrTranscribedSegment vad = AsrTranscribedSegment(
      audioFileIndex: 0,
      startMs: 30000,
      endMs: 31000,
      tokens: const <String>['ん'],
      tokenTimesMs: const <int>[30100],
    );
    final List<AsrTranscribedSegment> pseudo =
        AsrCueBuilder.resplitContinuousSegments(<AsrTranscribedSegment>[
      _core(0, 12000, const <String>[], const <int>[]),
      vad,
    ]);
    expect(pseudo, <AsrTranscribedSegment>[vad]);
  });

  test('全是 VAD 段时直接返回原列表（老路径零改动）', () {
    final List<AsrTranscribedSegment> segs = <AsrTranscribedSegment>[
      AsrTranscribedSegment(
        audioFileIndex: 0,
        startMs: 0,
        endMs: 1000,
        tokens: const <String>['あ'],
        tokenTimesMs: const <int>[100],
      ),
    ];
    expect(
        identical(AsrCueBuilder.resplitContinuousSegments(segs), segs), isTrue);
  });
}
