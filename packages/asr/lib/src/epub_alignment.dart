import 'dart:io';

import 'package:fushi_asr_align/asr_align.dart';
import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;
import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'transcribe_runner.dart';
export 'package:fushi_asr_align/asr_align.dart'
    show
        CueMatch,
        EpubBook,
        EpubCueMatcher,
        EpubSrtMatcher,
        readEpubBook,
        maxEpubBytes;

class BookAlignedSubtitles {
  const BookAlignedSubtitles(this.text, this.cueCount, this.stats,
      {this.matches = const <CueMatch>[]});
  final String text;
  final int cueCount;
  final Map<String, Object?> stats;

  /// 每条**输出** cue 的正文位置（与 [text] 里的 cue 一一对应，下标即 cue 序号
  /// -1；未命中为 [CueMatch.unmatched]）。`sectionIndex` 是 [EpubBook.sections]
  /// 下标，`normCharStart/End` 是该节归一化正文里的字符区间。
  ///
  /// 匹配器算出来了就不该丢：下游想诊断「哪条 cue 落到了目录页 / 被带过头」，
  /// 拿严格子串搜索去反推位置是不可靠的（听写稿七成搜不到），这里才是权威答案。
  final List<CueMatch> matches;
}

/// 对齐参数。默认即匹配器默认；[searchWindow] 为 null 表示在
/// [EpubCueMatcher.defaultProbeWindows] 里自动探测取命中率最高的一档。
class BookAlignOptions {
  const BookAlignOptions({
    this.searchWindow,
    this.similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
    this.maxConsecutiveMisses = EpubSrtMatcher.defaultMaxConsecutiveMisses,
  });

  final int? searchWindow;
  final double similarityThreshold;
  final int maxConsecutiveMisses;
}

/// 把一次转录的结果按正文对齐。等价于 [alignCuesWithBook]，只是从
/// [TranscribeOutcome] 里取 cue 与逐 token 时间。
Future<BookAlignedSubtitles> alignTranscriptionWithBook(
        EpubBook book, TranscribeOutcome original, SubtitleFormat format,
        {TranscribeCancellation? cancellation,
        BookAlignOptions options = const BookAlignOptions()}) =>
    alignCuesWithBook(book, original.cues, original.tokenTimings, format,
        cancellation: cancellation, options: options);

/// 书对齐的唯一入口：命中 cue 的听写文本换成正文原文（标点、引号一起带回），
/// 有逐 token 时间就按正文句界重切；未命中 cue 保留听写与原始时间。
///
/// 输入只要 cue 列表与可选的 token 时间——「刚转录出来的」与「从磁盘读回的
/// SRT + `*.tokens.jsonl`」在这里是同一种东西。[tokenTimings] 与 [cues] 按下标
/// 配对；长度不等时一条都不挂（行号错位比没有更糟），退化成只换文本不重切。
Future<BookAlignedSubtitles> alignCuesWithBook(
        EpubBook book,
        List<SubtitleCue> cues,
        List<AsrCueTokenTiming>? tokenTimings,
        SubtitleFormat format,
        {TranscribeCancellation? cancellation,
        BookAlignOptions options = const BookAlignOptions()}) =>
    cancellableCompute(
        _alignmentTask(
            book,
            cues,
            tokenTimings?.length == cues.length ? tokenTimings : null,
            format,
            options),
        cancellation);

Future<EpubBook> readCancellableEpubBook(
        String path, TranscribeCancellation token) =>
    cancellableCompute(_bookTask(path), token);

EpubBook Function() _bookTask(String path) => () {
      final file = File(path);
      if (file.lengthSync() > maxEpubBytes) {
        throw const FormatException('EPUB 超过 64 MiB 上限');
      }
      return parseEpubBytes(file.readAsBytesSync());
    };

BookAlignedSubtitles Function() _alignmentTask(
        EpubBook book,
        List<SubtitleCue> originalCues,
        List<AsrCueTokenTiming>? tokenTimings,
        SubtitleFormat format,
        BookAlignOptions options) =>
    () {
      final watch = Stopwatch()..start();
      final cues = [
        for (var i = 0; i < originalCues.length; i++)
          AlignCue()
            ..bookKey = ''
            ..chapterHref = ''
            ..sentenceIndex = i
            ..textFragmentId = ''
            ..audioFileIndex = 0
            ..text = originalCues[i].text
            ..startMs = originalCues[i].startMs
            ..endMs = originalCues[i].endMs
            ..tokenTiming = tokenTimings?[i]
      ];
      final (match, window, probed) = _matchWithOptions(book, cues, options);
      final resegmented = const CueSentenceResegmenter()
          .resegment(sections: book.sections, cues: cues, result: match);
      replaceMatchedCueTextWithBookText(
          sections: book.sections,
          cues: resegmented.cues,
          result: resegmented.result);
      final output = [
        for (var i = 0; i < resegmented.cues.length; i++)
          SubtitleCue(
              index: i + 1,
              startMs: resegmented.cues[i].startMs,
              endMs: resegmented.cues[i].endMs,
              text: resegmented.cues[i].text)
      ];
      watch.stop();
      return BookAlignedSubtitles(
          renderSubtitles(output, format),
          output.length,
          {
            'bookTitle': book.title,
            'bookLanguage': book.language,
            'sections': book.sections.length,
            'inputCues': match.totalCues,
            'matchedCues': match.matchedCues,
            'unmatchedCues': match.totalCues - match.matchedCues,
            'matchRate': match.matchRate,
            'searchWindow': window,
            // 自动探测时各档的第一遍命中率（key 为窗口字符数）；指定窗口时为 null。
            'probeWindows': probed == null
                ? null
                : {
                    for (final e in probed.entries) '${e.key}': e.value,
                  },
            'similarityThreshold': options.similarityThreshold,
            'maxConsecutiveMisses': options.maxConsecutiveMisses,
            'elapsedMs': watch.elapsedMilliseconds,
            'boundariesAdded': resegmented.stats.boundariesAdded,
            'boundariesRemoved': resegmented.stats.boundariesRemoved,
            'timingMode': tokenTimings == null
                ? 'segment-preserved'
                : 'token-resegmented',
            'warnings': [
              if (match.matchRate < 0.6) '正文匹配率较低，请检查书籍版本、语言或音频范围；未匹配部分保留原始转录。',
              if (tokenTimings == null) '此方案没有逐词时间戳，保留原始片段时间，不按字数伪造句界时间。',
            ],
          },
          matches: resegmented.result.matches);
    };

/// 指定窗口直接匹配；未指定就在默认三档里探测取最优（全零时退回默认窗口）。
/// 返回 (匹配结果, 实际窗口, 探测各档命中率或 null)。
(MatchResult, int, Map<int, double>?) _matchWithOptions(
    EpubBook book, List<AlignCue> cues, BookAlignOptions options) {
  final int? fixed = options.searchWindow;
  if (fixed != null) {
    return (
      EpubCueMatcher.match(
        sections: book.sections,
        cues: cues,
        searchWindow: fixed,
        similarityThreshold: options.similarityThreshold,
        maxConsecutiveMisses: options.maxConsecutiveMisses,
      ),
      fixed,
      null,
    );
  }
  final ProbeResult probe = EpubCueMatcher.probe(
    sections: book.sections,
    cues: cues,
    similarityThreshold: options.similarityThreshold,
    maxConsecutiveMisses: options.maxConsecutiveMisses,
  );
  final MapEntry<int, double>? best = probe.best;
  final MatchResult? bestResult = probe.bestResult;
  if (best != null && best.value > 0 && bestResult != null) {
    return (bestResult, best.key, probe.perWindow);
  }
  return (
    EpubCueMatcher.match(
      sections: book.sections,
      cues: cues,
      similarityThreshold: options.similarityThreshold,
      maxConsecutiveMisses: options.maxConsecutiveMisses,
    ),
    EpubSrtMatcher.defaultSearchWindow,
    probe.perWindow,
  );
}
