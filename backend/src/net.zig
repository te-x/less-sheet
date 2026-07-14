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

const c = std.c;
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
    mutex: c.pthread_mutex_t = .{},
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
    thread: ?std.Thread = null,
    cancel_flag: std.atomic.Value(bool) = .init(false),

    fn lock(self: *NetOpenJob) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *NetOpenJob) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
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

fn failLocked(job: *NetOpenJob, err: api.NetStatus) void {
    job.lock();
    defer job.unlock();
    job.state = .failed;
    job.err = err;
}

/// Publish a successfully-built doc onto the job (or fail). `built` is null when
/// the Source build failed (transport already freed). Runs OUTSIDE the job lock
/// for the heavy fetch/build, taking the lock only to publish the terminal
/// state, so poll never blocks on a slow open.
fn publish(job: *NetOpenJob, built: ?net_source.BuiltSource) void {
    const b = built orelse return failLocked(job, .io);
    const doc = open.buildDocument(job.gpa, b.source, b.mapping, b.file_size, job.opt) orelse return failLocked(job, .io);
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
    job.bytes_total = b.file_size;
    job.bytes_fetched = b.file_size;
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
    switch (fx.fault) {
        .none => {},
        .connect => return failLocked(job, .unreachable_),
        .timeout => return failLocked(job, .timeout),
        .io => return failLocked(job, .io),
    }
    if (fx.redirect_hops > redirect_cap) return failLocked(job, .too_many_redirects);
    if (fx.http_status != 200 and fx.http_status != 206) {
        job.http_status = @intCast(fx.http_status);
        return failLocked(job, .http_status);
    }
    if (fx.stall) {
        // A live, non-terminal open: cancel is the only way out (AC8/AC9).
        job.state = .fetching;
        return;
    }
    const total = fx.body.len;
    const range = fx.honor_ranges and fx.advertise_length;
    const is_gz = total >= 2 and fx.body[0] == 0x1f and fx.body[1] == 0x8b;
    const body_copy = job.gpa.dupe(u8, fx.body) catch return failLocked(job, .io);
    const transport: net_source.Transport = .{ .fake = body_copy };
    const progress: net_source.Progress = .{ .ctx = job, .callback = onProgress };
    const built = if (range and !is_gz)
        net_source.buildRandom(job.gpa, transport, total, progress)
    else
        net_source.buildDownloadAll(job.gpa, transport, total, progress);
    publish(job, built);
}

/// Background real-transport worker (std.http.Client). Not exercised by the
/// gate. Reuses ONE `RealTransport` (one std.http.Client / connection pool) for
/// the probe AND every subsequent ranged fetch (round-2 review finding 5) —
/// no fresh TCP/TLS handshake per 256 KiB chunk.
fn realWorker(job: *NetOpenJob) void {
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
    job.bytes_total = probe.total;
    job.progress = if (probe.total > 0) 0.0 else api.net_progress_unknown;
    job.unlock();

    const transport: net_source.Transport = .{ .real = rt };
    const progress: net_source.Progress = .{ .ctx = job, .callback = onProgress };
    const built = if (probe.range)
        net_source.buildRandom(job.gpa, transport, probe.total, progress)
    else
        net_source.buildDownloadAll(job.gpa, transport, probe.total, progress);
    publish(job, built);
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
    job.thread = std.Thread.spawn(.{}, realWorker, .{job}) catch {
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
    if (job.thread) |t| {
        t.join();
        job.thread = null;
    } else {
        cancel(job);
    }
    if (job.url.len > 0) job.gpa.free(job.url);
    _ = c.pthread_mutex_destroy(&job.mutex);
    job.gpa.destroy(job);
}

pub fn jobProbe(job: *const NetOpenJob) api.NetJobProbe {
    const j = @constCast(job);
    j.lock();
    defer j.unlock();
    return .{ .spool_present = j.spool_present, .fetch_count = j.fetch_count };
}
