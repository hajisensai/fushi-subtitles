/// 有声书 ASR 引擎装载：执行后端（EP）选择策略 + 四个 ONNX 会话的创建与释放。
///
/// 策略是纯函数（[selectAsrEncoderProviders] / [recommendAsrEncoderVariant]），
/// IO 只在 [AsrEngineLoader]。会话抽象来自共享层 `onnx_inference.dart`，真实现是
/// 由宿主注入（桌面/服务端是 `fushi_asr_onnx_ffi` 的 FFI 工厂，Flutter 宿主是插件工厂）。
library;

import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_ctc_decoder.dart';
import 'package:fushi_asr_core/src/asr/asr_encoder_buckets.dart';
import 'package:fushi_asr_core/src/asr/asr_fp16_graph.dart';
import 'package:fushi_asr_core/src/asr/asr_greedy_graph.dart';
import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_model_store.dart';
import 'package:fushi_asr_core/src/asr/asr_nemo_mel.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart' show AsrSegmentDecoder;
import 'package:fushi_asr_core/src/asr/asr_transducer_decoder.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/asr/asr_vad.dart' show kAsrDefaultMaxSegmentMs;
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';

/// 本子系统的 `dart:developer` 日志通道名（整本转录跑在后台 isolate，理由同
/// `kOnnxLogName`）。
export 'package:fushi_asr_core/src/asr/asr_types.dart' show kAsrLogName;

/// 加速偏好：自动、CPU，或显式选择 macOS FP32 CoreML。
///
/// [directml] / [cuda]：Windows 上显式指定 GPU 后端（[auto] 在两者都可用时取
/// CUDA，见 [selectAsrEncoderProviders]）。与 [coreml] 同一约定：指定了却不可用
/// 时策略函数直接抛——界面只在探测到可用时才给这两个选项。
enum AsrAccelerationPreference { auto, cpuOnly, coreml, directml, cuda }

/// 平台（纯枚举入参，保持策略函数可测纯函数）。
enum AsrPlatform { windows, macos, ios, linux, android }

/// 当前进程所在平台。Fushi 只出这五端，其余（fuchsia 等）直接抛——静默映射到
/// 某一端会让策略在没验证过的平台上装作有依据。
AsrPlatform currentAsrPlatform() {
  if (Platform.isWindows) return AsrPlatform.windows;
  if (Platform.isMacOS) return AsrPlatform.macos;
  if (Platform.isIOS) return AsrPlatform.ios;
  if (Platform.isLinux) return AsrPlatform.linux;
  if (Platform.isAndroid) return AsrPlatform.android;
  throw UnsupportedError(
    'ASR has no execution provider policy for ${Platform.operatingSystem}',
  );
}

/// 编码器的 EP 列表（首项为首选，末项永远是 CPU 兜底）。
///
/// 策略依据是 `ocr_inference.dart` 里 BUG-2050 / BUG-1613 的本机实测（同一个
/// ORT 运行时、同一批 EP），ASR 编码器是单次前向的大模型，与 OCR 检测器同型：
///
/// | 平台 | fp32 编码器 | int8 编码器 |
/// |---|---|---|
/// | Windows | cuda（若 available）→ directml（若 available）→ 否则 CPU | CPU |
/// | macOS / iOS | CPU（CoreML 默认不开，见下） | CPU |
/// | Linux / Android | CPU | CPU |
///
/// - **GPU EP 只给 fp32 编码器**。BUG-2050 实测：int8 量化模型在 ORT 1.22.0 的
///   DirectML EP 上根本建不出会话（`MLOperatorAuthorImpl.cpp(2851)`
///   `E_INVALIDARG`），而同架构 fp32 档建得起来且比 CPU 快 19.4 倍。请求一个注定
///   失败的 EP 只是白付一次建会话再退 CPU，所以 int8 直接 CPU。
/// - **Windows：DirectML 若 available 就用**。这与 OCR 的「一个加速 EP 都不要」
///   不矛盾——OCR 排除 DirectML 的两条理由（int8 检测器建不出会话 / 自回归识别
///   负优化）在这里分别由「只给 fp32」和「decoder/joiner 恒 CPU」（见
///   [AsrEngineLoader.load]）消掉；592 MB 的 fp32 编码器一次前向吃整段音频，正是
///   fp32 检测器那 19.4 倍加速的形态。CUDA 在我们出的 ORT NuGet 里不存在
///   （`microsoft.ml.onnxruntime.directml`，见 `ocr_inference.dart`），但若
///   available 集合里真有它——将来换了带 CUDA EP 的包——就优先于 DirectML。
/// - **macOS：auto 仍推荐 INT8 CPU；coreml 显式请求 FP32 CoreML**。
///   M4 日语实测动态图分成 263 个 CoreML 子图，整段速度慢于 INT8 CPU，
///   因此不把实验后端作为自动默认。iOS 尚未验证，仍保持 CPU。
/// - Linux / Android：CPU。
/// - [AsrAccelerationPreference.cpuOnly] 恒 CPU。
/// - 任何加速 EP 后面永远缀 CPU 兜底：运行期建不出会话由
///   `createOnnxSessionWithProviderFallback` 退到 CPU（BUG-2034）。
List<OnnxExecutionProvider> selectAsrEncoderProviders({
  required AsrPlatform platform,
  required Set<OnnxExecutionProvider> available,
  required AsrAccelerationPreference preference,
  required AsrEncoderVariant variant,
}) {
  const List<OnnxExecutionProvider> cpuOnly = <OnnxExecutionProvider>[
    OnnxExecutionProvider.cpu,
  ];
  if (preference == AsrAccelerationPreference.cpuOnly) return cpuOnly;
  if (variant != AsrEncoderVariant.fp32) return cpuOnly;
  if (preference == AsrAccelerationPreference.coreml) {
    if (platform != AsrPlatform.macos ||
        !available.contains(OnnxExecutionProvider.coreml)) {
      throw UnsupportedError(
          'Requested CoreML is unavailable on this platform/runtime');
    }
    return const [OnnxExecutionProvider.coreml, OnnxExecutionProvider.cpu];
  }
  if (preference == AsrAccelerationPreference.directml ||
      preference == AsrAccelerationPreference.cuda) {
    final OnnxExecutionProvider wanted =
        preference == AsrAccelerationPreference.cuda
        ? OnnxExecutionProvider.cuda
        : OnnxExecutionProvider.directml;
    if (platform != AsrPlatform.windows || !available.contains(wanted)) {
      throw UnsupportedError(
        'Requested ${wanted.name} is unavailable on this platform/runtime',
      );
    }
    return <OnnxExecutionProvider>[wanted, OnnxExecutionProvider.cpu];
  }
  final List<OnnxExecutionProvider> preferenceOrder = switch (platform) {
    AsrPlatform.windows => const <OnnxExecutionProvider>[
        OnnxExecutionProvider.cuda,
        OnnxExecutionProvider.directml,
      ],
    // 自动模式保留 CPU；macOS CoreML 由上面的显式分支选择。
    AsrPlatform.macos ||
    AsrPlatform.ios ||
    AsrPlatform.linux ||
    AsrPlatform.android =>
      const <OnnxExecutionProvider>[],
  };
  for (final OnnxExecutionProvider candidate in preferenceOrder) {
    if (!available.contains(candidate)) continue;
    return <OnnxExecutionProvider>[candidate, OnnxExecutionProvider.cpu];
  }
  return cpuOnly;
}

/// fp16 编码器只给这些 EP：GPU 张量核对半精度有真实内核收益（DirectML 上
/// zipformer 静态桶实测见 `asr_fp16_graph.dart`），且权重与融合图的中间张量都
/// 减半——多桶共存时显存不再那么容易溢出。CPU 上 ORT 的 fp16 算子覆盖不全、
/// 也没有速度收益，fp16 会话真落到 CPU 时必须换回 fp32（见
/// [AsrEngineLoader._openEncoder]）。
const Set<OnnxExecutionProvider> kAsrFp16Providers = <OnnxExecutionProvider>{
  OnnxExecutionProvider.directml,
  OnnxExecutionProvider.cuda,
};

/// 装载时要不要把全部静态桶建好（纯函数，可测）。
///
/// 三个条件同时成立才全预热：
/// - [buckets] 是全桶表（[kAsrGpuEncoderBuckets] / [kAsrGpuEncoderBucketsLarge]）
///   ——半桶表本来就是预算吃紧的信号；
/// - [budgetBytes] 已知（≥ 10 GiB 才会拿到全桶表，两桶常驻峰值 6.6~7.6 GB 实测过）；
/// - [materialMs] 已知且 ≥ [kAsrPrewarmAllMinMaterialMs]：每桶 3~8 s 的建桶只有在
///   素材够长时才摊得平——5 分钟片段本身只转 2~3 s，为省几百毫秒 padding 先花
///   8 s 建大桶是净亏。
bool shouldPrewarmAllStaticBuckets({
  required List<AsrEncoderBucket> buckets,
  required int? budgetBytes,
  required int? materialMs,
}) {
  if (!_isFullBucketTable(buckets)) return false;
  if (budgetBytes == null) return false;
  if (materialMs == null) return false;
  return materialMs >= kAsrPrewarmAllMinMaterialMs;
}

/// [buckets] 是不是一张「全桶表」：帧数档位与某张全表逐项相同、每档行数不少于
/// 它（fp16 表由全表按 [kAsrFp16BucketRowFactor] 放大行数派生，也算全表；半桶表
/// 帧数相同但行数减半，不算）。按结构判而不按对象身份判，派生表才不会被当成
/// 「预算吃紧」。
bool _isFullBucketTable(List<AsrEncoderBucket> buckets) {
  const List<List<AsrEncoderBucket>> fullTables = <List<AsrEncoderBucket>>[
    kAsrGpuEncoderBuckets,
    kAsrGpuEncoderBucketsLarge,
    kAsrCtcGpuBuckets,
  ];
  for (final List<AsrEncoderBucket> full in fullTables) {
    if (full.length != buckets.length) continue;
    bool same = true;
    for (int i = 0; i < full.length && same; i++) {
      same = buckets[i].frames == full[i].frames &&
          buckets[i].batch >= full[i].batch;
    }
    if (same) return true;
  }
  return false;
}

/// 全预热的素材时长门槛：15 分钟。RTX 4070 Ti 上 30 分钟英语按需建大桶要多付
/// ~4 s（wall 6 s → 10 s），15 分钟约多付 2 s，与提前建桶的 3~8 s 打平。
const int kAsrPrewarmAllMinMaterialMs = 15 * 60 * 1000;

/// 推荐下载 / 加载哪个编码器变体：会选到 GPU EP 就 fp32，否则 int8。
///
/// fp32 比 int8 大 437 MB，只有 GPU 能把这笔磁盘换成速度；CPU 上 int8 反而更快
/// （BUG-2050 对照：int8 CPU 81.5 ms vs fp32 CPU 419.4 ms）。
///
/// [fp32GpuMinBudgetBytes]（`AsrModelPack.fp32GpuMinBudgetBytes`）给了时，
/// GPU 显存预算 [budgetBytes] 未知或不足就退回 int8：Omnilingual 1B fp32 的 3.9 GB
/// 权重塞进 6 GB 卡会溢出到主机内存，比 CPU int8 还慢且照不到回退。
AsrEncoderVariant recommendAsrEncoderVariant({
  required AsrPlatform platform,
  required Set<OnnxExecutionProvider> available,
  required AsrAccelerationPreference preference,
  int? fp32GpuMinBudgetBytes,
  int? budgetBytes,
}) {
  final List<OnnxExecutionProvider> providers = selectAsrEncoderProviders(
    platform: platform,
    available: available,
    preference: preference,
    variant: AsrEncoderVariant.fp32,
  );
  if (providers.first == OnnxExecutionProvider.cpu) {
    return AsrEncoderVariant.int8;
  }
  if (fp32GpuMinBudgetBytes != null &&
      (budgetBytes == null || budgetBytes < fp32GpuMinBudgetBytes)) {
    return AsrEncoderVariant.int8;
  }
  return AsrEncoderVariant.fp32;
}

/// 一套已装载的 ASR 会话。
class AsrEngineSessions {
  AsrEngineSessions({
    required this.encoder,
    required this.vad,
    required this.tokens,
    required this.variant,
    required this.encoderResolution,
    this.architecture = AsrModelArchitecture.transducer,
    this.decoder,
    this.joiner,
    this.greedy,
    this.greedyPool = const <OnnxSession>[],
    this.greedyUnavailableReason,
    this.staticEncoders,
    this.decoderContextSize = kAsrDecoderContextSize,
    this.indexType = AsrIndexType.int64,
    this.encoderFp16 = false,
    this.nemoMel,
  }) : assert(
         architecture == AsrModelArchitecture.ctc ||
             (decoder != null && joiner != null),
         'transducer 需要 decoder / joiner 会话',
       );

  /// 同一套会话、换一个 EP 解析说明（健康检查回退时把原因记上去）。
  AsrEngineSessions withEncoderResolution(OnnxProviderResolution resolution) =>
      AsrEngineSessions(
        encoder: encoder,
        vad: vad,
        tokens: tokens,
        variant: variant,
        encoderResolution: resolution,
        architecture: architecture,
        decoder: decoder,
        joiner: joiner,
        greedy: greedy,
        greedyPool: greedyPool,
        greedyUnavailableReason: greedyUnavailableReason,
        staticEncoders: staticEncoders,
        decoderContextSize: decoderContextSize,
        indexType: indexType,
        encoderFp16: encoderFp16,
        nemoMel: nemoMel,
      );

  /// 模型包架构：决定 [newDecoder] 装哪种解码器、[maxSegmentMs] 取哪档。
  final AsrModelArchitecture architecture;

  /// transducer 的 encoder；CTC 的整个模型。
  final OnnxSession encoder;

  /// transducer 专有（CTC 为 null）。
  final OnnxSession? decoder;
  final OnnxSession? joiner;
  final OnnxSession vad;
  final AsrTokenTable tokens;
  final AsrEncoderVariant variant;

  /// 模型包契约（`AsrModelPack.decoderContextSize` / `indexType`），随会话一起
  /// 交给解码器。
  final int decoderContextSize;
  final AsrIndexType indexType;

  /// CTC 包的 NeMo mel 前端（`AsrCtcFrontend.nemoMel80`，Kitsune）；波形前端为
  /// null。
  final AsrNemoMel? nemoMel;

  /// 用本套会话构造批量解码器。in-process 与 isolate 两条装配路径都从这里拿，
  /// 包契约参数只在此处传递一次。
  AsrSegmentDecoder newDecoder() => switch (architecture) {
    AsrModelArchitecture.transducer => AsrTransducerDecoder(
      encoder: encoder,
      decoder: decoder!,
      joiner: joiner!,
      tokens: tokens,
      greedy: greedy,
      greedyPool: greedyPool,
      staticEncoders: staticEncoders,
      contextSize: decoderContextSize,
      indexType: indexType,
    ),
    AsrModelArchitecture.ctc => AsrCtcDecoder(
      model: encoder,
      tokens: tokens,
      staticSessions: staticEncoders,
      nemoMel: nemoMel,
    ),
  };

  /// VAD 单段上限：zipformer 静态桶把段切到 10 s（见 [kAsrStaticMaxSegmentMs]），
  /// CTC 桶按 21 s 建、Omnilingual 本身吃得下 40 s，保持 VAD 默认 20 s。
  ///
  /// NeMo mel 前端（Kitsune）也取 10 s：评测与 SubThx 都按 ≤ 10 s 段跑，段越长
  /// 一批补零越多。
  int get maxSegmentMs =>
      (architecture == AsrModelArchitecture.transducer &&
              staticEncoders != null) ||
          nemoMel != null
      ? kAsrStaticMaxSegmentMs
      : kAsrDefaultMaxSegmentMs;

  /// 派生的贪心 Loop 图会话（CPU）；null 表示拼装/建会话失败，解码器回退到
  /// Dart 逐帧循环（结果等价，只是慢）。回退不静默：原因在
  /// [greedyUnavailableReason]，UI/日志据此提示。
  final OnnxSession? greedy;
  final String? greedyUnavailableReason;

  /// 同一张贪心 Loop 图的**额外**会话：解码器把一批的行均分给
  /// `[greedy, ...greedyPool]` 并行搜（`AsrTransducerDecoder`）。每个会话在
  /// 插件里各占一条 CPU 工作线程，intra-op 各 [kAsrGreedyGraphIntraOpThreads]。
  final List<OnnxSession> greedyPool;

  /// 编码器实际落到的 EP 与（若有）降级原因——降级必须可观测（BUG-1163）。
  final OnnxProviderResolution encoderResolution;

  /// 编码器（含静态桶）跑的是设备端派生的 fp16 图（`asr_fp16_graph.dart`）。
  /// 只在 [kAsrFp16Providers] 的 EP 上为 true；转换或建会话失败回退 fp32 时为
  /// false 并有日志。
  final bool encoderFp16;

  /// GPU 静态 shape 编码器桶池（只在编码器真落到 GPU EP 时有）；桶按需建、建
  /// 失败回退 [encoder]。
  final AsrStaticEncoderPool? staticEncoders;

  Future<void> close() async {
    await staticEncoders?.close();
    await encoder.close();
    await decoder?.close();
    await joiner?.close();
    await vad.close();
    await greedy?.close();
    for (final OnnxSession s in greedyPool) {
      await s.close();
    }
  }
}

/// 贪心 Loop 图会话数：≥ 8 逻辑核开两个（各 [kAsrGreedyGraphIntraOpThreads]
/// 线程），一批的行对半并行搜；核少时一个。
int defaultAsrGreedySessionCount() => Platform.numberOfProcessors >= 8 ? 2 : 1;

/// 贪心 Loop 图会话的 intra-op 线程数默认值。图里每帧都是 N×512 级别的小矩阵，
/// ORT 默认把全部核心都拉起来做线程同步反而拖慢（Python 侧 int8 N8T250：默认
/// 全核 111 ms，2~4 线程 45 ms）；具体取值以真机扫描为准，见
/// `integration_test/asr_directml_session_lifecycle_itest.dart`。
const int kAsrGreedyGraphIntraOpThreads = 4;

/// 从 [AsrModelStore] 装载四个会话 + 词表。
class AsrEngineLoader {
  /// [platform] 只为可测性存在：EP 选择策略是按平台分档的
  /// （[selectAsrEncoderProviders]），而「注入了 available EP 却仍按宿主平台
  /// 判档」会让「DirectML 该被选中」这类用例在 Windows 上绿、在 Linux CI 上红
  /// —— 判据里混进了一个测试无法控制的量。生产路径不传，取宿主真值。
  ///
  /// [factory] 是**必填**的：本包不自带 ONNX 后端。桌面 / 服务端注入
  /// `fushi_asr_onnx_ffi` 的 FFI 工厂，Flutter 宿主注入插件工厂（`OrtOnnxSessionFactory`）。
  /// 抽包前这里默认 new 一个插件工厂，那条默认值正是把整条依赖链钉死在 Flutter 上
  /// 的东西。
  AsrEngineLoader({required OnnxSessionFactory factory, AsrPlatform? platform})
    : _factory = factory,
      _platform = platform;

  final OnnxSessionFactory _factory;
  final AsrPlatform? _platform;

  AsrPlatform get _resolvedPlatform => _platform ?? currentAsrPlatform();

  /// 本机 ORT 运行时编译进来的加速 EP（语义边界见
  /// [OnnxSessionFactory.availableAcceleratedProviders]；不吞异常）。
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() =>
      _factory.availableAcceleratedProviders();

  /// 本进程 GPU 显存预算（字节；查不到为 null），给 `AsrModelPack.
  /// fp32GpuMinBudgetBytes` 门槛用。
  Future<int?> deviceMemoryBudgetBytes() => _factory.deviceMemoryBudgetBytes();

  /// 装载。编码器按 [selectAsrEncoderProviders] 选出的 EP 建（经共享的
  /// provider 回退，resolution 记入 [AsrEngineSessions.encoderResolution]）；
  /// decoder / joiner / vad **恒 CPU**——自回归小 batch 逐帧调用，GPU 往返是负
  /// 优化（OCR 识别器实测同理，见 `ocr_inference.dart`）。
  ///
  /// EP 探测本身抛错时按 CPU 装载，但把探测错误写进 `encoderResolution.
  /// fallbackReason`——有 N 卡也会退到 CPU 是一条真实降级，不允许静默
  /// （BUG-1163）。[AsrAccelerationPreference.cpuOnly] 不探测。
  ///
  /// 中途任一会话建失败时已建成的会话全部关闭再抛，不留 native 泄漏。
  ///
  /// 编码器落在 CUDA 上时装载完先试解码一段合成音频（[_cudaHealthCheck]）：
  /// cuDNN 缺失 / 版本不对时 ORT 建会话**不报错**，要到第一次 Run 的 Conv 才失败
  /// （2026-10-15 plugin EP 实测）。试跑失败就整套关掉、排除 CUDA 重装（显式选了
  /// CUDA 也一样退到 DirectML / CPU），原因记进 `encoderResolution`——不静默。
  Future<AsrEngineSessions> load({
    required AsrModelStore store,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
    bool useGreedyGraph = true,
    bool useStaticEncoderBuckets = true,
    bool useFp16Encoder = true,
    List<AsrEncoderBucket>? staticBucketsOverride,
    int? materialMs,
    int? greedyIntraOpThreads = kAsrGreedyGraphIntraOpThreads,
    int? greedySessions,
  }) async {
    Future<AsrEngineSessions> once(
      AsrAccelerationPreference pref,
      Set<OnnxExecutionProvider> excluded,
    ) =>
        _loadOnce(
          store: store,
          variant: variant,
          preference: pref,
          excluded: excluded,
          useGreedyGraph: useGreedyGraph,
          useStaticEncoderBuckets: useStaticEncoderBuckets,
          useFp16Encoder: useFp16Encoder,
          staticBucketsOverride: staticBucketsOverride,
          materialMs: materialMs,
          greedyIntraOpThreads: greedyIntraOpThreads,
          greedySessions: greedySessions,
        );
    final AsrEngineSessions sessions =
        await once(preference, const <OnnxExecutionProvider>{});
    if (sessions.encoderResolution.effective != OnnxExecutionProvider.cuda) {
      return sessions;
    }
    final Object? failure = await _cudaHealthCheck(sessions);
    if (failure == null) return sessions;
    developer.log(
      'ASR CUDA health check failed; reloading without CUDA',
      name: kAsrLogName,
      error: failure,
    );
    await sessions.close();
    final AsrEngineSessions retry = await once(
      AsrAccelerationPreference.auto,
      const <OnnxExecutionProvider>{OnnxExecutionProvider.cuda},
    );
    final OnnxProviderResolution r = retry.encoderResolution;
    return retry.withEncoderResolution(
      OnnxProviderResolution(
        requested: <OnnxExecutionProvider>[
          OnnxExecutionProvider.cuda,
          ...r.requested,
        ],
        effective: r.effective,
        fallbackReason: <String>[
          'CUDA health check failed: $failure',
          if (r.fallbackReason != null) r.fallbackReason!,
        ].join('; '),
      ),
    );
  }

  /// 一秒合成音频（低电平正弦）走一遍完整解码；返回错误，成功为 null。
  static Future<Object?> _cudaHealthCheck(AsrEngineSessions sessions) async {
    final Float32List x = Float32List(kAsrSampleRate);
    for (int i = 0; i < x.length; i++) {
      x[i] = 0.05 * math.sin(2 * math.pi * 220 * i / kAsrSampleRate);
    }
    try {
      await sessions.newDecoder().decodeBatch(<AsrSpeechSegment>[
        AsrSpeechSegment(startSample: 0, samples: x),
      ]);
      return null;
    } catch (error) {
      return error;
    }
  }

  Future<AsrEngineSessions> _loadOnce({
    required AsrModelStore store,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
    required Set<OnnxExecutionProvider> excluded,
    required bool useGreedyGraph,
    required bool useStaticEncoderBuckets,
    required bool useFp16Encoder,
    required List<AsrEncoderBucket>? staticBucketsOverride,
    required int? materialMs,
    required int? greedyIntraOpThreads,
    required int? greedySessions,
  }) async {
    Set<OnnxExecutionProvider> available = const <OnnxExecutionProvider>{};
    Object? probeError;
    if (preference != AsrAccelerationPreference.cpuOnly) {
      try {
        available = (await _factory.availableAcceleratedProviders()).difference(
          excluded,
        );
      } catch (error) {
        probeError = error;
        developer.log(
          'ASR accelerated provider probe failed; assuming CPU only',
          name: kAsrLogName,
          error: error,
        );
      }
    }
    final List<OnnxExecutionProvider> encoderProviders =
        selectAsrEncoderProviders(
          platform: _resolvedPlatform,
          available: available,
          preference: preference,
          variant: variant,
        );
    const List<OnnxExecutionProvider> cpu = <OnnxExecutionProvider>[
      OnnxExecutionProvider.cpu,
    ];
    if (store.pack.architecture == AsrModelArchitecture.ctc) {
      return _loadCtc(
        store: store,
        variant: variant,
        providers: encoderProviders,
        probeError: probeError,
        useStaticEncoderBuckets: useStaticEncoderBuckets,
        useFp16Encoder: useFp16Encoder,
        staticBucketsOverride: staticBucketsOverride,
        materialMs: materialMs,
      );
    }
    final AsrModelRole encoderRole = asrEncoderRole(variant);

    final List<OnnxSession> opened = <OnnxSession>[];
    Future<void> closeOpened() async {
      for (final OnnxSession session in opened) {
        await session.close();
      }
    }

    try {
      final _OpenedEncoder openedEncoder = await _openEncoder(
        store: store,
        role: encoderRole,
        providers: encoderProviders,
        useFp16: useFp16Encoder && variant == AsrEncoderVariant.fp32,
      );
      final OnnxSession encoder = openedEncoder.session;
      opened.add(encoder);
      final OnnxProviderResolution encoderResolution = _withProbeError(
        openedEncoder.resolution,
        probeError,
      );
      final OnnxSession decoder = await _openManifestSession(
        store,
        asrDecoderRole(variant),
        providers: cpu,
      );
      opened.add(decoder);
      final OnnxSession joiner = await _openManifestSession(
        store,
        asrJoinerRole(variant),
        providers: cpu,
      );
      opened.add(joiner);
      final OnnxSession vad = await _openManifestSession(
        store,
        AsrModelRole.vad,
        providers: cpu,
      );
      opened.add(vad);
      final AsrTokenTable tokens = AsrTokenTable.parse(
        await store.fileFor(AsrModelRole.tokens).readAsString(),
        blankToken: store.pack.blankToken,
      );
      // 贪心 Loop 图：拼装或建会话失败都不致命——逐帧路径永远在，但要把原因
      // 留下来（速度差一个量级，用户看到慢要能知道为什么）。
      OnnxSession? greedy;
      final List<OnnxSession> greedyPool = <OnnxSession>[];
      String? greedyUnavailableReason;
      if (useGreedyGraph) {
        try {
          final File graphFile = await store.ensureGreedyGraph(
            variant,
            build: buildAsrGreedyGraph,
            blankId: tokens.blankId,
            unkId: tokens.unkId,
          );
          greedy = await _factory.createSession(
            graphFile.path,
            providers: cpu,
            intraOpNumThreads: greedyIntraOpThreads,
          );
          opened.add(greedy);
          final int sessions = greedySessions ?? defaultAsrGreedySessionCount();
          for (int i = 1; i < sessions; i++) {
            final OnnxSession extra = await _factory.createSession(
              graphFile.path,
              providers: cpu,
              intraOpNumThreads: greedyIntraOpThreads,
            );
            opened.add(extra);
            greedyPool.add(extra);
          }
        } catch (error, stack) {
          greedyUnavailableReason = '$error';
          developer.log(
            'ASR greedy graph unavailable; falling back to per-frame decoding',
            name: kAsrLogName,
            error: error,
            stackTrace: stack,
          );
        }
      }
      // 静态 shape 桶只给**真的实现了 free-dimension override 的后端**。判据是
      // 白名单不是黑名单（`!= cpu` 会在别处开新 EP 时自动把桶发给它）：
      // `freeDimensionOverrides` 只有 vendored flutter_onnxruntime 的 Windows
      // 插件读，别的平台插件收到这个 key 直接忽略（third_party/
      // flutter_onnxruntime/PATCHES.md delta #8）。一旦按 BUG-1613 把 CoreML
      // 打开，黑名单写法会让 Apple 端拿到一个「桶建得成、run 也不失败（动态
      // shape 收得下静态形状）、零收益、且永远不触发回退」的池子：多占两份
      // 编码器权重、x 白 pad 到桶的 T、VAD 还被砍到 10 s。
      final OnnxExecutionProvider effective = encoderResolution.effective;
      AsrStaticEncoderPool? staticEncoders;
      if (useStaticEncoderBuckets &&
          kAsrStaticBucketProviders.contains(effective)) {
        final int? budget = await _factory.deviceMemoryBudgetBytes();
        // 桶表：基准 / 调参用的显式覆盖优先，否则按显存预算选。
        final List<AsrEncoderBucket> buckets =
            staticBucketsOverride ??
            asrEncoderBucketsForBudget(budget, fp16: openedEncoder.fp16);
        developer.log(
          'ASR static encoder buckets for GPU budget '
          '${budget == null ? 'unknown' : '${budget ~/ (1024 * 1024)} MiB'}'
          '${openedEncoder.fp16 ? ' (fp16 rows x$kAsrFp16BucketRowFactor)' : ''}: '
          '$buckets',
          name: kAsrLogName,
        );
        if (buckets.isNotEmpty) {
          staticEncoders = AsrStaticEncoderPool(
            factory: _factory,
            modelPath: openedEncoder.modelPath,
            providers: <OnnxExecutionProvider>[effective],
            buckets: buckets,
            logName: kAsrLogName,
          );
          // 预热策略（见 [shouldPrewarmAllStaticBuckets]）：素材够长且预算够放整张
          // 桶表时全部预热并等建完——每桶 3~8 s，留到转录中途按需建会在 GPU 队列上
          // 把编码停住同样久，且进度 / ETA 会把停顿算成转录速度；短素材或预算不足
          // 时只预热最小桶，大桶按需建（`sessionFor` 本来就是惰性的）。显存不够时
          // DML **不抛异常**——它溢出到主机内存、RSS 暴涨到被系统杀掉，回退机制照
          // 不到这条路径，所以预算这道门必须在建桶之前。
          if (staticBucketsOverride != null ||
              shouldPrewarmAllStaticBuckets(
                buckets: buckets,
                budgetBytes: budget,
                materialMs: materialMs,
              )) {
            await staticEncoders.prewarmAll();
          } else {
            await staticEncoders.prewarmSmallest();
          }
        }
      }
      developer.log(
        'ASR engine loaded (${variant.name} encoder'
        '${openedEncoder.fp16 ? ', fp16' : ''}): $encoderResolution '
        'greedyGraph=${greedy != null}'
        '${greedy != null ? ' x${1 + greedyPool.length}' : ''} '
        'staticBuckets=${staticEncoders != null}',
        name: kAsrLogName,
      );
      return AsrEngineSessions(
        encoderFp16: openedEncoder.fp16,
        greedy: greedy,
        greedyPool: greedyPool,
        greedyUnavailableReason: greedyUnavailableReason,
        staticEncoders: staticEncoders,
        encoder: encoder,
        decoder: decoder,
        joiner: joiner,
        vad: vad,
        tokens: tokens,
        variant: variant,
        encoderResolution: encoderResolution,
        decoderContextSize: store.pack.decoderContextSize,
        indexType: store.pack.indexType,
      );
    } catch (_) {
      await closeOpened();
      rethrow;
    }
  }

  /// CTC 包：一个模型会话（fp32 走 GPU EP、int8 走 CPU）+ VAD + 词表。GPU 上按
  /// 样本数建静态桶（[kAsrCtcGpuBuckets]，`N` / `num_samples` 钉死，无哨兵行），
  /// 预热策略与 transducer 相同。
  Future<AsrEngineSessions> _loadCtc({
    required AsrModelStore store,
    required AsrEncoderVariant variant,
    required List<OnnxExecutionProvider> providers,
    required Object? probeError,
    required bool useStaticEncoderBuckets,
    required bool useFp16Encoder,
    required List<AsrEncoderBucket>? staticBucketsOverride,
    required int? materialMs,
  }) async {
    const List<OnnxExecutionProvider> cpu = <OnnxExecutionProvider>[
      OnnxExecutionProvider.cpu,
    ];
    final List<OnnxSession> opened = <OnnxSession>[];
    // NeMo mel 前端（Kitsune）：GPU 文件本身就是混合精度导出，不再派生 fp16；
    // 输入维度名与波形桶不同，不建样本数静态桶（动态会话 + 批内 1 s 取整）。
    final bool nemo = store.pack.ctcFrontend == AsrCtcFrontend.nemoMel80;
    try {
      final AsrNemoMel? nemoMel = nemo
          ? AsrNemoMel.fromNpy(
              await store.fileFor(AsrModelRole.melFilterbank).readAsBytes(),
            )
          : null;
      final _OpenedEncoder openedEncoder = await _openEncoder(
        store: store,
        role: asrCtcModelRole(variant),
        providers: providers,
        useFp16: !nemo && useFp16Encoder && variant == AsrEncoderVariant.fp32,
      );
      final OnnxSession model = openedEncoder.session;
      final String modelPath = openedEncoder.modelPath;
      opened.add(model);
      final OnnxProviderResolution modelResolution = _withProbeError(
        openedEncoder.resolution,
        probeError,
      );
      final OnnxSession vad = await _openManifestSession(
        store,
        AsrModelRole.vad,
        providers: cpu,
      );
      opened.add(vad);
      final AsrTokenTable tokens = AsrTokenTable.parse(
        await store.fileFor(AsrModelRole.tokens).readAsString(),
        blankToken: store.pack.blankToken,
      );
      final OnnxExecutionProvider effective = modelResolution.effective;
      AsrStaticEncoderPool? staticSessions;
      if (!nemo &&
          useStaticEncoderBuckets &&
          kAsrStaticBucketProviders.contains(effective)) {
        final int? budget = await _factory.deviceMemoryBudgetBytes();
        final List<AsrEncoderBucket> buckets =
            staticBucketsOverride ?? kAsrCtcGpuBuckets;
        staticSessions = AsrStaticEncoderPool(
          factory: _factory,
          modelPath: modelPath,
          providers: <OnnxExecutionProvider>[effective],
          buckets: buckets,
          batchDimName: kAsrCtcBatchDim,
          timeDimName: kAsrCtcSamplesDim,
          logName: kAsrLogName,
        );
        if (staticBucketsOverride != null ||
            shouldPrewarmAllStaticBuckets(
              buckets: buckets,
              budgetBytes: budget,
              materialMs: materialMs,
            )) {
          await staticSessions.prewarmAll();
        } else {
          await staticSessions.prewarmSmallest();
        }
      }
      developer.log(
        'ASR CTC engine loaded (${variant.name}'
        '${openedEncoder.fp16 ? ', fp16' : ''}): $modelResolution '
        'staticBuckets=${staticSessions != null}',
        name: kAsrLogName,
      );
      return AsrEngineSessions(
        architecture: AsrModelArchitecture.ctc,
        encoderFp16: openedEncoder.fp16,
        encoder: model,
        vad: vad,
        tokens: tokens,
        variant: variant,
        encoderResolution: modelResolution,
        staticEncoders: staticSessions,
        nemoMel: nemoMel,
      );
    } catch (_) {
      for (final OnnxSession s in opened) {
        await s.close();
      }
      rethrow;
    }
  }

  /// 建一个**清单文件**的会话，并在失败时分辨「是不是这个文件本身坏了」。
  ///
  /// 坏档不再把 ORT 的 `Protobuf parsing failed` 原样抛给上层：那句话对用户没有
  /// 任何可执行含义，而 [isAsrModelFileReady] 的宽松判定（存在且非空）会让下载
  /// 器每次都把它当就绪跳过——同一个错误于是每次转录复现，用户除了手删整个模型
  /// 目录没有出路。这里把坏档删掉并换成 [AsrModelFileUnusableException]，
  /// 「重新下载」这条本来就有的路重新可达。
  ///
  /// 只处理清单文件。派生文件（fp16 编码器、贪心 Loop 图）不走这里：它们各自
  /// 已有「失败就回退」的路径，删不删都不影响用户能不能转录。
  Future<OnnxSession> _openManifestSession(
    AsrModelStore store,
    AsrModelRole role, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
  }) async {
    final File file = store.fileFor(role);
    try {
      return await _factory.createSession(
        file.path,
        providers: providers,
        onProviderResolved: onProviderResolved,
      );
    } catch (error) {
      if (!isOnnxUnreadableModelFailure(error)) {
        rethrow;
      }
      throw _discardUnusableModelFile(store, role, file, error);
    }
  }

  /// 删掉装不起来的模型文件，并造出带诊断信息的异常。
  ///
  /// 删除失败不掩盖：`deleted: false` 会一路带到 UI，用户至少知道要手删哪个
  /// 文件，而不是对着一句 protobuf 报错猜。
  static AsrModelFileUnusableException _discardUnusableModelFile(
    AsrModelStore store,
    AsrModelRole role,
    File file,
    Object cause,
  ) {
    final bool existed = file.existsSync();
    final int actual = existed ? file.lengthSync() : -1;
    bool deleted = false;
    if (existed) {
      try {
        file.deleteSync();
        deleted = true;
      } catch (error, stack) {
        developer.log(
          'ASR unusable model file could not be deleted: ${file.path}',
          name: kAsrLogName,
          error: error,
          stackTrace: stack,
        );
      }
    }
    final AsrModelFile model = store.pack.fileForRole(role);
    developer.log(
      'ASR model file unusable (${model.fileName}, $actual bytes, '
      'expected ${model.expectedBytes}, deleted: $deleted): ${file.path}',
      name: kAsrLogName,
      error: cause,
    );
    return AsrModelFileUnusableException(
      fileName: model.fileName,
      path: file.path,
      actualBytes: actual,
      expectedBytes: model.expectedBytes,
      deleted: deleted,
      cause: cause,
    );
  }

  /// 打开编码器（动态 shape 会话）。首选 EP 在 [kAsrFp16Providers] 里且 [useFp16]
  /// 时，先把 fp32 文件在设备上转成 fp16 派生文件再建会话；以下任一情况回退
  /// fp32 并留日志，不静默：
  /// - 转换失败（外置权重 / 不支持的图形态，抛 [FormatException]）；
  /// - fp16 会话建不起来；
  /// - fp16 会话经 provider 回退落到了 CPU——fp16 在 CPU 上没有收益也未必跑得动，
  ///   换回 fp32 重新按原 EP 列表建（fp32 也可能落 CPU，那是原有的降级路径）。
  Future<_OpenedEncoder> _openEncoder({
    required AsrModelStore store,
    required AsrModelRole role,
    required List<OnnxExecutionProvider> providers,
    required bool useFp16,
  }) async {
    final String fp32Path = store.fileFor(role).path;
    if (useFp16 && kAsrFp16Providers.contains(providers.first)) {
      final _OpenedEncoder? fp16 = await _tryOpenFp16(
        store: store,
        role: role,
        providers: providers,
      );
      if (fp16 != null) return fp16;
    }
    OnnxProviderResolution? resolution;
    final OnnxSession session = await _openManifestSession(
      store,
      role,
      providers: providers,
      onProviderResolved: (OnnxProviderResolution r) => resolution = r,
    );
    return _OpenedEncoder(
      session: session,
      modelPath: fp32Path,
      resolution:
          resolution ??
          OnnxProviderResolution(
            requested: providers,
            effective: providers.first,
          ),
      fp16: false,
    );
  }

  Future<_OpenedEncoder?> _tryOpenFp16({
    required AsrModelStore store,
    required AsrModelRole role,
    required List<OnnxExecutionProvider> providers,
  }) async {
    final File file;
    try {
      final Stopwatch clock = Stopwatch()..start();
      file = await store.ensureFp16Encoder(role, convert: convertAsrModelToFp16);
      developer.log(
        'ASR fp16 encoder ready in ${clock.elapsedMilliseconds}ms: ${file.path}',
        name: kAsrLogName,
      );
    } catch (error, stack) {
      developer.log(
        'ASR fp16 encoder conversion failed; using fp32',
        name: kAsrLogName,
        error: error,
        stackTrace: stack,
      );
      return null;
    }
    OnnxProviderResolution? resolution;
    final OnnxSession session;
    try {
      session = await _factory.createSession(
        file.path,
        providers: providers,
        onProviderResolved: (OnnxProviderResolution r) => resolution = r,
      );
    } catch (error, stack) {
      developer.log(
        'ASR fp16 encoder session failed; using fp32',
        name: kAsrLogName,
        error: error,
        stackTrace: stack,
      );
      return null;
    }
    final OnnxProviderResolution effective =
        resolution ??
        OnnxProviderResolution(requested: providers, effective: providers.first);
    if (!kAsrFp16Providers.contains(effective.effective)) {
      developer.log(
        'ASR fp16 encoder fell back to ${effective.effective.name}; '
        'reopening fp32 (${effective.fallbackReason})',
        name: kAsrLogName,
      );
      await session.close();
      return null;
    }
    return _OpenedEncoder(
      session: session,
      modelPath: file.path,
      resolution: effective,
      fp16: true,
    );
  }

  /// 探测失败时把原因并进 resolution：编码器落在 CPU 是探测失败的**后果**，
  /// 不是策略选择，必须以 `fallbackReason` 的形态浮出来。
  static OnnxProviderResolution _withProbeError(
    OnnxProviderResolution resolution,
    Object? probeError,
  ) {
    if (probeError == null) return resolution;
    return OnnxProviderResolution(
      requested: resolution.requested,
      effective: resolution.effective,
      fallbackReason: resolution.fallbackReason == null
          ? 'accelerated provider probe failed: $probeError'
          : '${resolution.fallbackReason}; '
                'accelerated provider probe failed: $probeError',
    );
  }
}

/// [AsrEngineLoader._openEncoder] 的结果：会话、它加载的模型文件（静态桶按同一
/// 文件建）、EP 解析与精度。
class _OpenedEncoder {
  const _OpenedEncoder({
    required this.session,
    required this.modelPath,
    required this.resolution,
    required this.fp16,
  });

  final OnnxSession session;
  final String modelPath;
  final OnnxProviderResolution resolution;
  final bool fp16;
}
