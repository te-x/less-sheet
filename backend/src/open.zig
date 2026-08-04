//! Shared document construction: turns a ready `Source` (mmap / gzip /
//! http_range) into a fully-formed `Document` with the head scanned, the shape
//! (columns/header) built, the dialect resolved, and the background worker
//! spawned. Both `ls_open` (root.openWithAllocator, over a local mmap/gzip
//! Source) and the network open (net.zig, over an http_range or downloaded
//! Source) funnel through `buildDocument`, so every existing accessor, jump,
//! search, and filter behaves identically regardless of where the bytes came
//! from — the whole point of the reader-interface seam.

const std = @import("std");
const api = @import("api");

const posix = std.posix;
const sysio = @import("sysio.zig");

const base = @import("base.zig");
// ARCH-security-hardening (g): released here only on the failure path before a
// Document exists to own the guard slot (afterwards `freeDoc` does it).
const fault_guard = @import("fault_guard.zig");
const csv_reader = @import("csv_reader.zig");
const source_mod = @import("source.zig");
const index = @import("index.zig");
const matcher = @import("matcher.zig");
const Document = base.Document;
const CellRef = base.CellRef;
const freeDoc = base.freeDoc;

/// Sample size (SOURCE bytes) for encoding detection. Mirrors the constant that
/// lived in root.zig before the extraction.
const encoding_sample_bytes: usize = 256 * 1024;

/// Build a Document from a ready Source. On success returns the doc (worker
/// spawned); on failure returns null AFTER releasing `source`, `mapping`,
/// `fault_slot` and `fd` (the caller must not touch any of them again).
/// `mapping`, when non-null, is the backing mmap the doc owns and munmaps at
/// close (a local file, or a network download spool). For an http_range Source
/// `mapping` is null — the Source owns its spool. `file_size` is the physical
/// byte total for progress.
///
/// `fault_slot` and `fd` are the ARCH-security-hardening (g) SOURCE-FAULT GUARD's
/// two handles on a LOCAL file: the registry slot guarding `mapping` (armed by
/// the caller BEFORE any byte was read) and the source fd kept open so a fault
/// can be sized with `fstat`. Both are null for a network document — the local
/// mmap is what AC-g1 scopes, and the network spool is a file this process
/// creates, holds and extends itself rather than one a stranger can truncate.
pub fn buildDocument(
    gpa: std.mem.Allocator,
    source_in: source_mod.Source,
    mapping: ?[]align(std.heap.page_size_min) const u8,
    fault_slot: ?u32,
    fd: ?posix.fd_t,
    file_size: u64,
    opt: api.OpenOptions,
) ?*Document {
    var source = source_in;
    var source_owned = true;
    defer if (source_owned) source_mod.sourceDeinit(&source);

    const from_mmap = source == .mmap;
    const is_gzip = source == .gzip;
    const head_bytes: []const u8 = if (from_mmap) source.mmap.bytes else source.openHead();
    const oh = csv_reader.openHead(head_bytes, opt, encoding_sample_bytes);
    source_mod.rebaseBom(&source, oh.bom_len);

    const content_len: u64 = if (is_gzip) file_size else source.len();

    const doc = gpa.create(Document) catch {
        fault_guard.disarm(fault_slot);
        if (mapping) |m| posix.munmap(m);
        if (fd) |h| sysio.close(h);
        return null;
    };
    doc.* = .{
        .gpa = gpa,
        .mapping = mapping,
        .fault_slot = fault_slot,
        .fd = fd,
        .source = source,
        .reader = .{ .csv = oh.reader },
        .content_len = content_len,
        .file_size = file_size,
        .bom_len = oh.bom_len,
        .dialect = undefined,
        .column_count = 0,
        .data_start = undefined,
        .auto = opt.index_mode == api.index_auto,
        .has_header = false,
        .header_buf = &.{},
        .header_refs = &.{},
        .record1_capped = false,
        .row0_pinned_buf = &.{},
        .row0_pinned_refs = &.{},
        .mutex = .init,
        .cond = .init,
        .checkpoints = .empty,
        .oversized_checkpoints = .empty,
        .oversized_stage = .empty,
        .frontier_rows = 0,
        .frontier_pos = undefined,
        .complete = true,
        .total_rows = 0,
        .jump_state = .idle,
        .jump_target = 0,
        .jump_start_rows = 0,
        .jump_progress = 0.0,
        .jump_landed = 0,
        .search_state = .idle,
        .search_nav = .none,
        .search_progress = 0.0,
        .search_found_row = 0,
        .search_found_col = 0,
        .search_position = 0,
        .search_total = 0,
        .search_total_exact = false,
        .search_pos = undefined,
        .search_rows = 0,
        .search_to_eof = true,
        .search_gen = 0,
        .nav_pending = false,
        .nav_anchor = 0,
        .nav_dir = .forward,
        .search_kind = .text,
        .search_op = .eq,
        .search_column = 0,
        .search_value = &.{},
        .search_value_dec = .{},
        .search_fold = false,
        .search_failure = &.{},
        .scope_mask = &.{},
        .block_counts = .empty,
        .search_scratch = .empty,
        .search_refs = .empty,
        .w_value = .empty,
        .w_mask = .empty,
        .w_failure = .empty,
        .w_ctx = .{},
        .w_gen = 0,
        .nav_scratch = .empty,
        .nav_refs = .empty,
        .filter_state = .idle,
        .filter_progress = 0.0,
        .filter_total = 0,
        .filter_total_exact = false,
        .filter_pos = undefined,
        .filter_rows = 0,
        .filter_gen = 0,
        .filter_kind = .text,
        .filter_op = .eq,
        .filter_column = 0,
        .filter_value = &.{},
        .filter_value_dec = .{},
        .filter_fold = false,
        .filter_failure = &.{},
        .filter_scope_mask = &.{},
        .filter_block_counts = .empty,
        .filter_oversized_stage = .empty,
        .filter_oversized_matches = .empty,
        .filter_scratch = .empty,
        .filter_refs = .empty,
        .wf_value = .empty,
        .wf_mask = .empty,
        .wf_failure = .empty,
        .wf_ctx = .{},
        .wf_gen = 0,
        .worker = null,
        .stop = false,
        .stop_atomic = .init(false),
        .win_buf = .empty,
        .win_refs = .empty,
        .win_source = .empty,
        .win_oversized = .empty,
        .win_first = 0,
        .win_rows = 0,
    };
    source_owned = false;

    // never-full-download-streaming (TD1): the lazy-frontier gate keys strictly
    // on source kind — true for a network Source (http_range, or gzip composed
    // over http_range), false for every local mmap/gzip doc (byte-identical).
    doc.net = source_mod.sourceIsNetwork(doc.source);

    if (is_gzip) switch (doc.source) {
        .gzip => |g| {
            doc.gz_physical_in = g.open_physical;
            doc.gz_inflated_out = g.open_inflated;
            doc.gz_resident_bytes = g.residentBytes();
        },
        else => {},
    };

    const start_pos = doc.reader.start(doc.source);
    doc.data_start = start_pos;
    doc.frontier_pos = start_pos;
    doc.search_pos = start_pos;
    doc.filter_pos = start_pos;

    if (oh.content.len > 0) {
        if (!buildShape(doc, opt)) {
            freeDoc(doc);
            return null;
        }
        doc.checkpoints.append(gpa, .{ .row = 0, .pos = doc.data_start }) catch {
            freeDoc(doc);
            return null;
        };
        doc.frontier_pos = doc.data_start;
        if (doc.has_header and doc.record1_capped) {
            doc.complete = true;
            doc.total_rows = 0;
        } else {
            doc.complete = false;
            index.headScan(doc);
        }
    }

    doc.dialect = .{
        .separator = oh.reader.sep,
        .quote = oh.reader.quote orelse api.default_quote,
        .has_quote = oh.reader.quote != null,
        .header = doc.has_header,
        .encoding = oh.reader.encoding,
        .separator_forced = opt.separator != api.sniff,
        .quote_forced = opt.quote != api.sniff,
        .header_forced = opt.header != api.sniff,
        .encoding_forced = opt.encoding != api.encoding_auto,
    };

    source_mod.sourceFinishOpen(&doc.source);
    doc.startWorker(index.workerMain);
    return doc;
}

/// Decode record 1, fix the column count, decide the header, and (when the
/// header is on) retain its cells. Moved verbatim from root.zig; see the
/// original doc comment there for the BOUNDED RECORD 1 rationale.
fn buildShape(doc: *Document, opt: api.OpenOptions) bool {
    var tmp_buf: std.ArrayList(u8) = .empty;
    var tmp_refs: std.ArrayList(CellRef) = .empty;
    const lim = index.headSourceLimit(doc);
    const res = doc.reader.materialize(doc.source, doc.reader.start(doc.source), null, api.cell_max_bytes, lim, &tmp_buf, &tmp_refs, doc.gpa) catch {
        tmp_buf.deinit(doc.gpa);
        tmp_refs.deinit(doc.gpa);
        return false;
    };
    doc.column_count = @intCast(tmp_refs.items.len);
    doc.record1_capped = res.capped;

    var all_numeric = true;
    for (tmp_refs.items) |ref| {
        if (!matcher.isNumeric(tmp_buf.items[ref.start .. ref.start + ref.len])) {
            all_numeric = false;
            break;
        }
    }
    doc.has_header = switch (opt.header) {
        api.header_on => true,
        api.header_off => false,
        else => !all_numeric,
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
        doc.data_start = res.next;
    } else if (doc.record1_capped) {
        doc.row0_pinned_buf = tmp_buf.toOwnedSlice(doc.gpa) catch {
            tmp_buf.deinit(doc.gpa);
            tmp_refs.deinit(doc.gpa);
            return false;
        };
        doc.row0_pinned_refs = tmp_refs.toOwnedSlice(doc.gpa) catch {
            doc.gpa.free(doc.row0_pinned_buf);
            doc.row0_pinned_buf = &.{};
            tmp_refs.deinit(doc.gpa);
            return false;
        };
        doc.data_start = doc.reader.start(doc.source);
    } else {
        tmp_buf.deinit(doc.gpa);
        tmp_refs.deinit(doc.gpa);
        doc.data_start = doc.reader.start(doc.source);
    }
    return true;
}
