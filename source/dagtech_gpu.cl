/*
 * DagTech GPU Kernel - OpenCL 1.2
 * Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
 * https://dagtech.network
 *
 * Exact port of the DagTech scrypt_1024_1_1_256 algorithm with proprietary
 * post-ROMix X[0] modification.  Every constant and operation matches
 * dagtech_miner.c so that CPU and GPU produce identical hashes for the
 * same nonce.
 *
 * Kernel entry point: dagtech_search
 *   header80  - 80-byte block header as 20 uint words (nonce at word 19)
 *   output    - [0] best nonce (atomic_min), [1] found count (atomic_inc)
 *   V         - global V array; each work-item gets its own 1024*32 uint slice
 *   target    - 32-bit difficulty target: (uint)(0xFFFFFFFFull / difficulty)
 *   nonce_base- nonce = nonce_base + get_global_id(0)
 */

/* Enable global-memory atomic operations (required by some drivers) */
#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics     : enable
#pragma OPENCL EXTENSION cl_khr_global_int32_extended_atomics : enable

/* =========================================================================
 * Helpers
 * ========================================================================= */
#define BSWAP(x) ((rotate((x),8u)&0x00FF00FFu)|(rotate((x),24u)&0xFF00FF00u))

/* =========================================================================
 * SHA-256 constants — identical to dagtech_sha256_k[64] in dagtech_sha256.h
 * ========================================================================= */
__constant uint SHA256_K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

/* SHA-256 IV — identical to dagtech_sha256_iv[8] in dagtech_miner.c */
#define SHA256_IV_0 0x6a09e667u
#define SHA256_IV_1 0xbb67ae85u
#define SHA256_IV_2 0x3c6ef372u
#define SHA256_IV_3 0xa54ff53au
#define SHA256_IV_4 0x510e527fu
#define SHA256_IV_5 0x9b05688cu
#define SHA256_IV_6 0x1f83d9abu
#define SHA256_IV_7 0x5be0cd19u

/* =========================================================================
 * PBKDF2 padding constants — exact same values as in dagtech_miner.c
 * ========================================================================= */

/* scrypt_keypad[12]: { 0x80000000,0,0,0,0,0,0,0,0,0,0,0x00000280 } */
#define KEYPAD_0  0x80000000u
/* [1..10] = 0 */
#define KEYPAD_11 0x00000280u

/* scrypt_innerpad[11]: { 0x80000000,0,0,0,0,0,0,0,0,0,0x000004a0 } */
#define INNERPAD_0  0x80000000u
/* [1..9] = 0 */
#define INNERPAD_10 0x000004a0u

/* scrypt_outerpad[8]: { 0x80000000,0,0,0,0,0,0,0x00000300 } */
#define OUTERPAD_0 0x80000000u
/* [1..6] = 0 */
#define OUTERPAD_7 0x00000300u

/* scrypt_finalblk[16]: { 0x00000001,0x80000000,0,0,0,0,0,0,0,0,0,0,0,0,0,0x00000620 } */
#define FINALBLK_0  0x00000001u
#define FINALBLK_1  0x80000000u
/* [2..14] = 0 */
#define FINALBLK_15 0x00000620u

/* =========================================================================
 * SHA-256 macros
 * ========================================================================= */
#define ROR32(x,n) (rotate((x), (uint)(32u-(n))))
#define CH(x,y,z)  (((x)&(y))^(~(x)&(z)))
#define MAJ(x,y,z) (((x)&(y))^((x)&(z))^((y)&(z)))
#define EP0(x)  (ROR32(x,2)  ^ ROR32(x,13) ^ ROR32(x,22))
#define EP1(x)  (ROR32(x,6)  ^ ROR32(x,11) ^ ROR32(x,25))
#define SIG0(x) (ROR32(x,7)  ^ ROR32(x,18) ^ ((x)>>3u))
#define SIG1(x) (ROR32(x,17) ^ ROR32(x,19) ^ ((x)>>10u))

/* =========================================================================
 * sha256_xform — port of dagtech_sha256_xform(state, block, swap)
 *
 * swap=0: W[i] = block[i]          (words already LE in register)
 * swap=1: W[i] = BSWAP(block[i])   (convert BE-stored words to LE)
 *
 * In OpenCL we always pass the 16 words as explicit parameters to keep
 * everything in private registers; the caller supplies them pre-swapped
 * or raw depending on the call site.
 * ========================================================================= */
static void sha256_xform(__private uint state[8],
                         uint w0,  uint w1,  uint w2,  uint w3,
                         uint w4,  uint w5,  uint w6,  uint w7,
                         uint w8,  uint w9,  uint w10, uint w11,
                         uint w12, uint w13, uint w14, uint w15)
{
    uint W[64];
    W[0]=w0;  W[1]=w1;  W[2]=w2;  W[3]=w3;
    W[4]=w4;  W[5]=w5;  W[6]=w6;  W[7]=w7;
    W[8]=w8;  W[9]=w9;  W[10]=w10;W[11]=w11;
    W[12]=w12;W[13]=w13;W[14]=w14;W[15]=w15;

    for (int i = 16; i < 64; i++)
        W[i] = SIG1(W[i-2]) + W[i-7] + SIG0(W[i-15]) + W[i-16];

    uint a=state[0], b=state[1], c=state[2], d=state[3];
    uint e=state[4], f=state[5], g=state[6], h=state[7];

    for (int i = 0; i < 64; i++) {
        uint t1 = h + EP1(e) + CH(e,f,g) + SHA256_K[i] + W[i];
        uint t2 = EP0(a) + MAJ(a,b,c);
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d;
    state[4]+=e; state[5]+=f; state[6]+=g; state[7]+=h;
}

/* =========================================================================
 * hmac80_init — port of dagtech_hmac80_init
 *
 * Inputs:
 *   key[20]  - 80-byte key as 20 uint words (LE, same as C)
 *   tstate   - IN: midstate (SHA256 of key[0..15]), OUT: new tstate
 *   ostate   - OUT: outer state
 * ========================================================================= */
static void hmac80_init(__private const uint key[20],
                        __private uint tstate[8],
                        __private uint ostate[8])
{
    uint ihash[8];

    /* Finish inner hash: process key[16..19] + keypad
       pad = { key[16], key[17], key[18], key[19],
               KEYPAD_0, 0,0,0,0,0,0,0,0,0,0, KEYPAD_11 }
       (memcpy(pad, key+16, 16) then memcpy(pad+4, scrypt_keypad, 48)) */
    sha256_xform(tstate,
        key[16], key[17], key[18], key[19],
        KEYPAD_0, 0u, 0u, 0u,
        0u, 0u, 0u, 0u,
        0u, 0u, 0u, KEYPAD_11);

    for (int i = 0; i < 8; i++) ihash[i] = tstate[i];

    /* ostate = SHA256_IV ^ (ihash ^ 0x5c5c5c5c) pad */
    ostate[0]=SHA256_IV_0; ostate[1]=SHA256_IV_1;
    ostate[2]=SHA256_IV_2; ostate[3]=SHA256_IV_3;
    ostate[4]=SHA256_IV_4; ostate[5]=SHA256_IV_5;
    ostate[6]=SHA256_IV_6; ostate[7]=SHA256_IV_7;
    sha256_xform(ostate,
        ihash[0]^0x5c5c5c5cu, ihash[1]^0x5c5c5c5cu,
        ihash[2]^0x5c5c5c5cu, ihash[3]^0x5c5c5c5cu,
        ihash[4]^0x5c5c5c5cu, ihash[5]^0x5c5c5c5cu,
        ihash[6]^0x5c5c5c5cu, ihash[7]^0x5c5c5c5cu,
        0x5c5c5c5cu, 0x5c5c5c5cu, 0x5c5c5c5cu, 0x5c5c5c5cu,
        0x5c5c5c5cu, 0x5c5c5c5cu, 0x5c5c5c5cu, 0x5c5c5c5cu);

    /* tstate = SHA256_IV ^ (ihash ^ 0x36363636) pad */
    tstate[0]=SHA256_IV_0; tstate[1]=SHA256_IV_1;
    tstate[2]=SHA256_IV_2; tstate[3]=SHA256_IV_3;
    tstate[4]=SHA256_IV_4; tstate[5]=SHA256_IV_5;
    tstate[6]=SHA256_IV_6; tstate[7]=SHA256_IV_7;
    sha256_xform(tstate,
        ihash[0]^0x36363636u, ihash[1]^0x36363636u,
        ihash[2]^0x36363636u, ihash[3]^0x36363636u,
        ihash[4]^0x36363636u, ihash[5]^0x36363636u,
        ihash[6]^0x36363636u, ihash[7]^0x36363636u,
        0x36363636u, 0x36363636u, 0x36363636u, 0x36363636u,
        0x36363636u, 0x36363636u, 0x36363636u, 0x36363636u);
}

/* =========================================================================
 * pbkdf2_80_128 — port of dagtech_pbkdf2_80_128
 *
 * tstate_in / ostate_in are const; local copies are used so callers'
 * tstate/ostate are not modified.
 *
 * Produces 32 uint words (128 bytes) in output[0..31].
 * ========================================================================= */
static void pbkdf2_80_128(__private const uint tstate_in[8],
                          __private const uint ostate_in[8],
                          __private const uint salt[20],
                          __private uint output[32])
{
    /* istate = tstate XORed with SHA256 of salt[0..15] */
    uint istate[8];
    for (int i = 0; i < 8; i++) istate[i] = tstate_in[i];
    sha256_xform(istate,
        salt[0],  salt[1],  salt[2],  salt[3],
        salt[4],  salt[5],  salt[6],  salt[7],
        salt[8],  salt[9],  salt[10], salt[11],
        salt[12], salt[13], salt[14], salt[15]);

    /* ibuf = { salt[16], salt[17], salt[18], salt[19], counter,
                INNERPAD_0, 0,0,0,0,0,0,0,0,0, INNERPAD_10 }
       (memcpy(ibuf, salt+16, 16) then memcpy(ibuf+5, scrypt_innerpad, 44)) */

    /* obuf layout: obuf[0..7]=obuf_state, obuf[8..15] = outerpad constant
       (memcpy(obuf+8, scrypt_outerpad, 32)) */

    for (int i = 0; i < 4; i++) {
        uint obuf_state[8];
        for (int j = 0; j < 8; j++) obuf_state[j] = istate[j];

        /* Process ibuf: salt[16..19], counter i+1, innerpad */
        sha256_xform(obuf_state,
            salt[16], salt[17], salt[18], salt[19],
            (uint)(i+1),
            INNERPAD_0, 0u, 0u,
            0u, 0u, 0u, 0u,
            0u, 0u, 0u, INNERPAD_10);

        /* ostate2 = outer; process obuf_state + outerpad */
        uint ostate2[8];
        for (int j = 0; j < 8; j++) ostate2[j] = ostate_in[j];
        sha256_xform(ostate2,
            obuf_state[0], obuf_state[1], obuf_state[2], obuf_state[3],
            obuf_state[4], obuf_state[5], obuf_state[6], obuf_state[7],
            OUTERPAD_0, 0u, 0u, 0u,
            0u, 0u, 0u, OUTERPAD_7);

        /* Store as big-endian words (BSWAP matches DAGTECH_SWAB32) */
        for (int j = 0; j < 8; j++)
            output[8*i + j] = BSWAP(ostate2[j]);
    }
}

/* =========================================================================
 * pbkdf2_128_32 — port of dagtech_pbkdf2_128_32
 *
 * Modifies tstate and ostate in place (last use at the call site).
 * Produces 8 uint words (32 bytes) in output[0..7].
 * ========================================================================= */
static void pbkdf2_128_32(__private uint tstate[8],
                          __private uint ostate[8],
                          __private const uint salt[32],
                          __private uint output[8])
{
    /* dagtech_sha256_xform(tstate, salt,      1)  -- swap=1 */
    sha256_xform(tstate,
        BSWAP(salt[0]),  BSWAP(salt[1]),  BSWAP(salt[2]),  BSWAP(salt[3]),
        BSWAP(salt[4]),  BSWAP(salt[5]),  BSWAP(salt[6]),  BSWAP(salt[7]),
        BSWAP(salt[8]),  BSWAP(salt[9]),  BSWAP(salt[10]), BSWAP(salt[11]),
        BSWAP(salt[12]), BSWAP(salt[13]), BSWAP(salt[14]), BSWAP(salt[15]));

    /* dagtech_sha256_xform(tstate, salt+16, 1) -- swap=1 */
    sha256_xform(tstate,
        BSWAP(salt[16]), BSWAP(salt[17]), BSWAP(salt[18]), BSWAP(salt[19]),
        BSWAP(salt[20]), BSWAP(salt[21]), BSWAP(salt[22]), BSWAP(salt[23]),
        BSWAP(salt[24]), BSWAP(salt[25]), BSWAP(salt[26]), BSWAP(salt[27]),
        BSWAP(salt[28]), BSWAP(salt[29]), BSWAP(salt[30]), BSWAP(salt[31]));

    /* dagtech_sha256_xform(tstate, scrypt_finalblk, 0) -- swap=0 */
    sha256_xform(tstate,
        FINALBLK_0, FINALBLK_1, 0u, 0u,
        0u, 0u, 0u, 0u,
        0u, 0u, 0u, 0u,
        0u, 0u, 0u, FINALBLK_15);

    /* buf = { tstate[0..7], OUTERPAD_0, 0,0,0,0,0,0, OUTERPAD_7 } */
    sha256_xform(ostate,
        tstate[0], tstate[1], tstate[2], tstate[3],
        tstate[4], tstate[5], tstate[6], tstate[7],
        OUTERPAD_0, 0u, 0u, 0u,
        0u, 0u, 0u, OUTERPAD_7);

    /* Output: BSWAP each word (matches DAGTECH_SWAB32) */
    for (int i = 0; i < 8; i++)
        output[i] = BSWAP(ostate[i]);
}

/* =========================================================================
 * xor_salsa8 — port of dagtech_xor_salsa8
 *
 * Salsa20/8 quarter-rounds: column then row ordering, exactly as in C.
 * ========================================================================= */
static void xor_salsa8(__private uint B[16], __private const uint Bx[16])
{
    uint x00=(B[0]^=Bx[0]),  x01=(B[1]^=Bx[1]),
         x02=(B[2]^=Bx[2]),  x03=(B[3]^=Bx[3]);
    uint x04=(B[4]^=Bx[4]),  x05=(B[5]^=Bx[5]),
         x06=(B[6]^=Bx[6]),  x07=(B[7]^=Bx[7]);
    uint x08=(B[8]^=Bx[8]),  x09=(B[9]^=Bx[9]),
         x10=(B[10]^=Bx[10]), x11=(B[11]^=Bx[11]);
    uint x12=(B[12]^=Bx[12]), x13=(B[13]^=Bx[13]),
         x14=(B[14]^=Bx[14]), x15=(B[15]^=Bx[15]);

    for (int i = 0; i < 8; i += 2) {
        /* Column rounds */
        x04^=rotate(x00+x12,7u);  x09^=rotate(x05+x01,7u);
        x14^=rotate(x10+x06,7u);  x03^=rotate(x15+x11,7u);
        x08^=rotate(x04+x00,9u);  x13^=rotate(x09+x05,9u);
        x02^=rotate(x14+x10,9u);  x07^=rotate(x03+x15,9u);
        x12^=rotate(x08+x04,13u); x01^=rotate(x13+x09,13u);
        x06^=rotate(x02+x14,13u); x11^=rotate(x07+x03,13u);
        x00^=rotate(x12+x08,18u); x05^=rotate(x01+x13,18u);
        x10^=rotate(x06+x02,18u); x15^=rotate(x11+x07,18u);
        /* Row rounds */
        x01^=rotate(x00+x03,7u);  x06^=rotate(x05+x04,7u);
        x11^=rotate(x10+x09,7u);  x12^=rotate(x15+x14,7u);
        x02^=rotate(x01+x00,9u);  x07^=rotate(x06+x05,9u);
        x08^=rotate(x11+x10,9u);  x13^=rotate(x12+x15,9u);
        x03^=rotate(x02+x01,13u); x04^=rotate(x07+x06,13u);
        x09^=rotate(x08+x11,13u); x14^=rotate(x13+x12,13u);
        x00^=rotate(x03+x02,18u); x05^=rotate(x04+x07,18u);
        x10^=rotate(x09+x08,18u); x15^=rotate(x14+x13,18u);
    }

    B[0]+=x00;  B[1]+=x01;  B[2]+=x02;  B[3]+=x03;
    B[4]+=x04;  B[5]+=x05;  B[6]+=x06;  B[7]+=x07;
    B[8]+=x08;  B[9]+=x09;  B[10]+=x10; B[11]+=x11;
    B[12]+=x12; B[13]+=x13; B[14]+=x14; B[15]+=x15;
}

/* =========================================================================
 * scrypt_romix — port of dagtech_scrypt_romix (N=1024)
 *
 * V_slice is the work-item's own 1024*32 uint slice of the global V buffer.
 * X[0..31] is the 128-byte scrypt block in private memory.
 * ========================================================================= */
static void scrypt_romix(__private uint X[32], __global uint *V_slice)
{
    /* Fill phase */
    for (int i = 0; i < 1024; i++) {
        for (int k = 0; k < 32; k++) V_slice[i*32 + k] = X[k];
        xor_salsa8(&X[0],  &X[16]);
        xor_salsa8(&X[16], &X[0]);
    }
    /* Mix phase */
    for (int i = 0; i < 1024; i++) {
        int j = (int)(X[16] & 1023u);
        for (int k = 0; k < 32; k++) X[k] ^= V_slice[j*32 + k];
        xor_salsa8(&X[0],  &X[16]);
        xor_salsa8(&X[16], &X[0]);
    }
}

/* =========================================================================
 * dagtech_search — main kernel
 *
 * Each work-item hashes one nonce = nonce_base + get_global_id(0).
 * Full pipeline:
 *   1. midstate (SHA256 of header[0..15], swap=0)
 *   2. hmac80_init
 *   3. pbkdf2_80_128
 *   4. scrypt_romix (using per-work-item V slice)
 *   5. Post-ROMix X[0] modification (proprietary DagTech step)
 *   6. pbkdf2_128_32
 *   7. Compare hash[7] against 32-bit target
 * ========================================================================= */
__kernel void dagtech_search(__global const uint *header80,
                             __global uint *output,
                             __global uint *V,
                             uint target,
                             uint nonce_base)
{
    uint gid   = get_global_id(0);
    uint nonce = nonce_base + gid;

    /* Copy header to private; set nonce at word 19 */
    __private uint hdr[20];
    for (int i = 0; i < 20; i++) hdr[i] = header80[i];
    hdr[19] = nonce;

    /* --- Step 1: midstate = SHA256_IV, then xform with hdr[0..15] (swap=0) --- */
    __private uint tstate[8];
    tstate[0]=SHA256_IV_0; tstate[1]=SHA256_IV_1;
    tstate[2]=SHA256_IV_2; tstate[3]=SHA256_IV_3;
    tstate[4]=SHA256_IV_4; tstate[5]=SHA256_IV_5;
    tstate[6]=SHA256_IV_6; tstate[7]=SHA256_IV_7;

    sha256_xform(tstate,
        hdr[0],  hdr[1],  hdr[2],  hdr[3],
        hdr[4],  hdr[5],  hdr[6],  hdr[7],
        hdr[8],  hdr[9],  hdr[10], hdr[11],
        hdr[12], hdr[13], hdr[14], hdr[15]);

    /* --- Step 2: HMAC-SHA256 init --- */
    __private uint ostate[8];
    hmac80_init(hdr, tstate, ostate);

    /* --- Step 3: PBKDF2 80 -> 128 --- */
    __private uint X[32];
    pbkdf2_80_128(tstate, ostate, hdr, X);

    /* --- Step 4: scrypt ROMix on per-work-item V slice --- */
    __global uint *V_slice = V + (size_t)gid * (size_t)(1024 * 32);
    scrypt_romix(X, V_slice);

    /* --- Step 5: Proprietary post-ROMix X[0] modification ---
         uint32_t B = DAGTECH_SWAB32(X[0]);
         uint32_t M = (B & 0xffff8000) | ((B + 0xe0) & 0x7fff);
         X[0] = DAGTECH_SWAB32(M);                                   */
    {
        uint B = BSWAP(X[0]);
        uint M = (B & 0xffff8000u) | ((B + 0xe0u) & 0x7fffu);
        X[0]  = BSWAP(M);
    }

    /* --- Step 6: PBKDF2 128 -> 32 --- */
    __private uint hash[8];
    pbkdf2_128_32(tstate, ostate, X, hash);

    /* --- Step 7: Check target (hash[7] is the highest-order word after BSWAP) ---
       The C check uses hash[31..24] as a big-endian uint64.
       After pbkdf2_128_32, hash[i] = BSWAP(ostate[i]), so
       hash[7] is the most-significant 32 bits of the big-endian hash.
       We check hash[7] <= target (32-bit approximation). */
    if (hash[7] <= target) {
        atomic_min(&output[0], nonce);
        atomic_inc(&output[1]);
    }
}
