param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [switch]$AudioOnly,

    [string]$AudioFormat = "mp3",

    [ValidateSet("mp4", "mkv")]
    [string]$VideoContainer = "mp4",

    [switch]$SeriesMode,

    [string]$SeriesName,

    [Nullable[int]]$SeasonNumber,

    [Nullable[int]]$EpisodeNumber
)

$ErrorActionPreference = "Stop"
$ArchiveHelperPath = Join-Path $PSScriptRoot "archive.ps1"
$EpisodeDetectionPath = Join-Path $PSScriptRoot "episode-detection.ps1"
if (-not (Test-Path -LiteralPath $ArchiveHelperPath -PathType Leaf)) { throw "archive.ps1 não encontrado." }
if (-not (Test-Path -LiteralPath $EpisodeDetectionPath -PathType Leaf)) { throw "episode-detection.ps1 não encontrado." }
. $ArchiveHelperPath
. $EpisodeDetectionPath
$ConfigDir = Join-Path $HOME ".video-dl"
$StatePath = Join-Path $ConfigDir "pluto-state.json"

function Ensure-Directory([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue -PathType Container)) {
        New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
    }
}

function Safe-Name([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "Pluto TV" }
    $value = [regex]::Replace($Name, '\s*[\\/]\s*', ' + ')
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) { $value = $value.Replace([string]$char, "_") }
    $value = ($value -replace '\s+', ' ').Trim().TrimEnd('.', ' ')
    if ($value.Length -gt 160) { $value = $value.Substring(0, 160).Trim() }
    return $value
}

function Read-Number([string]$Prompt, [Nullable[int]]$DefaultValue) {
    while ($true) {
        $text = if ($null -ne $DefaultValue) { Read-Host "$Prompt [$DefaultValue]" } else { Read-Host $Prompt }
        if ([string]::IsNullOrWhiteSpace($text)) { return $DefaultValue }
        if ($text -match '^\d+$') { return [int]$text }
        Write-Host "Valor inválido. Tente novamente." -ForegroundColor Yellow
    }
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return @() }
    try { return @((Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)) } catch { return @() }
}

function Save-State([object[]]$State) {
    Ensure-Directory $ConfigDir
    @($State) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Update-State([string]$ShowId, [string]$Series, [Nullable[int]]$Season, [Nullable[int]]$Episode) {
    if ([string]::IsNullOrWhiteSpace($ShowId)) { return }
    $state = @(Load-State)
    $state = @($state | Where-Object { $_.showId -ne $ShowId })
    $state += [PSCustomObject]@{ showId = $ShowId; series = $Series; season = $Season; episode = $Episode; updatedAt = (Get-Date).ToString("o") }
    Save-State $state
}

function Try-PageNumbers([string]$PageUrl) {
    $result = [PSCustomObject]@{ season = $null; episode = $null }
    try {
        $response = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -TimeoutSec 15 -Headers @{ "User-Agent" = "Mozilla/5.0" }
        $html = [string]$response.Content
        foreach ($pattern in @('"seasonNumber"\s*:\s*"?(\d+)"?', '\\"seasonNumber\\"\s*:\s*"?(\d+)"?', '"season_number"\s*:\s*"?(\d+)"?')) {
            $m = [regex]::Match($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) { $result.season = [int]$m.Groups[1].Value; break }
        }
        foreach ($pattern in @('"episodeNumber"\s*:\s*"?(\d+)"?', '\\"episodeNumber\\"\s*:\s*"?(\d+)"?', '"episode_number"\s*:\s*"?(\d+)"?')) {
            $m = [regex]::Match($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) { $result.episode = [int]$m.Groups[1].Value; break }
        }

    } catch { }
    return $result
}

function Test-PythonModule([string]$Module) {
    if (Get-Command python -ErrorAction SilentlyContinue) {
        & python -c "import $Module" *> $null
        return ($LASTEXITCODE -eq 0)
    }
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3 -c "import $Module" *> $null
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

function Invoke-StreamlinkLocal([object[]]$Arguments) {
    if (Get-Command streamlink -ErrorAction SilentlyContinue) {
        & streamlink @Arguments | Out-Host
        return [int]$LASTEXITCODE
    }
    if (Test-PythonModule "streamlink") {
        if (Get-Command python -ErrorAction SilentlyContinue) { & python -m streamlink @Arguments | Out-Host }
        else { & py -3 -m streamlink @Arguments | Out-Host }
        return [int]$LASTEXITCODE
    }
    throw "Streamlink não foi encontrado."
}

function Get-StreamlinkMetadata([string]$PageUrl) {
    if (Get-Command streamlink -ErrorAction SilentlyContinue) {
        $jsonText = (& streamlink --json $PageUrl 2>$null | Out-String)
        $code = $LASTEXITCODE
    } elseif (Test-PythonModule "streamlink") {
        if (Get-Command python -ErrorAction SilentlyContinue) { $jsonText = (& python -m streamlink --json $PageUrl 2>$null | Out-String) }
        else { $jsonText = (& py -3 -m streamlink --json $PageUrl 2>$null | Out-String) }
        $code = $LASTEXITCODE
    } else {
        throw "Streamlink não foi encontrado."
    }
    if ($code -ne 0 -or [string]::IsNullOrWhiteSpace($jsonText)) { throw "O Streamlink não conseguiu ler os metadados da Pluto." }
    return ($jsonText | ConvertFrom-Json)
}

function Get-LocalSettings {
    $result = [PSCustomObject]@{ qualityInFilename = $true; duplicatePolicy = "skip" }
    $path = Join-Path (Join-Path $HOME ".video-dl") "config.json"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $cfg.PSObject.Properties["qualityInFilename"]) { $result.qualityInFilename = [bool]$cfg.qualityInFilename }
            if ([string]$cfg.duplicatePolicy -in @("skip", "ask", "overwrite", "rename")) { $result.duplicatePolicy = [string]$cfg.duplicatePolicy }
        } catch { }
    }
    return $result
}

function Find-ExistingVariant([string]$PathValue) {
    $dir = Split-Path -Parent $PathValue
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $pattern = '^' + [regex]::Escape($stem) + '(?: \[\d+p\])?' + [regex]::Escape($ext) + '$'
    return Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
}

function Get-UniqueOutputPath([string]$PathValue) {
    $dir = Split-Path -Parent $PathValue
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $i = 2
    while ($true) {
        $candidate = Join-Path $dir ("{0} ({1}){2}" -f $stem, $i, $ext)
        if ($null -eq (Find-ExistingVariant $candidate) -and -not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $i++
    }
}

function Resolve-Collision([string]$PathValue) {
    $settings = Get-LocalSettings
    $existing = Find-ExistingVariant $PathValue
    if ($null -eq $existing) { return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }
    $policy = [string]$settings.duplicatePolicy
    if ($policy -eq "ask") {
        Write-Host "Arquivo já existe: $($existing.Name)" -ForegroundColor Yellow
        $choice = (Read-Host "[P]ular / [S]ubstituir / [C]riar cópia [P]").Trim().ToLowerInvariant()
        if ($choice -in @("s", "substituir")) { $policy = "overwrite" }
        elseif ($choice -in @("c", "copia", "cópia")) { $policy = "rename" }
        else { $policy = "skip" }
    }
    if ($policy -eq "overwrite") { Remove-Item -LiteralPath $existing.FullName -Force; return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }
    if ($policy -eq "rename") { return [PSCustomObject]@{ Skip = $false; Path = (Get-UniqueOutputPath $PathValue) } }
    Write-Host "Arquivo já existe; download pulado: $($existing.Name)" -ForegroundColor Cyan
    return [PSCustomObject]@{ Skip = $true; Path = $existing.FullName }
}

function Add-QualitySuffix([string]$PathValue) {
    $settings = Get-LocalSettings
    if (-not [bool]$settings.qualityInFilename -or -not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { return $PathValue }
    try {
        $raw = (& ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 -- $PathValue 2>$null | Select-Object -First 1)
        if ([string]$raw -notmatch '^(\d+)x(\d+)$') { return $PathValue }
        $height = [Math]::Min([int]$Matches[1], [int]$Matches[2])
        $dir = Split-Path -Parent $PathValue
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
        if ($stem -match '\[\d+p\]$') { return $PathValue }
        $ext = [System.IO.Path]::GetExtension($PathValue)
        $target = Join-Path $dir ("$stem [$height`p]$ext")
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        Move-Item -LiteralPath $PathValue -Destination $target -Force
        return $target
    } catch { return $PathValue }
}

function Convert-Audio([string]$InputPath, [string]$OutputPath, [string]$Format) {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "FFmpeg é necessário para --audio." }
    $ffArgs = @("-y", "-i", $InputPath, "-vn")
    switch ($Format.ToLowerInvariant()) {
        "mp3" { $ffArgs += @("-c:a", "libmp3lame", "-q:a", "0") }
        "m4a" { $ffArgs += @("-c:a", "aac", "-b:a", "192k") }
        "aac" { $ffArgs += @("-c:a", "aac", "-b:a", "192k") }
        "opus" { $ffArgs += @("-c:a", "libopus", "-b:a", "160k") }
        "wav" { $ffArgs += @("-c:a", "pcm_s16le") }
        "flac" { $ffArgs += @("-c:a", "flac") }
    }
    $ffArgs += $OutputPath
    & ffmpeg @ffArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "FFmpeg não conseguiu extrair o áudio." }
}

function Download-Pluto([string]$Folder, [string]$FileBase, [string]$Identity, [string]$SourceId) {
    Ensure-Directory $Folder
    if ($AudioOnly) {
        $desired = Join-Path $Folder ($FileBase + "." + $AudioFormat)
        $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false ([bool]$SeriesMode)
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
        $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false ([bool]$SeriesMode)
        if ($decision.Skip) { return $decision.Path }
        $outputPath = [string]$decision.Path
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $outputPath)
        if ($code -ne 0) { throw "O Streamlink terminou com código $code." }
        Register-VideoDlDownload $Identity $outputPath $Url $SourceId
        return $outputPath
    }

    $desired = Join-Path $Folder ($FileBase + "." + $VideoContainer)
    $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false ([bool]$SeriesMode)
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
        $mkvDecision = Resolve-VideoDlTarget $Identity $desiredMkv $Url $SourceId $false ([bool]$SeriesMode)
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
}

Ensure-Directory $OutputRoot
$showId = $null
$episodeId = $null
$seasonFromUrl = $null
if ($Url -match '/(?:shows|on-demand/series)/([^/?]+)') { $showId = $Matches[1] }
if ($Url -match '/episode/([^/?]+)') { $episodeId = $Matches[1] }
if ($Url -match '/season/(\d+)') { $seasonFromUrl = [int]$Matches[1] }
$contentIdentity = Get-VideoDlIdentity "pluto" $episodeId $Url

Write-Host "Pluto: lendo metadados..."
$data = Get-StreamlinkMetadata $Url
$apiInfo = Get-VideoDlPlutoEpisodeNumbers $Url

$streamlinkSeries = if ($null -ne $data.metadata) { [string]$data.metadata.author } else { "" }
$streamlinkTitle = if ($null -ne $data.metadata) { [string]$data.metadata.title } else { "" }

$series = $streamlinkSeries
if ([string]::IsNullOrWhiteSpace($series) -and -not [string]::IsNullOrWhiteSpace([string]$apiInfo.SeriesTitle)) {
    $series = [string]$apiInfo.SeriesTitle
}
if ([string]::IsNullOrWhiteSpace($series) -and -not [string]::IsNullOrWhiteSpace($SeriesName)) {
    $series = $SeriesName
}

$title = $streamlinkTitle
$titleIsPlaceholder = [string]::IsNullOrWhiteSpace($title) -or $title.Trim() -in @("Episódio", "Episodio", "Episode", "Vídeo", "Video")
if ($titleIsPlaceholder -and -not [string]::IsNullOrWhiteSpace([string]$apiInfo.Title)) {
    $title = [string]$apiInfo.Title
}
$titleIsPlaceholder = [string]::IsNullOrWhiteSpace($title) -or $title.Trim() -in @("Episódio", "Episodio", "Episode", "Vídeo", "Video")

if ([string]::IsNullOrWhiteSpace($series)) { $series = "Pluto TV" }

$metadataLine = "Metadata: Streamlink série='{0}' título='{1}' | Pluto {2} série='{3}' título='{4}' S={5} E={6}" -f $streamlinkSeries, $streamlinkTitle, [string]$apiInfo.Pattern, [string]$apiInfo.SeriesTitle, [string]$apiInfo.Title, [string]$apiInfo.Season, [string]$apiInfo.Episode
Write-Host $metadataLine -ForegroundColor DarkGray

if ($SeriesMode -and $titleIsPlaceholder) {
    throw "A Pluto não retornou o título real do episódio. Download cancelado para não salvar como 'Episódio'."
}
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

$season = if ($null -ne $SeasonNumber) { [int]$SeasonNumber } else { $seasonFromUrl }
$episode = if ($null -ne $EpisodeNumber) { [int]$EpisodeNumber } else { $null }
$combined = "$series $title"
if ($null -eq $season) {
    $m = [regex]::Match($combined, '\bS(?:eason)?\s*0*(\d+)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { $season = [int]$m.Groups[1].Value }
}
if ($null -eq $episode) {
    $mEpisode = [regex]::Match($combined, '\bE(?:pisode|p\.?)?\s*0*(\d+)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($mEpisode.Success) { $episode = [int]$mEpisode.Groups[1].Value }
}

if ($null -eq $season -or $null -eq $episode) {
    if ($null -eq $season -and $null -ne $apiInfo.Season) { $season = [int]$apiInfo.Season }
    if ($null -eq $episode -and $null -ne $apiInfo.Episode) { $episode = [int]$apiInfo.Episode }
}

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
Write-Host "Série:      $series"
Write-Host "Temporada:  $season"
Write-Host "Episódio:   $episode"
Write-Host "Título:     $title"
Write-Host "Idioma:     $language"
Write-Host "Destino:    $seasonFolder"

$outputPath = Download-Pluto $seasonFolder $fileBase $contentIdentity $episodeId
Update-State $showId $series $season $episode
Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green
