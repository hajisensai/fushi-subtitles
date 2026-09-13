<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · **Türkçe** · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

Altyazı üreten çok dilli konuşma tanıma. **Takılabilir bir ONNX arka ucuna sahip, saf Dart ile
yazılmış bir çekirdek**; sunucu tarafında çalışır, komut satırından ya da dahili web arayüzünden
yönetilir.

[Fushi](https://github.com/hajisensai/Fushi) projesinden ayrılarak bağımsız bir depoya
(`hajisensai/fushi-subtitles`) taşındı; Fushi artık bu depoya bağımlı. Komut satırı çalıştırılabilir
dosyasının adı `fushi-subs`.

## Neler yapar

- **17 yerleşik dil**: Japonca / İngilizce / Çince / Kantonca / Korece / Rusça / Vietnamca / Tayca
  dillerinin her biri kendi zipformer RNN-T modeliyle çalışır; Almanca / İspanyolca / Fransızca /
  İtalyanca / Felemenkçe / Portekizce / Türkçe / Endonezce / Arapça ise Meta'nın Omnilingual ASR 1B
  CTC modelini kullanır.
- **Kendi modellerinizi getirin**: yerleşik manifest yalnızca bir varsayılandır. Kendi zipformer /
  CTC dışa aktarımlarınızı, yerleşik 17 dilin dışındaki diller de dahil olmak üzere, tek bir JSON
  dosyasıyla bağlayabilirsiniz (`fushi-subs models export-manifest` düzenlemeniz için bir şablon
  yazar).
- **Üç çıktı biçimi**: SRT / WebVTT / JSON.
- **Üç kullanım yolu**: komut satırı, HTTP API ve sunucuyla birlikte gelen web arayüzü.
- **Sesli kitap hizalama** (`fushi_asr_align`): altyazı bloklarını EPUB gövde metniyle cümle cümle
  eşleştirir, atlanan bölümleri çapalar arasını doldurarak geri kazanır, ardından belirteç başına
  üretim zamanlarını kullanarak blokları cümle sınırlarından yeniden böler — "birkaç cümleyi
  kapsayan tek blok" ölçümü 18 → 0 oldu.

## Kurulum

Önceden derlenmiş arşivler [Releases sayfasında](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel) ve Windows (x64 / arm64). Açın, `fushi-subs` dosyasını `PATH` içine koyun, ffmpeg kurun (bkz. «Ön koşullar») ve `fushi-subs doctor` çalıştırın – ONNX Runtime ile ffmpeg kullanılabilir mi bildirir. Linux ve macOS arşivlerinde ONNX Runtime çalıştırılabilir dosyanın yanında gelir; Windows'ta ilk çalıştırmada otomatik indirilir. macOS ikilileri imzasızdır: açtıktan sonra bir kez `xattr -dr com.apple.quarantine fushi-subs/` çalıştırın.

## Hızlı başlangıç

```bash
dart pub get

# Bir model indir (İngilizce int8, yaklaşık 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Deşifre et, altyazılar stdout'a gider
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# Ya da sunucuyu başlat ve tarayıcıda http://127.0.0.1:8642 adresine dosya bırak
dart run packages/asr_cli/bin/asr.dart serve
```

Komut satırı aracı ince bir istemci gibi de davranıp işi uzak bir sunucuya devredebilir:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Ön koşullar

| Bağımlılık | Notlar |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — daha eskisinde `GetApi(22)` nullptr döndürür, dolayısıyla eski bir kurulum mevcut olsa bile kullanılamaz). Arama sırası: `ASR_ONNXRUNTIME_LIB` ortam değişkeni → gerektiğinde indirilen yönetilen kopya → çalıştırılabilir dosyanın yanı → sistem arama yolu. **Windows'ta hiçbiri bulunamazsa kullanılabilir bir sürüm otomatik olarak indirilir** (NuGet'teki `Microsoft.ML.OnnxRuntime.DirectML`, 17.9 MB, sha256 ile sabitlenmiş, `<data root>/asr_runtime/` altına iner); yalnızca CPU içeren GitHub sürümü yerine DirectML derlemesi kullanılır, aksi hâlde GPU hızlandırma sessizce yok olur. `DirectML.dll` dosyasının kendisi Windows sistem bileşeninden gelir. Ayrıca Microsoft Visual C++ Redistributable de gereklidir. macOS'ta `script/bootstrap_macos.sh` betiğini kullanın; Linux'ta dağıtımınızın paket yöneticisini. |
| **ffmpeg** | Herhangi bir ses/video girdisini 16 kHz mono PCM'e çözer. Arama sırası: `ASR_FFMPEG` → çalıştırılabilir dosyanın yanı → `PATH`. `ffprobe` isteğe bağlıdır (onsuz toplam süre bilinmez, bu yüzden ilerleme yüzdesi isabetsiz olur). |

Diğer ortam değişkenleri: `ASR_DATA_DIR` (modeller ve iş dizinleri için kök) ve
`ASR_MODELS_MANIFEST` (kendi model manifestiniz).

macOS'ta `transcribe --coreml` veya `serve --coreml`, CoreML FP32 kodlayıcısını açıkça etkinleştirir.
Mevcut Japonca model, ölçümlerde CPU üzerindeki INT8'den daha yavaş çıkıyor; bu nedenle otomatik mod
yine CPU'yu seçiyor. Kullanım, operatörlerin gerçekten çalıştığının kanıtı ve üç yönlü kıyaslamalar
[../MACOS_COREML.md](../MACOS_COREML.md) dosyasında.

## Kendi modellerinizi getirin

```bash
fushi-subs models export-manifest -o models.json   # yerleşik manifesti şablon olarak dışa aktar
# düzenledikten sonra
asr --models models.json transcribe -l hi hindi.mp3
```

Manifest, yerleşik tabloyla `id` üzerinden birleştirilir ve sizin paketleriniz öne konur — aynı `id`
yerleşik olanı geçersiz kılar, aynı dil için de sizinki kazanır. Olabilecek en küçük paket yalnızca
`id` / `languages` / `files` gerektirir:

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

Geri kalan alanların varsayılanları vardır (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **Bir CTC paketi `blankToken` değerini açıkça
belirtmek zorundadır** — üzerinde uzlaşılmış bir varsayılan yoktur ve yanlış tahmin tüm deşifre
metnini bozar.

## HTTP API

| Uç nokta | Notlar |
|---|---|
| `GET /` | Web arayüzü (dış kaynağı olmayan tek dosya, yerel ağda çevrimdışı kullanılabilir) |
| `GET /v1/health` | Canlılık yoklaması, token gerektirmez |
| `GET /v1/models` | Hangi dillerin ve model paketlerinin bilindiği |
| `POST /v1/transcribe?language=ja&format=srt` | İstek gövdesi ses baytlarıdır ya da bir `audio` ve bir `epub` dosyası içeren multipart gövdedir. Yanıt, satır başına bir ilerleme olayı içeren akış hâlinde NDJSON'dur; son satır `result`, `cancelled` veya `error` olur |
| `POST /v1/retime?language=ja&format=srt` | Altyazı zamanlamasının yeniden ayarlanması: multipart olarak `audio` (ses veya video) ve `subtitle` (UTF-8 SRT/VTT, en fazla 8 MiB) yükleyin. Altyazı metni ve blok sayısı korunurken zamanlamalar konuşmaya göre yeniden kalibre edilir; bu da NDJSON döndürür |

`--token` ayarlandığında istekler `Authorization: Bearer <token>` başlığını taşımalıdır.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

Yeniden zamanlama, deşifre etmeyle aynı `engine`, `filename` ve `jobId` parametrelerini destekler;
ayrıca SRT, VTT ve JSON çıktısı verir. `result.text` yeniden kalibre edilmiş altyazı, `rawText` ise
ham konuşma tanıma çıktısıdır; `retiming`, kaç bloğun doğrudan eşleştiğini, kaçının aradeğerlendiğini
ve kaçının özgün zamanlamasında bırakıldığını, eşleşme oranı, zaman kayması ve uyarılarla birlikte
bildirir; böylece güvenilir bir konuşma çapası bulunamayan yerleri inceleyebilirsiniz. Japon
televizyon altyazılarındaki baştaki konuşmacı adları ve parantez içindeki ses efektleri yalnızca
eşleştirme sırasında yok sayılır; dışa aktarılan metin özgün hâlini korur. Altyazılarla ASR
bölütlemesinin uyuşmadığı yerlerde, bölüt başına zaman kayması veya sürüklenmeyi kestirmek için
birbirinden bağımsız birkaç konuşma sınırı kullanılabilir; açılış jenerikleri ve reklamlar gibi sürüm
farkları ayrıca ele alınır. Arayüz, yeniden kalibre edilmiş blok sayılarını tam cümle eşleşmelerinden
ve kestirimlerden ayırt eder; böylece tam cümle eşleşme oranı, yeniden kalibrasyon kapsamı sanılmaz.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**Başarıyı belirleyen şey, HTTP durum kodu değil, bir `result` satırının gelip gelmediğidir**: yanıt
akmaya başladıktan sonra durum kodu artık değiştirilemez, dolayısıyla bir hata ancak son satır olarak
geri gönderilebilir.

## Paket düzeni

| Paket | İçerik | Bağımlılıkları |
|---|---|---|
| `fushi_asr_core` | Saf Dart deşifre çekirdeği: VAD bölütleme, fbank, RNN-T açgözlü Loop grafiği / CTC kod çözme, toplu işleme ve kovalama, fp16 grafik dönüşümü, model manifesti ve indirmeler, SRT çıktısı. **Flutter yok, dart:ffi yok, paketlenmiş ONNX arka ucu yok** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | dart:ffi ile ONNX Runtime arka ucu (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | EPUB / metin ↔ ses hizalaması: cümle düzeyinde Dice eşleştirmesi (ruby okuma izi dahil), çapalar arasındaki boşlukların doldurulması, blokların cümle sınırlarından yeniden bölünmesi | `fushi_asr_core` |
| `fushi_asr` | Cephe: tek çağrılık bir `TranscribeRunner` ve altyazı biçimleri | yukarıdaki ikisi |
| `fushi_asr_server` | HTTP sunucusu ile istemcisi ve web arayüzü | `fushi_asr` |
| `fushi_asr_cli` | `asr` komut satırı | `fushi_asr` `fushi_asr_server` `args` |

Bu katmanlamanın amacı, **algoritma katmanının yalnızca tek bir dar arayüze bağımlı olmasıdır**
(`OnnxSessionFactory.createSession`). Bir Flutter uygulaması kendi eklenti arka ucunu enjekte eder,
sunucu FFI arka ucunu enjekte eder ve aynı algoritmalar her ikisinde de çalışır.

## Geliştirme

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 test
cd packages/asr_onnx_ffi && dart test    # 15 test, gerçek bir onnxruntime gerekir (yoksa grup atlanır)
cd packages/asr_align && dart test       # 15 test
cd packages/asr && dart test             # 10 test
cd packages/asr_server && dart test      # 10 test
```

Apple Silicon macOS'ta `./script/bootstrap_macos.sh` projeye özel bir Dart SDK, FFmpeg ve ONNX
Runtime kurar; ardından `./script/check.sh` tüm denetimi çalıştırır. macOS makinesine dair ortam
notları ve sınır önerileri [../MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md) dosyasında.

ORT FFI bağlarının yeniden üretilmesi (yalnızca ORT sürümü değişirse gerekir; üretilen kod depoya
işlendiği için sıradan kullanıcıların LLVM'ye ihtiyacı yoktur):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Tanılama: `ASR_TRACE_SHUTDOWN=1`, deşifre kapanışının her adımını stderr'e yazar (oturumu kapat → PCM
köprüsünü kapat → çıkış mesajı → sunucu yanıtı yazar); "bitti ama takılı kalıyor" durumlarını
ayıklamak için.

Uygulama planı ve tasarım ödünleşimleri [../PLAN.md](../PLAN.md) dosyasında.

## Lisans

GPL-3.0, bkz. [LICENSE](../../LICENSE). `third_party/onnxruntime/` altındaki başlık dosyaları ONNX
Runtime'dan (MIT) gelir ve özgün lisanslarını korur.
