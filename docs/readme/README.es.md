<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · **Español** · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

Reconocimiento de voz multilingüe que genera subtítulos. **Un núcleo escrito íntegramente en Dart con
un backend ONNX intercambiable**, que se ejecuta en el servidor y se controla desde la CLI o desde la
interfaz web incorporada.

Extraído de [Fushi](https://github.com/hajisensai/Fushi) a un repositorio independiente
(`hajisensai/fushi-subtitles`), del que Fushi pasa a depender. El ejecutable de línea de comandos se
llama `fushi-subs`.

## Qué hace

- **17 idiomas incorporados**: japonés / inglés / chino / cantonés / coreano / ruso / vietnamita /
  tailandés utilizan cada uno su propio zipformer RNN-T; alemán / español / francés / italiano /
  neerlandés / portugués / turco / indonesio / árabe se apoyan en Omnilingual ASR 1B CTC de Meta.
- **Aporta tus propios modelos**: el manifiesto incorporado es solo un valor por defecto. Basta un
  único archivo JSON para conectar tus propias exportaciones zipformer / CTC, incluidos idiomas
  fuera de los 17 incorporados (`fushi-subs models export-manifest` escribe una plantilla para
  editar).
- **Tres formatos de salida**: SRT / WebVTT / JSON.
- **Tres formas de manejarlo**: línea de comandos, API HTTP y la interfaz web que incluye el
  servidor.
- **Alineación de audiolibros** (`fushi_asr_align`): coteja frase por frase los cues de subtítulo
  con el texto del cuerpo del EPUB, recupera los pasajes omitidos rellenando el hueco entre anclas y
  después vuelve a dividir los cues en los límites de frase usando los tiempos de emisión por token;
  los casos de «un cue que abarca varias frases» pasaron de 18 a 0 en la medición.

## Instalación

Los archivos precompilados están en la [página de Releases](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel) y Windows (x64 / arm64). Descomprime, pon `fushi-subs` en tu `PATH`, instala ffmpeg (ver «Requisitos previos») y ejecuta `fushi-subs doctor`: informa si ONNX Runtime y ffmpeg están disponibles. Los archivos de Linux y macOS incluyen ONNX Runtime junto al ejecutable; en Windows se descarga automáticamente en la primera ejecución. Los binarios de macOS no están firmados: ejecuta una vez `xattr -dr com.apple.quarantine fushi-subs/` tras descomprimir.

## Inicio rápido

```bash
dart pub get

# Descargar un modelo (inglés int8, unos 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Transcribir; los subtítulos salen por stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# O arrancar el servidor y soltar archivos en http://127.0.0.1:8642 desde el navegador
dart run packages/asr_cli/bin/asr.dart serve
```

La CLI también puede actuar como cliente ligero y delegar el trabajo en un servidor remoto:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Requisitos previos

| Dependencia | Notas |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+**: por debajo de esa versión `GetApi(22)` devuelve nullptr, así que una instalación más antigua resulta inservible aunque esté presente). Orden de búsqueda: la variable de entorno `ASR_ONNXRUNTIME_LIB` → la copia gestionada que se descarga bajo demanda → junto al ejecutable → la ruta de búsqueda del sistema. **En Windows se descarga automáticamente una versión utilizable cuando no se encuentra ninguna** (el paquete `Microsoft.ML.OnnxRuntime.DirectML` de NuGet, 17,9 MB, fijado por sha256, que se instala en `<data root>/asr_runtime/`); se usa la compilación con DirectML y no la versión publicada en GitHub solo para CPU, porque de lo contrario la aceleración por GPU desaparecería en silencio. La propia `DirectML.dll` proviene del componente del sistema Windows. También hace falta el Microsoft Visual C++ Redistributable. En macOS usa `script/bootstrap_macos.sh`; en Linux, el gestor de paquetes de tu distribución. |
| **ffmpeg** | Decodifica cualquier audio o vídeo a PCM mono de 16 kHz. Orden de búsqueda: `ASR_FFMPEG` → junto al ejecutable → `PATH`. `ffprobe` es opcional (sin él se desconoce la duración total, por lo que el porcentaje de progreso es impreciso). |

Otras variables de entorno: `ASR_DATA_DIR` (raíz para los modelos y los directorios de trabajos) y
`ASR_MODELS_MANIFEST` (tu propio manifiesto de modelos).

En macOS, `transcribe --coreml` o `serve --coreml` habilitan explícitamente el codificador CoreML
FP32. El modelo japonés actual mide más lento que INT8 en CPU, así que el modo automático sigue
eligiendo la CPU. El uso, la prueba de la ejecución de los operadores y los benchmarks a tres bandas
están en [docs/MACOS_COREML.md](../MACOS_COREML.md).

## Aporta tus propios modelos

```bash
fushi-subs models export-manifest -o models.json   # exportar el manifiesto incorporado como plantilla
# después de editarlo
asr --models models.json transcribe -l hi hindi.mp3
```

El manifiesto se fusiona con la tabla incorporada por `id`, colocando primero tus packs: un mismo
`id` sobrescribe el incorporado y, para un mismo idioma, gana el tuyo. El pack más pequeño posible
solo necesita `id` / `languages` / `files`:

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

El resto de los campos tienen valores por defecto (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **Un pack CTC debe indicar `blankToken` de forma
explícita**: no hay un valor por defecto consensuado, y equivocarse al adivinarlo destroza la
transcripción entera.

## API HTTP

| Endpoint | Notas |
|---|---|
| `GET /` | La interfaz web (un único archivo sin recursos externos, utilizable sin conexión en una LAN) |
| `GET /v1/health` | Sonda de disponibilidad, no requiere token |
| `GET /v1/models` | Qué idiomas y packs de modelos se conocen |
| `POST /v1/transcribe?language=ja&format=srt` | El cuerpo de la petición son los bytes de audio, o un cuerpo multipart con un archivo `audio` y otro `epub`. La respuesta es NDJSON en streaming, un evento de progreso por línea, con `result`, `cancelled` o `error` como última línea |
| `POST /v1/retime?language=ja&format=srt` | Resincronización de subtítulos: sube `audio` (audio o vídeo) y `subtitle` (SRT/VTT en UTF-8, como máximo 8 MiB) como multipart. Se conservan el texto del subtítulo y el número de cues mientras se recalibran los tiempos contra la voz; también devuelve NDJSON |

Cuando se define `--token`, las peticiones deben llevar `Authorization: Bearer <token>`.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

La resincronización admite los mismos parámetros `engine`, `filename` y `jobId` que la
transcripción, además de salida en SRT, VTT y JSON. `result.text` es el subtítulo recalibrado y
`rawText` es la salida en bruto del reconocimiento de voz; `retiming` informa de cuántos cues se
emparejaron directamente, se interpolaron o se dejaron con sus tiempos originales, junto con la tasa
de coincidencia, el desfase temporal y las advertencias, de modo que puedas revisar las partes donde
no se halló un ancla de voz fiable. Los nombres de hablante al principio y los efectos de sonido
entre corchetes de los subtítulos de televisión japonesa se ignoran únicamente durante el cotejo; el
texto exportado conserva el original. Allí donde los subtítulos y la segmentación del ASR no
coinciden, se pueden usar varios límites de voz independientes para estimar un desfase temporal o
una deriva por segmento; las diferencias entre versiones, como cabeceras y anuncios, se tratan
aparte. La interfaz distingue el número de cues recalibrados de las coincidencias de frase completa
y de las estimaciones, para que una tasa de coincidencia de frase completa no se confunda con la
cobertura de la recalibración.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**El éxito lo decide si llegó una línea `result`, no el código de estado HTTP**: una vez que la
respuesta empieza a transmitirse, el código de estado ya no puede cambiarse, así que un fallo solo
puede comunicarse como la última línea.

## Estructura de paquetes

| Paquete | Contenido | Depende de |
|---|---|---|
| `fushi_asr_core` | El núcleo de transcripción en Dart puro: segmentación VAD, fbank, grafo Loop greedy de RNN-T / decodificación CTC, batching y bucketing, conversión del grafo a fp16, manifiesto de modelos y descargas, salida SRT. **Sin Flutter, sin dart:ffi, sin backend ONNX incluido** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | El backend dart:ffi de ONNX Runtime (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | Alineación EPUB / texto ↔ audio: coincidencia Dice a nivel de frase (incluida una pista de lecturas ruby), relleno de huecos entre anclas, redivisión de cues en los límites de frase | `fushi_asr_core` |
| `fushi_asr` | La fachada: un `TranscribeRunner` de una sola llamada más los formatos de subtítulo | los dos anteriores |
| `fushi_asr_server` | El servidor y el cliente HTTP más la interfaz web | `fushi_asr` |
| `fushi_asr_cli` | La línea de comandos `asr` | `fushi_asr` `fushi_asr_server` `args` |

El sentido de esta estratificación es que **la capa de algoritmos depende de una sola interfaz
estrecha** (`OnnxSessionFactory.createSession`). Un host Flutter inyecta su propio backend de
plugin, el servidor inyecta el backend FFI, y los mismos algoritmos se ejecutan en ambos.

## Desarrollo

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 pruebas
cd packages/asr_onnx_ffi && dart test    # 15 pruebas, necesita un onnxruntime real (el grupo se omite si no lo hay)
cd packages/asr_align && dart test       # 15 pruebas
cd packages/asr && dart test             # 10 pruebas
cd packages/asr_server && dart test      # 10 pruebas
```

En macOS con Apple Silicon, `./script/bootstrap_macos.sh` instala un SDK de Dart local al proyecto,
FFmpeg y ONNX Runtime, tras lo cual `./script/check.sh` ejecuta la comprobación completa. Las notas
sobre el entorno y las recomendaciones sobre los límites del host macOS están en
[docs/MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md).

Regeneración de los bindings FFI de ORT (solo necesaria al cambiar la versión de ORT; el código
generado está en el repositorio, así que los usuarios corrientes no necesitan LLVM):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Diagnóstico: `ASR_TRACE_SHUTDOWN=1` escribe en stderr cada paso del cierre de la transcripción
(cerrar la sesión → cerrar el puente PCM → mensaje de salida → el servidor escribe la respuesta),
para depurar los casos de «termina pero se queda colgado».

El plan de implementación y las concesiones de diseño están en [docs/PLAN.md](../PLAN.md).

## Licencia

GPL-3.0, véase [LICENSE](../../LICENSE). Las cabeceras bajo `third_party/onnxruntime/` proceden de
ONNX Runtime (MIT) y conservan su licencia original.
