/// DirectML.dll 解析判据 + 原生错误消息容错解码的回归测试。
///
/// 真 bug（2026-09-13，下游 SubMoe 实测）：Windows 10 的 System32 里是
/// DirectML 1.0.200713，ORT 1.22 的 DML EP 建不出设备（`887A0004`），整条链静默
/// 回落 CPU；而 ORT 报错里的 ANSI 字节让 `Utf8.toDartString()` 抛
/// `FormatException: offset 169`，真错因被吞。两处都不能再回去。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:fushi_asr_onnx_ffi/src/directml_runtime.dart';
import 'package:fushi_asr_onnx_ffi/src/ort_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('dml_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// 建一个空的 DirectML.dll 占位；返回路径与 [DirectMlRuntime.resolveCandidates]
  /// 拼出来的形态一致（`p.join` 分段），断言才能逐字比。
  String dll(String dir) {
    final String path =
        p.joinAll(<String>[tmp.path, ...dir.split('/'), 'DirectML.dll']);
    File(path).createSync(recursive: true);
    return path;
  }

  group('DirectMlRuntime.resolve', () {
    test('候选顺序：显式 > 可执行文件同级 > 托管目录 > System32', () {
      final List<String> c = DirectMlRuntime.resolveCandidates(
        environment: <String, String>{
          'ASR_DIRECTML_LIB': r'X:\dml\DirectML.dll',
          'SystemRoot': r'C:\Windows',
        },
        executablePath: r'D:\app\fushi-subs.exe',
        managedDir: r'D:\data\asr_runtime\ort',
      );
      expect(c, <String>[
        r'X:\dml\DirectML.dll',
        p.join(r'D:\app', 'DirectML.dll'),
        p.join(r'D:\data\asr_runtime\ort', 'DirectML.dll'),
        p.join(r'C:\Windows', 'System32', 'DirectML.dll'),
      ]);
    });

    test('随包那份够新就选它，不去碰 System32 里的旧版', () {
      final String bundled = dll('app');
      final String system = dll('sys/System32');
      final DirectMlResolution r = DirectMlRuntime.resolve(
        isWindows: true,
        environment: const <String, String>{},
        executablePath: p.join(tmp.path, 'app', 'fushi-subs.exe'),
        managedDir: null,
        systemRoot: p.join(tmp.path, 'sys'),
        readVersion: (String path) =>
            path == bundled ? <int>[1, 15, 4, 0] : <int>[1, 0, 0, 200713],
      );
      expect(r.path, bundled);
      expect(r.meetsRequirement, isTrue);
      expect(r.attempted, hasLength(1), reason: '选中就停，不再往后探');
      expect(r.describe(), isNot(contains('低于')));
      expect(system, isNotEmpty);
    });

    test('只有 System32 的 Windows 10 旧版：仍选它但判为不够，描述里给出处置', () {
      final String system = dll('sys/System32');
      final DirectMlResolution r = DirectMlRuntime.resolve(
        isWindows: true,
        environment: const <String, String>{},
        executablePath: p.join(tmp.path, 'app', 'fushi-subs.exe'),
        managedDir: null,
        systemRoot: p.join(tmp.path, 'sys'),
        readVersion: (_) => <int>[1, 0, 0, 200713],
      );
      expect(r.path, system);
      expect(r.found, isTrue);
      expect(r.meetsRequirement, isFalse);
      expect(r.describe(), contains('1.0.0.200713'));
      expect(r.describe(), contains('1.15.4'));
      expect(r.describe(), contains('ASR_DIRECTML_LIB'));
      expect(r.attempted.first, contains('不存在'));
    });

    test('多份都不够新时选版本最高的；版本读不出的不算够', () {
      final String a = dll('a');
      final String b = dll('b');
      final DirectMlResolution r = DirectMlRuntime.resolve(
        isWindows: true,
        environment: <String, String>{'ASR_DIRECTML_LIB': a},
        executablePath: p.join(tmp.path, 'b', 'x.exe'),
        managedDir: null,
        systemRoot: p.join(tmp.path, 'nope'),
        readVersion: (String path) => path == a ? null : <int>[1, 12, 0, 0],
      );
      expect(r.path, b);
      expect(r.meetsRequirement, isFalse);
    });

    test('一个候选都不存在：found=false，描述列出试过的路径', () {
      final DirectMlResolution r = DirectMlRuntime.resolve(
        isWindows: true,
        environment: const <String, String>{},
        executablePath: p.join(tmp.path, 'app', 'x.exe'),
        managedDir: null,
        systemRoot: p.join(tmp.path, 'nope'),
      );
      expect(r.found, isFalse);
      expect(r.describe(), contains('一个候选都不存在'));
      expect(r.describe(), contains('System32'));
    });

    test('非 Windows：不适用', () {
      final DirectMlResolution r = DirectMlRuntime.resolve(isWindows: false);
      expect(r.found, isFalse);
      expect(r.attempted.single, contains('非 Windows'));
    });

    test('版本比较按 4 段数值，不按字串', () {
      expect(
          DirectMlResolution.compareVersions(
              <int>[1, 15, 4], <int>[1, 15, 4, 0]),
          0);
      expect(
          DirectMlResolution.compareVersions(
              <int>[1, 9, 0, 0], <int>[1, 15, 4]),
          lessThan(0));
      expect(
          DirectMlResolution.compareVersions(
              <int>[2, 0, 0, 0], <int>[1, 15, 4]),
          greaterThan(0));
    });
  });

  group('readFileVersion（真 version.dll）', () {
    test('System32 里的 DirectML.dll 读得出 4 段版本', () {
      final String path = p.join(
          Platform.environment['SystemRoot'] ?? r'C:\Windows',
          'System32',
          'DirectML.dll');
      final List<int>? v = DirectMlRuntime.readFileVersion(path);
      expect(v, isNotNull);
      expect(v, hasLength(4));
      expect(v!.first, greaterThanOrEqualTo(1));
    }, testOn: 'windows');

    test('不存在 / 不是 PE 的文件返回 null，不抛', () {
      expect(DirectMlRuntime.readFileVersion(p.join(tmp.path, 'nope.dll')),
          isNull);
      final File junk = File(p.join(tmp.path, 'junk.dll'))
        ..writeAsStringSync('not a pe');
      expect(DirectMlRuntime.readFileVersion(junk.path), isNull);
    });
  });

  group('readNativeCString', () {
    Pointer<Char> native(List<int> bytes) {
      final Pointer<Uint8> ptr = calloc<Uint8>(bytes.length + 1);
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      ptr[bytes.length] = 0;
      return ptr.cast<Char>();
    }

    test('合法 UTF-8 原样返回', () {
      final Pointer<Char> ptr = native(utf8.encode('会话创建失败：887A0004'));
      try {
        expect(readNativeCString(ptr), '会话创建失败：887A0004');
      } finally {
        calloc.free(ptr.cast<Uint8>());
      }
    });

    test('ANSI 代码页字节（非法 UTF-8）不抛，ASCII 部分原样保留', () {
      // GBK 的「不受支持」+ ASCII 尾巴：模拟 Windows FormatMessageA 的产物。
      final List<int> bytes = <int>[
        ...utf8.encode('dml_provider_factory.cc(520) 887A0004 '),
        0xB2,
        0xBB,
        0xCA,
        0xDC,
        0xD6,
        0xA7,
        0xB3,
        0xD6,
        ...utf8.encode(' (end)'),
      ];
      final Pointer<Char> ptr = native(bytes);
      try {
        final String text = readNativeCString(ptr);
        expect(text, startsWith('dml_provider_factory.cc(520) 887A0004 '));
        expect(text, endsWith(' (end)'));
        expect(text, contains('\uFFFD'));
      } finally {
        calloc.free(ptr.cast<Uint8>());
      }
    });

    test('没有 NUL 时按 maxBytes 截断', () {
      final Pointer<Uint8> ptr = calloc<Uint8>(8);
      ptr.asTypedList(8).fillRange(0, 8, 0x41);
      try {
        expect(readNativeCString(ptr.cast<Char>(), maxBytes: 5), 'AAAAA');
      } finally {
        calloc.free(ptr);
      }
    });
  });
}
