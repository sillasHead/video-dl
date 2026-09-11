$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "O video-dl atualmente suporta instalação automática apenas no Windows."
}

$repo = "sillasHead/video-dl"
$root = Join-Path $env:LOCALAPPDATA "video-dl"
$appDir = Join-Path $root "app"
$binDir = Join-Path $root "bin"
$legacyDir = Join-Path $HOME "Documents\WindowsPowerShell\Scripts\video-dl"
$tempDir = Join-Path $env:TEMP ("video-dl-install-" + [Guid]::NewGuid().ToString("N"))

function Ensure-Directory([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue -PathType Container)) {
        New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
    }
}

try {
    Write-Host "Consultando versão mais recente..." -ForegroundColor Cyan
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ "User-Agent" = "video-dl-installer" }
    $tag = [string]$release.tag_name
    if ([string]::IsNullOrWhiteSpace($tag)) { throw "Não foi possível descobrir a versão mais recente." }

    Write-Host "Instalando video-dl $tag..." -ForegroundColor Cyan
    Ensure-Directory $tempDir

    $downloads = @(
        @{ Remote = "src/video-dl.ps1"; Local = "video-dl.ps1" },
        @{ Remote = "src/pluto-dl.ps1"; Local = "pluto-dl.ps1" },
        @{ Remote = "src/th-dl.ps1"; Local = "th-dl.ps1" },
        @{ Remote = "installer/video-dl.cmd"; Local = "video-dl.cmd" }
    )

    foreach ($item in $downloads) {
        $url = "https://raw.githubusercontent.com/$repo/$tag/$($item.Remote)"
        $target = Join-Path $tempDir $item.Local
        Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-Item -LiteralPath $target).Length -eq 0) {
            throw "Falha ao baixar $($item.Remote)."
        }
    }

    if (Test-Path -LiteralPath $legacyDir) {
        Remove-Item -LiteralPath $legacyDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $profiles = @(
        (Join-Path $HOME "Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"),
        (Join-Path $HOME "Documents\PowerShell\Microsoft.PowerShell_profile.ps1")
    )

    foreach ($profilePath in $profiles) {
        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { continue }
        try {
            $text = Get-Content -LiteralPath $profilePath -Raw -ErrorAction Stop
            $pattern = '(?ms)\r?\n?\s*#\s*video-dl\s*\r?\n\s*function\s+video-dl\s*\{.*?\r?\n\s*\}\s*'
            $updated = [regex]::Replace($text, $pattern, "`r`n")
            if ($updated -ne $text) {
                Set-Content -LiteralPath $profilePath -Value $updated.TrimEnd() -Encoding UTF8
            }
        } catch { }
    }

    if (Test-Path -LiteralPath $appDir) {
        Remove-Item -LiteralPath $appDir -Recurse -Force
    }
    Ensure-Directory $appDir
    Ensure-Directory $binDir

    Copy-Item -LiteralPath (Join-Path $tempDir "video-dl.ps1") -Destination (Join-Path $appDir "video-dl.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $tempDir "pluto-dl.ps1") -Destination (Join-Path $appDir "pluto-dl.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $tempDir "th-dl.ps1") -Destination (Join-Path $appDir "th-dl.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $tempDir "video-dl.cmd") -Destination (Join-Path $binDir "video-dl.cmd") -Force

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $parts = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($parts -notcontains $binDir) {
        [Environment]::SetEnvironmentVariable("Path", ((@($parts) + @($binDir)) -join ';'), "User")
    }

    if (($env:PATH -split ';') -notcontains $binDir) {
        $env:PATH = "$binDir;$env:PATH"
    }

    Remove-Item Function:\video-dl -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "video-dl $($tag.TrimStart('v')) instalado." -ForegroundColor Green
    Write-Host "Configurações e dependências em %USERPROFILE%\.video-dl foram preservadas."
    Write-Host ""
    Write-Host "Teste agora com:" -ForegroundColor Cyan
    Write-Host "  video-dl --version"
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
