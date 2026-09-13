<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · **ไทย** · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

ระบบรู้จำเสียงพูดหลายภาษาที่สร้างออกมาเป็นคำบรรยาย **แกนหลักเขียนด้วย Dart ล้วน พร้อมแบ็กเอนด์
ONNX ที่ถอดเปลี่ยนได้** ทำงานฝั่งเซิร์ฟเวอร์ และสั่งงานผ่าน CLI หรือเว็บ UI ที่มีมาให้ในตัว

แยกออกมาจาก [Fushi](https://github.com/hajisensai/Fushi) เป็นรีโพซิทอรีอิสระ
(`hajisensai/fushi-subtitles`) แล้วให้ Fushi กลับมาพึ่งพาอีกที ไฟล์สั่งการบรรทัดคำสั่งชื่อว่า
`fushi-subs`

## ความสามารถ

- **17 ภาษาในตัว**: ญี่ปุ่น / อังกฤษ / จีนกลาง / กวางตุ้ง / เกาหลี / รัสเซีย /
  เวียดนาม / ไทย แต่ละภาษาใช้ zipformer RNN-T ของตัวเอง ส่วนเยอรมัน / สเปน / ฝรั่งเศส / อิตาลี /
  ดัตช์ / โปรตุเกส / ตุรกี / อินโดนีเซีย / อาหรับ ใช้ Omnilingual ASR 1B CTC ของ Meta
- **ใส่โมเดลของคุณเองได้**: manifest ที่มีมาให้เป็นเพียงค่าเริ่มต้น ใช้ไฟล์ JSON เพียงไฟล์เดียว
  ก็เสียบ zipformer / CTC ที่คุณ export เองเข้าไปได้ รวมถึงภาษาที่อยู่นอก 17 ภาษาในตัว
  (`fushi-subs models export-manifest` จะเขียนเทมเพลตออกมาให้แก้)
- **สามรูปแบบผลลัพธ์**: SRT / WebVTT / JSON
- **สามวิธีสั่งงาน**: บรรทัดคำสั่ง, HTTP API และเว็บ UI ที่มากับเซิร์ฟเวอร์
- **การจัดแนวหนังสือเสียง** (`fushi_asr_align`): จับคู่ cue คำบรรยายกับเนื้อความ EPUB
  ทีละประโยค กู้ช่วงที่หลุดไปด้วยการเติมย้อนกลับระหว่างจุดยึด แล้วตัด cue ใหม่ตามขอบเขตประโยค
  โดยใช้เวลาการปล่อยผลรายโทเคน — กรณี "cue เดียวคลุมหลายประโยค" วัดได้ 18 → 0

## การติดตั้ง

ไฟล์ที่คอมไพล์แล้วอยู่ที่[หน้า Releases](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel) และ Windows (x64 / arm64) แตกไฟล์ นำ `fushi-subs` ไปไว้ใน `PATH` ติดตั้ง ffmpeg (ดู «สิ่งที่ต้องมี») แล้วรัน `fushi-subs doctor` ซึ่งจะรายงานว่า ONNX Runtime และ ffmpeg ใช้งานได้หรือไม่ ไฟล์สำหรับ Linux / macOS มี ONNX Runtime อยู่ข้างไฟล์โปรแกรม ส่วน Windows จะดาวน์โหลดอัตโนมัติเมื่อรันครั้งแรก ไบนารี macOS ไม่ได้ลงนาม: หลังแตกไฟล์ให้รัน `xattr -dr com.apple.quarantine fushi-subs/` หนึ่งครั้ง

## เริ่มต้นอย่างรวดเร็ว

```bash
dart pub get

# ดาวน์โหลดโมเดล (ภาษาอังกฤษ int8 ขนาดราว 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# ถอดเสียง คำบรรยายจะออกทาง stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# หรือเปิดเซิร์ฟเวอร์แล้วลากไฟล์ไปวางที่ http://127.0.0.1:8642 ในเบราว์เซอร์
dart run packages/asr_cli/bin/asr.dart serve
```

CLI ยังทำหน้าที่เป็นไคลเอนต์บาง ๆ ส่งงานไปให้เซิร์ฟเวอร์ระยะไกลได้ด้วย:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### สิ่งที่ต้องมีก่อน

| สิ่งที่ต้องพึ่งพา | หมายเหตุ |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — ต่ำกว่านั้น `GetApi(22)` จะคืนค่า nullptr ตัวที่ติดตั้งไว้เก่ากว่านี้จึงใช้ไม่ได้แม้จะมีอยู่ก็ตาม) ลำดับการค้นหา: ตัวแปรสภาพแวดล้อม `ASR_ONNXRUNTIME_LIB` → สำเนาที่ระบบจัดการและดึงมาเมื่อจำเป็น → ข้าง ๆ ไฟล์สั่งการ → พาธค้นหาของระบบ **บน Windows ระบบจะดาวน์โหลดเวอร์ชันที่ใช้งานได้ให้อัตโนมัติเมื่อหาไม่เจอ** (`Microsoft.ML.OnnxRuntime.DirectML` จาก NuGet ขนาด 17.9 MB ตรึงด้วย sha256 ลงไว้ที่ `<data root>/asr_runtime/`) ที่เลือกบิลด์ DirectML แทน GitHub release ที่รองรับเฉพาะ CPU ก็เพราะไม่อย่างนั้นการเร่งความเร็วด้วย GPU จะหายไปเงียบ ๆ ส่วน `DirectML.dll` เองมาจากคอมโพเนนต์ของระบบ Windows และยังต้องมี Microsoft Visual C++ Redistributable ด้วย บน macOS ให้ใช้ `script/bootstrap_macos.sh` บน Linux ให้ใช้ตัวจัดการแพ็กเกจของดิสทริบิวชันคุณ |
| **ffmpeg** | ถอดรหัสไฟล์เสียง/วิดีโอใด ๆ ให้เป็น PCM โมโน 16 kHz ลำดับการค้นหา: `ASR_FFMPEG` → ข้าง ๆ ไฟล์สั่งการ → `PATH` ส่วน `ffprobe` เป็นตัวเลือกเสริม (ถ้าไม่มีจะไม่รู้ความยาวรวม เปอร์เซ็นต์ความคืบหน้าจึงไม่แม่นยำ) |

ตัวแปรสภาพแวดล้อมอื่น ๆ: `ASR_DATA_DIR` (ไดเรกทอรีรากของโมเดลและงาน) และ
`ASR_MODELS_MANIFEST` (manifest โมเดลของคุณเอง)

บน macOS คำสั่ง `transcribe --coreml` หรือ `serve --coreml` จะเปิดใช้ตัวเข้ารหัส CoreML FP32
อย่างชัดเจน โมเดลภาษาญี่ปุ่นตัวปัจจุบันวัดแล้วช้ากว่า INT8 บน CPU โหมดอัตโนมัติจึงยังเลือก CPU อยู่
วิธีใช้ หลักฐานว่าโอเปอเรเตอร์ทำงานจริง และผลเปรียบเทียบสามทาง อยู่ใน
[docs/MACOS_COREML.md](../MACOS_COREML.md)

## ใส่โมเดลของคุณเอง

```bash
fushi-subs models export-manifest -o models.json   # export manifest ในตัวออกมาเป็นเทมเพลต
# หลังแก้ไขเสร็จแล้ว
asr --models models.json transcribe -l hi hindi.mp3
```

manifest จะถูกรวมเข้ากับตารางในตัวโดยยึดตาม `id` และวางแพ็กของคุณไว้ก่อน — `id` ที่ซ้ำกันจะ
ทับตัวในตัว และถ้าเป็นภาษาเดียวกันของคุณจะชนะ แพ็กที่เล็กที่สุดเท่าที่เป็นไปได้ต้องการเพียง
`id` / `languages` / `files`:

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

ฟิลด์ที่เหลือมีค่าเริ่มต้นให้อยู่แล้ว (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`) **แพ็กแบบ CTC ต้องระบุ `blankToken` อย่างชัดเจน** —
เพราะไม่มีค่าเริ่มต้นที่ทุกฝ่ายเห็นตรงกัน และถ้าเดาผิดข้อความถอดเสียงทั้งชุดจะเพี้ยนหมด

## HTTP API

| ปลายทาง | หมายเหตุ |
|---|---|
| `GET /` | เว็บ UI (ไฟล์เดียวจบ ไม่มีทรัพยากรภายนอก ใช้งานออฟไลน์ในเครือข่ายภายในได้) |
| `GET /v1/health` | ตรวจสอบว่ายังทำงานอยู่ ไม่ต้องใช้โทเคน |
| `GET /v1/models` | บอกว่ารู้จักภาษาและแพ็กโมเดลใดบ้าง |
| `POST /v1/transcribe?language=ja&format=srt` | เนื้อความคำขอคือไบต์ของไฟล์เสียง หรือเป็น multipart ที่มีไฟล์ `audio` และ `epub` ผลลัพธ์เป็น NDJSON แบบสตรีม หนึ่งเหตุการณ์ความคืบหน้าต่อหนึ่งบรรทัด โดยบรรทัดสุดท้ายเป็น `result`, `cancelled` หรือ `error` |
| `POST /v1/retime?language=ja&format=srt` | ปรับเวลาคำบรรยายใหม่: อัปโหลด `audio` (ไฟล์เสียงหรือวิดีโอ) และ `subtitle` (SRT/VTT แบบ UTF-8 ไม่เกิน 8 MiB) เป็น multipart ข้อความคำบรรยายและจำนวน cue จะคงเดิม ส่วนเวลาจะถูกปรับเทียบใหม่กับเสียงพูด และคืนค่าเป็น NDJSON เช่นกัน |

เมื่อกำหนด `--token` ไว้ คำขอต้องแนบ `Authorization: Bearer <token>` มาด้วย

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

การปรับเวลาใหม่รองรับพารามิเตอร์ `engine`, `filename` และ `jobId` เหมือนกับการถอดเสียง และรองรับ
ผลลัพธ์แบบ SRT, VTT และ JSON โดย `result.text` คือคำบรรยายที่ปรับเทียบแล้ว ส่วน `rawText` คือ
ผลดิบจากการรู้จำเสียง ขณะที่ `retiming` จะรายงานว่ามี cue กี่รายการที่จับคู่ได้ตรง ๆ กี่รายการที่
ประมาณค่าเชิงเส้น และกี่รายการที่คงเวลาเดิมไว้ พร้อมอัตราการจับคู่ ค่าเลื่อนเวลา และคำเตือน
คุณจึงตรวจดูส่วนที่ไม่พบจุดยึดของเสียงพูดที่เชื่อถือได้ ชื่อผู้พูดที่นำหน้าและเสียงประกอบในวงเล็บ
ในคำบรรยายรายการทีวีญี่ปุ่นจะถูกละเลยเฉพาะตอนจับคู่เท่านั้น ข้อความที่ส่งออกยังคงของเดิมไว้
ในจุดที่คำบรรยายกับการแบ่งส่วนของ ASR ไม่ตรงกัน สามารถใช้ขอบเขตเสียงพูดอิสระหลายจุดมาประมาณ
ค่าเลื่อนเวลาหรือค่าดริฟต์รายส่วนได้ ส่วนความแตกต่างระหว่างเวอร์ชัน เช่น เพลงเปิดและช่วงโฆษณา
จะจัดการแยกต่างหาก UI จะแยกจำนวน cue ที่ปรับเทียบแล้วออกจากการจับคู่ทั้งประโยคและจากค่าประมาณ
เพื่อไม่ให้เข้าใจผิดว่าอัตราการจับคู่ทั้งประโยคคือความครอบคลุมของการปรับเทียบ

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**ตัวชี้ขาดว่าสำเร็จหรือไม่คือมีบรรทัด `result` ส่งมาหรือเปล่า ไม่ใช่รหัสสถานะ HTTP**: เมื่อ
การตอบกลับเริ่มสตรีมออกไปแล้วก็แก้รหัสสถานะไม่ได้อีก ความล้มเหลวจึงส่งกลับได้เพียงในรูปของ
บรรทัดสุดท้ายเท่านั้น

## โครงสร้างแพ็กเกจ

| แพ็กเกจ | เนื้อหา | พึ่งพา |
|---|---|---|
| `fushi_asr_core` | แกนถอดเสียงที่เป็น Dart ล้วน: การแบ่งส่วนด้วย VAD, fbank, กราฟ RNN-T greedy Loop / การถอดรหัส CTC, การรวมชุดและแบ่งถัง, การแปลงกราฟเป็น fp16, manifest โมเดลและการดาวน์โหลด, การส่งออก SRT **ไม่มี Flutter ไม่มี dart:ffi ไม่มีแบ็กเอนด์ ONNX ผูกมาด้วย** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | แบ็กเอนด์ ONNX Runtime แบบ dart:ffi (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | การจัดแนว EPUB / ข้อความ ↔ เสียง: การจับคู่ระดับประโยคด้วย Dice (รวมถึงแทร็กคำอ่านแบบ ruby), การเติมช่องว่างระหว่างจุดยึด, การตัด cue ใหม่ตามขอบเขตประโยค | `fushi_asr_core` |
| `fushi_asr` | ชั้นหน้าฉาก: `TranscribeRunner` ที่เรียกครั้งเดียวจบ พร้อมรูปแบบคำบรรยาย | สองตัวข้างบน |
| `fushi_asr_server` | เซิร์ฟเวอร์ HTTP และไคลเอนต์ พร้อมเว็บ UI | `fushi_asr` |
| `fushi_asr_cli` | บรรทัดคำสั่ง `asr` | `fushi_asr` `fushi_asr_server` `args` |

ประเด็นสำคัญของการแบ่งชั้นแบบนี้คือ **ชั้นอัลกอริทึมพึ่งพาอินเทอร์เฟซแคบ ๆ เพียงตัวเดียว**
(`OnnxSessionFactory.createSession`) โฮสต์ที่เป็น Flutter จะฉีดแบ็กเอนด์ปลั๊กอินของตัวเองเข้าไป
ส่วนเซิร์ฟเวอร์ฉีดแบ็กเอนด์ FFI แล้วอัลกอริทึมชุดเดียวกันก็ทำงานได้ทั้งสองฝั่ง

## การพัฒนา

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 tests
cd packages/asr_onnx_ffi && dart test    # 15 tests, needs a real onnxruntime (the group skips without one)
cd packages/asr_align && dart test       # 15 tests
cd packages/asr && dart test             # 10 tests
cd packages/asr_server && dart test      # 10 tests
```

บน macOS ที่ใช้ Apple Silicon สคริปต์ `./script/bootstrap_macos.sh` จะติดตั้ง Dart SDK, FFmpeg และ
ONNX Runtime เฉพาะภายในโปรเจกต์ หลังจากนั้น `./script/check.sh` จะรันการตรวจสอบทั้งชุด
บันทึกเกี่ยวกับสภาพแวดล้อมและข้อแนะนำเรื่องขอบเขตของโฮสต์ macOS อยู่ใน
[docs/MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md)

การสร้าง ORT FFI bindings ใหม่ (จำเป็นเฉพาะตอนเปลี่ยนเวอร์ชัน ORT เท่านั้น โค้ดที่สร้างขึ้นถูก
คอมมิตไว้แล้ว ผู้ใช้ทั่วไปจึงไม่ต้องมี LLVM):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

การวินิจฉัยปัญหา: `ASR_TRACE_SHUTDOWN=1` จะเขียนทุกขั้นตอนของการปิดกระบวนการถอดเสียงลง stderr
(ปิด session → ปิดสะพาน PCM → ข้อความแจ้งการออก → เซิร์ฟเวอร์เขียนการตอบกลับ) สำหรับดีบักอาการ
"ทำงานเสร็จแล้วแต่ค้าง"

แผนการพัฒนาและการชั่งน้ำหนักในการออกแบบอยู่ใน [docs/PLAN.md](../PLAN.md)

## สัญญาอนุญาต

GPL-3.0 ดูที่ [LICENSE](../../LICENSE) ส่วนไฟล์เฮดเดอร์ใต้ `third_party/onnxruntime/` มาจาก ONNX
Runtime (MIT) และยังคงสัญญาอนุญาตเดิมไว้
