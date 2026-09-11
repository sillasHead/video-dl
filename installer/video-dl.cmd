@echo off
where pwsh.exe >nul 2>nul
if not errorlevel 1 goto pwsh

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\video-dl\app\video-dl.ps1" %*
exit /b %errorlevel%

:pwsh
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\video-dl\app\video-dl.ps1" %*
exit /b %errorlevel%
