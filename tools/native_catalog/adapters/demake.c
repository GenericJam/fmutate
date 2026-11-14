/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from Demake's browser build (InigoHernandez/demake-synth web/dmk_web.c: the firmware's
 * platform-free core, firmware/src/dmk_core.c, and the exports its AudioWorklet calls). This file includes that
 * entry (tools/native_catalog/recipes/demake.py compiles it with the flags web/build.sh gives emcc) and maps the core
 * to the fm1c_* calls of native/engine/live.c, as the FM-1 build (firmware/fm1/dmk_fm1.c) drives it: the panel in the
 * core's order (dmk.h: B_FX .. B_REC, B_OCTD, B_OCTU; E_SELECT, E_ALGO, E_PRESET, E_K1..K4), the sound in DMK_SUB
 * blocks with the MASTER knob after it at the DAC's level (half of Q15 full scale, as fm1-emu plays it), the screen drawn ~30 times a second (4 bits a pixel, 16 colours). */
#include <signal.h>
#include <stdint.h>
#include <string.h>

#include FM1N_ENTRY                     /* web/dmk_web.c (its path: recipes/_entry.py) */

#define EXPORT __attribute__((used, visibility("default")))

static uint32_t edge_now(void) { return (uint32_t)((uint64_t)dmk_samples() * 1000u / DMK_SR); }
static void edge_set(uint32_t i, uint32_t down);
#include "edges.h"

/* wire order (0 OCT- 1 OCT+ 2 FX ... 13 REC) -> the core's; encoders 0 SELECT 1 ALGORITHM 2-5 KNOB1-4 6 PRESETS */
static int button_of(uint32_t i) { return i == 0u ? B_OCTD : i == 1u ? B_OCTU : (int)i - 2; }
static const uint8_t ENC_OF[7] = {E_SELECT, E_ALGO, E_K1, E_K2, E_K3, E_K4, E_PRESET};
static void edge_set(uint32_t i, uint32_t down)
{
    if (i >= EDGE_KEY0) dmk_key((int)(i - EDGE_KEY0), (int)down);
    else dmk_button(button_of(i), (int)down);
}

static volatile int booted, debug_crash, debug_hang;
static int32_t master_q12 = 4096;
static uint16_t fb_native[DMK_W * DMK_H];
static uint32_t frame_at, store_seen = ~0u, store_hash;

static void draw(void)
{
    const uint8_t *f = dmk_frame(edge_now());
    const uint16_t *pal = dmk_palette565();
    uint32_t i;
    frame_at = edge_now();
    for (i = 0; i < DMK_FB_BYTES; i++) {
        fb_native[2u * i] = pal[f[i] >> 4];
        fb_native[2u * i + 1u] = pal[f[i] & 15u];
    }
}

EXPORT int fm1c_init(void)
{
    if (booted) return -1;
    dmk_store_read = ws_read;                   /* (the store the engine loaded into fm1c_blob(0)) */
    dmk_store_write = ws_write;
    edges_init();
    dmk_init(1u);
    edges_init();
    draw();
    booted = 1;
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return DMK_SR; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    static int16_t blk[DMK_SUB * 2];
    static uint32_t pos = DMK_SUB;
    uint32_t i;
    for (i = 0; i < n; i++) {
        if (pos >= DMK_SUB) {
            uint32_t j;
            if (debug_crash) raise(SIGSEGV);
            while (debug_hang)
                ;
            edges_due();
            dmk_render(blk, DMK_SUB);
            for (j = 0; j < 2u * DMK_SUB; j++) {
                int32_t v = (blk[j] * master_q12) >> 13;   /* (the DAC's level: Q15 << 7 in 24 bits, / 2 as 16) */
                blk[j] = (int16_t)(v > 32767 ? 32767 : v < -32767 ? -32767 : v);
            }
            pos = 0;
            if (edge_now() - frame_at >= 33u) draw();
        }
        out[2u * i] = blk[2u * pos];
        out[2u * i + 1u] = blk[2u * pos + 1u];
        pos++;
    }
}
EXPORT uint32_t fm1c_ms(void) { return edge_now(); }
EXPORT void fm1c_master(uint32_t k10)
{
    if (k10 > 1024u) k10 = 1024u;
    master_q12 = (int32_t)((k10 * k10) >> 8);
}
EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < 27u) edge_in(EDGE_KEY0 + k, down); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) edge_in(b, down); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { if (e < 7u && steps) dmk_encoder(ENC_OF[e], steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st >= 0x80u && st != 0xF0u && st != 0xF7u) dmk_midi((int)st, (int)(d1 & 0x7Fu), (int)(d2 & 0x7Fu));
}

EXPORT const uint16_t *fm1c_fb(void) { return fb_native; }
EXPORT uint32_t fm1c_fb_hash(void) { return fnv_bytes(2166136261u, fb_native, sizeof fb_native); }
/* the LEDs: 27 keys then 14 buttons (the core's order), 0..255: lit from half up, glowing below */
static uint32_t leds_of(uint32_t base, uint32_t n, int lit, const int *order)
{
    const uint8_t *l = dmk_leds();
    uint32_t m = 0, i;
    for (i = 0; i < n; i++) {
        uint8_t v = l[base + (order ? (uint32_t)order[i] : i)];
        if (lit ? v >= 128u : v && v < 128u) m |= 1u << i;
    }
    return m;
}
static const int BTN_ORDER[14] = {B_OCTD, B_OCTU, B_FX, B_SEL, B_ENV, B_LFO, B_EDIT, B_GLO, B_HOME, B_SAVE, B_ARP,
                                  B_SEQ, B_PLAY, B_REC};
EXPORT uint32_t fm1c_leds_buttons(void) { return leds_of(DMK_KEYS, 14u, 1, BTN_ORDER); }
EXPORT uint32_t fm1c_leds_keys(void) { return leds_of(0, DMK_KEYS, 1, 0); }
EXPORT uint32_t fm1c_glow_keys(void) { return leds_of(0, DMK_KEYS, 0, 0); }

/* the store: Demake's 64 KiB of songs and sounds, one blob */
EXPORT uint32_t fm1c_blob_count(void) { return 1u; }
EXPORT uint32_t fm1c_blob_size(void) { return sizeof store; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { return i == 0u ? store : 0; }
EXPORT uint32_t fm1c_store_hash(void)
{
    if (store_gen != store_seen) {
        store_seen = store_gen;
        store_hash = fnv_bytes(2166136261u, store, sizeof store);
    }
    return store_hash;
}
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
