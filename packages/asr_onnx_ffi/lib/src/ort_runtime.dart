/// ONNX Runtime 动态库的装载、`OrtApi` 取用与错误检查。
///
/// 进程内单例：`OrtEnv` 按 ORT 的契约每进程一个就够，而且建它不便宜。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_asr_onnx_ffi/src/ffi/onnxruntime_bindings.dart';

/// 本包生成绑定所依据的头文件版本对应的 API 版本号。
///
/// ORT 的 C ABI 是**严格尾部追加**的（1.22 → 1.29 删除 0 项、顺序改动 0 处），
/// 所以用这个版本号去问一个更新的 runtime 是安全的，拿回来的表前 322 项布局
/// 完全一致。反过来不成立：runtime 比它老会返回 **nullptr**（不是抛错），
/// 那种情况必须当场报出来而不是空指针崩在后面。
const int kOrtApiVersion = 22;

/// ORT 报错。
class OrtException implements Exception {
  OrtException(this.code, this.message);

  /// `OrtErrorCode`（1 = FAIL，2 = INVALID_ARGUMENT，…）。
  final int code;
  final String message;

  @override
  String toString() => 'OrtException($code): $message';
}

/// 装不出运行时（缺 DLL、缺 VC++ Redist、版本太老）。
class OrtRuntimeUnavailable implements Exception {
  OrtRuntimeUnavailable(this.message, {this.attempted = const <String>[]});

  final String message;

  /// 试过的库路径，按序。报错必须带上它——「找不到 onnxruntime」而不说找过哪里，
  /// 用户只能猜。
  final List<String> attempted;

  @override
  String toString() => attempted.isEmpty
      ? 'OrtRuntimeUnavailable: $message'
      : 'OrtRuntimeUnavailable: $message（试过：${attempted.join(" / ")}）';
}

/// 进程内唯一的 ORT 运行时句柄。
class OrtRuntime {
  OrtRuntime._(this.bindings, this.api, this.env, this.libraryPath);

  static OrtRuntime? _instance;

  final OnnxRuntimeBindings bindings;
  final Pointer<OrtApi> api;
  final Pointer<OrtEnv> env;

  /// 实际装上的库路径（诊断用）。
  final String libraryPath;

  /// 取（或首次建）进程内单例。
  ///
  /// [libraryPathOverride] 只给测试与特殊部署；生产走 [resolveLibraryCandidates]。
  static OrtRuntime instance({String? libraryPathOverride}) {
    final OrtRuntime? existing = _instance;
    if (existing != null) return existing;
    return _instance = _open(libraryPathOverride);
  }

  /// 本进程是否已经装上运行时。
  static bool get isLoaded => _instance != null;

  /// 释放 OrtEnv 并清掉单例；没装过时什么也不做。
  ///
  /// **进程退出前必须调一次**（所有会话先 close）。不调的话 env 一直活到 C++
  /// 静态析构阶段，而 libonnxruntime 里日志管理器的 mutex 先于它销毁，env 析构
  /// 去锁它就是 `mutex lock failed: Invalid argument` → abort(134)。macOS 官方
  /// 1.22.0 的 arm64 / x86_64 两份库都实测中招；Linux / Windows 只是碰巧析构顺序
  /// 无害。调过之后再 [instance] 会重新装一份。
  static void shutdown() {
    final OrtRuntime? rt = _instance;
    if (rt == null) return;
    _instance = null;
    rt.api.ref.ReleaseEnv.asFunction<void Function(Pointer<OrtEnv>)>()(rt.env);
  }

  static OrtRuntime _open(String? override) {
    final List<String> candidates = override != null && override.isNotEmpty
        ? <String>[override]
        : resolveLibraryCandidates();
    final List<String> attempted = <String>[];
    final _UsableOrt? picked = selectUsableCandidate<_UsableOrt>(
        candidates, probeCandidate, attempted);
    if (picked == null) {
      throw OrtRuntimeUnavailable(
        'onnxruntime 动态库不可用'
        '${Platform.isWindows ? "（Windows 上两种常见原因：一是缺 Microsoft Visual "
            "C++ Redistributable —— onnxruntime.dll 静态依赖 MSVCP140.dll；"
            "二是只搜到系统目录里那份旧 ORT，用 ASR_ONNXRUNTIME_LIB 指向 1.22 "
            "或更新的一份）" : ""}',
        attempted: attempted,
      );
    }
    final OnnxRuntimeBindings bindings = picked.bindings;
    final Pointer<OrtApi> api = picked.api;
    final Pointer<Pointer<OrtEnv>> envOut = calloc<Pointer<OrtEnv>>();
    final Pointer<Utf8> logId = 'asr'.toNativeUtf8();
    try {
      final Pointer<OrtStatus> status = api.ref.CreateEnv.asFunction<
          Pointer<OrtStatus> Function(
            int,
            Pointer<Char>,
            Pointer<Pointer<OrtEnv>>,
          )>()(
        OrtLoggingLevel.ORT_LOGGING_LEVEL_WARNING.value,
        logId.cast<Char>(),
        envOut,
      );
      checkOrtStatus(api, status);
      return OrtRuntime._(bindings, api, envOut.value, picked.path);
    } finally {
      calloc.free(logId);
      calloc.free(envOut);
    }
  }

  /// 在候选里挑第一个**真能用**的，每个失败候选的原因逐条记进 [failures]。
  ///
  /// 判据必须是「打得开 **且** `GetApi(kOrtApiVersion)` 非空」，不能只看 open。
  /// Windows 的 `C:\Windows\System32` 里就躺着一份随系统/驱动装的旧 ORT
  /// （实测 1.17.1），裸库名恒定先搜到它。只以 open 成功为准就会在那里 break，
  /// 把整条候选链毒死——后面真正可用的运行时永远轮不到，用户看到的是「不支持
  /// API 版本 22」而不是「继续找下一个」。
  static T? selectUsableCandidate<T>(
    List<String> candidates,
    (T?, String?) Function(String candidate) probe,
    List<String> failures,
  ) {
    for (final String candidate in candidates) {
      final (T? value, String? failure) = probe(candidate);
      if (value != null) return value;
      failures.add('$candidate：${failure ?? "未知原因"}');
    }
    return null;
  }

  /// 探一个候选：装上并要到与本包绑定匹配的 `OrtApi` 才算数。
  static (_UsableOrt?, String?) probeCandidate(String candidate) {
    final DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open(candidate);
    } catch (error) {
      return (null, '打不开（$error）');
    }
    // Dart 没有 DynamicLibrary.close：版本不合的库会留在进程里（一个模块句柄）。
    // 换下一个候选比让它毒死整条链划算。
    //
    // 符号查找与 open 一样是判据的一部分，同样只能记失败、不能抛：Windows 的
    // System32 里可能有一份**同名却不导出 `OrtGetApiBase`** 的 DLL（实测 error
    // 127 ERROR_PROC_NOT_FOUND）。lookup 抛出的 ArgumentError 一旦冒出去，
    // 「跳过不可用候选、继续往下找」就整个废掉；更糟的是 `ensureOrtRuntime()`
    // 开头就调这里，异常在下载分支之前抛出，托管运行时永远装不上。
    final OnnxRuntimeBindings bindings = OnnxRuntimeBindings(lib);
    final Pointer<OrtApiBase> base;
    try {
      base = bindings.OrtGetApiBase();
    } catch (error) {
      return (null, '不是 ONNX Runtime（找不到 OrtGetApiBase：$error）');
    }
    if (base == nullptr) return (null, 'OrtGetApiBase 返回空');
    final Pointer<OrtApi> api =
        base.ref.GetApi.asFunction<Pointer<OrtApi> Function(int)>()(
      kOrtApiVersion,
    );
    if (api == nullptr) {
      // ORT 对版本不支持的回应是 nullptr，不是抛错。不判这一下就会在第一次调用
      // 时空指针崩，堆栈里看不出真正原因。
      final Pointer<Char> version =
          base.ref.GetVersionString.asFunction<Pointer<Char> Function()>()();
      return (
        null,
        '版本 ${version == nullptr ? "未知" : readNativeCString(version)}'
            '，不支持 API 版本 $kOrtApiVersion（需要 1.22 或更新）'
      );
    }
    return (_UsableOrt(bindings, api, candidate), null);
  }

  /// 按序给出候选库路径。
  ///
  /// 1. `ASR_ONNXRUNTIME_LIB`：显式指定（开发 / 特殊部署，优先级最高）。
  /// 2. 可执行文件同级目录：随包分发的常规落点。
  /// 3. 裸库名：交给系统搜索路径。
  ///
  /// 与 ffmpeg 的解析顺序同范式（环境变量 > 捆绑 > 系统）。
  /// 按需下载装到的目录（`ensureOrtRuntime()` 写入）。
  ///
  /// 做成可变静态而不是把路径一路传进来：数据根是**异步**解析的
  /// （`asrSupportRootDirectory()`），而候选序列必须同步给出。与
  /// `asrSupportRootResolver` 同一种装配手法。null = 没有托管副本。
  static String? managedRuntimeDir;

  /// 候选序列：显式指定 > 按需下载的托管副本 > 可执行文件同级 > 系统搜索路径。
  ///
  /// 托管副本排在系统搜索路径前面是有意的：那份是我们按版本下的、判据过了的，
  /// 而裸库名在 Windows 上恒定先撞上 `C:\Windows\System32` 里随系统/驱动装
  /// 的旧 ORT。让已知好的那份先被试到，省掉每次启动都白探一遍旧库。
  static List<String> resolveLibraryCandidates({
    Map<String, String>? environment,
    String? executablePath,
    String? managedDir,
  }) {
    final Map<String, String> env = environment ?? Platform.environment;
    final String bare = defaultLibraryFileName();
    final String? override = env['ASR_ONNXRUNTIME_LIB'];
    final String exe = executablePath ?? Platform.resolvedExecutable;
    final String? managed = managedDir ?? managedRuntimeDir;
    return <String>[
      if (override != null && override.trim().isNotEmpty) override.trim(),
      if (managed != null && managed.trim().isNotEmpty)
        p.join(managed.trim(), bare),
      p.join(p.dirname(exe), bare),
      bare,
    ];
  }

  /// 各平台的裸库名。
  static String defaultLibraryFileName() {
    if (Platform.isWindows) return 'onnxruntime.dll';
    if (Platform.isMacOS) return 'libonnxruntime.dylib';
    return 'libonnxruntime.so';
  }

  /// 运行时版本串（`1.22.0`）。
  String get versionString {
    final Pointer<OrtApiBase> base = bindings.OrtGetApiBase();
    final Pointer<Char> v =
        base.ref.GetVersionString.asFunction<Pointer<Char> Function()>()();
    return v == nullptr ? 'unknown' : readNativeCString(v);
  }
}

/// 检查 ORT 调用的返回状态；非空即失败，读出码与消息后**必须** release。
void checkOrtStatus(Pointer<OrtApi> api, Pointer<OrtStatus> status) {
  if (status == nullptr) return;
  final int code = api.ref.GetErrorCode
      .asFunction<int Function(Pointer<OrtStatus>)>()(status);
  final Pointer<Char> message = api.ref.GetErrorMessage
      .asFunction<Pointer<Char> Function(Pointer<OrtStatus>)>()(status);
  final String text =
      message == nullptr ? '(no message)' : readNativeCString(message);
  api.ref.ReleaseStatus.asFunction<void Function(Pointer<OrtStatus>)>()(status);
  throw OrtException(code, text);
}

/// 读原生 NUL 结尾字符串，**非法 UTF-8 不抛**。
///
/// ORT 的错误消息不保证是 UTF-8：Windows 上 DML/D3D 的 HRESULT 描述来自
/// 系统 `FormatMessageA`，走的是当前 ANSI 代码页（中文系统 GBK）。直接
/// `Utf8.toDartString()` 遇到它抛 `FormatException: Unexpected extension byte
/// (at offset 169)`——真正的错因（`887A0004 DXGI_ERROR_UNSUPPORTED`：DirectML
/// 太旧 / 显卡不支持 D3D12）被一个偏移量顶替，用户只能瞎猜。这里按字节读到
/// NUL，坏字节用 U+FFFD 顶替，能读的部分（错误码、源文件、行号全是 ASCII）
/// 原样保留。[maxBytes] 是没有 NUL 时的兜底上限。
String readNativeCString(Pointer<Char> pointer, {int maxBytes = 1 << 16}) {
  final Pointer<Uint8> bytes = pointer.cast<Uint8>();
  int length = 0;
  while (length < maxBytes && bytes[length] != 0) {
    length++;
  }
  final Uint8List view = bytes.asTypedList(length);
  return utf8.decode(view, allowMalformed: true);
}

/// 一个通过版本判据的候选。
class _UsableOrt {
  _UsableOrt(this.bindings, this.api, this.path);
  final OnnxRuntimeBindings bindings;
  final Pointer<OrtApi> api;
  final String path;
}
