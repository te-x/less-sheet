//! Sparse column metadata, bounded lazy CSV inference, and the additive
//! caller-owned column ABI from ARCH-column-config.

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");
const matcher = @import("matcher.zig");
const nav = @import("nav.zig");
const state_mod = @import("column_state.zig");

const Document = base.Document;
const State = state_mod.State;
const abi_version = api.column_metadata_abi_version;

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

fn typeOf(kind: api.ColumnTypeKind) api.ColumnType {
    var ty = unknownType();
    ty.kind = kind;
    return ty;
}

/// Internal integer candidates carry exact numeric parameters so a later
/// integer+decimal widening can compute the decimal descriptor correctly.
/// Those parameters are never exposed for a non-decimal ABI kind.
fn publicType(ty: api.ColumnType) api.ColumnType {
    if (ty.kind == .decimal or ty.kind == .datetime) return ty;
    var result = ty;
    result.decimal_precision = api.column_type_precision_unspecified;
    result.decimal_scale = api.column_type_scale_unspecified;
    result.datetime_semantics = .none;
    result.datetime_fraction_digits = api.column_type_fraction_digits_unspecified;
    return result;
}

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

fn snapshot(state: *const State) api.ColumnMetadata {
    const u = unknownType();
    const declared = if (state.declared) |ty| publicType(ty) else u;
    const inferred = if (state.inferred) |ty| publicType(ty) else u;
    const override_ty = state.override_type orelse u;
    const proposal = if (state.proposal) |ty| publicType(ty) else u;
    const effective, const effective_source: api.ColumnTypeSource = if (state.override_type) |ty|
        .{ ty, .override }
    else if (state.inferred_published and state.inferred != null)
        .{ inferred, .inferred }
    else if (state.declared != null)
        .{ declared, .declared }
    else
        .{ u, .none };

    var presence: u32 = 0;
    if (state.declared != null) presence |= api.column_has_declared;
    if (state.inferred != null) presence |= api.column_has_inferred;
    if (state.override_type != null) presence |= api.column_has_override;
    if (state.proposal != null) presence |= api.column_has_proposal;
    if (state.has_sentinel) presence |= api.column_has_null_sentinel;
    if (state.conflict_example_len > 0) presence |= api.column_has_conflict_example;

    return .{
        .struct_size = @sizeOf(api.ColumnMetadata),
        .abi_version = abi_version,
        .column = state.column,
        .presence_flags = presence,
        .generation = state.generation,
        .declared = declared,
        .inferred = inferred,
        .override = override_ty,
        .effective = effective,
        .proposal = proposal,
        .effective_source = effective_source,
        .inference_state = state.inference_state,
        .confidence = state.confidence,
        .null_policy = if (state.has_sentinel) .sentinel else .none,
        .conflict_state = state.conflict_state,
        .null_sentinel_bytes = @intCast(state.sentinel_len),
        .evidence_count = state.evidence_count,
        .sampled_row_count = state.sampled_row_count,
        .sampled_decoded_bytes = state.sampled_decoded_bytes,
        .empty_count = state.empty_count,
        .null_count = state.null_count,
        .conflict_count = state.conflict_count,
        .conflict_source_row = state.conflict_source_row,
        .conflict_example_bytes = @intCast(state.conflict_example_len),
        .conflict_example_truncated = @intFromBool(state.conflict_example_truncated),
        .reserved = .{ 0, 0, 0, 0 },
    };
}

fn validOverrideType(t: api.ColumnType) bool {
    if (t.struct_size != @sizeOf(api.ColumnType) or t.abi_version != abi_version) return false;
    if (t.flags != 0 or t.reserved != 0) return false;
    if (t.decimal_precision != api.column_type_precision_unspecified or
        t.decimal_scale != api.column_type_scale_unspecified or
        t.datetime_fraction_digits != api.column_type_fraction_digits_unspecified) return false;
    return switch (t.kind) {
        .text, .boolean, .integer, .decimal, .date => t.datetime_semantics == .none,
        .datetime => t.datetime_semantics == .naive or t.datetime_semantics == .zoned,
        .unknown, .unsupported => false,
    };
}

fn idsValid(doc: *const Document, ids: [*]const u32, count: u32) bool {
    var i: u32 = 0;
    while (i < count) : (i += 1) if (ids[i] >= doc.column_count) return false;
    return true;
}

fn nextCounter(value: *u64) u64 {
    if (value.* != std.math.maxInt(u64)) value.* += 1;
    return value.*;
}

fn commitOne(doc: *Document, state: *State) void {
    state.generation = nextCounter(&doc.column_store.metadata_generation);
}

fn getOrCreateLocked(doc: *Document, column: u32) error{OutOfMemory}!*State {
    if (doc.column_store.find(column)) |state| return state;
    try doc.column_store.states.ensureUnusedCapacity(doc.gpa, 1);
    try doc.column_store.state_index.ensureUnusedCapacity(doc.gpa, 1);
    const index = doc.column_store.states.items.len;
    doc.column_store.states.appendAssumeCapacity(State.init(column));
    doc.column_store.state_index.putAssumeCapacity(column, index);
    return &doc.column_store.states.items[index];
}

fn containsDesired(doc: *const Document, column: u32) bool {
    for (doc.column_store.desired.items) |id| if (id == column) return true;
    return false;
}

fn restartHeadLocked(doc: *Document) void {
    doc.column_head_pos = doc.data_start;
    doc.column_head_row = 0;
    doc.column_head_target = @min(api.column_inference_head_max_rows, if (doc.complete) doc.total_rows else doc.frontier_rows);
    doc.column_head_exact = doc.complete and doc.column_head_target == doc.total_rows;
    doc.column_head_active = true;
    doc.column_parsed = false;
    doc.column_commit_index = 0;
    doc.column_work_generation +%= 1;
    doc.column_store.job_state = .queued;
    doc.column_store.completed_column_count = 0;
    doc.column_store.source_bytes_scanned = 0;
    doc.column_store.source_bytes_budget = @min(api.open_head_max_bytes, doc.file_size);
    doc.column_store.rows_scanned = 0;
    doc.column_store.rows_budget = doc.column_head_target;
    doc.column_store.progress = 0.0;
}

fn sameDesired(doc: *const Document, ids: []const u32) bool {
    return std.mem.eql(u32, doc.column_store.desired.items, ids);
}

fn lessU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

pub fn inferenceRequest(doc: *Document, ids: ?[*]const u32, count: u32) api.ColumnResult {
    if (count == 0 or count > api.column_batch_max) return .invalid_argument;
    const p = ids orelse return .invalid_argument;
    if (!idsValid(doc, p, count)) return .no_column;

    const sorted = doc.gpa.alloc(u32, count) catch return .out_of_memory;
    defer doc.gpa.free(sorted);
    @memcpy(sorted, p[0..count]);
    std.mem.sort(u32, sorted, {}, lessU32);
    var unique_len: usize = 0;
    for (sorted) |id| {
        if (unique_len == 0 or sorted[unique_len - 1] != id) {
            sorted[unique_len] = id;
            unique_len += 1;
        }
    }
    const normalized = sorted[0..unique_len];

    doc.lock();
    defer doc.unlock();
    if (sameDesired(doc, normalized)) return .ok;

    var missing: usize = 0;
    for (normalized) |id| if (doc.column_store.find(id) == null) {
        missing += 1;
    };
    doc.column_store.desired.ensureTotalCapacity(doc.gpa, normalized.len) catch return .out_of_memory;
    doc.column_store.states.ensureUnusedCapacity(doc.gpa, missing) catch return .out_of_memory;
    doc.column_store.state_index.ensureUnusedCapacity(doc.gpa, @intCast(missing)) catch return .out_of_memory;
    doc.column_window_events.ensureTotalCapacity(doc.gpa, api.window_max_rows) catch return .out_of_memory;
    doc.column_changed_ids.ensureTotalCapacity(doc.gpa, normalized.len) catch return .out_of_memory;

    doc.column_store.desired.clearRetainingCapacity();
    doc.column_store.desired.appendSliceAssumeCapacity(normalized);
    var any_metadata = false;
    for (normalized) |id| {
        const state = doc.column_store.find(id) orelse blk: {
            const index = doc.column_store.states.items.len;
            doc.column_store.states.appendAssumeCapacity(State.init(id));
            doc.column_store.state_index.putAssumeCapacity(id, index);
            break :blk &doc.column_store.states.items[index];
        };
        if (!state.head_sampled) {
            state.inference_state = .queued;
            any_metadata = true;
        }
    }
    if (any_metadata) {
        const generation = nextCounter(&doc.column_store.metadata_generation);
        for (normalized) |id| {
            const state = doc.column_store.find(id).?;
            if (!state.head_sampled) state.generation = generation;
        }
    }
    _ = nextCounter(&doc.column_store.request_generation);
    restartHeadLocked(doc);
    doc.column_window_events.clearRetainingCapacity();
    doc.column_event_index = 0;
    doc.column_event_decoded_bytes = 0;
    doc.wakeWorker();
    drainDegradedLocked(doc);
    return .ok;
}

pub fn inferenceCancel(doc: *Document) void {
    doc.lock();
    defer doc.unlock();
    const had_request = doc.column_store.desired.items.len > 0;
    var changed = false;
    for (doc.column_store.desired.items) |id| {
        const state = doc.column_store.find(id).?;
        if (state.evidence_count == 0 and !state.inferred_published) {
            if (state.inference_state != .unrequested) changed = true;
        } else if (!state.inferred_published) {
            if (state.inference_state != .provisional) changed = true;
        }
    }
    if (changed) {
        const generation = nextCounter(&doc.column_store.metadata_generation);
        for (doc.column_store.desired.items) |id| {
            const state = doc.column_store.find(id).?;
            if (state.evidence_count == 0 and !state.inferred_published and state.inference_state != .unrequested) {
                state.inference_state = .unrequested;
                state.generation = generation;
            } else if (state.evidence_count > 0 and !state.inferred_published and state.inference_state != .provisional) {
                state.inference_state = .provisional;
                state.generation = generation;
            }
        }
    }
    doc.column_store.desired.clearRetainingCapacity();
    doc.column_work_generation +%= 1;
    doc.column_parsed = false;
    doc.column_head_active = false;
    doc.column_window_events.clearRetainingCapacity();
    doc.column_event_index = 0;
    if (had_request) _ = nextCounter(&doc.column_store.request_generation);
    doc.column_store.job_state = .cancelled;
}

/// Publish a replacement, bounded materialized-window event to the worker.
/// Only stable source identities/positions cross lanes; no window byte borrow
/// survives this call. The queue capacity was reserved by inferenceRequest.
pub fn windowMaterialized(doc: *Document) void {
    doc.lock();
    defer doc.unlock();
    if (doc.column_store.desired.items.len == 0) return;
    const count = @min(doc.win_source.items.len, @min(doc.win_pos.items.len, doc.win_oversized.items.len));
    doc.column_window_events.clearRetainingCapacity();
    var i: usize = 0;
    while (i < count and i < api.window_max_rows) : (i += 1) {
        doc.column_window_events.appendAssumeCapacity(.{
            .row = doc.win_source.items[i],
            .pos = doc.win_pos.items[i],
            .oversized = doc.win_oversized.items[i],
        });
    }
    doc.column_event_index = 0;
    doc.column_event_decoded_bytes = 0;
    doc.column_window_generation +%= 1;
    if (doc.column_parsed and doc.column_parsed_kind == .window) doc.column_parsed = false;
    if (doc.column_window_events.items.len > 0) {
        doc.column_store.job_state = .queued;
        doc.column_store.completed_column_count = 0;
        doc.column_store.source_bytes_scanned = 0;
        doc.column_store.source_bytes_budget = @as(u64, @intCast(doc.column_window_events.items.len)) *|
            api.window_row_scan_max_bytes;
        doc.column_store.rows_scanned = 0;
        doc.column_store.rows_budget = doc.column_window_events.items.len;
        doc.column_store.progress = 0.0;
        doc.wakeWorker();
        drainDegradedLocked(doc);
    }
}

pub fn overrideSet(doc: *Document, column: u32, ty: *const api.ColumnType) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    if (!validOverrideType(ty.*)) return .invalid_argument;
    doc.lock();
    defer doc.unlock();
    const state = getOrCreateLocked(doc, column) catch return .out_of_memory;
    state.override_type = ty.*;
    state.resetConflicts();
    validateSamplesAgainstOverride(state, ty.*);
    commitOne(doc, state);
    return .ok;
}

pub fn overrideClear(doc: *Document, column: u32) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    doc.lock();
    defer doc.unlock();
    const state = doc.column_store.find(column) orelse return .ok;
    if (state.override_type == null) return .ok;
    state.override_type = null;
    state.resetConflicts();
    commitOne(doc, state);
    return .ok;
}

pub fn nullSentinelSet(doc: *Document, column: u32, bytes: ?[*]const u8, len: usize) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    if (len > api.column_sentinel_max_bytes) return .invalid_argument;
    const slice: []const u8 = if (len == 0) &.{} else blk: {
        const p = bytes orelse return .invalid_argument;
        break :blk p[0..len];
    };
    if (!std.unicode.utf8ValidateSlice(slice)) return .invalid_argument;

    doc.lock();
    defer doc.unlock();
    const state = getOrCreateLocked(doc, column) catch return .out_of_memory;
    if (state.has_sentinel and std.mem.eql(u8, state.sentinel[0..state.sentinel_len], slice)) return .ok;
    state.has_sentinel = true;
    state.sentinel_len = len;
    @memcpy(state.sentinel[0..len], slice);
    state.resetEvidence();
    if (containsDesired(doc, column)) {
        state.inference_state = .queued;
        restartHeadLocked(doc);
        doc.wakeWorker();
        drainDegradedLocked(doc);
    }
    commitOne(doc, state);
    return .ok;
}

pub fn nullSentinelClear(doc: *Document, column: u32) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    doc.lock();
    defer doc.unlock();
    const state = doc.column_store.find(column) orelse return .ok;
    if (!state.has_sentinel) return .ok;
    state.has_sentinel = false;
    state.sentinel_len = 0;
    state.resetEvidence();
    if (containsDesired(doc, column)) {
        state.inference_state = .queued;
        restartHeadLocked(doc);
        doc.wakeWorker();
        drainDegradedLocked(doc);
    }
    commitOne(doc, state);
    return .ok;
}

pub fn acceptProposal(doc: *Document, column: u32) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    doc.lock();
    defer doc.unlock();
    const state = doc.column_store.find(column) orelse return .no_proposal;
    const proposal = state.proposal orelse return .no_proposal;
    state.inferred = proposal;
    state.inferred_published = true;
    state.inference_state = .published;
    if (state.confidence == .none or state.confidence == .low) state.confidence = .bounded;
    state.resetConflicts();
    commitOne(doc, state);
    return .ok;
}

fn trimAscii(raw: []const u8) []const u8 {
    var lo: usize = 0;
    var hi = raw.len;
    while (lo < hi and (raw[lo] == 0x20 or (raw[lo] >= 0x09 and raw[lo] <= 0x0d))) lo += 1;
    while (hi > lo and (raw[hi - 1] == 0x20 or (raw[hi - 1] >= 0x09 and raw[hi - 1] <= 0x0d))) hi -= 1;
    return raw[lo..hi];
}

fn eqlAsciiIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lx = if (x >= 'A' and x <= 'Z') x + 32 else x;
        if (lx != y) return false;
    }
    return true;
}

fn leap(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn digits(raw: []const u8, start: usize, count: usize) ?u32 {
    var value: u32 = 0;
    for (raw[start .. start + count]) |ch| {
        if (ch < '0' or ch > '9') return null;
        value = value * 10 + ch - '0';
    }
    return value;
}

fn validDate(raw: []const u8) bool {
    if (raw.len != 10 or raw[4] != '-' or raw[7] != '-') return false;
    const year = digits(raw, 0, 4) orelse return false;
    const month = digits(raw, 5, 2) orelse return false;
    const day = digits(raw, 8, 2) orelse return false;
    if (month < 1 or month > 12 or day < 1) return false;
    const mdays = [_]u32{ 31, if (leap(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day <= mdays[month - 1];
}

fn datetimeType(raw: []const u8) ?api.ColumnType {
    if (raw.len < 19 or raw[10] != 'T' or raw[13] != ':' or raw[16] != ':' or !validDate(raw[0..10])) return null;
    const hour = digits(raw, 11, 2) orelse return null;
    const minute = digits(raw, 14, 2) orelse return null;
    const second = digits(raw, 17, 2) orelse return null;
    if (hour > 23 or minute > 59 or second > 59) return null;
    var i: usize = 19;
    var fraction: u32 = 0;
    if (i < raw.len and raw[i] == '.') {
        i += 1;
        const start = i;
        while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') i += 1;
        fraction = @intCast(i - start);
        if (fraction == 0 or fraction > 9) return null;
    }
    var semantics: api.ColumnDatetimeSemantics = .naive;
    if (i < raw.len) {
        semantics = .zoned;
        if (raw[i] == 'Z') {
            i += 1;
        } else {
            if ((raw[i] != '+' and raw[i] != '-') or i + 6 != raw.len or raw[i + 3] != ':') return null;
            const oh = digits(raw, i + 1, 2) orelse return null;
            const om = digits(raw, i + 4, 2) orelse return null;
            if (oh > 23 or om > 59) return null;
            i += 6;
        }
    }
    if (i != raw.len) return null;
    var ty = typeOf(.datetime);
    ty.datetime_semantics = semantics;
    ty.datetime_fraction_digits = fraction;
    return ty;
}

fn decimalType(raw: []const u8) api.ColumnType {
    var ty = typeOf(.decimal);
    const dec = matcher.parseDecimal(raw);
    const s = trimAscii(raw);
    var exponent_saturated = false;
    if (std.mem.indexOfAny(u8, s, "eE")) |at| {
        var i = at + 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var magnitude: u64 = 0;
        while (i < s.len) : (i += 1) {
            const digit: u64 = s[i] - '0';
            if (magnitude > (@as(u64, std.math.maxInt(i64)) - digit) / 10) {
                exponent_saturated = true;
                break;
            }
            magnitude = magnitude * 10 + digit;
        }
    }
    ty.decimal_precision = if (exponent_saturated) std.math.maxInt(u64) - 1 else if (dec.zero) 1 else @intCast(dec.sig_len);
    var scale = @as(i64, @intCast(if (dec.zero) 1 else dec.sig_len)) -| 1 -| dec.msd_pos;
    if (scale == std.math.minInt(i64)) scale = std.math.minInt(i64) + 1;
    ty.decimal_scale = scale;
    return ty;
}

fn integerType(raw: []const u8) api.ColumnType {
    var ty = decimalType(raw);
    ty.kind = .integer;
    return ty;
}

fn classify(raw: []const u8) api.ColumnType {
    const s = trimAscii(raw);
    if (eqlAsciiIgnoreCase(s, "true") or eqlAsciiIgnoreCase(s, "false")) return typeOf(.boolean);
    if (matcher.isNumeric(raw)) {
        if (std.mem.indexOfAny(u8, s, ".eE") != null) return decimalType(raw);
        return integerType(raw);
    }
    if (validDate(raw)) return typeOf(.date);
    if (datetimeType(raw)) |ty| return ty;
    return typeOf(.text);
}

fn mergeTypes(a: api.ColumnType, b: api.ColumnType) api.ColumnType {
    if (a.kind == b.kind) {
        var result = a;
        if (a.kind == .decimal or a.kind == .integer) {
            result.decimal_scale = @max(a.decimal_scale, b.decimal_scale);
            const ai = if (a.decimal_scale >= 0)
                a.decimal_precision -| @as(u64, @intCast(a.decimal_scale))
            else
                a.decimal_precision +| @as(u64, @intCast(-a.decimal_scale));
            const bi = if (b.decimal_scale >= 0)
                b.decimal_precision -| @as(u64, @intCast(b.decimal_scale))
            else
                b.decimal_precision +| @as(u64, @intCast(-b.decimal_scale));
            const integer_capacity = @max(ai, bi);
            const common_precision = if (result.decimal_scale >= 0)
                integer_capacity +| @as(u64, @intCast(result.decimal_scale))
            else
                integer_capacity -| @as(u64, @intCast(-result.decimal_scale));
            result.decimal_precision = @min(common_precision, std.math.maxInt(u64) - 1);
        } else if (a.kind == .datetime) {
            if (a.datetime_semantics != b.datetime_semantics) return typeOf(.text);
            result.datetime_fraction_digits = @max(a.datetime_fraction_digits, b.datetime_fraction_digits);
        }
        return result;
    }
    if ((a.kind == .integer and b.kind == .decimal) or (a.kind == .decimal and b.kind == .integer)) {
        var da = a;
        var db = b;
        da.kind = .decimal;
        db.kind = .decimal;
        return mergeTypes(da, db);
    }
    return typeOf(.text);
}

fn compatible(published: api.ColumnType, observed: api.ColumnType) bool {
    return switch (published.kind) {
        .unknown, .unsupported, .text => true,
        .boolean => observed.kind == .boolean,
        .integer => observed.kind == .integer,
        .decimal => blk: {
            if (observed.kind != .integer and observed.kind != .decimal) break :blk false;
            if (published.decimal_precision == api.column_type_precision_unspecified and
                published.decimal_scale == api.column_type_scale_unspecified) break :blk true;
            const published_integer = if (published.decimal_scale >= 0)
                published.decimal_precision -| @as(u64, @intCast(published.decimal_scale))
            else
                published.decimal_precision +| @as(u64, @intCast(-published.decimal_scale));
            const observed_integer = if (observed.decimal_scale >= 0)
                observed.decimal_precision -| @as(u64, @intCast(observed.decimal_scale))
            else
                observed.decimal_precision +| @as(u64, @intCast(-observed.decimal_scale));
            break :blk observed.decimal_scale <= published.decimal_scale and observed_integer <= published_integer;
        },
        .date => observed.kind == .date,
        .datetime => observed.kind == .datetime and
            observed.datetime_semantics == published.datetime_semantics and
            observed.datetime_fraction_digits <= published.datetime_fraction_digits,
    };
}

fn replacementFor(published: api.ColumnType, observed: api.ColumnType) api.ColumnType {
    if (published.kind == .integer and observed.kind == .decimal) return observed;
    if (published.kind == .decimal and (observed.kind == .integer or observed.kind == .decimal)) {
        var widened = observed;
        widened.kind = .decimal;
        return widened;
    }
    return observed;
}

fn conflictBucket(ty: api.ColumnType) usize {
    if (ty.kind == .datetime and ty.datetime_semantics == .zoned) return 8;
    return @intFromEnum(ty.kind);
}

fn recordSample(state: *State, observed: api.ColumnType, raw: []const u8, row: u64) void {
    const bucket = &state.samples[conflictBucket(observed)];
    bucket.ty = if (bucket.ty) |candidate| mergeTypes(candidate, observed) else observed;
    bucket.count +|= 1;
    if (bucket.source_row == api.no_row) {
        bucket.source_row = row;
        const n = @min(raw.len, api.column_conflict_example_max_bytes);
        var cut = n;
        while (cut > 0 and !std.unicode.utf8ValidateSlice(raw[0..cut])) cut -= 1;
        @memcpy(bucket.example[0..cut], raw[0..cut]);
        bucket.example_len = cut;
        bucket.example_truncated = cut < raw.len;
    }
}

fn validateSamplesAgainstOverride(state: *State, override_ty: api.ColumnType) void {
    var first: ?*const state_mod.SampleBucket = null;
    for (&state.samples) |*bucket| {
        const sampled_ty = bucket.ty orelse continue;
        if (compatible(override_ty, sampled_ty)) continue;
        state.conflict_count +|= bucket.count;
        state.conflict_state = .observed;
        if (first == null or bucket.source_row < first.?.source_row) first = bucket;
    }
    if (first) |bucket| {
        state.conflict_source_row = bucket.source_row;
        @memcpy(state.conflict_example[0..bucket.example_len], bucket.example[0..bucket.example_len]);
        state.conflict_example_len = bucket.example_len;
        state.conflict_example_truncated = bucket.example_truncated;
    }
}

fn recordConflict(state: *State, published: api.ColumnType, observed: api.ColumnType, raw: []const u8, row: u64) void {
    state.conflict_count +|= 1;
    if (state.conflict_state == .none) state.conflict_state = .observed;
    if (state.conflict_source_row == api.no_row) {
        state.conflict_source_row = row;
        const n = @min(raw.len, api.column_conflict_example_max_bytes);
        var cut = n;
        while (cut > 0 and !std.unicode.utf8ValidateSlice(raw[0..cut])) cut -= 1;
        @memcpy(state.conflict_example[0..cut], raw[0..cut]);
        state.conflict_example_len = cut;
        state.conflict_example_truncated = cut < raw.len;
    }
    const replacement = replacementFor(published, observed);
    const bucket = &state.conflict_buckets[conflictBucket(replacement)];
    bucket.ty = if (bucket.ty) |candidate| mergeTypes(candidate, replacement) else replacement;
    bucket.count +|= 1;
    if (state.override_type == null and bucket.count >= 8) {
        state.proposal = mergeTypes(published, bucket.ty.?);
        state.conflict_state = .proposed;
    }
}

const ObserveParts = struct { inference: bool, conflict: bool };

fn observeClassified(state: *State, observed: api.ColumnType, raw: []const u8, row: u64, parts: ObserveParts) void {
    if (!parts.inference and !parts.conflict) return;
    recordSample(state, observed, raw, row);
    if (state.override_type) |override_ty| {
        if (parts.conflict and !compatible(override_ty, observed)) recordConflict(state, override_ty, observed, raw, row);
    }
    if (state.inferred_published) {
        const inferred = state.inferred.?;
        if (compatible(inferred, observed)) {
            if (parts.inference) state.evidence_count +|= 1;
        } else if (parts.conflict and state.override_type == null) {
            recordConflict(state, inferred, observed, raw, row);
        }
        return;
    }

    if (!parts.inference) return;
    state.inferred = if (state.inferred) |candidate| mergeTypes(candidate, observed) else observed;
    state.evidence_count +|= 1;
    if (state.evidence_count >= 8) {
        state.inferred_published = true;
        state.inference_state = .published;
        state.confidence = .bounded;
    }
}

fn observe(state: *State, raw: []const u8, row: u64) void {
    if (state.has_sentinel and std.mem.eql(u8, state.sentinel[0..state.sentinel_len], raw)) {
        state.null_count +|= 1;
        return;
    }
    if (raw.len == 0) {
        state.empty_count +|= 1;
        return;
    }
    const observed = classify(raw);
    var parts: ObserveParts = .{
        .inference = !state.publication_overflow_rows.contains(row),
        .conflict = false,
    };
    if (state.inferred_published and !compatible(state.inferred.?, observed)) parts.inference = false;
    const effective = state.override_type orelse if (state.inferred_published) state.inferred.? else null;
    if (effective) |published| {
        if (!compatible(published, observed)) {
            const replacement = replacementFor(published, observed);
            parts.conflict = !state.conflict_buckets[conflictBucket(replacement)].overflow_rows.contains(row);
        }
    }
    observeClassified(state, observed, raw, row, parts);
}

/// Preserve exact eight-row decisions after the general exact-range store is
/// full. Each unresolved publication/replacement bucket retains precisely the
/// identities it can still consume; duplicates are rejected and storage stops
/// growing once that decision has its eight-row proof.
fn observeUntracked(state: *State, raw: []const u8, row: u64) bool {
    if ((state.has_sentinel and std.mem.eql(u8, state.sentinel[0..state.sentinel_len], raw)) or raw.len == 0) return false;
    const observed = classify(raw);
    var parts: ObserveParts = .{ .inference = false, .conflict = false };

    if (!state.inferred_published or compatible(state.inferred.?, observed))
        parts.inference = state.publication_overflow_rows.admit(row);

    const effective = state.override_type orelse if (state.inferred_published) state.inferred.? else null;
    if (effective) |published| {
        if (!compatible(published, observed)) {
            const replacement = replacementFor(published, observed);
            parts.conflict = state.conflict_buckets[conflictBucket(replacement)].overflow_rows.admit(row);
        }
    }
    if (!parts.inference and !parts.conflict) return false;
    observeClassified(state, observed, raw, row, parts);
    return true;
}

fn finishHeadLocked(doc: *Document) void {
    var changed: usize = 0;
    for (doc.column_store.desired.items) |id| if (!doc.column_store.find(id).?.head_sampled) {
        changed += 1;
    };
    const generation = if (changed > 0) nextCounter(&doc.column_store.metadata_generation) else 0;
    for (doc.column_store.desired.items) |id| {
        const state = doc.column_store.find(id).?;
        if (state.head_sampled) continue;
        state.head_sampled = true;
        state.coverClassifiedPrefix(doc.column_head_row);
        const exhaustive = doc.column_head_exact and state.classified_prefix >= doc.total_rows;
        if (exhaustive) {
            state.confidence = .exhaustive;
            state.inference_state = .published;
            if (state.inferred != null) state.inferred_published = true;
        } else if (state.inferred_published) {
            state.inference_state = .published;
            state.confidence = .bounded;
        } else if (state.evidence_count > 0) {
            state.inference_state = .provisional;
            state.confidence = .low;
        } else {
            state.inference_state = .provisional;
            state.confidence = .none;
        }
        state.generation = generation;
    }
    doc.column_head_active = false;
}

fn settleStateLocked(doc: *const Document, state: *State) bool {
    const old_state = state.inference_state;
    const old_confidence = state.confidence;
    const old_published = state.inferred_published;
    if (doc.complete and state.classified_prefix >= doc.total_rows) {
        state.inference_state = .published;
        state.confidence = .exhaustive;
        if (state.inferred != null) state.inferred_published = true;
    } else if (state.inferred_published) {
        state.inference_state = .published;
        if (state.confidence == .none or state.confidence == .low) state.confidence = .bounded;
    } else if (state.evidence_count > 0) {
        state.inference_state = .provisional;
        state.confidence = .low;
    } else {
        state.inference_state = .provisional;
        state.confidence = .none;
    }
    return old_state != state.inference_state or old_confidence != state.confidence or old_published != state.inferred_published;
}

/// Index completion may validate an already-classified exact prefix, but it
/// never queues or performs additional column scanning.
pub fn sourceCompletedLocked(doc: *Document) void {
    if (!doc.complete or doc.column_store.job_state != .done) return;
    doc.column_changed_ids.clearRetainingCapacity();
    for (doc.column_store.desired.items) |id| {
        const state = doc.column_store.find(id).?;
        if (state.head_sampled and settleStateLocked(doc, state)) doc.column_changed_ids.appendAssumeCapacity(id);
    }
    if (doc.column_changed_ids.items.len > 0) {
        const generation = nextCounter(&doc.column_store.metadata_generation);
        for (doc.column_changed_ids.items) |id| doc.column_store.find(id).?.generation = generation;
    }
}

fn completeWorkLocked(doc: *Document) void {
    if (doc.column_head_active or doc.column_event_index < doc.column_window_events.items.len) {
        doc.column_store.job_state = .queued;
        return;
    }
    doc.column_changed_ids.clearRetainingCapacity();
    for (doc.column_store.desired.items) |id| {
        const state = doc.column_store.find(id).?;
        if (settleStateLocked(doc, state)) doc.column_changed_ids.appendAssumeCapacity(id);
    }
    if (doc.column_changed_ids.items.len > 0) {
        const generation = nextCounter(&doc.column_store.metadata_generation);
        for (doc.column_changed_ids.items) |id| doc.column_store.find(id).?.generation = generation;
    }
    doc.column_store.completed_column_count = @intCast(doc.column_store.desired.items.len);
    doc.column_store.progress = 1.0;
    doc.column_store.job_state = .done;
}

fn updateActiveProgress(doc: *Document, kind: base.ColumnSampleKind, fraction: f64) void {
    const bounded = @min(@max(fraction, 0.0), 0.999999);
    switch (kind) {
        .head => {
            if (doc.column_head_target == 0) return;
            doc.column_store.progress = @min(0.999999, (@as(f64, @floatFromInt(doc.column_head_row)) + bounded) /
                @as(f64, @floatFromInt(doc.column_head_target)));
        },
        .window => {
            const count = doc.column_window_events.items.len;
            if (count == 0) return;
            doc.column_store.progress = @min(0.999999, (@as(f64, @floatFromInt(doc.column_event_index)) + bounded) /
                @as(f64, @floatFromInt(count)));
        },
    }
}

fn commitParsedLocked(doc: *Document) void {
    if (!doc.column_parsed) return;
    if (doc.column_parsed_request_gen != doc.column_store.request_generation or
        doc.column_parsed_work_gen != doc.column_work_generation or
        (doc.column_parsed_kind == .window and doc.column_parsed_window_gen != doc.column_window_generation))
    {
        doc.column_parsed = false;
        if (doc.column_store.job_state == .cancelled) return;
        completeWorkLocked(doc);
        return;
    }

    const start = doc.column_commit_index;
    doc.column_changed_ids.clearRetainingCapacity();
    var i = start;
    var chunk_bytes: u64 = 0;
    var event_exhausted = false;
    var out_of_memory = false;
    while (i < doc.column_worker_ids.items.len) : (i += 1) {
        const ref = doc.column_refs.items[i];
        if (doc.column_parsed_kind == .window and
            doc.column_event_decoded_bytes + ref.len > api.column_inference_window_max_bytes)
        {
            event_exhausted = true;
            break;
        }
        if (chunk_bytes > 0 and chunk_bytes + ref.len > api.column_inference_window_max_bytes) break;
        chunk_bytes +|= ref.len;
        if (doc.column_parsed_kind == .window) doc.column_event_decoded_bytes +|= ref.len;
        const state = doc.column_store.find(doc.column_worker_ids.items[i]) orelse continue;
        var threshold_only = false;
        if (doc.column_parsed_kind == .head) {
            if (state.head_sampled) continue;
        } else {
            if (doc.column_parsed_source_row < doc.column_head_target) continue;
            const coverage = state.coverRow(doc.gpa, doc.column_parsed_source_row) catch {
                out_of_memory = true;
                break;
            };
            if (coverage == .already) continue;
            threshold_only = coverage == .untracked;
        }
        if (!doc.column_parsed_oversized and !ref.truncated) {
            const raw = doc.column_buf.items[ref.start .. ref.start + ref.len];
            if (threshold_only) {
                if (!observeUntracked(state, raw, doc.column_parsed_source_row)) continue;
            } else observe(state, raw, doc.column_parsed_source_row);
            state.sampled_decoded_bytes +|= ref.len;
        }
        state.inference_state = .sampling;
        state.sampled_row_count +|= 1;
        doc.column_changed_ids.appendAssumeCapacity(state.column);
    }

    if (out_of_memory) {
        doc.column_parsed = false;
        doc.column_store.job_state = .cancelled;
        return;
    }

    if (doc.column_changed_ids.items.len > 0) {
        const generation = nextCounter(&doc.column_store.metadata_generation);
        for (doc.column_changed_ids.items) |id| doc.column_store.find(id).?.generation = generation;
    }
    doc.column_commit_index = i;
    updateActiveProgress(doc, doc.column_parsed_kind, @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(doc.column_worker_ids.items.len)));
    if (event_exhausted) {
        doc.column_event_index = doc.column_window_events.items.len;
        doc.column_parsed = false;
        completeWorkLocked(doc);
        return;
    }
    if (i < doc.column_worker_ids.items.len) {
        doc.column_store.job_state = .queued;
        return;
    }

    doc.column_parsed = false;
    doc.column_commit_index = 0;
    switch (doc.column_parsed_kind) {
        .head => {
            doc.column_head_pos = doc.column_parsed_next_pos;
            doc.column_head_row += 1;
            doc.column_store.rows_scanned = doc.column_head_row;
            doc.column_store.source_bytes_scanned = doc.reader.physicalBytes(doc.source, doc.column_head_pos) -|
                doc.reader.physicalBytes(doc.source, doc.data_start);
            if (doc.column_head_row >= doc.column_head_target) finishHeadLocked(doc);
        },
        .window => {
            doc.column_event_index += 1;
            doc.column_store.rows_scanned = doc.column_event_index;
        },
    }
    updateActiveProgress(doc, doc.column_parsed_kind, 0.0);
    completeWorkLocked(doc);
}

/// Run one inference row/commit chunk. The caller enters and leaves with the
/// document mutex held. Parsing happens lock-free against immutable Reader
/// input; generation checks discard cancelled/replaced work before commit.
pub fn workerRunLocked(doc: *Document) void {
    if (doc.column_store.job_state != .queued) return;
    if (doc.stop or doc.stop_atomic.load(.monotonic)) {
        if (doc.column_scanner) |*scanner| scanner.deinit();
        doc.column_scanner = null;
        doc.column_store.job_state = .cancelled;
        return;
    }
    doc.column_store.job_state = .running;
    if (doc.column_parsed) {
        commitParsedLocked(doc);
        return;
    }

    if (doc.column_scanner != null and
        (doc.column_parsed_request_gen != doc.column_store.request_generation or
            doc.column_parsed_work_gen != doc.column_work_generation or
            (doc.column_parsed_kind == .window and doc.column_parsed_window_gen != doc.column_window_generation)))
    {
        doc.column_scanner.?.deinit();
        doc.column_scanner = null;
        doc.column_buf.clearRetainingCapacity();
        doc.column_refs.clearRetainingCapacity();
    }

    if (doc.column_head_active and doc.column_head_row >= doc.column_head_target) {
        finishHeadLocked(doc);
        completeWorkLocked(doc);
        return;
    }
    if (doc.column_head_active and
        doc.reader.bytesConsumed(doc.source, doc.column_head_pos) -|
            doc.reader.bytesConsumed(doc.source, doc.data_start) >= api.open_head_max_bytes)
    {
        doc.column_head_target = doc.column_head_row;
        finishHeadLocked(doc);
        completeWorkLocked(doc);
        return;
    }

    if (doc.column_scanner == null) {
        const kind: base.ColumnSampleKind = if (doc.column_head_active) .head else .window;
        if (kind == .window and doc.column_event_index >= doc.column_window_events.items.len) {
            completeWorkLocked(doc);
            return;
        }

        doc.column_worker_ids.clearRetainingCapacity();
        const wanted_count = if (kind == .head) blk: {
            var count: usize = 0;
            for (doc.column_store.desired.items) |id| {
                if (!doc.column_store.find(id).?.head_sampled) count += 1;
            }
            break :blk count;
        } else doc.column_store.desired.items.len;
        doc.column_worker_ids.ensureTotalCapacity(doc.gpa, wanted_count) catch {
            doc.column_store.job_state = .cancelled;
            return;
        };
        for (doc.column_store.desired.items) |id| {
            if (kind == .head and doc.column_store.find(id).?.head_sampled) continue;
            doc.column_worker_ids.appendAssumeCapacity(id);
        }
        if (doc.column_worker_ids.items.len == 0) {
            if (kind == .head) finishHeadLocked(doc) else doc.column_event_index = doc.column_window_events.items.len;
            completeWorkLocked(doc);
            return;
        }

        doc.column_refs.clearRetainingCapacity();
        doc.column_buf.clearRetainingCapacity();
        doc.column_refs.ensureTotalCapacity(doc.gpa, doc.column_worker_ids.items.len) catch {
            doc.column_store.job_state = .cancelled;
            return;
        };
        doc.column_changed_ids.ensureTotalCapacity(doc.gpa, doc.column_worker_ids.items.len) catch {
            doc.column_store.job_state = .cancelled;
            return;
        };

        const pos = if (kind == .head) doc.column_head_pos else doc.column_window_events.items[doc.column_event_index].pos;
        doc.column_parsed_kind = kind;
        doc.column_parsed_source_row = if (kind == .head) doc.column_head_row else doc.column_window_events.items[doc.column_event_index].row;
        doc.column_parsed_next_pos = pos;
        doc.column_parsed_oversized = kind == .window and doc.column_window_events.items[doc.column_event_index].oversized;
        doc.column_commit_index = 0;
        doc.column_parsed_request_gen = doc.column_store.request_generation;
        doc.column_parsed_work_gen = doc.column_work_generation;
        doc.column_parsed_window_gen = doc.column_window_generation;
        doc.column_scan_start_pos = pos;
        doc.column_scan_accounted_bytes = 0;
        doc.column_parsed_source_bytes = 0;

        if (doc.column_parsed_oversized) {
            while (doc.column_refs.items.len < doc.column_worker_ids.items.len)
                doc.column_refs.appendAssumeCapacity(.{ .start = 0, .len = 0, .truncated = true });
            doc.column_parsed = true;
            commitParsedLocked(doc);
            return;
        }
        doc.column_scanner = doc.reader.selectedScanner(doc.source, pos);
    }

    const scanner = &doc.column_scanner.?;
    const head_source_before = if (doc.column_parsed_kind == .head)
        doc.reader.bytesConsumed(doc.source, doc.column_scan_start_pos) -|
            doc.reader.bytesConsumed(doc.source, doc.data_start)
    else
        0;
    const head_source_remaining = api.open_head_max_bytes -| head_source_before;
    const scan_row_budget = if (doc.column_parsed_kind == .head)
        @min(api.window_row_scan_max_bytes, head_source_remaining)
    else
        api.window_row_scan_max_bytes;
    const head_cap_boundary = doc.column_parsed_kind == .head and
        head_source_before +| scan_row_budget >= api.open_head_max_bytes;
    doc.unlock();
    const step = scanner.step(
        doc.column_worker_ids.items,
        api.cell_max_bytes,
        api.column_inference_window_max_bytes,
        scan_row_budget,
        &doc.column_buf,
        &doc.column_refs,
        doc.gpa,
    ) catch null;
    // Release a gzip inflater lane before reacquiring the document mutex.
    // Foreground jump/Find/filter work may already hold that mutex while it
    // waits for a lane, so reversing these two operations would deadlock.
    scanner.releaseLane();
    doc.lock();

    if (step == null) {
        doc.column_scanner.?.deinit();
        doc.column_scanner = null;
        doc.column_store.job_state = .cancelled;
        return;
    }
    const next_pos = switch (step.?) {
        .paused => |p| p,
        .done => |p| p,
        .oversized => |p| p,
    };
    const total_source_bytes = doc.reader.physicalBytes(doc.source, next_pos) -|
        doc.reader.physicalBytes(doc.source, doc.column_scan_start_pos);
    const source_delta = total_source_bytes -| doc.column_scan_accounted_bytes;
    doc.column_scan_accounted_bytes = total_source_bytes;
    doc.column_parsed_source_bytes = total_source_bytes;
    if (doc.column_parsed_kind == .window) {
        doc.column_store.source_bytes_scanned +|= source_delta;
    } else {
        doc.column_store.source_bytes_scanned = @min(api.open_head_max_bytes, doc.reader.bytesConsumed(doc.source, next_pos) -|
            doc.reader.bytesConsumed(doc.source, doc.data_start));
    }

    if (doc.stop or doc.stop_atomic.load(.monotonic) or
        doc.column_parsed_request_gen != doc.column_store.request_generation or
        doc.column_parsed_work_gen != doc.column_work_generation or
        (doc.column_parsed_kind == .window and doc.column_parsed_window_gen != doc.column_window_generation))
    {
        doc.column_scanner.?.deinit();
        doc.column_scanner = null;
        doc.column_buf.clearRetainingCapacity();
        doc.column_refs.clearRetainingCapacity();
        if (doc.column_store.job_state == .cancelled) return;
        completeWorkLocked(doc);
        return;
    }

    switch (step.?) {
        .paused => {
            const logical_work = doc.reader.logicalBytes(doc.source, next_pos) -|
                doc.reader.logicalBytes(doc.source, doc.column_scan_start_pos);
            updateActiveProgress(doc, doc.column_parsed_kind, @as(f64, @floatFromInt(@min(logical_work, api.window_row_scan_max_bytes))) /
                @as(f64, @floatFromInt(api.window_row_scan_max_bytes)));
            doc.column_store.job_state = .queued;
        },
        .done => {
            doc.column_scanner.?.deinit();
            doc.column_scanner = null;
            doc.column_parsed_next_pos = next_pos;
            doc.column_parsed = true;
            commitParsedLocked(doc);
        },
        .oversized => {
            doc.column_scanner.?.deinit();
            doc.column_scanner = null;
            doc.column_buf.clearRetainingCapacity();
            doc.column_refs.clearRetainingCapacity();
            if (head_cap_boundary) {
                doc.column_head_target = doc.column_head_row;
                finishHeadLocked(doc);
                completeWorkLocked(doc);
                return;
            }
            while (doc.column_refs.items.len < doc.column_worker_ids.items.len)
                doc.column_refs.appendAssumeCapacity(.{ .start = 0, .len = 0, .truncated = true });
            doc.column_parsed_oversized = true;
            if (doc.column_parsed_kind == .head) {
                const checkpoint = nav.bestCheckpoint(doc, doc.column_parsed_source_row +| 1);
                if (checkpoint.row == doc.column_parsed_source_row +| 1) {
                    doc.column_parsed_next_pos = checkpoint.pos;
                } else {
                    doc.column_head_target = doc.column_parsed_source_row +| 1;
                    doc.column_parsed_next_pos = next_pos;
                }
            } else doc.column_parsed_next_pos = next_pos;
            doc.column_parsed = true;
            commitParsedLocked(doc);
        },
    }
}

fn drainDegradedLocked(doc: *Document) void {
    if (doc.worker != null) return;
    while (doc.column_store.job_state == .queued) workerRunLocked(doc);
}

pub fn metadataPoll(doc: *Document, out: *api.ColumnInferenceStatus) api.ColumnResult {
    if (out.struct_size != @sizeOf(api.ColumnInferenceStatus) or out.abi_version != abi_version) return .invalid_argument;
    doc.lock();
    defer doc.unlock();
    out.* = .{
        .struct_size = @sizeOf(api.ColumnInferenceStatus),
        .abi_version = abi_version,
        .state = doc.column_store.job_state,
        .reserved0 = 0,
        .request_generation = doc.column_store.request_generation,
        .metadata_generation = doc.column_store.metadata_generation,
        .requested_column_count = @intCast(doc.column_store.desired.items.len),
        .completed_column_count = doc.column_store.completed_column_count,
        .source_bytes_scanned = doc.column_store.source_bytes_scanned,
        .source_bytes_budget = doc.column_store.source_bytes_budget,
        .rows_scanned = doc.column_store.rows_scanned,
        .rows_budget = doc.column_store.rows_budget,
        .progress = doc.column_store.progress,
        .reserved = .{ 0, 0, 0, 0 },
    };
    return .ok;
}

pub fn metadataGetMany(doc: *Document, ids: ?[*]const u32, count: u32, out: ?[*]api.ColumnMetadata, capacity: u32, out_gen: *u64) api.ColumnResult {
    if (count == 0) {
        doc.lock();
        defer doc.unlock();
        out_gen.* = doc.column_store.metadata_generation;
        return .ok;
    }
    if (count > api.column_batch_max or capacity > api.column_batch_max or capacity < count) return .invalid_argument;
    const p = ids orelse return .invalid_argument;
    const items = out orelse return .invalid_argument;
    var i: u32 = 0;
    while (i < count) : (i += 1) if (items[i].struct_size != @sizeOf(api.ColumnMetadata) or items[i].abi_version != abi_version) return .invalid_argument;
    if (!idsValid(doc, p, count)) return .no_column;

    doc.lock();
    defer doc.unlock();
    const generation = doc.column_store.metadata_generation;
    i = 0;
    while (i < count) : (i += 1) items[i] = if (doc.column_store.findConst(p[i])) |state| snapshot(state) else synthUnknown(p[i]);
    out_gen.* = generation;
    return .ok;
}

pub fn labelsCopyMany(doc: *Document, ids: ?[*]const u32, count: u32, spans: ?[*]api.ColumnLabelSpan, capacity: u32, arena: ?[*]u8, arena_capacity: usize, out_required: *usize) api.ColumnResult {
    if (count == 0) {
        out_required.* = 0;
        return .ok;
    }
    if (count > api.column_batch_max or capacity > api.column_batch_max or capacity < count) return .invalid_argument;
    const p = ids orelse return .invalid_argument;
    const sp = spans orelse return .invalid_argument;
    var i: u32 = 0;
    while (i < count) : (i += 1) if (sp[i].struct_size != @sizeOf(api.ColumnLabelSpan) or sp[i].abi_version != abi_version) return .invalid_argument;
    if (!idsValid(doc, p, count)) return .no_column;
    if (arena == null and arena_capacity != 0) return .invalid_argument;

    doc.lock();
    defer doc.unlock();
    var required: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        const ref = if (doc.has_header) doc.header_refs[p[i]] else base.CellRef{ .start = 0, .len = 0 };
        const present = doc.has_header and ref.len > 0;
        const len = if (present) ref.len else 0;
        if (std.math.maxInt(usize) - required < len) return .invalid_argument;
        sp[i] = .{
            .struct_size = @sizeOf(api.ColumnLabelSpan),
            .abi_version = abi_version,
            .column = p[i],
            .flags = (if (present) api.column_label_present else 0) | (if (doc.has_header and ref.truncated) api.column_label_truncated else 0),
            .offset = required,
            .len = len,
            .reserved = .{ 0, 0 },
        };
        required += len;
    }
    out_required.* = required;
    if (arena == null and arena_capacity == 0) return .ok;
    if (arena_capacity < required) return .buffer_too_small;
    const dst = arena.?;
    i = 0;
    while (i < count) : (i += 1) if (sp[i].len > 0) {
        const ref = doc.header_refs[p[i]];
        const off: usize = @intCast(sp[i].offset);
        const len: usize = @intCast(sp[i].len);
        @memcpy(dst[off .. off + len], doc.header_buf[ref.start .. ref.start + ref.len]);
    };
    return .ok;
}

fn copyValue(bytes: []const u8, buf: ?[*]u8, capacity: usize, out_required: *usize) api.ColumnResult {
    if (buf == null and capacity != 0) return .invalid_argument;
    out_required.* = bytes.len;
    if (buf == null and capacity == 0) return .ok;
    if (capacity < bytes.len) return .buffer_too_small;
    @memcpy(buf.?[0..bytes.len], bytes);
    return .ok;
}

pub fn nullSentinelCopy(doc: *Document, column: u32, buf: ?[*]u8, buf_capacity: usize, out_required: *usize) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    doc.lock();
    defer doc.unlock();
    const state = doc.column_store.findConst(column) orelse return .no_value;
    if (!state.has_sentinel) return .no_value;
    return copyValue(state.sentinel[0..state.sentinel_len], buf, buf_capacity, out_required);
}

pub fn conflictExampleCopy(doc: *Document, column: u32, buf: ?[*]u8, buf_capacity: usize, out_required: *usize) api.ColumnResult {
    if (column >= doc.column_count) return .no_column;
    doc.lock();
    defer doc.unlock();
    const state = doc.column_store.findConst(column) orelse return .no_value;
    if (state.conflict_example_len == 0) return .no_value;
    return copyValue(state.conflict_example[0..state.conflict_example_len], buf, buf_capacity, out_required);
}
