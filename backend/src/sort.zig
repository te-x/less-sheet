//! SORTED VIEWS — the third view kind (ARCH-sort-by-column). See
//! api/lesssheet.h "SORTED VIEWS" for the normative model: the comparator's
//! total order, the key pass, flip-only-at-ACTIVE, sorted coordinates, jump and
//! find under a sort, the four-way scan slot, the rebuild triggers, RESET,
//! failure, and laziness.
//!
//! SEED (planner-authored): request VALIDATION and the poll snapshot are real —
//! everything else is absent. A valid `ls_sort_set` records the request and
//! returns true but starts NO key pass, so `ls_sort_poll` stays `.idle` and the
//! frozen `waitSortActive` helper fails fast with `error.SortNotStarted`
//! (mirroring `waitFilterDone` over the column-config seed) instead of hanging.
//! Every instrumentation seam reports zeros. That is what makes every ordering,
//! coordinate, composition, slot, bound, and failure assertion in the `srt_*`
//! suite RED until the real pass, external merge, permutation, and inverse
//! mapping are built and wired.

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");
const tempdir = @import("tempdir.zig");

const Document = base.Document;

/// `ls_sort_set`. Validation is REAL in the seed (the rejection guards are
/// green from the start); the build is not.
pub fn setSort(d: *Document, column: u32, direction: api.SortDirection) bool {
    switch (direction) {
        .ascending, .descending => {},
    }
    d.lock();
    defer d.unlock();
    if (column >= d.column_count) return false;
    // A no-op re-request of an ACTIVE (column, direction) changes nothing at
    // all — not even the search/jump reset (api/lesssheet.h THE FLIP).
    if (d.sort_state == .active and d.sort_column == column and d.sort_direction == direction) return true;
    // SEED: record the request, start nothing. The real implementation takes
    // the scan slot, resets search + jump, and drives the key pass.
    d.sort_column = column;
    d.sort_direction = direction;
    return true;
}

/// `ls_sort_clear` — also the cancel verb. ZERO allocation; never fails.
pub fn clearSort(d: *Document) void {
    d.lock();
    defer d.unlock();
    if (d.sort_state == .idle) return;
    d.sort_state = .idle;
    d.sort_err = .ok;
    d.sort_column = 0;
    d.sort_direction = .ascending;
    d.sort_progress = 0.0;
}

/// `ls_sort_poll`. ZERO allocation; never fails; never scans.
pub fn pollSort(d: *Document) api.SortStatus {
    d.lock();
    defer d.unlock();
    if (d.sort_state == .idle) return .{
        .state = .idle,
        .err = .ok,
        .column = 0,
        .direction = .ascending,
        .progress = 0.0,
    };
    return .{
        .state = d.sort_state,
        .err = d.sort_err,
        .column = d.sort_column,
        .direction = d.sort_direction,
        .progress = d.sort_progress,
    };
}

// --- The ONE chunk knob: one default (contracts/api.zig
// `sort_chunk_default_bytes`) + THIS resolver. Every consumer inside the sort
// reads `chunkBytes(d)`; nothing re-derives the number. -------------------

/// THE RESOLVER (contracts/api.zig `sortChunkBytes`).
pub fn chunkBytes(d: *const Document) u64 {
    return if (d.sort_chunk_override != 0) d.sort_chunk_override else api.sort_chunk_default_bytes;
}

/// Test seam: override the chunk knob for this document (0 restores default).
pub fn chunkBytesSetForTest(d: *Document, bytes: u64) void {
    d.lock();
    defer d.unlock();
    d.sort_chunk_override = bytes;
}

// --- Instrumentation seams (Zig-only; see contracts/api.zig) ---------------

pub fn tempStore(d: *const Document) api.SortTempStore {
    return .{
        .present = d.sort_temp_files != 0,
        .files = d.sort_temp_files,
        .live_bytes = d.sort_temp_live_bytes,
        .peak_bytes = d.sort_temp_peak_bytes,
        .mode = d.sort_temp_mode,
        .unlinked = d.sort_temp_unlinked,
    };
}

pub fn tempFailAfter(d: *Document, ops: u64) void {
    d.lock();
    defer d.unlock();
    d.sort_temp_fail_after = ops;
}

pub fn allocFailAfter(d: *Document, allocs: u64) void {
    d.lock();
    defer d.unlock();
    d.sort_alloc_fail_after = allocs;
}

pub fn residentBytes(d: *const Document) u64 {
    return d.sort_resident_peak;
}

pub fn residentReset(d: *Document) void {
    d.lock();
    defer d.unlock();
    d.sort_resident_peak = 0;
}

/// Where this document's sort scratch goes — always THE resolver, never a
/// locally built "/tmp/..." literal (src/tempdir.zig says why).
pub fn tempDir() []const u8 {
    return tempdir.resolve();
}
