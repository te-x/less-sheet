//! Frozen behavior tests — viewer-ui slice (planner-owned).
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
    var od = try openBytes("x;y\nz;w\n");
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
