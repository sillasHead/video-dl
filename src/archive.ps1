# Shared internal download identity/archive helpers.
# Keeps source IDs out of visible filenames while still recognizing the same content.

$script:VideoDlArchiveDir = Join-Path $HOME ".video-dl"
$script:VideoDlArchivePath = Join-Path $script:VideoDlArchiveDir "downloads.json"

function Get-VideoDlDuplicatePolicy {
    $configPath = Join-Path $script:VideoDlArchiveDir "config.json"
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $value = [string]$cfg.duplicatePolicy
            if ($value -in @("skip", "ask", "overwrite", "rename")) { return $value }
        } catch { }
    }
    return "skip"
}

function Normalize-VideoDlSource([string]$Source) {
    if ([string]::IsNullOrWhiteSpace($Source)) { return "unknown" }
    $value = $Source.Trim().ToLowerInvariant()
    $value = $value -replace '^www\.', ''
    if ($value -match '(^|\.)(youtube\.com|youtu\.be)$' -or $value -eq "youtube") { return "youtube" }
    if ($value -match '(^|\.)threads\.(com|net)$' -or $value -eq "threads") { return "threads" }
    if ($value -match '(^|\.)pluto\.tv$' -or $value -eq "pluto") { return "pluto" }
    return $value
}

function Get-VideoDlUrlFingerprint([string]$Url) {
    $normalized = $Url
    try {
        $uri = [Uri]$Url
        $builder = New-Object System.UriBuilder($uri)
        $builder.Fragment = ""
        $builder.Host = $builder.Host.ToLowerInvariant()
        $normalized = $builder.Uri.AbsoluteUri.TrimEnd('/')
    } catch { }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$normalized)
        $hash = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString("x2") })
    } finally {
        $sha.Dispose()
    }
}

function Get-VideoDlIdentity([string]$Source, [string]$SourceId, [string]$Url) {
    $sourceName = Normalize-VideoDlSource $Source
    if (-not [string]::IsNullOrWhiteSpace($SourceId)) {
        return "$sourceName`:$($SourceId.Trim())"
    }
    return "url:$sourceName`:$(Get-VideoDlUrlFingerprint $Url)"
}

function Read-VideoDlArchive {
    if (-not (Test-Path -LiteralPath $script:VideoDlArchivePath -PathType Leaf)) { return @() }
    try {
        $data = Get-Content -LiteralPath $script:VideoDlArchivePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $data.PSObject.Properties["items"]) { return @($data.items) }
        return @($data)
    } catch {
        return @()
    }
}

function Write-VideoDlArchive([object[]]$Items) {
    if (-not (Test-Path -LiteralPath $script:VideoDlArchiveDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:VideoDlArchiveDir -Force | Out-Null
    }
    $payload = [PSCustomObject]@{
        version = 1
        items = @($Items)
    }
    $temp = "$($script:VideoDlArchivePath).tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $script:VideoDlArchivePath -Force
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-VideoDlArchiveEntry([string]$Identity) {
    if ([string]::IsNullOrWhiteSpace($Identity)) { return $null }
    return @(Read-VideoDlArchive | Where-Object { [string]$_.identity -ieq $Identity } | Sort-Object updatedAt -Descending) | Select-Object -First 1
}

function Remove-VideoDlArchiveEntry([string]$Identity) {
    if ([string]::IsNullOrWhiteSpace($Identity)) { return }
    $remaining = @(Read-VideoDlArchive | Where-Object { [string]$_.identity -ine $Identity })
    Write-VideoDlArchive $remaining
}

function Register-VideoDlDownload([string]$Identity, [string]$PathValue, [string]$Url, [string]$SourceId) {
    if ([string]::IsNullOrWhiteSpace($Identity) -or [string]::IsNullOrWhiteSpace($PathValue)) { return }
    try { $fullPath = [System.IO.Path]::GetFullPath($PathValue) } catch { $fullPath = $PathValue }
    $items = @(Read-VideoDlArchive | Where-Object { [string]$_.identity -ine $Identity })
    $items += [PSCustomObject]@{
        identity = $Identity
        sourceId = $SourceId
        url = $Url
        path = $fullPath
        updatedAt = (Get-Date).ToString("o")
    }
    Write-VideoDlArchive $items
}

function Test-VideoDlNameTaken([string]$PathValue) {
    if (Test-Path -LiteralPath $PathValue) { return $true }
    $dir = Split-Path -Parent $PathValue
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $pattern = '^' + [regex]::Escape($stem) + '(?: \[\d+p\])?' + [regex]::Escape($ext) + '$'
    return $null -ne (Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | Select-Object -First 1)
}

function Get-VideoDlUniquePath([string]$PathValue) {
    if (-not (Test-VideoDlNameTaken $PathValue)) { return $PathValue }
    $dir = Split-Path -Parent $PathValue
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $ext = [System.IO.Path]::GetExtension($PathValue)
    $i = 2
    while ($true) {
        $candidate = Join-Path $dir ("{0} ({1}){2}" -f $stem, $i, $ext)
        if (-not (Test-VideoDlNameTaken $candidate)) { return $candidate }
        $i++
    }
}

function Find-VideoDlLegacyIdFile([string]$DesiredPath, [string]$SourceId) {
    if ([string]::IsNullOrWhiteSpace($SourceId)) { return $null }
    $dir = Split-Path -Parent $DesiredPath
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    $idToken = " [$SourceId]"
    return Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.IndexOf($idToken, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Try-MigrateVideoDlLegacyIdFile([string]$Identity, [string]$DesiredPath, [string]$Url, [string]$SourceId) {
    if ([string]::IsNullOrWhiteSpace($Identity) -or [string]::IsNullOrWhiteSpace($SourceId)) { return $null }
    if ($null -ne (Get-VideoDlArchiveEntry $Identity)) { return $null }
    $legacy = Find-VideoDlLegacyIdFile $DesiredPath $SourceId
    if ($null -eq $legacy) { return $null }

    $escaped = [regex]::Escape(" [$SourceId]")
    $cleanName = [regex]::Replace($legacy.Name, $escaped, "", 1)
    $cleanPath = Join-Path $legacy.DirectoryName $cleanName
    $finalPath = $legacy.FullName
    if (-not (Test-Path -LiteralPath $cleanPath)) {
        try {
            Move-Item -LiteralPath $legacy.FullName -Destination $cleanPath
            $finalPath = $cleanPath
            Write-Host "Nome antigo atualizado: $cleanName" -ForegroundColor Cyan
        } catch { }
    }
    Register-VideoDlDownload $Identity $finalPath $Url $SourceId
    return Get-VideoDlArchiveEntry $Identity
}

function Get-VideoDlSeriesCoreStem([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PathValue)
    $stem = [regex]::Replace($stem, '\s+\[\d+p\]$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $stem = [regex]::Replace($stem, '^S\d{1,4}E\d{1,6}\s*-\s*', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $stem.Trim()
}

function Try-ReconcileVideoDlSeriesPath([object]$Entry, [string]$DesiredPath, [string]$Identity, [string]$Url, [string]$SourceId) {
    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace($DesiredPath)) { return $null }
    $oldPath = [string]$Entry.path
    if ([string]::IsNullOrWhiteSpace($oldPath) -or -not (Test-Path -LiteralPath $oldPath -PathType Leaf)) { return $null }

    $oldCore = Get-VideoDlSeriesCoreStem $oldPath
    $desiredCore = Get-VideoDlSeriesCoreStem $DesiredPath
    if ([string]::IsNullOrWhiteSpace($oldCore) -or $oldCore -ine $desiredCore) { return $null }

    $oldStem = [System.IO.Path]::GetFileNameWithoutExtension($oldPath)
    $quality = ""
    $qualityMatch = [regex]::Match($oldStem, '(\s+\[\d+p\])$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($qualityMatch.Success) { $quality = $qualityMatch.Groups[1].Value }

    $desiredDir = Split-Path -Parent $DesiredPath
    $desiredStem = [System.IO.Path]::GetFileNameWithoutExtension($DesiredPath)
    $oldExt = [System.IO.Path]::GetExtension($oldPath)
    $targetPath = Join-Path $desiredDir ($desiredStem + $quality + $oldExt)

    try {
        if ([System.IO.Path]::GetFullPath($oldPath) -ieq [System.IO.Path]::GetFullPath($targetPath)) { return $oldPath }
    } catch { }
    if (Test-Path -LiteralPath $targetPath) { return $null }

    if (-not (Test-Path -LiteralPath $desiredDir -PathType Container)) {
        New-Item -ItemType Directory -Path $desiredDir -Force | Out-Null
    }

    $oldDir = Split-Path -Parent $oldPath
    try {
        Move-Item -LiteralPath $oldPath -Destination $targetPath -Force
        Register-VideoDlDownload $Identity $targetPath $Url $SourceId
        Write-Host "Organização corrigida: $([System.IO.Path]::GetFileName($targetPath))" -ForegroundColor Cyan
        if ($oldDir -ine $desiredDir -and (Test-Path -LiteralPath $oldDir -PathType Container)) {
            $remaining = @(Get-ChildItem -LiteralPath $oldDir -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $oldDir -Force -ErrorAction SilentlyContinue }
        }
        return $targetPath
    } catch {
        return $null
    }
}

function Resolve-VideoDlTarget(
    [string]$Identity,
    [string]$DesiredPath,
    [string]$Url,
    [string]$SourceId,
    [bool]$ForceOverwrite = $false,
    [bool]$ReconcileSeriesPath = $false
) {
    if (-not [string]::IsNullOrWhiteSpace($Identity)) {
        [void](Try-MigrateVideoDlLegacyIdFile $Identity $DesiredPath $Url $SourceId)
        $entry = Get-VideoDlArchiveEntry $Identity
        if ($null -ne $entry -and $ReconcileSeriesPath) {
            $reconciledPath = Try-ReconcileVideoDlSeriesPath $entry $DesiredPath $Identity $Url $SourceId
            if (-not [string]::IsNullOrWhiteSpace([string]$reconciledPath)) {
                return [PSCustomObject]@{ Skip = $true; Path = $reconciledPath; KnownIdentity = $true; Reconciled = $true }
            }
        }
        if ($null -ne $entry) {
            $oldPath = [string]$entry.path
            if (-not [string]::IsNullOrWhiteSpace($oldPath) -and (Test-Path -LiteralPath $oldPath -PathType Leaf)) {
                $policy = if ($ForceOverwrite) { "overwrite" } else { Get-VideoDlDuplicatePolicy }
                if ($policy -eq "ask") {
                    Write-Host "Este conteúdo já foi baixado: $([System.IO.Path]::GetFileName($oldPath))" -ForegroundColor Yellow
                    $choice = (Read-Host "[P]ular / [S]ubstituir / [C]riar cópia [P]").Trim().ToLowerInvariant()
                    if ($choice -in @("s", "substituir")) { $policy = "overwrite" }
                    elseif ($choice -in @("c", "copia", "cópia")) { $policy = "rename" }
                    else { $policy = "skip" }
                }

                if ($policy -eq "skip") {
                    Write-Host "Conteúdo já baixado; download pulado: $([System.IO.Path]::GetFileName($oldPath))" -ForegroundColor Cyan
                    return [PSCustomObject]@{ Skip = $true; Path = $oldPath; KnownIdentity = $true }
                }
                if ($policy -eq "overwrite") {
                    Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
                    Remove-VideoDlArchiveEntry $Identity
                } elseif ($policy -eq "rename") {
                    $copyPath = Get-VideoDlUniquePath $DesiredPath
                    return [PSCustomObject]@{ Skip = $false; Path = $copyPath; KnownIdentity = $true }
                }
            } else {
                Remove-VideoDlArchiveEntry $Identity
            }
        }
    }

    # No known matching identity: a filename collision is a different/unknown item,
    # so preserve both by choosing (2), (3), ... instead of silently skipping it.
    $target = Get-VideoDlUniquePath $DesiredPath
    return [PSCustomObject]@{ Skip = $false; Path = $target; KnownIdentity = $false }
}

function Find-VideoDlOutputForBase([string]$Directory, [string]$FileBase) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
    $pattern = '^' + [regex]::Escape($FileBase) + '(?: \[\d+p\])?\.(?:mp4|mkv|webm|mov|ts|m4v|mp3|m4a|aac|opus|flac|wav)$'
    return Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}
