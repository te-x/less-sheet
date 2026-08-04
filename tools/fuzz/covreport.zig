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
//!
//! Counts are PCs (instrumented basic blocks), not lines: "seen" means the
//! fuzzer executed that block at least once, accumulated across every run that
//! shared the cache.

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
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--require")) {
            required = it.next() orelse return fail("--require needs a comma-separated list", .{});
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
    for (lines.items) |l| {
        const pct = if (l.t.total == 0) 0.0 else @as(f64, @floatFromInt(l.t.seen)) * 100.0 / @as(f64, @floatFromInt(l.t.total));
        p("  {s:<28} {d:>6}/{d:<6} {d:>6.2}%\n", .{ l.name, l.t.seen, l.t.total, pct });
    }
    p("==============================\n", .{});
    if (missing != 0) {
        std.debug.print("\ncovreport: {d} required hotspot module(s) NOT ENTERED\n", .{missing});
        std.process.exit(2);
    }
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
