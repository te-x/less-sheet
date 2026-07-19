/*
 * lsg_jump.h — the GTK frontend's JUMP-TO-ROW feature (slice 3: "jump"). Two
 * layers, mirroring the macOS split:
 *
 *   1. A PURE, display-free jump VIEW-MODEL — the C analog of the macOS
 *      `JumpControlling` / `JumpControl` (Sources/Contracts/JumpControl.swift
 * + Sources/LessSheetKit/ViewerLogic.swift) TOGETHER WITH the two reject
 *      decisions macOS keeps in its app layer (`ViewerModel.submitJump` /
 *      `foldJump`). A value state machine (`lsg_jump_*` over `LsgJumpFlow` by
 *      value): it NEVER touches the core — it parses + validates the entered
 *      row, decides run-vs-reject, folds the core's jump-scan poll into a
 *      progress display, and decides the landing / cancel-restore / reject the
 *      widget acts on. Lifting the two app-layer reject rules into this pure
 *      layer (macOS leaves them above the frozen `JumpControl`) is what makes
 * the hand-rolled GTK grid's jump behavior verifiable headlessly under g_test.
 *
 *   2. The JUMP BRIDGE over the real core — the C analog of the macOS
 *      `CoreDocumentSession` jump methods (`startJump` / `cancelJump` /
 *      `jumpStatus`). These `lsg_document_jump_*` functions are the SINGLE
 * place this frontend calls `ls_jump_start` / `ls_jump_cancel` /
 * `ls_jump_poll`; they extend the document session frozen in <lsg_document.h>
 * (which stays frozen — the surface grows per slice) and so take an
 * `LsgDocument *`.
 *
 * THE FRONTIER IS THE CORE'S. A jump beyond the scanned region is served by
 * the core scanning forward to the target with visible progress (PROJECT.md
 * "Jumps & the scan frontier"); the frontend owns no scanner — it only
 * starts/cancels the core jump, polls its status, and drives the presentation.
 * Every byte the jump-scan covers permanently feeds the core's row index (cost
 * paid once).
 *
 * FILTERED = ORIGINAL ROW NUMBER. The entered number is always the document's
 * ORIGINAL (source) data-row number. Under a filter (a LATER slice — no filter
 * bridge is frozen here) the core interprets `ls_jump_start`'s target as an
 * ORIGINAL row and reports the FILTERED index of the nearest matching row
 * at/after it as the landing (api/lesssheet.h "JUMP under a filter"). The
 * frontend owns NO original->filtered mapping — the core does it. This
 * module's ONLY filtered-aware behavior is to SUPPRESS the out-of-range reject
 * (a filtered jump never rejects; it clamps to the last match), threaded as
 * the `filtered` flag through `lsg_jump_submit` / `lsg_jump_resolve`. The jump
 * contract already speaks in original-row terms so the filter slice composes
 * without a breaking change.
 *
 * SLICE 3 SCOPE (jump): 1-based digit entry + validation with rejection
 * feedback; the asynchronous jump-scan with monotone progress + cancel; the
 * filtered == original-row rule; and the LANDED row the grid scrolls into view
 * (via the existing frozen grid-geometry scroll math — no new geometry here).
 * OUT (later slices, NOT frozen here): filter-to-matches (`ls_filter_*`),
 * streaming copy, Settings/column-config, dialect override, the deferred
 * "Where" predicate widget. The jump ENTRY widget and the progress UI are
 * display-dependent (the author's GUI pass) — but every signature the implementer
 * wires into main.c is frozen here, and every non-drawing decision (parse,
 * run/reject, progress fold, land/cancel) is unit-pinned under g_test. The
 * poll loop keeps ticking while the flow is `LSG_JUMP_FLOW_SCANNING`, ORed at
 * the widget with the frozen `lsg_window_poll_decide` (which this slice does
 * NOT modify).
 *
 * Contract role (frozen; the prototypes/structs ARE the signatures — compiled
 * with -Werror so any drift against a stub/caller fails compilation). Symbols
 * are namespaced `lsg_` / `Lsg` / `LSG_` so they never collide with the core's
 * frozen `ls_` / `LS_` ABI in <lesssheet.h>, which this header builds ON
 * (never copies).
 *
 * OWNERSHIP: the view-model is a PLAIN VALUE type (`LsgJumpFlow` /
 * `LsgJumpStatus` / `LsgJumpSubmit` — no owned heap, no free functions). The
 * input string to `lsg_jump_parse` / `lsg_jump_submit` is BORROWED,
 * caller-owned, NUL-terminated UTF-8 (the entry buffer, or a literal in tests)
 * — the transforms only READ it.
 *
 * THREADING (mirrors <lesssheet.h> / <lsg_document.h>): the pure `lsg_jump_*`
 * transforms are pure (any thread; they touch no shared state). The bridge
 * `lsg_document_jump_start` / `_cancel` / `_poll` sit on the core's
 * POLL/CONTROL lane (internally synchronized; safe from any thread, but not
 * concurrently with `lsg_document_close` — the frontend stops polling before
 * close).
 */
#ifndef LSG_JUMP_H
#define LSG_JUMP_H

#include <glib.h>
#include <lsg_document.h>

G_BEGIN_DECLS

/* ------------------------------------------------------------------------- */
/* The core jump-slot snapshot (mirrors ls_jump_status + the macOS JumpStatus)
 */
/* ------------------------------------------------------------------------- */

/*
 * The document's single jump-slot state. Values are PINNED to the ABI's
 * `ls_jump_state` (LS_JUMP_*), so the bridge maps them 1:1 (the runtime pin is
 * a frozen test; -Werror compilation is the signature-drift guard).
 */
typedef enum
{
  LSG_JUMP_IDLE = 0, /* no jump since open, or the last jump was cancelled  */
  LSG_JUMP_SCANNING = 1, /* a scan toward the target is running */
  LSG_JUMP_DONE = 2, /* the jump finished; `landed_row` is valid            */
} LsgJumpState;

/*
 * One poll of the core jump slot (the C analog of the macOS `JumpStatus`,
 * flattening `ls_jump_status`). A PLAIN VALUE.
 *   progress    — [0.0, 1.0]; the fraction of the scan distance to the target
 *                 covered so far; monotone within one jump; exactly 1.0 at
 * DONE. Meaningful for SCANNING / DONE. landed_row  — meaningful ONLY at DONE:
 * the target row, clamped to the last data row when the target lies at/past
 * EOF (0 for a document with no data rows). Under a filter this is the nearest
 * matching row's FILTERED index (see the file header).
 */
typedef struct
{
  LsgJumpState state;
  gdouble progress;
  guint64 landed_row;
} LsgJumpStatus;

/* ------------------------------------------------------------------------- */
/* The pure jump view-model (mirrors JumpFlow + the app-layer reject rules) */
/* ------------------------------------------------------------------------- */

/*
 * The jump control's presentation state (mirrors the macOS `JumpFlow`, with
 * the two macOS app-layer reject decisions folded in as the
 * `LSG_JUMP_FLOW_REJECTED` kind). The widget switches on `kind`: IDLE       —
 * no jump in flight; the field is idle. SCANNING   — scanning toward `target`;
 * show the progress bar + Cancel once past the delayed-progress threshold, and
 * keep the poll loop ticking. Cancel/reject restore to `pre_jump_first_row`.
 *   LANDED     — the jump finished: scroll so `landed_row` is visible (the row
 *                anchoring is the widget's, via the frozen grid-geometry
 * math). CANCELLED  — the user cancelled (Esc): restore the viewport to
 *                `restore_first_row` (the captured pre-jump position). The
 * core's frontier gains are kept. REJECTED   — the target was invalid or out
 * of range: blink + shake the field (re-armed for correction). When
 * `has_restore`, also re-anchor the viewport to `restore_first_row` (a scan
 * had run — the after-scan reject); an upfront reject leaves the viewport
 * untouched
 *                (`has_restore` FALSE — no scan started, nothing moved).
 */
typedef enum
{
  LSG_JUMP_FLOW_IDLE = 0,
  LSG_JUMP_FLOW_SCANNING = 1,
  LSG_JUMP_FLOW_LANDED = 2,
  LSG_JUMP_FLOW_CANCELLED = 3,
  LSG_JUMP_FLOW_REJECTED = 4,
} LsgJumpFlowKind;

/*
 * The whole jump view-model state — a PLAIN VALUE (no owned heap). Swift's
 * per-case enum payloads are flattened; each field is meaningful only in the
 * kinds noted:
 *   target              — SCANNING: the 0-based ORIGINAL data-row target the
 * core is scanning toward (the value handed to `lsg_document_jump_start`).
 *   pre_jump_first_row  — SCANNING: the viewport's first visible row captured
 * when the jump began (the cancel/reject restore point). progress            —
 * SCANNING: the displayed scan progress in [0.0, 1.0], monotone (never
 * regresses on a stale poll). landed_row          — LANDED: the row to scroll
 * into view (a view/filtered index). restore_first_row   — CANCELLED, and
 * REJECTED when `has_restore`: the first visible row to re-anchor to.
 *   has_restore         — REJECTED only: whether `restore_first_row` is set
 * (TRUE after an after-scan reject, FALSE after an upfront one).
 */
typedef struct
{
  LsgJumpFlowKind kind;
  guint64 target;
  guint64 pre_jump_first_row;
  gdouble progress;
  guint64 landed_row;
  guint64 restore_first_row;
  gboolean has_restore;
} LsgJumpFlow;

/* The outcome of submitting the jump field (Enter). */
typedef enum
{
  LSG_JUMP_RUN = 0, /* valid, in range: start the scan toward `target`     */
  LSG_JUMP_REJECTED = 1, /* invalid / out-of-range input: red blink + shake */
} LsgJumpOutcome;

/*
 * The result of `lsg_jump_submit`. `flow` is the next view-model state either
 * way (SCANNING on RUN, REJECTED on REJECTED). `target` is meaningful only
 * when `outcome == LSG_JUMP_RUN`: the 0-based ORIGINAL data row to hand
 * straight to `lsg_document_jump_start`.
 */
typedef struct
{
  LsgJumpOutcome outcome;
  guint64 target;
  LsgJumpFlow flow;
} LsgJumpSubmit;

/* The empty initial view-model: `LSG_JUMP_FLOW_IDLE` (all payload fields
 * zero). The widget resets to this on Esc/close and on a dialect re-open / new
 * document identity (a flow referencing rows of a closed handle must not
 * persist). */
LsgJumpFlow lsg_jump_initial (void);

/*
 * Parse the jump field's text into a 0-based data-row target (the C analog of
 * `JumpControl.parseTarget`). The field accepts 1-BASED row numbers (UI copy
 * counts rows from 1), ASCII DIGITS ONLY, 64-bit: `input` must be non-empty,
 * every byte in '0'..'9' (leading zeros allowed), decoding to a value v with
 * 1 <= v <= G_MAXUINT64. On success writes the 0-based row v - 1 to
 * `*out_target` and returns TRUE. Returns FALSE (leaving `*out_target`
 * untouched) for anything else — empty/NULL, a non-digit byte (sign, space,
 * dot, non-ASCII numeral), zero
 * ("0" / "00"), or overflow past G_MAXUINT64.
 */
gboolean lsg_jump_parse (const char *input, guint64 *out_target);

/*
 * Enter: parse + validate the field, deciding run-vs-reject (the C analog of
 * the macOS `submitJump` composed with `JumpControl.begin`).
 * `pre_jump_first_row` is the viewport's current first visible row (captured
 * as the cancel/reject restore point). `rowcount` is the IDENTITY-view
 * row-count knowledge (count + whether exact). `filtered` is whether a filter
 * is active.
 *   - `input` fails `lsg_jump_parse` -> REJECTED, `flow` = REJECTED with
 *     `has_restore` FALSE (no scan; the viewport is untouched).
 *   - UNFILTERED and `rowcount.exact` and `target >= rowcount.count` ->
 * REJECTED the same way (an out-of-range target is known upfront when the
 * count is exact — no scan). While `filtered`, this upfront check is SKIPPED
 * (the target is an ORIGINAL row number, `rowcount` reports the filtered m —
 * not the same domain — and a filtered jump never rejects; it clamps to the
 * last match). While the count is still an ESTIMATE, an out-of-range target
 * can only be discovered by scanning to EOF (see `lsg_jump_resolve`).
 *   - otherwise RUN: `target` is the 0-based row and `flow` =
 *     SCANNING(target, pre_jump_first_row, progress 0). The caller then issues
 *     `lsg_document_jump_start(doc, target)` and folds the immediate poll with
 *     `lsg_jump_resolve` (a behind-frontier target lands without a poll tick).
 */
LsgJumpSubmit lsg_jump_submit (const char *input, LsgRowCount rowcount,
                               gboolean filtered, guint64 pre_jump_first_row);

/*
 * Fold one core jump-slot poll into the flow (the C analog of
 * `JumpControl.resolve` composed with the macOS `foldJump` reject decision).
 * Only a SCANNING flow folds a poll; every other kind is returned UNCHANGED
 * (an IDLE/LANDED/CANCELLED/REJECTED flow is stable — a stale poll never
 * resurrects or resets it).
 *   - `status.state == LSG_JUMP_SCANNING` -> SCANNING with
 *     progress' = MAX(displayed, status.progress) (display progress never
 *     regresses); `target` / `pre_jump_first_row` unchanged.
 *   - `status.state == LSG_JUMP_DONE` with landing r = status.landed_row:
 *       * UNFILTERED and r < `flow.target` -> REJECTED with `has_restore` TRUE
 * and `restore_first_row` = `flow.pre_jump_first_row`. The scan ended SHORT of
 *         the target: the target was past the last data row, the core clamped,
 * and the frontend rejects + re-anchors rather than land on the clamp (the
 *         after-scan out-of-range reject — the estimate-mode counterpart of
 *         `lsg_jump_submit`'s upfront check).
 *       * otherwise -> LANDED(r). This covers the exact hit (r == target) AND
 *         EVERY filtered jump: while `filtered`, r is a FILTERED index and
 *         `flow.target` an ORIGINAL row number — not comparable — so a
 * filtered jump never rejects (it clamps to the last match's filtered index).
 *   - `status.state == LSG_JUMP_IDLE` -> UNCHANGED (an idle poll never resets
 * a live scan by itself; cancellation goes through `lsg_jump_cancel`).
 */
LsgJumpFlow lsg_jump_resolve (LsgJumpFlow flow, LsgJumpStatus status,
                              gboolean filtered);

/*
 * The user cancel (Esc) (the C analog of `JumpControl.cancelled`): a SCANNING
 * flow becomes CANCELLED with `restore_first_row` = the captured
 * `pre_jump_first_row`; any other flow is returned unchanged. The caller also
 * calls `lsg_document_jump_cancel(doc)` (the core keeps its frontier gains)
 * and scrolls back to `restore_first_row`.
 */
LsgJumpFlow lsg_jump_cancel (LsgJumpFlow flow);

/* ------------------------------------------------------------------------- */
/* The jump bridge over the core — the single place ls_jump_* are called; */
/* extends the <lsg_document.h> session. */
/* ------------------------------------------------------------------------- */

/*
 * Start (or retarget) the document's jump toward `target_row` (a 0-based
 * ORIGINAL data row; mirrors `ls_jump_start`). A previous unfinished jump is
 * implicitly cancelled (its frontier gains are kept). Never blocks:
 *   - a target already behind the frontier — or, when the row count is exact,
 * a target at/past EOF (clamp) — completes BEFORE this call returns
 *     (`lsg_document_jump_poll` then reports LSG_JUMP_DONE, no scan runs);
 *   - otherwise an asynchronous scan advances the shared frontier toward the
 *     target, observable via `lsg_document_jump_poll`, taking the core's
 * single scan slot (a scanning search is cancelled — see <lsg_find.h>). On a
 * document with no data rows the jump completes immediately with landed_row 0.
 * While a filter is active `target_row` is an ORIGINAL row number and the
 * landing is the nearest matching row's FILTERED index (see the file header).
 * Poll/control lane.
 */
void lsg_document_jump_start (LsgDocument *doc, guint64 target_row);

/*
 * Cancel the active jump, if any (no-op otherwise; mirrors `ls_jump_cancel`).
 * After this returns, `lsg_document_jump_poll` reports LSG_JUMP_IDLE — UNLESS
 * the jump had already completed, in which case LSG_JUMP_DONE persists. All
 * frontier progress made by the cancelled scan is KEPT. Restoring the viewport
 * is the caller's affair (see `lsg_jump_cancel`). Never blocks. Poll/control
 * lane.
 */
void lsg_document_jump_cancel (LsgDocument *doc);

/*
 * The current jump-slot snapshot (mirrors `ls_jump_poll`; maps
 * `ls_jump_status` 1:1 into `LsgJumpStatus`). ZERO allocation; never blocks;
 * never fails — a fresh session (no jump since open) reports LSG_JUMP_IDLE.
 * Poll/control lane.
 */
LsgJumpStatus lsg_document_jump_poll (const LsgDocument *doc);

G_END_DECLS

#endif /* LSG_JUMP_H */
