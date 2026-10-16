/// 把整本转录任务下放到 `Isolate.spawn` 的后台 isolate。
///
/// 转录链路里的 fbank（纯 Dart FFT）、能量 VAD、PCM 解析、Loop 图输出的 token
/// 还原全是主 isolate 上的同步 CPU 工作；ORT 调用本身经 MethodChannel 异步，但
/// 每批几十秒音频的特征计算就够把 UI 卡成幻灯片（2026-09-06 英语整本实测）。
/// 做法与漫画 OCR 整卷任务（`manga_ocr_service_impl.dart`）相同：
/// `BackgroundIsolateBinaryMessenger.ensureInitialized(RootIsolateToken)` 让
/// flutter_onnxruntime 的 MethodChannel 可从后台 isolate 发出，会话在 isolate
/// 内建、在 isolate 内关，主 isolate 只收事件。
///
/// 消息协议（同代码库 `Isolate.spawn`，直接发送实例；`AsrTranscribeEvent` 三个
/// 子类的字段都是纯数据，可原样跨 isolate）：
///
/// ```text
/// isolate → main : _ControlPort(sendPort)     建会话前第一时间发，主侧据此发暂停
///                  _Loaded(resolution, greedy…) 引擎装载完成（spawn() 在此返回）
///                  AsrTranscribeEvent           进度 / 已暂停 / 完成（原样转发）
///                  _Stats(AsrDecodeStats)       任务结束后的分阶段耗时
///                  _Error(message, stack)       装载或运行期异常
///                  _Exited()                    会话已关、isolate 即将退出
/// main → isolate : 'pause'                     请求在下一个检查点暂停
/// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';

import 'package:fushi_asr_core/src/asr/asr_encoder_buckets.dart';
import 'package:fushi_asr_core/src/asr/asr_engine.dart';
import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_model_store.dart';
import 'package:fushi_asr_core/src/asr/asr_pcm_bridge.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart';
import 'package:fushi_asr_core/src/asr/asr_transcription_service.dart';
import 'package:fushi_asr_core/src/asr/asr_transducer_decoder.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/util/log.dart';
import 'package:fushi_asr_core/src/asr/asr_vad.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';

/// 跨 isolate 的任务说明：全是路径 / 枚举 / 数值，不带闭包与会话。
@immutable
class AsrIsolateJobSpec {
  const AsrIsolateJobSpec({
    required this.storeDirPath,
    required this.pack,
    required this.language,
    required this.variant,
    required this.preference,
    required this.audioPaths,
    required this.jobDirPath,
    required this.chunkSeconds,
    required this.audioProfile,
    this.batchSize,
    this.usePipeline = true,
    this.useFp16Encoder = true,
    this.staticBucketsOverride,
    this.materialMs,
    this.greedySessions,
    this.greedyIntraOpThreads,
  });

  /// 见 [AsrTranscriptionService.greedySessions] / `greedyIntraOpThreads`。
  final int? greedySessions;
  final int? greedyIntraOpThreads;

  final String storeDirPath;

  /// 根 isolate 选定的模型包。**不能**在后台 isolate 里按 [language] 重查
  /// `asrModelPackFor`：`Isolate.spawn` 的新 isolate 全局量从头初始化，宿主装进
  /// `asrModelRegistry` 的自带 / 可选包（Kitsune 等）在那边看不见，会静默换回
  /// 内置包。
  final AsrModelPack pack;
  final AsrLanguage language;
  final AsrEncoderVariant variant;
  final AsrAccelerationPreference preference;
  final List<String> audioPaths;
  final String jobDirPath;
  final int chunkSeconds;
  final AsrAudioProfile audioProfile;

  final bool usePipeline;

  /// 见 [AsrTranscriptionService.useFp16Encoder]。
  final bool useFp16Encoder;

  /// 见 [AsrTranscriptionService.staticBucketsOverride]。
  final List<AsrEncoderBucket>? staticBucketsOverride;

  /// 素材总时长（毫秒；null = 未知），决定装载时的桶预热策略。
  final int? materialMs;

  /// null = 按编码器实际落到的 EP 取 [AsrTranscriptionService.defaultBatchSizeFor]。
  final int? batchSize;
}

class _IsolateArgs {
  const _IsolateArgs({
    required this.events,
    required this.backend,
    required this.spec,
    required this.pcmPort,
  });

  final SendPort events;

  /// 后台 isolate 里怎么装配 ONNX 后端（见 [AsrIsolateBackend]）。
  final AsrIsolateBackend backend;
  final AsrIsolateJobSpec spec;

  /// 根 isolate 的 [AsrPcmBridgeHost] 请求端口：PCM 解码留在根 isolate
  /// （BUG-2197，`asr_pcm_bridge.dart` 文件头）。
  final SendPort pcmPort;
}

/// 后台转录 isolate 里怎么装配 ONNX 后端。
///
/// **整体必须可跨 isolate 传递**，所以两个函数字段只能是顶层 / 静态函数引用
/// （闭包过不了 isolate 边界），[bootstrapArg] 只能是可发送值。
///
/// 抽包前这里是硬编码的 `RootIsolateToken` + `BackgroundIsolateBinaryMessenger`
/// ——那是 Flutter method channel 后端的实现细节（后台 isolate 要重新挂上 binary
/// messenger 才能发方法调用），也是整条 ASR 依赖链上**唯一**的结构性 Flutter 依赖。
/// 做成钩子之后：Flutter 宿主传自己的包装函数 + `RootIsolateToken.instance`，
/// 纯 Dart FFI 后端两个钩子都不传。
class AsrIsolateBackend {
  const AsrIsolateBackend({
    required this.buildFactory,
    this.bootstrap,
    this.bootstrapArg,
  });

  /// 在后台 isolate 里 new 出 ONNX 会话工厂。
  final OnnxSessionFactory Function() buildFactory;

  /// 后台 isolate 里的宿主前置初始化；null 表示不需要。
  final void Function(Object arg)? bootstrap;

  /// 传给 [bootstrap] 的可发送参数。
  final Object? bootstrapArg;

  /// 在后台 isolate 里跑一次前置初始化（钩子或参数缺失都视为不需要）。
  void runBootstrap() {
    final void Function(Object arg)? hook = bootstrap;
    final Object? arg = bootstrapArg;
    if (hook == null || arg == null) return;
    hook(arg);
  }
}

class _ControlPortMessage {
  const _ControlPortMessage(this.port);
  final SendPort port;
}

class _LoadedMessage {
  const _LoadedMessage({
    required this.resolution,
    required this.greedyGraphAvailable,
    required this.greedyUnavailableReason,
    required this.encoderFp16,
  });

  final OnnxProviderResolution resolution;
  final bool greedyGraphAvailable;
  final String? greedyUnavailableReason;
  final bool encoderFp16;
}

class _StatsMessage {
  const _StatsMessage(this.stats);
  final AsrDecodeStats stats;
}

class _ErrorMessage {
  const _ErrorMessage(this.message, this.stackTrace);
  final String message;
  final String stackTrace;
}

class _ExitedMessage {
  const _ExitedMessage();
}

const String _kPauseMessage = 'pause';

/// 后台 isolate 里跑的转录（生产路径）。
class AsrIsolateTranscription implements AsrRunningTranscription {
  AsrIsolateTranscription._(
    this._events,
    this._control,
    this._loaded,
    this._exited,
  );

  /// 起 isolate、装载引擎；引擎装好（或装载失败）才返回，与进程内路径的
  /// `start()` 契约一致。[pcm] 留在根 isolate 服务转录 isolate 的解码请求。
  static Future<AsrIsolateTranscription> spawn(
    AsrIsolateJobSpec spec, {
    required AsrPcmSource pcm,
    required AsrIsolateBackend backend,
  }) async {
    final ReceivePort events = ReceivePort();
    final AsrPcmBridgeHost pcmHost = AsrPcmBridgeHost(pcm);
    final Completer<SendPort> control = Completer<SendPort>();
    final Completer<_LoadedMessage> loaded = Completer<_LoadedMessage>();
    final Completer<void> exited = Completer<void>();
    late final AsrIsolateTranscription running;
    events.listen((Object? message) {
      if (message is _ControlPortMessage) {
        if (!control.isCompleted) control.complete(message.port);
        return;
      }
      if (message is _LoadedMessage) {
        if (!loaded.isCompleted) loaded.complete(message);
        return;
      }
      if (message is _ErrorMessage) {
        final StateError error = StateError(message.message);
        final StackTrace stack = StackTrace.fromString(message.stackTrace);
        if (!loaded.isCompleted) {
          loaded.completeError(error, stack);
        } else {
          running._onRunError(error, stack);
        }
        return;
      }
      if (message is _ExitedMessage) {
        if (!exited.isCompleted) exited.complete();
        running._onExited();
        events.close();
        unawaited(pcmHost.close());
        return;
      }
      if (message is List<Object?> && message.length == 2) {
        // Isolate.spawn onError 通道：[error, stackTrace] 字符串对。
        final StateError error = StateError(
          'ASR isolate crashed: ${message[0]}',
        );
        final StackTrace stack = StackTrace.fromString('${message[1]}');
        if (!loaded.isCompleted) loaded.completeError(error, stack);
        running._onRunError(error, stack);
        if (!exited.isCompleted) exited.complete();
        running._onExited();
        events.close();
        unawaited(pcmHost.close());
        return;
      }
      if (message is _StatsMessage) {
        running._stats = message.stats;
        return;
      }
      if (message is AsrTranscribeEvent) {
        running._onEvent(message);
      }
    });
    running = AsrIsolateTranscription._(
      events,
      control.future,
      loaded.future,
      exited.future,
    );
    try {
      await Isolate.spawn<_IsolateArgs>(
        _isolateMain,
        _IsolateArgs(
          events: events.sendPort,
          backend: backend,
          spec: spec,
          pcmPort: pcmHost.port,
        ),
        onError: events.sendPort,
        debugName: 'asr_transcribe_job',
      );
      final _LoadedMessage m = await loaded.future;
      running._resolution = m.resolution;
      running._greedyGraphAvailable = m.greedyGraphAvailable;
      running._greedyUnavailableReason = m.greedyUnavailableReason;
      running._encoderFp16 = m.encoderFp16;
      return running;
    } catch (_) {
      events.close();
      await pcmHost.close();
      rethrow;
    }
  }

  final ReceivePort _events;
  final Future<SendPort> _control;
  // ignore: unused_field — 只为让 spawn() 的等待与实例绑定，便于将来重连。
  final Future<_LoadedMessage> _loaded;
  final Future<void> _exited;

  late OnnxProviderResolution _resolution;
  bool _greedyGraphAvailable = false;
  String? _greedyUnavailableReason;
  bool _encoderFp16 = false;
  AsrDecodeStats? _stats;
  StreamController<AsrTranscribeEvent>? _stream;
  bool _isolateExited = false;
  bool _pauseRequested = false;

  @override
  OnnxProviderResolution get encoderResolution => _resolution;

  @override
  bool get greedyGraphAvailable => _greedyGraphAvailable;

  @override
  String? get greedyUnavailableReason => _greedyUnavailableReason;

  @override
  bool get encoderFp16 => _encoderFp16;

  @override
  AsrDecodeStats? get decodeStats => _stats;

  @override
  Stream<AsrTranscribeEvent> run() {
    if (_stream != null) {
      throw StateError('AsrIsolateTranscription.run() 只能调用一次');
    }
    final StreamController<AsrTranscribeEvent> c =
        StreamController<AsrTranscribeEvent>();
    _stream = c;
    if (_isolateExited) c.close();
    return c.stream;
  }

  void _onEvent(AsrTranscribeEvent e) {
    final StreamController<AsrTranscribeEvent>? c = _stream;
    if (c == null || c.isClosed) return;
    c.add(e);
    // 任务流以 finished / paused 收尾（与 AsrTranscribeJob.run 契约一致）。
    if (e is AsrTranscribeFinishedEvent || e is AsrTranscribePausedEvent) {
      c.close();
    }
  }

  void _onRunError(Object error, StackTrace stack) {
    final StreamController<AsrTranscribeEvent>? c = _stream;
    if (c == null || c.isClosed) return;
    c.addError(error, stack);
    c.close();
  }

  void _onExited() {
    _isolateExited = true;
    final StreamController<AsrTranscribeEvent>? c = _stream;
    if (c != null && !c.isClosed) c.close();
  }

  @override
  void requestPause({bool discardPending = false}) {
    if (_pauseRequested) return;
    _pauseRequested = true;
    unawaited(_control.then((SendPort port) =>
        port.send(discardPending ? 'cancel' : _kPauseMessage)));
  }

  /// 会话归 isolate 所有：这里只能请求暂停并等它在下一个检查点关会话退出；
  /// 不 `Isolate.kill`——那会让 ORT 的 native 会话没人释放。
  @override
  Future<void> dispose() async {
    if (!_isolateExited) {
      requestPause();
      await _exited;
    }
    _events.close();
  }
}

/// isolate 入口：装载引擎 → 跑任务 → 回发事件 → 关会话。
Future<void> _isolateMain(_IsolateArgs args) async {
  final ReceivePort control = ReceivePort();
  AsrTranscribeJob? job;
  bool pauseBeforeStart = false;
  bool discardPending = false;
  control.listen((Object? message) {
    if (message != _kPauseMessage && message != 'cancel') return;
    discardPending = discardPending || message == 'cancel';
    final AsrTranscribeJob? j = job;
    if (j != null) {
      j.requestPause(discardPending: discardPending);
    } else {
      pauseBeforeStart = true;
    }
  });
  args.events.send(_ControlPortMessage(control.sendPort));

  // 宿主的后台 isolate 前置初始化。method channel 后端必须先挂上 binary
  // messenger 才能从后台 isolate 发调用；FFI 后端不需要，钩子为 null。
  args.backend.runBootstrap();

  final AsrIsolateJobSpec spec = args.spec;
  // PCM 解码在根 isolate（ffmpeg_kit 的 EventChannel 只能在那边订阅，BUG-2197）。
  final RemoteAsrPcmSource pcm = RemoteAsrPcmSource(args.pcmPort);
  AsrEngineSessions? sessions;
  try {
    final AsrModelStore store = AsrModelStore(
      Directory(spec.storeDirPath),
      spec.pack,
    );
    final AsrEngineLoader loader = AsrEngineLoader(
      factory: args.backend.buildFactory(),
    );
    sessions = await loader.load(
      store: store,
      variant: spec.variant,
      preference: spec.preference,
      useFp16Encoder: spec.useFp16Encoder,
      staticBucketsOverride: spec.staticBucketsOverride,
      materialMs: spec.materialMs,
      greedySessions: spec.greedySessions,
      greedyIntraOpThreads:
          spec.greedyIntraOpThreads ?? kAsrGreedyGraphIntraOpThreads,
    );
    args.events.send(
      _LoadedMessage(
        resolution: sessions.encoderResolution,
        greedyGraphAvailable: sessions.greedy != null,
        greedyUnavailableReason: sessions.greedyUnavailableReason,
        encoderFp16: sessions.encoderFp16,
      ),
    );
    final AsrSegmentDecoder decoder = sessions.newDecoder()..warmUp();
    final int maxSegmentMs = sessions.maxSegmentMs;
    final AsrTranscribeJob j = AsrTranscribeJob(
      jobDir: Directory(spec.jobDirPath),
      audioPaths: spec.audioPaths,
      modelId: store.pack.id,
      pcm: pcm,
      segmenter: switch (spec.audioProfile) {
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
      batchSize: spec.batchSize ??
          AsrTranscriptionService.defaultBatchSizeFor(
            sessions.encoderResolution.effective,
          ),
      chunkSeconds: spec.chunkSeconds,
      statsProvider: () => decoder.stats,
      usePipeline: spec.usePipeline,
    );
    job = j;
    if (pauseBeforeStart) j.requestPause(discardPending: discardPending);
    await for (final AsrTranscribeEvent e in j.run()) {
      // 统计先于收尾事件发出：主侧在 finished / paused 一到就读 decodeStats。
      if (e is AsrTranscribeFinishedEvent || e is AsrTranscribePausedEvent) {
        args.events.send(_StatsMessage(decoder.stats));
      }
      args.events.send(e);
    }
  } catch (error, stack) {
    args.events.send(_ErrorMessage('$error', '$stack'));
  } finally {
    asrShutdownTrace('isolate: closing sessions');
    try {
      await sessions?.close();
    } catch (_) {
      // 关会话失败没有可做的补救；退出本 isolate 即可。
    }
    asrShutdownTrace('isolate: sessions closed');
    pcm.close();
    asrShutdownTrace('isolate: pcm closed');
    args.events.send(const _ExitedMessage());
    asrShutdownTrace('isolate: exited message sent');
    control.close();
  }
}
