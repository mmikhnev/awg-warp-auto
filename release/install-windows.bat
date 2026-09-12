@echo off
setlocal
cd /d "%~dp0"
if exist "%~dp0install-windows.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
)
if %ERRORLEVEL% NEQ 0 (
    echo.
    pause
)
