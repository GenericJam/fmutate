/* SPDX-License-Identifier: GPL-3.0-only */
/* A cartridge linked into the iOS app (no downloaded native code there): its fm1c_* calls as the one table the app
 * sees, `FM1C_TABLE` (fm1c_<id>), in FMutate's native/engine/fm1engine.h layout (struct fm1c_api, iOS port). common.py
 * links this with the cartridge's objects through `ld -r`, keeping only the table global (two firmwares' symbols
 * can't clash) and moving the writable data and BSS to sections of their own (FM1C_DATA, FM1C_BSS), which the app's
 * host restores before each boot.
 *
 * For a call-driven cartridge (adapters/web.c: the firmware runs inside fm1c_render on the caller's thread) the loop
 * calls are trivial: nothing runs between calls, so it has always "ended" cleanly and stopping it is immediate. */
#include <stddef.h>
#include <stdint.h>

struct fm1c_api {
    int (*init)(void);
    uint32_t (*rate)(void);
    void (*render)(int16_t *, uint32_t);
    uint32_t (*ms)(void);
    void (*master)(uint32_t);
    void (*key)(uint32_t, uint32_t), (*button)(uint32_t, uint32_t), (*enc)(uint32_t, int32_t);
    void (*midi)(uint32_t, uint32_t, uint32_t);
    const uint16_t *(*fb)(void);
    uint32_t (*fb_hash)(void), (*leds_buttons)(void), (*leds_keys)(void), (*glow_keys)(void);
    uint32_t (*blob_count)(void), (*blob_size)(void), (*store_hash)(void);
    uint8_t *(*blob)(uint32_t);
    void (*debug)(uint32_t);
    int (*ended)(void);
    void (*stop)(void);
    int (*quit)(uint32_t timeout_ms);
    void (*state)(void **data, size_t *data_n, void **bss, size_t *bss_n);
    int (*on_loop_thread)(void);
};

int fm1c_init(void);
uint32_t fm1c_rate(void);
void fm1c_render(int16_t *, uint32_t);
uint32_t fm1c_ms(void);
void fm1c_master(uint32_t);
void fm1c_key(uint32_t, uint32_t);
void fm1c_button(uint32_t, uint32_t);
void fm1c_enc(uint32_t, int32_t);
void fm1c_midi(uint32_t, uint32_t, uint32_t);
const uint16_t *fm1c_fb(void);
uint32_t fm1c_fb_hash(void), fm1c_leds_buttons(void), fm1c_leds_keys(void), fm1c_glow_keys(void);
uint32_t fm1c_blob_count(void), fm1c_blob_size(void), fm1c_store_hash(void);
uint8_t *fm1c_blob(uint32_t);
void fm1c_debug(uint32_t);

static int ended(void) { return 0; }
static void stop(void) {}
static int quit(uint32_t timeout_ms) { (void)timeout_ms; return 0; }
static int on_loop_thread(void) { return 0; }

#define FM1C_SECT(edge, s) __asm("section$" #edge "$__DATA$" s)
extern char fm1c_data_start FM1C_SECT(start, FM1C_DATA), fm1c_data_end FM1C_SECT(end, FM1C_DATA);
extern char fm1c_bss_start FM1C_SECT(start, FM1C_BSS), fm1c_bss_end FM1C_SECT(end, FM1C_BSS);
static void state(void **data, size_t *data_n, void **bss, size_t *bss_n)
{
    *data = &fm1c_data_start;
    *data_n = (size_t)(&fm1c_data_end - &fm1c_data_start);
    *bss = &fm1c_bss_start;
    *bss_n = (size_t)(&fm1c_bss_end - &fm1c_bss_start);
}

__attribute__((used, visibility("default"))) const struct fm1c_api FM1C_TABLE = {
    fm1c_init, fm1c_rate, fm1c_render, fm1c_ms, fm1c_master, fm1c_key, fm1c_button, fm1c_enc, fm1c_midi,
    fm1c_fb, fm1c_fb_hash, fm1c_leds_buttons, fm1c_leds_keys, fm1c_glow_keys,
    fm1c_blob_count, fm1c_blob_size, fm1c_store_hash, fm1c_blob, fm1c_debug,
    ended, stop, quit, state, on_loop_thread,
};
