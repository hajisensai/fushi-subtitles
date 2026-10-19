import 'dart:typed_data';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:test/test.dart';

/// [seconds] 长的「响」信号（±0.3 交替，每帧能量恒定），在 [dips] 给出的
/// `(起点秒, 终点秒)` 区间里换成 ±0.001。
Float32List _signal(double seconds, List<(double, double)> dips) {
  final int n = (seconds * kAsrSampleRate).round();
  final Float32List out = Float32List(n);
  for (int i = 0; i < n; i++) {
    final double t = i / kAsrSampleRate;
    final bool quiet = dips.any(((double, double) d) => t >= d.$1 && t < d.$2);
    final double a = quiet ? 0.001 : 0.3;
    out[i] = i.isEven ? a : -a;
  }
  return out;
}

void main() {
  test('切点落在安静段里，取窗口完全进入安静段的最早一帧', () {
    // 安静段 600 ms、窗口 400 ms：窗口 [i-10, i+9] 帧整段落进 [1400, 1430)
    // 的最早 i 是 1410 → 28.2 s。
    final Float32List pcm = _signal(100, <(double, double)>[
      (28.0, 28.6),
      (61.0, 61.6),
    ]);
    final List<double> cuts = asrQuietCuts(
      pcm,
      targetSeconds: 30,
      searchSeconds: 6,
    );
    // 第三个目标 61.2 + 30 = 91.2 ≥ 100 − 0.4 × 30 = 88：不再切。
    expect(cuts, hasLength(2));
    expect(cuts[0], closeTo(28.2, 1e-9));
    expect(cuts[1], closeTo(61.2, 1e-9));
  });

  test('搜索窗外的安静段不会被选中', () {
    // 第一个目标 30 ± 6 = [24, 36]；10 s 处的安静段在窗外。
    final Float32List pcm = _signal(60, <(double, double)>[
      (10.0, 11.0),
      (33.0, 33.6),
    ]);
    final List<double> cuts =
        asrQuietCuts(pcm, targetSeconds: 30, searchSeconds: 6);
    expect(cuts, <Matcher>[closeTo(33.2, 1e-9)]);
  });

  test('剩余不足 0.4 × target 不切', () {
    // 40 s：30 < 40 − 12 = 28 不成立。
    expect(
      asrQuietCuts(_signal(40, const <(double, double)>[]), targetSeconds: 30),
      isEmpty,
    );
    // 50 s：30 < 38 成立，切一刀。
    expect(
      asrQuietCuts(_signal(50, const <(double, double)>[]),
          targetSeconds: 30, searchSeconds: 6),
      hasLength(1),
    );
  });

  test('切点恒在 20 ms 帧边界上', () {
    final Float32List pcm = _signal(70, <(double, double)>[(31.013, 31.7)]);
    for (final double c
        in asrQuietCuts(pcm, targetSeconds: 30, searchSeconds: 6)) {
      final double samples = c * kAsrSampleRate;
      expect(samples.round() % kAsrQuietCutFrameSamples, 0);
      expect((samples - samples.round()).abs(), lessThan(1e-6));
    }
  });

  test('空输入与非法参数', () {
    expect(asrQuietCuts(Float32List(0), targetSeconds: 30), isEmpty);
    expect(
      () => asrQuietCuts(Float32List(16000), targetSeconds: 0),
      throwsArgumentError,
    );
  });

  test('二分口径（target = 块长 / 2，search = 块长 / 4）只给一个内部切点', () {
    final Float32List pcm = _signal(80, <(double, double)>[(50.0, 50.6)]);
    final List<double> mid =
        asrQuietCuts(pcm, targetSeconds: 40, searchSeconds: 20);
    expect(mid, <Matcher>[closeTo(50.2, 1e-9)]);
  });
}
