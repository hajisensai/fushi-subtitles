/// 外部子进程的启动注入点 + 取消令牌。
///
/// 存在的理由：MOSS 分段、`nvidia-smi` 探测、运行库解压都要起外部进程，而宿主
/// （Fushi）要求**所有**子进程经它自己的登记表启动——退出时统一清理、崩溃后能
/// 找回孤儿进程。库不能依赖宿主那一套，所以把「怎么起进程」做成参数：调用方
/// 不传就用 [Process.start]，宿主传它自己的启动器。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 起一个子进程。签名刻意窄：只有可执行文件与参数，环境 / 工作目录一律继承
/// 当前进程，宿主的登记表因此只需实现这一种形态。
typedef AsrProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// 默认启动器：直接 [Process.start]。
Future<Process> defaultAsrProcessStarter(
  String executable,
  List<String> arguments,
) =>
    Process.start(executable, arguments);

/// 任务被调用方取消。
class AsrCancelledException implements Exception {
  const AsrCancelledException();

  @override
  String toString() => 'AsrCancelledException';
}

/// 取消令牌：调用方持有并 [cancel]，库在阶段边界检查、并在子进程运行期间监听
/// [whenCancelled] 立刻杀掉当前子进程。
class AsrCancellationToken {
  final Completer<void> _completer = Completer<void>();

  /// 是否已取消。
  bool get isCancelled => _completer.isCompleted;

  /// 取消时完成的 future（永不出错）。
  Future<void> get whenCancelled => _completer.future;

  /// 请求取消；重复调用无副作用。
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }

  /// 已取消就抛 [AsrCancelledException]。
  void throwIfCancelled() {
    if (isCancelled) throw const AsrCancelledException();
  }
}

/// 一次子进程运行的结果（stdout / stderr 按 UTF-8 宽容解码）。
class AsrProcessResult {
  const AsrProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// 子进程超时未退出（已被杀掉）。
class AsrProcessTimeoutException implements Exception {
  const AsrProcessTimeoutException(this.executable, this.timeout);

  final String executable;
  final Duration timeout;

  @override
  String toString() =>
      'AsrProcessTimeoutException($executable 超过 ${timeout.inSeconds}s 未退出)';
}

/// 起进程、并发排干两条管道、等它退出。
///
/// - 两条管道必须同时排：子进程往任意一条写满缓冲区都会阻塞，只等 exitCode
///   会把长任务卡死。
/// - [cancellation] 触发时杀掉子进程并抛 [AsrCancelledException]；
///   [timeout] 到期同样杀掉，抛 [AsrProcessTimeoutException]。
/// - [ProcessException]（可执行文件不存在等）原样向上传播。
Future<AsrProcessResult> runAsrProcess(
  String executable,
  List<String> arguments, {
  AsrProcessStarter? startProcess,
  AsrCancellationToken? cancellation,
  Duration? timeout,
}) async {
  cancellation?.throwIfCancelled();
  final Process process =
      await (startProcess ?? defaultAsrProcessStarter)(executable, arguments);
  bool killedByCancel = false;
  bool killedByTimeout = false;
  final Future<String> stdoutText =
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final Future<String> stderrText =
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
  Timer? timer;
  if (timeout != null) {
    timer = Timer(timeout, () {
      killedByTimeout = true;
      process.kill();
    });
  }
  // 取消监听：令牌完成即杀进程。进程正常退出后再触发的取消不影响本次结果。
  bool exited = false;
  unawaited(cancellation?.whenCancelled.then((_) {
    if (exited) return;
    killedByCancel = true;
    process.kill();
  }));
  try {
    final int code = await process.exitCode;
    exited = true;
    final String out = await stdoutText;
    final String err = await stderrText;
    if (killedByCancel) throw const AsrCancelledException();
    if (killedByTimeout) {
      throw AsrProcessTimeoutException(executable, timeout!);
    }
    return AsrProcessResult(exitCode: code, stdout: out, stderr: err);
  } finally {
    exited = true;
    timer?.cancel();
  }
}
