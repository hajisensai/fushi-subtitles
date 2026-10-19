/// 「按给定分段识别」：分段由外部系统给出（如 MOSS-Transcribe-Diarize 的句级
/// 时间轴），本包只负责逐段识别，**不再自己切段**。
///
/// 与 VAD / 滑窗切段器的区别：
/// - 段界是输入，不是推断出来的：每个 [AsrSegmentSpan] 原样成为一段语音、识别后
///   成为**一条** cue，cue 起止严格等于给定分段（见
///   `AsrCueBuilder.buildOnePerSegment`），不按句末标点再切、也不与相邻段合并。
/// - 段与段之间可以有空隙（不识别），也可以重叠（MOSS 多说话人同时开口）：
///   重叠时每段各自取自己的 PCM 范围，同一段音频会被识别两次。
///
/// 断点续跑沿用任务层的不变式（`asr_transcribe_job.dart` 文件头）：
/// [inProgressSpeechStartSample] = 起点已喂到、但还没发出的段里最早的起点；任务
/// 从那里重喂，并丢掉起点 ≥ 该样本的已落盘段。[reset] 之后首块的起点就是续跑点，
/// 起点早于它的段视为已完成，不再发出——它们要么已落盘，要么识别为空本来就不落盘。
///
/// 只服务**单个音频文件**（视频场景）：分段的时间轴相对该文件起点。多文件任务的
/// 拒绝在 `AsrTranscriptionService.start` 做。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart'
    show AsrSegmenter;
import 'package:fushi_asr_core/src/asr/asr_types.dart';

/// 喂给模型的最短音频（毫秒）。比它短的分段把**送进模型的样本**向后补到这么长
/// （不超过文件末尾），cue 时间仍是给定分段：CTC 在过短的输入上可能一帧都出不来。
/// 与 asr_bench 的 `run_onseg.py`（`max(end, start + 0.3)`）同一口径。
const int kAsrFixedSegmentMinFeedMs = 300;

/// 一个给定分段（毫秒，相对音频文件起点）。
///
/// 纯数据、可跨 isolate 发送（`AsrIsolateJobSpec.segments`）。
@immutable
class AsrSegmentSpan {
  const AsrSegmentSpan({required this.startMs, required this.endMs});

  final int startMs;
  final int endMs;

  int get durationMs => endMs - startMs;

  @override
  bool operator ==(Object other) =>
      other is AsrSegmentSpan &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);

  @override
  String toString() => 'AsrSegmentSpan($startMs–$endMs)';
}

/// 校验给定分段：起点非负、终点严格大于起点。不合法直接抛 [ArgumentError]，
/// 不静默丢弃——丢一段就是字幕里少一句，调用方必须知道。
void validateAsrSegmentSpans(List<AsrSegmentSpan> spans) {
  for (int i = 0; i < spans.length; i++) {
    final AsrSegmentSpan s = spans[i];
    if (s.startMs < 0 || s.endMs <= s.startMs) {
      throw ArgumentError.value(
        s,
        'segments[$i]',
        '分段必须满足 0 ≤ startMs < endMs',
      );
    }
  }
}

/// 按起点（再按终点）升序排好的副本。段的先后与输入顺序无关。
List<AsrSegmentSpan> sortedAsrSegmentSpans(List<AsrSegmentSpan> spans) =>
    List<AsrSegmentSpan>.of(spans)
      ..sort((AsrSegmentSpan a, AsrSegmentSpan b) {
        final int byStart = a.startMs.compareTo(b.startMs);
        return byStart != 0 ? byStart : a.endMs.compareTo(b.endMs);
      });

/// **纯函数**：分段列表的稳定指纹（SHA-1 十六进制），进任务 id 的哈希。
///
/// 先排序再算：同一组分段换个顺序给，结果完全相同，应命中同一份缓存。
String asrSegmentSpansFingerprint(List<AsrSegmentSpan> spans) {
  final StringBuffer sb = StringBuffer();
  for (final AsrSegmentSpan s in sortedAsrSegmentSpans(spans)) {
    sb
      ..write(s.startMs)
      ..write('-')
      ..write(s.endMs)
      ..write('\n');
  }
  return sha1.convert(utf8.encode(sb.toString())).toString();
}

/// 固定分段切段器：缓冲 PCM，某段的最后一个样本到达时发出该段。
class AsrFixedSegmenter implements AsrSegmenter {
  AsrFixedSegmenter(List<AsrSegmentSpan> spans)
      : _spans = _toSampleSpans(spans);

  /// 按起点升序；`end` 已按 [kAsrFixedSegmentMinFeedMs] 补长（送模型用），
  /// `rawStartMs` / `rawEndMs` 是原始给定时间（cue 用）。
  final List<_SampleSpan> _spans;

  /// 本文件内已发出（或因早于续跑点而跳过）的段。
  late List<bool> _done = List<bool>.filled(_spans.length, false);

  /// `_done` 里第一个 false 的下标（单调前进）；等于长度表示全部完成。
  int _firstPending = 0;

  /// 续跑点（[reset] 后首块的起点）；null = 还没收到首块。
  int? _floor;

  /// 缓冲：`_buffer[0]` 对应文件样本 `_bufferStart`。
  int _bufferStart = 0;
  Float32List _buffer = Float32List(0);
  int _bufferLength = 0;

  /// 已喂到的样本终点（不含）。
  int _fedEnd = 0;

  static List<_SampleSpan> _toSampleSpans(List<AsrSegmentSpan> spans) {
    validateAsrSegmentSpans(spans);
    return <_SampleSpan>[
      for (final AsrSegmentSpan s in sortedAsrSegmentSpans(spans))
        _SampleSpan(
          startSample: _msToSamples(s.startMs),
          endSample: _msToSamples(
            s.durationMs < kAsrFixedSegmentMinFeedMs
                ? s.startMs + kAsrFixedSegmentMinFeedMs
                : s.endMs,
          ),
          rawStartMs: s.startMs,
          rawEndMs: s.endMs,
        ),
    ];
  }

  static int _msToSamples(int ms) => ms * kAsrSampleRate ~/ 1000;

  @override
  int? get inProgressSpeechStartSample {
    if (_floor == null) return null;
    if (_firstPending >= _spans.length) return null;
    final int start = _spans[_firstPending].startSample;
    // 起点还没喂到的段不算「进行中」：检查点取块末尾即可，续跑时它照样会被发出。
    return start < _fedEnd ? start : null;
  }

  @override
  void reset() {
    _done = List<bool>.filled(_spans.length, false);
    _firstPending = 0;
    _floor = null;
    _bufferStart = 0;
    _buffer = Float32List(0);
    _bufferLength = 0;
    _fedEnd = 0;
  }

  @override
  Future<List<AsrSpeechSegment>> feed(AsrPcmChunk chunk) async {
    if (chunk.samples.isEmpty) return const <AsrSpeechSegment>[];
    if (_floor == null) {
      final int floor = chunk.startSample;
      _floor = floor;
      _bufferStart = floor;
      _fedEnd = floor;
      // 起点早于续跑点的段在上一次运行里已经处理过（见文件头的不变式）。
      for (int i = 0; i < _spans.length; i++) {
        if (_spans[i].startSample < floor) _done[i] = true;
      }
      _advanceFirstPending();
    }
    if (chunk.startSample != _fedEnd) {
      throw StateError(
        'AsrFixedSegmenter: PCM 块不连续（期望起点 $_fedEnd，实际 ${chunk.startSample}）',
      );
    }
    _append(chunk.samples);
    _fedEnd = chunk.endSample;
    final List<AsrSpeechSegment> out = _emitReady(atEof: false);
    _trim();
    return out;
  }

  @override
  Future<List<AsrSpeechSegment>> flush() async {
    // 文件结束：终点越过文件末尾的段按已有音频截断发出；起点都没喂到的段
    // （分段超出文件时长）没有音频可识别，丢弃。
    final List<AsrSpeechSegment> out =
        _floor == null ? const <AsrSpeechSegment>[] : _emitReady(atEof: true);
    reset();
    return out;
  }

  List<AsrSpeechSegment> _emitReady({required bool atEof}) {
    final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
    for (int i = _firstPending; i < _spans.length; i++) {
      if (_done[i]) continue;
      final _SampleSpan s = _spans[i];
      // 按起点升序：后面的段起点只会更晚，都还没开始。
      if (s.startSample >= _fedEnd) break;
      if (s.endSample > _fedEnd && !atEof) continue;
      final int end = s.endSample < _fedEnd ? s.endSample : _fedEnd;
      _done[i] = true;
      if (end <= s.startSample) continue;
      out.add(
        AsrSpeechSegment(
          startSample: s.startSample,
          samples: Float32List.fromList(
            Float32List.sublistView(
              _buffer,
              s.startSample - _bufferStart,
              end - _bufferStart,
            ),
          ),
          rawStartMs: s.rawStartMs,
          rawEndMs: s.rawEndMs,
        ),
      );
    }
    _advanceFirstPending();
    return out;
  }

  void _advanceFirstPending() {
    while (_firstPending < _spans.length && _done[_firstPending]) {
      _firstPending++;
    }
  }

  /// 丢掉不再需要的前缀：最早一个未完成段的起点之前的样本。
  void _trim() {
    final int keepFrom = _firstPending < _spans.length
        ? _spans[_firstPending].startSample
        : _fedEnd;
    final int bufferEnd = _bufferStart + _bufferLength;
    final int cut =
        (keepFrom < bufferEnd ? keepFrom : bufferEnd) - _bufferStart;
    if (cut <= 0) return;
    _buffer.setRange(0, _bufferLength - cut, _buffer, cut);
    _bufferLength -= cut;
    _bufferStart += cut;
  }

  void _append(Float32List samples) {
    final int needed = _bufferLength + samples.length;
    if (needed > _buffer.length) {
      final Float32List grown = Float32List(needed * 2);
      grown.setRange(0, _bufferLength, _buffer);
      _buffer = grown;
    }
    _buffer.setRange(_bufferLength, needed, samples);
    _bufferLength = needed;
  }
}

class _SampleSpan {
  const _SampleSpan({
    required this.startSample,
    required this.endSample,
    required this.rawStartMs,
    required this.rawEndMs,
  });

  final int startSample;
  final int endSample;
  final int rawStartMs;
  final int rawEndMs;
}
