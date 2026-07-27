//! Logical byte sources.  The mmap variant stays a direct immutable span;
//! gzip owns bounded streaming inflater sessions and restart checkpoints.

const std = @import("std");
const api = @import("api");

const flate = std.compress.flate;
const Reader = std.Io.Reader;
const Decompress = flate.Decompress;
const posix = std.posix;
const sysio = @import("sysio.zig");

const net_source = @import("net_source.zig");
/// The network `http_range` Source state (ARCH-network-source) — a genuinely
/// random-access byte provider peer to mmap/gzip, defined in net_source.zig.
pub const HttpRange = net_source.HttpRange;

pub const chunk_bytes: usize = 256 * 1024;
pub const checkpoint_interval: u64 = 32 * 1024 * 1024;
const open_bytes: usize = @intCast(api.open_head_max_bytes);

pub const Mmap = struct { bytes: []const u8, physical_base: u64 = 0 };
pub const SourceKind = enum { mmap, gzip };

const Terminal = enum { inflating, clean, damaged, budget };
const PhysicalMark = struct { logical_end: u64, physical_end: u64 };
const checkpoint_ram_budget: usize = 4 * 1024 * 1024;
const max_checkpoint_entries: usize = 64 * 1024;

const Session = struct {
    input: Reader,
    history: [flate.max_window_len]u8,
    dec: Decompress,
    logical: u64,
    member_count: u32,
    terminal: Terminal,

    fn init(self: *Session, mapping: []const u8, physical_end: usize) void {
        @memset(&self.history, 0);
        self.input = .fixed(mapping);
        self.input.end = @min(mapping.len, physical_end);
        self.logical = 0;
        self.member_count = 0;
        self.terminal = .inflating;
        self.dec = Decompress.init(&self.input, .gzip, &self.history);
    }

    fn repair(self: *Session) void {
        self.dec.input = &self.input;
        self.dec.reader.buffer = &self.history;
    }
};

const CheckpointEntry = struct {
    logical: u64,
    physical: u64,
    file_offset: ?u64,
    hot: ?*Checkpoint,
};

const Checkpoint = struct {
    logical: u64,
    input: Reader,
    history: [flate.max_window_len]u8,
    dec: Decompress,
    member_count: u32,
    terminal: Terminal,

    fn capture(self: *Checkpoint, s: *const Session) void {
        self.logical = s.logical;
        self.input = s.input;
        self.history = s.history;
        self.dec = s.dec;
        self.member_count = s.member_count;
        self.terminal = s.terminal;
        self.dec.input = &self.input;
        self.dec.reader.buffer = &self.history;
    }

    fn restore(self: *const Checkpoint, s: *Session) void {
        s.input = self.input;
        s.history = self.history;
        s.dec = self.dec;
        s.logical = self.logical;
        s.member_count = self.member_count;
        s.terminal = self.terminal;
        s.repair();
    }
};

pub const Gzip = struct {
    gpa: std.mem.Allocator,
    mapping: []const u8,
    /// never-full-download-streaming (TD4): the compressed-byte provider for a
    /// NETWORK gzip. When set, `mapping` is the http_range spool's stable base;
    /// the inflater fetches compressed bytes on demand via `provider` and its
    /// physical end comes from the provider (present high-water = a resumable
    /// budget stop; stream EOF = the clean/damaged terminal), NOT `mapping.len`.
    /// null for a LOCAL gzip (mapping.len IS the end — byte-identical).
    provider: ?*net_source.HttpRange = null,
    mutex: sysio.Mutex = .init,
    cond: sysio.Condition = .init,
    forward: *Session,
    replay: *Session,
    replay2: *Session,
    checkpoints: std.ArrayList(CheckpointEntry) = .empty,
    spill_snapshot: *Checkpoint,
    spill_snapshot2: *Checkpoint,
    hot_checkpoint_bytes: usize = 0,
    head: std.ArrayList(u8) = .empty,
    lane_buf: [3][chunk_bytes]u8 = undefined,
    op_start: [3]u64 = @splat(0),
    op_len: [3]usize = @splat(0),
    op_replay: [3]bool = @splat(false),
    op_physical: [3]u64 = @splat(0),
    lane_busy: [3]bool = @splat(false),
    lane_physical_budget: [3]?u64 = @splat(null),
    forward_logical: std.atomic.Value(u64) = .init(0),
    forward_physical: std.atomic.Value(u64) = .init(0),
    terminal_end: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    terminal_kind: std.atomic.Value(u8) = .init(0), // 0 unknown, 1 clean, 2 damaged
    bom_len: u64 = 0,
    shutdown: std.atomic.Value(bool) = .init(false),
    opening: bool = true,
    force_chunk: std.atomic.Value(u64) = .init(0),
    replay_landed: bool = false,
    replay_restored: u64 = 0,
    replay_inflated: u64 = 0,
    open_physical: u64 = 0,
    open_inflated: u64 = 0,
    /// gz-filter-stream regression seams (api.gzInflatedBytes / api.gzInflateOps):
    /// cumulative inflated OUTPUT bytes AND inflate OPERATIONS (produce calls)
    /// since the last reset. A trailing FILTER/SEARCH scan that STREAMS forward
    /// inflates O(logical) bytes in O(logical/chunk) ops; the shipped trailing
    /// scan cannot serve a byte behind the forward session's over-produced
    /// position, so it LIVELOCKS -- spinning 0-byte produce calls forever (ops
    /// grow UNBOUNDED while bytes plateau). ops is thus the deterministic
    /// regression signal. Reset via root.gzInflateWorkReset.
    inflated_total: std.atomic.Value(u64) = .init(0),
    inflate_ops: std.atomic.Value(u64) = .init(0),
    spill_fd: ?posix.fd_t = null,
    spill_bytes: u64 = 0,
    spill_ops: u64 = 0,
    spill_fail_after: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    head_marks: [open_bytes / chunk_bytes + 1]PhysicalMark = undefined,
    head_mark_count: usize = 0,

    pub fn lock(self: *Gzip) void {
        self.mutex.lockUncancelable(sysio.io());
    }
    pub fn unlock(self: *Gzip) void {
        self.mutex.unlock(sysio.io());
    }

    fn init(gpa: std.mem.Allocator, mapping: []const u8) !*Gzip {
        const self = try gpa.create(Gzip);
        errdefer gpa.destroy(self);
        const f = try gpa.create(Session);
        errdefer gpa.destroy(f);
        const r = try gpa.create(Session);
        errdefer gpa.destroy(r);
        const r2 = try gpa.create(Session);
        errdefer gpa.destroy(r2);
        const spill_snapshot = try gpa.create(Checkpoint);
        errdefer gpa.destroy(spill_snapshot);
        const spill_snapshot2 = try gpa.create(Checkpoint);
        errdefer gpa.destroy(spill_snapshot2);
        self.* = .{ .gpa = gpa, .mapping = mapping, .forward = f, .replay = r, .replay2 = r2, .spill_snapshot = spill_snapshot, .spill_snapshot2 = spill_snapshot2 };
        f.init(mapping, @min(mapping.len, open_bytes));
        r.init(mapping, @min(mapping.len, open_bytes));
        r2.init(mapping, @min(mapping.len, open_bytes));
        try self.head.ensureTotalCapacity(gpa, open_bytes);
        try self.inflateOpenHead();
        return self;
    }

    /// never-full-download-streaming (TD4): build a gzip Source that inflates the
    /// COMPRESSED bytes served on demand by `provider` (an http_range spool). The
    /// spool's stable base is the `mapping`; the physical end comes from the
    /// provider, so `mapping.len` (a presized total, or the huge unknown-length
    /// reservation) is NOT the terminal. `provider` is owned by the returned Gzip
    /// on success (deinit frees it); on any failure the CALLER frees `provider`.
    fn initProvider(gpa: std.mem.Allocator, provider: *net_source.HttpRange) !*Gzip {
        const self = try gpa.create(Gzip);
        errdefer gpa.destroy(self);
        const f = try gpa.create(Session);
        errdefer gpa.destroy(f);
        const r = try gpa.create(Session);
        errdefer gpa.destroy(r);
        const r2 = try gpa.create(Session);
        errdefer gpa.destroy(r2);
        const spill_snapshot = try gpa.create(Checkpoint);
        errdefer gpa.destroy(spill_snapshot);
        const spill_snapshot2 = try gpa.create(Checkpoint);
        errdefer gpa.destroy(spill_snapshot2);
        const mapping = provider.spool;
        self.* = .{ .gpa = gpa, .mapping = mapping, .provider = provider, .forward = f, .replay = r, .replay2 = r2, .spill_snapshot = spill_snapshot, .spill_snapshot2 = spill_snapshot2 };
        // input.end starts at 0; `produce` refreshes it from the provider's
        // present compressed high-water before every read (never past fetched).
        f.init(mapping, 0);
        r.init(mapping, 0);
        r2.init(mapping, 0);
        try self.head.ensureTotalCapacity(gpa, open_bytes);
        try self.inflateOpenHead();
        return self;
    }

    fn deinit(self: *Gzip) void {
        for (self.checkpoints.items) |entry| if (entry.hot) |cp| self.gpa.destroy(cp);
        self.checkpoints.deinit(self.gpa);
        self.head.deinit(self.gpa);
        if (self.spill_fd) |fd| sysio.close(fd);
        self.gpa.destroy(self.forward);
        self.gpa.destroy(self.replay);
        self.gpa.destroy(self.replay2);
        self.gpa.destroy(self.spill_snapshot);
        self.gpa.destroy(self.spill_snapshot2);
        // std.Io.Mutex/Condition need no explicit destroy (unlike pthread_*_destroy).
        if (self.provider) |hr| hr.deinit(); // network gzip owns its compressed spool
        self.gpa.destroy(self);
    }

    /// The physical (compressed) END of the stream: the provider's known total
    /// (or `maxInt` while an unknown-length stream has not hit EOF) for a network
    /// gzip; `mapping.len` for a local one. Replaces `mapping.len`-as-end so a
    /// growing/on-demand spool is never mistaken for the terminal (TD4).
    fn physicalLen(self: *const Gzip) u64 {
        if (self.provider) |hr| return hr.physicalTotal() orelse std.math.maxInt(u64);
        return self.mapping.len;
    }

    fn physical(s: *const Session) u64 {
        return s.input.seek;
    }

    fn nextMember(self: *Gzip, s: *Session) bool {
        s.member_count += 1;
        const at = s.input.seek;
        const phys_len = self.physicalLen();
        if (at == phys_len) {
            s.terminal = .clean;
            return false;
        }
        if (at + 2 > s.input.end) {
            s.terminal = if (s.input.end < phys_len) .budget else .damaged;
            return false;
        }
        if (self.mapping[at] != 0x1f or self.mapping[at + 1] != 0x8b) {
            s.terminal = .damaged;
            return false;
        }
        s.dec = Decompress.init(&s.input, .gzip, &s.history);
        return true;
    }

    /// Produce at most `out.len` bytes.  A physical artificial end is a
    /// resumable budget stop; a real decoder/end-of-input failure is a stable
    /// damaged end once useful bytes exist.
    fn produce(self: *Gzip, s: *Session, out: []u8) usize {
        _ = self.inflate_ops.fetchAdd(1, .monotonic); // gz-filter-stream: count EVERY inflate op (0-byte spins included)
        if (out.len == 0 or self.shutdown.load(.acquire)) return 0;
        // Network gzip (TD4): fetch compressed bytes ahead of the read cursor and
        // lift a resumable budget stop when more arrived. The inflater consumes
        // compressed bytes strictly forward; checkpoint replay only reads already-
        // present bytes, so a single forward fetch high-water suffices.
        if (self.provider) |hr| {
            const fetched = hr.ensureCompressed(s.input.seek + chunk_bytes);
            const new_end: usize = @intCast(@min(fetched, self.mapping.len));
            if (new_end > s.input.end) {
                s.input.end = new_end;
                if (s.terminal == .budget) {
                    s.dec.err = null;
                    s.terminal = .inflating;
                }
            }
        }
        var written: usize = 0;
        while (written < out.len and s.terminal == .inflating) {
            const n = s.dec.reader.readSliceShort(out[written..]) catch {
                // The indirect inflater commits bytes to its history reader
                // before reporting a footer/structural error. Preserve that
                // safely decoded prefix instead of losing it with the error.
                const pending = s.dec.reader.buffer[s.dec.reader.seek..s.dec.reader.end];
                const take = @min(pending.len, out.len - written);
                if (take > 0) {
                    @memcpy(out[written..][0..take], pending[0..take]);
                    s.dec.reader.seek += take;
                    s.logical += take;
                    written += take;
                }
                if (s.input.end < self.physicalLen() and s.input.seek >= s.input.end) {
                    s.terminal = .budget;
                } else {
                    s.terminal = .damaged;
                }
                break;
            };
            if (n > 0) {
                written += n;
                s.logical += n;
                if (s == self.forward) self.forward_logical.store(s.logical, .release);
                continue;
            }
            if (!self.nextMember(s)) break;
        }
        if (s == self.forward) {
            self.forward_logical.store(s.logical, .release);
            self.forward_physical.store(s.input.seek, .release);
        }
        // A retained trailing-scan session may reach the real end before the
        // shared forward session.  Real EOF is source-global knowledge; only
        // an artificial physical budget stop remains lane-local.
        switch (s.terminal) {
            .clean => {
                self.terminal_kind.store(1, .release);
                self.terminal_end.store(s.logical, .release);
            },
            .damaged => {
                self.terminal_kind.store(2, .release);
                self.terminal_end.store(s.logical, .release);
            },
            else => {},
        }
        _ = self.inflated_total.fetchAdd(@intCast(written), .monotonic); // gz-filter-stream: inflated output bytes
        return written;
    }

    fn inflateOpenHead(self: *Gzip) !void {
        while (self.head.items.len < open_bytes and self.forward.terminal == .inflating) {
            const old = self.head.items.len;
            const want = @min(chunk_bytes, open_bytes - old);
            try self.head.resize(self.gpa, old + want);
            const n = self.produce(self.forward, self.head.items[old .. old + want]);
            self.head.shrinkRetainingCapacity(old + n);
            if (n > 0 and self.head_mark_count < self.head_marks.len) {
                self.head_marks[self.head_mark_count] = .{ .logical_end = self.forward.logical, .physical_end = self.forward.input.seek };
                self.head_mark_count += 1;
            }
            if (n == 0) break;
        }
        self.open_physical = @min(self.forward.input.seek, api.open_head_max_bytes);
        self.open_inflated = self.head.items.len;
    }

    fn finishOpen(self: *Gzip) void {
        self.lock();
        defer self.unlock();
        self.opening = false;
        // Every forward session starts with the independent physical-open
        // fence, even when the inflated-output fence is reached first.  Once
        // all open-time parsing is complete the physical fence must always be
        // lifted; otherwise a high-expansion member eventually mistakes that
        // artificial end for a damaged/terminal gzip end. For a NETWORK gzip the
        // physical fence is the fetched compressed high-water (refreshed every
        // `produce` from the provider) — never `mapping.len` (the presized total
        // or the huge unknown-length reservation), which would read unfetched
        // pages — so leave `input.end` at the fetched edge here (TD4).
        if (self.provider == null) self.forward.input.end = self.mapping.len;
        if (self.forward.terminal == .budget) {
            self.forward.dec.err = null;
            self.forward.terminal = .inflating;
        }
    }

    pub fn openUsable(self: *const Gzip) bool {
        return self.head.items.len > 0 or self.forward.member_count > 0;
    }

    pub fn terminalLogical(self: *const Gzip) ?u64 {
        const end = self.terminal_end.load(.acquire);
        return if (end == std.math.maxInt(u64)) null else end -| self.bom_len;
    }

    fn createSpill(self: *Gzip) void {
        if (self.spill_fd != null or self.spill_fail_after.load(.acquire) == 0) return;
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/tmp/lesssheet-gz-{x}-{x}.ckpt", .{ sysio.uniqueToken(), @intFromPtr(self) }) catch return;
        const fd = posix.openatZ(posix.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600) catch return;
        sysio.unlinkAbsolute(path) catch {
            sysio.close(fd);
            return;
        };
        self.spill_fd = fd;
    }

    fn persistCheckpoint(self: *Gzip, cp: *const Checkpoint) ?u64 {
        if (self.spill_ops >= self.spill_fail_after.load(.acquire)) return null;
        self.createSpill();
        const fd = self.spill_fd orelse return null;
        const bytes = std.mem.asBytes(cp);
        const start = self.spill_bytes;
        sysio.file(fd).writePositionalAll(sysio.io(), bytes, start) catch return null;
        self.spill_bytes += bytes.len;
        self.spill_ops += 1;
        return start;
    }

    fn loadCheckpoint(self: *Gzip, entry: CheckpointEntry, lane: usize) ?*Checkpoint {
        if (entry.hot) |cp| return cp;
        const offset = entry.file_offset orelse return null;
        const fd = self.spill_fd orelse return null;
        const snapshot = if (lane == 2) self.spill_snapshot2 else self.spill_snapshot;
        const bytes = std.mem.asBytes(snapshot);
        const got = sysio.file(fd).readPositionalAll(sysio.io(), bytes, offset) catch return null;
        if (got != bytes.len) return null;
        snapshot.dec.input = &snapshot.input;
        snapshot.dec.reader.buffer = &snapshot.history;
        return snapshot;
    }

    fn checkpointIfDue(self: *Gzip, s: *Session) void {
        if (s != self.forward) return;
        self.lock();
        const expected = (@as(u64, self.checkpoints.items.len) + 1) * checkpoint_interval;
        self.unlock();
        if (s.logical != expected) return;
        const cp = self.gpa.create(Checkpoint) catch {
            s.terminal = .damaged;
            return;
        };
        cp.capture(s);
        const file_offset = self.persistCheckpoint(cp);
        var hot: ?*Checkpoint = cp;
        if (file_offset != null) {
            self.gpa.destroy(cp);
            hot = null;
        } else if (self.hot_checkpoint_bytes + @sizeOf(Checkpoint) <= checkpoint_ram_budget) {
            self.hot_checkpoint_bytes += @sizeOf(Checkpoint);
        } else {
            self.gpa.destroy(cp);
            s.terminal = .damaged;
            return;
        }
        self.lock();
        defer self.unlock();
        if (self.checkpoints.items.len >= max_checkpoint_entries) {
            if (hot) |h| {
                self.hot_checkpoint_bytes -= @sizeOf(Checkpoint);
                self.gpa.destroy(h);
            }
            s.terminal = .damaged;
            return;
        }
        self.checkpoints.append(self.gpa, .{
            .logical = s.logical,
            .physical = s.input.seek,
            .file_offset = file_offset,
            .hot = hot,
        }) catch {
            if (hot) |h| {
                self.hot_checkpoint_bytes -= @sizeOf(Checkpoint);
                self.gpa.destroy(h);
            }
            s.terminal = .damaged;
        };
    }

    fn fillFromSession(self: *Gzip, s: *Session, replay: bool, lane: usize) usize {
        self.op_start[lane] = s.logical;
        self.op_replay[lane] = replay;
        const next_cp = if (!replay) ((s.logical / checkpoint_interval) + 1) * checkpoint_interval else std.math.maxInt(u64);
        const allowed: usize = @intCast(@min(@as(u64, chunk_bytes), next_cp -| s.logical));
        self.op_len[lane] = self.produce(s, self.lane_buf[lane][0..allowed]);
        self.op_physical[lane] = s.input.seek;
        self.checkpointIfDue(s);
        return self.op_len[lane];
    }

    fn discardTo(self: *Gzip, s: *Session, target: u64, replay: bool, lane: usize) bool {
        while (s.logical < target) {
            const want: usize = @intCast(@min(@as(u64, chunk_bytes), target - s.logical));
            const n = self.produce(s, self.lane_buf[lane][0..want]);
            self.checkpointIfDue(s);
            if (replay) {
                self.lock();
                self.replay_inflated += n;
                self.unlock();
            }
            if (n == 0) return false;
        }
        return true;
    }

    fn beginReplay(self: *Gzip, target: u64, lane: usize) bool {
        var chosen: ?CheckpointEntry = null;
        self.lock();
        for (self.checkpoints.items) |entry| {
            if (entry.logical <= target) chosen = entry else break;
        }
        self.unlock();
        const session = if (lane == 2) self.replay2 else self.replay;
        if (chosen) |entry| {
            const cp = self.loadCheckpoint(entry, lane) orelse return false;
            cp.restore(session);
            self.lock();
            self.replay_landed = true;
            self.replay_restored = entry.logical -| self.bom_len;
            self.replay_inflated = 0;
            self.unlock();
        } else {
            session.init(self.mapping, self.mapping.len);
            self.lock();
            self.replay_landed = target >= self.head.items.len;
            self.replay_restored = 0;
            self.replay_inflated = 0;
            self.unlock();
        }
        if (self.lane_physical_budget[lane]) |budget|
            session.input.end = @intCast(@min(@as(u64, self.mapping.len), session.input.seek +| budget));
        self.op_len[lane] = 0;
        return self.discardTo(session, target, true, lane);
    }

    /// The inflate Session driving `lane` (0 = forward, 1 = replay, 2 = replay2)
    /// — the ONE place that mapping is resolved (it used to be re-derived
    /// inline at six call sites).
    fn sessionForLane(self: *const Gzip, lane: usize) *Session {
        return if (lane == forward_lane) self.forward else if (lane == 1) self.replay else self.replay2;
    }

    /// The forward (non-replay) inflate lane — named once so a lane-0-specific
    /// check reads as one.
    const forward_lane: usize = 0;

    /// security-hardening (e) AC-e3: whether `lane`'s inflate is parked on a
    /// RESUMABLE budget stop — it ran out of COMPRESSED bytes (`produce`:
    /// `s.input.end < physicalLen() and s.input.seek >= s.input.end`) rather than
    /// reaching a clean or damaged terminus. `.budget` deliberately leaves
    /// `terminal_kind` unset precisely because it is NOT an end-of-source: for a
    /// NETWORK gzip whose ranged fetch came back short, `ensureCompressed` cannot
    /// grow `input.end`, so the session parks here indefinitely and an empty span
    /// at this point is a STALL, never EOF.
    pub fn laneAtBudget(self: *const Gzip, lane: usize) bool {
        return self.sessionForLane(lane).terminal == .budget;
    }

    fn byteAtLane(self: *Gzip, lane: usize, internal: u64) ?u8 {
        if (internal < self.head.items.len) return self.head.items[@intCast(internal)];
        if (self.op_len[lane] > 0 and internal >= self.op_start[lane] and internal < self.op_start[lane] + self.op_len[lane])
            return self.lane_buf[lane][@intCast(internal - self.op_start[lane])];

        const replay = lane != 0;
        const s = self.sessionForLane(lane);
        if (!replay) {
            // The final `return lane_buf[lane][0]` is only correct when the
            // forward session lands EXACTLY on `internal`. Two ways it can't,
            // both routed to a replay session by returning null (the caller's
            // next cursorAt sees no forward coverage and picks lane 1/2):
            //  * over-produced PAST `internal` (and not in the op buffer — the
            //    fast path above already handled that): it cannot rewind.
            //  * a budget/EOF stop SHORT of `internal`: discardTo scratches
            //    lane_buf[lane] as it advances, so a partial-then-stalled skip
            //    leaves the resident op buffer CLOBBERED and stale — drop it
            //    (op_len = 0) so no later fwd_buffered read trusts corrupt bytes
            //    (the network gzip tail hazard).
            if (s.logical > internal) return null;
            if (!self.discardTo(s, internal, false, lane)) {
                self.op_len[lane] = 0;
                return null;
            }
        } else {
            var nearest: u64 = 0;
            self.lock();
            for (self.checkpoints.items) |entry| if (entry.logical <= internal) {
                nearest = entry.logical;
            } else break;
            self.unlock();
            if (!self.op_replay[lane] or internal < s.logical or nearest > s.logical) {
                if (!self.beginReplay(internal, lane)) return null;
            } else if (!self.discardTo(s, internal, true, lane)) return null;
        }
        if (self.fillFromSession(s, replay, lane) == 0) return null;
        return self.lane_buf[lane][0];
    }

    pub fn residentBytes(self: *const Gzip) u64 {
        return self.head.capacity + 3 * @sizeOf(Session) + 2 * @sizeOf(Checkpoint) + self.hot_checkpoint_bytes +
            self.checkpoints.capacity * @sizeOf(CheckpointEntry) + @sizeOf(Gzip);
    }

    fn physicalFor(self: *const Gzip, logical: u64) u64 {
        const internal = logical +| self.bom_len;
        for (self.head_marks[0..self.head_mark_count]) |m| if (internal <= m.logical_end) return @min(m.physical_end, self.mapping.len);
        for (self.checkpoints.items) |entry| if (internal <= entry.logical) return @min(entry.physical, self.mapping.len);
        return @min(self.forward_physical.load(.acquire), self.mapping.len);
    }
};

pub const Source = union(enum) {
    mmap: Mmap,
    gzip: *Gzip,
    http_range: *HttpRange,

    pub fn len(self: Source) u64 {
        return switch (self) {
            .mmap => |m| m.bytes.len,
            .gzip => |g| g.terminalLogical() orelse (g.forward_logical.load(.acquire) -| g.bom_len),
            .http_range => |hr| hr.logicalLen(),
        };
    }

    pub fn slice(self: Source, start: u64, end: u64) []const u8 {
        return switch (self) {
            .mmap => |m| m.bytes[@intCast(start)..@intCast(end)],
            .gzip => unreachable,
            .http_range => unreachable, // http_range reads via the streaming Cursor, never a direct slice
        };
    }

    pub fn isGzip(self: Source) bool {
        return self == .gzip;
    }

    pub fn knownEnd(self: Source) ?u64 {
        return switch (self) {
            .mmap => |m| m.bytes.len,
            .gzip => |g| g.terminalLogical(),
            // null until the stream's total is known (mirrors gzip.terminalLogical):
            // an unknown-length stream must NEVER report its fetched high-water as
            // the end (that would falsely stop the reader at the head).
            .http_range => |hr| hr.knownEnd(),
        };
    }

    pub fn openHead(self: Source) []const u8 {
        return switch (self) {
            .mmap => |m| m.bytes[0..@min(m.bytes.len, open_bytes)],
            .gzip => |g| g.head.items,
            .http_range => |hr| hr.openHead(),
        };
    }

    pub fn gzipUsable(self: Source) bool {
        return switch (self) {
            .mmap => true,
            .gzip => |g| g.openUsable(),
            .http_range => true,
        };
    }
};

/// Serialized operation cursor.  It leases the gzip operation buffer until
/// deinit; mmap cursors do not lock or copy.
pub const Cursor = struct {
    source: ?Source = null,
    logical: u64 = 0,
    physical: u64 = 0,
    limit: ?u64 = null,
    physical_limit: ?u64 = null,
    saved_input_end: usize = 0,
    locked: bool = false,
    lane: u8 = 0,
    look: [4]u8 = undefined,
    look_start: u64 = 0,
    look_len: usize = 0,

    pub fn deinit(self: *Cursor) void {
        if (self.locked) switch (self.source.?) {
            .http_range => {}, // random-access: no lane lease to release
            .gzip => |g| {
                g.lock();
                g.lane_busy[self.lane] = false;
                g.lane_physical_budget[self.lane] = null;
                if (self.physical_limit != null) {
                    const session = g.sessionForLane(self.lane);
                    session.input.end = self.saved_input_end;
                    if (session.terminal == .budget) {
                        session.dec.err = null;
                        session.terminal = .inflating;
                    }
                }
                g.cond.broadcast(sysio.io());
                g.unlock();
            },
            .mmap => {},
        };
        self.locked = false;
    }

    /// A resumable background cursor must not retain a gzip lane across a
    /// scheduler yield. Reacquisition happens off the document mutex on the
    /// next step, after higher-priority foreground work has had its turn.
    pub fn releaseLane(self: *Cursor) void {
        self.deinit();
    }

    pub fn resumeLane(self: *Cursor) void {
        if (self.locked) return;
        const source = self.source orelse return;
        if (source == .mmap) return;
        const logical = self.logical;
        const limit = self.limit;
        self.* = cursorAt(source, logical, limit, null);
    }

    /// http_range: a genuinely random-access provider over the spool mapping;
    /// peek/span ensure the requested range is fetched (persist-once) then
    /// return a stable spool slice directly — no look-buffer copy needed.
    fn peekHttp(self: *Cursor, n: usize) []const u8 {
        const hr = self.source.?.http_range;
        const max_n = @min(n, self.look.len);
        // Cap by an explicit logical limit and the source's TRUE end (null while
        // an unknown-length stream has not hit EOF) — NEVER by the current
        // fetched extent, so `ensureSlice` drives the sequential drain forward
        // past the head instead of stopping at it.
        var cap: ?u64 = self.limit;
        if (hr.knownEnd()) |ke| cap = if (cap) |x| @min(x, ke) else ke;
        if (cap) |x| if (self.logical >= x) return self.look[0..0];
        var avail: u64 = max_n;
        if (cap) |x| avail = @min(avail, x - self.logical);
        if (self.physical_limit) |pl| {
            const at = hr.physical_base +| self.logical;
            avail = @min(avail, pl -| at);
        }
        if (avail == 0) return self.look[0..0];
        const s = hr.ensureSlice(self.logical + hr.bom_len, avail);
        return s[0..@min(s.len, @as(usize, @intCast(avail)))];
    }

    fn spanHttp(self: *Cursor) []const u8 {
        const hr = self.source.?.http_range;
        var cap: ?u64 = self.limit;
        if (hr.knownEnd()) |ke| cap = if (cap) |x| @min(x, ke) else ke;
        if (cap) |x| if (self.logical >= x) return &.{};
        const internal = self.logical + hr.bom_len;
        // Bound to the next chunk boundary so each span triggers at most one
        // fresh fetch (incremental, never fetch-the-whole-file). `ensureSlice`
        // drains forward as needed and returns the available (short at EOF)
        // slice; empty means the stream ended (or shut down).
        const chunk_end_internal = ((internal / net_source.chunk_bytes) + 1) * net_source.chunk_bytes;
        var end_logical: u64 = chunk_end_internal -| hr.bom_len;
        if (cap) |x| end_logical = @min(end_logical, x);
        if (self.physical_limit) |pl| end_logical = @min(end_logical, pl -| hr.physical_base);
        if (end_logical <= self.logical) return &.{};
        return hr.ensureSlice(internal, end_logical - self.logical);
    }

    pub fn peek(self: *Cursor, n: usize) []const u8 {
        if (self.source.? == .http_range) return self.peekHttp(n);
        const max_n = @min(n, self.look.len);
        if (self.limit) |lim| if (self.logical >= lim) return self.look[0..0];
        var got: usize = 0;
        // A previous peek may have crossed a lane-buffer boundary. Preserve
        // its unconsumed suffix: advancing the inflater replaced lane_buf,
        // but advancing the Cursor by one byte did not consume all lookahead.
        if (self.look_len > 0 and self.logical >= self.look_start and self.logical < self.look_start + self.look_len) {
            const offset: usize = @intCast(self.logical - self.look_start);
            got = @min(max_n, self.look_len - offset);
            std.mem.copyForwards(u8, self.look[0..got], self.look[offset..][0..got]);
            self.look_start = self.logical;
            self.look_len = got;
            if (got == max_n) return self.look[0..got];
        } else {
            self.look_start = self.logical;
            self.look_len = 0;
        }
        switch (self.source.?) {
            .mmap => |m| {
                const physical_end = if (self.physical_limit) |p| p -| m.physical_base else m.bytes.len;
                const end = @min(m.bytes.len, @as(usize, @intCast(@min(self.limit orelse m.bytes.len, physical_end))));
                const at: usize = @intCast(self.logical);
                if (got == 0 and at < end and end - at >= max_n) return m.bytes[at .. at + max_n];
            },
            .gzip => |g| {
                const internal = self.logical + g.bom_len;
                const logical_end = if (self.limit) |lim| lim + g.bom_len else std.math.maxInt(u64);
                if (got == 0 and internal < g.head.items.len) {
                    const end = @min(@as(u64, g.head.items.len), logical_end);
                    if (end - internal >= max_n) return g.head.items[@intCast(internal)..@intCast(internal + max_n)];
                }
                const lane: usize = self.lane;
                if (got == 0 and internal >= g.op_start[lane] and internal + max_n <= g.op_start[lane] + g.op_len[lane] and internal + max_n <= logical_end)
                    return g.lane_buf[lane][@intCast(internal - g.op_start[lane])..@intCast(internal - g.op_start[lane] + max_n)];
            },
            .http_range => unreachable, // handled by peekHttp early return
        }
        while (got < max_n) : (got += 1) {
            if (self.limit) |lim| if (self.logical + got >= lim) break;
            if (self.physical_limit) |lim| switch (self.source.?) {
                .mmap => |m| if (m.physical_base +| self.logical +| got >= lim) break,
                .gzip => {},
                .http_range => {},
            };
            const b = switch (self.source.?) {
                .mmap => |m| if (self.logical + got < m.bytes.len) m.bytes[@intCast(self.logical + got)] else break,
                .gzip => |g| g.byteAtLane(self.lane, self.logical + got + g.bom_len) orelse break,
                .http_range => unreachable,
            };
            self.look[got] = b;
        }
        self.look_start = self.logical;
        self.look_len = got;
        return self.look[0..got];
    }

    pub fn advance(self: *Cursor, n: usize) void {
        self.logical += n;
    }

    pub fn physicalPosition(self: *Cursor) u64 {
        return switch (self.source.?) {
            .mmap => |m| m.physical_base +| self.logical,
            .http_range => |hr| hr.physical_base +| self.logical,
            .gzip => |g| blk: {
                const internal = self.logical +| g.bom_len;
                if (internal <= g.head.items.len) break :blk g.physicalFor(internal -| g.bom_len);
                const lane: usize = self.lane;
                if (internal >= g.op_start[lane] and internal <= g.op_start[lane] + g.op_len[lane]) break :blk g.op_physical[lane];
                const session = g.sessionForLane(lane);
                break :blk session.input.seek;
            },
        };
    }

    pub fn hitPhysicalLimit(self: *const Cursor) bool {
        if (self.physical_limit == null) return false;
        return switch (self.source.?) {
            .mmap => |m| m.physical_base +| self.logical >= self.physical_limit.?,
            .http_range => |hr| hr.physical_base +| self.logical >= self.physical_limit.?,
            .gzip => |g| g.laneAtBudget(self.lane),
        };
    }

    pub fn atLimit(self: *const Cursor) bool {
        if (self.limit) |lim| if (self.logical >= lim) {
            // A logical limit that coincides with the source's OWN true end
            // (source.knownEnd()) is not a truncation — it is simply where
            // the content legitimately ends. Only a limit STRICTLY before the
            // true end is a genuine artificial cap (e.g. a per-row/window
            // scan budget). Without this check, the last record of any
            // streamed source (gzip/http_range) whose scan-budget limit
            // happens to equal the source's total length is misreported as
            // oversized/truncated/budget-stopped — the mmap path already
            // gets this right (lexer.recordBounds's `capped = limit != content.len`).
            if (self.source) |src| if (src.knownEnd()) |known_end| if (lim >= known_end) return false;
            return true;
        };
        if (self.hitPhysicalLimit()) return true;
        return switch (self.source.?) {
            .mmap => false,
            .http_range => false,
            .gzip => |g| g.opening and g.laneAtBudget(Gzip.forward_lane),
        };
    }

    /// security-hardening (e) AC-e3: whether an EMPTY span at the current position
    /// is a genuine end-of-source, vs. bytes merely NOT-YET-AVAILABLE. A NETWORK
    /// short/failed range leaves un-fetched bytes BELOW the known end, so an empty
    /// span there is a retryable STALL, not EOF -- the frontier must not complete
    /// over it.
    ///   * mmap: an empty span is always end-of-mapping (no provider, nothing to
    ///     wait for).
    ///   * gzip: an empty span is a clean/damaged inflate terminus -- EXCEPT for a
    ///     NETWORK gzip (`provider != null`) parked on a `.budget` stop, which
    ///     means the compressed bytes have not arrived, not that the stream ended.
    ///     A LOCAL gzip can also park on `.budget`, but only against a mapping it
    ///     already fully owns, so it always resumes; only the network one can park
    ///     forever. Without this the short-body gz path reports a truncated
    ///     document as COMPLETE with a wrong row count.
    ///
    /// VERIFICATION STATUS of the gzip arm below
    /// (`!(g.provider != null and g.laneAtBudget(self.lane))`): REASONED-CORRECT,
    /// NOT PROBE-CONFIRMED. It must not be written up anywhere as tested — the
    /// 273/273 suite does not cover it either. The fixture built to discriminate
    /// it FAILED to: `probe_gz.zig` with a FULL gzip body, `advertise_length =
    /// true`, and `short_body_at` swept over 20-95% produced BYTE-IDENTICAL
    /// results with and without this arm, on every cut. Advertising the full
    /// plain length while short-circuiting delivery never parks the forward lane
    /// on `.budget` at an empty span, so the arm is never the deciding predicate
    /// there. A discriminating fixture must drive a network gzip to a `.budget`
    /// stop with no compressed bytes left to hand out. Until one exists, treat
    /// this arm as unexercised: reason about it, do not cite a test for it.
    pub fn spanTerminal(self: *const Cursor) bool {
        return switch (self.source.?) {
            .mmap => true,
            .gzip => |g| !(g.provider != null and g.laneAtBudget(self.lane)),
            .http_range => |hr| if (hr.knownEnd()) |ke| self.logical >= ke else hr.eof.load(.acquire),
        };
    }

    pub fn span(self: *Cursor) []const u8 {
        if (self.source.? == .http_range) return self.spanHttp();
        if (self.limit) |lim| if (self.logical >= lim) return &.{};
        return switch (self.source.?) {
            .mmap => |m| blk: {
                const at: usize = @intCast(self.logical);
                if (at >= m.bytes.len) break :blk &.{};
                const physical_end = if (self.physical_limit) |p| p -| m.physical_base else m.bytes.len;
                const lim: usize = @intCast(@min(@min(self.limit orelse m.bytes.len, physical_end), m.bytes.len));
                if (at >= lim) break :blk &.{};
                break :blk m.bytes[at..lim];
            },
            .gzip => |g| blk: {
                const internal = self.logical + g.bom_len;
                const lane: usize = self.lane;
                _ = g.byteAtLane(lane, internal) orelse break :blk &.{};
                const public_lim = self.limit orelse std.math.maxInt(u64);
                var result: []const u8 = if (internal < g.head.items.len)
                    g.head.items[@intCast(internal)..@intCast(@min(@as(u64, g.head.items.len), public_lim +| g.bom_len))]
                else if (internal >= g.op_start[lane] and internal < g.op_start[lane] + g.op_len[lane])
                    g.lane_buf[lane][@intCast(internal - g.op_start[lane])..@intCast(@min(@as(u64, g.op_len[lane]), public_lim +| g.bom_len - g.op_start[lane]))]
                else
                    &.{};
                const forced = g.force_chunk.load(.acquire);
                if (forced > 0 and result.len > forced) result = result[0..@intCast(forced)];
                break :blk result;
            },
            .http_range => unreachable, // handled by spanHttp early return
        };
    }
};

pub fn sourceFromMapping(mapping: []const u8, kind: SourceKind) Source {
    if (kind == .mmap) return .{ .mmap = .{ .bytes = mapping } };
    const g = Gzip.init(std.heap.smp_allocator, mapping) catch return .{ .mmap = .{ .bytes = mapping } };
    return .{ .gzip = g };
}

pub fn snapshotProbe(gpa: std.mem.Allocator, mapping: []const u8, target: u64) bool {
    const g = Gzip.init(gpa, mapping) catch return false;
    defer g.deinit();
    const a = gpa.create(Session) catch return false;
    defer gpa.destroy(a);
    const b = gpa.create(Session) catch return false;
    defer gpa.destroy(b);
    const cp = gpa.create(Checkpoint) catch return false;
    defer gpa.destroy(cp);
    a.init(mapping, mapping.len);
    _ = g.discardTo(a, target, false, 0);
    cp.capture(a);
    cp.restore(b);
    var abuf: [chunk_bytes]u8 = undefined;
    var bbuf: [chunk_bytes]u8 = undefined;
    while (true) {
        const an = g.produce(a, &abuf);
        const bn = g.produce(b, &bbuf);
        if (an != bn or !std.mem.eql(u8, abuf[0..an], bbuf[0..bn])) return false;
        if (an == 0) return a.terminal == b.terminal and a.input.seek == b.input.seek;
    }
}

pub fn sourceFromMappingAlloc(gpa: std.mem.Allocator, mapping: []const u8, kind: SourceKind) !Source {
    return switch (kind) {
        .mmap => .{ .mmap = .{ .bytes = mapping } },
        .gzip => .{ .gzip = try Gzip.init(gpa, mapping) },
    };
}

pub fn sourceShutdown(source: *Source) void {
    switch (source.*) {
        .mmap => {},
        .gzip => |g| {
            g.shutdown.store(true, .release);
            if (g.provider) |hr| hr.shutdown.store(true, .release); // network gzip: wake a stalled compressed drain
        },
        .http_range => |hr| hr.shutdown.store(true, .release),
    }
}

// never-full-download-streaming: gzip-over-http_range construction + the
// network-source predicates the index/poll/rowcount lanes key on.

/// Compose a gzip Source over the compressed bytes served on demand by an
/// http_range spool (TD4). On success the returned Gzip OWNS `provider` (its
/// deinit frees it); on failure returns null and the CALLER frees `provider`.
pub fn gzipOverProvider(gpa: std.mem.Allocator, provider: *HttpRange) ?*Gzip {
    return Gzip.initProvider(gpa, provider) catch null;
}

/// Whether a freshly-composed provider gzip inflated a usable head.
pub fn gzipUsablePtr(g: *Gzip) bool {
    return g.openUsable();
}

/// Deinit a provider gzip (also frees its owned http_range provider).
pub fn gzipDeinit(g: *Gzip) void {
    g.deinit();
}

/// True iff this Source fetches over the network (http_range, or a gzip composed
/// over an http_range) — the lazy-frontier gate keys strictly on this (TD1).
pub fn sourceIsNetwork(source: Source) bool {
    return switch (source) {
        .mmap => false,
        .gzip => |g| g.provider != null,
        .http_range => true,
    };
}

/// The network Source's http_range provider (for the net_* instrumentation
/// seams), or null for a non-network / local Source.
pub fn netProviderOf(source: Source) ?*HttpRange {
    return switch (source) {
        .mmap => null,
        .gzip => |g| g.provider,
        .http_range => |hr| hr,
    };
}

/// The known PHYSICAL total of a network Source (Content-Length / Content-Range
/// total, or the received size once an unknown-length stream hit EOF), or null
/// while an unknown-length stream's total is not yet known (the UINT64_MAX
/// sentinel case at the poll level). Non-network Sources return their byte size.
pub fn netPhysicalTotal(source: Source) ?u64 {
    return switch (source) {
        .mmap => |m| m.bytes.len,
        .gzip => |g| if (g.provider) |hr| hr.physicalTotal() else g.mapping.len,
        .http_range => |hr| hr.physicalTotal(),
    };
}

pub fn sourceFinishOpen(source: *Source) void {
    switch (source.*) {
        .mmap => {},
        .gzip => |g| g.finishOpen(),
        .http_range => {},
    }
}

pub fn sourceDeinit(source: *Source) void {
    switch (source.*) {
        .mmap => {},
        .gzip => |g| g.deinit(),
        .http_range => |hr| hr.deinit(),
    }
}

pub fn cursorAt(source: Source, logical: u64, logical_limit: ?u64, physical_budget: ?u64) Cursor {
    var cur: Cursor = .{ .source = source, .logical = logical, .limit = logical_limit };
    switch (source) {
        .mmap => |m| if (physical_budget) |budget| {
            cur.physical_limit = m.physical_base +| logical +| budget;
        },
        .http_range => |hr| if (physical_budget) |budget| {
            cur.physical_limit = hr.physical_base +| logical +| budget;
        },
        .gzip => |g| {
            g.lock();
            const internal = logical +| g.bom_len;
            while (true) {
                const forward_logical = g.forward_logical.load(.acquire);
                if (!g.lane_busy[0]) {
                    // Lane 0 idle ⇒ the forward session's op buffer is stable
                    // (only a lane-0 op mutates op_start[0]/op_len[0]). The
                    // forward lane can serve `internal` iff it can still inflate
                    // FORWARD to it (internal >= its logical position) OR its
                    // resident op buffer already covers it — the latter reuses
                    // the just-produced chunk for a read just behind the
                    // advancing frontier without a replay. Once the forward
                    // session over-produces PAST `internal` and no longer
                    // buffers it (notably when it parks at clean EOF, where the
                    // buffer becomes empty at the logical end), it can neither
                    // rewind nor produce it, so that read MUST replay — routing
                    // it to lane 0 there yields a 0-byte produce and blanks the
                    // record (the gz tail dead zone).
                    const fwd_buffered = g.op_len[0] > 0 and
                        internal >= g.op_start[0] and internal < g.op_start[0] + g.op_len[0];
                    if (internal >= forward_logical or fwd_buffered) {
                        cur.lane = 0;
                        break;
                    }
                    if (!g.lane_busy[1]) {
                        cur.lane = 1;
                        break;
                    }
                    if (!g.lane_busy[2]) {
                        cur.lane = 2;
                        break;
                    }
                } else if (internal < forward_logical) {
                    // Forward lane busy AND `internal` is behind the frontier ⇒
                    // serve it from an independent replay session.
                    if (!g.lane_busy[1]) {
                        cur.lane = 1;
                        break;
                    }
                    if (!g.lane_busy[2]) {
                        cur.lane = 2;
                        break;
                    }
                }
                g.cond.waitUncancelable(sysio.io(), &g.mutex);
            }
            g.lane_busy[cur.lane] = true;
            g.lane_physical_budget[cur.lane] = physical_budget;
            const session = g.sessionForLane(cur.lane);
            cur.physical = session.input.seek;
            if (physical_budget) |budget| {
                cur.saved_input_end = session.input.end;
                cur.physical_limit = @min(@as(u64, session.input.end), session.input.seek +| budget);
                session.input.end = @intCast(cur.physical_limit.?);
            }
            g.unlock();
            cur.locked = true;
        },
    }
    return cur;
}

/// Acquire one lane for a sequential FILTER/SEARCH chunk.  Unlike cursorAt's
/// short-operation resume fast path, a scan which starts behind the forward
/// inflater must use an independent replay session: the shared forward
/// session can never serve a byte behind its over-produced logical position.
/// The returned Cursor retains that lane until the whole chunk is finished.
pub fn scanCursorAt(source: Source, logical: u64) Cursor {
    var cur: Cursor = .{ .source = source, .logical = logical };
    switch (source) {
        .mmap => {},
        .http_range => {},
        .gzip => |g| {
            g.lock();
            const internal = logical +| g.bom_len;
            while (true) {
                const trailing = internal < g.forward_logical.load(.acquire);
                if (!trailing and !g.lane_busy[0]) {
                    cur.lane = 0;
                    break;
                }
                if (trailing) {
                    if (!g.lane_busy[1]) {
                        cur.lane = 1;
                        break;
                    }
                    if (!g.lane_busy[2]) {
                        cur.lane = 2;
                        break;
                    }
                }
                g.cond.waitUncancelable(sysio.io(), &g.mutex);
            }
            g.lane_busy[cur.lane] = true;
            const session = g.sessionForLane(cur.lane);
            cur.physical = session.input.seek;
            g.unlock();
            cur.locked = true;
        },
    }
    return cur;
}

pub fn rebaseBom(source: *Source, bom_len: u64) void {
    switch (source.*) {
        .mmap => |*m| {
            const used = @min(bom_len, m.bytes.len);
            m.bytes = m.bytes[@intCast(used)..];
            m.physical_base +|= used;
        },
        .gzip => |g| g.bom_len = @min(bom_len, g.head.items.len),
        .http_range => |hr| {
            const used = @min(bom_len, hr.head_len);
            hr.bom_len = used;
            hr.physical_base +|= used;
        },
    }
}
