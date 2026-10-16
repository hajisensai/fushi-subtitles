import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'asr_types.dart';

/// 能量包络的帧长（毫秒）。
const int kAsrEnergyFrameMs = 20;

/// 一帧的样本数（16 kHz）。
const int kAsrEnergyFrameSamples = kAsrSampleRate * kAsrEnergyFrameMs ~/ 1000;

/// 包络文件里「这帧没算过」的值（文件空洞读出来是 0）：读端一律当作有声，
/// 宁可不吸附也不凭空造出静音谷。
const int kAsrEnergyUnknownDb = 0;

/// 转录任务目录里第 [fileIndex] 个音频的能量包络：每 [kAsrEnergyFrameMs] 一帧
/// 一个有符号字节（RMS 电平，整数 dBFS，夹 [−100, −1]；0 = 未算）。帧 k 覆盖
/// 该文件的样本 `[k·320, (k+1)·320)`，按偏移随机写入：续跑从 resumeSample 重新
/// 解码时覆写同一位置，不需要额外检查点。10 小时约 1.8 MB。
String asrEnergyEnvelopePath(Directory jobDir, int fileIndex) =>
    p.join(jobDir.path, 'transcript.energy.$fileIndex');

/// 把一块 PCM 的整帧电平写进 [file]（块首尾不满一帧的样本跳过，留 0 = 未算）。
Future<void> writeAsrEnergyChunk(File file, AsrPcmChunk chunk) async {
  const int fs = kAsrEnergyFrameSamples;
  final int firstFrame = (chunk.startSample + fs - 1) ~/ fs;
  final int skip = firstFrame * fs - chunk.startSample;
  final int n = (chunk.samples.length - skip) ~/ fs;
  if (n <= 0) return;
  final Int8List out = Int8List(n);
  for (int f = 0; f < n; f++) {
    final int base = skip + f * fs;
    double acc = 0;
    for (int i = 0; i < fs; i++) {
      final double v = chunk.samples[base + i];
      acc += v * v;
    }
    final double db = acc <= 0 ? -100 : 10 * math.log(acc / fs) / math.ln10;
    out[f] = db.round().clamp(-100, -1);
  }
  final RandomAccessFile raf = await file.open(mode: FileMode.append);
  try {
    await raf.setPosition(firstFrame);
    await raf.writeFrom(out);
  } finally {
    await raf.close();
  }
}

/// 读回一个音频的能量包络；文件不存在返回 null。
Int8List? readAsrEnergyEnvelope(Directory jobDir, int fileIndex) {
  final File f = File(asrEnergyEnvelopePath(jobDir, fileIndex));
  if (!f.existsSync()) return null;
  return Int8List.sublistView(f.readAsBytesSync());
}

/// 整个任务（可能多个音频文件）在单时间轴上的能量包络：各文件按 `state.json`
/// 的时长依次拼接（与 cue 时间同一时间轴，见 `asrFileOffsetsFromDurations`）。
/// 缺状态 / 任一文件时长未知 / 一个包络都没有时返回 null；个别文件缺包络时该段
/// 留 0（未知，下游按有声处理）。
Int8List? readAsrEnergyTimeline(Directory jobDir) {
  final File stateFile = File(p.join(jobDir.path, 'state.json'));
  if (!stateFile.existsSync()) return null;
  final Object? json = jsonDecode(stateFile.readAsStringSync());
  if (json is! Map<String, Object?>) return null;
  final Object? durations = json['fileDurationsMs'];
  if (durations is! List<Object?> || durations.isEmpty) return null;
  final List<int> frames = <int>[];
  for (final Object? d in durations) {
    if (d is! num) return null;
    frames.add(d.toInt() ~/ kAsrEnergyFrameMs);
  }
  final Int8List out = Int8List(frames.fold<int>(0, (int a, int b) => a + b));
  bool any = false;
  int offset = 0;
  for (int i = 0; i < frames.length; i++) {
    final Int8List? env = readAsrEnergyEnvelope(jobDir, i);
    if (env != null) {
      any = true;
      out.setRange(offset, offset + math.min(env.length, frames[i]), env);
    }
    offset += frames[i];
  }
  return any ? out : null;
}
