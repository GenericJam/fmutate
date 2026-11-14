/* SPDX-License-Identifier: GPL-3.0-only */
/* LUXR's browser emulator (emu/lx_emu_web.c: emu_*) as the X0X lineage's web_* calls, so adapters/web.c makes it a
 * cartridge (tools/native_catalog/recipes/wasm.py links the two). The two APIs are the same shape: buttons by
 * their printed labels (B_FX .. B_REC, B_OCT-, B_OCT+), encoders SELECT ALGO PRESET K1..K4, MASTER 0..1023
 * (WEB_MASTER_MAX 1023), the screen in the panel's byte order, the store a NOR image. What differs is taken here:
 * the render's 128-frame limit, the lights as one byte each. */
#include <stdint.h>

#define EXPORT __attribute__((used, visibility("default")))

void emu_init(uint32_t seed);
void emu_render(uint32_t n);
float *emu_out_l(void);
float *emu_out_r(void);
void emu_buttons(uint32_t held);
void emu_keys(uint32_t keys);
void emu_enc(uint32_t role, int32_t steps);
void emu_master(uint32_t pot);
void emu_midi(uint32_t status, uint32_t d1, uint32_t d2);
uint16_t *emu_screen(void);
uint8_t *emu_leds_btn(void);
uint8_t *emu_leds_key(void);
uint8_t *emu_store(void);
uint32_t emu_store_len(void);
uint32_t emu_store_gen(void);

#define PART 128u                                /* (emu_render: at most HALF_FRAMES) */
static float out_l[1024], out_r[1024];

EXPORT void web_boot(void) { emu_init(1u); }
EXPORT void web_render(uint32_t n)
{
    uint32_t b, i;
    if (n > 1024u) n = 1024u;
    for (b = 0; b < n; b += PART) {
        uint32_t m = n - b < PART ? n - b : PART;
        const float *l, *r;
        emu_render(m);
        l = emu_out_l();
        r = emu_out_r();
        for (i = 0; i < m; i++) {
            out_l[b + i] = l[i];
            out_r[b + i] = r[i];
        }
    }
}
EXPORT float *web_out_l(void) { return out_l; }
EXPORT float *web_out_r(void) { return out_r; }
EXPORT void web_buttons(uint32_t m) { emu_buttons(m); }
EXPORT void web_keys(uint32_t m) { emu_keys(m); }
EXPORT void web_enc(int role, int32_t n) { emu_enc((uint32_t)role, n); }
EXPORT void web_master(uint32_t v) { emu_master(v); }
EXPORT uint32_t web_midi(uint32_t st, uint32_t d1, uint32_t d2) { emu_midi(st, d1, d2); return 0; }
EXPORT uint16_t *web_screen(void) { return emu_screen(); }
EXPORT uint32_t web_lit_buttons(void)
{
    const uint8_t *l = emu_leds_btn();
    uint32_t v = 0, i;
    for (i = 0; i < 14u; i++)
        if (l[i]) v |= 1u << i;
    return v;
}
EXPORT uint32_t web_lit_keys(void)
{
    const uint8_t *l = emu_leds_key();
    uint32_t v = 0, i;
    for (i = 0; i < 27u; i++)
        if (l[i]) v |= 1u << i;
    return v;
}
EXPORT uint8_t *web_nor(void) { return emu_store(); }
EXPORT uint32_t web_nor_size(void) { return emu_store_len(); }
EXPORT uint32_t web_flash_writes_count(void) { return emu_store_gen(); }
