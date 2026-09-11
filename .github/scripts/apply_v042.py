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


branch_files = {
    "main": Path("src/video-dl.ps1"),
    "pluto": Path("src/pluto-dl.ps1"),
    "threads": Path("src/th-dl.ps1"),
    "setup": Path("setup.ps1"),
    "iss": Path("installer/video-dl.iss"),
    "readme": Path("README.md"),
    "version": Path("VERSION"),
}

# ---- main dispatcher ----
p = branch_files["main"]
s = p.read_text(encoding="utf-8-sig")
s = replace_once(s, '$Version = "0.4.1"', '$Version = "0.4.2"', "main version")
s = replace_once(
    s,
    '$ThDlPath = Join-Path $ScriptRoot "th-dl.ps1"\n$script:YtDlpUnsupportedHosts = @{}',
    '$ThDlPath = Join-Path $ScriptRoot "th-dl.ps1"\n$ArchiveHelperPath = Join-Path $ScriptRoot "archive.ps1"\nif (-not (Test-Path -LiteralPath $ArchiveHelperPath -PathType Leaf)) { throw "archive.ps1 não encontrado." }\n. $ArchiveHelperPath\n$script:YtDlpUnsupportedHosts = @{}',
    "source archive helper",
)
s = replace_once(
    s,
    'if ([string]::IsNullOrWhiteSpace($OutputTemplate)) { $OutputTemplate = "%(title).180B [%(id)s].%(ext)s" }',
    'if ([string]::IsNullOrWhiteSpace($OutputTemplate)) { $OutputTemplate = "%(title).180B.%(ext)s" }',
    "default yt-dlp template",
)

new_generic = r'''function Invoke-GenericStreamlink(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat,
    [string]$VideoContainer, [string]$FileBase, [string]$Identity, [string]$SourceId
) {
    if (-not (Ensure-Dependency "streamlink" "fallback para streams")) { return 127 }
    if ([string]::IsNullOrWhiteSpace($FileBase)) { $FileBase = (Get-Date -Format "yyyy-MM-dd") + " - stream-" + (Get-Date -Format "HHmmss") }
    $FileBase = Safe-Name $FileBase
    if ([string]::IsNullOrWhiteSpace($Identity)) { $Identity = Get-VideoDlIdentity (Get-UrlHost $Url) $SourceId $Url }

    if ($AudioOnly) {
        if (-not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
        $desired = Join-Path $OutputDir ($FileBase + "." + $AudioFormat)
        $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
        if ($decision.Skip) { return 0 }
        $target = [string]$decision.Path
        $FileBase = [System.IO.Path]::GetFileNameWithoutExtension($target)
        $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
        $code = Invoke-Streamlink @($Url, "best", "-o", $temp)
        if ($code -ne 0) { Remove-Item $temp -Force -ErrorAction SilentlyContinue; return $code }
        $ffArgs = @("-y", "-i", $temp, "-vn")
        switch ($AudioFormat.ToLowerInvariant()) {
            "mp3" { $ffArgs += @("-c:a", "libmp3lame", "-q:a", "0") }
            "m4a" { $ffArgs += @("-c:a", "aac", "-b:a", "192k") }
            "aac" { $ffArgs += @("-c:a", "aac", "-b:a", "192k") }
            "opus" { $ffArgs += @("-c:a", "libopus", "-b:a", "160k") }
            "wav" { $ffArgs += @("-c:a", "pcm_s16le") }
            "flac" { $ffArgs += @("-c:a", "flac") }
        }
        $ffArgs += $target
        & ffmpeg @ffArgs | Out-Host
        $ffCode = [int]$LASTEXITCODE
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
        if ($ffCode -eq 0 -and (Test-Path -LiteralPath $target -PathType Leaf)) { Register-VideoDlDownload $Identity $target $Url $SourceId }
        return $ffCode
    }

    $hasFfmpeg = Ensure-Dependency "ffmpeg" "saída de vídeo em $VideoContainer"
    if (-not $hasFfmpeg) {
        Write-Warn "FFmpeg não disponível; salvando o stream original em .ts."
        $desired = Join-Path $OutputDir ($FileBase + ".ts")
        $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
        if ($decision.Skip) { return 0 }
        $target = [string]$decision.Path
        $code = Invoke-Streamlink @($Url, "best", "-o", $target)
        if ($code -eq 0 -and (Test-Path -LiteralPath $target -PathType Leaf)) { Register-VideoDlDownload $Identity $target $Url $SourceId }
        return $code
    }

    $desired = Join-Path $OutputDir ($FileBase + "." + $VideoContainer)
    $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
    if ($decision.Skip) { return 0 }
    $target = [string]$decision.Path
    $FileBase = [System.IO.Path]::GetFileNameWithoutExtension($target)
    $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
    $code = Invoke-Streamlink @($Url, "best", "-o", $temp)
    if ($code -ne 0) { Remove-Item $temp -Force -ErrorAction SilentlyContinue; return $code }

    $ffArgs = @("-y", "-i", $temp, "-map", "0", "-c", "copy")
    if ($VideoContainer -eq "mp4") { $ffArgs += @("-movflags", "+faststart") }
    $ffArgs += $target
    & ffmpeg @ffArgs | Out-Host
    $ffCode = [int]$LASTEXITCODE

    if ($ffCode -ne 0 -and $VideoContainer -eq "mp4") {
        Write-Warn "O stream não pôde ser remuxado para MP4. Tentando MKV sem re-encode..."
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        $desiredMkv = Join-Path $OutputDir ($FileBase + ".mkv")
        $mkvDecision = Resolve-VideoDlTarget $Identity $desiredMkv $Url $SourceId $false
        if ($mkvDecision.Skip) { Remove-Item $temp -Force -ErrorAction SilentlyContinue; return 0 }
        $target = [string]$mkvDecision.Path
        & ffmpeg -y -i $temp -map 0 -c copy $target | Out-Host
        $ffCode = [int]$LASTEXITCODE
    }
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    if ($ffCode -eq 0 -and (Test-Path -LiteralPath $target -PathType Leaf)) {
        $target = Add-QualitySuffix $target
        Register-VideoDlDownload $Identity $target $Url $SourceId
    }
    return $ffCode
}'''
s = replace_block(s, "function Invoke-GenericStreamlink", "function Invoke-Pluto", new_generic, "generic streamlink")

new_naming = r'''function Get-AvulsoNaming([string]$Url, [string]$CookieBrowser, [string]$CookieFile) {
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $false
    $date = if ($null -ne $metadata) { [string]$metadata.Date } else { Get-Date -Format "yyyy-MM-dd" }
    $title = if ($null -ne $metadata) { [string]$metadata.Title } else { "Vídeo" }
    $sourceId = if ($null -ne $metadata) { [string]$metadata.Id } else { $null }
    $fileBase = "$date - $(Safe-Name $title 155)"
    $template = "$fileBase.%(ext)s"
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
    return [PSCustomObject]@{
        Metadata = $metadata
        FileBase = $fileBase
        Template = $template
        Identity = $identity
        SourceId = $sourceId
    }
}

function Register-YtDlpResult([string]$Identity, [string]$Url, [string]$SourceId, [string]$OutputDir, [string]$FileBase) {
    $result = Find-VideoDlOutputForBase $OutputDir $FileBase
    if ($null -ne $result) { Register-VideoDlDownload $Identity $result.FullName $Url $SourceId }
}'''
s = replace_block(s, "function Get-AvulsoNaming", "function Invoke-OneDownload", new_naming, "standalone naming")

new_one = r'''function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$ResolvedOutput
) {
    $output = if ([string]::IsNullOrWhiteSpace($ResolvedOutput)) { Resolve-OutputPath $RequestedPath $Here } else { $ResolvedOutput }
    Ensure-Directory $output
    Write-Host ""
    Write-Host "Destino: $output"
    $kind = Get-SiteKind $Url

    if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat $VideoContainer $false) }

    if ($Playlist) {
        $playlistTemplate = "%(playlist_title).120B\%(playlist_index)03d - %(title).150B.%(ext)s"
        return (Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $true $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $playlistTemplate)
    }

    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $naming.Identity $desiredPath $Url $naming.SourceId $false
    if ($decision.Skip) { return 0 }
    $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $naming.Template = "$($naming.FileBase).%(ext)s"

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
    }

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $naming.Template
        if ($code -eq 0) {
            Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase)
    }

    $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $naming.Template
    if ($code -eq 0) {
        Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
}'''
s = replace_block(s, "function Invoke-OneDownload", "function Read-RequiredText", new_one, "standalone download")

new_series = r'''function Invoke-SeriesItem(
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

    $seriesFolder = Join-Path $BaseOutput (Safe-Name $info.Series 120)
    $seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f $info.Season)
    Ensure-Directory $seasonFolder
    $prefix = "S{0:D2}E{1:D2}" -f $info.Season, $info.Episode
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $seasonFolder ($fallbackBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $identity $desiredPath $Url $sourceId $false
    if ($decision.Skip) { return 0 }
    $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $template = "$fallbackBase.%(ext)s"

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    Write-Host ""
    Write-Host "Série:     $($info.Series)"
    Write-Host "Temporada: $($info.Season)"
    Write-Host "Episódio:  $($info.Episode)"
    Write-Host "Título:    $($info.Title)"
    Write-Host "Destino:   $seasonFolder"

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $template
        if ($code -eq 0) {
            Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase)
    }

    $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $template
    if ($code -eq 0) {
        Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
}'''
s = replace_block(s, "function Invoke-SeriesItem", "function Invoke-SeriesSession", new_series, "series download")
s = replace_once(s, "  Avulso:  AAAA-MM-DD - Título original [ID].ext", "  Avulso:  AAAA-MM-DD - Título original [1080p].ext", "help naming")
p.write_text(s, encoding="utf-8")

# ---- Pluto helper ----
p = branch_files["pluto"]
s = p.read_text(encoding="utf-8-sig")
s = replace_once(
    s,
    '$ErrorActionPreference = "Stop"\n$ConfigDir = Join-Path $HOME ".video-dl"',
    '$ErrorActionPreference = "Stop"\n$ArchiveHelperPath = Join-Path $PSScriptRoot "archive.ps1"\nif (-not (Test-Path -LiteralPath $ArchiveHelperPath -PathType Leaf)) { throw "archive.ps1 não encontrado." }\n. $ArchiveHelperPath\n$ConfigDir = Join-Path $HOME ".video-dl"',
    "pluto source archive",
)
new_pluto_download = r'''function Download-Pluto([string]$Folder, [string]$FileBase, [string]$Identity, [string]$SourceId) {
    Ensure-Directory $Folder
    if ($AudioOnly) {
        $desired = Join-Path $Folder ($FileBase + "." + $AudioFormat)
        $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
        if ($decision.Skip) { return $decision.Path }
        $outputPath = [string]$decision.Path
        $tempPath = Join-Path $env:TEMP ("video-dl-pluto-" + [Guid]::NewGuid().ToString("N") + ".ts")
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $tempPath)
        if ($code -ne 0) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; throw "O Streamlink terminou com código $code." }
        Convert-Audio $tempPath $outputPath $AudioFormat
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        Register-VideoDlDownload $Identity $outputPath $Url $SourceId
        return $outputPath
    }

    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        Write-Host "FFmpeg não disponível; salvando o stream original em .ts." -ForegroundColor Yellow
        $desired = Join-Path $Folder ($FileBase + ".ts")
        $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
        if ($decision.Skip) { return $decision.Path }
        $outputPath = [string]$decision.Path
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $outputPath)
        if ($code -ne 0) { throw "O Streamlink terminou com código $code." }
        Register-VideoDlDownload $Identity $outputPath $Url $SourceId
        return $outputPath
    }

    $desired = Join-Path $Folder ($FileBase + "." + $VideoContainer)
    $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
    if ($decision.Skip) { return $decision.Path }
    $outputPath = [string]$decision.Path
    $FileBase = [System.IO.Path]::GetFileNameWithoutExtension($outputPath)

    $tempPath = Join-Path $env:TEMP ("video-dl-pluto-" + [Guid]::NewGuid().ToString("N") + ".ts")
    $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $tempPath)
    if ($code -ne 0) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; throw "O Streamlink terminou com código $code." }

    $ffArgs = @("-y", "-i", $tempPath, "-map", "0", "-c", "copy")
    if ($VideoContainer -eq "mp4") { $ffArgs += @("-movflags", "+faststart") }
    $ffArgs += $outputPath
    & ffmpeg @ffArgs | Out-Host
    $ffCode = [int]$LASTEXITCODE

    if ($ffCode -ne 0 -and $VideoContainer -eq "mp4") {
        Write-Host "MP4 incompatível com este stream; tentando MKV sem re-encode..." -ForegroundColor Yellow
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        $desiredMkv = Join-Path $Folder ($FileBase + ".mkv")
        $mkvDecision = Resolve-VideoDlTarget $Identity $desiredMkv $Url $SourceId $false
        if ($mkvDecision.Skip) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; return $mkvDecision.Path }
        $outputPath = [string]$mkvDecision.Path
        & ffmpeg -y -i $tempPath -map 0 -c copy $outputPath | Out-Host
        $ffCode = [int]$LASTEXITCODE
    }
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    if ($ffCode -ne 0) { throw "FFmpeg não conseguiu remuxar o vídeo." }
    $outputPath = Add-QualitySuffix $outputPath
    Register-VideoDlDownload $Identity $outputPath $Url $SourceId
    return $outputPath
}'''
s = replace_block(s, "function Download-Pluto", "Ensure-Directory $OutputRoot", new_pluto_download, "pluto download")

pluto_tail = r'''Ensure-Directory $OutputRoot
$showId = $null
$episodeId = $null
$seasonFromUrl = $null
if ($Url -match '/(?:shows|on-demand/series)/([^/?]+)') { $showId = $Matches[1] }
if ($Url -match '/episode/([^/?]+)') { $episodeId = $Matches[1] }
if ($Url -match '/season/(\d+)') { $seasonFromUrl = [int]$Matches[1] }
$contentIdentity = Get-VideoDlIdentity "pluto" $episodeId $Url

Write-Host "Pluto: lendo metadados..."
$data = Get-StreamlinkMetadata $Url
$series = if ($null -ne $data.metadata) { [string]$data.metadata.author } else { $null }
$title = if ($null -ne $data.metadata) { [string]$data.metadata.title } else { $null }
if ([string]::IsNullOrWhiteSpace($series)) { $series = "Pluto TV" }
if ([string]::IsNullOrWhiteSpace($title)) { $title = "Episódio" }

if (-not $SeriesMode) {
    $date = Get-Date -Format "yyyy-MM-dd"
    $fileBase = "$date - $(Safe-Name $title)"
    Write-Host "Título:   $title"
    Write-Host "Destino:  $OutputRoot"
    $outputPath = Download-Pluto $OutputRoot (Safe-Name $fileBase) $contentIdentity $episodeId
    Write-Host ""
    Write-Host "Salvo: $outputPath" -ForegroundColor Green
    return
}

$season = $seasonFromUrl
$episode = $null
$combined = "$series $title"
if ($null -eq $season) {
    $m = [regex]::Match($combined, '\bS(?:eason)?\s*0*(\d+)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { $season = [int]$m.Groups[1].Value }
}
$mEpisode = [regex]::Match($combined, '\bE(?:pisode|p\.?)?\s*0*(\d+)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
if ($mEpisode.Success) { $episode = [int]$mEpisode.Groups[1].Value }

if ($null -eq $season -or $null -eq $episode) {
    $pageNumbers = Try-PageNumbers $Url
    if ($null -eq $season -and $null -ne $pageNumbers.season) { $season = [int]$pageNumbers.season }
    if ($null -eq $episode -and $null -ne $pageNumbers.episode) { $episode = [int]$pageNumbers.episode }
}

$state = @(Load-State)
$previous = if (-not [string]::IsNullOrWhiteSpace($showId)) { $state | Where-Object { $_.showId -eq $showId } | Select-Object -First 1 } else { $null }

if ($null -eq $season) {
    $seasonDefault = if ($null -ne $previous -and $null -ne $previous.season) { [int]$previous.season } else { 1 }
    $season = Read-Number "Temporada" $seasonDefault
}
if ($null -eq $episode) {
    $episodeDefault = $null
    if ($null -ne $previous -and $null -ne $previous.episode) {
        $sameSeason = ($null -eq $previous.season -or [int]$previous.season -eq [int]$season)
        if ($sameSeason) { $episodeDefault = [int]$previous.episode + 1 }
    }
    $episode = Read-Number "Número do episódio" $episodeDefault
}
if ($null -eq $episode) { $episode = Read-Number "Número do episódio" 1 }

$language = "unknown"
try {
    $uri = [Uri]$Url
    if ($uri.AbsolutePath -match '^/br/') { $language = "pt-BR" }
    elseif ($uri.AbsolutePath -match '^/us/') { $language = "en-US" }
} catch { }

$seriesFolder = Join-Path $OutputRoot (Safe-Name $series)
$seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f [int]$season)
Ensure-Directory $seasonFolder
$prefix = "S{0:D2}E{1:D2}" -f [int]$season, [int]$episode
$fileBase = Safe-Name ("{0} - {1}" -f $prefix, $title)

Write-Host ""
Write-Host "Série:     $series"
Write-Host "Temporada: $season"
Write-Host "Episódio:  $episode"
Write-Host "Idioma:     $language"
Write-Host "Destino:    $seasonFolder"

$outputPath = Download-Pluto $seasonFolder $fileBase $contentIdentity $episodeId
Update-State $showId $series $season $episode
Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green
'''
a = s.find("Ensure-Directory $OutputRoot")
if a < 0:
    raise RuntimeError("missing pluto tail")
s = s[:a] + pluto_tail
p.write_text(s, encoding="utf-8")

# ---- Threads helper ----
p = branch_files["threads"]
s = p.read_text(encoding="utf-8-sig")
s = replace_once(
    s,
    '$ErrorActionPreference = "Stop"\n',
    '$ErrorActionPreference = "Stop"\n$ArchiveHelperPath = Join-Path $PSScriptRoot "archive.ps1"\nif (-not (Test-Path -LiteralPath $ArchiveHelperPath -PathType Leaf)) { throw "archive.ps1 não encontrado." }\n. $ArchiveHelperPath\n',
    "threads source archive",
)
threads_tail = r'''if (-not (Get-Command th -ErrorAction SilentlyContinue)) { throw "O comando 'th' não foi encontrado." }
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

Write-Host "Fallback Threads: resolvendo URL..."
$resolvedUrl = Resolve-ThreadsUrl $Url
if ($resolvedUrl -notmatch 'threads\.(?:com|net)/@([^/]+)/post/([^/?]+)') { throw "Não foi possível identificar um post do Threads em: $resolvedUrl" }

$username = $Matches[1]
$shortcode = $Matches[2]
$postUrl = "https://www.threads.com/@$username/post/$shortcode"
$contentIdentity = Get-VideoDlIdentity "threads" $shortcode $postUrl
Write-Host "Post: @$username / $shortcode"
Write-Host "Extraindo mídia com th..."

$html = th post "$postUrl" --raw | Out-String
if (-not $html) { throw "O Threads não retornou HTML." }
$escapedCode = [regex]::Escape($shortcode)
$match = [regex]::Match($html, """code"":""$escapedCode"".*?""video_versions"":\[(?<versions>.*?)\]", [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $match.Success) { throw "Nenhum vídeo foi encontrado nesse post." }

$versions = ("[" + $match.Groups["versions"].Value + "]") | ConvertFrom-Json
if (-not $versions -or @($versions).Count -eq 0) { throw "Nenhuma versão de vídeo disponível foi encontrada." }
$video = $versions | Sort-Object { ([int]$_.width * [int]$_.height) } -Descending | Select-Object -First 1
$videoUrl = $video.url
if (-not $videoUrl) { throw "A URL do vídeo não pôde ser extraída." }
Write-Host "Qualidade: $($video.width)x$($video.height)"

if ([string]::IsNullOrWhiteSpace($FileBase)) {
    $FileBase = (Get-Date -Format "yyyy-MM-dd") + " - @${username}"
}
$FileBase = Safe-Name $FileBase

if ($AudioOnly) {
    $desired = Join-Path $OutputDir ($FileBase + "." + $AudioFormat)
    $decision = Resolve-VideoDlTarget $contentIdentity $desired $postUrl $shortcode ([bool]$Force)
    if ($decision.Skip) { Write-Host ""; Write-Host "Salvo: $($decision.Path)" -ForegroundColor Green; return }
    $outputPath = [string]$decision.Path
    $tempVideo = Join-Path $env:TEMP ("video-dl-threads-" + [Guid]::NewGuid().ToString("N") + ".mp4")
    Write-Host "Baixando vídeo temporário..."
    Download-File $videoUrl $tempVideo
    Write-Host "Extraindo áudio: $outputPath"
    Convert-Audio $tempVideo $outputPath $AudioFormat
    Remove-Item -LiteralPath $tempVideo -Force -ErrorAction SilentlyContinue
    Register-VideoDlDownload $contentIdentity $outputPath $postUrl $shortcode
} else {
    $desired = Join-Path $OutputDir ($FileBase + "." + $VideoContainer)
    $decision = Resolve-VideoDlTarget $contentIdentity $desired $postUrl $shortcode ([bool]$Force)
    if ($decision.Skip) { Write-Host ""; Write-Host "Salvo: $($decision.Path)" -ForegroundColor Green; return }
    $outputPath = [string]$decision.Path

    if ($VideoContainer -eq "mp4") {
        Write-Host "Baixando: $outputPath"
        Download-File $videoUrl $outputPath
    } else {
        if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "FFmpeg é necessário para saída MKV." }
        $tempVideo = Join-Path $env:TEMP ("video-dl-threads-" + [Guid]::NewGuid().ToString("N") + ".mp4")
        Write-Host "Baixando vídeo temporário..."
        Download-File $videoUrl $tempVideo
        Write-Host "Remuxando para MKV: $outputPath"
        & ffmpeg -y -i $tempVideo -map 0 -c copy $outputPath | Out-Host
        $ffCode = [int]$LASTEXITCODE
        Remove-Item -LiteralPath $tempVideo -Force -ErrorAction SilentlyContinue
        if ($ffCode -ne 0) { throw "FFmpeg não conseguiu remuxar o vídeo para MKV." }
    }

    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        $outputPath = Add-QualitySuffix $outputPath
        Register-VideoDlDownload $contentIdentity $outputPath $postUrl $shortcode
    }
}

Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green
'''
a = s.find('if (-not (Get-Command th -ErrorAction SilentlyContinue))')
if a < 0:
    raise RuntimeError("missing threads tail")
s = s[:a] + threads_tail
p.write_text(s, encoding="utf-8")

# ---- setup installer ----
p = branch_files["setup"]
s = p.read_text(encoding="utf-8-sig")
s = replace_once(
    s,
    '@{ Remote = "src/th-dl.ps1"; Local = "th-dl.ps1" },\n        @{ Remote = "installer/video-dl.cmd"; Local = "video-dl.cmd" }',
    '@{ Remote = "src/th-dl.ps1"; Local = "th-dl.ps1" },\n        @{ Remote = "src/archive.ps1"; Local = "archive.ps1" },\n        @{ Remote = "installer/video-dl.cmd"; Local = "video-dl.cmd" }',
    "setup download archive",
)
s = replace_once(
    s,
    'Copy-Item -LiteralPath (Join-Path $tempDir "th-dl.ps1") -Destination (Join-Path $appDir "th-dl.ps1") -Force\n    Copy-Item -LiteralPath (Join-Path $tempDir "video-dl.cmd")',
    'Copy-Item -LiteralPath (Join-Path $tempDir "th-dl.ps1") -Destination (Join-Path $appDir "th-dl.ps1") -Force\n    Copy-Item -LiteralPath (Join-Path $tempDir "archive.ps1") -Destination (Join-Path $appDir "archive.ps1") -Force\n    Copy-Item -LiteralPath (Join-Path $tempDir "video-dl.cmd")',
    "setup copy archive",
)
p.write_text(s, encoding="utf-8")

# ---- Inno Setup ----
p = branch_files["iss"]
s = p.read_text(encoding="utf-8-sig")
s = replace_once(s, '#define MyAppVersion "0.3.3"', '#define MyAppVersion "0.4.2"', "iss fallback version")
s = replace_once(
    s,
    'Source: "..\\src\\th-dl.ps1"; DestDir: "{app}"; Flags: ignoreversion\n',
    'Source: "..\\src\\th-dl.ps1"; DestDir: "{app}"; Flags: ignoreversion\nSource: "..\\src\\archive.ps1"; DestDir: "{app}"; Flags: ignoreversion\n',
    "iss archive file",
)
p.write_text(s, encoding="utf-8")

# ---- README ----
p = branch_files["readme"]
s = p.read_text(encoding="utf-8-sig")
s = replace_once(
    s,
    '└── 2026-09-11 - Título original [ID].mp4',
    '└── 2026-09-11 - Título original [1080p].mp4',
    "readme filename example",
)
s = replace_once(
    s,
    'O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual. Por padrão, vídeos também recebem a resolução real no nome, por exemplo `[1080p]`.',
    'O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual. Por padrão, vídeos também recebem a resolução real no nome, por exemplo `[1080p]`. IDs técnicos do site ficam fora do nome do arquivo.',
    "readme naming text",
)
old_dup = '`ask` oferece pular, substituir ou criar cópia. `rename` cria `(2)`, `(3)` etc. Em playlists nativas, `overwrite` é respeitado; os outros modos deixam o yt-dlp pular colisões item a item.'
new_dup = '''O `video-dl` mantém um histórico interno em `%USERPROFILE%\\.video-dl\\downloads.json`. Assim, o ID do site não precisa aparecer no nome: se a mesma mídia for enviada novamente, o programa reconhece a identidade e aplica `skip`, `ask`, `overwrite` ou `rename`. Se **outra mídia** tiver exatamente o mesmo nome, ambas são preservadas e a nova recebe `(2)`, `(3)` etc.\n\nAo encontrar arquivos antigos no padrão com `[ID]`, o programa tenta remover esse ID do nome e registrar o arquivo no histórico sem baixá-lo de novo. Em playlists nativas, o índice da playlist continua evitando a maioria das colisões e o yt-dlp trata cada item.'''
s = replace_once(s, old_dup, new_dup, "readme duplicate semantics")
p.write_text(s, encoding="utf-8")

# ---- VERSION ----
branch_files["version"].write_text("0.4.2\n", encoding="utf-8")

print("v0.4.2 patch applied")
