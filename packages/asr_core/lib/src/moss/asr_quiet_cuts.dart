/// 静音切点：把长音频在「最安静的 400 ms」处切成约 [targetSeconds] 一块。
///
/// 移植自 asr_bench 已验证的 `run_moss.py` 的 `quiet_cuts`（K-ON 等 12 集实测），
/// 行为逐项对齐：
/// - 20 ms 一帧，帧电平 `10·log10(mean(x²) + 1e-10)` dB；
/// - 400 ms 滑动平均（numpy `convolve(mode="same")` 口径：偶数窗口对 i 取
///   `[i - k/2, i + k/2 - 1]`，越界部分按 0 dB 计入——边缘因此偏「响」，不会被
///   选成切点）；
/// - 第 n 个切点在「上一个切点 + target」的 ±[searchSeconds] 内取最低点；
/// - 剩余不足 `minTailFraction × target` 就不再切（避免切出一个几十秒的尾巴）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_types.dart';

/// 能量帧长（毫秒）。与原型的 `hop = 0.02 s` 一致。
const int kAsrQuietCutFrameMs = 20;

/// 一帧样本数（16 kHz）。
const int kAsrQuietCutFrameSamples =
    kAsrSampleRate * kAsrQuietCutFrameMs ~/ 1000;

/// 在 16 kHz 单声道 [samples]（float32，[-1, 1)）上求切点，单位秒、升序。
///
/// 返回值只含**内部切点**，不含 0 与总时长；切点恒落在帧边界上
/// （`秒 × 16000` 是 [kAsrQuietCutFrameSamples] 的整数倍）。
List<double> asrQuietCuts(
  Float32List samples, {
  required double targetSeconds,
  double searchSeconds = 60,
  double windowSeconds = 0.4,
  double minTailFraction = 0.4,
}) {
  if (targetSeconds <= 0) {
    throw ArgumentError.value(targetSeconds, 'targetSeconds', '必须为正');
  }
  const int hop = kAsrQuietCutFrameSamples;
  const double frameSeconds = kAsrQuietCutFrameMs / 1000;
  final int frameCount = samples.length ~/ hop;
  if (frameCount == 0) return <double>[];

  // 帧电平（dB）。
  final Float64List db = Float64List(frameCount);
  for (int f = 0; f < frameCount; f++) {
    final int base = f * hop;
    double acc = 0;
    for (int i = 0; i < hop; i++) {
      final double v = samples[base + i];
      acc += v * v;
    }
    db[f] = 10 * math.log(acc / hop + 1e-10) / math.ln10;
  }

  // 滑动平均：对 i 取 [i - (k-1-off), i + off]，越界部分为 0、分母恒为 k。
  // 逐窗直接求和而不用前缀和相减：前缀和的舍入噪声会打破相等电平之间的并列，
  // 让「取最早一帧」的语义随机漂移。
  final int k =
      math.max(1, (windowSeconds * 1000).round() ~/ kAsrQuietCutFrameMs);
  final int off = (k - 1) ~/ 2;
  double smoothAt(int i) {
    final int lo = math.max(0, i - (k - 1 - off));
    final int hi = math.min(frameCount - 1, i + off);
    double sum = 0;
    for (int m = lo; m <= hi; m++) {
      sum += db[m];
    }
    return sum / k;
  }

  final double total = samples.length / kAsrSampleRate;
  final List<double> cuts = <double>[];
  double t = targetSeconds;
  while (t < total - targetSeconds * minTailFraction) {
    // 原型用 int() 截断换算帧号；这里同样截断，再夹到合法范围。
    final int lo = math.max(0, ((t - searchSeconds) / frameSeconds).floor());
    final int hi = math.min(
      frameCount,
      (math.min(t + searchSeconds, total) / frameSeconds).floor(),
    );
    if (hi <= lo) break;
    int best = lo;
    double bestValue = smoothAt(lo);
    for (int i = lo + 1; i < hi; i++) {
      final double v = smoothAt(i);
      // 严格小于：并列时取最早的一帧（numpy argmin 语义）。
      if (v < bestValue) {
        bestValue = v;
        best = i;
      }
    }
    final double cut = best * hop / kAsrSampleRate;
    // 防御：切点不前进就停（参数病态时不死循环）。
    if (cuts.isNotEmpty && cut <= cuts.last) break;
    cuts.add(cut);
    t = cut + targetSeconds;
  }
  return cuts;
}
