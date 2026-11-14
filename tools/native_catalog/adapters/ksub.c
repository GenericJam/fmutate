/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from KAWA's browser build and its descendants' (K-WASUB: source/web/wasm_host.c, which
 * platform.c takes in place of the hardware under KAWA_WASM; its exports PFX_*: ksub_, kawa_): the app's main loop
 * pass (PFX_step) and its audio interrupt (PFX_audio: 256 frames, the clock moved by them), run as the page's worklet
 * does: a block, then a pass. The panel is in wire order already (platform.c's BTN_* and ENC_* ids), MASTER the
 * device's square law (platform.c: k10 * k10 >> 8, Q12), the screen the panel's pixels turned to values, the LEDs
 * 41 levels (2 lit, 1 dim). The saved data, where the build exports them (KS_STORE, KS_SETTINGS): the user store
 * (PFX_store) and the settings (PFX_settings: valid, length, data), a blob each. */
#include <signal.h>
#include <stdint.h>
#include <string.h>

#define EXPORT __attribute__((used, visibility("default")))
#ifndef PFX
#define PFX ksub
#endif
#define CAT2(a, b) a##_##b
#define CAT(a, b) CAT2(a, b)
#define F(x) CAT(PFX, x)

void F(init)(void);
void F(step)(void);
float *F(audio)(void);
void F(keys)(uint32_t mask);
void F(button)(uint32_t id, uint32_t down);
void F(turn)(uint32_t enc, int32_t steps);
void F(master)(int32_t q12);
void F(midi)(uint32_t st, uint32_t d1, uint32_t d2);
uint16_t *F(screen)(void);
uint8_t *F(leds)(void);
#if KS_SETTINGS
uint8_t *F(settings)(void);
uint32_t F(settings_gen)(void);
#endif
#if KS_STORE
uint8_t *F(store)(void);
uint32_t F(store_size)(void);
uint32_t F(store_gen)(void);
#define BLOB_SIZE F(store_size)()
#define SETTINGS_BLOB 1u
#else
#define BLOB_SIZE SETTINGS
#define SETTINGS_BLOB 0u
#endif

#define BLK 256u
#define SETTINGS 260u
static uint32_t frames, pos = BLK, key_mask;
static const float *blk;
static volatile int debug_crash, debug_hang;

#if KS_SETTINGS
static uint32_t settings_gen;
static uint8_t settings[32768];                  /* (a blob the size of the store's: the settings at its start) */
#endif

EXPORT uint32_t fm1c_blob_count(void) { return (KS_STORE ? 1u : 0u) + (KS_SETTINGS ? 1u : 0u); }
EXPORT uint32_t fm1c_blob_size(void) { return BLOB_SIZE; }
EXPORT uint8_t *fm1c_blob(uint32_t i)
{
#if KS_STORE
    if (i == 0u) return F(store)();
#endif
#if KS_SETTINGS
    if (i == SETTINGS_BLOB) return settings;
#endif
    (void)i;
    return 0;
}
EXPORT uint32_t fm1c_store_hash(void)
{
    uint32_t h = 0;
#if KS_SETTINGS
    if (F(settings_gen)() != settings_gen) {
        settings_gen = F(settings_gen)();
        memcpy(settings, F(settings)(), SETTINGS);
    }
    h ^= settings_gen;
#endif
#if KS_STORE
    h ^= F(store_gen)() * 2654435761u;
#endif
    return h;
}

EXPORT int fm1c_init(void)
{
#if KS_SETTINGS
    memcpy(F(settings)(), settings, SETTINGS);
#endif
    F(master)((1023 * 1023) >> 8);             /* (MASTER at unity until the app sets it, as live.c) */
    F(init)();
#if KS_SETTINGS
    settings_gen = F(settings_gen)();
#endif
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return 44100u; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i;
    for (i = 0; i < n; i++) {
        float a, b;
        if (pos >= BLK) {
            if (debug_crash) raise(SIGSEGV);
            while (debug_hang)
                ;
            blk = F(audio)();
            pos = 0;
            F(step)();
        }
        a = blk[2u * pos] * 32768.0f;
        b = blk[2u * pos + 1u] * 32768.0f;
        out[2u * i] = (int16_t)(a > 32767.0f ? 32767 : a < -32768.0f ? -32768 : (int32_t)a);
        out[2u * i + 1u] = (int16_t)(b > 32767.0f ? 32767 : b < -32768.0f ? -32768 : (int32_t)b);
        pos++;
        frames++;
    }
}
EXPORT uint32_t fm1c_ms(void) { return (uint32_t)((uint64_t)frames * 1000u / 44100u); }
EXPORT void fm1c_master(uint32_t k10)
{
    if (k10 > 1023u) k10 = 1023u;
    F(master)((int32_t)((k10 * k10) >> 8));
}
EXPORT void fm1c_key(uint32_t k, uint32_t down)
{
    if (k >= 27u) return;
    key_mask = down ? key_mask | 1u << k : key_mask & ~(1u << k);
    F(keys)(key_mask);
}
EXPORT void fm1c_button(uint32_t b, uint32_t down) { F(button)(b, down != 0u); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { F(turn)(e, steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st >= 0x80u && st < 0xF0u) F(midi)(st, d1 & 0x7Fu, d2 & 0x7Fu);
}
EXPORT const uint16_t *fm1c_fb(void) { return F(screen)(); }
EXPORT uint32_t fm1c_fb_hash(void)
{
    const uint16_t *p = F(screen)();
    uint32_t h = 2166136261u, i;
    for (i = 0; i < 240u * 240u; i++) h = (h ^ p[i]) * 16777619u;
    return h;
}
static uint32_t leds(uint32_t first, uint32_t n, uint8_t level)
{
    const uint8_t *l = F(leds)();
    uint32_t v = 0, i;
    for (i = 0; i < n; i++)
        if (l[first + i] == level) v |= 1u << i;
    return v;
}
EXPORT uint32_t fm1c_leds_buttons(void) { return leds(0u, 14u, 2u); }
EXPORT uint32_t fm1c_leds_keys(void) { return leds(14u, 27u, 2u); }
EXPORT uint32_t fm1c_glow_keys(void) { return leds(14u, 27u, 1u); }
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
