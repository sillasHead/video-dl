# media-resolver.ps1
# Generic embedded-media resolver. Keeps site metadata separate from media discovery.

function ConvertTo-VideoDlAbsoluteHttpUrl([string]$Value, [string]$BaseUrl = "") {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $candidate = [System.Net.WebUtility]::HtmlDecode($Value).Trim().Trim('"').Trim("'")
    $candidate = $candidate -replace '\\/', '/'

    for ($i = 0; $i -lt 2; $i++) {
        try {
            $decoded = [Uri]::UnescapeDataString($candidate)
            if ($decoded -eq $candidate) { break }
            $candidate = $decoded
        } catch {
            break
        }
    }

    if ($candidate.StartsWith("//")) {
        try {
            $base = [Uri]$BaseUrl
            $candidate = "$($base.Scheme):$candidate"
        } catch {
            $candidate = "https:$candidate"
        }
    }

    try {
        $absolute = [Uri]$candidate
        if ($absolute.IsAbsoluteUri -and $absolute.Scheme -in @("http", "https")) {
            return $absolute.AbsoluteUri
        }
    } catch { }

    if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        try {
            $base = [Uri]$BaseUrl
            $absolute = [Uri]::new($base, $candidate)
            if ($absolute.Scheme -in @("http", "https")) { return $absolute.AbsoluteUri }
        } catch { }
    }
    return $null
}

function Test-VideoDlHlsUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try {
        $uri = [Uri]$Url
        return ($uri.AbsolutePath -match '(?i)\.m3u8$')
    } catch {
        return ($Url -match '(?i)\.m3u8(?:[?#]|$)')
    }
}

function Get-VideoDlQueryParameterValues([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return @() }
    try { $uri = [Uri]$Url } catch { return @() }
    if ([string]::IsNullOrWhiteSpace($uri.Query)) { return @() }

    $interesting = @("d", "url", "src", "file", "source", "video", "stream", "hls", "playlist", "manifest")
    $values = @()
    foreach ($part in $uri.Query.TrimStart('?').Split('&')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $pair = $part.Split('=', 2)
        if ($pair.Count -lt 2) { continue }
        try { $name = [Uri]::UnescapeDataString([string]$pair[0]).ToLowerInvariant() } catch { $name = ([string]$pair[0]).ToLowerInvariant() }
        if ($name -notin $interesting) { continue }

        $value = [string]$pair[1]
        for ($i = 0; $i -lt 2; $i++) {
            try {
                $decoded = [Uri]::UnescapeDataString($value)
                if ($decoded -eq $value) { break }
                $value = $decoded
            } catch { break }
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) { $values += $value }
    }
    return @($values)
}

function Get-VideoDlHlsUrlFromValue([string]$Value, [string]$BaseUrl = "") {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $candidate = [System.Net.WebUtility]::HtmlDecode($Value).Trim()
    $candidate = $candidate -replace '\\/', '/'

    # Query parameters such as ?d=<encoded m3u8> are common in embed players.
    $queryUrl = ConvertTo-VideoDlAbsoluteHttpUrl $candidate $BaseUrl
    if (-not [string]::IsNullOrWhiteSpace($queryUrl)) {
        foreach ($nested in @(Get-VideoDlQueryParameterValues $queryUrl)) {
            $nestedUrl = ConvertTo-VideoDlAbsoluteHttpUrl $nested $queryUrl
            if (Test-VideoDlHlsUrl $nestedUrl) { return $nestedUrl }
        }
        if (Test-VideoDlHlsUrl $queryUrl) { return $queryUrl }
    }

    $decoded = $candidate
    for ($i = 0; $i -lt 2; $i++) {
        try {
            $next = [Uri]::UnescapeDataString($decoded)
            if ($next -eq $decoded) { break }
            $decoded = $next
        } catch { break }
    }

    # Absolute HLS URL inside JavaScript/text.
    $match = [regex]::Match(
        $decoded,
        '(?i)(?<url>https?://[^\s"''<>]+?\.m3u8(?:\?[^\s"''<>]*)?)'
    )
    if ($match.Success) {
        $url = ConvertTo-VideoDlAbsoluteHttpUrl ([string]$match.Groups['url'].Value) $BaseUrl
        if (Test-VideoDlHlsUrl $url) { return $url }
    }

    # Relative/protocol-relative value that itself points to HLS.
    if ($decoded -match '(?i)\.m3u8(?:[?#]|$)') {
        $url = ConvertTo-VideoDlAbsoluteHttpUrl $decoded $BaseUrl
        if (Test-VideoDlHlsUrl $url) { return $url }
    }
    return $null
}

function Get-VideoDlIframeUrlsFromHtml([string]$Html, [string]$BaseUrl) {
    if ([string]::IsNullOrWhiteSpace($Html)) { return @() }
    $decoded = [System.Net.WebUtility]::HtmlDecode($Html)
    $result = @()
    $seen = @{}

    foreach ($match in [regex]::Matches(
        $decoded,
        '(?is)<iframe\b[^>]*\bsrc\s*=\s*["''](?<value>[^"'']+)["'']'
    )) {
        $url = ConvertTo-VideoDlAbsoluteHttpUrl ([string]$match.Groups['value'].Value) $BaseUrl
        if ([string]::IsNullOrWhiteSpace($url) -or $seen.ContainsKey($url)) { continue }
        $seen[$url] = $true
        $result += $url
    }
    return @($result)
}

function Get-VideoDlHlsUrlsFromHtml([string]$Html, [string]$BaseUrl) {
    if ([string]::IsNullOrWhiteSpace($Html)) { return @() }

    $decoded = [System.Net.WebUtility]::HtmlDecode($Html)
    $decoded = $decoded -replace '\\/', '/'
    $result = @()
    $seen = @{}

    function Add-VideoDlHlsCandidate([string]$Value) {
        $url = Get-VideoDlHlsUrlFromValue $Value $BaseUrl
        if ([string]::IsNullOrWhiteSpace($url) -or $seen.ContainsKey($url)) { return }
        $seen[$url] = $true
        $script:VideoDlResolverScratch += $url
    }

    # Local scratch array avoids relying on pipeline output from the nested helper.
    $oldScratch = $script:VideoDlResolverScratch
    $script:VideoDlResolverScratch = @()
    try {
        # Native media tags.
        foreach ($match in [regex]::Matches(
            $decoded,
            '(?is)<(?:video|source)\b[^>]*\bsrc\s*=\s*["''](?<value>[^"'']+)["'']'
        )) {
            Add-VideoDlHlsCandidate ([string]$match.Groups['value'].Value)
        }

        # Common JavaScript/player keys.
        foreach ($match in [regex]::Matches(
            $decoded,
            '(?is)(?:\bfile|\bsrc|\bsource|\burl|\bhls|\bplaylist|\bmanifest)\s*[:=]\s*["''](?<value>[^"'']+)["'']'
        )) {
            Add-VideoDlHlsCandidate ([string]$match.Groups['value'].Value)
        }

        # Iframe URLs may carry the real HLS URL in query parameters.
        foreach ($iframe in @(Get-VideoDlIframeUrlsFromHtml $decoded $BaseUrl)) {
            Add-VideoDlHlsCandidate $iframe
        }

        # Last pass: absolute m3u8 URLs visible anywhere in HTML/JS.
        foreach ($match in [regex]::Matches(
            $decoded,
            '(?i)https?://[^\s"''<>]+?\.m3u8(?:\?[^\s"''<>]*)?'
        )) {
            Add-VideoDlHlsCandidate ([string]$match.Value)
        }

        $result = @($script:VideoDlResolverScratch)
    } finally {
        $script:VideoDlResolverScratch = $oldScratch
    }

    return @($result)
}

function Invoke-VideoDlMediaPageRequest([string]$Url, [string]$Referer = "") {
    $headers = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
        "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    }
    if (-not [string]::IsNullOrWhiteSpace($Referer)) { $headers["Referer"] = $Referer }
    return Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15 -Headers $headers
}

function Resolve-VideoDlEmbeddedHls(
    [string]$Url,
    [int]$MaxDepth = 2,
    [int]$Depth = 0,
    [string]$Referer = "",
    [hashtable]$Visited = $null
) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    $absoluteUrl = ConvertTo-VideoDlAbsoluteHttpUrl $Url $Referer
    if ([string]::IsNullOrWhiteSpace($absoluteUrl)) { return $null }

    if (Test-VideoDlHlsUrl $absoluteUrl) {
        return [PSCustomObject]@{
            Url = $absoluteUrl
            Kind = "hls"
            Source = "direct"
            Referer = $Referer
            Depth = $Depth
        }
    }

    if ($null -eq $Visited) { $Visited = @{} }
    if ($Visited.ContainsKey($absoluteUrl)) { return $null }
    $Visited[$absoluteUrl] = $true
    if ($Depth -gt $MaxDepth) { return $null }

    try {
        $response = Invoke-VideoDlMediaPageRequest $absoluteUrl $Referer
        $html = [string]$response.Content
    } catch {
        return $null
    }

    $hlsUrls = @(Get-VideoDlHlsUrlsFromHtml $html $absoluteUrl)
    if ($hlsUrls.Count -gt 0) {
        return [PSCustomObject]@{
            Url = [string]$hlsUrls[0]
            Kind = "hls"
            Source = "html"
            Referer = $absoluteUrl
            Depth = $Depth
        }
    }

    if ($Depth -ge $MaxDepth) { return $null }

    $iframes = @(Get-VideoDlIframeUrlsFromHtml $html $absoluteUrl)
    $limit = [Math]::Min($iframes.Count, 8)
    for ($i = 0; $i -lt $limit; $i++) {
        $resolved = Resolve-VideoDlEmbeddedHls ([string]$iframes[$i]) $MaxDepth ($Depth + 1) $absoluteUrl $Visited
        if ($null -ne $resolved) { return $resolved }
    }
    return $null
}
