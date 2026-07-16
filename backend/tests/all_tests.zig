//! Frozen behavior tests — viewer-ui + find-seek slices (planner-owned).
//! Every core acceptance criterion of ARCH-viewer-ui (1–8) maps to at least
//! one test below, and the walking-skeleton dialect/error coverage is carried
//! over onto the windowed surface. Tests exercise the PUBLIC C ABI through
//! the contract module (`@import("api")`) only — never internal Zig APIs.
//!
//! Determinism: most tests open with LS_INDEX_MANUAL (no background indexer)
//! and advance the frontier via the public jump machinery; files no larger
//! than LS_OPEN_HEAD_MAX_BYTES are fully indexed by open itself (pinned), so
//! their row counts are exact immediately. AUTO mode is exercised where its
//! observable behavior (progress monotonicity, completion) is the subject.
const std = @import("std");
const api = @import("api");

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

const manual: api.OpenOptions = .{ .index_mode = api.index_manual };

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

/// Write `bytes` to a fresh temp file with `mode` permissions; returns the
/// absolute, NUL-terminated path expected by ls_open.
fn makeFixture(bytes: []const u8, mode: u9) !Fixture {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "fixture.csv",
        .data = bytes,
        .flags = .{ .permissions = .fromMode(mode) },
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ buf[0..n], "fixture.csv" });
    return .{ .tmp = tmp, .path = path };
}

/// Write `head` then extend the file sparsely to `total_len` bytes (the tail
/// reads as zeros; only the head occupies disk). For O(head) open probes.
fn makeSparseFixture(head: []const u8, total_len: u64) !Fixture {
    const io = std.testing.io;
    var fx = try makeFixture(head, 0o644);
    errdefer fx.deinit();
    const f = try fx.tmp.dir.openFile(io, "fixture.csv", .{ .mode = .write_only });
    defer f.close(io);
    try f.setLength(io, total_len);
    return fx;
}

const OpenedDoc = struct {
    fx: Fixture,
    doc: *api.Doc,

    fn deinit(self: *OpenedDoc) void {
        api.ls_close(self.doc);
        self.fx.deinit();
    }
};

/// Open `bytes` as a document with explicit options; fails the test on error.
fn openWith(bytes: []const u8, options: api.OpenOptions) !OpenedDoc {
    var fx = try makeFixture(bytes, 0o644);
    errdefer fx.deinit();
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &options, &doc));
    try std.testing.expect(doc != null);
    return .{ .fx = fx, .doc = doc.? };
}

/// Deterministic default for tests: sniff everything, MANUAL index mode.
fn openBytes(bytes: []const u8) !OpenedDoc {
    return openWith(bytes, manual);
}

fn expectCell(doc: *const api.Doc, row: u64, col: u32, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, api.ls_cell(doc, row, col).slice());
}

fn expectHeaderCell(doc: *const api.Doc, col: u32, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, api.ls_header_cell(doc, col).slice());
}

/// Tiny-fixture (≤ head budget) dimensions: exact row count + column count.
fn expectDims(doc: *const api.Doc, data_rows: u64, cols: u32) !void {
    const rc = api.ls_row_count_get(doc);
    try std.testing.expectEqual(data_rows, rc.count);
    try std.testing.expectEqual(true, rc.exact);
    try std.testing.expectEqual(cols, api.ls_column_count(doc));
}

/// Materialize the head window (tiny fixtures) so cells are servable.
fn winAll(doc: *api.Doc) void {
    _ = api.ls_window_set(doc, 0, api.window_max_rows);
}

fn elapsedMs(t0: std.Io.Clock.Timestamp) i64 {
    return t0.durationTo(.now(std.testing.io, .awake)).raw.toMilliseconds();
}

/// Poll the jump slot until DONE (≤ 60 s); returns the final status.
fn waitJumpDone(doc: *api.Doc) !api.JumpStatus {
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        const s = api.ls_jump_poll(doc);
        if (s.state == .done) return s;
        if (elapsedMs(t0) > 15_000) return error.JumpTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Advance the frontier to EOF through the public jump machinery.
fn scanToEnd(doc: *api.Doc) !void {
    api.ls_jump_start(doc, std.math.maxInt(u64));
    _ = try waitJumpDone(doc);
}

/// n fixed-width 18-byte records: "{i:0>8},{2i:0>8}\n" (record i starts at
/// byte 18*i; deterministic cell text for any row).
fn genFixedRows(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var line: [32]u8 = undefined;
    for (0..n) |i| {
        const s = try std.fmt.bufPrint(&line, "{d:0>8},{d:0>8}\n", .{ i, 2 * i });
        try buf.appendSlice(gpa, s);
    }
    return buf.toOwnedSlice(gpa);
}

fn fixedCell(buf: *[8]u8, v: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>8}", .{v}) catch unreachable;
}

test "toolchain baseline" {
    try std.testing.expect(true);
}

// ---------------------------------------------------------------------------
// Criterion 1 — forced dialect: every candidate separator, custom bytes,
// every quote incl. NONE, header on/off; invalid combinations are a distinct
// usage error; a never-occurring separator renders one column.
// ---------------------------------------------------------------------------

test "c1: each candidate separator forced parses the fixture" {
    for (api.separator_candidates) |sep| {
        var bytes: [12]u8 = undefined;
        const fixture = try std.fmt.bufPrint(&bytes, "a{c}b\n1{c}2\n", .{ sep, sep });
        var od = try openWith(fixture, .{ .separator = sep, .index_mode = api.index_manual });
        defer od.deinit();
        const d = api.ls_dialect_get(od.doc);
        try std.testing.expectEqual(sep, d.separator);
        try std.testing.expectEqual(true, d.separator_forced);
        try std.testing.expectEqual(false, d.quote_forced);
        try std.testing.expectEqual(true, d.header); // "a","b" not numeric
        try expectDims(od.doc, 1, 2);
        winAll(od.doc);
        try expectHeaderCell(od.doc, 0, "a");
        try expectHeaderCell(od.doc, 1, "b");
        try expectCell(od.doc, 0, 0, "1");
        try expectCell(od.doc, 0, 1, "2");
    }
}

test "c1: custom separator bytes are honored exactly" {
    var od = try openWith("a:b\n1:2\n", .{ .separator = ':', .index_mode = api.index_manual });
    defer od.deinit();
    try std.testing.expectEqual(@as(u8, ':'), api.ls_dialect_get(od.doc).separator);
    try expectDims(od.doc, 1, 2);
    winAll(od.doc);
    try expectCell(od.doc, 0, 1, "2");

    // space is a legal custom separator (any ASCII byte except CR/LF/quote)
    var od2 = try openWith("a b\n1 2\n", .{ .separator = ' ', .index_mode = api.index_manual });
    defer od2.deinit();
    try expectDims(od2.doc, 1, 2);
    winAll(od2.doc);
    try expectCell(od2.doc, 0, 0, "1");
}

test "c1: forced single-quote and custom quote bytes drive the quoting grammar" {
    var od = try openWith("'x,y',q\n'a''b',w\n", .{
        .separator = ',',
        .quote = '\'',
        .index_mode = api.index_manual,
    });
    defer od.deinit();
    const d = api.ls_dialect_get(od.doc);
    try std.testing.expectEqual(@as(u8, '\''), d.quote);
    try std.testing.expectEqual(true, d.has_quote);
    try std.testing.expectEqual(true, d.quote_forced);
    try expectDims(od.doc, 1, 2);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "x,y"); // embedded separator protected
    try expectCell(od.doc, 0, 0, "a'b"); // doubled custom quote is a literal

    var od2 = try openWith("`a#b`#c\n", .{
        .separator = '#',
        .quote = '`',
        .index_mode = api.index_manual,
    });
    defer od2.deinit();
    try expectDims(od2.doc, 0, 2); // single record; suggested header
    winAll(od2.doc);
    try expectHeaderCell(od2.doc, 0, "a#b");
    try expectHeaderCell(od2.doc, 1, "c");
}

test "c1: quote NONE makes quote bytes literal text" {
    var od = try openWith("\"a\",b\nc,d\n", .{ .quote = api.quote_none, .index_mode = api.index_manual });
    defer od.deinit();
    const d = api.ls_dialect_get(od.doc);
    try std.testing.expectEqual(false, d.has_quote);
    try std.testing.expectEqual(true, d.quote_forced);
    try expectDims(od.doc, 1, 2);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "\"a\""); // quotes are literal
    try expectCell(od.doc, 0, 0, "c");
}

test "c1: quote NONE stops protecting embedded newlines" {
    // With quoting disabled, the '\n' inside the would-be quoted field ends
    // record 1: the document is single-column ("\"x" is record 1's one field).
    var od = try openWith("\"x\ny\",z\n", .{ .quote = api.quote_none, .index_mode = api.index_manual });
    defer od.deinit();
    try expectDims(od.doc, 1, 1);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "\"x");
    try expectCell(od.doc, 0, 0, "y\""); // truncated to the column count
}

test "c1: header forced ON overrides the all-numeric suggestion" {
    var od = try openWith("1,2\n3,4\n", .{ .header = api.header_on, .index_mode = api.index_manual });
    defer od.deinit();
    const d = api.ls_dialect_get(od.doc);
    try std.testing.expectEqual(true, d.header);
    try std.testing.expectEqual(true, d.header_forced);
    try expectDims(od.doc, 1, 2);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "1");
    try expectCell(od.doc, 0, 0, "3");
}

test "c1: header forced OFF demotes a texty record 1 to data row 0" {
    var od = try openWith("a,b\n1,2\n", .{ .header = api.header_off, .index_mode = api.index_manual });
    defer od.deinit();
    const d = api.ls_dialect_get(od.doc);
    try std.testing.expectEqual(false, d.header);
    try std.testing.expectEqual(true, d.header_forced);
    try expectDims(od.doc, 2, 2);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, ""); // no effective header
    try expectCell(od.doc, 0, 0, "a");
    try expectCell(od.doc, 1, 1, "2");
}

test "c1: a separator that never occurs renders a single column (not an error)" {
    var od = try openWith("a,b\nc,d\n", .{ .separator = '|', .index_mode = api.index_manual });
    defer od.deinit();
    try std.testing.expectEqual(@as(u32, 1), api.ls_column_count(od.doc));
    try expectDims(od.doc, 1, 1); // "a,b" suggested header
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "a,b");
    try expectCell(od.doc, 0, 0, "c,d");
}

test "c1: out-of-domain options are a distinct usage error" {
    var fx = try makeFixture("a,b\n", 0o644);
    defer fx.deinit();
    const bad = [_]api.OpenOptions{
        .{ .separator = '\n' },
        .{ .separator = '\r' },
        .{ .separator = 0 },
        .{ .separator = 0x80 },
        .{ .separator = -3 },
        .{ .quote = '\n' },
        .{ .quote = '\r' },
        .{ .quote = 0 },
        .{ .quote = 128 },
        .{ .quote = -4 },
        .{ .separator = ';', .quote = ';' }, // forced collision
        .{ .header = 2 },
        .{ .header = -2 },
        .{ .index_mode = 2 },
        .{ .index_mode = -1 },
    };
    for (bad) |opts| {
        var doc: ?*api.Doc = null;
        try std.testing.expectEqual(api.Status.invalid_argument, api.ls_open(fx.path.ptr, &opts, &doc));
        try std.testing.expectEqual(@as(?*api.Doc, null), doc);
    }
    // ...and the same file still opens with valid options.
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &manual, &doc));
    api.ls_close(doc.?);
}

test "c1: NULL options mean all-sniff + AUTO index" {
    var fx = try makeFixture("a,b\n1,2\n", 0o644);
    defer fx.deinit();
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, null, &doc));
    defer api.ls_close(doc.?);
    const d = api.ls_dialect_get(doc.?);
    try std.testing.expectEqual(api.default_separator, d.separator);
    try std.testing.expectEqual(api.default_quote, d.quote);
    try std.testing.expectEqual(true, d.has_quote);
    try std.testing.expectEqual(false, d.separator_forced);
    try std.testing.expectEqual(false, d.quote_forced);
    try std.testing.expectEqual(false, d.header_forced);
}

// ---------------------------------------------------------------------------
// Criterion 2 — sniffer: right dialect for every candidate pair (with quoted
// fields containing the other candidates), pinned tie-breaks, and the
// O(head-sample) read bound.
// ---------------------------------------------------------------------------

/// A fixture only (sep, quote) parses with consistent field counts: a plain
/// 3-field header plus 4 data records whose every field is quoted and embeds
/// all OTHER separator candidates, the other quote candidate, and a per-record
/// varying number of real separators.
fn buildSniffFixture(gpa: std.mem.Allocator, sep: u8, quote: u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "h1");
    try buf.append(gpa, sep);
    try buf.appendSlice(gpa, "h2");
    try buf.append(gpa, sep);
    try buf.appendSlice(gpa, "h3\n");
    for (0..4) |r| {
        for (0..3) |c| {
            if (c != 0) try buf.append(gpa, sep);
            try buf.append(gpa, quote);
            for (api.separator_candidates) |cand| {
                if (cand != sep) try buf.append(gpa, cand);
            }
            for (api.quote_candidates) |qc| {
                if (qc != quote) try buf.append(gpa, qc);
            }
            for (0..r + 1) |_| try buf.append(gpa, sep);
            try buf.append(gpa, 'x');
            try buf.append(gpa, quote);
        }
        try buf.append(gpa, '\n');
    }
    return buf.toOwnedSlice(gpa);
}

test "c2: the sniffer picks every candidate pair despite quoted traps" {
    const gpa = std.testing.allocator;
    for (api.separator_candidates) |sep| {
        for (api.quote_candidates) |quote| {
            const fixture = try buildSniffFixture(gpa, sep, quote);
            defer gpa.free(fixture);
            errdefer std.debug.print("pair: sep=0x{x} quote=0x{x}\n", .{ sep, quote });
            var od = try openBytes(fixture);
            defer od.deinit();
            const d = api.ls_dialect_get(od.doc);
            try std.testing.expectEqual(sep, d.separator);
            try std.testing.expectEqual(quote, d.quote);
            try std.testing.expectEqual(true, d.has_quote);
            try std.testing.expectEqual(false, d.separator_forced);
            try std.testing.expectEqual(false, d.quote_forced);
            try std.testing.expectEqual(true, d.header);
            try expectDims(od.doc, 4, 3);
            // Cell round-trip: quotes stripped, embedded candidates intact.
            var expected: std.ArrayList(u8) = .empty;
            defer expected.deinit(gpa);
            for (api.separator_candidates) |cand| {
                if (cand != sep) try expected.append(gpa, cand);
            }
            for (api.quote_candidates) |qc| {
                if (qc != quote) try expected.append(gpa, qc);
            }
            try expected.append(gpa, sep);
            try expected.append(gpa, 'x');
            winAll(od.doc);
            try expectCell(od.doc, 0, 0, expected.items);
        }
    }
}

test "c2: no structure sniffs as the comma/double-quote default, one column" {
    var od = try openBytes("a\nb\nc\n");
    defer od.deinit();
    const d = api.ls_dialect_get(od.doc);
    try std.testing.expectEqual(api.default_separator, d.separator);
    try std.testing.expectEqual(api.default_quote, d.quote);
    try std.testing.expectEqual(true, d.has_quote);
    try expectDims(od.doc, 2, 1);
}

test "c2: an exact consistency tie breaks toward comma" {
    // Both ',' and ';' split every record into exactly 2 consistent fields.
    var od = try openBytes("a,b;c\nd,e;f\n");
    defer od.deinit();
    try std.testing.expectEqual(api.default_separator, api.ls_dialect_get(od.doc).separator);
}

test "c2: a candidate that splits consistently beats single-field candidates" {
    // All-numeric record 1 keeps the header OFF, so the dims assertion reads
    // purely as "the winning candidate split the document into a 2x2 DATA
    // grid". (DECISION-1: the original fixture "x;y\nz;w\n" tripped the header
    // rule, which excludes record 1 from row counts -- expectDims(2, 2) was
    // unsatisfiable together with the api/lesssheet.h header grammar.)
    var od = try openBytes("1;2\n3;4\n");
    defer od.deinit();
    try std.testing.expectEqual(@as(u8, ';'), api.ls_dialect_get(od.doc).separator);
    try expectDims(od.doc, 2, 2);
}

test "c2: a forced quote is excluded from separator sniffing (and vice versa)" {
    // Forcing quote=',' removes ',' from the separator candidates: the comma
    // fixture must sniff ';' (the best remaining candidate).
    var od = try openWith("a;b\nc;d\n", .{ .quote = ',', .index_mode = api.index_manual });
    defer od.deinit();
    const d = api.ls_dialect_get(od.doc);
    try std.testing.expectEqual(@as(u8, ';'), d.separator);
    try std.testing.expectEqual(@as(u8, ','), d.quote);
    // Forcing separator '"' removes '"' from the quote candidates.
    var od2 = try openWith("a\"b\n'c'\"d\n", .{ .separator = '"', .index_mode = api.index_manual });
    defer od2.deinit();
    const d2 = api.ls_dialect_get(od2.doc);
    try std.testing.expectEqual(@as(u8, '"'), d2.separator);
    try std.testing.expect(!d2.has_quote or d2.quote != '"');
}

test "c2: sniffing + open read only the head (bytes-scanned probe)" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 300_000); // 5.4 MB > head budget
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    const d = api.ls_dialect_get(od.doc);
    try std.testing.expectEqual(api.default_separator, d.separator);
    try std.testing.expectEqual(false, d.header); // all-numeric record 1
    const p = api.ls_index_poll(od.doc);
    try std.testing.expectEqual(@as(u64, 300_000 * 18), p.bytes_total);
    try std.testing.expect(p.bytes_scanned <= api.open_head_max_bytes);
    try std.testing.expect(p.bytes_scanned < p.bytes_total);
    try std.testing.expectEqual(false, p.complete);
}

// ---------------------------------------------------------------------------
// Criterion 3 — header suggestion: the pinned numeric grammar, under every
// sniffed/forced dialect.
// ---------------------------------------------------------------------------

fn expectHeaderUnder(options: api.OpenOptions, bytes: []const u8, expected: bool) !void {
    errdefer std.debug.print("fixture: {f}\n", .{std.zig.fmtString(bytes)});
    var od = try openWith(bytes, options);
    defer od.deinit();
    try std.testing.expectEqual(expected, api.ls_dialect_get(od.doc).header);
}

fn expectSuggested(bytes: []const u8, expected: bool) !void {
    // Forced comma dialect: the grammar is the subject, not sniffing.
    try expectHeaderUnder(.{ .separator = ',', .index_mode = api.index_manual }, bytes, expected);
}

test "c3: header suggestion on the ARCH cases" {
    try expectSuggested("name,age\n1,2\n", true);
    try expectSuggested("1,2.5\n3,4\n", false);
    try expectSuggested("1,,3\n", true); // empty cell is NOT numeric
    try expectSuggested("+1e5,-2\n", false);
}

test "c3: pinned numeric grammar — accepted forms (row 1 all numeric)" {
    try expectSuggested("1e5,2\n", false); // exponent without fraction
    try expectSuggested(" 12 ,3\n", false); // ASCII whitespace trimmed
    try expectSuggested("\t7\t,8\n", false); // tabs trimmed
    try expectSuggested(".5,5.\n", false); // leading/trailing dot forms
    try expectSuggested("-0.0,+42\n", false); // signs
    try expectSuggested("1.5e-3,2E+4\n", false); // signed exponents, e or E
}

test "c3: pinned numeric grammar — rejected forms (suggest header)" {
    try expectSuggested("0x1F,2\n", true); // no hex
    try expectSuggested("\"1,000\",2\n", true); // no thousands separators
    try expectSuggested("1e,2\n", true); // dangling exponent
    try expectSuggested("e5,2\n", true); // no digits before exponent
    try expectSuggested("--1,2\n", true); // double sign
    try expectSuggested("1.2.3,4\n", true); // two dots
    try expectSuggested("NaN,1\n", true); // no nan
    try expectSuggested("inf,1\n", true); // no inf
    try expectSuggested("1 2,3\n", true); // inner whitespace survives trim
    try expectSuggested("١٢,3\n", true); // ASCII digits only
}

test "c3: the grammar applies under non-comma dialects" {
    try expectHeaderUnder(.{ .separator = ';', .index_mode = api.index_manual }, "1;2\n3;4\n", false);
    try expectHeaderUnder(.{ .separator = ';', .index_mode = api.index_manual }, "a;2\n3;4\n", true);
    try expectHeaderUnder(.{ .separator = '\t', .index_mode = api.index_manual }, "7\t8\n", false);
}

test "c3: quote NONE changes cell text and therefore numericness" {
    // Under '"' quoting, record 1 is ["1","2"] — numeric, no header.
    try expectHeaderUnder(.{ .quote = '"', .index_mode = api.index_manual }, "\"1\",\"2\"\n3,4\n", false);
    // With quoting disabled the cells keep their quotes — not numeric.
    try expectHeaderUnder(.{ .quote = api.quote_none, .index_mode = api.index_manual }, "\"1\",\"2\"\n3,4\n", true);
}

test "c3: an empty-line record is a single empty, non-numeric cell" {
    var od = try openBytes("\n");
    defer od.deinit();
    try std.testing.expectEqual(true, api.ls_dialect_get(od.doc).header);
    try expectDims(od.doc, 0, 1);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "");
}

test "c3: a header-only document has zero data rows, exact immediately" {
    var od = try openBytes("\"a\"\"b\",1\n");
    defer od.deinit();
    try std.testing.expectEqual(true, api.ls_dialect_get(od.doc).header);
    try expectDims(od.doc, 0, 2);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "a\"b");
    try expectHeaderCell(od.doc, 1, "1");
    try expectCell(od.doc, 0, 0, ""); // no data row 0
}

// ---------------------------------------------------------------------------
// Criterion 4 — windowed access: exact cells behind the frontier, zero
// allocation on the access path, eviction + byte-identical re-serve, 64-bit
// row addressing, LS_WINDOW_MAX_ROWS clamp, window_set never scans.
// ---------------------------------------------------------------------------

test "c4: any window behind the frontier serves exact cell text" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 10_000);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);
    try expectDims(od.doc, 10_000, 2);

    const r = api.ls_window_set(od.doc, 4_000, 100);
    try std.testing.expectEqual(@as(u64, 4_000), r.first_row);
    try std.testing.expectEqual(@as(u64, 100), r.row_count);
    var buf: [8]u8 = undefined;
    try expectCell(od.doc, 4_000, 0, fixedCell(&buf, 4_000));
    try expectCell(od.doc, 4_000, 1, fixedCell(&buf, 8_000));
    try expectCell(od.doc, 4_099, 0, fixedCell(&buf, 4_099));
    try expectCell(od.doc, 4_099, 1, fixedCell(&buf, 8_198));
    try expectCell(od.doc, 4_000, 2, ""); // out-of-range column
}

test "c4: evicted rows re-serve byte-identical text; rows outside the window are not served" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 10_000);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);

    _ = api.ls_window_set(od.doc, 0, 64);
    const first = try gpa.dupe(u8, api.ls_cell(od.doc, 7, 0).slice());
    defer gpa.free(first);
    const second = try gpa.dupe(u8, api.ls_cell(od.doc, 7, 1).slice());
    defer gpa.free(second);
    try std.testing.expect(first.len > 0);

    // Move the window far away: row 7 is evicted (not served), row 9000 is.
    _ = api.ls_window_set(od.doc, 9_000, 64);
    var buf: [8]u8 = undefined;
    try expectCell(od.doc, 9_000, 0, fixedCell(&buf, 9_000));
    try expectCell(od.doc, 7, 0, "");

    // Move back: byte-identical re-serve.
    _ = api.ls_window_set(od.doc, 0, 64);
    try expectCell(od.doc, 7, 0, first);
    try expectCell(od.doc, 7, 1, second);
}

test "c4: row addressing is 64-bit clean (no u32 truncation aliasing)" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 10_000);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);
    _ = api.ls_window_set(od.doc, 0, 64);
    // If the implementation truncated rows to u32, this would alias row 2.
    try expectCell(od.doc, (1 << 32) + 2, 0, "");
    const r = api.ls_window_set(od.doc, (1 << 32) + 5, 10);
    try std.testing.expectEqual(@as(u64, (1 << 32) + 5), r.first_row);
    try std.testing.expectEqual(@as(u64, 0), r.row_count);
    // A clamped jump from a >2^32 target still lands on the true last row.
    api.ls_jump_start(od.doc, 1 << 40);
    const s = try waitJumpDone(od.doc);
    try std.testing.expectEqual(@as(u64, 9_999), s.landed_row);
}

test "c4: window row_count is clamped to LS_WINDOW_MAX_ROWS" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 10_000);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);
    const r = api.ls_window_set(od.doc, 0, 100_000);
    try std.testing.expectEqual(@as(u64, api.window_max_rows), r.row_count);
    // ...and the requested range is clamped to the document's end.
    const tail = api.ls_window_set(od.doc, 9_990, 100);
    try std.testing.expectEqual(@as(u64, 10), tail.row_count);
}

test "c4: window_set never advances the frontier (no hidden scans)" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 300_000); // 5.4 MB > head budget
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    const before = api.ls_index_poll(od.doc).bytes_scanned;
    // Row 260,000 starts at byte 4,680,000 > LS_OPEN_HEAD_MAX_BYTES: it is
    // beyond any legal open frontier in MANUAL mode.
    const r = api.ls_window_set(od.doc, 260_000, 10);
    try std.testing.expectEqual(@as(u64, 260_000), r.first_row);
    try std.testing.expectEqual(@as(u64, 0), r.row_count);
    try expectCell(od.doc, 260_000, 0, "");
    try std.testing.expectEqual(before, api.ls_index_poll(od.doc).bytes_scanned);
    // The head region is servable immediately (open's ready guarantee).
    const head = api.ls_window_set(od.doc, 0, api.open_ready_min_rows);
    try std.testing.expectEqual(@as(u64, api.open_ready_min_rows), head.row_count);
    var buf: [8]u8 = undefined;
    try expectCell(od.doc, 511, 0, fixedCell(&buf, 511));
    try std.testing.expectEqual(before, api.ls_index_poll(od.doc).bytes_scanned);
}

/// Counts every allocating call (alloc/resize/remap) while delegating to a
/// parent allocator; frees are delegated uncounted.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = self_of(ctx);
        self.count += 1;
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = self_of(ctx);
        self.count += 1;
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = self_of(ctx);
        self.count += 1;
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        return self_of(ctx).parent.vtable.free(self_of(ctx).parent.ptr, memory, alignment, ret_addr);
    }
    fn self_of(ctx: *anyopaque) *CountingAllocator {
        return @ptrCast(@alignCast(ctx));
    }
};

test "c4: zero allocation on the access and poll paths" {
    var counting: CountingAllocator = .{ .parent = std.testing.allocator };
    var fx = try makeFixture("a,b,c\n\"x,1\",2\n3\n4,5,6\n", 0o644);
    defer fx.deinit();
    var doc_opt: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.openWithAllocator(counting.allocator(), fx.path.ptr, &manual, &doc_opt));
    const doc = doc_opt.?;
    defer api.ls_close(doc);

    try scanToEnd(doc); // may allocate (scan state / checkpoints)
    _ = api.ls_window_set(doc, 0, 16); // may allocate (materialization)
    const allocs_after_setup = counting.count;

    try std.testing.expectEqual(@as(u32, 3), api.ls_column_count(doc));
    const rc = api.ls_row_count_get(doc);
    try std.testing.expectEqual(@as(u64, 3), rc.count);
    try std.testing.expectEqual(true, rc.exact);
    _ = api.ls_dialect_get(doc);
    _ = api.ls_index_poll(doc);
    _ = api.ls_jump_poll(doc);
    try expectHeaderCell(doc, 0, "a");
    try expectHeaderCell(doc, 2, "c");
    try expectCell(doc, 0, 0, "x,1");
    try expectCell(doc, 0, 1, "2");
    try expectCell(doc, 0, 2, ""); // ragged pad
    try expectCell(doc, 1, 0, "3");
    try expectCell(doc, 2, 2, "6");
    // Out-of-range accesses are also allocation-free total functions.
    try expectCell(doc, 99, 0, "");
    try expectCell(doc, 0, 99, "");
    try expectCell(doc, 1 << 40, 0, "");
    try expectHeaderCell(doc, 99, "");

    try std.testing.expectEqual(allocs_after_setup, counting.count);
}

// ---------------------------------------------------------------------------
// Criterion 5 — index correctness: quoted embedded newlines, CRLF/LF/CR
// mixes; every checkpoint maps to a true record boundary (proven by exact
// re-serves across evictions); the completed count equals the true count.
// ---------------------------------------------------------------------------

/// 600 records with deterministic content: first cell "r{i:0>4}"; second cell
/// cycles quoted-embedded-LF, quoted-embedded-CRLF, quoted-doubled-quote, and
/// plain; record terminators alternate LF / CRLF, with a lone CR every 97th.
fn genGnarlyRows(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var tmp: [16]u8 = undefined;
    for (0..n) |i| {
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "r{d:0>4},", .{i}));
        switch (i % 4) {
            0 => try buf.appendSlice(gpa, "\"e\nb\""),
            1 => try buf.appendSlice(gpa, "\"e\r\nb\""),
            2 => try buf.appendSlice(gpa, "\"q\"\"x\""),
            else => try buf.appendSlice(gpa, "p"),
        }
        if (i % 97 == 96) {
            try buf.append(gpa, '\r'); // lone CR terminator
        } else if (i % 2 == 0) {
            try buf.appendSlice(gpa, "\n");
        } else {
            try buf.appendSlice(gpa, "\r\n");
        }
    }
    return buf.toOwnedSlice(gpa);
}

fn gnarlySecondCell(i: usize) []const u8 {
    return switch (i % 4) {
        0 => "e\nb",
        1 => "e\r\nb",
        2 => "q\"x",
        else => "p",
    };
}

test "c5: checkpoints are true record boundaries under quoted newlines and CRLF/CR mixes" {
    const gpa = std.testing.allocator;
    const body = try genGnarlyRows(gpa, 600);
    defer gpa.free(body);
    const fixture = try std.mem.concat(gpa, u8, &.{ "ca,cb\n", body });
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);
    try expectDims(od.doc, 600, 2);
    try std.testing.expectEqual(true, api.ls_index_poll(od.doc).complete);

    // Sweep the whole document in small windows: every re-materialization
    // re-lexes from a checkpoint; any checkpoint inside a quoted region
    // would corrupt the served cells.
    var buf: [16]u8 = undefined;
    var start: u64 = 0;
    while (start < 600) : (start += 64) {
        const r = api.ls_window_set(od.doc, start, 64);
        try std.testing.expectEqual(start, r.first_row);
        try std.testing.expectEqual(@min(@as(u64, 64), 600 - start), r.row_count);
        var row = start;
        while (row < start + r.row_count) : (row += 1) {
            errdefer std.debug.print("row: {d}\n", .{row});
            const expected_first = try std.fmt.bufPrint(&buf, "r{d:0>4}", .{row});
            try expectCell(od.doc, row, 0, expected_first);
            try expectCell(od.doc, row, 1, gnarlySecondCell(row));
        }
    }
}

test "c5: quoted embedded newline in a tiny document (carried over)" {
    var od = try openBytes("\"x,y\",q\n\"line1\nline2\",w\n");
    defer od.deinit();
    try std.testing.expectEqual(true, api.ls_dialect_get(od.doc).header);
    try expectDims(od.doc, 1, 2);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "x,y");
    try expectHeaderCell(od.doc, 1, "q");
    try expectCell(od.doc, 0, 0, "line1\nline2");
    try expectCell(od.doc, 0, 1, "w");
}

test "c5: CRLF and LF produce identical grids; trailing terminator adds nothing" {
    const variants = [_][]const u8{
        "1,2\r\n3,4\r\n",
        "1,2\r\n3,4",
        "1,2\n3,4\n",
        "1,2\n3,4",
        "1,2\r3,4\r", // lone CR terminators
    };
    for (variants) |bytes| {
        errdefer std.debug.print("variant: {f}\n", .{std.zig.fmtString(bytes)});
        var od = try openBytes(bytes);
        defer od.deinit();
        try std.testing.expectEqual(false, api.ls_dialect_get(od.doc).header);
        try expectDims(od.doc, 2, 2);
        winAll(od.doc);
        try expectCell(od.doc, 0, 0, "1");
        try expectCell(od.doc, 0, 1, "2");
        try expectCell(od.doc, 1, 0, "3");
        try expectCell(od.doc, 1, 1, "4");
    }
}

// ---------------------------------------------------------------------------
// Criterion 6 — progress monotonicity; the row-count estimate is available
// from open and marked estimated until final.
// ---------------------------------------------------------------------------

test "c6: the row-count estimate exists at open and is marked estimated" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 300_000); // fixed 18-byte rows
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    const rc = api.ls_row_count_get(od.doc);
    try std.testing.expectEqual(false, rc.exact);
    // Estimate = file bytes / mean indexed row bytes; rows are exactly 18
    // bytes, so any honest estimator lands near 300,000.
    try std.testing.expect(rc.count > 200_000 and rc.count < 400_000);
    // ...and it becomes exact and true at completion.
    try scanToEnd(od.doc);
    try expectDims(od.doc, 300_000, 2);
}

test "c6: AUTO-mode index progress is monotone to completion" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 300_000);
    defer gpa.free(fixture);
    var od = try openWith(fixture, .{}); // all defaults: AUTO index
    defer od.deinit();
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    var last: u64 = 0;
    var samples: usize = 0;
    while (true) {
        const p = api.ls_index_poll(od.doc);
        try std.testing.expect(p.bytes_scanned >= last);
        try std.testing.expect(p.bytes_scanned <= p.bytes_total);
        try std.testing.expectEqual(@as(u64, 300_000 * 18), p.bytes_total);
        last = p.bytes_scanned;
        samples += 1;
        if (p.complete) break;
        if (elapsedMs(t0) > 15_000) return error.IndexTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(samples >= 1);
    try std.testing.expectEqual(@as(u64, 300_000 * 18), api.ls_index_poll(od.doc).bytes_scanned);
    try expectDims(od.doc, 300_000, 2);
}

test "c6: jump progress is monotone in [0,1] and exactly 1.0 when done" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 300_000);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    api.ls_jump_start(od.doc, 250_000);
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    var last: f64 = 0.0;
    while (true) {
        const s = api.ls_jump_poll(od.doc);
        try std.testing.expect(s.progress >= 0.0 and s.progress <= 1.0);
        try std.testing.expect(s.progress >= last);
        last = s.progress;
        if (s.state == .done) {
            try std.testing.expectEqual(@as(f64, 1.0), s.progress);
            try std.testing.expectEqual(@as(u64, 250_000), s.landed_row);
            break;
        }
        if (elapsedMs(t0) > 15_000) return error.JumpTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

// ---------------------------------------------------------------------------
// Criterion 7 — jump semantics: exact landing, EOF clamp, instant behind the
// frontier, cancellation keeps the frontier.
// ---------------------------------------------------------------------------

test "c7: a jump beyond the frontier lands exactly on the target" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 300_000);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    api.ls_jump_start(od.doc, 250_000); // byte 4.5 MB: beyond any open frontier
    const s = try waitJumpDone(od.doc);
    try std.testing.expectEqual(@as(u64, 250_000), s.landed_row);
    const r = api.ls_window_set(od.doc, 250_000, 3);
    try std.testing.expectEqual(@as(u64, 3), r.row_count);
    var buf: [8]u8 = undefined;
    try expectCell(od.doc, 250_000, 0, fixedCell(&buf, 250_000));
    try expectCell(od.doc, 250_002, 1, fixedCell(&buf, 500_004));

    // A jump behind the frontier completes before ls_jump_start returns.
    const bytes_before = api.ls_index_poll(od.doc).bytes_scanned;
    api.ls_jump_start(od.doc, 1_000);
    const s2 = api.ls_jump_poll(od.doc);
    try std.testing.expectEqual(api.JumpState.done, s2.state);
    try std.testing.expectEqual(@as(u64, 1_000), s2.landed_row);
    try std.testing.expectEqual(@as(f64, 1.0), s2.progress);
    try std.testing.expectEqual(bytes_before, api.ls_index_poll(od.doc).bytes_scanned);
}

test "c7: a jump past EOF clamps to the last row and makes the count exact" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 10_000);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    api.ls_jump_start(od.doc, 999_999_999);
    const s = try waitJumpDone(od.doc);
    try std.testing.expectEqual(@as(u64, 9_999), s.landed_row);
    try expectDims(od.doc, 10_000, 2);
    // With the count exact, an at/past-EOF target clamps synchronously.
    api.ls_jump_start(od.doc, 20_000);
    const s2 = api.ls_jump_poll(od.doc);
    try std.testing.expectEqual(api.JumpState.done, s2.state);
    try std.testing.expectEqual(@as(u64, 9_999), s2.landed_row);
}

test "c7: jump on an empty document completes immediately with landed_row 0" {
    var od = try openBytes("");
    defer od.deinit();
    api.ls_jump_start(od.doc, 5);
    const s = api.ls_jump_poll(od.doc);
    try std.testing.expectEqual(api.JumpState.done, s.state);
    try std.testing.expectEqual(@as(u64, 0), s.landed_row);
}

test "c7: cancelling a jump keeps the frontier and leaves the document functional" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 300_000);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    const b0 = api.ls_index_poll(od.doc).bytes_scanned;

    api.ls_jump_start(od.doc, 290_000);
    api.ls_jump_cancel(od.doc);
    const s = api.ls_jump_poll(od.doc);
    // After cancel returns: idle — unless the scan had already finished.
    try std.testing.expect(s.state == .idle or s.state == .done);
    try std.testing.expect(api.ls_index_poll(od.doc).bytes_scanned >= b0); // gains kept

    // The head frontier survives: a jump behind it is instant.
    api.ls_jump_start(od.doc, 64);
    const s2 = api.ls_jump_poll(od.doc);
    try std.testing.expectEqual(api.JumpState.done, s2.state);
    try std.testing.expectEqual(@as(u64, 64), s2.landed_row);

    // And a fresh scan still works end-to-end after the cancellation.
    api.ls_jump_start(od.doc, 290_000);
    const s3 = try waitJumpDone(od.doc);
    try std.testing.expectEqual(@as(u64, 290_000), s3.landed_row);
    const r = api.ls_window_set(od.doc, 290_000, 1);
    try std.testing.expectEqual(@as(u64, 1), r.row_count);
    var buf: [8]u8 = undefined;
    try expectCell(od.doc, 290_000, 0, fixedCell(&buf, 290_000));
}

// ---------------------------------------------------------------------------
// Criterion 8 — O(head) open on a multi-GB document: bytes-read probe via the
// frontier, first window < 50 ms in-core, 64-bit byte offsets.
// ---------------------------------------------------------------------------

test "c8: a 5 GiB document opens O(head) and serves the first window instantly" {
    const gpa = std.testing.allocator;
    const head = try genFixedRows(gpa, 2_000); // 36 KB of real records
    defer gpa.free(head);
    const total: u64 = 5 * 1024 * 1024 * 1024; // sparse tail (APFS)
    var fx = try makeSparseFixture(head, total);
    defer fx.deinit();

    const t_open: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    var doc_opt: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &manual, &doc_opt));
    const doc = doc_opt.?;
    defer api.ls_close(doc);
    try std.testing.expect(elapsedMs(t_open) < 500); // never O(file)

    const p = api.ls_index_poll(doc);
    try std.testing.expectEqual(total, p.bytes_total); // 64-bit clean
    try std.testing.expect(p.bytes_scanned <= api.open_head_max_bytes);
    try std.testing.expectEqual(false, p.complete);

    const rc = api.ls_row_count_get(doc);
    try std.testing.expectEqual(false, rc.exact);
    try std.testing.expect(rc.count > 1_000_000); // estimate scales with file size

    const t_window: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    const r = api.ls_window_set(doc, 0, api.open_ready_min_rows);
    try std.testing.expectEqual(@as(u64, api.open_ready_min_rows), r.row_count);
    var buf: [8]u8 = undefined;
    try expectCell(doc, 0, 0, fixedCell(&buf, 0));
    try expectCell(doc, 511, 0, fixedCell(&buf, 511));
    try std.testing.expect(elapsedMs(t_window) < 50); // ARCH: first window < 50 ms
}

// ---------------------------------------------------------------------------
// Carried-over coverage: BOM, empty file, ragged truncate/pad, error codes.
// ---------------------------------------------------------------------------

test "carry: leading UTF-8 BOM is stripped and absent from the first cell" {
    var od = try openBytes("\xEF\xBB\xBFname,age\n1,2\n");
    defer od.deinit();
    try std.testing.expectEqual(true, api.ls_dialect_get(od.doc).header);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "name");
    try expectCell(od.doc, 0, 0, "1");
}

test "carry: BOM-only and empty files are empty documents, complete at open" {
    for ([_][]const u8{ "", "\xEF\xBB\xBF" }) |bytes| {
        var od = try openBytes(bytes);
        defer od.deinit();
        try expectDims(od.doc, 0, 0);
        const d = api.ls_dialect_get(od.doc);
        try std.testing.expectEqual(false, d.header);
        try std.testing.expectEqual(api.default_separator, d.separator);
        try std.testing.expectEqual(api.default_quote, d.quote);
        const p = api.ls_index_poll(od.doc);
        try std.testing.expectEqual(true, p.complete);
        const r = api.ls_window_set(od.doc, 0, 10);
        try std.testing.expectEqual(@as(u64, 0), r.row_count);
        try expectCell(od.doc, 0, 0, "");
        try expectHeaderCell(od.doc, 0, "");
    }
}

test "carry: header forced ON on an empty document still reports header false" {
    var od = try openWith("", .{ .header = api.header_on, .index_mode = api.index_manual });
    defer od.deinit();
    const d = api.ls_dialect_get(od.doc);
    try std.testing.expectEqual(false, d.header);
    try std.testing.expectEqual(true, d.header_forced);
}

test "carry: rows are truncated or padded to the column count" {
    var od = try openBytes("a,b,c\n1,2\n4,5,6,7\n");
    defer od.deinit();
    try expectDims(od.doc, 2, 3);
    winAll(od.doc);
    try expectCell(od.doc, 0, 0, "1");
    try expectCell(od.doc, 0, 1, "2");
    try expectCell(od.doc, 0, 2, ""); // narrower row pads
    try expectCell(od.doc, 1, 0, "4");
    try expectCell(od.doc, 1, 2, "6"); // wider row truncates
    try expectCell(od.doc, 1, 3, ""); // out-of-range col

    var od2 = try openBytes("1,2\n3\n");
    defer od2.deinit();
    try std.testing.expectEqual(false, api.ls_dialect_get(od2.doc).header);
    try expectDims(od2.doc, 2, 2);
    winAll(od2.doc);
    try expectCell(od2.doc, 1, 0, "3");
    try expectCell(od2.doc, 1, 1, "");
}

test "carry: missing path yields not_found and a null handle" {
    var fx = try makeFixture("x\n", 0o644); // only to obtain a real temp dir
    defer fx.deinit();
    const missing = try std.fs.path.joinZ(std.testing.allocator, &.{ std.fs.path.dirname(fx.path).?, "does-not-exist.csv" });
    defer std.testing.allocator.free(missing);
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.not_found, api.ls_open(missing.ptr, &manual, &doc));
    try std.testing.expectEqual(@as(?*api.Doc, null), doc);
}

test "carry: unreadable file yields permission_denied" {
    var fx = try makeFixture("secret\n", 0o000);
    defer fx.deinit();
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.permission_denied, api.ls_open(fx.path.ptr, &manual, &doc));
    try std.testing.expectEqual(@as(?*api.Doc, null), doc);
}

test "carry: a path that is not a readable file yields the distinct io code" {
    var fx = try makeFixture("x\n", 0o644);
    defer fx.deinit();
    const dir_path = try std.testing.allocator.dupeZ(u8, std.fs.path.dirname(fx.path).?);
    defer std.testing.allocator.free(dir_path);
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.io, api.ls_open(dir_path.ptr, &manual, &doc));
    try std.testing.expectEqual(@as(?*api.Doc, null), doc);
    // ABI stability: the failure codes are distinct and pinned to the header.
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.Status.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.Status.not_found));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(api.Status.permission_denied));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(api.Status.io));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(api.Status.invalid_argument));
    // ... and .io is not a catch-all: the sibling readable file still opens.
    var ok_doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &manual, &ok_doc));
    api.ls_close(ok_doc.?);
}

// ---------------------------------------------------------------------------
// Public C ABI: the exported symbols are callable through extern linkage,
// exactly as a frontend links them (struct returns cross the C ABI by value).
// ---------------------------------------------------------------------------

const c_linked = struct {
    extern fn ls_open(path: [*:0]const u8, options: ?*const api.OpenOptions, out_doc: *?*api.Doc) api.Status;
    extern fn ls_close(doc: *api.Doc) void;
    extern fn ls_dialect_get(doc: *const api.Doc) api.Dialect;
    extern fn ls_column_count(doc: *const api.Doc) u32;
    extern fn ls_row_count_get(doc: *const api.Doc) api.RowCount;
    extern fn ls_index_poll(doc: *const api.Doc) api.ScanProgress;
    extern fn ls_window_set(doc: *api.Doc, first_row: u64, row_count: u32) api.RowRange;
    extern fn ls_cell(doc: *const api.Doc, row: u64, col: u32) api.Str;
    extern fn ls_header_cell(doc: *const api.Doc, col: u32) api.Str;
    extern fn ls_jump_start(doc: *api.Doc, target_row: u64) void;
    extern fn ls_jump_cancel(doc: *api.Doc) void;
    extern fn ls_jump_poll(doc: *const api.Doc) api.JumpStatus;
};

test "abi: the exported C symbols are callable through extern linkage" {
    var fx = try makeFixture("a,b\n1,2\n", 0o644);
    defer fx.deinit();
    var doc_opt: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, c_linked.ls_open(fx.path.ptr, &manual, &doc_opt));
    const doc = doc_opt.?;
    defer c_linked.ls_close(doc);

    const d = c_linked.ls_dialect_get(doc);
    try std.testing.expectEqual(api.default_separator, d.separator);
    try std.testing.expectEqual(true, d.header);
    try std.testing.expectEqual(@as(u32, 2), c_linked.ls_column_count(doc));
    const rc = c_linked.ls_row_count_get(doc);
    try std.testing.expectEqual(@as(u64, 1), rc.count);
    try std.testing.expectEqual(true, rc.exact); // tiny file: complete at open
    try std.testing.expectEqual(true, c_linked.ls_index_poll(doc).complete);
    const r = c_linked.ls_window_set(doc, 0, 10);
    try std.testing.expectEqual(@as(u64, 0), r.first_row);
    try std.testing.expectEqual(@as(u64, 1), r.row_count);
    try std.testing.expectEqualStrings("1", c_linked.ls_cell(doc, 0, 0).slice());
    try std.testing.expectEqualStrings("b", c_linked.ls_header_cell(doc, 1).slice());
    c_linked.ls_jump_start(doc, 0);
    try std.testing.expectEqual(api.JumpState.done, c_linked.ls_jump_poll(doc).state);
    c_linked.ls_jump_cancel(doc); // no-op after done
    try std.testing.expectEqual(api.JumpState.done, c_linked.ls_jump_poll(doc).state);
}

// ===========================================================================
// find-seek slice (ARCH-find-seek core criteria 1–6). Frozen; planner-owned.
// Naming: f<criterion>. Semantics under test are pinned in api/lesssheet.h
// (SEARCH section + ls_search_* contracts) and mirrored in contracts/api.zig.
// Determinism: generated needle fixtures force header OFF so record i is data
// row i; every test asserts ls_search_start's `true` BEFORE any poll loop, so
// unimplemented seeds fail fast instead of hanging.
// ===========================================================================

const manualNoHeader: api.OpenOptions = .{ .header = api.header_off, .index_mode = api.index_manual };

fn textReq(query: []const u8) api.SearchRequest {
    return .{ .kind = .text, .value_ptr = query.ptr, .value_len = query.len };
}

fn textReqScoped(query: []const u8, scope: []const u32) api.SearchRequest {
    return .{
        .kind = .text,
        .value_ptr = query.ptr,
        .value_len = query.len,
        .scope_ptr = scope.ptr,
        .scope_len = scope.len,
    };
}

fn predReq(column: u32, op: api.SearchOp, value: []const u8) api.SearchRequest {
    return .{ .kind = .predicate, .op = op, .column = column, .value_ptr = value.ptr, .value_len = value.len };
}

fn startSearch(doc: *api.Doc, req: api.SearchRequest) !void {
    try std.testing.expectEqual(true, api.ls_search_start(doc, &req));
}

fn expectRejected(doc: *api.Doc, req: api.SearchRequest) !void {
    try std.testing.expectEqual(false, api.ls_search_start(doc, &req));
}

/// Poll until the search job reports DONE (<= 15 s); returns the snapshot.
/// Errors immediately on IDLE (a started search never polls IDLE).
fn waitSearchDone(doc: *api.Doc) !api.SearchStatus {
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        const s = api.ls_search_poll(doc);
        if (s.state == .done) return s;
        if (s.state == .idle) return error.SearchNotStarted;
        if (elapsedMs(t0) > 15_000) return error.SearchTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Poll until the nav slot is terminal (FOUND or EXHAUSTED; <= 15 s).
fn waitNavTerminal(doc: *api.Doc) !api.SearchStatus {
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        const s = api.ls_search_poll(doc);
        if (s.nav == .found or s.nav == .exhausted) return s;
        if (s.state == .idle) return error.SearchNotStarted;
        if (elapsedMs(t0) > 15_000) return error.NavTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn navAndWait(doc: *api.Doc, anchor: u64, dir: api.SearchDir) !api.SearchStatus {
    api.ls_search_nav(doc, anchor, dir);
    return waitNavTerminal(doc);
}

fn expectFound(s: api.SearchStatus, row: u64, col: u32, position: u64) !void {
    try std.testing.expectEqual(api.SearchNavState.found, s.nav);
    try std.testing.expectEqual(row, s.found_row);
    try std.testing.expectEqual(col, s.found_col);
    try std.testing.expectEqual(position, s.position);
    try std.testing.expect(s.total >= s.position); // n always exact, m >= n
}

/// Run `req` to completion; returns the final exact total (m).
fn searchTotal(doc: *api.Doc, req: api.SearchRequest) !u64 {
    try startSearch(doc, req);
    const s = try waitSearchDone(doc);
    try std.testing.expectEqual(true, s.total_exact);
    try std.testing.expectEqual(@as(f64, 1.0), s.progress);
    return s.total;
}

/// n fixed-width 18-byte records "{i:0>8},XXXXXXXX\n"; the second cell is the
/// 8-byte marker "needle{seq:0>2}" on the rows listed in `matches` (ascending)
/// and the digits "{2i:0>8}" elsewhere. Digits never contain "needle", so the
/// text query "needle" matches exactly `matches`. Open with manualNoHeader.
fn genNeedleRows(gpa: std.mem.Allocator, n: u64, matches: []const u64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var line: [32]u8 = undefined;
    var mi: usize = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        if (mi < matches.len and matches[mi] == i) {
            try buf.appendSlice(gpa, try std.fmt.bufPrint(&line, "{d:0>8},needle{d:0>2}\n", .{ i, mi % 100 }));
            mi += 1;
        } else {
            try buf.appendSlice(gpa, try std.fmt.bufPrint(&line, "{d:0>8},{d:0>8}\n", .{ i, 2 * i }));
        }
    }
    return buf.toOwnedSlice(gpa);
}

/// The ascending multiples of `step` below `n` (0, step, 2*step, …).
fn ascending(gpa: std.mem.Allocator, n: u64, step: u64) ![]u64 {
    var list: std.ArrayList(u64) = .empty;
    errdefer list.deinit(gpa);
    var i: u64 = 0;
    while (i < n) : (i += step) try list.append(gpa, i);
    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// f1 — text matcher: smart case, substring positions, byte-exact non-ASCII,
// header exclusion, scope, request validation.
// ---------------------------------------------------------------------------

test "f1: smart case — lowercase query folds ASCII; any uppercase byte demands exact bytes" {
    var od = try openBytes("w\nHello\nHELLO\nhello\nshell\nhelp\n");
    defer od.deinit();
    // All-lowercase query: ASCII-case-insensitive substring match.
    try std.testing.expectEqual(@as(u64, 3), try searchTotal(od.doc, textReq("hello")));
    var s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 0, 1); // "Hello"
    s = try navAndWait(od.doc, 1, .forward);
    try expectFound(s, 1, 0, 2); // "HELLO"
    s = try navAndWait(od.doc, 2, .forward);
    try expectFound(s, 2, 0, 3); // "hello"
    s = try navAndWait(od.doc, 3, .forward);
    try std.testing.expectEqual(api.SearchNavState.exhausted, s.nav); // "shell", "help" lack "hello"
    // One ASCII uppercase byte -> the whole query is byte-exact.
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, textReq("Hello")));
    s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 0, 1);
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, textReq("HELLO")));
    s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 1, 0, 1);
    // Exact mode matching nothing: zero total, exact, no movement to offer.
    try std.testing.expectEqual(@as(u64, 0), try searchTotal(od.doc, textReq("hELLO")));
    s = try navAndWait(od.doc, 0, .forward);
    try std.testing.expectEqual(api.SearchNavState.exhausted, s.nav);
}

test "f1: substring matches at cell start, middle, and end" {
    var od = try openBytes("h\nneedle-start\nmid-needle-mid\nend-needle\nno-match\n");
    defer od.deinit();
    try std.testing.expectEqual(@as(u64, 3), try searchTotal(od.doc, textReq("needle")));
    var s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 0, 1);
    s = try navAndWait(od.doc, 1, .forward);
    try expectFound(s, 1, 0, 2);
    s = try navAndWait(od.doc, 2, .forward);
    try expectFound(s, 2, 0, 3);
}

test "f1: UTF-8 beyond ASCII matches byte-exactly in both smart-case modes" {
    var od = try openBytes("h\ncafé\nCAFÉ\ncafe\nCAFE\n");
    defer od.deinit();
    // Lowercase mode folds the ASCII c/a/f; the é bytes never fold, so the
    // all-lowercase query "café" does NOT match "CAFÉ".
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, textReq("café")));
    const s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 0, 1);
    // A plain-ASCII lowercase query folds against both ASCII casings.
    try std.testing.expectEqual(@as(u64, 2), try searchTotal(od.doc, textReq("cafe")));
    // ASCII uppercase C/A/F flips the query to exact mode: only "CAFÉ".
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, textReq("CAFÉ")));
}

test "f1: the header record is never searched" {
    var od = try openBytes("needle,also needle\nx,y\nz,needle\n");
    defer od.deinit();
    try std.testing.expectEqual(true, api.ls_dialect_get(od.doc).header);
    // Both header cells contain the query but are never evaluated.
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, textReq("needle")));
    const s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 1, 1, 1); // data row 1, column 1
}

test "f1: text scope excludes columns exactly; the lowest in-scope match column is reported" {
    var od = try openBytes("a,b,c\nneedle,x,x\nx,needle,x\nx,x,needle\nx,needle,needle\n");
    defer od.deinit();
    // NULL scope = all columns.
    try std.testing.expectEqual(@as(u64, 4), try searchTotal(od.doc, textReq("needle")));
    var s = try navAndWait(od.doc, 3, .forward);
    try expectFound(s, 3, 1, 4); // row 3 matches in cols 1 and 2: lowest wins
    // Scope {1}: only column-1 cells are evaluated.
    try std.testing.expectEqual(@as(u64, 2), try searchTotal(od.doc, textReqScoped("needle", &.{1})));
    s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 1, 1, 1);
    s = try navAndWait(od.doc, 2, .forward);
    try expectFound(s, 3, 1, 2);
    // Scope {0,2}: rows 0, 2, 3 — and row 3's match column is 2 under it.
    try std.testing.expectEqual(@as(u64, 3), try searchTotal(od.doc, textReqScoped("needle", &.{ 0, 2 })));
    s = try navAndWait(od.doc, 3, .forward);
    try expectFound(s, 3, 2, 3);
}

test "f1: invalid requests are rejected with zero state change" {
    var od = try openBytes("a,b\nneedle,2\n");
    defer od.deinit();
    // Rejections on a fresh document leave it IDLE (all-zero snapshot).
    try expectRejected(od.doc, textReq("")); // the empty query means "no search"
    try expectRejected(od.doc, textReqScoped("x", &.{ 0, 7 })); // out-of-range scope column
    const dummy: [1]u32 = .{0};
    try expectRejected(od.doc, .{
        .kind = .text,
        .value_ptr = "x",
        .value_len = 1,
        .scope_ptr = &dummy,
        .scope_len = 0, // non-NULL empty scope is invalid
    });
    var s = api.ls_search_poll(od.doc);
    try std.testing.expectEqual(api.SearchState.idle, s.state);
    try std.testing.expectEqual(api.SearchNavState.none, s.nav);
    // A nav without an active search is a no-op.
    api.ls_search_nav(od.doc, 0, .forward);
    s = api.ls_search_poll(od.doc);
    try std.testing.expectEqual(api.SearchState.idle, s.state);
    try std.testing.expectEqual(api.SearchNavState.none, s.nav);

    // After a real search, a rejected start leaves it fully intact.
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, textReq("needle")));
    try expectRejected(od.doc, textReq(""));
    s = api.ls_search_poll(od.doc);
    try std.testing.expectEqual(api.SearchState.done, s.state);
    try std.testing.expectEqual(@as(u64, 1), s.total);
    try std.testing.expectEqual(true, s.total_exact);
}

// ---------------------------------------------------------------------------
// f2 — predicate matcher: byte-exact =/≠, numeric ordering under the pinned
// grammar with EXACT comparison, non-numeric-never-matches, value validation.
// ---------------------------------------------------------------------------

test "f2: = and ≠ compare byte-exactly (no folding, no trimming); = '' matches empty and padded cells" {
    var od = try openBytes("h1,h2\nx,abc\ny,Abc\nz, abc\nw,abc\nv\n");
    defer od.deinit();
    try std.testing.expectEqual(@as(u64, 2), try searchTotal(od.doc, predReq(1, .eq, "abc"))); // rows 0, 3
    var s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 1, 1);
    s = try navAndWait(od.doc, 1, .forward);
    try expectFound(s, 3, 1, 2);
    // "Abc" (case) and " abc" (padding) are unequal bytes -> they are ≠.
    try std.testing.expectEqual(@as(u64, 3), try searchTotal(od.doc, predReq(1, .ne, "abc")));
    // The ragged row 4 pads column 1 with the empty cell: = "" finds it.
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, predReq(1, .eq, "")));
    s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 4, 1, 1);
}

test "f2: ordering operators — grammar acceptance, boundary equality for ≤ ≥, non-numeric never matches" {
    var od = try openBytes("v\n1\n2\n2.0\n10\n2.5\n-3\n+4\n1e2\n 12 \n0x1F\nabc\n\n.5\n5.\nNaN\n");
    defer od.deinit();
    try expectDims(od.doc, 15, 1);
    try std.testing.expectEqual(@as(u64, 3), try searchTotal(od.doc, predReq(0, .lt, "2"))); // 1, -3, .5
    try std.testing.expectEqual(@as(u64, 6), try searchTotal(od.doc, predReq(0, .gt, "2"))); // 10, 2.5, +4, 1e2, " 12 ", 5.
    try std.testing.expectEqual(@as(u64, 5), try searchTotal(od.doc, predReq(0, .le, "2"))); // lt + {2, 2.0}
    try std.testing.expectEqual(@as(u64, 8), try searchTotal(od.doc, predReq(0, .ge, "2"))); // gt + {2, 2.0}
    // "2.0" equals 2 by mathematical value: ≤/≥ include it, </> exclude it —
    // while byte-exact = still distinguishes the two representations.
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, predReq(0, .eq, "2")));
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, predReq(0, .eq, "2.0")));
    try std.testing.expectEqual(@as(u64, 5), try searchTotal(od.doc, predReq(0, .le, "2.0")));
    // Every numeric cell and only the numeric cells ("0x1F", "abc", the empty
    // record, and "NaN" never match an ordering operator).
    try std.testing.expectEqual(@as(u64, 11), try searchTotal(od.doc, predReq(0, .ge, "-3")));
    try std.testing.expectEqual(@as(u64, 0), try searchTotal(od.doc, predReq(0, .lt, "-3")));
}

test "f2: signed zeros and exponent forms compare equal by mathematical value" {
    var od = try openBytes("v\n0\n+0\n-0\n0.0\n0e5\n");
    defer od.deinit();
    try std.testing.expectEqual(@as(u64, 5), try searchTotal(od.doc, predReq(0, .le, "0")));
    try std.testing.expectEqual(@as(u64, 5), try searchTotal(od.doc, predReq(0, .ge, "0")));
    try std.testing.expectEqual(@as(u64, 0), try searchTotal(od.doc, predReq(0, .lt, "0")));
    try std.testing.expectEqual(@as(u64, 0), try searchTotal(od.doc, predReq(0, .gt, "0")));

    var od2 = try openBytes("v\n1e-2\n0.01\n100\n1e2\n");
    defer od2.deinit();
    try std.testing.expectEqual(@as(u64, 2), try searchTotal(od2.doc, predReq(0, .le, "0.01")));
    try std.testing.expectEqual(@as(u64, 2), try searchTotal(od2.doc, predReq(0, .ge, "1e2")));
    try std.testing.expectEqual(@as(u64, 0), try searchTotal(od2.doc, predReq(0, .gt, "100")));
    try std.testing.expectEqual(@as(u64, 4), try searchTotal(od2.doc, predReq(0, .ge, "0.01")));
}

test "f2: ordering comparison is exact beyond double precision" {
    // Adjacent 39-digit integers (u128-scale ids) order correctly; a double
    // would collapse them.
    var od = try openBytes("v\n340282366920938463463374607431768211455\n340282366920938463463374607431768211454\n");
    defer od.deinit();
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, predReq(0, .gt, "340282366920938463463374607431768211454")));
    const s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 0, 1);
    try std.testing.expectEqual(@as(u64, 2), try searchTotal(od.doc, predReq(0, .ge, "340282366920938463463374607431768211454")));
    // 2^53 and 2^53 + 1 are distinct (both round to the same double).
    var od2 = try openBytes("v\n9007199254740993\n9007199254740992\n");
    defer od2.deinit();
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od2.doc, predReq(0, .gt, "9007199254740992")));
    // Magnitudes beyond double range still order.
    var od3 = try openBytes("v\n1e400\n1e399\n");
    defer od3.deinit();
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od3.doc, predReq(0, .gt, "1e399")));
    try std.testing.expectEqual(@as(u64, 2), try searchTotal(od3.doc, predReq(0, .le, "1e400")));
    // Long fractions are not truncated.
    var od4 = try openBytes("v\n0.1\n0.10000000000000000000000001\n");
    defer od4.deinit();
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od4.doc, predReq(0, .gt, "0.1")));
}

test "f2: ordering with a non-numeric value is rejected; the predicate column must exist" {
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    try expectRejected(od.doc, predReq(0, .lt, "abc"));
    try expectRejected(od.doc, predReq(0, .le, "")); // empty is not numeric
    try expectRejected(od.doc, predReq(0, .ge, "1,000"));
    try expectRejected(od.doc, predReq(0, .gt, "1e"));
    try expectRejected(od.doc, predReq(99, .eq, "x")); // no column 99
    try std.testing.expectEqual(api.SearchState.idle, api.ls_search_poll(od.doc).state);
    // ...while = with the same non-numeric value is a legal byte comparison,
    // and grammar-accepted values (" 12 ", ".5", "+1e5") drive ordering.
    try std.testing.expectEqual(@as(u64, 0), try searchTotal(od.doc, predReq(0, .eq, "abc")));
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, predReq(0, .lt, " 12 ")));
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, predReq(1, .gt, ".5")));
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, predReq(0, .lt, "+1e5")));
}

// ---------------------------------------------------------------------------
// f3 — streaming navigation: exact landings both directions, behind and
// beyond the frontier; the shared frontier advances (paid once); monotone
// progress to 1.0.
// ---------------------------------------------------------------------------

test "f3: navigation anchors are inclusive-forward / strictly-before-backward" {
    const gpa = std.testing.allocator;
    const fixture = try genNeedleRows(gpa, 8, &.{ 0, 5 });
    defer gpa.free(fixture);
    var od = try openWith(fixture, manualNoHeader);
    defer od.deinit();
    try startSearch(od.doc, textReq("needle"));
    var s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 1, 1); // forward includes the anchor row itself
    s = try navAndWait(od.doc, 5, .forward);
    try expectFound(s, 5, 1, 2);
    s = try navAndWait(od.doc, 6, .forward);
    try std.testing.expectEqual(api.SearchNavState.exhausted, s.nav);
    s = try navAndWait(od.doc, 5, .backward);
    try expectFound(s, 0, 1, 1); // backward is strictly before the anchor
    s = try navAndWait(od.doc, 0, .backward);
    try std.testing.expectEqual(api.SearchNavState.exhausted, s.nav); // nothing before row 0
    s = try navAndWait(od.doc, std.math.maxInt(u64), .backward);
    try expectFound(s, 5, 1, 2); // last-in-file
    const done = try waitSearchDone(od.doc);
    try std.testing.expectEqual(@as(u64, 2), done.total);
}

test "f3: streaming navigation is exact behind and beyond the frontier; the shared frontier advances" {
    const gpa = std.testing.allocator;
    const fixture = try genNeedleRows(gpa, 300_000, &.{ 100, 150_000, 290_000 });
    defer gpa.free(fixture);
    var od = try openWith(fixture, manualNoHeader);
    defer od.deinit();
    try startSearch(od.doc, textReq("needle"));

    // Within the open head frontier.
    var s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 100, 1, 1);
    s = try navAndWait(od.doc, 101, .forward);
    try expectFound(s, 150_000, 1, 2); // byte 2.7 MB: still inside the head
    // Row 290,000 starts at byte 5.22 MB — beyond any legal MANUAL open
    // frontier: serving it must advance the SHARED frontier.
    s = try navAndWait(od.doc, 150_001, .forward);
    try expectFound(s, 290_000, 1, 3);
    try std.testing.expect(api.ls_index_poll(od.doc).bytes_scanned >= 290_000 * 18);
    // Paid once: a jump into the searched region is now synchronous-instant,
    // and it must NOT disturb the running search (no scan needed).
    api.ls_jump_start(od.doc, 290_000);
    const j = api.ls_jump_poll(od.doc);
    try std.testing.expectEqual(api.JumpState.done, j.state);
    try std.testing.expectEqual(@as(u64, 290_000), j.landed_row);
    const r = api.ls_window_set(od.doc, 290_000, 1);
    try std.testing.expectEqual(@as(u64, 1), r.row_count);
    try expectCell(od.doc, 290_000, 1, "needle02");

    // Backward, across the whole file.
    s = try navAndWait(od.doc, 290_000, .backward);
    try expectFound(s, 150_000, 1, 2);
    s = try navAndWait(od.doc, 150_000, .backward);
    try expectFound(s, 100, 1, 1);
    s = try navAndWait(od.doc, 100, .backward);
    try std.testing.expectEqual(api.SearchNavState.exhausted, s.nav);
    s = try navAndWait(od.doc, std.math.maxInt(u64), .backward);
    try expectFound(s, 290_000, 1, 3);

    const done = try waitSearchDone(od.doc);
    try std.testing.expectEqual(@as(u64, 3), done.total);
    try std.testing.expectEqual(true, done.total_exact);
}

test "f3: search progress and totals are monotone; progress is exactly 1.0 at DONE" {
    const gpa = std.testing.allocator;
    const fixture = try genNeedleRows(gpa, 300_000, &.{ 100, 200_000 });
    defer gpa.free(fixture);
    var od = try openWith(fixture, manualNoHeader);
    defer od.deinit();
    try startSearch(od.doc, textReq("needle"));
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    var last_progress: f64 = 0.0;
    var last_total: u64 = 0;
    while (true) {
        const s = api.ls_search_poll(od.doc);
        try std.testing.expect(s.progress >= 0.0 and s.progress <= 1.0);
        try std.testing.expect(s.progress >= last_progress);
        try std.testing.expect(s.total >= last_total);
        last_progress = s.progress;
        last_total = s.total;
        if (s.state == .done) {
            try std.testing.expectEqual(@as(f64, 1.0), s.progress);
            try std.testing.expectEqual(@as(u64, 2), s.total);
            try std.testing.expectEqual(true, s.total_exact);
            break;
        }
        if (elapsedMs(t0) > 15_000) return error.SearchTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

// ---------------------------------------------------------------------------
// f4 — bounded counts: exact totals and positions on known layouts (zero,
// dense, checkpoint-straddling); O(checkpoints) memory; zero-alloc polls.
// ---------------------------------------------------------------------------

test "f4: counts are exact on known layouts — zero, dense, and checkpoint-straddling" {
    const gpa = std.testing.allocator;
    { // Zero matches: "No matches" is a DONE with total 0 and no movement.
        const fixture = try genNeedleRows(gpa, 10_000, &.{});
        defer gpa.free(fixture);
        var od = try openWith(fixture, manualNoHeader);
        defer od.deinit();
        try std.testing.expectEqual(@as(u64, 0), try searchTotal(od.doc, textReq("needle")));
        const s = try navAndWait(od.doc, 0, .forward);
        try std.testing.expectEqual(api.SearchNavState.exhausted, s.nav);
    }
    { // Every row matches.
        const all = try ascending(gpa, 10_000, 1);
        defer gpa.free(all);
        const fixture = try genNeedleRows(gpa, 10_000, all);
        defer gpa.free(fixture);
        var od = try openWith(fixture, manualNoHeader);
        defer od.deinit();
        try std.testing.expectEqual(@as(u64, 10_000), try searchTotal(od.doc, textReq("needle")));
        var s = try navAndWait(od.doc, 0, .forward);
        try expectFound(s, 0, 1, 1);
        s = try navAndWait(od.doc, 5_000, .forward);
        try expectFound(s, 5_000, 1, 5_001);
        s = try navAndWait(od.doc, 9_999, .forward);
        try expectFound(s, 9_999, 1, 10_000);
        s = try navAndWait(od.doc, 9_999, .backward);
        try expectFound(s, 9_998, 1, 9_999);
    }
    { // Matches straddling likely checkpoint boundaries: walk every match in
      // both directions; positions stay exact across block edges.
        const matches = [_]u64{ 1023, 1024, 2047, 2048, 2049, 4095, 4096, 6143, 6144, 8191, 8192 };
        const fixture = try genNeedleRows(gpa, 10_000, &matches);
        defer gpa.free(fixture);
        var od = try openWith(fixture, manualNoHeader);
        defer od.deinit();
        try std.testing.expectEqual(@as(u64, matches.len), try searchTotal(od.doc, textReq("needle")));
        var i: usize = 0;
        var anchor: u64 = 0;
        while (i < matches.len) : (i += 1) {
            const s = try navAndWait(od.doc, anchor, .forward);
            try expectFound(s, matches[i], 1, i + 1);
            anchor = matches[i] + 1;
        }
        var s = try navAndWait(od.doc, anchor, .forward);
        try std.testing.expectEqual(api.SearchNavState.exhausted, s.nav);
        i = matches.len;
        var back: u64 = std.math.maxInt(u64);
        while (i > 0) : (i -= 1) {
            s = try navAndWait(od.doc, back, .backward);
            try expectFound(s, matches[i - 1], 1, i);
            back = matches[i - 1];
        }
        s = try navAndWait(od.doc, back, .backward);
        try std.testing.expectEqual(api.SearchNavState.exhausted, s.nav);
    }
}

/// Accumulates every requested allocation size (alloc len + resize/remap
/// new_len) while delegating to a parent allocator. Monotone and coarse:
/// storage that grew with match COUNT would show up here.
const BytesAllocator = struct {
    parent: std.mem.Allocator,
    bytes: std.atomic.Value(u64) = .init(0),

    fn allocator(self: *BytesAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = self_of(ctx);
        _ = self.bytes.fetchAdd(len, .monotonic);
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = self_of(ctx);
        _ = self.bytes.fetchAdd(new_len, .monotonic);
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = self_of(ctx);
        _ = self.bytes.fetchAdd(new_len, .monotonic);
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        return self_of(ctx).parent.vtable.free(self_of(ctx).parent.ptr, memory, alignment, ret_addr);
    }
    fn self_of(ctx: *anyopaque) *BytesAllocator {
        return @ptrCast(@alignCast(ctx));
    }
};

test "f4: dense-match count storage is O(checkpoints) — independent of match density" {
    const gpa = std.testing.allocator;
    const n: u64 = 200_000; // 3.6 MB: fully indexed at open (head budget), so
    // the deltas below measure SEARCH allocations only.
    const sparse_rows = try ascending(gpa, n, 20_000); // 10 matches
    defer gpa.free(sparse_rows);
    const dense_rows = try ascending(gpa, n, 1); // every row matches
    defer gpa.free(dense_rows);

    const sets = [2][]const u64{ sparse_rows, dense_rows };
    const expected = [2]u64{ 10, n };
    var deltas: [2]u64 = undefined;
    for (sets, 0..) |match_set, idx| {
        const fixture = try genNeedleRows(gpa, n, match_set);
        defer gpa.free(fixture);
        var fx = try makeFixture(fixture, 0o644);
        defer fx.deinit();
        var tracking: BytesAllocator = .{ .parent = std.testing.allocator };
        var doc_opt: ?*api.Doc = null;
        try std.testing.expectEqual(api.Status.ok, api.openWithAllocator(tracking.allocator(), fx.path.ptr, &manualNoHeader, &doc_opt));
        const doc = doc_opt.?;
        defer api.ls_close(doc);
        const before = tracking.bytes.load(.monotonic);
        try startSearch(doc, textReq("needle"));
        const s = try waitSearchDone(doc);
        try std.testing.expectEqual(expected[idx], s.total);
        deltas[idx] = tracking.bytes.load(.monotonic) - before;
    }
    // A materialized match-row list would grow the dense search by ~200k
    // entries (>= 1.6 MB); per-block counters are identical for both layouts.
    try std.testing.expect(deltas[1] <= deltas[0] + 64 * 1024);
}

test "f4: search polls and cancel are zero-allocation; DONE navs complete synchronously" {
    var counting: CountingAllocator = .{ .parent = std.testing.allocator };
    var fx = try makeFixture("h\nneedle\nplain\n", 0o644);
    defer fx.deinit();
    var doc_opt: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.openWithAllocator(counting.allocator(), fx.path.ptr, &manual, &doc_opt));
    const doc = doc_opt.?;
    defer api.ls_close(doc);
    // The search machinery is lazy: an IDLE poll allocates nothing.
    const before_any = counting.count;
    _ = api.ls_search_poll(doc);
    try std.testing.expectEqual(before_any, counting.count);
    // Run a search to DONE (start/nav/scan may allocate)...
    try startSearch(doc, textReq("needle"));
    _ = try waitSearchDone(doc);
    // After DONE, every navigation completes before ls_search_nav returns.
    api.ls_search_nav(doc, 0, .forward);
    const instant = api.ls_search_poll(doc);
    try expectFound(instant, 0, 0, 1);
    // ...and the poll/cancel paths are allocation-free afterwards.
    const after_setup = counting.count;
    _ = api.ls_search_poll(doc);
    api.ls_search_cancel(doc); // no-op after DONE
    const s = api.ls_search_poll(doc);
    try std.testing.expectEqual(api.SearchState.done, s.state);
    try std.testing.expectEqual(after_setup, counting.count);
}

// ---------------------------------------------------------------------------
// f5 — job discipline: the single scan slot (search <-> jump mutual
// cancellation, kept gains, terminal states, nav resume), search replacement,
// close-during-search safety, AUTO-mode coexistence.
// ---------------------------------------------------------------------------

test "f5: a new search replaces the previous one — counts and navigation reset" {
    var od = try openBytes("h\nfoo\nbar\nfoo\nfoobar\n");
    defer od.deinit();
    try std.testing.expectEqual(@as(u64, 3), try searchTotal(od.doc, textReq("foo")));
    var s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 0, 1);
    // Replace: the snapshot resets (nav NONE, found/position zeroed)...
    try startSearch(od.doc, textReq("bar"));
    s = api.ls_search_poll(od.doc);
    try std.testing.expect(s.state == .scanning or s.state == .done);
    try std.testing.expectEqual(api.SearchNavState.none, s.nav);
    try std.testing.expectEqual(@as(u64, 0), s.found_row);
    try std.testing.expectEqual(@as(u64, 0), s.position);
    // ...and the new counts converge to the new query's exact total.
    const done = try waitSearchDone(od.doc);
    try std.testing.expectEqual(@as(u64, 2), done.total);
    s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 1, 0, 1);
}

test "f5: ls_search_cancel is terminal — counts freeze; DONE persists; pending nav resolves" {
    const gpa = std.testing.allocator;
    const fixture = try genNeedleRows(gpa, 300_000, &.{ 10, 250_000 });
    defer gpa.free(fixture);
    var od = try openWith(fixture, manualNoHeader);
    defer od.deinit();
    try startSearch(od.doc, textReq("needle"));
    api.ls_search_nav(od.doc, 200_000, .forward);
    api.ls_search_cancel(od.doc);
    const s = api.ls_search_poll(od.doc);
    try std.testing.expect(s.state == .cancelled or s.state == .done);
    try std.testing.expect(s.nav != .searching); // pending nav resolved (NONE) or already terminal
    // Frozen: a later snapshot is identical (nothing scans anymore).
    try std.testing.io.sleep(.fromMilliseconds(25), .awake);
    const s2 = api.ls_search_poll(od.doc);
    try std.testing.expectEqual(s.state, s2.state);
    try std.testing.expectEqual(s.total, s2.total);
    try std.testing.expectEqual(s.progress, s2.progress);
    try std.testing.expectEqual(s.nav, s2.nav);
    if (s2.state == .cancelled) {
        try std.testing.expectEqual(false, s2.total_exact);
        try std.testing.expect(s2.progress < 1.0);
    }
    // Cancel after completion: DONE persists.
    var od2 = try openBytes("h\nneedle\n");
    defer od2.deinit();
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od2.doc, textReq("needle")));
    api.ls_search_cancel(od2.doc);
    const s3 = api.ls_search_poll(od2.doc);
    try std.testing.expectEqual(api.SearchState.done, s3.state);
    try std.testing.expectEqual(true, s3.total_exact);
}

test "f5: the single scan slot — search and jump cancel each other; instant jumps do not disturb" {
    const gpa = std.testing.allocator;
    const fixture = try genNeedleRows(gpa, 2_000_000, &.{ 5, 1_999_990 });
    defer gpa.free(fixture);
    var od = try openWith(fixture, manualNoHeader);
    defer od.deinit();

    // (a) ls_search_start cancels a scanning jump (36 MB target: it cannot
    // finish in the microseconds before the search starts) to IDLE.
    api.ls_jump_start(od.doc, 1_900_000);
    try std.testing.expectEqual(api.JumpState.scanning, api.ls_jump_poll(od.doc).state);
    const b0 = api.ls_index_poll(od.doc).bytes_scanned;
    try startSearch(od.doc, textReq("needle"));
    try std.testing.expectEqual(api.JumpState.idle, api.ls_jump_poll(od.doc).state);
    try std.testing.expect(api.ls_index_poll(od.doc).bytes_scanned >= b0); // gains kept

    // (b) an instant (behind-frontier) jump does NOT disturb the search.
    const s0 = api.ls_search_poll(od.doc);
    api.ls_jump_start(od.doc, 3);
    const j = api.ls_jump_poll(od.doc);
    try std.testing.expectEqual(api.JumpState.done, j.state);
    try std.testing.expectEqual(@as(u64, 3), j.landed_row);
    if (s0.state == .scanning) {
        const s1 = api.ls_search_poll(od.doc);
        try std.testing.expect(s1.state == .scanning or s1.state == .done);
    }

    // (c) a jump that must scan cancels the search terminally; counts, found
    // results, and frontier gains are kept.
    var s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 5, 1, 1);
    api.ls_jump_start(od.doc, 1_950_000);
    s = api.ls_search_poll(od.doc);
    try std.testing.expect(s.state == .cancelled or s.state == .done);
    try expectFound(s, 5, 1, 1); // the landing persists across the cancellation
    if (s.state == .cancelled) {
        try std.testing.expectEqual(false, s.total_exact);
        const frozen = api.ls_search_poll(od.doc);
        try std.testing.expectEqual(s.total, frozen.total);
        try std.testing.expectEqual(s.progress, frozen.progress);
    }
    const jd = try waitJumpDone(od.doc);
    try std.testing.expectEqual(@as(u64, 1_950_000), jd.landed_row);

    // (d) a nav needing uncovered rows RESUMES the cancelled search and takes
    // the slot back (cancelling a scanning jump); the resumed scan reaches
    // EOF here, so the search finishes DONE with the exact final total.
    api.ls_jump_start(od.doc, 1_999_999);
    const j2 = api.ls_jump_poll(od.doc);
    api.ls_search_nav(od.doc, std.math.maxInt(u64), .backward);
    if (j2.state == .scanning) {
        const j3 = api.ls_jump_poll(od.doc);
        try std.testing.expect(j3.state == .idle or j3.state == .done);
    }
    s = try waitNavTerminal(od.doc);
    try expectFound(s, 1_999_990, 1, 2);
    const done = api.ls_search_poll(od.doc);
    try std.testing.expectEqual(api.SearchState.done, done.state);
    try std.testing.expectEqual(@as(u64, 2), done.total);
    try std.testing.expectEqual(true, done.total_exact);
    try std.testing.expectEqual(@as(f64, 1.0), done.progress);
}

test "f5: ls_close during an active match-scan is safe (MANUAL and AUTO)" {
    const gpa = std.testing.allocator;
    const fixture = try genNeedleRows(gpa, 300_000, &.{ 7, 200_000 });
    defer gpa.free(fixture);
    for ([_]i32{ api.index_manual, api.index_auto }) |mode| {
        var fx = try makeFixture(fixture, 0o644);
        defer fx.deinit();
        var doc_opt: ?*api.Doc = null;
        const opts: api.OpenOptions = .{ .header = api.header_off, .index_mode = mode };
        try std.testing.expectEqual(api.Status.ok, api.openWithAllocator(std.testing.allocator, fx.path.ptr, &opts, &doc_opt));
        const doc = doc_opt.?;
        try startSearch(doc, textReq("needle"));
        api.ls_search_nav(doc, std.math.maxInt(u64), .backward);
        // Close mid-scan: must cancel + join core threads; the testing
        // allocator fails the test on any leak.
        api.ls_close(doc);
    }
}

test "f5: a search under AUTO indexing reaches the same exact counts" {
    const gpa = std.testing.allocator;
    const fixture = try genNeedleRows(gpa, 300_000, &.{ 100, 150_000, 299_999 });
    defer gpa.free(fixture);
    var od = try openWith(fixture, .{ .header = api.header_off }); // AUTO index
    defer od.deinit();
    try startSearch(od.doc, textReq("needle"));
    const done = try waitSearchDone(od.doc);
    try std.testing.expectEqual(@as(u64, 3), done.total);
    try std.testing.expectEqual(true, done.total_exact);
    const s = try navAndWait(od.doc, 150_001, .forward);
    try expectFound(s, 299_999, 1, 3);
}

// ---------------------------------------------------------------------------
// f6 — document identity: search state is per-handle; a dialect re-open
// starts from zero.
// ---------------------------------------------------------------------------

test "f6: a dialect re-open starts with zero search state" {
    var fx = try makeFixture("needle,x\nfoo,needle\n", 0o644);
    defer fx.deinit();
    // First open: sniffed header ON -> 1 data row, 1 match.
    var doc_opt: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &manual, &doc_opt));
    var doc = doc_opt.?;
    var s = api.ls_search_poll(doc);
    try std.testing.expectEqual(api.SearchState.idle, s.state); // fresh handle: all-zero
    try std.testing.expectEqual(api.SearchNavState.none, s.nav);
    try std.testing.expectEqual(@as(f64, 0.0), s.progress);
    try std.testing.expectEqual(@as(u64, 0), s.total);
    try std.testing.expectEqual(false, s.total_exact);
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(doc, textReq("needle")));
    api.ls_close(doc);

    // Re-open with a forced dialect change (header OFF): zero search state,
    // and a fresh search sees the re-dialected document (2 data rows match).
    const opts: api.OpenOptions = .{ .header = api.header_off, .index_mode = api.index_manual };
    doc_opt = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &opts, &doc_opt));
    doc = doc_opt.?;
    defer api.ls_close(doc);
    s = api.ls_search_poll(doc);
    try std.testing.expectEqual(api.SearchState.idle, s.state);
    try std.testing.expectEqual(api.SearchNavState.none, s.nav);
    try std.testing.expectEqual(@as(u64, 0), s.total);
    try std.testing.expectEqual(false, s.total_exact);
    try std.testing.expectEqual(@as(u64, 2), try searchTotal(doc, textReq("needle")));
}

// ---------------------------------------------------------------------------
// Public C ABI: the search symbols are callable through extern linkage, and
// the enum values are pinned to the header.
// ---------------------------------------------------------------------------

const c_linked_search = struct {
    extern fn ls_search_start(doc: *api.Doc, request: *const api.SearchRequest) bool;
    extern fn ls_search_nav(doc: *api.Doc, anchor_row: u64, dir: api.SearchDir) void;
    extern fn ls_search_cancel(doc: *api.Doc) void;
    extern fn ls_search_poll(doc: *const api.Doc) api.SearchStatus;
};

test "abi: the search C symbols are callable through extern linkage; enum values pinned" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.SearchKind.text));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.SearchKind.predicate));
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.SearchOp.eq));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.SearchOp.ne));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(api.SearchOp.lt));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(api.SearchOp.gt));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(api.SearchOp.le));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(api.SearchOp.ge));
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.SearchDir.forward));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.SearchDir.backward));
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.SearchState.idle));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.SearchState.scanning));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(api.SearchState.done));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(api.SearchState.cancelled));
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.SearchNavState.none));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.SearchNavState.searching));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(api.SearchNavState.found));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(api.SearchNavState.exhausted));

    var od = try openBytes("h\nneedle\nplain\n");
    defer od.deinit();
    const req = textReq("needle");
    try std.testing.expectEqual(true, c_linked_search.ls_search_start(od.doc, &req));
    c_linked_search.ls_search_nav(od.doc, 0, .forward);
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        const s = c_linked_search.ls_search_poll(od.doc);
        if (s.state == .done and s.nav == .found) {
            try std.testing.expectEqual(@as(u64, 0), s.found_row);
            try std.testing.expectEqual(@as(u32, 0), s.found_col);
            try std.testing.expectEqual(@as(u64, 1), s.position);
            try std.testing.expectEqual(@as(u64, 1), s.total);
            try std.testing.expectEqual(true, s.total_exact);
            break;
        }
        if (s.state == .idle) return error.SearchNotStarted;
        if (elapsedMs(t0) > 15_000) return error.SearchTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    c_linked_search.ls_search_cancel(od.doc); // no-op after DONE
    try std.testing.expectEqual(api.SearchState.done, c_linked_search.ls_search_poll(od.doc).state);
}

// ===========================================================================
// csv-hardening slice (ARCH-csv-hardening core criteria 1-17; app criteria
// 18-20 live in apps/macos). Frozen; planner-owned. Naming: h<criterion>.
// Semantics are pinned in api/lesssheet.h (TEXT AND ENCODING: detection
// pipeline, transcode-to-UTF-8 guarantee vs UTF-8 pass-through, the
// LS_CELL_MAX_BYTES display cap, search-over-the-full-cell; DELIMITED-TEXT:
// bounded record 1) and mirrored in contracts/api.zig. Tests exercise the
// PUBLIC C ABI through @import("api") only, reusing the helpers above
// (openBytes/openWith, expectCell, expectDims, scanToEnd, searchTotal, ...).
// Determinism: fixtures no larger than the head budget are fully indexed at
// open (row counts exact immediately); large-file probes use MANUAL mode +
// sparse fixtures and assert the O(head) SOURCE-byte bound.
// ===========================================================================

/// UTF-16 code units of UTF-8 `s` (BMP direct; astral as surrogate pairs).
fn utf16Units(gpa: std.mem.Allocator, s: []const u8) ![]u16 {
    var units: std.ArrayList(u16) = .empty;
    errdefer units.deinit(gpa);
    var it = (std.unicode.Utf8View.init(s) catch unreachable).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0xFFFF) {
            try units.append(gpa, @intCast(cp));
        } else {
            const v = cp - 0x10000;
            try units.append(gpa, @intCast(0xD800 + (v >> 10)));
            try units.append(gpa, @intCast(0xDC00 + (v & 0x3FF)));
        }
    }
    return units.toOwnedSlice(gpa);
}

/// UTF-16 bytes of `s`, `little` endian, with an optional matching leading BOM.
fn toUtf16(gpa: std.mem.Allocator, s: []const u8, little: bool, bom: bool) ![]u8 {
    const units = try utf16Units(gpa, s);
    defer gpa.free(units);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (bom) try out.appendSlice(gpa, if (little) &[_]u8{ 0xFF, 0xFE } else &[_]u8{ 0xFE, 0xFF });
    for (units) |u| {
        const hi: u8 = @intCast(u >> 8);
        const lo: u8 = @intCast(u & 0xFF);
        try out.appendSlice(gpa, if (little) &[_]u8{ lo, hi } else &[_]u8{ hi, lo });
    }
    return out.toOwnedSlice(gpa);
}

fn expectEncoding(doc: *const api.Doc, encoding: u8, forced: bool) !void {
    const d = api.ls_dialect_get(doc);
    try std.testing.expectEqual(encoding, d.encoding);
    try std.testing.expectEqual(forced, d.encoding_forced);
}

// ---------------------------------------------------------------------------
// h1..h12 — encoding detection, transcoding, forcing, reporting, bounds.
// ---------------------------------------------------------------------------

test "h1: UTF-16LE with BOM decodes to UTF-8; BOM absent; report UTF-16 LE" {
    const gpa = std.testing.allocator;
    const src = try toUtf16(gpa, "name,city\nJosé,42\n", true, true);
    defer gpa.free(src);
    var od = try openBytes(src); // automatic detection
    defer od.deinit();
    const d = api.ls_dialect_get(od.doc);
    try expectEncoding(od.doc, api.encoding_utf16le, false);
    try std.testing.expectEqual(@as(u8, ','), d.separator); // sniffed on transcoded UTF-8
    try std.testing.expectEqual(true, d.header);
    try expectDims(od.doc, 1, 2);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "name");
    try expectCell(od.doc, 0, 0, "José"); // UTF-8: 4A 6F 73 C3 A9
    try expectCell(od.doc, 0, 1, "42");
}

test "h2: UTF-16BE with BOM decodes to UTF-8; report UTF-16 BE" {
    const gpa = std.testing.allocator;
    const src = try toUtf16(gpa, "name,city\nJosé,42\n", false, true);
    defer gpa.free(src);
    var od = try openBytes(src);
    defer od.deinit();
    try expectEncoding(od.doc, api.encoding_utf16be, false);
    try expectDims(od.doc, 1, 2);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 1, "city");
    try expectCell(od.doc, 0, 0, "José");
}

test "h3: BOM-less UTF-16 is caught by the NUL-ratio heuristic (LE and BE)" {
    const gpa = std.testing.allocator;
    const le = try toUtf16(gpa, "id,name\n1,Ada\n2,Bo\n", true, false);
    defer gpa.free(le);
    var od = try openBytes(le);
    defer od.deinit();
    try expectEncoding(od.doc, api.encoding_utf16le, false);
    try expectDims(od.doc, 2, 2);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 1, "name");
    try expectCell(od.doc, 1, 1, "Bo");

    const be = try toUtf16(gpa, "id,name\n1,Ada\n2,Bo\n", false, false);
    defer gpa.free(be);
    var od2 = try openBytes(be);
    defer od2.deinit();
    try expectEncoding(od2.doc, api.encoding_utf16be, false);
    winAll(od2.doc);
    try expectCell(od2.doc, 0, 1, "Ada");
}

test "h4: a Latin-1 file auto-detects as ISO-8859-1 and transcodes to UTF-8" {
    var od = try openBytes("name,note\nAda,caf\xE9\n");
    defer od.deinit();
    try expectEncoding(od.doc, api.encoding_latin1, false);
    try std.testing.expectEqual(true, api.ls_dialect_get(od.doc).header);
    winAll(od.doc);
    try expectCell(od.doc, 0, 0, "Ada");
    try expectCell(od.doc, 0, 1, "caf\xC3\xA9"); // é as UTF-8 C3 A9
}

test "h5: head-only detection misses a late 8-bit byte; forcing ISO-8859-1 recovers" {
    const gpa = std.testing.allocator;
    // Header + fixed-width ASCII rows filling > head budget, then one final row
    // whose second cell holds a lone Latin-1 byte (0xE9) only AFTER the head.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "id,note\n");
    while (buf.items.len < api.open_head_max_bytes + 64 * 1024) {
        try buf.appendSlice(gpa, "aaaaaaa,bbbbbbb\n"); // 16 bytes each
    }
    try buf.appendSlice(gpa, "z,caf\xE9\n"); // the late 8-bit row

    // Automatic: the head is pure ASCII -> detected UTF-8 (documented limit).
    var od = try openBytes(buf.items);
    defer od.deinit();
    try expectEncoding(od.doc, api.encoding_utf8, false);

    // Forcing ISO-8859-1 re-reads the whole file correctly.
    var od2 = try openWith(buf.items, .{ .encoding = api.encoding_latin1, .index_mode = api.index_manual });
    defer od2.deinit();
    try expectEncoding(od2.doc, api.encoding_latin1, true);
    try scanToEnd(od2.doc);
    const rc = api.ls_row_count_get(od2.doc);
    try std.testing.expectEqual(true, rc.exact);
    const last = rc.count - 1;
    _ = api.ls_window_set(od2.doc, last, 1);
    try expectCell(od2.doc, last, 1, "caf\xC3\xA9");
}

test "h6: Windows-1252 smart quotes + undefined bytes; the same bytes as Latin-1" {
    const bytes = "a,b\n\x93q\x94,\x81\n";
    var od = try openWith(bytes, .{ .encoding = api.encoding_windows1252, .index_mode = api.index_manual });
    defer od.deinit();
    try expectEncoding(od.doc, api.encoding_windows1252, true);
    winAll(od.doc);
    try expectCell(od.doc, 0, 0, "\xE2\x80\x9Cq\xE2\x80\x9D"); // 0x93/0x94 -> “ ” (U+201C/201D)
    try expectCell(od.doc, 0, 1, "\xEF\xBF\xBD"); // 0x81 undefined -> U+FFFD

    // The same bytes decoded as Latin-1: 0x93 -> U+0093, 0x94 -> U+0094,
    // 0x81 -> U+0081 (C1 controls; UTF-8 two-byte C2 xx).
    var od2 = try openWith(bytes, .{ .encoding = api.encoding_latin1, .index_mode = api.index_manual });
    defer od2.deinit();
    winAll(od2.doc);
    try expectCell(od2.doc, 0, 0, "\xC2\x93q\xC2\x94");
    try expectCell(od2.doc, 0, 1, "\xC2\x81");
}

test "h7: UTF-8 is pass-through — BOM stripped, invalid bytes survive unchanged" {
    // Valid UTF-8 with a BOM: byte-identical to today, BOM absent, report UTF-8.
    var od = try openBytes("\xEF\xBB\xBFname,city\nJosé,42\n");
    defer od.deinit();
    try expectEncoding(od.doc, api.encoding_utf8, false);
    winAll(od.doc);
    try expectHeaderCell(od.doc, 0, "name");
    try expectCell(od.doc, 0, 0, "José");

    // An invalid UTF-8 byte on the UTF-8 path is served UNCHANGED (Option A —
    // the core never rewrites it to U+FFFD). Forced UTF-8 so it stays UTF-8.
    var od2 = try openWith("h\naa\xFFbb\n", .{ .encoding = api.encoding_utf8, .index_mode = api.index_manual });
    defer od2.deinit();
    try expectEncoding(od2.doc, api.encoding_utf8, true);
    winAll(od2.doc);
    try expectCell(od2.doc, 0, 0, "aa\xFFbb"); // raw 0xFF survives
}

test "h8: an out-of-domain encoding is a distinct usage error (file untouched)" {
    var fx = try makeFixture("a,b\n1,2\n", 0o644);
    defer fx.deinit();
    const bad = [_]i32{ -2, -3, 5, 6, 100, -100 };
    for (bad) |enc| {
        var doc: ?*api.Doc = null;
        const opts: api.OpenOptions = .{ .encoding = enc };
        try std.testing.expectEqual(api.Status.invalid_argument, api.ls_open(fx.path.ptr, &opts, &doc));
        try std.testing.expectEqual(@as(?*api.Doc, null), doc);
    }
    // ...and every value in the domain opens.
    const good = [_]i32{
        api.encoding_auto,      api.encoding_utf8,    api.encoding_utf16le,
        api.encoding_utf16be,   api.encoding_latin1,  api.encoding_windows1252,
    };
    for (good) |enc| {
        var doc: ?*api.Doc = null;
        const opts: api.OpenOptions = .{ .encoding = enc, .index_mode = api.index_manual };
        try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &opts, &doc));
        api.ls_close(doc.?);
    }
}

test "h9: detection + transcode read <= head budget (SOURCE bytes) per encoding" {
    const gpa = std.testing.allocator;
    const total: u64 = 1024 * 1024 * 1024; // 1 GiB sparse

    // Large Latin-1 file: opens fast, reports ISO-8859-1, reads <= head budget.
    {
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(gpa);
        try head.appendSlice(gpa, "id,note\n");
        var i: usize = 0;
        while (i < 4000) : (i += 1) try head.appendSlice(gpa, "1,caf\xE9\n");
        var fx = try makeSparseFixture(head.items, total);
        defer fx.deinit();
        const t0: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
        var doc: ?*api.Doc = null;
        try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &manual, &doc));
        defer api.ls_close(doc.?);
        try std.testing.expect(elapsedMs(t0) < 500); // never O(file)
        try expectEncoding(doc.?, api.encoding_latin1, false);
        const p = api.ls_index_poll(doc.?);
        try std.testing.expectEqual(total, p.bytes_total);
        try std.testing.expect(p.bytes_scanned <= api.open_head_max_bytes);
    }
    // Large UTF-16LE file (BOM): same source-byte bound.
    {
        const u16head = try toUtf16(gpa, "id,name\n1,Ada\n2,Bob\n", true, true);
        defer gpa.free(u16head);
        var fx = try makeSparseFixture(u16head, total);
        defer fx.deinit();
        const t0: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
        var doc: ?*api.Doc = null;
        try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &manual, &doc));
        defer api.ls_close(doc.?);
        try std.testing.expect(elapsedMs(t0) < 500);
        try expectEncoding(doc.?, api.encoding_utf16le, false);
        try std.testing.expect(api.ls_index_poll(doc.?).bytes_scanned <= api.open_head_max_bytes);
    }
}

test "h10: forced UTF-16 without a BOM decodes; a matching leading BOM is stripped" {
    const gpa = std.testing.allocator;
    // No BOM, forced LE.
    const le = try toUtf16(gpa, "a,b\nJosé,x\n", true, false);
    defer gpa.free(le);
    var od = try openWith(le, .{ .encoding = api.encoding_utf16le, .index_mode = api.index_manual });
    defer od.deinit();
    try expectEncoding(od.doc, api.encoding_utf16le, true);
    try expectDims(od.doc, 1, 2);
    winAll(od.doc);
    try expectCell(od.doc, 0, 0, "José");

    // A BOM matching the forced encoding is consumed (not a leading cell char).
    const le_bom = try toUtf16(gpa, "a,b\nx,y\n", true, true);
    defer gpa.free(le_bom);
    var od2 = try openWith(le_bom, .{ .encoding = api.encoding_utf16le, .index_mode = api.index_manual });
    defer od2.deinit();
    winAll(od2.doc);
    try expectHeaderCell(od2.doc, 0, "a"); // not "\u{FEFF}a"
}

test "h11: empty and BOM-only files open empty with a sensible reported encoding" {
    // Empty, automatic -> UTF-8.
    var od = try openBytes("");
    defer od.deinit();
    try expectDims(od.doc, 0, 0);
    try expectEncoding(od.doc, api.encoding_utf8, false);
    // Empty, forced Latin-1 -> the forced value is reported.
    var od2 = try openWith("", .{ .encoding = api.encoding_latin1, .index_mode = api.index_manual });
    defer od2.deinit();
    try expectDims(od2.doc, 0, 0);
    try expectEncoding(od2.doc, api.encoding_latin1, true);
    // UTF-16LE BOM-only -> empty document, encoding UTF-16 LE.
    var od3 = try openBytes("\xFF\xFE");
    defer od3.deinit();
    try expectDims(od3.doc, 0, 0);
    try expectEncoding(od3.doc, api.encoding_utf16le, false);
    // UTF-8 BOM-only -> empty document, UTF-8.
    var od4 = try openBytes("\xEF\xBB\xBF");
    defer od4.deinit();
    try expectDims(od4.doc, 0, 0);
    try expectEncoding(od4.doc, api.encoding_utf8, false);
}

test "h12: dialect/header/column outcomes are identical across encodings" {
    const gpa = std.testing.allocator;
    const logical = "name;age\nJosé;42\nBo;7\n"; // ';' delimited, header, accented

    var u8doc = try openBytes(logical);
    defer u8doc.deinit();
    const du8 = api.ls_dialect_get(u8doc.doc);
    try std.testing.expectEqual(@as(u8, ';'), du8.separator);
    try std.testing.expectEqual(true, du8.header);

    const le = try toUtf16(gpa, logical, true, true);
    defer gpa.free(le);
    var ledoc = try openBytes(le);
    defer ledoc.deinit();

    const latin = "name;age\nJos\xE9;42\nBo;7\n"; // é -> 0xE9
    var latindoc = try openWith(latin, .{ .encoding = api.encoding_latin1, .index_mode = api.index_manual });
    defer latindoc.deinit();

    inline for (.{ ledoc, latindoc }) |od| {
        const d = api.ls_dialect_get(od.doc);
        try std.testing.expectEqual(du8.separator, d.separator);
        try std.testing.expectEqual(du8.header, d.header);
        try std.testing.expectEqual(api.ls_column_count(u8doc.doc), api.ls_column_count(od.doc));
    }
    // The transcoded cells match the UTF-8 baseline exactly.
    winAll(u8doc.doc);
    winAll(ledoc.doc);
    winAll(latindoc.doc);
    try expectCell(u8doc.doc, 0, 0, "José");
    try expectCell(ledoc.doc, 0, 0, "José");
    try expectCell(latindoc.doc, 0, 0, "José");
}

// ---------------------------------------------------------------------------
// h13..h17 — the per-cell display cap, bounded record 1, search-over-full-cell.
// ---------------------------------------------------------------------------

test "h13: a cell over the display cap is served truncated at a code-point boundary" {
    const gpa = std.testing.allocator;
    // Data row 0, one column: 4095 'a', then a 2-byte 'é' straddling byte 4096,
    // then filler — the cap must cut BEFORE 'é' (largest boundary <= 4096 = 4095).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "h\n");
    var k: usize = 0;
    while (k < 4095) : (k += 1) try buf.append(gpa, 'a');
    try buf.appendSlice(gpa, "é"); // bytes at offsets 4095, 4096
    k = 0;
    while (k < 1000) : (k += 1) try buf.append(gpa, 'b');
    try buf.append(gpa, '\n');
    try buf.appendSlice(gpa, "small\n");

    var od = try openBytes(buf.items);
    defer od.deinit();
    try expectDims(od.doc, 2, 1);
    winAll(od.doc);

    const served = api.ls_cell(od.doc, 0, 0).slice();
    try std.testing.expect(served.len <= api.cell_max_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(served)); // never a split code point
    try std.testing.expectEqual(@as(usize, 4095), served.len); // cut before the 'é'
    for (served) |ch| try std.testing.expectEqual(@as(u8, 'a'), ch);
    try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, 0, 0));

    // A cell within the cap is served whole with the flag false.
    try expectCell(od.doc, 1, 0, "small");
    try std.testing.expectEqual(false, api.ls_cell_truncated(od.doc, 1, 0));
    // Out-of-window / out-of-range: false.
    try std.testing.expectEqual(false, api.ls_cell_truncated(od.doc, 99, 0));
    try std.testing.expectEqual(false, api.ls_cell_truncated(od.doc, 0, 9));
}

test "h13b: an oversized HEADER cell is capped and flagged too" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var k: usize = 0;
    while (k < 6000) : (k += 1) try buf.append(gpa, 'H'); // header cell > cap
    try buf.appendSlice(gpa, "\nx\n"); // one data row keeps the header a header
    var od = try openWith(buf.items, .{ .header = api.header_on, .index_mode = api.index_manual });
    defer od.deinit();
    winAll(od.doc);
    try std.testing.expect(api.ls_header_cell(od.doc, 0).slice().len <= api.cell_max_bytes);
    try std.testing.expectEqual(true, api.ls_header_cell_truncated(od.doc, 0));
    try std.testing.expectEqual(false, api.ls_header_cell_truncated(od.doc, 9)); // out of range
}

test "h14: an unterminated giant record 1 opens bounded, last field truncated+flagged" {
    const gpa = std.testing.allocator;
    // Record 1: field "a", then an unclosed quoted cell (no closing quote, no
    // newline) swallowing the rest for > head budget of source bytes. A 256 MiB
    // sparse tail makes an O(file) decode measurably slow — open must stay O(head).
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(gpa);
    try head.appendSlice(gpa, "a,\"");
    while (head.items.len < api.open_head_max_bytes + 256 * 1024) {
        try head.appendSlice(gpa, "bbbbbbbb");
    }
    const total: u64 = 256 * 1024 * 1024;
    var fx = try makeSparseFixture(head.items, total);
    defer fx.deinit();

    const t0: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    var doc: ?*api.Doc = null;
    const opts: api.OpenOptions = .{ .separator = ',', .quote = '"', .header = api.header_off, .index_mode = api.index_manual };
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &opts, &doc));
    defer api.ls_close(doc.?);
    try std.testing.expect(elapsedMs(t0) < 500); // O(head), not O(file)
    // Column count = the fields decoded within budget (the quote swallows all
    // separators, so exactly two: "a" and the giant unterminated field).
    try std.testing.expectEqual(@as(u32, 2), api.ls_column_count(doc.?));
    try std.testing.expect(api.ls_index_poll(doc.?).bytes_scanned <= api.open_head_max_bytes);

    _ = api.ls_window_set(doc.?, 0, 1);
    try expectCell(doc.?, 0, 0, "a");
    try std.testing.expectEqual(false, api.ls_cell_truncated(doc.?, 0, 0));
    // The in-progress final field is display-truncated and flagged.
    try std.testing.expect(api.ls_cell(doc.?, 0, 1).slice().len <= api.cell_max_bytes);
    try std.testing.expectEqual(true, api.ls_cell_truncated(doc.?, 0, 1));
}

test "h15: text search matches the FULL cell, past the display cap" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "h\n"); // header record
    var k: usize = 0;
    while (k < 5000) : (k += 1) try buf.append(gpa, 'a'); // > cap of filler
    try buf.appendSlice(gpa, "NEEDLE\n"); // the only match, past the 4 KiB cap

    var od = try openBytes(buf.items);
    defer od.deinit();
    // The match is found even though it lives past the served display bytes.
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, textReq("NEEDLE")));
    const s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 0, 1);
    // ...and that same served cell is capped + flagged (display-only).
    _ = api.ls_window_set(od.doc, 0, 1);
    try std.testing.expect(api.ls_cell(od.doc, 0, 0).slice().len <= api.cell_max_bytes);
    try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, 0, 0));
}

test "h16: predicate = compares the FULL cell, past the display cap" {
    const gpa = std.testing.allocator;
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    var k: usize = 0;
    while (k < 5000) : (k += 1) try big.append(gpa, 'z'); // > cap
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, big.items); // data row 0 (header off)
    try buf.append(gpa, '\n');
    try buf.appendSlice(gpa, "small\n"); // data row 1

    var od = try openWith(buf.items, .{ .header = api.header_off, .index_mode = api.index_manual });
    defer od.deinit();
    // = big matches ONLY the full-content row 0 (byte-exact over the WHOLE cell).
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, predReq(0, .eq, big.items)));
    const s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 0, 1);
    // A value equal only to the capped prefix must NOT match the full cell.
    try std.testing.expectEqual(@as(u64, 0), try searchTotal(od.doc, predReq(0, .eq, big.items[0..api.cell_max_bytes])));
    _ = api.ls_window_set(od.doc, 0, 1);
    try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, 0, 0));
}

test "h17: a window of oversized cells is per-cell bounded and window_set stays fast" {
    const gpa = std.testing.allocator;
    const cell = try gpa.alloc(u8, 8192); // 8 KiB per cell (2x the cap)
    defer gpa.free(cell);
    @memset(cell, 'a');
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var r: usize = 0;
    while (r < 200) : (r += 1) {
        try buf.appendSlice(gpa, cell);
        try buf.append(gpa, ',');
        try buf.appendSlice(gpa, cell);
        try buf.append(gpa, '\n');
    }
    var od = try openWith(buf.items, .{ .header = api.header_off, .separator = ',', .index_mode = api.index_manual });
    defer od.deinit();
    try scanToEnd(od.doc);

    const before = api.ls_index_poll(od.doc).bytes_scanned;
    const t0: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    const range = api.ls_window_set(od.doc, 0, 200);
    try std.testing.expect(elapsedMs(t0) < 100); // synchronous-fast: no scan, no full-file read
    try std.testing.expectEqual(@as(u64, 200), range.row_count);
    try std.testing.expectEqual(before, api.ls_index_poll(od.doc).bytes_scanned); // frontier untouched
    // Per-cell cap == the window memory bound (window <= rows*cols*cap).
    var i: u64 = 0;
    while (i < 200) : (i += 1) {
        try std.testing.expect(api.ls_cell(od.doc, i, 0).slice().len <= api.cell_max_bytes);
        try std.testing.expect(api.ls_cell(od.doc, i, 1).slice().len <= api.cell_max_bytes);
        try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, i, 0));
        try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, i, 1));
    }
}

// ---------------------------------------------------------------------------
// Public C ABI: csv-hardening constants + truncation symbols pinned to the
// header, callable through extern linkage (regression guard; green from seed).
// ---------------------------------------------------------------------------

const c_linked_csv = struct {
    extern fn ls_cell_truncated(doc: *const api.Doc, row: u64, col: u32) bool;
    extern fn ls_header_cell_truncated(doc: *const api.Doc, col: u32) bool;
};

test "abi: csv-hardening constants are pinned and truncation symbols link" {
    try std.testing.expectEqual(@as(i32, -1), api.encoding_auto);
    try std.testing.expectEqual(@as(u8, 0), api.encoding_utf8);
    try std.testing.expectEqual(@as(u8, 1), api.encoding_utf16le);
    try std.testing.expectEqual(@as(u8, 2), api.encoding_utf16be);
    try std.testing.expectEqual(@as(u8, 3), api.encoding_latin1);
    try std.testing.expectEqual(@as(u8, 4), api.encoding_windows1252);
    try std.testing.expectEqual(@as(usize, 4096), api.cell_max_bytes);

    var od = try openBytes("h\nsmall\n");
    defer od.deinit();
    winAll(od.doc);
    try std.testing.expectEqual(false, c_linked_csv.ls_cell_truncated(od.doc, 0, 0));
    try std.testing.expectEqual(false, c_linked_csv.ls_header_cell_truncated(od.doc, 0));
}

// ===========================================================================
// filtered-views slice (ARCH-filtered-views core criteria 1-15; app criteria
// 16-18 live in apps/macos). Frozen; planner-owned. Naming: fv<criterion>.
// Semantics are pinned in api/lesssheet.h FILTERED VIEWS (the filter view mode,
// the counters-not-lists memory bound, the shared scan slot, filtered
// coordinates for the row accessors / jump / find, source-row mapping, reset)
// and mirrored in contracts/api.zig. Tests exercise the PUBLIC C ABI through
// @import("api") only, reusing the helpers above (openBytes/openWith, expectCell,
// expectDims, winAll, startSearch/navAndWait/expectFound, genNeedleRows,
// ascending, BytesAllocator, ...). Determinism: the addressing fixture is far
// below the head budget (fully indexed at open, filter counts exact fast);
// scale tests use MANUAL mode where only scans drive the frontier, and the
// filter-scan runs to EOF on the core worker exactly like a match-scan.
// ===========================================================================

/// A fixture with matches interleaved among non-matches, header ON, 3 columns.
/// Data rows 0..7 (source row numbers in comments):
const fv_fixture =
    "name,qty,note\n" ++
    "Widget,2,alpha needle\n" ++ //   0: note has "needle";      qty 2
    "NEEDLE,10,beta\n" ++ //          1: name "NEEDLE";           qty 10
    "needle,2.0,gamma\n" ++ //        2: name "needle";           qty 2.0
    "gadget,-3,Needle point\n" ++ //  3: note "Needle";           qty -3
    "Gizmo,1e2,delta\n" ++ //         4: no "needle";             qty 1e2=100
    "café,0.5,CAFÉ\n" ++ //           5: no "needle";             qty 0.5
    ",5.,needleneedle\n" ++ //        6: note "needleneedle";     qty 5.
    "plain,abc,end needle\n"; //      7: note "end needle";       qty non-numeric

/// TEXT "needle" (smart-case fold) matches source rows 0,1,2,3,6,7 (m = 6).
/// WHERE qty(col 1) >= 2 matches source rows 0,1,2,4,6 (m = 5).

fn setFilter(doc: *api.Doc, req: api.SearchRequest) !void {
    try std.testing.expectEqual(true, api.ls_filter_set(doc, &req));
}

fn expectFilterRejected(doc: *api.Doc, req: api.SearchRequest) !void {
    try std.testing.expectEqual(false, api.ls_filter_set(doc, &req));
}

/// Poll the filter until DONE (<= 15 s); returns the snapshot. Errors on IDLE
/// (a set filter never polls IDLE), so an unimplemented seed fails at the
/// ls_filter_set assertion instead of hanging here.
fn waitFilterDone(doc: *api.Doc) !api.FilterStatus {
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        const s = api.ls_filter_poll(doc);
        if (s.state == .done) return s;
        if (s.state == .idle) return error.FilterNotSet;
        if (elapsedMs(t0) > 15_000) return error.FilterTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Materialize the full filtered view and assert filtered row i maps to
/// `sources[i]` (its gutter value), with the row one past the last not servable.
fn expectSourceRows(doc: *api.Doc, sources: []const u64) !void {
    _ = api.ls_window_set(doc, 0, api.window_max_rows);
    for (sources, 0..) |src, i| {
        try std.testing.expectEqual(src, api.ls_source_row(doc, @intCast(i)));
    }
    try std.testing.expectEqual(api.no_row, api.ls_source_row(doc, sources.len));
}

// --- fv1..fv6 — the filter view & addressing --------------------------------

test "fv1: with no filter the identity view is unchanged; filter poll IDLE; source_row is identity" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    // A fresh handle: no filter -> LS_FILTER_IDLE, all-zero snapshot.
    const f = api.ls_filter_poll(od.doc);
    try std.testing.expectEqual(api.FilterState.idle, f.state);
    try std.testing.expectEqual(@as(f64, 0.0), f.progress);
    try std.testing.expectEqual(@as(u64, 0), f.total);
    try std.testing.expectEqual(false, f.total_exact);
    // Identity accessors behave exactly as today (regression guard).
    try expectDims(od.doc, 8, 3);
    try std.testing.expectEqual(true, api.ls_dialect_get(od.doc).header);
    winAll(od.doc);
    try expectCell(od.doc, 0, 0, "Widget");
    try expectCell(od.doc, 3, 2, "Needle point");
    try expectHeaderCell(od.doc, 1, "qty");
    // ls_source_row is the identity on servable rows; sentinel past the range.
    try std.testing.expectEqual(@as(u64, 0), api.ls_source_row(od.doc, 0));
    try std.testing.expectEqual(@as(u64, 7), api.ls_source_row(od.doc, 7));
    try std.testing.expectEqual(api.no_row, api.ls_source_row(od.doc, 8));
}

test "fv2: a WHERE filter reports the matching count and serves the matching rows' cells in file order" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    try setFilter(od.doc, predReq(1, .ge, "2")); // qty >= 2 -> sources 0,1,2,4,6
    const f = try waitFilterDone(od.doc);
    try std.testing.expectEqual(@as(u64, 5), f.total);
    try std.testing.expectEqual(true, f.total_exact);
    try std.testing.expectEqual(@as(f64, 1.0), f.progress);
    // Row count reports m, exact.
    const rc = api.ls_row_count_get(od.doc);
    try std.testing.expectEqual(@as(u64, 5), rc.count);
    try std.testing.expectEqual(true, rc.exact);
    // A window over [0, m) serves the matching rows' cells in file order.
    const r = api.ls_window_set(od.doc, 0, api.window_max_rows);
    try std.testing.expectEqual(@as(u64, 5), r.row_count);
    try expectCell(od.doc, 0, 0, "Widget"); //       source 0
    try expectCell(od.doc, 1, 0, "NEEDLE"); //       source 1
    try expectCell(od.doc, 2, 1, "2.0"); //          source 2
    try expectCell(od.doc, 3, 0, "Gizmo"); //        source 4
    try expectCell(od.doc, 4, 2, "needleneedle"); // source 6
    // The header record is unaffected by the filter.
    try expectHeaderCell(od.doc, 0, "name");
    try expectSourceRows(od.doc, &.{ 0, 1, 2, 4, 6 });
}

test "fv3: a TEXT filter yields the substring-matching rows with Find's smart-case rule" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    // Lowercase query folds ASCII case: sources 0,1,2,3,6,7.
    try setFilter(od.doc, textReq("needle"));
    var f = try waitFilterDone(od.doc);
    try std.testing.expectEqual(@as(u64, 6), f.total);
    try expectSourceRows(od.doc, &.{ 0, 1, 2, 3, 6, 7 });
    // One ASCII uppercase byte -> byte-exact: only "NEEDLE" (source 1).
    try setFilter(od.doc, textReq("NEEDLE"));
    f = try waitFilterDone(od.doc);
    try std.testing.expectEqual(@as(u64, 1), f.total);
    try expectSourceRows(od.doc, &.{1});
    // Column scope excludes columns exactly: "needle" (fold) in the NAME column
    // (col 0) is sources 1 (NEEDLE) and 2 (needle); notes are ignored.
    try setFilter(od.doc, textReqScoped("needle", &.{0}));
    f = try waitFilterDone(od.doc);
    try std.testing.expectEqual(@as(u64, 2), f.total);
    try expectSourceRows(od.doc, &.{ 1, 2 });
}

test "fv4: clearing the filter restores the identity view" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    try setFilter(od.doc, textReq("needle"));
    _ = try waitFilterDone(od.doc);
    try std.testing.expectEqual(@as(u64, 6), api.ls_row_count_get(od.doc).count);
    // Clear -> identity view: full count, poll IDLE, row i == physical data row i.
    api.ls_filter_clear(od.doc);
    try std.testing.expectEqual(api.FilterState.idle, api.ls_filter_poll(od.doc).state);
    const rc = api.ls_row_count_get(od.doc);
    try std.testing.expectEqual(@as(u64, 8), rc.count);
    try std.testing.expectEqual(true, rc.exact);
    winAll(od.doc);
    try expectCell(od.doc, 3, 0, "gadget"); // physical data row 3 again
    try expectCell(od.doc, 4, 2, "delta");
    try std.testing.expectEqual(@as(u64, 4), api.ls_source_row(od.doc, 4)); // identity
}

test "fv5: an invalid filter request is rejected and leaves the current view unchanged" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    // Establish a filtered view (qty >= 2 -> 5 rows).
    try setFilter(od.doc, predReq(1, .ge, "2"));
    _ = try waitFilterDone(od.doc);
    try std.testing.expectEqual(@as(u64, 5), api.ls_row_count_get(od.doc).count);
    // Each invalid request is rejected (exactly as ls_search_start rejects it).
    try expectFilterRejected(od.doc, textReq("")); //               empty TEXT query
    try expectFilterRejected(od.doc, textReqScoped("x", &.{})); //  non-NULL empty scope
    try expectFilterRejected(od.doc, textReqScoped("x", &.{3})); // scope column out of range
    try expectFilterRejected(od.doc, predReq(9, .eq, "x")); //      column out of range
    try expectFilterRejected(od.doc, predReq(1, .lt, "abc")); //    non-numeric ordering value
    // The 5-row filtered view is unchanged after every rejection.
    try std.testing.expect(api.ls_filter_poll(od.doc).state != .idle);
    try std.testing.expectEqual(@as(u64, 5), api.ls_row_count_get(od.doc).count);
    try expectSourceRows(od.doc, &.{ 0, 1, 2, 4, 6 });
}

test "fv6: a filter that matches nothing yields a filtered view of exactly 0 rows" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    try setFilter(od.doc, textReq("zzz-no-such-substring"));
    const f = try waitFilterDone(od.doc);
    try std.testing.expectEqual(@as(u64, 0), f.total);
    try std.testing.expectEqual(true, f.total_exact);
    const rc = api.ls_row_count_get(od.doc);
    try std.testing.expectEqual(@as(u64, 0), rc.count);
    try std.testing.expectEqual(true, rc.exact);
    // No rows servable; ls_source_row(0) is the sentinel.
    const r = api.ls_window_set(od.doc, 0, api.window_max_rows);
    try std.testing.expectEqual(@as(u64, 0), r.row_count);
    try std.testing.expectEqual(api.no_row, api.ls_source_row(od.doc, 0));
}

// --- fv7..fv10 — scan, progress, memory, the shared slot --------------------

test "fv7: the filter-scan is scanning with monotone progress until done, then an exact total" {
    const gpa = std.testing.allocator;
    // Row 290,000 is well beyond any MANUAL open frontier: the filter-scan must
    // advance the shared frontier to count it.
    const fixture = try genNeedleRows(gpa, 300_000, &.{ 100, 150_000, 290_000 });
    defer gpa.free(fixture);
    var od = try openWith(fixture, manualNoHeader);
    defer od.deinit();
    try setFilter(od.doc, textReq("needle"));
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    var last_progress: f64 = 0.0;
    var last_total: u64 = 0;
    while (true) {
        const s = api.ls_filter_poll(od.doc);
        try std.testing.expect(s.state != .idle); // a set filter is never IDLE
        try std.testing.expect(s.progress >= 0.0 and s.progress <= 1.0);
        try std.testing.expect(s.progress >= last_progress); // monotone
        try std.testing.expect(s.total >= last_total); // monotone
        try std.testing.expect(api.ls_row_count_get(od.doc).count >= s.total);
        last_progress = s.progress;
        last_total = s.total;
        if (s.state == .done) {
            try std.testing.expectEqual(@as(f64, 1.0), s.progress);
            try std.testing.expectEqual(@as(u64, 3), s.total);
            try std.testing.expectEqual(true, s.total_exact);
            const rc = api.ls_row_count_get(od.doc);
            try std.testing.expectEqual(@as(u64, 3), rc.count);
            try std.testing.expectEqual(true, rc.exact);
            break;
        }
        if (elapsedMs(t0) > 15_000) return error.FilterTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    // All three matches are servable, in filtered coordinates.
    try expectSourceRows(od.doc, &.{ 100, 150_000, 290_000 });
}

test "fv8: filter counter storage is O(checkpoints) — independent of the match count" {
    const gpa = std.testing.allocator;
    const n: u64 = 200_000; // 3.6 MB: fully indexed at open, so the deltas below
    // measure FILTER allocations only.
    const sparse_rows = try ascending(gpa, n, 20_000); // 10 matches
    defer gpa.free(sparse_rows);
    const dense_rows = try ascending(gpa, n, 1); // every row matches
    defer gpa.free(dense_rows);
    const sets = [2][]const u64{ sparse_rows, dense_rows };
    const expected = [2]u64{ 10, n };
    var deltas: [2]u64 = undefined;
    for (sets, 0..) |match_set, idx| {
        const fixture = try genNeedleRows(gpa, n, match_set);
        defer gpa.free(fixture);
        var fx = try makeFixture(fixture, 0o644);
        defer fx.deinit();
        var tracking: BytesAllocator = .{ .parent = std.testing.allocator };
        var doc_opt: ?*api.Doc = null;
        try std.testing.expectEqual(api.Status.ok, api.openWithAllocator(tracking.allocator(), fx.path.ptr, &manualNoHeader, &doc_opt));
        const doc = doc_opt.?;
        defer api.ls_close(doc);
        const before = tracking.bytes.load(.monotonic);
        try setFilter(doc, textReq("needle"));
        const s = try waitFilterDone(doc);
        try std.testing.expectEqual(expected[idx], s.total);
        deltas[idx] = tracking.bytes.load(.monotonic) - before;
    }
    // A materialized match-row list would grow the dense filter by ~200k
    // entries (>= 1.6 MB); per-block counters are identical for both layouts.
    try std.testing.expect(deltas[1] <= deltas[0] + 64 * 1024);
}

test "fv9: the filter-scan feeds the base row index — after it completes the index is complete" {
    const gpa = std.testing.allocator;
    const fixture = try genNeedleRows(gpa, 300_000, &.{ 5, 290_000 });
    defer gpa.free(fixture);
    var od = try openWith(fixture, manualNoHeader); // MANUAL: only scans advance the frontier
    defer od.deinit();
    try std.testing.expectEqual(false, api.ls_index_poll(od.doc).complete); // head only, so far
    try setFilter(od.doc, textReq("needle"));
    _ = try waitFilterDone(od.doc);
    // Bytes scanned for the filter also indexed the document (paid once).
    const p = api.ls_index_poll(od.doc);
    try std.testing.expectEqual(true, p.complete);
    try std.testing.expectEqual(p.bytes_total, p.bytes_scanned);
    // The base (unfiltered) row count is exact once the filter is cleared.
    api.ls_filter_clear(od.doc);
    const rc = api.ls_row_count_get(od.doc);
    try std.testing.expectEqual(@as(u64, 300_000), rc.count);
    try std.testing.expectEqual(true, rc.exact);
}

test "fv10: filter and jump share the scan slot — a jump takes it, gains kept, the mode persists" {
    const gpa = std.testing.allocator;
    const fixture = try genNeedleRows(gpa, 2_000_000, &.{ 5, 1_000_000, 1_999_990 });
    defer gpa.free(fixture);
    var od = try openWith(fixture, manualNoHeader);
    defer od.deinit();
    try setFilter(od.doc, textReq("needle"));
    // Let the filter-scan count at least the first match.
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (api.ls_filter_poll(od.doc).total < 1) {
        if (elapsedMs(t0) > 15_000) return error.FilterTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    const mid = api.ls_filter_poll(od.doc);
    // A jump that must scan (far target) engages the slot.
    api.ls_jump_start(od.doc, 1_900_000);
    const after = api.ls_filter_poll(od.doc);
    // The filter MODE persists (never IDLE); the match frontier never regresses.
    try std.testing.expect(after.state != .idle);
    try std.testing.expect(after.total >= mid.total);
    try std.testing.expect(after.progress >= mid.progress);
    // Rows already counted behind the filter frontier stay servable.
    const r = api.ls_window_set(od.doc, 0, 1);
    try std.testing.expectEqual(@as(u64, 1), r.row_count);
    try std.testing.expectEqual(@as(u64, 5), api.ls_source_row(od.doc, 0)); // first match's source
    _ = try waitJumpDone(od.doc);
    // The filter mode survived the whole exchange (fv12 pins the filtered landing).
    try std.testing.expect(api.ls_filter_poll(od.doc).state != .idle);
}

// --- fv11..fv13 — source rows, jump, clear re-anchor ------------------------

test "fv11: each served filtered row reports its correct original data-row number" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    try setFilter(od.doc, textReq("needle")); // sources 0,1,2,3,6,7
    _ = try waitFilterDone(od.doc);
    _ = api.ls_window_set(od.doc, 0, api.window_max_rows);
    const expected = [_]u64{ 0, 1, 2, 3, 6, 7 };
    for (expected, 0..) |src, i| {
        try std.testing.expectEqual(src, api.ls_source_row(od.doc, @intCast(i)));
    }
    try std.testing.expectEqual(api.no_row, api.ls_source_row(od.doc, expected.len)); // past range
    // Same window/borrow domain as ls_cell: a narrower window makes rows outside
    // it unservable (LS_NO_ROW), and the in-window rows still map correctly.
    const r = api.ls_window_set(od.doc, 2, 2); // filtered rows 2,3 -> sources 2,3
    try std.testing.expectEqual(@as(u64, 2), r.row_count);
    try std.testing.expectEqual(@as(u64, 2), api.ls_source_row(od.doc, 2));
    try std.testing.expectEqual(@as(u64, 3), api.ls_source_row(od.doc, 3));
    try std.testing.expectEqual(api.no_row, api.ls_source_row(od.doc, 0)); // now out of window
}

test "fv12: jump under a filter takes an original row number and lands on the nearest match at-or-after it" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    try setFilter(od.doc, textReq("needle")); // sources 0,1,2,3,6,7 -> filtered 0..5
    _ = try waitFilterDone(od.doc);
    // go to original row 4 -> nearest match >= 4 is source 6 = filtered index 4.
    api.ls_jump_start(od.doc, 4);
    var jd = try waitJumpDone(od.doc);
    try std.testing.expectEqual(@as(u64, 4), jd.landed_row); // FILTERED index
    _ = api.ls_window_set(od.doc, jd.landed_row, 1);
    try std.testing.expectEqual(@as(u64, 6), api.ls_source_row(od.doc, jd.landed_row)); // gutter >= 4
    // go to original row 3 -> exact match at source 3 = filtered index 3.
    api.ls_jump_start(od.doc, 3);
    jd = try waitJumpDone(od.doc);
    try std.testing.expectEqual(@as(u64, 3), jd.landed_row);
    // go past EOF -> clamp to the last match: source 7 = filtered index 5.
    api.ls_jump_start(od.doc, 1_000_000);
    jd = try waitJumpDone(od.doc);
    try std.testing.expectEqual(@as(u64, 5), jd.landed_row);
    _ = api.ls_window_set(od.doc, jd.landed_row, 1);
    try std.testing.expectEqual(@as(u64, 7), api.ls_source_row(od.doc, jd.landed_row));
}

test "fv13: clearing re-anchors via the source row of the top visible filtered row" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    try setFilter(od.doc, textReq("needle"));
    _ = try waitFilterDone(od.doc);
    // Viewport top at filtered row 4 (source row 6): capture its source row.
    _ = api.ls_window_set(od.doc, 4, 2);
    const anchor = api.ls_source_row(od.doc, 4);
    try std.testing.expectEqual(@as(u64, 6), anchor);
    // Clear, then the captured source row is directly addressable in identity.
    api.ls_filter_clear(od.doc);
    const r = api.ls_window_set(od.doc, anchor, 1);
    try std.testing.expectEqual(@as(u64, 1), r.row_count);
    try expectCell(od.doc, anchor, 2, "needleneedle"); // physical data row 6, note col
    try std.testing.expectEqual(anchor, api.ls_source_row(od.doc, anchor)); // identity again
}

// --- fv14..fv15 — find within a filter; reset semantics ---------------------

test "fv14: find within a filter matches only filtered rows; counts/positions/nav are filtered" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    // Filter: qty >= 2 -> source rows 0,1,2,4,6 (filtered 0..4).
    try setFilter(od.doc, predReq(1, .ge, "2"));
    _ = try waitFilterDone(od.doc);
    // Find "needle" WITHIN the filter: filtered rows whose cells contain it are
    // filtered 0 (src 0), 1 (src 1), 2 (src 2), 4 (src 6); filtered 3 (src 4,
    // "Gizmo") does not -> total within the filter = 4.
    try startSearch(od.doc, textReq("needle"));
    const done = try waitSearchDone(od.doc);
    try std.testing.expectEqual(@as(u64, 4), done.total);
    try std.testing.expectEqual(true, done.total_exact);
    // found_row is a FILTERED index; navigation stays within the filtered view;
    // the position (n of m) counts rows satisfying BOTH predicates.
    var s = try navAndWait(od.doc, 0, .forward);
    try expectFound(s, 0, 2, 1); // filtered 0 (src 0), "alpha needle" col 2
    s = try navAndWait(od.doc, 1, .forward);
    try expectFound(s, 1, 0, 2); // filtered 1 (src 1), "NEEDLE" col 0
    s = try navAndWait(od.doc, 2, .forward);
    try expectFound(s, 2, 0, 3); // filtered 2 (src 2), "needle" col 0
    s = try navAndWait(od.doc, 3, .forward);
    try expectFound(s, 4, 2, 4); // skips filtered 3 (no match); filtered 4 (src 6) col 2
    s = try navAndWait(od.doc, 5, .forward);
    try std.testing.expectEqual(api.SearchNavState.exhausted, s.nav);
    // The found filtered row maps back to its source row for the gutter.
    _ = api.ls_window_set(od.doc, 4, 1);
    try std.testing.expectEqual(@as(u64, 6), api.ls_source_row(od.doc, 4));
}

test "fv15: setting/clearing a filter resets an active find; a re-open clears the filter" {
    var fx = try makeFixture(fv_fixture, 0o644);
    defer fx.deinit();
    var doc_opt: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &manual, &doc_opt));
    var doc = doc_opt.?;
    // A find in the identity view...
    try startSearch(doc, textReq("needle"));
    _ = try waitSearchDone(doc);
    try std.testing.expect(api.ls_search_poll(doc).state != .idle);
    // ...is RESET when a filter is set (the coordinate space changed).
    try setFilter(doc, predReq(1, .ge, "2"));
    try std.testing.expectEqual(api.SearchState.idle, api.ls_search_poll(doc).state);
    // A find within the filter, then CLEARING the filter, resets it again.
    try startSearch(doc, textReq("needle"));
    _ = try waitSearchDone(doc);
    api.ls_filter_clear(doc);
    try std.testing.expectEqual(api.SearchState.idle, api.ls_search_poll(doc).state);
    // Set a filter, then a dialect re-open clears BOTH the filter and the search.
    try setFilter(doc, predReq(1, .ge, "2"));
    _ = try waitFilterDone(doc);
    api.ls_close(doc);
    const opts: api.OpenOptions = .{ .header = api.header_off, .index_mode = api.index_manual };
    doc_opt = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &opts, &doc_opt));
    doc = doc_opt.?;
    defer api.ls_close(doc);
    try std.testing.expectEqual(api.FilterState.idle, api.ls_filter_poll(doc).state);
    try std.testing.expectEqual(api.SearchState.idle, api.ls_search_poll(doc).state);
}

// ---------------------------------------------------------------------------
// Public C ABI: the filter symbols are callable through extern linkage, and the
// enum values / sentinel are pinned to the header (regression guard; the seed
// links and reports IDLE, so this stays green from the seed).
// ---------------------------------------------------------------------------

const c_linked_filter = struct {
    extern fn ls_filter_set(doc: *api.Doc, request: *const api.SearchRequest) bool;
    extern fn ls_filter_clear(doc: *api.Doc) void;
    extern fn ls_filter_poll(doc: *const api.Doc) api.FilterStatus;
    extern fn ls_source_row(doc: *const api.Doc, row: u64) u64;
};

test "abi: the filter C symbols are callable through extern linkage; enum values pinned" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.FilterState.idle));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.FilterState.scanning));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(api.FilterState.done));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(api.FilterState.cancelled));
    try std.testing.expectEqual(std.math.maxInt(u64), api.no_row);

    var od = try openBytes(fv_fixture);
    defer od.deinit();
    const req = textReq("needle");
    _ = c_linked_filter.ls_filter_set(od.doc, &req);
    _ = c_linked_filter.ls_filter_poll(od.doc);
    winAll(od.doc);
    _ = c_linked_filter.ls_source_row(od.doc, 0);
    c_linked_filter.ls_filter_clear(od.doc);
    try std.testing.expectEqual(api.FilterState.idle, c_linked_filter.ls_filter_poll(od.doc).state);
}

// ===========================================================================
// huge-row-budget slice (ARCH-huge-row-budget). Frozen; planner-owned. Bounds
// the SYNCHRONOUS window scan (ls_window_set) to LS_WINDOW_ROW_SCAN_MAX_BYTES
// per row so a huge row/cell can never block the caller (UI) thread: such a row
// is served as a bounded PREFIX and flagged by the NEW per-row ls_row_oversized
// (window/borrow domain identical to ls_source_row). Semantics pinned in
// api/lesssheet.h (the LS_WINDOW_ROW_SCAN_MAX_BYTES comment, ls_row_oversized,
// the re-qualified ls_window_set cost) and mirrored in contracts/api.zig.
// Naming: hr<criterion>, mapping ARCH acceptance 3-6.
//
// NOTE on the PRIMARY criteria (1-2, the <100 ms landing on sparse5g / big2g):
// those are WALL-CLOCK, environment-sensitive, and multi-GB — a FRONTEND probe
// (the sparse5g jump proxy in the ARCH regression loop), NOT a Zig unit test.
// These fixtures put the huge row just OVER the cap (~1.1 MiB) so the RED seed
// still materializes them in ~1 ms; the tests pin CORRECTNESS + the oversized
// flag, not wall-clock. The no-re-scan guarantee (criterion 4 / checkpoint-
// after-oversized) is pinned here only as far as a unit test can: a window
// positioned after the huge row must serve the correct cells (which, once the
// window scan is bounded, is possible ONLY via a checkpoint dropped after the
// oversized row); the timing half is the same frontend probe.
// ---------------------------------------------------------------------------

/// A source span comfortably OVER the per-row window scan cap, yet small enough
/// that the whole fixture is ~1.1 MiB (see the NOTE above).
const hr_over_cap_bytes: usize = @intCast(api.window_row_scan_max_bytes + 64 * 1024);

/// Build a 2-column (header "a,b") document: `before` small rows, then ONE huge
/// row whose SOURCE extent exceeds LS_WINDOW_ROW_SCAN_MAX_BYTES (first cell is
/// `hr_over_cap_bytes` of 'X', second cell "TAIL"), then `after` small rows.
/// Every non-huge data row `i` is exactly "a{i},b{i}". Returns the bytes (caller
/// frees) and the 0-based data-row index of the huge row (== `before`). The
/// fixture stays < LS_OPEN_HEAD_MAX_BYTES, so it is fully indexed by open (exact
/// count) and the huge row is behind the frontier immediately.
fn genHugeRowDoc(gpa: std.mem.Allocator, before: usize, after: usize) !struct { bytes: []u8, huge_row: u64 } {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var line: [32]u8 = undefined;
    try buf.appendSlice(gpa, "a,b\n"); // texty record 1 -> header
    var i: usize = 0;
    while (i < before) : (i += 1) {
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&line, "a{d},b{d}\n", .{ i, i }));
    }
    const blob = try gpa.alloc(u8, hr_over_cap_bytes);
    defer gpa.free(blob);
    @memset(blob, 'X');
    try buf.appendSlice(gpa, blob); // the huge row's first cell (> the scan cap)
    try buf.appendSlice(gpa, ",TAIL\n");
    i = 0;
    while (i < after) : (i += 1) {
        const r = before + 1 + i;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&line, "a{d},b{d}\n", .{ r, r }));
    }
    return .{ .bytes = try buf.toOwnedSlice(gpa), .huge_row = @intCast(before) };
}

test "hr3-served: an oversized row is a bounded prefix + flagged; rows before it are whole (ARCH 3)" {
    const gpa = std.testing.allocator;
    const doc = try genHugeRowDoc(gpa, 3, 0); // rows 0,1,2 small; row 3 huge
    defer gpa.free(doc.bytes);
    var od = try openBytes(doc.bytes);
    defer od.deinit();
    try expectDims(od.doc, 4, 2); // fully indexed at open

    const r = api.ls_window_set(od.doc, 0, 16);
    try std.testing.expectEqual(@as(u64, 4), r.row_count);
    // Rows BEFORE the huge row: full content, NOT oversized.
    var buf: [16]u8 = undefined;
    var i: u64 = 0;
    while (i < doc.huge_row) : (i += 1) {
        try expectCell(od.doc, i, 0, try std.fmt.bufPrint(&buf, "a{d}", .{i}));
        try expectCell(od.doc, i, 1, try std.fmt.bufPrint(&buf, "b{d}", .{i}));
        try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, i));
    }
    // The huge row: served as a bounded prefix — its visible cell obeys the
    // per-cell display cap (unchanged) and the row is FLAGGED oversized.
    try std.testing.expect(api.ls_cell(od.doc, doc.huge_row, 0).slice().len <= api.cell_max_bytes);
    try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, doc.huge_row, 0));
    try std.testing.expectEqual(true, api.ls_row_oversized(od.doc, doc.huge_row));
    // Total function: out-of-window / out-of-range rows are never oversized.
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, 999));
}

test "hr4-reach: a window after an oversized row serves correct cells; the huge row is flagged (ARCH 4)" {
    const gpa = std.testing.allocator;
    const doc = try genHugeRowDoc(gpa, 2, 3); // rows 0,1 small; row 2 huge; rows 3,4,5 small
    defer gpa.free(doc.bytes);
    var od = try openBytes(doc.bytes);
    defer od.deinit();
    try expectDims(od.doc, 6, 2);

    // Reaching rows AFTER the huge row serves their EXACT cells. Once the
    // synchronous window scan is bounded to the cap, this is possible only via
    // a checkpoint dropped after the oversized row (ARCH decision 2); we pin
    // correctness here, the <100 ms no-rescan half is the frontend probe.
    const after0 = doc.huge_row + 1;
    var buf: [16]u8 = undefined;
    const ra = api.ls_window_set(od.doc, after0, 8);
    try std.testing.expectEqual(@as(u64, 3), ra.row_count);
    var i: u64 = after0;
    while (i < 6) : (i += 1) {
        try expectCell(od.doc, i, 0, try std.fmt.bufPrint(&buf, "a{d}", .{i}));
        try expectCell(od.doc, i, 1, try std.fmt.bufPrint(&buf, "b{d}", .{i}));
        try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, i));
    }
    // A window SPANNING [huge, after]: the huge row is flagged oversized and the
    // rows after it are still served correctly in the SAME window.
    const rs = api.ls_window_set(od.doc, doc.huge_row, 4);
    try std.testing.expectEqual(@as(u64, 4), rs.row_count);
    try std.testing.expectEqual(true, api.ls_row_oversized(od.doc, doc.huge_row));
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, doc.huge_row + 1));
    try expectCell(od.doc, doc.huge_row + 1, 0, try std.fmt.bufPrint(&buf, "a{d}", .{doc.huge_row + 1}));
}

test "hr6-fullcell: search AND filter still match the FULL cell past the window scan cap (ARCH 6)" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "h\n"); // header (single column)
    const blob = try gpa.alloc(u8, hr_over_cap_bytes);
    defer gpa.free(blob);
    @memset(blob, 'a');
    try buf.appendSlice(gpa, blob); // > the per-row window scan cap of filler
    try buf.appendSlice(gpa, "NEEDLE\n"); // the ONLY match, past BOTH caps

    var od = try openBytes(buf.items);
    defer od.deinit();
    // Data row 0 (the giant cell) is served oversized + display-capped.
    _ = api.ls_window_set(od.doc, 0, 1);
    try std.testing.expect(api.ls_cell(od.doc, 0, 0).slice().len <= api.cell_max_bytes);
    try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, 0, 0));
    try std.testing.expectEqual(true, api.ls_row_oversized(od.doc, 0));
    // SEARCH scans the WHOLE cell (never the scan cap): the match past the cap
    // is still counted and navigable — the window bound must NOT touch search.
    try std.testing.expectEqual(@as(u64, 1), try searchTotal(od.doc, textReq("NEEDLE")));
    try expectFound(try navAndWait(od.doc, 0, .forward), 0, 0, 1);
    // FILTER (same match machinery) also matches past the cap: 1 matching row.
    try setFilter(od.doc, textReq("NEEDLE"));
    try std.testing.expectEqual(@as(u64, 1), (try waitFilterDone(od.doc)).total);
}

test "hr5-count: an oversized row counts as exactly one row; the frontier is unaffected (ARCH 5)" {
    const gpa = std.testing.allocator;
    const doc = try genHugeRowDoc(gpa, 4, 4); // 4 + 1 huge + 4 = 9 data rows
    defer gpa.free(doc.bytes);
    var od = try openBytes(doc.bytes);
    defer od.deinit();
    // The huge row is ONE row: 9 data rows exact, and the frontier covers the
    // whole file (bytes_scanned == file size, complete) — the count/estimate
    // machinery is untouched by the window-side cap.
    try expectDims(od.doc, 9, 2);
    const p = api.ls_index_poll(od.doc);
    try std.testing.expectEqual(true, p.complete);
    try std.testing.expectEqual(p.bytes_total, p.bytes_scanned);
    // Feature tie (RED on the seed): the huge row IS flagged when materialized,
    // and it is still counted as exactly one.
    _ = api.ls_window_set(od.doc, 0, api.window_max_rows);
    try std.testing.expectEqual(true, api.ls_row_oversized(od.doc, doc.huge_row));
    try std.testing.expectEqual(@as(u64, 9), api.ls_row_count_get(od.doc).count);
}

// ---------------------------------------------------------------------------
// Public C ABI: the constant + ls_row_oversized are pinned to the header and
// callable through extern linkage (regression/linkage guard; the seed links and
// reports false, so this stays green from the seed).
// ---------------------------------------------------------------------------

const c_linked_hugerow = struct {
    extern fn ls_row_oversized(doc: *const api.Doc, row: u64) bool;
};

test "abi: LS_WINDOW_ROW_SCAN_MAX_BYTES is pinned and ls_row_oversized links" {
    try std.testing.expectEqual(@as(u64, 1024 * 1024), api.window_row_scan_max_bytes);
    var od = try openBytes("h\nsmall\n");
    defer od.deinit();
    winAll(od.doc);
    try std.testing.expectEqual(false, c_linked_hugerow.ls_row_oversized(od.doc, 0));
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, 0)); // normal row
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, 999)); // out of range
}

// ===========================================================================
// huge-row-FILTERED slice (ARCH-huge-row-filtered). Frozen; planner-owned.
// Extends the huge-row-budget WINDOW bound to the FILTERED view path: a filtered
// view materialize landing on / crossing a giant row (source extent >
// LS_WINDOW_ROW_SCAN_MAX_BYTES) must be O(budget), NOT O(giant-row bytes) --
// WITHOUT changing filter MATCHING semantics. Matching stays FULL-cell and is
// decided by the BACKGROUND filter-scan (ls_filter_set, cap = null); the
// synchronous ls_window_set path must NOT re-decide a row's match by scanning it
// in the foreground. A giant MATCHING filtered row is served exactly like the
// identity path: a bounded PREFIX (each cell <= LS_CELL_MAX_BYTES; columns past
// the per-row scan cap padded to "") with ls_row_oversized(filtered_index) TRUE.
//
// Contract basis (NO new api/ surface -- the giant rows' recorded match results
// stay backend-internal, never crossing the ABI): the FUNCTION-LEVEL ls_window_set
// contract in api/lesssheet.h already promises "never scans past the per-row cap
// ... safe to call on the UI thread for ANY row size" and applies IN EITHER VIEW
// (FILTERED VIEWS: "ls_window_set never scans, in either view"); ls_row_oversized
// is already defined over a FILTERED index while a filter is active. This feature
// makes the FILTERED path deliver that already-frozen promise.
//
// Naming: hrf<n>, mapping ARCH acceptance 1-4. Like the identity hr* tests, the
// fixtures put the giant row just OVER the cap (~1.1 MiB, reusing hr_over_cap_bytes)
// so the RED seed (windowSetFiltered still re-lexes unbounded and never flags a
// filtered row oversized) still materializes them in ~1 ms: the tests pin
// CORRECTNESS + the oversized flag + the BOUND (a column past the per-row scan cap
// is served "", proving the giant row was NOT fully re-lexed) -- never wall-clock.
// The <100 ms landing is the same frontend probe as the identity path (criterion 1).
// ---------------------------------------------------------------------------

/// Append ONE giant data row to `buf`: its FIRST cell is `hr_over_cap_bytes` of
/// filler, so its SECOND cell (col 1) lies entirely PAST the per-row window scan
/// cap. `needle_in_prefix` = the filler is preceded by "needle", so the giant row
/// matches a "needle" filter within its VISIBLE (display-capped) prefix; otherwise
/// the filler is pure 'X' and the row's ONLY "needle" is its col-1 TAIL -- a
/// full-cell match the BACKGROUND filter-scan finds but a bounded foreground
/// prefix cannot (the tail-match crux, ARCH criterion 2).
fn appendGiantRow(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), needle_in_prefix: bool) !void {
    const blob = try gpa.alloc(u8, hr_over_cap_bytes);
    defer gpa.free(blob);
    @memset(blob, 'X');
    if (needle_in_prefix) try buf.appendSlice(gpa, "needle");
    try buf.appendSlice(gpa, blob);
    try buf.appendSlice(gpa, if (needle_in_prefix) ",TAIL\n" else ",needle\n");
}

test "hrf1-bounded: a filtered window crossing a giant MATCHING row serves it as a bounded prefix + flag; rows before/after whole (ARCH 1,4)" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "k,v\n"); //        texty record 1 -> header, 2 columns
    try buf.appendSlice(gpa, "m0,needle\n"); //  source 0: match (normal)
    try buf.appendSlice(gpa, "x1,plain\n"); //   source 1: no match
    try appendGiantRow(gpa, &buf, true); //      source 2: GIANT, matches in its prefix
    try buf.appendSlice(gpa, "x3,plain\n"); //   source 3: no match
    try buf.appendSlice(gpa, "m4,needle\n"); //  source 4: match (normal)

    var od = try openBytes(buf.items);
    defer od.deinit();
    try setFilter(od.doc, textReq("needle")); // sources 0,2,4 -> filtered 0,1,2
    const f = try waitFilterDone(od.doc);
    try std.testing.expectEqual(@as(u64, 3), f.total); // the giant row counted full-cell

    // ONE materialize spanning the giant row (filtered index 1) -- the O(budget)
    // crossing (ARCH criterion 1). The RED seed re-lexes the giant row unbounded.
    const r = api.ls_window_set(od.doc, 0, api.window_max_rows);
    try std.testing.expectEqual(@as(u64, 3), r.row_count);
    // filtered 0 == source 0: a NORMAL matching row, served whole, NOT oversized.
    try std.testing.expectEqual(@as(u64, 0), api.ls_source_row(od.doc, 0));
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, 0));
    try expectCell(od.doc, 0, 1, "needle");
    // filtered 1 == source 2: the GIANT matching row, served as a BOUNDED PREFIX
    // (ARCH criterion 4). Its visible cell obeys the per-cell display cap and the
    // row is FLAGGED oversized in FILTERED coordinates.
    try std.testing.expectEqual(@as(u64, 2), api.ls_source_row(od.doc, 1));
    try std.testing.expectEqual(true, api.ls_row_oversized(od.doc, 1)); // RED on seed
    try std.testing.expect(api.ls_cell(od.doc, 1, 0).slice().len <= api.cell_max_bytes);
    try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, 1, 0));
    // col 1 lies past the per-row scan cap -> padded to "": proves the giant row
    // was NOT fully re-lexed (the RED seed reaches the tail and serves "TAIL").
    try expectCell(od.doc, 1, 1, ""); // RED on seed
    // filtered 2 == source 4: the row AFTER the giant one, served whole -- reached
    // via the checkpoint dropped after the oversized row, not by re-scanning it.
    try std.testing.expectEqual(@as(u64, 4), api.ls_source_row(od.doc, 2));
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, 2));
    try expectCell(od.doc, 2, 1, "needle");
}

test "hrf2-tailmatch: a giant row matching only in its TAIL (past the cap) still appears in the filtered view, served bounded (ARCH 1,2)" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "k,v\n"); //        header, 2 columns
    try buf.appendSlice(gpa, "m0,needle\n"); //  source 0: match (normal)
    try appendGiantRow(gpa, &buf, false); //     source 1: GIANT, matches ONLY via its col-1 tail
    try buf.appendSlice(gpa, "m2,needle\n"); //  source 2: match (normal)

    var od = try openBytes(buf.items);
    defer od.deinit();
    try setFilter(od.doc, textReq("needle")); // FULL-cell match -> sources 0,1,2
    const f = try waitFilterDone(od.doc);
    // Criterion 2: the giant row is counted because the BACKGROUND scan matched
    // its FULL cell (the needle past the 1 MiB cap) -- never decided on a prefix.
    try std.testing.expectEqual(@as(u64, 3), f.total);
    try std.testing.expectEqual(@as(u64, 3), api.ls_row_count_get(od.doc).count);

    const r = api.ls_window_set(od.doc, 0, api.window_max_rows);
    try std.testing.expectEqual(@as(u64, 3), r.row_count);
    // The giant row IS present at filtered index 1 (source 1): the window path
    // honored the background full-cell match WITHOUT re-scanning to the tail. A
    // foreground prefix decision (the wrong fix) would find no needle in the
    // prefix and DROP the row, shifting filtered 1 to source 2.
    try std.testing.expectEqual(@as(u64, 0), api.ls_source_row(od.doc, 0));
    try std.testing.expectEqual(@as(u64, 1), api.ls_source_row(od.doc, 1));
    try std.testing.expectEqual(@as(u64, 2), api.ls_source_row(od.doc, 2));
    // Served as a bounded prefix: flagged oversized, col 0 display-capped, and the
    // col-1 tail (which HOLDS the match) is past the scan cap -> served "" (the
    // match is real but not visible in the served prefix).
    try std.testing.expectEqual(true, api.ls_row_oversized(od.doc, 1)); // RED on seed
    try std.testing.expect(api.ls_cell(od.doc, 1, 0).slice().len <= api.cell_max_bytes);
    try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, 1, 0));
    try expectCell(od.doc, 1, 1, ""); // RED on seed
    // The normal rows around it are NOT oversized and serve their real cells.
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, 0));
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, 2));
    try expectCell(od.doc, 0, 1, "needle");
    try expectCell(od.doc, 2, 1, "needle");
}

test "hrf3-nav: filter count / source mapping / jump-under-filter / find-within-filter cross a giant row unchanged (ARCH 3)" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "k,v\n");
    try buf.appendSlice(gpa, "m0,needle\n"); //  source 0: match  -> filtered 0
    try buf.appendSlice(gpa, "x1,plain\n"); //   source 1: no match
    try appendGiantRow(gpa, &buf, false); //     source 2: GIANT tail-match -> filtered 1
    try buf.appendSlice(gpa, "x3,plain\n"); //   source 3: no match
    try buf.appendSlice(gpa, "m4,needle\n"); //  source 4: match  -> filtered 2

    var od = try openBytes(buf.items);
    defer od.deinit();
    try setFilter(od.doc, textReq("needle"));
    // filter_total counts the giant row (full-cell) among the matches (ARCH 3).
    try std.testing.expectEqual(@as(u64, 3), (try waitFilterDone(od.doc)).total);

    // Source mapping is correct ACROSS the giant row (filtered 1 == the giant,
    // source 2), and the rows around it map to their originals.
    _ = api.ls_window_set(od.doc, 0, api.window_max_rows);
    try std.testing.expectEqual(@as(u64, 0), api.ls_source_row(od.doc, 0));
    try std.testing.expectEqual(@as(u64, 2), api.ls_source_row(od.doc, 1));
    try std.testing.expectEqual(@as(u64, 4), api.ls_source_row(od.doc, 2));

    // Jump under the filter: an ORIGINAL row number lands on the nearest match's
    // FILTERED index -- the resolution crosses the giant row and stays exact.
    api.ls_jump_start(od.doc, 3); // nearest match >= 3 is source 4 -> filtered 2
    try std.testing.expectEqual(@as(u64, 2), (try waitJumpDone(od.doc)).landed_row);
    api.ls_jump_start(od.doc, 1); // nearest match >= 1 is the giant (source 2) -> filtered 1
    try std.testing.expectEqual(@as(u64, 1), (try waitJumpDone(od.doc)).landed_row);

    // Find within the filter still counts the giant row (full-cell) among matches
    // (all three filtered rows contain "needle"): counts stay exact and complete.
    try startSearch(od.doc, textReq("needle"));
    const s = try waitSearchDone(od.doc);
    try std.testing.expectEqual(@as(u64, 3), s.total);
    try std.testing.expectEqual(true, s.total_exact);
}

// ===========================================================================
// csv-corpus slice (ARCH-csv-corpus, AC2-AC4). Frozen; planner-owned.
//
// This sweep binds OUR parser to the clean-room generator's parser-agnostic
// oracle: it iterates the GENERATED manifest.json and, for every non-heavy
// case, asserts our output matches the manifest exactly where the manifest is
// exact, and robustly where it is not. Coverage grows automatically with the
// generator; nothing here is hard-coded per file. Uses ONLY the frozen public
// C ABI via `@import("api")` -- no api/lesssheet.h change.
//
// RED -> GREEN (the seed).  The corpus dir is injected by backend/build.zig
// (NOT frozen) through a generated `corpus` options module (corpus.dir). At
// freeze that module EXISTS (so this file compiles) but the generator run is
// deliberately NOT wired, so corpus.dir has no manifest.json and both tests
// fail at loadCorpus with error.CorpusNotGenerated -- a crisp behavior RED
// ("the corpus generate step is not wired"), never a compile/import failure.
// The implementer makes it GREEN by adding, in build.zig, a b.addSystemCommand
// that runs `python3 tools/csvgen/gen.py --all --seed 1337 --out <cache>`,
// making the behavior-test run depend on it, and injecting <cache> as
// corpus.dir (Options.addOptionPath) -- plus the AC7 selftest.py oracle guard.
// Nothing generated is committed (hermetic generate-at-test).
//
// WHY WE FORCE THE ORACLE'S DIALECT (empirically validated over all 56 light
// cases).  The manifest's column_count / data_row_count are defined RELATIVE
// to the declared encoding + delimiter (selftest.py decodes per the declared
// encoding/delimiter before counting), and the generator's has_header intent
// is ground truth a sniffer cannot always recover:
//   * an all-text single-record / no-header file trips our numeric-grammar
//     header suggestion (would drop a data row), and
//   * windows-1252 is, by the frozen contract (api/lesssheet.h TEXT AND
//     ENCODING step 4), NOT auto-detectable -- it resolves to Latin-1.
// So the sweep opens each case FORCING the manifest's encoding (mapped),
// delimiter (where declared), and header (per has_header), MANUAL index, then
// asserts our parser reproduces the oracle's STRUCTURE. This is the faithful,
// satisfiable binding under the frozen contract. Detection/sniffing themselves
// stay covered exhaustively by the hand-built c1/c2/c3 fixtures above; here we
// bind the decode + record-boundary + truncate/pad + count machinery to the
// adversarial oracle.
//
// THE ONE RECORD-MODEL CARVE-OUT.  Our frozen record model counts an empty
// line as a record with a single empty field (api/lesssheet.h DELIMITED-TEXT),
// while the manifest's Python-csv model counts only NON-empty data rows. They
// agree except for a file with interior blank lines, where our count is a
// superset (>= manifest). Asserting == there is contract-impossible (no api
// change), so that dimension is robustness-only (exact + >= manifest). The
// only such light case is blank_lines_interspersed (its manifest notes say so:
// "5 non-empty data rows"); a rename or a NEW interior-blank case falls into
// the strict-== branch and fails LOUD, prompting a planner review -- never a
// silent pass. See recordModelDiverges.
// ===========================================================================

const corpus = @import("corpus");

/// The generated corpus + its manifest, kept together: json.Value strings AND
/// object keys may slice into `bytes` (object keys are always alloc_if_needed),
/// so the buffer must outlive every `.object.get`/value read below.
const Corpus = struct {
    parsed: std.json.Parsed(std.json.Value),
    bytes: []u8,
    gpa: std.mem.Allocator,

    fn deinit(self: *Corpus) void {
        self.parsed.deinit();
        self.gpa.free(self.bytes);
    }

    /// The `cases[]` array (generator-guaranteed shape; a corrupt manifest is a
    /// loud panic, which the AC7 selftest.py guard prevents from ever shipping).
    fn cases(self: *const Corpus) []std.json.Value {
        return self.parsed.value.object.get("cases").?.array.items;
    }
};

/// Load + parse <corpus.dir>/manifest.json. THE RED SEED lives here: at freeze
/// corpus.dir has no manifest, so this returns error.CorpusNotGenerated.
fn loadCorpus(gpa: std.mem.Allocator) !Corpus {
    const io = std.testing.io;
    const path = try std.fs.path.join(gpa, &.{ corpus.dir, "manifest.json" });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |e| {
        std.debug.print(
            "\n[csv-corpus] cannot read {s}: {t}\n" ++
                "  the corpus generate step is NOT WIRED. In backend/build.zig add a\n" ++
                "  b.addSystemCommand running `python3 tools/csvgen/gen.py --all --seed 1337\n" ++
                "  --out <cache>`, make run_behavior_tests depend on it, and inject <cache>\n" ++
                "  as the `corpus` option `dir` (Options.addOptionPath). Nothing is committed.\n",
            .{ path, e },
        );
        return error.CorpusNotGenerated;
    };
    errdefer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    return .{ .parsed = parsed, .bytes = bytes, .gpa = gpa };
}

// --- manifest field accessors (dynamic json.Value; total, tag-safe) ---------

fn mObj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}
fn mInt(v: std.json.Value, key: []const u8) ?i64 {
    const x = mObj(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        else => null,
    };
}
fn mStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = mObj(v, key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}
fn mBool(v: std.json.Value, key: []const u8) bool {
    const x = mObj(v, key) orelse return false;
    return switch (x) {
        .bool => |b| b,
        else => false,
    };
}

/// Manifest encoding string -> the concrete LS_ENCODING_* value to FORCE and to
/// expect in the resolved dialect. null for "n/a" and the malformed
/// "... (invalid|truncated|with NUL)" notes (open with AUTO; assert nothing).
fn encConcrete(enc: []const u8) ?u8 {
    if (std.mem.eql(u8, enc, "utf-8")) return api.encoding_utf8;
    if (std.mem.eql(u8, enc, "utf-16le")) return api.encoding_utf16le;
    if (std.mem.eql(u8, enc, "utf-16be")) return api.encoding_utf16be;
    if (std.mem.eql(u8, enc, "latin-1")) return api.encoding_latin1;
    if (std.mem.eql(u8, enc, "windows-1252")) return api.encoding_windows1252;
    return null;
}

/// The single documented record-model carve-out (see the section header): our
/// frozen "empty line == a record" model over-counts the manifest's non-empty
/// data-row count for a file with interior blank lines.
fn recordModelDiverges(name: []const u8) bool {
    return std.mem.eql(u8, name, "blank_lines_interspersed");
}

/// Force the oracle's declared dialect (see the section header for why). MANUAL
/// index: a light file (< head budget) is fully indexed at open, so the row
/// count is exact immediately.
fn forcedOptions(case: std.json.Value) api.OpenOptions {
    var opts: api.OpenOptions = .{ .index_mode = api.index_manual };
    if (mStr(case, "encoding")) |enc| {
        if (encConcrete(enc)) |e| opts.encoding = @as(i32, e);
    }
    if (mStr(case, "delimiter")) |d| {
        if (d.len == 1) opts.separator = @as(i32, d[0]);
    }
    opts.header = if (mBool(case, "has_header")) api.header_on else api.header_off;
    return opts;
}

/// Materialize the head window and prove every served cell is BOUNDED by the
/// display cap and safe to read (touch every served byte: an out-of-bounds
/// borrow would trap under test safety). The robustness lane for AC2/AC3 --
/// the only cell check available, since the manifest carries no cell text.
fn sampleServableBounded(doc: *api.Doc) !void {
    const r = api.ls_window_set(doc, 0, 64);
    const col_cap: u32 = @min(api.ls_column_count(doc), 8);
    var sum: usize = 0;
    var row = r.first_row;
    while (row < r.first_row + r.row_count) : (row += 1) {
        _ = api.ls_row_oversized(doc, row);
        var c: u32 = 0;
        while (c < col_cap) : (c += 1) {
            const cell = api.ls_cell(doc, row, c);
            try std.testing.expect(cell.len <= api.cell_max_bytes);
            _ = api.ls_cell_truncated(doc, row, c);
            for (cell.slice()) |b| sum +%= b;
        }
    }
    std.mem.doNotOptimizeAway(sum);
}

// ---------------------------------------------------------------------------
// AC2 (exactness, well-formed) + AC3 (robustness, malformed / undefined dims).
// One oracle-bound sweep over the whole light corpus.
// ---------------------------------------------------------------------------

test "corpus: parser output matches the manifest oracle across the light corpus (ARCH AC2/AC3)" {
    const gpa = std.testing.allocator;
    var cx = try loadCorpus(gpa);
    defer cx.deinit();

    var seen: usize = 0;
    var malformed_seen: usize = 0;
    var enc_mask: u8 = 0; // bit e set once a concrete encoding e is asserted

    for (cx.cases()) |case| {
        if (mBool(case, "heavy")) continue; // heavy cases: on-demand perf lane (AC6), never here
        const file = mStr(case, "file") orelse return error.MalformedManifest;
        if (std.mem.endsWith(u8, file, ".gz")) continue; // .csv.gz deferred (no gzip parser)
        const name = mStr(case, "name") orelse return error.MalformedManifest;
        errdefer std.debug.print("\n[csv-corpus] AC2/AC3 case: {s} ({s})\n", .{ name, file });

        const path = try std.fs.path.joinZ(gpa, &.{ corpus.dir, file });
        defer gpa.free(path);
        const opts = forcedOptions(case);
        var doc_opt: ?*api.Doc = null;
        const st = api.ls_open(path.ptr, &opts, &doc_opt);
        seen += 1;

        if (mBool(case, "malformed")) {
            malformed_seen += 1;
            // AC3: opens lenient (LS_OK) OR a distinct documented status; never
            // crash/hang/UB. The file exists and is readable, so the only
            // legitimate outcomes are OK or the catch-all IO code.
            try std.testing.expect(st == .ok or st == .io);
            if (st == .ok) {
                const doc = doc_opt.?;
                defer api.ls_close(doc);
                try sampleServableBounded(doc); // if it opens, cells serve bounded
            }
            continue;
        }

        // Well-formed: exact where the manifest field is an integer; robustness
        // where it is "ragged"/null (that dimension simply is not asserted).
        try std.testing.expectEqual(api.Status.ok, st);
        const doc = doc_opt.?;
        defer api.ls_close(doc);

        if (mInt(case, "column_count")) |cc| {
            try std.testing.expectEqual(@as(u32, @intCast(cc)), api.ls_column_count(doc));
        }
        if (mInt(case, "data_row_count")) |dr| {
            const rc = api.ls_row_count_get(doc);
            try std.testing.expectEqual(true, rc.exact); // light file: exact at open
            const want = @as(u64, @intCast(dr));
            if (recordModelDiverges(name)) {
                try std.testing.expect(rc.count >= want); // interior blanks add records
            } else {
                try std.testing.expectEqual(want, rc.count);
            }
        }
        if (mStr(case, "encoding")) |enc| {
            if (encConcrete(enc)) |e| {
                try std.testing.expectEqual(e, api.ls_dialect_get(doc).encoding);
                enc_mask |= (@as(u8, 1) << @as(u3, @intCast(e)));
            }
        }
        if (mStr(case, "delimiter")) |d| {
            if (d.len == 1) try std.testing.expectEqual(@as(u8, d[0]), api.ls_dialect_get(doc).separator);
        }
        try sampleServableBounded(doc);
    }

    // COMPLETENESS FLOOR: a future weakening of `gen.py --all` cannot silently
    // shrink coverage. The light corpus is 56 cases (8 malformed; all 5
    // concrete encodings represented).
    try std.testing.expect(seen >= 40);
    try std.testing.expect(malformed_seen >= 5);
    try std.testing.expect(@popCount(enc_mask) >= 5); // utf8/utf16le/utf16be/latin1/win1252
}

// ---------------------------------------------------------------------------
// AC4 -- cold-open budget across every non-heavy case: ls_open + first window
// materialize completes < 500 ms (O(head)/O(viewport), never O(file)). AUTO
// dialect (the realistic sniff/detect cold path) + MANUAL index (no background
// thread -> deterministic timing).
// ---------------------------------------------------------------------------

test "corpus: cold-open + first window is < 500 ms for every non-heavy case (ARCH AC4)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cx = try loadCorpus(gpa);
    defer cx.deinit();

    var seen: usize = 0;
    for (cx.cases()) |case| {
        if (mBool(case, "heavy")) continue;
        const file = mStr(case, "file") orelse return error.MalformedManifest;
        if (std.mem.endsWith(u8, file, ".gz")) continue;
        const name = mStr(case, "name") orelse return error.MalformedManifest;
        errdefer std.debug.print("\n[csv-corpus] AC4 cold-open case: {s} ({s})\n", .{ name, file });

        const path = try std.fs.path.joinZ(gpa, &.{ corpus.dir, file });
        defer gpa.free(path);

        var doc_opt: ?*api.Doc = null;
        const t0: std.Io.Clock.Timestamp = .now(io, .awake);
        const st = api.ls_open(path.ptr, &manual, &doc_opt); // AUTO sniff/detect, MANUAL index
        if (st == .ok) {
            const doc = doc_opt.?;
            defer api.ls_close(doc);
            _ = api.ls_window_set(doc, 0, api.open_ready_min_rows); // first screen
        }
        try std.testing.expect(elapsedMs(t0) < 500);
        seen += 1;
    }
    try std.testing.expect(seen >= 40); // completeness floor (see AC2/AC3 sweep)
}

// ===========================================================================
// select-copy slice (ARCH-select-copy) — the SHARED api/ + BACKEND piece: the
// bounded, window-INDEPENDENT LOSSLESS full-cell read ls_cell_copy. Frozen;
// planner-owned. Maps ARCH acceptance criterion 3 (Copy is lossless + correct),
// BACKEND portion: a cell past the 4 KiB display cap is read COMPLETE up to the
// caller's byte cap; the truncated flag + the exact-cap, code-point-boundary
// cut; a small cell reads byte-identical to ls_cell; the NO-BORROW (copy)
// lifetime rule; and the PENDING / NO_CELL / window-independence status
// contract (how an off-thread copy reads across the scan frontier). Semantics
// pinned in api/lesssheet.h FULL-CELL READ / ls_cell_copy and mirrored in
// contracts/api.zig (CopyResult + the comptime pin). The macOS selection / TSV
// builder / async copy is a SEPARATE pass (frontend Contracts + Tests).
//
// Determinism: custom fixtures force the dialect + MANUAL index; a fixture no
// larger than the head budget is fully indexed at open (exact count). The
// big-cell fixtures sit just over the 4 KiB display cap but far under the 1 MiB
// per-row source scan cap, so they are NORMAL (not oversized) rows — read whole
// into a generous caller buffer.
//
// NOTE (RED seed): src/ ships a stub (window.cellCopy) that serves the EMPTY
// string, so cc1..cc5 are RED on content/status while `zig build` still
// compiles (the comptime pin + C-ABI export are satisfied). The RED->GREEN path
// is documented on window.cellCopy.
// ---------------------------------------------------------------------------

const CopyOut = struct { result: api.CopyResult, len: usize, truncated: bool };

/// Call ls_cell_copy into `buf`. The out-params are POISONED first, so a GREEN
/// implementation that returns .ok/.no_cell/.pending but forgets to write them
/// is caught by the assertions below.
fn copyCell(doc: *const api.Doc, row: u64, col: u32, buf: []u8) CopyOut {
    var len: usize = std.math.maxInt(usize);
    var truncated: bool = true;
    const result = api.ls_cell_copy(doc, row, col, buf.ptr, buf.len, &len, &truncated);
    return .{ .result = result, .len = len, .truncated = truncated };
}

test "cc1: a cell past the display cap is read COMPLETE up to the caller's cap (ARCH 3 lossless)" {
    const gpa = std.testing.allocator;
    // Data row 0, col 0: 5000 bytes (4996 'a' then a distinctive "TAIL") — well
    // over the 4 KiB display cap, well under the 1 MiB per-row source cap.
    var cell0: std.ArrayList(u8) = .empty;
    defer cell0.deinit(gpa);
    var k: usize = 0;
    while (k < 4996) : (k += 1) try cell0.append(gpa, 'a');
    try cell0.appendSlice(gpa, "TAIL");
    try std.testing.expectEqual(@as(usize, 5000), cell0.items.len);

    var fixture: std.ArrayList(u8) = .empty;
    defer fixture.deinit(gpa);
    try fixture.appendSlice(gpa, "h1,h2\n");
    try fixture.appendSlice(gpa, cell0.items);
    try fixture.appendSlice(gpa, ",second\n");

    var od = try openWith(fixture.items, .{ .separator = ',', .header = api.header_on, .index_mode = api.index_manual });
    defer od.deinit();
    try expectDims(od.doc, 1, 2);
    winAll(od.doc);

    // Contrast (unchanged / additive): ls_cell is still DISPLAY-capped + flagged.
    try std.testing.expect(api.ls_cell(od.doc, 0, 0).slice().len <= api.cell_max_bytes);
    try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, 0, 0));

    const buf = try gpa.alloc(u8, 1 << 20); // ~1 MiB — the frontend's per-cell cap
    defer gpa.free(buf);

    // The FULL cell comes back: every byte, correct UTF-8, NOT truncated.
    const c0 = copyCell(od.doc, 0, 0, buf);
    try std.testing.expectEqual(api.CopyResult.ok, c0.result);
    try std.testing.expectEqual(@as(usize, 5000), c0.len);
    try std.testing.expectEqual(false, c0.truncated);
    try std.testing.expectEqualStrings(cell0.items, buf[0..c0.len]);

    // A neighbouring small cell reads whole too.
    const c1 = copyCell(od.doc, 0, 1, buf);
    try std.testing.expectEqual(api.CopyResult.ok, c1.result);
    try std.testing.expectEqual(false, c1.truncated);
    try std.testing.expectEqualStrings("second", buf[0..c1.len]);
}

test "cc2: over the caller's cap serves EXACTLY the cap, flagged, cut at a code-point boundary (ARCH 3)" {
    const gpa = std.testing.allocator;
    // (a) ASCII: the cap lands on a boundary -> exactly buf_len bytes served.
    {
        var fixture: std.ArrayList(u8) = .empty;
        defer fixture.deinit(gpa);
        try fixture.appendSlice(gpa, "h\n");
        var k: usize = 0;
        while (k < 5000) : (k += 1) try fixture.append(gpa, 'a'); // one big cell
        try fixture.append(gpa, '\n');
        var od = try openWith(fixture.items, .{ .separator = ',', .header = api.header_on, .index_mode = api.index_manual });
        defer od.deinit();
        var buf: [100]u8 = undefined;
        const c = copyCell(od.doc, 0, 0, &buf);
        try std.testing.expectEqual(api.CopyResult.ok, c.result);
        try std.testing.expectEqual(@as(usize, 100), c.len); // exactly the cap
        try std.testing.expectEqual(true, c.truncated);
        for (buf[0..c.len]) |ch| try std.testing.expectEqual(@as(u8, 'a'), ch);
    }
    // (b) UTF-8: the cap falls INSIDE a 2-byte 'é' -> cut BEFORE it (99 bytes),
    // never a split code point (mirrors the ls_cell display-cap rule, h13).
    {
        var fixture: std.ArrayList(u8) = .empty;
        defer fixture.deinit(gpa);
        try fixture.appendSlice(gpa, "h\n");
        var k: usize = 0;
        while (k < 99) : (k += 1) try fixture.append(gpa, 'a');
        try fixture.appendSlice(gpa, "é"); // bytes at offsets 99, 100
        k = 0;
        while (k < 500) : (k += 1) try fixture.append(gpa, 'b');
        try fixture.append(gpa, '\n');
        var od = try openWith(fixture.items, .{ .separator = ',', .header = api.header_on, .index_mode = api.index_manual });
        defer od.deinit();
        var buf: [100]u8 = undefined;
        const c = copyCell(od.doc, 0, 0, &buf);
        try std.testing.expectEqual(api.CopyResult.ok, c.result);
        try std.testing.expectEqual(true, c.truncated);
        try std.testing.expectEqual(@as(usize, 99), c.len); // cut before the split 'é'
        try std.testing.expect(std.unicode.utf8ValidateSlice(buf[0..c.len]));
        for (buf[0..c.len]) |ch| try std.testing.expectEqual(@as(u8, 'a'), ch);
    }
}

test "cc3: a small cell reads byte-identical to ls_cell; empty is OK/0; a bad column is NO_CELL (ARCH 3)" {
    var od = try openWith("a,b,c\n1,,hello\np\n", .{ .separator = ',', .header = api.header_on, .index_mode = api.index_manual });
    defer od.deinit();
    try expectDims(od.doc, 2, 3);
    winAll(od.doc);

    var buf: [64]u8 = undefined;
    // Byte-identical to ls_cell for every small cell of row 0 ("1","","hello").
    const cols = [_]u32{ 0, 1, 2 };
    for (cols) |col| {
        const c = copyCell(od.doc, 0, col, &buf);
        try std.testing.expectEqual(api.CopyResult.ok, c.result);
        try std.testing.expectEqual(false, c.truncated);
        try std.testing.expectEqualStrings(api.ls_cell(od.doc, 0, col).slice(), buf[0..c.len]);
    }
    // An EMBEDDED empty cell (row 0, col 1) is OK with zero length, not truncated.
    const embedded = copyCell(od.doc, 0, 1, &buf);
    try std.testing.expectEqual(api.CopyResult.ok, embedded.result);
    try std.testing.expectEqual(@as(usize, 0), embedded.len);
    try std.testing.expectEqual(false, embedded.truncated);
    // A ragged-PADDED empty cell (row 1, col 2 — "p" padded to 3 columns) too.
    const padded = copyCell(od.doc, 1, 2, &buf);
    try std.testing.expectEqual(api.CopyResult.ok, padded.result);
    try std.testing.expectEqual(@as(usize, 0), padded.len);
    // A column at/past ls_column_count has no cell: NO_CELL (retrying won't help).
    try std.testing.expectEqual(api.CopyResult.no_cell, copyCell(od.doc, 0, 3, &buf).result);
}

test "cc4: ls_cell_copy COPIES (no borrow) — its bytes survive a later ls_window_set (ARCH 3)" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 10_000);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);

    _ = api.ls_window_set(od.doc, 0, 64);
    var buf: [64]u8 = undefined;
    var expect: [8]u8 = undefined;
    const want = fixedCell(&expect, 7);

    const c = copyCell(od.doc, 7, 0, &buf);
    try std.testing.expectEqual(api.CopyResult.ok, c.result);
    try std.testing.expectEqualStrings(want, buf[0..c.len]);
    try std.testing.expectEqualStrings(want, api.ls_cell(od.doc, 7, 0).slice()); // agrees with ls_cell

    // Move the window FAR away — this evicts row 7 and invalidates every ls_str
    // borrow. Bytes already COPIED into `buf` are unaffected (it is not a borrow).
    _ = api.ls_window_set(od.doc, 9_000, 64);
    try std.testing.expectEqualStrings(want, buf[0..c.len]); // still intact
    try std.testing.expectEqualStrings("", api.ls_cell(od.doc, 7, 0).slice()); // ls_cell: evicted
    // A FRESH copy of row 7 still works though the window sits at 9000
    // (window-INDEPENDENT: row 7 is behind the frontier, no window needed).
    const c2 = copyCell(od.doc, 7, 0, &buf);
    try std.testing.expectEqual(api.CopyResult.ok, c2.result);
    try std.testing.expectEqualStrings(want, buf[0..c2.len]);
}

test "cc5: PENDING beyond the frontier, NO_CELL past an exact end; reads are window-independent (ARCH 3)" {
    const gpa = std.testing.allocator;
    const fixture = try genFixedRows(gpa, 300_000); // 5.4 MB > head budget
    defer gpa.free(fixture);
    var od = try openBytes(fixture); // MANUAL: no background frontier advance
    defer od.deinit();

    var buf: [64]u8 = undefined;
    var expect: [8]u8 = undefined;

    // Row 0 is behind the open frontier and reads with NO ls_window_set at all
    // (window-INDEPENDENT).
    const head = copyCell(od.doc, 0, 0, &buf);
    try std.testing.expectEqual(api.CopyResult.ok, head.result);
    try std.testing.expectEqualStrings(fixedCell(&expect, 0), buf[0..head.len]);

    // Row 260,000 starts at byte 4,680,000 > LS_OPEN_HEAD_MAX_BYTES: beyond the
    // open frontier in MANUAL mode -> PENDING (advance the frontier and retry).
    try std.testing.expectEqual(api.CopyResult.pending, copyCell(od.doc, 260_000, 0, &buf).result);

    // Advance the frontier over it via the public jump machinery; the same read
    // then succeeds — still with NO ls_window_set (window-INDEPENDENT).
    api.ls_jump_start(od.doc, 260_000);
    _ = try waitJumpDone(od.doc);
    const deep = copyCell(od.doc, 260_000, 0, &buf);
    try std.testing.expectEqual(api.CopyResult.ok, deep.result);
    try std.testing.expectEqualStrings(fixedCell(&expect, 260_000), buf[0..deep.len]);

    // With the count made EXACT, a row at/past the end is NO_CELL (not PENDING).
    try scanToEnd(od.doc);
    try expectDims(od.doc, 300_000, 2);
    try std.testing.expectEqual(api.CopyResult.no_cell, copyCell(od.doc, 300_000, 0, &buf).result);
    // A bad column is NO_CELL regardless of the row.
    try std.testing.expectEqual(api.CopyResult.no_cell, copyCell(od.doc, 0, 2, &buf).result);
}

// ---------------------------------------------------------------------------
// Public C ABI: the select-copy symbol is callable through extern linkage and
// the ls_copy_result enum values are pinned (regression guard; green from seed).
// ---------------------------------------------------------------------------

const c_linked_copy = struct {
    extern fn ls_cell_copy(doc: *const api.Doc, row: u64, col: u32, buf: ?[*]u8, buf_len: usize, out_len: *usize, out_truncated: *bool) api.CopyResult;
};

test "abi: the select-copy symbol links through extern linkage; ls_copy_result values pinned" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.CopyResult.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.CopyResult.pending));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(api.CopyResult.no_cell));

    var od = try openBytes("a,b\nx,y\n");
    defer od.deinit();
    winAll(od.doc);
    var len: usize = 123;
    var truncated: bool = true;
    var buf: [8]u8 = undefined;
    // A column past the count is NO_CELL through the C symbol (green from seed).
    const res = c_linked_copy.ls_cell_copy(od.doc, 0, 9, &buf, buf.len, &len, &truncated);
    try std.testing.expectEqual(api.CopyResult.no_cell, res);
}


// ===========================================================================
// stream-copy slice (ARCH-stream-copy) — the BACKEND COPY CURSOR. Frozen;
// planner-owned. ls_cell_copy is accelerated by an internal, forward, view-
// scoped COPY CURSOR behind the UNCHANGED ABI (api/lesssheet.h + the
// ls_cell_copy signature stay byte-identical): a row-major sweep advances O(1)
// per row instead of re-locating each cell from a sparse checkpoint. Maps:
//   sc1 (AC1) identity output byte-identical to locate-from-scratch, across the
//              representative rects (single / within-window / spanning >=2
//              checkpoints / first+last / col past fields / ragged+embedded-
//              empty / cell past the display cap / oversized row / bounded
//              record-1 row 0).
//   sc2 (AC2) filtered output byte-identical to the per-cell nthMatchLocation
//              path (all-match spanning checkpoints + zero-match).
//   sc3 (AC3) identity locate cost is O(rows), interval-INVARIANT; extra
//              columns add ZERO advances.
//   sc4 (AC4) filtered locate cost is O(filtered rows read), interval-invariant.
//   sc5 (AC5) NEVER-SLOWER: backwards / re-anchor access stays correct and its
//              advance count never exceeds the from-scratch baseline.
//
// THE SEAM (contracts/api.zig, Zig-only — NOT new ABI): copyCursorSetEnabled
// toggles the cursor (OFF == today's locate-from-scratch: the byte-identical
// REFERENCE for AC1/AC2 and the interval-costly BASELINE for AC3/AC5);
// copyAdvances / copyAdvancesReset read/zero the count of SOURCE ROW-ADVANCES
// the copy path takes.
//
// HOW AC3/AC4 PROVE INTERVAL-INVARIANCE WITHOUT A RUNTIME INTERVAL KNOB: a
// per-document runtime checkpoint interval would force a runtime divisor into
// the index/search/filter/nav hot loops (today `% 2048` / `/ 2048` fold to a
// mask/shift on a comptime power-of-two) — a real perf regression for TEST-only
// code, and blast radius far beyond the ARCH's window.zig+base.zig cursor. So
// instead: the cursor sweep's advance count is EXACTLY N-1 (identity) / linear
// in M (filtered) — a value carrying NO checkpoint-interval term, hence
// UNCHANGED whatever the interval (halved or otherwise) — while the from-scratch
// BASELINE is >= 100*N (it re-skips ~interval/2 rows per cell), manifestly
// interval-scaled. `count ~= N`  vs  `baseline >= 100*N` together prove the
// cursor path is O(rows), NOT O(rows x interval). The linear CEILING (e.g.
// `<= N+64`) independently rules out any interval factor (an O(N x interval)
// count would be ~1000x larger). (Planner-decided seam shape — see hand-off.)
//
// RED SEED: the cursor is unbuilt, so cellCopy locates from scratch in BOTH
// toggle states — the AC1/AC2 equivalence sweeps hold trivially (like the
// frontend's structural greens; load-bearing the moment a real cursor could
// diverge) and cc1..cc5 stay green — and NOTHING increments copy_advances
// (copyAdvances == 0), which fails every AC3/AC4/AC5 count assertion (0 is
// neither >= N-1 nor >= 100*N). GREEN needs the cursor + the counter wired to
// increment once per source row the copy path steps forward, in BOTH the
// identity (window.cellCopy) and filtered (window.cellCopyFiltered) paths.
// Every fixture stays < LS_OPEN_HEAD_MAX_BYTES (except the deliberately >4 MiB
// bounded-record-1 fixture) so it is fully indexed at open — exact count, every
// row behind the frontier, deterministic advance counts, no scan.
// ---------------------------------------------------------------------------

fn prepNoop(_: *api.Doc) anyerror!void {}

fn prepScanToEnd(doc: *api.Doc) anyerror!void {
    try scanToEnd(doc);
}

/// ALL-MATCH filter: "0" occurs in every zero-padded genFixedRows cell, so the
/// filtered view is EVERY data row (m == n; filtered row i == physical row i).
/// AUTO index mode so the filter-scan converges to DONE (exact m) on its own —
/// never a jump stealing the single scan slot (which would cancel it).
fn prepFilterAll(doc: *api.Doc) anyerror!void {
    try setFilter(doc, textReq("0"));
    _ = try waitFilterDone(doc);
}

const sc_auto: api.OpenOptions = .{ .index_mode = api.index_auto };

/// Open `bytes` TWICE (independent handles on identical content), run `prep` on
/// each, disable the cursor on the REFERENCE and enable it on the SUBJECT, then
/// sweep [top,bottom] x [left,right] ROW-MAJOR in lockstep — the exact monotone,
/// non-decreasing access TSVCopyBuilder produces, so the subject's forward
/// cursor engages across the whole sweep while the reference locates every cell
/// from scratch. Asserts byte-identical (result, out_len, out_truncated, and the
/// written buf bytes) per cell (ARCH AC1/AC2).
fn expectCopyEquivalent(
    bytes: []const u8,
    options: api.OpenOptions,
    top: u64,
    bottom: u64,
    left: u32,
    right: u32,
    buf_len: usize,
    comptime prep: fn (*api.Doc) anyerror!void,
) !void {
    const gpa = std.testing.allocator;
    var ref = try openWith(bytes, options);
    defer ref.deinit();
    var sub = try openWith(bytes, options);
    defer sub.deinit();
    try prep(ref.doc);
    try prep(sub.doc);
    api.copyCursorSetEnabled(ref.doc, false); // locate-from-scratch REFERENCE
    api.copyCursorSetEnabled(sub.doc, true); // cursor-accelerated SUBJECT

    const bref = try gpa.alloc(u8, buf_len);
    defer gpa.free(bref);
    const bsub = try gpa.alloc(u8, buf_len);
    defer gpa.free(bsub);

    var r = top;
    while (r <= bottom) : (r += 1) {
        var c = left;
        while (c <= right) : (c += 1) {
            errdefer std.debug.print("\n[stream-copy] divergence at row {d}, col {d}\n", .{ r, c });
            const a = copyCell(ref.doc, r, c, bref);
            const b = copyCell(sub.doc, r, c, bsub);
            try std.testing.expectEqual(a.result, b.result);
            try std.testing.expectEqual(a.len, b.len);
            try std.testing.expectEqual(a.truncated, b.truncated);
            try std.testing.expectEqualSlices(u8, bref[0..a.len], bsub[0..b.len]);
        }
    }
}

/// Row-major copy sweep of [0,rows) x [0,cols) with the cursor toggled to
/// `enabled`; returns the copy-path SOURCE-ROW-ADVANCE count taken by the sweep.
fn sweepAdvances(doc: *api.Doc, rows: u64, cols: u32, enabled: bool) u64 {
    api.copyCursorSetEnabled(doc, enabled);
    api.copyAdvancesReset(doc);
    var buf: [64]u8 = undefined;
    var r: u64 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            _ = copyCell(doc, r, c, &buf);
        }
    }
    return api.copyAdvances(doc);
}

test "sc1: identity copy is byte-identical to locate-from-scratch across representative rects (ARCH AC1)" {
    const gpa = std.testing.allocator;

    // (a) Uniform fixture spanning >=2 checkpoints (n > checkpoint_interval): a
    // full row-major sweep covers the single / within-first-window / checkpoint-
    // spanning / first+last rects at once; col 2 == column_count is NO_CELL in
    // BOTH paths (past-fields).
    {
        const n: u64 = 2_500;
        const fixture = try genFixedRows(gpa, n);
        defer gpa.free(fixture);
        try expectCopyEquivalent(fixture, manual, 0, n - 1, 0, 2, 64, prepScanToEnd);
    }
    // (b) Ragged + embedded-empty cell + a cell PAST the 4 KiB display cap (the
    // lossless full read). Header on (texty record 1).
    {
        var fx: std.ArrayList(u8) = .empty;
        defer fx.deinit(gpa);
        try fx.appendSlice(gpa, "h1,h2,h3\n");
        try fx.appendSlice(gpa, "a,,c\n"); // embedded empty (col 1)
        try fx.appendSlice(gpa, "short\n"); // ragged: cols 1,2 padded empty
        var big: usize = 0;
        while (big < 5000) : (big += 1) try fx.append(gpa, 'A'); // > the display cap
        try fx.appendSlice(gpa, ",y,z\n");
        const opts: api.OpenOptions = .{ .separator = ',', .header = api.header_on, .index_mode = api.index_manual };
        try expectCopyEquivalent(fx.items, opts, 0, 2, 0, 3, 1 << 16, prepNoop); // col 3 == column_count
    }
    // (c) Oversized row (source extent > the per-row scan cap): served as a
    // bounded prefix; the cursor must reach the rows AFTER it via the frontier's
    // post-oversized checkpoint, byte-identically to from-scratch.
    {
        const doc = try genHugeRowDoc(gpa, 2, 2); // rows 0,1 small; 2 huge; 3,4 small
        defer gpa.free(doc.bytes);
        try expectCopyEquivalent(doc.bytes, manual, 0, 4, 0, 2, 4096, prepNoop); // col 2 == column_count
    }
    // (d) Bounded record-1 row 0 (header OFF; record 1 never terminates within
    // the O(head) budget): served from data_start, BYPASSING the cursor — pinned
    // here so the cursor addition never disturbs that special case.
    {
        var fx: std.ArrayList(u8) = .empty;
        defer fx.deinit(gpa);
        const over: usize = @intCast(api.open_head_max_bytes + 64 * 1024); // > head budget
        const blob = try gpa.alloc(u8, over);
        defer gpa.free(blob);
        @memset(blob, 'A');
        try fx.appendSlice(gpa, blob); // record 1 == data row 0, past the budget
        try fx.appendSlice(gpa, ",tail\n");
        const opts: api.OpenOptions = .{ .separator = ',', .header = api.header_off, .index_mode = api.index_manual };
        try expectCopyEquivalent(fx.items, opts, 0, 0, 0, 1, 1 << 16, prepNoop);
    }
}

test "sc2: filtered copy is byte-identical to the per-cell match-locate path (ARCH AC2)" {
    const gpa = std.testing.allocator;
    const n: u64 = 6_000; // all-match spans checkpoints 0,2048,4096
    const fixture = try genFixedRows(gpa, n);
    defer gpa.free(fixture);

    // ALL-MATCH: filtered coords == identity coords; a filtered row-major sweep
    // spanning >=2 checkpoints matches the from-scratch nthMatchLocation path
    // cell-for-cell.
    try expectCopyEquivalent(fixture, sc_auto, 0, n - 1, 0, 1, 64, prepFilterAll);

    // ZERO-MATCH ("z" occurs nowhere): the filtered view has 0 rows, so row 0 is
    // NO_CELL (m exact) in BOTH the cursor and reference paths.
    {
        var ref = try openWith(fixture, sc_auto);
        defer ref.deinit();
        var sub = try openWith(fixture, sc_auto);
        defer sub.deinit();
        try setFilter(ref.doc, textReq("z"));
        _ = try waitFilterDone(ref.doc);
        try setFilter(sub.doc, textReq("z"));
        _ = try waitFilterDone(sub.doc);
        api.copyCursorSetEnabled(ref.doc, false);
        api.copyCursorSetEnabled(sub.doc, true);
        var b1: [64]u8 = undefined;
        var b2: [64]u8 = undefined;
        try std.testing.expectEqual(api.CopyResult.no_cell, copyCell(ref.doc, 0, 0, &b1).result);
        try std.testing.expectEqual(api.CopyResult.no_cell, copyCell(sub.doc, 0, 0, &b2).result);
    }
}

test "sc3: identity copy is O(rows), interval-invariant; extra columns add zero advances (ARCH AC3)" {
    const gpa = std.testing.allocator;
    const n: u64 = 10_000; // spans ~5 checkpoints (interval 2048)
    const fixture = try genFixedRows(gpa, n);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);
    try expectDims(od.doc, n, 2);

    // BASELINE (cursor OFF): from-scratch re-locates each cell from the nearest
    // sparse checkpoint -> ~interval/2 advances PER ROW -> manifestly interval-
    // scaled. (RED seed: copyAdvances == 0, so 0 >= 100*n fails.)
    const baseline = sweepAdvances(od.doc, n, 1, false);
    try std.testing.expect(baseline >= 100 * n);

    // CURSOR (on): a row-major sweep advances exactly ONCE per row after
    // anchoring at row 0 -> ~N-1. N-1 carries NO checkpoint-interval term, so it
    // is UNCHANGED whatever the interval (halved or otherwise): O(rows), NOT
    // O(rows x interval). (RED seed: 0 is not >= n-1.)
    const cursor = sweepAdvances(od.doc, n, 1, true);
    try std.testing.expect(cursor >= n - 1); // linear floor (>= one advance/row)
    try std.testing.expect(cursor <= n + 64); // linear ceiling, + O(1) only (rules out any interval factor)
    try std.testing.expect(baseline >= 20 * cursor); // from-scratch dwarfs the cursor

    // EXTRA COLUMNS ADD ZERO advances: sweeping BOTH columns visits each row's
    // cells without re-locating -> the SAME advance count as one column.
    const cursor_wide = sweepAdvances(od.doc, n, 2, true);
    try std.testing.expectEqual(cursor, cursor_wide);
}

test "sc4: filtered copy is O(filtered rows read), interval-invariant (ARCH AC4)" {
    const gpa = std.testing.allocator;
    const n: u64 = 6_000; // all rows match "0" -> m == n, spanning checkpoints
    const fixture = try genFixedRows(gpa, n);
    defer gpa.free(fixture);
    var od = try openWith(fixture, sc_auto);
    defer od.deinit();
    try setFilter(od.doc, textReq("0"));
    const fs = try waitFilterDone(od.doc);
    try std.testing.expectEqual(n, fs.total); // all-match

    // CURSOR (on): the filtered cursor resumes the match-walk FORWARD from the
    // last filtered row -> LINEAR in filtered rows read, with NO interval term.
    // An O(m x interval) count would be ~interval x larger (>> 4*n+8), so the
    // linear ceiling rules out any interval factor. (RED seed: 0 is not >= 1.)
    const cursor = sweepAdvances(od.doc, n, 1, true);
    try std.testing.expect(cursor >= 1); // did real forward-walk work
    try std.testing.expect(cursor <= 4 * n + 8); // linear in m, interval-INDEPENDENT
}

test "sc5: backwards / re-anchor access stays correct and never slower than from-scratch (ARCH AC5)" {
    const gpa = std.testing.allocator;
    const n: u64 = 8_000;
    const fixture = try genFixedRows(gpa, n);
    defer gpa.free(fixture);
    var ref = try openBytes(fixture);
    defer ref.deinit();
    var sub = try openBytes(fixture);
    defer sub.deinit();
    try scanToEnd(ref.doc);
    try scanToEnd(sub.doc);
    api.copyCursorSetEnabled(ref.doc, false); // from-scratch reference
    api.copyCursorSetEnabled(sub.doc, true); // cursor re-anchors on each backwards step
    api.copyAdvancesReset(ref.doc);
    api.copyAdvancesReset(sub.doc);

    // DESCENDING sweep: every step has row < cursor.row, so the cursor must
    // re-anchor (fall back to locate-from-scratch) -- still CORRECT, and never
    // more advances than the from-scratch reference doing the same.
    var bref: [64]u8 = undefined;
    var bsub: [64]u8 = undefined;
    var r: u64 = n;
    while (r > 0) {
        r -= 1;
        const a = copyCell(ref.doc, r, 0, &bref);
        const b = copyCell(sub.doc, r, 0, &bsub);
        try std.testing.expectEqual(a.result, b.result);
        try std.testing.expectEqualSlices(u8, bref[0..a.len], bsub[0..b.len]);
    }
    const baseline = api.copyAdvances(ref.doc);
    const cursor = api.copyAdvances(sub.doc);
    try std.testing.expect(baseline >= 100 * n); // from-scratch backwards is interval-costly (RED seed: 0)
    try std.testing.expect(cursor <= baseline); // NEVER SLOWER than locate-from-scratch
}


// ===========================================================================
// csv-gz slice (ARCH-csv-gz) — transparent, checkpointed `.csv.gz`. Frozen;
// planner-owned. Tests exercise the PUBLIC C ABI through @import("api") only,
// PLUS the Zig-only instrumentation seams (gz* / snapshot probe — NOT the C
// ABI, like copyAdvances), so api/lesssheet.h is BYTE-IDENTICAL (AC1). gzip
// fixtures are generated DETERMINISTICALLY IN-TEST via the pinned Zig-0.16 std
// (std.compress.flate.Compress .gzip/.raw + a hand-built RFC-1952 header/footer
// for the optional-field / recovery / false-ISIZE / BGZF matrices), so the
// frozen suite is self-contained and never depends on build.zig wiring.
//
// AC -> test map  (FU = deterministic frozen unit · TL = generous CI timing
// lane · RM = REVIEWER-MEASURED build-time, NOT gate-blocking — Decision 2-A):
//   AC1  frozen boundary ....... gz_ac1  (GUARD: root gate + abi tests)
//   AC2  magic not name ........ gz_ac2  (FU RED)
//   AC3  plain/gzip equivalence  gz_ac3  (FU RED)
//   AC4  member transparency ... gz_ac4  (FU RED)
//   AC5  dual open bound ....... gz_ac5  (FU RED)
//   AC6  5KB..500GB flatness ... gz_ac6  (FU RED + TL cold-open<500ms)
//   AC7  small determinism ..... gz_ac7  (FU RED)
//   AC8  RFC/member coverage ... gz_ac8  (FU RED)
//   AC9  recovery matrix ....... gz_ac9  (FU RED)
//   AC10 terminal prefix ....... gz_ac10 (FU RED)
//   AC11 no ISIZE dependency ... gz_ac11 (FU RED)
//   AC12 chunk-boundary ........ gz_ac12 (FU RED)
//   AC13 no unbounded materlz. . gz_ac13 (FU RED)
//   AC14 checkpoint restore .... gz_ac14 (FU RED + comptime shape pin)
//   AC15 bounded replay ........ gz_ac15 (FU RED, heavy 132 MiB-inflate fixture)
//   AC16 landing performance ... gz_ac16 (FU RED correctness + TL <100ms)
//   AC17 resident/temp bounds .. gz_ac17 (FU RED; 120 MiB 10GB-class RSS = RM)
//   AC18 checkpoint-store fail . gz_ac18 (FU RED)
//   AC19 concurrency+cleanup ... gz_ac19 (FU RED)
//   AC20 plain-CSV regression .. gz_ac20 (GUARD FU; 5%-median & 5MB-RSS = RM)
//   AC21 read-only source ...... gz_ac21 (GUARD FU)
//   AC22 build/distribution .... gz_ac22 (GUARD FU; single-digit-MB size = RM)
//
// RED SEED: gzip is NOT wired (root.zig detects no magic; source.sourceFromMapping
// always builds the mmap specialization). So a `.csv` file whose bytes are gzip
// is opened as mmap-as-plain garbage -> every EQUIVALENCE/behaviour AC diverges
// from its plain reference (RED). The gz* counters read DEFAULTED base.Document
// state == 0/false -> every QUANTITATIVE AC's "did real work" clause (`> 0 and
// <= bound`) fails at 0 (RED) — exactly stream-copy's `copyAdvances == 0` seed.
// The four GUARD ACs (AC1/20/21/22) are invariants: GREEN by construction and
// must STAY green. GREEN needs the implementer to build+wire the bounded,
// checkpointed gzip Source + streaming matcher and set the counters.
// ===========================================================================

const flate = std.compress.flate;

/// gzip `plain` into ONE standard member (stdlib header/footer, mtime 0).
fn gz(gpa: std.mem.Allocator, plain: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, @max(64, plain.len));
    defer out.deinit();
    var win: [flate.max_window_len]u8 = undefined;
    var cmp = try flate.Compress.init(&out.writer, &win, .gzip, .default);
    try cmp.writer.writeAll(plain);
    try cmp.finish();
    return gpa.dupe(u8, out.written());
}

/// Raw (headerless) DEFLATE of `plain` — the payload for hand-built members.
fn deflateRaw(gpa: std.mem.Allocator, plain: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, @max(64, plain.len));
    defer out.deinit();
    var win: [flate.max_window_len]u8 = undefined;
    var cmp = try flate.Compress.init(&out.writer, &win, .raw, .default);
    try cmp.writer.writeAll(plain);
    try cmp.finish();
    return gpa.dupe(u8, out.written());
}

fn appendU32Le(gpa: std.mem.Allocator, m: *std.ArrayList(u8), v: u32) !void {
    try m.append(gpa, @intCast(v & 0xff));
    try m.append(gpa, @intCast((v >> 8) & 0xff));
    try m.append(gpa, @intCast((v >> 16) & 0xff));
    try m.append(gpa, @intCast((v >> 24) & 0xff));
}

/// Full-control single gzip member (RFC 1952) for the optional-field (AC8),
/// recovery (AC9), and false-ISIZE (AC11) matrices.
const GzFlags = struct {
    cm: u8 = 8, // compression method (8 = deflate; !=8 tests rejection)
    ftext: bool = false,
    fname: ?[]const u8 = null,
    fcomment: ?[]const u8 = null,
    extra: ?[]const u8 = null, // FEXTRA payload (subfields; e.g. BGZF "BC")
    fhcrc: bool = false,
    bad_fhcrc: bool = false, // corrupt the header CRC16 (AC9)
    bad_crc: bool = false, // corrupt the footer CRC32 (AC9)
    isize_override: ?u32 = null, // false/wrapped ISIZE (AC11)
    truncate_payload: ?usize = null, // keep only N deflate bytes (AC9 truncation)
    omit_footer: bool = false, // drop CRC32+ISIZE (AC9 truncation)
};

fn gzMember(gpa: std.mem.Allocator, plain: []const u8, f: GzFlags) ![]u8 {
    var m: std.ArrayList(u8) = .empty;
    errdefer m.deinit(gpa);
    var flg: u8 = 0;
    if (f.ftext) flg |= 0x01;
    if (f.fhcrc or f.bad_fhcrc) flg |= 0x02;
    if (f.extra != null) flg |= 0x04;
    if (f.fname != null) flg |= 0x08;
    if (f.fcomment != null) flg |= 0x10;
    try m.appendSlice(gpa, &.{ 0x1f, 0x8b, f.cm, flg, 0, 0, 0, 0, 0, 0xff }); // magic..OS
    if (f.extra) |x| {
        try m.append(gpa, @intCast(x.len & 0xff));
        try m.append(gpa, @intCast((x.len >> 8) & 0xff));
        try m.appendSlice(gpa, x);
    }
    if (f.fname) |n| {
        try m.appendSlice(gpa, n);
        try m.append(gpa, 0);
    }
    if (f.fcomment) |cm| {
        try m.appendSlice(gpa, cm);
        try m.append(gpa, 0);
    }
    if (f.fhcrc or f.bad_fhcrc) {
        var h16: u16 = @truncate(std.hash.Crc32.hash(m.items));
        if (f.bad_fhcrc) h16 +%= 1;
        try m.append(gpa, @intCast(h16 & 0xff));
        try m.append(gpa, @intCast((h16 >> 8) & 0xff));
    }
    const raw = try deflateRaw(gpa, plain);
    defer gpa.free(raw);
    const payload = if (f.truncate_payload) |n| raw[0..@min(n, raw.len)] else raw;
    try m.appendSlice(gpa, payload);
    if (!f.omit_footer) {
        var crc = std.hash.Crc32.hash(plain);
        if (f.bad_crc) crc +%= 1;
        try appendU32Le(gpa, &m, crc);
        try appendU32Le(gpa, &m, f.isize_override orelse @truncate(plain.len));
    }
    return m.toOwnedSlice(gpa);
}

/// A multi-member gzip whose CONCATENATED payload == `plain`, split at byte
/// `at` (adversarial member boundary — AC3/AC4).
fn gzSplit(gpa: std.mem.Allocator, plain: []const u8, at: usize) ![]u8 {
    const cut = @min(at, plain.len);
    const a = try gzMember(gpa, plain[0..cut], .{});
    defer gpa.free(a);
    const b = try gzMember(gpa, plain[cut..], .{});
    defer gpa.free(b);
    var m: std.ArrayList(u8) = .empty;
    errdefer m.deinit(gpa);
    try m.appendSlice(gpa, a);
    try m.appendSlice(gpa, b);
    return m.toOwnedSlice(gpa);
}

/// A BGZF-STYLE stream: `plain` split into `block`-byte members, each carrying a
/// gzip FEXTRA "BC" subfield (AC3/AC8). BSIZE is a placeholder — a generic gzip
/// reader skips XLEN bytes and decodes the payload regardless.
fn gzBgzf(gpa: std.mem.Allocator, plain: []const u8, block: usize) ![]u8 {
    var m: std.ArrayList(u8) = .empty;
    errdefer m.deinit(gpa);
    const bc = [_]u8{ 'B', 'C', 2, 0, 0, 0 }; // SI1 SI2 SLEN(=2 LE) BSIZE(LE placeholder)
    var i: usize = 0;
    if (plain.len == 0) {
        const only = try gzMember(gpa, plain, .{ .extra = &bc });
        defer gpa.free(only);
        try m.appendSlice(gpa, only);
        return m.toOwnedSlice(gpa);
    }
    while (i < plain.len) : (i += block) {
        const end = @min(i + block, plain.len);
        const mem = try gzMember(gpa, plain[i..end], .{ .extra = &bc });
        defer gpa.free(mem);
        try m.appendSlice(gpa, mem);
    }
    return m.toOwnedSlice(gpa);
}

/// A HIGH-EXPANSION gzip: `unit` repeated `repeat` times, streamed through the
/// (fastest) compressor so a few-KB gz inflates to `unit.len * repeat` bytes
/// WITHOUT materializing the whole logical stream (AC6/AC15).
fn gzHighExpansion(gpa: std.mem.Allocator, unit: []const u8, repeat: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer out.deinit();
    var win: [flate.max_window_len]u8 = undefined;
    var cmp = try flate.Compress.init(&out.writer, &win, .gzip, .level_1);
    var i: usize = 0;
    while (i < repeat) : (i += 1) try cmp.writer.writeAll(unit);
    try cmp.finish();
    return gpa.dupe(u8, out.written());
}

fn makeFixtureNamed(bytes: []const u8, sub: []const u8, mode: u9) !Fixture {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = bytes, .flags = .{ .permissions = .fromMode(mode) } });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ buf[0..n], sub });
    return .{ .tmp = tmp, .path = path };
}

fn openNamed(bytes: []const u8, sub: []const u8, options: api.OpenOptions) !OpenedDoc {
    var fx = try makeFixtureNamed(bytes, sub, 0o644);
    errdefer fx.deinit();
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &options, &doc));
    try std.testing.expect(doc != null);
    return .{ .fx = fx, .doc = doc.? };
}

/// The AC3 workhorse: a gzip of `plain` opened with `opts` is byte-identical in
/// EVERY observable dimension to the plain file opened the same way. RED in the
/// seed (gzip decodes to mmap-as-plain garbage -> dims/dialect/cells diverge).
fn expectGzEquiv(plain: []const u8, opts: api.OpenOptions, gz_bytes: []const u8) !void {
    var pod = try openWith(plain, opts);
    defer pod.deinit();
    var god = try openWith(gz_bytes, opts);
    defer god.deinit();
    try scanToEnd(pod.doc);
    try scanToEnd(god.doc);

    const pd = api.ls_dialect_get(pod.doc);
    const gd = api.ls_dialect_get(god.doc);
    try std.testing.expectEqual(pd.separator, gd.separator);
    try std.testing.expectEqual(pd.quote, gd.quote);
    try std.testing.expectEqual(pd.has_quote, gd.has_quote);
    try std.testing.expectEqual(pd.header, gd.header);
    try std.testing.expectEqual(pd.encoding, gd.encoding);

    const cols = api.ls_column_count(pod.doc);
    try std.testing.expectEqual(cols, api.ls_column_count(god.doc));
    const prc = api.ls_row_count_get(pod.doc);
    const grc = api.ls_row_count_get(god.doc);
    try std.testing.expectEqual(prc.count, grc.count);
    try std.testing.expectEqual(prc.exact, grc.exact);

    _ = api.ls_window_set(pod.doc, 0, api.window_max_rows);
    _ = api.ls_window_set(god.doc, 0, api.window_max_rows);
    var c: u32 = 0;
    while (c < cols) : (c += 1) {
        try std.testing.expectEqualStrings(api.ls_header_cell(pod.doc, c).slice(), api.ls_header_cell(god.doc, c).slice());
        try std.testing.expectEqual(api.ls_header_cell_truncated(pod.doc, c), api.ls_header_cell_truncated(god.doc, c));
    }
    var r: u64 = 0;
    while (r < prc.count and r < api.window_max_rows) : (r += 1) {
        c = 0;
        while (c < cols) : (c += 1) {
            errdefer std.debug.print("\n[csv-gz] cell divergence at row {d} col {d}\n", .{ r, c });
            try std.testing.expectEqualStrings(api.ls_cell(pod.doc, r, c).slice(), api.ls_cell(god.doc, r, c).slice());
            try std.testing.expectEqual(api.ls_cell_truncated(pod.doc, r, c), api.ls_cell_truncated(god.doc, r, c));
        }
        try std.testing.expectEqual(api.ls_row_oversized(pod.doc, r), api.ls_row_oversized(god.doc, r));
        try std.testing.expectEqual(api.ls_source_row(pod.doc, r), api.ls_source_row(god.doc, r));
    }
}

test "gz_ac1: frozen C-ABI boundary (root gate + abi extern-linkage tests)" {
    // AC1 (GUARD): api/lesssheet.h byte-identity is enforced by the ROOT gate's
    // frozen `api/` integrity + the `abi:` extern-linkage tests above; csv-gz
    // touches NO api/ symbol. Here we assert the gz feature is entirely behind
    // the unchanged ABI: the instrumentation is Zig-only (never a C export).
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    // A plain document reports zero gzip state through the Zig-only seams — the
    // ABI surface it exposes is unchanged (no gzip-specific C symbol exists).
    try std.testing.expectEqual(@as(u64, 0), api.gzResidentBytes(od.doc));
    const st = api.gzCheckpointStore(od.doc);
    try std.testing.expectEqual(false, st.present);
}

test "gz_ac2: gzip opens by MAGIC not name; plain named .csv.gz stays plain" {
    const gpa = std.testing.allocator;
    const plain = "name,age\nAlice,30\nBob,25\n";
    const g = try gz(gpa, plain);
    defer gpa.free(g);

    // gzip content under `.csv`, `.gz`, and an unrelated extension all open AS
    // the decompressed CSV (magic 1f8b, not filename). RED: seed = garbage.
    for ([_][]const u8{ "data.csv", "data.gz", "export.bin" }) |sub| {
        var od = try openNamed(g, sub, manual);
        defer od.deinit();
        try std.testing.expectEqual(@as(u32, 2), api.ls_column_count(od.doc));
        winAll(od.doc);
        try expectCell(od.doc, 0, 0, "Alice");
        try expectCell(od.doc, 1, 1, "25");
    }
    // A PLAIN CSV named `.csv.gz` lacks gzip magic -> stays plain (GUARD).
    {
        var od = try openNamed(plain, "data.csv.gz", manual);
        defer od.deinit();
        try std.testing.expectEqual(@as(u32, 2), api.ls_column_count(od.doc));
        winAll(od.doc);
        try expectCell(od.doc, 0, 0, "Alice");
    }
    // Zero- and one-byte files retain existing plain behavior (GUARD).
    {
        var e = try openBytes("");
        defer e.deinit();
        try std.testing.expectEqual(@as(u32, 0), api.ls_column_count(e.doc));
        var one = try openBytes("x");
        defer one.deinit();
        try std.testing.expectEqual(@as(u32, 1), api.ls_column_count(one.doc));
    }
}

// Regression (found live 2026-07-15 via the network-source feature, opening a
// real-world CSV with no trailing newline over HTTP): the LAST row of a
// STREAMED source (gzip or http_range) with no trailing newline was wrongly
// flagged ls_row_oversized — a false positive never seen locally (mmap) since
// the whole file is small. Root cause: `Cursor.atLimit()` treated "hit the
// row-scan-budget limit" as always meaning "capped/truncated", even when that
// limit happened to coincide EXACTLY with the source's own true end (which it
// always does for the last row of a document smaller than the scan budget,
// since `posAtByteBudget` clamps to `source.knownEnd()`). The mmap path
// already got this right (`lexer.recordBounds`'s `capped = limit != content.len`);
// `atLimit()` now makes the same "limit == the source's true end -> not a cap"
// distinction, fixing gzip and http_range identically at their one shared seam.
test "gz_regression: last row with no trailing newline is never falsely oversized" {
    const gpa = std.testing.allocator;
    // No trailing "\n" after the final field — the exact trigger condition:
    // streamUnit hits genuine EOF (not a separator/terminator) while decoding
    // the last row, so `capped` is decided by the (buggy) atLimit() check.
    const plain = "name,country\nAlice,US\nBob,UK\nZoe,ZW";
    const g = try gz(gpa, plain);
    defer gpa.free(g);

    var od = try openNamed(g, "data.csv.gz", manual);
    defer od.deinit();
    try expectDims(od.doc, 3, 2);
    winAll(od.doc);
    try expectCell(od.doc, 2, 0, "Zoe");
    try expectCell(od.doc, 2, 1, "ZW");
    // The regression: the last row must NOT be reported oversized merely
    // because it lacks a trailing newline. Every row here is tiny.
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, 0));
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, 1));
    try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, 2));
}

test "gz_ac3: plain/gzip equivalence across the encoding/dialect/quote matrix (single, multi-member, BGZF)" {
    const gpa = std.testing.allocator;
    // A representative logical CSV: header, quotes + doubled quotes, embedded
    // newline, CRLF + LF, ragged rows, empty cells, invalid-UTF8 pass-through.
    const plain = "id,name,note\r\n" ++
        "1,\"a,b\",\"line\nbreak\"\r\n" ++
        "2,\"he said \"\"hi\"\"\",\r\n" ++
        "3,short\n" ++
        "4,\xff\xfe-raw,ok\n";
    const opts: api.OpenOptions = .{ .separator = ',', .index_mode = api.index_manual };

    const single = try gz(gpa, plain);
    defer gpa.free(single);
    try expectGzEquiv(plain, opts, single);

    // Adversarial member splits at several byte positions (inside a quote, a
    // CRLF, a field, a record) — all invisible to the CSV layer.
    for ([_]usize{ 1, 15, 18, 30, plain.len - 2 }) |at| {
        const ms = try gzSplit(gpa, plain, at);
        defer gpa.free(ms);
        try expectGzEquiv(plain, opts, ms);
    }
    // BGZF-style: 16-byte blocks, each a member with a "BC" extra field.
    const bg = try gzBgzf(gpa, plain, 16);
    defer gpa.free(bg);
    try expectGzEquiv(plain, opts, bg);
}

test "gz_ac4: member transparency — splits/BOM/repeated-header/missing-newline/trailing-garbage" {
    const gpa = std.testing.allocator;
    // Missing newline BETWEEN members concatenates their bytes within a field.
    {
        const a = try gzMember(gpa, "h1,h2\nval", .{}); // no trailing newline
        defer gpa.free(a);
        const b = try gzMember(gpa, "ue,x\n", .{}); // continues the field: "value"
        defer gpa.free(b);
        var ms: std.ArrayList(u8) = .empty;
        defer ms.deinit(gpa);
        try ms.appendSlice(gpa, a);
        try ms.appendSlice(gpa, b);
        try expectGzEquiv("h1,h2\nvalue,x\n", .{ .separator = ',', .index_mode = api.index_manual }, ms.items);
    }
    // A later member starting with a UTF-8 BOM: only the FIRST overall BOM is
    // stripped; a later BOM + a repeated header line are ORDINARY data.
    {
        const plain = "\xEF\xBB\xBFa,b\n1,2\n\xEF\xBB\xBFa,b\n3,4\n";
        const ms = try gzSplit(gpa, plain, 8); // split so member 2 begins at the later BOM
        defer gpa.free(ms);
        try expectGzEquiv(plain, .{ .separator = ',', .index_mode = api.index_manual }, ms);
    }
    // Trailing non-gzip bytes after a completed member are NOT appended as CSV.
    {
        const m = try gzMember(gpa, "a,b\n1,2\n", .{});
        defer gpa.free(m);
        var withjunk: std.ArrayList(u8) = .empty;
        defer withjunk.deinit(gpa);
        try withjunk.appendSlice(gpa, m);
        try withjunk.appendSlice(gpa, "TRAILING GARBAGE NOT CSV");
        try expectGzEquiv("a,b\n1,2\n", .{ .separator = ',', .index_mode = api.index_manual }, withjunk.items);
    }
}

test "gz_ac5: every gzip open consumes <= 4 MiB physical in AND <= 4 MiB inflated out" {
    const gpa = std.testing.allocator;
    // A high-expansion gzip: ~5 KB compressed, ~64 MiB logical. Open must stop
    // at 4 MiB inflated WITHOUT touching a trailer/tail page for ISIZE.
    const big = try gzHighExpansion(gpa, "aaaa,bbbb,cccc\n", (64 * 1024 * 1024) / 15);
    defer gpa.free(big);
    try std.testing.expect(big.len < 4 * 1024 * 1024); // compressed prefix is small
    var od = try openWith(big, .{ .separator = ',', .index_mode = api.index_manual });
    defer od.deinit();
    const b = api.gzOpenBudget(od.doc);
    // RED SEED: budget == {0,0}, so `> 0` fails. GREEN: bounded by BOTH ceilings.
    try std.testing.expect(b.physical_in > 0);
    try std.testing.expect(b.inflated_out > 0);
    try std.testing.expect(b.physical_in <= api.open_head_max_bytes);
    try std.testing.expect(b.inflated_out <= api.open_head_max_bytes);
    // High expansion < 4 MiB compressed is NOT fully inflated at open.
    try std.testing.expect(b.inflated_out < 64 * 1024 * 1024);
}

test "gz_ac6: 5 KB..500 GB flatness — open work is bounded, independent of size (FU + TL cold-open)" {
    const gpa = std.testing.allocator;
    const small = try gz(gpa, "a,b,c\n1,2,3\n4,5,6\n");
    defer gpa.free(small);
    const t0: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    var sm = try openWith(small, .{ .separator = ',', .index_mode = api.index_manual });
    defer sm.deinit();
    try std.testing.expect(elapsedMs(t0) < 500); // TL cold-open ceiling (generous)
    const sb = api.gzOpenBudget(sm.doc);

    // A sparse apparent-500 GB file: a small valid gzip head, then a hole.
    const head = try gz(gpa, "a,b,c\n1,2,3\n4,5,6\n");
    defer gpa.free(head);
    var fx = try makeSparseFixture(head, 500 * 1024 * 1024 * 1024);
    defer fx.deinit();
    var big_doc: ?*api.Doc = null;
    const t1: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &manual, &big_doc));
    defer api.ls_close(big_doc.?);
    try std.testing.expect(elapsedMs(t1) < 500); // TL: the 500 GB apparent size adds no open work
    const bb = api.gzOpenBudget(big_doc.?);
    // FU RED: both opens did real work bounded to the head — the apparent size
    // caused NO extra physical consumption (seed budgets are 0 -> `> 0` fails).
    try std.testing.expect(sb.physical_in > 0 and sb.physical_in <= api.open_head_max_bytes);
    try std.testing.expect(bb.physical_in > 0 and bb.physical_in <= api.open_head_max_bytes);
}

test "gz_ac7: a fully-fitting gzip is exact+complete at open; an over-4-MiB output is a usable head, inexact" {
    const gpa = std.testing.allocator;
    // Whole physical AND inflated streams fit both 4 MiB limits -> exact.
    const smallp = "a,b\n1,2\n3,4\n5,6\n";
    const smallg = try gz(gpa, smallp);
    defer gpa.free(smallg);
    var sd = try openWith(smallg, .{ .separator = ',', .index_mode = api.index_manual });
    defer sd.deinit();
    const rc = api.ls_row_count_get(sd.doc);
    try std.testing.expectEqual(true, rc.exact); // RED seed: garbage count != 3 (and content check below)
    try std.testing.expectEqual(@as(u64, 3), rc.count);
    const poll = api.ls_index_poll(sd.doc);
    try std.testing.expectEqual(true, poll.complete);

    // Output crosses 4 MiB -> usable head, INEXACT (not blocked for full inflate).
    const bigg = try gzHighExpansion(gpa, "aaaa,bbbb\n", (16 * 1024 * 1024) / 10);
    defer gpa.free(bigg);
    var bd = try openWith(bigg, .{ .separator = ',', .index_mode = api.index_manual });
    defer bd.deinit();
    try std.testing.expectEqual(false, api.ls_row_count_get(bd.doc).exact); // RED seed: small-as-plain -> exact==true
}

test "gz_ac8: RFC/member coverage — optional fields + empty/multi member; non-gzip is not misparsed" {
    const gpa = std.testing.allocator;
    const plain = "a,b\n1,2\n3,4\n";
    const opts: api.OpenOptions = .{ .separator = ',', .index_mode = api.index_manual };
    // Every supported optional header field decodes to the same logical CSV.
    const with_fields = try gzMember(gpa, plain, .{ .ftext = true, .fname = "orig.csv", .fcomment = "note", .extra = &[_]u8{ 'X', 'Y', 1, 0, 7 }, .fhcrc = true });
    defer gpa.free(with_fields);
    try expectGzEquiv(plain, opts, with_fields);
    // An EMPTY member followed by a real member (concatenated).
    {
        const empty = try gzMember(gpa, "", .{});
        defer gpa.free(empty);
        const real = try gzMember(gpa, plain, .{});
        defer gpa.free(real);
        var ms: std.ArrayList(u8) = .empty;
        defer ms.deinit(gpa);
        try ms.appendSlice(gpa, empty);
        try ms.appendSlice(gpa, real);
        try expectGzEquiv(plain, opts, ms.items);
    }
    // A non-method-8 "gzip" (CM=9) has no usable payload -> LS_ERROR_IO.
    {
        const badcm = try gzMember(gpa, plain, .{ .cm = 9 });
        defer gpa.free(badcm);
        var fx = try makeFixture(badcm, 0o644);
        defer fx.deinit();
        var doc: ?*api.Doc = null;
        // RED SEED: opened as mmap-as-plain -> .ok; GREEN: rejected .io.
        try std.testing.expectEqual(api.Status.io, api.ls_open(fx.path.ptr, &opts, &doc));
    }
}

test "gz_ac9: recovery matrix — empty/invalid/truncated/footer-mismatch/structural/budget-header" {
    const gpa = std.testing.allocator;
    const opts: api.OpenOptions = .{ .separator = ',', .index_mode = api.index_manual };
    // (a) valid EMPTY gzip -> empty document (0 columns, like an empty file).
    {
        const empty = try gzMember(gpa, "", .{});
        defer gpa.free(empty);
        var od = try openWith(empty, opts);
        defer od.deinit();
        try std.testing.expectEqual(@as(u32, 0), api.ls_column_count(od.doc)); // RED seed: ~20 garbage bytes -> >=1 col
    }
    // (b) INVALID gzip (magic, then garbage) with no payload -> LS_ERROR_IO.
    {
        const bad = [_]u8{ 0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff, 0xde, 0xad, 0xbe, 0xef };
        var fx = try makeFixture(&bad, 0o644);
        defer fx.deinit();
        var doc: ?*api.Doc = null;
        try std.testing.expectEqual(api.Status.io, api.ls_open(fx.path.ptr, &opts, &doc)); // RED seed: .ok
    }
    // (c) TRUNCATION after emitted payload (footer missing) -> the FULL emitted
    //     prefix is salvaged exactly (deterministic: all deflate bytes present,
    //     only the CRC/ISIZE footer dropped -> damaged EOF after every row).
    {
        const full = "a,b\n1,2\n3,4\n5,6\n";
        const trunc = try gzMember(gpa, full, .{ .omit_footer = true });
        defer gpa.free(trunc);
        try expectGzEquiv(full, opts, trunc); // RED seed: garbage; GREEN: salvaged == full
    }
    // (d) footer CRC mismatch keeps payload AND permits a following valid member.
    {
        const bad = try gzMember(gpa, "a,b\n1,2\n", .{ .bad_crc = true });
        defer gpa.free(bad);
        const good = try gzMember(gpa, "3,4\n", .{});
        defer gpa.free(good);
        var ms: std.ArrayList(u8) = .empty;
        defer ms.deinit(gpa);
        try ms.appendSlice(gpa, bad);
        try ms.appendSlice(gpa, good);
        try expectGzEquiv("a,b\n1,2\n3,4\n", opts, ms.items);
    }
    // (e) an optional FILENAME that consumes the whole physical head budget
    //     before any payload -> LS_ERROR_IO within the budget.
    {
        const huge = try gpa.alloc(u8, api.open_head_max_bytes + 64 * 1024);
        defer gpa.free(huge);
        @memset(huge, 'N');
        const m = try gzMember(gpa, "a,b\n1,2\n", .{ .fname = huge });
        defer gpa.free(m);
        var fx = try makeFixture(m, 0o644);
        defer fx.deinit();
        var doc: ?*api.Doc = null;
        try std.testing.expectEqual(api.Status.io, api.ls_open(fx.path.ptr, &opts, &doc)); // RED seed: .ok
    }
}

test "gz_ac10: a salvaged prefix has a deterministic immutable end (exact count, terminal poll, stable)" {
    const gpa = std.testing.allocator;
    const opts: api.OpenOptions = .{ .separator = ',', .index_mode = api.index_manual };
    const full = "a,b\n1,2\n3,4\n5,6\n";
    const trunc = try gzMember(gpa, full, .{ .truncate_payload = 6, .omit_footer = true });
    defer gpa.free(trunc);
    var od = try openWith(trunc, opts);
    defer od.deinit();
    try scanToEnd(od.doc);
    const rc = api.ls_row_count_get(od.doc);
    try std.testing.expectEqual(true, rc.exact); // salvaged prefix is EXACT for the rows it has
    const poll = api.ls_index_poll(od.doc);
    // Terminal normalization: bytes_scanned == bytes_total, complete == true.
    try std.testing.expectEqual(poll.bytes_total, poll.bytes_scanned); // RED seed: garbage/partial
    try std.testing.expectEqual(true, poll.complete);
    // Repeated access exposes no additional rows after the terminal decision.
    const rc2 = api.ls_row_count_get(od.doc);
    try std.testing.expectEqual(rc.count, rc2.count);
    try std.testing.expect(rc.count >= 1); // at least the emitted prefix
}

test "gz_ac11: row estimate/progress never use ISIZE (false/wrapped ISIZE + concatenated members)" {
    const gpa = std.testing.allocator;
    const plain = "a,b\n1,2\n3,4\n5,6\n7,8\n";
    // Deliberately FALSE / wrapped ISIZE in each member's footer.
    const m1 = try gzMember(gpa, "a,b\n1,2\n3,4\n", .{ .isize_override = 0xFFFFFFFF });
    defer gpa.free(m1);
    const m2 = try gzMember(gpa, "5,6\n7,8\n", .{ .isize_override = 7 });
    defer gpa.free(m2);
    var ms: std.ArrayList(u8) = .empty;
    defer ms.deinit(gpa);
    try ms.appendSlice(gpa, m1);
    try ms.appendSlice(gpa, m2);
    // The decoded CSV (ISIZE ignored) is byte-identical to plain; the estimate
    // collapses to the exact count at terminal EOF. RED seed: garbage.
    try expectGzEquiv(plain, .{ .separator = ',', .index_mode = api.index_manual }, ms.items);
}

test "gz_ac12: forced 1-byte/irregular chunks split every token boundary; results == mmap reference" {
    const gpa = std.testing.allocator;
    const plain = "n,v\r\n" ++
        "\"a,b\",\"x\ny\"\r\n" ++ // quote + embedded sep + embedded newline
        "alpha,3.14159e2\n" ++ // decimal token
        "beta,-0.0000000000000000000000000000000000000042\n"; // >40-digit magnitude
    const g = try gz(gpa, plain);
    defer gpa.free(g);
    var pod = try openWith(plain, .{ .separator = ',', .index_mode = api.index_manual });
    defer pod.deinit();
    var god = try openWith(g, .{ .separator = ',', .index_mode = api.index_manual });
    defer god.deinit();
    api.gzForceChunkBytes(god.doc, 1); // one inflated byte per span
    try scanToEnd(pod.doc);
    try scanToEnd(god.doc);
    try std.testing.expectEqual(api.ls_column_count(pod.doc), api.ls_column_count(god.doc));
    _ = api.ls_window_set(pod.doc, 0, api.window_max_rows);
    _ = api.ls_window_set(god.doc, 0, api.window_max_rows);
    const cols = api.ls_column_count(pod.doc);
    var r: u64 = 0;
    const n = api.ls_row_count_get(pod.doc).count;
    while (r < n) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            try std.testing.expectEqualStrings(api.ls_cell(pod.doc, r, c).slice(), api.ls_cell(god.doc, r, c).slice());
        }
    }
    // Numeric predicate + text search resolve identically under 1-byte chunking.
    try startSearch(god.doc, predReq(1, .lt, "0")); // the negative decimal row
    const gs = try waitSearchDone(god.doc);
    try std.testing.expectEqual(@as(u64, 1), gs.total);
}

test "gz_ac13: streaming match is O(query+fixed) on a giant cell; the tail match is found (no unbounded materialize)" {
    const gpa = std.testing.allocator;
    // A giant first cell (> the display cap AND > any small budget), with the
    // search needle only in its TAIL, plus a normal following row.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try plain.appendSlice(gpa, "h1,h2\n");
    var i: usize = 0;
    while (i < 2 * 1024 * 1024) : (i += 1) try plain.append(gpa, 'a');
    try plain.appendSlice(gpa, "NEEDLE,x\n");
    try plain.appendSlice(gpa, "b,y\n");
    const g = try gz(gpa, plain.items);
    defer gpa.free(g);
    var od = try openWith(g, .{ .separator = ',', .index_mode = api.index_auto });
    defer od.deinit();
    try scanToEnd(od.doc);
    api.gzStreamMatcherResidentReset(od.doc);
    try startSearch(od.doc, textReq("NEEDLE"));
    const s = try waitSearchDone(od.doc);
    try std.testing.expectEqual(@as(u64, 1), s.total); // RED seed: garbage -> not found as expected
    const resident = api.gzStreamMatcherResidentBytes(od.doc);
    // O(query + fixed state), never O(cell): RED seed reads 0 (`> 0` fails);
    // GREEN stays far below the 2 MiB cell.
    try std.testing.expect(resident > 0);
    try std.testing.expect(resident < 64 * 1024);
}

test "gz_ac14: forced inflate-checkpoint snapshot+restore is byte-identical (stored/fixed/dynamic/pending/member)" {
    const gpa = std.testing.allocator;
    // Fixtures biased toward different DEFLATE block kinds + a member boundary.
    const dynamic = try gzHighExpansion(gpa, "the quick brown fox,42,lorem ipsum dolor\n", 40000);
    defer gpa.free(dynamic);
    const twomember = try gzSplit(gpa, "col\n" ++ "aaaaaaaa\n" ** 200, 900);
    defer gpa.free(twomember);
    for ([_][]const u8{ dynamic, twomember }) |fixture| {
        for ([_]u64{ 0, 100, 40000, 250000 }) |probe| {
            const pr = api.gzSnapshotProbe(gpa, fixture, probe);
            // RED SEED: {restored=false, identical=false}. GREEN: a checkpoint
            // was taken/restored AND the restart matched uninterrupted decoding.
            try std.testing.expectEqual(true, pr.restored);
            try std.testing.expectEqual(true, pr.identical);
        }
    }
}

test "gz_ac15: behind-frontier landing restores a nonzero checkpoint and replays <= 32 MiB (heavy)" {
    const gpa = std.testing.allocator;
    // ~135 MiB logical from a tiny gzip: crosses >4 durable 32-MiB checkpoints.
    const unit = "aaaa,bbbb\n"; // 10 bytes/row
    const repeat: usize = (135 * 1024 * 1024) / 10;
    const g = try gzHighExpansion(gpa, unit, repeat);
    defer gpa.free(g);
    var od = try openWith(g, .{ .separator = ',', .index_mode = api.index_manual });
    defer od.deinit();
    try scanToEnd(od.doc); // scan past >=4 intervals, evicting hot inflated state
    // Land backward deep in an early interval (far behind the frontier).
    const target: u64 = (40 * 1024 * 1024) / 10; // ~40 MiB in -> 2nd interval
    api.gzReplayStatsReset(od.doc);
    _ = api.ls_window_set(od.doc, target, 4);
    var buf: [64]u8 = undefined;
    const cc = copyCell(od.doc, target, 0, &buf); // forces the behind-frontier decode
    try std.testing.expectEqual(api.CopyResult.ok, cc.result);
    try std.testing.expectEqualStrings("aaaa", buf[0..cc.len]); // RED seed: row out of range
    const rp = api.gzReplayStats(od.doc);
    // RED SEED: {landed=false, restored=0, replay=0}. GREEN: resumed from a
    // NONZERO nearest checkpoint, replaying at most one 32-MiB interval.
    try std.testing.expectEqual(true, rp.landed);
    try std.testing.expect(rp.restored_checkpoint_logical > 0);
    try std.testing.expect(rp.inflated_replay <= 32 * 1024 * 1024);
}

test "gz_ac16: a behind-frontier landing meets the synchronous budget (TL <100 ms) and returns correct cells" {
    const gpa = std.testing.allocator;
    const g = try gzHighExpansion(gpa, "aaaa,bbbb\n", (48 * 1024 * 1024) / 10);
    defer gpa.free(g);
    var od = try openWith(g, .{ .separator = ',', .index_mode = api.index_manual });
    defer od.deinit();
    try scanToEnd(od.doc);
    const target: u64 = (8 * 1024 * 1024) / 10;
    const t0: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    _ = api.ls_window_set(od.doc, target, 8);
    try std.testing.expect(elapsedMs(t0) < 100); // TL: landing budget (generous)
    var buf: [64]u8 = undefined;
    const cc = copyCell(od.doc, target, 1, &buf);
    try std.testing.expectEqual(api.CopyResult.ok, cc.result);
    try std.testing.expectEqualStrings("bbbb", buf[0..cc.len]); // RED seed: row out of range
}

test "gz_ac17: gzip resident state <= 16 MiB; checkpoint file is 0600, unlinked, bounded (120 MiB RSS = RM)" {
    // NOTE: the 120 MiB steady RSS on a 10 GB-class document (ARCH NFR) is
    // REVIEWER-MEASURED at build time (RM) — not a hermetic frozen unit test.
    const gpa = std.testing.allocator;
    const g = try gzHighExpansion(gpa, "aaaa,bbbb,cccc\n", (80 * 1024 * 1024) / 15);
    defer gpa.free(g);
    var od = try openWith(g, .{ .separator = ',', .index_mode = api.index_manual });
    defer od.deinit();
    try scanToEnd(od.doc); // spills checkpoints as the frontier advances
    const resident = api.gzResidentBytes(od.doc);
    try std.testing.expect(resident > 0); // RED seed: 0
    try std.testing.expect(resident <= 16 * 1024 * 1024);
    const st = api.gzCheckpointStore(od.doc);
    try std.testing.expectEqual(true, st.present); // RED seed: false
    try std.testing.expectEqual(@as(u32, 0o600), st.mode);
    try std.testing.expectEqual(true, st.unlinked); // already unlinked while open
    // <= 0.25% of inflated bytes + fixed overhead (inflated ~80 MiB here).
    try std.testing.expect(st.bytes <= (80 * 1024 * 1024) / 400 + 1024 * 1024);
}

test "gz_ac18: injected checkpoint-store failure keeps usable content, stays <=16 MiB, terminates cleanly" {
    const gpa = std.testing.allocator;
    const g = try gzHighExpansion(gpa, "aaaa,bbbb\n", (40 * 1024 * 1024) / 10);
    defer gpa.free(g);
    var od = try openWith(g, .{ .separator = ',', .index_mode = api.index_manual });
    defer od.deinit();
    api.gzCheckpointStoreFailAfter(od.doc, 0); // fail the very first store op
    try scanToEnd(od.doc);
    // Memory-only mode within the SAME 16 MiB ceiling; terminates at the last
    // replay-safe prefix with the AC10 terminal completion behavior.
    try std.testing.expect(api.gzResidentBytes(od.doc) <= 16 * 1024 * 1024);
    const poll = api.ls_index_poll(od.doc);
    try std.testing.expectEqual(true, poll.complete); // terminal
    try std.testing.expectEqual(poll.bytes_total, poll.bytes_scanned);
    // Content already produced stays usable + correct.
    _ = api.ls_window_set(od.doc, 0, 4);
    var buf: [64]u8 = undefined;
    const cc = copyCell(od.doc, 0, 0, &buf);
    try std.testing.expectEqual(api.CopyResult.ok, cc.result);
    try std.testing.expectEqualStrings("aaaa", buf[0..cc.len]); // RED seed: garbage cell
}

test "gz_ac19: concurrent AUTO scan + window + background copy over a gzip yields reference-equal data" {
    const gpa = std.testing.allocator;
    const plain = try genFixedRows(gpa, 8_000); // deterministic "{i:0>8},{2i:0>8}"
    defer gpa.free(plain);
    const g = try gz(gpa, plain);
    defer gpa.free(g);
    var pod = try openWith(plain, manual);
    defer pod.deinit();
    try scanToEnd(pod.doc);
    var god = try openWith(g, .{ .index_mode = api.index_auto }); // background worker scans
    defer god.deinit();
    // Interleave window changes + full-cell copies WHILE the worker inflates —
    // exercising the lease/borrow rules without a deadlock or torn read.
    var it: u64 = 0;
    var pbuf: [32]u8 = undefined;
    var gbuf: [32]u8 = undefined;
    while (it < 200) : (it += 1) {
        const row = (it * 37) % 8_000;
        _ = api.ls_window_set(god.doc, row, 8);
        const a = copyCell(pod.doc, row, 1, &pbuf);
        const b = copyCell(god.doc, row, 1, &gbuf);
        if (b.result == .pending) continue; // frontier not there yet; retry later
        try std.testing.expectEqual(a.result, b.result);
        try std.testing.expectEqualSlices(u8, pbuf[0..a.len], gbuf[0..b.len]); // RED seed: garbage
    }
    // Close during active inflation is safe (no hang / no double-unmap).
    var closing = try openWith(g, .{ .index_mode = api.index_auto });
    api.ls_close(closing.doc);
    closing.fx.deinit();
}

test "gz_ac20: plain-CSV mmap fast path is unaffected — zero gzip state, direct spans (GUARD; throughput/RSS = RM)" {
    // NOTE: the "median window/search/filter throughput <= 5% slower than the
    // pre-csv-gz commit" and "steady RSS grows <= 5 MB" NFRs are REVIEWER-
    // MEASURED at build time across >=5 release runs (RM) — not frozen units.
    // Here we GUARD the structural invariant: a plain document allocates ZERO
    // gzip-specific state and copies ZERO bytes through any cache (direct
    // spans). This stays GREEN through the build (it must never regress).
    const gpa = std.testing.allocator;
    const plain = try genFixedRows(gpa, 5_000);
    defer gpa.free(plain);
    var od = try openBytes(plain);
    defer od.deinit();
    try scanToEnd(od.doc);
    _ = api.ls_window_set(od.doc, 100, 64);
    var buf: [32]u8 = undefined;
    _ = copyCell(od.doc, 100, 0, &buf);
    try startSearch(od.doc, predReq(0, .ge, "00000000"));
    _ = try waitSearchDone(od.doc);
    try setFilter(od.doc, textReq("0"));
    _ = try waitFilterDone(od.doc);
    try std.testing.expectEqual(@as(u64, 0), api.gzResidentBytes(od.doc)); // no gzip state on the mmap path
    try std.testing.expectEqual(@as(u64, 0), api.gzCacheCopyBytes(od.doc)); // direct spans, never via a cache
}

test "gz_ac21: the physical gzip source is never modified, locked, renamed, or copied wholesale (GUARD)" {
    const gpa = std.testing.allocator;
    const g = try gz(gpa, "a,b,c\n1,2,3\n4,5,6\n7,8,9\n");
    defer gpa.free(g);
    const before = std.hash.Crc32.hash(g);
    var fx = try makeFixture(g, 0o644);
    defer fx.deinit();
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &manual, &doc));
    {
        defer api.ls_close(doc.?);
        try scanToEnd(doc.?);
        _ = api.ls_window_set(doc.?, 0, 8);
        var buf: [32]u8 = undefined;
        _ = copyCell(doc.?, 0, 0, &buf);
    }
    // Re-read the source file and confirm byte-identical (never written).
    const reread = try fx.tmp.dir.readFileAlloc(std.testing.io, "fixture.csv", gpa, std.Io.Limit.limited(1 << 20));
    defer gpa.free(reread);
    try std.testing.expectEqual(before, std.hash.Crc32.hash(reread));
    try std.testing.expectEqualSlices(u8, g, reread);
}

test "gz_ac22: uses ONLY the pinned Zig-0.16 std gzip decoder — no runtime dependency (GUARD; size = RM)" {
    // NOTE: single-digit-MB assembled binary size is REVIEWER-MEASURED (RM).
    // GUARD (comptime): the std gzip decoder/encoder the feature builds on are
    // present in the pinned toolchain — no vendored compression dependency.
    comptime {
        if (!@hasDecl(std.compress.flate, "Decompress")) @compileError("std.compress.flate.Decompress missing");
        if (!@hasDecl(std.compress.flate, "Compress")) @compileError("std.compress.flate.Compress missing");
    }
    // The value-copy snapshot adapter the checkpoint feature relies on compiles
    // against the installed std (mirrors the frozen contract's shape pin).
    var in: std.Io.Reader = .fixed(&[_]u8{ 0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff });
    var hist: [flate.max_window_len]u8 = undefined;
    const dec_a = flate.Decompress.init(&in, .gzip, &hist);
    const dec_b = dec_a; // value copy => snapshottable
    try std.testing.expect(@TypeOf(dec_b) == flate.Decompress);
}


// ===========================================================================
// window-budget slice (ARCH-window-budget). Frozen; planner-owned. Bounds the
// SYNCHRONOUS work of ls_window_set to a fixed 8 MiB (8,388,608-byte) aggregate
// charged-work ceiling and repairs the filtered ls_search_nav lane (backlog #6),
// BOTH behind a BYTE-IDENTICAL api/lesssheet.h (AC1): a budget-truncated window
// returns a shorter contiguous ls_row_range (completed prefix; suffix pending),
// REUSING the existing short-range signal -- no new ABI flag -- and ls_row_oversized
// keeps its narrower per-row (>1 MiB) meaning. Tests use the PUBLIC C ABI via
// @import("api") PLUS the Zig-only charged-work seams (windowChargedBytes /
// navChargedBytes -- NOT the C ABI, like copyAdvances / gz*).
//
// AC -> test map:
//   AC1  frozen surface ......... wb_ac1  (GUARD: 8 MiB pin + seams link; root gate covers the header)
//   AC2  exact 8 MiB accounting . wb_ac2  (mmap + gzip + filtered: charged>0 AND <=8 MiB)          [RED]
//   AC3  short-prefix result .... wb_ac3  (contiguous prefix; first unreturned row ABSENT, unflagged) [RED]
//   AC4  monotone retry .......... wb_ac4  (grows to full; no livelock; no completed-work re-scan)    [RED]
//   AC5  eviction + borrows ...... wb_ac5  (identical reuse + changed request re-derive byte-identical) [RED]
//   AC6  caps stay distinct ...... wb_ac6  (>1 MiB oversized vs aggregate-cut normal row absent+unflagged) [RED]
//   AC7  frontend pending flow ... (macOS ViewerModel MODEL test -- NOT a backend unit; see apps/macos)
//   AC8  window work bound ....... wb_ac8  (WORK proxy <=8 MiB, flat as rows grow; skip charged; wall-clock=RM) [RED]
//   AC9  normal-window regression  wb_ac9  (a normal viewport fills in ONE call; order/cells unchanged) [RED]
//   AC10 mmap fast path .......... wb_ac10 (byte-identical output; charged>0; zero cache-copy; dispatch=RM) [RED]
//   AC11 committed #6 proof ...... wb_ac11 (giants crossed by filtered nav; fwd/back FOUND/EXHAUSTED, tail, position) [RED]
//   AC12 #6 pass/fix branch ...... wb_ac12 (frozen OFF-MAIN branch: SEARCHING + worker resolves; replace/cancel/concurrent) [RED]
//   AC13 no dependency/storage ... wb_ac13 (retries leak nothing; source read-only; deps frozen by the freeze) [GUARD]
//
// #6 FROZEN BRANCH (ARCH criterion 12 / Decision 5). The planner has DETERMINED
// the synchronous filtered-nav lane is NOT provably bounded: nav.relexBlock /
// countInBlockUpTo re-lex a whole checkpoint block (up to checkpoint_interval ==
// 2048 rows) of possibly-giant rows synchronously under the document lock with an
// UNBOUNDED DualLimit (contrast window.windowSetFiltered, which is per-row capped
// -- yet even a per-row cap leaves a 2048-row block at up to ~2 GiB). So criterion
// 11 is RED and the frozen behavior is the criterion-12 REPAIR: ls_search_nav
// returns PROMPTLY with LS_SEARCH_NAV_SEARCHING (bounded synchronous work) and the
// existing search worker resolves the exact FOUND/EXHAUSTED off-main, outside the
// short commit lock (FR11: a background giant-row parse never makes a concurrent
// ls_window_set / poll wait). Should the implementer instead PROVE a finite
// synchronous bound, relaxing this contract is a two-key CHANGE-REQUEST, not a
// free change.
//
// RED SEED: ls_window_set / filtered ls_search_nav keep TODAY's UNBOUNDED behavior
// (return the full window / resolve nav synchronously) and the two charged-work
// seams read DEFAULTED base.Document state == 0. So: short-prefix / grows-on-retry
// / deferred-SEARCHING assertions FAIL (the seed returns everything at once /
// resolves synchronously), and charged>0 clauses FAIL at 0. GREEN needs the
// aggregate meter + request-local continuation (window.zig / base.zig) and the
// bounded/off-main filtered nav (nav.zig / search.zig), wiring both counters.
// Fixtures keep giant/near-cap rows just over/under the 1 MiB per-row cap so the
// RED seed still completes each in ~ms (like the hr*/hrf* fixtures): the tests
// pin the WORK model + its short-range consequences, never wall-clock.
// ---------------------------------------------------------------------------

/// A source row whose extent is JUST UNDER the per-row scan cap
/// (LS_WINDOW_ROW_SCAN_MAX_BYTES == 1 MiB): a NORMAL row (fully materialized, NOT
/// oversized) that still costs ~0.94 MiB of charged window work, so a handful blow
/// past the 8 MiB aggregate ceiling while each stays cheap enough for the RED seed
/// to materialize in ~ms.
const wb_near_cap_bytes: usize = @intCast(api.window_row_scan_max_bytes - 64 * 1024);

/// `n` two-column near-cap rows under header "k,v": col 0 is ~wb_near_cap_bytes of
/// filler 'a' (display-capped when served, but < the 1 MiB per-row cap so col 1 is
/// still reachable), col 1 is the decimal "{i}" (a small, deterministic checkable
/// cell). Bigger than the O(head) budget, so a test scanToEnd()s to index every
/// row behind the frontier before windowing. Caller frees.
fn genNearCapRows(gpa: std.mem.Allocator, n: u64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "k,v\n");
    const blob = try gpa.alloc(u8, wb_near_cap_bytes);
    defer gpa.free(blob);
    @memset(blob, 'a');
    var line: [24]u8 = undefined;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try buf.appendSlice(gpa, blob); // col 0: ~0.94 MiB filler -> NORMAL (< 1 MiB cap)
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&line, ",{d}\n", .{i})); // col 1: "{i}"
    }
    return buf.toOwnedSlice(gpa);
}

/// Approx source bytes of ONE genNearCapRows row (filler + ",{i}\n"; the decimal
/// tail is 3-4 bytes -- close enough for the linear no-re-scan ceiling in wb_ac4).
const wb_row_source: u64 = wb_near_cap_bytes + 4;

test "wb_ac1: the 8 MiB ceiling is pinned and the charged-work seams link (GUARD)" {
    // NOT the C ABI: the root gate proves api/lesssheet.h byte-identical; here we
    // pin the frozen aggregate number + that the Zig-only seams are callable and
    // total (they only rise once the meter fires). Green from the seed; must stay.
    try std.testing.expectEqual(@as(u64, 8_388_608), api.window_budget_max_bytes);
    var od = try openBytes("k,v\nx,y\n");
    defer od.deinit();
    winAll(od.doc);
    _ = api.windowChargedBytes(od.doc); // links + total
    try std.testing.expectEqual(@as(u64, 0), api.navChargedBytes(od.doc)); // no nav yet
}

test "wb_ac2: every ls_window_set charges >0 and <= 8 MiB across mmap, gzip, and filtered paths (ARCH AC2)" {
    const gpa = std.testing.allocator;
    // (a) mmap identity near-cap window (fits under one 8 MiB call).
    {
        const fixture = try genNearCapRows(gpa, 6); // ~5.6 MiB
        defer gpa.free(fixture);
        var od = try openBytes(fixture);
        defer od.deinit();
        try scanToEnd(od.doc);
        _ = api.ls_window_set(od.doc, 0, 6);
        const charged = api.windowChargedBytes(od.doc);
        try std.testing.expect(charged > 0); // RED seed: 0
        try std.testing.expect(charged <= api.window_budget_max_bytes);
    }
    // (b) gzip: charged is measured at the LOGICAL inflated-source layer, so the
    // SAME ceiling and meaning hold for a .csv.gz window.
    {
        const plain = try genNearCapRows(gpa, 4);
        defer gpa.free(plain);
        const g = try gz(gpa, plain);
        defer gpa.free(g);
        var od = try openWith(g, .{ .separator = ',', .index_mode = api.index_manual });
        defer od.deinit();
        try scanToEnd(od.doc);
        _ = api.ls_window_set(od.doc, 0, 4);
        const charged = api.windowChargedBytes(od.doc);
        try std.testing.expect(charged > 0); // RED seed: 0
        try std.testing.expect(charged <= api.window_budget_max_bytes);
    }
    // (c) filtered near-cap window: the match-TEST plus the display re-materialize
    // is a DOUBLE pass over each matched row, charged twice -- yet still bounded by
    // the SAME ceiling (which is exactly what shortens the filtered prefix).
    {
        const fixture = try genNearCapRows(gpa, 4);
        defer gpa.free(fixture);
        var od = try openWith(fixture, .{ .index_mode = api.index_auto });
        defer od.deinit();
        try setFilter(od.doc, textReq("a")); // col-0 filler -> every row matches
        try std.testing.expectEqual(@as(u64, 4), (try waitFilterDone(od.doc)).total);
        _ = api.ls_window_set(od.doc, 0, 4);
        const charged = api.windowChargedBytes(od.doc);
        try std.testing.expect(charged > 0); // RED seed: 0
        try std.testing.expect(charged <= api.window_budget_max_bytes);
    }
}

test "wb_ac3: a window over > 8 MiB of rows returns a SHORT contiguous prefix; the suffix is absent, not blank (ARCH AC3)" {
    const gpa = std.testing.allocator;
    const n: u64 = 12; // ~11.3 MiB -> one 8 MiB call cannot hold all 12 near-cap rows
    const fixture = try genNearCapRows(gpa, n);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);
    try expectDims(od.doc, n, 2);

    const r = api.ls_window_set(od.doc, 0, @intCast(n));
    // A short contiguous prefix beginning at the requested row (RED seed: all n).
    try std.testing.expectEqual(@as(u64, 0), r.first_row);
    try std.testing.expect(r.row_count >= 1); // >=1 fits (per-row cap < aggregate cap)
    try std.testing.expect(r.row_count < n); // ... but NOT the whole > 8 MiB window
    try std.testing.expect(api.windowChargedBytes(od.doc) <= api.window_budget_max_bytes);
    // Every RETURNED row is correct + NOT oversized (a near-cap row is normal;
    // aggregate exhaustion ALONE never sets ls_row_oversized).
    var buf: [24]u8 = undefined;
    var i: u64 = 0;
    while (i < r.row_count) : (i += 1) {
        try expectCell(od.doc, i, 1, try std.fmt.bufPrint(&buf, "{d}", .{i}));
        try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, i));
        try std.testing.expectEqual(i, api.ls_source_row(od.doc, i));
    }
    // The FIRST unreturned row is ABSENT -- not a row of empty cells: ls_cell is
    // empty AND ls_source_row is the no-row sentinel (outside the served window).
    try std.testing.expectEqual(@as(usize, 0), api.ls_cell(od.doc, r.row_count, 0).slice().len);
    try std.testing.expectEqual(api.no_row, api.ls_source_row(od.doc, r.row_count));
}

test "wb_ac4: identical retries grow the prefix monotonically to the full range with no re-scan or livelock (ARCH AC4)" {
    const gpa = std.testing.allocator;
    const n: u64 = 20; // ~18.8 MiB -> at least 3 budget-bounded calls to fill
    const fixture = try genNearCapRows(gpa, n);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);

    const first = api.ls_window_set(od.doc, 0, @intCast(n));
    try std.testing.expect(first.row_count < n); // RED seed: returns all n at once
    var prev: u64 = first.row_count;
    var total_charged: u64 = api.windowChargedBytes(od.doc);
    var calls: u32 = 1;
    // Repeating the IDENTICAL request grows the returned count monotonically and
    // fills the whole range within a finite number of calls.
    while (prev < n) {
        const r = api.ls_window_set(od.doc, 0, @intCast(n));
        try std.testing.expect(r.row_count >= prev); // monotone non-decreasing
        try std.testing.expect(api.windowChargedBytes(od.doc) <= api.window_budget_max_bytes);
        total_charged += api.windowChargedBytes(od.doc);
        prev = r.row_count;
        calls += 1;
        try std.testing.expect(calls <= 64); // NO LIVELOCK: a finite call budget fills it
    }
    try std.testing.expectEqual(n, prev);
    // The whole range is byte-identical to a single (uncapped) read.
    var buf: [24]u8 = undefined;
    var i: u64 = 0;
    while (i < n) : (i += 1) try expectCell(od.doc, i, 1, try std.fmt.bufPrint(&buf, "{d}", .{i}));
    // NO completed-work re-scan: total charged to fill stays near the range's ONE-
    // pass source size plus at most one restarted per-row op per call (ARCH: "an
    // unfinished boundary operation may be restarted"). Re-scanning the completed
    // prefix each call would be quadratic (>> this bound) and would in fact
    // livelock -- caught above.
    const bound: u64 = n * wb_row_source + @as(u64, calls) * api.window_row_scan_max_bytes;
    try std.testing.expect(total_charged <= bound);
}

test "wb_ac5: a changed request evicts and re-derives byte-identical; identical reuse refreshes borrows (ARCH AC5)" {
    const gpa = std.testing.allocator;
    const n: u64 = 12;
    const fixture = try genNearCapRows(gpa, n);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);

    // Identical retries: an earlier prefix row keeps serving byte-identical col-1
    // text as the prefix grows (borrows re-derived each call; no stale bytes).
    const first = api.ls_window_set(od.doc, 0, @intCast(n));
    try std.testing.expect(first.row_count < n); // RED seed: full window
    try expectCell(od.doc, 0, 1, "0");
    _ = api.ls_window_set(od.doc, 0, @intCast(n)); // identical -> resume + grow
    try expectCell(od.doc, 0, 1, "0"); // row 0 still correct after reuse

    // A DIFFERENT request evicts the continuation; a return re-derives identical
    // cells from the immutable source (existing eviction semantics preserved).
    _ = api.ls_window_set(od.doc, 3, 2);
    try expectCell(od.doc, 3, 1, "3");
    _ = api.ls_window_set(od.doc, 0, @intCast(n)); // back to the original range
    try expectCell(od.doc, 0, 1, "0");
}

test "wb_ac6: aggregate exhaustion and the per-row 1 MiB cap stay distinct (ARCH AC6)" {
    const gpa = std.testing.allocator;
    // 12 NORMAL near-cap rows (~11.3 MiB > 8 MiB), then ONE genuinely oversized
    // (> 1 MiB) row.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "k,v\n");
    const normal = try gpa.alloc(u8, wb_near_cap_bytes);
    defer gpa.free(normal);
    @memset(normal, 'a');
    const big = try gpa.alloc(u8, hr_over_cap_bytes); // > the 1 MiB per-row cap
    defer gpa.free(big);
    @memset(big, 'X');
    var line: [24]u8 = undefined;
    var i: u64 = 0;
    while (i < 12) : (i += 1) {
        try buf.appendSlice(gpa, normal);
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&line, ",{d}\n", .{i}));
    }
    try buf.appendSlice(gpa, big); // row 12: genuinely oversized
    try buf.appendSlice(gpa, ",TAIL\n");

    var od = try openBytes(buf.items);
    defer od.deinit();
    try scanToEnd(od.doc);
    try expectDims(od.doc, 13, 2);

    // A whole-doc window: the aggregate cap cuts among the NORMAL rows BEFORE the
    // oversized one, so it is absent and NO returned row is flagged oversized
    // merely because the budget fired (RED seed: returns all 13, incl the flagged
    // oversized row).
    const r = api.ls_window_set(od.doc, 0, 13);
    try std.testing.expect(r.row_count < 13);
    var j: u64 = 0;
    while (j < r.row_count) : (j += 1) try std.testing.expectEqual(false, api.ls_row_oversized(od.doc, j));

    // Retrying the identical request eventually reaches the oversized row: it IS
    // present as a bounded prefix and flagged -- the per-row cap, distinct from the
    // aggregate budget. LS_CELL_MAX_BYTES truncation stays byte-identical.
    var guard: u32 = 0;
    while (api.ls_source_row(od.doc, 12) == api.no_row) {
        _ = api.ls_window_set(od.doc, 0, 13);
        guard += 1;
        try std.testing.expect(guard <= 64);
    }
    try std.testing.expectEqual(true, api.ls_row_oversized(od.doc, 12));
    try std.testing.expectEqual(true, api.ls_cell_truncated(od.doc, 12, 0));
}

test "wb_ac8: synchronous window work stays <= 8 MiB and flat as the fixture grows; skips are charged (ARCH AC8 work proxy)" {
    // The wall-clock ceiling (release <500 ms, target <=100 ms on Apple Silicon) is
    // a target-host reviewer probe; the DETERMINISTIC gate proxy is the 8 MiB
    // charged-work bound -- verified here to NOT grow with row count.
    const gpa = std.testing.allocator;
    for ([_]u64{ 12, 24 }) |n| {
        const fixture = try genNearCapRows(gpa, n);
        defer gpa.free(fixture);
        var od = try openBytes(fixture);
        defer od.deinit();
        try scanToEnd(od.doc);
        const r = api.ls_window_set(od.doc, 0, @intCast(n));
        try std.testing.expect(r.row_count < n); // RED seed: full
        const charged = api.windowChargedBytes(od.doc);
        try std.testing.expect(charged > 0); // RED seed: 0
        try std.testing.expect(charged <= api.window_budget_max_bytes); // flat, independent of n
    }
    // A large checkpoint SKIP is charged and bounded too: a window whose first row
    // sits ~11 MiB of source past its (row-0) checkpoint spends the budget skipping
    // and returns ZERO new rows on the first call -- the continuation retains that
    // forward progress (RED seed: skips unbounded, then returns rows 12..15).
    {
        const n: u64 = 16; // rows 0..15 all in checkpoint block 0 (< 2048)
        const fixture = try genNearCapRows(gpa, n);
        defer gpa.free(fixture);
        var od = try openBytes(fixture);
        defer od.deinit();
        try scanToEnd(od.doc);
        const r = api.ls_window_set(od.doc, 12, 4); // skip rows 0..12 (~11.3 MiB) > 8 MiB
        try std.testing.expectEqual(@as(u64, 0), r.row_count);
        try std.testing.expect(api.windowChargedBytes(od.doc) <= api.window_budget_max_bytes);
    }
}

test "wb_ac9: a normal small-row viewport fills in ONE call; row order and cells unchanged (ARCH AC9)" {
    const gpa = std.testing.allocator;
    const n: u64 = 5_000; // small 18-byte rows; a 4096-row viewport is ~72 KiB of work
    const fixture = try genFixedRows(gpa, n);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);
    // A full scroll-buffer request fills in a SINGLE call -- the aggregate cap never
    // fires for a normal viewport (guard: must stay GREEN through the build).
    const r = api.ls_window_set(od.doc, 0, api.window_max_rows);
    try std.testing.expectEqual(@as(u64, api.window_max_rows), r.row_count);
    const charged = api.windowChargedBytes(od.doc);
    try std.testing.expect(charged > 0); // RED seed: 0
    try std.testing.expect(charged <= api.window_budget_max_bytes);
    var b0: [8]u8 = undefined;
    var b1: [8]u8 = undefined;
    try expectCell(od.doc, 4095, 0, fixedCell(&b0, 4095));
    try expectCell(od.doc, 4095, 1, fixedCell(&b1, 2 * 4095));
}

test "wb_ac10: the mmap fast path is preserved -- byte-identical output, zero cache-copy, metered (ARCH AC10)" {
    // Throughput (<=5% regression) + no per-byte dynamic dispatch are REVIEWER-
    // MEASURED (RM); here we GUARD the structural invariants + that the meter works
    // on mmap.
    const gpa = std.testing.allocator;
    const n: u64 = 10;
    const fixture = try genNearCapRows(gpa, n);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);
    const r = api.ls_window_set(od.doc, 0, @intCast(n));
    // The meter accounts on the mmap path (RED seed: 0) ...
    try std.testing.expect(api.windowChargedBytes(od.doc) > 0);
    // ... WITHOUT copying source bytes through any staging cache (direct spans):
    // reuse the csv-gz proxies, which are 0 for the mmap specialization.
    try std.testing.expectEqual(@as(u64, 0), api.gzCacheCopyBytes(od.doc));
    try std.testing.expectEqual(@as(u64, 0), api.gzResidentBytes(od.doc));
    // Returned-prefix output is byte-identical (col 1 is deterministic).
    var buf: [24]u8 = undefined;
    var i: u64 = 0;
    while (i < r.row_count) : (i += 1) try expectCell(od.doc, i, 1, try std.fmt.bufPrint(&buf, "{d}", .{i}));
}

/// Append ONE giant data row: col 0 is `size` filler bytes (> the 1 MiB per-row
/// cap when `size` is chosen so). `needle_in_prefix` puts "needle" in col 0 (a
/// prefix match, visible in a bounded read); otherwise col 1 == "needle" -- a
/// TAIL match past the cap that only the FULL-cell background scan can find.
fn appendGiantRowSized(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), size: usize, needle_in_prefix: bool) !void {
    const blob = try gpa.alloc(u8, size);
    defer gpa.free(blob);
    @memset(blob, 'X');
    if (needle_in_prefix) try buf.appendSlice(gpa, "needle");
    try buf.appendSlice(gpa, blob);
    try buf.appendSlice(gpa, if (needle_in_prefix) ",TAIL\n" else ",needle\n");
}

/// A filtered-nav #6 fixture: tiny match "m0", then `ngiant` giant rows each
/// matching "needle" (alternating prefix-match / tail-match-past-the-cap), then a
/// tiny match "mZ". Under filter "needle" the filtered view is
/// [m0, giant0..giant(ngiant-1), mZ] (filter_total == ngiant + 2). All rows sit in
/// checkpoint block 0 (ngiant + 2 << 2048), so a filtered ls_search_nav whose
/// answer lies past the giants must re-lex ACROSS them from the block-0 checkpoint
/// -- the unbounded synchronous work #6 repairs. Caller frees.
fn genGiantNavDoc(gpa: std.mem.Allocator, giant: usize, ngiant: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "k,v\n");
    try buf.appendSlice(gpa, "m0,needle\n"); // filtered 0 (tiny)
    var j: usize = 0;
    while (j < ngiant) : (j += 1) try appendGiantRowSized(gpa, &buf, giant, j % 2 == 0);
    try buf.appendSlice(gpa, "mZ,needle\n"); // filtered ngiant+1 (tiny)
    return buf.toOwnedSlice(gpa);
}

test "wb_ac11: filtered ls_search_nav crossing giant rows resolves the exact FOUND/EXHAUSTED result off-main (ARCH AC11, #6)" {
    const gpa = std.testing.allocator;
    const ngiant: usize = 8; // ~8.8 MiB of giants crossed (> the 8 MiB synchronous ceiling)
    const g = try genGiantNavDoc(gpa, hr_over_cap_bytes, ngiant);
    defer gpa.free(g);
    var od = try openWith(g, .{ .index_mode = api.index_auto });
    defer od.deinit();
    const last: u64 = ngiant + 1; // filtered index of "mZ"
    const total: u64 = ngiant + 2; // filter_total

    try setFilter(od.doc, textReq("needle"));
    try std.testing.expectEqual(total, (try waitFilterDone(od.doc)).total); // giants counted full-cell
    try startSearch(od.doc, textReq("needle")); // every filtered row is a find match
    try std.testing.expectEqual(total, (try waitSearchDone(od.doc)).total);

    // FORWARD from an anchor PAST the giants: resolving must re-lex across all
    // giants from the block-0 checkpoint. The GREEN repair returns PROMPTLY with
    // SEARCHING (RED seed: it re-lexes synchronously and resolves in-call, so the
    // immediate poll already reads FOUND), then the worker publishes the exact
    // filtered row + 1-based position; the synchronous portion stays bounded.
    api.ls_search_nav(od.doc, last, .forward);
    try std.testing.expectEqual(api.SearchNavState.searching, api.ls_search_poll(od.doc).nav);
    try std.testing.expect(api.navChargedBytes(od.doc) <= api.window_budget_max_bytes);
    try expectFound(try waitNavTerminal(od.doc), last, 1, total);

    // BACKWARD from past-the-end: the LAST match (filtered `last`) -- also crosses
    // the giants; exact row + position.
    api.ls_search_nav(od.doc, total, .backward);
    try std.testing.expect(api.navChargedBytes(od.doc) <= api.window_budget_max_bytes);
    try expectFound(try waitNavTerminal(od.doc), last, 1, total);

    // A giant TAIL match (needle past the 1 MiB cap) is a real, navigable filtered
    // row: forward from filtered 1 finds the next match, never decided on a prefix.
    api.ls_search_nav(od.doc, 1, .forward);
    const tail = try waitNavTerminal(od.doc);
    try std.testing.expectEqual(api.SearchNavState.found, tail.nav);
    try std.testing.expectEqual(@as(u64, 1), tail.found_row);

    // EXHAUSTED that crosses giants: search "m0" (only filtered 0 matches), then
    // forward from filtered 1 must re-lex [1, end) across the giants to confirm no
    // later match, still bounded.
    try startSearch(od.doc, textReq("m0"));
    _ = try waitSearchDone(od.doc);
    api.ls_search_nav(od.doc, 1, .forward);
    try std.testing.expect(api.navChargedBytes(od.doc) <= api.window_budget_max_bytes);
    try std.testing.expectEqual(api.SearchNavState.exhausted, (try waitNavTerminal(od.doc)).nav);

    // Giant-row-length INDEPENDENCE (bound, NOT linear re-lex): DOUBLING every
    // giant does not grow the synchronous nav work -- it stays <= the ceiling even
    // though the crossing is now ~17.6 MiB (a linear re-lex would ~double it).
    const g2 = try genGiantNavDoc(gpa, 2 * hr_over_cap_bytes, ngiant);
    defer gpa.free(g2);
    var od2 = try openWith(g2, .{ .index_mode = api.index_auto });
    defer od2.deinit();
    try setFilter(od2.doc, textReq("needle"));
    _ = try waitFilterDone(od2.doc);
    try startSearch(od2.doc, textReq("needle"));
    _ = try waitSearchDone(od2.doc);
    api.ls_search_nav(od2.doc, last, .forward);
    try std.testing.expect(api.navChargedBytes(od2.doc) <= api.window_budget_max_bytes);
    try expectFound(try waitNavTerminal(od2.doc), last, 1, total);
}

test "wb_ac12: the #6 off-main nav supersedes/cancels and never blocks a concurrent window/poll (ARCH AC12, #6)" {
    const gpa = std.testing.allocator;
    const ngiant: usize = 8;
    const g = try genGiantNavDoc(gpa, hr_over_cap_bytes, ngiant);
    defer gpa.free(g);
    var od = try openWith(g, .{ .index_mode = api.index_auto });
    defer od.deinit();
    const last: u64 = ngiant + 1;
    const total: u64 = ngiant + 2;
    try setFilter(od.doc, textReq("needle"));
    _ = try waitFilterDone(od.doc);
    try startSearch(od.doc, textReq("needle"));
    _ = try waitSearchDone(od.doc);

    // A crossing nav defers OFF-MAIN (RED seed: resolves synchronously to FOUND).
    api.ls_search_nav(od.doc, last, .forward);
    try std.testing.expectEqual(api.SearchNavState.searching, api.ls_search_poll(od.doc).nav);

    // While that nav is pending, a concurrent ls_window_set + ls_index_poll return
    // promptly with correct data (FR11: a background giant-row parse never makes the
    // window/poll lane wait behind it -- the source parse is outside the commit lock).
    const w = api.ls_window_set(od.doc, 0, 4);
    try std.testing.expect(w.row_count >= 1);
    try std.testing.expectEqual(@as(u64, 0), api.ls_source_row(od.doc, 0)); // filtered 0 == source 0 ("m0")
    _ = api.ls_index_poll(od.doc);
    try expectFound(try waitNavTerminal(od.doc), last, 1, total);

    // REPLACEMENT: a second nav supersedes a pending one; the final result is the
    // REPLACEMENT's answer (both cross giants; here both resolve to the last match).
    api.ls_search_nav(od.doc, last, .forward);
    api.ls_search_nav(od.doc, total, .backward); // supersedes the pending forward
    try expectFound(try waitNavTerminal(od.doc), last, 1, total);

    // CANCEL resolves a pending nav to NONE (existing terminal rule; no stale
    // worker result publishes afterward).
    api.ls_search_nav(od.doc, last, .forward);
    api.ls_search_cancel(od.doc);
    try std.testing.expectEqual(api.SearchNavState.none, api.ls_search_poll(od.doc).nav);
}

test "wb_ac13: window retries add no leak and never touch the source file (ARCH AC13)" {
    // The dependency manifest (build.zig) is unchanged -- enforced by the FREEZE,
    // not a runtime check. Here: bounded retained continuation state is released on
    // close (the testing allocator fails on any leak) and the source stays read-only.
    const gpa = std.testing.allocator;
    const fixture = try genNearCapRows(gpa, 16);
    defer gpa.free(fixture);
    const before = std.hash.Crc32.hash(fixture);
    var fx = try makeFixture(fixture, 0o644);
    defer fx.deinit();
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &manual, &doc));
    {
        defer api.ls_close(doc.?);
        try scanToEnd(doc.?);
        var k: u32 = 0;
        while (k < 8) : (k += 1) _ = api.ls_window_set(doc.?, 0, 16); // identical retries
        _ = api.ls_window_set(doc.?, 4, 4); // a different request (evict)
    }
    const reread = try fx.tmp.dir.readFileAlloc(std.testing.io, "fixture.csv", gpa, std.Io.Limit.limited(64 * 1024 * 1024));
    defer gpa.free(reread);
    try std.testing.expectEqual(before, std.hash.Crc32.hash(reread)); // source never written
}


// ===========================================================================
// gz-filter-stream slice — REGRESSION test for a diagnosed csv-gz defect
// (frozen; planner-owned). A background FILTER or SEARCH scan that TRAILS the
// index frontier — the document already inflated once by the AUTO indexer, so
// every row the scan wants is at or behind the forward inflater — must reuse
// ONE live inflater and STREAM forward (ARCH-csv-gz req6: "Sequential forward
// work reuses its live inflater and never restarts per row"): O(logical) bytes
// in O(logical/chunk) inflate operations.
//
// The shipped trailing scan does NOT. It acquires a fresh cursor per row
// (reader.readerMatchRow -> csv_reader.matchStream -> source.cursorAt) and,
// resuming at the position the previous row left off, reuses the FORWARD lane
// via the `internal == forward_resume` fast path. As it reads past the open
// head, the forward session's inflated high-water mark (s.logical) races AHEAD
// of the cursor (the cursor's 4-byte peek-ahead + 256 KiB chunk over-production
// push it past the cursor's actual offset). The forward lane can only move
// forward — source.byteAtLane cannot serve a byte BEHIND s.logical on lane 0 —
// so the cursor stalls: byteAtLane returns null / the scan re-issues produce()
// which now yields 0 bytes (terminal), and the scan LIVELOCKS. It spins issuing
// 0-byte produce() calls forever: it never terminates and never reports the
// correct count (measured symptom: a filtered .csv.gz was pathologically slow /
// effectively non-terminating — a handful of near-cap rows after ~226 s).
//
// DETERMINISTIC TEETH: api.gzInflateOps (produce invocations) and
// api.gzInflatedBytes are WIRED to real inflate work in the seed (source.zig),
// unlike the not-yet-built gz_*/wb_* RED seeds. The livelock makes the OP count
// grow WITHOUT BOUND (0-byte spins) while inflated BYTES plateau at ~1x logical,
// so a byte bound alone cannot catch it — the OP count is the signal. The poll
// below TRIPS on the op bound within microseconds of the spin (no 226 s hang;
// ls_close then stops the worker at its per-row shutdown check). The streaming
// fix keeps ops at O(logical/chunk) << the bound, completes, and counts right.
// ---------------------------------------------------------------------------

const GzScanKind = enum { filter, search };

fn gzScanDone(doc: *api.Doc, kind: GzScanKind) bool {
    return switch (kind) {
        .filter => api.ls_filter_poll(doc).state == .done,
        .search => api.ls_search_poll(doc).state == .done,
    };
}

/// Poll a trailing background gzip scan to completion while holding its inflate
/// WORK to a streaming budget. Reset api.gzInflateWorkReset(doc) AND start the
/// scan just before calling, so the counters measure only THIS scan.
///   * op_bound  = logical / 4096 : a streaming pass does ~logical/256KiB inflate
///     ops (<< this, ~64x slack even if the chunk size shrank); the livelocking /
///     re-inflating scan blows past it near-instantly -> RED, deterministic + fast.
///   * byte_bound = 4 x logical   : one forward pass is ~1x logical; this guards
///     against a future PURE re-inflation regression (the current defect plateaus
///     under it — the op bound is what catches the shipped livelock).
/// A 20 s wall-clock backstop only fires if a scan somehow neither streams,
/// spins ops, nor completes (never expected); the op bound is the real RED.
fn expectStreamingGzScan(doc: *api.Doc, logical: u64, kind: GzScanKind) !void {
    const op_bound: u64 = logical / 4096;
    const byte_bound: u64 = 4 * logical;
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        const ops = api.gzInflateOps(doc);
        if (ops > op_bound) {
            std.debug.print("\n[gzfs] {s}-scan inflate ops {d} > streaming bound {d}: the trailing scan does not stream forward (livelock / per-row restart)\n", .{ @tagName(kind), ops, op_bound });
            return error.NonStreamingInflate;
        }
        if (api.gzInflatedBytes(doc) > byte_bound) {
            std.debug.print("\n[gzfs] {s}-scan inflated bytes exceed 4x logical: re-inflation, not a linear pass\n", .{@tagName(kind)});
            return error.QuadraticInflate;
        }
        if (gzScanDone(doc, kind)) break;
        if (elapsedMs(t0) > 20_000) return error.ScanTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    // Completed within the streaming budget: real work happened (seam wired) and
    // it was a bounded forward pass, not an unbounded spin / re-inflation.
    try std.testing.expect(api.gzInflateOps(doc) > 0);
    try std.testing.expect(api.gzInflateOps(doc) <= op_bound);
    try std.testing.expect(api.gzInflatedBytes(doc) > 0);
    try std.testing.expect(api.gzInflatedBytes(doc) <= byte_bound);
}

// ~48 near-cap (~0.94 MiB) rows -> ~45 MiB inflated: several rows share each
// 32-MiB gzip inflate-checkpoint window AND the scan crosses >= 1 window (a
// durable checkpoint is written at 32 MiB), so the fix must stream ACROSS a
// checkpoint boundary. Big enough that the trailing scan reads well past the
// 4 MiB open head, where the shipped defect manifests.
const gzfs_rows: u64 = 48;

test "gzfs_filter: a gzip FILTER-scan trailing the frontier streams forward, does not livelock/re-inflate (regression)" {
    const gpa = std.testing.allocator;
    const plain = try genNearCapRows(gpa, gzfs_rows);
    defer gpa.free(plain);
    const g = try gz(gpa, plain);
    defer gpa.free(g);
    const logical: u64 = plain.len;

    var od = try openWith(g, .{ .separator = ',', .index_mode = api.index_auto });
    defer od.deinit();
    // Drive the AUTO indexer to EOF FIRST so the whole document is behind the
    // frontier: the filter-scan then reads every row trailing the inflater —
    // the exact condition under which the shipped scan fails to stream.
    try scanToEnd(od.doc);
    api.gzInflateWorkReset(od.doc);

    // A predicate matching a SUBSET (col 1 "v" < 24 -> rows 0..23); the scan
    // still visits all 48 rows.
    try setFilter(od.doc, predReq(1, .lt, "24"));
    try expectStreamingGzScan(od.doc, logical, .filter);

    // The streaming fix must also be CORRECT: the subset is counted exactly.
    const st = api.ls_filter_poll(od.doc);
    try std.testing.expectEqual(api.FilterState.done, st.state);
    try std.testing.expectEqual(@as(u64, 24), st.total);
}

test "gzfs_search: a gzip FIND-scan trailing the frontier streams forward, does not livelock/re-inflate (regression)" {
    const gpa = std.testing.allocator;
    const plain = try genNearCapRows(gpa, gzfs_rows);
    defer gpa.free(plain);
    const g = try gz(gpa, plain);
    defer gpa.free(g);
    const logical: u64 = plain.len;

    var od = try openWith(g, .{ .separator = ',', .index_mode = api.index_auto });
    defer od.deinit();
    // Same trailing condition as the filter: index complete, then a find that
    // must re-lex behind the frontier to COUNT (it runs even after the index is
    // complete — see index.workerMain slot priority). col-0 filler is all 'a',
    // so text "a" matches every row: the scan visits all 48.
    try scanToEnd(od.doc);
    api.gzInflateWorkReset(od.doc);

    try startSearch(od.doc, textReq("a"));
    try expectStreamingGzScan(od.doc, logical, .search);

    const st = api.ls_search_poll(od.doc);
    try std.testing.expectEqual(api.SearchState.done, st.state);
    try std.testing.expectEqual(gzfs_rows, st.total);
}

// ===========================================================================
// gz-filter-stream — GENERAL multi-block regression (planner-owned, frozen).
// gzfs_filter/gzfs_search above use a 48-row, single-block, no-contention
// fixture; the shipped fix passed them yet an earlier round still re-inflated a
// ~32 MiB checkpoint interval PER 2048-row block when a behind-frontier replay
// read perturbed the scan's replay lane BETWEEN blocks. These tests lock the
// GENERAL case: a gzip FILTER/SEARCH scan that trails the frontier across MANY
// 2048-row blocks and >= 2 durable 32 MiB inflate-checkpoints, with a
// behind-frontier replay-lane read interleaved between every block.
//
// The committed fix retains ONE scan replay lane for the WHOLE job
// (base.Document.match_scan_cursor, keyed by owner+generation+position;
// lane_busy stays held across block commits), so an interleaved read is forced
// onto the OTHER replay lane and the scan keeps streaming: ~1x logical inflated
// bytes in ~logical/chunk inflate ops, no matter how many reads perturb the
// other lane. Two impls this MUST reject, both witnessed by the bounds below:
//   * ORIGINAL livelock (pre-fix): the trailing scan reused the forward lane
//     past its over-produced position and spun 0-byte produce() calls -> ops
//     grow without bound (bytes plateau) -> the OP bound trips.
//   * PER-BLOCK-LEASE (the round-1 regression): the scan releases + reacquires
//     its replay lane each block, so the interleaved read repositions the lane
//     it will re-grab; every block then re-inflates from the nearest checkpoint
//     up to the scan's position -> inflated bytes/ops grow ~= blocks x interval.
//     Measured on this fixture (per-block-lease iso vs the committed fix):
//     ~1.19 GiB / 4637 ops  vs  ~72.6 MiB / 282 ops  -- a ~16x gap.
//
// Driven single-threaded and DETERMINISTICALLY: api.gzScanStep advances the
// scan one 2048-row block at a time on THIS thread with the worker parked
// (api.gzScanParkWorker), and api.gzTouchReplayLane performs the between-block
// behind-frontier replay-lane read. The inflate-work counters
// (api.gzInflatedBytes / api.gzInflateOps) are a pure function of the inflate
// work done, so the assertions are reproducible with no wall-clock or thread
// race. (A concurrent worker-driven scan with hammered behind-frontier windows
// streams identically on the fix; this single-threaded form is the frozen,
// non-flaky witness.)
// ---------------------------------------------------------------------------

/// `n` fixed-width SHORT rows under header "k,v": col 0 is `filler` bytes of
/// 'a' (so text "a" matches EVERY row -> exact terminal total == n), col 1 the
/// 8-digit index. Row width is exactly filler+10, so row R starts at byte
/// 4 + R*(filler+10) -- fixed enough to place the >2048-row, >64 MiB fixture
/// deterministically across the 32/64 MiB checkpoints. Caller frees.
fn genShortRows(gpa: std.mem.Allocator, n: u64, filler: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "k,v\n");
    const blob = try gpa.alloc(u8, filler);
    defer gpa.free(blob);
    @memset(blob, 'a');
    var line: [16]u8 = undefined;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try buf.appendSlice(gpa, blob); // col 0: 'a' filler -> matches "a"
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&line, ",{d:0>8}\n", .{i}));
    }
    return buf.toOwnedSlice(gpa);
}

const gzmb_filler: usize = 502; // row width 512 bytes
const gzmb_rows: u64 = 150_000; // ~73.2 MiB logical: 74 blocks; crosses the 32 & 64 MiB ckpts
const gzmb_chunk: u64 = 256 * 1024; // source.chunk_bytes: the inflate op size
// The between-block read grabs a replay lane JUST PAST the first durable 32 MiB
// inflate-checkpoint: the retained-lane fix replays it once (~1 chunk) then
// serves repeats from that lane's buffer, while a per-block-lease scan re-grabs
// the repositioned lane every block and re-inflates from the 32 MiB checkpoint.
const gzmb_touch: u64 = 32 * 1024 * 1024 + 4;

const GzMbKind = enum { filter, search };

fn expectStreamingGzMultiblock(kind: GzMbKind) !void {
    const gpa = std.testing.allocator;
    const plain = try genShortRows(gpa, gzmb_rows, gzmb_filler);
    defer gpa.free(plain);
    const g = try gz(gpa, plain);
    defer gpa.free(g);
    const logical: u64 = plain.len;

    var od = try openWith(g, .{ .separator = ',', .index_mode = api.index_auto });
    defer od.deinit();
    const doc = od.doc;

    // Index to EOF FIRST: the forward inflater reaches the frontier and drops
    // durable 32 & 64 MiB inflate-checkpoints, so the whole document is behind
    // the frontier and the match-scan trails it (the failing condition).
    try scanToEnd(doc);

    // Park the worker and drive the scan one 2048-row block at a time on this
    // thread, so the between-block interleave is exact and the counters
    // reproducible.
    api.gzScanParkWorker(doc, true);
    switch (kind) {
        .filter => try setFilter(doc, textReq("a")),
        .search => try startSearch(doc, textReq("a")),
    }
    api.gzInflateWorkReset(doc); // measure ONLY the trailing scan + interleave

    var blocks: u64 = 0;
    while (true) {
        const st = api.gzScanStep(doc);
        if (st == .idle) return error.ScanNotArmed; // arming failed
        if (st == .done) break;
        // Between blocks: a behind-frontier replay-lane read (the general form
        // of an ls_window_set / ls_cell_copy / nav over a trailing row).
        api.gzTouchReplayLane(doc, gzmb_touch);
        blocks += 1;
    }
    api.gzScanParkWorker(doc, false);

    const ops = api.gzInflateOps(doc);
    const bytes = api.gzInflatedBytes(doc);
    // One forward pass is ~1x logical bytes in ~logical/chunk ops; the retained
    // lane keeps the scan there under the interleave. A per-block-lease scan
    // (~16x) and the original livelock (unbounded ops) both blow these.
    const byte_bound: u64 = 2 * logical;
    const op_bound: u64 = 4 * (logical / gzmb_chunk);
    if (bytes > byte_bound) {
        std.debug.print("\n[gzfs_multiblock {s}] inflated {d} > {d} (2x logical): trailing scan re-inflates per block, does not stream\n", .{ @tagName(kind), bytes, byte_bound });
        return error.NonStreamingInflate;
    }
    if (ops > op_bound) {
        std.debug.print("\n[gzfs_multiblock {s}] inflate ops {d} > {d}: per-block re-inflation / livelock, not a single forward pass\n", .{ @tagName(kind), ops, op_bound });
        return error.NonStreamingInflate;
    }
    try std.testing.expect(blocks >= 40); // truly multi-block, crossed both checkpoints
    try std.testing.expect(ops > 0 and bytes > 0); // seams wired; real inflate happened

    // Termination + EXACT terminal total: every one of the 150k rows visited and
    // counted (text "a" matches every row), proving the streaming scan is also
    // correct, not merely cheap.
    switch (kind) {
        .filter => {
            const f = api.ls_filter_poll(doc);
            try std.testing.expectEqual(api.FilterState.done, f.state);
            try std.testing.expectEqual(gzmb_rows, f.total);
        },
        .search => {
            const st = api.ls_search_poll(doc);
            try std.testing.expectEqual(api.SearchState.done, st.state);
            try std.testing.expectEqual(gzmb_rows, st.total);
        },
    }
}

test "gzfs_filter_multiblock: a gzip FILTER-scan trailing the frontier across many blocks + checkpoints streams under a between-block replay-lane read (regression)" {
    try expectStreamingGzMultiblock(.filter);
}

test "gzfs_search_multiblock: a gzip FIND-scan trailing the frontier across many blocks + checkpoints streams under a between-block replay-lane read (regression)" {
    try expectStreamingGzMultiblock(.search);
}

// ===========================================================================
// column-config slice (ARCH-column-config) — the SHARED api/ + BACKEND piece.
// Frozen; planner-owned. Drives the additive column-metadata C ABI (see
// api/lesssheet.h "COLUMN METADATA EXTENSION") through @import("api"). The
// display half (formatting/alignment/panel/search) lives in the macOS suite;
// inference, publication, conflict/proposal, precedence, the sparse type model,
// generations, and the windowed labels are proven HERE (the core owns typing —
// PROJECT.md slice 9).
//
// AC -> test map (backend-relevant clauses of the 21 ARCH criteria):
//   AC1  additive + layout ........ cc_ac1_layout_constants                 [GUARD]
//   AC2  coherent/zero-alloc query  cc_ac2_get_many_order_dups, cc_ac2_query_zero_alloc [GUARD]
//   AC3  atomic mutation/copy ...... cc_ac3_get_many_atomic, cc_ac3_poll_atomic,
//        cc_ac3_override_validation, cc_ac3_sentinel_validation,
//        cc_ac3_idempotent_and_no_proposal, cc_ac3_sentinel_copy_empty_vs_novalue [3 GUARD, 1 RED]
//   AC4  cold open, no inference ... cc_ac4_open_no_inference                [GUARD]
//   AC5  bounded/lazy/cancellable .. cc_ac5_request_publishes, cc_ac5_bounded_first_sample,
//        cc_ac5_cancellable, cc_ac5_no_frontier_advance                      [RED]
//   AC6  publication threshold ..... cc_ac6_threshold_7_vs_8, cc_ac6_exhaustive_small [RED]
//   AC7  grammar + parameters ...... cc_ac7_grammar_kinds, cc_ac7_datetime_decimal_params [RED]
//   AC8  no silent revision ........ cc_ac8_conflict_proposal_accept         [RED]
//   AC9  empty/null/conflict distinct cc_ac9_empty_vs_null, cc_ac9_sentinel_exact [RED]
//   AC9/gen one-commit ............. cc_gen_one_commit_per_mutation          [RED]
//   AC10 precedence + reset ........ cc_ac10_precedence_and_reset            [RED]
//   AC13 windowed header labels .... cc_ac13_windowed_labels                 [RED]
//   AC17 raw ops invariant ......... cc_ac17_raw_unaffected_by_config        [GUARD]
//   AC19 fresh session on re-open .. cc_ac19_reopen_is_fresh                 [GUARD]
//
// RED SEED (src/column.zig): every mutating call is a validated NO-OP and the
// job never leaves JOB_IDLE, so `waitInferenceDone` returns error.InferenceNotStarted
// (the requested job never polls IDLE — mirrors waitFilterDone) and every
// "publishes / bounded / conflict / proposal / precedence / labels / one-commit"
// assertion FAILS instead of hanging. The GUARD tests (layout, validation
// atomicity, cold-open-no-inference, raw invariance, fresh re-open) are green
// by construction and protect those invariants on the way to green.
// ===========================================================================

const cc_abi_version = api.column_metadata_abi_version;

fn ccRequest(doc: *api.Doc, ids: []const u32) !void {
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_inference_request(doc, ids.ptr, @intCast(ids.len)));
}

fn ccPoll(doc: *api.Doc) api.ColumnInferenceStatus {
    var s: api.ColumnInferenceStatus = undefined;
    s.struct_size = @sizeOf(api.ColumnInferenceStatus);
    s.abi_version = cc_abi_version;
    std.debug.assert(api.ls_column_metadata_poll(doc, &s) == .ok);
    return s;
}

/// Poll the inference job (after a request) until DONE or CANCELLED; return the
/// status. Errors on IDLE (a requested job never polls IDLE — the RED SEED does,
/// so a test fails HERE with a clear error instead of hanging) or after 15 s.
fn waitInferenceDone(doc: *api.Doc) !api.ColumnInferenceStatus {
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        const s = ccPoll(doc);
        if (s.state == .done or s.state == .cancelled) return s;
        if (s.state == .idle) return error.InferenceNotStarted;
        if (elapsedMs(t0) > 15_000) return error.InferenceTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn ccGetMany(doc: *api.Doc, ids: []const u32, items: []api.ColumnMetadata) !u64 {
    std.debug.assert(items.len >= ids.len);
    for (items) |*it| {
        it.* = undefined;
        it.struct_size = @sizeOf(api.ColumnMetadata);
        it.abi_version = cc_abi_version;
    }
    var gen: u64 = 0;
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_metadata_get_many(doc, ids.ptr, @intCast(ids.len), items.ptr, @intCast(items.len), &gen));
    return gen;
}

fn ccGet1(doc: *api.Doc, col: u32) !api.ColumnMetadata {
    var items: [1]api.ColumnMetadata = undefined;
    const ids = [_]u32{col};
    _ = try ccGetMany(doc, &ids, &items);
    return items[0];
}

/// Request inference for `col` and wait for the job to settle, then return the
/// column's committed metadata. RED SEED: the wait errors (job never leaves IDLE).
fn ccInferAndGet(doc: *api.Doc, col: u32) !api.ColumnMetadata {
    const ids = [_]u32{col};
    try ccRequest(doc, &ids);
    _ = try waitInferenceDone(doc);
    return ccGet1(doc, col);
}

fn ccIntType() api.ColumnType {
    return .{
        .struct_size = @sizeOf(api.ColumnType),
        .abi_version = cc_abi_version,
        .kind = .integer,
        .flags = 0,
        .decimal_precision = api.column_type_precision_unspecified,
        .decimal_scale = api.column_type_scale_unspecified,
        .datetime_semantics = .none,
        .datetime_fraction_digits = api.column_type_fraction_digits_unspecified,
        .reserved = 0,
    };
}

/// header + `eligible` integer rows + empty rows until the file exceeds the 4 MiB
/// head budget, so open (MANUAL) leaves it NON-EXHAUSTIVE and the first inference
/// sample (256 rows) sees exactly `eligible` eligible values. Caller frees.
fn genEligibleThenEmpty(gpa: std.mem.Allocator, eligible: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "n\n");
    var i: u32 = 0;
    while (i < eligible) : (i += 1) try buf.appendSlice(gpa, "123\n");
    // Pad with empty rows past 4 MiB so the doc is not fully indexed by open.
    const target: usize = api.open_head_max_bytes + 128 * 1024;
    try buf.ensureTotalCapacity(gpa, target + 16);
    while (buf.items.len < target) try buf.append(gpa, '\n');
    return buf.toOwnedSlice(gpa);
}

// --- cc_ac1 — additive surface + fixed layout (GUARD) -----------------------

test "cc_ac1_layout_constants: snapshot sizes/constants/enums are the frozen v1 values" {
    // Sizes/aligns are pinned at comptime in contracts/api.zig + api/lesssheet.h;
    // pin the same numbers as a runtime guard against silent drift.
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(api.ColumnType));
    try std.testing.expectEqual(@as(usize, 384), @sizeOf(api.ColumnMetadata));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(api.ColumnInferenceStatus));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(api.ColumnLabelSpan));
    try std.testing.expectEqual(@as(u32, 1), api.column_metadata_abi_version);
    try std.testing.expectEqual(@as(u32, 1024), api.column_batch_max);
    try std.testing.expectEqual(@as(u64, 256), api.column_inference_head_max_rows);
    try std.testing.expectEqual(@as(u64, 262144), api.column_inference_window_max_bytes);
    try std.testing.expectEqual(@as(usize, 256), api.column_sentinel_max_bytes);
    try std.testing.expectEqual(@as(usize, 256), api.column_conflict_example_max_bytes);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), api.column_type_precision_unspecified);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), api.column_type_scale_unspecified);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), api.column_type_fraction_digits_unspecified);
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(api.ColumnTypeKind.integer));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(api.ColumnTypeKind.datetime));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(api.ColumnResult.buffer_too_small));
}

// --- cc_ac4 — cold open starts no inference (GUARD) -------------------------

test "cc_ac4_open_no_inference: open creates no per-column state and no job" {
    var od = try openBytes("a,b,c\n1,2,3\n4,5,6\n");
    defer od.deinit();
    const s = ccPoll(od.doc);
    try std.testing.expectEqual(api.ColumnInferenceJobState.idle, s.state);
    try std.testing.expectEqual(@as(u32, 0), s.requested_column_count);
    try std.testing.expectEqual(@as(u64, 0), s.metadata_generation);
    var items: [3]api.ColumnMetadata = undefined;
    const ids = [_]u32{ 0, 1, 2 };
    const gen = try ccGetMany(od.doc, &ids, &items);
    try std.testing.expectEqual(@as(u64, 0), gen); // untouched document
    for (items, 0..) |m, c| {
        try std.testing.expectEqual(@as(u32, @intCast(c)), m.column);
        try std.testing.expectEqual(@as(u64, 0), m.generation);
        try std.testing.expectEqual(api.ColumnInferenceState.unrequested, m.inference_state);
        try std.testing.expectEqual(api.ColumnTypeSource.none, m.effective_source);
        try std.testing.expectEqual(api.ColumnTypeKind.unknown, m.effective.kind);
    }
}

// --- cc_ac2 — coherent, caller-owned, zero-allocation batch snapshots -------

test "cc_ac2_get_many_order_dups: caller order, duplicates, one generation" {
    var od = try openBytes("a,b,c\n1,2,3\n");
    defer od.deinit();
    var items: [4]api.ColumnMetadata = undefined;
    const ids = [_]u32{ 2, 0, 0, 1 };
    _ = try ccGetMany(od.doc, &ids, &items);
    // one item per requested ID, in the requested order (duplicates preserved).
    try std.testing.expectEqual(@as(u32, 2), items[0].column);
    try std.testing.expectEqual(@as(u32, 0), items[1].column);
    try std.testing.expectEqual(@as(u32, 0), items[2].column);
    try std.testing.expectEqual(@as(u32, 1), items[3].column);
    // a zero-length batch is a valid no-op that still reports the generation.
    var gen: u64 = 12345;
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_metadata_get_many(od.doc, null, 0, null, 0, &gen));
    try std.testing.expectEqual(@as(u64, 0), gen);
}

test "cc_ac2_query_zero_alloc: get_many / poll / copy allocate nothing" {
    var counting: CountingAllocator = .{ .parent = std.testing.allocator };
    var fx = try makeFixture("name,age\nAda,37\n", 0o644);
    defer fx.deinit();
    var doc_opt: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.openWithAllocator(counting.allocator(), fx.path.ptr, &manual, &doc_opt));
    const doc = doc_opt.?;
    defer api.ls_close(doc);
    const baseline = counting.count;

    var items: [2]api.ColumnMetadata = undefined;
    const ids = [_]u32{ 0, 1 };
    _ = try ccGetMany(doc, &ids, &items);
    _ = ccPoll(doc);
    var spans: [2]api.ColumnLabelSpan = undefined;
    for (&spans) |*sp| {
        sp.struct_size = @sizeOf(api.ColumnLabelSpan);
        sp.abi_version = cc_abi_version;
    }
    var required: usize = 0;
    _ = api.ls_column_labels_copy_many(doc, &ids, 2, &spans, 2, null, 0, &required);
    _ = api.ls_column_null_sentinel_copy(doc, 0, null, 0, &required);
    _ = api.ls_column_conflict_example_copy(doc, 0, null, 0, &required);

    try std.testing.expectEqual(baseline, counting.count); // ZERO new allocations
}

// --- cc_ac3 — atomic mutation + copy errors ---------------------------------

test "cc_ac3_get_many_atomic: bad size/version/ID leaves every output byte untouched" {
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    const ids = [_]u32{ 0, 1 };
    var gen: u64 = 999;

    // A wrong struct_size on one item -> INVALID_ARGUMENT, nothing written.
    var items: [2]api.ColumnMetadata = undefined;
    items[0].struct_size = 7; // wrong
    items[0].abi_version = cc_abi_version;
    items[0].column = 0xDEAD;
    items[1].struct_size = @sizeOf(api.ColumnMetadata);
    items[1].abi_version = cc_abi_version;
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_metadata_get_many(od.doc, &ids, 2, &items, 2, &gen));
    try std.testing.expectEqual(@as(u32, 0xDEAD), items[0].column); // untouched
    try std.testing.expectEqual(@as(u64, 999), gen); // untouched

    // capacity < count -> INVALID_ARGUMENT.
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_metadata_get_many(od.doc, &ids, 2, &items, 1, &gen));

    // An out-of-range ID (valid shape) -> NO_COLUMN.
    const bad = [_]u32{ 0, 9 };
    for (&items) |*it| {
        it.struct_size = @sizeOf(api.ColumnMetadata);
        it.abi_version = cc_abi_version;
    }
    try std.testing.expectEqual(api.ColumnResult.no_column, api.ls_column_metadata_get_many(od.doc, &bad, 2, &items, 2, &gen));
}

test "cc_ac3_poll_atomic: size/version mismatch is INVALID_ARGUMENT" {
    var od = try openBytes("a\n1\n");
    defer od.deinit();
    var s: api.ColumnInferenceStatus = undefined;
    s.struct_size = 3; // wrong
    s.abi_version = cc_abi_version;
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_metadata_poll(od.doc, &s));
    s.struct_size = @sizeOf(api.ColumnInferenceStatus);
    s.abi_version = 999; // wrong
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_metadata_poll(od.doc, &s));
}

test "cc_ac3_override_validation: unknown/unsupported/malformed rejected; explicit kind accepted" {
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    var t = ccIntType();
    // valid explicit integer override.
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_override_set(od.doc, 0, &t));
    // UNKNOWN / UNSUPPORTED are never valid overrides.
    t.kind = .unknown;
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_override_set(od.doc, 0, &t));
    t.kind = .unsupported;
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_override_set(od.doc, 0, &t));
    // A datetime override MUST carry an explicit NAIVE/ZONED semantic.
    t = ccIntType();
    t.kind = .datetime;
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_override_set(od.doc, 0, &t)); // semantics NONE
    t.datetime_semantics = .naive;
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_override_set(od.doc, 0, &t));
    // precision/scale are inferred metadata — an override may not set them.
    t = ccIntType();
    t.kind = .decimal;
    t.decimal_scale = 2;
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_override_set(od.doc, 0, &t));
    // A wrong struct_size is INVALID_ARGUMENT; an out-of-range column is NO_COLUMN.
    t = ccIntType();
    t.struct_size = 1;
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_override_set(od.doc, 0, &t));
    t = ccIntType();
    try std.testing.expectEqual(api.ColumnResult.no_column, api.ls_column_override_set(od.doc, 9, &t));
}

test "cc_ac3_sentinel_validation: length / UTF-8 / null-pointer rules" {
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    // valid non-empty sentinel.
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_null_sentinel_set(od.doc, 0, "NA", 2));
    // the empty sentinel (NULL pointer, length 0) is valid.
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_null_sentinel_set(od.doc, 0, null, 0));
    // over the 256-byte cap -> INVALID_ARGUMENT.
    var big: [257]u8 = undefined;
    @memset(&big, 'x');
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_null_sentinel_set(od.doc, 0, &big, big.len));
    // invalid UTF-8 -> INVALID_ARGUMENT.
    const bad = [_]u8{ 0xFF, 0xFE };
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_null_sentinel_set(od.doc, 0, &bad, bad.len));
    // NULL pointer with length > 0 -> INVALID_ARGUMENT.
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_null_sentinel_set(od.doc, 0, null, 3));
    // out-of-range column -> NO_COLUMN.
    try std.testing.expectEqual(api.ColumnResult.no_column, api.ls_column_null_sentinel_set(od.doc, 9, "NA", 2));
}

test "cc_ac3_idempotent_and_no_proposal: clears idempotent; accept without a proposal" {
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_override_clear(od.doc, 0));
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_override_clear(od.doc, 0));
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_null_sentinel_clear(od.doc, 0));
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_null_sentinel_clear(od.doc, 0));
    // accepting when there is no proposal is a no-op NO_PROPOSAL.
    try std.testing.expectEqual(api.ColumnResult.no_proposal, api.ls_column_inference_accept_proposal(od.doc, 0));
    // idempotent normalized request.
    const ids = [_]u32{ 1, 0, 0 };
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_inference_request(od.doc, &ids, ids.len));
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_inference_request(od.doc, &ids, ids.len));
    // request with count 0 is invalid (per header: 1..1024).
    try std.testing.expectEqual(api.ColumnResult.invalid_argument, api.ls_column_inference_request(od.doc, null, 0));
}

test "cc_ac3_sentinel_copy_empty_vs_novalue: OK/len 0 (empty) is distinct from NO_VALUE" {
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    var required: usize = 424242;
    // No sentinel set -> NO_VALUE.
    try std.testing.expectEqual(api.ColumnResult.no_value, api.ls_column_null_sentinel_copy(od.doc, 0, null, 0, &required));
    // An EMPTY sentinel round-trips as OK with required length 0 (RED: the seed
    // stores nothing, so the copy still reports NO_VALUE).
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_null_sentinel_set(od.doc, 0, null, 0));
    required = 424242;
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_null_sentinel_copy(od.doc, 0, null, 0, &required));
    try std.testing.expectEqual(@as(usize, 0), required);
}

// --- cc_ac5 — bounded, lazy, cancellable inference (RED) --------------------

test "cc_ac5_request_publishes: a requested integer column publishes an effective type" {
    var od = try openBytes("n\n1\n2\n3\n4\n5\n6\n7\n8\n");
    defer od.deinit();
    const m = try ccInferAndGet(od.doc, 0); // RED: waitInferenceDone errors (job stays IDLE)
    try std.testing.expectEqual(api.ColumnInferenceState.published, m.inference_state);
    try std.testing.expectEqual(api.ColumnTypeKind.integer, m.effective.kind);
    try std.testing.expectEqual(api.ColumnTypeSource.inferred, m.effective_source);
    try std.testing.expect(m.evidence_count >= 8);
}

test "cc_ac5_bounded_first_sample: first sample touches at most 256 rows / 4 MiB and does real work" {
    const gpa = std.testing.allocator;
    const fixture = try genEligibleThenEmpty(gpa, 32); // >4 MiB, 32 eligible in the head
    defer gpa.free(fixture);
    var od = try openWith(fixture, manual);
    defer od.deinit();
    const ids = [_]u32{0};
    try ccRequest(od.doc, &ids);
    const s = try waitInferenceDone(od.doc); // RED: errors on the seed's IDLE job
    // Real WORK happened, but within BOTH first-sample ceilings.
    try std.testing.expect(s.rows_scanned > 0);
    try std.testing.expect(s.rows_scanned <= api.column_inference_head_max_rows);
    try std.testing.expect(s.rows_budget <= api.column_inference_head_max_rows);
    try std.testing.expect(s.source_bytes_scanned > 0);
    try std.testing.expect(s.source_bytes_scanned <= api.open_head_max_bytes);
    try std.testing.expect(s.source_bytes_budget <= api.open_head_max_bytes);
    try std.testing.expect(s.rows_scanned <= s.rows_budget);
}

test "cc_ac5_no_frontier_advance: inference never advances the scan frontier to EOF" {
    const gpa = std.testing.allocator;
    const fixture = try genEligibleThenEmpty(gpa, 16);
    defer gpa.free(fixture);
    var od = try openWith(fixture, manual);
    defer od.deinit();
    try std.testing.expectEqual(false, api.ls_index_poll(od.doc).complete); // >4 MiB, not fully indexed
    const ids = [_]u32{0};
    try ccRequest(od.doc, &ids);
    _ = try waitInferenceDone(od.doc); // RED on the seed
    // Inference read only the bounded head — the frontier is still short of EOF.
    try std.testing.expectEqual(false, api.ls_index_poll(od.doc).complete);
    try std.testing.expectEqual(false, api.ls_row_count_get(od.doc).exact);
}

test "cc_ac5_cancellable: cancel moves the job to CANCELLED" {
    const gpa = std.testing.allocator;
    const fixture = try genEligibleThenEmpty(gpa, 16);
    defer gpa.free(fixture);
    var od = try openWith(fixture, manual);
    defer od.deinit();
    const ids = [_]u32{0};
    try ccRequest(od.doc, &ids);
    api.ls_column_inference_cancel(od.doc);
    try std.testing.expectEqual(api.ColumnInferenceJobState.cancelled, ccPoll(od.doc).state); // RED: seed reports IDLE
}

// --- cc_ac6 — exact publication threshold (RED) -----------------------------

test "cc_ac6_threshold_7_vs_8: 7 eligible stay PROVISIONAL; the 8th publishes BOUNDED" {
    const gpa = std.testing.allocator;
    // Seven eligible values in a NON-exhaustive document: LOW/PROVISIONAL, and
    // the effective type does NOT move off unknown.
    {
        const fx7 = try genEligibleThenEmpty(gpa, 7);
        defer gpa.free(fx7);
        var od = try openWith(fx7, manual);
        defer od.deinit();
        const m = try ccInferAndGet(od.doc, 0); // RED on the seed
        try std.testing.expectEqual(api.ColumnInferenceState.provisional, m.inference_state);
        try std.testing.expectEqual(api.ColumnConfidence.low, m.confidence);
        try std.testing.expectEqual(api.ColumnTypeSource.none, m.effective_source);
        try std.testing.expectEqual(api.ColumnTypeKind.unknown, m.effective.kind);
        try std.testing.expectEqual(@as(u64, 7), m.evidence_count);
    }
    // Eight eligible values -> BOUNDED/PUBLISHED, effective integer.
    {
        const fx8 = try genEligibleThenEmpty(gpa, 8);
        defer gpa.free(fx8);
        var od = try openWith(fx8, manual);
        defer od.deinit();
        const m = try ccInferAndGet(od.doc, 0);
        try std.testing.expectEqual(api.ColumnInferenceState.published, m.inference_state);
        try std.testing.expectEqual(api.ColumnConfidence.bounded, m.confidence);
        try std.testing.expectEqual(api.ColumnTypeKind.integer, m.effective.kind);
    }
}

test "cc_ac6_exhaustive_small: <8 values publish EXHAUSTIVE at exhaustion; 0 -> unknown" {
    // Three integer rows, fully indexed by open -> EXHAUSTIVE integer.
    {
        var od = try openBytes("n\n10\n20\n30\n");
        defer od.deinit();
        const m = try ccInferAndGet(od.doc, 0); // RED on the seed
        try std.testing.expectEqual(api.ColumnInferenceState.published, m.inference_state);
        try std.testing.expectEqual(api.ColumnConfidence.exhaustive, m.confidence);
        try std.testing.expectEqual(api.ColumnTypeKind.integer, m.effective.kind);
        try std.testing.expectEqual(@as(u64, 3), m.evidence_count);
    }
    // All-empty column, exhausted -> EXHAUSTIVE unknown (no eligible evidence).
    {
        var od = try openBytes("n\n\n\n\n");
        defer od.deinit();
        const m = try ccInferAndGet(od.doc, 0);
        try std.testing.expectEqual(api.ColumnConfidence.exhaustive, m.confidence);
        try std.testing.expectEqual(api.ColumnTypeKind.unknown, m.effective.kind);
        try std.testing.expect(m.evidence_count == 0);
        try std.testing.expect(m.empty_count >= 3);
    }
}

// --- cc_ac7 — exact grammar + parameters (RED) ------------------------------

test "cc_ac7_grammar_kinds: boolean / integer / decimal / date; widen; mixed->text" {
    // 8 agreeing data rows per column.
    const fixture =
        "b,i,d,dt,mx,wd\n" ++
        "true,1,1.5,2020-01-01,1,1\n" ++
        "false,-2,2.5,2020-01-02,abc,2.5\n" ++
        "TRUE,+3,3.5,2020-01-03,3,3\n" ++
        "False,4,4.5,2020-01-04,def,4.5\n" ++
        "true,5,5.5,2020-01-05,5,5\n" ++
        "false,6,6.5,2020-01-06,ghi,6.5\n" ++
        "TRUE,7,7.5,2020-01-07,7,7\n" ++
        "false,8,8.5,2020-01-08,jkl,8.5\n";
    var od = try openBytes(fixture);
    defer od.deinit();
    const ids = [_]u32{ 0, 1, 2, 3, 4, 5 };
    try ccRequest(od.doc, &ids);
    _ = try waitInferenceDone(od.doc); // RED on the seed
    var items: [6]api.ColumnMetadata = undefined;
    _ = try ccGetMany(od.doc, &ids, &items);
    try std.testing.expectEqual(api.ColumnTypeKind.boolean, items[0].effective.kind);
    try std.testing.expectEqual(api.ColumnTypeKind.integer, items[1].effective.kind);
    try std.testing.expectEqual(api.ColumnTypeKind.decimal, items[2].effective.kind);
    try std.testing.expectEqual(api.ColumnTypeKind.date, items[3].effective.kind);
    try std.testing.expectEqual(api.ColumnTypeKind.text, items[4].effective.kind); // mixed int+text
    try std.testing.expectEqual(api.ColumnTypeKind.decimal, items[5].effective.kind); // int+decimal widen
}

test "cc_ac7_datetime_decimal_params: datetime semantic/fraction + decimal precision/scale" {
    const fixture =
        "naive,zoned,decimal\n" ++
        "2020-01-01T00:00:00,2020-01-01T00:00:00.123Z,12.5\n" ++
        "2020-01-02T01:02:03,2020-01-02T00:00:00.123Z,12.5\n" ++
        "2020-01-03T01:02:03,2020-01-03T00:00:00.123Z,12.5\n" ++
        "2020-01-04T01:02:03,2020-01-04T00:00:00.123Z,12.5\n" ++
        "2020-01-05T01:02:03,2020-01-05T00:00:00.123Z,12.5\n" ++
        "2020-01-06T01:02:03,2020-01-06T00:00:00.123Z,12.5\n" ++
        "2020-01-07T01:02:03,2020-01-07T00:00:00.123Z,12.5\n" ++
        "2020-01-08T01:02:03,2020-01-08T00:00:00.123Z,12.5\n";
    var od = try openBytes(fixture);
    defer od.deinit();
    const ids = [_]u32{ 0, 1, 2 };
    try ccRequest(od.doc, &ids);
    _ = try waitInferenceDone(od.doc); // RED on the seed
    var items: [3]api.ColumnMetadata = undefined;
    _ = try ccGetMany(od.doc, &ids, &items);
    // naive datetime.
    try std.testing.expectEqual(api.ColumnTypeKind.datetime, items[0].effective.kind);
    try std.testing.expectEqual(api.ColumnDatetimeSemantics.naive, items[0].effective.datetime_semantics);
    try std.testing.expectEqual(@as(u32, 0), items[0].effective.datetime_fraction_digits);
    // zoned datetime with a 3-digit fraction.
    try std.testing.expectEqual(api.ColumnTypeKind.datetime, items[1].effective.kind);
    try std.testing.expectEqual(api.ColumnDatetimeSemantics.zoned, items[1].effective.datetime_semantics);
    try std.testing.expectEqual(@as(u32, 3), items[1].effective.datetime_fraction_digits);
    // decimal 12.5 -> coefficient "125" (precision 3), one fractional place (scale 1).
    try std.testing.expectEqual(api.ColumnTypeKind.decimal, items[2].effective.kind);
    try std.testing.expectEqual(@as(u64, 3), items[2].effective.decimal_precision);
    try std.testing.expectEqual(@as(i64, 1), items[2].effective.decimal_scale);
}

// --- cc_ac8 — publication is frozen; contradictions propose, never revise ---

test "cc_ac8_conflict_proposal_accept: published type is frozen; 8 agree -> proposal -> accept" {
    // 8 integers publish INTEGER, then 8 decimals contradict and agree on DECIMAL.
    const fixture =
        "n\n1\n2\n3\n4\n5\n6\n7\n8\n" ++
        "1.5\n2.5\n3.5\n4.5\n5.5\n6.5\n7.5\n8.5\n";
    var od = try openBytes(fixture);
    defer od.deinit();
    const m = try ccInferAndGet(od.doc, 0); // RED on the seed
    // The published effective type does NOT move off integer.
    try std.testing.expectEqual(api.ColumnTypeKind.integer, m.effective.kind);
    try std.testing.expect(@intFromEnum(m.confidence) >= @intFromEnum(api.ColumnConfidence.bounded));
    // 8 agreeing contradictions -> a PROPOSAL to widen to decimal.
    try std.testing.expectEqual(api.ColumnConflictState.proposed, m.conflict_state);
    try std.testing.expectEqual(api.ColumnTypeKind.decimal, m.proposal.kind);
    try std.testing.expect(m.conflict_count >= 8);
    try std.testing.expect(m.conflict_source_row != api.no_row);
    // The representative conflicting raw value is retrievable.
    var buf: [64]u8 = undefined;
    var required: usize = 0;
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_conflict_example_copy(od.doc, 0, &buf, buf.len, &required));
    try std.testing.expect(required > 0);

    const gen_before = (try ccGet1(od.doc, 0)).generation;
    // Accepting replaces INFERRED (stays Auto), clears the proposal, bumps the gen.
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_inference_accept_proposal(od.doc, 0));
    const after = try ccGet1(od.doc, 0);
    try std.testing.expectEqual(api.ColumnTypeKind.decimal, after.effective.kind);
    try std.testing.expectEqual(api.ColumnTypeSource.inferred, after.effective_source); // NOT an override
    try std.testing.expectEqual(api.ColumnConflictState.none, after.conflict_state);
    try std.testing.expect(after.generation > gen_before);
}

// --- cc_ac9 — empty vs null vs conflict are distinct ------------------------

test "cc_ac9_empty_vs_null: empty text is not null; an empty sentinel makes it null" {
    // row 0 empty, rows 1..2 integers; no sentinel -> empty text, no null.
    var od = try openBytes("n\n\n5\n10\n");
    defer od.deinit();
    var m = try ccInferAndGet(od.doc, 0); // RED on the seed
    try std.testing.expectEqual(api.ColumnTypeKind.integer, m.effective.kind);
    try std.testing.expect(m.empty_count >= 1);
    try std.testing.expectEqual(@as(u64, 0), m.null_count);
    try std.testing.expectEqual(api.ColumnConflictState.none, m.conflict_state);
    // An EMPTY sentinel reclassifies the empty field as null (fresh epoch).
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_null_sentinel_set(od.doc, 0, null, 0));
    const ids = [_]u32{0};
    try ccRequest(od.doc, &ids);
    _ = try waitInferenceDone(od.doc);
    m = try ccGet1(od.doc, 0);
    try std.testing.expect(m.null_count >= 1);
    try std.testing.expectEqual(api.ColumnTypeKind.integer, m.effective.kind);
}

test "cc_ac9_sentinel_exact: a sentinel matches byte-for-byte, whitespace included" {
    // Sentinel " NA " (spaces around NA). Only the exact 4-byte cell is null.
    var od = try openBytes("n\n5\n NA \nNA\n na \n10\n");
    defer od.deinit();
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_null_sentinel_set(od.doc, 0, " NA ", 4));
    const ids = [_]u32{0};
    try ccRequest(od.doc, &ids);
    _ = try waitInferenceDone(od.doc); // RED on the seed
    const m = try ccGet1(od.doc, 0);
    try std.testing.expectEqual(@as(u64, 1), m.null_count); // ONLY " NA " matched
}

// --- cc_gen — one generation commit per mutation ----------------------------

test "cc_gen_one_commit_per_mutation: a valid override commits exactly one generation" {
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    const before = try ccGet1(od.doc, 0); // generation 0 (untouched)
    try std.testing.expectEqual(@as(u64, 0), before.generation);
    var t = ccIntType();
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_override_set(od.doc, 0, &t));
    var items: [2]api.ColumnMetadata = undefined;
    const ids = [_]u32{ 0, 1 };
    const gen = try ccGetMany(od.doc, &ids, &items);
    try std.testing.expect(gen > 0); // RED: the seed never advances the generation
    try std.testing.expectEqual(gen, items[0].generation); // the changed column is stamped
    try std.testing.expectEqual(@as(u64, 0), items[1].generation); // the untouched one is not
}

// --- cc_ac10 — effective-type precedence + reset ----------------------------

test "cc_ac10_precedence_and_reset: override wins; clearing reveals inferred" {
    // A column that infers integer; an override to text must win, and clearing
    // it must reveal the published inferred integer WITHOUT a re-open.
    var od = try openBytes("n\n1\n2\n3\n4\n5\n6\n7\n8\n");
    defer od.deinit();
    var m = try ccInferAndGet(od.doc, 0); // RED on the seed
    try std.testing.expectEqual(api.ColumnTypeKind.integer, m.effective.kind);
    // override -> text.
    var t = ccIntType();
    t.kind = .text;
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_override_set(od.doc, 0, &t));
    m = try ccGet1(od.doc, 0);
    try std.testing.expectEqual(api.ColumnTypeKind.text, m.effective.kind);
    try std.testing.expectEqual(api.ColumnTypeSource.override, m.effective_source);
    try std.testing.expect((m.presence_flags & api.column_has_inferred) != 0); // inferred not destroyed
    // clear -> reveals the published inferred integer.
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_override_clear(od.doc, 0));
    m = try ccGet1(od.doc, 0);
    try std.testing.expectEqual(api.ColumnTypeKind.integer, m.effective.kind);
    try std.testing.expectEqual(api.ColumnTypeSource.inferred, m.effective_source);
}

// --- cc_ac13 — windowed header labels (RED) ---------------------------------

test "cc_ac13_windowed_labels: labels copy in requested order with two-pass sizing" {
    var od = try openBytes("alpha,beta,gamma\n1,2,3\n");
    defer od.deinit();
    const ids = [_]u32{ 0, 2 }; // a SUB-range (not all columns): windowed fetch
    var spans: [2]api.ColumnLabelSpan = undefined;
    for (&spans) |*sp| {
        sp.struct_size = @sizeOf(api.ColumnLabelSpan);
        sp.abi_version = cc_abi_version;
    }
    var required: usize = 0;
    // pass 1 — preflight: spans + required length, no bytes.
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_labels_copy_many(od.doc, &ids, 2, &spans, 2, null, 0, &required));
    try std.testing.expectEqual(@as(usize, 10), required); // "alpha"(5) + "gamma"(5) — RED: seed reports 0
    try std.testing.expect((spans[0].flags & api.column_label_present) != 0);
    try std.testing.expectEqual(@as(u64, 5), spans[0].len);
    try std.testing.expectEqual(@as(u64, 5), spans[1].len);
    // a too-small arena -> BUFFER_TOO_SMALL, arena untouched.
    var small: [4]u8 = undefined;
    try std.testing.expectEqual(api.ColumnResult.buffer_too_small, api.ls_column_labels_copy_many(od.doc, &ids, 2, &spans, 2, &small, small.len, &required));
    // pass 2 — copy the bytes.
    var arena: [10]u8 = undefined;
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_labels_copy_many(od.doc, &ids, 2, &spans, 2, &arena, arena.len, &required));
    try std.testing.expectEqualStrings("alpha", arena[spans[0].offset .. spans[0].offset + spans[0].len]);
    try std.testing.expectEqualStrings("gamma", arena[spans[1].offset .. spans[1].offset + spans[1].len]);
}

// --- cc_ac17 — raw copy/search/filter never see column config (GUARD) -------

test "cc_ac17_raw_unaffected_by_config: overrides/sentinels never change raw cells or search" {
    var od = try openBytes("n,v\n1,2\n3,4\n5,6\n");
    defer od.deinit();
    try scanToEnd(od.doc);
    winAll(od.doc);
    try expectCell(od.doc, 1, 0, "3"); // raw before config
    const total_before = try searchTotal(od.doc, textReq("3"));

    var t = ccIntType();
    t.kind = .decimal;
    _ = api.ls_column_override_set(od.doc, 0, &t);
    _ = api.ls_column_null_sentinel_set(od.doc, 0, "3", 1);

    winAll(od.doc);
    try expectCell(od.doc, 1, 0, "3"); // raw cell byte-identical
    try std.testing.expectEqual(total_before, try searchTotal(od.doc, textReq("3"))); // search unchanged
}

// --- cc_ac19 — a fresh handle is a fresh session (GUARD) --------------------

test "cc_ac19_reopen_is_fresh: a new handle begins at generation 0 with no state" {
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    // Configure the first handle.
    var t = ccIntType();
    _ = api.ls_column_override_set(od.doc, 0, &t);
    _ = api.ls_column_null_sentinel_set(od.doc, 0, "NA", 2);

    // A distinct handle (the backend half of a re-open) shares no column state.
    var od2 = try openBytes("a,b\n1,2\n");
    defer od2.deinit();
    const s = ccPoll(od2.doc);
    try std.testing.expectEqual(api.ColumnInferenceJobState.idle, s.state);
    try std.testing.expectEqual(@as(u64, 0), s.metadata_generation);
    const m = try ccGet1(od2.doc, 0);
    try std.testing.expectEqual(@as(u64, 0), m.generation);
    try std.testing.expectEqual(api.ColumnTypeKind.unknown, m.effective.kind);
    try std.testing.expectEqual(api.ColumnNullPolicyKind.none, m.null_policy);
}

// ===========================================================================
// network-source slice (ARCH-network-source) — frozen behavior tests
// (planner-owned). Each of the ARCH's 17 acceptance criteria maps to >=1 test;
// the backend covers AC1-AC9, AC11-AC16 (AC10 "no cold-start marker" and AC17
// "frontend entry point" are macOS-side; AC9's visible-affordance UI half is
// macOS, its poll-surface half is here). Hermetic + deterministic: NO live
// network. A well-behaved / faulty / range-honoring / range-ignoring SERVER is
// modelled by an INJECTED TRANSPORT the tests configure with an api.NetFixture
// and start through api.openUrlStartFake (the twin of ls_open_url_start;
// production uses the real std.http.Client). The real-client mapping of real
// DNS/TCP/TLS/redirects over a live localhost http:// AND https:// server is a
// REVIEWER/human target-host probe (see contracts/api.zig NETWORK notes), not a
// hermetic gate test. SEED: openUrlStartFake ignores the fixture and fails
// UNREACHABLE, so every transport-dependent AC below is RED until the http_range
// Source + transport are built + wired; the additive-boundary and scheme-
// rejection guards are green from the seed.

const net_url: []const u8 = "http://fixture.test/data.csv";

/// Poll a job to a terminal state (<= 15 s guard); never blocks the seed (seed
/// jobs are terminal on the first poll).
fn pollNetTerminal(job: *api.NetOpenJob) !api.NetOpenStatus {
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        const s = api.ls_net_open_poll(job);
        switch (s.state) {
            .done, .failed, .cancelled => return s,
            .pending, .fetching => {},
        }
        if (elapsedMs(t0) > 15_000) return error.NetOpenTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Start a fake-transport open and require it to reach DONE with a valid doc.
/// The caller owns the returned doc (ls_close it); the job is released here
/// (releasing a job never closes its doc). RED in the seed (reaches FAILED).
fn openFakeToDone(fixture: *const api.NetFixture) !*api.Doc {
    const job = api.openUrlStartFake(fixture, net_url.ptr, net_url.len, null) orelse return error.NetJobAllocFailed;
    defer api.ls_net_open_release(job);
    const s = try pollNetTerminal(job);
    try std.testing.expectEqual(api.NetOpenState.done, s.state);
    try std.testing.expect(s.doc != null);
    return s.doc.?;
}

// Public C ABI: the network-open symbols are callable through extern linkage,
// and the enum values are pinned to the header (green from seed).
const c_linked_net = struct {
    extern fn ls_open_url_start(url: [*]const u8, url_len: usize, options: ?*const api.OpenOptions) ?*api.NetOpenJob;
    extern fn ls_net_open_poll(job: *const api.NetOpenJob) api.NetOpenStatus;
    extern fn ls_net_open_cancel(job: *api.NetOpenJob) void;
    extern fn ls_net_open_release(job: *api.NetOpenJob) void;
};

test "abi: the network-open C symbols are callable through extern linkage; enum values pinned" {
    // ls_net_status
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.NetStatus.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.NetStatus.invalid_argument));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(api.NetStatus.unreachable_));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(api.NetStatus.timeout));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(api.NetStatus.http_status));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(api.NetStatus.too_many_redirects));
    try std.testing.expectEqual(@as(c_int, 6), @intFromEnum(api.NetStatus.io));
    try std.testing.expectEqual(@as(c_int, 7), @intFromEnum(api.NetStatus.cancelled));
    // ls_net_open_state
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.NetOpenState.pending));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.NetOpenState.fetching));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(api.NetOpenState.done));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(api.NetOpenState.failed));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(api.NetOpenState.cancelled));
    try std.testing.expectEqual(@as(f64, -1.0), api.net_progress_unknown);

    // A disallowed scheme is rejected synchronously through the real C symbol —
    // no network — and released cleanly. (Green from seed.)
    const bad: []const u8 = "ftp://example.test/x.csv";
    const job = c_linked_net.ls_open_url_start(bad.ptr, bad.len, null) orelse return error.NetJobAllocFailed;
    const s = c_linked_net.ls_net_open_poll(job);
    try std.testing.expectEqual(api.NetOpenState.failed, s.state);
    try std.testing.expectEqual(api.NetStatus.invalid_argument, s.err);
    c_linked_net.ls_net_open_release(job);
}

test "net_ac1: on-paper Parquet/ODS Source-shape proof is a review criterion; the ABI is arbitrary-range" {
    // AC1 is a DESIGN-REVIEW criterion: docs/architecture/ARCH-network-source.md
    // carries the on-paper proof that this exact Source shape serves Parquet's
    // footer-first and ODS's ZIP-central-directory access with NO Source/interface
    // change (both are just [start,end) range requests — the same primitive CSV's
    // scan-frontier already uses). It is verified by the architect/human, not by
    // a byte assertion here. This guard pins the OBSERVABLE consequence: the new
    // open surface is ADDITIVE and job-based (arbitrary async range fetch), and a
    // non-network document is entirely unaffected by it.
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    try std.testing.expectEqual(api.NetRangeMode.unknown, api.netRangeMode(od.doc));
    try std.testing.expectEqual(@as(u64, 0), api.netFetchCount(od.doc));
}

test "net_ac2: frozen boundary is additive — a local document is unaffected by the network surface" {
    // AC2 (GUARD): api/lesssheet.h byte-identity is enforced by the ROOT gate's
    // frozen api/ integrity (and the macOS AmendmentContractGuard hash). Here we
    // assert the network feature is entirely behind the new additive ABI + Zig
    // seams: a plain mmap document reports zero/absent network state and its every
    // existing behavior is unchanged.
    var od = try openBytes("name,age\nAlice,30\nBob,25\n");
    defer od.deinit();
    winAll(od.doc);
    try expectCell(od.doc, 0, 0, "Alice");
    try std.testing.expectEqual(@as(u64, 0), api.netResidentBytes(od.doc));
    try std.testing.expectEqual(@as(u64, 0), api.netFetchCount(od.doc));
    const sp = api.netSpoolStore(od.doc);
    try std.testing.expectEqual(false, sp.present);
    try std.testing.expectEqual(api.NetRangeMode.unknown, api.netRangeMode(od.doc));
}

test "net_ac3: range-support path — head rows are servable before the whole resource is fetched" {
    // A server that honors Range: the open runs in true random-access mode and the
    // first window is servable without downloading the whole file. RED in seed.
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "name,age\n");
    {
        var line: [64]u8 = undefined;
        for (0..5000) |i| try body.appendSlice(gpa, try std.fmt.bufPrint(&line, "row{d},{d}\n", .{ i, i }));
    }

    var fx: api.NetFixture = .{ .body = body.items, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    try std.testing.expectEqual(api.NetRangeMode.random_access, api.netRangeMode(doc));
    winAll(doc);
    try expectCell(doc, 0, 0, "row0");
    // A jump near EOF completes WITHOUT the whole resource having been fetched
    // (true partial access, not full-download-first).
    try scanToEnd(doc);
    try std.testing.expect(api.netFetchCount(doc) > 0);
    try std.testing.expect(api.netResidentBytes(doc) <= 16 * 1024 * 1024);
}

test "net_ac4: fallback path — a server that ignores Range downloads sequentially, opens correctly" {
    // 200-only (Range ignored) OR no usable length -> sequential download -> spool
    // -> open exactly like a local file, with correct rows/dialect/counts. RED.
    const plain = "id,name\n1,Alice\n2,Bob\n3,Carol\n";
    inline for (.{
        api.NetFixture{ .body = plain, .honor_ranges = false, .advertise_length = false },
        api.NetFixture{ .body = plain, .honor_ranges = true, .advertise_length = false },
    }) |fixture| {
        var fx = fixture;
        const doc = try openFakeToDone(&fx);
        defer api.ls_close(doc);
        try std.testing.expectEqual(api.NetRangeMode.sequential_fallback, api.netRangeMode(doc));
        try std.testing.expectEqual(@as(u32, 2), api.ls_column_count(doc));
        winAll(doc);
        try expectCell(doc, 0, 1, "Alice");
        try expectCell(doc, 2, 1, "Carol");
    }
}

test "net_ac5: .csv.gz over the network opens through the gzip Source (range and fallback)" {
    // A gzip-compressed CSV served over either path opens through the same gzip
    // Source wrapping logic as a local .csv.gz — byte-identical dialect/rows. RED.
    const gpa = std.testing.allocator;
    const plain = "name,age\nAlice,30\nBob,25\n";
    const g = try gz(gpa, plain);
    defer gpa.free(g);

    var ref = try openWith(plain, manual);
    defer ref.deinit();

    inline for (.{ true, false }) |honor| {
        var fx: api.NetFixture = .{ .body = g, .honor_ranges = honor, .advertise_length = honor };
        const doc = try openFakeToDone(&fx);
        defer api.ls_close(doc);
        try std.testing.expectEqual(api.ls_column_count(ref.doc), api.ls_column_count(doc));
        const rc = api.ls_row_count_get(doc);
        try std.testing.expectEqual(@as(u64, 2), rc.count);
        winAll(doc);
        try expectCell(doc, 0, 0, "Alice");
        try expectCell(doc, 1, 1, "25");
    }
}

test "net_ac6: never-re-fetch — a re-access after RAM-cache eviction is served from the spool" {
    // Once a byte range has been fetched it is served from the local spool
    // forever after, with ZERO additional network requests — even after the RAM
    // cache is evicted. RED.
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "k,v\n");
    {
        var line: [64]u8 = undefined;
        for (0..2000) |i| try body.appendSlice(gpa, try std.fmt.bufPrint(&line, "{d},{d}\n", .{ i, i }));
    }

    var fx: api.NetFixture = .{ .body = body.items, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    winAll(doc);
    _ = api.ls_window_set(doc, 0, 64); // fetch the head range
    const after_first = api.netFetchCount(doc);
    try std.testing.expect(after_first > 0);

    api.netForceCacheBytes(doc, 0); // evict the resident RAM cache entirely
    _ = api.ls_window_set(doc, 0, 64); // re-access the SAME range
    try std.testing.expectEqual(after_first, api.netFetchCount(doc)); // served from spool: no new fetch
}

test "net_ac7: error taxonomy — each cause surfaces its own distinct NetStatus" {
    // Every ls_net_status value is independently reproducible; none collapses into
    // another. The scheme-rejection case is hermetic + green from seed; the
    // transport faults are RED until the transport maps them.
    const body = "a,b\n1,2\n";
    const cases = .{
        .{ api.NetFixture{ .body = body, .fault = .connect }, api.NetStatus.unreachable_ },
        .{ api.NetFixture{ .body = body, .fault = .timeout }, api.NetStatus.timeout },
        .{ api.NetFixture{ .body = body, .fault = .io }, api.NetStatus.io },
        .{ api.NetFixture{ .body = "", .http_status = 404 }, api.NetStatus.http_status },
        .{ api.NetFixture{ .body = body, .redirect_hops = 1000 }, api.NetStatus.too_many_redirects },
    };
    inline for (cases) |case| {
        var fx = case[0];
        const job = api.openUrlStartFake(&fx, net_url.ptr, net_url.len, null) orelse return error.NetJobAllocFailed;
        defer api.ls_net_open_release(job);
        const s = try pollNetTerminal(job);
        try std.testing.expectEqual(api.NetOpenState.failed, s.state);
        try std.testing.expectEqual(case[1], s.err);
        if (case[1] == .http_status) try std.testing.expectEqual(@as(i32, 404), s.http_status);
    }
    // Disallowed / malformed schemes reject SYNCHRONOUSLY with no network. (Green.)
    inline for (.{ "ftp://x/y.csv", "file:///etc/passwd", "notaurl", "" }) |bad_s| {
        const bad: []const u8 = bad_s;
        const job = api.ls_open_url_start(bad.ptr, bad.len, null) orelse return error.NetJobAllocFailed;
        defer api.ls_net_open_release(job);
        const s = api.ls_net_open_poll(job);
        try std.testing.expectEqual(api.NetOpenState.failed, s.state);
        try std.testing.expectEqual(api.NetStatus.invalid_argument, s.err);
    }
}

test "net_ac8: cancellation mid-open stops the fetch, releases resources, leaves no dangling doc" {
    // A stall fixture keeps the job in flight; cancel stops it within a chunk
    // boundary, releases all resources (spool included), and produces no doc. RED
    // in seed (the seed job is already terminal, so cancel is a no-op).
    const body = "a,b\n1,2\n3,4\n";
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = true, .advertise_length = true, .stall = true };
    const job = api.openUrlStartFake(&fx, net_url.ptr, net_url.len, null) orelse return error.NetJobAllocFailed;
    defer api.ls_net_open_release(job);

    // The affordance is live from t0: the first poll is NON-terminal for a
    // stalled open (no silent stall; poll never blocks).
    const first = api.ls_net_open_poll(job);
    try std.testing.expect(first.state == .pending or first.state == .fetching);

    api.ls_net_open_cancel(job);
    const s = try pollNetTerminal(job);
    try std.testing.expectEqual(api.NetOpenState.cancelled, s.state);
    try std.testing.expect(s.doc == null); // no dangling document
    try std.testing.expectEqual(false, api.netJobProbe(job).spool_present); // spool released
}

test "net_ac9: no silent stalls — poll reports a live snapshot from t0 and never blocks (backend half)" {
    // The backend-observable half of AC9: from the instant the open starts, poll
    // returns a valid live snapshot without blocking, with progress either a
    // determinate fraction in [0,1] or the LS_NET_PROGRESS_UNKNOWN sentinel — and
    // it is non-terminal while the fetch is stalled. (The always-visible UI
    // affordance itself is the macOS AC9 half.) RED in seed.
    const body = "a,b\n1,2\n";
    var fx: api.NetFixture = .{ .body = body, .stall = true, .advertise_length = false };
    const job = api.openUrlStartFake(&fx, net_url.ptr, net_url.len, null) orelse return error.NetJobAllocFailed;
    defer api.ls_net_open_release(job);
    defer api.ls_net_open_cancel(job); // don't leave the fetch running

    const s = api.ls_net_open_poll(job);
    try std.testing.expect(s.state == .pending or s.state == .fetching); // non-terminal: still working
    const determinate = s.progress >= 0.0 and s.progress <= 1.0;
    const unknown = s.progress == api.net_progress_unknown;
    try std.testing.expect(determinate or unknown);
}

test "net_ac11: scheme allowlist — http/https open; ftp/file/malformed reject with no network" {
    // The rejection half is hermetic + green from seed (see net_ac7). The success
    // half (a valid http/https URL opens) is RED until the transport is wired; the
    // REAL http:// and https:// round-trip is a reviewer target-host probe.
    const plain = "x\n1\n2\n";
    var fx: api.NetFixture = .{ .body = plain, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx); // RED in seed
    defer api.ls_close(doc);
    try std.testing.expectEqual(@as(u32, 1), api.ls_column_count(doc));

    // Rejections touch no network (synchronous FAILED/INVALID_ARGUMENT).
    inline for (.{ "ftp://h/x", "file:///x", "gopher://h" }) |bad_s| {
        const bad: []const u8 = bad_s;
        const job = api.ls_open_url_start(bad.ptr, bad.len, null) orelse return error.NetJobAllocFailed;
        defer api.ls_net_open_release(job);
        try std.testing.expectEqual(api.NetStatus.invalid_argument, api.ls_net_open_poll(job).err);
    }
}

test "net_ac12: no auth (401/403 -> HTTP_STATUS); redirects bounded (within cap DONE, over cap error)" {
    const body = "a\n1\n";
    // Auth required -> HTTP_STATUS carrying the numeric code (no credential path).
    inline for (.{ 401, 403 }) |code| {
        var fx: api.NetFixture = .{ .body = "", .http_status = code };
        const job = api.openUrlStartFake(&fx, net_url.ptr, net_url.len, null) orelse return error.NetJobAllocFailed;
        defer api.ls_net_open_release(job);
        const s = try pollNetTerminal(job);
        try std.testing.expectEqual(api.NetStatus.http_status, s.err);
        try std.testing.expectEqual(@as(i32, code), s.http_status);
    }
    // A short redirect chain within the cap succeeds; one past it fails.
    {
        var ok_fx: api.NetFixture = .{ .body = body, .redirect_hops = 1, .honor_ranges = true, .advertise_length = true };
        const doc = try openFakeToDone(&ok_fx);
        defer api.ls_close(doc);
        try std.testing.expectEqual(@as(u32, 1), api.ls_column_count(doc));
    }
    {
        var over_fx: api.NetFixture = .{ .body = body, .redirect_hops = 1000 };
        const job = api.openUrlStartFake(&over_fx, net_url.ptr, net_url.len, null) orelse return error.NetJobAllocFailed;
        defer api.ls_net_open_release(job);
        try std.testing.expectEqual(api.NetStatus.too_many_redirects, (try pollNetTerminal(job)).err);
    }
}

test "net_ac13: no cross-open caching — re-opening the same URL re-fetches from scratch" {
    // Re-opening after close always re-fetches: the second open's Source issues
    // its own fetches (no reuse of a prior open's spool). RED.
    const plain = "k,v\na,1\nb,2\n";
    var fx1: api.NetFixture = .{ .body = plain, .honor_ranges = true, .advertise_length = true };
    const doc1 = try openFakeToDone(&fx1);
    winAll(doc1);
    _ = api.ls_window_set(doc1, 0, 8);
    try std.testing.expect(api.netFetchCount(doc1) > 0);
    api.ls_close(doc1);

    var fx2: api.NetFixture = .{ .body = plain, .honor_ranges = true, .advertise_length = true };
    const doc2 = try openFakeToDone(&fx2);
    defer api.ls_close(doc2);
    winAll(doc2);
    _ = api.ls_window_set(doc2, 0, 8);
    try std.testing.expect(api.netFetchCount(doc2) > 0); // fresh fetch, not a reused cache
}

test "net_ac14: spool file hygiene — 0600, unlinked while open, bounded, present only while live" {
    // The private spool is created mode 0600 and unlinked immediately (never
    // visible in its directory while open). RED.
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "n\n");
    {
        var line: [64]u8 = undefined;
        for (0..3000) |i| try body.appendSlice(gpa, try std.fmt.bufPrint(&line, "{d}\n", .{i}));
    }

    var fx: api.NetFixture = .{ .body = body.items, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    try scanToEnd(doc); // materialize enough that the spool is non-empty
    const sp = api.netSpoolStore(doc);
    try std.testing.expectEqual(true, sp.present);
    try std.testing.expectEqual(@as(u32, 0o600), sp.mode);
    try std.testing.expectEqual(true, sp.unlinked);
    try std.testing.expect(sp.bytes > 0);
}

test "net_ac15: memory bound — network Source resident RAM stays <= 16 MiB across scroll/jump" {
    // Steady-state resident RAM does not grow unbounded with spool size (the spool
    // is disk-resident). RED.
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "a,b,c\n");
    {
        var line: [64]u8 = undefined;
        for (0..20000) |i| try body.appendSlice(gpa, try std.fmt.bufPrint(&line, "{d},{d},{d}\n", .{ i, i * 2, i * 3 }));
    }

    var fx: api.NetFixture = .{ .body = body.items, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    // A sustained scroll/jump exercise.
    var r: u64 = 0;
    while (r < 20000) : (r += 4096) {
        api.ls_jump_start(doc, r);
        _ = try waitJumpDone(doc);
        _ = api.ls_window_set(doc, r, 256);
        try std.testing.expect(api.netResidentBytes(doc) <= 16 * 1024 * 1024);
    }
    try std.testing.expect(api.netResidentBytes(doc) > 0);
}

test "net_ac16: dependencies & size — Zig std only (std.http.Client / std.crypto.tls) (GUARD)" {
    // AC16 (GUARD): no new RUNTIME dependency. The real enforcement is the frozen
    // build.zig (stdlib-only; no build.zig.zon) under the component's
    // DEPENDENCY_PATHS + the header's DEPENDENCIES note; the app stays
    // single-digit MB (a reviewer size measurement). This compile-time reference
    // pins that the approved networking primitives are the STD ones.
    _ = std.http.Client;
    _ = std.crypto.tls.Client;
    // A plain document remains fully functional (no dependency regression).
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    try expectDims(od.doc, 1, 2);
}


// ===========================================================================
// never-full-download-streaming slice (ARCH-never-full-download-streaming) —
// frozen behavior tests (planner-owned). Each of the ARCH's 24 acceptance
// criteria maps to a `nfd_acN` test below. A network document must be STRICTLY
// lazy: it fetches only what open / scroll / search / a deep jump needs, with
// NO background network scan (the shipped slice's `buildDownloadAll` +
// background AUTO indexer over the wire is the bug this corrects). Hermetic +
// deterministic: the injected fake transport (api.NetFixture -> openUrlStartFake)
// models range / no-range, known / unknown length, withhold-then-release, and
// post-open drop; fetch-minimality is proven by `netFetchCount`, never latency.
//
// SEED (RED): the current impl keeps `buildDownloadAll` (sequential + gzip
// download the whole resource -> netFetchCount 0, netRangeMode sequential_fallback)
// and spawns the AUTO frontier indexer for network docs (it drives the frontier
// to EOF over the wire -> ls_index_poll.complete / ls_row_count.exact firm
// unbidden, netFetchCount covers the whole body); decideProbe still forces
// range=!is_gz and never reports an unknown-length stream. So every fetch-
// minimality / streaming / sentinel AC below is RED until the lazy model +
// sequential fill + gzip-over-spool + net gate are built and wired. The
// frozen-boundary / on-paper-proof / deps / local-non-regression guards are
// GREEN from the seed (and AC21 must STAY green — the lazy gate keys on source
// kind: LOCAL docs are byte-identical).
//
// LOCAL is strict, NETWORK is best-effort: these tests assert correctness +
// fetch-minimality only. Wall-clock/latency and the real std.http.Client round-
// trip remain human target-host probes (see contracts/api.zig NETWORK notes).

const net_chunk: u64 = 256 * 1024; // net_source.chunk_bytes
const net_head_chunks: u64 = 16; // open_head_max_bytes (4 MiB) / 256 KiB

/// Let any AUTO background index work run to a stable point: poll ls_index_poll
/// until complete OR `budget_ms` elapse; return the final snapshot. On the
/// current (non-lazy) SEED an AUTO network doc's background indexer drives the
/// frontier to EOF over the wire, so this returns complete==true with a grown
/// netFetchCount (the over-fetch the lazy model eliminates); once the net gate
/// is built it returns at the budget with complete==false and a head-only count.
fn settleIndex(doc: *api.Doc, budget_ms: i64) api.ScanProgress {
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        const s = api.ls_index_poll(doc);
        if (s.complete) return s;
        if (elapsedMs(t0) > budget_ms) return s;
        io.sleep(.fromMilliseconds(2), .awake) catch return s;
    }
}

/// Busy-wait `ms` milliseconds while the background lane (if any) runs.
fn netWait(ms: i64) void {
    const io = std.testing.io;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    while (elapsedMs(t0) < ms) io.sleep(.fromMilliseconds(5), .awake) catch return;
}

test "nfd_ac1: frozen boundary + amendments — sentinel present; local docs unaffected (GUARD)" {
    // Layout byte-identity of api/lesssheet.h is enforced by the root gate's
    // frozen-api integrity + the macOS AmendmentContractGuard hash; here we pin
    // the observable amendments: the unknown-total sentinel exists, and a LOCAL
    // document never reports it (its AUTO indexer still drives to EOF). GREEN.
    try std.testing.expectEqual(std.math.maxInt(u64), api.bytes_total_unknown);
    var od = try openWith("a,b\n1,2\n3,4\n", .{}); // AUTO local
    defer od.deinit();
    const ip = settleIndex(od.doc, 2000);
    try std.testing.expectEqual(true, ip.complete);
    try std.testing.expect(ip.bytes_total != api.bytes_total_unknown);
    try std.testing.expectEqual(api.NetRangeMode.unknown, api.netRangeMode(od.doc));
}

test "nfd_ac2: no full download — plain CSV, no-range server streams sequentially" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 600_000); // ~10.8 MiB >> 4 MiB head
    defer gpa.free(body);
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = false, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    try std.testing.expectEqual(api.NetRangeMode.sequential_fallback, api.netRangeMode(doc));
    winAll(doc);
    var b: [8]u8 = undefined;
    try expectCell(doc, 0, 0, fixedCell(&b, 0)); // first window servable
    // STREAMED, not downloaded: the Source issued demand fetches (RED: the seed's
    // buildDownloadAll issues none -> netFetchCount 0), bounded to ~the head, and
    // after AUTO settles the whole body is NOT fetched and the index is NOT
    // complete (RED: the seed downloads + indexes everything).
    const ip = settleIndex(doc, 400);
    try std.testing.expect(api.netFetchCount(doc) > 0);
    try std.testing.expect(api.netFetchCount(doc) <= net_head_chunks + 8);
    try std.testing.expectEqual(false, ip.complete);
}

test "nfd_ac3: no full download — .csv.gz streams compressed bytes on demand (range + no-range)" {
    const gpa = std.testing.allocator;
    const plain = try genFixedRows(gpa, 600_000);
    defer gpa.free(plain);
    const g = try gz(gpa, plain);
    defer gpa.free(g);
    inline for (.{ true, false }) |honor| {
        var fx: api.NetFixture = .{ .body = g, .honor_ranges = honor, .advertise_length = honor };
        const doc = try openFakeToDone(&fx);
        defer api.ls_close(doc);
        winAll(doc);
        var b: [8]u8 = undefined;
        try expectCell(doc, 0, 0, fixedCell(&b, 0));
        // Compressed bytes are fetched via the streaming http_range Source (RED:
        // the seed forces gzip down buildDownloadAll -> netFetchCount 0); the whole
        // compressed body is not fetched and the doc is not fully inflated at open.
        const ip = settleIndex(doc, 400);
        try std.testing.expect(api.netFetchCount(doc) > 0);
        try std.testing.expectEqual(false, ip.complete);
    }
}

test "nfd_ac4: no background growth — netFetchCount + frontier flat across poll-wait-poll" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 600_000);
    defer gpa.free(body);
    const g = try gz(gpa, body);
    defer gpa.free(g);
    const cases = [_]api.NetFixture{
        .{ .body = body, .honor_ranges = true, .advertise_length = true }, // random
        .{ .body = body, .honor_ranges = false, .advertise_length = true }, // sequential
        .{ .body = g, .honor_ranges = true, .advertise_length = true }, // gzip
    };
    for (cases) |fixture| {
        var fx = fixture;
        const doc = try openFakeToDone(&fx);
        defer api.ls_close(doc);
        const c0 = api.netFetchCount(doc);
        const f0 = api.ls_index_poll(doc).bytes_scanned;
        netWait(300); // a background scan (the bug) would grow both / complete the index
        try std.testing.expectEqual(c0, api.netFetchCount(doc)); // no background fetch
        try std.testing.expectEqual(f0, api.ls_index_poll(doc).bytes_scanned); // frontier frozen
        try std.testing.expectEqual(false, api.ls_index_poll(doc).complete);
        try std.testing.expectEqual(false, api.ls_row_count_get(doc).exact);
    }
}

test "nfd_ac5: scroll advances the frontier by a bounded amount, never to EOF" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 600_000); // ~44 chunks; head ~= 233k rows
    defer gpa.free(body);
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    _ = settleIndex(doc, 200);
    // A scroll-driven jump toward bottom_visible + buffer (row 300k, past the head
    // frontier but NOT EOF).
    api.ls_jump_start(doc, 300_000);
    _ = try waitJumpDone(doc);
    _ = api.ls_window_set(doc, 300_000, 64);
    var b: [8]u8 = undefined;
    try expectCell(doc, 300_000, 0, fixedCell(&b, 300_000)); // newly visible rows correct
    // Bounded: the frontier advanced toward the target, NOT to EOF (RED: the
    // seed's AUTO indexer fetched the whole ~44-chunk body + completed).
    try std.testing.expect(api.netFetchCount(doc) < 30);
    try std.testing.expectEqual(false, api.ls_index_poll(doc).complete);
}

test "nfd_ac6: search fetches up to the next match then parks CANCELLED" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    {
        var line: [48]u8 = undefined;
        for (0..600_000) |i| {
            if (i == 300_000) {
                try body.appendSlice(gpa, "NEEDLE,x\n");
            } else try body.appendSlice(gpa, try std.fmt.bufPrint(&line, "{d:0>8},{d:0>8}\n", .{ i, 2 * i }));
        }
    }
    var fx: api.NetFixture = .{ .body = body.items, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    try startSearch(doc, textReq("NEEDLE"));
    const s = try navAndWait(doc, 0, .forward);
    try std.testing.expectEqual(api.SearchNavState.found, s.nav);
    try std.testing.expectEqual(@as(u64, 300_000), s.found_row);
    // Demand-bounded: total counts only the scanned prefix (== position), NOT
    // exact, and the search PARKS at CANCELLED (RED: the seed drives the match-
    // scan to EOF -> state DONE / total_exact, and fetches the whole body).
    try std.testing.expectEqual(s.position, s.total);
    try std.testing.expectEqual(false, s.total_exact);
    try std.testing.expectEqual(api.SearchState.cancelled, api.ls_search_poll(doc).state);
    try std.testing.expect(api.netFetchCount(doc) < 30);
}

test "nfd_ac7: deep jump pays on demand; cancel freezes the frontier, no further fetch" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 900_000); // ~64 chunks
    defer gpa.free(body);
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    _ = settleIndex(doc, 200);
    // A deep jump toward a far row; cancel it, then prove the frontier froze and
    // no more bytes were fetched afterward (RED: the seed's AUTO indexer keeps
    // fetching in the background regardless of the jump cancel, and reaches EOF).
    api.ls_jump_start(doc, 850_000);
    api.ls_jump_cancel(doc);
    const c_after_cancel = api.netFetchCount(doc);
    netWait(250);
    try std.testing.expectEqual(c_after_cancel, api.netFetchCount(doc)); // no further fetch
    try std.testing.expectEqual(false, api.ls_index_poll(doc).complete); // not driven to EOF
    try std.testing.expect(api.netFetchCount(doc) < 60);
}

test "nfd_ac8: find-last / wrap runs as an explicit on-demand scan (not eager)" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    {
        var line: [48]u8 = undefined;
        for (0..600_000) |i| {
            if (i == 100_000 or i == 500_000) {
                try body.appendSlice(gpa, "HIT,x\n");
            } else try body.appendSlice(gpa, try std.fmt.bufPrint(&line, "{d:0>8},{d:0>8}\n", .{ i, 2 * i }));
        }
    }
    var fx: api.NetFixture = .{ .body = body.items, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    _ = settleIndex(doc, 200);
    // NOT eager: before any demand, the background has not scanned to EOF (RED:
    // the seed's AUTO indexer already did, over the wire).
    try std.testing.expectEqual(false, api.ls_index_poll(doc).complete);
    try std.testing.expect(api.netFetchCount(doc) <= net_head_chunks + 8);
    // Explicit find-last: a backward nav from past-EOF reaches the LAST match.
    try startSearch(doc, textReq("HIT"));
    const s = try navAndWait(doc, std.math.maxInt(u64), .backward);
    try std.testing.expectEqual(api.SearchNavState.found, s.nav);
    try std.testing.expectEqual(@as(u64, 500_000), s.found_row);
}

test "nfd_ac9: range-server plain CSV stays random-access; only the background indexer is suppressed" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 600_000);
    defer gpa.free(body);
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    try std.testing.expectEqual(api.NetRangeMode.random_access, api.netRangeMode(doc)); // unchanged
    // The ONLY behavior change vs the shipped slice: the row count firms on
    // demand, not in the background (RED: the seed's AUTO indexer completes the
    // index + makes the count exact unbidden).
    const ip = settleIndex(doc, 300);
    try std.testing.expectEqual(false, ip.complete);
    try std.testing.expectEqual(false, api.ls_row_count_get(doc).exact);
    // A jump near EOF still lands via random access without a prior full fetch.
    api.ls_jump_start(doc, 590_000);
    _ = try waitJumpDone(doc);
    _ = api.ls_window_set(doc, 590_000, 16);
    var b: [8]u8 = undefined;
    try expectCell(doc, 590_000, 0, fixedCell(&b, 590_000));
    try std.testing.expect(api.netFetchCount(doc) < 44); // never the whole file
}

test "nfd_ac10: .csv.gz composes over the growing spool; backward landing zero new fetch" {
    const gpa = std.testing.allocator;
    const plain = try genFixedRows(gpa, 400_000);
    defer gpa.free(plain);
    const g = try gz(gpa, plain);
    defer gpa.free(g);
    var fx: api.NetFixture = .{ .body = g, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    try std.testing.expectEqual(@as(u32, 2), api.ls_column_count(doc));
    // Composed over the http_range Source (RED: the seed's buildDownloadAll path
    // -> netRangeMode sequential_fallback + netFetchCount 0).
    try std.testing.expectEqual(api.NetRangeMode.random_access, api.netRangeMode(doc));
    try std.testing.expect(api.netFetchCount(doc) > 0);
    // Fetch a mid region, then land backward and prove ZERO new network fetch
    // (checkpoint replay into already-fetched compressed bytes).
    api.ls_jump_start(doc, 200_000);
    _ = try waitJumpDone(doc);
    _ = api.ls_window_set(doc, 200_000, 32);
    var b: [8]u8 = undefined;
    try expectCell(doc, 200_000, 0, fixedCell(&b, 200_000));
    const c_mid = api.netFetchCount(doc);
    _ = api.ls_window_set(doc, 10, 32); // backward landing behind the frontier
    try expectCell(doc, 10, 0, fixedCell(&b, 10));
    try std.testing.expectEqual(c_mid, api.netFetchCount(doc)); // zero new fetch
}

test "nfd_ac11: known-total sequential — bytes_total is the known size; row count is a projection" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 600_000);
    defer gpa.free(body);
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = false, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    try std.testing.expectEqual(api.NetRangeMode.sequential_fallback, api.netRangeMode(doc));
    const ip = settleIndex(doc, 300);
    try std.testing.expectEqual(@as(u64, body.len), ip.bytes_total); // known total
    try std.testing.expect(ip.bytes_total != api.bytes_total_unknown);
    try std.testing.expectEqual(false, ip.complete); // no background drive
    const rc = api.ls_row_count_get(doc);
    try std.testing.expectEqual(false, rc.exact); // free projection
    try std.testing.expect(rc.count > 0);
    try std.testing.expect(api.netFetchCount(doc) > 0); // streamed, not downloaded (RED)
}

test "nfd_ac12: unknown-length streaming — UINT64_MAX sentinel; nav to EOF firms it; empty distinct" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 300_000); // ~5.4 MiB, unknown length
    defer gpa.free(body);
    // 200 with no usable Content-Length: an unknown-length stream.
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = false, .advertise_length = false };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    const ip = settleIndex(doc, 300);
    try std.testing.expectEqual(api.bytes_total_unknown, ip.bytes_total); // UINT64_MAX sentinel (RED)
    try std.testing.expectEqual(false, ip.complete);
    try std.testing.expectEqual(false, api.ls_row_count_get(doc).exact); // discovered-rows lower bound
    // Navigate to EOF -> the total firms, complete + exact.
    try scanToEnd(doc);
    const ip2 = api.ls_index_poll(doc);
    try std.testing.expectEqual(true, ip2.complete);
    try std.testing.expect(ip2.bytes_total != api.bytes_total_unknown);
    try std.testing.expectEqual(true, api.ls_row_count_get(doc).exact);
    // A Content-Length: 0 resource opens as the EMPTY document (distinct from unknown).
    var efx: api.NetFixture = .{ .body = "", .honor_ranges = false, .advertise_length = true };
    const edoc = try openFakeToDone(&efx);
    defer api.ls_close(edoc);
    const eip = api.ls_index_poll(edoc);
    try std.testing.expectEqual(@as(u64, 0), eip.bytes_total); // {0,0,true}, NOT the sentinel
    try std.testing.expectEqual(true, eip.complete);
    try std.testing.expectEqual(@as(u64, 0), api.ls_row_count_get(edoc).count);
}

test "nfd_ac13: withhold-then-release — demand beyond released stays SCANNING, then advances" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 600_000); // ~10.8 MiB
    defer gpa.free(body);
    // Release the first 5 MiB (covers the 4 MiB head); withhold the rest.
    var gate: std.atomic.Value(u64) = .init(5 * 1024 * 1024);
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = false, .advertise_length = true, .withhold = &gate };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    // A demand jump PAST the released prefix stays SCANNING, fetching nothing past
    // what is released (RED: the seed ignores `withhold` + downloads the whole
    // body, so the jump completes immediately).
    api.ls_jump_start(doc, 500_000); // byte ~9 MiB, past the 5 MiB release
    netWait(150);
    try std.testing.expectEqual(api.JumpState.scanning, api.ls_jump_poll(doc).state);
    // Release the rest -> the demand advances to completion.
    gate.store(body.len, .release);
    const js = try waitJumpDone(doc);
    try std.testing.expectEqual(@as(u64, 500_000), js.landed_row);
    _ = api.ls_window_set(doc, 500_000, 16);
    var b: [8]u8 = undefined;
    try expectCell(doc, 500_000, 0, fixedCell(&b, 500_000));
}

test "nfd_ac14: never-re-fetch under streaming — re-access after cache eviction served from spool" {
    const gpa = std.testing.allocator;
    const plain = try genFixedRows(gpa, 300_000);
    defer gpa.free(plain);
    const g = try gz(gpa, plain);
    defer gpa.free(g);
    const cases = [_]api.NetFixture{
        .{ .body = plain, .honor_ranges = true, .advertise_length = true }, // random
        .{ .body = plain, .honor_ranges = false, .advertise_length = true }, // sequential
        .{ .body = g, .honor_ranges = true, .advertise_length = true }, // gzip
    };
    for (cases) |fixture| {
        var fx = fixture;
        const doc = try openFakeToDone(&fx);
        defer api.ls_close(doc);
        winAll(doc);
        _ = api.ls_window_set(doc, 0, 64);
        const after_first = api.netFetchCount(doc);
        try std.testing.expect(after_first > 0); // streamed (RED: seq/gzip seed download-all -> 0)
        api.netForceCacheBytes(doc, 0); // evict the resident RAM cache entirely
        _ = api.ls_window_set(doc, 0, 64); // re-access the SAME range
        try std.testing.expectEqual(after_first, api.netFetchCount(doc)); // from spool, no new fetch
    }
}

test "nfd_ac15: sequential fill only extends the prefix; backward landing reads spool, zero network" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 500_000);
    defer gpa.free(body);
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = false, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    try std.testing.expectEqual(api.NetRangeMode.sequential_fallback, api.netRangeMode(doc));
    // Drain forward to a mid row (extends the contiguous downloaded prefix).
    api.ls_jump_start(doc, 300_000);
    _ = try waitJumpDone(doc);
    var b: [8]u8 = undefined;
    _ = api.ls_window_set(doc, 300_000, 16);
    try expectCell(doc, 300_000, 0, fixedCell(&b, 300_000));
    const c_mid = api.netFetchCount(doc);
    try std.testing.expect(c_mid > 0); // streamed (RED: seed download-all -> 0)
    // Backward landing reads the already-downloaded spool prefix, zero network.
    _ = api.ls_window_set(doc, 5, 16);
    try expectCell(doc, 5, 0, fixedCell(&b, 5));
    try std.testing.expectEqual(c_mid, api.netFetchCount(doc)); // zero new fetch backward
    try std.testing.expectEqual(false, api.ls_index_poll(doc).complete); // not driven to EOF
}

test "nfd_ac16: post-open stream drop terminates the document at the received bytes" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 600_000); // ~10.8 MiB nominal
    defer gpa.free(body);
    // The stream drops after ~6 MiB (~349k rows): the document ends at the
    // received bytes (the gzip damaged-EOF analog).
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = false, .advertise_length = false, .drop_after = 6 * 1024 * 1024 };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    // Drive to the truncated EOF: index/search reach terminal states over the
    // received prefix; the count is FEWER than the nominal full body (RED: the
    // seed serves the whole body -> 600k rows).
    try scanToEnd(doc);
    const ip = api.ls_index_poll(doc);
    try std.testing.expectEqual(true, ip.complete); // terminal over the received prefix
    try std.testing.expect(ip.bytes_total != api.bytes_total_unknown); // firmed to received size
    const rc = api.ls_row_count_get(doc);
    try std.testing.expectEqual(true, rc.exact);
    try std.testing.expect(rc.count < 600_000);
    try std.testing.expect(rc.count > 0);
    // Received rows are servable (row 300000 is within the ~349k received).
    _ = api.ls_window_set(doc, 300_000, 16);
    var b: [8]u8 = undefined;
    try expectCell(doc, 300_000, 0, fixedCell(&b, 300_000));
}

test "nfd_ac17: decideProbe / parseContentRangeTotal units (streaming classification)" {
    // parseContentRangeTotal: extract the resource total (or null for absent / *).
    try std.testing.expectEqual(@as(?u64, 12345), api.parseContentRangeTotal("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-99/12345\r\n\r\n"));
    try std.testing.expectEqual(@as(?u64, null), api.parseContentRangeTotal("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-99/*\r\n\r\n"));
    try std.testing.expectEqual(@as(?u64, null), api.parseContentRangeTotal("HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n"));
    // 206 + Content-Range total -> RANDOM fill / known.
    {
        const d = api.decideProbe(206, 100, 12345, false);
        try std.testing.expectEqual(true, d.range);
        try std.testing.expectEqual(@as(u64, 12345), d.total);
        try std.testing.expectEqual(true, d.length_known);
    }
    // 200 + Content-Length -> SEQUENTIAL fill / known.
    {
        const d = api.decideProbe(200, 500, null, false);
        try std.testing.expectEqual(false, d.range);
        try std.testing.expectEqual(@as(u64, 500), d.total);
        try std.testing.expectEqual(true, d.length_known);
    }
    // 200 with an ABSENT Content-Length (null) -> SEQUENTIAL fill / UNKNOWN length
    // (RED: the seed always reports length_known = true).
    {
        const d = api.decideProbe(200, null, null, false);
        try std.testing.expectEqual(false, d.range);
        try std.testing.expectEqual(false, d.length_known);
    }
    // Content-Length: 0 (present zero) -> EMPTY, length_known (distinct from unknown).
    {
        const d = api.decideProbe(200, 0, null, false);
        try std.testing.expectEqual(true, d.length_known);
        try std.testing.expectEqual(@as(u64, 0), d.total);
    }
    // A gzip magic verdict no longer forces range=false on a range server (RED:
    // the seed still forces range = !is_gz = false).
    {
        const d = api.decideProbe(206, 100, 12345, true);
        try std.testing.expectEqual(true, d.range);
        try std.testing.expectEqual(true, d.is_gz);
    }
}

test "nfd_ac18: determinism pin — a small resource fitting the head is exact at open; a large one is not" {
    const gpa = std.testing.allocator;
    const small = "a,b\n1,2\n3,4\n5,6\n"; // << head; fully fetched at open
    inline for (.{ true, false }) |known| { // known-length and unknown-length
        var fx: api.NetFixture = .{ .body = small, .honor_ranges = false, .advertise_length = known };
        const doc = try openFakeToDone(&fx);
        defer api.ls_close(doc);
        const rc = api.ls_row_count_get(doc);
        try std.testing.expectEqual(true, rc.exact); // small -> exact at open
        try std.testing.expectEqual(@as(u64, 3), rc.count);
        try std.testing.expectEqual(true, api.ls_index_poll(doc).complete);
        try std.testing.expect(api.netFetchCount(doc) > 0); // streamed (RED: seq seed download-all -> 0)
    }
    // A large one is NOT exact at open (no background drive).
    const big = try genFixedRows(gpa, 600_000);
    defer gpa.free(big);
    var bfx: api.NetFixture = .{ .body = big, .honor_ranges = true, .advertise_length = true };
    const bdoc = try openFakeToDone(&bfx);
    defer api.ls_close(bdoc);
    _ = settleIndex(bdoc, 300);
    try std.testing.expectEqual(false, api.ls_row_count_get(bdoc).exact); // RED: seed AUTO makes it exact
}

test "nfd_ac19: memory bound — resident RAM within ceiling; streamed, not fully resident" {
    const gpa = std.testing.allocator;
    const plain = try genFixedRows(gpa, 600_000);
    defer gpa.free(plain);
    const g = try gz(gpa, plain);
    defer gpa.free(g);
    const cases = [_]api.NetFixture{
        .{ .body = plain, .honor_ranges = true, .advertise_length = true }, // random
        .{ .body = g, .honor_ranges = true, .advertise_length = true }, // gzip
    };
    for (cases) |fixture| {
        var fx = fixture;
        const doc = try openFakeToDone(&fx);
        defer api.ls_close(doc);
        var r: u64 = 0;
        while (r < 550_000) : (r += 50_000) {
            api.ls_jump_start(doc, r);
            _ = try waitJumpDone(doc);
            _ = api.ls_window_set(doc, r, 128);
            try std.testing.expect(api.netResidentBytes(doc) <= 16 * 1024 * 1024);
        }
        try std.testing.expect(api.netFetchCount(doc) > 0); // streamed (RED: gzip seed -> 0)
    }
}

test "nfd_ac20: spool hygiene incl. unknown-length growth (0600, unlinked, grows, present while live)" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 400_000);
    defer gpa.free(body);
    // Unknown-length stream: the spool cannot be presized; it grows as the
    // frontier advances (RED: the seed's buildDownloadAll doc has no http_range
    // spool -> netSpoolStore.present is false).
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = false, .advertise_length = false };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    const sp0 = api.netSpoolStore(doc);
    try std.testing.expectEqual(true, sp0.present);
    try std.testing.expectEqual(@as(u32, 0o600), sp0.mode);
    try std.testing.expectEqual(true, sp0.unlinked);
    const bytes0 = sp0.bytes;
    // Advance the frontier -> the unknown-length spool GROWS.
    api.ls_jump_start(doc, 300_000);
    _ = try waitJumpDone(doc);
    const sp1 = api.netSpoolStore(doc);
    try std.testing.expect(sp1.bytes > bytes0);
    try std.testing.expect(api.netFetchCount(doc) > 0);
}

test "nfd_ac21: local non-regression — the AUTO background indexer still runs for local docs (GUARD)" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 600_000); // > head: a local AUTO doc completes in the background
    defer gpa.free(body);
    var od = try openWith(body, .{}); // AUTO local
    defer od.deinit();
    // The lazy gate keys on SOURCE KIND: a LOCAL document's AUTO indexer still
    // drives the frontier to EOF unbidden (the net gate must NOT suppress it).
    // GREEN from the seed, and MUST STAY green after the fix.
    const ip = settleIndex(od.doc, 8000);
    try std.testing.expectEqual(true, ip.complete);
    try std.testing.expectEqual(true, api.ls_row_count_get(od.doc).exact);
    try std.testing.expect(ip.bytes_total != api.bytes_total_unknown);
    try std.testing.expectEqual(api.NetRangeMode.unknown, api.netRangeMode(od.doc)); // not a network doc
}

test "nfd_ac22: cancellation — cancel mid-demand; close during a demand joins cleanly" {
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 600_000);
    defer gpa.free(body);
    // Withhold beyond the head so a demand jump is genuinely in-flight (SCANNING)
    // when we cancel it (RED: the seed serves the whole body, so the jump is never
    // in-flight and the SCANNING assertion fails).
    var gate: std.atomic.Value(u64) = .init(5 * 1024 * 1024);
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = false, .advertise_length = true, .withhold = &gate };
    const doc = try openFakeToDone(&fx);
    api.ls_jump_start(doc, 500_000); // past the released prefix -> in flight
    netWait(120);
    try std.testing.expectEqual(api.JumpState.scanning, api.ls_jump_poll(doc).state);
    api.ls_jump_cancel(doc);
    // ls_close while the (cancelled) demand is settling joins cleanly and unmaps
    // once; the leak-checking test allocator + no hang are the proof.
    api.ls_close(doc);
}

test "nfd_ac23: on-paper Parquet/ODS proof over the streaming byte source is a review criterion (GUARD)" {
    // AC23 is a DESIGN-REVIEW criterion: ARCH-never-full-download-streaming.md
    // carries the on-paper proof that random fill serves Parquet footer-first /
    // ODS ZIP-central-directory reads, and sequential fill is CSV's degenerate
    // case -- both the same "ask for any [start,end)" primitive, NO Source/
    // interface change. Verified by the architect/human. The observable
    // consequence pinned here: a non-network document is unaffected.
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    try std.testing.expectEqual(api.NetRangeMode.unknown, api.netRangeMode(od.doc));
    try std.testing.expectEqual(@as(u64, 0), api.netFetchCount(od.doc));
}

test "nfd_ac24: dependencies & size — Zig std only (std.http.Client / std.crypto.tls) (GUARD)" {
    // AC24 (GUARD): no new RUNTIME dependency (enforced by the frozen build.zig,
    // stdlib-only, no build.zig.zon); the app stays single-digit MB (a reviewer
    // size measurement). This pins that the approved networking primitives are std.
    _ = std.http.Client;
    _ = std.crypto.tls.Client;
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    try expectDims(od.doc, 1, 2);
}

test "nfd_ac25: network filter parks CANCELLED and advances only on a filtered demand — no full download" {
    // REGRESSION LOCK for the filter net-park (src/filter.zig setFilter `if (d.net)`)
    // — the filtered twin of the search net-park (nfd_ac6). A NETWORK filtered view
    // launches NO to-EOF filter scan: it PARKS immediately at CANCELLED (the filter
    // MODE is active and the view IS filtered) and the frontier advances ONLY on a
    // filtered demand, never as a background drive over the wire ("No full download,
    // ever" applied to filtering). Without the guard, the degraded (worker == null)
    // synchronous to-EOF loop / a background `.scanning` drive would fetch the whole
    // resource — exactly the finding-1 regression this AC locks.
    const gpa = std.testing.allocator;
    const body = try genFixedRows(gpa, 600_000); // ~10.8 MiB (~42 chunks) >> 4 MiB head
    defer gpa.free(body);
    var fx: api.NetFixture = .{ .body = body, .honor_ranges = true, .advertise_length = true };
    const doc = try openFakeToDone(&fx);
    defer api.ls_close(doc);
    _ = settleIndex(doc, 200); // let open's head work settle (no background drive on net)

    // (1)+(2) The filter is SET (returns true; the mode is ACTIVE and the view IS
    // filtered) but its to-EOF scan PARKS immediately at CANCELLED — NOT `.scanning`
    // to EOF, NOT `.done` with an exact whole-file total (mirror nfd_ac6's search
    // net-park `ls_search_poll(doc).state == .cancelled`). The predicate matches
    // EVERY row, so a naive eager count would have to fetch the whole body.
    try setFilter(doc, predReq(0, .ge, "00000000")); // col 0 >= 0: matches every row
    try std.testing.expectEqual(api.FilterState.cancelled, api.ls_filter_poll(doc).state);
    try std.testing.expectEqual(false, api.ls_row_count_get(doc).exact); // no whole-file total

    // (3) HEADLINE — no full download / no background growth: the park fetched only
    // ~the head, and both netFetchCount and the frontier stay FLAT across a
    // poll-wait-poll (mirror nfd_ac4's capture-c0 / wait / expectEqual technique). A
    // worker-driven or degraded to-EOF filter scan would grow both and complete the
    // index over the wire.
    const c0 = api.netFetchCount(doc);
    try std.testing.expect(c0 <= net_head_chunks + 8); // head-only, not the whole body
    const f0 = api.ls_index_poll(doc).bytes_scanned;
    netWait(300);
    try std.testing.expectEqual(c0, api.netFetchCount(doc)); // no background fetch
    try std.testing.expectEqual(f0, api.ls_index_poll(doc).bytes_scanned); // frontier frozen
    try std.testing.expectEqual(false, api.ls_index_poll(doc).complete);
    try std.testing.expectEqual(false, api.ls_row_count_get(doc).exact);

    // (4) ON-DEMAND — a filtered jump AFTER the park drives the filter-scan on the
    // worker to advance the frontier toward the target by a BOUNDED amount, fetching
    // only what is needed (never to EOF), then RE-PARKS at CANCELLED (mirror nfd_ac5's
    // bounded scroll + the net-park re-entry). `target` is an ORIGINAL row; every row
    // matches, so filtered index == original row (identity mapping).
    api.ls_jump_start(doc, 300_000);
    _ = try waitJumpDone(doc);
    _ = api.ls_window_set(doc, 300_000, 64);
    var b: [8]u8 = undefined;
    try expectCell(doc, 300_000, 0, fixedCell(&b, 300_000)); // newly demanded row servable + correct
    try std.testing.expectEqual(@as(u64, 300_000), api.ls_source_row(doc, 300_000)); // identity (all match)
    try std.testing.expect(api.netFetchCount(doc) < 30); // advanced toward the target, NOT to EOF
    try std.testing.expectEqual(false, api.ls_index_poll(doc).complete);
    try std.testing.expectEqual(api.FilterState.cancelled, api.ls_filter_poll(doc).state); // re-parked

    // (5) GUARD — local non-regression: a LOCAL filter (doc.net == false) still scans
    // to DONE / exact. The fv2..fv15 series covers the full local filtered view and
    // nfd_ac21 covers the local AUTO indexer staying live; not duplicated here.
}

// ===========================================================================
// thin-frontend-shared-core slice — Phase 1: per-window MATCH FLAGS
// (ls_window_match_flags). Semantics pinned in api/lesssheet.h "MATCH-FLAGS
// EXTENSION" and mirrored in contracts/api.zig. Tests exercise the PUBLIC C ABI
// through @import("api") only, reusing the helpers above (openBytes/openWith,
// winAll, textReq/textReqScoped/predReq/startSearch, setFilter/waitFilterDone,
// fv_fixture). RED against the current seed (window.matchFlags returns the empty
// Str): every verdict assertion expects a win_rows*col_count buffer of 1/0 and
// fails on the empty buffer — a BEHAVIOR red, not a compile/link error.
//
// Naming maps to ARCH-thin-frontend-shared-core Phase-1 ACs: mf1-mf3 + mf8 ->
// AC1 (byte-identical verdicts, incl. exact-decimal + the filter note); mf4 ->
// AC2 (scope); mf5 -> AC3 (IDLE); mf6 -> AC4 (column-windowed & bounded);
// mf7 -> AC5 (borrow discipline & recompute cadence).
// Determinism: fixtures are far below the head budget (fully indexed at open),
// so ls_window_match_flags is read RIGHT AFTER ls_search_start WITHOUT waiting
// for the match-scan — the flags come from the active request + the already
// materialized window, never the scan (a pinned property of the call).
//
// The golden 1/0 arrays were generated from the CURRENT frontend CellMatcher
// (apps/macos/.../FindLogic.swift — the byte-identical duplicate Phase 1
// deletes) over the same fixture cells, so "byte-identical to the matcher" is
// locked from both sides (this backend suite + the macOS golden bridge test).
// ===========================================================================

fn matchFlags(doc: *const api.Doc, first_col: u32, col_count: u32) []const u8 {
    return api.ls_window_match_flags(doc, first_col, col_count).slice();
}

/// A rows x cols delimited fixture (no header; header forced OFF at open) whose
/// `hit_col` cell is "hit" and every other cell is "v" — for the AC4 wide-doc
/// probe (column-windowed cost independent of ls_column_count).
fn genWide(gpa: std.mem.Allocator, cols: u32, rows: u32, hit_col: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (0..rows) |_| {
        for (0..cols) |c| {
            if (c > 0) try buf.append(gpa, ',');
            try buf.appendSlice(gpa, if (c == hit_col) "hit" else "v");
        }
        try buf.append(gpa, '\n');
    }
    return buf.toOwnedSlice(gpa);
}

// --- mf1..mf8 — the per-window match-flags companion call --------------------

test "mf1: AC1 TEXT smart-case per-cell verdicts are byte-identical to the matcher" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    winAll(od.doc);

    // Lowercase query folds ASCII case (no ASCII uppercase byte).
    try startSearch(od.doc, textReq("needle"));
    try std.testing.expectEqualSlices(u8, &.{
        0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1,
    }, matchFlags(od.doc, 0, 3));

    // One ASCII uppercase byte -> byte-exact: only "Needle point" (row 3, col 2).
    try startSearch(od.doc, textReq("Needle"));
    try std.testing.expectEqualSlices(u8, &.{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    }, matchFlags(od.doc, 0, 3));

    // Non-ASCII bytes always compare exactly: "café" hits only row 5, col 0
    // (the col-2 "CAFÉ" folds only its ASCII bytes, so it does NOT match).
    try startSearch(od.doc, textReq("café"));
    try std.testing.expectEqualSlices(u8, &.{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    }, matchFlags(od.doc, 0, 3));

    // Dense single letter — broad coverage across all three columns.
    try startSearch(od.doc, textReq("e"));
    try std.testing.expectEqualSlices(u8, &.{
        1, 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 1, 0, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1,
    }, matchFlags(od.doc, 0, 3));
}

test "mf2: AC1 PREDICATE eq/ne + numeric ordering per-cell verdicts (qty column)" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    winAll(od.doc);

    // qty <= 2 : rows 0(2),2(2.0),3(-3),5(0.5).
    try startSearch(od.doc, predReq(1, .le, "2"));
    try std.testing.expectEqualSlices(u8, &.{
        0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
    }, matchFlags(od.doc, 0, 3));

    // qty > 2 : rows 1(10),4(1e2=100),6(5.).
    try startSearch(od.doc, predReq(1, .gt, "2"));
    try std.testing.expectEqualSlices(u8, &.{
        0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0,
    }, matchFlags(od.doc, 0, 3));

    // qty < 1e2 (== 100): everything numeric below 100 (rows 0,1,2,3,5,6).
    try startSearch(od.doc, predReq(1, .lt, "1e2"));
    try std.testing.expectEqualSlices(u8, &.{
        0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0,
    }, matchFlags(od.doc, 0, 3));

    // qty == 2.0 is BYTE-EXACT: only the literal "2.0" (row 2); "2" does NOT.
    try startSearch(od.doc, predReq(1, .eq, "2.0"));
    try std.testing.expectEqualSlices(u8, &.{
        0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    }, matchFlags(od.doc, 0, 3));

    // qty != 10 is BYTE-EXACT: every row except the literal "10" (row 1).
    try startSearch(od.doc, predReq(1, .ne, "10"));
    try std.testing.expectEqualSlices(u8, &.{
        0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0,
    }, matchFlags(od.doc, 0, 3));
}

test "mf3: AC1 exact-decimal ordering edge cases (never through f64)" {
    // header OFF -> record 1 ("2.0", numeric) is data row 0; 9 data rows, 1 col.
    const dec_fixture =
        "2.0\n2\n100\n1e2\n1e400\n1e399\n" ++
        "1234567890123456789012345678901234567890\n" ++ // 40-digit A
        "1234567890123456789012345678901234567891\n" ++ // 40-digit B = A + 1
        "abc\n";
    var od = try openWith(dec_fixture, .{ .header = api.header_off, .index_mode = api.index_manual });
    defer od.deinit();
    winAll(od.doc);

    // == "2" is byte-exact: only the literal "2" (row 1); "2.0" does NOT.
    try startSearch(od.doc, predReq(0, .eq, "2"));
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 0, 0, 0, 0, 0, 0 }, matchFlags(od.doc, 0, 1));

    // >= 1e2 (== 100): 100, 1e2, 1e400, 1e399, and both 40-digit ints; "abc" no.
    try startSearch(od.doc, predReq(0, .ge, "1e2"));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 1, 1, 1, 1, 1, 0 }, matchFlags(od.doc, 0, 1));

    // > 1e399: only 1e400 (both overflow an f64 but order exactly).
    try startSearch(od.doc, predReq(0, .gt, "1e399"));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 0, 0, 0, 0 }, matchFlags(od.doc, 0, 1));

    // < the larger 40-digit int B: the small values + A, never the two 1e39x
    // giants (both >> B) nor B itself nor "abc".
    try startSearch(od.doc, predReq(0, .lt, "1234567890123456789012345678901234567891"));
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 0, 0, 1, 0, 0 }, matchFlags(od.doc, 0, 1));

    // != "100" is byte-exact: "1e2" (numerically 100) still differs BYTE-wise.
    try startSearch(od.doc, predReq(0, .ne, "100"));
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 0, 1, 1, 1, 1, 1, 1 }, matchFlags(od.doc, 0, 1));
}

test "mf4: AC2 scope is part of the verdict (TEXT in-scope cols; PREDICATE target col)" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    winAll(od.doc);

    // TEXT scoped to columns {0, 2}: the qty column (1) is NEVER flagged even
    // though "1e2" (row 4, col 1) contains 'e' — scope excludes it.
    try startSearch(od.doc, textReqScoped("e", &.{ 0, 2 }));
    try std.testing.expectEqualSlices(u8, &.{
        1, 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1,
    }, matchFlags(od.doc, 0, 3));

    // TEXT scoped to {0}: only the name column can be 1.
    try startSearch(od.doc, textReqScoped("e", &.{0}));
    try std.testing.expectEqualSlices(u8, &.{
        1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    }, matchFlags(od.doc, 0, 3));

    // PREDICATE flags ONLY its target column (1); columns 0 and 2 stay 0.
    try startSearch(od.doc, predReq(1, .eq, "2"));
    try std.testing.expectEqualSlices(u8, &.{
        0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    }, matchFlags(od.doc, 0, 3));
}

test "mf5: AC3 IDLE returns the empty ls_str (no highlights)" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    winAll(od.doc);
    // No search started since open -> LS_SEARCH_IDLE -> empty buffer.
    try std.testing.expectEqual(api.SearchState.idle, api.ls_search_poll(od.doc).state);
    try std.testing.expectEqual(@as(usize, 0), matchFlags(od.doc, 0, 3).len);
    // A ptr is still valid (never NULL), just with len 0 — like an empty ls_cell.
    try std.testing.expect(@intFromPtr(api.ls_window_match_flags(od.doc, 0, 3).ptr) != 0);
}

test "mf6: AC4 column-windowed & bounded (sub-range slices; out-of-range -> empty; O(cols))" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    winAll(od.doc);
    try startSearch(od.doc, textReq("needle"));

    // Full width [0,3): the 24-byte verdict.
    try std.testing.expectEqual(@as(usize, 24), matchFlags(od.doc, 0, 3).len);
    // Sub-range [2,1) — the note column only (stride 1).
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 1, 0, 0, 1, 1 }, matchFlags(od.doc, 2, 1));
    // Sub-range [0,2) — name+qty only (stride 2), a slice of the full verdict.
    try std.testing.expectEqualSlices(u8, &.{
        0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    }, matchFlags(od.doc, 0, 2));
    // Empty / out-of-range column ranges -> the empty ls_str (len 0).
    try std.testing.expectEqual(@as(usize, 0), matchFlags(od.doc, 0, 0).len); // col_count 0
    try std.testing.expectEqual(@as(usize, 0), matchFlags(od.doc, 3, 1).len); // first_col >= column_count
    try std.testing.expectEqual(@as(usize, 0), matchFlags(od.doc, 2, 2).len); // range spills past column_count

    // Wide-doc probe: the output (and work) is O(requested cols), NOT
    // O(ls_column_count). 64 columns, 2 rows, "hit" only in column 5.
    const gpa = std.testing.allocator;
    const wide = try genWide(gpa, 64, 2, 5);
    defer gpa.free(wide);
    var wd = try openWith(wide, .{ .header = api.header_off, .index_mode = api.index_manual });
    defer wd.deinit();
    try std.testing.expectEqual(@as(u32, 64), api.ls_column_count(wd.doc));
    winAll(wd.doc);
    try startSearch(wd.doc, predReq(5, .eq, "hit"));
    // Request only columns [4,7): 2 rows x 3 cols = 6 bytes (NOT 2 x 64), with
    // the "hit" flag on column 5 (the middle slot) of each row.
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 0, 1, 0 }, matchFlags(wd.doc, 4, 3));
}

test "mf7: AC5 the buffer tracks the current window and search (recompute cadence)" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    winAll(od.doc);
    try startSearch(od.doc, textReq("needle"));
    try std.testing.expectEqual(@as(usize, 24), matchFlags(od.doc, 0, 3).len);

    // A NEW window (rows 3..6) recomputes over the new rows only: the length
    // shrinks to win_rows*col_count and the verdicts are those rows' (the
    // previous buffer is invalidated by ls_window_set — the ls_cell borrow rule).
    _ = api.ls_window_set(od.doc, 3, 3);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 0, 0, 0, 0, 0 }, matchFlags(od.doc, 0, 3));

    // A NEW search over the SAME window recomputes the verdict WITHOUT a
    // window_set (memoization is keyed on window OR search change): qty > 2 over
    // rows 3(-3),4(100),5(0.5).
    try startSearch(od.doc, predReq(1, .gt, "2"));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 0, 0, 0, 0 }, matchFlags(od.doc, 0, 3));
}

test "mf8: AC1 a filter changes WHICH rows the window holds, not the per-cell verdict" {
    var od = try openBytes(fv_fixture);
    defer od.deinit();
    // Filter to rows with ANY cell containing "needle" -> sources 0,1,2,3,6,7.
    try setFilter(od.doc, textReq("needle"));
    _ = try waitFilterDone(od.doc);
    winAll(od.doc); // materialize the 6 filtered rows
    // Search the same predicate in FILTERED coordinates.
    try startSearch(od.doc, textReq("needle"));
    // The per-cell verdict is identical to mf1's needle case with rows 4,5 (the
    // two rows that hold no "needle") simply absent from the filtered view.
    try std.testing.expectEqualSlices(u8, &.{
        0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1,
    }, matchFlags(od.doc, 0, 3));
}

// ===========================================================================
// thin-frontend-shared-core slice — Phase 2 (ARCH-thin-frontend-shared-core).
// cp1..cp_perf: the core-framed streaming TSV COPY JOB (ls_copy_open /
// ls_copy_next / ls_copy_close). The concatenated ls_copy_next chunks must be
// BYTE-IDENTICAL to the deleted frontend TSVCopyBuilder — TAB (0x09) field
// separators, LF (0x0A) row separators, NO trailing separator, spreadsheet
// quoting (quote a cell containing TAB/CR/LF/quote; double interior quotes), the
// single-cell raw special-case, lossless cells (no LS_CELL_MAX_BYTES display
// cap), and the LS_COPY_MAX_CELLS safety cap reported via budget_capped. Tests
// exercise the PUBLIC C ABI (@import("api")) plus the Zig-only cap seam
// (copyCapCellsForTest — NOT the C ABI, like copyAdvances), so api/lesssheet.h is
// byte-identical.
//
// SEED: ls_copy_next reports DONE with 0 bytes -> the framing / STALLED /
// rows_done / budget_capped / advance-count behaviors are RED (empty output,
// never stalls, rows_done 0, never capped, 0 advances); the lifecycle hygiene
// (empty/out-of-range rects DONE-0, cancel/drain leak nothing) + the ABI link /
// enum-value pins are GREEN-by-construction. RED -> GREEN: the implementer builds
// the row-major sweep + TSV framing here, reusing window.zig's forward COPY
// CURSOR (behind ls_cell_copy).
// ===========================================================================

const CopyDrive = struct {
    bytes: std.ArrayList(u8),
    steps: usize, // number of MORE chunks
    stalls: usize, // number of STALLED steps handled (via a jump)
    rows_done: u64, // last reported rows_done (its value at DONE)
    monotone: bool, // rows_done never regressed across the stream
    boundary_ok: bool, // every chunk's `written` <= buf_len; STALLED wrote 0
    budget_capped: bool, // budget_capped reported on DONE

    fn deinit(self: *CopyDrive, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }
};

fn copyRect(first_row: u64, row_count: u64, first_col: u32, col_count: u32) api.CopyRect {
    return .{ .first_row = first_row, .row_count = row_count, .first_col = first_col, .col_count = col_count };
}

/// Drive a WHOLE streaming copy of `sel` in `buf_len`-byte chunks, advancing the
/// shared frontier (public ls_jump_start) on STALLED and retrying, until DONE.
/// Accumulates the framed TSV bytes and records the streaming invariants.
fn driveCopy(gpa: std.mem.Allocator, doc: *api.Doc, sel: api.CopyRect, buf_len: usize) !CopyDrive {
    const rr = sel;
    const job = api.ls_copy_open(doc, &rr) orelse return error.CopyOpenFailed;
    defer api.ls_copy_close(job);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const buf = try gpa.alloc(u8, buf_len);
    defer gpa.free(buf);

    var steps: usize = 0;
    var stalls: usize = 0;
    var last: u64 = 0;
    var monotone = true;
    var boundary_ok = true;
    var capped = false;
    var guard: usize = 0;
    while (true) {
        guard += 1;
        if (guard > 10_000_000) return error.CopyRunaway;
        const p = api.ls_copy_next(job, buf.ptr, buf.len);
        if (p.rows_done < last) monotone = false;
        last = p.rows_done;
        switch (p.step) {
            .more => {
                steps += 1;
                if (p.written > buf.len) boundary_ok = false;
                try out.appendSlice(gpa, buf[0..p.written]);
            },
            .done => {
                if (p.written > buf.len) boundary_ok = false;
                try out.appendSlice(gpa, buf[0..p.written]);
                capped = p.budget_capped;
                break;
            },
            .stalled => {
                stalls += 1;
                if (p.written != 0) boundary_ok = false;
                api.ls_jump_start(doc, p.stalled_row);
                _ = try waitJumpDone(doc);
            },
        }
    }
    return .{ .bytes = out, .steps = steps, .stalls = stalls, .rows_done = last, .monotone = monotone, .boundary_ok = boundary_ok, .budget_capped = capped };
}

// The full fv_fixture copy, row-major, TSV-framed (TSVCopyBuilder rules). No cell
// contains TAB/CR/LF/quote, so every cell is raw; row 6's empty name is a leading
// empty field; no trailing newline. This is ALSO the macOS bridge test's golden
// (find.csv == fv_fixture, byte-for-byte).
const fv_full_tsv =
    "Widget\t2\talpha needle\n" ++
    "NEEDLE\t10\tbeta\n" ++
    "needle\t2.0\tgamma\n" ++
    "gadget\t-3\tNeedle point\n" ++
    "Gizmo\t1e2\tdelta\n" ++
    "café\t0.5\tCAFÉ\n" ++
    "\t5.\tneedleneedle\n" ++
    "plain\tabc\tend needle";

// Quoting fixture (== apps/macos .../Fixtures/copyquote.csv): header on (c1,c2
// non-numeric); data row 0 col0 has a literal TAB, col1 a literal double-quote;
// data row 1 col0 is a quoted field with an embedded LF. Each special cell must
// be spreadsheet-quoted on copy.
const cp_quote_fixture = "c1,c2\na\tb,x\"y\n\"p\nq\",plain\n";
const cp_quote_opts: api.OpenOptions = .{ .separator = ',', .header = api.header_on, .index_mode = api.index_manual };

test "cp1: AC1 TSV framing byte-identical to TSVCopyBuilder — plain cells, empty cell, single-cell raw, column sub-window" {
    const gpa = std.testing.allocator;
    var od = try openBytes(fv_fixture); // MANUAL; <= head budget -> fully indexed, every row servable
    defer od.deinit();

    // Full 8x3 selection in one big chunk.
    {
        var d = try driveCopy(gpa, od.doc, copyRect(0, 8, 0, 3), 1 << 16);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings(fv_full_tsv, d.bytes.items);
        try std.testing.expectEqual(@as(u64, 8), d.rows_done);
        try std.testing.expect(d.monotone and d.boundary_ok and !d.budget_capped);
    }
    // Single cell (row 0, col 0) -> RAW value, no newline, no quoting.
    {
        var d = try driveCopy(gpa, od.doc, copyRect(0, 1, 0, 1), 1 << 16);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("Widget", d.bytes.items);
    }
    // Single EMPTY cell (row 6, col 0 == "") -> empty output.
    {
        var d = try driveCopy(gpa, od.doc, copyRect(6, 1, 0, 1), 1 << 16);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("", d.bytes.items);
    }
    // The empty cell inside a MULTI-cell row is a leading empty field.
    {
        var d = try driveCopy(gpa, od.doc, copyRect(6, 1, 0, 3), 1 << 16);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("\t5.\tneedleneedle", d.bytes.items);
    }
    // Column sub-window: qty column only (col 1), rows 0..2 -> multi-row single col.
    {
        var d = try driveCopy(gpa, od.doc, copyRect(0, 3, 1, 1), 1 << 16);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("2\n10\n2.0", d.bytes.items);
    }
}

test "cp2: AC1 spreadsheet quoting (TAB / quote / embedded-newline cells); single-cell raw bypasses quoting" {
    const gpa = std.testing.allocator;
    var od = try openWith(cp_quote_fixture, cp_quote_opts);
    defer od.deinit();
    try expectDims(od.doc, 2, 2);

    // Full 2x2: each special cell quoted (interior quote doubled), plain raw.
    {
        var d = try driveCopy(gpa, od.doc, copyRect(0, 2, 0, 2), 1 << 16);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("\"a\tb\"\t\"x\"\"y\"\n\"p\nq\"\tplain", d.bytes.items);
    }
    // The SAME tab-containing cell as a SINGLE-cell copy is RAW (never quoted).
    {
        var d = try driveCopy(gpa, od.doc, copyRect(0, 1, 0, 1), 1 << 16);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("a\tb", d.bytes.items);
    }
}

test "cp3: AC1 lossless (cell past the 4 KiB display cap read WHOLE) + AC3 tiny-buffer chunks concatenate identically" {
    const gpa = std.testing.allocator;
    // A first cell of 5000 'A' (> LS_CELL_MAX_BYTES 4096), then a 2nd column.
    var fx: std.ArrayList(u8) = .empty;
    defer fx.deinit(gpa);
    try fx.appendSlice(gpa, "h1,h2\n");
    var i: usize = 0;
    while (i < 5000) : (i += 1) try fx.append(gpa, 'A');
    try fx.appendSlice(gpa, ",tail\n");
    var od = try openWith(fx.items, .{ .separator = ',', .header = api.header_on, .index_mode = api.index_manual });
    defer od.deinit();
    try expectDims(od.doc, 1, 2);

    // Expected TSV = <5000 A> \t tail (lossless: the full cell, NOT capped at 4096).
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    i = 0;
    while (i < 5000) : (i += 1) try expected.append(gpa, 'A');
    try expected.appendSlice(gpa, "\ttail");

    // Big buffer: whole selection in one shot.
    var big = try driveCopy(gpa, od.doc, copyRect(0, 1, 0, 2), 1 << 16);
    defer big.deinit(gpa);
    try std.testing.expectEqualStrings(expected.items, big.bytes.items);

    // Tiny buffer forces the oversized field to split across chunks (at code-point
    // boundaries): the concatenation is byte-identical, and no chunk exceeds buf_len.
    var small = try driveCopy(gpa, od.doc, copyRect(0, 1, 0, 2), 64);
    defer small.deinit(gpa);
    try std.testing.expectEqualStrings(expected.items, small.bytes.items);
    try std.testing.expect(small.boundary_ok);
}

test "cp4: AC3 streaming — tiny-buffer chunks concatenate byte-identical; rows_done monotone to rect.row_count" {
    const gpa = std.testing.allocator;
    const n: u64 = 5000; // 5000*18 = 90 KB <= head budget -> fully indexed at open
    const fixture = try genFixedRows(gpa, n);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try expectDims(od.doc, n, 2);

    // Reference expected TSV, built from the known fixed cells.
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    var b0: [8]u8 = undefined;
    var b1: [8]u8 = undefined;
    var r: u64 = 0;
    while (r < n) : (r += 1) {
        if (r > 0) try expected.append(gpa, '\n');
        try expected.appendSlice(gpa, fixedCell(&b0, @intCast(r)));
        try expected.append(gpa, '\t');
        try expected.appendSlice(gpa, fixedCell(&b1, @intCast(2 * r)));
    }

    var d = try driveCopy(gpa, od.doc, copyRect(0, n, 0, 2), 200); // small buffer -> many chunks
    defer d.deinit(gpa);
    try std.testing.expectEqualStrings(expected.items, d.bytes.items);
    try std.testing.expect(d.monotone); // rows_done never regressed
    try std.testing.expectEqual(n, d.rows_done); // reached rect.row_count at DONE
    try std.testing.expect(d.steps >= 1); // genuinely streamed (multiple chunks)
    try std.testing.expect(d.boundary_ok);
}

test "cp5: AC4 a selection crossing the frontier STALLS with stalled_row; a jump advances it and it resumes to DONE" {
    const gpa = std.testing.allocator;
    const n: u64 = 300_000; // 5.4 MB > head budget: MANUAL open leaves later rows past the frontier
    const top: u64 = 250_000;
    const fixture = try genFixedRows(gpa, n);
    defer gpa.free(fixture);

    // REFERENCE: a fully-scanned copy of the same rect never stalls.
    var ref = try openBytes(fixture);
    defer ref.deinit();
    try scanToEnd(ref.doc);
    var refd = try driveCopy(gpa, ref.doc, copyRect(0, top, 0, 2), 1 << 16);
    defer refd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), refd.stalls);

    // SUBJECT: MANUAL, NOT scanned -> the sweep hits the frontier and STALLS;
    // driveCopy advances via ls_jump_start(stalled_row) and resumes until DONE.
    var sub = try openBytes(fixture);
    defer sub.deinit();
    var subd = try driveCopy(gpa, sub.doc, copyRect(0, top, 0, 2), 1 << 16);
    defer subd.deinit(gpa);
    try std.testing.expect(subd.stalls >= 1); // it genuinely crossed the frontier
    try std.testing.expectEqualStrings(refd.bytes.items, subd.bytes.items); // identical output either way
    try std.testing.expectEqual(top, subd.rows_done);
}

test "cp6: AC1 the LS_COPY_MAX_CELLS safety cap is reported via budget_capped (Zig seam forces a small cap)" {
    const gpa = std.testing.allocator;
    var od = try openBytes(fv_fixture);
    defer od.deinit();

    // Uncapped reference: a 9-cell (3x3) selection is far below the natural cap.
    var full = try driveCopy(gpa, od.doc, copyRect(0, 3, 0, 3), 1 << 16);
    defer full.deinit(gpa);
    try std.testing.expect(!full.budget_capped);

    // Force a 4-cell cap: the 9-cell selection is cut short and reported on DONE.
    api.copyCapCellsForTest(od.doc, 4);
    var capped = try driveCopy(gpa, od.doc, copyRect(0, 3, 0, 3), 1 << 16);
    defer capped.deinit(gpa);
    try std.testing.expect(capped.budget_capped); // cut short -> reported
    try std.testing.expect(capped.bytes.items.len > 0); // some cells emitted
    try std.testing.expect(capped.bytes.items.len < full.bytes.items.len); // strictly truncated
    try std.testing.expect(std.mem.startsWith(u8, full.bytes.items, capped.bytes.items)); // a front prefix
}

test "cp7: AC3 lifecycle hygiene — empty/out-of-range rects DONE with 0 bytes; cancel/drain leak nothing" {
    const gpa = std.testing.allocator;
    var od = try openBytes(fv_fixture);
    defer od.deinit();

    // Empty rect (row_count 0) -> a valid job that steps DONE with 0 bytes.
    {
        var d = try driveCopy(gpa, od.doc, copyRect(0, 0, 0, 3), 1 << 16);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("", d.bytes.items);
    }
    // Empty rect (col_count 0) -> DONE, 0 bytes.
    {
        var d = try driveCopy(gpa, od.doc, copyRect(0, 8, 0, 0), 1 << 16);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("", d.bytes.items);
    }
    // Out-of-range column range (col 5 >= column_count 3) -> DONE, 0 bytes.
    {
        var d = try driveCopy(gpa, od.doc, copyRect(0, 8, 5, 2), 1 << 16);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("", d.bytes.items);
    }
    // CANCEL mid-stream: open, pull once, close WITHOUT draining -> no leak
    // (std.testing.allocator fails the test on any leak).
    {
        const rr = copyRect(0, 8, 0, 3);
        const job = api.ls_copy_open(od.doc, &rr) orelse return error.CopyOpenFailed;
        var buf: [16]u8 = undefined;
        _ = api.ls_copy_next(job, &buf, buf.len);
        api.ls_copy_close(job); // released exactly once
    }
    // Open + close with no next at all -> no leak.
    {
        const rr = copyRect(0, 1, 0, 1);
        const job = api.ls_copy_open(od.doc, &rr) orelse return error.CopyOpenFailed;
        api.ls_copy_close(job);
    }
}

test "cp_perf: AC2 the streaming sweep is O(rows), interval-invariant (advance count, not wall-clock)" {
    const gpa = std.testing.allocator;
    const n: u64 = 6_000; // spans multiple sparse checkpoints (interval 2048)
    const fixture = try genFixedRows(gpa, n);
    defer gpa.free(fixture);
    var od = try openBytes(fixture);
    defer od.deinit();
    try scanToEnd(od.doc);
    try expectDims(od.doc, n, 2);

    api.copyAdvancesReset(od.doc);
    var d = try driveCopy(gpa, od.doc, copyRect(0, n, 0, 2), 1 << 16);
    defer d.deinit(gpa);
    const advances = api.copyAdvances(od.doc);
    // A forward sweep advances ~once per row after anchoring, with NO checkpoint-
    // interval term. RED seed: the seed emits nothing -> 0 advances, so the linear
    // FLOOR fails. GREEN: the cursor sweep is O(rows). The linear CEILING rules out
    // any O(rows x interval) locate-per-row cost (the ~80 s path this replaces).
    try std.testing.expect(advances >= n - 1);
    try std.testing.expect(advances <= 4 * n + 64);
}

const c_linked_copy_job = struct {
    extern fn ls_copy_open(doc: *const api.Doc, rrect: *const api.CopyRect) ?*api.CopyJob;
    extern fn ls_copy_next(job: *api.CopyJob, buf: ?[*]u8, buf_len: usize) api.CopyProgress;
    extern fn ls_copy_close(job: *api.CopyJob) void;
};

test "cp_abi: the streaming-copy symbols link through extern linkage; ls_copy_step values pinned" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.CopyStep.more));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.CopyStep.done));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(api.CopyStep.stalled));

    var od = try openBytes("a,b\nx,y\n");
    defer od.deinit();
    const rr = copyRect(0, 1, 0, 2);
    const job = c_linked_copy_job.ls_copy_open(od.doc, &rr) orelse return error.CopyOpenFailed;
    var buf: [64]u8 = undefined;
    const p = c_linked_copy_job.ls_copy_next(job, &buf, buf.len);
    try std.testing.expect(p.step == .more or p.step == .done or p.step == .stalled);
    c_linked_copy_job.ls_copy_close(job);
}
