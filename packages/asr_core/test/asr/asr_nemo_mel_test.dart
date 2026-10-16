import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_nemo_mel.dart';
import 'package:test/test.dart';

/// 与 Python 参考（SubThx mel.rs 的 numpy 移植）同一个确定性信号。
Float32List _signal(int n) {
  final Float32List out = Float32List(n);
  for (int i = 0; i < n; i++) {
    out[i] =
        0.3 * math.sin(2 * math.pi * 440 * i / 16000) +
        0.1 * math.sin(2 * math.pi * 1234 * i / 16000) * math.cos(i / 700) +
        0.01 * math.sin(i * i * 1e-5);
  }
  return out;
}

/// 合成三角滤波器组 `[257, 80]`，写成 v1 `.npy`（`<f4`）。
Uint8List _filterbankNpy() {
  final Float32List fb = Float32List(257 * 80);
  for (int k = 0; k < 257; k++) {
    for (int m = 0; m < 80; m++) {
      fb[k * 80 + m] = math.max(0.0, 1 - (k - 3 * m - 5).abs() / 4.0) / 10;
    }
  }
  String header =
      "{'descr': '<f4', 'fortran_order': False, 'shape': (257, 80), }";
  while ((10 + header.length + 1) % 64 != 0) {
    header += ' ';
  }
  header += '\n';
  final BytesBuilder b =
      BytesBuilder()
        ..add(<int>[0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 1, 0])
        ..add(<int>[header.length & 0xff, header.length >> 8])
        ..add(latin1.encode(header))
        ..add(fb.buffer.asUint8List());
  return b.toBytes();
}

void main() {
  test('与 numpy 参考实现逐值一致（含 1 s 对齐的批内补零）', () {
    final AsrNemoMel mel = AsrNemoMel.fromNpy(_filterbankNpy());
    expect(mel.nMels, 80);
    final AsrNemoMelBatch out = mel.batch(<Float32List>[
      _signal(16000 * 2 + 333),
      _signal(16000 + 77),
    ], padTo: 16000);
    expect(out.frames, 301);
    expect(out.lengths, <int>[202, 100]);
    double at(int b, int m, int t) =>
        out.features[(b * out.nMels + m) * out.frames + t];
    // Python：run_kitsune_ort.mel_one 在同一输入上的输出。
    const List<(int, int, int, double)> expected = <(int, int, int, double)>[
      (0, 0, 0, 4.57997989654541),
      (0, 10, 5, -0.602546751499176),
      (0, 40, 100, -0.11165217310190201),
      (0, 79, 201, 3.2213969230651855),
      (1, 3, 0, -9.834213256835938),
      (1, 50, 50, -0.13622011244297028),
      (1, 79, 100, 0.0),
      (1, 20, 150, 0.0),
    ];
    for (final (int b, int m, int t, double v) in expected) {
      expect(at(b, m, t), closeTo(v, 2e-3), reason: 'b=$b m=$m t=$t');
    }
    double absSum(int b) {
      double s = 0;
      for (int i = 0; i < out.nMels * out.frames; i++) {
        s += out.features[b * out.nMels * out.frames + i].abs();
      }
      return s;
    }

    expect(absSum(0), closeTo(5074.548557822534, 0.5));
    expect(absSum(1), closeTo(2807.487908995041, 0.5));
  });

  test('短于一帧的段输出全零、有效帧 0', () {
    final AsrNemoMel mel = AsrNemoMel.fromNpy(_filterbankNpy());
    final AsrNemoMelBatch out = mel.batch(<Float32List>[Float32List(100)]);
    expect(out.lengths, <int>[0]);
    expect(out.features.every((double v) => v == 0), isTrue);
  });

  test('拒绝非 npy 与形状不符的滤波器组', () {
    expect(
      () => AsrNemoMel.fromNpy(Uint8List.fromList(<int>[1, 2, 3])),
      throwsFormatException,
    );
  });
}
