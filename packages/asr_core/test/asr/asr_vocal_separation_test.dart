import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_model_registry.dart';
import 'package:fushi_asr_core/src/asr/asr_transcription_service.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/asr/asr_vocal_separation.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';
import 'package:test/test.dart';

/// 把输入原样当「人声」吐回：分离链路的 STFT → iSTFT → 重采样往返应当近乎无损。
class _IdentitySession implements OnnxSession {
  int runs = 0;
  List<int>? lastShape;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    runs++;
    final OnnxTensor x = inputs['input']!;
    lastShape = x.shape;
    return <String, OnnxTensor>{
      'output': OnnxTensor.float32(Float32List.fromList(x.floatData!), x.shape),
    };
  }

  @override
  Future<void> close() async {}
}

/// 什么人声都没有。
class _SilenceSession implements OnnxSession {
  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor x = inputs['input']!;
    return <String, OnnxTensor>{
      'output': OnnxTensor.float32(Float32List(x.elementCount), x.shape),
    };
  }

  @override
  Future<void> close() async {}
}

class _ListPcm implements AsrPcmSource {
  _ListPcm(this.chunks);
  final List<AsrPcmChunk> chunks;

  @override
  Future<int?> probeDurationMs(String audioPath) async => 1234;

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) =>
      Stream<AsrPcmChunk>.fromIterable(chunks);
}

Float32List _sine(int n, double hz, int rate, {double amp = 0.5}) {
  final Float32List x = Float32List(n);
  for (int i = 0; i < n; i++) {
    x[i] = amp * math.sin(2 * math.pi * hz * i / rate);
  }
  return x;
}

double _rms(Float32List x, int from, int to) {
  double acc = 0;
  for (int i = from; i < to; i++) {
    acc += x[i] * x[i];
  }
  return math.sqrt(acc / (to - from));
}

double _maxAbsDiff(Float32List a, Float32List b, int from, int to) {
  double m = 0;
  for (int i = from; i < to; i++) {
    m = math.max(m, (a[i] - b[i]).abs());
  }
  return m;
}

void main() {
  group('AsrResampler', () {
    test('16 k → 44.1 k → 16 k：长度按比例，带内正弦往返几乎无损', () {
      final AsrResampler up = AsrResampler(fromRate: 16000, toRate: 44100);
      final AsrResampler down = AsrResampler(fromRate: 44100, toRate: 16000);
      final Float32List x = _sine(16000, 440, 16000);
      final Float32List wide = up.process(x);
      expect(wide.length, 44100);
      final Float32List back = down.process(wide);
      expect(back.length, 16000);
      // 两端各让出滤波器半长，中段逐样本比对。
      expect(_maxAbsDiff(x, back, 400, 15600), lessThan(2e-3));
    });

    test('上采样保持频率：44.1 k 上 1 kHz 正弦每 44.1 个样本一个周期', () {
      final AsrResampler up = AsrResampler(fromRate: 16000, toRate: 44100);
      final Float32List wide = up.process(_sine(16000, 1000, 16000));
      final Float32List ref = _sine(44100, 1000, 44100);
      expect(_maxAbsDiff(wide, ref, 2000, 42000), lessThan(2e-3));
    });

    test('下采样滤掉新奈奎斯特以上的分量', () {
      final AsrResampler down = AsrResampler(fromRate: 44100, toRate: 16000);
      final Float32List out = down.process(_sine(44100, 12000, 44100));
      expect(_rms(out, 500, 15500), lessThan(1e-3));
    });
  });

  group('AsrVocalSeparator', () {
    test('恒等模型：分离链路（重采样 + STFT/iSTFT 分窗）往返近乎无损、长度不变', () async {
      final _IdentitySession session = _IdentitySession();
      final AsrVocalSeparator separator = AsrVocalSeparator(session);
      // 13 s：跨三个 MDX 窗口（每窗产出 257024 / 44100 ≈ 5.83 s），尾窗不满。
      final int n = 13 * kAsrSampleRate;
      final Float32List x = _sine(n, 523.25, kAsrSampleRate, amp: 0.3);
      for (int i = 0; i < n; i++) {
        x[i] += 0.2 * math.sin(2 * math.pi * 3100 * i / kAsrSampleRate);
      }
      final Float32List y = await separator.separate(x);
      expect(y.length, n);
      expect(session.runs, 3);
      expect(session.lastShape, <int>[1, 4, 2048, 256]);
      expect(_maxAbsDiff(x, y, 800, n - 800), lessThan(5e-3));
    });

    test('模型判定没有人声：输出静音', () async {
      final AsrVocalSeparator separator = AsrVocalSeparator(_SilenceSession());
      final Float32List y =
          await separator.separate(_sine(kAsrSampleRate * 2, 440, 16000));
      expect(_rms(y, 0, y.length), lessThan(1e-6));
    });

    test('空块原样返回空', () async {
      final _IdentitySession session = _IdentitySession();
      final Float32List y =
          await AsrVocalSeparator(session).separate(Float32List(0));
      expect(y, isEmpty);
      expect(session.runs, 0);
    });

    test('PCM 装饰器：逐块分离，块起点与长度不变，时长探测直通', () async {
      final AsrVocalSeparatingPcmSource pcm = AsrVocalSeparatingPcmSource(
        _ListPcm(<AsrPcmChunk>[
          AsrPcmChunk(startSample: 0, samples: _sine(16000, 440, 16000)),
          AsrPcmChunk(startSample: 16000, samples: _sine(8000, 440, 16000)),
        ]),
        AsrVocalSeparator(_SilenceSession()),
      );
      expect(await pcm.probeDurationMs('x'), 1234);
      final List<AsrPcmChunk> out = await pcm.decode('x').toList();
      expect(out.map((AsrPcmChunk c) => c.startSample), <int>[0, 16000]);
      expect(out.map((AsrPcmChunk c) => c.samples.length), <int>[16000, 8000]);
      expect(_rms(out.first.samples, 0, 16000), lessThan(1e-6));
    });
  });

  group('歌曲素材', () {
    test('选包与混音相同（同 id），只多一个两变体共用的分离模型', () {
      final AsrModelPack mixed = asrModelPackFor(
        AsrLanguage.japanese,
        profile: AsrAudioProfile.mixedAudio,
      );
      final AsrModelPack song = asrModelPackFor(
        AsrLanguage.japanese,
        profile: AsrAudioProfile.song,
      );
      expect(song.id, mixed.id);
      expect(mixed.hasVocalSeparator, isFalse);
      expect(song.hasVocalSeparator, isTrue);
      for (final AsrEncoderVariant v in AsrEncoderVariant.values) {
        expect(
          song.filesFor(v).map((AsrModelFile f) => f.fileName),
          <String>[
            ...mixed.filesFor(v).map((AsrModelFile f) => f.fileName),
            kAsrVocalSeparatorFile.fileName,
          ],
        );
        expect(
          song.totalBytes(v),
          mixed.totalBytes(v) + kAsrVocalSeparatorFile.expectedBytes,
        );
      }
      // 派生幂等，不会挂两份。
      expect(song.withVocalSeparation().files.length, song.files.length);
    });

    test('素材映射：歌曲按混音参选、做分离；其余不分离', () {
      expect(AsrAudioProfile.song.packProfile, AsrAudioProfile.mixedAudio);
      expect(AsrAudioProfile.song.separatesVocals, isTrue);
      expect(AsrAudioProfile.mixedAudio.separatesVocals, isFalse);
      expect(AsrAudioProfile.cleanSpeech.separatesVocals, isFalse);
      expect(
          kAsrParakeetJapanesePack.servesProfile(AsrAudioProfile.song), isTrue);
      // 通用包仍是通用包（加了 song 不改变「不带素材的老调用方」能看到谁）。
      expect(kAsrJapanesePack.servesProfile(null), isTrue);
      expect(kAsrParakeetJapanesePack.servesProfile(null), isFalse);
      expect(
        AsrModelRegistry.builtin()
            .packForLanguage(AsrLanguage.japanese,
                profile: AsrAudioProfile.song)
            ?.id,
        kAsrParakeetJapanesePack.id,
      );
    });

    test('任务 id：歌曲与混音分开缓存', () {
      final String mixed = AsrTranscriptionService.jobIdFor(
        <String>['/no/such/song.flac'],
        AsrLanguage.japanese,
        profile: AsrAudioProfile.mixedAudio,
      );
      final String song = AsrTranscriptionService.jobIdFor(
        <String>['/no/such/song.flac'],
        AsrLanguage.japanese,
        profile: AsrAudioProfile.song,
      );
      expect(song, isNot(mixed));
    });

    test('包清单里写 song 是错的：audioProfiles 只认声学素材', () {
      final Map<String, Object?> json = Map<String, Object?>.of(
        kAsrParakeetJapanesePack.toJson() as Map<String, Object?>,
      )..['audioProfiles'] = <String>['song'];
      expect(() => AsrModelPack.fromJson(json), throwsFormatException);
    });
  });
}
