//! fm1emu: an FM-1 firmware package (`.fwsc`, the update package a real FM-1 installs) in fm1-emu, its own OS
//! process, driven over an Erlang Port ({packet, 2}) exactly as native/engine/fm1engine.c drives a cartridge:
//!
//!   fm1emu <package.fwsc> <shm_prefix> <flash_file> [target_fill_frames]
//!
//! Same messages, `<prefix>.ring`, `<prefix>.fb` (RGB565 240 x 240 and the LED trailer) and pacing as the
//! native engine (docs/engine_protocol.md): it emulates while fewer than the target fill frames are queued, so
//! the mixer's audio clock drives the firmware's. The flash file holds the sectors the firmware changed
//! (records of a 4-byte little-endian offset and the 4096-byte sector); it is written when a save of the
//! firmware's has settled, and when the port closes.
//!
//!   fm1emu --bench <package.fwsc> [seconds] [key ...]
//!
//! runs the package flat out for `seconds` of emulated time (10), holding the keys (C major: 7 11 14) from
//! the second second on, and reports how much faster than real time it ran and its loudest sample.

mod edges;
mod machine;
mod sys;

use edges::Edges;
use machine::Machine;
use std::ffi::c_int;
use std::sync::atomic::{AtomicI64, AtomicU32, AtomicU64, Ordering};

const RING_FRAMES: u32 = 4096;
/// Default frames queued ahead of the mixer (~23 ms); the app passes more when the device takes bigger bursts.
const TARGET_FILL: u32 = 1024;
const BLOCK: u32 = 256;
const RATE: u32 = 44_100;
const RING_MAGIC: u32 = 0x464D_3152;
const FB_MAGIC: u32 = 0x464D_3146;
const PIXELS: usize = 240 * 240;
/// Header, pixels, LED trailer.
const FB_BYTES: usize = 8 + PIXELS * 2 + 16;
/// Instructions per emulator slice (fm1-live's).
const SLICE: u32 = 20_000;
/// Emulated frames with no audio from the firmware (booting, or not playing at all) before silence stands in
/// for it: longer than any DMA half, so a playing firmware's own audio always comes first.
const SILENCE_AFTER: u64 = 4096;
/// Timed MIDI goes in this many frames early: the firmware renders 256-frame halves, so a note lands on the
/// nearest half boundary rather than the next (as the native engine's MIDI_LEAD).
const MIDI_LEAD: i64 = 128;
const QMAX: usize = 4096;

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

struct Engine {
    m: Machine,
    port: c_int,
    flash_path: String,
    ring: &'static RingHdr,
    ring_data: &'static mut [i16],
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
    /// Frames kept queued ahead of the mixer (argv, op 0x07).
    target_fill: u32,
}

fn clamp_fill(f: u32) -> u32 {
    f.clamp(2 * BLOCK, RING_FRAMES - BLOCK)
}

fn put32(b: &mut [u8], v: u32) {
    b.copy_from_slice(&v.to_be_bytes());
}

impl Engine {
    fn send(&self, m: &[u8]) {
        let mut b = Vec::with_capacity(2 + m.len());
        b.extend_from_slice(&(m.len() as u16).to_be_bytes());
        b.extend_from_slice(m);
        if !sys::write_all(self.port, &b) {
            std::process::exit(0); // (the BEAM is gone)
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

    fn handle(&mut self, m: &[u8]) {
        match (m.first(), m.len()) {
            (Some(0x01), 3..) => self.panel(machine::key_id(m[1]), m[2] != 0),
            (Some(0x02), 3..) => self.panel(machine::button_id(m[1]), m[2] != 0),
            (Some(0x03), 3..) => self.m.enc(m[1], m[2] as i8),
            (Some(0x04), 4..) => self.m.midi(m[1], m[2], m[3]),
            (Some(0x05), 3..) => self.m.master(u16::from_be_bytes([m[1], m[2]])),
            (Some(0x07), 3..) => self.target_fill = clamp_fill(u16::from_be_bytes([m[1], m[2]]) as u32),
            (Some(0x06), 12..) => {
                let frame = u64::from_be_bytes(m[1..9].try_into().unwrap());
                if self.q.len() < QMAX {
                    self.q.push(Timed { frame, msg: [m[9], m[10], m[11]] });
                } else {
                    self.m.midi(m[9], m[10], m[11]); // (queue full: now rather than never)
                }
            }
            (Some(0x10), _) => sys::crash(),
            (Some(0x11), _) => self.hang = true,
            (Some(op), _) => eprintln!("fm1emu: unknown op 0x{op:02x}"),
            (None, _) => {}
        }
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
    /// emulating as far as it takes; silence where it plays none.
    fn render(&mut self, w: u64, out: &mut [i16]) {
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
                loop {
                    std::hint::spin_loop(); // (debug: as if the firmware's loop never came back)
                }
            }
            let Engine { m, edges, .. } = self;
            edges.due(m.cycles(), |id, down| m.press(id, down));
            if let Err(e) = self.m.run(SLICE) {
                eprintln!("fm1emu: the firmware halted: {e}");
                let _ = self.save_flash();
                std::process::exit(3);
            }
            self.pend.append(&mut self.m.soc.periph.audio);
        }
        out.copy_from_slice(&self.pend[..need]);
        self.pend.drain(..need);
    }
}

fn die(what: &str) -> ! {
    eprintln!("fm1emu: {what}");
    std::process::exit(2);
}

/// Development knobs, as fm1-live's: FM1_NO_JIT=1 interprets; FM1_MHZ=N clocks the CPU at N MHz instead of the
/// FM-1's 240 (cheaper to emulate for firmwares that spend cycles waiting rather than idling).
fn jit_on() -> bool {
    std::env::var_os("FM1_NO_JIT").is_none()
}

fn clock_hz() -> u64 {
    let mhz = std::env::var("FM1_MHZ").ok().and_then(|v| v.parse::<u64>().ok()).filter(|&m| m > 0);
    mhz.map_or(fm1_soc::CPU_HZ, |m| m * 1_000_000)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--bench") {
        return bench(&args[2..]);
    }
    if args.len() != 4 && args.len() != 5 {
        eprintln!("usage: fm1emu <package.fwsc> <shm_prefix> <flash_file> [target_fill_frames]\n       fm1emu --bench <package.fwsc> [seconds] [key ...]");
        std::process::exit(2);
    }
    let target_fill = args.get(4).map_or(TARGET_FILL, |s| clamp_fill(s.parse::<u32>().unwrap_or(TARGET_FILL)));
    let port = sys::take_port();

    let pkg = std::fs::read(&args[1]).unwrap_or_else(|e| die(&format!("{}: {e}", args[1])));
    let mut m = Machine::boot(&pkg, jit_on(), clock_hz()).unwrap_or_else(|e| die(&format!("{}: {e}", args[1])));
    drop(pkg);
    m.master(1024); // (unity until told otherwise, as the native engine; fm1-emu's pot starts at 900)
    let flash_path = args[3].clone();
    if let Ok(records) = std::fs::read(&flash_path) {
        if let Err(e) = m.restore_flash(&records) {
            eprintln!("fm1emu: {flash_path}: {e}; starting from the package's flash");
        }
    }

    let ring_bytes = std::mem::size_of::<RingHdr>() + RING_FRAMES as usize * 4;
    let ring_p = sys::map_new_file(&format!("{}.ring", args[2]), ring_bytes).unwrap_or_else(|e| die(&format!("ring: {e}")));
    let fb = sys::map_new_file(&format!("{}.fb", args[2]), FB_BYTES).unwrap_or_else(|e| die(&format!("fb: {e}")));
    // SAFETY: both mappings live until the process exits; the header is 64 bytes, as the C struct, and the
    // samples follow it, 4-byte aligned; nothing else in this process aliases them.
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
        port,
        flash_path,
        ring,
        ring_data,
        q: Vec::new(),
        edges,
        pend: Vec::new(),
        hang: false,
        flash_rev,
        flash_changed_at: 0.0,
        flash_saved_rev: flash_rev,
        target_fill,
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

    loop {
        let w = e.ring.w.load(Ordering::Relaxed);
        let r = e.ring.r.load(Ordering::Acquire);
        let fill = w.wrapping_sub(r) as u32;
        let revents = if fill + BLOCK <= e.target_fill {
            // a block straight into the ring
            e.render(w, &mut blk);
            let pos = (w % RING_FRAMES as u64) as usize;
            for i in 0..BLOCK as usize {
                let at = 2 * ((pos + i) % RING_FRAMES as usize);
                e.ring_data[at] = blk[2 * i];
                e.ring_data[at + 1] = blk[2 * i + 1];
            }
            e.ring.w.store(w + BLOCK as u64, Ordering::Release);
            sys::poll_stdin(0)
        } else {
            sys::poll_stdin(1) // the ring is full enough: wait a millisecond (or for input)
        };
        if revents & (sys::POLLIN | sys::POLLHUP) != 0 {
            match sys::read_stdin(&mut chunk) {
                Ok(0) => {
                    // EOF: the BEAM closed the port
                    e.save_flash();
                    std::process::exit(0);
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
                        e.handle(&msg);
                    }
                }
                Err(err) if matches!(err.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted) => {}
                Err(err) => die(&format!("read: {err}")),
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
            let mut s = [0u8; 25];
            s[0] = 0x82;
            put32(&mut s[1..5], e.m.ms() as u32);
            put32(&mut s[5..9], fill);
            put32(&mut s[9..13], fb_seq);
            put32(&mut s[13..17], leds.0);
            put32(&mut s[17..21], leds.1);
            put32(&mut s[21..25], leds.2);
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

/// `--bench <package> [seconds] [key ...]`: flat out, no port, no ring.
fn bench(args: &[String]) {
    let Some(path) = args.first() else { die("--bench needs a package") };
    let secs: f64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(10.0);
    let mut keys: Vec<u8> = args.iter().skip(2).filter_map(|s| s.parse().ok()).collect();
    if keys.is_empty() {
        keys = vec![7, 11, 14];
    }
    let pkg = std::fs::read(path).unwrap_or_else(|e| die(&format!("{path}: {e}")));
    let (t0, c0) = (sys::now_s(), sys::cpu_s());
    let mut m = Machine::boot(&pkg, jit_on(), clock_hz()).unwrap_or_else(|e| die(&format!("{path}: {e}")));
    m.master(1024);
    let (mut held, mut frames, mut peak_before, mut peak_held) = (false, 0u64, 0i32, 0i32);
    let mut first_audio: Option<(u64, f64)> = None;
    let end_ms = (secs * 1000.0) as u64;
    let (mut t_held, mut c_held, mut ms_held) = (0.0, 0.0, 0u64);
    while m.ms() < end_ms {
        if !held && m.ms() >= 1000 {
            held = true;
            (t_held, c_held, ms_held) = (sys::now_s(), sys::cpu_s(), m.ms());
            for &k in &keys {
                if let Some(id) = machine::key_id(k) {
                    m.press(id, true);
                }
            }
        }
        if let Err(e) = m.run(SLICE) {
            die(&format!("the firmware halted at {} ms: {e}", m.ms()));
        }
        let peak = m.soc.periph.audio.iter().map(|&s| (s as i32).abs()).max().unwrap_or(0);
        frames += (m.soc.periph.audio.len() / 2) as u64;
        if first_audio.is_none() && !m.soc.periph.audio.is_empty() {
            first_audio = Some((m.ms(), sys::cpu_s() - c0));
        }
        m.soc.periph.audio.clear();
        if held { peak_held = peak_held.max(peak) } else { peak_before = peak_before.max(peak) }
    }
    let (t1, c1) = (sys::now_s(), sys::cpu_s());
    let emu_s = m.ms() as f64 / 1000.0;
    let held_s = (m.ms() - ms_held) as f64 / 1000.0;
    println!(
        "{path}: {emu_s:.2} s emulated (jit {}, {} MHz) in {:.2} s wall, {:.2} s CPU (boot included): {:.2}x real time",
        jit_on(),
        clock_hz() / 1_000_000,
        t1 - t0,
        c1 - c0,
        emu_s / (c1 - c0)
    );
    println!(
        "keys {keys:?} held: {held_s:.2} s emulated in {:.2} s CPU: {:.2}x real time, {:.0}% of one core at real time",
        c1 - c_held,
        held_s / (c1 - c_held),
        100.0 * (c1 - c_held) / held_s
    );
    println!(
        "audio: {frames} frames ({:.2} s), peak {peak_before} before the keys, {peak_held} with them; wall while held {:.2} s",
        frames as f64 / RATE as f64,
        t1 - t_held
    );
    let (fa_ms, fa_cpu) = first_audio.unwrap_or((0, 0.0));
    println!(
        "boot: the first audio at {fa_ms} ms of firmware time, {fa_cpu:.2} s CPU in; the first second in {:.2} s CPU",
        c_held - c0
    );
}
