//! The emulated FM-1 running a package: booted as fm1-live boots one (`fm1-live --fwsc`), stepped as it
//! steps it, the engine wire's panel numbers translated to fm1-emu's matrix ids, and its flash saved as the
//! sectors the firmware changed.

use fm1_core::{Bus, Cpu};
use fm1_soc::{machine, Action, Board, Soc, FLASH_SIZE};

const RAM_BASE: u32 = 0x01c0_0000;
const RAM_SIZE: usize = 1 << 20;
const SECTOR: usize = 4096;
/// A flash file record: a 4-byte little-endian offset, then the 4096-byte sector (as fm1-emu's web saves
/// keep them).
const RECORD: usize = 4 + SECTOR;
/// fm1-emu's matrix ids: buttons 0..13 (the engine wire's order), note keys 14..40 (F3..G5).
const KEY_BASE: u8 = 14;

/// Key 0 = F3 .. 26 = G5 (the engine wire's numbers, docs/engine_protocol.md): its matrix id.
pub fn key_id(k: u8) -> Option<u8> {
    (k < 27).then_some(KEY_BASE + k)
}

/// 0 OCT- 1 OCT+ 2 FX 3 SEL 4 ENV 5 LFO 6 EDIT 7 GLO 8 HOME 9 SAVE 10 ARP 11 SEQ 12 PLAY 13 REC: fm1-emu's button
/// ids are the same.
pub fn button_id(b: u8) -> Option<u8> {
    (b < KEY_BASE).then_some(b)
}

/// The MASTER pot's ADC channel.
const MASTER_ADC: u8 = 4;
/// LED on-fractions: the matrix lights a column at a time, so a fully lit LED is on about 1/11 of the time
/// (fm1-live's panel draws f / 0.08 as its brightness). At least half of that is lit; less than half and
/// more than a sixteenth is the firmware's dim (PWM) layer, the glow.
const LED_FULL: f32 = 0.08;
/// The slowest CPU clock `set_mhz` takes.
pub const MIN_MHZ: u32 = 20;
/// Fewest instructions between stalls on a clock below the FM-1's (`run`; ~8.5 us at 240 MHz): each run of
/// the cores costs a little (core 1 starts by probing a block at a time), so fewer runs, measured: OberVave's
/// package at 120 MHz on the host 3.7x real time at 256, 5.1x at 2048, as fast as a 120 MHz `Periph::hz`.
const STALL_CHUNK: u32 = 2048;
/// Stall ticks owed at most (10 ms at 240 MHz); beyond that (events too dense to fit them in) they are forgiven.
const STALL_MAX: u64 = fm1_soc::CPU_HZ / 100;
/// A DMA half that moves less than this (max - min of its samples) is quiet: a firmware may write the same
/// silence every time, so a quiet half that repeats is no sign of starving.
const QUIET_SPAN: i32 = 512;

pub struct Machine {
    cpu: Cpu,
    cpu1: Option<Cpu>,
    pub soc: Soc,
    pending_tick: bool,
    /// The flash as the package installs it, to find the sectors the firmware has written since.
    flash0: Vec<u8>,
    /// The emulated CPU clock (`set_mhz`), and the stall ticks owed for it, in 1/hz of a tick.
    hz: u64,
    owed: u64,
    /// The last two DMA halves the firmware played (the buffer's two halves), and how many halves the DMA
    /// played that the firmware hadn't written since they last played (`stale`).
    halves: [Vec<i16>; 2],
    half_n: u64,
    stale: u32,
    /// Ticks of instructions run, of stalls paid and forgiven, so far (--bench reports them).
    pub ran: u64,
    pub paid: u64,
    pub forgiven: u64,
}

impl Machine {
    /// Boot an FM-1 package (`.fwsc`). `jit`: compile the firmware to native code where fm1-core can; `mhz`: the
    /// CPU clock (`set_mhz`; the FM-1's is 240 MHz).
    pub fn boot(pkg: &[u8], jit: bool, mhz: u32) -> Result<Self, String> {
        let st = std::panic::catch_unwind(|| fm1_soc::stock_from_package(pkg, None))
            .map_err(|_| "malformed firmware package".to_owned())??;
        if st.board != Board::Fm1 {
            return Err(format!("not an FM-1 package ({})", st.identity));
        }
        let mut soc = Soc::new(RAM_SIZE, st.xip);
        soc.periph.skip_idle = true;
        let mut cpu = Cpu::new(st.entry);
        cpu.jit_on = jit;
        // the SPL hands cpu0 over in user mode, with its boot-parameter struct in r0
        cpu.user = true;
        let params = RAM_BASE + 0x7fc00;
        soc.write32(params, params + 0x40);
        cpu.regs[0] = fm1_soc::stock_boot(&mut soc, &st.flash, params, st.board);
        soc.sfc_boot(st.key, st.app_end);
        let flash0 = soc.flash.mem.clone();
        let mut m = Machine {
            cpu,
            cpu1: None,
            soc,
            pending_tick: false,
            flash0,
            hz: fm1_soc::CPU_HZ,
            owed: 0,
            halves: [Vec::new(), Vec::new()],
            half_n: 0,
            stale: 0,
            ran: 0,
            paid: 0,
            forgiven: 0,
        };
        m.set_mhz(mhz);
        Ok(m)
    }

    /// The emulated CPU's clock, MIN_MHZ..240 MHz, from now on. The SoC's clock (`Periph::hz`: its timers, the
    /// DAC, the firmware's milliseconds) stays the FM-1's 240 MHz: below it the CPU stalls, (240 - mhz) / mhz
    /// ticks for each instruction it runs (both cores), so the firmware gets mhz million instructions a second
    /// of emulated time and emulated time never jumps. Returns the clock set.
    pub fn set_mhz(&mut self, mhz: u32) -> u32 {
        let mhz = mhz.clamp(MIN_MHZ, (fm1_soc::CPU_HZ / 1_000_000) as u32);
        self.hz = mhz as u64 * 1_000_000;
        self.owed = 0;
        mhz
    }

    pub fn mhz(&self) -> u32 {
        (self.hz / 1_000_000) as u32
    }

    /// DMA halves played that the firmware hadn't rewritten since they last played (not counting quiet ones):
    /// it fell a whole half behind its own audio, the sign of a CPU clock too slow for it.
    pub fn stale_halves(&self) -> u32 {
        self.stale
    }

    /// Run `n` instructions of cpu0, and of cpu1 beside it once the firmware has released it. Err: the
    /// firmware halted (it would have locked up or reset a real FM-1).
    ///
    /// Below 240 MHz the CPU stalls (`set_mhz`): ticks that pass with both cores stopped, as `skip_idle`'s jumps
    /// pass, and as those never past the SoC's next timed event (a tick due, an interrupt). So the cores run as
    /// many instructions as fit with their stalls before the next event (STALL_CHUNK at least), then the
    /// stalls are paid up to it; what doesn't fit is owed after the CPU has had its turn at the event. Time the
    /// CPU jumped over idling (`skip_idle`, a polling loop skipped) is time, not instructions: it owes nothing.
    pub fn run(&mut self, n: u32) -> Result<(), String> {
        let slow = self.hz < fm1_soc::CPU_HZ;
        let mut left = n;
        while left > 0 {
            // (below 240 MHz: what is owed paid, then as many instructions as fit before the next event with
            // their stalls, a few at least)
            let k = if slow {
                let room = self.stall();
                ((room * self.hz / fm1_soc::CPU_HZ).min(left as u64) as u32).max(STALL_CHUNK.min(left))
            } else {
                left
            };
            let (c0, idle0) = (self.soc.periph.cycles, self.idle_ticks());
            let (audio0, halves0) = (self.soc.periph.audio.len(), self.soc.periph.audio_halves);
            let jit = self.cpu.jit_on;
            let Machine { cpu, cpu1, soc, pending_tick, .. } = self;
            machine::run_dual(cpu1, soc, k, RAM_SIZE, jit, |soc, k| machine::run_blocks(cpu, soc, k, pending_tick))?;
            self.check_halves(audio0, halves0);
            // (a chip reset starts the polling-loop counts again)
            let ran = (self.soc.periph.cycles - c0).saturating_sub(self.idle_ticks().saturating_sub(idle0));
            self.ran += ran;
            if slow {
                let owed = self.owed + ran * (fm1_soc::CPU_HZ - self.hz);
                self.owed = owed.min(STALL_MAX * self.hz);
                self.forgiven += (owed - self.owed) / self.hz;
            }
            left -= k;
        }
        Ok(())
    }

    /// Ticks jumped over idling so far (TIMER4 polling, polling loops).
    fn idle_ticks(&self) -> u64 {
        self.soc.periph.skipped + self.soc.loop_skip.skipped
    }

    /// Pay the stall ticks owed, as far as the next timed event; returns the ticks left before it.
    fn stall(&mut self) -> u64 {
        if self.pending_tick {
            return 0; // (a tick is due: the CPU's turn)
        }
        let p = &mut self.soc.periph;
        let cap = std::mem::replace(&mut p.room_cap, u64::MAX);
        let mut room = p.tick_room();
        if room == 0 {
            // (the next event's time may be unknown just now: have it worked out)
            self.soc.advance(0);
            room = self.soc.periph.tick_room();
        }
        self.soc.periph.room_cap = cap;
        let pay = (self.owed / self.hz).min(room);
        if pay > 0 {
            self.soc.advance(pay);
            self.owed -= pay * self.hz;
            self.paid += pay;
        }
        room - pay
    }

    /// The halves the DMA played in the last run (fm1-soc appends each half's samples as it finishes):
    /// compared with the same half of the buffer the time before.
    fn check_halves(&mut self, audio0: usize, halves0: u64) {
        let n = (self.soc.periph.audio_halves - halves0) as usize;
        let fresh = self.soc.periph.audio.len() - audio0;
        if n == 0 || fresh == 0 || fresh % n != 0 {
            return;
        }
        let len = fresh / n;
        for h in self.soc.periph.audio[audio0..].chunks_exact(len) {
            let last = &mut self.halves[(self.half_n & 1) as usize];
            self.half_n += 1;
            if last.as_slice() == h {
                let (lo, hi) = h.iter().fold((i32::MAX, i32::MIN), |(lo, hi), &s| (lo.min(s as i32), hi.max(s as i32)));
                if hi - lo >= QUIET_SPAN {
                    self.stale += 1;
                }
            } else {
                last.clear();
                last.extend_from_slice(h);
            }
        }
    }

    /// Emulated milliseconds since boot.
    pub fn ms(&self) -> u64 {
        self.soc.periph.ms()
    }

    /// Emulated CPU cycles since boot (the emulated clock).
    pub fn cycles(&self) -> u64 {
        self.soc.periph.cycles
    }

    /// `ms` of emulated time in CPU cycles.
    pub fn cycles_of_ms(&self, ms: u64) -> u64 {
        self.soc.periph.cycle_of_ms(ms)
    }

    /// Frames the DAC has clocked since boot (44117.6 Hz of emulated time, whether the firmware plays or not).
    pub fn dac_frames(&self) -> u64 {
        self.soc.periph.audio_frames_so_far()
    }

    // ---- the panel

    /// A key or button (its matrix id: key_id, button_id) closed or open, from now.
    pub fn press(&mut self, id: u8, down: bool) {
        self.soc.periph.apply(&Action::Key { id, down });
    }

    /// 0 SELECT 1 ALGORITHM 2-5 KNOB1-4 6 PRESETS (fm1-emu's encoder numbers are the same); + = clockwise.
    pub fn enc(&mut self, e: u8, clicks: i8) {
        if e < 7 {
            self.soc.periph.apply(&Action::Enc { enc: e, clicks: clicks as i32 });
        }
    }

    /// MASTER 0..1024: the pot, 0..1023 on its ADC; the firmware applies its own curve.
    pub fn master(&mut self, v: u16) {
        let value = (u32::from(v.min(1024)) * 1023 / 1024) as u16;
        self.soc.periph.apply(&Action::Adc { ch: MASTER_ADC, value });
    }

    /// One MIDI message into the MIDI IN jack, its bytes as the message has them (a program change is two).
    pub fn midi(&mut self, st: u8, d1: u8, d2: u8) {
        let len = match st {
            0x80..=0xBF | 0xE0..=0xEF | 0xF2 => 3,
            0xC0..=0xDF | 0xF1 | 0xF3 => 2,
            0xF6 | 0xF8..=0xFD | 0xFF => 1,
            _ => return, // (data bytes, SysEx framing, active sensing: as the native engine)
        };
        for &b in &[st, d1 & 0x7F, d2 & 0x7F][..len] {
            self.soc.periph.apply(&Action::Midi { b });
        }
    }

    // ---- what the panel shows

    pub fn lcd(&self) -> &[u16] {
        &self.soc.lcd.fb
    }

    pub fn lcd_revision(&self) -> u32 {
        self.soc.lcd.revision
    }

    /// The LEDs since the last call, as the wire's bit masks: (buttons, keys, key glow).
    pub fn leds(&mut self) -> (u32, u32, u32) {
        let f = self.soc.periph.led_take();
        let (mut buttons, mut keys, mut glow) = (0u32, 0u32, 0u32);
        for (i, &v) in f.iter().enumerate() {
            let b = (v / LED_FULL).clamp(0.0, 1.0);
            let (lit, dim) = (b >= 0.5, b > 1.0 / 16.0 && b < 0.5);
            if i < KEY_BASE as usize {
                if lit { buttons |= 1 << i; }
            } else {
                let k = i - KEY_BASE as usize;
                if lit { keys |= 1 << k; }
                if dim { glow |= 1 << k; }
            }
        }
        (buttons, keys, glow)
    }

    // ---- flash

    pub fn flash_revision(&self) -> u32 {
        self.soc.flash.revision
    }

    /// Mid-way through an erase or a program (the firmware's save isn't finished).
    pub fn flash_busy(&self) -> bool {
        self.soc.flash.busy()
    }

    /// The sectors the firmware changed, as flash file records.
    pub fn flash_records(&self) -> Vec<u8> {
        let (now, then) = (&self.soc.flash.mem, &self.flash0);
        let mut out = Vec::new();
        for at in (0..now.len().min(then.len())).step_by(SECTOR) {
            let end = (at + SECTOR).min(now.len());
            if now[at..end] != then[at..end] {
                out.extend_from_slice(&(at as u32).to_le_bytes());
                out.extend_from_slice(&now[at..end]);
                out.resize(out.len() + SECTOR - (end - at), 0xFF);
            }
        }
        out
    }

    /// Lay saved records over the package's flash (through to the XIP window, as the firmware's own writes
    /// go). Err: not a flash file of this format; nothing is changed then.
    pub fn restore_flash(&mut self, records: &[u8]) -> Result<(), String> {
        if records.len() % RECORD != 0 {
            return Err(format!("{} bytes is not a whole number of sector records", records.len()));
        }
        let mut image = self.flash0.clone();
        for r in records.chunks_exact(RECORD) {
            let at = u32::from_le_bytes([r[0], r[1], r[2], r[3]]) as usize;
            if at % SECTOR != 0 || at + SECTOR > FLASH_SIZE {
                return Err(format!("sector offset {at:#x} is out of the flash"));
            }
            image[at..at + SECTOR].copy_from_slice(&r[4..]);
        }
        self.soc.restore_flash(&image);
        Ok(())
    }
}
