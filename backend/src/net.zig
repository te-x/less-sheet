//! network-source slice (ARCH-network-source): the asynchronous URL-open job
//! behind the ls_open_url_* C ABI and the openUrlStartFake test seam.
//!
//! SEED (planner freeze). This module validates the URL scheme/shape and the
//! open options SYNCHRONOUSLY — a scheme other than http/https, a malformed
//! URL, or an out-of-domain ls_open_options field fails the job immediately with
//! LS_NET_ERROR_INVALID_ARGUMENT and touches no network (that path is correct
//! from the seed) — then, for a well-formed request, FAILS the job with
//! LS_NET_ERROR_UNREACHABLE because no transport is wired yet. That single RED
//! outcome is what keeps every transport-dependent acceptance criterion RED.
//!
//! IMPLEMENTER'S WORK (flips RED -> GREEN). Add the `http_range` Source (a peer
//! to mmap/gzip in source.zig — survey the Gzip struct's spill-file / chunk /
//! resident-budget idiom and mirror it), the real std.http.Client transport
//! (std.Io.Threaded), the injected fake transport that consumes a
//! `api.NetFixture` for `openUrlStartFake`, the range-probe/fallback decision,
//! the persist-once spool file (0600, unlinked, never re-fetch), the bounded
//! (16 MiB) RAM cache, and the DONE-doc construction (feed the fetched head
//! through the SAME internal open path ls_open uses, so every existing accessor
//! works). Populate the Document `net_*` instrumentation fields (see base.zig)
//! and this job's `spool_present`/`fetch_count` as the fetch runs. The job
//! lifecycle ABI (start/poll/cancel/release) and its state machine are the
//! FROZEN entry points; only their behavior for a well-formed request is RED.

const std = @import("std");
const api = @import("api");

const c = std.c;
const default_gpa = std.heap.smp_allocator;

/// The async open-job behind `ls_net_open_job`. Core-owned; freed by
/// `release`. A `.done` job's `doc` outlives the job (closed independently by
/// ls_close). The implementer adds the transport / fetch-thread / spool /
/// nascent-Source fields here.
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
    // Job-level resource instrumentation (netJobProbe): the in-flight fetch's
    // private spool file and network fetch count, before any doc exists. The
    // implementer maintains these as the fetch runs and clears them on cancel.
    // SEED: never set.
    spool_present: bool = false,
    fetch_count: u64 = 0,

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

// Same domain as root.validateOptions; duplicated (a tiny pure check) rather
// than imported to avoid a root<->net import cycle.
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
    // http/https only (case-insensitive per spec; the seed accepts the lowercase
    // forms the tests use — the implementer may broaden to case-insensitive).
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

/// Shared job constructor for the real (`fixture == null`, std.http.Client) and
/// injected-transport (`fixture != null`) start paths — the twin of
/// `openWithAllocator` for ls_open. See the module doc for the seed behavior.
pub fn startJob(gpa: std.mem.Allocator, url: [*]const u8, url_len: usize, options: ?*const api.OpenOptions, fixture: ?*const api.NetFixture) ?*NetOpenJob {
    _ = fixture; // SEED: no transport wired; a well-formed request fails UNREACHABLE.
    const job = gpa.create(NetOpenJob) catch return null;
    job.* = .{ .gpa = gpa };
    const opt: api.OpenOptions = if (options) |o| o.* else .{};
    if (!validScheme(url[0..url_len]) or !validOptions(opt)) {
        job.state = .failed;
        job.err = .invalid_argument;
        return job;
    }
    job.state = .failed;
    job.err = .unreachable_;
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
    job.lock();
    defer job.unlock();
    switch (job.state) {
        .pending, .fetching => {
            // The implementer stops the fetch at its next chunk boundary and
            // releases resources (spool included) here.
            job.state = .cancelled;
            job.err = .cancelled;
            job.spool_present = false;
        },
        else => {}, // terminal: no-op
    }
}

pub fn release(job: *NetOpenJob) void {
    // If still in flight, cancel + join the fetch first (like ls_close on a
    // scanning document). SEED: nothing to join. Never closes job.doc (the doc
    // follows the independent ls_close lifecycle).
    cancel(job);
    _ = c.pthread_mutex_destroy(&job.mutex);
    job.gpa.destroy(job);
}

pub fn jobProbe(job: *const NetOpenJob) api.NetJobProbe {
    const j = @constCast(job);
    j.lock();
    defer j.unlock();
    return .{ .spool_present = j.spool_present, .fetch_count = j.fetch_count };
}
