<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · **Deutsch** · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

Mehrsprachige Spracherkennung, die Untertitel erzeugt. **Ein reiner Dart-Kern mit austauschbarem
ONNX-Backend**, der serverseitig läuft und über die CLI oder die mitgelieferte Web-UI gesteuert wird.

Aus [Fushi](https://github.com/hajisensai/Fushi) in ein eigenständiges Repository
(`hajisensai/fushi-subtitles`) ausgelagert, das Fushi seinerseits als Abhängigkeit einbindet. Die
ausführbare Datei für die Kommandozeile heißt `fushi-subs`.

## Funktionsumfang

- **17 integrierte Sprachen**: Japanisch / Englisch / Chinesisch / Kantonesisch / Koreanisch /
  Russisch / Vietnamesisch / Thailändisch nutzen jeweils einen eigenen Zipformer-RNN-T; Deutsch /
  Spanisch / Französisch / Italienisch / Niederländisch / Portugiesisch / Türkisch / Indonesisch /
  Arabisch laufen über Metas Omnilingual ASR 1B CTC.
- **Eigene Modelle einbinden**: Das eingebaute Manifest ist lediglich eine Voreinstellung. Eine
  einzige JSON-Datei genügt, um eigene Zipformer-/CTC-Exporte einzuhängen – auch für Sprachen
  außerhalb der 17 integrierten (`fushi-subs models export-manifest` schreibt eine Vorlage zum
  Bearbeiten heraus).
- **Drei Ausgabeformate**: SRT / WebVTT / JSON.
- **Drei Bedienwege**: Kommandozeile, HTTP-API und die Web-UI, die der Server mitbringt.
- **Hörbuch-Ausrichtung** (`fushi_asr_align`): gleicht Untertitel-Cues Satz für Satz gegen den
  EPUB-Fließtext ab, holt übersprungene Passagen durch Auffüllen zwischen Ankern zurück und
  zerlegt Cues anschließend anhand der Emissionszeiten pro Token an Satzgrenzen neu – „ein Cue
  deckt mehrere Sätze ab“ ging messbar von 18 → 0 zurück.

## Installation

Vorgefertigte Archive gibt es auf der [Releases-Seite](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel) und Windows (x64 / arm64). Entpacken, `fushi-subs` in den `PATH` legen, ffmpeg installieren (siehe „Voraussetzungen“) und dann `fushi-subs doctor` ausführen – es meldet, ob ONNX Runtime und ffmpeg nutzbar sind. Die Linux- und macOS-Archive enthalten ONNX Runtime neben der ausführbaren Datei; unter Windows wird es beim ersten Start automatisch heruntergeladen. macOS-Binaries sind unsigniert: nach dem Entpacken einmal `xattr -dr com.apple.quarantine fushi-subs/` ausführen.

## Schnellstart

```bash
dart pub get

# Ein Modell herunterladen (Englisch int8, etwa 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Transkribieren, die Untertitel gehen nach stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# Oder den Server starten und Dateien im Browser auf http://127.0.0.1:8642 ablegen
dart run packages/asr_cli/bin/asr.dart serve
```

Die CLI kann auch als schlanker Client auftreten und die Arbeit an einen entfernten Server abgeben:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Voraussetzungen

| Abhängigkeit | Hinweise |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** – darunter liefert `GetApi(22)` nullptr, eine ältere Installation ist also selbst dann unbrauchbar, wenn sie vorhanden ist). Suchreihenfolge: Umgebungsvariable `ASR_ONNXRUNTIME_LIB` → die bei Bedarf geladene verwaltete Kopie → neben der ausführbaren Datei → der Systemsuchpfad. **Unter Windows wird automatisch eine brauchbare Version heruntergeladen, wenn keine gefunden wird** (NuGets `Microsoft.ML.OnnxRuntime.DirectML`, 17,9 MB, per sha256 fixiert, abgelegt unter `<data root>/asr_runtime/`); dabei kommt der DirectML-Build zum Einsatz und nicht das reine CPU-Release von GitHub, weil sonst die GPU-Beschleunigung stillschweigend wegfällt. `DirectML.dll` selbst stammt aus der Windows-Systemkomponente. Zusätzlich wird das Microsoft Visual C++ Redistributable benötigt. Unter macOS `script/bootstrap_macos.sh` verwenden; unter Linux den Paketmanager Ihrer Distribution. |
| **ffmpeg** | Dekodiert beliebige Audio-/Videodaten in 16-kHz-Mono-PCM. Suchreihenfolge: `ASR_FFMPEG` → neben der ausführbaren Datei → `PATH`. `ffprobe` ist optional (ohne das Werkzeug ist die Gesamtdauer unbekannt, die Fortschrittsanzeige in Prozent also ungenau). |

Weitere Umgebungsvariablen: `ASR_DATA_DIR` (Wurzelverzeichnis für Modelle und Job-Verzeichnisse) und
`ASR_MODELS_MANIFEST` (Ihr eigenes Modellmanifest).

Unter macOS aktivieren `transcribe --coreml` bzw. `serve --coreml` explizit den CoreML-FP32-Encoder.
Das aktuelle japanische Modell misst sich langsamer als INT8 auf der CPU, weshalb der Automatikmodus
weiterhin die CPU wählt. Verwendung, Nachweis der Operator-Ausführung und Dreiwege-Benchmarks stehen
in [docs/MACOS_COREML.md](../MACOS_COREML.md).

## Eigene Modelle einbinden

```bash
fushi-subs models export-manifest -o models.json   # das eingebaute Manifest als Vorlage exportieren
# nach dem Bearbeiten
asr --models models.json transcribe -l hi hindi.mp3
```

Das Manifest wird anhand der `id` mit der eingebauten Tabelle zusammengeführt, wobei Ihre Packs
zuerst einsortiert werden – dieselbe `id` überschreibt den eingebauten Eintrag, und bei gleicher
Sprache gewinnt Ihre Variante. Das kleinstmögliche Pack braucht nur `id` / `languages` / `files`:

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

Für die übrigen Felder gibt es Vorgabewerte (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **Ein CTC-Pack muss `blankToken` ausdrücklich
angeben** – es gibt keinen allgemein anerkannten Standardwert, und ein falscher Rateversuch
verstümmelt das gesamte Transkript.

## HTTP-API

| Endpunkt | Hinweise |
|---|---|
| `GET /` | Die Web-UI (eine einzelne Datei ohne externe Ressourcen, offline im LAN nutzbar) |
| `GET /v1/health` | Liveness-Probe, kein Token erforderlich |
| `GET /v1/models` | Welche Sprachen und Modell-Packs bekannt sind |
| `POST /v1/transcribe?language=ja&format=srt` | Der Request-Body enthält die Audio-Bytes oder einen Multipart-Body mit einer `audio`- und einer `epub`-Datei. Die Antwort ist gestreamtes NDJSON, ein Fortschrittsereignis pro Zeile, mit `result`, `cancelled` oder `error` als letzter Zeile |
| `POST /v1/retime?language=ja&format=srt` | Neusynchronisation von Untertiteln: `audio` (Audio oder Video) und `subtitle` (UTF-8-SRT/VTT, höchstens 8 MiB) als Multipart hochladen. Untertiteltext und Cue-Anzahl bleiben erhalten, während die Zeiten gegen die Sprache neu kalibriert werden; liefert ebenfalls NDJSON |

Ist `--token` gesetzt, müssen Requests `Authorization: Bearer <token>` mitführen.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

Die Neusynchronisation unterstützt dieselben Parameter `engine`, `filename` und `jobId` wie die
Transkription, dazu die Ausgabe als SRT, VTT und JSON. `result.text` ist der neu kalibrierte
Untertitel, `rawText` die rohe Ausgabe der Spracherkennung; `retiming` meldet, wie viele Cues direkt
zugeordnet, interpoliert oder auf ihren ursprünglichen Zeiten belassen wurden, samt Trefferquote,
Zeitversatz und Warnungen, sodass Sie die Stellen prüfen können, an denen sich kein verlässlicher
Sprachanker fand. Vorangestellte Sprechernamen und in Klammern gesetzte Geräuschangaben in
japanischen TV-Untertiteln werden nur beim Abgleich ignoriert; der exportierte Text behält das
Original. Wo Untertitel und ASR-Segmentierung auseinandergehen, lassen sich mehrere unabhängige
Sprachgrenzen nutzen, um Zeitversatz oder Drift pro Segment zu schätzen; Fassungsunterschiede wie
Vorspanne und Werbeblöcke werden gesondert behandelt. Die UI unterscheidet die Anzahl neu
kalibrierter Cues von Ganzsatz-Treffern und von Schätzungen, damit eine Ganzsatz-Trefferquote nicht
mit der Abdeckung der Neukalibrierung verwechselt wird.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**Über den Erfolg entscheidet, ob eine `result`-Zeile eingetroffen ist, nicht der HTTP-Statuscode**:
Sobald die Antwort zu streamen beginnt, lässt sich der Statuscode nicht mehr ändern, ein Fehlschlag
kann also nur noch als letzte Zeile zurückgemeldet werden.

## Paketstruktur

| Paket | Inhalt | Hängt ab von |
|---|---|---|
| `fushi_asr_core` | Der reine Dart-Transkriptionskern: VAD-Segmentierung, fbank, RNN-T-Greedy-Loop-Graph / CTC-Dekodierung, Batching und Bucketing, fp16-Graphkonvertierung, Modellmanifest und Downloads, SRT-Ausgabe. **Kein Flutter, kein dart:ffi, kein mitgeliefertes ONNX-Backend** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | Das dart:ffi-ONNX-Runtime-Backend (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | EPUB-/Text-↔-Audio-Ausrichtung: Dice-Abgleich auf Satzebene (einschließlich einer Ruby-Lesungsspur), Auffüllen von Lücken zwischen Ankern, Neuzerlegung der Cues an Satzgrenzen | `fushi_asr_core` |
| `fushi_asr` | Die Fassade: ein `TranscribeRunner` mit einem einzigen Aufruf plus Untertitelformate | die beiden obigen |
| `fushi_asr_server` | Der HTTP-Server und -Client sowie die Web-UI | `fushi_asr` |
| `fushi_asr_cli` | Die Kommandozeile `asr` | `fushi_asr` `fushi_asr_server` `args` |

Der Sinn der Schichtung ist, dass **die Algorithmusschicht nur von einer einzigen schmalen
Schnittstelle abhängt** (`OnnxSessionFactory.createSession`). Ein Flutter-Host injiziert sein eigenes
Plugin-Backend, der Server injiziert das FFI-Backend, und in beiden Fällen laufen dieselben
Algorithmen.

## Entwicklung

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 Tests
cd packages/asr_onnx_ffi && dart test    # 15 Tests, braucht eine echte onnxruntime (ohne sie wird die Gruppe übersprungen)
cd packages/asr_align && dart test       # 15 Tests
cd packages/asr && dart test             # 10 Tests
cd packages/asr_server && dart test      # 10 Tests
```

Unter macOS auf Apple Silicon installiert `./script/bootstrap_macos.sh` ein projektlokales Dart SDK,
FFmpeg und ONNX Runtime; anschließend führt `./script/check.sh` die vollständige Prüfung aus.
Hinweise zur Umgebung und Empfehlungen zu den Grenzen des macOS-Hosts stehen in
[docs/MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md).

Neuerzeugen der ORT-FFI-Bindings (nur nötig, wenn die ORT-Version wechselt; der generierte Code ist
eingecheckt, gewöhnliche Nutzer brauchen also kein LLVM):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Diagnose: `ASR_TRACE_SHUTDOWN=1` schreibt jeden Schritt des Transkriptions-Teardowns nach stderr
(Session schließen → PCM-Bridge schließen → Exit-Meldung → Server schreibt die Antwort), um „ist
fertig, hängt aber“ zu debuggen.

Der Umsetzungsplan und die Abwägungen beim Entwurf stehen in [docs/PLAN.md](../PLAN.md).

## Lizenz

GPL-3.0, siehe [LICENSE](../../LICENSE). Die Header unter `third_party/onnxruntime/` stammen von ONNX
Runtime (MIT) und behalten ihre ursprüngliche Lizenz.
