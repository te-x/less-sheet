//! Seed-corpus loader.
//!
//! The committed corpus lives in four PACK files, one per fuzz target. A pack is
//! a flat concatenation of length-framed entries:
//!
//!     entry := u32le byte_len || byte_len bytes
//!
//! and each entry is one complete `std.testing.Smith` REPLAY BLOB for its target
//! (the wire format Smith itself documents at `std/testing/Smith.zig` `constructInput`):
//!
//!     blob := u32le n || n document bytes      <- smith.sliceWeightedBytes(&doc_buf, ..)
//!          || u64le w0 || u64le w1 || u64le w2 <- smith.valueRangeAtMost(u64, 0, maxInt)
//!          || u32le m || m needle bytes        <- smith.sliceWeightedBytes(&needle_buf, ..)
//!
//! A pack is deliberately a plain file rather than generated Zig source: adding a
//! regression seed (AC-c2) is an append, and `tools/fuzz/seedgen.zig --append`
//! does exactly that without regenerating anything else.
//!
//! `std.testing.FuzzInputOptions.corpus` entries are handed to the fuzzer BELOW
//! its mutable watermark (`compiler/test_runner.zig` -> `fuzzer_new_input`, and
//! `fuzzer.zig` ignores them once `start_mut_corpus` is set), so unlike an
//! on-disk pre-seed they are never culled. They double as the deterministic
//! REPLAY set: a plain `zig build test` (no `-ffuzz`) runs every entry once
//! through the same target function.

const std = @import("std");

/// Split a pack into its entries at comptime.
fn unpack(comptime blob: []const u8) []const []const u8 {
    comptime {
        @setEvalBranchQuota(200_000);
        var list: []const []const u8 = &.{};
        var i: usize = 0;
        while (i + 4 <= blob.len) {
            const n = std.mem.readInt(u32, blob[i..][0..4], .little);
            i += 4;
            if (i + n > blob.len) @compileError("truncated seed pack");
            list = list ++ &[_][]const u8{blob[i .. i + n]};
            i += n;
        }
        if (i != blob.len) @compileError("trailing bytes in seed pack");
        return list;
    }
}

pub const csv = unpack(@embedFile("seeds/csv.pack"));
pub const gz_raw = unpack(@embedFile("seeds/gz_raw.pack"));
pub const gz_trunc = unpack(@embedFile("seeds/gz_trunc.pack"));
pub const net = unpack(@embedFile("seeds/net.pack"));
