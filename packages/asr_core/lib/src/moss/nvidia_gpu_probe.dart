/// MOSS 的 CUDA 后端能不能在这台机器上跑：经 `nvidia-smi` 问驱动版本与计算能力。
///
/// 判据与宿主（Fushi `gpu_acceleration.dart`）的 CUDA 13 门槛一致：
/// - 驱动主版本 ≥ 580（CUDA 13.x 的 minor-version compatibility 下限；Windows
///   运行库是 cuda13.3 构建）；
/// - 计算能力 ≥ 7.5（Turing，CUDA 13 支持的最低架构）。
///
/// Linux 侧按 CUDA 12.8 的要求算驱动门槛：NVIDIA CUDA Toolkit Release Notes
/// 表 3 写明 12.8 GA 需要 Linux ≥ 570.26（Windows ≥ 570.65）。12.x 的
/// minor-version compatibility 虽然把下限放宽到 525，但那条路不支持 PTX JIT，
/// 而预编译内核不覆盖的新卡要靠 JIT，所以取 570 这个保守值。注意 audio.cpp
/// v0.9.2 并没有发布 Linux CUDA 版 CLI（见 `audiocpp_manifest.dart`），这条门槛
/// 只描述「显卡够不够」，运行库缺项由清单另行回答。
///
/// 探测失败（没装驱动、`nvidia-smi` 不在、输出看不懂）返回不可用 + 原因，**不抛**。
library;

import 'dart:io';

import 'package:fushi_asr_core/src/moss/audiocpp_manifest.dart';
import 'package:fushi_asr_core/src/util/asr_process.dart';

/// Windows（CUDA 13.x）最低驱动主版本。
const int kMossCudaMinDriverMajorWindows = 580;

/// Linux（CUDA 12.8）最低驱动主版本。
const int kMossCudaMinDriverMajorLinux = 570;

/// 最低计算能力 ×10（7.5 → 75）。
const int kMossCudaMinComputeCapability = 75;

/// 一块 N 卡的探测值。
class NvidiaGpuInfo {
  const NvidiaGpuInfo({
    required this.index,
    required this.driverVersion,
    required this.driverMajor,
    required this.computeCapability,
  });

  /// `nvidia-smi` 输出里的行号（= nvidia-smi 的设备序号）。
  final int index;

  /// 原文，如 `596.49`。
  final String driverVersion;
  final int driverMajor;

  /// 计算能力 ×10，如 `12.0` → 120。
  final int computeCapability;
}

/// 可用性结论。
class MossCudaAvailability {
  const MossCudaAvailability({
    required this.available,
    required this.reason,
    required this.gpus,
  });

  final bool available;

  /// 不可用时的原因（可直接展示）；可用时为 null。
  final String? reason;

  /// 解析出的所有显卡（探测失败时为空）。
  final List<NvidiaGpuInfo> gpus;
}

/// 解析 `nvidia-smi --query-gpu=driver_version,compute_cap --format=csv,noheader`。
/// 看不懂的行跳过。
List<NvidiaGpuInfo> parseNvidiaSmiGpuCsv(String output) {
  final List<NvidiaGpuInfo> gpus = <NvidiaGpuInfo>[];
  int index = 0;
  for (final String raw in output.split('\n')) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    final List<String> parts =
        line.split(',').map((String s) => s.trim()).toList();
    final int row = index++;
    if (parts.length < 2) continue;
    final int? major = int.tryParse(parts[0].split('.').first);
    final List<String> cc = parts[1].split('.');
    final int? ccMajor = int.tryParse(cc.first);
    final int? ccMinor = cc.length > 1 ? int.tryParse(cc[1]) : 0;
    if (major == null || ccMajor == null || ccMinor == null) continue;
    gpus.add(NvidiaGpuInfo(
      index: row,
      driverVersion: parts[0],
      driverMajor: major,
      computeCapability: ccMajor * 10 + ccMinor,
    ));
  }
  return gpus;
}

/// 按平台门槛判定（纯函数）。任意一块卡达标即可用——与宿主判据一致。
MossCudaAvailability judgeMossCudaAvailability(
  List<NvidiaGpuInfo> gpus,
  AudioCppPlatform platform,
) {
  if (gpus.isEmpty) {
    return const MossCudaAvailability(
      available: false,
      reason: '没有检测到 NVIDIA 显卡',
      gpus: <NvidiaGpuInfo>[],
    );
  }
  final int minDriver = platform == AudioCppPlatform.windowsX64
      ? kMossCudaMinDriverMajorWindows
      : kMossCudaMinDriverMajorLinux;
  // 驱动是整机一份，各行相同；按第一行判。
  final NvidiaGpuInfo first = gpus.first;
  if (first.driverMajor < minDriver) {
    return MossCudaAvailability(
      available: false,
      reason: 'NVIDIA 驱动 ${first.driverVersion} 低于要求（R$minDriver 及以上）',
      gpus: gpus,
    );
  }
  final bool anyCapable = gpus.any((NvidiaGpuInfo g) =>
      g.computeCapability >= kMossCudaMinComputeCapability);
  if (!anyCapable) {
    return MossCudaAvailability(
      available: false,
      reason: '显卡计算能力低于 7.5（需要 Turing 及更新架构）',
      gpus: gpus,
    );
  }
  return MossCudaAvailability(available: true, reason: null, gpus: gpus);
}

/// 当前进程所在平台；不是 Windows / Linux x64 时为 null。
AudioCppPlatform? currentAudioCppPlatform() {
  if (Platform.isWindows) return AudioCppPlatform.windowsX64;
  if (Platform.isLinux) return AudioCppPlatform.linuxX64;
  return null;
}

/// 跑 `nvidia-smi` 并判定。经 [startProcess] 起进程（宿主注入自己的登记表）。
Future<MossCudaAvailability> probeMossCudaAvailability({
  AsrProcessStarter? startProcess,
  AudioCppPlatform? platform,
  String nvidiaSmiExecutable = 'nvidia-smi',
  Duration timeout = const Duration(seconds: 15),
}) async {
  final AudioCppPlatform? target = platform ?? currentAudioCppPlatform();
  if (target == null) {
    return const MossCudaAvailability(
      available: false,
      reason: 'MOSS CUDA 后端只支持 Windows / Linux',
      gpus: <NvidiaGpuInfo>[],
    );
  }
  final AsrProcessResult result;
  try {
    result = await runAsrProcess(
      nvidiaSmiExecutable,
      const <String>[
        '--query-gpu=driver_version,compute_cap',
        '--format=csv,noheader',
      ],
      startProcess: startProcess,
      timeout: timeout,
    );
  } on ProcessException catch (e) {
    return MossCudaAvailability(
      available: false,
      reason: '找不到 nvidia-smi（未安装 NVIDIA 驱动？）：${e.message}',
      gpus: const <NvidiaGpuInfo>[],
    );
  } on AsrProcessTimeoutException {
    return const MossCudaAvailability(
      available: false,
      reason: 'nvidia-smi 无响应',
      gpus: <NvidiaGpuInfo>[],
    );
  } on Exception catch (e) {
    // 宿主注入的启动器可能抛自己的异常类型（登记表拒绝等）：一律当不可用。
    return MossCudaAvailability(
      available: false,
      reason: '无法运行 nvidia-smi：$e',
      gpus: const <NvidiaGpuInfo>[],
    );
  }
  if (result.exitCode != 0) {
    final String err = result.stderr.trim().isEmpty
        ? result.stdout.trim()
        : result.stderr.trim();
    return MossCudaAvailability(
      available: false,
      reason: 'nvidia-smi 失败（退出码 ${result.exitCode}）：$err',
      gpus: const <NvidiaGpuInfo>[],
    );
  }
  return judgeMossCudaAvailability(parseNvidiaSmiGpuCsv(result.stdout), target);
}
