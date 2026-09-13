/// `OnnxSessionFactory` 的 dart:ffi 实现（CLI / 服务端用）。
library;

import 'dart:developer' as developer;
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:ffi/ffi.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_asr_onnx_ffi/src/directml_runtime.dart';
import 'package:fushi_asr_onnx_ffi/src/ffi/onnxruntime_bindings.dart';
import 'package:fushi_asr_onnx_ffi/src/ort_runtime.dart';
import 'package:fushi_asr_onnx_ffi/src/ffi_onnx_session.dart';
import 'macos_session_tuning.dart';
import 'coreml_specialization.dart';

/// `OrtDmlApi` 的手写绑定。
///
/// 为什么手写：ORT 的 `dml_provider_factory.h` 顶部 `#include <d3d12.h>` /
/// `<DirectML.h>`，还在 `__cplusplus` 分支里定义 `operator|` 重载，不是合法的
/// ffigen 输入。这里只需要该结构体的**第一个成员**，手写一条比把整个 Windows SDK
/// 拖进绑定生成划算得多。
///
/// 顺序必须与上游头文件一致（`SessionOptionsAppendExecutionProvider_DML` 是第一
/// 个成员，后面是 DML1 / CreateGPUAllocationFromD3DResource / …），取错就是调到
/// 别的函数上。
// ignore: non_constant_identifier_names —— 成员名必须与 C 头文件一致
final class OrtDmlApi extends Struct {
  external Pointer<
      NativeFunction<
          Pointer<OrtStatus> Function(
            Pointer<OrtSessionOptions> options,
            Int device_id,
          )>> SessionOptionsAppendExecutionProvider_DML;
}

/// 纯 Dart 的 ONNX 会话工厂。
///
/// 与 Flutter 插件后端实现同一个接口，装配点唯一：
/// `AsrEngineLoader(factory: FfiOnnxSessionFactory())`。
class FfiOnnxSessionFactory implements OnnxSessionFactory {
  FfiOnnxSessionFactory({
    this.logName = kOnnxLogName,
    this.libraryPathOverride,
    this.deviceId = 0,
    this.coreMlBasicOptimizations = false,
    this.coreMlRequireStaticInputShapes = true,
  });

  final String logName;

  /// 显式指定 onnxruntime 动态库（测试 / 特殊部署）；null 走
  /// [OrtRuntime.resolveLibraryCandidates]。
  final String? libraryPathOverride;

  /// GPU EP 的设备序号。
  final int deviceId;

  /// Diagnostic A/B switch. Applies only to macOS CoreML sessions.
  final bool coreMlBasicOptimizations;
  final bool coreMlRequireStaticInputShapes;
  bool get _staticCoreMlInputs =>
      Platform.environment.containsKey('ASR_COREML_STATIC_INPUTS')
          ? Platform.environment['ASR_COREML_STATIC_INPUTS'] == '1'
          : coreMlRequireStaticInputShapes;
  String get _coreMlComputeUnits {
    final value = Platform.environment['ASR_COREML_COMPUTE_UNITS'] ?? 'ALL';
    if (!{'ALL', 'CPUOnly', 'CPUAndGPU', 'CPUAndNeuralEngine'}
        .contains(value)) {
      throw ArgumentError('Unsupported ASR_COREML_COMPUTE_UNITS: $value');
    }
    return value;
  }

  CoreMlSpecialization get _coreMlSpecialization =>
      CoreMlSpecialization.resolve(Platform.environment);

  OrtRuntime get _runtime =>
      OrtRuntime.instance(libraryPathOverride: libraryPathOverride);

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    final File file = File(modelPath);
    if (!file.existsSync()) {
      throw FileSystemException('模型文件不存在', modelPath);
    }
    final Uint8List bytes = await file.readAsBytes();
    String? coreMlCache;
    if (providers.contains(OnnxExecutionProvider.coreml) && Platform.isMacOS) {
      final root = await asrSupportRootDirectory();
      // ORT's in-memory graph hash omits weights. Namespace by actual model
      // bytes, runtime version and shape overrides to prevent stale reuse.
      final shapes = (freeDimensionOverrides?.entries.toList() ?? [])
        ..sort((a, b) => a.key.compareTo(b.key));
      coreMlCache = p.join(
          root.path,
          'coreml_cache',
          _runtime.versionString,
          '${coreMlBasicOptimizations ? 'basic' : 'all'}'
              '${_staticCoreMlInputs ? '-static-inputs-only' : ''}'
              '${_coreMlComputeUnits == 'ALL' ? '' : '-$_coreMlComputeUnits'}'
              '${_coreMlSpecialization.cacheSuffix}',
          sha256.convert(bytes).toString(),
          shapes.isEmpty
              ? 'dynamic'
              : sha256
                  .convert(utf8.encode(
                      shapes.map((e) => '${e.key}=${e.value}').join(';')))
                  .toString());
      await Directory(coreMlCache).create(recursive: true);
    }
    return createOnnxSessionWithProviderFallback<OnnxSession>(
      providers: providers,
      onResolved: onProviderResolved,
      logName: logName,
      create: (List<OnnxExecutionProvider> effective) async => _create(
        bytes,
        effective,
        intraOpNumThreads: intraOpNumThreads,
        freeDimensionOverrides: freeDimensionOverrides,
        coreMlCache: coreMlCache,
      ),
    );
  }

  OnnxSession _create(
    Uint8List bytes,
    List<OnnxExecutionProvider> providers, {
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
    String? coreMlCache,
  }) {
    final OrtRuntime runtime = _runtime;
    final Pointer<OrtApi> api = runtime.api;
    final Pointer<Pointer<OrtSessionOptions>> optionsOut =
        calloc<Pointer<OrtSessionOptions>>();
    Pointer<OrtSessionOptions> options = nullptr;
    try {
      checkOrtStatus(
        api,
        api.ref.CreateSessionOptions.asFunction<
            Pointer<OrtStatus> Function(Pointer<Pointer<OrtSessionOptions>>)>()(
          optionsOut,
        ),
      );
      options = optionsOut.value;

      final preferred =
          providers.isEmpty ? OnnxExecutionProvider.cpu : providers.first;
      final tuning = MacOsSessionTuning.resolve(
          isMacOS: Platform.isMacOS,
          environment: Platform.environment,
          provider: preferred,
          callerThreads: intraOpNumThreads);
      intraOpNumThreads = tuning.threads;
      for (final entry in tuning.entries.entries) {
        using((arena) {
          checkOrtStatus(
              api,
              api.ref.AddSessionConfigEntry.asFunction<
                      Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>,
                          Pointer<Char>, Pointer<Char>)>()(
                  options,
                  entry.key.toNativeUtf8(allocator: arena).cast<Char>(),
                  entry.value.toNativeUtf8(allocator: arena).cast<Char>()));
        });
      }

      if (intraOpNumThreads != null) {
        checkOrtStatus(
          api,
          api.ref.SetIntraOpNumThreads.asFunction<
              Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>,
                  int)>()(options, intraOpNumThreads),
        );
      }

      // 固定 shape：ORT 能在建会话时把整图融合 / 编译一次，而不是每次 run 重新
      // 规划。DirectML 上 zipformer 编码器吞吐 5~7 倍。
      //
      // **必须是 ByName**：`AddFreeDimensionOverride` 匹配的是 ONNX 的
      // `denotation`（DATA_BATCH 那类标准语义标签），`...ByName` 匹配的才是
      // `dim_param`（Netron 里看到的 `N` / `T`）。PyTorch 导出器基本不填
      // denotation，调错那个**既不报错也不生效**，只是悄悄慢 5~7 倍。
      final Map<String, int>? overrides = freeDimensionOverrides;
      if (overrides != null) {
        for (final MapEntry<String, int> e in overrides.entries) {
          final Pointer<Utf8> name = e.key.toNativeUtf8();
          try {
            checkOrtStatus(
              api,
              api.ref.AddFreeDimensionOverrideByName.asFunction<
                  Pointer<OrtStatus> Function(
                      Pointer<OrtSessionOptions>,
                      Pointer<Char>,
                      int)>()(options, name.cast<Char>(), e.value),
            );
          } finally {
            calloc.free(name);
          }
        }
      }

      if (preferred == OnnxExecutionProvider.coreml &&
          Platform.isMacOS &&
          coreMlBasicOptimizations) {
        checkOrtStatus(
            api,
            api.ref.SetSessionGraphOptimizationLevel.asFunction<
                    Pointer<OrtStatus> Function(
                        Pointer<OrtSessionOptions>, int)>()(
                options, GraphOptimizationLevel.ORT_ENABLE_BASIC.value));
      }
      // DirectML：先把我们选中的 DirectML.dll 装进进程，ORT 之后按裸名加载拿到
      // 的就是它，而不是 System32 里 Windows 10 自带的 1.0（见 directml_runtime.dart）。
      final DirectMlResolution? dml =
          preferred == OnnxExecutionProvider.directml
              ? DirectMlRuntime.ensureLoaded()
              : null;
      try {
        _appendProvider(api, options, preferred, coreMlCache: coreMlCache);
      } on OrtException catch (error) {
        throw _withDirectMlHint(error, dml);
      }

      final profileDir = Platform.environment['ASR_ORT_PROFILE_DIR'];
      final profile = preferred == OnnxExecutionProvider.coreml &&
          Platform.isMacOS &&
          profileDir != null &&
          profileDir.isNotEmpty;
      if (profile) {
        Directory(profileDir).createSync(recursive: true);
        final prefix = p
            .join(profileDir,
                'coreml-$pid-${DateTime.now().microsecondsSinceEpoch}')
            .toNativeUtf8();
        try {
          // ORTCHAR_T is char on macOS; generated Windows bindings use WChar.
          checkOrtStatus(
              api,
              api.ref.EnableProfiling
                  .cast<
                      NativeFunction<
                          Pointer<OrtStatus> Function(
                              Pointer<OrtSessionOptions>, Pointer<Char>)>>()
                  .asFunction<
                      Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>,
                          Pointer<Char>)>()(options, prefix.cast<Char>()));
        } finally {
          calloc.free(prefix);
        }
      }

      try {
        return FfiOnnxSession.create(runtime, bytes, options,
            profiling: profile);
      } on OrtException catch (error) {
        throw _withDirectMlHint(error, dml);
      }
    } finally {
      if (options != nullptr) {
        api.ref.ReleaseSessionOptions
            .asFunction<void Function(Pointer<OrtSessionOptions>)>()(options);
      }
      calloc.free(optionsOut);
    }
  }

  /// DML 建会话失败时把「用的是哪份 DirectML.dll、版本够不够」缀在 ORT 原话后面。
  /// ORT 自己的报错只有 HRESULT（`887A0004`），不会说是 DLL 太旧。
  static OrtException _withDirectMlHint(
      OrtException error, DirectMlResolution? dml) {
    if (dml == null) return error;
    return OrtException(error.code, '${error.message}；${dml.describe()}');
  }

  void _appendProvider(Pointer<OrtApi> api, Pointer<OrtSessionOptions> options,
      OnnxExecutionProvider provider,
      {String? coreMlCache}) {
    switch (provider) {
      case OnnxExecutionProvider.cpu:
        return; // CPU 是默认 EP，不需要 append。
      case OnnxExecutionProvider.directml:
        _appendDirectMl(api, options);
      case OnnxExecutionProvider.cuda:
        _appendCuda(api, options);
      case OnnxExecutionProvider.coreml:
        _appendCoreMl(api, options, coreMlCache);
    }
  }

  void _appendCoreMl(Pointer<OrtApi> api, Pointer<OrtSessionOptions> options,
      String? cacheDirectory) {
    if (!Platform.isMacOS) {
      throw UnsupportedError('CoreML FFI is currently supported on macOS only');
    }
    final values = <String, String>{
      'ModelFormat': 'MLProgram',
      'MLComputeUnits': _coreMlComputeUnits,
      'RequireStaticInputShapes': _staticCoreMlInputs ? '1' : '0',
      'EnableOnSubgraphs': '0',
      ..._coreMlSpecialization.providerOptions,
      if (cacheDirectory != null) 'ModelCacheDirectory': cacheDirectory,
    };
    using((arena) {
      final name = 'CoreML'.toNativeUtf8(allocator: arena);
      final keys = arena<Pointer<Char>>(values.length);
      final vals = arena<Pointer<Char>>(values.length);
      var i = 0;
      for (final entry in values.entries) {
        keys[i] = entry.key.toNativeUtf8(allocator: arena).cast<Char>();
        vals[i] = entry.value.toNativeUtf8(allocator: arena).cast<Char>();
        i++;
      }
      checkOrtStatus(
          api,
          api.ref.SessionOptionsAppendExecutionProvider.asFunction<
                  Pointer<OrtStatus> Function(
                      Pointer<OrtSessionOptions>,
                      Pointer<Char>,
                      Pointer<Pointer<Char>>,
                      Pointer<Pointer<Char>>,
                      int)>()(
              options, name.cast<Char>(), keys, vals, values.length));
    });
  }

  void _appendDirectMl(
    Pointer<OrtApi> api,
    Pointer<OrtSessionOptions> options,
  ) {
    // DirectML 与其它 EP 不同，不能用通用的
    // `SessionOptionsAppendExecutionProvider(name, ...)`——那个函数只认
    // QNN / OpenVINO / XNNPACK / WebNN / WebGpu / Azure / Js / VitisAI / CoreML，
    // 喂 "DML" 进去会失败（有的实现还会把错误吞掉，表现为静默回落 CPU）。
    // 正路是取 OrtDmlApi 再调它的成员。
    final Pointer<Pointer<Void>> apiOut = calloc<Pointer<Void>>();
    final Pointer<Utf8> name = 'DML'.toNativeUtf8();
    try {
      checkOrtStatus(
        api,
        api.ref.GetExecutionProviderApi.asFunction<
                Pointer<OrtStatus> Function(
                    Pointer<Char>, int, Pointer<Pointer<Void>>)>()(
            name.cast<Char>(), kOrtApiVersion, apiOut),
      );
      final Pointer<OrtDmlApi> dml = apiOut.value.cast<OrtDmlApi>();
      if (dml == nullptr) {
        throw OrtException(1, '这份 onnxruntime 没有编译进 DirectML EP');
      }
      // DML 要求：关内存复用模式 + 顺序执行。少任何一条都会在真跑时出问题。
      checkOrtStatus(
        api,
        api.ref.SetSessionExecutionMode.asFunction<
            Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>, int)>()(
          options,
          ExecutionMode.ORT_SEQUENTIAL.value,
        ),
      );
      checkOrtStatus(
        api,
        api.ref.DisableMemPattern.asFunction<
            Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>)>()(options),
      );
      checkOrtStatus(
        api,
        dml.ref.SessionOptionsAppendExecutionProvider_DML.asFunction<
            Pointer<OrtStatus> Function(
                Pointer<OrtSessionOptions>, int)>()(options, deviceId),
      );
    } finally {
      calloc.free(name);
      calloc.free(apiOut);
    }
  }

  void _appendCuda(
    Pointer<OrtApi> api,
    Pointer<OrtSessionOptions> options,
  ) {
    checkOrtStatus(
      api,
      api.ref.SessionOptionsAppendExecutionProvider_CUDA_V2.asFunction<
          Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>,
              Pointer<OrtCUDAProviderOptionsV2>)>()(options, _cudaOptions(api)),
    );
  }

  Pointer<OrtCUDAProviderOptionsV2> _cudaOptions(Pointer<OrtApi> api) {
    final Pointer<Pointer<OrtCUDAProviderOptionsV2>> out =
        calloc<Pointer<OrtCUDAProviderOptionsV2>>();
    try {
      checkOrtStatus(
        api,
        api.ref.CreateCUDAProviderOptions.asFunction<
            Pointer<OrtStatus> Function(
                Pointer<Pointer<OrtCUDAProviderOptionsV2>>)>()(out),
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  @override
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() async {
    final Pointer<OrtApi> api = _runtime.api;
    final Pointer<Pointer<Pointer<Char>>> listOut =
        calloc<Pointer<Pointer<Char>>>();
    final Pointer<Int> countOut = calloc<Int>();
    try {
      checkOrtStatus(
        api,
        api.ref.GetAvailableProviders.asFunction<
            Pointer<OrtStatus> Function(Pointer<Pointer<Pointer<Char>>>,
                Pointer<Int>)>()(listOut, countOut),
      );
      final Pointer<Pointer<Char>> list = listOut.value;
      final int count = countOut.value;
      final Set<OnnxExecutionProvider> out = <OnnxExecutionProvider>{};
      for (int i = 0; i < count; i++) {
        final String name = list[i].cast<Utf8>().toDartString();
        final OnnxExecutionProvider? mapped = switch (name) {
          'DmlExecutionProvider' => OnnxExecutionProvider.directml,
          'CUDAExecutionProvider' => OnnxExecutionProvider.cuda,
          'CoreMLExecutionProvider' => OnnxExecutionProvider.coreml,
          _ => null,
        };
        if (mapped != null) out.add(mapped);
      }
      api.ref.ReleaseAvailableProviders.asFunction<
          Pointer<OrtStatus> Function(Pointer<Pointer<Char>>, int)>()(
        list,
        count,
      );
      return out;
    } finally {
      calloc.free(listOut);
      calloc.free(countOut);
    }
  }

  /// GPU 显存预算。
  ///
  /// **当前一律返回 null（= 未知）**，不是 0、也不是瞎猜一个数。上游那份实现走的
  /// 是 Windows DXGI 的 `QueryVideoMemoryInfo`（COM 接口），从 dart:ffi 调要手写
  /// 一串 vtable 调用，还没接。
  ///
  /// 返回未知是**安全的一侧**：核心层拿 null 时按保守桶表建静态桶
  /// （`asr_encoder_buckets.dart`），只是吞吐不如按真实显存开大的那档，不会因为
  /// 桶太大把显存撑爆。这条降级是显式可观测的，不是静默的。
  @override
  Future<int?> deviceMemoryBudgetBytes() async {
    developer.log(
      'FFI 后端暂不查询 GPU 显存预算，按未知处理（静态桶走保守表）',
      name: logName,
    );
    return null;
  }
}

/// 顶层工厂构造函数：给 `AsrIsolateBackend.buildFactory` 用。
///
/// **必须是顶层函数**——它要跨 isolate 边界发送，闭包过不去。
OnnxSessionFactory buildFfiOnnxFactory() =>
    FfiOnnxSessionFactory(logName: kAsrLogName);
