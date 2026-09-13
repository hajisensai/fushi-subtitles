/// `fushi-subs doctor`：运行环境体检。
///
/// 转录真正依赖的外部件只有两样——ONNX Runtime 动态库与 ffmpeg——出问题时用户看到
/// 的却是转录中途的一条异常。这里把两样各自「解析到哪、装不装得上、什么版本」一次
/// 摆出来；退出码 0 当且仅当两样都可用，所以它同时也是 Release 流水线的冒烟门：
/// 随包的运行时在目标 OS / 架构上真能加载，包才算能发。
library;

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:fushi_asr/asr.dart';

/// 一样外部件的探测结果：解析到的路径 + 版本（可用）或失败原因（不可用）。
class DoctorProbe {
  const DoctorProbe.ok({required this.path, required this.version})
      : failure = null;

  const DoctorProbe.failed({required this.path, required this.failure})
      : version = null;

  /// 解析到的路径或裸命令名；失败时是最后试的那个。
  final String path;
  final String? version;
  final String? failure;

  bool get ok => failure == null;
}

/// 体检报告。
class DoctorReport {
  const DoctorReport({
    required this.ort,
    required this.providers,
    required this.ffmpeg,
    required this.ffprobe,
  });

  final DoctorProbe ort;

  /// ORT 装上后探到的加速 EP 名；装不上时为空。
  final List<String> providers;
  final DoctorProbe ffmpeg;

  /// ffprobe 可选（缺了只是进度百分比不准），不参与 [healthy]。
  final DoctorProbe ffprobe;

  bool get healthy => ort.ok && ffmpeg.ok;
}

/// 采集报告。Windows 上先走一遍与转录相同的按需下载（缺库时下 17.9 MB），
/// 其它平台缺库直接报失败并给出安装指引——与真实转录路径逐字一致，体检说
/// 「能用」转录就不会再因为运行时栽在同一处。
Future<DoctorReport> collectDoctorReport({
  void Function(ModelDownloadEvent event)? onDownload,
}) async {
  final DoctorProbe ort = await _probeOrt(onDownload);
  List<String> providers = const <String>[];
  if (ort.ok) {
    final Set<OnnxExecutionProvider> eps =
        await FfiOnnxSessionFactory().availableAcceleratedProviders();
    providers = eps.map((OnnxExecutionProvider e) => e.name).toList()..sort();
  }
  return DoctorReport(
    ort: ort,
    providers: providers,
    ffmpeg: await _probeTool(resolveFfmpegExecutable()),
    ffprobe: await _probeTool(resolveFfprobeExecutable()),
  );
}

Future<DoctorProbe> _probeOrt(
  void Function(ModelDownloadEvent event)? onDownload,
) async {
  try {
    await for (final ModelDownloadEvent e in ensureOrtRuntime()) {
      onDownload?.call(e);
    }
    final OrtRuntime rt = OrtRuntime.instance();
    return DoctorProbe.ok(path: rt.libraryPath, version: rt.versionString);
  } on OrtProvisionUnsupported catch (e) {
    return DoctorProbe.failed(
      path: OrtRuntime.resolveLibraryCandidates().join(' / '),
      failure: e.message,
    );
  } on OrtRuntimeUnavailable catch (e) {
    return DoctorProbe.failed(
      path: e.attempted.isEmpty ? '(无候选)' : e.attempted.join(' / '),
      failure: e.message,
    );
  } catch (e) {
    return DoctorProbe.failed(
      path: OrtRuntime.resolveLibraryCandidates().join(' / '),
      failure: '$e',
    );
  }
}

/// 跑 `<tool> -version`，取首行当版本。起不来（不存在 / 不可执行）即失败。
Future<DoctorProbe> _probeTool(String executable) async {
  try {
    final ProcessResult r = await Process.run(executable, <String>['-version'])
        .timeout(const Duration(seconds: 15));
    final String out = '${r.stdout}'.trim();
    final String firstLine = out.split(RegExp(r'\r?\n')).first;
    if (r.exitCode != 0 || firstLine.isEmpty) {
      return DoctorProbe.failed(
        path: executable,
        failure: '退出码 ${r.exitCode}：${'${r.stderr}'.trim()}',
      );
    }
    return DoctorProbe.ok(path: executable, version: firstLine);
  } on ProcessException catch (e) {
    return DoctorProbe.failed(path: executable, failure: e.message);
  } on TimeoutException {
    return DoctorProbe.failed(path: executable, failure: '15 秒没有响应');
  }
}

/// 报告的文本形态。纯函数，便于单测；每样一行「名 · 状态 · 路径 · 版本/原因」。
String formatDoctorReport(DoctorReport report) {
  final StringBuffer b = StringBuffer();
  b.writeln(_line('ONNX Runtime', report.ort));
  if (report.ort.ok) {
    b.writeln('  加速后端: '
        '${report.providers.isEmpty ? "无（仅 CPU）" : report.providers.join(", ")}');
  }
  b.writeln(_line('ffmpeg', report.ffmpeg));
  b.writeln(_line('ffprobe', report.ffprobe, optional: true));
  b.writeln(report.healthy ? '结论: 可以转录' : '结论: 不能转录，先修上面标 ✗ 的项');
  return b.toString();
}

String _line(String name, DoctorProbe probe, {bool optional = false}) {
  if (probe.ok) return '✓ $name  ${probe.path}\n  版本: ${probe.version}';
  final String mark = optional ? '△' : '✗';
  return '$mark $name  ${probe.path}\n  ${optional ? "可选，缺了只影响进度百分比: " : ""}${probe.failure}';
}

class DoctorCommand extends Command<int> {
  @override
  String get name => 'doctor';

  @override
  String get description => '检查运行环境：ONNX Runtime、加速后端、ffmpeg。都可用退出码才是 0。';

  @override
  Future<int> run() async {
    // 与其它子命令同款：`--data-dir` 决定按需下载的 ORT 落在哪个数据根下。
    final Object? dataDir = globalResults?['data-dir'];
    if (dataDir is String && dataDir.isNotEmpty) {
      final Directory root = Directory(dataDir);
      asrSupportRootResolver = () async => root;
    }
    String? lastFile;
    final DoctorReport report = await collectDoctorReport(
      onDownload: (ModelDownloadEvent e) {
        if (e.fileName != lastFile) {
          lastFile = e.fileName;
          stderr.writeln('下载 ONNX Runtime $kOrtPackageVersion（${e.fileName}）…');
        }
      },
    );
    stdout.write(formatDoctorReport(report));
    return report.healthy ? 0 : 1;
  }
}
