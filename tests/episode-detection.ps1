$ErrorActionPreference = "Stop"
$root = Join-Path $PSScriptRoot ".."
. (Join-Path $root "src\episode-detection.ps1")
. (Join-Path $root "src\archive.ps1")
. (Join-Path $root "src\media-resolver.ps1")
. (Join-Path $root "src\animesdigital.ps1")

function Assert-EpisodePair([string]$Text, [int]$Season, [int]$Episode) {
    $result = Get-VideoDlEpisodeNumbersFromText $Text
    if ($null -eq $result.Season -or $null -eq $result.Episode -or [int]$result.Season -ne $Season -or [int]$result.Episode -ne $Episode) {
        throw "Could not parse '$Text'. Expected S$Season E$Episode; got S$($result.Season) E$($result.Episode)."
    }
}

Assert-EpisodePair "S01E02 - Title" 1 2
Assert-EpisodePair "S1.E2 Title" 1 2
Assert-EpisodePair "Season 1 Episode 2 - Title" 1 2
Assert-EpisodePair "Season 1 Ep 2 - Title" 1 2
Assert-EpisodePair "1x02 - Title" 1 2
Assert-EpisodePair "01x02 - Title" 1 2
Assert-EpisodePair "Temporada 1 Episodio 2 - Title" 1 2
$accentedEpisode = "Temporada 1 Epis$([char]0x00F3)dio 2 - Title"
Assert-EpisodePair $accentedEpisode 1 2
Assert-EpisodePair "T1E2 - Title" 1 2
Assert-EpisodePair "S1 (Season 1)E2 (Episode 2) Bolhas de sabao / Calca rasgada" 1 2
Assert-EpisodePair '<h1>S1 (Season 1)</h1><span>E4 (Episode 4)</span> Neighbors' 1 4

$ambiguous = Get-VideoDlEpisodeNumbersFromText "Trailer 102"
if ($null -ne $ambiguous.Season -or $null -ne $ambiguous.Episode) {
    throw "Ambiguous number 102 must not be converted automatically."
}

$episodeOnly = Get-VideoDlEpisodeOnlyFromText "Episode 7 - Title"
if ([int]$episodeOnly.Episode -ne 7) { throw "Episode-only pattern failed." }

$plutoGraphQlData = [PSCustomObject]@{
    data = [PSCustomObject]@{
        fullEpisodes = [PSCustomObject]@{
            episodes = @(
                [PSCustomObject]@{ contentId = "episode-a"; seasonNum = "1"; episodeNum = "2"; seriesTitle = "Bob Esponja"; title = "Primeiro título"; genre = "Kids" },
                [PSCustomObject]@{ contentId = "episode-b"; seasonNum = "1"; episodeNum = "4"; seriesTitle = "Bob Esponja"; title = "Bolhas de sabão / Calça rasgada"; genre = "Kids" }
            )
        }
    }
}
$plutoGraphQl = Get-VideoDlPlutoEpisodeNumbersFromData $plutoGraphQlData "episode-b"
if ([int]$plutoGraphQl.Season -ne 1 -or [int]$plutoGraphQl.Episode -ne 4 -or $plutoGraphQl.Confidence -ne "high") {
    throw "Pluto GraphQL metadata parsing failed."
}
if ($plutoGraphQl.SeriesTitle -ne "Bob Esponja" -or $plutoGraphQl.Title -ne "Bolhas de sabão / Calça rasgada") {
    throw "Pluto GraphQL title parsing failed."
}

$plutoLegacyData = [PSCustomObject]@{
    name = "Bob Esponja"
    seasons = @(
        [PSCustomObject]@{
            number = 1
            episodes = @(
                [PSCustomObject]@{ _id = "episode-a"; number = 2; season = 1; name = "Primeiro título" },
                [PSCustomObject]@{ _id = "episode-b"; number = 4; season = 1; name = "Título real do episódio" }
            )
        }
    )
}
$plutoLegacy = Get-VideoDlPlutoEpisodeNumbersFromData $plutoLegacyData "episode-b"
if ([int]$plutoLegacy.Season -ne 1 -or [int]$plutoLegacy.Episode -ne 4 -or $plutoLegacy.Confidence -ne "high") {
    throw "Pluto legacy metadata parsing failed."
}
if ($plutoLegacy.SeriesTitle -ne "Bob Esponja" -or $plutoLegacy.Title -ne "Título real do episódio") {
    throw "Pluto legacy title parsing failed."
}

# Generic media resolver: common embed/player patterns should resolve without
# adding a site-specific downloader.
$genericEncodedEmbed = @'
<html><body>
<iframe src="https://player.example/embed.php?d=https%3A%2F%2Fcdn.example%2Fshow%2F02%2Findex.m3u8&amp;token=abc"></iframe>
</body></html>
'@
$genericEncodedUrls = @(Get-VideoDlHlsUrlsFromHtml $genericEncodedEmbed "https://site.example/watch/2")
if ($genericEncodedUrls.Count -lt 1 -or $genericEncodedUrls[0] -ne "https://cdn.example/show/02/index.m3u8") {
    throw "Generic encoded iframe HLS parsing failed: $($genericEncodedUrls -join ', ')."
}

$genericSourceHtml = @'
<html><body><video controls><source src="/media/episode/master.m3u8?token=xyz"></video></body></html>
'@
$genericSourceUrls = @(Get-VideoDlHlsUrlsFromHtml $genericSourceHtml "https://site.example/watch/2")
if ($genericSourceUrls.Count -lt 1 -or $genericSourceUrls[0] -ne "https://site.example/media/episode/master.m3u8?token=xyz") {
    throw "Generic source-tag HLS parsing failed: $($genericSourceUrls -join ', ')."
}

$genericJsHtml = @'
<script>
const player = { file: "https:\/\/cdn.example\/video\/index.m3u8" };
</script>
'@
$genericJsUrls = @(Get-VideoDlHlsUrlsFromHtml $genericJsHtml "https://site.example/watch/2")
if ($genericJsUrls.Count -lt 1 -or $genericJsUrls[0] -ne "https://cdn.example/video/index.m3u8") {
    throw "Generic JavaScript HLS parsing failed: $($genericJsUrls -join ', ')."
}

$genericIframeHtml = '<iframe src="/player/episode-2"></iframe>'
$genericIframeUrls = @(Get-VideoDlIframeUrlsFromHtml $genericIframeHtml "https://site.example/watch/2")
if ($genericIframeUrls.Count -ne 1 -or $genericIframeUrls[0] -ne "https://site.example/player/episode-2") {
    throw "Generic iframe URL parsing failed: $($genericIframeUrls -join ', ')."
}

$directHls = Resolve-VideoDlEmbeddedHls "https://cdn.example/video/index.m3u8" 2
if ($null -eq $directHls -or $directHls.Kind -ne "hls" -or $directHls.Source -ne "direct") {
    throw "Direct HLS resolver path failed."
}

# AnimesDigital: a página de episódio deve fornecer metadados confiáveis e o HLS real
# sem depender do título genérico "index" do manifesto.
$animesDigitalEpisodeHtml = @'
<html>
  <body>
    <h1>Coragem, o C&atilde;o Covarde 1&ordf; Temporada Dublado Desenho 02</h1>
    <iframe src="https://api.anivideo.net/videohls.php?d=https%3A%2F%2Fcdn-sv01.maximaimg.online%2Fstream%2Fc%2Fcoragem-o-cao-covarde-dublado%2F02.mp4%2Findex.m3u8&amp;nocache1790041132"></iframe>
    <div>Anime: Coragem, o C&atilde;o Covarde 1&ordf; Temporada Dublado</div>
    <div>Epis&oacute;dio: 2</div>
    <div>Audio: Portugu&ecirc;s</div>
    <div>Descri&ccedil;&atilde;o:</div>
  </body>
</html>
'@
$ad = Get-AnimesDigitalMetadataFromHtml $animesDigitalEpisodeHtml "https://animesdigital.org/video/a/112077/"
$expectedSeries = "Coragem, o C" + [char]0x00E3 + "o Covarde"
if ($ad.Series -ne $expectedSeries) { throw "AnimesDigital series parsing failed: '$($ad.Series)'." }
if ([int]$ad.SeasonNumber -ne 1 -or [int]$ad.EpisodeNumber -ne 2) {
    throw "AnimesDigital season/episode parsing failed."
}
$expectedEpisodeTitle = "Epis" + [char]0x00F3 + "dio 02"
if ($ad.Title -ne $expectedEpisodeTitle) { throw "AnimesDigital fallback episode title failed: '$($ad.Title)'." }
$expectedAudio = "Portugu" + [char]0x00EA + "s"
if ($ad.Audio -ne $expectedAudio) { throw "AnimesDigital audio parsing failed: '$($ad.Audio)'." }
if ($ad.Id -ne "112077") { throw "AnimesDigital source id parsing failed: '$($ad.Id)'." }
$expectedHls = "https://cdn-sv01.maximaimg.online/stream/c/coragem-o-cao-covarde-dublado/02.mp4/index.m3u8"
if ($ad.StreamUrl -ne $expectedHls) { throw "AnimesDigital HLS extraction failed: '$($ad.StreamUrl)'." }

# A página de temporada lista os episódios em ordem decrescente; o downloader
# precisa deduplicar e ordenar antes de iniciar o lote.
$animesDigitalSeasonHtml = @'
<html><body>
<a href="/video/a/112076/">Coragem, o C&amp;atilde;o Covarde 1&amp;ordf; Temporada Dublado Desenho 03</a>
<a href="/video/a/112077/">Coragem, o C&amp;atilde;o Covarde 1&amp;ordf; Temporada Dublado Desenho 02</a>
<a href="/video/a/112078/">Coragem, o C&amp;atilde;o Covarde 1&amp;ordf; Temporada Dublado Desenho 01</a>
<a href="/video/a/112077/">02 Epis&amp;oacute;dio</a>
</body></html>
'@
$adUrls = @(Get-AnimesDigitalEpisodeUrlsFromHtml $animesDigitalSeasonHtml "https://animesdigital.org/anime/a/coragem-o-cao-covarde-dublado-1a-temporada")
if ($adUrls.Count -ne 3) { throw "AnimesDigital season list should contain 3 unique episodes; got $($adUrls.Count)." }
if ($adUrls[0] -ne "https://animesdigital.org/video/a/112078/" -or
    $adUrls[1] -ne "https://animesdigital.org/video/a/112077/" -or
    $adUrls[2] -ne "https://animesdigital.org/video/a/112076/") {
    throw "AnimesDigital season episode ordering failed: $($adUrls -join ', ')."
}
if (-not (Test-AnimesDigitalSeasonUrl "https://animesdigital.org/anime/a/coragem-o-cao-covarde-dublado-1a-temporada")) {
    throw "AnimesDigital season URL detection failed."
}
if (Test-AnimesDigitalSeasonUrl "https://animesdigital.org/video/a/112077/") {
    throw "AnimesDigital episode URL was incorrectly classified as a season page."
}

# Regression test for v0.4.4: a file already saved as S100E2100 must be moved to
# the corrected S01E05 path without downloading it again.
$originalArchiveDir = $script:VideoDlArchiveDir
$originalArchivePath = $script:VideoDlArchivePath
$tempRoot = Join-Path $env:TEMP ("video-dl-archive-test-" + [Guid]::NewGuid().ToString("N"))
try {
    $script:VideoDlArchiveDir = Join-Path $tempRoot ".video-dl"
    $script:VideoDlArchivePath = Join-Path $script:VideoDlArchiveDir "downloads.json"

    $oldDir = Join-Path $tempRoot "Bob Esponja Calca Quadrada\Season 100"
    New-Item -ItemType Directory -Path $oldDir -Force | Out-Null
    $oldPath = Join-Path $oldDir "S100E2100 - Entrega de pizza _ Lar doce abacaxi [720p].mp4"
    Set-Content -LiteralPath $oldPath -Value "test" -Encoding ASCII

    $identity = "pluto:episode-test"
    $url = "https://pluto.tv/br/shows/show-test/episode/episode-test/"
    Register-VideoDlDownload $identity $oldPath $url "episode-test"

    $desiredDir = Join-Path $tempRoot "Bob Esponja Calca Quadrada\Season 01"
    $desiredPath = Join-Path $desiredDir "S01E05 - Entrega de pizza _ Lar doce abacaxi.mp4"
    $decision = Resolve-VideoDlTarget $identity $desiredPath $url "episode-test" $false $true
    $expectedPath = Join-Path $desiredDir "S01E05 - Entrega de pizza _ Lar doce abacaxi [720p].mp4"

    if (-not $decision.Skip -or -not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
        throw "Series reconciliation did not move the existing file to the corrected path."
    }
    if (Test-Path -LiteralPath $oldPath) { throw "Old wrong series path still exists after reconciliation." }
    $entry = Get-VideoDlArchiveEntry $identity
    if ([string]$entry.path -ine [System.IO.Path]::GetFullPath($expectedPath)) {
        throw "Archive was not updated after series reconciliation."
    }
} finally {
    $script:VideoDlArchiveDir = $originalArchiveDir
    $script:VideoDlArchivePath = $originalArchivePath
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Episode detection tests: OK" -ForegroundColor Green
