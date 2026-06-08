# DagTech GPU Miner Control Server
# Serves the dashboard and manages the GPU miner process lifecycle.
# Runs on port 8883 so the dashboard stays accessible when the miner is down.
param([string]$BaseDir = (Split-Path (Split-Path $MyInvocation.MyCommand.Path) -Parent))

$script:BASE      = $BaseDir
$script:BIN       = Join-Path $BaseDir "bin\dagtech-gpu-miner.exe"
$script:CONFIG    = Join-Path $BaseDir "config.env"
$script:LOGDIR    = Join-Path $BaseDir "logs"
$script:DASHBOARD = Join-Path $BaseDir "dashboard\index.html"
$script:STOPFILE   = Join-Path $BaseDir "logs\.stop"
$script:MINERPIDF  = Join-Path $BaseDir "logs\miner.pid"
$PIDFILE           = Join-Path $BaseDir "logs\control.pid"
$script:TASK_NAME  = "DagTech GPU Miner"
$script:CTRL_SCRIPT     = Join-Path $BaseDir "bin\dagtech-control.ps1"
$script:PENDING_NEW     = Join-Path $BaseDir "bin\dagtech-control.ps1.new"
$script:PendingRestart  = $false

if (-not (Test-Path $script:LOGDIR)) { New-Item -ItemType Directory -Path $script:LOGDIR | Out-Null }

# ── Apply any pending control-script update ──────────────────────────────────
# Downloaded by /update as .new; renamed here at next startup so the running
# script is never overwritten while in use (Windows allows renaming open files).
if (Test-Path $script:PENDING_NEW) {
    try {
        Move-Item $script:PENDING_NEW $script:CTRL_SCRIPT -Force -ErrorAction Stop
        Write-Host "[DagTech GPU] Pending control server update applied."
    } catch {
        Write-Host "[DagTech GPU] Warning: could not apply pending control update: $_"
    }
}

# ── Single-instance guard ────────────────────────────────────────────────────
# If a previous instance holds the PID file and is still alive, wait briefly for
# it to exit — this is the normal graceful-restart handoff, where the outgoing
# server is in the middle of shutting down. Only bail out if a live holder remains
# after the grace window, which means a genuine second instance is starting up.
$guardDeadline = (Get-Date).AddSeconds(10)
while ($true) {
    $holderPid = $null
    if (Test-Path $PIDFILE) {
        try { $holderPid = [int]((Get-Content $PIDFILE -Raw).Trim()) } catch { $holderPid = $null }
    }
    if (-not $holderPid -or $holderPid -eq $PID) { break }            # slot free, or already ours
    if (-not (Get-Process -Id $holderPid -ErrorAction SilentlyContinue)) { break }   # stale PID file — take over
    if ((Get-Date) -ge $guardDeadline) {
        Write-Host "[DagTech GPU] Control server already running (PID $holderPid). Exiting."
        exit 0
    }
    Start-Sleep -Milliseconds 250                                     # wait for the outgoing instance to release the slot
}
[System.IO.File]::WriteAllText($PIDFILE, "$PID")

$script:StartMode = "service"
# Watchdog defaults — overridden by config.env values below
$script:WatchdogRestartDelay  = 60    # seconds miner must be down before first restart attempt
$script:WatchdogRetryInterval = 300   # seconds between subsequent restart attempts
$script:WatchdogMaxRetries    = 0     # 0 = unlimited retries
if (Test-Path $script:CONFIG) {
    Get-Content $script:CONFIG | ForEach-Object {
        if ($_ -match '^START_MODE=(.+)$')              { $script:StartMode             = $Matches[1].Trim() }
        if ($_ -match '^WATCHDOG_RESTART_DELAY=(\d+)$') { $script:WatchdogRestartDelay  = [int]$Matches[1] }
        if ($_ -match '^WATCHDOG_RETRY_INTERVAL=(\d+)$'){ $script:WatchdogRetryInterval = [int]$Matches[1] }
        if ($_ -match '^WATCHDOG_MAX_RETRIES=(\d+)$')   { $script:WatchdogMaxRetries    = [int]$Matches[1] }
    }
}

try { $host.UI.RawUI.WindowTitle = "DagTech GPU Miner Control Server" } catch {}

function Write-Log([string]$msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Write-Host $line
    try {
        $logPath = Join-Path $script:LOGDIR "miner_$(Get-Date -Format 'yyyy-MM-dd').log"
        $fs = New-Object System.IO.FileStream($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $sw = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
        $sw.WriteLine($line)
        $sw.Close()
        $fs.Close()
    } catch {}
}

function Get-ActiveMinerLog {
    # Returns the miner log file the process is currently writing to.
    # Prefers today's file when it has content; otherwise picks the most-recently-
    # modified miner_YYYY-MM-DD.log so the dashboard stays accurate even when the
    # miner started before midnight (or hasn't been restarted in several days).
    $today = Join-Path $script:LOGDIR "miner_$(Get-Date -Format 'yyyy-MM-dd').log"
    if ((Test-Path $today) -and (Get-Item $today).Length -ge 200) { return $today }
    $best = Get-ChildItem $script:LOGDIR -Filter "miner_*.log" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^miner_\d{4}-\d{2}-\d{2}\.log$' -and $_.Length -ge 200 } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    if ($best) { return $best.FullName }
    return $today   # return today's path even if empty (caller handles missing file)
}

function Read-Config {
    $cfg = @{}
    Get-Content $script:CONFIG | ForEach-Object {
        if ($_ -match '^([A-Z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
    }
    return $cfg
}

function Detect-GpuVram {
    # Returns @{ vram_mb = <int>; rec_intensity = <int>; gpu_count = <int> }
    # Enumerates ALL GPUs (not just the first). Uses the largest VRAM card for the
    # intensity recommendation. Caches results in config.env; sets GPU_DEVICE=all
    # automatically when multiple GPUs are found and no device override is set.
    $cfg = Read-Config
    if ($cfg["GPU_REC_INTENSITY"] -and $cfg["GPU_VRAM_MB"] -ne $null -and $cfg["GPU_DETECTED_COUNT"]) {
        return @{
            vram_mb      = [int]$cfg["GPU_VRAM_MB"]
            rec_intensity = [int]$cfg["GPU_REC_INTENSITY"]
            gpu_count    = [int]$cfg["GPU_DETECTED_COUNT"]
        }
    }

    # ── Enumerate GPUs ────────────────────────────────────────────────────────
    $gpus = [System.Collections.Generic.List[hashtable]]::new()

    # Try nvidia-smi first — returns one line per GPU
    try {
        $nvOut = & nvidia-smi --query-gpu=memory.total,name --format=csv,noheader,nounits 2>$null
        if ($nvOut) {
            $idx = 0
            foreach ($line in ($nvOut -split "`r?`n")) {
                $line = $line.Trim()
                if ($line -match '^\d+') {
                    $parts = $line -split ',\s*', 2
                    $vmb   = [int]$parts[0].Trim()
                    $name  = if ($parts.Count -gt 1) { $parts[1].Trim() } else { "NVIDIA GPU $idx" }
                    $gpus.Add(@{ index = $idx; name = $name; vram_mb = $vmb; vendor = "nvidia" })
                    $idx++
                }
            }
        }
    } catch {}

    # Fall back to WMI for AMD/Intel (skips iGPUs with < 1 GB adapter RAM)
    if ($gpus.Count -eq 0) {
        try {
            $wmiGpus = Get-WmiObject Win32_VideoController |
                       Where-Object { $_.AdapterRAM -gt 1073741824 } |
                       Sort-Object AdapterRAM -Descending
            $idx = 0
            foreach ($wg in $wmiGpus) {
                $vmb    = [int]($wg.AdapterRAM / 1MB)
                $name   = $wg.Name
                $vendor = if ($name -match "NVIDIA") { "nvidia" }
                          elseif ($name -match "AMD|Radeon") { "amd" }
                          else { "unknown" }
                $gpus.Add(@{ index = $idx; name = $name; vram_mb = $vmb; vendor = $vendor })
                $idx++
            }
        } catch {}
    }

    $gpuCount = $gpus.Count
    # Use maximum VRAM across all cards for the intensity recommendation
    $maxVram = if ($gpuCount -gt 0) {
        ($gpus | ForEach-Object { $_.vram_mb } | Measure-Object -Maximum).Maximum
    } else { 0 }

    # Compute recommended intensity from V-buffer formula (75% of max-VRAM target)
    # V-buffer bytes = 2^E * 128 KB  (E = 14 + intensity/100*6)
    $recInt = 8   # safe fallback when VRAM unknown
    if ($maxVram -gt 0) {
        $target = [double]$maxVram * 1048576.0 * 0.75
        $e = [Math]::Floor([Math]::Log($target / 131072.0) / [Math]::Log(2.0))
        if ($e -lt 14) { $e = 14 }
        $recInt = [int][Math]::Floor(($e - 13.5) * 100.0 / 6.0 - 0.001)
        if ($recInt -lt 5)  { $recInt = 5 }
        if ($recInt -gt 95) { $recInt = 95 }
    }

    # Cache to config.env. Also default GPU_DEVICE to "all" when multiple GPUs
    # are present and the user has never explicitly set a device override.
    try {
        $lines   = @(Get-Content $script:CONFIG)
        $hadVram = $false; $hadRec = $false; $hadCnt = $false; $devSet = $false
        $existingDev = ($lines | Where-Object { $_ -match '^GPU_DEVICE=' } | Select-Object -First 1) -replace '^GPU_DEVICE=',''
        $newLines = @(foreach ($line in $lines) {
            if     ($line -match '^GPU_VRAM_MB=')        { "GPU_VRAM_MB=$maxVram";    $hadVram = $true }
            elseif ($line -match '^GPU_REC_INTENSITY=')  { "GPU_REC_INTENSITY=$recInt"; $hadRec = $true }
            elseif ($line -match '^GPU_DETECTED_COUNT=') { "GPU_DETECTED_COUNT=$gpuCount"; $hadCnt = $true }
            else { $line }
        })
        if (-not $hadVram) { $newLines += "GPU_VRAM_MB=$maxVram" }
        if (-not $hadRec)  { $newLines += "GPU_REC_INTENSITY=$recInt" }
        if (-not $hadCnt)  { $newLines += "GPU_DETECTED_COUNT=$gpuCount" }
        # Default GPU_DEVICE to "all" for multi-GPU rigs when not explicitly configured
        if ($gpuCount -gt 1 -and (-not $existingDev -or $existingDev -eq '0')) {
            if (-not ($newLines -match '^GPU_DEVICE=')) { $newLines += "GPU_DEVICE=all" }
            else { $newLines = $newLines -replace '^GPU_DEVICE=.*$', 'GPU_DEVICE=all' }
        }
        [System.IO.File]::WriteAllLines($script:CONFIG, $newLines, (New-Object System.Text.UTF8Encoding $false))
    } catch {}

    return @{ vram_mb = $maxVram; rec_intensity = $recInt; gpu_count = $gpuCount }
}

function Get-MinerProcess {
    # Try saved PID first — reliable even if the name lookup fails
    if (Test-Path $script:MINERPIDF) {
        try {
            $savedPid = [int]((Get-Content $script:MINERPIDF -Raw -ErrorAction Stop).Trim())
            $p = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
            if ($p -and $p.Name -match 'dagtech') { return $p }
        } catch {}
    }
    # Fall back to name search
    return Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Build-MinerArgList([hashtable]$cfg) {
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.AddRange([string[]]@(
        "--wallet",       $(if ($cfg["WALLET"]) {
                              $wn = if ($cfg["WORKER_NAME"]) { $cfg["WORKER_NAME"] } else { "" }
                              if ($wn) { "$($cfg['WALLET']).$wn" } else { $cfg["WALLET"] }
                          } else { "" }),
        "--pool",         $(if ($cfg["POOL_HOST"])   { $cfg["POOL_HOST"] }   else { "" }),
        "--port",         $(if ($cfg["POOL_PORT"])   { $cfg["POOL_PORT"] }   else { "3334" }),
        "--threads",      $(if ($cfg["THREADS"])     { $cfg["THREADS"] }     else { "1" }),
        "--worker",       $(if ($cfg["WORKER_NAME"]) { $cfg["WORKER_NAME"] } else { "dagtech" }),
        "--cpu-limit",    $(if ($cfg["CPU_LIMIT"])   { $cfg["CPU_LIMIT"] }   else { "100" }),
        "--metrics-port", $(if ($cfg["METRICS_PORT"]){ $cfg["METRICS_PORT"]} else { "8882" }),
        "--dashboard-dir",(Join-Path $script:BASE "dashboard")
    ))
    if ($cfg["POOL_PASSWORD"]) { $argList.Add("--password"); $argList.Add($cfg["POOL_PASSWORD"]) }

    # GPU flags
    $gpuEnabled = $cfg["GPU_ENABLED"]
    if ($gpuEnabled -eq "1") {
        $argList.Add("--gpu")
        if ($cfg["GPU_INTENSITY"]) { $argList.Add("--gpu-intensity"); $argList.Add($cfg["GPU_INTENSITY"]) }
        if ($cfg["GPU_THROTTLE"])  { $argList.Add("--gpu-throttle");  $argList.Add($cfg["GPU_THROTTLE"]) }
        if ($cfg["GPU_PLATFORM"])  { $argList.Add("--gpu-platform");  $argList.Add($cfg["GPU_PLATFORM"]) }
        if ($cfg["GPU_DEVICE"])    { $argList.Add("--gpu-device");    $argList.Add($cfg["GPU_DEVICE"]) }
    } elseif ($gpuEnabled -eq "0") {
        $argList.Add("--no-gpu")
    }
    Write-Output -NoEnumerate $argList
}

function Start-MinerProcess {
    if (Get-MinerProcess) { return }
    $cfg = Read-Config
    $logFile = Join-Path $script:LOGDIR "miner_$(Get-Date -Format 'yyyy-MM-dd').log"
    $argList = Build-MinerArgList $cfg
    Write-Log "Starting GPU miner..."
    $proc = Start-Process -FilePath $script:BIN -ArgumentList $argList.ToArray() `
        -RedirectStandardOutput $logFile -RedirectStandardError $logFile.Replace('.log','.err.log') `
        -NoNewWindow -PassThru
    if ($proc) {
        try { "$($proc.Id)" | Out-File $script:MINERPIDF -Encoding ASCII -Force } catch {}
        Write-Log "GPU miner started (PID $($proc.Id))"
        $script:MinerStartedAt       = [datetime]::UtcNow
        $script:GpuPlatformCheckDone = $false
    }
}

function Stop-MinerProcess {
    "" | Out-File $script:STOPFILE -Force -Encoding ASCII
    # Kill by tracked PID first (most reliable)
    $killedPid = $null
    if (Test-Path $script:MINERPIDF) {
        try {
            $savedPid = [int]((Get-Content $script:MINERPIDF -Raw -ErrorAction Stop).Trim())
            $p = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
            if ($p) { $p | Stop-Process -Force -ErrorAction SilentlyContinue; $killedPid = $savedPid }
        } catch {}
        Remove-Item $script:MINERPIDF -Force -ErrorAction SilentlyContinue
    }
    # Also sweep by name to catch any instance not tracked by PID
    Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Log "Miner stopped (pid=$killedPid)."
}

function Send-Response {
    param($ctx, [string]$body, [int]$status = 200, [string]$contentType = "application/json")
    try {
        $res = $ctx.Response
        $res.StatusCode = $status
        $res.ContentType = $contentType
        $res.Headers["Access-Control-Allow-Origin"]  = "*"
        $res.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        $res.Headers["Access-Control-Allow-Headers"] = "Content-Type"
        $res.Headers["Connection"] = "close"   # release socket immediately; prevents CLOSE_WAIT buildup
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Flush()
        $res.Close()
    } catch {
        try { $ctx.Response.Abort() } catch { }  # force-release socket if client disconnected first
    }
}

# Watchdog — checked inline on the main thread after each request (no threading issues)
$script:LastWatchdog       = [datetime]::UtcNow
$script:MinerDownSince     = $null   # set when miner is first detected as not running
$script:LastRestartAttempt = $null   # set after each restart attempt
$script:WatchdogRestarts   = 0       # attempt count; resets when miner comes back up
$script:MinerStartedAt          = $null   # set in Start-MinerProcess; used by GPU platform check
$script:GpuPlatformCheckDone    = $false  # reset on each miner start; prevents repeated checks
$script:LastJobSeenAt           = $null   # updated by watchdog when a New job: line is found

# Detect GPU VRAM and cache recommended intensity to config (runs once; no-op if already cached)
$null = Detect-GpuVram

# ─── Background cache refresher ─────────────────────────────────────────────
# /sysinfo and /gpu-stats run WMI/nvidia-smi queries that take 2-8 seconds.
# Running them on the single-threaded request loop blocks all queued requests;
# clients time out and send FIN → server responds to a closed socket →
# CLOSE_WAIT accumulates until the listener stops accepting connections.
# RunSpaces share the same PowerShell process and hit a per-process WMI lock.
# Fix: Start-Job (a NEW powershell.exe process) runs the collection loop and
# writes results to temp files. The main loop reads those files in < 1 ms.
$script:SysinfoFile  = Join-Path $script:LOGDIR "sysinfo.cache.json"
$script:GpuStatsFile = Join-Path $script:LOGDIR "gpustats.cache.json"
$script:MetricsFile  = Join-Path $script:LOGDIR "metrics.cache.json"
$script:CacheJob     = $null

function Start-CacheRefresher {
    if ($script:CacheJob) {
        Stop-Job  $script:CacheJob -ErrorAction SilentlyContinue
        Remove-Job $script:CacheJob -Force -ErrorAction SilentlyContinue
        $script:CacheJob = $null
    }

    $script:CacheJob = Start-Job -ScriptBlock {
        param($configPath, $siFile, $gsFile, $siTmp, $gsTmp, $mFile, $mTmp, $logDir)

        # ── Per-job state for metrics ──────────────────────────────────────────
        $lastJobSeenAt = $null   # tracks when last "New job:" was seen in log

        function Get-SysinfoJson {
            $out = @{}
            try {
                $load = (Get-CimInstance Win32_Processor -OperationTimeoutSec 2 |
                         Measure-Object -Property LoadPercentage -Average).Average
                $out["cpu_usage"] = [math]::Round([double]$load, 1)
            } catch {}
            try {
                $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 2
                $out["mem_used_mb"]  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024)
                $out["mem_total_mb"] = [math]::Round($os.TotalVisibleMemorySize / 1024)
            } catch {}
            try {
                $lhm = Get-CimInstance -Namespace root/OpenHardwareMonitor -ClassName Sensor `
                           -OperationTimeoutSec 2 -ErrorAction Stop |
                       Where-Object { $_.SensorType -eq "Temperature" }
                if ($lhm) {
                    $cpuPkg = $lhm | Where-Object { $_.Name -match "CPU Package|CPU Tdie|Tdie|Package" } | Select-Object -First 1
                    if (-not $cpuPkg) { $cpuPkg = $lhm | Where-Object { $_.Identifier -match "/cpu/" } | Select-Object -First 1 }
                    if ($cpuPkg) { $out["cpu_temp"] = [math]::Round([double]$cpuPkg.Value, 1) }
                    $gpuTemp = $lhm | Where-Object { $_.Identifier -match "/gpu" -and $_.Name -match "GPU Core|GPU Temperature|Temperature" } | Select-Object -First 1
                    if ($gpuTemp) { $out["gpu_temp"] = [math]::Round([double]$gpuTemp.Value, 1) }
                }
            } catch {}
            if (-not $out.ContainsKey("cpu_temp")) {
                try {
                    $zones = Get-CimInstance -Namespace root/WMI -ClassName MSAcpi_ThermalZoneTemperature `
                                 -OperationTimeoutSec 2 -ErrorAction Stop
                    $temps = @($zones | ForEach-Object { ($_.CurrentTemperature - 2732) / 10.0 })
                    if ($temps.Count -gt 0) {
                        $out["cpu_temp"] = [math]::Round(($temps | Measure-Object -Maximum).Maximum, 1)
                    }
                } catch {}
            }
            $gpusSysinfo = [System.Collections.Generic.List[string]]::new()
            if (-not $out.ContainsKey("gpu_temp")) {
                try {
                    $nvPaths = @("nvidia-smi",
                        "C:\Windows\System32\nvidia-smi.exe",
                        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
                        (Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"))
                    $nvExe = $nvPaths | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
                    if ($nvExe) {
                        $nv = & $nvExe --query-gpu=temperature.gpu,utilization.gpu,name --format=csv,noheader,nounits 2>$null
                        if ($nv) {
                            $gIdx = 0
                            foreach ($nvLine in ($nv -split "`r?`n")) {
                                $nvLine = $nvLine.Trim()
                                if (-not $nvLine) { continue }
                                $p = $nvLine -split ',\s*'
                                if ($p.Count -ge 3) {
                                    $gTemp  = [double]$p[0].Trim()
                                    $gUsage = [double]$p[1].Trim()
                                    $gName  = ($p[2].Trim() -replace '"',"'")
                                    if ($gIdx -eq 0) {
                                        $out["gpu_temp"]   = $gTemp
                                        $out["gpu_usage"]  = $gUsage
                                        $out["gpu_name"]   = $p[2].Trim()
                                        $out["gpu_vendor"] = "nvidia"
                                    }
                                    $gpusSysinfo.Add('{"index":' + $gIdx + ',"temp":' + $gTemp +
                                        ',"usage":' + $gUsage + ',"name":"' + $gName + '","vendor":"nvidia"}')
                                    $gIdx++
                                }
                            }
                        }
                    }
                } catch {}
            }
            if (-not $out.ContainsKey("gpu_name")) {
                try {
                    $gpu = Get-CimInstance Win32_VideoController -OperationTimeoutSec 2 | Select-Object -First 1
                    if ($gpu) {
                        $out["gpu_name"]   = $gpu.Name
                        $out["gpu_vendor"] = if ($gpu.Name -match "NVIDIA") { "nvidia" }
                                             elseif ($gpu.Name -match "AMD|Radeon") { "amd" }
                                             else { "unknown" }
                    }
                } catch {}
            }
            if (-not $out.ContainsKey("gpu_usage")) {
                try {
                    $s = Get-Counter '\GPU Engine(*engtype_3D*)\Utilization Percentage' -ErrorAction Stop -MaxSamples 1
                    $usage = ($s.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum
                    if ($null -ne $usage) { $out["gpu_usage"] = [math]::Round([double]$usage, 1) }
                } catch {}
            }
            $kvs = @()
            foreach ($k in $out.Keys) {
                $v = $out[$k]
                if ($v -is [string]) { $kvs += ('"' + $k + '":"' + ($v.Replace('\','\\').Replace('"','\"')) + '"') }
                else                 { $kvs += ('"' + $k + '":' + $v) }
            }
            $gpusSysinfoJson = if ($gpusSysinfo.Count -gt 0) { '[' + ($gpusSysinfo -join ',') + ']' } else { '[]' }
            $kvs += '"gpus":' + $gpusSysinfoJson
            return '{' + ($kvs -join ',') + '}'
        }

        function Get-GpuStatsJson {
            $cfg = @{}
            if (Test-Path $configPath) {
                Get-Content $configPath | ForEach-Object {
                    if ($_ -match '^([A-Z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
                }
            }
            $gpuEnabled   = $cfg["GPU_ENABLED"] -eq "1"
            $gpuIntensity = if ($cfg["GPU_INTENSITY"])     { $cfg["GPU_INTENSITY"] }          else { "80" }
            $gpuThrottle  = if ($cfg["GPU_THROTTLE"])      { [int]$cfg["GPU_THROTTLE"] }      else { 100 }
            $gpuPlatform  = if ($cfg["GPU_PLATFORM"])      { [int]$cfg["GPU_PLATFORM"] }      else { 0 }
            $gpuDevice    = if ($cfg["GPU_DEVICE"])        { $cfg["GPU_DEVICE"].Trim() }      else { "0" }
            $gpuVramMb    = if ($cfg["GPU_VRAM_MB"])       { [int]$cfg["GPU_VRAM_MB"] }       else { 0 }
            $gpuRecInt    = if ($cfg["GPU_REC_INTENSITY"]) { [int]$cfg["GPU_REC_INTENSITY"] } else { -1 }
            $enabledStr   = if ($gpuEnabled) { "true" } else { "false" }
            $gpuItems     = [System.Collections.Generic.List[string]]::new()
            $nvOut = $null
            try { $nvOut = & nvidia-smi --query-gpu=memory.total,name --format=csv,noheader,nounits 2>$null } catch {}
            try {
                if ($nvOut) {
                    $idx = 0
                    foreach ($nvLine in ($nvOut -split "`r?`n")) {
                        $nvLine = $nvLine.Trim()
                        if ($nvLine -match '^\d+') {
                            $parts = $nvLine -split ',\s*', 2
                            $vmb   = [int]$parts[0].Trim()
                            $gname = if ($parts.Count -gt 1) { ($parts[1].Trim() -replace '"',"'") } else { "NVIDIA GPU $idx" }
                            $gRec  = 8
                            if ($vmb -gt 0) {
                                $gt = [double]$vmb * 1048576.0 * 0.75
                                $ge = [Math]::Floor([Math]::Log($gt / 131072.0) / [Math]::Log(2.0))
                                if ($ge -lt 14) { $ge = 14 }
                                $gRec = [int][Math]::Floor(($ge - 13.5) * 100.0 / 6.0 - 0.001)
                                if ($gRec -lt 5)  { $gRec = 5 }
                                if ($gRec -gt 95) { $gRec = 95 }
                            }
                            $gpuItems.Add('{"index":' + $idx + ',"name":"' + $gname + '","vram_mb":' + $vmb +
                                ',"rec_intensity":' + $gRec + ',"vendor":"nvidia"}')
                            $idx++
                        }
                    }
                }
            } catch {}
            if ($gpuItems.Count -eq 0) {
                try {
                    $idx = 0
                    foreach ($wg in (Get-WmiObject Win32_VideoController |
                                     Where-Object { $_.AdapterRAM -gt 1073741824 } |
                                     Sort-Object AdapterRAM -Descending)) {
                        $vmb    = [int]($wg.AdapterRAM / 1MB)
                        $gname  = ($wg.Name -replace '"',"'")
                        $vendor = if ($gname -match "NVIDIA") { "nvidia" }
                                  elseif ($gname -match "AMD|Radeon") { "amd" }
                                  else { "unknown" }
                        $gRec   = 8
                        if ($vmb -gt 0) {
                            $gt = [double]$vmb * 1048576.0 * 0.75
                            $ge = [Math]::Floor([Math]::Log($gt / 131072.0) / [Math]::Log(2.0))
                            if ($ge -lt 14) { $ge = 14 }
                            $gRec = [int][Math]::Floor(($ge - 13.5) * 100.0 / 6.0 - 0.001)
                            if ($gRec -lt 5)  { $gRec = 5 }
                            if ($gRec -gt 95) { $gRec = 95 }
                        }
                        $gpuItems.Add('{"index":' + $idx + ',"name":"' + $gname + '","vram_mb":' + $vmb +
                            ',"rec_intensity":' + $gRec + ',"vendor":"' + $vendor + '"}')
                        $idx++
                    }
                } catch {}
            }
            $gpuListJson   = if ($gpuItems.Count -gt 0) { '[' + ($gpuItems -join ',') + ']' } else { '[]' }
            $intensityJson = if ($gpuIntensity -match '^\d') { $gpuIntensity } else { '"' + $gpuIntensity + '"' }
            $deviceJson    = '"' + ($gpuDevice -replace '"',"'") + '"'
            return ('{"gpu_enabled":' + $enabledStr +
                ',"gpu_intensity":' + $intensityJson +
                ',"gpu_throttle":' + $gpuThrottle +
                ',"gpu_platform":' + $gpuPlatform +
                ',"gpu_device":' + $deviceJson +
                ',"gpu_vram_mb":' + $gpuVramMb +
                ',"gpu_rec_intensity":' + $gpuRecInt +
                ',"gpus":' + $gpuListJson + '}')
        }

        function Get-MetricsJson {
            param($configPath, $logDir)
            $cfg = @{}
            if (Test-Path $configPath) {
                Get-Content $configPath | ForEach-Object {
                    if ($_ -match '^([A-Z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
                }
            }
            $miningMode  = if ($cfg["MINING_MODE"]) { $cfg["MINING_MODE"] } else { "both" }
            $metricsPort = if ($cfg["METRICS_PORT"]) { $cfg["METRICS_PORT"] } else { "8882" }

            # Find active log file (today's if it has content, otherwise most recent)
            $today   = Join-Path $logDir "miner_$(Get-Date -Format 'yyyy-MM-dd').log"
            $logFile = if ((Test-Path $today) -and (Get-Item $today -EA SilentlyContinue).Length -ge 200) { $today } else {
                Get-ChildItem $logDir -Filter "miner_*.log" -EA SilentlyContinue |
                    Where-Object { $_.Name -match '^miner_\d{4}-\d{2}-\d{2}\.log$' -and $_.Length -ge 200 } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
            }

            # Is the miner process running?
            $minerRunning = $null -ne (Get-Process -Name "dagtech-gpu-miner" -ErrorAction SilentlyContinue)

            $out = @{
                running       = $minerRunning
                wallet        = if ($cfg["WALLET"])            { $cfg["WALLET"] }                              else { "" }
                worker        = if ($cfg["WORKER_NAME"])       { $cfg["WORKER_NAME"] }                         else { "" }
                pool          = if ($cfg["POOL_HOST"])         { "$($cfg['POOL_HOST']):$($cfg['POOL_PORT'])" }  else { "" }
                threads       = if ($cfg["THREADS"])           { [int]$cfg["THREADS"] }                        else { 0 }
                version       = if ($cfg["INSTALLER_VERSION"]) { $cfg["INSTALLER_VERSION"] }                   else { "" }
                gpu_intensity = if ($cfg["GPU_INTENSITY"])     { [int]$cfg["GPU_INTENSITY"] }                   else { 80 }
                gpu_throttle  = if ($cfg["GPU_THROTTLE"])      { [int]$cfg["GPU_THROTTLE"] }                    else { 100 }
                mining_mode   = $miningMode
                pool_status   = "unknown"
                job_id        = ""
                last_job_secs_ago = $null
                hashrate         = 0.0
                cpu_hashrate     = 0.0
                gpu_hashrate     = 0.0
                accepted         = 0; submitted = 0; rejected = 0; stale = 0
                uptime           = 0; total_hashes = 0; difficulty = 0.0
                cpu_shares_found = 0; gpu_shares_found = 0
                cpu_submitted = 0; gpu_submitted = 0
                cpu_accepted  = 0; gpu_accepted  = 0
                cpu_rejected  = 0; gpu_rejected  = 0
                cpu_stale     = 0; gpu_stale     = 0
            }

            if ($logFile -and (Test-Path $logFile)) {
                try {
                    $fs     = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                    $content = $reader.ReadToEnd(); $reader.Close(); $fs.Close()
                    $lines = $content -split "`r?`n"
                    $out["cpu_shares_found"] = ($lines | Where-Object { $_ -match '\[DagTech\] \*\* SHARE FOUND \*\*' }).Count
                    $out["gpu_shares_found"] = ($lines | Where-Object { $_ -match '\[DagTech GPU\] \*\* SHARE FOUND \*\*' }).Count
                    $foundStats = $false; $foundDiff = $false; $foundJob = $false; $foundConn = $false
                    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                        if ($foundStats -and $foundDiff -and $foundJob -and $foundConn) { break }
                        $line = $lines[$i]
                        if (-not $foundStats -and $line -match '\[DagTech\]\s+([\d.]+)\s+H/s\s+\|\s+CPU:\s+([\d.]+)\s+H/s\s+\|\s+GPU:\s+([\d.]+)\s+H/s\s+\|\s+Shares:\s+(\d+)/(\d+)/(\d+)/(\d+).*Uptime:\s+(\d+)h(\d+)m') {
                            $out["hashrate"]=[double]$Matches[1]; $out["cpu_hashrate"]=[double]$Matches[2]; $out["gpu_hashrate"]=[double]$Matches[3]
                            $out["submitted"]=[int]$Matches[4]; $out["accepted"]=[int]$Matches[5]; $out["rejected"]=[int]$Matches[6]; $out["stale"]=[int]$Matches[7]
                            $us=[int]$Matches[8]*3600+[int]$Matches[9]*60; $out["uptime"]=$us; $out["total_hashes"]=[long]([double]$Matches[1]*$us); $foundStats=$true
                        }
                        if (-not $foundStats -and $line -match '\[DagTech\]\s+([\d.]+)\s+H/s\s+\|\s+Shares:\s+(\d+)/(\d+)/(\d+)/(\d+).*Uptime:\s+(\d+)h(\d+)m') {
                            $out["hashrate"]=[double]$Matches[1]; $out["submitted"]=[int]$Matches[2]; $out["accepted"]=[int]$Matches[3]; $out["rejected"]=[int]$Matches[4]; $out["stale"]=[int]$Matches[5]
                            $us=[int]$Matches[6]*3600+[int]$Matches[7]*60; $out["uptime"]=$us; $out["total_hashes"]=[long]([double]$Matches[1]*$us); $foundStats=$true
                        }
                        if (-not $foundDiff -and $line -match '\[DagTech\]\s+Difficulty:\s+([\d.]+)') { $out["difficulty"]=[double]$Matches[1]; $foundDiff=$true }
                        if (-not $foundJob  -and $line -match '\[DagTech\]\s+New job:\s+(\S+)')       { $out["job_id"]=$Matches[1]; $foundJob=$true; $lastJobSeenAt=[datetime]::UtcNow }
                        if (-not $foundConn) {
                            if     ($line -match '\[DagTech\] Connected!')           { $out["pool_status"]="connected";    $foundConn=$true }
                            elseif ($line -match '\[DagTech\] New job:')             { $out["pool_status"]="connected";    $foundConn=$true }
                            elseif ($line -match '\[DagTech\] Pool connection lost') { $out["pool_status"]="disconnected"; $foundConn=$true }
                            elseif ($line -match '\[DagTech\] Reconnecting')         { $out["pool_status"]="reconnecting"; $foundConn=$true }
                            elseif ($line -match '\[DagTech\] Connecting to pool')   { $out["pool_status"]="connecting";   $foundConn=$true }
                            elseif ($line -match '\[DagTech\] Waiting for work')     { $out["pool_status"]="connecting";   $foundConn=$true }
                        }
                    }
                } catch {}
            }
            if ($lastJobSeenAt) { $out["last_job_secs_ago"] = [int]([datetime]::UtcNow - $lastJobSeenAt).TotalSeconds }

            # Pull authoritative stats from the miner's own metrics endpoint (8882).
            # The miner computes hashrate/share totals correctly for ANY GPU count,
            # whereas the log-line scrape above only matches the single-GPU format
            # ("... | GPU: <n> H/s | ...") and silently reads ZERO when 2+ GPUs are
            # active (multi-GPU logs print "... | GPU[0]: x | GPU[1]: y | ..."). So
            # when the API is reachable, its numbers win; the log scrape stays as the
            # fallback for the brief window before the miner's HTTP server is up.
            try {
                $wr = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$metricsPort/metrics")
                $wr.Timeout = 2000; $wr.ReadWriteTimeout = 2000; $wr.Method = "GET"; $wr.Proxy = $null
                $resp = $wr.GetResponse()
                $mr   = [System.IO.StreamReader]::new($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $mj   = $mr.ReadToEnd() | ConvertFrom-Json; $mr.Close(); $resp.Close()
                # Per-source share counters (only available from the API)
                foreach ($f in @("cpu_submitted","gpu_submitted","cpu_accepted","gpu_accepted","cpu_rejected","gpu_rejected","cpu_stale","gpu_stale")) {
                    if ($null -ne $mj.$f) { $out[$f] = [long]$mj.$f }
                }
                # Hashrates (doubles) — broken by the multi-GPU log format
                foreach ($f in @("hashrate","cpu_hashrate","gpu_hashrate")) {
                    if ($null -ne $mj.$f) { $out[$f] = [double]$mj.$f }
                }
                # Aggregate counters / uptime / total hashes (longs) — same breakage
                foreach ($f in @("submitted","accepted","rejected","stale","total_hashes","uptime")) {
                    if ($null -ne $mj.$f) { $out[$f] = [long]$mj.$f }
                }
                # CPU identity (string + int) for the dashboard System card
                if ($null -ne $mj.cpu_name)  { $out["cpu_name"]  = [string]$mj.cpu_name }
                if ($null -ne $mj.cpu_cores) { $out["cpu_cores"] = [long]$mj.cpu_cores }
            } catch {}

            $kvs = @()
            foreach ($k in $out.Keys) {
                $v = $out[$k]
                if     ($v -is [bool])   { $kvs += '"' + $k + '":' + ($v.ToString().ToLower()) }
                elseif ($null -eq $v)    { $kvs += '"' + $k + '":null' }
                elseif ($v -is [string]) { $kvs += '"' + $k + '":"' + ($v.Replace('\','\\').Replace('"','\"')) + '"' }
                else                     { $kvs += '"' + $k + '":' + ($v.ToString([System.Globalization.CultureInfo]::InvariantCulture)) }
            }
            return '{' + ($kvs -join ',') + '}'
        }

        while ($true) {
            try {
                $json = Get-SysinfoJson
                [System.IO.File]::WriteAllText($siTmp, $json, [System.Text.Encoding]::UTF8)
                Move-Item $siTmp $siFile -Force -ErrorAction Stop
            } catch {}
            try {
                $json = Get-GpuStatsJson
                [System.IO.File]::WriteAllText($gsTmp, $json, [System.Text.Encoding]::UTF8)
                Move-Item $gsTmp $gsFile -Force -ErrorAction Stop
            } catch {}
            try {
                $json = Get-MetricsJson -configPath $configPath -logDir $logDir
                [System.IO.File]::WriteAllText($mTmp, $json, [System.Text.Encoding]::UTF8)
                Move-Item $mTmp $mFile -Force -ErrorAction Stop
            } catch {}
            Start-Sleep -Seconds 4
        }
    } -ArgumentList $script:CONFIG, $script:SysinfoFile, $script:GpuStatsFile, ($script:SysinfoFile + '.tmp'), ($script:GpuStatsFile + '.tmp'), $script:MetricsFile, ($script:MetricsFile + '.tmp'), $script:LOGDIR

    Write-Log "Background cache refresher started (Job $($script:CacheJob.Id))."
}

# Start cache refresh job — runs WMI/nvidia-smi in a separate process so
# the synchronous request loop is never blocked on slow queries.
Start-CacheRefresher

# Start listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:8883/")
try {
    $listener.Start()
} catch {
    Write-Host "ERROR: Could not bind port 8883 - is another instance already running?"
    exit 1
}

Write-Log "Control server listening on http://127.0.0.1:8883/"

# ── Reconcile miner state ─────────────────────────────────────────────────────
# Ensure exactly ONE miner — running the CURRENT on-disk binary — is alive, and
# act only on the delta:
#   • Graceful control-server restart: a healthy miner running the current binary
#     is ADOPTED (left untouched), so the restart is gap-free.
#   • Reinstall / binary update: a miner started before the current binary's mtime
#     is stale, so it is cycled to pick up the new binary.
#   • Crash / reinstall race / forced logoff: any duplicate or untracked miner is
#     swept, then one fresh miner is started.
# A control-server (re)start resumes mining, so clear any leftover stop file first.
if (Test-Path $script:STOPFILE) { Remove-Item $script:STOPFILE -Force }

$trackedPid = $null
if (Test-Path $script:MINERPIDF) {
    try { $trackedPid = [int]((Get-Content $script:MINERPIDF -Raw).Trim()) } catch { $trackedPid = $null }
}
$tracked = if ($trackedPid) { Get-Process -Id $trackedPid -ErrorAction SilentlyContinue } else { $null }

# Adopt the tracked miner only if it is alive AND was started after the current
# binary was written (i.e. it is running the current build, not a stale one).
$adopt = $false
if ($tracked -and $tracked.Name -match 'dagtech') {
    try {
        $binMtime = (Get-Item $script:BIN).LastWriteTimeUtc
        if ($tracked.StartTime.ToUniversalTime() -ge $binMtime.AddSeconds(-5)) { $adopt = $true }   # 5s skew tolerance
    } catch { $adopt = $true }   # if the comparison fails, prefer adopting over a needless restart
}

# Sweep every miner that is NOT the one we are adopting (duplicates, stale orphans,
# or a process still running an outdated binary after a reinstall).
Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue |
    Where-Object { -not ($adopt -and $_.Id -eq $trackedPid) } |
    Stop-Process -Force -ErrorAction SilentlyContinue

if ($adopt) {
    Write-Log "Reconcile: adopted healthy miner PID $trackedPid (current binary) — no restart."
} else {
    Remove-Item $script:MINERPIDF -Force -ErrorAction SilentlyContinue
    Write-Log "Reconcile: no current healthy miner — starting fresh."
    Start-MinerProcess
}

# Synchronous request loop
while ($listener.IsListening) {
    try {
        $ctx    = $listener.GetContext()
        $method = $ctx.Request.HttpMethod
        $path   = $ctx.Request.Url.AbsolutePath

        if ($method -eq "OPTIONS") { Send-Response $ctx "" 204; continue }

        switch -exact ($path) {
            "/" {
                $html = [System.IO.File]::ReadAllText($script:DASHBOARD, [System.Text.Encoding]::UTF8)
                $ctx.Response.Headers["Cache-Control"] = "no-store"
                Send-Response $ctx $html 200 "text/html; charset=utf-8"
                break
            }
            "/logo.png" {
                $logoPath = Join-Path $BaseDir "dashboard\logo.png"
                if (Test-Path $logoPath) {
                    try {
                        $fileBytes = [System.IO.File]::ReadAllBytes($logoPath)
                        $ctx.Response.StatusCode = 200
                        $ctx.Response.ContentType = "image/png"
                        $ctx.Response.Headers["Cache-Control"] = "public, max-age=86400"
                        $ctx.Response.ContentLength64 = $fileBytes.Length
                        $ctx.Response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                        $ctx.Response.OutputStream.Flush()
                        $ctx.Response.Close()
                    } catch {}
                } else { Send-Response $ctx "" 404 }
                break
            }
            "/logo.ico" {
                $logoPath = Join-Path $BaseDir "dashboard\logo.ico"
                if (Test-Path $logoPath) {
                    try {
                        $fileBytes = [System.IO.File]::ReadAllBytes($logoPath)
                        $ctx.Response.StatusCode = 200
                        $ctx.Response.ContentType = "image/x-icon"
                        $ctx.Response.Headers["Cache-Control"] = "public, max-age=86400"
                        $ctx.Response.ContentLength64 = $fileBytes.Length
                        $ctx.Response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                        $ctx.Response.OutputStream.Flush()
                        $ctx.Response.Close()
                    } catch {}
                } else { Send-Response $ctx "" 404 }
                break
            }
            "/status" {
                $running = ($null -ne (Get-MinerProcess)).ToString().ToLower()
                $stopped = (Test-Path $script:STOPFILE).ToString().ToLower()
                Send-Response $ctx ('{"running":' + $running + ',"stopped":' + $stopped + ',"start_mode":"' + $script:StartMode + '"}')
                break
            }
            "/start" {
                if (Test-Path $script:STOPFILE) { Remove-Item $script:STOPFILE -Force }
                Start-MinerProcess
                Write-Log "Start command received via dashboard."
                Send-Response $ctx '{"ok":true}'
                break
            }
            "/stop" {
                Stop-MinerProcess
                Write-Log "Stop command received via dashboard."
                Send-Response $ctx '{"ok":true}'
                break
            }
            "/restart" {
                Write-Log "Restart command received via dashboard."
                $proc = Get-MinerProcess
                if ($proc) { $proc | Stop-Process -Force }
                if (Test-Path $script:STOPFILE) { Remove-Item $script:STOPFILE -Force }
                Start-Sleep -Milliseconds 1500
                Start-MinerProcess
                Send-Response $ctx '{"ok":true}'
                break
            }
            "/config" {
                if ($method -eq "POST") {
                    $rawBody = ""
                    try {
                        $ms = New-Object System.IO.MemoryStream
                        $ctx.Request.InputStream.CopyTo($ms)
                        $rawBody = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()).Trim()
                    } catch {}

                    if ($rawBody) {
                        try {
                            $newCfg    = ConvertFrom-Json -InputObject $rawBody
                            $propNames = $newCfg.PSObject.Properties.Name
                            $lines     = @(Get-Content $script:CONFIG)
                            $updatedKeys = @()
                            $newLines  = @(foreach ($line in $lines) {
                                if ($line -match '^([A-Z_]+)=(.*)$') {
                                    $k = $Matches[1]
                                    if ($propNames -contains $k) {
                                        $updatedKeys += $k
                                        "$k=$($newCfg.$k)"
                                    } else { $line }
                                } else { $line }
                            })
                            # Append any keys from the dashboard that weren't already in the file
                            foreach ($k in $propNames) {
                                if ($updatedKeys -notcontains $k) {
                                    $newLines += "$k=$($newCfg.$k)"
                                }
                            }
                            [System.IO.File]::WriteAllLines($script:CONFIG, $newLines, (New-Object System.Text.UTF8Encoding $false))
                            Write-Log "Config updated via dashboard."

                            $wasRunning = $null -ne (Get-MinerProcess)
                            if ($wasRunning) {
                                $proc = Get-MinerProcess
                                if ($proc) { $proc | Stop-Process -Force }
                                Start-Sleep -Milliseconds 1200
                                if (Test-Path $script:STOPFILE) { Remove-Item $script:STOPFILE -Force }
                                Start-MinerProcess
                                Write-Log "Miner restarted after config change."
                                Send-Response $ctx '{"ok":true,"restarted":true}'
                            } else {
                                Send-Response $ctx '{"ok":true,"restarted":false}'
                            }
                        } catch {
                            $msg = $_.Exception.Message -replace '"',"'" -replace '\r?\n',' '
                            Write-Log "Config POST error: $msg | body: $rawBody"
                            Send-Response $ctx ('{"error":"' + $msg + '"}') 400
                        }
                    } else {
                        Send-Response $ctx '{"error":"empty body"}' 400
                    }
                } else {
                    $cfg = Read-Config
                    $kvs = @()
                    foreach ($k in $cfg.Keys) {
                        $kvs += ('"' + $k + '":"' + ($cfg[$k].Replace('\','\\').Replace('"','\"')) + '"')
                    }
                    Send-Response $ctx ('{' + ($kvs -join ',') + '}')
                }
                break
            }
            "/run-autotune" {
                # Manual one-shot autotune: clear the cache so the miner re-sweeps,
                # ensure AUTOTUNE=1 so the sweep actually runs, then restart. The
                # miner benchmarks candidates, applies + re-caches the winner.
                if ($method -eq "POST") {
                    try {
                        $cfg = Read-Config
                        $cacheFile = if ($cfg["AUTOTUNE_CACHE"]) { $cfg["AUTOTUNE_CACHE"] } else { Join-Path $script:BASE "autotune.json" }
                        if (Test-Path $cacheFile) { Remove-Item $cacheFile -Force -ErrorAction SilentlyContinue }
                        $lines = @(Get-Content $script:CONFIG)
                        $hasKey = $false
                        $newLines = @(foreach ($l in $lines) {
                            if ($l -match '^AUTOTUNE=') { $hasKey = $true; 'AUTOTUNE=1' } else { $l }
                        })
                        if (-not $hasKey) { $newLines += 'AUTOTUNE=1' }
                        [System.IO.File]::WriteAllLines($script:CONFIG, $newLines, (New-Object System.Text.UTF8Encoding $false))
                        Write-Log "Run-autotune requested: cache cleared, AUTOTUNE=1, restarting miner."
                        $wasRunning = $null -ne (Get-MinerProcess)
                        if ($wasRunning) {
                            $proc = Get-MinerProcess
                            if ($proc) { $proc | Stop-Process -Force }
                            Start-Sleep -Milliseconds 1200
                            if (Test-Path $script:STOPFILE) { Remove-Item $script:STOPFILE -Force }
                            Start-MinerProcess
                            Send-Response $ctx '{"ok":true,"restarted":true}'
                        } else {
                            Send-Response $ctx '{"ok":true,"restarted":false}'
                        }
                    } catch {
                        $msg = $_.Exception.Message -replace '"',"'" -replace '\r?\n',' '
                        Write-Log "Run-autotune error: $msg"
                        Send-Response $ctx ('{"error":"' + $msg + '"}') 400
                    }
                } else {
                    Send-Response $ctx '{"error":"POST required"}' 405
                }
                break
            }
            "/autotune-status" {
                # Reports the saved tuning (from autotune.json) so the dashboard can
                # show "Tuned: split @ 8192" without the user digging into the log.
                $cfg = Read-Config
                $cacheFile = if ($cfg["AUTOTUNE_CACHE"]) { $cfg["AUTOTUNE_CACHE"] } else { Join-Path $script:BASE "autotune.json" }
                $valid = $false; $bs = 0; $mode = ""
                if (Test-Path $cacheFile) {
                    foreach ($l in (Get-Content $cacheFile -ErrorAction SilentlyContinue)) {
                        if     ($l -match '^valid=(\d+)')              { $valid = ([int]$Matches[1] -ne 0) }
                        elseif ($l -match '^selected_batchsize=(\d+)') { $bs    = [int]$Matches[1] }
                        elseif ($l -match '^selected_mode=(\w+)')      { $mode  = $Matches[1] }
                    }
                }
                # In-progress detection via the miner's marker file ("<cache>.running"),
                # written per-trial during a sweep and removed when it ends. Reliable
                # regardless of trial length or log volume (the old log-tail scan missed
                # long 60s trials). Treated as stale if the miner isn't actually running.
                $running = $false; $trial = 0; $total = 0
                $markerFile = "$cacheFile.running"
                if ((Test-Path $markerFile) -and ($null -ne (Get-MinerProcess))) {
                    $running = $true
                    foreach ($l in (Get-Content $markerFile -ErrorAction SilentlyContinue)) {
                        if     ($l -match '^trial=(\d+)') { $trial = [int]$Matches[1] }
                        elseif ($l -match '^total=(\d+)') { $total = [int]$Matches[1] }
                    }
                }
                $enabled = if ($cfg["AUTOTUNE"] -eq "1") { 'true' } else { 'false' }
                Send-Response $ctx ('{"enabled":' + $enabled + ',"valid":' + ($valid.ToString().ToLower()) + ',"batchsize":' + $bs + ',"mode":"' + $mode + '","running":' + ($running.ToString().ToLower()) + ',"trial":' + $trial + ',"total":' + $total + '}')
                break
            }
            "/gpu-stats" {
                # Background job (separate process) writes this every 4 s — main loop never blocks
                $json = if (Test-Path $script:GpuStatsFile) {
                    try { [System.IO.File]::ReadAllText($script:GpuStatsFile) } catch { $null }
                } else { $null }
                Send-Response $ctx $(if ($json) { $json } else { '{"gpu_enabled":false,"gpus":[]}' })
                break
            }
            "/_gpu-stats-old" {
                $cfg = Read-Config
                $gpuEnabled  = if ($cfg["GPU_ENABLED"])       { $cfg["GPU_ENABLED"] -eq "1" }  else { $false }
                $gpuIntensity= if ($cfg["GPU_INTENSITY"])     { $cfg["GPU_INTENSITY"] }          else { "80" }
                $gpuThrottle = if ($cfg["GPU_THROTTLE"])      { [int]$cfg["GPU_THROTTLE"] }      else { 100 }
                $gpuPlatform = if ($cfg["GPU_PLATFORM"])      { [int]$cfg["GPU_PLATFORM"] }      else { 0 }
                # GPU_DEVICE can be "0", "0,1", or "all" — keep as string, never cast to int
                $gpuDevice   = if ($cfg["GPU_DEVICE"])        { $cfg["GPU_DEVICE"].Trim() }      else { "0" }
                $gpuVramMb   = if ($cfg["GPU_VRAM_MB"])       { [int]$cfg["GPU_VRAM_MB"] }       else { 0 }
                $gpuRecInt   = if ($cfg["GPU_REC_INTENSITY"]) { [int]$cfg["GPU_REC_INTENSITY"] } else { -1 }
                $enabledStr  = if ($gpuEnabled) { "true" } else { "false" }

                # ── Enumerate all GPUs for the device picker ──────────────────
                # nvidia-smi and WMI are tried in separate try-catch blocks so a
                # "command not found" exception from a missing nvidia-smi never
                # prevents the AMD/WMI fallback from running.
                $gpuListJson = "[]"
                $gpuItems = [System.Collections.Generic.List[string]]::new()
                # Try nvidia-smi (NVIDIA GPUs)
                $nvOut = $null
                try { $nvOut = & nvidia-smi --query-gpu=memory.total,name --format=csv,noheader,nounits 2>$null } catch {}
                try {
                    if ($nvOut) {
                        $idx = 0
                        foreach ($nvLine in ($nvOut -split "`r?`n")) {
                            $nvLine = $nvLine.Trim()
                            if ($nvLine -match '^\d+') {
                                $parts = $nvLine -split ',\s*', 2
                                $vmb   = [int]$parts[0].Trim()
                                $gname = if ($parts.Count -gt 1) { ($parts[1].Trim() -replace '"',"'") } else { "NVIDIA GPU $idx" }
                                # Per-GPU rec intensity based on its own VRAM
                                $gRec = 8
                                if ($vmb -gt 0) {
                                    $gt = [double]$vmb * 1048576.0 * 0.75
                                    $ge = [Math]::Floor([Math]::Log($gt / 131072.0) / [Math]::Log(2.0))
                                    if ($ge -lt 14) { $ge = 14 }
                                    $gRec = [int][Math]::Floor(($ge - 13.5) * 100.0 / 6.0 - 0.001)
                                    if ($gRec -lt 5)  { $gRec = 5 }
                                    if ($gRec -gt 95) { $gRec = 95 }
                                }
                                $gpuItems.Add('{"index":' + $idx + ',"name":"' + $gname + '","vram_mb":' + $vmb + ',"rec_intensity":' + $gRec + ',"vendor":"nvidia"}')
                                $idx++
                            }
                        }
                    }
                } catch {}
                # AMD / Intel fallback via WMI (own try-catch so nvidia failure can't block it)
                if ($gpuItems.Count -eq 0) { try {
                    $idx = 0
                    foreach ($wg in (Get-WmiObject Win32_VideoController | Where-Object { $_.AdapterRAM -gt 1073741824 } | Sort-Object AdapterRAM -Descending)) {
                        $vmb   = [int]($wg.AdapterRAM / 1MB)
                        $gname = ($wg.Name -replace '"',"'")
                        $vendor = if ($gname -match "NVIDIA") { "nvidia" } elseif ($gname -match "AMD|Radeon") { "amd" } else { "unknown" }
                        $gRec = 8
                        if ($vmb -gt 0) {
                            $gt = [double]$vmb * 1048576.0 * 0.75
                            $ge = [Math]::Floor([Math]::Log($gt / 131072.0) / [Math]::Log(2.0))
                            if ($ge -lt 14) { $ge = 14 }
                            $gRec = [int][Math]::Floor(($ge - 13.5) * 100.0 / 6.0 - 0.001)
                            if ($gRec -lt 5)  { $gRec = 5 }
                            if ($gRec -gt 95) { $gRec = 95 }
                        }
                        $gpuItems.Add('{"index":' + $idx + ',"name":"' + $gname + '","vram_mb":' + $vmb + ',"rec_intensity":' + $gRec + ',"vendor":"' + $vendor + '"}')
                        $idx++
                    }
                } catch {} }
                if ($gpuItems.Count -gt 0) { $gpuListJson = '[' + ($gpuItems -join ',') + ']' }

                $intensityJson = if ($gpuIntensity -match '^\d') { $gpuIntensity } else { '"' + $gpuIntensity + '"' }
                $deviceJson    = '"' + ($gpuDevice -replace '"',"'") + '"'
                $script:_GpuStatsCache = ('{"gpu_enabled":' + $enabledStr +
                    ',"gpu_intensity":' + $intensityJson +
                    ',"gpu_throttle":' + $gpuThrottle +
                    ',"gpu_platform":' + $gpuPlatform +
                    ',"gpu_device":' + $deviceJson +
                    ',"gpu_vram_mb":' + $gpuVramMb +
                    ',"gpu_rec_intensity":' + $gpuRecInt +
                    ',"gpus":' + $gpuListJson + '}')
                break
            }
            "/open-logs" {
                if ($script:StartMode -ne "login") {
                    Send-Response $ctx '{"ok":false,"terminal":false}'
                    break
                }
                $logFile = Get-ActiveMinerLog
                $cmd = @"
`$Host.UI.RawUI.WindowTitle = 'DagTech GPU Miner - Live Log'
`$Host.UI.RawUI.BackgroundColor = 'Black'
Clear-Host
Write-Host '  DagTech GPU Miner - Live Log' -ForegroundColor Cyan
Write-Host '  ─────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''
`$log = '$($logFile -replace "'","''")'
while (-not (Test-Path `$log)) { Write-Host 'Waiting for log file...' -ForegroundColor DarkGray; Start-Sleep 2 }
Get-Content -Wait -Tail 50 `$log | ForEach-Object {
    if (`$_.Contains('[DagTech GPU]')) {
        Write-Host `$_ -ForegroundColor Magenta
    } elseif (`$_.Contains('[DagTech CPU]')) {
        Write-Host `$_ -ForegroundColor Green
    } elseif (`$_ -match 'SHARE FOUND|ACCEPTED') {
        Write-Host `$_ -ForegroundColor Cyan
    } elseif (`$_ -match 'ERROR|error|failed|FAILED') {
        Write-Host `$_ -ForegroundColor Red
    } elseif (`$_ -match 'WARN|warn') {
        Write-Host `$_ -ForegroundColor Yellow
    } elseif (`$_ -match 'Control server|Watchdog|Starting') {
        Write-Host `$_ -ForegroundColor Cyan
    } else {
        Write-Host `$_ -ForegroundColor Gray
    }
}
"@
                Start-Process powershell -ArgumentList "-NoProfile", "-NoExit", "-Command", $cmd
                Send-Response $ctx '{"ok":true,"terminal":true}'
                break
            }
            "/switch-mode" {
                if ($method -ne "POST") { Send-Response $ctx '{"error":"POST required"}' 405; break }
                $rawBody = ""
                try {
                    $ms = New-Object System.IO.MemoryStream
                    $ctx.Request.InputStream.CopyTo($ms)
                    $rawBody = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()).Trim()
                } catch {}
                $newMode = $null
                try {
                    $body = ConvertFrom-Json -InputObject $rawBody
                    if ($body.mode -eq "login" -or $body.mode -eq "service" -or $body.mode -eq "manual") { $newMode = $body.mode }
                } catch {}
                if (-not $newMode) { Send-Response $ctx '{"error":"invalid mode"}' 400; break }

                # Update START_MODE in config file
                try {
                    $lines = @(Get-Content $script:CONFIG)
                    $found = $false
                    $newLines = @(foreach ($line in $lines) {
                        if ($line -match '^START_MODE=') { "START_MODE=$newMode"; $found = $true }
                        else { $line }
                    })
                    if (-not $found) { $newLines += "START_MODE=$newMode" }
                    [System.IO.File]::WriteAllLines($script:CONFIG, $newLines, (New-Object System.Text.UTF8Encoding $false))
                    $script:StartMode = $newMode
                    Write-Log "Start mode updated to '$newMode' in config."
                } catch {
                    $msg = $_.Exception.Message -replace '"',"'"
                    Send-Response $ctx ('{"error":"Config update failed: ' + $msg + '"}') 500
                    break
                }

                # Manual mode: remove any existing task and write the stop sentinel.
                # The miner stays idle until the user explicitly clicks Start.
                if ($newMode -eq "manual") {
                    Unregister-ScheduledTask -TaskName $script:TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
                    if (-not (Test-Path $script:LOGDIR)) { New-Item -ItemType Directory -Path $script:LOGDIR -Force | Out-Null }
                    [System.IO.File]::WriteAllText($script:STOPFILE, "")
                    Write-Log "Switched to manual mode: scheduled task removed, stop sentinel written."
                    Send-Response $ctx '{"ok":true,"mode":"manual","requires_logoff":false}'
                    break
                }

                # Re-register the scheduled task with the new trigger/principal
                $requiresLogoff = $false
                $binDir = Split-Path $script:BIN
                $psArg  = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $binDir 'dagtech-control.ps1') + '"'
                try {
                    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArg
                    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
                    if ($newMode -eq "login") {
                        $interactiveUser = (Get-CimInstance Win32_ComputerSystem).UserName
                        if (-not $interactiveUser) { throw "Could not determine logged-in user" }
                        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $interactiveUser
                        $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Highest
                        $requiresLogoff = $true
                    } else {
                        $trigger   = New-ScheduledTaskTrigger -AtStartup
                        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
                    }
                    Unregister-ScheduledTask -TaskName $script:TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
                    $null = Register-ScheduledTask -TaskName $script:TASK_NAME -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop
                    Write-Log "Task '$($script:TASK_NAME)' re-registered as '$newMode' mode."
                } catch {
                    $msg = $_.Exception.Message -replace '"',"'"
                    # Config saved — report partial success with warning
                    $logoffStr = $requiresLogoff.ToString().ToLower()
                    Send-Response $ctx ('{"ok":true,"mode":"' + $newMode + '","requires_logoff":' + $logoffStr + ',"warn":"Task re-registration failed: ' + $msg + '"}')
                    break
                }
                $logoffStr = $requiresLogoff.ToString().ToLower()
                Send-Response $ctx ('{"ok":true,"mode":"' + $newMode + '","requires_logoff":' + $logoffStr + '}')
                break
            }
            "/logs" {
                $tail = 200
                try {
                    $qs = $ctx.Request.Url.Query
                    if ($qs -match '[?&]tail=(\d+)') { $tail = [int]$Matches[1] }
                } catch {}
                $logFile = Get-ActiveMinerLog
                $lines = @()
                if (Test-Path $logFile) {
                    try {
                        $fs = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                        $content = $reader.ReadToEnd()
                        $reader.Close(); $fs.Close()
                        $all = ($content -split "`r?`n") | Where-Object { $_ -ne '' }
                        $lines = if ($all.Count -gt $tail) { $all[($all.Count - $tail)..($all.Count - 1)] } else { $all }
                    } catch { $lines = @("Error reading log: $($_.Exception.Message)") }
                } else {
                    $lines = @("No log file for today yet.")
                }
                $escaped = $lines | ForEach-Object { '"' + ($_ -replace '\\','\\' -replace '"','\"') + '"' }
                Send-Response $ctx ('[' + ($escaped -join ',') + ']')
                break
            }
            "/sysinfo" {
                # Background job (separate process) writes this every 4 s — main loop never blocks
                $json = if (Test-Path $script:SysinfoFile) {
                    try { [System.IO.File]::ReadAllText($script:SysinfoFile) } catch { $null }
                } else { $null }
                Send-Response $ctx $(if ($json) { $json } else { '{"cpu_usage":0,"mem_used_mb":0,"mem_total_mb":0,"gpu_usage":0,"gpus":[]}' })
                break
            }
            "/_sysinfo-old" {
                $out = @{}

                # CPU usage — 2-second cap so a slow WMI call never blocks the server
                try {
                    $load = (Get-CimInstance Win32_Processor -OperationTimeoutSec 2 | Measure-Object -Property LoadPercentage -Average).Average
                    $out["cpu_usage"] = [math]::Round([double]$load, 1)
                } catch {}

                # Memory
                try {
                    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 2
                    $out["mem_used_mb"]  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024)
                    $out["mem_total_mb"] = [math]::Round($os.TotalVisibleMemorySize / 1024)
                } catch {}

                # Temperatures via LibreHardwareMonitor WMI
                try {
                    $lhmSensors = Get-CimInstance -Namespace root/OpenHardwareMonitor -ClassName Sensor -OperationTimeoutSec 2 -ErrorAction Stop |
                                  Where-Object { $_.SensorType -eq "Temperature" }
                    if ($lhmSensors) {
                        $cpuPkg = $lhmSensors | Where-Object { $_.Name -match "CPU Package|CPU Tdie|Tdie|Package" } | Select-Object -First 1
                        if (-not $cpuPkg) { $cpuPkg = $lhmSensors | Where-Object { $_.Identifier -match "/cpu/" } | Select-Object -First 1 }
                        if ($cpuPkg) { $out["cpu_temp"] = [math]::Round([double]$cpuPkg.Value, 1) }

                        $gpuTemp = $lhmSensors | Where-Object { $_.Identifier -match "/gpu" -and $_.Name -match "GPU Core|GPU Temperature|Temperature" } | Select-Object -First 1
                        if ($gpuTemp) { $out["gpu_temp"] = [math]::Round([double]$gpuTemp.Value, 1) }
                    }
                } catch {}

                # CPU temperature fallback
                if (-not $out.ContainsKey("cpu_temp")) {
                    try {
                        $zones = Get-CimInstance -Namespace root/WMI -ClassName MSAcpi_ThermalZoneTemperature -OperationTimeoutSec 2 -ErrorAction Stop
                        $temps = @($zones | ForEach-Object { ($_.CurrentTemperature - 2732) / 10.0 })
                        if ($temps.Count -gt 0) {
                            $out["cpu_temp"] = [math]::Round(($temps | Measure-Object -Maximum).Maximum, 1)
                        }
                    } catch {}
                }

                # NVIDIA GPU(s) — enumerate all cards, not just the first
                $gpusSysinfo = [System.Collections.Generic.List[string]]::new()
                if (-not $out.ContainsKey("gpu_temp")) { try {
                    $nvPaths = @(
                        "nvidia-smi",
                        "C:\Windows\System32\nvidia-smi.exe",
                        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
                        (Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe")
                    )
                    $nvExe = $nvPaths | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
                    if (-not $nvExe) {
                        $nvExe = Get-ChildItem "$env:SystemRoot\System32\nvidia-smi.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
                    }
                    if ($nvExe) {
                        $nv = & $nvExe --query-gpu=temperature.gpu,utilization.gpu,name --format=csv,noheader,nounits 2>$null
                        if ($nv) {
                            $gIdx = 0
                            foreach ($nvLine in ($nv -split "`r?`n")) {
                                $nvLine = $nvLine.Trim()
                                if (-not $nvLine) { continue }
                                $p = $nvLine -split ',\s*'
                                if ($p.Count -ge 3) {
                                    $gTemp  = [double]$p[0].Trim()
                                    $gUsage = [double]$p[1].Trim()
                                    $gName  = ($p[2].Trim() -replace '"',"'")
                                    # Primary card fields (first GPU — backward compat)
                                    if ($gIdx -eq 0) {
                                        $out["gpu_temp"]   = $gTemp
                                        $out["gpu_usage"]  = $gUsage
                                        $out["gpu_name"]   = $p[2].Trim()
                                        $out["gpu_vendor"] = "nvidia"
                                    }
                                    $gpusSysinfo.Add('{"index":' + $gIdx + ',"temp":' + $gTemp + ',"usage":' + $gUsage + ',"name":"' + $gName + '","vendor":"nvidia"}')
                                    $gIdx++
                                }
                            }
                        }
                    }
                } catch {} }

                # GPU name + vendor via WMI
                if (-not $out.ContainsKey("gpu_name")) {
                    try {
                        $gpu = Get-CimInstance Win32_VideoController -OperationTimeoutSec 2 | Select-Object -First 1
                        if ($gpu) {
                            $out["gpu_name"] = $gpu.Name
                            if ($gpu.Name -match "NVIDIA") { $out["gpu_vendor"] = "nvidia" }
                            elseif ($gpu.Name -match "AMD|Radeon") { $out["gpu_vendor"] = "amd" }
                            else { $out["gpu_vendor"] = "unknown" }
                        }
                    } catch {}
                }

                # GPU usage fallback via Windows perf counters — run in a background job with a
                # 2-second timeout so a slow counter never blocks the synchronous request loop.
                if (-not $out.ContainsKey("gpu_usage")) {
                    try {
                        $gpuJob = Start-Job {
                            $s = Get-Counter '\GPU Engine(*engtype_3D*)\Utilization Percentage' -ErrorAction Stop
                            ($s.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum
                        }
                        $null = $gpuJob | Wait-Job -Timeout 2
                        if ($gpuJob.State -eq 'Completed') {
                            $usage = Receive-Job $gpuJob -ErrorAction SilentlyContinue
                            if ($null -ne $usage) { $out["gpu_usage"] = [math]::Round([double]$usage, 1) }
                        }
                        Remove-Job $gpuJob -Force
                    } catch {}
                }

                $kvs = @()
                foreach ($k in $out.Keys) {
                    $v = $out[$k]
                    if ($v -is [string]) { $kvs += ('"' + $k + '":"' + ($v.Replace('\','\\').Replace('"','\"')) + '"') }
                    else                 { $kvs += ('"' + $k + '":' + $v) }
                }
                # Append per-GPU array so the dashboard can show per-card stats
                $gpusSysinfoJson = if ($gpusSysinfo.Count -gt 0) { '[' + ($gpusSysinfo -join ',') + ']' } else { '[]' }
                $kvs += '"gpus":' + $gpusSysinfoJson
                break
            }
            "/metrics" {
                # Fast path: serve the background-job cache written every 4 s.
                # Falls back to a live scan only if the cache doesn't exist yet.
                if (Test-Path $script:MetricsFile) {
                    try {
                        $cached = [System.IO.File]::ReadAllText($script:MetricsFile, [System.Text.Encoding]::UTF8)
                        Send-Response $ctx $cached
                        break
                    } catch {}
                }
                # ── Fallback: live scan (first few seconds before cache is ready) ──
                $cfg = Read-Config
                $minerRunning = $null -ne (Get-MinerProcess)
                $runningStr   = if ($minerRunning) { "true" } else { "false" }
                # Derive mining_mode from config
                $miningMode = if     ($cfg["MINING_MODE"])        { $cfg["MINING_MODE"] }
                              elseif ($cfg["GPU_ENABLED"] -eq "1") { "both" }
                              else                                  { "cpu" }

                $out = @{
                    wallet        = if ($cfg["WALLET"])             { $cfg["WALLET"] }                                   else { "" }
                    worker        = if ($cfg["WORKER_NAME"])        { $cfg["WORKER_NAME"] }                              else { "" }
                    pool          = if ($cfg["POOL_HOST"])          { $cfg["POOL_HOST"] + ":" + $cfg["POOL_PORT"] }      else { "" }
                    threads       = if ($cfg["THREADS"])            { [int]$cfg["THREADS"] }                             else { 0 }
                    version       = if ($cfg["INSTALLER_VERSION"])  { $cfg["INSTALLER_VERSION"] }                        else { "" }
                    gpu_intensity = if ($cfg["GPU_INTENSITY"])      { [int]$cfg["GPU_INTENSITY"] }                       else { 80 }
                    gpu_throttle  = if ($cfg["GPU_THROTTLE"])       { [int]$cfg["GPU_THROTTLE"] }                        else { 100 }
                    mining_mode   = $miningMode
                    pool_status      = "unknown"
                    job_id           = ""
                    last_job_secs_ago = if ($script:LastJobSeenAt) { [int]([datetime]::UtcNow - $script:LastJobSeenAt).TotalSeconds } else { $null }
                    hashrate         = 0.0
                    accepted         = 0
                    submitted        = 0
                    rejected         = 0
                    stale            = 0
                    uptime           = 0
                    total_hashes     = 0
                    difficulty       = 0.0
                    cpu_shares_found = 0
                    gpu_shares_found = 0
                    cpu_submitted    = 0
                    gpu_submitted    = 0
                    cpu_accepted     = 0
                    gpu_accepted     = 0
                    cpu_rejected     = 0
                    gpu_rejected     = 0
                    cpu_stale        = 0
                    gpu_stale        = 0
                }
                # Locate the log the miner is actually writing to — may be from a previous day
                # if the process started before midnight and has never been restarted.
                $logFile = Get-ActiveMinerLog
                if (Test-Path $logFile) {
                    try {
                        $fs     = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                        $content = $reader.ReadToEnd()
                        $reader.Close(); $fs.Close()
                        $lines = $content -split "`r?`n"
                        # Full-scan share counts — CPU and GPU have different log prefixes
                        $out["cpu_shares_found"] = ($lines | Where-Object { $_ -match '\[DagTech\] \*\* SHARE FOUND \*\*' }).Count
                        $out["gpu_shares_found"] = ($lines | Where-Object { $_ -match '\[DagTech GPU\] \*\* SHARE FOUND \*\*' }).Count
                        $foundStats = $false
                        $foundDiff  = $false
                        $foundJob   = $false
                        $foundConn  = $false
                        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                            if ($foundStats -and $foundDiff -and $foundJob -and $foundConn) { break }
                            $line = $lines[$i]
                            # Match GPU stats line: X.XX H/s | CPU: Y H/s | GPU: Z H/s | Shares: ...
                            if (-not $foundStats -and $line -match '\[DagTech\]\s+([\d.]+)\s+H/s\s+\|\s+CPU:\s+([\d.]+)\s+H/s\s+\|\s+GPU:\s+([\d.]+)\s+H/s\s+\|\s+Shares:\s+(\d+)/(\d+)/(\d+)/(\d+).*Uptime:\s+(\d+)h(\d+)m') {
                                $out["hashrate"]     = [double]$Matches[1]
                                $out["cpu_hashrate"] = [double]$Matches[2]
                                $out["gpu_hashrate"] = [double]$Matches[3]
                                $out["submitted"]    = [int]$Matches[4]
                                $out["accepted"]     = [int]$Matches[5]
                                $out["rejected"]     = [int]$Matches[6]
                                $out["stale"]        = [int]$Matches[7]
                                $uptimeSec           = [int]$Matches[8] * 3600 + [int]$Matches[9] * 60
                                $out["uptime"]       = $uptimeSec
                                $out["total_hashes"] = [long]($out["hashrate"] * $uptimeSec)
                                $foundStats = $true
                            }
                            # Also match CPU-only stats line
                            if (-not $foundStats -and $line -match '\[DagTech\]\s+([\d.]+)\s+H/s\s+\|\s+Shares:\s+(\d+)/(\d+)/(\d+)/(\d+).*Uptime:\s+(\d+)h(\d+)m') {
                                $out["hashrate"]     = [double]$Matches[1]
                                $out["submitted"]    = [int]$Matches[2]
                                $out["accepted"]     = [int]$Matches[3]
                                $out["rejected"]     = [int]$Matches[4]
                                $out["stale"]        = [int]$Matches[5]
                                $uptimeSec           = [int]$Matches[6] * 3600 + [int]$Matches[7] * 60
                                $out["uptime"]       = $uptimeSec
                                $out["total_hashes"] = [long]($out["hashrate"] * $uptimeSec)
                                $foundStats = $true
                            }
                            if (-not $foundDiff -and $line -match '\[DagTech\]\s+Difficulty:\s+([\d.]+)') {
                                $out["difficulty"] = [double]$Matches[1]
                                $foundDiff = $true
                            }
                            if (-not $foundJob -and $line -match '\[DagTech\]\s+New job:\s+(\S+)') {
                                $out["job_id"] = $Matches[1]
                                $foundJob = $true
                            }
                            if (-not $foundConn) {
                                if     ($line -match '\[DagTech\] Connected!')           { $out["pool_status"] = "connected";    $foundConn = $true }
                                elseif ($line -match '\[DagTech\] New job:')             { $out["pool_status"] = "connected";    $foundConn = $true }
                                elseif ($line -match '\[DagTech\] Pool connection lost') { $out["pool_status"] = "disconnected"; $foundConn = $true }
                                elseif ($line -match '\[DagTech\] Reconnecting')         { $out["pool_status"] = "reconnecting"; $foundConn = $true }
                                elseif ($line -match '\[DagTech\] Connecting to pool')   { $out["pool_status"] = "connecting";   $foundConn = $true }
                                elseif ($line -match '\[DagTech\] Waiting for work')     { $out["pool_status"] = "connecting";   $foundConn = $true }
                            }
                        }
                    } catch {}
                }
                # Fetch per-source share stats from the miner's metrics HTTP endpoint
                # Use HttpWebRequest directly — Invoke-WebRequest can hang indefinitely in
                # scheduled-task context despite TimeoutSec; HttpWebRequest honours Timeout always.
                $metricsPort = if ($cfg["METRICS_PORT"]) { $cfg["METRICS_PORT"] } else { "8882" }
                try {
                    $wr = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$metricsPort/metrics")
                    $wr.Timeout = 2000
                    $wr.ReadWriteTimeout = 2000
                    $wr.Method = "GET"
                    $wr.Proxy = $null
                    $resp   = $wr.GetResponse()
                    $reader = [System.IO.StreamReader]::new($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                    $mj     = $reader.ReadToEnd() | ConvertFrom-Json
                    $reader.Close(); $resp.Close()
                    foreach ($f in @("cpu_submitted","gpu_submitted","cpu_accepted","gpu_accepted","cpu_rejected","gpu_rejected","cpu_stale","gpu_stale")) {
                        if ($null -ne $mj.$f) { $out[$f] = [long]$mj.$f }
                    }
                    if ($null -ne $mj.cpu_name)  { $out["cpu_name"]  = [string]$mj.cpu_name }
                    if ($null -ne $mj.cpu_cores) { $out["cpu_cores"] = [long]$mj.cpu_cores }
                } catch {}
                $kvs = @('"running":' + $runningStr)
                foreach ($k in $out.Keys) {
                    $v = $out[$k]
                    if ($v -is [string]) { $kvs += ('"' + $k + '":"' + ($v.Replace('\','\\').Replace('"','\"')) + '"') }
                    else { $kvs += ('"' + $k + '":' + ($v.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
                }
                Send-Response $ctx ('{' + ($kvs -join ',') + '}')
                break
            }
            "/update-check" {
                try {
                    $wr = [System.Net.HttpWebRequest]::Create("https://raw.githubusercontent.com/danvandamme/blockdag-GPU-miner-installer/main/VERSION")
                    $wr.Timeout = 8000; $wr.ReadWriteTimeout = 8000; $wr.Method = "GET"; $wr.Proxy = $null
                    $resp   = $wr.GetResponse()
                    $reader = [System.IO.StreamReader]::new($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                    $latestVer = $reader.ReadToEnd().Trim()
                    $reader.Close(); $resp.Close()
                    $cfg = Read-Config
                    $currentVer = if ($cfg["INSTALLER_VERSION"]) { $cfg["INSTALLER_VERSION"] } else { "unknown" }
                    $upToDate = ($latestVer -eq $currentVer).ToString().ToLower()
                    Send-Response $ctx ('{"current":"' + ($currentVer -replace '"',"'") + '","latest":"' + ($latestVer -replace '"',"'") + '","up_to_date":' + $upToDate + '}')
                } catch {
                    $msg = $_.Exception.Message -replace '"',"'" -replace '\r?\n',' '
                    Send-Response $ctx ('{"error":"' + $msg + '"}') 500
                }
                break
            }
            "/update" {
                if ($method -ne "POST") { Send-Response $ctx '{"error":"POST required"}' 405; break }
                try {
                    $ghBase = "https://raw.githubusercontent.com/danvandamme/blockdag-GPU-miner-installer/main"
                    # ─ Fetch latest version ──────────────────────────────────────────────
                    $wr = [System.Net.HttpWebRequest]::Create("$ghBase/VERSION")
                    $wr.Timeout = 10000; $wr.ReadWriteTimeout = 10000; $wr.Method = "GET"; $wr.Proxy = $null
                    $resp   = $wr.GetResponse()
                    $reader = [System.IO.StreamReader]::new($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                    $latestVer = $reader.ReadToEnd().Trim()
                    $reader.Close(); $resp.Close()
                    $cfg = Read-Config
                    $currentVer = if ($cfg["INSTALLER_VERSION"]) { $cfg["INSTALLER_VERSION"] } else { "unknown" }
                    if ($currentVer -eq $latestVer) {
                        Send-Response $ctx ('{"ok":true,"status":"up_to_date","version":"' + $currentVer + '"}')
                        break
                    }
                    # ─ Stop miner to release binary file lock ────────────────────────────
                    $wasRunning = $null -ne (Get-MinerProcess)
                    if ($wasRunning) {
                        Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                        Remove-Item $script:MINERPIDF -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Milliseconds 1500
                    }
                    # ─ Download files ────────────────────────────────────────────────────
                    $downloads = @(
                        @{ src = "dashboard/index.html";        dst = "dashboard\index.html" },
                        @{ src = "dashboard/logo.ico";          dst = "dashboard\logo.ico" },
                        @{ src = "dashboard/logo.png";          dst = "dashboard\logo.png" },
                        @{ src = "dagtech-start.bat";           dst = "bin\dagtech-start.bat" },
                        @{ src = "dagtech-stop.bat";            dst = "bin\dagtech-stop.bat" },
                        @{ src = "dagtech-logs.bat";            dst = "bin\dagtech-logs.bat" },
                        @{ src = "dagtech-restart-control.bat"; dst = "bin\dagtech-restart-control.bat" },
                        @{ src = "dagtech-uninstall.bat";       dst = "bin\dagtech-uninstall.bat" },
                        @{ src = "dagtech-force-stop.bat";      dst = "bin\dagtech-force-stop.bat" },
                        @{ src = "dagtech-gpu-miner.exe";       dst = "bin\dagtech-gpu-miner.exe" },
                        @{ src = "dagtech-control.ps1";         dst = "bin\dagtech-control.ps1.new" }
                    )
                    $errors = [System.Collections.Generic.List[string]]::new()
                    foreach ($dl in $downloads) {
                        try {
                            $destPath = Join-Path $script:BASE $dl.dst
                            $wr2 = [System.Net.HttpWebRequest]::Create("$ghBase/$($dl.src)")
                            $wr2.Timeout = 60000; $wr2.ReadWriteTimeout = 60000; $wr2.Method = "GET"; $wr2.Proxy = $null
                            $resp2 = $wr2.GetResponse()
                            $fs = [System.IO.File]::Open($destPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                            $resp2.GetResponseStream().CopyTo($fs)
                            $fs.Close(); $resp2.Close()
                            Write-Log "Update: downloaded $($dl.src)"
                        } catch {
                            $errors.Add($dl.src + ': ' + ($_.Exception.Message -replace '"',"'"))
                            Write-Log ('Update: failed ' + $dl.src + ' - ' + $_)
                        }
                    }
                    # ─ Update INSTALLER_VERSION in config.env ────────────────────────────
                    try {
                        $cfgLines = @(Get-Content $script:CONFIG)
                        $found = $false
                        $newCfgLines = @(foreach ($line in $cfgLines) {
                            if ($line -match '^INSTALLER_VERSION=') { "INSTALLER_VERSION=$latestVer"; $found = $true } else { $line }
                        })
                        if (-not $found) { $newCfgLines += "INSTALLER_VERSION=$latestVer" }
                        [System.IO.File]::WriteAllLines($script:CONFIG, $newCfgLines, (New-Object System.Text.UTF8Encoding $false))
                    } catch { $errors.Add('config.env: ' + ($_.Exception.Message -replace '"',"'")) }
                    # ─ Copy logo.ico to bin\ so shortcuts keep their icon ─────────────────
                    $logoSrc = Join-Path $script:BASE "dashboard\logo.ico"
                    $logoDst = Join-Path $script:BASE "bin\logo.ico"
                    if (Test-Path $logoSrc) {
                        try { Copy-Item $logoSrc $logoDst -Force } catch { $errors.Add('logo.ico: ' + ($_.Exception.Message -replace '"',"'")) }
                    }
                    # ─ Add any missing watchdog / new config keys ────────────────────────
                    try {
                        $wdDefaults = [ordered]@{
                            WATCHDOG_RESTART_DELAY  = "60"
                            WATCHDOG_RETRY_INTERVAL = "300"
                            WATCHDOG_MAX_RETRIES    = "0"
                        }
                        $wdLines    = @(Get-Content $script:CONFIG)
                        $wdExisting = @($wdLines | ForEach-Object { if ($_ -match '^([A-Z_]+)=') { $Matches[1] } })
                        $wdAdd      = @($wdDefaults.Keys | Where-Object { $wdExisting -notcontains $_ } | ForEach-Object { "$_=$($wdDefaults[$_])" })
                        if ($wdAdd.Count -gt 0) {
                            [System.IO.File]::WriteAllLines($script:CONFIG, ($wdLines + $wdAdd), (New-Object System.Text.UTF8Encoding $false))
                            Write-Log "Update: added missing config keys: $($wdAdd -join ', ')"
                        }
                    } catch { $errors.Add('watchdog-config: ' + ($_.Exception.Message -replace '"',"'")) }
                    # ─ Refresh "Miner Shortcuts" desktop folder and all shortcuts ─────────
                    try {
                        # Resolve the interactive user's desktop — works even when running as SYSTEM
                        $wmiUser = (Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction SilentlyContinue).UserName
                        $desktopPath = if ($wmiUser) {
                            $uname = $wmiUser.Split('\')[-1]
                            $c = "C:\Users\$uname\Desktop"
                            if (Test-Path $c) { $c } else { [Environment]::GetFolderPath('Desktop') }
                        } else { [Environment]::GetFolderPath('Desktop') }

                        $shortcutFolder = Join-Path $desktopPath "Miner Shortcuts"
                        if (-not (Test-Path $shortcutFolder)) { New-Item -ItemType Directory -Path $shortcutFolder | Out-Null }

                        # Remove old direct-on-desktop shortcuts left by pre-folder versions
                        @('DagTech GPU Miner.lnk','DagTech GPU Miner - Stop.lnk','DagTech GPU Miner - Uninstall.lnk','DagTech GPU Miner - Logs.lnk','DagTech GPU Miner - Restart Control.lnk') | ForEach-Object {
                            $old = Join-Path $desktopPath $_; if (Test-Path $old) { Remove-Item $old -Force }
                        }

                        $binDir   = Split-Path $script:BIN
                        $iconPath = Join-Path $binDir "logo.ico"
                        $sh       = New-Object -COM WScript.Shell
                        @(
                            @{ name = "DagTech GPU Miner.lnk";                   target = Join-Path $binDir "dagtech-start.bat";           desc = "Start DagTech GPU Miner" },
                            @{ name = "DagTech GPU Miner - Stop.lnk";            target = Join-Path $binDir "dagtech-stop.bat";            desc = "Stop DagTech GPU Miner" },
                            @{ name = "DagTech GPU Miner - Uninstall.lnk";       target = Join-Path $binDir "dagtech-uninstall.bat";       desc = "Uninstall DagTech GPU Miner" },
                            @{ name = "DagTech GPU Miner - Logs.lnk";            target = Join-Path $binDir "dagtech-logs.bat";            desc = "View DagTech GPU Miner live log" },
                            @{ name = "DagTech GPU Miner - Restart Control.lnk"; target = Join-Path $binDir "dagtech-restart-control.bat"; desc = "Restart DagTech GPU Miner control server" }
                        ) | ForEach-Object {
                            $lnk = $sh.CreateShortcut((Join-Path $shortcutFolder $_.name))
                            $lnk.TargetPath       = $_.target
                            $lnk.WorkingDirectory = $binDir
                            $lnk.Description      = $_.desc
                            if (Test-Path $iconPath) { $lnk.IconLocation = "$iconPath,0" }
                            $lnk.Save()
                        }
                        Write-Log "Update: desktop shortcuts refreshed in 'Miner Shortcuts' folder."
                    } catch { $errors.Add('shortcuts: ' + ($_.Exception.Message -replace '"',"'")); Write-Log "Update: shortcut refresh failed - $_" }
                    # ─ Restart miner if it was running ───────────────────────────────────
                    if ($wasRunning -and -not (Test-Path $script:STOPFILE)) { Start-MinerProcess }
                    $hasCtrl  = (Test-Path (Join-Path $script:BASE "bin\dagtech-control.ps1.new")).ToString().ToLower()
                    $errStr   = if ($errors.Count -gt 0) { '"' + ($errors -join '; ') + '"' } else { 'null' }
                    Write-Log "Update applied: $currentVer -> $latestVer"
                    Send-Response $ctx ('{"ok":true,"status":"updated","from":"' + $currentVer + '","to":"' + $latestVer + '","restart_required":' + $hasCtrl + ',"errors":' + $errStr + '}')
                } catch {
                    $msg = $_.Exception.Message -replace '"',"'" -replace '\r?\n',' '
                    Write-Log "Update error: $_"
                    Send-Response $ctx ('{"error":"' + $msg + '"}') 500
                }
                break
            }
            "/restart-server" {
                if ($method -ne "POST") { Send-Response $ctx '{"error":"POST required"}' 405; break }
                Send-Response $ctx '{"ok":true}'
                $script:PendingRestart = $true
                $listener.Stop()
                break
            }
            default {
                Send-Response $ctx '{"error":"not found"}' 404
                break
            }
        }
    } catch [System.Net.HttpListenerException] {
        break
    } catch {
        Write-Log "Request error: $_"
        try { $ctx.Response.Abort() } catch { }  # release socket on unhandled error
    }

    # Inline watchdog: runs on the main thread every 30 s — no threading issues
    $now = [datetime]::UtcNow
    if (($now - $script:LastWatchdog).TotalSeconds -ge 30) {
        $script:LastWatchdog = $now

        # ── Daily log rotation: delete miner logs older than 7 days ──────────
        if ($now.Hour -eq 3 -and $now.Minute -lt 1) {
            try {
                $cutoff = $now.AddDays(-7)
                Get-ChildItem $script:LOGDIR -Filter "miner_*.log" -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoff } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            } catch {}
        }

        if (Test-Path $script:STOPFILE) {
            # Intentionally stopped — clear all down-tracking
            $script:MinerDownSince     = $null
            $script:LastRestartAttempt = $null
            $script:WatchdogRestarts   = 0
        } else {
            if (Get-MinerProcess) {
                # Miner is healthy — clear down-tracking and log recovery if it was down
                if ($null -ne $script:MinerDownSince) { Write-Log "Watchdog: miner is back up." }
                $script:MinerDownSince     = $null
                $script:LastRestartAttempt = $null
                $script:WatchdogRestarts   = 0

                # ── Last-job staleness check ─────────────────────────────────────────
                # Scan the tail of the log every 30s for "New job:" lines.  If the
                # miner is running but hasn't received a new job for >5 min, the
                # pool or node RPC may have stalled.
                try {
                    $jobLogFile = Get-ActiveMinerLog
                    if ($jobLogFile -and (Test-Path $jobLogFile)) {
                        $jobLines = Get-Content $jobLogFile -Tail 200 -ErrorAction SilentlyContinue
                        if ($jobLines | Where-Object { $_ -match '\[DagTech\]\s+New job:' }) {
                            $script:LastJobSeenAt = [datetime]::UtcNow
                        }
                    }
                } catch {}

                # ── GPU platform auto-detect ──────────────────────────────────────────
                # If GPU mining shows 0 H/s 90 s after start, try GPU_PLATFORM=1.
                # Only runs once per miner start and only bumps from 0 → 1 (never loops).
                if (-not $script:GpuPlatformCheckDone -and
                    $null -ne $script:MinerStartedAt -and
                    ([datetime]::UtcNow - $script:MinerStartedAt).TotalSeconds -ge 90) {

                    $script:GpuPlatformCheckDone = $true   # mark now; prevents re-entry
                    $gpuCfg = Read-Config
                    $curPlatform = if ($gpuCfg["GPU_PLATFORM"]) { try { [int]$gpuCfg["GPU_PLATFORM"] } catch { 0 } } else { 0 }

                    if ($gpuCfg["GPU_ENABLED"] -eq "1" -and $curPlatform -eq 0) {
                        # Parse the last GPU stats line from the miner log
                        $logFile  = Get-ActiveMinerLog
                        $gpuHash  = -1.0   # -1 = not found; 0 = found but zero
                        $cpuHash  = 0.0
                        if ($logFile -and (Test-Path $logFile)) {
                            $logLines = Get-Content $logFile -Tail 80 -ErrorAction SilentlyContinue
                            $statsLine = $logLines | Where-Object {
                                $_ -match '\[DagTech\].*\|\s+CPU:\s+[\d.]+\s+H/s\s+\|\s+GPU:\s+[\d.]+\s+H/s'
                            } | Select-Object -Last 1
                            if ($statsLine -match '\[DagTech\].*\|\s+CPU:\s+([\d.]+)\s+H/s\s+\|\s+GPU:\s+([\d.]+)\s+H/s') {
                                $cpuHash = [double]$Matches[1]
                                $gpuHash = [double]$Matches[2]
                            }
                        }

                        if ($gpuHash -eq 0 -and $cpuHash -gt 0) {
                            Write-Log "Watchdog: GPU hashrate is 0 H/s after 90s (CPU is running) — switching to GPU_PLATFORM=1 and restarting."
                            # Update GPU_PLATFORM in config.env
                            $cfgLines = @(Get-Content $script:CONFIG -ErrorAction SilentlyContinue)
                            $keyFound = $false
                            $newCfgLines = @($cfgLines | ForEach-Object {
                                if ($_ -match '^GPU_PLATFORM=') { $keyFound = $true; "GPU_PLATFORM=1" } else { $_ }
                            })
                            if (-not $keyFound) { $newCfgLines += "GPU_PLATFORM=1" }
                            [System.IO.File]::WriteAllLines($script:CONFIG, $newCfgLines, (New-Object System.Text.UTF8Encoding $false))
                            # Restart the miner with the new platform
                            $minerProc = Get-MinerProcess
                            if ($minerProc) { $minerProc | Stop-Process -Force -ErrorAction SilentlyContinue }
                            Start-Sleep -Milliseconds 1200
                            $script:GpuPlatformCheckDone = $false   # let the check run again for the new instance
                            Start-MinerProcess
                        } elseif ($gpuHash -gt 0) {
                            Write-Log "Watchdog: GPU platform check OK — GPU running at $gpuHash H/s on platform $curPlatform."
                        }
                        # If $gpuHash -eq -1 (no stats line yet), check is already marked done — will re-run next start
                    }
                }
            } else {
                # Miner is not running — start or continue timing
                if ($null -eq $script:MinerDownSince) {
                    $script:MinerDownSince = $now
                    Write-Log "Watchdog: miner not running — will restart after $($script:WatchdogRestartDelay)s if still down."
                }

                $downSecs   = ($now - $script:MinerDownSince).TotalSeconds
                $sinceRetry = if ($null -ne $script:LastRestartAttempt) { ($now - $script:LastRestartAttempt).TotalSeconds } else { $downSecs }
                $unlimited  = ($script:WatchdogMaxRetries -eq 0)
                $canRetry   = $unlimited -or ($script:WatchdogRestarts -lt $script:WatchdogMaxRetries)

                if ($script:WatchdogRestarts -eq 0 -and $downSecs -ge $script:WatchdogRestartDelay) {
                    # First restart attempt after the initial delay
                    Write-Log "Watchdog: miner down $([int]$downSecs)s — restarting (attempt 1)..."
                    Start-MinerProcess
                    $script:LastRestartAttempt = $now
                    $script:WatchdogRestarts   = 1
                } elseif ($script:WatchdogRestarts -gt 0 -and $canRetry -and $sinceRetry -ge $script:WatchdogRetryInterval) {
                    # Subsequent retry after the retry interval
                    $attempt = $script:WatchdogRestarts + 1
                    Write-Log "Watchdog: miner still down — retrying (attempt $attempt)..."
                    Start-MinerProcess
                    $script:LastRestartAttempt = $now
                    $script:WatchdogRestarts++
                } elseif ($script:WatchdogRestarts -gt 0 -and -not $canRetry -and $sinceRetry -lt 35) {
                    # Log once when max retries is reached (only on the cycle it tips over)
                    Write-Log "Watchdog: max retries ($($script:WatchdogMaxRetries)) reached — manual start required."
                }
            }
        }
    }
}

# Spawn a fresh control server if a restart was requested (update applied or
# /restart-server). Spawn FIRST (so we hold the child handle), then release our
# PID slot so the child's single-instance guard can claim it, then VERIFY the
# child is actually listening before we give up — no silent fire-and-forget.
if ($script:PendingRestart) {
    # Relaunch the control server so the (possibly updated) script is reloaded —
    # a running PowerShell script can't hot-swap its own body, so it must exit and
    # start a fresh copy. Use the SAME mechanism the server was started with, and
    # make sure the new instance has NO visible window: otherwise the restart
    # leaves the old (now-dead) console behind AND pops a new one. On Windows 11
    # the default console host (Windows Terminal) ignores `-WindowStyle Hidden`,
    # so the old `Start-Process powershell -WindowStyle Hidden` surfaced a stray
    # Terminal window every time.
    $taskExists = $null -ne (Get-ScheduledTask -TaskName $script:TASK_NAME -ErrorAction SilentlyContinue)
    $launched   = $false
    try {
        if ($taskExists) {
            # Service install: relaunch via Task Scheduler. Tasks run with no
            # console window at all, and this matches the normal startup path.
            Remove-Item $PIDFILE -Force -ErrorAction SilentlyContinue   # release the slot for the new instance's guard
            Start-ScheduledTask -TaskName $script:TASK_NAME -ErrorAction Stop
            $launched = $true
            Write-Log "Control server respawn requested via scheduled task '$($script:TASK_NAME)' (windowless). Verifying..."
        } else {
            # Manual / direct launch: start hidden via CreateProcess with
            # CreateNoWindow. Unlike -WindowStyle Hidden, CreateNoWindow can't be
            # overridden by Windows Terminal, so the new server stays truly invisible.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName        = (Join-Path $PSHOME 'powershell.exe')
            $psi.Arguments       = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:CTRL_SCRIPT + '" -BaseDir "' + $script:BASE + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow  = $true
            $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $child = [System.Diagnostics.Process]::Start($psi)
            Remove-Item $PIDFILE -Force -ErrorAction SilentlyContinue   # let the child's guard claim the slot
            if ($child) { $launched = $true; Write-Log "Control server respawn launched (child PID $($child.Id), windowless). Verifying..." }
        }
    } catch {
        Write-Log "RESPAWN FAILED to launch a new control server: $_"
    }
    if ($launched) {
        $up = $false
        for ($i = 0; $i -lt 20; $i++) {                             # up to ~10s
            Start-Sleep -Milliseconds 500
            try {
                if ((Invoke-WebRequest 'http://127.0.0.1:8883/status' -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { $up = $true; break }
            } catch {}
        }
        if ($up) { Write-Log "Respawn verified: new control server is listening on 8883." }
        else     { Write-Log "WARNING: respawned control server did not respond on 8883 within 10s — the scheduled task will recover it on next trigger/reboot." }
    }
}

# Stop background cache refresh job
if ($script:CacheJob) {
    Stop-Job  $script:CacheJob -ErrorAction SilentlyContinue
    Remove-Job $script:CacheJob -Force -ErrorAction SilentlyContinue
}

Write-Log "Control server stopped."
