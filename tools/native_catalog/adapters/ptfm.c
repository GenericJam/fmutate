/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from PT/FM's emulator platform (emulator/plat_web.c with fw/core), built natively as its
 * author's own test builds it (WEB_NATIVE: fw/tests/web_native.c): the device's time runs as the audio is asked
 * for (a main-loop pass a millisecond when the loop is free, the audio interrupt every 256 frames, the FM-1's own
 * output stage), the panel in wire order (fw/core/plat.h: B_OCTM .. B_REC, K_SELECT K_ALG K_K1..4 K_PRESETS), the
 * screen as pixel values, the LEDs a level each (64 the UI's dim), the flash (1 MiB, NOR) one blob. */
#include <signal.h>
#include <stdint.h>
#include <time.h>

#define EXPORT __attribute__((used, visibility("default")))

uint8_t *web_flash_buf(void);
uint32_t web_flash_gen_get(void);
uint16_t *web_fb_buf(void);
uint8_t *web_leds_buf(void);
int32_t *web_out_buf(void);
uint32_t web_now_ms(void);
void web_flash_reset(void);
void web_init(void);
void web_render(uint32_t n);
void web_button(uint32_t id, uint32_t down);
void web_note(uint32_t n, uint32_t down);
void web_knob(uint32_t id, int32_t step);
void web_master_set(int32_t v);
int32_t web_midi_in(uint32_t b0, uint32_t b1, uint32_t b2, uint32_t src);

double web_clock_us(void)                        /* (plat_web.c's CPU figures: this machine's clock) */
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e6 + (double)t.tv_nsec / 1e3;
}

#define FLASH (1u << 20)
static int flash_ready;
static volatile int debug_crash, debug_hang;
static void flash_setup(void)                    /* a new FM-1's flash, before a kept image is put over it */
{
    if (!flash_ready) {
        flash_ready = 1;
        web_flash_reset();
    }
}
EXPORT uint32_t fm1c_blob_count(void) { return 1u; }
EXPORT uint32_t fm1c_blob_size(void) { return FLASH; }
EXPORT uint8_t *fm1c_blob(uint32_t i)
{
    flash_setup();
    return i == 0u ? web_flash_buf() : 0;
}
EXPORT uint32_t fm1c_store_hash(void) { return web_flash_gen_get(); }

EXPORT int fm1c_init(void)
{
    flash_setup();
    web_master_set(1023);                        /* (MASTER at unity until the app sets it, as live.c) */
    web_init();
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return 44100u; }
#define CHUNK 256u
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    while (n) {
        uint32_t k = n < CHUNK ? n : CHUNK, i;
        const int32_t *s;
        if (debug_crash) raise(SIGSEGV);
        while (debug_hang)
            ;
        web_render(k);
        s = web_out_buf();
        for (i = 0; i < 2u * k; i++) {         /* (the codec's 24-bit words) */
            int32_t v = s[i] >> 8;
            out[i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
        }
        out += 2u * k;
        n -= k;
    }
}
EXPORT uint32_t fm1c_ms(void) { return web_now_ms(); }
EXPORT void fm1c_master(uint32_t k10) { web_master_set((int32_t)(k10 > 1023u ? 1023u : k10)); }
EXPORT void fm1c_key(uint32_t k, uint32_t down) { web_note(k, down != 0u); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { web_button(b, down != 0u); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { web_knob(e, steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st >= 0x80u && st < 0xF0u) web_midi_in(st, d1, d2, 0u);
}
EXPORT const uint16_t *fm1c_fb(void) { return web_fb_buf(); }
EXPORT uint32_t fm1c_fb_hash(void)
{
    const uint16_t *p = web_fb_buf();
    uint32_t h = 2166136261u, i;
    for (i = 0; i < 240u * 240u; i++) h = (h ^ p[i]) * 16777619u;
    return h;
}
static uint32_t leds(uint32_t first, uint32_t n, int dim)
{
    const uint8_t *l = web_leds_buf();
    uint32_t v = 0, i;
    for (i = 0; i < n; i++)
        if (dim ? l[first + i] && l[first + i] < 128u : l[first + i] >= 128u) v |= 1u << i;
    return v;
}
EXPORT uint32_t fm1c_leds_buttons(void) { return leds(0u, 14u, 0); }
EXPORT uint32_t fm1c_leds_keys(void) { return leds(14u, 27u, 0); }
EXPORT uint32_t fm1c_glow_keys(void) { return leds(14u, 27u, 1); }
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
