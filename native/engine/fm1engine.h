/* SPDX-License-Identifier: GPL-3.0-only */
/* The firmware engine's core (fm1engine.c), shared by its two hosts: the executable (fm1engine.c's main, one OS
 * process per firmware, Android and the tests) and the in-process host (c_src/fm1host.c, iOS, an engine per
 * thread). docs/engine_protocol.md describes what it does; docs/decisions/2026-11-13-ios-port.md why two hosts. */
#ifndef FM1ENGINE_H
#define FM1ENGINE_H

#include <stddef.h>
#include <stdint.h>

/* A cartridge's panel API: live.c's fm1c_* calls, found with dlsym in a cartridge built as a shared library, or
 * the table a cartridge linked into the app exports (FM1C_TABLE in live.c). */
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
    /* Linked in only (NULL from dlsym's table): */
    int (*ended)(void);                   /* the firmware's loop has stopped: 0 no, 1 quit, 2 crashed (debug) */
    void (*stop)(void);                   /* ask the loop to stop at its next park point (any thread) */
    int (*quit)(uint32_t timeout_ms);     /* stop it and wait: 0 ended (its thread joined), -1 still running */
    void (*state)(void **data, size_t *data_n, void **bss, size_t *bss_n);   /* its globals, for a fresh boot */
    int (*on_loop_thread)(void);          /* the caller is its firmware's loop thread (async-signal-safe) */
};

/* How an engine talks to its host. */
struct fm1engine_io {
    void *ctx;
    int in_fd;                            /* port messages in ({packet, 2}); EOF = closed: save the flash, end */
    int (*send)(void *ctx, const uint8_t *msg, uint32_t n);   /* one message out; nonzero = nobody listens */
    const volatile int *abandoned;        /* the host gave up on this engine: end at once, save nothing (NULL:
                                             a process, killed from outside instead) */
};

/* Exit codes, as the executable's: 0 closed (flash saved) or the host is gone, 2 error before READY,
 * 139 debug crash in-process (an OS process dies of SIGSEGV instead), 137 abandoned. */
#define FM1ENGINE_EXIT_OK 0
#define FM1ENGINE_EXIT_ERROR 2
#define FM1ENGINE_EXIT_KILLED 137
#define FM1ENGINE_EXIT_CRASHED 139

/* Run one cartridge until its port closes: `prefix`.ring and `prefix`.fb, the flash file, the target ring fill
 * (0 = the default). Returns an exit code above. */
int fm1engine_run(const struct fm1c_api *cart, const char *prefix, const char *flash, uint32_t fill,
                  const struct fm1engine_io *io);

#endif
