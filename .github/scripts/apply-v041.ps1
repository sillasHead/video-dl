$ErrorActionPreference = "Stop"

function Regex-ReplaceRequired([string]$Path, [string]$Pattern, [string]$Replacement, [string]$Label) {
    $content = Get-Content -LiteralPath $Path -Raw
    $regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $regex.IsMatch($content)) { throw "Trecho não encontrado em ${Path}: $Label" }
    $content = $regex.Replace($content, { param($m) $Replacement }, 1)
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Insert-BeforeOnce([string]$Path, [string]$Marker, [string]$Text, [string]$Sentinel, [string]$Label) {
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content.Contains($Sentinel)) { return }
    $idx = $content.IndexOf($Marker)
    if ($idx -lt 0) { throw "Marcador não encontrado em ${Path}: $Label" }
    $content = $content.Insert($idx, $Text)
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

$main = "src/video-dl.ps1"
$pluto = "src/pluto-dl.ps1"
$threads = "src/th-dl.ps1"
$readme = "README.md"

# Make variant-aware rename actually pick (2), (3)... even when the existing file already has [1080p].
Regex-ReplaceRequired $main 'function Get-UniqueOutputPath\(\[string\]\$PathValue\) \{.*?\n\}' @'
function Get-UniqueOutputPath([string]$PathValue) {
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
}
'@ 'main unique output'

# Finalize generic Streamlink video with ffprobe-derived [1080p].
Regex-ReplaceRequired $main '(function Invoke-GenericStreamlink\(.*?)(\n    Remove-Item \$temp -Force -ErrorAction SilentlyContinue\n    return \$ffCode\n\})' @'
$1
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    if ($ffCode -eq 0 -and (Test-Path -LiteralPath $target -PathType Leaf)) { $target = Add-QualitySuffix $target }
    return $ffCode
}
'@ 'streamlink finalize'

# Standalone preflight: duplicate policy before spending bandwidth.
Regex-ReplaceRequired $main '(\n    \$naming = Get-AvulsoNaming \$Url \$CookieBrowser \$CookieFile\n)(\n    if \(\(Test-YtDlpUnsupportedForSession \$Url\))' @'

    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $expectedPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $collision = Resolve-OutputCollision $expectedPath
    if ($collision.Skip) { return 0 }
    if ([string]$collision.Path -ne $expectedPath) {
        $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$collision.Path)
        $naming.Template = "$($naming.FileBase).%(ext)s"
    }
$2'@ 'standalone duplicate preflight'

# Series preflight.
Regex-ReplaceRequired $main '(\n    \$template = "\$prefix - %\(title\)\.165B\.%\(ext\)s"\n    \$fallbackBase = "\$prefix - \$\(Safe-Name \$info\.Title 160\)"\n)(\n    Write-Host ""\n)' @'

    $template = "$prefix - %(title).165B.%(ext)s"
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $expectedPath = Join-Path $seasonFolder ($fallbackBase + "." + $expectedExt)
    $collision = Resolve-OutputCollision $expectedPath
    if ($collision.Skip) { return 0 }
    if ([string]$collision.Path -ne $expectedPath) {
        $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$collision.Path)
        $template = "$fallbackBase.%(ext)s"
    }
$2'@ 'series duplicate preflight'

# Help + commands if not already present.
$content = Get-Content -LiteralPath $main -Raw
if (-not $content.Contains('set-quality-name <on|off>')) {
    $content = $content.Replace('  settings                        resumo das configurações atuais', "  settings                        resumo das configurações atuais`r`n  set-quality-name <on|off>       mostra/oculta [1080p] no nome dos vídeos`r`n  set-duplicate-policy <modo>     skip, ask, overwrite ou rename")
}
if (-not $content.Contains('"set-quality-name" {')) {
    $needle = '            "set-audio-format" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-audio-format <formato>" }; Set-AudioFormatCommand ([string]$tokens[1]); return }'
    $addition = $needle + "`r`n" + '            "set-quality-name" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-quality-name <on|off>" }; Set-QualityNameCommand ([string]$tokens[1]); return }' + "`r`n" + '            "set-duplicate-policy" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-duplicate-policy <skip|ask|overwrite|rename>" }; Set-DuplicatePolicyCommand ([string]$tokens[1]); return }'
    if (-not $content.Contains($needle)) { throw "set-audio-format command not found" }
    $content = $content.Replace($needle, $addition)
}
Set-Content -LiteralPath $main -Value $content -Encoding UTF8

# Pluto helper functions.
Insert-BeforeOnce $pluto 'function Convert-Audio' @'
function Get-LocalSettings {
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

'@ 'function Get-LocalSettings {' 'pluto helpers'

# Pluto collisions: audio, direct TS fallback, normal video. These are regex-based to tolerate line endings.
Regex-ReplaceRequired $pluto '        if \(Test-Path -LiteralPath \$outputPath -PathType Leaf\) \{.*?        \}\n        \$code = Invoke-StreamlinkLocal @\(\$Url, "best", "-o", \$tempPath\)' @'
        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { return $collision.Path }
        $outputPath = [string]$collision.Path
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $tempPath)'@ 'pluto audio collision'

Regex-ReplaceRequired $pluto '(        Write-Host "FFmpeg não disponível; salvando o stream original em \.ts\." -ForegroundColor Yellow\n        \$outputPath = Join-Path \$Folder \(\$FileBase \+ "\.ts"\)\n)(        \$code = Invoke-StreamlinkLocal)' @'
$1        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { return $collision.Path }
        $outputPath = [string]$collision.Path
$2'@ 'pluto ts collision'

Regex-ReplaceRequired $pluto '    \$outputPath = Join-Path \$Folder \(\$FileBase \+ "\." \+ \$VideoContainer\)\n    if \(Test-Path -LiteralPath \$outputPath -PathType Leaf\) \{.*?    \}\n\n    \$tempPath' @'
    $outputPath = Join-Path $Folder ($FileBase + "." + $VideoContainer)
    $collision = Resolve-Collision $outputPath
    if ($collision.Skip) { return $collision.Path }
    $outputPath = [string]$collision.Path

    $tempPath'@ 'pluto video collision'

Regex-ReplaceRequired $pluto '(    Remove-Item -LiteralPath \$tempPath -Force -ErrorAction SilentlyContinue\n    if \(\$ffCode -ne 0\) \{ throw "FFmpeg não conseguiu remuxar o vídeo\." \}\n)(    return \$outputPath)' @'
$1    $outputPath = Add-QualitySuffix $outputPath
$2'@ 'pluto quality suffix'

# Threads helper functions. Existing Get-UniquePath remains, but collisions now detect [1080p] variants.
Insert-BeforeOnce $threads 'function Resolve-ThreadsUrl' @'
function Get-LocalSettings {
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

'@ 'function Get-LocalSettings {' 'threads helpers'

# Replace the three old auto-rename collision lines (audio/mp4/mkv).
$content = Get-Content -LiteralPath $threads -Raw
$old = 'if ((Test-Path -LiteralPath $outputPath) -and -not $Force) { $outputPath = Get-UniquePath $outputPath }'
$replacement = @'
$collision = Resolve-Collision $outputPath
    if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
    $outputPath = [string]$collision.Path
'@
$count = ([regex]::Matches($content, [regex]::Escape($old))).Count
if ($count -ne 3) { throw "Esperava 3 colisões antigas no Threads, encontrei $count." }
$content = $content.Replace($old, $replacement)
Set-Content -LiteralPath $threads -Value $content -Encoding UTF8

Regex-ReplaceRequired $threads '(\n\}\n\nWrite-Host ""\nWrite-Host "Salvo: \$outputPath" -ForegroundColor Green)' @'

}

if (-not $AudioOnly -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) { $outputPath = Add-QualitySuffix $outputPath }
Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green'@ 'threads quality suffix'

# README.
$content = Get-Content -LiteralPath $readme -Raw
if (-not $content.Contains('resolução real no nome')) {
    $content = $content.Replace('O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual.', 'O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual. Por padrão, vídeos também recebem a resolução real no nome, por exemplo `[1080p]`.')
}
if (-not $content.Contains('## Qualidade no nome e arquivos repetidos')) {
    $section = @'
## Qualidade no nome e arquivos repetidos

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

`ask` oferece pular, substituir ou criar cópia. `rename` cria `(2)`, `(3)` etc. Para playlists nativas, o yt-dlp continua responsável por colisões item a item.

'@
    $marker = '## Sites'
    $idx = $content.IndexOf($marker)
    if ($idx -lt 0) { throw "README Sites marker not found" }
    $content = $content.Insert($idx, $section)
}
Set-Content -LiteralPath $readme -Value $content -Encoding UTF8

Write-Host "v0.4.1 continuation applied"
