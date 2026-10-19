/// multipart 请求体分几次到达时，解析中途报错也必须回 400，而不是挂住。
///
/// 真 bug（2026-10-19，#25 的 Linux CI 整个 job 挂到 30 分钟超时）：服务器自己
/// 持有请求体订阅、给 multipart 解析器做背压转发。解析器在请求体还没收完时报错
/// → 中继被取消；而中继此前因背压暂停过时，请求体订阅也跟着暂停，中继被取消又
/// 不会回调 onResume——剩下的请求体永远读不到，响应发不出去，`stop()` 也等不完。
/// Windows 上 HttpClient 小包一次到齐所以 `retime_test` 碰不到；这里用裸 socket
/// 把请求体切成两段、中间停一下，逐个切点复现。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr/asr.dart';
import 'package:fushi_asr_server/asr_server.dart';
import 'package:test/test.dart';

class _Unreachable implements TranscribeService {
  int calls = 0;

  @override
  Future<TranscribeOutcome> run({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrAudioProfile audioProfile,
    SubtitleFormat format = SubtitleFormat.srt,
    void Function(TranscribeProgress)? onProgress,
    TranscribeCancellation? cancellation,
  }) {
    calls++;
    throw StateError('坏上传不应走到推理');
  }
}

/// 发一个 `Connection: close` 的 POST：先发头，请求体在 [split] 处切成两段，
/// 每段之前停 [gap]。返回完整的原始响应。
Future<String> _postInTwoPieces(
  Uri base,
  String body,
  int split, {
  Duration gap = const Duration(milliseconds: 20),
}) async {
  final Socket socket = await Socket.connect(base.host, base.port);
  try {
    final List<int> bytes = utf8.encode(body);
    socket.add(utf8.encode(
        'POST /v1/retime?language=ja&format=srt&filename=voice.wav HTTP/1.1\r\n'
        'Host: localhost\r\n'
        'Connection: close\r\n'
        'Content-Type: multipart/form-data; boundary=broken\r\n'
        'Content-Length: ${bytes.length}\r\n\r\n'));
    await socket.flush();
    for (final List<int> piece in <List<int>>[
      bytes.sublist(0, split),
      bytes.sublist(split),
    ]) {
      await Future<void>.delayed(gap);
      socket.add(piece);
      await socket.flush();
    }
    return await utf8.decodeStream(socket);
  } finally {
    socket.destroy();
  }
}

void main() {
  const Map<String, String> bodies = <String, String>{
    '坏的 part 头': '--broken\r\ninvalid header\r\n',
    '坏的结尾边界': '--broken\r\n'
        'Content-Disposition: form-data; name="audio"; filename="voice.wav"\r\n'
        '\r\naudio bytes\r\n--brokenINVALID',
  };

  for (final MapEntry<String, String> entry in bodies.entries) {
    test('${entry.key}：请求体任意切成两段都回 400', () async {
      final _Unreachable service = _Unreachable();
      final AsrServer server =
          AsrServer(runner: service, registry: AsrModelRegistry.builtin());
      final Uri base = await server.start(port: 0);
      addTearDown(server.stop);
      final int length = utf8.encode(entry.value).length;
      for (int split = 1; split < length; split++) {
        final String response = await _postInTwoPieces(
          base,
          entry.value,
          split,
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('切点 $split：5 秒内没收到响应（请求挂住）'),
        );
        expect(response, startsWith('HTTP/1.1 400'), reason: '切点 $split');
        expect(response, contains('multipart'), reason: '切点 $split');
      }
      expect(service.calls, 0);
    });
  }
}
