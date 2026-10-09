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
$ArchiveHelperPath = Join-Path $PSScriptRoot "archive.ps1"
if (-not (Test-Path -LiteralPath $ArchiveHelperPath -PathType Leaf)) { throw "archive.ps1 não encontrado." }
. $ArchiveHelperPath

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

function Get-ThreadsCrawlerHtml([string]$PostUrl) {
    $googlebot = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        try {
            $text = curl.exe -Ls --fail -A $googlebot -H "Accept-Language: en-US,en;q=0.9" "$PostUrl" 2>$null | Out-String
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($text)) { return $text }
        } catch { }
    }
    try {
        $response = Invoke-WebRequest -Uri $PostUrl -UseBasicParsing -TimeoutSec 20 -Headers @{
            "User-Agent" = $googlebot
            "Accept-Language" = "en-US,en;q=0.9"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) { return [string]$response.Content }
    } catch { }
    return $null
}

function Find-ThreadsMediaBearingObject([object]$Value) {
    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @("video_versions", "video_dash_manifest", "carousel_media")) {
            if ($Value.Contains($key) -and $null -ne $Value[$key]) {
                if ($key -eq "video_versions" -and @($Value[$key]).Count -eq 0) { continue }
                if ($key -eq "video_dash_manifest" -and [string]::IsNullOrWhiteSpace([string]$Value[$key])) { continue }
                if ($key -eq "carousel_media" -and @($Value[$key]).Count -eq 0) { continue }
                return $Value
            }
        }
        foreach ($key in $Value.Keys) {
            $found = Find-ThreadsMediaBearingObject $Value[$key]
            if ($null -ne $found) { return $found }
        }
        return $null
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($key in @("video_versions", "video_dash_manifest", "carousel_media")) {
            $prop = $Value.PSObject.Properties[$key]
            if ($null -eq $prop -or $null -eq $prop.Value) { continue }
            if ($key -eq "video_versions" -and @($prop.Value).Count -eq 0) { continue }
            if ($key -eq "video_dash_manifest" -and [string]::IsNullOrWhiteSpace([string]$prop.Value)) { continue }
            if ($key -eq "carousel_media" -and @($prop.Value).Count -eq 0) { continue }
            return $Value
        }
        foreach ($prop in $Value.PSObject.Properties) {
            $found = Find-ThreadsMediaBearingObject $prop.Value
            if ($null -ne $found) { return $found }
        }
        return $null
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            $found = Find-ThreadsMediaBearingObject $item
            if ($null -ne $found) { return $found }
        }
    }
    return $null
}

function Find-ThreadsPostInObject([object]$Value, [string]$Shortcode) {
    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        $code = $null
        if ($Value.Contains("code")) { $code = [string]$Value["code"] }
        if ($code -eq $Shortcode) {
            $media = Find-ThreadsMediaBearingObject $Value
            if ($null -ne $media) { return $media }
        }
        foreach ($key in $Value.Keys) {
            $found = Find-ThreadsPostInObject $Value[$key] $Shortcode
            if ($null -ne $found) { return $found }
        }
        return $null
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $codeProp = $Value.PSObject.Properties["code"]
        if ($null -ne $codeProp -and [string]$codeProp.Value -eq $Shortcode) {
            $media = Find-ThreadsMediaBearingObject $Value
            if ($null -ne $media) { return $media }
        }
        foreach ($prop in $Value.PSObject.Properties) {
            $found = Find-ThreadsPostInObject $prop.Value $Shortcode
            if ($null -ne $found) { return $found }
        }
        return $null
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            $found = Find-ThreadsPostInObject $item $Shortcode
            if ($null -ne $found) { return $found }
        }
    }
    return $null
}

function Get-ThreadsPostFromHtml([string]$Html, [string]$Shortcode) {
    if ([string]::IsNullOrWhiteSpace($Html)) { return $null }
    $blocks = [regex]::Matches(
        $Html,
        '<script[^>]+type=["'']application/json["''][^>]*>(?<json>.*?)</script>',
        [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    foreach ($block in $blocks) {
        $json = [System.Net.WebUtility]::HtmlDecode([string]$block.Groups["json"].Value)
        if ([string]::IsNullOrWhiteSpace($json)) { continue }
        try {
            $data = $json | ConvertFrom-Json
            $post = Find-ThreadsPostInObject $data $Shortcode
            if ($null -ne $post) { return $post }
        } catch { }
    }
    return $null
}

function Get-ThreadsVideoVersions([object]$Post) {
    if ($null -eq $Post) { return @() }

    $versions = @()
    $direct = $Post.PSObject.Properties["video_versions"]
    if ($null -ne $direct -and $null -ne $direct.Value) { $versions += @($direct.Value) }

    if ($versions.Count -eq 0) {
        $carouselProp = $Post.PSObject.Properties["carousel_media"]
        if ($null -ne $carouselProp -and $null -ne $carouselProp.Value) {
            foreach ($item in @($carouselProp.Value)) {
                if ($null -eq $item) { continue }
                $itemVersions = $item.PSObject.Properties["video_versions"]
                if ($null -ne $itemVersions -and $null -ne $itemVersions.Value) {
                    $versions += @($itemVersions.Value)
                }
            }
        }
    }
    return @($versions)
}

function Select-ThreadsBestVideo([object[]]$Versions) {
    return @($Versions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.url) } |
        Sort-Object {
            $w = 0; $h = 0
            try { $w = [int]$_.width } catch { }
            try { $h = [int]$_.height } catch { }
            ($w * $h)
        } -Descending) | Select-Object -First 1
}

function Get-ThreadsDashManifest([object]$Post) {
    if ($null -eq $Post) { return $null }

    $direct = $Post.PSObject.Properties["video_dash_manifest"]
    if ($null -ne $direct -and -not [string]::IsNullOrWhiteSpace([string]$direct.Value)) {
        return [string]$direct.Value
    }

    $carouselProp = $Post.PSObject.Properties["carousel_media"]
    if ($null -ne $carouselProp -and $null -ne $carouselProp.Value) {
        foreach ($item in @($carouselProp.Value)) {
            if ($null -eq $item) { continue }
            $manifestProp = $item.PSObject.Properties["video_dash_manifest"]
            if ($null -ne $manifestProp -and -not [string]::IsNullOrWhiteSpace([string]$manifestProp.Value)) {
                return [string]$manifestProp.Value
            }
        }
    }
    return $null
}

function Select-ThreadsDashStreams([string]$Manifest) {
    if ([string]::IsNullOrWhiteSpace($Manifest)) { return $null }
    try { [xml]$xml = $Manifest } catch { return $null }

    $videoCandidates = @()
    $audioCandidates = @()
    $representations = $xml.SelectNodes("//*[local-name()='Representation']")
    foreach ($rep in $representations) {
        $baseNode = $rep.SelectSingleNode("./*[local-name()='BaseURL']")
        if ($null -eq $baseNode) {
            $baseNode = $rep.ParentNode.SelectSingleNode("./*[local-name()='BaseURL']")
        }
        if ($null -eq $baseNode) { continue }
        $url = [System.Net.WebUtility]::HtmlDecode(([string]$baseNode.InnerText).Trim())
        if ([string]::IsNullOrWhiteSpace($url) -or $url -notmatch '^https?://') { continue }

        $adapt = $rep.ParentNode
        $mime = [string]$rep.mimeType
        if ([string]::IsNullOrWhiteSpace($mime)) { $mime = [string]$adapt.mimeType }
        $contentType = [string]$adapt.contentType
        $codecs = [string]$rep.codecs
        if ([string]::IsNullOrWhiteSpace($codecs)) { $codecs = [string]$adapt.codecs }

        $width = 0; $height = 0; $bandwidth = 0
        try { $width = [int]$rep.width } catch { }
        try { $height = [int]$rep.height } catch { }
        try { $bandwidth = [int]$rep.bandwidth } catch { }

        $entry = [PSCustomObject]@{
            Url = $url
            Width = $width
            Height = $height
            Bandwidth = $bandwidth
            Codecs = $codecs
        }

        $isAudio = ($contentType -eq "audio") -or ($mime -like "audio/*") -or ($codecs -match '^(mp4a|opus|vorbis)')
        $isVideo = ($contentType -eq "video") -or ($mime -like "video/*") -or ($width -gt 0 -and $height -gt 0)
        if ($isAudio) { $audioCandidates += $entry }
        elseif ($isVideo) { $videoCandidates += $entry }
    }

    $video = @($videoCandidates | Sort-Object @{Expression={ $_.Width * $_.Height }; Descending=$true}, @{Expression={$_.Bandwidth}; Descending=$true}) | Select-Object -First 1
    $audio = @($audioCandidates | Sort-Object Bandwidth -Descending) | Select-Object -First 1
    if ($null -eq $video) { return $null }

    return [PSCustomObject]@{
        VideoUrl = [string]$video.Url
        AudioUrl = if ($null -ne $audio) { [string]$audio.Url } else { $null }
        Width = [int]$video.Width
        Height = [int]$video.Height
    }
}

function Merge-ThreadsDashVideo([string]$VideoUrl, [string]$AudioUrl, [string]$OutputPath, [string]$VideoContainer) {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "FFmpeg é necessário para juntar vídeo e áudio DASH do Threads." }
    $args = @("-hide_banner", "-y", "-i", $VideoUrl)
    if (-not [string]::IsNullOrWhiteSpace($AudioUrl)) { $args += @("-i", $AudioUrl) }
    $args += @("-map", "0:v:0")
    if (-not [string]::IsNullOrWhiteSpace($AudioUrl)) { $args += @("-map", "1:a:0") }
    $args += @("-c", "copy")
    if ($VideoContainer -eq "mp4") { $args += @("-movflags", "+faststart") }
    $args += $OutputPath
    & ffmpeg @args | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "FFmpeg não conseguiu juntar os streams DASH do Threads."
    }
}

if (-not (Get-Command th -ErrorAction SilentlyContinue)) { throw "O comando 'th' não foi encontrado." }
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
$post = Get-ThreadsPostFromHtml $html $shortcode

if ($null -eq $post) {
    Write-Host "Formato do th não trouxe o vídeo; tentando página pública para crawler..."
    $crawlerHtml = Get-ThreadsCrawlerHtml $postUrl
    $post = Get-ThreadsPostFromHtml $crawlerHtml $shortcode
}

if ($null -eq $post) {
    throw "Nenhum vídeo foi encontrado nesse post. O post pode ser privado/indisponível ou o Threads mudou a estrutura da página."
}

$versions = @(Get-ThreadsVideoVersions $post)
$videoUrl = $null
$audioUrl = $null
$usingDash = $false
$quality = "melhor disponível"

if ($versions.Count -gt 0) {
    $video = Select-ThreadsBestVideo $versions
    $videoUrl = [string]$video.url
    if ($video.width -and $video.height) { $quality = "$($video.width)x$($video.height)" }
} else {
    $manifest = Get-ThreadsDashManifest $post
    $dash = Select-ThreadsDashStreams $manifest
    if ($null -ne $dash) {
        $usingDash = $true
        $videoUrl = [string]$dash.VideoUrl
        $audioUrl = [string]$dash.AudioUrl
        if ($dash.Width -gt 0 -and $dash.Height -gt 0) { $quality = "$($dash.Width)x$($dash.Height)" }
        Write-Host "Vídeo disponível apenas em DASH; usando manifesto do Threads."
    }
}

if ([string]::IsNullOrWhiteSpace($videoUrl)) {
    throw "Nenhuma versão de vídeo disponível foi encontrada."
}
Write-Host "Qualidade: $quality"

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
    if ($usingDash -and -not [string]::IsNullOrWhiteSpace($audioUrl)) {
        $tempAudio = Join-Path $env:TEMP ("video-dl-threads-audio-" + [Guid]::NewGuid().ToString("N") + ".m4a")
        Write-Host "Baixando áudio DASH temporário..."
        Download-File $audioUrl $tempAudio
        Write-Host "Convertendo áudio: $outputPath"
        Convert-Audio $tempAudio $outputPath $AudioFormat
        Remove-Item -LiteralPath $tempAudio -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Baixando vídeo temporário..."
        Download-File $videoUrl $tempVideo
        Write-Host "Extraindo áudio: $outputPath"
        Convert-Audio $tempVideo $outputPath $AudioFormat
        Remove-Item -LiteralPath $tempVideo -Force -ErrorAction SilentlyContinue
    }
    Register-VideoDlDownload $contentIdentity $outputPath $postUrl $shortcode
} else {
    $desired = Join-Path $OutputDir ($FileBase + "." + $VideoContainer)
    $decision = Resolve-VideoDlTarget $contentIdentity $desired $postUrl $shortcode ([bool]$Force)
    if ($decision.Skip) { Write-Host ""; Write-Host "Salvo: $($decision.Path)" -ForegroundColor Green; return }
    $outputPath = [string]$decision.Path

    if ($usingDash) {
        Write-Host "Baixando/juntando streams DASH: $outputPath"
        Merge-ThreadsDashVideo $videoUrl $audioUrl $outputPath $VideoContainer
    } elseif ($VideoContainer -eq "mp4") {
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
