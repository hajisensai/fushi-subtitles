import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_energy_envelope.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:test/test.dart';

AsrPcmChunk _chunk(int startSample, List<double> levels) {
  // 每个 level 一帧：常数幅值 a 的 RMS = a。
  final Float32List s = Float32List(levels.length * kAsrEnergyFrameSamples);
  for (int f = 0; f < levels.length; f++) {
    for (int i = 0; i < kAsrEnergyFrameSamples; i++) {
      s[f * kAsrEnergyFrameSamples + i] = levels[f];
    }
  }
  return AsrPcmChunk(startSample: startSample, samples: s);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('asr_energy_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('按帧偏移写入：静音 −100、0.1 幅值 −20 dB，没写过的帧读 0', () async {
    final File f = File(asrEnergyEnvelopePath(dir, 0));
    await writeAsrEnergyChunk(
      f,
      _chunk(2 * kAsrEnergyFrameSamples, <double>[0, 0.1, 0.1]),
    );
    expect(readAsrEnergyEnvelope(dir, 0), <int>[0, 0, -100, -20, -20]);
    expect(readAsrEnergyEnvelope(dir, 1), isNull);
  });

  test('块起点不在帧边界：跳过不满一帧的头，从下一个整帧写起', () async {
    final File f = File(asrEnergyEnvelopePath(dir, 0));
    final Float32List s = Float32List(3 * kAsrEnergyFrameSamples)
      ..fillRange(0, 3 * kAsrEnergyFrameSamples, 0.1);
    await writeAsrEnergyChunk(
      f,
      AsrPcmChunk(startSample: kAsrEnergyFrameSamples ~/ 2, samples: s),
    );
    // 样本 [160, 1120)：整帧只有 1、2（[320,960)），帧 3 不满。
    expect(readAsrEnergyEnvelope(dir, 0), <int>[0, -20, -20]);
  });

  test('多文件按 state.json 时长拼成单时间轴；缺包络的文件留 0', () async {
    File('${dir.path}/state.json').writeAsStringSync(
      '{"fileDurationsMs":[60,80,40]}',
    );
    await writeAsrEnergyChunk(
      File(asrEnergyEnvelopePath(dir, 0)),
      _chunk(0, <double>[0.1, 0.1, 0.1]),
    );
    await writeAsrEnergyChunk(
      File(asrEnergyEnvelopePath(dir, 2)),
      _chunk(0, <double>[0, 0]),
    );
    expect(
      readAsrEnergyTimeline(dir),
      <int>[-20, -20, -20, 0, 0, 0, 0, -100, -100],
    );
  });

  test('没有 state.json 或一个包络都没有：null', () {
    expect(readAsrEnergyTimeline(dir), isNull);
    File('${dir.path}/state.json').writeAsStringSync(
      '{"fileDurationsMs":[60]}',
    );
    expect(readAsrEnergyTimeline(dir), isNull);
  });

  test('续跑从中间重新解码：同一位置覆写，后面的帧保留', () async {
    final File f = File(asrEnergyEnvelopePath(dir, 0));
    await writeAsrEnergyChunk(f, _chunk(0, <double>[0.1, 0.1, 0.1, 0.1]));
    await writeAsrEnergyChunk(
      f,
      _chunk(kAsrEnergyFrameSamples, <double>[0, 0]),
    );
    expect(readAsrEnergyEnvelope(dir, 0), <int>[-20, -100, -100, -20]);
  });
}
