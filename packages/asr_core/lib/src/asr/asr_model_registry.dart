/// 模型注册表：内置清单 + 用户自带清单。
///
/// 抽包前模型表是 `asr_model_manifest.dart` 里 900 行硬编码的 `const`，语言是封闭
/// 枚举，`asrModelPackFor()` 直接在常量表里 `firstWhere`——对 app 够用，对一个要
/// 分享出去的库不够：别人想接自己的 zipformer / CTC 导出就没有入口。
///
/// 这里不改内置表（它是**真相源**，字段值都是逐文件用 `onnx` 核实过的），只把
/// 「当前认得哪些包」变成可替换的一层：
///
/// ```
/// 内置 kAsrModelPacks  ──┐
///                        ├─ 按 id 合并（用户覆盖内置）→ asrModelRegistry
/// 用户清单 JSON       ──┘
/// ```
///
/// 用户清单的取法（CLI / 服务端按序）：`--models <file>` > `ASR_MODELS_MANIFEST`
/// 环境变量 > 数据根下的 `models.json`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';

/// 当前生效的注册表。宿主（CLI / 服务端 / app）装配一次，之后
/// [asrModelPackFor] 与 [AsrLanguage.fromTag] 都读它。
AsrModelRegistry asrModelRegistry = AsrModelRegistry.builtin();

/// 一组模型包。
@immutable
class AsrModelRegistry {
  const AsrModelRegistry(this.packs);

  /// 内置 17 语言 9 个包。
  factory AsrModelRegistry.builtin() =>
      const AsrModelRegistry(kAsrModelPacks);

  final List<AsrModelPack> packs;

  /// 注册表认得的全部语言，按包顺序、包内顺序展平，去重。
  List<AsrLanguage> get languages {
    final List<AsrLanguage> out = <AsrLanguage>[];
    for (final AsrModelPack pack in packs) {
      for (final AsrLanguage language in pack.languages) {
        if (!out.contains(language)) out.add(language);
      }
    }
    return out;
  }

  /// 服务该语言的包；没有则 null。
  ///
  /// 多个包声明同一语言时取**最先**的——[mergedWith] 把用户包排在内置包前面，
  /// 所以「用户为 ja 提供自己的包」这件事自然成立，不需要额外的优先级字段。
  ///
  /// [profile]：要转的素材。只在声明适用该素材的包里选（[AsrModelPack.servesProfile]）；
  /// null 只看通用包。专用包排在通用包前面就是「这种素材优先用它」。
  AsrModelPack? packForLanguage(
    AsrLanguage language, {
    AsrAudioProfile? profile,
  }) {
    for (final AsrModelPack pack in packs) {
      if (pack.languages.contains(language) && pack.servesProfile(profile)) {
        return pack;
      }
    }
    return null;
  }

  AsrModelPack? packById(String id) {
    for (final AsrModelPack pack in packs) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  /// 合并：[other] 的包排在前面并按 [AsrModelPack.id] 覆盖同 id 的本表包。
  ///
  /// 「排在前面」既实现了覆盖，也实现了「同语言优先用用户的包」——两件事一个
  /// 规则说清，不需要第二个开关。
  AsrModelRegistry mergedWith(AsrModelRegistry other) {
    final Set<String> overridden =
        other.packs.map((AsrModelPack p) => p.id).toSet();
    return AsrModelRegistry(<AsrModelPack>[
      ...other.packs,
      ...packs.where((AsrModelPack p) => !overridden.contains(p.id)),
    ]);
  }

  /// 从清单 JSON 解析。格式见 [AsrModelPack.fromJson]；顶层可以是
  /// `{"packs": [...]}`，也可以直接是数组。
  ///
  /// 解析失败一律抛 [FormatException] 并带上出错的包 id / 字段——自带模型配错了
  /// 必须当场报清楚，静默跳过一个包会让人对着「语言列表里怎么没有它」猜半天。
  factory AsrModelRegistry.fromJson(Object? json) {
    final Object? raw = json is Map<String, Object?> ? json['packs'] : json;
    if (raw is! List) {
      throw const FormatException(
        '模型清单顶层必须是数组或 {"packs": [...]}',
      );
    }
    return AsrModelRegistry(<AsrModelPack>[
      for (final Object? entry in raw) AsrModelPack.fromJson(entry),
    ]);
  }

  /// 解析一份清单文件。
  static Future<AsrModelRegistry> loadFile(File file) async {
    final String text = await file.readAsString();
    try {
      return AsrModelRegistry.fromJson(jsonDecode(text));
    } on FormatException catch (error) {
      throw FormatException('模型清单 ${file.path} 解析失败：${error.message}');
    }
  }

  /// 按约定顺序找出用户清单并合并进内置表：显式路径 >
  /// `ASR_MODELS_MANIFEST` 环境变量 > [dataRoot]`/models.json`。都没有就返回内置表。
  static Future<AsrModelRegistry> resolve({
    String? explicitPath,
    Directory? dataRoot,
    Map<String, String>? environment,
  }) async {
    final Map<String, String> env = environment ?? Platform.environment;
    final List<String> candidates = <String>[
      if (explicitPath != null && explicitPath.isNotEmpty) explicitPath,
      if ((env['ASR_MODELS_MANIFEST'] ?? '').isNotEmpty)
        env['ASR_MODELS_MANIFEST']!,
      if (dataRoot != null) '${dataRoot.path}${Platform.pathSeparator}models.json',
    ];
    for (final String path in candidates) {
      final File file = File(path);
      if (!file.existsSync()) {
        // 显式给的路径不存在是配置错误，必须报；探测性的两条静默跳过。
        if (path == explicitPath) {
          throw FileSystemException('模型清单不存在', path);
        }
        continue;
      }
      return AsrModelRegistry.builtin().mergedWith(
        await AsrModelRegistry.loadFile(file),
      );
    }
    return AsrModelRegistry.builtin();
  }

  Object toJson() => <String, Object?>{
        'packs': <Object>[for (final AsrModelPack pack in packs) pack.toJson()],
      };
}
