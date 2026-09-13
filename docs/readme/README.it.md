<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · **Italiano** · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

Riconoscimento vocale multilingue che produce sottotitoli. **Un core interamente in Dart con un
backend ONNX intercambiabile**, che gira lato server e si pilota da riga di comando o dalla web UI
integrata.

Estratto da [Fushi](https://github.com/hajisensai/Fushi) in un repository autonomo
(`hajisensai/fushi-subtitles`), da cui Fushi poi dipende. L'eseguibile da riga di comando si chiama
`fushi-subs`.

## Cosa fa

- **17 lingue integrate**: giapponese / inglese / cinese / cantonese / coreano / russo /
  vietnamita / thailandese usano ciascuna il proprio zipformer RNN-T; tedesco / spagnolo /
  francese / italiano / olandese / portoghese / turco / indonesiano / arabo usano Omnilingual ASR
  1B CTC di Meta.
- **Modelli propri**: il manifest integrato è solo un valore predefinito. Basta un file JSON per
  collegare i tuoi export zipformer / CTC, comprese lingue al di fuori delle 17 integrate
  (`fushi-subs models export-manifest` scrive un modello da modificare).
- **Tre formati di output**: SRT / WebVTT / JSON.
- **Tre modi per pilotarlo**: riga di comando, API HTTP e la web UI inclusa nel server.
- **Allineamento di audiolibri** (`fushi_asr_align`): confronta le battute dei sottotitoli con il
  testo del corpo dell'EPUB frase per frase, recupera i passaggi mancati riempiendo gli spazi tra
  gli ancoraggi e infine risuddivide le battute sui confini di frase usando i tempi di emissione
  per token — «una battuta che copre più frasi» misurata 18 → 0.

## Installazione

Gli archivi precompilati sono nella [pagina Releases](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel) e Windows (x64 / arm64). Estrai, metti `fushi-subs` nel `PATH`, installa ffmpeg (vedi «Prerequisiti») e poi esegui `fushi-subs doctor`: riporta se ONNX Runtime e ffmpeg sono utilizzabili. Gli archivi Linux e macOS includono ONNX Runtime accanto all'eseguibile; su Windows viene scaricato automaticamente al primo avvio. I binari macOS non sono firmati: dopo l'estrazione esegui una volta `xattr -dr com.apple.quarantine fushi-subs/`.

## Avvio rapido

```bash
dart pub get

# Scarica un modello (inglese int8, circa 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Trascrivi, i sottotitoli vanno su stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# Oppure avvia il server e trascina i file su http://127.0.0.1:8642 nel browser
dart run packages/asr_cli/bin/asr.dart serve
```

La CLI può anche fare da client leggero e delegare il lavoro a un server remoto:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Prerequisiti

| Dipendenza | Note |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — al di sotto `GetApi(22)` restituisce nullptr, quindi un'installazione più vecchia è inutilizzabile anche se presente). Ordine di ricerca: la variabile d'ambiente `ASR_ONNXRUNTIME_LIB` → la copia gestita scaricata su richiesta → accanto all'eseguibile → il percorso di ricerca di sistema. **Su Windows una versione utilizzabile viene scaricata automaticamente quando non se ne trova nessuna** (`Microsoft.ML.OnnxRuntime.DirectML` da NuGet, 17,9 MB, fissato tramite sha256, collocato in `<data root>/asr_runtime/`); si usa la build DirectML e non la release GitHub solo-CPU, altrimenti l'accelerazione GPU sparisce silenziosamente. `DirectML.dll` stessa proviene dal componente di sistema di Windows. È richiesto anche il Microsoft Visual C++ Redistributable. Su macOS usa `script/bootstrap_macos.sh`; su Linux usa il gestore di pacchetti della tua distribuzione. |
| **ffmpeg** | Decodifica audio/video arbitrari in PCM mono a 16 kHz. Ordine di ricerca: `ASR_FFMPEG` → accanto all'eseguibile → `PATH`. `ffprobe` è facoltativo (senza di esso la durata totale è sconosciuta, quindi la percentuale di avanzamento è imprecisa). |

Altre variabili d'ambiente: `ASR_DATA_DIR` (radice per i modelli e le directory dei job) e
`ASR_MODELS_MANIFEST` (il tuo manifest dei modelli).

Su macOS, `transcribe --coreml` o `serve --coreml` abilita esplicitamente l'encoder CoreML FP32.
L'attuale modello giapponese risulta più lento dell'INT8 su CPU, quindi la modalità automatica
sceglie comunque la CPU. Utilizzo, prova dell'esecuzione degli operatori e benchmark a tre vie sono
in [../MACOS_COREML.md](../MACOS_COREML.md).

## Modelli propri

```bash
fushi-subs models export-manifest -o models.json   # esporta il manifest integrato come modello
# dopo averlo modificato
asr --models models.json transcribe -l hi hindi.mp3
```

Il manifest viene unito alla tabella integrata tramite `id`, con i tuoi pacchetti messi per primi —
lo stesso `id` sovrascrive quello integrato e, a parità di lingua, vince il tuo. Il pacchetto più
piccolo possibile richiede solo `id` / `languages` / `files`:

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

I campi rimanenti hanno valori predefiniti (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **Un pacchetto CTC deve dichiarare `blankToken` in
modo esplicito** — non esiste un valore predefinito condiviso e sbagliare a indovinare rende
illeggibile l'intera trascrizione.

## API HTTP

| Endpoint | Note |
|---|---|
| `GET /` | La web UI (un singolo file senza risorse esterne, utilizzabile offline in LAN) |
| `GET /v1/health` | Sonda di liveness, nessun token richiesto |
| `GET /v1/models` | Quali lingue e pacchetti di modelli sono noti |
| `POST /v1/transcribe?language=ja&format=srt` | Il corpo della richiesta sono i byte audio, oppure un corpo multipart con un file `audio` e uno `epub`. La risposta è NDJSON in streaming, un evento di avanzamento per riga, con `result`, `cancelled` o `error` come ultima riga |
| `POST /v1/retime?language=ja&format=srt` | Ritempificazione dei sottotitoli: carica `audio` (audio o video) e `subtitle` (SRT/VTT UTF-8, al massimo 8 MiB) come multipart. Il testo dei sottotitoli e il numero di battute vengono preservati mentre i tempi vengono ricalibrati sul parlato; restituisce anch'esso NDJSON |

Quando `--token` è impostato, le richieste devono includere `Authorization: Bearer <token>`.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

La ritempificazione supporta gli stessi parametri `engine`, `filename` e `jobId` della
trascrizione, oltre all'output SRT, VTT e JSON. `result.text` è il sottotitolo ricalibrato e
`rawText` è l'output grezzo del riconoscimento vocale; `retiming` riporta quante battute sono state
abbinate direttamente, interpolate o lasciate sui tempi originali, insieme al tasso di
corrispondenza, allo scostamento temporale e agli avvisi, così puoi ispezionare le parti in cui non
è stato trovato alcun ancoraggio vocale affidabile. I nomi dei parlanti in testa e gli effetti
sonori tra parentesi nei sottotitoli TV giapponesi vengono ignorati solo durante l'abbinamento; il
testo esportato mantiene l'originale. Dove i sottotitoli e la segmentazione ASR non concordano, si
possono usare più confini di parlato indipendenti per stimare uno scostamento temporale o una
deriva per segmento; le differenze di versione come sigle e pubblicità sono gestite a parte. La UI
distingue il numero di battute ricalibrate dalle corrispondenze di frase intera e dalle stime, così
un tasso di corrispondenza a frase intera non viene scambiato per copertura della ricalibrazione.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**Il successo è determinato dall'arrivo di una riga `result`, non dal codice di stato HTTP**: una
volta che la risposta inizia a essere trasmessa in streaming il codice di stato non può più essere
cambiato, quindi un errore può essere comunicato solo come ultima riga.

## Struttura dei pacchetti

| Pacchetto | Contenuto | Dipende da |
|---|---|---|
| `fushi_asr_core` | Il core di trascrizione interamente in Dart: segmentazione VAD, fbank, decodifica RNN-T greedy con grafo Loop / CTC, batching e bucketing, conversione del grafo in fp16, manifest dei modelli e download, output SRT. **Niente Flutter, niente dart:ffi, nessun backend ONNX incluso** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | Il backend ONNX Runtime via dart:ffi (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | Allineamento EPUB / testo ↔ audio: corrispondenza Dice a livello di frase (inclusa una traccia di letture ruby), riempimento delle lacune tra gli ancoraggi, risuddivisione delle battute sui confini di frase | `fushi_asr_core` |
| `fushi_asr` | La facciata: un `TranscribeRunner` a chiamata singola più i formati di sottotitoli | i due precedenti |
| `fushi_asr_server` | Il server e il client HTTP più la web UI | `fushi_asr` |
| `fushi_asr_cli` | La riga di comando `asr` | `fushi_asr` `fushi_asr_server` `args` |

Il senso della stratificazione è che **il livello algoritmico dipende da una sola interfaccia
ristretta** (`OnnxSessionFactory.createSession`). Un host Flutter inietta il proprio backend
plugin, il server inietta il backend FFI, e gli stessi algoritmi girano su entrambi.

## Sviluppo

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 test
cd packages/asr_onnx_ffi && dart test    # 15 test, richiede un onnxruntime reale (il gruppo viene saltato senza)
cd packages/asr_align && dart test       # 15 test
cd packages/asr && dart test             # 10 test
cd packages/asr_server && dart test      # 10 test
```

Su macOS con Apple Silicon, `./script/bootstrap_macos.sh` installa un SDK Dart locale al progetto,
FFmpeg e ONNX Runtime; dopodiché `./script/check.sh` esegue il controllo completo. Note
sull'ambiente e indicazioni sui confini per l'host macOS sono in
[../MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md).

Rigenerazione dei binding FFI di ORT (serve solo quando si cambia la versione di ORT; il codice
generato è versionato, quindi gli utenti comuni non hanno bisogno di LLVM):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Diagnostica: `ASR_TRACE_SHUTDOWN=1` scrive su stderr ogni passo della chiusura della trascrizione
(chiusura della sessione → chiusura del bridge PCM → messaggio di uscita → il server scrive la
risposta), utile per il debug di «ha finito ma resta appeso».

Il piano di implementazione e i compromessi di progettazione sono in [../PLAN.md](../PLAN.md).

## Licenza

GPL-3.0, vedi [LICENSE](../../LICENSE). Gli header sotto `third_party/onnxruntime/` provengono da
ONNX Runtime (MIT) e mantengono la loro licenza originale.
