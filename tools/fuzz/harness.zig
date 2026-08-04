//! less-sheet coverage-guided fuzz harness — security-hardening wave (c), AC-c1/AC-c3.
//!
//! WHAT THIS IS. Four coverage-guided fuzz targets over the SHIPPED C ABI, built
//! `ReleaseSafe` (the mode we ship), driven by Zig 0.16.0's builtin fuzzer:
//!
//!   csv       — a fuzzed local file through ls_open + the whole read surface
//!   gz_raw    — fuzzed .csv.gz FILE BYTES (the inflater's own error space)
//!   gz_trunc  — structure-aware: a REAL deflate stream cut at a fuzzed offset
//!   net       — the net-source reducer over the injected fake transport
//!
//! THE BAR. This project ships ReleaseSafe, so a Zig safety panic IS a crash.
//! Every target therefore asserts NOTHING about the returned values: the property
//! under test is "the process survives and the API stays callable" on arbitrary
//! bytes. A finding is a panic / abort / leak / hang, never a mismatched value —
//! value correctness is the frozen suite's job (285 tests), not the campaign's.
//!
//! C ABI, NOT ZIG INTERNALS. Every call below is one of the `export fn` symbols
//! in `api/lesssheet.h`, reached through the `contracts/api.zig` re-exports
//! (`pub const ls_open = core.ls_open;` — the same function the C header names,
//! not a Zig-side twin). The ONE deliberate exception is the fake transport, see
//! `oneNet`.
//!
//! ALLOCATION DISCIPLINE. `compiler/test_runner.zig` reinstalls a fresh
//! `testing.allocator_instance` around EVERY iteration and `exit(1)`s on a leak,
//! so a target must not hold `testing.allocator` memory across iterations. The
//! harness therefore allocates nothing per iteration: every buffer is a static or
//! is owned by the per-test `Sandbox` (page allocator, created before `fuzz()`).
//! That leak check still applies to any allocation a target makes itself.
//!
//! HANGS. AC-c2 counts a hang as a finding, and the fuzzer has no per-iteration
//! watchdog, so a wedged iteration would stall the whole campaign rather than
//! report. Every wait in here is a BOUNDED spin — `settle` for a document's
//! background lanes, the poll loop in `oneNet` for an open job — that gives up and
//! proceeds instead of waiting for a state that may never come. The harness also
//! never uses a fixture knob whose contract is "wait until the test says so": see
//! the `withhold` note in `oneNet`.
//!
//! What it CANNOT bound is a hang inside a single C-ABI call, because there is
//! nothing to poll. Finding F1 (`findings/README.md`) is exactly that, and the
//! only lever against it is the quarantine below.

const std = @import("std");
const api = @import("api");
const seeds = @import("seeds.zig");
const gzbuild = @import("gzbuild.zig");
const build_options = @import("build_options");
const Smith = std.testing.Smith;

/// Apply `-Dseed-limit=N` (see build.zig): replay only the first N entries of a
/// pack. 0 keeps the whole corpus, which is what a campaign always uses.
fn limited(pack: []const []const u8) []const []const u8 {
    const n = build_options.seed_limit;
    return if (n == 0 or n >= pack.len) pack else pack[0..n];
}

// ---------------------------------------------------------------------------
// Byte weighting
//
// The document/needle draws are weighted toward CSV-ish bytes so the fuzzer
// spends its budget on plausible structure. The weight set COVERS 0..255
// (`.rangeAtMost(u8, 0, 255, 1)` is present), which matters for replay: an
// uncovered byte would be rewritten to `byte_weights[0].min` when a seed is
// replayed through `Smith{ .in = blob }`, silently corrupting the corpus.
// Keeping the full range in the set makes replay byte-exact.
// ---------------------------------------------------------------------------
const csv_bytes: []const Smith.Weight = &.{
    .rangeAtMost(u8, 0, 255, 1),
    .rangeAtMost(u8, 0x20, 0x7e, 4),
    .value(u8, ',', 10),
    .value(u8, '\n', 10),
    .value(u8, '"', 6),
    .value(u8, '\r', 3),
    .value(u8, '\t', 3),
    .value(u8, ';', 3),
    .value(u8, 0, 2),
};

const doc_max = 64 * 1024;
const plain_max = 32 * 1024;
const needle_max = 48;
/// The `gz_raw` draw is capped below `doc_max` because its bytes are COMPRESSED:
/// an iteration's cost scales with the DECOMPRESSED size, so the draw length does
/// not bound the work — a 64 KiB compressed draw of a repetitive CSV expands past
/// a megabyte, every byte of which the open head scan walks through the gzip lane.
/// The cap keeps that unbounded-by-construction factor in check. 24 KiB
/// specifically because it still holds the largest regression seed the corpus
/// carries (the `flate_b1` fixture-B cut, 16901 bytes) intact.
///
/// Not a throughput emergency: with this cap the whole 146-entry `gz_raw` corpus
/// replays in ~21 s (0.14 s/entry) on an M-series mac. An earlier six-minute
/// figure was a HUNG run (finding F1), not slowness — do not cite it.
const gz_doc_max = 24 * 1024;
/// Ceiling on the document the `rep` amplifier may build (see `repFor`): the
/// amplifier is what lets a small entropy blob produce a multi-hundred-KiB
/// document, which is what crosses the index's chunk boundaries and the
/// window/row-scan budgets. `Sandbox.place` clamps to this.
const scratch_max = 1024 * 1024;

var doc_buf: [doc_max]u8 = undefined;
var plain_buf: [plain_max]u8 = undefined;
var needle_buf: [needle_max]u8 = undefined;
var gz_buf: [4 * (doc_max + 4096)]u8 = undefined;
var raw_buf: [doc_max + 4096]u8 = undefined;
var win_buf: [gzbuild.window_len]u8 = undefined;
var copy_buf: [16 * 1024]u8 = undefined;
var cell_buf: [api.cell_max_bytes]u8 = undefined;
var col_ids: [64]u32 = undefined;
var col_meta: [64]api.ColumnMetadata = undefined;

// ---------------------------------------------------------------------------
// Config words
//
// Each target draws THREE u64 entropy words and bit-slices them, rather than
// drawing one Smith value per knob. Two reasons: (1) `valueRangeAtMost(u64, 0,
// maxInt)` is the identity on 8 replay bytes, so a seed's knob tail is exactly
// 24 bytes with no per-knob encoding for the generator to keep in sync; (2) the
// fuzzer gets direct bit-level control of every knob at once.
//
//   w0 — target-specific SHAPE (see each target)
//   w1 — dialect + window                (shared layout, `Dialect`)
//   w2 — search / filter / copy / jump   (shared layout, `Drive`)
// ---------------------------------------------------------------------------

/// Consume the low `n` bits of `w`.
fn take(w: *u64, n: u6) u64 {
    const mask: u64 = if (n == 64) std.math.maxInt(u64) else (@as(u64, 1) << n) - 1;
    const v = w.* & mask;
    w.* >>= n;
    return v;
}

const Dialect = struct {
    opts: api.OpenOptions,
    first_row: u64,
    row_count: u32,
    spins: u32,

    fn from(word: u64) Dialect {
        var w = word;
        const sep: i32 = switch (take(&w, 3)) {
            0 => ',',
            1 => ';',
            2 => '\t',
            3 => '|',
            4 => 0x00, // an out-of-candidate separator byte: must be accepted or cleanly refused
            5 => 0xff,
            else => api.sniff,
        };
        const quote: i32 = switch (take(&w, 2)) {
            0 => '"',
            1 => '\'',
            2 => api.quote_none,
            else => api.sniff,
        };
        const header: i32 = switch (take(&w, 2)) {
            1 => api.header_off,
            2 => api.header_on,
            else => api.sniff,
        };
        const enc: i32 = switch (take(&w, 3)) {
            1 => api.encoding_utf8,
            2 => api.encoding_utf16le,
            3 => api.encoding_utf16be,
            4 => api.encoding_latin1,
            5 => api.encoding_windows1252,
            else => api.encoding_auto,
        };
        const index_mode: i32 = if (take(&w, 1) == 0) api.index_auto else api.index_manual;
        return .{
            .opts = .{
                .separator = sep,
                .quote = quote,
                .header = header,
                .index_mode = index_mode,
                .encoding = enc,
            },
            // Deliberately past any plausible row count: an out-of-range window
            // must clamp, not fault.
            .first_row = take(&w, 20),
            // Deliberately past `window_max_rows` (4096): the clamp is on the
            // fuzzed path too.
            .row_count = @intCast(take(&w, 13)),
            .spins = @intCast(take(&w, 3) * 512),
        };
    }
};

const Drive = struct {
    kind: api.SearchKind,
    op: api.SearchOp,
    column: u32,
    case_sensitive: bool,
    jump: u64,
    copy_rows: u64,
    copy_cols: u32,
    do_filter: bool,
    do_columns: bool,
    infer_count: u32,

    fn from(word: u64) Drive {
        var w = word;
        const kind: api.SearchKind = if (take(&w, 1) == 0) .text else .predicate;
        const op: api.SearchOp = switch (take(&w, 3)) {
            0 => .eq,
            1 => .ne,
            2 => .lt,
            3 => .gt,
            4 => .le,
            else => .ge,
        };
        return .{
            .kind = kind,
            .op = op,
            .column = @intCast(take(&w, 6)),
            .case_sensitive = take(&w, 1) != 0,
            .jump = take(&w, 20),
            .copy_rows = take(&w, 13),
            .copy_cols = @intCast(take(&w, 6)),
            .do_filter = take(&w, 1) != 0,
            .do_columns = take(&w, 1) != 0,
            .infer_count = @intCast(take(&w, 6)),
        };
    }
};

/// One drawn input: the document bytes, three config words, a needle.
const Input = struct {
    data: []u8,
    w0: u64,
    dialect: Dialect,
    drive: Drive,
    needle: []u8,

    fn draw(smith: *Smith, data_buf: []u8) Input {
        const n = smith.sliceWeightedBytes(data_buf, csv_bytes);
        const w0 = smith.valueRangeAtMost(u64, 0, std.math.maxInt(u64));
        const w1 = smith.valueRangeAtMost(u64, 0, std.math.maxInt(u64));
        const w2 = smith.valueRangeAtMost(u64, 0, std.math.maxInt(u64));
        const m = smith.sliceWeightedBytes(&needle_buf, csv_bytes);
        return .{
            .data = data_buf[0..n],
            .w0 = w0,
            .dialect = .from(w1),
            .drive = .from(w2),
            .needle = needle_buf[0..m],
        };
    }
};

// ---------------------------------------------------------------------------
// Sandbox — one temp dir + one reusable document path per fuzz target, created
// BEFORE `fuzz()` (so its allocations never meet the per-iteration leak check)
// and reused by every iteration.
// ---------------------------------------------------------------------------
const Sandbox = struct {
    tmp: std.testing.TmpDir,
    scratch: []u8,
    path: [:0]u8,
    sub: []const u8,
    path_store: [std.Io.Dir.max_path_bytes + 64]u8 = undefined,

    fn init(sub: []const u8) !*Sandbox {
        const gpa = std.heap.page_allocator;
        const sb = try gpa.create(Sandbox);
        sb.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .scratch = try gpa.alloc(u8, scratch_max),
            .path = undefined,
            .sub = sub,
        };
        var real: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try sb.tmp.dir.realPath(std.testing.io, &real);
        sb.path = try std.fmt.bufPrintZ(&sb.path_store, "{s}/{s}", .{ real[0..n], sub });
        return sb;
    }

    /// Write `bytes` repeated `rep` times as the document, bounded by `scratch`.
    ///
    /// The clamp is `@min`, never `@max(1, ...)`: a single copy that does not fit
    /// must be TRUNCATED rather than written past the buffer. A harness-side
    /// overrun would surface as a ReleaseSafe panic indistinguishable from a
    /// finding in the core, and burn triage time on the wrong code.
    fn place(sb: *Sandbox, bytes: []const u8, rep: usize) !void {
        var total: usize = 0;
        if (bytes.len != 0) {
            const fit = @min(rep, sb.scratch.len / bytes.len);
            for (0..fit) |i| @memcpy(sb.scratch[i * bytes.len ..][0..bytes.len], bytes);
            total = fit * bytes.len;
            if (fit == 0) {
                total = sb.scratch.len;
                @memcpy(sb.scratch, bytes[0..total]);
            }
        }
        try sb.tmp.dir.writeFile(std.testing.io, .{
            .sub_path = sb.sub,
            .data = sb.scratch[0..total],
            .flags = .{ .permissions = .fromMode(0o644) },
        });
    }
};

/// `rep` mapping: overwhelmingly 1, occasionally large. Amplification is what
/// reaches the multi-chunk index and the 1 MiB per-row scan budget from a small
/// entropy blob; doing it on most iterations would just cost throughput.
///
/// PLAIN-TEXT TARGETS ONLY. It is deliberately NOT applied at full range to the gz
/// targets: a compressed document is already amplified by its own expansion ratio,
/// so repeating a member multiplies the DECOMPRESSED size, not the file size, and
/// the product is unbounded by anything the fuzzer draws.
fn repFor(bits: u64) usize {
    return switch (bits) {
        0...47 => 1,
        48...55 => 2,
        56...59 => 4,
        60...61 => 8,
        62 => 16,
        else => 64,
    };
}

// ---------------------------------------------------------------------------
// Bounded drivers
// ---------------------------------------------------------------------------

/// Let a background lane make progress, bounded. Never waits for `complete`:
/// on a fuzzed document it may legitimately never arrive, and the API is
/// specified to be callable regardless.
///
/// A pure spin would be useless here — 4096 `spinLoopHint`s take microseconds and
/// a scan worker would not have advanced at all, so the index/search/filter
/// COMPLETED states would be nearly unreachable. So the spin yields the CPU a few
/// times, bounded to `max_yield_ms` total, which is enough for a small document to
/// finish scanning without turning every iteration into a sleep.
fn settle(doc: *api.Doc, spins: u32) void {
    const max_yields = 4;
    var yields: u32 = 0;
    var i: u32 = 0;
    while (i < spins) : (i += 1) {
        if (api.ls_index_poll(doc).complete) return;
        if (i % 512 == 511 and yields < max_yields) {
            yields += 1;
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

/// Read every cell of a materialized window, plus the per-row predicates.
fn sweepWindow(doc: *api.Doc, r: api.RowRange, cols: u32) void {
    const rows = @min(r.row_count, 64);
    const ncols = @min(cols, 24);
    var i: u64 = 0;
    while (i < rows) : (i += 1) {
        const row = r.first_row + i;
        var c: u32 = 0;
        while (c < ncols) : (c += 1) {
            const s = api.ls_cell(doc, row, c);
            std.mem.doNotOptimizeAway(s.len);
            if (s.len != 0) std.mem.doNotOptimizeAway(s.ptr[s.len - 1]);
            _ = api.ls_cell_truncated(doc, row, c);
        }
        _ = api.ls_row_oversized(doc, row);
        _ = api.ls_source_row(doc, row);
    }
}

/// Exercise the whole read surface of an OPEN document. Every call is C ABI.
///
/// DELIBERATELY MOSTLY UNGATED. Only `filter` and column inference are behind a
/// drawn bit; window materialization, the cell sweep, search, jump and copy run
/// on EVERY iteration. That is what makes an ALL-ZERO config word already reach
/// every hotspot module AC-c1 enumerates — which in turn means the seed generator
/// never has to know this file's bit layout to produce a seed that lands deep in
/// the code. Gating them would trade that guarantee for throughput.
fn exercise(doc: *api.Doc, d: Dialect, k: Drive, needle: []const u8) void {
    settle(doc, 512 + d.spins);

    _ = api.ls_dialect_get(doc);
    const cols = api.ls_column_count(doc);
    _ = api.ls_row_count_get(doc);
    _ = api.ls_index_poll(doc);

    // --- window materialization + cell reads (window.zig, csv_reader.zig, encoding.zig)
    // A viewport-shaped window first (always in range), then the fuzzed one
    // (deliberately allowed past the end and past `window_max_rows`).
    sweepWindow(doc, api.ls_window_set(doc, 0, 64), cols);
    const r = api.ls_window_set(doc, d.first_row, d.row_count);
    sweepWindow(doc, r, cols);

    const ncols = @min(cols, 24);
    var c: u32 = 0;
    while (c < ncols) : (c += 1) {
        const s = api.ls_header_cell(doc, c);
        std.mem.doNotOptimizeAway(s.len);
        _ = api.ls_header_cell_truncated(doc, c);
    }
    // Out-of-range probes: past the end in both axes.
    _ = api.ls_cell(doc, std.math.maxInt(u64), 0);
    _ = api.ls_cell(doc, d.first_row, cols);
    _ = api.ls_header_cell(doc, cols +| 1);

    // --- full-cell read: the number-aware formula neutralization (security (f))
    var out_len: usize = 0;
    var out_trunc: bool = false;
    _ = api.ls_cell_copy(doc, r.first_row, 0, &cell_buf, cell_buf.len, &out_len, &out_trunc);
    _ = api.ls_cell_copy(doc, 0, 0, &cell_buf, cell_buf.len, &out_len, &out_trunc);

    // --- search (search.zig, matcher.zig)
    {
        const req: api.SearchRequest = .{
            .kind = k.kind,
            .op = k.op,
            .column = k.column,
            .value_ptr = if (needle.len == 0) null else needle.ptr,
            .value_len = needle.len,
            .case_sensitive = k.case_sensitive,
        };
        if (api.ls_search_start(doc, &req)) {
            settle(doc, 256);
            _ = api.ls_search_poll(doc);
            api.ls_search_nav(doc, k.jump, .forward);
            _ = api.ls_search_poll(doc);
            api.ls_search_nav(doc, k.jump, .backward);
            _ = api.ls_search_poll(doc);
            _ = api.ls_window_match_flags(doc, 0, @min(cols, 8));
        }
        api.ls_search_cancel(doc);
    }

    // --- filter (filter.zig + the filtered window/index views)
    if (k.do_filter) {
        const req: api.SearchRequest = .{
            .kind = k.kind,
            .op = k.op,
            .column = k.column,
            .value_ptr = if (needle.len == 0) null else needle.ptr,
            .value_len = needle.len,
            .case_sensitive = k.case_sensitive,
        };
        if (api.ls_filter_set(doc, &req)) {
            settle(doc, 256);
            _ = api.ls_filter_poll(doc);
            const fr = api.ls_window_set(doc, 0, @min(d.row_count, 64));
            var j: u64 = 0;
            while (j < @min(fr.row_count, 32)) : (j += 1) {
                _ = api.ls_cell(doc, fr.first_row + j, 0);
                _ = api.ls_source_row(doc, fr.first_row + j);
            }
        }
        api.ls_filter_clear(doc);
    }

    // --- jump / frontier advance (nav.zig, index.zig)
    api.ls_jump_start(doc, k.jump);
    var spins: u32 = 0;
    while (spins < 512) : (spins += 1) {
        if (api.ls_jump_poll(doc).state != .scanning) break;
        std.atomic.spinLoopHint();
    }
    api.ls_jump_cancel(doc);

    // --- streaming copy (the neutralizing framer)
    {
        const rect: api.CopyRect = .{
            .first_row = d.first_row,
            .row_count = k.copy_rows,
            .first_col = 0,
            .col_count = k.copy_cols,
        };
        if (api.ls_copy_open(doc, &rect)) |job| {
            defer api.ls_copy_close(job);
            var pulls: u32 = 0;
            while (pulls < 64) : (pulls += 1) {
                const p = api.ls_copy_next(job, &copy_buf, copy_buf.len);
                if (p.step != .more) break;
            }
        }
    }

    // --- column metadata / inference (column.zig, column_state.zig)
    if (k.do_columns) {
        const n = @min(@min(k.infer_count, cols), @as(u32, col_ids.len));
        for (0..n) |ix| col_ids[ix] = @intCast(ix);
        if (n != 0) {
            _ = api.ls_column_inference_request(doc, &col_ids, n);
            settle(doc, 256);
            var st: api.ColumnInferenceStatus = undefined;
            st.struct_size = @sizeOf(api.ColumnInferenceStatus);
            st.abi_version = api.column_metadata_abi_version;
            _ = api.ls_column_metadata_poll(doc, &st);
            for (0..n) |ix| {
                col_meta[ix] = std.mem.zeroes(api.ColumnMetadata);
                col_meta[ix].struct_size = @sizeOf(api.ColumnMetadata);
                col_meta[ix].abi_version = api.column_metadata_abi_version;
            }
            var gen: u64 = 0;
            _ = api.ls_column_metadata_get_many(doc, &col_ids, n, &col_meta, n, &gen);
            _ = api.ls_column_null_sentinel_set(doc, 0, needle.ptr, needle.len);
            var got: usize = 0;
            _ = api.ls_column_null_sentinel_copy(doc, 0, &cell_buf, cell_buf.len, &got);
            _ = api.ls_column_conflict_example_copy(doc, 0, &cell_buf, cell_buf.len, &got);
            _ = api.ls_column_null_sentinel_clear(doc, 0);
            _ = api.ls_column_override_clear(doc, 0);
            _ = api.ls_column_inference_accept_proposal(doc, 0);
            api.ls_column_inference_cancel(doc);
        }
    }
}

/// Open the sandbox document through the C ABI and exercise it.
fn openAndExercise(sb: *Sandbox, in: Input, opts: api.OpenOptions) void {
    var doc: ?*api.Doc = null;
    const st = api.ls_open(sb.path.ptr, &opts, &doc);
    if (st != .ok) {
        // A refused open must not have produced a document.
        std.debug.assert(doc == null);
        return;
    }
    const d = doc orelse return;
    defer api.ls_close(d);
    exercise(d, in.dialect, in.drive, in.needle);
}

/// Build a gzip member of `plain` per `shape` into the shared static buffer.
fn gzMember(plain: []const u8, shape: gzbuild.Shape) ?[]u8 {
    return gzbuild.member(plain, shape, &win_buf, &raw_buf, &gz_buf);
}

// ---------------------------------------------------------------------------
// QUARANTINE — non-mmap source x UTF-16 (see tools/fuzz/findings/README.md, F1)
//
// The FIRST thing this harness found, on its own seed corpus, before any campaign
// started: `ls_open` NEVER RETURNS when the decoded stream is UTF-16 with an ODD
// trailing byte (a dangling half code unit at end of stream) and the source is NOT
// the mmap'd local file. Verified on BOTH non-mmap sources — the local gzip source
// and the network source — from the very same 3 bytes, `FF FE 41`. The identical
// bytes as a plain `.csv` return cleanly, so the mmap path resolves end-of-stream
// there and the streaming sources do not.
//
// It is reachable with `encoding = auto`: no dialect override, no user action. It
// is a HANG, not a crash, so nothing times it out, and Zig's fuzzer has no
// per-iteration watchdog — one hit wedges an entire campaign silently.
//
// Until it is fixed, the three streaming targets PIN the encoding to UTF-8.
// Pinning rather than merely declining to DRAW utf16 is what actually avoids it:
// auto-detection selects UTF-16 by itself from a BOM.
//
// Cost of the quarantine, stated plainly: the `encoding` hotspot is covered by the
// `csv` target only while this is true — where all five encodings are drawn and
// measured to terminate. Revert by setting this to `false`, which is the intended
// first step of triage once the fix lands.
const quarantine_utf16_streaming = false; // LIFTED: F1 fixed (streaming end-of-stream verdict)

fn quarantine(opts: api.OpenOptions) api.OpenOptions {
    if (!quarantine_utf16_streaming) return opts;
    var o = opts;
    o.encoding = api.encoding_utf8;
    return o;
}

// ---------------------------------------------------------------------------
// Targets
// ---------------------------------------------------------------------------

fn oneCsv(sb: *Sandbox, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const in: Input = .draw(smith, &doc_buf);
    var w0 = in.w0;
    try sb.place(in.data, repFor(take(&w0, 6)));
    openAndExercise(sb, in, in.dialect.opts);
}

fn oneGzRaw(sb: *Sandbox, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const in: Input = .draw(smith, doc_buf[0..gz_doc_max]);
    var w0 = in.w0;
    // Repeating a complete member yields a valid MULTI-MEMBER gzip; repeating a
    // damaged one yields garbage after the first. Both are wanted. Capped hard at
    // 4 rather than going through `repFor`, for the reason given there: on a
    // COMPRESSED input a repeat multiplies the decompressed size, so the product
    // is not bounded by anything the fuzzer draws.
    try sb.place(in.data, 1 + @as(usize, @intCast(take(&w0, 2))));
    openAndExercise(sb, in, quarantine(in.dialect.opts));
}

fn oneGzTrunc(sb: *Sandbox, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const in: Input = .draw(smith, plain_buf[0..plain_max]);
    const shape: gzbuild.Shape = .decode(in.w0);
    const member = gzMember(in.data, shape) orelse return;
    try sb.place(member, 1);
    openAndExercise(sb, in, quarantine(in.dialect.opts));
}

/// The net-source reducer.
///
/// THE ONE NON-C-ABI CALL IN THE HARNESS, and why. The real network path is
/// `ls_open_url_start`, which owns a `std.http.Client` — it needs a live server,
/// which is neither hermetic nor fuzzable. The backend's frozen contract exposes
/// exactly one injection point for this, `api.openUrlStartFake` + `api.NetFixture`
/// (`contracts/api.zig`: "Zig-only test seams (NOT the C ABI — like
/// openWithAllocator / gz*)"), and it is deliberately NOT in `api/lesssheet.h` so
/// that header stays byte-identical. There is therefore no C-ABI route to
/// `net_source.zig` at all, and AC-c1 names `net_source` as a required hotspot.
///
/// Consequence, stated rather than implied: the JOB START is a Zig seam call.
/// Everything after it — `ls_net_open_poll` / `cancel` / `release`, and the whole
/// read surface of the document the job produces — is the same C ABI as every
/// other target, and the code under test (the reducer, the spool, the range/
/// sequential fill strategies, the gzip-over-spool composition) is production
/// code reached through its production entry point. Only the byte provider is
/// injected, exactly as the frozen net suite does it.
fn oneNet(sb: *Sandbox, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    _ = sb;
    const in: Input = .draw(smith, &doc_buf);
    var w = in.w0;

    const honor_ranges = take(&w, 1) != 0;
    const advertise_length = take(&w, 1) != 0;
    const redirect_downgrade = take(&w, 1) != 0;
    const status: u16 = switch (take(&w, 3)) {
        0 => 200,
        1 => 206,
        2 => 404,
        3 => 401,
        4 => 500,
        5 => 304,
        6 => 416,
        else => 200,
    };
    const hops: u32 = @intCast(take(&w, 3));
    const fault: api.NetFault = switch (take(&w, 2)) {
        1 => .connect,
        2 => .timeout,
        3 => .io,
        else => .none,
    };
    const use_drop = take(&w, 1) != 0;
    const drop_at = take(&w, 20);
    const use_short = take(&w, 1) != 0;
    const short_at = take(&w, 20);
    const gz_body = take(&w, 1) != 0;
    const cancel_early = take(&w, 1) != 0;

    // Compose gzip over the network source when asked: that is the path where
    // the inflater runs over a growing spool rather than an mmap.
    const body: []const u8 = if (gz_body)
        (gzMember(in.data, .{}) orelse in.data)
    else
        in.data;

    var attempts: std.atomic.Value(u64) = .init(0);

    // NetFixture.withhold IS DELIBERATELY NOT USED, and this is a correctness
    // requirement on the harness rather than a gap.
    //
    // `withhold` models a server that has streamed only a prefix so far: the fake
    // serves bytes only below the gate and a demand past it WAITS until the test
    // raises the gate. A fuzz target cannot safely hold that contract. The open
    // itself consumes bytes, so if the drawn gate sits below what the open head
    // needs, the open blocks — and the harness code that would raise the gate is
    // downstream of the very call that is blocked. That is a deadlock the harness
    // built, and it is indistinguishable at a glance from a core hang: it cost one
    // false lead in this cell before being pinned by a stack sample
    // (`ensureSlice` under `buildDocument`, waiting on bytes nobody would release).
    //
    // The frozen suite is the right place for that knob, because a test knows its
    // own fixture's size and can pick a gate above the head requirement
    // (`flate_b2a`/`flate_b2b` do exactly that, gating on 256 KiB chunk
    // boundaries; AC13 covers the raise-and-resume behavior).
    //
    // Partial and faulty delivery are still fuzzed here through the knobs that
    // cannot wait forever: `drop_after` (a hard stream END -> damaged EOF),
    // `short_body_at` (a retryable short range), `fault`, `redirect_hops`,
    // `redirect_downgrade` and the status-code table.

    var fx: api.NetFixture = .{
        .body = body,
        .honor_ranges = honor_ranges,
        .advertise_length = advertise_length,
        .http_status = status,
        .redirect_hops = hops,
        .fault = fault,
        .stall = false,
        .drop_after = if (use_drop) drop_at else null,
        .redirect_downgrade = redirect_downgrade,
        .short_body_at = if (use_short) short_at else null,
        .fetch_attempts = &attempts,
    };

    const url = if (redirect_downgrade) "https://fixture.test/d.csv" else "http://fixture.test/d.csv";
    // Unconditional, not just for `gz_body`: the NETWORK source hits F1 on its
    // own — entry 40 of net.pack is a 3-byte `FF FE 41` body with every knob at
    // its default, and it wedges the open with no gzip involved.
    const net_opts = quarantine(in.dialect.opts);
    const job = api.openUrlStartFake(&fx, url.ptr, url.len, &net_opts) orelse return;
    defer api.ls_net_open_release(job);

    if (cancel_early) api.ls_net_open_cancel(job);

    // Poll to a terminal state, bounded. Every fixture the harness builds either
    // completes or fails on its own (see the `withhold` note above), so the bound
    // is a backstop against a CORE hang, not part of the protocol.
    var st = api.ls_net_open_poll(job);
    var spins: u32 = 0;
    while (spins < 4_000) : (spins += 1) {
        st = api.ls_net_open_poll(job);
        switch (st.state) {
            .done, .failed, .cancelled => break,
            .pending, .fetching => {},
        }
        if (spins % 64 == 63) std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    if (st.state != .done) {
        // Not terminal within the bound, or a terminal non-DONE: `release` (the
        // deferred call) is what tears the job down, cancel included.
        api.ls_net_open_cancel(job);
        return;
    }
    const doc = st.doc orelse return;
    defer api.ls_close(doc);
    exercise(doc, in.dialect, in.drive, in.needle);
    _ = api.netRangeMode(doc);
    _ = api.netFetchCount(doc);
    _ = api.netResidentBytes(doc);
}

// ---------------------------------------------------------------------------
// Fuzz tests
//
// Each is its own fuzz test, so the fuzzer keeps a SEPARATE corpus per target
// (`.zig-cache/f/<hash(test name)>/`) and rotates its budget between them. They
// share ONE coverage map (`.zig-cache/v/<pc_digest>`, keyed on the binary's PC
// table), which is what makes a single coverage report cover all four.
// ---------------------------------------------------------------------------

test "fuzz csv: ls_open + window/cell/search/filter/copy over a fuzzed local CSV" {
    try std.testing.fuzz(try Sandbox.init("doc.csv"), oneCsv, .{ .corpus = limited(seeds.csv) });
}

test "fuzz gz_raw: fuzzed .csv.gz file bytes through the gzip source + inflater" {
    try std.testing.fuzz(try Sandbox.init("doc.csv.gz"), oneGzRaw, .{ .corpus = limited(seeds.gz_raw) });
}

test "fuzz gz_trunc: a real deflate stream truncated at a fuzzed offset (task #40 generalized)" {
    try std.testing.fuzz(try Sandbox.init("cut.csv.gz"), oneGzTrunc, .{ .corpus = limited(seeds.gz_trunc) });
}

test "fuzz net: the net-source reducer over the injected fake transport" {
    try std.testing.fuzz(try Sandbox.init("net.csv"), oneNet, .{ .corpus = limited(seeds.net) });
}

// ---------------------------------------------------------------------------
// Self-checks — these run under a plain `zig build test` and guard the two
// properties the corpus format silently depends on.
// ---------------------------------------------------------------------------

test "seed blob format round-trips byte-exactly through Smith replay" {
    // A hand-built blob must come back out of `Input.draw` unchanged: this is
    // what makes a committed pack entry mean what the generator intended, and
    // what catches a byte-weight set that no longer covers 0..255.
    const doc = "a,b\r\n\x00\xff\"q\",2\n";
    var blob: [4 + doc.len + 24 + 4 + 3]u8 = undefined;
    std.mem.writeInt(u32, blob[0..4], doc.len, .little);
    @memcpy(blob[4..][0..doc.len], doc);
    var off: usize = 4 + doc.len;
    for ([_]u64{ 0x0123456789abcdef, 0xfedcba9876543210, 0x00ff00ff00ff00ff }) |v| {
        std.mem.writeInt(u64, blob[off..][0..8], v, .little);
        off += 8;
    }
    std.mem.writeInt(u32, blob[off..][0..4], 3, .little);
    off += 4;
    @memcpy(blob[off..][0..3], "xyz");

    var smith: Smith = .{ .in = &blob };
    const in: Input = .draw(&smith, &doc_buf);
    try std.testing.expectEqualStrings(doc, in.data);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), in.w0);
    try std.testing.expectEqualStrings("xyz", in.needle);
    // And the two words behind the shared knob layouts really were consumed in
    // order (w1 -> dialect, w2 -> drive).
    try std.testing.expectEqual(Dialect.from(0xfedcba9876543210).opts, in.dialect.opts);
    try std.testing.expectEqual(Drive.from(0x00ff00ff00ff00ff).column, in.drive.column);
}

test "the committed corpus is non-empty for every target" {
    // A pack that silently emptied (a regenerate that failed, a bad path) would
    // turn the campaign into an unseeded random walk and nothing else would
    // complain. Numbers are floors, not exact counts.
    try std.testing.expect(seeds.csv.len >= 32);
    try std.testing.expect(seeds.gz_raw.len >= 16);
    try std.testing.expect(seeds.gz_trunc.len >= 8);
    try std.testing.expect(seeds.net.len >= 8);
}
