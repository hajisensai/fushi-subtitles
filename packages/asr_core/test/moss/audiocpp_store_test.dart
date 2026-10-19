import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fushi_asr_core/asr_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

List<int> _bytes(int n, int seed) =>
    List<int>.generate(n, (int i) => (i * 31 + seed) % 251);

String _sha(List<int> b) => crypto.sha256.convert(b).toString();

/// 本地 HTTP 假服务器：按路径回固定字节，记录请求次数。
class _Server {
  _Server._(this._server, this.bodies);

  static Future<_Server> start(Map<String, List<int>> bodies) async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _Server s = _Server._(server, bodies);
    server.listen((HttpRequest req) async {
      s.hits[req.uri.path] = (s.hits[req.uri.path] ?? 0) + 1;
      final List<int>? body = bodies[req.uri.path];
      if (body == null) {
        req.response.statusCode = HttpStatus.notFound;
      } else {
        req.response.contentLength = body.length;
        req.response.add(body);
      }
      await req.response.close();
    });
    return s;
  }

  final HttpServer _server;
  final Map<String, List<int>> bodies;
  final Map<String, int> hits = <String, int>{};

  String url(String path) => 'http://127.0.0.1:${_server.port}$path';

  Future<void> close() => _server.close(force: true);
}

ModelFileDownloader _downloader() => ModelFileDownloader(
      // 本地假服务器：不走环境代理。
      createClient: () => HttpClient()..findProxy = (Uri _) => 'DIRECT',
      urlCandidates: (DownloadableModelFile f) => <String>[f.url],
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audiocpp_store_test_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('清单', () {
    test('Windows 三种后端齐全；Linux 没有 CUDA CLI', () {
      for (final AudioCppBackend b in AudioCppBackend.values) {
        expect(
            audioCppRuntimePackFor(AudioCppPlatform.windowsX64, b), isNotNull);
      }
      expect(
        audioCppRuntimePackFor(AudioCppPlatform.linuxX64, AudioCppBackend.cuda),
        isNull,
      );
      final AudioCppRuntimePack cuda = audioCppRuntimePackFor(
          AudioCppPlatform.windowsX64, AudioCppBackend.cuda)!;
      expect(cuda.directoryName, 'audiocpp-v0.9.2-windows-x64-cuda');
      expect(cuda.totalBytes, 275142402 + 575457454);
      expect(cuda.executableName, 'audiocpp_cli.exe');
    });

    test('摘要都是 64 位小写十六进制，权重文件名以 .gguf 结尾、URL 钉 revision', () {
      final RegExp hex = RegExp(r'^[0-9a-f]{64}$');
      for (final AudioCppRuntimePack pack in kAudioCppRuntimePacks) {
        for (final AudioCppDownloadFile f in pack.archives) {
          expect(f.sha256, matches(hex), reason: f.fileName);
          expect(f.url, endsWith('/v0.9.2/${f.fileName}'));
          expect(f.expectedBytes, greaterThan(0));
        }
      }
      expect(kMossModelFile.sha256, matches(hex));
      expect(kMossModelFile.fileName, endsWith('.gguf'));
      expect(kMossModelFile.url, contains('/resolve/$kMossModelRevision/'));
      expect(kMossModelFile.expectedBytes, 1132110560);
    });
  });

  group('MossModelStore', () {
    test('下载 → 校验摘要 → 写 sidecar → 就绪；再次 ensure 不发请求', () async {
      final List<int> body = _bytes(300000, 7);
      final _Server server =
          await _Server.start(<String, List<int>>{'/m.gguf': body});
      addTearDown(server.close);
      final AudioCppDownloadFile spec = AudioCppDownloadFile(
        fileName: 'm.gguf',
        url: server.url('/m.gguf'),
        expectedBytes: body.length,
        sha256: _sha(body),
      );
      final MossModelStore store =
          MossModelStore(Directory(p.join(tmp.path, 'moss')), file: spec);
      final AudioCppProvisionStatus before = await store.status();
      expect(before.ready, isFalse);
      expect(before.missingFiles, <String>['m.gguf']);
      expect(before.remainingBytes, body.length);

      final List<ModelDownloadEvent> events =
          await store.ensure(downloader: _downloader()).toList();
      expect(events.last.done, isTrue);
      expect(store.isReady, isTrue);
      expect(File('${store.modelFile.path}.sha256').readAsStringSync(),
          _sha(body));
      final AudioCppProvisionStatus after = await store.status();
      expect(after.ready, isTrue);
      expect(after.missingFiles, isEmpty);
      expect(after.obtainedBytes, body.length);

      expect(await store.ensure(downloader: _downloader()).toList(), isEmpty);
      expect(server.hits['/m.gguf'], 1);
    });

    test('摘要不符：报错、删掉坏档、不就绪', () async {
      final List<int> body = _bytes(4096, 1);
      final _Server server =
          await _Server.start(<String, List<int>>{'/m.gguf': body});
      addTearDown(server.close);
      final MossModelStore store = MossModelStore(
        Directory(p.join(tmp.path, 'moss')),
        file: AudioCppDownloadFile(
          fileName: 'm.gguf',
          url: server.url('/m.gguf'),
          expectedBytes: body.length,
          sha256: '0' * 64,
        ),
      );
      await expectLater(
        store.ensure(downloader: _downloader()).toList(),
        throwsA(isA<AudioCppProvisionCorrupt>().having(
            (AudioCppProvisionCorrupt e) => e.message,
            'msg',
            contains('sha256'))),
      );
      expect(store.modelFile.existsSync(), isFalse);
      expect(store.isReady, isFalse);
    });

    test('文件在但没有 sidecar（没校验过）不算就绪', () {
      final AudioCppDownloadFile spec = AudioCppDownloadFile(
        fileName: 'm.gguf',
        url: 'http://unused/m.gguf',
        expectedBytes: 3,
        sha256: _sha(<int>[1, 2, 3]),
      );
      final MossModelStore store =
          MossModelStore(Directory(p.join(tmp.path, 'moss')), file: spec);
      store.dir.createSync(recursive: true);
      store.modelFile.writeAsBytesSync(<int>[1, 2, 3]);
      expect(store.isReady, isFalse);
    });
  });

  group('AudioCppRuntimeStore', () {
    AudioCppRuntimePack pack(_Server server, Map<String, List<int>> bodies,
        {String? badSha}) {
      return AudioCppRuntimePack(
        platform: AudioCppPlatform.windowsX64,
        backend: AudioCppBackend.cuda,
        archives: <AudioCppDownloadFile>[
          for (final MapEntry<String, List<int>> e in bodies.entries)
            AudioCppDownloadFile(
              fileName: e.key.substring(1),
              url: server.url(e.key),
              expectedBytes: e.value.length,
              sha256: badSha ?? _sha(e.value),
            ),
        ],
      );
    }

    test('下载全部归档 → 校验 → 依次解压 → 有 CLI → 写标记、删中转', () async {
      final Map<String, List<int>> bodies = <String, List<int>>{
        '/bin.zip': _bytes(5000, 2),
        '/cudart.zip': _bytes(7000, 3),
      };
      final _Server server = await _Server.start(bodies);
      addTearDown(server.close);
      final List<String> extracted = <String>[];
      final AudioCppRuntimeStore store = AudioCppRuntimeStore(
        Directory(p.join(tmp.path, 'rt')),
        pack(server, bodies),
        extractor: (File archive, Directory target) async {
          extracted.add(p.basename(archive.path));
          if (p.basename(archive.path) == 'bin.zip') {
            File(p.join(target.path, 'audiocpp_cli.exe'))
                .writeAsStringSync('exe');
          }
        },
      );
      final AudioCppProvisionStatus before = await store.status();
      expect(before.ready, isFalse);
      expect(before.missingFiles, <String>['bin.zip', 'cudart.zip']);
      expect(before.totalBytes, 12000);

      await store.ensure(downloader: _downloader()).drain<void>();
      expect(extracted, <String>['bin.zip', 'cudart.zip']);
      expect(store.isReady, isTrue);
      expect(
          Directory(p.join(store.dir.path, '.download')).existsSync(), isFalse);
      final AudioCppProvisionStatus after = await store.status();
      expect(after.ready, isTrue);
      expect(after.obtainedBytes, 12000);

      // 已就绪：不发事件、不请求。
      expect(await store.ensure(downloader: _downloader()).toList(), isEmpty);
      expect(server.hits['/bin.zip'], 1);
    });

    test('任一归档摘要不符：一个都不解压，报错', () async {
      final Map<String, List<int>> bodies = <String, List<int>>{
        '/bin.zip': _bytes(5000, 2),
      };
      final _Server server = await _Server.start(bodies);
      addTearDown(server.close);
      bool extractedAny = false;
      final AudioCppRuntimeStore store = AudioCppRuntimeStore(
        Directory(p.join(tmp.path, 'rt')),
        pack(server, bodies, badSha: 'f' * 64),
        extractor: (File a, Directory t) async => extractedAny = true,
      );
      await expectLater(
        store.ensure(downloader: _downloader()).drain<void>(),
        throwsA(isA<AudioCppProvisionCorrupt>()),
      );
      expect(extractedAny, isFalse);
      expect(store.isReady, isFalse);
    });

    test('解压后没有 CLI：报错且不写就绪标记', () async {
      final Map<String, List<int>> bodies = <String, List<int>>{
        '/bin.zip': _bytes(100, 2),
      };
      final _Server server = await _Server.start(bodies);
      addTearDown(server.close);
      final AudioCppRuntimeStore store = AudioCppRuntimeStore(
        Directory(p.join(tmp.path, 'rt')),
        pack(server, bodies),
        extractor: (File a, Directory t) async {},
      );
      await expectLater(
        store.ensure(downloader: _downloader()).drain<void>(),
        throwsA(isA<AudioCppProvisionCorrupt>().having(
            (AudioCppProvisionCorrupt e) => e.message,
            'msg',
            contains('audiocpp_cli'))),
      );
      expect(store.isReady, isFalse);
    });

    test('标记与清单不符（换了版本）不算就绪', () {
      final AudioCppRuntimePack real = audioCppRuntimePackFor(
          AudioCppPlatform.windowsX64, AudioCppBackend.cpu)!;
      final AudioCppRuntimeStore store =
          AudioCppRuntimeStore(Directory(p.join(tmp.path, 'rt')), real);
      store.dir.createSync(recursive: true);
      store.executable.writeAsStringSync('exe');
      File(p.join(store.dir.path, '.audiocpp-installed.json'))
          .writeAsStringSync('{"version":"0.9.1","archives":[]}');
      expect(store.isReady, isFalse);
    });
  });

  test('系统 tar 能解出 tar.gz（解压默认实现的真路径）', () async {
    final Directory src = Directory(p.join(tmp.path, 'src'))..createSync();
    File(p.join(src.path, 'audiocpp_cli')).writeAsStringSync('hello');
    final File archive = File(p.join(tmp.path, 'a.tar.gz'));
    final ProcessResult created = await Process.run(
      systemTarExecutable(),
      <String>['-czf', archive.path, '-C', src.path, '.'],
    );
    expect(created.exitCode, 0, reason: '${created.stderr}');
    final Directory out = Directory(p.join(tmp.path, 'out'));
    await extractWithSystemTar(archive, out);
    expect(File(p.join(out.path, 'audiocpp_cli')).readAsStringSync(), 'hello');
  });

  test('解压失败带 tar 的 stderr', () async {
    final File bogus = File(p.join(tmp.path, 'bogus.zip'))
      ..writeAsStringSync('not an archive');
    await expectLater(
      extractWithSystemTar(bogus, Directory(p.join(tmp.path, 'out'))),
      throwsA(isA<AudioCppProvisionCorrupt>()),
    );
  });
}
