param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Url,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = (Get-Location).Path,

    [switch]$AudioOnly,

    [string]$AudioFormat = "mp3",

    [ValidateSet("mp4", "mkv")]
    [string]$VideoContainer = "mp4",

    [string]$FileBase,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Safe-Name([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "Threads" }
    $value = $Name
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) { $value = $value.Replace([string]$char, "_") }
    $value = ($value -replace '\s+', ' ').Trim().TrimEnd('.', ' ')
    if ($value.Length -gt 180) { $value = $value.Substring(0, 180).Trim() }
    return $value
}

function Get-UniquePath([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue)) { return $PathValue }
    $dir = Split-Path -Parent $PathValue
    $name = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $i = 2
    while ($true) {
        $candidate = Join-Path $dir ("{0} ({1}){2}" -f $name, $i, $ext)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $i++
    }
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

function Get-UniqueVariantPath([string]$PathValue) {
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
    $existing = Find-ExistingVariant $PathValue
    if ($null -eq $existing) { return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }
    $settings = Get-LocalSettings
    $policy = if ($Force) { "overwrite" } else { [string]$settings.duplicatePolicy }
    if ($policy -eq "ask") {
        Write-Host "Arquivo já existe: $($existing.Name)" -ForegroundColor Yellow
        $choice = (Read-Host "[P]ular / [S]ubstituir / [C]riar cópia [P]").Trim().ToLowerInvariant()
        if ($choice -in @("s", "substituir")) { $policy = "overwrite" }
        elseif ($choice -in @("c", "copia", "cópia")) { $policy = "rename" }
        else { $policy = "skip" }
    }
    if ($policy -eq "overwrite") { Remove-Item -LiteralPath $existing.FullName -Force; return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }
    if ($policy -eq "rename") { return [PSCustomObject]@{ Skip = $false; Path = (Get-UniqueVariantPath $PathValue) } }
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

function Resolve-ThreadsUrl([string]$InputUrl) {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $resolved = curl.exe -Ls -o NUL -w "%{url_effective}" "$InputUrl"
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolved)) { return (($resolved -split '\?')[0]) }
    }
    try {
        $response = Invoke-WebRequest -Uri $InputUrl -UseBasicParsing -MaximumRedirection 10
        $final = $null
        if ($null -ne $response.BaseResponse -and $null -ne $response.BaseResponse.ResponseUri) { $final = $response.BaseResponse.ResponseUri.AbsoluteUri }
        if (-not [string]::IsNullOrWhiteSpace($final)) { return (($final -split '\?')[0]) }
    } catch { }
    return (($InputUrl -split '\?')[0])
}

function Download-File([string]$DownloadUrl, [string]$Destination) {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        curl.exe -L --fail --retry 3 --retry-delay 1 --progress-bar "$DownloadUrl" -o "$Destination"
        if ($LASTEXITCODE -ne 0) { throw "Falha ao baixar o arquivo." }
        return
    }
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $Destination -UseBasicParsing
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

if (-not (Get-Command th -ErrorAction SilentlyContinue)) { throw "O comando 'th' não foi encontrado." }
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

Write-Host "Fallback Threads: resolvendo URL..."
$resolvedUrl = Resolve-ThreadsUrl $Url
if ($resolvedUrl -notmatch 'threads\.(?:com|net)/@([^/]+)/post/([^/?]+)') { throw "Não foi possível identificar um post do Threads em: $resolvedUrl" }

$username = $Matches[1]
$shortcode = $Matches[2]
$postUrl = "https://www.threads.com/@$username/post/$shortcode"
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
    $FileBase = (Get-Date -Format "yyyy-MM-dd") + " - @${username} [$shortcode]"
}
$FileBase = Safe-Name $FileBase

if ($AudioOnly) {
    $tempVideo = Join-Path $env:TEMP ("video-dl-threads-" + [Guid]::NewGuid().ToString("N") + ".mp4")
    $outputPath = Join-Path $OutputDir ($FileBase + "." + $AudioFormat)
    $collision = Resolve-Collision $outputPath
    if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
    $outputPath = [string]$collision.Path
    Write-Host "Baixando vídeo temporário..."
    Download-File $videoUrl $tempVideo
    Write-Host "Extraindo áudio: $outputPath"
    Convert-Audio $tempVideo $outputPath $AudioFormat
    Remove-Item -LiteralPath $tempVideo -Force -ErrorAction SilentlyContinue
} else {
    if ($VideoContainer -eq "mp4") {
        $outputPath = Join-Path $OutputDir ($FileBase + ".mp4")
        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
        $outputPath = [string]$collision.Path
        Write-Host "Baixando: $outputPath"
        Download-File $videoUrl $outputPath
    } else {
        if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "FFmpeg é necessário para saída MKV." }
        $tempVideo = Join-Path $env:TEMP ("video-dl-threads-" + [Guid]::NewGuid().ToString("N") + ".mp4")
        $outputPath = Join-Path $OutputDir ($FileBase + ".mkv")
        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
        $outputPath = [string]$collision.Path
        Write-Host "Baixando vídeo temporário..."
        Download-File $videoUrl $tempVideo
        Write-Host "Remuxando para MKV: $outputPath"
        & ffmpeg -y -i $tempVideo -map 0 -c copy $outputPath | Out-Host
        $ffCode = [int]$LASTEXITCODE
        Remove-Item -LiteralPath $tempVideo -Force -ErrorAction SilentlyContinue
        if ($ffCode -ne 0) { throw "FFmpeg não conseguiu remuxar o vídeo para MKV." }
    }
}

if (-not $AudioOnly -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) { $outputPath = Add-QualitySuffix $outputPath }
Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green


