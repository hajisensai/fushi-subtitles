<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · **日本語** · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

字幕を生成する多言語音声認識エンジン。**純粋な Dart のコアと差し替え可能な ONNX バックエンド**で構成され、
サーバーサイドで動作し、CLI または同梱の Web UI から操作します。

[Fushi](https://github.com/hajisensai/Fushi) から独立したリポジトリ（`hajisensai/fushi-subtitles`）
として切り出したもので、Fushi 側がこれを依存関係として利用します。コマンドライン実行ファイル名は
`fushi-subs` です。

## 何ができるか

- **17 言語を内蔵**：日本語 / 英語 / 中国語 / 広東語 / 韓国語 / ロシア語 / ベトナム語 / タイ語 は
  それぞれ専用の zipformer RNN-T で動作し、ドイツ語 / スペイン語 / フランス語 / イタリア語 /
  オランダ語 / ポルトガル語 / トルコ語 / インドネシア語 / アラビア語 は Meta の Omnilingual ASR 1B CTC
  を使います。
- **自前モデルの持ち込み**：内蔵マニフェストはあくまで既定値です。JSON を 1 つ書くだけで独自の
  zipformer / CTC エクスポートを組み込めます。内蔵の 17 言語以外の言語も対象にできます
  （`fushi-subs models export-manifest` で編集用のテンプレートを書き出せます）。
- **3 種類の出力形式**：SRT / WebVTT / JSON。
- **3 通りの操作方法**：コマンドライン、HTTP API、そしてサーバーに同梱された Web UI。
- **オーディオブックのアライメント**（`fushi_asr_align`）：字幕 cue を EPUB の本文と一文ずつ突き合わせ、
  アンカー間を埋め戻して取りこぼした箇所を回収し、さらにトークン単位の発話時刻を使って文境界で
  cue を切り直します。「1 つの cue が複数の文をまたぐ」件数は実測で 18 → 0 になりました。

## インストール

ビルド済みアーカイブは [Releases ページ](https://github.com/hajisensai/fushi-subtitles/releases) にあります：Linux（x64 / arm64）、macOS（Apple Silicon / Intel）、Windows（x64 / arm64）。展開して `fushi-subs` を `PATH` に置き、ffmpeg をインストール（「前提条件」参照）してから `fushi-subs doctor` を実行してください。ONNX Runtime と ffmpeg が使えるかを報告します。Linux / macOS のアーカイブには ONNX Runtime が実行ファイルの隣に同梱され、Windows では初回実行時に自動ダウンロードされます。macOS のバイナリは未署名です：展開後に一度 `xattr -dr com.apple.quarantine fushi-subs/` を実行してください。

## クイックスタート

```bash
dart pub get

# モデルをダウンロード（英語 int8、約 67 MB）
dart run packages/asr_cli/bin/asr.dart models pull -l en

# 文字起こし。字幕は stdout に出力される
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# あるいはサーバーを起動し、ブラウザで http://127.0.0.1:8642 を開いてファイルをドロップする
dart run packages/asr_cli/bin/asr.dart serve
```

CLI はシンクライアントとして振る舞い、処理をリモートサーバーに任せることもできます。

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### 前提条件

| 依存関係 | 備考 |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib`（**1.22 以上**。これより古いと `GetApi(22)` が nullptr を返すため、インストール済みでも使えません）。探索順は、`ASR_ONNXRUNTIME_LIB` 環境変数 → 必要に応じて取得される管理下のコピー → 実行ファイルと同じ場所 → システムの検索パス。**Windows では使えるバージョンが見つからない場合に自動でダウンロードします**（NuGet の `Microsoft.ML.OnnxRuntime.DirectML`、17.9 MB、sha256 で固定、配置先は `<データルート>/asr_runtime/`）。GitHub リリースの CPU 専用ビルドではなく DirectML ビルドを使うのは、そうしないと GPU アクセラレーションが黙って失われるためです。`DirectML.dll` 自体は Windows のシステムコンポーネントから供給されます。加えて Microsoft Visual C++ 再頒布可能パッケージも必要です。macOS では `script/bootstrap_macos.sh` を、Linux ではディストリビューションのパッケージマネージャーを使ってください。 |
| **ffmpeg** | 任意の音声／動画を 16 kHz モノラル PCM にデコードします。探索順は `ASR_FFMPEG` → 実行ファイルと同じ場所 → `PATH`。`ffprobe` は任意です（無い場合は総再生時間が分からないため、進捗のパーセンテージが不正確になります）。 |

その他の環境変数：`ASR_DATA_DIR`（モデルとジョブディレクトリのルート）と
`ASR_MODELS_MANIFEST`（独自のモデルマニフェスト）。

macOS では `transcribe --coreml` または `serve --coreml` で CoreML FP32 エンコーダーを明示的に
有効化できます。現行の日本語モデルは実測で CPU の INT8 より遅いため、自動モードでは依然として
CPU が選ばれます。使い方、演算子が実際に実行されている証拠、3 方式のベンチマークは
[docs/MACOS_COREML.md](../MACOS_COREML.md) にあります。

## 自前モデルの持ち込み

```bash
fushi-subs models export-manifest -o models.json   # 内蔵マニフェストをテンプレートとして書き出す
# 編集したあとで
asr --models models.json transcribe -l hi hindi.mp3
```

マニフェストは `id` をキーに内蔵テーブルとマージされ、自分のパックが先に並びます。つまり同じ `id` は
内蔵側を上書きし、同じ言語なら自分のものが優先されます。最小構成のパックに必要なのは
`id` / `languages` / `files` だけです。

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

残りのフィールドには既定値があります（`architecture: transducer`、`indexType: int64`、
`decoderContextSize: 2`、`blankToken: <blk>`）。**CTC パックでは `blankToken` を明示する必要があります**。
これには広く合意された既定値が存在せず、推測を誤ると文字起こし全体が壊れてしまうためです。

## HTTP API

| エンドポイント | 備考 |
|---|---|
| `GET /` | Web UI（外部リソースを持たない単一ファイル。LAN 内でオフライン利用可能） |
| `GET /v1/health` | 死活監視用のプローブ。トークン不要 |
| `GET /v1/models` | 認識できる言語とモデルパックの一覧 |
| `POST /v1/transcribe?language=ja&format=srt` | リクエストボディは音声のバイト列、または `audio` と `epub` の 2 ファイルを含む multipart。レスポンスはストリーミング NDJSON で、1 行につき 1 つの進捗イベント、最終行が `result`、`cancelled`、`error` のいずれかになります |
| `POST /v1/retime?language=ja&format=srt` | 字幕のタイミング再調整：`audio`（音声または動画）と `subtitle`（UTF-8 の SRT/VTT、最大 8 MiB）を multipart でアップロードします。字幕のテキストと cue 数は保ったまま、音声に合わせてタイミングだけを再校正します。こちらも NDJSON を返します |

`--token` を設定している場合、リクエストには `Authorization: Bearer <token>` が必要です。

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

タイミング再調整は文字起こしと同じ `engine`、`filename`、`jobId` パラメータに対応し、出力も
SRT、VTT、JSON が使えます。`result.text` が再校正後の字幕、`rawText` が音声認識の生の出力です。
`retiming` には、直接マッチした cue 数、補間した cue 数、元のタイミングのまま残した cue 数に加え、
マッチ率、時間オフセット、警告が含まれるため、信頼できる音声アンカーが見つからなかった箇所を
確認できます。日本語のテレビ字幕にある行頭の話者名や括弧付きの効果音は、マッチングの際にのみ
無視され、書き出されるテキストには元のまま残ります。字幕と ASR の分割が食い違う場合は、複数の
独立した音声境界からセグメントごとの時間オフセットやドリフトを推定できます。オープニングや
コマーシャルといったバージョン差は個別に扱われます。UI は再校正された cue 数、文全体のマッチ、
推定値を区別して表示するので、文全体のマッチ率を再校正のカバレッジと取り違えることはありません。

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**成功したかどうかは HTTP ステータスコードではなく、`result` 行が届いたかどうかで判断します**。
レスポンスのストリーミングが始まってしまうとステータスコードは変更できないため、失敗は最終行と
してしか返せないからです。

## パッケージ構成

| パッケージ | 内容 | 依存 |
|---|---|---|
| `fushi_asr_core` | 純粋な Dart の文字起こしコア：VAD による分割、fbank、RNN-T の貪欲 Loop グラフ / CTC デコード、バッチ化とバケット分け、fp16 グラフ変換、モデルマニフェストとダウンロード、SRT 出力。**Flutter なし、dart:ffi なし、ONNX バックエンドの同梱なし** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | dart:ffi による ONNX Runtime バックエンド（CPU / DirectML / CUDA） | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | EPUB / テキスト ↔ 音声のアライメント：文単位の Dice マッチング（ルビの読みトラックを含む）、アンカー間のギャップ埋め戻し、文境界での cue 再分割 | `fushi_asr_core` |
| `fushi_asr` | ファサード：呼び出し 1 回で済む `TranscribeRunner` と字幕フォーマット | 上記 2 つ |
| `fushi_asr_server` | HTTP サーバーとクライアント、および Web UI | `fushi_asr` |
| `fushi_asr_cli` | `asr` コマンドライン | `fushi_asr` `fushi_asr_server` `args` |

この階層化の狙いは、**アルゴリズム層が 1 つの狭いインターフェースだけに依存する**ことです
（`OnnxSessionFactory.createSession`）。Flutter ホストは自前のプラグインバックエンドを、サーバーは
FFI バックエンドを注入し、同一のアルゴリズムが両方で動きます。

## 開発

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 件
cd packages/asr_onnx_ffi && dart test    # 15 件。実物の onnxruntime が必要（無い場合はグループごと skip）
cd packages/asr_align && dart test       # 15 件
cd packages/asr && dart test             # 10 件
cd packages/asr_server && dart test      # 10 件
```

Apple Silicon の macOS では、`./script/bootstrap_macos.sh` がプロジェクトローカルの Dart SDK、
FFmpeg、ONNX Runtime をインストールし、そのあと `./script/check.sh` で一通りのチェックを実行します。
macOS ホスト向けの環境メモと境界に関する指針は [docs/MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md)
にあります。

ORT の FFI バインディングの再生成（ORT のバージョンを変更するときにのみ必要です。生成コードは
コミット済みなので、通常の利用者に LLVM は不要です）：

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

診断：`ASR_TRACE_SHUTDOWN=1` を指定すると、文字起こし終了処理の各ステップが stderr に書き出されます
（セッションのクローズ → PCM ブリッジのクローズ → 終了メッセージ → サーバーがレスポンスを書き出す）。
「完了したのにハングする」を調べるときに使います。

実装計画と設計上のトレードオフは [docs/PLAN.md](../PLAN.md) にあります。

## ライセンス

GPL-3.0、[LICENSE](../../LICENSE) を参照してください。`third_party/onnxruntime/` 以下のヘッダーは
ONNX Runtime（MIT）由来で、元のライセンスをそのまま維持しています。
