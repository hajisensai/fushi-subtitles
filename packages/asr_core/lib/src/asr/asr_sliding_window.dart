/// 不用 VAD 的切段：固定长度、相互重叠的窗口铺满整条音频（给 CTC 模型）。
///
/// **为什么不用 VAD**：2026-10-15 在 8 集动画（人工日文字幕作真值）上实测，silero
/// 在带 BGM / 音效的对白上大面积判非语音——同一个 CTC 模型配 silero 切段读音
/// CER 20.9%，换成本切段器 13.6%（K-ON 那集 33.6% → 12.2%），插入错误只多
/// 0.4 个百分点：CTC 自己就会把音乐、静默判成 blank。逐字生成的模型（Whisper /
/// RNN-T 之外的 AED）没有这个性质，去掉 VAD 会在音乐上幻听，所以本切段器只配
/// [AsrModelArchitecture.nemoCtc] 用。
///
/// 网格：窗口长 [windowMs]、步长 `windowMs − overlapMs`，第 k 个窗口起点
/// `k·step`（相对文件起点，与从哪里续跑无关）。每个窗口的**中心区**
/// （[AsrSpeechSegment.coreStartSample] 起止）= 去掉两侧各半个重叠：
///
/// ```text
/// 窗口 k   |----[======中心区======]----|
/// 窗口 k+1                   |----[======中心区======]----|
///                                 ^ 两个中心区在重叠区正中首尾相接
/// ```
///
/// 首个窗口中心区从文件起点开始，末窗口一直延到文件末尾，中间窗口的中心区
/// 首尾相接、互不重叠——[AsrTranscribedSegment.fromDecoded] 只留中心区里的
/// token，整条时间轴不重不漏。
///
/// 断点续跑：[inProgressSpeechStartSample] 恒为下一个未发出窗口的起点（一个网格
/// 点），任务从那里重喂；[reset] 之后若首块不从 0 开始，首窗按「中间窗口」处理
/// （中心区让出前半个重叠），恰好接上已落盘的上一窗中心区。
library;

import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart'
    show AsrSegmenter;
import 'package:fushi_asr_core/src/asr/asr_types.dart';

/// 默认窗口长（毫秒）。基准里 8 / 15 / 20 / 30 s 四档，15 s 读音 CER 最低。
const int kAsrSlidingWindowMs = 15000;

/// 默认重叠（毫秒）。
const int kAsrSlidingOverlapMs = 3000;

class AsrSlidingWindowSegmenter implements AsrSegmenter {
  AsrSlidingWindowSegmenter({
    this.windowMs = kAsrSlidingWindowMs,
    this.overlapMs = kAsrSlidingOverlapMs,
  })  : _window = windowMs * kAsrSampleRate ~/ 1000,
        _overlap = overlapMs * kAsrSampleRate ~/ 1000 {
    if (overlapMs < 0 || overlapMs >= windowMs || overlapMs.isOdd) {
      throw ArgumentError(
        'overlapMs 必须是 [0, windowMs) 内的偶数毫秒（中心区按半个重叠切）',
      );
    }
  }

  final int windowMs;
  final int overlapMs;
  final int _window;
  final int _overlap;

  int get _step => _window - _overlap;
  int get _half => _overlap ~/ 2;

  /// `_buffer[_offset]` 对应的文件样本号（= 下一个待发窗口的起点）。
  int? _bufferStart;
  Float32List _buffer = Float32List(0);

  /// 已消费样本数（发窗只挪读指针，追加时再一次性压缩，免得每窗搬整块）。
  int _offset = 0;

  /// `_buffer` 里有效样本的结尾（含已消费部分）。
  int _end = 0;

  int get _bufferLength => _end - _offset;

  @override
  int? get inProgressSpeechStartSample => _bufferStart;

  @override
  void reset() {
    _bufferStart = null;
    _buffer = Float32List(0);
    _offset = 0;
    _end = 0;
  }

  @override
  Future<List<AsrSpeechSegment>> feed(AsrPcmChunk chunk) async {
    if (chunk.samples.isEmpty) return const <AsrSpeechSegment>[];
    _bufferStart ??= chunk.startSample;
    _append(chunk.samples);
    final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
    // 发出所有完整窗口；保留下一个窗口起点之后的样本（至少一个重叠）。
    while (_bufferLength >= _window) {
      out.add(_emit(_window, isLast: false));
      _consume(_step);
    }
    return out;
  }

  @override
  Future<List<AsrSpeechSegment>> flush() async {
    final int? start = _bufferStart;
    if (start == null || _bufferLength == 0) {
      reset();
      return const <AsrSpeechSegment>[];
    }
    // 尾窗：从下一个网格点到文件末尾。它的前 half 已经被上一窗的中心区认领过，
    // 若余下的连 half 都不到（上一窗的中心区已经盖到文件末尾附近），就没有新内容。
    final bool isFirst = start == 0;
    final AsrSpeechSegment? tail = isFirst || _bufferLength > _half
        ? _emit(_bufferLength, isLast: true)
        : null;
    reset();
    return tail == null ? const <AsrSpeechSegment>[] : <AsrSpeechSegment>[tail];
  }

  AsrSpeechSegment _emit(int length, {required bool isLast}) {
    final int start = _bufferStart!;
    final Float32List samples = Float32List.fromList(
      Float32List.sublistView(_buffer, _offset, _offset + length),
    );
    final int coreStart = start == 0 ? 0 : start + _half;
    final int coreEnd = isLast ? start + length : start + _window - _half;
    return AsrSpeechSegment(
      startSample: start,
      samples: samples,
      coreStartSample: coreStart,
      coreEndSample: coreEnd,
    );
  }

  void _append(Float32List samples) {
    final int live = _bufferLength;
    final int needed = live + samples.length;
    if (_end + samples.length > _buffer.length) {
      // 压缩掉已消费的前缀；放不下再扩容。
      final Float32List target =
          needed > _buffer.length ? Float32List(needed + _window) : _buffer;
      target.setRange(0, live, _buffer, _offset);
      _buffer = target;
      _offset = 0;
      _end = live;
    }
    _buffer.setRange(_end, _end + samples.length, samples);
    _end += samples.length;
  }

  void _consume(int count) {
    _offset += count;
    _bufferStart = _bufferStart! + count;
  }
}
