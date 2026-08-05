//! tools/fuzz/lexer_diff.zig — DIFFERENTIAL ORACLE for the structural-byte scan.
//!
//! WHY THIS EXISTS. `lexer.findStructural` answers "where does this CSV field
//! end" for the two BYTE-WISE UTF-8 structural scans — and only those two: the
//! match-scan row loop in `csv_reader.matchMmapUtf8` and the unquoted-field arm
//! of `lexer.storeToStructural`. (It is NOT every UTF-8 structural scan: the
//! unit-wise `scanToStructural`, the quote-stateful `scanUtf8Rows`, and the
//! whole cursor/streaming family bypass it, so it is reachable for `.mmap`
//! sources only. `findStructural`'s own doc comment carries the full map.)
//! It replaced `std.mem.findAny`, a scalar loop, with a `@Vector(N, u8)` block
//! scan: three splat compares OR-ed together, then `std.simd.firstTrue`, then a
//! scalar tail.
//!
//! That is exactly the shape of change that fails SILENTLY. A missed lane is a
//! false negative, so the field runs past its real end, swallows the separator,
//! and the row is mis-lexed — wrong cell contents and a wrong row count, with no
//! crash for the four crash-oriented targets in `harness.zig` to catch. A wrong
//! lane index is worse still: it reports a structural byte where there is none,
//! and every position this scan yields is one a caller may publish as a row
//! start (see review/REVIEW-row-count-drift.md — "a terminator is consumed
//! whole, or not at all" rests on the offset being exact).
//!
//! The property is total equivalence, not merely "finds something":
//!
//!   REFERENCE  `std.mem.findAny(u8, hay, &.{ sep, '\r', '\n' })` — in 0.16 a
//!              plain nested scalar loop, the implementation being replaced, and
//!              obviously correct by inspection.
//!   UNDER TEST `lexer.findStructural(hay, sep)`.
//!
//! They must return the IDENTICAL optional for every input. Inputs are shaped to
//! hammer the block/tail seam, which is where a vector scan actually breaks:
//! every length from 0 to several blocks, and a needle planted at every offset
//! in that range — so a scan that mishandles the first block, the last partial
//! block, or the boundary between them cannot pass.
//!
//! Runs two ways:
//!   zig build diff            (deterministic sweep, fixed seeds)
//!   zig build test --fuzz     (the Smith-driven target joins the campaign)

const std = @import("std");
const lexer = @import("core").lexer_internals;
const enc = @import("core").encoding_internals;

// The five encodings `resolveEncoding` can produce (contracts/api.zig). Named
// here rather than imported so the oracle keeps working if the `api` module is
// not wired into it.
const utf8: u8 = 0;
const utf16le: u8 = 1;
const utf16be: u8 = 2;
const latin1: u8 = 3;
const windows1252: u8 = 4;

/// The UNIT-WISE structural scan, written the way every non-UTF-8 lexer arm
/// writes it: decode a unit, test it with `unitIsStructural`, advance by
/// `src_len`. Returns the SOURCE offset of the first structural unit.
///
/// This is the second of the two arms. `csv_reader.matchCursor` now picks the
/// byte-wise `findStructural` when the encoding is UTF-8 and this shape
/// otherwise, so "the two arms agree on UTF-8" is the load-bearing claim and
/// "they do NOT agree on the multi-byte encodings" is why the gate must stay.
fn refUnitScan(content: []const u8, sep: u8, encoding: u8) ?usize {
    var i: usize = 0;
    while (i < content.len) {
        const u = enc.decodeUnit(content, i, content.len, encoding) orelse return null;
        if (enc.unitIsStructural(u, sep)) return i;
        i += u.src_len;
    }
    return null;
}

/// The implementation under test must agree with the one it replaced.
fn expectAgree(hay: []const u8, sep: u8) !void {
    const want = std.mem.findAny(u8, hay, &.{ sep, '\r', '\n' });
    const got = lexer.findStructural(hay, sep);
    if (want == null and got == null) return;
    if (want == null or got == null or want.? != got.?) {
        std.debug.print(
            "findStructural MISMATCH: len={d} sep={d} want={?d} got={?d}\nhay={x}\n",
            .{ hay.len, sep, want, got, hay },
        );
        return error.StructuralScanDisagrees;
    }
    // The offset must also BE a structural byte and the first one, independently
    // of the reference: a scan whose two implementations drifted together is
    // still wrong. (Cheap, and it makes the oracle self-checking.)
    if (got) |at| {
        try std.testing.expect(at < hay.len);
        const c = hay[at];
        try std.testing.expect(c == sep or c == '\r' or c == '\n');
        for (hay[0..at]) |b| try std.testing.expect(b != sep and b != '\r' and b != '\n');
    } else {
        for (hay) |b| try std.testing.expect(b != sep and b != '\r' and b != '\n');
    }
}

/// The vector width the scan actually uses, so the sweep's lengths straddle the
/// real block boundary rather than a guessed one.
const block: usize = std.simd.suggestVectorLength(u8) orelse 1;

test "findStructural: needle at every offset of every length across the block seam" {
    const gpa = std.testing.allocator;
    // Four blocks plus change: covers no-block, exactly-one-block, several
    // blocks, and every partial tail in between.
    const max_len = block * 4 + 3;
    const buf = try gpa.alloc(u8, max_len);
    defer gpa.free(buf);

    for ([_]u8{ ',', ';', '\t', 'a', 0, 0xFF }) |sep| {
        var len: usize = 0;
        while (len <= max_len) : (len += 1) {
            const hay = buf[0..len];
            // Filler must contain none of the three needles, or "first" moves.
            @memset(hay, 'x');
            try expectAgree(hay, sep);

            // One needle, at every offset. All three needle bytes, because they
            // land in three different splat compares.
            for ([_]u8{ sep, '\r', '\n' }) |needle| {
                for (0..len) |at| {
                    @memset(hay, 'x');
                    hay[at] = needle;
                    try expectAgree(hay, sep);
                }
            }

            // Two needles: pins that the LOWEST set lane wins, including when
            // the two land in different blocks and in different compares.
            for (0..len) |a| {
                for (a + 1..len) |b| {
                    @memset(hay, 'x');
                    hay[a] = '\r';
                    hay[b] = sep;
                    try expectAgree(hay, sep);
                    @memset(hay, 'x');
                    hay[a] = sep;
                    hay[b] = '\n';
                    try expectAgree(hay, sep);
                }
            }
        }
    }
}

test "findStructural: sep aliasing CR/LF, and all-needle runs" {
    const gpa = std.testing.allocator;
    const max_len = block * 3 + 1;
    const buf = try gpa.alloc(u8, max_len);
    defer gpa.free(buf);
    // A dialect whose separator IS a terminator byte makes two of the three
    // splat compares identical -- the OR must still yield the first lane.
    for ([_]u8{ '\r', '\n' }) |sep| {
        var len: usize = 0;
        while (len <= max_len) : (len += 1) {
            const hay = buf[0..len];
            @memset(hay, '\r');
            try expectAgree(hay, sep);
            @memset(hay, '\n');
            try expectAgree(hay, sep);
            @memset(hay, 'x');
            if (len > 0) hay[len - 1] = sep;
            try expectAgree(hay, sep);
        }
    }
}

test "findStructural: pseudorandom sweep, fixed seeds" {
    const gpa = std.testing.allocator;
    const max_len = block * 6;
    const buf = try gpa.alloc(u8, max_len);
    defer gpa.free(buf);

    for ([_]u64{ 0x5EED, 0xA11CE, 0xBEEF, 0x1234_5678, 0xFFFF_FFFF }) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const rnd = prng.random();
        var case: usize = 0;
        while (case < 20_000) : (case += 1) {
            const len = rnd.uintAtMost(usize, max_len);
            const hay = buf[0..len];
            const sep = switch (rnd.uintLessThan(u8, 4)) {
                0 => ',',
                1 => ';',
                2 => '\t',
                else => rnd.int(u8),
            };
            // Dense needles half the time (short fields, the common CSV shape),
            // sparse the other half (multi-MB cells, a supported input).
            const dense = rnd.boolean();
            for (hay) |*b| {
                if (dense) {
                    b.* = switch (rnd.uintLessThan(u8, 5)) {
                        0 => sep,
                        1 => '\r',
                        2 => '\n',
                        else => rnd.int(u8),
                    };
                } else {
                    const v = rnd.int(u8);
                    b.* = if (v == sep or v == '\r' or v == '\n') 'x' else v;
                }
            }
            try expectAgree(hay, sep);
        }
    }
}

// ---------------------------------------------------------------------------
// The two ARMS of csv_reader.matchCursor's structural scan.
// ---------------------------------------------------------------------------

test "arms agree on UTF-8: byte-wise findStructural == unit-wise scan" {
    const gpa = std.testing.allocator;
    const max_len = block * 3 + 5;
    const buf = try gpa.alloc(u8, max_len);
    defer gpa.free(buf);

    // Includes bytes >= 0x80: under UTF-8 pass-through these are ordinary
    // non-structural singletons, which is exactly why the byte-wise scan is
    // allowed to treat them as filler. A validating decoder would not be.
    for ([_]u8{ ',', ';', '\t', 0x7F }) |sep| {
        var prng: std.Random.DefaultPrng = .init(0xC0FFEE + @as(u64, sep));
        const rnd = prng.random();
        var case: usize = 0;
        while (case < 30_000) : (case += 1) {
            const len = rnd.uintAtMost(usize, max_len);
            const hay = buf[0..len];
            for (hay) |*b| {
                b.* = switch (rnd.uintLessThan(u8, 6)) {
                    0 => sep,
                    1 => '\r',
                    2 => '\n',
                    3 => rnd.intRangeAtMost(u8, 0x80, 0xFF), // invalid/continuation
                    else => rnd.intRangeAtMost(u8, 'a', 'z'),
                };
            }
            const byte_wise = lexer.findStructural(hay, sep);
            const unit_wise = refUnitScan(hay, sep, utf8);
            if (byte_wise == null and unit_wise == null) continue;
            if (byte_wise == null or unit_wise == null or byte_wise.? != unit_wise.?) {
                std.debug.print(
                    "UTF-8 ARMS DISAGREE: sep={d} byte_wise={?d} unit_wise={?d}\nhay={x}\n",
                    .{ sep, byte_wise, unit_wise, hay },
                );
                return error.Utf8ArmsDisagree;
            }
        }
    }
}

test "the UTF-8 gate is load-bearing: byte-wise is WRONG for the other four encodings" {
    // GUARD / honesty assertion, in the style of the suite's `*_controls` tests:
    // it asserts the HAZARD IS REAL. If any of these ever stopped differing, the
    // `encoding == api.encoding_utf8` gate in `matchCursor` would look redundant
    // and someone would delete it.

    // UTF-16LE: U+2C00 encodes as bytes { 0x00, 0x2C }. The unit is ONE
    // character and is NOT a separator, but a byte scan sees 0x2C (',') at
    // offset 1 and would cut the field there.
    {
        const bytes = [_]u8{ 0x00, 0x2C, 'A', 0x00 };
        try std.testing.expectEqual(@as(?usize, 1), lexer.findStructural(&bytes, ','));
        try std.testing.expectEqual(@as(?usize, null), refUnitScan(&bytes, ',', utf16le));
    }
    // UTF-16BE: the same trap with the bytes the other way round.
    {
        const bytes = [_]u8{ 0x2C, 0x00, 0x00, 'A' };
        try std.testing.expectEqual(@as(?usize, 0), lexer.findStructural(&bytes, ','));
        try std.testing.expectEqual(@as(?usize, null), refUnitScan(&bytes, ',', utf16be));
    }
    // Latin-1 / Windows-1252: a source byte >= 0x80 decodes to TWO output bytes,
    // so source offsets and output offsets diverge. The byte-wise scan reports a
    // SOURCE offset that the unit-wise scan reaches at a different index once a
    // high byte precedes the separator -- here they happen to agree on the
    // offset, so the real divergence to pin is that feeding raw SOURCE bytes
    // would hand the matcher un-transcoded bytes. Assert the decode differs.
    for ([_]u8{ latin1, windows1252 }) |e| {
        const high = [_]u8{0xE9}; // Latin-1 'é' -> 2 UTF-8 output bytes
        const u = enc.decodeUnit(&high, 0, high.len, e).?;
        try std.testing.expectEqual(@as(usize, 1), u.src_len);
        try std.testing.expect(u.out_len == 2); // src != out: byte-wise feeding would corrupt
        try std.testing.expect(!enc.unitIsStructural(u, ','));
    }
    // THIRD REASON THE GATE MUST STAY, and the one least likely to be
    // rediscovered: the END-OF-STREAM verdict is encoding-asymmetric.
    //
    // `Cursor.danglingTail` is encoding-AGNOSTIC -- it is NOT the case that "it
    // returns 0 for UTF-8" by its own logic. The chain is:
    //   * UTF-8: a null unit can only mean `peek` returned ZERO bytes (every byte
    //     decodes, so nothing else yields null). So `in_hand == 0`, and
    //     `danglingTail`'s `left > in_hand` test makes it 0. Nothing is stranded,
    //     which is why the byte-wise arm may treat "no unit" as plain exhaustion.
    //   * UTF-16: a unit can be null with `in_hand == 1` -- a lone trailing byte,
    //     half a code unit -- and `danglingTail` is then genuinely NONZERO, a
    //     residue `streamUnit` must advance over for the stream's last row to be
    //     counted like the mmap side's.
    // A byte-wise arm applied to UTF-16 would silently drop that residue. This is
    // the same end-of-stream class as finding F1 in findings/README.md.
    {
        // UTF-16LE with an odd trailing byte: the decoder cannot complete a unit.
        const odd = [_]u8{ 'A', 0x00, 0x42 };
        try std.testing.expectEqual(@as(?usize, null), refUnitScan(&odd, ',', utf16le));
        try std.testing.expect(enc.decodeUnit(&odd, 2, odd.len, utf16le) == null);
        // UTF-8 has no such state: every offset in range decodes.
        var i: usize = 0;
        while (i < odd.len) : (i += 1) {
            try std.testing.expect(enc.decodeUnit(&odd, i, odd.len, utf8) != null);
        }
    }
    // And the property the fast path DOES rest on: under UTF-8 every byte is a
    // singleton whose output is itself, for all 256 values.
    {
        var b: u16 = 0;
        while (b <= 0xFF) : (b += 1) {
            const one = [_]u8{@intCast(b)};
            const u = enc.decodeUnit(&one, 0, 1, utf8).?;
            try std.testing.expectEqual(@as(usize, 1), u.src_len);
            try std.testing.expectEqual(@as(u8, 1), u.out_len);
            try std.testing.expectEqual(@as(u8, @intCast(b)), u.out[0]);
        }
    }
}

test "findStructural differential: fuzz target (Smith-driven)" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    // Several blocks wide, so the fuzzer can reach the block/tail seam.
    var hay_buf: [512]u8 = undefined;
    const hay_len = smith.slice(&hay_buf);
    // The dialect separator is drawn independently of the bytes, so the fuzzer
    // can make it common (dense short fields) or absent (one long cell).
    const sep = smith.valueRangeAtMost(u8, 0, 255);
    try expectAgree(hay_buf[0..hay_len], sep);
}
