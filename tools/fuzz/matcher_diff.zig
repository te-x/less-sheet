//! tools/fuzz/matcher_diff.zig — DIFFERENTIAL ORACLE for the matcher's fast paths.
//!
//! WHY THIS EXISTS, AND WHY IT IS NOT IN harness.zig. The four targets in
//! `harness.zig` drive the C ABI and assert nothing about returned values: their
//! property is "the process survives arbitrary bytes". This file asserts the
//! opposite kind of property — that three implementations of ONE verdict agree
//! on every input we can throw at them:
//!
//!   REFERENCE  a naive, obviously-correct brute-force substring / byte-compare
//!              written here, independent of `src/matcher.zig`;
//!   WHOLE-CELL `matcher.cellMatches` — what `ls_window_match_flags` (highlight
//!              flags), the nav re-lex and the filtered-window predicate use;
//!   STREAMING  `matcher.StreamCell` — what the full-file scan (search / filter /
//!              count) uses, fed in one call AND in every awkward split.
//!
//! The three exist deliberately (see the comments at `matcher.cellMatches` and
//! `window.matchFlags`): a row match and a cell highlight must never disagree.
//! The streaming path is also the one carrying the performance work — an early
//! verdict exit, a pre-folded query, and a VECTORIZED anchor prefilter that skips
//! positions the scalar KMP would have rejected. A false negative in that
//! prefilter would silently drop matches, which no crash-oriented fuzz target
//! could ever notice. Hence: chunk splits at every block boundary, and queries
//! drawn AS SUBSTRINGS of the cell so the expected answer is usually "match".
//!
//! For the ordering predicates (LT/GT/LE/GE) the whole-cell path IS the reference:
//! it parses the cell into an exact Decimal and compares, while `StreamCell` runs
//! an incremental digit FSM. Two genuinely different algorithms, one verdict.
//!
//! Runs two ways:
//!   zig build diff            (deterministic sweep, ~1e5 cases, fixed seeds)
//!   zig build test --fuzz     (the Smith-driven target joins the campaign)

const std = @import("std");
const matcher = @import("core").matcher_internals;

/// The matcher's own context/enum types, reached through the struct field rather
/// than a second import of `base.zig`: importing that file as its own module
/// would make a DIFFERENT `MatchCtx` type than the one `StreamCell` holds.
const MatchCtx = @FieldType(matcher.StreamCell, "ctx");
const Kind = @FieldType(MatchCtx, "kind");
const Op = @FieldType(MatchCtx, "op");

// ---------------------------------------------------------------------------
// The reference implementation. Deliberately the dumbest thing that can be
// correct: no KMP, no vectors, no streaming state, no shared helpers with the
// code under test (not even asciiLower).
// ---------------------------------------------------------------------------

fn refLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

fn refText(cell: []const u8, query: []const u8, fold: bool) bool {
    if (query.len == 0) return true; // pinned: the empty query matches
    if (query.len > cell.len) return false;
    var start: usize = 0;
    while (start + query.len <= cell.len) : (start += 1) {
        var all = true;
        for (query, 0..) |qb, j| {
            const a = if (fold) refLower(cell[start + j]) else cell[start + j];
            const b = if (fold) refLower(qb) else qb;
            if (a != b) {
                all = false;
                break;
            }
        }
        if (all) return true;
    }
    return false;
}

fn refEqual(cell: []const u8, query: []const u8, fold: bool) bool {
    if (cell.len != query.len) return false;
    for (cell, query) |x, y| {
        const a = if (fold) refLower(x) else x;
        const b = if (fold) refLower(y) else y;
        if (a != b) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// One case, checked every way.
// ---------------------------------------------------------------------------

/// Chunk splits that matter to the vector prefilter: it engages only with a
/// full block (16 or 32 bytes on the hosts we ship) plus one lookahead byte
/// left, and hands the tail back to the scalar KMP, which is the only path
/// allowed to end mid-match. So a match must still be found when the run is cut
/// exactly at, one before, and one after every block boundary.
const cut_offsets = [_]usize{ 1, 2, 3, 7, 8, 9, 15, 16, 17, 18, 19, 31, 32, 33, 34, 63, 64, 65, 127, 128, 129 };

/// TWO cuts, not one. A single cut can never construct the shape the prefilter
/// is most exposed to: the vector loop consumes a block inside run 1, a match
/// straddles into run 2, and run 2 is ITSELF cut — so the carried `text_k` has
/// to survive a second hand-off, and the second run may be short enough to go
/// straight to the scalar path while mid-match. Each pair brackets a block
/// boundary from both sides.
const cut_pairs = [_][2]usize{
    .{ 15, 16 }, .{ 16, 17 }, .{ 16, 32 }, .{ 17, 18 },
    .{ 17, 33 }, .{ 31, 34 }, .{ 32, 33 }, .{ 32, 64 },
    .{ 33, 49 }, .{ 63, 65 }, .{ 64, 65 }, .{ 1, 17 },
};

fn feedSplit(sc: *matcher.StreamCell, cell: []const u8, at: usize) void {
    if (at >= cell.len) {
        sc.feed(cell);
        return;
    }
    sc.feed(cell[0..at]);
    sc.feed(&.{}); // an empty run must be a no-op
    sc.feed(cell[at..]);
}

fn feedSplit2(sc: *matcher.StreamCell, cell: []const u8, a: usize, b: usize) void {
    if (a >= cell.len or b >= cell.len or a >= b) {
        feedSplit(sc, cell, a);
        return;
    }
    sc.feed(cell[0..a]);
    sc.feed(cell[a..b]);
    sc.feed(&.{});
    sc.feed(cell[b..]);
}

fn checkOne(
    gpa: std.mem.Allocator,
    cell: []const u8,
    query: []const u8,
    fold: bool,
    kind: Kind,
    op: Op,
    unit: usize,
) !void {
    var q = try matcher.Query.init(gpa, query, fold, kind);
    defer q.deinit(gpa);
    const ctx: MatchCtx = .{ .kind = kind, .op = op, .column = 0, .q = &q, .column_count = 1 };

    // 1. whole-cell verdict vs the naive reference (the arms this work rewrote).
    const whole = matcher.cellMatches(ctx, 0, cell);
    switch (kind) {
        .text => try expectSame("cellMatches vs reference (text)", refText(cell, query, fold), whole, cell, query, fold, kind, op),
        .predicate => switch (op) {
            .eq => try expectSame("cellMatches vs reference (eq)", refEqual(cell, query, fold), whole, cell, query, fold, kind, op),
            .ne => try expectSame("cellMatches vs reference (ne)", !refEqual(cell, query, fold), whole, cell, query, fold, kind, op),
            // Ordering: the whole-cell path (parse + exact decimal compare) is
            // itself the reference for the streaming FSM below.
            .lt, .gt, .le, .ge => {},
        },
    }

    // 2. streaming, one call.
    var one = matcher.StreamCell.init(ctx, 0);
    one.feed(cell);
    try expectSame("StreamCell(one call) vs cellMatches", whole, one.matches(), cell, query, fold, kind, op);

    // 3. streaming, split at each interesting boundary.
    for (cut_offsets) |at| {
        var sc = matcher.StreamCell.init(ctx, 0);
        feedSplit(&sc, cell, at);
        try expectSame("StreamCell(split) vs cellMatches", whole, sc.matches(), cell, query, fold, kind, op);
    }

    // 3b. streaming, split TWICE (see `cut_pairs`).
    for (cut_pairs) |p| {
        var sc = matcher.StreamCell.init(ctx, 0);
        feedSplit2(&sc, cell, p[0], p[1]);
        try expectSame("StreamCell(two splits) vs cellMatches", whole, sc.matches(), cell, query, fold, kind, op);
    }

    // 4. through a CLONE of the query — what the scan actually matches against:
    //    every worker snapshot (search.refreshWorkerCtx / filter.
    //    refreshFilterWorkerCtx) is a clone, so a clone that came out weaker
    //    than its source would change the verdict of every full-file scan while
    //    leaving the interactive paths correct.
    {
        var cloned = try q.clone(gpa);
        defer cloned.deinit(gpa);
        const cctx: MatchCtx = .{ .kind = kind, .op = op, .column = 0, .q = &cloned, .column_count = 1 };
        try expectSame("cellMatches(clone) vs cellMatches", whole, matcher.cellMatches(cctx, 0, cell), cell, query, fold, kind, op);
        var sc = matcher.StreamCell.init(cctx, 0);
        sc.feed(cell);
        try expectSame("StreamCell(clone) vs cellMatches", whole, sc.matches(), cell, query, fold, kind, op);
    }

    // 5. streaming, fed in fixed-size units — `unit == 1` is the decode-per-unit
    //    streaming cursor path (non-UTF-8 sources), where every feed call is
    //    below the vector threshold and the KMP state must carry across all of
    //    them.
    if (unit > 0) {
        var sc = matcher.StreamCell.init(ctx, 0);
        var i: usize = 0;
        while (i < cell.len) : (i += unit) sc.feed(cell[i..@min(i + unit, cell.len)]);
        try expectSame("StreamCell(units) vs cellMatches", whole, sc.matches(), cell, query, fold, kind, op);
    }
}

fn expectSame(
    what: []const u8,
    want: bool,
    got: bool,
    cell: []const u8,
    query: []const u8,
    fold: bool,
    kind: Kind,
    op: Op,
) !void {
    if (want == got) return;
    std.debug.print(
        \\
        \\MATCHER DIFFERENTIAL MISMATCH: {s}
        \\  want={} got={}  kind={s} op={s} fold={}
        \\  query ({d} B): "{f}"
        \\  cell  ({d} B): "{f}"
        \\
    , .{
        what,         want,
        got,          @tagName(kind),
        @tagName(op), fold,
        query.len,    std.ascii.hexEscape(query, .lower),
        cell.len,     std.ascii.hexEscape(cell, .lower),
    });
    return error.MatcherDifferentialMismatch;
}

// ---------------------------------------------------------------------------
// Input generation. Two alphabets: a tiny text one (so random queries actually
// hit, and case folding has something to fold) and a numeric one (so the
// ordering FSM meets real numbers, exponents and junk).
// ---------------------------------------------------------------------------

const text_alphabet = "aAbB0_\xc3\xa9\"";
const num_alphabet = "0123456789.eE+- \t";

const cell_lens = [_]usize{ 0, 1, 2, 3, 7, 15, 16, 17, 18, 19, 31, 32, 33, 34, 39, 47, 63, 64, 65, 80, 129, 300, 1031 };

fn fillRandom(rand: std.Random, buf: []u8, alphabet: []const u8) void {
    for (buf) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
}

const ops = [_]Op{ .eq, .ne, .lt, .gt, .le, .ge };

fn sweep(gpa: std.mem.Allocator, seed: u64, cases: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    const cell_buf = try gpa.alloc(u8, 4096);
    defer gpa.free(cell_buf);
    const q_buf = try gpa.alloc(u8, 64);
    defer gpa.free(q_buf);

    var n: usize = 0;
    while (n < cases) : (n += 1) {
        const numeric = rand.boolean();
        const alphabet = if (numeric) num_alphabet else text_alphabet;
        const cell_len = @min(cell_buf.len, cell_lens[rand.uintLessThan(usize, cell_lens.len)]);
        const cell = cell_buf[0..cell_len];
        fillRandom(rand, cell, alphabet);

        // Half the queries are SUBSTRINGS of the cell (optionally case-flipped),
        // so the expected verdict is usually "match" and a false negative in the
        // prefilter cannot hide behind a random non-match.
        var query: []u8 = undefined;
        if (cell_len > 0 and rand.boolean()) {
            const qlen = 1 + rand.uintLessThan(usize, @min(q_buf.len, cell_len));
            const at = rand.uintLessThan(usize, cell_len - qlen + 1);
            query = q_buf[0..qlen];
            @memcpy(query, cell[at..][0..qlen]);
            if (rand.boolean()) for (query) |*b| {
                if (rand.boolean()) b.* = switch (b.*) {
                    'a'...'z' => b.* - 32,
                    'A'...'Z' => b.* + 32,
                    else => b.*,
                };
            };
        } else {
            const qlen = rand.uintLessThan(usize, 8);
            query = q_buf[0..qlen];
            fillRandom(rand, query, alphabet);
        }

        const fold = rand.boolean();
        const unit: usize = switch (rand.uintLessThan(u8, 4)) {
            0 => 1,
            1 => 2,
            2 => 4,
            else => 0,
        };
        try checkOne(gpa, cell, query, fold, .text, .eq, unit);
        try checkOne(gpa, cell, query, fold, .predicate, ops[rand.uintLessThan(usize, ops.len)], unit);
    }
}

test "matcher differential: streaming vs whole-cell vs naive reference" {
    // Fixed seeds: a failure here is reproducible from the printed case, and the
    // sweep is part of `zig build diff` rather than a fuzz campaign.
    for ([_]u64{ 1, 2, 1337, 0xC0FFEE, 0xDEADBEEF }) |seed| {
        try sweep(std.testing.allocator, seed, 4000);
    }
}

test "matcher differential: pinned semantics that must never move" {
    const gpa = std.testing.allocator;

    // An empty query matches for TEXT (ls_search_start rejects one, but
    // ls_window_match_flags asks with whatever is active).
    {
        var q = try matcher.Query.init(gpa, "", false, .text);
        defer q.deinit(gpa);
        const ctx: MatchCtx = .{ .kind = .text, .q = &q, .column_count = 1 };
        try std.testing.expect(matcher.cellMatches(ctx, 0, "anything"));
        var sc = matcher.StreamCell.init(ctx, 0);
        sc.feed("anything");
        try std.testing.expect(sc.matches());
    }
    // A query longer than the cell never matches.
    {
        var q = try matcher.Query.init(gpa, "abcdef", false, .text);
        defer q.deinit(gpa);
        const ctx: MatchCtx = .{ .kind = .text, .q = &q, .column_count = 1 };
        try std.testing.expect(!matcher.cellMatches(ctx, 0, "abc"));
        var sc = matcher.StreamCell.init(ctx, 0);
        sc.feed("abc");
        try std.testing.expect(!sc.matches());
    }
    // Folding is ASCII 'A'..'Z' only: every byte >= 0x80 compares EXACTLY, so
    // two different high bytes never fold together.
    {
        var q = try matcher.Query.init(gpa, "\xc3\xa9", true, .text);
        defer q.deinit(gpa);
        const ctx: MatchCtx = .{ .kind = .text, .q = &q, .column_count = 1 };
        try std.testing.expect(matcher.cellMatches(ctx, 0, "x\xc3\xa9y"));
        try std.testing.expect(!matcher.cellMatches(ctx, 0, "x\xc3\x89y"));
        var sc = matcher.StreamCell.init(ctx, 0);
        sc.feed("x\xc3\x89y");
        try std.testing.expect(!sc.matches());
    }
    // An out-of-scope column never matches (TEXT), and a predicate matches only
    // on its own column.
    {
        var q = try matcher.Query.init(gpa, "a", false, .text);
        defer q.deinit(gpa);
        const mask = [_]bool{ false, true };
        const ctx: MatchCtx = .{ .kind = .text, .q = &q, .scope_mask = &mask, .column_count = 2 };
        try std.testing.expect(!matcher.cellMatches(ctx, 0, "a"));
        try std.testing.expect(matcher.cellMatches(ctx, 1, "a"));
    }
    {
        var q = try matcher.Query.init(gpa, "5", false, .predicate);
        defer q.deinit(gpa);
        const ctx: MatchCtx = .{ .kind = .predicate, .op = .lt, .column = 1, .q = &q, .column_count = 2 };
        try std.testing.expect(!matcher.cellMatches(ctx, 0, "1"));
        try std.testing.expect(matcher.cellMatches(ctx, 1, "1"));
        // A non-numeric cell never satisfies an ordering predicate.
        try std.testing.expect(!matcher.cellMatches(ctx, 1, "abc"));
        var sc = matcher.StreamCell.init(ctx, 1);
        sc.feed("abc");
        try std.testing.expect(!sc.matches());
    }
}

test "matcher differential: fuzz target (Smith-driven)" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var cell_buf: [4096]u8 = undefined;
    var q_buf: [64]u8 = undefined;
    const cell_len = smith.slice(&cell_buf);
    const q_len = smith.slice(&q_buf);
    const cell = cell_buf[0..cell_len];
    const query = q_buf[0..q_len];
    const fold = smith.valueRangeAtMost(u8, 0, 1) == 1;
    // Fixed-width draws only: Smith's replay ABI rejects usize.
    const unit: usize = smith.valueRangeAtMost(u8, 0, 4);
    const op = ops[smith.valueRangeAtMost(u8, 0, ops.len - 1)];
    try checkOne(std.testing.allocator, cell, query, fold, .text, .eq, unit);
    try checkOne(std.testing.allocator, cell, query, fold, .predicate, op, unit);
}
