import 'dart:ffi';
import 'dart:io';

/// 显式指定原生库路径的环境变量（测试 / 开发用）。
const String kAsrCuePostLibEnv = 'FUSHI_ASR_CUE_POST_LIB';

/// 绑定期望的 C ABI 版本（`native/asr_cue_post/src/lib.rs` 的 `ABI_VERSION`）。
const int kAsrCuePostAbiVersion = 1;

/// 绑定会 lookup 的全部 C 符号。宿主把本 crate 编进自己的原生库时，用它核对导出是否齐全。
const List<String> kAsrCuePostSymbols = <String>[
  'fcp_abi_version',
  'fcp_cue_post_process',
];

/// 原生库加载失败 / 缺符号 / ABI 不符。原生库是硬依赖：不回退到任何 Dart 实现。
final class AsrCuePostUnavailableError extends Error {
  AsrCuePostUnavailableError(this.message, [this.attempts = const <String>[]]);

  final String message;

  /// 逐个候选路径的失败原因。
  final List<String> attempts;

  @override
  String toString() => attempts.isEmpty
      ? 'AsrCuePostUnavailableError: $message'
      : 'AsrCuePostUnavailableError: $message\n  ${attempts.join('\n  ')}';
}

typedef _AbiVersionC = Int32 Function();
typedef _AbiVersionDart = int Function();

/// 已加载、核对过 ABI 的 `fcp_*` 原生库。
///
/// 两种来源：
/// - [instance] / [load]：本仓自己的 `native/asr_cue_post` 产物（cdylib）；
/// - [fromDynamicLibrary]：宿主把 crate 当 Cargo 依赖编进了自己的原生库（Fushi 的
///   `fushi_compute`），把那个库交进来。
///
/// 注意 isolate 边界：静态 [instance] 每个 isolate 各自加载一次；宿主注入的库要在
/// 运行处理的那个 isolate 里取。
final class AsrCuePostLibrary {
  AsrCuePostLibrary._(this.library, this.libraryPath);

  /// 底层动态库。
  final DynamicLibrary library;

  /// 实际加载的路径；进程内 / 宿主注入时为 null。
  final String? libraryPath;

  /// 包装宿主已加载的库；ABI 不符或缺 [kAsrCuePostSymbols] 时抛
  /// [AsrCuePostUnavailableError]。
  static AsrCuePostLibrary fromDynamicLibrary(
    DynamicLibrary library, {
    String? libraryPath,
  }) {
    final String? error = bindError(library);
    if (error != null) {
      throw AsrCuePostUnavailableError(
        'native library ${libraryPath ?? '<host>'} cannot serve fcp_*: $error',
      );
    }
    return AsrCuePostLibrary._(library, libraryPath);
  }

  static AsrCuePostLibrary? _default;
  static AsrCuePostUnavailableError? _defaultError;

  /// 按 [libraryCandidates] 加载一次并缓存；失败抛 [AsrCuePostUnavailableError]
  /// （之后每次访问都抛同一个）。
  static AsrCuePostLibrary get instance {
    final AsrCuePostLibrary? loaded = _default;
    if (loaded != null) return loaded;
    final AsrCuePostUnavailableError? error = _defaultError;
    if (error != null) throw error;
    try {
      return _default = load();
    } on AsrCuePostUnavailableError catch (e) {
      _defaultError = e;
      rethrow;
    }
  }

  /// 当前平台的裸库名。
  static String defaultLibraryName() {
    if (Platform.isWindows) return 'fushi_asr_cue_post.dll';
    if (Platform.isMacOS || Platform.isIOS) {
      return 'libfushi_asr_cue_post.dylib';
    }
    return 'libfushi_asr_cue_post.so';
  }

  /// 进程是不是测试宿主（`dart test` / `flutter test`）。只有它才去仓库里找
  /// `native/asr_cue_post/target/release/`：正式程序不能从当前目录的上级加载库。
  static bool isTestHost(String executablePath) {
    final String base =
        executablePath.split(RegExp(r'[\\/]')).last.toLowerCase();
    return base == 'dart' ||
        base == 'dart.exe' ||
        base == 'flutter_tester' ||
        base == 'flutter_tester.exe';
  }

  /// 候选路径，按优先级：显式 [libraryPath] → 环境变量 [kAsrCuePostLibEnv] →
  /// 可执行文件同级 → `bin/../lib/<name>` → 测试宿主下从 [currentDirectory] 向上找到的
  /// `native/asr_cue_post/target/release/<name>` → 裸名（系统搜索路径）。
  static List<String> libraryCandidates({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
    String? currentDirectory,
  }) {
    final String name = defaultLibraryName();
    final Map<String, String> env = environment ?? Platform.environment;
    final String exe = executablePath ?? Platform.resolvedExecutable;
    final String binDir = File(exe).parent.path;
    final String sep = Platform.pathSeparator;
    final String? fromEnv = env[kAsrCuePostLibEnv];
    final String? built = isTestHost(exe)
        ? _findRepoBuild(currentDirectory ?? Directory.current.path, name)
        : null;
    return <String>[
      if (libraryPath != null && libraryPath.isNotEmpty) libraryPath,
      if (fromEnv != null && fromEnv.isNotEmpty) fromEnv,
      '$binDir$sep$name',
      File('$binDir$sep..${sep}lib$sep$name').absolute.path,
      if (built != null) built,
      name,
    ];
  }

  static String? _findRepoBuild(String start, String name) {
    final String sep = Platform.pathSeparator;
    Directory dir = Directory(start).absolute;
    for (int depth = 0; depth < 8; depth++) {
      final File candidate = File(
        '${dir.path}${sep}native${sep}asr_cue_post${sep}target'
        '${sep}release$sep$name',
      );
      if (candidate.existsSync()) return candidate.path;
      // 到仓库根为止：worktree 的 `.git` 是文件，再往上会悄悄加载别的副本。
      if (FileSystemEntity.typeSync('${dir.path}$sep.git') !=
          FileSystemEntityType.notFound) {
        break;
      }
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// 按 [libraryCandidates] 顺序加载；全部失败抛 [AsrCuePostUnavailableError]，带每个
  /// 候选的失败原因。显式给了 [libraryPath] 时只试这一个。
  static AsrCuePostLibrary load({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
    String? currentDirectory,
  }) {
    if (Platform.isIOS && (libraryPath == null || libraryPath.isEmpty)) {
      // iOS 只能静态链进主二进制。
      final DynamicLibrary process = DynamicLibrary.process();
      final String? error = bindError(process);
      if (error != null) {
        throw AsrCuePostUnavailableError(
          'fcp_* is not linked into this iOS binary: $error',
        );
      }
      return AsrCuePostLibrary._(process, null);
    }
    final List<String> candidates =
        libraryPath != null && libraryPath.isNotEmpty
            ? <String>[libraryPath]
            : libraryCandidates(
                environment: environment,
                executablePath: executablePath,
                currentDirectory: currentDirectory,
              );
    final List<String> attempts = <String>[];
    for (final String candidate in candidates) {
      final bool isBareName = !candidate.contains('/') &&
          !candidate.contains(Platform.pathSeparator);
      if (!isBareName && !File(candidate).existsSync()) {
        attempts.add('$candidate: not found');
        continue;
      }
      final DynamicLibrary lib;
      try {
        lib = DynamicLibrary.open(candidate);
      } on ArgumentError catch (e) {
        attempts.add('$candidate: cannot open (${e.message})');
        continue;
      }
      final String? error = bindError(lib);
      if (error != null) {
        attempts.add('$candidate: $error');
        continue;
      }
      return AsrCuePostLibrary._(lib, candidate);
    }
    throw AsrCuePostUnavailableError(
      'cannot load ${defaultLibraryName()}',
      attempts,
    );
  }

  /// 库可用返回 null；否则返回原因（缺符号 / ABI 不符）。
  static String? bindError(DynamicLibrary lib) {
    for (final String symbol in kAsrCuePostSymbols) {
      if (!lib.providesSymbol(symbol)) return 'missing symbol $symbol';
    }
    final int version = lib
        .lookupFunction<_AbiVersionC, _AbiVersionDart>('fcp_abi_version')
        .call();
    if (version != kAsrCuePostAbiVersion) {
      return 'ABI version $version, bindings expect $kAsrCuePostAbiVersion';
    }
    return null;
  }
}
