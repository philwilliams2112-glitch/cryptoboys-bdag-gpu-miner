# Task #40 — Coalesce V-buffer (port plan)

**Status:** ✅ SHIPPED as **GPU-2026.0608.11** (`.11` = fresh installs now default the autotune prompt to ON, so a new machine tunes itself on first boot; existing installs keep their setting) (`.10` = autotune progress now tracked via a `<cache>.running` marker file the miner writes per-trial; fixes the banner not showing on machines with long 60s trials, where the old 80-line log-tail detection missed the markers) (`.8` dropped the redundant dashboard `v1.x.0` label; `.9` logs the live year-based `GPU-2026.x` version on connect so it's visible in the dashboard log too — single source of truth, no hardcoded dashboard version) (`.6` = manual "Run Autotune Now" + tuned settings apply with the toggle OFF + dashboard status line; `.7` = amber "Autotune in progress — trial X/8" banner, driven by `/autotune-status` parsing the miner log tail). Increments 1–3 of #40 plus #42 (autotune); `.2` adds two operational fixes (config-path resolution, legacy-task cleanup); `.3` exposes the autotune toggle in the installer (prompt defaulting OFF, writes `AUTOTUNE` + `AUTOTUNE_TRIAL_SECONDS` to config.env); `.4` adds an autotune toggle to the dashboard Config modal (checkbox → writes `AUTOTUNE` via the generic `/config` POST, which restarts the miner to apply). No control-server or exe-code change was needed — the generic `/config` handler plus the `.2` config-path fix carry it end-to-end.
**Baseline:** GPU-2026.0607.2 on RTX 4060 Laptop (8 GB), 129 KH/s GPU + 9 KH/s CPU, shares 90/91 accepted.

### Release GPU-2026.0608.1 — what shipped
- **#40 Inc1** — `uint4` vectorized V-buffer access in `scrypt_romix` (committed `903813b`).
- **#40 Inc2** — split monolithic `dagtech_search` into `dagtech_pre` / `dagtech_romix` / `dagtech_post` kernels; this is the **default** path (committed `21df1f7`).
- **#40 Inc3** — cooperative 4-threads-per-hash ROMix (`dagtech_romix_coop`). **Opt-in only** via `GPU_KERNEL_MODE=coop` — slower than split on this GPU because OpenCL `__local`+barrier overhead exceeds the savings vs CUDA `__shfl_sync`. Kept for devices where it may win.
- **#42 Autotune** — opt-in via `AUTOTUNE=1`. Sweeps batch size × kernel mode, scores by accepted-share-weighted hashrate, caches the winner to `autotune.json` keyed on GPU+driver. On the 4060 Laptop it selects **split @ batchsize 8192**.
- **Bugfix** — GPU_VENDOR detection on multi-GPU systems; registers all available OpenCL ICDs (committed `bb41841`).

**Measured result (RTX 4060 Laptop):** ~129 KH/s baseline → **~256 KH/s at `GPU_THROTTLE=50`** → **~621 KH/s steady at `GPU_THROTTLE=100`** (split @ 8192). Roughly **2× faster** than the previous shipped version under the same throttle, ~4.5× vs raw baseline at full throttle. Share-accept ratio unchanged (no rejects/stales introduced).

**Portability stance:** OpenCL 1.2, no vendor intrinsics; everything NVIDIA-specific (e.g. any future `nvidia-smi` telemetry) stays optional and degrades silently. The `.cl` kernel is loaded at runtime next to the exe, so it must ship alongside the binary (the installer copies it on both build-from-source and prebuilt paths).

### Operational fixes (GPU-2026.0608.2)
- **Config path resolution — FIXED.** `dagtech_default_config_path()` previously looked only under `$USERPROFILE/dagtech-gpu-miner/config.env`, but the installer writes `config.env` to the install root `C:\dagtech-gpu-miner\`, so the miner never auto-loaded it (only env-var / CLI workarounds worked). Now it takes `argv[0]` and searches, first-existing-wins: (1) `<exedir>/config.env`, (2) `<exedir>/../config.env` (install root — where the installer writes it), (3) `./config.env`, (4) `$USERPROFILE/dagtech-gpu-miner/config.env` (legacy fallback, kept for back-compat). Validated: a `config.env` placed in the install root is now loaded automatically.
- **Legacy scheduled-task cleanup — ADDED.** The installer source is internally consistent at task name `DagTech GPU Miner`, so fresh installs were never actually broken. But machines carrying an older `DagTech Miner` task (e.g. the original dev box) could orphan it on upgrade and double-launch. The installer and uninstaller now also `Unregister` any legacy `DagTech Miner` task. Harmless no-op on machines without one.

### Known follow-ups (not blocking this release)
- Branding rename (DagTech → generic "bdag miner", credit DagTech original + DVD Mining modifications) — parked for a future session with a fresh repo.
**Validation rule (from CLAUDE.md):** every increment must produce **real H/s + accepted shares** before merging. The host-side `<2 ms` "implausibly fast" guard in `dagtech_gpu_thread` (around `dagtech_miner.c:927`) is the trip wire — if a kernel batch completes in under 2 ms, hashes aren't counted (driver-reset / fast-fail symptom).

---

## 1. What the reference miner actually does

Three techniques the CLAUDE.md briefing names, mapped to where they live in `reference-cuda-miner/src/`:

### 1a. Split kernels (not one mega-kernel per nonce)

Our miner runs **one kernel** that does the full pipeline per nonce: `dagtech_search` in `source/dagtech_gpu.cl:365–427`. Steps 1–7 (midstate → HMAC init → PBKDF2 80→128 → ROMix → tweak → PBKDF2 128→32 → target check) all in one launch.

The reference splits the same pipeline into **6 kernels** launched in sequence per nonce batch (`src/hasher.cu`):

| Reference kernel | Lines | Our kernel's equivalent step |
|---|---|---|
| `scrypt_hash_start_kernel` | 395–442 | Steps 1–3 (midstate, HMAC init, PBKDF2 80→128) — output: per-hash `tstate`, `ostate`, `X` |
| `hasher_gen_kernel` | 279–308 | Step 4a — ROMix **Fill** phase (writes V) |
| `hasher_hash_kernel` | 314–339 | Step 4b — ROMix **Mix** phase (random V reads) |
| `hasher_combo_kernel` | 351–378 | Steps 4a+4b fused (smaller register pressure than 4a/4b standalone — used when the device's occupancy permits) |
| `bdag_post_romix_tweak_kernel` | 452–460 | Step 5 — the proprietary X[0] tweak |
| `scrypt_hash_finish_kernel` | 524–550 | Steps 6–7 (PBKDF2 128→32 + target check) |

**Why this matters for #40:** each individual kernel finishes in **well under the 2 s Windows TDR watchdog**, regardless of how many hashes are in flight. The previous coalesce attempt died on the 780M iGPU because a single huge dispatch exceeded the watchdog. Splitting fixes the failure mode at the structural level — we never enqueue work that *can* time out.

### 1b. Cooperative `THREADS_PER_SCRYPT_BLOCK = 4` (four threads per hash)

Where it lives: every reference kernel uses these two lines (e.g. `hasher.cu:60–61`):
```cuda
int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x) / THREADS_PER_SCRYPT_BLOCK;
start = scrypt_block * SCRYPT_SCRATCH_PER_BLOCK + (32*i) + 8*(threadIdx.x % 4);
```

Reading this: a "scrypt block" (one 128-byte state) is owned by **four threads**, not one. Each thread handles `8 of the 32` uints in `X[]`. The four threads share the work via:
- **Memory:** each thread writes its 8-uint slice (32 bytes = one `uint4` pair) to the *same* row of V. Adjacent thread = adjacent 32 bytes = **perfectly coalesced** memory access.
- **Computation:** they exchange data via warp shuffles (`__shfl_sync` at `hasher.cu:73, 107–109, 292–294`) to recombine the Salsa20/8 state between rounds.

**Why this matters for #40:** in our current kernel, work-item `i`'s V row sits 128 KB away from work-item `i+1`'s V row — **the exact uncoalesced pattern the briefing flags**. Switching to 4-threads-per-hash makes adjacent work-items (within a sub-group / warp) hit adjacent memory.

### 1c. `uint4` vector loads and stores

Where: `scrypt_cores.cu:82–98` defines `write_8_as_uint4` / `read_8_as_uint4`, and the kernels in `hasher.cu` use raw `uint4 t = *(uint4*)&scratch[loc]` and `*(uint4*)&scratch[loc] = t` (e.g. lines 42, 53, 55, 81, 83, 415).

Effect: each memory transaction moves **16 bytes** (4 uints) instead of 4 bytes. Combined with coalescing from (1b), 8 threads × 16 bytes = one 128-byte cache line per row — exactly what the memory controller wants.

In portable OpenCL this is `uint4` + `vstore4`/`vload4`, **or** the simpler `__global uint4 *vp = (__global uint4 *)&V[...]; *vp = ...;` which most OpenCL 1.2 compilers handle correctly.

---

## 2. Constraints we cannot violate

1. **The post-ROMix X[0] tweak must stay bit-identical.** Both copies:
   - Host (CPU path): `source/dagtech_miner.c:417` area
   - Kernel: `source/dagtech_gpu.cl:408–412`
   Pool acceptance depends on this. Any rewrite of step 5 ships exactly this five-line snippet.
2. **The `<2 ms` "implausibly fast" guard stays put.** It's the only thing distinguishing a kernel that did 8192 hashes from a kernel the driver reset. Removing it = silently shipping fake hashrate. Located in `dagtech_gpu_thread` near `dagtech_miner.c:927`.
3. **Portability stays portable.** OpenCL 1.2 baseline — no `cl_khr_subgroups` extension assumptions, no NVIDIA-specific intrinsics. Inter-thread communication uses `__local` memory + `barrier(CLK_LOCAL_MEM_FENCE)`, not `sub_group_shuffle`. (The reference uses CUDA `__shfl_sync`; we substitute local memory.)
4. **The CUDA fork decision is user-gated.** Per CLAUDE.md, going NVIDIA-only requires explicit owner approval. Until then, every change ships as portable OpenCL.

---

## 3. CUDA → OpenCL idiom map

| CUDA | Portable OpenCL 1.2 |
|---|---|
| `__global__ void foo(...)` | `__kernel void foo(...)` |
| `__device__ inline T helper(...)` | `static T helper(...)` (already used in our `.cl`) |
| `threadIdx.x` | `get_local_id(0)` |
| `blockIdx.x * blockDim.x + threadIdx.x` | `get_global_id(0)` |
| `__shared__ T arr[N]` | `__local T arr[N]` (kernel arg or declaration) |
| `__syncthreads()` | `barrier(CLK_LOCAL_MEM_FENCE)` |
| `__shfl_sync(0xffffffff, val, lane)` | **No portable equivalent.** Use `__local` scratch + barrier: write `val` to `local[get_local_id(0)]`, barrier, read `local[lane]`, barrier. |
| `uint4 t = *(uint4*)&p[i]` | `uint4 t = *((__global uint4*)&p[i])` — OR `vload4(0, &p[i])` |
| `*(uint4*)&p[i] = t` | `*((__global uint4*)&p[i]) = t` — OR `vstore4(t, 0, &p[i])` |

The `__shfl_sync` → `__local + barrier` substitution is the highest-risk part of the port: it adds barrier overhead the CUDA path doesn't pay. Some of the reference's speedup will leak. Expect a smaller speedup multiplier on OpenCL than the reference miner sees on CUDA.

---

## 4. Phased increments (each one is independently shippable)

Each increment ends with the same gate: **build → run → check `gpu_hashrate` AND share-accept ratio for ≥5 minutes, no kernel resets in log, no "implausibly fast" lines**. If anything fails, revert that increment before moving on.

### Increment 1 — `uint4` writes/reads on the existing kernel layout (low risk)

**What changes:** only the inner loop bodies of `scrypt_romix` in `dagtech_gpu.cl:335–350`. Replace the byte-by-byte 32-uint copy with 8 × `uint4` stores/loads.

**Files changed:** `source/dagtech_gpu.cl` only.

**Expected win:** modest. The pattern stays uncoalesced *between* work-items (still 128 KB stride), so this is just better per-work-item memory bandwidth. Reference miner's `write_8_as_uint4` is the exact template — but applied to our current 1-thread-per-hash layout.

**Risk:** very low. No layout change. No tweak change. The kernel is still the same single `dagtech_search`. If shares stop accepting, the BSWAP order in `uint4` packing is wrong — easy to bisect.

**Rollback:** revert the one file. No host-side change.

### Increment 2 — Split the kernel (medium risk)

**What changes:**
- `source/dagtech_gpu.cl`: keep `dagtech_search` for backward compat, **add** `dagtech_start`, `dagtech_romix`, `dagtech_tweak`, `dagtech_finish` kernels. Each does one stage and reads/writes intermediate state to/from `__global` buffers.
- `source/dagtech_miner.c`: in `dagtech_gpu_thread`, replace the single `clEnqueueNDRangeKernel` (line 888) with a sequence of four enqueues. Allocate the intermediate buffers (`tstate_buf`, `ostate_buf`, `X_buf`) once at context init.

**Expected win (predicted):** zero or slightly negative on its own — splitting adds per-launch overhead. The *purpose* of this increment is to unlock Increment 3 (cooperative threads in `dagtech_romix` only, without breaking the other stages) and to make each kernel small enough to never exceed Windows TDR even at high `global_size`.

**Actual measured win (RTX 4060 Laptop, diff 10.448):** **+90% over Inc1, +112% over baseline.** Steady-state went from 143 KH/s → ~272 KH/s. Best explanation: the single `dagtech_search` kernel had high register pressure that capped warp occupancy per SM. Three smaller kernels each fit in a smaller register footprint, so the GPU keeps many more warps live simultaneously. This matches the reference miner's `hasher_combo_kernel` comment: "the two individual kernels can use fewer registers alone." The prediction missed this entirely — splitting wasn't just a structural prerequisite for #3, it was an occupancy win in its own right.

**Risk:** medium. State has to flow between kernels via global buffers. Any byte-order or layout mismatch surfaces as zero accepted shares.

**Rollback:** revert both files; the old `dagtech_search` path stays intact in the .cl file as a fallback, so we can fall back at runtime via an env var if needed.

### Increment 3 — Cooperative 4 threads/hash + coalesced V layout (high risk, big win)

**Outcome (RTX 4060 Laptop, default-split disabled, GPU_KERNEL_MODE=coop):** algorithmically correct but **slower** than Inc2 — ~80 KH/s vs Inc2's ~272 KH/s. Across two validation polls (lws=64 and lws=32) totalling 109 submitted shares, **zero rejected**. The cooperative Salsa20/8 with diagonal-column ownership and `__local`+`barrier` transposes produces bit-identical hashes — the post-ROMix tweak is preserved, pool acceptance unchanged.

Root cause of the regression: the reference miner's wins come from CUDA `__shfl_sync` (1-cycle hardware warp shuffle); the portable-OpenCL substitute (`__local` writes + `barrier(CLK_LOCAL_MEM_FENCE)` + reads) has overhead that exceeds the per-thread compute savings on this hardware. Switching `lws` between 64 (1 AMD wavefront / 2 NVIDIA warps) and 32 (1 NVIDIA warp, intra-warp lockstep) didn't materially change the result — the cost isn't the barrier wait, it's the local-memory round-trip itself relative to the small amount of saved compute.

Decision: **kept as an opt-in path, not the default.** The coop kernel and its host wiring (`kernel_romix_coop`, `kernel_mode==2`) are shipped in the source so it can be tested on different hardware (AMD with native wavefront cooperation, OpenCL 2.0 sub-group shuffles, future tuning). Default `kernel_mode` is capped at split (1); set `GPU_KERNEL_MODE=coop` to opt in.

**Lesson:** Inc2's surprise +112% gain came from kernel-split-driven register-pressure relief, not from memory coalescing. After Inc2 the kernel isn't memory-bound anymore — it's well-utilizing the SMs — so adding more work-items via cooperation doesn't help, and the barrier overhead hurts. Future #40-related work (if any) should focus on autotune (#42) and possibly OpenCL 2.0 sub-group shuffles for NVIDIA-capable devices, not on more parallelization of the existing structure.



**What changes:**
- The new `dagtech_romix` kernel from Increment 2 gets rewritten: launch with `4 × scrypt_blocks` work-items, use `__local` memory + barriers for the four threads of each scrypt block to share state, and reshape the V buffer to **interleaved layout** so adjacent work-items touch adjacent memory.

  Specifically: `V[ row * (4 * scrypt_blocks) * 8 + (scrypt_block * 4 + thread_in_block) * 8 + lane_uint ]` — meaning the four threads of one scrypt block write four adjacent 8-uint chunks, and adjacent scrypt blocks sit right next to each other.

- `source/dagtech_miner.c`: `global_size` arg to the ROMix dispatch becomes `4 * global_size_hashes`. `gpu_fit_global_size` accounting stays the same (V buffer size per hash didn't change, just its internal layout).

**Expected win:** this is where the real speedup lives. The reference miner's playbook says memory-bandwidth-bound kernels respond strongly to coalescing on discrete GPUs.

**Risk:** high. New layout means every V read/write changes; the Salsa20/8 state must be reconstructed from four threads' partial views; barriers are non-trivial to place correctly. The post-ROMix X[0] tweak runs **after** ROMix output is recombined into a single 32-uint state — easy to get wrong.

**Rollback:** the previous increment's `dagtech_romix` kernel is preserved alongside, selectable via an env var or `GPU_COOP_THREADS=0|1`. If we ship Increment 3 broken, users can fall back without re-installing.

### #42 — GPU work-size autotune (status update)

**Shipped (uncommitted, in source tree):** trial harness, scoring formula (reference miner's), key-based JSON cache, gpu_thread startup integration, config knobs in config.env and via env-var override.

Config knobs (all opt-in, AUTOTUNE defaults to 0):
- `AUTOTUNE` (0|1): turn it on
- `AUTOTUNE_BATCHES` (comma list): default `"1024,2048,4096,8192"`
- `AUTOTUNE_KERNEL_MODES` (comma list): default `"split,legacy"` (coop stays manual)
- `AUTOTUNE_TRIAL_SECONDS` (5..600): default 60 (was 30 in early draft)
- `AUTOTUNE_FORCE` (0|1): force re-run, ignore cache
- `AUTOTUNE_CACHE` (path): default `C:\dagtech-gpu-miner\autotune.json`
- `TARGET_BATCH_MS`: default 1500 (latency penalty threshold)

Scoring formula (matches reference miner; per-penalty cap at 0.75 of base):
```
accepted_factor = submitted>0 ? max(0.15, accepted/submitted) : 0.85
base = hashrate_hps * accepted_factor
stale_penalty   = base * min(0.75, stale_rate)
lowdiff_penalty = base * min(0.75, rejected_rate)
useful = max(0, base - stale_penalty - lowdiff_penalty)
latency_penalty = avg_batch_ms > target_ms ? useful * (1 - target_ms/avg_batch_ms) : 0
final_score = max(0, useful - latency_penalty)
```

**Bug found and fixed during validation:** the first iteration's trial harness omitted `GPU_THROTTLE`'s duty-cycle sleep. Trials ran at 100% duty cycle while live mining runs at `gpu_throttle`%. Trial hashrates were inflated by `1/throttle` (2× at the default 50% throttle). Patched: trial harness now applies the same `gpu_elapsed * (100 - gpu_throttle) / gpu_throttle` sleep as the main loop.

**Validation results (RTX 4060 Laptop, AUTOTUNE_FORCE=1, AUTOTUNE_TRIAL_SECONDS=30, post-throttle-fix):**

| # | Batchsize | Mode | hps | sub/acc | avg_ms | score |
|---|---|---|---|---|---|---|
| 1 | 1024 | split | 35,331 | 3/3 | 10.0 | 35,331 |
| 2 | 2048 | split | 126,090 | 14/14 | 5.7 | 126,090 |
| 3 | 4096 | split | 125,226 | 11/11 | 11.2 | 125,226 |
| 4 | 8192 | split | 166,451 | 12/12 | 17.1 | 166,451 |
| 5 | 1024 | legacy | 31,231 | 4/4 | 10.5 | 31,231 |
| 6 | 2048 | legacy | 122,582 | 11/10 | 6.1 | 102,151 |
| 7 | 4096 | legacy | 124,799 | 10/10 | 11.3 | 124,799 |
| 8 | 8192 | legacy | **217,548** | 15/15 | 13.3 | **217,548 ← winner** |

Live steady-state at the autotune-picked config (legacy@8192): ~257 KH/s. Trial under-measured by ~15% (warmup overhead, short trial). Inc2's split@8192 steady-state was ~272 KH/s, so the autotune pick is within 5% of best-known. Autotune did NOT pick a wildly wrong winner — both legacy@8192 (post-Inc1 uint4 benefits) and split@8192 are top-tier on this GPU; short trials had enough noise that legacy edged split this time.

**Known limitations of v1:**
- Short trials (30s default in test, 60s production) have run-to-run variance. The picked winner is consistently top-tier but may flip between top candidates on different runs.
- No per-candidate latency-vs-target tracking yet (just averages avg_batch_ms).
- No detailed `autotune_summary_*.json` reports — only the winner is saved.
- No `AUTO_THRESHOLD` adaptive submit margin.
- Trial harness duplicates the main-loop dispatch (~80 lines) rather than refactoring — keeps the working main path completely safe, costs duplication.

**Two operational bugs surfaced during validation (separate from autotune):**
1. **Scheduled task is named `DagTech Miner`** (not `DagTech GPU Miner` as the README implies). `Stop-ScheduledTask -TaskName 'DagTech GPU Miner'` silently no-ops.
2. **`dagtech_default_config_path()`** in `dagtech_miner.c` looks for config under `$USERPROFILE/dagtech-gpu-miner/`, but the install lives at `C:\dagtech-gpu-miner\`. When the scheduled task starts the miner via the control server, the miner can't read config.env (relies on CLI args from the control server instead). Anything in config.env that isn't passed as a CLI arg — including all AUTOTUNE knobs — never takes effect on a scheduled-task launch. Workarounds for now: env vars (machine-scope), or `--config` CLI flag added to the control server's `Build-MinerArgList`.

---

### Increment 4 — Tune work-group size

Once Increment 3 is producing correct shares, find the optimal work-group size for cooperative-thread layout. Currently we pass `NULL` for local_work_size in `clEnqueueNDRangeKernel` (line 889). The kernel will run with whatever the driver picks. For 4-threads-per-hash, work-group size should be a multiple of 4 and large enough for one sub-group/warp (32 on NVIDIA, 64 on AMD). Trying `64`, `128`, `256` and picking the best is one short experiment.

This is the bridge to **#42 (autotune)**: it shows there's a meaningful work-group-size search to do per device.

---

## 5. Order of operations and checkpoints

| Step | Touches | Validation |
|---|---|---|
| 1 | New file `task-40-port-plan.md` (this doc) | — |
| 2 | Increment 1 → build → mine for 5 min | `gpu_hashrate > 129 KH/s`, shares still accepting, no "implausibly fast" |
| 3 | Increment 1 commit + version bump to `GPU-2026.0607.3` | clean tree |
| 4 | Increment 2 → build → mine 5 min | hashrate ≈ same as baseline (split overhead), shares still accepting |
| 5 | Increment 2 commit + bump `0607.4` | clean tree |
| 6 | Increment 3 → build → mine 10 min | hashrate **substantially** > baseline, share ratio unchanged |
| 7 | Increment 3 commit + bump `0607.5` | clean tree |
| 8 | Increment 4 → quick local sweep | best WGS noted; not committed until #42 |
| 9 | Move on to #42 (autotune) on a clean tree |

If any step's validation fails, that step's commit doesn't land. Previous increments stay.

---

## 6. Open questions

1. **Sub-group size on the 4060.** Likely 32. Need to read `CL_DEVICE_SUB_GROUP_SIZES_INTEL` or `clGetKernelSubGroupInfo` if available, otherwise assume 32 for the cooperative-thread layout's barrier placement. Not blocking for Increment 1.
2. **Should `dagtech_search` (single-kernel path) stay shipped after Increment 2?** Yes for now — it's a runtime fallback (`GPU_KERNEL_MODE=legacy`) until #40 is proven stable across devices.
3. **The reference miner's `hasher_combo_kernel` (gen+hash fused).** Worth porting after Increment 3 is stable — fewer launches per nonce, less per-kernel overhead. Skip for now to keep increments small.

---

## 7. Concretely, what's next

Increment 1 only touches `dagtech_gpu.cl:335–350` (`scrypt_romix`'s Fill and Mix inner loops). Smallest possible change that exercises the build/run/validate loop end-to-end. If you want to proceed, I'd:

1. Make the `uint4` edit in `dagtech_gpu.cl`.
2. Build via `tools/build-gpu-miner.ps1`.
3. Stop the running miner, swap in the new `dagtech-gpu-miner.exe` at `C:\dagtech-gpu-miner\bin\`, restart.
4. Watch metrics for 5 minutes — confirm `gpu_hashrate > 129 KH/s` and share-accept ratio unchanged.
5. If green, commit as `GPU-2026.0607.3: uint4 V-buffer access in scrypt_romix`. If red, revert.

No version bump needed during dev — we only bump on the commit at the end of an increment.
