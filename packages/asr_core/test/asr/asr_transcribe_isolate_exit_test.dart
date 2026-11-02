import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:test/test.dart';

/// 后台转录 isolate 收尾后必须真的退出，哪怕宿主 bootstrap 在里面留了一个
/// 永不关闭的端口。
///
/// 真实场景：Flutter 宿主在 bootstrap 里挂 `BackgroundIsolateBinaryMessenger`
/// （method channel 后端必需），它持有一个没有公开关闭方法的 `RawReceivePort`。
/// 只靠「关掉自己的端口、等事件循环空」退出时，这个端口让 isolate 永远活着：
/// 每转录一次漏一个 isolate（Fushi BUG-3993）。

OnnxSessionFactory _failingFactory() =>
    throw UnimplementedError('本用例只验 isolate 收尾，不装引擎');

/// 模拟宿主 bootstrap：留一个永不关闭的端口，并把本 isolate 交给测试挂退出监听。
void _leakyBootstrap(Object arg) {
  final SendPort reportTo = arg as SendPort;
  // 故意不关：等同 BackgroundIsolateBinaryMessenger 的常驻端口。
  RawReceivePort((Object? _) {});
  reportTo.send(Isolate.current);
}

class _NoPcm implements AsrPcmSource {
  @override
  Future<int?> probeDurationMs(String audioPath) async => null;

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) =>
      const Stream<AsrPcmChunk>.empty();
}

void main() {
  test('isolate exits after the job ends even with a host port left open',
      () async {
    final Directory tmp = await Directory.systemTemp.createTemp('asr_exit_');
    addTearDown(() => tmp.delete(recursive: true));

    final ReceivePort isolates = ReceivePort();
    final ReceivePort exits = ReceivePort();
    addTearDown(isolates.close);
    addTearDown(exits.close);
    final Completer<void> exited = Completer<void>();
    exits.listen((_) {
      if (!exited.isCompleted) exited.complete();
    });
    isolates.listen((Object? message) {
      // 监听挂上之前 isolate 若已退出，addOnExitListener 会立即回发。
      (message! as Isolate).addOnExitListener(exits.sendPort);
    });

    final AsrModelPack pack = asrModelPackFor(AsrLanguage.japanese);
    final Future<AsrIsolateTranscription> spawned =
        AsrIsolateTranscription.spawn(
      AsrIsolateJobSpec(
        storeDirPath: tmp.path,
        pack: pack,
        language: AsrLanguage.japanese,
        variant: AsrEncoderVariant.int8,
        preference: AsrAccelerationPreference.cpuOnly,
        audioPaths: const <String>[],
        jobDirPath: tmp.path,
        chunkSeconds: 600,
        audioProfile: AsrAudioProfile.values.first,
      ),
      pcm: _NoPcm(),
      backend: AsrIsolateBackend(
        buildFactory: _failingFactory,
        bootstrap: _leakyBootstrap,
        bootstrapArg: isolates.sendPort,
      ),
    );
    await expectLater(spawned, throwsA(isA<StateError>()));

    await exited.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('转录 isolate 收尾后没有退出（被宿主端口挂住）'),
    );
  });
}
