$ErrorActionPreference = "Stop"

function Replace-Required([string]$Path, [string]$Old, [string]$New, [string]$Label) {
    $content = Get-Content -LiteralPath $Path -Raw
    if (-not $content.Contains($Old)) { throw "Trecho não encontrado em ${Path}: $Label" }
    $content = $content.Replace($Old, $New)
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Insert-Before([string]$Path, [string]$Marker, [string]$Text, [string]$Label) {
    $content = Get-Content -LiteralPath $Path -Raw
    $idx = $content.IndexOf($Marker)
    if ($idx -lt 0) { throw "Marcador não encontrado em ${Path}: $Label" }
    $content = $content.Insert($idx, $Text)
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

$main = "src/video-dl.ps1"
$pluto = "src/pluto-dl.ps1"
$threads = "src/th-dl.ps1"
$readme = "README.md"

# Version + PowerShell automatic variable collision.
Replace-Required $main '$Version = "0.4.0"' '$Version = "0.4.1"' 'version'
$content = Get-Content -LiteralPath $main -Raw
$content = $content.Replace('$host', '$urlHost')
Set-Content -LiteralPath $main -Value $content -Encoding UTF8
Set-Content -LiteralPath "VERSION" -Value "0.4.1" -Encoding UTF8

# Config v5: quality suffix + duplicate policy.
Replace-Required $main @'
        version = 4
        defaultPath = $null
        autoUseDefault = $false
        videoContainer = "mp4"
        audioFormat = "mp3"
'@ @'
        version = 5
        defaultPath = $null
        autoUseDefault = $false
        videoContainer = "mp4"
        audioFormat = "mp3"
        qualityInFilename = $true
        duplicatePolicy = "skip"
'@ 'default config v5'

Replace-Required $main @'
        if ($null -eq $config.PSObject.Properties["audioFormat"]) {
            Add-Member -InputObject $config -NotePropertyName audioFormat -NotePropertyValue "mp3"
            $needsSave = $true
        }
        if ([string]$config.videoContainer -notin @("mp4", "mkv")) {
'@ @'
        if ($null -eq $config.PSObject.Properties["audioFormat"]) {
            Add-Member -InputObject $config -NotePropertyName audioFormat -NotePropertyValue "mp3"
            $needsSave = $true
        }
        if ($null -eq $config.PSObject.Properties["qualityInFilename"]) {
            Add-Member -InputObject $config -NotePropertyName qualityInFilename -NotePropertyValue $true
            $needsSave = $true
        }
        if ($null -eq $config.PSObject.Properties["duplicatePolicy"]) {
            Add-Member -InputObject $config -NotePropertyName duplicatePolicy -NotePropertyValue "skip"
            $needsSave = $true
        }
        if ([string]$config.videoContainer -notin @("mp4", "mkv")) {
'@ 'config migration fields'

Replace-Required $main @'
        if ([string]$config.audioFormat -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) {
            throw "audioFormat deve ser mp3, m4a, aac, opus, flac ou wav."
        }
        if ($null -eq $config.PSObject.Properties["version"]) {
            Add-Member -InputObject $config -NotePropertyName version -NotePropertyValue 4
            $needsSave = $true
        } elseif ([int]$config.version -lt 4) {
            $config.version = 4
            $needsSave = $true
        }
'@ @'
        if ([string]$config.audioFormat -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) {
            throw "audioFormat deve ser mp3, m4a, aac, opus, flac ou wav."
        }
        if ([string]$config.duplicatePolicy -notin @("skip", "ask", "overwrite", "rename")) {
            throw "duplicatePolicy deve ser skip, ask, overwrite ou rename."
        }
        if ($null -eq $config.PSObject.Properties["version"]) {
            Add-Member -InputObject $config -NotePropertyName version -NotePropertyValue 5
            $needsSave = $true
        } elseif ([int]$config.version -lt 5) {
            $config.version = 5
            $needsSave = $true
        }
'@ 'config v5 validation'

# Common collision/media helpers.
Insert-Before $main 'function Show-Settings {' @'
function Get-UniqueOutputPath([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue)) { return $PathValue }
    $dir = Split-Path -Parent $PathValue
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $i = 2
    while ($true) {
        $candidate = Join-Path $dir ("{0} ({1}){2}" -f $stem, $i, $ext)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $i++
    }
}

function Find-ExistingOutputVariant([string]$PathValue) {
    $dir = Split-Path -Parent $PathValue
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $pattern = '^' + [regex]::Escape($stem) + '(?: \[\d+p\])?' + [regex]::Escape($ext) + '$'
    return Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
}

function Resolve-OutputCollision([string]$PathValue) {
    $config = Get-Config
    $existing = Find-ExistingOutputVariant $PathValue
    if ($null -eq $existing) { return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }

    $policy = [string]$config.duplicatePolicy
    if ($policy -eq "ask") {
        Write-Warn "Arquivo já existe: $($existing.Name)"
        $choice = (Read-Host "[P]ular / [S]ubstituir / [C]riar cópia [P]").Trim().ToLowerInvariant()
        if ($choice -in @("s", "substituir")) { $policy = "overwrite" }
        elseif ($choice -in @("c", "copia", "cópia")) { $policy = "rename" }
        else { $policy = "skip" }
    }

    switch ($policy) {
        "overwrite" {
            Remove-Item -LiteralPath $existing.FullName -Force
            return [PSCustomObject]@{ Skip = $false; Path = $PathValue }
        }
        "rename" {
            return [PSCustomObject]@{ Skip = $false; Path = (Get-UniqueOutputPath $PathValue) }
        }
        default {
            Write-Info "Arquivo já existe; download pulado: $($existing.Name)"
            return [PSCustomObject]@{ Skip = $true; Path = $existing.FullName }
        }
    }
}

function Get-VideoHeight([string]$PathValue) {
    if (-not (Test-Command "ffprobe") -or -not (Test-Path -LiteralPath $PathValue -PathType Leaf)) { return $null }
    try {
        $raw = (& ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 -- $PathValue 2>$null | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace([string]$raw) -or [string]$raw -notmatch '^(\d+)x(\d+)$') { return $null }
        return [Math]::Min([int]$Matches[1], [int]$Matches[2])
    } catch { return $null }
}

function Add-QualitySuffix([string]$PathValue) {
    $config = Get-Config
    if (-not [bool]$config.qualityInFilename) { return $PathValue }
    $height = Get-VideoHeight $PathValue
    if ($null -eq $height) { return $PathValue }
    $dir = Split-Path -Parent $PathValue
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    if ($stem -match '\[\d+p\]$') { return $PathValue }
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $target = Join-Path $dir ("$stem [$height`p]$ext")
    if ($target -eq $PathValue) { return $PathValue }
    if (Test-Path -LiteralPath $target) {
        $collision = Resolve-OutputCollision $target
        if ($collision.Skip) { Remove-Item -LiteralPath $PathValue -Force -ErrorAction SilentlyContinue; return $collision.Path }
        $target = [string]$collision.Path
    }
    Move-Item -LiteralPath $PathValue -Destination $target -Force
    return $target
}

'@ 'insert collision helpers'

Replace-Required $main @'
    Write-Host ("  Áudio:      {0}" -f ([string]$config.audioFormat).ToUpperInvariant())
    Write-Host "  Qualidade:  1080p por padrão"
'@ @'
    Write-Host ("  Áudio:      {0}" -f ([string]$config.audioFormat).ToUpperInvariant())
    Write-Host "  Qualidade:  1080p por padrão"
    Write-Host ("  Nome:       qualidade {0}" -f $(if ([bool]$config.qualityInFilename) { "no arquivo" } else { "oculta" }))
    Write-Host ("  Duplicados: {0}" -f ([string]$config.duplicatePolicy))
'@ 'settings fields'

Insert-Before $main 'function Apply-PersistentMediaSettings' @'
function Set-QualityNameCommand([string]$Value) {
    $valueNormalized = $Value.Trim().ToLowerInvariant()
    if ($valueNormalized -notin @("on", "off", "true", "false", "1", "0")) { throw "Use on ou off." }
    $config = Get-Config
    $config.qualityInFilename = ($valueNormalized -in @("on", "true", "1"))
    Save-Config $config
    Write-Ok ("Qualidade no nome do arquivo: " + $(if ([bool]$config.qualityInFilename) { "ativada" } else { "desativada" }))
}

function Set-DuplicatePolicyCommand([string]$Policy) {
    $Policy = $Policy.Trim().ToLowerInvariant()
    if ($Policy -notin @("skip", "ask", "overwrite", "rename")) { throw "Use skip, ask, overwrite ou rename." }
    $config = Get-Config
    $config.duplicatePolicy = $Policy
    Save-Config $config
    Write-Ok "Política de duplicados: $Policy"
}

'@ 'settings commands'

# yt-dlp: add quality to video output names and honor overwrite policy.
Replace-Required $main @'
    if ([string]::IsNullOrWhiteSpace($OutputTemplate)) { $OutputTemplate = "%(title).180B [%(id)s].%(ext)s" }
    $argsList = @("--windows-filenames", "--continue", "--no-overwrites", "-P", $OutputDir, "-o", $OutputTemplate)
'@ @'
    if ([string]::IsNullOrWhiteSpace($OutputTemplate)) { $OutputTemplate = "%(title).180B [%(id)s].%(ext)s" }
    $config = Get-Config
    if (-not $AudioOnly -and [bool]$config.qualityInFilename -and $OutputTemplate -notmatch '%\(height\)s?p') {
        $OutputTemplate = $OutputTemplate -replace '\.%\(ext\)s$', ' [%(height)sp].%(ext)s'
    }
    $overwriteArg = if ([string]$config.duplicatePolicy -eq "overwrite") { "--force-overwrites" } else { "--no-overwrites" }
    $argsList = @("--windows-filenames", "--continue", $overwriteArg, "-P", $OutputDir, "-o", $OutputTemplate)
'@ 'yt-dlp quality naming'

# Generic Streamlink collision handling + ffprobe rename.
Replace-Required $main @'
        $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
        $target = Join-Path $OutputDir ($FileBase + "." + $AudioFormat)
        $code = Invoke-Streamlink @($Url, "best", "-o", $temp)
'@ @'
        $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
        $target = Join-Path $OutputDir ($FileBase + "." + $AudioFormat)
        $collision = Resolve-OutputCollision $target
        if ($collision.Skip) { return 0 }
        $target = [string]$collision.Path
        $code = Invoke-Streamlink @($Url, "best", "-o", $temp)
'@ 'streamlink audio collision'

Replace-Required $main @'
    $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
    $target = Join-Path $OutputDir ($FileBase + "." + $VideoContainer)
    $code = Invoke-Streamlink @($Url, "best", "-o", $temp)
'@ @'
    $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
    $target = Join-Path $OutputDir ($FileBase + "." + $VideoContainer)
    $collision = Resolve-OutputCollision $target
    if ($collision.Skip) { return 0 }
    $target = [string]$collision.Path
    $code = Invoke-Streamlink @($Url, "best", "-o", $temp)
'@ 'streamlink video collision'

Replace-Required $main @'
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    return $ffCode
}

function Invoke-Pluto'@ @'
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    if ($ffCode -eq 0 -and (Test-Path -LiteralPath $target -PathType Leaf)) { $target = Add-QualitySuffix $target }
    return $ffCode
}

function Invoke-Pluto'@ 'streamlink quality finalize'

# Preflight duplicates for yt-dlp/generic standalone downloads.
Replace-Required $main @'
    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
'@ @'
    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $expectedPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $collision = Resolve-OutputCollision $expectedPath
    if ($collision.Skip) { return 0 }
    if ([string]$collision.Path -ne $expectedPath) {
        $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$collision.Path)
        $naming.Template = "$($naming.FileBase).%(ext)s"
    }

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
'@ 'standalone duplicate preflight'

# Series duplicate preflight.
Replace-Required $main @'
    $template = "$prefix - %(title).165B.%(ext)s"
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"

    Write-Host ""
'@ @'
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

    Write-Host ""
'@ 'series duplicate preflight'

# Help and commands.
Replace-Required $main @'
CONFIGURAÇÃO
  config                          abre config.json no editor (VS Code/EDITOR/Notepad)
  config show                     mostra a configuração no terminal
  config path                     mostra o caminho do arquivo
  settings                        resumo das configurações atuais
'@ @'
CONFIGURAÇÃO
  config                          abre config.json no editor (VS Code/EDITOR/Notepad)
  config show                     mostra a configuração no terminal
  config path                     mostra o caminho do arquivo
  settings                        resumo das configurações atuais
  set-quality-name <on|off>       mostra/oculta [1080p] no nome dos vídeos
  set-duplicate-policy <modo>     skip, ask, overwrite ou rename
'@ 'help config'

Replace-Required $main @'
            "set-audio-format" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-audio-format <formato>" }; Set-AudioFormatCommand ([string]$tokens[1]); return }
            "remove-path"'@ @'
            "set-audio-format" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-audio-format <formato>" }; Set-AudioFormatCommand ([string]$tokens[1]); return }
            "set-quality-name" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-quality-name <on|off>" }; Set-QualityNameCommand ([string]$tokens[1]); return }
            "set-duplicate-policy" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-duplicate-policy <skip|ask|overwrite|rename>" }; Set-DuplicatePolicyCommand ([string]$tokens[1]); return }
            "remove-path"'@ 'command switch'

# Pluto helper: settings, collision policy, quality suffix.
Insert-Before $pluto 'function Convert-Audio' @'
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

function Get-UniqueOutputPath([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue)) { return $PathValue }
    $dir = Split-Path -Parent $PathValue
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $i = 2
    while ($true) {
        $candidate = Join-Path $dir ("{0} ({1}){2}" -f $stem, $i, $ext)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $i++
    }
}

function Find-ExistingVariant([string]$PathValue) {
    $dir = Split-Path -Parent $PathValue
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $pattern = '^' + [regex]::Escape($stem) + '(?: \[\d+p\])?' + [regex]::Escape($ext) + '$'
    return Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
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

'@ 'pluto helpers'

Replace-Required $pluto @'
        if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
            $answer = Read-Host "O arquivo já existe. Substituir? [s/N]"
            if ($answer.Trim().ToLowerInvariant() -notin @("s", "sim", "y", "yes")) { Write-Host "Download pulado."; return $outputPath }
            Remove-Item -LiteralPath $outputPath -Force
        }
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $tempPath)
'@ @'
        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { return $collision.Path }
        $outputPath = [string]$collision.Path
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $tempPath)
'@ 'pluto audio duplicate'

Replace-Required $pluto @'
    $outputPath = Join-Path $Folder ($FileBase + "." + $VideoContainer)
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        $answer = Read-Host "O arquivo já existe. Substituir? [s/N]"
        if ($answer.Trim().ToLowerInvariant() -notin @("s", "sim", "y", "yes")) { Write-Host "Download pulado."; return $outputPath }
        Remove-Item -LiteralPath $outputPath -Force
    }

    $tempPath = Join-Path $env:TEMP ("video-dl-pluto-" + [Guid]::NewGuid().ToString("N") + ".ts")
'@ @'
    $outputPath = Join-Path $Folder ($FileBase + "." + $VideoContainer)
    $collision = Resolve-Collision $outputPath
    if ($collision.Skip) { return $collision.Path }
    $outputPath = [string]$collision.Path

    $tempPath = Join-Path $env:TEMP ("video-dl-pluto-" + [Guid]::NewGuid().ToString("N") + ".ts")
'@ 'pluto video duplicate'

Replace-Required $pluto @'
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    if ($ffCode -ne 0) { throw "FFmpeg não conseguiu remuxar o vídeo." }
    return $outputPath
}
'@ @'
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    if ($ffCode -ne 0) { throw "FFmpeg não conseguiu remuxar o vídeo." }
    $outputPath = Add-QualitySuffix $outputPath
    return $outputPath
}
'@ 'pluto quality suffix'

# Threads helper: replace automatic-copy behavior with configured policy, then quality suffix.
Insert-Before $threads 'function Resolve-ThreadsUrl' @'
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

function Resolve-Collision([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue)) { return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }
    $settings = Get-LocalSettings
    $policy = [string]$settings.duplicatePolicy
    if ($Force) { $policy = "overwrite" }
    if ($policy -eq "ask") {
        Write-Host "Arquivo já existe: $([System.IO.Path]::GetFileName($PathValue))" -ForegroundColor Yellow
        $choice = (Read-Host "[P]ular / [S]ubstituir / [C]riar cópia [P]").Trim().ToLowerInvariant()
        if ($choice -in @("s", "substituir")) { $policy = "overwrite" }
        elseif ($choice -in @("c", "copia", "cópia")) { $policy = "rename" }
        else { $policy = "skip" }
    }
    if ($policy -eq "overwrite") { Remove-Item -LiteralPath $PathValue -Force; return [PSCustomObject]@{ Skip = $false; Path = $PathValue } }
    if ($policy -eq "rename") { return [PSCustomObject]@{ Skip = $false; Path = (Get-UniquePath $PathValue) } }
    Write-Host "Arquivo já existe; download pulado: $([System.IO.Path]::GetFileName($PathValue))" -ForegroundColor Cyan
    return [PSCustomObject]@{ Skip = $true; Path = $PathValue }
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
        $ext = [System.IO.Path]::GetExtension($PathValue)
        $target = Join-Path $dir ("$stem [$height`p]$ext")
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        Move-Item -LiteralPath $PathValue -Destination $target -Force
        return $target
    } catch { return $PathValue }
}

'@ 'threads helpers'

Replace-Required $threads '    if ((Test-Path -LiteralPath $outputPath) -and -not $Force) { $outputPath = Get-UniquePath $outputPath }' @'
    $collision = Resolve-Collision $outputPath
    if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
    $outputPath = [string]$collision.Path
'@ 'threads audio collision'

# Replace both video collision occurrences after the first replacement above.
$content = Get-Content -LiteralPath $threads -Raw
$old = '        if ((Test-Path -LiteralPath $outputPath) -and -not $Force) { $outputPath = Get-UniquePath $outputPath }'
$new = @'
        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
        $outputPath = [string]$collision.Path
'@
if (($content.Split($old).Count - 1) -lt 2) { throw "Colisões de vídeo do Threads não encontradas." }
$content = $content.Replace($old, $new)
Set-Content -LiteralPath $threads -Value $content -Encoding UTF8

Replace-Required $threads @'
}

Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green
'@ @'
}

if (-not $AudioOnly -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) { $outputPath = Add-QualitySuffix $outputPath }
Write-Host ""
Write-Host "Salvo: $outputPath" -ForegroundColor Green
'@ 'threads quality suffix'

# README docs.
Replace-Required $readme 'O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual.' 'O `video-dl` tenta usar a data original de publicação. Se o site não fornecer uma data confiável, usa a data atual. Por padrão, vídeos também recebem a resolução real no nome, por exemplo `[1080p]`.' 'readme naming'

Insert-Before $readme '## Sites' @'
## Qualidade no nome e arquivos repetidos

Por padrão, o vídeo final recebe a resolução real no nome (`[720p]`, `[1080p]`, `[1440p]`, `[2160p]` etc.). yt-dlp usa a altura do formato selecionado; Streamlink, Pluto e Threads confirmam o arquivo final com `ffprobe` quando disponível.

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

'@ 'readme duplicate section'

Write-Host "v0.4.1 patch applied"
