# video-dl

> yt-dlp com menos sofrimento.

Downloader universal para Windows/PowerShell, usando `yt-dlp`, Streamlink e fallbacks específicos quando necessário.

## Instalar

Abra o PowerShell e rode:

```powershell
irm https://raw.githubusercontent.com/sillasHead/video-dl/main/setup.ps1 | iex
```

O instalador baixa diretamente os arquivos da versão mais recente, atualiza uma instalação anterior e preserva suas configurações em `%USERPROFILE%\.video-dl`. Ele não precisa executar o `.exe` da release.

Depois, abra um terminal novo e use:

```powershell
video-dl "URL"
```

## Exemplos

```powershell
video-dl "URL"
video-dl "URL" --audio
video-dl "URL" --quality 720
video-dl "URL" --max-quality
video-dl "URL" --cookies auto
video-dl --series
video-dl "URL" --series
video-dl "URL-DE-PLAYLIST" --playlist
video-dl doctor
video-dl install-deps
video-dl update
video-dl settings
video-dl config
```

## Organização dos arquivos

Vídeo avulso fica direto no destino escolhido:

```text
Videos\video-dl\
└── 2026-09-11 - Título original [ID].mp4
```

O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual. Por padrão, vídeos também recebem a resolução real no nome, por exemplo `[1080p]`.

No modo série, você cola os links um por um e o programa tenta deduzir série, temporada e episódio por metadados, título da página e padrões como `S01E05`, `1x05` ou `Temporada 1 Episódio 5`:

```text
Videos\video-dl\
└── Bob Esponja\
    └── Season 01\
        ├── S01E01 - Título.mp4
        ├── S01E02 - Título.mp4
        └── S01E03 - Título.mp4
```

Se algum dado não puder ser determinado com segurança, ele pergunta. Dentro da mesma sessão, série/temporada e o próximo número de episódio são reaproveitados quando fizer sentido.

`--playlist` é separado de `--series`: ele serve para playlists nativas suportadas pelo `yt-dlp`, como uma playlist do YouTube.

## Destinos

Você pode salvar vários destinos e escolher entre dois comportamentos: perguntar quando houver mais de um destino ou usar um deles automaticamente.

```powershell
video-dl --add-path "D:\Series" --name Series
video-dl --paths
video-dl set-default Series
video-dl unset-default
```

`set-default <nome>` faz o `video-dl` usar esse destino automaticamente, sem perguntar. `unset-default` volta ao modo de perguntar. `--path <nome|caminho>` e `--here` continuam servindo como exceções para um download específico.

## Qualidade

Por padrão, vídeos baixados via `yt-dlp` ficam limitados a **1080p** e priorizam **MP4 + H.264 + AAC** para boa compatibilidade. Se 1080p não existir, cai automaticamente para uma resolução menor.

```powershell
video-dl "URL" --quality 720
video-dl "URL" --max-quality
video-dl "URL" --max-quality --wpp
```

## Áudio

```powershell
video-dl "URL" --audio
video-dl "URL" --audio --audio-format m4a
```

O padrão é MP3. Você pode mudar apenas um download ou salvar outro padrão:

```powershell
video-dl "URL" --audio --audio-format opus
video-dl set-audio-format opus
```

Formatos aceitos: `mp3`, `m4a`, `aac`, `opus`, `flac` e `wav`.

## Container de vídeo

O padrão é **MP4**. Streams baixados via Streamlink/Pluto são recebidos como TS temporário e remuxados com FFmpeg, sem re-encode e sem perda de qualidade.

```powershell
video-dl "URL" --container mkv
video-dl set-container mkv
video-dl set-container mp4
```

Se um stream não puder ser remuxado para MP4 sem recodificar, o `video-dl` tenta MKV. Se FFmpeg não estiver disponível e a instalação for recusada, streams podem permanecer em `.ts` como fallback.

## Configuração

```powershell
video-dl settings
video-dl config
video-dl config show
video-dl config path
```

`video-dl config` abre `%USERPROFILE%\\.video-dl\\config.json`. O programa usa `VIDEO_DL_EDITOR` ou `EDITOR` quando definidos, depois tenta VS Code e por fim o Bloco de Notas. É possível editar manualmente destinos, `videoContainer` e `audioFormat`. Valores inválidos não sobrescrevem silenciosamente o arquivo; o programa informa o erro para que ele seja corrigido.

## Qualidade no nome e arquivos repetidos

Por padrão, o vídeo final recebe a resolução no nome (`[720p]`, `[1080p]`, `[1440p]`, `[2160p]` etc.). O yt-dlp usa a altura do formato selecionado; Streamlink, Pluto e Threads confirmam o arquivo final com `ffprobe` quando disponível.

```powershell
video-dl set-quality-name off
video-dl set-quality-name on
```

Arquivos repetidos usam `skip` por padrão. É possível mudar o comportamento:

```powershell
video-dl set-duplicate-policy skip
video-dl set-duplicate-policy ask
video-dl set-duplicate-policy overwrite
video-dl set-duplicate-policy rename
```

`ask` oferece pular, substituir ou criar cópia. `rename` cria `(2)`, `(3)` etc. Em playlists nativas, `overwrite` é respeitado; os outros modos deixam o yt-dlp pular colisões item a item.

## Sites

A ideia é não exigir um comando diferente para cada site: o link é roteado automaticamente. YouTube, TikTok, Instagram, Facebook e outros sites suportados passam primeiro pelo `yt-dlp`; streams podem cair para Streamlink; Pluto TV e Threads têm tratamento adicional.

Suporte real depende dos extratores das ferramentas usadas e pode quebrar temporariamente quando um site muda internamente.

## Dependências

```powershell
video-dl doctor
video-dl install-deps
```

Quando necessário, o programa pode oferecer instalação de `yt-dlp`, FFmpeg, Streamlink e Threads CLI.

## Código e releases

Os scripts ficam em [`src/`](src/). O instalador Windows também é gerado automaticamente pelo GitHub Actions e publicado em **Releases** como `video-dl-setup.exe`, mas a instalação por PowerShell não depende dele.

