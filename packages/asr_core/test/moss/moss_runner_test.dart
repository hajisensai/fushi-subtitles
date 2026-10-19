import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process.dart';

/// 响信号里挖若干安静段（与 quiet_cuts 测试同一种构造）。
Float32List _signal(double seconds, List<(double, double)> dips) {
  final int n = (seconds * kAsrSampleRate).round();
  final Float32List out = Float32List(n);
  for (int i = 0; i < n; i++) {
    final double t = i / kAsrSampleRate;
    final bool quiet = dips.any(((double, double) d) => t >= d.$1 && t < d.$2);
    final double a = quiet ? 0.001 : 0.3;
    out[i] = i.isEven ? a : -a;
  }
  return out;
}

/// wav 文件的时长（秒）：44 字节头 + PCM_16 单声道。
double _wavSeconds(String path) =>
    (File(path).lengthSync() - 44) / 2 / kAsrSampleRate;

/// audio.cpp v0.9.2 CUDA 版 `--list-devices` 的真实 stderr 形态（双卡）。
const String _kTwoCudaDevicesStderr =
    'ggml_cuda_init: found 2 CUDA devices (Total VRAM: 40000 MiB):\n'
    '  Device 0: NVIDIA GeForce GTX 1080 Ti, compute capability 6.1, VMM: yes, '
    'VRAM: 11264 MiB\n'
    '  Device 1: NVIDIA GeForce RTX 3060, compute capability 8.6, VMM: yes, '
    'VRAM: 12288 MiB\n'
    'load_backend: loaded CUDA backend from ggml-cuda.dll\n';

/// 假 CLI：按 [respond] 的结果写 `--text-out`，记录每次调用。`--list-devices`
/// 单独记在 [listCalls]，按 [listDevicesStderr] 回答。
class _FakeCli {
  _FakeCli(this.respond, {this.listDevicesStderr = _kTwoCudaDevicesStderr});

  /// 入参：本块时长；返回 (退出码, stderr, 原始流文本)。
  final (int, String, String) Function(double seconds) respond;
  final String listDevicesStderr;
  final List<StartedCall> calls = <StartedCall>[];
  final List<StartedCall> listCalls = <StartedCall>[];

  Future<Process> start(String executable, List<String> arguments) async {
    if (arguments.contains('--list-devices')) {
      final FakeProcess process = FakeProcess(
        stdoutText: 'available_devices=1\n',
        stderrText: listDevicesStderr,
      );
      listCalls.add(StartedCall(executable, arguments, process));
      return process;
    }
    final double seconds = _wavSeconds(
      arguments[arguments.indexOf('--audio') + 1],
    );
    final (int code, String err, String raw) = respond(seconds);
    final String txt = arguments[arguments.indexOf('--text-out') + 1];
    final String seg = arguments[arguments.indexOf('--segments-out') + 1];
    if (code == 0) {
      File(txt).writeAsStringSync(raw);
      File(seg).writeAsStringSync('[]');
    }
    final FakeProcess process =
        FakeProcess(stderrText: err, exitCodeValue: code);
    calls.add(StartedCall(executable, arguments, process));
    return process;
  }
}

String _model(Directory dir) {
  final File f = File(p.join(dir.path, 'moss.gguf'))..writeAsStringSync('w');
  return f.path;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('moss_runner_test_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('原始流解析', () {
    test('解析 [s][Sxx]正文[e]，跨行、去首尾空白', () {
      final List<MossRawCue> cues = parseMossRawTranscript(
        '[3.28][S01]はい。[3.84][4.44][S02] 澪、\n部室行こう [6.02][7][S01][7.1]',
      );
      expect(cues, hasLength(3));
      expect(cues[0].startSeconds, 3.28);
      expect(cues[0].endSeconds, 3.84);
      expect(cues[0].label, 'S01');
      expect(cues[0].text, 'はい。');
      expect(cues[1].text, '澪、\n部室行こう');
      expect(cues[2].text, isEmpty);
    });

    test('cue 口径：块起点偏移、end 至少 s+0.2、空正文丢弃、说话人带块序号', () {
      final List<MossCue> cues = mossCuesFromRaw(
        parseMossRawTranscript('[1.0][S01]あ[1.05][2][S02]い[3][4][S01] [5]'),
        chunkStartSeconds: 286.16,
        chunkOrdinal: 2,
      );
      expect(cues, hasLength(2));
      expect(cues[0].startMs, 287160);
      expect(cues[0].endMs, 287360); // max(1.05, 1.2)
      expect(cues[0].speaker, '2:S01');
      expect(cues[1].startMs, 288160);
      expect(cues[1].endMs, 289160);
      expect(cues[1].speaker, '2:S02');
    });
  });

  test('wav 编码：头字段正确，s16 解出的 float 原样还原', () {
    final Float32List pcm = Float32List.fromList(
        <double>[0, 1 / 32768, -1, 32767 / 32768, -12345 / 32768]);
    final Uint8List wav = encodePcm16Wav(pcm);
    final ByteData v = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(v.getUint32(24, Endian.little), 16000);
    expect(v.getUint16(34, Endian.little), 16);
    expect(v.getUint32(40, Endian.little), 10);
    expect(
      <int>[for (int i = 0; i < 5; i++) v.getInt16(44 + i * 2, Endian.little)],
      <int>[0, 1, -32768, 32767, -12345],
    );
  });

  test('模型路径不以 .gguf 结尾直接拒绝', () {
    expect(
      () => MossRunner(cliPath: 'cli', modelPath: 'model.bin'),
      throwsArgumentError,
    );
  });

  test('按静音切块、参数拼对、结果排序、临时文件删除', () async {
    final _FakeCli cli = _FakeCli(
      (double s) => (0, '', '[0.5][S01]前[1.0][0.1][S02]先[0.2]'),
    );
    final MossRunner runner = MossRunner(
      cliPath: 'audiocpp_cli',
      modelPath: _model(tmp),
      backend: AudioCppBackend.vulkan,
      chunkSeconds: 30,
      instruct: '热词提示：澪',
      startProcess: cli.start,
    );
    final List<MossProgress> progress = <MossProgress>[];
    final Directory work = Directory(p.join(tmp.path, 'job'));
    final MossTranscript t = await runner.run(
      _signal(70, <(double, double)>[(28.0, 28.6)]),
      workDir: work,
      onProgress: progress.add,
    );
    // 30 ± 60 的搜索窗覆盖整段，最低点在 28.2；58.2 ≥ 70 − 12 不再切。
    expect(t.chunkEdgesSeconds, <Object>[0, closeTo(28.2, 1e-9), 70]);
    expect(t.chunkCount, 2);
    expect(t.splitCount, 0);
    expect(cli.calls, hasLength(2));
    final StartedCall first = cli.calls.first;
    expect(first.executable, 'audiocpp_cli');
    expect(first.arg('--task'), 'asr');
    expect(first.arg('--family'), 'moss_transcribe_diarize');
    expect(first.arg('--backend'), 'vulkan');
    expect(first.arg('--threads'), '8');
    expect(first.arg('--request-option'), 'max_tokens=8192');
    expect(first.arg('--instruct'), '热词提示：澪');
    // 排序：块内 0.1 的「先」排在 0.5 的「前」前面；第二块整体在后。
    expect(<String>[for (final MossCue c in t.cues) '${c.startMs}:${c.text}'],
        <String>['100:先', '500:前', '28300:先', '28700:前']);
    expect(t.cues.first.speaker, '1:S02');
    expect(t.cues.last.speaker, '2:S01');
    // 进度：0 起步，单调，收尾等于总时长。
    expect(progress.first.processedSeconds, 0);
    expect(progress.last.processedSeconds, closeTo(70, 1e-9));
    expect(progress.last.completedChunks, 2);
    // 只剩缓存，wav / txt / seg 都删了。
    final List<String> left = work
        .listSync()
        .map((FileSystemEntity e) => p.basename(e.path))
        .toList()
      ..sort();
    expect(left, <String>['moss_0_451200.json', 'moss_451200_1120000.json']);
  });

  test('撞 max_tokens 的长块在块内最安静处二分后重跑', () async {
    final _FakeCli cli = _FakeCli((double s) => s > 60
        ? (1, 'error: generation hit max_tokens (8192)', '')
        : (0, '', '[0.0][S01]x[1.0]'));
    final MossRunner runner = MossRunner(
      cliPath: 'cli',
      modelPath: _model(tmp),
      chunkSeconds: 300,
      startProcess: cli.start,
    );
    // 80 s 一块（不足以切），撞上限 → 在 50.2 处二分。
    final MossTranscript t = await runner.run(
      _signal(80, <(double, double)>[(50.0, 50.6)]),
      workDir: Directory(p.join(tmp.path, 'job')),
    );
    expect(t.splitCount, 1);
    expect(t.chunkCount, 1);
    expect(cli.calls, hasLength(3));
    expect(<int>[for (final MossCue c in t.cues) c.startMs], <int>[0, 50200]);
    // 块序号按执行次数计：失败的那次是 1，两半是 2、3（与原型 ci 同口径）。
    expect(<String>[for (final MossCue c in t.cues) c.speaker],
        <String>['2:S01', '3:S01']);
  });

  test('撞 max_tokens 但块不够长：当真错误抛出，带 stderr 尾部', () async {
    final String longErr = '${'x' * 2000}max_tokens TAIL';
    final _FakeCli cli = _FakeCli((double s) => (1, longErr, ''));
    final MossRunner runner = MossRunner(
      cliPath: 'cli',
      modelPath: _model(tmp),
      startProcess: cli.start,
    );
    await expectLater(
      runner.run(_signal(30, const <(double, double)>[]),
          workDir: Directory(p.join(tmp.path, 'job'))),
      throwsA(isA<MossRunException>()
          .having((MossRunException e) => e.stderrTail.length, 'tail', 800)
          .having((MossRunException e) => e.stderrTail, 'text',
              endsWith('max_tokens TAIL'))
          .having((MossRunException e) => e.exitCode, 'exit', 1)),
    );
  });

  test('其它非零退出直接抛出', () async {
    final _FakeCli cli =
        _FakeCli((double s) => (3, 'CUDA error: out of memory', ''));
    final MossRunner runner = MossRunner(
      cliPath: 'cli',
      modelPath: _model(tmp),
      startProcess: cli.start,
    );
    await expectLater(
      runner.run(_signal(100, const <(double, double)>[]),
          workDir: Directory(p.join(tmp.path, 'job'))),
      throwsA(isA<MossRunException>().having(
          (MossRunException e) => e.stderrTail, 'tail', contains('CUDA'))),
    );
  });

  test('续跑：已完成的块（含二分决定）读缓存不重跑', () async {
    final Float32List pcm = _signal(80, <(double, double)>[(50.0, 50.6)]);
    final Directory work = Directory(p.join(tmp.path, 'job'));
    final String model = _model(tmp);
    final _FakeCli cli = _FakeCli((double s) =>
        s > 60 ? (1, 'max_tokens', '') : (0, '', '[0.0][S01]x[1.0]'));
    final MossTranscript a = await MossRunner(
      cliPath: 'cli',
      modelPath: model,
      startProcess: cli.start,
    ).run(pcm, workDir: work);

    final MossTranscript b = await MossRunner(
      cliPath: 'cli',
      modelPath: model,
      startProcess: (String e, List<String> args) => fail('续跑不应再起进程：$args'),
    ).run(pcm, workDir: work);
    expect(b.splitCount, a.splitCount);
    expect(<String>[for (final MossCue c in b.cues) c.toString()],
        <String>[for (final MossCue c in a.cues) c.toString()]);
  });

  test('参数变了（instruct）缓存作废、重跑', () async {
    final Float32List pcm = _signal(20, const <(double, double)>[]);
    final Directory work = Directory(p.join(tmp.path, 'job'));
    final String model = _model(tmp);
    final _FakeCli cli = _FakeCli((double s) => (0, '', '[0][S01]x[1]'));
    await MossRunner(cliPath: 'cli', modelPath: model, startProcess: cli.start)
        .run(pcm, workDir: work);
    await MossRunner(
      cliPath: 'cli',
      modelPath: model,
      instruct: '别的指令',
      startProcess: cli.start,
    ).run(pcm, workDir: work);
    expect(cli.calls, hasLength(2));
  });

  test('空音频：直接返回空结果，不起 CLI', () async {
    final List<MossProgress> progress = <MossProgress>[];
    final MossTranscript t = await MossRunner(
      cliPath: 'cli',
      modelPath: _model(tmp),
      backend: AudioCppBackend.cuda,
      startProcess: (String e, List<String> args) => fail('不应起进程：$args'),
    ).run(
      Float32List(0),
      workDir: Directory(p.join(tmp.path, 'job')),
      onProgress: progress.add,
    );
    expect(t.cues, isEmpty);
    expect(t.chunkCount, 0);
    expect(t.splitCount, 0);
    expect(t.audioSeconds, 0);
    expect(progress.single.fraction, 1);
  });

  group('后端与设备', () {
    test('CUDA 不传 device：按 CLI 枚举选序号最小的达标卡（不是 0 号卡），只探一次', () async {
      final _FakeCli cli = _FakeCli((double s) => (0, '', '[0][S01]x[1]'));
      await MossRunner(
        cliPath: 'cli',
        modelPath: _model(tmp),
        backend: AudioCppBackend.cuda,
        chunkSeconds: 30,
        startProcess: cli.start,
      ).run(
        _signal(70, <(double, double)>[(28.0, 28.6)]),
        workDir: Directory(p.join(tmp.path, 'job')),
      );
      expect(cli.listCalls, hasLength(1));
      expect(cli.listCalls.single.arguments, <String>['--list-devices']);
      expect(cli.calls, hasLength(2));
      for (final StartedCall c in cli.calls) {
        expect(c.arg('--backend'), 'cuda');
        expect(c.arg('--device'), '1');
      }
    });

    test('CUDA 卡都不达标：抛 MossRunException，不跑块', () async {
      final _FakeCli cli = _FakeCli(
        (double s) => (0, '', '[0][S01]x[1]'),
        listDevicesStderr:
            '  Device 0: Quadro P4000, compute capability 6.1, VMM: yes\n',
      );
      await expectLater(
        MossRunner(
          cliPath: 'cli',
          modelPath: _model(tmp),
          backend: AudioCppBackend.cuda,
          startProcess: cli.start,
        ).run(_signal(20, const <(double, double)>[]),
            workDir: Directory(p.join(tmp.path, 'job'))),
        throwsA(isA<MossRunException>().having(
            (MossRunException e) => e.message, 'message', contains('7.5'))),
      );
      expect(cli.calls, isEmpty);
    });

    test('CUDA 枚举不到任何设备：抛 MossRunException', () async {
      final _FakeCli cli = _FakeCli(
        (double s) => (0, '', '[0][S01]x[1]'),
        listDevicesStderr: '',
      );
      await expectLater(
        MossRunner(
          cliPath: 'cli',
          modelPath: _model(tmp),
          backend: AudioCppBackend.cuda,
          startProcess: cli.start,
        ).run(_signal(20, const <(double, double)>[]),
            workDir: Directory(p.join(tmp.path, 'job'))),
        throwsA(isA<MossRunException>()),
      );
      expect(cli.calls, isEmpty);
    });

    test('显式 device：原样传，不枚举', () async {
      final _FakeCli cli = _FakeCli((double s) => (0, '', '[0][S01]x[1]'));
      await MossRunner(
        cliPath: 'cli',
        modelPath: _model(tmp),
        backend: AudioCppBackend.cuda,
        device: 0,
        startProcess: cli.start,
      ).run(_signal(20, const <(double, double)>[]),
          workDir: Directory(p.join(tmp.path, 'job')));
      expect(cli.listCalls, isEmpty);
      expect(cli.calls.single.arg('--device'), '0');
    });

    test('非 CUDA 后端：不枚举、不传 --device', () async {
      final _FakeCli cli = _FakeCli((double s) => (0, '', '[0][S01]x[1]'));
      await MossRunner(
        cliPath: 'cli',
        modelPath: _model(tmp),
        backend: AudioCppBackend.vulkan,
        startProcess: cli.start,
      ).run(_signal(20, const <(double, double)>[]),
          workDir: Directory(p.join(tmp.path, 'job')));
      expect(cli.listCalls, isEmpty);
      expect(cli.calls.single.arguments, isNot(contains('--device')));
    });

    test('不传 backend：按清单取当前平台实际有 CLI 的后端', () {
      final MossRunner runner =
          MossRunner(cliPath: 'cli', modelPath: _model(tmp));
      expect(runner.backend, defaultMossBackendFor(currentAudioCppPlatform()));
      if (Platform.isLinux) {
        expect(runner.backend, AudioCppBackend.vulkan);
      }
    });

    test('forRuntime：CLI 与后端都跟着运行库走', () {
      final AudioCppRuntimePack pack = audioCppRuntimePackFor(
          AudioCppPlatform.linuxX64, AudioCppBackend.vulkan)!;
      final AudioCppRuntimeStore store =
          AudioCppRuntimeStore(Directory(p.join(tmp.path, 'rt')), pack);
      final MossRunner runner =
          MossRunner.forRuntime(store, modelPath: _model(tmp));
      expect(runner.backend, AudioCppBackend.vulkan);
      expect(runner.cliPath, store.executable.path);
    });
  });

  test('取消：杀掉正在跑的子进程并抛 AsrCancelledException', () async {
    final AsrCancellationToken token = AsrCancellationToken();
    FakeProcess? running;
    final Directory work = Directory(p.join(tmp.path, 'job'));
    final Future<MossTranscript> future = MossRunner(
      cliPath: 'cli',
      modelPath: _model(tmp),
      startProcess: (String e, List<String> args) async {
        running = FakeProcess(hang: true);
        scheduleMicrotask(token.cancel);
        return running!;
      },
    ).run(_signal(20, const <(double, double)>[]),
        workDir: work, cancellation: token);
    await expectLater(future, throwsA(isA<AsrCancelledException>()));
    expect(running!.killed, isTrue);
    // 取消后不留临时 wav，也不写缓存。
    expect(work.listSync(), isEmpty);
  });
}
