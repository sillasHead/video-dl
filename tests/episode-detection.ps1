$ErrorActionPreference = "Stop"
$root = Join-Path $PSScriptRoot ".."
. (Join-Path $root "src\episode-detection.ps1")
. (Join-Path $root "src\archive.ps1")

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
    seasons = @(
        [PSCustomObject]@{
            number = 1
            episodes = @(
                [PSCustomObject]@{ _id = "episode-a"; number = 2; season = 1 },
                [PSCustomObject]@{ _id = "episode-b"; number = 4; season = 1 }
            )
        }
    )
}
$plutoLegacy = Get-VideoDlPlutoEpisodeNumbersFromData $plutoLegacyData "episode-b"
if ([int]$plutoLegacy.Season -ne 1 -or [int]$plutoLegacy.Episode -ne 4 -or $plutoLegacy.Confidence -ne "high") {
    throw "Pluto legacy metadata parsing failed."
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
