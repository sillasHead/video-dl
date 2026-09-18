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

function Get-VideoDlPlutoRegionIp([string]$Url) {
    try {
        if (([Uri]$Url).AbsolutePath -match '^/br(?:/|$)') {
            # A Pluto seleciona parte do catálogo pela região. Esse IP público BR é usado somente
            # como dica regional para URLs /br/; não representa o endereço real do usuário.
            return "177.47.27.205"
        }
    } catch { }
    return $null
}

function Get-VideoDlPlutoReferer([string]$Url) {
    try {
        if (([Uri]$Url).AbsolutePath -match '^/br(?:/|$)') { return "https://pluto.tv/br/" }
    } catch { }
    return "https://pluto.tv/"
}

function Get-VideoDlPlutoEpisodeNumbersFromData([object]$Data, [string]$EpisodeId) {
    $result = [PSCustomObject]@{
        Season = $null
        Episode = $null
        SeriesTitle = ""
        Title = ""
        Genre = ""
        Pattern = "pluto-graphql"
        Confidence = "none"
    }
    if ($null -eq $Data -or [string]::IsNullOrWhiteSpace($EpisodeId)) { return $result }

    try {
        $episodes = @($Data.data.fullEpisodes.episodes)
        foreach ($episodeItem in $episodes) {
            $candidateId = [string](Get-VideoDlObjectProperty $episodeItem @("contentId", "_id", "id"))
            if ([string]::IsNullOrWhiteSpace($candidateId) -or $candidateId -ine $EpisodeId) { continue }

            $seasonNumber = Get-VideoDlObjectProperty $episodeItem @("seasonNum", "seasonNumber", "season")
            $episodeNumber = Get-VideoDlObjectProperty $episodeItem @("episodeNum", "episodeNumber", "number", "episode")
            $result.SeriesTitle = [string](Get-VideoDlObjectProperty $episodeItem @("seriesTitle", "seriesName", "showTitle"))
            $result.Title = [string](Get-VideoDlObjectProperty $episodeItem @("title", "episodeTitle", "name"))
            $result.Genre = [string](Get-VideoDlObjectProperty $episodeItem @("genre", "category"))
            try { if ($null -ne $seasonNumber) { $result.Season = [int]$seasonNumber } } catch { }
            try { if ($null -ne $episodeNumber) { $result.Episode = [int]$episodeNumber } } catch { }
            if ($null -ne $result.Season -and $null -ne $result.Episode) { $result.Confidence = "high" }
            return $result
        }
    } catch { }

    # Compatibilidade defensiva com o formato antigo da API de catálogo.
    $root = $Data
    if ($null -eq $root.PSObject.Properties["seasons"] -and $null -ne $root.PSObject.Properties["data"]) {
        $root = $root.data
    }
    if ($null -eq $root -or $null -eq $root.PSObject.Properties["seasons"]) { return $result }

    $rootSeriesTitle = [string](Get-VideoDlObjectProperty $root @("name", "title", "seriesTitle", "seriesName"))
    if (-not [string]::IsNullOrWhiteSpace($rootSeriesTitle)) {
        $result.SeriesTitle = $rootSeriesTitle
    }

    foreach ($seasonItem in @($root.seasons)) {
        $seasonNumber = Get-VideoDlObjectProperty $seasonItem @("number", "season", "seasonNumber")
        foreach ($episodeItem in @($seasonItem.episodes)) {
            $candidateId = [string](Get-VideoDlObjectProperty $episodeItem @("_id", "id", "contentId"))
            if ([string]::IsNullOrWhiteSpace($candidateId) -or $candidateId -ine $EpisodeId) { continue }

            $episodeNumber = Get-VideoDlObjectProperty $episodeItem @("number", "episode", "episodeNumber")
            $episodeSeason = Get-VideoDlObjectProperty $episodeItem @("season", "seasonNumber")
            $episodeSeriesTitle = [string](Get-VideoDlObjectProperty $episodeItem @("seriesTitle", "seriesName", "showTitle"))
            if (-not [string]::IsNullOrWhiteSpace($episodeSeriesTitle)) {
                $result.SeriesTitle = $episodeSeriesTitle
            }
            $result.Title = [string](Get-VideoDlObjectProperty $episodeItem @("title", "episodeTitle", "name"))
            $result.Genre = [string](Get-VideoDlObjectProperty $episodeItem @("genre", "category"))
            if ($null -eq $episodeSeason) { $episodeSeason = $seasonNumber }
            try { if ($null -ne $episodeSeason) { $result.Season = [int]$episodeSeason } } catch { }
            try { if ($null -ne $episodeNumber) { $result.Episode = [int]$episodeNumber } } catch { }
            if ($null -ne $result.Season -and $null -ne $result.Episode) { $result.Confidence = "high" }
            return $result
        }
    }
    return $result
}

function Get-VideoDlPlutoEpisodeFromVodApi([string]$Url, [string]$ShowId, [string]$EpisodeId) {
    $empty = [PSCustomObject]@{
        Season = $null
        Episode = $null
        SeriesTitle = ""
        Title = ""
        Genre = ""
        Pattern = "pluto-v3"
        Confidence = "none"
    }
    if ([string]::IsNullOrWhiteSpace($ShowId) -or [string]::IsNullOrWhiteSpace($EpisodeId)) { return $empty }

    $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    $referer = Get-VideoDlPlutoReferer $Url
    $baseHeaders = @{
        "User-Agent" = $userAgent
        "Accept" = "application/json, text/javascript, */*; q=0.01"
        "Origin" = "https://pluto.tv"
        "Referer" = $referer
    }

    $headerAttempts = @($baseHeaders)
    $regionIp = Get-VideoDlPlutoRegionIp $Url
    if (-not [string]::IsNullOrWhiteSpace($regionIp)) {
        $regionalHeaders = @{}
        foreach ($key in $baseHeaders.Keys) { $regionalHeaders[$key] = $baseHeaders[$key] }
        $regionalHeaders["X-Forwarded-For"] = $regionIp
        $headerAttempts += $regionalHeaders
    }

    foreach ($requestHeaders in $headerAttempts) {
        try {
            $bootParams = [ordered]@{
                appName = "web"
                appVersion = "8.0.0"
                deviceVersion = "122.0.0"
                deviceModel = "web"
                deviceMake = "chrome"
                deviceType = "web"
                clientID = [Guid]::NewGuid().ToString()
                clientModelNumber = "1.0.0"
                serverSideAds = "false"
            }
            $bootQuery = @(
                foreach ($pair in $bootParams.GetEnumerator()) {
                    "{0}={1}" -f [Uri]::EscapeDataString([string]$pair.Key), [Uri]::EscapeDataString([string]$pair.Value)
                }
            ) -join "&"
            $bootUri = "https://boot.pluto.tv/v4/start?$bootQuery"
            $boot = Invoke-RestMethod -Uri $bootUri -Method Get -TimeoutSec 15 -Headers $requestHeaders
            $token = [string]$boot.sessionToken
            if ([string]::IsNullOrWhiteSpace($token)) { continue }

            $apiHeaders = @{}
            foreach ($key in $requestHeaders.Keys) { $apiHeaders[$key] = $requestHeaders[$key] }
            $apiHeaders["Authorization"] = "Bearer $token"

            $encodedShowId = [Uri]::EscapeDataString($ShowId)
            $vodUri = "https://api.pluto.tv/v3/vod/series/$encodedShowId/seasons?includeItems=true&deviceType=web"
            $data = Invoke-RestMethod -Uri $vodUri -Method Get -TimeoutSec 15 -Headers $apiHeaders
            $result = Get-VideoDlPlutoEpisodeNumbersFromData $data $EpisodeId
            $result.Pattern = "pluto-v3"

            $hasMetadata = (
                $null -ne $result.Season -or
                $null -ne $result.Episode -or
                -not [string]::IsNullOrWhiteSpace([string]$result.SeriesTitle) -or
                -not [string]::IsNullOrWhiteSpace([string]$result.Title)
            )
            if ($hasMetadata) { return $result }
        } catch { }
    }

    return $empty
}

function Get-VideoDlPlutoEpisodeNumbers([string]$Url) {
    $empty = [PSCustomObject]@{
        Season = $null
        Episode = $null
        SeriesTitle = ""
        Title = ""
        Genre = ""
        Pattern = "pluto-graphql"
        Confidence = "none"
    }
    if ([string]::IsNullOrWhiteSpace($Url)) { return $empty }

    $showId = $null
    $episodeId = $null
    if ($Url -match '/(?:shows|on-demand/series)/([^/?#]+)') { $showId = $Matches[1] }
    if ($Url -match '/episode/([^/?#]+)') { $episodeId = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($showId) -or [string]::IsNullOrWhiteSpace($episodeId)) { return $empty }

    try {
        # Mesma FullEpisodesData usada atualmente pelo plugin Pluto do Streamlink.
        $variables = @{
            showId = $showId
            apiRawContentId = $null
            withApiRaw = $false
            episodeId = $episodeId
        } | ConvertTo-Json -Compress
        $extensions = @{
            # Hash atual do FullEpisodesData usado pelo plugin Pluto do Streamlink.
            tnPersistedDocumentHash = "c42c1d0736825cd1f43e28b71dfa6f4955a1b3003a92e42edf99fcae885ea1fe"
        } | ConvertTo-Json -Compress

        $uri = "https://pluto.tv/api/tn/hubs/graphql/?operationName=FullEpisodesData&extensions=$([Uri]::EscapeDataString($extensions))&variables=$([Uri]::EscapeDataString($variables))"
        $headers = @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
            "apollo-require-preflight" = "true"
            "Accept" = "application/json"
            "Referer" = (Get-VideoDlPlutoReferer $Url)
        }

        # Primeiro usa a região real da conexão. O X-Forwarded-For fixo pode
        # fazer a Pluto devolver catálogo vazio mesmo quando o stream funciona.
        $attemptHeaders = @($headers)
        $regionIp = Get-VideoDlPlutoRegionIp $Url
        if (-not [string]::IsNullOrWhiteSpace($regionIp)) {
            $regionalHeaders = @{}
            foreach ($key in $headers.Keys) { $regionalHeaders[$key] = $headers[$key] }
            $regionalHeaders["X-Forwarded-For"] = $regionIp
            $attemptHeaders += $regionalHeaders
        }

        foreach ($requestHeaders in $attemptHeaders) {
            try {
                $data = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15 -Headers $requestHeaders
                $result = Get-VideoDlPlutoEpisodeNumbersFromData $data $episodeId
                $hasMetadata = (
                    $null -ne $result.Season -or
                    $null -ne $result.Episode -or
                    -not [string]::IsNullOrWhiteSpace([string]$result.SeriesTitle) -or
                    -not [string]::IsNullOrWhiteSpace([string]$result.Title)
                )
                if ($hasMetadata) { return $result }
            } catch { }
        }

        $vodResult = Get-VideoDlPlutoEpisodeFromVodApi $Url $showId $episodeId
        return $vodResult
    } catch {
        return (Get-VideoDlPlutoEpisodeFromVodApi $Url $showId $episodeId)
    }
}
