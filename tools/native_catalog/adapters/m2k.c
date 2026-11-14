/* SPDX-License-Identifier: GPL-3.0-only */
/* A firmware cartridge from MONO2K's browser build (web/m2k_web.c: the firmware's core, firmware/src/m2k_core.c,
 * with the page's w_* calls), driven as the FM-1's own glue drives the core (firmware/fm1/m2k_fm1.c): 128-frame
 * renders, the platform's MASTER (k10 * k10 >> 8, Q12) and clip, a frame of the 1-bit screen every 33 ms (ink
 * black, paper white, the panel's), the core's ids from the panel's (button_of, ENC_OF), its lights on from a
 * quarter up. Not here: the core's store (m2k_link.c on the device), so nothing is saved. */
#include <signal.h>
#include <stdint.h>

#define EXPORT __attribute__((used, visibility("default")))

int16_t *w_audio(void);
void w_render(int n);
const uint8_t *w_frame(uint32_t ms);
const uint8_t *w_leds(void);
void w_init(uint32_t seed);
void w_key(int k, int d);
void w_button(int b, int d);
void w_encoder(int e, int d);
void w_midi(int s, int a, int b);

enum { B_FX, B_SEL, B_ENV, B_LFO, B_EDIT, B_GLO, B_HOME, B_SAVE, B_ARP, B_SEQ, B_PLAY, B_REC, B_OCTD, B_OCTU };
enum { E_SELECT, E_ALGO, E_PRESET, E_K1, E_K2, E_K3, E_K4 };
#define KEYS 27u
#define BLK 128u
#define FRAME_MS 33u

static int button_of(uint32_t id) { return id == 0u ? B_OCTD : id == 1u ? B_OCTU : (int)id - 2; }
static const uint8_t ENC_OF[7] = {E_SELECT, E_ALGO, E_K1, E_K2, E_K3, E_K4, E_PRESET};

static uint32_t frames, pos = BLK, next_frame;
static int32_t master_q12 = 4092;
static uint16_t fb[240u * 240u];
static volatile int debug_crash, debug_hang;

static uint32_t now_ms(void) { return (uint32_t)((uint64_t)frames * 1000u / 44100u); }
static void screen(void)                         /* (m2k_fm1.c's screen_send: a nibble's four pixels, MSB first) */
{
    const uint8_t *f = w_frame(now_ms());
    uint32_t i, k;
    for (i = 0; i < 240u * 30u; i++)
        for (k = 0; k < 8u; k++)
            fb[i * 8u + k] = f[i] >> (7u - k) & 1u ? 0x0000u : 0xFFFFu;
}

EXPORT uint32_t fm1c_blob_count(void) { return 0u; }
EXPORT uint32_t fm1c_blob_size(void) { return 0u; }
EXPORT uint8_t *fm1c_blob(uint32_t i) { (void)i; return 0; }
EXPORT uint32_t fm1c_store_hash(void) { return 0u; }

EXPORT int fm1c_init(void)
{
    w_init(1u);
    screen();
    return 0;
}
EXPORT uint32_t fm1c_rate(void) { return 44100u; }
EXPORT void fm1c_render(int16_t *out, uint32_t n)
{
    uint32_t i, c;
    for (i = 0; i < n; i++) {
        const int16_t *b;
        if (pos >= BLK) {
            if (debug_crash) raise(SIGSEGV);
            while (debug_hang)
                ;
            w_render((int)BLK);
            pos = 0;
            if (now_ms() >= next_frame) {
                next_frame = now_ms() + FRAME_MS;
                screen();
            }
        }
        b = w_audio();
        for (c = 0; c < 2u; c++) {
            int32_t v = (b[2u * pos + c] * master_q12) >> 12;
            out[2u * i + c] = (int16_t)(v > 32767 ? 32767 : v < -32767 ? -32767 : v);
        }
        pos++;
        frames++;
    }
}
EXPORT uint32_t fm1c_ms(void) { return now_ms(); }
EXPORT void fm1c_master(uint32_t k10)
{
    if (k10 > 1023u) k10 = 1023u;
    master_q12 = (int32_t)((k10 * k10) >> 8);
}
EXPORT void fm1c_key(uint32_t k, uint32_t down) { if (k < KEYS) w_key((int)k, down != 0u); }
EXPORT void fm1c_button(uint32_t b, uint32_t down) { if (b < 14u) w_button(button_of(b), down != 0u); }
EXPORT void fm1c_enc(uint32_t e, int32_t steps) { if (e < 7u && steps) w_encoder(ENC_OF[e], (int)steps); }
EXPORT void fm1c_midi(uint32_t st, uint32_t d1, uint32_t d2)
{
    if (st >= 0x80u && st < 0xF0u) w_midi((int)st, (int)(d1 & 0x7Fu), (int)(d2 & 0x7Fu));
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
    const uint8_t *l = w_leds();
    uint32_t v = 0, i;
    for (i = 0; i < 14u; i++)
        if (l[KEYS + (uint32_t)button_of(i)] >= 64u) v |= 1u << i;
    return v;
}
EXPORT uint32_t fm1c_leds_keys(void)
{
    const uint8_t *l = w_leds();
    uint32_t v = 0, i;
    for (i = 0; i < KEYS; i++)
        if (l[i] >= 64u) v |= 1u << i;
    return v;
}
EXPORT uint32_t fm1c_glow_keys(void)
{
    const uint8_t *l = w_leds();
    uint32_t v = 0, i;
    for (i = 0; i < KEYS; i++)
        if (l[i] && l[i] < 64u) v |= 1u << i;
    return v;
}
EXPORT void fm1c_debug(uint32_t what)
{
    if (what == 1u) debug_crash = 1;
    if (what == 2u) debug_hang = 1;
}
