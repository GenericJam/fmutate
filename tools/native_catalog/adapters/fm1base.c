/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from fm1-base's host simulator (charlesvestal/fm1-base host/plat_host.c: the whole app, UI
 * and sound, against a simulated FM-1) when the tree has no browser entry of its own (web/emu/emu_web.c trimmed
 * away, as J6's vendored fm1-base and the Audio Router's fork). This file is that entry: compiled with the flags
 * the firmware's own `tools/build.py APP --host` gives plat_host.c (tools/native_catalog/recipes/fm1base.py records
 * them), plus -DPLAT_WEB, which leaves plat_host.c's script runner and main() out. It exports the X0X lineage's web_*
 * calls over plat_host.c's state, and adapters/web.c (linked in front) maps those to the fm1c_* calls.
 *
 * The device's clock as fm1-base's browser emulator runs it: producing audio advances the simulated FM-1 one
 * millisecond at a time (run_ms), which renders APP_BLOCK-frame blocks and runs the UI every 16 ms. */
#include <stdint.h>
#include <string.h>

static void web_audio(const int32_t *blk, uint32_t n);
#include "plat_host.c"

#undef __attribute__
#define WEB_EXPORT __attribute__((used, visibility("default")))

/* blocks from run_ms, stereo float (Q23 in), drained by web_render */
#define RING 4096u
static float ring[RING * 2u], out_l[1024], out_r[1024];
static uint32_t ring_w, ring_r;
static void web_audio(const int32_t *blk, uint32_t n)
{
    uint32_t k;
    for (k = 0; k < n; k++) {
        uint32_t i = (ring_w++ % RING) * 2u;
        ring[i] = (float)blk[2u * k] / 8388608.0f;
        ring[i + 1u] = (float)blk[2u * k + 1u] / 8388608.0f;
    }
}
static void web_said(const uint8_t *p, uint32_t n) { (void)p, (void)n; }   /* (no screen reader here) */

WEB_EXPORT float *web_out_l(void) { return out_l; }
WEB_EXPORT float *web_out_r(void) { return out_r; }
WEB_EXPORT void web_render(uint32_t n)
{
    uint32_t k;
    if (n > 1024u) n = 1024u;
    while (ring_w - ring_r < n)
        run_ms(1);
    for (k = 0; k < n; k++) {
        uint32_t i = (ring_r++ % RING) * 2u;
        out_l[k] = ring[i];
        out_r[k] = ring[i + 1u];
    }
}
WEB_EXPORT void web_boot(void) { boot(); }
WEB_EXPORT void web_buttons(uint32_t m) { held_btn = m; }
WEB_EXPORT void web_keys(uint32_t m)
{
#ifdef APP_KEY_SENSE
    uint32_t k, ch = m ^ held_keys;                     /* each key at velocity 100, as the browser emulator */
    for (k = 0; k < NKEYS; k++)
        if (ch >> k & 1u) app_host_key(k, m >> k & 1u ? 100u : 0u, 0);
#endif
    held_keys = m;
}
WEB_EXPORT void web_enc(int role, int32_t n)
{
    if (role >= 0 && role < NE) enc_acc[role] += n;
}
WEB_EXPORT void web_master(uint32_t v) { master = v > 4096u ? 4096u : v; }
WEB_EXPORT uint32_t web_lit_buttons(void) { return lit_btn; }
WEB_EXPORT uint32_t web_lit_keys(void) { return lit_keys; }
WEB_EXPORT uint32_t web_dim_keys(void) { return dim_keys | mid_keys; }
WEB_EXPORT void web_midi_in(uint32_t port, uint32_t pkt)
{
    if (port < NPORTS && mi_w - mi_r < MQ) {
        min_q[mi_w % MQ] = pkt;
        min_port[mi_w++ % MQ] = port;
    }
}
WEB_EXPORT uint16_t *web_fb(void) { return fb; }
WEB_EXPORT uint32_t web_now(void) { return now_ms; }

/* saved objects: the engine keeps them as blobs and hands them back before boot */
WEB_EXPORT uint8_t *web_store(uint32_t obj) { store_ready(); return obj < OBJ_NOBJ ? store[obj] : 0; }
WEB_EXPORT int web_store_len(uint32_t obj) { store_ready(); return obj < OBJ_NOBJ ? store_len[obj] : -1; }
WEB_EXPORT void web_store_set_len(uint32_t obj, int n)
{
    store_ready();
    if (obj < OBJ_NOBJ) store_len[obj] = n < 0 ? -1 : n > (int)PLAT_STORE_MAX ? (int)PLAT_STORE_MAX : n;
}
WEB_EXPORT uint32_t web_store_writes(void) { return store_writes; }
WEB_EXPORT uint32_t web_nobj(void) { return OBJ_NOBJ; }
WEB_EXPORT uint32_t web_store_max(void) { return PLAT_STORE_MAX; }
