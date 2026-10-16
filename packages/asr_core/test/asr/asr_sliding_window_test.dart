import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_sliding_window.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:test/test.dart';

const int _sr = kAsrSampleRate;

/// 按 [chunkSeconds] 一块喂完 [totalSamples]（样本值 = 下标，便于核对切片），
/// 从 [startSample] 开始（模拟续跑）。
Future<List<AsrSpeechSegment>> _run(
  AsrSlidingWindowSegmenter seg,
  int totalSamples, {
  int startSample = 0,
  double chunkSeconds = 7.3,
}) async {
  final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
  final int chunk = (chunkSeconds * _sr).round();
  for (int s = startSample; s < totalSamples; s += chunk) {
    final int e = s + chunk > totalSamples ? totalSamples : s + chunk;
    final Float32List samples = Float32List(e - s);
    for (int i = 0; i < samples.length; i++) {
      samples[i] = (s + i).toDouble();
    }
    out.addAll(await seg.feed(AsrPcmChunk(startSample: s, samples: samples)));
  }
  out.addAll(await seg.flush());
  return out;
}

/// 中心区从 [from] 起首尾相接、恰好铺到 [to]，且每个窗口的中心区落在窗口内。
void _expectSeamlessCores(List<AsrSpeechSegment> windows, int from, int to) {
  expect(windows, isNotEmpty);
  int cursor = from;
  for (final AsrSpeechSegment w in windows) {
    expect(w.isWindow, isTrue);
    expect(w.coreStartSample, cursor, reason: '中心区必须首尾相接');
    expect(w.coreEndSample!, greaterThan(w.coreStartSample!));
    expect(w.coreStartSample!, greaterThanOrEqualTo(w.startSample));
    expect(w.coreEndSample!, lessThanOrEqualTo(w.endSample));
    // 样本与文件位置对齐（值 = 下标）。
    expect(w.samples.first, w.startSample.toDouble());
    expect(w.samples.last, (w.endSample - 1).toDouble());
    cursor = w.coreEndSample!;
  }
  expect(cursor, to, reason: '中心区必须铺到文件末尾');
}

void main() {
  test('窗口按 12 s 网格排布，中心区首尾相接铺满整个文件', () async {
    final List<AsrSpeechSegment> w =
        await _run(AsrSlidingWindowSegmenter(), 100 * _sr + 1234);
    for (int k = 0; k < w.length; k++) {
      expect(w[k].startSample, k * 12 * _sr);
    }
    // 中间窗口满长 15 s，中心区让出两侧各 1.5 s。
    expect(w[1].samples.length, 15 * _sr);
    expect(w[1].coreStartSample, 12 * _sr + 3 * _sr ~/ 2);
    expect(w[1].coreEndSample, 12 * _sr + 15 * _sr - 3 * _sr ~/ 2);
    _expectSeamlessCores(w, 0, 100 * _sr + 1234);
  });

  test('短于一个窗口：一个窗口、中心区就是整段', () async {
    final List<AsrSpeechSegment> w =
        await _run(AsrSlidingWindowSegmenter(), 5 * _sr);
    expect(w, hasLength(1));
    expect(w.single.startSample, 0);
    expect(w.single.coreStartSample, 0);
    expect(w.single.coreEndSample, 5 * _sr);
  });

  test('恰好一个窗口长：第二个尾窗只补后半个重叠', () async {
    final List<AsrSpeechSegment> w =
        await _run(AsrSlidingWindowSegmenter(), 15 * _sr);
    _expectSeamlessCores(w, 0, 15 * _sr);
    expect(w, hasLength(2));
  });

  test('剩余不到半个重叠时不发空尾窗（上一窗的中心区已盖到末尾）', () async {
    // 12 s 一步：第 2 窗起点 12 s，满窗到 27 s，中心区到 25.5 s；文件 25.6 s。
    final List<AsrSpeechSegment> w = await _run(
      AsrSlidingWindowSegmenter(),
      (25.6 * _sr).round(),
    );
    _expectSeamlessCores(w, 0, (25.6 * _sr).round());
  });

  test('续跑：从检查点（下一个窗口起点）重喂，中心区接上已落盘的那一窗', () async {
    final AsrSlidingWindowSegmenter full = AsrSlidingWindowSegmenter();
    final List<AsrSpeechSegment> all = await _run(full, 70 * _sr);

    // 模拟：喂完前 30 s 后落检查点。
    final AsrSlidingWindowSegmenter first = AsrSlidingWindowSegmenter();
    final Float32List head = Float32List(30 * _sr);
    for (int i = 0; i < head.length; i++) {
      head[i] = i.toDouble();
    }
    final List<AsrSpeechSegment> before =
        await first.feed(AsrPcmChunk(startSample: 0, samples: head));
    final int resume = first.inProgressSpeechStartSample!;
    expect(resume % (12 * _sr), 0, reason: '检查点必须落在窗口网格上');

    final AsrSlidingWindowSegmenter second = AsrSlidingWindowSegmenter();
    final List<AsrSpeechSegment> after =
        await _run(second, 70 * _sr, startSample: resume);
    final List<AsrSpeechSegment> stitched = <AsrSpeechSegment>[
      ...before,
      ...after,
    ];
    _expectSeamlessCores(stitched, 0, 70 * _sr);
    expect(
      stitched.map((AsrSpeechSegment s) => s.coreStartSample).toList(),
      all.map((AsrSpeechSegment s) => s.coreStartSample).toList(),
      reason: '续跑与一次跑完的中心区完全相同',
    );
  });

  test('块大小不影响结果（块边界不是窗口边界）', () async {
    final List<AsrSpeechSegment> a = await _run(
        AsrSlidingWindowSegmenter(), 61 * _sr + 77,
        chunkSeconds: 300);
    final List<AsrSpeechSegment> b = await _run(
        AsrSlidingWindowSegmenter(), 61 * _sr + 77,
        chunkSeconds: 0.9);
    expect(b.map((AsrSpeechSegment s) => (s.startSample, s.coreEndSample)),
        a.map((AsrSpeechSegment s) => (s.startSample, s.coreEndSample)));
  });

  test('重叠必须是 [0, window) 内的偶数毫秒', () {
    expect(
        () => AsrSlidingWindowSegmenter(overlapMs: 15000), throwsArgumentError);
    expect(
        () => AsrSlidingWindowSegmenter(overlapMs: 3001), throwsArgumentError);
  });

  group('AsrTranscribedSegment.fromDecoded 按中心区过滤', () {
    test('只留中心区里的 token，段界改为中心区、标记 continuous', () {
      final AsrSpeechSegment window = AsrSpeechSegment(
        startSample: 12 * _sr,
        samples: Float32List(15 * _sr),
        coreStartSample: 13 * _sr + _sr ~/ 2,
        coreEndSample: 25 * _sr + _sr ~/ 2,
      );
      final AsrTranscribedSegment t = AsrTranscribedSegment.fromDecoded(
        audioFileIndex: 0,
        speech: window,
        decoded: AsrDecodedSegment(
          tokens: const <String>['あ', 'い', 'う', 'え', 'お'],
          // 相对窗口起点：1.0 s / 1.5 s（中心区起点，含）/ 7 s / 13.5 s（终点，不含）/ 14 s
          tokenOffsetsMs: const <int>[1000, 1500, 7000, 13500, 14000],
        ),
      );
      expect(t.tokens, <String>['い', 'う']);
      expect(t.tokenTimesMs, <int>[13500, 19000]);
      expect(t.startMs, 13500);
      expect(t.endMs, 25500);
      expect(t.continuous, isTrue);
      // 持久化往返保留标记。
      final AsrTranscribedSegment back = AsrTranscribedSegment.fromJson(
        t.toJson(),
      );
      expect(back.continuous, isTrue);
    });

    test('VAD 段（没有中心区）原样保留、不标 continuous', () {
      final AsrTranscribedSegment t = AsrTranscribedSegment.fromDecoded(
        audioFileIndex: 0,
        speech: AsrSpeechSegment(startSample: _sr, samples: Float32List(_sr)),
        decoded: AsrDecodedSegment(
          tokens: const <String>['は'],
          tokenOffsetsMs: const <int>[100],
        ),
      );
      expect(t.tokens, <String>['は']);
      expect(t.continuous, isFalse);
      expect(t.toJson().containsKey('c'), isFalse);
    });
  });
}
