//! The emulator engine: an FM-1 firmware package (`.fwsc`, the update package a real FM-1 installs) in fm1-emu,
//! driven by Erlang Port messages ({packet, 2}) exactly as native/engine/fm1engine.c drives a cartridge. Same
//! messages, `<prefix>.ring`, `<prefix>.fb` (RGB565 240 x 240 and the LED trailer) and pacing as the native
//! engine (docs/engine_protocol.md): it emulates while fewer than the target fill frames are queued, so the
//! mixer's audio clock drives the firmware's. The flash file holds the sectors the firmware changed (records of a
//! 4-byte little-endian offset and the 4096-byte sector); it is written when a save of the firmware's has
//! settled, and when the port closes. Beyond the native engine: op 0x08 sets the emulated CPU's clock, and STATUS
//! carries that clock, the DMA halves the firmware left stale and the engine's CPU time.
//!
//! `run` is the engine; its host is either an OS process of its own (main.rs: stdin, stdout) or a thread of the
//! iOS app (ffi.rs, c_src/fm1host.c: a pipe in, a callback out).

use crate::edges::{self, Edges};
use crate::machine::{self, Machine};
use crate::sys;
use std::ffi::{c_int, c_void};
use std::sync::atomic::{AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering};

const RING_FRAMES: u32 = 4096;
/// Default frames queued ahead of the mixer (~23 ms); the app passes more when the device takes bigger bursts.
pub const TARGET_FILL: u32 = 1024;
const BLOCK: u32 = 256;
const RATE: u32 = 44_100;
const RING_MAGIC: u32 = 0x464D_3152;
const FB_MAGIC: u32 = 0x464D_3146;
const PIXELS: usize = 240 * 240;
/// Header, pixels, LED trailer.
const FB_BYTES: usize = 8 + PIXELS * 2 + 16;
const RING_BYTES: usize = std::mem::size_of::<RingHdr>() + RING_FRAMES as usize * 4;
/// Instructions per emulator slice (fm1-live's).
const SLICE: u32 = 20_000;
/// Emulated frames with no audio from the firmware (booting, or not playing at all) before silence stands in
/// for it: longer than any DMA half, so a playing firmware's own audio always comes first.
const SILENCE_AFTER: u64 = 4096;
/// Timed MIDI goes in this many frames early: the firmware renders 256-frame halves, so a note lands on the
/// nearest half boundary rather than the next (as the native engine's MIDI_LEAD).
const MIDI_LEAD: i64 = 128;
const QMAX: usize = 4096;

/// Exit codes (as native/engine/fm1engine.h's): closed or the host is gone, a bad package or setup, the firmware
/// halted, a panic (in-process), killed, the debug crash (in-process).
pub const EXIT_OK: i32 = 0;
pub const EXIT_ERROR: i32 = 2;
pub const EXIT_HALTED: i32 = 3;
pub const EXIT_PANIC: i32 = 134;
pub const EXIT_KILLED: i32 = 137;
pub const EXIT_CRASHED: i32 = 139;

/// How an engine talks to its host: `struct fm1engine_io` of native/engine/fm1engine.h, field for field.
#[repr(C)]
pub struct Io {
    pub ctx: *mut c_void,
    /// Port messages in ({packet, 2}); EOF = closed: save the flash, end.
    pub in_fd: c_int,
    /// One message out; nonzero = nobody listens.
    pub send: unsafe extern "C" fn(ctx: *mut c_void, msg: *const u8, n: u32) -> c_int,
    /// The host gave up on this engine: end at once, save nothing. Null in a process (killed from outside).
    pub abandoned: *const AtomicI32,
}

impl Io {
    fn abandoned(&self) -> bool {
        // SAFETY: the host keeps the flag alive while the engine runs (fm1host.c frees it after the thread ends).
        !self.abandoned.is_null() && unsafe { (*self.abandoned).load(Ordering::Acquire) } != 0
    }

    fn in_process(&self) -> bool {
        !self.abandoned.is_null()
    }
}

/// What to run: the package, the shm prefix, the flash file, the target fill, the CPU clock, the JIT.
pub struct Config {
    pub package: String,
    pub prefix: String,
    pub flash: String,
    pub fill: u32,
    pub mhz: u32,
    pub jit: bool,
}

/// `<prefix>.ring`'s header.
#[repr(C)]
struct RingHdr {
    magic: AtomicU32,
    capacity: u32,
    rate: u32,
    _pad0: u32,
    w: AtomicU64,
    r: AtomicU64,
    /// The mixer frame at which ring index r plays, minus r.
    mix_minus_r: AtomicI64,
    mix_valid: AtomicU32,
    _pad1: [u8; 20],
}

struct Timed {
    frame: u64,
    msg: [u8; 3],
}

struct Engine<'a> {
    m: Machine,
    io: &'a Io,
    /// The host doesn't listen any more: end (as a process whose port's reader is gone).
    gone: bool,
    flash_path: String,
    ring: &'a RingHdr,
    ring_data: &'a mut [i16],
    /// MIDI scheduled at mixer frames (op 0x06), delivered when the emulator reaches that ring index.
    q: Vec<Timed>,
    /// The panel's key and button edges, each input's spaced in emulated time (edges.rs).
    edges: Edges,
    /// The firmware's audio not yet in the ring (interleaved stereo).
    pend: Vec<i16>,
    hang: bool,
    /// Flash: the revision last seen, when it last changed, the revision last saved.
    flash_rev: u32,
    flash_changed_at: f64,
    flash_saved_rev: u32,
    /// Frames kept queued ahead of the mixer (argument, op 0x07).
    target_fill: u32,
}

pub fn clamp_fill(f: u32) -> u32 {
    f.clamp(2 * BLOCK, RING_FRAMES - BLOCK)
}

fn put32(b: &mut [u8], v: u32) {
    b.copy_from_slice(&v.to_be_bytes());
}

impl Engine<'_> {
    fn send(&mut self, m: &[u8]) {
        // SAFETY: the host's callback, given a valid slice for its length.
        if !self.gone && unsafe { (self.io.send)(self.io.ctx, m.as_ptr(), m.len() as u32) } != 0 {
            self.gone = true; // (nobody listens: stop, as when the BEAM is gone)
        }
    }

    fn save_flash(&mut self) -> u32 {
        let records = self.m.flash_records();
        let tmp = format!("{}.tmp", self.flash_path);
        match std::fs::write(&tmp, &records).and_then(|_| std::fs::rename(&tmp, &self.flash_path)) {
            Ok(()) => {
                self.flash_saved_rev = self.m.flash_revision();
                records.len() as u32
            }
            Err(e) => {
                eprintln!("fm1emu: {}: {e}", self.flash_path);
                0
            }
        }
    }

    /// One port message. Some(code): the engine ends (the debug crash in-process).
    fn handle(&mut self, m: &[u8]) -> Option<i32> {
        match (m.first(), m.len()) {
            (Some(0x01), 3..) => self.panel(machine::key_id(m[1]), m[2] != 0),
            (Some(0x02), 3..) => self.panel(machine::button_id(m[1]), m[2] != 0),
            (Some(0x03), 3..) => self.m.enc(m[1], m[2] as i8),
            (Some(0x04), 4..) => self.m.midi(m[1], m[2], m[3]),
            (Some(0x05), 3..) => self.m.master(u16::from_be_bytes([m[1], m[2]])),
            (Some(0x07), 3..) => self.target_fill = clamp_fill(u16::from_be_bytes([m[1], m[2]]) as u32),
            (Some(0x08), 3..) => {
                self.m.set_mhz(u16::from_be_bytes([m[1], m[2]]) as u32);
            }
            (Some(0x06), 12..) => {
                let frame = u64::from_be_bytes(m[1..9].try_into().unwrap());
                if self.q.len() < QMAX {
                    self.q.push(Timed { frame, msg: [m[9], m[10], m[11]] });
                } else {
                    self.m.midi(m[9], m[10], m[11]); // (queue full: now rather than never)
                }
            }
            // (debug: a process dies of SIGSEGV; on a thread of the app the engine ends as if it had)
            (Some(0x10), _) if self.io.in_process() => return Some(EXIT_CRASHED),
            (Some(0x10), _) => sys::crash(),
            (Some(0x11), _) => self.hang = true,
            (Some(op), _) => eprintln!("fm1emu: unknown op 0x{op:02x}"),
            (None, _) => {}
        }
        None
    }

    fn panel(&mut self, id: Option<u8>, down: bool) {
        if let Some(id) = id {
            if self.edges.push(id, down, self.m.cycles()) {
                self.m.press(id, down);
            }
        }
    }

    /// Timed MIDI due by ring index `at` (where the emulator's output has got to), in time order.
    fn deliver_midi(&mut self, at: u64) {
        if self.q.is_empty() {
            return;
        }
        let valid = self.ring.mix_valid.load(Ordering::Acquire) != 0;
        let off = self.ring.mix_minus_r.load(Ordering::Relaxed) + MIDI_LEAD;
        loop {
            let due = self
                .q
                .iter()
                .enumerate()
                .map(|(i, t)| (i, if valid { t.frame as i64 - off } else { at as i64 }))
                .filter(|&(_, e)| e <= at as i64)
                .min_by_key(|&(_, e)| e);
            let Some((i, _)) = due else { break };
            let t = self.q.remove(i);
            self.m.midi(t.msg[0], t.msg[1], t.msg[2]);
        }
    }

    /// The next BLOCK frames for ring index `w` (= frames put in the ring since boot): the firmware's audio,
    /// emulating as far as it takes; silence where it plays none. Err(code): the engine ends.
    fn render(&mut self, w: u64, out: &mut [i16]) -> Result<(), i32> {
        let need = 2 * BLOCK as usize;
        loop {
            let pending = (self.pend.len() / 2) as u64;
            self.deliver_midi(w + pending);
            if self.pend.len() >= need {
                break;
            }
            if self.m.dac_frames() >= w + pending + BLOCK as u64 + SILENCE_AFTER {
                self.pend.resize(need, 0);
                break;
            }
            if self.hang {
                // (debug: as if the firmware's loop never came back; a host on a thread can still let it go)
                while !self.io.abandoned() {
                    std::hint::spin_loop();
                }
                return Err(EXIT_KILLED);
            }
            let Engine { m, edges, .. } = self;
            edges.due(m.cycles(), |id, down| m.press(id, down));
            if let Err(e) = self.m.run(SLICE) {
                eprintln!("fm1emu: the firmware halted: {e}");
                let _ = self.save_flash();
                return Err(EXIT_HALTED);
            }
            self.pend.append(&mut self.m.soc.periph.audio);
        }
        out.copy_from_slice(&self.pend[..need]);
        self.pend.drain(..need);
        Ok(())
    }
}

/// Run one package until its port closes; returns an exit code above.
pub fn run(cfg: &Config, io: &Io) -> i32 {
    let pkg = match std::fs::read(&cfg.package) {
        Ok(p) => p,
        Err(e) => return die(&format!("{}: {e}", cfg.package)),
    };
    let mut m = match Machine::boot(&pkg, cfg.jit, cfg.mhz) {
        Ok(m) => m,
        Err(e) => return die(&format!("{}: {e}", cfg.package)),
    };
    drop(pkg);
    m.master(1024); // (unity until told otherwise, as the native engine; fm1-emu's pot starts at 900)
    if let Ok(records) = std::fs::read(&cfg.flash) {
        if let Err(e) = m.restore_flash(&records) {
            eprintln!("fm1emu: {}: {e}; starting from the package's flash", cfg.flash);
        }
    }

    let ring_p = match sys::map_new_file(&format!("{}.ring", cfg.prefix), RING_BYTES) {
        Ok(p) => p,
        Err(e) => return die(&format!("ring: {e}")),
    };
    let fb = match sys::map_new_file(&format!("{}.fb", cfg.prefix), FB_BYTES) {
        Ok(p) => p,
        Err(e) => {
            sys::unmap(ring_p, RING_BYTES);
            return die(&format!("fb: {e}"));
        }
    };
    let code = run_mapped(cfg, io, m, ring_p, fb);
    sys::unmap(ring_p, RING_BYTES);
    sys::unmap(fb, FB_BYTES);
    code
}

fn run_mapped(cfg: &Config, io: &Io, m: Machine, ring_p: *mut u8, fb: *mut u8) -> i32 {
    // SAFETY: both mappings live until `run` unmaps them after this returns; the header is 64 bytes, as the C
    // struct, and the samples follow it, 4-byte aligned; nothing else in this engine aliases them.
    let (ring, ring_data) = unsafe {
        let hdr = &mut *(ring_p as *mut RingHdr);
        hdr.capacity = RING_FRAMES;
        hdr.rate = RATE;
        hdr.w.store(0, Ordering::Relaxed);
        hdr.r.store(0, Ordering::Relaxed);
        hdr.magic.store(RING_MAGIC, Ordering::Release);
        let data = std::slice::from_raw_parts_mut(ring_p.add(std::mem::size_of::<RingHdr>()) as *mut i16, 2 * RING_FRAMES as usize);
        std::ptr::copy_nonoverlapping(FB_MAGIC.to_le_bytes().as_ptr(), fb, 4);
        (&*(ring_p as *const RingHdr), data)
    };

    let flash_rev = m.flash_revision();
    let edges = Edges::new(m.cycles_of_ms(edges::GAP_MS));
    let mut e = Engine {
        m,
        io,
        gone: false,
        flash_path: cfg.flash.clone(),
        ring,
        ring_data,
        q: Vec::new(),
        edges,
        pend: Vec::new(),
        hang: false,
        flash_rev,
        flash_changed_at: 0.0,
        flash_saved_rev: flash_rev,
        target_fill: clamp_fill(cfg.fill),
    };
    let mut ready = [0x81u8, 0, 0, 0, 0];
    put32(&mut ready[1..5], e.m.ms() as u32);
    e.send(&ready);

    let mut inbuf: Vec<u8> = Vec::with_capacity(65536 + 2);
    let mut chunk = [0u8; 4096];
    let mut blk = [0i16; 2 * BLOCK as usize];
    let (mut fb_seq, mut lcd_rev, mut leds) = (0u32, u32::MAX, (0u32, 0u32, 0u32));
    let (mut last_fb_t, mut last_status_t, mut leds_at_ms) = (0.0f64, 0.0f64, 0u64);
    // SAFETY: the pixel area of the mapping (offset 8, 2-byte aligned) and the trailer after it.
    let pixels = unsafe { std::slice::from_raw_parts_mut(fb.add(8) as *mut u16, PIXELS) };
    let trailer = unsafe { std::slice::from_raw_parts(fb.add(8 + PIXELS * 2) as *const AtomicU32, 4) };
    let seq = unsafe { &*(fb.add(4) as *const AtomicU32) };
    // the engine's CPU time: the process's when it is one, its thread's on a thread of the app
    let cpu_s = if io.in_process() { sys::thread_cpu_s } else { sys::cpu_s };

    loop {
        if io.abandoned() {
            return EXIT_KILLED;
        }
        if e.gone {
            return EXIT_OK;
        }
        let w = e.ring.w.load(Ordering::Relaxed);
        let r = e.ring.r.load(Ordering::Acquire);
        let fill = w.wrapping_sub(r) as u32;
        let revents = if fill + BLOCK <= e.target_fill {
            // a block straight into the ring
            if let Err(code) = e.render(w, &mut blk) {
                return code;
            }
            let pos = (w % RING_FRAMES as u64) as usize;
            for i in 0..BLOCK as usize {
                let at = 2 * ((pos + i) % RING_FRAMES as usize);
                e.ring_data[at] = blk[2 * i];
                e.ring_data[at + 1] = blk[2 * i + 1];
            }
            e.ring.w.store(w + BLOCK as u64, Ordering::Release);
            sys::poll_in(io.in_fd, 0)
        } else {
            sys::poll_in(io.in_fd, 1) // the ring is full enough: wait a millisecond (or for input)
        };
        if revents & (sys::POLLIN | sys::POLLHUP) != 0 {
            match sys::read_fd(io.in_fd, &mut chunk) {
                Ok(0) => {
                    // EOF: the host closed the port
                    e.save_flash();
                    return EXIT_OK;
                }
                Ok(n) => {
                    inbuf.extend_from_slice(&chunk[..n]);
                    while inbuf.len() >= 2 {
                        let len = u16::from_be_bytes([inbuf[0], inbuf[1]]) as usize;
                        if inbuf.len() < 2 + len {
                            break;
                        }
                        let msg: Vec<u8> = inbuf[2..2 + len].to_vec();
                        inbuf.drain(..2 + len);
                        if let Some(code) = e.handle(&msg) {
                            return code;
                        }
                    }
                }
                Err(err) if matches!(err.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted) => {}
                Err(err) => return die(&format!("read: {err}")),
            }
        }

        let t = sys::now_s();
        if t - last_fb_t >= 1.0 / 60.0 {
            // the screen when it changed, and the LEDs (read by the UI)
            last_fb_t = t;
            if e.m.lcd_revision() != lcd_rev {
                lcd_rev = e.m.lcd_revision();
                pixels.copy_from_slice(e.m.lcd());
                fb_seq = fb_seq.wrapping_add(1);
                seq.store(fb_seq, Ordering::Release);
            }
            // (LED fractions over at least 5 ms of firmware time: none passes while the ring is full)
            let ms = e.m.ms();
            if ms >= leds_at_ms + 5 {
                leds_at_ms = ms;
                leds = e.m.leds();
            }
            trailer[0].store(leds.0, Ordering::Relaxed);
            trailer[1].store(leds.1, Ordering::Relaxed);
            trailer[2].store(leds.2, Ordering::Relaxed);
            trailer[3].store(ms as u32, Ordering::Release);
        }
        if t - last_status_t >= 0.1 {
            // STATUS on the wall clock (the firmware's clock stops when nobody drains the ring), and the flash
            // once a save of the firmware's has settled
            last_status_t = t;
            let mut s = [0u8; 35];
            s[0] = 0x82;
            put32(&mut s[1..5], e.m.ms() as u32);
            put32(&mut s[5..9], fill);
            put32(&mut s[9..13], fb_seq);
            put32(&mut s[13..17], leds.0);
            put32(&mut s[17..21], leds.1);
            put32(&mut s[21..25], leds.2);
            s[25..27].copy_from_slice(&(e.m.mhz() as u16).to_be_bytes());
            put32(&mut s[27..31], e.m.stale_halves());
            put32(&mut s[31..35], (cpu_s() * 1000.0) as u32);
            e.send(&s);
            let rev = e.m.flash_revision();
            if rev != e.flash_rev {
                e.flash_rev = rev;
                e.flash_changed_at = t;
            } else if rev != e.flash_saved_rev && t - e.flash_changed_at >= 0.25 && !e.m.flash_busy() {
                let mut f = [0x84u8, 0, 0, 0, 0];
                put32(&mut f[1..5], e.save_flash());
                e.send(&f);
            }
        }
    }
}

fn die(what: &str) -> i32 {
    eprintln!("fm1emu: {what}");
    EXIT_ERROR
}

/// `--bench <package> [seconds] [key ...]`: flat out, no port, no ring. Returns the report's lines.
pub fn bench(path: &str, secs: f64, keys: &[u8], jit: bool, mhz: u32) -> Result<Vec<String>, String> {
    let keys: Vec<u8> = if keys.is_empty() { vec![7, 11, 14] } else { keys.to_vec() };
    let pkg = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    // (the thread's CPU time: in the app other threads run beside it; in a process it is the same)
    let (t0, c0) = (sys::now_s(), sys::thread_cpu_s());
    let mut m = Machine::boot(&pkg, jit, mhz).map_err(|e| format!("{path}: {e}"))?;
    m.master(1024);
    let (mut held, mut frames, mut peak_before, mut peak_held) = (false, 0u64, 0i32, 0i32);
    let mut first_audio: Option<(u64, f64)> = None;
    let end_ms = (secs * 1000.0) as u64;
    let (mut t_held, mut c_held, mut ms_held) = (0.0, 0.0, 0u64);
    while m.ms() < end_ms {
        if !held && m.ms() >= 1000 {
            held = true;
            (t_held, c_held, ms_held) = (sys::now_s(), sys::thread_cpu_s(), m.ms());
            for &k in &keys {
                if let Some(id) = machine::key_id(k) {
                    m.press(id, true);
                }
            }
        }
        m.run(SLICE).map_err(|e| format!("the firmware halted at {} ms: {e}", m.ms()))?;
        let peak = m.soc.periph.audio.iter().map(|&s| (s as i32).abs()).max().unwrap_or(0);
        frames += (m.soc.periph.audio.len() / 2) as u64;
        if first_audio.is_none() && !m.soc.periph.audio.is_empty() {
            first_audio = Some((m.ms(), sys::thread_cpu_s() - c0));
        }
        m.soc.periph.audio.clear();
        if held { peak_held = peak_held.max(peak) } else { peak_before = peak_before.max(peak) }
    }
    let (t1, c1) = (sys::now_s(), sys::thread_cpu_s());
    let emu_s = m.ms() as f64 / 1000.0;
    let held_s = (m.ms() - ms_held) as f64 / 1000.0;
    let (fa_ms, fa_cpu) = first_audio.unwrap_or((0, 0.0));
    Ok(vec![
        format!(
            "{path}: {emu_s:.2} s emulated (jit {jit}, {} MHz) in {:.2} s wall, {:.2} s CPU (boot included): {:.2}x real time",
            m.mhz(),
            t1 - t0,
            c1 - c0,
            emu_s / (c1 - c0)
        ),
        format!(
            "keys {keys:?} held: {held_s:.2} s emulated in {:.2} s CPU: {:.2}x real time, {:.0}% of one core at real time",
            c1 - c_held,
            held_s / (c1 - c_held),
            100.0 * (c1 - c_held) / held_s
        ),
        format!(
            "audio: {frames} frames ({:.2} s), peak {peak_before} before the keys, {peak_held} with them, {} DMA halves stale; wall while held {:.2} s",
            frames as f64 / RATE as f64,
            m.stale_halves(),
            t1 - t_held
        ),
        format!(
            "CPU: {:.1} M instructions a second of emulated time; stalls {:.1} M ticks a second, {:.1} M forgiven",
            m.ran as f64 / emu_s / 1e6,
            m.paid as f64 / emu_s / 1e6,
            m.forgiven as f64 / emu_s / 1e6
        ),
        format!("boot: the first audio at {fa_ms} ms of firmware time, {fa_cpu:.2} s CPU in; the first second in {:.2} s CPU", c_held - c0),
    ])
}
