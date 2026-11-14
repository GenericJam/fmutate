/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from zvenson's Dinghy platform (Dinghy and its forks: firmware/src/platform.c includes a fake
 * FM-1, a host.c, under a <NAME>_HOST switch). native/engine/live.c does this for OberVave's line (OBV_HOST with the
 * browser simulator's OBV_WASM); the rest of the line has no such switch, so tools/native_catalog/recipes/dinghy.py
 * compiles a copy of the firmware whose fake has its script runner (platform_poll) renamed away and its main()
 * renamed to host_script_main, and this file drives the app's loop instead, as live.c does: the fake's main (the
 * fork's own setup, then app_main or app_init + app_loop) on its own thread, parked at each platform_poll, one pass
 * per millisecond of audio, the ISR (app_audio) every HALF_FRAMES frames in between.
 *
 * The fakes name their state differently; the recipe reads the names from the fake's own functions and passes them:
 *   DH_PRESS, DH_REL     the buttons' press and release edges (fm1_input_edges)
 *   DH_NOTE_PRESS        the keys' press edges (fm1_input_note_edges), when the fake keeps them
 *   DH_ENC, DH_ENC_POS   the encoders' detents owed to the app (fm1_enc_take); the position so far
 *   DH_LED64             the lit LEDs, a bit per LED id (0..13 the buttons, 14..40 the keys)
 *   DH_LED_ARR           ... a byte per LED id (DH_LED_ARR_GLOW: 2 lit, 1 dim, in the one array)
 *   DH_LED_KEYS32        ... the keys' only, a bit per key
 *   DH_GLOW64, DH_GLOW_ARR  the dim layer, as a bit or a byte per LED id
 *   DH_STORE0..          the fake's RAM storage (settings, slots, the flash it fakes): one blob, in that order
 *   DH_HOST_MAIN         the fake's main is there to run (not in OberVave's line, where app_main is called)
 * The panel state fm1_in, the clock fm1_ms, the screen fb and the MIDI-in queue mq / mq_w are the same in all. */
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
static void dh_boot(void);
#include FW_MAIN

/* ---- the main loop as a coroutine on its own thread (live.c) */
static sem_t *dh_run_app, *dh_run_caller;
static pthread_t dh_app_thread;
static volatile int dh_booted, dh_debug_crash, dh_debug_hang;

static sem_t *dh_sem_new(void)
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
    if (dh_debug_crash) raise(SIGSEGV);
    while (dh_debug_hang)
        ;
    sem_post(dh_run_caller);
    sem_wait(dh_run_app);
}
static void *dh_app_run(void *arg)
{
    (void)arg;
    sem_wait(dh_run_app);
#if DH_HOST_MAIN
    {
        static char arg0[] = "fm1cart";
        char *argv[] = {arg0, 0};
        host_script_main(1, argv);
    }
#else
    dh_boot();
    app_main();
#endif
    return 0;
}
static void dh_pass(void)
{
    sem_post(dh_run_app);
    sem_wait(dh_run_caller);
}

/* ---- panel edges (live.c's rule: each input's edges EDGE_GAP_MS of firmware time apart) */
#define EDGE_GAP_MS 16u
#define EDGE_NIN 41u
#define EDGE_KEY0 14u
#define EDGE_QMAX 32u
static struct { uint32_t at; uint8_t on, n; } dh_edge[EDGE_NIN];
static uint64_t dh_edge_pending;

static void dh_edge_apply(uint32_t i, uint32_t down)
{
    uint32_t bit = i >= EDGE_KEY0 ? 1u << (i - EDGE_KEY0) : 1u << i;
    dh_edge[i].on = (uint8_t)down;
    dh_edge[i].at = fm1_ms;
    if (i >= EDGE_KEY0) {
        if (down) {
            fm1_in.notes |= bit;
#ifdef DH_NOTE_PRESS
            DH_NOTE_PRESS |= bit;
#endif
        } else
            fm1_in.notes &= ~bit;
    } else if (down) {
        fm1_in.buttons |= bit;
#ifdef DH_PRESS
        DH_PRESS |= bit;
#endif
    } else {
        fm1_in.buttons &= ~bit;
#ifdef DH_REL
        DH_REL |= bit;
#endif
    }
}
static int dh_edge_settled(uint32_t i) { return fm1_ms - dh_edge[i].at >= EDGE_GAP_MS; }
static void dh_edge_in(uint32_t i, uint32_t down)
{
    down = down != 0u;
    if (down == (dh_edge[i].on ^ (dh_edge[i].n & 1u))) return;
    if (!dh_edge[i].n && dh_edge_settled(i))
        dh_edge_apply(i, down);
    else if (dh_edge[i].n < EDGE_QMAX) {
        dh_edge[i].n++;
        dh_edge_pending |= 1ull << i;
    } else
        dh_edge[i].n--;
}
static void dh_edges_due(void)
{
    uint64_t p = dh_edge_pending;
    while (p) {
        uint32_t i = (uint32_t)__builtin_ctzll(p);
        p &= p - 1u;
        if (!dh_edge_settled(i)) continue;
        dh_edge_apply(i, !dh_edge[i].on);
        if (!--dh_edge[i].n) dh_edge_pending &= ~(1ull << i);
    }
}

/* ---- storage: the fake FM-1's arrays, concatenated into one blob. The engine fills the blob before fm1c_init
 * when it has one saved; the fake's main sets its arrays up (an erased flash) and then calls dh_boot, which puts a
 * saved blob over them. A blob that is all zeros was never saved. */
static struct { void *p; size_t n; } dh_part[8];
static uint32_t dh_parts;
static uint8_t *dh_blob;
static size_t dh_blob_n;
#define DH_PART(a) (dh_part[dh_parts].p = (void *)(a), dh_part[dh_parts++].n = sizeof(a))
static void dh_store_setup(void)
{
    uint32_t i;
    if (dh_blob || dh_parts) return;
#ifdef DH_STORE0
    DH_PART(DH_STORE0);
#endif
#ifdef DH_STORE1
    DH_PART(DH_STORE1);
#endif
#ifdef DH_STORE2
    DH_PART(DH_STORE2);
#endif
#ifdef DH_STORE3
    DH_PART(DH_STORE3);
#endif
#ifdef DH_STORE4
    DH_PART(DH_STORE4);
#endif
    for (i = 0; i < dh_parts; i++) dh_blob_n += dh_part[i].n;
    if (dh_blob_n) dh_blob = calloc(1, dh_blob_n);
}
static void dh_store_copy(int to_firmware)
{
    size_t off = 0;
    uint32_t i;
    for (i = 0; dh_blob && i < dh_parts; i++) {
        if (to_firmware) memcpy(dh_part[i].p, dh_blob + off, dh_part[i].n);
        else memcpy(dh_blob + off, dh_part[i].p, dh_part[i].n);
        off += dh_part[i].n;
    }
}
static void dh_boot(void)
{
    size_t i;
    for (i = 0; i < dh_blob_n && !dh_blob[i]; i++)
        ;
    if (i < dh_blob_n) dh_store_copy(1);
}
EXPORT uint32_t fm1c_blob_count(void) { dh_store_setup(); return dh_blob ? 1u : 0u; }
EXPORT uint32_t fm1c_blob_size(void) { dh_store_setup(); return (uint32_t)dh_blob_n; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { dh_store_setup(); return i == 0u ? dh_blob : 0; }
EXPORT uint32_t fm1c_store_hash(void)
{
    uint32_t h = 2166136261u;
    size_t i;
    dh_store_setup();
    if (!dh_booted) return h;
    dh_store_copy(0);
    for (i = 0; i < dh_blob_n; i++) h = (h ^ dh_blob[i]) * 16777619u;
    return h;
}

/* ---- the clock */
static int32_t dh_blk[2u * HALF_FRAMES];
static uint32_t dh_blk_pos = HALF_FRAMES, dh_ms_acc;
static int32_t dh_master_q12 = 4096;

EXPORT int fm1c_init(void)
{
    uint32_t i;
    if (dh_booted) return -1;
    dh_store_setup();
    for (i = 0; i < EDGE_NIN; i++) dh_edge[i].at = fm1_ms - EDGE_GAP_MS;
    if (!(dh_run_app = dh_sem_new()) || !(dh_run_caller = dh_sem_new())) return -1;
    if (pthread_create(&dh_app_thread, 0, dh_app_run, 0)) return -1;
    dh_booted = 1;
    dh_pass();
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return FS; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i, j;
    for (i = 0; i < n; i++) {
        if (dh_blk_pos >= HALF_FRAMES) {
            memset(dh_blk, 0, sizeof dh_blk);
            app_audio(dh_blk, HALF_FRAMES);
            for (j = 0; j < 2u * HALF_FRAMES; j++) {
                int32_t v = (dh_blk[j] * dh_master_q12) >> 12;
                dh_blk[j] = v > 32767 ? 32767 : v < -32767 ? -32767 : v;
            }
            dh_blk_pos = 0;
        }
        out[2u * i] = (int16_t)dh_blk[2u * dh_blk_pos];
        out[2u * i + 1u] = (int16_t)dh_blk[2u * dh_blk_pos + 1u];
        dh_blk_pos++;
        if ((dh_ms_acc += 1000u) >= FS) {
            dh_ms_acc -= FS;
            dh_edges_due();
            fm1_ms++;
            dh_pass();
        }
    }
}
EXPORT uint32_t fm1c_ms(void) { return fm1_ms; }
EXPORT void fm1c_master(uint32_t k10)
{
    if (k10 > 1024u) k10 = 1024u;
    dh_master_q12 = (int32_t)((k10 * k10) >> 8);
}
EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < 27u) dh_edge_in(EDGE_KEY0 + k, down); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) dh_edge_in(b, down); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps)
{
#ifdef DH_ENC
    if (e < sizeof DH_ENC / sizeof DH_ENC[0]) {
        DH_ENC[e] += steps;
#ifdef DH_ENC_POS
        DH_ENC_POS[e] += steps;
#endif
    }
#else
    (void)e; (void)steps;                       /* (a fake without encoders: the app reads none) */
#endif
}
#define DH_MQ_N (sizeof mq / sizeof mq[0])
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st < 0x80u || st >= 0xF0u || mq_w - mq_r >= DH_MQ_N) return;
    mq[mq_w % DH_MQ_N][0] = (uint8_t)st;
    mq[mq_w % DH_MQ_N][1] = (uint8_t)(d1 & 0x7Fu);
    mq[mq_w % DH_MQ_N][2] = (uint8_t)(d2 & 0x7Fu);
    if (sizeof mq[0] > 3u) mq[mq_w % DH_MQ_N][sizeof mq[0] > 3u ? 3 : 0] = 1;   /* (from USB) */
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
/* the fake FM-1's LEDs, by LED id: lit, and the dim layer */
static uint64_t dh_leds(void)
{
#if defined DH_LED64
    return DH_LED64;
#elif defined DH_LED_KEYS32
    return (uint64_t)DH_LED_KEYS32 << 14;
#elif defined DH_LED_ARR
    uint64_t m = 0;
    for (uint32_t i = 0; i < 64u && i < sizeof DH_LED_ARR; i++)
#if DH_LED_ARR_GLOW
        if (DH_LED_ARR[i] == 2) m |= 1ull << i;
#else
        if (DH_LED_ARR[i]) m |= 1ull << i;
#endif
    return m;
#else
    return 0;
#endif
}
static uint64_t dh_glow(void)
{
#if defined DH_GLOW64
    return DH_GLOW64;
#elif defined DH_GLOW_ARR || (defined DH_LED_ARR && DH_LED_ARR_GLOW)
#ifdef DH_GLOW_ARR
#define DH_G DH_GLOW_ARR
#define DH_G_ON(v) ((v) != 0)
#else
#define DH_G DH_LED_ARR
#define DH_G_ON(v) ((v) == 1)
#endif
    uint64_t m = 0;
    for (uint32_t i = 0; i < 64u && i < sizeof DH_G; i++)
        if (DH_G_ON(DH_G[i])) m |= 1ull << i;
    return m;
#else
    return 0;
#endif
}
EXPORT uint32_t fm1c_leds_buttons(void) { return (uint32_t)(dh_leds() & 0x3FFFu); }
EXPORT uint32_t fm1c_leds_keys(void) { return (uint32_t)(dh_leds() >> 14) & 0x7FFFFFFu; }
EXPORT uint32_t fm1c_glow_keys(void) { return (uint32_t)(dh_glow() >> 14) & 0x7FFFFFFu; }
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) dh_debug_crash = 1;
    if (what == 2u) dh_debug_hang = 1;
}
