/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from Guitchordi's simulator build (stoogs/guitchordi scripts/build-simulator.sh: the
 * platform-free app, firmware/app.c and dsp/engine.c, with its fw_* exports). tools/native_catalog/recipes/guitchordi.py
 * compiles those natively as the script does and links this in front: the fm1c_* calls, driving the app as the FM-1
 * build does (firmware/fm1/main.c): every 128-frame half the panel's state in (buttons and encoders in the app's
 * roles: FX SEL ENV LFO EDIT GLO HOME SAVE ARP SEQ PLAY REC OCT- OCT+; SELECT ALGO PRESET K1..K4), fw_render's mono
 * float to both channels at the DAC's level (audio-output.h: sample * GM_DAC_LIMIT, 24-bit), the MASTER knob as
 * fw_master 0..100. The device keeps nothing in flash and ignores MIDI, so neither do we. */
#include <signal.h>
#include <stdint.h>
#include <string.h>

#include "app.h"

#define EXPORT __attribute__((used, visibility("default")))
#define FS 44100u
#define HALF_FRAMES 128u
#define GM_DAC_LIMIT 629144                     /* firmware/fm1/audio-output.h */

static uint64_t frames;
static uint32_t edge_now(void) { return (uint32_t)(frames * 1000u / FS); }
static void edge_set(uint32_t i, uint32_t down);
#include "edges.h"
static void edge_set(uint32_t i, uint32_t down) { edge_masks(i, down); }

/* wire order (0 OCT- 1 OCT+ 2 FX ... 13 REC) <- the app's role r is wire ROLE_WIRE[r]; encoders likewise */
static const uint8_t ROLE_WIRE[14] = {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 0, 1};
static const uint8_t ENC_ROLE[7] = {0, 1, 3, 4, 5, 6, 2};     /* wire encoder -> the app's role */

static volatile int booted, debug_crash, debug_hang;
static uint32_t master = 100, master_set = ~0u;
static int16_t blk[2u * HALF_FRAMES];
static uint32_t pos = HALF_FRAMES;

static void half(void)
{
    uint32_t r, i;
    const float *s;
    edges_due();
    fw_keys(edge_keys);
    for (r = 0; r < 14u; r++) fw_button((int)r, (int)(edge_buttons >> ROLE_WIRE[r] & 1u));
    if (master != master_set) fw_master((int)(master_set = master));
    s = fw_render(HALF_FRAMES);
    for (i = 0; i < HALF_FRAMES; i++) {
        float v = s ? s[i] : 0.0f;
        int32_t q = master && v >= -1.0f && v <= 1.0f ? (int32_t)(v * (float)GM_DAC_LIMIT) / 256 : 0;
        blk[2u * i] = blk[2u * i + 1u] = (int16_t)q;
    }
    frames += HALF_FRAMES;
}

EXPORT int fm1c_init(void)
{
    if (booted) return -1;
    edges_init();
    fw_boot();
    fw_master(0);
    booted = 1;
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return FS; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i;
    for (i = 0; i < n; i++) {
        if (pos >= HALF_FRAMES) {
            if (debug_crash) raise(SIGSEGV);
            while (debug_hang)
                ;
            half();
            pos = 0;
        }
        out[2u * i] = blk[2u * pos];
        out[2u * i + 1u] = blk[2u * pos + 1u];
        pos++;
    }
}
EXPORT uint32_t fm1c_ms(void) { return edge_now(); }
EXPORT void fm1c_master(uint32_t k10) { master = (k10 > 1024u ? 1024u : k10) * 100u / 1024u; }
EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < 27u) edge_in(EDGE_KEY0 + k, down); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) edge_in(b, down); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { if (e < 7u && steps) fw_encoder(ENC_ROLE[e], steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2) { (void)st, (void)d1, (void)d2; }

EXPORT const uint16_t *fm1c_fb(void) { return fw_frame(); }
EXPORT uint32_t fm1c_fb_hash(void) { return fnv_bytes(2166136261u, fw_frame(), 240u * 240u * 2u); }
EXPORT uint32_t fm1c_leds_buttons(void)
{
    uint32_t act = fw_buttons(), w = 0, r;
    for (r = 0; r < 14u; r++)
        if (act >> r & 1u) w |= 1u << ROLE_WIRE[r];
    return w;
}
static uint32_t keys_at(int lo, int hi)
{
    uint32_t m = 0, k;
    for (k = 0; k < 27u; k++) {
        int b = fw_key_brightness((int)k);
        if (b >= lo && b < hi) m |= 1u << k;
    }
    return m;
}
EXPORT uint32_t fm1c_leds_keys(void) { return keys_at(80, 1 << 30); }     /* full and medium, as main.c */
EXPORT uint32_t fm1c_glow_keys(void) { return keys_at(1, 80); }          /* its faint ones */
EXPORT uint32_t fm1c_blob_count(void) { return 0; }
EXPORT uint32_t fm1c_blob_size(void) { return 0; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { (void)i; return 0; }
EXPORT uint32_t fm1c_store_hash(void) { return 0; }
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
