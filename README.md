# video-dl

> yt-dlp com menos sofrimento.

Downloader universal para Windows/PowerShell, usando `yt-dlp`, Streamlink e fallbacks específicos quando necessário.

## Instalar

Abra o PowerShell e rode:

```powershell
irm https://raw.githubusercontent.com/sillasHead/video-dl/main/install.ps1 | iex
```

O instalador baixa a versão mais recente, atualiza uma instalação anterior e preserva suas configurações em `%USERPROFILE%\.video-dl`.

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
video-dl doctor
video-dl install-deps
```

Por padrão, vídeos baixados via yt-dlp ficam limitados a 1080p e priorizam MP4/H.264/AAC para boa compatibilidade. O programa tenta instalar as dependências necessárias quando elas estiverem ausentes.

## Sites

A ideia é não exigir um comando diferente para cada site: o link é roteado automaticamente. YouTube e sites genéricos passam primeiro pelo `yt-dlp`; streams podem cair para Streamlink; Pluto TV e Threads têm tratamento adicional.

Suporte real depende dos extratores das ferramentas usadas e pode quebrar temporariamente quando um site muda internamente.

## Código

Os scripts ficam em [`src/`](src/). O instalador Windows é gerado automaticamente pelo GitHub Actions e publicado em **Releases** como `video-dl-setup.exe`.

## Status

Projeto em desenvolvimento. O modo de séries genérico, com detecção de série/temporada/episódio por metadados, está sendo preparado para uma próxima versão.
