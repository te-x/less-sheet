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
const source_mod = @import("source.zig");

const c = std.c;
const posix = std.posix;

pub const chunk_bytes: u64 = 256 * 1024; // mirrors source.chunk_bytes
pub const cache_ceiling: u64 = 16 * 1024 * 1024; // 16 MiB resident RAM bound (AC15)
const open_bytes: u64 = api.open_head_max_bytes;
const redirect_cap: u32 = 3; // Zig std's small fixed redirect cap (AC12)

/// Process-wide sequence for unique download-spool filenames (the http_range
/// spool uses the HttpRange pointer; the one-shot download path has no such
/// handle, so it draws a monotonic id instead).
var dl_seq: std.atomic.Value(u64) = .init(0);

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
fn parseContentRangeTotal(head_bytes: []const u8) ?u64 {
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

/// The pure total/range/gzip decision from a SUCCESSFUL (2xx) probe's raw
/// signals — extracted from `probe()` so the exact logic behind two live bugs
/// is isolated and (once the streaming redesign adds a seam) unit-testable
/// without a real HTTP server. `status` is 2xx; `content_length` is the response's Content-Length
/// (the whole resource for 200, only the PARTIAL slice for 206);
/// `content_range_total` is `parseContentRangeTotal` of the head (null unless a
/// usable `Content-Range: …/total` was present); `is_gz` is the leading-magic
/// (1f 8b) verdict on the body head. The two bugs this encodes:
///   1. total: a 206's Content-Length is the partial slice, NOT the resource —
///      the total must come from Content-Range (else a >4 MiB file truncated to
///      the 4 MiB probe range); and when no usable Content-Range total exists,
///      fall back exactly as if ranges were unsupported (ARCH probe/fallback §3).
///   2. is_gz: a gzip resource must download-and-decompress even on a range
///      host (range mode serves raw compressed bytes -> garbage cells), so a
///      gzip verdict forces `range = false` (the caller routes that to
///      buildDownloadAll, which wraps the spool in a gzip Source). NOTE: this
///      whole-file download for gzip is the exact behavior the never-full-
///      download streaming redesign (ARCH backlog) will replace.
fn decideProbe(status: i32, content_length: u64, content_range_total: ?u64, is_gz: bool) Probe {
    const partial = status == 206;
    if (!partial) return .{ .ok = true, .total = content_length, .range = false, .is_gz = is_gz };
    const total = content_range_total orelse 0;
    if (total == 0) return .{ .ok = true, .total = content_length, .range = false, .is_gz = is_gz };
    // A gzip resource is never random-access over the wire — force the
    // download-and-decompress path regardless of range support.
    return .{ .ok = true, .total = total, .range = !is_gz, .is_gz = is_gz };
}

/// One real host connection for the whole job's lifetime: ONE `std.http.Client`
/// (and its `Io.Threaded` executor), constructed once and reused across the
/// probe AND every subsequent ranged fetch — `std.http.Client`'s connection
/// pool then keeps the underlying TCP/TLS connection alive across requests to
/// the same host instead of a fresh handshake per 256 KiB chunk (round-2 review
/// finding 5). Heap-allocated so its address (captured by `Io.Threaded.io()`)
/// stays stable for the transport's whole lifetime.
pub const RealTransport = struct {
    gpa: std.mem.Allocator,
    url: []u8, // owned NUL-free copy
    threaded: std.Io.Threaded,
    client: std.http.Client,

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
        self.client.deinit();
        self.threaded.deinit();
        self.gpa.free(self.url);
        self.gpa.destroy(self);
    }

    /// One ranged GET for the head bound. 206 + Content-Range total => random
    /// access; 200 / no usable length => sequential fallback. Also reads the
    /// first 2 body bytes (already in flight on this same request/response —
    /// no extra round-trip) to detect the `.csv.gz` magic, so the real
    /// transport picks buildRandom/buildDownloadAll exactly like the fake
    /// transport does in runFake — without this, a range-supporting host
    /// serving a gzip resource took the raw random-access path and the CSV
    /// reader parsed undecompressed gzip bytes as plain text (garbage cells).
    pub fn probe(self: *RealTransport) Probe {
        const uri = std.Uri.parse(self.url) catch return .{ .err = .invalid_argument };
        var range_buf: [64]u8 = undefined;
        const range_val = std.fmt.bufPrint(&range_buf, "bytes=0-{d}", .{open_bytes - 1}) catch return .{ .err = .io };
        var req = self.client.request(.GET, uri, .{
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
        const code: i32 = @intCast(@intFromEnum(response.head.status));
        if (code < 200 or code >= 300) return .{ .err = .http_status, .http_status = code };
        // Extract every needed field from `response.head` (a view into
        // `redirect_buf`) BEFORE touching the body reader below — reading the
        // body can reuse/overwrite that same buffer, so any head-field slice
        // must be consumed first, never interleaved with body reads (an earlier
        // draft read Content-Range AFTER the body reader and segfaulted).
        const content_length = response.head.content_length orelse 0;
        const range_total: ?u64 = if (code == 206) parseContentRangeTotal(response.head.bytes) else null;
        var magic: [2]u8 = .{ 0, 0 };
        var transfer_buf: [4096]u8 = undefined;
        const body = response.reader(&transfer_buf);
        const magic_len = body.readSliceShort(&magic) catch 0;
        const is_gz = magic_len == 2 and magic[0] == 0x1f and magic[1] == 0x8b;
        // All the (bug-prone) classification now lives in the pure, unit-tested
        // decideProbe; probe() is just the I/O around it.
        return decideProbe(code, content_length, range_total, is_gz);
    }

    fn fetchInto(self: *RealTransport, dest: []u8, offset: u64) bool {
        if (dest.len == 0) return true;
        const uri = std.Uri.parse(self.url) catch return false;
        var range_buf: [64]u8 = undefined;
        const range_val = std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ offset, offset + dest.len - 1 }) catch return false;
        var req = self.client.request(.GET, uri, .{
            .redirect_behavior = .init(redirect_cap),
            .extra_headers = &.{.{ .name = "range", .value = range_val }},
        }) catch return false;
        defer req.deinit();
        req.sendBodiless() catch return false;
        var redirect_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return false;
        const code = @intFromEnum(response.head.status);
        if (code < 200 or code >= 300) return false;
        var transfer_buf: [64 * 1024]u8 = undefined;
        const body = response.reader(&transfer_buf);
        body.readSliceAll(dest) catch |err| switch (err) {
            error.EndOfStream => {}, // server returned a short body; keep what we got
            else => return false,
        };
        return true;
    }
};

pub const Transport = union(enum) {
    fake: []u8, // owned copy of the full resource bytes
    real: *RealTransport,

    /// Fetch `dest.len` bytes at `offset` into `dest`. Returns false on failure.
    pub fn fetchInto(self: Transport, dest: []u8, offset: u64) bool {
        switch (self) {
            .fake => |body| {
                if (offset >= body.len) {
                    @memset(dest, 0);
                    return true;
                }
                const avail = @min(@as(u64, dest.len), body.len - offset);
                @memcpy(dest[0..@intCast(avail)], body[@intCast(offset)..][0..@intCast(avail)]);
                if (avail < dest.len) @memset(dest[@intCast(avail)..], 0);
                return true;
            },
            .real => |rt| return rt.fetchInto(dest, offset),
        }
    }

    pub fn deinit(self: Transport, gpa: std.mem.Allocator) void {
        switch (self) {
            .fake => |body| gpa.free(body),
            .real => |rt| rt.deinit(),
        }
    }
};

// ---------------------------------------------------------------------------
// HttpRange: the random-access Source state (peer to source.Gzip).
// ---------------------------------------------------------------------------

pub const HttpRange = struct {
    gpa: std.mem.Allocator,
    mutex: c.pthread_mutex_t = .{},
    transport: Transport,
    spool_fd: ?posix.fd_t = null,
    spool: []align(std.heap.page_size_min) u8 = &.{},
    total: u64 = 0, // raw remote resource length
    head_len: u64 = 0, // bytes fetched at open (the head)
    bom_len: u64 = 0,
    physical_base: u64 = 0,
    present: []bool = &.{}, // per-chunk: fetched into the spool
    resident: []bool = &.{}, // per-chunk: counted in the RAM cache
    resident_order: std.ArrayList(usize) = .empty,
    resident_bytes: u64 = 0,
    cache_cap: u64 = cache_ceiling,
    fetch_count: u64 = 0,
    spool_bytes: u64 = 0,
    range_mode: u8 = 1, // 1 random-access, 2 sequential-fallback
    shutdown: std.atomic.Value(bool) = .init(false),
    progress: ?Progress = null,

    pub fn lock(self: *HttpRange) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }
    pub fn unlock(self: *HttpRange) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn numChunks(total: u64) usize {
        if (total == 0) return 0;
        return @intCast((total + chunk_bytes - 1) / chunk_bytes);
    }

    fn chunkLen(self: *const HttpRange, c_idx: usize) u64 {
        const start = @as(u64, c_idx) * chunk_bytes;
        return @min(chunk_bytes, self.total - start);
    }

    /// Create the private spool file (0600, unlinked immediately, sized to
    /// `total`) and mmap it read/write, mirroring the gzip spill-file idiom.
    fn openSpool(self: *HttpRange) bool {
        if (self.total == 0) return true; // nothing to map
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/tmp/lesssheet-net-{d}-{x}.spool", .{ c.getpid(), @intFromPtr(self) }) catch return false;
        const fd = posix.openatZ(posix.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600) catch return false;
        if (c.unlink(path.ptr) != 0) {
            _ = c.close(fd);
            return false;
        }
        if (c.ftruncate(fd, @intCast(self.total)) != 0) {
            _ = c.close(fd);
            return false;
        }
        const m = posix.mmap(null, @intCast(self.total), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch {
            _ = c.close(fd);
            return false;
        };
        self.spool_fd = fd;
        self.spool = m;
        return true;
    }

    fn ensureChunkLocked(self: *HttpRange, c_idx: usize) void {
        if (!self.present[c_idx]) {
            const start = @as(u64, c_idx) * chunk_bytes;
            const len = self.chunkLen(c_idx);
            const dest = self.spool[@intCast(start)..@intCast(start + len)];
            if (!self.transport.fetchInto(dest, start)) return;
            self.present[c_idx] = true;
            self.fetch_count += 1;
            self.spool_bytes += len;
            if (self.progress) |p| p.callback(p.ctx, self.spool_bytes, self.total);
        }
        self.markResidentLocked(c_idx);
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

    pub fn logicalLen(self: *const HttpRange) u64 {
        return self.total - self.bom_len;
    }

    /// Ensure [internal, internal+want) is fetched into the spool and return the
    /// contiguous spool slice actually available. `internal` is a raw (pre-BOM)
    /// offset into the resource. Latency-unbounded on a never-before-seen range
    /// by design (only ever reached from an async, cancellable scan/jump path).
    pub fn ensureSlice(self: *HttpRange, internal: u64, want: u64) []const u8 {
        self.lock();
        defer self.unlock();
        if (internal >= self.total or self.spool.len == 0) return &.{};
        const end = @min(self.total, internal + want);
        if (end <= internal) return &.{};
        var ci = internal / chunk_bytes;
        const last = (end - 1) / chunk_bytes;
        while (ci <= last) : (ci += 1) self.ensureChunkLocked(ci);
        return self.spool[@intCast(internal)..@intCast(end)];
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

    pub fn deinit(self: *HttpRange) void {
        if (self.spool.len > 0) posix.munmap(self.spool);
        if (self.spool_fd) |fd| _ = c.close(fd);
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
    mapping: ?[]align(std.heap.page_size_min) const u8, // owned by the doc (munmap on close); null for http_range
    file_size: u64,
    range_mode: u8,
};

/// Build a true random-access `http_range` Source: create the spool sized to
/// `total`, fetch the head, and hand back the Source. Fails cleanly (deinit +
/// transport freed) returning null. `progress`, when given, is invoked with
/// (bytes fetched so far, total) on every actual network fetch (never a cache
/// hit) — for the whole document's later lifetime too, since it is stored on
/// the built `HttpRange`.
pub fn buildRandom(gpa: std.mem.Allocator, transport: Transport, total: u64, progress: ?Progress) ?BuiltSource {
    const hr = gpa.create(HttpRange) catch {
        transport.deinit(gpa);
        return null;
    };
    hr.* = .{ .gpa = gpa, .transport = transport, .total = total, .range_mode = 1, .progress = progress };
    const n = HttpRange.numChunks(total);
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
    if (!hr.openSpool()) {
        hr.deinit();
        return null;
    }
    hr.head_len = @min(open_bytes, total);
    _ = hr.ensureSlice(0, hr.head_len);
    return .{ .source = .{ .http_range = hr }, .mapping = null, .file_size = total, .range_mode = 1 };
}

/// Download the whole resource sequentially into a private spool, mmap it, and
/// build an mmap Source (or a gzip Source when the magic bytes say .csv.gz) —
/// the ARCH "sequential fallback / opened as a local document" path. `transport`
/// is consumed (freed) here; the spool mapping is handed to the doc. `progress`
/// (see buildRandom) is invoked after every chunk actually fetched.
pub fn buildDownloadAll(gpa: std.mem.Allocator, transport: Transport, total: u64, progress: ?Progress) ?BuiltSource {
    defer transport.deinit(gpa);
    if (total == 0) {
        return .{ .source = .{ .mmap = .{ .bytes = &.{} } }, .mapping = null, .file_size = 0, .range_mode = 2 };
    }
    const seq = dl_seq.fetchAdd(1, .monotonic);
    var path_buf: [160]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/lesssheet-net-{d}-{x}.dl", .{ c.getpid(), seq }) catch return null;
    const fd = posix.openatZ(posix.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600) catch return null;
    if (c.unlink(path.ptr) != 0) {
        _ = c.close(fd);
        return null;
    }
    if (c.ftruncate(fd, @intCast(total)) != 0) {
        _ = c.close(fd);
        return null;
    }
    const rw = posix.mmap(null, @intCast(total), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch {
        _ = c.close(fd);
        return null;
    };
    // Sequential download in chunks.
    var off: u64 = 0;
    while (off < total) : (off += chunk_bytes) {
        const len = @min(chunk_bytes, total - off);
        if (!transport.fetchInto(rw[@intCast(off)..@intCast(off + len)], off)) {
            posix.munmap(rw);
            _ = c.close(fd);
            return null;
        }
        if (progress) |p| p.callback(p.ctx, off + len, total);
    }
    _ = c.close(fd); // the mapping keeps the pages; the file is already unlinked
    const mapping: []align(std.heap.page_size_min) const u8 = rw;
    const is_gz = total >= 2 and rw[0] == 0x1f and rw[1] == 0x8b;
    if (is_gz) {
        const src = source_mod.sourceFromMappingAlloc(gpa, mapping, .gzip) catch {
            posix.munmap(mapping);
            return null;
        };
        if (!src.gzipUsable()) {
            var s = src;
            source_mod.sourceDeinit(&s);
            posix.munmap(mapping);
            return null;
        }
        return .{ .source = src, .mapping = mapping, .file_size = total, .range_mode = 2 };
    }
    return .{ .source = .{ .mmap = .{ .bytes = mapping } }, .mapping = mapping, .file_size = total, .range_mode = 2 };
}
