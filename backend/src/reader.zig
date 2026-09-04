//! The Reader interface: the format→rows/cells parser the format-agnostic
//! core (window/index/nav/search/filter — the C ABI in root.zig) calls
//! INSTEAD of a format's own parser directly (see docs/architecture/
//! ARCH-reader-interface.md). CSV (src/csv_reader.zig) is the only member
//! today; a future Parquet or ODS/XLSX Reader would add a sibling variant to
//! the `Reader` union below with NO change to window/index/nav/search/filter/
//! root.
//!
//! The row `Pos` a Reader hands back (from `boundsAfter`/`materialize`) is
//! OPAQUE to every caller outside `src/csv_reader.zig`: a handle the core
//! only ever obtains from, and passes back to, a Reader op, or stores
//! verbatim in a `base.Checkpoint`/`nav.SourceLoc`.
//! For the CSV Reader it happens to be a byte offset into the `Source` (src/
//! source.zig); nothing outside `csv_reader.zig` may assume that. Every core
//! call site treats `Pos` as a value to
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

/// Opaque row position. CSV records the immutable logical inflated offset and
/// the compressed-file high-water mark that produced it. Core callers only
/// store/pass this value; coordinate access remains behind Reader methods.
pub const Pos = struct { logical: u64, physical: u64 };

pub const BoundsResult = struct { next: Pos, capped: bool };
pub const MaterializeResult = struct { next: Pos, capped: bool };
pub const CellResult = struct { len: usize, truncated: bool };
pub const ScanRowsResult = struct { next: Pos, rows: u64, eof: bool };
pub const SelectedStep = csv_reader.SelectedStep;

pub const SelectedScanner = union(enum) {
    csv: csv_reader.SelectedScanner,

    pub fn deinit(self: *SelectedScanner) void {
        switch (self.*) {
            .csv => |*scanner| scanner.deinit(),
        }
    }

    pub fn releaseLane(self: *SelectedScanner) void {
        switch (self.*) {
            .csv => |*scanner| scanner.releaseLane(),
        }
    }

    pub fn step(self: *SelectedScanner, selected: []const u32, cap: usize, work_budget: u64, row_budget: u64, buf: *std.ArrayList(u8), refs: *std.ArrayList(CellRef), gpa: std.mem.Allocator) std.mem.Allocator.Error!SelectedStep {
        return switch (self.*) {
            .csv => |*scanner| scanner.step(selected, cap, work_budget, row_budget, buf, refs, gpa),
        };
    }
};

/// A pluggable format Reader. One tagged-union variant per format — CSV is
/// the only member today (see csv_reader.CsvReader). Every op takes the
/// `Source` explicitly (a Reader never owns one), so the same Reader value
/// can serve different byte providers across calls.
///
/// Dispatch is a single `switch` per call — no vtable, no heap indirection.
/// With one variant this costs at most one (trivially-predicted, often
/// wholly-elided) branch.
pub const Reader = union(enum) {
    csv: csv_reader.CsvReader,

    pub fn selectedScanner(self: Reader, source: Source, pos: Pos) SelectedScanner {
        return switch (self) {
            .csv => |r| .{ .csv = csv_reader.SelectedScanner.init(r, source, pos) },
        };
    }

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

    pub fn logicalBytes(self: Reader, source: Source, pos: Pos) u64 {
        _ = self;
        return posLogicalBytes(source, pos);
    }

    pub fn physicalBytes(self: Reader, source: Source, pos: Pos) u64 {
        _ = self;
        return posPhysicalBytes(source, pos);
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

    /// Decode only the strictly-increasing selected column IDs, sharing one
    /// record scan and returning refs in selected-ID order.
    pub fn materializeSelected(
        self: Reader,
        source: Source,
        pos: Pos,
        selected: []const u32,
        cap: usize,
        limit: ?Pos,
        buf: *std.ArrayList(u8),
        refs: *std.ArrayList(CellRef),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!MaterializeResult {
        return switch (self) {
            .csv => |r| r.materializeSelected(source, pos, selected, cap, limit, buf, refs, gpa),
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

    /// Advance several records with one Source lease.  This is the frontier
    /// hot path for streaming sources; mmap retains its direct lexer loop.
    pub fn scanRows(self: Reader, source: Source, pos: Pos, max_rows: u64) ScanRowsResult {
        return switch (self) {
            .csv => |r| r.scanRows(source, pos, max_rows),
        };
    }
};

const source_mod2 = @import("source.zig");

/// Unknown-end query in the frozen SourceEnd vocabulary -- never conflate current
/// availability with EOF.
pub fn sourceEndAt(source: Source, pos: Pos) api.SourceEnd {
    if (source.knownEnd()) |end| return if (pos.logical >= end) switch (source) {
        .mmap => .clean_eof,
        .http_range => .clean_eof,
        .gzip => |g| if (g.terminal_kind.load(.acquire) == 1) .clean_eof else .damaged_eof,
    } else .inflating;
    return .inflating;
}

/// Bounded cursor acquisition by opaque logical position + DUAL limits (logical
/// inflated-output + optional physical compressed-input).
pub fn sourceCursorAt(source: Source, pos: Pos, limit: api.DualLimit) source_mod2.Cursor {
    const logical_limit = if (limit.logical) |n| pos.logical +| n else null;
    return source_mod2.cursorAt(source, pos.logical, logical_limit, limit.physical);
}

/// Logical inflated-byte measurement of a position (row extents, per-row scan
/// cap, oversized detection, CSV parsing). CSV `Pos` IS a logical byte offset
/// (identity), matching bytesConsumed.
pub fn posLogicalBytes(source: Source, pos: Pos) u64 {
    _ = source;
    return pos.logical;
}

/// Physical compressed-file-byte measurement of a position (index/search/filter
/// progress + the row-count estimate). For mmap this equals the logical offset,
/// apart from the BOM base.
pub fn posPhysicalBytes(source: Source, pos: Pos) u64 {
    _ = source;
    return pos.physical;
}

/// Rebase the Source after the ONE leading BOM: only a BOM at inflated offset
/// zero of the whole concatenated stream is stripped.
pub fn sourceRebaseBom(source: *Source, bom_len: u64) void {
    source_mod2.rebaseBom(source, bom_len);
}

/// The streaming ROW-MATCH result: next opaque position plus the lowest matching
/// column, over ONE predicate or the composed filter+find pair, so a row is
/// decompressed + lexed ONCE and the matcher stays O(query + fixed state).
pub const MatchRowResult = struct {
    next: Pos,
    matched_col: ?u32,
    filter_matched: bool,
    capped: bool,
    end: api.SourceEnd,
};

/// Match one row through a document-owned whole-job scan Cursor: ownership and
/// deinit stay with base.Document, so the lane remains leased across worker
/// block commits (a per-block lease would let another lane reposition the
/// inflater session between blocks and force a checkpoint replay per block).
pub fn readerMatchRowAtScanCursor(
    self: Reader,
    cursor: *source_mod.Cursor,
    primary: base.MatchCtx,
    filter_ctx: ?base.MatchCtx,
) MatchRowResult {
    return switch (self) {
        .csv => |r| r.matchRowAtScanCursor(cursor, primary, filter_ctx),
    };
}

pub fn readerMatchRow(
    self: Reader,
    source: Source,
    pos: Pos,
    primary: base.MatchCtx,
    filter_ctx: ?base.MatchCtx,
    limit: api.DualLimit,
) MatchRowResult {
    return switch (self) {
        .csv => |r| r.matchRow(source, pos, primary, filter_ctx, limit),
    };
}
