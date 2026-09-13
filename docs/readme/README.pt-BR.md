<!-- Language nav: English first (the default), then the web UI i18n LANGS order; guarded by readme_i18n_test.dart -->
[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-HK.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · **Português (Brasil)** · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [ไทย](README.th.md) · [Bahasa Indonesia](README.id.md) · [العربية](README.ar.md)

# fushi-subtitles

Reconhecimento de fala multilíngue que gera legendas. **Um núcleo em Dart puro com um backend ONNX
plugável**, executado no servidor e controlado pela linha de comando ou pela interface web
embutida.

Extraído do [Fushi](https://github.com/hajisensai/Fushi) para um repositório independente
(`hajisensai/fushi-subtitles`), do qual o Fushi passou a depender. O executável de linha de comando
se chama `fushi-subs`.

## O que ele faz

- **17 idiomas embutidos**: japonês / inglês / chinês / cantonês / coreano / russo / vietnamita /
  tailandês usam cada um o seu próprio zipformer RNN-T; alemão / espanhol / francês / italiano /
  holandês / português / turco / indonésio / árabe usam o Omnilingual ASR 1B CTC da Meta.
- **Traga seus próprios modelos**: o manifesto embutido é apenas um padrão. Basta um arquivo JSON
  para plugar seus próprios exports zipformer / CTC, inclusive idiomas fora dos 17 embutidos
  (`fushi-subs models export-manifest` grava um modelo para você editar).
- **Três formatos de saída**: SRT / WebVTT / JSON.
- **Três formas de operá-lo**: linha de comando, API HTTP e a interface web que acompanha o
  servidor.
- **Alinhamento de audiolivros** (`fushi_asr_align`): compara as legendas com o texto do corpo do
  EPUB frase a frase, recupera trechos perdidos preenchendo as lacunas entre âncoras e então
  redivide as legendas nos limites de frase usando os tempos de emissão por token — "uma legenda
  cobrindo várias frases" medido em 18 → 0.

## Instalação

Os arquivos pré-compilados estão na [página de Releases](https://github.com/hajisensai/fushi-subtitles/releases): Linux (x64 / arm64), macOS (Apple Silicon / Intel) e Windows (x64 / arm64). Descompacte, coloque `fushi-subs` no seu `PATH`, instale o ffmpeg (veja «Pré-requisitos») e rode `fushi-subs doctor` — ele informa se o ONNX Runtime e o ffmpeg estão utilizáveis. Os arquivos de Linux e macOS trazem o ONNX Runtime ao lado do executável; no Windows ele é baixado automaticamente na primeira execução. Os binários de macOS não são assinados: após descompactar, rode uma vez `xattr -dr com.apple.quarantine fushi-subs/`.

## Início rápido

```bash
dart pub get

# Baixe um modelo (inglês int8, cerca de 67 MB)
dart run packages/asr_cli/bin/asr.dart models pull -l en

# Transcreva; as legendas vão para stdout
dart run packages/asr_cli/bin/asr.dart transcribe -l en lecture.mp3 > lecture.srt

# Ou inicie o servidor e arraste arquivos para http://127.0.0.1:8642 no navegador
dart run packages/asr_cli/bin/asr.dart serve
```

A CLI também pode atuar como cliente leve e delegar o trabalho a um servidor remoto:

```bash
fushi-subs transcribe -l ja --server http://192.168.1.10:8642 audiobook.m4b -o out.srt
```

### Pré-requisitos

| Dependência | Observações |
|---|---|
| **ONNX Runtime** | `onnxruntime.dll` / `libonnxruntime.so` / `libonnxruntime.dylib` (**1.22+** — abaixo disso `GetApi(22)` retorna nullptr, então uma instalação mais antiga é inutilizável mesmo estando presente). Ordem de busca: a variável de ambiente `ASR_ONNXRUNTIME_LIB` → a cópia gerenciada baixada sob demanda → ao lado do executável → o caminho de busca do sistema. **No Windows, uma versão utilizável é baixada automaticamente quando nenhuma é encontrada** (`Microsoft.ML.OnnxRuntime.DirectML` do NuGet, 17,9 MB, fixado por sha256, instalado em `<data root>/asr_runtime/`); usa-se a build DirectML em vez da release do GitHub somente para CPU, caso contrário a aceleração por GPU desaparece silenciosamente. A própria `DirectML.dll` vem do componente de sistema do Windows. O Microsoft Visual C++ Redistributable também é necessário. No macOS use `script/bootstrap_macos.sh`; no Linux use o gerenciador de pacotes da sua distribuição. |
| **ffmpeg** | Decodifica áudio/vídeo arbitrário em PCM mono de 16 kHz. Ordem de busca: `ASR_FFMPEG` → ao lado do executável → `PATH`. O `ffprobe` é opcional (sem ele a duração total é desconhecida, então a porcentagem de progresso fica imprecisa). |

Outras variáveis de ambiente: `ASR_DATA_DIR` (raiz para modelos e diretórios de jobs) e
`ASR_MODELS_MANIFEST` (seu próprio manifesto de modelos).

No macOS, `transcribe --coreml` ou `serve --coreml` habilita explicitamente o encoder CoreML FP32.
O modelo japonês atual mede mais lento que o INT8 na CPU, então o modo automático continua
escolhendo a CPU. Uso, comprovação da execução dos operadores e benchmarks de três vias estão em
[../MACOS_COREML.md](../MACOS_COREML.md).

## Traga seus próprios modelos

```bash
fushi-subs models export-manifest -o models.json   # exporta o manifesto embutido como modelo
# depois de editá-lo
asr --models models.json transcribe -l hi hindi.mp3
```

O manifesto é mesclado com a tabela embutida por `id`, com os seus pacotes vindo primeiro — o mesmo
`id` sobrescreve o embutido e, para o mesmo idioma, o seu prevalece. O menor pacote possível precisa
apenas de `id` / `languages` / `files`:

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

Os demais campos têm padrões (`architecture: transducer`, `indexType: int64`,
`decoderContextSize: 2`, `blankToken: <blk>`). **Um pacote CTC precisa declarar `blankToken`
explicitamente** — não existe um padrão consensual, e errar o palpite embaralha a transcrição
inteira.

## API HTTP

| Endpoint | Observações |
|---|---|
| `GET /` | A interface web (um único arquivo sem recursos externos, utilizável offline em rede local) |
| `GET /v1/health` | Sonda de liveness, não exige token |
| `GET /v1/models` | Quais idiomas e pacotes de modelos são conhecidos |
| `POST /v1/transcribe?language=ja&format=srt` | O corpo da requisição são os bytes de áudio, ou um corpo multipart com um arquivo `audio` e um `epub`. A resposta é NDJSON em streaming, um evento de progresso por linha, com `result`, `cancelled` ou `error` como última linha |
| `POST /v1/retime?language=ja&format=srt` | Reajuste de tempo das legendas: envie `audio` (áudio ou vídeo) e `subtitle` (SRT/VTT em UTF-8, no máximo 8 MiB) como multipart. O texto das legendas e a contagem de blocos são preservados enquanto os tempos são recalibrados contra a fala; também retorna NDJSON |

Quando `--token` está definido, as requisições devem enviar `Authorization: Bearer <token>`.

```js
const res = await fetch('/v1/transcribe?language=ja', { method: 'POST', body: file });
```

O reajuste de tempo aceita os mesmos parâmetros `engine`, `filename` e `jobId` da transcrição, além
de saída em SRT, VTT e JSON. `result.text` é a legenda recalibrada e `rawText` é a saída bruta do
reconhecimento de fala; `retiming` informa quantos blocos foram correspondidos diretamente,
interpolados ou mantidos nos tempos originais, junto com a taxa de correspondência, o deslocamento
de tempo e os avisos, para que você possa inspecionar os trechos em que nenhuma âncora de fala
confiável foi encontrada. Nomes de falantes no início da linha e efeitos sonoros entre colchetes em
legendas de TV japonesas são ignorados apenas durante a correspondência; o texto exportado mantém o
original. Onde as legendas e a segmentação do ASR divergem, vários limites de fala independentes
podem ser usados para estimar um deslocamento de tempo ou uma deriva por segmento; diferenças de
versão, como aberturas e comerciais, são tratadas à parte. A interface distingue a contagem de
blocos recalibrados das correspondências de frase inteira e das estimativas, de modo que uma taxa
de correspondência de frase inteira não seja confundida com a cobertura da recalibração.

```js
const body = new FormData();
body.append('audio', mediaFile);
body.append('subtitle', subtitleFile);
const res = await fetch('/v1/retime?language=ja&format=srt', {
  method: 'POST',
  body,
});
```

**O sucesso é determinado pela chegada de uma linha `result`, não pelo código de status HTTP**: uma
vez que a resposta começa a ser transmitida em streaming, o código de status não pode mais ser
alterado, então uma falha só pode ser comunicada como a última linha.

## Estrutura dos pacotes

| Pacote | Conteúdo | Depende de |
|---|---|---|
| `fushi_asr_core` | O núcleo de transcrição em Dart puro: segmentação VAD, fbank, decodificação RNN-T greedy com grafo Loop / CTC, batching e bucketing, conversão de grafo para fp16, manifesto de modelos e downloads, saída SRT. **Sem Flutter, sem dart:ffi, sem backend ONNX embutido** | `meta` `path` `crypto` |
| `fushi_asr_onnx_ffi` | O backend ONNX Runtime via dart:ffi (CPU / DirectML / CUDA) | `fushi_asr_core` `ffi` |
| `fushi_asr_align` | Alinhamento EPUB / texto ↔ áudio: correspondência Dice em nível de frase (incluindo uma trilha de leituras ruby), preenchimento de lacunas entre âncoras, redivisão das legendas nos limites de frase | `fushi_asr_core` |
| `fushi_asr` | A fachada: um `TranscribeRunner` de chamada única mais os formatos de legenda | os dois acima |
| `fushi_asr_server` | O servidor e o cliente HTTP mais a interface web | `fushi_asr` |
| `fushi_asr_cli` | A linha de comando `asr` | `fushi_asr` `fushi_asr_server` `args` |

O objetivo dessa estratificação é que **a camada de algoritmos dependa de uma única interface
estreita** (`OnnxSessionFactory.createSession`). Um host Flutter injeta o seu próprio backend de
plugin, o servidor injeta o backend FFI, e os mesmos algoritmos rodam nos dois.

## Desenvolvimento

```bash
dart analyze packages
cd packages/asr_core && dart test        # 326 testes
cd packages/asr_onnx_ffi && dart test    # 15 testes, precisa de um onnxruntime real (sem ele o grupo é pulado)
cd packages/asr_align && dart test       # 15 testes
cd packages/asr && dart test             # 10 testes
cd packages/asr_server && dart test      # 10 testes
```

No macOS com Apple Silicon, `./script/bootstrap_macos.sh` instala um SDK Dart local ao projeto,
FFmpeg e ONNX Runtime; em seguida `./script/check.sh` executa a verificação completa. Notas sobre o
ambiente e orientações de fronteira para o host macOS estão em
[../MACOS_DEVELOPMENT.md](../MACOS_DEVELOPMENT.md).

Regeneração dos bindings FFI do ORT (necessária apenas ao mudar a versão do ORT; o código gerado
está versionado, então usuários comuns não precisam de LLVM):

```bash
cd packages/asr_onnx_ffi && dart run ffigen --config ffigen.yaml
```

Diagnóstico: `ASR_TRACE_SHUTDOWN=1` escreve no stderr cada passo do encerramento da transcrição
(fechar sessão → fechar a ponte PCM → mensagem de saída → o servidor escreve a resposta), para
depurar o caso "terminou mas fica travado".

O plano de implementação e as decisões de projeto estão em [../PLAN.md](../PLAN.md).

## Licença

GPL-3.0, veja [LICENSE](../../LICENSE). Os headers em `third_party/onnxruntime/` vêm do ONNX Runtime
(MIT) e mantêm a licença original.
