//! The few POSIX calls the engine needs beyond std (Linux and Android, 64- and 32-bit; macOS and iOS): the
//! port's file descriptors, poll, the shared mappings, the debug crash and the CPU clock. Declared here so the
//! crate has no dependencies besides fm1-emu's own.

use std::ffi::{c_int, c_long, c_void};
use std::fs::OpenOptions;
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::AsRawFd;

pub const POLLIN: i16 = 0x1;
pub const POLLHUP: i16 = 0x10;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const PROT_READ_WRITE: c_int = 0x1 | 0x2;
const MAP_SHARED: c_int = 0x1;
const SIGSEGV: c_int = 11;
const SIG_DFL: usize = 0;
#[cfg(not(target_vendor = "apple"))]
const O_NONBLOCK: c_int = 0o4000;
#[cfg(not(target_vendor = "apple"))]
const CLOCK_MONOTONIC: c_int = 1;
#[cfg(not(target_vendor = "apple"))]
const CLOCK_PROCESS_CPUTIME_ID: c_int = 2;
#[cfg(target_vendor = "apple")]
const O_NONBLOCK: c_int = 0x4;
#[cfg(target_vendor = "apple")]
const CLOCK_MONOTONIC: c_int = 6;
#[cfg(target_vendor = "apple")]
const CLOCK_PROCESS_CPUTIME_ID: c_int = 12;

#[repr(C)]
pub struct PollFd {
    pub fd: c_int,
    pub events: i16,
    pub revents: i16,
}

#[repr(C)]
struct Timespec {
    tv_sec: c_long,
    tv_nsec: c_long,
}

extern "C" {
    fn dup(fd: c_int) -> c_int;
    fn dup2(fd: c_int, to: c_int) -> c_int;
    fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    fn poll(fds: *mut PollFd, n: u32, timeout_ms: c_int) -> c_int;
    fn read(fd: c_int, buf: *mut c_void, n: usize) -> isize;
    fn write(fd: c_int, buf: *const c_void, n: usize) -> isize;
    fn mmap(addr: *mut c_void, len: usize, prot: c_int, flags: c_int, fd: c_int, off: c_long) -> *mut c_void;
    fn signal(sig: c_int, handler: usize) -> usize;
    fn raise(sig: c_int) -> c_int;
    fn clock_gettime(clock: c_int, ts: *mut Timespec) -> c_int;
}

/// The port: keep stdout for it (returned), send everything printed to stdout to stderr, and make stdin
/// non-blocking.
pub fn take_port() -> c_int {
    // SAFETY: plain descriptor calls on the process's own stdio.
    unsafe {
        let out = dup(1);
        dup2(2, 1);
        fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
        out
    }
}

/// Wait up to `timeout_ms` for stdin; returns its revents.
pub fn poll_stdin(timeout_ms: i32) -> i16 {
    let mut p = PollFd { fd: 0, events: POLLIN, revents: 0 };
    // SAFETY: one valid pollfd.
    unsafe { poll(&mut p, 1, timeout_ms) };
    p.revents
}

/// Read what stdin has: Ok(0) = EOF, Err(WouldBlock) = nothing yet.
pub fn read_stdin(buf: &mut [u8]) -> io::Result<usize> {
    // SAFETY: the buffer is valid for its length.
    let n = unsafe { read(0, buf.as_mut_ptr().cast(), buf.len()) };
    if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n as usize) }
}

/// Write all of `b` to `fd`; false when the reader is gone.
pub fn write_all(fd: c_int, mut b: &[u8]) -> bool {
    while !b.is_empty() {
        // SAFETY: the slice is valid for its length.
        let n = unsafe { write(fd, b.as_ptr().cast(), b.len()) };
        if n <= 0 {
            if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return false;
        }
        b = &b[n as usize..];
    }
    true
}

/// A new shared file of `n` bytes, mapped read-write. Always a new file (unlinked first, never truncated in
/// place): a mixer still mapping the previous engine's file keeps its (old) pages instead of SIGBUS.
pub fn map_new_file(path: &str, n: usize) -> io::Result<*mut u8> {
    let _ = std::fs::remove_file(path);
    let f = OpenOptions::new().read(true).write(true).create_new(true).mode(0o600).open(path)?;
    f.set_len(n as u64)?;
    // SAFETY: a fresh shared mapping of a file we just sized; failure is checked.
    let p = unsafe { mmap(std::ptr::null_mut(), n, PROT_READ_WRITE, MAP_SHARED, f.as_raw_fd(), 0) };
    if p as isize == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(p.cast())
}

/// Die of SIGSEGV, as a firmware that dereferenced garbage would (std's stack-overflow handler is taken
/// off first: it would swallow a raised SIGSEGV).
pub fn crash() -> ! {
    // SAFETY: restoring the default action and raising a signal at ourselves.
    unsafe {
        signal(SIGSEGV, SIG_DFL);
        raise(SIGSEGV);
    }
    std::process::abort()
}

fn clock(id: c_int) -> f64 {
    let mut ts = Timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: a valid timespec.
    unsafe { clock_gettime(id, &mut ts) };
    ts.tv_sec as f64 + ts.tv_nsec as f64 * 1e-9
}

/// Seconds on the monotonic clock.
pub fn now_s() -> f64 {
    clock(CLOCK_MONOTONIC)
}

/// CPU seconds this process has used.
pub fn cpu_s() -> f64 {
    clock(CLOCK_PROCESS_CPUTIME_ID)
}
