//! The two libc calls `std` does not expose.
//!
//! Hand-written FFI instead of the `libc` crate: the crate has zero dependencies, so there is
//! nothing to fetch, vendor, or re-hash when nixpkgs moves. Everything here is a thin wrapper
//! over a stable Linux syscall ABI.
//!
//! Body movement deliberately does **not** use `splice(2)`. A request cannot be forwarded before
//! its model id is known, and the id lives inside the body, so the payload has to land in userspace
//! anyway; a kernel-level zero-copy path would only add a failure mode with no payoff.

use std::io;
use std::os::raw::c_int;

extern "C" {
    fn flock(fd: c_int, op: c_int) -> c_int;
}

// <sys/file.h> on Linux.
const LOCK_EX: c_int = 2;
const LOCK_UN: c_int = 8;
const EINTR: i32 = 4;

/// Take `LOCK_EX` on an open descriptor, blocking until it is ours.
///
/// This is the exact same lock `flock(1)` (the wake scripts), `fcntl.flock` (`dash.py`) and the
/// old `switcher.sh` take, so all orchestrators serialize on one inode per domain.
pub fn flock_ex(fd: c_int) -> io::Result<()> {
    // Retry on EINTR: a blocked flock is interrupted by signals (SIGCHLD from the subprocess
    // starts we spawn, SIGTERM on `nixos-rebuild switch`, ...).
    loop {
        if unsafe { flock(fd, LOCK_EX) } == 0 {
            return Ok(());
        }
        let err = io::Error::last_os_error();
        if err.raw_os_error() != Some(EINTR) {
            return Err(err);
        }
    }
}

/// Drop `LOCK_EX`; the kernel also drops it on close, so this is best effort.
pub fn funlock(fd: c_int) {
    unsafe {
        flock(fd, LOCK_UN);
    }
}
