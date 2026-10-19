import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:fushi_asr_core/src/asr/asr_cue_builder.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart';
import 'package:fushi_asr_core/src/asr/asr_transcription_service.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';

/// 逐 token 终点从解码器一路带到 tokens.jsonl 的 `e` 字段：每一跳都钉一条。
void main() {
  group('ctcCollapseFrames', () {
    bool isBlank(int id) => id == 0;

    test('起点 = 同 id 首帧，终点 = 同 id 末帧 + 1；blank 不归前一个 token', () {
      final ({List<int> ids, List<int> startFrames, List<int> endFrames}) c =
          ctcCollapseFrames(<int>[0, 1, 1, 0, 1, 2, 2, 0, 0], isBlank);
      expect(c.ids, <int>[1, 1, 2], reason: '隔着 blank 的同一 id 是两个 token');
      expect(c.startFrames, <int>[1, 4, 5]);
      expect(c.endFrames, <int>[3, 5, 7]);
    });

    test('特殊符号串不延长前一个 token', () {
      final ({List<int> ids, List<int> startFrames, List<int> endFrames}) c =
          ctcCollapseFrames(<int>[3, 3, 0, 0, 3], isBlank);
      expect(c.endFrames, <int>[2, 5]);
    });
  });

  test('materializeWithEnds：byte-fallback 合成的字符终点取最后一个字节', () {
    final AsrTokenTable table = AsrTokenTable.parse(
      '<blk> 0\n<0xE2> 1\n<0x80> 2\n<0x99> 3\n▁the 4\ns 5\n',
    );
    final ({List<String> tokens, List<int> timesMs, List<int>? endTimesMs}) m =
        table.materializeWithEnds(
      <int>[4, 1, 2, 3, 5],
      <int>[0, 100, 110, 120, 200],
      <int>[90, 105, 115, 125, 250],
    );
    expect(m.tokens, <String>[' the', '’', 's']);
    expect(m.timesMs, <int>[0, 100, 200]);
    expect(m.endTimesMs, <int>[90, 125, 250]);
    expect(table.materializeWithEnds(<int>[4], <int>[0]).endTimesMs, isNull);
  });

  group('AsrTranscribedSegment 带终点', () {
    test('VAD 段：终点按段起点平移；落盘键 te 往返', () {
      final AsrTranscribedSegment s = AsrTranscribedSegment.fromDecoded(
        audioFileIndex: 0,
        speech: AsrSpeechSegment(
          startSample: kAsrSampleRate,
          samples: Float32List(kAsrSampleRate),
        ),
        decoded: AsrDecodedSegment(
          tokens: const <String>['あ', 'い'],
          tokenOffsetsMs: const <int>[100, 400],
          tokenEndOffsetsMs: const <int>[180, 480],
        ),
      );
      expect(s.tokenTimesMs, <int>[1100, 1400]);
      expect(s.tokenEndTimesMs, <int>[1180, 1480]);
      final Map<String, Object?> json = s.toJson();
      expect(json['te'], <int>[1180, 1480]);
      expect(json.containsKey('me'), isFalse, reason: 'me 是已删除产物的旧键');
      expect(
        AsrTranscribedSegment.fromJson(json).tokenEndTimesMs,
        <int>[1180, 1480],
      );
    });

    test('滑窗：只留中心区 token，终点跟着同一组下标', () {
      final AsrTranscribedSegment s = AsrTranscribedSegment.fromDecoded(
        audioFileIndex: 0,
        speech: AsrSpeechSegment(
          startSample: 0,
          samples: Float32List(2 * kAsrSampleRate),
          coreStartSample: kAsrSampleRate ~/ 2,
          coreEndSample: kAsrSampleRate * 3 ~/ 2,
        ),
        decoded: AsrDecodedSegment(
          tokens: const <String>['a', 'b', 'c'],
          tokenOffsetsMs: const <int>[100, 800, 1600],
          tokenEndOffsetsMs: const <int>[200, 900, 1700],
        ),
      );
      expect(s.tokens, <String>['b']);
      expect(s.tokenEndTimesMs, <int>[900]);
    });

    test('旧检查点：没有 te / 只有已删除的 me / te 长度不符 → 终点未知', () {
      const Map<String, Object?> base = <String, Object?>{
        'f': 0,
        's': 0,
        'e': 900,
        't': <String>['あ', 'い'],
        'm': <int>[100, 200],
      };
      expect(AsrTranscribedSegment.fromJson(base).tokenEndTimesMs, isNull);
      expect(
        AsrTranscribedSegment.fromJson(<String, Object?>{
          ...base,
          'me': <int>[150, 250],
        }).tokenEndTimesMs,
        isNull,
      );
      expect(
        AsrTranscribedSegment.fromJson(<String, Object?>{
          ...base,
          'te': <int>[150],
        }).tokenEndTimesMs,
        isNull,
      );
    });
  });

  group('cue 构造带终点', () {
    test('按句切开后每条 cue 的终点相对各自起点', () {
      final List<AsrCue> cues =
          const AsrCueBuilder().build(<AsrTranscribedSegment>[
        AsrTranscribedSegment(
          audioFileIndex: 0,
          startMs: 1000,
          endMs: 5000,
          tokens: const <String>['あ', 'あ', '。', 'い', 'い'],
          tokenTimesMs: const <int>[1200, 1300, 1400, 3000, 3100],
          tokenEndTimesMs: const <int>[1280, 1380, 1480, 3080, 3180],
        ),
      ]);
      expect(cues, hasLength(2));
      expect(cues[0].tokenEndOffsetsMs, <int>[280, 380, 480]);
      expect(cues[1].startMs, 2850);
      expect(cues[1].tokenEndOffsetsMs, <int>[230, 330]);
    });

    test('滑窗段拼接：全有才有，混进一段旧检查点就整串未知', () {
      AsrTranscribedSegment win(int start, int end, int t,
              {required bool ends}) =>
          AsrTranscribedSegment(
            audioFileIndex: 0,
            startMs: start,
            endMs: end,
            tokens: const <String>['あ'],
            tokenTimesMs: <int>[t],
            tokenEndTimesMs: ends ? <int>[t + 80] : null,
            continuous: true,
          );
      final List<AsrTranscribedSegment> withEnds =
          AsrCueBuilder.resplitContinuousSegments(<AsrTranscribedSegment>[
        win(0, 12000, 1000, ends: true),
        win(12000, 24000, 1300, ends: true),
      ]);
      expect(withEnds.single.tokenEndTimesMs, <int>[1080, 1380]);
      final List<AsrTranscribedSegment> mixed =
          AsrCueBuilder.resplitContinuousSegments(<AsrTranscribedSegment>[
        win(0, 12000, 1000, ends: true),
        win(12000, 24000, 1300, ends: false),
      ]);
      expect(mixed.single.tokenEndTimesMs, isNull);
    });

    test('一段一条 cue（给定分段）也带终点', () {
      final List<AsrCue> cues =
          const AsrCueBuilder().buildOnePerSegment(<AsrTranscribedSegment>[
        AsrTranscribedSegment(
          audioFileIndex: 0,
          startMs: 2000,
          endMs: 3000,
          rawStartMs: 2000,
          rawEndMs: 3000,
          tokens: const <String>['は', 'い'],
          tokenTimesMs: const <int>[2100, 2300],
          tokenEndTimesMs: const <int>[2200, 2500],
        ),
      ]);
      expect(cues.single.tokenEndOffsetsMs, <int>[200, 500]);
    });
  });

  group('tokens.jsonl 的 e 字段', () {
    final List<AsrCue> cues = <AsrCue>[
      const AsrCue(
        startMs: 0,
        endMs: 900,
        text: 'はい',
        audioFileIndex: 0,
        tokens: <String>['は', 'い'],
        tokenOffsetsMs: <int>[100, 300],
        tokenEndOffsetsMs: <int>[200, 500],
      ),
      const AsrCue(
        startMs: 1000,
        endMs: 1500,
        text: 'え',
        audioFileIndex: 0,
        tokens: <String>['え'],
        tokenOffsetsMs: <int>[50],
      ),
    ];

    test('有终点写 e、没有就不写这个键', () {
      expect(
        serializeAsrCueTokens(cues),
        '{"t":["は","い"],"o":[100,300],"e":[200,500]}\n'
        '{"t":["え"],"o":[50]}\n',
      );
    });

    test('老读取方 parseAsrCueTokens 不受 e 影响', () {
      final List<({List<String> tokens, List<int> offsetsMs})>? rows =
          parseAsrCueTokens(serializeAsrCueTokens(cues));
      expect(rows, hasLength(2));
      expect(rows![0].offsetsMs, <int>[100, 300]);
    });

    test('parseAsrCueTokenTimings 读出 e；旧行没有 e → null；e 长度不符 → 整体无效', () {
      final List<AsrCueTokenTiming>? rows =
          parseAsrCueTokenTimings(serializeAsrCueTokens(cues));
      expect(rows, hasLength(2));
      expect(rows![0].endOffsetsMs, <int>[200, 500]);
      expect(rows[1].endOffsetsMs, isNull);
      expect(
        parseAsrCueTokenTimings('{"t":["a","b"],"o":[1,2],"e":[3]}\n'),
        isNull,
      );
      expect(
          parseAsrCueTokenTimings('{"t":["a"],"o":[1]}\n')!.single.endOffsetsMs,
          isNull);
      expect(
        serializeAsrCueTokenTimings(rows),
        serializeAsrCueTokens(cues),
        reason: '读回再写出逐字相同',
      );
    });

    test('readCueTokenTimings 把终点交给宿主', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('asr_token_end_');
      addTearDown(() => dir.delete(recursive: true));
      final File srt = File(p.join(dir.path, AsrJobFiles.srt))
        ..writeAsStringSync(serializeAsrCuesToSrt(cues));
      File(p.join(dir.path, AsrJobFiles.state)).writeAsStringSync('{}');
      File(p.join(dir.path, AsrJobFiles.cueTokens))
          .writeAsStringSync(serializeAsrCueTokens(cues));
      final List<AsrCueTokenTiming>? rows =
          await AsrTranscriptionService.readCueTokenTimings(
        srt.path,
        expectedCount: 2,
      );
      expect(rows![0].endOffsetsMs, <int>[200, 500]);
      expect(rows[1].endOffsetsMs, isNull);
    });
  });
}
