/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from Adrift's browser emulator backend (romainguy/adrift src/platform/platform_web.c: the
 * platform API of src/platform/platform.h over a simulated FM-1, compiled with the core modules by build.sh web).
 * This file includes it (tools/native_catalog/recipes/adrift.py replays build.sh's compiles natively, the backend's
 * freestanding memcpy / memmove / memset renamed out of the C library's way) and drives it as the FM-1 backend
 * (platform_fm1.c) does: 64-frame audio blocks at 44118 Hz (16-bit PCM, which the DAC takes as << 8: the same level
 * as 16 bits), the UI tick every 16 ms, the panel's hardware ids in wire order. */
#include <signal.h>
#include <stdint.h>

#include FM1N_ENTRY                             /* src/platform/platform_web.c (its path: recipes/_entry.py) */

#define EXPORT __attribute__((used, visibility("default")))
#define UI_MS 16u                               /* platform_fm1.c's main loop */

static uint64_t frames;
static uint32_t now_ms, ui_at;
static uint32_t edge_now(void) { return now_ms; }
static void edge_set(uint32_t i, uint32_t down);
#include "edges.h"
static void edge_set(uint32_t i, uint32_t down)
{
    if (i >= EDGE_KEY0) adrift_web_panel_key((uint8_t)(i - EDGE_KEY0), (uint8_t)down, 100u);
    else adrift_web_hw_button((uint8_t)i, (uint8_t)down);
}
/* wire encoders (0 SELECT 1 ALGORITHM 2-5 KNOB1-4 6 PRESETS) -> platform.h's */
static const uint8_t ENC_OF[7] = {ADRIFT_ENC_SELECT, ADRIFT_ENC_ALGORITHM, ADRIFT_ENC_KNOB1, ADRIFT_ENC_KNOB2,
                                  ADRIFT_ENC_KNOB3, ADRIFT_ENC_KNOB4, ADRIFT_ENC_PRESETS};

static volatile int booted, debug_crash, debug_hang;
static int32_t master_pot = 1023;
static uint32_t pos = ADRIFT_BLOCK_SIZE;

EXPORT int fm1c_init(void)
{
    if (booted) return -1;
    ensure_web_flash();
    edges_init();
    adrift_web_init();
    adrift_web_set_master_pot(master_pot);
    adrift_web_tick_ui(0);
    booted = 1;
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return ADRIFT_SAMPLE_RATE; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i;
    for (i = 0; i < n; i++) {
        if (pos >= ADRIFT_BLOCK_SIZE) {
            if (debug_crash) raise(SIGSEGV);
            while (debug_hang)
                ;
            adrift_web_render_audio(ADRIFT_BLOCK_SIZE);
            pos = 0;
        }
        out[2u * i] = g_pcm_i16[2u * pos];
        out[2u * i + 1u] = g_pcm_i16[2u * pos + 1u];
        pos++;
        frames++;
        while ((uint64_t)now_ms * ADRIFT_SAMPLE_RATE < frames * 1000u) {
            now_ms++;
            edges_due();
            if (now_ms - ui_at >= UI_MS) {
                ui_at = now_ms;
                adrift_web_tick_ui(0);
            }
        }
    }
}
EXPORT uint32_t fm1c_ms(void) { return now_ms; }
EXPORT void fm1c_master(uint32_t k10)
{
    master_pot = (int32_t)((k10 > 1024u ? 1024u : k10) * 1023u / 1024u);
    adrift_web_set_master_pot(master_pot);
}
EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < 27u) edge_in(EDGE_KEY0 + k, down); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) edge_in(b, down); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { if (e < 7u && steps) adrift_web_enc_delta(ENC_OF[e], steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st >= 0x80u && st < 0xF0u) adrift_web_push_midi((uint8_t)st, (uint8_t)(d1 & 0x7Fu), (uint8_t)(d2 & 0x7Fu));
}

EXPORT const uint16_t *fm1c_fb(void) { return g_rgb565_fb; }
EXPORT uint32_t fm1c_fb_hash(void) { return fnv_bytes(2166136261u, g_rgb565_fb, sizeof g_rgb565_fb); }
EXPORT uint32_t fm1c_leds_buttons(void) { return adrift_web_leds_buttons() & 0x3FFFu; }
EXPORT uint32_t fm1c_leds_keys(void) { return adrift_web_leds_keys() & 0x7FFFFFFu; }
EXPORT uint32_t fm1c_glow_keys(void) { return 0; }

/* the user presets' flash slots, one blob */
static uint32_t hash, hashed;
EXPORT uint32_t fm1c_blob_count(void) { return 1u; }
EXPORT uint32_t fm1c_blob_size(void) { return ADRIFT_WEB_FLASH_BYTES; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { ensure_web_flash(); return i == 0u ? &g_web_flash[0][0] : 0; }
EXPORT uint32_t fm1c_store_hash(void)
{
    if (!hashed || adrift_web_take_storage_dirty()) {
        hashed = 1;
        hash = fnv_bytes(2166136261u, g_web_flash, sizeof g_web_flash);
    }
    return hash;
}
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
