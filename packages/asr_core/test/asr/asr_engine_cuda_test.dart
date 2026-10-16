import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_asr_core/src/asr/asr_engine.dart';
import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_model_store.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';

/// Windows 上 DirectML / CUDA 都是显式可选，「自动」CUDA 优先；CUDA 建会话成功但
/// 第一次 Run 才失败（cuDNN 缺失）时装载自检把它退掉、记下原因。

/// 假 CTC 会话：`x[N, S]` → 全 blank 的 `logits[N, S/320, 6]`；[failRun] 时每次
/// run 都抛（模拟 cuDNN 缺失时 Conv 才报错）。
class _Session implements OnnxSession {
  _Session(this.providers, {this.failRun = false});
  final List<OnnxExecutionProvider> providers;
  final bool failRun;
  bool closed = false;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    if (failRun) throw StateError('CUDNN_STATUS_NOT_INITIALIZED');
    final OnnxTensor x = inputs[AsrModelIo.ctcInputX]!;
    final int rows = x.shape[0];
    final int frames = x.shape[1] ~/ 320;
    return <String, OnnxTensor>{
      AsrModelIo.ctcOutputLogits: OnnxTensor.float32(
        Float32List(rows * frames * 6),
        <int>[rows, frames, 6],
      ),
    };
  }

  @override
  Future<void> close() async => closed = true;
}

class _Factory implements OnnxSessionFactory {
  _Factory(this.available, {this.cudaRunFails = false});
  final Set<OnnxExecutionProvider> available;
  final bool cudaRunFails;
  final List<_Session> sessions = <_Session>[];

  @override
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() async =>
      available;

  @override
  Future<int?> deviceMemoryBudgetBytes() async => null;

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    onProviderResolved?.call(
      OnnxProviderResolution(requested: providers, effective: providers.first),
    );
    final _Session s = _Session(
      List<OnnxExecutionProvider>.from(providers),
      failRun: cudaRunFails && providers.first == OnnxExecutionProvider.cuda,
    );
    sessions.add(s);
    return s;
  }
}

void main() {
  const Set<OnnxExecutionProvider> both = <OnnxExecutionProvider>{
    OnnxExecutionProvider.cuda,
    OnnxExecutionProvider.directml,
  };

  group('selectAsrEncoderProviders：Windows 的显式 GPU 档', () {
    List<OnnxExecutionProvider> pick(
      AsrAccelerationPreference preference, {
      Set<OnnxExecutionProvider> available = both,
      AsrPlatform platform = AsrPlatform.windows,
    }) =>
        selectAsrEncoderProviders(
          platform: platform,
          available: available,
          preference: preference,
          variant: AsrEncoderVariant.fp32,
        );

    test('自动：两者都在时 CUDA 优先，只有 DirectML 时用它', () {
      expect(pick(AsrAccelerationPreference.auto).first,
          OnnxExecutionProvider.cuda);
      expect(
        pick(
          AsrAccelerationPreference.auto,
          available: const <OnnxExecutionProvider>{
            OnnxExecutionProvider.directml,
          },
        ).first,
        OnnxExecutionProvider.directml,
      );
    });

    test('显式 DirectML：即使 CUDA 可用也用 DirectML（显卡老 / 想省显存的人）', () {
      expect(pick(AsrAccelerationPreference.directml), <OnnxExecutionProvider>[
        OnnxExecutionProvider.directml,
        OnnxExecutionProvider.cpu,
      ]);
    });

    test('显式 CUDA：可用就用', () {
      expect(pick(AsrAccelerationPreference.cuda), <OnnxExecutionProvider>[
        OnnxExecutionProvider.cuda,
        OnnxExecutionProvider.cpu,
      ]);
    });

    test('显式选了却不可用（运行库没装 / 非 Windows）：抛，不静默换别的', () {
      expect(
        () => pick(
          AsrAccelerationPreference.cuda,
          available: const <OnnxExecutionProvider>{
            OnnxExecutionProvider.directml,
          },
        ),
        throwsUnsupportedError,
      );
      expect(
        () => pick(
          AsrAccelerationPreference.directml,
          platform: AsrPlatform.linux,
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('装载自检', () {
    late Directory tmp;
    late AsrModelStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('asr_engine_cuda_');
      store = AsrModelStore(tmp, kAsrOmnilingualPack);
      for (final AsrModelFile f in kAsrOmnilingualPack.files) {
        if (f.role == AsrModelRole.tokens) {
          store.fileFor(f.role).writeAsStringSync(
                '<s> 0\n<pad> 1\n</s> 2\n<unk> 3\n  4\na 5\n',
              );
        } else {
          store.fileFor(f.role).writeAsBytesSync(<int>[1, 2, 3]);
        }
      }
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<AsrEngineSessions> load(
      _Factory f,
      AsrAccelerationPreference preference,
    ) =>
        AsrEngineLoader(factory: f, platform: AsrPlatform.windows).load(
          store: store,
          variant: AsrEncoderVariant.fp32,
          preference: preference,
          useStaticEncoderBuckets: false,
        );

    test('CUDA 能跑：留在 CUDA，没有降级原因', () async {
      final _Factory f = _Factory(both);
      final AsrEngineSessions s = await load(f, AsrAccelerationPreference.auto);
      expect(s.encoderResolution.effective, OnnxExecutionProvider.cuda);
      expect(s.encoderResolution.didFallBack, isFalse);
      await s.close();
    });

    for (final AsrAccelerationPreference pref in <AsrAccelerationPreference>[
      AsrAccelerationPreference.auto,
      AsrAccelerationPreference.cuda,
    ]) {
      test('CUDA 首次 Run 失败（${pref.name}）：关掉重装到 DirectML，原因可见', () async {
        final _Factory f = _Factory(both, cudaRunFails: true);
        final AsrEngineSessions s = await load(f, pref);
        expect(s.encoderResolution.effective, OnnxExecutionProvider.directml);
        expect(s.encoderResolution.fallbackReason,
            contains('CUDA health check failed'));
        expect(s.encoderResolution.requested.first, OnnxExecutionProvider.cuda);
        // 第一套（CUDA）会话全部关掉了，不留 native 泄漏。
        expect(
          f.sessions
              .where((_Session x) =>
                  x.providers.first == OnnxExecutionProvider.cuda)
              .every((_Session x) => x.closed),
          isTrue,
        );
        await s.close();
      });
    }

    test('CUDA 失败且没有 DirectML：退到 CPU', () async {
      final _Factory f = _Factory(
        const <OnnxExecutionProvider>{OnnxExecutionProvider.cuda},
        cudaRunFails: true,
      );
      final AsrEngineSessions s = await load(f, AsrAccelerationPreference.auto);
      expect(s.encoderResolution.effective, OnnxExecutionProvider.cpu);
      expect(s.encoderResolution.didFallBack, isTrue);
      await s.close();
    });
  });
}
