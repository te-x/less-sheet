//! The SOURCE-FAULT GUARD: a scoped, chained `SIGBUS` handler over the core's
//! own mmap regions.
//!
//! WHY. We map local files (`root.openWithAllocator`) and then read them lazily,
//! so the bytes under a live mapping can stop existing: another process truncates
//! the file, a network mount drops, a USB drive is pulled. Reading a page that no
//! longer has backing store raises `SIGBUS`, which by default kills the process
//! — and this core is linked INTO the frontend, so that kills the app. We must
//! instead catch the fault inside our OWN regions, recover, and report a clean
//! truncated/faulted outcome.
//!
//! MEASURED PLATFORM SPLIT: truncating under a live read-only `MAP_PRIVATE`
//! mapping raises `SIGBUS` on Linux (all arms) but NOT on macOS 26/APFS, which
//! keeps serving the bytes the mapping opened with. A mapping LONGER than its
//! file faults on both. So on macOS this guard is inert insurance; on Linux —
//! which we ship to (aarch64/x86_64-linux-musl, the GTK frontend) — it is what
//! stands between a shrinking file and a dead app.
//!
//! ------------------------------------------------------------------ MECHANISM
//! RECOVERY IS PAGE REPAIR, NOT `siglongjmp`. Returning from a SIGBUS handler
//! re-executes the faulting instruction, which faults again — forever. So the
//! handler must change something first. It replaces the faulted range with an
//! anonymous zero mapping via `mmap(MAP_FIXED|MAP_ANONYMOUS)`, then returns: the
//! faulting load re-executes, reads zeroes, and the interrupted code continues
//! NORMALLY. Chosen over `sigsetjmp`/`siglongjmp` for two reasons:
//!
//!   1. COST. The guard sits on the local read path — the one path that was never
//!      allowed to regress. `siglongjmp` needs a `sigsetjmp` on the way IN, at
//!      every site that touches the mapping; page repair needs NOTHING on the
//!      way in. The only no-fault cost here is one acquire atomic load per scan
//!      chunk / per `ls_window_set` (see `faultCount`) — not per byte, not per
//!      row, not per read.
//!   2. SAFETY. `longjmp` out of a signal handler abandons every `defer` between
//!      the jump target and the fault, so it would escape the document mutex a
//!      scan holds and wedge the next `ls_close`. Page repair unwinds nothing:
//!      locks release, `defer`s run, the scan finishes normally and is DISCARDED
//!      by its caller.
//!
//! Zero-filling is emphatically NOT the report. It only buys a clean return; the
//! zeroes must never be believed. Every caller brackets the work that touches a
//! mapping with `faultCount` and throws the whole result away if the count moved
//! (`base.goTerminalOnSourceFaultLocked`); a repair that silently succeeded would
//! be the silent-wrong-data failure.
//!
//! The repair covers `[faulting page, region end)`, not just the one page: a
//! truncation removes a SUFFIX, so the whole tail is gone, and repairing it in
//! one call keeps this O(1) in mmap calls per region instead of O(pages) — which
//! also matters because each `MAP_FIXED` split would otherwise cost a VMA and a
//! big file could walk into Linux's `max_map_count`.
//!
//! ------------------------------------------------------- ASYNC-SIGNAL SAFETY
//! A handler may not allocate and may not take a lock, yet it has to decide, AT
//! FAULT TIME, whether the faulting address is inside one of our regions — and
//! that set changes as documents open and close, concurrently with faults. So the
//! registry is a FIXED, statically allocated table (no allocation, ever) and each
//! slot is a SEQLOCK: writers bump `seq` to odd, mutate, bump to even; the handler
//! reads `seq`, reads the region, re-reads `seq`, and SKIPS the slot unless both
//! reads are equal and even.
//!
//! That is not merely "mostly consistent", it is exact for the case that matters.
//! A slot is only ever mutated while it holds NO live region, so the slot
//! describing the region we are faulting in is never in flight: it always reads
//! cleanly. Skipping an in-flight slot can therefore only ever skip somebody
//! else's region — it can never make us miss our own fault (a false negative,
//! which would crash) and it can never make us adopt a fault that is not ours (a
//! false positive, which would swallow the host's crash). Writers serialize with
//! each other on a mutex the handler never touches.
//!
//! ------------------------------------------------------------------- CHAINING
//! We are NEVER the first handler: `std.start` installs one for SIGBUS in every
//! ReleaseSafe Zig binary (`default_enable_segfault_handler = runtime_safety`),
//! and the host app (Swift / GTK) may install its own crash reporter. So install
//! captures the previous `Sigaction` and `chain` hands a fault we do not own
//! straight to it — SA_SIGINFO handler, plain handler, `SIG_IGN`, or `SIG_DFL`
//! (restore + return, so the instruction re-executes and the process dies
//! properly, with the right signal and a core dump). Zig's own crash reporting
//! keeps working for every fault outside our regions.
//!
//! ONE-SIGNAL POLICY. `install` calls `sigaction` for `.BUS` and for nothing
//! else. SEGV/ILL/FPE stay with the host's crash reporting, and IO/PIPE stay with
//! the network executor, which owns them deliberately and permanently
//! (`std.Io.Threaded.init`; see src/net_source.zig's note on never deinitializing
//! it).
//!
//! Installation happens ONCE per process, on the first `arm`, and is never undone
//! — not on the last close either. Uninstalling would either hand SIGBUS back to
//! a handler that knows nothing about our regions while documents are still open,
//! or leave a later document unguarded with no way to re-arm; and a foreign
//! SIGBUS keeps reaching the previous handler regardless, because `chain` is what
//! answers it.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const sysio = @import("sysio.zig");

/// How many mmap regions can be guarded at once. One per open document (a local
/// file's mapping), so this is a per-process concurrent-document ceiling and 64
/// is far past any viewer's real use. Statically allocated: the handler must not
/// allocate, so the table cannot grow. If it is ever full, `arm` returns null and
/// that document runs UNGUARDED — i.e. exactly the pre-guard behaviour, never
/// something worse.
const slot_count = 64;

/// A guarded region. `seq` is the seqlock (even = stable, odd = mid-mutation);
/// `base`/`len` are only read between two equal, even `seq` reads. `faults` is a
/// monotonic counter rather than a flag so a caller can tell "a fault happened
/// under THIS operation" from "this document faulted at some point in the past" —
/// which is what lets a faulted document keep serving the rows that ARE still
/// backed instead of going dark completely.
const Slot = struct {
    seq: u32 = 0,
    faults: u32 = 0,
    base: usize = 0,
    len: usize = 0,
};

var slots: [slot_count]Slot = @splat(.{});

/// Serializes `arm`/`disarm` against each other. The handler NEVER takes this —
/// it is the seqlock that makes the handler safe, not this mutex.
var table_mutex: sysio.Mutex = .init;

var installed: bool = false;
var prev_action: posix.Sigaction = undefined;
/// Resolved once at install: `std.heap.pageSize()` may consult the OS on its
/// first call, which is not something to do from a signal handler.
var page_size: usize = 0;

inline fn faultAddr(info: *const posix.siginfo_t) usize {
    return switch (builtin.os.tag) {
        .macos => @intFromPtr(info.addr),
        .linux => @intFromPtr(info.fields.sigfault.addr),
        else => 0,
    };
}

/// Map anonymous zeroed PROT_READ pages over `[at, at + len)`. Deliberately the
/// raw libc call, not `posix.mmap`: the wrapper's error mapping reaches
/// `unreachable`, which is a PANIC under ReleaseSafe, and panicking inside a
/// signal handler is not a recovery. Here failure is just `false`.
fn mapZeroOver(at: usize, len: usize) bool {
    const r = std.c.mmap(
        @ptrFromInt(at),
        len,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
        -1,
        0,
    );
    return r != std.c.MAP_FAILED;
}

/// Page-rounded end of a region. `mmap` is given an unrounded length (the file
/// size), but the kernel maps whole pages, so a fault in the final partial page
/// is still ours and its repair must cover the whole page.
inline fn regionEnd(base: usize, len: usize) usize {
    return std.mem.alignForward(usize, base +| len, page_size);
}

/// THE HANDLER. Async-signal-safe: no allocation, no lock, no formatting, no
/// libc beyond `mmap` (and `sigaction` on the SIG_DFL chain, both plain
/// syscalls).
fn onSigbus(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    const addr = faultAddr(info);
    if (addr != 0) {
        for (&slots) |*s| {
            // Seqlock read: an odd or changing `seq` means this slot is being
            // armed/disarmed, which means it is not the region we are faulting
            // in (a live region is never mutated) — skip it.
            //
            // `seq_cst` throughout, deliberately. A seqlock needs the payload
            // reads to stay BETWEEN the two `seq` reads, and 0.16 removed
            // `@fence`, so total ordering is the only way left to say that
            // without hand-waving — an `acquire` load forbids later accesses from
            // moving before it but does not stop itself from being hoisted. The
            // cost lands only here, inside a fault that has already happened;
            // the no-fault path never executes a line of this function.
            const s1 = @atomicLoad(u32, &s.seq, .seq_cst);
            if (s1 & 1 != 0) continue;
            const base = @atomicLoad(usize, &s.base, .seq_cst);
            const len = @atomicLoad(usize, &s.len, .seq_cst);
            if (@atomicLoad(u32, &s.seq, .seq_cst) != s1) continue;
            if (len == 0) continue;
            const end = regionEnd(base, len);
            if (addr < base or addr >= end) continue;

            // Ours. Repair from the faulting page to the end of the region (a
            // truncation kills a suffix), falling back to the single page.
            const p = std.mem.alignBackward(usize, addr, page_size);
            if (p < end and (mapZeroOver(p, end - p) or mapZeroOver(p, page_size))) {
                // Publish BEFORE resuming: the interrupted code reads zeroes the
                // moment we return, and must be able to see that it did.
                _ = @atomicRmw(u32, &s.faults, .Add, 1, .release);
                return;
            }
            // Cannot repair. Falling through to `chain` dies honestly rather
            // than returning into an endless fault loop.
            break;
        }
    }
    chain(sig, info, ctx);
}

/// Hand the fault to whatever owned SIGBUS before us.
fn chain(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) void {
    const p = prev_action; // immutable after install
    if (p.flags & posix.SA.SIGINFO != 0) {
        if (p.handler.sigaction) |f| return f(sig, info, ctx);
    }
    const h = p.handler.handler;
    const hp = @intFromPtr(h);
    if (hp == @intFromPtr(posix.SIG.IGN)) return;
    if (hp == @intFromPtr(posix.SIG.DFL)) {
        // Put the default back and return: the faulting instruction re-executes
        // and the process dies with the correct signal, exactly as it would have
        // without us. This also permanently disarms the guard, which is
        // immaterial — we are on the way out.
        posix.sigaction(sig, &p, null);
        return;
    }
    if (h) |f| f(sig);
}

/// Install our chained handler for SIGBUS, exactly once per process. Caller holds
/// `table_mutex`.
fn installLocked() void {
    if (installed) return;
    page_size = std.heap.pageSize();
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = onSigbus },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO,
    };
    // The ONLY signal this core ever installs a handler for.
    posix.sigaction(.BUS, &act, &prev_action);
    installed = true;
}

/// Guard `region` (an mmap'd local file) and return its slot, or null if the
/// table is full (that document simply runs unguarded). Installs the handler on
/// first use. MUST be called before the region's bytes are first touched.
pub fn arm(region: []const u8) ?u32 {
    if (region.len == 0) return null;
    table_mutex.lockUncancelable(sysio.io());
    defer table_mutex.unlock(sysio.io());
    installLocked();
    for (&slots, 0..) |*s, i| {
        if (s.len != 0) continue;
        // Seqlock write: odd while the region is inconsistent, even when done.
        // A fresh region starts with a zeroed fault counter.
        _ = @atomicRmw(u32, &s.seq, .Add, 1, .seq_cst);
        @atomicStore(u32, &s.faults, 0, .seq_cst);
        @atomicStore(usize, &s.base, @intFromPtr(region.ptr), .seq_cst);
        @atomicStore(usize, &s.len, region.len, .seq_cst);
        _ = @atomicRmw(u32, &s.seq, .Add, 1, .seq_cst);
        return @intCast(i);
    }
    return null;
}

/// Stop guarding a slot. Called when the document releases its mapping, so it
/// must happen BEFORE the `munmap` (afterwards the address range could be handed
/// to an unrelated mapping and a fault there is not ours).
pub fn disarm(slot: ?u32) void {
    const i = slot orelse return;
    if (i >= slot_count) return;
    const s = &slots[i];
    table_mutex.lockUncancelable(sysio.io());
    defer table_mutex.unlock(sysio.io());
    _ = @atomicRmw(u32, &s.seq, .Add, 1, .seq_cst);
    @atomicStore(usize, &s.len, 0, .seq_cst);
    @atomicStore(usize, &s.base, 0, .seq_cst);
    _ = @atomicRmw(u32, &s.seq, .Add, 1, .seq_cst);
}

/// How many times this region has faulted. Callers bracket any work that reads
/// the mapping with this and discard the result if it moved — see the module
/// header. This is the guard's ENTIRE cost when nothing faults: one atomic load.
pub fn faultCount(slot: ?u32) u32 {
    const i = slot orelse return 0;
    if (i >= slot_count) return 0;
    return @atomicLoad(u32, &slots[i].faults, .acquire);
}
