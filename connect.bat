@echo off
rem Double-click to connect. Asks for administrator rights automatically.
rem Set your SSH username on the server here (only used on the first run):
set SSH_USER=matthias

rem Re-launch as administrator if needed.
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect-forward.ps1" -User %SSH_USER% %*
echo.
pause
