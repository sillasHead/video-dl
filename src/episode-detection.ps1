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
            Regex = '(?<![A-Za-z0-9])(?:T|Temporada)\s*0*(\d+)\s*[-_.:| ]*\s*(?:E|EP|Epis[oó]dio)\s*0*(\d+)(?!\d)'
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
        '(?<![A-Za-z0-9])(?:E|EP|Episode|Epis[oó]dio)\s*0*(\d+)(?!\d)',
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
