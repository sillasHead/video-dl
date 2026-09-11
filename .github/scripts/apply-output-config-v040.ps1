$ErrorActionPreference = "Stop"

function Replace-Required([string]$Path, [string]$Old, [string]$New, [string]$Label) {
    $content = Get-Content -LiteralPath $Path -Raw
    if (-not $content.Contains($Old)) { throw "Trecho não encontrado em $Path: $Label" }
    $content = $content.Replace($Old, $New)
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Replace-RegexRequired([string]$Path, [string]$Pattern, [string]$Replacement, [string]$Label) {
    $content = Get-Content -LiteralPath $Path -Raw
    $regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $regex.IsMatch($content)) { throw "Padrão não encontrado em $Path: $Label" }
    $content = $regex.Replace($content, $Replacement, 1)
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

$main = "src/video-dl.ps1"
$pluto = "src/pluto-dl.ps1"
$threads = "src/th-dl.ps1"

# Version + per-process yt-dlp capability cache.
Replace-Required $main '$Version = "0.3.3"' '$Version = "0.4.0"' 'version'
Replace-Required $main '$ThDlPath = Join-Path $ScriptRoot "th-dl.ps1"' @'
$ThDlPath = Join-Path $ScriptRoot "th-dl.ps1"
$script:YtDlpUnsupportedHosts = @{}
'@ 'unsupported cache'

# Capture stderr too, so unsupported URLs can be classified without another failed download.
Replace-Required $main '$text = (& yt-dlp @Arguments 2>$null | Out-String)' '$text = (& yt-dlp @Arguments 2>&1 | Out-String)' 'yt-dlp capture exe'
Replace-Required $main '$text = (& py -3 -m yt_dlp @Arguments 2>$null | Out-String)' '$text = (& py -3 -m yt_dlp @Arguments 2>&1 | Out-String)' 'yt-dlp capture py'
Replace-Required $main '$text = (& python -m yt_dlp @Arguments 2>$null | Out-String)' '$text = (& python -m yt_dlp @Arguments 2>&1 | Out-String)' 'yt-dlp capture python'

# Config v4: output container and persistent audio format.
Replace-RegexRequired $main 'function New-DefaultConfig \{.*?\n\}' @'
function New-DefaultConfig {
    return [PSCustomObject]@{
        version = 4
        defaultPath = $null
        autoUseDefault = $false
        videoContainer = "mp4"
        audioFormat = "mp3"
        paths = @([PSCustomObject]@{ name = "Videos"; path = $DefaultDownloadPath })
    }
}
'@ 'New-DefaultConfig'

$oldConfigMigration = @'
        if ($null -eq $config.PSObject.Properties["version"]) {
            Add-Member -InputObject $config -NotePropertyName version -NotePropertyValue 3
            $needsSave = $true
        } elseif ([int]$config.version -lt 3) {
            $config.version = 3
            $needsSave = $true
        }
        if ([bool]$config.autoUseDefault -and ([string]::IsNullOrWhiteSpace([string]$config.defaultPath) -or $null -eq (Get-PathByName $config ([string]$config.defaultPath)))) {
'@
$newConfigMigration = @'
        if ($null -eq $config.PSObject.Properties["videoContainer"]) {
            Add-Member -InputObject $config -NotePropertyName videoContainer -NotePropertyValue "mp4"
            $needsSave = $true
        }
        if ($null -eq $config.PSObject.Properties["audioFormat"]) {
            Add-Member -InputObject $config -NotePropertyName audioFormat -NotePropertyValue "mp3"
            $needsSave = $true
        }
        if ([string]$config.videoContainer -notin @("mp4", "mkv")) {
            throw "videoContainer deve ser 'mp4' ou 'mkv'."
        }
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
        if ([bool]$config.autoUseDefault -and ([string]::IsNullOrWhiteSpace([string]$config.defaultPath) -or $null -eq (Get-PathByName $config ([string]$config.defaultPath)))) {
'@
Replace-Required $main $oldConfigMigration $newConfigMigration 'config v4 migration'

$oldCatch = @'
    } catch {
        Write-Warn "Configuração inválida. Recriando..."
        $config = New-DefaultConfig
        Ensure-Directory $DefaultDownloadPath
        Save-Config $config
        return $config
    }
}
'@
$newCatch = @'
    } catch {
        throw "Configuração inválida em '$ConfigPath': $($_.Exception.Message) Use 'video-dl config' para corrigir o arquivo manualmente."
    }
}
'@
Replace-Required $main $oldCatch $newCatch 'preserve invalid manual config'

# Configuration editor + persistent media settings commands.
$marker = @'
function Get-DetectedCookieBrowsers {
'@
$insert = @'
function Ensure-ConfigFileForEditing {
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { return }
    $config = New-DefaultConfig
    Save-Config $config
}

function Open-ConfigEditor {
    Ensure-ConfigFileForEditing
    Write-Host "Configuração: $ConfigPath"

    $editor = $env:VIDEO_DL_EDITOR
    if ([string]::IsNullOrWhiteSpace($editor)) { $editor = $env:EDITOR }

    if (-not [string]::IsNullOrWhiteSpace($editor) -and (Test-Command $editor)) {
        $command = Get-Command $editor -ErrorAction Stop
        Start-Process -FilePath $command.Source -ArgumentList @($ConfigPath) | Out-Null
        return
    }
    if (Test-Command "code") {
        $command = Get-Command "code" -ErrorAction Stop
        Start-Process -FilePath $command.Source -ArgumentList @($ConfigPath) | Out-Null
        return
    }
    Start-Process -FilePath "notepad.exe" -ArgumentList @($ConfigPath) | Out-Null
}

function Show-Config {
    Get-Config | ConvertTo-Json -Depth 8 | Write-Host
}

function Show-Settings {
    $config = Get-Config
    $destination = if ([bool]$config.autoUseDefault) { "$($config.defaultPath) [automático]" } else { "perguntar quando necessário" }
    Write-Host "Configurações:"
    Write-Host ""
    Write-Host ("  Destino:    {0}" -f $destination)
    Write-Host ("  Vídeo:      {0}" -f ([string]$config.videoContainer).ToUpperInvariant())
    Write-Host ("  Áudio:      {0}" -f ([string]$config.audioFormat).ToUpperInvariant())
    Write-Host "  Qualidade:  1080p por padrão"
    Write-Host ""
    Write-Host "Arquivo: $ConfigPath"
}

function Set-ContainerCommand([string]$Container) {
    $Container = $Container.ToLowerInvariant()
    if ($Container -notin @("mp4", "mkv")) { throw "Container inválido. Use mp4 ou mkv." }
    $config = Get-Config
    $config.videoContainer = $Container
    Save-Config $config
    Write-Ok "Container padrão de vídeo: $Container"
}

function Set-AudioFormatCommand([string]$Format) {
    $Format = $Format.ToLowerInvariant()
    if ($Format -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) { throw "Formato de áudio inválido. Use mp3, m4a, aac, opus, flac ou wav." }
    $config = Get-Config
    $config.audioFormat = $Format
    Save-Config $config
    Write-Ok "Formato padrão de áudio: $Format"
}

function Apply-PersistentMediaSettings([object]$Parsed) {
    $defaultContainer = "mp4"
    $defaultAudio = "mp3"
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $config = Get-Config
        $defaultContainer = [string]$config.videoContainer
        $defaultAudio = [string]$config.audioFormat
    }
    if ([string]::IsNullOrWhiteSpace([string]$Parsed.VideoContainer)) { $Parsed.VideoContainer = $defaultContainer }
    if ([string]::IsNullOrWhiteSpace([string]$Parsed.AudioFormat)) { $Parsed.AudioFormat = $defaultAudio }
    return $Parsed
}

function Get-UrlHost([string]$Url) {
    try { return ([Uri]$Url).Host.ToLowerInvariant() } catch { return "" }
}

function Register-YtDlpProbeFailure([string]$Url, [object]$Probe) {
    if ($null -eq $Probe -or [string]::IsNullOrWhiteSpace([string]$Probe.Text)) { return }
    if ([string]$Probe.Text -match '(?i)Unsupported URL') {
        $host = Get-UrlHost $Url
        if (-not [string]::IsNullOrWhiteSpace($host)) { $script:YtDlpUnsupportedHosts[$host] = $true }
    }
}

function Test-YtDlpUnsupportedForSession([string]$Url) {
    $host = Get-UrlHost $Url
    return (-not [string]::IsNullOrWhiteSpace($host) -and $script:YtDlpUnsupportedHosts.ContainsKey($host))
}

function Get-DetectedCookieBrowsers {
'@
Replace-Required $main $marker $insert 'config/editor helpers'

# Mark unsupported URL during metadata probe.
Replace-Required $main @'
            $probe = Invoke-YtDlpCapture ($baseArgs + @(Get-CookieArgs $candidate $CookieFile) + @($Url))
            if ($probe.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($probe.Text)) {
                try { return ($probe.Text | ConvertFrom-Json) } catch { }
            }
'@ @'
            $probe = Invoke-YtDlpCapture ($baseArgs + @(Get-CookieArgs $candidate $CookieFile) + @($Url))
            if ($probe.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($probe.Text)) {
                try { return ($probe.Text | ConvertFrom-Json) } catch { }
            }
            Register-YtDlpProbeFailure $Url $probe
'@ 'auto cookie probe classification'
Replace-Required $main @'
    $probe = Invoke-YtDlpCapture ($baseArgs + @(Get-CookieArgs $CookieBrowser $CookieFile) + @($Url))
    if ($probe.Code -ne 0 -or [string]::IsNullOrWhiteSpace($probe.Text)) { return $null }
'@ @'
    $probe = Invoke-YtDlpCapture ($baseArgs + @(Get-CookieArgs $CookieBrowser $CookieFile) + @($Url))
    if ($probe.Code -ne 0 -or [string]::IsNullOrWhiteSpace($probe.Text)) {
        Register-YtDlpProbeFailure $Url $probe
        return $null
    }
'@ 'normal probe classification'

# yt-dlp gets an explicit output container.
Replace-Required $main @'
function Build-YtDlpArgs(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$OutputTemplate
) {
'@ @'
function Build-YtDlpArgs(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat, [string]$VideoContainer,
    [string]$CookieBrowser, [string]$CookieFile, [string]$OutputTemplate
) {
'@ 'Build-YtDlpArgs signature'

Replace-Required $main @'
    } else {
        if ($Compat) { $argsList += @("--preset-alias", "mp4") }
        if (-not $MaxQuality) {
'@ @'
    } else {
        if ($VideoContainer -eq "mp4") {
            if ($Compat) { $argsList += @("--preset-alias", "mp4") }
            else { $argsList += @("--merge-output-format", "mp4", "--remux-video", "mp4") }
        } elseif ($VideoContainer -eq "mkv") {
            $argsList += @("--merge-output-format", "mkv", "--remux-video", "mkv")
        }
        if (-not $MaxQuality) {
'@ 'yt-dlp container args'

Replace-Required $main @'
function Invoke-YtDlpDownload(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$OfferCookieRetry, [string]$OutputTemplate
) {
'@ @'
function Invoke-YtDlpDownload(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat, [string]$VideoContainer,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$OfferCookieRetry, [string]$OutputTemplate
) {
'@ 'Invoke-YtDlpDownload signature'

# Update all internal Build-YtDlpArgs calls.
$content = Get-Content -LiteralPath $main -Raw
$content = $content.Replace('Build-YtDlpArgs $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $candidate', 'Build-YtDlpArgs $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $VideoContainer $candidate')
$content = $content.Replace('Build-YtDlpArgs $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $CookieBrowser', 'Build-YtDlpArgs $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser')
$content = $content.Replace('Invoke-YtDlpDownload $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $browser', 'Invoke-YtDlpDownload $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $VideoContainer $browser')
Set-Content -LiteralPath $main -Value $content -Encoding UTF8

# Generic Streamlink: temporary TS -> remux to configured container without re-encoding.
Replace-RegexRequired $main 'function Invoke-GenericStreamlink\(.*?\n\}' @'
function Invoke-GenericStreamlink([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer, [string]$FileBase) {
    if (-not (Ensure-Dependency "streamlink" "fallback para streams")) { return 127 }
    if ([string]::IsNullOrWhiteSpace($FileBase)) { $FileBase = (Get-Date -Format "yyyy-MM-dd") + " - stream-" + (Get-Date -Format "HHmmss") }
    $FileBase = Safe-Name $FileBase

    if ($AudioOnly) {
        if (-not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
        $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
        $target = Join-Path $OutputDir ($FileBase + "." + $AudioFormat)
        $code = Invoke-Streamlink @($Url, "best", "-o", $temp)
        if ($code -ne 0) { Remove-Item $temp -Force -ErrorAction SilentlyContinue; return $code }
        & ffmpeg -y -i $temp -vn $target | Out-Host
        $ffCode = [int]$LASTEXITCODE
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
        return $ffCode
    }

    if (-not (Ensure-Dependency "ffmpeg" "saída de vídeo em $VideoContainer")) {
        Write-Warn "FFmpeg não disponível; salvando o stream original em .ts."
        $target = Join-Path $OutputDir ($FileBase + ".ts")
        return (Invoke-Streamlink @($Url, "best", "-o", $target))
    }

    $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
    $target = Join-Path $OutputDir ($FileBase + "." + $VideoContainer)
    $code = Invoke-Streamlink @($Url, "best", "-o", $temp)
    if ($code -ne 0) { Remove-Item $temp -Force -ErrorAction SilentlyContinue; return $code }

    $ffArgs = @("-y", "-i", $temp, "-map", "0", "-c", "copy")
    if ($VideoContainer -eq "mp4") { $ffArgs += @("-movflags", "+faststart") }
    $ffArgs += $target
    & ffmpeg @ffArgs | Out-Host
    $ffCode = [int]$LASTEXITCODE

    if ($ffCode -ne 0 -and $VideoContainer -eq "mp4") {
        Write-Warn "O stream não pôde ser remuxado para MP4. Tentando MKV sem re-encode..."
        $target = Join-Path $OutputDir ($FileBase + ".mkv")
        & ffmpeg -y -i $temp -map 0 -c copy $target | Out-Host
        $ffCode = [int]$LASTEXITCODE
    }
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    return $ffCode
}
'@ 'Invoke-GenericStreamlink'

Replace-Required $main 'function Invoke-Pluto([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [bool]$SeriesMode) {' 'function Invoke-Pluto([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer, [bool]$SeriesMode) {' 'Invoke-Pluto signature'
Replace-Required $main '& $PlutoDlPath -Url $Url -OutputRoot $OutputDir -AudioOnly:$AudioOnly -AudioFormat $AudioFormat -SeriesMode:$SeriesMode' '& $PlutoDlPath -Url $Url -OutputRoot $OutputDir -AudioOnly:$AudioOnly -AudioFormat $AudioFormat -VideoContainer $VideoContainer -SeriesMode:$SeriesMode' 'Invoke-Pluto call'
Replace-Required $main 'function Invoke-ThreadsFallback([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$FileBase) {' 'function Invoke-ThreadsFallback([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer, [string]$FileBase) {' 'Threads fallback signature'
Replace-Required $main '& $ThDlPath -Url $Url -OutputDir $OutputDir -AudioOnly:$AudioOnly -AudioFormat $AudioFormat -FileBase $FileBase' '& $ThDlPath -Url $Url -OutputDir $OutputDir -AudioOnly:$AudioOnly -AudioFormat $AudioFormat -VideoContainer $VideoContainer -FileBase $FileBase' 'Threads fallback call'

# Propagate VideoContainer through download/session functions and add unsupported-host short-circuit.
Replace-Required $main @'
function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$ResolvedOutput
) {
'@ @'
function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$ResolvedOutput
) {
'@ 'Invoke-OneDownload signature'
Replace-Required $main 'if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat $false) }' 'if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat $VideoContainer $false) }' 'Pluto standalone route'

$content = Get-Content -LiteralPath $main -Raw
$content = $content.Replace('Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $true $Quality $MaxQuality $Compat $CookieBrowser', 'Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $true $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser')
$content = $content.Replace('Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $CookieBrowser', 'Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser')
$content = $content.Replace('Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat $naming.FileBase', 'Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase')
$content = $content.Replace('Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $naming.FileBase', 'Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase')
Set-Content -LiteralPath $main -Value $content -Encoding UTF8

Replace-Required $main @'
    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile

    if ($kind -eq "threads") {
'@ @'
    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase)
    }

    if ($kind -eq "threads") {
'@ 'unsupported short-circuit standalone'

Replace-Required $main @'
function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile
) {
'@ @'
function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile
) {
'@ 'Invoke-SeriesItem signature'
Replace-Required $main 'return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $true)' 'return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $VideoContainer $true)' 'Pluto series route'
$content = Get-Content -LiteralPath $main -Raw
$content = $content.Replace('Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $CookieBrowser', 'Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser')
$content = $content.Replace('Invoke-ThreadsFallback $Url $seasonFolder $AudioOnly $AudioFormat $fallbackBase', 'Invoke-ThreadsFallback $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase')
$content = $content.Replace('Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $fallbackBase', 'Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase')
$content = $content.Replace('Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.NoFallback', 'Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback')
Set-Content -LiteralPath $main -Value $content -Encoding UTF8

Replace-Required $main @'
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State
'@ @'
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        $seriesFolder = Join-Path $BaseOutput (Safe-Name $info.Series 120)
        $seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f $info.Season)
        Ensure-Directory $seasonFolder
        $prefix = "S{0:D2}E{1:D2}" -f $info.Season, $info.Episode
        $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase)
    }
'@ 'unsupported short-circuit series'

# Updater no longer launches the unsigned setup EXE; use the same PowerShell installer as README.
Replace-RegexRequired $main 'function Update-VideoDl \{.*?\n\}' @'
function Update-VideoDl {
    Write-Info "Consultando a versão mais recente..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/sillasHead/video-dl/releases/latest" -Headers @{ "User-Agent" = "video-dl" }
        $latest = ([string]$release.tag_name).TrimStart('v')
        Write-Host "Instalada:   $Version"
        Write-Host "Disponível:  $latest"
        if ($latest -eq $Version) { Write-Ok "Você já está na versão mais recente."; return }
        $answer = Read-Host "Atualizar agora? [S/n]"
        if (-not (Test-Yes $answer $true)) { return }

        $setupUrl = "https://raw.githubusercontent.com/sillasHead/video-dl/main/setup.ps1"
        $command = "irm '$setupUrl' | iex"
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $command) -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "O instalador PowerShell terminou com código $($process.ExitCode)." }
        Write-Ok "Atualização concluída."
    } catch { Write-Fail "Falha ao atualizar: $($_.Exception.Message)" }
}
'@ 'PowerShell updater'

# Help + parsing + command dispatch.
Replace-Required $main '  --source                        não aplica o preset de compatibilidade' @'
  --source                        não aplica o preset de compatibilidade
  --container <mp4|mkv>           sobrescreve o container de vídeo neste download
  set-container <mp4|mkv>         muda o container padrão de vídeo
'@ 'help video container'
Replace-Required $main '  --audio-format <formato>        mp3, m4a, opus, flac, wav...' @'
  --audio-format <formato>        mp3, m4a, aac, opus, flac ou wav
  set-audio-format <formato>      muda o formato padrão de áudio
'@ 'help audio setting'
Replace-Required $main '  unset-default                  volta a perguntar quando houver mais de um destino' @'
  unset-default                   volta a perguntar quando houver mais de um destino

CONFIGURAÇÃO
  config                          abre config.json no editor (VS Code/EDITOR/Notepad)
  config show                     mostra a configuração no terminal
  config path                     mostra o caminho do arquivo
  settings                        resumo das configurações atuais
'@ 'help config section'

Replace-Required $main @'
        Url = $null; RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = "mp3";
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
        Compat = $true; CookieBrowser = $null; CookieFile = $null
'@ @'
        Url = $null; RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = $null; VideoContainer = $null;
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
        Compat = $true; CookieBrowser = $null; CookieFile = $null
'@ 'parse defaults'
Replace-Required $main '            "--audio-format" { if (++$i -ge $Tokens.Count) { throw "--audio-format precisa de um valor." }; $r.AudioFormat = ([string]$Tokens[$i]).ToLowerInvariant(); $r.AudioOnly = $true }' @'
            "--audio-format" { if (++$i -ge $Tokens.Count) { throw "--audio-format precisa de um valor." }; $r.AudioFormat = ([string]$Tokens[$i]).ToLowerInvariant(); $r.AudioOnly = $true }
            "--container" { if (++$i -ge $Tokens.Count) { throw "--container precisa de um valor." }; $r.VideoContainer = ([string]$Tokens[$i]).ToLowerInvariant() }
'@ 'parse container'
Replace-Required $main '    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }' @'
    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    if ($r.VideoContainer -and $r.VideoContainer -notin @("mp4", "mkv")) { throw "--container aceita: mp4 ou mkv." }
    if ($r.AudioFormat -and $r.AudioFormat -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) { throw "--audio-format aceita: mp3, m4a, aac, opus, flac ou wav." }
'@ 'parse validation'

Replace-Required $main @'
            "config" { Get-Config | ConvertTo-Json -Depth 8 | Write-Host; return }
            "--config" { Get-Config | ConvertTo-Json -Depth 8 | Write-Host; return }
'@ @'
            "config" {
                if ($tokens.Count -gt 1 -and ([string]$tokens[1]).ToLowerInvariant() -eq "show") { Show-Config; return }
                if ($tokens.Count -gt 1 -and ([string]$tokens[1]).ToLowerInvariant() -eq "path") { Write-Host $ConfigPath; return }
                Open-ConfigEditor; return
            }
            "--config" { Open-ConfigEditor; return }
            "settings" { Show-Settings; return }
            "--settings" { Show-Settings; return }
            "set-container" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-container <mp4|mkv>" }; Set-ContainerCommand ([string]$tokens[1]); return }
            "set-audio-format" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-audio-format <formato>" }; Set-AudioFormatCommand ([string]$tokens[1]); return }
'@ 'config/media commands'

Replace-Required $main '    $parsed = Parse-DownloadArguments $tokens' @'
    $parsed = Parse-DownloadArguments $tokens
    $parsed = Apply-PersistentMediaSettings $parsed
'@ 'apply persistent settings'

# Add VideoContainer argument to top-level Invoke-OneDownload calls.
$content = Get-Content -LiteralPath $main -Raw
$content = $content.Replace('Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.NoFallback', 'Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback')
$content = $content.Replace('Invoke-OneDownload $parsed.Url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.NoFallback', 'Invoke-OneDownload $parsed.Url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback')
Set-Content -LiteralPath $main -Value $content -Encoding UTF8

# Pluto helper: configurable MP4/MKV remux, TS only as emergency fallback if FFmpeg is unavailable.
Replace-Required $pluto @'
    [string]$AudioFormat = "mp3",

    [switch]$SeriesMode
'@ @'
    [string]$AudioFormat = "mp3",

    [ValidateSet("mp4", "mkv")]
    [string]$VideoContainer = "mp4",

    [switch]$SeriesMode
'@ 'Pluto VideoContainer param'

Replace-RegexRequired $pluto 'function Download-Pluto\(.*?\n\}' @'
function Download-Pluto([string]$Folder, [string]$FileBase) {
    Ensure-Directory $Folder
    if ($AudioOnly) {
        $outputPath = Join-Path $Folder ($FileBase + "." + $AudioFormat)
        $tempPath = Join-Path $env:TEMP ("video-dl-pluto-" + [Guid]::NewGuid().ToString("N") + ".ts")
        if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
            $answer = Read-Host "O arquivo já existe. Substituir? [s/N]"
            if ($answer.Trim().ToLowerInvariant() -notin @("s", "sim", "y", "yes")) { Write-Host "Download pulado."; return $outputPath }
            Remove-Item -LiteralPath $outputPath -Force
        }
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $tempPath)
        if ($code -ne 0) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; throw "O Streamlink terminou com código $code." }
        Convert-Audio $tempPath $outputPath $AudioFormat
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        return $outputPath
    }

    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        Write-Host "FFmpeg não disponível; salvando o stream original em .ts." -ForegroundColor Yellow
        $outputPath = Join-Path $Folder ($FileBase + ".ts")
        $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $outputPath)
        if ($code -ne 0) { throw "O Streamlink terminou com código $code." }
        return $outputPath
    }

    $outputPath = Join-Path $Folder ($FileBase + "." + $VideoContainer)
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        $answer = Read-Host "O arquivo já existe. Substituir? [s/N]"
        if ($answer.Trim().ToLowerInvariant() -notin @("s", "sim", "y", "yes")) { Write-Host "Download pulado."; return $outputPath }
        Remove-Item -LiteralPath $outputPath -Force
    }

    $tempPath = Join-Path $env:TEMP ("video-dl-pluto-" + [Guid]::NewGuid().ToString("N") + ".ts")
    $code = Invoke-StreamlinkLocal @($Url, "best", "-o", $tempPath)
    if ($code -ne 0) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; throw "O Streamlink terminou com código $code." }

    $ffArgs = @("-y", "-i", $tempPath, "-map", "0", "-c", "copy")
    if ($VideoContainer -eq "mp4") { $ffArgs += @("-movflags", "+faststart") }
    $ffArgs += $outputPath
    & ffmpeg @ffArgs | Out-Host
    $ffCode = [int]$LASTEXITCODE

    if ($ffCode -ne 0 -and $VideoContainer -eq "mp4") {
        Write-Host "MP4 incompatível com este stream; tentando MKV sem re-encode..." -ForegroundColor Yellow
        $outputPath = Join-Path $Folder ($FileBase + ".mkv")
        & ffmpeg -y -i $tempPath -map 0 -c copy $outputPath | Out-Host
        $ffCode = [int]$LASTEXITCODE
    }
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    if ($ffCode -ne 0) { throw "FFmpeg não conseguiu remuxar o vídeo." }
    return $outputPath
}
'@ 'Download-Pluto remux'

# Threads fallback supports MKV too.
Replace-Required $threads @'
    [string]$AudioFormat = "mp3",

    [string]$FileBase,
'@ @'
    [string]$AudioFormat = "mp3",

    [ValidateSet("mp4", "mkv")]
    [string]$VideoContainer = "mp4",

    [string]$FileBase,
'@ 'Threads VideoContainer param'
Replace-Required $threads @'
} else {
    $outputPath = Join-Path $OutputDir ($FileBase + ".mp4")
    if ((Test-Path -LiteralPath $outputPath) -and -not $Force) { $outputPath = Get-UniquePath $outputPath }
    Write-Host "Baixando: $outputPath"
    Download-File $videoUrl $outputPath
}
'@ @'
} else {
    if ($VideoContainer -eq "mp4") {
        $outputPath = Join-Path $OutputDir ($FileBase + ".mp4")
        if ((Test-Path -LiteralPath $outputPath) -and -not $Force) { $outputPath = Get-UniquePath $outputPath }
        Write-Host "Baixando: $outputPath"
        Download-File $videoUrl $outputPath
    } else {
        if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "FFmpeg é necessário para saída MKV." }
        $tempVideo = Join-Path $env:TEMP ("video-dl-threads-" + [Guid]::NewGuid().ToString("N") + ".mp4")
        $outputPath = Join-Path $OutputDir ($FileBase + ".mkv")
        if ((Test-Path -LiteralPath $outputPath) -and -not $Force) { $outputPath = Get-UniquePath $outputPath }
        Write-Host "Baixando vídeo temporário..."
        Download-File $videoUrl $tempVideo
        Write-Host "Remuxando para MKV: $outputPath"
        & ffmpeg -y -i $tempVideo -map 0 -c copy $outputPath | Out-Host
        $ffCode = [int]$LASTEXITCODE
        Remove-Item -LiteralPath $tempVideo -Force -ErrorAction SilentlyContinue
        if ($ffCode -ne 0) { throw "FFmpeg não conseguiu remuxar o vídeo para MKV." }
    }
}
'@ 'Threads MKV output'

# Version file.
Set-Content -LiteralPath "VERSION" -Value "0.4.0" -Encoding ascii

# README additions.
$readme = Get-Content -LiteralPath "README.md" -Raw
$needle = @'
video-dl update
```
'@
$replacement = @'
video-dl update
video-dl settings
video-dl config
```
'@
if (-not $readme.Contains($needle)) { throw "README examples marker not found" }
$readme = $readme.Replace($needle, $replacement)

$needle = @'
O padrão é MP3.

## Sites
'@
$replacement = @'
O padrão é MP3. Você pode mudar apenas um download ou salvar outro padrão:

```powershell
video-dl "URL" --audio --audio-format opus
video-dl set-audio-format opus
```

Formatos aceitos: `mp3`, `m4a`, `aac`, `opus`, `flac` e `wav`.

## Container de vídeo

O padrão é **MP4**. Streams baixados via Streamlink/Pluto são recebidos como TS temporário e remuxados com FFmpeg, sem re-encode e sem perda de qualidade.

```powershell
video-dl "URL" --container mkv
video-dl set-container mkv
video-dl set-container mp4
```

Se um stream não puder ser remuxado para MP4 sem recodificar, o `video-dl` tenta MKV. Se FFmpeg não estiver disponível e a instalação for recusada, streams podem permanecer em `.ts` como fallback.

## Configuração

```powershell
video-dl settings
video-dl config
video-dl config show
video-dl config path
```

`video-dl config` abre `%USERPROFILE%\\.video-dl\\config.json`. O programa usa `VIDEO_DL_EDITOR` ou `EDITOR` quando definidos, depois tenta VS Code e por fim o Bloco de Notas. É possível editar manualmente destinos, `videoContainer` e `audioFormat`. Valores inválidos não sobrescrevem silenciosamente o arquivo; o programa informa o erro para que ele seja corrigido.

## Sites
'@
if (-not $readme.Contains($needle)) { throw "README audio marker not found" }
$readme = $readme.Replace($needle, $replacement)
Set-Content -LiteralPath "README.md" -Value $readme -Encoding UTF8
