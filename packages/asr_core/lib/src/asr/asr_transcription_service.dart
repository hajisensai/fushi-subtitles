/// 有声书设备端转录的装配层：模型存储 / 引擎加载 / PCM 源 / 任务目录 三者拼成
/// 一次可运行的 [AsrRunningTranscription]，UI 只与本层对话。
///
/// 任务目录按「音频文件名 + 字节数 + 模型包 id」的 SHA-1 命名
/// （`<appSupport>/asr_jobs/<hash>`），与绝对路径无关：用户把有声书目录挪个位置
/// 再选同一组文件，进度照样接上；同一组音频换语言转录是另一个任务，互不覆盖。
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_asr_core/src/asr/asr_cue_builder.dart'
    show AsrCueTokenTiming, parseAsrCueTokens;
import 'package:fushi_asr_core/src/asr/asr_encoder_buckets.dart';
import 'package:fushi_asr_core/src/asr/asr_engine.dart';
import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_model_store.dart';
import 'package:fushi_asr_core/src/asr/asr_pcm_source.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_isolate.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart';
import 'package:fushi_asr_core/src/asr/asr_transducer_decoder.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/asr/asr_vad.dart';
import 'package:fushi_asr_core/src/onnx/model_file_downloader.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';
import 'package:fushi_asr_core/src/util/asr_paths.dart';

/// 素材的声学属性：调用方对**自己的输入**作出的断言。
///
/// 这里刻意不是「选哪个 VAD 实现」——调用方不知道该选哪个，但它一定知道自己在
/// 转什么。实现映射只发生在一处（切段器的构造点）。
///
/// **没有默认值是有意的。** 能量门限是一个带前提的性能优化，前提是「语音与背景
/// 在能量上双模态可分」。这个前提以前是隐含的、没人检查的默认值，于是失效时
/// 静默给出自信的错误答案：2026-09-10 在一集 Re:Zero（内封英文字幕作真值）上
/// 实测，能量门限把 **89.3% 的片长**（219 段 / 1428.1 s）送进 ASR，其中
/// **34.6%（493.7 s）落在任何对白之外**，**31 段（14.2%）整段没有一句对白**
/// ——每一段都是一次幻听机会，而幻听出的 cue 会直接进字幕。让每个调用方显式
/// 签字，才是这个前提唯一可靠的检查方式。
enum AsrAudioProfile {
  /// 干净朗读：语音与静默的能量差 30 dB 以上，构成清晰的双模态分布。
  /// 有声书、录音棚 TTS、口述录音。
  ///
  /// 这是一个**断言**，不是偏好。选错的代价见 [mixedAudio]。
  cleanSpeech,

  /// 混音素材：动画、影视、任何带持续 BGM 或环境声的音源。
  ///
  /// 这类素材上能量门限不是「差一点」，是前提不成立，**调参数救不回来**：
  /// 上述那一集的失败段实测电平分布 p10 −39.3 / p50 −27.3 / p90 −21.8 dBFS，
  /// 整段挤在 17.5 dB 的窄带里，根本没有可供门限落脚的空谷；去掉
  /// [EnergyVadScorer.maxThresholdDb] 的夹紧仍有 158/312 帧判语音，要压到
  /// Silero 那 6/312 帧得把门限推到 −14.9 dBFS（≈本段峰值），代价是全片正常
  /// 对白大面积漏掉。
  ///
  /// 代价已经付过：`silero_vad.onnx` 是每个语言包的必下文件，会话在引擎装载时
  /// 无条件打开（跑能量门限时它也开着），零新依赖、零额外下载。
  mixedAudio,
}

/// 开跑前的计划：哪个语言包、会用哪个编码器变体、期望落到哪个 EP、模型是否就绪。
@immutable
class AsrTranscribePlan {
  const AsrTranscribePlan({
    required this.language,
    required this.variant,
    required this.expectedProvider,
    required this.modelStatus,
    this.probeError,
    this.availableProviders = const <OnnxExecutionProvider>{},
  });

  final AsrLanguage language;
  final AsrEncoderVariant variant;

  /// 按平台策略与本机 EP 集合预期的编码器 EP（真正生效以运行期 resolution 为准）。
  final OnnxExecutionProvider expectedProvider;
  final AsrModelStatus modelStatus;

  /// EP 探测本身抛错时的原因；null = 探测正常（含 cpuOnly 不探测）。
  ///
  /// 探测失败是一条真实的降级路径：有 GPU 的机器探测抛错会被推荐成 int8 · CPU，
  /// 用户按 CPU 速度跑完整本却不知道探测失败过——所以不吞掉，交给 UI 提示
  /// （BUG-1163 同一条纪律）。
  final String? probeError;

  /// 本机运行时探测到的加速 EP（[AsrAccelerationPreference.cpuOnly] 不探测，为
  /// 空）。界面据此决定给不给「DirectML」「CUDA」两个显式选项。
  final Set<OnnxExecutionProvider> availableProviders;

  /// 能不能开始转录 —— 只看识别模型。
  bool get modelReady => modelStatus.ready;

  int get totalModelBytes => modelStatus.totalBytes;
  int get obtainedModelBytes => modelStatus.obtainedBytes;

  /// 开始转录还差多少字节。
  int get bytesToDownload => (totalModelBytes - obtainedModelBytes).clamp(
        0,
        totalModelBytes,
      );
}

/// 一次正在运行的转录。用完必须 [dispose] 释放 native 会话。
///
/// 两个实现：生产走 [AsrIsolateTranscription]（整条链路在后台 isolate，主 isolate
/// 不卡）；[AsrInProcessTranscription] 在当前 isolate 跑，给注入 fake 的测试与
/// 需要直接拿会话的基准用。
abstract interface class AsrRunningTranscription {
  OnnxProviderResolution get encoderResolution;

  /// 贪心 Loop 图是否建成；没建成时 [greedyUnavailableReason] 说明原因。
  bool get greedyGraphAvailable;
  String? get greedyUnavailableReason;

  /// 编码器是否跑在设备端派生的 fp16 图上（见 `AsrEngineSessions.encoderFp16`）。
  bool get encoderFp16;

  /// 任务结束后的分阶段耗时（isolate 路径在 finished / paused 之后才有）。
  AsrDecodeStats? get decodeStats;

  /// 事件流（一次性；见 [AsrTranscribeJob.run]）。
  Stream<AsrTranscribeEvent> run();

  void requestPause({bool discardPending = false});

  Future<void> dispose();
}

/// 在当前 isolate 里跑的转录（会话 + 任务）。
class AsrInProcessTranscription implements AsrRunningTranscription {
  AsrInProcessTranscription({
    required this.sessions,
    required this.job,
    AsrSegmentDecoder? decoder,
  }) : _decoder = decoder;

  final AsrEngineSessions sessions;
  final AsrTranscribeJob job;
  final AsrSegmentDecoder? _decoder;

  @override
  OnnxProviderResolution get encoderResolution => sessions.encoderResolution;

  @override
  bool get greedyGraphAvailable => sessions.greedy != null;

  @override
  String? get greedyUnavailableReason => sessions.greedyUnavailableReason;

  @override
  bool get encoderFp16 => sessions.encoderFp16;

  @override
  AsrDecodeStats? get decodeStats => _decoder?.stats;

  @override
  Stream<AsrTranscribeEvent> run() => job.run();

  @override
  void requestPause({bool discardPending = false}) =>
      job.requestPause(discardPending: discardPending);

  @override
  Future<void> dispose() => sessions.close();
}

/// 装配层。所有依赖可注入以便测试。
class AsrTranscriptionService {
  /// [backend] 是**必填**的：本包不自带 ONNX 后端。它同时服务两条路径——进程内路径
  /// 拿它 new 出工厂给 [AsrEngineLoader]，isolate 路径把它整个送进后台 isolate
  /// （所以它的函数字段只能是顶层 / 静态函数引用，见 [AsrIsolateBackend]）。
  AsrTranscriptionService({
    required AsrIsolateBackend backend,
    AsrEngineLoader? loader,
    AsrPcmSource? pcm,
    Future<AsrModelStore> Function(AsrLanguage language)? openStore,
    Future<Directory> Function()? jobsRoot,
    this.batchSize,
    this.chunkSeconds = 300,
    required this.audioProfile,
    this.runInIsolate = true,
    this.usePipeline = true,
    this.useFp16Encoder = true,
    this.staticBucketsOverride,
    this.greedySessions,
    this.greedyIntraOpThreads,
  })  : _backend = backend,
        _injectedLoader = loader,
        _pcm = pcm ?? FfmpegAsrPcmSource(),
        _openStore = openStore ?? AsrModelStore.open,
        _jobsRoot = jobsRoot ?? _defaultJobsRoot;

  final AsrIsolateBackend _backend;

  /// 注入的装载器；null 时按需从 [_backend] 现建（见 [_loader]）。
  final AsrEngineLoader? _injectedLoader;
  AsrEngineLoader? _lazyLoader;

  /// 引擎装载器，**按需建**。
  ///
  /// 不能在构造函数里急切建：那会让「new 一个服务」隐含要求 ONNX 后端此刻就可用。
  /// 实测代价是子类化这个服务来做 widget 测试时（覆写 plan/start、根本不碰引擎）
  /// 照样会去建后端——11 条 UI 用例因此炸在构造函数里，错因还指向后端而不是测试。
  /// 真正需要装载器的只有进程内路径；isolate 路径的装配整个走 [_backend]。
  AsrEngineLoader get _loader =>
      _injectedLoader ??
      (_lazyLoader ??= AsrEngineLoader(factory: _backend.buildFactory()));
  final AsrPcmSource _pcm;
  final Future<AsrModelStore> Function(AsrLanguage language) _openStore;
  final Future<Directory> Function() _jobsRoot;

  /// 一次 encoder 前向的段数（动态 shape 路径）；null 时按编码器实际落到的 EP 取
  /// [defaultBatchSizeFor]。GPU 静态桶路径下一批行数由桶决定，本值不生效
  /// （见 [AsrTranscribeJob.batchSize]）。
  final int? batchSize;
  final int chunkSeconds;
  /// 见 [AsrAudioProfile]：调用方对素材的断言，**没有默认值**。
  final AsrAudioProfile audioProfile;

  /// 真转录是否下放后台 isolate（生产默认 true）。false 走进程内路径，注入的
  /// [AsrEngineLoader] / [AsrPcmSource] 只在该路径生效——闭包与 fake 会话过不了
  /// isolate 边界。
  final bool runInIsolate;

  /// 见 [AsrTranscribeJob.usePipeline]（基准对照用；生产恒 true）。
  final bool usePipeline;

  /// 静态桶表覆盖（基准 / 调参用；生产为 null，按显存预算选表）。
  final List<AsrEncoderBucket>? staticBucketsOverride;

  /// 见 [AsrEngineLoader.load] 的 `useFp16Encoder`（基准对照用；生产恒 true）。
  final bool useFp16Encoder;

  /// 贪心 Loop 图会话数 / 每会话 intra-op 线程数覆盖（基准扫描用；null 取
  /// [defaultAsrGreedySessionCount] / [kAsrGreedyGraphIntraOpThreads]）。
  final int? greedySessions;
  final int? greedyIntraOpThreads;

  /// 默认批次：GPU 上 batch 越大越省逐帧 joiner 的往返（2026-09-05 真机分阶段计时
  /// 里逐帧循环是 ASR 阶段的大头，encoder 本身在 DirectML 上只占零头）；CPU 上
  /// int8 encoder 的算力随 batch 线性增长，取一半平衡内存与往返。
  static int defaultBatchSizeFor(OnnxExecutionProvider encoderProvider) =>
      encoderProvider == OnnxExecutionProvider.cpu ? 16 : 32;

  /// 本平台是否具备设备端转录能力（= 本地 ONNX Runtime 随包）。
  static bool get isSupported => isLocalOnnxRuntimeAvailable;

  static Future<Directory> _defaultJobsRoot() async {
    final Directory support = await asrSupportRootDirectory();
    return Directory(p.join(support.path, 'asr_jobs'));
  }

  Future<AsrModelStore> modelStore(AsrLanguage language) =>
      _openStore(language);

  /// 计算计划：探测 EP → 推荐变体 → 查该语言包的模型状态。
  Future<AsrTranscribePlan> plan({
    required AsrLanguage language,
    required AsrAccelerationPreference preference,
  }) async {
    Set<OnnxExecutionProvider> available = const <OnnxExecutionProvider>{};
    String? probeError;
    if (preference != AsrAccelerationPreference.cpuOnly) {
      try {
        available = await _loader.availableAcceleratedProviders();
      } catch (error) {
        // 探测失败按 CPU 规划，但原因随计划带给 UI；运行期 loader 会再把它记进
        // resolution.fallbackReason。不允许 catch (_) 静默吞掉。
        available = const <OnnxExecutionProvider>{};
        probeError = '$error';
        developer.log(
          'ASR accelerated provider probe failed; planning for CPU only',
          name: kAsrLogName,
          error: error,
        );
      }
    }
    final AsrPlatform platform = currentAsrPlatform();
    final AsrModelPack pack = asrModelPackFor(language);
    // 有显存门槛的包（Omnilingual 1B）才去查预算；查失败按未知处理 → int8。
    int? budgetBytes;
    if (pack.fp32GpuMinBudgetBytes != null && available.isNotEmpty) {
      try {
        budgetBytes = await _loader.deviceMemoryBudgetBytes();
      } catch (error) {
        developer.log(
          'ASR device memory budget probe failed; assuming unknown',
          name: kAsrLogName,
          error: error,
        );
      }
    }
    final AsrEncoderVariant variant = recommendAsrEncoderVariant(
      platform: platform,
      available: available,
      preference: preference,
      fp32GpuMinBudgetBytes: pack.fp32GpuMinBudgetBytes,
      budgetBytes: budgetBytes,
    );
    final OnnxExecutionProvider expected = selectAsrEncoderProviders(
      platform: platform,
      available: available,
      preference: preference,
      variant: variant,
    ).first;
    final AsrModelStore store = await _openStore(language);
    return AsrTranscribePlan(
      language: language,
      variant: variant,
      expectedProvider: expected,
      modelStatus: await store.status(variant),
      probeError: probeError,
      availableProviders: Set<OnnxExecutionProvider>.unmodifiable(available),
    );
  }

  /// 下载识别模型。
  Stream<ModelDownloadEvent> downloadModel({
    required AsrLanguage language,
    required AsrEncoderVariant variant,
  }) async* {
    final AsrModelStore store = await _openStore(language);
    yield* store.download(variant);
  }

  /// 任务目录：文件名 + 字节数 + 模型包 id 的 SHA-1。
  Future<Directory> jobDirFor(
    List<String> audioPaths,
    AsrLanguage language,
  ) async {
    final Directory root = await _jobsRoot();
    final String id = jobIdFor(audioPaths, language);
    return Directory(p.join(root.path, id));
  }

  /// 纯函数：由文件名、字节数与模型包 id 派生稳定 id（文件不存在按 0 字节计）。
  static String jobIdFor(List<String> audioPaths, AsrLanguage language) {
    final StringBuffer sb = StringBuffer();
    for (final String path in audioPaths) {
      final File f = File(path);
      final int bytes = f.existsSync() ? f.lengthSync() : 0;
      sb
        ..write(p.basename(path))
        ..write('|')
        ..write(bytes)
        ..write('\n');
    }
    sb
      ..write('model=')
      ..write(asrModelPackFor(language).id)
      ..write('\n');
    return sha1.convert(utf8.encode(sb.toString())).toString();
  }

  /// 已有的任务状态（没有则 null）。
  Future<AsrJobState?> existingState(
    List<String> audioPaths,
    AsrLanguage language,
  ) async {
    final Directory dir = await jobDirFor(audioPaths, language);
    if (!File(p.join(dir.path, AsrJobFiles.state)).existsSync()) return null;
    final ({AsrJobState state, bool fresh}) loaded =
        await AsrTranscribeJob.loadStateDetailed(
      dir,
      audioPaths,
      modelId: asrModelPackFor(language).id,
    );
    return loaded.fresh ? null : loaded.state;
  }

  /// 已完成任务的 SRT 路径（未完成或不存在则 null）。
  Future<String?> finishedSrtPath(
    List<String> audioPaths,
    AsrLanguage language,
  ) async {
    final AsrJobState? state = await existingState(audioPaths, language);
    if (state == null || !state.finished) return null;
    final Directory dir = await jobDirFor(audioPaths, language);
    final File srt = File(p.join(dir.path, AsrJobFiles.srt));
    return srt.existsSync() ? srt.path : null;
  }

  /// 该字幕路径是否是本服务转录出来的产物（任务目录里的 `transcript.srt`，
  /// 旁边有 `state.json`）。导入链路据此决定要不要把命中 cue 的文本换成正文
  /// （听写文本换成正文后阅读器 DOM 重定位才精确）。
  static bool isAsrGeneratedSubtitlePath(String path) {
    if (p.basename(path) != AsrJobFiles.srt) return false;
    return File(p.join(p.dirname(path), AsrJobFiles.state)).existsSync();
  }

  /// 读转录产物旁边的逐 token 时间 sidecar（[AsrJobFiles.cueTokens]），按行号与
  /// 从同一份 SRT 解析出来的 cue 一一对应，供匹配后按正文句界重切 cue。
  ///
  /// 不是转录产物、sidecar 缺失 / 损坏、行数与 [expectedCount] 不符时返回 null
  /// ——**一条都不给**：行号错位比没有更糟。
  ///
  /// 抽包前这里直接往调用方的 `AudioCue.tokenTiming` 上写。那把两件事焊死了：
  /// 读 sidecar 是本包的事，往哪种 cue 类型上挂是调用方的事。现在只回读到的行，
  /// 由调用方自己挂到自己的 cue 类型上。
  static Future<List<AsrCueTokenTiming>?> readCueTokenTimings(
    String subtitlePath, {
    required int expectedCount,
  }) async {
    if (!isAsrGeneratedSubtitlePath(subtitlePath)) return null;
    final File sidecar = File(
      p.join(p.dirname(subtitlePath), AsrJobFiles.cueTokens),
    );
    if (!sidecar.existsSync()) return null;
    final List<({List<String> tokens, List<int> offsetsMs})>? rows;
    try {
      rows = parseAsrCueTokens(await sidecar.readAsString());
    } on FileSystemException catch (error) {
      developer.log(
        'ASR cue token sidecar unreadable: ${sidecar.path}',
        name: kAsrLogName,
        error: error,
      );
      return null;
    }
    if (rows == null || rows.length != expectedCount) {
      developer.log(
        'ASR cue token sidecar ignored: rows=${rows?.length} '
        'cues=$expectedCount',
        name: kAsrLogName,
      );
      return null;
    }
    return <AsrCueTokenTiming>[
      for (final ({List<String> tokens, List<int> offsetsMs}) row in rows)
        AsrCueTokenTiming(tokens: row.tokens, offsetsMs: row.offsetsMs),
    ];
  }

  /// 全部音频的总时长（毫秒）；任一文件探不出就返回 null（策略按未知处理，
  /// 不拿部分和冒充总长）。
  Future<int?> _probeMaterialMs(List<String> audioPaths) async {
    int total = 0;
    for (final String path in audioPaths) {
      final int? ms = await _pcm.probeDurationMs(path);
      if (ms == null) return null;
      total += ms;
    }
    return total;
  }

  /// 丢弃该组音频在该语言下的全部转录进度与产物。
  Future<void> discard(List<String> audioPaths, AsrLanguage language) async {
    final Directory dir = await jobDirFor(audioPaths, language);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// 装载引擎并构造任务（不开跑；调用方订阅 [AsrRunningTranscription.run]）。
  Future<AsrRunningTranscription> start({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
  }) async {
    final AsrModelStore store = await _openStore(language);
    final Directory jobDir = await jobDirFor(audioPaths, language);
    // 素材总时长（探测失败的文件按未知处理）：决定装载时预热几个静态桶。
    final int? materialMs = await _probeMaterialMs(audioPaths);
    if (runInIsolate) {
      return AsrIsolateTranscription.spawn(
        pcm: _pcm,
        backend: _backend,
        AsrIsolateJobSpec(
          storeDirPath: store.dir.path,
          pack: store.pack,
          language: language,
          variant: variant,
          preference: preference,
          audioPaths: List<String>.unmodifiable(audioPaths),
          jobDirPath: jobDir.path,
          chunkSeconds: chunkSeconds,
          audioProfile: audioProfile,
          batchSize: batchSize,
          usePipeline: usePipeline,
          useFp16Encoder: useFp16Encoder,
          staticBucketsOverride: staticBucketsOverride,
          materialMs: materialMs,
          greedySessions: greedySessions,
          greedyIntraOpThreads: greedyIntraOpThreads,
        ),
      );
    }
    final AsrEngineSessions sessions = await _loader.load(
      store: store,
      variant: variant,
      preference: preference,
      useFp16Encoder: useFp16Encoder,
      staticBucketsOverride: staticBucketsOverride,
      materialMs: materialMs,
      greedySessions: greedySessions,
      greedyIntraOpThreads:
          greedyIntraOpThreads ?? kAsrGreedyGraphIntraOpThreads,
    );
    try {
      final AsrSegmentDecoder decoder = sessions.newDecoder()..warmUp();
      final int maxSegmentMs = sessions.maxSegmentMs;
      final AsrTranscribeJob job = AsrTranscribeJob(
        jobDir: jobDir,
        audioPaths: audioPaths,
        modelId: store.pack.id,
        pcm: _pcm,
        segmenter: switch (audioProfile) {
          // 干净朗读：语音与静默双模态可分，纯 Dart 能量门限够用且免掉每窗口
          // 一次 ONNX 前向（有声书上实测占整条流水线七成）。
          AsrAudioProfile.cleanSpeech => AsrVadSegmenter(
              scorer: EnergyVadScorer(),
              maxSegmentMs: maxSegmentMs,
            ),
          // 混音素材：能量门限的前提不成立，只能用神经网络 VAD。
          AsrAudioProfile.mixedAudio => AsrVadSegmenter(
              session: sessions.vad,
              maxSegmentMs: maxSegmentMs,
            ),
        },
        decoder: decoder,
        batchSize: batchSize ??
            defaultBatchSizeFor(sessions.encoderResolution.effective),
        chunkSeconds: chunkSeconds,
        statsProvider: () => decoder.stats,
        usePipeline: usePipeline,
      );
      return AsrInProcessTranscription(
        sessions: sessions,
        job: job,
        decoder: decoder,
      );
    } catch (_) {
      await sessions.close();
      rethrow;
    }
  }
}
