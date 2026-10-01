/// 与业务无关的模型文件下载器（OCR / ASR 共用）：逐文件字节进度、`.part`
/// 临时名 + 原子 rename、HTTP Range 断点续传、主源失败换镜像、系统代理。
///
/// 事件契约见 [ModelDownloadEvent]：按文件粒度报告 receivedBytes / totalBytes；
/// 全部文件完成后最后发一次 `done=true`；任何失败以 error 事件结束流
/// （async* 抛出即 error）。
///
/// http 栈：`dart:io` [HttpClient] 经 `createAsrHttpClient()` 统一装配
/// （BUG-1498：env > GUI 系统代理 > DIRECT），不引新依赖。
///
/// 历史：这套逻辑最初绑着漫画 OCR 的 `MangaOcrModelFile` / `MangaOcrDownloadEvent`
/// 住在 `lib/src/ocr/manga_ocr_model_downloader.dart`；有声书 ASR 接入后抬到本
/// 文件，OCR 那边改成薄适配（类型转换），行为与测试原样保留。
///
/// 连接健康（[ModelDownloadResilience]）：几 GB 的单文件要在一条 TCP 连接上跑
/// 很久，而代理出口 / 链路会中途劣化——实测同一代理下，跑了 3 小时的旧连接只剩
/// 50 KB/s，新开一条连接 11 MB/s。旧实现对卡死没有空闲超时（进度条永远不动）、
/// 对劣化没有任何感知、对中途断线直接整条失败，用户只能手动「取消 → 继续」来换
/// 连接。现在由下载器自己做这件事：卡死 / 劣化 / 瞬时传输错误都断开当前连接，
/// 用 Range 从 `.part` 当前长度续传。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'package:fushi_asr_core/src/util/asr_http.dart';

/// 清单里一个可下载的模型文件（各子系统的清单类型实现本接口）。
abstract interface class DownloadableModelFile {
  /// 落盘文件名（与远端 basename 一致，Range 续传直接复用同 URL）。
  String get fileName;

  /// 主源直链。
  String get url;

  /// 预期字节数（用于 totalBytes 展示与下载后长度校验；0 表示未知、不校验）。
  int get expectedBytes;
}

/// 模型下载进度事件。
class ModelDownloadEvent {
  const ModelDownloadEvent({
    required this.fileName,
    required this.receivedBytes,
    required this.totalBytes,
    this.done = false,
  });

  final String fileName;
  final int receivedBytes;
  final int totalBytes;

  /// 全部文件完成时最后发一次 done=true。
  final bool done;
}

/// 默认进度事件的字节间隔（避免大文件每 chunk 一事件淹没 UI）。
const int kModelDownloadProgressInterval = 512 * 1024;

/// Hugging Face 主源 host。
const String kHuggingFaceHost = 'huggingface.co';

/// Hugging Face 镜像 host（与 huggingface.co **路径完全同构**，只换域名即可命中
/// 同一个 blob）。
///
/// 存在的唯一理由是主源在部分网络下握手就断——几百 MB 的模型对这类用户等于下不
/// 动。镜像只在主源失败后按序尝试（见 [ModelFileDownloader]），不改变默认信任
/// 关系；字节一致性仍由下载器 rename 前的长度校验兜底。
const List<String> kHuggingFaceMirrorHosts = <String>['hf-mirror.com'];

/// 一个 URL 的**下载候选序列**：主源在前，Hugging Face 镜像依次在后。
///
/// 刻意做成从 [url] 派生而不是让清单逐条列出多个 URL：清单里每多一个手写 URL
/// 就多一处能写错的地方，而镜像与主源本就只差 host。非 huggingface.co 的 URL
/// （GitHub release、测试注入的 localhost、将来换源）原样返回单元素列表——没有
/// 「测试专用分支」，只有「不认识的 host 不派生镜像」这一条规则。
List<String> defaultHuggingFaceUrlCandidates(String url) {
  final Uri primary = Uri.parse(url);
  if (primary.host != kHuggingFaceHost) {
    return <String>[url];
  }
  return <String>[
    url,
    for (final String host in kHuggingFaceMirrorHosts)
      primary.replace(host: host).toString(),
  ];
}

List<String> _defaultUrlCandidates(DownloadableModelFile file) =>
    defaultHuggingFaceUrlCandidates(file.url);

/// 下载连接的健康策略：何时判定一条连接坏了、换几次连接才放弃。
///
/// 三种情况都会「断开当前连接 → Range 续传」：
/// - **卡死**：等响应头或两次数据之间超过 [stallTimeout] 没有字节。
/// - **劣化**：每 [speedWindow] 结算一次窗口速度，低于本次下载出现过的最好窗口
///   速度的 1/[degradedRatio]。还没有像样的参照（最好速度不到
///   [minReferenceBytesPerSecond]）时，每个文件允许试探性换一次连接——开局就
///   分到坏出口的连接没有「变慢」可比。连续 [maxDegradedReconnects] 次换连接
///   都没回到正常速度，就认定是网络本身慢，本文件不再因劣化换连接。
/// - **瞬时错误**：连接中断、TLS / socket 错误、5xx / 429。
///
/// 只有「换了连接却一个字节都没多下到」才计入失败；连续失败 [maxFailedAttempts]
/// 次后放弃当前候选（换镜像或抛出最后一个错误），两次尝试之间按
/// [retryBackoff] 指数退避。404 之类确定性错误不重试。
class ModelDownloadResilience {
  const ModelDownloadResilience({
    this.stallTimeout = const Duration(seconds: 30),
    this.speedWindow = const Duration(seconds: 15),
    this.degradedRatio = 10,
    this.minReferenceBytesPerSecond = 512 * 1024,
    this.maxDegradedReconnects = 3,
    this.maxFailedAttempts = 4,
    this.retryBackoff = const Duration(seconds: 1),
  });

  final Duration stallTimeout;
  final Duration speedWindow;
  final int degradedRatio;
  final int minReferenceBytesPerSecond;
  final int maxDegradedReconnects;
  final int maxFailedAttempts;
  final Duration retryBackoff;
}

/// 服务器回了非预期状态码。[isTransient] 为真（5xx / 429）时下载器会重试。
class ModelDownloadStatusException extends HttpException {
  ModelDownloadStatusException(this.statusCode, String message, {super.uri})
      : super(message);

  final int statusCode;

  bool get isTransient =>
      statusCode >= 500 || statusCode == HttpStatus.tooManyRequests;
}

/// 当前连接速度远低于本次下载的正常水平，主动断开换连接。
class _DegradedConnection implements Exception {
  const _DegradedConnection(this.bytesPerSecond);

  final int bytesPerSecond;

  @override
  String toString() => 'connection degraded to $bytesPerSecond B/s';
}

/// 一次 [ModelFileDownloader.downloadAll] 范围内的速度参照（跨文件、跨重连）。
class _SpeedReference {
  int peakBytesPerSecond = 0;
}

/// 单个文件的劣化判定状态（跨该文件的多次重连）。
class _DegradeState {
  int reconnects = 0;
}

bool _isRetryable(Object error) {
  if (error is ModelDownloadStatusException) return error.isTransient;
  return error is IOException ||
      error is TimeoutException ||
      error is _DegradedConnection;
}

/// 模型下载器。[createClient] 可注入（测试指向本地 HttpServer）。
class ModelFileDownloader {
  ModelFileDownloader({
    HttpClient Function()? createClient,
    List<String> Function(DownloadableModelFile file)? urlCandidates,
    this.progressByteInterval = kModelDownloadProgressInterval,
    this.resilience = const ModelDownloadResilience(),
  })  : _createClient = createClient ?? _defaultClient,
        _urlCandidates = urlCandidates ?? _defaultUrlCandidates;

  final HttpClient Function() _createClient;

  /// 连接健康策略（卡死 / 劣化 / 瞬时错误时换连接续传）。
  final ModelDownloadResilience resilience;

  /// 单文件的下载候选 URL 序列（主源 + 镜像）。可注入：镜像回退这条分支只有
  /// 把候选序列做成参数才测得到——真实候选写死了 huggingface 域名，测试里的
  /// 本地 HttpServer 永远派生不出第二个候选。
  final List<String> Function(DownloadableModelFile file) _urlCandidates;

  /// 两次进度事件之间至少累积的字节数（首尾事件恒发）。
  final int progressByteInterval;

  // BUG-1498：原先是 `findProxyFromEnvironment`——只读 HTTPS_PROXY/HTTP_PROXY 环境
  // 变量，读不到 Windows 注册表 / macOS / Linux 的 GUI 系统代理。而这条链路要从
  // huggingface 下几百 MB 模型，clash「系统代理」模式（写注册表、不导出 env）下
  // 等于裸直连。改走统一装配点后 env > GUI 系统代理 > DIRECT 一致生效。
  static HttpClient _defaultClient() => createAsrHttpClient()
    // 主源在部分网络下是「连不上」而非「连上后慢」。系统默认超时可以拖到
    // 数十秒，多个文件叠起来用户只看到一个不动的进度条。20s 足够覆盖正常
    // 握手，又能让镜像回退在可感知的时间内发生。
    ..connectionTimeout = const Duration(seconds: 20);

  /// 下载清单里所有未就绪文件到 [targetDir]。
  ///
  /// - [isReady] 判定最终文件是否已就绪（各子系统自己的规则，通常是「存在且
  ///   非空」）；已就绪文件跳过（仍发一条 received==total 的完成进度，让 UI
  ///   汇总正确）。
  /// - `.part` 残留触发 Range 续传；服务器不支持（非 206）则整文件重下。
  /// - 单文件完成：长度非零 + （expected>0 时）长度==expected，然后原子
  ///   rename `.part` → 最终名。
  /// - 全部完成后补发 `done=true` 收尾事件。
  Stream<ModelDownloadEvent> downloadAll({
    required List<DownloadableModelFile> files,
    required Directory targetDir,
    required bool Function(File file) isReady,
  }) async* {
    if (files.isEmpty) {
      return;
    }
    await targetDir.create(recursive: true);
    final HttpClient client = _createClient();
    final _SpeedReference reference = _SpeedReference();
    try {
      for (final DownloadableModelFile file in files) {
        final File target = File(p.join(targetDir.path, file.fileName));
        if (isReady(target)) {
          final int size = target.lengthSync();
          yield ModelDownloadEvent(
            fileName: file.fileName,
            receivedBytes: size,
            totalBytes: size,
          );
          continue;
        }
        yield* _downloadFile(client, file, target, reference);
      }
      final DownloadableModelFile last = files.last;
      yield ModelDownloadEvent(
        fileName: last.fileName,
        receivedBytes: last.expectedBytes,
        totalBytes: last.expectedBytes,
        done: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 单文件下载：主源失败按序换镜像（候选序列由 [_urlCandidates] 给出）。
  ///
  /// 换源不清 `.part`——镜像与主源是同一个 blob，续传直接接上；万一遇到内容不
  /// 一致的源，rename 前的长度校验仍会拦下并删掉坏 `.part`。全部候选都失败时抛
  /// 最后一个错误，语义与单源时代一致。
  ///
  /// 同一候选内，可重试的失败（见 [ModelDownloadResilience]）断开连接后用 Range
  /// 续传；有进度的重连立即进行、不计失败，没进度的才计数并退避。
  Stream<ModelDownloadEvent> _downloadFile(
    HttpClient client,
    DownloadableModelFile file,
    File target,
    _SpeedReference reference,
  ) async* {
    final List<String> candidates = _urlCandidates(file);
    final File part = File('${target.path}.part');
    final _DegradeState degrade = _DegradeState();
    Object? lastError;
    StackTrace? lastStack;
    for (final String url in candidates) {
      int failures = 0;
      while (failures < resilience.maxFailedAttempts) {
        final int before = _lengthOf(part);
        try {
          // 逐事件转发而不是 `yield*`：async* 里 `yield*` 委托出去的错误直接流向
          // 下游监听者，**不经过**这里的 try/catch——那样写出来的回退循环长得
          // 像模像样，实际第一个候选一失败就整条流报错，永远换不到镜像。
          await for (final ModelDownloadEvent event in _downloadFileFrom(
            client,
            file,
            target,
            url,
            reference,
            degrade,
          )) {
            yield event;
          }
          return;
        } on Object catch (error, stack) {
          lastError = error;
          lastStack = stack;
          if (!_isRetryable(error)) break;
          failures = _lengthOf(part) > before ? 0 : failures + 1;
          await _backoff(failures);
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  static int _lengthOf(File file) => file.existsSync() ? file.lengthSync() : 0;

  /// 第 n 次连续无进度失败后等 retryBackoff × 2^(n-1)；有进度（n=0）立即重连，
  /// 用完次数的那一次也不等（马上换候选 / 抛错）。
  Future<void> _backoff(int failures) async {
    if (failures <= 0 || failures >= resilience.maxFailedAttempts) return;
    await Future<void>.delayed(resilience.retryBackoff * (1 << (failures - 1)));
  }

  /// 结算一个测速窗口：更新参照，劣化时抛 [_DegradedConnection] 断开连接。
  void _checkSpeed(int rate, _SpeedReference reference, _DegradeState degrade) {
    final int peak = reference.peakBytesPerSecond;
    reference.peakBytesPerSecond = math.max(peak, rate);
    if (degrade.reconnects >= resilience.maxDegradedReconnects) return;
    final bool hasReference = peak >= resilience.minReferenceBytesPerSecond;
    final bool degraded = hasReference
        ? rate * resilience.degradedRatio < peak
        : rate < resilience.minReferenceBytesPerSecond &&
            degrade.reconnects == 0;
    if (!degraded) {
      if (hasReference) degrade.reconnects = 0;
      return;
    }
    degrade.reconnects++;
    throw _DegradedConnection(rate);
  }

  Stream<ModelDownloadEvent> _downloadFileFrom(
    HttpClient client,
    DownloadableModelFile file,
    File target,
    String url,
    _SpeedReference reference,
    _DegradeState degrade,
  ) async* {
    final File part = File('${target.path}.part');
    int offset = part.existsSync() ? part.lengthSync() : 0;

    final HttpClientRequest request = await client.getUrl(Uri.parse(url));
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    // 等响应头也算卡死窗口：连上了却迟迟不回头的连接与读到一半不动是同一种坏。
    final HttpClientResponse response = await request.close().timeout(
          resilience.stallTimeout,
        );

    if (offset > 0 &&
        response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        file.expectedBytes > 0 &&
        offset == file.expectedBytes) {
      // `.part` 已经完整（上次在 rename 前中断），服务器对 bytes=<len>- 回 416：
      // 不再拉流，直接走校验 + 原子转正。
      await response.drain<void>();
      yield _finalizePart(file, part, target);
      return;
    }

    final IOSink sink;
    int received;
    int total;
    if (offset > 0 && response.statusCode == HttpStatus.partialContent) {
      // Range 命中：从 offset 续写。
      received = offset;
      total = response.contentLength > 0
          ? offset + response.contentLength
          : math.max(file.expectedBytes, offset);
      sink = part.openWrite(mode: FileMode.append);
    } else if (response.statusCode == HttpStatus.ok) {
      // 服务器不支持 Range（或本就无残留）：整文件重下，截断旧残留。
      received = 0;
      total = response.contentLength > 0
          ? response.contentLength
          : file.expectedBytes;
      sink = part.openWrite();
      offset = 0;
    } else {
      await response.drain<void>();
      throw ModelDownloadStatusException(
        response.statusCode,
        'download ${file.fileName} failed: HTTP ${response.statusCode}',
        uri: Uri.parse(url),
      );
    }

    int lastEmitted = -1;
    final Stopwatch window = Stopwatch()..start();
    int windowBytes = 0;
    try {
      yield ModelDownloadEvent(
        fileName: file.fileName,
        receivedBytes: received,
        totalBytes: total,
      );
      lastEmitted = received;
      // 两次数据之间超过 stallTimeout 即 TimeoutException：退出循环会取消订阅，
      // dart:io 随之销毁这条 socket，重连拿到的是新连接。
      await for (final List<int> chunk in response.timeout(
        resilience.stallTimeout,
      )) {
        sink.add(chunk);
        received += chunk.length;
        windowBytes += chunk.length;
        if (window.elapsed >= resilience.speedWindow) {
          final int micros = math.max(1, window.elapsedMicroseconds);
          _checkSpeed(windowBytes * 1000000 ~/ micros, reference, degrade);
          windowBytes = 0;
          window.reset();
        }
        if (received - lastEmitted >= progressByteInterval) {
          yield ModelDownloadEvent(
            fileName: file.fileName,
            receivedBytes: received,
            totalBytes: total,
          );
          lastEmitted = received;
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    yield _finalizePart(file, part, target);
  }

  /// 完成一个 `.part`：实际大小校验（非零恒查；expected>0 时长度校验——传输
  /// 截断/上游漂移都在 rename 前拦截，绝不把坏档转正）+ 原子 rename，返回该
  /// 文件的完成事件。
  ModelDownloadEvent _finalizePart(
    DownloadableModelFile file,
    File part,
    File target,
  ) {
    final int actual = part.lengthSync();
    if (actual <= 0) {
      throw StateError('download ${file.fileName} produced empty file');
    }
    if (file.expectedBytes > 0 && actual != file.expectedBytes) {
      // 长度不符的 .part 不可信，删掉避免下次 Range 续传在坏偏移上加码。
      try {
        part.deleteSync();
      } catch (_) {}
      throw StateError(
        'download ${file.fileName} size mismatch: '
        'got $actual, expected ${file.expectedBytes}',
      );
    }

    // 原子转正：目标若有非法残留（0 字节）先清掉再 rename。
    if (target.existsSync()) {
      target.deleteSync();
    }
    part.renameSync(target.path);
    return ModelDownloadEvent(
      fileName: file.fileName,
      receivedBytes: actual,
      totalBytes: actual,
    );
  }
}
