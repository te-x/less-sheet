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
