//! The matcher: numeric-cell grammar (isNumeric), EXACT decimal comparison
//! (never through f64), and the allocation-free per-row predicate/text
//! matcher that runs inside every scan loop (search match-scan, filter scan,
//! navigation re-lex). None of this needs a `*Document` — it is pure logic
//! over an already-decoded record (see api/lesssheet.h SEARCH and HEADER
//! RULE for the pinned grammars).

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");

const CellRef = base.CellRef;
const MatchCtx = base.MatchCtx;
const Decimal = base.Decimal;

// ---------------------------------------------------------------------------
// Numeric-cell test (pinned grammar — see api/lesssheet.h HEADER RULE).
//   sign? ( digits ('.' digits?)? | '.' digits ) ( ('e'|'E') sign? digits )?
// after trimming ASCII whitespace (0x09..0x0D, 0x20); remainder must be
// non-empty and match fully. Decimal separator '.' only; ASCII digits only.
// ---------------------------------------------------------------------------

fn isAsciiWs(ch: u8) bool {
    return ch == 0x20 or (ch >= 0x09 and ch <= 0x0D);
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

pub fn isNumeric(raw: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = raw.len;
    while (lo < hi and isAsciiWs(raw[lo])) lo += 1;
    while (hi > lo and isAsciiWs(raw[hi - 1])) hi -= 1;
    const s = raw[lo..hi];
    if (s.len == 0) return false;

    var i: usize = 0;
    if (s[i] == '+' or s[i] == '-') i += 1;

    var int_digits: usize = 0;
    while (i < s.len and isDigit(s[i])) : (i += 1) int_digits += 1;

    var has_significand = int_digits > 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var frac_digits: usize = 0;
        while (i < s.len and isDigit(s[i])) : (i += 1) frac_digits += 1;
        if (int_digits == 0 and frac_digits == 0) return false; // lone '.'
        if (frac_digits > 0) has_significand = true;
    } else if (int_digits == 0) {
        return false; // needs the 'digits' form when there is no dot
    }
    if (!has_significand) return false;

    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < s.len and isDigit(s[i])) : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return false; // dangling exponent
    }
    return i == s.len;
}

// ---------------------------------------------------------------------------
// EXACT decimal comparison (mathematical value; never through f64).
// A number parses under the SAME pinned grammar as isNumeric, then compares by
// sign, then order-of-magnitude of the most-significant significant digit, then
// digit sequence — so "2.0"=="2", "1e2"=="100", 39-digit ids and 2^53±1 order
// correctly, and "1e400">"1e399". Exponents beyond i64 saturate (documented).
// ---------------------------------------------------------------------------

pub const Order = std.math.Order;

/// Parse `raw` under the pinned numeric grammar into an exact Decimal. Invalid
/// (non-numeric) input yields `.valid == false`. Allocation-free.
pub fn parseDecimal(raw: []const u8) Decimal {
    var lo: usize = 0;
    var hi: usize = raw.len;
    while (lo < hi and isAsciiWs(raw[lo])) lo += 1;
    while (hi > lo and isAsciiWs(raw[hi - 1])) hi -= 1;
    const s = raw[lo..hi];
    if (s.len == 0) return .{};

    var i: usize = 0;
    var negative = false;
    if (s[0] == '+') {
        i = 1;
    } else if (s[0] == '-') {
        negative = true;
        i = 1;
    }

    const int_start = i;
    while (i < s.len and isDigit(s[i])) i += 1;
    const int_part = s[int_start..i];

    var frac_part: []const u8 = s[0..0];
    var has_sig = int_part.len > 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and isDigit(s[i])) i += 1;
        frac_part = s[frac_start..i];
        if (int_part.len == 0 and frac_part.len == 0) return .{}; // lone '.'
        if (frac_part.len > 0) has_sig = true;
    } else if (int_part.len == 0) {
        return .{}; // needs the 'digits' form when there is no dot
    }
    if (!has_sig) return .{};

    var exp: i64 = 0;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        var esign = false;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            esign = s[i] == '-';
            i += 1;
        }
        const edig_start = i;
        var e_acc: i64 = 0;
        var saturated = false;
        while (i < s.len and isDigit(s[i])) : (i += 1) {
            if (!saturated) {
                e_acc = (e_acc *| 10) +| @as(i64, s[i] - '0');
                if (e_acc == std.math.maxInt(i64)) saturated = true;
            }
        }
        if (i == edig_start) return .{}; // dangling exponent
        exp = if (esign) -e_acc else e_acc;
    }
    if (i != s.len) return .{}; // trailing junk

    // First & last significant (nonzero) digits across int_part ++ frac_part.
    const total = int_part.len + frac_part.len;
    var f: usize = 0;
    var found_first = false;
    var l: usize = 0;
    var k: usize = 0;
    while (k < total) : (k += 1) {
        const d = if (k < int_part.len) int_part[k] else frac_part[k - int_part.len];
        if (d != '0') {
            if (!found_first) {
                f = k;
                found_first = true;
            }
            l = k;
        }
    }
    if (!found_first) {
        return .{ .valid = true, .negative = negative, .zero = true, .int_part = int_part, .frac_part = frac_part };
    }
    const msd_pos = exp +| @as(i64, @intCast(int_part.len)) -| 1 -| @as(i64, @intCast(f));
    return .{
        .valid = true,
        .negative = negative,
        .zero = false,
        .int_part = int_part,
        .frac_part = frac_part,
        .first = f,
        .sig_len = l - f + 1,
        .msd_pos = msd_pos,
    };
}

fn compareMagnitude(a: Decimal, b: Decimal) Order {
    if (a.msd_pos != b.msd_pos) return if (a.msd_pos > b.msd_pos) .gt else .lt;
    var i: usize = 0;
    while (i < a.sig_len and i < b.sig_len) : (i += 1) {
        const da = a.sigDigit(i);
        const db = b.sigDigit(i);
        if (da != db) return if (da > db) .gt else .lt;
    }
    if (a.sig_len == b.sig_len) return .eq;
    return if (a.sig_len > b.sig_len) .gt else .lt;
}

/// Total order on two VALID Decimals by mathematical value.
pub fn compareDecimal(a: Decimal, b: Decimal) Order {
    if (a.zero and b.zero) return .eq;
    if (a.zero) return if (b.negative) .gt else .lt;
    if (b.zero) return if (a.negative) .lt else .gt;
    if (a.negative != b.negative) return if (a.negative) .lt else .gt;
    const mag = compareMagnitude(a, b);
    return if (a.negative) mag.invert() else mag;
}

pub fn asciiLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

/// The ASCII-uppercase twin of an already-folded byte — identity unless it is
/// 'a'..'z'. Used ONLY to turn a folded compare into two exact splat compares
/// (see `Query.anchor0_upper`); `asciiLower` stays the definition of folding.
fn asciiUpper(b: u8) u8 {
    return if (b >= 'a' and b <= 'z') b - 32 else b;
}

/// KMP prefix table over an ALREADY-FOLDED query (`Query.folded`), one entry
/// per query byte. Private on purpose: `Query.init` is the single builder, so
/// no second site can derive a table that disagrees with the folded query it
/// is supposed to describe.
fn buildFailure(gpa: std.mem.Allocator, query: []const u8) std.mem.Allocator.Error![]usize {
    if (query.len == 0) return gpa.alloc(usize, 0);
    const table = try gpa.alloc(usize, query.len);
    table[0] = 0;
    var k: usize = 0;
    var i: usize = 1;
    while (i < query.len) : (i += 1) {
        const b = query[i];
        while (k > 0 and b != query[k]) k = table[k - 1];
        if (b == query[k]) k += 1;
        table[i] = k;
    }
    return table;
}

/// Everything DERIVED from one accepted request's query, computed exactly ONCE
/// (`init`, when ls_search_start / ls_filter_set accepts the request) and only
/// read afterwards — by the streaming scan (`StreamCell`), the per-cell verdict
/// (`cellMatches`), the nav re-lex and the window highlight flags.
///
/// Single source of truth for the derived artifacts: one struct owns them and
/// every consumer reads it through `MatchCtx.q`, so a folded query and the
/// table describing it cannot drift apart.
///
/// The empty query (`.{}` / `empty`) is legal and means "matches" for TEXT —
/// see `textMatch` and `StreamCell.init`.
pub const Query = struct {
    /// The query bytes EXACTLY as requested (owned).
    value: []const u8 = &.{},
    /// `value` with ASCII 'A'..'Z' lowered when `fold`, else byte-identical to
    /// `value`. Always its OWN allocation (never an alias of `value`), so
    /// `deinit` is unconditional and copy-free reasoning stays simple.
    ///
    /// Every byte loop compares cell bytes against THIS, so `asciiLower` is
    /// never applied to a query byte inside a loop: folding the query is
    /// per-request work, not per-byte work. Sound because `asciiLower` only
    /// maps 'A'..'Z' and is the identity on every byte >= 0x80, so
    /// `asciiLower(cell) == folded[k]` is exactly `asciiLower(cell) ==
    /// asciiLower(value[k])`.
    folded: []const u8 = &.{},
    /// KMP prefix table over `folded`; empty unless the request is TEXT (no
    /// other kind can consult it, and the table costs 8 bytes per query byte).
    failure: []const usize = &.{},
    /// `value` parsed under the pinned numeric grammar — the ordering
    /// predicates' comparison operand; `.valid == false` when the query is not
    /// numeric. BORROWS `value`, which is why a Query is duplicated with
    /// `clone` and never by plain assignment.
    value_dec: Decimal = .{},
    /// Fold ASCII case (== !request.case_sensitive): TEXT substring and
    /// predicate EQ/NE. Ordering predicates ignore it.
    fold: bool = false,
    /// Whether this query was derived for a TEXT request — i.e. THE INPUT that
    /// decided which artifacts to derive (only TEXT can consult `failure`).
    /// Recorded rather than inferred: `clone` needs to reproduce the same
    /// decision, and inferring it from a derived artifact (`failure.len > 0`)
    /// would make "a clone can never come out weaker than its source" true only
    /// incidentally — it holds today just because both request sites reject an
    /// empty TEXT query. Not a second source of truth for the request kind:
    /// `MatchCtx.kind` remains that, and this records what was DERIVED here.
    is_text: bool = false,

    /// Anchor constants for the TEXT scan's vector prefilter (see
    /// `StreamCell.feedText`): the first `folded` byte and — when the query has
    /// at least two — the second, each paired with its ASCII-uppercase twin.
    /// A folded compare is then two EXACT splat compares per block, with no
    /// folding of a query byte and no per-byte work at all:
    /// `asciiLower(cell) == folded[j]` iff `cell == anchor_j or cell ==
    /// anchor_j_upper`, because `folded[j]` is never 'A'..'Z'. When the request
    /// is case-sensitive (or the byte is not a letter) the twin equals the byte
    /// and the second compare is redundant, never wrong.
    anchor0: u8 = 0,
    anchor0_upper: u8 = 0,
    anchor1: u8 = 0,
    anchor1_upper: u8 = 0,

    /// The default (empty, case-sensitive) query. `MatchCtx.q` points here
    /// until a request is accepted, which keeps a default `MatchCtx` valid
    /// without an allocation.
    pub const empty: Query = .{};

    /// Derive every artifact from one request. Allocates; on OOM nothing is
    /// retained and the caller rejects the request unchanged. The ONE place that
    /// decides a request kind needs a KMP table.
    pub fn init(gpa: std.mem.Allocator, value: []const u8, fold: bool, kind: api.SearchKind) std.mem.Allocator.Error!Query {
        return build(gpa, value, fold, kind == .text);
    }

    /// An independent copy — the worker's lock-free snapshot, so the document's
    /// request buffers can be replaced/freed underneath it. Re-derives rather
    /// than memcpy-ing, because `value_dec` borrows `value`.
    ///
    /// Takes no `kind`: a clone must never come out WEAKER than its source, and
    /// passing one would allow exactly that — cloning a TEXT query as a
    /// predicate would drop the KMP table that `feedText` indexes. It replays
    /// the source's own recorded decision (`is_text`), so the two are identical
    /// by construction rather than by coincidence.
    pub fn clone(self: Query, gpa: std.mem.Allocator) std.mem.Allocator.Error!Query {
        return build(gpa, self.value, self.fold, self.is_text);
    }

    fn build(gpa: std.mem.Allocator, value: []const u8, fold: bool, is_text: bool) std.mem.Allocator.Error!Query {
        const value_copy = try gpa.dupe(u8, value);
        errdefer gpa.free(value_copy);
        const folded = try gpa.dupe(u8, value);
        errdefer gpa.free(folded);
        if (fold) {
            for (folded) |*b| b.* = asciiLower(b.*);
        }
        const failure = if (is_text) try buildFailure(gpa, folded) else try gpa.alloc(usize, 0);
        const a0: u8 = if (folded.len > 0) folded[0] else 0;
        const a1: u8 = if (folded.len > 1) folded[1] else 0;
        return .{
            .value = value_copy,
            .folded = folded,
            .failure = failure,
            .value_dec = parseDecimal(value_copy),
            .fold = fold,
            .is_text = is_text,
            .anchor0 = a0,
            .anchor0_upper = if (fold) asciiUpper(a0) else a0,
            .anchor1 = a1,
            .anchor1_upper = if (fold) asciiUpper(a1) else a1,
        };
    }

    /// `Allocator.free` returns early on a zero-length slice, so this is also
    /// correct for a default-constructed (never-allocated) Query.
    pub fn deinit(self: *Query, gpa: std.mem.Allocator) void {
        gpa.free(self.value);
        gpa.free(self.folded);
        gpa.free(self.failure);
        self.* = .{};
    }
};

/// Allocation-free streaming state for one decoded cell.  TEXT computes the
/// KMP fallback from the query when needed, keeping resident state constant;
/// EQ/NE track exact length/content without retaining cell bytes.
pub const StreamCell = struct {
    ctx: MatchCtx,
    col: u32,
    text_k: usize = 0,
    text_found: bool = false,
    equal: bool = true,
    len: usize = 0,
    num_phase: NumericPhase = .leading,
    num_negative: bool = false,
    num_int_digits: u64 = 0,
    num_total_digits: u64 = 0,
    num_first: ?u64 = null,
    num_sig_seen: u64 = 0,
    num_order: Order = .eq,
    num_saw_digit: bool = false,
    num_exp_negative: bool = false,
    num_exp: i64 = 0,
    num_exp_digits: u64 = 0,

    const NumericPhase = enum { leading, mantissa, fraction, exp_start, exponent, trailing, invalid };

    pub fn init(ctx: MatchCtx, col: u32) StreamCell {
        return .{ .ctx = ctx, .col = col, .text_found = ctx.kind == .text and ctx.q.value.len == 0 };
    }

    fn feedDigit(self: *StreamCell, b: u8, integer: bool) void {
        const at = self.num_total_digits;
        self.num_total_digits +|= 1;
        if (integer) self.num_int_digits +|= 1;
        self.num_saw_digit = true;
        if (self.num_first == null and b != '0') self.num_first = at;
        if (self.num_first) |first| if (at >= first) {
            const sig: usize = @intCast(@min(at - first, std.math.maxInt(usize)));
            const qd = if (sig < self.ctx.q.value_dec.sig_len) self.ctx.q.value_dec.sigDigit(sig) else '0';
            if (self.num_order == .eq and b != qd) self.num_order = if (b < qd) .lt else .gt;
            self.num_sig_seen +|= 1;
        };
    }

    fn feedNumeric(self: *StreamCell, b: u8) void {
        var again = true;
        while (again) {
            again = false;
            switch (self.num_phase) {
                .leading => {
                    if (isAsciiWs(b)) return;
                    if (b == '+' or b == '-') {
                        self.num_negative = b == '-';
                        self.num_phase = .mantissa;
                    } else {
                        self.num_phase = .mantissa;
                        again = true;
                    }
                },
                .mantissa => {
                    if (isDigit(b)) self.feedDigit(b, true) else if (b == '.') self.num_phase = .fraction else if ((b == 'e' or b == 'E') and self.num_saw_digit) self.num_phase = .exp_start else if (isAsciiWs(b) and self.num_saw_digit) self.num_phase = .trailing else self.num_phase = .invalid;
                },
                .fraction => {
                    if (isDigit(b)) self.feedDigit(b, false) else if ((b == 'e' or b == 'E') and self.num_saw_digit) self.num_phase = .exp_start else if (isAsciiWs(b) and self.num_saw_digit) self.num_phase = .trailing else self.num_phase = .invalid;
                },
                .exp_start => {
                    if (b == '+' or b == '-') {
                        self.num_exp_negative = b == '-';
                        self.num_phase = .exponent;
                    } else if (isDigit(b)) {
                        self.num_phase = .exponent;
                        again = true;
                    } else self.num_phase = .invalid;
                },
                .exponent => {
                    if (isDigit(b)) {
                        self.num_exp_digits +|= 1;
                        self.num_exp = (self.num_exp *| 10) +| @as(i64, b - '0');
                    } else if (isAsciiWs(b) and self.num_exp_digits > 0) self.num_phase = .trailing else self.num_phase = .invalid;
                },
                .trailing => {
                    if (!isAsciiWs(b)) self.num_phase = .invalid;
                },
                .invalid => {},
            }
        }
    }

    /// Feed the next decoded bytes of the current cell.
    ///
    /// Every arm STOPS as soon as this cell's verdict can no longer change —
    /// multi-megabyte cells are a supported shape (outlier-budget policy), so
    /// a decided cell must not cost an iteration per remaining byte:
    ///   * TEXT once the query was found (`text_found` is monotone),
    ///   * EQ/NE once a byte disproved `equal` (it never recovers, and
    ///     `matches()` reads `len` only through `equal`),
    ///   * ordering once `num_phase` reached `.invalid` (a terminal state whose
    ///     verdict is a fixed `false`; the digit tallies are then never read).
    /// `init` is the ONLY constructor, and it sets `text_found` for the empty
    /// query — the one case that must report a match with no bytes to compare —
    /// so the TEXT guard below also covers `value.len == 0` and the indexing of
    /// `value[text_k]` past it is always in bounds.
    pub fn feed(self: *StreamCell, bytes: []const u8) void {
        // Both request-fixed discriminants (kind/op, and `fold` inside the two
        // byte loops below) are tested ONCE per call, never per byte.
        switch (self.ctx.kind) {
            .text => {
                if (self.text_found) return;
                if (self.ctx.q.fold) self.feedText(bytes, true) else self.feedText(bytes, false);
            },
            .predicate => switch (self.ctx.op) {
                .eq, .ne => {
                    if (!self.equal) return;
                    if (self.ctx.q.fold) self.feedEqual(bytes, true) else self.feedEqual(bytes, false);
                },
                .lt, .gt, .le, .ge => {
                    if (self.num_phase == .invalid) return;
                    for (bytes) |b| {
                        self.feedNumeric(b);
                        if (self.num_phase == .invalid) return;
                    }
                },
            },
        }
    }

    /// Vector width for the anchor prefilter, 0 on a target without SIMD (the
    /// whole prefilter is then comptime-dead and TEXT is pure `feedTextScalar`).
    const anchor_vec_len: usize = std.simd.suggestVectorLength(u8) orelse 0;

    /// TEXT substring search over one run of cell bytes.
    ///
    /// While the KMP cursor is at 0 there is no match in progress and KMP does
    /// nothing but hunt for the query's first byte, so every position that
    /// cannot START a match may be skipped — that part is vectorizable, and a
    /// long cell spends nearly all its bytes there. The prefilter tests the
    /// first query byte AND (when the query has one) the second, which is what
    /// keeps a query whose first byte is common — a digit against a numeric
    /// column — from degenerating into one block scan per byte.
    ///
    /// Only positions with a full block-plus-second-byte span left are claimed,
    /// so the prefilter never needs a byte beyond this run: a match straddling
    /// two `feed` calls is still found by the scalar KMP that owns the tail and
    /// carries `text_k` across calls.
    fn feedText(self: *StreamCell, bytes: []const u8, comptime fold: bool) void {
        if (comptime anchor_vec_len == 0) return self.feedTextScalar(bytes, fold);
        const q = self.ctx.q;
        const two = q.folded.len >= 2;
        const span = anchor_vec_len + @intFromBool(two);
        // Short runs (every cell of a typical narrow CSV, and every unit of the
        // decode-per-unit streaming path) go straight to the scalar loop: they
        // must not pay a byte of prefilter setup.
        if (bytes.len < span) return self.feedTextScalar(bytes, fold);

        const query = q.folded;
        const failure = q.failure;
        const V = @Vector(anchor_vec_len, u8);
        const s0: V = @splat(q.anchor0);
        const s0u: V = @splat(q.anchor0_upper);
        const s1: V = @splat(q.anchor1);
        const s1u: V = @splat(q.anchor1_upper);
        var k = self.text_k;
        var i: usize = 0;
        while (i < bytes.len) {
            if (k == 0) {
                while (bytes.len - i >= span) {
                    const v0: V = bytes[i..][0..anchor_vec_len].*;
                    var m = v0 == s0;
                    if (fold) m = m | (v0 == s0u);
                    if (two) {
                        const v1: V = bytes[i + 1 ..][0..anchor_vec_len].*;
                        var m1 = v1 == s1;
                        if (fold) m1 = m1 | (v1 == s1u);
                        m = m & m1;
                    }
                    if (@reduce(.Or, m)) {
                        i += std.simd.firstTrue(m).?;
                        break;
                    }
                    i += anchor_vec_len;
                }
                // Out of full spans: the rest is the scalar loop's, which is
                // also the only path allowed to end mid-match.
                if (bytes.len - i < span) break;
            }
            const b = if (fold) asciiLower(bytes[i]) else bytes[i];
            while (k > 0 and b != query[k]) k = failure[k - 1];
            if (b == query[k]) k += 1;
            i += 1;
            if (k == query.len) {
                self.text_k = k;
                self.text_found = true;
                return;
            }
        }
        self.text_k = k;
        if (i < bytes.len) self.feedTextScalar(bytes[i..], fold);
    }

    /// Plain KMP over one run. `query` is the PRE-FOLDED query, so the only
    /// per-byte fold is on the cell byte and `comptime fold` keeps even that
    /// test out of the loop body. The cursor lives in a local and is written
    /// back once — reading it through `self` every byte was a dependent load
    /// per byte. This is the reference behavior for the whole TEXT arm: the
    /// vector path above only skips positions this loop would have rejected.
    fn feedTextScalar(self: *StreamCell, bytes: []const u8, comptime fold: bool) void {
        const query = self.ctx.q.folded;
        const failure = self.ctx.q.failure;
        var k = self.text_k;
        for (bytes) |raw| {
            const b = if (fold) asciiLower(raw) else raw;
            while (k > 0 and b != query[k]) k = failure[k - 1];
            if (b == query[k]) k += 1;
            if (k == query.len) {
                self.text_k = k;
                self.text_found = true;
                return;
            }
        }
        self.text_k = k;
    }

    /// Predicate EQ/NE: compare the cell against the query byte for byte.
    /// Comparing the folded cell byte to the pre-folded query byte is exactly
    /// `asciiLower(cell) == asciiLower(query)`, and byte-exact when `!fold`
    /// (`folded` is then byte-identical to `value`), so every byte >= 0x80
    /// still compares exactly.
    fn feedEqual(self: *StreamCell, bytes: []const u8, comptime fold: bool) void {
        const query = self.ctx.q.folded;
        var len = self.len;
        for (bytes) |raw| {
            const b = if (fold) asciiLower(raw) else raw;
            if (len >= query.len or b != query[len]) {
                self.equal = false;
                self.len = len + 1;
                return;
            }
            len += 1;
        }
        self.len = len;
    }

    pub fn matches(self: StreamCell) bool {
        return switch (self.ctx.kind) {
            .text => self.text_found,
            .predicate => switch (self.ctx.op) {
                .eq => self.equal and self.len == self.ctx.q.value.len,
                .ne => !(self.equal and self.len == self.ctx.q.value.len),
                .lt, .gt, .le, .ge => self.numericMatches(),
            },
        };
    }

    fn numericMatches(self: StreamCell) bool {
        const valid = self.num_saw_digit and self.num_phase != .invalid and self.num_phase != .leading and self.num_phase != .exp_start and
            (self.num_phase != .exponent or self.num_exp_digits > 0);
        if (!valid) return false;
        const q = self.ctx.q.value_dec;
        const zero = self.num_first == null;
        var ord: Order = .eq;
        if (zero and q.zero) ord = .eq else if (zero) ord = if (q.negative) .gt else .lt else if (q.zero) ord = if (self.num_negative) .lt else .gt else if (self.num_negative != q.negative) ord = if (self.num_negative) .lt else .gt else {
            const exp = if (self.num_exp_negative) -self.num_exp else self.num_exp;
            const msd = exp +| @as(i64, @intCast(@min(self.num_int_digits, std.math.maxInt(i64)))) -| 1 -| @as(i64, @intCast(@min(self.num_first.?, std.math.maxInt(i64))));
            var magnitude: Order = if (msd != q.msd_pos) (if (msd < q.msd_pos) .lt else .gt) else self.num_order;
            if (msd == q.msd_pos and magnitude == .eq) {
                var i: usize = @intCast(@min(self.num_sig_seen, std.math.maxInt(usize)));
                while (i < q.sig_len) : (i += 1) if (q.sigDigit(i) != '0') {
                    magnitude = .lt;
                    break;
                };
            }
            ord = if (self.num_negative) magnitude.invert() else magnitude;
        }
        return switch (self.ctx.op) {
            .lt => ord == .lt,
            .gt => ord == .gt,
            .le => ord != .gt,
            .ge => ord != .lt,
            else => unreachable,
        };
    }
};

/// ASCII-case-aware byte equality for the predicate EQ/NE match: byte-exact when
/// `!q.fold`; when folding, ASCII letters compare case-folded while every byte
/// >= 0x80 stays exact (asciiLower is identity outside 'A'..'Z' — and `q.folded`
/// is byte-identical to `q.value` when not folding).
fn bytesEqual(cell: []const u8, q: *const Query) bool {
    if (cell.len != q.folded.len) return false;
    if (!q.fold) return std.mem.eql(u8, cell, q.folded);
    for (cell, q.folded) |x, y| if (asciiLower(x) != y) return false;
    return true;
}

/// Substring match: fold ASCII case iff `q.fold` (case-insensitive), else
/// byte-exact. Bytes >= 0x80 (all non-ASCII) always compare exactly. An empty
/// query matches (`ls_search_start` rejects one, but `ls_window_match_flags`
/// asks with whatever is active).
///
/// The interactive-latency twin of `StreamCell` (nav re-lex, filtered-window
/// predicate, highlight flags) — deliberately still the naive scan, since it
/// runs over one visible cell, not over the file. It reads the SAME
/// `Query.folded` the scan reads, so the two cannot disagree about what the
/// query is, and the two verdicts must always agree.
fn textMatch(cell: []const u8, q: *const Query) bool {
    const query = q.folded;
    if (query.len == 0) return true;
    if (query.len > cell.len) return false;
    const last = cell.len - query.len;
    var start: usize = 0;
    while (start <= last) : (start += 1) {
        var k: usize = 0;
        while (k < query.len) : (k += 1) {
            const a = if (q.fold) asciiLower(cell[start + k]) else cell[start + k];
            if (a != query[k]) break;
        }
        if (k == query.len) return true;
    }
    return false;
}

/// Per-cell match verdict: does column `col`'s decoded cell bytes satisfy the
/// active request `ctx`? This is the single per-column decision `matchRecord`
/// (below) is composed from, exposed so `window.matchFlags`
/// (ls_window_match_flags) reports the EXACT same verdict per visible cell —
/// no re-derived grammar, no second matcher.
///   * TEXT: 1 iff `col` is IN SCOPE (empty scope_mask == all columns) AND the
///     smart-case substring rule holds; an out-of-scope column is always 0.
///   * PREDICATE: 1 only on the target `ctx.column` (every other column 0), and
///     there iff the operator holds — EQ/NE ASCII-folded per `ctx.q.fold`
///     (byte-exact when case-sensitive), LT/GT/LE/GE the
///     exact-decimal comparison (a non-numeric cell never matches an ordering
///     op; the empty value is legal).
/// Allocation-free; pure over the passed bytes.
pub fn cellMatches(ctx: MatchCtx, col: u32, cell: []const u8) bool {
    switch (ctx.kind) {
        .text => {
            if (ctx.scope_mask.len != 0 and (col >= ctx.scope_mask.len or !ctx.scope_mask[col])) return false;
            return textMatch(cell, ctx.q);
        },
        .predicate => {
            if (col != ctx.column) return false;
            return switch (ctx.op) {
                .eq => bytesEqual(cell, ctx.q),
                .ne => !bytesEqual(cell, ctx.q),
                .lt, .gt, .le, .ge => blk: {
                    const cd = parseDecimal(cell);
                    if (!cd.valid) break :blk false; // non-numeric cell never matches ordering
                    const ord = compareDecimal(cd, ctx.q.value_dec);
                    break :blk switch (ctx.op) {
                        .lt => ord == .lt,
                        .gt => ord == .gt,
                        .le => ord != .gt,
                        .ge => ord != .lt,
                        else => unreachable,
                    };
                },
            };
        },
    }
}

/// Evaluate the matcher on a decoded record. Returns the matched column (lowest
/// in-scope for TEXT; the predicate column for PREDICATE) or null. `refs` has
/// exactly `column_count` entries (truncate/pad already applied, == ls_cell).
/// Composed from the per-cell `cellMatches` decision, so a whole-row match and
/// a per-cell highlight verdict can never drift apart.
pub fn matchRecord(ctx: MatchCtx, buf: []const u8, refs: []const CellRef) ?u32 {
    switch (ctx.kind) {
        .text => {
            var col: u32 = 0;
            while (col < ctx.column_count) : (col += 1) {
                if (col >= refs.len) break;
                const ref = refs[col];
                if (cellMatches(ctx, col, buf[ref.start .. ref.start + ref.len])) return col;
            }
            return null;
        },
        .predicate => {
            if (ctx.column >= refs.len) return null;
            const ref = refs[ctx.column];
            return if (cellMatches(ctx, ctx.column, buf[ref.start .. ref.start + ref.len])) ctx.column else null;
        },
    }
}
