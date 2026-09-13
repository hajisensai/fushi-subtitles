<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · **Tiếng Việt** · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

Nhận dạng giọng nói đa ngôn ngữ, đầu ra là phụ đề. **Một lõi thuần Dart với backend ONNX có thể thay
thế**, chạy phía máy chủ và được điều khiển từ CLI hoặc giao diện web tích hợp sẵn.

Được tách ra từ [Fushi](https://github.com/hajisensai/Fushi) thành một kho mã độc lập
(`hajisensai/fushi-subtitles`), và Fushi nay phụ thuộc vào nó. Tệp thực thi dòng lệnh có tên là
`fushi-subs`.

## Nó làm được gì

- **17 ngôn ngữ tích hợp sẵn**: tiếng Nhật / Anh / Trung / Quảng Đông / Hàn / Nga / Việt / Thái, mỗi
  ngôn ngữ chạy zipformer RNN-T riêng; tiếng Đức / Tây Ban Nha / Pháp / Ý / Hà Lan / Bồ Đào Nha /
  Thổ Nhĩ Kỳ / Indonesia / Ả Rập chạy trên Omnilingual ASR 1B CTC của Meta.
- **Tự mang mô hình của bạn**: manifest tích hợp chỉ là mặc định. Chỉ cần một tệp JSON là đủ để gắn
  vào các bản xuất zipformer / CTC của riêng bạn, kể cả những ngôn ngữ nằm ngoài 17 ngôn ngữ tích
  hợp (`fushi-subs models export-manifest` sẽ ghi ra một mẫu để bạn chỉnh sửa).
- **Ba định dạng đầu ra**: SRT / WebVTT / JSON.
- **Ba cách điều khiển**: dòng lệnh, HTTP API và giao diện web đi kèm máy chủ.
- **Căn chỉnh sách nói** (`fushi_asr_align`): đối chiếu từng câu giữa các khối phụ đề và phần thân
  văn bản EPUB, khôi phục những đoạn bị bỏ sót bằng cách lấp đầy khoảng giữa các mốc neo, rồi cắt
  lại các khối theo ranh giới câu dựa trên thời điểm phát sinh của từng token — "một khối phủ nhiều
  câu" đo được là 18 → 0.

## Cài đặt

Bản dựng sẵn có ở [trang Releases](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel) và Windows (x64 / arm64). Giải nén, đặt `fushi-subs` vào `PATH`, cài ffmpeg (xem «Yêu cầu»), rồi chạy `fushi-subs doctor` — nó cho biết ONNX Runtime và ffmpeg có dùng được không. Gói Linux / macOS kèm sẵn ONNX Runtime cạnh file thực thi; trên Windows nó được tải tự động ở lần chạy đầu. Binary macOS chưa ký: sau khi giải nén chạy một lần `xattr -dr com.apple.quarantine fushi-subs/`.

## Bắt đầu nhanh

```bash
dart pub get

# Tải một mô hình (tiếng Anh int8, khoảng 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Chuyển thành văn bản, phụ đề xuất ra stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# Hoặc khởi động máy chủ rồi thả tệp vào http://127.0.0.1:8642 trên trình duyệt
dart run packages/asr_cli/bin/asr.dart serve
```

CLI cũng có thể đóng vai trò một client mỏng và giao việc cho máy chủ từ xa:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Yêu cầu tiên quyết

| Phụ thuộc | Ghi chú |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — thấp hơn thì `GetApi(22)` trả về nullptr, nên bản cài cũ là không dùng được dù đã có sẵn). Thứ tự tìm kiếm: biến môi trường `ASR_ONNXRUNTIME_LIB` → bản sao được quản lý, tải về khi cần → cạnh tệp thực thi → đường dẫn tìm kiếm của hệ thống. **Trên Windows, nếu không tìm thấy bản nào thì một phiên bản dùng được sẽ tự động được tải về** (`Microsoft.ML.OnnxRuntime.DirectML` từ NuGet, 17.9 MB, ghim theo sha256, đặt vào `<data root>/asr_runtime/`); bản dựng DirectML được dùng thay cho bản phát hành GitHub chỉ có CPU, nếu không thì tăng tốc GPU sẽ biến mất một cách âm thầm. Bản thân `DirectML.dll` đến từ thành phần hệ thống của Windows. Ngoài ra còn cần Microsoft Visual C++ Redistributable. Trên macOS hãy dùng `script/bootstrap_macos.sh`; trên Linux hãy dùng trình quản lý gói của bản phân phối. |
| **ffmpeg** | Giải mã âm thanh/video bất kỳ thành PCM mono 16 kHz. Thứ tự tìm kiếm: `ASR_FFMPEG` → cạnh tệp thực thi → `PATH`. `ffprobe` là tùy chọn (không có nó thì không biết tổng thời lượng, nên phần trăm tiến độ sẽ không chính xác). |

Các biến môi trường khác: `ASR_DATA_DIR` (thư mục gốc cho mô hình và thư mục công việc) và
`ASR_MODELS_MANIFEST` (manifest mô hình của riêng bạn).

Trên macOS, `transcribe --coreml` hoặc `serve --coreml` bật tường minh bộ mã hóa CoreML FP32. Mô hình
tiếng Nhật hiện tại đo được là chậm hơn INT8 trên CPU, nên chế độ tự động vẫn chọn CPU. Cách dùng,
bằng chứng các toán tử thực sự chạy và kết quả đo ba chiều nằm trong
[../MACOS_COREML.md](../MACOS_COREML.md).

## Tự mang mô hình của bạn

```bash
fushi-subs models export-manifest -o models.json   # xuất manifest tích hợp làm mẫu
# sau khi chỉnh sửa nó
asr --models models.json transcribe -l hi hindi.mp3
```

Manifest được hợp nhất với bảng tích hợp theo `id`, các gói của bạn được đặt lên trước — cùng một
`id` sẽ ghi đè gói tích hợp, và với cùng một ngôn ngữ thì gói của bạn thắng. Gói nhỏ nhất có thể chỉ
cần `id` / `languages` / `files`:

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

Các trường còn lại đều có giá trị mặc định (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **Gói CTC bắt buộc phải khai báo `blankToken` một
cách tường minh** — không có giá trị mặc định nào được thống nhất, và đoán sai sẽ làm hỏng toàn bộ
bản ghi.

## HTTP API

| Điểm cuối | Ghi chú |
|---|---|
| `GET /` | Giao diện web (một tệp duy nhất, không có tài nguyên ngoài, dùng được ngoại tuyến trong mạng LAN) |
| `GET /v1/health` | Thăm dò tình trạng sống, không cần token |
| `GET /v1/models` | Những ngôn ngữ và gói mô hình đã biết |
| `POST /v1/transcribe?language=ja&format=srt` | Thân yêu cầu là các byte âm thanh, hoặc một thân multipart gồm tệp `audio` và tệp `epub`. Phản hồi là NDJSON dạng luồng, mỗi dòng một sự kiện tiến độ, với dòng cuối là `result`, `cancelled` hoặc `error` |
| `POST /v1/retime?language=ja&format=srt` | Căn lại thời gian phụ đề: tải lên dạng multipart gồm `audio` (âm thanh hoặc video) và `subtitle` (SRT/VTT mã UTF-8, tối đa 8 MiB). Nội dung phụ đề và số khối được giữ nguyên trong khi thời gian được hiệu chỉnh lại theo giọng nói; cũng trả về NDJSON |

Khi đặt `--token`, các yêu cầu phải mang theo `Authorization: Bearer <token>`.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

Việc căn lại thời gian hỗ trợ cùng các tham số `engine`, `filename` và `jobId` như khi chuyển thành
văn bản, cộng thêm đầu ra SRT, VTT và JSON. `result.text` là phụ đề đã hiệu chỉnh còn `rawText` là
kết quả nhận dạng giọng nói thô; `retiming` cho biết có bao nhiêu khối khớp trực tiếp, bao nhiêu được
nội suy và bao nhiêu giữ nguyên thời gian ban đầu, kèm theo tỷ lệ khớp, độ lệch thời gian và các cảnh
báo, để bạn có thể xem xét những phần không tìm được mốc neo giọng nói đáng tin cậy. Tên người nói ở
đầu dòng và hiệu ứng âm thanh trong ngoặc trong phụ đề truyền hình Nhật Bản chỉ bị bỏ qua khi đối
chiếu; văn bản xuất ra vẫn giữ nguyên bản gốc. Ở những chỗ phụ đề và cách phân đoạn của ASR không
thống nhất, có thể dùng nhiều ranh giới giọng nói độc lập để ước lượng độ lệch hoặc độ trôi thời gian
theo từng đoạn; những khác biệt giữa các phiên bản như đoạn mở đầu và quảng cáo được xử lý riêng.
Giao diện phân biệt số khối đã hiệu chỉnh với số câu khớp trọn vẹn và với các ước lượng, nên tỷ lệ
khớp trọn câu không bị nhầm thành mức độ bao phủ của việc hiệu chỉnh.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**Thành công được quyết định bởi việc dòng `result` có đến hay không, chứ không phải bởi mã trạng
thái HTTP**: một khi phản hồi đã bắt đầu truyền theo luồng thì mã trạng thái không còn thay đổi được
nữa, nên lỗi chỉ có thể được gửi về ở dòng cuối cùng.

## Bố cục các gói

| Gói | Nội dung | Phụ thuộc vào |
|---|---|---|
| `fushi_asr_core` | Lõi chuyển giọng nói thành văn bản thuần Dart: phân đoạn VAD, fbank, đồ thị Loop tham lam của RNN-T / giải mã CTC, gom lô và chia nhóm, chuyển đổi đồ thị sang fp16, manifest mô hình và tải xuống, xuất SRT. **Không Flutter, không dart:ffi, không backend ONNX đi kèm** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | Backend ONNX Runtime bằng dart:ffi (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | Căn chỉnh EPUB / văn bản ↔ âm thanh: đối chiếu Dice ở mức câu (gồm cả một dải âm đọc ruby), lấp đầy khoảng trống giữa các mốc neo, cắt lại khối theo ranh giới câu | `fushi_asr_core` |
| `fushi_asr` | Lớp mặt tiền: một `TranscribeRunner` gọi một lần là xong, cùng các định dạng phụ đề | hai gói ở trên |
| `fushi_asr_server` | Máy chủ và client HTTP cùng giao diện web | `fushi_asr` |
| `fushi_asr_cli` | Dòng lệnh `asr` | `fushi_asr` `fushi_asr_server` `args` |

Ý nghĩa của việc phân lớp này là **lớp thuật toán chỉ phụ thuộc vào một giao diện hẹp duy nhất**
(`OnnxSessionFactory.createSession`). Ứng dụng Flutter tiêm backend plugin của riêng nó, máy chủ tiêm
backend FFI, và cùng một bộ thuật toán chạy trên cả hai.

## Phát triển

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 bài kiểm thử
cd packages/asr_onnx_ffi && dart test    # 15 bài kiểm thử, cần onnxruntime thật (không có thì nhóm này bị bỏ qua)
cd packages/asr_align && dart test       # 15 bài kiểm thử
cd packages/asr && dart test             # 10 bài kiểm thử
cd packages/asr_server && dart test      # 10 bài kiểm thử
```

Trên macOS chạy Apple Silicon, `./script/bootstrap_macos.sh` sẽ cài Dart SDK, FFmpeg và ONNX Runtime
cục bộ cho dự án, sau đó `./script/check.sh` chạy toàn bộ phần kiểm tra. Ghi chú về môi trường và lời
khuyên về ranh giới cho máy macOS nằm trong [../MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md).

Tạo lại các binding FFI của ORT (chỉ cần khi đổi phiên bản ORT; mã sinh ra đã được commit nên người
dùng thông thường không cần LLVM):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Chẩn đoán: `ASR_TRACE_SHUTDOWN=1` ghi ra stderr từng bước của quá trình dọn dẹp sau khi chuyển giọng
nói thành văn bản (đóng phiên → đóng cầu nối PCM → thông điệp thoát → máy chủ ghi phản hồi), để gỡ
lỗi tình huống "xong rồi mà vẫn treo".

Kế hoạch triển khai và các đánh đổi thiết kế nằm trong [../PLAN.md](../PLAN.md).

## Giấy phép

GPL-3.0, xem [LICENSE](../../LICENSE). Các tệp header trong `third_party/onnxruntime/` đến từ ONNX
Runtime (MIT) và giữ nguyên giấy phép gốc.
