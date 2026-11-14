/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from a browser simulator with the sim_* panel API (zp12's sim/sim.c; the pattern of
 * OberVave's web/sim, which native/engine/live.c runs for the Dinghy line): the firmware's own sources on a fake
 * FM-1, compiled natively as the author's own native test does (-DSIM_NATIVE: the main loop a coroutine,
 * adapters/include/ucontext.h). Its calls are already the engine's: the panel in wire order (buttons 0 OCT- ..
 * 13 REC, encoders 0 SELECT .. 6 PRESETS, keys 0 F3 .. 26 G5), MASTER 0..1023, the screen as pixel values, the store
 * a span of the simulated flash. tools/native_catalog/recipes/wasm.py links this file in front. */
#include <signal.h>
#include <stdint.h>

#define EXPORT __attribute__((used, visibility("default")))

int sim_init(uint32_t rate);
uint32_t sim_rate(void);
float *sim_out_l(void);
float *sim_out_r(void);
void sim_render(uint32_t n);
uint32_t sim_now(void);
void sim_key(uint32_t k, uint32_t down);
void sim_button(uint32_t b, uint32_t down);
void sim_enc(uint32_t e, int32_t steps);
void sim_midi(uint32_t st, uint32_t d1, uint32_t d2);
void sim_master(uint32_t k10);
uint8_t *sim_store(void);
uint32_t sim_store_size(void);
uint32_t sim_store_writes(void);
uint16_t *sim_screen(void);
uint32_t sim_fb_hash(void);
uint32_t sim_leds_buttons(void);
uint32_t sim_leds_keys(void);
uint32_t sim_glow_keys(void);

static volatile int debug_crash, debug_hang;

EXPORT int fm1c_init(void)
{
    sim_master(1023u);                           /* (MASTER at unity until the app sets it, as live.c) */
    return sim_init(sim_rate());
}
EXPORT uint32_t fm1c_rate(void) { return sim_rate(); }
#define CHUNK 256u
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    while (n) {
        uint32_t k = n < CHUNK ? n : CHUNK, i;
        const float *l, *r;
        if (debug_crash) raise(SIGSEGV);
        while (debug_hang)
            ;
        sim_render(k);
        l = sim_out_l();
        r = sim_out_r();
        for (i = 0; i < k; i++) {
            float a = l[i] * 32768.0f, b = r[i] * 32768.0f;
            out[2u * i] = (int16_t)(a > 32767.0f ? 32767 : a < -32768.0f ? -32768 : (int32_t)a);
            out[2u * i + 1u] = (int16_t)(b > 32767.0f ? 32767 : b < -32768.0f ? -32768 : (int32_t)b);
        }
        out += 2u * k;
        n -= k;
    }
}
EXPORT uint32_t fm1c_ms(void) { return sim_now(); }
EXPORT void fm1c_master(uint32_t k10) { sim_master(k10 > 1023u ? 1023u : k10); }
EXPORT void fm1c_key(uint32_t k, uint32_t down) { sim_key(k, down != 0u); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { sim_button(b, down != 0u); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { sim_enc(e, steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2) { sim_midi(st, d1, d2); }
EXPORT const uint16_t *fm1c_fb(void) { return sim_screen(); }
EXPORT uint32_t fm1c_fb_hash(void) { return sim_fb_hash(); }
EXPORT uint32_t fm1c_leds_buttons(void) { return sim_leds_buttons() & 0x3FFFu; }
EXPORT uint32_t fm1c_leds_keys(void) { return sim_leds_keys() & 0x7FFFFFFu; }
EXPORT uint32_t fm1c_glow_keys(void) { return sim_glow_keys() & 0x7FFFFFFu; }
EXPORT uint32_t fm1c_blob_count(void) { return 1u; }
EXPORT uint32_t fm1c_blob_size(void) { return sim_store_size(); }
EXPORT uint8_t *fm1c_blob(uint32_t i) { return i == 0u ? sim_store() : 0; }
EXPORT uint32_t fm1c_store_hash(void) { return sim_store_writes(); }
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
