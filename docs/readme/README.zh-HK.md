<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

多語言語音辨識產生字幕。**純 Dart 核心 + 可插拔 ONNX 後端**，跑在伺服器端，用 CLI 或內建網頁介面呼叫。

從 [Fushi](https://github.com/hajisensai/Fushi) 抽出為獨立倉庫（`hajisensai/fushi-subtitles`），
Fushi 反過來依賴它。命令列可執行檔叫 `fushi-subs`。

## 能做甚麼

- **17 種內建語言**：日 / 英 / 中 / 粵 / 韓 / 俄 / 越 / 泰各自跑自己的 zipformer RNN-T；
  德 / 西 / 法 / 意 / 荷 / 葡 / 土 / 印尼 / 阿拉伯走 Meta Omnilingual ASR 1B CTC。
- **自備模型**：內建清單只是預設值。寫一份 JSON 就能接上自己的 zipformer / CTC 匯出，
  包括內建 17 種以外的語言（`fushi-subs models export-manifest` 匯出一份範本再改）。
- **三種輸出格式**：SRT / WebVTT / JSON。
- **三種驅動方式**：命令列、HTTP API，以及伺服器端自帶的網頁介面。
- **有聲書對齊**（`fushi_asr_align`）：把字幕 cue 與 EPUB 正文逐句對上，用錨點回填撈回漏配的段落，
  再用逐 token 發射時間依句界重切 cue——「一條 cue 蓋了好幾句」實測 18 → 0。

## 安裝

預編譯套件在 [Releases 頁面](https://github.com/hajisensai/fushi-subtitles/releases)：Linux（x64 / arm64）、macOS（Apple Silicon / Intel）、Windows（x64 / arm64）。解壓後把 `fushi-subs` 放進 `PATH`，裝好 ffmpeg（見「前置依賴」），再執行 `fushi-subs doctor`——它會回報 ONNX Runtime 與 ffmpeg 是否可用。Linux / macOS 套件裡 ONNX Runtime 就放在執行檔旁邊；Windows 首次執行時自動下載。macOS 二進位未簽名：解壓後執行一次 `xattr -dr com.apple.quarantine fushi-subs/`。

## 快速上手

```bash
dart pub get

# 下載模型（英語 int8，約 67 MB）
dart run packages/asr_cli/bin/asr.dart models pull -l en

# 轉錄，字幕寫到 stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# 或者起伺服器，用瀏覽器開 http://127.0.0.1:8642 把檔案拖進去
dart run packages/asr_cli/bin/asr.dart serve
```

CLI 也可以只當一個輕量客戶端，把工作交給遠端伺服器：

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### 前置需求

| 相依項 | 說明 |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib`（**1.22+**，低於此版本 `GetApi(22)` 會回傳 nullptr，就算裝了也用不了）。尋找順序：`ASR_ONNXRUNTIME_LIB` 環境變數 → 按需下載的託管副本 → 可執行檔同層目錄 → 系統搜尋路徑。**Windows 上找不到可用版本時會自動下載**（NuGet 的 `Microsoft.ML.OnnxRuntime.DirectML`，17.9 MB，以 sha256 釘死，落在 `<資料根目錄>/asr_runtime/`）；下載的是 DirectML 那一份而非 GitHub release 的純 CPU 版，否則 GPU 加速會無聲消失。`DirectML.dll` 本身來自 Windows 內建的系統元件。另外還需要 Microsoft Visual C++ Redistributable。macOS 請用 `script/bootstrap_macos.sh`，Linux 則用發行版的套件管理員。 |
| **ffmpeg** | 用來把任意音訊／視訊解碼成 16 kHz 單聲道 PCM。尋找順序：`ASR_FFMPEG` → 可執行檔同層 → `PATH`。`ffprobe` 為選用（少了它就探不出總長度，進度百分比會不準）。 |

其他環境變數：`ASR_DATA_DIR`（模型與工作目錄的根）與 `ASR_MODELS_MANIFEST`（自備的模型清單）。

macOS 上可用 `transcribe --coreml` 或 `serve --coreml` 明確啟用 CoreML FP32 編碼器。
目前的日語模型實測比 CPU 上的 INT8 還慢，因此自動模式仍然會選 CPU。
用法、運算子執行證明與三方測速見 [docs/MACOS_COREML.md](../MACOS_COREML.md)。

## 自備模型

```bash
fushi-subs models export-manifest -o models.json   # 匯出內建清單當範本
# 改完之後
asr --models models.json transcribe -l hi hindi.mp3
```

清單會依 `id` 與內建表合併，你的包排在前面——同一個 `id` 覆蓋內建的，同一語言以你的為準。
最小的一個包只需要 `id` / `languages` / `files`：

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

其餘欄位都有預設值（`architecture: transducer`、`indexType: int64`、`decoderContextSize: 2`、
`blankToken: <blk>`）。**CTC 包必須明確寫出 `blankToken`**——它沒有共識上的預設值，猜錯就是整篇亂碼。

## HTTP API

| 端點 | 說明 |
|---|---|
| `GET /` | 網頁介面（單一檔案、零外部資源，內網離線可用） |
| `GET /v1/health` | 存活探測，不需要權杖 |
| `GET /v1/models` | 認得哪些語言與模型包 |
| `POST /v1/transcribe?language=ja&format=srt` | 請求主體為音訊位元組，或包含 `audio` 與 `epub` 兩個檔案的 multipart。回應是串流 NDJSON，一行一個進度事件，最後一行是 `result`、`cancelled` 或 `error` |
| `POST /v1/retime?language=ja&format=srt` | 字幕對軸：以 multipart 上傳 `audio`（音訊或視訊）與 `subtitle`（UTF-8 SRT/VTT，最多 8 MiB）。字幕原文與條數保持不變，只依語音重新校準時間軸；同樣回傳 NDJSON |

設了 `--token` 時，請求必須帶 `Authorization: Bearer <token>`。

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

對軸支援與轉錄相同的 `engine`、`filename`、`jobId` 參數，以及 SRT、VTT、JSON 輸出。
`result.text` 是校準後的字幕，`rawText` 是語音辨識的原始輸出；`retiming` 會報出直接匹配、
內插、以及維持原時間軸的條數，連同匹配率、時間偏移與警告，方便你檢查那些找不到可靠語音錨點的部分。
日文電視字幕開頭的角色名與括號音效只在匹配時忽略，匯出的文字仍保留原文。
字幕與 ASR 分句不一致時，可用多個獨立的語音邊界估計分段時間偏移或漂移；
片頭、廣告之類的版本差異會分開處理。介面會區分時間校準條數、整句匹配與估算值，
避免把整句匹配率誤當成校準覆蓋率。

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**判定成功的依據是「有沒有收到 `result` 行」，而不是 HTTP 狀態碼**：回應一旦開始串流就
改不了狀態碼，失敗只能當作最後一行送回來。

## 套件結構

| 套件 | 內容 | 相依 |
|---|---|---|
| `fushi_asr_core` | 純 Dart 轉錄核心：VAD 分段、fbank、RNN-T 貪婪 Loop 圖 / CTC 解碼、攢批分桶、fp16 圖轉換、模型清單與下載、SRT 產出。**零 Flutter、零 dart:ffi、不自帶 ONNX 後端** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | ONNX Runtime 的 dart:ffi 後端（CPU / DirectML / CUDA） | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | EPUB / 文字 ↔ 音訊對齊：句級 Dice 匹配（含 ruby 讀音軌）、錨點間隙回填、依句界重切 cue | `fushi_asr_core` |
| `fushi_asr` | 門面：一步到位的 `TranscribeRunner` 加上字幕格式 | 上面兩個 |
| `fushi_asr_server` | HTTP 伺服器與客戶端，加上網頁介面 | `fushi_asr` |
| `fushi_asr_cli` | `asr` 命令列 | `fushi_asr` `fushi_asr_server` `args` |

分層的意義在於**演算法層只依賴一個很窄的介面**（`OnnxSessionFactory.createSession`）。
Flutter 宿主注入自己的外掛後端，伺服器端注入 FFI 後端，同一套演算法兩邊都能跑。

## 開發

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 條測試
cd packages/asr_onnx_ffi && dart test    # 15 條測試，需要真的 onnxruntime（沒有就整組 skip）
cd packages/asr_align && dart test       # 15 條測試
cd packages/asr && dart test             # 10 條測試
cd packages/asr_server && dart test      # 10 條測試
```

在 Apple Silicon 的 macOS 上，`./script/bootstrap_macos.sh` 會安裝專案本地的 Dart SDK、FFmpeg 與
ONNX Runtime，之後用 `./script/check.sh` 跑完整檢查。macOS 宿主的環境說明與邊界建議見
[docs/MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md)。

重新產生 ORT FFI 綁定（只有改 ORT 版本時才需要；產物已入庫，一般使用者不必裝 LLVM）：

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

診斷：`ASR_TRACE_SHUTDOWN=1` 會把轉錄收尾的每一步寫到 stderr（關閉 session → 關閉 PCM 橋接 →
結束訊息 → 伺服器寫出回應），用來排查「跑完了卻卡住」。

實作計畫與設計取捨見 [docs/PLAN.md](../PLAN.md)。

## 授權

GPL-3.0，見 [LICENSE](../../LICENSE)。`third_party/onnxruntime/` 底下的標頭檔來自
ONNX Runtime（MIT），保留其原始授權。
