import 'dart:async';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _File implements DownloadableModelFile {
  _File(this.fileName, this.url, this.expectedBytes);

  @override
  final String fileName;
  @override
  final String url;
  @override
  final int expectedBytes;
}

List<int> _bytes(int n) => List<int>.generate(n, (int i) => i % 251);

/// 解析 `bytes=<n>-`，无 Range 时为 0。
int _rangeStart(HttpRequest request) {
  final String? range = request.headers.value(HttpHeaders.rangeHeader);
  if (range == null) return 0;
  return int.parse(range.substring('bytes='.length, range.length - 1));
}

/// 从 [start] 起按 [chunk] 字节、每块间隔 [gap] 发送剩余内容（206 / 200）。
Future<void> _serve(
  HttpRequest request,
  List<int> body, {
  int chunk = 64 * 1024,
  Duration gap = Duration.zero,
  int? stopAfter,
}) async {
  final int start = _rangeStart(request);
  final HttpResponse response = request.response;
  // 关掉输出缓冲：否则 flush() 推不出小块正文，「发了 1000 字节再卡住」会变成「一字节没发」。
  response.bufferOutput = false;
  response.statusCode = start > 0 ? HttpStatus.partialContent : HttpStatus.ok;
  response.contentLength = body.length - start;
  int sent = 0;
  for (int i = start; i < body.length; i += chunk) {
    if (stopAfter != null && sent >= stopAfter) {
      // 卡死：不再发、也不关，直到客户端超时断开。
      await Completer<void>().future.timeout(
            const Duration(seconds: 5),
            onTimeout: () {},
          );
      return;
    }
    final List<int> piece = body.sublist(i, (i + chunk).clamp(0, body.length));
    response.add(piece);
    sent += piece.length;
    await response.flush();
    if (gap > Duration.zero) await Future<void>.delayed(gap);
  }
  await response.close();
}

/// 像真实静态文件服务器那样处理 Range：起点越过文件末尾回 416 并带
/// `Content-Range: bytes */<总长>`（[withContentRange] 为假时不带），否则同 [_serve]。
Future<void> _serveRanged(
  HttpRequest request,
  List<int> body, {
  bool withContentRange = true,
}) async {
  final int start = _rangeStart(request);
  if (start > 0 && start >= body.length) {
    request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    if (withContentRange) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${body.length}',
      );
    }
    await request.response.close();
    return;
  }
  await _serve(request, body);
}

const ModelDownloadResilience _fast = ModelDownloadResilience(
  stallTimeout: Duration(milliseconds: 400),
  speedWindow: Duration(milliseconds: 150),
  minReferenceBytesPerSecond: 200 * 1024,
  retryBackoff: Duration(milliseconds: 10),
);

void main() {
  late HttpServer server;
  late Directory dir;
  late Future<void> Function(HttpRequest request, int attempt) handler;
  final Map<String, int> attempts = <String, int>{};
  final List<String> ranges = <String>[];

  setUp(() async {
    attempts.clear();
    ranges.clear();
    dir = await Directory.systemTemp.createTemp('model_dl_test_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final String path = request.uri.path;
      final int attempt = attempts[path] = (attempts[path] ?? 0) + 1;
      ranges.add('$path ${request.headers.value(HttpHeaders.rangeHeader)}');
      try {
        await handler(request, attempt);
      } on Object {
        // 客户端主动断开时写回会失败，属预期。
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  String url(String name) => 'http://127.0.0.1:${server.port}/$name';

  ModelFileDownloader downloader([ModelDownloadResilience r = _fast]) =>
      ModelFileDownloader(createClient: HttpClient.new, resilience: r);

  Future<List<ModelDownloadEvent>> run(
    ModelFileDownloader d,
    List<DownloadableModelFile> files,
  ) =>
      d
          .downloadAll(
            files: files,
            targetDir: dir,
            isReady: (File f) => f.existsSync() && f.lengthSync() > 0,
          )
          .toList();

  Future<void> expectFile(String name, List<int> body) async {
    final File f = File(p.join(dir.path, name));
    expect(await f.readAsBytes(), body);
    expect(File('${f.path}.part').existsSync(), isFalse);
  }

  test('卡死：超时断开后用 Range 从 .part 续传', () async {
    final List<int> body = _bytes(256 * 1024);
    handler = (HttpRequest request, int attempt) => attempt == 1
        ? _serve(request, body, chunk: 1000, stopAfter: 1000)
        : _serve(request, body);
    await run(downloader(), <DownloadableModelFile>[
      _File('a.bin', url('a.bin'), body.length),
    ]);
    await expectFile('a.bin', body);
    expect(ranges, <String>['/a.bin null', '/a.bin bytes=1000-']);
  });

  test('连接中途断开：自动续传，不整条失败', () async {
    final List<int> body = _bytes(200 * 1024);
    handler = (HttpRequest request, int attempt) async {
      if (attempt > 1) return _serve(request, body);
      final Socket socket = await request.response.detachSocket(
        writeHeaders: false,
      );
      socket.write(
        'HTTP/1.1 200 OK\r\ncontent-length: ${body.length}\r\n\r\n',
      );
      socket.add(body.sublist(0, 5000));
      await socket.flush();
      socket.destroy();
    };
    await run(downloader(), <DownloadableModelFile>[
      _File('b.bin', url('b.bin'), body.length),
    ]);
    await expectFile('b.bin', body);
    expect(ranges.last, '/b.bin bytes=5000-');
  });

  test('劣化：速度跌到参照的 1/10 以下换新连接续传', () async {
    final List<int> fast = _bytes(4 * 1024 * 1024);
    final List<int> slowThenFast = _bytes(600 * 1024);
    handler = (HttpRequest request, int attempt) {
      if (request.uri.path == '/fast.bin') {
        return _serve(request, fast, gap: const Duration(milliseconds: 5));
      }
      return attempt == 1
          ? _serve(
              request,
              slowThenFast,
              chunk: 512,
              gap: const Duration(milliseconds: 50),
            )
          : _serve(request, slowThenFast);
    };
    await run(downloader(), <DownloadableModelFile>[
      _File('fast.bin', url('fast.bin'), fast.length),
      _File('slow.bin', url('slow.bin'), slowThenFast.length),
    ]);
    await expectFile('slow.bin', slowThenFast);
    expect(attempts['/fast.bin'], 1, reason: '健康连接不应被打断');
    expect(attempts['/slow.bin'], 2);
    expect(ranges.last, startsWith('/slow.bin bytes='));
  });

  test('无参照：开局慢只试探换一次连接，网络本身慢就照慢的下完', () async {
    final List<int> body = _bytes(40 * 1024);
    handler = (HttpRequest request, int attempt) => _serve(
          request,
          body,
          chunk: 1024,
          gap: const Duration(milliseconds: 20),
        );
    await run(downloader(), <DownloadableModelFile>[
      _File('c.bin', url('c.bin'), body.length),
    ]);
    await expectFile('c.bin', body);
    expect(attempts['/c.bin'], 2);
  });

  test('503 是瞬时错误：重试后成功', () async {
    final List<int> body = _bytes(10 * 1024);
    handler = (HttpRequest request, int attempt) async {
      if (attempt == 1) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      await _serve(request, body);
    };
    await run(downloader(), <DownloadableModelFile>[
      _File('d.bin', url('d.bin'), body.length),
    ]);
    await expectFile('d.bin', body);
  });

  test('无进度的失败计数用尽后抛出真实错误；404 不重试', () async {
    handler = (HttpRequest request, int attempt) async {
      request.response.statusCode = request.uri.path == '/e.bin'
          ? HttpStatus.serviceUnavailable
          : HttpStatus.notFound;
      await request.response.close();
    };
    await expectLater(
      run(downloader(), <DownloadableModelFile>[
        _File('e.bin', url('e.bin'), 10),
      ]),
      throwsA(
        isA<ModelDownloadStatusException>().having(
          (ModelDownloadStatusException e) => e.statusCode,
          'statusCode',
          503,
        ),
      ),
    );
    expect(attempts['/e.bin'], _fast.maxFailedAttempts);

    await expectLater(
      run(downloader(), <DownloadableModelFile>[
        _File('f.bin', url('f.bin'), 10),
      ]),
      throwsA(isA<HttpException>()),
    );
    expect(attempts['/f.bin'], 1);
  });

  /// 预置一个 `.part` 残留。
  void writePart(String name, List<int> bytes) =>
      File(p.join(dir.path, '$name.part')).writeAsBytesSync(bytes);

  test('.part 比 expectedBytes 长：发请求前就删掉，从 0 整文件重下', () async {
    final List<int> body = _bytes(30 * 1024);
    // 两条下载同时往同一个 .part 追加的产物：比真实文件长。
    writePart('g.bin', <int>[...body, ...body.sublist(0, 7000)]);
    handler = (HttpRequest request, int attempt) => _serveRanged(request, body);
    await run(downloader(), <DownloadableModelFile>[
      _File('g.bin', url('g.bin'), body.length),
    ]);
    await expectFile('g.bin', body);
    expect(ranges, <String>['/g.bin null'], reason: '不该带坏偏移去续传');
  });

  test('续传被回 416 且长度对不上远端总长：删 .part 在同一次调用里重下', () async {
    final List<int> body = _bytes(30 * 1024);
    writePart('h.bin', <int>[...body, ...body.sublist(0, 7000)]);
    handler = (HttpRequest request, int attempt) => _serveRanged(request, body);
    // expectedBytes 未知：只能靠服务器的 416 发现 .part 超长。
    await run(downloader(), <DownloadableModelFile>[
      _File('h.bin', url('h.bin'), 0),
    ]);
    await expectFile('h.bin', body);
    expect(
        ranges, <String>['/h.bin bytes=${body.length + 7000}-', '/h.bin null']);
  });

  test('416 不带 Content-Range、远端总长无从判断：同样判 .part 不可信重下', () async {
    final List<int> body = _bytes(30 * 1024);
    writePart('i.bin', <int>[...body, 1, 2, 3]);
    handler = (HttpRequest request, int attempt) =>
        _serveRanged(request, body, withContentRange: false);
    await run(downloader(), <DownloadableModelFile>[
      _File('i.bin', url('i.bin'), 0),
    ]);
    await expectFile('i.bin', body);
    expect(ranges, <String>['/i.bin bytes=${body.length + 3}-', '/i.bin null']);
  });

  test('expectedBytes 未知、416 的 Content-Range 总长 == .part 长度：直接转正', () async {
    final List<int> body = _bytes(30 * 1024);
    writePart('j.bin', body);
    handler = (HttpRequest request, int attempt) => _serveRanged(request, body);
    await run(downloader(), <DownloadableModelFile>[
      _File('j.bin', url('j.bin'), 0),
    ]);
    await expectFile('j.bin', body);
    expect(ranges, <String>['/j.bin bytes=${body.length}-'], reason: '不该重下');
  });

  test('.part 长度 == expectedBytes、续传回 416：直接转正（原有路径）', () async {
    final List<int> body = _bytes(30 * 1024);
    writePart('k.bin', body);
    handler = (HttpRequest request, int attempt) =>
        _serveRanged(request, body, withContentRange: false);
    await run(downloader(), <DownloadableModelFile>[
      _File('k.bin', url('k.bin'), body.length),
    ]);
    await expectFile('k.bin', body);
    expect(ranges, <String>['/k.bin bytes=${body.length}-']);
  });

  test('重下后服务器仍回 416：如实抛出，只重下一次不打转', () async {
    writePart('l.bin', _bytes(100));
    handler = (HttpRequest request, int attempt) async {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await request.response.close();
    };
    await expectLater(
      run(downloader(), <DownloadableModelFile>[
        _File('l.bin', url('l.bin'), 0),
      ]),
      throwsA(
        isA<ModelDownloadStatusException>().having(
          (ModelDownloadStatusException e) => e.statusCode,
          'statusCode',
          HttpStatus.requestedRangeNotSatisfiable,
        ),
      ),
    );
    expect(ranges, <String>['/l.bin bytes=100-', '/l.bin null']);
    expect(File(p.join(dir.path, 'l.bin.part')).existsSync(), isFalse,
        reason: '不可信的 .part 必须删掉，否则下次又从同一个坏偏移 416');
  });
}
