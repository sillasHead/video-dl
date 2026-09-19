param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = "Stop"
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
$EmbedReferer = "https://embed.wcostream.com/"

function Get-WebText([string]$Target, [string]$Referer = $null) {
    $headers = @{ "User-Agent" = $UserAgent; "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }
    if ($Referer) { $headers["Referer"] = $Referer }
    return [string](Invoke-WebRequest -Uri $Target -UseBasicParsing -TimeoutSec 25 -Headers $headers).Content
}

function Resolve-AbsoluteUrl([string]$Base, [string]$Candidate) {
    $value = [System.Net.WebUtility]::HtmlDecode($Candidate) -replace '\\/', '/'
    return ([Uri]::new([Uri]$Base, $value)).AbsoluteUri
}

function Resolve-WcoVideo([string]$PageUrl) {
    $pageHtml = Get-WebText $PageUrl
    $m = [regex]::Match($pageHtml, '(?is)<iframe[^>]+src=["'']([^"'']*embed\.wcostream\.com/inc/embed/(?:index|embed)\.php\?[^"'']+)["'']')
    if (-not $m.Success) {
        $m = [regex]::Match($pageHtml, '(?is)(https?://embed\.wcostream\.com/inc/embed/(?:index|embed)\.php\?[^"''<\s]+)')
    }
    if (-not $m.Success) { throw "Embed do WCOStream não encontrado." }

    $embedUrl = Resolve-AbsoluteUrl $PageUrl $m.Groups[1].Value
    $embedHtml = Get-WebText $embedUrl $PageUrl
    $m2 = [regex]::Match($embedHtml, '(?is)\$\.getJSON\(\s*["'']([^"'']*getvidlink\.php\?[^"'']+)["'']')
    if (-not $m2.Success) { throw "getvidlink.php não encontrado." }

    $getVidLinkUrl = Resolve-AbsoluteUrl $embedUrl $m2.Groups[1].Value
    $linkInfo = Invoke-RestMethod -Uri $getVidLinkUrl -Method Get -TimeoutSec 25 -Headers @{ "User-Agent" = $UserAgent; "Referer" = $EmbedReferer; "Accept" = "application/json, text/javascript, */*; q=0.01" }
    if (-not $linkInfo.enc -or -not $linkInfo.server) { throw "enc/server ausente na resposta do WCOStream." }

    $resolver = ([string]$linkInfo.server).TrimEnd('/') + "/getvid?evid=" + [Uri]::EscapeDataString([string]$linkInfo.enc) + "&json"
    $final = Invoke-RestMethod -Uri $resolver -Method Get -TimeoutSec 25 -Headers @{ "User-Agent" = $UserAgent; "Referer" = $EmbedReferer; "Accept" = "*/*" }
    $mediaUrl = ([string]$final).Trim('"') -replace '\\/', '/'
    if (-not $mediaUrl) { throw "URL final do vídeo não retornada." }
    return $mediaUrl
}

try {
    $mediaUrl = Resolve-WcoVideo $Url
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $curl) { throw "curl.exe não encontrado." }

    Write-Host "WCOStream: fonte encontrada." -ForegroundColor Cyan
    & $curl.Source -L --fail --retry 3 --continue-at - -H "Accept: */*" -H "Range: bytes=0-" -H "Referer: $EmbedReferer" -H "User-Agent: $UserAgent" $mediaUrl -o $OutputPath
    if ($LASTEXITCODE -ne 0) { throw "curl falhou com código $LASTEXITCODE." }
    Write-Host "WCOStream: download concluído." -ForegroundColor Green
} catch {
    Write-Host "ERRO WCOStream: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
