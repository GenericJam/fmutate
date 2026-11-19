//! fm1emu: the emulator engine (engine.rs) as an OS process of its own, driven over an Erlang Port
//! ({packet, 2}) exactly as native/engine/fm1engine.c drives a cartridge:
//!
//!   fm1emu <package.fwsc> <shm_prefix> <flash_file> [target_fill_frames]
//!
//!   fm1emu --bench <package.fwsc> [seconds] [key ...]
//!
//! runs the package flat out for `seconds` of emulated time (10), holding the keys (C major: 7 11 14) from
//! the second second on, and reports how much faster than real time it ran and its loudest sample.

use fm1emu::engine::{self, Config, Io, TARGET_FILL};
use fm1emu::sys;
use std::ffi::{c_int, c_void};

/// Development knobs, as fm1-live's: FM1_NO_JIT=1 interprets; FM1_MHZ=N starts the CPU at N MHz instead of the
/// FM-1's 240 (as op 0x08 sets it: cheaper to emulate for firmwares that spend cycles waiting).
fn jit_on() -> bool {
    std::env::var_os("FM1_NO_JIT").is_none()
}

fn start_mhz() -> u32 {
    std::env::var("FM1_MHZ").ok().and_then(|v| v.parse::<u32>().ok()).unwrap_or(240)
}

/// {packet, 2} to the port: a 2-byte big-endian length, then the bytes. Nonzero when the BEAM is gone.
unsafe extern "C" fn send_port(ctx: *mut c_void, msg: *const u8, n: u32) -> c_int {
    // SAFETY: ctx is main's port descriptor, msg valid for n bytes (engine.rs).
    let (fd, m) = unsafe { (*(ctx as *const c_int), std::slice::from_raw_parts(msg, n as usize)) };
    let mut b = Vec::with_capacity(2 + m.len());
    b.extend_from_slice(&(m.len() as u16).to_be_bytes());
    b.extend_from_slice(m);
    c_int::from(!sys::write_all(fd, &b))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--bench") {
        let Some(path) = args.get(2) else {
            eprintln!("fm1emu: --bench needs a package");
            std::process::exit(2);
        };
        let secs: f64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(10.0);
        let keys: Vec<u8> = args.iter().skip(4).filter_map(|s| s.parse().ok()).collect();
        match engine::bench(path, secs, &keys, jit_on(), start_mhz()) {
            Ok(lines) => lines.iter().for_each(|l| println!("{l}")),
            Err(e) => {
                eprintln!("fm1emu: {e}");
                std::process::exit(2);
            }
        }
        return;
    }
    if args.len() != 4 && args.len() != 5 {
        eprintln!("usage: fm1emu <package.fwsc> <shm_prefix> <flash_file> [target_fill_frames]\n       fm1emu --bench <package.fwsc> [seconds] [key ...]");
        std::process::exit(2);
    }
    let cfg = Config {
        package: args[1].clone(),
        prefix: args[2].clone(),
        flash: args[3].clone(),
        fill: args.get(4).map_or(TARGET_FILL, |s| s.parse::<u32>().unwrap_or(TARGET_FILL)),
        mhz: start_mhz(),
        jit: jit_on(),
    };
    let mut port = sys::take_port();
    let io = Io { ctx: (&mut port as *mut c_int).cast(), in_fd: 0, send: send_port, abandoned: std::ptr::null() };
    std::process::exit(engine::run(&cfg, &io));
}
