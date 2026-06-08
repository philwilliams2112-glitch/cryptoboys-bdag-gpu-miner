@echo off
REM ============================================================================
REM DagTech GPU Miner - Windows Installer
REM Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
REM https://dagtech.network
REM
REM Builds and installs the DagTech GPU Miner on Windows.
REM
REM Bundled files (must be in the same folder as this .bat):
REM   dagtech_miner.c           Source code (CPU+GPU)
REM   dagtech_sha256.h          SHA256 header
REM   dagtech_gpu.cl            OpenCL kernel (required for GPU)
REM   dagtech-gpu-miner.exe     Pre-built binary (used if no compiler is found)
REM   dashboard\index.html      Web dashboard
REM
REM Usage: Double-click this file, or run from a command prompt.
REM ============================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "VERSION=GPU-2026.0608.11"
set "INSTALL_DIR=C:\dagtech-gpu-miner"
set "BIN_DIR=%INSTALL_DIR%\bin"
set "DASHBOARD_DIR=%INSTALL_DIR%\dashboard"
set "LOG_DIR=%INSTALL_DIR%\logs"
set "CONFIG_FILE=%INSTALL_DIR%\config.env"

echo.
echo   =====================================================
echo     DagTech GPU Miner v%VERSION% - Windows Installer
echo     dagtech.network
echo     By Dawie Nel / DagTech Ltd
echo   =====================================================
echo.

REM ============================================================================
REM 0. Administrator elevation
REM ============================================================================
net session >nul 2>&1
if errorlevel 1 (
    echo [GPU Miner] Administrator rights required - click Yes on the UAC prompt.
    echo [GPU Miner] The installer will continue in a new window.
    set "_SELF=%CD%\%~nx0"
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -Verb RunAs -ArgumentList '/d', '/k', ('\"' + $env:_SELF + '\"')"
    timeout /t 3 /nobreak >nul
    exit /b
)

REM ============================================================================
REM 0b. Windows Defender exclusions (before any file copies)
REM ============================================================================
echo [GPU Miner] Configuring Windows Defender exclusions...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -ErrorAction SilentlyContinue; Add-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue; Add-MpPreference -ExclusionProcess '%BIN_DIR%\dagtech-gpu-miner.exe' -ErrorAction SilentlyContinue" >nul 2>&1
echo [GPU Miner] Defender exclusions set.

REM ============================================================================
REM 0b-2. Power plan - switch to High Performance for maximum mining throughput.
REM       Balanced plan throttles clock speeds and can cut hash rate by 60-75%.
REM ============================================================================
echo [GPU Miner] Setting High Performance power plan...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" >nul 2>&1
echo [GPU Miner] Power plan set to High Performance.

REM ============================================================================
REM 0c. Firewall rule for miner metrics (port 8882)
REM ============================================================================
echo [GPU Miner] Configuring firewall rule for miner metrics (port 8882)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Remove-NetFirewallRule -DisplayName 'DagTech GPU Miner Metrics' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'DagTech GPU Miner Metrics' -Direction Inbound -Protocol TCP -LocalPort 8882 -Profile Private,Domain -Action Allow | Out-Null" >nul 2>&1
echo [GPU Miner] Firewall rule set.

REM ============================================================================
REM 1. System Checks
REM ============================================================================
echo [GPU Miner] Checking system...
ver | findstr /i "10\. 11\." >nul 2>&1
if errorlevel 1 echo [GPU Miner] WARNING: Recommended Windows 10 or newer.

for /f %%a in ('powershell -nologo -command "(Get-CimInstance Win32_Processor).NumberOfLogicalProcessors" 2^>nul') do set "CPU_CORES=%%a"
for /f "delims=" %%a in ('powershell -nologo -command "(Get-CimInstance Win32_Processor).Name" 2^>nul') do set "CPU_NAME=%%a"
for /f %%a in ('powershell -nologo -command "[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)" 2^>nul') do set "RAM_MB=%%a"

if "%RAM_MB%"==""    set "RAM_MB=0"
if "%CPU_CORES%"=="" set "CPU_CORES=1"

echo.
echo   Hardware:
echo   CPU:   %CPU_NAME%
echo   Cores: %CPU_CORES%
echo   RAM:   %RAM_MB% MB
echo.

if %RAM_MB% LSS 512 (
    echo [GPU Miner] ERROR: Minimum 512MB RAM required.
    pause & exit /b 1
)

REM Disk space check
for /f "tokens=*" %%s in ('powershell -NoProfile -Command "(Get-PSDrive C).Free" 2^>nul') do set "FREE_BYTES=%%s"
for /f "tokens=*" %%g in ('powershell -NoProfile -Command "[math]::Round(%FREE_BYTES% / 1GB, 2)" 2^>nul') do set "FREE_GB=%%g"
for /f "tokens=*" %%c in ('powershell -NoProfile -Command "if (%FREE_BYTES% -lt 500MB) { 'LOW' } else { 'OK' }" 2^>nul') do set "SPACE_CHECK=%%c"
if "!SPACE_CHECK!"=="LOW" (
    echo [GPU Miner] WARNING: Only !FREE_GB! GB free on C:. At least 500 MB recommended.
    echo         Press any key to continue anyway, or close this window to cancel.
    pause >nul
) else (
    echo [GPU Miner] Disk space OK ^(!FREE_GB! GB free^).
)

REM ============================================================================
REM 1b. Detect GPU(s) and vendor
REM ============================================================================
echo [GPU Miner] Detecting GPU(s)...
powershell -Command "Get-WmiObject Win32_VideoController | Select-Object Name | Format-List" 2>nul
for /f "tokens=*" %%g in ('powershell -NoProfile -Command "(Get-WmiObject Win32_VideoController).Name -join ',' " 2^>nul') do set "GPU_NAME=%%g"
if "!GPU_NAME!"=="" (
    echo [GPU Miner] WARNING: No GPU detected. GPU mining will fall back to CPU-only at runtime.
) else (
    echo [GPU Miner] GPU detected: !GPU_NAME!
)

REM Detect GPU vendor - pick the highest-priority mining target.
REM Priority: NVIDIA > AMD > Intel. Handles dual-GPU systems (NVIDIA discrete +
REM AMD/Intel iGPU) where the previous "first findstr wins" logic falsely
REM returned the iGPU's vendor because AMD/Intel matched before NVIDIA did.
REM NOTE: do NOT use regex alternation '|' in the PowerShell match expression.
REM Inside cmd.exe's for /f context, the caret in '^|' survives into the
REM PowerShell command, and .NET treats '^' as a start-of-string anchor -
REM so e.g. 'NVIDIA^' can never match mid-string and the whole alternation
REM falls through silently. Use multiple -match clauses joined with -or instead.
set "GPU_VENDOR=unknown"
for /f "tokens=*" %%v in ('powershell -NoProfile -Command ^
    "$n = ((Get-WmiObject Win32_VideoController).Name -join ' ');" ^
    "if ($n -match 'NVIDIA' -or $n -match 'GeForce' -or $n -match 'Quadro' -or $n -match 'RTX' -or $n -match 'GTX' -or $n -match 'Tesla') { 'nvidia' }" ^
    "elseif ($n -match 'AMD' -or $n -match 'Radeon') { 'amd' }" ^
    "elseif ($n -match 'Intel') { 'intel' }" ^
    "else { 'unknown' }" 2^>nul') do set "GPU_VENDOR=%%v"
if not "!GPU_VENDOR!"=="unknown" echo [GPU Miner] GPU vendor: !GPU_VENDOR!

REM ============================================================================
REM 1c. Ensure OpenCL ICD is registered in the registry
REM     Some driver installs (especially after Windows updates) leave the
REM     Khronos\OpenCL\Vendors registry key empty, so the OpenCL loader finds
REM     no platforms and the miner reports "No OpenCL platforms found" / 0 H/s.
REM     We locate the vendor DLL in DriverStore and register it if missing.
REM ============================================================================
REM Register every vendor ICD whose DLL is present on the system. Independent
REM registry entries; registering both on a multi-GPU system lets the miner
REM switch GPU_PLATFORM at runtime without re-running the installer.
echo [GPU Miner] Checking OpenCL ICD registry...

REM NVIDIA ICD - register if nvopencl64.dll is present in DriverStore
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$dll = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'nvopencl64.dll' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName;" ^
    "if ($dll) {" ^
    "    $reg = 'HKLM:\SOFTWARE\Khronos\OpenCL\Vendors';" ^
    "    if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null };" ^
    "    $existing = (Get-Item $reg).Property | Where-Object { $_ -like '*nvopencl64*' };" ^
    "    if (-not $existing) { New-ItemProperty -Path $reg -Name $dll -Value 0 -PropertyType DWORD -Force | Out-Null; Write-Host '[GPU Miner] Registered NVIDIA OpenCL ICD:' $dll } else { Write-Host '[GPU Miner] NVIDIA OpenCL ICD already registered.' }" ^
    "}"

REM AMD ICD - register if amdocl64.dll is present (System32 or DriverStore)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$dll = Get-ChildItem 'C:\Windows\System32' -Filter 'amdocl64.dll' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName;" ^
    "if (-not $dll) { $dll = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'amdocl64.dll' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName };" ^
    "if ($dll) {" ^
    "    $reg = 'HKLM:\SOFTWARE\Khronos\OpenCL\Vendors';" ^
    "    if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null };" ^
    "    $existing = (Get-Item $reg).Property | Where-Object { $_ -like '*amdocl64*' };" ^
    "    if (-not $existing) { New-ItemProperty -Path $reg -Name $dll -Value 0 -PropertyType DWORD -Force | Out-Null; Write-Host '[GPU Miner] Registered AMD OpenCL ICD:' $dll } else { Write-Host '[GPU Miner] AMD OpenCL ICD already registered.' }" ^
    "}"

REM Warn only if no vendor's ICD got registered (no GPU drivers found anywhere)
powershell -NoProfile -Command ^
    "$reg = 'HKLM:\SOFTWARE\Khronos\OpenCL\Vendors';" ^
    "$entries = if (Test-Path $reg) { (Get-Item $reg).Property } else { @() };" ^
    "if (-not $entries -or $entries.Count -eq 0) { Write-Host '[GPU Miner] WARNING: No OpenCL ICDs registered - install GPU drivers if GPU shows 0 H/s.' }"

REM ============================================================================
REM 2. Find C Compiler
REM ============================================================================
echo [GPU Miner] Checking for C compiler...

for %%d in (
    "%INSTALL_DIR%\mingw64\bin"
    "C:\MinGW\bin"
    "C:\MinGW64\bin"
    "C:\mingw64\bin"
    "C:\mingw32\bin"
    "C:\TDM-GCC-64\bin"
    "C:\tools\mingw64\bin"
    "C:\msys64\mingw64\bin"
    "C:\msys64\mingw32\bin"
) do (
    if exist "%%~d\gcc.exe" set "PATH=%%~d;!PATH!"
)

set "HAS_GCC=0"
where gcc >nul 2>&1 && set "HAS_GCC=1"

REM Reject a 32-bit compiler (e.g. an old C:\MinGW / mingw32 on PATH): it cannot
REM link the 64-bit system OpenCL.dll and can only ever produce a broken binary.
REM Treat it as "no compiler" so we fall back to the bundled 64-bit exe.
if "%HAS_GCC%"=="1" (
    set "_GCC_MACH="
    for /f "tokens=*" %%m in ('gcc -dumpmachine 2^>nul') do set "_GCC_MACH=%%m"
    echo !_GCC_MACH! | find /i "x86_64" >nul
    if errorlevel 1 (
        echo [GPU Miner] Ignoring 32-bit compiler ^(!_GCC_MACH!^); using bundled 64-bit binary.
        set "HAS_GCC=0"
    )
)

set "HAS_BUNDLED=0"
if exist "%~dp0dagtech-gpu-miner.exe" set "HAS_BUNDLED=1"

REM The bundled 64-bit exe is the guaranteed baseline (installed in step 6). A
REM valid 64-bit compiler is then used as a bonus to rebuild it with -march=native
REM CPU tuning, but a failed compile never removes the bundled binary.
if "%HAS_GCC%"=="1" (
    echo [GPU Miner] 64-bit compiler found - will install bundled binary, then tune for this CPU.
    goto :compiler_ready
)
if "%HAS_BUNDLED%"=="1" (
    echo [GPU Miner] Using bundled pre-built 64-bit binary.
    goto :compiler_ready
)

REM No compiler and no bundled binary - try to download MinGW
echo [GPU Miner] No compiler found. Downloading portable MinGW-w64...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

set "MINGW_PS=%TEMP%\dagtech-mingw-dl.ps1"
del "%MINGW_PS%" 2>nul

echo $ErrorActionPreference = 'Stop'                                                                   >> "%MINGW_PS%"
echo $dest = '%INSTALL_DIR%'                                                                           >> "%MINGW_PS%"
echo try {                                                                                             >> "%MINGW_PS%"
echo     Write-Host '[GPU Miner] Fetching MinGW-w64 release info...'                                  >> "%MINGW_PS%"
echo     $r = Invoke-RestMethod 'https://api.github.com/repos/brechtsanders/winlibs_mingw/releases/latest' -UseBasicParsing >> "%MINGW_PS%"
echo     $a = $r.assets ^| Where-Object { $_.name -like '*x86_64-posix-seh*ucrt*.zip' } ^| Select-Object -First 1 >> "%MINGW_PS%"
echo     if (-not $a) { $a = $r.assets ^| Where-Object { $_.name -like '*x86_64-posix-seh*.zip' } ^| Select-Object -First 1 } >> "%MINGW_PS%"
echo     if (-not $a) { throw 'No suitable MinGW-w64 asset found' }                                   >> "%MINGW_PS%"
echo     $mb = [math]::Round^($a.size / 1MB, 1^)                                                      >> "%MINGW_PS%"
echo     Write-Host "[GPU Miner] Downloading $($a.name) ($mb MB)..."                                   >> "%MINGW_PS%"
echo     $zip = "$env:TEMP\dagtech-mingw.zip"                                                         >> "%MINGW_PS%"
echo     Invoke-WebRequest $a.browser_download_url -OutFile $zip -UseBasicParsing                     >> "%MINGW_PS%"
echo     Write-Host '[GPU Miner] Extracting...'                                                      >> "%MINGW_PS%"
echo     $mingwDest = Join-Path $dest 'mingw64'                                                      >> "%MINGW_PS%"
echo     if (Test-Path $mingwDest) { Remove-Item $mingwDest -Recurse -Force }                         >> "%MINGW_PS%"
echo     Expand-Archive $zip -DestinationPath $dest -Force                                            >> "%MINGW_PS%"
echo     Remove-Item $zip -Force -ErrorAction SilentlyContinue                                        >> "%MINGW_PS%"
echo     Write-Host '[GPU Miner] MinGW-w64 installed.'                                               >> "%MINGW_PS%"
echo     exit 0                                                                                       >> "%MINGW_PS%"
echo } catch {                                                                                        >> "%MINGW_PS%"
echo     Write-Host "[GPU Miner] Download failed: $_"                                                  >> "%MINGW_PS%"
echo     exit 1                                                                                       >> "%MINGW_PS%"
echo }                                                                                                >> "%MINGW_PS%"

powershell -nologo -ExecutionPolicy Bypass -File "%MINGW_PS%"
if errorlevel 1 (
    echo.
    echo [GPU Miner] Could not auto-install MinGW-w64.
    echo         To build from source, download from https://winlibs.com/ and add gcc.exe to PATH.
    echo         Or place dagtech-gpu-miner.exe (pre-built) in the same folder as this installer.
    pause & exit /b 1
)

set "FOUND_GCC="
if exist "%INSTALL_DIR%\mingw64\bin\gcc.exe" set "FOUND_GCC=%INSTALL_DIR%\mingw64\bin"
if not defined FOUND_GCC (
    for /f "delims=" %%g in ('where /r "%INSTALL_DIR%" gcc.exe 2^>nul') do (
        if not defined FOUND_GCC for %%f in ("%%g") do set "FOUND_GCC=%%~dpf"
    )
)
if not defined FOUND_GCC (
    echo [GPU Miner] ERROR: gcc.exe not found after extraction. Please try again.
    pause & exit /b 1
)
set "PATH=%FOUND_GCC%;%PATH%"
set "HAS_GCC=1"
echo [GPU Miner] MinGW-w64 ready at %FOUND_GCC%
powershell -nologo -command "[Environment]::SetEnvironmentVariable('PATH','%FOUND_GCC%;'+[Environment]::GetEnvironmentVariable('PATH','User'),'User')" >nul 2>&1

:compiler_ready

REM ============================================================================
REM 2b. Download OpenCL headers if compiler is available and headers missing
REM ============================================================================
set "OPENCL_HEADERS_DIR=%~dp0opencl-headers"
if "%HAS_GCC%"=="1" if not exist "%OPENCL_HEADERS_DIR%\CL\cl.h" (
    echo [GPU Miner] OpenCL headers not found. Downloading from Khronos...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$zip='%TEMP%\opencl-headers.zip'; $ext='%TEMP%\ocl-ext'; Invoke-WebRequest 'https://github.com/KhronosGroup/OpenCL-Headers/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing; if (Test-Path $ext) { Remove-Item $ext -Recurse -Force }; Expand-Archive $zip -DestinationPath $ext -Force; $clSrc=Join-Path $ext 'OpenCL-Headers-main\CL'; $dest='%OPENCL_HEADERS_DIR%'; if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }; Copy-Item $clSrc -Destination $dest -Recurse -Force; Remove-Item $zip,$ext -Recurse -Force -ErrorAction SilentlyContinue; Write-Host '[GPU Miner] OpenCL headers installed.'"
    if errorlevel 1 (
        echo [GPU Miner] WARNING: Could not download OpenCL headers. GPU compile may fail.
    ) else (
        echo [GPU Miner] OpenCL headers ready.
    )
)

REM ============================================================================
REM 2c. Generate libOpenCL.a import library from system OpenCL.dll
REM     gendef + dlltool are bundled with MinGW-w64. The Khronos headers repo
REM     only ships .h files — libOpenCL.a must be generated from the system DLL
REM     that GPU drivers install at C:\Windows\System32\OpenCL.dll.
REM ============================================================================
if "%HAS_GCC%"=="1" if not exist "%OPENCL_HEADERS_DIR%\libOpenCL.a" (
    if exist "%SystemRoot%\System32\OpenCL.dll" (
        echo [GPU Miner] Generating libOpenCL.a from system OpenCL.dll...
        set "_GCC_BIN_FOR_OCL="
        for /f "tokens=*" %%g in ('where gcc 2^>nul') do if not defined _GCC_BIN_FOR_OCL set "_GCC_BIN_FOR_OCL=%%~dpg"
        if defined _GCC_BIN_FOR_OCL (
            if exist "!_GCC_BIN_FOR_OCL!gendef.exe" if exist "!_GCC_BIN_FOR_OCL!dlltool.exe" (
                if not exist "%OPENCL_HEADERS_DIR%" mkdir "%OPENCL_HEADERS_DIR%"
                pushd "%OPENCL_HEADERS_DIR%"
                "!_GCC_BIN_FOR_OCL!gendef.exe" "%SystemRoot%\System32\OpenCL.dll" >nul 2>&1
                "!_GCC_BIN_FOR_OCL!dlltool.exe" -d OpenCL.def -l libOpenCL.a >nul 2>&1
                del /f OpenCL.def 2>nul
                popd
                if exist "%OPENCL_HEADERS_DIR%\libOpenCL.a" (
                    echo [GPU Miner] libOpenCL.a generated successfully.
                ) else (
                    echo [GPU Miner] WARNING: libOpenCL.a generation failed. GPU compile may fail.
                )
            ) else (
                echo [GPU Miner] WARNING: gendef/dlltool not found in MinGW bin. GPU compile may fail.
            )
        ) else (
            echo [GPU Miner] WARNING: gcc not found in PATH for libOpenCL.a generation.
        )
    ) else (
        echo [GPU Miner] WARNING: OpenCL.dll not found in System32. Install GPU drivers first.
        if /i "!GPU_VENDOR!"=="amd" (
            echo         AMD GPU detected - install AMD Radeon Software from amd.com/support
            echo         then re-run this installer.
        ) else if /i "!GPU_VENDOR!"=="nvidia" (
            echo         NVIDIA GPU detected - install GeForce drivers from nvidia.com/drivers
            echo         then re-run this installer.
        ) else (
            echo         Install your GPU drivers then re-run this installer.
        )
        echo         GPU compile will likely fail without OpenCL.dll.
    )
)

REM ============================================================================
REM 3. Locate source files
REM ============================================================================
set "SRC_FILE=%~dp0source\dagtech_miner.c"
set "SHA256_FILE=%~dp0source\dagtech_sha256.h"
set "CL_FILE=%~dp0source\dagtech_gpu.cl"

if "%HAS_GCC%"=="1" if not exist "%SRC_FILE%" goto :missing_src
if "%HAS_GCC%"=="1" if not exist "%CL_FILE%" goto :missing_cl
goto :src_files_ok
:missing_src
echo [GPU Miner] ERROR: dagtech_miner.c not found in installer folder.
pause & exit /b 1
:missing_cl
echo [GPU Miner] ERROR: dagtech_gpu.cl not found in installer folder.
pause & exit /b 1
:src_files_ok

REM ============================================================================
REM 4. Configuration
REM ============================================================================
echo.
echo   ---- Configuration ----
echo.

set "DEF_POOL=dvdmining.ddns.net"
set "DEF_PORT=3334"
set "DEF_PASSWORD=1234"
for /f "tokens=*" %%h in ('powershell -nologo -command "$env:COMPUTERNAME.ToLower()" 2^>nul') do set "DEF_WORKER=%%h"
if "%DEF_WORKER%"=="" set "DEF_WORKER=dagtech"
set "DEF_THREADS="
set "DEF_GPU_INT=35"
if exist "%CONFIG_FILE%" (
    for /f "tokens=1,* delims==" %%k in (%CONFIG_FILE%) do (
        if "%%k"=="WALLET"       set "DEF_WALLET=%%l"
        if "%%k"=="POOL_HOST"    set "DEF_POOL=%%l"
        if "%%k"=="POOL"         set "DEF_POOL=%%l"
        if "%%k"=="POOL_PORT"    set "DEF_PORT=%%l"
        if "%%k"=="PORT"         set "DEF_PORT=%%l"
        if "%%k"=="WORKER_NAME"  set "DEF_WORKER=%%l"
        if "%%k"=="WORKER"       set "DEF_WORKER=%%l"
        if "%%k"=="THREADS"      set "DEF_THREADS=%%l"
        if "%%k"=="CPU_LIMIT"    set "DEF_CPU_LIMIT=%%l"
        if "%%k"=="POOL_PASSWORD" set "DEF_PASSWORD=%%l"
        if "%%k"=="GPU_INTENSITY" set "DEF_GPU_INT=%%l"
        if "%%k"=="GPU_THROTTLE" set "DEF_GPU_THROTTLE=%%l"
        if "%%k"=="START_MODE"    set "DEF_START_MODE=%%l"
        if "%%k"=="AUTOTUNE"      set "DEF_AUTOTUNE=%%l"
        if "%%k"=="AUTOTUNE_TRIAL_SECONDS" set "DEF_AUTOTUNE_SEC=%%l"
    )
    echo [GPU Miner] Loaded defaults from existing config.
)

:wallet_prompt
set "WALLET="
if defined DEF_WALLET (
    echo   Wallet (current: %DEF_WALLET%^):
    set /p "WALLET=  New wallet (leave blank to keep current): "
    if "!WALLET!"=="" set "WALLET=%DEF_WALLET%"
) else (
    set /p "WALLET=  Wallet address (0x...): "
)
if "!WALLET!"=="" ( echo   [WARN] Wallet is required. & goto :wallet_prompt )
for /f "tokens=*" %%v in ('powershell -NoProfile -Command "if ('!WALLET!' -match '^0x[0-9a-fA-F]{40}') { 'OK' } else { 'BAD' }" 2^>nul') do set "ADDR_CHECK=%%v"
if not "!ADDR_CHECK!"=="OK" (
    echo   [WARN] That does not look like a valid wallet address.
    echo          Expected format: 0x followed by 40 hex characters.
    goto :wallet_prompt
)

echo.
set /p "POOL_INPUT=  Pool address (default: %DEF_POOL%): "
if "%POOL_INPUT%"=="" (set "POOL=%DEF_POOL%") else (set "POOL=%POOL_INPUT%")

set /p "PORT_INPUT=  Pool port   (default: %DEF_PORT%): "
if "%PORT_INPUT%"=="" (set "PORT=%DEF_PORT%") else (set "PORT=%PORT_INPUT%")

echo.
set /p "WORKER_INPUT=  Worker name (default: %DEF_WORKER%): "
if "%WORKER_INPUT%"=="" (set "WORKER=%DEF_WORKER%") else (set "WORKER=%WORKER_INPUT%")

set /a "DEFAULT_THREADS=%CPU_CORES% / 2"
if %DEFAULT_THREADS% LSS 1 set "DEFAULT_THREADS=1"
if defined DEF_THREADS set "DEFAULT_THREADS=%DEF_THREADS%"
echo.
set /p "THREADS_INPUT=  CPU threads (1-%CPU_CORES%, default %DEFAULT_THREADS%): "
if "%THREADS_INPUT%"=="" (set "THREADS=%DEFAULT_THREADS%") else (set "THREADS=%THREADS_INPUT%")

echo.
if not defined DEF_CPU_LIMIT set "DEF_CPU_LIMIT=50"
echo   CPU throttle limits CPU mining effort to keep the machine cool and usable.
echo   ^(50 = use about half the CPU; 100 = no limit / full speed.^)
set /p "CPU_LIMIT_INPUT=  CPU throttle 5-100 (default !DEF_CPU_LIMIT!): "
if "!CPU_LIMIT_INPUT!"=="" (set "CPU_LIMIT=!DEF_CPU_LIMIT!") else (set "CPU_LIMIT=!CPU_LIMIT_INPUT!")

REM ---- GPU VRAM detection + intensity recommendation -------------------------
echo.
echo [GPU Miner] Detecting GPU VRAM for intensity recommendation...
set "GPU_VRAM_MB=0"
set "GPU_VRAM_NAME="

REM NVIDIA: nvidia-smi gives exact dedicated VRAM
for /f "tokens=1,* delims=," %%a in ('nvidia-smi --query-gpu^=name^,memory.total --format^=csv^,noheader^,nounits 2^>nul') do (
    if "!GPU_VRAM_MB!"=="0" (
        set "GPU_VRAM_NAME=%%a"
        set "_V=%%b"
        set "_V=!_V: =!"
        set "GPU_VRAM_MB=!_V!"
    )
)

REM Fallback 1: Registry QWORD - reads 64-bit value, bypasses WMI 4 GB cap
REM   Works for AMD RX 5000/6000/7000 and NVIDIA cards equally.
REM   HardwareInformation.MemorySize is REG_BINARY or REG_QWORD under the display adapter key.
set "_REG_VRAM=HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
if "!GPU_VRAM_MB!"=="0" (
    for /f "tokens=*" %%v in ('powershell -NoProfile -Command "try { $b=$env:_REG_VRAM; $best=0L; Get-ChildItem $b -EA SilentlyContinue ^| Where-Object {$_.PSChildName -match ""^\d{4}$""} ^| ForEach-Object { $p=Get-ItemProperty $_.PSPath -EA SilentlyContinue; $m=$p.""HardwareInformation.MemorySize""; if($m -ne $null){ $n=if($m -is [byte[]]){[BitConverter]::ToInt64(($m+[byte[]](0,0,0,0,0,0,0,0))[0..7],0)}else{[long]$m}; if($n -gt $best){$best=$n} } }; if($best -gt 0){[int]($best/1MB)}else{0} } catch {0}" 2^>nul') do set "GPU_VRAM_MB=%%v"
)

REM Fallback 2: WMI AdapterRAM - 32-bit field, caps at 4096 MB, last resort
if "!GPU_VRAM_MB!"=="0" (
    for /f "tokens=*" %%v in ('powershell -NoProfile -Command "try { $g=Get-WmiObject Win32_VideoController ^| Where-Object { $_.AdapterRAM -gt 1GB } ^| Sort-Object AdapterRAM -Desc ^| Select-Object -First 1; if($g){ [int]($g.AdapterRAM/1MB) }else{ 0 } } catch { 0 }" 2^>nul') do set "GPU_VRAM_MB=%%v"
)

REM Calculate recommended intensity from V-buffer formula:
REM   V-buffer = 2^E * 128 KB, where E = floor(14 + intensity/100*6 + 0.5)
REM   Target: use up to 75%% of VRAM so the buffer fits with headroom.
set "REC_GPU_INT=8"
if "!GPU_VRAM_MB!"=="0" goto :vram_fallback
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "$v=[long]'!GPU_VRAM_MB!'; $t=$v*1048576*0.75; $e=[Math]::Floor([Math]::Log($t/131072)/[Math]::Log(2)); if($e -lt 14){$e=14}; $i=[int][Math]::Floor(($e-13.5)*100.0/6.0-0.001); if($i -lt 5){$i=5}; if($i -gt 95){$i=95}; $i" 2^>nul') do set "REC_GPU_INT=%%i"
if not "!GPU_VRAM_NAME!"=="" echo   GPU  : !GPU_VRAM_NAME!
echo   VRAM : !GPU_VRAM_MB! MB  -^>  recommended intensity: !REC_GPU_INT!
echo   ^(At this intensity the V-buffer uses ~75%% of VRAM. Reduce if GPU shows 0 H/s.^)
set "DEF_GPU_INT=!REC_GPU_INT!"
goto :vram_done
:vram_fallback
echo [GPU Miner] Could not detect VRAM - using safe default intensity !REC_GPU_INT!.
set "DEF_GPU_INT=!REC_GPU_INT!"
:vram_done

if /i "!GPU_VENDOR!"=="amd" (
    echo.
    echo   [AMD GPU] OpenCL platform note:
    echo   If GPU mining shows 0 H/s after install, edit %CONFIG_FILE%
    echo   and change GPU_PLATFORM=0 to GPU_PLATFORM=1 then restart the miner.
)

echo.
set /p "GPU_INT_INPUT=  GPU intensity 0-100 (default !DEF_GPU_INT!): "
if "!GPU_INT_INPUT!"=="" (set "GPU_INT=!DEF_GPU_INT!") else (set "GPU_INT=!GPU_INT_INPUT!")

echo.
if not defined DEF_GPU_THROTTLE set "DEF_GPU_THROTTLE=80"
echo   GPU throttle limits GPU duty cycle to reduce heat (100 = no limit).
set /p "GPU_THROTTLE_INPUT=  GPU throttle 5-100 (default !DEF_GPU_THROTTLE!): "
if "!GPU_THROTTLE_INPUT!"=="" (set "GPU_THROTTLE=!DEF_GPU_THROTTLE!") else (set "GPU_THROTTLE=!GPU_THROTTLE_INPUT!")

echo.
REM Fresh installs (no existing config) default autotune ON so a new machine
REM tunes itself on first boot. Existing installs keep whatever they had.
if not defined DEF_AUTOTUNE     set "DEF_AUTOTUNE=1"
if not defined DEF_AUTOTUNE_SEC set "DEF_AUTOTUNE_SEC=60"
echo   GPU autotune sweeps batch sizes/kernel modes once at startup and caches the
echo   fastest combo. First run adds a few minutes; instant on later starts.
if "!DEF_AUTOTUNE!"=="1" (set "AT_HINT=Y/n, default yes") else (set "AT_HINT=y/N, default no")
set /p "AUTOTUNE_INPUT=  Enable GPU autotune? [!AT_HINT!]: "
set "AUTOTUNE=!DEF_AUTOTUNE!"
if /i "!AUTOTUNE_INPUT!"=="y"   set "AUTOTUNE=1"
if /i "!AUTOTUNE_INPUT!"=="yes" set "AUTOTUNE=1"
if /i "!AUTOTUNE_INPUT!"=="n"   set "AUTOTUNE=0"
if /i "!AUTOTUNE_INPUT!"=="no"  set "AUTOTUNE=0"
set "AUTOTUNE_SEC=!DEF_AUTOTUNE_SEC!"

echo.
set "DEF_PASSWORD_SHOW="
if defined DEF_PASSWORD set "DEF_PASSWORD_SHOW=!DEF_PASSWORD!"
set /p "PASSWORD_INPUT=  Pool password (default: blank): "
if "!PASSWORD_INPUT!"=="" (
    if defined DEF_PASSWORD (set "PASSWORD=!DEF_PASSWORD!") else (set "PASSWORD=")
) else (
    set "PASSWORD=!PASSWORD_INPUT!"
)

echo.
echo   Summary:
echo   Wallet      : %WALLET%
echo   Pool        : %POOL%:%PORT%
echo   Worker      : %WORKER%
echo   Password    : %PASSWORD%
echo   CPU Threads : %THREADS%
echo   CPU Throttle : %CPU_LIMIT%%%
echo   GPU Intensity: %GPU_INT%
echo   GPU Throttle : %GPU_THROTTLE%%%
echo.

REM ---- Start mode -----------------------------------------------------------
set "START_MODE_CHOICE=login"
if defined DEF_START_MODE set "START_MODE_CHOICE=!DEF_START_MODE!"
echo   How should the miner start?
echo     [1] System service  - starts at boot, runs as SYSTEM (no login needed)
echo     [2] At login        - starts when you log in, runs as you (terminal log window)
echo     [3] Manual only     - does NOT auto-start; use the desktop shortcut when you want to mine
echo.
if /i "!START_MODE_CHOICE!"=="login" (
    set /p "SM_INPUT=  Choice (default: 2): "
) else if /i "!START_MODE_CHOICE!"=="manual" (
    set /p "SM_INPUT=  Choice (default: 3): "
) else (
    set /p "SM_INPUT=  Choice (default: 1): "
)
if "!SM_INPUT!"=="1" ( set "START_MODE_CHOICE=service" ) else if "!SM_INPUT!"=="2" ( set "START_MODE_CHOICE=login" ) else if "!SM_INPUT!"=="3" ( set "START_MODE_CHOICE=manual" )
echo   Start mode: !START_MODE_CHOICE!
echo.

REM ============================================================================
REM 4b. Stop any running miner BEFORE touching the binary
REM     (dagtech-gpu-miner.exe is locked while running; copy silently fails)
REM ============================================================================
echo [GPU Miner] Force-stopping any running miner instance...
REM Inline, non-interactive force stop. We do NOT call dagtech-force-stop.bat
REM here because that is a standalone tool that self-elevates and ends with a
REM pause prompt — calling it would hang the installer. This replicates its
REM kill sequence: task stop, miner kill, orphaned control-server kill, and
REM HTTP.sys reservation release so the new files copy and bind cleanly.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Disable-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue | Out-Null;" ^
    "Stop-ScheduledTask   -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue;" ^
    "Disable-ScheduledTask -TaskName 'DagTech Miner' -ErrorAction SilentlyContinue | Out-Null;" ^
    "Stop-ScheduledTask   -TaskName 'DagTech Miner' -ErrorAction SilentlyContinue;" ^
    "$pidFile='%INSTALL_DIR%\logs\control.pid';" ^
    "if (Test-Path $pidFile) { $raw=(Get-Content $pidFile -Raw).Trim(); if ($raw -match '^\d+$') { try { Get-Process -Id ([int]$raw) -EA Stop | Stop-Process -Force } catch {} } };" ^
    "Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue;" ^
    "Get-CimInstance Win32_Process -Filter ""Name='powershell.exe'"" | Where-Object { $_.CommandLine -like '*dagtech-control*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue };" ^
    "Get-CimInstance Win32_Process -Filter ""Name='pwsh.exe'"" | Where-Object { $_.CommandLine -like '*dagtech-control*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue };" ^
    "netsh http delete urlacl url=http://127.0.0.1:8883/ | Out-Null;" ^
    "Start-Sleep -Seconds 1" 2>nul
echo [GPU Miner] Miner stopped.

REM Re-enable the scheduled task (force-stop disables it; we need it enabled so
REM the new install's auto-start works). Task registration later re-creates it
REM anyway, but enabling here keeps state clean if registration is skipped.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Enable-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue | Out-Null" >nul 2>&1

REM ============================================================================
REM 5. Create directories
REM ============================================================================
echo [GPU Miner] Creating directories...
if not exist "%INSTALL_DIR%"    mkdir "%INSTALL_DIR%"
if not exist "%BIN_DIR%"        mkdir "%BIN_DIR%"
if not exist "%DASHBOARD_DIR%"  mkdir "%DASHBOARD_DIR%"
if not exist "%LOG_DIR%"        mkdir "%LOG_DIR%"

REM ============================================================================
REM 6. Install binary
REM ============================================================================

REM -- Fast path: bundled pre-built binary --
if "%HAS_BUNDLED%"=="1" (
    copy /y "%~dp0dagtech-gpu-miner.exe" "%BIN_DIR%\dagtech-gpu-miner.exe" >nul
    echo [GPU Miner] Pre-built binary installed.
)

REM -- Bundled runtime DLL --
if exist "%~dp0libwinpthread-1.dll" (
    copy /y "%~dp0libwinpthread-1.dll" "%BIN_DIR%\libwinpthread-1.dll" >nul
    echo [GPU Miner] Runtime DLL installed.
)

REM -- Compile from source if compiler available --
if not "%HAS_GCC%"=="1" goto :compile_else
if not exist "%SRC_FILE%" goto :compile_else

echo [GPU Miner] Tuning the miner for this CPU (native 64-bit compile)...
copy /y "%CL_FILE%" "%BIN_DIR%\dagtech_gpu.cl" >nul 2>&1
echo [GPU Miner] OpenCL kernel installed.

REM Compile to a TEMP file and only replace the deployed binary on success, so a
REM failed compile can never destroy the bundled exe installed in step 6 above.
gcc -DDAGTECH_GPU -I"%OPENCL_HEADERS_DIR%" -L"%OPENCL_HEADERS_DIR%" -O2 -march=native -Wall -D_WIN32_WINNT=0x0600 -o "%BIN_DIR%\dagtech-gpu-miner.exe.new" "%SRC_FILE%" -lws2_32 -lm -lkernel32 -lOpenCL -static-libgcc -Wl,-Bstatic,-lpthread,-Bdynamic

if errorlevel 1 (
    echo [GPU Miner] Native compile failed - keeping the bundled 64-bit binary.
    del /f /q "%BIN_DIR%\dagtech-gpu-miner.exe.new" 2>nul
    goto :compile_done
)
move /y "%BIN_DIR%\dagtech-gpu-miner.exe.new" "%BIN_DIR%\dagtech-gpu-miner.exe" >nul
echo [GPU Miner] Native-optimized build installed.
set "_GCC_DIR="
for /f "tokens=*" %%g in ('where gcc 2^>nul') do if not defined _GCC_DIR set "_GCC_DIR=%%~dpg"
if defined _GCC_DIR (
    for %%d in (libwinpthread-1.dll libgcc_s_seh-1.dll libgcc_s_dw2-1.dll) do (
        if exist "!_GCC_DIR!%%d" (
            copy /y "!_GCC_DIR!%%d" "%BIN_DIR%\" >nul
            echo [GPU Miner] Runtime DLL installed: %%d
        )
    )
)
goto :compile_done

:compile_else
REM Still copy the kernel file even if not compiling
if exist "%CL_FILE%" (
    copy /y "%CL_FILE%" "%BIN_DIR%\dagtech_gpu.cl" >nul 2>&1
    echo [GPU Miner] OpenCL kernel installed.
)

:compile_done

if not exist "%BIN_DIR%\dagtech-gpu-miner.exe" (
    echo [GPU Miner] ERROR: No binary available. Cannot continue.
    echo         Place dagtech-gpu-miner.exe in the same folder as this installer and retry.
    pause & exit /b 1
)

REM ============================================================================
REM 7. Save configuration
REM ============================================================================
echo [GPU Miner] Saving config...
(
echo # DagTech GPU Miner Configuration
echo # Generated by DagTech GPU Installer v%VERSION%
echo INSTALLER_VERSION=%VERSION%
echo WALLET=!WALLET!
echo POOL_HOST=!POOL!
echo POOL_PORT=!PORT!
echo MINING_MODE=both
echo THREADS=!THREADS!
echo WORKER_NAME=!WORKER!
echo POOL_PASSWORD=!PASSWORD!
echo CPU_LIMIT=!CPU_LIMIT!
echo METRICS_PORT=8882
echo GPU_ENABLED=1
echo GPU_INTENSITY=!GPU_INT!
echo GPU_THROTTLE=!GPU_THROTTLE!
echo GPU_VRAM_MB=!GPU_VRAM_MB!
echo GPU_REC_INTENSITY=!REC_GPU_INT!
echo GPU_PLATFORM=0
echo GPU_DEVICE=0
echo GPU_VENDOR=!GPU_VENDOR!
echo AUTOTUNE=!AUTOTUNE!
echo AUTOTUNE_TRIAL_SECONDS=!AUTOTUNE_SEC!
echo WATCHDOG_RESTART_DELAY=60
echo WATCHDOG_RETRY_INTERVAL=300
echo WATCHDOG_MAX_RETRIES=0
echo START_MODE=!START_MODE_CHOICE!
) > "%CONFIG_FILE%"
echo [GPU Miner] Config saved.

REM Register HTTP URL ACLs:
REM   http://+:8882/           - miner metrics (wildcard so it's reachable on LAN)
REM   http://127.0.0.1:8883/   - control server (localhost only, no wildcard needed)
netsh http add urlacl url=http://+:8882/ user=Everyone >nul 2>&1
netsh http add urlacl url=http://127.0.0.1:8883/ user=Everyone >nul 2>&1
echo [GPU Miner] Port ACLs registered (metrics=8882, control=8883).

REM ============================================================================
REM 8. Install dashboard
REM ============================================================================
if exist "%~dp0dashboard\index.html" (
    copy /y "%~dp0dashboard\index.html" "%DASHBOARD_DIR%\" >nul
    echo [GPU Miner] Dashboard installed.
) else if exist "%~dp0..\dashboard\index.html" (
    copy /y "%~dp0..\dashboard\index.html" "%DASHBOARD_DIR%\" >nul
    echo [GPU Miner] Dashboard installed.
)
for %%f in (logo.ico logo.png) do (
    if exist "%~dp0dashboard\%%f" (
        copy /y "%~dp0dashboard\%%f" "%DASHBOARD_DIR%\" >nul
        echo [GPU Miner] Dashboard asset installed: %%f
    )
)
REM Also copy logo.ico to bin\ so shortcuts can reference it
if exist "%~dp0dashboard\logo.ico" (
    copy /y "%~dp0dashboard\logo.ico" "%BIN_DIR%\logo.ico" >nul
    echo [GPU Miner] Shortcut icon installed.
)

REM ============================================================================
REM 8b. Install control server
REM ============================================================================
if exist "%~dp0dagtech-control.ps1" (
    copy /y "%~dp0dagtech-control.ps1" "%BIN_DIR%\" >nul
    echo [GPU Miner] Control server installed.
) else (
    echo [GPU Miner] WARNING: dagtech-control.ps1 not found in installer folder.
)

REM ============================================================================
REM 9. Install launcher scripts
REM ============================================================================
echo [GPU Miner] Installing launcher scripts...
for %%f in (dagtech-start.bat dagtech-stop.bat dagtech-status.bat dagtech-logs.bat dagtech-force-stop.bat dagtech-restart-control.bat dagtech-uninstall.bat) do (
    if exist "%~dp0%%f" (
        copy /y "%~dp0%%f" "%BIN_DIR%\%%f" >nul
    )
)
echo [GPU Miner] Launcher scripts installed.

REM ============================================================================
REM 10. Add bin folder to user PATH
REM ============================================================================
echo [GPU Miner] Adding to PATH...
powershell -nologo -command ^
    "$p=[Environment]::GetEnvironmentVariable('PATH','User'); if($p -notlike '*dagtech-gpu-miner\bin*'){[Environment]::SetEnvironmentVariable('PATH','%BIN_DIR%;'+$p,'User')}" >nul 2>&1

REM ============================================================================
REM 11. Desktop shortcuts  (all go inside "Miner Shortcuts" folder)
REM ============================================================================
echo [GPU Miner] Creating desktop shortcuts...

REM Create "Miner Shortcuts" folder and clean up any old direct shortcuts from previous installs
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$desk=[Environment]::GetFolderPath('Desktop');" ^
    "$folder=Join-Path $desk 'Miner Shortcuts';" ^
    "if (-not (Test-Path $folder)){ New-Item -ItemType Directory -Path $folder | Out-Null };" ^
    "@('DagTech GPU Miner.lnk','DagTech GPU Miner - Stop.lnk','DagTech GPU Miner - Uninstall.lnk','DagTech GPU Miner - Logs.lnk','DagTech GPU Miner - Restart Control.lnk','DagTech GPU Miner - Force Stop.lnk') | ForEach-Object { $old=Join-Path $desk $_; if (Test-Path $old){ Remove-Item $old -Force } }"
echo [GPU Miner] Shortcut folder ready: "Miner Shortcuts"

REM -- Start shortcut --
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$d=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Miner Shortcuts'; $lnk=Join-Path $d 'DagTech GPU Miner.lnk'; $s=(New-Object -COM WScript.Shell).CreateShortcut($lnk); $s.TargetPath='%BIN_DIR%\dagtech-start.bat'; $s.WorkingDirectory='%BIN_DIR%'; $s.Description='Start DagTech GPU Miner'; $s.IconLocation='%BIN_DIR%\logo.ico,0'; $s.Save()"
if not errorlevel 1 echo [GPU Miner] Shortcut created: "DagTech GPU Miner"

REM -- Stop shortcut --
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$d=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Miner Shortcuts'; $lnk=Join-Path $d 'DagTech GPU Miner - Stop.lnk'; $s=(New-Object -COM WScript.Shell).CreateShortcut($lnk); $s.TargetPath='%BIN_DIR%\dagtech-stop.bat'; $s.WorkingDirectory='%BIN_DIR%'; $s.Description='Stop DagTech GPU Miner'; $s.IconLocation='%BIN_DIR%\logo.ico,0'; $s.Save()"
if not errorlevel 1 echo [GPU Miner] Shortcut created: "DagTech GPU Miner - Stop"

REM -- Uninstall shortcut --
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$d=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Miner Shortcuts'; $lnk=Join-Path $d 'DagTech GPU Miner - Uninstall.lnk'; $s=(New-Object -COM WScript.Shell).CreateShortcut($lnk); $s.TargetPath='%BIN_DIR%\dagtech-uninstall.bat'; $s.WorkingDirectory='%BIN_DIR%'; $s.Description='Uninstall DagTech GPU Miner'; $s.IconLocation='%BIN_DIR%\logo.ico,0'; $s.Save()"
if not errorlevel 1 echo [GPU Miner] Shortcut created: "DagTech GPU Miner - Uninstall"

REM -- Logs shortcut --
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$d=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Miner Shortcuts'; $lnk=Join-Path $d 'DagTech GPU Miner - Logs.lnk'; $s=(New-Object -COM WScript.Shell).CreateShortcut($lnk); $s.TargetPath='%BIN_DIR%\dagtech-logs.bat'; $s.WorkingDirectory='%BIN_DIR%'; $s.Description='View DagTech GPU Miner live log'; $s.IconLocation='%BIN_DIR%\logo.ico,0'; $s.Save()"
if not errorlevel 1 echo [GPU Miner] Shortcut created: "DagTech GPU Miner - Logs"

REM -- Restart Control shortcut --
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$d=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Miner Shortcuts'; $lnk=Join-Path $d 'DagTech GPU Miner - Restart Control.lnk'; $s=(New-Object -COM WScript.Shell).CreateShortcut($lnk); $s.TargetPath='%BIN_DIR%\dagtech-restart-control.bat'; $s.WorkingDirectory='%BIN_DIR%'; $s.Description='Restart DagTech GPU Miner control server'; $s.IconLocation='%BIN_DIR%\logo.ico,0'; $s.Save()"
if not errorlevel 1 echo [GPU Miner] Shortcut created: "DagTech GPU Miner - Restart Control"

REM -- Force Stop shortcut --
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$d=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Miner Shortcuts'; $lnk=Join-Path $d 'DagTech GPU Miner - Force Stop.lnk'; $s=(New-Object -COM WScript.Shell).CreateShortcut($lnk); $s.TargetPath='%BIN_DIR%\dagtech-force-stop.bat'; $s.WorkingDirectory='%BIN_DIR%'; $s.Description='Force stop DagTech GPU Miner (kills all processes)'; $s.IconLocation='%BIN_DIR%\logo.ico,0'; $s.Save()"
if not errorlevel 1 echo [GPU Miner] Shortcut created: "DagTech GPU Miner - Force Stop"

REM ============================================================================
REM 12. Auto-start via Task Scheduler
REM ============================================================================
echo.

REM Remove old Startup-folder shortcut if present
powershell -NoProfile -ExecutionPolicy Bypass -Command "$lnk=[IO.Path]::Combine($env:APPDATA,'Microsoft\Windows\Start Menu\Programs\Startup\DagTech GPU Miner.lnk'); if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host '[GPU Miner] Removed old startup shortcut.' }" 2>nul

REM Remove any legacy-named scheduled task from older installs so it can't
REM orphan and double-launch the miner alongside the current "DagTech GPU Miner" task.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Disable-ScheduledTask    -TaskName 'DagTech Miner' -ErrorAction SilentlyContinue | Out-Null;" ^
    "Stop-ScheduledTask       -TaskName 'DagTech Miner' -ErrorAction SilentlyContinue;" ^
    "Unregister-ScheduledTask -TaskName 'DagTech Miner' -Confirm:$false -ErrorAction SilentlyContinue" >nul 2>&1

REM Stop existing task and control server before re-registering
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Stop-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue;" ^
    "$pidFile='%INSTALL_DIR%\logs\control.pid';" ^
    "if (Test-Path $pidFile) { try { $p=Get-Process -Id ([int](Get-Content $pidFile -Raw).Trim()) -ErrorAction Stop; $p | Stop-Process -Force; Start-Sleep -Milliseconds 800 } catch {} }" ^
    "Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*dagtech-control*' } | Stop-Process -Force -ErrorAction SilentlyContinue" 2>nul

if /i "!START_MODE_CHOICE!"=="service" goto :task_service
if /i "!START_MODE_CHOICE!"=="login"   goto :task_login

:task_manual
echo   [GPU Miner] Manual-only mode - no scheduled task will be created.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Unregister-ScheduledTask -TaskName 'DagTech GPU Miner' -Confirm:$false -ErrorAction SilentlyContinue" >nul 2>&1
if not exist "%INSTALL_DIR%\logs" mkdir "%INSTALL_DIR%\logs" 2>nul
echo. > "%INSTALL_DIR%\logs\.stop"
echo   [GPU Miner] Miner installed. Use the "DagTech GPU Miner" desktop shortcut to start mining.
goto :task_done

:task_service
echo   [GPU Miner] Registering auto-start scheduled task (system service, starts at boot)...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$bd='%BIN_DIR%';" ^
    "$arg='-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"' + $bd + '\dagtech-control.ps1\"';" ^
    "$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg;" ^
    "$t=New-ScheduledTaskTrigger -AtStartup;" ^
    "$s=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1);" ^
    "$p=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest;" ^
    "Unregister-ScheduledTask -TaskName 'DagTech GPU Miner' -Confirm:$false -ErrorAction SilentlyContinue;" ^
    "$null=Register-ScheduledTask -TaskName 'DagTech GPU Miner' -Action $a -Trigger $t -Settings $s -Principal $p -Force;" ^
    "Remove-Item '%INSTALL_DIR%\logs\.stop' -Force -ErrorAction SilentlyContinue;" ^
    "$st=Get-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue;" ^
    "if ($st) { Write-Host ('[GPU Miner] Task registered (system service, starts at boot). State: ' + $st.State) } else { Write-Host '[GPU Miner] ERROR: Task registration failed - try running installer as Administrator.' }"
if errorlevel 1 echo [GPU Miner] WARNING: Could not register scheduled task - run installer as Administrator.
goto :task_done

:task_login
echo   [GPU Miner] Registering auto-start scheduled task (login mode, starts at logon)...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$bd='%BIN_DIR%';" ^
    "$arg='-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"' + $bd + '\dagtech-control.ps1\"';" ^
    "$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg;" ^
    "$t=New-ScheduledTaskTrigger -AtLogOn -User ($env:USERDOMAIN + '\' + $env:USERNAME);" ^
    "$s=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1);" ^
    "$p=New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN + '\' + $env:USERNAME) -LogonType Interactive -RunLevel Highest;" ^
    "Unregister-ScheduledTask -TaskName 'DagTech GPU Miner' -Confirm:$false -ErrorAction SilentlyContinue;" ^
    "$null=Register-ScheduledTask -TaskName 'DagTech GPU Miner' -Action $a -Trigger $t -Settings $s -Principal $p -Force;" ^
    "Remove-Item '%INSTALL_DIR%\logs\.stop' -Force -ErrorAction SilentlyContinue;" ^
    "$st=Get-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue;" ^
    "if ($st) { Write-Host ('[GPU Miner] Task registered (login mode, starts at logon). State: ' + $st.State) } else { Write-Host '[GPU Miner] ERROR: Task registration failed - try running installer as Administrator.' }"
goto :task_done

:task_done

REM ---- Offer to start mining now --------------------------------------------
REM Registration above no longer auto-starts; this prompt is the single place
REM the miner is launched right after install, and it works for every start mode
REM (manual launches the control server directly; service/login kick the task).
echo.
set "START_NOW=Y"
set /p "START_NOW_INPUT=  Start mining now? [Y/n]: "
if not "!START_NOW_INPUT!"=="" set "START_NOW=!START_NOW_INPUT!"
if /i "!START_NOW:~0,1!"=="n" (
    echo   [GPU Miner] Not starting now. Launch "DagTech GPU Miner" on your desktop when ready.
) else (
    echo   [GPU Miner] Starting miner...
    if /i "!START_MODE_CHOICE!"=="manual" (
        if exist "%BIN_DIR%\dagtech-start.bat" (
            start "" "%BIN_DIR%\dagtech-start.bat"
        ) else (
            start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%BIN_DIR%\dagtech-control.ps1"
        )
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
            "Remove-Item '%INSTALL_DIR%\logs\.stop' -Force -ErrorAction SilentlyContinue;" ^
            "Start-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue" >nul 2>&1
    )
    echo   [GPU Miner] Miner started.  Dashboard: http://127.0.0.1:8883
)

REM Disable sleep/hibernate so the miner never stops due to power management
powercfg /change standby-timeout-ac 0 >nul 2>&1
powercfg /change hibernate-timeout-ac 0 >nul 2>&1
powercfg /hibernate off >nul 2>&1
echo   [GPU Miner] Sleep and hibernate disabled.

REM ============================================================================
REM Done
REM ============================================================================
echo.
echo   =====================================================
echo     DagTech GPU Miner Installation Complete!
echo   =====================================================
echo.
echo   Shortcuts in "Miner Shortcuts" folder on your Desktop:
echo     "DagTech GPU Miner"                  - starts mining
echo     "DagTech GPU Miner - Stop"           - stops mining
echo     "DagTech GPU Miner - Force Stop"     - kills all processes (use if Stop hangs)
echo     "DagTech GPU Miner - Logs"           - view live log in terminal
echo     "DagTech GPU Miner - Restart Control"- restart control server (applies updates)
echo     "DagTech GPU Miner - Uninstall"      - removes miner completely
echo.
echo   Dashboard (while mining):
echo     http://127.0.0.1:8883
echo.
echo   Config:  %CONFIG_FILE%
echo   Logs:    %LOG_DIR%
echo.
if /i "!GPU_VENDOR!"=="amd" (
    echo   AMD GPU: if GPU mining shows 0 H/s, edit config.env and try GPU_PLATFORM=1
    echo.
)
if /i "!START_MODE_CHOICE!"=="manual" (
    echo   Start mode: Manual — the miner will NOT start automatically.
    echo   Double-click "DagTech GPU Miner" on your desktop whenever you want to mine.
    echo.
)
echo   To update settings: edit %CONFIG_FILE% directly.
echo.
echo   DagTech GPU Mining Suite v%VERSION%
echo   By Dawie Nel / DagTech Ltd  -  dagtech.network
echo.
echo   Full documentation (troubleshooting, config reference, updating):
echo     %INSTALL_DIR%\README.html
echo.
echo   You can close this window now.
if exist "%~dp0README.html" copy /y "%~dp0README.html" "%INSTALL_DIR%\README.html" >nul 2>&1
if exist "%INSTALL_DIR%\README.html" (
    start "" "%INSTALL_DIR%\README.html"
) else (
    start "" "https://github.com/danvandamme/blockdag-GPU-miner-installer#readme"
)
pause >nul
