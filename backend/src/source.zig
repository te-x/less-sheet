//! Logical byte sources.  The mmap variant stays a direct immutable span;
//! gzip owns bounded streaming inflater sessions and restart checkpoints.

const std = @import("std");
const api = @import("api");

const flate = std.compress.flate;
const Reader = std.Io.Reader;
const Decompress = flate.Decompress;
const c = std.c;
const posix = std.posix;

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
    mutex: c.pthread_mutex_t = .{},
    cond: c.pthread_cond_t = .{},
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
    forward_resume: std.atomic.Value(u64) = .init(0),
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
    spill_fd: ?posix.fd_t = null,
    spill_bytes: u64 = 0,
    spill_ops: u64 = 0,
    spill_fail_after: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    head_marks: [open_bytes / chunk_bytes + 1]PhysicalMark = undefined,
    head_mark_count: usize = 0,

    pub fn lock(self: *Gzip) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }
    pub fn unlock(self: *Gzip) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
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

    fn deinit(self: *Gzip) void {
        for (self.checkpoints.items) |entry| if (entry.hot) |cp| self.gpa.destroy(cp);
        self.checkpoints.deinit(self.gpa);
        self.head.deinit(self.gpa);
        if (self.spill_fd) |fd| _ = c.close(fd);
        self.gpa.destroy(self.forward);
        self.gpa.destroy(self.replay);
        self.gpa.destroy(self.replay2);
        self.gpa.destroy(self.spill_snapshot);
        self.gpa.destroy(self.spill_snapshot2);
        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.gpa.destroy(self);
    }

    fn physical(s: *const Session) u64 {
        return s.input.seek;
    }

    fn nextMember(self: *Gzip, s: *Session) bool {
        s.member_count += 1;
        const at = s.input.seek;
        if (at == self.mapping.len) {
            s.terminal = .clean;
            return false;
        }
        if (at + 2 > s.input.end) {
            s.terminal = if (s.input.end < self.mapping.len) .budget else .damaged;
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
        if (out.len == 0 or self.shutdown.load(.acquire)) return 0;
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
                if (s.input.end < self.mapping.len and s.input.seek >= s.input.end) {
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
        }
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
        // artificial end for a damaged/terminal gzip end.
        self.forward.input.end = self.mapping.len;
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
        const path = std.fmt.bufPrintZ(&path_buf, "/tmp/lesssheet-gz-{d}-{x}.ckpt", .{ c.getpid(), @intFromPtr(self) }) catch return;
        const fd = posix.openatZ(posix.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600) catch return;
        if (c.unlink(path.ptr) != 0) {
            _ = c.close(fd);
            return;
        }
        self.spill_fd = fd;
    }

    fn persistCheckpoint(self: *Gzip, cp: *const Checkpoint) ?u64 {
        if (self.spill_ops >= self.spill_fail_after.load(.acquire)) return null;
        self.createSpill();
        const fd = self.spill_fd orelse return null;
        const bytes = std.mem.asBytes(cp);
        const start = self.spill_bytes;
        var done: usize = 0;
        while (done < bytes.len) {
            const n = c.pwrite(fd, bytes[done..].ptr, bytes.len - done, @intCast(start + done));
            if (n <= 0) return null;
            done += @intCast(n);
        }
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
        var done: usize = 0;
        while (done < bytes.len) {
            const n = c.pread(fd, bytes[done..].ptr, bytes.len - done, @intCast(offset + done));
            if (n <= 0) return null;
            done += @intCast(n);
        }
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

    fn byteAtLane(self: *Gzip, lane: usize, internal: u64) ?u8 {
        if (internal < self.head.items.len) return self.head.items[@intCast(internal)];
        if (self.op_len[lane] > 0 and internal >= self.op_start[lane] and internal < self.op_start[lane] + self.op_len[lane])
            return self.lane_buf[lane][@intCast(internal - self.op_start[lane])];

        const replay = lane != 0;
        const s = if (lane == 0) self.forward else if (lane == 1) self.replay else self.replay2;
        if (!replay) {
            if (!self.discardTo(s, internal, false, lane)) return null;
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

    pub fn len(self: Source) u64 {
        return switch (self) {
            .mmap => |m| m.bytes.len,
            .gzip => |g| g.terminalLogical() orelse (g.forward_logical.load(.acquire) -| g.bom_len),
        };
    }

    pub fn slice(self: Source, start: u64, end: u64) []const u8 {
        return switch (self) {
            .mmap => |m| m.bytes[@intCast(start)..@intCast(end)],
            .gzip => unreachable,
        };
    }

    pub fn isGzip(self: Source) bool {
        return self == .gzip;
    }

    pub fn knownEnd(self: Source) ?u64 {
        return switch (self) {
            .mmap => |m| m.bytes.len,
            .gzip => |g| g.terminalLogical(),
        };
    }

    pub fn openHead(self: Source) []const u8 {
        return switch (self) {
            .mmap => |m| m.bytes[0..@min(m.bytes.len, open_bytes)],
            .gzip => |g| g.head.items,
        };
    }

    pub fn gzipUsable(self: Source) bool {
        return switch (self) {
            .mmap => true,
            .gzip => |g| g.openUsable(),
        };
    }
};

/// Serialized operation cursor.  It leases the gzip operation buffer until
/// deinit; mmap cursors do not lock or copy.
pub const Cursor = struct {
    source: ?Source = null,
    logical: u64 = 0,
    physical: u64 = 0,
    span_len: usize = 0,
    limit: ?u64 = null,
    physical_limit: ?u64 = null,
    saved_input_end: usize = 0,
    locked: bool = false,
    lane: u8 = 0,
    look: [4]u8 = undefined,

    pub fn deinit(self: *Cursor) void {
        if (self.locked) switch (self.source.?) {
            .gzip => |g| {
                g.lock();
                const internal = self.logical +| g.bom_len;
                const frontier = g.forward_logical.load(.acquire);
                if (self.lane == 0 or (internal <= frontier and frontier - internal <= chunk_bytes))
                    g.forward_resume.store(internal, .release);
                g.lane_busy[self.lane] = false;
                g.lane_physical_budget[self.lane] = null;
                if (self.physical_limit != null) {
                    const session = if (self.lane == 0) g.forward else if (self.lane == 1) g.replay else g.replay2;
                    session.input.end = self.saved_input_end;
                    if (session.terminal == .budget) {
                        session.dec.err = null;
                        session.terminal = .inflating;
                    }
                }
                _ = c.pthread_cond_broadcast(&g.cond);
                g.unlock();
            },
            .mmap => {},
        };
        self.locked = false;
    }

    pub fn peek(self: *Cursor, n: usize) []const u8 {
        const max_n = @min(n, self.look.len);
        if (self.limit) |lim| if (self.logical >= lim) return self.look[0..0];
        switch (self.source.?) {
            .mmap => |m| {
                const physical_end = if (self.physical_limit) |p| p -| m.physical_base else m.bytes.len;
                const end = @min(m.bytes.len, @as(usize, @intCast(@min(self.limit orelse m.bytes.len, physical_end))));
                const at: usize = @intCast(self.logical);
                if (at < end) return m.bytes[at..@min(end, at + max_n)];
            },
            .gzip => |g| {
                const internal = self.logical + g.bom_len;
                const logical_end = if (self.limit) |lim| lim + g.bom_len else std.math.maxInt(u64);
                if (internal < g.head.items.len) {
                    const end = @min(@as(u64, g.head.items.len), logical_end);
                    if (end - internal >= max_n) return g.head.items[@intCast(internal)..@intCast(internal + max_n)];
                }
                const lane: usize = self.lane;
                _ = g.byteAtLane(lane, internal) orelse return self.look[0..0];
                if (internal >= g.op_start[lane] and internal + max_n <= g.op_start[lane] + g.op_len[lane] and internal + max_n <= logical_end)
                    return g.lane_buf[lane][@intCast(internal - g.op_start[lane])..@intCast(internal - g.op_start[lane] + max_n)];
            },
        }
        var got: usize = 0;
        while (got < max_n) : (got += 1) {
            if (self.limit) |lim| if (self.logical + got >= lim) break;
            if (self.physical_limit) |lim| switch (self.source.?) {
                .mmap => |m| if (m.physical_base +| self.logical +| got >= lim) break,
                .gzip => {},
            };
            const b = switch (self.source.?) {
                .mmap => |m| if (self.logical + got < m.bytes.len) m.bytes[@intCast(self.logical + got)] else break,
                .gzip => |g| g.byteAtLane(self.lane, self.logical + got + g.bom_len) orelse break,
            };
            self.look[got] = b;
        }
        self.span_len = got;
        return self.look[0..got];
    }

    pub fn advance(self: *Cursor, n: usize) void {
        self.logical += n;
    }

    pub fn physicalPosition(self: *Cursor) u64 {
        return switch (self.source.?) {
            .mmap => |m| m.physical_base +| self.logical,
            .gzip => |g| blk: {
                const internal = self.logical +| g.bom_len;
                if (internal <= g.head.items.len) break :blk g.physicalFor(internal -| g.bom_len);
                const lane: usize = self.lane;
                if (internal >= g.op_start[lane] and internal <= g.op_start[lane] + g.op_len[lane]) break :blk g.op_physical[lane];
                const session = if (lane == 0) g.forward else if (lane == 1) g.replay else g.replay2;
                break :blk session.input.seek;
            },
        };
    }

    pub fn hitPhysicalLimit(self: *const Cursor) bool {
        if (self.physical_limit == null) return false;
        return switch (self.source.?) {
            .mmap => |m| m.physical_base +| self.logical >= self.physical_limit.?,
            .gzip => |g| blk: {
                const session = if (self.lane == 0) g.forward else if (self.lane == 1) g.replay else g.replay2;
                break :blk session.terminal == .budget;
            },
        };
    }

    pub fn atLimit(self: *const Cursor) bool {
        if (self.limit) |lim| if (self.logical >= lim) return true;
        if (self.hitPhysicalLimit()) return true;
        return switch (self.source.?) {
            .mmap => false,
            .gzip => |g| g.opening and g.forward.terminal == .budget,
        };
    }

    pub fn span(self: *Cursor) []const u8 {
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
        .gzip => |g| g.shutdown.store(true, .release),
    }
}

pub fn sourceFinishOpen(source: *Source) void {
    switch (source.*) {
        .mmap => {},
        .gzip => |g| g.finishOpen(),
    }
}

pub fn sourceDeinit(source: *Source) void {
    switch (source.*) {
        .mmap => {},
        .gzip => |g| g.deinit(),
    }
}

pub fn cursorAt(source: Source, logical: u64, logical_limit: ?u64, physical_budget: ?u64) Cursor {
    var cur: Cursor = .{ .source = source, .logical = logical, .limit = logical_limit };
    switch (source) {
        .mmap => |m| if (physical_budget) |budget| {
            cur.physical_limit = m.physical_base +| logical +| budget;
        },
        .gzip => |g| {
            g.lock();
            const internal = logical +| g.bom_len;
            while (true) {
                const forward_logical = g.forward_logical.load(.acquire);
                const forward_resume = g.forward_resume.load(.acquire);
                if ((internal >= forward_logical or internal == forward_resume) and !g.lane_busy[0]) {
                    cur.lane = 0;
                    break;
                }
                if (internal < forward_logical and internal != forward_resume) {
                    if (!g.lane_busy[1]) {
                        cur.lane = 1;
                        break;
                    }
                    if (!g.lane_busy[2]) {
                        cur.lane = 2;
                        break;
                    }
                }
                _ = c.pthread_cond_wait(&g.cond, &g.mutex);
            }
            g.lane_busy[cur.lane] = true;
            g.lane_physical_budget[cur.lane] = physical_budget;
            const session = if (cur.lane == 0) g.forward else if (cur.lane == 1) g.replay else g.replay2;
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

pub fn rebaseBom(source: *Source, bom_len: u64) void {
    switch (source.*) {
        .mmap => |*m| {
            const used = @min(bom_len, m.bytes.len);
            m.bytes = m.bytes[@intCast(used)..];
            m.physical_base +|= used;
        },
        .gzip => |g| g.bom_len = @min(bom_len, g.head.items.len),
    }
}
