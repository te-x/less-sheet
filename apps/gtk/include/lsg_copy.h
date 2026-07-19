/*
 * lsg_copy.h — the GTK frontend's STREAMING TSV COPY feature (slice 5:
 * "copy"). The heaviest GTK parity slice: a port of the macOS streaming
 * clipboard copy over the frozen core job family `ls_copy_open` /
 * `ls_copy_next` / `ls_copy_close` (api/lesssheet.h "STREAMING COPY
 * EXTENSION"). Two layers, mirroring every prior GTK slice (find / jump /
 * filter):
 *
 *   1. A PURE, display-free copy VIEW-MODEL — the C analog of the macOS
 *      `DocumentModel.streamCopy` DRIVE LOOP (apps/macos …/ViewerModel.swift)
 *      TOGETHER WITH the `CopyReport` / `CopyOutcome` state macOS keeps in its
 * App layer. A plain-value state machine (`lsg_copy_*` over `LsgCopyFlow` by
 *      value): it NEVER touches the core, threads, or I/O. It folds each core
 * copy STEP into a progress + outcome state — accumulating rows/bytes, cutting
 * at the frontend byte budget, mapping the core's cell-cap, driving the
 *      STALLED → advance-frontier → resume orchestration WITH the filtered
 *      no-progress guard, and turning a user cancel into a terminal outcome.
 *      Lifting this drive logic into the pure layer (macOS leaves it in the
 * App layer, gate-locked only by an inert `StreamCopyOutcomeProbe`) is what
 * makes the hand-rolled GTK copy behavior VERIFIABLE HEADLESS under g_test —
 * exactly as `lsg_jump` lifted macOS's app-layer reject rules into its pure
 * view-model.
 *
 *   2. The COPY BRIDGE over the real core — the C analog of the macOS
 *      `CoreDocumentSession.openCopy` / `copyStreamNext` / `copyStreamClose` +
 *      `CoreCopyStream`. `lsg_document_copy_open` vends an opaque `LsgCopyJob
 * *` wrapping an `ls_copy_job *`; `lsg_document_copy_next` frames the next TSV
 *      chunk into a caller buffer; `lsg_document_copy_close` releases the job.
 *      These are the SINGLE place this frontend calls `ls_copy_*`; they extend
 * the document session frozen in <lsg_document.h> (which stays frozen — the
 *      surface grows per slice) and reach the core handle + the control-lane
 * lock through the non-frozen `struct _LsgDocument` seam.
 *
 * THE CORE OWNS THE FRAMING. The TSV bytes (TAB field / LF row separators, no
 * trailing separator, spreadsheet quoting, the single-cell RAW special-case,
 * lossless cells past the display cap) are produced BY THE CORE,
 * byte-identical to the macOS path and to the deleted `TSVCopyBuilder`
 * (api/lesssheet.h). This frontend concatenates the chunks and owns NO TSV
 * logic — it drives the pull loop, advances the shared scan frontier on a
 * stall, and accumulates the payload.
 *
 * THE OFF-MAIN WORKER + THE CLOSE-GUARD (the macOS `copyBufferLock`
 * equivalent). A large copy runs on a BACKGROUND worker (main.c owns the
 * thread — display / threading domain, NOT frozen) so the grid keeps scrolling
 * while it streams (mirrors macOS AC4). The core copy job is poll/control-lane
 * — safe from any thread — EXCEPT concurrently with `ls_close` on the same
 * document (api/lesssheet.h THREADING). The bridge therefore serializes every
 * `ls_copy_*` call with `ls_close` through the document session's
 * `control_lock` (the lane lock `lsg_document_close` already acquires —
 * pre-reserved in the `_LsgDocument` seam "for the control lane
 * (copy/find/filter workers)"), checking that the core handle is still open
 * under the lock. This is the exact discipline macOS's `copyBufferLock`
 * + `isClosed` give `copyStreamNext` / `close()`. See the LIFETIME &
 * CLOSE-GUARD block on the bridge below for the ownership rule (a job must not
 * outlive its document) and why the concurrent worker↔close race is safe but
 * NOT deterministically g_testable (documented + reasoned, like the
 * network-driving caveat).
 *
 * SLICE 5 SCOPE (copy): the streaming copy ENGINE + STATE — the pure
 * drive/outcome view-model and the core-backed job bridge, DISPLAY-AGNOSTIC.
 * OUT (main.c, NOT frozen here): the grid SELECTION marquee that produces the
 * rectangle; the clipboard hand-off (GdkClipboard) of the accumulated payload;
 * the PROGRESS DISPLAY location — the author's unified header/title-bar progress +
 * inline cancel — and the worker THREAD itself and its bounded
 * frontier-advance wait (the macOS `frontierPoll*` tunables live in the App
 * layer, un-frozen). Every signature the implementer wires into the worker is
 * frozen here; every non-drawing decision (fold, budget cut, cell-cap map,
 * stall/resume, cancel, progress) is unit-pinned under g_test.
 *
 * Contract role (frozen; the prototypes/structs ARE the signatures — compiled
 * with -Werror so any drift against a stub/caller fails compilation). Symbols
 * are namespaced `lsg_` / `Lsg` / `LSG_` so they never collide with the core's
 * frozen `ls_` / `LS_` ABI in <lesssheet.h>, which this header builds ON
 * (never copies). (NOTE: the core's `ls_copy_*` job family is itself distinct
 * from the core's older `ls_copy_result` enum of `ls_cell_copy`; this frontend
 * wraps the JOB family.)
 *
 * OWNERSHIP: the view-model (`LsgCopyFlow` / `LsgCopyStep` / `LsgCopyRect`) is
 * a PLAIN VALUE type — no owned heap, no free functions. The bridge's
 * `LsgCopyJob *` is OWNED (release with `lsg_document_copy_close`, exactly
 * once). The chunk bytes `lsg_document_copy_next` frames are COPIED into the
 * CALLER's buffer (no borrow — they have no tie to the `ls_str`
 * window-eviction rule and survive any later `lsg_document_set_window` on any
 * thread).
 *
 * THREADING (mirrors <lesssheet.h> / <lsg_document.h>): the pure `lsg_copy_*`
 * transforms are pure (any thread; they touch no shared state). The bridge
 * `lsg_document_copy_open` / `_next` / `_close` sit on the core's POLL/CONTROL
 * lane and are internally serialized against `lsg_document_close` by the
 * session's `control_lock`; a single job is SINGLE-CONSUMER (one worker thread
 * drives its
 * `_next` / `_close` at a time — mirrors `ls_copy_next`).
 */
#ifndef LSG_COPY_H
#define LSG_COPY_H

#include <glib.h>
#include <lsg_document.h>

G_BEGIN_DECLS

/* ------------------------------------------------------------------------- */
/* The core copy STEP + rectangle (mirror ls_copy_step / ls_copy_progress / */
/* ls_copy_rect — the currency shared by the bridge output and the pure fold)
 */
/* ------------------------------------------------------------------------- */

/*
 * The outcome of one core copy pull. Values are PINNED to the ABI's
 * `ls_copy_step` (LS_COPY_STEP_*), so the bridge maps them 1:1 (the runtime
 * pin is a frozen test; -Werror compilation is the signature-drift guard).
 */
typedef enum
{
  LSG_COPY_STEP_MORE
  = 0, /* wrote `written` bytes; more chunks remain — pull again */
  LSG_COPY_STEP_DONE
  = 1, /* wrote the final `written` bytes; the selection is complete */
  LSG_COPY_STEP_STALLED
  = 2, /* the next row is at/beyond the frontier; nothing written —
        * advance the frontier to `stalled_row`, then pull again */
} LsgCopyStepKind;

/*
 * One pull of a streaming copy — the C analog of the macOS `CopyStep`,
 * flattening `ls_copy_progress` + `ls_copy_step`. A PLAIN VALUE. It is BOTH
 * the bridge's return (`lsg_document_copy_next`) AND the pure fold's input
 * (`lsg_copy_fold`). kind          — which step this is (pinned to
 * `ls_copy_step`). written       — bytes the core framed into the caller
 * buffer THIS pull
 *                   (<= the buffer length; 0 on STALLED; may be 0 on DONE for
 * an empty / fully-capped selection). The worker appends exactly these bytes
 * to its growing payload; the fold accumulates them for the byte-budget cut.
 *   rows_done     — cumulative selection rows FULLY emitted so far — monotone
 *                   non-decreasing across the job
 * (`ls_copy_progress.rows_done`); the progress numerator. stalled_row   —
 * meaningful only on STALLED: the VIEW row the worker must advance the
 * frontier over (`lsg_document_jump_start`, await done) before pulling again;
 * 0 otherwise. budget_capped — meaningful only on DONE: true iff the core's
 * LS_COPY_MAX_CELLS safety cap cut the selection short; false for a full
 * completion.
 */
typedef struct
{
  LsgCopyStepKind kind;
  gsize written;
  guint64 rows_done;
  guint64 stalled_row;
  gboolean budget_capped;
} LsgCopyStep;

/*
 * The rectangular selection to serialize — the C analog of `ls_copy_rect`,
 * HALF-OPEN in both axes (rows [first_row, first_row + row_count), columns
 * [first_col, first_col + col_count)). Rows are VIEW-relative (FILTERED
 * indices while a filter is active — the same coordinates as
 * `lsg_document_set_window`); columns are 0-based PHYSICAL column indices. An
 * empty rect (row_count == 0 or col_count == 0) is valid and steps straight to
 * DONE with 0 bytes. main.c converts its (inclusive) grid selection marquee
 * into this half-open rect — the selection algebra itself is display-layer,
 * not frozen here.
 */
typedef struct
{
  guint64 first_row; /* view-relative, filtered-aware (like the window) */
  guint64 row_count;
  guint32 first_col; /* physical column index */
  guint32 col_count;
} LsgCopyRect;

/* ------------------------------------------------------------------------- */
/* The pure copy view-model (port of streamCopy's drive loop + CopyOutcome) */
/* ------------------------------------------------------------------------- */

/*
 * The copy drive's presentation state (mirrors the macOS `streamCopy` loop's
 * own control flow). The worker switches on `kind`: STREAMING — pulling
 * chunks; more remain. Call `lsg_document_copy_next` again, append `written`
 * bytes, and fold the step. STALLED   — the next row is past the scan
 * frontier: advance the frontier to `stalled_row` (`lsg_document_jump_start`,
 * await LSG_JUMP_DONE), then pull + fold again. The filtered no-progress guard
 * lives in `lsg_copy_fold` (a re-stall on the SAME row → DONE/FRONTIER). DONE
 * — terminal: stop pulling, `lsg_document_copy_close` the job, and (for a
 * non-cancelled outcome) hand the accumulated payload to the clipboard.
 * `outcome` says why it ended; `rows_done` / `bytes_done` drive the honest
 * "Copied N rows / ~M bytes" notice.
 */
typedef enum
{
  LSG_COPY_FLOW_STREAMING = 0,
  LSG_COPY_FLOW_STALLED = 1,
  LSG_COPY_FLOW_DONE = 2,
} LsgCopyFlowKind;

/*
 * Why a copy ended — the C analog of the macOS `CopyOutcome`, plus a CANCELLED
 * terminal (macOS drops a cancelled copy's report silently; the GTK view-model
 * makes cancel an explicit terminal so it is g_testable). Meaningful only when
 * `LsgCopyFlow.kind == LSG_COPY_FLOW_DONE`.
 */
typedef enum
{
  LSG_COPY_OUTCOME_COMPLETE = 0, /* the whole rect was copied */
  LSG_COPY_OUTCOME_BUDGET
  = 1, /* the frontend byte budget was reached (bounded blob) */
  LSG_COPY_OUTCOME_CELL_CAP
  = 2, /* the core's LS_COPY_MAX_CELLS cap cut it short (budget_capped) */
  LSG_COPY_OUTCOME_FRONTIER = 3,  /* a row past the frontier could not be
                                     advanced (filtered mis-target) */
  LSG_COPY_OUTCOME_CANCELLED = 4, /* the user cancelled */
} LsgCopyOutcome;

/*
 * The whole copy view-model state — a PLAIN VALUE (no owned heap). Fields are
 * meaningful in the kinds noted:
 *   kind             — the drive state (above).
 *   outcome          — DONE only: why the copy ended.
 *   rows_done        — cumulative rows fully emitted (monotone; never
 * regresses on a stale step). Progress numerator. bytes_done       —
 * cumulative bytes framed so far (the byte-budget accumulator; drives the "~M
 * bytes" notice). row_count        — the rect's row count captured at
 * `lsg_copy_begin` (the progress denominator; 0 for an empty rect).
 *   budget_bytes     — the frontend byte budget captured at `lsg_copy_begin`
 *                      (0 = no frontend byte cap; the core cell-cap still
 * bounds). stalled_row      — STALLED only: the view row to advance the
 * frontier over. last_stalled_row — the previous stalled row, for the
 * no-progress guard. has_last_stalled — whether a stall has occurred (arms the
 * no-progress guard).
 */
typedef struct
{
  LsgCopyFlowKind kind;
  LsgCopyOutcome outcome;
  guint64 rows_done;
  guint64 bytes_done;
  guint64 row_count;
  guint64 budget_bytes;
  guint64 stalled_row;
  guint64 last_stalled_row;
  gboolean has_last_stalled;
} LsgCopyFlow;

/*
 * Begin a copy of `rect` with a frontend byte budget of `budget_bytes` (0 = no
 * byte cap; the core's LS_COPY_MAX_CELLS still bounds a pathological selection
 * — see api/lesssheet.h). `budget_bytes` is a CALLER TUNABLE (the shipping
 * value — the macOS `CopyBudget.standard` ~64 MiB analog — lives un-frozen in
 * main.c; the g_tests pin the STOPPING behavior with tiny budgets, never a
 * magic size). Returns a fresh LSG_COPY_FLOW_STREAMING flow (rows_done /
 * bytes_done 0), capturing `rect.row_count` as the progress denominator.
 */
LsgCopyFlow lsg_copy_begin (LsgCopyRect rect, guint64 budget_bytes);

/*
 * Fold one core copy step into the flow (the C analog of one iteration of the
 * macOS `streamCopy` loop body). Only an in-flight flow (STREAMING or STALLED)
 * folds a step; a terminal DONE flow is returned UNCHANGED (a stale step never
 * resurrects it). Accumulates progress (rows_done monotone, bytes_done +=
 * written), then maps `step.kind`: MORE    — accumulated bytes reached a
 * POSITIVE `budget_bytes` -> DONE/BUDGET (the payload is bounded; mirrors the
 * macOS `.stoppedAtBudget` cut); otherwise -> STREAMING (pull again). DONE —
 * `step.budget_capped` -> DONE/CELL_CAP (the core cap cut it short); otherwise
 * -> DONE/COMPLETE. STALLED — the SAME row as the last stall (has_last_stalled
 * && stalled_row == last_stalled_row) -> DONE/FRONTIER: the previous frontier
 * advance made NO progress over this row, so stop cleanly instead of
 * re-jumping it forever. This is the FILTERED mis-target guard — under a
 * filter the core's `stalled_row` is a FILTERED view row but
 * `lsg_document_jump_start` targets an ORIGINAL data row (api/lesssheet.h
 * "JUMP under a filter"), so the jump can return LSG_JUMP_DONE without
 * advancing over the stalled view row. The IDENTITY view never trips this (a
 * real advance makes the next stall a strictly-later row). Otherwise ->
 * STALLED (record `stalled_row`; the worker advances the frontier to it, then
 * folds the next step).
 */
LsgCopyFlow lsg_copy_fold (LsgCopyFlow flow, LsgCopyStep step);

/*
 * The user cancel: an in-flight flow (STREAMING or STALLED) becomes
 * DONE/CANCELLED; a terminal DONE flow is returned unchanged. Cancel is "stop
 * pulling + close the job" — the core job holds no background thread, so there
 * is nothing to join (the worker sees the terminal flow,
 * `lsg_document_copy_close`s, and drops the partial payload). Mirrors macOS
 * `copyTask` cancellation.
 */
LsgCopyFlow lsg_copy_cancel (LsgCopyFlow flow);

/*
 * Progress fraction in [0.0, 1.0] for a progress affordance (the
 * header/title-bar progress is main.c's — this is just the number): rows_done
 * / row_count, clamped; 1.0 for an empty rect (row_count == 0). Monotone
 * non-decreasing (rows_done never regresses). A partial terminal (BUDGET /
 * FRONTIER / CANCELLED) reports its true fraction < 1.0; a COMPLETE
 * reports 1.0.
 */
gdouble lsg_copy_progress_fraction (LsgCopyFlow flow);

/* ------------------------------------------------------------------------- */
/* The copy bridge over the core — the single place ls_copy_* are called; */
/* extends the <lsg_document.h> session. Runs on the OFF-MAIN copy worker. */
/* ------------------------------------------------------------------------- */

/*
 * An in-progress streaming copy job — the C analog of the macOS
 * `CoreCopyStream`, wrapping one `ls_copy_job *`. OWNED by the caller; release
 * with `lsg_document_copy_close` EXACTLY ONCE (the handle is invalid
 * afterward). `LsgDocument` stays opaque; this handle lives in src/ over the
 * internal seam.
 */
typedef struct _LsgCopyJob LsgCopyJob;

/*
 * Open a pull-model streaming TSV copy of `rect` over `doc` (mirrors
 * `ls_copy_open`). Returns a fresh OWNED `LsgCopyJob *`, or NULL only when the
 * document is closed / NULL or the core handle could not be allocated. The
 * core validates an empty or out-of-range-column rect into a job that steps
 * straight to DONE with 0 bytes, so a degenerate selection is NOT an error
 * here. The rect is copied; the caller keeps ownership of it. The job
 * serializes in the coordinate space in effect at OPEN (identity view, or the
 * active filter's FILTERED coordinates) — a caller that changes the view
 * mid-copy must close this job and open a fresh one. Poll/control lane
 * (serialized with `lsg_document_close` by the session's `control_lock`).
 */
LsgCopyJob *lsg_document_copy_open (LsgDocument *doc, LsgCopyRect rect);

/*
 * Frame the next TSV chunk of `job` into `buf` (writes at most `buf_len`
 * bytes; the core COPIES — no borrow) and return the step (mirrors
 * `ls_copy_next` -> `ls_copy_progress`). A chunk ends at a field/row boundary,
 * except a single field longer than `buf_len` is split across pulls at a UTF-8
 * code-point boundary; the `written` bytes of successive pulls CONCATENATE
 * byte-for-byte into one well-formed TSV payload (byte-identical to the macOS
 * path / the deleted TSVCopyBuilder — pinned by the frozen bridge tests).
 * `buf` may be NULL only when `buf_len` is 0. SINGLE-CONSUMER: do not call
 * concurrently on one job. Do not call after a DONE step. Poll/control lane,
 * guarded (see below).
 */
LsgCopyStep lsg_document_copy_next (LsgCopyJob *job, guint8 *buf,
                                    gsize buf_len);

/*
 * Release the job (`ls_copy_close`; call EXACTLY ONCE; NULL-safe). Cancel is
 * simply "stop calling `_next`, then `_close`": the core job holds no
 * background thread, so there is nothing to join.
 *
 * LIFETIME & CLOSE-GUARD (the macOS `copyBufferLock` equivalent; the Slice-3
 * review's flagged race). A large copy runs on an OFF-MAIN worker (main.c) so
 * the grid keeps scrolling. The core forbids `ls_copy_*` CONCURRENTLY WITH
 * `ls_close` on the same document (api/lesssheet.h THREADING); the bridge
 * therefore takes the session's `control_lock` — the SAME lane lock
 * `lsg_document_close` acquires before `ls_close` — across every
 * `ls_copy_open` / `ls_copy_next` / `ls_copy_close`, and re-checks that the
 * core handle is still open under the lock (a call that finds it closed
 * returns a benign DONE / no-op). So a worker mid-`_next` and a
 * `lsg_document_close` on another thread can never overlap their core calls —
 * the exact guarantee macOS's `copyBufferLock` + `isClosed` give.
 *
 * OWNERSHIP RULE (unlike macOS, GTK has no ARC to defer the free): a job must
 * NOT OUTLIVE its document. `lsg_document_close` frees the session (and the
 * lane lock), so the frontend MUST stop the worker (no further `_next`) and
 * `lsg_document_copy_close` every job BEFORE `lsg_document_close` — leaf
 * before root. Within that lifetime the `control_lock` makes the concurrent
 * worker↔teardown window safe. The actual off-main worker + this race are NOT
 * deterministically g_testable (a real timing race); they are covered by this
 * bridge contract + reasoning, exactly like the network-driving caveat. The
 * g_tests pin the single-threaded bridge behavior (byte-identical framing,
 * empty/degenerate rects, close idempotency, leaf-before-root teardown).
 */
void lsg_document_copy_close (LsgCopyJob *job);

G_END_DECLS

#endif /* LSG_COPY_H */
