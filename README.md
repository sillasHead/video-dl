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
video-dl --list links.txt
video-dl --list "URL1" "URL2" "URL3"
video-dl --list links.txt --series
video-dl --list wcostream.txt --series
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
└── 2026-09-11 - Título original [1080p].mp4
```

O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual. Por padrão, vídeos também recebem a resolução real no nome, por exemplo `[1080p]`. IDs técnicos do site ficam fora do nome do arquivo.

No modo série, você cola os links um por um e o programa tenta deduzir série, temporada e episódio por metadados, título da página e padrões comuns como `S01E05`, `S1.E5`, `1x05`, `Season 1 Episode 5`, `Season 1 Ep 5`, `T1E5` e `Temporada 1 Episódio 5`:

```text
Videos\video-dl\
└── Bob Esponja\
    └── Season 01\
        ├── S01E01 - Título.mp4
        ├── S01E02 - Título.mp4
        └── S01E03 - Título.mp4
```

A prioridade é: metadados estruturados do site/downloader, informações explícitas da página, padrões reconhecidos no título e, só então, pergunta/sequência automática. Números ambíguos como `102` não são convertidos automaticamente em `S01E02`. Na Pluto, temporada e episódio são consultados primeiro pela API de catálogo da própria Pluto; a página fica apenas como fallback estruturado, evitando falsos positivos encontrados no HTML bruto.

Se algum dado não puder ser determinado com segurança, ele pergunta. Dentro da mesma sessão, série/temporada e o próximo número de episódio são reaproveitados quando fizer sentido.

`--playlist` é separado de `--series`: ele serve para playlists nativas suportadas pelo `yt-dlp`, como uma playlist do YouTube.

## Listas de links

`--list` aceita tanto um arquivo `.txt` quanto várias URLs passadas diretamente no comando:

```powershell
video-dl --list links.txt
video-dl --list "URL1" "URL2" "URL3"
video-dl --quality 1080 --list "URL1" "URL2"
video-dl --audio --list links.txt
```

No TXT, use uma URL por linha. Linhas vazias e linhas iniciadas por `#` são ignoradas. Uma falha não interrompe os demais itens; ao final, o programa mostra um resumo do lote. O mesmo destino é resolvido uma única vez para a lista inteira.

Também é possível combinar a lista com o modo série:

```powershell
video-dl --list episodios.txt --series
video-dl --series --list "URL1" "URL2" "URL3"
```

Nesse modo, metadados confiáveis de temporada/episódio continuam tendo prioridade. Quando o site não informa o número do episódio, o primeiro item pede o número necessário e os próximos seguem a sequência automaticamente. O histórico interno continua identificando conteúdos já baixados.

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

O `video-dl` mantém um histórico interno em `%USERPROFILE%\.video-dl\downloads.json`. Assim, o ID do site não precisa aparecer no nome: se a mesma mídia for enviada novamente, o programa reconhece a identidade e aplica `skip`, `ask`, `overwrite` ou `rename`. Se **outra mídia** tiver exatamente o mesmo nome, ambas são preservadas e a nova recebe `(2)`, `(3)` etc.

Ao encontrar arquivos antigos no padrão com `[ID]`, o programa tenta remover esse ID do nome e registrar o arquivo no histórico sem baixá-lo de novo. Em playlists nativas, o índice da playlist continua evitando a maioria das colisões e o yt-dlp trata cada item.

## Sites

A ideia é não exigir um comando diferente para cada site: o link é roteado automaticamente. YouTube, TikTok, Instagram, Facebook e outros sites suportados passam primeiro pelo `yt-dlp`; streams podem cair para Streamlink; Pluto TV, Threads e WCOStream têm tratamento adicional.

No WCOStream, o `video-dl` resolve automaticamente o player embed, o endpoint `getvidlink.php`, a URL temporária do vídeo e baixa o MP4 com os headers exigidos pelo servidor. Para vários episódios, use uma URL por linha em um TXT e rode `video-dl --list wcostream.txt --series`.

Suporte real depende dos extratores das ferramentas usadas e pode quebrar temporariamente quando um site muda internamente.

## Dependências

```powershell
video-dl doctor
video-dl install-deps
```

Quando necessário, o programa pode oferecer instalação de `yt-dlp`, FFmpeg, Streamlink e Threads CLI.

## Código e releases

Os scripts ficam em [`src/`](src/). O instalador Windows também é gerado automaticamente pelo GitHub Actions e publicado em **Releases** como `video-dl-setup.exe`, mas a instalação por PowerShell não depende dele.

