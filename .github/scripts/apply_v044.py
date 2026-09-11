from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"marker not found: {label}")
    return text.replace(old, new, 1)


def replace_between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    i = text.find(start)
    if i < 0:
        raise SystemExit(f"start marker not found: {label}")
    j = text.find(end, i)
    if j < 0:
        raise SystemExit(f"end marker not found: {label}")
    return text[:i] + replacement.rstrip() + "\n\n" + text[j:]


root = Path('.')
main_path = root / 'src' / 'video-dl.ps1'
main = main_path.read_text(encoding='utf-8')
main = replace_once(main, '$Version = "0.4.3"', '$Version = "0.4.4"', 'main version')
main = replace_once(
    main,
    '$ArchiveHelperPath = Join-Path $ScriptRoot "archive.ps1"\nif (-not (Test-Path -LiteralPath $ArchiveHelperPath -PathType Leaf)) { throw "archive.ps1 não encontrado." }\n. $ArchiveHelperPath',
    '$ArchiveHelperPath = Join-Path $ScriptRoot "archive.ps1"\n$EpisodeDetectionPath = Join-Path $ScriptRoot "episode-detection.ps1"\nif (-not (Test-Path -LiteralPath $ArchiveHelperPath -PathType Leaf)) { throw "archive.ps1 não encontrado." }\nif (-not (Test-Path -LiteralPath $EpisodeDetectionPath -PathType Leaf)) { throw "episode-detection.ps1 não encontrado." }\n. $ArchiveHelperPath\n. $EpisodeDetectionPath',
    'main helper import'
)

page_function = r'''function Get-PageEpisodeNumbers([string]$Url) {
    $result = [PSCustomObject]@{ Season = $null; Episode = $null }
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 12 -Headers @{ "User-Agent" = "Mozilla/5.0" }
        $html = [string]$response.Content
        foreach ($pattern in @('"seasonNumber"\s*:\s*"?(\d+)"?', '\\"seasonNumber\\"\s*:\s*"?(\d+)"?', '"season_number"\s*:\s*"?(\d+)"?')) {
            $m = [regex]::Match($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) { $result.Season = [int]$m.Groups[1].Value; break }
        }
        foreach ($pattern in @('"episodeNumber"\s*:\s*"?(\d+)"?', '\\"episodeNumber\\"\s*:\s*"?(\d+)"?', '"episode_number"\s*:\s*"?(\d+)"?')) {
            $m = [regex]::Match($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) { $result.Episode = [int]$m.Groups[1].Value; break }
        }

        if ($null -eq $result.Season -or $null -eq $result.Episode) {
            $parsed = Get-VideoDlEpisodeNumbersFromText $html
            if ($null -eq $result.Season -and $null -ne $parsed.Season) { $result.Season = [int]$parsed.Season }
            if ($null -eq $result.Episode -and $null -ne $parsed.Episode) { $result.Episode = [int]$parsed.Episode }
        }
    } catch { }
    return $result
}'''
main = replace_between(main, 'function Get-PageEpisodeNumbers', 'function Apply-TitleEpisodeGuess', page_function, 'main page parser')

title_function = r'''function Apply-TitleEpisodeGuess([object]$Info) {
    $text = [string]$Info.Title
    if ([string]::IsNullOrWhiteSpace($text)) { return $Info }

    $parsed = Get-VideoDlEpisodeNumbersFromText $text
    if ($null -ne $parsed.Season -and $null -ne $parsed.Episode) {
        if ($null -eq $Info.SeasonNumber) { $Info.SeasonNumber = [int]$parsed.Season }
        if ($null -eq $Info.EpisodeNumber) { $Info.EpisodeNumber = [int]$parsed.Episode }
        if ([string]::IsNullOrWhiteSpace([string]$Info.Series) -and [int]$parsed.Index -gt 0) {
            $prefix = ([string]$parsed.Text).Substring(0, [int]$parsed.Index).Trim(' ', '-', '|', '–', '—', ':')
            if ($prefix.Length -ge 2) { $Info.Series = $prefix; $Info.SeriesConfidence = "baixa" }
        }
    }

    if ($null -eq $Info.EpisodeNumber) {
        $episodeOnly = Get-VideoDlEpisodeOnlyFromText $text
        if ($null -ne $episodeOnly.Episode) { $Info.EpisodeNumber = [int]$episodeOnly.Episode }
    }
    return $Info
}'''
main = replace_between(main, 'function Apply-TitleEpisodeGuess', 'function Get-LinkMetadata', title_function, 'main title parser')
main_path.write_text(main, encoding='utf-8')

pluto_path = root / 'src' / 'pluto-dl.ps1'
pluto = pluto_path.read_text(encoding='utf-8')
pluto = replace_once(
    pluto,
    '$ArchiveHelperPath = Join-Path $PSScriptRoot "archive.ps1"\nif (-not (Test-Path -LiteralPath $ArchiveHelperPath -PathType Leaf)) { throw "archive.ps1 não encontrado." }\n. $ArchiveHelperPath',
    '$ArchiveHelperPath = Join-Path $PSScriptRoot "archive.ps1"\n$EpisodeDetectionPath = Join-Path $PSScriptRoot "episode-detection.ps1"\nif (-not (Test-Path -LiteralPath $ArchiveHelperPath -PathType Leaf)) { throw "archive.ps1 não encontrado." }\nif (-not (Test-Path -LiteralPath $EpisodeDetectionPath -PathType Leaf)) { throw "episode-detection.ps1 não encontrado." }\n. $ArchiveHelperPath\n. $EpisodeDetectionPath',
    'pluto helper import'
)
pluto_page = r'''function Try-PageNumbers([string]$PageUrl) {
    $result = [PSCustomObject]@{ season = $null; episode = $null }
    try {
        $response = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -TimeoutSec 15 -Headers @{ "User-Agent" = "Mozilla/5.0" }
        $html = [string]$response.Content
        foreach ($pattern in @('"seasonNumber"\s*:\s*"?(\d+)"?', '\\"seasonNumber\\"\s*:\s*"?(\d+)"?', '"season_number"\s*:\s*"?(\d+)"?')) {
            $m = [regex]::Match($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) { $result.season = [int]$m.Groups[1].Value; break }
        }
        foreach ($pattern in @('"episodeNumber"\s*:\s*"?(\d+)"?', '\\"episodeNumber\\"\s*:\s*"?(\d+)"?', '"episode_number"\s*:\s*"?(\d+)"?')) {
            $m = [regex]::Match($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) { $result.episode = [int]$m.Groups[1].Value; break }
        }

        if ($null -eq $result.season -or $null -eq $result.episode) {
            $parsed = Get-VideoDlEpisodeNumbersFromText $html
            if ($null -eq $result.season -and $null -ne $parsed.Season) { $result.season = [int]$parsed.Season }
            if ($null -eq $result.episode -and $null -ne $parsed.Episode) { $result.episode = [int]$parsed.Episode }
        }
    } catch { }
    return $result
}'''
pluto = replace_between(pluto, 'function Try-PageNumbers', 'function Test-PythonModule', pluto_page, 'pluto page parser')
pluto_path.write_text(pluto, encoding='utf-8')

for installer_name in ('setup.ps1', 'install.ps1'):
    path = root / installer_name
    text = path.read_text(encoding='utf-8')
    text = replace_once(
        text,
        '@{ Remote = "src/archive.ps1"; Local = "archive.ps1" },',
        '@{ Remote = "src/archive.ps1"; Local = "archive.ps1" },\n        @{ Remote = "src/episode-detection.ps1"; Local = "episode-detection.ps1" },',
        f'{installer_name} download helper'
    )
    text = replace_once(
        text,
        'Copy-Item -LiteralPath (Join-Path $tempDir "archive.ps1") -Destination (Join-Path $appDir "archive.ps1") -Force',
        'Copy-Item -LiteralPath (Join-Path $tempDir "archive.ps1") -Destination (Join-Path $appDir "archive.ps1") -Force\n    Copy-Item -LiteralPath (Join-Path $tempDir "episode-detection.ps1") -Destination (Join-Path $appDir "episode-detection.ps1") -Force',
        f'{installer_name} copy helper'
    )
    path.write_text(text, encoding='utf-8')

iss_path = root / 'installer' / 'video-dl.iss'
iss = iss_path.read_text(encoding='utf-8')
iss = replace_once(iss, '#define MyAppVersion "0.4.3"', '#define MyAppVersion "0.4.4"', 'iss version')
iss = replace_once(
    iss,
    'Source: "..\\src\\archive.ps1"; DestDir: "{app}"; Flags: ignoreversion',
    'Source: "..\\src\\archive.ps1"; DestDir: "{app}"; Flags: ignoreversion\nSource: "..\\src\\episode-detection.ps1"; DestDir: "{app}"; Flags: ignoreversion',
    'iss helper'
)
iss_path.write_text(iss, encoding='utf-8')

(root / 'VERSION').write_text('0.4.4\n', encoding='utf-8')

readme_path = root / 'README.md'
readme = readme_path.read_text(encoding='utf-8')
readme = replace_once(
    readme,
    'No modo série, você cola os links um por um e o programa tenta deduzir série, temporada e episódio por metadados, título da página e padrões como `S01E05`, `1x05` ou `Temporada 1 Episódio 5`:',
    'No modo série, você cola os links um por um e o programa tenta deduzir série, temporada e episódio por metadados, título da página e padrões comuns como `S01E05`, `S1.E5`, `1x05`, `Season 1 Episode 5`, `Season 1 Ep 5`, `T1E5` e `Temporada 1 Episódio 5`:',
    'readme patterns'
)
readme = replace_once(
    readme,
    'Se algum dado não puder ser determinado com segurança, ele pergunta. Dentro da mesma sessão, série/temporada e o próximo número de episódio são reaproveitados quando fizer sentido.',
    'A prioridade é: metadados estruturados do site/downloader, informações explícitas da página, padrões reconhecidos no título e, só então, pergunta/sequência automática. Números ambíguos como `102` não são convertidos automaticamente em `S01E02`. Na Pluto, o formato exibido pela própria página (`S1 (Season 1)E2 (Episode 2)`) também é reconhecido.\n\nSe algum dado não puder ser determinado com segurança, ele pergunta. Dentro da mesma sessão, série/temporada e o próximo número de episódio são reaproveitados quando fizer sentido.',
    'readme priority'
)
readme_path.write_text(readme, encoding='utf-8')

workflow_path = root / '.github' / 'workflows' / 'release.yml'
workflow = workflow_path.read_text(encoding='utf-8')
workflow = replace_once(
    workflow,
    '      - "src/**"\n      - "installer/**"',
    '      - "src/**"\n      - "tests/**"\n      - "installer/**"',
    'release tests path'
)
workflow = replace_once(
    workflow,
    '          powershell.exe -NoProfile -ExecutionPolicy Bypass -File "src\\video-dl.ps1" --help *> $null\n          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }',
    '          powershell.exe -NoProfile -ExecutionPolicy Bypass -File "src\\video-dl.ps1" --help *> $null\n          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\n\n          powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tests\\episode-detection.ps1"\n          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }',
    'release episode tests'
)
workflow_path.write_text(workflow, encoding='utf-8')
