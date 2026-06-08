@echo off
setlocal

for %%i in ("%~dp0..") do set "BASE=%%~fi"
set "LOGDIR=%BASE%\logs"

if not exist "%LOGDIR%" (
    echo [DagTech] Log directory not found: %LOGDIR%
    pause
    exit /b 1
)

REM Open a styled PowerShell terminal tailing today's miner log.
REM Must be launched by the user (not the SYSTEM service) so it appears on the desktop.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$host.UI.RawUI.WindowTitle = 'DagTech GPU Miner - Live Log';" ^
    "try { $host.UI.RawUI.BackgroundColor = 'Black'; Clear-Host } catch {}" ^
    "Write-Host '  DagTech GPU Miner - Live Log' -ForegroundColor Cyan;" ^
    "Write-Host '  Press Ctrl+C to close.' -ForegroundColor DarkGray;" ^
    "Write-Host '';" ^
    "$logDir = '%LOGDIR%';" ^
    "$log = Join-Path $logDir ('miner_' + (Get-Date -Format 'yyyy-MM-dd') + '.log');" ^
    "while (-not (Test-Path $log)) { Write-Host 'Waiting for log file...' -ForegroundColor DarkGray; Start-Sleep 2 };" ^
    "Get-Content -Wait -Tail 60 $log | ForEach-Object {" ^
    "    if ($_.Contains('[DagTech GPU]'))              { Write-Host $_ -ForegroundColor Magenta }" ^
    "    elseif ($_.Contains('[DagTech CPU]'))         { Write-Host $_ -ForegroundColor Green }" ^
    "    elseif ($_ -match 'SHARE FOUND|ACCEPTED')    { Write-Host $_ -ForegroundColor Cyan }" ^
    "    elseif ($_ -match 'ERROR|failed|FAILED')      { Write-Host $_ -ForegroundColor Red }" ^
    "    elseif ($_ -match 'WARN|warn')                { Write-Host $_ -ForegroundColor Yellow }" ^
    "    elseif ($_ -match 'Control server|Watchdog|Starting') { Write-Host $_ -ForegroundColor Cyan }" ^
    "    else { Write-Host $_ -ForegroundColor Gray } }"
