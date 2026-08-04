//! Seed-corpus generator — builds the four committed `.pack` files.
//!
//!   seedgen pack <out-dir> [--csv <file>...] [--gz <file>...]
//!   seedgen append <pack-file> <blob-file>
//!
//! `pack` is deterministic: same inputs, byte-identical packs. `append` is the
//! AC-c2 regression path — the fuzzer saves a crashing input to
//! `.zig-cache/f/crash`, which is already a Smith replay blob for the target that
//! crashed, so appending it to that target's pack turns the crash into a
//! permanent seed AND (because a plain `zig build test` replays every entry) into
//! a deterministic regression case.
//!
//! Seed sources, per AC-c1 ("seeded from the `csvgen` corpus + adversarial
//! gz/truncation/wide/ragged seeds"):
//!   * the `--csv` / `--gz` files: the `tools/csvgen` catalog the gate already
//!     runs (all 60 light cases of its 63-case catalog; the 3 heavy ones are
//!     multi-GB streams `--all` skips), generated with `--gzip` so the gz arm is
//!     seeded from the same catalog;
//!   * the built-in adversarial set below, which covers what a generator of
//!     WELL-FORMED CSV by construction cannot: unterminated quotes, lone quotes,
//!     embedded NULs, mixed line endings, encoding confusion, an over-cap cell, a
//!     wide record, ragged records, the formula-injection vectors, and the gzip
//!     damage matrix;
//!   * the two `flate_b1` regression cuts, byte-exact (see `gzbuild.zig`).

const std = @import("std");
const gzbuild = @import("gzbuild.zig");

/// Must match the harness's per-target draw buffers: a blob whose framed length
/// exceeds the buffer replays as a ZERO-length document (`Smith.sliceWeighted*`
/// falls back to `len_weights[0].min` when the encoded length is out of range),
/// which would silently void the seed.
const doc_max = 64 * 1024;
/// `gz_raw`'s draw buffer, smaller than `doc_max` because its bytes are
/// compressed — see the same constant in `harness.zig` for why, and why 24 KiB
/// specifically (it holds the `flate_b1` fixture-B regression member intact).
const gz_doc_max = 24 * 1024;
const plain_max = 32 * 1024;
const needle_max = 48;

var prng_state: u64 = 0x9e3779b97f4a7c15;

fn rnd() u64 {
    prng_state +%= 0x9e3779b97f4a7c15;
    var z = prng_state;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

const Pack = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    count: usize = 0,
    cap: usize,

    fn putInt(p: *Pack, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try p.bytes.appendSlice(p.gpa, &tmp);
    }

    fn add(p: *Pack, data: []const u8, w0: u64, w1: u64, w2: u64, needle: []const u8) !void {
        const doc = data[0..@min(data.len, p.cap)];
        const nd = needle[0..@min(needle.len, needle_max)];
        const blob_len = 4 + doc.len + 24 + 4 + nd.len;
        try p.putInt(u32, @intCast(blob_len));
        try p.putInt(u32, @intCast(doc.len));
        try p.bytes.appendSlice(p.gpa, doc);
        for ([_]u64{ w0, w1, w2 }) |v| try p.putInt(u64, v);
        try p.putInt(u32, @intCast(nd.len));
        try p.bytes.appendSlice(p.gpa, nd);
        p.count += 1;
    }

    /// One document -> the zero-word baseline (a well-formed, in-range drive that
    /// on its own reaches every hotspot) plus `variants` pseudo-random knob
    /// triples, with needles taken from the document itself so search/filter
    /// start from HITS rather than misses.
    fn addSpread(p: *Pack, data: []const u8, variants: u32) !void {
        try p.add(data, 0, 0, 0, "");
        for (0..variants) |_| {
            const w0 = rnd();
            const w1 = rnd();
            const w2 = rnd();
            var needle: []const u8 = "";
            if (data.len > 8) {
                const off = rnd() % (data.len - 8);
                const len = 1 + rnd() % 8;
                needle = data[off..][0..@intCast(len)];
            }
            try p.add(data, w0, w1, w2, needle);
        }
    }

    fn flush(p: *Pack, dir: std.Io.Dir, io: std.Io, name: []const u8) !void {
        try dir.writeFile(io, .{
            .sub_path = name,
            .data = p.bytes.items,
            .flags = .{ .permissions = .fromMode(0o644) },
        });
        std.debug.print("  {s}: {d} entries, {d} bytes\n", .{ name, p.count, p.bytes.items.len });
    }
};

/// Adversarial CSV texts. These are the cases a correct-by-construction fixture
/// generator does not emit, and each one is a shape that has historically broken
/// a CSV reader.
fn adversarialCsv(gpa: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    const literals = [_][]const u8{
        "",
        "\n",
        "\r",
        "\r\n",
        "a",
        "\"",
        "\"\"",
        "\"unterminated,x\ny,z\n",
        "a,\"b\"\"c\",d\n",
        "a,\"b\nc\",d\n",
        ",,,\n,,,\n,,,\n",
        "a,b\n1\n2,3,4\n5,6\n", // ragged
        "a;b;c\n1;2;3\n", // semicolon
        "a\tb\tc\n1\t2\t3\n", // tab
        "a|b|c\n1|2|3\n",
        "a,b\r1,2\r3,4\r", // lone-CR line endings
        "a,b\n1,2", // no trailing newline
        "\xef\xbb\xbfa,b\n1,2\n", // UTF-8 BOM
        "\xff\xfea\x00,\x00b\x00\n\x00", // UTF-16LE BOM
        "\xfe\xff\x00a\x00,\x00b\x00\n", // UTF-16BE BOM
        "\xff\xfe\x41", // UTF-16LE BOM + an ODD trailing byte
        "a,b\n\xe9\xe8,\xc0\n", // latin1/cp1252 high bytes
        "a,b\n\xed\xa0\x80,x\n", // a UTF-8-encoded surrogate (invalid)
        "a,b\n\xc3,x\n", // a truncated UTF-8 sequence
        "a\x00b,c\n1,2\n", // embedded NUL
        "=cmd|' /C calc'!A0,+1,-3,@SUM(1),-x,+y\n", // formula-injection vectors
        "1e400,-0,+2.5,0x10,1_000,.5,5.,NaN,inf\n", // number-grammar edges
        "\"\"\"\"\"\",x\n", // quote soup
        "a,b\n\"1\",\"2\"\n\"3\",\"4\"\n",
    };
    for (literals) |l| try out.append(gpa, l);

    // A WIDE record: more columns than any viewport, at the cap boundary.
    {
        var w: std.ArrayList(u8) = .empty;
        for (0..4000) |i| {
            if (i != 0) try w.append(gpa, ',');
            try w.print(gpa, "c{d}", .{i});
        }
        try w.append(gpa, '\n');
        for (0..4000) |i| {
            if (i != 0) try w.append(gpa, ',');
            try w.print(gpa, "{d}", .{i});
        }
        try w.append(gpa, '\n');
        try out.append(gpa, try w.toOwnedSlice(gpa));
    }
    // A cell far past the 4 KiB cell cap.
    {
        var w: std.ArrayList(u8) = .empty;
        try w.appendSlice(gpa, "a,");
        try w.appendNTimes(gpa, 'x', 20_000);
        try w.appendSlice(gpa, ",b\n1,2,3\n");
        try out.append(gpa, try w.toOwnedSlice(gpa));
    }
    // A quoted cell that never closes, spanning the whole document.
    {
        var w: std.ArrayList(u8) = .empty;
        try w.append(gpa, '"');
        try w.appendNTimes(gpa, 'q', 30_000);
        try out.append(gpa, try w.toOwnedSlice(gpa));
    }
    // Many short rows: crosses the index's row-group boundaries.
    {
        var w: std.ArrayList(u8) = .empty;
        for (0..4000) |i| try w.print(gpa, "{d},{d}\n", .{ i, i * 3 });
        try out.append(gpa, try w.toOwnedSlice(gpa));
    }
}

fn fixedRowsAlloc(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, n * 18 + 64);
    defer out.deinit();
    try gzbuild.fixedRows(&out.writer, n);
    return gpa.dupe(u8, out.written());
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = std.Io.Threaded.global_single_threaded.io();
    var it: std.process.Args.Iterator = .init(init.minimal.args);
    _ = it.next();

    const mode = it.next() orelse return usage();

    if (std.mem.eql(u8, mode, "append")) {
        const pack_path = it.next() orelse return usage();
        const blob_path = it.next() orelse return usage();
        const blob = try std.Io.Dir.cwd().readFileAlloc(io, blob_path, gpa, .limited(1 << 24));
        defer gpa.free(blob);
        const old = std.Io.Dir.cwd().readFileAlloc(io, pack_path, gpa, .limited(1 << 28)) catch
            try gpa.dupe(u8, "");
        defer gpa.free(old);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, old);
        var len_le: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_le, @intCast(blob.len), .little);
        try out.appendSlice(gpa, &len_le);
        try out.appendSlice(gpa, blob);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = pack_path,
            .data = out.items,
            .flags = .{ .permissions = .fromMode(0o644) },
        });
        std.debug.print("appended {d} bytes to {s}\n", .{ blob.len, pack_path });
        return;
    }
    if (!std.mem.eql(u8, mode, "pack")) return usage();

    const out_dir_path = it.next() orelse return usage();
    var csv_files: std.ArrayList([]const u8) = .empty;
    var gz_files: std.ArrayList([]const u8) = .empty;
    var bucket: u8 = 0;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--csv")) {
            bucket = 1;
        } else if (std.mem.eql(u8, a, "--gz")) {
            bucket = 2;
        } else switch (bucket) {
            1 => try csv_files.append(gpa, a),
            2 => try gz_files.append(gpa, a),
            else => return usage(),
        }
    }

    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir_path, .{});
    defer out_dir.close(io);

    var csv: Pack = .{ .gpa = gpa, .cap = doc_max };
    var gz_raw: Pack = .{ .gpa = gpa, .cap = gz_doc_max };
    var gz_trunc: Pack = .{ .gpa = gpa, .cap = plain_max };
    var net: Pack = .{ .gpa = gpa, .cap = doc_max };

    // ---- csv: the csvgen catalog -------------------------------------------
    for (csv_files.items) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(doc_max)) catch |e| switch (e) {
            // A catalog case larger than the draw buffer: take its head, which is
            // still a valid CSV prefix (and a truncated last record, which is
            // itself worth seeding).
            error.StreamTooLong => try headOf(gpa, io, path, doc_max),
            else => return e,
        };
        defer gpa.free(data);
        try csv.addSpread(data, 1);
    }

    // ---- csv: the adversarial set ------------------------------------------
    var adv: std.ArrayList([]const u8) = .empty;
    try adversarialCsv(gpa, &adv);
    for (adv.items) |d| try csv.addSpread(d, 2);

    // ---- gz_raw: the csvgen catalog's .csv.gz twins ------------------------
    for (gz_files.items) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(gz_doc_max)) catch |e| switch (e) {
            error.StreamTooLong => try headOf(gpa, io, path, gz_doc_max),
            else => return e,
        };
        defer gpa.free(data);
        try gz_raw.addSpread(data, 1);
    }

    // ---- gz_raw: the damage matrix + the flate_b1 regression cuts ----------
    {
        const win = try gpa.alloc(u8, gzbuild.window_len);
        defer gpa.free(win);
        const scratch = try gpa.alloc(u8, 4 * 1024 * 1024);
        defer gpa.free(scratch);
        const out = try gpa.alloc(u8, 4 * 1024 * 1024);
        defer gpa.free(out);

        // THE TWO REGRESSION SEEDS the reviewer asked to carry over
        // (review/REVIEW-flate-feed-guard.md): fixture A cut 50 and fixture B cut
        // 16891 — mid-DEFLATE-symbol truncations that produced a garbage decode
        // (a complete, exact, WRONG document) before the wave-(b) fix. `tail_cut`
        // counts bytes removed from the END, so a "keep N" cut is raw.len - N.
        const fa = try fixedRowsAlloc(gpa, 180);
        defer gpa.free(fa);
        const fb = try fixedRowsAlloc(gpa, 8_000);
        defer gpa.free(fb);
        const raw_a = gzbuild.deflateRaw(fa, win, scratch).?.len;
        const raw_b = gzbuild.deflateRaw(fb, win, scratch).?.len;
        std.debug.print("  flate_b1 fixture A raw={d} (keep 50), B raw={d} (keep 16891)\n", .{ raw_a, raw_b });

        const regressions = [_]struct { plain: []const u8, keep: usize }{
            .{ .plain = fa, .keep = 50 },
            .{ .plain = fb, .keep = 16891 },
        };
        for (regressions) |reg| {
            const raw_len = gzbuild.deflateRaw(reg.plain, win, scratch).?.len;
            const shape: gzbuild.Shape = .{
                .tail_cut = @intCast(raw_len - reg.keep),
                .omit_footer = true,
            };
            const m = gzbuild.member(reg.plain, shape, win, scratch, out).?;
            try gz_raw.addSpread(m, 1);
        }

        // The damage matrix over a small, complete payload.
        const shapes = [_]gzbuild.Shape{
            .{}, // complete, well-formed
            .{ .extra_members = 1 }, // valid multi-member
            .{ .extra_members = 3 },
            .{ .bad_crc = true },
            .{ .bad_isize = true },
            .{ .fhcrc = true },
            .{ .bad_fhcrc = true },
            .{ .fname = true },
            .{ .cm_sel = 4 }, // CM=0: must be refused
            .{ .cm_sel = 5 }, // CM=9: must be refused
            .{ .omit_footer = true },
            .{ .tail_cut = 1, .omit_footer = true },
            .{ .tail_cut = 2, .omit_footer = true },
            .{ .tail_cut = 7, .omit_footer = true },
            .{ .tail_cut = 31, .omit_footer = true },
            .{ .tail_cut = 97, .omit_footer = true },
            .{ .tail_cut = 251, .omit_footer = true },
            .{ .tail_cut = 1021, .omit_footer = true },
        };
        for (shapes) |s| {
            const m = gzbuild.member(fa, s, win, scratch, out).?;
            try gz_raw.addSpread(m, 0);
        }
        // A header with no payload at all, and magic followed by noise.
        try gz_raw.addSpread(&.{ 0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff }, 0);
        try gz_raw.addSpread("\x1f\x8b\x08\x00pure garbage after the magic", 1);
        try gz_raw.addSpread("\x1f\x8b", 0);

        // ---- gz_trunc: PLAIN payloads; w0 carries the cut ------------------
        // Fixture A's payload fits the 32 KiB draw buffer, so its exact cut is
        // reproducible in this target too (fixture B's 144 KB payload does not —
        // it is carried as a finished member in gz_raw above).
        const fa_cut: gzbuild.Shape = .{ .tail_cut = @intCast(raw_a - 50), .omit_footer = true };
        try gz_trunc.add(fa, fa_cut.encode(), 0, 0, "");
        const payloads = [_][]const u8{ fa, "a,b\n1,2\n", "x\n" };
        for (payloads) |plain| {
            if (plain.len > plain_max) continue;
            try gz_trunc.addSpread(plain, 2);
            var k: u20 = 1;
            while (k < 64) : (k *= 2) {
                const s: gzbuild.Shape = .{ .tail_cut = k, .omit_footer = true };
                try gz_trunc.add(plain, s.encode(), 0, 0, "");
            }
        }
        const rows_1800 = try fixedRowsAlloc(gpa, 1_800);
        defer gpa.free(rows_1800);
        try gz_trunc.addSpread(rows_1800, 2);
    }

    // ---- net: bodies the fake transport serves -----------------------------
    for (adv.items) |d| try net.addSpread(d, 1);
    {
        const rows = try fixedRowsAlloc(gpa, 2_000);
        defer gpa.free(rows);
        try net.addSpread(rows, 3);
    }

    try csv.flush(out_dir, io, "csv.pack");
    try gz_raw.flush(out_dir, io, "gz_raw.pack");
    try gz_trunc.flush(out_dir, io, "gz_trunc.pack");
    try net.flush(out_dir, io, "net.pack");
}

fn headOf(gpa: std.mem.Allocator, io: std.Io, path: []const u8, n: usize) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const buf = try gpa.alloc(u8, n);
    var rb: [4096]u8 = undefined;
    var r = f.reader(io, &rb);
    const got = r.interface.readSliceShort(buf) catch 0;
    return gpa.realloc(buf, got);
}

fn usage() void {
    std.debug.print(
        \\usage: seedgen pack <out-dir> [--csv <file>...] [--gz <file>...]
        \\       seedgen append <pack-file> <blob-file>
        \\
    , .{});
}
