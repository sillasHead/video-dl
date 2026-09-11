from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"missing {label}")
    return text.replace(old, new, 1)


def replace_block(text: str, start: str, end: str, new: str, label: str) -> str:
    a = text.find(start)
    if a < 0:
        raise RuntimeError(f"missing start {label}")
    b = text.find(end, a)
    if b < 0:
        raise RuntimeError(f"missing end {label}")
    return text[:a] + new.rstrip() + "\n\n" + text[b:]


main_path = Path("src/video-dl.ps1")
pluto_path = Path("src/pluto-dl.ps1")
readme_path = Path("README.md")
iss_path = Path("installer/video-dl.iss")
version_path = Path("VERSION")

main = main_path.read_text(encoding="utf-8")
pluto = pluto_path.read_text(encoding="utf-8")
readme = readme_path.read_text(encoding="utf-8")
iss = iss_path.read_text(encoding="utf-8")

main = replace_once(main, '$Version = "0.4.2"', '$Version = "0.4.3"', "main version")
main = replace_once(
    main,
    '$yt = Get-YtDlpMetadata $Url $CookieBrowser $CookieFile',
    '$yt = if ((Get-SiteKind $Url) -eq "pluto") { $null } else { Get-YtDlpMetadata $Url $CookieBrowser $CookieFile }',
    "skip yt-dlp metadata probe for Pluto",
)

old_invoke_pluto = '''function Invoke-Pluto([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer, [bool]$SeriesMode) {
    if (-not (Ensure-Dependency "streamlink" "Pluto TV")) { return 127 }
    if ($AudioOnly -and -not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
    if (-not $AudioOnly -and -not (Test-Dependency "ffmpeg")) {
        Write-Warn "FFmpeg é necessário para finalizar o vídeo em $VideoContainer."
        $answer = Read-Host "Instalar FFmpeg agora? [S/n]"
        if (Test-Yes $answer $true) { [void](Install-Ffmpeg) }
        if (-not (Test-Dependency "ffmpeg")) { Write-Warn "Sem FFmpeg, a Pluto será salva em .ts como fallback." }
    }
    if (-not (Test-Path -LiteralPath $PlutoDlPath)) { throw "pluto-dl.ps1 não encontrado." }
    & $PlutoDlPath -Url $Url -OutputRoot $OutputDir -AudioOnly:$AudioOnly -AudioFormat $AudioFormat -VideoContainer $VideoContainer -SeriesMode:$SeriesMode
    if ($?) { return 0 }
    return 1
}'''
new_invoke_pluto = '''function Invoke-Pluto(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer, [bool]$SeriesMode,
    [string]$SeriesName = $null, [Nullable[int]]$SeasonNumber = $null, [Nullable[int]]$EpisodeNumber = $null
) {
    if (-not (Ensure-Dependency "streamlink" "Pluto TV")) { return 127 }
    if ($AudioOnly -and -not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
    if (-not $AudioOnly -and -not (Test-Dependency "ffmpeg")) {
        Write-Warn "FFmpeg é necessário para finalizar o vídeo em $VideoContainer."
        $answer = Read-Host "Instalar FFmpeg agora? [S/n]"
        if (Test-Yes $answer $true) { [void](Install-Ffmpeg) }
        if (-not (Test-Dependency "ffmpeg")) { Write-Warn "Sem FFmpeg, a Pluto será salva em .ts como fallback." }
    }
    if (-not (Test-Path -LiteralPath $PlutoDlPath)) { throw "pluto-dl.ps1 não encontrado." }

    $plutoArgs = @{
        Url = $Url
        OutputRoot = $OutputDir
        AudioOnly = $AudioOnly
        AudioFormat = $AudioFormat
        VideoContainer = $VideoContainer
        SeriesMode = $SeriesMode
    }
    if (-not [string]::IsNullOrWhiteSpace($SeriesName)) { $plutoArgs.SeriesName = $SeriesName }
    if ($null -ne $SeasonNumber) { $plutoArgs.SeasonNumber = [int]$SeasonNumber }
    if ($null -ne $EpisodeNumber) { $plutoArgs.EpisodeNumber = [int]$EpisodeNumber }

    & $PlutoDlPath @plutoArgs
    if ($?) { return 0 }
    return 1
}'''
main = replace_once(main, old_invoke_pluto, new_invoke_pluto, "Invoke-Pluto")

main = replace_once(
    main,
    'function Resolve-SeriesInfo([object]$Metadata, [object]$State) {',
    'function Resolve-SeriesInfo([object]$Metadata, [object]$State, [bool]$AutoSequence = $false) {',
    "Resolve-SeriesInfo signature",
)
main = replace_once(
    main,
    '''    $episode = $Metadata.EpisodeNumber
    if ($null -eq $episode) {
        $next = $null
        if ($null -ne $State.LastEpisode -and $null -ne $State.Season -and [int]$State.Season -eq [int]$season) { $next = [int]$State.LastEpisode + 1 }
        $episode = Read-RequiredNumber "Número do episódio" $next
    }''',
    '''    $episode = $Metadata.EpisodeNumber
    if ($null -eq $episode) {
        $next = $null
        if ($null -ne $State.LastEpisode -and $null -ne $State.Season -and [int]$State.Season -eq [int]$season) { $next = [int]$State.LastEpisode + 1 }
        if ($AutoSequence -and $null -ne $next) { $episode = [int]$next }
        else { $episode = Read-RequiredNumber "Número do episódio" $next }
    }''',
    "series automatic sequencing",
)

old_series_header = '''function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile
) {
    $kind = Get-SiteKind $Url
    if ($kind -eq "pluto") {
        return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $VideoContainer $true)
    }

    if (-not (Test-Dependency "yt-dlp")) { [void](Ensure-Dependency "yt-dlp" "detecção de metadados de séries") }
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State
    $sourceId = [string]$metadata.Id
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
'''
new_series_header = '''function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$AutoSequence = $false
) {
    $kind = Get-SiteKind $Url

    if ($kind -ne "pluto" -and -not (Test-Dependency "yt-dlp")) { [void](Ensure-Dependency "yt-dlp" "detecção de metadados de séries") }
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State $AutoSequence

    if ($kind -eq "pluto") {
        return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $VideoContainer $true $info.Series $info.Season $info.Episode)
    }

    $sourceId = [string]$metadata.Id
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
'''
main = replace_once(main, old_series_header, new_series_header, "Invoke-SeriesItem header")

batch_helpers = r'''function Resolve-ListUrls([object[]]$Items) {
    $values = @($Items | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }

    if ($values.Count -eq 1 -and [System.IO.Path]::GetExtension($values[0]) -ieq ".txt") {
        $listPath = Normalize-Path $values[0]
        if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { throw "Arquivo de lista não encontrado: $($values[0])" }
        $values = @(Get-Content -LiteralPath $listPath -Encoding UTF8 | ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") })
        if ($values.Count -eq 0) { throw "O arquivo de lista não contém URLs." }
    }

    return @($values)
}

function Write-BatchSummary([int]$Total, [int]$Succeeded, [int]$Failed) {
    Write-Host ""
    Write-Host "Resumo da lista:"
    Write-Host "  Total:                 $Total"
    Write-Host "  Concluídos/ignorados:  $Succeeded"
    Write-Host "  Falharam:              $Failed"
}

function Invoke-BatchSession([object]$Parsed) {
    if ($Parsed.Loop) { throw "--list e --loop não podem ser usados juntos." }
    $urls = @(Resolve-ListUrls $Parsed.ListItems)
    $resolvedOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $succeeded = 0
    $failed = 0

    Write-Info "video-dl - lista ($($urls.Count) links)"
    for ($index = 0; $index -lt $urls.Count; $index++) {
        $url = [string]$urls[$index]
        Write-Host ""
        Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
        try {
            $code = Invoke-OneDownload $url $Parsed.RequestedPath $Parsed.Here $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Playlist $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
            else { $failed++; Write-Fail "Item não concluído (código $code)." }
        } catch {
            $failed++
            Write-Fail "Item não concluído: $($_.Exception.Message)"
        }
    }

    Write-BatchSummary $urls.Count $succeeded $failed
    if ($failed -gt 0) { return 1 }
    return 0
}
'''
main = replace_once(main, 'function Invoke-SeriesSession([object]$Parsed) {', batch_helpers + '\nfunction Invoke-SeriesSession([object]$Parsed) {', "batch helpers insertion")

old_series_session = '''function Invoke-SeriesSession([object]$Parsed) {
    if ($Parsed.Playlist) { throw "--series e --playlist representam coisas diferentes e não podem ser usados juntos." }
    $baseOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $state = [PSCustomObject]@{ Name = $null; Season = $null; LastEpisode = $null }

    Write-Info "video-dl - modo série"
    Write-Host "Destino base: $baseOutput"
    Write-Host "O programa tenta detectar série, temporada e episódio pelos metadados."

    $url = [string]$Parsed.Url
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($url)) { $url = Read-Host "`nURL do próximo episódio (Enter para sair)" }
        if ([string]::IsNullOrWhiteSpace($url)) { break }
        $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile
        if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        $url = $null
    }
}'''
new_series_session = '''function Invoke-SeriesSession([object]$Parsed) {
    if ($Parsed.Playlist) { throw "--series e --playlist representam coisas diferentes e não podem ser usados juntos." }
    if ($Parsed.Loop -and @($Parsed.ListItems).Count -gt 0) { throw "--list e --loop não podem ser usados juntos." }
    $baseOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $state = [PSCustomObject]@{ Name = $null; Season = $null; LastEpisode = $null }

    Write-Info "video-dl - modo série"
    Write-Host "Destino base: $baseOutput"
    Write-Host "O programa tenta detectar série, temporada e episódio pelos metadados."

    if (@($Parsed.ListItems).Count -gt 0) {
        $urls = @(Resolve-ListUrls $Parsed.ListItems)
        $succeeded = 0
        $failed = 0
        Write-Host "Lista: $($urls.Count) links"

        for ($index = 0; $index -lt $urls.Count; $index++) {
            $url = [string]$urls[$index]
            Write-Host ""
            Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
            try {
                $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $true
                if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
                else { $failed++; Write-Fail "Item não concluído (código $code)." }
            } catch {
                $failed++
                Write-Fail "Item não concluído: $($_.Exception.Message)"
            }
        }

        Write-BatchSummary $urls.Count $succeeded $failed
        if ($failed -gt 0) { return 1 }
        return 0
    }

    $url = [string]$Parsed.Url
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($url)) { $url = Read-Host "`nURL do próximo episódio (Enter para sair)" }
        if ([string]::IsNullOrWhiteSpace($url)) { break }
        $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $false
        if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        $url = $null
    }
    return 0
}'''
main = replace_once(main, old_series_session, new_series_session, "Invoke-SeriesSession")

main = replace_once(
    main,
    '''  video-dl "URL"                  baixa um vídeo avulso
  video-dl --series               modo série: cole os episódios um por um
  video-dl "URL" --series         começa a série por essa URL e pede as próximas
  video-dl                         modo interativo de vídeos avulsos''',
    '''  video-dl "URL"                  baixa um vídeo avulso
  video-dl --list links.txt        baixa uma lista de URLs de um arquivo TXT
  video-dl --list "URL1" "URL2"   baixa várias URLs passadas no próprio comando
  video-dl --list links.txt --series  processa a lista como episódios de uma série
  video-dl --series               modo série: cole os episódios um por um
  video-dl "URL" --series         começa a série por essa URL e pede as próximas
  video-dl                         modo interativo de vídeos avulsos''',
    "help usage list",
)
main = replace_once(
    main,
    '''OUTROS
  --series                        organiza vários links como episódios de uma série
  --playlist                      baixa playlist nativa do site via yt-dlp''',
    '''OUTROS
  --list <arquivo.txt|URLs...>     processa várias URLs; aceita TXT ou URLs no comando
  --series                        organiza vários links como episódios de uma série
  --playlist                      baixa playlist nativa do site via yt-dlp''',
    "help other list",
)

main = replace_once(
    main,
    '''        Url = $null; RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = $null; VideoContainer = $null;
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
        Compat = $true; CookieBrowser = $null; CookieFile = $null''',
    '''        Url = $null; ListItems = @(); RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = $null; VideoContainer = $null;
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
        Compat = $true; CookieBrowser = $null; CookieFile = $null''',
    "parser ListItems property",
)
main = replace_once(
    main,
    '''            "--playlist" { $r.Playlist = $true }
            "--series" { $r.Series = $true }''',
    '''            "--playlist" { $r.Playlist = $true }
            "--list" {
                $listValues = @()
                while (($i + 1) -lt $Tokens.Count -and -not ([string]$Tokens[$i + 1]).StartsWith("-")) {
                    $i++
                    $listValues += [string]$Tokens[$i]
                }
                if ($listValues.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }
                $r.ListItems = @($r.ListItems) + @($listValues)
            }
            "--series" { $r.Series = $true }''',
    "parser list option",
)
main = replace_once(
    main,
    '''    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    if ($r.VideoContainer -and $r.VideoContainer -notin @("mp4", "mkv")) { throw "--container aceita: mp4 ou mkv." }''',
    '''    if (@($r.ListItems).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.Url)) { throw "Use uma URL posicional ou --list, não os dois ao mesmo tempo." }
    if (@($r.ListItems).Count -gt 0 -and $r.Loop) { throw "--list e --loop não podem ser usados juntos." }
    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    if ($r.VideoContainer -and $r.VideoContainer -notin @("mp4", "mkv")) { throw "--container aceita: mp4 ou mkv." }''',
    "parser list validation",
)

main = replace_once(
    main,
    '''    if ($parsed.Series) {
        Invoke-SeriesSession $parsed
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$parsed.Url)) {''',
    '''    if ($parsed.Series) {
        $seriesCode = Invoke-SeriesSession $parsed
        if ($seriesCode -ne 0) { exit $seriesCode }
        return
    }

    if (@($parsed.ListItems).Count -gt 0) {
        $batchCode = Invoke-BatchSession $parsed
        if ($batchCode -ne 0) { exit $batchCode }
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$parsed.Url)) {''',
    "top-level batch routing",
)

# Pluto can receive already-resolved series metadata from the batch/session engine.
pluto = replace_once(
    pluto,
    '''    [ValidateSet("mp4", "mkv")]
    [string]$VideoContainer = "mp4",

    [switch]$SeriesMode
)''',
    '''    [ValidateSet("mp4", "mkv")]
    [string]$VideoContainer = "mp4",

    [switch]$SeriesMode,

    [string]$SeriesName,

    [Nullable[int]]$SeasonNumber,

    [Nullable[int]]$EpisodeNumber
)''',
    "Pluto parameters",
)
pluto = replace_once(
    pluto,
    '''if ([string]::IsNullOrWhiteSpace($series)) { $series = "Pluto TV" }
if ([string]::IsNullOrWhiteSpace($title)) { $title = "Episódio" }''',
    '''if (-not [string]::IsNullOrWhiteSpace($SeriesName)) { $series = $SeriesName }
if ([string]::IsNullOrWhiteSpace($series)) { $series = "Pluto TV" }
if ([string]::IsNullOrWhiteSpace($title)) { $title = "Episódio" }''',
    "Pluto series override",
)
pluto = replace_once(
    pluto,
    '''$season = $seasonFromUrl
$episode = $null''',
    '''$season = if ($null -ne $SeasonNumber) { [int]$SeasonNumber } else { $seasonFromUrl }
$episode = if ($null -ne $EpisodeNumber) { [int]$EpisodeNumber } else { $null }''',
    "Pluto episode overrides",
)

# README: examples + a dedicated batch section.
readme = replace_once(
    readme,
    '''video-dl "URL" --cookies auto
video-dl --series
video-dl "URL" --series''',
    '''video-dl "URL" --cookies auto
video-dl --list links.txt
video-dl --list "URL1" "URL2" "URL3"
video-dl --list links.txt --series
video-dl --series
video-dl "URL" --series''',
    "README examples",
)
list_section = '''## Listas de links

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

'''
readme = replace_once(readme, '## Destinos\n', list_section + '## Destinos\n', "README list section")

iss = replace_once(iss, '#define MyAppVersion "0.4.2"', '#define MyAppVersion "0.4.3"', "Inno default version")

main_path.write_text(main, encoding="utf-8")
pluto_path.write_text(pluto, encoding="utf-8")
readme_path.write_text(readme, encoding="utf-8")
iss_path.write_text(iss, encoding="utf-8")
version_path.write_text("0.4.3\n", encoding="utf-8")
