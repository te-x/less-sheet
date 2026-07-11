//! The Source seam: a general byte provider a byte-oriented Reader (the CSV
//! Reader today — src/csv_reader.zig) consumes instead of touching the
//! document's mmap directly (see docs/architecture/ARCH-reader-interface.md).
//! One variant today, `mmap` — an identity, zero-copy wrapper over the
//! read-only mmap'd file bytes (built once at `ls_open` from the post-BOM
//! content slice; see root.zig / `Document.source`).
//!
//! A byte-oriented Reader calls ONLY `len`/`slice` here, never assumes the
//! bytes are already resident: a future gzip Source (inflate + inflate-
//! checkpoints, so a behind-frontier seek resumes decompression from the
//! nearest checkpoint instead of the start — `[[formats-roadmap]]`) or a
//! ZIP-entry Source (ODS/XLSX) would add a sibling variant here whose
//! `slice` inflates up to the requested end first; `csv_reader.zig`'s call
//! sites are unaffected, since they already only ever call `len`/`slice`. A
//! columnar Reader (Parquet) would bypass this seam entirely and read its
//! file's own structure directly — see docs/architecture/ARCH-reader-
//! interface.md's AC5 note (also summarized at the bottom of
//! src/csv_reader.zig).

/// Identity byte provider: the whole span is already resident (the mmap'd,
/// post-BOM file content). `len`/`slice` are zero-cost (a plain re-slice).
pub const Mmap = struct {
    bytes: []const u8,
};

/// The seam itself: one variant today (`mmap`).
pub const Source = union(enum) {
    mmap: Mmap,

    /// Total bytes available from this Source.
    pub fn len(self: Source) u64 {
        return switch (self) {
            .mmap => |m| m.bytes.len,
        };
    }

    /// The byte range `[start, end)` (`end <= len()`). Always already
    /// resident for the identity `mmap` variant; a gzip/ZIP-entry Source
    /// would inflate up to `end` first (see the module doc).
    pub fn slice(self: Source, start: u64, end: u64) []const u8 {
        return switch (self) {
            .mmap => |m| m.bytes[@intCast(start)..@intCast(end)],
        };
    }
};
