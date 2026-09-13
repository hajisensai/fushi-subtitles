<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · **한국어** · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

자막을 생성하는 다국어 음성 인식 엔진. **순수 Dart 코어와 교체 가능한 ONNX 백엔드**로 이루어져 있으며,
서버 사이드에서 동작하고 CLI 또는 내장 웹 UI로 조작합니다.

[Fushi](https://github.com/hajisensai/Fushi)에서 독립 저장소(`hajisensai/fushi-subtitles`)로
분리한 프로젝트이며, Fushi가 다시 이 저장소를 의존성으로 사용합니다. 명령줄 실행 파일 이름은
`fushi-subs`입니다.

## 무엇을 하는가

- **17개 언어 내장**: 일본어 / 영어 / 중국어 / 광둥어 / 한국어 / 러시아어 / 베트남어 / 태국어는 각각
  전용 zipformer RNN-T로 동작하고, 독일어 / 스페인어 / 프랑스어 / 이탈리아어 / 네덜란드어 /
  포르투갈어 / 터키어 / 인도네시아어 / 아랍어는 Meta의 Omnilingual ASR 1B CTC를 사용합니다.
- **자체 모델 사용**: 내장 매니페스트는 기본값일 뿐입니다. JSON 파일 하나면 직접 만든 zipformer / CTC
  익스포트를 연결할 수 있으며, 내장된 17개 언어 밖의 언어도 지원할 수 있습니다
  (`fushi-subs models export-manifest`로 편집용 템플릿을 내보낼 수 있습니다).
- **세 가지 출력 형식**: SRT / WebVTT / JSON.
- **세 가지 사용 방법**: 명령줄, HTTP API, 그리고 서버에 함께 포함된 웹 UI.
- **오디오북 정렬**(`fushi_asr_align`): 자막 cue를 EPUB 본문과 문장 단위로 대조하고, 앵커 사이를
  되메워 놓친 구간을 회수한 다음, 토큰별 발화 시각을 이용해 문장 경계에서 cue를 다시 나눕니다.
  "cue 하나가 여러 문장을 덮는" 사례는 실측 18 → 0으로 줄었습니다.

## 설치

빌드된 아카이브는 [Releases 페이지](https://github.com/hajisensai/fushi-subtitles/releases)에 있습니다: Linux(x64 / arm64), macOS(Apple Silicon / Intel), Windows(x64 / arm64). 압축을 풀고 `fushi-subs`를 `PATH`에 두고 ffmpeg를 설치한 뒤(「사전 요구 사항」 참조) `fushi-subs doctor`를 실행하세요. ONNX Runtime과 ffmpeg가 사용 가능한지 알려줍니다. Linux / macOS 아카이브에는 ONNX Runtime이 실행 파일 옆에 포함되어 있고, Windows에서는 첫 실행 시 자동으로 다운로드됩니다. macOS 바이너리는 서명되지 않았습니다: 압축 해제 후 `xattr -dr com.apple.quarantine fushi-subs/`를 한 번 실행하세요.

## 빠른 시작

```bash
dart pub get

# 모델 내려받기 (영어 int8, 약 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# 전사, 자막은 stdout으로 출력
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# 또는 서버를 띄우고 브라우저에서 http://127.0.0.1:8642 에 파일을 끌어다 놓기
dart run packages/asr_cli/bin/asr.dart serve
```

CLI는 얇은 클라이언트 역할만 하면서 실제 작업을 원격 서버에 넘길 수도 있습니다.

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### 사전 요구 사항

| 의존성 | 설명 |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22 이상** — 그보다 낮으면 `GetApi(22)`가 nullptr를 반환하므로, 설치돼 있어도 쓸 수 없습니다). 탐색 순서: `ASR_ONNXRUNTIME_LIB` 환경 변수 → 필요할 때 받아 두는 관리 사본 → 실행 파일과 같은 위치 → 시스템 검색 경로. **Windows에서는 사용할 수 있는 버전이 없으면 자동으로 내려받습니다**(NuGet의 `Microsoft.ML.OnnxRuntime.DirectML`, 17.9 MB, sha256으로 고정, `<데이터 루트>/asr_runtime/`에 배치). GitHub 릴리스의 CPU 전용 빌드가 아니라 DirectML 빌드를 쓰는 이유는, 그렇지 않으면 GPU 가속이 조용히 사라지기 때문입니다. `DirectML.dll` 자체는 Windows 시스템 구성 요소에서 제공됩니다. Microsoft Visual C++ 재배포 가능 패키지도 필요합니다. macOS에서는 `script/bootstrap_macos.sh`를, Linux에서는 배포판 패키지 관리자를 사용하세요. |
| **ffmpeg** | 임의의 오디오/비디오를 16 kHz 모노 PCM으로 디코딩합니다. 탐색 순서: `ASR_FFMPEG` → 실행 파일과 같은 위치 → `PATH`. `ffprobe`는 선택 사항입니다(없으면 전체 길이를 알 수 없어 진행률 백분율이 부정확해집니다). |

그 밖의 환경 변수: `ASR_DATA_DIR`(모델과 작업 디렉터리의 루트), `ASR_MODELS_MANIFEST`(직접 만든
모델 매니페스트).

macOS에서는 `transcribe --coreml` 또는 `serve --coreml`로 CoreML FP32 인코더를 명시적으로 켤 수
있습니다. 현재 일본어 모델은 실측상 CPU의 INT8보다 느려서, 자동 모드는 여전히 CPU를 선택합니다.
사용법, 연산자가 실제로 실행됐다는 증거, 3자 벤치마크는
[docs/MACOS_COREML.md](../MACOS_COREML.md)에 있습니다.

## 자체 모델 사용

```bash
fushi-subs models export-manifest -o models.json   # 내장 매니페스트를 템플릿으로 내보내기
# 편집한 뒤에
asr --models models.json transcribe -l hi hindi.mp3
```

매니페스트는 `id`를 기준으로 내장 표와 병합되며, 사용자의 팩이 앞에 놓입니다. 즉 같은 `id`는 내장
항목을 덮어쓰고, 같은 언어라면 사용자의 것이 우선합니다. 가장 작은 팩에 필요한 항목은
`id` / `languages` / `files`뿐입니다.

```json
{"packs": [{
  "id": "my-hindi-zipformer",
  "languages": ["hi"],
  "files": [
    {"fileName": "encoder.onnx", "url": "https://…", "expectedBytes": 70000000, "role": "encoderInt8"},
    {"fileName": "decoder.onnx", "url": "https://…", "expectedBytes": 700000,   "role": "decoderInt8"},
    {"fileName": "joiner.onnx",  "url": "https://…", "expectedBytes": 400000,   "role": "joinerInt8"},
    {"fileName": "tokens.txt",   "url": "https://…", "expectedBytes": 50000,    "role": "tokens"},
    {"fileName": "silero_vad.onnx", "url": "https://…", "expectedBytes": 643854, "role": "vad"}
  ]
}]}
```

나머지 필드에는 기본값이 있습니다(`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **CTC 팩은 `blankToken`을 반드시 명시해야 합니다** —
널리 합의된 기본값이 없어서, 잘못 추측하면 전사 결과 전체가 깨집니다.

## HTTP API

| 엔드포인트 | 설명 |
|---|---|
| `GET /` | 웹 UI (외부 리소스가 없는 단일 파일, LAN에서 오프라인으로 사용 가능) |
| `GET /v1/health` | 생존 확인용 프로브, 토큰 불필요 |
| `GET /v1/models` | 어떤 언어와 모델 팩을 알고 있는지 |
| `POST /v1/transcribe?language=ja&format=srt` | 요청 본문은 오디오 바이트이거나, `audio`와 `epub` 파일을 담은 multipart입니다. 응답은 스트리밍 NDJSON으로, 한 줄에 진행 이벤트 하나씩이고 마지막 줄은 `result`, `cancelled`, `error` 중 하나입니다 |
| `POST /v1/retime?language=ja&format=srt` | 자막 타이밍 재조정: `audio`(오디오 또는 비디오)와 `subtitle`(UTF-8 SRT/VTT, 최대 8 MiB)을 multipart로 업로드합니다. 자막 텍스트와 cue 개수는 그대로 두고 타이밍만 음성에 맞춰 다시 보정합니다. 마찬가지로 NDJSON을 반환합니다 |

`--token`을 설정한 경우 요청에는 `Authorization: Bearer <token>`이 있어야 합니다.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

타이밍 재조정은 전사와 동일한 `engine`, `filename`, `jobId` 파라미터를 지원하고 SRT, VTT, JSON
출력도 지원합니다. `result.text`는 재보정된 자막이고 `rawText`는 음성 인식의 원본 출력입니다.
`retiming`은 직접 매칭된 cue, 보간된 cue, 원래 타이밍을 유지한 cue의 개수와 함께 매칭률, 시간
오프셋, 경고를 보고하므로 믿을 만한 음성 앵커를 찾지 못한 부분을 확인할 수 있습니다. 일본 TV
자막의 앞머리 화자 이름과 괄호로 묶인 효과음은 매칭할 때만 무시되고, 내보내는 텍스트에는 원문이
그대로 남습니다. 자막과 ASR의 분할이 어긋날 때는 여러 독립적인 음성 경계를 이용해 구간별 시간
오프셋이나 드리프트를 추정할 수 있으며, 오프닝이나 광고 같은 버전 차이는 별도로 처리됩니다.
UI는 재보정된 cue 수와 문장 전체 매칭, 그리고 추정값을 구분해서 보여주므로, 문장 전체 매칭률을
재보정 커버리지로 착각할 일이 없습니다.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**성공 여부는 HTTP 상태 코드가 아니라 `result` 줄이 도착했는지로 판단합니다**: 응답 스트리밍이
시작되면 상태 코드를 더 이상 바꿀 수 없기 때문에, 실패는 마지막 줄로만 돌려보낼 수 있습니다.

## 패키지 구성

| 패키지 | 내용 | 의존 대상 |
|---|---|---|
| `fushi_asr_core` | 순수 Dart 전사 코어: VAD 분할, fbank, RNN-T 그리디 Loop 그래프 / CTC 디코딩, 배치 처리와 버킷팅, fp16 그래프 변환, 모델 매니페스트와 다운로드, SRT 출력. **Flutter 없음, dart:ffi 없음, ONNX 백엔드 미포함** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | dart:ffi 기반 ONNX Runtime 백엔드 (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | EPUB / 텍스트 ↔ 오디오 정렬: 문장 단위 Dice 매칭(루비 독음 트랙 포함), 앵커 사이 공백 되메우기, 문장 경계에서의 cue 재분할 | `fushi_asr_core` |
| `fushi_asr` | 파사드: 한 번의 호출로 끝나는 `TranscribeRunner`와 자막 형식 | 위의 두 패키지 |
| `fushi_asr_server` | HTTP 서버와 클라이언트, 그리고 웹 UI | `fushi_asr` |
| `fushi_asr_cli` | `asr` 명령줄 | `fushi_asr` `fushi_asr_server` `args` |

이렇게 계층을 나눈 목적은 **알고리즘 계층이 좁은 인터페이스 하나에만 의존하도록** 하는 것입니다
(`OnnxSessionFactory.createSession`). Flutter 호스트는 자체 플러그인 백엔드를, 서버는 FFI 백엔드를
주입하며, 동일한 알고리즘이 양쪽에서 그대로 돌아갑니다.

## 개발

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326개 테스트
cd packages/asr_onnx_ffi && dart test    # 15개 테스트, 실제 onnxruntime 필요 (없으면 그룹 전체 skip)
cd packages/asr_align && dart test       # 15개 테스트
cd packages/asr && dart test             # 10개 테스트
cd packages/asr_server && dart test      # 10개 테스트
```

Apple Silicon macOS에서는 `./script/bootstrap_macos.sh`가 프로젝트 로컬 Dart SDK와 FFmpeg,
ONNX Runtime을 설치하고, 그다음 `./script/check.sh`로 전체 점검을 실행합니다. macOS 호스트를 위한
환경 참고 사항과 경계에 관한 조언은 [docs/MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md)에 있습니다.

ORT FFI 바인딩 재생성(ORT 버전을 바꿀 때만 필요합니다. 생성된 코드는 커밋돼 있으므로 일반
사용자에게 LLVM은 필요 없습니다):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

진단: `ASR_TRACE_SHUTDOWN=1`은 전사 종료 처리의 모든 단계를 stderr에 기록합니다(세션 닫기 →
PCM 브리지 닫기 → 종료 메시지 → 서버가 응답을 씀). "끝났는데 멈춰 있다"를 디버깅할 때 씁니다.

구현 계획과 설계상의 트레이드오프는 [docs/PLAN.md](../PLAN.md)에 있습니다.

## 라이선스

GPL-3.0, [LICENSE](../../LICENSE)를 참고하세요. `third_party/onnxruntime/` 아래의 헤더는
ONNX Runtime(MIT)에서 온 것이며 원래 라이선스를 그대로 유지합니다.
