//! Encoding: source-encoding resolution (see api/lesssheet.h TEXT AND
//! ENCODING) plus the SOURCE code-unit decoder fused into the lexer (src/
//! lexer.zig). There is no separate "transcode the buffer, then lex it"
//! pass: `decodeUnit` decodes exactly ONE source code unit (1 byte for UTF-8
//! pass-through / Latin-1 / Windows-1252 ASCII range, 1 byte for a
//! Latin-1/Windows-1252 high byte, 2 or 4 bytes for a UTF-16 code unit or
//! surrogate pair) into its UTF-8 output on every call, so every scan (head,
//! background index, jump, search, window materialization) transcodes ONLY
//! the source bytes it actually visits -- the streaming/windowed transcode
//! the ARCH requires, with zero extra buffering or bookkeeping. Because
//! sep/quote/CR/LF are always a single ASCII byte, comparing a unit's 1-byte
//! output against them is correct for every encoding (a multi-byte output
//! unit, or any raw byte >= 0x80, can never equal one).

const std = @import("std");
const api = @import("api");

// ---------------------------------------------------------------------------
// Encoding resolution (see api/lesssheet.h TEXT AND ENCODING). Runs on the
// RAW head bytes (pre-BOM-strip), before dialect sniffing. A forced encoding
// bypasses detection but a leading BOM matching it is still stripped.
// ---------------------------------------------------------------------------

pub const EncodingResolution = struct { encoding: u8, forced: bool, bom_len: u64 };

/// The BOM length for `enc` if `raw` actually starts with it, else 0.
/// Latin-1 / Windows-1252 have no BOM.
fn matchingBomLen(raw: []const u8, enc: u8) u64 {
    return switch (enc) {
        api.encoding_utf8 => if (raw.len >= 3 and raw[0] == 0xEF and raw[1] == 0xBB and raw[2] == 0xBF) 3 else 0,
        api.encoding_utf16le => if (raw.len >= 2 and raw[0] == 0xFF and raw[1] == 0xFE) 2 else 0,
        api.encoding_utf16be => if (raw.len >= 2 and raw[0] == 0xFE and raw[1] == 0xFF) 2 else 0,
        else => 0,
    };
}

/// UTF-8 validation step of detection: like `std.unicode.utf8ValidateSlice`,
/// except a multibyte sequence that is simply CUT by the sample boundary
/// (not enough bytes left to tell, but every available byte of it is a
/// plausible continuation byte) does not fail detection -- requirement 3. A
/// genuinely invalid byte (bad lead byte, bad continuation, overlong,
/// surrogate) anywhere, including in a trailing "short" sequence that has
/// more sample bytes after it that AREN'T valid continuations, still fails.
fn looksLikeUtf8(sample: []const u8) bool {
    var i: usize = 0;
    while (i < sample.len) {
        const b0 = sample[i];
        const n = std.unicode.utf8ByteSequenceLength(b0) catch return false;
        if (i + n > sample.len) {
            var k: usize = 1;
            while (i + k < sample.len) : (k += 1) {
                if (sample[i + k] & 0xC0 != 0x80) return false;
            }
            return true; // cut by the boundary; every available byte checks out
        }
        if (n > 1) _ = std.unicode.utf8Decode(sample[i .. i + n]) catch return false;
        i += n;
    }
    return true;
}

/// NUL-ratio heuristic for BOM-less UTF-16: true (LE, NULs on odd offsets),
/// false (BE, NULs on even offsets), or null (neither parity is UTF-16
/// shaped). Thresholds are an implementation detail (pinned outcomes only).
fn detectUtf16NulRatio(sample: []const u8) ?bool {
    if (sample.len < 8) return null;
    var even_total: usize = 0;
    var even_nul: usize = 0;
    var odd_total: usize = 0;
    var odd_nul: usize = 0;
    for (sample, 0..) |b, i| {
        if (i % 2 == 0) {
            even_total += 1;
            if (b == 0) even_nul += 1;
        } else {
            odd_total += 1;
            if (b == 0) odd_nul += 1;
        }
    }
    if (even_total == 0 or odd_total == 0) return null;
    const even_ratio = @as(f64, @floatFromInt(even_nul)) / @as(f64, @floatFromInt(even_total));
    const odd_ratio = @as(f64, @floatFromInt(odd_nul)) / @as(f64, @floatFromInt(odd_total));
    const dominant = 0.70;
    const sparse = 0.10;
    if (odd_ratio >= dominant and even_ratio <= sparse) return true; // LE
    if (even_ratio >= dominant and odd_ratio <= sparse) return false; // BE
    return null;
}

/// Resolve the effective encoding per the pinned detection pipeline (BOM ->
/// NUL-ratio -> UTF-8 validation -> Latin-1) or honor a forced one (stripping
/// a matching BOM either way). `raw` is a bounded prefix of the raw file
/// bytes (pre-BOM-strip); empty for a 0-byte file.
pub fn resolveEncoding(raw: []const u8, forced_opt: i32) EncodingResolution {
    if (forced_opt != api.encoding_auto) {
        const enc: u8 = @intCast(forced_opt);
        return .{ .encoding = enc, .forced = true, .bom_len = matchingBomLen(raw, enc) };
    }
    if (raw.len >= 3 and raw[0] == 0xEF and raw[1] == 0xBB and raw[2] == 0xBF)
        return .{ .encoding = api.encoding_utf8, .forced = false, .bom_len = 3 };
    if (raw.len >= 2 and raw[0] == 0xFF and raw[1] == 0xFE)
        return .{ .encoding = api.encoding_utf16le, .forced = false, .bom_len = 2 };
    if (raw.len >= 2 and raw[0] == 0xFE and raw[1] == 0xFF)
        return .{ .encoding = api.encoding_utf16be, .forced = false, .bom_len = 2 };
    if (detectUtf16NulRatio(raw)) |le|
        return .{ .encoding = if (le) api.encoding_utf16le else api.encoding_utf16be, .forced = false, .bom_len = 0 };
    if (looksLikeUtf8(raw))
        return .{ .encoding = api.encoding_utf8, .forced = false, .bom_len = 0 };
    return .{ .encoding = api.encoding_latin1, .forced = false, .bom_len = 0 };
}

// ---------------------------------------------------------------------------
// SOURCE code-unit decode (fused into the lexer; see the module doc comment).
// ---------------------------------------------------------------------------

/// One decoded SOURCE code unit: `src_len` source bytes consumed, `out[0
/// ..out_len]` its UTF-8 output (1-4 bytes). A unit is atomic for both
/// structural comparison (see `unitIsByte`) and the LS_CELL_MAX_BYTES cap
/// (never split), which is what guarantees the cap always cuts at a UTF-8
/// code-point boundary.
pub const Unit = struct {
    src_len: usize,
    out: [4]u8 = undefined,
    out_len: u8 = 1,
};

/// True iff `u`'s entire output is the single byte `b` (the only shape that
/// can ever compare equal to a separator/quote/CR/LF byte, all of which are
/// < 0x80 by construction).
pub inline fn unitIsByte(u: Unit, b: u8) bool {
    return u.out_len == 1 and u.out[0] == b;
}

fn replacementUnit(src_len: usize) Unit {
    var u: Unit = .{ .src_len = src_len };
    @memcpy(u.out[0..3], &std.unicode.replacement_character_utf8);
    u.out_len = 3;
    return u;
}

/// Decode the SOURCE code unit at `off` (SOURCE bytes; `content` is always
/// the document's full post-BOM source buffer), or null if no complete unit
/// is available before `limit` -- every caller treats that exactly like
/// hitting `limit` (`capped`), the same as the pre-csv-hardening byte-wise
/// bound check.
pub inline fn decodeUnit(content: []const u8, off: usize, limit: usize, encoding: u8) ?Unit {
    if (off >= limit) return null;
    // UTF-8 (the default / by far most common case) is the fast path: one
    // raw byte in, one raw byte out, no lookahead -- see
    // `decodeUtf8PassthroughUnit` for why grouping multibyte sequences here
    // is unnecessary (the display cap fixes up the boundary after the fact).
    if (encoding == api.encoding_utf8) return decodeUtf8PassthroughUnit(content, off);
    return switch (encoding) {
        api.encoding_utf16le => decodeUtf16Unit(content, off, limit, true),
        api.encoding_utf16be => decodeUtf16Unit(content, off, limit, false),
        api.encoding_latin1 => decodeLatin1Unit(content, off),
        api.encoding_windows1252 => decodeWindows1252Unit(content, off),
        else => unreachable, // validateOptions/resolveEncoding only ever produce the above
    };
}

/// ISO-8859-1: every byte value IS its codepoint (never U+FFFD from decoding).
fn decodeLatin1Unit(content: []const u8, off: usize) Unit {
    const b = content[off];
    if (b < 0x80) return .{ .src_len = 1, .out = .{ b, 0, 0, 0 }, .out_len = 1 };
    var u: Unit = .{ .src_len = 1 };
    u.out_len = std.unicode.utf8Encode(b, &u.out) catch unreachable; // 0x80-0xFF: always 2 bytes
    return u;
}

/// Windows-1252 0x80-0x9F is a fixed codepoint table (five undefined bytes
/// map to U+FFFD); 0xA0-0xFF is identical to Latin-1.
const windows1252_high: [32]u21 = .{
    0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
    0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
};

fn decodeWindows1252Unit(content: []const u8, off: usize) Unit {
    const b = content[off];
    if (b < 0x80) return .{ .src_len = 1, .out = .{ b, 0, 0, 0 }, .out_len = 1 };
    const cp: u21 = if (b < 0xA0) windows1252_high[b - 0x80] else b;
    var u: Unit = .{ .src_len = 1 };
    u.out_len = std.unicode.utf8Encode(cp, &u.out) catch unreachable;
    return u;
}

/// One UTF-16 code unit (2 bytes) or surrogate pair (4 bytes). Ill-formed /
/// lone surrogates -> U+FFFD (2 consumed bytes). A high surrogate that can't
/// be paired within `limit` defers (returns null) UNLESS `limit` is the true
/// end of content, in which case it is a genuinely dangling unit -> U+FFFD.
fn decodeUtf16Unit(content: []const u8, off: usize, limit: usize, little: bool) ?Unit {
    if (off + 2 > limit) return null;
    const endian: std.builtin.Endian = if (little) .little else .big;
    const cu0 = std.mem.readInt(u16, content[off..][0..2], endian);
    if (std.unicode.utf16IsHighSurrogate(cu0)) {
        if (off + 4 <= limit) {
            const cu1 = std.mem.readInt(u16, content[off + 2 ..][0..2], endian);
            if (std.unicode.utf16IsLowSurrogate(cu1)) {
                const cp = std.unicode.utf16DecodeSurrogatePair(&[_]u16{ cu0, cu1 }) catch unreachable;
                var u: Unit = .{ .src_len = 4 };
                u.out_len = std.unicode.utf8Encode(cp, &u.out) catch unreachable;
                return u;
            }
        } else if (limit != content.len) {
            return null; // budget-capped: defer to a future call with more room
        }
        return replacementUnit(2); // lone / dangling high surrogate
    }
    if (std.unicode.utf16IsLowSurrogate(cu0)) return replacementUnit(2); // lone low surrogate
    if (cu0 < 0x80) return .{ .src_len = 2, .out = .{ @intCast(cu0), 0, 0, 0 }, .out_len = 1 };
    var u: Unit = .{ .src_len = 2 };
    u.out_len = std.unicode.utf8Encode(cu0, &u.out) catch unreachable;
    return u;
}

/// UTF-8 pass-through (Option A): bytes are NEVER validated or rewritten (an
/// invalid byte survives unchanged -- see requirement 7). This is the hot
/// path (the default, and by far the most common, encoding): ALWAYS a
/// singleton raw byte, exactly like the pre-csv-hardening byte-wise lexer,
/// so scanning an all-ASCII/UTF-8 document costs no more than it did before.
/// A cap that lands inside a multibyte sequence is fixed up once per
/// (truncated) field by `utf8TrimToBoundary`, not per byte here.
inline fn decodeUtf8PassthroughUnit(content: []const u8, off: usize) Unit {
    return .{ .src_len = 1, .out = .{ content[off], 0, 0, 0 }, .out_len = 1 };
}

fn utf8LeadLen(b: u8) usize {
    return switch (b) {
        0x00...0x7F => 1,
        0xC0...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF7 => 4,
        else => 1, // stray continuation / invalid lead byte: singleton
    };
}

/// For the UTF-8 pass-through path only: `bytes` was stored one raw byte at a
/// time (see `decodeUtf8PassthroughUnit`), so a cap/limit cut can land in the
/// middle of a multibyte sequence. Returns the length to KEEP so the result
/// never ends on a split code point (requirement 8), fixing the boundary up
/// ONCE per truncated field rather than paying a lookahead per byte scanned.
/// O(1) for the overwhelming common case (the last byte is plain ASCII or
/// already a bare lead byte); at most a 3-byte backward walk otherwise.
/// Invalid UTF-8 (Option A: never rewritten) is otherwise left exactly as-is.
pub fn utf8TrimToBoundary(bytes: []const u8) usize {
    if (bytes.len == 0 or bytes[bytes.len - 1] < 0x80) return bytes.len;
    var back: usize = 0;
    while (back < 3 and back < bytes.len and (bytes[bytes.len - 1 - back] & 0xC0) == 0x80) : (back += 1) {}
    if (back >= bytes.len) return bytes.len; // defensive: nothing but continuation bytes
    const lead_pos = bytes.len - 1 - back;
    const n = utf8LeadLen(bytes[lead_pos]);
    if (n == 1) return bytes.len; // no real lead byte found (stray continuations): leave as-is
    if (lead_pos + n <= bytes.len) return bytes.len; // sequence is already complete
    return lead_pos; // incomplete: cut before the dangling lead byte
}
