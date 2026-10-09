$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "..\src\th-dl.ps1"
$source = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

function Assert-Contains([string]$Needle, [string]$Message) {
    if (-not $source.Contains($Needle)) { throw $Message }
}

Assert-Contains 'Get-ThreadsCrawlerHtml' "Crawler fallback ausente."
Assert-Contains 'Googlebot/2.1' "User-Agent de crawler ausente."
Assert-Contains 'Get-ThreadsPostFromHtml' "Parser de JSON do Threads ausente."
Assert-Contains 'Find-ThreadsPostInObject' "Busca recursiva pelo shortcode ausente."
Assert-Contains 'carousel_media' "Fallback de carousel ausente."
Assert-Contains '$crawlerHtml = Get-ThreadsCrawlerHtml $postUrl' "Fallback do crawler nao e acionado apos falha do th."

# Fixture minimal: target post is not the first object in the JSON.
$html = @'
<html><body>
<script type="application/json">{"noise":{"code":"OTHER","video_versions":[{"url":"https://bad.invalid/x.mp4","width":1920,"height":1080}]},"target":{"code":"DePi57PnWsS","video_versions":[{"url":"https://cdn.example/low.mp4","width":640,"height":360},{"url":"https://cdn.example/high.mp4","width":1080,"height":1920}]}}</script>
</body></html>
'@

# Import only helper definitions, avoiding script execution.
$helperStart = $source.IndexOf('function Get-ThreadsCrawlerHtml')
$helperEnd = $source.IndexOf("if (-not (Get-Command th", $helperStart)
if ($helperStart -lt 0 -or $helperEnd -lt 0) { throw "Não foi possível isolar os helpers do Threads." }
Invoke-Expression $source.Substring($helperStart, $helperEnd - $helperStart)

$post = Get-ThreadsPostFromHtml $html "DePi57PnWsS"
if ($null -eq $post) { throw "Fixture não encontrou o post alvo." }
$versions = @(Get-ThreadsVideoVersions $post)
if ($versions.Count -ne 2) { throw "Fixture deveria retornar 2 versões." }
$best = Select-ThreadsBestVideo $versions
if ([string]$best.url -ne "https://cdn.example/high.mp4") { throw "Seleção da melhor versão falhou." }

Write-Host "Threads crawler regression checks: OK" -ForegroundColor Green
