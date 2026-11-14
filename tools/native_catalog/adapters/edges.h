/* SPDX-License-Identifier: GPL-3.0-only */
/* The panel's edges for the adapters of tools/native_catalog (included by adapters/<recipe>.c): native/engine/live.c's
 * rule. Input comes in batches, so a press and its release can arrive together between two passes of the firmware;
 * each input's edges are applied in order, each once the input's previous one has been in place EDGE_GAP_MS of
 * firmware time; an edge on an input steady that long is applied at once. Ids as fm1-emu's matrix: 0..13 the
 * buttons in wire order (0 OCT- 1 OCT+ 2 FX 3 SEL 4 ENV 5 LFO 6 EDIT 7 GLO 8 HOME 9 SAVE 10 ARP 11 SEQ 12 PLAY
 * 13 REC), 14..40 the keys (0 = F3).
 *
 * The including file defines, before including this:
 *   static uint32_t edge_now(void);                   the firmware's milliseconds
 *   static void edge_set(uint32_t i, uint32_t down);  apply one edge to the firmware
 * and calls edges_init() before boot, edges_due() before each pass (each millisecond of firmware time). */
#ifndef FM1N_EDGES_H
#define FM1N_EDGES_H
#include <stdint.h>

#define EDGE_GAP_MS 16u
#define EDGE_NIN 41u
#define EDGE_KEY0 14u
#define EDGE_QMAX 32u
static struct { uint32_t at; uint8_t on, n; } edge[EDGE_NIN];
static uint64_t edge_pending;

static void edge_apply(uint32_t i, uint32_t down)
{
    edge[i].on = (uint8_t)down;
    edge[i].at = edge_now();
    edge_set(i, down);
}
static int edge_settled(uint32_t i) { return edge_now() - edge[i].at >= EDGE_GAP_MS; }
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
static void edges_init(void)
{
    uint32_t i;
    for (i = 0; i < EDGE_NIN; i++) edge[i].at = edge_now() - EDGE_GAP_MS;
}

/* the panel's other masks, kept here from the edges for adapters whose firmware takes whole masks */
static uint32_t edge_buttons, edge_keys;
static void edge_masks(uint32_t i, uint32_t down)
{
    uint32_t *m = i >= EDGE_KEY0 ? &edge_keys : &edge_buttons, bit = 1u << (i >= EDGE_KEY0 ? i - EDGE_KEY0 : i);
    *m = down ? *m | bit : *m & ~bit;
}

static uint32_t fnv_bytes(uint32_t h, const void *p, uint32_t n)
{
    const uint8_t *b = (const uint8_t *)p;
    while (n--) h = (h ^ *b++) * 16777619u;
    return h;
}
#endif
