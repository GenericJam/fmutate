/* SPDX-License-Identifier: GPL-3.0-only */
/* native_catalog generic shims (tools/native_catalog/build.py, tried when a firmware's plain native build fails):
 * the differences between the firmwares' build targets (the FM-1's pi32v2 ELF, WebAssembly) and a native one that
 * a whole class of firmwares runs into. Included first in every unit. */
#ifndef FM1_NATIVE_SHIMS_H
#define FM1_NATIVE_SHIMS_H
#ifdef __APPLE__
/* Mach-O section names are "segment,section": the firmwares' ELF ones (".pool", ".noinit", ...) are rejected */
#define section(x) __unused__
#endif
#endif
