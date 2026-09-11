$ErrorActionPreference = "Stop"
. (Join-Path (Join-Path $PSScriptRoot "..") "src\episode-detection.ps1")

function Assert-EpisodePair([string]$Text, [int]$Season, [int]$Episode) {
    $result = Get-VideoDlEpisodeNumbersFromText $Text
    if ($null -eq $result.Season -or $null -eq $result.Episode -or [int]$result.Season -ne $Season -or [int]$result.Episode -ne $Episode) {
        throw "Falha ao interpretar '$Text'. Esperado S$Season E$Episode; obtido S$($result.Season) E$($result.Episode)."
    }
}

Assert-EpisodePair "S01E02 - Título" 1 2
Assert-EpisodePair "S1.E2 Título" 1 2
Assert-EpisodePair "Season 1 Episode 2 - Title" 1 2
Assert-EpisodePair "Season 1 Ep 2 - Title" 1 2
Assert-EpisodePair "1x02 - Título" 1 2
Assert-EpisodePair "01x02 - Título" 1 2
Assert-EpisodePair "Temporada 1 Episódio 2 - Título" 1 2
Assert-EpisodePair "T1E2 - Título" 1 2
Assert-EpisodePair "S1 (Season 1)E2 (Episode 2) Bolhas de sabão / Calça rasgada" 1 2
Assert-EpisodePair '<h1>S1 (Season 1)</h1><span>E4 (Episode 4)</span> Vizinhos náuticos terríveis' 1 4

$ambiguous = Get-VideoDlEpisodeNumbersFromText "Trailer 102"
if ($null -ne $ambiguous.Season -or $null -ne $ambiguous.Episode) {
    throw "Número ambíguo 102 não deve ser convertido automaticamente em temporada/episódio."
}

$episodeOnly = Get-VideoDlEpisodeOnlyFromText "Episode 7 - Title"
if ([int]$episodeOnly.Episode -ne 7) { throw "Falha no padrão de episódio isolado." }

Write-Host "Episode detection tests: OK" -ForegroundColor Green
