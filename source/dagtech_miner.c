/*
 * DagTech GPU Miner - High Performance CPU+GPU Mining Engine
 * Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
 * https://dagtech.network
 *
 * Licensed under the MIT License.
 * Custom implementation of Modified Scrypt (N=1024, r=1, p=1)
 * with proprietary post-ROMix transformation.
 *
 * GPU support via OpenCL (compile with -DDAGTECH_GPU -lOpenCL).
 * Without -DDAGTECH_GPU, builds as a pure CPU miner identical to
 * the original dagtech-miner.
 *
 * Stratum protocol compatible with standard mining pools.
 *
 * Author:  Dawie Nel <dawie@dagtech.network>
 * Project: DagTech Mining Suite
 * Version: GPU-2026.0521.1
 */

#ifdef _WIN32
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #ifdef _MSC_VER
    #pragma comment(lib, "ws2_32.lib")
    typedef int ssize_t;
  #endif
  #define close closesocket
  #define usleep(x) Sleep((x)/1000)
  #define sleep(x) Sleep((x)*1000)
#else
  #include <arpa/inet.h>
  #include <netdb.h>
  #include <netinet/in.h>
  #include <sys/socket.h>
  #include <unistd.h>
  #ifdef __APPLE__
    #include <sys/sysctl.h>
  #endif
#endif

#ifdef USE_OPENSSL
  #include <openssl/sha.h>
  #define DT_SHA256(data, len, out)       SHA256(data, len, out)
  #define DT_SHA256_CTX                   SHA256_CTX
  #define DT_SHA256_Init(ctx)             SHA256_Init(ctx)
  #define DT_SHA256_Update(ctx, d, l)     SHA256_Update(ctx, d, l)
  #define DT_SHA256_Final(out, ctx)       SHA256_Final(out, ctx)
#else
  #include "dagtech_sha256.h"
  #define DT_SHA256(data, len, out)       dagtech_sha256(data, len, out)
  #define DT_SHA256_CTX                   DAGTECH_SHA256_CTX
  #define DT_SHA256_Init(ctx)             dagtech_sha256_init(ctx)
  #define DT_SHA256_Update(ctx, d, l)     dagtech_sha256_update(ctx, d, l)
  #define DT_SHA256_Final(out, ctx)       dagtech_sha256_final(ctx, out)
#endif

#ifdef DAGTECH_GPU
  #ifdef __APPLE__
    #include <OpenCL/opencl.h>
  #else
    #include <CL/cl.h>
  #endif
#endif

#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include <math.h>
#ifndef _WIN32
  #include <sys/stat.h>
#endif

#ifdef _WIN32
  #define DT_PRIu64 "I64u"
#else
  #define DT_PRIu64 "llu"
#endif

/* =========================================================================
 * DagTech GPU Miner Configuration
 * ========================================================================= */
#define DAGTECH_VERSION       "GPU-2026.0604.8"
#define DAGTECH_BANNER        "DagTech GPU Miner v" DAGTECH_VERSION " - dagtech.network"
#define DAGTECH_AUTHOR        "Dawie Nel / DagTech Ltd"
#define DAGTECH_DEFAULT_POOL  "excalibur.dagtech.network"
#define DAGTECH_DEFAULT_PORT  3334

/* Scrypt parameters - fixed for this algorithm */
#define SCRYPT_N  1024
#define SCRYPT_R  1
#define SCRYPT_P  1

/* =========================================================================
 * Runtime State
 * ========================================================================= */
static char pool_host[256]     = DAGTECH_DEFAULT_POOL;
static int  pool_port          = DAGTECH_DEFAULT_PORT;
static char wallet[128]        = "";
static char worker_name[64]    = "dagtech";
static char password[32]       = "";
static int  num_threads        = 0;  /* 0 = auto-detect */
static int  cpu_priority       = 0;  /* 0=normal, 1=low */
static int  cpu_limit          = 100; /* 1-100: % of CPU time to use per thread */
static int  gpu_throttle       = 100; /* 1-100: % of GPU time to use (duty-cycle throttle) */
static volatile int running    = 1;
static volatile int keep_alive = 1;  /* 0 = clean program exit; stays 1 across reconnects */
static int  metrics_port       = 8881;  /* built-in metrics/dashboard endpoint */
static char dashboard_dir[512] = "";

/* GPU configuration */
static int gpu_enabled   = -1;  /* -1=auto, 0=disabled, 1=enabled */
static int gpu_intensity = 80;  /* 0-100 */
static int gpu_platform  = 0;
static int gpu_device    = 0;   /* single-GPU fallback */

/* Multi-GPU: GPU_DEVICE=0,1 or GPU_DEVICE=all selects devices from gpu_platform */
#define MAX_GPUS 8
static int gpu_device_list[MAX_GPUS];
static int gpu_device_count    = 0;  /* 0 = use gpu_device (single) */
static int gpu_use_all         = 0;  /* 1 = use every GPU on the platform */
static int g_num_gpus          = 0;  /* GPUs successfully initialised */

/* Per-GPU intensity: GPU_INTENSITY=80,60 overrides the single global per card */
static int gpu_intensity_list[MAX_GPUS];
static int gpu_intensity_count = 0;  /* 0 = use gpu_intensity for all GPUs */

/* Stratum connection */
static int sockfd = -1;
static pthread_mutex_t sock_mtx  = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t job_mtx   = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t stats_mtx = PTHREAD_MUTEX_INITIALIZER;

/* Mining statistics */
static uint64_t total_hashes    = 0;
static uint64_t total_submitted = 0;
static uint64_t total_accepted  = 0;
static uint64_t total_rejected  = 0;
static uint64_t total_stale     = 0;
static uint64_t cpu_submitted   = 0;
static uint64_t gpu_submitted   = 0;
static uint64_t cpu_accepted    = 0;
static uint64_t gpu_accepted    = 0;
static uint64_t cpu_rejected    = 0;
static uint64_t gpu_rejected    = 0;
static uint64_t cpu_stale       = 0;
static uint64_t gpu_stale       = 0;

/* Pending submission ring buffer: maps submission id -> source (CPU=0, GPU=1)
   so that pool accept/reject responses can be attributed to the right source. */
#define PENDING_SUB_MAX 64
static struct { uint64_t id; int is_gpu; } pending_subs[PENDING_SUB_MAX];
static int pending_head  = 0;
static int pending_count = 0;
static pthread_mutex_t pending_mtx = PTHREAD_MUTEX_INITIALIZER;
static double   current_hashrate = 0.0;
static double   cpu_hashrate     = 0.0;
static double   gpu_hashrate     = 0.0;
static time_t   start_time;

/* Per-session hash counters for hashrate tracking */
static uint64_t cpu_hashes_session = 0;
static uint64_t gpu_hashes_session = 0;
static pthread_mutex_t cpu_stats_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gpu_stats_mtx = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    int      valid;
    uint64_t seq;
    char     job_id[128];
    char     prevhash[256];
    char     version[16];
    char     bits[16];
    char     ntime[16];
    char     extranonce1[16];
    double   difficulty;
} DagTechJob;

static DagTechJob current_job = {0};
static char extranonce1_global[16] = "";
static double current_difficulty = 0.01;

/* =========================================================================
 * Utility Functions - DagTech Implementation
 * ========================================================================= */
#define DAGTECH_SWAB32(x) (((x)>>24)|(((x)>>8)&0xff00)|(((x)<<8)&0xff0000)|((x)<<24))

static void hex_to_bytes(const char *hex, uint8_t *out, int len) {
    for (int i = 0; i < len; i++) {
        unsigned int byte;
        sscanf(hex + 2 * i, "%2x", &byte);
        out[i] = (uint8_t)byte;
    }
}

static void bytes_to_hex(const uint8_t *data, int len, char *out) {
    for (int i = 0; i < len; i++)
        sprintf(out + 2 * i, "%02x", data[i]);
    out[2 * len] = 0;
}

/* Millisecond wall-clock timer for CPU throttle */
static long long dagtech_tick_ms(void) {
#ifdef _WIN32
    return (long long)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

static void sha256d(const uint8_t *data, int len, uint8_t *out) {
    uint8_t h1[32];
    DT_SHA256(data, len, h1);
    DT_SHA256(h1, 32, out);
}

/* =========================================================================
 * DagTech Scrypt Engine (N=1024, r=1, p=1)
 * cpuminer-compatible scrypt_1024_1_1_256 implementation
 * ========================================================================= */

static const uint32_t dagtech_sha256_iv[8] = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
};

/* cpuminer PBKDF2 padding constants */
static const uint32_t scrypt_keypad[12]  = {
    0x80000000,0,0,0,0,0,0,0,0,0,0,0x00000280
};
static const uint32_t scrypt_innerpad[11] = {
    0x80000000,0,0,0,0,0,0,0,0,0,0x000004a0
};
static const uint32_t scrypt_outerpad[8] = {
    0x80000000,0,0,0,0,0,0,0x00000300
};
static const uint32_t scrypt_finalblk[16] = {
    0x00000001,0x80000000,0,0,0,0,0,0,0,0,0,0,0,0,0,0x00000620
};

/* SHA256 compression on uint32 words; swap=0: W[i]=block[i] (LE), swap=1: W[i]=bswap(block[i]) (BE) */
static void dagtech_sha256_xform(uint32_t state[8], const uint32_t block[16], int swap) {
    uint32_t W[64];
    if (swap)
        for (int i = 0; i < 16; i++) W[i] = DAGTECH_SWAB32(block[i]);
    else
        for (int i = 0; i < 16; i++) W[i] = block[i];
    for (int i = 16; i < 64; i++)
        W[i] = DAGTECH_SIG1(W[i-2]) + W[i-7] + DAGTECH_SIG0(W[i-15]) + W[i-16];
    uint32_t a=state[0],b=state[1],c=state[2],d=state[3];
    uint32_t e=state[4],f=state[5],g=state[6],h=state[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + DAGTECH_EP1(e) + DAGTECH_CH(e,f,g) + dagtech_sha256_k[i] + W[i];
        uint32_t t2 = DAGTECH_EP0(a) + DAGTECH_MAJ(a,b,c);
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d;
    state[4]+=e; state[5]+=f; state[6]+=g; state[7]+=h;
}

/* HMAC-SHA256 init for 80-byte key: computes tstate (inner) and ostate (outer) */
static void dagtech_hmac80_init(const uint32_t *key, uint32_t *tstate, uint32_t *ostate) {
    uint32_t ihash[8], pad[16];
    int i;
    /* Finish inner hash: tstate already has midstate (SHA256 of key[0..63]); process key[64..79] + keypad */
    memcpy(pad, key + 16, 16);
    memcpy(pad + 4, scrypt_keypad, 48);
    dagtech_sha256_xform(tstate, pad, 0);
    memcpy(ihash, tstate, 32);
    /* ostate = SHA256_IV XOR'd with (ihash XOR opad_const) */
    memcpy(ostate, dagtech_sha256_iv, 32);
    for (i = 0; i < 8; i++) pad[i] = ihash[i] ^ 0x5c5c5c5c;
    for (; i < 16; i++) pad[i] = 0x5c5c5c5c;
    dagtech_sha256_xform(ostate, pad, 0);
    /* tstate = SHA256_IV XOR'd with (ihash XOR ipad_const) */
    memcpy(tstate, dagtech_sha256_iv, 32);
    for (i = 0; i < 8; i++) pad[i] = ihash[i] ^ 0x36363636;
    for (; i < 16; i++) pad[i] = 0x36363636;
    dagtech_sha256_xform(tstate, pad, 0);
}

/* PBKDF2 phase 1: 80-byte password/salt -> 128-byte X */
static void dagtech_pbkdf2_80_128(const uint32_t *tstate, const uint32_t *ostate,
                                   const uint32_t *salt, uint32_t *output) {
    uint32_t istate[8], ostate2[8], ibuf[16], obuf[16];
    memcpy(istate, tstate, 32);
    dagtech_sha256_xform(istate, salt, 0);
    memcpy(ibuf, salt + 16, 16);
    memcpy(ibuf + 5, scrypt_innerpad, 44);
    memcpy(obuf + 8, scrypt_outerpad, 32);
    for (int i = 0; i < 4; i++) {
        memcpy(obuf, istate, 32);
        ibuf[4] = i + 1;
        dagtech_sha256_xform(obuf, ibuf, 0);
        memcpy(ostate2, ostate, 32);
        dagtech_sha256_xform(ostate2, obuf, 0);
        for (int j = 0; j < 8; j++)
            output[8*i + j] = DAGTECH_SWAB32(ostate2[j]);
    }
}

/* PBKDF2 phase 2: 128-byte X -> 32-byte output */
static void dagtech_pbkdf2_128_32(uint32_t *tstate, uint32_t *ostate,
                                   const uint32_t *salt, uint32_t *output) {
    uint32_t buf[16];
    dagtech_sha256_xform(tstate, salt,      1);
    dagtech_sha256_xform(tstate, salt + 16, 1);
    dagtech_sha256_xform(tstate, scrypt_finalblk, 0);
    memcpy(buf, tstate, 32);
    memcpy(buf + 8, scrypt_outerpad, 32);
    dagtech_sha256_xform(ostate, buf, 0);
    for (int i = 0; i < 8; i++)
        output[i] = DAGTECH_SWAB32(ostate[i]);
}

static void dagtech_xor_salsa8(uint32_t B[16], const uint32_t Bx[16]) {
    uint32_t x00=(B[0]^=Bx[0]),  x01=(B[1]^=Bx[1]),  x02=(B[2]^=Bx[2]),  x03=(B[3]^=Bx[3]);
    uint32_t x04=(B[4]^=Bx[4]),  x05=(B[5]^=Bx[5]),  x06=(B[6]^=Bx[6]),  x07=(B[7]^=Bx[7]);
    uint32_t x08=(B[8]^=Bx[8]),  x09=(B[9]^=Bx[9]),  x10=(B[10]^=Bx[10]), x11=(B[11]^=Bx[11]);
    uint32_t x12=(B[12]^=Bx[12]), x13=(B[13]^=Bx[13]), x14=(B[14]^=Bx[14]), x15=(B[15]^=Bx[15]);
    #define ROTL(a,c) (((a)<<(c)) | ((a)>>(32-(c))))
    for (int i = 0; i < 8; i += 2) {
        x04^=ROTL(x00+x12,7);  x09^=ROTL(x05+x01,7);
        x14^=ROTL(x10+x06,7);  x03^=ROTL(x15+x11,7);
        x08^=ROTL(x04+x00,9);  x13^=ROTL(x09+x05,9);
        x02^=ROTL(x14+x10,9);  x07^=ROTL(x03+x15,9);
        x12^=ROTL(x08+x04,13); x01^=ROTL(x13+x09,13);
        x06^=ROTL(x02+x14,13); x11^=ROTL(x07+x03,13);
        x00^=ROTL(x12+x08,18); x05^=ROTL(x01+x13,18);
        x10^=ROTL(x06+x02,18); x15^=ROTL(x11+x07,18);
        x01^=ROTL(x00+x03,7);  x06^=ROTL(x05+x04,7);
        x11^=ROTL(x10+x09,7);  x12^=ROTL(x15+x14,7);
        x02^=ROTL(x01+x00,9);  x07^=ROTL(x06+x05,9);
        x08^=ROTL(x11+x10,9);  x13^=ROTL(x12+x15,9);
        x03^=ROTL(x02+x01,13); x04^=ROTL(x07+x06,13);
        x09^=ROTL(x08+x11,13); x14^=ROTL(x13+x12,13);
        x00^=ROTL(x03+x02,18); x05^=ROTL(x04+x07,18);
        x10^=ROTL(x09+x08,18); x15^=ROTL(x14+x13,18);
    }
    #undef ROTL
    B[0]+=x00;  B[1]+=x01;  B[2]+=x02;  B[3]+=x03;
    B[4]+=x04;  B[5]+=x05;  B[6]+=x06;  B[7]+=x07;
    B[8]+=x08;  B[9]+=x09;  B[10]+=x10; B[11]+=x11;
    B[12]+=x12; B[13]+=x13; B[14]+=x14; B[15]+=x15;
}

static void dagtech_scrypt_romix(uint32_t *X, uint32_t *V, int N) {
    for (int i = 0; i < N; i++) {
        memcpy(&V[i * 32], X, 128);
        dagtech_xor_salsa8(&X[0], &X[16]);
        dagtech_xor_salsa8(&X[16], &X[0]);
    }
    for (int i = 0; i < N; i++) {
        int j = X[16] & (N - 1);
        for (int k = 0; k < 32; k++) X[k] ^= V[j * 32 + k];
        dagtech_xor_salsa8(&X[0], &X[16]);
        dagtech_xor_salsa8(&X[16], &X[0]);
    }
}

/*
 * DagTech Full Hash Function — scrypt_1024_1_1_256 (cpuminer-compatible)
 * V is a caller-supplied scratch buffer of SCRYPT_N * 128 bytes
 */
static void dagtech_hash(const uint8_t *input, uint8_t *output, uint32_t *V) {
    uint32_t tstate[8], ostate[8], X[32];
    const uint32_t *in32 = (const uint32_t *)input;
    /* Midstate: SHA256 of first 64 bytes of input with LE word loading */
    memcpy(tstate, dagtech_sha256_iv, 32);
    dagtech_sha256_xform(tstate, in32, 0);
    /* HMAC init */
    dagtech_hmac80_init(in32, tstate, ostate);
    /* PBKDF2 phase 1: header -> 128-byte X */
    dagtech_pbkdf2_80_128(tstate, ostate, in32, X);
    /* ROMix */
    dagtech_scrypt_romix(X, V, SCRYPT_N);
    /* Pool post-ROMix X[0] modification: add 0xe0 to lower 15 bits of bswap(X[0]) */
    {
        uint32_t B = DAGTECH_SWAB32(X[0]);
        uint32_t M = (B & 0xffff8000) | ((B + 0xe0) & 0x7fff);
        X[0] = DAGTECH_SWAB32(M);
    }
    /* PBKDF2 phase 2: X -> 32-byte hash */
    dagtech_pbkdf2_128_32(tstate, ostate, X, (uint32_t *)output);
}

/* =========================================================================
 * OpenCL GPU Worker
 * ========================================================================= */
#ifdef DAGTECH_GPU

/* Per-GPU OpenCL state — one entry per active device */
typedef struct {
    cl_device_id     device;
    cl_context       ctx;
    cl_command_queue queue;
    cl_program       program;
    cl_kernel        kernel;
    cl_mem           V_buf;
    cl_mem           output_buf;
    size_t           global_size;
    int              platform_idx;
    int              device_idx;
    int              gpu_index;    /* 0-based position among active GPUs */
    volatile int     ready;
    char             name[256];
    int              intensity;        /* actual intensity used for this GPU */
    uint64_t         hashes_session;   /* per-GPU hash counter */
    double           hashrate;         /* per-GPU H/s updated by stats loop */
} GpuCtx;

static GpuCtx g_gpus[MAX_GPUS];

/* Compute global_size from intensity (0-100 -> 2^14 .. 2^20) */
static size_t gpu_intensity_to_global_size(int intensity) {
    if (intensity <= 0)   return (size_t)1 << 14;
    if (intensity >= 100) return (size_t)1 << 20;
    /* linear interpolation across exponent 14..20 */
    double exp_val = 14.0 + (intensity / 100.0) * 6.0;
    return (size_t)1 << (int)(exp_val + 0.5);
}

/* Load the kernel source from the same directory as argv[0] */
static char *gpu_load_kernel_source(const char *exe_path, size_t *src_len) {
    char cl_path[1024];

    /* Build path: replace binary name with dagtech_gpu.cl */
    strncpy(cl_path, exe_path, sizeof(cl_path) - 1);
    cl_path[sizeof(cl_path) - 1] = '\0';

    /* Find last path separator */
    char *sep = strrchr(cl_path, '/');
#ifdef _WIN32
    {
        char *sep2 = strrchr(cl_path, '\\');
        if (sep2 > sep) sep = sep2;
    }
#endif
    if (sep) {
        *(sep + 1) = '\0';
        strncat(cl_path, "dagtech_gpu.cl", sizeof(cl_path) - strlen(cl_path) - 1);
    } else {
        strncpy(cl_path, "dagtech_gpu.cl", sizeof(cl_path) - 1);
    }

    FILE *f = fopen(cl_path, "rb");
    if (!f) {
        fprintf(stderr, "[DagTech GPU] ERROR: Cannot open kernel: %s\n", cl_path);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *src = (char *)malloc(fsize + 1);
    if (!src) { fclose(f); return NULL; }
    fread(src, 1, fsize, f);
    src[fsize] = '\0';
    fclose(f);
    if (src_len) *src_len = (size_t)fsize;
    return src;
}

/* Lists all OpenCL GPUs to stdout */
static void gpu_list_devices(void) {
    cl_uint num_platforms = 0;
    clGetPlatformIDs(0, NULL, &num_platforms);
    if (num_platforms == 0) {
        printf("[DagTech GPU] No OpenCL platforms found.\n");
        return;
    }
    cl_platform_id *platforms = (cl_platform_id *)malloc(num_platforms * sizeof(cl_platform_id));
    clGetPlatformIDs(num_platforms, platforms, NULL);
    printf("[DagTech GPU] Detected OpenCL devices:\n");
    for (cl_uint p = 0; p < num_platforms; p++) {
        cl_uint num_devices = 0;
        clGetDeviceIDs(platforms[p], CL_DEVICE_TYPE_GPU, 0, NULL, &num_devices);
        for (cl_uint d = 0; d < num_devices; d++) {
            cl_device_id dev;
            clGetDeviceIDs(platforms[p], CL_DEVICE_TYPE_GPU, d + 1, &dev, NULL);
            char name[256] = {0};
            clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof(name), name, NULL);
            printf("[DagTech GPU]   Platform %u Device %u: %s\n", p, d, name);
        }
    }
    free(platforms);
}

/* Initialise a single GPU into ctx using a pre-loaded kernel source string */
static int gpu_init_one(GpuCtx *ctx, cl_platform_id platform, int platform_idx,
                        int device_idx, int gpu_index,
                        const char *src, size_t src_len) {
    cl_int err;

    /* Select device */
    cl_uint num_devices = 0;
    clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, 0, NULL, &num_devices);
    if (num_devices == 0 || (cl_uint)device_idx >= num_devices) {
        fprintf(stderr, "[DagTech GPU] Device %d not available on platform %d (only %u found).\n",
                device_idx, platform_idx, num_devices);
        return -1;
    }
    cl_device_id *devices = (cl_device_id *)malloc(num_devices * sizeof(cl_device_id));
    clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, num_devices, devices, NULL);
    ctx->device = devices[device_idx];
    free(devices);

    ctx->platform_idx = platform_idx;
    ctx->device_idx   = device_idx;
    ctx->gpu_index    = gpu_index;
    ctx->ready        = 0;

    clGetDeviceInfo(ctx->device, CL_DEVICE_NAME, sizeof(ctx->name), ctx->name, NULL);
    printf("[DagTech GPU] GPU %d: %s (platform %d, device %d)\n",
           gpu_index, ctx->name, platform_idx, device_idx);

    /* Per-GPU context and command queue */
    ctx->ctx = clCreateContext(NULL, 1, &ctx->device, NULL, NULL, &err);
    if (err != CL_SUCCESS) {
        fprintf(stderr, "[DagTech GPU] clCreateContext failed (GPU %d): %d\n", gpu_index, err);
        return -1;
    }
    ctx->queue = clCreateCommandQueue(ctx->ctx, ctx->device, 0, &err);
    if (err != CL_SUCCESS) {
        fprintf(stderr, "[DagTech GPU] clCreateCommandQueue failed (GPU %d): %d\n", gpu_index, err);
        clReleaseContext(ctx->ctx); ctx->ctx = NULL;
        return -1;
    }

    /* Compile kernel for this device */
    ctx->program = clCreateProgramWithSource(ctx->ctx, 1, &src, &src_len, &err);
    if (err != CL_SUCCESS) {
        fprintf(stderr, "[DagTech GPU] clCreateProgramWithSource failed (GPU %d): %d\n", gpu_index, err);
        clReleaseCommandQueue(ctx->queue); ctx->queue = NULL;
        clReleaseContext(ctx->ctx);        ctx->ctx   = NULL;
        return -1;
    }
    err = clBuildProgram(ctx->program, 1, &ctx->device, "-cl-std=CL1.2", NULL, NULL);
    if (err != CL_SUCCESS) {
        size_t log_size = 0;
        clGetProgramBuildInfo(ctx->program, ctx->device, CL_PROGRAM_BUILD_LOG, 0, NULL, &log_size);
        char *log = (char *)malloc(log_size + 1);
        if (log) {
            clGetProgramBuildInfo(ctx->program, ctx->device, CL_PROGRAM_BUILD_LOG,
                                  log_size, log, NULL);
            log[log_size] = '\0';
            fprintf(stderr, "[DagTech GPU] Kernel build error (GPU %d):\n%s\n", gpu_index, log);
            free(log);
        }
        clReleaseProgram(ctx->program);    ctx->program = NULL;
        clReleaseCommandQueue(ctx->queue); ctx->queue   = NULL;
        clReleaseContext(ctx->ctx);        ctx->ctx     = NULL;
        return -1;
    }
    ctx->kernel = clCreateKernel(ctx->program, "dagtech_search", &err);
    if (err != CL_SUCCESS) {
        fprintf(stderr, "[DagTech GPU] clCreateKernel failed (GPU %d): %d\n", gpu_index, err);
        clReleaseProgram(ctx->program);    ctx->program = NULL;
        clReleaseCommandQueue(ctx->queue); ctx->queue   = NULL;
        clReleaseContext(ctx->ctx);        ctx->ctx     = NULL;
        return -1;
    }

    /* Work size and V buffer — use per-GPU intensity if provided */
    ctx->intensity   = (gpu_intensity_count > gpu_index) ?
                        gpu_intensity_list[gpu_index] : gpu_intensity;
    ctx->global_size = gpu_intensity_to_global_size(ctx->intensity);
    printf("[DagTech GPU] GPU %d: global work size %zu (intensity %d)\n",
           gpu_index, ctx->global_size, ctx->intensity);

    size_t v_bytes = ctx->global_size * 1024 * 32 * sizeof(cl_uint);
    printf("[DagTech GPU] GPU %d: allocating V buffer %.1f MB\n",
           gpu_index, v_bytes / (1024.0 * 1024.0));
    ctx->V_buf = clCreateBuffer(ctx->ctx, CL_MEM_READ_WRITE, v_bytes, NULL, &err);
    if (err != CL_SUCCESS) {
        fprintf(stderr, "[DagTech GPU] V buffer failed (GPU %d, %zu bytes): %d\n"
                        "[DagTech GPU] Try reducing --gpu-intensity.\n", gpu_index, v_bytes, err);
        clReleaseKernel(ctx->kernel);      ctx->kernel  = NULL;
        clReleaseProgram(ctx->program);    ctx->program = NULL;
        clReleaseCommandQueue(ctx->queue); ctx->queue   = NULL;
        clReleaseContext(ctx->ctx);        ctx->ctx     = NULL;
        return -1;
    }

    /* Output buffer: [0]=best_nonce, [1]=found_count */
    ctx->output_buf = clCreateBuffer(ctx->ctx, CL_MEM_READ_WRITE, 2 * sizeof(cl_uint), NULL, &err);
    if (err != CL_SUCCESS) {
        fprintf(stderr, "[DagTech GPU] Output buffer failed (GPU %d): %d\n", gpu_index, err);
        clReleaseMemObject(ctx->V_buf);    ctx->V_buf   = NULL;
        clReleaseKernel(ctx->kernel);      ctx->kernel  = NULL;
        clReleaseProgram(ctx->program);    ctx->program = NULL;
        clReleaseCommandQueue(ctx->queue); ctx->queue   = NULL;
        clReleaseContext(ctx->ctx);        ctx->ctx     = NULL;
        return -1;
    }

    ctx->ready = 1;
    return 0;
}

/* Discover and initialise all requested GPUs on gpu_platform */
static int gpu_init_all(const char *exe_path) {
    /* Load kernel source once — reused for every GPU's compile */
    size_t src_len = 0;
    char *src = gpu_load_kernel_source(exe_path, &src_len);
    if (!src) return -1;

    /* Select platform */
    cl_uint num_platforms = 0;
    clGetPlatformIDs(0, NULL, &num_platforms);
    if (num_platforms == 0) {
        fprintf(stderr, "[DagTech GPU] No OpenCL platforms found.\n");
        free(src); return -1;
    }
    if ((cl_uint)gpu_platform >= num_platforms) {
        fprintf(stderr, "[DagTech GPU] Platform %d not available (only %u found).\n",
                gpu_platform, num_platforms);
        free(src); return -1;
    }
    cl_platform_id *platforms = (cl_platform_id *)malloc(num_platforms * sizeof(cl_platform_id));
    clGetPlatformIDs(num_platforms, platforms, NULL);
    cl_platform_id plat = platforms[gpu_platform];
    free(platforms);

    /* Count available GPU devices on this platform */
    cl_uint num_devices = 0;
    clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 0, NULL, &num_devices);
    if (num_devices == 0) {
        fprintf(stderr, "[DagTech GPU] No GPU devices on platform %d.\n", gpu_platform);
        free(src); return -1;
    }

    /* Build list of device indices to initialise */
    int dev_list[MAX_GPUS];
    int dev_count = 0;

    if (gpu_use_all) {
        for (cl_uint d = 0; d < num_devices && dev_count < MAX_GPUS; d++)
            dev_list[dev_count++] = (int)d;
    } else if (gpu_device_count > 0) {
        for (int i = 0; i < gpu_device_count && i < MAX_GPUS; i++)
            dev_list[dev_count++] = gpu_device_list[i];
    } else {
        /* Backward-compatible single-device mode */
        dev_list[0] = gpu_device;
        dev_count   = 1;
    }

    /* Initialise each selected device */
    g_num_gpus = 0;
    memset(g_gpus, 0, sizeof(g_gpus));
    for (int i = 0; i < dev_count; i++) {
        if (g_num_gpus >= MAX_GPUS) break;
        if (gpu_init_one(&g_gpus[g_num_gpus], plat, gpu_platform,
                         dev_list[i], g_num_gpus, src, src_len) == 0) {
            g_num_gpus++;
        } else {
            fprintf(stderr, "[DagTech GPU] Skipping device %d (init failed).\n", dev_list[i]);
        }
    }

    free(src);
    if (g_num_gpus == 0) return -1;
    printf("[DagTech GPU] Initialised %d GPU(s) successfully.\n", g_num_gpus);
    return 0;
}

static void gpu_cleanup(void) {
    for (int i = 0; i < g_num_gpus; i++) {
        GpuCtx *ctx = &g_gpus[i];
        if (ctx->output_buf) { clReleaseMemObject(ctx->output_buf); ctx->output_buf = NULL; }
        if (ctx->V_buf)      { clReleaseMemObject(ctx->V_buf);      ctx->V_buf      = NULL; }
        if (ctx->kernel)     { clReleaseKernel(ctx->kernel);        ctx->kernel     = NULL; }
        if (ctx->program)    { clReleaseProgram(ctx->program);      ctx->program    = NULL; }
        if (ctx->queue)      { clReleaseCommandQueue(ctx->queue);   ctx->queue      = NULL; }
        if (ctx->ctx)        { clReleaseContext(ctx->ctx);          ctx->ctx        = NULL; }
        ctx->ready = 0;
    }
    g_num_gpus = 0;
}

/* GPU mining thread: covers a non-overlapping partition of 0x80000000-0xFFFFFFFF.
 * GPU i starts at 0x80000000 + i*global_size and strides by N*global_size,
 * ensuring N parallel GPUs tile the full range without overlap. */
static void *dagtech_gpu_thread(void *arg) {
    GpuCtx *ctx = (GpuCtx *)arg;
    int gpu_idx = ctx->gpu_index;

    if (!ctx->ready) {
        fprintf(stderr, "[DagTech GPU] GPU %d not ready, thread exiting.\n", gpu_idx);
        return NULL;
    }

    uint32_t nonce_base   = 0x80000000u + (uint32_t)gpu_idx * (uint32_t)ctx->global_size;
    uint32_t nonce_stride = (uint32_t)g_num_gpus  * (uint32_t)ctx->global_size;

    printf("[DagTech GPU] Worker %d started: %s (nonce base 0x%08x, stride 0x%x)\n",
           gpu_idx, ctx->name, nonce_base, nonce_stride);

    /* Per-thread scratch buffer for CPU re-verification */
    uint32_t *V_cpu = (uint32_t *)malloc(SCRYPT_N * 128);
    if (!V_cpu) {
        fprintf(stderr, "[DagTech GPU] Out of memory for CPU verify buffer (GPU %d).\n", gpu_idx);
        return NULL;
    }

    while (running) {
        DagTechJob j;
        pthread_mutex_lock(&job_mtx);
        j = current_job;
        pthread_mutex_unlock(&job_mtx);

        if (!j.valid) { usleep(100000); continue; }

        uint64_t job_seq = j.seq;

        /* Build 80-byte header with nonce=0 (placeholder) */
        uint8_t header80[80];
        {
            uint8_t version[4], prevhash[32], ntime_b[4], bits_b[4];
            uint8_t en1[4], en2[4], en_combined[8], merkle[32];
            if (strlen(j.version) != 8 || strlen(j.prevhash) < 64 ||
                strlen(j.ntime) != 8 || strlen(j.bits) != 8 ||
                strlen(j.extranonce1) != 8) {
                usleep(100000);
                continue;
            }
            hex_to_bytes(j.version,    version,  4);
            hex_to_bytes(j.prevhash,   prevhash, 32);
            hex_to_bytes(j.ntime,      ntime_b,  4);
            hex_to_bytes(j.bits,       bits_b,   4);
            hex_to_bytes(j.extranonce1, en1,     4);
            memset(en2, 0, 4);
            memcpy(en_combined, en1, 4);
            memcpy(en_combined + 4, en2, 4);
            sha256d(en_combined, 8, merkle);
            memcpy(header80,      version,  4);
            memcpy(header80 + 4,  prevhash, 32);
            memcpy(header80 + 36, merkle,   32);
            memcpy(header80 + 68, ntime_b,  4);
            memcpy(header80 + 72, bits_b,   4);
            memset(header80 + 76, 0, 4);  /* nonce placeholder */
        }

        /* Convert header to uint32 array for kernel */
        cl_uint header_words[20];
        memcpy(header_words, header80, 80);

        /* Compute 32-bit difficulty target matching the CPU's 64-bit check.
         * CPU checks: hash_top64 <= 0x0000FFFF00000000 / difficulty
         * hash_top64 upper 32 bits == hash[7] (BSWAP(ostate[7])), so the GPU
         * pre-filter target is the upper 32 bits of that threshold.
         * Using 0xFFFFFFFF/diff instead is ~1000x too lenient: atomic_min
         * always picks a nonce near nonce_base that rarely passes the CPU check. */
        double diff = j.difficulty > 0.0 ? j.difficulty : 1.0;
        double thresh_d = (double)0x0000FFFF00000000ULL / diff;
        uint64_t thresh64 = (thresh_d >= 18446744073709551615.0) ? 0xFFFFFFFFFFFFFFFFULL : (uint64_t)thresh_d;
        cl_uint target32 = (cl_uint)(thresh64 >> 32);

        /* Upload header to this GPU's context */
        cl_mem header_buf = clCreateBuffer(ctx->ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR,
                                           20 * sizeof(cl_uint), header_words, NULL);
        if (!header_buf) { usleep(50000); continue; }

        /* Launch batches until job changes */
        while (running) {
            pthread_mutex_lock(&job_mtx);
            int job_changed = (current_job.seq != job_seq);
            pthread_mutex_unlock(&job_mtx);
            if (job_changed) break;

            /* Reset output buffer */
            cl_uint output_init[2] = { 0xFFFFFFFFu, 0 };
            clEnqueueWriteBuffer(ctx->queue, ctx->output_buf, CL_TRUE, 0,
                                 2 * sizeof(cl_uint), output_init, 0, NULL, NULL);

            /* Set kernel args */
            clSetKernelArg(ctx->kernel, 0, sizeof(cl_mem), &header_buf);
            clSetKernelArg(ctx->kernel, 1, sizeof(cl_mem), &ctx->output_buf);
            clSetKernelArg(ctx->kernel, 2, sizeof(cl_mem), &ctx->V_buf);
            clSetKernelArg(ctx->kernel, 3, sizeof(cl_uint), &target32);
            clSetKernelArg(ctx->kernel, 4, sizeof(cl_uint), &nonce_base);

            /* Launch */
            long long gpu_t0 = dagtech_tick_ms();
            cl_event ev;
            cl_int err = clEnqueueNDRangeKernel(ctx->queue, ctx->kernel, 1, NULL,
                                                 &ctx->global_size, NULL, 0, NULL, &ev);
            if (err != CL_SUCCESS) {
                fprintf(stderr, "[DagTech GPU] Kernel launch error (GPU %d): %d\n", gpu_idx, err);
                break;
            }
            clWaitForEvents(1, &ev);
            clReleaseEvent(ev);
            long long gpu_elapsed = dagtech_tick_ms() - gpu_t0;

            /* Read output */
            cl_uint output_result[2] = { 0xFFFFFFFFu, 0 };
            clEnqueueReadBuffer(ctx->queue, ctx->output_buf, CL_TRUE, 0,
                                2 * sizeof(cl_uint), output_result, 0, NULL, NULL);

            /* Account for hashes — aggregate and per-GPU */
            pthread_mutex_lock(&gpu_stats_mtx);
            ctx->hashes_session += ctx->global_size;
            gpu_hashes_session  += ctx->global_size;
            pthread_mutex_unlock(&gpu_stats_mtx);

            pthread_mutex_lock(&stats_mtx);
            total_hashes += ctx->global_size;
            pthread_mutex_unlock(&stats_mtx);

            /* GPU throttle: duty-cycle sleep proportional to kernel run time.
             * Sleeps in 100ms chunks so the thread stays responsive to new jobs.
             * gpu_throttle=50 means GPU runs half the time (50% duty cycle). */
            if (gpu_throttle < 100 && gpu_elapsed > 0) {
                long long sleep_ms = gpu_elapsed * (100 - gpu_throttle) / gpu_throttle;
                long long slept = 0;
                while (slept < sleep_ms && running) {
                    long long chunk = sleep_ms - slept;
                    if (chunk > 100) chunk = 100;
                    usleep((unsigned int)(chunk * 1000));
                    slept += chunk;
                    pthread_mutex_lock(&job_mtx);
                    int job_changed = (current_job.seq != job_seq);
                    pthread_mutex_unlock(&job_mtx);
                    if (job_changed) break;
                }
            }

            /* If candidate found, CPU re-verify before submitting */
            if (output_result[1] > 0 && output_result[0] != 0xFFFFFFFFu) {
                uint32_t cand_nonce = output_result[0];
                /* Build header with candidate nonce */
                uint8_t verify_hdr[80];
                memcpy(verify_hdr, header80, 80);
                verify_hdr[76] = cand_nonce & 0xff;
                verify_hdr[77] = (cand_nonce >> 8) & 0xff;
                verify_hdr[78] = (cand_nonce >> 16) & 0xff;
                verify_hdr[79] = (cand_nonce >> 24) & 0xff;

                uint8_t hash[32];
                dagtech_hash(verify_hdr, hash, V_cpu);

                /* Full 64-bit target check (same as CPU worker) */
                uint64_t hash_top64 =
                    ((uint64_t)hash[31] << 56) | ((uint64_t)hash[30] << 48) |
                    ((uint64_t)hash[29] << 40) | ((uint64_t)hash[28] << 32) |
                    ((uint64_t)hash[27] << 24) | ((uint64_t)hash[26] << 16) |
                    ((uint64_t)hash[25] <<  8) |  (uint64_t)hash[24];
                double threshold_d = (double)0x0000FFFF00000000ULL / j.difficulty;
                uint64_t threshold64 = (threshold_d >= 18446744073709551615.0) ?
                                        0xFFFFFFFFFFFFFFFFULL : (uint64_t)threshold_d;

                if (hash_top64 <= threshold64) {
                    printf("[DagTech GPU] ** SHARE FOUND ** GPU %d nonce=0x%08x\n",
                           gpu_idx, cand_nonce);

                    /* Re-read job under lock before submitting */
                    DagTechJob jcur;
                    pthread_mutex_lock(&job_mtx);
                    jcur = current_job;
                    pthread_mutex_unlock(&job_mtx);
                    if (jcur.seq == job_seq && jcur.valid) {
                        extern void dagtech_submit_share_ext(const DagTechJob *j, uint32_t nonce);
                        dagtech_submit_share_ext(&jcur, cand_nonce);
                    }
                }
            }

            /* Advance nonce base, wrapping within this GPU's partition */
            nonce_base += nonce_stride;
            if (nonce_base < 0x80000000u)
                nonce_base = 0x80000000u + (uint32_t)gpu_idx * (uint32_t)ctx->global_size;
        }

        clReleaseMemObject(header_buf);
    }

    free(V_cpu);
    return NULL;
}

#endif /* DAGTECH_GPU */

/* =========================================================================
 * Stratum Protocol - DagTech Network Communication
 * ========================================================================= */
static int dagtech_connect_pool(void) {

    struct addrinfo hints, *res, *rp;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", pool_port);

    int rc = getaddrinfo(pool_host, port_str, &hints, &res);
    if (rc != 0) {
        fprintf(stderr, "[DagTech] DNS resolution failed for %s: %s\n",
                pool_host, gai_strerror(rc));
        return -1;
    }

    for (rp = res; rp != NULL; rp = rp->ai_next) {
        sockfd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (sockfd < 0) continue;
        if (connect(sockfd, rp->ai_addr, (int)rp->ai_addrlen) == 0) break;
        close(sockfd);
        sockfd = -1;
    }
    freeaddrinfo(res);

    if (sockfd < 0) {
        fprintf(stderr, "[DagTech] Failed to connect to %s:%d\n", pool_host, pool_port);
        return -1;
    }
    return 0;
}

static void dagtech_send(const char *line) {
    pthread_mutex_lock(&sock_mtx);
    char buf[2048];
    snprintf(buf, sizeof(buf), "%s\n", line);
    send(sockfd, buf, (int)strlen(buf), 0);
    pthread_mutex_unlock(&sock_mtx);
}

static void dagtech_subscribe_authorize(void) {
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"DagTech/" DAGTECH_VERSION "\"]}");
    dagtech_send(buf);

    /* Pool requires a bare EVM address as the stratum username.
       Worker name is sent in the password field for display purposes. */
    char pass_field[128];
    if (worker_name[0])
        snprintf(pass_field, sizeof(pass_field), "%s", worker_name);
    else
        snprintf(pass_field, sizeof(pass_field), "%s", password);

    snprintf(buf, sizeof(buf),
        "{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"%s\",\"%s\"]}",
        wallet, pass_field);
    dagtech_send(buf);
}

static int extract_quoted(const char *line, char out[][256], int max) {
    int count = 0;
    const char *p = line;
    while (count < max && (p = strchr(p, '"')) != NULL) {
        p++;
        const char *end = strchr(p, '"');
        if (!end) break;
        int len = (int)(end - p);
        if (len > 255) len = 255;
        memcpy(out[count], p, len);
        out[count][len] = 0;
        count++;
        p = end + 1;
    }
    return count;
}

static void dagtech_parse_stratum(const char *line) {
    /* Subscribe response — id:1 exactly (not id:1000+), extract extranonce1 */
    if (strstr(line, "mining.subscribe") == NULL &&
        strstr(line, "\"result\"") && strstr(line, "\"id\":1,")) {
        char strings[20][256];
        int n = extract_quoted(line, strings, 20);
        for (int i = 0; i < n; i++) {
            if (strlen(strings[i]) == 8 &&
                strspn(strings[i], "0123456789abcdef") == 8) {
                strncpy(extranonce1_global, strings[i],
                        sizeof(extranonce1_global) - 1);
                printf("[DagTech] Subscribed - extranonce1=%s\n", extranonce1_global);
                break;
            }
        }
    }
    /* Authorize response — id:2, result:true, not a share accept */
    else if (strstr(line, "\"id\":2,") && strstr(line, "\"result\":true")) {
        printf("[DagTech] Authorized\n");
    }
    /* Difficulty update */
    else if (strstr(line, "mining.set_difficulty")) {
        const char *p = strstr(line, "params");
        if (p) {
            p = strchr(p, '[');
            if (p) {
                double new_diff = atof(p + 1);
                current_difficulty = new_diff;
                pthread_mutex_lock(&job_mtx);
                if (current_job.valid)
                    current_job.difficulty = new_diff;
                pthread_mutex_unlock(&job_mtx);
                printf("[DagTech] Difficulty: %.8f\n", current_difficulty);
            }
        }
    }
    /* New job notification */
    else if (strstr(line, "mining.notify")) {
        char strings[20][256];
        int n = extract_quoted(line, strings, 20);
        int offset = 0;
        for (int i = 0; i < n; i++) {
            if (strcmp(strings[i], "mining.notify") == 0) {
                offset = i + 1;
                break;
            }
        }
        if (offset < n && strcmp(strings[offset], "params") == 0)
            offset++;
        if (n - offset >= 5) {
            pthread_mutex_lock(&job_mtx);
            current_job.valid = 1;
            current_job.seq++;
            current_job.difficulty = current_difficulty;
            strncpy(current_job.job_id,     strings[offset],   sizeof(current_job.job_id) - 1);
            strncpy(current_job.prevhash,   strings[offset+1], sizeof(current_job.prevhash) - 1);
            strncpy(current_job.version,    strings[offset+2], sizeof(current_job.version) - 1);
            strncpy(current_job.bits,       strings[offset+3], sizeof(current_job.bits) - 1);
            strncpy(current_job.ntime,      strings[offset+4], sizeof(current_job.ntime) - 1);
            strncpy(current_job.extranonce1, extranonce1_global, sizeof(current_job.extranonce1) - 1);
            pthread_mutex_unlock(&job_mtx);
            printf("[DagTech] New job: %s (diff %.8f)\n",
                   current_job.job_id, current_job.difficulty);
        }
    }
    /* Share accepted */
    else if (strstr(line, "\"result\"") && strstr(line, "true")
             && !strstr(line, "false") && !strstr(line, "\"error\":[")) {
        /* Parse response id to attribute to CPU or GPU */
        const char *idp = strstr(line, "\"id\":");
        uint64_t resp_id = idp ? strtoull(idp + 5, NULL, 10) : (uint64_t)-1;
        int src = -1;
        pthread_mutex_lock(&pending_mtx);
        for (int pi = 0; pi < pending_count; pi++) {
            int idx = (pending_head + pi) % PENDING_SUB_MAX;
            if (pending_subs[idx].id == resp_id) { src = pending_subs[idx].is_gpu; break; }
        }
        pthread_mutex_unlock(&pending_mtx);
        pthread_mutex_lock(&stats_mtx);
        total_accepted++;
        if (src == 1) gpu_accepted++;
        else if (src == 0) cpu_accepted++;
        pthread_mutex_unlock(&stats_mtx);
        printf("[DagTech] Share ACCEPTED (%lu total | CPU:%lu GPU:%lu)\n",
               (unsigned long)total_accepted,
               (unsigned long)cpu_accepted,
               (unsigned long)gpu_accepted);
    }
    /* Share rejected — error code 21 = "Job not found" = stale (job expired
       before submit arrived). Stales are normal; actual rejects are a problem. */
    else if (strstr(line, "\"error\":[")) {
        const char *idp = strstr(line, "\"id\":");
        uint64_t resp_id = idp ? strtoull(idp + 5, NULL, 10) : (uint64_t)-1;
        int src = -1;
        pthread_mutex_lock(&pending_mtx);
        for (int pi = 0; pi < pending_count; pi++) {
            int idx = (pending_head + pi) % PENDING_SUB_MAX;
            if (pending_subs[idx].id == resp_id) { src = pending_subs[idx].is_gpu; break; }
        }
        pthread_mutex_unlock(&pending_mtx);
        int is_stale = strstr(line, "\"21\"") || strstr(line, ",21,") ||
                       strstr(line, "[21,")  || strstr(line, "stale") ||
                       strstr(line, "job not found");
        pthread_mutex_lock(&stats_mtx);
        if (is_stale) {
            total_stale++;
            if (src == 1) gpu_stale++;    else if (src == 0) cpu_stale++;
            pthread_mutex_unlock(&stats_mtx);
            printf("[DagTech] Share stale (job expired) (%lu total stale)\n",
                   (unsigned long)total_stale);
        } else {
            total_rejected++;
            if (src == 1) gpu_rejected++; else if (src == 0) cpu_rejected++;
            pthread_mutex_unlock(&stats_mtx);
            printf("[DagTech] Share REJECTED: %s\n", line);
        }
    }
}

static void *dagtech_recv_thread(void *arg) {
    (void)arg;
    char buf[8192];
    char linebuf[16384] = {0};
    int linelen = 0;

    while (running) {
        ssize_t n = recv(sockfd, buf, sizeof(buf) - 1, 0);
        if (n <= 0) {
            if (running) printf("[DagTech] Pool connection lost\n");
            running = 0;
            break;
        }
        buf[n] = 0;
        for (int i = 0; i < n; i++) {
            if (buf[i] == '\n') {
                linebuf[linelen] = 0;
                if (linelen > 0) dagtech_parse_stratum(linebuf);
                linelen = 0;
            } else if (linelen < (int)sizeof(linebuf) - 1) {
                linebuf[linelen++] = buf[i];
            }
        }
    }
    return NULL;
}

/* =========================================================================
 * Block Header Construction
 * ========================================================================= */
static int dagtech_make_header(const DagTechJob *j, uint32_t nonce, uint8_t header[80]) {
    if (strlen(j->version) != 8 || strlen(j->prevhash) < 64 ||
        strlen(j->ntime) != 8 || strlen(j->bits) != 8 ||
        strlen(j->extranonce1) != 8) return -1;

    uint8_t version[4], prevhash[32], ntime_b[4], bits_b[4];
    uint8_t en1[4], en2[4], en_combined[8], merkle[32];

    hex_to_bytes(j->version,    version,  4);
    hex_to_bytes(j->prevhash,   prevhash, 32);
    hex_to_bytes(j->ntime,      ntime_b,  4);
    hex_to_bytes(j->bits,       bits_b,   4);
    hex_to_bytes(j->extranonce1, en1,     4);
    memset(en2, 0, 4);

    memcpy(en_combined, en1, 4);
    memcpy(en_combined + 4, en2, 4);
    sha256d(en_combined, 8, merkle);

    memcpy(header,      version,  4);
    memcpy(header + 4,  prevhash, 32);
    memcpy(header + 36, merkle,   32);
    memcpy(header + 68, ntime_b,  4);
    memcpy(header + 72, bits_b,   4);
    header[76] = nonce & 0xff;
    header[77] = (nonce >> 8) & 0xff;
    header[78] = (nonce >> 16) & 0xff;
    header[79] = (nonce >> 24) & 0xff;

    return 0;
}

/* Rate limiter: max ~5 share submissions per second */
static uint64_t last_submit_ms = 0;
static pthread_mutex_t submit_rate_mtx = PTHREAD_MUTEX_INITIALIZER;
#define SUBMIT_MIN_INTERVAL_MS 200

static uint64_t dagtech_now_ms(void) {
#ifdef _WIN32
    LARGE_INTEGER freq, count;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&count);
    return (uint64_t)(count.QuadPart * 1000 / freq.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
#endif
}

static void dagtech_submit_share(const DagTechJob *j, uint32_t nonce, int is_gpu) {
    /* Throttle: skip if we submitted too recently */
    uint64_t now_ms = dagtech_now_ms();
    pthread_mutex_lock(&submit_rate_mtx);
    uint64_t elapsed_ms = now_ms - last_submit_ms;
    if (elapsed_ms < SUBMIT_MIN_INTERVAL_MS) {
        pthread_mutex_unlock(&submit_rate_mtx);
        return;
    }
    last_submit_ms = now_ms;
    pthread_mutex_unlock(&submit_rate_mtx);

    char nonce_hex[16];
    uint8_t nb[4];
    nb[0] = nonce & 0xff;
    nb[1] = (nonce >> 8) & 0xff;
    nb[2] = (nonce >> 16) & 0xff;
    nb[3] = (nonce >> 24) & 0xff;
    bytes_to_hex(nb, 4, nonce_hex);

    /* Capture and increment submission id before sending */
    pthread_mutex_lock(&stats_mtx);
    uint64_t sub_id = 1000 + total_submitted;
    total_submitted++;
    if (is_gpu) gpu_submitted++; else cpu_submitted++;
    pthread_mutex_unlock(&stats_mtx);

    /* Record pending so the pool response can be attributed to the right source */
    pthread_mutex_lock(&pending_mtx);
    int slot = (pending_head + pending_count) % PENDING_SUB_MAX;
    pending_subs[slot].id     = sub_id;
    pending_subs[slot].is_gpu = is_gpu;
    if (pending_count < PENDING_SUB_MAX) pending_count++;
    else pending_head = (pending_head + 1) % PENDING_SUB_MAX;
    pthread_mutex_unlock(&pending_mtx);

    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"id\":%lu,\"method\":\"mining.submit\",\"params\":[\"%s\",\"%s\",\"00000000\",\"%s\",\"%s\"]}",
        (unsigned long)sub_id, wallet, j->job_id, j->ntime, nonce_hex);
    dagtech_send(buf);
}

/* External alias used by GPU thread (avoids forward-declaration complexity) */
void dagtech_submit_share_ext(const DagTechJob *j, uint32_t nonce) {
    dagtech_submit_share(j, nonce, 1);  /* GPU */
}

static int dagtech_check_target(const uint8_t *hash, double difficulty) {
    uint64_t hash_top64 = ((uint64_t)hash[31] << 56) | ((uint64_t)hash[30] << 48) |
                          ((uint64_t)hash[29] << 40) | ((uint64_t)hash[28] << 32) |
                          ((uint64_t)hash[27] << 24) | ((uint64_t)hash[26] << 16) |
                          ((uint64_t)hash[25] <<  8) |  (uint64_t)hash[24];
    double threshold_d = (double)0x0000FFFF00000000ULL / difficulty;
    uint64_t threshold64 = (threshold_d >= 18446744073709551615.0) ?
                            0xFFFFFFFFFFFFFFFFULL : (uint64_t)threshold_d;
    return hash_top64 <= threshold64;
}

/* =========================================================================
 * CPU Mining Thread - DagTech Worker
 * CPU uses nonce range 0x00000000 - 0x7FFFFFFF
 * ========================================================================= */
static void *dagtech_mine_thread(void *arg) {
    int tid = *(int *)arg;
    /* Distribute CPU workers across the lower half of nonce space */
    uint32_t nonce = (uint32_t)tid * (0x7FFFFFFFu / (num_threads > 0 ? num_threads : 1));
    uint64_t local_hashes = 0;

    uint32_t *V = (uint32_t *)malloc(SCRYPT_N * 128);
    if (!V) {
        fprintf(stderr, "[DagTech] FATAL: Worker %d out of memory\n", tid);
        return NULL;
    }

    printf("[DagTech] CPU Worker %d started (nonce range 0x%08x)\n", tid, nonce);

    while (running) {
        DagTechJob j;
        pthread_mutex_lock(&job_mtx);
        j = current_job;
        pthread_mutex_unlock(&job_mtx);

        if (!j.valid) { usleep(100000); continue; }

        uint64_t job_seq = j.seq;

        long long t0 = dagtech_tick_ms();
        for (int batch = 0; batch < 64 && running; batch++) {
            /* Stay in CPU nonce range */
            nonce &= 0x7FFFFFFFu;

            uint8_t header[80];
            if (dagtech_make_header(&j, nonce, header) < 0) break;

            uint8_t hash[32];
            dagtech_hash(header, hash, V);
            local_hashes++;

            if (dagtech_check_target(hash, j.difficulty)) {
                printf("[DagTech] ** SHARE FOUND ** CPU Worker %d, nonce=0x%08x\n", tid, nonce);
                dagtech_submit_share(&j, nonce, 0);  /* CPU */
            }

            nonce++;
            nonce &= 0x7FFFFFFFu;

            /* Check for new job */
            pthread_mutex_lock(&job_mtx);
            if (current_job.seq != job_seq) {
                pthread_mutex_unlock(&job_mtx);
                break;
            }
            pthread_mutex_unlock(&job_mtx);
        }

        pthread_mutex_lock(&cpu_stats_mtx);
        cpu_hashes_session += local_hashes;
        pthread_mutex_unlock(&cpu_stats_mtx);

        pthread_mutex_lock(&stats_mtx);
        total_hashes += local_hashes;
        pthread_mutex_unlock(&stats_mtx);
        local_hashes = 0;

        /* CPU throttle: sleep proportional to batch time.
         * Sleeps in 100ms chunks so the thread can still respond quickly
         * to new jobs even when the correct sleep duration is many seconds.
         * The old 2000ms hard cap broke throttling on slower machines where
         * a 64-hash batch takes longer than 2s. */
        if (cpu_limit < 100) {
            long long elapsed = dagtech_tick_ms() - t0;
            if (elapsed > 0) {
                long long sleep_ms = elapsed * (100 - cpu_limit) / cpu_limit;
                long long slept = 0;
                while (slept < sleep_ms && running) {
                    long long chunk = sleep_ms - slept;
                    if (chunk > 100) chunk = 100;
                    usleep((unsigned int)(chunk * 1000));
                    slept += chunk;
                    /* Stop sleeping early if a new job arrived */
                    pthread_mutex_lock(&job_mtx);
                    int job_changed = (current_job.seq != job_seq);
                    pthread_mutex_unlock(&job_mtx);
                    if (job_changed) break;
                }
            }
        }
    }
    free(V);
    return NULL;
}

/* =========================================================================
 * Built-in Metrics Server (for Dashboard)
 * ========================================================================= */
static void *dagtech_metrics_thread(void *arg) {
    (void)arg;

    #ifdef _WIN32
    SOCKET srv = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    #else
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    #endif
    if (srv < 0) {
        fprintf(stderr, "[DagTech] Metrics server failed to create socket\n");
        return NULL;
    }

    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, (char *)&opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(metrics_port);

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[DagTech] Metrics bind failed on port %d\n", metrics_port);
        close(srv);
        return NULL;
    }
    listen(srv, 5);
    printf("[DagTech] Metrics server on http://127.0.0.1:%d/metrics\n", metrics_port);

    while (keep_alive) {
        struct sockaddr_in client;
        #ifdef _WIN32
        int clen = sizeof(client);
        SOCKET cfd = accept(srv, (struct sockaddr *)&client, &clen);
        #else
        socklen_t clen = sizeof(client);
        int cfd = accept(srv, (struct sockaddr *)&client, &clen);
        #endif
        if (cfd < 0) continue;

        /* Read request and check path */
        char reqbuf[1024] = {0};
        recv(cfd, reqbuf, sizeof(reqbuf) - 1, 0);

        /* Serve dashboard HTML for any non-metrics GET */
        if (dashboard_dir[0] && strstr(reqbuf, "GET /metrics") == NULL
                              && strstr(reqbuf, "GET /") != NULL) {
            char html_path[600];
            snprintf(html_path, sizeof(html_path), "%s\\index.html", dashboard_dir);
            FILE *f = fopen(html_path, "rb");
            if (f) {
                fseek(f, 0, SEEK_END);
                long fsize = ftell(f);
                fseek(f, 0, SEEK_SET);
                char *html = (char *)malloc(fsize + 1);
                if (html) {
                    fread(html, 1, fsize, f);
                    char hdr[256];
                    snprintf(hdr, sizeof(hdr),
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                        "Connection: close\r\nContent-Length: %ld\r\n\r\n", fsize);
                    send(cfd, hdr, (int)strlen(hdr), 0);
                    send(cfd, html, (int)fsize, 0);
                    free(html);
                }
                fclose(f);
            } else {
                const char *nf = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                send(cfd, nf, (int)strlen(nf), 0);
            }
            close(cfd);
            continue;
        }

        /* Build per-GPU hashrate array string (no lock — same benign race as gpu_hashrate) */
        char gpu_hr_arr[256] = "[";
#ifdef DAGTECH_GPU
        for (int _gi = 0; _gi < g_num_gpus; _gi++) {
            char _tmp[32];
            snprintf(_tmp, sizeof(_tmp), "%s%.2f", _gi ? "," : "", g_gpus[_gi].hashrate);
            strncat(gpu_hr_arr, _tmp, sizeof(gpu_hr_arr) - strlen(gpu_hr_arr) - 2);
        }
#endif
        if (g_num_gpus == 0) strncat(gpu_hr_arr, "0.0", sizeof(gpu_hr_arr) - strlen(gpu_hr_arr) - 2);
        strncat(gpu_hr_arr, "]", sizeof(gpu_hr_arr) - strlen(gpu_hr_arr) - 1);

        /* Build JSON metrics response */
        pthread_mutex_lock(&stats_mtx);
        time_t uptime = time(NULL) - start_time;
        char json[3072];
        snprintf(json, sizeof(json),
            "{"
            "\"version\":\"%s\","
            "\"pool\":\"%s:%d\","
            "\"wallet\":\"%.10s...%s\","
            "\"wallet_full\":\"%s\","
            "\"worker\":\"%s\","
            "\"threads\":%d,"
            "\"hashrate\":%.2f,"
            "\"cpu_hashrate\":%.2f,"
            "\"gpu_hashrate\":%.2f,"
            "\"total_hashes\":%" DT_PRIu64 ","
            "\"submitted\":%" DT_PRIu64 ","
            "\"accepted\":%" DT_PRIu64 ","
            "\"rejected\":%" DT_PRIu64 ","
            "\"stale\":%" DT_PRIu64 ","
            "\"cpu_submitted\":%" DT_PRIu64 ","
            "\"gpu_submitted\":%" DT_PRIu64 ","
            "\"cpu_accepted\":%" DT_PRIu64 ","
            "\"gpu_accepted\":%" DT_PRIu64 ","
            "\"cpu_rejected\":%" DT_PRIu64 ","
            "\"gpu_rejected\":%" DT_PRIu64 ","
            "\"cpu_stale\":%" DT_PRIu64 ","
            "\"gpu_stale\":%" DT_PRIu64 ","
            "\"difficulty\":%.8f,"
            "\"uptime\":%ld,"
            "\"job_id\":\"%s\","
            "\"gpu_enabled\":%d,"
            "\"gpu_count\":%d,"
            "\"gpu_hashrates\":%s"
            "}",
            DAGTECH_VERSION, pool_host, pool_port,
            wallet, wallet + strlen(wallet) - 4,
            wallet,
            worker_name,
            num_threads, current_hashrate, cpu_hashrate, gpu_hashrate,
            (unsigned long long)total_hashes,
            (unsigned long long)total_submitted,
            (unsigned long long)total_accepted,
            (unsigned long long)total_rejected,
            (unsigned long long)total_stale,
            (unsigned long long)cpu_submitted,
            (unsigned long long)gpu_submitted,
            (unsigned long long)cpu_accepted,
            (unsigned long long)gpu_accepted,
            (unsigned long long)cpu_rejected,
            (unsigned long long)gpu_rejected,
            (unsigned long long)cpu_stale,
            (unsigned long long)gpu_stale,
            current_difficulty, (long)uptime,
            current_job.job_id,
            (gpu_enabled == 1) ? 1 : 0,
            g_num_gpus,
            gpu_hr_arr);
        pthread_mutex_unlock(&stats_mtx);

        char response[4096];
        snprintf(response, sizeof(response),
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/json\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "Connection: close\r\n"
            "Content-Length: %d\r\n"
            "\r\n%s",
            (int)strlen(json), json);

        send(cfd, response, (int)strlen(response), 0);
        close(cfd);
    }

    close(srv);
    return NULL;
}

/* =========================================================================
 * Signal Handler
 * ========================================================================= */
static void dagtech_signal(int sig) {
    (void)sig;
    printf("\n[DagTech] Shutting down...\n");
    keep_alive = 0;
    running = 0;
}

/* =========================================================================
 * Usage / Help
 * ========================================================================= */
static void dagtech_usage(void) {
    printf("\n");
    printf("  %s\n", DAGTECH_BANNER);
    printf("  %s\n\n", DAGTECH_AUTHOR);
    printf("  Usage: dagtech-gpu-miner [options]\n\n");
    printf("  Options:\n");
    printf("    --wallet <addr>        Your wallet address (REQUIRED)\n");
    printf("    --pool <host>          Pool hostname (default: %s)\n", DAGTECH_DEFAULT_POOL);
    printf("    --port <n>             Pool port (default: %d)\n", DAGTECH_DEFAULT_PORT);
    printf("    --threads <n>          Number of CPU mining threads (default: auto)\n");
    printf("    --worker <name>        Worker name (default: dagtech)\n");
    printf("    --password <pw>        Pool password (default: x)\n");
    printf("    --cpu-limit <n>        CPU usage limit percent per thread (1-100, default: 100)\n");
    printf("    --low-priority         Run at lowest CPU priority\n");
    printf("    --metrics-port <n>     Metrics HTTP port (default: %d)\n", metrics_port);
    printf("    --gpu                  Force enable GPU mining\n");
    printf("    --no-gpu               Disable GPU mining\n");
    printf("    --gpu-intensity <n|list>  GPU intensity per card: 80, 80,60 (default: 80)\n");
    printf("    --gpu-throttle <n>     GPU duty-cycle limit percent (1-100, default: 100)\n");
    printf("    --gpu-platform <n>     OpenCL platform index (default: 0)\n");
    printf("    --gpu-device <n|n,m|all>  OpenCL device(s): 0, 0,1, all (default: 0)\n");
    printf("    --config <path>        Load config from file\n");
    printf("    --save-config          Save current settings to config file and exit\n");
    printf("    --help                 Show this help\n");
    printf("\n");
    printf("  Config file keys: WALLET, POOL, PORT, THREADS, WORKER, CPU_LIMIT,\n");
    printf("    GPU_ENABLED, GPU_INTENSITY, GPU_THROTTLE, GPU_PLATFORM, GPU_DEVICE\n");
    printf("\n");
}

/* =========================================================================
 * Config Save / Load
 * ========================================================================= */
static const char *dagtech_default_config_path(void) {
    static char path[512];
    if (path[0]) return path;

    const char *home = NULL;
#ifdef _WIN32
    home = getenv("USERPROFILE");
    if (!home) home = getenv("HOMEDRIVE");
#else
    home = getenv("HOME");
#endif
    if (home)
        snprintf(path, sizeof(path), "%s/dagtech-gpu-miner/config.env", home);
    else
        snprintf(path, sizeof(path), "dagtech-gpu-miner/config.env");

    return path;
}

static void dagtech_mkdir_parents(const char *filepath) {
    char tmp[512];
    strncpy(tmp, filepath, sizeof(tmp) - 1);
    tmp[sizeof(tmp) - 1] = '\0';

    char *sep = strrchr(tmp, '/');
#ifdef _WIN32
    char *sep2 = strrchr(tmp, '\\');
    if (sep2 > sep) sep = sep2;
#endif
    if (!sep) return;
    *sep = '\0';

#ifdef _WIN32
    CreateDirectoryA(tmp, NULL);
#else
    mkdir(tmp, 0700);
#endif
}

static void dagtech_load_config(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        size_t l = strlen(line);
        while (l > 0 && (line[l-1] == '\n' || line[l-1] == '\r')) line[--l] = '\0';
        if (l == 0 || line[0] == '#') continue;

        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        const char *key = line;
        const char *val = eq + 1;

        if      (strcmp(key, "WALLET")       == 0) strncpy(wallet,       val, sizeof(wallet)       - 1);
        else if (strcmp(key, "POOL")         == 0) strncpy(pool_host,    val, sizeof(pool_host)    - 1);
        else if (strcmp(key, "PORT")         == 0) pool_port     = atoi(val);
        else if (strcmp(key, "THREADS")      == 0) num_threads   = atoi(val);
        else if (strcmp(key, "WORKER")       == 0) strncpy(worker_name,  val, sizeof(worker_name)  - 1);
        else if (strcmp(key, "PASSWORD")     == 0) strncpy(password,     val, sizeof(password)     - 1);
        else if (strcmp(key, "LOW_PRIORITY") == 0) cpu_priority  = atoi(val);
        else if (strcmp(key, "CPU_LIMIT")    == 0) { cpu_limit = atoi(val); if (cpu_limit < 1) cpu_limit = 1; if (cpu_limit > 100) cpu_limit = 100; }
        else if (strcmp(key, "GPU_THROTTLE") == 0) { gpu_throttle = atoi(val); if (gpu_throttle < 1) gpu_throttle = 1; if (gpu_throttle > 100) gpu_throttle = 100; }
        else if (strcmp(key, "METRICS_PORT") == 0) metrics_port  = atoi(val);
        else if (strcmp(key, "DASHBOARD_DIR")== 0) strncpy(dashboard_dir,val, sizeof(dashboard_dir)- 1);
        else if (strcmp(key, "GPU_ENABLED")  == 0) gpu_enabled   = atoi(val);
        else if (strcmp(key, "GPU_INTENSITY")== 0) {
            if (strchr(val, ',')) {
                gpu_intensity_count = 0;
                char tmp[64]; strncpy(tmp, val, sizeof(tmp)-1); tmp[sizeof(tmp)-1] = '\0';
                char *tok = strtok(tmp, ",");
                while (tok && gpu_intensity_count < MAX_GPUS) {
                    int v = atoi(tok); if (v < 0) v = 0; if (v > 100) v = 100;
                    gpu_intensity_list[gpu_intensity_count++] = v; tok = strtok(NULL, ",");
                }
                if (gpu_intensity_count > 0) gpu_intensity = gpu_intensity_list[0];
            } else {
                gpu_intensity = atoi(val);
                if (gpu_intensity < 0) gpu_intensity = 0;
                if (gpu_intensity > 100) gpu_intensity = 100;
                gpu_intensity_count = 0;
            }
        }
        else if (strcmp(key, "GPU_PLATFORM") == 0) gpu_platform  = atoi(val);
        else if (strcmp(key, "GPU_DEVICE")   == 0) {
            if (strcmp(val, "all") == 0) {
                gpu_use_all = 1;
            } else if (strchr(val, ',')) {
                gpu_device_count = 0; gpu_use_all = 0;
                char tmp[64]; strncpy(tmp, val, sizeof(tmp)-1); tmp[sizeof(tmp)-1] = '\0';
                char *tok = strtok(tmp, ",");
                while (tok && gpu_device_count < MAX_GPUS) {
                    gpu_device_list[gpu_device_count++] = atoi(tok);
                    tok = strtok(NULL, ",");
                }
            } else {
                gpu_device = atoi(val); gpu_device_count = 0; gpu_use_all = 0;
            }
        }
    }
    fclose(f);
    printf("[DagTech] Config loaded from %s\n", path);
}

static int dagtech_save_config(const char *path) {
    dagtech_mkdir_parents(path);

    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "[DagTech] ERROR: Cannot write config to %s: %s\n", path, strerror(errno));
        return -1;
    }

    fprintf(f, "# DagTech GPU Miner configuration\n");
    fprintf(f, "# Generated by dagtech-gpu-miner --save-config\n");
    fprintf(f, "# Edit manually or re-run with --save-config to update.\n\n");

    fprintf(f, "WALLET=%s\n",        wallet);
    fprintf(f, "POOL=%s\n",          pool_host);
    fprintf(f, "PORT=%d\n",          pool_port);
    fprintf(f, "THREADS=%d\n",       num_threads);
    fprintf(f, "WORKER=%s\n",        worker_name);
    fprintf(f, "PASSWORD=%s\n",      password);
    fprintf(f, "LOW_PRIORITY=%d\n",  cpu_priority);
    fprintf(f, "CPU_LIMIT=%d\n",     cpu_limit);
    fprintf(f, "GPU_THROTTLE=%d\n",  gpu_throttle);
    fprintf(f, "METRICS_PORT=%d\n",  metrics_port);
    fprintf(f, "GPU_ENABLED=%d\n",   gpu_enabled);
    if (gpu_intensity_count > 0) {
        fprintf(f, "GPU_INTENSITY=");
        for (int i = 0; i < gpu_intensity_count; i++)
            fprintf(f, "%s%d", i ? "," : "", gpu_intensity_list[i]);
        fprintf(f, "\n");
    } else {
        fprintf(f, "GPU_INTENSITY=%d\n", gpu_intensity);
    }
    fprintf(f, "GPU_PLATFORM=%d\n",  gpu_platform);
    if (gpu_use_all) {
        fprintf(f, "GPU_DEVICE=all\n");
    } else if (gpu_device_count > 0) {
        fprintf(f, "GPU_DEVICE=");
        for (int i = 0; i < gpu_device_count; i++)
            fprintf(f, "%s%d", i ? "," : "", gpu_device_list[i]);
        fprintf(f, "\n");
    } else {
        fprintf(f, "GPU_DEVICE=%d\n", gpu_device);
    }
    if (dashboard_dir[0])
        fprintf(f, "DASHBOARD_DIR=%s\n", dashboard_dir);

    fclose(f);
    printf("[DagTech] Config saved to %s\n", path);
    return 0;
}

/* =========================================================================
 * Auto-detect CPU thread count
 * ========================================================================= */
static int dagtech_detect_threads(void) {
    int cores = 1;
    #ifdef _WIN32
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    cores = si.dwNumberOfProcessors;
    #elif defined(__linux__)
    cores = sysconf(_SC_NPROCESSORS_ONLN);
    #elif defined(__APPLE__)
    size_t len = sizeof(cores);
    sysctlbyname("hw.logicalcpu", &cores, &len, NULL, 0);
    #endif
    int threads = cores / 2;
    if (threads < 1) threads = 1;
    return threads;
}

/* =========================================================================
 * Main Entry Point - DagTech GPU Miner
 * ========================================================================= */
int main(int argc, char **argv) {
    /* Flush log lines immediately — prevents output appearing in bursts when
       stdout is not a terminal (e.g. running as a background service). */
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);

    signal(SIGINT, dagtech_signal);
    signal(SIGTERM, dagtech_signal);

    /* ---- Pass 1: look for --config <path> before loading defaults ---- */
    const char *config_path = dagtech_default_config_path();
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            config_path = argv[++i];
            break;
        }
    }

    /* ---- Load config file (CLI args below will override) ---- */
    dagtech_load_config(config_path);

    /* ---- Pass 2: full argument parsing ---- */
    int do_save_config = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--wallet") == 0 && i + 1 < argc)
            strncpy(wallet, argv[++i], sizeof(wallet) - 1);
        else if (strcmp(argv[i], "--pool") == 0 && i + 1 < argc)
            strncpy(pool_host, argv[++i], sizeof(pool_host) - 1);
        else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc)
            pool_port = atoi(argv[++i]);
        else if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc)
            num_threads = atoi(argv[++i]);
        else if (strcmp(argv[i], "--worker") == 0 && i + 1 < argc)
            strncpy(worker_name, argv[++i], sizeof(worker_name) - 1);
        else if (strcmp(argv[i], "--password") == 0 && i + 1 < argc)
            strncpy(password, argv[++i], sizeof(password) - 1);
        else if (strcmp(argv[i], "--cpu-limit") == 0 && i + 1 < argc) {
            cpu_limit = atoi(argv[++i]);
            if (cpu_limit < 1)   cpu_limit = 1;
            if (cpu_limit > 100) cpu_limit = 100;
        }
        else if (strcmp(argv[i], "--low-priority") == 0)
            cpu_priority = 1;
        else if (strcmp(argv[i], "--metrics-port") == 0 && i + 1 < argc)
            metrics_port = atoi(argv[++i]);
        else if (strcmp(argv[i], "--dashboard-dir") == 0 && i + 1 < argc)
            strncpy(dashboard_dir, argv[++i], sizeof(dashboard_dir) - 1);
        else if (strcmp(argv[i], "--gpu") == 0)
            gpu_enabled = 1;
        else if (strcmp(argv[i], "--no-gpu") == 0)
            gpu_enabled = 0;
        else if (strcmp(argv[i], "--gpu-intensity") == 0 && i + 1 < argc) {
            const char *val = argv[++i];
            if (strchr(val, ',')) {
                gpu_intensity_count = 0;
                char tmp[64]; strncpy(tmp, val, sizeof(tmp)-1); tmp[sizeof(tmp)-1] = '\0';
                char *tok = strtok(tmp, ",");
                while (tok && gpu_intensity_count < MAX_GPUS) {
                    int v = atoi(tok); if (v < 0) v = 0; if (v > 100) v = 100;
                    gpu_intensity_list[gpu_intensity_count++] = v; tok = strtok(NULL, ",");
                }
                if (gpu_intensity_count > 0) gpu_intensity = gpu_intensity_list[0];
            } else {
                gpu_intensity = atoi(val);
                if (gpu_intensity < 0)   gpu_intensity = 0;
                if (gpu_intensity > 100) gpu_intensity = 100;
                gpu_intensity_count = 0;
            }
        }
        else if (strcmp(argv[i], "--gpu-throttle") == 0 && i + 1 < argc) {
            gpu_throttle = atoi(argv[++i]);
            if (gpu_throttle < 1)   gpu_throttle = 1;
            if (gpu_throttle > 100) gpu_throttle = 100;
        }
        else if (strcmp(argv[i], "--gpu-platform") == 0 && i + 1 < argc)
            gpu_platform = atoi(argv[++i]);
        else if (strcmp(argv[i], "--gpu-device") == 0 && i + 1 < argc) {
            const char *val = argv[++i];
            if (strcmp(val, "all") == 0) {
                gpu_use_all = 1;
            } else if (strchr(val, ',')) {
                gpu_device_count = 0; gpu_use_all = 0;
                char tmp[64]; strncpy(tmp, val, sizeof(tmp)-1); tmp[sizeof(tmp)-1] = '\0';
                char *tok = strtok(tmp, ",");
                while (tok && gpu_device_count < MAX_GPUS) {
                    gpu_device_list[gpu_device_count++] = atoi(tok);
                    tok = strtok(NULL, ",");
                }
            } else {
                gpu_device = atoi(val); gpu_device_count = 0; gpu_use_all = 0;
            }
        }
        else if (strcmp(argv[i], "--config") == 0 && i + 1 < argc)
            i++;  /* already handled in pass 1 */
        else if (strcmp(argv[i], "--save-config") == 0)
            do_save_config = 1;
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            dagtech_usage();
            return 0;
        }
    }

    /* ---- Handle --save-config ---- */
    if (do_save_config) {
        printf("\n");
        printf("  ============================================\n");
        printf("  %s\n", DAGTECH_BANNER);
        printf("  ============================================\n\n");
        if (wallet[0] == 0) {
            fprintf(stderr, "[DagTech] ERROR: --wallet is required when saving config.\n");
            return 1;
        }
        return dagtech_save_config(config_path) == 0 ? 0 : 1;
    }

    /* Banner */
    printf("\n");
    printf("  ============================================\n");
    printf("  %s\n", DAGTECH_BANNER);
    printf("  %s\n", DAGTECH_AUTHOR);
    printf("  ============================================\n\n");

    /* Validate wallet */
    if (wallet[0] == 0) {
        fprintf(stderr, "[DagTech] ERROR: Wallet address is required!\n");
        dagtech_usage();
        return 1;
    }
    if (strncmp(wallet, "0x", 2) != 0 || strlen(wallet) != 42) {
        fprintf(stderr, "[DagTech] WARNING: Wallet format looks unusual (expected 0x + 40 hex chars)\n");
    }

    /* Auto-detect threads if not specified */
    if (num_threads <= 0)
        num_threads = dagtech_detect_threads();

    /* Set low priority if requested */
    if (cpu_priority) {
        #ifdef _WIN32
        SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS);
        #else
        nice(19);
        #endif
        printf("[DagTech] Running at LOW CPU priority\n");
    }

    printf("[DagTech] Wallet:  %s\n", wallet);
    printf("[DagTech] Pool:    %s:%d\n", pool_host, pool_port);
    printf("[DagTech] Threads: %d (CPU)\n", num_threads);
    printf("[DagTech] Worker:  %s\n", worker_name);

#ifdef DAGTECH_GPU
    /* List and initialize GPU */
    gpu_list_devices();

    int use_gpu = 0;
    if (gpu_enabled == 1) {
        use_gpu = 1;
    } else if (gpu_enabled == 0) {
        use_gpu = 0;
        printf("[DagTech GPU] GPU disabled by config/flag.\n");
    } else {
        /* auto: try to init GPU */
        use_gpu = 1;
        printf("[DagTech GPU] Auto-detecting GPU (use --no-gpu to disable)...\n");
    }

    if (use_gpu) {
        if (gpu_init_all(argv[0]) == 0) {
            gpu_enabled = 1;
            printf("[DagTech GPU] Intensity: %d | Platform: %d | GPUs active: %d\n",
                   gpu_intensity, gpu_platform, g_num_gpus);
        } else {
            fprintf(stderr, "[DagTech GPU] GPU init failed - running CPU only.\n");
            gpu_enabled = 0;
        }
    }
#else
    printf("[DagTech] Built without GPU support (no -DDAGTECH_GPU).\n");
    gpu_enabled = 0;
#endif

    printf("\n");

    start_time = time(NULL);

    /* Initialise Winsock before any socket call (metrics thread or pool connect) */
    #ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2,2), &wsa);
    #endif

    /* Start metrics server thread */
    pthread_t metrics_tid;
    pthread_create(&metrics_tid, NULL, dagtech_metrics_thread, NULL);

    /* Reconnection loop */
    while (keep_alive) {
        running = 1;
        current_job.valid = 0;
        cpu_hashes_session = 0;
        gpu_hashes_session = 0;
#ifdef DAGTECH_GPU
        for (int _gi = 0; _gi < g_num_gpus; _gi++) {
            g_gpus[_gi].hashes_session = 0;
            g_gpus[_gi].hashrate       = 0.0;
        }
#endif

        printf("[DagTech] Connecting to pool %s:%d...\n", pool_host, pool_port);
        if (dagtech_connect_pool() < 0) {
            fprintf(stderr, "[DagTech] Cannot connect - retrying in 10s\n");
            sleep(10);
            continue;
        }
        printf("[DagTech] Connected!\n");
        dagtech_subscribe_authorize();

        /* Start receiver thread */
        pthread_t recv_tid;
        pthread_create(&recv_tid, NULL, dagtech_recv_thread, NULL);

        /* Wait for first job */
        printf("[DagTech] Waiting for work from pool...\n");
        for (int i = 0; i < 100 && running && !current_job.valid; i++)
            usleep(100000);

        if (!current_job.valid) {
            fprintf(stderr, "[DagTech] No job received - will retry in 10s\n");
            running = 0;
            pthread_join(recv_tid, NULL);
            close(sockfd);
            if (keep_alive) sleep(10);
            continue;
        }

        /* Start CPU mining threads */
        pthread_t *threads = malloc(num_threads * sizeof(pthread_t));
        int *tids = malloc(num_threads * sizeof(int));
        for (int i = 0; i < num_threads; i++) {
            tids[i] = i;
            pthread_create(&threads[i], NULL, dagtech_mine_thread, &tids[i]);
        }

        /* Start GPU threads — one per active device */
        pthread_t gpu_tids[MAX_GPUS];
        int gpu_threads_started = 0;
#ifdef DAGTECH_GPU
        if (gpu_enabled == 1) {
            for (int gi = 0; gi < g_num_gpus; gi++) {
                if (g_gpus[gi].ready) {
                    pthread_create(&gpu_tids[gpu_threads_started], NULL,
                                   dagtech_gpu_thread, &g_gpus[gi]);
                    gpu_threads_started++;
                }
            }
        }
#endif

        {
            char _gs[32] = "off";
#ifdef DAGTECH_GPU
            if (gpu_enabled == 1)
                snprintf(_gs, sizeof(_gs), "%d active", g_num_gpus);
#endif
            printf("[DagTech] Mining started! CPU workers: %d | GPU: %s\n\n",
                   num_threads, _gs);
        }

        /* Statistics reporting loop */
        time_t last_report = time(NULL);
        uint64_t last_total  = 0;
        uint64_t last_cpu_h  = 0;
        uint64_t last_gpu_h  = 0;
#ifdef DAGTECH_GPU
        uint64_t last_gpu_ind[MAX_GPUS];
        memset(last_gpu_ind, 0, sizeof(last_gpu_ind));
#endif
        while (running) {
            sleep(10);
            time_t now = time(NULL);
            double elapsed = difftime(now, last_report);
            if (elapsed >= 10) {
                pthread_mutex_lock(&stats_mtx);
                uint64_t h = total_hashes;
                pthread_mutex_unlock(&stats_mtx);

                pthread_mutex_lock(&cpu_stats_mtx);
                uint64_t ch = cpu_hashes_session;
                pthread_mutex_unlock(&cpu_stats_mtx);

                pthread_mutex_lock(&gpu_stats_mtx);
                uint64_t gh = gpu_hashes_session;
#ifdef DAGTECH_GPU
                uint64_t _ghi[MAX_GPUS];
                for (int _gi = 0; _gi < g_num_gpus; _gi++)
                    _ghi[_gi] = g_gpus[_gi].hashes_session;
#endif
                pthread_mutex_unlock(&gpu_stats_mtx);

                current_hashrate = (h  - last_total) / elapsed;
                cpu_hashrate     = (ch - last_cpu_h) / elapsed;
                gpu_hashrate     = (gh - last_gpu_h) / elapsed;
#ifdef DAGTECH_GPU
                for (int _gi = 0; _gi < g_num_gpus; _gi++) {
                    g_gpus[_gi].hashrate = (_ghi[_gi] - last_gpu_ind[_gi]) / elapsed;
                    last_gpu_ind[_gi]    = _ghi[_gi];
                }
#endif

                time_t uptime = now - start_time;
                int up_h = (int)(uptime / 3600);
                int up_m = (int)((uptime % 3600) / 60);

                if (gpu_enabled == 1) {
#ifdef DAGTECH_GPU
                    if (g_num_gpus > 1) {
                        /* Per-GPU breakdown when multiple cards active */
                        char _gd[512] = "";
                        for (int _gi = 0; _gi < g_num_gpus; _gi++) {
                            char _t[48];
                            snprintf(_t, sizeof(_t), " | GPU[%d]: %.2f H/s",
                                     _gi, g_gpus[_gi].hashrate);
                            strncat(_gd, _t, sizeof(_gd) - strlen(_gd) - 1);
                        }
                        printf("[DagTech] %.2f H/s | CPU: %.2f H/s%s | "
                               "Shares: %lu/%lu/%lu/%lu (sub/acc/rej/stale) | Uptime: %dh%dm\n",
                               current_hashrate, cpu_hashrate, _gd,
                               (unsigned long)total_submitted,
                               (unsigned long)total_accepted,
                               (unsigned long)total_rejected,
                               (unsigned long)total_stale,
                               up_h, up_m);
                    } else
#endif
                    {
                    printf("[DagTech] %.2f H/s | CPU: %.2f H/s | GPU: %.2f H/s | "
                           "Shares: %lu/%lu/%lu/%lu (sub/acc/rej/stale) | Uptime: %dh%dm\n",
                           current_hashrate, cpu_hashrate, gpu_hashrate,
                           (unsigned long)total_submitted,
                           (unsigned long)total_accepted,
                           (unsigned long)total_rejected,
                           (unsigned long)total_stale,
                           up_h, up_m);
                    }
                } else {
                    printf("[DagTech] %.1f H/s | Shares: %lu/%lu/%lu/%lu (sub/acc/rej/stale) | Uptime: %dh%dm\n",
                           current_hashrate,
                           (unsigned long)total_submitted,
                           (unsigned long)total_accepted,
                           (unsigned long)total_rejected,
                           (unsigned long)total_stale,
                           up_h, up_m);
                }

                last_total = h;
                last_cpu_h = ch;
                last_gpu_h = gh;
                last_report = now;
            }
        }

        /* Clean up session */
        for (int i = 0; i < num_threads; i++)
            pthread_join(threads[i], NULL);
        for (int i = 0; i < gpu_threads_started; i++)
            pthread_join(gpu_tids[i], NULL);
        pthread_join(recv_tid, NULL);
        free(threads);
        free(tids);
        close(sockfd);

        if (keep_alive) {
            printf("[DagTech] Reconnecting in 10s...\n");
            sleep(10);
        }
    }

#ifdef DAGTECH_GPU
    if (gpu_enabled == 1)
        gpu_cleanup();
#endif

    #ifdef _WIN32
    WSACleanup();
    #endif

    printf("[DagTech] Shutdown complete. Total hashes: %" DT_PRIu64 "\n",
           (unsigned long long)total_hashes);
    return 0;
}
