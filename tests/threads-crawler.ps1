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



# DASH-only fixture: some Threads posts expose no video_versions, only video_dash_manifest.
$dashXml = @'
<MPD>
  <Period>
    <AdaptationSet contentType="video" mimeType="video/mp4">
      <Representation id="v1" width="720" height="1280" bandwidth="400000"><BaseURL>https://cdn.example/720.mp4</BaseURL></Representation>
      <Representation id="v2" width="1080" height="1920" bandwidth="900000"><BaseURL>https://cdn.example/1080.mp4</BaseURL></Representation>
    </AdaptationSet>
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <Representation id="a1" bandwidth="128000" codecs="mp4a.40.2"><BaseURL>https://cdn.example/audio.m4a</BaseURL></Representation>
    </AdaptationSet>
  </Period>
</MPD>
'@
$dashPost = [PSCustomObject]@{ video_dash_manifest = $dashXml }
$manifest = Get-ThreadsDashManifest $dashPost
if ([string]::IsNullOrWhiteSpace($manifest)) { throw "Manifesto DASH nao encontrado." }
$streams = Select-ThreadsDashStreams $manifest
if ($null -eq $streams) { throw "Parser DASH nao retornou streams." }
if ($streams.VideoUrl -ne "https://cdn.example/1080.mp4") { throw "Selecao do melhor video DASH falhou." }
if ($streams.AudioUrl -ne "https://cdn.example/audio.m4a") { throw "Selecao do audio DASH falhou." }

Write-Host "Threads crawler regression checks: OK" -ForegroundColor Green
