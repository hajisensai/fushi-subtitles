import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:fushi_asr_core/src/asr/asr_cue_builder.dart';
import 'package:fushi_asr_core/src/asr/asr_engine.dart';
import 'package:fushi_asr_core/src/asr/asr_fixed_segmenter.dart';
import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_isolate.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart';
import 'package:fushi_asr_core/src/asr/asr_transcription_service.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';

const String _kModelId = 'test-pack';

int _ms(int samples) => samples * 1000 ~/ kAsrSampleRate;
int _samples(int ms) => ms * kAsrSampleRate ~/ 1000;

/// 斜坡 PCM：样本值 = 文件内样本号（float32 在 2^24 以内精确），用来核对每段
/// 拿到的是不是自己那一段音频。
class _RampPcm implements AsrPcmSource {
  _RampPcm(this.durationMs);

  final int durationMs;
  final List<int> decodeStarts = <int>[];

  @override
  Future<int?> probeDurationMs(String audioPath) async => durationMs;

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) async* {
    decodeStarts.add(startSample);
    final int total = _samples(durationMs);
    int pos = startSample;
    while (pos < total) {
      final int n = (chunkSeconds * kAsrSampleRate).clamp(0, total - pos);
      final Float32List samples = Float32List(n);
      for (int i = 0; i < n; i++) {
        samples[i] = (pos + i).toDouble();
      }
      yield AsrPcmChunk(startSample: pos, samples: samples);
      pos += n;
    }
  }
}

/// 每段都识别成两句话（「あ。い。」）；[emptyAtMs] 里的段识别为空。记下收到的段。
class _TwoSentenceDecoder implements AsrBatchDecoder {
  _TwoSentenceDecoder({this.emptyAtMs = const <int>{}});

  final Set<int> emptyAtMs;
  final List<AsrSpeechSegment> received = <AsrSpeechSegment>[];

  @override
  Future<List<AsrDecodedSegment>> decodeBatch(
    List<AsrSpeechSegment> segments,
  ) async {
    received.addAll(segments);
    return <AsrDecodedSegment>[
      for (final AsrSpeechSegment s in segments)
        emptyAtMs.contains(s.rawStartMs)
            ? AsrDecodedSegment.empty
            : AsrDecodedSegment(
                tokens: const <String>['あ', '。', 'い', '。'],
                tokenOffsetsMs: const <int>[0, 60, 120, 180],
              ),
    ];
  }
}

AsrPcmChunk _rampChunk(int startSample, int length) {
  final Float32List samples = Float32List(length);
  for (int i = 0; i < length; i++) {
    samples[i] = (startSample + i).toDouble();
  }
  return AsrPcmChunk(startSample: startSample, samples: samples);
}

/// SRT → (起, 止, 文本)。只解析本包自己写的格式。
List<(int, int, String)> _parseSrt(String srt) {
  int ts(String t) {
    final RegExpMatch m = RegExp(r'(\d+):(\d+):(\d+),(\d+)').firstMatch(t)!;
    return ((int.parse(m[1]!) * 60 + int.parse(m[2]!)) * 60 +
                int.parse(m[3]!)) *
            1000 +
        int.parse(m[4]!);
  }

  final List<(int, int, String)> out = <(int, int, String)>[];
  for (final String block in srt.trim().split('\n\n')) {
    final List<String> lines = block.split('\n');
    final List<String> times = lines[1].split(' --> ');
    out.add((ts(times[0]), ts(times[1]), lines[2]));
  }
  return out;
}

OnnxSessionFactory _unusedFactory() =>
    throw UnimplementedError('本组用例不该建 ONNX 后端');

void main() {
  group('AsrFixedSegmenter', () {
    test('跨块、重叠、空隙：每段取自己的 PCM 范围，原始时间写进 raw', () async {
      final AsrFixedSegmenter seg = AsrFixedSegmenter(const <AsrSegmentSpan>[
        // 故意乱序：段的先后与输入顺序无关。
        AsrSegmentSpan(startMs: 1500, endMs: 2500),
        AsrSegmentSpan(startMs: 200, endMs: 1800),
      ]);
      final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
      for (int start = 0; start < _samples(3000); start += kAsrSampleRate) {
        out.addAll(await seg.feed(_rampChunk(start, kAsrSampleRate)));
      }
      out.addAll(await seg.flush());
      expect(out.length, 2);
      out.sort((AsrSpeechSegment a, AsrSpeechSegment b) =>
          a.startSample.compareTo(b.startSample));
      final AsrSpeechSegment a = out[0];
      final AsrSpeechSegment b = out[1];
      expect((a.rawStartMs, a.rawEndMs), (200, 1800));
      expect((b.rawStartMs, b.rawEndMs), (1500, 2500));
      expect(a.startSample, _samples(200));
      expect(a.samples.length, _samples(1600));
      expect(b.startSample, _samples(1500));
      expect(b.samples.length, _samples(1000));
      // 斜坡：样本值就是文件内样本号，重叠区两段各自完整。
      expect(a.samples.first, _samples(200).toDouble());
      expect(a.samples.last, (_samples(1800) - 1).toDouble());
      expect(b.samples.first, _samples(1500).toDouble());
      expect(b.samples.last, (_samples(2500) - 1).toDouble());
    });

    test('过短的段送模型时补到 300 ms，raw 仍是原始分段', () async {
      final AsrFixedSegmenter seg = AsrFixedSegmenter(const <AsrSegmentSpan>[
        AsrSegmentSpan(startMs: 1000, endMs: 1100),
      ]);
      final List<AsrSpeechSegment> out = <AsrSpeechSegment>[
        ...await seg.feed(_rampChunk(0, _samples(2000))),
        ...await seg.flush(),
      ];
      expect(out.single.samples.length, _samples(kAsrFixedSegmentMinFeedMs));
      expect((out.single.rawStartMs, out.single.rawEndMs), (1000, 1100));
    });

    test('越过文件末尾：按已有音频截断；起点都在文件外的段丢弃', () async {
      final AsrFixedSegmenter seg = AsrFixedSegmenter(const <AsrSegmentSpan>[
        AsrSegmentSpan(startMs: 1500, endMs: 3000),
        AsrSegmentSpan(startMs: 2500, endMs: 3000),
      ]);
      final List<AsrSpeechSegment> out = <AsrSpeechSegment>[
        ...await seg.feed(_rampChunk(0, _samples(2000))),
      ];
      expect(out, isEmpty, reason: '终点还没到，不能提前发');
      expect(seg.inProgressSpeechStartSample, _samples(1500));
      out.addAll(await seg.flush());
      expect(out.single.startSample, _samples(1500));
      expect(out.single.samples.length, _samples(500));
      expect((out.single.rawStartMs, out.single.rawEndMs), (1500, 3000));
    });

    test('reset 后首块起点 = 续跑点：起点更早的段视为已完成', () async {
      final AsrFixedSegmenter seg = AsrFixedSegmenter(const <AsrSegmentSpan>[
        AsrSegmentSpan(startMs: 0, endMs: 900),
        AsrSegmentSpan(startMs: 800, endMs: 1500),
        AsrSegmentSpan(startMs: 1200, endMs: 1400),
      ]);
      seg.reset();
      final List<AsrSpeechSegment> out = <AsrSpeechSegment>[
        ...await seg.feed(_rampChunk(_samples(800), _samples(1200))),
        ...await seg.flush(),
      ];
      expect(
        out.map((AsrSpeechSegment s) => s.rawStartMs).toList()..sort(),
        <int>[800, 1200],
      );
    });

    test('进行中起点 = 已喂到但未发出的段里最早的起点', () async {
      final AsrFixedSegmenter seg = AsrFixedSegmenter(const <AsrSegmentSpan>[
        AsrSegmentSpan(startMs: 500, endMs: 2500),
        AsrSegmentSpan(startMs: 600, endMs: 900),
        AsrSegmentSpan(startMs: 3000, endMs: 3500),
      ]);
      expect(seg.inProgressSpeechStartSample, isNull);
      final List<AsrSpeechSegment> first =
          await seg.feed(_rampChunk(0, _samples(1000)));
      expect(first.single.rawStartMs, 600, reason: '短段先结束先发');
      expect(seg.inProgressSpeechStartSample, _samples(500));
      await seg.feed(_rampChunk(_samples(1000), _samples(2000)));
      // 500–2500 已发；3000 起的段还没喂到起点，不算进行中。
      expect(seg.inProgressSpeechStartSample, isNull);
    });

    test('不合法分段直接抛，不静默丢弃', () {
      expect(
        () => AsrFixedSegmenter(
            const <AsrSegmentSpan>[AsrSegmentSpan(startMs: 10, endMs: 10)]),
        throwsArgumentError,
      );
      expect(
        () => AsrFixedSegmenter(
            const <AsrSegmentSpan>[AsrSegmentSpan(startMs: -1, endMs: 10)]),
        throwsArgumentError,
      );
    });
  });

  group('按给定分段识别：任务端到端', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('asr_fixed_seg_test_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    const List<AsrSegmentSpan> spans = <AsrSegmentSpan>[
      AsrSegmentSpan(startMs: 200, endMs: 1800),
      AsrSegmentSpan(startMs: 1500, endMs: 2500), // 与上一段重叠
      AsrSegmentSpan(startMs: 3000, endMs: 3100), // 过短
      AsrSegmentSpan(startMs: 4000, endMs: 4800), // 识别为空
      AsrSegmentSpan(startMs: 5500, endMs: 7000), // 终点越过文件末尾
      AsrSegmentSpan(startMs: 6500, endMs: 7000), // 整段在文件外
    ];

    AsrTranscribeJob job(Directory dir, _RampPcm pcm, AsrBatchDecoder dec) =>
        AsrTranscribeJob(
          jobDir: dir,
          audioPaths: const <String>['ep01.mkv'],
          modelId: _kModelId,
          pcm: pcm,
          segmenter: AsrFixedSegmenter(spans),
          decoder: dec,
          batchSize: 2,
          chunkSeconds: 1,
          progressInterval: Duration.zero,
          oneCuePerSegment: true,
        );

    test('一段一条 cue，时间 == 给定分段；不按句末再切；tokens 行与 SRT 行一一对应', () async {
      final _RampPcm pcm = _RampPcm(6000);
      final _TwoSentenceDecoder dec =
          _TwoSentenceDecoder(emptyAtMs: const <int>{4000});
      final List<AsrTranscribeEvent> events =
          await job(tmp, pcm, dec).run().toList();
      final AsrTranscribeResult r =
          (events.last as AsrTranscribeFinishedEvent).result;
      final List<(int, int, String)> cues =
          _parseSrt(File(r.srtPath).readAsStringSync());
      expect(cues, <(int, int, String)>[
        (200, 1800, 'あ。い。'),
        (1500, 2500, 'あ。い。'),
        (3000, 3100, 'あ。い。'),
        (5500, 7000, 'あ。い。'),
      ]);
      expect(r.cueCount, 4);
      final List<({List<String> tokens, List<int> offsetsMs})>? rows =
          parseAsrCueTokens(
        File(p.join(tmp.path, AsrJobFiles.cueTokens)).readAsStringSync(),
      );
      expect(rows, hasLength(cues.length));
      for (final ({List<String> tokens, List<int> offsetsMs}) row in rows!) {
        expect(row.tokens, <String>['あ', '。', 'い', '。']);
        expect(row.offsetsMs, <int>[0, 60, 120, 180]);
      }
      // 每段送进模型的样本数：截断 / 补长都只动样本，不动 cue 时间。
      final Map<int, int> fedMs = <int, int>{
        for (final AsrSpeechSegment s in dec.received)
          s.rawStartMs!: _ms(s.samples.length),
      };
      expect(fedMs, <int, int>{
        200: 1600,
        1500: 1000,
        3000: 300,
        4000: 800,
        5500: 500,
      });
    });

    test('中途暂停再续跑：结果与一次跑完逐条相同（不重不漏）', () async {
      final Directory whole = Directory(p.join(tmp.path, 'whole'));
      final Directory resumed = Directory(p.join(tmp.path, 'resumed'));
      final AsrTranscribeResult full = ((await job(
        whole,
        _RampPcm(6000),
        _TwoSentenceDecoder(emptyAtMs: const <int>{4000}),
      ).run().toList())
              .last as AsrTranscribeFinishedEvent)
          .result;

      // 第 2 块（1–2 s）处理完就暂停：0.2–1.8 s 已发，1.5–2.5 s 进行中。
      final AsrTranscribeJob first = job(
        resumed,
        _RampPcm(6000),
        _TwoSentenceDecoder(emptyAtMs: const <int>{4000}),
      );
      int progress = 0;
      final List<AsrTranscribeEvent> firstEvents = <AsrTranscribeEvent>[];
      await for (final AsrTranscribeEvent e in first.run()) {
        firstEvents.add(e);
        if (e is AsrTranscribeProgressEvent && ++progress == 2) {
          first.requestPause();
        }
      }
      expect(firstEvents.last, isA<AsrTranscribePausedEvent>());
      final AsrJobState paused = await AsrTranscribeJob.loadState(
        resumed,
        const <String>['ep01.mkv'],
        modelId: _kModelId,
      );
      expect(paused.resumeSamples.single, _samples(1500));

      final _RampPcm pcm2 = _RampPcm(6000);
      final AsrTranscribeResult again = ((await job(
        resumed,
        pcm2,
        _TwoSentenceDecoder(emptyAtMs: const <int>{4000}),
      ).run().toList())
              .last as AsrTranscribeFinishedEvent)
          .result;
      expect(pcm2.decodeStarts.single, _samples(1500));
      expect(
        File(again.srtPath).readAsStringSync(),
        File(full.srtPath).readAsStringSync(),
      );
      expect(
        File(p.join(resumed.path, AsrJobFiles.cueTokens)).readAsStringSync(),
        File(p.join(whole.path, AsrJobFiles.cueTokens)).readAsStringSync(),
      );
    });
  });

  group('buildOnePerSegment', () {
    test('只剩标点的段不出 cue；重叠不被兜底改时间', () {
      final List<AsrCue> cues = const AsrCueBuilder().buildOnePerSegment(
        <AsrTranscribedSegment>[
          AsrTranscribedSegment(
            audioFileIndex: 0,
            startMs: 1000,
            endMs: 3000,
            rawStartMs: 1000,
            rawEndMs: 3000,
            tokens: <String>['こ', 'れ', '。', 'そ', 'れ', '。'],
            tokenTimesMs: <int>[1100, 1200, 1300, 2000, 2100, 2200],
          ),
          AsrTranscribedSegment(
            audioFileIndex: 0,
            startMs: 2000,
            endMs: 2300,
            rawStartMs: 2000,
            rawEndMs: 2100,
            tokens: <String>['…'],
            tokenTimesMs: <int>[2050],
          ),
          AsrTranscribedSegment(
            audioFileIndex: 0,
            startMs: 2500,
            endMs: 4000,
            rawStartMs: 2500,
            rawEndMs: 4000,
            tokens: <String>['あ'],
            tokenTimesMs: <int>[2600],
          ),
        ],
      );
      expect(
        cues.map((AsrCue c) => (c.startMs, c.endMs, c.text)).toList(),
        <(int, int, String)>[(1000, 3000, 'これ。それ。'), (2500, 4000, 'あ')],
      );
      expect(cues.first.tokenOffsetsMs, <int>[100, 200, 300, 1000, 1100, 1200]);
    });
  });

  group('AsrTranscriptionService.start 的分段入参校验', () {
    // 校验发生在打开模型目录 / 建任务目录之前：这两个钩子被调到就说明校验没拦住。
    final AsrTranscriptionService svc = AsrTranscriptionService(
      audioProfile: AsrAudioProfile.mixedAudio,
      backend: const AsrIsolateBackend(buildFactory: _unusedFactory),
      openStore: (AsrLanguage l, AsrAudioProfile pr) async =>
          throw StateError('校验应先于打开模型目录'),
      jobsRoot: () async => throw StateError('校验应先于建任务目录'),
      runInIsolate: false,
    );

    test('多个音频文件 + 分段 → ArgumentError', () {
      expect(
        svc.start(
          audioPaths: const <String>['a.mkv', 'b.mkv'],
          language: AsrLanguage.japanese,
          variant: AsrEncoderVariant.int8,
          preference: AsrAccelerationPreference.cpuOnly,
          segments: const <AsrSegmentSpan>[
            AsrSegmentSpan(startMs: 0, endMs: 1000),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('不合法分段 → ArgumentError', () {
      expect(
        svc.start(
          audioPaths: const <String>['a.mkv'],
          language: AsrLanguage.japanese,
          variant: AsrEncoderVariant.int8,
          preference: AsrAccelerationPreference.cpuOnly,
          segments: const <AsrSegmentSpan>[
            AsrSegmentSpan(startMs: 500, endMs: 400),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('jobIdFor 与分段', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('asr_fixed_seg_id_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('不给分段：与旧实现逐字相同（进行中的旧任务不失联）', () {
      final File f = File(p.join(tmp.path, 'ep01.mkv'))
        ..writeAsBytesSync(List<int>.filled(123, 0));
      for (final AsrAudioProfile? profile in <AsrAudioProfile?>[
        null,
        AsrAudioProfile.cleanSpeech,
        AsrAudioProfile.mixedAudio,
      ]) {
        // 旧实现的哈希输入原文（main 0c5878a）。
        final String legacyInput = 'ep01.mkv|123\n'
            'model=${asrModelPackFor(AsrLanguage.japanese, profile: profile).id}\n'
            '${profile == AsrAudioProfile.mixedAudio ? 'profile=mixedAudio\n' : ''}';
        expect(
          AsrTranscriptionService.jobIdFor(
            <String>[f.path],
            AsrLanguage.japanese,
            profile: profile,
          ),
          sha1.convert(utf8.encode(legacyInput)).toString(),
        );
      }
    });

    test('给了分段：id 不同；分段不同 id 不同；同一组分段换顺序 id 相同', () {
      final File f = File(p.join(tmp.path, 'ep01.mkv'))
        ..writeAsBytesSync(List<int>.filled(10, 0));
      String id(List<AsrSegmentSpan>? segments) =>
          AsrTranscriptionService.jobIdFor(
            <String>[f.path],
            AsrLanguage.japanese,
            profile: AsrAudioProfile.mixedAudio,
            segments: segments,
          );
      const AsrSegmentSpan a = AsrSegmentSpan(startMs: 0, endMs: 1000);
      const AsrSegmentSpan b = AsrSegmentSpan(startMs: 2000, endMs: 3000);
      final String none = id(null);
      final String ab = id(const <AsrSegmentSpan>[a, b]);
      expect(ab, isNot(none));
      expect(id(const <AsrSegmentSpan>[a]), isNot(ab));
      expect(
        id(const <AsrSegmentSpan>[
          a,
          AsrSegmentSpan(startMs: 2000, endMs: 3001)
        ]),
        isNot(ab),
      );
      expect(id(const <AsrSegmentSpan>[b, a]), ab);
      expect(id(const <AsrSegmentSpan>[]), isNot(none),
          reason: '空分段列表也是「给定分段」，与不给不同');
    });
  });
}
