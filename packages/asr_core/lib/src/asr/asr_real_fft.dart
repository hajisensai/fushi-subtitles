/// 实输入 FFT（只出功率谱）。kaldi fbank（`asr_fbank.dart`）与 NeMo log-mel
/// （`asr_nemo_mel.dart`）共用；库内部件，不从包入口导出。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 基 2 迭代复 FFT（Float64），只暴露实输入 → 功率谱。kaldi fbank 与 NeMo log-mel
/// （`asr_nemo_mel.dart`）共用。
class AsrRealFft {
  AsrRealFft(this.size)
      : _bitReverse = _buildBitReverse(size),
        _cos = Float64List(size ~/ 2),
        _sin = Float64List(size ~/ 2),
        _re = Float64List(size),
        _im = Float64List(size) {
    if (size < 2 || (size & (size - 1)) != 0) {
      throw ArgumentError.value(size, 'size', 'FFT 长度必须是 2 的幂');
    }
    for (int k = 0; k < size ~/ 2; k++) {
      final double angle = -2 * math.pi * k / size;
      _cos[k] = math.cos(angle);
      _sin[k] = math.sin(angle);
    }
  }

  final int size;
  final Int32List _bitReverse;
  final Float64List _cos;
  final Float64List _sin;
  final Float64List _re;
  final Float64List _im;

  static Int32List _buildBitReverse(int n) {
    int bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    final Int32List table = Int32List(n);
    for (int i = 0; i < n; i++) {
      int r = 0;
      for (int b = 0; b < bits; b++) {
        r = (r << 1) | ((i >> b) & 1);
      }
      table[i] = r;
    }
    return table;
  }

  /// [input] 长度 [size] 的实信号；[power] 长度 `size/2 + 1`：
  /// `power[k] = |X[k]|²`，k = 0..size/2（与 kaldi `ComputePowerSpectrum` 布局等价）。
  void powerSpectrum(Float64List input, Float64List power) {
    final int n = size;
    for (int i = 0; i < n; i++) {
      _re[_bitReverse[i]] = input[i];
      _im[i] = 0;
    }
    for (int len = 2; len <= n; len <<= 1) {
      final int half = len >> 1;
      final int step = n ~/ len;
      for (int start = 0; start < n; start += len) {
        for (int k = 0; k < half; k++) {
          final int a = start + k;
          final int b = a + half;
          final double wr = _cos[k * step];
          final double wi = _sin[k * step];
          final double tr = _re[b] * wr - _im[b] * wi;
          final double ti = _re[b] * wi + _im[b] * wr;
          _re[b] = _re[a] - tr;
          _im[b] = _im[a] - ti;
          _re[a] += tr;
          _im[a] += ti;
        }
      }
    }
    for (int k = 0; k <= n ~/ 2; k++) {
      power[k] = _re[k] * _re[k] + _im[k] * _im[k];
    }
  }
}
