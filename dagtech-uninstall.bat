@echo off
setlocal

REM ── Self-elevate if not already running as Administrator ──────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo   [Uninstall] Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

for %%i in ("%~dp0..") do set "BASE=%%~fi"
set "LOGDIR=%BASE%\logs"
set "STOPFILE=%LOGDIR%\.stop"
set "PIDFILE=%LOGDIR%\control.pid"
set "TASK_NAME=DagTech GPU Miner"

echo.
echo   =====================================================
echo     DagTech GPU Miner - Uninstaller
echo   =====================================================
echo.
echo   This will permanently remove:
echo     - Scheduled task  "%TASK_NAME%"
echo     - All running miner processes
echo     - Desktop shortcuts
echo     - Install folder:  %BASE%
echo.
set "CONFIRM=n"
set /p "CONFIRM=  Uninstall DagTech GPU Miner? (y/N): "
if /i not "%CONFIRM%"=="y" (
    echo.
    echo   Cancelled.
    pause
    exit /b 0
)
echo.

REM 1. Drop a .stop file so the watchdog doesn't restart anything
if not exist "%LOGDIR%" mkdir "%LOGDIR%" 2>nul
echo. > "%STOPFILE%"

REM 2. Stop + remove the scheduled task
echo   [Uninstall] Removing scheduled task...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Disable-ScheduledTask  -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue | Out-Null;" ^
    "Stop-ScheduledTask     -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue;" ^
    "Unregister-ScheduledTask -TaskName 'DagTech GPU Miner' -Confirm:$false -ErrorAction SilentlyContinue;" ^
    "Disable-ScheduledTask  -TaskName 'DagTech Miner' -ErrorAction SilentlyContinue | Out-Null;" ^
    "Stop-ScheduledTask     -TaskName 'DagTech Miner' -ErrorAction SilentlyContinue;" ^
    "Unregister-ScheduledTask -TaskName 'DagTech Miner' -Confirm:$false -ErrorAction SilentlyContinue" >nul 2>&1
echo   [Uninstall] Scheduled task removed.

REM 3. Kill running processes (binary, control server by cmdline, and by pid file)
echo   [Uninstall] Stopping miner processes...
taskkill /f /im dagtech-gpu-miner.exe >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "foreach ($exe in @('powershell.exe','pwsh.exe')) {" ^
    "    Get-CimInstance Win32_Process -Filter \"Name='$exe'\" |" ^
    "    Where-Object { $_.CommandLine -like '*dagtech-control*' } |" ^
    "    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" ^
    "}" >nul 2>&1
if exist "%PIDFILE%" (
    set /p CTRLPID=<"%PIDFILE%"
    taskkill /f /pid %CTRLPID% >nul 2>&1
)
echo   [Uninstall] Processes stopped.

REM 4. Remove desktop shortcuts
echo   [Uninstall] Removing desktop shortcuts...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=[Environment]::GetFolderPath('Desktop'); 'DagTech GPU Miner.lnk','DagTech GPU Miner - Stop.lnk','DagTech GPU Miner - Uninstall.lnk','DagTech GPU Miner - Logs.lnk','DagTech GPU Miner - Restart Control.lnk' | ForEach-Object { $f=Join-Path $d $_; if (Test-Path $f) { Remove-Item $f -Force } }" 2>nul

REM 5. Remove legacy Startup-folder shortcut (old installs)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$lnk=[IO.Path]::Combine($env:APPDATA,'Microsoft\Windows\Start Menu\Programs\Startup\DagTech GPU Miner.lnk'); if (Test-Path $lnk) { Remove-Item $lnk -Force }" 2>nul
echo   [Uninstall] Shortcuts removed.

REM 6. Delete the install directory
REM    We can't delete ourselves while running, so hand off to a temp cmd
REM    that waits for this process to exit first.
echo   [Uninstall] Deleting %BASE%...
set "DEL_CMD=timeout /t 2 /nobreak >nul & rd /s /q "%BASE%""
start "" /b cmd /c "%DEL_CMD%"

echo.
echo   =====================================================
echo     DagTech GPU Miner has been removed.
echo   =====================================================
echo.
echo   The install folder will be deleted in a moment.
echo.
pause
