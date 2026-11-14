/* SPDX-License-Identifier: GPL-3.0-only */
/* <ucontext.h> for a cartridge (tools/native_catalog/recipes/wasm.py puts this directory first on the include path):
 * a firmware's native simulator parks its never-returning main loop with getcontext / makecontext / swapcontext
 * (zp12's sim/sim.c under SIM_NATIVE). Android's C library has none of them and macOS only behind _XOPEN_SOURCE, so
 * here each context runs on its own thread and a switch hands control over (a mutex and a condition): exactly one
 * runs at a time, as with real contexts, on every target alike (native/engine/live.c does the same for Dinghy's
 * loop). What a firmware uses of the API: getcontext on a context it then gives a stack (uc_stack, at least
 * 1 MiB is used for the thread), uc_link and a function (makecontext, no arguments), swapcontext both ways. */
#ifndef FM1_UCONTEXT_THREADS_H
#define FM1_UCONTEXT_THREADS_H
#include <pthread.h>
#include <stddef.h>

typedef struct fm1_uctx {
    struct { void *ss_sp; size_t ss_size; int ss_flags; } uc_stack;
    struct fm1_uctx *uc_link;
    void (*fn)(void);
    pthread_t th;
    int started, run;
} ucontext_t;

static pthread_mutex_t fm1_uc_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fm1_uc_cv = PTHREAD_COND_INITIALIZER;

static void fm1_uc_go(ucontext_t *c)
{
    pthread_mutex_lock(&fm1_uc_mx);
    c->run = 1;
    pthread_cond_broadcast(&fm1_uc_cv);
    pthread_mutex_unlock(&fm1_uc_mx);
}
static void fm1_uc_wait(ucontext_t *c)
{
    pthread_mutex_lock(&fm1_uc_mx);
    while (!c->run)
        pthread_cond_wait(&fm1_uc_cv, &fm1_uc_mx);
    c->run = 0;
    pthread_mutex_unlock(&fm1_uc_mx);
}
static void *fm1_uc_thread(void *p)
{
    ucontext_t *c = (ucontext_t *)p;
    fm1_uc_wait(c);
    c->fn();
    if (c->uc_link)                             /* (the function returned: on to its link, this thread ends) */
        fm1_uc_go(c->uc_link);
    return 0;
}
static __attribute__((unused)) int getcontext(ucontext_t *c) { (void)c; return 0; }
static __attribute__((unused)) void makecontext(ucontext_t *c, void (*fn)(void), int argc, ...)
{
    (void)argc;
    c->fn = fn;
}
static __attribute__((unused)) int swapcontext(ucontext_t *from, ucontext_t *to)
{
    if (to->fn && !to->started) {
        pthread_attr_t a;
        size_t ss = to->uc_stack.ss_size < (1u << 20) ? (1u << 20) : to->uc_stack.ss_size;
        to->started = 1;
        pthread_attr_init(&a);
        pthread_attr_setstacksize(&a, ss);
        if (pthread_create(&to->th, &a, fm1_uc_thread, to))
            return -1;
        pthread_attr_destroy(&a);
    }
    fm1_uc_go(to);
    fm1_uc_wait(from);
    return 0;
}
#endif
