/*
 * c_src/fm1audio.c — the audio output: an AAudio stream in the app process that mixes the firmware
 * engines' rings (shared memory files written by libfm1engine.so, see docs/engine_protocol.md).
 *
 * Statically linked into the app binary as the NIF `fm1audio` (mob.exs :static_nifs); Elixir side:
 * FMutate.AudioNif / FMutate.Audio.
 *
 * - Up to NSLOT rings, each with a gain ramp (crossfades when switching firmware).
 * - The mixer's clock counts frames at the firmwares' rate (44.1 kHz). After every callback it writes into
 *   each ring the mixer frame at which the ring's next frame will play (`mix_minus_r`), so an engine can turn
 *   "MIDI at mixer frame M" into its own sample index.
 * - The device may run at another rate (48 kHz is common): the mix is made at 44.1 kHz and resampled
 *   linearly to the stream's rate.
 * - It never waits for an engine: a ring without enough frames plays silence for the rest and counts an
 *   underrun.
 * - AAudio is loaded with dlopen (libaaudio.so, API 26+), so the app binary needs no extra link flag.
 * - When the stream disconnects (headphones in or out, a USB device), it is reopened from a helper thread.
 */
#include <erl_nif.h>

#include <aaudio/AAudio.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

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

/* ---- AAudio, loaded at runtime */
static struct {
    void *h;
    aaudio_result_t (*createStreamBuilder)(AAudioStreamBuilder **);
    void (*setFormat)(AAudioStreamBuilder *, aaudio_format_t);
    void (*setChannelCount)(AAudioStreamBuilder *, int32_t);
    void (*setSampleRate)(AAudioStreamBuilder *, int32_t);
    void (*setPerformanceMode)(AAudioStreamBuilder *, aaudio_performance_mode_t);
    void (*setSharingMode)(AAudioStreamBuilder *, aaudio_sharing_mode_t);
    void (*setUsage)(AAudioStreamBuilder *, aaudio_usage_t);
    void (*setContentType)(AAudioStreamBuilder *, aaudio_content_type_t);
    void (*setDataCallback)(AAudioStreamBuilder *, AAudioStream_dataCallback, void *);
    void (*setErrorCallback)(AAudioStreamBuilder *, AAudioStream_errorCallback, void *);
    aaudio_result_t (*openStream)(AAudioStreamBuilder *, AAudioStream **);
    aaudio_result_t (*builderDelete)(AAudioStreamBuilder *);
    aaudio_result_t (*requestStart)(AAudioStream *);
    aaudio_result_t (*close)(AAudioStream *);
    int32_t (*getSampleRate)(AAudioStream *);
    int32_t (*getFramesPerBurst)(AAudioStream *);
    aaudio_result_t (*setBufferSizeInFrames)(AAudioStream *, int32_t);
    int32_t (*getBufferSizeInFrames)(AAudioStream *);
    aaudio_sharing_mode_t (*getSharingMode)(AAudioStream *);
    aaudio_performance_mode_t (*getPerformanceMode)(AAudioStream *);
    int32_t (*getXRunCount)(AAudioStream *);
    int64_t (*getFramesWritten)(AAudioStream *);
    aaudio_result_t (*getTimestamp)(AAudioStream *, clockid_t, int64_t *, int64_t *);
    const char *(*convertResultToText)(aaudio_result_t);
} A;

static struct slot slots[NSLOT];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;   /* open/close/attach/detach, never the callback */
static AAudioStream *stream;
static _Atomic int want_running;
static _Atomic uint64_t frame;                /* mixer clock: source (44.1 kHz) frames mixed so far */
static _Atomic uint64_t callbacks;
static _Atomic uint32_t peak;
static int32_t dev_rate = 44100;
static double rs_pos;                         /* resampler: position in the current source block */
static float rs_prev[2];                      /* the last source frame of the previous block */

static int load_aaudio(void)
{
    if (A.h) return 0;
    A.h = dlopen("libaaudio.so", RTLD_NOW);
    if (!A.h) return -1;
#define S(f, n) if (!(*(void **)&A.f = dlsym(A.h, n))) return -1
    S(createStreamBuilder, "AAudio_createStreamBuilder");
    S(setFormat, "AAudioStreamBuilder_setFormat");
    S(setChannelCount, "AAudioStreamBuilder_setChannelCount");
    S(setSampleRate, "AAudioStreamBuilder_setSampleRate");
    S(setPerformanceMode, "AAudioStreamBuilder_setPerformanceMode");
    S(setSharingMode, "AAudioStreamBuilder_setSharingMode");
    S(setUsage, "AAudioStreamBuilder_setUsage");
    S(setContentType, "AAudioStreamBuilder_setContentType");
    S(setDataCallback, "AAudioStreamBuilder_setDataCallback");
    S(setErrorCallback, "AAudioStreamBuilder_setErrorCallback");
    S(openStream, "AAudioStreamBuilder_openStream");
    S(builderDelete, "AAudioStreamBuilder_delete");
    S(requestStart, "AAudioStream_requestStart");
    S(close, "AAudioStream_close");
    S(getSampleRate, "AAudioStream_getSampleRate");
    S(getFramesPerBurst, "AAudioStream_getFramesPerBurst");
    S(setBufferSizeInFrames, "AAudioStream_setBufferSizeInFrames");
    S(getBufferSizeInFrames, "AAudioStream_getBufferSizeInFrames");
    S(getSharingMode, "AAudioStream_getSharingMode");
    S(getPerformanceMode, "AAudioStream_getPerformanceMode");
    S(getXRunCount, "AAudioStream_getXRunCount");
    S(getFramesWritten, "AAudioStream_getFramesWritten");
    S(getTimestamp, "AAudioStream_getTimestamp");
    S(convertResultToText, "AAudio_convertResultToText");
#undef S
    return 0;
}

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

static int16_t out_sample(float x, uint32_t *pk)
{
    float ax = fabsf(x);
    uint32_t a;
    if (ax > SOFT_KNEE) x = copysignf(SOFT_KNEE + (1 - SOFT_KNEE) * tanhf((ax - SOFT_KNEE) / (1 - SOFT_KNEE)), x);
    a = (uint32_t)(fabsf(x) * 32767.0f);
    if (a > *pk) *pk = a;
    return (int16_t)(x * 32767.0f);
}

static aaudio_data_callback_result_t on_data(AAudioStream *st, void *user, void *audio, int32_t n)
{
    static float src[(MAX_SRC + 2) * 2];
    int16_t *out = audio;
    uint32_t pk = atomic_load(&peak);
    (void)st; (void)user;
    if (dev_rate == 44100) {
        for (int32_t done = 0; done < n;) {
            uint32_t k = (uint32_t)(n - done) > MAX_SRC ? MAX_SRC : (uint32_t)(n - done);
            mix_source(src, k);
            for (uint32_t i = 0; i < 2 * k; i++) out[2 * done + i] = out_sample(src[i], &pk);
            done += (int32_t)k;
        }
    } else {
        /* linear resampling. src[0] is the previous block's last source frame, src[k] the k-th new one;
           device frame i sits at source position rs_pos + i * step (rs_pos in [0, 1) from src[0]). Taking
           floor(rs_pos + n * step) new frames keeps every interpolation inside the block and leaves the
           next block's rs_pos in [0, 1). */
        double step = SRC_RATE / dev_rate;
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
            for (int c = 0; c < 2; c++)
                out[2 * i + c] = out_sample(src[2 * j + c] + fr * (src[2 * (j + 1) + c] - src[2 * j + c]), &pk);
        }
        rs_pos = rs_pos + n * step - need;
        rs_prev[0] = src[2 * need];
        rs_prev[1] = src[2 * need + 1];
    }
    atomic_store(&peak, pk);
    atomic_fetch_add(&callbacks, 1);
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

static int open_stream_locked(void);

static void *reopen_thread(void *arg)
{
    (void)arg;
    usleep(100000);
    pthread_mutex_lock(&lock);
    if (stream) { A.close(stream); stream = NULL; }
    if (atomic_load(&want_running)) open_stream_locked();
    pthread_mutex_unlock(&lock);
    return NULL;
}

static void on_error(AAudioStream *st, void *user, aaudio_result_t err)
{
    pthread_t t;
    (void)st; (void)user;
    if (err == AAUDIO_ERROR_DISCONNECTED && pthread_create(&t, NULL, reopen_thread, NULL) == 0) pthread_detach(t);
}

static int open_stream_locked(void)
{
    AAudioStreamBuilder *b;
    aaudio_result_t res;
    if (A.createStreamBuilder(&b) != AAUDIO_OK) return -1;
    A.setFormat(b, AAUDIO_FORMAT_PCM_I16);
    A.setChannelCount(b, 2);
    /* the device's own rate (usually 48 kHz) and an exclusive stream give the lowest latency; asking for
       44.1 kHz pushes AAudio into a slower resampling path. on_data resamples instead. */
    A.setSampleRate(b, AAUDIO_UNSPECIFIED);
    A.setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    A.setSharingMode(b, AAUDIO_SHARING_MODE_EXCLUSIVE);
    A.setUsage(b, AAUDIO_USAGE_MEDIA);
    A.setContentType(b, AAUDIO_CONTENT_TYPE_MUSIC);
    A.setDataCallback(b, on_data, NULL);
    A.setErrorCallback(b, on_error, NULL);
    res = A.openStream(b, &stream);
    if (res != AAUDIO_OK) {                  /* no exclusive stream: shared */
        A.setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
        res = A.openStream(b, &stream);
    }
    A.builderDelete(b);
    if (res != AAUDIO_OK) { stream = NULL; return res; }
    dev_rate = A.getSampleRate(stream);
    rs_pos = 0;
    rs_prev[0] = rs_prev[1] = 0;
    A.setBufferSizeInFrames(stream, A.getFramesPerBurst(stream) * 2);   /* double buffering */
    res = A.requestStart(stream);
    if (res != AAUDIO_OK) { A.close(stream); stream = NULL; }
    return res;
}

/* ---- NIFs */

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *a) { return enif_make_atom(env, a); }

static ERL_NIF_TERM error_text(ErlNifEnv *env, const char *what, int res)
{
    const char *t = (A.convertResultToText && res < 0) ? A.convertResultToText(res) : what;
    return enif_make_tuple2(env, atom(env, "error"), enif_make_string(env, t ? t : what, ERL_NIF_LATIN1));
}

/* start() -> :ok | {:error, reason} */
static ERL_NIF_TERM nif_start(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int res = 0;
    (void)argc; (void)argv;
    if (load_aaudio()) return error_text(env, "libaaudio.so not available", 0);
    pthread_mutex_lock(&lock);
    atomic_store(&want_running, 1);
    if (!stream) res = open_stream_locked();
    pthread_mutex_unlock(&lock);
    return res == AAUDIO_OK ? atom(env, "ok") : error_text(env, "open failed", res);
}

static ERL_NIF_TERM nif_stop(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    pthread_mutex_lock(&lock);
    atomic_store(&want_running, 0);
    if (stream) { A.close(stream); stream = NULL; }
    pthread_mutex_unlock(&lock);
    return atom(env, "ok");
}

/* Wait until the audio callback has run once more, so it no longer holds a ring we are unmapping. */
static void wait_callback(void)
{
    uint64_t c = atomic_load(&callbacks);
    for (int i = 0; i < 100 && stream && atomic_load(&callbacks) == c; i++) usleep(1000);
}

static void detach_locked(int s)
{
    ring_hdr *rg = atomic_exchange(&slots[s].ring, NULL);
    if (!rg) return;
    wait_callback();
    munmap(rg, slots[s].map_len);
    slots[s].map_len = 0;
}

/* attach(slot, path) -> :ok | {:error, reason}; the slot starts silent (gain 0) */
static ERL_NIF_TERM nif_attach(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int s, fd;
    char path[1024];
    struct stat st;
    void *p;
    (void)argc;
    if (!enif_get_int(env, argv[0], &s) || s < 0 || s >= NSLOT) return enif_make_badarg(env);
    if (enif_get_string(env, argv[1], path, sizeof path, ERL_NIF_LATIN1) <= 0) {
        ErlNifBinary bin;
        if (!enif_inspect_binary(env, argv[1], &bin) || bin.size >= sizeof path) return enif_make_badarg(env);
        memcpy(path, bin.data, bin.size);
        path[bin.size] = 0;
    }
    fd = open(path, O_RDWR);
    if (fd < 0 || fstat(fd, &st) || (size_t)st.st_size < sizeof(ring_hdr)) {
        if (fd >= 0) close(fd);
        return error_text(env, "cannot open ring", 0);
    }
    p = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return error_text(env, "mmap failed", 0);
    if (((ring_hdr *)p)->magic != RING_MAGIC) { munmap(p, (size_t)st.st_size); return error_text(env, "not a ring", 0); }
    pthread_mutex_lock(&lock);
    detach_locked(s);
    slots[s].gain = slots[s].target = slots[s].step = 0;
    atomic_store(&slots[s].underruns, 0);
    slots[s].map_len = (size_t)st.st_size;
    /* start at the engine's write position: what it queued before we listened is stale */
    __atomic_store_n(&((ring_hdr *)p)->r, ((ring_hdr *)p)->w, __ATOMIC_RELEASE);
    atomic_store(&slots[s].ring, (ring_hdr *)p);
    pthread_mutex_unlock(&lock);
    return atom(env, "ok");
}

static ERL_NIF_TERM nif_detach(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int s;
    (void)argc;
    if (!enif_get_int(env, argv[0], &s) || s < 0 || s >= NSLOT) return enif_make_badarg(env);
    pthread_mutex_lock(&lock);
    detach_locked(s);
    pthread_mutex_unlock(&lock);
    return atom(env, "ok");
}

/* gain(slot, permille, ramp_ms) -> :ok */
static ERL_NIF_TERM nif_gain(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int s, g, ramp;
    struct slot *sl;
    (void)argc;
    if (!enif_get_int(env, argv[0], &s) || s < 0 || s >= NSLOT || !enif_get_int(env, argv[1], &g) ||
        !enif_get_int(env, argv[2], &ramp))
        return enif_make_badarg(env);
    sl = &slots[s];
    /* (benign race with the callback: a ramp starting a period late is inaudible) */
    sl->target = g / 1000.0f;
    sl->step = ramp > 0 ? (sl->target - sl->gain) / (float)(ramp * SRC_RATE / 1000) : 0;
    if (ramp <= 0) sl->gain = sl->target;
    return atom(env, "ok");
}

/* stats() -> %{frame, rate, peak, latency_ms, xruns, running, sharing, fills, underruns} */
static ERL_NIF_TERM nif_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM keys[9], vals[9], fills[NSLOT], unders[NSLOT], map;
    double latency = -1;
    int xruns = 0, running = 0, exclusive = 0;
    (void)argc; (void)argv;
    pthread_mutex_lock(&lock);
    if (stream) {
        int64_t pos, ns;
        running = 1;
        xruns = A.getXRunCount(stream);
        exclusive = A.getSharingMode(stream) == AAUDIO_SHARING_MODE_EXCLUSIVE;
        if (A.getTimestamp(stream, CLOCK_MONOTONIC, &pos, &ns) == AAUDIO_OK) {
            /* frames written but not yet presented, plus the time since that frame was presented */
            struct timespec now;
            int64_t written = A.getFramesWritten(stream);
            clock_gettime(CLOCK_MONOTONIC, &now);
            double since = ((now.tv_sec * 1000000000LL + now.tv_nsec) - ns) / 1e9;
            latency = ((written - pos) / (double)dev_rate - since) * 1000.0;
        }
    }
    pthread_mutex_unlock(&lock);
    for (int s = 0; s < NSLOT; s++) {
        ring_hdr *rg = atomic_load(&slots[s].ring);
        fills[s] = enif_make_uint(env, rg ? (unsigned)(rg->w - rg->r) : 0);
        unders[s] = enif_make_uint(env, atomic_load(&slots[s].underruns));
    }
    keys[0] = atom(env, "frame");      vals[0] = enif_make_uint64(env, atomic_load(&frame));
    keys[1] = atom(env, "rate");       vals[1] = enif_make_int(env, dev_rate);
    keys[2] = atom(env, "peak");       vals[2] = enif_make_uint(env, atomic_exchange(&peak, 0));
    keys[3] = atom(env, "latency_ms"); vals[3] = latency >= 0 ? enif_make_double(env, latency) : atom(env, "nil");
    keys[4] = atom(env, "xruns");      vals[4] = enif_make_int(env, xruns);
    keys[5] = atom(env, "running");    vals[5] = atom(env, running ? "true" : "false");
    keys[6] = atom(env, "sharing");    vals[6] = atom(env, exclusive ? "exclusive" : "shared");
    keys[7] = atom(env, "fills");      vals[7] = enif_make_list_from_array(env, fills, NSLOT);
    keys[8] = atom(env, "underruns");  vals[8] = enif_make_list_from_array(env, unders, NSLOT);
    enif_make_map_from_arrays(env, keys, vals, 9, &map);
    return map;
}

static ErlNifFunc nif_funcs[] = {
    {"start", 0, nif_start, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"stop", 0, nif_stop, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"attach", 2, nif_attach, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"detach", 1, nif_detach, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"gain", 3, nif_gain, 0},
    {"stats", 0, nif_stats, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.FMutate.AudioNif, nif_funcs, NULL, NULL, NULL, NULL)
