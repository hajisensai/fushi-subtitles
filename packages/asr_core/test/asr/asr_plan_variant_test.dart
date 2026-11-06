import 'package:test/test.dart';
import 'package:fushi_asr_core/src/asr/asr_engine.dart';
import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';

/// BUG-4128：推荐变体随显存预算浮动，「装没装」不能只看推荐的那个。
void main() {
  bool Function(AsrEncoderVariant) readySet(Set<AsrEncoderVariant> ready) =>
      (AsrEncoderVariant v) => ready.contains(v);

  group('usableAsrEncoderVariants', () {
    test('推荐 int8 → 只有 int8（fp32 此刻不划算 / 装不下）', () {
      for (final AsrAccelerationPreference pref
          in AsrAccelerationPreference.values) {
        expect(
          usableAsrEncoderVariants(
            recommended: AsrEncoderVariant.int8,
            preference: pref,
          ),
          <AsrEncoderVariant>[AsrEncoderVariant.int8],
          reason: pref.name,
        );
      }
    });

    test('推荐 fp32 + auto → fp32 优先，int8 可兜底', () {
      expect(
        usableAsrEncoderVariants(
          recommended: AsrEncoderVariant.fp32,
          preference: AsrAccelerationPreference.auto,
        ),
        <AsrEncoderVariant>[AsrEncoderVariant.fp32, AsrEncoderVariant.int8],
      );
    });

    test('推荐 fp32 + 显式 GPU 后端 → 只有 fp32（不偷偷换成 CPU）', () {
      for (final AsrAccelerationPreference pref in <AsrAccelerationPreference>[
        AsrAccelerationPreference.coreml,
        AsrAccelerationPreference.directml,
        AsrAccelerationPreference.cuda,
      ]) {
        expect(
          usableAsrEncoderVariants(
            recommended: AsrEncoderVariant.fp32,
            preference: pref,
          ),
          <AsrEncoderVariant>[AsrEncoderVariant.fp32],
          reason: pref.name,
        );
      }
    });
  });

  group('planAsrEncoderVariant', () {
    test('反馈原样：int8 已下好、第二天预算够 → 推荐 fp32，仍规划 int8', () {
      expect(
        planAsrEncoderVariant(
          recommended: AsrEncoderVariant.fp32,
          preference: AsrAccelerationPreference.auto,
          isReady: readySet(<AsrEncoderVariant>{AsrEncoderVariant.int8}),
        ),
        AsrEncoderVariant.int8,
      );
    });

    test('两个都在盘 → 用推荐的 fp32', () {
      expect(
        planAsrEncoderVariant(
          recommended: AsrEncoderVariant.fp32,
          preference: AsrAccelerationPreference.auto,
          isReady: readySet(<AsrEncoderVariant>{
            AsrEncoderVariant.int8,
            AsrEncoderVariant.fp32,
          }),
        ),
        AsrEncoderVariant.fp32,
      );
    });

    test('都没下 → 推荐的那个（= 要下载的）', () {
      for (final AsrEncoderVariant rec in AsrEncoderVariant.values) {
        expect(
          planAsrEncoderVariant(
            recommended: rec,
            preference: AsrAccelerationPreference.auto,
            isReady: readySet(const <AsrEncoderVariant>{}),
          ),
          rec,
        );
      }
    });

    test('推荐 int8、盘上只有 fp32 → 仍规划 int8（显存不允许 fp32）', () {
      expect(
        planAsrEncoderVariant(
          recommended: AsrEncoderVariant.int8,
          preference: AsrAccelerationPreference.auto,
          isReady: readySet(<AsrEncoderVariant>{AsrEncoderVariant.fp32}),
        ),
        AsrEncoderVariant.int8,
      );
    });

    test('显式 DirectML、盘上只有 int8 → 规划 fp32（要下载），不退 CPU', () {
      expect(
        planAsrEncoderVariant(
          recommended: AsrEncoderVariant.fp32,
          preference: AsrAccelerationPreference.directml,
          isReady: readySet(<AsrEncoderVariant>{AsrEncoderVariant.int8}),
        ),
        AsrEncoderVariant.fp32,
      );
    });
  });
}
