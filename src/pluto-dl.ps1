param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [switch]$AudioOnly,

    [string]$AudioFormat = "mp3"
)

$ErrorActionPreference = "Stop"

$ConfigDir = Join-Path $HOME ".video-dl"
$StatePath = Join-Path $ConfigDir "pluto-state.json"

function Ensure-Directory([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue -PathType Container)) {
        New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
    }
}

function Safe-Name([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "Pluto TV"
    }

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $value = $Name
    foreach ($char in $invalid) {
        $value = $value.Replace([string]$char, "_")
    }

    $value = ($value -replace '\s+', ' ').Trim().TrimEnd('.', ' ')
    if ($value.Length -gt 160) {
        $value = $value.Substring(0, 160).Trim()
    }
    return $value
}

function Read-Number([string]$Prompt, [Nullable[int]]$DefaultValue) {
    if ($null -ne $DefaultValue) {
        $text = Read-Host "$Prompt [$DefaultValue]"
    }
    else {
        $text = Read-Host "$Prompt"
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $DefaultValue
    }

    if ($text -match '^\d+$') {
        return [int]$text
    }

    Write-Host "Valor inválido. Tente novamente." -ForegroundColor Yellow
    return (Read-Number $Prompt $DefaultValue)
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return @()
    }

    try {
        $data = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($data)
    }
    catch {
        return @()
    }
}

function Save-State([object[]]$State) {
    Ensure-Directory $ConfigDir
    @($State) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Update-State(
    [string]$ShowId,
    [string]$Series,
    [Nullable[int]]$Season,
    [Nullable[int]]$Episode
) {
    if ([string]::IsNullOrWhiteSpace($ShowId)) {
        return
    }

    $state = @(Load-State)
    $state = @($state | Where-Object { $_.showId -ne $ShowId })

    $state += [PSCustomObject]@{
        showId = $ShowId
        series = $Series
        season = $Season
        episode = $Episode
        updatedAt = (Get-Date).ToString("o")
    }

    Save-State $state
}

function Try-PageNumbers([string]$PageUrl) {
    $result = [PSCustomObject]@{
        season = $null
        episode = $null
    }

    try {
        $response = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -TimeoutSec 15 -Headers @{
            "User-Agent" = "Mozilla/5.0"
        }
        $html = [string]$response.Content

        $seasonPatterns = @(
            '"seasonNumber"\s*:\s*"?(\d+)"?',
            '\\"seasonNumber\\"\s*:\s*"?(\d+)"?',
            '"season_number"\s*:\s*"?(\d+)"?'
        )

        foreach ($pattern in $seasonPatterns) {
            $m = [regex]::Match($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $result.season = [int]$m.Groups[1].Value
                break
            }
        }

        $episodePatterns = @(
            '"episodeNumber"\s*:\s*"?(\d+)"?',
            '\\"episodeNumber\\"\s*:\s*"?(\d+)"?',
            '"episode_number"\s*:\s*"?(\d+)"?'
        )

        foreach ($pattern in $episodePatterns) {
            $m = [regex]::Match($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $result.episode = [int]$m.Groups[1].Value
                break
            }
        }
    }
    catch { }

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
        if (Get-Command python -ErrorAction SilentlyContinue) {
            & python -m streamlink @Arguments | Out-Host
        }
        else {
            & py -3 -m streamlink @Arguments | Out-Host
        }
        return [int]$LASTEXITCODE
    }

    throw "Streamlink não foi encontrado."
}

function Get-StreamlinkMetadata([string]$PageUrl) {
    if (Get-Command streamlink -ErrorAction SilentlyContinue) {
        $jsonText = (& streamlink --json $PageUrl 2>$null | Out-String)
        $code = $LASTEXITCODE
    }
    elseif (Test-PythonModule "streamlink") {
        if (Get-Command python -ErrorAction SilentlyContinue) {
            $jsonText = (& python -m streamlink --json $PageUrl 2>$null | Out-String)
        }
        else {
            $jsonText = (& py -3 -m streamlink --json $PageUrl 2>$null | Out-String)
        }
        $code = $LASTEXITCODE
    }
    else {
        throw "Streamlink não foi encontrado."
    }

    if ($code -ne 0 -or [string]::IsNullOrWhiteSpace($jsonText)) {
        throw "O Streamlink não conseguiu ler os metadados da Pluto."
    }

    return ($jsonText | ConvertFrom-Json)
}

function Convert-Audio([string]$InputPath, [string]$OutputPath, [string]$Format) {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        throw "FFmpeg é necessário para --audio."
    }

    $ffArgs = @("-y", "-i", $InputPath, "-vn")
    switch ($Format.ToLowerInvariant()) {
        "mp3" { $ffArgs += @("-c:a", "libmp3lame", "-q:a", "0") }
        "m4a" { $ffArgs += @("-c:a", "aac", "-b:a", "192k") }
        "aac" { $ffArgs += @("-c:a", "aac", "-b:a", "192k") }
        "opus" { $ffArgs += @("-c:a", "libopus", "-b:a", "160k") }
        "wav" { $ffArgs += @("-c:a", "pcm_s16le") }
        "flac" { $ffArgs += @("-c:a", "flac") }
        default { }
    }
    $ffArgs += $OutputPath

    & ffmpeg @ffArgs | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg não conseguiu extrair o áudio."
    }
}

Ensure-Directory $OutputRoot

$showId = $null
$seasonFromUrl = $null

if ($Url -match '/(?:shows|on-demand/series)/([^/?]+)') {
    $showId = $Matches[1]
}

if ($Url -match '/season/(\d+)') {
    $seasonFromUrl = [int]$Matches[1]
}

Write-Host "Pluto: lendo metadados..."
$data = Get-StreamlinkMetadata $Url

$series = $null
$title = $null
if ($null -ne $data.metadata) {
    $series = [string]$data.metadata.author
    $title = [string]$data.metadata.title
}

if ([string]::IsNullOrWhiteSpace($series)) {
    $series = "Pluto TV"
}

if ([string]::IsNullOrWhiteSpace($title)) {
    $title = "Episódio"
}

$season = $seasonFromUrl
$episode = $null

$combined = "$series $title"
if ($null -eq $season) {
    $m = [regex]::Match($combined, '\bS(?:eason)?\s*0*(\d+)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
        $season = [int]$m.Groups[1].Value
    }
}

$mEpisode = [regex]::Match($combined, '\bE(?:pisode|p\.?)?\s*0*(\d+)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
if ($mEpisode.Success) {
    $episode = [int]$mEpisode.Groups[1].Value
}

if ($null -eq $season -or $null -eq $episode) {
    $pageNumbers = Try-PageNumbers $Url
    if ($null -eq $season -and $null -ne $pageNumbers.season) {
        $season = [int]$pageNumbers.season
    }
    if ($null -eq $episode -and $null -ne $pageNumbers.episode) {
        $episode = [int]$pageNumbers.episode
    }
}

$state = @(Load-State)
$previous = $null
if (-not [string]::IsNullOrWhiteSpace($showId)) {
    $previous = $state | Where-Object { $_.showId -eq $showId } | Select-Object -First 1
}

if ($null -eq $season) {
    $seasonDefault = $null
    if ($null -ne $previous -and $null -ne $previous.season) {
        $seasonDefault = [int]$previous.season
    }

    $season = Read-Number "Temporada (Enter para usar o sugerido; 0 = sem pasta)" $seasonDefault
}

if ($null -ne $season -and $season -eq 0) {
    $season = $null
}

if ($null -eq $episode) {
    $episodeDefault = $null

    if ($null -ne $previous -and $null -ne $previous.episode) {
        $sameSeason = $true
        if ($null -ne $season -and $null -ne $previous.season) {
            $sameSeason = ([int]$previous.season -eq [int]$season)
        }

        if ($sameSeason) {
            $episodeDefault = ([int]$previous.episode + 1)
        }
    }

    $episode = Read-Number "Número do episódio (Enter para usar o sugerido; 0 = desconhecido)" $episodeDefault
}

if ($null -ne $episode -and $episode -eq 0) {
    $episode = $null
}

$language = "unknown"
try {
    $uri = [Uri]$Url
    if ($uri.AbsolutePath -match '^/br/') {
        $language = "pt-BR"
    }
    elseif ($uri.AbsolutePath -match '^/us/') {
        $language = "en-US"
    }
}
catch { }

$seriesFolder = Join-Path $OutputRoot (Safe-Name $series)
Ensure-Directory $seriesFolder

if ($null -ne $season) {
    $seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f [int]$season)
    Ensure-Directory $seasonFolder
}
else {
    $seasonFolder = $seriesFolder
}

if ($null -ne $season -and $null -ne $episode) {
    $prefix = "S{0:D2}E{1:D2}" -f [int]$season, [int]$episode
}
elseif ($null -ne $episode) {
    $prefix = "E{0:D2}" -f [int]$episode
}
else {
    $prefix = "Episode"
}

$fileBase = Safe-Name ("{0} - {1} [{2}]" -f $prefix, $title, $language)

Write-Host ""
Write-Host "Série:     $series"
Write-Host "Temporada: $(if ($null -ne $season) { $season } else { 'desconhecida' })"
Write-Host "Episódio:  $(if ($null -ne $episode) { $episode } else { 'desconhecido' })"
Write-Host "Idioma:     $language"

if ($AudioOnly) {
    $outputPath = Join-Path $seasonFolder ($fileBase + "." + $AudioFormat)
    $tempPath = Join-Path $env:TEMP ("video-dl-pluto-" + [Guid]::NewGuid().ToString("N") + ".ts")

    Write-Host "Destino:    $outputPath"
    Write-Host ""

    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        $answer = Read-Host "O arquivo já existe. Substituir? [s/N]"
        if ($answer.Trim().ToLowerInvariant() -notin @("s", "sim", "y", "yes")) {
            Write-Host "Download pulado."
            return
        }
        Remove-Item -LiteralPath $outputPath -Force
    }

    $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $tempPath)
    if ($code -ne 0) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw "O Streamlink terminou com código $code."
    }

    Convert-Audio $tempPath $outputPath $AudioFormat
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
}
else {
    $outputPath = Join-Path $seasonFolder ($fileBase + ".ts")
    Write-Host "Destino:    $outputPath"
    Write-Host ""

    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        $answer = Read-Host "O arquivo já existe. Substituir? [s/N]"
        if ($answer.Trim().ToLowerInvariant() -notin @("s", "sim", "y", "yes")) {
            Write-Host "Download pulado."
            return
        }

        Remove-Item -LiteralPath $outputPath -Force
    }

    $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $outputPath)
    if ($code -ne 0) {
        throw "O Streamlink terminou com código $code."
    }
}

Update-State $showId $series $season $episode
Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green
