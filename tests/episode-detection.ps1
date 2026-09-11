$ErrorActionPreference = "Stop"
. (Join-Path (Join-Path $PSScriptRoot "..") "src\episode-detection.ps1")

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

$plutoData = [PSCustomObject]@{
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
$pluto = Get-VideoDlPlutoEpisodeNumbersFromData $plutoData "episode-b"
if ([int]$pluto.Season -ne 1 -or [int]$pluto.Episode -ne 4 -or $pluto.Confidence -ne "high") {
    throw "Pluto API metadata parsing failed."
}

Write-Host "Episode detection tests: OK" -ForegroundColor Green
