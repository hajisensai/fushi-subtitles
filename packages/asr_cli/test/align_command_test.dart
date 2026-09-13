import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/command_runner.dart';
import 'package:fushi_asr/asr.dart';
import 'package:fushi_asr_cli/asr_cli.dart';
import 'package:fushi_asr_cli/src/align_command.dart';
import 'package:test/test.dart';

/// 单章 EPUB：正文三句，第二、三句是听写要命中的范围。
List<int> _epub() {
  final files = <String, String>{
    'META-INF/container.xml':
        '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    'OPS/book.opf':
        '<package><metadata><title>T</title><language>ja</language></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/></spine></package>',
    'OPS/a.xhtml':
        '<html><body><p>たとえば、夢見る時がある。転入生がやってくる。その子は素敵な子。</p></body></html>',
  };
  final archive = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    archive.add(ArchiveFile(e.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

const String _heard = '夢見る時がある転入生がやってくる';
const String _srt = '1\n00:00:10,000 --> 00:00:13,500\n$_heard\n\n';

String _tokens() => serializeAsrCueTokenTimings([
      AsrCueTokenTiming(tokens: _heard.split(''), offsetsMs: [
        for (int i = 0; i < 7; i++) 100 + i * 100,
        for (int i = 0; i < 9; i++) 2000 + i * 100,
      ]),
    ]);

void main() {
  late Directory dir;
  late String epub;
  late String srt;
  late String out;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fushi_subs_align_');
    epub = '${dir.path}/book.epub';
    srt = '${dir.path}/transcript.srt';
    out = '${dir.path}/out.srt';
    await File(epub).writeAsBytes(_epub());
    await File(srt).writeAsString(_srt);
  });
  tearDown(() => dir.delete(recursive: true));

  Future<int> run(List<String> args) async =>
      (await buildAsrCommandRunner().run(['align', '-q', ...args])) ?? 1;

  test('defaultTokensPath: same dir, same stem, .tokens.jsonl', () {
    expect(
        defaultTokensPath('a/b/transcript.srt'), 'a/b/transcript.tokens.jsonl');
    expect(defaultTokensPath(r'C:\x\out.vtt'), r'C:\x\out.tokens.jsonl');
    expect(defaultTokensPath('noext'), 'noext.tokens.jsonl');
    expect(defaultTokensPath('a.b/noext'), 'a.b/noext.tokens.jsonl');
  });

  test('with sidecar next to the srt: resegments at book sentence boundaries',
      () async {
    await File(defaultTokensPath(srt)).writeAsString(_tokens());
    expect(await run([srt, '--book', epub, '-o', out]), 0);
    final cues = parseSrt(await File(out).readAsString());
    expect(cues.map((c) => c.text), ['夢見る時がある。', '転入生がやってくる。']);
    expect(cues.first.startMs, 10000);
    expect(cues.last.endMs, 13500);
  });

  test('without sidecar: text replaced with book text, cue count unchanged',
      () async {
    expect(await run([srt, '--book', epub, '-o', out]), 0);
    final cues = parseSrt(await File(out).readAsString());
    expect(cues, hasLength(1));
    expect(cues.single.text, '夢見る時がある。転入生がやってくる。');
    expect(cues.single.startMs, 10000);
    expect(cues.single.endMs, 13500);
  });

  test('sidecar row count != cue count: timing ignored, no resegment',
      () async {
    await File(defaultTokensPath(srt)).writeAsString(_tokens() + _tokens());
    expect(await run([srt, '--book', epub, '-o', out]), 0);
    expect(parseSrt(await File(out).readAsString()), hasLength(1));
  });

  test('--tokens overrides the default sidecar location', () async {
    final String elsewhere = '${dir.path}/elsewhere.jsonl';
    await File(elsewhere).writeAsString(_tokens());
    expect(
        await run([srt, '--book', epub, '--tokens', elsewhere, '-o', out]), 0);
    expect(parseSrt(await File(out).readAsString()), hasLength(2));
  });

  test('missing --book or missing files fail loudly', () async {
    expect(() => run([srt, '-o', out]), throwsA(isA<UsageException>()));
    expect(await run([srt, '--book', '${dir.path}/nope.epub', '-o', out]), 2);
    expect(await run(['${dir.path}/nope.srt', '--book', epub, '-o', out]), 2);
    expect(File(out).existsSync(), isFalse);
  });

  test('--matches writes one JSON line per output cue with book positions',
      () async {
    await File(defaultTokensPath(srt)).writeAsString(_tokens());
    final String matches = '${dir.path}/matches.jsonl';
    expect(
        await run([srt, '--book', epub, '-o', out, '--matches', matches]), 0);
    final List<String> lines =
        (await File(matches).readAsString()).trim().split('\n');
    final List<SubtitleCue> cues = parseSrt(await File(out).readAsString());
    expect(lines, hasLength(cues.length));
    expect(cues, hasLength(2), reason: '带 sidecar 时重切成两句');
    for (int i = 0; i < lines.length; i++) {
      final Map<String, Object?> row =
          jsonDecode(lines[i]) as Map<String, Object?>;
      expect(row['cue'], i + 1);
      expect(row['section'], 0);
      expect(row['start'], isA<int>());
      expect((row['end'] as int), greaterThan(row['start'] as int));
      expect((row['score'] as num), greaterThan(0));
    }
    // 第二句紧接第一句：位置单调。
    final int end1 = (jsonDecode(lines[0]) as Map)['end'] as int;
    final int start2 = (jsonDecode(lines[1]) as Map)['start'] as int;
    expect(start2, greaterThanOrEqualTo(end1));
  });

  test('--window/--threshold/--max-misses are validated and applied', () async {
    expect(
        await run([
          srt,
          '--book',
          epub,
          '-o',
          out,
          '--window',
          '120',
          '--threshold',
          '0.9',
          '--max-misses',
          '5'
        ]),
        0);
    expect(parseSrt(await File(out).readAsString()).single.text,
        '夢見る時がある。転入生がやってくる。');
    expect(() => run([srt, '--book', epub, '--window', '0']),
        throwsA(isA<UsageException>()));
    expect(() => run([srt, '--book', epub, '--threshold', '1.5']),
        throwsA(isA<UsageException>()));
    expect(() => run([srt, '--book', epub, '--max-misses', 'x']),
        throwsA(isA<UsageException>()));
  });

  test('transcribe --help shows the shared alignment options', () async {
    final List<String> lines = <String>[];
    final runner = buildAsrCommandRunner();
    final Command<int> transcribe = runner.commands['transcribe']!;
    lines.add(transcribe.usage);
    expect(lines.single, contains('--window'));
    expect(lines.single, contains('--matches'));
  });
}
