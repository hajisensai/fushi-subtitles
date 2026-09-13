import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:fushi_asr/asr.dart' show OrtRuntime;
import 'package:fushi_asr_cli/asr_cli.dart';

Future<void> main(List<String> args) async {
  try {
    exitCode = await buildAsrCommandRunner().run(args) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    exitCode = 64; // EX_USAGE
  } finally {
    // 各命令在自己的 finally 里已把会话关完；这里只剩 OrtEnv。不释放它 macOS 上
    // 退出必 abort（见 OrtRuntime.shutdown）。
    OrtRuntime.shutdown();
  }
}
