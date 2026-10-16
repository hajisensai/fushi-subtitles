import 'dart:convert';
import 'dart:io';
import 'package:fushi_asr/asr.dart';

Future<void> main(List<String> args) async {
  final coreml = args.contains('--coreml');
  final reuse = !args.contains('--no-reuse');
  args = args.where((arg) => !arg.startsWith('--')).toList();
  if (args.isEmpty) {
    stderr.writeln(
        'usage: reazon_benchmark [--coreml] [--no-reuse] <audio.wav> ...');
    exitCode = 64;
    return;
  }
  final runner = TranscribeRunner(
    registry: AsrModelRegistry.builtin(),
    forceCpu: !coreml,
    forceCoreMl: coreml,
    reuseCoreMlSessions: reuse,
    missingModel: MissingModelPolicy.fail,
  );
  final results = <Object>[];
  try {
    for (final path in args) {
      final watch = Stopwatch()..start();
      final outcome = await runner.run(
          audioPaths: [path],
          language: AsrLanguage.japanese,
          // ReazonSpeech 基准：干净朗读（有声书 / 测试集）。混音素材上日语会
          // 选 Parakeet，就不是这个脚本要测的模型了。
          audioProfile: AsrAudioProfile.cleanSpeech,
          format: SubtitleFormat.json);
      watch.stop();
      if (coreml &&
          outcome.provider?.effective != OnnxExecutionProvider.coreml) {
        throw StateError('CoreML benchmark fell back: ${outcome.provider}');
      }
      if (outcome.cues.isEmpty) throw StateError('No transcription results');
      results.add({
        'engine': 'reazonspeech-k2-v2-${coreml ? 'coreml' : 'cpu'}',
        'provider': outcome.provider.toString(),
        'audio_seconds': outcome.audioMs / 1000,
        'pipeline_seconds': watch.elapsedMicroseconds / 1e6,
        'input': path,
        'reuse_sessions': reuse && coreml,
        'rss_bytes': ProcessInfo.currentRss,
        'peak_rss_bytes': ProcessInfo.maxRss,
        if (outcome.decodeStats case final stats?)
          'decode_stats': {
            'batches': stats.batches,
            'segments': stats.segments,
            'padding_ratio': stats.paddingRatio,
            // Includes scheduling waits; not CPU time or additive wall time.
            'fbank_elapsed_seconds': stats.fbank.inMicroseconds / 1e6,
            'encoder_seconds': stats.encoder.inMicroseconds / 1e6,
            'search_seconds': stats.search.inMicroseconds / 1e6,
          },
        'segments': (jsonDecode(outcome.text) as Map<String, dynamic>)['cues'],
      });
    }
  } finally {
    await runner.close();
  }
  stdout.writeln(
      jsonEncode(results.length == 1 ? results.single : {'runs': results}));
}
