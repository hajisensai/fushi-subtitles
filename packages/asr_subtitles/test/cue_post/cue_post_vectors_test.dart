// 搬迁回归：冻结向量（test/fixtures/cue_post_vectors.json）由搬迁前 Fushi 里的实现对
// cue_post_vector_inputs.dart 生成的输入算出，这里走 AsrCuePostProcessor 的原生链路
// 逐条核对起止、文本、分组与**全部** token 偏移。来源见 inputs 文件头与 fixture 的
// `generatedBy`。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:test/test.dart';

import 'cue_post_vector_inputs.dart';

AsrEnergySnapOptions _snapOptions(SnapParams p) => AsrEnergySnapOptions(
      frameMs: p.frameMs,
      maxGapMs: p.maxGapMs,
      windowMs: p.windowMs,
      minValleyMs: p.minValleyMs,
      distancePenalty: p.distancePenalty,
      tailMs: p.tailMs,
      leadMs: p.leadMs,
      minDurationMs: p.minDurationMs,
      floorMarginDb: p.floorMarginDb,
      minThresholdDb: p.minThresholdDb,
      maxThresholdDb: p.maxThresholdDb,
      tokenGuardMs: p.tokenGuardMs,
      edgeMaxShiftMs: p.edgeMaxShiftMs,
      edgeMinVoiceMs: p.edgeMinVoiceMs,
      edgeLeadMs: p.edgeLeadMs,
      edgeTailMs: p.edgeTailMs,
      cutBiasMs: 0, // 冻结向量生成时还没有这一项
    );

Map<String, Map<String, Object?>> _byId(Object? section) =>
    <String, Map<String, Object?>>{
      for (final Object? e in section! as List<Object?>)
        (e! as Map<String, Object?>)['id']! as String:
            e as Map<String, Object?>,
    };

void main() {
  final Map<String, Object?> fixture = jsonDecode(
    File('test/fixtures/cue_post_vectors.json').readAsStringSync(),
  ) as Map<String, Object?>;

  group('只吸附 / 修边', () {
    final Map<String, Map<String, Object?>> want = _byId(fixture['snap']);
    List<Object?> state(AsrCuePostResult r) => <Object?>[
          for (final AsrPostCueGroup g in r.groups)
            <Object?>[g.startMs, g.endMs, g.tokenOffsetsMs],
        ];

    for (final SnapCase c in snapCases()) {
      test(c.id, () {
        final Map<String, Object?> w = want[c.id]!;
        final AsrCuePostProcessor post = AsrCuePostProcessor(
          snap: _snapOptions(c.params),
        );
        final List<AsrPostCue> cues = <AsrPostCue>[
          for (final SnapCue s in c.cues)
            AsrPostCue(
              startMs: s.startMs,
              endMs: s.endMs,
              audioFileIndex: s.audioFileIndex,
              tokenOffsetsMs: s.offsetsMs,
            ),
        ];
        expect(cues, hasLength(w['cueCount']));

        final AsrCuePostResult both = post.process(
          cues,
          c.energy,
          stages: const <AsrCuePostStage>{
            AsrCuePostStage.snap,
            AsrCuePostStage.refineEdges,
          },
        );
        expect(both.snappedBoundaries, w['snapMoved']);
        expect(both.refinedEdges, w['thenRefineEdges']);
        expect(state(both), w['snapThenRefine']);

        final AsrCuePostResult snapOnly = post.process(
          cues,
          c.energy,
          stages: const <AsrCuePostStage>{AsrCuePostStage.snap},
        );
        expect(snapOnly.snappedBoundaries, w['snapOnlyMoved']);
        expect(state(snapOnly), w['snapOnly']);

        final AsrCuePostResult refineOnly = post.process(
          cues,
          c.energy,
          stages: const <AsrCuePostStage>{AsrCuePostStage.refineEdges},
        );
        expect(refineOnly.refinedEdges, w['refineOnlyEdges']);
        expect(state(refineOnly), w['refineOnly']);
      });
    }
  });

  group('整条链（默认参数）', () {
    final Map<String, Map<String, Object?>> want = _byId(fixture['pipeline']);
    for (final PostCase c in postCases()) {
      test(c.id, () {
        final Map<String, Object?> w = want[c.id]!;
        final List<AsrPostCue> cues = <AsrPostCue>[
          for (final PostCue p in c.cues)
            AsrPostCue(
              startMs: p.startMs,
              endMs: p.endMs,
              audioFileIndex: p.audioFileIndex,
              text: p.text,
              tokenOffsetsMs: p.offsetsMs,
              sectionIndex: p.sectionIndex,
              normCharStart: p.normCharStart,
              normCharEnd: p.normCharEnd,
            ),
        ];
        final AsrCuePostResult r = AsrCuePostProcessor().process(
          cues,
          c.energy,
        );
        expect(r.snappedBoundaries, w['snapped']);
        expect(r.refinedEdges, w['refined']);
        expect(r.mergedFragments, w['merged']);
        expect(r.displayMarginEdges, w['margins']);
        expect(<Object?>[
          for (final AsrPostCueGroup g in r.groups)
            <Object?>[
              g.startMs,
              g.endMs,
              g.text,
              g.tokenOffsetsMs,
              cues[g.firstIndex].sectionIndex,
              cues[g.firstIndex].normCharStart,
              cues[g.lastIndex].normCharEnd,
            ],
        ], w['cues']);
      });
    }
  });
}
