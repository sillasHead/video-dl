$ErrorActionPreference = "Stop"

$sourcePath = Join-Path $PSScriptRoot "..\src\video-dl.ps1"
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8

function Assert-Contains([string]$Needle, [string]$Message) {
    if (-not $source.Contains($Needle)) { throw $Message }
}

Assert-Contains 'if ($siteKind -eq "instagram") {' "Instagram precisa ter tratamento específico no preset compatível."
Assert-Contains 'function Convert-VideoDlToWhatsAppCompatible' "Conversao automatica para WhatsApp nao encontrada."
Assert-Contains 'Convert-VideoDlResultForWhatsApp $output $naming.FileBase' "Download avulso do Instagram não chama a conversão para WhatsApp."
Assert-Contains 'Convert-VideoDlResultForWhatsApp $seasonFolder $fallbackBase' "Modo série do Instagram não chama a conversão para WhatsApp."
Assert-Contains '-c:v libx264' "Conversão para WhatsApp precisa usar H.264."
Assert-Contains '-c:a aac' "Conversão para WhatsApp precisa usar AAC."
Assert-Contains '-pix_fmt yuv420p' "Conversão para WhatsApp precisa usar yuv420p."
Assert-Contains '-movflags +faststart' "Conversão para WhatsApp precisa aplicar faststart."

Write-Host "Instagram/WhatsApp regression checks: OK" -ForegroundColor Green
