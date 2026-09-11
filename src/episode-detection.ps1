function ConvertTo-VideoDlMetadataText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $value = [System.Net.WebUtility]::HtmlDecode($Text)
    $value = [regex]::Replace($value, '<[^>]+>', ' ')
    $value = [regex]::Replace($value, '\s+', ' ')
    return $value.Trim()
}

function Get-VideoDlEpisodeNumbersFromText([string]$Text) {
    $normalized = ConvertTo-VideoDlMetadataText $Text
    $result = [PSCustomObject]@{
        Season = $null
        Episode = $null
        Pattern = $null
        Confidence = "none"
        Index = -1
        Text = $normalized
    }
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $result }

    $patterns = @(
        [PSCustomObject]@{
            Name = "pluto-labeled"
            Confidence = "high"
            Regex = '(?<![A-Za-z0-9])S\s*0*(\d+)\s*\(\s*Season\s+0*\d+\s*\)\s*E\s*0*(\d+)\s*\(\s*Episode\s+0*\d+\s*\)'
        },
        [PSCustomObject]@{
            Name = "season-episode"
            Confidence = "high"
            Regex = '(?<![A-Za-z0-9])S(?:eason)?\s*0*(\d+)\s*[-_.:| ]*\s*E(?:pisode|p\.?)?\s*0*(\d+)(?!\d)'
        },
        [PSCustomObject]@{
            Name = "season-x-episode"
            Confidence = "high"
            Regex = '(?<!\d)0*(\d+)\s*x\s*0*(\d+)(?!\d)'
        },
        [PSCustomObject]@{
            Name = "temporada-episodio"
            Confidence = "high"
            Regex = '(?<![A-Za-z0-9])(?:T|Temporada)\s*0*(\d+)\s*[-_.:| ]*\s*(?:E|EP|Epis(?:o|\u00F3)dio)\s*0*(\d+)(?!\d)'
        }
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($normalized, $pattern.Regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { continue }
        $result.Season = [int]$match.Groups[1].Value
        $result.Episode = [int]$match.Groups[2].Value
        $result.Pattern = [string]$pattern.Name
        $result.Confidence = [string]$pattern.Confidence
        $result.Index = [int]$match.Index
        return $result
    }

    return $result
}

function Get-VideoDlEpisodeOnlyFromText([string]$Text) {
    $normalized = ConvertTo-VideoDlMetadataText $Text
    $result = [PSCustomObject]@{
        Episode = $null
        Pattern = $null
        Confidence = "none"
        Index = -1
        Text = $normalized
    }
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $result }

    $match = [regex]::Match(
        $normalized,
        '(?<![A-Za-z0-9])(?:E|EP|Episode|Epis(?:o|\u00F3)dio)\s*0*(\d+)(?!\d)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($match.Success) {
        $result.Episode = [int]$match.Groups[1].Value
        $result.Pattern = "episode-only"
        $result.Confidence = "medium"
        $result.Index = [int]$match.Index
    }
    return $result
}

function Get-VideoDlObjectProperty([object]$Object, [string[]]$Names) {
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $property.Value
        }
    }
    return $null
}

function Get-VideoDlPlutoEpisodeNumbersFromData([object]$Data, [string]$EpisodeId) {
    $result = [PSCustomObject]@{
        Season = $null
        Episode = $null
        Pattern = "pluto-api"
        Confidence = "none"
    }
    if ($null -eq $Data -or [string]::IsNullOrWhiteSpace($EpisodeId)) { return $result }

    $root = $Data
    if ($null -eq $root.PSObject.Properties["seasons"] -and $null -ne $root.PSObject.Properties["data"]) {
        $root = $root.data
    }
    if ($null -eq $root -or $null -eq $root.PSObject.Properties["seasons"]) { return $result }

    foreach ($seasonItem in @($root.seasons)) {
        $seasonNumber = Get-VideoDlObjectProperty $seasonItem @("number", "season", "seasonNumber")
        foreach ($episodeItem in @($seasonItem.episodes)) {
            $candidateId = [string](Get-VideoDlObjectProperty $episodeItem @("_id", "id", "contentId"))
            if ([string]::IsNullOrWhiteSpace($candidateId) -or $candidateId -ine $EpisodeId) { continue }

            $episodeNumber = Get-VideoDlObjectProperty $episodeItem @("number", "episode", "episodeNumber")
            $episodeSeason = Get-VideoDlObjectProperty $episodeItem @("season", "seasonNumber")
            if ($null -eq $episodeSeason) { $episodeSeason = $seasonNumber }

            try { if ($null -ne $episodeSeason) { $result.Season = [int]$episodeSeason } } catch { }
            try { if ($null -ne $episodeNumber) { $result.Episode = [int]$episodeNumber } } catch { }
            if ($null -ne $result.Season -or $null -ne $result.Episode) { $result.Confidence = "high" }
            return $result
        }
    }
    return $result
}

function Get-VideoDlPlutoEpisodeNumbers([string]$Url) {
    $empty = [PSCustomObject]@{
        Season = $null
        Episode = $null
        Pattern = "pluto-api"
        Confidence = "none"
    }
    if ([string]::IsNullOrWhiteSpace($Url)) { return $empty }

    $showId = $null
    $episodeId = $null
    if ($Url -match '/(?:shows|on-demand/series)/([^/?#]+)') { $showId = $Matches[1] }
    if ($Url -match '/episode/([^/?#]+)') { $episodeId = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($showId) -or [string]::IsNullOrWhiteSpace($episodeId)) { return $empty }

    try {
        $apiUrl = "https://api.pluto.tv/v3/vod/series/$showId/seasons?includeItems=true&deviceType=web"
        $data = Invoke-RestMethod -Uri $apiUrl -Method Get -TimeoutSec 15 -Headers @{ "User-Agent" = "Mozilla/5.0" }
        return (Get-VideoDlPlutoEpisodeNumbersFromData $data $episodeId)
    } catch {
        return $empty
    }
}
