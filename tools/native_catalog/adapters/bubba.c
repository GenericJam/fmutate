/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from Bubba Machine's portable core (Erbubar23/bubba-machine core/: bm_app_*, the whole
 * instrument, with the simulated HAL its browser emulator and PC tests share, hal/bm_hal_sim.c: 1 MiB NOR flash,
 * the framebuffer, the LEDs). tools/native_catalog/recipes/bubba.py compiles the sources tools/build.py lists for
 * the emulator (its SRC, CXX_SRC, CFLAGS, CXXFLAGS) natively; this file takes hal/web/hal_web.c's place and drives the
 * core as the FM-1 port does (hal/fm1/fm1_main.c): the audio render in 256-frame halves at the codec's 44118 Hz, the
 * UI loop (panel edges, MASTER, bm_app_tick) every 10 ms OS tick. The ids are the matrix's (the engine's wire order);
 * the output is the 24-bit DAC word (Q23) as 16 bits. */
#include <signal.h>
#include <stdint.h>
#include <string.h>

#include "bm_hal_sim.h"
#include "bm_app_int.h"

#define EXPORT __attribute__((used, visibility("default")))
#define HALF_FRAMES 256u
#define UI_MS 10u                               /* os_time_dly(1): one 10 ms tick of the SDK's OS */

static bm_sim sim;
static bm_app app;
static uint32_t now_ms;
static uint64_t frames;

static uint32_t edge_now(void) { return now_ms; }
static void edge_set(uint32_t i, uint32_t down);
#include "edges.h"
static void edge_set(uint32_t i, uint32_t down)
{
    if (i >= EDGE_KEY0) bm_app_key(&app, (int)(i - EDGE_KEY0), (int)down, now_ms);
    else bm_app_button(&app, (int)i, (int)down, now_ms);
}

static volatile int booted, debug_crash, debug_hang;
static int32_t blk[2u * HALF_FRAMES];
static uint32_t pos = HALF_FRAMES, ui_at, master_adc = 1023;

static void flash_setup(void)                   /* erased, once, before the engine hands back what it saved */
{
    static int done;
    if (!done) {
        done = 1;
        bm_sim_flash_erase_all(&sim);
    }
}

EXPORT int fm1c_init(void)
{
    bm_platform pf;
    if (booted) return -1;
    flash_setup();
    edges_init();
    bm_sim_platform(&sim, &pf);
    bm_app_init(&app, &pf, now_ms);
    bm_app_master(&app, (uint16_t)master_adc);
    bm_app_battery(&app, 100);
    booted = 1;
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return BM_FS_OUT; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i, j;
    for (i = 0; i < n; i++) {
        if (pos >= HALF_FRAMES) {
            if (debug_crash) raise(SIGSEGV);
            while (debug_hang)
                ;
            bm_app_audio(&app, blk, HALF_FRAMES);
            for (j = 0; j < 2u * HALF_FRAMES; j++) {
                int32_t v = blk[j] > 8388607 ? 8388607 : blk[j] < -8388608 ? -8388608 : blk[j];
                blk[j] = v >> 8;
            }
            pos = 0;
        }
        out[2u * i] = (int16_t)blk[2u * pos];
        out[2u * i + 1u] = (int16_t)blk[2u * pos + 1u];
        pos++;
        frames++;
        while ((uint64_t)now_ms * BM_FS_OUT < frames * 1000u) {
            now_ms++;
            edges_due();
            if (now_ms - ui_at >= UI_MS) {      /* the UI loop */
                ui_at = now_ms;
                bm_app_master(&app, (uint16_t)master_adc);
                sim.spi_bytes = 0;
                sim.midi_n = 0;                 /* (MIDI out: nobody listens) */
                bm_app_tick(&app, now_ms);
            }
        }
    }
}
EXPORT uint32_t fm1c_ms(void) { return now_ms; }
EXPORT void fm1c_master(uint32_t k10) { master_adc = (k10 > 1024u ? 1024u : k10) * 1023u / 1024u; }
EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < 27u) edge_in(EDGE_KEY0 + k, down); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) edge_in(b, down); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { if (e < 7u && steps) bm_app_encoder(&app, (int)e, steps, now_ms); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st < 0x80u || st >= 0xF0u) return;
    bm_app_midi_in(&app, (uint8_t)st);
    bm_app_midi_in(&app, (uint8_t)(d1 & 0x7Fu));
    if ((st & 0xE0u) != 0xC0u) bm_app_midi_in(&app, (uint8_t)(d2 & 0x7Fu));   /* (program/pressure: one data byte) */
}

EXPORT const uint16_t *fm1c_fb(void) { return sim.fb; }
EXPORT uint32_t fm1c_fb_hash(void) { return fnv_bytes(2166136261u, sim.fb, sizeof sim.fb); }
static uint32_t leds(uint32_t base, uint32_t n, int lit)
{
    uint32_t m = 0, i;
    for (i = 0; i < n; i++) {
        uint8_t v = sim.leds[base + i];
        if (lit ? v != LED_OFF && v != LED_DIM : v == LED_DIM) m |= 1u << i;
    }
    return m;
}
EXPORT uint32_t fm1c_leds_buttons(void) { return leds(0, 14u, 1); }
EXPORT uint32_t fm1c_leds_keys(void) { return leds(BM_LED_KEY0, 27u, 1); }
EXPORT uint32_t fm1c_glow_keys(void) { return leds(BM_LED_KEY0, 27u, 0); }

/* the 1 MiB flash (settings, patterns, takes) as one blob; it changes when the core writes it */
static uint32_t seen = ~0u, hash;
EXPORT uint32_t fm1c_blob_count(void) { return 1u; }
EXPORT uint32_t fm1c_blob_size(void) { flash_setup(); return BM_FLASH_SIZE; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { flash_setup(); return i == 0u ? sim.flash : 0; }
EXPORT uint32_t fm1c_store_hash(void)
{
    if (sim.flash_writes != seen) {
        seen = sim.flash_writes;
        hash = fnv_bytes(2166136261u, sim.flash, BM_FLASH_SIZE);
    }
    return hash;
}
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
