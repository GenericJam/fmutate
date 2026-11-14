//! The emulator engine as a C library, for an app that runs engines on threads of its own (iOS: c_src/fm1host.c,
//! linked from native/build_ios.sh's archive). Mirrors native/engine/fm1engine.h's fm1engine_run.

use crate::engine::{self, Config, Io, EXIT_ERROR, EXIT_PANIC};
use std::ffi::{c_char, c_int, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};

fn string(p: *const c_char) -> Option<String> {
    // SAFETY: the caller passes NUL-terminated strings (or null).
    (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

/// Run one package until its port closes (`io`, fm1engine.h's struct fm1engine_io): `prefix`.ring and
/// `prefix`.fb, the flash file, the target ring fill (0: the default), the emulated CPU's clock in MHz (0: 240).
/// Interpreted (iOS has no JIT for apps). Returns the engine's exit code; a panic is 134 and leaves the app
/// running.
///
/// # Safety
/// The strings are NUL-terminated; `io` and what it points to stay valid until this returns.
#[no_mangle]
pub unsafe extern "C" fn fm1emu_run(
    package: *const c_char,
    prefix: *const c_char,
    flash: *const c_char,
    fill: u32,
    mhz: u32,
    io: *const Io,
) -> c_int {
    let (Some(package), Some(prefix), Some(flash)) = (string(package), string(prefix), string(flash)) else {
        return EXIT_ERROR;
    };
    if io.is_null() {
        return EXIT_ERROR;
    }
    let cfg = Config {
        package,
        prefix,
        flash,
        fill: if fill == 0 { engine::TARGET_FILL } else { fill },
        mhz: if mhz == 0 { 240 } else { mhz },
        jit: false,
    };
    // SAFETY: the caller keeps `io` valid until this returns.
    let io = unsafe { &*io };
    catch_unwind(AssertUnwindSafe(|| engine::run(&cfg, io))).unwrap_or(EXIT_PANIC)
}

/// `fm1emu --bench`, in the app: `package` flat out for `secs` of emulated time with a C major chord held from the
/// second second, at `mhz` (0: 240), interpreted. Writes the report (lines, NUL-terminated, cut to fit) into
/// `out`; returns 0, or 2 with the error in `out`.
///
/// # Safety
/// `package` is NUL-terminated; `out` is writable for `out_n` bytes.
#[no_mangle]
pub unsafe extern "C" fn fm1emu_bench(package: *const c_char, secs: f64, mhz: u32, out: *mut c_char, out_n: usize) -> c_int {
    let Some(path) = string(package) else { return EXIT_ERROR };
    let res = catch_unwind(|| engine::bench(&path, secs, &[], false, if mhz == 0 { 240 } else { mhz }))
        .unwrap_or_else(|_| Err("panicked".to_owned()));
    let (code, text) = match res {
        Ok(lines) => (0, lines.join("\n")),
        Err(e) => (EXIT_ERROR, e),
    };
    if !out.is_null() && out_n > 0 {
        let n = text.len().min(out_n - 1);
        // SAFETY: out is writable for out_n bytes, n < out_n.
        unsafe {
            std::ptr::copy_nonoverlapping(text.as_ptr(), out.cast(), n);
            *out.add(n) = 0;
        }
    }
    code
}
