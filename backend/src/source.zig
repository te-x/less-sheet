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


// ---------------------------------------------------------------------------
// csv-gz SEED seam stubs (ARCH-csv-gz "Internal Source/Reader contract",
// Decision 1-C). These satisfy the contract's capability pins and compile the
// tree; they are NOT wired into the working mmap hot path (which still uses
// `len`/`slice` above), so existing behavior is byte-identical (all existing
// tests + cc/sc stay GREEN) while every csv-gz behavior test is RED. The
// implementer replaces `Source`/`Cursor` internals + these bodies with the real
// bounded, checkpointed gzip Source (mmap stays a zero-copy specialization).
// ---------------------------------------------------------------------------

/// The Source kind selected at construction (ARCH req2). `gzip` is inflated
/// transparently behind the same Reader; `mmap` is the zero-copy specialization.
pub const SourceKind = enum { mmap, gzip };

/// SEED STUB cursor shape (ARCH req2 "starts at an opaque logical position and
/// yields immutable contiguous spans", <=256 KiB, up to 4 bytes cross-span
/// lookahead, reports SourceEnd). The REAL cursor (leased/pinned spans, gzip
/// replay session, dual-coordinate reporting) is implementer-owned; this stub
/// only exists so `core.Cursor` / `sourceCursorAt` type-check.
pub const Cursor = struct {
    logical: u64 = 0,
    physical: u64 = 0,
    span_len: usize = 0,
};

/// Construct a Source over the physical `mapping` for the selected `kind`
/// (ARCH: construction from a physical mmap + mmap|gzip kind). SEED: always the
/// mmap specialization -- gzip detection/inflation is NOT wired yet, so a gzip
/// file falls through to the mmap-as-plain path and every gzip behavior test
/// diverges from its plain reference (RED).
pub fn sourceFromMapping(mapping: []const u8, kind: SourceKind) Source {
    _ = kind;
    return .{ .mmap = .{ .bytes = mapping } };
}

/// Explicit Source shutdown (ARCH req9): signal in-flight cursor sessions to
/// stop at a bounded chunk boundary. SEED: no gzip state -> no-op.
pub fn sourceShutdown(source: *Source) void {
    _ = source;
}

/// Explicit Source deinitialization (ARCH req2/req9): release cursor sessions,
/// cache blocks, close the already-unlinked checkpoint store, before the
/// physical mapping is unmapped. SEED: no gzip state -> no-op (the mmap unmap
/// still happens in base.freeDoc, unchanged).
pub fn sourceDeinit(source: *Source) void {
    _ = source;
}
