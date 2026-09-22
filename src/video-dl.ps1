# video-dl.ps1
# Universal video/audio downloader dispatcher for Windows PowerShell / PowerShell 7.

$ErrorActionPreference = "Stop"
$Version = "0.4.24"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $HOME ".video-dl"
$ConfigPath = Join-Path $ConfigDir "config.json"
$PrivateBin = Join-Path $ConfigDir "bin"
$DefaultDownloadPath = Join-Path (Join-Path $HOME "Videos") "video-dl"
$PlutoDlPath = Join-Path $ScriptRoot "pluto-dl.ps1"
$ThDlPath = Join-Path $ScriptRoot "th-dl.ps1"
$WcoDlPath = Join-Path $ScriptRoot "wcostream-dl.ps1"
$ArchiveHelperPath = Join-Path $ScriptRoot "archive.ps1"
$EpisodeDetectionPath = Join-Path $ScriptRoot "episode-detection.ps1"
$AnimesDigitalPath = Join-Path $ScriptRoot "animesdigital.ps1"
if (-not (Test-Path -LiteralPath $ArchiveHelperPath -PathType Leaf)) { throw "archive.ps1 não encontrado." }
if (-not (Test-Path -LiteralPath $EpisodeDetectionPath -PathType Leaf)) { throw "episode-detection.ps1 não encontrado." }
if (-not (Test-Path -LiteralPath $AnimesDigitalPath -PathType Leaf)) { throw "animesdigital.ps1 não encontrado." }
. $ArchiveHelperPath
. $EpisodeDetectionPath
. $AnimesDigitalPath
$script:YtDlpUnsupportedHosts = @{}

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

function Safe-Name([string]$Name, [int]$MaxLength = 170) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "Sem título" }
    $value = $Name
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $value = $value.Replace([string]$char, "_")
    }
    $value = ($value -replace '\s+', ' ').Trim().TrimEnd('.', ' ')
    if ($value.Length -gt $MaxLength) { $value = $value.Substring(0, $MaxLength).Trim() }
    if ([string]::IsNullOrWhiteSpace($value)) { return "Sem título" }
    return $value
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

function Invoke-YtDlpCapture([object[]]$Arguments) {
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if (Test-Command "yt-dlp") {
            $text = (& yt-dlp @Arguments 2>&1 | Out-String)
            return [PSCustomObject]@{ Code = [int]$LASTEXITCODE; Text = $text }
        }
        if (Test-PythonModule "yt_dlp") {
            $python = Get-PythonCommand
            if ($python -eq "py") { $text = (& py -3 -m yt_dlp @Arguments 2>&1 | Out-String) }
            else { $text = (& python -m yt_dlp @Arguments 2>&1 | Out-String) }
            return [PSCustomObject]@{ Code = [int]$LASTEXITCODE; Text = $text }
        }
    } catch {
        return [PSCustomObject]@{ Code = 1; Text = [string]$_.Exception.Message }
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    return [PSCustomObject]@{ Code = 127; Text = "" }
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

function Invoke-StreamlinkCapture([object[]]$Arguments) {
    try {
        if (Test-Command "streamlink") {
            $text = (& streamlink @Arguments 2>$null | Out-String)
            return [PSCustomObject]@{ Code = [int]$LASTEXITCODE; Text = $text }
        }
        if (Test-PythonModule "streamlink") {
            $python = Get-PythonCommand
            if ($python -eq "py") { $text = (& py -3 -m streamlink @Arguments 2>$null | Out-String) }
            else { $text = (& python -m streamlink @Arguments 2>$null | Out-String) }
            return [PSCustomObject]@{ Code = [int]$LASTEXITCODE; Text = $text }
        }
    } catch { }
    return [PSCustomObject]@{ Code = 127; Text = "" }
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
        Write-Info "Instalando/atualizando Streamlink estável via Python..."
        $code = Invoke-Python @("-m", "pip", "install", "-U", "streamlink")
        if ($code -eq 0 -and (Test-Dependency "streamlink")) {
            Write-Ok "Streamlink atualizado."
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
        version = 5
        defaultPath = $null
        autoUseDefault = $false
        videoContainer = "mp4"
        audioFormat = "mp3"
        qualityInFilename = $true
        duplicatePolicy = "skip"
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
        Write-Host "Onde deseja salvar seus downloads?"
        Write-Host "Sugestão: $DefaultDownloadPath"
        $answer = Read-Host "Caminho (Enter para usar a sugestão)"
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

        $needsSave = $false
        if ($null -eq $config.PSObject.Properties["autoUseDefault"]) {
            Add-Member -InputObject $config -NotePropertyName autoUseDefault -NotePropertyValue $false
            # Nas versões anteriores, defaultPath só escolhia a opção sugerida no prompt.
            # Mantemos o comportamento antigo ao migrar: continuar perguntando.
            $config.defaultPath = $null
            $needsSave = $true
        }
        if ($null -eq $config.PSObject.Properties["videoContainer"]) {
            Add-Member -InputObject $config -NotePropertyName videoContainer -NotePropertyValue "mp4"
            $needsSave = $true
        }
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
            throw "videoContainer deve ser 'mp4' ou 'mkv'."
        }
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
        if ([bool]$config.autoUseDefault -and ([string]::IsNullOrWhiteSpace([string]$config.defaultPath) -or $null -eq (Get-PathByName $config ([string]$config.defaultPath)))) {
            $config.autoUseDefault = $false
            $config.defaultPath = $null
            $needsSave = $true
        }
        if ($needsSave) { Save-Config $config }
        return $config
    } catch {
        throw "Configuração inválida em '$ConfigPath': $($_.Exception.Message) Use 'video-dl config' para corrigir o arquivo manualmente."
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
    if ($paths.Count -eq 1) {
        Ensure-Directory ([string]$paths[0].path)
        return [string]$paths[0].path
    }

    if ([bool]$config.autoUseDefault -and -not [string]::IsNullOrWhiteSpace([string]$config.defaultPath)) {
        $defaultPath = Get-PathByName $config ([string]$config.defaultPath)
        if ($null -ne $defaultPath) {
            Ensure-Directory ([string]$defaultPath.path)
            return [string]$defaultPath.path
        }
    }

    Write-Host ""
    Write-Host "Onde deseja salvar?"
    for ($i = 0; $i -lt $paths.Count; $i++) {
        Write-Host ("  [{0}] {1,-16} {2}" -f ($i + 1), $paths[$i].name, $paths[$i].path)
    }

    while ($true) {
        $choice = Read-Host "Escolha"
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $paths.Count) {
            $idx = [int]$choice - 1
            break
        }
        Write-Warn "Escolha um destino entre 1 e $($paths.Count)."
    }

    Ensure-Directory ([string]$paths[$idx].path)
    return [string]$paths[$idx].path
}

function Show-Paths {
    $config = Get-Config
    $automatic = [bool]$config.autoUseDefault
    Write-Host "Destinos salvos:"
    foreach ($item in @($config.paths)) {
        $isDefault = $automatic -and ([string]$item.name -ieq [string]$config.defaultPath)
        $marker = if ($isDefault) { "*" } else { " " }
        $suffix = if ($isDefault) { "  [padrão]" } else { "" }
        Write-Host ("  {0} {1,-16} {2}{3}" -f $marker, $item.name, $item.path, $suffix)
    }
    Write-Host ""
    if ($automatic) {
        Write-Host "Modo: usando '$($config.defaultPath)' automaticamente."
    } else {
        Write-Host "Modo: perguntar quando houver mais de um destino."
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
    if ($MakeDefault) { $config.defaultPath = $Name; $config.autoUseDefault = $true }
    Save-Config $config
    Write-Ok "Destino adicionado: $Name -> $normalized"
}

function Remove-PathCommand([string]$Name) {
    $config = Get-Config
    $remaining = @($config.paths | Where-Object { $_.name -ine $Name })
    if ($remaining.Count -eq @($config.paths).Count) { throw "Destino '$Name' não encontrado." }
    if ($remaining.Count -eq 0) { throw "Não é possível remover o único destino." }
    $config.paths = $remaining
    if ([string]$config.defaultPath -ieq $Name) { $config.defaultPath = $null; $config.autoUseDefault = $false }
    Save-Config $config
    Write-Ok "Destino removido: $Name"
}

function Set-DefaultPathCommand([string]$Name) {
    $config = Get-Config
    if ($null -eq (Get-PathByName $config $Name)) { throw "Destino '$Name' não encontrado." }
    $config.defaultPath = $Name
    $config.autoUseDefault = $true
    Save-Config $config
    Write-Ok "Destino padrão: $Name (uso automático ativado)"
}

function Unset-DefaultPathCommand {
    $config = Get-Config
    $config.defaultPath = $null
    $config.autoUseDefault = $false
    Save-Config $config
    Write-Ok "Destino padrão removido. O video-dl voltará a perguntar quando houver mais de um destino."
}

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
function Show-Settings {
    $config = Get-Config
    $destination = if ([bool]$config.autoUseDefault) { "$($config.defaultPath) [automático]" } else { "perguntar quando necessário" }
    Write-Host "Configurações:"
    Write-Host ""
    Write-Host ("  Destino:    {0}" -f $destination)
    Write-Host ("  Vídeo:      {0}" -f ([string]$config.videoContainer).ToUpperInvariant())
    Write-Host ("  Áudio:      {0}" -f ([string]$config.audioFormat).ToUpperInvariant())
    Write-Host "  Qualidade:  1080p por padrão"
    Write-Host ("  Nome:       qualidade {0}" -f $(if ([bool]$config.qualityInFilename) { "no arquivo" } else { "oculta" }))
    Write-Host ("  Duplicados: {0}" -f ([string]$config.duplicatePolicy))
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
        $urlHost = Get-UrlHost $Url
        if (-not [string]::IsNullOrWhiteSpace($urlHost)) { $script:YtDlpUnsupportedHosts[$urlHost] = $true }
    }
}

function Test-YtDlpUnsupportedForSession([string]$Url) {
    $urlHost = Get-UrlHost $Url
    return (-not [string]::IsNullOrWhiteSpace($urlHost) -and $script:YtDlpUnsupportedHosts.ContainsKey($urlHost))
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

function Get-CookieArgs([string]$Browser, [string]$CookieFile) {
    if (-not [string]::IsNullOrWhiteSpace($CookieFile)) { return @("--cookies", $CookieFile) }
    if (-not [string]::IsNullOrWhiteSpace($Browser) -and $Browser -ne "auto") { return @("--cookies-from-browser", $Browser) }
    return @()
}

function Convert-YtDate([object]$Metadata) {
    if ($null -eq $Metadata) { return (Get-Date -Format "yyyy-MM-dd") }
    foreach ($field in @("upload_date", "release_date", "modified_date")) {
        $raw = [string]$Metadata.$field
        if ($raw -match '^(\d{4})(\d{2})(\d{2})$') { return "$($Matches[1])-$($Matches[2])-$($Matches[3])" }
        if ($raw -match '^\d{4}-\d{2}-\d{2}') { return $raw.Substring(0, 10) }
    }
    foreach ($field in @("timestamp", "release_timestamp")) {
        if ($null -ne $Metadata.$field) {
            try { return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Metadata.$field).LocalDateTime.ToString("yyyy-MM-dd") } catch { }
        }
    }
    return (Get-Date -Format "yyyy-MM-dd")
}

function Get-YtDlpMetadata([string]$Url, [string]$CookieBrowser, [string]$CookieFile) {
    if (-not (Test-Dependency "yt-dlp")) { return $null }
    $baseArgs = @("--dump-single-json", "--skip-download", "--no-warnings", "--no-playlist")

    if ($CookieBrowser -eq "auto") {
        foreach ($candidate in @(Get-CookieCandidates "auto")) {
            $probe = Invoke-YtDlpCapture ($baseArgs + @(Get-CookieArgs $candidate $CookieFile) + @($Url))
            if ($probe.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($probe.Text)) {
                try { return ($probe.Text | ConvertFrom-Json) } catch { }
            }
            Register-YtDlpProbeFailure $Url $probe
        }
        return $null
    }

    $probe = Invoke-YtDlpCapture ($baseArgs + @(Get-CookieArgs $CookieBrowser $CookieFile) + @($Url))
    if ($probe.Code -ne 0 -or [string]::IsNullOrWhiteSpace($probe.Text)) {
        Register-YtDlpProbeFailure $Url $probe
        return $null
    }
    try { return ($probe.Text | ConvertFrom-Json) } catch { return $null }
}

function Get-StreamlinkMetadata([string]$Url) {
    if (-not (Test-Dependency "streamlink")) { return $null }
    $probe = Invoke-StreamlinkCapture @("--json", $Url)
    if ($probe.Code -ne 0 -or [string]::IsNullOrWhiteSpace($probe.Text)) { return $null }
    try { return ($probe.Text | ConvertFrom-Json) } catch { return $null }
}

function Get-PageEpisodeNumbers([string]$Url) {
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

    } catch { }
    return $result
}

function Apply-TitleEpisodeGuess([object]$Info) {
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
}

function Get-LinkMetadata([string]$Url, [string]$CookieBrowser, [string]$CookieFile, [bool]$ProbeEpisodeNumbers) {
    $info = [PSCustomObject]@{
        Title = $null; Series = $null; SeriesConfidence = "nenhuma";
        SeasonNumber = $null; EpisodeNumber = $null; Date = (Get-Date -Format "yyyy-MM-dd"); Id = $null;
        Source = "fallback"
    }

    $siteKind = Get-SiteKind $Url
    if ($siteKind -eq "wcostream") { return (Get-WcoMetadata $Url) }
    if ($siteKind -eq "animesdigital") { return (Get-AnimesDigitalEpisodeMetadata $Url) }
    $yt = if ($siteKind -in @("pluto", "hls")) { $null } else { Get-YtDlpMetadata $Url $CookieBrowser $CookieFile }
    if ($null -ne $yt) {
        $info.Source = "yt-dlp"
        $info.Title = if (-not [string]::IsNullOrWhiteSpace([string]$yt.episode)) { [string]$yt.episode } else { [string]$yt.title }
        $info.Id = [string]$yt.id
        $info.Date = Convert-YtDate $yt
        if (-not [string]::IsNullOrWhiteSpace([string]$yt.series)) {
            $info.Series = [string]$yt.series
            $info.SeriesConfidence = "alta"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$yt.playlist_title)) {
            $info.Series = [string]$yt.playlist_title
            $info.SeriesConfidence = "média"
        }
        if ($null -ne $yt.season_number) { try { $info.SeasonNumber = [int]$yt.season_number } catch { } }
        if ($null -ne $yt.episode_number) { try { $info.EpisodeNumber = [int]$yt.episode_number } catch { } }
    } else {
        $sl = Get-StreamlinkMetadata $Url
        if ($null -ne $sl -and $null -ne $sl.metadata) {
            $info.Source = "streamlink"
            if (-not [string]::IsNullOrWhiteSpace([string]$sl.metadata.title)) { $info.Title = [string]$sl.metadata.title }
            if (-not [string]::IsNullOrWhiteSpace([string]$sl.metadata.author)) {
                $info.Series = [string]$sl.metadata.author
                $info.SeriesConfidence = "média"
            }
        }
    }

    $info = Apply-TitleEpisodeGuess $info
    if ($ProbeEpisodeNumbers -and $siteKind -eq "pluto") {
        $plutoSeriesHint = [string]$info.Series
        $plutoShowId = $null
        if ($Url -match '/(?:shows|on-demand/series)/([^/?#]+)') { $plutoShowId = [string]$Matches[1] }
        if ([string]::IsNullOrWhiteSpace($plutoSeriesHint) -and -not [string]::IsNullOrWhiteSpace($plutoShowId)) {
            $plutoStatePath = Join-Path $ConfigDir "pluto-state.json"
            if (Test-Path -LiteralPath $plutoStatePath -PathType Leaf) {
                try {
                    $savedStates = @((Get-Content -LiteralPath $plutoStatePath -Raw -Encoding UTF8 | ConvertFrom-Json))
                    $savedHint = $savedStates | Where-Object { [string]$_.showId -eq $plutoShowId } | Select-Object -First 1
                    if ($null -ne $savedHint -and -not [string]::IsNullOrWhiteSpace([string]$savedHint.series)) {
                        $plutoSeriesHint = [string]$savedHint.series
                    }
                } catch { }
            }
        }

        $plutoInfo = Get-VideoDlPlutoEpisodeNumbers $Url $plutoSeriesHint

        if ($null -eq $info.SeasonNumber -and $null -ne $plutoInfo.Season) {
            $info.SeasonNumber = [int]$plutoInfo.Season
        }
        if ($null -eq $info.EpisodeNumber -and $null -ne $plutoInfo.Episode) {
            $info.EpisodeNumber = [int]$plutoInfo.Episode
        }
        if ([string]::IsNullOrWhiteSpace([string]$info.Series) -and -not [string]::IsNullOrWhiteSpace([string]$plutoInfo.SeriesTitle)) {
            $info.Series = [string]$plutoInfo.SeriesTitle
            $info.SeriesConfidence = "alta"
        }

        $titleText = ([string]$info.Title).Trim()
        $genericTitle = [string]::IsNullOrWhiteSpace($titleText) -or $titleText -in @("Vídeo", "Video", "Episódio", "Episodio", "Episode")
        if ($genericTitle -and -not [string]::IsNullOrWhiteSpace([string]$plutoInfo.Title)) {
            $info.Title = [string]$plutoInfo.Title
        }

        if ([string]::IsNullOrWhiteSpace([string]$info.Series) -and -not [string]::IsNullOrWhiteSpace($plutoSeriesHint)) {
            $info.Series = $plutoSeriesHint
            $info.SeriesConfidence = "alta"
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$plutoInfo.SeriesTitle) -or -not [string]::IsNullOrWhiteSpace([string]$plutoInfo.Title)) {
            $info.Source = [string]$plutoInfo.Pattern
        }
    }
    if ($ProbeEpisodeNumbers -and $siteKind -eq "pluto" -and [string]::IsNullOrWhiteSpace([string]$info.Series)) {
        $showId = $null
        if ($Url -match '/(?:shows|on-demand/series)/([^/?#]+)') { $showId = [string]$Matches[1] }
        $plutoStatePath = Join-Path $ConfigDir "pluto-state.json"
        if (-not [string]::IsNullOrWhiteSpace($showId) -and (Test-Path -LiteralPath $plutoStatePath -PathType Leaf)) {
            try {
                $savedStates = @((Get-Content -LiteralPath $plutoStatePath -Raw -Encoding UTF8 | ConvertFrom-Json))
                $saved = $savedStates | Where-Object { [string]$_.showId -eq $showId } | Select-Object -First 1
                if ($null -ne $saved -and -not [string]::IsNullOrWhiteSpace([string]$saved.series)) {
                    $info.Series = [string]$saved.series
                    $info.SeriesConfidence = "alta"
                    if ($null -eq $info.SeasonNumber -and $null -ne $saved.season) {
                        try { $info.SeasonNumber = [int]$saved.season } catch { }
                    }
                    $info.Source = "pluto-state"
                }
            } catch { }
        }
    }

    if ($ProbeEpisodeNumbers -and ($null -eq $info.SeasonNumber -or $null -eq $info.EpisodeNumber)) {
        $page = Get-PageEpisodeNumbers $Url
        if ($null -eq $info.SeasonNumber -and $null -ne $page.Season) { $info.SeasonNumber = [int]$page.Season }
        if ($null -eq $info.EpisodeNumber -and $null -ne $page.Episode) { $info.EpisodeNumber = [int]$page.Episode }
    }
    if ([string]::IsNullOrWhiteSpace([string]$info.Title)) { $info.Title = "Vídeo" }
    return $info
}

function Build-YtDlpArgs(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat, [string]$VideoContainer,
    [string]$CookieBrowser, [string]$CookieFile, [string]$OutputTemplate
) {
    if ([string]::IsNullOrWhiteSpace($OutputTemplate)) { $OutputTemplate = "%(title).180B.%(ext)s" }
    $config = Get-Config
    if (-not $AudioOnly -and [bool]$config.qualityInFilename -and $OutputTemplate -notmatch '%\(height\)s?p') {
        $OutputTemplate = $OutputTemplate -replace '\.%\(ext\)s$', ' [%(height)sp].%(ext)s'
    }
    $overwriteArg = if ([string]$config.duplicatePolicy -eq "overwrite") { "--force-overwrites" } else { "--no-overwrites" }
    $argsList = @("--windows-filenames", "--continue", $overwriteArg, "-P", $OutputDir, "-o", $OutputTemplate)
    if ($Playlist) { $argsList += "--yes-playlist" } else { $argsList += "--no-playlist" }

    if ($AudioOnly) {
        $argsList += @("-x", "--audio-format", $AudioFormat, "--audio-quality", "0")
    } else {
        if ($VideoContainer -eq "mp4") {
            if ($Compat) {
                $compatHeight = if ($MaxQuality) { "" } else { "[height<=$Quality]" }
                $compatFormat = "bv*[vcodec^=avc1]$compatHeight+ba[acodec^=mp4a]/b[vcodec^=avc1][acodec^=mp4a]$compatHeight"
                $argsList += @("-f", $compatFormat, "--merge-output-format", "mp4", "--remux-video", "mp4", "--postprocessor-args", "ffmpeg:-movflags +faststart")
            } else { $argsList += @("--merge-output-format", "mp4", "--remux-video", "mp4") }
        } elseif ($VideoContainer -eq "mkv") {
            $argsList += @("--merge-output-format", "mkv", "--remux-video", "mkv")
        }
        if (-not $MaxQuality -and -not $Compat) {
            if (Test-Dependency "ffmpeg") { $argsList += @("-f", "bv*[height<=$Quality]+ba/b[height<=$Quality]") }
            else { $argsList += @("-f", "b[height<=$Quality]/b") }
        }
    }

    $argsList += @(Get-CookieArgs $CookieBrowser $CookieFile)
    $argsList += $Url
    return $argsList
}

function Invoke-YtDlpDownload(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat,
    [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat, [string]$VideoContainer,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$OfferCookieRetry, [string]$OutputTemplate
) {
    if (-not (Ensure-Dependency "yt-dlp" "downloads de vídeo e áudio")) { return 127 }
    if ($AudioOnly -and -not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }

    if (-not $AudioOnly -and -not $MaxQuality -and -not (Test-Dependency "ffmpeg")) {
        Write-Warn "FFmpeg não está instalado; sem ele, a qualidade disponível pode ser menor."
        $answer = Read-Host "Instalar FFmpeg para permitir vídeo+áudio em alta qualidade? [S/n]"
        if (Test-Yes $answer $true) { [void](Install-Ffmpeg) }
    }

    if ($CookieBrowser -eq "auto") {
        foreach ($candidate in @(Get-CookieCandidates "auto")) {
            Write-Info "Tentando com cookies do $candidate..."
            $code = Invoke-YtDlp (Build-YtDlpArgs $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $VideoContainer $candidate $CookieFile $OutputTemplate)
            if ($code -eq 0) { return 0 }
        }
        return 1
    }

    $code = Invoke-YtDlp (Build-YtDlpArgs $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $OutputTemplate)
    if ($code -eq 0) { return 0 }

    if ($OfferCookieRetry -and [string]::IsNullOrWhiteSpace($CookieBrowser) -and [string]::IsNullOrWhiteSpace($CookieFile)) {
        $answer = Read-Host "Tentar novamente usando cookies do navegador? [s/N]"
        if (Test-Yes $answer $false) {
            $browser = Select-CookieBrowser
            return (Invoke-YtDlpDownload $Url $OutputDir $AudioOnly $AudioFormat $Playlist $Quality $MaxQuality $Compat $VideoContainer $browser $null $false $OutputTemplate)
        }
    }
    return $code
}

function Invoke-StreamlinkToFile(
    [string]$Url, [string]$OutputPath, [int]$SegmentThreads = 1
) {
    $threads = [Math]::Max(1, [Math]::Min($SegmentThreads, 10))
    $attempts = @($threads)
    if ($threads -gt 1) { $attempts += 1 }

    foreach ($attempt in $attempts) {
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        $argsList = @()
        if ($attempt -gt 1) {
            Write-Info "HLS: baixando com $attempt segmentos em paralelo."
            $argsList += @("--stream-segment-threads", [string]$attempt)
        }
        $argsList += @($Url, "best", "-o", $OutputPath)
        $code = Invoke-Streamlink $argsList
        if ($code -eq 0) { return 0 }
        if ($attempt -gt 1) {
            Write-Warn "Download HLS paralelo falhou. Tentando novamente com 1 segmento..."
        }
    }
    return [int]$code
}

function Invoke-GenericStreamlink(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat,
    [string]$VideoContainer, [string]$FileBase, [string]$Identity, [string]$SourceId,
    [int]$SegmentThreads = 1, [string]$HistoryUrl = $null
) {
    if (-not (Ensure-Dependency "streamlink" "fallback para streams")) { return 127 }
    if ([string]::IsNullOrWhiteSpace($FileBase)) { $FileBase = (Get-Date -Format "yyyy-MM-dd") + " - stream-" + (Get-Date -Format "HHmmss") }
    $FileBase = Safe-Name $FileBase
    if ([string]::IsNullOrWhiteSpace($Identity)) { $Identity = Get-VideoDlIdentity (Get-UrlHost $Url) $SourceId $Url }
    $recordUrl = if ([string]::IsNullOrWhiteSpace($HistoryUrl)) { $Url } else { $HistoryUrl }

    if ($AudioOnly) {
        if (-not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
        $desired = Join-Path $OutputDir ($FileBase + "." + $AudioFormat)
        $decision = Resolve-VideoDlTarget $Identity $desired $recordUrl $SourceId $false
        if ($decision.Skip) { return 0 }
        $target = [string]$decision.Path
        $FileBase = [System.IO.Path]::GetFileNameWithoutExtension($target)
        $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
        $code = Invoke-StreamlinkToFile $Url $temp $SegmentThreads
        if ($code -ne 0) { Remove-Item $temp -Force -ErrorAction SilentlyContinue; return $code }
        $ffArgs = @("-y", "-i", $temp, "-vn")
        switch ($AudioFormat.ToLowerInvariant()) {
            "mp3" { $ffArgs += @("-c:a", "libmp3lame", "-q:a", "0") }
            "m4a" { $ffArgs += @("-c:a", "aac", "-b:a", "192k") }
            "aac" { $ffArgs += @("-c:a", "aac", "-b:a", "192k") }
            "opus" { $ffArgs += @("-c:a", "libopus", "-b:a", "160k") }
            "wav" { $ffArgs += @("-c:a", "pcm_s16le") }
            "flac" { $ffArgs += @("-c:a", "flac") }
        }
        $ffArgs += $target
        & ffmpeg @ffArgs | Out-Host
        $ffCode = [int]$LASTEXITCODE
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
        if ($ffCode -eq 0 -and (Test-Path -LiteralPath $target -PathType Leaf)) { Register-VideoDlDownload $Identity $target $recordUrl $SourceId }
        return $ffCode
    }

    $hasFfmpeg = Ensure-Dependency "ffmpeg" "saída de vídeo em $VideoContainer"
    if (-not $hasFfmpeg) {
        Write-Warn "FFmpeg não disponível; salvando o stream original em .ts."
        $desired = Join-Path $OutputDir ($FileBase + ".ts")
        $decision = Resolve-VideoDlTarget $Identity $desired $recordUrl $SourceId $false
        if ($decision.Skip) { return 0 }
        $target = [string]$decision.Path
        $code = Invoke-StreamlinkToFile $Url $target $SegmentThreads
        if ($code -eq 0 -and (Test-Path -LiteralPath $target -PathType Leaf)) { Register-VideoDlDownload $Identity $target $recordUrl $SourceId }
        return $code
    }

    $desired = Join-Path $OutputDir ($FileBase + "." + $VideoContainer)
    $decision = Resolve-VideoDlTarget $Identity $desired $recordUrl $SourceId $false
    if ($decision.Skip) { return 0 }
    $target = [string]$decision.Path
    $FileBase = [System.IO.Path]::GetFileNameWithoutExtension($target)
    $temp = Join-Path $env:TEMP ("video-dl-stream-" + [Guid]::NewGuid().ToString("N") + ".ts")
    $code = Invoke-StreamlinkToFile $Url $temp $SegmentThreads
    if ($code -ne 0) { Remove-Item $temp -Force -ErrorAction SilentlyContinue; return $code }

    $ffArgs = @("-y", "-i", $temp, "-map", "0", "-c", "copy")
    if ($VideoContainer -eq "mp4") { $ffArgs += @("-movflags", "+faststart") }
    $ffArgs += $target
    & ffmpeg @ffArgs | Out-Host
    $ffCode = [int]$LASTEXITCODE

    if ($ffCode -ne 0 -and $VideoContainer -eq "mp4") {
        Write-Warn "O stream não pôde ser remuxado para MP4. Tentando MKV sem re-encode..."
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        $desiredMkv = Join-Path $OutputDir ($FileBase + ".mkv")
        $mkvDecision = Resolve-VideoDlTarget $Identity $desiredMkv $recordUrl $SourceId $false
        if ($mkvDecision.Skip) { Remove-Item $temp -Force -ErrorAction SilentlyContinue; return 0 }
        $target = [string]$mkvDecision.Path
        & ffmpeg -y -i $temp -map 0 -c copy $target | Out-Host
        $ffCode = [int]$LASTEXITCODE
    }
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    if ($ffCode -eq 0 -and (Test-Path -LiteralPath $target -PathType Leaf)) {
        $target = Add-QualitySuffix $target
        Register-VideoDlDownload $Identity $target $recordUrl $SourceId
    }
    return $ffCode
}

function Get-StreamlinkVersion {
    try {
        $text = ""
        if (Test-Command "streamlink") {
            $text = (& streamlink --version 2>$null | Out-String)
        } elseif (Test-PythonModule "streamlink") {
            $python = Get-PythonCommand
            if ($python -eq "py") { $text = (& py -3 -m streamlink --version 2>$null | Out-String) }
            else { $text = (& python -m streamlink --version 2>$null | Out-String) }
        }
        if ($text -match '(\d+\.\d+(?:\.\d+)?)') {
            return [version]$Matches[1]
        }
    } catch { }
    return $null
}

function Ensure-PlutoStreamlink {
    if (-not (Ensure-Dependency "streamlink" "Pluto TV")) { return $false }

    $version = Get-StreamlinkVersion
    if ($null -ne $version) {
        Write-Host "Streamlink: $version"
        if ($version -lt [version]"8.6.0") {
            Write-Warn "A Pluto requer Streamlink 8.6.0+ para o suporte VOD corrigido. Atualizando..."
            if (-not (Install-Streamlink)) { return $false }
            $version = Get-StreamlinkVersion
            if ($null -ne $version) { Write-Host "Streamlink atualizado: $version" }
        }
    }
    return $true
}

function Invoke-Pluto(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer, [bool]$SeriesMode,
    [string]$SeriesName = $null, [Nullable[int]]$SeasonNumber = $null, [Nullable[int]]$EpisodeNumber = $null
) {
    if (-not (Ensure-PlutoStreamlink)) { return 127 }
    if ($AudioOnly -and -not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
    if (-not $AudioOnly -and -not (Test-Dependency "ffmpeg")) {
        Write-Warn "FFmpeg é necessário para finalizar o vídeo em $VideoContainer."
        $answer = Read-Host "Instalar FFmpeg agora? [S/n]"
        if (Test-Yes $answer $true) { [void](Install-Ffmpeg) }
        if (-not (Test-Dependency "ffmpeg")) { Write-Warn "Sem FFmpeg, a Pluto será salva em .ts como fallback." }
    }
    if (-not (Test-Path -LiteralPath $PlutoDlPath)) { throw "pluto-dl.ps1 não encontrado." }

    $plutoArgs = @{
        Url = $Url
        OutputRoot = $OutputDir
        AudioOnly = $AudioOnly
        AudioFormat = $AudioFormat
        VideoContainer = $VideoContainer
        SeriesMode = $SeriesMode
    }
    if (-not [string]::IsNullOrWhiteSpace($SeriesName)) { $plutoArgs.SeriesName = $SeriesName }
    if ($null -ne $SeasonNumber) { $plutoArgs.SeasonNumber = [int]$SeasonNumber }
    if ($null -ne $EpisodeNumber) { $plutoArgs.EpisodeNumber = [int]$EpisodeNumber }

    & $PlutoDlPath @plutoArgs
    if ($?) { return 0 }
    return 1
}

function Invoke-ThreadsFallback([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer, [string]$FileBase) {
    if (-not (Ensure-Dependency "th" "fallback do Threads")) { return 127 }
    if ($AudioOnly -and -not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
    if (-not (Test-Path -LiteralPath $ThDlPath)) { throw "th-dl.ps1 não encontrado." }
    & $ThDlPath -Url $Url -OutputDir $OutputDir -AudioOnly:$AudioOnly -AudioFormat $AudioFormat -VideoContainer $VideoContainer -FileBase $FileBase
    if ($?) { return 0 }
    return 1
}

function Get-SiteKind([string]$Url) {
    try {
        $uri = [Uri]$Url
        $urlHost = $uri.Host.ToLowerInvariant()
        $urlPath = $uri.AbsolutePath.ToLowerInvariant()
    } catch { return "generic" }
    if ($urlPath -match '\.m3u8
function Get-WcoMetadata([string]$Url) {
    $info = [PSCustomObject]@{
        Title = "Vídeo"; Series = $null; SeriesConfidence = "nenhuma";
        SeasonNumber = 1; EpisodeNumber = $null; Date = (Get-Date -Format "yyyy-MM-dd"); Id = $null;
        Source = "wcostream-url"
    }
    try {
        $slug = [Uri]::UnescapeDataString(([Uri]$Url).AbsolutePath.Trim('/'))
        if ($slug -match '(?i)^(.+?)-episode-(\d+)(?:-(.*))?$') {
            $seriesSlug = $Matches[1]
            $info.EpisodeNumber = [int]$Matches[2]
            $titleSlug = [string]$Matches[3]
            $info.Series = (($seriesSlug -split '-' | Where-Object { $_ } | ForEach-Object {
                if ($_.Length -gt 1) { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) } else { $_.ToUpperInvariant() }
            }) -join ' ')
            $info.SeriesConfidence = "média"
            if (-not [string]::IsNullOrWhiteSpace($titleSlug)) {
                $info.Title = (($titleSlug -split '-' | Where-Object { $_ }) -join ' ')
            } else { $info.Title = "Episódio $($info.EpisodeNumber)" }
            $info.Id = $slug
        }
    } catch { }
    return $info
}

function Invoke-WcoStream(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [string]$FileBase, [string]$Identity, [string]$SourceId
) {
    if ($AudioOnly) { Write-Warn "WCOStream: --audio ainda não é suportado."; return 1 }
    if (-not (Test-Path -LiteralPath $WcoDlPath -PathType Leaf)) { throw "wcostream-dl.ps1 não encontrado." }
    $desired = Join-Path $OutputDir ($FileBase + ".mp4")
    $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
    if ($decision.Skip) { return 0 }
    $target = [string]$decision.Path
    & $WcoDlPath -Url $Url -OutputPath $target
    if (-not $?) { return 1 }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $final = Add-QualitySuffix $target
        Register-VideoDlDownload $Identity $final $Url $SourceId
        return 0
    }
    return 1
}

function Get-AvulsoNaming([string]$Url, [string]$CookieBrowser, [string]$CookieFile) {
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $false
    $date = if ($null -ne $metadata) { [string]$metadata.Date } else { Get-Date -Format "yyyy-MM-dd" }
    $title = if ($null -ne $metadata) { [string]$metadata.Title } else { "Vídeo" }
    $sourceId = if ($null -ne $metadata) { [string]$metadata.Id } else { $null }
    $fileBase = "$date - $(Safe-Name $title 155)"
    $template = "$fileBase.%(ext)s"
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
    return [PSCustomObject]@{
        Metadata = $metadata
        FileBase = $fileBase
        Template = $template
        Identity = $identity
        SourceId = $sourceId
    }
}

function Register-YtDlpResult([string]$Identity, [string]$Url, [string]$SourceId, [string]$OutputDir, [string]$FileBase) {
    $result = Find-VideoDlOutputForBase $OutputDir $FileBase
    if ($null -ne $result) { Register-VideoDlDownload $Identity $result.FullName $Url $SourceId }
}

function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$ResolvedOutput
) {
    $output = if ([string]::IsNullOrWhiteSpace($ResolvedOutput)) { Resolve-OutputPath $RequestedPath $Here } else { $ResolvedOutput }
    Ensure-Directory $output
    Write-Host ""
    Write-Host "Destino: $output"
    $kind = Get-SiteKind $Url

    if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat $VideoContainer $false) }
    if ($kind -eq "animesdigital" -and (Test-AnimesDigitalSeasonUrl $Url)) {
        throw "AnimesDigital: esta é uma página de temporada. Use o mesmo link com --series."
    }
    if ($kind -eq "wcostream") {
        $metadata = Get-WcoMetadata $Url
        $sourceId = [string]$metadata.Id
        $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
        $fileBase = "$(Get-Date -Format 'yyyy-MM-dd') - $(Safe-Name ([string]$metadata.Title) 155)"
        return (Invoke-WcoStream $Url $output $AudioOnly $AudioFormat $VideoContainer $fileBase $identity $sourceId)
    }

    if ($Playlist) {
        $playlistTemplate = "%(playlist_title).120B\%(playlist_index)03d - %(title).150B.%(ext)s"
        return (Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $true $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $playlistTemplate)
    }

    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $naming.Identity $desiredPath $Url $naming.SourceId $false
    if ($decision.Skip) { return 0 }
    $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $naming.Template = "$($naming.FileBase).%(ext)s"

    if ($kind -eq "animesdigital") {
        $streamUrl = [string]$naming.Metadata.StreamUrl
        if ([string]::IsNullOrWhiteSpace($streamUrl)) { throw "AnimesDigital: manifesto HLS não encontrado." }
        Write-Info "AnimesDigital: stream HLS detectado; pulando yt-dlp genérico."
        return (Invoke-GenericStreamlink $streamUrl $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId 8 $Url)
    }
    if ($kind -eq "hls") {
        Write-Info "HLS direto detectado; usando download paralelo."
        return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId 8 $Url)
    }

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
    }

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $naming.Template
        if ($code -eq 0) {
            Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase)
    }

    $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $naming.Template
    if ($code -eq 0) {
        Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
}

function Read-RequiredText([string]$Prompt, [string]$DefaultValue) {
    while ($true) {
        $label = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $DefaultValue }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
}

function Read-RequiredNumber([string]$Prompt, [Nullable[int]]$DefaultValue) {
    while ($true) {
        $label = if ($null -eq $DefaultValue) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value) -and $null -ne $DefaultValue) { return [int]$DefaultValue }
        if ($value -match '^\d+$' -and [int]$value -ge 0) { return [int]$value }
        Write-Warn "Digite um número válido."
    }
}

function Resolve-SeriesInfo([object]$Metadata, [object]$State, [bool]$AutoSequence = $false) {
    $series = [string]$Metadata.Series
    $confidence = [string]$Metadata.SeriesConfidence

    if (-not [string]::IsNullOrWhiteSpace([string]$State.Name)) {
        if ([string]::IsNullOrWhiteSpace($series) -or $confidence -eq "baixa") {
            $series = [string]$State.Name
        } elseif ($series -ine [string]$State.Name) {
            Write-Warn "O link parece ser de outra série: '$series'."
            $switchSeries = Read-Host "Trocar da série '$($State.Name)' para '$series'? [s/N]"
            if (-not (Test-Yes $switchSeries $false)) { $series = [string]$State.Name }
            else { $State.Season = $null; $State.LastEpisode = $null }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($series) -and $confidence -ne "alta") {
        $answer = Read-Host "Série detectada: '$series' ($confidence confiança). Usar? [S/n]"
        if (-not (Test-Yes $answer $true)) { $series = $null }
    }

    if ([string]::IsNullOrWhiteSpace($series)) { $series = Read-RequiredText "Nome da série" ([string]$State.Name) }

    $season = $Metadata.SeasonNumber
    if ($null -eq $season) { $season = $State.Season }
    if ($null -eq $season) { $season = Read-RequiredNumber "Temporada" 1 }

    $episode = $Metadata.EpisodeNumber
    if ($null -eq $episode) {
        $next = $null
        if ($null -ne $State.LastEpisode -and $null -ne $State.Season -and [int]$State.Season -eq [int]$season) { $next = [int]$State.LastEpisode + 1 }
        if ($AutoSequence -and $null -ne $next) { $episode = [int]$next }
        else { $episode = Read-RequiredNumber "Número do episódio" $next }
    }

    $title = [string]$Metadata.Title
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "Episódio $episode" }

    $State.Name = $series
    $State.Season = [int]$season
    $State.LastEpisode = [int]$episode

    return [PSCustomObject]@{
        Series = $series; Season = [int]$season; Episode = [int]$episode; Title = $title
    }
}

function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$AutoSequence = $false
) {
    $kind = Get-SiteKind $Url

    if ($kind -notin @("pluto", "animesdigital", "hls") -and -not (Test-Dependency "yt-dlp")) { [void](Ensure-Dependency "yt-dlp" "detecção de metadados de séries") }
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State $AutoSequence

    if ($kind -eq "pluto") {
        return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $VideoContainer $true $info.Series $info.Season $info.Episode)
    }

    $sourceId = [string]$metadata.Id
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url

    $seriesFolder = Join-Path $BaseOutput (Safe-Name $info.Series 120)
    $seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f $info.Season)
    Ensure-Directory $seasonFolder
    $prefix = "S{0:D2}E{1:D2}" -f $info.Season, $info.Episode
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $seasonFolder ($fallbackBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $identity $desiredPath $Url $sourceId $false
    if ($decision.Skip) { return 0 }
    $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $template = "$fallbackBase.%(ext)s"

    if ($kind -eq "wcostream") {
        Write-Host ""
        Write-Host "Série:     $($info.Series)"
        Write-Host "Temporada: $($info.Season)"
        Write-Host "Episódio:  $($info.Episode)"
        Write-Host "Título:    $($info.Title)"
        Write-Host "Destino:   $seasonFolder"
        return (Invoke-WcoStream $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    if ($kind -eq "animesdigital") {
        Write-Host ""
        Write-Host "Série:     $($info.Series)"
        Write-Host "Temporada: $($info.Season)"
        Write-Host "Episódio:  $($info.Episode)"
        Write-Host "Título:    $($info.Title)"
        if (-not [string]::IsNullOrWhiteSpace([string]$metadata.Audio)) { Write-Host "Áudio:     $($metadata.Audio)" }
        Write-Host "Destino:   $seasonFolder"
        $streamUrl = [string]$metadata.StreamUrl
        if ([string]::IsNullOrWhiteSpace($streamUrl)) { throw "AnimesDigital: manifesto HLS não encontrado." }
        Write-Info "AnimesDigital: usando HLS com até 8 segmentos em paralelo."
        return (Invoke-GenericStreamlink $streamUrl $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId 8 $Url)
    }

    if ($kind -eq "hls") {
        Write-Host ""
        Write-Host "Série:     $($info.Series)"
        Write-Host "Temporada: $($info.Season)"
        Write-Host "Episódio:  $($info.Episode)"
        Write-Host "Título:    $($info.Title)"
        Write-Host "Destino:   $seasonFolder"
        Write-Info "HLS direto: usando até 8 segmentos em paralelo."
        return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId 8 $Url)
    }

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    Write-Host ""
    Write-Host "Série:     $($info.Series)"
    Write-Host "Temporada: $($info.Season)"
    Write-Host "Episódio:  $($info.Episode)"
    Write-Host "Título:    $($info.Title)"
    Write-Host "Destino:   $seasonFolder"

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $template
        if ($code -eq 0) {
            Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase)
    }

    $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $template
    if ($code -eq 0) {
        Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
}

function Resolve-ListUrls([object[]]$Items) {
    $values = @($Items | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }

    if ($values.Count -eq 1 -and [System.IO.Path]::GetExtension($values[0]) -ieq ".txt") {
        $listPath = Normalize-Path $values[0]
        if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { throw "Arquivo de lista não encontrado: $($values[0])" }
        $values = @(Get-Content -LiteralPath $listPath -Encoding UTF8 | ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") })
        if ($values.Count -eq 0) { throw "O arquivo de lista não contém URLs." }
    }

    return @($values)
}

function Expand-AnimesDigitalSeriesUrls([object[]]$Urls) {
    $expanded = @()
    foreach ($value in @($Urls)) {
        $url = [string]$value
        if ((Get-SiteKind $url) -eq "animesdigital" -and (Test-AnimesDigitalSeasonUrl $url)) {
            $episodes = @(Get-AnimesDigitalSeasonEpisodeUrls $url)
            Write-Info "AnimesDigital: temporada detectada com $($episodes.Count) episódio(s)."
            $expanded += $episodes
        } else {
            $expanded += $url
        }
    }
    return @($expanded)
}

function Write-BatchSummary([int]$Total, [int]$Succeeded, [int]$Failed) {
    Write-Host ""
    Write-Host "Resumo da lista:"
    Write-Host "  Total:                 $Total"
    Write-Host "  Concluídos/ignorados:  $Succeeded"
    Write-Host "  Falharam:              $Failed"
}

function Invoke-BatchSession([object]$Parsed) {
    if ($Parsed.Loop) { throw "--list e --loop não podem ser usados juntos." }
    $urls = @(Resolve-ListUrls $Parsed.ListItems)
    $resolvedOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $succeeded = 0
    $failed = 0

    Write-Info "video-dl - lista ($($urls.Count) links)"
    for ($index = 0; $index -lt $urls.Count; $index++) {
        $url = [string]$urls[$index]
        Write-Host ""
        Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
        try {
            $code = Invoke-OneDownload $url $Parsed.RequestedPath $Parsed.Here $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Playlist $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
            else { $failed++; Write-Fail "Item não concluído (código $code)." }
        } catch {
            $failed++
            Write-Fail "Item não concluído: $($_.Exception.Message)"
        }
    }

    Write-BatchSummary $urls.Count $succeeded $failed
    if ($failed -gt 0) { return 1 }
    return 0
}

function Invoke-SeriesSession([object]$Parsed) {
    if ($Parsed.Playlist) { throw "--series e --playlist representam coisas diferentes e não podem ser usados juntos." }
    if ($Parsed.Loop -and @($Parsed.ListItems).Count -gt 0) { throw "--list e --loop não podem ser usados juntos." }
    $baseOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $state = [PSCustomObject]@{ Name = $null; Season = $null; LastEpisode = $null }

    Write-Info "video-dl - modo série"
    Write-Host "Destino base: $baseOutput"
    Write-Host "O programa tenta detectar série, temporada e episódio pelos metadados."

    $batchUrls = @()
    if (@($Parsed.ListItems).Count -gt 0) {
        $batchUrls = @(Expand-AnimesDigitalSeriesUrls (Resolve-ListUrls $Parsed.ListItems))
    } elseif (
        -not [string]::IsNullOrWhiteSpace([string]$Parsed.Url) -and
        (Get-SiteKind ([string]$Parsed.Url)) -eq "animesdigital" -and
        (Test-AnimesDigitalSeasonUrl ([string]$Parsed.Url))
    ) {
        $batchUrls = @(Expand-AnimesDigitalSeriesUrls @([string]$Parsed.Url))
    }

    if ($batchUrls.Count -gt 0) {
        $urls = @($batchUrls)
        $succeeded = 0
        $failed = 0
        Write-Host "Lista: $($urls.Count) links"

        for ($index = 0; $index -lt $urls.Count; $index++) {
            $url = [string]$urls[$index]
            Write-Host ""
            Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
            try {
                $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $true
                if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
                else { $failed++; Write-Fail "Item não concluído (código $code)." }
            } catch {
                $failed++
                Write-Fail "Item não concluído: $($_.Exception.Message)"
            }
        }

        Write-BatchSummary $urls.Count $succeeded $failed
        if ($failed -gt 0) { return 1 }
        return 0
    }

    $url = [string]$Parsed.Url
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($url)) { $url = Read-Host "`nURL do próximo episódio (Enter para sair)" }
        if ([string]::IsNullOrWhiteSpace($url)) { break }
        $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $false
        if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        $url = $null
    }
    return 0
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

        $setupUrl = "https://raw.githubusercontent.com/sillasHead/video-dl/main/setup.ps1"
        $tempSetup = Join-Path $env:TEMP ("video-dl-setup-" + [Guid]::NewGuid().ToString("N") + ".ps1")
        Invoke-WebRequest -Uri $setupUrl -OutFile $tempSetup -UseBasicParsing -Headers @{ "Cache-Control" = "no-cache" }

        try {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -ne $pwsh) {
                & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            } else {
                $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
                if ($null -eq $windowsPowerShell) { throw "Nenhum PowerShell executável foi encontrado." }
                & $windowsPowerShell.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            }

            if ($exitCode -ne 0) { throw "O instalador PowerShell terminou com código $exitCode." }
        } finally {
            Remove-Item -LiteralPath $tempSetup -Force -ErrorAction SilentlyContinue
        }
        Write-Ok "Atualização concluída."
    } catch { Write-Fail "Falha ao atualizar: $($_.Exception.Message)" }
}
function Show-Help {
    @"
video-dl $Version - downloader universal

USO
  video-dl "URL"                  baixa um vídeo avulso
  video-dl --list links.txt        baixa uma lista de URLs de um arquivo TXT
  video-dl --list "URL1" "URL2"   baixa várias URLs passadas no próprio comando
  video-dl --list links.txt --series  processa a lista como episódios de uma série
  video-dl --series               modo série: cole os episódios um por um
  video-dl "URL" --series         começa a série por essa URL e pede as próximas
  video-dl                         modo interativo de vídeos avulsos

ORGANIZAÇÃO
  Avulso:  AAAA-MM-DD - Título original [1080p].ext
           usa a data original quando disponível; data atual como fallback.
  Série:   Série\Season 01\S01E01 - Título.ext
           tenta deduzir série/temporada/episódio por metadados e pelo título.
  Playlist nativa: --playlist (ex.: playlist do YouTube)

QUALIDADE / COMPATIBILIDADE
  --quality <altura>              limite de resolução (padrão: 1080)
  --max-quality                   melhor qualidade disponível, sem limite
  --wpp, -wpp, --compat           prioriza MP4 + H.264 + AAC
  fix <arquivo>                    converte vídeo existente para MP4 H.264 + AAC
  --source                        não aplica o preset de compatibilidade
  --container <mp4|mkv>           sobrescreve o container de vídeo neste download
  set-container <mp4|mkv>         muda o container padrão de vídeo

ÁUDIO
  --audio, --audio-only           baixa/extrai somente o áudio (MP3 por padrão)
  --audio-format <formato>        mp3, m4a, aac, opus, flac ou wav
  set-audio-format <formato>      muda o formato padrão de áudio

COOKIES
  --cookies <browser>             firefox, chrome, edge, brave ou auto
  --cookies-file <arquivo>        usa cookies.txt

DESTINO
  --path <nome|caminho>           escolhe destino salvo ou caminho direto
  --here                          salva na pasta atual
  --add-path <caminho>            adiciona destino
  --name <nome>                   usado junto com --add-path
  --default                       adiciona e passa a usar esse destino automaticamente
  --paths                         lista destinos
  --remove-path <nome>            remove destino
  set-default <nome>              usa esse destino automaticamente
  unset-default                   volta a perguntar quando houver mais de um destino

CONFIGURAÇÃO
  config                          abre config.json no editor (VS Code/EDITOR/Notepad)
  config show                     mostra a configuração no terminal
  config path                     mostra o caminho do arquivo
  settings                        resumo das configurações atuais
  set-quality-name <on|off>       mostra/oculta [1080p] no nome dos vídeos
  set-duplicate-policy <modo>     skip, ask, overwrite ou rename

OUTROS
  --list <arquivo.txt|URLs...>     processa várias URLs; aceita TXT ou URLs no comando
  --series                        organiza vários links como episódios de uma série
  --playlist                      baixa playlist nativa do site via yt-dlp
  --no-fallback                   não tenta downloader alternativo
  --loop                          continua pedindo links avulsos
  doctor                          verifica dependências
  install-deps                    instala dependências ausentes
  update                          atualiza pelo GitHub
  --version                       mostra a versão
  --help                          mostra esta ajuda
"@ | Write-Host
}

function Repair-WhatsAppVideo([string]$InputPath) {
    $input = Normalize-Path $InputPath
    if (-not (Test-Path -LiteralPath $input -PathType Leaf)) { throw "Arquivo não encontrado: $input" }
    if (-not (Test-Dependency "ffmpeg")) { throw "ffmpeg não encontrado. Rode: video-dl install-deps" }

    $dir = Split-Path -Parent $input
    $base = [System.IO.Path]::GetFileNameWithoutExtension($input)
    $output = Join-Path $dir ($base + " [WhatsApp].mp4")
    $n = 2
    while (Test-Path -LiteralPath $output) {
        $output = Join-Path $dir ($base + " [WhatsApp $n].mp4")
        $n++
    }

    Write-Info "Convertendo para WhatsApp: MP4 + H.264 + AAC..."
    & ffmpeg -hide_banner -y -i $input -map 0:v:0 -map '0:a:0?' -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 -movflags +faststart $output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "ffmpeg falhou ao converter o arquivo." }
    Write-Ok "Arquivo compatível criado:"
    Write-Host $output
}

function Parse-DownloadArguments([object[]]$Tokens) {
    $r = [PSCustomObject]@{
        Url = $null; ListItems = @(); RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = $null; VideoContainer = $null;
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
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
            "--container" { if (++$i -ge $Tokens.Count) { throw "--container precisa de um valor." }; $r.VideoContainer = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--quality" { if (++$i -ge $Tokens.Count) { throw "--quality precisa de um valor." }; if ([string]$Tokens[$i] -notmatch '^\d+$') { throw "--quality deve ser numérico." }; $r.Quality = [int]$Tokens[$i]; $r.MaxQuality = $false }
            "--max-quality" { $r.MaxQuality = $true; $r.Compat = $false }
            "--wpp" { $r.Compat = $true }
            "-wpp" { $r.Compat = $true }
            "--compat" { $r.Compat = $true }
            "--source" { $r.Compat = $false }
            "--cookies" { if (++$i -ge $Tokens.Count) { throw "--cookies precisa de um navegador." }; $r.CookieBrowser = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--cookies-file" { if (++$i -ge $Tokens.Count) { throw "--cookies-file precisa de um caminho." }; $r.CookieFile = Normalize-Path ([string]$Tokens[$i]) }
            "--playlist" { $r.Playlist = $true }
            "--list" {
                $listValues = @()
                while (($i + 1) -lt $Tokens.Count -and -not ([string]$Tokens[$i + 1]).StartsWith("-")) {
                    $i++
                    $listValues += [string]$Tokens[$i]
                }
                if ($listValues.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }
                $r.ListItems = @($r.ListItems) + @($listValues)
            }
            "--series" { $r.Series = $true }
            "--no-fallback" { $r.NoFallback = $true }
            "--loop" { $r.Loop = $true }
            default {
                if ($token.StartsWith("-")) { throw "Opção desconhecida: $token" }
                if ([string]::IsNullOrWhiteSpace([string]$r.Url)) { $r.Url = $token }
                else { throw "Argumento inesperado: $token" }
            }
        }
    }
    if (@($r.ListItems).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.Url)) { throw "Use uma URL posicional ou --list, não os dois ao mesmo tempo." }
    if (@($r.ListItems).Count -gt 0 -and $r.Loop) { throw "--list e --loop não podem ser usados juntos." }
    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    if ($r.VideoContainer -and $r.VideoContainer -notin @("mp4", "mkv")) { throw "--container aceita: mp4 ou mkv." }
    if ($r.AudioFormat -and $r.AudioFormat -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) { throw "--audio-format aceita: mp3, m4a, aac, opus, flac ou wav." }
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
            "fix" { if ($tokens.Count -lt 2) { throw "Uso: video-dl fix <arquivo>" }; Repair-WhatsAppVideo ([string]$tokens[1]); return }
            "paths" { Show-Paths; return }
            "--paths" { Show-Paths; return }
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
            "set-quality-name" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-quality-name <on|off>" }; Set-QualityNameCommand ([string]$tokens[1]); return }
            "set-duplicate-policy" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-duplicate-policy <skip|ask|overwrite|rename>" }; Set-DuplicatePolicyCommand ([string]$tokens[1]); return }
            "remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "--remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "--set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "unset-default" { Unset-DefaultPathCommand; return }
            "--unset-default" { Unset-DefaultPathCommand; return }
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
    $parsed = Apply-PersistentMediaSettings $parsed
    if ($parsed.Series) {
        $seriesCode = Invoke-SeriesSession $parsed
        if ($seriesCode -ne 0) { exit $seriesCode }
        return
    }

    if (@($parsed.ListItems).Count -gt 0) {
        $batchCode = Invoke-BatchSession $parsed
        if ($batchCode -ne 0) { exit $batchCode }
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$parsed.Url)) {
        Write-Info "video-dl - modo interativo"
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nCole uma URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
        return
    }

    $code = Invoke-OneDownload $parsed.Url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $null
    if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }

    if ($parsed.Loop) {
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nPróxima URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
    }
} catch {
    Write-Fail "ERRO: $($_.Exception.Message)"
    Write-Host "Use 'video-dl --help' para ver os comandos."
    exit 1
}











) { return "hls" }
    if ($urlHost -match '(^|\.)animesdigital\.org
function Get-WcoMetadata([string]$Url) {
    $info = [PSCustomObject]@{
        Title = "Vídeo"; Series = $null; SeriesConfidence = "nenhuma";
        SeasonNumber = 1; EpisodeNumber = $null; Date = (Get-Date -Format "yyyy-MM-dd"); Id = $null;
        Source = "wcostream-url"
    }
    try {
        $slug = [Uri]::UnescapeDataString(([Uri]$Url).AbsolutePath.Trim('/'))
        if ($slug -match '(?i)^(.+?)-episode-(\d+)(?:-(.*))?$') {
            $seriesSlug = $Matches[1]
            $info.EpisodeNumber = [int]$Matches[2]
            $titleSlug = [string]$Matches[3]
            $info.Series = (($seriesSlug -split '-' | Where-Object { $_ } | ForEach-Object {
                if ($_.Length -gt 1) { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) } else { $_.ToUpperInvariant() }
            }) -join ' ')
            $info.SeriesConfidence = "média"
            if (-not [string]::IsNullOrWhiteSpace($titleSlug)) {
                $info.Title = (($titleSlug -split '-' | Where-Object { $_ }) -join ' ')
            } else { $info.Title = "Episódio $($info.EpisodeNumber)" }
            $info.Id = $slug
        }
    } catch { }
    return $info
}

function Invoke-WcoStream(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [string]$FileBase, [string]$Identity, [string]$SourceId
) {
    if ($AudioOnly) { Write-Warn "WCOStream: --audio ainda não é suportado."; return 1 }
    if (-not (Test-Path -LiteralPath $WcoDlPath -PathType Leaf)) { throw "wcostream-dl.ps1 não encontrado." }
    $desired = Join-Path $OutputDir ($FileBase + ".mp4")
    $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
    if ($decision.Skip) { return 0 }
    $target = [string]$decision.Path
    & $WcoDlPath -Url $Url -OutputPath $target
    if (-not $?) { return 1 }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $final = Add-QualitySuffix $target
        Register-VideoDlDownload $Identity $final $Url $SourceId
        return 0
    }
    return 1
}

function Get-AvulsoNaming([string]$Url, [string]$CookieBrowser, [string]$CookieFile) {
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $false
    $date = if ($null -ne $metadata) { [string]$metadata.Date } else { Get-Date -Format "yyyy-MM-dd" }
    $title = if ($null -ne $metadata) { [string]$metadata.Title } else { "Vídeo" }
    $sourceId = if ($null -ne $metadata) { [string]$metadata.Id } else { $null }
    $fileBase = "$date - $(Safe-Name $title 155)"
    $template = "$fileBase.%(ext)s"
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
    return [PSCustomObject]@{
        Metadata = $metadata
        FileBase = $fileBase
        Template = $template
        Identity = $identity
        SourceId = $sourceId
    }
}

function Register-YtDlpResult([string]$Identity, [string]$Url, [string]$SourceId, [string]$OutputDir, [string]$FileBase) {
    $result = Find-VideoDlOutputForBase $OutputDir $FileBase
    if ($null -ne $result) { Register-VideoDlDownload $Identity $result.FullName $Url $SourceId }
}

function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$ResolvedOutput
) {
    $output = if ([string]::IsNullOrWhiteSpace($ResolvedOutput)) { Resolve-OutputPath $RequestedPath $Here } else { $ResolvedOutput }
    Ensure-Directory $output
    Write-Host ""
    Write-Host "Destino: $output"
    $kind = Get-SiteKind $Url

    if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat $VideoContainer $false) }
    if ($kind -eq "wcostream") {
        $metadata = Get-WcoMetadata $Url
        $sourceId = [string]$metadata.Id
        $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
        $fileBase = "$(Get-Date -Format 'yyyy-MM-dd') - $(Safe-Name ([string]$metadata.Title) 155)"
        return (Invoke-WcoStream $Url $output $AudioOnly $AudioFormat $VideoContainer $fileBase $identity $sourceId)
    }

    if ($Playlist) {
        $playlistTemplate = "%(playlist_title).120B\%(playlist_index)03d - %(title).150B.%(ext)s"
        return (Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $true $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $playlistTemplate)
    }

    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $naming.Identity $desiredPath $Url $naming.SourceId $false
    if ($decision.Skip) { return 0 }
    $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $naming.Template = "$($naming.FileBase).%(ext)s"

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
    }

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $naming.Template
        if ($code -eq 0) {
            Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase)
    }

    $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $naming.Template
    if ($code -eq 0) {
        Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
}

function Read-RequiredText([string]$Prompt, [string]$DefaultValue) {
    while ($true) {
        $label = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $DefaultValue }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
}

function Read-RequiredNumber([string]$Prompt, [Nullable[int]]$DefaultValue) {
    while ($true) {
        $label = if ($null -eq $DefaultValue) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value) -and $null -ne $DefaultValue) { return [int]$DefaultValue }
        if ($value -match '^\d+$' -and [int]$value -ge 0) { return [int]$value }
        Write-Warn "Digite um número válido."
    }
}

function Resolve-SeriesInfo([object]$Metadata, [object]$State, [bool]$AutoSequence = $false) {
    $series = [string]$Metadata.Series
    $confidence = [string]$Metadata.SeriesConfidence

    if (-not [string]::IsNullOrWhiteSpace([string]$State.Name)) {
        if ([string]::IsNullOrWhiteSpace($series) -or $confidence -eq "baixa") {
            $series = [string]$State.Name
        } elseif ($series -ine [string]$State.Name) {
            Write-Warn "O link parece ser de outra série: '$series'."
            $switchSeries = Read-Host "Trocar da série '$($State.Name)' para '$series'? [s/N]"
            if (-not (Test-Yes $switchSeries $false)) { $series = [string]$State.Name }
            else { $State.Season = $null; $State.LastEpisode = $null }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($series) -and $confidence -ne "alta") {
        $answer = Read-Host "Série detectada: '$series' ($confidence confiança). Usar? [S/n]"
        if (-not (Test-Yes $answer $true)) { $series = $null }
    }

    if ([string]::IsNullOrWhiteSpace($series)) { $series = Read-RequiredText "Nome da série" ([string]$State.Name) }

    $season = $Metadata.SeasonNumber
    if ($null -eq $season) { $season = $State.Season }
    if ($null -eq $season) { $season = Read-RequiredNumber "Temporada" 1 }

    $episode = $Metadata.EpisodeNumber
    if ($null -eq $episode) {
        $next = $null
        if ($null -ne $State.LastEpisode -and $null -ne $State.Season -and [int]$State.Season -eq [int]$season) { $next = [int]$State.LastEpisode + 1 }
        if ($AutoSequence -and $null -ne $next) { $episode = [int]$next }
        else { $episode = Read-RequiredNumber "Número do episódio" $next }
    }

    $title = [string]$Metadata.Title
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "Episódio $episode" }

    $State.Name = $series
    $State.Season = [int]$season
    $State.LastEpisode = [int]$episode

    return [PSCustomObject]@{
        Series = $series; Season = [int]$season; Episode = [int]$episode; Title = $title
    }
}

function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$AutoSequence = $false
) {
    $kind = Get-SiteKind $Url

    if ($kind -ne "pluto" -and -not (Test-Dependency "yt-dlp")) { [void](Ensure-Dependency "yt-dlp" "detecção de metadados de séries") }
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State $AutoSequence

    if ($kind -eq "pluto") {
        return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $VideoContainer $true $info.Series $info.Season $info.Episode)
    }

    $sourceId = [string]$metadata.Id
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url

    $seriesFolder = Join-Path $BaseOutput (Safe-Name $info.Series 120)
    $seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f $info.Season)
    Ensure-Directory $seasonFolder
    $prefix = "S{0:D2}E{1:D2}" -f $info.Season, $info.Episode
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $seasonFolder ($fallbackBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $identity $desiredPath $Url $sourceId $false
    if ($decision.Skip) { return 0 }
    $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $template = "$fallbackBase.%(ext)s"

    if ($kind -eq "wcostream") {
        Write-Host ""
        Write-Host "Série:     $($info.Series)"
        Write-Host "Temporada: $($info.Season)"
        Write-Host "Episódio:  $($info.Episode)"
        Write-Host "Título:    $($info.Title)"
        Write-Host "Destino:   $seasonFolder"
        return (Invoke-WcoStream $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    Write-Host ""
    Write-Host "Série:     $($info.Series)"
    Write-Host "Temporada: $($info.Season)"
    Write-Host "Episódio:  $($info.Episode)"
    Write-Host "Título:    $($info.Title)"
    Write-Host "Destino:   $seasonFolder"

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $template
        if ($code -eq 0) {
            Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase)
    }

    $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $template
    if ($code -eq 0) {
        Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
}

function Resolve-ListUrls([object[]]$Items) {
    $values = @($Items | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }

    if ($values.Count -eq 1 -and [System.IO.Path]::GetExtension($values[0]) -ieq ".txt") {
        $listPath = Normalize-Path $values[0]
        if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { throw "Arquivo de lista não encontrado: $($values[0])" }
        $values = @(Get-Content -LiteralPath $listPath -Encoding UTF8 | ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") })
        if ($values.Count -eq 0) { throw "O arquivo de lista não contém URLs." }
    }

    return @($values)
}

function Write-BatchSummary([int]$Total, [int]$Succeeded, [int]$Failed) {
    Write-Host ""
    Write-Host "Resumo da lista:"
    Write-Host "  Total:                 $Total"
    Write-Host "  Concluídos/ignorados:  $Succeeded"
    Write-Host "  Falharam:              $Failed"
}

function Invoke-BatchSession([object]$Parsed) {
    if ($Parsed.Loop) { throw "--list e --loop não podem ser usados juntos." }
    $urls = @(Resolve-ListUrls $Parsed.ListItems)
    $resolvedOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $succeeded = 0
    $failed = 0

    Write-Info "video-dl - lista ($($urls.Count) links)"
    for ($index = 0; $index -lt $urls.Count; $index++) {
        $url = [string]$urls[$index]
        Write-Host ""
        Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
        try {
            $code = Invoke-OneDownload $url $Parsed.RequestedPath $Parsed.Here $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Playlist $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
            else { $failed++; Write-Fail "Item não concluído (código $code)." }
        } catch {
            $failed++
            Write-Fail "Item não concluído: $($_.Exception.Message)"
        }
    }

    Write-BatchSummary $urls.Count $succeeded $failed
    if ($failed -gt 0) { return 1 }
    return 0
}

function Invoke-SeriesSession([object]$Parsed) {
    if ($Parsed.Playlist) { throw "--series e --playlist representam coisas diferentes e não podem ser usados juntos." }
    if ($Parsed.Loop -and @($Parsed.ListItems).Count -gt 0) { throw "--list e --loop não podem ser usados juntos." }
    $baseOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $state = [PSCustomObject]@{ Name = $null; Season = $null; LastEpisode = $null }

    Write-Info "video-dl - modo série"
    Write-Host "Destino base: $baseOutput"
    Write-Host "O programa tenta detectar série, temporada e episódio pelos metadados."

    if (@($Parsed.ListItems).Count -gt 0) {
        $urls = @(Resolve-ListUrls $Parsed.ListItems)
        $succeeded = 0
        $failed = 0
        Write-Host "Lista: $($urls.Count) links"

        for ($index = 0; $index -lt $urls.Count; $index++) {
            $url = [string]$urls[$index]
            Write-Host ""
            Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
            try {
                $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $true
                if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
                else { $failed++; Write-Fail "Item não concluído (código $code)." }
            } catch {
                $failed++
                Write-Fail "Item não concluído: $($_.Exception.Message)"
            }
        }

        Write-BatchSummary $urls.Count $succeeded $failed
        if ($failed -gt 0) { return 1 }
        return 0
    }

    $url = [string]$Parsed.Url
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($url)) { $url = Read-Host "`nURL do próximo episódio (Enter para sair)" }
        if ([string]::IsNullOrWhiteSpace($url)) { break }
        $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $false
        if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        $url = $null
    }
    return 0
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

        $setupUrl = "https://raw.githubusercontent.com/sillasHead/video-dl/main/setup.ps1"
        $tempSetup = Join-Path $env:TEMP ("video-dl-setup-" + [Guid]::NewGuid().ToString("N") + ".ps1")
        Invoke-WebRequest -Uri $setupUrl -OutFile $tempSetup -UseBasicParsing -Headers @{ "Cache-Control" = "no-cache" }

        try {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -ne $pwsh) {
                & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            } else {
                $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
                if ($null -eq $windowsPowerShell) { throw "Nenhum PowerShell executável foi encontrado." }
                & $windowsPowerShell.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            }

            if ($exitCode -ne 0) { throw "O instalador PowerShell terminou com código $exitCode." }
        } finally {
            Remove-Item -LiteralPath $tempSetup -Force -ErrorAction SilentlyContinue
        }
        Write-Ok "Atualização concluída."
    } catch { Write-Fail "Falha ao atualizar: $($_.Exception.Message)" }
}
function Show-Help {
    @"
video-dl $Version - downloader universal

USO
  video-dl "URL"                  baixa um vídeo avulso
  video-dl --list links.txt        baixa uma lista de URLs de um arquivo TXT
  video-dl --list "URL1" "URL2"   baixa várias URLs passadas no próprio comando
  video-dl --list links.txt --series  processa a lista como episódios de uma série
  video-dl --series               modo série: cole os episódios um por um
  video-dl "URL" --series         começa a série por essa URL e pede as próximas
  video-dl                         modo interativo de vídeos avulsos

ORGANIZAÇÃO
  Avulso:  AAAA-MM-DD - Título original [1080p].ext
           usa a data original quando disponível; data atual como fallback.
  Série:   Série\Season 01\S01E01 - Título.ext
           tenta deduzir série/temporada/episódio por metadados e pelo título.
  Playlist nativa: --playlist (ex.: playlist do YouTube)

QUALIDADE / COMPATIBILIDADE
  --quality <altura>              limite de resolução (padrão: 1080)
  --max-quality                   melhor qualidade disponível, sem limite
  --wpp, -wpp, --compat           prioriza MP4 + H.264 + AAC
  fix <arquivo>                    converte vídeo existente para MP4 H.264 + AAC
  --source                        não aplica o preset de compatibilidade
  --container <mp4|mkv>           sobrescreve o container de vídeo neste download
  set-container <mp4|mkv>         muda o container padrão de vídeo

ÁUDIO
  --audio, --audio-only           baixa/extrai somente o áudio (MP3 por padrão)
  --audio-format <formato>        mp3, m4a, aac, opus, flac ou wav
  set-audio-format <formato>      muda o formato padrão de áudio

COOKIES
  --cookies <browser>             firefox, chrome, edge, brave ou auto
  --cookies-file <arquivo>        usa cookies.txt

DESTINO
  --path <nome|caminho>           escolhe destino salvo ou caminho direto
  --here                          salva na pasta atual
  --add-path <caminho>            adiciona destino
  --name <nome>                   usado junto com --add-path
  --default                       adiciona e passa a usar esse destino automaticamente
  --paths                         lista destinos
  --remove-path <nome>            remove destino
  set-default <nome>              usa esse destino automaticamente
  unset-default                   volta a perguntar quando houver mais de um destino

CONFIGURAÇÃO
  config                          abre config.json no editor (VS Code/EDITOR/Notepad)
  config show                     mostra a configuração no terminal
  config path                     mostra o caminho do arquivo
  settings                        resumo das configurações atuais
  set-quality-name <on|off>       mostra/oculta [1080p] no nome dos vídeos
  set-duplicate-policy <modo>     skip, ask, overwrite ou rename

OUTROS
  --list <arquivo.txt|URLs...>     processa várias URLs; aceita TXT ou URLs no comando
  --series                        organiza vários links como episódios de uma série
  --playlist                      baixa playlist nativa do site via yt-dlp
  --no-fallback                   não tenta downloader alternativo
  --loop                          continua pedindo links avulsos
  doctor                          verifica dependências
  install-deps                    instala dependências ausentes
  update                          atualiza pelo GitHub
  --version                       mostra a versão
  --help                          mostra esta ajuda
"@ | Write-Host
}

function Repair-WhatsAppVideo([string]$InputPath) {
    $input = Normalize-Path $InputPath
    if (-not (Test-Path -LiteralPath $input -PathType Leaf)) { throw "Arquivo não encontrado: $input" }
    if (-not (Test-Dependency "ffmpeg")) { throw "ffmpeg não encontrado. Rode: video-dl install-deps" }

    $dir = Split-Path -Parent $input
    $base = [System.IO.Path]::GetFileNameWithoutExtension($input)
    $output = Join-Path $dir ($base + " [WhatsApp].mp4")
    $n = 2
    while (Test-Path -LiteralPath $output) {
        $output = Join-Path $dir ($base + " [WhatsApp $n].mp4")
        $n++
    }

    Write-Info "Convertendo para WhatsApp: MP4 + H.264 + AAC..."
    & ffmpeg -hide_banner -y -i $input -map 0:v:0 -map '0:a:0?' -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 -movflags +faststart $output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "ffmpeg falhou ao converter o arquivo." }
    Write-Ok "Arquivo compatível criado:"
    Write-Host $output
}

function Parse-DownloadArguments([object[]]$Tokens) {
    $r = [PSCustomObject]@{
        Url = $null; ListItems = @(); RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = $null; VideoContainer = $null;
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
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
            "--container" { if (++$i -ge $Tokens.Count) { throw "--container precisa de um valor." }; $r.VideoContainer = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--quality" { if (++$i -ge $Tokens.Count) { throw "--quality precisa de um valor." }; if ([string]$Tokens[$i] -notmatch '^\d+$') { throw "--quality deve ser numérico." }; $r.Quality = [int]$Tokens[$i]; $r.MaxQuality = $false }
            "--max-quality" { $r.MaxQuality = $true; $r.Compat = $false }
            "--wpp" { $r.Compat = $true }
            "-wpp" { $r.Compat = $true }
            "--compat" { $r.Compat = $true }
            "--source" { $r.Compat = $false }
            "--cookies" { if (++$i -ge $Tokens.Count) { throw "--cookies precisa de um navegador." }; $r.CookieBrowser = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--cookies-file" { if (++$i -ge $Tokens.Count) { throw "--cookies-file precisa de um caminho." }; $r.CookieFile = Normalize-Path ([string]$Tokens[$i]) }
            "--playlist" { $r.Playlist = $true }
            "--list" {
                $listValues = @()
                while (($i + 1) -lt $Tokens.Count -and -not ([string]$Tokens[$i + 1]).StartsWith("-")) {
                    $i++
                    $listValues += [string]$Tokens[$i]
                }
                if ($listValues.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }
                $r.ListItems = @($r.ListItems) + @($listValues)
            }
            "--series" { $r.Series = $true }
            "--no-fallback" { $r.NoFallback = $true }
            "--loop" { $r.Loop = $true }
            default {
                if ($token.StartsWith("-")) { throw "Opção desconhecida: $token" }
                if ([string]::IsNullOrWhiteSpace([string]$r.Url)) { $r.Url = $token }
                else { throw "Argumento inesperado: $token" }
            }
        }
    }
    if (@($r.ListItems).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.Url)) { throw "Use uma URL posicional ou --list, não os dois ao mesmo tempo." }
    if (@($r.ListItems).Count -gt 0 -and $r.Loop) { throw "--list e --loop não podem ser usados juntos." }
    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    if ($r.VideoContainer -and $r.VideoContainer -notin @("mp4", "mkv")) { throw "--container aceita: mp4 ou mkv." }
    if ($r.AudioFormat -and $r.AudioFormat -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) { throw "--audio-format aceita: mp3, m4a, aac, opus, flac ou wav." }
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
            "fix" { if ($tokens.Count -lt 2) { throw "Uso: video-dl fix <arquivo>" }; Repair-WhatsAppVideo ([string]$tokens[1]); return }
            "paths" { Show-Paths; return }
            "--paths" { Show-Paths; return }
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
            "set-quality-name" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-quality-name <on|off>" }; Set-QualityNameCommand ([string]$tokens[1]); return }
            "set-duplicate-policy" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-duplicate-policy <skip|ask|overwrite|rename>" }; Set-DuplicatePolicyCommand ([string]$tokens[1]); return }
            "remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "--remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "--set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "unset-default" { Unset-DefaultPathCommand; return }
            "--unset-default" { Unset-DefaultPathCommand; return }
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
    $parsed = Apply-PersistentMediaSettings $parsed
    if ($parsed.Series) {
        $seriesCode = Invoke-SeriesSession $parsed
        if ($seriesCode -ne 0) { exit $seriesCode }
        return
    }

    if (@($parsed.ListItems).Count -gt 0) {
        $batchCode = Invoke-BatchSession $parsed
        if ($batchCode -ne 0) { exit $batchCode }
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$parsed.Url)) {
        Write-Info "video-dl - modo interativo"
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nCole uma URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
        return
    }

    $code = Invoke-OneDownload $parsed.Url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $null
    if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }

    if ($parsed.Loop) {
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nPróxima URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
    }
} catch {
    Write-Fail "ERRO: $($_.Exception.Message)"
    Write-Host "Use 'video-dl --help' para ver os comandos."
    exit 1
}











) { return "animesdigital" }
    if ($urlHost -match '(^|\.)pluto\.tv
function Get-WcoMetadata([string]$Url) {
    $info = [PSCustomObject]@{
        Title = "Vídeo"; Series = $null; SeriesConfidence = "nenhuma";
        SeasonNumber = 1; EpisodeNumber = $null; Date = (Get-Date -Format "yyyy-MM-dd"); Id = $null;
        Source = "wcostream-url"
    }
    try {
        $slug = [Uri]::UnescapeDataString(([Uri]$Url).AbsolutePath.Trim('/'))
        if ($slug -match '(?i)^(.+?)-episode-(\d+)(?:-(.*))?$') {
            $seriesSlug = $Matches[1]
            $info.EpisodeNumber = [int]$Matches[2]
            $titleSlug = [string]$Matches[3]
            $info.Series = (($seriesSlug -split '-' | Where-Object { $_ } | ForEach-Object {
                if ($_.Length -gt 1) { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) } else { $_.ToUpperInvariant() }
            }) -join ' ')
            $info.SeriesConfidence = "média"
            if (-not [string]::IsNullOrWhiteSpace($titleSlug)) {
                $info.Title = (($titleSlug -split '-' | Where-Object { $_ }) -join ' ')
            } else { $info.Title = "Episódio $($info.EpisodeNumber)" }
            $info.Id = $slug
        }
    } catch { }
    return $info
}

function Invoke-WcoStream(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [string]$FileBase, [string]$Identity, [string]$SourceId
) {
    if ($AudioOnly) { Write-Warn "WCOStream: --audio ainda não é suportado."; return 1 }
    if (-not (Test-Path -LiteralPath $WcoDlPath -PathType Leaf)) { throw "wcostream-dl.ps1 não encontrado." }
    $desired = Join-Path $OutputDir ($FileBase + ".mp4")
    $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
    if ($decision.Skip) { return 0 }
    $target = [string]$decision.Path
    & $WcoDlPath -Url $Url -OutputPath $target
    if (-not $?) { return 1 }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $final = Add-QualitySuffix $target
        Register-VideoDlDownload $Identity $final $Url $SourceId
        return 0
    }
    return 1
}

function Get-AvulsoNaming([string]$Url, [string]$CookieBrowser, [string]$CookieFile) {
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $false
    $date = if ($null -ne $metadata) { [string]$metadata.Date } else { Get-Date -Format "yyyy-MM-dd" }
    $title = if ($null -ne $metadata) { [string]$metadata.Title } else { "Vídeo" }
    $sourceId = if ($null -ne $metadata) { [string]$metadata.Id } else { $null }
    $fileBase = "$date - $(Safe-Name $title 155)"
    $template = "$fileBase.%(ext)s"
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
    return [PSCustomObject]@{
        Metadata = $metadata
        FileBase = $fileBase
        Template = $template
        Identity = $identity
        SourceId = $sourceId
    }
}

function Register-YtDlpResult([string]$Identity, [string]$Url, [string]$SourceId, [string]$OutputDir, [string]$FileBase) {
    $result = Find-VideoDlOutputForBase $OutputDir $FileBase
    if ($null -ne $result) { Register-VideoDlDownload $Identity $result.FullName $Url $SourceId }
}

function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$ResolvedOutput
) {
    $output = if ([string]::IsNullOrWhiteSpace($ResolvedOutput)) { Resolve-OutputPath $RequestedPath $Here } else { $ResolvedOutput }
    Ensure-Directory $output
    Write-Host ""
    Write-Host "Destino: $output"
    $kind = Get-SiteKind $Url

    if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat $VideoContainer $false) }
    if ($kind -eq "wcostream") {
        $metadata = Get-WcoMetadata $Url
        $sourceId = [string]$metadata.Id
        $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
        $fileBase = "$(Get-Date -Format 'yyyy-MM-dd') - $(Safe-Name ([string]$metadata.Title) 155)"
        return (Invoke-WcoStream $Url $output $AudioOnly $AudioFormat $VideoContainer $fileBase $identity $sourceId)
    }

    if ($Playlist) {
        $playlistTemplate = "%(playlist_title).120B\%(playlist_index)03d - %(title).150B.%(ext)s"
        return (Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $true $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $playlistTemplate)
    }

    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $naming.Identity $desiredPath $Url $naming.SourceId $false
    if ($decision.Skip) { return 0 }
    $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $naming.Template = "$($naming.FileBase).%(ext)s"

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
    }

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $naming.Template
        if ($code -eq 0) {
            Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase)
    }

    $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $naming.Template
    if ($code -eq 0) {
        Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
}

function Read-RequiredText([string]$Prompt, [string]$DefaultValue) {
    while ($true) {
        $label = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $DefaultValue }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
}

function Read-RequiredNumber([string]$Prompt, [Nullable[int]]$DefaultValue) {
    while ($true) {
        $label = if ($null -eq $DefaultValue) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value) -and $null -ne $DefaultValue) { return [int]$DefaultValue }
        if ($value -match '^\d+$' -and [int]$value -ge 0) { return [int]$value }
        Write-Warn "Digite um número válido."
    }
}

function Resolve-SeriesInfo([object]$Metadata, [object]$State, [bool]$AutoSequence = $false) {
    $series = [string]$Metadata.Series
    $confidence = [string]$Metadata.SeriesConfidence

    if (-not [string]::IsNullOrWhiteSpace([string]$State.Name)) {
        if ([string]::IsNullOrWhiteSpace($series) -or $confidence -eq "baixa") {
            $series = [string]$State.Name
        } elseif ($series -ine [string]$State.Name) {
            Write-Warn "O link parece ser de outra série: '$series'."
            $switchSeries = Read-Host "Trocar da série '$($State.Name)' para '$series'? [s/N]"
            if (-not (Test-Yes $switchSeries $false)) { $series = [string]$State.Name }
            else { $State.Season = $null; $State.LastEpisode = $null }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($series) -and $confidence -ne "alta") {
        $answer = Read-Host "Série detectada: '$series' ($confidence confiança). Usar? [S/n]"
        if (-not (Test-Yes $answer $true)) { $series = $null }
    }

    if ([string]::IsNullOrWhiteSpace($series)) { $series = Read-RequiredText "Nome da série" ([string]$State.Name) }

    $season = $Metadata.SeasonNumber
    if ($null -eq $season) { $season = $State.Season }
    if ($null -eq $season) { $season = Read-RequiredNumber "Temporada" 1 }

    $episode = $Metadata.EpisodeNumber
    if ($null -eq $episode) {
        $next = $null
        if ($null -ne $State.LastEpisode -and $null -ne $State.Season -and [int]$State.Season -eq [int]$season) { $next = [int]$State.LastEpisode + 1 }
        if ($AutoSequence -and $null -ne $next) { $episode = [int]$next }
        else { $episode = Read-RequiredNumber "Número do episódio" $next }
    }

    $title = [string]$Metadata.Title
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "Episódio $episode" }

    $State.Name = $series
    $State.Season = [int]$season
    $State.LastEpisode = [int]$episode

    return [PSCustomObject]@{
        Series = $series; Season = [int]$season; Episode = [int]$episode; Title = $title
    }
}

function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$AutoSequence = $false
) {
    $kind = Get-SiteKind $Url

    if ($kind -ne "pluto" -and -not (Test-Dependency "yt-dlp")) { [void](Ensure-Dependency "yt-dlp" "detecção de metadados de séries") }
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State $AutoSequence

    if ($kind -eq "pluto") {
        return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $VideoContainer $true $info.Series $info.Season $info.Episode)
    }

    $sourceId = [string]$metadata.Id
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url

    $seriesFolder = Join-Path $BaseOutput (Safe-Name $info.Series 120)
    $seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f $info.Season)
    Ensure-Directory $seasonFolder
    $prefix = "S{0:D2}E{1:D2}" -f $info.Season, $info.Episode
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $seasonFolder ($fallbackBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $identity $desiredPath $Url $sourceId $false
    if ($decision.Skip) { return 0 }
    $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $template = "$fallbackBase.%(ext)s"

    if ($kind -eq "wcostream") {
        Write-Host ""
        Write-Host "Série:     $($info.Series)"
        Write-Host "Temporada: $($info.Season)"
        Write-Host "Episódio:  $($info.Episode)"
        Write-Host "Título:    $($info.Title)"
        Write-Host "Destino:   $seasonFolder"
        return (Invoke-WcoStream $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    Write-Host ""
    Write-Host "Série:     $($info.Series)"
    Write-Host "Temporada: $($info.Season)"
    Write-Host "Episódio:  $($info.Episode)"
    Write-Host "Título:    $($info.Title)"
    Write-Host "Destino:   $seasonFolder"

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $template
        if ($code -eq 0) {
            Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase)
    }

    $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $template
    if ($code -eq 0) {
        Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
}

function Resolve-ListUrls([object[]]$Items) {
    $values = @($Items | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }

    if ($values.Count -eq 1 -and [System.IO.Path]::GetExtension($values[0]) -ieq ".txt") {
        $listPath = Normalize-Path $values[0]
        if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { throw "Arquivo de lista não encontrado: $($values[0])" }
        $values = @(Get-Content -LiteralPath $listPath -Encoding UTF8 | ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") })
        if ($values.Count -eq 0) { throw "O arquivo de lista não contém URLs." }
    }

    return @($values)
}

function Write-BatchSummary([int]$Total, [int]$Succeeded, [int]$Failed) {
    Write-Host ""
    Write-Host "Resumo da lista:"
    Write-Host "  Total:                 $Total"
    Write-Host "  Concluídos/ignorados:  $Succeeded"
    Write-Host "  Falharam:              $Failed"
}

function Invoke-BatchSession([object]$Parsed) {
    if ($Parsed.Loop) { throw "--list e --loop não podem ser usados juntos." }
    $urls = @(Resolve-ListUrls $Parsed.ListItems)
    $resolvedOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $succeeded = 0
    $failed = 0

    Write-Info "video-dl - lista ($($urls.Count) links)"
    for ($index = 0; $index -lt $urls.Count; $index++) {
        $url = [string]$urls[$index]
        Write-Host ""
        Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
        try {
            $code = Invoke-OneDownload $url $Parsed.RequestedPath $Parsed.Here $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Playlist $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
            else { $failed++; Write-Fail "Item não concluído (código $code)." }
        } catch {
            $failed++
            Write-Fail "Item não concluído: $($_.Exception.Message)"
        }
    }

    Write-BatchSummary $urls.Count $succeeded $failed
    if ($failed -gt 0) { return 1 }
    return 0
}

function Invoke-SeriesSession([object]$Parsed) {
    if ($Parsed.Playlist) { throw "--series e --playlist representam coisas diferentes e não podem ser usados juntos." }
    if ($Parsed.Loop -and @($Parsed.ListItems).Count -gt 0) { throw "--list e --loop não podem ser usados juntos." }
    $baseOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $state = [PSCustomObject]@{ Name = $null; Season = $null; LastEpisode = $null }

    Write-Info "video-dl - modo série"
    Write-Host "Destino base: $baseOutput"
    Write-Host "O programa tenta detectar série, temporada e episódio pelos metadados."

    if (@($Parsed.ListItems).Count -gt 0) {
        $urls = @(Resolve-ListUrls $Parsed.ListItems)
        $succeeded = 0
        $failed = 0
        Write-Host "Lista: $($urls.Count) links"

        for ($index = 0; $index -lt $urls.Count; $index++) {
            $url = [string]$urls[$index]
            Write-Host ""
            Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
            try {
                $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $true
                if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
                else { $failed++; Write-Fail "Item não concluído (código $code)." }
            } catch {
                $failed++
                Write-Fail "Item não concluído: $($_.Exception.Message)"
            }
        }

        Write-BatchSummary $urls.Count $succeeded $failed
        if ($failed -gt 0) { return 1 }
        return 0
    }

    $url = [string]$Parsed.Url
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($url)) { $url = Read-Host "`nURL do próximo episódio (Enter para sair)" }
        if ([string]::IsNullOrWhiteSpace($url)) { break }
        $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $false
        if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        $url = $null
    }
    return 0
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

        $setupUrl = "https://raw.githubusercontent.com/sillasHead/video-dl/main/setup.ps1"
        $tempSetup = Join-Path $env:TEMP ("video-dl-setup-" + [Guid]::NewGuid().ToString("N") + ".ps1")
        Invoke-WebRequest -Uri $setupUrl -OutFile $tempSetup -UseBasicParsing -Headers @{ "Cache-Control" = "no-cache" }

        try {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -ne $pwsh) {
                & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            } else {
                $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
                if ($null -eq $windowsPowerShell) { throw "Nenhum PowerShell executável foi encontrado." }
                & $windowsPowerShell.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            }

            if ($exitCode -ne 0) { throw "O instalador PowerShell terminou com código $exitCode." }
        } finally {
            Remove-Item -LiteralPath $tempSetup -Force -ErrorAction SilentlyContinue
        }
        Write-Ok "Atualização concluída."
    } catch { Write-Fail "Falha ao atualizar: $($_.Exception.Message)" }
}
function Show-Help {
    @"
video-dl $Version - downloader universal

USO
  video-dl "URL"                  baixa um vídeo avulso
  video-dl --list links.txt        baixa uma lista de URLs de um arquivo TXT
  video-dl --list "URL1" "URL2"   baixa várias URLs passadas no próprio comando
  video-dl --list links.txt --series  processa a lista como episódios de uma série
  video-dl --series               modo série: cole os episódios um por um
  video-dl "URL" --series         começa a série por essa URL e pede as próximas
  video-dl                         modo interativo de vídeos avulsos

ORGANIZAÇÃO
  Avulso:  AAAA-MM-DD - Título original [1080p].ext
           usa a data original quando disponível; data atual como fallback.
  Série:   Série\Season 01\S01E01 - Título.ext
           tenta deduzir série/temporada/episódio por metadados e pelo título.
  Playlist nativa: --playlist (ex.: playlist do YouTube)

QUALIDADE / COMPATIBILIDADE
  --quality <altura>              limite de resolução (padrão: 1080)
  --max-quality                   melhor qualidade disponível, sem limite
  --wpp, -wpp, --compat           prioriza MP4 + H.264 + AAC
  fix <arquivo>                    converte vídeo existente para MP4 H.264 + AAC
  --source                        não aplica o preset de compatibilidade
  --container <mp4|mkv>           sobrescreve o container de vídeo neste download
  set-container <mp4|mkv>         muda o container padrão de vídeo

ÁUDIO
  --audio, --audio-only           baixa/extrai somente o áudio (MP3 por padrão)
  --audio-format <formato>        mp3, m4a, aac, opus, flac ou wav
  set-audio-format <formato>      muda o formato padrão de áudio

COOKIES
  --cookies <browser>             firefox, chrome, edge, brave ou auto
  --cookies-file <arquivo>        usa cookies.txt

DESTINO
  --path <nome|caminho>           escolhe destino salvo ou caminho direto
  --here                          salva na pasta atual
  --add-path <caminho>            adiciona destino
  --name <nome>                   usado junto com --add-path
  --default                       adiciona e passa a usar esse destino automaticamente
  --paths                         lista destinos
  --remove-path <nome>            remove destino
  set-default <nome>              usa esse destino automaticamente
  unset-default                   volta a perguntar quando houver mais de um destino

CONFIGURAÇÃO
  config                          abre config.json no editor (VS Code/EDITOR/Notepad)
  config show                     mostra a configuração no terminal
  config path                     mostra o caminho do arquivo
  settings                        resumo das configurações atuais
  set-quality-name <on|off>       mostra/oculta [1080p] no nome dos vídeos
  set-duplicate-policy <modo>     skip, ask, overwrite ou rename

OUTROS
  --list <arquivo.txt|URLs...>     processa várias URLs; aceita TXT ou URLs no comando
  --series                        organiza vários links como episódios de uma série
  --playlist                      baixa playlist nativa do site via yt-dlp
  --no-fallback                   não tenta downloader alternativo
  --loop                          continua pedindo links avulsos
  doctor                          verifica dependências
  install-deps                    instala dependências ausentes
  update                          atualiza pelo GitHub
  --version                       mostra a versão
  --help                          mostra esta ajuda
"@ | Write-Host
}

function Repair-WhatsAppVideo([string]$InputPath) {
    $input = Normalize-Path $InputPath
    if (-not (Test-Path -LiteralPath $input -PathType Leaf)) { throw "Arquivo não encontrado: $input" }
    if (-not (Test-Dependency "ffmpeg")) { throw "ffmpeg não encontrado. Rode: video-dl install-deps" }

    $dir = Split-Path -Parent $input
    $base = [System.IO.Path]::GetFileNameWithoutExtension($input)
    $output = Join-Path $dir ($base + " [WhatsApp].mp4")
    $n = 2
    while (Test-Path -LiteralPath $output) {
        $output = Join-Path $dir ($base + " [WhatsApp $n].mp4")
        $n++
    }

    Write-Info "Convertendo para WhatsApp: MP4 + H.264 + AAC..."
    & ffmpeg -hide_banner -y -i $input -map 0:v:0 -map '0:a:0?' -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 -movflags +faststart $output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "ffmpeg falhou ao converter o arquivo." }
    Write-Ok "Arquivo compatível criado:"
    Write-Host $output
}

function Parse-DownloadArguments([object[]]$Tokens) {
    $r = [PSCustomObject]@{
        Url = $null; ListItems = @(); RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = $null; VideoContainer = $null;
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
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
            "--container" { if (++$i -ge $Tokens.Count) { throw "--container precisa de um valor." }; $r.VideoContainer = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--quality" { if (++$i -ge $Tokens.Count) { throw "--quality precisa de um valor." }; if ([string]$Tokens[$i] -notmatch '^\d+$') { throw "--quality deve ser numérico." }; $r.Quality = [int]$Tokens[$i]; $r.MaxQuality = $false }
            "--max-quality" { $r.MaxQuality = $true; $r.Compat = $false }
            "--wpp" { $r.Compat = $true }
            "-wpp" { $r.Compat = $true }
            "--compat" { $r.Compat = $true }
            "--source" { $r.Compat = $false }
            "--cookies" { if (++$i -ge $Tokens.Count) { throw "--cookies precisa de um navegador." }; $r.CookieBrowser = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--cookies-file" { if (++$i -ge $Tokens.Count) { throw "--cookies-file precisa de um caminho." }; $r.CookieFile = Normalize-Path ([string]$Tokens[$i]) }
            "--playlist" { $r.Playlist = $true }
            "--list" {
                $listValues = @()
                while (($i + 1) -lt $Tokens.Count -and -not ([string]$Tokens[$i + 1]).StartsWith("-")) {
                    $i++
                    $listValues += [string]$Tokens[$i]
                }
                if ($listValues.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }
                $r.ListItems = @($r.ListItems) + @($listValues)
            }
            "--series" { $r.Series = $true }
            "--no-fallback" { $r.NoFallback = $true }
            "--loop" { $r.Loop = $true }
            default {
                if ($token.StartsWith("-")) { throw "Opção desconhecida: $token" }
                if ([string]::IsNullOrWhiteSpace([string]$r.Url)) { $r.Url = $token }
                else { throw "Argumento inesperado: $token" }
            }
        }
    }
    if (@($r.ListItems).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.Url)) { throw "Use uma URL posicional ou --list, não os dois ao mesmo tempo." }
    if (@($r.ListItems).Count -gt 0 -and $r.Loop) { throw "--list e --loop não podem ser usados juntos." }
    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    if ($r.VideoContainer -and $r.VideoContainer -notin @("mp4", "mkv")) { throw "--container aceita: mp4 ou mkv." }
    if ($r.AudioFormat -and $r.AudioFormat -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) { throw "--audio-format aceita: mp3, m4a, aac, opus, flac ou wav." }
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
            "fix" { if ($tokens.Count -lt 2) { throw "Uso: video-dl fix <arquivo>" }; Repair-WhatsAppVideo ([string]$tokens[1]); return }
            "paths" { Show-Paths; return }
            "--paths" { Show-Paths; return }
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
            "set-quality-name" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-quality-name <on|off>" }; Set-QualityNameCommand ([string]$tokens[1]); return }
            "set-duplicate-policy" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-duplicate-policy <skip|ask|overwrite|rename>" }; Set-DuplicatePolicyCommand ([string]$tokens[1]); return }
            "remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "--remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "--set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "unset-default" { Unset-DefaultPathCommand; return }
            "--unset-default" { Unset-DefaultPathCommand; return }
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
    $parsed = Apply-PersistentMediaSettings $parsed
    if ($parsed.Series) {
        $seriesCode = Invoke-SeriesSession $parsed
        if ($seriesCode -ne 0) { exit $seriesCode }
        return
    }

    if (@($parsed.ListItems).Count -gt 0) {
        $batchCode = Invoke-BatchSession $parsed
        if ($batchCode -ne 0) { exit $batchCode }
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$parsed.Url)) {
        Write-Info "video-dl - modo interativo"
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nCole uma URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
        return
    }

    $code = Invoke-OneDownload $parsed.Url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $null
    if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }

    if ($parsed.Loop) {
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nPróxima URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
    }
} catch {
    Write-Fail "ERRO: $($_.Exception.Message)"
    Write-Host "Use 'video-dl --help' para ver os comandos."
    exit 1
}











) { return "pluto" }
    if ($urlHost -match '(^|\.)(wcostream\.tv|wcostream\.com)
function Get-WcoMetadata([string]$Url) {
    $info = [PSCustomObject]@{
        Title = "Vídeo"; Series = $null; SeriesConfidence = "nenhuma";
        SeasonNumber = 1; EpisodeNumber = $null; Date = (Get-Date -Format "yyyy-MM-dd"); Id = $null;
        Source = "wcostream-url"
    }
    try {
        $slug = [Uri]::UnescapeDataString(([Uri]$Url).AbsolutePath.Trim('/'))
        if ($slug -match '(?i)^(.+?)-episode-(\d+)(?:-(.*))?$') {
            $seriesSlug = $Matches[1]
            $info.EpisodeNumber = [int]$Matches[2]
            $titleSlug = [string]$Matches[3]
            $info.Series = (($seriesSlug -split '-' | Where-Object { $_ } | ForEach-Object {
                if ($_.Length -gt 1) { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) } else { $_.ToUpperInvariant() }
            }) -join ' ')
            $info.SeriesConfidence = "média"
            if (-not [string]::IsNullOrWhiteSpace($titleSlug)) {
                $info.Title = (($titleSlug -split '-' | Where-Object { $_ }) -join ' ')
            } else { $info.Title = "Episódio $($info.EpisodeNumber)" }
            $info.Id = $slug
        }
    } catch { }
    return $info
}

function Invoke-WcoStream(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [string]$FileBase, [string]$Identity, [string]$SourceId
) {
    if ($AudioOnly) { Write-Warn "WCOStream: --audio ainda não é suportado."; return 1 }
    if (-not (Test-Path -LiteralPath $WcoDlPath -PathType Leaf)) { throw "wcostream-dl.ps1 não encontrado." }
    $desired = Join-Path $OutputDir ($FileBase + ".mp4")
    $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
    if ($decision.Skip) { return 0 }
    $target = [string]$decision.Path
    & $WcoDlPath -Url $Url -OutputPath $target
    if (-not $?) { return 1 }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $final = Add-QualitySuffix $target
        Register-VideoDlDownload $Identity $final $Url $SourceId
        return 0
    }
    return 1
}

function Get-AvulsoNaming([string]$Url, [string]$CookieBrowser, [string]$CookieFile) {
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $false
    $date = if ($null -ne $metadata) { [string]$metadata.Date } else { Get-Date -Format "yyyy-MM-dd" }
    $title = if ($null -ne $metadata) { [string]$metadata.Title } else { "Vídeo" }
    $sourceId = if ($null -ne $metadata) { [string]$metadata.Id } else { $null }
    $fileBase = "$date - $(Safe-Name $title 155)"
    $template = "$fileBase.%(ext)s"
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
    return [PSCustomObject]@{
        Metadata = $metadata
        FileBase = $fileBase
        Template = $template
        Identity = $identity
        SourceId = $sourceId
    }
}

function Register-YtDlpResult([string]$Identity, [string]$Url, [string]$SourceId, [string]$OutputDir, [string]$FileBase) {
    $result = Find-VideoDlOutputForBase $OutputDir $FileBase
    if ($null -ne $result) { Register-VideoDlDownload $Identity $result.FullName $Url $SourceId }
}

function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$ResolvedOutput
) {
    $output = if ([string]::IsNullOrWhiteSpace($ResolvedOutput)) { Resolve-OutputPath $RequestedPath $Here } else { $ResolvedOutput }
    Ensure-Directory $output
    Write-Host ""
    Write-Host "Destino: $output"
    $kind = Get-SiteKind $Url

    if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat $VideoContainer $false) }
    if ($kind -eq "wcostream") {
        $metadata = Get-WcoMetadata $Url
        $sourceId = [string]$metadata.Id
        $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
        $fileBase = "$(Get-Date -Format 'yyyy-MM-dd') - $(Safe-Name ([string]$metadata.Title) 155)"
        return (Invoke-WcoStream $Url $output $AudioOnly $AudioFormat $VideoContainer $fileBase $identity $sourceId)
    }

    if ($Playlist) {
        $playlistTemplate = "%(playlist_title).120B\%(playlist_index)03d - %(title).150B.%(ext)s"
        return (Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $true $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $playlistTemplate)
    }

    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $naming.Identity $desiredPath $Url $naming.SourceId $false
    if ($decision.Skip) { return 0 }
    $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $naming.Template = "$($naming.FileBase).%(ext)s"

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
    }

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $naming.Template
        if ($code -eq 0) {
            Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase)
    }

    $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $naming.Template
    if ($code -eq 0) {
        Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
}

function Read-RequiredText([string]$Prompt, [string]$DefaultValue) {
    while ($true) {
        $label = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $DefaultValue }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
}

function Read-RequiredNumber([string]$Prompt, [Nullable[int]]$DefaultValue) {
    while ($true) {
        $label = if ($null -eq $DefaultValue) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value) -and $null -ne $DefaultValue) { return [int]$DefaultValue }
        if ($value -match '^\d+$' -and [int]$value -ge 0) { return [int]$value }
        Write-Warn "Digite um número válido."
    }
}

function Resolve-SeriesInfo([object]$Metadata, [object]$State, [bool]$AutoSequence = $false) {
    $series = [string]$Metadata.Series
    $confidence = [string]$Metadata.SeriesConfidence

    if (-not [string]::IsNullOrWhiteSpace([string]$State.Name)) {
        if ([string]::IsNullOrWhiteSpace($series) -or $confidence -eq "baixa") {
            $series = [string]$State.Name
        } elseif ($series -ine [string]$State.Name) {
            Write-Warn "O link parece ser de outra série: '$series'."
            $switchSeries = Read-Host "Trocar da série '$($State.Name)' para '$series'? [s/N]"
            if (-not (Test-Yes $switchSeries $false)) { $series = [string]$State.Name }
            else { $State.Season = $null; $State.LastEpisode = $null }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($series) -and $confidence -ne "alta") {
        $answer = Read-Host "Série detectada: '$series' ($confidence confiança). Usar? [S/n]"
        if (-not (Test-Yes $answer $true)) { $series = $null }
    }

    if ([string]::IsNullOrWhiteSpace($series)) { $series = Read-RequiredText "Nome da série" ([string]$State.Name) }

    $season = $Metadata.SeasonNumber
    if ($null -eq $season) { $season = $State.Season }
    if ($null -eq $season) { $season = Read-RequiredNumber "Temporada" 1 }

    $episode = $Metadata.EpisodeNumber
    if ($null -eq $episode) {
        $next = $null
        if ($null -ne $State.LastEpisode -and $null -ne $State.Season -and [int]$State.Season -eq [int]$season) { $next = [int]$State.LastEpisode + 1 }
        if ($AutoSequence -and $null -ne $next) { $episode = [int]$next }
        else { $episode = Read-RequiredNumber "Número do episódio" $next }
    }

    $title = [string]$Metadata.Title
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "Episódio $episode" }

    $State.Name = $series
    $State.Season = [int]$season
    $State.LastEpisode = [int]$episode

    return [PSCustomObject]@{
        Series = $series; Season = [int]$season; Episode = [int]$episode; Title = $title
    }
}

function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$AutoSequence = $false
) {
    $kind = Get-SiteKind $Url

    if ($kind -ne "pluto" -and -not (Test-Dependency "yt-dlp")) { [void](Ensure-Dependency "yt-dlp" "detecção de metadados de séries") }
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State $AutoSequence

    if ($kind -eq "pluto") {
        return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $VideoContainer $true $info.Series $info.Season $info.Episode)
    }

    $sourceId = [string]$metadata.Id
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url

    $seriesFolder = Join-Path $BaseOutput (Safe-Name $info.Series 120)
    $seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f $info.Season)
    Ensure-Directory $seasonFolder
    $prefix = "S{0:D2}E{1:D2}" -f $info.Season, $info.Episode
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $seasonFolder ($fallbackBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $identity $desiredPath $Url $sourceId $false
    if ($decision.Skip) { return 0 }
    $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $template = "$fallbackBase.%(ext)s"

    if ($kind -eq "wcostream") {
        Write-Host ""
        Write-Host "Série:     $($info.Series)"
        Write-Host "Temporada: $($info.Season)"
        Write-Host "Episódio:  $($info.Episode)"
        Write-Host "Título:    $($info.Title)"
        Write-Host "Destino:   $seasonFolder"
        return (Invoke-WcoStream $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    Write-Host ""
    Write-Host "Série:     $($info.Series)"
    Write-Host "Temporada: $($info.Season)"
    Write-Host "Episódio:  $($info.Episode)"
    Write-Host "Título:    $($info.Title)"
    Write-Host "Destino:   $seasonFolder"

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $template
        if ($code -eq 0) {
            Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase)
    }

    $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $template
    if ($code -eq 0) {
        Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
}

function Resolve-ListUrls([object[]]$Items) {
    $values = @($Items | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }

    if ($values.Count -eq 1 -and [System.IO.Path]::GetExtension($values[0]) -ieq ".txt") {
        $listPath = Normalize-Path $values[0]
        if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { throw "Arquivo de lista não encontrado: $($values[0])" }
        $values = @(Get-Content -LiteralPath $listPath -Encoding UTF8 | ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") })
        if ($values.Count -eq 0) { throw "O arquivo de lista não contém URLs." }
    }

    return @($values)
}

function Write-BatchSummary([int]$Total, [int]$Succeeded, [int]$Failed) {
    Write-Host ""
    Write-Host "Resumo da lista:"
    Write-Host "  Total:                 $Total"
    Write-Host "  Concluídos/ignorados:  $Succeeded"
    Write-Host "  Falharam:              $Failed"
}

function Invoke-BatchSession([object]$Parsed) {
    if ($Parsed.Loop) { throw "--list e --loop não podem ser usados juntos." }
    $urls = @(Resolve-ListUrls $Parsed.ListItems)
    $resolvedOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $succeeded = 0
    $failed = 0

    Write-Info "video-dl - lista ($($urls.Count) links)"
    for ($index = 0; $index -lt $urls.Count; $index++) {
        $url = [string]$urls[$index]
        Write-Host ""
        Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
        try {
            $code = Invoke-OneDownload $url $Parsed.RequestedPath $Parsed.Here $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Playlist $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
            else { $failed++; Write-Fail "Item não concluído (código $code)." }
        } catch {
            $failed++
            Write-Fail "Item não concluído: $($_.Exception.Message)"
        }
    }

    Write-BatchSummary $urls.Count $succeeded $failed
    if ($failed -gt 0) { return 1 }
    return 0
}

function Invoke-SeriesSession([object]$Parsed) {
    if ($Parsed.Playlist) { throw "--series e --playlist representam coisas diferentes e não podem ser usados juntos." }
    if ($Parsed.Loop -and @($Parsed.ListItems).Count -gt 0) { throw "--list e --loop não podem ser usados juntos." }
    $baseOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $state = [PSCustomObject]@{ Name = $null; Season = $null; LastEpisode = $null }

    Write-Info "video-dl - modo série"
    Write-Host "Destino base: $baseOutput"
    Write-Host "O programa tenta detectar série, temporada e episódio pelos metadados."

    if (@($Parsed.ListItems).Count -gt 0) {
        $urls = @(Resolve-ListUrls $Parsed.ListItems)
        $succeeded = 0
        $failed = 0
        Write-Host "Lista: $($urls.Count) links"

        for ($index = 0; $index -lt $urls.Count; $index++) {
            $url = [string]$urls[$index]
            Write-Host ""
            Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
            try {
                $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $true
                if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
                else { $failed++; Write-Fail "Item não concluído (código $code)." }
            } catch {
                $failed++
                Write-Fail "Item não concluído: $($_.Exception.Message)"
            }
        }

        Write-BatchSummary $urls.Count $succeeded $failed
        if ($failed -gt 0) { return 1 }
        return 0
    }

    $url = [string]$Parsed.Url
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($url)) { $url = Read-Host "`nURL do próximo episódio (Enter para sair)" }
        if ([string]::IsNullOrWhiteSpace($url)) { break }
        $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $false
        if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        $url = $null
    }
    return 0
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

        $setupUrl = "https://raw.githubusercontent.com/sillasHead/video-dl/main/setup.ps1"
        $tempSetup = Join-Path $env:TEMP ("video-dl-setup-" + [Guid]::NewGuid().ToString("N") + ".ps1")
        Invoke-WebRequest -Uri $setupUrl -OutFile $tempSetup -UseBasicParsing -Headers @{ "Cache-Control" = "no-cache" }

        try {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -ne $pwsh) {
                & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            } else {
                $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
                if ($null -eq $windowsPowerShell) { throw "Nenhum PowerShell executável foi encontrado." }
                & $windowsPowerShell.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            }

            if ($exitCode -ne 0) { throw "O instalador PowerShell terminou com código $exitCode." }
        } finally {
            Remove-Item -LiteralPath $tempSetup -Force -ErrorAction SilentlyContinue
        }
        Write-Ok "Atualização concluída."
    } catch { Write-Fail "Falha ao atualizar: $($_.Exception.Message)" }
}
function Show-Help {
    @"
video-dl $Version - downloader universal

USO
  video-dl "URL"                  baixa um vídeo avulso
  video-dl --list links.txt        baixa uma lista de URLs de um arquivo TXT
  video-dl --list "URL1" "URL2"   baixa várias URLs passadas no próprio comando
  video-dl --list links.txt --series  processa a lista como episódios de uma série
  video-dl --series               modo série: cole os episódios um por um
  video-dl "URL" --series         começa a série por essa URL e pede as próximas
  video-dl                         modo interativo de vídeos avulsos

ORGANIZAÇÃO
  Avulso:  AAAA-MM-DD - Título original [1080p].ext
           usa a data original quando disponível; data atual como fallback.
  Série:   Série\Season 01\S01E01 - Título.ext
           tenta deduzir série/temporada/episódio por metadados e pelo título.
  Playlist nativa: --playlist (ex.: playlist do YouTube)

QUALIDADE / COMPATIBILIDADE
  --quality <altura>              limite de resolução (padrão: 1080)
  --max-quality                   melhor qualidade disponível, sem limite
  --wpp, -wpp, --compat           prioriza MP4 + H.264 + AAC
  fix <arquivo>                    converte vídeo existente para MP4 H.264 + AAC
  --source                        não aplica o preset de compatibilidade
  --container <mp4|mkv>           sobrescreve o container de vídeo neste download
  set-container <mp4|mkv>         muda o container padrão de vídeo

ÁUDIO
  --audio, --audio-only           baixa/extrai somente o áudio (MP3 por padrão)
  --audio-format <formato>        mp3, m4a, aac, opus, flac ou wav
  set-audio-format <formato>      muda o formato padrão de áudio

COOKIES
  --cookies <browser>             firefox, chrome, edge, brave ou auto
  --cookies-file <arquivo>        usa cookies.txt

DESTINO
  --path <nome|caminho>           escolhe destino salvo ou caminho direto
  --here                          salva na pasta atual
  --add-path <caminho>            adiciona destino
  --name <nome>                   usado junto com --add-path
  --default                       adiciona e passa a usar esse destino automaticamente
  --paths                         lista destinos
  --remove-path <nome>            remove destino
  set-default <nome>              usa esse destino automaticamente
  unset-default                   volta a perguntar quando houver mais de um destino

CONFIGURAÇÃO
  config                          abre config.json no editor (VS Code/EDITOR/Notepad)
  config show                     mostra a configuração no terminal
  config path                     mostra o caminho do arquivo
  settings                        resumo das configurações atuais
  set-quality-name <on|off>       mostra/oculta [1080p] no nome dos vídeos
  set-duplicate-policy <modo>     skip, ask, overwrite ou rename

OUTROS
  --list <arquivo.txt|URLs...>     processa várias URLs; aceita TXT ou URLs no comando
  --series                        organiza vários links como episódios de uma série
  --playlist                      baixa playlist nativa do site via yt-dlp
  --no-fallback                   não tenta downloader alternativo
  --loop                          continua pedindo links avulsos
  doctor                          verifica dependências
  install-deps                    instala dependências ausentes
  update                          atualiza pelo GitHub
  --version                       mostra a versão
  --help                          mostra esta ajuda
"@ | Write-Host
}

function Repair-WhatsAppVideo([string]$InputPath) {
    $input = Normalize-Path $InputPath
    if (-not (Test-Path -LiteralPath $input -PathType Leaf)) { throw "Arquivo não encontrado: $input" }
    if (-not (Test-Dependency "ffmpeg")) { throw "ffmpeg não encontrado. Rode: video-dl install-deps" }

    $dir = Split-Path -Parent $input
    $base = [System.IO.Path]::GetFileNameWithoutExtension($input)
    $output = Join-Path $dir ($base + " [WhatsApp].mp4")
    $n = 2
    while (Test-Path -LiteralPath $output) {
        $output = Join-Path $dir ($base + " [WhatsApp $n].mp4")
        $n++
    }

    Write-Info "Convertendo para WhatsApp: MP4 + H.264 + AAC..."
    & ffmpeg -hide_banner -y -i $input -map 0:v:0 -map '0:a:0?' -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 -movflags +faststart $output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "ffmpeg falhou ao converter o arquivo." }
    Write-Ok "Arquivo compatível criado:"
    Write-Host $output
}

function Parse-DownloadArguments([object[]]$Tokens) {
    $r = [PSCustomObject]@{
        Url = $null; ListItems = @(); RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = $null; VideoContainer = $null;
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
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
            "--container" { if (++$i -ge $Tokens.Count) { throw "--container precisa de um valor." }; $r.VideoContainer = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--quality" { if (++$i -ge $Tokens.Count) { throw "--quality precisa de um valor." }; if ([string]$Tokens[$i] -notmatch '^\d+$') { throw "--quality deve ser numérico." }; $r.Quality = [int]$Tokens[$i]; $r.MaxQuality = $false }
            "--max-quality" { $r.MaxQuality = $true; $r.Compat = $false }
            "--wpp" { $r.Compat = $true }
            "-wpp" { $r.Compat = $true }
            "--compat" { $r.Compat = $true }
            "--source" { $r.Compat = $false }
            "--cookies" { if (++$i -ge $Tokens.Count) { throw "--cookies precisa de um navegador." }; $r.CookieBrowser = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--cookies-file" { if (++$i -ge $Tokens.Count) { throw "--cookies-file precisa de um caminho." }; $r.CookieFile = Normalize-Path ([string]$Tokens[$i]) }
            "--playlist" { $r.Playlist = $true }
            "--list" {
                $listValues = @()
                while (($i + 1) -lt $Tokens.Count -and -not ([string]$Tokens[$i + 1]).StartsWith("-")) {
                    $i++
                    $listValues += [string]$Tokens[$i]
                }
                if ($listValues.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }
                $r.ListItems = @($r.ListItems) + @($listValues)
            }
            "--series" { $r.Series = $true }
            "--no-fallback" { $r.NoFallback = $true }
            "--loop" { $r.Loop = $true }
            default {
                if ($token.StartsWith("-")) { throw "Opção desconhecida: $token" }
                if ([string]::IsNullOrWhiteSpace([string]$r.Url)) { $r.Url = $token }
                else { throw "Argumento inesperado: $token" }
            }
        }
    }
    if (@($r.ListItems).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.Url)) { throw "Use uma URL posicional ou --list, não os dois ao mesmo tempo." }
    if (@($r.ListItems).Count -gt 0 -and $r.Loop) { throw "--list e --loop não podem ser usados juntos." }
    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    if ($r.VideoContainer -and $r.VideoContainer -notin @("mp4", "mkv")) { throw "--container aceita: mp4 ou mkv." }
    if ($r.AudioFormat -and $r.AudioFormat -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) { throw "--audio-format aceita: mp3, m4a, aac, opus, flac ou wav." }
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
            "fix" { if ($tokens.Count -lt 2) { throw "Uso: video-dl fix <arquivo>" }; Repair-WhatsAppVideo ([string]$tokens[1]); return }
            "paths" { Show-Paths; return }
            "--paths" { Show-Paths; return }
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
            "set-quality-name" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-quality-name <on|off>" }; Set-QualityNameCommand ([string]$tokens[1]); return }
            "set-duplicate-policy" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-duplicate-policy <skip|ask|overwrite|rename>" }; Set-DuplicatePolicyCommand ([string]$tokens[1]); return }
            "remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "--remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "--set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "unset-default" { Unset-DefaultPathCommand; return }
            "--unset-default" { Unset-DefaultPathCommand; return }
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
    $parsed = Apply-PersistentMediaSettings $parsed
    if ($parsed.Series) {
        $seriesCode = Invoke-SeriesSession $parsed
        if ($seriesCode -ne 0) { exit $seriesCode }
        return
    }

    if (@($parsed.ListItems).Count -gt 0) {
        $batchCode = Invoke-BatchSession $parsed
        if ($batchCode -ne 0) { exit $batchCode }
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$parsed.Url)) {
        Write-Info "video-dl - modo interativo"
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nCole uma URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
        return
    }

    $code = Invoke-OneDownload $parsed.Url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $null
    if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }

    if ($parsed.Loop) {
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nPróxima URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
    }
} catch {
    Write-Fail "ERRO: $($_.Exception.Message)"
    Write-Host "Use 'video-dl --help' para ver os comandos."
    exit 1
}











) { return "wcostream" }
    if ($urlHost -match '(^|\.)threads\.(com|net)
function Get-WcoMetadata([string]$Url) {
    $info = [PSCustomObject]@{
        Title = "Vídeo"; Series = $null; SeriesConfidence = "nenhuma";
        SeasonNumber = 1; EpisodeNumber = $null; Date = (Get-Date -Format "yyyy-MM-dd"); Id = $null;
        Source = "wcostream-url"
    }
    try {
        $slug = [Uri]::UnescapeDataString(([Uri]$Url).AbsolutePath.Trim('/'))
        if ($slug -match '(?i)^(.+?)-episode-(\d+)(?:-(.*))?$') {
            $seriesSlug = $Matches[1]
            $info.EpisodeNumber = [int]$Matches[2]
            $titleSlug = [string]$Matches[3]
            $info.Series = (($seriesSlug -split '-' | Where-Object { $_ } | ForEach-Object {
                if ($_.Length -gt 1) { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) } else { $_.ToUpperInvariant() }
            }) -join ' ')
            $info.SeriesConfidence = "média"
            if (-not [string]::IsNullOrWhiteSpace($titleSlug)) {
                $info.Title = (($titleSlug -split '-' | Where-Object { $_ }) -join ' ')
            } else { $info.Title = "Episódio $($info.EpisodeNumber)" }
            $info.Id = $slug
        }
    } catch { }
    return $info
}

function Invoke-WcoStream(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [string]$FileBase, [string]$Identity, [string]$SourceId
) {
    if ($AudioOnly) { Write-Warn "WCOStream: --audio ainda não é suportado."; return 1 }
    if (-not (Test-Path -LiteralPath $WcoDlPath -PathType Leaf)) { throw "wcostream-dl.ps1 não encontrado." }
    $desired = Join-Path $OutputDir ($FileBase + ".mp4")
    $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
    if ($decision.Skip) { return 0 }
    $target = [string]$decision.Path
    & $WcoDlPath -Url $Url -OutputPath $target
    if (-not $?) { return 1 }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $final = Add-QualitySuffix $target
        Register-VideoDlDownload $Identity $final $Url $SourceId
        return 0
    }
    return 1
}

function Get-AvulsoNaming([string]$Url, [string]$CookieBrowser, [string]$CookieFile) {
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $false
    $date = if ($null -ne $metadata) { [string]$metadata.Date } else { Get-Date -Format "yyyy-MM-dd" }
    $title = if ($null -ne $metadata) { [string]$metadata.Title } else { "Vídeo" }
    $sourceId = if ($null -ne $metadata) { [string]$metadata.Id } else { $null }
    $fileBase = "$date - $(Safe-Name $title 155)"
    $template = "$fileBase.%(ext)s"
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
    return [PSCustomObject]@{
        Metadata = $metadata
        FileBase = $fileBase
        Template = $template
        Identity = $identity
        SourceId = $sourceId
    }
}

function Register-YtDlpResult([string]$Identity, [string]$Url, [string]$SourceId, [string]$OutputDir, [string]$FileBase) {
    $result = Find-VideoDlOutputForBase $OutputDir $FileBase
    if ($null -ne $result) { Register-VideoDlDownload $Identity $result.FullName $Url $SourceId }
}

function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$ResolvedOutput
) {
    $output = if ([string]::IsNullOrWhiteSpace($ResolvedOutput)) { Resolve-OutputPath $RequestedPath $Here } else { $ResolvedOutput }
    Ensure-Directory $output
    Write-Host ""
    Write-Host "Destino: $output"
    $kind = Get-SiteKind $Url

    if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat $VideoContainer $false) }
    if ($kind -eq "wcostream") {
        $metadata = Get-WcoMetadata $Url
        $sourceId = [string]$metadata.Id
        $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
        $fileBase = "$(Get-Date -Format 'yyyy-MM-dd') - $(Safe-Name ([string]$metadata.Title) 155)"
        return (Invoke-WcoStream $Url $output $AudioOnly $AudioFormat $VideoContainer $fileBase $identity $sourceId)
    }

    if ($Playlist) {
        $playlistTemplate = "%(playlist_title).120B\%(playlist_index)03d - %(title).150B.%(ext)s"
        return (Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $true $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $playlistTemplate)
    }

    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $naming.Identity $desiredPath $Url $naming.SourceId $false
    if ($decision.Skip) { return 0 }
    $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $naming.Template = "$($naming.FileBase).%(ext)s"

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
    }

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $naming.Template
        if ($code -eq 0) {
            Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase)
    }

    $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $naming.Template
    if ($code -eq 0) {
        Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
}

function Read-RequiredText([string]$Prompt, [string]$DefaultValue) {
    while ($true) {
        $label = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $DefaultValue }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
}

function Read-RequiredNumber([string]$Prompt, [Nullable[int]]$DefaultValue) {
    while ($true) {
        $label = if ($null -eq $DefaultValue) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value) -and $null -ne $DefaultValue) { return [int]$DefaultValue }
        if ($value -match '^\d+$' -and [int]$value -ge 0) { return [int]$value }
        Write-Warn "Digite um número válido."
    }
}

function Resolve-SeriesInfo([object]$Metadata, [object]$State, [bool]$AutoSequence = $false) {
    $series = [string]$Metadata.Series
    $confidence = [string]$Metadata.SeriesConfidence

    if (-not [string]::IsNullOrWhiteSpace([string]$State.Name)) {
        if ([string]::IsNullOrWhiteSpace($series) -or $confidence -eq "baixa") {
            $series = [string]$State.Name
        } elseif ($series -ine [string]$State.Name) {
            Write-Warn "O link parece ser de outra série: '$series'."
            $switchSeries = Read-Host "Trocar da série '$($State.Name)' para '$series'? [s/N]"
            if (-not (Test-Yes $switchSeries $false)) { $series = [string]$State.Name }
            else { $State.Season = $null; $State.LastEpisode = $null }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($series) -and $confidence -ne "alta") {
        $answer = Read-Host "Série detectada: '$series' ($confidence confiança). Usar? [S/n]"
        if (-not (Test-Yes $answer $true)) { $series = $null }
    }

    if ([string]::IsNullOrWhiteSpace($series)) { $series = Read-RequiredText "Nome da série" ([string]$State.Name) }

    $season = $Metadata.SeasonNumber
    if ($null -eq $season) { $season = $State.Season }
    if ($null -eq $season) { $season = Read-RequiredNumber "Temporada" 1 }

    $episode = $Metadata.EpisodeNumber
    if ($null -eq $episode) {
        $next = $null
        if ($null -ne $State.LastEpisode -and $null -ne $State.Season -and [int]$State.Season -eq [int]$season) { $next = [int]$State.LastEpisode + 1 }
        if ($AutoSequence -and $null -ne $next) { $episode = [int]$next }
        else { $episode = Read-RequiredNumber "Número do episódio" $next }
    }

    $title = [string]$Metadata.Title
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "Episódio $episode" }

    $State.Name = $series
    $State.Season = [int]$season
    $State.LastEpisode = [int]$episode

    return [PSCustomObject]@{
        Series = $series; Season = [int]$season; Episode = [int]$episode; Title = $title
    }
}

function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$AutoSequence = $false
) {
    $kind = Get-SiteKind $Url

    if ($kind -ne "pluto" -and -not (Test-Dependency "yt-dlp")) { [void](Ensure-Dependency "yt-dlp" "detecção de metadados de séries") }
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State $AutoSequence

    if ($kind -eq "pluto") {
        return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $VideoContainer $true $info.Series $info.Season $info.Episode)
    }

    $sourceId = [string]$metadata.Id
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url

    $seriesFolder = Join-Path $BaseOutput (Safe-Name $info.Series 120)
    $seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f $info.Season)
    Ensure-Directory $seasonFolder
    $prefix = "S{0:D2}E{1:D2}" -f $info.Season, $info.Episode
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $seasonFolder ($fallbackBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $identity $desiredPath $Url $sourceId $false
    if ($decision.Skip) { return 0 }
    $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $template = "$fallbackBase.%(ext)s"

    if ($kind -eq "wcostream") {
        Write-Host ""
        Write-Host "Série:     $($info.Series)"
        Write-Host "Temporada: $($info.Season)"
        Write-Host "Episódio:  $($info.Episode)"
        Write-Host "Título:    $($info.Title)"
        Write-Host "Destino:   $seasonFolder"
        return (Invoke-WcoStream $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    Write-Host ""
    Write-Host "Série:     $($info.Series)"
    Write-Host "Temporada: $($info.Season)"
    Write-Host "Episódio:  $($info.Episode)"
    Write-Host "Título:    $($info.Title)"
    Write-Host "Destino:   $seasonFolder"

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $template
        if ($code -eq 0) {
            Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase)
    }

    $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $template
    if ($code -eq 0) {
        Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
}

function Resolve-ListUrls([object[]]$Items) {
    $values = @($Items | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }

    if ($values.Count -eq 1 -and [System.IO.Path]::GetExtension($values[0]) -ieq ".txt") {
        $listPath = Normalize-Path $values[0]
        if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { throw "Arquivo de lista não encontrado: $($values[0])" }
        $values = @(Get-Content -LiteralPath $listPath -Encoding UTF8 | ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") })
        if ($values.Count -eq 0) { throw "O arquivo de lista não contém URLs." }
    }

    return @($values)
}

function Write-BatchSummary([int]$Total, [int]$Succeeded, [int]$Failed) {
    Write-Host ""
    Write-Host "Resumo da lista:"
    Write-Host "  Total:                 $Total"
    Write-Host "  Concluídos/ignorados:  $Succeeded"
    Write-Host "  Falharam:              $Failed"
}

function Invoke-BatchSession([object]$Parsed) {
    if ($Parsed.Loop) { throw "--list e --loop não podem ser usados juntos." }
    $urls = @(Resolve-ListUrls $Parsed.ListItems)
    $resolvedOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $succeeded = 0
    $failed = 0

    Write-Info "video-dl - lista ($($urls.Count) links)"
    for ($index = 0; $index -lt $urls.Count; $index++) {
        $url = [string]$urls[$index]
        Write-Host ""
        Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
        try {
            $code = Invoke-OneDownload $url $Parsed.RequestedPath $Parsed.Here $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Playlist $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
            else { $failed++; Write-Fail "Item não concluído (código $code)." }
        } catch {
            $failed++
            Write-Fail "Item não concluído: $($_.Exception.Message)"
        }
    }

    Write-BatchSummary $urls.Count $succeeded $failed
    if ($failed -gt 0) { return 1 }
    return 0
}

function Invoke-SeriesSession([object]$Parsed) {
    if ($Parsed.Playlist) { throw "--series e --playlist representam coisas diferentes e não podem ser usados juntos." }
    if ($Parsed.Loop -and @($Parsed.ListItems).Count -gt 0) { throw "--list e --loop não podem ser usados juntos." }
    $baseOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $state = [PSCustomObject]@{ Name = $null; Season = $null; LastEpisode = $null }

    Write-Info "video-dl - modo série"
    Write-Host "Destino base: $baseOutput"
    Write-Host "O programa tenta detectar série, temporada e episódio pelos metadados."

    if (@($Parsed.ListItems).Count -gt 0) {
        $urls = @(Resolve-ListUrls $Parsed.ListItems)
        $succeeded = 0
        $failed = 0
        Write-Host "Lista: $($urls.Count) links"

        for ($index = 0; $index -lt $urls.Count; $index++) {
            $url = [string]$urls[$index]
            Write-Host ""
            Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
            try {
                $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $true
                if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
                else { $failed++; Write-Fail "Item não concluído (código $code)." }
            } catch {
                $failed++
                Write-Fail "Item não concluído: $($_.Exception.Message)"
            }
        }

        Write-BatchSummary $urls.Count $succeeded $failed
        if ($failed -gt 0) { return 1 }
        return 0
    }

    $url = [string]$Parsed.Url
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($url)) { $url = Read-Host "`nURL do próximo episódio (Enter para sair)" }
        if ([string]::IsNullOrWhiteSpace($url)) { break }
        $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $false
        if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        $url = $null
    }
    return 0
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

        $setupUrl = "https://raw.githubusercontent.com/sillasHead/video-dl/main/setup.ps1"
        $tempSetup = Join-Path $env:TEMP ("video-dl-setup-" + [Guid]::NewGuid().ToString("N") + ".ps1")
        Invoke-WebRequest -Uri $setupUrl -OutFile $tempSetup -UseBasicParsing -Headers @{ "Cache-Control" = "no-cache" }

        try {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -ne $pwsh) {
                & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            } else {
                $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
                if ($null -eq $windowsPowerShell) { throw "Nenhum PowerShell executável foi encontrado." }
                & $windowsPowerShell.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            }

            if ($exitCode -ne 0) { throw "O instalador PowerShell terminou com código $exitCode." }
        } finally {
            Remove-Item -LiteralPath $tempSetup -Force -ErrorAction SilentlyContinue
        }
        Write-Ok "Atualização concluída."
    } catch { Write-Fail "Falha ao atualizar: $($_.Exception.Message)" }
}
function Show-Help {
    @"
video-dl $Version - downloader universal

USO
  video-dl "URL"                  baixa um vídeo avulso
  video-dl --list links.txt        baixa uma lista de URLs de um arquivo TXT
  video-dl --list "URL1" "URL2"   baixa várias URLs passadas no próprio comando
  video-dl --list links.txt --series  processa a lista como episódios de uma série
  video-dl --series               modo série: cole os episódios um por um
  video-dl "URL" --series         começa a série por essa URL e pede as próximas
  video-dl                         modo interativo de vídeos avulsos

ORGANIZAÇÃO
  Avulso:  AAAA-MM-DD - Título original [1080p].ext
           usa a data original quando disponível; data atual como fallback.
  Série:   Série\Season 01\S01E01 - Título.ext
           tenta deduzir série/temporada/episódio por metadados e pelo título.
  Playlist nativa: --playlist (ex.: playlist do YouTube)

QUALIDADE / COMPATIBILIDADE
  --quality <altura>              limite de resolução (padrão: 1080)
  --max-quality                   melhor qualidade disponível, sem limite
  --wpp, -wpp, --compat           prioriza MP4 + H.264 + AAC
  fix <arquivo>                    converte vídeo existente para MP4 H.264 + AAC
  --source                        não aplica o preset de compatibilidade
  --container <mp4|mkv>           sobrescreve o container de vídeo neste download
  set-container <mp4|mkv>         muda o container padrão de vídeo

ÁUDIO
  --audio, --audio-only           baixa/extrai somente o áudio (MP3 por padrão)
  --audio-format <formato>        mp3, m4a, aac, opus, flac ou wav
  set-audio-format <formato>      muda o formato padrão de áudio

COOKIES
  --cookies <browser>             firefox, chrome, edge, brave ou auto
  --cookies-file <arquivo>        usa cookies.txt

DESTINO
  --path <nome|caminho>           escolhe destino salvo ou caminho direto
  --here                          salva na pasta atual
  --add-path <caminho>            adiciona destino
  --name <nome>                   usado junto com --add-path
  --default                       adiciona e passa a usar esse destino automaticamente
  --paths                         lista destinos
  --remove-path <nome>            remove destino
  set-default <nome>              usa esse destino automaticamente
  unset-default                   volta a perguntar quando houver mais de um destino

CONFIGURAÇÃO
  config                          abre config.json no editor (VS Code/EDITOR/Notepad)
  config show                     mostra a configuração no terminal
  config path                     mostra o caminho do arquivo
  settings                        resumo das configurações atuais
  set-quality-name <on|off>       mostra/oculta [1080p] no nome dos vídeos
  set-duplicate-policy <modo>     skip, ask, overwrite ou rename

OUTROS
  --list <arquivo.txt|URLs...>     processa várias URLs; aceita TXT ou URLs no comando
  --series                        organiza vários links como episódios de uma série
  --playlist                      baixa playlist nativa do site via yt-dlp
  --no-fallback                   não tenta downloader alternativo
  --loop                          continua pedindo links avulsos
  doctor                          verifica dependências
  install-deps                    instala dependências ausentes
  update                          atualiza pelo GitHub
  --version                       mostra a versão
  --help                          mostra esta ajuda
"@ | Write-Host
}

function Repair-WhatsAppVideo([string]$InputPath) {
    $input = Normalize-Path $InputPath
    if (-not (Test-Path -LiteralPath $input -PathType Leaf)) { throw "Arquivo não encontrado: $input" }
    if (-not (Test-Dependency "ffmpeg")) { throw "ffmpeg não encontrado. Rode: video-dl install-deps" }

    $dir = Split-Path -Parent $input
    $base = [System.IO.Path]::GetFileNameWithoutExtension($input)
    $output = Join-Path $dir ($base + " [WhatsApp].mp4")
    $n = 2
    while (Test-Path -LiteralPath $output) {
        $output = Join-Path $dir ($base + " [WhatsApp $n].mp4")
        $n++
    }

    Write-Info "Convertendo para WhatsApp: MP4 + H.264 + AAC..."
    & ffmpeg -hide_banner -y -i $input -map 0:v:0 -map '0:a:0?' -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 -movflags +faststart $output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "ffmpeg falhou ao converter o arquivo." }
    Write-Ok "Arquivo compatível criado:"
    Write-Host $output
}

function Parse-DownloadArguments([object[]]$Tokens) {
    $r = [PSCustomObject]@{
        Url = $null; ListItems = @(); RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = $null; VideoContainer = $null;
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
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
            "--container" { if (++$i -ge $Tokens.Count) { throw "--container precisa de um valor." }; $r.VideoContainer = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--quality" { if (++$i -ge $Tokens.Count) { throw "--quality precisa de um valor." }; if ([string]$Tokens[$i] -notmatch '^\d+$') { throw "--quality deve ser numérico." }; $r.Quality = [int]$Tokens[$i]; $r.MaxQuality = $false }
            "--max-quality" { $r.MaxQuality = $true; $r.Compat = $false }
            "--wpp" { $r.Compat = $true }
            "-wpp" { $r.Compat = $true }
            "--compat" { $r.Compat = $true }
            "--source" { $r.Compat = $false }
            "--cookies" { if (++$i -ge $Tokens.Count) { throw "--cookies precisa de um navegador." }; $r.CookieBrowser = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--cookies-file" { if (++$i -ge $Tokens.Count) { throw "--cookies-file precisa de um caminho." }; $r.CookieFile = Normalize-Path ([string]$Tokens[$i]) }
            "--playlist" { $r.Playlist = $true }
            "--list" {
                $listValues = @()
                while (($i + 1) -lt $Tokens.Count -and -not ([string]$Tokens[$i + 1]).StartsWith("-")) {
                    $i++
                    $listValues += [string]$Tokens[$i]
                }
                if ($listValues.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }
                $r.ListItems = @($r.ListItems) + @($listValues)
            }
            "--series" { $r.Series = $true }
            "--no-fallback" { $r.NoFallback = $true }
            "--loop" { $r.Loop = $true }
            default {
                if ($token.StartsWith("-")) { throw "Opção desconhecida: $token" }
                if ([string]::IsNullOrWhiteSpace([string]$r.Url)) { $r.Url = $token }
                else { throw "Argumento inesperado: $token" }
            }
        }
    }
    if (@($r.ListItems).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.Url)) { throw "Use uma URL posicional ou --list, não os dois ao mesmo tempo." }
    if (@($r.ListItems).Count -gt 0 -and $r.Loop) { throw "--list e --loop não podem ser usados juntos." }
    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    if ($r.VideoContainer -and $r.VideoContainer -notin @("mp4", "mkv")) { throw "--container aceita: mp4 ou mkv." }
    if ($r.AudioFormat -and $r.AudioFormat -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) { throw "--audio-format aceita: mp3, m4a, aac, opus, flac ou wav." }
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
            "fix" { if ($tokens.Count -lt 2) { throw "Uso: video-dl fix <arquivo>" }; Repair-WhatsAppVideo ([string]$tokens[1]); return }
            "paths" { Show-Paths; return }
            "--paths" { Show-Paths; return }
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
            "set-quality-name" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-quality-name <on|off>" }; Set-QualityNameCommand ([string]$tokens[1]); return }
            "set-duplicate-policy" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-duplicate-policy <skip|ask|overwrite|rename>" }; Set-DuplicatePolicyCommand ([string]$tokens[1]); return }
            "remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "--remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "--set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "unset-default" { Unset-DefaultPathCommand; return }
            "--unset-default" { Unset-DefaultPathCommand; return }
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
    $parsed = Apply-PersistentMediaSettings $parsed
    if ($parsed.Series) {
        $seriesCode = Invoke-SeriesSession $parsed
        if ($seriesCode -ne 0) { exit $seriesCode }
        return
    }

    if (@($parsed.ListItems).Count -gt 0) {
        $batchCode = Invoke-BatchSession $parsed
        if ($batchCode -ne 0) { exit $batchCode }
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$parsed.Url)) {
        Write-Info "video-dl - modo interativo"
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nCole uma URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
        return
    }

    $code = Invoke-OneDownload $parsed.Url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $null
    if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }

    if ($parsed.Loop) {
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nPróxima URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
    }
} catch {
    Write-Fail "ERRO: $($_.Exception.Message)"
    Write-Host "Use 'video-dl --help' para ver os comandos."
    exit 1
}











) { return "threads" }
    if ($urlHost -match '(^|\.)(youtube\.com|youtu\.be)
function Get-WcoMetadata([string]$Url) {
    $info = [PSCustomObject]@{
        Title = "Vídeo"; Series = $null; SeriesConfidence = "nenhuma";
        SeasonNumber = 1; EpisodeNumber = $null; Date = (Get-Date -Format "yyyy-MM-dd"); Id = $null;
        Source = "wcostream-url"
    }
    try {
        $slug = [Uri]::UnescapeDataString(([Uri]$Url).AbsolutePath.Trim('/'))
        if ($slug -match '(?i)^(.+?)-episode-(\d+)(?:-(.*))?$') {
            $seriesSlug = $Matches[1]
            $info.EpisodeNumber = [int]$Matches[2]
            $titleSlug = [string]$Matches[3]
            $info.Series = (($seriesSlug -split '-' | Where-Object { $_ } | ForEach-Object {
                if ($_.Length -gt 1) { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) } else { $_.ToUpperInvariant() }
            }) -join ' ')
            $info.SeriesConfidence = "média"
            if (-not [string]::IsNullOrWhiteSpace($titleSlug)) {
                $info.Title = (($titleSlug -split '-' | Where-Object { $_ }) -join ' ')
            } else { $info.Title = "Episódio $($info.EpisodeNumber)" }
            $info.Id = $slug
        }
    } catch { }
    return $info
}

function Invoke-WcoStream(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [string]$FileBase, [string]$Identity, [string]$SourceId
) {
    if ($AudioOnly) { Write-Warn "WCOStream: --audio ainda não é suportado."; return 1 }
    if (-not (Test-Path -LiteralPath $WcoDlPath -PathType Leaf)) { throw "wcostream-dl.ps1 não encontrado." }
    $desired = Join-Path $OutputDir ($FileBase + ".mp4")
    $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
    if ($decision.Skip) { return 0 }
    $target = [string]$decision.Path
    & $WcoDlPath -Url $Url -OutputPath $target
    if (-not $?) { return 1 }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $final = Add-QualitySuffix $target
        Register-VideoDlDownload $Identity $final $Url $SourceId
        return 0
    }
    return 1
}

function Get-AvulsoNaming([string]$Url, [string]$CookieBrowser, [string]$CookieFile) {
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $false
    $date = if ($null -ne $metadata) { [string]$metadata.Date } else { Get-Date -Format "yyyy-MM-dd" }
    $title = if ($null -ne $metadata) { [string]$metadata.Title } else { "Vídeo" }
    $sourceId = if ($null -ne $metadata) { [string]$metadata.Id } else { $null }
    $fileBase = "$date - $(Safe-Name $title 155)"
    $template = "$fileBase.%(ext)s"
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
    return [PSCustomObject]@{
        Metadata = $metadata
        FileBase = $fileBase
        Template = $template
        Identity = $identity
        SourceId = $sourceId
    }
}

function Register-YtDlpResult([string]$Identity, [string]$Url, [string]$SourceId, [string]$OutputDir, [string]$FileBase) {
    $result = Find-VideoDlOutputForBase $OutputDir $FileBase
    if ($null -ne $result) { Register-VideoDlDownload $Identity $result.FullName $Url $SourceId }
}

function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$ResolvedOutput
) {
    $output = if ([string]::IsNullOrWhiteSpace($ResolvedOutput)) { Resolve-OutputPath $RequestedPath $Here } else { $ResolvedOutput }
    Ensure-Directory $output
    Write-Host ""
    Write-Host "Destino: $output"
    $kind = Get-SiteKind $Url

    if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat $VideoContainer $false) }
    if ($kind -eq "wcostream") {
        $metadata = Get-WcoMetadata $Url
        $sourceId = [string]$metadata.Id
        $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
        $fileBase = "$(Get-Date -Format 'yyyy-MM-dd') - $(Safe-Name ([string]$metadata.Title) 155)"
        return (Invoke-WcoStream $Url $output $AudioOnly $AudioFormat $VideoContainer $fileBase $identity $sourceId)
    }

    if ($Playlist) {
        $playlistTemplate = "%(playlist_title).120B\%(playlist_index)03d - %(title).150B.%(ext)s"
        return (Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $true $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $playlistTemplate)
    }

    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $naming.Identity $desiredPath $Url $naming.SourceId $false
    if ($decision.Skip) { return 0 }
    $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $naming.Template = "$($naming.FileBase).%(ext)s"

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
    }

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $naming.Template
        if ($code -eq 0) {
            Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase)
    }

    $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $naming.Template
    if ($code -eq 0) {
        Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
}

function Read-RequiredText([string]$Prompt, [string]$DefaultValue) {
    while ($true) {
        $label = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $DefaultValue }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
}

function Read-RequiredNumber([string]$Prompt, [Nullable[int]]$DefaultValue) {
    while ($true) {
        $label = if ($null -eq $DefaultValue) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value) -and $null -ne $DefaultValue) { return [int]$DefaultValue }
        if ($value -match '^\d+$' -and [int]$value -ge 0) { return [int]$value }
        Write-Warn "Digite um número válido."
    }
}

function Resolve-SeriesInfo([object]$Metadata, [object]$State, [bool]$AutoSequence = $false) {
    $series = [string]$Metadata.Series
    $confidence = [string]$Metadata.SeriesConfidence

    if (-not [string]::IsNullOrWhiteSpace([string]$State.Name)) {
        if ([string]::IsNullOrWhiteSpace($series) -or $confidence -eq "baixa") {
            $series = [string]$State.Name
        } elseif ($series -ine [string]$State.Name) {
            Write-Warn "O link parece ser de outra série: '$series'."
            $switchSeries = Read-Host "Trocar da série '$($State.Name)' para '$series'? [s/N]"
            if (-not (Test-Yes $switchSeries $false)) { $series = [string]$State.Name }
            else { $State.Season = $null; $State.LastEpisode = $null }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($series) -and $confidence -ne "alta") {
        $answer = Read-Host "Série detectada: '$series' ($confidence confiança). Usar? [S/n]"
        if (-not (Test-Yes $answer $true)) { $series = $null }
    }

    if ([string]::IsNullOrWhiteSpace($series)) { $series = Read-RequiredText "Nome da série" ([string]$State.Name) }

    $season = $Metadata.SeasonNumber
    if ($null -eq $season) { $season = $State.Season }
    if ($null -eq $season) { $season = Read-RequiredNumber "Temporada" 1 }

    $episode = $Metadata.EpisodeNumber
    if ($null -eq $episode) {
        $next = $null
        if ($null -ne $State.LastEpisode -and $null -ne $State.Season -and [int]$State.Season -eq [int]$season) { $next = [int]$State.LastEpisode + 1 }
        if ($AutoSequence -and $null -ne $next) { $episode = [int]$next }
        else { $episode = Read-RequiredNumber "Número do episódio" $next }
    }

    $title = [string]$Metadata.Title
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "Episódio $episode" }

    $State.Name = $series
    $State.Season = [int]$season
    $State.LastEpisode = [int]$episode

    return [PSCustomObject]@{
        Series = $series; Season = [int]$season; Episode = [int]$episode; Title = $title
    }
}

function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$AutoSequence = $false
) {
    $kind = Get-SiteKind $Url

    if ($kind -ne "pluto" -and -not (Test-Dependency "yt-dlp")) { [void](Ensure-Dependency "yt-dlp" "detecção de metadados de séries") }
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State $AutoSequence

    if ($kind -eq "pluto") {
        return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $VideoContainer $true $info.Series $info.Season $info.Episode)
    }

    $sourceId = [string]$metadata.Id
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url

    $seriesFolder = Join-Path $BaseOutput (Safe-Name $info.Series 120)
    $seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f $info.Season)
    Ensure-Directory $seasonFolder
    $prefix = "S{0:D2}E{1:D2}" -f $info.Season, $info.Episode
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $seasonFolder ($fallbackBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $identity $desiredPath $Url $sourceId $false
    if ($decision.Skip) { return 0 }
    $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $template = "$fallbackBase.%(ext)s"

    if ($kind -eq "wcostream") {
        Write-Host ""
        Write-Host "Série:     $($info.Series)"
        Write-Host "Temporada: $($info.Season)"
        Write-Host "Episódio:  $($info.Episode)"
        Write-Host "Título:    $($info.Title)"
        Write-Host "Destino:   $seasonFolder"
        return (Invoke-WcoStream $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    Write-Host ""
    Write-Host "Série:     $($info.Series)"
    Write-Host "Temporada: $($info.Season)"
    Write-Host "Episódio:  $($info.Episode)"
    Write-Host "Título:    $($info.Title)"
    Write-Host "Destino:   $seasonFolder"

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $template
        if ($code -eq 0) {
            Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase)
    }

    $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $template
    if ($code -eq 0) {
        Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
}

function Resolve-ListUrls([object[]]$Items) {
    $values = @($Items | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }

    if ($values.Count -eq 1 -and [System.IO.Path]::GetExtension($values[0]) -ieq ".txt") {
        $listPath = Normalize-Path $values[0]
        if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { throw "Arquivo de lista não encontrado: $($values[0])" }
        $values = @(Get-Content -LiteralPath $listPath -Encoding UTF8 | ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") })
        if ($values.Count -eq 0) { throw "O arquivo de lista não contém URLs." }
    }

    return @($values)
}

function Write-BatchSummary([int]$Total, [int]$Succeeded, [int]$Failed) {
    Write-Host ""
    Write-Host "Resumo da lista:"
    Write-Host "  Total:                 $Total"
    Write-Host "  Concluídos/ignorados:  $Succeeded"
    Write-Host "  Falharam:              $Failed"
}

function Invoke-BatchSession([object]$Parsed) {
    if ($Parsed.Loop) { throw "--list e --loop não podem ser usados juntos." }
    $urls = @(Resolve-ListUrls $Parsed.ListItems)
    $resolvedOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $succeeded = 0
    $failed = 0

    Write-Info "video-dl - lista ($($urls.Count) links)"
    for ($index = 0; $index -lt $urls.Count; $index++) {
        $url = [string]$urls[$index]
        Write-Host ""
        Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
        try {
            $code = Invoke-OneDownload $url $Parsed.RequestedPath $Parsed.Here $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Playlist $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
            else { $failed++; Write-Fail "Item não concluído (código $code)." }
        } catch {
            $failed++
            Write-Fail "Item não concluído: $($_.Exception.Message)"
        }
    }

    Write-BatchSummary $urls.Count $succeeded $failed
    if ($failed -gt 0) { return 1 }
    return 0
}

function Invoke-SeriesSession([object]$Parsed) {
    if ($Parsed.Playlist) { throw "--series e --playlist representam coisas diferentes e não podem ser usados juntos." }
    if ($Parsed.Loop -and @($Parsed.ListItems).Count -gt 0) { throw "--list e --loop não podem ser usados juntos." }
    $baseOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $state = [PSCustomObject]@{ Name = $null; Season = $null; LastEpisode = $null }

    Write-Info "video-dl - modo série"
    Write-Host "Destino base: $baseOutput"
    Write-Host "O programa tenta detectar série, temporada e episódio pelos metadados."

    if (@($Parsed.ListItems).Count -gt 0) {
        $urls = @(Resolve-ListUrls $Parsed.ListItems)
        $succeeded = 0
        $failed = 0
        Write-Host "Lista: $($urls.Count) links"

        for ($index = 0; $index -lt $urls.Count; $index++) {
            $url = [string]$urls[$index]
            Write-Host ""
            Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
            try {
                $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $true
                if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
                else { $failed++; Write-Fail "Item não concluído (código $code)." }
            } catch {
                $failed++
                Write-Fail "Item não concluído: $($_.Exception.Message)"
            }
        }

        Write-BatchSummary $urls.Count $succeeded $failed
        if ($failed -gt 0) { return 1 }
        return 0
    }

    $url = [string]$Parsed.Url
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($url)) { $url = Read-Host "`nURL do próximo episódio (Enter para sair)" }
        if ([string]::IsNullOrWhiteSpace($url)) { break }
        $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $false
        if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        $url = $null
    }
    return 0
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

        $setupUrl = "https://raw.githubusercontent.com/sillasHead/video-dl/main/setup.ps1"
        $tempSetup = Join-Path $env:TEMP ("video-dl-setup-" + [Guid]::NewGuid().ToString("N") + ".ps1")
        Invoke-WebRequest -Uri $setupUrl -OutFile $tempSetup -UseBasicParsing -Headers @{ "Cache-Control" = "no-cache" }

        try {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -ne $pwsh) {
                & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            } else {
                $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
                if ($null -eq $windowsPowerShell) { throw "Nenhum PowerShell executável foi encontrado." }
                & $windowsPowerShell.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            }

            if ($exitCode -ne 0) { throw "O instalador PowerShell terminou com código $exitCode." }
        } finally {
            Remove-Item -LiteralPath $tempSetup -Force -ErrorAction SilentlyContinue
        }
        Write-Ok "Atualização concluída."
    } catch { Write-Fail "Falha ao atualizar: $($_.Exception.Message)" }
}
function Show-Help {
    @"
video-dl $Version - downloader universal

USO
  video-dl "URL"                  baixa um vídeo avulso
  video-dl --list links.txt        baixa uma lista de URLs de um arquivo TXT
  video-dl --list "URL1" "URL2"   baixa várias URLs passadas no próprio comando
  video-dl --list links.txt --series  processa a lista como episódios de uma série
  video-dl --series               modo série: cole os episódios um por um
  video-dl "URL" --series         começa a série por essa URL e pede as próximas
  video-dl                         modo interativo de vídeos avulsos

ORGANIZAÇÃO
  Avulso:  AAAA-MM-DD - Título original [1080p].ext
           usa a data original quando disponível; data atual como fallback.
  Série:   Série\Season 01\S01E01 - Título.ext
           tenta deduzir série/temporada/episódio por metadados e pelo título.
  Playlist nativa: --playlist (ex.: playlist do YouTube)

QUALIDADE / COMPATIBILIDADE
  --quality <altura>              limite de resolução (padrão: 1080)
  --max-quality                   melhor qualidade disponível, sem limite
  --wpp, -wpp, --compat           prioriza MP4 + H.264 + AAC
  fix <arquivo>                    converte vídeo existente para MP4 H.264 + AAC
  --source                        não aplica o preset de compatibilidade
  --container <mp4|mkv>           sobrescreve o container de vídeo neste download
  set-container <mp4|mkv>         muda o container padrão de vídeo

ÁUDIO
  --audio, --audio-only           baixa/extrai somente o áudio (MP3 por padrão)
  --audio-format <formato>        mp3, m4a, aac, opus, flac ou wav
  set-audio-format <formato>      muda o formato padrão de áudio

COOKIES
  --cookies <browser>             firefox, chrome, edge, brave ou auto
  --cookies-file <arquivo>        usa cookies.txt

DESTINO
  --path <nome|caminho>           escolhe destino salvo ou caminho direto
  --here                          salva na pasta atual
  --add-path <caminho>            adiciona destino
  --name <nome>                   usado junto com --add-path
  --default                       adiciona e passa a usar esse destino automaticamente
  --paths                         lista destinos
  --remove-path <nome>            remove destino
  set-default <nome>              usa esse destino automaticamente
  unset-default                   volta a perguntar quando houver mais de um destino

CONFIGURAÇÃO
  config                          abre config.json no editor (VS Code/EDITOR/Notepad)
  config show                     mostra a configuração no terminal
  config path                     mostra o caminho do arquivo
  settings                        resumo das configurações atuais
  set-quality-name <on|off>       mostra/oculta [1080p] no nome dos vídeos
  set-duplicate-policy <modo>     skip, ask, overwrite ou rename

OUTROS
  --list <arquivo.txt|URLs...>     processa várias URLs; aceita TXT ou URLs no comando
  --series                        organiza vários links como episódios de uma série
  --playlist                      baixa playlist nativa do site via yt-dlp
  --no-fallback                   não tenta downloader alternativo
  --loop                          continua pedindo links avulsos
  doctor                          verifica dependências
  install-deps                    instala dependências ausentes
  update                          atualiza pelo GitHub
  --version                       mostra a versão
  --help                          mostra esta ajuda
"@ | Write-Host
}

function Repair-WhatsAppVideo([string]$InputPath) {
    $input = Normalize-Path $InputPath
    if (-not (Test-Path -LiteralPath $input -PathType Leaf)) { throw "Arquivo não encontrado: $input" }
    if (-not (Test-Dependency "ffmpeg")) { throw "ffmpeg não encontrado. Rode: video-dl install-deps" }

    $dir = Split-Path -Parent $input
    $base = [System.IO.Path]::GetFileNameWithoutExtension($input)
    $output = Join-Path $dir ($base + " [WhatsApp].mp4")
    $n = 2
    while (Test-Path -LiteralPath $output) {
        $output = Join-Path $dir ($base + " [WhatsApp $n].mp4")
        $n++
    }

    Write-Info "Convertendo para WhatsApp: MP4 + H.264 + AAC..."
    & ffmpeg -hide_banner -y -i $input -map 0:v:0 -map '0:a:0?' -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 -movflags +faststart $output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "ffmpeg falhou ao converter o arquivo." }
    Write-Ok "Arquivo compatível criado:"
    Write-Host $output
}

function Parse-DownloadArguments([object[]]$Tokens) {
    $r = [PSCustomObject]@{
        Url = $null; ListItems = @(); RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = $null; VideoContainer = $null;
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
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
            "--container" { if (++$i -ge $Tokens.Count) { throw "--container precisa de um valor." }; $r.VideoContainer = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--quality" { if (++$i -ge $Tokens.Count) { throw "--quality precisa de um valor." }; if ([string]$Tokens[$i] -notmatch '^\d+$') { throw "--quality deve ser numérico." }; $r.Quality = [int]$Tokens[$i]; $r.MaxQuality = $false }
            "--max-quality" { $r.MaxQuality = $true; $r.Compat = $false }
            "--wpp" { $r.Compat = $true }
            "-wpp" { $r.Compat = $true }
            "--compat" { $r.Compat = $true }
            "--source" { $r.Compat = $false }
            "--cookies" { if (++$i -ge $Tokens.Count) { throw "--cookies precisa de um navegador." }; $r.CookieBrowser = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--cookies-file" { if (++$i -ge $Tokens.Count) { throw "--cookies-file precisa de um caminho." }; $r.CookieFile = Normalize-Path ([string]$Tokens[$i]) }
            "--playlist" { $r.Playlist = $true }
            "--list" {
                $listValues = @()
                while (($i + 1) -lt $Tokens.Count -and -not ([string]$Tokens[$i + 1]).StartsWith("-")) {
                    $i++
                    $listValues += [string]$Tokens[$i]
                }
                if ($listValues.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }
                $r.ListItems = @($r.ListItems) + @($listValues)
            }
            "--series" { $r.Series = $true }
            "--no-fallback" { $r.NoFallback = $true }
            "--loop" { $r.Loop = $true }
            default {
                if ($token.StartsWith("-")) { throw "Opção desconhecida: $token" }
                if ([string]::IsNullOrWhiteSpace([string]$r.Url)) { $r.Url = $token }
                else { throw "Argumento inesperado: $token" }
            }
        }
    }
    if (@($r.ListItems).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.Url)) { throw "Use uma URL posicional ou --list, não os dois ao mesmo tempo." }
    if (@($r.ListItems).Count -gt 0 -and $r.Loop) { throw "--list e --loop não podem ser usados juntos." }
    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    if ($r.VideoContainer -and $r.VideoContainer -notin @("mp4", "mkv")) { throw "--container aceita: mp4 ou mkv." }
    if ($r.AudioFormat -and $r.AudioFormat -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) { throw "--audio-format aceita: mp3, m4a, aac, opus, flac ou wav." }
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
            "fix" { if ($tokens.Count -lt 2) { throw "Uso: video-dl fix <arquivo>" }; Repair-WhatsAppVideo ([string]$tokens[1]); return }
            "paths" { Show-Paths; return }
            "--paths" { Show-Paths; return }
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
            "set-quality-name" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-quality-name <on|off>" }; Set-QualityNameCommand ([string]$tokens[1]); return }
            "set-duplicate-policy" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-duplicate-policy <skip|ask|overwrite|rename>" }; Set-DuplicatePolicyCommand ([string]$tokens[1]); return }
            "remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "--remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "--set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "unset-default" { Unset-DefaultPathCommand; return }
            "--unset-default" { Unset-DefaultPathCommand; return }
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
    $parsed = Apply-PersistentMediaSettings $parsed
    if ($parsed.Series) {
        $seriesCode = Invoke-SeriesSession $parsed
        if ($seriesCode -ne 0) { exit $seriesCode }
        return
    }

    if (@($parsed.ListItems).Count -gt 0) {
        $batchCode = Invoke-BatchSession $parsed
        if ($batchCode -ne 0) { exit $batchCode }
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$parsed.Url)) {
        Write-Info "video-dl - modo interativo"
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nCole uma URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
        return
    }

    $code = Invoke-OneDownload $parsed.Url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $null
    if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }

    if ($parsed.Loop) {
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nPróxima URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
    }
} catch {
    Write-Fail "ERRO: $($_.Exception.Message)"
    Write-Host "Use 'video-dl --help' para ver os comandos."
    exit 1
}











) { return "youtube" }
    return "generic"
}

function Get-WcoMetadata([string]$Url) {
    $info = [PSCustomObject]@{
        Title = "Vídeo"; Series = $null; SeriesConfidence = "nenhuma";
        SeasonNumber = 1; EpisodeNumber = $null; Date = (Get-Date -Format "yyyy-MM-dd"); Id = $null;
        Source = "wcostream-url"
    }
    try {
        $slug = [Uri]::UnescapeDataString(([Uri]$Url).AbsolutePath.Trim('/'))
        if ($slug -match '(?i)^(.+?)-episode-(\d+)(?:-(.*))?$') {
            $seriesSlug = $Matches[1]
            $info.EpisodeNumber = [int]$Matches[2]
            $titleSlug = [string]$Matches[3]
            $info.Series = (($seriesSlug -split '-' | Where-Object { $_ } | ForEach-Object {
                if ($_.Length -gt 1) { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) } else { $_.ToUpperInvariant() }
            }) -join ' ')
            $info.SeriesConfidence = "média"
            if (-not [string]::IsNullOrWhiteSpace($titleSlug)) {
                $info.Title = (($titleSlug -split '-' | Where-Object { $_ }) -join ' ')
            } else { $info.Title = "Episódio $($info.EpisodeNumber)" }
            $info.Id = $slug
        }
    } catch { }
    return $info
}

function Invoke-WcoStream(
    [string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [string]$FileBase, [string]$Identity, [string]$SourceId
) {
    if ($AudioOnly) { Write-Warn "WCOStream: --audio ainda não é suportado."; return 1 }
    if (-not (Test-Path -LiteralPath $WcoDlPath -PathType Leaf)) { throw "wcostream-dl.ps1 não encontrado." }
    $desired = Join-Path $OutputDir ($FileBase + ".mp4")
    $decision = Resolve-VideoDlTarget $Identity $desired $Url $SourceId $false
    if ($decision.Skip) { return 0 }
    $target = [string]$decision.Path
    & $WcoDlPath -Url $Url -OutputPath $target
    if (-not $?) { return 1 }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $final = Add-QualitySuffix $target
        Register-VideoDlDownload $Identity $final $Url $SourceId
        return 0
    }
    return 1
}

function Get-AvulsoNaming([string]$Url, [string]$CookieBrowser, [string]$CookieFile) {
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $false
    $date = if ($null -ne $metadata) { [string]$metadata.Date } else { Get-Date -Format "yyyy-MM-dd" }
    $title = if ($null -ne $metadata) { [string]$metadata.Title } else { "Vídeo" }
    $sourceId = if ($null -ne $metadata) { [string]$metadata.Id } else { $null }
    $fileBase = "$date - $(Safe-Name $title 155)"
    $template = "$fileBase.%(ext)s"
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
    return [PSCustomObject]@{
        Metadata = $metadata
        FileBase = $fileBase
        Template = $template
        Identity = $identity
        SourceId = $sourceId
    }
}

function Register-YtDlpResult([string]$Identity, [string]$Url, [string]$SourceId, [string]$OutputDir, [string]$FileBase) {
    $result = Find-VideoDlOutputForBase $OutputDir $FileBase
    if ($null -ne $result) { Register-VideoDlDownload $Identity $result.FullName $Url $SourceId }
}

function Invoke-OneDownload(
    [string]$Url, [string]$RequestedPath, [bool]$Here, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [bool]$Playlist, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [string]$ResolvedOutput
) {
    $output = if ([string]::IsNullOrWhiteSpace($ResolvedOutput)) { Resolve-OutputPath $RequestedPath $Here } else { $ResolvedOutput }
    Ensure-Directory $output
    Write-Host ""
    Write-Host "Destino: $output"
    $kind = Get-SiteKind $Url

    if ($kind -eq "pluto") { return (Invoke-Pluto $Url $output $AudioOnly $AudioFormat $VideoContainer $false) }
    if ($kind -eq "wcostream") {
        $metadata = Get-WcoMetadata $Url
        $sourceId = [string]$metadata.Id
        $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url
        $fileBase = "$(Get-Date -Format 'yyyy-MM-dd') - $(Safe-Name ([string]$metadata.Title) 155)"
        return (Invoke-WcoStream $Url $output $AudioOnly $AudioFormat $VideoContainer $fileBase $identity $sourceId)
    }

    if ($Playlist) {
        $playlistTemplate = "%(playlist_title).120B\%(playlist_index)03d - %(title).150B.%(ext)s"
        return (Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $true $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $playlistTemplate)
    }

    $naming = Get-AvulsoNaming $Url $CookieBrowser $CookieFile
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $output ($naming.FileBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $naming.Identity $desiredPath $Url $naming.SourceId $false
    if ($decision.Skip) { return 0 }
    $naming.FileBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $naming.Template = "$($naming.FileBase).%(ext)s"

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
    }

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $naming.Template
        if ($code -eq 0) {
            Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase)
    }

    $code = Invoke-YtDlpDownload $Url $output $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $naming.Template
    if ($code -eq 0) {
        Register-YtDlpResult $naming.Identity $Url $naming.SourceId $output $naming.FileBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $output $AudioOnly $AudioFormat $VideoContainer $naming.FileBase $naming.Identity $naming.SourceId)
}

function Read-RequiredText([string]$Prompt, [string]$DefaultValue) {
    while ($true) {
        $label = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $DefaultValue }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
}

function Read-RequiredNumber([string]$Prompt, [Nullable[int]]$DefaultValue) {
    while ($true) {
        $label = if ($null -eq $DefaultValue) { $Prompt } else { "$Prompt [$DefaultValue]" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value) -and $null -ne $DefaultValue) { return [int]$DefaultValue }
        if ($value -match '^\d+$' -and [int]$value -ge 0) { return [int]$value }
        Write-Warn "Digite um número válido."
    }
}

function Resolve-SeriesInfo([object]$Metadata, [object]$State, [bool]$AutoSequence = $false) {
    $series = [string]$Metadata.Series
    $confidence = [string]$Metadata.SeriesConfidence

    if (-not [string]::IsNullOrWhiteSpace([string]$State.Name)) {
        if ([string]::IsNullOrWhiteSpace($series) -or $confidence -eq "baixa") {
            $series = [string]$State.Name
        } elseif ($series -ine [string]$State.Name) {
            Write-Warn "O link parece ser de outra série: '$series'."
            $switchSeries = Read-Host "Trocar da série '$($State.Name)' para '$series'? [s/N]"
            if (-not (Test-Yes $switchSeries $false)) { $series = [string]$State.Name }
            else { $State.Season = $null; $State.LastEpisode = $null }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($series) -and $confidence -ne "alta") {
        $answer = Read-Host "Série detectada: '$series' ($confidence confiança). Usar? [S/n]"
        if (-not (Test-Yes $answer $true)) { $series = $null }
    }

    if ([string]::IsNullOrWhiteSpace($series)) { $series = Read-RequiredText "Nome da série" ([string]$State.Name) }

    $season = $Metadata.SeasonNumber
    if ($null -eq $season) { $season = $State.Season }
    if ($null -eq $season) { $season = Read-RequiredNumber "Temporada" 1 }

    $episode = $Metadata.EpisodeNumber
    if ($null -eq $episode) {
        $next = $null
        if ($null -ne $State.LastEpisode -and $null -ne $State.Season -and [int]$State.Season -eq [int]$season) { $next = [int]$State.LastEpisode + 1 }
        if ($AutoSequence -and $null -ne $next) { $episode = [int]$next }
        else { $episode = Read-RequiredNumber "Número do episódio" $next }
    }

    $title = [string]$Metadata.Title
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "Episódio $episode" }

    $State.Name = $series
    $State.Season = [int]$season
    $State.LastEpisode = [int]$episode

    return [PSCustomObject]@{
        Series = $series; Season = [int]$season; Episode = [int]$episode; Title = $title
    }
}

function Invoke-SeriesItem(
    [string]$Url, [string]$BaseOutput, [object]$State, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer,
    [bool]$NoFallback, [int]$Quality, [bool]$MaxQuality, [bool]$Compat,
    [string]$CookieBrowser, [string]$CookieFile, [bool]$AutoSequence = $false
) {
    $kind = Get-SiteKind $Url

    if ($kind -ne "pluto" -and -not (Test-Dependency "yt-dlp")) { [void](Ensure-Dependency "yt-dlp" "detecção de metadados de séries") }
    $metadata = Get-LinkMetadata $Url $CookieBrowser $CookieFile $true
    $info = Resolve-SeriesInfo $metadata $State $AutoSequence

    if ($kind -eq "pluto") {
        return (Invoke-Pluto $Url $BaseOutput $AudioOnly $AudioFormat $VideoContainer $true $info.Series $info.Season $info.Episode)
    }

    $sourceId = [string]$metadata.Id
    $identity = Get-VideoDlIdentity (Get-UrlHost $Url) $sourceId $Url

    $seriesFolder = Join-Path $BaseOutput (Safe-Name $info.Series 120)
    $seasonFolder = Join-Path $seriesFolder ("Season {0:D2}" -f $info.Season)
    Ensure-Directory $seasonFolder
    $prefix = "S{0:D2}E{1:D2}" -f $info.Season, $info.Episode
    $fallbackBase = "$prefix - $(Safe-Name $info.Title 160)"
    $expectedExt = if ($AudioOnly) { $AudioFormat } else { $VideoContainer }
    $desiredPath = Join-Path $seasonFolder ($fallbackBase + "." + $expectedExt)
    $decision = Resolve-VideoDlTarget $identity $desiredPath $Url $sourceId $false
    if ($decision.Skip) { return 0 }
    $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$decision.Path)
    $template = "$fallbackBase.%(ext)s"

    if ($kind -eq "wcostream") {
        Write-Host ""
        Write-Host "Série:     $($info.Series)"
        Write-Host "Temporada: $($info.Season)"
        Write-Host "Episódio:  $($info.Episode)"
        Write-Host "Título:    $($info.Title)"
        Write-Host "Destino:   $seasonFolder"
        return (Invoke-WcoStream $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    if ((Test-YtDlpUnsupportedForSession $Url) -and $kind -notin @("threads", "pluto")) {
        if ($NoFallback) {
            Write-Warn "yt-dlp informou que este domínio não é suportado; --no-fallback impede a tentativa alternativa."
            return 1
        }
        Write-Info "yt-dlp não suporta este domínio nesta sessão. Indo direto para Streamlink."
        return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
    }

    Write-Host ""
    Write-Host "Série:     $($info.Series)"
    Write-Host "Temporada: $($info.Season)"
    Write-Host "Episódio:  $($info.Episode)"
    Write-Host "Título:    $($info.Title)"
    Write-Host "Destino:   $seasonFolder"

    if ($kind -eq "threads") {
        $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $false $template
        if ($code -eq 0) {
            Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
            return 0
        }
        if ($NoFallback) { return $code }
        Write-Warn "yt-dlp falhou no Threads. Tentando fallback específico..."
        return (Invoke-ThreadsFallback $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase)
    }

    $code = Invoke-YtDlpDownload $Url $seasonFolder $AudioOnly $AudioFormat $false $Quality $MaxQuality $Compat $VideoContainer $CookieBrowser $CookieFile $true $template
    if ($code -eq 0) {
        Register-YtDlpResult $identity $Url $sourceId $seasonFolder $fallbackBase
        return 0
    }
    if ($NoFallback) { return $code }
    Write-Warn "yt-dlp não conseguiu baixar. Tentando Streamlink..."
    return (Invoke-GenericStreamlink $Url $seasonFolder $AudioOnly $AudioFormat $VideoContainer $fallbackBase $identity $sourceId)
}

function Resolve-ListUrls([object[]]$Items) {
    $values = @($Items | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }

    if ($values.Count -eq 1 -and [System.IO.Path]::GetExtension($values[0]) -ieq ".txt") {
        $listPath = Normalize-Path $values[0]
        if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { throw "Arquivo de lista não encontrado: $($values[0])" }
        $values = @(Get-Content -LiteralPath $listPath -Encoding UTF8 | ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") })
        if ($values.Count -eq 0) { throw "O arquivo de lista não contém URLs." }
    }

    return @($values)
}

function Write-BatchSummary([int]$Total, [int]$Succeeded, [int]$Failed) {
    Write-Host ""
    Write-Host "Resumo da lista:"
    Write-Host "  Total:                 $Total"
    Write-Host "  Concluídos/ignorados:  $Succeeded"
    Write-Host "  Falharam:              $Failed"
}

function Invoke-BatchSession([object]$Parsed) {
    if ($Parsed.Loop) { throw "--list e --loop não podem ser usados juntos." }
    $urls = @(Resolve-ListUrls $Parsed.ListItems)
    $resolvedOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $succeeded = 0
    $failed = 0

    Write-Info "video-dl - lista ($($urls.Count) links)"
    for ($index = 0; $index -lt $urls.Count; $index++) {
        $url = [string]$urls[$index]
        Write-Host ""
        Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
        try {
            $code = Invoke-OneDownload $url $Parsed.RequestedPath $Parsed.Here $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Playlist $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
            else { $failed++; Write-Fail "Item não concluído (código $code)." }
        } catch {
            $failed++
            Write-Fail "Item não concluído: $($_.Exception.Message)"
        }
    }

    Write-BatchSummary $urls.Count $succeeded $failed
    if ($failed -gt 0) { return 1 }
    return 0
}

function Invoke-SeriesSession([object]$Parsed) {
    if ($Parsed.Playlist) { throw "--series e --playlist representam coisas diferentes e não podem ser usados juntos." }
    if ($Parsed.Loop -and @($Parsed.ListItems).Count -gt 0) { throw "--list e --loop não podem ser usados juntos." }
    $baseOutput = Resolve-OutputPath $Parsed.RequestedPath $Parsed.Here
    $state = [PSCustomObject]@{ Name = $null; Season = $null; LastEpisode = $null }

    Write-Info "video-dl - modo série"
    Write-Host "Destino base: $baseOutput"
    Write-Host "O programa tenta detectar série, temporada e episódio pelos metadados."

    if (@($Parsed.ListItems).Count -gt 0) {
        $urls = @(Resolve-ListUrls $Parsed.ListItems)
        $succeeded = 0
        $failed = 0
        Write-Host "Lista: $($urls.Count) links"

        for ($index = 0; $index -lt $urls.Count; $index++) {
            $url = [string]$urls[$index]
            Write-Host ""
            Write-Info ("[{0}/{1}] {2}" -f ($index + 1), $urls.Count, $url)
            try {
                $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $true
                if ($code -eq 0) { $succeeded++; Write-Ok "Item concluído." }
                else { $failed++; Write-Fail "Item não concluído (código $code)." }
            } catch {
                $failed++
                Write-Fail "Item não concluído: $($_.Exception.Message)"
            }
        }

        Write-BatchSummary $urls.Count $succeeded $failed
        if ($failed -gt 0) { return 1 }
        return 0
    }

    $url = [string]$Parsed.Url
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($url)) { $url = Read-Host "`nURL do próximo episódio (Enter para sair)" }
        if ([string]::IsNullOrWhiteSpace($url)) { break }
        $code = Invoke-SeriesItem $url $baseOutput $state $Parsed.AudioOnly $Parsed.AudioFormat $Parsed.VideoContainer $Parsed.NoFallback $Parsed.Quality $Parsed.MaxQuality $Parsed.Compat $Parsed.CookieBrowser $Parsed.CookieFile $false
        if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        $url = $null
    }
    return 0
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

        $setupUrl = "https://raw.githubusercontent.com/sillasHead/video-dl/main/setup.ps1"
        $tempSetup = Join-Path $env:TEMP ("video-dl-setup-" + [Guid]::NewGuid().ToString("N") + ".ps1")
        Invoke-WebRequest -Uri $setupUrl -OutFile $tempSetup -UseBasicParsing -Headers @{ "Cache-Control" = "no-cache" }

        try {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -ne $pwsh) {
                & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            } else {
                $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
                if ($null -eq $windowsPowerShell) { throw "Nenhum PowerShell executável foi encontrado." }
                & $windowsPowerShell.Source -NoProfile -ExecutionPolicy Bypass -File $tempSetup
                $exitCode = [int]$LASTEXITCODE
            }

            if ($exitCode -ne 0) { throw "O instalador PowerShell terminou com código $exitCode." }
        } finally {
            Remove-Item -LiteralPath $tempSetup -Force -ErrorAction SilentlyContinue
        }
        Write-Ok "Atualização concluída."
    } catch { Write-Fail "Falha ao atualizar: $($_.Exception.Message)" }
}
function Show-Help {
    @"
video-dl $Version - downloader universal

USO
  video-dl "URL"                  baixa um vídeo avulso
  video-dl --list links.txt        baixa uma lista de URLs de um arquivo TXT
  video-dl --list "URL1" "URL2"   baixa várias URLs passadas no próprio comando
  video-dl --list links.txt --series  processa a lista como episódios de uma série
  video-dl --series               modo série: cole os episódios um por um
  video-dl "URL" --series         começa a série por essa URL e pede as próximas
  video-dl                         modo interativo de vídeos avulsos

ORGANIZAÇÃO
  Avulso:  AAAA-MM-DD - Título original [1080p].ext
           usa a data original quando disponível; data atual como fallback.
  Série:   Série\Season 01\S01E01 - Título.ext
           tenta deduzir série/temporada/episódio por metadados e pelo título.
  Playlist nativa: --playlist (ex.: playlist do YouTube)

QUALIDADE / COMPATIBILIDADE
  --quality <altura>              limite de resolução (padrão: 1080)
  --max-quality                   melhor qualidade disponível, sem limite
  --wpp, -wpp, --compat           prioriza MP4 + H.264 + AAC
  fix <arquivo>                    converte vídeo existente para MP4 H.264 + AAC
  --source                        não aplica o preset de compatibilidade
  --container <mp4|mkv>           sobrescreve o container de vídeo neste download
  set-container <mp4|mkv>         muda o container padrão de vídeo

ÁUDIO
  --audio, --audio-only           baixa/extrai somente o áudio (MP3 por padrão)
  --audio-format <formato>        mp3, m4a, aac, opus, flac ou wav
  set-audio-format <formato>      muda o formato padrão de áudio

COOKIES
  --cookies <browser>             firefox, chrome, edge, brave ou auto
  --cookies-file <arquivo>        usa cookies.txt

DESTINO
  --path <nome|caminho>           escolhe destino salvo ou caminho direto
  --here                          salva na pasta atual
  --add-path <caminho>            adiciona destino
  --name <nome>                   usado junto com --add-path
  --default                       adiciona e passa a usar esse destino automaticamente
  --paths                         lista destinos
  --remove-path <nome>            remove destino
  set-default <nome>              usa esse destino automaticamente
  unset-default                   volta a perguntar quando houver mais de um destino

CONFIGURAÇÃO
  config                          abre config.json no editor (VS Code/EDITOR/Notepad)
  config show                     mostra a configuração no terminal
  config path                     mostra o caminho do arquivo
  settings                        resumo das configurações atuais
  set-quality-name <on|off>       mostra/oculta [1080p] no nome dos vídeos
  set-duplicate-policy <modo>     skip, ask, overwrite ou rename

OUTROS
  --list <arquivo.txt|URLs...>     processa várias URLs; aceita TXT ou URLs no comando
  --series                        organiza vários links como episódios de uma série
  --playlist                      baixa playlist nativa do site via yt-dlp
  --no-fallback                   não tenta downloader alternativo
  --loop                          continua pedindo links avulsos
  doctor                          verifica dependências
  install-deps                    instala dependências ausentes
  update                          atualiza pelo GitHub
  --version                       mostra a versão
  --help                          mostra esta ajuda
"@ | Write-Host
}

function Repair-WhatsAppVideo([string]$InputPath) {
    $input = Normalize-Path $InputPath
    if (-not (Test-Path -LiteralPath $input -PathType Leaf)) { throw "Arquivo não encontrado: $input" }
    if (-not (Test-Dependency "ffmpeg")) { throw "ffmpeg não encontrado. Rode: video-dl install-deps" }

    $dir = Split-Path -Parent $input
    $base = [System.IO.Path]::GetFileNameWithoutExtension($input)
    $output = Join-Path $dir ($base + " [WhatsApp].mp4")
    $n = 2
    while (Test-Path -LiteralPath $output) {
        $output = Join-Path $dir ($base + " [WhatsApp $n].mp4")
        $n++
    }

    Write-Info "Convertendo para WhatsApp: MP4 + H.264 + AAC..."
    & ffmpeg -hide_banner -y -i $input -map 0:v:0 -map '0:a:0?' -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 -movflags +faststart $output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "ffmpeg falhou ao converter o arquivo." }
    Write-Ok "Arquivo compatível criado:"
    Write-Host $output
}

function Parse-DownloadArguments([object[]]$Tokens) {
    $r = [PSCustomObject]@{
        Url = $null; ListItems = @(); RequestedPath = $null; Here = $false; AudioOnly = $false; AudioFormat = $null; VideoContainer = $null;
        NoFallback = $false; Playlist = $false; Series = $false; Loop = $false; Quality = 1080; MaxQuality = $false;
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
            "--container" { if (++$i -ge $Tokens.Count) { throw "--container precisa de um valor." }; $r.VideoContainer = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--quality" { if (++$i -ge $Tokens.Count) { throw "--quality precisa de um valor." }; if ([string]$Tokens[$i] -notmatch '^\d+$') { throw "--quality deve ser numérico." }; $r.Quality = [int]$Tokens[$i]; $r.MaxQuality = $false }
            "--max-quality" { $r.MaxQuality = $true; $r.Compat = $false }
            "--wpp" { $r.Compat = $true }
            "-wpp" { $r.Compat = $true }
            "--compat" { $r.Compat = $true }
            "--source" { $r.Compat = $false }
            "--cookies" { if (++$i -ge $Tokens.Count) { throw "--cookies precisa de um navegador." }; $r.CookieBrowser = ([string]$Tokens[$i]).ToLowerInvariant() }
            "--cookies-file" { if (++$i -ge $Tokens.Count) { throw "--cookies-file precisa de um caminho." }; $r.CookieFile = Normalize-Path ([string]$Tokens[$i]) }
            "--playlist" { $r.Playlist = $true }
            "--list" {
                $listValues = @()
                while (($i + 1) -lt $Tokens.Count -and -not ([string]$Tokens[$i + 1]).StartsWith("-")) {
                    $i++
                    $listValues += [string]$Tokens[$i]
                }
                if ($listValues.Count -eq 0) { throw "--list precisa de pelo menos uma URL ou de um arquivo .txt." }
                $r.ListItems = @($r.ListItems) + @($listValues)
            }
            "--series" { $r.Series = $true }
            "--no-fallback" { $r.NoFallback = $true }
            "--loop" { $r.Loop = $true }
            default {
                if ($token.StartsWith("-")) { throw "Opção desconhecida: $token" }
                if ([string]::IsNullOrWhiteSpace([string]$r.Url)) { $r.Url = $token }
                else { throw "Argumento inesperado: $token" }
            }
        }
    }
    if (@($r.ListItems).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.Url)) { throw "Use uma URL posicional ou --list, não os dois ao mesmo tempo." }
    if (@($r.ListItems).Count -gt 0 -and $r.Loop) { throw "--list e --loop não podem ser usados juntos." }
    if ($r.CookieBrowser -and $r.CookieBrowser -notin @("auto", "firefox", "chrome", "edge", "brave")) { throw "--cookies aceita: auto, firefox, chrome, edge ou brave." }
    if ($r.VideoContainer -and $r.VideoContainer -notin @("mp4", "mkv")) { throw "--container aceita: mp4 ou mkv." }
    if ($r.AudioFormat -and $r.AudioFormat -notin @("mp3", "m4a", "aac", "opus", "flac", "wav")) { throw "--audio-format aceita: mp3, m4a, aac, opus, flac ou wav." }
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
            "fix" { if ($tokens.Count -lt 2) { throw "Uso: video-dl fix <arquivo>" }; Repair-WhatsAppVideo ([string]$tokens[1]); return }
            "paths" { Show-Paths; return }
            "--paths" { Show-Paths; return }
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
            "set-quality-name" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-quality-name <on|off>" }; Set-QualityNameCommand ([string]$tokens[1]); return }
            "set-duplicate-policy" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-duplicate-policy <skip|ask|overwrite|rename>" }; Set-DuplicatePolicyCommand ([string]$tokens[1]); return }
            "remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "--remove-path" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --remove-path <nome>" }; Remove-PathCommand ([string]$tokens[1]); return }
            "set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "--set-default" { if ($tokens.Count -lt 2) { throw "Uso: video-dl --set-default <nome>" }; Set-DefaultPathCommand ([string]$tokens[1]); return }
            "unset-default" { Unset-DefaultPathCommand; return }
            "--unset-default" { Unset-DefaultPathCommand; return }
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
    $parsed = Apply-PersistentMediaSettings $parsed
    if ($parsed.Series) {
        $seriesCode = Invoke-SeriesSession $parsed
        if ($seriesCode -ne 0) { exit $seriesCode }
        return
    }

    if (@($parsed.ListItems).Count -gt 0) {
        $batchCode = Invoke-BatchSession $parsed
        if ($batchCode -ne 0) { exit $batchCode }
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$parsed.Url)) {
        Write-Info "video-dl - modo interativo"
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nCole uma URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
        return
    }

    $code = Invoke-OneDownload $parsed.Url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $null
    if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }

    if ($parsed.Loop) {
        $resolvedOutput = Resolve-OutputPath $parsed.RequestedPath $parsed.Here
        while ($true) {
            $url = Read-Host "`nPróxima URL (Enter para sair)"
            if ([string]::IsNullOrWhiteSpace($url)) { break }
            $code = Invoke-OneDownload $url $parsed.RequestedPath $parsed.Here $parsed.AudioOnly $parsed.AudioFormat $parsed.VideoContainer $parsed.NoFallback $parsed.Playlist $parsed.Quality $parsed.MaxQuality $parsed.Compat $parsed.CookieBrowser $parsed.CookieFile $resolvedOutput
            if ($code -eq 0) { Write-Ok "`nDownload concluído." } else { Write-Fail "`nDownload não concluído (código $code)." }
        }
    }
} catch {
    Write-Fail "ERRO: $($_.Exception.Message)"
    Write-Host "Use 'video-dl --help' para ver os comandos."
    exit 1
}











