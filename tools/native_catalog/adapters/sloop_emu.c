/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from the SLOOP line's browser emulator (No Man Sky FM's firmware/wasm/nms_wasm.c, winampFM's
 * winampfm_wasm.c, hericdk's: the firmware's one unit, felucca.c's includes, after a browser HAL), run as its
 * AudioWorklet does: 128 frames a block, the main loop's UI pass (emu_frame) every sixth, emu_start once the
 * splash has shown (900 ms, the page's). Its pointer exports are wasm32 addresses, so this file includes the
 * emulator (FW_ENTRY: tools/native_catalog/recipes/wasm.py's "unity") and reads its framebuffer, audio, LEDs and
 * flash image directly. The panel is the FM-1's matrix ids (wire order), MASTER the pot's ADC (0..1023) the
 * firmware squares, the screen the panel's pixels as values, the LEDs the columns of the matrix (FM1_KEYMAP). */
#include <signal.h>
#include <stdint.h>

#include FW_ENTRY

#define EXPORT __attribute__((used, visibility("default")))
#define BLOCK 128u
#define SPLASH_MS 900u

static uint32_t emu_pos = BLOCK, emu_blocks, emu_started, emu_notes, emu_buttons;
static volatile int debug_crash, debug_hang;

EXPORT uint32_t fm1c_blob_count(void) { return 1u; }
EXPORT uint32_t fm1c_blob_size(void) { return EMU_FLASH_SIZE; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { return i == 0u ? emu_flash : 0; }
EXPORT uint32_t fm1c_store_hash(void) { return emu_flash_gen; }

EXPORT int fm1c_init(void)
{
    emu_adc_set(FM1_ADC_MASTER, 1023);           /* (MASTER at unity until the app sets it, as live.c) */
    emu_init();
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return FS; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i;
    for (i = 0; i < n; i++) {
        float a, b;
        if (emu_pos >= BLOCK) {
            if (debug_crash) raise(SIGSEGV);
            while (debug_hang)
                ;
            emu_render(BLOCK);
            emu_pos = 0;
            if (++emu_blocks % 6u == 0u)
                emu_frame();
            if (!emu_started && fm1_ms >= SPLASH_MS) {
                emu_started = 1;
                emu_start();
            }
        }
        a = emu_audio_f[2u * emu_pos] * 32768.0f;
        b = emu_audio_f[2u * emu_pos + 1u] * 32768.0f;
        out[2u * i] = (int16_t)(a > 32767.0f ? 32767 : a < -32768.0f ? -32768 : (int32_t)a);
        out[2u * i + 1u] = (int16_t)(b > 32767.0f ? 32767 : b < -32768.0f ? -32768 : (int32_t)b);
        emu_pos++;
    }
}
EXPORT uint32_t fm1c_ms(void) { return fm1_ms; }
EXPORT void fm1c_master(uint32_t k10) { emu_adc_set(FM1_ADC_MASTER, (int32_t)(k10 > 1023u ? 1023u : k10)); }
EXPORT void fm1c_key(uint32_t k, uint32_t down)
{
    if (k >= 27u) return;
    emu_notes = down ? emu_notes | 1u << k : emu_notes & ~(1u << k);
    emu_input(emu_notes, emu_buttons);
}
EXPORT void fm1c_button(uint32_t b, uint32_t down)
{
    if (b >= 14u) return;
    emu_buttons = down ? emu_buttons | 1u << b : emu_buttons & ~(1u << b);
    emu_input(emu_notes, emu_buttons);
}
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { emu_enc(e, steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st >= 0x80u && st < 0xF0u)               /* (a USB-MIDI event packet, as usb.c queues one) */
        emu_midi((st >> 4) | st << 8 | (d1 & 0x7Fu) << 16 | (d2 & 0x7Fu) << 24);
}
EXPORT const uint16_t *fm1c_fb(void) { return emu_fb; }
EXPORT uint32_t fm1c_fb_hash(void)
{
    uint32_t h = 2166136261u, i;
    for (i = 0; i < 240u * 240u; i++) h = (h ^ emu_fb[i]) * 16777619u;
    return h;
}
static uint32_t led_bits(const uint8_t *cols, int keys)   /* the LED columns back to ids (FM1_KEYMAP) */
{
    uint32_t c, r, v = 0;
    for (c = 0; c < FM1_NCOL; c++)
        for (r = 1; r < 5u; r++) {
            int32_t id = FM1_KEYMAP[r][c];
            if (id < 0 || !((cols[c] >> r) & 1u)) continue;
            if (keys && id >= 14) v |= 1u << (id - 14);
            if (!keys && id < 14) v |= 1u << id;
        }
    return v;
}
EXPORT uint32_t fm1c_leds_buttons(void) { return led_bits(fm1_led, 0); }
EXPORT uint32_t fm1c_leds_keys(void) { return led_bits(fm1_led, 1); }
EXPORT uint32_t fm1c_glow_keys(void) { return led_bits(fm1_led_dim, 1); }
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
