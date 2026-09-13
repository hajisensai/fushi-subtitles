<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · **Bahasa Indonesia** · [العربية](README.ar.md)

# fushi-subtitles

Pengenalan suara multibahasa yang menghasilkan takarir. **Inti murni Dart dengan backend ONNX yang
dapat dipasang-lepas**, berjalan di sisi server dan dikendalikan lewat CLI atau antarmuka web
bawaan.

Dipisahkan dari [Fushi](https://github.com/hajisensai/Fushi) menjadi repositori mandiri
(`hajisensai/fushi-subtitles`), yang kemudian menjadi dependensi Fushi. Executable baris
perintahnya bernama `fushi-subs`.

## Apa yang dilakukannya

- **17 bahasa bawaan**: Jepang / Inggris / Mandarin / Kanton / Korea / Rusia /
  Vietnam / Thai masing-masing menjalankan zipformer RNN-T sendiri; Jerman / Spanyol / Prancis /
  Italia / Belanda / Portugis / Turki / Indonesia / Arab menjalankan Omnilingual ASR 1B CTC dari
  Meta.
- **Pakai model Anda sendiri**: manifest bawaan hanyalah nilai awal. Satu berkas JSON sudah cukup
  untuk memasang hasil ekspor zipformer / CTC Anda sendiri, termasuk bahasa di luar 17 bahasa
  bawaan (`fushi-subs models export-manifest` menuliskan templat yang tinggal Anda sunting).
- **Tiga format keluaran**: SRT / WebVTT / JSON.
- **Tiga cara menjalankannya**: baris perintah, HTTP API, dan antarmuka web yang disertakan server.
- **Penyelarasan buku audio** (`fushi_asr_align`): mencocokkan cue takarir dengan teks isi EPUB
  kalimat demi kalimat, memulihkan bagian yang terlewat dengan mengisi balik di antara jangkar,
  lalu memotong ulang cue pada batas kalimat memakai waktu emisi per token — kasus "satu cue
  mencakup beberapa kalimat" terukur 18 → 0.

## Instalasi

Arsip siap pakai ada di [halaman Releases](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel), dan Windows (x64 / arm64). Ekstrak, letakkan `fushi-subs` di `PATH`, pasang ffmpeg (lihat «Prasyarat»), lalu jalankan `fushi-subs doctor` — ia melaporkan apakah ONNX Runtime dan ffmpeg bisa dipakai. Arsip Linux / macOS menyertakan ONNX Runtime di samping berkas eksekusi; di Windows diunduh otomatis saat pertama dijalankan. Biner macOS tidak ditandatangani: setelah ekstrak jalankan sekali `xattr -dr com.apple.quarantine fushi-subs/`.

## Mulai cepat

```bash
dart pub get

# Unduh sebuah model (bahasa Inggris int8, sekitar 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Transkripsikan, takarir keluar ke stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# Atau jalankan server lalu seret berkas ke http://127.0.0.1:8642 di peramban
dart run packages/asr_cli/bin/asr.dart serve
```

CLI juga bisa bertindak sebagai klien tipis dan menyerahkan pekerjaannya ke server jarak jauh:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Prasyarat

| Dependensi | Catatan |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — di bawah itu `GetApi(22)` mengembalikan nullptr, jadi instalasi yang lebih lama tidak terpakai sekalipun sudah ada). Urutan pencarian: variabel lingkungan `ASR_ONNXRUNTIME_LIB` → salinan terkelola yang diambil saat dibutuhkan → di samping executable → jalur pencarian sistem. **Di Windows versi yang layak pakai diunduh otomatis bila tidak ditemukan satu pun** (`Microsoft.ML.OnnxRuntime.DirectML` dari NuGet, 17,9 MB, dipatok dengan sha256, mendarat di `<data root>/asr_runtime/`); yang dipakai adalah build DirectML, bukan rilis GitHub yang hanya CPU, sebab kalau tidak akselerasi GPU hilang tanpa peringatan. `DirectML.dll` sendiri berasal dari komponen sistem Windows. Microsoft Visual C++ Redistributable juga diperlukan. Di macOS gunakan `script/bootstrap_macos.sh`; di Linux gunakan pengelola paket distribusi Anda. |
| **ffmpeg** | Mendekode audio/video apa pun menjadi PCM mono 16 kHz. Urutan pencarian: `ASR_FFMPEG` → di samping executable → `PATH`. `ffprobe` bersifat opsional (tanpanya durasi total tidak diketahui, sehingga persentase kemajuan tidak akurat). |

Variabel lingkungan lainnya: `ASR_DATA_DIR` (akar untuk model dan direktori pekerjaan) dan
`ASR_MODELS_MANIFEST` (manifest model Anda sendiri).

Di macOS, `transcribe --coreml` atau `serve --coreml` secara eksplisit mengaktifkan encoder CoreML
FP32. Model bahasa Jepang saat ini terukur lebih lambat daripada INT8 di CPU, jadi mode otomatis
tetap memilih CPU. Cara pakai, bukti eksekusi operator, dan tolok ukur tiga arah ada di
[docs/MACOS_COREML.md](../MACOS_COREML.md).

## Pakai model Anda sendiri

```bash
fushi-subs models export-manifest -o models.json   # ekspor manifest bawaan sebagai templat
# setelah menyuntingnya
asr --models models.json transcribe -l hi hindi.mp3
```

Manifest digabungkan dengan tabel bawaan berdasarkan `id`, dengan paket Anda ditempatkan lebih
dulu — `id` yang sama menimpa versi bawaan, dan untuk bahasa yang sama milik Anda yang menang.
Paket sekecil-kecilnya hanya butuh `id` / `languages` / `files`:

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

Sisa ruasnya punya nilai bawaan (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **Paket CTC wajib menyatakan `blankToken` secara
eksplisit** — tidak ada nilai bawaan yang disepakati bersama, dan salah menebak akan mengacaukan
seluruh transkrip.

## HTTP API

| Endpoint | Catatan |
|---|---|
| `GET /` | Antarmuka web (satu berkas tanpa sumber daya eksternal, bisa dipakai luring di LAN) |
| `GET /v1/health` | Uji keaktifan, tidak perlu token |
| `GET /v1/models` | Bahasa dan paket model apa saja yang dikenali |
| `POST /v1/transcribe?language=ja&format=srt` | Badan permintaan berisi bita audio, atau badan multipart dengan berkas `audio` dan `epub`. Responsnya berupa NDJSON mengalir, satu peristiwa kemajuan per baris, dengan `result`, `cancelled` atau `error` sebagai baris terakhir |
| `POST /v1/retime?language=ja&format=srt` | Penyetelan ulang waktu takarir: unggah `audio` (audio atau video) dan `subtitle` (SRT/VTT UTF-8, maksimal 8 MiB) sebagai multipart. Teks takarir dan jumlah cue dipertahankan sementara waktunya dikalibrasi ulang terhadap suara; juga mengembalikan NDJSON |

Bila `--token` disetel, permintaan harus membawa `Authorization: Bearer <token>`.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

Penyetelan ulang waktu mendukung parameter `engine`, `filename` dan `jobId` yang sama seperti
transkripsi, ditambah keluaran SRT, VTT dan JSON. `result.text` adalah takarir hasil kalibrasi
ulang dan `rawText` adalah keluaran mentah pengenalan suara; `retiming` melaporkan berapa cue yang
cocok langsung, yang diinterpolasi, atau yang dibiarkan pada waktu aslinya, berikut tingkat
kecocokan, geseran waktu dan peringatan, sehingga Anda bisa memeriksa bagian yang tidak menemukan
jangkar suara yang tepercaya. Nama pembicara di awal baris dan efek suara dalam kurung pada takarir
TV Jepang diabaikan hanya saat pencocokan; teks yang diekspor tetap memakai aslinya. Di tempat
takarir dan segmentasi ASR tidak sepakat, beberapa batas suara yang saling bebas dapat dipakai
untuk memperkirakan geseran waktu atau drift per segmen; perbedaan versi seperti lagu pembuka dan
iklan ditangani terpisah. Antarmukanya membedakan jumlah cue yang dikalibrasi ulang dari kecocokan
satu kalimat penuh dan dari perkiraan, sehingga tingkat kecocokan kalimat penuh tidak disalahartikan
sebagai cakupan kalibrasi ulang.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**Keberhasilan ditentukan oleh datang atau tidaknya baris `result`, bukan oleh kode status HTTP**:
begitu respons mulai mengalir, kode statusnya tidak bisa diubah lagi, sehingga kegagalan hanya
dapat dikirim balik sebagai baris terakhir.

## Tata letak paket

| Paket | Isi | Bergantung pada |
|---|---|---|
| `fushi_asr_core` | Inti transkripsi murni Dart: segmentasi VAD, fbank, graf RNN-T greedy Loop / pendekodean CTC, batching dan bucketing, konversi graf fp16, manifest model dan pengunduhan, keluaran SRT. **Tanpa Flutter, tanpa dart:ffi, tanpa backend ONNX bawaan** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | Backend ONNX Runtime berbasis dart:ffi (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | Penyelarasan EPUB / teks ↔ audio: pencocokan Dice tingkat kalimat (termasuk jalur bacaan ruby), pengisian celah di antara jangkar, pemotongan ulang cue pada batas kalimat | `fushi_asr_core` |
| `fushi_asr` | Fasadnya: `TranscribeRunner` sekali panggil plus format takarir | keduanya di atas |
| `fushi_asr_server` | Server HTTP dan kliennya plus antarmuka web | `fushi_asr` |
| `fushi_asr_cli` | Baris perintah `asr` | `fushi_asr` `fushi_asr_server` `args` |

Inti dari pelapisan ini adalah **lapisan algoritme hanya bergantung pada satu antarmuka sempit**
(`OnnxSessionFactory.createSession`). Host Flutter menyuntikkan backend plugin-nya sendiri, server
menyuntikkan backend FFI, dan algoritme yang sama berjalan di keduanya.

## Pengembangan

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 tests
cd packages/asr_onnx_ffi && dart test    # 15 tests, needs a real onnxruntime (the group skips without one)
cd packages/asr_align && dart test       # 15 tests
cd packages/asr && dart test             # 10 tests
cd packages/asr_server && dart test      # 10 tests
```

Di macOS Apple Silicon, `./script/bootstrap_macos.sh` memasang Dart SDK, FFmpeg dan ONNX Runtime
khusus proyek ini, setelah itu `./script/check.sh` menjalankan pemeriksaan lengkap. Catatan
lingkungan dan saran batasan untuk host macOS ada di
[docs/MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md).

Membangkitkan ulang binding ORT FFI (hanya perlu saat mengganti versi ORT; kode hasil bangkitan
sudah dikomit, jadi pengguna biasa tidak memerlukan LLVM):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Diagnostik: `ASR_TRACE_SHUTDOWN=1` menulis setiap langkah pembongkaran transkripsi ke stderr (tutup
session → tutup jembatan PCM → pesan keluar → server menulis responsnya), untuk mendebug kasus
"sudah selesai tapi menggantung".

Rencana implementasi dan pertimbangan desainnya ada di [docs/PLAN.md](../PLAN.md).

## Lisensi

GPL-3.0, lihat [LICENSE](../../LICENSE). Berkas header di bawah `third_party/onnxruntime/` berasal
dari ONNX Runtime (MIT) dan tetap memakai lisensi aslinya.
