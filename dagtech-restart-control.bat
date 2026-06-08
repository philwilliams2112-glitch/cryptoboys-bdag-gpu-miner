@echo off
:: DagTech GPU Miner - Restart Control Server
:: Stops and restarts the control server (dagtech-control.ps1) without
:: changing whether the miner itself is running.
:: Useful after a software update to pick up the new control server code.
:: Requires Administrator — will self-elevate if needed.

REM ── Self-elevate ─────────────────────────────────────────────────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo   DagTech GPU Miner - Restart Control Server
echo   -------------------------------------------
echo.

REM ============================================================================
REM STEP 1 — Stop via scheduled task.
REM          This catches the task-owned process. Orphaned children (spawned by
REM          the control server's own /restart-server endpoint and not tracked
REM          by Task Scheduler) are handled in the next two steps.
REM ============================================================================
echo   Stopping control server...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Stop-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue" >nul 2>&1
echo   [OK] Scheduled task stopped

REM ============================================================================
REM STEP 2 — Kill any remaining control server processes by command-line.
REM          Catches orphaned children that Stop-ScheduledTask misses.
REM          Running elevated ensures CommandLine is visible even for processes
REM          running at higher integrity levels.
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$killed = 0;" ^
    "foreach ($exe in @('powershell.exe','pwsh.exe')) {" ^
    "    Get-CimInstance Win32_Process -Filter \"Name='$exe'\" |" ^
    "    Where-Object { $_.CommandLine -like '*dagtech-control*' } |" ^
    "    ForEach-Object {" ^
    "        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue;" ^
    "        Write-Host ('  [OK] Killed orphaned ' + $exe + ' PID ' + $_.ProcessId);" ^
    "        $killed++" ^
    "    }" ^
    "};" ^
    "if ($killed -eq 0) { Write-Host '  [--] No orphaned processes found' }"

REM ============================================================================
REM STEP 3 — Also kill by PID file in case command-line match missed it.
REM          Verifies the PID belongs to a PowerShell process before killing.
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
        "        Write-Host ('  [--] PID ' + $pidRaw + ' is ' + $p.Name + ' - not PowerShell, skipping')" ^
        "    } else {" ^
        "        Write-Host ('  [--] PID ' + $pidRaw + ' from pid file is already gone')" ^
        "    }" ^
        "} else {" ^
        "    Write-Host '  [--] PID file is empty or invalid - skipping'" ^
        "}"
    del "C:\dagtech-gpu-miner\logs\control.pid" >nul 2>&1
)

REM ============================================================================
REM STEP 4 — Release any stale HTTP.sys URL reservation on port 8883.
REM          When a process is killed without calling HttpListener.Stop(),
REM          HTTP.sys keeps port 8883 registered (visible as PID 4 in netstat).
REM          The new server launch would then fail immediately with error code 1.
REM          Requires Administrator - hence the self-elevation above.
REM ============================================================================
echo   Releasing HTTP.sys port 8883 reservation...
netsh http delete urlacl url=http://127.0.0.1:8883/ >nul 2>&1 ^
    && echo   [OK] HTTP.sys port 8883 reservation released ^
    || echo   [--] No HTTP.sys reservation found for port 8883 (already clear)

REM ============================================================================
REM STEP 5 — Start the control server via the scheduled task.
REM          NOTE: We do NOT touch the .stop sentinel here. The miner stays
REM          in whatever state it was in before this restart — running stays
REM          running, stopped stays stopped.
REM ============================================================================
echo   Starting control server...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue" >nul 2>&1

REM ============================================================================
REM STEP 6 — Confirm the new process is up and responding.
REM          Polls up to ~10 seconds so slow starts are not falsely reported
REM          as failures.
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$t = Get-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue;" ^
    "if (-not $t) { Write-Host '  [WARN] Scheduled task not found - is the miner installed?' -ForegroundColor Red; exit }" ^
    "$proc = $null; $tries = 0;" ^
    "while (-not $proc -and $tries -lt 5) {" ^
    "    Start-Sleep -Seconds 2; $tries++;" ^
    "    $proc = Get-CimInstance Win32_Process |" ^
    "            Where-Object { $_.Name -in 'powershell.exe','pwsh.exe' -and $_.CommandLine -like '*dagtech-control*' };" ^
    "};" ^
    "if ($proc) {" ^
    "    $ctrlPid = ($proc | Select-Object -First 1 -ExpandProperty ProcessId);" ^
    "    $ok = $false;" ^
    "    try {" ^
    "        $r = [System.Net.WebRequest]::Create('http://127.0.0.1:8883/status');" ^
    "        $r.Timeout = 3000; $r.GetResponse().Close(); $ok = $true" ^
    "    } catch {}" ^
    "    if ($ok) {" ^
    "        Write-Host ('  [OK] Control server running and responding (PID ' + $ctrlPid + ')') -ForegroundColor Green" ^
    "    } else {" ^
    "        Write-Host ('  [OK] Control server process running (PID ' + $ctrlPid + ') - still starting up') -ForegroundColor Green" ^
    "    }" ^
    "} else {" ^
    "    Write-Host '  [WARN] Process not found after 10 s - check the miner logs.' -ForegroundColor Red;" ^
    "    Write-Host '         Log: C:\dagtech-gpu-miner\logs\' -ForegroundColor Red" ^
    "}"

echo.
pause
