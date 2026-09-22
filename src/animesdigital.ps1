# animesdigital.ps1
# Parser/resolver específico para páginas de episódio e temporada do AnimesDigital.

function ConvertFrom-AnimesDigitalHtmlFragment([string]$Html) {
    if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
    $text = [System.Net.WebUtility]::HtmlDecode($Html)
    $text = [regex]::Replace($text, '(?is)<script\b.*?</script>|<style\b.*?</style>', ' ')
    $text = [regex]::Replace($text, '(?i)<br\s*/?>', ' ')
    $text = [regex]::Replace($text, '<[^>]+>', ' ')
    $text = [regex]::Replace($text, '\s+', ' ').Trim()
    return $text
}

function Test-AnimesDigitalSeasonUrl([string]$Url) {
    try {
        $uri = [Uri]$Url
        return ($uri.Host -match '(?i)(^|\.)animesdigital\.org$' -and $uri.AbsolutePath -match '(?i)^/anime/')
    } catch {
        return $false
    }
}

function Get-AnimesDigitalStreamUrlFromHtml([string]$Html) {
    if ([string]::IsNullOrWhiteSpace($Html)) { return $null }
    $decoded = [System.Net.WebUtility]::HtmlDecode($Html)

    # O player atual usa api.anivideo.net/videohls.php?d=<manifesto HLS>.
    # Aceita tanto d=https://... quanto o mesmo valor percent-encoded.
    $match = [regex]::Match(
        $decoded,
        '(?i)[?&]d=(?<stream>https?(?::|%3A)[^&"''<>\s]*?\.m3u8(?:\?[^&"''<>\s]*)?)'
    )
    if ($match.Success) {
        $candidate = [string]$match.Groups['stream'].Value
        for ($i = 0; $i -lt 2; $i++) {
            try {
                $unescaped = [Uri]::UnescapeDataString($candidate)
                if ($unescaped -eq $candidate) { break }
                $candidate = $unescaped
            } catch { break }
        }
        if ($candidate -match '(?i)^https?://.+\.m3u8(?:\?.*)?$') { return $candidate }
    }

    # Fallback para páginas que exponham o manifesto diretamente.
    $direct = [regex]::Match($decoded, '(?i)https?://[^"''<>\s]+\.m3u8(?:\?[^"''<>\s]*)?')
    if ($direct.Success) { return [string]$direct.Value }

    $encoded = [regex]::Match($decoded, '(?i)https?%3A%2F%2F[^"''<>\s&]+?\.m3u8')
    if ($encoded.Success) {
        try { return [Uri]::UnescapeDataString([string]$encoded.Value) } catch { }
    }
    return $null
}

function Get-AnimesDigitalMetadataFromHtml([string]$Html, [string]$Url = "") {
    $decoded = [System.Net.WebUtility]::HtmlDecode([string]$Html)
    $plain = ConvertFrom-AnimesDigitalHtmlFragment $decoded

    $h1 = ""
    $h1Match = [regex]::Match($decoded, '(?is)<h1\b[^>]*>(?<value>.*?)</h1>')
    if ($h1Match.Success) {
        $h1 = ConvertFrom-AnimesDigitalHtmlFragment ([string]$h1Match.Groups['value'].Value)
    }

    $seriesRaw = ""
    $episode = $null
    $infoMatch = [regex]::Match(
        $plain,
        '(?i)\bAnime:\s*(?<series>.+?)\s+Epis[oó]dio:\s*0*(?<episode>\d+)\b'
    )
    if ($infoMatch.Success) {
        $seriesRaw = ([string]$infoMatch.Groups['series'].Value).Trim()
        $episode = [int]$infoMatch.Groups['episode'].Value
    }

    if ($null -eq $episode -and -not [string]::IsNullOrWhiteSpace($h1)) {
        $episodeMatch = [regex]::Match($h1, '(?i)(?:Desenho|Epis[oó]dio)\s*0*(?<episode>\d+)\b')
        if ($episodeMatch.Success) { $episode = [int]$episodeMatch.Groups['episode'].Value }
    }

    if ([string]::IsNullOrWhiteSpace($seriesRaw)) {
        $seriesRaw = $h1
        if ($null -ne $episode) {
            $seriesRaw = [regex]::Replace(
                $seriesRaw,
                '(?i)\s+(?:Desenho|Epis[oó]dio)\s*0*' + [regex]::Escape([string]$episode) + '\b.*$',
                ''
            ).Trim()
        }
    }

    $season = $null
    $seasonMatch = [regex]::Match($seriesRaw, '(?i)(?<season>\d+)\s*(?:ª|º|a|o)?\s*Temporada\b')
    if (-not $seasonMatch.Success -and -not [string]::IsNullOrWhiteSpace($h1)) {
        $seasonMatch = [regex]::Match($h1, '(?i)(?<season>\d+)\s*(?:ª|º|a|o)?\s*Temporada\b')
    }
    if ($seasonMatch.Success) { $season = [int]$seasonMatch.Groups['season'].Value }

    $series = $seriesRaw
    if (-not [string]::IsNullOrWhiteSpace($series)) {
        $series = [regex]::Replace(
            $series,
            '(?i)\s+\d+\s*(?:ª|º|a|o)?\s*Temporada\b.*$',
            ''
        ).Trim()
        $series = [regex]::Replace(
            $series,
            '(?i)\s+(?:Dublado|Legendado|Dual\s+Áudio|Dual\s+Audio)\s*$',
            ''
        ).Trim()
    }

    $title = ""
    if ($null -ne $episode -and -not [string]::IsNullOrWhiteSpace($h1)) {
        $titleMatch = [regex]::Match(
            $h1,
            '(?i)(?:Desenho|Epis[oó]dio)\s*0*' + [regex]::Escape([string]$episode) + '\s*[-–—:]\s*(?<title>.+)$'
        )
        if ($titleMatch.Success) {
            $title = ([string]$titleMatch.Groups['title'].Value).Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($title) -and $null -ne $episode) {
        $title = "Episódio {0:D2}" -f [int]$episode
    }
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "Vídeo" }

    $audio = $null
    $audioMatch = [regex]::Match($plain, '(?i)\bAudio:\s*(?<audio>.+?)(?:\s+Descri[cç][aã]o:|\s+Coment[aá]rios|$)')
    if ($audioMatch.Success) { $audio = ([string]$audioMatch.Groups['audio'].Value).Trim() }

    $id = $null
    if (-not [string]::IsNullOrWhiteSpace($Url) -and $Url -match '(?i)/video/a/(\d+)') {
        $id = [string]$Matches[1]
    }

    return [PSCustomObject]@{
        Title = $title
        Series = $series
        SeriesConfidence = $(if ([string]::IsNullOrWhiteSpace($series)) { "nenhuma" } else { "alta" })
        SeasonNumber = $season
        EpisodeNumber = $episode
        Date = (Get-Date -Format "yyyy-MM-dd")
        Id = $id
        Source = "animesdigital-page"
        StreamUrl = Get-AnimesDigitalStreamUrlFromHtml $decoded
        Audio = $audio
    }
}

function Get-AnimesDigitalEpisodeUrlsFromHtml([string]$Html, [string]$BaseUrl = "https://animesdigital.org/") {
    if ([string]::IsNullOrWhiteSpace($Html)) { return @() }
    $decoded = [System.Net.WebUtility]::HtmlDecode($Html)
    try { $base = [Uri]$BaseUrl } catch { $base = [Uri]"https://animesdigital.org/" }

    $items = @()
    $seen = @{}
    $matches = [regex]::Matches(
        $decoded,
        '(?is)<a\b[^>]*href\s*=\s*["''](?<href>[^"'']*/video/a/\d+/?[^"'']*)["''][^>]*>(?<label>.*?)</a>'
    )
    $order = 0
    foreach ($match in $matches) {
        $href = [System.Net.WebUtility]::HtmlDecode([string]$match.Groups['href'].Value).Trim()
        if ([string]::IsNullOrWhiteSpace($href)) { continue }
        try { $absolute = ([Uri]::new($base, $href)).AbsoluteUri } catch { continue }
        if ($seen.ContainsKey($absolute)) { continue }
        $seen[$absolute] = $true

        $label = ConvertFrom-AnimesDigitalHtmlFragment ([string]$match.Groups['label'].Value)
        $episode = $null
        $episodeMatch = [regex]::Match($label, '(?i)(?:Desenho|Epis[oó]dio)\s*0*(?<episode>\d+)\b')
        if ($episodeMatch.Success) { $episode = [int]$episodeMatch.Groups['episode'].Value }

        $items += [PSCustomObject]@{
            Url = $absolute
            Episode = $episode
            Order = $order
        }
        $order++
    }

    return @(
        $items |
            Sort-Object @{ Expression = { if ($null -eq $_.Episode) { [int]::MaxValue } else { [int]$_.Episode } } }, Order |
            ForEach-Object { [string]$_.Url }
    )
}

function Get-AnimesDigitalPageHtml([string]$Url) {
    $headers = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
        "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        "Referer" = "https://animesdigital.org/"
    }
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 -Headers $headers
    return [string]$response.Content
}

function Get-AnimesDigitalEpisodeMetadata([string]$Url) {
    if (Test-AnimesDigitalSeasonUrl $Url) {
        throw "A URL informada é uma página de temporada. Use --series para baixar os episódios."
    }
    $html = Get-AnimesDigitalPageHtml $Url
    $metadata = Get-AnimesDigitalMetadataFromHtml $html $Url
    if ([string]::IsNullOrWhiteSpace([string]$metadata.StreamUrl)) {
        throw "AnimesDigital: não foi possível localizar o manifesto HLS deste episódio."
    }
    return $metadata
}

function Get-AnimesDigitalSeasonEpisodeUrls([string]$Url) {
    $html = Get-AnimesDigitalPageHtml $Url
    $urls = @(Get-AnimesDigitalEpisodeUrlsFromHtml $html $Url)
    if ($urls.Count -eq 0) {
        throw "AnimesDigital: nenhum episódio foi encontrado na página da temporada."
    }
    return $urls
}
