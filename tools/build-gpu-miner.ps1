# build-gpu-miner.ps1 - Downloads OpenCL headers and MinGW if needed, compiles dagtech-gpu-miner.exe
param([string]$RootDir = (Split-Path (Split-Path $MyInvocation.MyCommand.Path) -Parent))
$here      = $RootDir
$src       = Join-Path $here "source\dagtech_miner.c"
$out       = Join-Path $here "dagtech-gpu-miner.exe"
$clHeaders = Join-Path $here "opencl-headers\CL"

Write-Host ""
Write-Host "  Building dagtech-gpu-miner.exe (GPU + CPU miner)..."
Write-Host ""

# -- Step 1: Download OpenCL headers if not already present -------------------
if (-not (Test-Path $clHeaders)) {
    Write-Host "  OpenCL headers not found. Downloading from Khronos GitHub..."
    $zip = Join-Path $env:TEMP "opencl-headers.zip"
    $extractDir = Join-Path $env:TEMP "opencl-headers-extract"
    try {
        Invoke-WebRequest "https://github.com/KhronosGroup/OpenCL-Headers/archive/refs/heads/main.zip" `
            -OutFile $zip -UseBasicParsing
        Write-Host "  Extracting OpenCL headers..."
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive $zip -DestinationPath $extractDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue

        $clSrc = Join-Path $extractDir "OpenCL-Headers-main\CL"
        $clDest = Join-Path $here "opencl-headers\CL"
        if (-not (Test-Path (Join-Path $here "opencl-headers"))) {
            New-Item -ItemType Directory -Path (Join-Path $here "opencl-headers") | Out-Null
        }
        Copy-Item $clSrc -Destination (Join-Path $here "opencl-headers") -Recurse -Force
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  OpenCL headers installed at: $clDest"
        Write-Host ""
    } catch {
        Write-Host "  ERROR downloading OpenCL headers: $_"
        Write-Host "  Manually place CL/ headers at: $clHeaders"
        exit 1
    }
} else {
    Write-Host "  OpenCL headers found: $clHeaders"
}

# -- Step 2: Find gcc ---------------------------------------------------------
$gcc = $null
try { $gcc = (Get-Command gcc -ErrorAction Stop).Source } catch {}
if (-not $gcc) {
    $found = Get-ChildItem $here -Filter gcc.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $gcc = $found.FullName }
}

# -- Step 3: Download MinGW if needed -----------------------------------------
if (-not $gcc) {
    Write-Host "  No compiler found. Downloading portable MinGW-w64..."
    Write-Host "  (one-time download, ~60 MB)"
    Write-Host ""
    try {
        $r = Invoke-RestMethod "https://api.github.com/repos/brechtsanders/winlibs_mingw/releases/latest" -UseBasicParsing
        $a = $r.assets | Where-Object { $_.name -like "*x86_64-posix-seh*ucrt*.zip" } | Select-Object -First 1
        if (-not $a) { $a = $r.assets | Where-Object { $_.name -like "*x86_64-posix-seh*.zip" } | Select-Object -First 1 }
        if (-not $a) { throw "No suitable MinGW asset found" }
        $zip = Join-Path $env:TEMP "dagtech-mingw.zip"
        Write-Host "  Downloading $($a.name)..."
        Invoke-WebRequest $a.browser_download_url -OutFile $zip -UseBasicParsing
        Write-Host "  Extracting..."
        Expand-Archive $zip -DestinationPath $here -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Write-Host "  MinGW ready."
        Write-Host ""
    } catch {
        Write-Host "  ERROR: $_"
        exit 1
    }
    $found = Get-ChildItem $here -Filter gcc.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $gcc = $found.FullName } else { Write-Host "  ERROR: gcc.exe not found after extraction."; exit 1 }
}

# -- Step 3b: Generate libOpenCL.a import library from system OpenCL.dll ------
# gendef + dlltool ship with MinGW-w64. libOpenCL.a is NOT in the Khronos
# headers repo — it must be generated from the OpenCL.dll that GPU drivers install.
$oclHeadersDir = Join-Path $here "opencl-headers"
$libOpenCLPath  = Join-Path $oclHeadersDir "libOpenCL.a"
if (-not (Test-Path $libOpenCLPath)) {
    $systemOCL = Join-Path $env:SystemRoot "System32\OpenCL.dll"
    $gccDir    = Split-Path $gcc
    $gendef    = Join-Path $gccDir "gendef.exe"
    $dlltool   = Join-Path $gccDir "dlltool.exe"
    if (Test-Path $systemOCL) {
        if ((Test-Path $gendef) -and (Test-Path $dlltool)) {
            Write-Host "  Generating libOpenCL.a from system OpenCL.dll..."
            $origLoc = Get-Location
            Set-Location $oclHeadersDir
            & $gendef $systemOCL 2>$null | Out-Null
            & $dlltool -d OpenCL.def -l libOpenCL.a 2>$null | Out-Null
            Remove-Item (Join-Path $oclHeadersDir "OpenCL.def") -Force -ErrorAction SilentlyContinue
            Set-Location $origLoc
            if (Test-Path $libOpenCLPath) {
                Write-Host "  libOpenCL.a generated successfully."
            } else {
                Write-Host "  WARNING: libOpenCL.a generation failed — compile may fail."
                Write-Host "  Install GPU drivers and retry, or place libOpenCL.a manually in opencl-headers\"
            }
        } else {
            Write-Host "  WARNING: gendef.exe or dlltool.exe not found in MinGW bin: $gccDir"
            Write-Host "  Cannot generate libOpenCL.a — compile will likely fail with -lOpenCL."
        }
    } else {
        Write-Host "  WARNING: $systemOCL not found."
        Write-Host "  Install NVIDIA, AMD, or Intel GPU drivers first, then retry."
    }
    Write-Host ""
} else {
    Write-Host "  libOpenCL.a already present: $libOpenCLPath"
}

# -- Step 4: Compile -----------------------------------------------------------
$includeDir = Join-Path $here "opencl-headers"

Write-Host "  Compiler  : $gcc"
Write-Host "  Source    : $src"
Write-Host "  Output    : $out"
Write-Host "  CL Headers: $includeDir"
Write-Host ""

$compileArgs = @(
    "-DDAGTECH_GPU",
    "-I$includeDir",
    "-L$includeDir",
    "-O2", "-march=x86-64-v3", "-Wall", "-D_WIN32_WINNT=0x0600",
    "-o", $out, $src,
    "-lws2_32", "-lm", "-lkernel32", "-lOpenCL",
    "-static-libgcc", "-Wl,-Bstatic,-lpthread,-Bdynamic"
)
& $gcc @compileArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  ERROR: Compilation failed."
    Write-Host "  Make sure OpenCL.lib / OpenCL.dll is available (install GPU drivers)."
    exit 1
}

Write-Host ""
Write-Host "  Done!  dagtech-gpu-miner.exe built successfully."
Write-Host "  Output: $out"
Write-Host ""
