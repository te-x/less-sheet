//! sysio.zig (backend-linux-portability) — portable blocking file I/O + thread
//! synchronization, replacing the macOS-only `std.c` libc bindings so the core
//! cross-compiles to aarch64/x86_64-linux-musl while staying byte-identical on
//! macOS.
//!
//! Zig 0.16.0 moved the file syscalls behind `std.Io.File` (each takes an `Io`)
//! and REMOVED `std.Thread.Mutex`/`Condition`/`sleep` in favor of
//! `std.Io.Mutex`/`Condition`/`Io.sleep` (also `Io`-parameterized). The old
//! `std.c.{fstat,close,pread,pwrite,ftruncate,unlink,getpid,pthread_*}` bindings
//! resolve on Darwin but are `void` on linux-musl (Zig binds Linux libc thinly,
//! assuming raw syscalls) — that is the cross-build's first error.
//!
//! We back every ported op with `std.Io.Threaded.global_single_threaded`: a
//! process-global, statically-initialized `Io` with NO allocator, NO signal
//! handlers, and NO worker-thread pool. Its blocking file ops (stat/close/
//! read/write/setLength/deleteFile) run inline on the calling thread — positional
//! reads/writes carry no shared offset, so they are thread-safe across the core's
//! lanes — and its `Mutex`/`Condition` are futex-backed, so they genuinely block
//! and wake across the REAL OS threads the core spawns (`builtin.single_threaded`
//! is false here). The primitives are cross-platform (Linux/macOS/Windows-ready),
//! matching the ARCH's "portable std, not POSIX-only" intent for groups A/B.
//!
//! The two genuinely platform-specific primitives — `posix.mmap`/`munmap` and
//! `posix.madvise` — deliberately stay in `std.posix` behind the Source seam
//! (ARCH group C); they compile and work on macOS + Linux and are the named
//! Windows plug-in point. This module never touches them.

const std = @import("std");

pub const File = std.Io.File;
pub const Mutex = std.Io.Mutex;
pub const Condition = std.Io.Condition;

/// The shared blocking `Io`. Free to obtain (a pointer to a static instance),
/// so call sites fetch it per-op rather than threading it through signatures.
pub inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Wrap a raw POSIX fd (from `std.posix.openatZ`) as a blocking `File`. The fds
/// the core opens never set O_NONBLOCK, so `nonblocking` is always false.
pub inline fn file(fd: std.posix.fd_t) File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Close a raw fd through the blocking `Io` (replaces `c.close`).
pub inline fn close(fd: std.posix.fd_t) void {
    file(fd).close(io());
}

/// Delete an absolute path through the blocking `Io` (replaces `c.unlink` for
/// the create-then-unlink anonymous-temp idiom). Callers pass a `/tmp/...` path.
pub inline fn unlinkAbsolute(path: []const u8) std.Io.Dir.DeleteFileError!void {
    return std.Io.Dir.deleteFileAbsolute(io(), path);
}

/// Blocking millisecond sleep (replaces the `c.timespec`/`c.nanosleep` back-off).
pub inline fn sleepMs(ms: u64) void {
    io().sleep(std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// A process-unique token for temp-file names, replacing `c.getpid()` (absent
/// from `std.posix` in 0.16.0). Folds a monotonic per-process counter with the
/// caller thread's id so concurrent creators — even at the same object address
/// across processes — get distinct names; the O_CREAT|O_EXCL open is the final
/// backstop against any residual collision.
var name_counter: std.atomic.Value(u64) = .init(0);
pub fn uniqueToken() u64 {
    const n = name_counter.fetchAdd(1, .monotonic);
    const tid: u64 = @intCast(std.Thread.getCurrentId());
    return (tid << 20) ^ (n *% 0x9E3779B97F4A7C15);
}
