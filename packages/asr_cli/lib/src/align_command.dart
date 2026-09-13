/// `fushi-subs align`：已有字幕 + EPUB → 正文替换后的字幕（不重跑 ASR）。
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:fushi_asr/asr.dart';

/// 与 `transcribe` 同一约定：字幕走 stdout / `-o`，统计与告警走 stderr。
class AlignCommand extends Command<int> {
  AlignCommand() {
    argParser
      ..addOption('book', abbr: 'b', help: 'EPUB 正文（必填）')
      ..addOption('tokens',
          help: '逐 token 时间 sidecar（`*.tokens.jsonl`）。省略则找字幕同目录同名的 '
              '`<字幕名>.tokens.jsonl`；找不到或行数与 cue 数不符就只换文本不重切')
      ..addOption('output', abbr: 'o', help: '输出文件；省略写 stdout')
      ..addOption('format',
          abbr: 'f',
          defaultsTo: 'srt',
          allowed: <String>['srt', 'vtt', 'json'],
          help: '字幕格式')
      ..addFlag('quiet', abbr: 'q', help: '不打统计', negatable: false);
  }

  @override
  String get name => 'align';

  @override
  String get description =>
      '把已有字幕（SRT / WebVTT）按 EPUB 正文对齐：命中的 cue 换成正文原文（标点、引号一起带回），'
      '有逐 token 时间时按正文句界重切。不重跑语音识别。';

  @override
  String get invocation => 'fushi-subs align --book <x.epub> [选项] <字幕文件>';

  @override
  Future<int> run() async {
    final List<String> rest = argResults!.rest;
    if (rest.length != 1) usageException('要给且只给一个字幕文件');
    final String? bookPath = argResults!['book'] as String?;
    if (bookPath == null) usageException('要指定 --book <x.epub>');
    final SubtitleFormat format =
        SubtitleFormat.fromName(argResults!['format'] as String)!;
    final bool quiet = argResults!['quiet'] as bool;

    final File subtitleFile = File(rest.single);
    if (!subtitleFile.existsSync()) {
      stderr.writeln('字幕文件不存在：${subtitleFile.path}');
      return 2;
    }
    if (!File(bookPath).existsSync()) {
      stderr.writeln('EPUB 不存在：$bookPath');
      return 2;
    }
    final List<SubtitleCue> cues;
    try {
      cues = parseRetimingSubtitles(await subtitleFile.readAsString());
    } on FormatException catch (e) {
      stderr.writeln('字幕解析失败：${e.message}');
      return 2;
    }

    final File tokensFile = File(
        (argResults!['tokens'] as String?) ?? defaultTokensPath(rest.single));
    final List<AsrCueTokenTiming>? tokenTimings =
        await readAlignTokenTimings(tokensFile, cues.length, quiet: quiet);

    final TranscribeCancellation cancellation = TranscribeCancellation();
    final EpubBook book;
    try {
      book = await readCancellableEpubBook(bookPath, cancellation);
    } on FormatException catch (e) {
      stderr.writeln('EPUB 解析失败：${e.message}');
      return 2;
    }
    final BookAlignedSubtitles aligned = await alignCuesWithBook(
        book, cues, tokenTimings, format,
        cancellation: cancellation);
    if (!quiet) printAlignmentStats(aligned.stats);

    final String? out = argResults!['output'] as String?;
    if (out == null) {
      stdout.write(aligned.text);
    } else {
      await File(out).writeAsString(aligned.text);
      if (!quiet) stderr.writeln('写入 $out');
    }
    return 0;
  }
}

/// 字幕同目录同名的 sidecar：`a/transcript.srt` → `a/transcript.tokens.jsonl`
/// （与 `AsrJobFiles.cueTokens` 在任务目录里的命名一致）。
String defaultTokensPath(String subtitlePath) {
  final String base = subtitlePath.substring(
      0, subtitlePath.length - _extensionOf(subtitlePath).length);
  return '$base.tokens.jsonl';
}

String _extensionOf(String path) {
  final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final int dot = path.lastIndexOf('.');
  return dot > slash ? path.substring(dot) : '';
}

/// 读 sidecar 并按行数与 cue 数校验；对不上或没有就返回 null（只换文本不重切），
/// 原因打到 stderr。
Future<List<AsrCueTokenTiming>?> readAlignTokenTimings(
  File tokensFile,
  int cueCount, {
  required bool quiet,
}) async {
  if (!tokensFile.existsSync()) {
    if (!quiet) {
      stderr.writeln('无逐词时间（${tokensFile.path} 不存在），只替换文本不重切句界。');
    }
    return null;
  }
  final List<({List<String> tokens, List<int> offsetsMs})>? rows =
      parseAsrCueTokens(await tokensFile.readAsString());
  if (rows == null || rows.length != cueCount) {
    if (!quiet) {
      stderr.writeln('逐词时间 sidecar 与字幕不配对（sidecar ${rows?.length ?? "坏行"} 行，'
          '字幕 $cueCount 条），一条都不挂：只替换文本不重切句界。');
    }
    return null;
  }
  return <AsrCueTokenTiming>[
    for (final ({List<String> tokens, List<int> offsetsMs}) r in rows)
      AsrCueTokenTiming(tokens: r.tokens, offsetsMs: r.offsetsMs),
  ];
}

/// 对齐统计打到 stderr（`transcribe --book` 与 `align` 共用）。
void printAlignmentStats(Map<String, Object?> stats) {
  final num rate = (stats['matchRate'] as num?) ?? 0;
  stderr.writeln('正文对齐：${stats['matchedCues']}/${stats['inputCues']} 条命中'
      '（${(rate * 100).toStringAsFixed(1)}%），'
      '句界 +${stats['boundariesAdded']} / -${stats['boundariesRemoved']}，'
      '时间模式 ${stats['timingMode']}，用时 ${stats['elapsedMs']} ms');
  for (final Object? w in (stats['warnings'] as List<Object?>?) ?? const []) {
    stderr.writeln('警告：$w');
  }
}
