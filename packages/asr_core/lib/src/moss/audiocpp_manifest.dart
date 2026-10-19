/// audio.cpp 运行库与 MOSS-Transcribe-Diarize 权重的固定清单。
///
/// 全部按**版本 + sha256** 钉死：下来的是要执行的机器码与要加载的权重，长度校验
/// 挡不住「长度对得上的坏包」。摘要来源：运行库取 GitHub release 资产的
/// `digest` 字段，权重取 Hugging Face LFS 的 oid（固定 revision）。改版本时
/// 文件名、字节数、摘要三样一起改。
///
/// 平台覆盖（audio.cpp v0.9.2 实际发布了什么，2026-10-19 逐个列过归档）：
///
/// | 平台 | cuda | vulkan | cpu |
/// |---|---|---|---|
/// | Windows x64 | bin-cuda13.3 + cudart-cuda13.3 | bin-vulkan | bin-cpu |
/// | Linux x64 | **无 CLI** | bin-vulkan | bin-cpu |
///
/// Linux 没有 CUDA 版 CLI：`bin-ubuntu-x64-cuda12.8-colab.tar.gz` 里只有
/// `audiocpp_server`，`lib-ubuntu-x64-cuda*.tar.gz` 只有 `libaudiocpp.so`，
/// 都不是本层调用的 `audiocpp_cli`。所以 Linux + CUDA 在清单里是缺项
/// （[audioCppRuntimePackFor] 返回 null），N 卡走 vulkan。
library;

import 'package:fushi_asr_core/src/onnx/model_file_downloader.dart';

/// audio.cpp 版本（release tag 去掉 `v`）。
const String kAudioCppVersion = '0.9.2';

/// release 资产直链前缀。
const String kAudioCppReleaseBase =
    'https://github.com/0xShug0/audio.cpp/releases/download/v$kAudioCppVersion/';

/// audio.cpp 的推理后端，[cliValue] 即 `--backend` 的取值
/// （`audiocpp_cli --help`：`cpu|cuda|hip|rocm|vulkan|metal|best`）。
enum AudioCppBackend {
  cuda('cuda'),
  vulkan('vulkan'),
  cpu('cpu');

  const AudioCppBackend(this.cliValue);

  final String cliValue;
}

/// 运行库的目标平台。
enum AudioCppPlatform {
  windowsX64('windows-x64'),
  linuxX64('linux-x64');

  const AudioCppPlatform(this.id);

  /// 目录名里的平台段。
  final String id;
}

/// 清单里一个要下载的文件（运行库归档或权重），带固定摘要。
class AudioCppDownloadFile implements DownloadableModelFile {
  const AudioCppDownloadFile({
    required this.fileName,
    required this.url,
    required this.expectedBytes,
    required this.sha256,
  });

  /// 落盘文件名。权重文件**必须以 `.gguf` 结尾**：audio.cpp 按扩展名认格式。
  @override
  final String fileName;

  @override
  final String url;

  @override
  final int expectedBytes;

  /// 小写十六进制 sha256。
  final String sha256;
}

/// 一个平台 × 后端的运行库：若干归档解压到同一目录。
class AudioCppRuntimePack {
  const AudioCppRuntimePack({
    required this.platform,
    required this.backend,
    required this.archives,
  });

  final AudioCppPlatform platform;
  final AudioCppBackend backend;

  /// 按顺序解压到同一目录（cudart 归档与 bin 归档都是平铺布局）。
  final List<AudioCppDownloadFile> archives;

  /// 落盘目录名：`audiocpp-v<版本>-<平台>-<后端>`。换版本 / 换后端是另一个
  /// 目录，回退只改常量，不用先删旧的。
  String get directoryName =>
      'audiocpp-v$kAudioCppVersion-${platform.id}-${backend.cliValue}';

  /// 解压后 CLI 的相对路径（两平台的归档都把它放在根上）。
  String get executableName => platform == AudioCppPlatform.windowsX64
      ? 'audiocpp_cli.exe'
      : 'audiocpp_cli';

  /// 归档总字节数（「共需多少」）。
  int get totalBytes => archives.fold<int>(
      0, (int sum, AudioCppDownloadFile f) => sum + f.expectedBytes);
}

AudioCppDownloadFile _release(String name, int bytes, String sha256) =>
    AudioCppDownloadFile(
      fileName: name,
      url: '$kAudioCppReleaseBase$name',
      expectedBytes: bytes,
      sha256: sha256,
    );

/// v0.9.2 全部可用的运行库组合。
final List<AudioCppRuntimePack> kAudioCppRuntimePacks = <AudioCppRuntimePack>[
  AudioCppRuntimePack(
    platform: AudioCppPlatform.windowsX64,
    backend: AudioCppBackend.cuda,
    archives: <AudioCppDownloadFile>[
      _release(
        'audio-v0.9.2-bin-windows-x64-cuda13.3.zip',
        275142402,
        'ddf7474656e4c47a1bc5b5a53a268709d968d87132367d646baae5a77c34391f',
      ),
      _release(
        'audio-v0.9.2-cudart-windows-x64-cuda13.3.zip',
        575457454,
        'f3bb616e43f4b8aec4be7f2c2b323aec381a1993bac382401a011c121c126e59',
      ),
    ],
  ),
  AudioCppRuntimePack(
    platform: AudioCppPlatform.windowsX64,
    backend: AudioCppBackend.vulkan,
    archives: <AudioCppDownloadFile>[
      _release(
        'audio-v0.9.2-bin-windows-x64-vulkan.zip',
        62705751,
        '271402eae94195b9e2204e9f07e576bd0df879c75bafb0fa2f940830648d63f9',
      ),
    ],
  ),
  AudioCppRuntimePack(
    platform: AudioCppPlatform.windowsX64,
    backend: AudioCppBackend.cpu,
    archives: <AudioCppDownloadFile>[
      _release(
        'audio-v0.9.2-bin-windows-x64-cpu.zip',
        28258383,
        '66df445ba41f02ed2694e8d6933525163a3cc10adccf5cc40d5ad927c7774529',
      ),
    ],
  ),
  AudioCppRuntimePack(
    platform: AudioCppPlatform.linuxX64,
    backend: AudioCppBackend.vulkan,
    archives: <AudioCppDownloadFile>[
      _release(
        'audio-v0.9.2-bin-ubuntu-x64-vulkan.tar.gz',
        81428599,
        'f74b72124c412b28e6520e0c7b5cab31e89a9f933534f2ec2ab35664c4f491e6',
      ),
    ],
  ),
  AudioCppRuntimePack(
    platform: AudioCppPlatform.linuxX64,
    backend: AudioCppBackend.cpu,
    archives: <AudioCppDownloadFile>[
      _release(
        'audio-v0.9.2-bin-ubuntu-x64-cpu.tar.gz',
        53834870,
        '9de8271c0c46817c4dd2d4e4ff01584e2d5db6bcc528f28b08f5aa77e7c0968b',
      ),
    ],
  ),
];

/// 某平台 × 后端的运行库；v0.9.2 没发布对应 CLI 时返回 null（见文件头的表）。
AudioCppRuntimePack? audioCppRuntimePackFor(
  AudioCppPlatform platform,
  AudioCppBackend backend,
) {
  for (final AudioCppRuntimePack pack in kAudioCppRuntimePacks) {
    if (pack.platform == platform && pack.backend == backend) return pack;
  }
  return null;
}

/// MOSS 权重所在 HF 仓库与固定 revision。
const String kMossModelRepo = 'audio-cpp/audio.cpp-gguf';
const String kMossModelRevision = '661a224e9d9adbd49c01626f85e426f5f425d771';

/// MOSS-Transcribe-Diarize Q8_0 GGUF。
const AudioCppDownloadFile kMossModelFile = AudioCppDownloadFile(
  fileName: 'moss-transcribe-diarize-q8_0.gguf',
  url: 'https://huggingface.co/$kMossModelRepo/resolve/$kMossModelRevision/'
      'MOSS-Transcribe-Diarize-GGUF/moss-transcribe-diarize-q8_0.gguf',
  expectedBytes: 1132110560,
  sha256: '93eea5865615e270b827752945f2dfd0f522ed673f4f551675e9013170173679',
);
