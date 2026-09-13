import 'package:fushi_asr_cli/src/doctor.dart';
import 'package:test/test.dart';

const DoctorProbe _ortOk = DoctorProbe.ok(
    path: '/opt/fushi-subs/libonnxruntime.so', version: '1.22.0');
const DoctorProbe _ffmpegOk =
    DoctorProbe.ok(path: 'ffmpeg', version: 'ffmpeg version 7.1');
const DoctorProbe _ffprobeMissing =
    DoctorProbe.failed(path: 'ffprobe', failure: 'No such file');

void main() {
  test('ORT 与 ffmpeg 都可用才算健康；ffprobe 缺了不算', () {
    const DoctorReport r = DoctorReport(
      ort: _ortOk,
      providers: <String>['directml'],
      ffmpeg: _ffmpegOk,
      ffprobe: _ffprobeMissing,
    );
    expect(r.healthy, isTrue);
    final String text = formatDoctorReport(r);
    expect(text, contains('✓ ONNX Runtime  /opt/fushi-subs/libonnxruntime.so'));
    expect(text, contains('版本: 1.22.0'));
    expect(text, contains('加速后端: directml'));
    expect(text, contains('△ ffprobe'));
    expect(text, contains('结论: 可以转录'));
  });

  test('ORT 装不上：报告失败路径与原因，退出结论为不能转录', () {
    const DoctorReport r = DoctorReport(
      ort: DoctorProbe.failed(
        path: '/a/libonnxruntime.so / libonnxruntime.so',
        failure: '不支持 API 版本 22',
      ),
      providers: <String>[],
      ffmpeg: _ffmpegOk,
      ffprobe: _ffprobeMissing,
    );
    expect(r.healthy, isFalse);
    final String text = formatDoctorReport(r);
    expect(text,
        contains('✗ ONNX Runtime  /a/libonnxruntime.so / libonnxruntime.so'));
    expect(text, contains('不支持 API 版本 22'));
    expect(text, isNot(contains('加速后端')));
    expect(text, contains('结论: 不能转录'));
  });

  test('ffmpeg 缺了也不健康', () {
    const DoctorReport r = DoctorReport(
      ort: _ortOk,
      providers: <String>[],
      ffmpeg: DoctorProbe.failed(path: 'ffmpeg', failure: 'No such file'),
      ffprobe: _ffprobeMissing,
    );
    expect(r.healthy, isFalse);
    expect(formatDoctorReport(r), contains('加速后端: 无（仅 CPU）'));
  });
}
