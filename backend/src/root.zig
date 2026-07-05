//! less-sheet core — file access, parsing, and windowed row access.
//! Implements api/lesssheet.h exactly (see it and contracts/api.zig for the
//! full semantics: ownership, validity, threading, CSV dialect, header rule,
//! numeric grammar). contracts/ and tests/ are planner-owned.
//!
//! Walking-skeleton strategy: open the file, mmap it read-only, parse only its
//! head (at most one header record + `head_max_data_rows` data records) into a
//! compact owned store, then unmap. Cell text crosses the ABI as borrowed
//! slices into that store; accessors are pure O(1) lookups with zero
//! allocation. Opening is O(loaded head): pages beyond the parsed head never
//! fault, so a 10 GB CSV opens as fast as a 10 KB one.

const std = @import("std");
const api = @import("api");

const posix = std.posix;
const c = std.c;

/// Default allocator behind `ls_open` (thread-safe, no libc dependency of its
/// own beyond what the target already links). `ls_close` returns storage here.
const default_gpa = std.heap.smp_allocator;

/// A borrowed cell's byte range within a document's `text` buffer.
const Cell = struct { off: u32, len: u32 };

/// The concrete storage behind an `ls_doc` handle. All fields except the
/// allocator are owned and freed in `ls_close`.
const Document = struct {
    gpa: std.mem.Allocator,
    /// All materialized cell bytes (CSV-unescaped), concatenated. Cell ranges
    /// index into this; it stays valid until close.
    text: std.ArrayList(u8),
    /// Flat data-row cells, row-major. Row `r` occupies
    /// `data_cells[row_starts[r] .. row_starts[r+1]]` (already truncated to
    /// `column_count`; shorter rows store fewer and pad on access).
    data_cells: std.ArrayList(Cell),
    /// `data_row_count + 1` offsets into `data_cells`.
    row_starts: std.ArrayList(u32),
    /// The suggested header record's cells (exactly `column_count` of them when
    /// `header_suggested`; otherwise unused and length 0).
    header_cells: std.ArrayList(Cell),
    column_count: u32,
    data_row_count: u32,
    header_suggested: bool,

    fn deinit(self: *Document) void {
        const gpa = self.gpa;
        self.text.deinit(gpa);
        self.data_cells.deinit(gpa);
        self.row_starts.deinit(gpa);
        self.header_cells.deinit(gpa);
        gpa.destroy(self);
    }
};

/// The empty borrowed string returned by every out-of-range / no-header access.
/// `ptr` is a valid, non-null address; `len` is 0 (its contents must not be read).
const empty_str: api.Str = .{ .ptr = "", .len = 0 };

fn asDoc(doc: *const api.Doc) *const Document {
    return @ptrCast(@alignCast(doc));
}

// ---------------------------------------------------------------------------
// Open (C ABI + explicit-allocator seam).
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_open`. Equals
/// `openHeadWithAllocator(<default allocator>, path, out_doc)`.
pub export fn ls_open(path: [*:0]const u8, out_doc: *?*api.Doc) callconv(.c) api.Status {
    return openHeadWithAllocator(default_gpa, path, out_doc);
}

/// See contracts/api.zig `openHeadWithAllocator`. Every heap allocation for the
/// document goes through `gpa`; the file mapping itself (mmap) is exempt.
pub fn openHeadWithAllocator(gpa: std.mem.Allocator, path: [*:0]const u8, out_doc: *?*api.Doc) api.Status {
    out_doc.* = null;

    const fd = posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| return switch (err) {
        error.FileNotFound => .not_found,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        else => .io,
    };
    defer _ = c.close(fd);

    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return .io;
    // Only regular files are readable as documents; directories/devices/etc.
    // exist but "cannot be read as a file" -> the distinct I/O error code.
    if (!posix.S.ISREG(@as(u32, st.mode))) return .io;

    const size: usize = if (st.size > 0) @intCast(st.size) else 0;

    // Empty file: a valid, empty document (mmap of length 0 is not allowed).
    if (size == 0) {
        const doc = buildDocument(gpa, &.{}) catch return .io;
        out_doc.* = @ptrCast(doc);
        return .ok;
    }

    const mapping = posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return .io;
    defer posix.munmap(mapping);

    var data: []const u8 = mapping;
    // Strip a single leading UTF-8 BOM before parsing (never appears in cells).
    if (data.len >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
        data = data[3..];
    }

    const doc = buildDocument(gpa, data) catch return .io;
    out_doc.* = @ptrCast(doc);
    return .ok;
}

/// See api/lesssheet.h `ls_close`.
pub export fn ls_close(doc: *api.Doc) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    d.deinit();
}

// ---------------------------------------------------------------------------
// Accessors — zero allocation, total functions.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_data_row_count`.
pub export fn ls_data_row_count(doc: *const api.Doc) callconv(.c) u32 {
    return asDoc(doc).data_row_count;
}

/// See api/lesssheet.h `ls_column_count`.
pub export fn ls_column_count(doc: *const api.Doc) callconv(.c) u32 {
    return asDoc(doc).column_count;
}

/// See api/lesssheet.h `ls_header_suggested`.
pub export fn ls_header_suggested(doc: *const api.Doc) callconv(.c) bool {
    return asDoc(doc).header_suggested;
}

/// See api/lesssheet.h `ls_cell`. Zero allocation; total function.
pub export fn ls_cell(doc: *const api.Doc, row: u32, col: u32) callconv(.c) api.Str {
    const d = asDoc(doc);
    if (row >= d.data_row_count or col >= d.column_count) return empty_str;
    const start = d.row_starts.items[row];
    const stored = d.row_starts.items[row + 1] - start;
    if (col >= stored) return empty_str; // ragged pad: missing trailing cell
    return borrow(d, d.data_cells.items[start + col]);
}

/// See api/lesssheet.h `ls_header_cell`. Zero allocation; total function.
pub export fn ls_header_cell(doc: *const api.Doc, col: u32) callconv(.c) api.Str {
    const d = asDoc(doc);
    if (!d.header_suggested or col >= d.column_count) return empty_str;
    return borrow(d, d.header_cells.items[col]);
}

fn borrow(d: *const Document, cell: Cell) api.Str {
    return .{ .ptr = d.text.items.ptr + cell.off, .len = cell.len };
}

// ---------------------------------------------------------------------------
// Head materialization.
// ---------------------------------------------------------------------------

fn buildDocument(gpa: std.mem.Allocator, data: []const u8) !*Document {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var data_cells: std.ArrayList(Cell) = .empty;
    errdefer data_cells.deinit(gpa);
    var row_starts: std.ArrayList(u32) = .empty;
    errdefer row_starts.deinit(gpa);
    var header_cells: std.ArrayList(Cell) = .empty;
    errdefer header_cells.deinit(gpa);

    var column_count: u32 = 0;
    var data_row_count: u32 = 0;
    var header_suggested = false;

    try row_starts.append(gpa, 0);

    if (data.len > 0) {
        // Record 1 defines the column count and the header suggestion. Parse it
        // fully (store every field) into header_cells first.
        const r0 = try parseRecord(gpa, data, 0, &text, &header_cells, std.math.maxInt(u32));
        column_count = @intCast(r0.fields);

        var all_numeric = true;
        for (header_cells.items) |cell| {
            if (!isNumeric(text.items[cell.off..][0..cell.len])) {
                all_numeric = false;
                break;
            }
        }
        header_suggested = !all_numeric;

        var pos = r0.next;

        if (!header_suggested) {
            // Record 1 is data row 0. Reuse the already-materialized cells.
            try data_cells.appendSlice(gpa, header_cells.items);
            header_cells.clearRetainingCapacity();
            data_row_count = 1;
            try row_starts.append(gpa, @intCast(data_cells.items.len));
        }

        // Parse further data records until the head cap or EOF. Records wider
        // than column_count are truncated during parsing; narrower ones pad.
        while (data_row_count < api.head_max_data_rows and pos < data.len) {
            const r = try parseRecord(gpa, data, pos, &text, &data_cells, column_count);
            pos = r.next;
            data_row_count += 1;
            try row_starts.append(gpa, @intCast(data_cells.items.len));
        }
    }

    const doc = try gpa.create(Document);
    doc.* = .{
        .gpa = gpa,
        .text = text,
        .data_cells = data_cells,
        .row_starts = row_starts,
        .header_cells = header_cells,
        .column_count = column_count,
        .data_row_count = data_row_count,
        .header_suggested = header_suggested,
    };
    return doc;
}

const RecordResult = struct { next: usize, fields: usize };

/// Parse one quote-aware RFC-4180 record starting at `data[start]`. Appends each
/// field's unescaped bytes to `text` and, for the first `max_store` fields, a
/// cell range to `out_cells`. Extra fields are still consumed (to find the
/// record boundary) but not stored (the truncate rule). Returns the field count
/// and the offset just past the record terminator (or EOF).
fn parseRecord(
    gpa: std.mem.Allocator,
    data: []const u8,
    start: usize,
    text: *std.ArrayList(u8),
    out_cells: *std.ArrayList(Cell),
    max_store: u32,
) !RecordResult {
    var i = start;
    var fields: usize = 0;
    while (true) {
        const field_off = text.items.len;
        i = try parseField(gpa, data, i, text);
        const field_len = text.items.len - field_off;
        if (fields < max_store) {
            try out_cells.append(gpa, .{ .off = @intCast(field_off), .len = @intCast(field_len) });
        } else {
            // Truncated field: reclaim the bytes we just appended.
            text.items.len = field_off;
        }
        fields += 1;

        if (i >= data.len) return .{ .next = i, .fields = fields };
        switch (data[i]) {
            ',' => i += 1, // field separator; continue to the next field
            '\n' => return .{ .next = i + 1, .fields = fields },
            '\r' => {
                const skip: usize = if (i + 1 < data.len and data[i + 1] == '\n') 2 else 1;
                return .{ .next = i + skip, .fields = fields };
            },
            else => unreachable, // parseField only stops at ',' '\n' '\r' or EOF
        }
    }
}

/// Parse a single field starting at `data[start]`, appending its unescaped
/// bytes to `text`. Returns the index of the delimiter/terminator/EOF that
/// ended the field (one of ',' '\n' '\r' or data.len).
fn parseField(gpa: std.mem.Allocator, data: []const u8, start: usize, text: *std.ArrayList(u8)) !usize {
    var i = start;
    if (i < data.len and data[i] == '"') {
        i += 1;
        while (i < data.len) {
            const ch = data[i];
            if (ch == '"') {
                if (i + 1 < data.len and data[i + 1] == '"') {
                    try text.append(gpa, '"'); // "" -> literal quote
                    i += 2;
                } else {
                    i += 1; // closing quote
                    break;
                }
            } else {
                try text.append(gpa, ch); // commas/CR/LF inside quotes are literal
                i += 1;
            }
        }
    }
    // Unquoted run (also absorbs any bytes after a closing quote up to the delimiter).
    while (i < data.len) {
        const ch = data[i];
        if (ch == ',' or ch == '\n' or ch == '\r') break;
        try text.append(gpa, ch);
        i += 1;
    }
    return i;
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

fn isNumeric(raw: []const u8) bool {
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
