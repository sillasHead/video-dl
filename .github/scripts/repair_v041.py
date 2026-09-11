from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"missing: {label}")
    return text.replace(old, new, 1)


def sub_once(text: str, pattern: str, repl: str, label: str) -> str:
    new, count = re.subn(pattern, repl, text, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError(f"regex missing: {label}")
    return new


main_path = Path("src/video-dl.ps1")
pluto_path = Path("src/pluto-dl.ps1")
threads_path = Path("src/th-dl.ps1")
readme_path = Path("README.md")

main = main_path.read_text(encoding="utf-8-sig")

# variant-aware rename
main = sub_once(
    main,
    r"function Get-UniqueOutputPath\(\[string\]\$PathValue\) \{.*?\n\}",
    r'''function Get-UniqueOutputPath([string]$PathValue) {
    $dir = Split-Path -Parent $PathValue
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    if ($null -eq (Find-ExistingOutputVariant $PathValue) -and -not (Test-Path -LiteralPath $PathValue)) { return $PathValue }
    $i = 2
    while ($true) {
        $candidate = Join-Path $dir ("{0} ({1}){2}" -f $stem, $i, $ext)
        if ($null -eq (Find-ExistingOutputVariant $candidate) -and -not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $i++
    }
}''',
    "main unique output",
)

# generic Streamlink final quality suffix
main = replace_once(
    main,
    '''    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    return $ffCode
}

function Invoke-Pluto''',
    '''    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    if ($ffCode -eq 0 -and (Test-Path -LiteralPath $target -PathType Leaf)) { $target = Add-QualitySuffix $target }
    return $ffCode
}

function Invoke-Pluto''',
    "streamlink finalize",
)

# standalone duplicate preflight
main = replace_once(
    main,
    '''    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {''',
    '''    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $expectedPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $collision = Resolve-OutputCollision $expectedPath
    if ($collision.Skip) { return 0 }
    if ([string]$collision.Path -ne $expectedPath) {
        $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$collision.Path)
        $naming.Template = "$($naming.FileBase).%(ext)s"
    }

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {''',
    "standalone preflight",
)

# series duplicate preflight
main = replace_once(
    main,
    '''    $template = "$prefix - %(title).165B.%(ext)s"
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"

    Write-Host ""''',
    '''    $template = "$prefix - %(title).165B.%(ext)s"
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $expectedPath = Join-Path $seasonFolder ($fallbackBase + "." + $expectedExt)
    $collision = Resolve-OutputCollision $expectedPath
    if ($collision.Skip) { return 0 }
    if ([string]$collision.Path -ne $expectedPath) {
        $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$collision.Path)
        $template = "$fallbackBase.%(ext)s"
    }

    Write-Host ""''',
    "series preflight",
)

# help / command dispatch
if "set-quality-name <on|off>" not in main:
    main = replace_once(
        main,
        "  settings                        resumo das configurações atuais",
        "  settings                        resumo das configurações atuais\n  set-quality-name <on|off>       mostra/oculta [1080p] no nome dos vídeos\n  set-duplicate-policy <modo>     skip, ask, overwrite ou rename",
        "help commands",
    )

if '"set-quality-name" {' not in main:
    needle = '            "set-audio-format" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-audio-format <formato>" }; Set-AudioFormatCommand ([string]$tokens[1]); return }'
    addition = needle + '\n' + '            "set-quality-name" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-quality-name <on|off>" }; Set-QualityNameCommand ([string]$tokens[1]); return }' + '\n' + '            "set-duplicate-policy" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-duplicate-policy <skip|ask|overwrite|rename>" }; Set-DuplicatePolicyCommand ([string]$tokens[1]); return }'
    main = replace_once(main, needle, addition, "command dispatch")

main_path.write_text(main, encoding="utf-8")

# Pluto helper
pluto = pluto_path.read_text(encoding="utf-8-sig")
helpers = r'''function Get-LocalSettings {
    $result = [PSCustomObject]@{ qualityInFilename = $true; duplicatePolicy = "skip" }
    $path = Join-Path (Join-Path $HOME ".video-dl") "config.json"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $cfg.PSObject.Properties["qualityInFilename"]) { $result.qualityInFilename = [bool]$cfg.qualityInFilename }
            if ([string]$cfg.duplicatePolicy -in @("skip", "ask", "overwrite", "rename")) { $result.duplicatePolicy = [string]$cfg.duplicatePolicy }
        } catch { }
    }
    return $result
}

function Find-ExistingVariant([string]$PathValue) {
    $dir = Split-Path -Parent $PathValue
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $pattern = '^' + [regex]::Escape($stem) + '(?: \[\d+p\])?' + [regex]::Escape($ext) + '$'
    return Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
}

function Get-UniqueOutputPath([string]$PathValue) {
    $dir = Split-Path -Parent $PathValue
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $i = 2
    while ($true) {
        $candidate = Join-Path $dir ("{0} ({1}){2}" -f $stem, $i, $ext)
        if ($null -eq (Find-ExistingVariant $candidate) -and -not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $i++
    }
}

function Resolve-Collision([string]$PathValue) {
    $settings = Get-LocalSettings
    $existing = Find-ExistingVariant $PathValue
    if ($null -eq $existing) { return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }
    $policy = [string]$settings.duplicatePolicy
    if ($policy -eq "ask") {
        Write-Host "Arquivo já existe: $($existing.Name)" -ForegroundColor Yellow
        $choice = (Read-Host "[P]ular / [S]ubstituir / [C]riar cópia [P]").Trim().ToLowerInvariant()
        if ($choice -in @("s", "substituir")) { $policy = "overwrite" }
        elseif ($choice -in @("c", "copia", "cópia")) { $policy = "rename" }
        else { $policy = "skip" }
    }
    if ($policy -eq "overwrite") { Remove-Item -LiteralPath $existing.FullName -Force; return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }
    if ($policy -eq "rename") { return [PSCustomObject]@{ Skip = $false; Path = (Get-UniqueOutputPath $PathValue) } }
    Write-Host "Arquivo já existe; download pulado: $($existing.Name)" -ForegroundColor Cyan
    return [PSCustomObject]@{ Skip = $true; Path = $existing.FullName }
}

function Add-QualitySuffix([string]$PathValue) {
    $settings = Get-LocalSettings
    if (-not [bool]$settings.qualityInFilename -or -not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { return $PathValue }
    try {
        $raw = (& ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 -- $PathValue 2>$null | Select-Object -First 1)
        if ([string]$raw -notmatch '^(\d+)x(\d+)$') { return $PathValue }
        $height = [Math]::Min([int]$Matches[1], [int]$Matches[2])
        $dir = Split-Path -Parent $PathValue
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
        if ($stem -match '\[\d+p\]$') { return $PathValue }
        $ext = [System.IO.Path]::GetExtension($PathValue)
        $target = Join-Path $dir ("$stem [$height`p]$ext")
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        Move-Item -LiteralPath $PathValue -Destination $target -Force
        return $target
    } catch { return $PathValue }
}

'''
if "function Get-LocalSettings" not in pluto:
    pluto = replace_once(pluto, "function Convert-Audio", helpers + "function Convert-Audio", "pluto helper insert")

pluto = sub_once(
    pluto,
    r'''        if \(Test-Path -LiteralPath \$outputPath -PathType Leaf\) \{.*?        \}\n        \$code = Invoke-StreamlinkLocal @\(\$Url, "best", "-o", \$tempPath\)''',
    '''        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { return $collision.Path }
        $outputPath = [string]$collision.Path
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $tempPath)''',
    "pluto audio collision",
)
pluto = replace_once(
    pluto,
    '''        $outputPath = Join-Path $Folder ($FileBase + ".ts")
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $outputPath)''',
    '''        $outputPath = Join-Path $Folder ($FileBase + ".ts")
        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { return $collision.Path }
        $outputPath = [string]$collision.Path
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $outputPath)''',
    "pluto ts collision",
)
pluto = sub_once(
    pluto,
    r'''    \$outputPath = Join-Path \$Folder \(\$FileBase \+ "\." \+ \$VideoContainer\)\n    if \(Test-Path -LiteralPath \$outputPath -PathType Leaf\) \{.*?    \}\n\n    \$tempPath''',
    '''    $outputPath = Join-Path $Folder ($FileBase + "." + $VideoContainer)
    $collision = Resolve-Collision $outputPath
    if ($collision.Skip) { return $collision.Path }
    $outputPath = [string]$collision.Path

    $tempPath''',
    "pluto video collision",
)
pluto = replace_once(
    pluto,
    '''    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    if ($ffCode -ne 0) { throw "FFmpeg não conseguiu remuxar o vídeo." }
    return $outputPath''',
    '''    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    if ($ffCode -ne 0) { throw "FFmpeg não conseguiu remuxar o vídeo." }
    $outputPath = Add-QualitySuffix $outputPath
    return $outputPath''',
    "pluto quality suffix",
)
pluto_path.write_text(pluto, encoding="utf-8")

# Threads helper
threads = threads_path.read_text(encoding="utf-8-sig")
threads_helpers = r'''function Get-LocalSettings {
    $result = [PSCustomObject]@{ qualityInFilename = $true; duplicatePolicy = "skip" }
    $path = Join-Path (Join-Path $HOME ".video-dl") "config.json"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $cfg.PSObject.Properties["qualityInFilename"]) { $result.qualityInFilename = [bool]$cfg.qualityInFilename }
            if ([string]$cfg.duplicatePolicy -in @("skip", "ask", "overwrite", "rename")) { $result.duplicatePolicy = [string]$cfg.duplicatePolicy }
        } catch { }
    }
    return $result
}

function Find-ExistingVariant([string]$PathValue) {
    $dir = Split-Path -Parent $PathValue
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $pattern = '^' + [regex]::Escape($stem) + '(?: \[\d+p\])?' + [regex]::Escape($ext) + '$'
    return Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
}

function Get-UniqueVariantPath([string]$PathValue) {
    $dir = Split-Path -Parent $PathValue
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $i = 2
    while ($true) {
        $candidate = Join-Path $dir ("{0} ({1}){2}" -f $stem, $i, $ext)
        if ($null -eq (Find-ExistingVariant $candidate) -and -not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $i++
    }
}

function Resolve-Collision([string]$PathValue) {
    $existing = Find-ExistingVariant $PathValue
    if ($null -eq $existing) { return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }
    $settings = Get-LocalSettings
    $policy = if ($Force) { "overwrite" } else { [string]$settings.duplicatePolicy }
    if ($policy -eq "ask") {
        Write-Host "Arquivo já existe: $($existing.Name)" -ForegroundColor Yellow
        $choice = (Read-Host "[P]ular / [S]ubstituir / [C]riar cópia [P]").Trim().ToLowerInvariant()
        if ($choice -in @("s", "substituir")) { $policy = "overwrite" }
        elseif ($choice -in @("c", "copia", "cópia")) { $policy = "rename" }
        else { $policy = "skip" }
    }
    if ($policy -eq "overwrite") { Remove-Item -LiteralPath $existing.FullName -Force; return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }
    if ($policy -eq "rename") { return [PSCustomObject]@{ Skip = $false; Path = (Get-UniqueVariantPath $PathValue) } }
    Write-Host "Arquivo já existe; download pulado: $($existing.Name)" -ForegroundColor Cyan
    return [PSCustomObject]@{ Skip = $true; Path = $existing.FullName }
}

function Add-QualitySuffix([string]$PathValue) {
    $settings = Get-LocalSettings
    if (-not [bool]$settings.qualityInFilename -or -not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { return $PathValue }
    try {
        $raw = (& ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 -- $PathValue 2>$null | Select-Object -First 1)
        if ([string]$raw -notmatch '^(\d+)x(\d+)$') { return $PathValue }
        $height = [Math]::Min([int]$Matches[1], [int]$Matches[2])
        $dir = Split-Path -Parent $PathValue
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
        if ($stem -match '\[\d+p\]$') { return $PathValue }
        $ext = [System.IO.Path]::GetExtension($PathValue)
        $target = Join-Path $dir ("$stem [$height`p]$ext")
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        Move-Item -LiteralPath $PathValue -Destination $target -Force
        return $target
    } catch { return $PathValue }
}

'''
if "function Get-LocalSettings" not in threads:
    threads = replace_once(threads, "function Resolve-ThreadsUrl", threads_helpers + "function Resolve-ThreadsUrl", "threads helper insert")

old_collision = 'if ((Test-Path -LiteralPath $outputPath) -and -not $Force) { $outputPath = Get-UniquePath $outputPath }'
if threads.count(old_collision) != 3:
    raise RuntimeError(f"expected 3 Threads collisions, got {threads.count(old_collision)}")
threads = threads.replace(
    old_collision,
    '''$collision = Resolve-Collision $outputPath
    if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
    $outputPath = [string]$collision.Path''',
)
threads = replace_once(
    threads,
    '''}

Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green''',
    '''}

if (-not $AudioOnly -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) { $outputPath = Add-QualitySuffix $outputPath }
Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green''',
    "threads quality suffix",
)
threads_path.write_text(threads, encoding="utf-8")

# README
readme = readme_path.read_text(encoding="utf-8-sig")
if "resolução real no nome" not in readme:
    readme = replace_once(
        readme,
        "O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual.",
        "O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual. Por padrão, vídeos também recebem a resolução real no nome, por exemplo `[1080p]`.",
        "readme naming",
    )
if "## Qualidade no nome e arquivos repetidos" not in readme:
    section = '''## Qualidade no nome e arquivos repetidos

Por padrão, o vídeo final recebe a resolução no nome (`[720p]`, `[1080p]`, `[1440p]`, `[2160p]` etc.). O yt-dlp usa a altura do formato selecionado; Streamlink, Pluto e Threads confirmam o arquivo final com `ffprobe` quando disponível.

```powershell
video-dl set-quality-name off
video-dl set-quality-name on
```

Arquivos repetidos usam `skip` por padrão. É possível mudar o comportamento:

```powershell
video-dl set-duplicate-policy skip
video-dl set-duplicate-policy ask
video-dl set-duplicate-policy overwrite
video-dl set-duplicate-policy rename
```

`ask` oferece pular, substituir ou criar cópia. `rename` cria `(2)`, `(3)` etc. Em playlists nativas, `overwrite` é respeitado; os outros modos deixam o yt-dlp pular colisões item a item.

'''
    readme = replace_once(readme, "## Sites", section + "## Sites", "readme section")
readme_path.write_text(readme, encoding="utf-8")

print("v0.4.1 repair applied")
