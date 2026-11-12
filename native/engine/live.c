/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge: one FM-1 firmware of the Dinghy/zvenson platform family (OberVave, Shine On, ...) as a
 * native shared library, on its authors' own fake FM-1 (tests/host.c, the build their browser simulator uses:
 * OBV_HOST + OBV_WASM, web/sim/sim.c). The exported fm1c_* calls are web/sim/sim.c's sim_* panel API, natively.
 *
 * The app's main loop never returns (app_main: for (;;) { platform_poll(); ... }). The browser build parks it with
 * Binaryen's Asyncify; here it runs on its own thread and hands control back and forth with the caller's thread
 * (two semaphores), so exactly one of them runs at a time: platform_poll() parks the loop, fm1c_pass() runs it
 * until it parks again. One pass per millisecond of audio, the ISR (app_audio, 256 frames) in between, as on the
 * device and in tests/host.c. Everything the caller does (panel input, reading the screen) happens while the loop
 * is parked, so nothing is shared while both run.
 *
 * Build: cc -O2 -shared -fPIC -DFW_MAIN='"<repo>/firmware/src/<app>.c"' -I<repo>/firmware/src -I<repo>/firmware/gen
 *        live.c -o <app>.so -lpthread */
#define OBV_HOST 1
#define OBV_WASM 1
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((used, visibility("default")))

#include FW_MAIN

/* ---- the main loop as a coroutine on its own thread */
static sem_t run_app, run_caller;
static pthread_t app_thread;
static volatile int booted, debug_crash, debug_hang;

static void platform_poll(void)                 /* the app, every pass: park until the next millisecond */
{
    if (debug_crash)
        raise(SIGSEGV);                         /* (debug: as if the firmware had dereferenced garbage) */
    while (debug_hang)                          /* (debug: as if the firmware's loop never came back to poll) */
        ;
    sem_post(&run_caller);
    sem_wait(&run_app);
}
static void *app_run(void *arg)
{
    (void)arg;
    sem_wait(&run_app);
    app_main();                                 /* (never returns) */
    return 0;
}
static void fm1c_pass(void)                     /* one pass of the main loop (the first: boot up to its first poll) */
{
    sem_post(&run_app);
    sem_wait(&run_caller);
}

/* ---- the panel's keys and buttons, as the device's debounced matrix delivers them. Input comes in batches (a
 * port read), so a press and its release can arrive together, between two passes: applied at once, the main loop
 * would never see the press. Each input's edges are applied in order, each one once the input's previous edge has
 * been in place for EDGE_GAP_MS passes of the main loop (firmware milliseconds); an edge with none pending before
 * it, on an input that has been steady that long, is applied at once. Inputs are independent: OCT- and OCT+
 * tapped together are down in the same pass (the firmwares' "both: octave 0").
 * 16 ms: what the firmwares' own scan needs to see an edge, with a margin. Their hal/fm1_input.h (Felucca's)
 * debounces in frames of the 11-column scan (~1.1 ms): a press counts after FM1_DEB_PRESS (2) frames closed, a
 * release after FM1_DEB_RELEASE (8) frames open, up to ~10 ms with the scan's phase. In the emulator engine
 * (native/emu, the same gap) the firmware runs that scan on the emulated matrix, so a shorter release is never
 * seen; here, where the main loop reads the panel every pass, it gives each edge the time the device gives it (a
 * debounced key is down >= ~9 ms however short the touch). Shorter than any human double tap, so only edges that
 * arrive together wait. Ids as fm1-emu's matrix: 0..13 buttons, 14..40 keys. */
#define EDGE_GAP_MS 16u
#define EDGE_NIN 41u
#define EDGE_KEY0 14u
#define EDGE_QMAX 32u                           /* edges an input holds back (16 taps, ~0.5 s) */
static struct { uint32_t at; uint8_t on, n; } edge[EDGE_NIN];   /* `on` since the pass after fm1_ms `at`; n flips queued */
static uint64_t edge_pending;                   /* bit i: edge[i].n > 0 */

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
        host_edges |= bit;                      /* (fm1_input_edges: pressed and released since the last call) */
    } else {
        fm1_in.buttons &= ~bit;
        host_rel |= bit;
    }
}
static int edge_settled(uint32_t i) { return fm1_ms - edge[i].at >= EDGE_GAP_MS; }
static void edge_in(uint32_t i, uint32_t down)
{
    down = down != 0u;
    if (down == (edge[i].on ^ (edge[i].n & 1u))) return;   /* (the state it is already going to) */
    if (!edge[i].n && edge_settled(i))
        edge_apply(i, down);
    else if (edge[i].n < EDGE_QMAX) {
        edge[i].n++;
        edge_pending |= 1ull << i;
    } else
        edge[i].n--;                            /* (full: it cancels the last one queued; the state still ends right) */
}
static void edges_due(void)                     /* before each pass */
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

/* ---- the clock: audio in the ISR's 256-frame blocks, the main loop every millisecond (as web/sim/sim.c) */
static int32_t blk[2u * HALF_FRAMES];
static uint32_t blk_pos = HALF_FRAMES, ms_acc;
static int32_t master_q12 = 4096;

EXPORT int fm1c_init(void)                      /* boot; call once. 0 = ok */
{
    uint32_t i;
    if (booted) return -1;
    for (i = 0; i < EDGE_NIN; i++) edge[i].at = fm1_ms - EDGE_GAP_MS;   /* (all settled) */
    sem_init(&run_app, 0, 0);
    sem_init(&run_caller, 0, 0);
    if (pthread_create(&app_thread, 0, app_run, 0)) return -1;
    booted = 1;
    fm1c_pass();
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return FS; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)   /* n stereo frames, interleaved */
{
    uint32_t i, j;
    for (i = 0; i < n; i++) {
        if (blk_pos >= HALF_FRAMES) {           /* the ISR: a block, the MASTER knob, the device's clip */
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
        if ((ms_acc += 1000u) >= FS) {           /* a millisecond: the panel, the clock, then a pass of the main loop */
            ms_acc -= FS;
            edges_due();
            fm1_ms++;
            fm1c_pass();
        }
    }
}
EXPORT uint32_t fm1c_ms(void) { return fm1_ms; }
EXPORT void fm1c_master(uint32_t k10)           /* MASTER, 0..1024 (the device's curve; 1024 = unity) */
{
    if (k10 > 1024u) k10 = 1024u;
    master_q12 = (int32_t)((k10 * k10) >> 8);
}

/* ---- the panel (web/sim/sim.c's) */
EXPORT void fm1c_key(uint32_t k, uint32_t down) /* the 27 keys: 0 = F3 .. 26 = G5 */
{
    if (k < 27u) edge_in(EDGE_KEY0 + k, down);
}
EXPORT void fm1c_button(uint32_t b, uint32_t down)  /* 0 OCT- 1 OCT+ 2 FX 3 SEL 4 ENV 5 LFO 6 EDIT 7 GLO 8 HOME 9 SAVE
                                                       10 ARP 11 SEQ 12 PLAY 13 REC */
{
    if (b < 14u) edge_in(b, down);
}
EXPORT void fm1c_enc(uint32_t e, int32_t steps) /* 0 SELECT 1 ALGORITHM 2-5 KNOB 1-4 6 PRESETS; + = clockwise */
{
    if (e < (uint32_t)HOST_NENC) { host_enc[e] += steps; host_enc_pos[e] += steps; }
}
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st < 0x80u || st == 0xF0u || st == 0xF7u || st == 0xFEu || mq_w - mq_r >= 64u) return;
    mq[mq_w % 64u][0] = (uint8_t)st; mq[mq_w % 64u][1] = (uint8_t)(d1 & 0x7Fu); mq[mq_w % 64u][2] = (uint8_t)(d2 & 0x7Fu);
    mq_w++;
}

/* ---- what the panel shows */
EXPORT const uint16_t *fm1c_fb(void) { return fb; }   /* 240 x 240 RGB565, row by row */
EXPORT uint32_t fm1c_fb_hash(void)
{
    uint32_t h = 2166136261u, i;
    const uint32_t *p = (const uint32_t *)fb;
    for (i = 0; i < 240u * 240u / 2u; i++) h = (h ^ p[i]) * 16777619u;
    return h;
}
EXPORT uint32_t fm1c_leds_buttons(void) { return (uint32_t)(host_leds & 0x3FFFu); }
EXPORT uint32_t fm1c_leds_keys(void) { return (uint32_t)(host_leds >> 14) & 0x7FFFFFFu; }
EXPORT uint32_t fm1c_glow_keys(void) { return (uint32_t)(host_glow >> 14) & 0x7FFFFFFu; }

/* ---- storage: blob 0 = the settings sector (with the programs), 1..NBLOB = pattern slots; byte 0 = 1 if used.
 * The engine loads them before fm1c_init and saves them when fm1c_store_hash changes. */
EXPORT uint32_t fm1c_blob_count(void) { return NBLOB + 1u; }
EXPORT uint32_t fm1c_blob_size(void) { return HOST_BLOB_SZ; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { return i == 0u ? host_store : i <= NBLOB ? host_slot[i - 1u] : 0; }
EXPORT uint32_t fm1c_store_hash(void)
{
    uint32_t h = 2166136261u, i, b;
    for (b = 0; b <= NBLOB; b++) {
        const uint8_t *p = fm1c_blob(b);
        for (i = 0; i < HOST_BLOB_SZ; i++) h = (h ^ p[i]) * 16777619u;
    }
    return h;
}

/* ---- debug: prove the isolation */
EXPORT void fm1c_debug(uint32_t what)           /* 1: crash at the next pass, 2: hang at the next pass */
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
