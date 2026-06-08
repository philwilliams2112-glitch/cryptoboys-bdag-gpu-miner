# BlockDAG GPU Miner — Windows Installer

A Windows installer for the DagTech GPU Miner (Scrypt-DT algorithm).  
Supports NVIDIA, AMD, and Intel GPUs via OpenCL. CPU mining runs in parallel.

---

## Quick Start

1. Right-click `install-gpu-miner.bat` → **Run as administrator**
2. Enter your wallet address, pool, and worker name when prompted
3. Choose a start mode (see below)
4. Open the dashboard at **http://127.0.0.1:8883** while mining

---

## Desktop Shortcuts

| Shortcut | Action |
|---|---|
| `DagTech GPU Miner` | Start mining |
| `DagTech GPU Miner - Stop` | Stop mining gracefully |
| `DagTech GPU Miner - Force Stop` | Kill all miner processes immediately (use if Stop hangs) |
| `DagTech GPU Miner - Logs` | Open live log terminal |
| `DagTech GPU Miner - Restart Control` | Restart the dashboard server (applies updates) |
| `DagTech GPU Miner - Uninstall` | Remove the miner completely |

---

## Start Modes

**Service** — starts at boot, runs as SYSTEM. No login required. Best for dedicated mining machines.

**Login** — starts when you log in, runs as your user. Shows a live log window on your desktop.

**Manual** — does not auto-start. Use the `DagTech GPU Miner` desktop shortcut when you want to mine.

You can change the start mode at any time by re-running the installer.

---

## Dashboard

While the miner is running, open **http://127.0.0.1:8883** in a browser.

The dashboard shows live hash rates (CPU and GPU separately), share counts, pool connection status, difficulty, and a live activity log. You can also open the log viewer and adjust settings from the Config button.

If the dashboard is blank or stale after an update, use the **Restart Control** shortcut and refresh the page.

---

## Files and Folders

| Path | Contents |
|---|---|
| `C:\dagtech-gpu-miner\config.env` | All miner settings |
| `C:\dagtech-gpu-miner\logs\` | Daily log files (`miner_YYYY-MM-DD.log`) |
| `C:\dagtech-gpu-miner\bin\` | Miner binary and launcher scripts |
| `C:\dagtech-gpu-miner\dashboard\` | Dashboard HTML and assets |

---

## Config Reference

Open `C:\dagtech-gpu-miner\config.env` in Notepad to edit settings. Restart the miner after saving.

| Key | Description |
|---|---|
| `WALLET` | Your BlockDAG wallet address (0x...) |
| `POOL_HOST` | Mining pool hostname |
| `POOL_PORT` | Mining pool port |
| `POOL_PASSWORD` | Pool password (often `x` or a number) |
| `WORKER_NAME` | Worker label shown on the pool |
| `THREADS` | Number of CPU threads to use for mining |
| `GPU_ENABLED` | `1` to enable GPU mining, `0` to disable |
| `GPU_INTENSITY` | GPU workload size 0–100 (higher = more VRAM used) |
| `GPU_THROTTLE` | GPU duty cycle limit 5–100 (`80` = 80% max, reduces heat) |
| `GPU_PLATFORM` | OpenCL platform index. Auto-detected on first run — if GPU shows 0 H/s the miner will switch to `1` automatically after 90 seconds. Set manually if auto-detect does not resolve it. |
| `GPU_DEVICE` | OpenCL device index within the platform (usually `0`) |
| `GPU_VENDOR` | Detected vendor (`amd`, `nvidia`, `intel`) — informational |
| `WATCHDOG_RESTART_DELAY` | Seconds miner must be continuously down before the first auto-restart attempt (default `60`) |
| `WATCHDOG_RETRY_INTERVAL` | Seconds to wait between subsequent restart attempts if the miner keeps failing (default `300`) |
| `WATCHDOG_MAX_RETRIES` | Max number of auto-restart attempts before giving up; `0` = unlimited (default `0`) |
| `START_MODE` | `service`, `login`, or `manual` |
| `MINING_MODE` | `both` (CPU+GPU), `gpu`, or `cpu` |
| `METRICS_PORT` | Port for the miner metrics API (default `8882`) |

---

## Troubleshooting

### GPU shows 0 H/s

**Auto-detection:** The miner checks GPU hashrate 90 seconds after starting. If GPU is 0 H/s but CPU is running, it automatically switches to `GPU_PLATFORM=1`, saves the change to `config.env`, and restarts. Check the dashboard log — you will see a `Watchdog: GPU hashrate is 0 H/s ... switching to GPU_PLATFORM=1` message if this fires.

**If auto-detection does not resolve it** (GPU still 0 H/s after a second start):
1. Open `C:\dagtech-gpu-miner\config.env` in Notepad
2. Change `GPU_PLATFORM=1` to `GPU_PLATFORM=2`
3. Save and restart the miner (`DagTech GPU Miner - Stop`, then `DagTech GPU Miner`)

**Most common cause on AMD:** OpenCL platform order varies by system — Intel integrated graphics may be platform 0 and the Radeon card platform 1 or 2.

---

### "No OpenCL platforms found" — NVIDIA or AMD

**What this means:** OpenCL is the GPU compute API the miner uses to talk to your graphics card. Windows maintains a registry list at `HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenCL\Vendors` that tells the OpenCL loader which driver DLLs to use. If a GPU driver was installed or updated without correctly writing to this list, the loader finds nothing — and the miner reports "No OpenCL platforms found" and GPU hashrate stays at 0.

**The installer tries to fix this automatically.** If you are still seeing the problem, follow the steps below.

---

#### NVIDIA — manual fix

The NVIDIA OpenCL library is `nvopencl64.dll`, stored inside the driver's DriverStore folder. Its exact path changes with every driver version, which is why a static registry file cannot be shipped — it must be detected at runtime.

**Fix — PowerShell (run as Administrator):**

```powershell
$dll = Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" `
    -Recurse -Filter "nvopencl64.dll" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if ($dll) {
    New-Item -Path "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors" `
        -Name $dll -Value 0 -PropertyType DWORD -Force
    Write-Host "Done: $dll"
} else {
    Write-Host "nvopencl64.dll not found - reinstall your NVIDIA drivers."
}
```

**Fix — regedit (manual):**

1. Open **File Explorer** and browse to `C:\Windows\System32\DriverStore\FileRepository\`
2. Search for `nvopencl64.dll` — it will be inside a folder named something like `nvlt.inf_amd64_*`
3. Copy the full path (e.g. `C:\Windows\System32\DriverStore\FileRepository\nvlt.inf_amd64_abc12345\nvopencl64.dll`)
4. Open **regedit** as Administrator
5. Navigate to `HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenCL\Vendors`  
   (right-click and create the `Khronos`, `OpenCL`, and `Vendors` keys if they don't exist)
6. Right-click `Vendors` → **New → DWORD (32-bit) Value**
7. Paste the full DLL path as the **name**
8. Leave the **value data** as `0`
9. Restart the miner

---

#### AMD — manual fix

AMD's OpenCL library is `amdocl64.dll`. It may be in `System32` directly, or in DriverStore.

**Fix — PowerShell (run as Administrator):**

```powershell
$dll = Get-ChildItem "C:\Windows\System32" -Filter "amdocl64.dll" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $dll) {
    $dll = Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" `
        -Recurse -Filter "amdocl64.dll" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if ($dll) {
    New-Item -Path "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors" `
        -Name $dll -Value 0 -PropertyType DWORD -Force
    Write-Host "Done: $dll"
} else {
    Write-Host "amdocl64.dll not found - reinstall AMD Radeon Software."
}
```

If `amdocl64.dll` is not found at all, install or reinstall AMD drivers from **https://www.amd.com/support** (choose **Full Install**), reboot, then re-run `install-gpu-miner.bat`.

---

### GPU intensity — out of memory / crashes

If the miner crashes or the GPU shows errors, the intensity may be too high for your VRAM.

**Fix:** Lower `GPU_INTENSITY` in `config.env` in steps of 10 until stable.  
The installer recommends an intensity that uses ~75% of detected VRAM. If VRAM detection was inaccurate, start at `30` and work up.

---

### Miner not starting after reboot (service mode)

1. Open **Task Scheduler** (search in Start Menu)
2. Look for **DagTech GPU Miner** in the task list
3. Check that the task status is **Ready** and the last run result is `0x0`
4. If the task is missing, re-run the installer and choose **Service** mode again

---

### Dashboard not loading

1. Check that the miner is running — use `DagTech GPU Miner - Status` or check Task Manager for `dagtech-gpu-miner.exe` and `powershell.exe`
2. Use the **Restart Control** shortcut and try **http://127.0.0.1:8883** again
3. If still not loading, check `C:\dagtech-gpu-miner\logs\` for errors

---

### Antivirus blocking or quarantining the miner

Mining software is frequently flagged as a false positive by antivirus programs because it uses the GPU intensively and communicates with external pool servers. The miner binary is clean — add an exclusion rather than allowing individual detections, as the exclusion persists across updates.

**Windows Defender** — handled automatically by the installer. If Defender removes the binary anyway:

1. Open **Windows Security** → **Virus & threat protection** → **Protection history**
2. Find the quarantined item and select **Allow**
3. Re-run the installer to restore the binary

To add Defender exclusions manually in PowerShell (elevated):

```powershell
Add-MpPreference -ExclusionPath "C:\dagtech-gpu-miner"
Add-MpPreference -ExclusionProcess "C:\dagtech-gpu-miner\bin\dagtech-gpu-miner.exe"
```

**ESET** (and other third-party AV) — the installer cannot configure these automatically. Add an exclusion manually:

1. Open ESET → **Setup** → **Advanced Setup** (F5)
2. Go to **Detection Engine** → **Exclusions**
3. Add the folder `C:\dagtech-gpu-miner` as an exclusion
4. If the binary was already quarantined, restore it from the ESET quarantine before re-running the installer

**Note:** If the antivirus quarantines the miner binary, the watchdog auto-restart will fail silently because the `.exe` is missing. Always check the AV quarantine first if the miner stops and the watchdog does not bring it back.

---

## Updating

Open the dashboard at **http://127.0.0.1:8883**, click **Update**, and confirm. The control server downloads the latest version from GitHub, applies it, and restarts automatically. The miner keeps running during the update and is only briefly restarted if required.

If the dashboard is not reachable (e.g. after a failed update left a broken script), replace the control script manually:

```powershell
# Run in an elevated PowerShell window
$url = "https://raw.githubusercontent.com/danvandamme/blockdag-GPU-miner-installer/main/dagtech-control.ps1"
Invoke-WebRequest $url -OutFile "C:\dagtech-gpu-miner\bin\dagtech-control.ps1" -UseBasicParsing
Restart-ScheduledTask "DagTech GPU Miner"
```

---

## Uninstall

Double-click the **DagTech GPU Miner - Uninstall** shortcut on your desktop, or run:

```
C:\dagtech-gpu-miner\bin\dagtech-uninstall.bat
```

This stops the miner, removes the scheduled task, deletes all installed files, and removes the desktop shortcuts.

---

## Credits

Original DagTech GPU Mining Suite v1.0.0  
By Dawie Nel / DagTech Ltd — https://dagtech.network  
Modified by Dan Van Damme
