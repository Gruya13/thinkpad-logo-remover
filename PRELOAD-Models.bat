@echo off
setlocal
set "TPLR_PRELOAD=%~dp0scripts\Preload-ThinkPadBios.ps1"
if not exist "%TPLR_PRELOAD%" (
    echo [ERROR] Script not found: %TPLR_PRELOAD%
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TPLR_PRELOAD%"
exit /b %errorlevel%
