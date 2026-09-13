<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · **العربية**

# fushi-subtitles

تعرّف على الكلام متعدد اللغات يُنتج ملفات ترجمة. **نواة مكتوبة بلغة Dart خالصة مع خلفية ONNX قابلة
للاستبدال**، تعمل على جانب الخادم وتُدار من سطر الأوامر أو من واجهة الويب المضمّنة.

استُخرج المشروع من [Fushi](https://github.com/hajisensai/Fushi) إلى مستودع مستقل باسم
(`hajisensai/fushi-subtitles`)، ثم صار Fushi يعتمد عليه. أما ملف سطر الأوامر التنفيذي فاسمه
`fushi-subs`.

## ماذا يفعل

- **17 لغة مضمّنة**: اليابانية / الإنجليزية / الصينية / الكانتونية / الكورية / الروسية /
  الفيتنامية / التايلاندية، ولكلٍّ منها نموذج zipformer RNN-T خاص بها؛ أما الألمانية / الإسبانية /
  الفرنسية / الإيطالية / الهولندية / البرتغالية / التركية / الإندونيسية / العربية فتعمل بنموذج
  Omnilingual ASR 1B CTC من Meta.
- **أحضر نماذجك الخاصة**: البيان المضمّن ليس إلا إعدادًا افتراضيًا. يكفي ملف JSON واحد لتركيب
  صادرات zipformer / CTC الخاصة بك، بما في ذلك لغات خارج اللغات السبع عشرة المضمّنة
  (`fushi-subs models export-manifest` يكتب لك قالبًا جاهزًا للتعديل).
- **ثلاث صيغ للإخراج**: SRT / WebVTT / JSON.
- **ثلاث طرق للتشغيل**: سطر الأوامر، وواجهة HTTP البرمجية، وواجهة الويب التي تأتي مع الخادم.
- **محاذاة الكتب الصوتية** (`fushi_asr_align`): تطابق مقاطع الترجمة مع نص EPUB جملةً بجملة،
  وتستعيد المقاطع الفائتة عبر الملء الرجعي بين نقاط الارتساء، ثم تعيد تقسيم المقاطع عند حدود الجمل
  بالاعتماد على أزمنة الإصدار لكل رمز — فحالة "مقطع واحد يغطي عدة جمل" قيست 18 → 0.

## التثبيت

الأرشيفات الجاهزة موجودة في [صفحة Releases](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64) و macOS (Apple Silicon / Intel) و Windows (x64 / arm64). فكّ الضغط، ضع `fushi-subs` في `PATH`، ثبّت ffmpeg (انظر «المتطلبات»)، ثم شغّل `fushi-subs doctor` — يخبرك إن كان ONNX Runtime و ffmpeg جاهزين. أرشيفات Linux و macOS تحوي ONNX Runtime بجوار الملف التنفيذي؛ على Windows يُنزَّل تلقائياً عند أول تشغيل. ثنائيات macOS غير موقّعة: بعد فك الضغط شغّل مرة واحدة `xattr -dr com.apple.quarantine fushi-subs/`.

## البداية السريعة

```bash
dart pub get

# نزّل نموذجًا (الإنجليزية int8، نحو 67 ميغابايت)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# فرِّغ الصوت نصًّا، وتذهب الترجمة إلى stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# أو شغّل الخادم واسحب الملفات إلى http://127.0.0.1:8642 في المتصفح
dart run packages/asr_cli/bin/asr.dart serve
```

كما يمكن لسطر الأوامر أن يعمل كعميل خفيف يُسند العمل إلى خادم بعيد:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### المتطلبات المسبقة

| الاعتمادية | ملاحظات |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — وما دون ذلك يُرجع `GetApi(22)` قيمة nullptr، فتصبح النسخة الأقدم غير صالحة للاستعمال حتى لو كانت مثبّتة). ترتيب البحث: متغير البيئة `ASR_ONNXRUNTIME_LIB` → النسخة المُدارة التي تُجلب عند الحاجة → بجوار الملف التنفيذي → مسار البحث في النظام. **على Windows تُنزَّل نسخة صالحة تلقائيًا عند عدم العثور على أي نسخة** (حزمة `Microsoft.ML.OnnxRuntime.DirectML` من NuGet، بحجم 17.9 ميغابايت، مثبّتة بـ sha256، وتُوضع في `<data root>/asr_runtime/`)؛ ونستخدم بناء DirectML بدلًا من إصدار GitHub المقتصر على المعالج، وإلا اختفى تسريع كرت الرسوميات بصمت. أما `DirectML.dll` نفسه فيأتي من مكوّنات نظام Windows. كذلك يلزم وجود Microsoft Visual C++ Redistributable. على macOS استخدم `script/bootstrap_macos.sh`؛ وعلى Linux استخدم مدير الحزم الخاص بتوزيعتك. |
| **ffmpeg** | يفك ترميز أي ملف صوتي أو مرئي إلى PCM أحادي القناة بتردد 16 كيلوهرتز. ترتيب البحث: `ASR_FFMPEG` → بجوار الملف التنفيذي → `PATH`. أما `ffprobe` فاختياري (بدونه تبقى المدة الإجمالية مجهولة، فتصبح نسبة التقدم غير دقيقة). |

متغيرات بيئة أخرى: `ASR_DATA_DIR` (المجلد الجذر للنماذج ومجلدات المهام) و
`ASR_MODELS_MANIFEST` (بيان النماذج الخاص بك).

على macOS، يُفعّل الأمر `transcribe --coreml` أو `serve --coreml` مُرمِّز CoreML بدقة FP32 صراحةً.
والنموذج الياباني الحالي قيس أبطأ من INT8 على المعالج، لذا ما زال الوضع التلقائي يختار المعالج.
تجد طريقة الاستعمال، وإثبات تنفيذ المعاملات، والقياسات الثلاثية المقارنة في
[docs/MACOS_COREML.md](../MACOS_COREML.md).

## أحضر نماذجك الخاصة

```bash
fushi-subs models export-manifest -o models.json   # صدّر البيان المضمّن ليكون قالبًا
# بعد تعديله
asr --models models.json transcribe -l hi hindi.mp3
```

يُدمج البيان مع الجدول المضمّن بحسب `id`، مع وضع حزمك أولًا — فنفس `id` يتجاوز المضمّن، وفي حالة
اللغة نفسها تفوز حزمتك. وأصغر حزمة ممكنة لا تحتاج سوى `id` / `languages` / `files`:

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

أما بقية الحقول فلها قيم افتراضية (`architecture: transducer`، `indexType: int64`،
`decoderContextSize: 2`، `blankToken: <blk>`). **وعلى حزمة CTC أن تصرّح بـ `blankToken` صراحةً** —
إذ لا توجد قيمة افتراضية متفق عليها، والتخمين الخاطئ يفسد النص المُفرَّغ بأكمله.

## واجهة HTTP البرمجية

| نقطة النهاية | ملاحظات |
|---|---|
| `GET /` | واجهة الويب (ملف واحد بلا أي موارد خارجية، صالحة للعمل دون اتصال داخل الشبكة المحلية) |
| `GET /v1/health` | فحص الحياة، ولا يتطلب رمزًا |
| `GET /v1/models` | ما هي اللغات وحزم النماذج المعروفة |
| `POST /v1/transcribe?language=ja&format=srt` | جسم الطلب هو بايتات الصوت، أو جسم multipart يحوي ملف `audio` وملف `epub`. والاستجابة NDJSON متدفقة، حدث تقدم واحد في كل سطر، ويكون آخر سطر `result` أو `cancelled` أو `error` |
| `POST /v1/retime?language=ja&format=srt` | إعادة ضبط توقيت الترجمة: ارفع `audio` (صوت أو فيديو) و`subtitle` (ملف SRT/VTT بترميز UTF-8، بحد أقصى 8 ميبي بايت) بصيغة multipart. يُحفظ نص الترجمة وعدد المقاطع بينما يُعاد معايرة التوقيتات على الكلام؛ وتُرجع كذلك NDJSON |

عند ضبط `--token`، يجب أن تحمل الطلبات ترويسة `Authorization: Bearer <token>`.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

تدعم إعادة الضبط الزمني نفس معاملات `engine` و`filename` و`jobId` المستعملة في التفريغ النصي،
إضافةً إلى الإخراج بصيغ SRT وVTT وJSON. فـ `result.text` هو الترجمة بعد إعادة المعايرة، و`rawText`
هو الناتج الخام لتعرّف الكلام؛ بينما يبلّغ `retiming` عن عدد المقاطع التي طوبقت مباشرةً، وتلك التي
استُوفيت بالاستيفاء، وتلك التي بقيت على توقيتاتها الأصلية، مع نسبة التطابق وإزاحة الوقت
والتحذيرات، حتى يتسنى لك فحص المواضع التي لم يُعثر فيها على نقطة ارتساء كلامية موثوقة. أما أسماء
المتحدثين في بداية السطر والمؤثرات الصوتية بين الأقواس في ترجمات التلفزيون الياباني فتُتجاهل أثناء
المطابقة فقط؛ والنص المُصدَّر يبقي على الأصل. وحيث تختلف الترجمة عن تقسيم ASR، يمكن استخدام عدة
حدود كلامية مستقلة لتقدير إزاحة زمنية أو انحراف زمني لكل مقطع؛ أما فروق النسخ مثل مقدمات الحلقات
والفواصل الإعلانية فتُعالَج على حدة. وتميّز الواجهة بين عدد المقاطع المعاد معايرتها وبين مطابقات
الجملة الكاملة وبين التقديرات، حتى لا تُفهم نسبة مطابقة الجملة الكاملة على أنها نسبة تغطية إعادة
المعايرة.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**النجاح يُحسم بوصول سطر `result` لا برمز حالة HTTP**: فما إن تبدأ الاستجابة بالتدفق حتى يتعذّر
تغيير رمز الحالة، ولذلك لا سبيل لإرسال الفشل إلا في السطر الأخير.

## بنية الحزم

| الحزمة | المحتوى | تعتمد على |
|---|---|---|
| `fushi_asr_core` | نواة التفريغ النصي المكتوبة بلغة Dart خالصة: تقسيم VAD، وfbank، ومخطط RNN-T greedy Loop / فك ترميز CTC، والتجميع الدُّفعي والتوزيع على السلال، وتحويل المخطط إلى fp16، وبيان النماذج وتنزيلها، وإخراج SRT. **بلا Flutter، وبلا dart:ffi، وبلا خلفية ONNX مرفقة** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | خلفية ONNX Runtime عبر dart:ffi (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | محاذاة EPUB / النص ↔ الصوت: مطابقة Dice على مستوى الجملة (بما في ذلك مسار قراءة ruby)، وملء الفجوات بين نقاط الارتساء، وإعادة تقسيم المقاطع عند حدود الجمل | `fushi_asr_core` |
| `fushi_asr` | الواجهة الجامعة: `TranscribeRunner` باستدعاء واحد إضافةً إلى صيغ الترجمة | الحزمتان أعلاه |
| `fushi_asr_server` | خادم HTTP وعميله إضافةً إلى واجهة الويب | `fushi_asr` |
| `fushi_asr_cli` | سطر أوامر `asr` | `fushi_asr` `fushi_asr_server` `args` |

والغاية من هذا التطبيق الطبقي أن **طبقة الخوارزميات لا تعتمد إلا على واجهة ضيقة واحدة**
(`OnnxSessionFactory.createSession`). فمضيف Flutter يحقن خلفية الملحق الخاصة به، والخادم يحقن
خلفية FFI، وتعمل الخوارزميات نفسها في الحالتين.

## التطوير

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 tests
cd packages/asr_onnx_ffi && dart test    # 15 tests, needs a real onnxruntime (the group skips without one)
cd packages/asr_align && dart test       # 15 tests
cd packages/asr && dart test             # 10 tests
cd packages/asr_server && dart test      # 10 tests
```

على أجهزة macOS بمعالجات Apple Silicon، يثبّت `./script/bootstrap_macos.sh` نسخة محلية للمشروع من
Dart SDK وFFmpeg وONNX Runtime، ثم يشغّل `./script/check.sh` الفحص الكامل. وتجد ملاحظات البيئة
وإرشادات الحدود الخاصة بمضيف macOS في [docs/MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md).

إعادة توليد ارتباطات ORT FFI (لا يلزم ذلك إلا عند تغيير إصدار ORT؛ فالشيفرة المولَّدة مودعة في
المستودع، ومن ثم لا يحتاج المستخدم العادي إلى LLVM):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

التشخيص: يكتب `ASR_TRACE_SHUTDOWN=1` كل خطوة من خطوات إنهاء التفريغ النصي إلى stderr (إغلاق
الجلسة → إغلاق جسر PCM → رسالة الخروج → كتابة الخادم للاستجابة)، وذلك لتصحيح حالة "انتهى لكنه
معلّق".

أما خطة التنفيذ والموازنات التصميمية فتجدها في [docs/PLAN.md](../PLAN.md).

## الرخصة

GPL-3.0، انظر [LICENSE](../../LICENSE). أما ملفات الترويسة الموجودة تحت `third_party/onnxruntime/`
فمصدرها ONNX Runtime (MIT) وتحتفظ برخصتها الأصلية.
