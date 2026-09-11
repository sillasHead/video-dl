# video-dl.ps1
# Universal video/audio downloader dispatcher for Windows PowerShell / PowerShell 7.

$ErrorActionPreference = "Stop"
$Version = "0.2.0"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $HOME ".video-dl"
$ConfigPath = Join-Path $ConfigDir "config.json"
$PrivateBin = Join-Path $ConfigDir "bin"
$DefaultDownloadPath = Join-Path (Join-Path $HOME "Videos") "video-dl"
$PlutoDlPath = Join-Path $ScriptRoot "pluto-dl.ps1"
$ThDlPath = Join-Path $ScriptRoot "th-dl.ps1"

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host $Message -ForegroundColor Red }

function Test-Yes([string]$Value, [bool]$DefaultYes = $false) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $DefaultYes }
    return $Value.Trim().ToLowerInvariant() -in @("s", "sim", "y", "yes")
}

function Ensure-Directory([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue -PathType Container)) {
        New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
    }
}

function Normalize-Path([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue.Trim().Trim('"'))
    try { return [System.IO.Path]::GetFullPath($expanded) } catch { return $expanded }
}

Ensure-Directory $ConfigDir
Ensure-Directory $PrivateBin
if (($env:PATH -split ';') -notcontains $PrivateBin) { $env:PATH = "$PrivateBin;$env:PATH" }

function Test-Command([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-PythonCommand {
    if (Test-Command "python") { return "python" }
    if (Test-Command "py") { return "py" }
    return $null
}

function Test-PythonModule([string]$Module) {
    $python = Get-PythonCommand
    if ($null -eq $python) { return $false }
    try {
        if ($python -eq "py") { & py -3 -c "import $Module" *> $null }
        else { & python -c "import $Module" *> $null }
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Invoke-Python([object[]]$Arguments) {
    $python = Get-PythonCommand
    if ($null -eq $python) { return 127 }
    if ($python -eq "py") { & py -3 @Arguments | Out-Host }
    else { & python @Arguments | Out-Host }
    return [int]$LASTEXITCODE
}

function Test-Dependency([string]$Name) {
    switch ($Name.ToLowerInvariant()) {
        "yt-dlp" { return ((Test-Command "yt-dlp") -or (Test-PythonModule "yt_dlp")) }
        "streamlink" { return ((Test-Command "streamlink") -or (Test-PythonModule "streamlink")) }
        "ffmpeg" { return (Test-Command "ffmpeg") }
        "th" { return (Test-Command "th") }
        default { return (Test-Command $Name) }
    }
}

function Invoke-YtDlp([object[]]$Arguments) {
    if (Test-Command "yt-dlp") {
        & yt-dlp @Arguments | Out-Host
        return [int]$LASTEXITCODE
    }
    if (Test-PythonModule "yt_dlp") {
        return (Invoke-Python (@("-m", "yt_dlp") + @($Arguments)))
    }
    return 127
}

function Invoke-Streamlink([object[]]$Arguments) {
    if (Test-Command "streamlink") {
        & streamlink @Arguments | Out-Host
        return [int]$LASTEXITCODE
    }
    if (Test-PythonModule "streamlink") {
        return (Invoke-Python (@("-m", "streamlink") + @($Arguments)))
    }
    return 127
}

function Install-YtDlp {
    Write-Info "Baixando yt-dlp oficial..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest" -Headers @{ "User-Agent" = "video-dl" }
        $asset = @($release.assets | Where-Object { $_.name -eq "yt-dlp.exe" }) | Select-Object -First 1
        if ($null -eq $asset) { throw "yt-dlp.exe não encontrado na release." }
        $target = Join-Path $PrivateBin "yt-dlp.exe"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $target -UseBasicParsing
        Write-Ok "yt-dlp instalado."
        return $true
    } catch {
        Write-Fail "Falha ao instalar yt-dlp: $($_.Exception.Message)"
        return $false
    }
}

function Install-Ffmpeg {
    Write-Warn "O pacote do FFmpeg é grande (aproximadamente 200 MB)."
    try {
        $url = "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
        $temp = Join-Path $env:TEMP ("video-dl-ffmpeg-" + [Guid]::NewGuid().ToString("N"))
        $zip = "$temp.zip"
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Ensure-Directory $temp
        Expand-Archive -LiteralPath $zip -DestinationPath $temp -Force
        foreach ($name in @("ffmpeg.exe", "ffprobe.exe", "ffplay.exe")) {
            $file = Get-ChildItem -LiteralPath $temp -Filter $name -Recurse -File | Select-Object -First 1
            if ($null -ne $file) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $PrivateBin $name) -Force }
        }
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Command "ffmpeg")) { throw "ffmpeg.exe não foi encontrado após a extração." }
        Write-Ok "FFmpeg instalado."
        return $true
    } catch {
        Write-Fail "Falha ao instalar FFmpeg: $($_.Exception.Message)"
        return $false
    }
}

function Install-Streamlink {
    $python = Get-PythonCommand
    if ($null -ne $python) {
        Write-Info "Instalando Streamlink via Python..."
        $code = Invoke-Python @("-m", "pip", "install", "-U", "https://github.com/streamlink/streamlink/archive/refs/heads/master.zip")
        if ($code -eq 0 -and (Test-Dependency "streamlink")) {
            Write-Ok "Streamlink instalado."
            return $true
        }
    }
    if (Test-Command "winget") {
        Write-Info "Tentando instalar Streamlink pelo winget..."
        & winget install streamlink --accept-package-agreements --accept-source-agreements | Out-Host
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Streamlink instalado. Talvez seja necessário abrir outro terminal."
            return $true
        }
    }
    Write-Fail "Não foi possível instalar Streamlink automaticamente."
    return $false
}

function Install-Th {
    Write-Info "Baixando Threads CLI (th)..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/tamnd/threads-cli/releases/latest" -Headers @{ "User-Agent" = "video-dl" }
        $asset = @($release.assets | Where-Object { $_.name -match 'windows_amd64\.zip$' }) | Select-Object -First 1
        if ($null -eq $asset) { throw "Pacote Windows x64 não encontrado." }
        $temp = Join-Path $env:TEMP ("video-dl-th-" + [Guid]::NewGuid().ToString("N"))
        $zip = "$temp.zip"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        Ensure-Directory $temp
        Expand-Archive -LiteralPath $zip -DestinationPath $temp -Force
        $exe = Get-ChildItem -LiteralPath $temp -Filter "th.exe" -Recurse -File | Select-Object -First 1
        if ($null -eq $exe) { throw "th.exe não encontrado." }
        Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $PrivateBin "th.exe") -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Threads CLI instalado."
        return $true
    } catch {
        Write-Fail "Falha ao instalar Threads CLI: $($_.Exception.Message)"
        return $false
    }
}

function Install-Dependency([string]$Name) {
    switch ($Name.ToLowerInvariant()) {
        "yt-dlp" { return (Install-YtDlp) }
        "ffmpeg" { return (Install-Ffmpeg) }
        "streamlink" { return (Install-Streamlink) }
        "th" { return (Install-Th) }
        default { return $false }
    }
}

function Ensure-Dependency([string]$Name, [string]$Reason) {
    if (Test-Dependency $Name) { return $true }
    Write-Warn "$Name não está instalado."
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { Write-Host "Necessário para: $Reason" }
    $answer = Read-Host "Instalar agora? [S/n]"
    if (-not (Test-Yes $answer $true)) { return $false }
    return (Install-Dependency $Name)
}

function Install-AllMissingDependencies {
    foreach ($dep in @("yt-dlp", "ffmpeg", "streamlink", "th")) {
        if (-not (Test-Dependency $dep)) { [void](Install-Dependency $dep) }
    }
}

function New-DefaultConfig {
    return [PSCustomObject]@{
        version = 2
        defaultPath = "Videos"
        paths = @([PSCustomObject]@{ name = "Videos"; path = $DefaultDownloadPath })
    }
}

function Save-Config([object]$Config) {
    Ensure-Directory $ConfigDir
    $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-Host ""
        Write-Info "Primeira execução do video-dl."
        $answer = Read-Host "Pasta padrão [$DefaultDownloadPath]"
        $path = if ([string]::IsNullOrWhiteSpace($answer)) { $DefaultDownloadPath } else { Normalize-Path $answer }
        Ensure-Directory $path
        $config = New-DefaultConfig
        $config.paths[0].path = $path
        Save-Config $config
        return $config
    }
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $config.paths -or @($config.paths).Count -eq 0) { throw "Configuração sem destinos." }
        return $config
    } catch {
        Write-Warn "Configuração inválida. Recriando..."
        $config = New-DefaultConfig
        Ensure-Directory $DefaultDownloadPath
        Save-Config $config
        return $config
    }
}

function Get-PathByName([object]$Config, [string]$Name) {
    return @($Config.paths | Where-Object { $_.name -ieq $Name }) | Select-Object -First 1
}

function Resolve-OutputPath([string]$RequestedPath, [bool]$Here) {
    if ($Here) { return (Get-Location).Path }
    $config = Get-Config
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $named = Get-PathByName $config $RequestedPath
        if ($null -ne $named) { Ensure-Directory ([string]$named.path); return [string]$named.path }
        $direct = Normalize-Path $RequestedPath
        Ensure-Directory $direct
        return $direct
    }
    $paths = @($config.paths)
    if ($paths.Count -eq 1) { Ensure-Directory ([string]$paths[0].path); return [string]$paths[0].path }

    Write-Host ""
    Write-Host "Onde deseja salvar?"
    $defaultIndex = 0
    for ($i = 0; $i -lt $paths.Count; $i++) {
        $marker = " "
        if ([string]$paths[$i].name -ieq [string]$config.defaultPath) { $marker = "*"; $defaultIndex = $i }
        Write-Host ("  [{0}] {1} {2,-14} {3}" -f ($i + 1), $marker, $paths[$i].name, $paths[$i].path)
    }
    $choice = Read-Host ("Escolha [Enter = {0}]" -f ($defaultIndex + 1))
    if ([string]::IsNullOrWhiteSpace($choice)) { $idx = $defaultIndex }
    elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $paths.Count) { $idx = [int]$choice - 1 }
    else { throw "Destino inválido." }
    Ensure-Directory ([string]$paths[$idx].path)
    return [string]$paths[$idx].path
}

function Show-Paths {
    $config = Get-Config
    Write-Host "Destinos salvos:"
    foreach ($item in @($config.paths)) {
        $marker = if ([string]$item.name -ieq [string]$config.defaultPath) { "*" } else { " " }
        Write-Host ("  {0} {1,-16} {2}" -f $marker, $item.name, $item.path)
    }
}

function Add-PathCommand([string]$PathValue, [string]$Name, [bool]$MakeDefault) {
    $config = Get-Config
    $normalized = Normalize-Path $PathValue
    Ensure-Directory $normalized
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = Split-Path -Leaf $normalized
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "Destino" }
    }
    if ($null -ne (Get-PathByName $config $Name)) { throw "Já existe um destino chamado '$Name'." }
    $config.paths = @($config.paths) + @([PSCustomObject]@{ name = $Name; path = $normalized })
    if ($MakeDefault) { $config.defaultPath = $Name }
    Save-Config $config
    Write-Ok "Destino adicionado: $Name -> $normalized"
}

function Remove-PathCommand([string]$Name) {
    $config = Get-Config
    $remaining = @($config.paths | Where-Object { $_.name -ine $Name })
    if ($remaining.Count -eq @($config.paths).Count) { throw "Destino '$Name' não encontrado." }
    if ($remaining.Count -eq 0) { throw "Não é possível remover o único destino." }
    $config.paths = $remaining
    if ([string]$config.defaultPath -ieq $Name) { $config.defaultPath = [string]$remaining[0].name }
    Save-Config $config
    Write-Ok "Destino removido: $Name"
}

function Set-DefaultPathCommand([string]$Name) {
    $config = Get-Config
    if ($null -eq (Get-PathByName $config $Name)) { throw "Destino '$Name' não encontrado." }
    $config.defaultPath = $Name
    Save-Config $config
    Write-Ok "Destino padrão: $Name"
}

function Get-DetectedCookieBrowsers {
    $result = @()
    $checks = @(
        @{ name = "firefox"; path = (Join-Path $env:APPDATA "Mozilla\Firefox\Profiles") },
        @{ name = "chrome"; path = (Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data") },
        @{ name = "edge"; path = (Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data") },
        @{ name = "brave"; path = (Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\User Data") }
    )
    foreach ($item in $checks) { if (Test-Path -LiteralPath $item.path) { $result += $item.name } }
    return $result
}

function Select-CookieBrowser {
    $detected = @(Get-DetectedCookieBrowsers)
    $options = @("firefox", "chrome", "edge", "brave")
    Write-Host "Navegador para cookies:"
    for ($i = 0; $i -lt $options.Count; $i++) {
        $note = if ($detected -contains $options[$i]) { " (detectado)" } else { "" }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $options[$i], $note)
    }
    Write-Host "  [5] automático"
    $choice = Read-Host "Escolha [5]"
    if ([string]::IsNullOrWhiteSpace($choice)) { return "auto" }
    if ($choice -match '^[1-4]$') { return $options[[int]$choice - 1] }
    return "auto"
}

function Get-CookieCandidates([string]$Browser) {
    if ([string]::IsNullOrWhiteSpace($Browser)) { return @() }
    if ($Browser -ne "auto") { return @($Browser) }
    $detected = @(Get-DetectedCookieBrowsers)
    if ($detected.Count -gt 0) { return $detected }
    return @("firefox", "chrome", "edge", "brave")
}

function Build-YtDlpArgs(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile
) {
    $argsList = @(
        "--windows-filenames", "--continue", "--no-overwrites",
        "-P", $OutputDir,
        "-o", "%(title).180B [%(id)s].%(ext)s"
    )
    if ($Playlist) { $argsList += "--yes-playlist" } else { $argsList += "--no-playlist" }

    if ($AudioOnly) {
        $argsList += @("-x", "--audio-format", $AudioFormat, "--audio-quality", "0")
    } else {
        if ($Compat) { $argsList += @("--preset-alias", "mp4") }
        if (-not $MaxQuality) {
            if (Test-Dependency "ffmpeg") { $argsList += @("-f", "bv*[height<=$Quality]+ba/b[height<=$Quality]") }
            else { $argsList += @("-f", "b[height<=$Quality]/b") }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($CookieFile)) { $argsList += @("--cookies", $CookieFile) }
    elseif (-not [string]::IsNullOrWhiteSpace($CookieBrowser) -and $CookieBrowser -ne "auto") { $argsList += @("--cookies-from-browser", $CookieBrowser) }
    $argsList += $Url
    return $argsList
}

function Invoke-YtDlpDownload(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$OfferCookieRetry
) {
    if (-not (Ensure-Dependency "yt-dlp" "downloads de vídeo e áudio")) { return 127 }
    if ($AudioOnly -and -not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }

    if (-not $AudioOnly -and -not $MaxQuality -and -not (Test-Dependency "ffmpeg")) {
        Write-Warn "FFmpeg não está instalado; sem ele, a qualidade disponível pode ser menor."
        $answer = Read-Host "Instalar FFmpeg para permitir vídeo+áudio em alta qualidade? [S/n]"
        if (Test-Yes $answer $true) { [void](Install-Ffmpeg) }
    }

    $candidates = Get-CookieCandidates $CookieBrowser
    if ($CookieBrowser -eq "auto") {
        foreach ($candidate in $candidates) {
            Write-Info "Tentando com cookies do $candidate..."
            $code = Invoke-YtDlp (Build-YtDlpArgs $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $candidate $CookieFile)
            if ($code -eq 0) { return 0 }
        }
        return 1
    }

    $code = Invoke-YtDlp (Build-YtDlpArgs $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $CookieBrowser $CookieFile)
    if ($code -eq 0) { return 0 }

    if ($OfferCookieRetry -and [string]::IsNullOrWhiteSpace($CookieBrowser) -and [string]::IsNullOrWhiteSpace($CookieFile)) {
        $answer = Read-Host "Tentar novamente usando cookies do navegador? [s/N]"
        if (Test-Yes $answer $false) {
            $browser = Select-CookieBrowser
            return (Invoke-YtDlpDownload $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $browser $null $false)
        }
    }
    return $code
}

function Invoke-GenericStreamlink([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat) {
    if (-not (Ensure-Dependency "streamlink" "fallback para streams")) { return 127 }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    if ($AudioOnly) {
        if (-not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
        $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
        $target = Join-Path $OutputDir ("stream-$stamp.$AudioFormat")
        $code = Invoke-Streamlink @($Url, "best", "-o", $temp)
        if ($code -ne 0) { Remove-Item $temp -Force -ErrorAction SilentlyContinue; return $code }
        & ffmpeg -y -i $temp -vn $target | Out-Host
        $ffCode = [int]$LASTEXITCODE
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
        return $ffCode
    }
    $target = Join-Path $OutputDir ("stream-$stamp.ts")
    return (Invoke-Streamlink @($Url, "best", "-o", $target))
}

function Invoke-Pluto([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat) {
    if (-not (Ensure-Dependency "streamlink" "Pluto TV")) { return 127 }
    if ($AudioOnly -and -not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
    if (-not (Test-Path -LiteralPath $PlutoDlPath)) { throw "pluto-dl.ps1 não encontrado." }
    & $PlutoDlPath -Url $Url -OutputRoot $OutputDir -AudioOnly:$AudioOnly -AudioFormat $AudioFormat
    if ($?) { return 0 }
    return 1
}

function Invoke-ThreadsFallback([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat) {
    if (-not (Ensure-Dependency "th" "fallback do Threads")) { return 127 }
    if ($AudioOnly -and -not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
    if (-not (Test-Path -LiteralPath $ThDlPath)) { throw "th-dl.ps1 não encontrado." }
    & $ThDlPath -Url $Url -OutputDir $OutputDir -AudioOnly:$AudioOnly -AudioFormat $AudioFormat
    if ($?) { return 0 }
    return 1
}

function Get-SiteKind([string]$Url) {
    try { $host = ([Uri]$Url).Host.ToLowerInvariant() } catch { return "generic" }
    if ($host -match '(^|\.)pluto\.tv$') { return "pluto" }
    if ($host -match '(^|\.)threads\.(com|net)$') { return "threads" }
    if ($host -match '(^|\.)(youtube\.com|youtu\.be)$') { return "youtube" }
    return "generic"
}

function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile
) {
    $output = Resolve-OutputPath $RequestedPath $Here
    Write-Host ""
    Write-Host "Destino: $output"
    $kind = Get-SiteKind $Url

    if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat) }

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $CookieBrowser $CookieFile $false
        if ($code -eq 0 -or $NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat)
    }

    $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $CookieBrowser $CookieFile $true
    if ($code -eq 0 -or $NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat)
}

function Show-Doctor([bool]$OfferInstall) {
    Write-Host "video-dl $Version"
    Write-Host ""
    foreach ($dep in @("yt-dlp", "ffmpeg", "streamlink", "th")) {
        if (Test-Dependency $dep) { Write-Ok ("  {0,-12} OK" -f $dep) }
        else { Write-Warn ("  {0,-12} AUSENTE" -f $dep) }
    }
    if ($OfferInstall) {
        $missing = @(@("yt-dlp", "ffmpeg", "streamlink", "th") | Where-Object { -not (Test-Dependency $_) })
        if ($missing.Count -gt 0) {
            $answer = Read-Host "`nInstalar dependências ausentes? [s/N]"
            if (Test-Yes $answer $false) { Install-AllMissingDependencies }
        }
    }
}

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
        $asset = @($release.assets | Where-Object { $_.name -eq "video-dl-setup.exe" }) | Select-Object -First 1
        if ($null -eq $asset) { throw "video-dl-setup.exe não encontrado na release." }
        $temp = Join-Path $env:TEMP ("video-dl-setup-" + [Guid]::NewGuid().ToString("N") + ".exe")
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $temp -UseBasicParsing
        Start-Process -FilePath $temp -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART")
        Write-Host "O atualizador foi iniciado. Abra um novo terminal quando terminar."
    } catch { Write-Fail "Falha ao atualizar: $($_.Exception.Message)" }
}

function Show-Help {
    @"
video-dl $Version - downloader universal

USO
  video-dl "URL"
  video-dl                         modo interativo

QUALIDADE / COMPATIBILIDADE
  --quality <altura>              limite de resolução (padrão: 1080)
  --max-quality                   melhor qualidade disponível, sem limite
  --wpp, --compat                 prioriza MP4 + H.264 + AAC
  --source                        não aplica o preset de compatibilidade

ÁUDIO
  --audio, --audio-only           baixa/extrai somente o áudio (MP3 por padrão)
  --audio-format <formato>        mp3, m4a, opus, flac, wav...

COOKIES
  --cookies <browser>             firefox, chrome, edge, brave ou auto
  --cookies-file <arquivo>        usa cookies.txt

DESTINO
  --path <nome|caminho>           escolhe destino salvo ou caminho direto
  --here                          salva na pasta atual
  --add-path <caminho>            adiciona destino
  --name <nome>                   usado junto com --add-path
  --default                       torna o destino adicionado padrão
  --paths                         lista destinos
  --remove-path <nome>            remove destino
  set-default <nome>              muda o destino padrão

OUTROS
  --playlist                      permite playlist do yt-dlp
  --no-fallback                   não tenta downloader alternativo
  --loop                          continua pedindo links
  doctor                          verifica dependências
  install-deps                    instala dependências ausentes
  update                          atualiza pelo GitHub
  --version                       mostra a versão
  --help                          mostra esta ajuda

PADRÃO
  Vídeo avulso: título original [ID].ext
  Qualidade: até 1080p, com fallback automático para resoluções menores.
  Compatibilidade: MP4/H.264/AAC quando possível.
"@ | Write-Host
}

function Parse-DownloadArguments([object[]]$Tokens) {
    $r = [PSCustomObject]@{
        Url = $null; RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = "mp3";
        NoFallback = $false; Playlist = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
        Compat = $true; CookieBrowser = $null; CookieFile = $null
    }
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $token = [string]$Tokens[$i]
        switch ($token.ToLowerInvariant()) {
            "--path" { if (++$i -ge $Tokens.Count) { throw "--path precisa de um valor." }; $r.RequestedPath = [string]$Tokens[$i] }
            "-p" { if (++$i -ge $Tokens.Count) { throw "-p precisa de um valor." }; $r.RequestedPath = [string]$Tokens[$i] }
            "--here" { $r.Here = $true }
            "--audio" { $r.AudioOnly = $true }
            "--audio-only" { $r.AudioOnly = $true }
            "--audio-format" { if (++$i -ge $Tokens.Count) { throw "--audio-format precisa de um valor." }; $r.AudioFormat = ([string]$Tokens[$i]).ToLowerInvariant(); $r.AudioOnly = $true }
            "--quality" { if (++$i -ge $Tokens.Count) { throw "--quality precisa de um valor." }; if ([string]$Tokens[$i] -notmatch '^\d+$') { throw "--quality deve ser numérico." }; $r.Quality = [int]$Tokens[$i]; $r.MaxQuality = $false }
            "--max-quality" { $r.MaxQuality = $true; $r.Compat = $false }
            "--wpp" { $r.Compat = $true }
            "--compat" { $r.Compat = $true }
            "--source" { $r.Compat = $false }
            "--cookies" { if (++$i -ge $Tokens.Count) { throw "--cookies precisa de um navegador." }; $r.CookieBrowser = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--cookies-file" { if (++$i -ge $Tokens.Count) { throw "--cookies-file precisa de um caminho." }; $r.CookieFile = Normalize-Path ([string]$Tokens[$i]) }
            "--playlist" { $r.Playlist = $true }
            "--no-fallback" { $r.NoFallback = $true }
            "--loop" { $r.Loop = $true }
            default {
                if ($token.StartsWith("-")) { throw "Opção desconhecida: $token" }
                if ([string]::IsNullOrWhiteSpace([string]$r.Url)) { $r.Url = $token }
                else { throw "Argumento inesperado: $token" }
            }
        }
    }
    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    return $r
}

try {
    $tokens = @($args)
    if ($tokens.Count -gt 0) {
        $cmd = ([string]$tokens[0]).ToLowerInvariant()
        switch ($cmd) {
            "help" { Show-Help; return }
            "--help" { Show-Help; return }
            "-h" { Show-Help; return }
            "--version" { Write-Host $Version; return }
            "version" { Write-Host $Version; return }
            "doctor" { Show-Doctor $true; return }
            "--doctor" { Show-Doctor $true; return }
            "install-deps" { Install-AllMissingDependencies; return }
            "--install-deps" { Install-AllMissingDependencies; return }
            "update" { Update-VideoDl; return }
            "paths" { Show-Paths; return }
            "--paths" { Show-Paths; return }
            "config" { Get-Config | ConvertTo-Json -Depth 8 | Write-Host; return }
            "--config" { Get-Config | ConvertTo-Json -Depth 8 | Write-Host; return }
            "remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "--remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "--set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
        }

        if ($cmd -in @("add-path", "--add-path")) {
            if ($tokens.Count -lt 2) { throw "Uso: video-dl --add-path <caminho> [--name Nome] [--default]" }
            $pathValue = [string]$tokens[1]
            $name = $null
            $makeDefault = $false
            for ($i = 2; $i -lt $tokens.Count; $i++) {
                $t = ([string]$tokens[$i]).ToLowerInvariant()
                if ($t -eq "--name") { if (++$i -ge $tokens.Count) { throw "--name precisa de um valor." }; $name = [string]$tokens[$i] }
                elseif ($t -eq "--default") { $makeDefault = $true }
                else { throw "Opção desconhecida em add-path: $($tokens[$i])" }
            }
            Add-PathCommand $pathValue $name $makeDefault
            return
        }
    }

    $parsed = Parse-DownloadArguments $tokens
    if ([string]::IsNullOrWhiteSpace([string]$parsed.Url)) {
        Write-Info "video-dl - modo interativo"
        while ($true) {
            $url = Read-Host "`nCole uma URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
        return
    }

    $code = Invoke-OneDownload $parsed.Url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile
    if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }

    if ($parsed.Loop) {
        while ($true) {
            $url = Read-Host "`nPróxima URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
    }
} catch {
    Write-Fail "ERRO: $($_.Exception.Message)"
    Write-Host "Use 'video-dl --help' para ver os comandos."
    exit 1
}
