//! The parameterized, quote-aware lexer (RFC-4180 generalized; quote NONE).
//! All entry points agree on record boundaries and decode SOURCE bytes
//! through `encoding.decodeUnit`, so they are correct for whichever encoding
//! produced the document's UTF-8 (see src/encoding.zig).

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");
const enc = @import("encoding.zig");

const CellRef = base.CellRef;

pub const Bounds = struct { next: usize, capped: bool };

/// Vector width for `findStructural`, 0 on a target without SIMD — the block
/// loop is then comptime-dead and the scan is purely the scalar tail loop.
/// `std.simd.suggestVectorLength` is how std sizes its own `findScalarPos`
/// blocks, so this follows the platform std already picked.
const structural_vec_len: usize = std.simd.suggestVectorLength(u8) orelse 0;

/// THE structural-byte scan: the offset within `hay` of the first byte that can
/// end a CSV field — `sep`, CR or LF — or null if `hay` contains none.
///
/// ONE SOURCE FOR THE BYTE-WISE SCAN — and ONLY the byte-wise scan. Both of the
/// codebase's byte-at-a-slice UTF-8 structural scans call this, and they are the
/// only two callers:
///   * `storeToStructural` below (the unquoted-field store, UTF-8 arm), and
///   * the match-scan row loop in `csv_reader.matchMmapUtf8`.
/// Both previously called `std.mem.findAny(u8, …, &.{ sep, '\r', '\n' })` —
/// which in Zig 0.16 resolves to `findAnyPos` (`std/mem.zig`), a plain nested
/// scalar loop: three compares plus a bounds check for every byte of the file.
/// That it is NOT vectorized is easy to miss because `findScalarPos` — one
/// needle, used by the quoted-field arm — sits 80 lines above it in the same
/// file and IS vectorized, which is why only the three-needle scan was slow.
/// (The two call sites also passed the needles in different ORDERS,
/// `{sep,'\r','\n'}` vs `{sep,'\n','\r'}`; immaterial, because `findAnyPos`
/// iterates positions outer and values inner so order cannot move the returned
/// index — but one helper now makes that unable to drift at all.)
///
/// WHAT DOES **NOT** ROUTE THROUGH HERE — a map, so the next reader does not
/// mistake this for "all UTF-8 structural scanning". Editing this function does
/// not touch any of them:
///   * `csv_reader.scanUtf8Rows` — the row-count walk; byte-at-a-time because it
///     is quote-stateful and owns the terminator invariant;
///   * `scanToStructural` below, reached from `recordBounds` and
///     `sniff.countFields` — unit-wise, runs for ALL encodings including UTF-8;
///   * `csv_reader.matchCursor` — the match scan for `.gzip` / `.http_range`;
///   * the streaming decode family — `lexStream`, `lexStreamSelected`,
///     `cellStream`, `decodeColumn`.
/// The last two matter most: source dispatch is uniform (`.mmap => <content
/// lexer.*>` vs `.gzip, .http_range => <cursor *Stream>`), and the cursor family
/// never calls this. So this helper is reachable for **`.mmap` sources only** —
/// a local `.csv.gz` or a network document gains nothing from it, on bounds,
/// materialize, selected, cell and match alike.
///
/// This is ONLY a faster way to compute the same offset. It decides nothing
/// about terminators: CR, LF and CRLF are still classified by the caller, so
/// the "a terminator is consumed whole, or not at all" invariant is untouched.
/// `sep` is a runtime dialect value, so the three needles are splatted at run
/// time — no comptime specialization is needed or wanted. A dialect whose `sep`
/// IS CR or LF is safe for free: the splat then merely equals `vcr`/`vlf` and
/// the OR of the three masks describes the same set of bytes.
///
/// BUFFER SAFETY: reads only bytes inside `hay` (never one past it, not even
/// speculatively — the block loop's `hay.len - i >= structural_vec_len` is
/// exactly the condition for the `hay[i..][0..N]` load) and returns only an
/// offset into `hay`. It holds no state across calls and keeps no pointer.
/// No CURRENT caller is a streaming one (see the map above — the cursor family
/// does not use this), so that is a property held in advance rather than one
/// being relied on today: should a re-filling caller ever route here, a peek
/// invalidating the slice `hay` pointed into cannot catch anything in here out.
pub fn findStructural(hay: []const u8, sep: u8) ?usize {
    var i: usize = 0;
    // Runs shorter than one block — every field of a typical narrow CSV — go
    // straight to the scalar loop so they never pay even the splat setup, the
    // same short-run bail `matcher.feedText` makes before its anchor prefilter.
    if (comptime structural_vec_len > 0) if (hay.len >= structural_vec_len) {
        const V = @Vector(structural_vec_len, u8);
        const vsep: V = @splat(sep);
        const vcr: V = @splat('\r');
        const vlf: V = @splat('\n');
        while (hay.len - i >= structural_vec_len) : (i += structural_vec_len) {
            const v: V = hay[i..][0..structural_vec_len].*;
            const m = (v == vsep) | (v == vcr) | (v == vlf);
            // firstTrue on the OR of the three masks — the LOWEST set lane, so
            // the result is the first structural byte regardless of which of
            // the three it is, matching `findAny`'s left-to-right semantics.
            if (@reduce(.Or, m)) return i + std.simd.firstTrue(m).?;
        }
    };
    while (i < hay.len) : (i += 1) {
        const c = hay[i];
        if (c == sep or c == '\r' or c == '\n') return i;
    }
    return null;
}

/// Advance from `i` (decoding units of `encoding`) until a sep/CR/LF unit
/// (not consumed) or `limit` (ran out, `hit_limit`). Shared by the unquoted
/// scan and the post-closing-quote trailing-junk scan (both stop the same way).
pub const Scan = struct { pos: usize, hit_limit: bool };

fn scanToStructural(content: []const u8, start: usize, sep: u8, limit: usize, encoding: u8) Scan {
    var i = start;
    while (true) {
        const u = enc.decodeUnit(content, i, limit, encoding) orelse return .{ .pos = i, .hit_limit = true };
        if (enc.unitIsByte(u, sep) or enc.unitIsByte(u, '\n') or enc.unitIsByte(u, '\r')) return .{ .pos = i, .hit_limit = false };
        i += u.src_len;
    }
}

/// Find where the record at `pos` ends. Scans no further than `limit`
/// (<= content.len); `capped` is true iff the record failed to terminate
/// before `limit` (used to bound the head-budget scan). Quote state protects
/// embedded separators / CR / LF.
pub fn recordBounds(content: []const u8, pos: usize, sep: u8, quote: ?u8, limit: usize, encoding: u8) Bounds {
    var i = pos;
    const cl = content.len;
    while (true) {
        if (quote) |q| {
            const first = enc.decodeUnit(content, i, limit, encoding);
            if (first != null and enc.unitIsByte(first.?, q)) {
                i += first.?.src_len;
                while (true) {
                    const u = enc.decodeUnit(content, i, limit, encoding) orelse
                        return .{ .next = limit, .capped = limit != cl };
                    if (enc.unitIsByte(u, q)) {
                        const peek = enc.decodeUnit(content, i + u.src_len, limit, encoding);
                        if (peek != null and enc.unitIsByte(peek.?, q)) {
                            i += u.src_len + peek.?.src_len;
                            continue;
                        }
                        i += u.src_len;
                        break;
                    }
                    i += u.src_len;
                }
            }
        }
        const s = scanToStructural(content, i, sep, limit, encoding);
        if (s.hit_limit) return .{ .next = limit, .capped = limit != cl };
        i = s.pos;
        const u = enc.decodeUnit(content, i, limit, encoding).?; // present: hit_limit was false
        if (enc.unitIsByte(u, sep)) {
            i += u.src_len;
            continue;
        }
        if (enc.unitIsByte(u, '\r')) {
            const nxt = enc.decodeUnit(content, i + u.src_len, limit, encoding);
            const next_i = if (nxt != null and enc.unitIsByte(nxt.?, '\n')) i + u.src_len + nxt.?.src_len else i + u.src_len;
            return .{ .next = next_i, .capped = false };
        }
        return .{ .next = i + u.src_len, .capped = false }; // '\n'
    }
}

/// Count the fields of the record at `pos` (no decode, no alloc), scanning no
/// further than `limit`. `quoted` reports whether any field opened with the
/// quote byte (feeds the sniffer's "active quote" signal). Used by the sniffer.
pub fn countFields(content: []const u8, pos: usize, sep: u8, quote: ?u8, limit: usize, encoding: u8) struct { count: u32, next: usize, quoted: bool } {
    var i = pos;
    var count: u32 = 0;
    var quoted = false;
    while (true) {
        if (quote) |q| {
            const first = enc.decodeUnit(content, i, limit, encoding);
            if (first != null and enc.unitIsByte(first.?, q)) {
                quoted = true;
                i += first.?.src_len;
                while (true) {
                    const u = enc.decodeUnit(content, i, limit, encoding) orelse break;
                    if (enc.unitIsByte(u, q)) {
                        const peek = enc.decodeUnit(content, i + u.src_len, limit, encoding);
                        if (peek != null and enc.unitIsByte(peek.?, q)) {
                            i += u.src_len + peek.?.src_len;
                            continue;
                        }
                        i += u.src_len;
                        break;
                    }
                    i += u.src_len;
                }
            }
        }
        const s = scanToStructural(content, i, sep, limit, encoding);
        count += 1;
        if (s.hit_limit) return .{ .count = count, .next = limit, .quoted = quoted };
        i = s.pos;
        const u = enc.decodeUnit(content, i, limit, encoding).?;
        if (enc.unitIsByte(u, sep)) {
            i += u.src_len;
            continue;
        }
        if (enc.unitIsByte(u, '\r')) {
            const nxt = enc.decodeUnit(content, i + u.src_len, limit, encoding);
            const next_i = if (nxt != null and enc.unitIsByte(nxt.?, '\n')) i + u.src_len + nxt.?.src_len else i + u.src_len;
            return .{ .count = count, .next = next_i, .quoted = quoted };
        }
        return .{ .count = count, .next = i + u.src_len, .quoted = quoted };
    }
}

/// Append one decoded unit's UTF-8 output to `buf` (from `start`) unless the
/// LS_CELL_MAX_BYTES cap is already reached or would be exceeded, in which
/// case nothing is appended (never a partial unit -- this is what guarantees
/// the served cell is cut at a code-point boundary) and `truncated.*` latches
/// true. Once latched, no further unit is ever stored for this field (a
/// later, smaller unit must not "fit" into room a bigger skipped one left
/// behind).
fn storeCapped(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, start: usize, u: enc.Unit, cap: ?usize, truncated: *bool) !void {
    if (truncated.*) return;
    if (cap) |cap_bytes| {
        if (buf.items.len - start + u.out_len > cap_bytes) {
            truncated.* = true;
            return;
        }
    }
    try buf.appendSlice(gpa, u.out[0..u.out_len]);
}

/// Decode the quoted body starting right after the opening quote (`i`),
/// collapsing doubled quotes to one literal, storing (subject to `cap`) into
/// `buf` from `start`. Returns the position right after the closing quote, or
/// signals `hit_limit` if the quote never closes within `limit`.
pub const QuoteResult = struct { pos: usize, hit_limit: bool };

fn consumeQuotedBody(
    content: []const u8,
    start_at: usize,
    start: usize,
    q: u8,
    limit: usize,
    encoding: u8,
    store: bool,
    cap: ?usize,
    truncated: *bool,
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) !QuoteResult {
    var i = start_at;
    while (true) {
        const u = enc.decodeUnit(content, i, limit, encoding) orelse return .{ .pos = limit, .hit_limit = true };
        if (enc.unitIsByte(u, q)) {
            const peek = enc.decodeUnit(content, i + u.src_len, limit, encoding);
            if (peek != null and enc.unitIsByte(peek.?, q)) {
                if (store) try storeCapped(buf, gpa, start, u, cap, truncated);
                i += u.src_len + peek.?.src_len;
                continue;
            }
            return .{ .pos = i + u.src_len, .hit_limit = false };
        }
        if (store) try storeCapped(buf, gpa, start, u, cap, truncated);
        i += u.src_len;
    }
}

/// Decode units from `i` until a sep/CR/LF unit (not stored) or `limit` (ran
/// out); stores (subject to `cap`) exactly like `consumeQuotedBody`. Shared by
/// the unquoted-field case and the post-closing-quote trailing-junk case.
fn storeToStructural(
    content: []const u8,
    start_at: usize,
    start: usize,
    sep: u8,
    limit: usize,
    encoding: u8,
    store: bool,
    cap: ?usize,
    truncated: *bool,
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) !Scan {
    if (encoding == api.encoding_utf8) {
        const tail = content[start_at..limit];
        const rel = findStructural(tail, sep);
        const end = start_at + (rel orelse tail.len);
        if (store and !truncated.*) {
            const bytes = content[start_at..end];
            if (cap) |cap_bytes| {
                const used = buf.items.len - start;
                const room = cap_bytes -| used;
                const take = @min(room, bytes.len);
                try buf.appendSlice(gpa, bytes[0..take]);
                if (take < bytes.len) truncated.* = true;
            } else {
                try buf.appendSlice(gpa, bytes);
            }
        }
        return .{ .pos = end, .hit_limit = rel == null };
    }
    var i = start_at;
    while (true) {
        const u = enc.decodeUnit(content, i, limit, encoding) orelse return .{ .pos = limit, .hit_limit = true };
        if (enc.unitIsByte(u, sep) or enc.unitIsByte(u, '\n') or enc.unitIsByte(u, '\r')) return .{ .pos = i, .hit_limit = false };
        if (store) try storeCapped(buf, gpa, start, u, cap, truncated);
        i += u.src_len;
    }
}

/// Decode the record at `pos` into `buf`/`refs`. `want` == null decodes every
/// field (no padding); `want` == N produces exactly N refs (decoding the first
/// N fields, padding missing ones with the empty cell, scanning the rest for
/// the boundary). Each stored cell is capped to at most `cap` UTF-8 bytes
/// (null == uncapped, used by SEARCH so it sees the full cell) at a
/// code-point boundary, flagging `CellRef.truncated`; scanning for the
/// record/field boundary is NEVER bounded by `cap` (only by `limit`), so a
/// field longer than `cap` is still fully accounted for. `limit` bounds how
/// many SOURCE bytes this call may look at (<= content.len); `capped` in the
/// result mirrors `recordBounds`: record 1's O(head) bound (requirement 9)
/// passes a real limit, every other caller passes content.len (unbounded).
///
/// `CellRef.truncated` is true iff the field's full transcoded content is
/// longer than the bytes stored for it: `cap` cut it, or `limit` is an
/// ARTIFICIAL bound (`limit != content.len` — a caller's head/row scan budget)
/// reached before the field could be fully decoded. Reaching the TRUE end of
/// the content (`limit == content.len`) with no more separators is simply a
/// final record with no terminator: nothing is missing, so the cell is
/// complete and UNTRUNCATED. Same rule as `lexSelected`, `recordBounds`'s
/// `capped = limit != content.len`, `csv_reader.decodeColumn`'s `artificial`,
/// and the streaming lane's `Cursor.atLimit`.
pub fn lexInto(
    content: []const u8,
    pos: usize,
    sep: u8,
    quote: ?u8,
    want: ?u32,
    cap: ?usize,
    limit: usize,
    encoding: u8,
    buf: *std.ArrayList(u8),
    refs: *std.ArrayList(CellRef),
    gpa: std.mem.Allocator,
) !Bounds {
    var i = pos;
    const cl = content.len;
    const artificial = limit != cl; // one derivation, both verdicts below
    var produced: u32 = 0;
    while (true) {
        const store = want == null or produced < want.?;
        const start = buf.items.len;
        var truncated = false;
        var hit_limit = false;

        if (quote) |q| {
            const first = enc.decodeUnit(content, i, limit, encoding);
            if (first != null and enc.unitIsByte(first.?, q)) {
                i += first.?.src_len;
                const qr = try consumeQuotedBody(content, i, start, q, limit, encoding, store, cap, &truncated, buf, gpa);
                hit_limit = qr.hit_limit;
                i = qr.pos;
            }
        }
        if (!hit_limit) {
            const sr = try storeToStructural(content, i, start, sep, limit, encoding, store, cap, &truncated, buf, gpa);
            hit_limit = sr.hit_limit;
            i = sr.pos;
        }

        const was_truncated = truncated or (hit_limit and artificial);
        if (store) {
            // UTF-8 pass-through stores raw bytes one at a time (the hot,
            // zero-lookahead path -- see decodeUtf8PassthroughUnit), so a cut
            // field may end mid code point; fix the boundary up once here
            // rather than paying a lookahead per byte scanned.
            if (was_truncated and encoding == api.encoding_utf8) {
                buf.shrinkRetainingCapacity(start + enc.utf8TrimToBoundary(buf.items[start..]));
            }
            try refs.append(gpa, .{ .start = start, .len = buf.items.len - start, .truncated = was_truncated });
        }
        produced += 1;

        if (hit_limit) {
            if (want) |w| while (produced < w) : (produced += 1) try refs.append(gpa, .{ .start = 0, .len = 0 });
            return .{ .next = limit, .capped = artificial };
        }

        const u = enc.decodeUnit(content, i, limit, encoding).?; // present: hit_limit was false
        if (enc.unitIsByte(u, sep)) {
            i += u.src_len;
            continue;
        }
        var next_i = i + u.src_len;
        if (enc.unitIsByte(u, '\r')) {
            const nxt = enc.decodeUnit(content, next_i, limit, encoding);
            if (nxt != null and enc.unitIsByte(nxt.?, '\n')) next_i += nxt.?.src_len;
        }
        if (want) |w| while (produced < w) : (produced += 1) try refs.append(gpa, .{ .start = 0, .len = 0 });
        return .{ .next = next_i, .capped = false };
    }
}

/// Decode an ordered set of columns in one record pass. `selected` must be
/// strictly increasing; `refs` receives exactly one entry per selected ID in
/// that same order. Fields between selected IDs are scanned but never stored,
/// avoiding the O(ids × column-index) repeated-prefix cost of per-cell reads.
pub fn lexSelected(
    content: []const u8,
    pos: usize,
    sep: u8,
    quote: ?u8,
    selected: []const u32,
    cap: usize,
    limit: usize,
    encoding: u8,
    buf: *std.ArrayList(u8),
    refs: *std.ArrayList(CellRef),
    gpa: std.mem.Allocator,
) !Bounds {
    var i = pos;
    const artificial = limit != content.len; // one derivation, as in lexInto
    var produced: u32 = 0;
    var selected_index: usize = 0;
    while (true) {
        const store = selected_index < selected.len and selected[selected_index] == produced;
        const start = buf.items.len;
        var truncated = false;
        var hit_limit = false;

        if (quote) |q| {
            const first = enc.decodeUnit(content, i, limit, encoding);
            if (first != null and enc.unitIsByte(first.?, q)) {
                i += first.?.src_len;
                const qr = try consumeQuotedBody(content, i, start, q, limit, encoding, store, cap, &truncated, buf, gpa);
                hit_limit = qr.hit_limit;
                i = qr.pos;
            }
        }
        if (!hit_limit) {
            const sr = try storeToStructural(content, i, start, sep, limit, encoding, store, cap, &truncated, buf, gpa);
            hit_limit = sr.hit_limit;
            i = sr.pos;
        }

        const was_truncated = truncated or (hit_limit and artificial);
        if (store) {
            if (was_truncated and encoding == api.encoding_utf8)
                buf.shrinkRetainingCapacity(start + enc.utf8TrimToBoundary(buf.items[start..]));
            try refs.append(gpa, .{ .start = start, .len = buf.items.len - start, .truncated = was_truncated });
            selected_index += 1;
        }
        produced += 1;

        if (hit_limit) {
            while (selected_index < selected.len) : (selected_index += 1)
                try refs.append(gpa, .{ .start = 0, .len = 0, .truncated = artificial });
            return .{ .next = limit, .capped = artificial };
        }

        const u = enc.decodeUnit(content, i, limit, encoding).?;
        if (enc.unitIsByte(u, sep)) {
            i += u.src_len;
            continue;
        }
        var next_i = i + u.src_len;
        if (enc.unitIsByte(u, '\r')) {
            const nxt = enc.decodeUnit(content, next_i, limit, encoding);
            if (nxt != null and enc.unitIsByte(nxt.?, '\n')) next_i += nxt.?.src_len;
        }
        while (selected_index < selected.len) : (selected_index += 1)
            try refs.append(gpa, .{ .start = 0, .len = 0 });
        return .{ .next = next_i, .capped = false };
    }
}
