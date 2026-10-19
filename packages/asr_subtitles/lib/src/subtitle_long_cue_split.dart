/// 显示后处理：把「多句长条」拆成几条，切点时间取自 ASR 的逐 token 时间。
///
/// 场景是视频字幕管线的最后一步（方案 S5）：按外部分段（MOSS）识别出来的 cue
/// 一段常常装着好几句话、跨七八秒，屏幕上一次铺满两行还停很久。这里只拆**超长**
/// 的条目（时长超过 [SubtitleLongCueSplitOptions.maxDurationMs] 或字数超过
/// [SubtitleLongCueSplitOptions.maxChars]），其余原样保留。
///
/// 规则移植自 asr_bench 的 `subsplit.py` 里被采纳的 `split_aligned`（12 集对人工
/// 字幕实测：切点离人工边界的中位误差从按字数比例的 0.37 s 降到 0.30 s）：
///
/// 1. **切在哪**：句末（`。！？!?…`）之后；短于
///    [SubtitleLongCueSplitOptions.minPieceChars] 的碎片并进前一片（`えっ。` 不单
///    独成条）。没有句末、但时长仍超限的，在最长的 token 间停顿处切一刀（停顿短于
///    [SubtitleLongCueSplitOptions.minPauseMs] 就不切）。
/// 2. **切点什么时刻**：最终文本（可能经 LLM 校对，与识别文本不同）按编辑距离对齐
///    到 token 字符流，切点 = 下一句第一个字的开始时间 − 0.1 s，且不早于上一字的
///    结束时间。没有 token 时间时退回按字数比例分时长。
/// 3. **夹紧**：所有切点夹在 `[起点 + 0.3 s, 终点 − 0.3 s]`，相邻切点至少隔 0.3 s。
///    切点一律先取整到毫秒再夹紧、再比较：浮点切点各自取整后可能落在同一毫秒，
///    那样会产出零时长条目。两条路径对「夹不下」的处理不同，见下文差异。
///
/// 不按 token 时间裁掉条目首尾的静音：同一批实测里那样做时间轴 IoU 反而从 0.773
/// 降到 0.755。
///
/// token 时间带终点（sidecar 的 `e` 字段，CTC 解码器产出）时与原型语义一致：
/// 停顿 = 上一 token 终点到下一 token 起点，−0.1 s 的提前量真的生效（上一字结束
/// 早于下一字开始）。**没有终点时的退化**（旧 sidecar、transducer）：每个 token 的
/// 终点取下一个 token 的起点、最后一个取 cue 终点，于是字符时间首尾相接，切点就落
/// 在下一 token 起点本身；停顿改量相邻 token **起点之间**的间隔，同一个 350 ms 阈值
/// 下偏松。
///
/// 与 Python 原型的其他差异（都是有意的）：
/// - 句末之后紧跟的闭合括号 / 引号（`」』）)` 等）并进前一句，不会被甩到下一条开头。
/// - 夹紧之后切点若仍落在 cue 之外（条目太短、切点太多），丢掉这个切点（相邻两片
///   合并），不产出时长为负或为零的条目。
/// - 按字数比例的退路（没有 token 时间）没有原型约束，夹紧是**硬的**：cue 短于
///   两倍边距（`[起点 + 0.3 s, 终点 − 0.3 s]` 是空区间）时整条不拆；被最小间隔
///   推过 `终点 − 0.3 s` 的切点丢掉（相邻两片合并）。token 路径为与原型逐条一致，
///   保留原型「夹紧后仍在 cue 内就留」的口径。
library;

import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;

import 'subtitle_format.dart';

/// 长条拆分的参数。默认值即方案 S5 / `subsplit.py` 的取值。
class SubtitleLongCueSplitOptions {
  const SubtitleLongCueSplitOptions({
    this.maxDurationMs = 7000,
    this.maxChars = 40,
    this.minPieceChars = 4,
    this.minPauseMs = 350,
    this.boundaryLeadMs = 100,
    this.edgeMarginMs = 300,
    this.minPieceGapMs = 300,
  });

  /// 时长**超过**它（不含等于）才考虑拆。
  final int maxDurationMs;

  /// 去掉首尾空白后的字数（Unicode 码点）**超过**它才考虑拆。
  final int maxChars;

  /// 去掉首尾空白后短于它的片段并进前一片（前一片本身太短时，后一片也并进来）。
  final int minPieceChars;

  /// 无句末时，最长的 token 间停顿（上一 token 终点到下一 token 起点；没有终点时
  /// 退回起点间隔）至少这么长才在那里切。
  final int minPauseMs;

  /// 切点 = 下一句首字开始时间减去这么多（但不早于上一字结束）。
  final int boundaryLeadMs;

  /// 切点离 cue 起止至少这么远。
  final int edgeMarginMs;

  /// 相邻切点至少隔这么远。
  final int minPieceGapMs;
}

/// 句末标点：其后可以切。
const Set<int> _terminators = <int>{
  0x3002, // 。
  0xFF01, // ！
  0xFF1F, // ？
  0x21, // !
  0x3F, // ?
  0x2026, // …
};

/// 紧随句末时并进前一句的闭合符号。
const Set<int> _closingMarks = <int>{
  0x300D, // 」
  0x300F, // 』
  0xFF09, // ）
  0x29, // )
  0x3011, // 】
  0x3015, // 〕
  0x300B, // 》
  0x3009, // 〉
  0x22, // "
  0x201D, // ”
  0x2019, // ’
};

/// 码点是否空白（与 `String.trim` 同一口径够用：ASCII 空白、全角空格、NBSP）。
bool _isSpace(int rune) =>
    rune == 0x20 ||
    (rune >= 0x09 && rune <= 0x0D) ||
    rune == 0x3000 ||
    rune == 0xA0;

int _trimmedLength(List<int> runes, int from, int to) {
  int a = from;
  int b = to;
  while (a < b && _isSpace(runes[a])) {
    a++;
  }
  while (b > a && _isSpace(runes[b - 1])) {
    b--;
  }
  return b - a;
}

/// 这条 cue 是否超长、需要考虑拆分。
bool subtitleCueNeedsSplit(
  SubtitleCue cue, {
  SubtitleLongCueSplitOptions options = const SubtitleLongCueSplitOptions(),
}) {
  final List<int> runes = cue.text.runes.toList(growable: false);
  return cue.endMs - cue.startMs > options.maxDurationMs ||
      _trimmedLength(runes, 0, runes.length) > options.maxChars;
}

/// **纯函数**：按句末切分 [text] 后各片的结束位置（码点偏移，不含最后一片的
/// 结尾），已合并过短碎片。没有可切处时返回空列表。
List<int> subtitleSentenceCuts(
  String text, {
  int minPieceChars = 4,
}) =>
    _sentenceCuts(text.runes.toList(growable: false), minPieceChars);

List<int> _sentenceCuts(List<int> runes, int minPieceChars) {
  // 先按句末（及紧随的闭合符号）切成原始片段：[from, to)。
  final List<(int, int)> parts = <(int, int)>[];
  int from = 0;
  for (int i = 0; i < runes.length; i++) {
    if (!_terminators.contains(runes[i])) continue;
    int to = i + 1;
    while (to < runes.length && _closingMarks.contains(runes[to])) {
      to++;
    }
    parts.add((from, to));
    from = to;
    i = to - 1;
  }
  if (from < runes.length) parts.add((from, runes.length));
  // 合并：纯空白片段、过短片段并进前一片；前一片过短时后一片也并进来。
  final List<(int, int)> pieces = <(int, int)>[];
  for (final (int a, int b) in parts) {
    final int len = _trimmedLength(runes, a, b);
    if (pieces.isNotEmpty &&
        (len < minPieceChars ||
            _trimmedLength(runes, pieces.last.$1, pieces.last.$2) <
                minPieceChars)) {
      pieces[pieces.length - 1] = (pieces.last.$1, b);
    } else {
      pieces.add((a, b));
    }
  }
  return <int>[
    for (int i = 0; i + 1 < pieces.length; i++) pieces[i].$2,
  ];
}

/// 拆分产物的一片：拆出来的 cue，以及落在这一片里的 token 时间（偏移已改成相对
/// **这一片**的起点）。导出时按这个列表写 SRT 和 tokens sidecar，两者行号一一对应。
class SubtitleCueWithTokenTiming {
  const SubtitleCueWithTokenTiming(this.cue, this.tokenTiming);

  final SubtitleCue cue;

  /// 这一片的 token 时间；原 cue 没给 token 时间、或按字数比例拆（没法把 token
  /// 归到片）时为 null。偏移可以为负（token 起点早于片起点：切点被夹紧挪后时）。
  final AsrCueTokenTiming? tokenTiming;
}

/// 拆一整份字幕。[tokenTimings] 给出时必须与 [cues] 等长、按下标一一对应（某条没有
/// 就放 null）；不等长直接抛 [ArgumentError]——错位比没有更糟。输出按顺序重新编号
/// （从 1 起）。要连 token 时间一起拆用 [splitLongSubtitleCuesWithTokenTimings]。
List<SubtitleCue> splitLongSubtitleCues(
  List<SubtitleCue> cues, {
  List<AsrCueTokenTiming?>? tokenTimings,
  SubtitleLongCueSplitOptions options = const SubtitleLongCueSplitOptions(),
}) =>
    <SubtitleCue>[
      for (final SubtitleCueWithTokenTiming piece
          in splitLongSubtitleCuesWithTokenTimings(
        cues,
        tokenTimings: tokenTimings,
        options: options,
      ))
        piece.cue,
    ];

/// [splitLongSubtitleCues] 的同时返回每片 token 时间的版本。
///
/// token 归属：按 token 第一个有效字符在 token 字符流里的位置，落在哪一片的字符流
/// 区间就归哪一片（片界 = 切点在字符流里的对齐位置，与算切点时刻用的是同一个对齐）。
/// 切点落在多字 token 内部时，整个 token 归它起点所在的那一片。没拆的条目原样带回
/// 自己的 token 时间。
List<SubtitleCueWithTokenTiming> splitLongSubtitleCuesWithTokenTimings(
  List<SubtitleCue> cues, {
  List<AsrCueTokenTiming?>? tokenTimings,
  SubtitleLongCueSplitOptions options = const SubtitleLongCueSplitOptions(),
}) {
  if (tokenTimings != null && tokenTimings.length != cues.length) {
    throw ArgumentError.value(
      tokenTimings.length,
      'tokenTimings',
      '必须与 cues（${cues.length} 条）一一对应',
    );
  }
  final List<SubtitleCueWithTokenTiming> out = <SubtitleCueWithTokenTiming>[];
  for (int i = 0; i < cues.length; i++) {
    for (final SubtitleCueWithTokenTiming piece
        in splitLongSubtitleCueWithTokenTiming(
      cues[i],
      tokenTiming: tokenTimings?[i],
      options: options,
    )) {
      out.add(
        SubtitleCueWithTokenTiming(
          SubtitleCue(
            index: out.length + 1,
            startMs: piece.cue.startMs,
            endMs: piece.cue.endMs,
            text: piece.cue.text,
          ),
          piece.tokenTiming,
        ),
      );
    }
  }
  return out;
}

/// 拆一条。不超长、或找不到切点时原样返回（单元素列表）。各片沿用原 cue 的
/// [SubtitleCue.index]，重新编号交给 [splitLongSubtitleCues]。
///
/// [tokenTiming] 是这条 cue 的识别 token 及其相对 cue 起点的开始（与可选的结束）
/// 时刻（`transcript.tokens.jsonl` 的一行）；它的文本可以与 [SubtitleCue.text]
/// 不同（LLM 校对过），对齐容忍增删改。null 或有效字符不足 2 个时按字数比例分时长。
List<SubtitleCue> splitLongSubtitleCue(
  SubtitleCue cue, {
  AsrCueTokenTiming? tokenTiming,
  SubtitleLongCueSplitOptions options = const SubtitleLongCueSplitOptions(),
}) =>
    <SubtitleCue>[
      for (final SubtitleCueWithTokenTiming piece
          in splitLongSubtitleCueWithTokenTiming(
        cue,
        tokenTiming: tokenTiming,
        options: options,
      ))
        piece.cue,
    ];

/// [splitLongSubtitleCue] 的同时返回每片 token 时间的版本（归属规则见
/// [splitLongSubtitleCuesWithTokenTimings]）。
List<SubtitleCueWithTokenTiming> splitLongSubtitleCueWithTokenTiming(
  SubtitleCue cue, {
  AsrCueTokenTiming? tokenTiming,
  SubtitleLongCueSplitOptions options = const SubtitleLongCueSplitOptions(),
}) {
  final List<SubtitleCueWithTokenTiming> unchanged =
      <SubtitleCueWithTokenTiming>[
    SubtitleCueWithTokenTiming(cue, tokenTiming),
  ];
  if (!subtitleCueNeedsSplit(cue, options: options)) return unchanged;
  final List<int> text = cue.text.runes.toList(growable: false);
  final _CharTimes? chars =
      tokenTiming == null ? null : _charTimes(tokenTiming, cue);
  if (chars == null || chars.runes.length < 2) {
    final List<_Piece>? pieces = _splitProportional(cue, text, options);
    if (pieces == null) return unchanged;
    return <SubtitleCueWithTokenTiming>[
      for (final _Piece p in pieces) SubtitleCueWithTokenTiming(p.cue, null),
    ];
  }
  final List<int> map = _alignToStream(text, chars.runes);

  /// 切在文本位置 [k] 之前时，下一片首字在字符流里的下标（夹进 `[1, 流长 − 1]`）。
  int streamIndex(int k) {
    int j = map[k];
    if (j < 1) j = 1;
    if (j > chars.runes.length - 1) j = chars.runes.length - 1;
    return j;
  }

  /// 切在文本位置 [k] 之前时的时刻（相对 cue 起点，毫秒）。
  double boundaryTime(int k) {
    final int j = streamIndex(k);
    final double next = chars.startMs[j] - options.boundaryLeadMs;
    final double prevEnd = chars.endMs[j - 1];
    return next > prevEnd ? next : prevEnd;
  }

  List<int> cuts = _sentenceCuts(text, options.minPieceChars);
  final int durationMs = cue.endMs - cue.startMs;
  if (cuts.isEmpty && durationMs > options.maxDurationMs) {
    cuts = _pauseCut(text, tokenTiming!, map, options);
  }
  if (cuts.isEmpty) return unchanged;
  final List<int> times = _clampedCutTimes(
    <double>[for (final int k in cuts) boundaryTime(k)],
    durationMs,
    options,
  );
  final List<_Piece>? pieces = _pieces(cue, text, cuts, times);
  if (pieces == null) return unchanged;
  // 每片在字符流里的起点：第一片从 0 起，其余取切点的对齐位置。
  final List<int> streamStarts = <int>[
    for (int p = 0; p < pieces.length; p++)
      p == 0 ? 0 : streamIndex(pieces[p].textStart),
  ];
  final List<List<int>> owned =
      List<List<int>>.generate(pieces.length, (_) => <int>[]);
  for (int t = 0; t < tokenTiming!.tokens.length; t++) {
    final int c = chars.tokenCharStart[t];
    int p = pieces.length - 1;
    while (p > 0 && c < streamStarts[p]) {
      p--;
    }
    owned[p].add(t);
  }
  final List<int>? ends = tokenTiming.endOffsetsMs;
  return <SubtitleCueWithTokenTiming>[
    for (int p = 0; p < pieces.length; p++)
      SubtitleCueWithTokenTiming(
        pieces[p].cue,
        AsrCueTokenTiming(
          tokens: <String>[for (final int t in owned[p]) tokenTiming.tokens[t]],
          offsetsMs: <int>[
            for (final int t in owned[p])
              tokenTiming.offsetsMs[t] - (pieces[p].cue.startMs - cue.startMs),
          ],
          endOffsetsMs: ends == null
              ? null
              : <int>[
                  for (final int t in owned[p])
                    ends[t] - (pieces[p].cue.startMs - cue.startMs),
                ],
        ),
      ),
  ];
}

/// 无句末的超长条：在最长的 token 间停顿处切（够 [SubtitleLongCueSplitOptions.minPauseMs]
/// 才切），切点映射回最终文本里离它最近的位置；两边都要留够 minPieceChars 个字。
///
/// 停顿 = 上一 token **终点**到下一 token 起点；没有终点（旧 sidecar / transducer）
/// 时退回相邻 token 起点之间的间隔（含 token 自身时长，同一阈值下更容易切）。
List<int> _pauseCut(
  List<int> text,
  AsrCueTokenTiming timing,
  List<int> map,
  SubtitleLongCueSplitOptions options,
) {
  final List<int> o = timing.offsetsMs;
  final List<int>? e = timing.endOffsetsMs;
  if (o.length < 2) return const <int>[];
  int bestGap = -0x7fffffff;
  int bestAt = -1;
  for (int i = 0; i + 1 < o.length; i++) {
    final int gap = o[i + 1] - (e == null ? o[i] : e[i]);
    // 同长取靠后的一处：与原型 `max(gaps)` 对 (gap, i) 元组取最大一致。
    if (gap >= bestGap) {
      bestGap = gap;
      bestAt = i;
    }
  }
  if (bestGap < options.minPauseMs) return const <int>[];
  // 停顿前有多少个有效字符（token 去首尾空白后的码点数）。
  int wpos = 0;
  for (int i = 0; i <= bestAt; i++) {
    wpos += timing.tokens[i].trim().runes.length;
  }
  if (text.length < 2) return const <int>[];
  int k = 1;
  int bestDist = (map[1] - wpos).abs();
  for (int x = 2; x < text.length; x++) {
    final int d = (map[x] - wpos).abs();
    if (d < bestDist) {
      bestDist = d;
      k = x;
    }
  }
  if (k < options.minPieceChars || k > text.length - options.minPieceChars) {
    return const <int>[];
  }
  return <int>[k];
}

/// 拆出来的一片及其在最终文本里的起点（码点偏移，未去空白）。
class _Piece {
  const _Piece(this.cue, this.textStart);

  final SubtitleCue cue;
  final int textStart;
}

/// 按字数比例分时长（没有 token 时间时）：切点 = 起点 + 时长 × 偏移 / 总字数，
/// 再按 [SubtitleLongCueSplitOptions.edgeMarginMs] /
/// [SubtitleLongCueSplitOptions.minPieceGapMs] 硬夹紧（见文件头「差异」）。
/// 没有切点、或 cue 短到容不下两侧边距时返回 null（= 不拆）。
List<_Piece>? _splitProportional(
  SubtitleCue cue,
  List<int> text,
  SubtitleLongCueSplitOptions options,
) {
  final List<int> cuts = _sentenceCuts(text, options.minPieceChars);
  if (cuts.isEmpty) return null;
  final int duration = cue.endMs - cue.startMs;
  final int hi = duration - options.edgeMarginMs;
  // 容不下 [边距, 时长 − 边距] 这个区间：切哪儿都违反边距，整条不拆。
  if (hi < options.edgeMarginMs) return null;
  final List<int> times = _clampedCutTimes(
    <double>[for (final int k in cuts) duration * k / text.length],
    duration,
    options,
  );
  final List<int> keptCuts = <int>[];
  final List<int> keptTimes = <int>[];
  for (int i = 0; i < cuts.length; i++) {
    // 被最小间隔推过上界的切点丢掉；后面的切点只会更晚，一并丢掉。
    if (times[i] > hi) break;
    keptCuts.add(cuts[i]);
    keptTimes.add(times[i]);
  }
  return _pieces(cue, text, keptCuts, keptTimes);
}

/// 切点时刻（相对 cue 起点，毫秒）的公共夹紧：先取整到毫秒，再夹进
/// `[边距, 时长 − 边距]`（与原型 `min(max(v, lo), hi)` 同序：区间为空时取上界），
/// 再保证相邻切点至少隔 [SubtitleLongCueSplitOptions.minPieceGapMs]。整数运算，
/// 结果与「浮点夹紧后再取整」相同，但后续比较不会被取整打穿。
List<int> _clampedCutTimes(
  List<double> raw,
  int durationMs,
  SubtitleLongCueSplitOptions options,
) {
  final int lo = options.edgeMarginMs;
  final int hi = durationMs - options.edgeMarginMs;
  final List<int> times = <int>[
    for (final double v in raw) _clampInt(v.round(), lo, hi),
  ];
  for (int i = 1; i < times.length; i++) {
    final int floor = times[i - 1] + options.minPieceGapMs;
    if (times[i] < floor) times[i] = floor;
  }
  return times;
}

/// 按切点（码点偏移）与切点时刻（相对 cue 起点，整数毫秒）组装各片；去掉首尾
/// 空白后为空的片段不输出，落在 cue 之外 / 不严格递增的切点丢掉（相邻两片合并），
/// 所以每片时长都 > 0。一个切点都不剩时返回 null（= 不拆）。
List<_Piece>? _pieces(
  SubtitleCue cue,
  List<int> text,
  List<int> cuts,
  List<int> times,
) {
  final int duration = cue.endMs - cue.startMs;
  final List<int> keptCuts = <int>[];
  final List<int> keptTimes = <int>[];
  for (int i = 0; i < cuts.length; i++) {
    final int t = times[i];
    final int prev = keptTimes.isEmpty ? 0 : keptTimes.last;
    if (t <= prev || t >= duration) continue;
    keptCuts.add(cuts[i]);
    keptTimes.add(t);
  }
  if (keptCuts.isEmpty) return null;
  final List<int> edges = <int>[0, ...keptCuts, text.length];
  final List<int> bounds = <int>[
    cue.startMs,
    for (final int t in keptTimes) cue.startMs + t,
    cue.endMs,
  ];
  final List<_Piece> out = <_Piece>[];
  for (int i = 0; i + 1 < edges.length; i++) {
    final String piece =
        String.fromCharCodes(text.sublist(edges[i], edges[i + 1])).trim();
    if (piece.isEmpty) continue;
    out.add(
      _Piece(
        SubtitleCue(
          index: cue.index,
          startMs: bounds[i],
          endMs: bounds[i + 1],
          text: piece,
        ),
        edges[i],
      ),
    );
  }
  return out;
}

int _clampInt(int v, int lo, int hi) {
  // 与原型 `min(max(v, lo), hi)` 同序：lo > hi 时取 hi。
  final int a = v > lo ? v : lo;
  return a < hi ? a : hi;
}

/// token 字符流：每个有效字符（token 去首尾空白后的码点）的开始 / 结束时刻
/// （相对 cue 起点，毫秒），以及每个 token 的第一个字符在流里的下标。
///
/// token 的区间 = `[起点, 终点]`；没有终点时终点取下一 token 起点（最后一个取
/// cue 终点）。token 内按字符均分（同原型 `_char_times`）。
class _CharTimes {
  _CharTimes(this.runes, this.startMs, this.endMs, this.tokenCharStart);

  final List<int> runes;
  final List<double> startMs;
  final List<double> endMs;

  /// 下标 = token 下标；空白 token 取它所在位置（= 下一个有效字符的下标）。
  final List<int> tokenCharStart;
}

_CharTimes? _charTimes(AsrCueTokenTiming timing, SubtitleCue cue) {
  final List<int>? ends = timing.endOffsetsMs;
  if (timing.tokens.length != timing.offsetsMs.length ||
      (ends != null && ends.length != timing.tokens.length)) {
    return null;
  }
  final int duration = cue.endMs - cue.startMs;
  final List<int> runes = <int>[];
  final List<double> st = <double>[];
  final List<double> en = <double>[];
  final List<int> tokenStart = <int>[];
  for (int i = 0; i < timing.tokens.length; i++) {
    tokenStart.add(runes.length);
    final List<int> w = timing.tokens[i].trim().runes.toList(growable: false);
    if (w.isEmpty) continue;
    final double a = timing.offsetsMs[i].toDouble();
    final double rawB = ends != null
        ? ends[i].toDouble()
        : i + 1 < timing.offsetsMs.length
            ? timing.offsetsMs[i + 1].toDouble()
            : duration.toDouble();
    // 偏移不单调（或末 token 越过 cue 终点）时不让时长为负。
    final double b = rawB > a ? rawB : a;
    for (int c = 0; c < w.length; c++) {
      runes.add(w[c]);
      st.add(a + (b - a) * c / w.length);
      en.add(a + (b - a) * (c + 1) / w.length);
    }
  }
  return _CharTimes(runes, st, en, tokenStart);
}

/// 最终文本每个码点对齐到 token 字符流的哪个下标（长度 = text.length + 1，末项
/// = 流长度）。Levenshtein 回溯：匹配 / 替换 → 对应字符；文本多出来的字（流里没
/// 有）→ 流里它所在位置的下一个字符；流里多出来的字跳过。
List<int> _alignToStream(List<int> text, List<int> stream) {
  final int n = text.length;
  final int m = stream.length;
  final int w = m + 1;
  final List<int> d = List<int>.filled((n + 1) * w, 0);
  for (int j = 0; j <= m; j++) {
    d[j] = j;
  }
  for (int i = 1; i <= n; i++) {
    d[i * w] = i;
    for (int j = 1; j <= m; j++) {
      final int sub =
          d[(i - 1) * w + j - 1] + (text[i - 1] == stream[j - 1] ? 0 : 1);
      final int del = d[(i - 1) * w + j] + 1;
      final int ins = d[i * w + j - 1] + 1;
      int best = sub;
      if (del < best) best = del;
      if (ins < best) best = ins;
      d[i * w + j] = best;
    }
  }
  final List<int> map = List<int>.filled(n + 1, 0);
  map[n] = m;
  int i = n;
  int j = m;
  while (i > 0) {
    final int here = d[i * w + j];
    if (j > 0 &&
        here ==
            d[(i - 1) * w + j - 1] + (text[i - 1] == stream[j - 1] ? 0 : 1)) {
      map[i - 1] = j - 1;
      i--;
      j--;
    } else if (here == d[(i - 1) * w + j] + 1) {
      map[i - 1] = j;
      i--;
    } else {
      j--;
    }
  }
  return map;
}

/// 半角 `!` `?` 统一成全角 `！` `？`（方案 S5：字幕标点统一为全角）。只动这两个
/// 字符，其余原样。
String normalizeSubtitlePunctuationToFullWidth(String text) =>
    text.replaceAll('!', '！').replaceAll('?', '？');
