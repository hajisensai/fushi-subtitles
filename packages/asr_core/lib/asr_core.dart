/// 纯 Dart 语音识别转录核心。
///
/// 一条链路：音频 → ffmpeg 解成 16 kHz 单声道 PCM → VAD 分段 → fbank →
/// zipformer RNN-T（贪心 Loop 图）或 CTC 解码 → cue 合并 → SRT / VTT。
///
/// 本包**不自带 ONNX 后端**：算法层只依赖 [OnnxSessionFactory] 这个窄接口，
/// 由宿主注入（桌面 / 服务端用 `fushi_asr_onnx_ffi`，Flutter 宿主用插件后端）。
/// 这是整套代码能同时服务 app、CLI 和服务端的唯一原因，别往这层塞具体实现。
library;

export 'src/asr/asr_ctc_align.dart';
export 'src/asr/asr_ctc_decoder.dart';
export 'src/asr/asr_cue_builder.dart';
export 'src/asr/asr_encoder_buckets.dart';
export 'src/asr/asr_energy_envelope.dart';
export 'src/asr/asr_engine.dart';
export 'src/asr/asr_fbank.dart' hide AsrRealFft;
export 'src/asr/asr_nemo_mel.dart';
export 'src/asr/asr_fbank_workers.dart';
export 'src/asr/asr_fp16_graph.dart';
export 'src/asr/asr_greedy_graph.dart';
export 'src/asr/asr_model_manifest.dart';
export 'src/asr/asr_model_registry.dart';
export 'src/asr/asr_model_store.dart';
export 'src/asr/asr_pcm_bridge.dart';
export 'src/asr/asr_pcm_source.dart';
export 'src/asr/asr_transcribe_isolate.dart';
export 'src/asr/asr_transcribe_job.dart';
export 'src/asr/asr_transcription_service.dart';
export 'src/asr/asr_transducer_decoder.dart';
export 'src/asr/asr_types.dart';
export 'src/asr/asr_vad.dart';
export 'src/ffmpeg/ffmpeg_backend.dart';
export 'src/onnx/model_file_downloader.dart';
export 'src/onnx/onnx_inference.dart';
export 'src/onnx/onnx_proto.dart';
export 'src/util/asr_http.dart';
export 'src/util/asr_paths.dart';
export 'src/util/directory_bytes.dart';
export 'src/util/log.dart';
