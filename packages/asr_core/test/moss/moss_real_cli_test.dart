/// 真机跑一次 MOSS（默认 skip）。
///
/// 需要本机已有 audio.cpp CLI、MOSS GGUF 与一段 16 kHz 单声道 PCM_16 wav：
///
/// ```
/// MOSS_CLI=C:/asr_bench/tools/audiocpp/audiocpp_cli.exe \
/// MOSS_MODEL=C:/asr_bench/models/moss/moss-transcribe-diarize-q8_0.gguf \
/// MOSS_AUDIO=C:/asr_bench/audio/kon.wav \
/// MOSS_REFERENCE=C:/asr_bench/out/moss_c300/kon.json \
/// dart test test/moss/moss_real_cli_test.dart
/// ```
///
/// 可选：`MOSS_BACKEND`（cuda / vulkan / cpu，默认 cuda）、`MOSS_WORK_DIR`
/// （默认临时目录，跑完删除；给了就保留缓存，可验证续跑）、`MOSS_OUT`（把结果
/// JSON 写到这里）。`MOSS_REFERENCE` 是 asr_bench `run_moss.py` 的输出，用来
/// 对比 cue 数与切点。
@Tags(<String>['moss'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:test/test.dart';

/// 读 16 kHz 单声道 PCM_16 wav（逐 chunk 找 `fmt ` 与 `data`）。
Float32List _readWav(String path) {
  final Uint8List bytes = File(path).readAsBytesSync();
  final ByteData v = ByteData.sublistView(bytes);
  int offset = 12;
  int? channels;
  int? rate;
  int? bits;
  while (offset + 8 <= bytes.length) {
    final String id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final int size = v.getUint32(offset + 4, Endian.little);
    final int body = offset + 8;
    if (id == 'fmt ') {
      channels = v.getUint16(body + 2, Endian.little);
      rate = v.getUint32(body + 4, Endian.little);
      bits = v.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (channels != 1 || rate != kAsrSampleRate || bits != 16) {
        throw FormatException('要 16 kHz 单声道 16 bit，实际 '
            '$rate Hz / $channels ch / $bits bit');
      }
      final int end = (body + size).clamp(0, bytes.length);
      return pcmS16leToFloat32(Uint8List.sublistView(bytes, body, end));
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('wav 里没有 data chunk');
}

void main() {
  final Map<String, String> env = Platform.environment;
  final String? cli = env['MOSS_CLI'];
  final String? model = env['MOSS_MODEL'];
  final String? audio = env['MOSS_AUDIO'];
  final bool configured = cli != null && model != null && audio != null;

  test(
    '真 audio.cpp + MOSS 跑通整段音频',
    () async {
      final AudioCppBackend backend = AudioCppBackend.values.firstWhere(
        (AudioCppBackend b) => b.cliValue == (env['MOSS_BACKEND'] ?? 'cuda'),
      );
      final Float32List pcm = _readWav(audio!);
      final String? keep = env['MOSS_WORK_DIR'];
      final Directory work = keep != null
          ? Directory(keep)
          : await Directory.systemTemp.createTemp('moss_real_');
      final Stopwatch watch = Stopwatch()..start();
      final MossTranscript t;
      try {
        t = await MossRunner(
          cliPath: cli!,
          modelPath: model!,
          backend: backend,
        ).run(
          pcm,
          workDir: work,
          onProgress: (MossProgress pr) =>
              print('progress ${pr.processedSeconds.toStringAsFixed(1)}/'
                  '${pr.totalSeconds.toStringAsFixed(1)} s, '
                  'chunks ${pr.completedChunks}, splits ${pr.splitCount}'),
        );
      } finally {
        if (keep == null) await work.delete(recursive: true);
      }
      watch.stop();
      final double wall = watch.elapsedMilliseconds / 1000;
      print(
          'MOSS ${backend.cliValue}: audio ${t.audioSeconds.toStringAsFixed(1)} s, '
          '${t.chunkCount} chunks, ${t.splitCount} splits, ${t.cues.length} cues, '
          'wall ${wall.toStringAsFixed(1)} s, '
          'RTF ${(wall / t.audioSeconds).toStringAsFixed(4)}');
      print('cuts ${t.chunkEdgesSeconds}');
      final String? out = env['MOSS_OUT'];
      if (out != null) {
        File(out).writeAsStringSync(
            const JsonEncoder.withIndent(' ').convert(t.toJson()));
      }

      expect(t.cues, isNotEmpty);
      for (int i = 1; i < t.cues.length; i++) {
        expect(t.cues[i].startMs, greaterThanOrEqualTo(t.cues[i - 1].startMs));
      }
      for (final MossCue c in t.cues) {
        expect(c.endMs, greaterThan(c.startMs));
        expect(c.text.trim(), isNotEmpty);
        expect(c.speaker, matches(RegExp(r'^\d+:S\d+$')));
      }

      final String? reference = env['MOSS_REFERENCE'];
      if (reference != null) {
        final Map<String, Object?> ref =
            jsonDecode(File(reference).readAsStringSync())
                as Map<String, Object?>;
        final int refCues = (ref['cues']! as List<Object?>).length;
        final List<double> refCuts = <double>[
          for (final Object? c in ref['cuts']! as List<Object?>)
            (c! as num).toDouble(),
        ];
        print('reference: $refCues cues, cuts $refCuts');
        // 切点是确定性的：与 Python 原型逐个一致（容差一帧）。
        expect(t.chunkEdgesSeconds, hasLength(refCuts.length));
        for (int i = 0; i < refCuts.length; i++) {
          expect(t.chunkEdgesSeconds[i], closeTo(refCuts[i], 0.021));
        }
        // 解码有 GPU 非确定性，cue 数只要求接近。
        expect(
            (t.cues.length - refCues).abs(), lessThanOrEqualTo(refCues ~/ 10));
      }
    },
    skip: configured ? false : '设 MOSS_CLI / MOSS_MODEL / MOSS_AUDIO 才跑',
    timeout: const Timeout(Duration(minutes: 60)),
  );
}
