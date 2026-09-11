$ErrorActionPreference = "Stop"
$path = "src/video-dl.ps1"
$content = Get-Content -LiteralPath $path -Raw

function Replace-Required([string]$Old, [string]$New, [string]$Label) {
    if (-not $script:content.Contains($Old)) { throw "Trecho não encontrado: $Label" }
    $script:content = $script:content.Replace($Old, $New)
}

# Keep Update-VideoDl clean and avoid .NET replacement-string expansion of PowerShell variables.
$pattern = 'function Update-VideoDl \{.*?(?=function Show-Help)'
$regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $regex.IsMatch($content)) { throw "Update-VideoDl não encontrado." }
$replacement = @'
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

'@
$content = $regex.Replace($content, { param($match) $replacement }, 1)

# Capturing yt-dlp stderr must work in both Windows PowerShell and PowerShell 7.
$pattern = 'function Invoke-YtDlpCapture\(\[object\[\]\]\$Arguments\) \{.*?\n\}'
$regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $regex.IsMatch($content)) { throw "Invoke-YtDlpCapture não encontrado." }
$replacement = @'
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
'@
$content = $regex.Replace($content, { param($match) $replacement }, 1)

# Generic Streamlink audio uses explicit codecs just like Pluto/Threads.
$old = @'
        & ffmpeg -y -i $temp -vn $target | Out-Host
        $ffCode = [int]$LASTEXITCODE
'@
$new = @'
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
'@
Replace-Required $old $new 'Streamlink explicit audio codecs'

# For Pluto video output, offer FFmpeg installation before falling back to raw TS.
$old = @'
function Invoke-Pluto([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer, [bool]$SeriesMode) {
    if (-not (Ensure-Dependency "streamlink" "Pluto TV")) { return 127 }
    if ($AudioOnly -and -not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
    if (-not (Test-Path -LiteralPath $PlutoDlPath)) { throw "pluto-dl.ps1 não encontrado." }
'@
$new = @'
function Invoke-Pluto([string]$Url, [string]$OutputDir, [bool]$AudioOnly, [string]$AudioFormat, [string]$VideoContainer, [bool]$SeriesMode) {
    if (-not (Ensure-Dependency "streamlink" "Pluto TV")) { return 127 }
    if ($AudioOnly -and -not (Ensure-Dependency "ffmpeg" "extração de áudio")) { return 127 }
    if (-not $AudioOnly -and -not (Test-Dependency "ffmpeg")) {
        Write-Warn "FFmpeg é necessário para finalizar o vídeo em $VideoContainer."
        $answer = Read-Host "Instalar FFmpeg agora? [S/n]"
        if (Test-Yes $answer $true) { [void](Install-Ffmpeg) }
        if (-not (Test-Dependency "ffmpeg")) { Write-Warn "Sem FFmpeg, a Pluto será salva em .ts como fallback." }
    }
    if (-not (Test-Path -LiteralPath $PlutoDlPath)) { throw "pluto-dl.ps1 não encontrado." }
'@
Replace-Required $old $new 'Pluto FFmpeg prompt'

Set-Content -LiteralPath $path -Value $content.TrimEnd() -Encoding UTF8
