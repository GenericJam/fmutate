/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from GATOR's host simulator (npi3pak/fm1-gator host/sim.c + host/host_hal.h: the app,
 * firmware/apps/<app>/app.c, with the platform's own C, against a stub HAL; tools/sim.py builds it). This file is the
 * simulator's main unit in our build: it includes host/sim.c (its main() renamed away) and drives the app as the
 * firmware's main loop does (firmware/sys/main.c, audio.c): app_audio in FW_BLOCK blocks at the codec's rate (FW_FS,
 * 48 kHz by default), the clock fm1_ms from the samples, app_frame every FW_FRAME_MS with the panel read in; the
 * output at the DAC's level (Q15 << 7 in 24 bits: half of full scale as 16 bits, as fm1-emu plays it). The matrix ids (buttons, encoders, LEDs) are the engine's wire order. */
#include <signal.h>
#include <stdint.h>

#define main fm1n_gator_sim_main
#include FM1N_ENTRY                     /* host/sim.c (its path: recipes/_entry.py) */
#undef main

#define EXPORT __attribute__((used, visibility("default")))
#ifndef FW_FRAME_MS
#define FW_FRAME_MS 15u                         /* firmware/sys/main.c */
#endif

static uint64_t samples;
static uint32_t edge_now(void) { return fm1_ms; }
static void edge_set(uint32_t i, uint32_t down);
#include "edges.h"
static void edge_set(uint32_t i, uint32_t down)
{
    if (i >= EDGE_KEY0) host_key(i - EDGE_KEY0, (int)down);
    else {                                      /* (host_button's, by matrix id) */
        uint32_t bit = FW_BIT(i);
        if (down && !(fm1_in.buttons & bit)) fm1_in.pressed |= bit;
        if (!down && (fm1_in.buttons & bit)) fm1_in.released |= bit;
        fm1_in.buttons = down ? fm1_in.buttons | bit : fm1_in.buttons & ~bit;
    }
}

static volatile int booted, debug_crash, debug_hang;
static int32_t blk[2u * FW_BLOCK];
static uint32_t pos = FW_BLOCK, frame_ms;

static void block(void)
{
    uint32_t i;
    app_audio(blk, FW_BLOCK);
    for (i = 0; i < 2u * FW_BLOCK; i++)         /* audio.c: clipped to Q15, << 7 into the 24-bit DAC; as 16 bits, / 2 */
        blk[i] = (blk[i] > 32767 ? 32767 : blk[i] < -32768 ? -32768 : blk[i]) >> 1;
}
static void pass_ms(void)                       /* a millisecond: the panel, then the main loop if a frame is due */
{
    fw_input_t in;
    fm1_ms++;
    edges_due();
    if (fm1_ms - frame_ms >= FW_FRAME_MS) {
        frame_ms = fm1_ms;
        fw_input_read(&in);
        app_frame(&in);
    }
}

/* storage: a blob per slot, [length: u32][FW_STORE_MAX] */
#define BLOB_SZ (4u + FW_STORE_MAX)
static uint8_t blobs[FW_STORE_SLOTS][BLOB_SZ];
static void blobs_from_fw(void)
{
    uint32_t s;
    for (s = 0; s < FW_STORE_SLOTS; s++) {
        memcpy(blobs[s], &host_store_len[s], 4);
        memcpy(blobs[s] + 4, host_store[s], FW_STORE_MAX);
    }
}

EXPORT int fm1c_init(void)
{
    uint32_t s;
    if (booted) return -1;
    for (s = 0; s < FW_STORE_SLOTS; s++) {      /* (what the engine loaded) */
        uint32_t len;
        memcpy(&len, blobs[s], 4);
        host_store_len[s] = len <= FW_STORE_MAX ? len : 0;
        memcpy(host_store[s], blobs[s] + 4, FW_STORE_MAX);
    }
    edges_init();
    lcd_init();
    app_init();
    frame_ms = fm1_ms;
    booted = 1;
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return FW_FS; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i;
    for (i = 0; i < n; i++) {
        if (pos >= FW_BLOCK) {
            if (debug_crash) raise(SIGSEGV);
            while (debug_hang)
                ;
            block();
            pos = 0;
        }
        out[2u * i] = (int16_t)blk[2u * pos];
        out[2u * i + 1u] = (int16_t)blk[2u * pos + 1u];
        pos++;
        samples++;
        while ((uint64_t)fm1_ms * FW_FS < samples * 1000u) pass_ms();
    }
}
EXPORT uint32_t fm1c_ms(void) { return fm1_ms; }
EXPORT void fm1c_master(uint32_t k10) { host_adc_master = (int32_t)((k10 > 1024u ? 1024u : k10) * 1023u / 1024u); }
EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < 27u) edge_in(EDGE_KEY0 + k, down); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) edge_in(b, down); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { if (e < 7u) fm1_in.enc_steps[e] += (int16_t)steps; }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st >= 0x80u && st < 0xF0u) host_midi(st, d1 & 0x7Fu, d2 & 0x7Fu);
}

EXPORT const uint16_t *fm1c_fb(void) { return host_fb; }
EXPORT uint32_t fm1c_fb_hash(void) { return fnv_bytes(2166136261u, host_fb, sizeof host_fb); }
EXPORT uint32_t fm1c_leds_buttons(void) { return (uint32_t)(host_leds & 0x3FFFu); }
EXPORT uint32_t fm1c_leds_keys(void) { return (uint32_t)(host_leds >> 14) & 0x7FFFFFFu; }
EXPORT uint32_t fm1c_glow_keys(void) { return 0; }
EXPORT uint32_t fm1c_blob_count(void) { return FW_STORE_SLOTS; }
EXPORT uint32_t fm1c_blob_size(void) { return BLOB_SZ; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { return i < FW_STORE_SLOTS ? blobs[i] : 0; }
EXPORT uint32_t fm1c_store_hash(void)
{
    if (booted) blobs_from_fw();
    return fnv_bytes(2166136261u, blobs, sizeof blobs);
}
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
