//! The CSV Reader: the first (and, in this slice, only) implementation of
//! the Reader interface (src/reader.zig) — CSV's format→rows/cells parsing,
//! wrapping `lexer.zig` / `encoding.zig` / `sniff.zig` (moved BEHIND this
//! module, not rewritten — see docs/architecture/ARCH-reader-interface.md).
//! Its row `Pos` IS a byte offset into the `Source`; every cast between
//! `Pos` and a byte offset lives HERE (`toPos`/`toOffset` below) — nothing
//! outside this file may rely on that (see reader.zig's module doc).

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");
const enc = @import("encoding.zig");
const lexer = @import("lexer.zig");
const sniff = @import("sniff.zig");
const source_mod = @import("source.zig");
const reader_mod = @import("reader.zig");

const Source = source_mod.Source;
const Pos = reader_mod.Pos;
const CellRef = base.CellRef;
const BoundsResult = reader_mod.BoundsResult;
const MaterializeResult = reader_mod.MaterializeResult;
const CellResult = reader_mod.CellResult;

fn toPos(off: usize) Pos {
    return @enumFromInt(off);
}

fn toOffset(pos: Pos) usize {
    return @intCast(@intFromEnum(pos));
}

/// The CSV Reader: the resolved dialect (sep/quote/encoding — see
/// `openHead`) plus the Reader ops. Immutable after construction; cheap to
/// copy (three small scalar fields), which is what lets `reader.Reader`
/// dispatch by value with no indirection.
pub const CsvReader = struct {
    sep: u8,
    quote: ?u8,
    encoding: u8,

    pub fn start(self: CsvReader, source: Source) Pos {
        _ = self;
        _ = source;
        return toPos(0);
    }

    pub fn atEnd(self: CsvReader, source: Source, pos: Pos) bool {
        _ = self;
        return toOffset(pos) >= source.len();
    }

    /// See reader.Reader.posAtByteBudget. CSV: `min(from + budget, len)`,
    /// exactly the bound every window/head-scan call site computed inline
    /// before the reorg (now the ONLY place that arithmetic happens).
    pub fn posAtByteBudget(self: CsvReader, source: Source, from: Pos, budget: u64) Pos {
        _ = self;
        const off = toOffset(from);
        const add: usize = @intCast(budget);
        const bounded = off +| add;
        const len: usize = @intCast(source.len());
        return toPos(@min(bounded, len));
    }

    pub fn bytesConsumed(self: CsvReader, source: Source, pos: Pos) u64 {
        _ = self;
        _ = source;
        return @intFromEnum(pos);
    }

    pub fn boundsAfter(self: CsvReader, source: Source, pos: Pos, limit: ?Pos) BoundsResult {
        const content = source.slice(0, source.len());
        const lim: usize = if (limit) |l| toOffset(l) else content.len;
        const b = lexer.recordBounds(content, toOffset(pos), self.sep, self.quote, lim, self.encoding);
        return .{ .next = toPos(b.next), .capped = b.capped };
    }

    pub fn materialize(
        self: CsvReader,
        source: Source,
        pos: Pos,
        want: ?u32,
        cap: ?usize,
        limit: ?Pos,
        buf: *std.ArrayList(u8),
        refs: *std.ArrayList(CellRef),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!MaterializeResult {
        const content = source.slice(0, source.len());
        const lim: usize = if (limit) |l| toOffset(l) else content.len;
        const res = try lexer.lexInto(content, toOffset(pos), self.sep, self.quote, want, cap, lim, self.encoding, buf, refs, gpa);
        return .{ .next = toPos(res.next), .capped = res.capped };
    }

    pub fn cell(
        self: CsvReader,
        source: Source,
        pos: Pos,
        col: u32,
        limit: ?Pos,
        buf: ?[*]u8,
        buf_len: usize,
    ) CellResult {
        const content = source.slice(0, source.len());
        const lim: usize = if (limit) |l| toOffset(l) else content.len;
        const res = decodeColumn(content, toOffset(pos), self.sep, self.quote, lim, self.encoding, col, buf, buf_len);
        return .{ .len = res.len, .truncated = res.truncated };
    }
};

// ---------------------------------------------------------------------------
// open/sniff (ARCH-reader-interface item 5): detect + set up. Called ONCE,
// directly by root.zig's openWithAllocator, before any Reader/Source value
// exists — it PRODUCES them.
// ---------------------------------------------------------------------------

pub const OpenResult = struct {
    reader: CsvReader,
    bom_len: u64,
    /// The post-BOM content slice (`mapping[bom_len..]`); the caller (root.
    /// zig) wraps it into a `source.Mmap` — kept a plain slice here so this
    /// module needs no dependency the other way (Document lives in base.zig).
    content: []const u8,
};

/// Resolve the source encoding, then the dialect, from the raw (pre-BOM-
/// strip) mapping bytes, returning the ready CSV Reader + the post-BOM
/// content slice. Mirrors the pipeline root.zig ran inline before this
/// reorg (see api/lesssheet.h "Pipeline order at open"): encoding resolution
/// runs on a bounded raw sample BEFORE dialect sniffing (sniffing needs
/// already-transcoded structure). `sample_bytes` bounds the encoding-
/// detection sample only (independent of the O(head) dialect/shape budget
/// applied later via `posAtByteBudget`). `mapping` is the whole (post-open,
/// pre-BOM-strip) file mapping, or an empty slice for a 0-byte file — always
/// run unconditionally, exactly like the pre-reorg root.zig (an empty
/// `mapping` still yields sensible sniffed defaults).
pub fn openHead(mapping: []const u8, opt: api.OpenOptions, sample_bytes: usize) OpenResult {
    const sample = mapping[0..@min(mapping.len, sample_bytes)];
    const enc_res = enc.resolveEncoding(sample, opt.encoding);
    const content = mapping[enc_res.bom_len..mapping.len];
    const rd = sniff.sniffDialect(content, opt, enc_res.encoding);
    return .{
        .reader = .{ .sep = rd.sep, .quote = rd.quote, .encoding = enc_res.encoding },
        .bom_len = enc_res.bom_len,
        .content = content,
    };
}

// ---------------------------------------------------------------------------
// decodeColumn (the `cell` op's implementation — the ls_cell_copy / former
// window.cellCopy primitive). Moved verbatim from window.zig: decode ONLY
// column `col` of the record starting at SOURCE offset `start`, touching no
// ArrayList/allocator (fields before `col` are scanned WITHOUT storing;
// decoding stops the instant `col` is resolved).
// ---------------------------------------------------------------------------

/// Append one decoded unit's UTF-8 output to `buf[0..buf_len]` at
/// `out_len.*` unless the cap is already reached or would be exceeded (never
/// a partial unit, so the written bytes are only ever cut at a unit boundary
/// — the `utf8TrimToBoundary` fixup in `decodeColumn` then fixes up the rarer
/// UTF-8-pass-through case where a "unit" is a single raw byte that can
/// itself land mid code point), latching `cap_truncated.*` and storing
/// nothing further once set. Mirrors lexer.zig's private `storeCapped`,
/// adapted to a raw fixed buffer instead of an ArrayList so the caller does
/// ZERO heap allocation.
fn storeUnit(buf: ?[*]u8, buf_len: usize, out_len: *usize, cap_truncated: *bool, u: enc.Unit) void {
    if (cap_truncated.*) return;
    if (out_len.* + @as(usize, u.out_len) > buf_len) {
        cap_truncated.* = true;
        return;
    }
    if (buf) |b| @memcpy(b[out_len.* .. out_len.* + u.out_len], u.out[0..u.out_len]);
    out_len.* += u.out_len;
}

/// Decode ONLY column `col` of the record starting at SOURCE offset `start`
/// into `buf[0..buf_len]` (nothing written when `col`'s field doesn't exist —
/// a ragged row — or `buf_len` is 0). Mirrors lexer.lexInto's per-field decode
/// (quote handling, structural sep/CR/LF scanning, the `utf8TrimToBoundary`
/// fixup on a cut field) but touches no ArrayList or allocator: fields before
/// `col` are scanned WITHOUT storing, and decoding stops the instant `col` is
/// resolved (found, cut, or padded) — it never looks at the rest of the row.
/// `limit` bounds the SOURCE bytes visited (the caller's per-row scan cap, or
/// `content.len` for the unbounded pinned-row-0 decode); ZERO heap
/// allocation.
///
/// `truncated` is true iff `col`'s full transcoded content exceeds the
/// written bytes: `buf_len` cut it, or `limit` is an ARTIFICIAL bound
/// (`limit != content.len` — the per-row source scan cap) reached before
/// `col` could be located or fully decoded. Reaching the TRUE end of the
/// content (`limit == content.len`) with no more separators is simply a
/// ragged/short row: `col` beyond it pads to the empty, UNTRUNCATED cell —
/// nothing is missing.
fn decodeColumn(
    content: []const u8,
    start: usize,
    sep: u8,
    quote: ?u8,
    limit: usize,
    encoding: u8,
    col: u32,
    buf: ?[*]u8,
    buf_len: usize,
) struct { len: usize, truncated: bool } {
    const artificial = limit != content.len;
    var i = start;
    var produced: u32 = 0;
    while (true) {
        const store = produced == col;
        var out_len: usize = 0;
        var cap_truncated = false;
        var hit_limit = false;

        if (quote) |q| {
            if (enc.decodeUnit(content, i, limit, encoding)) |first| {
                if (enc.unitIsByte(first, q)) {
                    i += first.src_len;
                    while (true) {
                        const u = enc.decodeUnit(content, i, limit, encoding) orelse {
                            hit_limit = true;
                            break;
                        };
                        if (enc.unitIsByte(u, q)) {
                            const peek = enc.decodeUnit(content, i + u.src_len, limit, encoding);
                            if (peek != null and enc.unitIsByte(peek.?, q)) {
                                if (store) storeUnit(buf, buf_len, &out_len, &cap_truncated, u);
                                i += u.src_len + peek.?.src_len;
                                continue;
                            }
                            i += u.src_len;
                            break;
                        }
                        if (store) storeUnit(buf, buf_len, &out_len, &cap_truncated, u);
                        i += u.src_len;
                    }
                }
            }
        }
        if (!hit_limit) {
            while (true) {
                const u = enc.decodeUnit(content, i, limit, encoding) orelse {
                    hit_limit = true;
                    break;
                };
                if (enc.unitIsByte(u, sep) or enc.unitIsByte(u, '\n') or enc.unitIsByte(u, '\r')) break;
                if (store) storeUnit(buf, buf_len, &out_len, &cap_truncated, u);
                i += u.src_len;
            }
        }

        const was_truncated = cap_truncated or (hit_limit and artificial);
        if (store) {
            if (was_truncated and encoding == api.encoding_utf8) {
                if (buf) |b| out_len = enc.utf8TrimToBoundary(b[0..out_len]);
            }
            return .{ .len = out_len, .truncated = was_truncated };
        }
        if (hit_limit) return .{ .len = 0, .truncated = artificial };

        produced += 1;
        const u = enc.decodeUnit(content, i, limit, encoding).?; // present: hit_limit was false
        if (enc.unitIsByte(u, sep)) {
            i += u.src_len;
            continue;
        }
        return .{ .len = 0, .truncated = false }; // record terminator: col beyond -> ragged pad
    }
}

// ---------------------------------------------------------------------------
// AC5 note (docs/architecture/ARCH-reader-interface.md) — validated on paper
// against the two acid-test format shapes; neither would touch reader.zig or
// any core file (window/index/nav/search/filter/root), only add a sibling
// `..._reader.zig` + a `Reader` union variant:
//
//   * Parquet (columnar-binary; most different from CSV). `Pos` would encode
//     `(row_group: u32, in_group_index: u32)` packed into the same `u64`
//     (still an opaque handle to the core). `start`/`atEnd` read the footer's
//     row-group directory; `posAtByteBudget` bounds "open" to the footer +
//     first row group (still O(head) bytes, per the ABI); `boundsAfter` just
//     increments `in_group_index` (wrapping into the next row group at its
//     boundary — no byte scan at all); `materialize`/`cell` decode the
//     row's typed column chunks into display text; `bytesConsumed` sums the
//     row groups' on-disk byte ranges up to `pos` (Parquet's footer already
//     has these, so the ABI's byte-denominated progress fields stay exact,
//     not estimated). No byte-oriented `Source` is touched at all — Parquet
//     reads its own file structure directly (see source.zig's module doc).
//
//   * ODS/XLSX (ZIP container of XML; the container+stateful-position acid
//     test). A `zip_reader.zig` Source variant streams-inflates one ZIP
//     entry (e.g. `xl/worksheets/sheet1.xml`) — `len`/`slice` hide the
//     inflate exactly like a future gzip Source (source.zig's module doc).
//     An `xml_reader.zig` Reader parses that inflated stream; because a
//     `<row>` element's true start can depend on open ancestor tags, `Pos`
//     packs an inflated-stream offset PLUS a small parser-state tag (e.g.
//     "inside <sheetData>, no open row") into the same opaque `u64` — still
//     just a value the core stores/compares/hands back, never inspects.
//     `boundsAfter`/`materialize`/`cell` resume the SAX-style scan from that
//     state instead of re-parsing from the top of the sheet.
//
// Both slot in as a new Reader (+ new Source, for ODS) variant with zero
// change to window.zig/index.zig/nav.zig/search.zig/filter.zig/root.zig,
// which is the seam this reorg exists to prove (ARCH-reader-interface AC5).
