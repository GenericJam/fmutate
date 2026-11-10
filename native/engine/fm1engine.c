/* fm1engine: one firmware cartridge in its own OS process, driven over an Erlang Port ({packet, 2}).
 *
 *   fm1engine <cart.so> <shm_prefix> <flash_file> [target_fill_frames]
 *
 * Audio goes into <shm_prefix>.ring, the screen and the LEDs into <shm_prefix>.fb (docs/engine_protocol.md);
 * the port carries panel input in and READY / STATUS / FLASH_SAVED out. The firmware's own printf goes to
 * stderr: stdout is the port. The engine paces itself on the ring: it renders while fewer than the target fill
 * frames are queued, so the mixer's audio clock drives the firmware's clock. When the port closes it saves the
 * flash and exits. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define RING_FRAMES 4096u
#define TARGET_FILL 1024u                       /* default frames queued ahead of the mixer (~23 ms); the app
                                                   passes more when the audio device takes bigger bursts */
#define FB_BYTES (8u + 240u * 240u * 2u + 16u)  /* header, pixels, LED trailer (see docs/engine_protocol.md) */
#define BLOCK 256u
#define RING_MAGIC 0x464D3152u
#define FB_MAGIC 0x464D3146u

typedef struct {
    uint32_t magic, capacity, rate, pad0;
    volatile uint64_t w, r;
    volatile int64_t mix_minus_r;               /* the mixer frame at which ring index r plays, minus r */
    volatile uint32_t mix_valid;
    uint8_t pad1[20];
} ring_hdr;

/* MIDI scheduled at mixer frames (op 0x06), delivered when the engine renders that frame */
#define QMAX 4096u
static struct timed { uint64_t frame; uint8_t st, d1, d2; } q[QMAX];
static uint32_t qn;
static ring_hdr *ring;

static struct {
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
} c;

static int port_out = -1;
static const char *flash_path;

static void die(const char *what)
{
    fprintf(stderr, "fm1engine: %s: %s\n", what, errno ? strerror(errno) : "failed");
    exit(2);
}

static void *sym(void *h, const char *name)
{
    void *p = dlsym(h, name);
    if (!p) { fprintf(stderr, "fm1engine: cartridge lacks %s\n", name); exit(2); }
    return p;
}

static void put32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static void send_msg(const uint8_t *m, uint32_t n)  /* {packet, 2}: a 2-byte big-endian length, then the bytes */
{
    uint8_t hdr[2] = {(uint8_t)(n >> 8), (uint8_t)n};
    if (write(port_out, hdr, 2) != 2 || write(port_out, m, n) != (ssize_t)n) exit(0);   /* (the BEAM is gone) */
}

static void *map_file(const char *path, size_t n)
{
    /* a new file each time, never O_TRUNC: a mixer still mapping the previous engine's ring keeps its (old) pages,
     * where truncating the same inode would SIGBUS it */
    int fd;
    void *p;
    unlink(path);
    fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) die(path);
    if (ftruncate(fd, (off_t)n)) die(path);
    p = mmap(0, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) die(path);
    close(fd);
    return p;
}

static void flash_load(void)
{
    FILE *f = fopen(flash_path, "rb");
    uint32_t i;
    if (!f) return;
    for (i = 0; i < c.blob_count(); i++)
        if (fread(c.blob(i), 1, c.blob_size(), f) != c.blob_size()) break;
    fclose(f);
}

static uint32_t flash_save(void)                /* atomically: a temp file, then rename */
{
    char tmp[4096];
    FILE *f;
    uint32_t i, n = 0;
    snprintf(tmp, sizeof tmp, "%s.tmp", flash_path);
    if (!(f = fopen(tmp, "wb"))) { perror(tmp); return 0; }
    for (i = 0; i < c.blob_count(); i++) n += (uint32_t)fwrite(c.blob(i), 1, c.blob_size(), f);
    if (fclose(f) || rename(tmp, flash_path)) { perror(flash_path); return 0; }
    return n;
}

static void handle(const uint8_t *m, uint32_t n)
{
    if (n < 1) return;
    switch (m[0]) {
    case 0x01: if (n >= 3) c.key(m[1], m[2]); break;
    case 0x02: if (n >= 3) c.button(m[1], m[2]); break;
    case 0x03: if (n >= 3) c.enc(m[1], (int8_t)m[2]); break;
    case 0x04: if (n >= 4) c.midi(m[1], m[2], m[3]); break;
    case 0x06:
        if (n >= 12) {
            uint64_t f = 0;
            uint32_t i;
            for (i = 0; i < 8; i++) f = f << 8 | m[1 + i];
            if (qn < QMAX) q[qn++] = (struct timed){f, m[9], m[10], m[11]};
            else c.midi(m[9], m[10], m[11]);  /* (queue full: now rather than never) */
        }
        break;
    case 0x05: if (n >= 3) c.master((uint32_t)m[1] << 8 | m[2]); break;
    case 0x10: c.debug(1); break;
    case 0x11: c.debug(2); break;
    default: fprintf(stderr, "fm1engine: unknown op 0x%02x\n", m[0]);
    }
}

static uint8_t inbuf[65536 + 2];
static uint32_t in_n;

static void read_port(void)                     /* whatever has arrived, without blocking; EOF = the BEAM closed us */
{
    ssize_t got = read(0, inbuf + in_n, sizeof inbuf - in_n);
    if (got == 0) {
        flash_save();
        exit(0);
    }
    if (got < 0) { if (errno == EAGAIN || errno == EINTR) return; die("read"); }
    in_n += (uint32_t)got;
    for (;;) {
        uint32_t len;
        if (in_n < 2) return;
        len = (uint32_t)inbuf[0] << 8 | inbuf[1];
        if (in_n < 2 + len) return;
        handle(inbuf + 2, len);
        memmove(inbuf, inbuf + 2 + len, in_n - 2 - len);
        in_n -= 2 + len;
    }
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* BLOCK frames at ring index w into blk, delivering each queued MIDI message at its frame: the block is
 * rendered in pieces split at the events' frames. The firmware hears MIDI at its next pass (1 ms) and makes
 * sound in its own 256-frame ISR blocks, so a note starts at the next block boundary after it arrives: up to
 * 5.8 ms late. Delivering half a block early (MIDI_LEAD) moves that to the nearest boundary, +-2.9 ms. */
#define MIDI_LEAD 128
static void render_timed(int16_t *blk, uint64_t w)
{
    int valid = (int)__atomic_load_n(&ring->mix_valid, __ATOMIC_ACQUIRE);
    int64_t off = ring->mix_minus_r + MIDI_LEAD;
    uint32_t done = 0;
    for (;;) {
        uint32_t i, best = qn;
        int64_t best_e = 0;
        for (i = 0; i < qn; i++) {
            int64_t e = valid ? (int64_t)q[i].frame - off : (int64_t)w;
            if (e < (int64_t)(w + BLOCK) && (best == qn || e < best_e)) { best = i; best_e = e; }
        }
        if (best == qn) break;
        if (best_e > (int64_t)(w + done)) {     /* render up to the event's frame */
            uint32_t n = (uint32_t)(best_e - (int64_t)w) - done;
            c.render(blk + 2u * done, n);
            done += n;
        }
        c.midi(q[best].st, q[best].d1, q[best].d2);
        memmove(q + best, q + best + 1, (qn - best - 1) * sizeof q[0]);
        qn--;
    }
    if (done < BLOCK) c.render(blk + 2u * done, BLOCK - done);
}

int main(int argc, char **argv)
{
    char path[4096];
    void *h;
    int16_t *ring_data;
    uint8_t *fbm;
    uint32_t last_fb = 0, fb_seq = 0, last_store, target_fill = TARGET_FILL;
    double last_fb_t = 0, last_status_t = 0;

    if (argc != 4 && argc != 5) {
        fprintf(stderr, "usage: fm1engine <cart.so> <shm_prefix> <flash_file> [target_fill_frames]\n");
        return 2;
    }
    if (argc == 5) {
        target_fill = (uint32_t)strtoul(argv[4], NULL, 10);
        if (target_fill < 2u * BLOCK) target_fill = 2u * BLOCK;
        if (target_fill > RING_FRAMES - BLOCK) target_fill = RING_FRAMES - BLOCK;
    }
    flash_path = argv[3];
    port_out = dup(1);                          /* the port: keep it, and send the firmware's stdout to stderr */
    dup2(2, 1);
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);

    if (!(h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL))) { fprintf(stderr, "fm1engine: %s\n", dlerror()); return 2; }
    c.init = sym(h, "fm1c_init"); c.rate = sym(h, "fm1c_rate"); c.render = sym(h, "fm1c_render");
    c.ms = sym(h, "fm1c_ms"); c.master = sym(h, "fm1c_master"); c.key = sym(h, "fm1c_key");
    c.button = sym(h, "fm1c_button"); c.enc = sym(h, "fm1c_enc"); c.midi = sym(h, "fm1c_midi");
    c.fb = sym(h, "fm1c_fb"); c.fb_hash = sym(h, "fm1c_fb_hash"); c.leds_buttons = sym(h, "fm1c_leds_buttons");
    c.leds_keys = sym(h, "fm1c_leds_keys"); c.glow_keys = sym(h, "fm1c_glow_keys");
    c.blob_count = sym(h, "fm1c_blob_count"); c.blob_size = sym(h, "fm1c_blob_size"); c.blob = sym(h, "fm1c_blob");
    c.store_hash = sym(h, "fm1c_store_hash"); c.debug = sym(h, "fm1c_debug");

    snprintf(path, sizeof path, "%s.ring", argv[2]);
    ring = map_file(path, sizeof(ring_hdr) + RING_FRAMES * 4u);
    ring_data = (int16_t *)(ring + 1);
    snprintf(path, sizeof path, "%s.fb", argv[2]);
    fbm = map_file(path, FB_BYTES);
    ring->capacity = RING_FRAMES;
    ring->rate = c.rate();
    ring->w = ring->r = 0;
    __atomic_store_n(&ring->magic, RING_MAGIC, __ATOMIC_RELEASE);
    memcpy(fbm, &(uint32_t){FB_MAGIC}, 4);

    flash_load();
    if (c.init()) { fprintf(stderr, "fm1engine: the firmware did not boot\n"); return 2; }
    last_store = c.store_hash();
    {
        uint8_t m[5] = {0x81};
        put32(m + 1, c.ms());
        send_msg(m, 5);
    }

    for (;;) {
        struct pollfd pfd = {0, POLLIN, 0};
        uint64_t w = ring->w, r = __atomic_load_n(&ring->r, __ATOMIC_ACQUIRE);
        uint32_t fill = (uint32_t)(w - r);
        double t;

        if (fill + BLOCK <= target_fill) {      /* render a block straight into the ring */
            int16_t blk[BLOCK * 2u];
            uint32_t i, pos = (uint32_t)(w % RING_FRAMES);
            render_timed(blk, w);
            for (i = 0; i < BLOCK; i++) {
                ring_data[2u * ((pos + i) % RING_FRAMES)] = blk[2u * i];
                ring_data[2u * ((pos + i) % RING_FRAMES) + 1u] = blk[2u * i + 1u];
            }
            __atomic_store_n(&ring->w, w + BLOCK, __ATOMIC_RELEASE);
            poll(&pfd, 1, 0);
        } else
            poll(&pfd, 1, 1);                   /* the ring is full enough: wait a millisecond (or for input) */
        if (pfd.revents & (POLLIN | POLLHUP)) read_port();

        t = now_s();
        if (t - last_fb_t >= 1.0 / 60.0) {      /* the screen when it changed, and the LEDs (read by the UI) */
            uint32_t hh = c.fb_hash(), *trailer = (uint32_t *)(fbm + 8 + 240u * 240u * 2u);
            last_fb_t = t;
            if (hh != last_fb) {
                last_fb = hh;
                memcpy(fbm + 8, c.fb(), 240u * 240u * 2u);
                __atomic_store_n((uint32_t *)(fbm + 4), ++fb_seq, __ATOMIC_RELEASE);
            }
            trailer[0] = c.leds_buttons();
            trailer[1] = c.leds_keys();
            trailer[2] = c.glow_keys();
            __atomic_store_n(&trailer[3], c.ms(), __ATOMIC_RELEASE);
        }
        if (t - last_status_t >= 0.1) {         /* STATUS on the wall clock (the firmware's clock stops when nobody
                                                   drains the ring), and the flash when the firmware saved */
            uint8_t m[25] = {0x82};
            uint32_t sh = c.store_hash();
            last_status_t = t;
            put32(m + 1, c.ms()); put32(m + 5, fill); put32(m + 9, fb_seq);
            put32(m + 13, c.leds_buttons()); put32(m + 17, c.leds_keys()); put32(m + 21, c.glow_keys());
            send_msg(m, 25);
            if (sh != last_store) {
                uint8_t f[5] = {0x84};
                last_store = sh;
                put32(f + 1, flash_save());
                send_msg(f, 5);
            }
        }
    }
}
