//! Coverage report for a fuzz campaign — the AC-c1 evidence tool.
//!
//! AC-c1 does not stop at "a harness exists": it requires that "the coverage
//! report shows entry into the enumerated hotspot modules (`csv_reader`,
//! `source`, `net_source`, `window`, `index`, `search`, `encoding`)". Zig's own
//! `--fuzz=N` report prints one aggregate percentage over the whole binary, which
//! cannot answer that. This tool answers it per source file, and EXITS NON-ZERO
//! when a required module was never entered — so "the harness reaches the code"
//! is a checked claim rather than a stated one.
//!
//! HOW IT WORKS. Zig's fuzzer memory-maps its coverage state to
//! `<cache-root>/v/<hex(pc_digest)>` in the layout `std.Build.abi.SeenPcsHeader`
//! describes: three `usize` counters, then one BIT per instrumented PC, then the
//! PC addresses themselves (unslid, i.e. as they appear in the binary). The file
//! carries no symbol information at all, so PCs are resolved against the
//! fuzz-mode-REBUILT test binary with `std.debug.Info` — the same API
//! `std/Build/Fuzz.zig` uses to drive its web UI. Mach-O split debug info is
//! handled inside `std.debug.Info` (it resolves address-by-address through
//! `MachOFile.getDwarfForAddress`), so no dSYM step and no external symbolizer
//! (`atos`, `llvm-symbolizer`) is required.
//!
//!   covreport <fuzz-binary> <coverage-file> [--require <substr>,...] [--all]
//!            [--cold <substr>,...]
//!
//! Counts are PCs (instrumented basic blocks), not lines: "seen" means the
//! fuzzer executed that block at least once, accumulated across every run that
//! shared the cache.
//!
//! AIMING (`--cold`). A per-file percentage says a module is weakly covered but
//! not WHICH code the fuzzer never entered, which is the only thing that tells
//! you what to change in a target. `--cold` resolves the same PCs to their LINE
//! (`std.debug.Coverage.SourceLocation` carries file + line + column), attributes
//! each line to the enclosing `fn` by parsing the module's own source, and prints
//! per-function seen/total plus the cold line ranges — so "27% of search.zig"
//! becomes a named list of unreached functions. Report only; it never changes the
//! exit status.

const std = @import("std");

/// `std.Build.abi.SeenPcsHeader` — kept as a local declaration on purpose: it is
/// a compiler-internal ABI, and naming it here makes the dependency explicit and
/// the failure mode a compile/size error rather than a silent misparse.
const SeenPcsHeader = extern struct {
    n_runs: usize,
    unique_runs: usize,
    pcs_len: usize,
};

const default_required = "csv_reader,source,net_source,window,index,search,encoding";

const Tally = struct { total: u32, seen: u32 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = std.Io.Threaded.global_single_threaded.io();

    var it: std.process.Args.Iterator = .init(init.minimal.args);
    _ = it.next();
    const bin_path = it.next() orelse return fail("usage: covreport <fuzz-binary> <coverage-file> [--require a,b] [--all]", .{});
    const cov_path = it.next() orelse return fail("usage: covreport <fuzz-binary> <coverage-file> [--require a,b] [--all]", .{});
    var required: []const u8 = default_required;
    var show_all = false;
    var cold: []const u8 = "";
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--require")) {
            required = it.next() orelse return fail("--require needs a comma-separated list", .{});
        } else if (std.mem.eql(u8, a, "--cold")) {
            cold = it.next() orelse return fail("--cold needs a comma-separated list", .{});
        } else if (std.mem.eql(u8, a, "--all")) {
            show_all = true;
        } else return fail("unknown argument: {s}", .{a});
    }

    // ---- decode the coverage file -----------------------------------------
    const raw = std.Io.Dir.cwd().readFileAlloc(io, cov_path, gpa, .limited(1 << 30)) catch |e|
        return fail("cannot read coverage file '{s}': {t}", .{ cov_path, e });
    defer gpa.free(raw);
    if (raw.len < @sizeOf(SeenPcsHeader)) return fail("coverage file too short", .{});

    const hdr: *const SeenPcsHeader = @ptrCast(@alignCast(raw[0..@sizeOf(SeenPcsHeader)]));
    const pcs_len = hdr.pcs_len;
    const word_bits = @bitSizeOf(usize);
    const bits_words = (pcs_len + word_bits - 1) / word_bits;
    const bits_off = @sizeOf(SeenPcsHeader);
    const pcs_off = bits_off + bits_words * @sizeOf(usize);
    const want = pcs_off + pcs_len * @sizeOf(usize);
    if (raw.len != want)
        return fail("coverage file is {d} bytes, expected {d} for {d} PCs — wrong file, or a different zig version", .{ raw.len, want, pcs_len });

    const bits: []const usize = @alignCast(std.mem.bytesAsSlice(usize, raw[bits_off..pcs_off]));
    const pcs: []const u64 = @alignCast(std.mem.bytesAsSlice(u64, raw[pcs_off..]));

    // ---- resolve PCs to source locations ----------------------------------
    var coverage: std.debug.Coverage = .init;
    defer coverage.deinit(gpa);
    var info = std.debug.Info.load(gpa, io, .{
        .root_dir = .{ .path = null, .handle = .cwd() },
        .sub_path = bin_path,
    }, &coverage, @import("builtin").object_format, @import("builtin").cpu.arch) catch |e|
        return fail("cannot load debug info from '{s}': {t}", .{ bin_path, e });
    defer info.deinit(gpa);

    const Row = struct { pc: u64, index: u32, sl: std.debug.Coverage.SourceLocation };
    var rows: std.MultiArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    try rows.resize(gpa, pcs_len);
    @memcpy(rows.items(.pc), pcs);
    for (rows.items(.index), 0..) |*v, i| v.* = @intCast(i);
    // `resolveAddresses` asserts ascending order; the PC table from the 8-bit
    // counters is not sorted.
    rows.sortUnstable(struct {
        addrs: []const u64,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.addrs[a] < ctx.addrs[b];
        }
    }{ .addrs = rows.items(.pc) });
    info.resolveAddresses(gpa, io, rows.items(.pc), rows.items(.sl)) catch |e|
        return fail("cannot resolve addresses: {t}", .{e});

    // ---- aggregate per file ------------------------------------------------
    var per_file: std.AutoArrayHashMapUnmanaged(u32, Tally) = .empty;
    defer per_file.deinit(gpa);
    var unresolved: u32 = 0;
    var seen_total: u32 = 0;
    for (rows.items(.index), rows.items(.sl)) |orig, sl| {
        const hit = (bits[orig / word_bits] >> @intCast(orig % word_bits)) & 1 != 0;
        if (hit) seen_total += 1;
        if (sl.file == .invalid) {
            unresolved += 1;
            continue;
        }
        const gop = try per_file.getOrPut(gpa, @intFromEnum(sl.file));
        if (!gop.found_existing) gop.value_ptr.* = .{ .total = 0, .seen = 0 };
        gop.value_ptr.total += 1;
        if (hit) gop.value_ptr.seen += 1;
    }

    p("======= COVERAGE REPORT =======\n", .{});
    p("binary      : {s}\n", .{bin_path});
    p("coverage    : {s}\n", .{cov_path});
    p("runs        : {d}\n", .{hdr.n_runs});
    p("unique runs : {d}\n", .{hdr.unique_runs});
    p("PCs covered : {d}/{d} ({d:.2}%)\n", .{
        seen_total,                                                                                                pcs_len,
        if (pcs_len == 0) 0.0 else @as(f64, @floatFromInt(seen_total)) * 100.0 / @as(f64, @floatFromInt(pcs_len)),
    });
    p("unresolved  : {d} PCs (no debug line info)\n\n", .{unresolved});

    // ---- the AC-c1 hotspot check ------------------------------------------
    p("-- required hotspot modules (AC-c1) --\n", .{});
    var missing: u32 = 0;
    var req_it = std.mem.tokenizeScalar(u8, required, ',');
    while (req_it.next()) |name| {
        var total: u32 = 0;
        var seen: u32 = 0;
        var files: u32 = 0;
        var fit = per_file.iterator();
        while (fit.next()) |e| {
            const f = coverage.fileAt(@enumFromInt(e.key_ptr.*));
            const base = coverage.stringAt(f.basename);
            if (!matchesModule(base, name)) continue;
            files += 1;
            total += e.value_ptr.total;
            seen += e.value_ptr.seen;
        }
        const ok = seen > 0;
        if (!ok) missing += 1;
        p("  {s:<12} {s}  {d}/{d} PCs in {d} file(s)\n", .{
            name, if (ok) "ENTERED    " else "NOT ENTERED", seen, total, files,
        });
    }
    p("\n", .{});

    // ---- per-file table ---------------------------------------------------
    const Line = struct { name: []const u8, t: Tally };
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    var fit = per_file.iterator();
    while (fit.next()) |e| {
        const f = coverage.fileAt(@enumFromInt(e.key_ptr.*));
        const base = coverage.stringAt(f.basename);
        const dir = coverage.stringAt(coverage.directories.keys()[f.directory_index]);
        // Everything outside the project is std/compiler-rt noise unless asked for.
        const in_project = std.mem.indexOf(u8, dir, "less-sheet") != null;
        if (!show_all and !in_project) continue;
        try lines.append(gpa, .{ .name = base, .t = e.value_ptr.* });
    }
    std.mem.sort(Line, lines.items, {}, struct {
        fn lt(_: void, a: Line, b: Line) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    p("-- per-file coverage ({s}) --\n", .{if (show_all) "all files" else "project files only"});
    var attributed: u32 = 0;
    for (lines.items) |l| {
        const pct = if (l.t.total == 0) 0.0 else @as(f64, @floatFromInt(l.t.seen)) * 100.0 / @as(f64, @floatFromInt(l.t.total));
        p("  {s:<28} {d:>6}/{d:<6} {d:>6.2}%\n", .{ l.name, l.t.seen, l.t.total, pct });
        attributed += l.t.total;
    }
    // BINARY-MATCH CHECK, and the reason it is printed rather than merely
    // computed. The coverage map carries PC ADDRESSES but no symbols, so handing
    // this tool a binary from a DIFFERENT build (a `-Donly` triage build, an
    // older campaign, the non-instrumented test binary) does not error — it
    // resolves a fraction of the PCs and reports every module at a fraction of
    // its true size. That reads as a catastrophic coverage collapse, and it has
    // already caused one wrong reading in this tree (`window NOT ENTERED 0/138`
    // where the truth was 215/376).
    //
    // `unresolved` is NOT a usable discriminator (316 vs 323 between a matching
    // and a non-matching binary on the same map — noise). The count of PCs
    // ATTRIBUTED to project files is: 5901 vs 3492 vs 1605 on that same map, a
    // margin no near-miss closes. Callers pick the binary that MAXIMIZES it (see
    // fuzz.sh), so it is printed as the audit trail for that choice.
    p("attributed  : {d} PCs in {d} project file(s)  <- maximize to match binary/map\n", .{ attributed, lines.items.len });
    p("==============================\n", .{});

    // ---- cold-region attribution (--cold), report-only ---------------------
    var cold_it = std.mem.tokenizeScalar(u8, cold, ',');
    while (cold_it.next()) |name| {
        coldReport(gpa, io, &coverage, rows.items(.index), rows.items(.sl), bits, name) catch |e|
            p("\ncovreport: --cold {s}: {t}\n", .{ name, e });
    }

    if (missing != 0) {
        std.debug.print("\ncovreport: {d} required hotspot module(s) NOT ENTERED\n", .{missing});
        std.process.exit(2);
    }
}

/// Per-function and cold-line-range attribution for ONE module — the aiming
/// view. Report only: it never affects the exit status, so the AC-c1 gate
/// property is untouched.
///
/// Function boundaries come from the module's OWN SOURCE, not from DWARF: a
/// `fn` line starts a span that runs to the next `fn` line. That is exact for
/// Zig's declaration order and, for a nested `fn`, deliberately attributes the
/// inner body to the inner name. The alternative (a DWARF subprogram walk) buys
/// nothing here and couples the tool to another compiler-internal layout.
fn coldReport(
    gpa: std.mem.Allocator,
    io: std.Io,
    coverage: *std.debug.Coverage,
    idxs: []const u32,
    sls: []const std.debug.Coverage.SourceLocation,
    bits: []const usize,
    module: []const u8,
) !void {
    const word_bits = @bitSizeOf(usize);

    // Locate the module's file through the resolved locations themselves, so
    // this needs no access to `Coverage`'s internal file table.
    var file: ?std.debug.Coverage.File.Index = null;
    for (sls) |sl| {
        if (sl.file == .invalid) continue;
        const f = coverage.fileAt(sl.file);
        if (matchesModule(coverage.stringAt(f.basename), module)) {
            file = sl.file;
            break;
        }
    }
    const fi = file orelse {
        p("\n-- cold regions: {s} -- no PC in this build resolved to that module\n", .{module});
        return;
    };
    const f = coverage.fileAt(fi);
    const basename = coverage.stringAt(f.basename);
    const dir = coverage.stringAt(coverage.directories.keys()[f.directory_index]);

    // ---- per-line tallies for this file ------------------------------------
    var per_line: std.AutoArrayHashMapUnmanaged(u32, Tally) = .empty;
    defer per_line.deinit(gpa);
    var mod_total: u32 = 0;
    var mod_seen: u32 = 0;
    for (idxs, sls) |orig, sl| {
        if (sl.file != fi) continue;
        const hit = (bits[orig / word_bits] >> @intCast(orig % word_bits)) & 1 != 0;
        mod_total += 1;
        if (hit) mod_seen += 1;
        const gop = try per_line.getOrPut(gpa, sl.line);
        if (!gop.found_existing) gop.value_ptr.* = .{ .total = 0, .seen = 0 };
        gop.value_ptr.total += 1;
        if (hit) gop.value_ptr.seen += 1;
    }

    p("\n-- cold regions: {s}  {d}/{d} PCs seen --\n", .{ basename, mod_seen, mod_total });

    // ---- function spans from the source ------------------------------------
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    try path.appendSlice(gpa, dir);
    try path.append(gpa, '/');
    try path.appendSlice(gpa, basename);
    const src = std.Io.Dir.cwd().readFileAlloc(io, path.items, gpa, .limited(1 << 24)) catch |e| {
        p("  (cannot read {s}: {t} — falling back to line ranges only)\n", .{ path.items, e });
        try printColdRanges(gpa, &per_line);
        return;
    };
    defer gpa.free(src);

    const Span = struct { name: []const u8, start: u32, end: u32, total: u32 = 0, seen: u32 = 0 };
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    try spans.append(gpa, .{ .name = "<file scope>", .start = 1, .end = std.math.maxInt(u32) });
    var line_no: u32 = 0;
    var lit = std.mem.splitScalar(u8, src, '\n');
    while (lit.next()) |text| {
        line_no += 1;
        if (fnNameOf(text)) |nm| {
            spans.items[spans.items.len - 1].end = line_no - 1;
            try spans.append(gpa, .{ .name = nm, .start = line_no, .end = std.math.maxInt(u32) });
        }
    }
    spans.items[spans.items.len - 1].end = line_no;

    // ---- attribute ---------------------------------------------------------
    for (per_line.keys(), per_line.values()) |line, t| {
        for (spans.items) |*s| {
            if (line >= s.start and line <= s.end) {
                s.total += t.total;
                s.seen += t.seen;
                break;
            }
        }
    }

    std.mem.sort(Span, spans.items, {}, struct {
        fn lt(_: void, a: Span, b: Span) bool {
            const ca = a.total - a.seen;
            const cb = b.total - b.seen;
            if (ca != cb) return ca > cb; // coldest first: that is what to aim at
            return a.start < b.start;
        }
    }.lt);

    p("  {s:<34} {s:>5}  {s:>9}  {s:>7}\n", .{ "function", "lines", "seen/total", "cold" });
    for (spans.items) |s| {
        if (s.total == 0) continue;
        const c = s.total - s.seen;
        p("  {s:<34} {d:>4}-{d:<4} {d:>5}/{d:<5} {d:>6}{s}\n", .{
            s.name, s.start, s.end, s.seen, s.total, c,
            if (s.seen == 0) "   NEVER ENTERED" else "",
        });
    }
    try printColdRanges(gpa, &per_line);
}

/// Contiguous runs of instrumented-but-never-executed lines. A run is broken by
/// a line that WAS executed, not by a line that carries no PC, so a cold region
/// reads as one range instead of a dozen fragments.
fn printColdRanges(gpa: std.mem.Allocator, per_line: *std.AutoArrayHashMapUnmanaged(u32, Tally)) !void {
    const Pair = struct { line: u32, t: Tally };
    var all: std.ArrayList(Pair) = .empty;
    defer all.deinit(gpa);
    for (per_line.keys(), per_line.values()) |line, t| try all.append(gpa, .{ .line = line, .t = t });
    std.mem.sort(Pair, all.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.line < b.line;
        }
    }.lt);

    p("  cold line ranges:", .{});
    var start: u32 = 0;
    var last: u32 = 0;
    var pcs: u32 = 0;
    var n: u32 = 0;
    for (all.items) |it| {
        if (it.t.seen == 0) {
            if (start == 0) start = it.line;
            last = it.line;
            pcs += it.t.total;
        } else if (start != 0) {
            if (n % 4 == 0) p("\n   ", .{});
            p(" {d}-{d}({d})", .{ start, last, pcs });
            n += 1;
            start = 0;
            pcs = 0;
        }
    }
    if (start != 0) {
        if (n % 4 == 0) p("\n   ", .{});
        p(" {d}-{d}({d})", .{ start, last, pcs });
        n += 1;
    }
    if (n == 0) p(" (none)", .{});
    p("\n", .{});
}

/// The declared name on a Zig `fn` line, after any leading modifiers; null when
/// the line does not declare one.
fn fnNameOf(text: []const u8) ?[]const u8 {
    var s = std.mem.trimStart(u8, text, " \t");
    var stripped = true;
    while (stripped) {
        stripped = false;
        for ([_][]const u8{ "pub ", "export ", "inline ", "noinline ", "threadlocal " }) |m| {
            if (std.mem.startsWith(u8, s, m)) {
                s = std.mem.trimStart(u8, s[m.len..], " \t");
                stripped = true;
            }
        }
    }
    if (!std.mem.startsWith(u8, s, "fn ")) return null;
    s = std.mem.trimStart(u8, s[3..], " \t");
    const paren = std.mem.indexOfScalar(u8, s, '(') orelse return null;
    const name = std.mem.trim(u8, s[0..paren], " \t");
    return if (name.len == 0) null else name;
}

/// A required module name matches a source file when it is that file's stem.
/// Substring matching would let `source` claim `net_source.zig`, which is exactly
/// the confusion AC-c1's separate enumeration of both is guarding against.
fn matchesModule(basename: []const u8, module: []const u8) bool {
    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |d| basename[0..d] else basename;
    return std.mem.eql(u8, stem, module);
}

/// All output goes through `std.debug.print` (stderr, locked per call). This tool
/// prints a few dozen lines, so a buffered writer buys nothing and the 0.16
/// `Io.Writer` plumbing is one more thing to get wrong.
fn p(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("covreport: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
