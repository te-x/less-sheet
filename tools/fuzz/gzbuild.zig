//! Shared gzip/deflate construction, used by BOTH the harness (which builds a
//! member per fuzz iteration) and the seed generator (which bakes regression
//! members into the corpus).
//!
//! It is shared rather than duplicated for one specific reason: two of the seeds
//! AC-c2 requires the corpus to carry are the `flate_b1` regression cuts — the
//! mid-DEFLATE-symbol truncations that produced a garbage decode before the
//! wave-(b) fix (`review/REVIEW-flate-feed-guard.md`: fixture A cut 50, fixture
//! B cut 16891). A cut offset only means anything against ONE exact deflate
//! stream, so the generator and the harness must emit the same bytes for the same
//! payload. This mirrors the frozen suite's own `deflateRaw` / `gzMember` helpers
//! (`backend/tests/all_tests.zig`), which use the same `std.compress.flate`
//! `.raw` / `.default` settings.
//!
//! Buffers are passed in by the caller: the harness owns statics (it may not
//! allocate per iteration), the generator allocates.

const std = @import("std");
const flate = std.compress.flate;

pub const window_len = flate.max_window_len;

/// Headerless DEFLATE of `plain` into `out`. Returns null when `out` is too
/// small or the compressor errors — never a partial stream.
pub fn deflateRaw(plain: []const u8, win: []u8, out: []u8) ?[]u8 {
    var w = std.Io.Writer.fixed(out);
    var cmp = flate.Compress.init(&w, win, .raw, .default) catch return null;
    cmp.writer.writeAll(plain) catch return null;
    cmp.finish() catch return null;
    return w.buffered();
}

/// The gzip member's shape, as a 64-bit word.
///
/// A packed struct rather than hand-rolled bit shifting so `decode`/`encode` are
/// `@bitCast` and cannot drift apart: the harness decodes a fuzzer-drawn word,
/// the generator encodes a chosen shape, and both agree by construction. Zig
/// packs fields LSB-first, so field order IS the bit order.
///
/// Every default is 0, and 0 deliberately means "a well-formed, complete member
/// of the payload": an all-zero config word is the useful baseline seed, not a
/// degenerate one.
pub const Shape = packed struct(u64) {
    /// Bytes removed from the END of the deflate stream — the damage model for
    /// both a truncated file and a partial network fetch. 0 == no truncation.
    /// Applied modulo `raw.len + 1`, so every drawn value maps onto a real cut.
    tail_cut: u20 = 0,
    /// The member is emitted `extra_members + 1` times (a valid multi-member
    /// gzip when the member is complete; garbage after the first when it is not).
    extra_members: u2 = 0,
    /// Drop the CRC32+ISIZE footer (what a truncated file actually looks like).
    omit_footer: bool = false,
    /// Corrupt the footer CRC32.
    bad_crc: bool = false,
    /// Emit (and, with `bad_fhcrc`, corrupt) the optional header CRC16.
    fhcrc: bool = false,
    bad_fhcrc: bool = false,
    /// Emit an FNAME field.
    fname: bool = false,
    /// Report a false uncompressed size in the footer.
    bad_isize: bool = false,
    /// Compression-method selector. Mostly 8 (deflate) so the inflater is
    /// actually reached; 4 and 5 pick the values that must be cleanly REFUSED.
    cm_sel: u3 = 0,
    _reserved: u33 = 0,

    pub fn cm(s: Shape) u8 {
        return switch (s.cm_sel) {
            4 => 0,
            5 => 9,
            else => 8,
        };
    }

    pub fn decode(word: u64) Shape {
        return @bitCast(word);
    }

    pub fn encode(s: Shape) u64 {
        return @bitCast(s);
    }
};

fn appendU32Le(w: *std.Io.Writer, v: u32) !void {
    try w.writeAll(&.{
        @intCast(v & 0xff),
        @intCast((v >> 8) & 0xff),
        @intCast((v >> 16) & 0xff),
        @intCast((v >> 24) & 0xff),
    });
}

/// Build `shape.extra_members + 1` copies of a gzip member of `plain` into
/// `out`. Returns null when a buffer is too small.
pub fn member(plain: []const u8, shape: Shape, win: []u8, raw_scratch: []u8, out: []u8) ?[]u8 {
    const raw = deflateRaw(plain, win, raw_scratch) orelse return null;
    const keep = raw.len - @as(usize, @intCast(shape.tail_cut % (raw.len + 1)));

    var w = std.Io.Writer.fixed(out);
    var copies: u32 = 0;
    while (copies <= shape.extra_members) : (copies += 1) {
        const start = w.buffered().len;
        var flg: u8 = 0;
        if (shape.fhcrc or shape.bad_fhcrc) flg |= 0x02;
        if (shape.fname) flg |= 0x08;
        w.writeAll(&.{ 0x1f, 0x8b, shape.cm(), flg, 0, 0, 0, 0, 0, 0xff }) catch return null;
        if (shape.fname) w.writeAll("f\x00") catch return null;
        if (shape.fhcrc or shape.bad_fhcrc) {
            var h16: u16 = @truncate(std.hash.Crc32.hash(w.buffered()[start..]));
            if (shape.bad_fhcrc) h16 +%= 1;
            w.writeAll(&.{ @intCast(h16 & 0xff), @intCast((h16 >> 8) & 0xff) }) catch return null;
        }
        w.writeAll(raw[0..keep]) catch return null;
        if (!shape.omit_footer) {
            var crc = std.hash.Crc32.hash(plain);
            if (shape.bad_crc) crc +%= 1;
            var isize_: u32 = @truncate(plain.len);
            if (shape.bad_isize) isize_ ^= 0x5a5a_5a5a;
            appendU32Le(&w, crc) catch return null;
            appendU32Le(&w, isize_) catch return null;
        }
    }
    return w.buffered();
}

/// `n` fixed-width 18-byte records, byte-identical to the frozen suite's
/// `genFixedRows` (`backend/tests/all_tests.zig`) — the payload the `flate_b1`
/// regression cuts are defined against.
pub fn fixedRows(w: *std.Io.Writer, n: usize) !void {
    for (0..n) |i| try w.print("{d:0>8},{d:0>8}\n", .{ i, 2 * i });
}

test "Shape encode/decode round-trips and zero means a complete deflate member" {
    const zero = Shape.decode(0);
    try std.testing.expectEqual(@as(u20, 0), zero.tail_cut);
    try std.testing.expectEqual(@as(u8, 8), zero.cm());
    try std.testing.expectEqual(false, zero.omit_footer);

    const s: Shape = .{ .tail_cut = 12345, .omit_footer = true, .extra_members = 2, .cm_sel = 5 };
    try std.testing.expectEqual(s, Shape.decode(s.encode()));
    try std.testing.expectEqual(@as(u8, 9), Shape.decode(s.encode()).cm());
}
