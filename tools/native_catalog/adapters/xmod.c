/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from XMOD's browser simulator (host/websim.c: the FM-1's pages, firmware/pages.c, with the
 * player and the flash song slots; the songs/ files built in), run as web/sim.html runs it: a page frame every
 * 20 ms with the input since the last (presses, releases, held; notes pressed, held), the player's audio between.
 * The panel ids are the wire's (pages.c: BTN_OCTDN .. BTN_REC, ENC_SELECT ALGO K1..K4 PRESET), MASTER the
 * device's square law (firmware/audio.c: k * k >> 8, Q12, applied here as its audio interrupt does), the screen
 * as values, the LEDs 41 bytes, the song slots' flash one blob. */
#include <signal.h>
#include <stdint.h>

#define EXPORT __attribute__((used, visibility("default")))

const uint16_t *sim_fb(void);
const uint8_t *sim_leds(void);
uint8_t *sim_flash_ptr(void);
uint32_t sim_flash_size(void);
uint32_t sim_flash_writes(void);
void sim_flash_clear(void);
void sim_init(uint32_t rate, uint32_t play);
void sim_input(uint32_t pressed, uint32_t released, uint32_t held, uint32_t notes, uint32_t notes_held);
void sim_enc(uint32_t i, int32_t steps);
void sim_frame(void);
const float *sim_audio(uint32_t n);

#define FS 44100u
#define FRAME (FS / 50u)                         /* 20 ms */
static uint32_t frames, to_frame = FRAME, pressed, released, held, notes, notes_held, flash_ready;
static int32_t master_q12 = 4088;
static volatile int debug_crash, debug_hang;

static void flash_setup(void)                    /* (erased, before a kept image goes over it) */
{
    if (!flash_ready) {
        flash_ready = 1;
        sim_flash_clear();
    }
}
EXPORT uint32_t fm1c_blob_count(void) { return 1u; }
EXPORT uint32_t fm1c_blob_size(void) { return sim_flash_size(); }
EXPORT uint8_t *fm1c_blob(uint32_t i)
{
    flash_setup();
    return i == 0u ? sim_flash_ptr() : 0;
}
EXPORT uint32_t fm1c_store_hash(void) { return sim_flash_writes(); }

EXPORT int fm1c_init(void)
{
    flash_setup();
    sim_init(FS, 0u);
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return FS; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    while (n) {
        uint32_t k = n < to_frame ? n : to_frame, i;
        const float *a;
        if (debug_crash) raise(SIGSEGV);
        while (debug_hang)
            ;
        a = sim_audio(k);
        for (i = 0; i < 2u * k; i++) {
            int32_t v = (int32_t)(a[i] * 32768.0f);
            v = (v * master_q12) >> 12;
            out[i] = (int16_t)(v > 32767 ? 32767 : v < -32767 ? -32767 : v);
        }
        out += 2u * k;
        n -= k;
        frames += k;
        if (!(to_frame -= k)) {
            to_frame = FRAME;
            sim_input(pressed, released, held, notes, notes_held);
            pressed = released = notes = 0;
            sim_frame();
        }
    }
}
EXPORT uint32_t fm1c_ms(void) { return (uint32_t)((uint64_t)frames * 1000u / FS); }
EXPORT void fm1c_master(uint32_t k10)
{
    if (k10 > 1023u) k10 = 1023u;
    master_q12 = (int32_t)((k10 * k10) >> 8);
}
EXPORT void fm1c_key(uint32_t k, uint32_t down)
{
    if (k >= 27u) return;
    if (down) {
        notes |= 1u << k;
        notes_held |= 1u << k;
    } else
        notes_held &= ~(1u << k);
}
EXPORT void fm1c_button(uint32_t b, uint32_t down)
{
    if (b >= 14u) return;
    if (down) {
        pressed |= 1u << b;
        held |= 1u << b;
    } else {
        released |= 1u << b;
        held &= ~(1u << b);
    }
}
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { if (e < 7u) sim_enc(e, steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2) { (void)st; (void)d1; (void)d2; }
EXPORT const uint16_t *fm1c_fb(void) { return sim_fb(); }
EXPORT uint32_t fm1c_fb_hash(void)
{
    const uint16_t *p = sim_fb();
    uint32_t h = 2166136261u, i;
    for (i = 0; i < 240u * 240u; i++) h = (h ^ p[i]) * 16777619u;
    return h;
}
static uint32_t leds(uint32_t first, uint32_t n)
{
    const uint8_t *l = sim_leds();
    uint32_t v = 0, i;
    for (i = 0; i < n; i++)
        if (l[first + i]) v |= 1u << i;
    return v;
}
EXPORT uint32_t fm1c_leds_buttons(void) { return leds(0u, 14u); }
EXPORT uint32_t fm1c_leds_keys(void) { return leds(14u, 27u); }
EXPORT uint32_t fm1c_glow_keys(void) { return 0u; }
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
