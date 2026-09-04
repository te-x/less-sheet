//! Sparse, session-scoped storage for the per-column metadata. Keeping the
//! storage types separate from column.zig lets base.Document own them without
//! creating an import cycle with the worker.

const std = @import("std");
const api = @import("api");

const publication_threshold = 8;

pub const ThresholdRows = struct {
    len: u8 = 0,
    rows: [publication_threshold]u64 = [_]u64{api.no_row} ** publication_threshold,

    /// Admit a source identity only once. Capacity is exactly the amount of
    /// proof any one publication/proposal decision can consume; once full,
    /// that decision has already reached its eight-row threshold.
    pub fn admit(self: *ThresholdRows, row: u64) bool {
        if (self.contains(row)) return false;
        if (self.len == self.rows.len) return false;
        self.rows[self.len] = row;
        self.len += 1;
        return true;
    }

    pub fn contains(self: *const ThresholdRows, row: u64) bool {
        for (self.rows[0..self.len]) |seen| if (seen == row) return true;
        return false;
    }
};

pub const ConflictBucket = struct {
    ty: ?api.ColumnType = null,
    count: u64 = 0,
    overflow_rows: ThresholdRows = .{},
};

pub const SampleBucket = struct {
    ty: ?api.ColumnType = null,
    count: u64 = 0,
    source_row: u64 = api.no_row,
    example_len: usize = 0,
    example_truncated: bool = false,
    example: [api.column_conflict_example_max_bytes]u8 = undefined,
};

pub const CoverageRange = struct { first: u64, end: u64 };
pub const CoverResult = enum { already, tracked, untracked };

// The prefix is exact and monotonic. Pending disjoint coverage is exact too,
// but capped so pathological fragmented windows cannot grow memory or locked
// merge work without bound.
const coverage_range_max_bytes = 4 * 1024;
const coverage_range_max_count = coverage_range_max_bytes / @sizeOf(CoverageRange);

pub const State = struct {
    column: u32,
    generation: u64 = 0,

    // CSV leaves this absent; the slot is nevertheless real so future
    // self-describing readers can participate in effective precedence.
    declared: ?api.ColumnType = null,
    inferred: ?api.ColumnType = null,
    inferred_published: bool = false,
    override_type: ?api.ColumnType = null,
    proposal: ?api.ColumnType = null,

    inference_state: api.ColumnInferenceState = .unrequested,
    confidence: api.ColumnConfidence = .none,
    head_sampled: bool = false,

    has_sentinel: bool = false,
    sentinel_len: usize = 0,
    sentinel: [api.column_sentinel_max_bytes]u8 = undefined,

    evidence_count: u64 = 0,
    sampled_row_count: u64 = 0,
    sampled_decoded_bytes: u64 = 0,
    empty_count: u64 = 0,
    null_count: u64 = 0,

    conflict_state: api.ColumnConflictState = .none,
    conflict_count: u64 = 0,
    conflict_source_row: u64 = api.no_row,
    conflict_example_len: usize = 0,
    conflict_example_truncated: bool = false,
    conflict_example: [api.column_conflict_example_max_bytes]u8 = undefined,
    conflict_buckets: [9]ConflictBucket = [_]ConflictBucket{.{}} ** 9,
    samples: [9]SampleBucket = [_]SampleBucket{.{}} ** 9,
    publication_overflow_rows: ThresholdRows = .{},

    // Rows below this prefix have actually had this column examined. Pending
    // disjoint ranges are exact too, but bounded; neither index progress nor a
    // probabilistic identity structure may advance classification coverage.
    classified_prefix: u64 = 0,
    coverage_ranges: std.ArrayList(CoverageRange) = .empty,

    pub fn init(column: u32) State {
        return .{ .column = column };
    }

    pub fn resetEvidence(self: *State) void {
        self.inferred = null;
        self.inferred_published = false;
        self.proposal = null;
        self.inference_state = .unrequested;
        self.confidence = .none;
        self.head_sampled = false;
        self.evidence_count = 0;
        self.sampled_row_count = 0;
        self.sampled_decoded_bytes = 0;
        self.empty_count = 0;
        self.null_count = 0;
        self.samples = [_]SampleBucket{.{}} ** 9;
        self.publication_overflow_rows = .{};
        self.classified_prefix = 0;
        self.coverage_ranges.clearRetainingCapacity();
        self.resetConflicts();
    }

    pub fn resetConflicts(self: *State) void {
        self.proposal = null;
        self.conflict_state = .none;
        self.conflict_count = 0;
        self.conflict_source_row = api.no_row;
        self.conflict_example_len = 0;
        self.conflict_example_truncated = false;
        self.conflict_buckets = [_]ConflictBucket{.{}} ** 9;
    }

    fn lessRange(_: void, a: CoverageRange, b: CoverageRange) bool {
        return a.first < b.first;
    }

    fn normalizeCoverage(self: *State) void {
        var write: usize = 0;
        for (self.coverage_ranges.items) |range| {
            if (range.end <= self.classified_prefix) continue;
            if (range.first <= self.classified_prefix) {
                self.classified_prefix = @max(self.classified_prefix, range.end);
                continue;
            }
            if (write > 0 and range.first <= self.coverage_ranges.items[write - 1].end) {
                self.coverage_ranges.items[write - 1].end = @max(self.coverage_ranges.items[write - 1].end, range.end);
            } else {
                self.coverage_ranges.items[write] = range;
                write += 1;
            }
        }
        self.coverage_ranges.items.len = write;
    }

    pub fn coverClassifiedPrefix(self: *State, end: u64) void {
        self.classified_prefix = @max(self.classified_prefix, end);
        self.normalizeCoverage();
    }

    fn rangeContains(self: *const State, row: u64) bool {
        for (self.coverage_ranges.items) |range| {
            if (row < range.first) return false;
            if (row < range.end) return true;
        }
        return false;
    }

    /// Classify this exact source-row identity against the bounded coverage
    /// set. At range capacity the threshold-specific exact row sets decide
    /// whether an otherwise-untracked value can still be admitted safely.
    pub fn coverRow(self: *State, gpa: std.mem.Allocator, row: u64) std.mem.Allocator.Error!CoverResult {
        if (row < self.classified_prefix or self.rangeContains(row)) return .already;
        if (row == self.classified_prefix) {
            self.classified_prefix += 1;
        } else {
            for (self.coverage_ranges.items) |*range| {
                if (row +| 1 == range.first) {
                    range.first = row;
                    self.normalizeCoverage();
                    return .tracked;
                }
                if (row == range.end) {
                    range.end +|= 1;
                    self.normalizeCoverage();
                    return .tracked;
                }
                if (row < range.first) break;
            }
            if (self.coverage_ranges.items.len >= coverage_range_max_count) return .untracked;
            try self.coverage_ranges.append(gpa, .{ .first = row, .end = row +| 1 });
            std.mem.sort(CoverageRange, self.coverage_ranges.items, {}, lessRange);
        }
        self.normalizeCoverage();
        return .tracked;
    }
};

pub const Store = struct {
    states: std.ArrayList(State) = .empty,
    state_index: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    desired: std.ArrayList(u32) = .empty,

    request_generation: u64 = 0,
    metadata_generation: u64 = 0,
    job_state: api.ColumnInferenceJobState = .idle,
    completed_column_count: u32 = 0,
    source_bytes_scanned: u64 = 0,
    source_bytes_budget: u64 = 0,
    rows_scanned: u64 = 0,
    rows_budget: u64 = 0,
    progress: f64 = 0.0,

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        for (self.states.items) |*state| {
            state.coverage_ranges.deinit(gpa);
        }
        self.states.deinit(gpa);
        self.state_index.deinit(gpa);
        self.desired.deinit(gpa);
    }

    pub fn find(self: *Store, column: u32) ?*State {
        const index = self.state_index.get(column) orelse return null;
        return &self.states.items[index];
    }

    pub fn findConst(self: *const Store, column: u32) ?*const State {
        const index = self.state_index.get(column) orelse return null;
        return &self.states.items[index];
    }
};
