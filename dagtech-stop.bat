@echo off
setlocal

for %%i in ("%~dp0..") do set "BASE=%%~fi"
set "LOGDIR=%BASE%\logs"
set "STOPFILE=%LOGDIR%\.stop"
set "PIDFILE=%LOGDIR%\control.pid"

echo. > "%STOPFILE%"

REM Stop the scheduled task first so it doesn't restart the miner
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Stop-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue" >nul 2>&1

taskkill /f /im dagtech-gpu-miner.exe 2>nul && echo [DagTech GPU] Miner stopped || echo [DagTech GPU] Miner was not running

if exist "%PIDFILE%" (
    set /p CTRLPID=<"%PIDFILE%"
    taskkill /f /pid %CTRLPID% 2>nul && echo [DagTech GPU] Control server stopped || echo [DagTech GPU] Control server was not running
    del "%PIDFILE%" 2>nul
) else (
    echo [DagTech GPU] Control server PID not found
)

pause
