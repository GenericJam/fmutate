/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from a firmware's own browser build: the X0X lineage's web API (charlesvestal/fm1-x0x's
 * web/emu/x0x_web.c, and its many descendants: Felucca forks' web/emu/felucca_web.c, fm1-base's web/emu/emu_web.c,
 * FoMni, AMB, ...). Those files compile the whole firmware against a simulated FM-1 and export
 *
 *   web_boot()                      power on (after the saved flash / objects are handed back)
 *   web_render(n), web_out_l/r()    run the device until n frames exist, as float stereo
 *   web_buttons(mask), web_keys(mask), web_enc(role, n), web_master(v)
 *   web_fb() or web_screen()        240 x 240 RGB565 as the panel takes it (high byte first)
 *   web_lit_buttons/keys(), web_dim_keys()
 *   web_midi(st, d1, d2) or web_midi_in(port, usb_packet)
 *   web_nor()/web_nor_size() (a NOR image) or web_store(obj)/web_store_len/web_nobj/web_store_max (saved objects)
 *
 * all plain C; tools/native_catalog/build.py compiles them natively (the same command the firmware's build gives
 * emcc) and links this file in front: the fm1c_* calls of native/engine/live.c, so libfm1engine.so runs it as any
 * cartridge. The optional exports are weak: what a firmware has decides at run time.
 *
 * Their panel order is the printed labels' (Felucca's: FX SEL ENV LFO EDIT GLO HOME SAVE ARP SEQ PLAY REC OCT- OCT+;
 * encoders SELECT ALGO PRESET K1..K4); the engine's is fm1-emu's matrix order (docs/engine_protocol.md), mapped here.
 * Build-time knobs (tools/native_catalog/recipes/web.py reads them from the entry and its page): WEB_MASTER_MAX (the
 * value web_master takes for the knob all the way up: 4096 in X0X's lineage, 1023 in Felucca's ADC one), WEB_FB_SWAP
 * (1: the screen is high byte first), WEB_BTN_MAP / WEB_ENC_MAP (the page's bit for each wire button, its index for
 * each wire encoder, where the page has its own tables: Melodee's are the matrix order), WEB_BOOT_MASTER (web_boot
 * takes the MASTER knob), WEB_MIDI_IN_3 (web_midi_in takes status, data1, data2). */
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef WEB_MASTER_MAX
#define WEB_MASTER_MAX 4096u
#endif
#ifndef WEB_FB_SWAP
#define WEB_FB_SWAP 1
#endif
#ifndef WEB_FS
#define WEB_FS 44100u
#endif

#define EXPORT __attribute__((used, visibility("default")))

#if WEB_BOOT_MASTER
void web_boot(uint32_t master);
#else
void web_boot(void);
#endif
void web_render(uint32_t n);
float *web_out_l(void);
float *web_out_r(void);
/* the optional exports: -DWEB_HAS_<name>=1 for each the firmware defines (build.py reads its objects); a missing
 * one is a null function pointer, so `if (web_x)` decides at run time */
#if WEB_HAS_web_buttons
void web_buttons(uint32_t m);
#else
#define web_buttons ((void (*)(uint32_t m))0)
#endif
#if WEB_HAS_web_keys
void web_keys(uint32_t m);
#else
#define web_keys ((void (*)(uint32_t m))0)
#endif
#if WEB_HAS_web_enc
void web_enc(int role, int32_t n);
#define WEB_ENC_ANY 1
#elif WEB_HAS_web_encoder
void web_encoder(uint32_t e, int32_t n);
#define web_enc(role, n) web_encoder((uint32_t)(role), n)
#define WEB_ENC_ANY 1
#endif
#if WEB_HAS_web_master
void web_master(uint32_t v);
#else
#define web_master ((void (*)(uint32_t v))0)
#endif
#if WEB_HAS_web_fb
uint16_t * web_fb(void);
#else
#define web_fb ((uint16_t * (*)(void))0)
#endif
#if WEB_HAS_web_screen
uint16_t * web_screen(void);
#else
#define web_screen ((uint16_t * (*)(void))0)
#endif
#if WEB_HAS_web_lit_buttons
uint32_t web_lit_buttons(void);
#elif WEB_HAS_web_led_buttons
uint32_t web_led_buttons(void);
#define web_lit_buttons web_led_buttons
#else
#define web_lit_buttons ((uint32_t (*)(void))0)
#endif
#if WEB_HAS_web_lit_keys
uint32_t web_lit_keys(void);
#elif WEB_HAS_web_led_keys
uint32_t web_led_keys(void);
#define web_lit_keys web_led_keys
#else
#define web_lit_keys ((uint32_t (*)(void))0)
#endif
#if WEB_HAS_web_dim_keys
uint32_t web_dim_keys(void);
#else
#define web_dim_keys ((uint32_t (*)(void))0)
#endif
#if WEB_HAS_web_midi
uint32_t web_midi(uint32_t st, uint32_t d1, uint32_t d2);
#else
#define web_midi ((uint32_t (*)(uint32_t st, uint32_t d1, uint32_t d2))0)
#endif
#if WEB_HAS_web_midi_in && WEB_MIDI_IN_3
void web_midi_in(uint32_t st, uint32_t d1, uint32_t d2);
#elif WEB_HAS_web_midi_in
void web_midi_in(uint32_t port, uint32_t pkt);
#else
#define web_midi_in ((void (*)(uint32_t port, uint32_t pkt))0)
#endif
#if WEB_HAS_web_nor
uint8_t * web_nor(void);
#else
#define web_nor ((uint8_t * (*)(void))0)
#endif
#if WEB_HAS_web_nor_size
uint32_t web_nor_size(void);
#else
#define web_nor_size ((uint32_t (*)(void))0)
#endif
#if WEB_HAS_web_flash_writes_count
uint32_t web_flash_writes_count(void);
#else
#define web_flash_writes_count ((uint32_t (*)(void))0)
#endif
#if WEB_HAS_web_store
uint8_t * web_store(uint32_t obj);
#else
#define web_store ((uint8_t * (*)(uint32_t obj))0)
#endif
#if WEB_HAS_web_store_len
int web_store_len(uint32_t obj);
#else
#define web_store_len ((int (*)(uint32_t obj))0)
#endif
#if WEB_HAS_web_store_set_len
void web_store_set_len(uint32_t obj, int n);
#else
#define web_store_set_len ((void (*)(uint32_t obj, int n))0)
#endif
#if WEB_HAS_web_store_writes
uint32_t web_store_writes(void);
#else
#define web_store_writes ((uint32_t (*)(void))0)
#endif
#if WEB_HAS_web_nobj
uint32_t web_nobj(void);
#else
#define web_nobj ((uint32_t (*)(void))0)
#endif
#if WEB_HAS_web_store_max
uint32_t web_store_max(void);
#else
#define web_store_max ((uint32_t (*)(void))0)
#endif
#if WEB_HAS_web_now
uint32_t web_now(void);
#else
#define web_now ((uint32_t (*)(void))0)
#endif
#if WEB_HAS_web_now_ms
uint32_t web_now_ms(void);
#else
#define web_now_ms ((uint32_t (*)(void))0)
#endif
#if WEB_HAS_web_sample_rate
uint32_t web_sample_rate(void);
#else
#define web_sample_rate ((uint32_t (*)(void))0)
#endif

/* wire order (0 OCT- 1 OCT+ 2 FX 3 SEL ... 13 REC) -> label bit; encoders 0 SELECT 1 ALGORITHM 2-5 KNOB1-4 6 PRESETS -> role */
#ifndef WEB_BTN_MAP
#define WEB_BTN_MAP 12, 13, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
#endif
#ifndef WEB_ENC_MAP
#define WEB_ENC_MAP 0, 1, 3, 4, 5, 6, 2
#endif
static const uint8_t BTN_LABEL[14] = {WEB_BTN_MAP};
static const uint8_t ENC_ROLE[7] = {WEB_ENC_MAP};

static uint32_t frames, booted;
static volatile int debug_crash, debug_hang;
static int32_t master_v = -1;

static uint32_t fw_ms(void)
{
    if (web_now) return web_now();
    if (web_now_ms) return web_now_ms();
    return (uint32_t)((uint64_t)frames * 1000u / WEB_FS);
}

/* ---- panel edges, spaced EDGE_GAP_MS of firmware time apart per input (native/engine/live.c's rule) */
#define EDGE_GAP_MS 16u
#define EDGE_NIN 41u
#define EDGE_KEY0 14u
#define EDGE_QMAX 32u
static struct { uint32_t at; uint8_t on, n; } edge[EDGE_NIN];
static uint64_t edge_pending;
static uint32_t btn_mask, key_mask;

static void edge_apply(uint32_t i, uint32_t down)
{
    edge[i].on = (uint8_t)down;
    edge[i].at = fw_ms();
    if (i >= EDGE_KEY0) {
        uint32_t bit = 1u << (i - EDGE_KEY0);
        key_mask = down ? key_mask | bit : key_mask & ~bit;
        if (web_keys) web_keys(key_mask);
    } else {
        uint32_t bit = 1u << BTN_LABEL[i];
        btn_mask = down ? btn_mask | bit : btn_mask & ~bit;
        if (web_buttons) web_buttons(btn_mask);
    }
}
static int edge_settled(uint32_t i) { return fw_ms() - edge[i].at >= EDGE_GAP_MS; }
static void edge_in(uint32_t i, uint32_t down)
{
    down = down != 0u;
    if (down == (edge[i].on ^ (edge[i].n & 1u))) return;
    if (!edge[i].n && edge_settled(i))
        edge_apply(i, down);
    else if (edge[i].n < EDGE_QMAX) {
        edge[i].n++;
        edge_pending |= 1ull << i;
    } else
        edge[i].n--;
}
static void edges_due(void)
{
    uint64_t p = edge_pending;
    while (p) {
        uint32_t i = (uint32_t)__builtin_ctzll(p);
        p &= p - 1u;
        if (!edge_settled(i)) continue;
        edge_apply(i, !edge[i].on);
        if (!--edge[i].n) edge_pending &= ~(1ull << i);
    }
}

/* ---- storage: a NOR image as one blob, or each saved object as a blob of [length:i32][data] */
#define OBJ_MAX_BLOBS 64u
static uint8_t *obj_mirror;
static uint32_t obj_n, obj_max, obj_writes;

static void objs_setup(void)
{
    static int done;
    if (done) return;
    done = 1;
    if (web_nor || !web_store || !web_nobj || !web_store_max) return;
    obj_n = web_nobj();
    obj_max = web_store_max();
    if (obj_n > OBJ_MAX_BLOBS) obj_n = OBJ_MAX_BLOBS;
    obj_mirror = calloc(obj_n, 4u + obj_max);
    for (uint32_t i = 0; obj_mirror && i < obj_n; i++) {
        int32_t none = -1;
        memcpy(obj_mirror + i * (4u + obj_max), &none, 4);
    }
}
static void objs_to_firmware(void)
{
    for (uint32_t i = 0; obj_mirror && i < obj_n; i++) {
        uint8_t *m = obj_mirror + i * (4u + obj_max);
        int32_t len;
        memcpy(&len, m, 4);
        if (len < 0 || (uint32_t)len > obj_max) continue;
        memcpy(web_store(i), m + 4, (uint32_t)len);
        web_store_set_len(i, len);
    }
}
static void objs_from_firmware(void)
{
    for (uint32_t i = 0; obj_mirror && i < obj_n; i++) {
        uint8_t *m = obj_mirror + i * (4u + obj_max);
        int32_t len = web_store_len(i);
        memcpy(m, &len, 4);
        if (len > 0 && (uint32_t)len <= obj_max) memcpy(m + 4, web_store(i), (uint32_t)len);
    }
}

EXPORT uint32_t fm1c_blob_count(void)
{
    objs_setup();
    return web_nor ? 1u : obj_n;
}
EXPORT uint32_t fm1c_blob_size(void)
{
    objs_setup();
    return web_nor ? web_nor_size() : 4u + obj_max;
}
EXPORT uint8_t *fm1c_blob(uint32_t i)
{
    objs_setup();
    if (web_nor) return i == 0u ? web_nor() : 0;
    return i < obj_n ? obj_mirror + i * (4u + obj_max) : 0;
}
EXPORT uint32_t fm1c_store_hash(void)
{
    uint32_t h = 2166136261u, i, n;
    const uint8_t *p;
    if (web_nor) {
        if (web_flash_writes_count) return web_flash_writes_count();
        p = web_nor();
        n = web_nor_size();
        for (i = 0; i < n; i++) h = (h ^ p[i]) * 16777619u;
        return h;
    }
    if (!obj_mirror) return 0;
    if (web_store_writes) {
        uint32_t w = web_store_writes();
        if (w != obj_writes) { obj_writes = w; objs_from_firmware(); }
    } else
        objs_from_firmware();
    n = obj_n * (4u + obj_max);
    for (i = 0; i < n; i++) h = (h ^ obj_mirror[i]) * 16777619u;
    return h;
}

/* ---- life */
EXPORT int fm1c_init(void)
{
    uint32_t i;
    if (booted) return -1;
    objs_setup();
    objs_to_firmware();
    for (i = 0; i < EDGE_NIN; i++) edge[i].at = (uint32_t)-EDGE_GAP_MS;
    if (web_master) web_master(WEB_MASTER_MAX);  /* (MASTER at unity until the app sets it, as live.c) */
#if WEB_BOOT_MASTER
    web_boot(WEB_MASTER_MAX);
#else
    web_boot();
#endif
    for (i = 0; i < EDGE_NIN; i++) edge[i].at = fw_ms() - EDGE_GAP_MS;
    booted = 1;
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return web_sample_rate ? web_sample_rate() : WEB_FS; }

#define CHUNK 64u                                /* frames per web_render: panel edges land within 1.5 ms */
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    while (n) {
        uint32_t k = n < CHUNK ? n : CHUNK, i;
        const float *l, *r;
        if (debug_crash) raise(SIGSEGV);
        while (debug_hang)
            ;
        edges_due();
        web_render(k);
        l = web_out_l();
        r = web_out_r();
        for (i = 0; i < k; i++) {
            float a = l[i] * 32767.0f, b = r[i] * 32767.0f;
            out[2u * i] = (int16_t)(a > 32767.0f ? 32767 : a < -32767.0f ? -32767 : (int32_t)a);
            out[2u * i + 1u] = (int16_t)(b > 32767.0f ? 32767 : b < -32767.0f ? -32767 : (int32_t)b);
        }
        out += 2u * k;
        n -= k;
        frames += k;
    }
}
EXPORT uint32_t fm1c_ms(void) { return fw_ms(); }
EXPORT void fm1c_master(uint32_t k10)
{
    if (k10 > 1024u) k10 = 1024u;
    master_v = (int32_t)k10;
    if (web_master) web_master((uint32_t)((uint64_t)k10 * WEB_MASTER_MAX / 1024u));
}
EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < 27u) edge_in(EDGE_KEY0 + k, down); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) edge_in(b, down); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps)
{
#if WEB_ENC_ANY
    if (e < 7u) web_enc(ENC_ROLE[e], steps);
#else
    (void)e, (void)steps;
#endif
}
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st < 0x80u || st >= 0xF0u) return;
    if (web_midi)
        web_midi(st, d1 & 0x7Fu, d2 & 0x7Fu);
#if WEB_MIDI_IN_3
    else if (web_midi_in)
        web_midi_in(st, d1 & 0x7Fu, d2 & 0x7Fu);
#else
    else if (web_midi_in)
        web_midi_in(0u, (st >> 4) | st << 8 | (d1 & 0x7Fu) << 16 | (d2 & 0x7Fu) << 24);
#endif
}

/* ---- what the panel shows */
static uint16_t fb_out[240u * 240u];
static const uint16_t *web_pixels(void)
{
    static const uint16_t black[240u * 240u];
    const uint16_t *p = web_fb ? web_fb() : web_screen ? web_screen() : 0;
    return p ? p : black;
}
EXPORT const uint16_t *fm1c_fb(void)
{
    const uint16_t *p = web_pixels();
    uint32_t i;
    for (i = 0; i < 240u * 240u; i++)
        fb_out[i] = WEB_FB_SWAP ? (uint16_t)(p[i] >> 8 | p[i] << 8) : p[i];
    return fb_out;
}
EXPORT uint32_t fm1c_fb_hash(void)
{
    uint32_t h = 2166136261u, i;
    const uint16_t *p = web_pixels();
    for (i = 0; i < 240u * 240u; i++) h = (h ^ p[i]) * 16777619u;
    return h;
}
static uint32_t to_wire(uint32_t labels)
{
    uint32_t w = 0, b;
    for (b = 0; b < 14u; b++)
        if (labels >> BTN_LABEL[b] & 1u) w |= 1u << b;
    return w;
}
EXPORT uint32_t fm1c_leds_buttons(void) { return web_lit_buttons ? to_wire(web_lit_buttons()) : 0; }
EXPORT uint32_t fm1c_leds_keys(void) { return web_lit_keys ? web_lit_keys() & 0x7FFFFFFu : 0; }
EXPORT uint32_t fm1c_glow_keys(void) { return web_dim_keys ? web_dim_keys() & 0x7FFFFFFu : 0; }

EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
