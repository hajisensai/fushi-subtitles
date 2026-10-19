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

  group('CUDA 设备枚举（audiocpp_cli --list-devices）', () {
    test('解析 ggml 的设备行：CUDA 序号、名字、计算能力', () {
      final List<AudioCppCudaDevice> d = parseAudioCppCudaDevices(
        'available_devices=2\nCUDA:0 "NVIDIA GeForce RTX 5090" [GPU]\n'
        'ggml_cuda_init: found 2 CUDA devices (Total VRAM: 44894 MiB):\n'
        '  Device 0: NVIDIA GeForce RTX 5090, compute capability 12.0, '
        'VMM: yes, VRAM: 32606 MiB\r\n'
        '  Device 1: Tesla P40, compute capability 6.1, VMM: no, '
        'VRAM: 12288 MiB\n',
      );
      expect(d, hasLength(2));
      expect(d[0].index, 0);
      expect(d[0].name, 'NVIDIA GeForce RTX 5090');
      expect(d[0].computeCapability, 120);
      expect(d[1].index, 1);
      expect(d[1].computeCapability, 61);
      expect(parseAudioCppCudaDevices('ggml_vulkan: 0 = NVIDIA ...'), isEmpty);
    });

    test('选卡：序号最小的达标卡；都不达标为 null', () {
      AudioCppCudaDevice dev(int i, int cc) =>
          AudioCppCudaDevice(index: i, name: 'g$i', computeCapability: cc);
      expect(
          selectMossCudaDevice(<AudioCppCudaDevice>[dev(0, 61), dev(1, 86)])!
              .index,
          1);
      expect(
          selectMossCudaDevice(<AudioCppCudaDevice>[dev(2, 75), dev(1, 89)])!
              .index,
          1);
      expect(selectMossCudaDevice(<AudioCppCudaDevice>[dev(0, 61)]), isNull);
      expect(selectMossCudaDevice(const <AudioCppCudaDevice>[]), isNull);
    });

    test('listAudioCppCudaDevices：参数只有 --list-devices，stdout+stderr 都读',
        () async {
      final List<StartedCall> calls = <StartedCall>[];
      final List<AudioCppCudaDevice> d = await listAudioCppCudaDevices(
        'audiocpp_cli',
        startProcess: (String e, List<String> a) async {
          final FakeProcess fp = FakeProcess(
            stdoutText: 'CUDA:0 "x" [GPU]\n',
            stderrText: '  Device 0: x, compute capability 7.5, VMM: yes\n',
          );
          calls.add(StartedCall(e, a, fp));
          return fp;
        },
      );
      expect(calls.single.arguments, <String>['--list-devices']);
      expect(d.single.computeCapability, 75);
    });
  });

  group('后端选择以清单为准', () {
    const MossCudaAvailability yes = MossCudaAvailability(
        available: true, reason: null, gpus: <NvidiaGpuInfo>[]);
    const MossCudaAvailability no = MossCudaAvailability(
        available: false, reason: 'x', gpus: <NvidiaGpuInfo>[]);

    test('不探测的默认值：Windows = cuda，Linux = vulkan（没有 CUDA 版 CLI）', () {
      expect(defaultMossBackendFor(AudioCppPlatform.windowsX64),
          AudioCppBackend.cuda);
      expect(defaultMossBackendFor(AudioCppPlatform.linuxX64),
          AudioCppBackend.vulkan);
      expect(defaultMossBackendFor(null), AudioCppBackend.cpu);
    });

    test('结合探测：CUDA 可用且清单有包才取 cuda', () {
      expect(selectMossBackend(AudioCppPlatform.windowsX64, yes),
          AudioCppBackend.cuda);
      expect(selectMossBackend(AudioCppPlatform.windowsX64, no),
          AudioCppBackend.vulkan);
      expect(selectMossBackend(AudioCppPlatform.linuxX64, yes),
          AudioCppBackend.vulkan);
      expect(selectMossBackend(AudioCppPlatform.linuxX64, no),
          AudioCppBackend.vulkan);
    });

    test('chooseMossBackend：Linux 不跑 nvidia-smi；Windows 按探测结论', () async {
      expect(
        await chooseMossBackend(
          platform: AudioCppPlatform.linuxX64,
          startProcess: (String e, List<String> a) => fail('不应探测：$e'),
        ),
        AudioCppBackend.vulkan,
      );
      expect(
        await chooseMossBackend(
          platform: AudioCppPlatform.windowsX64,
          startProcess: (String e, List<String> a) async =>
              FakeProcess(stdoutText: '596.49, 12.0\n'),
        ),
        AudioCppBackend.cuda,
      );
      expect(
        await chooseMossBackend(
          platform: AudioCppPlatform.windowsX64,
          startProcess: (String e, List<String> a) async =>
              FakeProcess(stdoutText: '596.49, 6.1\n'),
        ),
        AudioCppBackend.vulkan,
      );
    });
  });
}
