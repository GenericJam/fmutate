/*
 * c_src/fm1mix.c — FMutate's mixer: a mob_audio_io processor ("fm1_mixer") that mixes the firmware engines' rings
 * (shared memory files written by the engines, see docs/engine_protocol.md) into the output stream mob_audio_io
 * owns (AAudio on Android, a RemoteIO unit and the audio session on iOS).
 *
 * Included by c_src/fm1audio.c (the NIF FMutate.AudioNif) and by test/c/fm1mix_host.c (host checks); plain C
 * over the plugin's C interface (deps/mob_audio_io/priv/include/mob_audio_io.h), no erl_nif, no platform API.
 *
 * - Up to NSLOT rings, each with a gain ramp (crossfades when switching firmware).
 * - The mixer's clock counts frames at the firmwares' rate (44.1 kHz). After every callback it writes into
 *   each ring the mixer frame at which the ring's next frame will play (`mix_minus_r`), so an engine can turn
 *   "MIDI at mixer frame M" into its own sample index. It goes on across the stream's reopens.
 * - The device may run at another rate (48 kHz is common): the mix is made at 44.1 kHz and resampled
 *   linearly to the stream's rate, which each MAI_EVENT_STARTED carries (a reopen may bring another).
 * - It never waits for an engine: a ring without enough frames plays silence for the rest and counts an
 *   underrun.
 * - The output is soft-clipped above SOFT_KNEE; `peak` is the loudest sample since the last read, 0..32767.
 * - One stream at a time renders it (FMutate.Audio opens one): the mixer's state is the audio thread's.
 */
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../deps/mob_audio_io/priv/include/mob_audio_io.h"

#define FM1MIX_PROCESSOR "fm1_mixer"
#define NSLOT 4
#define SRC_RATE 44100.0
#define MAX_SRC 4096                          /* source frames per callback, at most */
#define RING_MAGIC 0x464D3152u
#define SOFT_KNEE 0.75f

typedef struct {
    uint32_t magic, capacity, rate, pad0;
    volatile uint64_t w, r;
    volatile int64_t mix_minus_r;
    volatile uint32_t mix_valid;
    uint8_t pad1[20];
} ring_hdr;

struct slot {
    ring_hdr *_Atomic ring;                   /* read by the audio callback */
    size_t map_len;
    float gain, target, step;                 /* step per source frame while ramping */
    _Atomic uint32_t underruns;
};

static struct slot slots[NSLOT];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;   /* attach/detach, never the callback */
static _Atomic uint64_t frame;                /* mixer clock: source (44.1 kHz) frames mixed so far */
static _Atomic uint64_t callbacks;
static _Atomic uint32_t peak;
static _Atomic int32_t dev_rate = 44100;      /* the stream's rate (set at STARTED, before its first callback) */
static _Atomic int out_running;               /* between the stream's STARTED and STOPPED: callbacks may run */
static double rs_pos;                         /* resampler: position in the current source block */
static float rs_prev[2];                      /* the last source frame of the previous block */

/* ---- mixing (audio thread) */

static void mix_source(float *acc, uint32_t n)     /* n source frames into acc (stereo, -1..1) */
{
    uint64_t f0 = atomic_load(&frame);
    memset(acc, 0, n * 2 * sizeof(float));
    for (int s = 0; s < NSLOT; s++) {
        struct slot *sl = &slots[s];
        ring_hdr *rg = atomic_load(&sl->ring);
        uint64_t w, r;
        uint32_t avail, take, i;
        const int16_t *d;
        if (!rg) continue;
        w = __atomic_load_n(&rg->w, __ATOMIC_ACQUIRE);
        r = rg->r;
        avail = (uint32_t)(w - r);
        if (avail > rg->capacity) {           /* the engine restarted its ring under us: catch up */
            r = w;
            avail = 0;
        }
        take = avail < n ? avail : n;
        if (take < n && (sl->gain > 0 || sl->target > 0)) atomic_fetch_add(&sl->underruns, 1);
        d = (const int16_t *)(rg + 1);
        for (i = 0; i < n; i++) {
            if (sl->step != 0) {
                sl->gain += sl->step;
                if ((sl->step > 0 && sl->gain >= sl->target) || (sl->step < 0 && sl->gain <= sl->target)) {
                    sl->gain = sl->target;
                    sl->step = 0;
                }
            }
            if (i < take && sl->gain > 0) {
                uint32_t pos = (uint32_t)((r + i) % rg->capacity);
                acc[2 * i] += d[2 * pos] * (sl->gain / 32768.0f);
                acc[2 * i + 1] += d[2 * pos + 1] * (sl->gain / 32768.0f);
            }
        }
        /* the ring's next frame (r + take) plays at mixer frame (f0 + n) */
        rg->mix_minus_r = (int64_t)(f0 + n) - (int64_t)(r + take);
        __atomic_store_n(&rg->mix_valid, 1u, __ATOMIC_RELEASE);
        __atomic_store_n(&rg->r, r + take, __ATOMIC_RELEASE);
    }
    atomic_store(&frame, f0 + n);
}

/* the soft clip; *pk keeps the loudest sample (0..32767) */
static float out_sample(float x, uint32_t *pk)
{
    float ax = fabsf(x);
    uint32_t a;
    if (ax > SOFT_KNEE) x = copysignf(SOFT_KNEE + (1 - SOFT_KNEE) * tanhf((ax - SOFT_KNEE) / (1 - SOFT_KNEE)), x);
    a = (uint32_t)(fabsf(x) * 32767.0f);
    if (a > *pk) *pk = a;
    return x;
}

/* device frame i of `out` (ch interleaved channels): the stereo mix, or both halves of it for one channel */
static void put_frame(float *out, int32_t ch, int32_t i, float l, float r, uint32_t *pk)
{
    if (ch == 1) {
        out[i] = out_sample(0.5f * (l + r), pk);
    } else {
        out[(size_t)i * (size_t)ch] = out_sample(l, pk);
        out[(size_t)i * (size_t)ch + 1] = out_sample(r, pk);
    }
}

/* n device frames of interleaved float (ch channels; beyond the first two they stay silent), at dev_rate */
static void render_out(float *out, int32_t n, int32_t ch)
{
    static float src[(MAX_SRC + 2) * 2];
    uint32_t pk = atomic_load(&peak);
    int32_t rate = atomic_load_explicit(&dev_rate, memory_order_relaxed);
    if (rate == 44100) {
        for (int32_t done = 0; done < n;) {
            uint32_t k = (uint32_t)(n - done) > MAX_SRC ? MAX_SRC : (uint32_t)(n - done);
            mix_source(src, k);
            for (uint32_t i = 0; i < k; i++) put_frame(out, ch, done + (int32_t)i, src[2 * i], src[2 * i + 1], &pk);
            done += (int32_t)k;
        }
    } else {
        /* linear resampling. src[0] is the previous block's last source frame, src[k] the k-th new one;
           device frame i sits at source position rs_pos + i * step (rs_pos in [0, 1) from src[0]). Taking
           floor(rs_pos + n * step) new frames keeps every interpolation inside the block and leaves the
           next block's rs_pos in [0, 1). */
        double step = SRC_RATE / rate;
        uint32_t need = (uint32_t)floor(rs_pos + n * step);
        if (need > MAX_SRC) need = MAX_SRC;
        if (need < 1) need = 1;
        mix_source(src + 2, need);
        src[0] = rs_prev[0];
        src[1] = rs_prev[1];
        for (int32_t i = 0; i < n; i++) {
            double p = rs_pos + i * step;
            uint32_t j = (uint32_t)p;
            float fr = (float)(p - j);
            if (j + 1 > need) { j = need - 1; fr = 1; }   /* (only when MAX_SRC capped the block) */
            put_frame(out, ch, i, src[2 * j] + fr * (src[2 * (j + 1)] - src[2 * j]),
                      src[2 * j + 1] + fr * (src[2 * (j + 1) + 1] - src[2 * j + 1]), &pk);
        }
        rs_pos = rs_pos + n * step - need;
        rs_prev[0] = src[2 * need];
        rs_prev[1] = src[2 * need + 1];
    }
    atomic_store(&peak, pk);
    atomic_fetch_add(&callbacks, 1);
}

/* ---- the processor (mob_audio_io calls these) */

static void fm1mix_render(void *ctx, float *out, int32_t frames, const mai_time *t)
{
    (void)ctx;
    render_out(out, frames, t->channels);
}

/* never beside a callback: STARTED comes before the stream's first, STOPPED after its last */
static void fm1mix_stream_event(void *ctx, int32_t stream, int32_t event, const mai_time *t)
{
    (void)ctx; (void)stream;
    if (event == MAI_EVENT_STARTED) {
        atomic_store(&dev_rate, t->rate > 0 ? t->rate : 44100);
        rs_pos = 0;
        rs_prev[0] = rs_prev[1] = 0;
        atomic_store(&out_running, 1);
    } else if (event == MAI_EVENT_STOPPED) {
        atomic_store(&out_running, 0);
    }
}

/* Register "fm1_mixer" (from the NIF's load). MAI_OK, or the plugin's error; -100 when the linked plugin speaks
 * another C ABI than the header this was built with. */
static int32_t fm1mix_register(void)
{
    static const mai_processor p = {fm1mix_render, NULL, fm1mix_stream_event};
    if (mai_abi_version() != MAI_ABI_VERSION) return -100;
    return mai_register(FM1MIX_PROCESSOR, &p, NULL);
}

/* ---- the slots (normal threads: the NIF's calls) */

/* Wait until the audio callback has run once more, so it no longer holds a ring we are unmapping. */
static void wait_callback(void)
{
    uint64_t c = atomic_load(&callbacks);
    for (int i = 0; i < 100 && atomic_load(&out_running) && atomic_load(&callbacks) == c; i++) usleep(1000);
}

static void detach_locked(int s)
{
    ring_hdr *rg = atomic_exchange(&slots[s].ring, NULL);
    if (!rg) return;
    wait_callback();
    munmap(rg, slots[s].map_len);
    slots[s].map_len = 0;
}

/* Map the ring file at `path` into slot s (0..NSLOT-1), silent (gain 0); NULL or what went wrong. */
static const char *fm1mix_attach(int s, const char *path)
{
    int fd = open(path, O_RDWR);
    struct stat st;
    void *p;
    if (fd < 0 || fstat(fd, &st) || (size_t)st.st_size < sizeof(ring_hdr)) {
        if (fd >= 0) close(fd);
        return "cannot open ring";
    }
    p = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return "mmap failed";
    if (((ring_hdr *)p)->magic != RING_MAGIC) {
        munmap(p, (size_t)st.st_size);
        return "not a ring";
    }
    pthread_mutex_lock(&lock);
    detach_locked(s);
    slots[s].gain = slots[s].target = slots[s].step = 0;
    atomic_store(&slots[s].underruns, 0);
    slots[s].map_len = (size_t)st.st_size;
    /* start at the engine's write position: what it queued before we listened is stale */
    __atomic_store_n(&((ring_hdr *)p)->r, ((ring_hdr *)p)->w, __ATOMIC_RELEASE);
    atomic_store(&slots[s].ring, (ring_hdr *)p);
    pthread_mutex_unlock(&lock);
    return NULL;
}

static void fm1mix_detach(int s)
{
    pthread_mutex_lock(&lock);
    detach_locked(s);
    pthread_mutex_unlock(&lock);
}

/* Ramp slot s's gain to permille/1000 over ramp_ms (at once for 0). */
static void fm1mix_gain(int s, int permille, int ramp_ms)
{
    struct slot *sl = &slots[s];
    /* (benign race with the callback: a ramp starting a period late is inaudible) */
    sl->target = permille / 1000.0f;
    sl->step = ramp_ms > 0 ? (sl->target - sl->gain) / (float)(ramp_ms * SRC_RATE / 1000) : 0;
    if (ramp_ms <= 0) sl->gain = sl->target;
}

/* What FMutate.AudioNif.stats/0 reports; reading `peak` resets it. */
struct fm1mix_stats {
    uint64_t frame, callbacks;
    int32_t rate;
    uint32_t peak;
    int running;
    uint32_t fills[NSLOT], underruns[NSLOT];
};

static void fm1mix_stats(struct fm1mix_stats *o)
{
    o->frame = atomic_load(&frame);
    o->callbacks = atomic_load(&callbacks);
    o->rate = atomic_load(&dev_rate);
    o->peak = atomic_exchange(&peak, 0);
    o->running = atomic_load(&out_running);
    pthread_mutex_lock(&lock);                /* (a ring isn't unmapped under us) */
    for (int s = 0; s < NSLOT; s++) {
        ring_hdr *rg = atomic_load(&slots[s].ring);
        o->fills[s] = rg ? (uint32_t)(rg->w - rg->r) : 0;
        o->underruns[s] = atomic_load(&slots[s].underruns);
    }
    pthread_mutex_unlock(&lock);
}
