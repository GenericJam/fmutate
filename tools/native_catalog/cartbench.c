/* SPDX-License-Identifier: GPL-3.0-only */
/* cartbench: a native cartridge flat out, as libfm1emu.so --bench does for a package.
 *
 *   cartbench <libcart_<id>.so> [seconds] [key ...]
 *
 * Boots the cartridge, lets it settle 2 s of firmware time, holds the keys (default 7 11 14: a chord) and renders
 * `seconds` (default 8) of audio as fast as it can. Prints one JSON line: the real-time factor (firmware time /
 * wall time; 1.0 = exactly real time, so 1/x is the share of one core it needs), the CPU time, the chord's peak and
 * RMS. Build: cc -O2 -o cartbench tools/native_catalog/cartbench.c -ldl (the NDK's clang for a phone). */
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now(clockid_t c)
{
    struct timespec ts;
    clock_gettime(c, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void *sym(void *h, const char *n)
{
    void *p = dlsym(h, n);
    if (!p) { fprintf(stderr, "cartbench: no %s\n", n); exit(2); }
    return p;
}

int main(int argc, char **argv)
{
    void *h;
    int (*init)(void);
    uint32_t (*rate)(void), (*ms)(void);
    void (*render)(int16_t *, uint32_t), (*key)(uint32_t, uint32_t);
    double secs = argc > 2 ? atof(argv[2]) : 8.0, t0, c0, wall, cpu, sum = 0;
    int16_t blk[512];
    uint32_t fs, frames, i, j, peak = 0;
    int nk = argc > 3 ? argc - 3 : 3, keys[27] = {7, 11, 14};

    if (argc < 2) { fprintf(stderr, "usage: cartbench <cart.so> [seconds] [key ...]\n"); return 2; }
    for (i = 0; argc > 3 && i < (uint32_t)nk && i < 27u; i++) keys[i] = atoi(argv[3 + i]);
    if (!(h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL))) { fprintf(stderr, "cartbench: %s\n", dlerror()); return 2; }
    init = sym(h, "fm1c_init"); rate = sym(h, "fm1c_rate"); ms = sym(h, "fm1c_ms");
    render = sym(h, "fm1c_render"); key = sym(h, "fm1c_key");
    t0 = now(CLOCK_MONOTONIC);
    if (init()) { fprintf(stderr, "cartbench: did not boot\n"); return 2; }
    fs = rate();
    for (frames = 0; frames < 2u * fs; frames += 256u) render(blk, 256u);
    double boot = now(CLOCK_MONOTONIC) - t0;
    for (i = 0; i < (uint32_t)nk; i++) key((uint32_t)keys[i], 1u);
    t0 = now(CLOCK_MONOTONIC);
    c0 = now(CLOCK_PROCESS_CPUTIME_ID);
    uint32_t n = (uint32_t)(secs * fs);
    for (frames = 0; frames < n; frames += 256u) {
        render(blk, 256u);
        if (frames > fs / 2u)                   /* (the chord's attack over) */
            for (j = 0; j < 512u; j++) {
                uint32_t a = (uint32_t)abs(blk[j]);
                if (a > peak) peak = a;
                sum += (double)blk[j] * blk[j];
            }
    }
    wall = now(CLOCK_MONOTONIC) - t0;
    cpu = now(CLOCK_PROCESS_CPUTIME_ID) - c0;
    printf("{\"rt\": %.2f, \"cpu_rt\": %.2f, \"boot_2s_wall\": %.3f, \"fw_ms\": %u, \"peak\": %u, \"rms_db\": %.1f}\n",
           secs / wall, secs / cpu, boot, ms(), peak, 10.0 * log10(sum / ((double)(n - fs / 2u) * 2.0) / (32768.0 * 32768.0) + 1e-24));
    return 0;
}
