@echo off
setlocal
set "TPLR_SCRIPT=%~dp0scripts\Remove-ThinkPadLogo.ps1"
if not exist "%TPLR_SCRIPT%" (
    echo [ERROR] Script not found: %TPLR_SCRIPT%
    pause
    exit /b 1
)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s = $env:TPLR_SCRIPT; Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File \"' + $s + '\"')"
    exit /b %errorlevel%
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TPLR_SCRIPT%"
exit /b %errorlevel%
