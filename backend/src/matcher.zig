//! The matcher: numeric-cell grammar (isNumeric), EXACT decimal comparison
//! (never through f64), and the allocation-free per-row predicate/text
//! matcher that runs inside every scan loop (search match-scan, filter scan,
//! navigation re-lex). None of this needs a `*Document` — it is pure logic
//! over an already-decoded record (see api/lesssheet.h SEARCH and HEADER
//! RULE for the pinned grammars).

const std = @import("std");
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

// ---------------------------------------------------------------------------
// The matcher (allocation-free per row; runs inside the scan loop).
// ---------------------------------------------------------------------------

pub fn asciiLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

pub fn buildFailure(gpa: std.mem.Allocator, query: []const u8, fold: bool) std.mem.Allocator.Error![]usize {
    if (query.len == 0) return gpa.alloc(usize, 0);
    const table = try gpa.alloc(usize, query.len);
    table[0] = 0;
    var k: usize = 0;
    var i: usize = 1;
    while (i < query.len) : (i += 1) {
        const b = if (fold) asciiLower(query[i]) else query[i];
        while (k > 0 and b != (if (fold) asciiLower(query[k]) else query[k])) k = table[k - 1];
        if (b == (if (fold) asciiLower(query[k]) else query[k])) k += 1;
        table[i] = k;
    }
    return table;
}

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
        return .{ .ctx = ctx, .col = col, .text_found = ctx.kind == .text and ctx.value.len == 0 };
    }

    fn eqByte(self: StreamCell, a: u8, b: u8) bool {
        return if (self.ctx.fold) asciiLower(a) == asciiLower(b) else a == b;
    }

    fn feedDigit(self: *StreamCell, b: u8, integer: bool) void {
        const at = self.num_total_digits;
        self.num_total_digits +|= 1;
        if (integer) self.num_int_digits +|= 1;
        self.num_saw_digit = true;
        if (self.num_first == null and b != '0') self.num_first = at;
        if (self.num_first) |first| if (at >= first) {
            const sig: usize = @intCast(@min(at - first, std.math.maxInt(usize)));
            const qd = if (sig < self.ctx.value_dec.sig_len) self.ctx.value_dec.sigDigit(sig) else '0';
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

    pub fn feed(self: *StreamCell, bytes: []const u8) void {
        switch (self.ctx.kind) {
            .text => for (bytes) |b| {
                if (self.text_found or self.ctx.value.len == 0) continue;
                while (self.text_k > 0 and !self.eqByte(b, self.ctx.value[self.text_k])) self.text_k = self.ctx.failure[self.text_k - 1];
                if (self.eqByte(b, self.ctx.value[self.text_k])) self.text_k += 1;
                if (self.text_k == self.ctx.value.len) self.text_found = true;
            },
            .predicate => for (bytes) |b| if (self.ctx.op == .eq or self.ctx.op == .ne) {
                if (self.len >= self.ctx.value.len or !self.eqByte(b, self.ctx.value[self.len])) self.equal = false;
                self.len += 1;
            } else self.feedNumeric(b),
        }
    }

    pub fn matches(self: StreamCell) bool {
        return switch (self.ctx.kind) {
            .text => self.text_found,
            .predicate => switch (self.ctx.op) {
                .eq => self.equal and self.len == self.ctx.value.len,
                .ne => !(self.equal and self.len == self.ctx.value.len),
                .lt, .gt, .le, .ge => self.numericMatches(),
            },
        };
    }

    fn numericMatches(self: StreamCell) bool {
        const valid = self.num_saw_digit and self.num_phase != .invalid and self.num_phase != .leading and self.num_phase != .exp_start and
            (self.num_phase != .exponent or self.num_exp_digits > 0);
        if (!valid) return false;
        const q = self.ctx.value_dec;
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

pub fn streamSupported(ctx: MatchCtx) bool {
    _ = ctx;
    return true;
}

/// ASCII-case-aware byte equality for the predicate EQ/NE match: byte-exact when
/// `!fold`; when `fold` (case-insensitive), ASCII letters compare case-folded
/// while every byte >= 0x80 stays exact (asciiLower is identity outside 'A'..'Z').
fn bytesEqual(a: []const u8, b: []const u8, fold: bool) bool {
    if (a.len != b.len) return false;
    if (!fold) return std.mem.eql(u8, a, b);
    for (a, b) |x, y| if (asciiLower(x) != asciiLower(y)) return false;
    return true;
}

/// Substring match: fold ASCII case iff `fold` (case-insensitive), else
/// byte-exact. Bytes >= 0x80 (all non-ASCII) always compare exactly.
fn textMatch(cell: []const u8, query: []const u8, fold: bool) bool {
    if (query.len == 0) return true;
    if (query.len > cell.len) return false;
    const last = cell.len - query.len;
    var start: usize = 0;
    while (start <= last) : (start += 1) {
        var k: usize = 0;
        while (k < query.len) : (k += 1) {
            const a = cell[start + k];
            const b = query[k];
            const eq = if (fold) asciiLower(a) == asciiLower(b) else a == b;
            if (!eq) break;
        }
        if (k == query.len) return true;
    }
    return false;
}

/// Per-cell match verdict: does column `col`'s decoded cell bytes satisfy the
/// active request `ctx`? This is the single per-column decision `matchRecord`
/// (below) is composed from, exposed so `window.matchFlags`
/// (ls_window_match_flags, thin-frontend-shared-core Phase 1) reports the EXACT
/// same verdict per visible cell — no re-derived grammar, no second matcher.
///   * TEXT: 1 iff `col` is IN SCOPE (empty scope_mask == all columns) AND the
///     smart-case substring rule holds; an out-of-scope column is always 0.
///   * PREDICATE: 1 only on the target `ctx.column` (every other column 0), and
///     there iff the operator holds — EQ/NE ASCII-folded per `ctx.fold`
///     (byte-exact when case-sensitive), LT/GT/LE/GE the
///     exact-decimal comparison (a non-numeric cell never matches an ordering
///     op; the empty value is legal).
/// Allocation-free; pure over the passed bytes.
pub fn cellMatches(ctx: MatchCtx, col: u32, cell: []const u8) bool {
    switch (ctx.kind) {
        .text => {
            if (ctx.scope_mask.len != 0 and (col >= ctx.scope_mask.len or !ctx.scope_mask[col])) return false;
            return textMatch(cell, ctx.value, ctx.fold);
        },
        .predicate => {
            if (col != ctx.column) return false;
            return switch (ctx.op) {
                .eq => bytesEqual(cell, ctx.value, ctx.fold),
                .ne => !bytesEqual(cell, ctx.value, ctx.fold),
                .lt, .gt, .le, .ge => blk: {
                    const cd = parseDecimal(cell);
                    if (!cd.valid) break :blk false; // non-numeric cell never matches ordering
                    const ord = compareDecimal(cd, ctx.value_dec);
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
