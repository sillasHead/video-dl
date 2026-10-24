$ErrorActionPreference = "Stop"

$sourcePath = Join-Path $PSScriptRoot "..\src\video-dl.ps1"
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8

function Assert-Contains([string]$Needle, [string]$Message) {
    if (-not $source.Contains($Needle)) { throw $Message }
}

Assert-Contains 'return "twitter"' "X/Twitter nao esta sendo classificado."
Assert-Contains 'https://api.fxtwitter.com/2/status/$StatusId' "Endpoint FxTwitter ausente."
Assert-Contains 'function Get-TwitterFxVideoCandidates' "Parser de video FxTwitter ausente."
Assert-Contains 'function Select-TwitterFxBestVideo' "Seletor de melhor video FxTwitter ausente."
Assert-Contains 'Invoke-TwitterFallback $Url $output' "Fallback X/Twitter nao esta conectado ao fluxo principal."

# Isola as funcoes puras de parsing/selecao para fixture local.
$start = $source.IndexOf('function Get-TwitterFxVideoCandidates')
$end = $source.IndexOf('function Invoke-TwitterFallback', $start)
if ($start -lt 0 -or $end -lt 0) { throw "Nao foi possivel isolar os helpers X/Twitter." }
Invoke-Expression $source.Substring($start, $end - $start)

$status = [PSCustomObject]@{
    media = [PSCustomObject]@{
        videos = @(
            [PSCustomObject]@{
                width = 720
                height = 1280
                formats = @(
                    [PSCustomObject]@{ container = "m3u8"; codec = "h264"; bitrate = 0; url = "https://video.example/master.m3u8" },
                    [PSCustomObject]@{ container = "mp4"; codec = "h264"; bitrate = 450000; width = 720; height = 1280; url = "https://video.example/720.mp4" },
                    [PSCustomObject]@{ container = "mp4"; codec = "h264"; bitrate = 1200000; width = 1080; height = 1920; url = "https://video.example/1080.mp4" }
                )
            }
        )
    }
}

$candidates = @(Get-TwitterFxVideoCandidates $status)
if ($candidates.Count -ne 3) { throw "Fixture deveria produzir 3 formatos." }
$best = Select-TwitterFxBestVideo $candidates
if ($null -eq $best) { throw "Nenhum formato foi selecionado." }
if ([string]$best.Url -ne "https://video.example/1080.mp4") { throw "Melhor MP4 nao foi selecionado." }

$quoted = [PSCustomObject]@{
    quote = [PSCustomObject]@{
        media = [PSCustomObject]@{
            videos = @(
                [PSCustomObject]@{
                    width = 640
                    height = 360
                    formats = @([PSCustomObject]@{ container = "mp4"; codec = "h264"; bitrate = 200000; url = "https://video.example/quote.mp4" })
                }
            )
        }
    }
}
$quotedCandidates = @(Get-TwitterFxVideoCandidates $quoted)
if ($quotedCandidates.Count -ne 1 -or [string]$quotedCandidates[0].Url -ne "https://video.example/quote.mp4") {
    throw "Video em post citado nao foi encontrado."
}

Write-Host "X/Twitter fallback regression checks: OK" -ForegroundColor Green
