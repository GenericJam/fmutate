/* SPDX-License-Identifier: GPL-3.0-only */
/* native_catalog shim: what a browser build takes from Emscripten, for a native build of the same file */
#ifndef FM1_NATIVE_EMSCRIPTEN_H
#define FM1_NATIVE_EMSCRIPTEN_H
#define EMSCRIPTEN_KEEPALIVE __attribute__((used, visibility("default")))
#define EM_JS(ret, name, params, ...) static ret name params { return (ret)0; }
#define EM_ASM(...) ((void)0)
#define EM_ASM_INT(...) 0
static inline double emscripten_get_now(void) { return 0.0; }
#endif
