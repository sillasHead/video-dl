$ErrorActionPreference = "Stop"
$path = "src/video-dl.ps1"
$content = Get-Content -LiteralPath $path -Raw
$pattern = 'function Update-VideoDl \{.*(?=function Show-Help)'
$regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $regex.IsMatch($content)) { throw "Update-VideoDl corrompido não encontrado." }
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
Set-Content -LiteralPath $path -Value $content -Encoding UTF8
