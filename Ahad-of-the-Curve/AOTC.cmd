@echo off
chcp 65001 >nul
mode con: cols=110 lines=46 >nul 2>&1
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\AOTC.ps1"
if errorlevel 1 (
    echo.
    echo AOTC did not finish. Review the error above.
)
pause >nul
