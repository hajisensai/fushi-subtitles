<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · **Nederlands** · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

Meertalige spraakherkenning die ondertitels oplevert. **Een kern volledig in Dart met een
verwisselbare ONNX-backend**, die serverzijdig draait en wordt aangestuurd vanaf de opdrachtregel
of via de ingebouwde web-UI.

Losgemaakt uit [Fushi](https://github.com/hajisensai/Fushi) tot een zelfstandige repository
(`hajisensai/fushi-subtitles`), waar Fushi vervolgens van afhangt. Het uitvoerbare bestand voor de
opdrachtregel heet `fushi-subs`.

## Wat het doet

- **17 ingebouwde talen**: Japans / Engels / Chinees / Kantonees / Koreaans / Russisch /
  Vietnamees / Thai draaien elk hun eigen zipformer RNN-T; Duits / Spaans / Frans / Italiaans /
  Nederlands / Portugees / Turks / Indonesisch / Arabisch draaien op Meta's Omnilingual ASR 1B CTC.
- **Eigen modellen meebrengen**: het ingebouwde manifest is slechts een standaardwaarde. Eén
  JSON-bestand volstaat om je eigen zipformer-/CTC-exports aan te koppelen, ook voor talen buiten
  de ingebouwde 17 (`fushi-subs models export-manifest` schrijft een sjabloon weg om te bewerken).
- **Drie uitvoerformaten**: SRT / WebVTT / JSON.
- **Drie manieren om het aan te sturen**: opdrachtregel, HTTP-API en de web-UI die met de server
  meekomt.
- **Uitlijning van luisterboeken** (`fushi_asr_align`): vergelijkt ondertitelfragmenten zin voor
  zin met de hoofdtekst van de EPUB, herstelt gemiste passages door de gaten tussen ankers op te
  vullen en splitst de fragmenten daarna opnieuw op zinsgrenzen met behulp van de emissietijden per
  token — "één fragment dat meerdere zinnen beslaat" gemeten 18 → 0.

## Installatie

Kant-en-klare archieven staan op de [Releases-pagina](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel) en Windows (x64 / arm64). Pak uit, zet `fushi-subs` in je `PATH`, installeer ffmpeg (zie „Vereisten”) en draai `fushi-subs doctor` – het meldt of ONNX Runtime en ffmpeg bruikbaar zijn. De Linux- en macOS-archieven bevatten ONNX Runtime naast het uitvoerbare bestand; op Windows wordt het bij de eerste start automatisch gedownload. macOS-binaries zijn niet ondertekend: voer na het uitpakken eenmalig `xattr -dr com.apple.quarantine fushi-subs/` uit.

## Snel aan de slag

```bash
dart pub get

# Download een model (Engels int8, ongeveer 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Transcriberen, de ondertitels gaan naar stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# Of start de server en sleep bestanden naar http://127.0.0.1:8642 in een browser
dart run packages/asr_cli/bin/asr.dart serve
```

De CLI kan ook als dunne client fungeren en het werk aan een externe server overlaten:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Vereisten

| Afhankelijkheid | Opmerkingen |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — daaronder geeft `GetApi(22)` nullptr terug, dus een oudere installatie is onbruikbaar, zelfs als ze aanwezig is). Zoekvolgorde: de omgevingsvariabele `ASR_ONNXRUNTIME_LIB` → de beheerde kopie die op verzoek wordt opgehaald → naast het uitvoerbare bestand → het zoekpad van het systeem. **Op Windows wordt automatisch een bruikbare versie gedownload wanneer er geen wordt gevonden** (NuGet's `Microsoft.ML.OnnxRuntime.DirectML`, 17,9 MB, vastgezet met sha256, geplaatst in `<data root>/asr_runtime/`); de DirectML-build wordt gebruikt in plaats van de GitHub-release met alleen CPU, anders verdwijnt de GPU-versnelling stilzwijgend. `DirectML.dll` zelf komt van het systeemonderdeel van Windows. De Microsoft Visual C++ Redistributable is eveneens vereist. Gebruik op macOS `script/bootstrap_macos.sh`; gebruik op Linux de pakketbeheerder van je distributie. |
| **ffmpeg** | Decodeert willekeurige audio/video naar 16 kHz mono-PCM. Zoekvolgorde: `ASR_FFMPEG` → naast het uitvoerbare bestand → `PATH`. `ffprobe` is optioneel (zonder dat is de totale duur onbekend, waardoor het voortgangspercentage onnauwkeurig is). |

Andere omgevingsvariabelen: `ASR_DATA_DIR` (hoofdmap voor modellen en taakmappen) en
`ASR_MODELS_MANIFEST` (je eigen modelmanifest).

Op macOS schakelt `transcribe --coreml` of `serve --coreml` de CoreML FP32-encoder expliciet in.
Het huidige Japanse model meet trager dan INT8 op de CPU, dus de automatische modus kiest nog
altijd de CPU. Gebruik, bewijs van operatoruitvoering en driewegbenchmarks staan in
[../MACOS_COREML.md](../MACOS_COREML.md).

## Eigen modellen meebrengen

```bash
fushi-subs models export-manifest -o models.json   # exporteer het ingebouwde manifest als sjabloon
# nadat je het hebt bewerkt
asr --models models.json transcribe -l hi hindi.mp3
```

Het manifest wordt op `id` samengevoegd met de ingebouwde tabel, waarbij jouw pakketten voorop
komen — hetzelfde `id` overschrijft het ingebouwde, en bij dezelfde taal wint dat van jou. Het
kleinst mogelijke pakket heeft alleen `id` / `languages` / `files` nodig:

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

De overige velden hebben standaardwaarden (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **Een CTC-pakket moet `blankToken` expliciet
opgeven** — er is geen algemeen aanvaarde standaard, en een verkeerde gok verhaspelt het volledige
transcript.

## HTTP-API

| Endpoint | Opmerkingen |
|---|---|
| `GET /` | De web-UI (één bestand zonder externe bronnen, offline bruikbaar in een LAN) |
| `GET /v1/health` | Liveness-controle, geen token vereist |
| `GET /v1/models` | Welke talen en modelpakketten bekend zijn |
| `POST /v1/transcribe?language=ja&format=srt` | De hoofdtekst van het verzoek bestaat uit de audiobytes, of uit een multipart-body met een `audio`- en een `epub`-bestand. Het antwoord is streaming NDJSON, één voortgangsgebeurtenis per regel, met `result`, `cancelled` of `error` als laatste regel |
| `POST /v1/retime?language=ja&format=srt` | Ondertitels hertimen: upload `audio` (audio of video) en `subtitle` (UTF-8 SRT/VTT, maximaal 8 MiB) als multipart. De ondertiteltekst en het aantal fragmenten blijven behouden terwijl de timings opnieuw op de spraak worden geijkt; geeft eveneens NDJSON terug |

Wanneer `--token` is ingesteld, moeten verzoeken `Authorization: Bearer <token>` meesturen.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

Hertimen ondersteunt dezelfde parameters `engine`, `filename` en `jobId` als transcriberen, plus
uitvoer in SRT, VTT en JSON. `result.text` is de opnieuw geijkte ondertitel en `rawText` is de ruwe
uitvoer van de spraakherkenning; `retiming` meldt hoeveel fragmenten rechtstreeks zijn gematcht,
geïnterpoleerd of op hun oorspronkelijke timing zijn gelaten, samen met het matchpercentage, de
tijdsverschuiving en waarschuwingen, zodat je de delen kunt inspecteren waar geen betrouwbaar
spraakanker is gevonden. Voorop geplaatste sprekersnamen en geluidseffecten tussen haakjes in
Japanse tv-ondertitels worden alleen tijdens het matchen genegeerd; de geëxporteerde tekst behoudt
het origineel. Waar de ondertitels en de ASR-segmentatie van elkaar afwijken, kunnen meerdere
onafhankelijke spraakgrenzen worden gebruikt om per segment een tijdsverschuiving of drift te
schatten; versieverschillen zoals intro's en reclameblokken worden apart afgehandeld. De UI maakt
onderscheid tussen het aantal opnieuw geijkte fragmenten, volledige-zinmatches en schattingen,
zodat een matchpercentage op volledige zinnen niet wordt aangezien voor de dekking van de
herijking.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**Succes wordt bepaald door de vraag of er een `result`-regel is binnengekomen, niet door de
HTTP-statuscode**: zodra het antwoord begint te streamen kan de statuscode niet meer worden
gewijzigd, dus een mislukking kan alleen als laatste regel worden teruggestuurd.

## Pakketindeling

| Pakket | Inhoud | Hangt af van |
|---|---|---|
| `fushi_asr_core` | De transcriptiekern volledig in Dart: VAD-segmentatie, fbank, RNN-T greedy Loop-graaf / CTC-decodering, batching en bucketing, fp16-graafconversie, modelmanifest en downloads, SRT-uitvoer. **Geen Flutter, geen dart:ffi, geen meegeleverde ONNX-backend** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | De ONNX Runtime-backend via dart:ffi (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | Uitlijning van EPUB / tekst ↔ audio: Dice-matching op zinsniveau (inclusief een spoor met ruby-lezingen), gaten tussen ankers opvullen, fragmenten opnieuw splitsen op zinsgrenzen | `fushi_asr_core` |
| `fushi_asr` | De façade: een `TranscribeRunner` met één aanroep plus ondertitelformaten | de twee bovenstaande |
| `fushi_asr_server` | De HTTP-server en -client plus de web-UI | `fushi_asr` |
| `fushi_asr_cli` | De opdrachtregel `asr` | `fushi_asr` `fushi_asr_server` `args` |

Het punt van deze gelaagdheid is dat **de algoritmelaag van slechts één smalle interface afhangt**
(`OnnxSessionFactory.createSession`). Een Flutter-host injecteert zijn eigen plug-inbackend, de
server injecteert de FFI-backend, en dezelfde algoritmen draaien op beide.

## Ontwikkeling

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 tests
cd packages/asr_onnx_ffi && dart test    # 15 tests, vereist een echte onnxruntime (de groep wordt anders overgeslagen)
cd packages/asr_align && dart test       # 15 tests
cd packages/asr && dart test             # 10 tests
cd packages/asr_server && dart test      # 10 tests
```

Op macOS met Apple Silicon installeert `./script/bootstrap_macos.sh` een projectlokale Dart-SDK,
FFmpeg en ONNX Runtime, waarna `./script/check.sh` de volledige controle uitvoert. Opmerkingen over
de omgeving en advies over de grenzen van de macOS-host staan in
[../MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md).

De ORT FFI-bindings opnieuw genereren (alleen nodig bij het wijzigen van de ORT-versie; de
gegenereerde code is ingecheckt, dus gewone gebruikers hebben geen LLVM nodig):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Diagnostiek: `ASR_TRACE_SHUTDOWN=1` schrijft elke stap van het afbouwen van de transcriptie naar
stderr (sessie sluiten → PCM-bridge sluiten → afsluitbericht → server schrijft het antwoord), voor
het debuggen van "hij is klaar maar blijft hangen".

Het implementatieplan en de ontwerpafwegingen staan in [../PLAN.md](../PLAN.md).

## Licentie

GPL-3.0, zie [LICENSE](../../LICENSE). De headers onder `third_party/onnxruntime/` komen van ONNX
Runtime (MIT) en behouden hun oorspronkelijke licentie.
