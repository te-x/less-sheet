//! network-source slice (ARCH-network-source): the asynchronous URL-open job
//! behind the ls_open_url_* C ABI and the openUrlStartFake test seam.
//!
//! The job validates the URL scheme/options SYNCHRONOUSLY (a non-http/https
//! scheme, a malformed URL, or an out-of-domain option fails immediately with
//! LS_NET_ERROR_INVALID_ARGUMENT, no network touched), then:
//!   * FAKE transport (openUrlStartFake / the gate): runs the whole open
//!     synchronously from the injected `api.NetFixture` — range-probe/fallback
//!     decision, spool build, head fetch, DONE-doc construction — so the first
//!     poll is already terminal (a STALL fixture is the one exception: it stays
//!     FETCHING until cancelled, modelling a server that never responds).
//!   * REAL transport (ls_open_url_start): spawns a background fetch thread over
//!     std.http.Client. The gate never exercises this path — it is the human
//!     target-host probe per contracts/api.zig NETWORK notes — but it is a real,
//!     working implementation.
//!
//! Either way a DONE job's `doc` is built through the SAME internal open path
//! ls_open uses (open.buildDocument), fed by an http_range (random-access) or a
//! downloaded mmap/gzip Source, so every existing accessor works unchanged.

const std = @import("std");
const api = @import("api");

const sysio = @import("sysio.zig");
const default_gpa = std.heap.smp_allocator;

const net_source = @import("net_source.zig");
const open = @import("open.zig");
const base = @import("base.zig");
const source_mod = @import("source.zig");

const redirect_cap: u32 = 3;

/// The async open-job behind `ls_net_open_job`. Core-owned; freed by `release`.
/// A `.done` job's `doc` outlives the job (closed independently by ls_close).
pub const NetOpenJob = struct {
    gpa: std.mem.Allocator,
    mutex: sysio.Mutex = .init,
    state: api.NetOpenState = .pending,
    err: api.NetStatus = .ok,
    http_status: i32 = 0,
    progress: f64 = api.net_progress_unknown,
    bytes_fetched: u64 = 0,
    bytes_total: u64 = 0,
    doc: ?*api.Doc = null,
    spool_present: bool = false,
    fetch_count: u64 = 0,
    // Real-transport background fetch.
    url: []u8 = &.{},
    opt: api.OpenOptions = .{},
    /// The in-flight `realWorker` task (real transport only). A `Future`, not a
    /// `std.Thread`: only a task of a `std.Io.Threaded` executor can have its
    /// blocking socket syscalls interrupted, which is what lets `release` join a
    /// worker parked in a TLS handshake instead of hanging on it forever. See
    /// `net_source.netIo`.
    future: ?std.Io.Future(void) = null,
    cancel_flag: std.atomic.Value(bool) = .init(false),

    fn lock(self: *NetOpenJob) void {
        self.mutex.lockUncancelable(sysio.io());
    }
    fn unlock(self: *NetOpenJob) void {
        self.mutex.unlock(sysio.io());
    }
};

fn validByte(v: i32) bool {
    return v >= 0x01 and v <= 0x7F and v != 0x0A and v != 0x0D;
}

fn validOptions(opt: api.OpenOptions) bool {
    if (opt.separator != api.sniff and !validByte(opt.separator)) return false;
    if (opt.quote != api.sniff and opt.quote != api.quote_none and !validByte(opt.quote)) return false;
    if (opt.header != api.sniff and opt.header != api.header_off and opt.header != api.header_on) return false;
    if (opt.index_mode != api.index_auto and opt.index_mode != api.index_manual) return false;
    if (opt.encoding != api.encoding_auto and !(opt.encoding >= 0 and opt.encoding <= @as(i32, api.encoding_windows1252))) return false;
    if (opt.separator != api.sniff and opt.separator == opt.quote) return false;
    return true;
}

fn validScheme(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");
}

/// Terminate the job as FAILED — except that a failure observed after the caller
/// asked to cancel IS the cancellation: now that the worker is a cancellable task
/// (see `NetOpenJob.future`), an interrupted syscall surfaces as an ordinary
/// error (`error.Canceled` -> a failed fetch / a failed spool write), and
/// reporting that as FAILED/IO would contradict the state `cancel` already
/// published.
///
/// SCOPE — this is the predicate for every failure routed THROUGH here, not the
/// only site that maintains the invariant. Two terminal paths set state inline
/// and each repeats its own `cancel_flag` check first: `realWorker`'s
/// probe-failure arm (it also publishes `http_status`, which this helper does not
/// carry, so it cannot call in) and `publish`'s cancelled-while-building arm.
/// Three sites agree today; they are not one site. Any new terminal path must
/// either call `failLocked` or repeat the cancel-wins check — and if a third
/// inline site is ever needed, lift the shared part into a helper that can carry
/// `http_status` instead of adding another copy.
fn failLocked(job: *NetOpenJob, err: api.NetStatus) void {
    job.lock();
    defer job.unlock();
    if (job.cancel_flag.load(.acquire)) {
        job.state = .cancelled;
        job.err = .cancelled;
        job.spool_present = false;
        return;
    }
    job.state = .failed;
    job.err = err;
}

/// Publish a successfully-built doc onto the job (or fail). `built` is null when
/// the Source build failed (transport already freed). Runs OUTSIDE the job lock
/// for the heavy fetch/build, taking the lock only to publish the terminal
/// state, so poll never blocks on a slow open.
fn publish(job: *NetOpenJob, built: ?net_source.BuiltSource, build_err: api.NetStatus) void {
    const b = built orelse return failLocked(job, build_err);
    // No SOURCE-FAULT GUARD slot and no fd: AC-g1 scopes the guard to a LOCAL
    // file's mapping, and a network document's spool is a file this process
    // creates, holds open and extends itself — not one another process truncates.
    const doc = open.buildDocument(job.gpa, b.source, b.mapping, null, null, b.file_size, job.opt) orelse
        return failLocked(job, .io);
    doc.net_range_mode = b.range_mode;
    if (job.cancel_flag.load(.acquire)) {
        // Cancelled while building: drop the doc, report cancelled.
        base.freeDoc(doc);
        job.lock();
        defer job.unlock();
        job.state = .cancelled;
        job.err = .cancelled;
        return;
    }
    job.lock();
    defer job.unlock();
    job.doc = @ptrCast(doc);
    // Honest DONE (never-full-download-streaming): report the REAL head bytes
    // fetched and the known total (0 when the length is unknown) — not the old
    // fetched=total=file_size white lie, which for a streaming doc would falsely
    // imply a full download. progress = 1.0 means "open complete", NOT
    // "downloaded" (the ABI's LS_NET_OPEN_DONE semantics).
    job.bytes_total = if (b.length_known) b.file_size else 0;
    job.bytes_fetched = b.head_fetched;
    job.progress = 1.0;
    job.state = .done;
}

/// Live-progress trampoline (round-2 review finding 1): net_source calls this
/// on every actual network fetch (never a cache hit) with the running (bytes
/// fetched, total). Updates the job's poll-visible progress/bytes fields so
/// `ls_net_open_poll` reports REAL incremental progress, not just a start/
/// terminal snapshot. A no-op once the job has already reached a terminal
/// state (a late callback from a build that raced a cancel must not resurrect
/// a stale `.fetching`).
fn onProgress(ctx: *anyopaque, fetched: u64, total: u64) void {
    const job: *NetOpenJob = @ptrCast(@alignCast(ctx));
    job.lock();
    defer job.unlock();
    switch (job.state) {
        .done, .failed, .cancelled => return,
        .pending, .fetching => {},
    }
    job.state = .fetching;
    job.bytes_fetched = fetched;
    job.bytes_total = total;
    job.progress = if (total > 0) @as(f64, @floatFromInt(fetched)) / @as(f64, @floatFromInt(total)) else api.net_progress_unknown;
}

/// Synchronous fake-transport open from an injected fixture (the gate path).
fn runFake(job: *NetOpenJob, fx: *const api.NetFixture) void {
    // OPEN IS A DESIGNATED FETCHER (see `source.fetchPermitted`): the open-time
    // inflate of the gz head (`Gzip.initProvider` -> `inflateOpenHead`) and the
    // O(head) open scan must fetch, and AC-e1 already scopes open's latency to
    // "bounded by user cancel" (`ls_open_url_cancel`). Its own scope, not the
    // worker's: the permit is thread-local, and this body runs SYNCHRONOUSLY on
    // the caller's thread (`startJob` calls it inline) while `realWorker` runs on
    // an executor thread — neither inherits the other's.
    const permit = source_mod.beginFetchPermit();
    defer source_mod.endFetchPermit(permit);
    switch (fx.fault) {
        .none => {},
        .connect => return failLocked(job, .unreachable_),
        .timeout => return failLocked(job, .timeout),
        .io => return failLocked(job, .io),
    }
    if (fx.redirect_hops > redirect_cap) return failLocked(job, .too_many_redirects);
    // security-hardening (e) AC-e2: a redirect whose Location downgrades the
    // transport https->http is refused with a distinct code. The fixture models
    // the downgrade condition; routing it through the PURE decision
    // (net_source.redirectDowngrades) pins the taxonomy mapping the real
    // std.http.Client redirect path uses too (same seam, hermetically testable).
    if (fx.redirect_downgrade and net_source.redirectDowngrades("https", "http"))
        return failLocked(job, .insecure_redirect);
    if (fx.http_status != 200 and fx.http_status != 206) {
        job.http_status = @intCast(fx.http_status);
        return failLocked(job, .http_status);
    }
    if (fx.stall) {
        // A live, non-terminal open: cancel is the only way out (AC8/AC9).
        job.state = .fetching;
        return;
    }
    // Fake classification (mirrors decideProbe over the fixture's server shape):
    // honor_ranges + a usable length -> RANDOM fill (known); no usable length ->
    // SEQUENTIAL fill of an UNKNOWN-length stream; otherwise SEQUENTIAL fill
    // (known). gzip is detected on the fetched head inside buildNet and composes
    // over the same spool (no longer forced down a whole-file download).
    const known = fx.advertise_length;
    const range = fx.honor_ranges and fx.advertise_length;
    const total: u64 = if (known) fx.body.len else 0;
    const fs = job.gpa.create(net_source.FakeServer) catch return failLocked(job, .io);
    fs.* = .{
        .body = job.gpa.dupe(u8, fx.body) catch {
            job.gpa.destroy(fs);
            return failLocked(job, .io);
        },
        .released = fx.withhold,
        .drop_after = fx.drop_after,
        .short_body_at = fx.short_body_at, // security-hardening (e) AC-e3 short-body seam
        .attempts = fx.fetch_attempts, // frontier-commit-guard request-attempt tally
    };
    const transport: net_source.Transport = .{ .fake = fs };
    const progress: net_source.Progress = .{ .ctx = job, .callback = onProgress };
    var build_err: api.NetStatus = .io;
    const built = net_source.buildNet(job.gpa, transport, .{ .range = range, .total_known = known, .total = total }, progress, &build_err);
    publish(job, built, build_err);
}

/// Background real-transport worker (std.http.Client). Not exercised by the
/// gate. Reuses ONE `RealTransport` (one std.http.Client / connection pool) for
/// the probe AND every subsequent ranged fetch (round-2 review finding 5) —
/// no fresh TCP/TLS handshake per 256 KiB chunk.
fn realWorker(job: *NetOpenJob) void {
    // OPEN IS A DESIGNATED FETCHER — see `runFake` for why, and why each open
    // body opens its own thread-local scope.
    const permit = source_mod.beginFetchPermit();
    defer source_mod.endFetchPermit(permit);
    const rt = net_source.RealTransport.init(job.gpa, job.url) catch return failLocked(job, .io);
    const probe = rt.probe();
    if (job.cancel_flag.load(.acquire)) {
        rt.deinit();
        job.lock();
        job.state = .cancelled;
        job.err = .cancelled;
        job.unlock();
        return;
    }
    if (!probe.ok) {
        rt.deinit();
        job.lock();
        job.http_status = probe.http_status;
        job.state = .failed;
        job.err = probe.err;
        job.unlock();
        return;
    }
    job.lock();
    job.state = .fetching;
    job.bytes_total = if (probe.length_known) probe.total else 0;
    job.progress = if (probe.length_known and probe.total > 0) 0.0 else api.net_progress_unknown;
    job.unlock();

    const transport: net_source.Transport = .{ .real = rt };
    const progress: net_source.Progress = .{ .ctx = job, .callback = onProgress };
    // Every case streams through the http_range Source now (never a full
    // download): `probe.range` picks random vs sequential fill, and a gzip
    // resource composes the gzip Source over that spool (TD4) — buildNet detects
    // the magic on the fetched head.
    var build_err: api.NetStatus = .io;
    const built = net_source.buildNet(job.gpa, transport, .{ .range = probe.range, .total_known = probe.length_known, .total = probe.total }, progress, &build_err);
    publish(job, built, build_err);
}

/// Shared job constructor for the real (`fixture == null`, std.http.Client) and
/// injected-transport (`fixture != null`) start paths — the twin of
/// `openWithAllocator` for ls_open.
pub fn startJob(gpa: std.mem.Allocator, url: [*]const u8, url_len: usize, options: ?*const api.OpenOptions, fixture: ?*const api.NetFixture) ?*NetOpenJob {
    const job = gpa.create(NetOpenJob) catch return null;
    job.* = .{ .gpa = gpa };
    const opt: api.OpenOptions = if (options) |o| o.* else .{};
    job.opt = opt;
    if (!validScheme(url[0..url_len]) or !validOptions(opt)) {
        job.state = .failed;
        job.err = .invalid_argument;
        return job;
    }
    if (fixture) |fx| {
        runFake(job, fx);
        return job;
    }
    // Real transport: spawn a background fetch thread.
    job.url = gpa.dupe(u8, url[0..url_len]) catch {
        job.state = .failed;
        job.err = .io;
        return job;
    };
    job.state = .pending;
    // `concurrent`, never `async`: `async` is allowed to run the task EAGERLY on
    // this thread when no unit of concurrency is free (Io.zig:2358-2364), which
    // would turn `ls_open_url_start` — documented to return immediately — into a
    // blocking whole-open call. `concurrent` guarantees a separate thread or
    // fails, and that thread is executor-owned, hence cancellable.
    job.future = net_source.netIo().concurrent(realWorker, .{job}) catch {
        job.state = .failed;
        job.err = .unreachable_;
        return job;
    };
    return job;
}

pub fn poll(job: *const NetOpenJob) api.NetOpenStatus {
    const j = @constCast(job);
    j.lock();
    defer j.unlock();
    return .{
        .progress = j.progress,
        .bytes_fetched = j.bytes_fetched,
        .bytes_total = j.bytes_total,
        .doc = j.doc,
        .state = j.state,
        .err = j.err,
        .http_status = j.http_status,
        .reserved = 0,
    };
}

pub fn cancel(job: *NetOpenJob) void {
    job.cancel_flag.store(true, .release);
    job.lock();
    defer job.unlock();
    switch (job.state) {
        .pending, .fetching => {
            job.state = .cancelled;
            job.err = .cancelled;
            job.spool_present = false;
        },
        else => {}, // terminal: no-op
    }
}

pub fn release(job: *NetOpenJob) void {
    // If a real fetch is still in flight, signal cancel and join it first (like
    // ls_close on a scanning document). Never closes job.doc.
    job.cancel_flag.store(true, .release);
    if (job.future) |*f| {
        // `Future.cancel` = request cancellation + await. The request is what
        // actually TEARS DOWN a parked fetch: the executor interrupts the
        // worker's blocking socket syscall (SIGIO) until it acknowledges, the
        // read fails with `error.Canceled`, and the worker unwinds — so this
        // join terminates whether the peer accepted the TCP connection and then
        // answered nothing (parked in `receiveHead`) or sent valid 206 headers
        // and a few KiB and then went silent (parked in the BODY read).
        //   THAT SECOND CASE IS NOT FREE, and the join is only as reliable as
        // the worker's unwind. The interrupt lands ONCE: it leaves the executor
        // thread `.canceled`, and every syscall the worker makes AFTERWARDS is
        // uninterruptible (`Syscall.start` -> `.{ .thread = null }`,
        // Threaded.zig:1364). So a worker that answers `error.Canceled` by
        // reading again does not get a second cancel — it parks forever and
        // takes this join with it. `net_source`'s ONE-SHOT CANCELLATION note has
        // the mechanism and the rule it imposes (a failed read is TERMINAL);
        // `probe` violating it with one `catch 0` was the whole of net_body_hang.
        //   Idempotent; an already-finished task returns at once. There is no
        // request-WITHOUT-await primitive in the 0.16 `Io` vtable, which is why
        // the teardown lands here (release joins, and is documented to) rather
        // than in the non-blocking `cancel`.
        f.cancel(net_source.netIo());
        job.future = null;
    } else {
        cancel(job);
    }
    if (job.url.len > 0) job.gpa.free(job.url);
    // std.Io.Mutex needs no explicit destroy (unlike pthread_mutex_destroy).
    job.gpa.destroy(job);
}

pub fn jobProbe(job: *const NetOpenJob) api.NetJobProbe {
    const j = @constCast(job);
    j.lock();
    defer j.unlock();
    return .{ .spool_present = j.spool_present, .fetch_count = j.fetch_count };
}
