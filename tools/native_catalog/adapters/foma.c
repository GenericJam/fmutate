/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from the foma framework's emulator (konsumer/fomajam's platform/web.c, Spellbox's: the API of
 * fm1.h over a simulated FM-1, which the firmware's tools/build.py compiles with the app to WebAssembly). Its exports:
 *
 *   web_boot(); web_render(n), web_out_l/r()   the device runs until n frames exist (float, the DAC's level)
 *   web_keys(mask), web_buttons(mask)          held, in wire order (BTN_OCT_DOWN = 0 ... BTN_REC = 13)
 *   web_encoder(e, n)                          wire order (ENC_SELECT, ENC_ALGORITHM, ENC_KNOB1..4, ENC_PRESETS)
 *   web_master(0..1023), web_led_keys/buttons(), web_fb() (RGB565 byte-swapped, as the panel takes it)
 *   web_midi_in(st, d1, d2), web_store()/_len/_set_len/_gen (settings), web_flash()/_len/_gen (the store)
 *
 * tools/native_catalog/recipes/foma.py compiles platform/web.c and the app natively (the build's own flags) and
 * links this in front: the fm1c_* calls of native/engine/live.c. The panel's order is the engine's already.
 * Storage: one blob, [settings length: i32][settings: SETTINGS_MAX][the store's flash, if it has one]. */
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fm1.h"

#define EXPORT __attribute__((used, visibility("default")))

void web_boot(void);
void web_render(uint32_t n);
float *web_out_l(void);
float *web_out_r(void);
void web_keys(uint32_t m);
void web_buttons(uint32_t m);
void web_encoder(int e, int32_t n);
void web_master(uint32_t v);
uint32_t web_led_keys(void);
uint32_t web_led_buttons(void);
uint16_t *web_fb(void);
void web_midi_in(uint32_t st, uint32_t d1, uint32_t d2);
uint8_t *web_store(void);
int32_t web_store_len(void);
void web_store_set_len(int32_t n);
uint32_t web_store_gen(void);
#if FOMA_HAS_FLASH                                  /* (-DFOMA_HAS_FLASH=1: the emulator has the store's flash) */
uint8_t *web_flash(void);
uint32_t web_flash_len(void);
uint32_t web_flash_gen(void);
#else
static uint8_t *web_flash(void) { return 0; }
static uint32_t web_flash_len(void) { return 0; }
static uint32_t web_flash_gen(void) { return 0; }
#endif
uint32_t web_now(void);

static uint32_t edge_now(void) { return web_now(); }
static void edge_set(uint32_t i, uint32_t down);
#include "edges.h"
static void edge_set(uint32_t i, uint32_t down)
{
    edge_masks(i, down);
    if (i >= EDGE_KEY0) web_keys(edge_keys);
    else web_buttons(edge_buttons);
}

static volatile int booted, debug_crash, debug_hang;

/* ---- storage */
static uint8_t *blob;
static uint32_t blob_sz, seen_settings = ~0u, seen_flash = ~0u;
static void blob_setup(void)
{
    if (blob) return;
    blob_sz = 4u + SETTINGS_MAX + web_flash_len();
    blob = (uint8_t *)calloc(1, blob_sz);
    if (!blob) return;
    {
        int32_t len = web_store_len();
        memcpy(blob, &len, 4);
    }
    memcpy(blob + 4, web_store(), SETTINGS_MAX);
    if (web_flash_len()) memcpy(blob + 4 + SETTINGS_MAX, web_flash(), web_flash_len());
}
EXPORT uint32_t fm1c_blob_count(void) { return 1u; }
EXPORT uint32_t fm1c_blob_size(void) { blob_setup(); return blob_sz; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { blob_setup(); return i == 0u ? blob : 0; }
EXPORT uint32_t fm1c_store_hash(void)
{
    blob_setup();
    if (!blob) return 0;
    if (web_store_gen() != seen_settings) {
        int32_t len = web_store_len();
        seen_settings = web_store_gen();
        memcpy(blob, &len, 4);
        memcpy(blob + 4, web_store(), SETTINGS_MAX);
    }
    if (web_flash_len() && web_flash_gen() != seen_flash) {
        seen_flash = web_flash_gen();
        memcpy(blob + 4 + SETTINGS_MAX, web_flash(), web_flash_len());
    }
    return fnv_bytes(2166136261u, blob, blob_sz);
}

/* ---- life */
EXPORT int fm1c_init(void)
{
    int32_t len;
    if (booted) return -1;
    blob_setup();
    if (blob) {                                     /* (what the engine loaded, back into the firmware) */
        memcpy(&len, blob, 4);
        web_store_set_len(len >= 0 && len <= (int32_t)SETTINGS_MAX ? len : -1);
        memcpy(web_store(), blob + 4, SETTINGS_MAX);
        if (web_flash_len()) memcpy(web_flash(), blob + 4 + SETTINGS_MAX, web_flash_len());
    }
    edges_init();
    web_master(1023u);                              /* (MASTER up until the engine sets it, as live.c) */
    web_boot();
    booted = 1;
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return SAMPLE_RATE; }
#define CHUNK 64u
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    while (n) {
        uint32_t k = n < CHUNK ? n : CHUNK, i;
        const float *l, *r;
        if (debug_crash) raise(SIGSEGV);
        while (debug_hang)
            ;
        edges_due();
        web_render(k);
        l = web_out_l();
        r = web_out_r();
        for (i = 0; i < k; i++) {
            float a = l[i] * 32767.0f, b = r[i] * 32767.0f;
            out[2u * i] = (int16_t)(a > 32767.0f ? 32767 : a < -32767.0f ? -32767 : (int32_t)a);
            out[2u * i + 1u] = (int16_t)(b > 32767.0f ? 32767 : b < -32767.0f ? -32767 : (int32_t)b);
        }
        out += 2u * k;
        n -= k;
    }
}
EXPORT uint32_t fm1c_ms(void) { return web_now(); }
EXPORT void fm1c_master(uint32_t k10) { web_master((k10 > 1024u ? 1024u : k10) * 1023u / 1024u); }
EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < 27u) edge_in(EDGE_KEY0 + k, down); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) edge_in(b, down); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { if (e < 7u) web_encoder((int)e, steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st >= 0x80u && st < 0xF0u) web_midi_in(st, d1 & 0x7Fu, d2 & 0x7Fu);
}

/* ---- what the panel shows */
static uint16_t fb_out[240u * 240u];
EXPORT const uint16_t *fm1c_fb(void)
{
    const uint16_t *p = web_fb();
    uint32_t i;
    for (i = 0; i < 240u * 240u; i++) fb_out[i] = (uint16_t)(p[i] >> 8 | p[i] << 8);
    return fb_out;
}
EXPORT uint32_t fm1c_fb_hash(void) { return fnv_bytes(2166136261u, web_fb(), 240u * 240u * 2u); }
EXPORT uint32_t fm1c_leds_buttons(void) { return web_led_buttons() & 0x3FFFu; }
EXPORT uint32_t fm1c_leds_keys(void) { return web_led_keys() & 0x7FFFFFFu; }
EXPORT uint32_t fm1c_glow_keys(void) { return 0; }
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
