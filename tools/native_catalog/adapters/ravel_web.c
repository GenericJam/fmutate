/* SPDX-License-Identifier: GPL-3.0-only */
/* Ravel's browser emulator (web/emu/ravel_web.c on host/host_core.c: rv_*) as the X0X lineage's web_* calls, so
 * adapters/web.c makes it a cartridge (tools/native_catalog/recipes/wasm.py links the three). Ravel's simulated
 * FM-1 is the X0X host's shape (the device a millisecond at a time, MASTER 0..4096, saved objects in slots); its
 * panel is in wire order (firmware/app/plat.h: B_OCTDN, B_OCTUP, B_FX ..; EN_SELECT, EN_ALGO, EN_K1..4, EN_PRESET),
 * web.c's in the printed labels' (FX .. REC, OCT-, OCT+; SELECT ALGO PRESET K1..K4): turned back here. web_midi is
 * ravel_web.c's own. */
#include <stdint.h>

#define EXPORT __attribute__((used, visibility("default")))

void rv_boot(void);
void web_intro(void);
uint32_t rv_run(uint32_t ms);
float *rv_audio(void);
uint16_t *rv_fb(void);
void rv_set_buttons(uint32_t m);
void rv_set_keys(uint32_t m);
void rv_enc(int role, int32_t d);
void rv_set_master(uint32_t v);
uint32_t rv_leds_buttons(void);
uint32_t rv_leds_keys(void);
uint8_t *rv_store(uint32_t s);
int rv_store_len(uint32_t s);
void rv_store_set_len(uint32_t s, int n);
uint32_t rv_store_writes(void);
uint32_t rv_store_slots(void);
uint32_t rv_store_max(void);

/* the printed labels' order (web.c's bits and roles) -> Ravel's (the wire's) */
static uint32_t label_to_wire(uint32_t m) { return (m & 0xFFFu) << 2 | (m >> 12 & 3u); }
static uint32_t wire_to_label(uint32_t w) { return (w >> 2 & 0xFFFu) | (w & 3u) << 12; }
static const int ROLE[7] = {0, 1, 6, 2, 3, 4, 5};   /* SELECT ALGO PRESET K1..K4 -> EN_* */

/* output ring: rv_run makes whole milliseconds (about 44 frames each), web_render takes n */
#define RING 32768u
static float ring[RING * 2u], out_l[1024], out_r[1024];
static uint32_t ring_w, ring_r, now;

EXPORT void web_boot(void)                       /* power-on: the start screen too (ui_intro), as the page */
{
    rv_boot();
    web_intro();
}
EXPORT void web_render(uint32_t n)
{
    uint32_t k;
    if (n > 1024u) n = 1024u;
    while (ring_w - ring_r < n) {
        uint32_t got = rv_run(1u), i;
        const float *a = rv_audio();
        now++;
        for (i = 0; i < got; i++) {
            uint32_t j = (ring_w++ % RING) * 2u;
            ring[j] = a[2u * i];
            ring[j + 1u] = a[2u * i + 1u];
        }
    }
    for (k = 0; k < n; k++) {
        uint32_t j = (ring_r++ % RING) * 2u;
        out_l[k] = ring[j];
        out_r[k] = ring[j + 1u];
    }
}
EXPORT float *web_out_l(void) { return out_l; }
EXPORT float *web_out_r(void) { return out_r; }
EXPORT uint32_t web_now(void) { return now; }
EXPORT void web_buttons(uint32_t m) { rv_set_buttons(label_to_wire(m)); }
EXPORT void web_keys(uint32_t m) { rv_set_keys(m); }
EXPORT void web_enc(int role, int32_t n) { if (role >= 0 && role < 7) rv_enc(ROLE[role], n); }
EXPORT void web_master(uint32_t v) { rv_set_master(v); }
EXPORT uint16_t *web_fb(void) { return rv_fb(); }
EXPORT uint32_t web_lit_buttons(void) { return wire_to_label(rv_leds_buttons()); }
EXPORT uint32_t web_lit_keys(void) { return rv_leds_keys(); }
EXPORT uint8_t *web_store(uint32_t obj) { return rv_store(obj); }
EXPORT int web_store_len(uint32_t obj) { return rv_store_len(obj); }
EXPORT void web_store_set_len(uint32_t obj, int n) { rv_store_set_len(obj, n); }
EXPORT uint32_t web_store_writes(void) { return rv_store_writes(); }
EXPORT uint32_t web_nobj(void) { return rv_store_slots(); }
EXPORT uint32_t web_store_max(void) { return rv_store_max(); }
