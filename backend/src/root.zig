//! less-sheet core — file access, parsing, and windowed row access.
//! Implements api/lesssheet.h exactly (see it and contracts/api.zig for the
//! full semantics: format neutrality, ownership & the eviction-safe borrow
//! rule, O(head) open cost, the scan frontier, threading lanes, dialect
//! grammar, sniffing, header rule). contracts/ and tests/ are planner-owned.
//!
//! Architecture (viewer-ui slice):
//!   - The source file is mmap'd read-only; nothing is copied. Cell text is
//!     re-lexed on demand into an owned window buffer (quote-collapsing means
//!     a cell is not always a contiguous file slice), so borrows survive the
//!     core's background scanning and are invalidated only by the next
//!     ls_window_set / ls_close (eviction-safe borrow rule).
//!   - A sparse row index (checkpoints: data-row -> content offset at record
//!     boundaries, one every `checkpoint_interval` rows) plus a monotone scan
//!     FRONTIER. ls_open indexes only the head region (<= head budget). One
//!     core-owned worker thread advances the frontier: to EOF under AUTO, or
//!     toward a jump target under MANUAL. window_set never advances it.
//!   - The worker is the SOLE writer of the frontier/index; a single pthread
//!     mutex guards the frontier + jump slot for the poll/control lane and for
//!     window_set's clamp/checkpoint lookup. The window buffer is touched only
//!     by the (caller-serialized) window lane, so cell reads need no lock.

const std = @import("std");
const api = @import("api");

const posix = std.posix;
const c = std.c;

/// Default allocator behind `ls_open` (thread-safe). `ls_close` returns all
/// document storage here.
const default_gpa = std.heap.smp_allocator;

// --- Tunables (implementation detail; not part of the ABI) -----------------

/// One index checkpoint every this many data rows (binary-searched by
/// window_set / jump). Bounds index memory to O(rows / interval) and the
/// re-lex distance of any window to O(interval + window).
const checkpoint_interval: u64 = 2048;
/// Records the worker lexes per commit cycle (== interval so each cycle lands
/// on a checkpoint boundary); it releases the mutex during the scan.
const sniff_byte_cap: usize = 256 * 1024;
const sniff_record_cap: u32 = 256;
const max_field_hist: usize = 512;
/// Background indexer madvise(DONTNEED) hygiene: after this many freshly
/// scanned bytes, drop the pages well behind the frontier so a multi-GB scan
/// keeps resident memory O(this), not O(file). Best-effort (errors ignored).
const madvise_release_chunk: u64 = 8 * 1024 * 1024;
const madvise_keepback: u64 = 2 * 1024 * 1024;

const head_budget: u64 = api.open_head_max_bytes;

// --- Small value types ------------------------------------------------------

/// A decoded cell: byte range into an owning buffer (window or header).
const CellRef = struct { start: usize, len: usize };

/// A sparse row-index entry: data row `row` begins at content offset `offset`.
const Checkpoint = struct { row: u64, offset: u64 };

/// Sniffer scoring for one (separator, quote) candidate pair.
const Score = struct {
    /// The quote byte actually opens >= 1 field in the sample. A quote that
    /// never appears must not beat the default just because ignoring the real
    /// quotes happens to make ragged field counts look more consistent.
    active: bool,
    /// The pair splits records into >1 field (beats single-field candidates).
    splits: bool,
    /// Fraction of sampled records matching the modal field count.
    consistency: f64,
    /// The modal field count.
    mode: u32,
};

fn betterThan(a: Score, b: Score) bool {
    if (a.active != b.active) return a.active;
    if (a.splits != b.splits) return a.splits;
    if (a.consistency != b.consistency) return a.consistency > b.consistency;
    return a.mode > b.mode;
}

const empty_str: api.Str = .{ .ptr = "", .len = 0 };

// --- The document -----------------------------------------------------------

const Document = struct {
    gpa: std.mem.Allocator,

    // File mapping (immutable after open). `mapping` is null for an empty file.
    mapping: ?[]align(std.heap.page_size_min) const u8,
    content: []const u8, // mapping[bom_len..] (post-BOM working bytes)
    content_len: u64,
    file_size: u64,
    bom_len: u64,

    // Dialect + shape (immutable after open).
    sep: u8,
    quote: ?u8, // null == quoting disabled (NONE)
    dialect: api.Dialect,
    column_count: u32,
    data_start: u64, // content offset of data row 0
    auto: bool,

    // Header cells (immutable after open; never evicted).
    has_header: bool,
    header_buf: []const u8,
    header_refs: []const CellRef,

    // Frontier + index + jump slot (mutex-protected).
    mutex: c.pthread_mutex_t,
    cond: c.pthread_cond_t,
    checkpoints: std.ArrayList(Checkpoint),
    frontier_rows: u64,
    frontier_offset: u64,
    complete: bool,
    total_rows: u64,
    jump_state: api.JumpState,
    jump_target: u64,
    jump_start_rows: u64,
    jump_progress: f64,
    jump_landed: u64,

    // Worker control.
    worker: ?std.Thread,
    stop: bool,
    stop_atomic: std.atomic.Value(bool),

    // Materialized window (window lane only; no lock).
    win_buf: std.ArrayList(u8),
    win_refs: std.ArrayList(CellRef),
    win_first: u64,
    win_rows: u64,

    fn lock(self: *Document) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *Document) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }
    fn wakeWorker(self: *Document) void {
        _ = c.pthread_cond_broadcast(&self.cond);
    }
    fn waitWork(self: *Document) void {
        _ = c.pthread_cond_wait(&self.cond, &self.mutex);
    }
};

fn asDoc(doc: *const api.Doc) *const Document {
    return @ptrCast(@alignCast(doc));
}

/// The document behind a handle is always in mutable memory; the `*const`
/// ABI parameter is advisory. Poll/control-lane calls take the mutex through
/// this so they see consistent frontier snapshots.
fn asDocMut(doc: *const api.Doc) *Document {
    return @constCast(@ptrCast(@alignCast(doc)));
}

// ---------------------------------------------------------------------------
// Lifecycle (C ABI + explicit-allocator seam).
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_open`. Equals
/// `openWithAllocator(<default allocator>, path, options, out_doc)`.
pub export fn ls_open(path: [*:0]const u8, options: ?*const api.OpenOptions, out_doc: *?*api.Doc) callconv(.c) api.Status {
    return openWithAllocator(default_gpa, path, options, out_doc);
}

fn validByte(v: i32) bool {
    return v >= 0x01 and v <= 0x7F and v != 0x0A and v != 0x0D;
}

fn validateOptions(opt: api.OpenOptions) bool {
    if (opt.separator != api.sniff and !validByte(opt.separator)) return false;
    if (opt.quote != api.sniff and opt.quote != api.quote_none and !validByte(opt.quote)) return false;
    if (opt.header != api.sniff and opt.header != api.header_off and opt.header != api.header_on) return false;
    if (opt.index_mode != api.index_auto and opt.index_mode != api.index_manual) return false;
    // Forced separator == forced quote byte is a collision.
    if (opt.separator != api.sniff and opt.separator == opt.quote) return false;
    return true;
}

/// See contracts/api.zig `openWithAllocator`. Every heap allocation for the
/// document goes through `gpa`; the file mapping itself (mmap) is exempt.
pub fn openWithAllocator(gpa: std.mem.Allocator, path: [*:0]const u8, options: ?*const api.OpenOptions, out_doc: *?*api.Doc) api.Status {
    out_doc.* = null;

    const opt: api.OpenOptions = if (options) |o| o.* else .{};
    if (!validateOptions(opt)) return .invalid_argument;

    // Open + stat (no file bytes consumed beyond the head region below).
    const fd = posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| return switch (err) {
        error.FileNotFound => .not_found,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        else => .io,
    };
    defer _ = c.close(fd);

    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return .io;
    if (!posix.S.ISREG(@as(u32, st.mode))) return .io; // dirs/devices -> distinct .io
    const file_size: u64 = if (st.size > 0) @intCast(st.size) else 0;

    // Map the file head-to-tail (sparse tails cost nothing; pages fault lazily
    // and the indexer madvises them away). Empty files are not mapped.
    var mapping: ?[]align(std.heap.page_size_min) const u8 = null;
    var content: []const u8 = &.{};
    var bom_len: u64 = 0;
    if (file_size > 0) {
        const m = posix.mmap(null, file_size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return .io;
        mapping = m;
        if (file_size >= 3 and m[0] == 0xEF and m[1] == 0xBB and m[2] == 0xBF) bom_len = 3;
        content = m[bom_len..file_size];
    }

    const doc = gpa.create(Document) catch {
        if (mapping) |m| posix.munmap(m);
        return .io;
    };
    doc.* = .{
        .gpa = gpa,
        .mapping = mapping,
        .content = content,
        .content_len = content.len,
        .file_size = file_size,
        .bom_len = bom_len,
        .sep = api.default_separator,
        .quote = api.default_quote,
        .dialect = undefined,
        .column_count = 0,
        .data_start = 0,
        .auto = opt.index_mode == api.index_auto,
        .has_header = false,
        .header_buf = &.{},
        .header_refs = &.{},
        .mutex = .{},
        .cond = .{},
        .checkpoints = .empty,
        .frontier_rows = 0,
        .frontier_offset = 0,
        .complete = true, // an empty document is complete at open
        .total_rows = 0,
        .jump_state = .idle,
        .jump_target = 0,
        .jump_start_rows = 0,
        .jump_progress = 0.0,
        .jump_landed = 0,
        .worker = null,
        .stop = false,
        .stop_atomic = .init(false),
        .win_buf = .empty,
        .win_refs = .empty,
        .win_first = 0,
        .win_rows = 0,
    };

    // Resolve the effective dialect (sniff the non-forced parameters).
    const rd = sniffDialect(content, opt);
    doc.sep = rd.sep;
    doc.quote = rd.quote;

    // Record 1 -> column count, header decision, header cells.
    if (content.len > 0) {
        if (!buildShape(doc, opt)) {
            freeDoc(doc);
            return .io;
        }
        // The base checkpoint must exist: findCheckpoint always reads [0].
        doc.checkpoints.append(gpa, .{ .row = 0, .offset = doc.data_start }) catch {
            freeDoc(doc);
            return .io;
        };
        doc.frontier_offset = doc.data_start;
        doc.complete = false;
        headScan(doc);
    }

    doc.dialect = .{
        .separator = doc.sep,
        .quote = doc.quote orelse api.default_quote,
        .has_quote = doc.quote != null,
        .header = doc.has_header,
        .separator_forced = opt.separator != api.sniff,
        .quote_forced = opt.quote != api.sniff,
        .header_forced = opt.header != api.sniff,
    };

    // One worker for the document's lifetime: advances the frontier (AUTO) or
    // parks until a jump (MANUAL). Failure to spawn only forfeits background
    // progress; the head frontier still serves the first screen.
    doc.worker = std.Thread.spawn(.{}, workerMain, .{doc}) catch null;

    out_doc.* = @ptrCast(doc);
    return .ok;
}

/// Decode record 1, fix the column count, decide the header, and (when the
/// header is on) retain its cells. Returns false only on allocation failure.
fn buildShape(doc: *Document, opt: api.OpenOptions) bool {
    var tmp_buf: std.ArrayList(u8) = .empty;
    var tmp_refs: std.ArrayList(CellRef) = .empty;
    const rec0_next = lexInto(doc.content, 0, doc.sep, doc.quote, null, &tmp_buf, &tmp_refs, doc.gpa) catch {
        tmp_buf.deinit(doc.gpa);
        tmp_refs.deinit(doc.gpa);
        return false;
    };
    doc.column_count = @intCast(tmp_refs.items.len);

    var all_numeric = true;
    for (tmp_refs.items) |ref| {
        if (!isNumeric(tmp_buf.items[ref.start .. ref.start + ref.len])) {
            all_numeric = false;
            break;
        }
    }
    doc.has_header = switch (opt.header) {
        api.header_on => true,
        api.header_off => false,
        else => !all_numeric, // sniff: header unless every record-1 cell is numeric
    };

    if (doc.has_header) {
        doc.header_buf = tmp_buf.toOwnedSlice(doc.gpa) catch {
            tmp_buf.deinit(doc.gpa);
            tmp_refs.deinit(doc.gpa);
            return false;
        };
        doc.header_refs = tmp_refs.toOwnedSlice(doc.gpa) catch {
            doc.gpa.free(doc.header_buf);
            doc.header_buf = &.{};
            tmp_refs.deinit(doc.gpa);
            return false;
        };
        doc.data_start = rec0_next;
    } else {
        tmp_buf.deinit(doc.gpa);
        tmp_refs.deinit(doc.gpa);
        doc.data_start = 0; // record 1 is data row 0
    }
    return true;
}

/// Index the head region only: advance the frontier over data records while
/// they fit within the O(head) byte budget. Files no larger than the budget
/// are fully indexed here (complete + exact immediately, per the ABI pin).
fn headScan(doc: *Document) void {
    const content = doc.content;
    const budget: usize = if (head_budget > doc.bom_len) @intCast(head_budget - doc.bom_len) else 0;
    const lim = @min(budget, content.len); // recordBounds requires limit <= content.len
    var i: usize = @intCast(doc.data_start);
    var row: u64 = 0;
    while (i < content.len and i < budget) {
        const b = recordBounds(content, i, doc.sep, doc.quote, lim);
        if (b.capped) break; // record spills past the head budget: leave for later
        if (doc.bom_len + b.next > head_budget) break; // keep bytes_scanned <= budget
        i = b.next;
        row += 1;
        if (row % checkpoint_interval == 0) doc.checkpoints.append(doc.gpa, .{ .row = row, .offset = i }) catch {};
        if (b.next >= content.len) break;
    }
    doc.frontier_offset = i;
    doc.frontier_rows = row;
    if (i >= content.len) {
        doc.complete = true;
        doc.total_rows = row;
    }
}

/// Release all document storage. The worker is already joined (ls_close) or
/// was never spawned (open failure), so the sync primitives are quiescent and
/// safe to destroy.
fn freeDoc(doc: *Document) void {
    doc.checkpoints.deinit(doc.gpa);
    doc.win_buf.deinit(doc.gpa);
    doc.win_refs.deinit(doc.gpa);
    if (doc.header_buf.len > 0) doc.gpa.free(doc.header_buf);
    if (doc.header_refs.len > 0) doc.gpa.free(doc.header_refs);
    if (doc.mapping) |m| posix.munmap(m);
    _ = c.pthread_cond_destroy(&doc.cond);
    _ = c.pthread_mutex_destroy(&doc.mutex);
    doc.gpa.destroy(doc);
}

/// See api/lesssheet.h `ls_close`.
pub export fn ls_close(doc: *api.Doc) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    d.lock();
    d.stop = true;
    d.stop_atomic.store(true, .monotonic);
    d.wakeWorker();
    d.unlock();
    if (d.worker) |w| w.join();
    freeDoc(d);
}

// ---------------------------------------------------------------------------
// The background/jump worker (sole frontier writer).
// ---------------------------------------------------------------------------

fn workerMain(doc: *Document) void {
    var released: u64 = 0; // content offset up to which pages were madvised away
    doc.lock();
    while (true) {
        if (doc.stop) break;
        const need = !doc.complete and (doc.auto or doc.jump_state == .scanning);
        if (!need) {
            doc.waitWork();
            continue;
        }
        const start_off = doc.frontier_offset;
        const start_row = doc.frontier_rows;
        doc.unlock();

        // Scan up to the next checkpoint boundary without holding the lock
        // (the worker is the only frontier writer, so this is race-free).
        const res = scanChunk(doc, start_off, start_row);

        doc.lock();
        doc.frontier_offset = res.end_offset;
        doc.frontier_rows = res.end_row;
        if (res.checkpoint) |cp| doc.checkpoints.append(doc.gpa, cp) catch {};
        if (res.eof) {
            doc.complete = true;
            doc.total_rows = doc.frontier_rows;
        }
        if (doc.jump_state == .scanning) updateJump(doc);
        const advanced = doc.frontier_offset;
        doc.unlock();

        // Release pages far behind the frontier (bounded resident memory).
        if (doc.mapping != null and advanced > released + madvise_release_chunk and advanced > madvise_keepback) {
            const rel_end = advanced - madvise_keepback;
            madviseDontNeed(doc, released, rel_end);
            released = rel_end;
        }

        doc.lock();
    }
    doc.unlock();
}

const ChunkResult = struct {
    end_offset: u64,
    end_row: u64,
    eof: bool,
    checkpoint: ?Checkpoint,
};

/// Lex records from `start_off`/`start_row` up to the next `checkpoint_interval`
/// multiple, or EOF, or a stop request. Reads only immutable mmap bytes.
fn scanChunk(doc: *Document, start_off: u64, start_row: u64) ChunkResult {
    const content = doc.content;
    var i: usize = @intCast(start_off);
    var row = start_row;
    const target = ((start_row / checkpoint_interval) + 1) * checkpoint_interval;
    while (row < target) {
        if (doc.stop_atomic.load(.monotonic)) return .{ .end_offset = i, .end_row = row, .eof = false, .checkpoint = null };
        if (i >= content.len) return .{ .end_offset = i, .end_row = row, .eof = true, .checkpoint = null };
        const b = recordBounds(content, i, doc.sep, doc.quote, content.len);
        i = b.next;
        row += 1;
        if (b.next >= content.len) return .{ .end_offset = i, .end_row = row, .eof = true, .checkpoint = null };
    }
    return .{ .end_offset = i, .end_row = row, .eof = false, .checkpoint = .{ .row = row, .offset = i } };
}

/// Fold the current frontier into the active jump slot (mutex held).
fn updateJump(doc: *Document) void {
    if (doc.frontier_rows > doc.jump_target or doc.complete) {
        doc.jump_state = .done;
        doc.jump_landed = if (doc.jump_target < doc.frontier_rows)
            doc.jump_target
        else if (doc.frontier_rows > 0) doc.frontier_rows - 1 else 0;
        doc.jump_progress = 1.0;
    } else {
        const span = doc.jump_target - doc.jump_start_rows;
        if (span > 0) {
            const p = @as(f64, @floatFromInt(doc.frontier_rows - doc.jump_start_rows)) / @as(f64, @floatFromInt(span));
            if (p > doc.jump_progress) doc.jump_progress = p;
        }
    }
}

fn madviseDontNeed(doc: *Document, start_content: u64, end_content: u64) void {
    const m = doc.mapping orelse return;
    const psz: u64 = std.heap.page_size_min;
    const a_start = std.mem.alignForward(u64, doc.bom_len + start_content, psz);
    const a_end = std.mem.alignBackward(u64, doc.bom_len + end_content, psz);
    if (a_end <= a_start or a_end > m.len) return;
    const ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(@constCast(m.ptr + @as(usize, @intCast(a_start))));
    posix.madvise(ptr, @intCast(a_end - a_start), c.MADV.DONTNEED) catch {};
}

// ---------------------------------------------------------------------------
// Document facts — zero allocation, total functions.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_dialect_get`.
pub export fn ls_dialect_get(doc: *const api.Doc) callconv(.c) api.Dialect {
    return asDoc(doc).dialect;
}

/// See api/lesssheet.h `ls_column_count`.
pub export fn ls_column_count(doc: *const api.Doc) callconv(.c) u32 {
    return asDoc(doc).column_count;
}

// ---------------------------------------------------------------------------
// Row-count knowledge and index progress.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_row_count_get`.
pub export fn ls_row_count_get(doc: *const api.Doc) callconv(.c) api.RowCount {
    const d = asDocMut(doc);
    d.lock();
    defer d.unlock();
    if (d.complete) return .{ .count = d.total_rows, .exact = true };
    // Estimate = total data bytes / mean indexed row bytes.
    const scanned_data = d.frontier_offset - d.data_start;
    const total_data = d.content_len - d.data_start;
    var count: u64 = 0;
    if (d.frontier_rows == 0 or scanned_data == 0) {
        count = if (total_data > 0) 1 else 0;
    } else {
        count = @intCast(@as(u128, total_data) * @as(u128, d.frontier_rows) / @as(u128, scanned_data));
    }
    return .{ .count = count, .exact = false };
}

/// See api/lesssheet.h `ls_index_poll`.
pub export fn ls_index_poll(doc: *const api.Doc) callconv(.c) api.ScanProgress {
    const d = asDocMut(doc);
    d.lock();
    defer d.unlock();
    return .{
        .bytes_scanned = d.bom_len + d.frontier_offset,
        .bytes_total = d.file_size,
        .complete = d.complete,
    };
}

// ---------------------------------------------------------------------------
// Windowed row access.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_window_set`. Never advances the frontier; re-lexes
/// the requested rows (behind the frontier) from the nearest checkpoint into
/// the owned window buffer, evicting the previous window.
pub export fn ls_window_set(doc: *api.Doc, first_row: u64, row_count: u32) callconv(.c) api.RowRange {
    const d: *Document = @ptrCast(@alignCast(doc));

    // Evict the previous window regardless of the outcome.
    d.win_buf.clearRetainingCapacity();
    d.win_refs.clearRetainingCapacity();
    d.win_first = first_row;
    d.win_rows = 0;

    if (d.column_count == 0) return .{ .first_row = first_row, .row_count = 0 };
    const clamped: u64 = @min(@as(u64, row_count), @as(u64, api.window_max_rows));

    d.lock();
    const avail_end = if (d.complete) d.total_rows else d.frontier_rows;
    var materialize: u64 = 0;
    var cp: Checkpoint = .{ .row = 0, .offset = d.data_start };
    if (first_row < avail_end) {
        materialize = @min(clamped, avail_end - first_row);
        cp = findCheckpoint(d.checkpoints.items, first_row);
    }
    d.unlock();

    if (materialize == 0) return .{ .first_row = first_row, .row_count = 0 };

    // Skip from the checkpoint to first_row, then decode `materialize` rows.
    var off: usize = @intCast(cp.offset);
    var r = cp.row;
    while (r < first_row) : (r += 1) {
        off = recordBounds(d.content, off, d.sep, d.quote, d.content.len).next;
    }
    var produced: u64 = 0;
    while (produced < materialize) : (produced += 1) {
        off = lexInto(d.content, off, d.sep, d.quote, d.column_count, &d.win_buf, &d.win_refs, d.gpa) catch break;
    }
    d.win_rows = produced;
    return .{ .first_row = first_row, .row_count = produced };
}

/// Largest checkpoint with `.row <= row` (checkpoints[0].row == 0 always).
fn findCheckpoint(checkpoints: []const Checkpoint, row: u64) Checkpoint {
    var best: Checkpoint = checkpoints[0];
    var lo: usize = 0;
    var hi: usize = checkpoints.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (checkpoints[mid].row <= row) {
            best = checkpoints[mid];
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return best;
}

/// See api/lesssheet.h `ls_cell`. Zero allocation; total function.
pub export fn ls_cell(doc: *const api.Doc, row: u64, col: u32) callconv(.c) api.Str {
    const d = asDoc(doc);
    if (col >= d.column_count) return empty_str;
    if (row < d.win_first or row >= d.win_first + d.win_rows) return empty_str;
    const idx = (row - d.win_first) * d.column_count + col;
    if (idx >= d.win_refs.items.len) return empty_str;
    const ref = d.win_refs.items[@intCast(idx)];
    if (ref.len == 0) return empty_str;
    return .{ .ptr = d.win_buf.items.ptr + ref.start, .len = ref.len };
}

/// See api/lesssheet.h `ls_header_cell`. Zero allocation; total function.
pub export fn ls_header_cell(doc: *const api.Doc, col: u32) callconv(.c) api.Str {
    const d = asDoc(doc);
    if (!d.has_header or col >= d.column_count or col >= d.header_refs.len) return empty_str;
    const ref = d.header_refs[col];
    if (ref.len == 0) return empty_str;
    return .{ .ptr = d.header_buf.ptr + ref.start, .len = ref.len };
}

// ---------------------------------------------------------------------------
// Jump-scans.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_jump_start`.
pub export fn ls_jump_start(doc: *api.Doc, target_row: u64) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    d.lock();
    defer d.unlock();
    if (target_row < d.frontier_rows) {
        // Behind the frontier: complete before this call returns.
        d.jump_state = .done;
        d.jump_landed = target_row;
        d.jump_progress = 1.0;
        return;
    }
    if (d.complete) {
        // At/past EOF with an exact count: clamp to the last data row.
        d.jump_state = .done;
        d.jump_landed = if (d.frontier_rows > 0) d.frontier_rows - 1 else 0;
        d.jump_progress = 1.0;
        return;
    }
    if (d.worker == null) {
        // Degraded mode: the background worker failed to spawn at open, so no
        // scan can advance the frontier and AUTO indexing is frozen at the
        // head. Fail OPEN — land at the frontier edge (the last row the head
        // window can serve) and report DONE, instead of leaving the jump
        // SCANNING forever (which would hang the caller's poll loop).
        d.jump_state = .done;
        d.jump_landed = if (d.frontier_rows > 0) d.frontier_rows - 1 else 0;
        d.jump_progress = 1.0;
        return;
    }
    // Asynchronous scan toward the target (retargets any running jump).
    d.jump_state = .scanning;
    d.jump_target = target_row;
    d.jump_start_rows = d.frontier_rows;
    d.jump_progress = 0.0;
    d.wakeWorker();
}

/// See api/lesssheet.h `ls_jump_cancel`.
pub export fn ls_jump_cancel(doc: *api.Doc) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    d.lock();
    defer d.unlock();
    if (d.jump_state == .scanning) {
        d.jump_state = .idle; // frontier gains are kept (we never rewind it)
        d.jump_progress = 0.0;
    }
}

/// See api/lesssheet.h `ls_jump_poll`.
pub export fn ls_jump_poll(doc: *const api.Doc) callconv(.c) api.JumpStatus {
    const d = asDocMut(doc);
    d.lock();
    defer d.unlock();
    return .{ .state = d.jump_state, .progress = d.jump_progress, .landed_row = d.jump_landed };
}

// ---------------------------------------------------------------------------
// The parameterized, quote-aware lexer (RFC-4180 generalized; quote NONE).
// All three functions agree on record boundaries.
// ---------------------------------------------------------------------------

const Bounds = struct { next: usize, capped: bool };

/// Find where the record at `pos` ends. Scans no further than `limit`
/// (<= content.len); `capped` is true iff the record failed to terminate
/// before `limit` (used to bound the head-budget scan). Quote state protects
/// embedded separators / CR / LF.
fn recordBounds(content: []const u8, pos: usize, sep: u8, quote: ?u8, limit: usize) Bounds {
    var i = pos;
    const n = limit;
    const cl = content.len;
    while (true) {
        if (quote != null and i < n and content[i] == quote.?) {
            i += 1;
            while (i < n) {
                if (content[i] == quote.?) {
                    if (i + 1 < cl and content[i + 1] == quote.?) {
                        i += 2;
                    } else {
                        i += 1;
                        break;
                    }
                } else i += 1;
            }
            if (i >= n) return if (n == cl) .{ .next = cl, .capped = false } else .{ .next = n, .capped = true };
            while (i < n and content[i] != sep and content[i] != '\n' and content[i] != '\r') i += 1;
        } else {
            while (i < n and content[i] != sep and content[i] != '\n' and content[i] != '\r') i += 1;
        }
        if (i >= n) return if (n == cl) .{ .next = cl, .capped = false } else .{ .next = n, .capped = true };
        const ch = content[i];
        if (ch == sep) {
            i += 1;
            continue;
        }
        if (ch == '\r') return .{ .next = if (i + 1 < cl and content[i + 1] == '\n') i + 2 else i + 1, .capped = false };
        return .{ .next = i + 1, .capped = false }; // '\n'
    }
}

/// Count the fields of the record at `pos` (no decode, no alloc), scanning no
/// further than `limit`. `quoted` reports whether any field opened with the
/// quote byte (feeds the sniffer's "active quote" signal). Used by the sniffer.
fn countFields(content: []const u8, pos: usize, sep: u8, quote: ?u8, limit: usize) struct { count: u32, next: usize, quoted: bool } {
    var i = pos;
    const n = limit;
    const cl = content.len;
    var count: u32 = 0;
    var quoted = false;
    while (true) {
        if (quote != null and i < n and content[i] == quote.?) {
            quoted = true;
            i += 1;
            while (i < n) {
                if (content[i] == quote.?) {
                    if (i + 1 < cl and content[i + 1] == quote.?) {
                        i += 2;
                    } else {
                        i += 1;
                        break;
                    }
                } else i += 1;
            }
            while (i < n and content[i] != sep and content[i] != '\n' and content[i] != '\r') i += 1;
        } else {
            while (i < n and content[i] != sep and content[i] != '\n' and content[i] != '\r') i += 1;
        }
        count += 1;
        if (i >= n) return .{ .count = count, .next = i, .quoted = quoted };
        const ch = content[i];
        if (ch == sep) {
            i += 1;
            continue;
        }
        if (ch == '\r') return .{ .count = count, .next = if (i + 1 < cl and content[i + 1] == '\n') i + 2 else i + 1, .quoted = quoted };
        return .{ .count = count, .next = i + 1, .quoted = quoted };
    }
}

/// Decode the record at `pos` into `buf`/`refs`. `want` == null decodes every
/// field (no padding); `want` == N produces exactly N refs (decoding the first
/// N fields, padding missing ones with the empty cell, scanning the rest for
/// the boundary). Returns the next record's offset.
fn lexInto(
    content: []const u8,
    pos: usize,
    sep: u8,
    quote: ?u8,
    want: ?u32,
    buf: *std.ArrayList(u8),
    refs: *std.ArrayList(CellRef),
    gpa: std.mem.Allocator,
) !usize {
    var i = pos;
    const n = content.len;
    var produced: u32 = 0;
    while (true) {
        const store = want == null or produced < want.?;
        const start = buf.items.len;
        if (quote != null and i < n and content[i] == quote.?) {
            i += 1;
            while (i < n) {
                const ch = content[i];
                if (ch == quote.?) {
                    if (i + 1 < n and content[i + 1] == quote.?) {
                        if (store) try buf.append(gpa, quote.?);
                        i += 2;
                    } else {
                        i += 1;
                        break;
                    }
                } else {
                    if (store) try buf.append(gpa, ch);
                    i += 1;
                }
            }
            while (i < n and content[i] != sep and content[i] != '\n' and content[i] != '\r') {
                if (store) try buf.append(gpa, content[i]);
                i += 1;
            }
        } else {
            while (i < n and content[i] != sep and content[i] != '\n' and content[i] != '\r') {
                if (store) try buf.append(gpa, content[i]);
                i += 1;
            }
        }
        if (store) try refs.append(gpa, .{ .start = start, .len = buf.items.len - start });
        produced += 1;
        if (i >= n) {
            if (want) |w| while (produced < w) : (produced += 1) try refs.append(gpa, .{ .start = 0, .len = 0 });
            return n;
        }
        const ch = content[i];
        if (ch == sep) {
            i += 1;
            continue;
        }
        const next: usize = if (ch == '\r')
            (if (i + 1 < n and content[i + 1] == '\n') i + 2 else i + 1)
        else
            i + 1;
        if (want) |w| while (produced < w) : (produced += 1) try refs.append(gpa, .{ .start = 0, .len = 0 });
        return next;
    }
}

// ---------------------------------------------------------------------------
// Dialect sniffing (O(head sample); pinned candidates + tie-breaks).
// ---------------------------------------------------------------------------

const Resolved = struct { sep: u8, quote: ?u8 };

/// Resolve the effective separator/quote: forced parameters are fixed, the
/// rest are sniffed over the head sample. The sniffer never selects NONE and
/// never selects a value equal to a forced parameter.
fn sniffDialect(content: []const u8, opt: api.OpenOptions) Resolved {
    const sep_forced = opt.separator != api.sniff;
    const quote_none_forced = opt.quote == api.quote_none;
    const quote_byte_forced = opt.quote >= 0;
    const fsep: u8 = if (sep_forced) @intCast(opt.separator) else 0;
    const fqb: u8 = if (quote_byte_forced) @intCast(opt.quote) else 0;

    var seps: [4]u8 = undefined;
    var sn: usize = 0;
    if (sep_forced) {
        seps[0] = fsep;
        sn = 1;
    } else for (api.separator_candidates) |cch| {
        if (!(quote_byte_forced and cch == fqb)) {
            seps[sn] = cch;
            sn += 1;
        }
    }

    var quotes: [2]?u8 = undefined;
    var qn: usize = 0;
    if (quote_none_forced) {
        quotes[0] = null;
        qn = 1;
    } else if (quote_byte_forced) {
        quotes[0] = fqb;
        qn = 1;
    } else for (api.quote_candidates) |qch| {
        if (!(sep_forced and qch == fsep)) {
            quotes[qn] = qch;
            qn += 1;
        }
    }

    var best_sep: u8 = if (sn > 0) seps[0] else api.default_separator;
    var best_quote: ?u8 = if (qn > 0) quotes[0] else api.default_quote;
    if (sn * qn <= 1) return .{ .sep = best_sep, .quote = best_quote };

    var best: ?Score = null;
    for (seps[0..sn]) |s| {
        for (quotes[0..qn]) |q| {
            const sc = scorePair(content, s, q);
            if (best == null or betterThan(sc, best.?)) {
                best = sc;
                best_sep = s;
                best_quote = q;
            }
        }
    }
    return .{ .sep = best_sep, .quote = best_quote };
}

fn scorePair(content: []const u8, sep: u8, quote: ?u8) Score {
    var hist = [_]u32{0} ** (max_field_hist + 1);
    var total: u32 = 0;
    var records: u32 = 0;
    var active = false;
    var i: usize = 0;
    const limit = @min(content.len, sniff_byte_cap);
    while (i < limit and records < sniff_record_cap) {
        const r = countFields(content, i, sep, quote, limit);
        hist[@min(@as(usize, r.count), max_field_hist)] += 1;
        if (r.quoted) active = true;
        total += 1;
        records += 1;
        if (r.next <= i) break;
        i = r.next;
        if (i >= content.len) break;
    }
    // Modal field count, ties broken toward the LARGER count: a candidate that
    // splits any records into multiple fields must read as "splitting" even
    // when as many records are ragged/short (pinned: splitting beats single).
    var mode: u32 = 0;
    var mode_freq: u32 = 0;
    for (hist, 0..) |f, k| {
        if (f > 0 and f >= mode_freq) {
            mode_freq = f;
            mode = @intCast(k);
        }
    }
    return .{
        .active = active,
        .splits = mode >= 2,
        .consistency = if (total > 0) @as(f64, @floatFromInt(mode_freq)) / @as(f64, @floatFromInt(total)) else 0,
        .mode = mode,
    };
}

// ---------------------------------------------------------------------------
// Numeric-cell test (pinned grammar — see api/lesssheet.h HEADER RULE).
//   sign? ( digits ('.' digits?)? | '.' digits ) ( ('e'|'E') sign? digits )?
// after trimming ASCII whitespace (0x09..0x0D, 0x20); remainder must be
// non-empty and match fully. Decimal separator '.' only; ASCII digits only.
// ---------------------------------------------------------------------------

fn isAsciiWs(ch: u8) bool {
    return ch == 0x20 or (ch >= 0x09 and ch <= 0x0D);
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

pub fn isNumeric(raw: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = raw.len;
    while (lo < hi and isAsciiWs(raw[lo])) lo += 1;
    while (hi > lo and isAsciiWs(raw[hi - 1])) hi -= 1;
    const s = raw[lo..hi];
    if (s.len == 0) return false;

    var i: usize = 0;
    if (s[i] == '+' or s[i] == '-') i += 1;

    var int_digits: usize = 0;
    while (i < s.len and isDigit(s[i])) : (i += 1) int_digits += 1;

    var has_significand = int_digits > 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var frac_digits: usize = 0;
        while (i < s.len and isDigit(s[i])) : (i += 1) frac_digits += 1;
        if (int_digits == 0 and frac_digits == 0) return false; // lone '.'
        if (frac_digits > 0) has_significand = true;
    } else if (int_digits == 0) {
        return false; // needs the 'digits' form when there is no dot
    }
    if (!has_significand) return false;

    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < s.len and isDigit(s[i])) : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return false; // dangling exponent
    }
    return i == s.len;
}
