//! Dialect sniffing (O(head sample); pinned candidates + tie-breaks). See
//! api/lesssheet.h DIALECT SNIFFING for the pinned candidate/tie-break rules.

const api = @import("api");
const lexer = @import("lexer.zig");

/// The sample is bounded by BOTH caps, so sniffing costs the same regardless
/// of file size.
const sniff_byte_cap: usize = 256 * 1024;
const sniff_record_cap: u32 = 256;
const max_field_hist: usize = 512;

/// Sniffer scoring for one (separator, quote) candidate pair.
const Score = struct {
    /// The quote byte actually opens >= 1 field in the sample. A quote that
    /// never appears must not beat the default just because ignoring the real
    /// quotes happens to make ragged field counts look more consistent.
    active: bool,
    /// The pair splits records into >1 field (beats single-field candidates).
    splits: bool,
    /// Fraction of sampled records matching the modal field count.
    consistency: f64,
    mode: u32,
};

fn betterThan(a: Score, b: Score) bool {
    if (a.active != b.active) return a.active;
    if (a.splits != b.splits) return a.splits;
    if (a.consistency != b.consistency) return a.consistency > b.consistency;
    return a.mode > b.mode;
}

pub const Resolved = struct { sep: u8, quote: ?u8 };

/// Resolve the effective separator/quote: forced parameters are fixed, the
/// rest are sniffed over the head sample. The sniffer never selects NONE and
/// never selects a value equal to a forced parameter. `content` is the
/// document's (already BOM-stripped) SOURCE bytes; sniffing decodes it
/// through `decodeUnit(encoding)`, so the ASCII-structural candidate bytes
/// (`, ; \t | " '`) are found correctly regardless of source encoding.
pub fn sniffDialect(content: []const u8, opt: api.OpenOptions, encoding: u8) Resolved {
    const sep_forced = opt.separator != api.sniff;
    const quote_none_forced = opt.quote == api.quote_none;
    const quote_byte_forced = opt.quote >= 0;
    const fsep: u8 = if (sep_forced) @intCast(opt.separator) else 0;
    const fqb: u8 = if (quote_byte_forced) @intCast(opt.quote) else 0;

    var seps: [4]u8 = undefined;
    var sn: usize = 0;
    if (sep_forced) {
        seps[0] = fsep;
        sn = 1;
    } else for (api.separator_candidates) |cch| {
        if (!(quote_byte_forced and cch == fqb)) {
            seps[sn] = cch;
            sn += 1;
        }
    }

    var quotes: [2]?u8 = undefined;
    var qn: usize = 0;
    if (quote_none_forced) {
        quotes[0] = null;
        qn = 1;
    } else if (quote_byte_forced) {
        quotes[0] = fqb;
        qn = 1;
    } else for (api.quote_candidates) |qch| {
        if (!(sep_forced and qch == fsep)) {
            quotes[qn] = qch;
            qn += 1;
        }
    }

    var best_sep: u8 = if (sn > 0) seps[0] else api.default_separator;
    var best_quote: ?u8 = if (qn > 0) quotes[0] else api.default_quote;
    if (sn * qn <= 1) return .{ .sep = best_sep, .quote = best_quote };

    var best: ?Score = null;
    for (seps[0..sn]) |s| {
        for (quotes[0..qn]) |q| {
            const sc = scorePair(content, s, q, encoding);
            if (best == null or betterThan(sc, best.?)) {
                best = sc;
                best_sep = s;
                best_quote = q;
            }
        }
    }
    return .{ .sep = best_sep, .quote = best_quote };
}

fn scorePair(content: []const u8, sep: u8, quote: ?u8, encoding: u8) Score {
    var hist = [_]u32{0} ** (max_field_hist + 1);
    var total: u32 = 0;
    var records: u32 = 0;
    var active = false;
    var i: usize = 0;
    const limit = @min(content.len, sniff_byte_cap);
    while (i < limit and records < sniff_record_cap) {
        const r = lexer.countFields(content, i, sep, quote, limit, encoding);
        hist[@min(@as(usize, r.count), max_field_hist)] += 1;
        if (r.quoted) active = true;
        total += 1;
        records += 1;
        if (r.next <= i) break;
        i = r.next;
        if (i >= content.len) break;
    }
    // Modal field count, ties broken toward the LARGER count: a candidate that
    // splits any records into multiple fields must read as "splitting" even
    // when as many records are ragged/short — splitting beats single-field.
    var mode: u32 = 0;
    var mode_freq: u32 = 0;
    for (hist, 0..) |f, k| {
        if (f > 0 and f >= mode_freq) {
            mode_freq = f;
            mode = @intCast(k);
        }
    }
    return .{
        .active = active,
        .splits = mode >= 2,
        .consistency = if (total > 0) @as(f64, @floatFromInt(mode_freq)) / @as(f64, @floatFromInt(total)) else 0,
        .mode = mode,
    };
}
