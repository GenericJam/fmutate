/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from zvenson's Dinghy platform (Dinghy and its forks: firmware/src/platform.c includes the
 * fake FM-1 tests/host.c under DINGHY_HOST). native/engine/live.c does this for OberVave's line (OBV_HOST with the
 * browser simulator's OBV_WASM); the Dinghy line has no such switch, so tools/native_catalog/build.py compiles a
 * copy of the firmware whose tests/host.c has its script runner (platform_poll) and main() renamed away, and this
 * file drives the app's loop instead, as live.c does: app_main on its own thread, parked at each platform_poll,
 * one pass per millisecond of audio, the ISR (app_audio) every HALF_FRAMES frames in between.
 *
 * Storage: the fake FM-1 keeps the settings, blobs and slots in RAM arrays (host_set, host_blob[], host_slot[] in
 * Dinghy; forks vary). build.py passes DH_STORE_<array>=1 for each it finds; they are saved as one blob, in that
 * order. A fork with none of them runs without saves. OberVave's line (OBV_HOST) builds with OBV_WASM, where the fake
 * FM-1 leaves platform_poll and main to its includer, as in live.c. */
#include <fcntl.h>
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EXPORT __attribute__((used, visibility("default")))

static void platform_poll(void);
#include FW_MAIN

/* ---- the main loop as a coroutine on its own thread (live.c) */
static sem_t *run_app, *run_caller;
static pthread_t app_thread;
static volatile int booted, debug_crash, debug_hang;

static sem_t *sem_new(void)
{
#ifdef __APPLE__                                /* (macOS has no unnamed semaphores) */
    char name[64];
    sem_t *s;
    snprintf(name, sizeof name, "/fm1dh.%d.%p", (int)getpid(), (void *)&name);
    s = sem_open(name, O_CREAT | O_EXCL, 0600, 0);
    sem_unlink(name);
    return s == SEM_FAILED ? 0 : s;
#else
    sem_t *s = malloc(sizeof *s);
    if (s && sem_init(s, 0, 0)) { free(s); return 0; }
    return s;
#endif
}

static void platform_poll(void)
{
    if (debug_crash) raise(SIGSEGV);
    while (debug_hang)
        ;
    sem_post(run_caller);
    sem_wait(run_app);
}
static void *app_run(void *arg)
{
    (void)arg;
    sem_wait(run_app);
    app_main();
    return 0;
}
static void pass(void)
{
    sem_post(run_app);
    sem_wait(run_caller);
}

/* ---- panel edges (live.c's rule: each input's edges EDGE_GAP_MS of firmware time apart) */
#define EDGE_GAP_MS 16u
#define EDGE_NIN 41u
#define EDGE_KEY0 14u
#define EDGE_QMAX 32u
static struct { uint32_t at; uint8_t on, n; } edge[EDGE_NIN];
static uint64_t edge_pending;

static void edge_apply(uint32_t i, uint32_t down)
{
    uint32_t bit = i >= EDGE_KEY0 ? 1u << (i - EDGE_KEY0) : 1u << i;
    edge[i].on = (uint8_t)down;
    edge[i].at = fm1_ms;
    if (i >= EDGE_KEY0) {
        if (down) fm1_in.notes |= bit;
        else fm1_in.notes &= ~bit;
    } else if (down) {
        fm1_in.buttons |= bit;
        host_edges |= bit;
    } else {
        fm1_in.buttons &= ~bit;
#if DH_HAS_host_rel
        host_rel |= bit;
#endif
    }
}
static int edge_settled(uint32_t i) { return fm1_ms - edge[i].at >= EDGE_GAP_MS; }
static void edge_in(uint32_t i, uint32_t down)
{
    down = down != 0u;
    if (down == (edge[i].on ^ (edge[i].n & 1u))) return;
    if (!edge[i].n && edge_settled(i))
        edge_apply(i, down);
    else if (edge[i].n < EDGE_QMAX) {
        edge[i].n++;
        edge_pending |= 1ull << i;
    } else
        edge[i].n--;
}
static void edges_due(void)
{
    uint64_t p = edge_pending;
    while (p) {
        uint32_t i = (uint32_t)__builtin_ctzll(p);
        p &= p - 1u;
        if (!edge_settled(i)) continue;
        edge_apply(i, !edge[i].on);
        if (!--edge[i].n) edge_pending &= ~(1ull << i);
    }
}

/* ---- storage: the fake FM-1's arrays, concatenated into one blob */
static struct { void *p; size_t n; } store_part[4];
static uint32_t store_parts;
static uint8_t *store_blob;
static size_t store_size;
static void store_setup(void)
{
    uint32_t i;
    if (store_blob || store_parts) return;
#if DH_STORE_host_set
    store_part[store_parts].p = host_set; store_part[store_parts++].n = sizeof host_set;
#endif
#if DH_STORE_host_store
    store_part[store_parts].p = host_store; store_part[store_parts++].n = sizeof host_store;
#endif
#if DH_STORE_host_blob
    store_part[store_parts].p = host_blob; store_part[store_parts++].n = sizeof host_blob;
#endif
#if DH_STORE_host_slot
    store_part[store_parts].p = host_slot; store_part[store_parts++].n = sizeof host_slot;
#endif
    for (i = 0; i < store_parts; i++) store_size += store_part[i].n;
    if (store_size) store_blob = calloc(1, store_size);
}
static void store_copy(int to_firmware)
{
    size_t off = 0;
    uint32_t i;
    for (i = 0; store_blob && i < store_parts; i++) {
        if (to_firmware) memcpy(store_part[i].p, store_blob + off, store_part[i].n);
        else memcpy(store_blob + off, store_part[i].p, store_part[i].n);
        off += store_part[i].n;
    }
}
EXPORT uint32_t fm1c_blob_count(void) { store_setup(); return store_blob ? 1u : 0u; }
EXPORT uint32_t fm1c_blob_size(void) { store_setup(); return (uint32_t)store_size; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { store_setup(); return i == 0u ? store_blob : 0; }
EXPORT uint32_t fm1c_store_hash(void)
{
    uint32_t h = 2166136261u;
    size_t i;
    store_setup();
    store_copy(0);
    for (i = 0; i < store_size; i++) h = (h ^ store_blob[i]) * 16777619u;
    return h;
}

/* ---- the clock */
static int32_t blk[2u * HALF_FRAMES];
static uint32_t blk_pos = HALF_FRAMES, ms_acc;
static int32_t master_q12 = 4096;

EXPORT int fm1c_init(void)
{
    uint32_t i;
    if (booted) return -1;
    store_setup();
    store_copy(1);
    for (i = 0; i < EDGE_NIN; i++) edge[i].at = fm1_ms - EDGE_GAP_MS;
    if (!(run_app = sem_new()) || !(run_caller = sem_new())) return -1;
    if (pthread_create(&app_thread, 0, app_run, 0)) return -1;
    booted = 1;
    pass();
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return FS; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i, j;
    for (i = 0; i < n; i++) {
        if (blk_pos >= HALF_FRAMES) {
            memset(blk, 0, sizeof blk);
            app_audio(blk, HALF_FRAMES);
            for (j = 0; j < 2u * HALF_FRAMES; j++) {
                int32_t v = (blk[j] * master_q12) >> 12;
                blk[j] = v > 32767 ? 32767 : v < -32767 ? -32767 : v;
            }
            blk_pos = 0;
        }
        out[2u * i] = (int16_t)blk[2u * blk_pos];
        out[2u * i + 1u] = (int16_t)blk[2u * blk_pos + 1u];
        blk_pos++;
        if ((ms_acc += 1000u) >= FS) {
            ms_acc -= FS;
            edges_due();
            fm1_ms++;
            pass();
        }
    }
}
EXPORT uint32_t fm1c_ms(void) { return fm1_ms; }
EXPORT void fm1c_master(uint32_t k10)
{
    if (k10 > 1024u) k10 = 1024u;
    master_q12 = (int32_t)((k10 * k10) >> 8);
}
EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < 27u) edge_in(EDGE_KEY0 + k, down); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) edge_in(b, down); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps)
{
    if (e < sizeof host_enc / sizeof host_enc[0]) {
        host_enc[e] += steps;
#if DH_HAS_host_enc_pos
        host_enc_pos[e] += steps;
#endif
    }
}
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st < 0x80u || st >= 0xF0u || mq_w - mq_r >= 64u) return;
    mq[mq_w % 64u][0] = (uint8_t)st;
    mq[mq_w % 64u][1] = (uint8_t)(d1 & 0x7Fu);
    mq[mq_w % 64u][2] = (uint8_t)(d2 & 0x7Fu);
#if DH_MQ4
    mq[mq_w % 64u][3] = 1;                      /* (from USB) */
#endif
    mq_w++;
}
EXPORT const uint16_t *fm1c_fb(void) { return fb; }
EXPORT uint32_t fm1c_fb_hash(void)
{
    uint32_t h = 2166136261u, i;
    const uint32_t *p = (const uint32_t *)fb;
    for (i = 0; i < 240u * 240u / 2u; i++) h = (h ^ p[i]) * 16777619u;
    return h;
}
/* the fake FM-1's LEDs, by its version: host_leds (+ host_glow) as 64-bit ids, host_led as 64-bit ids or bytes */
static uint64_t leds64(void)
{
#if DH_HAS_host_leds
    return host_leds;
#elif DH_HAS_host_led64
    return host_led;
#elif DH_HAS_host_led_arr
    uint64_t m = 0;
    for (uint32_t i = 0; i < 64u && i < sizeof host_led; i++)
        if (host_led[i]) m |= 1ull << i;
    return m;
#else
    return 0;
#endif
}
EXPORT uint32_t fm1c_leds_buttons(void) { return (uint32_t)(leds64() & 0x3FFFu); }
EXPORT uint32_t fm1c_leds_keys(void) { return (uint32_t)(leds64() >> 14) & 0x7FFFFFFu; }
#if DH_HAS_host_glow
EXPORT uint32_t fm1c_glow_keys(void) { return (uint32_t)(host_glow >> 14) & 0x7FFFFFFu; }
#else
EXPORT uint32_t fm1c_glow_keys(void) { return 0; }
#endif
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
