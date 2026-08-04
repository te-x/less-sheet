//! Logical byte sources.  The mmap variant stays a direct immutable span;
//! gzip owns bounded streaming inflater sessions and restart checkpoints.

const std = @import("std");
const api = @import("api");

const flate = std.compress.flate;
const Reader = std.Io.Reader;
const Decompress = flate.Decompress;
const posix = std.posix;
const sysio = @import("sysio.zig");

const net_source = @import("net_source.zig");
/// The network `http_range` Source state (ARCH-network-source) — a genuinely
/// random-access byte provider peer to mmap/gzip, defined in net_source.zig.
pub const HttpRange = net_source.HttpRange;

pub const chunk_bytes: usize = 256 * 1024;
pub const checkpoint_interval: u64 = 32 * 1024 * 1024;
const open_bytes: usize = @intCast(api.open_head_max_bytes);

/// The deepest LOOKAHEAD any lexer issues past its read cursor — ONE named knob
/// with exactly three consumers: `Cursor.look`'s capacity (the peek buffer),
/// `csv_reader.streamUnit`'s `peek()` (the only max-width peek caller: a 4-byte
/// UTF-16 surrogate pair), and the FRONTIER COMMIT GUARD (`Source.commitBound`),
/// which must know it EXACTLY. Widening a peek without widening this would let
/// the guard commit a row whose lookahead is un-fetched — the wedge it exists to
/// prevent — so all three read this const and none writes `4`.
pub const max_lookahead: usize = 4;

pub const Mmap = struct { bytes: []const u8, physical_base: u64 = 0 };
pub const SourceKind = enum { mmap, gzip };

// ---------------------------------------------------------------------------
// THE FETCH PERMIT (security-hardening (e) AC-e1 residual, cell `net_gz_wedge`)
// ---------------------------------------------------------------------------
// The last unbounded route in the signed ARCH (ARCH-security-hardening :444-449)
// is `produce`'s compressed READ-AHEAD: it calls
// `ensureCompressed(s.input.seek + chunk_bytes)` on EVERY inflate op — a fixed
// 256 KiB read-ahead, not a demand the row needs — so a network gzip re-lex on
// the FOREGROUND lane (`ls_window_set` / `ls_cell` / `ls_cell_copy` / nav) issues
// a ranged GET on the UI thread, however far behind the frontier it sits. A slow
// or silent peer then wedges the document: every poll, cancel and `ls_close`
// blocks behind the same lane and the same document mutex.
//
// A commit-side bound cannot cover it (see `Source.commitGuarded`): the demand is
// not a function of where the frontier committed. So the cure is the OTHER half of
// the same idiom the frontier-commit guard already uses — `commitBound` vs
// `commitBoundNoFetch`, a path that MAY block vs one that reads only what is
// present — lifted from "which function did you call" to "who is calling":
//
//   THE DESIGNATED FETCHER FETCHES; THE FOREGROUND READ LANE DOES NOT.
//
// The permit is AMBIENT (thread-local) rather than a parameter because the
// discriminator is the CALL STACK, not the data: `cursorAt` / `scanCursorAt` /
// `sourceCursorAt` and the whole `Reader`/`csv_reader` layer under them are shared
// verbatim between the scan worker and the window lane (and `sourceCursorAt`'s
// signature is frozen — contracts/api.zig:687 — so it could not carry a flag
// anyway). Threading a bool through ~12 cursor construction sites would have to
// re-decide the same question at each of them; this decides it once, where the
// thread's ROLE is known.
//
// DEFAULT DENY, and that direction is the point: a scope that forgets to opt in
// declines to fetch, which shows up as a frontier that stops advancing — loud,
// and covered by existing tests (netgz1 itself asserts `landed > 100_000`).
// Default-allow would fail the other way: a forgotten mutex-held path wedges the
// UI silently. Only LOCAL gzip and mmap are unaffected either way (no provider,
// so no permission question is ever asked).
//
// The permit costs ONE thread-local load per NETWORK-gzip inflate op and nothing
// at all for a local one (`produce` only reads it inside `if (self.provider)`).
threadlocal var fetch_permit: bool = false;

/// Whether the CURRENT thread is a designated fetcher — the ONE resolver every
/// blocking-vs-present decision in the gzip feed reads. See the block comment
/// above `fetch_permit`.
pub fn fetchPermitted() bool {
    return fetch_permit;
}

/// Open a designated-fetcher scope on THIS thread; pass the returned token to
/// `endFetchPermit`. Nested/re-entrant by construction (it saves and restores
/// rather than clearing), so a scope inside a scope is harmless.
///
/// Thread-local, so it is NOT inherited by a thread or `io.concurrent` task
/// spawned inside the scope — every fetcher body opens its own (see
/// `index.workerMain`, `net.runFake`, `net.realWorker`).
pub fn beginFetchPermit() bool {
    const prev = fetch_permit;
    fetch_permit = true;
    return prev;
}

pub fn endFetchPermit(prev: bool) void {
    fetch_permit = prev;
}

const Terminal = enum { inflating, clean, damaged, budget };
const PhysicalMark = struct { logical_end: u64, physical_end: u64 };
const checkpoint_ram_budget: usize = 4 * 1024 * 1024;
const max_checkpoint_entries: usize = 64 * 1024;

/// The inflater's INPUT reader (security-hardening (b), AC-b1/AC-b2): a
/// `Reader.fixed` over the compressed mapping in every respect EXCEPT that
/// running out of bytes is reported as `error.ReadFailed` instead of
/// `error.EndOfStream`. That single difference is what makes it safe to feed a
/// TRUNCATED or not-yet-complete stream to `std.compress.flate` at all.
///
/// WHY. Zig 0.16.0's `Decompress` is not safe against running out of input
/// mid-symbol, but the unsoundness is narrow and exactly locatable:
///   * `decodeSymbol` peeks via `peekBitsShort`, whose ENDING path zero-pads with
///     no length check, and commits via `tossBitsShort`, whose guard reads
///     `bufferedLen()*8 + consumed_bits < n` where the available bits are
///     `bufferedLen()*8 - consumed_bits`. With that sign wrong the toss is
///     allowed when the bits are not there, and it either tosses past
///     `input.end` (tripping `Reader.toss`'s `seek <= end` assertion) or leaves
///     the reader EMPTY with `consumed_bits != 0`;
///   * the next `peekBitsEnding` then evaluates `0 * 8 - consumed_bits` and
///     panics with `integer overflow` (Decompress.zig:540; ReleaseSafe reports
///     :548 because it merges the two overflow traps of the inlined `takeBits`).
/// A ReleaseSafe panic IS a crash, and every truncated / withheld / dropped
/// stream reached it.
///
/// Everything else is already sound: `takeBits`/`peekBits` check correctly, so
/// FIXED blocks (`readFixedCode` is pure `takeIntBits`), the extra-bit reads and
/// every byte-aligned header/footer read cannot cause any of this. Only
/// `tossBitsShort` — `decodeSymbol` and the dynamic-header codegen decoder — can.
///
/// THE CURE. Both `peekBits` and `peekBitsShort` begin with
/// `d.input.peekInt(u32, .little)` and switch on its error:
/// `error.ReadFailed => error.ReadFailed`, `error.EndOfStream => <ending path>`.
/// So ReadFailed SHORT-CIRCUITS before either ending path — `peekBitsEnding`,
/// `peekBitsShortEnding` and the wrong-signed `tossBitsShort` all become
/// unreachable. `endingOrRefuse` returns exactly that at the boundary where the
/// ending paths stop being safe, and plain `EndOfStream` above it, so a truncated
/// member is still decoded down to its last usable bits (which is what `gz_ac9`,
/// `gz_ac10` and `flate_b1`'s byte-for-byte sweep measure).
///
/// It costs NOTHING on the streaming path: a vtable entry is only ever reached
/// once the buffered bytes run out, which is precisely the case that used to
/// crash. And it invents NO input — no padding — so `produce` never has to guess
/// which of the decoder's output bytes are real.
const refusing_vtable: Reader.VTable = .{
    .stream = refuseStream,
    .discard = refuseDiscard,
    .readVec = refuseReadVec,
    .rebase = refuseRebase,
};

/// The ONE end-of-input answer, and the ONE place the safety rule lives.
///
/// `EndOfStream` hands `Decompress` its ending paths; `ReadFailed` locks them out.
/// Two hazards, and each is refused over exactly the states it can occur in — no
/// wider, because every bit held back at the end of a truncated member can cost a
/// whole match's worth of output (up to 258 bytes).
///
///  (1) EVERY state: `buffered == 0` with bits already consumed from the (now
///      absent) current byte. `peekBitsEnding` computes
///      `buffered * 8 - consumed_bits` in usize and underflows — the
///      `integer overflow` panic. With `consumed_bits == 0` it evaluates to 0 and
///      is fine, and that case must stay open: a zero-extra-bit length or
///      distance code is a `takeBits(0)`, which needs no bits at all.
///
///  (2) DYNAMIC-SYMBOL states only: fewer than a full 15-bit code's worth of real
///      bits left. `tossBitsShort` admits any `n <= 8 + consumed_bits` (its guard
///      adds where it must subtract), so below that it both decodes symbols out of
///      `peekBitsShortEnding`'s zero padding and can toss past `input.end`
///      (tripping `Reader.toss`'s `seek <= end` assertion). It is the ONLY unsound
///      reader in `Decompress`, and it has just two call sites — `decodeSymbol`
///      and the code-length loop of a dynamic block header — so `.fixed_block*`
///      (`readFixedCode` is pure `takeIntBits`), `.stored_block` (byte-oriented),
///      the protocol FOOTER and the extra-bit reads of a match are all exempt and
///      keep decoding to the last bit. The protocol HEADER state is NOT exempt;
///      see `tossesShort` for why the stored tag and the code path differ there.
///
/// MEASURED both ways. Applying (2) everywhere truncates `gz_ac10`'s fixed-block
/// salvage from two rows to one; NOT applying it decoded a bogus match out of the
/// padding and served 14 bytes of garbage mid-document (`flate_b1` fixture B,
/// cut 16891: row 3698 came back `"0000307386"` where the document says
/// `"00003698"`). Scoped as below, both are right: that cut stops at the honest
/// prefix `"00003"` and `gz_ac10` keeps both rows.
///
/// The state test reads `Decompress.state`'s TAG by name. That is a deliberate,
/// COMPILE-CHECKED coupling to std: if a Zig bump renames or restructures these
/// states this stops building rather than silently going unsound.
fn endingOrRefuse(r: *Reader) Reader.Error {
    const s: *Session = @alignCast(@fieldParentPtr("input", r));
    const buffered: usize = r.end - r.seek;
    const consumed_bits: usize = s.dec.consumed_bits;
    if (buffered == 0 and consumed_bits > 0) return error.ReadFailed; // (1)
    const max_code_bits: usize = 15; // deflate's longest Huffman code
    if (tossesShort(s.dec.state) and buffered * 8 < max_code_bits + consumed_bits)
        return error.ReadFailed; // (2)
    return error.EndOfStream;
}

/// Whether `Decompress` in this state can reach `tossBitsShort` (see
/// `endingOrRefuse` (2)). DEFAULT-DENY: the switch below is exhaustive and has NO
/// `else`, so a Zig bump that ADDS a state breaks this build instead of silently
/// defaulting it to permissive. An `else => false` form only appears to have that
/// property — it catches a RENAME but waves through an ADDITION, which is the
/// likelier churn and the direction that costs correctness.
///
/// The gate tests the STORED tag, not the code path, and the two differ in two
/// ways that each cost real correctness:
///
///   * `.protocol_header` is NOT exempt, though the header's own byte reads are.
///     `Decompress.init` stores it, and `Session.init` / `nextMember` call `init`
///     once per member, so it stays the live tag for the whole of a member's
///     FIRST block — including the code-length loop of a dynamic header and the
///     literal/match symbol loop. Exempting it disabled (2) across every
///     single-block fixture in the suite.
///   * `.dynamic_block` is never STORED at all: entry into a block is a bare
///     `continue :sw` that assigns nothing, so the tag lags all the way back to
///     `init`. It is listed as refusing for exhaustiveness, not because it can be
///     observed.
///
/// The tag LAGS in general: `streamInner` assigns only where it returns, so a
/// dynamic block that last stopped mid-match still reads `.dynamic_block_match`
/// while decoding its next symbols. Every state a dynamic block can RESUME from
/// therefore counts. State the rule as: exempt is the set that can only ever be
/// stored while a SOUND reader is active; everything else refuses.
///
/// MEASURED, both directions. Exempting the stored `.protocol_header` served a
/// bogus symbol decoded out of `peekBitsShortEnding`'s zero padding — `flate_b1`
/// fixture A cut 50 returned row 5 as `"00000003"` where the document says
/// `"00000005"`, in a single final DYNAMIC block — and fixture B cut 16891 served
/// 14 bytes of garbage the same way (`"0000307386"` for `"00003698"`). Refusing
/// costs at most one symbol's worth of salvage at the end of a damaged member
/// (`gz_ac10`'s two bytes); permitting costs a garbage decode or a `Reader.toss`
/// assert panic. The project bar decides that direction.
fn tossesShort(state: anytype) bool {
    return switch (std.meta.activeTag(state)) {
        // Exempt: reachable only via byte-oriented or `takeIntBits` reads that
        // cannot under-run -- `readFixedCode`, stored blocks, the protocol footer
        // bytes, and `.end`.
        .fixed_block, .fixed_block_literal, .fixed_block_match, .stored_block, .protocol_footer, .end => false,
        // Everything else can reach `tossBitsShort`.
        .protocol_header, .block_header, .dynamic_block, .dynamic_block_literal, .dynamic_block_match => true,
    };
}

fn refuseStream(r: *Reader, w: *std.Io.Writer, limit: std.Io.Limit) Reader.StreamError!usize {
    _ = w;
    _ = limit;
    return endingOrRefuse(r);
}

fn refuseReadVec(r: *Reader, data: [][]u8) Reader.Error!usize {
    _ = data;
    return endingOrRefuse(r);
}

fn refuseDiscard(r: *Reader, limit: std.Io.Limit) Reader.Error!usize {
    _ = limit;
    return endingOrRefuse(r);
}

fn refuseRebase(r: *Reader, capacity: usize) Reader.RebaseError!void {
    _ = capacity;
    return endingOrRefuse(r); // the buffer IS the mapping; it never moves
}

/// `Reader.fixed(mapping)` with `refusing_vtable` (see it for why).
fn refusingReader(mapping: []const u8) Reader {
    return .{
        .vtable = &refusing_vtable,
        // Const-cast is safe for the same reason `Reader.fixed`'s is: every
        // vtable entry refuses, so nothing can write through it.
        .buffer = @constCast(mapping),
        .end = mapping.len,
        .seek = 0,
    };
}

const Session = struct {
    input: Reader,
    /// The ABSOLUTE physical offset a lane budget caps this session's fence at, or
    /// null for an uncapped session. It lives here, beside the `input.end` it
    /// bounds, because `produce` re-raises that fence on every provider op and has
    /// to re-apply the cap each time (see `produce`). A SIZE cannot live here: the
    /// budget is anchored at the seek the lane was leased at, and `input.seek`
    /// moves.
    fence_cap: ?usize,
    history: [flate.max_window_len]u8,
    dec: Decompress,
    logical: u64,
    member_count: u32,
    terminal: Terminal,

    fn init(self: *Session, mapping: []const u8, physical_end: usize) void {
        @memset(&self.history, 0);
        self.input = refusingReader(mapping);
        self.input.end = @min(mapping.len, physical_end);
        self.fence_cap = null;
        self.logical = 0;
        self.member_count = 0;
        self.terminal = .inflating;
        self.dec = Decompress.init(&self.input, .gzip, &self.history);
    }

    fn repair(self: *Session) void {
        self.dec.input = &self.input;
        self.dec.reader.buffer = &self.history;
    }
};

const CheckpointEntry = struct {
    logical: u64,
    physical: u64,
    file_offset: ?u64,
    hot: ?*Checkpoint,
};

const Checkpoint = struct {
    logical: u64,
    input: Reader,
    history: [flate.max_window_len]u8,
    dec: Decompress,
    member_count: u32,
    terminal: Terminal,

    fn capture(self: *Checkpoint, s: *const Session) void {
        self.logical = s.logical;
        self.input = s.input;
        self.history = s.history;
        self.dec = s.dec;
        self.member_count = s.member_count;
        self.terminal = s.terminal;
        self.dec.input = &self.input;
        self.dec.reader.buffer = &self.history;
    }

    fn restore(self: *const Checkpoint, s: *Session) void {
        s.input = self.input;
        s.history = self.history;
        s.dec = self.dec;
        s.logical = self.logical;
        s.member_count = self.member_count;
        s.terminal = self.terminal;
        s.repair();
    }
};

pub const Gzip = struct {
    gpa: std.mem.Allocator,
    mapping: []const u8,
    /// never-full-download-streaming (TD4): the compressed-byte provider for a
    /// NETWORK gzip. When set, `mapping` is the http_range spool's stable base;
    /// the inflater fetches compressed bytes on demand via `provider` and its
    /// physical end comes from the provider (present high-water = a resumable
    /// budget stop; stream EOF = the clean/damaged terminal), NOT `mapping.len`.
    /// null for a LOCAL gzip (mapping.len IS the end — byte-identical).
    provider: ?*net_source.HttpRange = null,
    mutex: sysio.Mutex = .init,
    cond: sysio.Condition = .init,
    forward: *Session,
    replay: *Session,
    replay2: *Session,
    checkpoints: std.ArrayList(CheckpointEntry) = .empty,
    spill_snapshot: *Checkpoint,
    spill_snapshot2: *Checkpoint,
    hot_checkpoint_bytes: usize = 0,
    head: std.ArrayList(u8) = .empty,
    lane_buf: [3][chunk_bytes]u8 = undefined,
    op_start: [3]u64 = @splat(0),
    op_len: [3]usize = @splat(0),
    op_replay: [3]bool = @splat(false),
    op_physical: [3]u64 = @splat(0),
    lane_busy: [3]bool = @splat(false),
    lane_physical_budget: [3]?u64 = @splat(null),
    forward_logical: std.atomic.Value(u64) = .init(0),
    forward_physical: std.atomic.Value(u64) = .init(0),
    terminal_end: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    terminal_kind: std.atomic.Value(u8) = .init(0), // 0 unknown, 1 clean, 2 damaged
    bom_len: u64 = 0,
    shutdown: std.atomic.Value(bool) = .init(false),
    opening: bool = true,
    force_chunk: std.atomic.Value(u64) = .init(0),
    replay_landed: bool = false,
    replay_restored: u64 = 0,
    replay_inflated: u64 = 0,
    open_physical: u64 = 0,
    open_inflated: u64 = 0,
    /// gz-filter-stream regression seams (api.gzInflatedBytes / api.gzInflateOps):
    /// cumulative inflated OUTPUT bytes AND inflate OPERATIONS (produce calls)
    /// since the last reset. A trailing FILTER/SEARCH scan that STREAMS forward
    /// inflates O(logical) bytes in O(logical/chunk) ops; the shipped trailing
    /// scan cannot serve a byte behind the forward session's over-produced
    /// position, so it LIVELOCKS -- spinning 0-byte produce calls forever (ops
    /// grow UNBOUNDED while bytes plateau). ops is thus the deterministic
    /// regression signal. Reset via root.gzInflateWorkReset.
    inflated_total: std.atomic.Value(u64) = .init(0),
    inflate_ops: std.atomic.Value(u64) = .init(0),
    spill_fd: ?posix.fd_t = null,
    spill_bytes: u64 = 0,
    spill_ops: u64 = 0,
    spill_fail_after: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    head_marks: [open_bytes / chunk_bytes + 1]PhysicalMark = undefined,
    head_mark_count: usize = 0,

    pub fn lock(self: *Gzip) void {
        self.mutex.lockUncancelable(sysio.io());
    }
    pub fn unlock(self: *Gzip) void {
        self.mutex.unlock(sysio.io());
    }

    fn init(gpa: std.mem.Allocator, mapping: []const u8) !*Gzip {
        const self = try gpa.create(Gzip);
        errdefer gpa.destroy(self);
        const f = try gpa.create(Session);
        errdefer gpa.destroy(f);
        const r = try gpa.create(Session);
        errdefer gpa.destroy(r);
        const r2 = try gpa.create(Session);
        errdefer gpa.destroy(r2);
        const spill_snapshot = try gpa.create(Checkpoint);
        errdefer gpa.destroy(spill_snapshot);
        const spill_snapshot2 = try gpa.create(Checkpoint);
        errdefer gpa.destroy(spill_snapshot2);
        self.* = .{ .gpa = gpa, .mapping = mapping, .forward = f, .replay = r, .replay2 = r2, .spill_snapshot = spill_snapshot, .spill_snapshot2 = spill_snapshot2 };
        f.init(mapping, @min(mapping.len, open_bytes));
        r.init(mapping, @min(mapping.len, open_bytes));
        r2.init(mapping, @min(mapping.len, open_bytes));
        try self.head.ensureTotalCapacity(gpa, open_bytes);
        try self.inflateOpenHead();
        return self;
    }

    /// never-full-download-streaming (TD4): build a gzip Source that inflates the
    /// COMPRESSED bytes served on demand by `provider` (an http_range spool). The
    /// spool's stable base is the `mapping`; the physical end comes from the
    /// provider, so `mapping.len` (a presized total, or the huge unknown-length
    /// reservation) is NOT the terminal. `provider` is owned by the returned Gzip
    /// on success (deinit frees it); on any failure the CALLER frees `provider`.
    fn initProvider(gpa: std.mem.Allocator, provider: *net_source.HttpRange) !*Gzip {
        const self = try gpa.create(Gzip);
        errdefer gpa.destroy(self);
        const f = try gpa.create(Session);
        errdefer gpa.destroy(f);
        const r = try gpa.create(Session);
        errdefer gpa.destroy(r);
        const r2 = try gpa.create(Session);
        errdefer gpa.destroy(r2);
        const spill_snapshot = try gpa.create(Checkpoint);
        errdefer gpa.destroy(spill_snapshot);
        const spill_snapshot2 = try gpa.create(Checkpoint);
        errdefer gpa.destroy(spill_snapshot2);
        const mapping = provider.spool;
        self.* = .{ .gpa = gpa, .mapping = mapping, .provider = provider, .forward = f, .replay = r, .replay2 = r2, .spill_snapshot = spill_snapshot, .spill_snapshot2 = spill_snapshot2 };
        // input.end starts at 0; `produce` refreshes it from the provider's
        // present compressed high-water before every read (never past fetched).
        f.init(mapping, 0);
        r.init(mapping, 0);
        r2.init(mapping, 0);
        try self.head.ensureTotalCapacity(gpa, open_bytes);
        try self.inflateOpenHead();
        return self;
    }

    fn deinit(self: *Gzip) void {
        for (self.checkpoints.items) |entry| if (entry.hot) |cp| self.gpa.destroy(cp);
        self.checkpoints.deinit(self.gpa);
        self.head.deinit(self.gpa);
        if (self.spill_fd) |fd| sysio.close(fd);
        self.gpa.destroy(self.forward);
        self.gpa.destroy(self.replay);
        self.gpa.destroy(self.replay2);
        self.gpa.destroy(self.spill_snapshot);
        self.gpa.destroy(self.spill_snapshot2);
        // std.Io.Mutex/Condition need no explicit destroy (unlike pthread_*_destroy).
        if (self.provider) |hr| hr.deinit(); // network gzip owns its compressed spool
        self.gpa.destroy(self);
    }

    /// The physical (compressed) END of the stream: the provider's known total
    /// (or `maxInt` while an unknown-length stream has not hit EOF) for a network
    /// gzip; `mapping.len` for a local one. Replaces `mapping.len`-as-end so a
    /// growing/on-demand spool is never mistaken for the terminal (TD4).
    fn physicalLen(self: *const Gzip) u64 {
        if (self.provider) |hr| return hr.physicalTotal() orelse std.math.maxInt(u64);
        return self.mapping.len;
    }

    /// Whether a stop at `fence` is RESUMABLE — i.e. whether that fence can still
    /// MOVE. Two ways it can: it is an artificial fence below the physical total
    /// (the open-head budget or a lane budget, both lifted later), and, for a
    /// network gzip, the provider can still deliver. Once the peer ends the body
    /// SHORT of the length it advertised the fence is frozen, and parking on it
    /// waits forever for bytes that stopped arriving — the dropped-stream case.
    ///
    /// Distinct from `sourceAwaitsBytes` on purpose; see that function.
    ///
    /// `may_fetch` is `produce`'s already-resolved fetch permit (see
    /// `fetchPermitted`), passed in rather than re-read so ONE thread-local load
    /// serves the whole inflate op. It matters here because a fence this call
    /// DECLINED to move is movable BY DEFINITION — the designated fetcher can
    /// still move it — and answering `false` for it would let a foreground read
    /// publish `.damaged`, which `produce` stores into `terminal_kind`: the
    /// DOCUMENT-GLOBAL terminal. A read lane's local decision not to fetch would
    /// then truncate the whole document (silent wrong data, the exact failure the
    /// standing bar forbids). Parking `.budget` instead is the honest answer:
    /// "these bytes are not here yet", which is what `.budget` already means.
    fn fenceCanMove(self: *const Gzip, fence: usize, may_fetch: bool) bool {
        if (fence >= self.physicalLen()) return false;
        const hr = self.provider orelse return true;
        if (may_fetch) return hr.awaitsBytes();
        // NO PERMIT. "Can this fence move?" is then NOT only a question about the
        // peer, because the reason we are sitting at it is that WE declined to move
        // it. It is also a question about whether the designated fetcher has settled
        // the stream yet, and `terminal_kind` is exactly that fact.
        //
        // STRICT RELAXATION, and that shape is the load-bearing part: the answer is
        // the permitted answer `OR` one more reason to park, so it is `true`
        // WHEREVER the fetching path would say `true`, and sometimes where it would
        // say `false`. `resumable` is therefore never LESS true than before this
        // change, so a permit-less op can only ever turn a `.damaged` this code
        // already produced into a recoverable `.budget` — it can never create a
        // `.damaged` that did not occur before. That is what keeps a foreground read
        // from stranding a session it does not own, INCLUDING lane 0's shared
        // forward session (`cursorAt` routes a read with `internal >=
        // forward_logical` there), whose `.damaged` would stop the frontier and
        // whose `.budget` self-heals in `produce` the moment the fence rises.
        // The two reasons to park:
        //   * NOT settled -> movable: park `.budget` and wait. Anything else would
        //     let a foreground read call an end that only a fetch could disprove —
        //     on a HEALTHY peer, where every declined read-ahead sits one chunk
        //     below a present edge the scan will raise moments later. That is the
        //     truncated-document / poisoned-lane failure, and it is silent.
        //   * SETTLED -> this edge IS the end, so classify it exactly as the scan
        //     did. That matters for correctness, not just tidiness: when the peer
        //     refused the tail, the scan's LAST inflate step ran out of input
        //     mid-symbol and `inflateStep` KEPT its output (those bytes came from
        //     real bits), and the frontier committed rows out of it. A resumable
        //     park here would UNDO that step instead, so a behind-frontier re-lex
        //     could not re-serve rows the frontier had already published —
        //     measured: `netgz1`'s `landed - 64` came back as an empty cell.
        return hr.awaitsBytes() or self.terminal_kind.load(.acquire) == 0;
    }

    fn physical(s: *const Session) u64 {
        return s.input.seek;
    }

    fn nextMember(self: *Gzip, s: *Session, fence: usize) bool {
        s.member_count += 1;
        const at = s.input.seek;
        const phys_len = self.physicalLen();
        if (at == phys_len) {
            s.terminal = .clean;
            return false;
        }
        if (at + 2 > fence) {
            s.terminal = if (fence < phys_len) .budget else .damaged;
            return false;
        }
        if (self.mapping[at] != 0x1f or self.mapping[at + 1] != 0x8b) {
            s.terminal = .damaged;
            return false;
        }
        s.dec = Decompress.init(&s.input, .gzip, &s.history);
        return true;
    }

    /// ONE inflate step: exactly one `Decompress` fill. Callers must have drained
    /// the history first (asserted), which is what makes dropping a step a single
    /// assignment on the output side.
    ///
    /// It never leaves the session both `.inflating` and unadvanced, so
    /// `produce`'s loop always terminates.
    fn inflateStep(self: *Gzip, s: *Session, fence: usize, resumable: bool) void {
        const r = &s.dec.reader;
        std.debug.assert(r.seek == r.end); // drained: dropping a step == `end = seek`
        const snap_dec = s.dec;
        const snap_seek = s.input.seek;

        r.fillMore() catch |err| switch (err) {
            // `.end` reached: this member decoded through its footer. std reports
            // that WITHOUT setting `dec.err`, which is what leaves `dec.err` as
            // the sole "the decoder failed" discriminator below.
            error.EndOfStream => {},
            error.ReadFailed => {}, // why is in `s.dec.err`
        };

        // No output needs vetting here: `endingOrRefuse` never lets the decoder
        // consume a bit it does not have, so every byte it emitted is backed by
        // the stream (the alternative — padding, and then guessing which output
        // bytes were real — is what that rule exists to avoid).

        // The input reader turned the decoder away: it wanted a byte we do not
        // have, whether that was reported as a refusal or a plain end of stream
        // (see `endingOrRefuse`). Everything emitted before that came from bytes
        // it was actually given, so there is nothing else to distrust or trim.
        const out_of_input = if (s.dec.err) |e|
            (e == error.ReadFailed or e == error.EndOfStream)
        else
            false;

        if (out_of_input and resumable) {
            // "NOT YET ARRIVED" — the fence is an ARTIFICIAL one: the open head
            // budget, a Cursor's physical budget, or a network provider's fetched
            // high-water. std cannot resume a decoder it stopped MID-SYMBOL: it
            // re-enters at `dec.state` having already tossed that symbol's bits,
            // decodes a different symbol from the wrong bit offset, and serves
            // wrong rows (a withheld-tail jump used to land ~145k rows early).
            // So undo the step WHOLE and park resumably. Nothing is lost — the
            // same bytes are simply re-decoded once the fence moves — and the
            // restored snapshot makes that resume byte-exact.
            const at = r.seek; // post-rebase history coordinates
            s.dec = snap_dec;
            s.dec.input = &s.input;
            s.dec.reader.buffer = &s.history;
            s.dec.reader.seek = at;
            s.dec.reader.end = at; // this step's output dropped
            s.input.seek = snap_seek;
            s.terminal = .budget;
            return;
        }
        if (s.dec.err != null) {
            // The step FAILED — out of input at the TRUE end ("NEVER ARRIVING"), or
            // a structural failure in bytes we do have (InvalidCode, a bad match, a
            // broken header). Either way this session is finished, and that has to
            // be decided BEFORE any "it produced bytes, so keep going" shortcut:
            // `streamFallible` leaves `dec.state` UNMODIFIED on error, so a step
            // that stopped in `.dynamic_block_literal` / `.dynamic_block_match`
            // re-emits its SAVED literal or match on every later step while
            // consuming no input at all. Re-entering it emits one byte per step
            // forever — MEASURED on `flate_b2b`'s dropped stream: 256 KiB of a
            // single duplicated byte per produce op, `input.seek` frozen 2 bytes
            // short of the fence, so the document grew phantom rows past its true
            // end (4 MiB of head out of a 3.6 MB document) and NEVER became
            // terminal. Whatever this step did emit was decoded from real bits, so
            // it is kept; what must not happen is another step.
            s.terminal = .damaged;
            return;
        }
        if (r.end > r.seek) return; // decoded bytes: progress, and all of them keepable
        // Zero bytes and no failure: the member is finished (an EMPTY member
        // produces exactly this on its first step). Where the old feed keyed on
        // `readSliceShort` returning 0, this keys on the decoder not failing —
        // `nextMember` still decides clean / next-member / damaged.
        _ = self.nextMember(s, fence);
    }

    /// Whether THIS thread may publish `terminal_kind`/`terminal_end` — the
    /// DOCUMENT-GLOBAL terminal, which becomes `terminalLogical()` and hence
    /// `Source.len` / `knownEnd`.
    ///
    /// A terminus reached at the stream's PHYSICAL end is fetch-independent, so any
    /// thread may publish it (and `.clean` is only ever set there — `nextMember`
    /// requires `at == physicalLen()`, so a clean end is never suppressed). A
    /// terminus reached at an ARTIFICIAL fence that this thread DECLINED to move is
    /// not ours to draw: the store would republish an end computed from a replay
    /// lane's own position, and could only ever move the document's end DOWN — a
    /// truncation caused by a read. Only the designated fetcher, which did move the
    /// fence as far as the peer allows, is entitled to that conclusion.
    ///
    /// Called ONLY from the two terminal arms below (once or twice in a document's
    /// life), never per inflate op — which is why the permit is re-read here instead
    /// of being kept live across `produce`'s hot drain loop.
    fn mayPublishTerminal(self: *const Gzip, fence: usize) bool {
        if (fence >= self.physicalLen()) return true;
        return self.provider == null or fetchPermitted();
    }

    /// Produce at most `out.len` bytes.  A physical artificial end is a
    /// resumable budget stop; a real decoder/end-of-input failure is a stable
    /// damaged end once useful bytes exist.
    fn produce(self: *Gzip, s: *Session, out: []u8) usize {
        _ = self.inflate_ops.fetchAdd(1, .monotonic); // gz-filter-stream: count EVERY inflate op (0-byte spins included)
        if (out.len == 0 or self.shutdown.load(.acquire)) return 0;
        // Network gzip (TD4): fetch compressed bytes ahead of the read cursor and
        // lift a resumable budget stop when more arrived. The inflater consumes
        // compressed bytes strictly forward; checkpoint replay only reads already-
        // present bytes, so a single forward fetch high-water suffices.
        // LOCAL gzip: no provider, so no permission question is ever asked and
        // this stays `true` at zero cost (the thread-local is not even read).
        var may_fetch = true;
        if (self.provider) |hr| {
            // THE FETCH PERMIT (AC-e1 residual). The read-ahead below is a FIXED
            // 256 KiB look-ahead, not a demand this row needs, so on the
            // foreground read lane it is pure cost with a peer-shaped tail: one
            // ranged GET issued from `ls_window_set` / `ls_cell` / `ls_cell_copy`
            // / nav, on a lane those calls hold, several of them with the document
            // mutex held for the whole call. Resolve it ONCE per inflate op (also
            // used by `fenceCanMove` below) and read only what is PRESENT when
            // this thread is not the designated fetcher: `presentCompressed` is
            // the same answer over already-fetched bytes, issues no request, and
            // takes no lock — which matters, because `ensureCompressed` holds the
            // provider's mutex ACROSS its blocking GET, so even acquiring that
            // lock here would queue the UI behind a silent peer.
            may_fetch = fetchPermitted();
            const want = s.input.seek + chunk_bytes;
            const fetched = if (may_fetch) hr.ensureCompressed(want) else hr.presentCompressed(want);
            var raised: u64 = @min(fetched, self.mapping.len);
            // Re-apply the lane's physical cap on EVERY raise. Without this a
            // budgeted provider lane reads straight past its budget, and nothing
            // downstream catches it: `Cursor.hitPhysicalLimit` keys on the session
            // parking at `.budget`, not on a byte comparison, so an un-capped
            // fence simply never trips it.
            if (s.fence_cap) |cap| raised = @min(raised, @as(u64, cap));
            const new_end: usize = @intCast(raised);
            if (new_end > s.input.end) {
                s.input.end = new_end;
                if (s.terminal == .budget) {
                    s.dec.err = null;
                    s.terminal = .inflating;
                }
            }
        }
        // THE HONEST EDGE: the last byte this session may treat as content —
        // `input.end` exactly as every other site sets it (the open fence, a
        // Cursor's physical budget, the provider's fetched high-water, or the
        // mapping's true end). `resumable` is the whole of "not yet arrived" vs
        // "never arriving": an edge SHORT of the physical total is one that can
        // still move, so a stop there parks and waits; an edge AT the total is
        // the end of the stream, so a stop there is terminal.
        const fence = s.input.end;
        const resumable = self.fenceCanMove(fence, may_fetch);

        var written: usize = 0;
        while (written < out.len) {
            // Drain FIRST, and only ever from the decoder's own history reader:
            // `readSliceShort` copies bytes into the destination and then DROPS
            // its count if a later step fails (Reader.zig:688 returns
            // `error.ReadFailed`, not the partial `i`), which used to leave the
            // salvage writing the next decoded bytes over the ones already there
            // — a complete, exact, WRONG document. Nothing here can lose a byte.
            const avail = s.dec.reader.buffered();
            if (avail.len > 0) {
                const take = @min(avail.len, out.len - written);
                @memcpy(out[written..][0..take], avail[0..take]);
                s.dec.reader.toss(take);
                written += take;
                s.logical += take;
                if (s == self.forward) self.forward_logical.store(s.logical, .release);
                continue;
            }
            if (s.terminal != .inflating) break;
            self.inflateStep(s, fence, resumable);
        }
        if (s == self.forward) {
            self.forward_logical.store(s.logical, .release);
            self.forward_physical.store(s.input.seek, .release);
        }
        // A retained trailing-scan session may reach the real end before the
        // shared forward session.  Real EOF is source-global knowledge; only
        // an artificial physical budget stop remains lane-local.
        switch (s.terminal) {
            .clean => if (self.mayPublishTerminal(fence)) {
                self.terminal_kind.store(1, .release);
                self.terminal_end.store(s.logical, .release);
            },
            .damaged => if (self.mayPublishTerminal(fence)) {
                self.terminal_kind.store(2, .release);
                self.terminal_end.store(s.logical, .release);
            },
            else => {},
        }
        _ = self.inflated_total.fetchAdd(@intCast(written), .monotonic); // gz-filter-stream: inflated output bytes
        return written;
    }

    fn inflateOpenHead(self: *Gzip) !void {
        while (self.head.items.len < open_bytes and self.forward.terminal == .inflating) {
            const old = self.head.items.len;
            const want = @min(chunk_bytes, open_bytes - old);
            try self.head.resize(self.gpa, old + want);
            const n = self.produce(self.forward, self.head.items[old .. old + want]);
            self.head.shrinkRetainingCapacity(old + n);
            if (n > 0 and self.head_mark_count < self.head_marks.len) {
                self.head_marks[self.head_mark_count] = .{ .logical_end = self.forward.logical, .physical_end = self.forward.input.seek };
                self.head_mark_count += 1;
            }
            if (n == 0) break;
        }
        self.open_physical = @min(self.forward.input.seek, api.open_head_max_bytes);
        self.open_inflated = self.head.items.len;
    }

    fn finishOpen(self: *Gzip) void {
        self.lock();
        defer self.unlock();
        self.opening = false;
        // Every forward session starts with the independent physical-open
        // fence, even when the inflated-output fence is reached first.  Once
        // all open-time parsing is complete the physical fence must always be
        // lifted; otherwise a high-expansion member eventually mistakes that
        // artificial end for a damaged/terminal gzip end. For a NETWORK gzip the
        // physical fence is the fetched compressed high-water (refreshed every
        // `produce` from the provider) — never `mapping.len` (the presized total
        // or the huge unknown-length reservation), which would read unfetched
        // pages — so leave `input.end` at the fetched edge here (TD4).
        if (self.provider == null) self.forward.input.end = self.mapping.len;
        if (self.forward.terminal == .budget) {
            self.forward.dec.err = null;
            self.forward.terminal = .inflating;
        }
    }

    /// Whether the open-time inflate produced a document worth serving: ANY output,
    /// or any member seen. Nothing about row completeness is asserted here.
    ///
    /// A stricter rule lived here briefly — a damaged stream also had to carry a
    /// row terminator, so a salvage shorter than one row could not present a
    /// truncated cell as a whole one. It was removed as part of the adjudicated
    /// CHANGE-REQUEST (`review/REVIEW-flate-feed-guard.md`): it answered the
    /// partial-tail question one salvage-end EARLIER than, and opposite to, the way
    /// the tail itself is served, and it turned a single-row garbage salvage into a
    /// clean `LS_ERROR_IO`, making that case unfalsifiable in exactly the region
    /// where a mid-symbol decode lands. Whole-rows-only is a product question for
    /// the architect, to be answered ONCE and applied to both ends of a salvage.
    pub fn openUsable(self: *const Gzip) bool {
        return self.head.items.len != 0 or self.forward.member_count != 0;
    }

    pub fn terminalLogical(self: *const Gzip) ?u64 {
        const end = self.terminal_end.load(.acquire);
        return if (end == std.math.maxInt(u64)) null else end -| self.bom_len;
    }

    fn createSpill(self: *Gzip) void {
        if (self.spill_fd != null or self.spill_fail_after.load(.acquire) == 0) return;
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/tmp/lesssheet-gz-{x}-{x}.ckpt", .{ sysio.uniqueToken(), @intFromPtr(self) }) catch return;
        const fd = posix.openatZ(posix.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600) catch return;
        sysio.unlinkAbsolute(path) catch {
            sysio.close(fd);
            return;
        };
        self.spill_fd = fd;
    }

    fn persistCheckpoint(self: *Gzip, cp: *const Checkpoint) ?u64 {
        if (self.spill_ops >= self.spill_fail_after.load(.acquire)) return null;
        self.createSpill();
        const fd = self.spill_fd orelse return null;
        const bytes = std.mem.asBytes(cp);
        const start = self.spill_bytes;
        sysio.file(fd).writePositionalAll(sysio.io(), bytes, start) catch return null;
        self.spill_bytes += bytes.len;
        self.spill_ops += 1;
        return start;
    }

    fn loadCheckpoint(self: *Gzip, entry: CheckpointEntry, lane: usize) ?*Checkpoint {
        if (entry.hot) |cp| return cp;
        const offset = entry.file_offset orelse return null;
        const fd = self.spill_fd orelse return null;
        const snapshot = if (lane == 2) self.spill_snapshot2 else self.spill_snapshot;
        const bytes = std.mem.asBytes(snapshot);
        const got = sysio.file(fd).readPositionalAll(sysio.io(), bytes, offset) catch return null;
        if (got != bytes.len) return null;
        snapshot.dec.input = &snapshot.input;
        snapshot.dec.reader.buffer = &snapshot.history;
        return snapshot;
    }

    fn checkpointIfDue(self: *Gzip, s: *Session) void {
        if (s != self.forward) return;
        self.lock();
        const expected = (@as(u64, self.checkpoints.items.len) + 1) * checkpoint_interval;
        self.unlock();
        if (s.logical != expected) return;
        const cp = self.gpa.create(Checkpoint) catch {
            s.terminal = .damaged;
            return;
        };
        cp.capture(s);
        const file_offset = self.persistCheckpoint(cp);
        var hot: ?*Checkpoint = cp;
        if (file_offset != null) {
            self.gpa.destroy(cp);
            hot = null;
        } else if (self.hot_checkpoint_bytes + @sizeOf(Checkpoint) <= checkpoint_ram_budget) {
            self.hot_checkpoint_bytes += @sizeOf(Checkpoint);
        } else {
            self.gpa.destroy(cp);
            s.terminal = .damaged;
            return;
        }
        self.lock();
        defer self.unlock();
        if (self.checkpoints.items.len >= max_checkpoint_entries) {
            if (hot) |h| {
                self.hot_checkpoint_bytes -= @sizeOf(Checkpoint);
                self.gpa.destroy(h);
            }
            s.terminal = .damaged;
            return;
        }
        self.checkpoints.append(self.gpa, .{
            .logical = s.logical,
            .physical = s.input.seek,
            .file_offset = file_offset,
            .hot = hot,
        }) catch {
            if (hot) |h| {
                self.hot_checkpoint_bytes -= @sizeOf(Checkpoint);
                self.gpa.destroy(h);
            }
            s.terminal = .damaged;
        };
    }

    fn fillFromSession(self: *Gzip, s: *Session, replay: bool, lane: usize) usize {
        self.op_start[lane] = s.logical;
        self.op_replay[lane] = replay;
        const next_cp = if (!replay) ((s.logical / checkpoint_interval) + 1) * checkpoint_interval else std.math.maxInt(u64);
        const allowed: usize = @intCast(@min(@as(u64, chunk_bytes), next_cp -| s.logical));
        self.op_len[lane] = self.produce(s, self.lane_buf[lane][0..allowed]);
        self.op_physical[lane] = s.input.seek;
        self.checkpointIfDue(s);
        return self.op_len[lane];
    }

    fn discardTo(self: *Gzip, s: *Session, target: u64, replay: bool, lane: usize) bool {
        while (s.logical < target) {
            const want: usize = @intCast(@min(@as(u64, chunk_bytes), target - s.logical));
            const n = self.produce(s, self.lane_buf[lane][0..want]);
            self.checkpointIfDue(s);
            if (replay) {
                self.lock();
                self.replay_inflated += n;
                self.unlock();
            }
            if (n == 0) return false;
        }
        return true;
    }

    fn beginReplay(self: *Gzip, target: u64, lane: usize) bool {
        var chosen: ?CheckpointEntry = null;
        self.lock();
        for (self.checkpoints.items) |entry| {
            if (entry.logical <= target) chosen = entry else break;
        }
        self.unlock();
        const session = if (lane == 2) self.replay2 else self.replay;
        if (chosen) |entry| {
            const cp = self.loadCheckpoint(entry, lane) orelse return false;
            cp.restore(session);
            self.lock();
            self.replay_landed = true;
            self.replay_restored = entry.logical -| self.bom_len;
            self.replay_inflated = 0;
            self.unlock();
        } else {
            // A NETWORK gzip's honest edge is the provider's FETCHED high-water,
            // never `mapping.len` — that is the presized spool total, and a
            // replay started there reads UNFETCHED spool zeros as content
            // (silent wrong data: the withheld-tail document grew rows past the
            // true count). Start at 0 exactly like `initProvider`'s forward
            // session; `produce` raises it from the provider on the first op.
            session.init(self.mapping, if (self.provider == null) self.mapping.len else 0);
            self.lock();
            self.replay_landed = target >= self.head.items.len;
            self.replay_restored = 0;
            self.replay_inflated = 0;
            self.unlock();
        }
        if (self.lane_physical_budget[lane]) |budget| {
            // Anchor the cap ABSOLUTELY, here, at the seek this replay starts from.
            // `session.input.end` is 0 for a provider (no bytes fetched into this
            // session yet), so min-ing the cap into it would store 0 and cap
            // nothing; `produce` re-applies `fence_cap` every time it raises the
            // fence from the provider's high-water instead.
            const cap: u64 = session.input.seek +| budget;
            session.fence_cap = @intCast(cap);
            session.input.end = @intCast(@min(@as(u64, session.input.end), cap));
        } else {
            session.fence_cap = null; // stated, not inferred from the lease order
        }
        self.op_len[lane] = 0;
        return self.discardTo(session, target, true, lane);
    }

    /// The inflate Session driving `lane` (0 = forward, 1 = replay, 2 = replay2)
    /// — the ONE place that mapping is resolved (it used to be re-derived
    /// inline at six call sites).
    fn sessionForLane(self: *const Gzip, lane: usize) *Session {
        return if (lane == forward_lane) self.forward else if (lane == 1) self.replay else self.replay2;
    }

    /// The forward (non-replay) inflate lane — named once so a lane-0-specific
    /// check reads as one.
    const forward_lane: usize = 0;

    /// security-hardening (e) AC-e3: whether `lane`'s inflate is parked on a
    /// RESUMABLE budget stop — it ran out of COMPRESSED bytes (`produce`:
    /// `s.input.end < physicalLen() and s.input.seek >= s.input.end`) rather than
    /// reaching a clean or damaged terminus. `.budget` deliberately leaves
    /// `terminal_kind` unset precisely because it is NOT an end-of-source: for a
    /// NETWORK gzip whose ranged fetch came back short, `ensureCompressed` cannot
    /// grow `input.end`, so the session parks here indefinitely and an empty span
    /// at this point is a STALL, never EOF.
    pub fn laneAtBudget(self: *const Gzip, lane: usize) bool {
        return self.sessionForLane(lane).terminal == .budget;
    }

    fn byteAtLane(self: *Gzip, lane: usize, internal: u64) ?u8 {
        if (internal < self.head.items.len) return self.head.items[@intCast(internal)];
        if (self.op_len[lane] > 0 and internal >= self.op_start[lane] and internal < self.op_start[lane] + self.op_len[lane])
            return self.lane_buf[lane][@intCast(internal - self.op_start[lane])];

        const replay = lane != 0;
        const s = self.sessionForLane(lane);
        if (!replay) {
            // The final `return lane_buf[lane][0]` is only correct when the
            // forward session lands EXACTLY on `internal`. Two ways it can't,
            // both routed to a replay session by returning null (the caller's
            // next cursorAt sees no forward coverage and picks lane 1/2):
            //  * over-produced PAST `internal` (and not in the op buffer — the
            //    fast path above already handled that): it cannot rewind.
            //  * a budget/EOF stop SHORT of `internal`: discardTo scratches
            //    lane_buf[lane] as it advances, so a partial-then-stalled skip
            //    leaves the resident op buffer CLOBBERED and stale — drop it
            //    (op_len = 0) so no later fwd_buffered read trusts corrupt bytes
            //    (the network gzip tail hazard).
            if (s.logical > internal) return null;
            if (!self.discardTo(s, internal, false, lane)) {
                self.op_len[lane] = 0;
                return null;
            }
        } else {
            var nearest: u64 = 0;
            self.lock();
            for (self.checkpoints.items) |entry| if (entry.logical <= internal) {
                nearest = entry.logical;
            } else break;
            self.unlock();
            if (!self.op_replay[lane] or internal < s.logical or nearest > s.logical) {
                if (!self.beginReplay(internal, lane)) return null;
            } else if (!self.discardTo(s, internal, true, lane)) return null;
        }
        if (self.fillFromSession(s, replay, lane) == 0) return null;
        return self.lane_buf[lane][0];
    }

    pub fn residentBytes(self: *const Gzip) u64 {
        return self.head.capacity + 3 * @sizeOf(Session) + 2 * @sizeOf(Checkpoint) + self.hot_checkpoint_bytes +
            self.checkpoints.capacity * @sizeOf(CheckpointEntry) + @sizeOf(Gzip);
    }

    fn physicalFor(self: *const Gzip, logical: u64) u64 {
        const internal = logical +| self.bom_len;
        for (self.head_marks[0..self.head_mark_count]) |m| if (internal <= m.logical_end) return @min(m.physical_end, self.mapping.len);
        for (self.checkpoints.items) |entry| if (internal <= entry.logical) return @min(entry.physical, self.mapping.len);
        return @min(self.forward_physical.load(.acquire), self.mapping.len);
    }
};

pub const Source = union(enum) {
    mmap: Mmap,
    gzip: *Gzip,
    http_range: *HttpRange,

    pub fn len(self: Source) u64 {
        return switch (self) {
            .mmap => |m| m.bytes.len,
            .gzip => |g| g.terminalLogical() orelse (g.forward_logical.load(.acquire) -| g.bom_len),
            .http_range => |hr| hr.logicalLen(),
        };
    }

    pub fn slice(self: Source, start: u64, end: u64) []const u8 {
        return switch (self) {
            .mmap => |m| m.bytes[@intCast(start)..@intCast(end)],
            .gzip => unreachable,
            .http_range => unreachable, // http_range reads via the streaming Cursor, never a direct slice
        };
    }

    pub fn isGzip(self: Source) bool {
        return self == .gzip;
    }

    pub fn knownEnd(self: Source) ?u64 {
        return switch (self) {
            .mmap => |m| m.bytes.len,
            .gzip => |g| g.terminalLogical(),
            // null until the stream's total is known (mirrors gzip.terminalLogical):
            // an unknown-length stream must NEVER report its fetched high-water as
            // the end (that would falsely stop the reader at the head).
            .http_range => |hr| hr.knownEnd(),
        };
    }

    /// FRONTIER COMMIT GUARD, hoist half: whether `commitBound` can EVER bound
    /// this Source. Scan loops hoist this out of their row loop so a LOCAL
    /// document pays a single register test, not a call, per row. Exactly the
    /// sources whose lookahead can be absent-but-fetchable answer true.
    ///
    /// SCOPE OF THE CURE: this guard closes AC-e1 for PLAIN NET CSV ONLY. Net GZIP
    /// stays UNCURED — `commitGuarded` is false for `.gzip`, so neither the wedge
    /// below nor the mid-row-frontier fix in `commitSearch`/`commitFilter` applies
    /// to it — pending the net-gz cell, which must also carry the
    /// `g.cond.waitUncancelable` mutex-held lane acquire (:1192/:1239).
    pub fn commitGuarded(self: Source) bool {
        return switch (self) {
            .mmap => false, // every byte is in the mapping; a peek never blocks
            // NET GZIP IS DELIBERATELY OUT OF SCOPE HERE (net_peek_mutex 3c) and a
            // commit-side bound cannot cover it: `produce` calls
            // `ensureCompressed(s.input.seek + chunk_bytes)` UNCONDITIONALLY on
            // every inflate op (:266-268), including on a REPLAY lane driven by a
            // mutex-held re-lex. That is a fixed 256 KiB compressed READ-AHEAD, not
            // a read of bytes the row needs, so it can demand an un-fetched chunk
            // however far behind the frontier the re-lex sits — bounding where the
            // frontier commits changes nothing. Its fix is `produce`-side
            // (demand-only / non-blocking `ensureCompressed` on replay lanes) and
            // belongs with `column.zig`'s mutex-held lane acquire (:1051, blocks on
            // `g.cond`) in a net-gz cell of its own. LOCAL gzip needs no guard at
            // all: `provider == null`, so every compressed byte is already mapped.
            .gzip => false,
            .http_range => true,
        };
    }

    /// FRONTIER COMMIT GUARD (security-hardening (e) AC-e1 residual, cell
    /// `net_peek_mutex`) — the ONE resolver every scan loop reads. Returns the
    /// highest LOGICAL offset at which a row may END and still be COMMITTED to the
    /// frontier; `maxInt` means unbounded. The invariant it encodes:
    ///
    ///     row_end + max_lookahead <= present_extent   OR   row_end is the
    ///                                                      source's TRUE end
    ///
    /// WHY. A row inside the counted region is later re-lexed by `window`/`nav`
    /// WHILE THE DOCUMENT MUTEX IS HELD. Finishing that row's terminator issues a
    /// `peek(max_lookahead)` AT `row_end`, which reads through `row_end +
    /// max_lookahead - 1` — past the row. That is not a corner case: a BARE CR
    /// terminator makes `csv_reader.finishTerminator` advance past the CR to
    /// `row_end` and then call `streamUnit` to test the successor for an LF, so the
    /// deepest byte a committed row can DEMAND is `row_end + max_lookahead - 1` and
    /// the bound must reserve the FULL width, not width - 1. On a network Source
    /// that read is an
    /// `ensureSlice`, i.e. a BLOCKING FETCH, and on the sequential arm an
    /// unbounded `net_source.stall_backoff_ms` spin
    /// (`net_source.ensureSliceSequentialLocked`) — so
    /// the whole document wedges: every poll, cancel and close blocks behind it.
    /// Two failure modes, both cured by never committing such a row:
    ///   * the wedge above (AC-e1 named it "One route remains UNBOUNDED");
    ///   * SILENT WRONG DATA, reachable TODAY with no clamp anywhere: `ensureSlice`
    ///     already returns the contiguous present PREFIX on a short/failed fetch
    ///     (:850-863), so the decoder can receive a TRUNCATED peek. A UTF-16
    ///     surrogate pair straddling that edge fails `off + 4 <= limit`, and the
    ///     deferral branch is dead on the peek path (`streamUnit` passes
    ///     `bytes.len` as `limit`), so `encoding.decodeUtf16Unit` falls through to
    ///     `replacementUnit(2)`: an astral character silently becomes U+FFFD
    ///     U+FFFD in served cell text.
    ///
    /// `reach` is the highest offset the caller is about to consider — its span
    /// end, or the row end it is about to count. This call SECURES that offset's
    /// lookahead first, on the CALLER's (scan worker's) thread and never under the
    /// document mutex: the scan is the designated fetcher, so the cost lands on
    /// the async, cancellable path that already pays it instead of on a mutex-held
    /// re-lex. Healthy documents therefore never see a bound (`reach` is secured,
    /// so the answer is >= `reach`) and the scan does not stop `max_lookahead`
    /// bytes short at every chunk boundary; a short/failed range alone bounds it,
    /// which is exactly AC-e3's "the un-fetched tail is never served as content".
    ///
    /// EOF IS EXEMPT: when every byte up to the true end is present the answer is
    /// unbounded, so the last row of a network document is committed normally.
    /// Without that a fully-fetched document would permanently lose its last row.
    pub fn commitBound(self: Source, reach: u64) u64 {
        return switch (self) {
            .mmap, .gzip => std.math.maxInt(u64), // see commitGuarded
            .http_range => |hr| hr.commitBound(reach, max_lookahead),
        };
    }

    /// `commitBound` WITHOUT the demand: bounds on what is already present and
    /// never fetches. Same one bound formula (`commitBound` resolves through this),
    /// two uses:
    ///   * the O(head) open scan (`index.headScan`), which must NOT pull a second
    ///     chunk over the wire — the net head budget is deliberately ONE chunk, and
    ///     a row it withholds costs nothing because the first demand scan picks the
    ///     row up straight away;
    ///   * the cheap per-span pre-check in a bulk scan, where the span's own bytes
    ///     are present by construction, so a demand there could only be a no-op.
    pub fn commitBoundNoFetch(self: Source) u64 {
        return switch (self) {
            .mmap, .gzip => std.math.maxInt(u64), // see commitGuarded
            .http_range => |hr| hr.commitBoundNoFetch(max_lookahead),
        };
    }

    pub fn openHead(self: Source) []const u8 {
        return switch (self) {
            .mmap => |m| m.bytes[0..@min(m.bytes.len, open_bytes)],
            .gzip => |g| g.head.items,
            .http_range => |hr| hr.openHead(),
        };
    }

    pub fn gzipUsable(self: Source) bool {
        return switch (self) {
            .mmap => true,
            .gzip => |g| g.openUsable(),
            .http_range => true,
        };
    }
};

/// Serialized operation cursor.  It leases the gzip operation buffer until
/// deinit; mmap cursors do not lock or copy.
pub const Cursor = struct {
    source: ?Source = null,
    logical: u64 = 0,
    physical: u64 = 0,
    limit: ?u64 = null,
    physical_limit: ?u64 = null,
    saved_input_end: usize = 0,
    locked: bool = false,
    lane: u8 = 0,
    look: [max_lookahead]u8 = undefined,
    look_start: u64 = 0,
    look_len: usize = 0,

    pub fn deinit(self: *Cursor) void {
        if (self.locked) switch (self.source.?) {
            .http_range => {}, // random-access: no lane lease to release
            .gzip => |g| {
                g.lock();
                g.lane_busy[self.lane] = false;
                g.lane_physical_budget[self.lane] = null;
                if (self.physical_limit != null) {
                    const session = g.sessionForLane(self.lane);
                    session.fence_cap = null;
                    // Never restore an end BEHIND the seek: a provider lane was
                    // leased at end 0 and has consumed bytes since, and
                    // `input.seek > input.end` makes `Reader.buffered()` a
                    // reversed slice. `produce` raises it again from the
                    // provider's high-water on the next op.
                    session.input.end = @max(self.saved_input_end, session.input.seek);
                    if (session.terminal == .budget) {
                        session.dec.err = null;
                        session.terminal = .inflating;
                    }
                }
                g.cond.broadcast(sysio.io());
                g.unlock();
            },
            .mmap => {},
        };
        self.locked = false;
    }

    /// A resumable background cursor must not retain a gzip lane across a
    /// scheduler yield. Reacquisition happens off the document mutex on the
    /// next step, after higher-priority foreground work has had its turn.
    pub fn releaseLane(self: *Cursor) void {
        self.deinit();
    }

    pub fn resumeLane(self: *Cursor) void {
        if (self.locked) return;
        const source = self.source orelse return;
        if (source == .mmap) return;
        const logical = self.logical;
        const limit = self.limit;
        self.* = cursorAt(source, logical, limit, null);
    }

    /// http_range: a genuinely random-access provider over the spool mapping;
    /// peek/span ensure the requested range is fetched (persist-once) then
    /// return a stable spool slice directly — no look-buffer copy needed.
    fn peekHttp(self: *Cursor, n: usize) []const u8 {
        const hr = self.source.?.http_range;
        const max_n = @min(n, self.look.len);
        // Cap by an explicit logical limit and the source's TRUE end (null while
        // an unknown-length stream has not hit EOF) — NEVER by the current
        // fetched extent, so `ensureSlice` drives the sequential drain forward
        // past the head instead of stopping at it.
        var cap: ?u64 = self.limit;
        if (hr.knownEnd()) |ke| cap = if (cap) |x| @min(x, ke) else ke;
        if (cap) |x| if (self.logical >= x) return self.look[0..0];
        var avail: u64 = max_n;
        if (cap) |x| avail = @min(avail, x - self.logical);
        if (self.physical_limit) |pl| {
            const at = hr.physical_base +| self.logical;
            avail = @min(avail, pl -| at);
        }
        if (avail == 0) return self.look[0..0];
        const s = hr.ensureSlice(self.logical + hr.bom_len, avail);
        return s[0..@min(s.len, @as(usize, @intCast(avail)))];
    }

    fn spanHttp(self: *Cursor) []const u8 {
        const hr = self.source.?.http_range;
        var cap: ?u64 = self.limit;
        if (hr.knownEnd()) |ke| cap = if (cap) |x| @min(x, ke) else ke;
        if (cap) |x| if (self.logical >= x) return &.{};
        const internal = self.logical + hr.bom_len;
        // Bound to the next chunk boundary so each span triggers at most one
        // fresh fetch (incremental, never fetch-the-whole-file). `ensureSlice`
        // drains forward as needed and returns the available (short at EOF)
        // slice; empty means the stream ended (or shut down).
        const chunk_end_internal = ((internal / net_source.chunk_bytes) + 1) * net_source.chunk_bytes;
        var end_logical: u64 = chunk_end_internal -| hr.bom_len;
        if (cap) |x| end_logical = @min(end_logical, x);
        if (self.physical_limit) |pl| end_logical = @min(end_logical, pl -| hr.physical_base);
        if (end_logical <= self.logical) return &.{};
        return hr.ensureSlice(internal, end_logical - self.logical);
    }

    pub fn peek(self: *Cursor, n: usize) []const u8 {
        if (self.source.? == .http_range) return self.peekHttp(n);
        const max_n = @min(n, self.look.len);
        if (self.limit) |lim| if (self.logical >= lim) return self.look[0..0];
        var got: usize = 0;
        // A previous peek may have crossed a lane-buffer boundary. Preserve
        // its unconsumed suffix: advancing the inflater replaced lane_buf,
        // but advancing the Cursor by one byte did not consume all lookahead.
        if (self.look_len > 0 and self.logical >= self.look_start and self.logical < self.look_start + self.look_len) {
            const offset: usize = @intCast(self.logical - self.look_start);
            got = @min(max_n, self.look_len - offset);
            std.mem.copyForwards(u8, self.look[0..got], self.look[offset..][0..got]);
            self.look_start = self.logical;
            self.look_len = got;
            if (got == max_n) return self.look[0..got];
        } else {
            self.look_start = self.logical;
            self.look_len = 0;
        }
        switch (self.source.?) {
            .mmap => |m| {
                const physical_end = if (self.physical_limit) |p| p -| m.physical_base else m.bytes.len;
                const end = @min(m.bytes.len, @as(usize, @intCast(@min(self.limit orelse m.bytes.len, physical_end))));
                const at: usize = @intCast(self.logical);
                if (got == 0 and at < end and end - at >= max_n) return m.bytes[at .. at + max_n];
            },
            .gzip => |g| {
                const internal = self.logical + g.bom_len;
                const logical_end = if (self.limit) |lim| lim + g.bom_len else std.math.maxInt(u64);
                if (got == 0 and internal < g.head.items.len) {
                    const end = @min(@as(u64, g.head.items.len), logical_end);
                    if (end - internal >= max_n) return g.head.items[@intCast(internal)..@intCast(internal + max_n)];
                }
                const lane: usize = self.lane;
                if (got == 0 and internal >= g.op_start[lane] and internal + max_n <= g.op_start[lane] + g.op_len[lane] and internal + max_n <= logical_end)
                    return g.lane_buf[lane][@intCast(internal - g.op_start[lane])..@intCast(internal - g.op_start[lane] + max_n)];
            },
            .http_range => unreachable, // handled by peekHttp early return
        }
        while (got < max_n) : (got += 1) {
            if (self.limit) |lim| if (self.logical + got >= lim) break;
            if (self.physical_limit) |lim| switch (self.source.?) {
                .mmap => |m| if (m.physical_base +| self.logical +| got >= lim) break,
                .gzip => {},
                .http_range => {},
            };
            const b = switch (self.source.?) {
                .mmap => |m| if (self.logical + got < m.bytes.len) m.bytes[@intCast(self.logical + got)] else break,
                .gzip => |g| g.byteAtLane(self.lane, self.logical + got + g.bom_len) orelse break,
                .http_range => unreachable,
            };
            self.look[got] = b;
        }
        self.look_start = self.logical;
        self.look_len = got;
        return self.look[0..got];
    }

    pub fn advance(self: *Cursor, n: usize) void {
        self.logical += n;
    }

    /// Move to `logical` in EITHER direction. Sound only for a POSITION-ONLY
    /// source — one where peek/span/physicalPosition are pure functions of
    /// `logical` with no retained lane/decoder state to unwind. That is exactly
    /// the set `commitGuarded` answers true for (`http_range`: a random-access
    /// spool), which is also the only caller: the frontier commit guard settling a
    /// bulk span scan on the last COMMITTABLE row boundary, which may be behind a
    /// cursor that walked into the next row or ahead of one whose span-end advance
    /// was skipped. A gzip cursor must NEVER be moved this way — its inflate
    /// session cannot run backwards.
    pub fn seekTo(self: *Cursor, logical: u64) void {
        std.debug.assert(self.source.?.commitGuarded());
        self.logical = logical;
        self.look_len = 0;
    }

    pub fn physicalPosition(self: *Cursor) u64 {
        return switch (self.source.?) {
            .mmap => |m| m.physical_base +| self.logical,
            .http_range => |hr| hr.physical_base +| self.logical,
            .gzip => |g| blk: {
                const internal = self.logical +| g.bom_len;
                if (internal <= g.head.items.len) break :blk g.physicalFor(internal -| g.bom_len);
                const lane: usize = self.lane;
                if (internal >= g.op_start[lane] and internal <= g.op_start[lane] + g.op_len[lane]) break :blk g.op_physical[lane];
                const session = g.sessionForLane(lane);
                break :blk session.input.seek;
            },
        };
    }

    pub fn hitPhysicalLimit(self: *const Cursor) bool {
        if (self.physical_limit == null) return false;
        return switch (self.source.?) {
            .mmap => |m| m.physical_base +| self.logical >= self.physical_limit.?,
            .http_range => |hr| hr.physical_base +| self.logical >= self.physical_limit.?,
            .gzip => |g| g.laneAtBudget(self.lane),
        };
    }

    pub fn atLimit(self: *const Cursor) bool {
        if (self.limit) |lim| if (self.logical >= lim) {
            // A logical limit that coincides with the source's OWN true end
            // (source.knownEnd()) is not a truncation — it is simply where
            // the content legitimately ends. Only a limit STRICTLY before the
            // true end is a genuine artificial cap (e.g. a per-row/window
            // scan budget). Without this check, the last record of any
            // streamed source (gzip/http_range) whose scan-budget limit
            // happens to equal the source's total length is misreported as
            // oversized/truncated/budget-stopped — the mmap path already
            // gets this right (lexer.recordBounds's `capped = limit != content.len`).
            if (self.source) |src| if (src.knownEnd()) |known_end| if (lim >= known_end) return false;
            return true;
        };
        if (self.hitPhysicalLimit()) return true;
        return switch (self.source.?) {
            .mmap => false,
            .http_range => false,
            .gzip => |g| g.opening and g.laneAtBudget(Gzip.forward_lane),
        };
    }

    /// mmap PARITY AT AN UNDECODABLE TAIL: how many bytes at the cursor are a code
    /// unit THE STREAM ENDS INSIDE — a dangling half UTF-16 unit — given that
    /// `in_hand` bytes here are already available (the count the caller's own `peek`
    /// just returned, so this never fetches). 0 at every other position, which is
    /// every well-formed one.
    ///
    /// The mmap lexer holds `content.len` up front, so a `decodeUnit` that comes up
    /// empty there means "the content ends inside this unit", and
    /// `lexer.recordBounds` DROPS the stub and lands on `limit` — with
    /// `capped = limit != content.len`, i.e. a true end is not a truncation. A
    /// streaming Cursor cannot see its end until the provider reaches it, so the
    /// same verdict has to be asked for at the point the decode came up null.
    /// Answering it wrong is unbounded rather than merely wrong: a scan step that
    /// neither advances nor reports `capped` makes every frontier loop re-issue the
    /// identical call forever (F1 — the `ls_open` hang).
    ///
    /// Three things make a decode come up empty, and only the first is a dangling
    /// tail:
    ///   * the stream genuinely ENDS mid-unit — `knownEnd` is published and every
    ///     byte up to it is `in_hand`: those bytes are the stub, and dropping them
    ///     lands the cursor exactly on the end (what this returns).
    ///   * an artificial CAP (a per-row/window/scan budget) cuts the unit: `atLimit`
    ///     answers `capped` and the caller stops without consuming. Only a limit
    ///     STRICTLY before the true end is such a cap — the same rule `atLimit`
    ///     applies just above, and `recordBounds`'s `limit != content.len`.
    ///   * the bytes are merely NOT YET THERE — an unknown-length stream that has
    ///     not hit EOF, a network range still in flight, a lane parked on a
    ///     compressed budget: `knownEnd` is null, or it is known but not `in_hand`.
    ///     That is a retryable STALL; consuming here would fabricate a terminus and
    ///     silently drop every row behind it.
    pub fn danglingTail(self: *const Cursor, in_hand: usize) usize {
        const end = (self.source orelse return 0).knownEnd() orelse return 0;
        if (self.limit) |lim| if (lim < end) return 0;
        const left = end -| self.logical;
        if (left == 0 or left > in_hand) return 0;
        return @intCast(left);
    }

    /// security-hardening (e) AC-e3: whether an EMPTY span at the current position
    /// is a genuine end-of-source, vs. bytes merely NOT-YET-AVAILABLE. A NETWORK
    /// short/failed range leaves un-fetched bytes BELOW the known end, so an empty
    /// span there is a retryable STALL, not EOF -- the frontier must not complete
    /// over it.
    ///   * mmap: an empty span is always end-of-mapping (no provider, nothing to
    ///     wait for).
    ///   * gzip: an empty span is a clean/damaged inflate terminus -- EXCEPT for a
    ///     NETWORK gzip (`provider != null`) parked on a `.budget` stop, which
    ///     means the compressed bytes have not arrived, not that the stream ended.
    ///     A LOCAL gzip can also park on `.budget`, but only against a mapping it
    ///     already fully owns, so it always resumes; only the network one can park
    ///     forever. Without this the short-body gz path reports a truncated
    ///     document as COMPLETE with a wrong row count.
    ///
    /// VERIFICATION STATUS of the gzip arm below
    /// (`!(g.provider != null and g.laneAtBudget(self.lane))`): REASONED-CORRECT,
    /// NOT PROBE-CONFIRMED. It must not be written up anywhere as tested — the
    /// 273/273 suite does not cover it either. The fixture built to discriminate
    /// it FAILED to: `probe_gz.zig` with a FULL gzip body, `advertise_length =
    /// true`, and `short_body_at` swept over 20-95% produced BYTE-IDENTICAL
    /// results with and without this arm, on every cut. Advertising the full
    /// plain length while short-circuiting delivery never parks the forward lane
    /// on `.budget` at an empty span, so the arm is never the deciding predicate
    /// there. A discriminating fixture must drive a network gzip to a `.budget`
    /// stop with no compressed bytes left to hand out. Until one exists, treat
    /// this arm as unexercised: reason about it, do not cite a test for it.
    pub fn spanTerminal(self: *const Cursor) bool {
        return switch (self.source.?) {
            .mmap => true,
            .gzip => |g| !(g.provider != null and g.laneAtBudget(self.lane)),
            .http_range => |hr| if (hr.knownEnd()) |ke| self.logical >= ke else hr.eof.load(.acquire),
        };
    }

    pub fn span(self: *Cursor) []const u8 {
        if (self.source.? == .http_range) return self.spanHttp();
        if (self.limit) |lim| if (self.logical >= lim) return &.{};
        return switch (self.source.?) {
            .mmap => |m| blk: {
                const at: usize = @intCast(self.logical);
                if (at >= m.bytes.len) break :blk &.{};
                const physical_end = if (self.physical_limit) |p| p -| m.physical_base else m.bytes.len;
                const lim: usize = @intCast(@min(@min(self.limit orelse m.bytes.len, physical_end), m.bytes.len));
                if (at >= lim) break :blk &.{};
                break :blk m.bytes[at..lim];
            },
            .gzip => |g| blk: {
                const internal = self.logical + g.bom_len;
                const lane: usize = self.lane;
                _ = g.byteAtLane(lane, internal) orelse break :blk &.{};
                const public_lim = self.limit orelse std.math.maxInt(u64);
                var result: []const u8 = if (internal < g.head.items.len)
                    g.head.items[@intCast(internal)..@intCast(@min(@as(u64, g.head.items.len), public_lim +| g.bom_len))]
                else if (internal >= g.op_start[lane] and internal < g.op_start[lane] + g.op_len[lane])
                    g.lane_buf[lane][@intCast(internal - g.op_start[lane])..@intCast(@min(@as(u64, g.op_len[lane]), public_lim +| g.bom_len - g.op_start[lane]))]
                else
                    &.{};
                const forced = g.force_chunk.load(.acquire);
                if (forced > 0 and result.len > forced) result = result[0..@intCast(forced)];
                break :blk result;
            },
            .http_range => unreachable, // handled by spanHttp early return
        };
    }
};

pub fn sourceFromMapping(mapping: []const u8, kind: SourceKind) Source {
    if (kind == .mmap) return .{ .mmap = .{ .bytes = mapping } };
    const g = Gzip.init(std.heap.smp_allocator, mapping) catch return .{ .mmap = .{ .bytes = mapping } };
    return .{ .gzip = g };
}

pub fn snapshotProbe(gpa: std.mem.Allocator, mapping: []const u8, target: u64) bool {
    const g = Gzip.init(gpa, mapping) catch return false;
    defer g.deinit();
    const a = gpa.create(Session) catch return false;
    defer gpa.destroy(a);
    const b = gpa.create(Session) catch return false;
    defer gpa.destroy(b);
    const cp = gpa.create(Checkpoint) catch return false;
    defer gpa.destroy(cp);
    a.init(mapping, mapping.len);
    _ = g.discardTo(a, target, false, 0);
    cp.capture(a);
    cp.restore(b);
    var abuf: [chunk_bytes]u8 = undefined;
    var bbuf: [chunk_bytes]u8 = undefined;
    while (true) {
        const an = g.produce(a, &abuf);
        const bn = g.produce(b, &bbuf);
        if (an != bn or !std.mem.eql(u8, abuf[0..an], bbuf[0..bn])) return false;
        if (an == 0) return a.terminal == b.terminal and a.input.seek == b.input.seek;
    }
}

pub fn sourceFromMappingAlloc(gpa: std.mem.Allocator, mapping: []const u8, kind: SourceKind) !Source {
    return switch (kind) {
        .mmap => .{ .mmap = .{ .bytes = mapping } },
        .gzip => .{ .gzip = try Gzip.init(gpa, mapping) },
    };
}

pub fn sourceShutdown(source: *Source) void {
    switch (source.*) {
        .mmap => {},
        .gzip => |g| {
            g.shutdown.store(true, .release);
            if (g.provider) |hr| hr.shutdown.store(true, .release); // network gzip: wake a stalled compressed drain
        },
        .http_range => |hr| hr.shutdown.store(true, .release),
    }
}

// never-full-download-streaming: gzip-over-http_range construction + the
// network-source predicates the index/poll/rowcount lanes key on.

/// Compose a gzip Source over the compressed bytes served on demand by an
/// http_range spool (TD4). On success the returned Gzip OWNS `provider` (its
/// deinit frees it); on failure returns null and the CALLER frees `provider`.
pub fn gzipOverProvider(gpa: std.mem.Allocator, provider: *HttpRange) ?*Gzip {
    return Gzip.initProvider(gpa, provider) catch null;
}

/// Whether a freshly-composed provider gzip inflated a usable head.
pub fn gzipUsablePtr(g: *Gzip) bool {
    return g.openUsable();
}

/// Deinit a provider gzip (also frees its owned http_range provider).
pub fn gzipDeinit(g: *Gzip) void {
    g.deinit();
}

/// security-hardening (b) AC-b2: whether more bytes can still ARRIVE FROM THE
/// PEER for `source` (see net_source.HttpRange.awaitsBytes). Local sources own
/// every byte they will ever have, so false.
///
/// NOT the same question as `Gzip.fenceCanMove`, and deliberately not shared with
/// it: a local gzip has no peer to wait for, yet its session fence still moves
/// when the open-head budget or a lane budget is lifted. This one answers
/// "should a stalled frontier keep waiting?"; that one answers "is a stop at this
/// fence resumable?".
pub fn sourceAwaitsBytes(source: Source) bool {
    return switch (source) {
        .mmap => false,
        .gzip => |g| if (g.provider) |hr| hr.awaitsBytes() else false,
        .http_range => |hr| hr.awaitsBytes(),
    };
}

/// True iff this Source fetches over the network (http_range, or a gzip composed
/// over an http_range) — the lazy-frontier gate keys strictly on this (TD1).
pub fn sourceIsNetwork(source: Source) bool {
    return switch (source) {
        .mmap => false,
        .gzip => |g| g.provider != null,
        .http_range => true,
    };
}

/// The network Source's http_range provider (for the net_* instrumentation
/// seams), or null for a non-network / local Source.
pub fn netProviderOf(source: Source) ?*HttpRange {
    return switch (source) {
        .mmap => null,
        .gzip => |g| g.provider,
        .http_range => |hr| hr,
    };
}

/// The known PHYSICAL total of a network Source (Content-Length / Content-Range
/// total, or the received size once an unknown-length stream hit EOF), or null
/// while an unknown-length stream's total is not yet known (the UINT64_MAX
/// sentinel case at the poll level). Non-network Sources return their byte size.
pub fn netPhysicalTotal(source: Source) ?u64 {
    return switch (source) {
        .mmap => |m| m.bytes.len,
        .gzip => |g| if (g.provider) |hr| hr.physicalTotal() else g.mapping.len,
        .http_range => |hr| hr.physicalTotal(),
    };
}

pub fn sourceFinishOpen(source: *Source) void {
    switch (source.*) {
        .mmap => {},
        .gzip => |g| g.finishOpen(),
        .http_range => {},
    }
}

pub fn sourceDeinit(source: *Source) void {
    switch (source.*) {
        .mmap => {},
        .gzip => |g| g.deinit(),
        .http_range => |hr| hr.deinit(),
    }
}

pub fn cursorAt(source: Source, logical: u64, logical_limit: ?u64, physical_budget: ?u64) Cursor {
    var cur: Cursor = .{ .source = source, .logical = logical, .limit = logical_limit };
    switch (source) {
        .mmap => |m| if (physical_budget) |budget| {
            cur.physical_limit = m.physical_base +| logical +| budget;
        },
        .http_range => |hr| if (physical_budget) |budget| {
            cur.physical_limit = hr.physical_base +| logical +| budget;
        },
        .gzip => |g| {
            g.lock();
            const internal = logical +| g.bom_len;
            while (true) {
                const forward_logical = g.forward_logical.load(.acquire);
                if (!g.lane_busy[0]) {
                    // Lane 0 idle ⇒ the forward session's op buffer is stable
                    // (only a lane-0 op mutates op_start[0]/op_len[0]). The
                    // forward lane can serve `internal` iff it can still inflate
                    // FORWARD to it (internal >= its logical position) OR its
                    // resident op buffer already covers it — the latter reuses
                    // the just-produced chunk for a read just behind the
                    // advancing frontier without a replay. Once the forward
                    // session over-produces PAST `internal` and no longer
                    // buffers it (notably when it parks at clean EOF, where the
                    // buffer becomes empty at the logical end), it can neither
                    // rewind nor produce it, so that read MUST replay — routing
                    // it to lane 0 there yields a 0-byte produce and blanks the
                    // record (the gz tail dead zone).
                    const fwd_buffered = g.op_len[0] > 0 and
                        internal >= g.op_start[0] and internal < g.op_start[0] + g.op_len[0];
                    if (internal >= forward_logical or fwd_buffered) {
                        cur.lane = 0;
                        break;
                    }
                    if (!g.lane_busy[1]) {
                        cur.lane = 1;
                        break;
                    }
                    if (!g.lane_busy[2]) {
                        cur.lane = 2;
                        break;
                    }
                } else if (internal < forward_logical) {
                    // Forward lane busy AND `internal` is behind the frontier ⇒
                    // serve it from an independent replay session.
                    if (!g.lane_busy[1]) {
                        cur.lane = 1;
                        break;
                    }
                    if (!g.lane_busy[2]) {
                        cur.lane = 2;
                        break;
                    }
                }
                g.cond.waitUncancelable(sysio.io(), &g.mutex);
            }
            g.lane_busy[cur.lane] = true;
            g.lane_physical_budget[cur.lane] = physical_budget;
            const session = g.sessionForLane(cur.lane);
            cur.physical = session.input.seek;
            if (physical_budget) |budget| {
                cur.saved_input_end = session.input.end;
                // ONE derivation of the cap, ABSOLUTE, matching `beginReplay` and the
                // field's own doc comment: the lane's budget anchored at the seek it
                // was leased at. `cur.physical_limit` keeps its own min() meaning (a
                // fence for bytes present NOW), but must not feed `fence_cap` —
                // `session.input.end` for a provider is the fetch HIGH-WATER, so that
                // pinned the cap at however far the download happened to have got at
                // lease time, and `produce`'s `@min(raised, cap)` then held the fence
                // there for the life of the lease. Degenerate case: a lane released
                // after consuming everything fetched sits at `end == seek`, which
                // pinned the cap at `seek`, so the raise could never satisfy
                // `new_end > s.input.end` and every budgeted op on that lane served
                // nothing and re-leased until an unbudgeted op broke the cycle.
                const cap: u64 = session.input.seek +| budget;
                session.fence_cap = @intCast(cap);
                cur.physical_limit = @min(@as(u64, session.input.end), cap);
                session.input.end = @intCast(cur.physical_limit.?);
            } else {
                session.fence_cap = null; // stated, not inferred from the lease order
            }
            g.unlock();
            cur.locked = true;
        },
    }
    return cur;
}

/// Acquire one lane for a sequential FILTER/SEARCH chunk.  Unlike cursorAt's
/// short-operation resume fast path, a scan which starts behind the forward
/// inflater must use an independent replay session: the shared forward
/// session can never serve a byte behind its over-produced logical position.
/// The returned Cursor retains that lane until the whole chunk is finished.
pub fn scanCursorAt(source: Source, logical: u64) Cursor {
    var cur: Cursor = .{ .source = source, .logical = logical };
    switch (source) {
        .mmap => {},
        .http_range => {},
        .gzip => |g| {
            g.lock();
            const internal = logical +| g.bom_len;
            while (true) {
                const trailing = internal < g.forward_logical.load(.acquire);
                if (!trailing and !g.lane_busy[0]) {
                    cur.lane = 0;
                    break;
                }
                if (trailing) {
                    if (!g.lane_busy[1]) {
                        cur.lane = 1;
                        break;
                    }
                    if (!g.lane_busy[2]) {
                        cur.lane = 2;
                        break;
                    }
                }
                g.cond.waitUncancelable(sysio.io(), &g.mutex);
            }
            g.lane_busy[cur.lane] = true;
            const session = g.sessionForLane(cur.lane);
            cur.physical = session.input.seek;
            g.unlock();
            cur.locked = true;
        },
    }
    return cur;
}

pub fn rebaseBom(source: *Source, bom_len: u64) void {
    switch (source.*) {
        .mmap => |*m| {
            const used = @min(bom_len, m.bytes.len);
            m.bytes = m.bytes[@intCast(used)..];
            m.physical_base +|= used;
        },
        .gzip => |g| g.bom_len = @min(bom_len, g.head.items.len),
        .http_range => |hr| {
            const used = @min(bom_len, hr.head_len);
            hr.bom_len = used;
            hr.physical_base +|= used;
        },
    }
}
