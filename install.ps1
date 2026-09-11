$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "O video-dl atualmente suporta instalação automática apenas no Windows."
}

$downloadUrl = "https://github.com/sillasHead/video-dl/releases/latest/download/video-dl-setup.exe"
$tempSetup = Join-Path $env:TEMP ("video-dl-setup-" + [Guid]::NewGuid().ToString("N") + ".exe")
$setupLog = Join-Path $env:TEMP "video-dl-setup.log"

try {
    Write-Host "Baixando video-dl..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempSetup -UseBasicParsing

    Remove-Item -LiteralPath $setupLog -Force -ErrorAction SilentlyContinue

    Write-Host "Instalando/atualizando..." -ForegroundColor Cyan
    $process = Start-Process -FilePath $tempSetup -ArgumentList @(
        "/VERYSILENT",
        "/NORESTART",
        "/LOG=$setupLog"
    ) -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Host ""
        Write-Host "O instalador não conseguiu concluir (código $($process.ExitCode))." -ForegroundColor Red

        if ($process.ExitCode -eq 1) {
            Write-Host "Código 1 = o instalador falhou ainda na inicialização." -ForegroundColor Yellow
        }

        if (Test-Path -LiteralPath $setupLog -PathType Leaf) {
            Write-Host ""
            Write-Host "Últimas linhas do log:" -ForegroundColor Yellow
            Get-Content -LiteralPath $setupLog -Tail 35 | ForEach-Object { Write-Host $_ }
            Write-Host ""
            Write-Host "Log completo: $setupLog" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Nenhum log chegou a ser criado; a falha ocorreu antes do Setup inicializar." -ForegroundColor Yellow
        }

        throw "Falha ao instalar o video-dl."
    }

    Remove-Item -LiteralPath $setupLog -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "video-dl instalado." -ForegroundColor Green
    Write-Host "Abra um terminal novo e rode: video-dl --version"
}
finally {
    Remove-Item -LiteralPath $tempSetup -Force -ErrorAction SilentlyContinue
}
