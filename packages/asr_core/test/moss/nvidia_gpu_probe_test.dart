import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:test/test.dart';

import '../support/fake_process.dart';

void main() {
  test('解析 csv：驱动主版本、计算能力 ×10，坏行跳过', () {
    final List<NvidiaGpuInfo> gpus =
        parseNvidiaSmiGpuCsv('596.49, 12.0\r\n\r\ngarbage\n580.12, 7.5\n');
    expect(gpus, hasLength(2));
    expect(gpus[0].driverMajor, 596);
    expect(gpus[0].computeCapability, 120);
    expect(gpus[0].index, 0);
    expect(gpus[1].computeCapability, 75);
    expect(gpus[1].index, 2);
  });

  group('门槛', () {
    NvidiaGpuInfo gpu(int driver, int cc) => NvidiaGpuInfo(
          index: 0,
          driverVersion: '$driver.00',
          driverMajor: driver,
          computeCapability: cc,
        );

    test('Windows：R580 + sm_75', () {
      expect(
          judgeMossCudaAvailability(
                  <NvidiaGpuInfo>[gpu(580, 75)], AudioCppPlatform.windowsX64)
              .available,
          isTrue);
      final MossCudaAvailability old = judgeMossCudaAvailability(
          <NvidiaGpuInfo>[gpu(579, 120)], AudioCppPlatform.windowsX64);
      expect(old.available, isFalse);
      expect(old.reason, contains('R580'));
      expect(
          judgeMossCudaAvailability(
                  <NvidiaGpuInfo>[gpu(596, 61)], AudioCppPlatform.windowsX64)
              .available,
          isFalse);
    });

    test('Linux：R570（CUDA 12.8）', () {
      expect(
          judgeMossCudaAvailability(
                  <NvidiaGpuInfo>[gpu(570, 86)], AudioCppPlatform.linuxX64)
              .available,
          isTrue);
      expect(
          judgeMossCudaAvailability(
                  <NvidiaGpuInfo>[gpu(565, 86)], AudioCppPlatform.linuxX64)
              .available,
          isFalse);
    });

    test('多卡任一达标即可；无卡不可用', () {
      expect(
          judgeMossCudaAvailability(
            <NvidiaGpuInfo>[gpu(596, 61), gpu(596, 89)],
            AudioCppPlatform.windowsX64,
          ).available,
          isTrue);
      expect(
          judgeMossCudaAvailability(
                  const <NvidiaGpuInfo>[], AudioCppPlatform.windowsX64)
              .available,
          isFalse);
    });
  });

  group('探测（注入启动器）', () {
    test('参数正确、成功路径', () async {
      final List<StartedCall> calls = <StartedCall>[];
      final MossCudaAvailability r = await probeMossCudaAvailability(
        platform: AudioCppPlatform.windowsX64,
        startProcess: (String e, List<String> a) async {
          final FakeProcess fp = FakeProcess(stdoutText: '596.49, 12.0\n');
          calls.add(StartedCall(e, a, fp));
          return fp;
        },
      );
      expect(r.available, isTrue);
      expect(calls.single.executable, 'nvidia-smi');
      expect(calls.single.arguments, <String>[
        '--query-gpu=driver_version,compute_cap',
        '--format=csv,noheader',
      ]);
    });

    test('nvidia-smi 不存在：不可用 + 原因，不抛', () async {
      final MossCudaAvailability r = await probeMossCudaAvailability(
        platform: AudioCppPlatform.linuxX64,
        startProcess: (String e, List<String> a) =>
            throw ProcessException(e, a, 'not found', 2),
      );
      expect(r.available, isFalse);
      expect(r.reason, contains('nvidia-smi'));
    });

    test('非零退出：不可用 + 原因', () async {
      final MossCudaAvailability r = await probeMossCudaAvailability(
        platform: AudioCppPlatform.windowsX64,
        startProcess: (String e, List<String> a) async =>
            FakeProcess(stdoutText: 'NVIDIA-SMI has failed', exitCodeValue: 9),
      );
      expect(r.available, isFalse);
      expect(r.reason, contains('NVIDIA-SMI has failed'));
    });

    test('卡死：超时杀掉，不可用', () async {
      FakeProcess? hung;
      final MossCudaAvailability r = await probeMossCudaAvailability(
        platform: AudioCppPlatform.windowsX64,
        timeout: const Duration(milliseconds: 50),
        startProcess: (String e, List<String> a) async =>
            hung = FakeProcess(hang: true),
      );
      expect(r.available, isFalse);
      expect(hung!.killed, isTrue);
    });
  });
}
