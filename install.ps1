$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "O video-dl atualmente suporta instalação automática apenas no Windows."
}

$downloadUrl = "https://github.com/sillasHead/video-dl/releases/latest/download/video-dl-setup.exe"
$tempSetup = Join-Path $env:TEMP ("video-dl-setup-" + [Guid]::NewGuid().ToString("N") + ".exe")

try {
    Write-Host "Baixando video-dl..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempSetup -UseBasicParsing

    Write-Host "Instalando/atualizando..." -ForegroundColor Cyan
    $process = Start-Process -FilePath $tempSetup -ArgumentList @(
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/NORESTART"
    ) -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        throw "O instalador terminou com código $($process.ExitCode)."
    }

    Write-Host ""
    Write-Host "video-dl instalado." -ForegroundColor Green
    Write-Host "Abra um terminal novo e rode: video-dl --help"
}
finally {
    Remove-Item -LiteralPath $tempSetup -Force -ErrorAction SilentlyContinue
}
