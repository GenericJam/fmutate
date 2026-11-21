/*
 * Host checks for c_src/fm1mix.c, the mixer FMutate registers with mob_audio_io ("fm1_mixer"): the processor is
 * driven the way the plugin drives it (stream_event, then render blocks with their mai_time), over a real ring
 * file. Built and run by test/fmutate/audio_mixer_test.exs:
 *
 *   cc -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -o /tmp/fm1mix_host \
 *      test/c/fm1mix_host.c -lm -lpthread
 *   /tmp/fm1mix_host <scratch dir>
 *
 * Exit 0 when every check holds, 1 otherwise (each failure is printed).
 */
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>

#include "../../c_src/fm1mix.c"

/* ---- the plugin's side, as far as fm1mix.c uses it */

static char registered_name[MAI_NAME_MAX];
static mai_processor proc;

int32_t mai_abi_version(void) { return MAI_ABI_VERSION; }

int32_t mai_register(const char *name, const mai_processor *p, void *ctx)
{
    (void)ctx;
    snprintf(registered_name, sizeof registered_name, "%s", name);
    proc = *p;
    return MAI_OK;
}

static int failures;

#define CHECK(cond, ...)                                              \
    do {                                                              \
        if (!(cond)) {                                                \
            failures++;                                               \
            fprintf(stderr, "%s:%d: %s: ", __FILE__, __LINE__, #cond); \
            fprintf(stderr, __VA_ARGS__);                             \
            fprintf(stderr, "\n");                                    \
        }                                                             \
    } while (0)

#define CAP 8192

/* An engine's ring (docs/engine_protocol.md): the header, then CAP stereo int16 frames. */
static ring_hdr *ring;

static ring_hdr *make_ring(const char *path)
{
    size_t len = sizeof(ring_hdr) + CAP * 4;
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    ring_hdr *r;
    if (fd < 0 || ftruncate(fd, (off_t)len)) return NULL;
    r = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (r == MAP_FAILED) return NULL;
    r->magic = RING_MAGIC;
    r->capacity = CAP;
    r->rate = 44100;
    return r;
}

/* the engine writes n frames of (l, r) */
static void produce(uint32_t n, int16_t l, int16_t r)
{
    int16_t *d = (int16_t *)(ring + 1);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t pos = (uint32_t)((ring->w + i) % CAP);
        d[2 * pos] = l;
        d[2 * pos + 1] = r;
    }
    __atomic_store_n(&ring->w, ring->w + n, __ATOMIC_RELEASE);
}

static void event(int32_t ev, int32_t rate, int32_t channels)
{
    mai_time t = {0, 0, 0, rate, channels};
    proc.stream_event(NULL, 1, ev, &t);
}

static float out[4096 * 2];

static void render(int32_t frames, int32_t channels)
{
    mai_time t = {0, 0, 0, 0, channels};
    memset(out, 0, sizeof out);                /* (the plugin hands render a zeroed buffer) */
    proc.render(NULL, out, frames, &t);
}

static int near(float a, float b) { return fabsf(a - b) < 1e-3f; }

int main(int argc, char **argv)
{
    char path[1024];
    struct fm1mix_stats st;
    if (argc < 2) {
        fprintf(stderr, "usage: fm1mix_host <scratch dir>\n");
        return 2;
    }
    snprintf(path, sizeof path, "%s/ring", argv[1]);

    CHECK(fm1mix_register() == MAI_OK, "register");
    CHECK(strcmp(registered_name, FM1MIX_PROCESSOR) == 0, "registered as %s", registered_name);
    CHECK(proc.render && proc.stream_event && !proc.capture, "an output processor");

    ring = make_ring(path);
    CHECK(ring != NULL, "ring file");
    if (!ring) return 1;
    produce(1000, 1, 1);                       /* (queued before the mixer listened: skipped) */
    CHECK(fm1mix_attach(0, path) == NULL, "attach");
    CHECK(ring->r == 1000, "attach starts at the engine's write position, r %llu", (unsigned long long)ring->r);
    fm1mix_stats(&st);
    CHECK(st.rate == 44100 && !st.running && st.frame == 0, "before a stream: rate %d running %d", st.rate,
          st.running);

    /* A 48 kHz stereo stream: 44.1 kHz frames mixed, resampled to the device's. */
    event(MAI_EVENT_STARTED, 48000, 2);
    fm1mix_stats(&st);
    CHECK(st.rate == 48000 && st.running, "started: rate %d running %d", st.rate, st.running);
    fm1mix_gain(0, 1000, 0);
    produce(CAP - 1000, 16384, -8192);        /* 0.5 left, -0.25 right */
    render(480, 2);
    CHECK(ring->r == 1000 + 441, "480 frames at 48 kHz take 441 at 44.1 kHz: r %llu",
          (unsigned long long)ring->r);
    CHECK(near(out[2 * 479], 0.5f) && near(out[2 * 479 + 1], -0.25f), "the ring's level: %f %f", out[2 * 479],
          out[2 * 479 + 1]);
    /* the ring's next frame plays at mixer frame 441 */
    CHECK(ring->mix_valid == 1 && ring->mix_minus_r == 441 - (int64_t)ring->r, "mix_minus_r %lld",
          (long long)ring->mix_minus_r);
    fm1mix_stats(&st);
    CHECK(st.frame == 441 && st.callbacks == 1, "clock %llu callbacks %llu", (unsigned long long)st.frame,
          (unsigned long long)st.callbacks);
    CHECK(st.peak == 16383, "peak %u", st.peak);
    CHECK(st.fills[0] == (uint32_t)(ring->w - ring->r), "fill %u", st.fills[0]);
    fm1mix_stats(&st);
    CHECK(st.peak == 0, "peak since the last read %u", st.peak);

    /* A second of 48 kHz in uneven blocks takes a second of 44.1 kHz, within the frame the resampler holds. */
    {
        uint64_t r0 = ring->r, f0 = st.frame;
        int32_t sizes[] = {192, 240, 480, 96, 4096};
        int32_t done = 0;
        for (int i = 0; done < 48000; i++) {
            int32_t n = sizes[i % 5] < 48000 - done ? sizes[i % 5] : 48000 - done;
            if (ring->w - ring->r < 4096) produce(4096, 16384, -8192);
            render(n, 2);
            done += n;
        }
        fm1mix_stats(&st);
        CHECK(st.frame - f0 >= 44099 && st.frame - f0 <= 44101, "a second: %llu mixed",
              (unsigned long long)(st.frame - f0));
        CHECK(ring->r - r0 == st.frame - f0, "the ring followed the clock: %llu", (unsigned long long)(ring->r - r0));
        CHECK(fabsf(out[0] - 0.5f) < 1e-3f, "steady level across blocks: %f", out[0]);
        CHECK(st.underruns[0] == 0, "underruns %u", st.underruns[0]);
    }

    /* Reopened at 44.1 kHz, mono (another device): no resampling, the two channels folded. */
    event(MAI_EVENT_STOPPED, 48000, 2);
    fm1mix_stats(&st);
    CHECK(!st.running, "stopped");
    event(MAI_EVENT_STARTED, 44100, 1);
    {
        uint64_t r0 = ring->r, f0 = st.frame;
        render(256, 1);
        fm1mix_stats(&st);
        CHECK(ring->r - r0 == 256 && st.frame - f0 == 256, "256 frames take 256: %llu",
              (unsigned long long)(ring->r - r0));
        CHECK(near(out[0], 0.125f) && near(out[255], 0.125f) && out[256] == 0, "mono %f %f", out[0], out[255]);
        CHECK(st.rate == 44100, "rate %d", st.rate);
    }

    /* A ring that runs dry: silence for the rest, one underrun, the clock goes on. */
    {
        uint32_t avail;
        uint64_t f0;
        event(MAI_EVENT_STOPPED, 44100, 1);
        event(MAI_EVENT_STARTED, 44100, 2);
        while (ring->w - ring->r > 1000) render(1000, 2);
        produce(500, 16384, -8192);
        avail = (uint32_t)(ring->w - ring->r);
        fm1mix_stats(&st);
        f0 = st.frame;
        render((int32_t)avail + 100, 2);
        fm1mix_stats(&st);
        CHECK(ring->r == ring->w, "took what there was");
        CHECK(st.underruns[0] == 1, "underruns %u", st.underruns[0]);
        CHECK(st.frame - f0 == avail + 100, "clock %llu", (unsigned long long)(st.frame - f0));
        CHECK(near(out[0], 0.5f) && out[2 * (avail + 99)] == 0 && out[2 * (avail + 99) + 1] == 0, "then silence");
    }

    /* Full scale is soft-clipped below 1; the peak keeps its 0..32767 scale. */
    produce(512, 32767, -32768);
    render(512, 2);
    fm1mix_stats(&st);
    CHECK(out[0] > SOFT_KNEE && out[0] < 1.0f && out[1] < -SOFT_KNEE && out[1] > -1.0f, "clipped %f %f", out[0],
          out[1]);
    CHECK(st.peak > 24575 && st.peak <= 32767, "peak %u", st.peak);

    /* A crossfade: a 10 ms ramp to silence (441 source frames). */
    produce(882, 16384, 16384);
    fm1mix_gain(0, 0, 10);
    render(882, 2);
    CHECK(out[0] > 0.49f && near(out[2 * 440], 0.0f) && out[2 * 881] == 0, "ramp %f %f %f", out[0], out[2 * 440],
          out[2 * 881]);

    /* Detach with the stream stopped doesn't wait for a callback; the slot plays nothing after. */
    event(MAI_EVENT_STOPPED, 44100, 2);
    fm1mix_detach(0);
    fm1mix_stats(&st);
    CHECK(st.fills[0] == 0, "detached fill %u", st.fills[0]);
    CHECK(fm1mix_attach(1, argv[1]) != NULL, "a directory isn't a ring");

    if (failures) fprintf(stderr, "%d check(s) failed\n", failures);
    else printf("fm1mix_host: all checks passed\n");
    return failures ? 1 : 0;
}
