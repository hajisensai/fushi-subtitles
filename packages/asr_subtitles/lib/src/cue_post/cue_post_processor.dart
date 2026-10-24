import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'cue_post_library.dart';

/// 设备端转录产物（与正文对齐后的有声书逐句 cue）的落库前后处理：
///
/// 1. [AsrCuePostStage.snap]：紧挨着的两条 cue 之间的切点吸到能量谷（真实停顿）上；
/// 2. [AsrCuePostStage.refineEdges]：起止点落在静音里时收回到真实有声处；
/// 3. [AsrCuePostStage.mergeFragments]：正文句内的短碎片并回相邻 cue（只并不拆）；
/// 4. [AsrCuePostStage.displayMargins]：按语速给跟读显示留余量（只外扩）。
///
/// 判定本体在 Rust（`native/asr_cue_post`），整本书一次 FFI 调用；这里只打包输入、
/// 按原生侧给出的起止与分组拼出结果（含 token 偏移的平移与拼接）。
enum AsrCuePostStage { snap, refineEdges, mergeFragments, displayMargins }

/// 一条输入 cue。
final class AsrPostCue {
  const AsrPostCue({
    required this.startMs,
    required this.endMs,
    this.audioFileIndex = 0,
    this.text = '',
    this.tokenOffsetsMs,
    this.sectionIndex = -1,
    this.normCharStart = -1,
    this.normCharEnd = -1,
  });

  final int startMs;
  final int endMs;

  /// 所属音频文件；跨文件的邻居互不影响。
  final int audioFileIndex;

  /// 正文文本（已换成书里的原文）；合并的句末判定与余量的字速分档都看它。
  final String text;

  /// 逐 token 发射时刻，相对 [startMs]；null = 没有 token 时间。
  final List<int>? tokenOffsetsMs;

  /// 命中的正文章节序号；< 0 = 未命中（未命中的 cue 不参与合并）。
  final int sectionIndex;

  /// 命中的正文区间（归一化字符偏移）；合并要求前条终点 = 后条起点。
  final int normCharStart;
  final int normCharEnd;
}

/// 输出的一条：输入第 [firstIndex] .. [lastIndex] 条（含两端）并成的结果。
final class AsrPostCueGroup {
  const AsrPostCueGroup({
    required this.firstIndex,
    required this.lastIndex,
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.tokenOffsetsMs,
  });

  final int firstIndex;
  final int lastIndex;
  final int startMs;
  final int endMs;

  /// 各条文本首尾相接。
  final String text;

  /// 相对 [startMs] 的 token 偏移：各条（平移到新起点后）首尾相接；任一条没有 token
  /// 时间则为 null。
  final List<int>? tokenOffsetsMs;

  /// 是否由多条并成。
  bool get isMerged => lastIndex > firstIndex;
}

/// [AsrCuePostProcessor.process] 的结果。
final class AsrCuePostResult {
  const AsrCuePostResult({
    required this.groups,
    required this.snappedBoundaries,
    required this.refinedEdges,
    required this.mergedFragments,
    required this.displayMarginEdges,
  });

  /// 按时间排序，与输入一一覆盖（并集 = 全部输入）。
  final List<AsrPostCueGroup> groups;

  /// 吸附挪动的切点数。
  final int snappedBoundaries;

  /// 修边挪动的边数。
  final int refinedEdges;

  /// 并进前一条的输入条数（= 输入条数 − 组数）。
  final int mergedFragments;

  /// 余量动过的边数。
  final int displayMarginEdges;
}

/// 能量吸附与修边的参数（默认值即 Fushi 有声书导入的取值）。
final class AsrEnergySnapOptions {
  const AsrEnergySnapOptions({
    this.frameMs = 20,
    this.maxGapMs = 400,
    this.windowMs = 600,
    this.minValleyMs = 120,
    this.distancePenalty = 0.5,
    this.tailMs = 80,
    this.leadMs = 40,
    this.minDurationMs = 500,
    this.floorMarginDb = 16,
    this.minThresholdDb = -50,
    this.maxThresholdDb = -30,
    this.tokenGuardMs = 1000,
    this.edgeMaxShiftMs = 600,
    this.edgeMinVoiceMs = 60,
    this.edgeLeadMs = 150,
    this.edgeTailMs = 80,
    this.cutBiasMs = 350,
  });

  /// 包络帧长（与转录时写入的一致）。
  final int frameMs;

  /// 两条 cue 之间空隙超过此值就不算「紧挨着」（那是 VAD 已经切开的停顿）。
  final int maxGapMs;

  /// 在原切点前后多远内找谷。
  final int windowMs;

  /// 谷的最短长度：塞音闭塞只有几十毫秒，不算句间停顿。
  final int minValleyMs;

  /// 选谷打分 = 谷长 − 此系数 × 谷中心离原切点的距离（都按毫秒）。
  final double distancePenalty;

  /// 前句终点在谷起点之后留的余韵。
  final int tailMs;

  /// 后句起点在谷终点之前提前的量。
  final int leadMs;

  /// 吸附 / 修边后 cue 不得短于此值，否则不动。
  final int minDurationMs;

  /// 门限 = 附近 ±15 s 电平第 10 百分位（底噪）+ 此值，夹到
  /// [[minThresholdDb], [maxThresholdDb]]。
  final double floorMarginDb;
  final double minThresholdDb;
  final double maxThresholdDb;

  /// 后句新起点不晚于它首 token 发射时刻 + 此值；修边后的终点不早于末 token − 此值。
  /// RNN-T 首 token 常比开口早 400~700 ms，200 ms 会把正确的谷拦下。
  final int tokenGuardMs;

  /// 修边：起止点最多往 cue 内收多远。
  final int edgeMaxShiftMs;

  /// 修边：多长的连续有声才算真开口 / 真收声（滤掉单帧噪声）。
  final int edgeMinVoiceMs;

  /// 修边：起点挪到开口前多少（轻声开口常在门限下，比 [leadMs] 宽）。
  final int edgeLeadMs;

  /// 修边：终点留到收声后多少。
  final int edgeTailMs;

  /// 选谷的中心相对 token 推算切点往后挪多少（RNN-T 发射系统性偏早，切点跟着偏早；
  /// 四个系列 7 本扫 0 / 200 / 350，350 时句间早切最少）。
  final int cutBiasMs;

  List<double> _encode() => <double>[
        frameMs.toDouble(),
        maxGapMs.toDouble(),
        windowMs.toDouble(),
        minValleyMs.toDouble(),
        distancePenalty,
        tailMs.toDouble(),
        leadMs.toDouble(),
        minDurationMs.toDouble(),
        floorMarginDb,
        minThresholdDb,
        maxThresholdDb,
        tokenGuardMs.toDouble(),
        edgeMaxShiftMs.toDouble(),
        edgeMinVoiceMs.toDouble(),
        edgeLeadMs.toDouble(),
        edgeTailMs.toDouble(),
        cutBiasMs.toDouble(),
      ];
}

/// 句内碎片合并的参数。
final class AsrFragmentMergeOptions {
  const AsrFragmentMergeOptions({
    this.shortMs = 1200,
    this.maxChars = 40,
    this.maxDurationMs = 10000,
    this.maxGapMs = 1500,
  });

  /// 任一侧短于此值才并（两侧都够长的句内停顿保持分开）。
  final int shortMs;

  /// 合并后的正文字数上限（UTF-16 码元，含标点）。
  final int maxChars;

  /// 合并后的时长上限。
  final int maxDurationMs;

  /// 两条之间的停顿上限：再长就是朗读者真的停住了。
  final int maxGapMs;

  List<double> _encode() => <double>[
        shortMs.toDouble(),
        maxChars.toDouble(),
        maxDurationMs.toDouble(),
        maxGapMs.toDouble(),
      ];
}

/// 跟读显示余量的参数：按有声跨度的字速分慢 / 正常 / 快三档。
final class AsrDisplayMarginOptions {
  const AsrDisplayMarginOptions({
    this.frameMs = 20,
    this.floorMarginDb = 16,
    this.minThresholdDb = -50,
    this.maxThresholdDb = -30,
    this.minVoiceMs = 60,
    this.slowCps = 5.5,
    this.fastCps = 7.0,
    this.headSlowMs = 120,
    this.headNormalMs = 80,
    this.headFastMs = 40,
    this.tailSlowMs = 180,
    this.tailNormalMs = 100,
    this.tailFastMs = 20,
    this.gapTailRatio = 0.18,
    this.tailCapMs = 250,
    this.glueMs = 400,
    this.tailSafetyMs = 50,
  });

  /// 包络帧长（与转录时写入的一致）。
  final int frameMs;

  /// 有声门限（与吸附同口径）。
  final double floorMarginDb;
  final double minThresholdDb;
  final double maxThresholdDb;

  /// 多长的连续有声才算真开口 / 真收声。
  final int minVoiceMs;

  /// 字速分档（正文字母 / 数字 / 假名 / 汉字每秒）：低于 [slowCps] 为慢，不低于
  /// [fastCps] 为快。
  final double slowCps;
  final double fastCps;

  /// 起点在开口前留的毫秒数，按慢 / 正常 / 快。
  final int headSlowMs;
  final int headNormalMs;
  final int headFastMs;

  /// 终点在收声后留的基础毫秒数，按慢 / 正常 / 快（快档不吃停顿项）。
  final int tailSlowMs;
  final int tailNormalMs;
  final int tailFastMs;

  /// 慢 / 正常档尾巴还可以取 `(停顿 − glueMs) × gapTailRatio`，与基础量取大。
  final double gapTailRatio;

  /// 尾巴上限。
  final int tailCapMs;

  /// 与邻句空地不超过此值视为连读，该侧不加余量。
  final int glueMs;

  /// 终点与下一条起点之间至少留的空隙。
  final int tailSafetyMs;

  List<double> _encode() => <double>[
        frameMs.toDouble(),
        floorMarginDb,
        minThresholdDb,
        maxThresholdDb,
        minVoiceMs.toDouble(),
        slowCps,
        fastCps,
        headSlowMs.toDouble(),
        headNormalMs.toDouble(),
        headFastMs.toDouble(),
        tailSlowMs.toDouble(),
        tailNormalMs.toDouble(),
        tailFastMs.toDouble(),
        gapTailRatio,
        tailCapMs.toDouble(),
        glueMs.toDouble(),
        tailSafetyMs.toDouble(),
      ];
}

typedef _ProcessC = Int32 Function(
  Pointer<Int8>,
  Size,
  Pointer<Int64>,
  Size,
  Pointer<Uint16>,
  Size,
  Pointer<Int64>,
  Pointer<Double>,
  Int32,
  Pointer<Int64>,
  Pointer<Int64>,
  Pointer<Int64>,
);
typedef _ProcessDart = int Function(
  Pointer<Int8>,
  int,
  Pointer<Int64>,
  int,
  Pointer<Uint16>,
  int,
  Pointer<Int64>,
  Pointer<Double>,
  int,
  Pointer<Int64>,
  Pointer<Int64>,
  Pointer<Int64>,
);

const int _cueStride = 9;
const int _statsLen = 5;
const int _paramCount = 17 + 4 + 17;

/// 原生侧返回码。
const int _statusOk = 0;
const int _statusInvalid = -2;

/// 整本书的转录 cue 后处理。
final class AsrCuePostProcessor {
  /// [library] 缺省为本仓自己的原生库（[AsrCuePostLibrary.instance]）；宿主把 crate
  /// 编进了自己的库时传 [AsrCuePostLibrary.fromDynamicLibrary]。
  AsrCuePostProcessor({
    AsrCuePostLibrary? library,
    this.snap = const AsrEnergySnapOptions(),
    this.merge = const AsrFragmentMergeOptions(),
    this.margins = const AsrDisplayMarginOptions(),
  }) : _library = library;

  final AsrCuePostLibrary? _library;
  final AsrEnergySnapOptions snap;
  final AsrFragmentMergeOptions merge;
  final AsrDisplayMarginOptions margins;

  /// 跑 [stages] 选中的步骤（缺省全部）。[energyDb] 为从时间 0 起每帧的整数 dBFS
  /// （0 = 未知，按有声处理）；为空时吸附 / 修边 / 余量跳过（合并照常）。
  ///
  /// [cues] 须按时间排序。原生库不可用抛 [AsrCuePostUnavailableError]；参数非法
  /// （整数参数非整数、帧长 ≤ 0、门限上下限颠倒、慢档字速高于快档）抛 [ArgumentError]。
  AsrCuePostResult process(
    List<AsrPostCue> cues,
    Int8List energyDb, {
    Set<AsrCuePostStage> stages = const <AsrCuePostStage>{
      AsrCuePostStage.snap,
      AsrCuePostStage.refineEdges,
      AsrCuePostStage.mergeFragments,
      AsrCuePostStage.displayMargins,
    },
  }) {
    final AsrCuePostLibrary lib = _library ?? AsrCuePostLibrary.instance;
    final _ProcessDart fn = lib.library.lookupFunction<_ProcessC, _ProcessDart>(
      'fcp_cue_post_process',
    );
    final int n = cues.length;
    final List<int> units = <int>[];
    final Int64List offsets = Int64List(n + 1);
    for (int i = 0; i < n; i++) {
      units.addAll(cues[i].text.codeUnits);
      offsets[i + 1] = units.length;
    }
    final List<double> params = <double>[
      ...snap._encode(),
      ...merge._encode(),
      ...margins._encode(),
    ];
    assert(params.length == _paramCount);
    int mask = 0;
    for (final AsrCuePostStage s in stages) {
      mask |= 1 << s.index;
    }

    final Int64List packed = Int64List(math.max(1, n * _cueStride));
    for (int i = 0; i < n; i++) {
      final AsrPostCue c = cues[i];
      final List<int>? t = c.tokenOffsetsMs;
      final bool hasTokens = t != null && t.isNotEmpty;
      packed.setAll(i * _cueStride, <int>[
        c.startMs,
        c.endMs,
        c.audioFileIndex,
        hasTokens ? 1 : 0,
        hasTokens ? t.first : 0,
        hasTokens ? t.last : 0,
        c.sectionIndex,
        c.normCharStart,
        c.normCharEnd,
      ]);
    }

    final Int64List groupOf = Int64List(n);
    final Int64List times = Int64List(2 * n);
    final Int64List stats = Int64List(_statsLen);
    using((Arena arena) {
      final Pointer<Int8> e = arena<Int8>(math.max(1, energyDb.length));
      e.asTypedList(math.max(1, energyDb.length)).setAll(0, energyDb);
      final Pointer<Int64> c = arena<Int64>(packed.length);
      c.asTypedList(packed.length).setAll(0, packed);
      final Pointer<Uint16> u = arena<Uint16>(math.max(1, units.length));
      u.asTypedList(math.max(1, units.length)).setAll(0, units);
      final Pointer<Int64> o = arena<Int64>(n + 1);
      o.asTypedList(n + 1).setAll(0, offsets);
      final Pointer<Double> p = arena<Double>(_paramCount);
      p.asTypedList(_paramCount).setAll(0, params);
      final Pointer<Int64> g = arena<Int64>(math.max(1, n));
      final Pointer<Int64> tm = arena<Int64>(math.max(1, 2 * n));
      final Pointer<Int64> st = arena<Int64>(_statsLen);
      final int rc = fn(
        e,
        energyDb.length,
        c,
        n,
        u,
        units.length,
        o,
        p,
        mask,
        g,
        tm,
        st,
      );
      if (rc == _statusInvalid) {
        throw ArgumentError('invalid cue post-processing parameters');
      }
      if (rc != _statusOk) {
        throw StateError('fcp_cue_post_process failed with status $rc');
      }
      packed.setAll(0, c.asTypedList(packed.length));
      groupOf.setAll(0, g.asTypedList(n));
      times.setAll(0, tm.asTypedList(2 * n));
      stats.setAll(0, st.asTypedList(_statsLen));
    });

    final List<AsrPostCueGroup> groups = <AsrPostCueGroup>[];
    int first = 0;
    while (first < n) {
      int last = first;
      while (last + 1 < n && groupOf[last + 1] == groupOf[first]) {
        last++;
      }
      groups.add(_group(cues, packed, times, groups.length, first, last));
      first = last + 1;
    }
    return AsrCuePostResult(
      groups: List<AsrPostCueGroup>.unmodifiable(groups),
      snappedBoundaries: stats[1],
      refinedEdges: stats[2],
      mergedFragments: stats[3],
      displayMarginEdges: stats[4],
    );
  }

  /// 拼一组：token 偏移先按吸附 + 修边后的新起点平移（夹到 ≥ 0，绝对发射时刻不变），
  /// 各条按相对首条起点的位移首尾相接，最后按余量挪动的起点再平移（不夹）。
  static AsrPostCueGroup _group(
    List<AsrPostCue> cues,
    Int64List packed,
    Int64List times,
    int g,
    int first,
    int last,
  ) {
    final int groupStart = packed[first * _cueStride];
    final StringBuffer text = StringBuffer();
    List<int>? offsets = <int>[];
    for (int i = first; i <= last; i++) {
      final AsrPostCue c = cues[i];
      text.write(c.text);
      final List<int>? t = c.tokenOffsetsMs;
      if (t == null) {
        offsets = null;
        continue;
      }
      if (offsets == null) continue;
      final int start = packed[i * _cueStride];
      final int delta = start - c.startMs;
      final int shift = start - groupStart;
      for (final int o in t) {
        offsets.add((delta == 0 ? o : math.max(0, o - delta)) + shift);
      }
    }
    final int finalStart = times[2 * g];
    final int marginDelta = finalStart - groupStart;
    if (offsets != null && marginDelta != 0) {
      for (int k = 0; k < offsets.length; k++) {
        offsets[k] -= marginDelta;
      }
    }
    return AsrPostCueGroup(
      firstIndex: first,
      lastIndex: last,
      startMs: finalStart,
      endMs: times[2 * g + 1],
      text: text.toString(),
      tokenOffsetsMs: offsets == null ? null : List<int>.unmodifiable(offsets),
    );
  }
}
