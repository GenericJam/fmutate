/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from Veffbox's web emulator (host/emu.c on host/vb_host.h: fw/vb_app.c and core/ with MNM-1's
 * gfx.c, against the FM-1 as host state), driven as the FM-1's main loop drives the app (fw/veffbox.c): the audio
 * interrupt's 32-frame blocks with the MASTER knob (vb_master, k10 * k10 >> 8), a UI pass every 15 ms (input, LEDs,
 * the screen's strips; four strips a pass, as the emulator's frame). The emulator's own exports give mono and
 * buttons only, so this file includes it (FW_ENTRY: tools/native_catalog/recipes/wasm.py's "unity") and takes the
 * stereo blocks and the LEDs itself. Panel: the wire's ids to Veffbox's (its B_* are the printed labels, its
 * encoders SELECT ALGORITHM PRESETS K1..K4), then its panel map, as emu_button / emu_encoder do. */
#include <signal.h>
#include <stdint.h>

#include FW_ENTRY
#undef __attribute__

#define EXPORT __attribute__((used, visibility("default")))
#define UI_MS 15u

static const uint8_t LABEL_OF_WIRE[14] = {12, 13, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
static const uint8_t ENC_OF_WIRE[7] = {0, 1, 3, 4, 5, 6, 2};
static int32_t blk[2u * CTL];
static uint32_t pos = CTL, frames, next_ui;
static volatile int debug_crash, debug_hang;

static uint32_t now_ms(void) { return 1000u + (uint32_t)((uint64_t)frames * 1000u / 44100u); }

EXPORT uint32_t fm1c_blob_count(void) { return 1u; }
EXPORT uint32_t fm1c_blob_size(void) { return sizeof host_flash; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { return i == 0u ? host_flash : 0; }
EXPORT uint32_t fm1c_store_hash(void) { return host_flash_writes; }

EXPORT int fm1c_init(void)
{
    uint32_t i, blank = 1;
    for (i = 0; i < sizeof host_flash && blank; i++)
        blank = host_flash[i] == 0;
    vb_master_q12 = (1023u * 1023u) >> 8;        /* (MASTER at unity until the app sets it, as live.c) */
    emu_init(!blank);                            /* (nothing kept: the flash erased) */
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return 44100u; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i, c;
    for (i = 0; i < n; i++) {
        if (pos >= CTL) {
            if (debug_crash) raise(SIGSEGV);
            while (debug_hang)
                ;
            vb_audio_block(blk, CTL);
            vb_master(blk, CTL);
            pos = 0;
            if ((int32_t)(now_ms() - next_ui) >= 0) {
                next_ui = now_ms() + UI_MS;
                emu_frame(now_ms());
            }
        }
        for (c = 0; c < 2u; c++) {
            int32_t v = blk[2u * pos + c];
            out[2u * i + c] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
        }
        pos++;
        frames++;
    }
}
EXPORT uint32_t fm1c_ms(void) { return now_ms(); }
EXPORT void fm1c_master(uint32_t k10)
{
    if (k10 > 1023u) k10 = 1023u;
    vb_master_q12 = (k10 * k10) >> 8;
}
EXPORT void fm1c_key(uint32_t k, uint32_t down) { emu_key(k, down != 0u); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) emu_button(LABEL_OF_WIRE[b], down != 0u); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { if (e < 7u) emu_encoder(ENC_OF_WIRE[e], (int)steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st < 0x80u || st >= 0xF0u || mi_w - mi_r >= MQ) return;
    midi_in_ms[mi_w % MQ] = fm1_ms;              /* (a USB-MIDI event packet, as usb.c queues one) */
    midi_in_q[mi_w++ % MQ] = (st >> 4) | st << 8 | (d1 & 0x7Fu) << 16 | (d2 & 0x7Fu) << 24;
}
EXPORT const uint16_t *fm1c_fb(void) { return fb; }
EXPORT uint32_t fm1c_fb_hash(void)
{
    uint32_t h = 2166136261u, i;
    for (i = 0; i < 240u * 240u; i++) h = (h ^ fb[i]) * 16777619u;
    return h;
}
EXPORT uint32_t fm1c_leds_buttons(void)
{
    uint32_t v = 0, w;
    for (w = 0; w < 14u; w++)
        if (emu_led(LABEL_OF_WIRE[w])) v |= 1u << w;
    return v;
}
EXPORT uint32_t fm1c_leds_keys(void) { return 0u; }
EXPORT uint32_t fm1c_glow_keys(void) { return 0u; }
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
