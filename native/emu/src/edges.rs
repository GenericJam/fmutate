//! The panel's keys and buttons, spaced so the firmware's own matrix scan sees every edge. Input comes in batches
//! (a port read), so a press and its release can arrive together, between two emulator slices: applied at once,
//! the matrix would never show the press to the firmware. Each input's edges are applied in order, each one once
//! the input's previous edge has been on the matrix for GAP_MS of emulated time; an edge with none pending before
//! it, on an input that has been steady that long, is applied at once. Inputs are independent: OCT- and OCT+
//! tapped together close in the same scan (OberVave's and Shine On's "both: octave 0").
//!
//! 16 ms, as the native engine's (native/engine/live.c, EDGE_GAP_MS): fm1-emu's matrix shows a key from its press
//! to its release as is (fm1-soc periph.rs), and the firmwares debounce it themselves. Their hal/fm1_input.h
//! (Felucca's) counts a press after FM1_DEB_PRESS (2) frames of its 11-column scan (~1.1 ms each) closed and a
//! release after FM1_DEB_RELEASE (8) frames open: up to ~10 ms with the scan's phase, so a shorter release is never
//! seen and a quick second tap merges with the first. 16 ms covers that with a margin (and the 8 ms a released
//! key's pill takes to lift, for firmwares that read its force), and is shorter than any human double tap.

/// fm1-emu's matrix ids: buttons 0..13, keys 14..40 (crate::machine).
pub const INPUTS: usize = 41;
pub const GAP_MS: u64 = 16;
/// Edges an input holds back (16 taps, ~0.5 s); one more cancels the last one queued, so the state still ends
/// where the port left it.
const QMAX: u8 = 32;

#[derive(Clone, Copy, Default)]
struct Input {
    /// On the matrix now.
    on: bool,
    /// Flips queued after it.
    n: u8,
    /// The emulated cycle from which the next flip may go on the matrix.
    next: u64,
}

pub struct Edges {
    inputs: [Input; INPUTS],
    /// Bit i: inputs[i] has flips queued.
    pending: u64,
    /// GAP_MS in emulated cycles.
    gap: u64,
}

impl Edges {
    pub fn new(gap_cycles: u64) -> Self {
        Edges { inputs: [Input::default(); INPUTS], pending: 0, gap: gap_cycles }
    }

    /// An edge from the port at emulated cycle `now`: true = put it on the matrix now; else it is queued (or it
    /// changed nothing).
    pub fn push(&mut self, id: u8, down: bool, now: u64) -> bool {
        let i = id as usize;
        let s = &mut self.inputs[i];
        if down == (s.on ^ (s.n & 1 == 1)) {
            return false; // (the state it is already going to)
        }
        if s.n == 0 && now >= s.next {
            s.on = down;
            s.next = now + self.gap;
            return true;
        }
        if s.n < QMAX {
            s.n += 1;
            self.pending |= 1 << i;
        } else {
            s.n -= 1;
        }
        false
    }

    /// The queued edges due at emulated cycle `now`, each input's next one: `apply(id, down)`.
    pub fn due(&mut self, now: u64, mut apply: impl FnMut(u8, bool)) {
        let mut p = self.pending;
        while p != 0 {
            let i = p.trailing_zeros() as usize;
            p &= p - 1;
            let s = &mut self.inputs[i];
            if now < s.next {
                continue;
            }
            s.on = !s.on;
            s.next = now + self.gap;
            s.n -= 1;
            if s.n == 0 {
                self.pending &= !(1 << i);
            }
            apply(i as u8, s.on);
        }
    }
}
