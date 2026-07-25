//! network-source slice (ARCH-network-source): the `http_range` byte Source —
//! a genuinely random-access provider peer to mmap/gzip (source.zig), backed by
//! a private, unlinked local spool file (mode 0600) plus a bounded (16 MiB) RAM
//! chunk cache. A byte, once fetched over the transport, is persisted to the
//! spool and NEVER re-fetched (AC6/AC13/AC14). The transport is either the real
//! std.http.Client (production) or an injected fake describing a server
//! (tests — the gate exercises only the fake; the real client is a human
//! target-host probe, per contracts/api.zig NETWORK notes).
//!
//! Mirrors the gzip Source's spill-file idiom (source.Gzip.createSpill): open a
//! /tmp file O_CREAT|O_EXCL mode 0600, unlink it immediately, keep the fd. The
//! spool is grown to the resource's total length (a sparse file) and mmap'd
//! MAP_SHARED read/write, so a fetched range is written through the mapping and
//! served back from it forever after (disk-bound replay, never network).

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");
const source_mod = @import("source.zig");

const posix = std.posix;
const sysio = @import("sysio.zig");

/// Short blocking sleep (portable std.Io sleep) used to back off while a
/// sequential fill waits for withheld bytes. Never holds a lock.
fn sleepMs(ms: u64) void {
    sysio.sleepMs(ms);
}

pub const chunk_bytes: u64 = 256 * 1024; // mirrors source.chunk_bytes
pub const cache_ceiling: u64 = 16 * 1024 * 1024; // 16 MiB resident RAM bound (AC15)
// The network open-head prefetch size. net_source is ALWAYS the network path,
// so it reads the single net-head constant directly (no net-vs-local branch here
// — that decision lives only in index.headBudget). See base.net_head_budget.
const open_bytes: u64 = base.net_head_budget;
const redirect_cap: u32 = 3; // Zig std's small fixed redirect cap (AC12)

/// security-hardening (e) AC-e1: the real-transport CONNECT timeout (the single
/// named knob, single source of truth). ~10 s: a non-responding connect fails
/// retryably, WIRED via ConnectTcpOptions.timeout in `RealTransport.dial`, so the
/// fetch thread/document never hangs on a dead host. There is NO idle-read
/// timeout in v1 (deferred): Zig 0.16 `std.http.Client`'s blocking response
/// reader exposes no per-read deadline hook, so a stalled ESTABLISHED stream is
/// covered by the cancellable/retry fetch model + user cancel instead. The
/// hermetic connect-timeout taxonomy (a stalled connect -> LS_NET_ERROR_TIMEOUT)
/// is exercised by the fake (NetFault.timeout).
pub const connect_timeout_secs: i64 = 10;

/// security-hardening (e) AC-e2: the PURE redirect scheme-downgrade decision — a
/// small, unit-testable seam used by BOTH the fake taxonomy mapping (net.runFake)
/// and the real std.http.Client redirect handling (RealTransport). A redirect
/// DOWNGRADES the transport iff it leaves an https origin for a plaintext http
/// one; that alone is refused (LS_NET_ERROR_INSECURE_REDIRECT). http->https
/// (upgrade), https->https and http->http (same-scheme, incl. cross-host) are all
/// allowed within the cap. Case-insensitive on the scheme text.
pub fn redirectDowngrades(from_scheme: []const u8, to_scheme: []const u8) bool {
    const from_secure = std.ascii.eqlIgnoreCase(from_scheme, "https");
    const to_secure = std.ascii.eqlIgnoreCase(to_scheme, "https");
    return from_secure and !to_secure;
}

/// The URL's scheme text ("https" / "http" / …) for the downgrade check, without
/// a full parse (a leading-token scan is enough and never fails).
fn schemeOf(url: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return url;
    return url[0..colon];
}

/// Live-progress callback (round-2 review finding 1): invoked with the running
/// (bytes fetched so far, resource total) every time a NEW range is actually
/// fetched over the transport (never on a cache/spool hit), so a poller
/// (`ls_net_open_poll`) sees real, incrementally-updating progress rather than
/// only a start/terminal snapshot. `ctx` is caller-owned (net.zig's NetOpenJob).
pub const ProgressFn = *const fn (ctx: *anyopaque, fetched: u64, total: u64) void;
pub const Progress = struct { ctx: *anyopaque, callback: ProgressFn };

// ---------------------------------------------------------------------------
// Transport: the byte provider a range fetch goes through.
// ---------------------------------------------------------------------------

/// The result of a real probe request: the resource total length + whether the
/// server honored Range, or the mapped failure.
pub const Probe = struct {
    ok: bool = false,
    total: u64 = 0,
    range: bool = false,
    is_gz: bool = false,
    length_known: bool = false,
    err: api.NetStatus = .ok,
    http_status: i32 = 0,
};

/// Parses the resource's TRUE total length out of a `Content-Range:
/// bytes start-end/total` response header (raw head bytes, CRLF-separated).
/// A 206 response's `Content-Length` is the size of THIS partial response
/// only — for any range narrower than the full resource that is NOT the
/// resource's total, so the total must come from Content-Range instead.
/// Returns null when the header is absent or its total is `*` (unknown).
/// Pure (no I/O). NOTE: the network-open strategy is slated to change to
/// never-full-download streaming (see ARCH backlog) — when that lands, this +
/// `decideProbe` should gain hermetic unit-test seams (they are the crux of
/// two fixed real-transport bugs the fake-transport gate path can't reach).
pub fn parseContentRangeTotal(head_bytes: []const u8) ?u64 {
    var lines = std.mem.splitSequence(u8, head_bytes, "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-range")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const slash = std.mem.lastIndexOfScalar(u8, value, '/') orelse return null;
        const total_str = value[slash + 1 ..];
        if (std.mem.eql(u8, total_str, "*")) return null;
        return std.fmt.parseInt(u64, total_str, 10) catch null;
    }
    return null;
}

/// The pure fill-strategy / length classification from a SUCCESSFUL (2xx)
/// probe's raw signals — extracted from `probe()` so it is unit-testable without
/// a real HTTP server (the crux of two fixed live-transport bugs). `status` is
/// 2xx; `content_length` is the response's Content-Length (the whole resource
/// for 200, only the PARTIAL slice for 206, null when absent);
/// `content_range_total` is `parseContentRangeTotal` of the head (null unless a
/// usable `Content-Range: …/total` was present); `is_gz` is the leading-magic
/// (1f 8b) verdict on the body head. A 206's Content-Length is the partial slice
/// (never the total), so a 206 without a usable Content-Range total is treated
/// as an unknown-length stream rather than truncated to the probe range.
/// never-full-download-streaming (AC17 / TD4 / TD5): the REAL streaming
/// classification. Two changes from the old download-all model:
///   * `range = !is_gz` is DROPPED — gzip now composes over the growing spool
///     (random OR sequential fill), so a gzip resource on a range host keeps
///     random access instead of forcing a full download.
///   * `length_known` splits `Content-Length: 0` (a genuinely EMPTY resource,
///     known total 0) from an ABSENT length (an unknown-length stream whose
///     total firms only at EOF).
/// Mapping:
///   206 + a usable Content-Range total -> RANDOM fill, known total.
///   206 without a usable total -> SEQUENTIAL fill, UNKNOWN length (a 206's
///     Content-Length is only the partial slice, never the resource total).
///   200 + Content-Length present (incl. 0) -> SEQUENTIAL fill, known total.
///   200 with an absent Content-Length -> SEQUENTIAL fill, UNKNOWN length.
/// Pure (no I/O); unit-tested via the api.decideProbe seam.
pub fn decideProbe(status: i32, content_length: ?u64, content_range_total: ?u64, is_gz: bool) api.ProbeDecision {
    if (status == 206) {
        if (content_range_total) |total|
            return .{ .range = true, .total = total, .length_known = true, .is_gz = is_gz };
        return .{ .range = false, .total = 0, .length_known = false, .is_gz = is_gz };
    }
    if (content_length) |cl|
        return .{ .range = false, .total = cl, .length_known = true, .is_gz = is_gz };
    return .{ .range = false, .total = 0, .length_known = false, .is_gz = is_gz };
}

/// One real host connection for the whole job's lifetime: ONE `std.http.Client`
/// (and its `Io.Threaded` executor), constructed once and reused across the
/// probe AND every subsequent ranged fetch — `std.http.Client`'s connection
/// pool then keeps the underlying TCP/TLS connection alive across requests to
/// the same host instead of a fresh handshake per 256 KiB chunk (round-2 review
/// finding 5). Heap-allocated so its address (captured by `Io.Threaded.io()`)
/// stays stable for the transport's whole lifetime.
/// The result of one forward drain of a sequential body reader: bytes copied
/// into `dest` and whether the stream ended (clean or dropped).
pub const DrainResult = struct { n: usize, eof: bool };

/// A persistent forward-draining GET for SEQUENTIAL fill (TD3): ONE request
/// whose response body is drained across successive `drainForward` calls, so a
/// no-range server is NOT re-GET per 256 KiB chunk (the shipped bug). The
/// request/response/transfer buffer are heap-owned so the body Reader's
/// internal pointers stay stable across drains.
const SeqStream = struct {
    req: std.http.Client.Request,
    response: std.http.Client.Response,
    transfer_buf: [64 * 1024]u8 = undefined,
    reader: *std.Io.Reader = undefined,
    drained: u64 = 0,
    ended: bool = false,
};

pub const RealTransport = struct {
    gpa: std.mem.Allocator,
    url: []u8, // owned NUL-free copy
    threaded: std.Io.Threaded,
    client: std.http.Client,
    seq: ?*SeqStream = null, // the persistent sequential body reader (lazy)

    pub fn init(gpa: std.mem.Allocator, url: []const u8) !*RealTransport {
        const self = try gpa.create(RealTransport);
        errdefer gpa.destroy(self);
        const url_copy = try gpa.dupe(u8, url);
        errdefer gpa.free(url_copy);
        self.* = .{ .gpa = gpa, .url = url_copy, .threaded = std.Io.Threaded.init(gpa, .{}), .client = undefined };
        self.client = .{ .allocator = gpa, .io = self.threaded.io() };
        return self;
    }

    pub fn deinit(self: *RealTransport) void {
        if (self.seq) |ss| {
            ss.req.deinit();
            self.gpa.destroy(ss);
        }
        self.client.deinit();
        self.threaded.deinit();
        self.gpa.free(self.url);
        self.gpa.destroy(self);
    }

    /// SEQUENTIAL fill (TD3): drain the resource body forward. `offset` must
    /// equal the already-drained high-water (sequential access — never a
    /// backward/random request, which the reader's forward-contiguous invariant
    /// guarantees). Opens ONE GET lazily on the first call and reuses it.
    fn drainForward(self: *RealTransport, dest: []u8, offset: u64) DrainResult {
        if (self.seq == null) {
            const ss = self.gpa.create(SeqStream) catch return .{ .n = 0, .eof = true };
            const uri = std.Uri.parse(self.url) catch {
                self.gpa.destroy(ss);
                return .{ .n = 0, .eof = true };
            };
            ss.* = .{ .req = self.client.request(.GET, uri, .{ .redirect_behavior = .init(redirect_cap) }) catch {
                self.gpa.destroy(ss);
                return .{ .n = 0, .eof = true };
            }, .response = undefined };
            ss.req.sendBodiless() catch {
                ss.req.deinit();
                self.gpa.destroy(ss);
                return .{ .n = 0, .eof = true };
            };
            var redirect_buf: [8192]u8 = undefined;
            ss.response = ss.req.receiveHead(&redirect_buf) catch {
                ss.req.deinit();
                self.gpa.destroy(ss);
                return .{ .n = 0, .eof = true };
            };
            const code = @intFromEnum(ss.response.head.status);
            if (code < 200 or code >= 300) {
                ss.req.deinit();
                self.gpa.destroy(ss);
                return .{ .n = 0, .eof = true };
            }
            ss.reader = ss.response.reader(&ss.transfer_buf);
            self.seq = ss;
        }
        const ss = self.seq.?;
        if (ss.ended or offset != ss.drained) return .{ .n = 0, .eof = ss.ended };
        const n = ss.reader.readSliceShort(dest) catch {
            ss.ended = true;
            return .{ .n = 0, .eof = true };
        };
        ss.drained += n;
        if (n == 0) ss.ended = true;
        return .{ .n = n, .eof = n == 0 };
    }

    /// security-hardening (e) AC-e1: acquire a connection to `uri`'s host with the
    /// CONNECT timeout applied. Reuses a pooled connection when present (no
    /// re-handshake), so the timeout bounds only a FRESH connect (e.g. a
    /// non-responding server on the initial probe). null on failure.
    fn dial(self: *RealTransport, uri: std.Uri) ?*std.http.Client.Connection {
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return null;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_buf) catch return null;
        const default_port: u16 = switch (protocol) {
            .plain => 80,
            .tls => 443,
        };
        const port = uri.port orelse default_port;
        return self.client.connectTcpOptions(.{
            .host = host,
            .port = port,
            .protocol = protocol,
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(connect_timeout_secs), .clock = .awake } },
        }) catch null;
    }

    /// One ranged GET for the head bound. 206 + Content-Range total => random
    /// fill; 200 + Content-Length => sequential fill (known); no usable length
    /// => sequential fill of an unknown-length stream. Also reads the first 2
    /// body bytes (already in flight on this same request/response — no extra
    /// round-trip) so `decideProbe` classifies exactly as the fake transport
    /// does; `buildNet` then detects the `.csv.gz` magic on the fetched head and
    /// composes the gzip Source over the same spool (never a full download).
    pub fn probe(self: *RealTransport) Probe {
        const uri = std.Uri.parse(self.url) catch return .{ .err = .invalid_argument };
        var range_buf: [64]u8 = undefined;
        const range_val = std.fmt.bufPrint(&range_buf, "bytes=0-{d}", .{open_bytes - 1}) catch return .{ .err = .io };
        const conn = self.dial(uri) orelse return .{ .err = .unreachable_ };
        var req = self.client.request(.GET, uri, .{
            .connection = conn,
            .redirect_behavior = .init(redirect_cap),
            .extra_headers = &.{.{ .name = "range", .value = range_val }},
        }) catch return .{ .err = .unreachable_ };
        defer req.deinit();
        req.sendBodiless() catch return .{ .err = .unreachable_ };
        var redirect_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| return switch (err) {
            error.TooManyHttpRedirects => .{ .err = .too_many_redirects },
            else => .{ .err = .unreachable_ },
        };
        // security-hardening (e) AC-e2: std auto-followed any redirect; `req.uri` is
        // the FINAL hop. Refuse if the chain downgraded the transport https->http
        // (the material downgrade -- serving content over plaintext after starting
        // secure). http->https / same-scheme (incl. cross-host) are unaffected.
        if (redirectDowngrades(schemeOf(self.url), req.uri.scheme)) return .{ .err = .insecure_redirect };
        const code: i32 = @intCast(@intFromEnum(response.head.status));
        if (code < 200 or code >= 300) return .{ .err = .http_status, .http_status = code };
        // Extract every needed field from `response.head` (a view into
        // `redirect_buf`) BEFORE touching the body reader below — reading the
        // body can reuse/overwrite that same buffer, so any head-field slice
        // must be consumed first, never interleaved with body reads (an earlier
        // draft read Content-Range AFTER the body reader and segfaulted).
        const content_length: ?u64 = response.head.content_length;
        const range_total: ?u64 = if (code == 206) parseContentRangeTotal(response.head.bytes) else null;
        var magic: [2]u8 = .{ 0, 0 };
        var transfer_buf: [4096]u8 = undefined;
        const body = response.reader(&transfer_buf);
        const magic_len = body.readSliceShort(&magic) catch 0;
        const is_gz = magic_len == 2 and magic[0] == 0x1f and magic[1] == 0x8b;
        // All the (bug-prone) classification now lives in the pure, unit-tested
        // decideProbe; probe() is just the I/O around it.
        const d = decideProbe(code, content_length, range_total, is_gz);
        return .{ .ok = true, .total = d.total, .range = d.range, .is_gz = d.is_gz, .length_known = d.length_known };
    }

    fn fetchInto(self: *RealTransport, dest: []u8, offset: u64) FetchOutcome {
        if (dest.len == 0) return .ok;
        const uri = std.Uri.parse(self.url) catch return .failed;
        var range_buf: [64]u8 = undefined;
        const range_val = std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ offset, offset + dest.len - 1 }) catch return .failed;
        const conn = self.dial(uri) orelse return .failed;
        var req = self.client.request(.GET, uri, .{
            .connection = conn,
            .redirect_behavior = .init(redirect_cap),
            .extra_headers = &.{.{ .name = "range", .value = range_val }},
        }) catch return .failed;
        defer req.deinit();
        req.sendBodiless() catch return .failed;
        var redirect_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return .failed;
        // security-hardening (e) AC-e2: refuse an https->http downgrade redirect.
        if (redirectDowngrades(schemeOf(self.url), req.uri.scheme)) return .failed;
        const code = @intFromEnum(response.head.status);
        if (code < 200 or code >= 300) return .failed;
        var transfer_buf: [64 * 1024]u8 = undefined;
        const body = response.reader(&transfer_buf);
        // security-hardening (e) AC-e3: a short body delivers fewer bytes than the
        // requested range -- report it (never zero-fill the undelivered tail).
        const got = body.readSliceShort(dest) catch return .failed;
        return if (got < dest.len) .short else .ok;
    }
};

/// The injected fake "server" for the gate (heap-owned by the Transport). Holds
/// the full resource bytes plus the streaming controls a NetFixture describes:
///   released    — withhold gate (AC13): only bytes in [0, released) are
///                 delivered right now; a demand beyond it waits (SCANNING).
///                 Borrowed from the test (outlives the job/doc); null = all.
///   drop_after  — post-open stream DROP (AC16): the body ends hard at this
///                 offset (the gzip damaged-EOF analog); null = full body.
pub const FakeServer = struct {
    body: []u8,
    released: ?*std.atomic.Value(u64) = null,
    drop_after: ?u64 = null,
    /// security-hardening (e) AC-e3 short-body seam: the server delivers body bytes
    /// only within [0, short_body_at); a range fetch beyond it is SHORT. null = full.
    short_body_at: ?u64 = null,
};

/// security-hardening (e) AC-e3: the outcome of a ranged fetch. `.ok` delivered
/// every requested byte; `.short` delivered FEWER (a short/zero body -- the
/// undelivered tail is neither fabricated nor marked present); `.failed` is a
/// transport error. Replaces the old `bool` so a short body is distinct from a
/// full one AND from a hard failure (the caller flags `.short` for the open-time
/// LS_NET_ERROR_SHORT_BODY classification and, either way, never marks the run
/// present).
pub const FetchOutcome = enum { ok, short, failed };

pub const Transport = union(enum) {
    fake: *FakeServer,
    real: *RealTransport,

    /// RANDOM fill: fetch `dest.len` bytes at `offset` (a ranged GET). A range
    /// server delivers any range in full (withhold/drop are SEQUENTIAL-only
    /// controls, never used with a range fixture).
    pub fn fetchInto(self: Transport, dest: []u8, offset: u64) FetchOutcome {
        switch (self) {
            .fake => |fs| {
                // security-hardening (e) AC-e3 short body: the fake advertises its
                // full length but delivers body bytes only within [0, deliver). A
                // request that reaches at/beyond `deliver` comes back SHORT -- the
                // undelivered tail is NEVER zero-filled (correcting the prior silent
                // zero-fill) and the caller never marks it present. deliver ==
                // body.len when short_body_at is null, so every other net test is
                // byte-unaffected.
                const deliver: u64 = if (fs.short_body_at) |s| @min(s, @as(u64, fs.body.len)) else fs.body.len;
                if (offset >= deliver) return .short; // zero body bytes here
                const avail = @min(@as(u64, dest.len), deliver - offset);
                @memcpy(dest[0..@intCast(avail)], fs.body[@intCast(offset)..][0..@intCast(avail)]);
                return if (avail < dest.len) .short else .ok;
            },
            .real => |rt| return rt.fetchInto(dest, offset),
        }
    }

    /// SEQUENTIAL fill (TD3): drain the body forward from `offset` (== the
    /// download high-water). Returns bytes copied + whether the stream ENDED.
    /// n==0 with eof==false means bytes are momentarily withheld (wait+retry).
    pub fn drainForward(self: Transport, dest: []u8, offset: u64) DrainResult {
        switch (self) {
            .fake => |fs| {
                const eff: u64 = if (fs.drop_after) |d| @min(d, fs.body.len) else fs.body.len;
                const released: u64 = if (fs.released) |g| @min(g.load(.acquire), eff) else eff;
                if (offset >= released) return .{ .n = 0, .eof = offset >= eff and released >= eff };
                const n: usize = @intCast(@min(@as(u64, dest.len), released - offset));
                @memcpy(dest[0..n], fs.body[@intCast(offset)..][0..n]);
                const at_eof = (offset + n >= eff) and (released >= eff);
                return .{ .n = n, .eof = at_eof };
            },
            .real => |rt| return rt.drainForward(dest, offset),
        }
    }

    pub fn deinit(self: Transport, gpa: std.mem.Allocator) void {
        switch (self) {
            .fake => |fs| {
                gpa.free(fs.body);
                gpa.destroy(fs);
            },
            .real => |rt| rt.deinit(),
        }
    }
};

// ---------------------------------------------------------------------------
// HttpRange: the network byte Source (peer to source.Gzip). Two fill
// strategies behind one Source variant (TD2): RANDOM (206 + Content-Range —
// ranged GET per chunk into a presized spool + `present[]` bitmap) and
// SEQUENTIAL (200 / no usable total — ONE forward-draining GET into a growing
// contiguous spool prefix, `seq_hw` high-water). Known length presizes the
// spool; UNKNOWN length grows it under a stable virtual reservation so
// outstanding spool slices never dangle across a growth (TD5).
// ---------------------------------------------------------------------------

/// The virtual address reservation for an UNKNOWN-length sequential spool:
/// generous (PROT_NONE anonymous — costs only address space, no commit), so the
/// mapping base is stable while the file grows into it via MAP_FIXED. A stream
/// that would exceed it terminates at the reservation (graceful; far beyond any
/// realistic viewport-driven drain).
const seq_reserve: u64 = 64 * 1024 * 1024 * 1024;

pub const HttpRange = struct {
    gpa: std.mem.Allocator,
    mutex: sysio.Mutex = .init,
    transport: Transport,
    spool_fd: ?posix.fd_t = null,
    // Known-length: the presized [0,total) mapping. Unknown-length: the stable
    // PROT_NONE reservation [0,reserve_len); only [0,mapped_len) is valid.
    spool: []align(std.heap.page_size_min) u8 = &.{},
    reserve_len: u64 = 0, // unknown-length: reserved virtual bytes (0 for known)
    mapped_len: u64 = 0, // unknown-length: ftruncated + mapped valid bytes
    total: u64 = 0, // known resource length (immutable); 0 until EOF if unknown
    total_known: bool = true, // false => unknown-length stream (firms at EOF)
    eof: std.atomic.Value(bool) = .init(false), // stream EOF discovered
    final_len: std.atomic.Value(u64) = .init(0), // the true total once EOF (unknown)
    head_len: u64 = 0, // bytes fetched at open (the head)
    bom_len: u64 = 0,
    physical_base: u64 = 0,
    // RANDOM fill (range server): per-chunk fetched + RAM-cache residency.
    present: []bool = &.{},
    resident: []bool = &.{},
    resident_order: std.ArrayList(usize) = .empty,
    resident_bytes: u64 = 0,
    cache_cap: u64 = cache_ceiling,
    // SEQUENTIAL fill: the contiguous downloaded prefix high-water.
    seq_hw: std.atomic.Value(u64) = .init(0),
    // Gzip compressed-provider: the contiguous compressed prefix fetched forward
    // for the inflater (random fill; sequential uses seq_hw).
    comp_fetched: u64 = 0,
    fetch_count: u64 = 0,
    spool_bytes: u64 = 0,
    range_mode: u8 = 1, // 1 random-access, 2 sequential
    shutdown: std.atomic.Value(bool) = .init(false),
    // RANDOM fill: a single transport-busy guard. Set (under the mutex) while a
    // thread holds the transport for a ranged GET with the mutex RELEASED, so
    // present-byte reads never block behind that GET (bug #1) and concurrent
    // fetchers serialize (one GET at a time — no double-fetch, no torn spool
    // region, no concurrent use of the shared transport client).
    fetching: bool = false,
    progress: ?Progress = null,
    /// security-hardening (e) AC-e3: set once any ranged fetch came back SHORT
    /// (server advertised its length but delivered fewer bytes / a zero body).
    /// buildNet reads it right after the head fetch to fail the OPEN with
    /// LS_NET_ERROR_SHORT_BODY; post-open it only records that the un-fetched
    /// tail stays not-present (no post-open error state -- root-planner boundary).
    short_fetch: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *HttpRange) void {
        self.mutex.lockUncancelable(sysio.io());
    }
    pub fn unlock(self: *HttpRange) void {
        self.mutex.unlock(sysio.io());
    }

    fn numChunks(total: u64) usize {
        if (total == 0) return 0;
        return @intCast((total + chunk_bytes - 1) / chunk_bytes);
    }

    fn chunkLen(self: *const HttpRange, c_idx: usize) u64 {
        const start = @as(u64, c_idx) * chunk_bytes;
        return @min(chunk_bytes, self.total - start);
    }

    /// Known-length: create the private spool (0600, unlinked), presize it to
    /// `total`, and mmap it read/write — the gzip spill-file idiom.
    fn openSpoolKnown(self: *HttpRange) bool {
        if (self.total == 0) return true; // nothing to map (empty resource)
        const fd = self.createSpoolFd() orelse return false;
        sysio.file(fd).setLength(sysio.io(), self.total) catch {
            sysio.close(fd);
            return false;
        };
        const m = posix.mmap(null, @intCast(self.total), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch {
            sysio.close(fd);
            return false;
        };
        self.spool_fd = fd;
        self.spool = m;
        self.mapped_len = self.total;
        return true;
    }

    /// Unknown-length: create the spool file and reserve a stable virtual
    /// address range (PROT_NONE anonymous). The file is ftruncated + MAP_FIXED
    /// into the reservation as the download grows (growSpoolLocked), so the base
    /// never moves and outstanding spool slices never dangle (TD5).
    fn openSpoolUnknown(self: *HttpRange) bool {
        const fd = self.createSpoolFd() orelse return false;
        const reservation = posix.mmap(null, @intCast(seq_reserve), .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch {
            sysio.close(fd);
            return false;
        };
        self.spool_fd = fd;
        self.spool = reservation;
        self.reserve_len = seq_reserve;
        self.mapped_len = 0;
        return true;
    }

    fn createSpoolFd(self: *HttpRange) ?posix.fd_t {
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/tmp/lesssheet-net-{x}-{x}.spool", .{ sysio.uniqueToken(), @intFromPtr(self) }) catch return null;
        const fd = posix.openatZ(posix.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600) catch return null;
        sysio.unlinkAbsolute(path) catch {
            sysio.close(fd);
            return null;
        };
        return fd;
    }

    /// Unknown-length: grow the mapped region to cover `need_end`, ftruncating
    /// the file and MAP_FIXED-mapping only the newly-grown region over the stable
    /// reservation (existing pages / outstanding slices are untouched).
    fn growSpoolLocked(self: *HttpRange, need_end: u64) bool {
        if (need_end <= self.mapped_len) return true;
        if (need_end > self.reserve_len) return false; // exceeds the reservation
        const new_mapped = std.mem.alignForward(u64, @min(need_end, self.reserve_len), chunk_bytes);
        const fd = self.spool_fd orelse return false;
        sysio.file(fd).setLength(sysio.io(), new_mapped) catch return false;
        const region_ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(self.spool.ptr + @as(usize, @intCast(self.mapped_len)));
        _ = posix.mmap(region_ptr, @intCast(new_mapped - self.mapped_len), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .FIXED = true }, fd, @intCast(self.mapped_len)) catch return false;
        self.mapped_len = new_mapped;
        return true;
    }

    fn markEofLocked(self: *HttpRange, at: u64) void {
        self.final_len.store(at, .release);
        self.eof.store(true, .release);
    }

    // --- RANDOM fill --------------------------------------------------------

    fn ensureChunkLocked(self: *HttpRange, c_idx: usize) void {
        if (!self.present[c_idx]) {
            const start = @as(u64, c_idx) * chunk_bytes;
            const len = self.chunkLen(c_idx);
            const dest = self.spool[@intCast(start)..@intCast(start + len)];
            switch (self.transport.fetchInto(dest, start)) {
                .ok => {},
                // security-hardening (e) AC-e3: leave the chunk not-present (no
                // zero-fill served) and flag a short body for the open-time check.
                .short => {
                    self.short_fetch.store(true, .release);
                    return;
                },
                .failed => return,
            }
            self.present[c_idx] = true;
            self.fetch_count += 1;
            self.spool_bytes += len;
            if (self.progress) |p| p.callback(p.ctx, self.spool_bytes, self.total);
        }
        self.markResidentLocked(c_idx);
    }

    /// Ensure chunks [first, last] are present, COALESCING each contiguous run of
    /// missing chunks into ONE ranged fetchInto (a single transport round-trip,
    /// so the O(head) open assembles in <=2 GETs, not one-per-256-KiB-chunk —
    /// bug #5), and releasing the document mutex ACROSS that network GET so
    /// concurrent present-byte reads / polls never block behind it (bug #1). The
    /// `fetching` guard serializes transport access while the mutex is down: a
    /// second thread that wants a byte covered by an in-flight GET waits WITHOUT
    /// the mutex (so unrelated present-byte reads still proceed) and re-checks
    /// when it frees — never a double-fetch, a torn spool region, or a concurrent
    /// transport call. Honors `shutdown`. Caller holds the mutex on entry+exit.
    fn ensureChunkRangeLocked(self: *HttpRange, first: usize, last: usize) void {
        var ci = first;
        while (ci <= last) {
            if (self.shutdown.load(.acquire)) return;
            if (self.present[ci]) {
                self.markResidentLocked(ci); // LRU touch (may evict), bytes retained
                ci += 1;
                continue;
            }
            if (self.fetching) {
                // Another thread holds the transport: wait mutex-free, re-check.
                self.unlock();
                sleepMs(2);
                self.lock();
                continue;
            }
            // Coalesce the contiguous missing run and fetch it in ONE GET. No
            // other thread can mutate present[]/fetching while we hold the mutex
            // here, so the run is stable until we publish it below.
            var run_end = ci + 1;
            while (run_end <= last and !self.present[run_end]) run_end += 1;
            const start = @as(u64, ci) * chunk_bytes;
            const stop = @min(self.total, @as(u64, run_end) * chunk_bytes);
            const dest = self.spool[@intCast(start)..@intCast(stop)];
            self.fetching = true;
            self.unlock();
            const outcome = self.transport.fetchInto(dest, start); // ~1 RTT, mutex down
            self.lock();
            self.fetching = false;
            switch (outcome) {
                .ok => {},
                // security-hardening (e) AC-e3: a short/failed GET leaves the whole
                // run not-present (ensureSlice then clamps to the present prefix, so
                // the frontier never advances over un-fetched bytes). `.short` also
                // flags the open-time short-body classification.
                .short => {
                    self.short_fetch.store(true, .release);
                    return;
                },
                .failed => return,
            }
            self.fetch_count += 1; // ROUND-TRIPS, not chunks
            var k = ci;
            while (k < run_end) : (k += 1) {
                if (!self.present[k]) {
                    self.present[k] = true;
                    self.spool_bytes += self.chunkLen(k);
                }
                self.markResidentLocked(k);
            }
            if (self.progress) |p| p.callback(p.ctx, self.spool_bytes, self.total);
            ci = run_end;
        }
    }

    fn markResidentLocked(self: *HttpRange, c_idx: usize) void {
        if (!self.resident[c_idx]) {
            self.resident[c_idx] = true;
            self.resident_order.append(self.gpa, c_idx) catch {};
            self.resident_bytes += self.chunkLen(c_idx);
        }
        self.evictLocked();
    }

    fn evictLocked(self: *HttpRange) void {
        var i: usize = 0;
        while (self.resident_bytes > self.cache_cap and i < self.resident_order.items.len) {
            const idx = self.resident_order.items[i];
            i += 1;
            if (self.resident[idx]) {
                self.resident[idx] = false;
                self.resident_bytes -= self.chunkLen(idx);
            }
        }
        // Compact the FIFO: drop the consumed prefix.
        if (i > 0) {
            const remaining = self.resident_order.items.len - i;
            std.mem.copyForwards(usize, self.resident_order.items[0..remaining], self.resident_order.items[i..]);
            self.resident_order.shrinkRetainingCapacity(remaining);
        }
    }

    pub fn setCacheCap(self: *HttpRange, n: u64) void {
        self.lock();
        defer self.unlock();
        self.cache_cap = n;
        self.evictLocked();
    }

    // --- SEQUENTIAL fill ----------------------------------------------------

    /// Drain ONE chunk forward from the download high-water. Returns true iff it
    /// advanced `seq_hw`; false when nothing is available yet (withheld) or at
    /// EOF (which it records). Caller holds the lock.
    fn drainOneChunkLocked(self: *HttpRange) bool {
        if (self.eof.load(.monotonic)) return false;
        const hw = self.seq_hw.load(.monotonic);
        const want_end = hw + chunk_bytes;
        var cap: u64 = undefined;
        if (self.total_known) {
            cap = self.total;
            if (hw >= cap) {
                self.markEofLocked(cap);
                return false;
            }
        } else {
            if (!self.growSpoolLocked(want_end)) {
                self.markEofLocked(hw);
                return false;
            }
            cap = self.mapped_len;
        }
        const dest_end = @min(cap, want_end);
        if (dest_end <= hw) return false;
        const dest = self.spool[@intCast(hw)..@intCast(dest_end)];
        const r = self.transport.drainForward(dest, hw);
        if (r.n == 0) {
            if (r.eof) self.markEofLocked(hw);
            return false;
        }
        const new_hw = hw + r.n;
        self.seq_hw.store(new_hw, .release);
        self.spool_bytes = new_hw;
        self.fetch_count += 1;
        if (r.eof) self.markEofLocked(new_hw);
        if (self.progress) |p| p.callback(p.ctx, new_hw, if (self.total_known) self.total else new_hw);
        return true;
    }

    /// Non-blocking forward drain to at least `target` bytes (or EOF / a
    /// withhold stall). Used for the open head and the gzip compressed provider.
    fn drainToLocked(self: *HttpRange, target: u64) void {
        while (self.seq_hw.load(.monotonic) < target) {
            if (self.eof.load(.monotonic) or self.shutdown.load(.acquire)) break;
            if (!self.drainOneChunkLocked()) break; // withheld or EOF
        }
    }

    /// Blocking forward drain to serve `internal` (AC13): waits (releasing the
    /// lock while sleeping, so poll / other lanes never block) until the byte at
    /// `internal` is downloaded, or the stream ends / shuts down. This lets a
    /// demand scan STAY SCANNING under withheld bytes and distinguishes a
    /// genuine EOF (empty return) from a momentary withhold (keeps waiting).
    fn ensureSliceSequentialLocked(self: *HttpRange, internal: u64, want: u64) []const u8 {
        while (self.seq_hw.load(.monotonic) <= internal) {
            if (self.eof.load(.monotonic) or self.shutdown.load(.acquire)) break;
            if (!self.drainOneChunkLocked()) {
                if (self.eof.load(.monotonic) or self.shutdown.load(.acquire)) break;
                self.unlock();
                sleepMs(2);
                self.lock();
            }
        }
        const hw = self.seq_hw.load(.monotonic);
        if (internal >= hw) return &.{};
        const end = @min(hw, internal + want);
        return self.spool[@intCast(internal)..@intCast(end)];
    }

    // --- Shared surface -----------------------------------------------------

    /// Ensure [internal, internal+want) is downloaded and return the contiguous
    /// spool slice actually available (short at EOF; empty past end). `internal`
    /// is a raw (pre-BOM) offset. Latency-unbounded on never-before-seen bytes by
    /// design (only ever reached from an async, cancellable scan/jump path).
    pub fn ensureSlice(self: *HttpRange, internal: u64, want: u64) []const u8 {
        self.lock();
        defer self.unlock();
        if (self.spool.len == 0) return &.{};
        if (self.range_mode == 2) return self.ensureSliceSequentialLocked(internal, want);
        // RANDOM fill: presized spool, contiguous missing chunks fetched in ONE
        // coalesced ranged GET (bug #5), with the mutex released across it (#1).
        if (internal >= self.total) return &.{};
        const end = @min(self.total, internal + want);
        if (end <= internal) return &.{};
        const first = internal / chunk_bytes;
        const last = (end - 1) / chunk_bytes;
        self.ensureChunkRangeLocked(@intCast(first), @intCast(last));
        // security-hardening (e) AC-e3: never serve un-fetched bytes. A short/
        // failed range leaves its chunks not-present, so clamp the returned slice
        // to the CONTIGUOUS PRESENT prefix from `internal` -- the un-fetched tail
        // is neither returned as (zero-fill) content nor allowed to advance the
        // frontier over it. When every requested chunk is present (the normal
        // case) this equals `end`, so behavior is byte-identical.
        var present_end: u64 = @as(u64, first) * chunk_bytes;
        var ci: usize = @intCast(first);
        while (ci <= @as(usize, @intCast(last)) and self.present[ci]) : (ci += 1) {
            present_end = @min(self.total, @as(u64, ci + 1) * chunk_bytes);
        }
        const served_end = @min(end, present_end);
        if (served_end <= internal) return &.{};
        return self.spool[@intCast(internal)..@intCast(served_end)];
    }

    /// gzip compressed provider (TD4): ensure the contiguous compressed prefix
    /// is fetched up to `want` and return the present high-water. The inflater
    /// consumes compressed bytes strictly forward; checkpoint replay reads only
    /// already-present bytes. For sequential fill this drains forward; for random
    /// fill it fetches the forward prefix (never re-fetching present chunks).
    pub fn ensureCompressed(self: *HttpRange, want: u64) u64 {
        self.lock();
        defer self.unlock();
        if (self.range_mode == 2) {
            self.drainToLocked(want);
            return self.seq_hw.load(.monotonic);
        }
        const end = @min(self.total, want);
        while (self.comp_fetched < end) {
            const ci = self.comp_fetched / chunk_bytes;
            if (!self.present[@intCast(ci)]) self.ensureChunkLocked(@intCast(ci));
            self.comp_fetched = @min(self.total, (ci + 1) * chunk_bytes);
        }
        return end;
    }

    pub fn byteAt(self: *HttpRange, internal: u64) ?u8 {
        const s = self.ensureSlice(internal, 1);
        if (s.len == 0) return null;
        return s[0];
    }

    pub fn openHead(self: *const HttpRange) []const u8 {
        if (self.spool.len == 0) return &.{};
        return self.spool[0..@intCast(self.head_len)];
    }

    /// The known resource total in RAW (physical) bytes: the Content-Length /
    /// Content-Range total when known, the received size once EOF fixed it for an
    /// unknown-length stream, or null while unknown. Lock-free.
    pub fn physicalTotal(self: *const HttpRange) ?u64 {
        if (self.total_known) return self.total;
        if (self.eof.load(.acquire)) return self.final_len.load(.acquire);
        return null;
    }

    /// The Source's current logical extent (== physical for plain CSV): the full
    /// total when known, the received size at EOF, else the fetched high-water.
    pub fn logicalLen(self: *const HttpRange) u64 {
        if (self.total_known) return self.total -| self.bom_len;
        if (self.eof.load(.acquire)) return self.final_len.load(.acquire) -| self.bom_len;
        return self.seq_hw.load(.acquire) -| self.bom_len;
    }

    /// The Source's true END, or null while unknown (mirrors gzip.terminalLogical
    /// — the reader's `.inflating` end vocabulary already covers null).
    pub fn knownEnd(self: *const HttpRange) ?u64 {
        const pt = self.physicalTotal() orelse return null;
        return pt -| self.bom_len;
    }

    pub fn deinit(self: *HttpRange) void {
        const span: u64 = if (self.reserve_len > 0) self.reserve_len else self.total;
        if (span > 0 and self.spool.len > 0) posix.munmap(self.spool.ptr[0..@intCast(span)]);
        if (self.spool_fd) |fd| sysio.close(fd);
        self.resident_order.deinit(self.gpa);
        if (self.present.len > 0) self.gpa.free(self.present);
        if (self.resident.len > 0) self.gpa.free(self.resident);
        self.transport.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Source builders (called by net.zig; return a source.Source + mapping).
// ---------------------------------------------------------------------------

pub const BuiltSource = struct {
    source: source_mod.Source,
    mapping: ?[]align(std.heap.page_size_min) const u8, // always null (the Source owns its spool)
    file_size: u64, // known resource total (PHYSICAL bytes); 0 for an unknown-length stream
    range_mode: u8,
    length_known: bool, // false => unknown-length stream (total firms at EOF)
    head_fetched: u64, // bytes actually fetched at open (honest DONE bytes_fetched)
};

/// The classified probe outcome the caller (net.zig) hands to `buildNet`.
pub const NetBuildOpts = struct {
    range: bool, // random fill (true) vs sequential fill (false)
    total_known: bool, // whether `total` is the known resource size
    total: u64, // known resource total (0 / don't-care when !total_known)
};

/// Build the streaming network Source for EVERY case (TD2/TD3/TD4): plain CSV or
/// `.csv.gz`, on a range or no-range server, of known or unknown length — always
/// demand-driven, never fully downloaded. Creates the spool, fetches only enough
/// head to classify (magic) + serve the first viewport, and (for a gzip resource)
/// composes the gzip Source over the growing compressed spool. Fails cleanly
/// (spool + transport freed) returning null.
pub fn buildNet(gpa: std.mem.Allocator, transport: Transport, opts: NetBuildOpts, progress: ?Progress, err_out: *api.NetStatus) ?BuiltSource {
    const hr = gpa.create(HttpRange) catch {
        transport.deinit(gpa);
        return null;
    };
    hr.* = .{
        .gpa = gpa,
        .transport = transport,
        .total = if (opts.total_known) opts.total else 0,
        .total_known = opts.total_known,
        .range_mode = if (opts.range) 1 else 2,
        .progress = progress,
    };
    if (opts.range) {
        const n = HttpRange.numChunks(hr.total);
        hr.present = gpa.alloc(bool, n) catch {
            gpa.destroy(hr);
            transport.deinit(gpa);
            return null;
        };
        @memset(hr.present, false);
        hr.resident = gpa.alloc(bool, n) catch {
            gpa.free(hr.present);
            gpa.destroy(hr);
            transport.deinit(gpa);
            return null;
        };
        @memset(hr.resident, false);
        if (!hr.openSpoolKnown()) {
            hr.deinit();
            return null;
        }
        _ = hr.ensureSlice(0, @min(chunk_bytes, hr.total)); // enough for the magic
    } else {
        const ok = if (opts.total_known) hr.openSpoolKnown() else hr.openSpoolUnknown();
        if (!ok) {
            hr.deinit();
            return null;
        }
        hr.lock();
        hr.drainToLocked(chunk_bytes); // enough for the magic
        hr.unlock();
    }

    // security-hardening (e) AC-e3: a SHORT / zero-length HEAD fetch is a
    // retryable short body -- fail the open with LS_NET_ERROR_SHORT_BODY rather
    // than serving zero-filled (un-fetched) bytes as document content. (A short
    // range fetched POST-open is handled by the present-prefix clamp in
    // ensureSlice; there is no post-open error state -- root-planner boundary.)
    if (hr.short_fetch.load(.acquire)) {
        err_out.* = .short_body;
        hr.deinit();
        return null;
    }

    // Classify from the fetched head: a `.csv.gz` magic (1f 8b) composes the
    // gzip Source over the (growing) compressed spool; plain CSV reads the spool
    // directly and fetches the full O(head) plain prefix now.
    const seen: u64 = if (opts.range) @min(hr.total, chunk_bytes) else hr.seq_hw.load(.monotonic);
    const is_gz = seen >= 2 and hr.spool.len >= 2 and hr.spool[0] == 0x1f and hr.spool[1] == 0x8b;
    if (is_gz) {
        const g = source_mod.gzipOverProvider(gpa, hr) orelse {
            hr.deinit();
            return null;
        };
        if (!source_mod.gzipUsablePtr(g)) {
            source_mod.gzipDeinit(g); // deinits g AND its provider (hr)
            return null;
        }
        return .{ .source = .{ .gzip = g }, .mapping = null, .file_size = hr.total, .range_mode = hr.range_mode, .length_known = opts.total_known, .head_fetched = hr.spool_bytes };
    }

    // Plain CSV: fetch the full O(head) prefix so the dialect/columns/first
    // viewport are servable at open.
    if (opts.range) {
        hr.head_len = @min(open_bytes, hr.total);
        _ = hr.ensureSlice(0, hr.head_len);
    } else {
        hr.lock();
        hr.drainToLocked(open_bytes);
        hr.head_len = @min(open_bytes, hr.seq_hw.load(.monotonic));
        hr.unlock();
    }
    return .{ .source = .{ .http_range = hr }, .mapping = null, .file_size = hr.total, .range_mode = hr.range_mode, .length_known = opts.total_known, .head_fetched = hr.spool_bytes };
}
