@echo off
REM DagTech GPU Miner - Status
tasklist /fi "imagename eq dagtech-gpu-miner.exe" /fo list 2>nul | findstr "PID" >nul
if errorlevel 1 (
    echo [GPU Miner] STOPPED
) else (
    echo [GPU Miner] RUNNING
    curl -s http://127.0.0.1:8882/metrics 2>nul
)
pause
