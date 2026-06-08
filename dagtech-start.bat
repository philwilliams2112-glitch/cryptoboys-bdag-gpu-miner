@echo off
setlocal

for %%i in ("%~dp0..") do set "BASE=%%~fi"
set "BIN=%BASE%\bin\dagtech-gpu-miner.exe"
set "LOGDIR=%BASE%\logs"
set "CTRLSCRIPT=%BASE%\bin\dagtech-control.ps1"

if not exist "%BIN%" (
    echo [DagTech GPU] ERROR: dagtech-gpu-miner.exe not found at %BIN%
    pause
    exit /b 1
)

if not exist "%LOGDIR%" mkdir "%LOGDIR%"

netstat -an 2>nul | find "8883" | find "LISTENING" >nul
if not errorlevel 1 (
    echo [DagTech GPU] Already running. Dashboard: http://127.0.0.1:8883/
    powershell -NoProfile -Command ^
        "Add-Type -AssemblyName System.Windows.Forms; $owner = New-Object System.Windows.Forms.Form; $owner.TopMost=$true; $owner.Show(); $owner.Hide(); [System.Windows.Forms.MessageBox]::Show($owner, 'DagTech GPU Miner is already running.' + [char]10 + [char]10 + 'Opening the dashboard now...', 'Already Running', 'OK', 'Information') | Out-Null; $owner.Dispose()"
    start "" http://127.0.0.1:8883/
    exit /b 0
)

echo.
echo   DagTech GPU Miner - dagtech.network
echo   Starting control server...
echo.

REM Prefer Task Scheduler (survives reboots without login); fall back to direct launch
schtasks /query /tn "DagTech GPU Miner" >nul 2>&1
if not errorlevel 1 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue" >nul 2>&1
) else (
    start /min "DagTech GPU Miner Control Server" powershell -NoProfile -ExecutionPolicy Bypass -File "%CTRLSCRIPT%" -BaseDir "%BASE%"
)

timeout /t 2 /nobreak >nul
echo [DagTech GPU] Dashboard: http://127.0.0.1:8883/
echo [DagTech GPU] Miner is starting in the background...
echo [DagTech GPU] Logs: %LOGDIR%
echo.
start "" http://127.0.0.1:8883/
