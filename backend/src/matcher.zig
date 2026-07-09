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

/// True iff the query has NO ASCII uppercase byte (then smart-case folds ASCII).
pub fn queryFolds(q: []const u8) bool {
    for (q) |b| if (b >= 'A' and b <= 'Z') return false;
    return true;
}

/// Substring match with smart case: fold ASCII case iff `fold`, else byte-exact.
/// Bytes >= 0x80 (all non-ASCII) always compare exactly.
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

/// Evaluate the matcher on a decoded record. Returns the matched column (lowest
/// in-scope for TEXT; the predicate column for PREDICATE) or null. `refs` has
/// exactly `column_count` entries (truncate/pad already applied, == ls_cell).
pub fn matchRecord(ctx: MatchCtx, buf: []const u8, refs: []const CellRef) ?u32 {
    switch (ctx.kind) {
        .text => {
            var col: u32 = 0;
            while (col < ctx.column_count) : (col += 1) {
                if (col >= refs.len) break;
                if (ctx.scope_mask.len != 0 and !ctx.scope_mask[col]) continue;
                const ref = refs[col];
                if (textMatch(buf[ref.start .. ref.start + ref.len], ctx.value, ctx.fold)) return col;
            }
            return null;
        },
        .predicate => {
            if (ctx.column >= refs.len) return null;
            const ref = refs[ctx.column];
            const cell = buf[ref.start .. ref.start + ref.len];
            const matched = switch (ctx.op) {
                .eq => std.mem.eql(u8, cell, ctx.value),
                .ne => !std.mem.eql(u8, cell, ctx.value),
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
            return if (matched) ctx.column else null;
        },
    }
}
