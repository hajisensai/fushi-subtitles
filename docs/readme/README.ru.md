<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · **Русский** · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

Многоязычное распознавание речи, на выходе — субтитры. **Ядро на чистом Dart со сменным ONNX-бэкендом**,
работает на стороне сервера и управляется из CLI или из встроенного веб-интерфейса.

Выделено из [Fushi](https://github.com/hajisensai/Fushi) в отдельный репозиторий
(`hajisensai/fushi-subtitles`), от которого Fushi теперь зависит. Исполняемый файл командной строки
называется `fushi-subs`.

## Что он умеет

- **17 встроенных языков**: японский / английский / китайский / кантонский / корейский / русский /
  вьетнамский / тайский — у каждого свой zipformer RNN-T; немецкий / испанский / французский /
  итальянский / нидерландский / португальский / турецкий / индонезийский / арабский работают на
  Omnilingual ASR 1B CTC от Meta.
- **Свои собственные модели**: встроенный манифест — всего лишь значение по умолчанию. Достаточно
  одного JSON-файла, чтобы подключить свои экспорты zipformer / CTC, в том числе для языков за
  пределами встроенных 17 (`fushi-subs models export-manifest` выпишет шаблон для правки).
- **Три формата вывода**: SRT / WebVTT / JSON.
- **Три способа управления**: командная строка, HTTP API и веб-интерфейс, который поставляется вместе
  с сервером.
- **Выравнивание аудиокниг** (`fushi_asr_align`): пофразно сопоставляет реплики субтитров с текстом
  EPUB, восстанавливает пропущенные фрагменты, дозаполняя промежутки между якорями, а затем заново
  режет реплики по границам предложений, опираясь на время появления каждого токена, — «одна реплика
  накрывает несколько предложений» измерено как 18 → 0.

## Установка

Готовые архивы лежат на [странице Releases](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel) и Windows (x64 / arm64). Распакуйте, положите `fushi-subs` в `PATH`, установите ffmpeg (см. «Требования») и запустите `fushi-subs doctor` — он покажет, доступны ли ONNX Runtime и ffmpeg. В архивах для Linux и macOS ONNX Runtime лежит рядом с исполняемым файлом; в Windows он скачивается автоматически при первом запуске. Бинарники для macOS не подписаны: после распаковки один раз выполните `xattr -dr com.apple.quarantine fushi-subs/`.

## Быстрый старт

```bash
dart pub get

# Скачать модель (английская int8, около 67 МБ)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Транскрибировать, субтитры уходят в stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# Или запустить сервер и перетащить файлы на http://127.0.0.1:8642 в браузере
dart run packages/asr_cli/bin/asr.dart serve
```

CLI также может работать как тонкий клиент и передавать работу удалённому серверу:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Требования

| Зависимость | Примечания |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — на более старых `GetApi(22)` возвращает nullptr, поэтому старая установка непригодна, даже если она есть). Порядок поиска: переменная окружения `ASR_ONNXRUNTIME_LIB` → управляемая копия, скачиваемая по требованию → рядом с исполняемым файлом → системные пути поиска. **В Windows пригодная версия скачивается автоматически, если ничего не найдено** (`Microsoft.ML.OnnxRuntime.DirectML` из NuGet, 17.9 МБ, закреплён по sha256, кладётся в `<data root>/asr_runtime/`); берётся сборка с DirectML, а не GitHub-релиз только для CPU, иначе GPU-ускорение молча исчезает. Сама `DirectML.dll` берётся из системного компонента Windows. Также требуется Microsoft Visual C++ Redistributable. На macOS используйте `script/bootstrap_macos.sh`; на Linux — пакетный менеджер вашего дистрибутива. |
| **ffmpeg** | Декодирует произвольное аудио/видео в 16 кГц моно PCM. Порядок поиска: `ASR_FFMPEG` → рядом с исполняемым файлом → `PATH`. `ffprobe` необязателен (без него общая длительность неизвестна, поэтому процент выполнения неточен). |

Другие переменные окружения: `ASR_DATA_DIR` (корень для моделей и каталогов заданий) и
`ASR_MODELS_MANIFEST` (ваш собственный манифест моделей).

На macOS `transcribe --coreml` или `serve --coreml` явно включает CoreML-энкодер FP32. Текущая
японская модель по замерам медленнее, чем INT8 на CPU, поэтому автоматический режим по-прежнему
выбирает CPU. Использование, подтверждение выполнения операторов и сравнение трёх вариантов — в
[../MACOS_COREML.md](../MACOS_COREML.md).

## Свои собственные модели

```bash
fushi-subs models export-manifest -o models.json   # экспортировать встроенный манифест как шаблон
# после его правки
asr --models models.json transcribe -l hi hindi.mp3
```

Манифест сливается со встроенной таблицей по `id`, ваши паки ставятся первыми — одинаковый `id`
перекрывает встроенный, а при совпадении языка выигрывает ваш. Минимально возможному паку нужны
только `id` / `languages` / `files`:

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

У остальных полей есть значения по умолчанию (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **Пак с CTC обязан указывать `blankToken` явно** —
общепринятого значения по умолчанию нет, а ошибка в нём испортит всю расшифровку.

## HTTP API

| Эндпоинт | Примечания |
|---|---|
| `GET /` | Веб-интерфейс (один файл без внешних ресурсов, работает офлайн в локальной сети) |
| `GET /v1/health` | Проверка живости, токен не нужен |
| `GET /v1/models` | Какие языки и паки моделей известны |
| `POST /v1/transcribe?language=ja&format=srt` | Тело запроса — байты аудио либо multipart-тело с файлами `audio` и `epub`. Ответ — потоковый NDJSON, по одному событию прогресса в строке, а последней строкой идёт `result`, `cancelled` или `error` |
| `POST /v1/retime?language=ja&format=srt` | Пересчёт таймингов субтитров: загрузите multipart-ом `audio` (аудио или видео) и `subtitle` (SRT/VTT в UTF-8, не больше 8 MiB). Текст субтитров и число реплик сохраняются, а тайминги перекалибруются по речи; тоже возвращает NDJSON |

Если задан `--token`, запросы должны нести `Authorization: Bearer <token>`.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

Пересчёт таймингов поддерживает те же параметры `engine`, `filename` и `jobId`, что и
транскрибирование, а также вывод в SRT, VTT и JSON. `result.text` — это перекалиброванные субтитры,
а `rawText` — сырой вывод распознавания речи; `retiming` сообщает, сколько реплик было сопоставлено
напрямую, сколько интерполировано и сколько осталось с исходными таймингами, вместе с долей
совпадений, смещением по времени и предупреждениями, так что можно посмотреть на участки, где
надёжного речевого якоря не нашлось. Ведущие имена говорящих и звуковые эффекты в скобках в японских
телевизионных субтитрах игнорируются только на этапе сопоставления; в экспортируемом тексте
сохраняется оригинал. Там, где субтитры и сегментация ASR расходятся, для оценки посегментного
смещения времени или дрейфа можно использовать несколько независимых речевых границ; различия версий
вроде заставок и рекламы обрабатываются отдельно. Интерфейс отличает число перекалиброванных реплик
от совпадений по целым предложениям и от оценок, чтобы долю совпадений по предложениям не приняли за
покрытие перекалибровки.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**Успех определяется тем, пришла ли строка `result`, а не HTTP-кодом ответа**: как только ответ начал
передаваться потоком, код статуса уже нельзя изменить, поэтому сообщить об ошибке можно только
последней строкой.

## Структура пакетов

| Пакет | Содержимое | Зависит от |
|---|---|---|
| `fushi_asr_core` | Ядро транскрибирования на чистом Dart: сегментация VAD, fbank, жадный Loop-граф RNN-T / декодирование CTC, батчинг и раскладка по корзинам, конвертация графа в fp16, манифест моделей и загрузки, вывод SRT. **Ни Flutter, ни dart:ffi, ни встроенного ONNX-бэкенда** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | Бэкенд ONNX Runtime на dart:ffi (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | Выравнивание EPUB / текста ↔ аудио: сопоставление по коэффициенту Дайса на уровне предложений (включая дорожку чтений ruby), дозаполнение промежутков между якорями, перерезка реплик по границам предложений | `fushi_asr_core` |
| `fushi_asr` | Фасад: `TranscribeRunner` в один вызов плюс форматы субтитров | два предыдущих |
| `fushi_asr_server` | HTTP-сервер и клиент плюс веб-интерфейс | `fushi_asr` |
| `fushi_asr_cli` | Командная строка `asr` | `fushi_asr` `fushi_asr_server` `args` |

Смысл такого разделения на слои в том, что **слой алгоритмов зависит только от одного узкого
интерфейса** (`OnnxSessionFactory.createSession`). Flutter-хост подставляет свой плагинный бэкенд,
сервер подставляет FFI-бэкенд, и одни и те же алгоритмы работают в обоих случаях.

## Разработка

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 тестов
cd packages/asr_onnx_ffi && dart test    # 15 тестов, нужен настоящий onnxruntime (без него группа пропускается)
cd packages/asr_align && dart test       # 15 тестов
cd packages/asr && dart test             # 10 тестов
cd packages/asr_server && dart test      # 10 тестов
```

На macOS с Apple Silicon `./script/bootstrap_macos.sh` установит локальные для проекта Dart SDK,
FFmpeg и ONNX Runtime, после чего `./script/check.sh` прогонит полную проверку. Замечания по
окружению и советы по границам для macOS-хоста — в [../MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md).

Перегенерация FFI-биндингов ORT (нужна только при смене версии ORT; сгенерированный код закоммичен,
поэтому обычным пользователям LLVM не нужен):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Диагностика: `ASR_TRACE_SHUTDOWN=1` пишет в stderr каждый шаг завершения транскрибирования (закрытие
сессии → закрытие PCM-моста → сообщение о выходе → сервер отправляет ответ) — для отладки ситуации
«всё закончилось, но висит».

План реализации и компромиссы проектирования — в [../PLAN.md](../PLAN.md).

## Лицензия

GPL-3.0, см. [LICENSE](../../LICENSE). Заголовочные файлы в `third_party/onnxruntime/` взяты из ONNX
Runtime (MIT) и сохраняют свою исходную лицензию.
