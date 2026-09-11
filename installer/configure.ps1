$ErrorActionPreference = "Stop"

$binDir = Join-Path $env:LOCALAPPDATA "video-dl\bin"
$legacyDir = Join-Path $HOME "Documents\WindowsPowerShell\Scripts\video-dl"

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

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$parts = @()
if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    $parts = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

if ($parts -notcontains $binDir) {
    $newPath = (@($parts) + @($binDir)) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
}
