/// audio.cpp 运行库与 MOSS 权重的磁盘管理：目录、就绪判定、状态、下载、校验、
/// 解压、删除。
///
/// 下载走共享的 [ModelFileDownloader]（`.part` 续传 / 镜像回退 / 代理 / 连接
/// 健康），本文件只补两件它不做的事：
/// - **sha256 校验**：下载器只校长度。校验通过才转正（运行库解压、权重写
///   sidecar），不符就删掉坏档并抛 [AudioCppProvisionCorrupt]。
/// - **解压**：运行库是 zip / tar.gz，解压交给系统 `tar`（见 [extractWithSystemTar]
///   的理由），经注入的进程启动器调用。
///
/// 落盘位置（都在 [asrSupportRootDirectory] 下）：
/// - 运行库：`<root>/asr_runtimes/audiocpp-v0.9.2-<平台>-<后端>/`
/// - 权重：`<root>/asr_models/moss/moss-transcribe-diarize-q8_0.gguf`
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'package:fushi_asr_core/src/moss/audiocpp_manifest.dart';
import 'package:fushi_asr_core/src/onnx/model_file_downloader.dart';
import 'package:fushi_asr_core/src/util/asr_paths.dart';
import 'package:fushi_asr_core/src/util/asr_process.dart';
import 'package:fushi_asr_core/src/util/directory_bytes.dart';

/// 下下来的文件与清单不符（长度或摘要），或解压后缺 CLI。
class AudioCppProvisionCorrupt implements Exception {
  const AudioCppProvisionCorrupt(this.message);

  final String message;

  @override
  String toString() => 'AudioCppProvisionCorrupt: $message';
}

/// 「就绪 / 缺什么 / 共需多少」状态。
class AudioCppProvisionStatus {
  const AudioCppProvisionStatus({
    required this.ready,
    required this.missingFiles,
    required this.totalBytes,
    required this.obtainedBytes,
    required this.diskBytes,
  });

  /// 全部就绪（运行库：已解压且 CLI 在；权重：已校验摘要）。
  final bool ready;

  /// 还缺的清单文件名（就绪时为空）。
  final List<String> missingFiles;

  /// 清单文件的总字节数（下载量，不是解压后的占用）。
  final int totalBytes;

  /// 朝 [totalBytes] 已拿到的字节：已下完的文件 + `.part` 残留。就绪时等于
  /// [totalBytes]。
  final int obtainedBytes;

  /// 目录真实递归占用（回答「删掉能腾出多少」）。
  final int diskBytes;

  /// 还需下载的字节数。
  int get remainingBytes =>
      (totalBytes - obtainedBytes).clamp(0, totalBytes).toInt();
}

/// 归档解压器签名：把 [archive] 解到 [target]（平铺，覆盖同名文件）。
typedef AudioCppArchiveExtractor = Future<void> Function(
  File archive,
  Directory target,
);

/// 系统 tar 的路径。
///
/// Windows 必须用 `%SystemRoot%\System32\tar.exe`（Windows 10 1803 起自带的
/// bsdtar，认 zip）——PATH 上的 `tar` 很可能是 Git 自带的 GNU tar，**不认 zip**。
/// 其它平台用 PATH 上的 `tar`（GNU / bsd 都自动识别 gzip）。
String systemTarExecutable() {
  if (!Platform.isWindows) return 'tar';
  final String root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return p.join(root, 'System32', 'tar.exe');
}

/// 用系统 tar 解压。
///
/// 为什么不用 `package:archive`：cudart 归档 575 MB、解压后上 GB，3.x 能流式解压
/// 的 `archive_io` 在 4.x 已移除，而宿主（Fushi）把 archive 钉在 3.x、本仓其它
/// 包是 4.x，两边没有共同的流式 API；整包 `decodeBytes` 读进内存又不可接受。
/// 系统 tar 两平台都在、流式、不加依赖。
Future<void> extractWithSystemTar(
  File archive,
  Directory target, {
  AsrProcessStarter? startProcess,
  AsrCancellationToken? cancellation,
  String? tarExecutable,
}) async {
  await target.create(recursive: true);
  final String tar = tarExecutable ?? systemTarExecutable();
  final AsrProcessResult result = await runAsrProcess(
    tar,
    <String>['-xf', archive.path, '-C', target.path],
    startProcess: startProcess,
    cancellation: cancellation,
  );
  if (result.exitCode != 0) {
    throw AudioCppProvisionCorrupt(
      '解压 ${p.basename(archive.path)} 失败（$tar 退出码 ${result.exitCode}）：'
      '${_tail(result.stderr, 800)}',
    );
  }
}

String _tail(String s, int n) => s.length <= n ? s : s.substring(s.length - n);

/// 文件的 sha256（流式，不整读进内存）。
Future<String> audioCppFileSha256(File file) async {
  final crypto.Digest digest = await crypto.sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// 校验 [file] 与清单项 [spec] 的长度与摘要；不符就**删掉**它并抛
/// [AudioCppProvisionCorrupt]（坏档留着只会让下次续传在坏偏移上加码）。
Future<void> verifyAudioCppDownload(
  File file,
  AudioCppDownloadFile spec,
) async {
  final int actual = file.existsSync() ? file.lengthSync() : -1;
  if (actual != spec.expectedBytes) {
    _deleteQuietly(file);
    throw AudioCppProvisionCorrupt(
      '${spec.fileName} 长度 $actual 与预期 ${spec.expectedBytes} 不符',
    );
  }
  final String digest = await audioCppFileSha256(file);
  if (digest != spec.sha256) {
    _deleteQuietly(file);
    throw AudioCppProvisionCorrupt(
      '${spec.fileName} sha256 $digest 与预期 ${spec.sha256} 不符',
    );
  }
}

void _deleteQuietly(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // 被占用删不掉：上抛的校验错误已足够说明问题。
  }
}

/// 下载器的「已就绪」判据：存在且长度等于清单值（摘要另行校验）。
bool _hasExpectedLength(File file, AudioCppDownloadFile spec) =>
    file.existsSync() && file.lengthSync() == spec.expectedBytes;

int _partBytes(File file) {
  final File part = File('${file.path}.part');
  return part.existsSync() ? part.lengthSync() : 0;
}

/// 一个平台 × 后端的 audio.cpp 运行库目录。
class AudioCppRuntimeStore {
  AudioCppRuntimeStore(
    this.dir,
    this.pack, {
    AsrProcessStarter? startProcess,
    AudioCppArchiveExtractor? extractor,
  })  : _startProcess = startProcess,
        _extractor = extractor;

  /// `<root>/asr_runtimes/<pack.directoryName>`。
  static Future<AudioCppRuntimeStore> open(
    AudioCppRuntimePack pack, {
    AsrProcessStarter? startProcess,
    AudioCppArchiveExtractor? extractor,
  }) async {
    final Directory root = await asrSupportRootDirectory();
    return AudioCppRuntimeStore(
      Directory(p.join(root.path, 'asr_runtimes', pack.directoryName)),
      pack,
      startProcess: startProcess,
      extractor: extractor,
    );
  }

  final Directory dir;
  final AudioCppRuntimePack pack;
  final AsrProcessStarter? _startProcess;
  final AudioCppArchiveExtractor? _extractor;

  /// 解压完成标记：记录装进来的归档摘要。CLI 在但标记缺 / 不符（解压中途被杀、
  /// 换了版本）一律当未就绪重装。
  File get _marker => File(p.join(dir.path, '.audiocpp-installed.json'));

  /// 归档的中转目录（解压完即删）。
  Directory get _downloadDir => Directory(p.join(dir.path, '.download'));

  /// CLI 可执行文件（不保证存在）。
  File get executable => File(p.join(dir.path, pack.executableName));

  String get _expectedMarker => jsonEncode(<String, Object?>{
        'version': kAudioCppVersion,
        'archives': <String>[
          for (final AudioCppDownloadFile a in pack.archives) a.sha256,
        ],
      });

  /// 已解压、CLI 在、标记与清单一致。
  bool get isReady {
    if (!executable.existsSync() || !_marker.existsSync()) return false;
    try {
      return _marker.readAsStringSync() == _expectedMarker;
    } on FileSystemException {
      return false;
    }
  }

  /// 就绪 / 缺什么 / 共需多少（递归量目录，别放热路径）。
  Future<AudioCppProvisionStatus> status() async {
    final int total = pack.totalBytes;
    final int disk = await measureDirectoryBytes(dir);
    if (isReady) {
      return AudioCppProvisionStatus(
        ready: true,
        missingFiles: const <String>[],
        totalBytes: total,
        obtainedBytes: total,
        diskBytes: disk,
      );
    }
    final List<String> missing = <String>[];
    int obtained = 0;
    for (final AudioCppDownloadFile a in pack.archives) {
      final File f = File(p.join(_downloadDir.path, a.fileName));
      if (_hasExpectedLength(f, a)) {
        obtained += a.expectedBytes;
      } else {
        obtained += _partBytes(f);
      }
      missing.add(a.fileName);
    }
    return AudioCppProvisionStatus(
      ready: false,
      missingFiles: missing,
      totalBytes: total,
      obtainedBytes: obtained,
      diskBytes: disk,
    );
  }

  /// 确保运行库就绪：缺了就下载 → 逐个校验摘要 → 解压 → 校验 CLI → 写标记。
  ///
  /// 已就绪时**一个事件都不发**。进度事件契约同 [ModelFileDownloader.downloadAll]
  /// （其 `done` 事件在下载完成时发出，随后才是校验与解压）。
  Stream<ModelDownloadEvent> ensure({
    ModelFileDownloader? downloader,
    AsrCancellationToken? cancellation,
  }) async* {
    if (isReady) return;
    await _downloadDir.create(recursive: true);
    final ModelFileDownloader effective = downloader ?? ModelFileDownloader();
    yield* effective.downloadAll(
      files: pack.archives,
      targetDir: _downloadDir,
      isReady: (File f) => _hasExpectedLength(
        f,
        pack.archives.firstWhere(
          (AudioCppDownloadFile a) => a.fileName == p.basename(f.path),
        ),
      ),
    );
    cancellation?.throwIfCancelled();
    // 先全部校验再解压：任何一个包是坏的就不往目录里写半套运行库。
    for (final AudioCppDownloadFile a in pack.archives) {
      await verifyAudioCppDownload(
        File(p.join(_downloadDir.path, a.fileName)),
        a,
      );
    }
    for (final AudioCppDownloadFile a in pack.archives) {
      cancellation?.throwIfCancelled();
      final File archive = File(p.join(_downloadDir.path, a.fileName));
      final AudioCppArchiveExtractor? extractor = _extractor;
      if (extractor != null) {
        await extractor(archive, dir);
      } else {
        await extractWithSystemTar(
          archive,
          dir,
          startProcess: _startProcess,
          cancellation: cancellation,
        );
      }
    }
    if (!executable.existsSync()) {
      throw AudioCppProvisionCorrupt(
        '解压后没有 ${pack.executableName}（${dir.path}）',
      );
    }
    if (pack.platform == AudioCppPlatform.linuxX64 && !Platform.isWindows) {
      // tar 一般保留可执行位，但归档来源不可控，显式补一刀。
      final AsrProcessResult chmod = await runAsrProcess(
        'chmod',
        <String>['+x', executable.path],
        startProcess: _startProcess,
        cancellation: cancellation,
      );
      if (chmod.exitCode != 0) {
        throw AudioCppProvisionCorrupt(
          'chmod +x ${executable.path} 失败：${_tail(chmod.stderr, 400)}',
        );
      }
    }
    await _marker.writeAsString(_expectedMarker, flush: true);
    await _downloadDir.delete(recursive: true);
  }

  /// 删除整个运行库目录，返回释放的字节数。
  Future<int> deleteAll() async {
    if (!await dir.exists()) return 0;
    final int freed = await measureDirectoryBytes(dir);
    await dir.delete(recursive: true);
    return freed;
  }
}

/// MOSS 权重目录：`<root>/asr_models/moss/`。
class MossModelStore {
  MossModelStore(this.dir, {this.file = kMossModelFile});

  static Future<MossModelStore> open({
    AudioCppDownloadFile file = kMossModelFile,
  }) async {
    final Directory root = await asrSupportRootDirectory();
    return MossModelStore(
      Directory(p.join(root.path, 'asr_models', 'moss')),
      file: file,
    );
  }

  final Directory dir;
  final AudioCppDownloadFile file;

  /// 权重文件（不保证存在）。
  File get modelFile => File(p.join(dir.path, file.fileName));

  /// 摘要已校验过的 sidecar：内容是校验通过的 sha256。1.1 GB 每次 stat 都重算
  /// 摘要不现实，所以只在下载完成时算一次，之后看 sidecar + 长度。
  File get _verifiedMarker => File('${modelFile.path}.sha256');

  /// 长度对、sidecar 摘要与清单一致。
  bool get isReady {
    if (!_hasExpectedLength(modelFile, file)) return false;
    if (!_verifiedMarker.existsSync()) return false;
    try {
      return _verifiedMarker.readAsStringSync().trim() == file.sha256;
    } on FileSystemException {
      return false;
    }
  }

  Future<AudioCppProvisionStatus> status() async {
    final int disk = await measureDirectoryBytes(dir);
    final bool ready = isReady;
    final int obtained = ready || _hasExpectedLength(modelFile, file)
        ? file.expectedBytes
        : _partBytes(modelFile);
    return AudioCppProvisionStatus(
      ready: ready,
      missingFiles: ready ? const <String>[] : <String>[file.fileName],
      totalBytes: file.expectedBytes,
      obtainedBytes: obtained,
      diskBytes: disk,
    );
  }

  /// 确保权重就绪：缺了就下（HF 主源 → hf-mirror），下完校验摘要写 sidecar。
  /// 已就绪时不发事件。
  Stream<ModelDownloadEvent> ensure({ModelFileDownloader? downloader}) async* {
    if (isReady) return;
    final ModelFileDownloader effective = downloader ?? ModelFileDownloader();
    yield* effective.downloadAll(
      files: <DownloadableModelFile>[file],
      targetDir: dir,
      isReady: (File f) => _hasExpectedLength(f, file),
    );
    _deleteQuietly(_verifiedMarker);
    await verifyAudioCppDownload(modelFile, file);
    await _verifiedMarker.writeAsString(file.sha256, flush: true);
  }

  Future<int> deleteAll() async {
    if (!await dir.exists()) return 0;
    final int freed = await measureDirectoryBytes(dir);
    await dir.delete(recursive: true);
    return freed;
  }
}
