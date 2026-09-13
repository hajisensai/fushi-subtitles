/// `fushi_asr_core` 的纯 Dart ONNX Runtime 后端。
///
/// 给没有 Flutter 引擎的宿主用（CLI / 服务端）。装配：
///
/// ```dart
/// final service = AsrTranscriptionService(
///   backend: const AsrIsolateBackend(buildFactory: buildFfiOnnxFactory),
///   // 对素材的断言，没有默认值：混音素材（动画/影视）用 mixedAudio，
///   // 干净朗读（有声书/口述）才用 cleanSpeech。见 AsrAudioProfile。
///   audioProfile: AsrAudioProfile.mixedAudio,
/// );
/// ```
///
/// 动态库解析顺序：`ASR_ONNXRUNTIME_LIB` > 按需下载的托管副本 > 可执行文件同级
/// > 系统搜索路径。Windows 上缺库时 `ensureOrtRuntime()` 会按需下载（见
/// `src/ort_provisioning.dart`）。
library;

export 'src/reusing_onnx_session_factory.dart' show ReusingOnnxSessionFactory;

export 'src/ffi_onnx_session.dart' show FfiOnnxSession;
export 'src/ffi_onnx_session_factory.dart'
    show FfiOnnxSessionFactory, buildFfiOnnxFactory;
export 'src/directml_runtime.dart'
    show DirectMlResolution, DirectMlRuntime, kDirectMlRequiredVersion;
export 'src/ort_runtime.dart'
    show
        OrtException,
        OrtRuntime,
        OrtRuntimeUnavailable,
        kOrtApiVersion,
        readNativeCString;
export 'src/ort_provisioning.dart'
    show
        OrtProvisionCorrupt,
        OrtProvisionUnsupported,
        adoptOrtManagedRuntimeDir,
        ensureOrtRuntime,
        extractOrtNative,
        findUsableOrtRuntime,
        kOrtPackageVersion,
        ortPackageUrl,
        ortRuntimeIdentifier,
        resolveOrtManagedDir,
        verifyOrtPackage;
