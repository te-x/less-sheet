//! column-config slice (ARCH-column-config) — RED SEED of the additive column-
//! metadata C ABI (see api/lesssheet.h COLUMN METADATA EXTENSION and the
//! contract mirror in contracts/api.zig). root.zig's `ls_column_*` exports
//! delegate here; the frozen behavior suite (tests/all_tests.zig, the `cc_*`
//! block) drives these through the public ABI.
//!
//! WHAT THIS SEED DOES (deliberately just enough to be RED-on-behavior, green-
//! on-conformance):
//!   - Validates every argument exactly as the header specifies (shape, size/
//!     version, capacity, ID range, UTF-8, override descriptor) and returns the
//!     documented error code with NO output/mutation — so the atomic-error and
//!     layout/validation GUARD tests are green by construction.
//!   - `metadata_get_many` SYNTHESIZES the canonical generation-0
//!     unrequested/unknown snapshot for every requested ID (the header's
//!     "untouched IDs are synthesized without state" rule) and reports global
//!     generation 0.
//!   - Every MUTATING call (inference request, override/sentinel set+clear,
//!     accept-proposal) is a validated NO-OP: it stores nothing, publishes
//!     nothing, and never advances a generation. The poll reports JOB_IDLE. The
//!     label/sentinel/example copies report "no value / zero length".
//!
//! CONSEQUENCE (why the suite is RED): because nothing is ever stored,
//! inferred, published, or copied, every behavioral AC — first-sample bound,
//! 8-value publication, provisional→published, precedence `override > inferred
//! > declared`, override/sentinel taking effect, one-commit generations,
//! conflict/proposal, windowed header labels, sentinel/example round-trips —
//! FAILS against this seed and passes only once the real sparse type model +
//! bounded lazy inference is built (in THIS module + base.Document, both
//! implementer-owned in src/). Mirrors the copy_advances==0 / gz_* / window-
//! budget RED-seed pattern.
//!
//! The C ABI does not need a Zig-only test seam here: the metadata / status
//! snapshot structs (rows_scanned, source_bytes_scanned, sampled_*, evidence_
//! count, generation, inference_state, confidence, conflict_state, …) ARE the
//! instrumentation the ACs assert against, all through @import("api").

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");

const Document = base.Document;

const abi_version = api.column_metadata_abi_version;

/// The canonical UNKNOWN type descriptor (an absent declared/inferred/override/
/// effective/proposal slot). All parameters at their UNSPECIFIED sentinels.
fn unknownType() api.ColumnType {
    return .{
        .struct_size = @sizeOf(api.ColumnType),
        .abi_version = abi_version,
        .kind = .unknown,
        .flags = 0,
        .decimal_precision = api.column_type_precision_unspecified,
        .decimal_scale = api.column_type_scale_unspecified,
        .datetime_semantics = .none,
        .datetime_fraction_digits = api.column_type_fraction_digits_unspecified,
        .reserved = 0,
    };
}

/// The generation-0 unrequested/unknown snapshot the header promises for an
/// untouched column (no stored per-column state).
fn synthUnknown(col: u32) api.ColumnMetadata {
    const u = unknownType();
    return .{
        .struct_size = @sizeOf(api.ColumnMetadata),
        .abi_version = abi_version,
        .column = col,
        .presence_flags = 0,
        .generation = 0,
        .declared = u,
        .inferred = u,
        .override = u,
        .effective = u,
        .proposal = u,
        .effective_source = .none,
        .inference_state = .unrequested,
        .confidence = .none,
        .null_policy = .none,
        .conflict_state = .none,
        .null_sentinel_bytes = 0,
        .evidence_count = 0,
        .sampled_row_count = 0,
        .sampled_decoded_bytes = 0,
        .empty_count = 0,
        .null_count = 0,
        .conflict_count = 0,
        .conflict_source_row = api.no_row,
        .conflict_example_bytes = 0,
        .conflict_example_truncated = 0,
        .reserved = .{ 0, 0, 0, 0 },
    };
}

/// A well-formed explicit override descriptor (ls_column_override_set input):
/// an explicit v1 base kind with parameters that are metadata-only left
/// UNSPECIFIED, and — for DATETIME only — an explicit NAIVE/ZONED semantic.
/// UNKNOWN/UNSUPPORTED and every malformed parameter combination are rejected.
fn validOverrideType(t: api.ColumnType) bool {
    if (t.struct_size != @sizeOf(api.ColumnType) or t.abi_version != abi_version) return false;
    if (t.flags != 0 or t.reserved != 0) return false;
    // precision/scale/fraction are inferred metadata / a separate frontend
    // format setting — an override descriptor leaves them UNSPECIFIED.
    if (t.decimal_precision != api.column_type_precision_unspecified) return false;
    if (t.decimal_scale != api.column_type_scale_unspecified) return false;
    if (t.datetime_fraction_digits != api.column_type_fraction_digits_unspecified) return false;
    switch (t.kind) {
        .text, .boolean, .integer, .decimal, .date => return t.datetime_semantics == .none,
        .datetime => return t.datetime_semantics == .naive or t.datetime_semantics == .zoned,
        .unknown, .unsupported => return false,
    }
}

fn idsValid(doc: *const Document, ids: [*]const u32, count: u32) bool {
    const cc = doc.column_count;
    var i: u32 = 0;
    while (i < count) : (i += 1) if (ids[i] >= cc) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Mutating calls (poll/control lane). RED SEED: validate, then no-op.
// ---------------------------------------------------------------------------

pub fn inferenceRequest(doc: *Document, ids: ?[*]const u32, count: u32) api.ColumnResult {
    if (count == 0 or count > api.column_batch_max) return .invalid_argument;
    const p = ids orelse return .invalid_argument;
    if (!idsValid(doc, p, count)) return .no_column;
    // RED SEED: no desired set, no worker job, no sparse state created.
    return .ok;
}

pub fn inferenceCancel(doc: *Document) void {
    _ = doc; // RED SEED: no job to cancel.
}

pub fn overrideSet(doc: *Document, column: u32, ty: *const api.ColumnType) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    if (!validOverrideType(ty.*)) return .invalid_argument;
    // RED SEED: not stored -> effective never becomes the override.
    return .ok;
}

pub fn overrideClear(doc: *Document, column: u32) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    return .ok; // RED SEED: nothing stored to clear.
}

pub fn nullSentinelSet(doc: *Document, column: u32, bytes: ?[*]const u8, len: usize) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    if (len > api.column_sentinel_max_bytes) return .invalid_argument;
    if (len > 0) {
        const p = bytes orelse return .invalid_argument;
        if (!std.unicode.utf8ValidateSlice(p[0..len])) return .invalid_argument;
    }
    // len == 0 with a null pointer is valid: the empty sentinel.
    return .ok; // RED SEED: not stored.
}

pub fn nullSentinelClear(doc: *Document, column: u32) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    return .ok;
}

pub fn acceptProposal(doc: *Document, column: u32) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    return .no_proposal; // RED SEED: no proposal ever exists.
}

// ---------------------------------------------------------------------------
// Query / poll / copy calls (poll/control lane; ZERO allocation).
// ---------------------------------------------------------------------------

pub fn metadataPoll(doc: *Document, out: *api.ColumnInferenceStatus) api.ColumnResult {
    _ = doc;
    if (out.struct_size != @sizeOf(api.ColumnInferenceStatus) or out.abi_version != abi_version)
        return .invalid_argument;
    out.* = .{
        .struct_size = @sizeOf(api.ColumnInferenceStatus),
        .abi_version = abi_version,
        .state = .idle,
        .reserved0 = 0,
        .request_generation = 0,
        .metadata_generation = 0,
        .requested_column_count = 0,
        .completed_column_count = 0,
        .source_bytes_scanned = 0,
        .source_bytes_budget = 0,
        .rows_scanned = 0,
        .rows_budget = 0,
        .progress = 0.0,
        .reserved = .{ 0, 0, 0, 0 },
    };
    return .ok;
}

pub fn metadataGetMany(
    doc: *Document,
    ids: ?[*]const u32,
    count: u32,
    out: ?[*]api.ColumnMetadata,
    capacity: u32,
    out_gen: *u64,
) api.ColumnResult {
    if (count == 0) {
        out_gen.* = 0;
        return .ok;
    }
    if (count > api.column_batch_max or capacity > api.column_batch_max or capacity < count)
        return .invalid_argument;
    const p = ids orelse return .invalid_argument;
    const items = out orelse return .invalid_argument;
    // All-or-nothing: validate every element's size/version, then every ID,
    // before writing any output byte.
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (items[i].struct_size != @sizeOf(api.ColumnMetadata) or items[i].abi_version != abi_version)
            return .invalid_argument;
    }
    if (!idsValid(doc, p, count)) return .no_column;
    out_gen.* = 0; // RED SEED: global generation never advances.
    i = 0;
    while (i < count) : (i += 1) items[i] = synthUnknown(p[i]);
    return .ok;
}

pub fn labelsCopyMany(
    doc: *Document,
    ids: ?[*]const u32,
    count: u32,
    spans: ?[*]api.ColumnLabelSpan,
    capacity: u32,
    arena: ?[*]u8,
    arena_capacity: usize,
    out_required: *usize,
) api.ColumnResult {
    _ = arena;
    _ = arena_capacity;
    if (count == 0) {
        out_required.* = 0;
        return .ok;
    }
    if (count > api.column_batch_max or capacity > api.column_batch_max or capacity < count)
        return .invalid_argument;
    const p = ids orelse return .invalid_argument;
    const sp = spans orelse return .invalid_argument;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (sp[i].struct_size != @sizeOf(api.ColumnLabelSpan) or sp[i].abi_version != abi_version)
            return .invalid_argument;
    }
    if (!idsValid(doc, p, count)) return .no_column;
    // RED SEED: report every label as header-off/empty (no PRESENT flag, zero
    // length, zero required bytes). The real impl copies the source header bytes.
    out_required.* = 0;
    i = 0;
    while (i < count) : (i += 1) {
        sp[i] = .{
            .struct_size = @sizeOf(api.ColumnLabelSpan),
            .abi_version = abi_version,
            .column = p[i],
            .flags = 0,
            .offset = 0,
            .len = 0,
            .reserved = .{ 0, 0 },
        };
    }
    return .ok;
}

pub fn nullSentinelCopy(
    doc: *Document,
    column: u32,
    buf: ?[*]u8,
    buf_capacity: usize,
    out_required: *usize,
) api.ColumnResult {
    _ = buf;
    _ = buf_capacity;
    _ = out_required;
    if (column >= doc.column_count) return .no_column;
    return .no_value; // RED SEED: no sentinel stored (outputs untouched).
}

pub fn conflictExampleCopy(
    doc: *Document,
    column: u32,
    buf: ?[*]u8,
    buf_capacity: usize,
    out_required: *usize,
) api.ColumnResult {
    _ = buf;
    _ = buf_capacity;
    _ = out_required;
    if (column >= doc.column_count) return .no_column;
    return .no_value; // RED SEED: no conflict example stored (outputs untouched).
}
