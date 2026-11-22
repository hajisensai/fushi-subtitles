/// 歌曲素材的人声分离（[AsrAudioProfile.song]）：识别前把伴奏压掉。
///
/// 模型是 UVR MDX-Net（[kAsrVocalSeparatorFile]），吃 44.1 kHz 复数 STFT、吐人声的
/// 复数 STFT。流程：
///
/// ```
/// 16 kHz PCM 块 ─重采样→ 44.1 kHz ─分窗 STFT→ MDX ─iSTFT→ 44.1 kHz 人声
///                                                       ─重采样→ 16 kHz 人声块
/// ```
///
/// **为什么从 16 kHz 块出发而不是另解一遍 44.1 kHz**：PCM 解码在根 isolate
/// （`asr_pcm_bridge.dart`，ffmpeg_kit 的限制，BUG-2197），转录 isolate 只拿得到
/// 16 kHz 块。在这一层做成 [AsrPcmSource] 的装饰器，分离就自动继承了块级检查点、
/// 暂停 / 续跑与两条装配路径（进程内 / isolate），不用给桥加一条全频带解码。
/// 代价是 8 kHz 以上的频带是空的；2026-11-23 在 メルト（270 s）上对照：全频带与
/// 16 kHz 输入分离后送 Parakeet，被直接识别漏掉的句子两边都找回来了，文本差别在
/// 个别假名。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';

/// 分离模型的采样率。
const int kAsrVocalSeparationSampleRate = 44100;

/// 一次分离前向的峰值工作集（字节）：权重 28 MB + ORT CPU arena。2026-11-23
/// onnxruntime 1.22 CPU EP 实测一个 `[1, 4, 2048, 256]` 窗口 RSS 从 90 MB 涨到
/// 616 MB，取整留余量。Dart 侧缓冲按窗口算（输入 / 输出张量各 8 MiB、iSTFT
/// 累加 4 MiB、人声尾巴 1 MiB，见 [AsrVocalSeparator.separate]），不随块长涨，
/// 落在余量里。宿主的内存门槛（移动端）在识别模型的估算上加这一项。
const int kAsrVocalSeparationWorkingSetBytes = 640 * 1024 * 1024;

/// MDX-Net 的 STFT 与张量形状。默认值逐项对照 [kAsrVocalSeparatorFile] 的 ONNX
/// 元数据（`n_fft` / `hop_length` / `dim_f` / `dim_t` / `center=1` / `hann`）。
class AsrMdxConfig {
  const AsrMdxConfig({
    this.nFft = 4096,
    this.hop = 1024,
    this.dimF = 2048,
    this.dimT = 256,
  });

  final int nFft;
  final int hop;

  /// 模型看的频点数（低频起前 [dimF] 个，其余置零）。
  final int dimF;

  /// 一个窗口的帧数。
  final int dimT;

  /// 一个窗口覆盖的样本数（center STFT：`dimT` 帧 ⇔ `hop * (dimT - 1)` 样本）。
  int get windowSamples => hop * (dimT - 1);

  /// 窗口两端各丢掉的样本（只作上下文，不出结果）。
  int get trim => nFft ~/ 2;

  /// 一个窗口产出的样本数（= 窗口步长）。
  int get genSamples => windowSamples - 2 * trim;
}

/// 有理比例的窗函数 sinc 重采样（线性相位，输出与输入时间对齐）。
///
/// 截止取两侧较低奈奎斯特的 95%，Blackman 窗，每侧 [zeroCrossings] 个过零点；
/// 每个相位的系数归一化到直流增益 1。输出长度 `floor(n * to / from)`。
class AsrResampler {
  AsrResampler({
    required this.fromRate,
    required this.toRate,
    this.zeroCrossings = 16,
  }) {
    if (fromRate <= 0 || toRate <= 0) {
      throw ArgumentError('采样率必须为正：$fromRate → $toRate');
    }
    final int g = _gcd(fromRate, toRate);
    _up = toRate ~/ g;
    _down = fromRate ~/ g;
    // 截止频率，单位「每个输入样本的周期数」。
    final double cutoff = 0.95 * 0.5 * math.min(fromRate, toRate) / fromRate;
    _half = (zeroCrossings / (2 * cutoff)).ceil();
    final int taps = 2 * _half;
    _table = Float64List(_up * taps);
    for (int phase = 0; phase < _up; phase++) {
      final double frac = phase / _up;
      double sum = 0;
      for (int j = 0; j < taps; j++) {
        // 第 j 个抽头对应输入 base + (j - half + 1)，与输出时刻相距 t。
        final double t = (j - _half + 1) - frac;
        final double x = 2 * cutoff * t;
        final double sinc = x == 0
            ? 1.0
            : math.sin(math.pi * x) / (math.pi * x);
        final double u = (t + _half) / (2 * _half); // 0..1
        final double w = u <= 0 || u >= 1
            ? 0.0
            : 0.42 -
                  0.5 * math.cos(2 * math.pi * u) +
                  0.08 * math.cos(4 * math.pi * u);
        final double h = 2 * cutoff * sinc * w;
        _table[phase * taps + j] = h;
        sum += h;
      }
      if (sum != 0) {
        for (int j = 0; j < taps; j++) {
          _table[phase * taps + j] /= sum;
        }
      }
    }
  }

  final int fromRate;
  final int toRate;
  final int zeroCrossings;

  late final int _up;
  late final int _down;
  late final int _half;
  late final Float64List _table;

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

  /// [input] 重采样后的长度。
  int outputLength(int inputLength) => inputLength * _up ~/ _down;

  /// 每个输出样本用到的输入样本数。
  int get taps => 2 * _half;

  /// 输出样本 [i] 用到的第一个输入下标（区间 `[firstInputFor(i), +taps)`，越界
  /// 部分按 0 计）。随 [i] 单调不减。
  int firstInputFor(int i) => (i * _down) ~/ _up - _half + 1;

  Float32List process(Float32List input) {
    final int n = input.length;
    final Float32List out = Float32List(outputLength(n));
    for (int i = 0; i < out.length; i++) {
      out[i] = sampleAt(input, 0, n, i);
    }
    return out;
  }

  /// 把输出样本 `[outStart, outStart + dest.length)` 写进 [dest]；超出
  /// `[0, outputLength(input.length))` 的位置写 0。与 [process] 逐样本相同，
  /// 只是不落整段输出。
  void renderInto(Float32List input, int outStart, Float32List dest) {
    final int n = input.length;
    final int total = outputLength(n);
    for (int i = 0; i < dest.length; i++) {
      final int k = outStart + i;
      dest[i] = k >= 0 && k < total ? sampleAt(input, 0, n, k) : 0.0;
    }
  }

  /// 输出样本 [i]：输入逻辑长度 [n]，[window] 里存的是输入下标
  /// `[offset, offset + window.length)` 那一段（[i] 用到的落在 `[0, n)` 内的
  /// 输入都必须在里面）。
  double sampleAt(Float32List window, int offset, int n, int i) {
    final int taps = 2 * _half;
    final int pos = i * _down;
    final int base = pos ~/ _up;
    final int phase = pos - base * _up;
    final int row = phase * taps;
    final int first = base - _half + 1;
    double acc = 0;
    if (first >= 0 && first + taps <= n) {
      final int o = first - offset;
      for (int j = 0; j < taps; j++) {
        acc += window[o + j] * _table[row + j];
      }
    } else {
      for (int j = 0; j < taps; j++) {
        final int k = first + j;
        if (k < 0 || k >= n) continue;
        acc += window[k - offset] * _table[row + j];
      }
    }
    return acc;
  }
}

/// 原地复数 FFT（基 2）。`inverse` 时做共轭变换并除以 N。
class _ComplexFft {
  _ComplexFft(this.size)
    : _re = Float64List(size),
      _im = Float64List(size),
      _cos = Float64List(size ~/ 2),
      _sin = Float64List(size ~/ 2),
      _rev = Int32List(size) {
    if (size < 2 || (size & (size - 1)) != 0) {
      throw ArgumentError.value(size, 'size', 'FFT 长度必须是 2 的幂');
    }
    for (int k = 0; k < size ~/ 2; k++) {
      final double a = -2 * math.pi * k / size;
      _cos[k] = math.cos(a);
      _sin[k] = math.sin(a);
    }
    int bits = 0;
    while ((1 << bits) < size) {
      bits++;
    }
    for (int i = 0; i < size; i++) {
      int r = 0;
      for (int b = 0; b < bits; b++) {
        r = (r << 1) | ((i >> b) & 1);
      }
      _rev[i] = r;
    }
  }

  final int size;
  final Float64List _re;
  final Float64List _im;
  final Float64List _cos;
  final Float64List _sin;
  final Int32List _rev;

  Float64List get re => _re;
  Float64List get im => _im;

  /// 对 [re] / [im]（已按自然顺序填好）做变换，结果写回 [re] / [im]。
  void transform({bool inverse = false}) {
    final int n = size;
    for (int i = 0; i < n; i++) {
      final int j = _rev[i];
      if (j > i) {
        final double tr = _re[i];
        _re[i] = _re[j];
        _re[j] = tr;
        final double ti = _im[i];
        _im[i] = _im[j];
        _im[j] = ti;
      }
    }
    final double sign = inverse ? -1.0 : 1.0;
    for (int len = 2; len <= n; len <<= 1) {
      final int half = len >> 1;
      final int step = n ~/ len;
      for (int start = 0; start < n; start += len) {
        for (int k = 0; k < half; k++) {
          final int a = start + k;
          final int b = a + half;
          final double wr = _cos[k * step];
          final double wi = sign * _sin[k * step];
          final double tr = _re[b] * wr - _im[b] * wi;
          final double ti = _re[b] * wi + _im[b] * wr;
          _re[b] = _re[a] - tr;
          _im[b] = _im[a] - ti;
          _re[a] += tr;
          _im[a] += ti;
        }
      }
    }
    if (inverse) {
      final double inv = 1.0 / n;
      for (int i = 0; i < n; i++) {
        _re[i] *= inv;
        _im[i] *= inv;
      }
    }
  }
}

/// MDX-Net 人声分离器：一个 ONNX 会话 + STFT / 重采样状态。不是线程安全的，
/// 一个转录任务一个。
class AsrVocalSeparator {
  AsrVocalSeparator(
    this.session, {
    this.config = const AsrMdxConfig(),
    this.inputName = 'input',
    this.outputName = 'output',
  }) : _fft = _ComplexFft(config.nFft),
       _window = _periodicHann(config.nFft),
       _up = AsrResampler(
         fromRate: kAsrSampleRate,
         toRate: kAsrVocalSeparationSampleRate,
       ),
       _downsample = AsrResampler(
         fromRate: kAsrVocalSeparationSampleRate,
         toRate: kAsrSampleRate,
       );

  final OnnxSession session;
  final AsrMdxConfig config;
  final String inputName;
  final String outputName;

  final _ComplexFft _fft;
  final Float64List _window;
  final AsrResampler _up;
  final AsrResampler _downsample;

  /// 模型输入张量 `[1, 4, dimF, dimT]`，窗口间复用。
  late final Float32List _input = Float32List(4 * config.dimF * config.dimT);

  static Float64List _periodicHann(int n) {
    final Float64List w = Float64List(n);
    for (int i = 0; i < n; i++) {
      w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
    }
    return w;
  }

  /// 16 kHz 单声道 → 同长度的 16 kHz 人声。
  ///
  /// 结果与 `downsample(separateAtModelRate(upsample(pcm16k)))` 逐样本相同，但
  /// **不落整段 44.1 kHz 中间量**：上采样按窗口现算，分离出的 44.1 kHz 人声只留
  /// 下采样滤波器还要用的那一截（< 一个窗口步长 + 滤波器长度）。一个 300 s 的块
  /// 整段落两份 44.1 kHz float 是 ~106 MB，而 [kAsrVocalSeparationWorkingSetBytes]
  /// 只按窗口级缓冲记账。
  Future<Float32List> separate(Float32List pcm16k) async {
    final int n16 = pcm16k.length;
    if (n16 == 0) return Float32List(0);
    final AsrMdxConfig c = config;
    final int n44 = _up.outputLength(n16);
    final int trim = c.trim;
    final int gen = c.genSamples;
    final AsrResampler down = _downsample;
    final int downTaps = down.taps;
    // 两次取整可能差一两个样本：按输入长度截齐 / 补零，时间轴不能漂。
    final int nOut = math.min(n16, down.outputLength(n44));
    final Float32List out = Float32List(n16);
    final Float32List segment = Float32List(c.windowSamples);
    // 已分离的 44.1 kHz 人声：buf[0, bufLen) 是逻辑下标 [bufStart, bufStart + bufLen)。
    final Float32List buf = Float32List(gen + downTaps + 1);
    int bufStart = 0;
    int bufLen = 0;
    int next = 0;
    for (int start = 0; start < n44 && next < nOut; start += gen) {
      _up.renderInto(pcm16k, start - trim, segment);
      final Float32List seg = await _separateWindow(segment);
      // seg 与 segment 同长；[trim, trim + gen) 对应 44.1 kHz 人声 [start, start + gen)。
      final int take = math.min(gen, n44 - start);
      buf.setRange(bufLen, bufLen + take, seg, trim);
      bufLen += take;
      final int produced = bufStart + bufLen;
      final bool last = produced >= n44;
      while (next < nOut &&
          (last || down.firstInputFor(next) + downTaps <= produced)) {
        out[next] = down.sampleAt(buf, bufStart, n44, next);
        next++;
      }
      // 丢掉下一个输出样本再也用不到的前缀。
      final int keepFrom = math.max(
        bufStart,
        math.min(produced, down.firstInputFor(next)),
      );
      final int drop = keepFrom - bufStart;
      if (drop > 0) {
        buf.setRange(0, bufLen - drop, buf, drop);
        bufLen -= drop;
        bufStart = keepFrom;
      }
    }
    return out;
  }

  /// 44.1 kHz 单声道 → 同长度的 44.1 kHz 人声。
  ///
  /// 与 sherpa-onnx 的 UVR 实现同构：两端各补 `trim` 个零、尾部补到整窗，按
  /// `genSamples` 步长取 `windowSamples` 长的窗口，每窗 center STFT（reflect
  /// 补边）→ 模型 → iSTFT，丢掉两端 `trim` 后首尾相接。单声道复制成左右两路
  /// 喂模型（模型是立体声的），输出两路取平均。
  Future<Float32List> separateAtModelRate(Float32List x) async {
    final AsrMdxConfig c = config;
    final int n = x.length;
    final Float32List out = Float32List(n);
    if (n == 0) return out;
    final int trim = c.trim;
    final int gen = c.genSamples;
    final int win = c.windowSamples;
    final Float32List segment = Float32List(win);
    for (int start = 0; start < n; start += gen) {
      // 窗口在「补过零的信号」里从 start 起，对应原信号 [start - trim, start - trim + win)。
      for (int i = 0; i < win; i++) {
        final int k = start - trim + i;
        segment[i] = k >= 0 && k < n ? x[k] : 0.0;
      }
      final Float32List seg = await _separateWindow(segment);
      // seg 与 segment 同长；[trim, trim + gen) 对应原信号 [start, start + gen)。
      final int take = math.min(gen, n - start);
      out.setRange(start, start + take, seg, trim);
    }
    return out;
  }

  /// 一个窗口：center STFT → 模型 → iSTFT，返回与 [segment] 同长的人声。
  Future<Float32List> _separateWindow(Float32List segment) async {
    final AsrMdxConfig c = config;
    final int bins = c.nFft ~/ 2 + 1;
    final int plane = c.dimF * c.dimT;
    final Float32List input = _input;
    _stftInto(segment, input, plane);
    final Map<String, OnnxTensor> result = await session.run(
      <String, OnnxTensor>{
        inputName: OnnxTensor.float32(input, <int>[1, 4, c.dimF, c.dimT]),
      },
    );
    final OnnxTensor? y = result[outputName] ?? result.values.firstOrNull;
    final Float32List? spec = y?.floatData;
    if (spec == null || spec.length != 4 * plane) {
      throw StateError(
        '人声分离模型输出形状不符：期望 ${4 * plane} 个 float，实得 '
        '${spec?.length} (${y?.shape})',
      );
    }
    return _istft(spec, plane, bins);
  }

  void _stftInto(Float32List segment, Float32List input, int plane) {
    final AsrMdxConfig c = config;
    final int nFft = c.nFft;
    final int half = nFft ~/ 2;
    final int len = segment.length;
    final Float64List re = _fft.re;
    final Float64List im = _fft.im;
    for (int t = 0; t < c.dimT; t++) {
      final int origin = t * c.hop - half;
      for (int i = 0; i < nFft; i++) {
        int k = origin + i;
        // reflect 补边（torch.stft center=True 的缺省）。
        if (k < 0) k = -k;
        if (k >= len) k = 2 * (len - 1) - k;
        re[i] = segment[k] * _window[i];
        im[i] = 0;
      }
      _fft.transform();
      for (int f = 0; f < c.dimF; f++) {
        final int idx = f * c.dimT + t;
        final double r = re[f];
        final double m = im[f];
        input[idx] = r; // 左 实
        input[plane + idx] = m; // 左 虚
        input[2 * plane + idx] = r; // 右 实
        input[3 * plane + idx] = m; // 右 虚
      }
    }
  }

  Float32List _istft(Float32List spec, int plane, int bins) {
    final AsrMdxConfig c = config;
    final int nFft = c.nFft;
    final int half = nFft ~/ 2;
    final int win = c.windowSamples;
    final int total = nFft + c.hop * (c.dimT - 1);
    final Float64List acc = Float64List(total);
    final Float64List norm = Float64List(total);
    final Float64List re = _fft.re;
    final Float64List im = _fft.im;
    for (int t = 0; t < c.dimT; t++) {
      for (int i = 0; i < nFft; i++) {
        re[i] = 0;
        im[i] = 0;
      }
      for (int f = 0; f < c.dimF && f < bins; f++) {
        final int idx = f * c.dimT + t;
        final double r = (spec[idx] + spec[2 * plane + idx]) * 0.5;
        final double m = (spec[plane + idx] + spec[3 * plane + idx]) * 0.5;
        re[f] = r;
        im[f] = m;
        if (f > 0 && f < half) {
          re[nFft - f] = r;
          im[nFft - f] = -m;
        }
      }
      // 实信号的直流与奈奎斯特频点虚部为零。
      im[0] = 0;
      im[half] = 0;
      _fft.transform(inverse: true);
      final int origin = t * c.hop;
      for (int i = 0; i < nFft; i++) {
        final double w = _window[i];
        acc[origin + i] += re[i] * w;
        norm[origin + i] += w * w;
      }
    }
    final Float32List out = Float32List(win);
    for (int i = 0; i < win; i++) {
      final double d = norm[half + i];
      out[i] = d > 1e-8 ? acc[half + i] / d : 0.0;
    }
    return out;
  }
}

/// 给 [inner] 解出来的每一块 PCM 先做人声分离再交出去。
///
/// 块之间各自独立分离（块长是分钟级，块边界只影响首尾 `trim`≈46 ms 的上下文）；
/// 块起点、长度与 [inner] 逐块相同，检查点 / 续跑语义不变。
class AsrVocalSeparatingPcmSource implements AsrPcmSource {
  AsrVocalSeparatingPcmSource(this.inner, this.separator);

  final AsrPcmSource inner;
  final AsrVocalSeparator separator;

  @override
  Future<int?> probeDurationMs(String audioPath) =>
      inner.probeDurationMs(audioPath);

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) async* {
    await for (final AsrPcmChunk chunk in inner.decode(
      audioPath,
      startSample: startSample,
      chunkSeconds: chunkSeconds,
    )) {
      yield AsrPcmChunk(
        startSample: chunk.startSample,
        samples: await separator.separate(chunk.samples),
      );
    }
  }
}
