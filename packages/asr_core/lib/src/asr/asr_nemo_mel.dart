/// NeMo 风格 log-mel 特征（Parakeet / FastConformer CTC 的输入），纯 Dart。
///
/// 与 `transformers` 的 `ParakeetFeatureExtractor`（即 NeMo
/// `AudioToMelSpectrogramPreprocessor` 推理期配置）逐步对齐，2026-10-15 用 numpy
/// 参考实现在 20 段真实动画对白上对拍，最大绝对差 5.6e-5、有效帧数逐段一致：
///
/// 1. 预加重 `y[0]=x[0]`、`y[n]=x[n]-0.97·x[n-1]`（整段做一次，不是逐帧）；
/// 2. 两端各补 `n_fft/2 = 256` 个零（`torch.stft(center=True, pad_mode="constant")`），
///    帧数 `1 + L/160`；
/// 3. 400 点**对称** Hann 窗（`periodic=False`）居中补零到 512，`|FFT|²`；
/// 4. 80 维 Slaney mel（librosa `norm="slaney"`、0–8000 Hz）后取 `log(x + 2⁻²⁴)`；
/// 5. 只在有效帧（`L / 160` 帧）上逐维做均值 / **无偏**标准差归一化
///    `(x-μ)/(σ+1e-5)`，有效帧之后的帧置 0。
///
/// 与 kaldi fbank（`asr_fbank.dart`）的差别都在这里：没有去直流、没有 povey 窗、
/// mel 刻度不同、要逐维归一化——混用任何一步，模型照样出字，只是错得多。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_real_fft.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';

/// 一段音频的 NeMo log-mel：[features] 帧主序 `[frames, 80]`，前 [validFrames]
/// 帧有效（其余为 0，供批内补齐）。
typedef AsrNemoMelFeatures = ({
  Float32List features,
  int frames,
  int validFrames,
});

class AsrNemoMel {
  const AsrNemoMel();

  static const int nFft = 512;
  static const int hopLength = 160;
  static const int winLength = 400;
  static const int numMels = kAsrFeatureDim;
  static const double preemphasis = 0.97;
  static const double logGuard = 5.960464477539063e-8; // 2^-24
  static const double normEpsilon = 1e-5;

  static final Float64List _window = _buildWindow();
  static final List<({int first, Float64List weights})> _filters =
      _buildSlaneyFilters();
  static final AsrRealFft _fft = AsrRealFft(nFft);

  /// 帧数（`center=True`）：`1 + L / hop`。
  static int frameCount(int numSamples) =>
      numSamples <= 0 ? 0 : 1 + numSamples ~/ hopLength;

  /// 参与归一化的有效帧数：`(L + n_fft/2·2 − n_fft) / hop = L / hop`。
  static int validFrameCount(int numSamples) =>
      numSamples <= 0 ? 0 : numSamples ~/ hopLength;

  AsrNemoMelFeatures compute(Float32List samples) {
    final int n = samples.length;
    final int frames = frameCount(n);
    final int valid = validFrameCount(n);
    final Float32List out = Float32List(frames * numMels);
    if (frames == 0) {
      return (features: out, frames: 0, validFrames: 0);
    }
    // 预加重后的整段，两侧补零 n_fft/2。
    const int pad = nFft ~/ 2;
    final Float64List padded = Float64List(n + 2 * pad);
    padded[pad] = samples[0];
    for (int i = 1; i < n; i++) {
      padded[pad + i] = samples[i] - preemphasis * samples[i - 1];
    }

    final Float64List frame = Float64List(nFft);
    final Float64List power = Float64List(nFft ~/ 2 + 1);
    final Float64List mel = Float64List(numMels);
    for (int t = 0; t < frames; t++) {
      final int base = t * hopLength;
      for (int k = 0; k < nFft; k++) {
        frame[k] = padded[base + k] * _window[k];
      }
      _fft.powerSpectrum(frame, power);
      for (int m = 0; m < numMels; m++) {
        final ({int first, Float64List weights}) f = _filters[m];
        double acc = 0;
        for (int k = 0; k < f.weights.length; k++) {
          acc += f.weights[k] * power[f.first + k];
        }
        mel[m] = acc;
      }
      final int row = t * numMels;
      for (int m = 0; m < numMels; m++) {
        out[row + m] = math.log(mel[m] + logGuard);
      }
    }
    _normalizePerFeature(out, frames, valid);
    return (features: out, frames: frames, validFrames: valid);
  }

  static void _normalizePerFeature(Float32List x, int frames, int valid) {
    if (valid <= 0) {
      x.fillRange(0, x.length, 0);
      return;
    }
    final Float64List mean = Float64List(numMels);
    for (int t = 0; t < valid; t++) {
      final int row = t * numMels;
      for (int m = 0; m < numMels; m++) {
        mean[m] += x[row + m];
      }
    }
    for (int m = 0; m < numMels; m++) {
      mean[m] /= valid;
    }
    final Float64List variance = Float64List(numMels);
    for (int t = 0; t < valid; t++) {
      final int row = t * numMels;
      for (int m = 0; m < numMels; m++) {
        final double d = x[row + m] - mean[m];
        variance[m] += d * d;
      }
    }
    final int dof = math.max(valid - 1, 1);
    final Float64List inv = Float64List(numMels);
    for (int m = 0; m < numMels; m++) {
      inv[m] = 1 / (math.sqrt(variance[m] / dof) + normEpsilon);
    }
    for (int t = 0; t < frames; t++) {
      final int row = t * numMels;
      if (t >= valid) {
        x.fillRange(row, row + numMels, 0);
        continue;
      }
      for (int m = 0; m < numMels; m++) {
        x[row + m] = (x[row + m] - mean[m]) * inv[m];
      }
    }
  }

  /// 400 点对称 Hann（`0.5 − 0.5·cos(2πn/(N−1))`），居中补零到 512。
  static Float64List _buildWindow() {
    final Float64List w = Float64List(nFft);
    const int left = (nFft - winLength) ~/ 2;
    for (int n = 0; n < winLength; n++) {
      w[left + n] = 0.5 - 0.5 * math.cos(2 * math.pi * n / (winLength - 1));
    }
    return w;
  }

  static double _hzToMel(double f) {
    const double fSp = 200.0 / 3;
    const double minLogHz = 1000.0;
    const double minLogMel = minLogHz / fSp;
    final double logStep = math.log(6.4) / 27.0;
    return f >= minLogHz
        ? minLogMel + math.log(f / minLogHz) / logStep
        : f / fSp;
  }

  static double _melToHz(double m) {
    const double fSp = 200.0 / 3;
    const double minLogHz = 1000.0;
    const double minLogMel = minLogHz / fSp;
    final double logStep = math.log(6.4) / 27.0;
    return m >= minLogMel
        ? minLogHz * math.exp(logStep * (m - minLogMel))
        : fSp * m;
  }

  /// librosa `filters.mel(sr=16000, n_fft=512, n_mels=80, fmin=0, fmax=8000,
  /// htk=False, norm="slaney")`：三角滤波 × `2/(f[i+2]−f[i])`。每个滤波器只存
  /// 非零区间。
  static List<({int first, Float64List weights})> _buildSlaneyFilters() {
    const int bins = nFft ~/ 2 + 1;
    const double fMax = kAsrSampleRate / 2;
    final Float64List fftFreqs = Float64List(bins);
    for (int k = 0; k < bins; k++) {
      fftFreqs[k] = fMax * k / (bins - 1);
    }
    final double melMin = _hzToMel(0);
    final double melMax = _hzToMel(fMax);
    final Float64List hz = Float64List(numMels + 2);
    for (int i = 0; i < numMels + 2; i++) {
      hz[i] = _melToHz(melMin + (melMax - melMin) * i / (numMels + 1));
    }
    final List<({int first, Float64List weights})> out =
        <({int first, Float64List weights})>[];
    for (int m = 0; m < numMels; m++) {
      final double lo = hz[m];
      final double mid = hz[m + 1];
      final double hi = hz[m + 2];
      final double enorm = 2.0 / (hi - lo);
      int first = -1;
      int last = -1;
      final Float64List full = Float64List(bins);
      for (int k = 0; k < bins; k++) {
        final double f = fftFreqs[k];
        final double lower = (f - lo) / (mid - lo);
        final double upper = (hi - f) / (hi - mid);
        final double w = math.max(0.0, math.min(lower, upper)) * enorm;
        full[k] = w;
        if (w > 0) {
          if (first < 0) first = k;
          last = k;
        }
      }
      out.add(
        first < 0
            ? (first: 0, weights: Float64List(0))
            : (
                first: first,
                weights: Float64List.sublistView(full, first, last + 1),
              ),
      );
    }
    return out;
  }
}
