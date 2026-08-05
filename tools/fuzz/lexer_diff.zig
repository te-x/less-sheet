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
