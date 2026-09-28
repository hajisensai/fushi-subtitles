/// 字幕格式与**重定时**。
///
/// 三件事，都不依赖任何 ONNX 后端：
/// 1. [SubtitleCue] 与 SRT / WebVTT / JSON 之间的纯文本变换；
/// 2. 拿一份 ASR 转录当参照，修好已有字幕的时间轴（[retimeSubtitles]）——正文与
///    顺序一个字都不动，只有唯一且单调的文本锚点算数，锚点之间按
///    [fitSubtitleClock] 的分区域时钟模型推，推不出来的段保持原样。
/// 3. 拿另一条字幕（视频自带的任意语言文本轨）当参照，只看 cue 开始时刻对时间轴
///    （[decideSubtitleSync]，含 CM 断点分段与多参考投票），再按结果只改写字幕字节
///    里的时间戳（[retimeSubtitleBytes]，编码 / 样式 / 行尾逐字节保留）。参考轨从哪
///    抽（ffmpeg / 容器 demux）本包同样不管，喂进来的只是开始时刻列表。
///
/// 转录从哪来本包不管：喂进来的只是 [RetimingTranscription] 这个窄接口（cue 列表
/// 加可选的逐 token 发射时间）。宿主可以用本仓的 ONNX 转录，也可以用别处产的
/// 结果——**这正是本包不依赖后端的理由**，别把 runner 或 session 塞进来。
library;

export 'src/cancellation.dart';
export 'src/subtitle_clock.dart';
export 'src/subtitle_format.dart';
export 'src/subtitle_reference_alignment.dart';
export 'src/subtitle_retiming.dart';
export 'src/subtitle_speech_text.dart';
export 'src/subtitle_time_rewriter.dart';
