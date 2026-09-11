param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Url,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = (Get-Location).Path,

    [switch]$AudioOnly,

    [string]$AudioFormat = "mp3",

    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Get-UniquePath([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue)) {
        return $PathValue
    }

    $dir = Split-Path -Parent $PathValue
    $name = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)

    $i = 2
    while ($true) {
        $candidate = Join-Path $dir ("{0} ({1}){2}" -f $name, $i, $ext)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
        $i++
    }
}

function Resolve-ThreadsUrl([string]$InputUrl) {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $resolved = curl.exe -Ls -o NUL -w "%{url_effective}" "$InputUrl"
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolved)) {
            return (($resolved -split '\?')[0])
        }
    }

    try {
        $response = Invoke-WebRequest -Uri $InputUrl -UseBasicParsing -MaximumRedirection 10
        $final = $null

        if ($null -ne $response.BaseResponse -and $null -ne $response.BaseResponse.ResponseUri) {
            $final = $response.BaseResponse.ResponseUri.AbsoluteUri
        }

        if (-not [string]::IsNullOrWhiteSpace($final)) {
            return (($final -split '\?')[0])
        }
    }
    catch { }

    return (($InputUrl -split '\?')[0])
}

function Download-File([string]$DownloadUrl, [string]$Destination) {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        curl.exe -L --fail --retry 3 --retry-delay 1 --progress-bar "$DownloadUrl" -o "$Destination"
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao baixar o arquivo."
        }
        return
    }

    Invoke-WebRequest -Uri $DownloadUrl -OutFile $Destination -UseBasicParsing
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

if (-not (Get-Command th -ErrorAction SilentlyContinue)) {
    throw "O comando 'th' não foi encontrado."
}

if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "Fallback Threads: resolvendo URL..."

$resolvedUrl = Resolve-ThreadsUrl $Url

if ($resolvedUrl -notmatch 'threads\.(?:com|net)/@([^/]+)/post/([^/?]+)') {
    throw "Não foi possível identificar um post do Threads em: $resolvedUrl"
}

$username = $Matches[1]
$shortcode = $Matches[2]
$postUrl = "https://www.threads.com/@$username/post/$shortcode"

Write-Host "Post: @$username / $shortcode"
Write-Host "Extraindo mídia com th..."

$html = th post "$postUrl" --raw | Out-String

if (-not $html) {
    throw "O Threads não retornou HTML."
}

$escapedCode = [regex]::Escape($shortcode)

$match = [regex]::Match(
    $html,
    """code"":""$escapedCode"".*?""video_versions"":\[(?<versions>.*?)\]",
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)

if (-not $match.Success) {
    throw "Nenhum vídeo foi encontrado nesse post."
}

$versionsJson = "[" + $match.Groups["versions"].Value + "]"
$versions = $versionsJson | ConvertFrom-Json

if (-not $versions -or @($versions).Count -eq 0) {
    throw "Nenhuma versão de vídeo disponível foi encontrada."
}

$video = $versions |
    Sort-Object { ([int]$_.width * [int]$_.height) } -Descending |
    Select-Object -First 1

$videoUrl = $video.url
if (-not $videoUrl) {
    throw "A URL do vídeo não pôde ser extraída."
}

Write-Host "Qualidade: $($video.width)x$($video.height)"

if ($AudioOnly) {
    $tempVideo = Join-Path $env:TEMP ("video-dl-threads-" + [Guid]::NewGuid().ToString("N") + ".mp4")
    $outputPath = Join-Path $OutputDir ("${username}_${shortcode}." + $AudioFormat)
    if ((Test-Path -LiteralPath $outputPath) -and -not $Force) {
        $outputPath = Get-UniquePath $outputPath
    }

    Write-Host "Baixando vídeo temporário..."
    Download-File $videoUrl $tempVideo
    Write-Host "Extraindo áudio: $outputPath"
    Convert-Audio $tempVideo $outputPath $AudioFormat
    Remove-Item -LiteralPath $tempVideo -Force -ErrorAction SilentlyContinue
}
else {
    $fileName = "${username}_${shortcode}.mp4"
    $outputPath = Join-Path $OutputDir $fileName

    if ((Test-Path -LiteralPath $outputPath) -and -not $Force) {
        $outputPath = Get-UniquePath $outputPath
    }

    Write-Host "Baixando: $outputPath"
    Download-File $videoUrl $outputPath
}

Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green
