@echo off
:: DagTech GPU Miner - Force Stop
:: Kills all miner and control server processes, including orphaned instances
:: that the normal stop tool misses. Safe to run at any time.
:: Requires Administrator (will self-elevate if needed).

REM ── Self-elevate ─────────────────────────────────────────────────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo   DagTech GPU Miner - Force Stop
echo   --------------------------------
echo.

REM ============================================================================
REM STEP 1 — Write the stop sentinel FIRST.
REM          The control server checks this file on startup and after every
REM          miner exit. Writing it first means even if any later step fails
REM          or the scheduled task restarts the control server in between, the
REM          miner will NOT be relaunched.
REM ============================================================================
if exist "C:\dagtech-gpu-miner\logs" (
    echo. > "C:\dagtech-gpu-miner\logs\.stop"
    echo   [OK] Stop sentinel written
) else (
    echo   [--] Install dir not found - sentinel skipped
)

REM ============================================================================
REM STEP 2 — Disable the scheduled task so its restart policy cannot
REM          relaunch the control server while we are killing processes.
REM          We re-enable it at the end so the miner still auto-starts on
REM          the next boot / login.
REM ============================================================================
echo   Stopping scheduled task...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Disable-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue | Out-Null;" ^
    "Stop-ScheduledTask   -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue" >nul 2>&1
echo   [OK] Scheduled task stopped and disabled

REM ============================================================================
REM STEP 3 — Kill the miner binary (all instances).
REM ============================================================================
echo   Killing dagtech-gpu-miner.exe...
taskkill /f /im dagtech-gpu-miner.exe >nul 2>&1 ^
    && echo   [OK] dagtech-gpu-miner.exe killed ^
    || echo   [--] dagtech-gpu-miner.exe was not running

REM ============================================================================
REM STEP 4 — Kill all control server processes (PowerShell 5 and 7).
REM          Matches by command-line so orphaned instances (spawned via
REM          /restart-server and not tracked by Task Scheduler) are caught too.
REM          Running elevated ensures CommandLine is visible even for processes
REM          running at higher integrity levels.
REM ============================================================================
echo   Killing control server processes...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$killed = 0;" ^
    "foreach ($exe in @('powershell.exe','pwsh.exe')) {" ^
    "    Get-CimInstance Win32_Process -Filter \"Name='$exe'\" |" ^
    "    Where-Object { $_.CommandLine -like '*dagtech-control*' } |" ^
    "    ForEach-Object {" ^
    "        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue;" ^
    "        Write-Host ('  [OK] Killed ' + $exe + ' PID ' + $_.ProcessId);" ^
    "        $killed++" ^
    "    }" ^
    "};" ^
    "if ($killed -eq 0) { Write-Host '  [--] No control server processes found' }"

REM ============================================================================
REM STEP 5 — Also kill by PID file in case command-line match missed it.
REM          Verifies the PID belongs to a PowerShell process before killing
REM          so a reused PID can never take out an unrelated process.
REM ============================================================================
if exist "C:\dagtech-gpu-miner\logs\control.pid" (
    set /p CTRLPID=<"C:\dagtech-gpu-miner\logs\control.pid"
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$pidRaw = '%CTRLPID%'.Trim();" ^
        "if ($pidRaw -match '^\d+$') {" ^
        "    $p = Get-Process -Id ([int]$pidRaw) -ErrorAction SilentlyContinue;" ^
        "    if ($p -and $p.Name -in 'powershell','pwsh') {" ^
        "        Stop-Process -Id ([int]$pidRaw) -Force -ErrorAction SilentlyContinue;" ^
        "        Write-Host ('  [OK] Killed PID ' + $pidRaw + ' from pid file')" ^
        "    } elseif ($p) {" ^
        "        Write-Host ('  [--] PID ' + $pidRaw + ' is ' + $p.Name + ' - not a PowerShell process, skipping')" ^
        "    } else {" ^
        "        Write-Host ('  [--] PID ' + $pidRaw + ' from pid file is already gone')" ^
        "    }" ^
        "} else {" ^
        "    Write-Host '  [--] PID file is empty or invalid - skipping'" ^
        "}"
    del "C:\dagtech-gpu-miner\logs\control.pid" >nul 2>&1
)

REM ============================================================================
REM STEP 6 — Release any stale HTTP.sys URL reservation on port 8883.
REM          When a process is killed without calling HttpListener.Stop(),
REM          HTTP.sys retains the active port registration (visible as PID 4
REM          in netstat). The next server launch then fails immediately with
REM          "Could not bind port 8883 - is another instance already running?"
REM          Deleting the reservation here clears it. The next elevated start
REM          recreates it automatically.
REM          This step requires Administrator - hence the self-elevation above.
REM ============================================================================
echo   Releasing HTTP.sys port 8883 reservation...
netsh http delete urlacl url=http://127.0.0.1:8883/ >nul 2>&1 ^
    && echo   [OK] HTTP.sys port 8883 reservation released ^
    || echo   [--] No HTTP.sys reservation found for port 8883 (already clear)

REM ============================================================================
REM STEP 7 — Brief pause, then verify processes are gone and port is free.
REM          Retry kill once if anything survived.
REM ============================================================================
echo   Verifying...
timeout /t 2 /nobreak >nul

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$m = Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue;" ^
    "$c = @('powershell.exe','pwsh.exe') | ForEach-Object {" ^
    "    Get-CimInstance Win32_Process -Filter \"Name='$_'\" |" ^
    "    Where-Object { $_.CommandLine -like '*dagtech-control*' }" ^
    "};" ^
    "if ($m -or $c) {" ^
    "    Write-Host '  [RETRY] Processes still running - sending second kill...' -ForegroundColor Yellow;" ^
    "    if ($m) { $m | Stop-Process -Force -ErrorAction SilentlyContinue };" ^
    "    if ($c) { $c | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } };" ^
    "    Start-Sleep -Seconds 2;" ^
    "    $m2 = Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue;" ^
    "    $c2 = @('powershell.exe','pwsh.exe') | ForEach-Object {" ^
    "        Get-CimInstance Win32_Process -Filter \"Name='$_'\" |" ^
    "        Where-Object { $_.CommandLine -like '*dagtech-control*' }" ^
    "    };" ^
    "    if ($m2 -or $c2) {" ^
    "        Write-Host '  [WARN] Processes still alive after two kill attempts - try rebooting.' -ForegroundColor Red" ^
    "    } else {" ^
    "        Write-Host '  [OK] All miner processes stopped (needed second kill)' -ForegroundColor Green" ^
    "    }" ^
    "} else {" ^
    "    Write-Host '  [OK] All miner processes are stopped' -ForegroundColor Green" ^
    "};" ^
    "$portBusy = netstat -ano 2`>nul | Select-String ':8883\s.*LISTENING';" ^
    "if ($portBusy) {" ^
    "    Write-Host '  [WARN] Port 8883 is still LISTENING - next start may fail. Try rebooting.' -ForegroundColor Yellow" ^
    "} else {" ^
    "    Write-Host '  [OK] Port 8883 is free' -ForegroundColor Green" ^
    "}"

REM ============================================================================
REM STEP 8 — Re-enable the scheduled task so the miner auto-starts on next
REM          boot / login as normal. The .stop sentinel is still in place so
REM          even if the task fires, the control server won't start the miner
REM          until the user explicitly starts it (dagtech-start.bat clears it).
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Enable-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue | Out-Null" >nul 2>&1
echo   [OK] Scheduled task re-enabled (miner will stay stopped until you click Start)

echo.
pause
