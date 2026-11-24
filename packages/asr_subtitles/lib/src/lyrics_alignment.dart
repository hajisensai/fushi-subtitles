/// 纯文本歌词（没有时间轴，例如 Genius 这类来源）↔ 这首歌的 ASR 转录：给每行歌词
/// 定起止时间。显示的仍是歌词原文，转录只当时间参照。
///
/// 唱歌比朗读难对得多，本文件针对的就是那几样：
/// - **拖音**：歌手把一个音拖长，ASR 常写成「そらあああ」「好きー」。两边都先把连续
///   相同的字收成一个、删掉长音符号（`ー` / `〜`），拖出来的元音也只是转录多出来的
///   字（便宜的转录空位）。
/// - **和声 / 合唱 / 喊声**：转录里会多出歌词没有的字（背景和声被识别出来），或者歌词
///   里括号里的和声根本没被识别。转录多的字是便宜的空位；歌词括号 `()` / `（）` 里的
///   字跳过代价更低，整行都在括号里的和声行照样参与对齐。
/// - **重复段**：副歌一字不差地出现好几次，单看文本分不清是哪一遍。这里不做「找唯一
///   锚点」，而是对整首做一次全局单调对齐（半全局 Needleman–Wunsch：歌词必须整段
///   用完，转录两端可以白送），重复段靠前后文自然落到各自那一遍上。
/// - **写法不同**：歌词写汉字、ASR 写假名（或反过来）时对不上字，但替换仍然推进双方
///   位置，夹在对上的字之间的行照样有时间（只是可信度低，记为 [LyricsLineTiming.estimated]）。
/// - **段落标记**：`[Chorus]` / `【サビ】` 这类整行标记与空行不唱，不参与对齐、不给时间
///   （[LyricsLineKind.marker] / [LyricsLineKind.blank]），调用方自己决定要不要留。
///
/// 纯 Dart、无 IO；[alignLyricsToTranscript] 在后台 isolate 里跑（可取消）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_core/text.dart' show AudioTextNormalizer;
import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;

import 'cancellation.dart';
import 'subtitle_format.dart';
import 'subtitle_retiming.dart' show RetimingTranscription;

/// 一行歌词的种类。
enum LyricsLineKind {
  /// 要唱的一行（参与对齐、给时间）。
  sung,

  /// 段落标记（`[Verse 1]`、`【サビ】`）或只有符号（`♪`）的行：不唱、不给时间。
  marker,

  /// 空行。
  blank,
}

/// 一行时间的来历。
enum LyricsLineTiming {
  /// 足够多的字与转录逐字对上（可信）。
  anchored,

  /// 对上的字不够，时间由对齐路径上的位置或前后可信行之间按字数推出来。
  estimated,

  /// 不唱的行（[LyricsLineKind.marker] / [LyricsLineKind.blank]），没有时间。
  none,
}

/// 对齐后的一行。
class AlignedLyricsLine {
  const AlignedLyricsLine({
    required this.index,
    required this.text,
    required this.kind,
    required this.timing,
    required this.startMs,
    required this.endMs,
    required this.chars,
    required this.matchedChars,
  });

  /// 在输入行列表里的下标。
  final int index;

  /// 原文（未改动）。
  final String text;
  final LyricsLineKind kind;
  final LyricsLineTiming timing;

  /// 起止时刻（毫秒，`startMs < endMs`）；不唱的行为 null。
  final int? startMs;
  final int? endMs;

  /// 参与对齐的字数（归一化、收拖音之后）与其中逐字对上的字数。
  final int chars;
  final int matchedChars;

  Map<String, Object?> toJson() => <String, Object?>{
        'index': index,
        'text': text,
        'kind': kind.name,
        'timing': timing.name,
        'startMs': startMs,
        'endMs': endMs,
        'chars': chars,
        'matchedChars': matchedChars,
      };
}

/// 整首的对齐结果。
class LyricsAlignment {
  const LyricsAlignment({
    required this.lines,
    required this.sungLines,
    required this.anchoredLines,
    required this.lyricChars,
    required this.matchedChars,
    required this.transcriptChars,
  });

  /// 与输入行一一对应（同序、同数）。
  final List<AlignedLyricsLine> lines;

  final int sungLines;
  final int anchoredLines;
  final int lyricChars;
  final int matchedChars;
  final int transcriptChars;

  /// 可信行占要唱的行的比例。
  double get anchoredRatio => sungLines == 0 ? 0 : anchoredLines / sungLines;

  /// 歌词逐字对上的比例。
  double get charCoverage => lyricChars == 0 ? 0 : matchedChars / lyricChars;

  /// 结果能不能用：可信行至少 [kLyricsAlignMinAnchoredLines] 行，且可信行比例、逐字
  /// 覆盖率都过门槛。不过门槛多半是转录与歌词根本不是同一首（或这首没人声 / 识别
  /// 全错），调用方应当告诉用户对不上，而不是存一份乱跳的时间轴。
  bool get isReliable =>
      anchoredLines >= kLyricsAlignMinAnchoredLines &&
      anchoredRatio >= kLyricsAlignMinAnchoredRatio &&
      charCoverage >= kLyricsAlignMinCharCoverage;

  Map<String, Object?> get stats => <String, Object?>{
        'sungLines': sungLines,
        'anchoredLines': anchoredLines,
        'lyricChars': lyricChars,
        'matchedChars': matchedChars,
        'transcriptChars': transcriptChars,
        'anchoredRatio': anchoredRatio,
        'charCoverage': charCoverage,
        'reliable': isReliable,
      };
}

/// [LyricsAlignment.isReliable] 的门槛。
const int kLyricsAlignMinAnchoredLines = 2;
const double kLyricsAlignMinAnchoredRatio = 0.3;
const double kLyricsAlignMinCharCoverage = 0.2;

/// 一行算「可信」至少要逐字对上的比例（且至少 2 个字；1 个字的行要全对上）。
const double kLyricsAlignLineAnchorRatio = 0.34;

/// DP 表格（歌词字数 × 转录字数）上限：一首歌远远够用（3000 × 3000 = 900 万），
/// 超出多半是把整张专辑的转录喂进来了。
const int kLyricsAlignMaxCells = 40000000;

/// 一个字的时长估计范围（毫秒）：行首 / 行尾没对上的字按它往外推。
const int _minCharMs = 60;
const int _maxCharMs = 700;
const int _defaultCharMs = 280;

// 打分（越大越好）。逐字对上 +2；替换 −1（写法不同但位置照样推进）；歌词的字没在
// 转录里 −1（括号里的和声 −0.25）；转录多出来的字（拖音元音、和声、喊声、识别
// 幻觉）−0.5。转录两端（前奏里的杂音、尾奏）白送。
const double _match = 2;
const double _substitute = -1;
const double _lyricGap = -1;
const double _optionalLyricGap = -0.25;
const double _transcriptGap = -0.5;

/// 对齐（后台 isolate，可取消）。[durationMs] 是整首时长（可缺省），只用来夹住最后
/// 几行推出来的时间。
///
/// 抛 [FormatException]：歌词 × 转录超过 [kLyricsAlignMaxCells]，或转录时间轴无效。
Future<LyricsAlignment> alignLyricsToTranscript(
  List<String> lines,
  RetimingTranscription transcription, {
  int? durationMs,
  TranscribeCancellation? cancellation,
}) {
  final List<String> input = List<String>.of(lines);
  final List<SubtitleCue> cues = List<SubtitleCue>.of(transcription.cues);
  final List<AsrCueTokenTiming>? tokens = transcription.tokenTimings == null
      ? null
      : List<AsrCueTokenTiming>.of(transcription.tokenTimings!);
  return cancellableCompute(
    () => alignLyricsToTranscriptSync(input, _Snapshot(cues, tokens),
        durationMs: durationMs),
    cancellation,
  );
}

class _Snapshot implements RetimingTranscription {
  const _Snapshot(this.cues, this.tokenTimings);
  @override
  final List<SubtitleCue> cues;
  @override
  final List<AsrCueTokenTiming>? tokenTimings;
}

/// [alignLyricsToTranscript] 的同步版本（测试、或调用方已经在后台 isolate 里）。
LyricsAlignment alignLyricsToTranscriptSync(
  List<String> lines,
  RetimingTranscription transcription, {
  int? durationMs,
}) {
  final _Lyrics lyrics = _Lyrics(lines);
  final _Transcript transcript = _Transcript(transcription);
  final int n = lyrics.chars.length;
  final int m = transcript.chars.length;
  if ((n + 1) * (m + 1) > kLyricsAlignMaxCells) {
    throw FormatException('歌词或转录过长（$n × $m 字）');
  }
  final Int32List aligned = n == 0 || m == 0
      ? (Int32List(n)..fillRange(0, n, -1))
      : _align(lyrics, transcript);

  final List<_LineFit> fits = <_LineFit>[];
  int matchedTotal = 0;
  for (final _LineSpan span in lyrics.spans) {
    if (span.kind != LyricsLineKind.sung) continue;
    final _LineFit fit = _fitLine(span, lyrics, transcript, aligned);
    matchedTotal += fit.matched;
    fits.add(fit);
  }
  final List<(int, int)?> times = _resolveTimes(
    fits,
    transcript,
    durationMs,
  );

  final List<AlignedLyricsLine> out = <AlignedLyricsLine>[];
  int sung = 0;
  int anchoredCount = 0;
  for (int i = 0; i < lyrics.spans.length; i++) {
    final _LineSpan span = lyrics.spans[i];
    if (span.kind != LyricsLineKind.sung) {
      out.add(AlignedLyricsLine(
        index: i,
        text: lines[i],
        kind: span.kind,
        timing: LyricsLineTiming.none,
        startMs: null,
        endMs: null,
        chars: 0,
        matchedChars: 0,
      ));
      continue;
    }
    final _LineFit fit = fits[sung];
    final (int, int)? t = times[sung];
    sung++;
    if (fit.anchored) anchoredCount++;
    out.add(AlignedLyricsLine(
      index: i,
      text: lines[i],
      kind: LyricsLineKind.sung,
      timing:
          fit.anchored ? LyricsLineTiming.anchored : LyricsLineTiming.estimated,
      startMs: t?.$1,
      endMs: t?.$2,
      chars: span.end - span.start,
      matchedChars: fit.matched,
    ));
  }
  return LyricsAlignment(
    lines: List<AlignedLyricsLine>.unmodifiable(out),
    sungLines: sung,
    anchoredLines: anchoredCount,
    lyricChars: n,
    matchedChars: matchedTotal,
    transcriptChars: m,
  );
}

// ---------------------------------------------------------------------------
// 归一化
// ---------------------------------------------------------------------------

final RegExp _unicodeText = RegExp(r'^[\p{L}\p{N}\p{M}]$', unicode: true);

/// 整行段落标记：`[Chorus]`、`[Verse 1: 歌手]`、`【サビ】`、`<Bridge>`。
final RegExp _markerLine = RegExp(r'^\s*(?:\[[^\]]*\]|【[^】]*】|<[^<>]*>)\s*$');

/// 单码点归一化：大小写 / 全角半角 / 片假名 → 平假名折叠，长音符号与波浪号删掉
/// （拖音），标点与空白删掉。返回 -1 = 不参与对齐。
int _fold(int rune) {
  if (rune == 0x30FC || rune == 0xFF70 || rune == 0x301C || rune == 0xFF5E) {
    return -1; // ー ｰ 〜 ～：拖音记号
  }
  final int folded = AudioTextNormalizer.foldCodePoint(rune);
  if (folded >= 0) return folded;
  final String c = String.fromCharCode(rune);
  if (!_unicodeText.hasMatch(c)) return -1;
  return c.toLowerCase().runes.first;
}

bool _isOpenParen(int r) => r == 0x28 || r == 0xFF08; // ( （
bool _isCloseParen(int r) => r == 0x29 || r == 0xFF09; // ) ）

class _LineSpan {
  _LineSpan(this.kind, this.start, this.end);
  final LyricsLineKind kind;

  /// 这一行的字在 [_Lyrics.chars] 里的区间 `[start, end)`。
  final int start;
  final int end;
}

class _Lyrics {
  _Lyrics(List<String> lines) {
    for (final String line in lines) {
      if (line.trim().isEmpty) {
        spans.add(_LineSpan(LyricsLineKind.blank, chars.length, chars.length));
        continue;
      }
      if (_markerLine.hasMatch(line)) {
        spans.add(_LineSpan(LyricsLineKind.marker, chars.length, chars.length));
        continue;
      }
      final int start = chars.length;
      int depth = 0;
      int previous = -1;
      for (final int rune in line.runes) {
        if (_isOpenParen(rune)) {
          depth++;
          continue;
        }
        if (_isCloseParen(rune)) {
          if (depth > 0) depth--;
          continue;
        }
        final int f = _fold(rune);
        if (f < 0) continue;
        // 拖音：连续相同的字收成一个（两边同样收，「ああ」这种本来就叠字的也一致）。
        if (f == previous) continue;
        previous = f;
        chars.add(f);
        optional.add(depth > 0);
      }
      spans.add(_LineSpan(
        chars.length == start ? LyricsLineKind.marker : LyricsLineKind.sung,
        start,
        chars.length,
      ));
    }
  }

  final List<int> chars = <int>[];

  /// 与 [chars] 等长：这个字在括号里（和声 / 合唱，没被识别出来也正常）。
  final List<bool> optional = <bool>[];
  final List<_LineSpan> spans = <_LineSpan>[];
}

/// 转录：逐字一个码点 + 该字的起止时刻。
class _Transcript {
  _Transcript(RetimingTranscription source) {
    final List<SubtitleCue> cues = source.cues;
    final List<AsrCueTokenTiming>? timings =
        source.tokenTimings?.length == cues.length ? source.tokenTimings : null;
    int previousStart = -1;
    for (int c = 0; c < cues.length; c++) {
      final SubtitleCue cue = cues[c];
      if (cue.startMs < previousStart || cue.endMs < cue.startMs) {
        throw const FormatException('ASR 转录的时间轴顺序无效');
      }
      previousStart = cue.startMs;
      final List<(int, int, int)> local =
          _tokenChars(cue, timings?[c]) ?? _uniformChars(cue);
      int previous = -1;
      for (final (int rune, int start, int end) in local) {
        if (rune == previous && starts.isNotEmpty) {
          // 拖音：同一个 cue 里连续相同的字并进前一个字，时长一并算给它。
          ends[ends.length - 1] = math.max(ends.last, end);
          continue;
        }
        previous = rune;
        chars.add(rune);
        starts.add(start);
        ends.add(end);
      }
    }
  }

  final List<int> chars = <int>[];
  final List<int> starts = <int>[];
  final List<int> ends = <int>[];

  static List<int> _foldText(String text) => <int>[
        for (final int r in text.runes)
          if (_fold(r) >= 0) _fold(r),
      ];

  static List<(int, int, int)> _uniformChars(SubtitleCue cue) {
    final List<int> runes = _foldText(cue.text);
    if (runes.isEmpty) return const <(int, int, int)>[];
    final double step = (cue.endMs - cue.startMs) / runes.length;
    return <(int, int, int)>[
      for (int i = 0; i < runes.length; i++)
        (
          runes[i],
          cue.startMs + (step * i).round(),
          cue.startMs + (step * (i + 1)).round(),
        ),
    ];
  }

  /// 有逐 token 发射时间时按 token 给时间：token 里的字平分「本 token 起点 → 下一个
  /// token 起点（或 token 自己的终点）」。token 拼起来与 cue 正文对不上、或时间倒退
  /// 时返回 null（退回均分；错位的 token 时间比没有更糟）。
  static List<(int, int, int)>? _tokenChars(
    SubtitleCue cue,
    AsrCueTokenTiming? timing,
  ) {
    if (timing == null ||
        timing.isEmpty ||
        timing.tokens.length != timing.offsetsMs.length) {
      return null;
    }
    final List<List<int>> tokens = <List<int>>[
      for (final String t in timing.tokens) _foldText(t),
    ];
    final List<int> whole = _foldText(cue.text);
    final List<int> joined = <int>[for (final List<int> t in tokens) ...t];
    if (joined.length != whole.length) return null;
    for (int i = 0; i < whole.length; i++) {
      if (joined[i] != whole[i]) return null;
    }
    final List<int> at = <int>[];
    int previous = cue.startMs;
    for (final int relative in timing.offsetsMs) {
      final int time = (cue.startMs + relative).clamp(cue.startMs, cue.endMs);
      if (time < previous) return null;
      at.add(time);
      previous = time;
    }
    final List<int>? ownEnds = timing.endOffsetsMs;
    final List<(int, int, int)> out = <(int, int, int)>[];
    for (int i = 0; i < tokens.length; i++) {
      final List<int> chars = tokens[i];
      if (chars.isEmpty) continue;
      final int start = at[i];
      int end = i + 1 < at.length ? at[i + 1] : cue.endMs;
      if (ownEnds != null) {
        final int own = (cue.startMs + ownEnds[i]).clamp(start, cue.endMs);
        if (own > start) end = math.min(end, own);
      }
      if (end <= start) end = math.min(cue.endMs, start + 1);
      final double step = (end - start) / chars.length;
      for (int k = 0; k < chars.length; k++) {
        out.add((
          chars[k],
          start + (step * k).round(),
          math.max(
              start + (step * (k + 1)).round(), start + (step * k).round()),
        ));
      }
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// 全局单调对齐
// ---------------------------------------------------------------------------

const int _fromDiagonal = 0;
const int _fromLyricGap = 1; // 歌词的字没对上转录（向上）
const int _fromTranscriptGap = 2; // 转录多出来的字（向左）

/// 半全局对齐：歌词必须整段用完，转录两端白送。返回与歌词字等长的数组：
/// 对上（逐字或替换）的转录下标，歌词空位为 -1；逐字对上的下标存成 `j`，替换存成
/// `-(j + 2)`（≤ -2），调用方据此区分。
Int32List _align(_Lyrics lyrics, _Transcript transcript) {
  final List<int> a = lyrics.chars;
  final List<int> b = transcript.chars;
  final int n = a.length;
  final int m = b.length;
  final int width = m + 1;
  final Uint8List from = Uint8List((n + 1) * width);
  Float64List previous = Float64List(width); // 第 0 行：转录前缀白送，全 0
  Float64List current = Float64List(width);
  for (int i = 1; i <= n; i++) {
    final double gap = lyrics.optional[i - 1] ? _optionalLyricGap : _lyricGap;
    current[0] = previous[0] + gap;
    from[i * width] = _fromLyricGap;
    final int ai = a[i - 1];
    for (int j = 1; j <= m; j++) {
      final double diagonal =
          previous[j - 1] + (ai == b[j - 1] ? _match : _substitute);
      final double up = previous[j] + gap;
      final double left = current[j - 1] + _transcriptGap;
      double best = diagonal;
      int dir = _fromDiagonal;
      if (up > best) {
        best = up;
        dir = _fromLyricGap;
      }
      if (left > best) {
        best = left;
        dir = _fromTranscriptGap;
      }
      current[j] = best;
      from[i * width + j] = dir;
    }
    final Float64List swap = previous;
    previous = current;
    current = swap;
  }
  // 转录后缀白送：最后一行里取最高分的终点。
  int endJ = 0;
  double best = previous[0];
  for (int j = 1; j <= m; j++) {
    if (previous[j] > best) {
      best = previous[j];
      endJ = j;
    }
  }
  final Int32List out = Int32List(n)..fillRange(0, n, -1);
  int i = n;
  int j = endJ;
  while (i > 0) {
    if (j == 0) {
      i--;
      continue;
    }
    switch (from[i * width + j]) {
      case _fromDiagonal:
        out[i - 1] = a[i - 1] == b[j - 1] ? j - 1 : -(j - 1 + 2);
        i--;
        j--;
      case _fromLyricGap:
        i--;
      default:
        j--;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 行时间
// ---------------------------------------------------------------------------

class _LineFit {
  _LineFit({
    required this.chars,
    required this.matched,
    required this.anchored,
    required this.start,
    required this.end,
  });

  final int chars;
  final int matched;
  final bool anchored;

  /// 由对齐路径推出的起止（毫秒）；整行一个字都没落到转录上为 null。
  final int? start;
  final int? end;
}

_LineFit _fitLine(
  _LineSpan span,
  _Lyrics lyrics,
  _Transcript transcript,
  Int32List aligned,
) {
  final int length = span.end - span.start;
  int matched = 0;
  int firstMatch = -1;
  int lastMatch = -1;
  int firstAny = -1;
  int lastAny = -1;
  for (int k = span.start; k < span.end; k++) {
    final int v = aligned[k];
    if (v == -1) continue;
    if (firstAny < 0) firstAny = k;
    lastAny = k;
    if (v >= 0) {
      matched++;
      if (firstMatch < 0) firstMatch = k;
      lastMatch = k;
    }
  }
  final bool anchored = length <= 1
      ? matched == length && length == 1
      : matched >= 2 && matched >= (length * kLyricsAlignLineAnchorRatio);
  int indexOf(int k) {
    final int v = aligned[k];
    return v >= 0 ? v : -(v + 2);
  }

  // 有逐字对上的字时以它们为准（替换可能挂在隔了一段间奏的杂字上）；行首 / 行尾
  // 没对上的字按这一行自己的字速往外推。
  final int lo = firstMatch >= 0 ? firstMatch : firstAny;
  final int hi = lastMatch >= 0 ? lastMatch : lastAny;
  if (lo < 0) {
    return _LineFit(
        chars: length,
        matched: matched,
        anchored: false,
        start: null,
        end: null);
  }
  final int loStart = transcript.starts[indexOf(lo)];
  final int hiEnd = transcript.ends[indexOf(hi)];
  final int span2 = hi - lo + 1;
  final int charMs = span2 >= 2
      ? ((hiEnd - loStart) / span2).round().clamp(_minCharMs, _maxCharMs)
      : _defaultCharMs;
  final int start = math.max(0, loStart - (lo - span.start) * charMs);
  final int end = math.max(start + 1, hiEnd + (span.end - 1 - hi) * charMs);
  return _LineFit(
    chars: length,
    matched: matched,
    anchored: anchored,
    start: start,
    end: end,
  );
}

/// 每个要唱的行的 `(start, end)`。可信行用自己的时间；其它行在相邻可信行之间：
/// 对齐路径给出的位置落在这个窗口里就用它，否则按字数把窗口分给这几行。
List<(int, int)?> _resolveTimes(
  List<_LineFit> fits,
  _Transcript transcript,
  int? durationMs,
) {
  final int count = fits.length;
  final List<(int, int)?> out = List<(int, int)?>.filled(count, null);
  if (count == 0) return out;

  // 可信行：单调（DP 本身单调；行首外推可能越过上一行，夹住）。
  final List<int> anchors = <int>[];
  for (int i = 0; i < count; i++) {
    final _LineFit f = fits[i];
    if (!f.anchored || f.start == null) continue;
    int start = f.start!;
    if (anchors.isNotEmpty) {
      final (int, int) prev = out[anchors.last]!;
      if (start <= prev.$1) start = prev.$1 + 1;
    }
    out[i] = (start, math.max(start + 1, f.end!));
    anchors.add(i);
  }

  final int charMs = _medianCharMs(fits);
  final int trackEnd = durationMs ??
      (transcript.ends.isEmpty ? 0 : transcript.ends.reduce(math.max) + 2000);

  int needOf(int from, int to) {
    int need = 0;
    for (int i = from; i < to; i++) {
      need += math.max(1, fits[i].chars) * charMs;
    }
    return need;
  }

  // 窗口 [lo, hi) 内放第 from..to-1 行（都不是可信行）。窗口一端是曲首 / 曲尾（前奏、
  // 尾奏）时没有位置的那几行不摊满整段，而是按字速贴着可信行排（[packRight]：贴右端，
  // [packLeft]：贴左端）。
  void fill(int from, int to, int lo, int hi,
      {bool packRight = false, bool packLeft = false}) {
    if (from >= to) return;
    if (hi <= lo) hi = lo + (to - from);
    // 先认对齐路径给的位置（单调、在窗口内）。
    int cursor = lo;
    final List<int> unplaced = <int>[];
    for (int i = from; i < to; i++) {
      final _LineFit f = fits[i];
      final int? s = f.start;
      if (s != null && s >= cursor && s < hi) {
        out[i] = (s, math.min(math.max(s + 1, f.end!), hi));
        cursor = s + 1;
      } else {
        out[i] = null;
        unplaced.add(i);
      }
    }
    if (unplaced.isEmpty) return;
    // 剩下的：在各自左右已定位置之间按字数分。
    int k = 0;
    while (k < unplaced.length) {
      int e = k;
      while (e + 1 < unplaced.length && unplaced[e + 1] == unplaced[e] + 1) {
        e++;
      }
      final int first = unplaced[k];
      final int last = unplaced[e];
      int left =
          first > from && out[first - 1] != null ? out[first - 1]!.$2 : lo;
      int right =
          last + 1 < to && out[last + 1] != null ? out[last + 1]!.$1 : hi;
      if (packRight && first == from) {
        left = math.max(left, right - needOf(first, last + 1));
      }
      if (packLeft && last + 1 == to) {
        right = math.min(right, left + needOf(first, last + 1));
      }
      _spread(fits, out, first, last + 1, left, math.max(right, left + 1));
      k = e + 1;
    }
  }

  if (anchors.isEmpty) {
    _spread(fits, out, 0, count, 0, math.max(trackEnd, count));
  } else {
    // 第一个可信行之前：对齐路径给了位置的照用，其余按字速往回排，到 0 为止。
    final int firstAnchor = anchors.first;
    if (firstAnchor > 0) {
      fill(0, firstAnchor, 0, out[firstAnchor]!.$1, packRight: true);
    }
    for (int a = 1; a < anchors.length; a++) {
      fill(anchors[a - 1] + 1, anchors[a], out[anchors[a - 1]]!.$2,
          out[anchors[a]]!.$1);
    }
    final int lastAnchor = anchors.last;
    if (lastAnchor + 1 < count) {
      final int lo = out[lastAnchor]!.$2;
      fill(lastAnchor + 1, count, lo,
          math.max(lo + needOf(lastAnchor + 1, count), trackEnd),
          packLeft: true);
    }
  }

  // 收尾：起点严格递增；终点不越过下一行起点。
  for (int i = 0; i < count; i++) {
    final (int, int) t = out[i]!;
    int start = t.$1;
    if (i > 0 && start <= out[i - 1]!.$1) start = out[i - 1]!.$1 + 1;
    out[i] = (start, math.max(start + 1, t.$2));
  }
  for (int i = 0; i + 1 < count; i++) {
    final (int, int) t = out[i]!;
    final int nextStart = out[i + 1]!.$1;
    if (t.$2 > nextStart) out[i] = (t.$1, math.max(t.$1 + 1, nextStart));
  }
  return out;
}

/// 把第 [from]..[to]-1 行按字数分进 `[lo, hi)`。
void _spread(
  List<_LineFit> fits,
  List<(int, int)?> out,
  int from,
  int to,
  int lo,
  int hi,
) {
  int total = 0;
  for (int i = from; i < to; i++) {
    total += math.max(1, fits[i].chars);
  }
  final double span = (hi - lo).toDouble();
  int used = 0;
  for (int i = from; i < to; i++) {
    final int w = math.max(1, fits[i].chars);
    final int start = lo + (span * used / total).round();
    used += w;
    final int end = lo + (span * used / total).round();
    out[i] = (start, math.max(start + 1, end));
  }
}

/// 可信行的字速中位数（没有可信行用默认值）。
int _medianCharMs(List<_LineFit> fits) {
  final List<int> rates = <int>[
    for (final _LineFit f in fits)
      if (f.anchored && f.start != null && f.chars > 0)
        ((f.end! - f.start!) / f.chars).round().clamp(_minCharMs, _maxCharMs),
  ]..sort();
  return rates.isEmpty ? _defaultCharMs : rates[rates.length ~/ 2];
}
