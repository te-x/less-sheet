//! The Reader interface: the format→rows/cells parser the format-agnostic
//! core (window/index/nav/search/filter — the C ABI in root.zig) calls
//! INSTEAD of a format's own parser directly (see docs/architecture/
//! ARCH-reader-interface.md). CSV (src/csv_reader.zig) is the only member in
//! this slice; a future Parquet or ODS/XLSX Reader would add a sibling
//! variant to the `Reader` union below with NO change to window/index/nav/
//! search/filter/root — see the AC5 note at the bottom of csv_reader.zig.
//!
//! The row `Pos` a Reader hands back (from `boundsAfter`/`materialize`) is
//! OPAQUE to every caller outside `src/csv_reader.zig`: a non-arithmetic
//! handle (Zig's open/non-exhaustive-enum pattern — `+`, `-`, `<`, `>` don't
//! even compile on it) that the core only ever obtains from, and passes back
//! to, a Reader op, or stores verbatim in a `base.Checkpoint`/`nav.SourceLoc`.
//! For the CSV Reader it happens to be a byte offset into the `Source` (src/
//! source.zig); a Parquet Reader would encode a (row-group, in-group index)
//! pair instead, and an XML (ODS/XLSX) Reader an offset plus parser-state
//! token — see ARCH-reader-interface AC5. Nothing outside `csv_reader.zig`
//! may assume otherwise; every core call site treats `Pos` as a value to
//! store/compare-for-equality/hand back, never to compute from scratch
//! (except via `start`/`posAtByteBudget` below, which hand back a fresh,
//! still-opaque `Pos` for a byte BUDGET the ABI itself pins — see api/
//! lesssheet.h `LS_OPEN_HEAD_MAX_BYTES` / `LS_WINDOW_ROW_SCAN_MAX_BYTES`).

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");
const source_mod = @import("source.zig");
const csv_reader = @import("csv_reader.zig");

pub const Source = source_mod.Source;
pub const CellRef = base.CellRef;

/// Opaque row position — see the module doc. Backed by a `u64` so a Reader
/// implementation can cast it to/from a byte offset (or whatever else)
/// internally, but the type itself supports only equality outside
/// `csv_reader.zig` — no arithmetic, no ordering.
pub const Pos = enum(u64) { _ };

pub const BoundsResult = struct { next: Pos, capped: bool };
pub const MaterializeResult = struct { next: Pos, capped: bool };
pub const CellResult = struct { len: usize, truncated: bool };

/// A pluggable format Reader. One tagged-union variant per format — CSV is
/// the only member in this slice (see csv_reader.CsvReader). Every op takes
/// the `Source` explicitly (a Reader never owns one), so the same Reader
/// value could serve different byte providers across calls (e.g. CSV over
/// an mmap Source today, CSV over a future gzip Source for csv.gz, with no
/// change here).
///
/// Dispatch is a single `switch` per call — no vtable, no heap indirection.
/// With one variant this costs at most one (trivially-predicted, often
/// wholly-elided) branch; see the reorg's perf spot-check for the measured
/// window/index/nav hot-path cost (unchanged vs. calling `lexer` directly).
pub const Reader = union(enum) {
    csv: csv_reader.CsvReader,

    /// The position of the very first row (byte 0 of `source` for CSV).
    pub fn start(self: Reader, source: Source) Pos {
        return switch (self) {
            .csv => |r| r.start(source),
        };
    }

    /// True iff `pos` is at/past the end of `source` (no more rows there).
    pub fn atEnd(self: Reader, source: Source, pos: Pos) bool {
        return switch (self) {
            .csv => |r| r.atEnd(source, pos),
        };
    }

    /// The position reached after advancing at most `budget` SOURCE bytes
    /// from `from`, clamped to the end of `source`. Both the O(head) open
    /// budget (index.headSourceLimit) and the per-row window-scan cap
    /// (window.zig / nav.zig, `LS_WINDOW_ROW_SCAN_MAX_BYTES`) are expressed
    /// this way, so the core never computes a position by arithmetic itself
    /// — it hands the Reader a plain byte COUNT (the ABI's own budget
    /// constant) and gets an opaque `Pos` back.
    pub fn posAtByteBudget(self: Reader, source: Source, from: Pos, budget: u64) Pos {
        return switch (self) {
            .csv => |r| r.posAtByteBudget(source, from, budget),
        };
    }

    /// SOURCE bytes conceptually consumed reaching `pos` — feeds the
    /// byte-denominated ABI progress fields (`ls_index_poll`, the row-count
    /// estimate) and the oversized-row size test (base.stageOversized).
    /// CSV: `pos` IS the byte count (an identity conversion).
    pub fn bytesConsumed(self: Reader, source: Source, pos: Pos) u64 {
        return switch (self) {
            .csv => |r| r.bytesConsumed(source, pos),
        };
    }

    /// The position right after the row starting at `pos` (CSV:
    /// `lexer.recordBounds`), never examining past `limit` (`null` == the
    /// true end of `source`). `capped` reports whether `limit` was reached
    /// before a real record terminator was found. Used by the index/search/
    /// filter scan loops and by the window/nav checkpoint-to-row skip loops.
    pub fn boundsAfter(self: Reader, source: Source, pos: Pos, limit: ?Pos) BoundsResult {
        return switch (self) {
            .csv => |r| r.boundsAfter(source, pos, limit),
        };
    }

    /// Decode the row at `pos` into `buf`/`refs` (CSV: `lexer.lexInto`).
    /// `want == null` decodes every field (no padding); `want == N` produces
    /// exactly N refs (pad/truncate). Each stored cell is capped to `cap`
    /// UTF-8 bytes (`null` == uncapped — SEARCH/filter's full-cell read).
    /// Never examines past `limit` (`null` == the true end of `source`);
    /// `capped` mirrors `boundsAfter`. Used by window/nav/search/filter.
    pub fn materialize(
        self: Reader,
        source: Source,
        pos: Pos,
        want: ?u32,
        cap: ?usize,
        limit: ?Pos,
        buf: *std.ArrayList(u8),
        refs: *std.ArrayList(CellRef),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!MaterializeResult {
        return switch (self) {
            .csv => |r| r.materialize(source, pos, want, cap, limit, buf, refs, gpa),
        };
    }

    /// Decode ONLY column `col` of the row at `pos` into `buf[0..buf_len]`
    /// (the `ls_cell_copy` / window.cellCopy primitive) — never the rest of
    /// the row, and zero heap allocation. Never examines past `limit`
    /// (`null` == the true end of `source`).
    pub fn cell(
        self: Reader,
        source: Source,
        pos: Pos,
        col: u32,
        limit: ?Pos,
        buf: ?[*]u8,
        buf_len: usize,
    ) CellResult {
        return switch (self) {
            .csv => |r| r.cell(source, pos, col, limit, buf, buf_len),
        };
    }
};


// ---------------------------------------------------------------------------
// csv-gz SEED seam stubs (ARCH-csv-gz "Internal Source/Reader contract",
// Decision 1-C). Reader/Source capabilities the repaired seam must provide,
// pinned in contracts/api.zig. NOT wired into the working path in the seed
// (window/index/nav/search/filter still call the existing ops above), so
// existing behavior is byte-identical; the implementer builds the real bounded,
// resumable versions. Every param is discarded here -- these are shape stubs.
// ---------------------------------------------------------------------------

const source_mod2 = @import("source.zig");

/// ARCH capability (2): unknown-end query in the frozen SourceEnd vocabulary --
/// never conflate current availability with EOF. SEED STUB.
pub fn sourceEndAt(source: Source, pos: Pos) api.SourceEnd {
    _ = source;
    _ = pos;
    return .clean_eof;
}

/// ARCH capability (3): bounded cursor acquisition by opaque logical position +
/// DUAL limits (logical inflated-output + optional physical compressed-input).
/// SEED STUB.
pub fn sourceCursorAt(source: Source, pos: Pos, limit: api.DualLimit) source_mod2.Cursor {
    _ = source;
    _ = pos;
    _ = limit;
    return .{};
}

/// ARCH capability (4): logical inflated-byte measurement of an actual position
/// (row extents, per-row scan cap, oversized detection, CSV parsing). SEED: CSV
/// Pos IS a logical byte offset (identity), matching bytesConsumed today.
pub fn posLogicalBytes(source: Source, pos: Pos) u64 {
    _ = source;
    return @intFromEnum(pos);
}

/// ARCH capability (4): physical compressed-file-byte measurement of an actual
/// position (index/search/filter progress + the row-count estimate). SEED: for
/// mmap this equals the logical offset (identity apart from the BOM base).
pub fn posPhysicalBytes(source: Source, pos: Pos) u64 {
    _ = source;
    return @intFromEnum(pos);
}

/// ARCH capability (5): rebase the Source after the ONE leading BOM (only a BOM
/// at inflated offset zero of the whole concatenated stream is stripped). SEED
/// STUB (root.zig still rebases via the mmap content slice today).
pub fn sourceRebaseBom(source: *Source, bom_len: u64) void {
    _ = source;
    _ = bom_len;
}

/// ARCH capability (6) / req4: the streaming ROW-MATCH the Reader gains -- next
/// opaque position + the lowest matching column/result matcher.matchRecord
/// returns today, over ONE predicate or the composed filter+find pair, so a row
/// is decompressed + lexed ONCE and the matcher stays O(query + fixed state)
/// (AC13). Replaces the unbounded materialize(cap=null) in search/filter/nav.
/// SEED STUB: returns "no match" and NOTHING calls it yet (search/filter/nav
/// still use the existing materialize path), so AC13 stays RED until the
/// implementer builds the streaming matcher, wires it, and increments
/// gzStreamMatcherResidentBytes.
pub const MatchRowResult = struct {
    next: Pos,
    matched_col: ?u32,
    capped: bool,
    end: api.SourceEnd,
};

pub fn readerMatchRow(
    self: Reader,
    source: Source,
    pos: Pos,
    primary: base.MatchCtx,
    filter_ctx: ?base.MatchCtx,
    limit: api.DualLimit,
) MatchRowResult {
    _ = self;
    _ = source;
    _ = primary;
    _ = filter_ctx;
    _ = limit;
    return .{ .next = pos, .matched_col = null, .capped = false, .end = .inflating };
}
