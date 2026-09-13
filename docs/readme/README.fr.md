<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · **Français** · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

Reconnaissance vocale multilingue qui produit des sous-titres. **Un cœur en Dart pur doté d'un
backend ONNX interchangeable**, qui s'exécute côté serveur et se pilote depuis la CLI ou depuis
l'interface web intégrée.

Extrait de [Fushi](https://github.com/hajisensai/Fushi) vers un dépôt autonome
(`hajisensai/fushi-subtitles`), dont Fushi dépend désormais. L'exécutable en ligne de commande
s'appelle `fushi-subs`.

## Ce qu'il fait

- **17 langues intégrées** : japonais / anglais / chinois / cantonais / coréen / russe /
  vietnamien / thaï disposent chacun de leur propre zipformer RNN-T ; allemand / espagnol /
  français / italien / néerlandais / portugais / turc / indonésien / arabe passent par Omnilingual
  ASR 1B CTC de Meta.
- **Vos propres modèles** : le manifeste intégré n'est qu'une valeur par défaut. Un seul fichier
  JSON suffit à brancher vos propres exports zipformer / CTC, y compris pour des langues hors des
  17 langues intégrées (`fushi-subs models export-manifest` écrit un modèle de fichier à éditer).
- **Trois formats de sortie** : SRT / WebVTT / JSON.
- **Trois façons de le piloter** : ligne de commande, API HTTP et l'interface web livrée avec le
  serveur.
- **Alignement de livres audio** (`fushi_asr_align`) : met en correspondance, phrase par phrase, les
  cues de sous-titres avec le corps de texte de l'EPUB, récupère les passages manqués en comblant
  l'intervalle entre les ancres, puis redécoupe les cues aux frontières de phrase à partir des temps
  d'émission par token — les cas d'« un cue couvrant plusieurs phrases » sont passés de 18 à 0 à la
  mesure.

## Installation

Les archives précompilées sont sur la [page Releases](https://github.com/hajisensai/fushi-subtitles/releases) : Linux (x64 / arm64), macOS (Apple Silicon / Intel) et Windows (x64 / arm64). Décompressez, placez `fushi-subs` dans votre `PATH`, installez ffmpeg (voir « Prérequis »), puis lancez `fushi-subs doctor` : il indique si ONNX Runtime et ffmpeg sont utilisables. Les archives Linux et macOS embarquent ONNX Runtime à côté de l'exécutable ; sous Windows il est téléchargé automatiquement au premier lancement. Les binaires macOS ne sont pas signés : exécutez une fois `xattr -dr com.apple.quarantine fushi-subs/` après décompression.

## Démarrage rapide

```bash
dart pub get

# Télécharger un modèle (anglais int8, environ 67 Mo)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Transcrire, les sous-titres partent sur stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# Ou démarrer le serveur et déposer des fichiers sur http://127.0.0.1:8642 dans un navigateur
dart run packages/asr_cli/bin/asr.dart serve
```

La CLI peut aussi se comporter en client léger et confier le travail à un serveur distant :

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Prérequis

| Dépendance | Remarques |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — en deçà, `GetApi(22)` renvoie nullptr, si bien qu'une installation plus ancienne reste inutilisable même lorsqu'elle est présente). Ordre de recherche : la variable d'environnement `ASR_ONNXRUNTIME_LIB` → la copie gérée récupérée à la demande → à côté de l'exécutable → le chemin de recherche du système. **Sous Windows, une version utilisable est téléchargée automatiquement lorsqu'aucune n'est trouvée** (le paquet NuGet `Microsoft.ML.OnnxRuntime.DirectML`, 17,9 Mo, épinglé par sha256, installé dans `<data root>/asr_runtime/`) ; c'est la build DirectML qui est utilisée plutôt que la release GitHub CPU seule, faute de quoi l'accélération GPU disparaîtrait silencieusement. `DirectML.dll` provient quant à elle du composant système de Windows. Le Microsoft Visual C++ Redistributable est également requis. Sous macOS, utilisez `script/bootstrap_macos.sh` ; sous Linux, le gestionnaire de paquets de votre distribution. |
| **ffmpeg** | Décode n'importe quel flux audio/vidéo en PCM mono 16 kHz. Ordre de recherche : `ASR_FFMPEG` → à côté de l'exécutable → `PATH`. `ffprobe` est facultatif (sans lui, la durée totale est inconnue, donc le pourcentage de progression est imprécis). |

Autres variables d'environnement : `ASR_DATA_DIR` (racine des modèles et des répertoires de tâches)
et `ASR_MODELS_MANIFEST` (votre propre manifeste de modèles).

Sous macOS, `transcribe --coreml` ou `serve --coreml` activent explicitement l'encodeur CoreML FP32.
Le modèle japonais actuel se mesure plus lent que l'INT8 sur CPU, si bien que le mode automatique
choisit toujours le CPU. L'utilisation, la preuve de l'exécution des opérateurs et les benchmarks
à trois voies figurent dans [docs/MACOS_COREML.md](../MACOS_COREML.md).

## Vos propres modèles

```bash
fushi-subs models export-manifest -o models.json   # exporter le manifeste intégré comme gabarit
# après l'avoir édité
asr --models models.json transcribe -l hi hindi.mp3
```

Le manifeste est fusionné avec la table intégrée par `id`, vos packs étant placés en premier : un
`id` identique remplace celui d'origine et, pour une même langue, le vôtre l'emporte. Le pack le
plus minimal possible ne nécessite que `id` / `languages` / `files` :

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

Les autres champs ont des valeurs par défaut (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **Un pack CTC doit indiquer `blankToken`
explicitement** — il n'existe pas de valeur par défaut consensuelle, et se tromper en la devinant
rend toute la transcription incompréhensible.

## API HTTP

| Point d'entrée | Remarques |
|---|---|
| `GET /` | L'interface web (un fichier unique sans ressource externe, utilisable hors ligne sur un réseau local) |
| `GET /v1/health` | Sonde de disponibilité, aucun jeton requis |
| `GET /v1/models` | Quelles langues et quels packs de modèles sont connus |
| `POST /v1/transcribe?language=ja&format=srt` | Le corps de la requête contient les octets audio, ou un corps multipart avec un fichier `audio` et un fichier `epub`. La réponse est du NDJSON en flux, un événement de progression par ligne, avec `result`, `cancelled` ou `error` en dernière ligne |
| `POST /v1/retime?language=ja&format=srt` | Resynchronisation de sous-titres : envoyez `audio` (audio ou vidéo) et `subtitle` (SRT/VTT en UTF-8, 8 Mio au maximum) en multipart. Le texte des sous-titres et le nombre de cues sont préservés pendant que les minutages sont recalibrés sur la parole ; renvoie également du NDJSON |

Lorsque `--token` est défini, les requêtes doivent porter `Authorization: Bearer <token>`.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

La resynchronisation accepte les mêmes paramètres `engine`, `filename` et `jobId` que la
transcription, ainsi que la sortie en SRT, VTT et JSON. `result.text` est le sous-titre recalibré et
`rawText` la sortie brute de la reconnaissance vocale ; `retiming` indique combien de cues ont été
appariés directement, interpolés ou laissés sur leurs minutages d'origine, avec le taux de
correspondance, le décalage temporel et les avertissements, afin que vous puissiez inspecter les
endroits où aucune ancre de parole fiable n'a été trouvée. Les noms de locuteur en tête de ligne et
les bruitages entre crochets des sous-titres de la télévision japonaise ne sont ignorés que pendant
la mise en correspondance ; le texte exporté conserve l'original. Là où les sous-titres et la
segmentation de l'ASR divergent, plusieurs frontières de parole indépendantes peuvent servir à
estimer un décalage temporel ou une dérive par segment ; les différences de version telles que les
génériques et les coupures publicitaires sont traitées séparément. L'interface distingue le nombre
de cues recalibrés des correspondances de phrase entière et des estimations, afin qu'un taux de
correspondance de phrase entière ne soit pas pris pour la couverture de la recalibration.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**Le succès se juge à l'arrivée d'une ligne `result`, pas au code de statut HTTP** : une fois que la
réponse commence à être diffusée, le code de statut ne peut plus être modifié, si bien qu'un échec
ne peut être signalé qu'en dernière ligne.

## Organisation des paquets

| Paquet | Contenu | Dépend de |
|---|---|---|
| `fushi_asr_core` | Le cœur de transcription en Dart pur : segmentation VAD, fbank, graphe Loop glouton RNN-T / décodage CTC, batching et bucketing, conversion du graphe en fp16, manifeste de modèles et téléchargements, sortie SRT. **Pas de Flutter, pas de dart:ffi, aucun backend ONNX embarqué** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | Le backend ONNX Runtime en dart:ffi (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | Alignement EPUB / texte ↔ audio : correspondance Dice au niveau de la phrase (y compris une piste de lectures ruby), comblement des intervalles entre ancres, redécoupage des cues aux frontières de phrase | `fushi_asr_core` |
| `fushi_asr` | La façade : un `TranscribeRunner` en un seul appel, plus les formats de sous-titres | les deux précédents |
| `fushi_asr_server` | Le serveur et le client HTTP, ainsi que l'interface web | `fushi_asr` |
| `fushi_asr_cli` | La ligne de commande `asr` | `fushi_asr` `fushi_asr_server` `args` |

L'intérêt de ce découpage en couches est que **la couche algorithmique ne dépend que d'une seule
interface étroite** (`OnnxSessionFactory.createSession`). Un hôte Flutter injecte son propre backend
de plugin, le serveur injecte le backend FFI, et les mêmes algorithmes s'exécutent dans les deux cas.

## Développement

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 tests
cd packages/asr_onnx_ffi && dart test    # 15 tests, nécessite un vrai onnxruntime (sinon le groupe est ignoré)
cd packages/asr_align && dart test       # 15 tests
cd packages/asr && dart test             # 10 tests
cd packages/asr_server && dart test      # 10 tests
```

Sous macOS sur Apple Silicon, `./script/bootstrap_macos.sh` installe un SDK Dart local au projet,
FFmpeg et ONNX Runtime, après quoi `./script/check.sh` lance la vérification complète. Les notes sur
l'environnement et les conseils relatifs aux limites de l'hôte macOS se trouvent dans
[docs/MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md).

Régénération des bindings FFI d'ORT (nécessaire uniquement en cas de changement de version d'ORT ; le
code généré est versionné, les utilisateurs ordinaires n'ont donc pas besoin de LLVM) :

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Diagnostic : `ASR_TRACE_SHUTDOWN=1` écrit sur stderr chaque étape de la fermeture de la transcription
(fermeture de la session → fermeture du pont PCM → message de sortie → écriture de la réponse par le
serveur), pour déboguer les cas « c'est terminé mais ça reste bloqué ».

Le plan d'implémentation et les arbitrages de conception se trouvent dans
[docs/PLAN.md](../PLAN.md).

## Licence

GPL-3.0, voir [LICENSE](../../LICENSE). Les en-têtes situés sous `third_party/onnxruntime/`
proviennent d'ONNX Runtime (MIT) et conservent leur licence d'origine.
