from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"marker not found: {label}")
    return text.replace(old, new, 1)


root = Path('.')

# main dispatcher
path = root / 'src' / 'video-dl.ps1'
text = path.read_text(encoding='utf-8')
text = replace_once(text, '$Version = "0.4.4"', '$Version = "0.4.5"', 'main version')

bad_html_fallback = '''\n        if ($null -eq $result.Season -or $null -eq $result.Episode) {\n            $parsed = Get-VideoDlEpisodeNumbersFromText $html\n            if ($null -eq $result.Season -and $null -ne $parsed.Season) { $result.Season = [int]$parsed.Season }\n            if ($null -eq $result.Episode -and $null -ne $parsed.Episode) { $result.Episode = [int]$parsed.Episode }\n        }\n'''
text = replace_once(text, bad_html_fallback, '\n', 'main raw html fallback')

text = replace_once(
    text,
    '    $yt = if ((Get-SiteKind $Url) -eq "pluto") { $null } else { Get-YtDlpMetadata $Url $CookieBrowser $CookieFile }',
    '    $siteKind = Get-SiteKind $Url\n    $yt = if ($siteKind -eq "pluto") { $null } else { Get-YtDlpMetadata $Url $CookieBrowser $CookieFile }',
    'main site kind'
)

old_probe = '''    $info = Apply-TitleEpisodeGuess $info\n    if ($ProbeEpisodeNumbers -and ($null -eq $info.SeasonNumber -or $null -eq $info.EpisodeNumber)) {\n        $page = Get-PageEpisodeNumbers $Url\n        if ($null -eq $info.SeasonNumber -and $null -ne $page.Season) { $info.SeasonNumber = [int]$page.Season }\n        if ($null -eq $info.EpisodeNumber -and $null -ne $page.Episode) { $info.EpisodeNumber = [int]$page.Episode }\n    }'''
new_probe = '''    $info = Apply-TitleEpisodeGuess $info\n    if ($ProbeEpisodeNumbers -and $siteKind -eq "pluto" -and ($null -eq $info.SeasonNumber -or $null -eq $info.EpisodeNumber)) {\n        $plutoNumbers = Get-VideoDlPlutoEpisodeNumbers $Url\n        if ($null -eq $info.SeasonNumber -and $null -ne $plutoNumbers.Season) { $info.SeasonNumber = [int]$plutoNumbers.Season }\n        if ($null -eq $info.EpisodeNumber -and $null -ne $plutoNumbers.Episode) { $info.EpisodeNumber = [int]$plutoNumbers.Episode }\n    }\n    if ($ProbeEpisodeNumbers -and ($null -eq $info.SeasonNumber -or $null -eq $info.EpisodeNumber)) {\n        $page = Get-PageEpisodeNumbers $Url\n        if ($null -eq $info.SeasonNumber -and $null -ne $page.Season) { $info.SeasonNumber = [int]$page.Season }\n        if ($null -eq $info.EpisodeNumber -and $null -ne $page.Episode) { $info.EpisodeNumber = [int]$page.Episode }\n    }'''
text = replace_once(text, old_probe, new_probe, 'main pluto api probe')
path.write_text(text, encoding='utf-8')

# Pluto helper
path = root / 'src' / 'pluto-dl.ps1'
text = path.read_text(encoding='utf-8')
text = replace_once(text, bad_html_fallback.replace('$result.Season', '$result.season').replace('$result.Episode', '$result.episode').replace('$parsed.Season', '$parsed.Season').replace('$parsed.Episode', '$parsed.Episode'), '\n', 'pluto raw html fallback')

old_page_probe = '''if ($null -eq $season -or $null -eq $episode) {\n    $pageNumbers = Try-PageNumbers $Url\n    if ($null -eq $season -and $null -ne $pageNumbers.season) { $season = [int]$pageNumbers.season }\n    if ($null -eq $episode -and $null -ne $pageNumbers.episode) { $episode = [int]$pageNumbers.episode }\n}'''
new_page_probe = '''if ($null -eq $season -or $null -eq $episode) {\n    $apiNumbers = Get-VideoDlPlutoEpisodeNumbers $Url\n    if ($null -eq $season -and $null -ne $apiNumbers.Season) { $season = [int]$apiNumbers.Season }\n    if ($null -eq $episode -and $null -ne $apiNumbers.Episode) { $episode = [int]$apiNumbers.Episode }\n}\n\nif ($null -eq $season -or $null -eq $episode) {\n    $pageNumbers = Try-PageNumbers $Url\n    if ($null -eq $season -and $null -ne $pageNumbers.season) { $season = [int]$pageNumbers.season }\n    if ($null -eq $episode -and $null -ne $pageNumbers.episode) { $episode = [int]$pageNumbers.episode }\n}'''
text = replace_once(text, old_page_probe, new_page_probe, 'pluto api before page')
text = text.replace('Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false', 'Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false ([bool]$SeriesMode)')
text = text.replace('Resolve-VideoDlTarget $Identity $desiredMkv $Url $SourceId $false', 'Resolve-VideoDlTarget $Identity $desiredMkv $Url $SourceId $false ([bool]$SeriesMode)')
path.write_text(text, encoding='utf-8')

# Archive: reconcile files already downloaded under a bad SxxExx path.
path = root / 'src' / 'archive.ps1'
text = path.read_text(encoding='utf-8')
marker = 'function Resolve-VideoDlTarget(\n'
if marker not in text:
    raise SystemExit('marker not found: archive resolve function')
helpers = r'''function Get-VideoDlSeriesCoreStem([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $stem = [regex]::Replace($stem, '\s+\[\d+p\]$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $stem = [regex]::Replace($stem, '^S\d{1,4}E\d{1,6}\s*-\s*', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $stem.Trim()
}

function Try-ReconcileVideoDlSeriesPath([object]$Entry, [string]$DesiredPath, [string]$Identity, [string]$Url, [string]$SourceId) {
    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace($DesiredPath)) { return $null }
    $oldPath = [string]$Entry.path
    if ([string]::IsNullOrWhiteSpace($oldPath) -or -not (Test-Path -LiteralPath $oldPath -PathType Leaf)) { return $null }

    $oldCore = Get-VideoDlSeriesCoreStem $oldPath
    $desiredCore = Get-VideoDlSeriesCoreStem $DesiredPath
    if ([string]::IsNullOrWhiteSpace($oldCore) -or $oldCore -ine $desiredCore) { return $null }

    $oldStem = [System.IO.Path]::GetFileNameWithoutExtension($oldPath)
    $quality = ""
    $qualityMatch = [regex]::Match($oldStem, '(\s+\[\d+p\])$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($qualityMatch.Success) { $quality = $qualityMatch.Groups[1].Value }

    $desiredDir = Split-Path -Parent $DesiredPath
    $desiredStem = [System.IO.Path]::GetFileNameWithoutExtension($DesiredPath)
    $oldExt = [System.IO.Path]::GetExtension($oldPath)
    $targetPath = Join-Path $desiredDir ($desiredStem + $quality + $oldExt)

    try {
        if ([System.IO.Path]::GetFullPath($oldPath) -ieq [System.IO.Path]::GetFullPath($targetPath)) { return $oldPath }
    } catch { }
    if (Test-Path -LiteralPath $targetPath) { return $null }

    if (-not (Test-Path -LiteralPath $desiredDir -PathType Container)) {
        New-Item -ItemType Directory -Path $desiredDir -Force | Out-Null
    }

    $oldDir = Split-Path -Parent $oldPath
    try {
        Move-Item -LiteralPath $oldPath -Destination $targetPath -Force
        Register-VideoDlDownload $Identity $targetPath $Url $SourceId
        Write-Host "Organização corrigida: $([System.IO.Path]::GetFileName($targetPath))" -ForegroundColor Cyan
        if ($oldDir -ine $desiredDir -and (Test-Path -LiteralPath $oldDir -PathType Container)) {
            $remaining = @(Get-ChildItem -LiteralPath $oldDir -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $oldDir -Force -ErrorAction SilentlyContinue }
        }
        return $targetPath
    } catch {
        return $null
    }
}

'''
text = text.replace(marker, helpers + marker, 1)
old_sig = '''function Resolve-VideoDlTarget(\n    [string]$Identity,\n    [string]$DesiredPath,\n    [string]$Url,\n    [string]$SourceId,\n    [bool]$ForceOverwrite = $false\n) {'''
new_sig = '''function Resolve-VideoDlTarget(\n    [string]$Identity,\n    [string]$DesiredPath,\n    [string]$Url,\n    [string]$SourceId,\n    [bool]$ForceOverwrite = $false,\n    [bool]$ReconcileSeriesPath = $false\n) {'''
text = replace_once(text, old_sig, new_sig, 'archive signature')
old_entry = '''        $entry = Get-VideoDlArchiveEntry $Identity\n        if ($null -ne $entry) {\n            $oldPath = [string]$entry.path'''
new_entry = '''        $entry = Get-VideoDlArchiveEntry $Identity\n        if ($null -ne $entry -and $ReconcileSeriesPath) {\n            $reconciledPath = Try-ReconcileVideoDlSeriesPath $entry $DesiredPath $Identity $Url $SourceId\n            if (-not [string]::IsNullOrWhiteSpace([string]$reconciledPath)) {\n                return [PSCustomObject]@{ Skip = $true; Path = $reconciledPath; KnownIdentity = $true; Reconciled = $true }\n            }\n        }\n        if ($null -ne $entry) {\n            $oldPath = [string]$entry.path'''
text = replace_once(text, old_entry, new_entry, 'archive reconciliation hook')
path.write_text(text, encoding='utf-8')

# Version + installer
(root / 'VERSION').write_text('0.4.5\n', encoding='utf-8')
path = root / 'installer' / 'video-dl.iss'
text = path.read_text(encoding='utf-8')
text = replace_once(text, '#define MyAppVersion "0.4.4"', '#define MyAppVersion "0.4.5"', 'installer version')
path.write_text(text, encoding='utf-8')

# README note
path = root / 'README.md'
text = path.read_text(encoding='utf-8')
needle = 'A prioridade é: metadados estruturados do site/downloader, informações explícitas da página, padrões reconhecidos no título e, só então, pergunta/sequência automática. Números ambíguos como `102` não são convertidos automaticamente em `S01E02`. Na Pluto, o formato exibido pela própria página (`S1 (Season 1)E2 (Episode 2)`) também é reconhecido.'
replacement = 'A prioridade é: metadados estruturados do site/downloader, informações explícitas da página, padrões reconhecidos no título e, só então, pergunta/sequência automática. Números ambíguos como `102` não são convertidos automaticamente em `S01E02`. Na Pluto, temporada e episódio são consultados primeiro pela API de catálogo da própria Pluto; a página fica apenas como fallback estruturado, evitando falsos positivos encontrados no HTML bruto.'
text = replace_once(text, needle, replacement, 'readme pluto metadata')
path.write_text(text, encoding='utf-8')
