//! SORTED VIEWS — the third view kind (ARCH-sort-by-column). See
//! api/lesssheet.h "SORTED VIEWS" for the normative model: the comparator's
//! total order, the key pass, THE CONVERGING PREFIX, sorted coordinates, jump
//! and find under a sort, the four-way scan slot, the rebuild triggers, RESET,
//! failure, and laziness.
//!
//! SHAPE OF THE IMPLEMENTATION
//!   * `Build` holds everything one key pass owns: the captured key
//!     configuration, the scan cursor, ONE in-memory chunk of (key, row)
//!     records sized by THE chunk knob (`chunkBytes`), the spilled RUNS, the
//!     bounded top-K PREFIX that serves a building sort, and — once the pass
//!     reaches EOF — the on-disk PERMUTATION and INVERSE mapping. It is created
//!     by the first non-no-op `ls_sort_set` and destroyed by
//!     `ls_sort_clear` / a failure / `ls_close`: a document nobody sorts
//!     allocates nothing here (api/lesssheet.h §12 LAZINESS).
//!   * The pass runs in the document's ONE background scan slot
//!     (src/index.zig `workerMain`), lock-free per chunk, committing under the
//!     document mutex exactly like the filter-scan it is modelled on. The
//!     `scan_busy` flag + the document condition give `ls_sort_clear` /
//!     `ls_sort_set` a deterministic "the worker is not inside a chunk" point,
//!     so a cancel really does release every temp file before it returns.
//!   * ORDER IS DIRECTION-AGNOSTIC ON DISK: the permutation is always the
//!     ASCENDING one and descending reads it backwards (the header's DESCENDING
//!     rule), which is what makes an ACTIVE flip O(1) and a flip WHILE BUILDING
//!     cost no source re-scan — only a re-derivation of the top-K prefix from
//!     the keys already extracted.

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");
const tempdir = @import("tempdir.zig");
const matcher = @import("matcher.zig");
const column = @import("column.zig");
const filter_mod = @import("filter.zig");
const nav = @import("nav.zig");
const sysio = @import("sysio.zig");

const posix = std.posix;
const Document = base.Document;
const Pos = base.Pos;
const CellRef = base.CellRef;
const checkpoint_interval = base.checkpoint_interval;

// ===========================================================================
// THE ONE CHUNK KNOB: one default (contracts/api.zig `sort_chunk_default_bytes`)
// + THIS resolver. Every consumer inside the sort — the pair buffer, the run
// writer, the k-way merge read-buffers — reads `chunkBytes(d)`; nothing
// re-derives the number.
// ===========================================================================

/// THE RESOLVER (contracts/api.zig `sortChunkBytes`).
pub fn chunkBytes(d: *const Document) u64 {
    return if (d.sort_chunk_override != 0) d.sort_chunk_override else api.sort_chunk_default_bytes;
}

/// Test seam: override the chunk knob for this document (0 restores default).
pub fn chunkBytesSetForTest(d: *Document, bytes: u64) void {
    d.lock();
    defer d.unlock();
    d.sort_chunk_override = bytes;
}

// --- The ONE prefix-depth resolver (contracts/api.zig `sortPrefixRows`) -----
// K is NOT a new constant: it IS api.window_max_rows (LS_WINDOW_MAX_ROWS), the
// deepest a caller can address in one window. Every consumer -- the top-K
// structure's capacity, the servable-range clamp while BUILDING -- reads THIS,
// never a literal 4096.

/// THE RESOLVER: how many view rows a BUILDING sort can serve at most.
pub fn prefixRows(d: *const Document) u64 {
    _ = d;
    return api.window_max_rows;
}

/// Where this document's sort scratch goes — always THE resolver, never a
/// locally built "/tmp/..." literal (src/tempdir.zig says why).
pub fn tempDir() []const u8 {
    return tempdir.resolve();
}

// ===========================================================================
// The key: one byte string per row, plus the GROUP it belongs to.
// ===========================================================================

/// api/lesssheet.h §2 THE ORDER: rows are partitioned into three groups that
/// never interleave. The numeric values ARE the ascending group order.
const group_conforming: u8 = 0;
const group_nonconforming: u8 = 1;
const group_null: u8 = 2;

/// How group-A keys of this column compare. Group B (non-conforming) and every
/// TEXT-ish effective kind use the header's TEXT rule; the other kinds are
/// encoded into order-preserving byte strings at extraction, so the comparator
/// is a plain byte compare and the merge never re-parses a value.
const KeyMode = enum { text, encoded };

/// The key configuration CAPTURED at the `ls_sort_set` that started the build
/// (api/lesssheet.h §2: "both CAPTURED at the ls_sort_set that started the
/// build"), so a background inference publication can never re-order the view
/// a user is looking at.
const KeyConfig = struct {
    column: u32,
    kind: api.ColumnTypeKind,
    semantics: api.ColumnDatetimeSemantics,
    mode: KeyMode,
    /// Owned copy of the column's null sentinel; empty == LS_COLUMN_NULL_NONE.
    sentinel: []u8,
    has_sentinel: bool,
};

fn keyModeFor(kind: api.ColumnTypeKind) KeyMode {
    return switch (kind) {
        .integer, .decimal, .date, .datetime, .boolean => .encoded,
        .text, .unknown, .unsupported => .text,
    };
}

/// The header's TEXT rule, verbatim: compare byte-by-byte with ASCII case
/// FOLDED, the shorter value first when one is a prefix of the other, then a
/// BYTE-EXACT comparison of the same bytes as the tiebreak (so "Ab" and "aB"
/// are ordered, and deterministically).
fn textOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const fa = matcher.asciiLower(a[i]);
        const fb = matcher.asciiLower(b[i]);
        if (fa != fb) return if (fa < fb) .lt else .gt;
    }
    if (a.len != b.len) return if (a.len < b.len) .lt else .gt;
    return std.mem.order(u8, a, b);
}

/// Big-endian encoding of an i64 with the sign bit flipped, so unsigned byte
/// order IS signed numeric order.
fn putBiasedI64(out: *[8]u8, v: i64) void {
    const u: u64 = @as(u64, @bitCast(v)) ^ (@as(u64, 1) << 63);
    std.mem.writeInt(u64, out, u, .big);
}

/// The decimal exponent, order-preserved but SHORT for every exponent a real
/// document contains: one range tag plus two bytes for |exponent| <= 16383,
/// and the full 8 bytes outside it. Compactness is not cosmetic — the first
/// eight bytes of a key are what the chunk sort compares as one integer (see
/// `keyPrefix`), so an 8-byte exponent would push every significant digit out
/// of that window and make the acceleration useless on numeric columns. The
/// three range tags never overlap, so ordering across them is still exact.
fn putExponent(out: *std.ArrayList(u8), gpa: std.mem.Allocator, msd_pos: i64) !void {
    if (msd_pos >= -16383 and msd_pos <= 16383) {
        const v: u16 = @intCast(msd_pos + 16384);
        try out.append(gpa, 0x01);
        try out.append(gpa, @intCast(v >> 8));
        try out.append(gpa, @truncate(v));
        return;
    }
    var wide: [8]u8 = undefined;
    putBiasedI64(&wide, msd_pos);
    try out.append(gpa, if (msd_pos < 0) @as(u8, 0x00) else 0x02);
    try out.appendSlice(gpa, &wide);
}

/// The first eight key bytes as ONE integer, under the rule that will order
/// this key: ASCII-folded for the TEXT rule (group B and text-ish kinds),
/// raw for an encoded key. Shorter keys pad with 0x00, which agrees with the
/// real comparator — a key that is a prefix of another sorts first — and any
/// tie here is resolved by the EXACT comparator, never by the prefix alone.
fn keyPrefix(mode: KeyMode, group: u8, key: []const u8) u64 {
    const fold = group != group_conforming or mode == .text;
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const byte: u8 = if (i < key.len)
            (if (fold) matcher.asciiLower(key[i]) else key[i])
        else
            0;
        v = (v << 8) | byte;
    }
    return v;
}

/// EXACT numeric key (api/lesssheet.h §2 INTEGER/DECIMAL): sign class, then the
/// decimal exponent of the most-significant digit, then the significant digits.
/// Never through binary floating point, and never lossy: equal-valued
/// spellings ("2", "2.0", "+2e0") produce byte-identical keys, so they TIE and
/// fall to source order, while any real difference shows up in the exponent or
/// in the digit string.
///
///   negatives  0x7F  ~exponent  ~digits  0xFF   (both inverted: larger
///   zero       0x80                             magnitude sorts FIRST, and the
///   positives  0x81   exponent   digits  0x00    0xFF terminator keeps a
///                                                 shorter digit string LAST)
fn encodeNumeric(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8) !void {
    const dec = matcher.parseDecimal(raw);
    if (!dec.valid or dec.zero) {
        try out.append(gpa, 0x80);
        return;
    }
    if (dec.negative) {
        // Every byte after the sign tag is INVERTED, so a larger magnitude
        // sorts FIRST; the 0xFF terminator (above every inverted digit) keeps a
        // shorter digit string LAST, which is what makes -1.2 > -1.23.
        const mark = out.items.len;
        try out.append(gpa, 0x7F);
        try putExponent(out, gpa, dec.msd_pos);
        var i: usize = 0;
        while (i < dec.sig_len) : (i += 1) try out.append(gpa, dec.sigDigit(i));
        for (out.items[mark + 1 ..]) |*b| b.* = ~b.*;
        try out.append(gpa, 0xFF);
    } else {
        try out.append(gpa, 0x81);
        try putExponent(out, gpa, dec.msd_pos);
        var i: usize = 0;
        while (i < dec.sig_len) : (i += 1) try out.append(gpa, dec.sigDigit(i));
        try out.append(gpa, 0x00);
    }
}

fn digitsAt(raw: []const u8, start: usize, count: usize) u64 {
    var v: u64 = 0;
    for (raw[start .. start + count]) |ch| v = v * 10 + (ch - '0');
    return v;
}

/// Days from 1970-01-01 for a proleptic-Gregorian civil date (Howard Hinnant's
/// `days_from_civil`). The grammar was already validated by
/// `column.classifyCell`, so the fields are in range.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = y_in - @as(i64, if (m <= 2) 1 else 0);
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else @as(i64, 9))) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// CHRONOLOGICAL datetime key (api/lesssheet.h §2 DATETIME): the INSTANT for a
/// zoned column (offsets normalized, so 00:00:00Z and 01:00:00+01:00 are a
/// TIE), the wall clock for a naive one; fractional seconds compare BY VALUE
/// (trailing zeros stripped, so ".5" == ".50"). The grammar was validated by
/// `column.classifyCell` before we get here.
fn encodeDatetime(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8) !void {
    const year: i64 = @intCast(digitsAt(raw, 0, 4));
    const month: i64 = @intCast(digitsAt(raw, 5, 2));
    const day: i64 = @intCast(digitsAt(raw, 8, 2));
    const hour: i64 = @intCast(digitsAt(raw, 11, 2));
    const minute: i64 = @intCast(digitsAt(raw, 14, 2));
    const second: i64 = @intCast(digitsAt(raw, 17, 2));
    var i: usize = 19;
    var frac: []const u8 = &.{};
    if (i < raw.len and raw[i] == '.') {
        i += 1;
        const start = i;
        while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') i += 1;
        frac = raw[start..i];
    }
    var offset_seconds: i64 = 0;
    if (i < raw.len and raw[i] != 'Z') {
        const sign: i64 = if (raw[i] == '-') -1 else 1;
        const oh: i64 = @intCast(digitsAt(raw, i + 1, 2));
        const om: i64 = @intCast(digitsAt(raw, i + 4, 2));
        offset_seconds = sign * (oh * 3600 + om * 60);
    }
    const total = daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset_seconds;
    var enc: [8]u8 = undefined;
    putBiasedI64(&enc, total);
    try out.appendSlice(gpa, &enc);
    var end = frac.len;
    while (end > 0 and frac[end - 1] == '0') end -= 1; // ".5" == ".50"
    try out.appendSlice(gpa, frac[0..end]);
    try out.append(gpa, 0x00); // no fraction sorts before any fraction
}

/// The group + key bytes for one cell under `cfg`. The CONFORMANCE decision is
/// `column.classifyCell` — the same pinned grammar the type inference uses, so
/// there is exactly one definition of "parses as a DATE" in the core.
fn buildKey(cfg: KeyConfig, gpa: std.mem.Allocator, cell: []const u8, out: *std.ArrayList(u8)) !u8 {
    out.clearRetainingCapacity();
    if (cfg.has_sentinel and std.mem.eql(u8, cfg.sentinel, cell)) return group_null;
    const conforms = switch (cfg.kind) {
        .text, .unknown, .unsupported => true,
        .integer => column.classifyCell(cell).kind == .integer,
        .decimal => blk: {
            const k = column.classifyCell(cell).kind;
            break :blk k == .integer or k == .decimal;
        },
        .date => column.classifyCell(cell).kind == .date,
        .datetime => blk: {
            const t = column.classifyCell(cell);
            // A value whose ZONEDNESS differs from the column's is
            // NON-CONFORMING (a naive value in a zoned column, or the reverse).
            break :blk t.kind == .datetime and t.datetime_semantics == cfg.semantics;
        },
        .boolean => column.classifyCell(cell).kind == .boolean,
    };
    if (!conforms) {
        try out.appendSlice(gpa, cell); // group B: ordered by the TEXT rule
        return group_nonconforming;
    }
    switch (cfg.kind) {
        .text, .unknown, .unsupported => try out.appendSlice(gpa, cell),
        .integer, .decimal => try encodeNumeric(out, gpa, cell),
        // The pinned YYYY-MM-DD grammar makes byte order chronological.
        .date => try out.appendSlice(gpa, cell),
        .datetime => try encodeDatetime(out, gpa, cell),
        // The boolean grammar is judged on the TRIMMED cell (column.classify
        // trims before it tests true/false), so the KEY has to be taken from
        // the same bytes: keying off `cell[0]` would read the leading space of
        // " true" and order it as FALSE.
        .boolean => {
            const t = column.trimmedCell(cell);
            try out.append(gpa, if (t.len > 0 and matcher.asciiLower(t[0]) == 't') @as(u8, 1) else 0);
        },
    }
    return group_conforming;
}

// ===========================================================================
// Records: what the chunk buffer and the run files hold.
//   [group u8][key_len u32 LE][key bytes][source row u64 LE]( [base u64 LE] )
// `base` — the row's index in the PRE-SORT view (its filtered index) — is
// stored only for a FILTERED build; unfiltered it IS the source row, and
// leaving it out is what keeps the transient temp footprint inside the ARCH's
// per-row bound.
// ===========================================================================

/// A record's place in the chunk buffer plus its fixed-width sort acceleration.
const SortEntry = struct {
    pref: u64,
    off: u32,
    group: u8,
};

const Record = struct {
    group: u8,
    key: []const u8,
    row: u64,
    base: u64,
    len: usize, // encoded length, for stepping a buffer
};

fn recordLen(key_len: usize, filtered: bool) usize {
    return 5 + key_len + 8 + @as(usize, if (filtered) 8 else 0);
}

fn writeRecord(out: *std.ArrayList(u8), gpa: std.mem.Allocator, group: u8, key: []const u8, row: u64, bidx: u64, filtered: bool) !void {
    const start = out.items.len;
    try out.ensureUnusedCapacity(gpa, recordLen(key.len, filtered));
    out.items.len = start + recordLen(key.len, filtered);
    const b = out.items[start..];
    b[0] = group;
    std.mem.writeInt(u32, b[1..5], @intCast(key.len), .little);
    @memcpy(b[5 .. 5 + key.len], key);
    std.mem.writeInt(u64, b[5 + key.len ..][0..8], row, .little);
    if (filtered) std.mem.writeInt(u64, b[13 + key.len ..][0..8], bidx, .little);
}

fn readRecord(buf: []const u8, filtered: bool) Record {
    const klen: usize = std.mem.readInt(u32, buf[1..5], .little);
    const row = std.mem.readInt(u64, buf[5 + klen ..][0..8], .little);
    const bidx = if (filtered) std.mem.readInt(u64, buf[13 + klen ..][0..8], .little) else row;
    return .{
        .group = buf[0],
        .key = buf[5 .. 5 + klen],
        .row = row,
        .base = bidx,
        .len = recordLen(klen, filtered),
    };
}

/// THE COMPARATOR (api/lesssheet.h §2 is the definition): group, then the key
/// under this column's rule, then SOURCE ORDER. Total — no two distinct rows
/// ever compare equal — and exact: a group-A key of an encoded kind is
/// order-preserving by construction, and a TEXT key carries the full cell
/// bytes, so no comparison is ever decided on a lossy prefix and no hash is
/// ever used to conclude equality.
fn ascLess(mode: KeyMode, a: Record, b: Record) bool {
    if (a.group != b.group) return a.group < b.group;
    const ord = if (a.group == group_conforming and mode == .encoded)
        std.mem.order(u8, a.key, b.key)
    else
        textOrder(a.key, b.key);
    return switch (ord) {
        .lt => true,
        .gt => false,
        .eq => a.row < b.row,
    };
}

/// "a comes before b in the REQUESTED direction". Descending is the ascending
/// permutation READ BACKWARDS — ties included, which is why equal values appear
/// in REVERSE source order descending.
fn dirLess(mode: KeyMode, dir: api.SortDirection, a: Record, b: Record) bool {
    return if (dir == .ascending) ascLess(mode, a, b) else ascLess(mode, b, a);
}

// ===========================================================================
// The bounded top-K PREFIX — the ONE structure that serves a BUILDING sort
// (api/lesssheet.h §3 THE PREFIX STRUCTURE). O(K) memory, K == the one prefix
// resolver, independent of the row count.
// ===========================================================================

const PrefixEntry = struct {
    group: u8,
    key: []u8,
    row: u64,

    fn rec(self: PrefixEntry) Record {
        return .{ .group = self.group, .key = self.key, .row = self.row, .base = self.row, .len = 0 };
    }
};

const Prefix = struct {
    /// A heap whose ROOT is the LEAST GOOD kept row for the current direction,
    /// so admitting a row is one comparison and eviction is O(log K).
    items: std.ArrayList(PrefixEntry) = .empty,
    /// Lazily rebuilt view of `items` in direction order; the read path
    /// (ls_source_row / a sorted window) hits it thousands of times per window,
    /// so it is memoized until the next mutation.
    sorted: std.ArrayList(u32) = .empty,
    sorted_valid: bool = false,
    key_bytes: u64 = 0,

    fn deinit(self: *Prefix, gpa: std.mem.Allocator) void {
        for (self.items.items) |e| gpa.free(e.key);
        self.items.deinit(gpa);
        self.sorted.deinit(gpa);
        self.* = .{};
    }

    fn clear(self: *Prefix, gpa: std.mem.Allocator) void {
        for (self.items.items) |e| gpa.free(e.key);
        self.items.clearRetainingCapacity();
        self.sorted.clearRetainingCapacity();
        self.sorted_valid = false;
        self.key_bytes = 0;
    }

    fn worseThanRoot(self: *const Prefix, mode: KeyMode, dir: api.SortDirection, r: Record) bool {
        if (self.items.items.len == 0) return false;
        return !dirLess(mode, dir, r, self.items.items[0].rec());
    }

    fn siftUp(self: *Prefix, mode: KeyMode, dir: api.SortDirection, start: usize) void {
        var i = start;
        while (i > 0) {
            const parent = (i - 1) / 2;
            // MAX-heap in "goodness": the parent must be the WORSE of the two,
            // so the ROOT is the least-good kept row and admitting a candidate
            // is one comparison. Stop as soon as the parent is already worse.
            if (!dirLess(mode, dir, self.items.items[parent].rec(), self.items.items[i].rec())) break;
            std.mem.swap(PrefixEntry, &self.items.items[parent], &self.items.items[i]);
            i = parent;
        }
    }

    fn siftDown(self: *Prefix, mode: KeyMode, dir: api.SortDirection) void {
        const n = self.items.items.len;
        var i: usize = 0;
        while (true) {
            const l = 2 * i + 1;
            if (l >= n) break;
            var worst = l;
            const r = l + 1;
            if (r < n and dirLess(mode, dir, self.items.items[worst].rec(), self.items.items[r].rec())) worst = r;
            if (dirLess(mode, dir, self.items.items[worst].rec(), self.items.items[i].rec())) break;
            std.mem.swap(PrefixEntry, &self.items.items[i], &self.items.items[worst]);
            i = worst;
        }
    }

    /// Admit `r` if it belongs in the top `cap`. Returns false only on OOM.
    fn push(self: *Prefix, gpa: std.mem.Allocator, mode: KeyMode, dir: api.SortDirection, cap: usize, r: Record) bool {
        if (cap == 0) return true;
        if (self.items.items.len >= cap) {
            if (self.worseThanRoot(mode, dir, r)) return true; // cannot make the top K
            const dup = gpa.dupe(u8, r.key) catch return false;
            const old = self.items.items[0];
            self.key_bytes -= old.key.len;
            gpa.free(old.key);
            self.items.items[0] = .{ .group = r.group, .key = dup, .row = r.row };
            self.key_bytes += dup.len;
            self.siftDown(mode, dir);
        } else {
            const dup = gpa.dupe(u8, r.key) catch return false;
            self.items.append(gpa, .{ .group = r.group, .key = dup, .row = r.row }) catch {
                gpa.free(dup);
                return false;
            };
            self.key_bytes += dup.len;
            self.siftUp(mode, dir, self.items.items.len - 1);
        }
        self.sorted_valid = false;
        return true;
    }

    const SortCtx = struct {
        p: *const Prefix,
        mode: KeyMode,
        dir: api.SortDirection,
        fn less(self: SortCtx, a: u32, b: u32) bool {
            return dirLess(self.mode, self.dir, self.p.items.items[a].rec(), self.p.items.items[b].rec());
        }
    };

    /// The prefix in direction order (best first). Caller holds the mutex.
    ///
    /// ZERO ALLOCATOR CALLS: this runs inside `ls_source_row`, which the frozen
    /// contract pins as allocation-free and infallible. The index buffer is
    /// sized ONCE at `ls_sort_set` (`reserve`, a call that may allocate) and
    /// the heap can never hold more than K entries, so the memo is only ever
    /// filled and sorted in place. Memoized on the prefix's own mutations, so
    /// the 4096 `ls_source_row` calls a full window costs sort once, not 4096
    /// times.
    fn ordered(self: *Prefix, mode: KeyMode, dir: api.SortDirection) []const u32 {
        if (self.sorted_valid and self.sorted.items.len == self.items.items.len) return self.sorted.items;
        if (self.sorted.capacity < self.items.items.len) return &.{}; // reserve failed at set
        self.sorted.clearRetainingCapacity();
        for (0..self.items.items.len) |i| self.sorted.appendAssumeCapacity(@intCast(i));
        const ctx: SortCtx = .{ .p = self, .mode = mode, .dir = dir };
        std.mem.sort(u32, self.sorted.items, ctx, SortCtx.less);
        self.sorted_valid = true;
        return self.sorted.items;
    }

    /// Size the direction-order memo for K entries up front (ls_sort_set).
    fn reserve(self: *Prefix, gpa: std.mem.Allocator, cap: usize) !void {
        try self.sorted.ensureTotalCapacityPrecise(gpa, cap);
        try self.items.ensureTotalCapacityPrecise(gpa, cap);
    }
};

// ===========================================================================
// FIND UNDER A SORT (api/lesssheet.h §7, ARCH FR7). "The counting mechanism is
// unchanged in KIND (per-block counters, never a match-row list, memory
// O(index checkpoints)); only the blocks are indexed by sorted position."
//
// `counts[i]` is the number of matching rows whose SORTED position lies in
// block i (blocks are `checkpoint_interval` sorted positions — the existing
// index-block knob, not a new one). It is tallied BY THE MATCH-SCAN, one
// inverse-mapping lookup per match, inside the pass that was already reading
// those rows: no navigation ever pays a second sweep for it, which is what
// makes "after LS_SEARCH_DONE every navigation is fast again" true.
//
// A navigation then skips whole empty blocks through `counts` and materializes
// exactly ONE block's worth of sorted positions to find the answer inside it —
// the cost class of one window, not of a file scan. That block's matching
// positions are cached (bounded by the block, like a window), so walking
// match-to-match inside a block is free.
// ===========================================================================

const NavIndex = struct {
    counts: std.ArrayList(u64) = .empty,
    /// The search generation these counters describe; a new search invalidates
    /// them (and a sort change destroys the whole build with them).
    search_gen: u64 = 0,
    ready: bool = false,
    /// The one cached block scan.
    block: u64 = 0,
    block_ready: bool = false,
    /// Sorted positions inside `block` that match, ascending, with the matched
    /// column beside each.
    positions: std.ArrayList(u64) = .empty,
    columns: std.ArrayList(u32) = .empty,
    /// Matches in every block strictly before `block` (the rank base).
    before: u64 = 0,
    /// Data rows the counters already cover, contiguously from row 0. The
    /// tally's own coverage proof (see navTallyLocked).
    tallied_rows: u64 = 0,

    fn deinit(self: *NavIndex, gpa: std.mem.Allocator) void {
        self.counts.deinit(gpa);
        self.positions.deinit(gpa);
        self.columns.deinit(gpa);
        self.* = .{};
    }

    fn reset(self: *NavIndex, gen: u64) void {
        self.counts.clearRetainingCapacity();
        self.positions.clearRetainingCapacity();
        self.columns.clearRetainingCapacity();
        self.search_gen = gen;
        self.ready = false;
        self.block_ready = false;
        self.before = 0;
        self.tallied_rows = 0;
    }
};

/// Bounded snapshot of Find's sorted counters. Source-order match counts alone
/// cannot restore sorted navigation: that would make the next arrow rescan the
/// document. The permutation generation and prefix coverage must also match.
pub const NavCache = struct {
    generation: ?u64 = null,
    counts: std.ArrayList(u64) = .empty,
    rows: u64 = 0,
    filter_cum: u64 = 0,

    pub fn deinit(self: *NavCache, gpa: std.mem.Allocator) void {
        self.counts.deinit(gpa);
    }

    pub fn capture(self: *NavCache, d: *Document) !void {
        const b = d.sort_build orelse return;
        if (d.sort_state != .active or b.nav.search_gen != d.search_gen or !b.nav.ready) return;
        if (!d.search_total_exact and b.nav.tallied_rows != d.search_rows) return;
        try self.counts.appendSlice(d.gpa, b.nav.counts.items);
        self.generation = d.sort_gen;
        self.rows = d.search_rows;
        self.filter_cum = d.search_filter_cum;
    }

    pub fn compatible(self: *const NavCache, d: *Document) bool {
        return d.sort_state == .active and self.generation != null and self.generation.? == d.sort_gen;
    }

    pub fn restore(self: *const NavCache, d: *Document) bool {
        if (!self.compatible(d)) return false;
        const b = d.sort_build orelse return false;
        b.nav.counts.ensureTotalCapacity(d.gpa, self.counts.items.len) catch return false;
        b.nav.reset(d.search_gen);
        b.nav.counts.appendSliceAssumeCapacity(self.counts.items);
        b.nav.ready = true;
        b.nav.tallied_rows = self.rows;
        d.search_filter_cum = self.filter_cum;
        d.sort_nav_tally = true;
        return true;
    }
};

// ===========================================================================
// Ephemeral temp storage — the SAME discipline (and the SAME resolver) as the
// gzip checkpoint spill and the network spool: mode 0600, unlinked at creation,
// never a cache, gone at ls_close.
// ===========================================================================

const TempFile = struct {
    fd: posix.fd_t,
    bytes: u64 = 0,
};

const Run = struct { off: u64, len: u64 };

// ===========================================================================
// The build.
// ===========================================================================

pub const Build = struct {
    gpa: std.mem.Allocator,
    cfg: KeyConfig,
    filtered: bool,
    dir: api.SortDirection,

    // --- scan cursor -------------------------------------------------------
    pos: Pos,
    row: u64 = 0, // data rows scanned
    view_rows: u64 = 0, // rows in the view (matching rows) seen so far
    block_matches: u64 = 0, // matches in the CURRENT, still-partial index block
    fold_from: u64 = 0, // first row `block_matches` counts (see commitChunk)
    eof: bool = false,

    // --- the ONE in-memory chunk of records --------------------------------
    buf: std.ArrayList(u8) = .empty,
    /// One entry per record in `buf`, carrying the record's OFFSET plus the
    /// fixed-width acceleration the header sanctions: the group and the first
    /// eight key bytes as one integer. Sorting these instead of chasing raw
    /// offsets keeps the chunk sort's comparisons in cache and integral, and
    /// any prefix TIE falls through to the exact comparator — so the
    /// acceleration is never allowed to decide an order by itself.
    offs: std.ArrayList(SortEntry) = .empty,

    // --- prefix candidates staged by the chunk currently running -----------
    stage: std.ArrayList(u8) = .empty,
    stage_offs: std.ArrayList(u32) = .empty,
    th_valid: bool = false, // a threshold snapshot exists (the prefix was full)
    th_group: u8 = 0,
    th_key: std.ArrayList(u8) = .empty,
    th_row: u64 = 0,

    // --- spilled runs ------------------------------------------------------
    runs_file: ?TempFile = null,
    runs: std.ArrayList(Run) = .empty,

    // --- the finished order ------------------------------------------------
    perm_file: ?TempFile = null,
    perm: []align(std.heap.page_size_min) u8 = &.{},
    inv_file: ?TempFile = null,
    inv: []align(std.heap.page_size_min) u8 = &.{},
    rows_total: u64 = 0, // == view_rows once ACTIVE

    prefix: Prefix = .{},
    /// FIND UNDER A SORT: the per-sorted-block match counters (see NavIndex).
    nav: NavIndex = .{},

    // --- per-row scratch ---------------------------------------------------
    scratch: std.ArrayList(u8) = .empty,
    refs: std.ArrayList(CellRef) = .empty,
    keybuf: std.ArrayList(u8) = .empty,
    /// Bytes the k-way merge's read-buffers hold while it runs (accounting
    /// only; the buffers themselves belong to the RunReaders).
    merge_bytes: u64 = 0,
    /// The one selected column the UNFILTERED pass decodes per row.
    selected: [1]u32 = .{0},

    // --- fault injection (the AC-s7 seams) ---------------------------------
    // SNAPSHOTTED at ls_sort_set, so the pass can create and write temp files
    // with the document mutex RELEASED without reading document state.
    temp_fail_after: u64 = std.math.maxInt(u64),
    alloc_fail_after: u64 = std.math.maxInt(u64),
    temp_ops: u64 = 0,
    allocs: u64 = 0,
    /// The document's cancel handle, so the long merge can notice an
    /// ls_sort_clear / ls_close without holding the mutex to check.
    interrupt: ?*std.atomic.Value(bool) = null,
    stop: ?*std.atomic.Value(bool) = null,

    fn deinit(self: *Build) void {
        const gpa = self.gpa;
        self.buf.deinit(gpa);
        self.offs.deinit(gpa);
        self.stage.deinit(gpa);
        self.stage_offs.deinit(gpa);
        self.th_key.deinit(gpa);
        self.runs.deinit(gpa);
        self.prefix.deinit(gpa);
        self.nav.deinit(gpa);
        self.scratch.deinit(gpa);
        self.refs.deinit(gpa);
        self.keybuf.deinit(gpa);
        if (self.cfg.sentinel.len > 0) gpa.free(self.cfg.sentinel);
        unmapAndClose(&self.perm, &self.perm_file);
        unmapAndClose(&self.inv, &self.inv_file);
        closeTemp(&self.runs_file);
        gpa.destroy(self);
    }

    /// Sort-owned RESIDENT bytes right now (contracts/api.zig
    /// `sortResidentBytes`): the key chunk + the merge read-buffers + the
    /// bounded prefix + the pass's own scratch. Deliberately a core-owned
    /// figure, not process RSS, and deliberately NOT counting the on-disk
    /// permutation/inverse mappings, which are temp storage the kernel may
    /// reclaim at will.
    fn resident(self: *const Build) u64 {
        var n: u64 = @sizeOf(Build);
        n += self.buf.capacity + self.offs.capacity * @sizeOf(SortEntry);
        n += self.stage.capacity + self.stage_offs.capacity * @sizeOf(u32);
        n += self.th_key.capacity;
        n += self.runs.capacity * @sizeOf(Run);
        n += self.prefix.items.capacity * @sizeOf(PrefixEntry) + self.prefix.key_bytes;
        n += self.prefix.sorted.capacity * @sizeOf(u32);
        n += self.nav.counts.capacity * @sizeOf(u64);
        n += self.nav.positions.capacity * @sizeOf(u64) + self.nav.columns.capacity * @sizeOf(u32);
        n += self.scratch.capacity + self.refs.capacity * @sizeOf(CellRef) + self.keybuf.capacity;
        n += self.merge_bytes;
        return n;
    }

    fn tempFiles(self: *const Build) u32 {
        var n: u32 = 0;
        if (self.runs_file != null) n += 1;
        if (self.perm_file != null) n += 1;
        if (self.inv_file != null) n += 1;
        return n;
    }

    fn tempLive(self: *const Build) u64 {
        var n: u64 = 0;
        if (self.runs_file) |f| n += f.bytes;
        if (self.perm_file) |f| n += f.bytes;
        if (self.inv_file) |f| n += f.bytes;
        return n;
    }
};

fn closeTemp(slot: *?TempFile) void {
    if (slot.*) |f| sysio.close(f.fd);
    slot.* = null;
}

fn unmapAndClose(map: *[]align(std.heap.page_size_min) u8, slot: *?TempFile) void {
    if (map.len > 0) posix.munmap(map.*);
    map.* = &.{};
    closeTemp(slot);
}

// --- allocation + temp-storage failure injection ---------------------------

/// What a pass step can fail with. `Storage` is the ephemeral temp store
/// (create/write/read); everything else is an allocation.
const PassError = error{ Storage, OutOfMemory, Interrupted };

// The two injection limits are SNAPSHOTTED onto the Build at ls_sort_set (the
// test seams set them on the document before a pass starts), so the scan and
// the merge can check them with the document mutex RELEASED.
fn allocOk(b: *Build) bool {
    if (b.allocs >= b.alloc_fail_after) return false;
    b.allocs += 1;
    return true;
}

fn tempOk(b: *Build) bool {
    if (b.temp_ops >= b.temp_fail_after) return false;
    b.temp_ops += 1;
    return true;
}

/// True when a cancel (`ls_sort_clear` / a replacing `ls_sort_set`) or
/// `ls_close` is waiting for this pass to leave its off-lock phase.
fn interrupted(b: *Build) bool {
    if (b.stop) |sp| if (sp.load(.monotonic)) return true;
    if (b.interrupt) |ip| return ip.load(.acquire);
    return false;
}

/// Create ONE ephemeral temp file through THE resolver: mode 0600, unlinked
/// immediately (never visible in its directory), never reused across opens.
fn createTemp(b: *Build, tag: []const u8) ?TempFile {
    if (!tempOk(b)) return null;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/lesssheet-sort-{s}-{x}-{x}", .{
        tempdir.resolve(), tag, sysio.uniqueToken(), @intFromPtr(b),
    }) catch return null;
    const fd = posix.openatZ(posix.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600) catch return null;
    sysio.unlinkAbsolute(path) catch {
        sysio.close(fd);
        return null;
    };
    return .{ .fd = fd };
}

fn publishTemp(d: *Document, b: *Build) void {
    d.sort_temp_files = b.tempFiles();
    d.sort_temp_live_bytes = b.tempLive();
    d.sort_temp_peak_bytes = @max(d.sort_temp_peak_bytes, d.sort_temp_live_bytes);
    d.sort_temp_mode = if (d.sort_temp_files > 0) 0o600 else 0;
    d.sort_temp_unlinked = d.sort_temp_files > 0;
}

fn publishResident(d: *Document, b: *Build) void {
    d.sort_resident_peak = @max(d.sort_resident_peak, b.resident());
}

// ===========================================================================
// The ABI bodies (api/lesssheet.h SORTED VIEWS).
// ===========================================================================

/// True while the document PRESENTS sorted coordinates: BUILDING and ACTIVE,
/// and PARKED (a frozen build). FAILED and IDLE both serve file order.
pub fn presented(d: *const Document) bool {
    return switch (d.sort_state) {
        .building, .active, .parked => true,
        .idle, .failed => false,
    };
}

/// How many view rows are SERVABLE right now (api/lesssheet.h §4): the whole
/// view once ACTIVE, the converging prefix — min(K, rows scanned) — while the
/// pass runs. Caller holds the mutex.
pub fn servableRows(d: *Document) u64 {
    if (!presented(d)) return 0;
    const b = d.sort_build orelse return 0;
    if (d.sort_state == .active) return b.rows_total;
    return @min(prefixRows(d), @as(u64, b.prefix.items.items.len));
}

/// The ORIGINAL data-row number of sorted row `i`, or null when `i` is not
/// servable — an O(1) lookup either way (the prefix structure while building,
/// the permutation once active). Caller holds the mutex.
pub fn sourceRowAt(d: *Document, i: u64) ?u64 {
    if (!presented(d)) return null;
    const b = d.sort_build orelse return null;
    if (d.sort_state == .active) {
        if (i >= b.rows_total) return null;
        const asc: u64 = if (d.sort_direction == .ascending) i else b.rows_total - 1 - i;
        return permAt(b, asc);
    }
    const order = b.prefix.ordered(b.cfg.mode, d.sort_direction);
    if (i >= order.len or i >= prefixRows(d)) return null;
    return b.prefix.items.items[order[@intCast(i)]].row;
}

fn permAt(b: *const Build, i: u64) u64 {
    const off: usize = @intCast(i * 8);
    return std.mem.readInt(u64, b.perm[off..][0..8], .little);
}

fn invAt(b: *const Build, base_index: u64) ?u64 {
    if (base_index >= b.rows_total) return null;
    const off: usize = @intCast(base_index * 8);
    return std.mem.readInt(u64, b.inv[off..][0..8], .little);
}

/// The SORTED position of the row whose PRE-SORT view index is `base_index`
/// (its filtered index under a filter, its source row otherwise), honoring the
/// requested direction. Caller holds the mutex; the sort must be ACTIVE.
pub fn sortedPosOfBase(d: *Document, base_index: u64) ?u64 {
    if (d.sort_state != .active) return null;
    const b = d.sort_build orelse return null;
    const asc = invAt(b, base_index) orelse return null;
    return if (d.sort_direction == .ascending) asc else b.rows_total - 1 - asc;
}

/// `ls_sort_set`. Validation is real before anything is touched: a rejected
/// request changes NOTHING.
pub fn setSort(d: *Document, col: u32, direction: api.SortDirection) bool {
    switch (direction) {
        .ascending, .descending => {},
    }
    d.lock();
    defer d.unlock();
    if (col >= d.column_count) return false;

    const same_column = d.sort_state != .idle and d.sort_column == col;
    // A no-op re-request of an ACTIVE or BUILDING (column, direction) changes
    // nothing at all — not even the search/jump reset (api/lesssheet.h §4).
    if (same_column and d.sort_direction == direction and
        (d.sort_state == .active or d.sort_state == .building)) return true;

    // THE FLIP, and the RE-DRIVE of a parked pass. Both keep the build: the run
    // artifacts are direction-agnostic, so flipping never re-scans the source
    // (an ACTIVE sort reads its permutation backwards; a BUILDING or PARKED one
    // re-converges its prefix from the keys ALREADY EXTRACTED), and a parked
    // pass that is re-driven continues from its own cursor rather than paying
    // for the rows it has already keyed. Both RESET search and jump — the
    // coordinate space changed, or is about to.
    if (keepableBuild(d, col) != null) {
        // `awaitScanIdle` RELEASES the mutex while it waits, and the worker can
        // take it and END the pass in that window — its Storage / allocation
        // failure arms call failBuild, which destroys this very Build. So the
        // decision is taken AGAIN on the far side of the wait, from the pointer
        // the wait itself hands back; nothing read before it is trusted after
        // it. (Found by the tools/fuzz sort target as F2: the old code decided
        // before the wait and unwrapped after it.) If the pass did fail while
        // we waited, falling through to startPass is exactly right — a request
        // on a FAILED sort re-runs it (api/lesssheet.h §4).
        if (awaitScanIdle(d)) |b| if (keepableBuild(d, col) != null) {
            if (d.sort_direction != direction) {
                d.sort_direction = direction;
                b.dir = direction;
                if (d.sort_state != .active and !rebuildPrefix(d, b)) {
                    failBuild(d, .memory);
                    resetForSortChange(d);
                    return true;
                }
            }
            if (d.sort_state == .parked) {
                d.sort_state = .building;
                if (d.worker != null) d.wakeWorker() else driveDegraded(d);
            }
            bumpGen(d);
            resetForSortChange(d);
            return true;
        };
    }

    return startPass(d, col, direction);
}

/// The build a request for `col` may KEEP (flip / re-drive) rather than
/// replace, or null when it must start a fresh pass. Returns the POINTER, so
/// no caller has to unwrap an optional it decided about earlier — the decision
/// and the pointer come from the same read, under one hold of the mutex.
/// Caller holds the mutex.
fn keepableBuild(d: *Document, col: u32) ?*Build {
    if (d.sort_state == .idle or d.sort_column != col) return null;
    return switch (d.sort_state) {
        .active, .building, .parked => d.sort_build,
        .idle, .failed => null,
    };
}

/// Both generations move together on a state change. `sort_view_gen` ALSO
/// moves whenever the converging prefix refines (see commitChunk), because a
/// served row can be DISPLACED by a smaller value found later; `sort_gen` does
/// not, so a chunk in flight can still tell "the prefix grew" from "my pass was
/// replaced".
fn bumpGen(d: *Document) void {
    d.sort_gen +%= 1;
    d.sort_view_gen +%= 1;
}

/// Every sort change the user can make RESETS any active search to
/// LS_SEARCH_IDLE and returns the jump slot to LS_JUMP_IDLE, because the
/// coordinate space changed (api/lesssheet.h §10 RESET — the filter's rule
/// applied to the third view kind). Caller holds the mutex.
fn resetForSortChange(d: *Document) void {
    // No more staging for the counters of a build that is being replaced.
    d.sort_nav_tally = false;
    d.search_filter_cum = 0;
    d.jump_state = .idle;
    d.jump_progress = 0.0;
    d.jump_landed = 0;
    d.search_state = .idle;
    d.search_nav = .none;
    d.search_progress = 0.0;
    d.search_found_row = 0;
    d.search_found_col = 0;
    d.search_position = 0;
    d.search_total = 0;
    d.search_total_exact = false;
    d.nav_pending = false;
    d.search_gen +%= 1;
    d.block_counts.clearRetainingCapacity();
    d.search_rows = 0;
    d.search_pos = d.data_start;
    // A sorted window is addressed in a coordinate space that just changed.
    d.win_request_valid = false;
}

/// Wait until the background pass is not inside a chunk, so the caller can
/// take the build apart (or re-derive its prefix) without racing it. The
/// worker publishes `sort_scan_busy` under the mutex and broadcasts when it
/// clears — and its per-row `stop`/generation checks bound the wait to one
/// row's work. Caller holds the mutex.
///
/// IT RELEASES THE MUTEX WHILE IT WAITS. Every pointer into the sort's state
/// read BEFORE a call to this is stale afterwards: the worker can take the
/// mutex in that window and end the pass, and its Storage / allocation failure
/// arms destroy the `Build` outright (`failBuild` -> `dropBuild`). That is the
/// F2 defect the fuzz sort target found, and it is why this RETURNS the build
/// as it stands AFTER the wait — a caller that wants the pointer has to take
/// it from here, and Zig makes ignoring the result an explicit `_ =`.
fn awaitScanIdle(d: *Document) ?*Build {
    if (!d.sort_scan_busy) return d.sort_build;
    d.sort_scan_interrupt.store(true, .release);
    while (d.sort_scan_busy) d.waitWork();
    d.sort_scan_interrupt.store(false, .release);
    return d.sort_build;
}

/// Start (or replace) the key pass. Caller holds the mutex.
fn startPass(d: *Document, col: u32, direction: api.SortDirection) bool {
    // Discarded on purpose: `dropBuild` re-reads the field itself and is
    // null-safe, so there is no pointer to go stale here.
    _ = awaitScanIdle(d);
    dropBuild(d);

    const cfg = captureConfig(d, col) catch {
        d.sort_column = col;
        d.sort_direction = direction;
        d.sort_state = .failed;
        d.sort_err = .memory;
        d.sort_progress = 0.0;
        bumpGen(d);
        resetForSortChange(d);
        return true;
    };

    const b = d.gpa.create(Build) catch {
        if (cfg.sentinel.len > 0) d.gpa.free(cfg.sentinel);
        d.sort_column = col;
        d.sort_direction = direction;
        d.sort_state = .failed;
        d.sort_err = .memory;
        bumpGen(d);
        resetForSortChange(d);
        return true;
    };
    b.* = .{
        .gpa = d.gpa,
        .cfg = cfg,
        .filtered = d.filter_state != .idle,
        .dir = direction,
        .pos = d.data_start,
        .selected = .{col}, // the ONE column an unfiltered pass decodes per row
        .temp_fail_after = d.sort_temp_fail_after,
        .alloc_fail_after = d.sort_alloc_fail_after,
        .interrupt = &d.sort_scan_interrupt,
        .stop = &d.stop_atomic,
    };
    // The prefix's storage is sized HERE — inside ls_sort_set, the one new call
    // the contract lets allocate — so that `ls_source_row` never has to.
    b.prefix.reserve(d.gpa, @intCast(prefixRows(d))) catch {
        b.deinit();
        d.sort_build = null;
        d.sort_column = col;
        d.sort_direction = direction;
        d.sort_state = .failed;
        d.sort_err = .memory;
        bumpGen(d);
        resetForSortChange(d);
        return true;
    };
    d.sort_build = b;
    d.sort_column = col;
    d.sort_direction = direction;
    d.sort_state = .building;
    d.sort_err = .ok;
    d.sort_progress = 0.0;
    d.sort_scanned_rows = 0;
    bumpGen(d);

    // Taking the scan slot: a scanning jump is cancelled (frontier gains kept),
    // a running filter-scan yields (counts and mode kept — the key pass
    // completes them anyway), and any active search is RESET.
    if (d.filter_state == .scanning) d.filter_state = .cancelled;
    resetForSortChange(d);

    if (d.reader.atEnd(d.source, d.data_start) or d.column_count == 0) {
        // Nothing to scan: ACTIVE immediately over an empty row set.
        b.eof = true;
        _ = finishPass(d, b, false);
        return true;
    }
    if (d.worker != null) {
        d.wakeWorker();
        return true;
    }
    driveDegraded(d);
    return true;
}

/// Degraded fallback (the worker never spawned at open): drive the pass to
/// completion on the CALLER's thread, mirroring ls_filter_set's and
/// ls_search_start's own fallbacks, so the pass always terminates instead of
/// leaving the view stuck on a prefix nothing can advance. The caller is
/// blocked here, so no other thread observes intermediate state. Caller holds
/// the mutex.
fn driveDegraded(d: *Document) void {
    // NEVER on a network document. This loop calls scanChunk — which FETCHES —
    // with the document mutex held for its whole duration, so on a network
    // source it would download the entire resource with ls_sort_clear,
    // ls_sort_poll and ls_close all blocked behind it, and no cancel able to
    // land. That is the exact wedge ls_filter_set (src/filter.zig) and
    // ls_search_nav (src/search.zig) each park against, for the reasons they
    // spell out. The sort PARKS instead: the request is kept, the poll reports
    // it, and another ls_sort_set re-drives it — which is already the
    // documented behavior of a parked pass on a network document (§8).
    if (d.net) {
        if (d.sort_state == .building) d.sort_state = .parked;
        return;
    }
    while (d.sort_state == .building) {
        const b = d.sort_build orelse break; // re-read every iteration
        if (pausedAt(d)) break; // a test pause: leave it building, as asked
        if (!runChunkLocked(d, b)) break;
    }
}

fn captureConfig(d: *Document, col: u32) !KeyConfig {
    const eff = column.effectiveType(d, col);
    var sentinel: []u8 = &.{};
    var has_sentinel = false;
    if (column.nullSentinelOf(d, col)) |s| {
        sentinel = try d.gpa.dupe(u8, s);
        has_sentinel = true;
    }
    return .{
        .column = col,
        .kind = eff.kind,
        .semantics = eff.datetime_semantics,
        .mode = keyModeFor(eff.kind),
        .sentinel = sentinel,
        .has_sentinel = has_sentinel,
    };
}

/// Release the build and every temp file with it. Caller holds the mutex and
/// has already ensured no chunk is running.
fn dropBuild(d: *Document) void {
    if (d.sort_build) |b| b.deinit();
    d.sort_build = null;
    d.sort_temp_files = 0;
    d.sort_temp_live_bytes = 0;
    d.sort_temp_mode = 0;
    d.sort_temp_unlinked = false;
}

/// `ls_sort_clear` — also the cancel verb. ZERO allocation; never fails. The
/// view RETURNS to its pre-sort file order and is fully servable again: a
/// cancelled build's converging prefix is gone, not frozen on screen.
pub fn clearSort(d: *Document) void {
    d.lock();
    defer d.unlock();
    if (d.sort_state == .idle and d.sort_build == null) return;
    _ = awaitScanIdle(d); // see startPass: dropBuild re-reads the field
    dropBuild(d);
    d.sort_state = .idle;
    d.sort_err = .ok;
    d.sort_column = 0;
    d.sort_direction = .ascending;
    d.sort_progress = 0.0;
    d.sort_scanned_rows = 0;
    bumpGen(d);
    resetForSortChange(d);
}

/// `ls_sort_poll`. ZERO allocation; never fails; never scans.
pub fn pollSort(d: *Document) api.SortStatus {
    d.lock();
    defer d.unlock();
    if (d.sort_state == .idle) return .{
        .state = .idle,
        .err = .ok,
        .column = 0,
        .direction = .ascending,
        .progress = 0.0,
    };
    return .{
        .state = d.sort_state,
        .err = d.sort_err,
        .column = d.sort_column,
        .direction = d.sort_direction,
        .progress = d.sort_progress,
    };
}

// --- Instrumentation seams (Zig-only; see contracts/api.zig) ---------------

pub fn tempStore(d: *const Document) api.SortTempStore {
    return .{
        .present = d.sort_temp_files != 0,
        .files = d.sort_temp_files,
        .live_bytes = d.sort_temp_live_bytes,
        .peak_bytes = d.sort_temp_peak_bytes,
        .mode = d.sort_temp_mode,
        .unlinked = d.sort_temp_unlinked,
    };
}

pub fn tempFailAfter(d: *Document, ops: u64) void {
    d.lock();
    defer d.unlock();
    d.sort_temp_fail_after = ops;
}

pub fn allocFailAfter(d: *Document, allocs: u64) void {
    d.lock();
    defer d.unlock();
    d.sort_alloc_fail_after = allocs;
}

pub fn residentBytes(d: *const Document) u64 {
    return d.sort_resident_peak;
}

pub fn residentReset(d: *Document) void {
    d.lock();
    defer d.unlock();
    d.sort_resident_peak = 0;
}

/// AC-s16(a) determinism seam: data rows the current key pass has scanned.
pub fn scannedRows(d: *const Document) u64 {
    return d.sort_scanned_rows;
}

/// AC-s16(a) determinism seam: stop the pass after `rows` scanned data rows and
/// wait there (maxInt restores "no limit"). Raising the limit resumes the SAME
/// pass — no re-request is needed.
pub fn pauseAfterRows(d: *Document, rows: u64) void {
    d.lock();
    d.sort_pause_after_rows = rows;
    d.wakeWorker();
    d.unlock();
}

// ===========================================================================
// The key pass.
// ===========================================================================

fn pausedAt(d: *Document) bool {
    const b = d.sort_build orelse return false;
    return b.row >= d.sort_pause_after_rows;
}

/// The worker's predicate for the sort slot (src/index.zig): a BUILDING pass
/// always drives; a PARKED one resumes on its own only under LS_INDEX_AUTO on
/// a LOCAL document (api/lesssheet.h §8). Caller holds the mutex.
pub fn wantsSlot(d: *Document) bool {
    if (d.sort_build == null) return false;
    return switch (d.sort_state) {
        .building => true,
        .parked => d.auto and !d.net,
        else => false,
    };
}

/// Park a BUILDING pass because a jump/find took the single scan slot: the
/// request is KEPT, progress FREEZES, and the converging prefix stays served,
/// exact for the region scanned so far. Caller holds the mutex.
pub fn parkForSlot(d: *Document) void {
    if (d.sort_state == .building) d.sort_state = .parked;
}

/// One step of the pass, driven by the worker with the mutex HELD on entry and
/// on return. Returns false when the pass reached a terminal state.
pub fn workerStep(d: *Document) bool {
    if (d.sort_build == null) return false;
    // `waitWork` RELEASES the mutex, so no build pointer is held across it:
    // the pause test reads the field itself, and the pointer used below is
    // taken only once no wait can intervene (F2's class — see awaitScanIdle).
    if (pausedAt(d)) {
        d.waitWork();
        return true;
    }
    if (d.sort_state == .parked) d.sort_state = .building;
    const b = d.sort_build orelse return false;
    return runChunk(d, b, true);
}

/// Drive one chunk with the lock held throughout (the degraded, no-worker
/// path).
fn runChunkLocked(d: *Document, b: *Build) bool {
    return runChunk(d, b, false);
}

const ChunkOutcome = struct {
    end_pos: Pos,
    end_row: u64,
    eof: bool = false,
    stalled: bool = false,
    interrupted: bool = false,
    err: ?api.SortError = null,
};

/// Scan + key one chunk of rows: from the build cursor up to the next index
/// block boundary, the pause limit, or EOF. `release` drops the document mutex
/// for the scan itself (the worker path) exactly as the filter-scan does.
fn runChunk(d: *Document, b: *Build, release: bool) bool {
    const gen = d.sort_gen;
    // The filter predicate the pass evaluates per row comes from the worker's
    // lock-free snapshot, refreshed here under the lock (search/filter/sort
    // never hold the slot at the same time, so the snapshot has one owner).
    if (b.filtered and d.filter_gen != d.wf_gen) {
        if (!filter_mod.refreshFilterWorkerCtx(d)) {
            failBuild(d, .memory);
            return false;
        }
        d.wf_gen = d.filter_gen;
    }
    const start_pos = b.pos;
    const start_row = b.row;
    const pause_limit = d.sort_pause_after_rows;
    const chunk_limit = chunkBytes(d);
    const faults_before = base.sourceFaultCount(d);

    if (release) {
        d.sort_scan_busy = true;
        d.unlock();
    }
    const res = scanChunk(d, b, start_pos, start_row, pause_limit, chunk_limit);
    if (release) {
        d.lock();
        d.sort_scan_busy = false;
        d.wakeWorker();
    }

    // A chunk that ran against the source-fault guard's zero-fill produced keys
    // for rows that no longer exist: discard it and let the document's existing
    // terminal vocabulary report the truncation.
    if (base.sourceFaultCount(d) != faults_before) {
        base.reportSourceFaultLocked(d);
        b.eof = true;
        return finishPass(d, b, release);
    }
    if (d.sort_gen != gen or d.sort_build != b) return false; // replaced/cleared under us
    if (res.err) |e| {
        failBuild(d, e);
        return false;
    }
    // ONE owner for the teardown: the commit only REPORTS a failure, so `b` is
    // still alive here and `failBuild` (which destroys it) runs exactly once,
    // with nothing after it touching the build.
    if (commitChunk(d, b, res)) |e| {
        failBuild(d, e);
        return false;
    }
    if (res.interrupted) return true;
    if (res.eof) return finishPass(d, b, release);
    if (res.stalled) {
        // The next bytes are not present and are not coming: end the pass at
        // the rows that ARE present rather than spinning on a zero-progress
        // cursor. The order over what was fetched is complete and honest.
        b.eof = true;
        return finishPass(d, b, release);
    }
    return true;
}

/// Lex + key one block of data rows (no lock held on the worker path). Reads
/// only through the Reader and the worker's lock-free filter snapshot.
fn scanChunk(d: *Document, b: *Build, start_pos: Pos, start_row: u64, pause_limit: u64, chunk_limit: u64) ChunkOutcome {
    var pos = start_pos;
    var row = start_row;
    const target = @min(((start_row / checkpoint_interval) + 1) * checkpoint_interval, pause_limit);
    base.beginOversizedChunk(d);
    b.stage.clearRetainingCapacity();
    b.stage_offs.clearRetainingCapacity();
    const guarded = d.source.commitGuarded();
    while (row < target) {
        if (d.stop_atomic.load(.monotonic) or d.sort_scan_interrupt.load(.acquire))
            return .{ .end_pos = pos, .end_row = row, .interrupted = true };
        if (d.reader.atEnd(d.source, pos)) return .{ .end_pos = pos, .end_row = row, .eof = true };
        const row_pos = pos;
        b.scratch.clearRetainingCapacity();
        b.refs.clearRetainingCapacity();
        // The FULL transcoded cell text, exactly as SEARCH matches it — never
        // the LS_CELL_MAX_BYTES display-capped bytes (api/lesssheet.h §2).
        // Unfiltered, only the SORT COLUMN is decoded (one record scan, no
        // per-row copy of the columns nobody keys on); a filtered pass needs
        // the whole record to evaluate the predicate.
        const m = (if (b.filtered)
            d.reader.materialize(d.source, pos, d.column_count, null, null, &b.scratch, &b.refs, b.gpa)
        else
            d.reader.materializeSelected(d.source, pos, &b.selected, std.math.maxInt(usize), null, &b.scratch, &b.refs, b.gpa)) catch
            return .{ .end_pos = pos, .end_row = row, .err = .memory };
        // A row that consumed no bytes is an un-fetched tail, never a row.
        if (base.scanStalled(d, pos, m.next)) return .{ .end_pos = pos, .end_row = row, .stalled = true };
        if (guarded) {
            const row_end = d.reader.logicalBytes(d.source, m.next);
            if (row_end > d.source.commitBound(row_end)) return .{ .end_pos = pos, .end_row = row, .stalled = true };
        }
        var take = true;
        if (b.filtered) take = matcher.matchRecord(d.wf_ctx, b.scratch.items, b.refs.items) != null;
        if (take) {
            const ref_idx: usize = if (b.filtered) b.cfg.column else 0;
            const cell: []const u8 = if (ref_idx < b.refs.items.len) blk: {
                const ref = b.refs.items[ref_idx];
                break :blk b.scratch.items[ref.start .. ref.start + ref.len];
            } else &.{};
            if (!allocOk(b)) return .{ .end_pos = pos, .end_row = row, .err = .memory };
            const group = buildKey(b.cfg, b.gpa, cell, &b.keybuf) catch
                return .{ .end_pos = pos, .end_row = row, .err = .memory };
            appendRecord(b, group, b.keybuf.items, row, b.view_rows, chunk_limit) catch |e|
                return .{ .end_pos = pos, .end_row = row, .err = switch (e) {
                    error.Storage => api.SortError.storage,
                    else => api.SortError.memory,
                } };
            b.view_rows += 1;
            b.block_matches += 1;
        }
        base.stageOversized(d, row, row_pos, m.next);
        pos = m.next;
        row += 1;
        if (d.reader.atEnd(d.source, pos)) return .{ .end_pos = pos, .end_row = row, .eof = true };
    }
    return .{ .end_pos = pos, .end_row = row };
}

/// Add one (key, row) record to the in-memory chunk, spilling the chunk as a
/// RUN first when it would exceed THE chunk knob, and staging the row as a
/// prefix candidate when it can still make the top K.
fn appendRecord(b: *Build, group: u8, key: []const u8, row: u64, bidx: u64, chunk_limit: u64) PassError!void {
    const rec: Record = .{ .group = group, .key = key, .row = row, .base = bidx, .len = 0 };
    // THE CONVERGING PREFIX: a row that cannot beat the prefix's least-good
    // member as of this chunk's start can never enter it, so the staging test
    // is one comparison and the published prefix is only touched at commit.
    if (!b.th_valid or !recWorseThanThreshold(b, rec)) {
        writeRecord(&b.stage, b.gpa, group, key, row, bidx, b.filtered) catch return error.OutOfMemory;
        b.stage_offs.append(b.gpa, @intCast(b.stage.items.len - recordLen(key.len, b.filtered))) catch return error.OutOfMemory;
    }
    const need = recordLen(key.len, b.filtered);
    const limit: usize = @intCast(@min(chunk_limit, @as(u64, std.math.maxInt(usize))));
    if (b.buf.items.len + need > limit and b.buf.items.len > 0) try spillRun(b);
    growChunk(b, b.buf.items.len + need, limit) catch return error.OutOfMemory;
    writeRecord(&b.buf, b.gpa, group, key, row, bidx, b.filtered) catch return error.OutOfMemory;
    b.offs.append(b.gpa, .{
        .off = @intCast(b.buf.items.len - need),
        .pref = keyPrefix(b.cfg.mode, group, key),
        .group = group,
    }) catch return error.OutOfMemory;
}

/// Keep the chunk buffer's CAPACITY inside the knob: grow geometrically (so a
/// small document never allocates the whole 32 MiB) but never past it, which is
/// what makes the "process memory is bounded by that chunk" claim literal.
fn growChunk(b: *Build, need: usize, limit: usize) std.mem.Allocator.Error!void {
    if (b.buf.capacity >= need) return;
    var want: usize = if (b.buf.capacity == 0) 64 * 1024 else b.buf.capacity * 2;
    while (want < need) want *= 2;
    if (want > limit and need <= limit) want = limit;
    try b.buf.ensureTotalCapacityPrecise(b.gpa, want);
}

fn recWorseThanThreshold(b: *Build, r: Record) bool {
    const th: Record = .{ .group = b.th_group, .key = b.th_key.items, .row = b.th_row, .base = 0, .len = 0 };
    return !dirLess(b.cfg.mode, b.dir, r, th);
}

/// Sort the in-memory chunk and append it to the runs file as ONE run.
fn spillRun(b: *Build) PassError!void {
    sortChunk(b);
    if (b.runs_file == null) {
        b.runs_file = createTemp(b, "run") orelse return error.Storage;
    }
    if (!tempOk(b)) return error.Storage;
    const f = &b.runs_file.?;
    const off = f.bytes;
    // Write the records in sorted order (they are permuted in `offs`, so the
    // buffer itself is not contiguous in order).
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(b.gpa);
    scratch.ensureTotalCapacity(b.gpa, b.buf.items.len) catch return error.OutOfMemory;
    for (b.offs.items) |e| {
        const r = readRecord(b.buf.items[e.off..], b.filtered);
        scratch.appendSlice(b.gpa, b.buf.items[e.off .. e.off + r.len]) catch return error.OutOfMemory;
    }
    sysio.file(f.fd).writePositionalAll(sysio.io(), scratch.items, off) catch return error.Storage;
    f.bytes += scratch.items.len;
    b.runs.append(b.gpa, .{ .off = off, .len = scratch.items.len }) catch return error.OutOfMemory;
    b.buf.clearRetainingCapacity();
    b.offs.clearRetainingCapacity();
}

const ChunkSortCtx = struct {
    b: *Build,
    fn less(self: ChunkSortCtx, x: SortEntry, y: SortEntry) bool {
        // Group, then the fixed-width prefix — two integer compares that settle
        // almost every pair without touching the record bytes. Only a genuine
        // prefix TIE (a lossy comparison) re-reads the full values, exactly as
        // api/lesssheet.h's EXACTNESS PIN requires; no hash, ever.
        if (x.group != y.group) return x.group < y.group;
        if (x.pref != y.pref) return x.pref < y.pref;
        const a = readRecord(self.b.buf.items[x.off..], self.b.filtered);
        const c = readRecord(self.b.buf.items[y.off..], self.b.filtered);
        return ascLess(self.b.cfg.mode, a, c);
    }
};

/// The chunk is always sorted ASCENDING: the run artifacts are
/// direction-agnostic, which is what makes a flip cost no re-scan.
fn sortChunk(b: *Build) void {
    const ctx: ChunkSortCtx = .{ .b = b };
    std.mem.sort(SortEntry, b.offs.items, ctx, ChunkSortCtx.less);
}

/// Fold one finished chunk into the document under the mutex: the prefix, the
/// scan cursor, the shared frontier, the filter's counters, and progress.
///
/// REPORTS failure rather than acting on it. `failBuild` destroys the `Build`,
/// and the caller keeps using it after this returns — so exactly ONE owner
/// (`runChunk`) may tear the build down, and it does that only after this
/// function has handed control back.
fn commitChunk(d: *Document, b: *Build, res: ChunkOutcome) ?api.SortError {
    // 1. The converging prefix: merge this chunk's staged candidates.
    for (b.stage_offs.items) |o| {
        const r = readRecord(b.stage.items[o..], b.filtered);
        if (!allocOk(b)) return .memory;
        if (!b.prefix.push(b.gpa, b.cfg.mode, b.dir, @intCast(prefixRows(d)), r)) return .memory;
    }
    b.stage.clearRetainingCapacity();
    b.stage_offs.clearRetainingCapacity();
    snapshotThreshold(d, b);
    // What the view SHOWS just changed (the prefix refined, or grew), so a
    // window materialized against the previous one must be rebuilt, not
    // extended.
    d.sort_view_gen +%= 1;

    // 2. The scan cursor.
    b.pos = res.end_pos;
    b.row = res.end_row;
    b.eof = res.eof;
    d.sort_scanned_rows = res.end_row;

    // 3. The SHARED frontier, exactly like a filter-scan: gains are paid once.
    const advancing = d.reader.bytesConsumed(d.source, res.end_pos) > d.reader.bytesConsumed(d.source, d.frontier_pos);
    if (advancing) {
        d.frontier_pos = res.end_pos;
        d.frontier_rows = res.end_row;
        if (res.end_row % checkpoint_interval == 0 and res.end_row > 0) {
            d.checkpoints.append(d.gpa, .{ .row = res.end_row, .pos = res.end_pos }) catch {
                d.complete = true;
                d.total_rows = d.frontier_rows;
            };
        }
    }
    base.drainOversized(d, advancing);

    // 4. The filter's own counters: the key pass drives an incomplete
    //    filter-scan to LS_FILTER_DONE as a side effect (api/lesssheet.h §3).
    //    Only WHOLE blocks may be appended — `filter_block_counts[i]` IS block
    //    i — so a pause inside a block carries its matches forward in
    //    `block_matches`, and a block the filter-scan had ALREADY counted
    //    (the pass restarts from row 0 while the filter's cursor sits further
    //    on) is dropped rather than double-counted.
    if (res.end_row % checkpoint_interval == 0 or res.eof) {
        if (b.filtered and d.filter_state != .idle and
            b.fold_from == d.filter_rows and res.end_row > d.filter_rows)
        {
            d.filter_block_counts.append(d.gpa, b.block_matches) catch {};
            d.filter_total +%= b.block_matches;
            d.filter_rows = res.end_row;
            d.filter_pos = res.end_pos;
            d.filter_progress = base.searchProgress(d, res.end_pos);
        }
        b.block_matches = 0;
        b.fold_from = res.end_row;
    }

    // 5. Progress: the fraction of the pass's work covered so far, monotone
    //    within one build and exactly 1.0 only at ACTIVE.
    if (!res.eof) {
        const p = base.searchProgress(d, res.end_pos);
        if (p > d.sort_progress and p < 1.0) d.sort_progress = p;
    }
    publishTemp(d, b);
    publishResident(d, b);
    return null;
}

/// Remember the prefix's least-good member so the next chunk can stage
/// candidates lock-free.
fn snapshotThreshold(d: *Document, b: *Build) void {
    const cap: usize = @intCast(prefixRows(d));
    if (b.prefix.items.items.len < cap) {
        b.th_valid = false;
        return;
    }
    const root = b.prefix.items.items[0];
    b.th_key.clearRetainingCapacity();
    b.th_key.appendSlice(b.gpa, root.key) catch {
        b.th_valid = false;
        return;
    };
    b.th_group = root.group;
    b.th_row = root.row;
    b.th_valid = true;
}

/// Re-derive the converging prefix for the CURRENT direction from the keys
/// ALREADY EXTRACTED — the in-memory chunk plus every spilled run. This is what
/// a direction flip while BUILDING costs: no source re-scan, no progress
/// regression. Caller holds the mutex and has ensured no chunk is running.
fn rebuildPrefix(d: *Document, b: *Build) bool {
    b.prefix.clear(b.gpa);
    b.th_valid = false;
    const cap: usize = @intCast(prefixRows(d));
    for (b.offs.items) |e| {
        const r = readRecord(b.buf.items[e.off..], b.filtered);
        if (!b.prefix.push(b.gpa, b.cfg.mode, b.dir, cap, r)) return false;
    }
    for (b.runs.items) |run| {
        var it = RunReader.init(b, run, mergeBufferBytes(chunkBytes(d), b.runs.items.len)) catch return false;
        defer it.deinit(b.gpa);
        while (it.next(b) catch return false) |r| {
            if (!b.prefix.push(b.gpa, b.cfg.mode, b.dir, cap, r)) return false;
        }
    }
    snapshotThreshold(d, b);
    return true;
}

// ===========================================================================
// The external merge: runs -> the permutation + the inverse mapping.
// ===========================================================================

/// A buffered forward reader over one spilled run. Its buffer is DERIVED from
/// the one chunk knob (see `mergeBufferBytes`), never independently sized.
const RunReader = struct {
    fd: posix.fd_t,
    off: u64,
    end: u64,
    buf: []u8,
    len: usize = 0,
    cur: usize = 0,

    fn init(b: *Build, run: Run, buf_bytes: usize) PassError!RunReader {
        const f = b.runs_file orelse return error.Storage;
        const buf = try b.gpa.alloc(u8, @max(buf_bytes, 4096));
        return .{ .fd = f.fd, .off = run.off, .end = run.off + run.len, .buf = buf };
    }

    fn deinit(self: *RunReader, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
    }

    /// The next record, or null at the run's end. Records never straddle the
    /// buffer: a partial tail is compacted to the front and refilled.
    fn next(self: *RunReader, b: *Build) PassError!?Record {
        while (true) {
            if (self.cur + 5 <= self.len) {
                const klen: usize = std.mem.readInt(u32, self.buf[self.cur + 1 ..][0..4], .little);
                const need = recordLen(klen, b.filtered);
                if (self.cur + need <= self.len) {
                    const r = readRecord(self.buf[self.cur..], b.filtered);
                    self.cur += need;
                    return r;
                }
                if (need > self.buf.len) {
                    // One pathological key is larger than the read buffer: grow
                    // to fit it (an outlier budget, never the steady state).
                    const grown = try b.gpa.realloc(self.buf, need);
                    self.buf = grown;
                }
            }
            if (!try self.refill()) return null;
        }
    }

    fn refill(self: *RunReader) PassError!bool {
        const rest = self.len - self.cur;
        if (rest > 0) std.mem.copyForwards(u8, self.buf[0..rest], self.buf[self.cur..self.len]);
        self.len = rest;
        self.cur = 0;
        if (self.off >= self.end) return rest > 0;
        const want: usize = @intCast(@min(@as(u64, self.buf.len - self.len), self.end - self.off));
        if (want == 0) return rest > 0;
        const got = sysio.file(self.fd).readPositionalAll(sysio.io(), self.buf[self.len .. self.len + want], self.off) catch return error.Storage;
        if (got == 0) return rest > 0;
        self.off += got;
        self.len += got;
        return true;
    }
};

/// Merge read-buffers are DERIVED from the ONE knob: the whole merge reads at
/// most one chunk's worth of run bytes at a time, however many runs there are.
fn mergeBufferBytes(chunk_limit: u64, runs: usize) usize {
    const per = chunk_limit / @as(u64, @max(runs, 1));
    return @intCast(@max(@min(per, 1 << 20), 4096));
}

/// Finish the pass: merge every run into the ascending permutation, build the
/// inverse mapping beside it, and publish LS_SORT_ACTIVE.
///
/// THE MERGE RUNS OFF-LOCK (when `release`, i.e. on the worker). It is the one
/// phase whose cost is O(rows) rather than O(chunk) — seconds on a 10 GB
/// document — and holding the document mutex across it would freeze every
/// poll, window read and ls_close for its whole duration. It is guarded by the
/// same `sort_scan_busy` handshake a scan chunk uses, so a concurrent
/// ls_sort_clear / ls_sort_set still waits for a consistent point instead of
/// racing the build, and it checks the interrupt flag as it goes so that wait
/// is short. Caller holds the mutex on entry and on return. Returns false (the
/// pass is over) in every case.
fn finishPass(d: *Document, b: *Build, release: bool) bool {
    const chunk_limit = chunkBytes(d);
    const gen = d.sort_gen;
    if (release) {
        d.sort_scan_busy = true;
        d.unlock();
    }
    const outcome = mergeAll(b, chunk_limit);
    if (release) {
        d.lock();
        d.sort_scan_busy = false;
        d.wakeWorker();
        // The busy flag is what makes `b` safe across the release above (every
        // teardown waits for it), but the invariant is re-checked LOCALLY
        // rather than inherited from the caller — the F2 class is exactly a
        // pointer trusted across a window someone else was supposed to guard.
        if (d.sort_gen != gen or d.sort_build != b) return false;
    }
    if (outcome) |_| {
        b.rows_total = b.view_rows;
        d.sort_state = .active;
        d.sort_err = .ok;
        d.sort_progress = 1.0;
        d.sort_scanned_rows = b.row;
        // The pass reached EOF, so the index is complete and the row count is
        // exact — and an incomplete filter's counters are complete with it.
        if (b.eof or d.reader.atEnd(d.source, b.pos)) {
            d.complete = true;
            d.total_rows = d.frontier_rows;
            // The pass reached EOF over the same row set the filter counts, so
            // its counters are final however incomplete they were (the last
            // partial block was folded by commitChunk's EOF branch).
            if (b.filtered and d.filter_state != .idle and d.filter_rows >= b.row) {
                d.filter_state = .done;
                d.filter_total_exact = true;
                d.filter_progress = 1.0;
            }
        }
        // The scratch that only the SCAN needed is released the moment the
        // scan is over, so an ACTIVE sort retains only its two mappings.
        b.buf.clearAndFree(b.gpa);
        b.offs.clearAndFree(b.gpa);
        b.stage.clearAndFree(b.gpa);
        b.stage_offs.clearAndFree(b.gpa);
        b.scratch.clearAndFree(b.gpa);
        b.refs.clearAndFree(b.gpa);
        b.prefix.clear(b.gpa);
        b.merge_bytes = 0;
        closeTemp(&b.runs_file);
        b.runs.clearAndFree(b.gpa);
        publishTemp(d, b);
        publishResident(d, b);
        // FIND UNDER A SORT: the inverse mapping now exists, so a search that
        // starts from here on can have its per-sorted-block counters tallied by
        // its own scan (ARCH FR7).
        navResetLocked(d, d.search_gen);
        // A jump or a find issued while the sort was building resolves HERE —
        // the finished order is what both were waiting for.
        resolveJumpLocked(d);
        @import("search.zig").resolveNavLocked(d);
        return false;
    } else |e| switch (e) {
        // Interrupted == a cancel or a replacement is already waiting on the
        // mutex we just re-took; it owns the teardown, so leave the build
        // exactly as it is and stop driving.
        error.Interrupted => return false,
        error.Storage => failBuild(d, .storage),
        error.OutOfMemory => failBuild(d, .memory),
    }
    return false;
}

fn mergeAll(b: *Build, chunk_limit: u64) PassError!void {
    // The final partial chunk: spill it only when runs already exist. A
    // document whose pairs fit ONE chunk touches no disk for runs at all.
    if (b.runs.items.len > 0 and b.buf.items.len > 0) {
        try spillRun(b);
    } else {
        sortChunk(b);
    }
    // Nothing past this point stages prefix candidates, and once every record
    // is in a run the chunk buffer is dead weight: release both BEFORE the
    // merge allocates its read-buffers, so the build's peak residency is
    // "chunk + prefix" during the scan and "prefix + merge buffers" during the
    // merge, never the sum of all four.
    b.stage.clearAndFree(b.gpa);
    b.stage_offs.clearAndFree(b.gpa);
    b.th_key.clearAndFree(b.gpa);
    if (b.runs.items.len > 0) {
        b.buf.clearAndFree(b.gpa);
        b.offs.clearAndFree(b.gpa);
    }

    const m = b.view_rows;
    b.perm_file = createTemp(b, "perm") orelse return error.Storage;
    b.inv_file = createTemp(b, "inv") orelse return error.Storage;
    const bytes: u64 = @max(m * 8, 8); // never map an empty region
    sysio.file(b.perm_file.?.fd).setLength(sysio.io(), bytes) catch return error.Storage;
    sysio.file(b.inv_file.?.fd).setLength(sysio.io(), bytes) catch return error.Storage;
    b.perm_file.?.bytes = m * 8;
    b.inv_file.?.bytes = m * 8;
    b.perm = posix.mmap(null, @intCast(bytes), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, b.perm_file.?.fd, 0) catch return error.Storage;
    b.inv = posix.mmap(null, @intCast(bytes), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, b.inv_file.?.fd, 0) catch return error.Storage;

    if (m == 0) return;

    if (b.runs.items.len == 0) {
        // Single in-memory chunk: no k-way merge, no run file.
        var i: u64 = 0;
        for (b.offs.items) |e| {
            const r = readRecord(b.buf.items[e.off..], b.filtered);
            emit(b, i, r);
            i += 1;
        }
        return;
    }
    return kWayMerge(b, chunk_limit);
}

fn emit(b: *Build, i: u64, r: Record) void {
    const off: usize = @intCast(i * 8);
    std.mem.writeInt(u64, b.perm[off..][0..8], r.row, .little);
    if (r.base < b.view_rows) {
        const ioff: usize = @intCast(r.base * 8);
        std.mem.writeInt(u64, b.inv[ioff..][0..8], i, .little);
    }
}

fn kWayMerge(b: *Build, chunk_limit: u64) PassError!void {
    const n = b.runs.items.len;
    const buf_bytes = mergeBufferBytes(chunk_limit, n);
    var readers = try b.gpa.alloc(RunReader, n);
    defer b.gpa.free(readers);
    var made: usize = 0;
    defer for (readers[0..made]) |*rr| rr.deinit(b.gpa);
    while (made < n) : (made += 1) readers[made] = try RunReader.init(b, b.runs.items[made], buf_bytes);
    b.merge_bytes = @as(u64, buf_bytes) * @as(u64, n);

    // A simple selection merge over the run heads: k is bounded by
    // (total keys / chunk), so the per-record cost stays small and the code
    // stays obvious. Heads live in `head`, refilled from their reader.
    var heads = try b.gpa.alloc(?Record, n);
    defer b.gpa.free(heads);
    for (0..n) |i| heads[i] = try readers[i].next(b);
    // A binary MIN-heap over the run heads, not a linear scan over them: with a
    // 32 MiB chunk a 10 GB document spills on the order of a hundred runs, and
    // picking the smallest head by scanning them all would cost O(runs) per
    // ROW — hundreds of times the work of the whole key extraction. This is
    // O(log runs) per row.
    var heap = try b.gpa.alloc(usize, n);
    defer b.gpa.free(heap);
    var hn: usize = 0;
    for (0..n) |i| {
        if (heads[i] == null) continue;
        heap[hn] = i;
        hn += 1;
    }
    const H = struct {
        fn less(bb: *Build, hs: []const ?Record, x: usize, y: usize) bool {
            return ascLess(bb.cfg.mode, hs[x].?, hs[y].?);
        }
        fn up(bb: *Build, hs: []const ?Record, hp: []usize, start: usize) void {
            var i = start;
            while (i > 0) {
                const p = (i - 1) / 2;
                if (!less(bb, hs, hp[i], hp[p])) break;
                std.mem.swap(usize, &hp[i], &hp[p]);
                i = p;
            }
        }
        fn down(bb: *Build, hs: []const ?Record, hp: []usize, len: usize) void {
            var i: usize = 0;
            while (true) {
                const l = 2 * i + 1;
                if (l >= len) break;
                var m = l;
                const r = l + 1;
                if (r < len and less(bb, hs, hp[r], hp[m])) m = r;
                if (!less(bb, hs, hp[m], hp[i])) break;
                std.mem.swap(usize, &hp[i], &hp[m]);
                i = m;
            }
        }
    };
    var i: usize = 0;
    while (i < hn) : (i += 1) H.up(b, heads, heap[0 .. i + 1], i);
    var out: u64 = 0;
    while (hn > 0) {
        const bi = heap[0];
        emit(b, out, heads[bi].?);
        out += 1;
        // A cancel must not wait out a multi-second merge (checked per block of
        // rows, so the check itself costs nothing).
        if (out % 65536 == 0 and interrupted(b)) return error.Interrupted;
        heads[bi] = try readers[bi].next(b);
        if (heads[bi] == null) {
            hn -= 1;
            heap[0] = heap[hn];
        }
        H.down(b, heads, heap[0..hn], hn);
    }
}

/// A key pass that cannot finish ends LS_SORT_FAILED at a consistent point: the
/// view RETURNS TO ITS PRE-SORT FILE ORDER and is fully servable again, the
/// REQUEST is retained so the frontend can render it and retry, and no temp
/// file or thread is leaked. Caller holds the mutex.
fn failBuild(d: *Document, err: api.SortError) void {
    dropBuild(d);
    d.sort_state = .failed;
    d.sort_err = err;
    bumpGen(d);
    d.win_request_valid = false;
    // A jump that was waiting for this sort can never land through it.
    if (d.jump_state == .scanning) {
        d.jump_state = .idle;
        d.jump_progress = 0.0;
    }
}

// ===========================================================================
// Rebuilds: the sort intent survives its inputs changing (api/lesssheet.h §9).
// ===========================================================================

/// A filter change, or a type-override / null-sentinel change ON THE SORT
/// COLUMN, invalidates the permutation: the request PERSISTS and the pass
/// re-runs automatically, presenting the REBUILD's converging prefix
/// immediately. Caller holds the mutex.
pub fn rebuildForInputChange(d: *Document, column_changed: ?u32) void {
    if (d.sort_state == .idle) return;
    if (column_changed) |c| if (c != d.sort_column) return;
    const col = d.sort_column;
    const dir = d.sort_direction;
    _ = startPass(d, col, dir);
}

// ===========================================================================
// Jump under a sort (api/lesssheet.h §6).
// ===========================================================================

/// `ls_jump_start` while a sort is PRESENTED. `target_row` is an ORIGINAL
/// data-row number; the landing is that row's SORTED position. Caller holds
/// the mutex. Returns true when it handled the jump.
pub fn jumpStartSorted(d: *Document, target_row: u64) bool {
    if (!presented(d)) return false;
    if (d.sort_state == .active) {
        resolveJumpTargetLocked(d, target_row);
        return true;
    }
    // No honest partial answer exists: the sorted position of one arbitrary
    // source row is not knowable from a prefix. Report SCANNING and let the
    // sort's own completion resolve it — and, per §8, the jump taking the slot
    // PARKS the build (its prefix stays served, frozen at what it reached).
    //
    // EXCEPT where parking would be a lie: under LS_INDEX_AUTO on a LOCAL
    // document §8 says a parked pass "RESUMES on its own ... whatever
    // jumps/finds intervene", and the pass is also the only thing that can
    // answer this jump. There the pass never actually yields, so reporting a
    // park the caller could observe would describe a state the core is not in.
    // Everywhere a park is real — MANUAL, or a network document, where the
    // build genuinely stops until an ls_sort_set re-drives it — it is reported.
    if (d.worker == null) {
        // Degraded: nothing else can ever advance the pass, so a jump that
        // waits for it would wait forever. Drive it here (bounded by the
        // document) and land through the mapping it produces — the same
        // fail-open spirit as the unsorted degraded jump, without inventing a
        // sorted position the core does not have.
        if (d.sort_state == .parked) d.sort_state = .building;
        driveDegraded(d);
        if (d.sort_state == .active) {
            resolveJumpTargetLocked(d, target_row);
            return true;
        }
        d.jump_state = .done;
        d.jump_progress = 1.0;
        d.jump_landed = 0;
        return true;
    }
    if (!(d.auto and !d.net)) parkForSlot(d);
    d.jump_state = .scanning;
    d.jump_target = target_row;
    d.jump_start_rows = d.frontier_rows;
    d.jump_progress = 0.0;
    d.wakeWorker();
    return true;
}

/// Resolve a pending jump once the sort is ACTIVE. Caller holds the mutex.
pub fn resolveJumpLocked(d: *Document) void {
    if (d.sort_state != .active or d.jump_state != .scanning) return;
    resolveJumpTargetLocked(d, d.jump_target);
}

fn resolveJumpTargetLocked(d: *Document, target_row: u64) void {
    const b = d.sort_build orelse return;
    d.jump_progress = 1.0;
    d.jump_state = .done;
    if (b.rows_total == 0) {
        d.jump_landed = 0;
        return;
    }
    // Composition rules are unchanged and applied in SOURCE space FIRST, then
    // mapped: under a filter the target resolves to the first MATCHING source
    // row >= target_row, and a target at/past EOF clamps to the last row.
    var base_index: u64 = 0;
    if (b.filtered and d.filter_state != .idle) {
        const fctx = filter_mod.filterCtx(d);
        var found = false;
        if (target_row < d.filter_rows) {
            if (nav.findForwardMatch(d, d.filter_block_counts.items, null, fctx, target_row, d.filter_rows)) |m| {
                base_index = nav.positionOf(d, d.filter_block_counts.items, null, fctx, m.row) - 1;
                found = true;
            }
        }
        if (!found) base_index = b.rows_total - 1;
    } else {
        base_index = @min(target_row, b.rows_total - 1);
    }
    d.jump_landed = sortedPosOfBase(d, base_index) orelse 0;
}

// ===========================================================================
// FIND UNDER A SORT — the tally, and the navigation over it.
// ===========================================================================

/// True while the match-scan should stage its matches for the tally below: a
/// sort is ACTIVE (so the inverse mapping exists) and the counters belong to
/// the search now running. Recomputed at ls_search_start / when the sort lands.
pub fn navTallyWantedLocked(d: *Document) bool {
    const b = d.sort_build orelse return false;
    return d.sort_state == .active and b.nav.search_gen == d.search_gen;
}

/// Point the counters at `search_gen` and clear them (ls_search_start, and the
/// moment a sort becomes ACTIVE). Caller holds the mutex.
pub fn navResetLocked(d: *Document, search_gen: u64) void {
    d.search_filter_cum = 0;
    d.sort_nav_tally = false;
    const b = d.sort_build orelse return;
    b.nav.reset(search_gen);
    // Only a scan that starts at row 0 can produce COMPLETE counters. A sort
    // that lands mid-search leaves them off, and the navigation rebuilds them
    // with one pass instead of trusting a tally that missed the early blocks.
    d.sort_nav_tally = navTallyWantedLocked(d) and d.search_rows == 0;
}

/// Allocate the counter array (one entry per sorted-position block, ZEROED)
/// the first time it is needed. `rows_total` is fixed once the sort is ACTIVE,
/// so this happens exactly once per search. Returns false on OOM, having left
/// the tally disabled rather than partial — a navigation would rather rebuild
/// the counters than answer from half of them.
fn navEnsureCounts(d: *Document, b: *Build) bool {
    const nblocks: usize = @intCast((b.rows_total + checkpoint_interval - 1) / checkpoint_interval);
    if (b.nav.counts.items.len == nblocks) return true;
    b.nav.counts.clearRetainingCapacity();
    b.nav.counts.appendNTimes(b.gpa, 0, nblocks) catch {
        d.sort_nav_tally = false;
        b.nav.reset(d.search_gen);
        return false;
    };
    return true;
}

/// Tally counters that were NOT built by the match-scan (the corner case where
/// the search finished while the sort was still building, so no inverse mapping
/// existed at the time). `bases` is the complete set for one block of the
/// counted region. Caller holds the mutex.
pub fn navTallyRebuildLocked(d: *Document, bases: []const u64) bool {
    const b = d.sort_build orelse return false;
    if (d.sort_state != .active) return false;
    if (b.nav.search_gen != d.search_gen) b.nav.reset(d.search_gen);
    if (!navEnsureCounts(d, b)) return false;
    for (bases) |base_index| {
        const p = sortedPosOfBase(d, base_index) orelse continue;
        const blk: usize = @intCast(p / checkpoint_interval);
        if (blk < b.nav.counts.items.len) b.nav.counts.items[blk] += 1;
    }
    return true;
}

/// Mark a rebuilt tally complete. Caller holds the mutex.
pub fn navMarkReadyLocked(d: *Document) void {
    const b = d.sort_build orelse return;
    if (b.nav.search_gen != d.search_gen) return;
    b.nav.ready = true;
    b.nav.block_ready = false;
}

/// ARCH FR7: fold one committed chunk's matches into the per-SORTED-block
/// counters, one inverse-mapping lookup each. Caller holds the mutex.
///
/// COMPLETE OR NOTHING. Counters that are short by even one match are worse
/// than no counters at all: every later `position` shifts, and a block whose
/// only match went missing is skipped outright, so a real row becomes
/// unreachable by navigation — a wrong answer, not a slow one. So the tally
/// carries its own evidence and verifies its own coverage:
///   * `complete` — the chunk staged every match it found (the caller's
///     snapshot of the flag was on, and no staging append failed);
///   * `start_row == tallied_rows` — this chunk begins exactly where the tally
///     left off, so no row between them went uncounted (a chunk that ran while
///     the flag was off, or a cursor that was re-entered, is caught here).
/// Anything else turns the tally OFF and resets it, and the navigation falls
/// back to `buildSortedCounters` — one pass, already written, already the path
/// used when a search finishes before its sort does.
pub fn navTallyLocked(d: *Document, bases: []const u64, complete: bool, start_row: u64, end_row: u64) void {
    if (!d.sort_nav_tally) return;
    const b = d.sort_build orelse return;
    if (b.nav.search_gen != d.search_gen or d.sort_state != .active) return;
    if (!complete or b.nav.tallied_rows != start_row) {
        d.sort_nav_tally = false;
        b.nav.reset(d.search_gen);
        return;
    }
    if (!navEnsureCounts(d, b)) return; // already disabled + reset inside
    for (bases) |base_index| {
        const p = sortedPosOfBase(d, base_index) orelse continue;
        const blk: usize = @intCast(p / checkpoint_interval);
        if (blk < b.nav.counts.items.len) b.nav.counts.items[blk] += 1;
    }
    b.nav.tallied_rows = end_row;
    b.nav.ready = true;
    b.nav.block_ready = false;
}

/// The counters, if they describe THIS search and are complete. Caller holds
/// the mutex.
fn navReady(d: *Document) ?*NavIndex {
    const b = d.sort_build orelse return null;
    if (d.sort_state != .active) return null;
    if (!b.nav.ready or b.nav.search_gen != d.search_gen) return null;
    return &b.nav;
}

/// A navigation plan: everything the off-lock resolver needs, snapshotted under
/// the mutex.
pub const NavPlan = struct {
    block: u64,
    lo: u64,
    hi: u64,
    before: u64,
    cached: bool,
};

/// Pick the sorted-position BLOCK that must be examined for this navigation,
/// skipping every block the counters say is empty. Null == no match in that
/// direction (EXHAUSTED). Caller holds the mutex.
pub fn navPlanLocked(d: *Document, anchor: u64, forward: bool) ?NavPlan {
    const nav_idx = navReady(d) orelse return null;
    const b = d.sort_build orelse return null;
    const nblocks = nav_idx.counts.items.len;
    if (nblocks == 0) return null;
    var before: u64 = 0;
    if (forward) {
        var blk: usize = @intCast(@min(anchor / checkpoint_interval, nblocks - 1));
        for (0..blk) |i| before += nav_idx.counts.items[i];
        while (blk < nblocks) : (blk += 1) {
            if (nav_idx.counts.items[blk] != 0) break;
            before += nav_idx.counts.items[blk];
        }
        if (blk >= nblocks) return null;
        // A block at/after the anchor's own block can hold matches BEFORE the
        // anchor; the resolver filters those out and, if none remain, asks
        // again from the next block.
        const lo: u64 = @as(u64, blk) * checkpoint_interval;
        return .{
            .block = blk,
            .lo = lo,
            .hi = @min(lo + checkpoint_interval, b.rows_total),
            .before = before,
            .cached = nav_idx.block_ready and nav_idx.block == blk,
        };
    }
    if (anchor == 0) return null; // nothing is strictly before position 0
    var blk: usize = @intCast(@min((anchor - 1) / checkpoint_interval, nblocks - 1));
    while (true) {
        if (nav_idx.counts.items[blk] != 0) break;
        if (blk == 0) return null;
        blk -= 1;
    }
    for (0..blk) |i| before += nav_idx.counts.items[i];
    const lo: u64 = @as(u64, blk) * checkpoint_interval;
    return .{
        .block = blk,
        .lo = lo,
        .hi = @min(lo + checkpoint_interval, b.rows_total),
        .before = before,
        .cached = nav_idx.block_ready and nav_idx.block == blk,
    };
}

/// The cached block scan, when it is the block this plan needs. Caller holds
/// the mutex; the slices belong to the build and stay valid under it.
pub fn navCachedBlock(d: *Document, plan: NavPlan) ?struct { positions: []const u64, columns: []const u32 } {
    const nav_idx = navReady(d) orelse return null;
    if (!nav_idx.block_ready or nav_idx.block != plan.block) return null;
    return .{ .positions = nav_idx.positions.items, .columns = nav_idx.columns.items };
}

/// Publish a freshly scanned block. Caller holds the mutex.
pub fn navPublishBlock(d: *Document, plan: NavPlan, positions: []const u64, columns: []const u32) void {
    const nav_idx = navReady(d) orelse return;
    const b = d.sort_build orelse return;
    nav_idx.positions.clearRetainingCapacity();
    nav_idx.columns.clearRetainingCapacity();
    nav_idx.positions.appendSlice(b.gpa, positions) catch return;
    nav_idx.columns.appendSlice(b.gpa, columns) catch {
        nav_idx.positions.clearRetainingCapacity();
        return;
    };
    nav_idx.block = plan.block;
    nav_idx.before = plan.before;
    nav_idx.block_ready = true;
}

/// The ORIGINAL row a SORTED position maps to, for the ACTIVE permutation.
/// Caller holds the mutex.
pub fn sourceRowOfPosition(d: *Document, p: u64) ?u64 {
    return sourceRowAt(d, p);
}

/// True when the counters exist for this search — i.e. the match-scan tallied
/// them as it went, so a navigation needs no sweep of its own. Caller holds the
/// mutex.
pub fn navHasCounters(d: *Document) bool {
    return navReady(d) != null;
}

// ===========================================================================
// ls_close / freeDoc.
// ===========================================================================

/// Release the build (the worker is already joined, or never spawned).
pub fn freeSort(d: *Document) void {
    if (d.sort_build) |b| b.deinit();
    d.sort_build = null;
}
