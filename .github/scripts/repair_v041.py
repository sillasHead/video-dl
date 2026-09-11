from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"missing: {label}")
    return text.replace(old, new, 1)

main_path = Path("src/video-dl.ps1")
pluto_path = Path("src/pluto-dl.ps1")
threads_path = Path("src/th-dl.ps1")

main = main_path.read_text(encoding="utf-8-sig")

# When FFmpeg is unavailable, TS fallback must still honor duplicate policy.
main = replace_once(
    main,
    '''        $target = Join-Path $OutputDir ($FileBase + ".ts")
        return (Invoke-Streamlink @($Url, "best", "-o", $target))''',
    '''        $target = Join-Path $OutputDir ($FileBase + ".ts")
        $collision = Resolve-OutputCollision $target
        if ($collision.Skip) { return 0 }
        $target = [string]$collision.Path
        return (Invoke-Streamlink @($Url, "best", "-o", $target))''',
    "main TS collision",
)

# If MP4 remux fails, remove the partial file, preserve a (2) suffix, and apply collision policy to MKV too.
main = replace_once(
    main,
    '''    if ($ffCode -ne 0 -and $VideoContainer -eq "mp4") {
        Write-Warn "O stream não pôde ser remuxado para MP4. Tentando MKV sem re-encode..."
        $target = Join-Path $OutputDir ($FileBase + ".mkv")
        & ffmpeg -y -i $temp -map 0 -c copy $target | Out-Host
        $ffCode = [int]$LASTEXITCODE
    }''',
    '''    if ($ffCode -ne 0 -and $VideoContainer -eq "mp4") {
        Write-Warn "O stream não pôde ser remuxado para MP4. Tentando MKV sem re-encode..."
        $failedMp4 = $target
        $targetStem = [System.IO.Path]::GetFileNameWithoutExtension($target)
        Remove-Item -LiteralPath $failedMp4 -Force -ErrorAction SilentlyContinue
        $target = Join-Path $OutputDir ($targetStem + ".mkv")
        $collision = Resolve-OutputCollision $target
        if ($collision.Skip) { Remove-Item $temp -Force -ErrorAction SilentlyContinue; return 0 }
        $target = [string]$collision.Path
        & ffmpeg -y -i $temp -map 0 -c copy $target | Out-Host
        $ffCode = [int]$LASTEXITCODE
    }''',
    "main MKV fallback",
)
main_path.write_text(main, encoding="utf-8")

pluto = pluto_path.read_text(encoding="utf-8-sig")
pluto = replace_once(
    pluto,
    '''    if ($ffCode -ne 0 -and $VideoContainer -eq "mp4") {
        Write-Host "MP4 incompatível com este stream; tentando MKV sem re-encode..." -ForegroundColor Yellow
        $outputPath = Join-Path $Folder ($FileBase + ".mkv")
        & ffmpeg -y -i $tempPath -map 0 -c copy $outputPath | Out-Host
        $ffCode = [int]$LASTEXITCODE
    }''',
    '''    if ($ffCode -ne 0 -and $VideoContainer -eq "mp4") {
        Write-Host "MP4 incompatível com este stream; tentando MKV sem re-encode..." -ForegroundColor Yellow
        $failedMp4 = $outputPath
        $targetStem = [System.IO.Path]::GetFileNameWithoutExtension($outputPath)
        Remove-Item -LiteralPath $failedMp4 -Force -ErrorAction SilentlyContinue
        $outputPath = Join-Path $Folder ($targetStem + ".mkv")
        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; return $collision.Path }
        $outputPath = [string]$collision.Path
        & ffmpeg -y -i $tempPath -map 0 -c copy $outputPath | Out-Host
        $ffCode = [int]$LASTEXITCODE
    }''',
    "pluto MKV fallback",
)
pluto_path.write_text(pluto, encoding="utf-8")

threads = threads_path.read_text(encoding="utf-8-sig")
threads = threads.replace(
    '''        $collision = Resolve-Collision $outputPath
    if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
    $outputPath = [string]$collision.Path
        Write-Host "Baixando: $outputPath"''',
    '''        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
        $outputPath = [string]$collision.Path
        Write-Host "Baixando: $outputPath"''',
    1,
)
threads = threads.replace(
    '''        $collision = Resolve-Collision $outputPath
    if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
    $outputPath = [string]$collision.Path
        Write-Host "Baixando vídeo temporário..."''',
    '''        $collision = Resolve-Collision $outputPath
        if ($collision.Skip) { Write-Host ""; Write-Host "Salvo: $($collision.Path)" -ForegroundColor Green; return }
        $outputPath = [string]$collision.Path
        Write-Host "Baixando vídeo temporário..."''',
    1,
)
threads_path.write_text(threads, encoding="utf-8")

print("v0.4.1 polish applied")
