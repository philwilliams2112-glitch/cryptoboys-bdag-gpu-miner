@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-gpu-miner.ps1" -RootDir "%~dp0.."
pause
