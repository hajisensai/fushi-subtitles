import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 测试用假子进程：stdout / stderr 一次性给定，退出码由 [exit] 决定；
/// [hang] 为真时直到 [kill] 才退出（退出码 -9）。
class FakeProcess implements Process {
  FakeProcess({
    String stdoutText = '',
    String stderrText = '',
    int exitCodeValue = 0,
    bool hang = false,
  }) {
    _stdout.add(utf8.encode(stdoutText));
    _stderr.add(utf8.encode(stderrText));
    if (!hang) {
      _finish(exitCodeValue);
    }
  }

  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();

  /// 是否被 kill 过。
  bool killed = false;

  void _finish(int code) {
    if (_exit.isCompleted) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => throw UnsupportedError('stdin');

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    _finish(-9);
    return true;
  }
}

/// 一次被记录下来的启动调用。
class StartedCall {
  StartedCall(this.executable, this.arguments, this.process);

  final String executable;
  final List<String> arguments;
  final FakeProcess process;

  /// 取 `--flag value` 的值。
  String? arg(String flag) {
    final int i = arguments.indexOf(flag);
    return i < 0 || i + 1 >= arguments.length ? null : arguments[i + 1];
  }
}
