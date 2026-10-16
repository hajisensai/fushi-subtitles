/// NeMo log-mel 前端（Parakeet / Kitsune 等 FastConformer CTC 用），逐项对齐
/// onnx_asr 的 `NemoPreprocessorNumpy` 与 SubThx `mel.rs`：
///
/// 1. 预加重 0.97（首样本前视为 0），整段之外补零；
/// 2. 居中 STFT：左右各补 `n_fft/2`，n_fft 512、Hann 400（`np.hanning`，居中
///    零填到 512）、hop 160（10 ms）；
/// 3. 功率谱 × slaney mel 滤波器组（`[257, n_mels]`，随模型包下发的 npy，不在
///    代码里重算，保证与导出端逐值一致）；
/// 4. `log(x + 2^-24)`；
/// 5. 每个 mel 维在**有效帧**上做均值 / 标准差（ddof = 1）归一化，`std + 1e-5`；
///    有效帧之外置零。
///
/// 输出布局 `[B, n_mels, T]`（行主序），`T = maxLen / 160 + 1`，有效帧数
/// `len / 160`——与导出图的 `features` / `lengths` 输入一致。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_fbank.dart' show AsrRealFft;
import 'package:fushi_asr_core/src/asr/asr_fbank_workers.dart';

/// NeMo log-mel 的固定帧参数。
abstract final class AsrNemoMelParams {
  static const int nFft = 512;
  static const int window = 400;
  static const int hop = 160;
  static const double preemphasis = 0.97;
}

/// 一批段的特征：`features` 为 `[batch, nMels, frames]` 行主序。
class AsrNemoMelBatch {
  const AsrNemoMelBatch({
    required this.features,
    required this.lengths,
    required this.batch,
    required this.nMels,
    required this.frames,
  });

  final Float32List features;

  /// 每段的有效帧数（`samples ~/ hop`）。
  final Int64List lengths;
  final int batch;
  final int nMels;
  final int frames;
}

class AsrNemoMel {
  AsrNemoMel(this.filterbank, this.nMels)
    : assert(filterbank.length == (AsrNemoMelParams.nFft ~/ 2 + 1) * nMels),
      _lo = Int32List(nMels),
      _hi = Int32List(nMels) {
    // 三角滤波器只在少数 bin 上非零：记下每个 mel 维的非零区间，乘法按区间
    // 走（稠密 257×80 每帧两万次乘加，10 h 音频单线程要一分多钟）。
    const int bins = AsrNemoMelParams.nFft ~/ 2 + 1;
    for (int m = 0; m < nMels; m++) {
      int lo = bins;
      int hi = 0;
      for (int k = 0; k < bins; k++) {
        if (filterbank[k * nMels + m] != 0) {
          if (k < lo) lo = k;
          hi = k + 1;
        }
      }
      _lo[m] = lo < hi ? lo : 0;
      _hi[m] = hi;
    }
  }

  /// 从 numpy `.npy`（float32 / float64，C 序，形状 `[257, n_mels]`）读滤波器组。
  factory AsrNemoMel.fromNpy(Uint8List bytes) {
    final ({List<int> shape, Float32List data}) npy = readNpyFloat(bytes);
    if (npy.shape.length != 2 ||
        npy.shape[0] != AsrNemoMelParams.nFft ~/ 2 + 1) {
      throw FormatException('mel 滤波器组形状异常：${npy.shape}');
    }
    return AsrNemoMel(npy.data, npy.shape[1]);
  }

  /// `[257 × nMels]`，行 = FFT bin。
  final Float32List filterbank;
  final int nMels;
  final Int32List _lo;
  final Int32List _hi;

  static final Float64List _window = _buildWindow();

  static Float64List _buildWindow() {
    const int n = AsrNemoMelParams.nFft;
    const int w = AsrNemoMelParams.window;
    const int off = (n - w) ~/ 2;
    final Float64List out = Float64List(n);
    for (int i = 0; i < w; i++) {
      out[off + i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (w - 1));
    }
    return out;
  }

  /// 一批段 → 特征。[padTo]：把批内最长段向上取整到它的倍数（样本），减少
  /// 不同的编码器输入形状（GPU EP 每个新形状要编译一次）；1 = 精确长度。
  AsrNemoMelBatch batch(List<Float32List> wavs, {int padTo = 1}) => assemble(
    <Float32List>[for (final Float32List w in wavs) compute(w)],
    <int>[for (final Float32List w in wavs) w.length],
    nMels,
    padTo: padTo,
  );

  /// 把逐段 [compute] 的结果拼成 `[B, nMels, T]`，有效帧之外补零。
  /// [sampleCounts]：各段原始样本数（决定 `T`）。
  static AsrNemoMelBatch assemble(
    List<Float32List> perSegment,
    List<int> sampleCounts,
    int nMels, {
    int padTo = 1,
  }) {
    int longest = 0;
    for (final int n in sampleCounts) {
      longest = math.max(longest, n);
    }
    final int unit = math.max(1, padTo);
    final int maxLen = (longest + unit - 1) ~/ unit * unit;
    final int frames = maxLen ~/ AsrNemoMelParams.hop + 1;
    final Float32List out = Float32List(perSegment.length * nMels * frames);
    final Int64List lengths = Int64List(perSegment.length);
    for (int b = 0; b < perSegment.length; b++) {
      final int valid = perSegment[b].length ~/ nMels;
      lengths[b] = valid;
      for (int m = 0; m < nMels; m++) {
        final int dst = (b * nMels + m) * frames;
        out.setRange(dst, dst + valid, perSegment[b], m * valid);
      }
    }
    return AsrNemoMelBatch(
      features: out,
      lengths: lengths,
      batch: perSegment.length,
      nMels: nMels,
      frames: frames,
    );
  }

  /// 一段 → 归一化 log-mel，布局 `[nMels, valid]`（`valid = len ~/ hop`）。
  Float32List compute(Float32List w) {
    final int valid = w.length ~/ AsrNemoMelParams.hop;
    final Float32List dst = Float32List(valid * nMels);
    _one(AsrRealFft(AsrNemoMelParams.nFft), w, valid, dst, 0);
    return dst;
  }

  void _one(
    AsrRealFft fft,
    Float32List w,
    int frames,
    Float32List dst,
    int dstOffset,
  ) {
    const int nFft = AsrNemoMelParams.nFft;
    const int hop = AsrNemoMelParams.hop;
    const int pad = nFft ~/ 2;
    const int bins = nFft ~/ 2 + 1;
    final int valid = w.length ~/ hop;
    if (valid == 0) return;
    // 预加重 + 居中补零（只需覆盖有效帧会读到的范围）。
    final int need = (valid - 1) * hop + nFft;
    final Float64List x = Float64List(need);
    for (int i = 0; i < w.length && pad + i < need; i++) {
      final double prev = i == 0 ? 0 : w[i - 1];
      x[pad + i] = w[i] - AsrNemoMelParams.preemphasis * prev;
    }
    final Float64List frame = Float64List(nFft);
    final Float64List power = Float64List(bins);
    final Float32List power32 = Float32List(bins);
    final Float32List logmel = Float32List(valid * nMels);
    final double floor = math.pow(2, -24).toDouble();
    for (int f = 0; f < valid; f++) {
      final int s = f * hop;
      for (int i = 0; i < nFft; i++) {
        frame[i] = x[s + i] * _window[i];
      }
      fft.powerSpectrum(frame, power);
      // 与参考实现一样先把功率收成 float32 再乘滤波器组。
      for (int k = 0; k < bins; k++) {
        power32[k] = power[k];
      }
      final int row = f * nMels;
      for (int m = 0; m < nMels; m++) {
        double acc = 0;
        for (int k = _lo[m]; k < _hi[m]; k++) {
          acc += power32[k] * filterbank[k * nMels + m];
        }
        logmel[row + m] = math.log(acc + floor);
      }
    }
    for (int m = 0; m < nMels; m++) {
      double sum = 0;
      for (int f = 0; f < valid; f++) {
        sum += logmel[f * nMels + m];
      }
      final double mean = sum / valid;
      double sq = 0;
      for (int f = 0; f < valid; f++) {
        final double d = logmel[f * nMels + m] - mean;
        sq += d * d;
      }
      final double std = valid > 1 ? math.sqrt(sq / (valid - 1)) : 0;
      final double denom = std + 1e-5;
      final int col = dstOffset + m * frames;
      for (int f = 0; f < valid; f++) {
        dst[col + f] = (logmel[f * nMels + m] - mean) / denom;
      }
    }
  }
}

/// [AsrNemoMel.compute] 的 isolate 池：与 `AsrFbankWorkers` 同一套分组与
/// [TransferableTypedData] 搬运，结果与逐段 [AsrNemoMel.compute] 逐元素相同。
class AsrNemoMelWorkers {
  AsrNemoMelWorkers(this.mel, {int? workers})
    : workers = workers ?? defaultAsrFbankWorkerCount();

  final AsrNemoMel mel;
  final int workers;

  Future<List<Float32List>> computeAll(List<Float32List> samples) async {
    if (samples.isEmpty) return const <Float32List>[];
    final List<List<int>> groups = AsrFbankWorkers.balancedGroups(
      samples.map((Float32List s) => s.length).toList(growable: false),
      workers,
    );
    final List<Float32List> flat = await Future.wait(
      groups.map(
        (List<int> g) => _runGroup(
          g.map((int i) => samples[i]).toList(growable: false),
          mel,
        ),
      ),
    );
    final List<Float32List> out = List<Float32List>.filled(
      samples.length,
      Float32List(0),
    );
    for (int gi = 0; gi < groups.length; gi++) {
      int offset = 0;
      for (final int i in groups[gi]) {
        final int len = samples[i].length ~/ AsrNemoMelParams.hop * mel.nMels;
        out[i] = Float32List.sublistView(flat[gi], offset, offset + len);
        offset += len;
      }
    }
    return out;
  }

  static Future<Float32List> _runGroup(
    List<Float32List> samples,
    AsrNemoMel mel,
  ) async {
    final List<int> lengths = samples
        .map((Float32List s) => s.length)
        .toList(growable: false);
    final TransferableTypedData packed = TransferableTypedData.fromList(
      samples,
    );
    final TransferableTypedData result = await Isolate.run(() {
      final Float32List all = packed.materialize().asFloat32List();
      final List<Float32List> parts = <Float32List>[];
      int offset = 0;
      for (final int len in lengths) {
        parts.add(
          mel.compute(Float32List.sublistView(all, offset, offset + len)),
        );
        offset += len;
      }
      return TransferableTypedData.fromList(parts);
    });
    return result.materialize().asFloat32List();
  }
}

/// 读 numpy `.npy`（v1/v2/v3，`<f4` / `<f8`，C 序）为 float32 与形状。
({List<int> shape, Float32List data}) readNpyFloat(Uint8List bytes) {
  const List<int> magic = <int>[0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59];
  for (int i = 0; i < magic.length; i++) {
    if (bytes.length <= i || bytes[i] != magic[i]) {
      throw const FormatException('不是 .npy 文件');
    }
  }
  final int major = bytes[6];
  final ByteData view = ByteData.sublistView(bytes);
  final int headerLen;
  final int headerStart;
  if (major == 1) {
    headerLen = view.getUint16(8, Endian.little);
    headerStart = 10;
  } else {
    headerLen = view.getUint32(8, Endian.little);
    headerStart = 12;
  }
  final String header = latin1.decode(
    bytes.sublist(headerStart, headerStart + headerLen),
  );
  final String descr =
      RegExp(r"'descr'\s*:\s*'([^']+)'").firstMatch(header)?.group(1) ?? '';
  if (RegExp(r"'fortran_order'\s*:\s*True").hasMatch(header)) {
    throw const FormatException('.npy 为 Fortran 序，不支持');
  }
  final String shapeText =
      RegExp(r"'shape'\s*:\s*\(([^)]*)\)").firstMatch(header)?.group(1) ?? '';
  final List<int> shape = <int>[
    for (final String part in shapeText.split(','))
      if (part.trim().isNotEmpty) int.parse(part.trim()),
  ];
  final int count = shape.fold<int>(1, (int a, int b) => a * b);
  final int dataStart = headerStart + headerLen;
  final Float32List data = Float32List(count);
  if (descr == '<f4') {
    for (int i = 0; i < count; i++) {
      data[i] = view.getFloat32(dataStart + i * 4, Endian.little);
    }
  } else if (descr == '<f8') {
    for (int i = 0; i < count; i++) {
      data[i] = view.getFloat64(dataStart + i * 8, Endian.little);
    }
  } else {
    throw FormatException('.npy dtype 不支持：$descr');
  }
  return (shape: shape, data: data);
}
