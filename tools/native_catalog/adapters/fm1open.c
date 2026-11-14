/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from M-VAVE's fm1_open browser simulator (web/engine/Simulator.c: the fm1.h SDK API over an
 * in-memory display, flash and MIDI, with the application's own C, app/ minus app/board, and the simulator's engine,
 * web/engine + web/synth + third_party/synth). The device links the instrument engine as a binary library
 * (sdk/lib/libfm1_engine.a); the simulator's is the C rendition in web/, so this is the simulator's sound.
 * tools/native_catalog/recipes/fm1open.py replays the native simulator build (tools/<app>/sim/native/Makefile, the
 * same sources as the WASM one) with this file in Simulator.c's place (it includes it): sim_render's 128-frame
 * blocks (Q23, the DAC's word, as 16 bits), the control poll every 10 ms inside it, the panel by physical id (the
 * engine's wire order), the flash as one blob. */
#include <signal.h>
#include <stdint.h>

#include FM1N_ENTRY                             /* web/engine/Simulator.c (its path: recipes/_entry.py) */

#define FM1N_EXPORT __attribute__((used, visibility("default")))

static uint32_t edge_now(void) { return now_ms; }
static void edge_set(uint32_t i, uint32_t down);
#include "edges.h"
static void edge_set(uint32_t i, uint32_t down)
{
    if (i >= EDGE_KEY0) sim_control(1, i - EDGE_KEY0, (int)down);
    else sim_control(0, i, (int)down);
}

static volatile int booted, debug_crash, debug_hang;
static int16_t blk[FM1_BLOCK_WORDS];
static uint32_t pos = FM1_BLOCK_FRAMES, knob = 1023;

FM1N_EXPORT int fm1c_init(void)
{
    uint32_t i, saved = 0;
    if (booted) return -1;
    for (i = 0; i < sizeof flash && !saved; i++) saved = flash[i] != 0;   /* (erased flash is 0xFF: all 0 = none) */
    sim_boot((saved ? 0u : 1u) | 2u);          /* (bit 1: the device's startup animation, as on power-on) */
    sim_control(3, 0, (int)knob);
    edges_init();
    booted = 1;
    return 0;
}
FM1N_EXPORT uint32_t fm1c_rate(void) { return FM1_SAMPLE_RATE; }
FM1N_EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i, j;
    for (i = 0; i < n; i++) {
        if (pos >= FM1_BLOCK_FRAMES) {
            if (debug_crash) raise(SIGSEGV);
            while (debug_hang)
                ;
            edges_due();
            sim_render();
            for (j = 0; j < FM1_BLOCK_WORDS; j++) {
                float v = output[j] * 32768.0f;
                blk[j] = (int16_t)(v > 32767.0f ? 32767 : v < -32768.0f ? -32768 : (int32_t)v);
            }
            pos = 0;
        }
        out[2u * i] = blk[2u * pos];
        out[2u * i + 1u] = blk[2u * pos + 1u];
        pos++;
    }
}
FM1N_EXPORT uint32_t fm1c_ms(void) { return now_ms; }
FM1N_EXPORT void fm1c_master(uint32_t k10)
{
    knob = (k10 > 1024u ? 1024u : k10) * 1023u / 1024u;
    if (booted) sim_control(3, 0, (int)knob);
}
FM1N_EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < 27u) edge_in(EDGE_KEY0 + k, down); }
FM1N_EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) edge_in(b, down); }
FM1N_EXPORT void fm1c_enc(uint32_t e, int32_t steps)
{
    int32_t v;
    if (e >= 7u || !steps) return;
    v = controls.encoders[e] + steps;           /* (detents since the app's last read) */
    sim_control(2, e, v > 127 ? 127 : v < -127 ? -127 : (int)v);
}
FM1N_EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st < 0x80u || st >= 0xF0u) return;
    file_buffer[0] = (uint8_t)st;
    file_buffer[1] = (uint8_t)(d1 & 0x7Fu);
    file_buffer[2] = (uint8_t)(d2 & 0x7Fu);
    sim_midi((st & 0xE0u) == 0xC0u ? 2u : 3u);
}

FM1N_EXPORT const uint16_t *fm1c_fb(void) { return pixels; }
FM1N_EXPORT uint32_t fm1c_fb_hash(void) { return fnv_bytes(2166136261u, pixels, sizeof pixels); }
static uint32_t lamps(uint32_t base, uint32_t n, uint8_t lo, uint8_t hi)
{
    uint32_t m = 0, i;
    for (i = 0; i < n; i++)
        if (leds[base + i] >= lo && leds[base + i] <= hi) m |= 1u << i;
    return m;
}
FM1N_EXPORT uint32_t fm1c_leds_buttons(void) { return lamps(0, 14u, 5, 8); }
FM1N_EXPORT uint32_t fm1c_leds_keys(void) { return lamps(14u, 27u, 5, 8); }
FM1N_EXPORT uint32_t fm1c_glow_keys(void) { return lamps(14u, 27u, 1, 4); }

static uint32_t seen = ~0u, hash;
FM1N_EXPORT uint32_t fm1c_blob_count(void) { return 1u; }
FM1N_EXPORT uint32_t fm1c_blob_size(void) { return sizeof flash; }
FM1N_EXPORT uint8_t *fm1c_blob(uint32_t i) { return i == 0u ? flash : 0; }
FM1N_EXPORT uint32_t fm1c_store_hash(void)
{
    if (flash_revision != seen) {
        seen = flash_revision;
        hash = fnv_bytes(2166136261u, flash, sizeof flash);
    }
    return hash;
}
FM1N_EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
