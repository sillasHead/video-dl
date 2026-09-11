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
```

## Organização dos arquivos

Vídeo avulso fica direto no destino escolhido:

```text
Videos\video-dl\
└── 2026-09-11 - Título original [ID].mp4
```

O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual.

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

O padrão é MP3.

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
