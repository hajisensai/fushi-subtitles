<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
**English** · [简体中文](docs/readme/README.zh-CN.md) · [繁體中文](docs/readme/README.zh-HK.md) · [日本語](docs/readme/README.ja.md) · [한국어](docs/readme/README.ko.md) · [Deutsch](docs/readme/README.de.md) · [Español](docs/readme/README.es.md) · [Français](docs/readme/README.fr.md) · [Italiano](docs/readme/README.it.md) · [Nederlands](docs/readme/README.nl.md) · [Português (Brasil)](docs/readme/README.pt-BR.md) · [Русский](docs/readme/README.ru.md) · [Türkçe](docs/readme/README.tr.md) · [Tiếng Việt](docs/readme/README.vi.md) · [ไทย](docs/readme/README.th.md) · [Bahasa Indonesia](docs/readme/README.id.md) · [العربية](docs/readme/README.ar.md)

# fushi-subtitles

Multilingual speech recognition that produces subtitles. **A pure-Dart core with a pluggable ONNX
backend**, running server-side and driven from the CLI or the built-in web UI.

Extracted from [Fushi](https://github.com/hajisensai/Fushi) into a standalone repository
(`hajisensai/fushi-subtitles`), which Fushi then depends on. The command-line executable is called
`fushi-subs`.

## What it does

- **17 built-in languages**: Japanese / English / Chinese / Cantonese / Korean / Russian /
  Vietnamese / Thai each run their own zipformer RNN-T; German / Spanish / French / Italian /
  Dutch / Portuguese / Turkish / Indonesian / Arabic run Meta's Omnilingual ASR 1B CTC.
- **Bring your own models**: the built-in manifest is only a default. One JSON file is enough to
  plug in your own zipformer / CTC exports, including languages outside the built-in 17
  (`fushi-subs models export-manifest` writes out a template to edit).
- **Three output formats**: SRT / WebVTT / JSON.
- **Three ways to drive it**: command line, HTTP API, and the web UI the server ships with.
- **Audiobook alignment** (`fushi_asr_align`): matches subtitle cues against EPUB body text
  sentence by sentence, recovers missed passages by backfilling between anchors, then re-splits
  cues on sentence boundaries using per-token emission times — "one cue covering several
  sentences" measured 18 → 0.

## Install

Prebuilt archives are on the [Releases page](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel) and Windows (x64 / arm64). Unpack, put `fushi-subs` on your `PATH`, install ffmpeg (see [Prerequisites](#prerequisites)), then run `fushi-subs doctor` — it reports whether ONNX Runtime and ffmpeg are usable. Linux and macOS archives ship ONNX Runtime next to the executable; on Windows it is downloaded automatically on first run. macOS binaries are unsigned: run `xattr -dr com.apple.quarantine fushi-subs/` once after unpacking.

## Quick start

```bash
dart pub get

# Download a model (English int8, about 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Transcribe, subtitles go to stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# Or start the server and drop files onto http://127.0.0.1:8642 in a browser
dart run packages/asr_cli/bin/asr.dart serve
```

The CLI can also act as a thin client and hand the work to a remote server:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Prerequisites

| Dependency | Notes |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — below that `GetApi(22)` returns nullptr, so an older install is unusable even once present). Lookup order: the `ASR_ONNXRUNTIME_LIB` environment variable → the managed copy fetched on demand → next to the executable → the system search path. **On Windows a usable version is downloaded automatically when none is found** (NuGet's `Microsoft.ML.OnnxRuntime.DirectML`, 17.9 MB, pinned by sha256, landing in `<data root>/asr_runtime/`); the DirectML build is used rather than the CPU-only GitHub release, otherwise GPU acceleration disappears silently. `DirectML.dll` itself comes from the Windows system component. The Microsoft Visual C++ Redistributable is also required. On macOS use `script/bootstrap_macos.sh`; on Linux use your distribution's package manager. |
| **ffmpeg** | Decodes arbitrary audio/video into 16 kHz mono PCM. Lookup order: `ASR_FFMPEG` → next to the executable → `PATH`. `ffprobe` is optional (without it the total duration is unknown, so the progress percentage is inaccurate). |

Other environment variables: `ASR_DATA_DIR` (root for models and job directories) and
`ASR_MODELS_MANIFEST` (your own model manifest).

On macOS, `transcribe --coreml` or `serve --coreml` explicitly enables the CoreML FP32 encoder. The
current Japanese model measures slower than INT8 on CPU, so automatic mode still picks CPU. Usage,
proof of operator execution and three-way benchmarks are in
[docs/MACOS_COREML.md](docs/MACOS_COREML.md).

## Bring your own models

```bash
fushi-subs models export-manifest -o models.json   # export the built-in manifest as a template
# after editing it
asr --models models.json transcribe -l hi hindi.mp3
```

The manifest is merged with the built-in table by `id`, with your packs placed first — the same
`id` overrides the built-in one, and for the same language yours wins. The smallest possible pack
needs only `id` / `languages` / `files`:

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

The remaining fields have defaults (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **A CTC pack must state `blankToken` explicitly** —
there is no consensus default, and guessing wrong garbles the entire transcript.

## HTTP API

| Endpoint | Notes |
|---|---|
| `GET /` | The web UI (a single file with no external resources, usable offline on a LAN) |
| `GET /v1/health` | Liveness probe, no token required |
| `GET /v1/models` | Which languages and model packs are known |
| `POST /v1/transcribe?language=ja&format=srt` | The request body is the audio bytes, or a multipart body with an `audio` and an `epub` file. The response is streaming NDJSON, one progress event per line, with `result`, `cancelled` or `error` as the last line |
| `POST /v1/retime?language=ja&format=srt` | Subtitle retiming: upload `audio` (audio or video) and `subtitle` (UTF-8 SRT/VTT, at most 8 MiB) as multipart. The subtitle text and cue count are preserved while the timings are recalibrated against the speech; also returns NDJSON |

When `--token` is set, requests must carry `Authorization: Bearer <token>`.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

Retiming supports the same `engine`, `filename` and `jobId` parameters as transcription, plus SRT,
VTT and JSON output. `result.text` is the recalibrated subtitle and `rawText` is the raw speech
recognition output; `retiming` reports how many cues were matched directly, interpolated or left on
their original timings, along with the match rate, time offset and warnings, so you can inspect the
parts where no reliable speech anchor was found. Leading speaker names and bracketed sound effects
in Japanese TV subtitles are ignored only while matching; the exported text keeps the original.
Where the subtitles and the ASR segmentation disagree, several independent speech boundaries can be
used to estimate a per-segment time offset or drift; version differences such as openings and
commercials are handled separately. The UI distinguishes recalibrated cue counts from
whole-sentence matches and from estimates, so a whole-sentence match rate is not mistaken for
recalibration coverage.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**Success is decided by whether a `result` line arrived, not by the HTTP status code**: once the
response starts streaming the status code can no longer be changed, so a failure can only be sent
back as the last line.

## Package layout

| Package | Contents | Depends on |
|---|---|---|
| `fushi_asr_core` | The pure-Dart transcription core: VAD segmentation, fbank, RNN-T greedy Loop graph / CTC decoding, batching and bucketing, fp16 graph conversion, model manifest and downloads, SRT output. **No Flutter, no dart:ffi, no bundled ONNX backend** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | The dart:ffi ONNX Runtime backend (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | EPUB / text ↔ audio alignment: sentence-level Dice matching (including a ruby reading track), gap backfilling between anchors, cue re-splitting on sentence boundaries | `fushi_asr_core` |
| `fushi_asr` | The facade: a one-call `TranscribeRunner` plus subtitle formats | the two above |
| `fushi_asr_server` | The HTTP server and client plus the web UI | `fushi_asr` |
| `fushi_asr_cli` | The `asr` command line | `fushi_asr` `fushi_asr_server` `args` |

The point of the layering is that **the algorithm layer depends on one narrow interface only**
(`OnnxSessionFactory.createSession`). A Flutter host injects its own plugin backend, the server
injects the FFI backend, and the same algorithms run on both.

## Development

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 tests
cd packages/asr_onnx_ffi && dart test    # 15 tests, needs a real onnxruntime (the group skips without one)
cd packages/asr_align && dart test       # 15 tests
cd packages/asr && dart test             # 10 tests
cd packages/asr_server && dart test      # 10 tests
```

On Apple Silicon macOS, `./script/bootstrap_macos.sh` installs a project-local Dart SDK, FFmpeg and
ONNX Runtime, after which `./script/check.sh` runs the full check. Environment notes and boundary
advice for the macOS host are in [docs/MACOS_DEVELOPMENT.md](docs/MACOS_DEVELOPMENT.md).

Regenerating the ORT FFI bindings (only needed when changing the ORT version; the generated code is
committed, so ordinary users need no LLVM):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Diagnostics: `ASR_TRACE_SHUTDOWN=1` writes every step of transcription teardown to stderr (close
session → close PCM bridge → exit message → server writes the response), for debugging "it finished
but hangs".

The implementation plan and design trade-offs are in [docs/PLAN.md](docs/PLAN.md).

## License

GPL-3.0, see [LICENSE](LICENSE). The headers under `third_party/onnxruntime/` come from ONNX
Runtime (MIT) and keep their original license.
