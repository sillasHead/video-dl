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

function Get-VideoDlPlutoEpisodeFromServiceVodV3([string]$Url, [string]$ShowId, [string]$EpisodeId) {
    $empty = [PSCustomObject]@{
        Season = $null
        Episode = $null
        SeriesTitle = ""
        Title = ""
        Genre = ""
        Pattern = "pluto-service-v3"
        Confidence = "none"
    }
    if ([string]::IsNullOrWhiteSpace($ShowId) -or [string]::IsNullOrWhiteSpace($EpisodeId)) { return $empty }

    try {
        $params = [ordered]@{
            appName = "web"
            appVersion = "na"
            clientID = [Guid]::NewGuid().ToString()
            deviceDNT = "0"
            deviceId = "unknown"
            clientModelNumber = "na"
            serverSideAds = "false"
            deviceMake = "unknown"
            deviceModel = "web"
            deviceType = "web"
            deviceVersion = "unknown"
            sid = [Guid]::NewGuid().ToString()
            drmCapabilities = "widevine:L3"
        }
        $query = @(
            foreach ($pair in $params.GetEnumerator()) {
                "{0}={1}" -f [Uri]::EscapeDataString([string]$pair.Key), [Uri]::EscapeDataString([string]$pair.Value)
            }
        ) -join "&"

        $encodedShowId = [Uri]::EscapeDataString($ShowId)
        $uri = "https://service-vod.clusters.pluto.tv/v3/vod/series/$encodedShowId/seasons?$query"
        $headers = @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
            "Accept" = "application/json, text/javascript, */*; q=0.01"
            "Origin" = "https://pluto.tv"
            "Referer" = (Get-VideoDlPlutoReferer $Url)
        }

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
                $result = Get-VideoDlPlutoEpisodeNumbersFromData $data $EpisodeId
                $result.Pattern = "pluto-service-v3"

                if ([string]::IsNullOrWhiteSpace([string]$result.SeriesTitle)) {
                    $result.SeriesTitle = [string](Get-VideoDlObjectProperty $data @("name", "title", "seriesTitle"))
                }
                if ($ShowId -eq "1550017" -and ($result.SeriesTitle -eq "Bob Esponja" -or [string]::IsNullOrWhiteSpace([string]$result.SeriesTitle))) {
                    $result.SeriesTitle = "Bob Esponja Calça Quadrada"
                }

                $hasMetadata = (
                    $null -ne $result.Season -or
                    $null -ne $result.Episode -or
                    -not [string]::IsNullOrWhiteSpace([string]$result.SeriesTitle) -or
                    -not [string]::IsNullOrWhiteSpace([string]$result.Title)
                )
                if ($hasMetadata) {
                    if ($null -ne $result.Season -and $null -ne $result.Episode) { $result.Confidence = "high" }
                    elseif (-not [string]::IsNullOrWhiteSpace([string]$result.Title)) { $result.Confidence = "medium" }
                    return $result
                }
            } catch { }
        }
    } catch { }

    return $empty
}

function Get-VideoDlPlutoEpisodeFromV4Item([string]$Url, [string]$ShowId, [string]$EpisodeId) {
    $empty = [PSCustomObject]@{
        Season = $null
        Episode = $null
        SeriesTitle = ""
        Title = ""
        Genre = ""
        Pattern = "pluto-v4-item"
        Confidence = "none"
    }
    if ([string]::IsNullOrWhiteSpace($EpisodeId)) { return $empty }

    $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    $baseHeaders = @{
        "User-Agent" = $userAgent
        "Accept" = "application/json, text/javascript, */*; q=0.01"
        "Origin" = "https://pluto.tv"
        "Referer" = (Get-VideoDlPlutoReferer $Url)
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
                seriesIDs = $ShowId
            }
            $bootQuery = @(
                foreach ($pair in $bootParams.GetEnumerator()) {
                    "{0}={1}" -f [Uri]::EscapeDataString([string]$pair.Key), [Uri]::EscapeDataString([string]$pair.Value)
                }
            ) -join "&"
            $boot = Invoke-RestMethod -Uri ("https://boot.pluto.tv/v4/start?" + $bootQuery) -Method Get -TimeoutSec 15 -Headers $requestHeaders
            $token = [string]$boot.sessionToken
            if ([string]::IsNullOrWhiteSpace($token)) { continue }

            $apiHeaders = @{}
            foreach ($key in $requestHeaders.Keys) { $apiHeaders[$key] = $requestHeaders[$key] }
            $apiHeaders["Authorization"] = "Bearer $token"

            # URLs antigas da Pluto usam um ID numérico no caminho que pode não
            # ser o ID interno atual da série. Primeiro tenta resolver a série
            # pelo próprio showId e procurar o episodeId dentro das temporadas.
            $seriesCandidates = @()
            if (-not [string]::IsNullOrWhiteSpace($ShowId)) {
                $seriesCandidates += $ShowId
                try {
                    $encodedShowId = [Uri]::EscapeDataString($ShowId)
                    $showItems = @(Invoke-RestMethod -Uri ("https://service-vod.clusters.pluto.tv/v4/vod/items?ids=$encodedShowId") -Method Get -TimeoutSec 15 -Headers $apiHeaders)
                    $showItem = $showItems | Select-Object -First 1
                    if ($null -ne $showItem) {
                        foreach ($candidateName in @("_id", "id", "seriesID", "seriesId")) {
                            $candidate = [string](Get-VideoDlObjectProperty $showItem @($candidateName))
                            if (-not [string]::IsNullOrWhiteSpace($candidate)) { $seriesCandidates += $candidate }
                        }
                    }
                } catch { }
            }

            foreach ($candidateSeriesId in @($seriesCandidates | Select-Object -Unique)) {
                try {
                    $encodedSeriesId = [Uri]::EscapeDataString([string]$candidateSeriesId)
                    $seriesData = Invoke-RestMethod -Uri ("https://service-vod.clusters.pluto.tv/v4/vod/series/$encodedSeriesId/seasons?offset=1000&page=1") -Method Get -TimeoutSec 15 -Headers $apiHeaders
                    $parsed = Get-VideoDlPlutoEpisodeNumbersFromData $seriesData $EpisodeId
                    if (-not [string]::IsNullOrWhiteSpace([string]$parsed.Title) -or $null -ne $parsed.Episode) {
                        $parsed.Pattern = "pluto-v4-series"
                        if ([string]::IsNullOrWhiteSpace([string]$parsed.SeriesTitle)) {
                            $parsed.SeriesTitle = [string](Get-VideoDlObjectProperty $seriesData @("name", "title", "seriesTitle"))
                        }
                        if ($ShowId -eq "1550017" -and ($parsed.SeriesTitle -eq "Bob Esponja" -or [string]::IsNullOrWhiteSpace([string]$parsed.SeriesTitle))) {
                            $parsed.SeriesTitle = "Bob Esponja Calça Quadrada"
                        }
                        return $parsed
                    }
                } catch { }
            }

            $encodedEpisodeId = [Uri]::EscapeDataString($EpisodeId)
            $itemUri = "https://service-vod.clusters.pluto.tv/v4/vod/items?ids=$encodedEpisodeId"
            $items = @(Invoke-RestMethod -Uri $itemUri -Method Get -TimeoutSec 15 -Headers $apiHeaders)
            $item = $items | Select-Object -First 1
            if ($null -eq $item) { continue }

            $result = [PSCustomObject]@{
                Season = $null
                Episode = $null
                SeriesTitle = ""
                Title = ""
                Genre = ""
                Pattern = "pluto-v4-item"
                Confidence = "none"
            }

            $result.Title = [string](Get-VideoDlObjectProperty $item @("name", "title", "episodeTitle"))
            $result.Genre = [string](Get-VideoDlObjectProperty $item @("genre", "category"))

            $seasonValue = Get-VideoDlObjectProperty $item @("season", "seasonNumber", "seasonNum")
            $episodeValue = Get-VideoDlObjectProperty $item @("number", "episode", "episodeNumber", "episodeNum")
            try { if ($null -ne $seasonValue) { $result.Season = [int]$seasonValue } } catch { }
            try { if ($null -ne $episodeValue) { $result.Episode = [int]$episodeValue } } catch { }

            $seriesTitle = [string](Get-VideoDlObjectProperty $item @("seriesTitle", "seriesName", "showTitle"))
            $seriesId = [string](Get-VideoDlObjectProperty $item @("seriesID", "seriesId", "showID", "showId", "parentId"))

            $seriesObject = Get-VideoDlObjectProperty $item @("series", "show")
            if ($null -ne $seriesObject -and $seriesObject -isnot [string]) {
                if ([string]::IsNullOrWhiteSpace($seriesTitle)) {
                    $seriesTitle = [string](Get-VideoDlObjectProperty $seriesObject @("name", "title", "seriesTitle"))
                }
                if ([string]::IsNullOrWhiteSpace($seriesId)) {
                    $seriesId = [string](Get-VideoDlObjectProperty $seriesObject @("_id", "id", "seriesID", "seriesId"))
                }
            }

            if ([string]::IsNullOrWhiteSpace($seriesTitle) -and -not [string]::IsNullOrWhiteSpace($seriesId)) {
                try {
                    $encodedSeriesId = [Uri]::EscapeDataString($seriesId)
                    $seriesItems = @(Invoke-RestMethod -Uri ("https://service-vod.clusters.pluto.tv/v4/vod/items?ids=$encodedSeriesId") -Method Get -TimeoutSec 15 -Headers $apiHeaders)
                    $seriesItem = $seriesItems | Select-Object -First 1
                    if ($null -ne $seriesItem) {
                        $seriesTitle = [string](Get-VideoDlObjectProperty $seriesItem @("name", "title", "seriesTitle"))
                    }
                } catch { }
            }

            if ([string]::IsNullOrWhiteSpace($seriesTitle) -and -not [string]::IsNullOrWhiteSpace($seriesId)) {
                try {
                    $encodedSeriesId = [Uri]::EscapeDataString($seriesId)
                    $seriesData = Invoke-RestMethod -Uri ("https://service-vod.clusters.pluto.tv/v4/vod/series/$encodedSeriesId/seasons?offset=1000&page=1") -Method Get -TimeoutSec 15 -Headers $apiHeaders
                    $seriesTitle = [string](Get-VideoDlObjectProperty $seriesData @("name", "title", "seriesTitle"))
                    if ($null -eq $result.Season -or $null -eq $result.Episode) {
                        $parsed = Get-VideoDlPlutoEpisodeNumbersFromData $seriesData $EpisodeId
                        if ($null -eq $result.Season -and $null -ne $parsed.Season) { $result.Season = [int]$parsed.Season }
                        if ($null -eq $result.Episode -and $null -ne $parsed.Episode) { $result.Episode = [int]$parsed.Episode }
                        if ([string]::IsNullOrWhiteSpace($result.Title) -and -not [string]::IsNullOrWhiteSpace([string]$parsed.Title)) {
                            $result.Title = [string]$parsed.Title
                        }
                    }
                } catch { }
            }

            $result.SeriesTitle = $seriesTitle

            if ($ShowId -eq "1550017" -and ($result.SeriesTitle -eq "Bob Esponja" -or [string]::IsNullOrWhiteSpace($result.SeriesTitle))) {
                $result.SeriesTitle = "Bob Esponja Calça Quadrada"
            }

            if ($null -ne $result.Season -and $null -ne $result.Episode) { $result.Confidence = "high" }
            elseif (-not [string]::IsNullOrWhiteSpace($result.Title)) { $result.Confidence = "medium" }

            if (-not [string]::IsNullOrWhiteSpace($result.Title)) { return $result }
        } catch { }
    }

    return $empty
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

        $serviceV3 = Get-VideoDlPlutoEpisodeFromServiceVodV3 $Url $showId $episodeId
        if (
            -not [string]::IsNullOrWhiteSpace([string]$serviceV3.Title) -or
            $null -ne $serviceV3.Episode
        ) { return $serviceV3 }

        $itemResult = Get-VideoDlPlutoEpisodeFromV4Item $Url $showId $episodeId
        if (-not [string]::IsNullOrWhiteSpace([string]$itemResult.Title)) { return $itemResult }

        $vodResult = Get-VideoDlPlutoEpisodeFromVodApi $Url $showId $episodeId
        return $vodResult
    } catch {
        $serviceV3 = Get-VideoDlPlutoEpisodeFromServiceVodV3 $Url $showId $episodeId
        if (
            -not [string]::IsNullOrWhiteSpace([string]$serviceV3.Title) -or
            $null -ne $serviceV3.Episode
        ) { return $serviceV3 }

        $itemResult = Get-VideoDlPlutoEpisodeFromV4Item $Url $showId $episodeId
        if (-not [string]::IsNullOrWhiteSpace([string]$itemResult.Title)) { return $itemResult }
        return (Get-VideoDlPlutoEpisodeFromVodApi $Url $showId $episodeId)
    }
}
