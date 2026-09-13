/// Windows `DirectML.dll` 的解析、版本读取与预加载。
///
/// ## 为什么要自己管这份 DLL
///
/// onnxruntime.dll 的 DirectML EP 在建会话时 `LoadLibrary("DirectML.dll")`，
/// 交给系统搜索顺序。上游原先的假设是「DirectML.dll 是 Windows 10 1903+ 的系统
/// 组件，System32 里就有、够新」——那只在 Windows 11 上成立（实测 1.15.5）。
/// **Windows 10 的 System32 里是 1.0.200713（2020 年 7 月，1.2 MB）**，而
/// ORT 1.22 的 DirectML 包在 NuGet 上声明的依赖下限是 1.15.4：老版本建不出
/// DML 设备，`887A0004 DXGI_ERROR_UNSUPPORTED`，整条链静默回落 CPU，用户看到的
/// 只是「GPU 占用个位数、慢十倍」。
///
/// 所以 DirectML.dll 与 onnxruntime.dll 一样由本包负责解析：候选序列显式给出、
/// 每个候选读文件版本、挑第一个够新的**按完整路径预加载**。Windows 按模块基名
/// 去重——本进程里一旦有了一份 `DirectML.dll`，ORT 之后再按裸名 LoadLibrary
/// 拿到的就是同一个模块，不再受搜索顺序与 System32 里那份旧版左右。
///
/// 候选序列（与 onnxruntime.dll 同范式：显式 > 随包 > 托管 > 系统）：
/// 1. `ASR_DIRECTML_LIB`
/// 2. 可执行文件同级（发布包随附）
/// 3. 按需下载的 ORT 托管目录（`OrtRuntime.managedRuntimeDir`）
/// 4. `%SystemRoot%\System32\DirectML.dll`
///
/// 不随 ORT 一起按需下载：`Microsoft.AI.DirectML` nupkg 为了塞 Xbox 与 debug
/// 二进制有 202 MB，为一个 18 MB 的 DLL 拖它不划算；发布包由 CI 抽出来随附。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_asr_onnx_ffi/src/ort_runtime.dart';

/// `Microsoft.ML.OnnxRuntime.DirectML 1.22.0` 在 NuGet 上声明的
/// `Microsoft.AI.DirectML` 依赖版本。低于它不一定不能跑，但那是 ORT 没承诺过
/// 的组合——诊断里要把这条线画出来。
const List<int> kDirectMlRequiredVersion = <int>[1, 15, 4];

/// 一次解析的结果。
class DirectMlResolution {
  const DirectMlResolution({
    required this.path,
    required this.version,
    required this.attempted,
  });

  /// 选中的 DLL 完整路径；一个候选都不存在时为 null。
  final String? path;

  /// [path] 的文件版本（4 段）；读不出为 null。
  final List<int>? version;

  /// 每个候选的判定，按序：`路径：结论`。
  final List<String> attempted;

  bool get found => path != null;

  /// 选中的那份是否 ≥ [kDirectMlRequiredVersion]。版本读不出时按「不够」处理
  /// ——那是异常形态的文件，不该被当成够新。
  bool get meetsRequirement =>
      version != null &&
      compareVersions(version!, kDirectMlRequiredVersion) >= 0;

  String get versionString => version?.join('.') ?? '未知';

  /// 给错误消息 / doctor 用的一句话结论。
  String describe() {
    if (!found) {
      return 'DirectML.dll 一个候选都不存在（试过：${attempted.join(" / ")}）';
    }
    final String base = 'DirectML.dll = $path（版本 $versionString）';
    if (meetsRequirement) return base;
    return '$base，低于 ORT $kOrtPackageVersionLabel 要求的 '
        '${kDirectMlRequiredVersion.join(".")}：Windows 10 自带的就是这么老，'
        '把发布包里的 DirectML.dll 放在可执行文件旁边，或用 ASR_DIRECTML_LIB 指向一份新的';
  }

  static int compareVersions(List<int> a, List<int> b) {
    for (int i = 0; i < 4; i++) {
      final int x = i < a.length ? a[i] : 0;
      final int y = i < b.length ? b[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }
}

/// 只在描述里用的 ORT 版本文字；不 import provisioning 以免循环依赖。
const String kOrtPackageVersionLabel = '1.22';

/// 进程内单例：解析一次、预加载一次。
class DirectMlRuntime {
  DirectMlRuntime._();

  static const String libraryFileName = 'DirectML.dll';

  static DirectMlResolution? _resolution;
  static DynamicLibrary? _preloaded;

  /// 解析 + 预加载（幂等）。非 Windows 直接返回「无候选」，不碰文件系统。
  ///
  /// 预加载失败不抛：那份文件存在但装不上（损坏 / 架构不对）的原因会记在
  /// [DirectMlResolution.attempted]，真正的失败让 ORT 建会话时报出来，与
  /// 其它 EP 故障走同一条回落路径。
  static DirectMlResolution ensureLoaded() {
    final DirectMlResolution? cached = _resolution;
    if (cached != null) return cached;
    final DirectMlResolution resolved = resolve();
    final String? path = resolved.path;
    if (path != null && _preloaded == null) {
      try {
        _preloaded = DynamicLibrary.open(path);
      } catch (error) {
        resolved.attempted.add('$path：预加载失败（$error）');
      }
    }
    return _resolution = resolved;
  }

  /// 测试用：清掉缓存的解析结果（已加载的模块留在进程里，Dart 关不掉）。
  static void resetForTesting() {
    _resolution = null;
  }

  /// 纯解析，不加载。所有输入可注入，好在非 Windows 上测判定逻辑。
  static DirectMlResolution resolve({
    Map<String, String>? environment,
    String? executablePath,
    String? managedDir,
    String? systemRoot,
    bool? isWindows,
    List<int>? Function(String path)? readVersion,
  }) {
    final bool windows = isWindows ?? Platform.isWindows;
    if (!windows) {
      return const DirectMlResolution(
          path: null, version: null, attempted: <String>['非 Windows，不适用']);
    }
    final List<String> candidates = resolveCandidates(
      environment: environment,
      executablePath: executablePath,
      managedDir: managedDir,
      systemRoot: systemRoot,
    );
    final List<int>? Function(String) version = readVersion ?? readFileVersion;
    final List<String> attempted = <String>[];
    String? bestPath;
    List<int>? bestVersion;
    for (final String candidate in candidates) {
      if (!File(candidate).existsSync()) {
        attempted.add('$candidate：不存在');
        continue;
      }
      final List<int>? v = version(candidate);
      final String label = v?.join('.') ?? '版本读不出';
      final bool ok = v != null &&
          DirectMlResolution.compareVersions(v, kDirectMlRequiredVersion) >= 0;
      attempted.add('$candidate：$label${ok ? "" : "（低于要求）"}');
      if (ok) {
        return DirectMlResolution(
            path: candidate, version: v, attempted: attempted);
      }
      // 没有一份够新时退而选版本最高的那份：至少让报错里带的是它。
      if (bestPath == null ||
          (v != null &&
              (bestVersion == null ||
                  DirectMlResolution.compareVersions(v, bestVersion) > 0))) {
        bestPath = candidate;
        bestVersion = v;
      }
    }
    return DirectMlResolution(
        path: bestPath, version: bestVersion, attempted: attempted);
  }

  /// 候选序列，见文件头。
  static List<String> resolveCandidates({
    Map<String, String>? environment,
    String? executablePath,
    String? managedDir,
    String? systemRoot,
  }) {
    final Map<String, String> env = environment ?? Platform.environment;
    final String? override = env['ASR_DIRECTML_LIB'];
    final String exe = executablePath ?? Platform.resolvedExecutable;
    final String? managed = managedDir ?? OrtRuntime.managedRuntimeDir;
    final String root = systemRoot ?? env['SystemRoot'] ?? r'C:\Windows';
    return <String>[
      if (override != null && override.trim().isNotEmpty) override.trim(),
      p.join(p.dirname(exe), libraryFileName),
      if (managed != null && managed.trim().isNotEmpty)
        p.join(managed.trim(), libraryFileName),
      p.join(root, 'System32', libraryFileName),
    ];
  }

  /// 读 PE 文件版本（`VS_FIXEDFILEINFO.dwFileVersion`），走 `version.dll`。
  /// 非 Windows / 读不出返回 null。
  static List<int>? readFileVersion(String path) {
    if (!Platform.isWindows) return null;
    try {
      final DynamicLibrary version = DynamicLibrary.open('version.dll');
      final int Function(Pointer<Utf16>, Pointer<Uint32>) sizeOf =
          version.lookupFunction<
              Uint32 Function(Pointer<Utf16>, Pointer<Uint32>),
              int Function(
                  Pointer<Utf16>, Pointer<Uint32>)>('GetFileVersionInfoSizeW');
      final int Function(Pointer<Utf16>, int, int, Pointer<Uint8>) getInfo =
          version.lookupFunction<
              Int32 Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Uint8>),
              int Function(Pointer<Utf16>, int, int,
                  Pointer<Uint8>)>('GetFileVersionInfoW');
      final int Function(Pointer<Uint8>, Pointer<Utf16>,
              Pointer<Pointer<Uint8>>, Pointer<Uint32>) query =
          version.lookupFunction<
              Int32 Function(Pointer<Uint8>, Pointer<Utf16>,
                  Pointer<Pointer<Uint8>>, Pointer<Uint32>),
              int Function(Pointer<Uint8>, Pointer<Utf16>,
                  Pointer<Pointer<Uint8>>, Pointer<Uint32>)>('VerQueryValueW');
      return using((Arena arena) {
        final Pointer<Utf16> file = path.toNativeUtf16(allocator: arena);
        final Pointer<Uint32> handle = arena<Uint32>();
        final int size = sizeOf(file, handle);
        if (size == 0) return null;
        final Pointer<Uint8> buffer = arena<Uint8>(size);
        if (getInfo(file, 0, size, buffer) == 0) return null;
        final Pointer<Pointer<Uint8>> out = arena<Pointer<Uint8>>();
        final Pointer<Uint32> outLen = arena<Uint32>();
        if (query(buffer, r'\'.toNativeUtf16(allocator: arena), out, outLen) ==
                0 ||
            outLen.value < 16) {
          return null;
        }
        // VS_FIXEDFILEINFO：dwSignature(0) dwStrucVersion(4) dwFileVersionMS(8)
        // dwFileVersionLS(12)。
        final Pointer<Uint32> fixed = out.value.cast<Uint32>();
        if (fixed[0] != 0xFEEF04BD) return null;
        final int ms = fixed[2];
        final int ls = fixed[3];
        return <int>[ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF];
      });
    } catch (_) {
      return null;
    }
  }
}
