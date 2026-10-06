import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_asr_core/src/asr/asr_engine.dart';
import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_model_store.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_isolate.dart';
import 'package:fushi_asr_core/src/asr/asr_transcription_service.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';
import 'package:path/path.dart' as p;

/// 只覆盖 EP 探测：可让探测抛错（模拟有 GPU 的机器 ORT 探测本身失败）。
class _ProbeFactory implements OnnxSessionFactory {
  _ProbeFactory({this.error});

  /// 非 null 时探测抛它；null 时返回「没有加速 EP」（平台无关的确定结果）。
  final Error? error;
  int probeCalls = 0;

  @override
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() async {
    probeCalls++;
    final Error? e = error;
    if (e != null) throw e;
    return const <OnnxExecutionProvider>{};
  }

  @override
  Future<int?> deviceMemoryBudgetBytes() async => null;

  /// 本组用例只走 `plan()`，不建会话。真被调到说明用例走错了路径，直接炸。
  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async =>
      throw UnimplementedError('_ProbeFactory 只覆盖 EP 探测');
}

/// 进程内路径（`runInIsolate: false`）不会用到它——[AsrTranscriptionService] 的
/// `loader ?? AsrEngineLoader(factory: backend.buildFactory())` 只在没传 loader
/// 时求值。真被调到说明装配错了。
OnnxSessionFactory _unusedFactory() =>
    throw UnimplementedError('本用例不该在 isolate 里建后端');

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asr_service_test_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  AsrTranscriptionService service(_ProbeFactory factory) =>
      AsrTranscriptionService(
        audioProfile: AsrAudioProfile.cleanSpeech,
        backend: const AsrIsolateBackend(buildFactory: _unusedFactory),
        loader: AsrEngineLoader(factory: factory),
        openStore: (AsrLanguage l) async =>
            AsrModelStore(tmp, asrModelPackFor(l)),
        jobsRoot: () async => tmp,
        runInIsolate: false,
      );

  group('plan：EP 探测失败不吞（A5）', () {
    test('探测抛错 → 按 CPU 推荐 int8，且 probeError 带原因', () async {
      final _ProbeFactory factory = _ProbeFactory(
        error: StateError('DirectML.dll not found'),
      );
      final AsrTranscribePlan plan = await service(factory).plan(
        language: AsrLanguage.japanese,
        preference: AsrAccelerationPreference.auto,
      );
      expect(factory.probeCalls, 1);
      expect(plan.variant, AsrEncoderVariant.int8);
      expect(plan.expectedProvider, OnnxExecutionProvider.cpu);
      expect(plan.probeError, isNotNull);
      expect(plan.probeError, contains('DirectML.dll not found'));
    });

    test('探测正常（无加速 EP）→ probeError 为 null', () async {
      final _ProbeFactory factory = _ProbeFactory();
      final AsrTranscribePlan plan = await service(factory).plan(
        language: AsrLanguage.japanese,
        preference: AsrAccelerationPreference.auto,
      );
      expect(factory.probeCalls, 1);
      expect(plan.variant, AsrEncoderVariant.int8);
      expect(plan.probeError, isNull);
    });

    test('cpuOnly 不探测：即使探测会抛也不算探测失败', () async {
      final _ProbeFactory factory = _ProbeFactory(error: StateError('boom'));
      final AsrTranscribePlan plan = await service(factory).plan(
        language: AsrLanguage.english,
        preference: AsrAccelerationPreference.cpuOnly,
      );
      expect(factory.probeCalls, 0);
      expect(plan.variant, AsrEncoderVariant.int8);
      expect(plan.probeError, isNull);
      expect(plan.language, AsrLanguage.english);
    });
  });

  group('jobIdFor：文件名 + 字节数 + 模型包 id（A7 纯函数守卫）', () {
    File write(String dir, String name, int bytes) {
      final Directory d = Directory(p.join(tmp.path, dir))
        ..createSync(recursive: true);
      return File(p.join(d.path, name))
        ..writeAsBytesSync(List<int>.filled(bytes, 0x41));
    }

    test('同名同字节数、不同目录 → 同 id（与绝对路径无关）', () {
      final File a = write('a', '第01巻.m4b', 100);
      final File b = write('b', '第01巻.m4b', 100);
      final String ia = AsrTranscriptionService.jobIdFor(
        <String>[a.path],
        AsrLanguage.japanese,
      );
      final String ib = AsrTranscriptionService.jobIdFor(
        <String>[b.path],
        AsrLanguage.japanese,
      );
      expect(ia, isNotEmpty);
      expect(ia, ib);
      expect(ia, matches(RegExp(r'^[0-9a-f]{40}$')), reason: 'SHA-1 十六进制');
    });

    test('同名不同字节数 → 不同 id', () {
      final File a = write('a', 'x.m4b', 100);
      final File b = write('b', 'x.m4b', 101);
      expect(
        AsrTranscriptionService.jobIdFor(
            <String>[a.path], AsrLanguage.japanese),
        isNot(
          AsrTranscriptionService.jobIdFor(
            <String>[b.path],
            AsrLanguage.japanese,
          ),
        ),
      );
    });

    test('同一组文件换语言 → 不同 id（互不覆盖进度）', () {
      final File a = write('a', 'x.m4b', 100);
      expect(
        AsrTranscriptionService.jobIdFor(
            <String>[a.path], AsrLanguage.japanese),
        isNot(
          AsrTranscriptionService.jobIdFor(
            <String>[a.path],
            AsrLanguage.english,
          ),
        ),
      );
    });

    test('多文件顺序参与 id；不存在的文件按 0 字节计', () {
      final File a = write('a', 'x.m4b', 10);
      final File b = write('a', 'y.m4b', 10);
      final String ab = AsrTranscriptionService.jobIdFor(
        <String>[a.path, b.path],
        AsrLanguage.japanese,
      );
      final String ba = AsrTranscriptionService.jobIdFor(
        <String>[b.path, a.path],
        AsrLanguage.japanese,
      );
      expect(ab, isNot(ba));
      final String missing = AsrTranscriptionService.jobIdFor(
        <String>[p.join(tmp.path, 'nope', 'x.m4b')],
        AsrLanguage.japanese,
      );
      final File zero = write('z', 'x.m4b', 0);
      expect(
        AsrTranscriptionService.jobIdFor(
          <String>[zero.path],
          AsrLanguage.japanese,
        ),
        missing,
      );
    });
  });

  group('isAsrGeneratedSubtitlePath：同目录有 state.json 才算转录产物', () {
    test('transcript.srt + 旁边 state.json → true', () {
      final Directory job = Directory(p.join(tmp.path, 'job'))..createSync();
      final File srt = File(p.join(job.path, AsrJobFiles.srt))
        ..writeAsStringSync('');
      File(p.join(job.path, AsrJobFiles.state)).writeAsStringSync('{}');
      expect(
          AsrTranscriptionService.isAsrGeneratedSubtitlePath(srt.path), isTrue);
    });

    test('transcript.srt 没有 state.json → false', () {
      final Directory job = Directory(p.join(tmp.path, 'job'))..createSync();
      final File srt = File(p.join(job.path, AsrJobFiles.srt))
        ..writeAsStringSync('');
      expect(
        AsrTranscriptionService.isAsrGeneratedSubtitlePath(srt.path),
        isFalse,
      );
    });

    test('别的文件名即使旁边有 state.json → false', () {
      final Directory job = Directory(p.join(tmp.path, 'job'))..createSync();
      final File srt = File(p.join(job.path, 'user.srt'))
        ..writeAsStringSync('');
      File(p.join(job.path, AsrJobFiles.state)).writeAsStringSync('{}');
      expect(
        AsrTranscriptionService.isAsrGeneratedSubtitlePath(srt.path),
        isFalse,
      );
    });
  });

  group('existingState / finishedSrtPath 与任务加载同一个作废判据', () {
    Future<Directory> writeJob(
      AsrTranscriptionService svc,
      List<String> paths, {
      required String extra,
    }) async {
      final Directory dir =
          await svc.jobDirFor(paths, AsrLanguage.values.first);
      dir.createSync(recursive: true);
      File(p.join(dir.path, AsrJobFiles.srt)).writeAsStringSync('');
      File(p.join(dir.path, AsrJobFiles.state)).writeAsStringSync(
        '{"version":${AsrJobState.currentVersion},'
        '"audioPaths":["${paths.single}"],'
        '"modelId":"${asrModelPackFor(AsrLanguage.values.first).id}",'
        '"fileDurationsMs":[22257761],"resumeSamples":[-1],"finished":true'
        '$extra}',
      );
      return dir;
    }

    test('记了短于时长的解码终点 → 不报已完成（重转也不会复用它）', () async {
      final AsrTranscriptionService svc = service(_ProbeFactory());
      const List<String> paths = <String>['book.m4b'];
      await writeJob(svc, paths, extra: ',"decodedEndMs":[274830]');
      expect(await svc.existingState(paths, AsrLanguage.values.first), isNull);
      expect(
        await svc.finishedSrtPath(paths, AsrLanguage.values.first),
        isNull,
      );
    });

    test('旧任务没记解码终点 → 照常报已完成', () async {
      final AsrTranscriptionService svc = service(_ProbeFactory());
      const List<String> paths = <String>['book.m4b'];
      final Directory dir = await writeJob(svc, paths, extra: '');
      expect(
        (await svc.existingState(paths, AsrLanguage.values.first))?.finished,
        isTrue,
      );
      expect(
        await svc.finishedSrtPath(paths, AsrLanguage.values.first),
        p.join(dir.path, AsrJobFiles.srt),
      );
    });
  });
}
