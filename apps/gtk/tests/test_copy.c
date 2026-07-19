/*
 * test_copy.c — RED behavior tests for the STREAMING COPY module (lsg_copy.h).
 * Slice 5. Display-free (glib only, no GTK). Two halves, mirroring the macOS
 * streaming-copy tests + the inert StreamCopyOutcomeProbe, lifted to deterministic
 * g_tests:
 *
 *   PURE VIEW-MODEL — the ABI step-enum pin; begin; the drive-loop FOLD that a C
 *   port of macOS `DocumentModel.streamCopy` performs per pull: MORE accumulation,
 *   the frontend byte-budget cut (probe `byte_budget`), the core cell-cap map
 *   (probe `cell_cap`), a plain completion (probe `complete`), the STALLED ->
 *   advance-frontier -> resume orchestration and the FILTERED no-progress guard
 *   (probe `filtered_stall`), user cancel, terminal stability, and the monotone
 *   progress fraction. No core, no threads.
 *
 *   COPY BRIDGE — the real Zig core through lsg_document_copy_open / _next / _close
 *   over the find.csv + copyquote.csv fixtures (both fully indexed at open, so the
 *   sweep never stalls): the core-framed TSV payload is BYTE-IDENTICAL to the macOS
 *   path / the deleted TSVCopyBuilder — full rect, single-cell RAW, empty leading
 *   field, sub-column, spreadsheet quoting (interior quotes doubled), and tiny-chunk
 *   concatenation — plus the empty/degenerate-rect DONE-with-0-bytes validation and
 *   close idempotency / leaf-before-root teardown. The off-main worker + the
 *   control_lock close-guard are a timing race, NOT deterministically g_testable —
 *   covered by the bridge contract + reasoning (lsg_copy.h), like the net caveat.
 *
 * These are RED against the seeded src/lsg_copy.c (a begin/fold/cancel that never
 * leaves the initial state, a progress that is always 0, and a bridge whose open
 * returns NULL) and turn GREEN as the module is implemented.
 */
#include <glib.h>
#include <string.h>
#include <lesssheet.h>
#include <lsg_document.h>
#include <lsg_copy.h>

/* ========================================================================= */
/* PURE VIEW-MODEL                                                            */
/* ========================================================================= */

/* --- ABI agreement: the frontend copy-step enum mirrors ls_copy_step exactly
 *     (the runtime drift guard; -Werror compilation is the signature guard) --- */

static void
test_abi_enum_pins (void)
{
  g_assert_cmpint (LSG_COPY_STEP_MORE, ==, LS_COPY_STEP_MORE);
  g_assert_cmpint (LSG_COPY_STEP_DONE, ==, LS_COPY_STEP_DONE);
  g_assert_cmpint (LSG_COPY_STEP_STALLED, ==, LS_COPY_STEP_STALLED);
}

/* --- begin: a fresh copy streams, with rows/bytes zero and row_count captured --- */

static void
test_begin (void)
{
  LsgCopyRect rect = { .first_row = 0, .row_count = 8, .first_col = 0, .col_count = 3 };
  LsgCopyFlow f = lsg_copy_begin (rect, 4096);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_STREAMING);
  g_assert_cmpuint (f.rows_done, ==, 0);
  g_assert_cmpuint (f.bytes_done, ==, 0);
  g_assert_cmpuint (f.row_count, ==, 8);      /* progress denominator captured */
  g_assert_cmpfloat (lsg_copy_progress_fraction (f), ==, 0.0);
}

/* --- MORE steps accumulate rows + bytes and keep streaming --- */

static void
test_fold_more_accumulates (void)
{
  LsgCopyRect rect = { .first_row = 0, .row_count = 10, .first_col = 0, .col_count = 2 };
  LsgCopyFlow f = lsg_copy_begin (rect, 0);   /* 0 = no byte cap */

  LsgCopyStep s1 = { .kind = LSG_COPY_STEP_MORE, .written = 30, .rows_done = 3 };
  f = lsg_copy_fold (f, s1);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_STREAMING);
  g_assert_cmpuint (f.rows_done, ==, 3);
  g_assert_cmpuint (f.bytes_done, ==, 30);
  g_assert_cmpfloat (lsg_copy_progress_fraction (f), ==, 0.3);

  LsgCopyStep s2 = { .kind = LSG_COPY_STEP_MORE, .written = 20, .rows_done = 7 };
  f = lsg_copy_fold (f, s2);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_STREAMING);
  g_assert_cmpuint (f.rows_done, ==, 7);
  g_assert_cmpuint (f.bytes_done, ==, 50);
  g_assert_cmpfloat (lsg_copy_progress_fraction (f), ==, 0.7);
}

/* --- a plain DONE step completes the copy at 1.0 (probe `complete`) --- */

static void
test_fold_done_complete (void)
{
  LsgCopyRect rect = { .first_row = 0, .row_count = 4, .first_col = 0, .col_count = 1 };
  LsgCopyFlow f = lsg_copy_begin (rect, 0);
  LsgCopyStep done = { .kind = LSG_COPY_STEP_DONE, .written = 8, .rows_done = 4, .budget_capped = FALSE };
  f = lsg_copy_fold (f, done);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_DONE);
  g_assert_cmpint (f.outcome, ==, LSG_COPY_OUTCOME_COMPLETE);
  g_assert_cmpuint (f.rows_done, ==, 4);
  g_assert_cmpfloat (lsg_copy_progress_fraction (f), ==, 1.0);
}

/* --- a DONE with budget_capped maps to CELL_CAP (probe `cell_cap`) --- */

static void
test_fold_done_cell_cap (void)
{
  LsgCopyRect rect = { .first_row = 0, .row_count = 100, .first_col = 0, .col_count = 3 };
  LsgCopyFlow f = lsg_copy_begin (rect, 0);
  LsgCopyStep capped = { .kind = LSG_COPY_STEP_DONE, .written = 0, .rows_done = 40, .budget_capped = TRUE };
  f = lsg_copy_fold (f, capped);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_DONE);
  g_assert_cmpint (f.outcome, ==, LSG_COPY_OUTCOME_CELL_CAP);
}

/* --- MORE past a positive byte budget stops at BUDGET, blob bounded
 *     (probe `byte_budget`; tiny budget pins the STOP, never a magic size) --- */

static void
test_fold_byte_budget (void)
{
  LsgCopyRect rect = { .first_row = 0, .row_count = 1000, .first_col = 0, .col_count = 3 };
  LsgCopyFlow f = lsg_copy_begin (rect, 4096);     /* tiny budget */

  /* Under budget: keeps streaming. */
  LsgCopyStep under = { .kind = LSG_COPY_STEP_MORE, .written = 3000, .rows_done = 5 };
  f = lsg_copy_fold (f, under);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_STREAMING);

  /* The chunk that reaches the budget stops the sweep (bounded to budget + one
   * chunk — mirrors the macOS `.stoppedAtBudget` cut). */
  LsgCopyStep over = { .kind = LSG_COPY_STEP_MORE, .written = 2000, .rows_done = 9 };
  f = lsg_copy_fold (f, over);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_DONE);
  g_assert_cmpint (f.outcome, ==, LSG_COPY_OUTCOME_BUDGET);
  g_assert_cmpuint (f.bytes_done, >=, 4096);
  g_assert_cmpuint (f.bytes_done, <=, 4096 + 2000);
  g_assert_cmpuint (f.rows_done, ==, 9);
}

/* --- STALLED with a new row asks the worker to advance the frontier; a following
 *     MORE resumes streaming (progress after the advance) --- */

static void
test_fold_stalled_advance_and_resume (void)
{
  LsgCopyRect rect = { .first_row = 0, .row_count = 100, .first_col = 0, .col_count = 2 };
  LsgCopyFlow f = lsg_copy_begin (rect, 0);

  LsgCopyStep stall = { .kind = LSG_COPY_STEP_STALLED, .written = 0, .rows_done = 10, .stalled_row = 10 };
  f = lsg_copy_fold (f, stall);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_STALLED);
  g_assert_cmpuint (f.stalled_row, ==, 10);       /* the worker jumps to row 10 */
  g_assert_cmpuint (f.rows_done, ==, 10);

  /* After the worker advanced the frontier and pulled again, a MORE resumes. */
  LsgCopyStep more = { .kind = LSG_COPY_STEP_MORE, .written = 40, .rows_done = 25 };
  f = lsg_copy_fold (f, more);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_STREAMING);
  g_assert_cmpuint (f.rows_done, ==, 25);

  /* A genuinely-later stall (frontier advanced) is NOT the no-progress case. */
  LsgCopyStep stall2 = { .kind = LSG_COPY_STEP_STALLED, .written = 0, .rows_done = 25, .stalled_row = 25 };
  f = lsg_copy_fold (f, stall2);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_STALLED);
  g_assert_cmpuint (f.stalled_row, ==, 25);
}

/* --- FILTERED mis-target: the SAME stalled row recurs after a jump -> stop
 *     cleanly at FRONTIER, no re-jump-forever (probe `filtered_stall`) --- */

static void
test_fold_filtered_stall_no_progress (void)
{
  LsgCopyRect rect = { .first_row = 0, .row_count = 100, .first_col = 0, .col_count = 2 };
  LsgCopyFlow f = lsg_copy_begin (rect, 0);

  /* First stall on view row 7: the worker jumps to (original) 7 — but under a
   * filter that does not advance the frontier over filtered view row 7. */
  LsgCopyStep stall = { .kind = LSG_COPY_STEP_STALLED, .written = 0, .rows_done = 0, .stalled_row = 7 };
  f = lsg_copy_fold (f, stall);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_STALLED);

  /* The SAME row stalls again -> no progress -> stop at the frontier. */
  LsgCopyStep again = { .kind = LSG_COPY_STEP_STALLED, .written = 0, .rows_done = 0, .stalled_row = 7 };
  f = lsg_copy_fold (f, again);
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_DONE);
  g_assert_cmpint (f.outcome, ==, LSG_COPY_OUTCOME_FRONTIER);
}

/* --- user cancel makes any in-flight flow terminal/CANCELLED; terminal stable --- */

static void
test_cancel (void)
{
  LsgCopyRect rect = { .first_row = 0, .row_count = 50, .first_col = 0, .col_count = 2 };

  /* Cancel while STREAMING. */
  LsgCopyFlow streaming = lsg_copy_begin (rect, 0);
  streaming = lsg_copy_fold (streaming, (LsgCopyStep){ .kind = LSG_COPY_STEP_MORE, .written = 10, .rows_done = 5 });
  LsgCopyFlow c1 = lsg_copy_cancel (streaming);
  g_assert_cmpint (c1.kind, ==, LSG_COPY_FLOW_DONE);
  g_assert_cmpint (c1.outcome, ==, LSG_COPY_OUTCOME_CANCELLED);
  g_assert_cmpuint (c1.rows_done, ==, 5);              /* partial progress preserved */

  /* Cancel while STALLED. */
  LsgCopyFlow stalled = lsg_copy_begin (rect, 0);
  stalled = lsg_copy_fold (stalled, (LsgCopyStep){ .kind = LSG_COPY_STEP_STALLED, .stalled_row = 3 });
  LsgCopyFlow c2 = lsg_copy_cancel (stalled);
  g_assert_cmpint (c2.kind, ==, LSG_COPY_FLOW_DONE);
  g_assert_cmpint (c2.outcome, ==, LSG_COPY_OUTCOME_CANCELLED);

  /* Cancelling a terminal flow is a no-op (stable). */
  g_assert_cmpint (lsg_copy_cancel (c1).kind, ==, LSG_COPY_FLOW_DONE);
  g_assert_cmpint (lsg_copy_cancel (c1).outcome, ==, LSG_COPY_OUTCOME_CANCELLED);
}

/* --- a terminal flow folds further steps unchanged; progress is monotone --- */

static void
test_fold_terminal_and_monotone (void)
{
  LsgCopyRect rect = { .first_row = 0, .row_count = 10, .first_col = 0, .col_count = 2 };
  LsgCopyFlow f = lsg_copy_begin (rect, 0);
  f = lsg_copy_fold (f, (LsgCopyStep){ .kind = LSG_COPY_STEP_DONE, .rows_done = 10 });
  g_assert_cmpint (f.kind, ==, LSG_COPY_FLOW_DONE);
  g_assert_cmpint (f.outcome, ==, LSG_COPY_OUTCOME_COMPLETE);

  /* A stray later step never resurrects a completed copy. */
  LsgCopyFlow g = lsg_copy_fold (f, (LsgCopyStep){ .kind = LSG_COPY_STEP_MORE, .written = 99, .rows_done = 3 });
  g_assert_cmpint (g.kind, ==, LSG_COPY_FLOW_DONE);
  g_assert_cmpint (g.outcome, ==, LSG_COPY_OUTCOME_COMPLETE);

  /* Progress never regresses on a stale (lower rows_done) step. */
  LsgCopyFlow h = lsg_copy_begin (rect, 0);
  h = lsg_copy_fold (h, (LsgCopyStep){ .kind = LSG_COPY_STEP_MORE, .written = 5, .rows_done = 8 });
  g_assert_cmpuint (h.rows_done, ==, 8);
  h = lsg_copy_fold (h, (LsgCopyStep){ .kind = LSG_COPY_STEP_MORE, .written = 5, .rows_done = 4 });
  g_assert_cmpuint (h.rows_done, ==, 8);              /* not lowered to 4 */
  g_assert_cmpfloat (lsg_copy_progress_fraction (h), ==, 0.8);
}

/* --- progress fraction: empty rect is fully done; clamped to [0, 1] --- */

static void
test_progress_fraction (void)
{
  /* Empty rect (nothing to do) reads as complete. */
  LsgCopyFlow empty = lsg_copy_begin ((LsgCopyRect){ .row_count = 0, .col_count = 3 }, 0);
  g_assert_cmpfloat (lsg_copy_progress_fraction (empty), ==, 1.0);

  /* A directly-constructed partial + complete state. */
  LsgCopyFlow partial = { .kind = LSG_COPY_FLOW_STREAMING, .row_count = 8, .rows_done = 2 };
  g_assert_cmpfloat (lsg_copy_progress_fraction (partial), ==, 0.25);

  LsgCopyFlow full = { .kind = LSG_COPY_FLOW_DONE, .outcome = LSG_COPY_OUTCOME_COMPLETE,
                       .row_count = 8, .rows_done = 8 };
  g_assert_cmpfloat (lsg_copy_progress_fraction (full), ==, 1.0);
}

/* ========================================================================= */
/* COPY BRIDGE (over the real core; find.csv + copyquote.csv fixtures)        */
/* ========================================================================= */

/* find.csv (header name,qty,note ON) — the SAME 8-row fixture the find/filter
 * tests pin against, and byte-identical to the macOS golden:
 *   0 Widget|2|alpha needle   1 NEEDLE|10|beta   2 needle|2.0|gamma
 *   3 gadget|-3|Needle point   4 Gizmo|1e2|delta   5 café|0.5|CAFÉ
 *   6 (empty)|5.|needleneedle  7 plain|abc|end needle */
static const char *k_find_full =
  "Widget\t2\talpha needle\n"
  "NEEDLE\t10\tbeta\n"
  "needle\t2.0\tgamma\n"
  "gadget\t-3\tNeedle point\n"
  "Gizmo\t1e2\tdelta\n"
  "café\t0.5\tCAFÉ\n"
  "\t5.\tneedleneedle\n"
  "plain\tabc\tend needle";

/* copyquote.csv (header c1,c2 ON): row 0 col0 has a literal TAB, col1 a literal
 * quote; row 1 col0 a quoted field with an embedded LF. Each special cell is
 * spreadsheet-quoted (interior quote doubled); the plain cell is raw. */
static const char *k_quote_full = "\"a\tb\"\t\"x\"\"y\"\n\"p\nq\"\tplain";

/* Drive a WHOLE streaming copy of `rect` through the bridge: open, pull chunks,
 * append `written` bytes, until DONE. `g_assert_nonnull(job)` is the RED gate at
 * freeze (the seed's open returns NULL). The fixtures are fully indexed at open,
 * so the sweep never STALLS (asserted) — the stall/resume drive is pinned purely
 * in the view-model tests above. Returns the concatenated TSV bytes (caller frees). */
static GByteArray *
drive_copy (LsgDocument *doc, LsgCopyRect rect, gsize chunk)
{
  LsgCopyJob *job = lsg_document_copy_open (doc, rect);
  g_assert_nonnull (job);                 /* RED: the seed vends no job */

  GByteArray *out = g_byte_array_new ();
  guint8 *buf = g_malloc (chunk > 0 ? chunk : 1);
  guint64 last_rows = 0;
  guint guardc = 0;
  for (;;)
    {
      g_assert_cmpuint (guardc++, <, 5000000);         /* runaway guard */
      LsgCopyStep s = lsg_document_copy_next (job, buf, chunk);
      g_assert_cmpuint (s.written, <=, chunk);
      g_assert_cmpuint (s.rows_done, >=, last_rows);   /* rows_done monotone */
      last_rows = s.rows_done;
      g_assert_cmpint (s.kind, !=, LSG_COPY_STEP_STALLED); /* fully indexed: no stall */
      g_byte_array_append (out, buf, s.written);
      if (s.kind == LSG_COPY_STEP_DONE)
        break;
    }
  lsg_document_copy_close (job);
  g_free (buf);
  return out;
}

static void
assert_tsv_eq (GByteArray *got, const char *expect)
{
  gsize n = strlen (expect);
  g_assert_cmpuint (got->len, ==, n);
  g_assert_cmpint (memcmp (got->data, expect, n), ==, 0);
  g_byte_array_free (got, TRUE);
}

static LsgDocument *
open_fixture (const char *path)
{
  LsgOpenError err = LSG_OPEN_IO;
  LsgDocument *doc = lsg_document_open_local (path, NULL, &err);
  g_assert_nonnull (doc);
  g_assert_cmpint (err, ==, LSG_OPEN_OK);
  return doc;
}

/* --- the full rect is byte-identical to the core/macOS TSV framing --- */

static void
test_bridge_full_rect_byte_identical (void)
{
  LsgDocument *doc = open_fixture (FIND_FIXTURE_PATH);
  g_assert_cmpuint (lsg_document_column_count (doc), ==, 3);

  LsgCopyRect full = { .first_row = 0, .row_count = 8, .first_col = 0, .col_count = 3 };
  assert_tsv_eq (drive_copy (doc, full, 1 << 16), k_find_full);

  lsg_document_close (doc);
}

/* --- a 1x1 rect emits the RAW cell value (never quoted, no trailing LF) --- */

static void
test_bridge_single_cell_raw (void)
{
  LsgDocument *doc = open_fixture (FIND_FIXTURE_PATH);

  /* row 3, col 2 -> "Needle point" raw. */
  LsgCopyRect one = { .first_row = 3, .row_count = 1, .first_col = 2, .col_count = 1 };
  assert_tsv_eq (drive_copy (doc, one, 1 << 16), "Needle point");

  lsg_document_close (doc);
}

/* --- a short row's leading empty field + a single-column sub-window --- */

static void
test_bridge_empty_field_and_sub_column (void)
{
  LsgDocument *doc = open_fixture (FIND_FIXTURE_PATH);

  /* row 6 (empty name) across all columns -> leading empty field. */
  LsgCopyRect row6 = { .first_row = 6, .row_count = 1, .first_col = 0, .col_count = 3 };
  assert_tsv_eq (drive_copy (doc, row6, 1 << 16), "\t5.\tneedleneedle");

  /* qty column (col 1), rows 0..2 -> a multi-row single column. */
  LsgCopyRect subcol = { .first_row = 0, .row_count = 3, .first_col = 1, .col_count = 1 };
  assert_tsv_eq (drive_copy (doc, subcol, 1 << 16), "2\n10\n2.0");

  lsg_document_close (doc);
}

/* --- spreadsheet quoting: TAB/quote/embedded-LF cells wrapped + doubled;
 *     the SAME tab cell as a single-cell copy is RAW --- */

static void
test_bridge_spreadsheet_quoting (void)
{
  LsgDocument *doc = open_fixture (COPYQUOTE_FIXTURE_PATH);
  g_assert_cmpuint (lsg_document_column_count (doc), ==, 2);

  LsgCopyRect full = { .first_row = 0, .row_count = 2, .first_col = 0, .col_count = 2 };
  assert_tsv_eq (drive_copy (doc, full, 1 << 16), k_quote_full);

  /* The tab-containing cell alone is RAW (never quoted). */
  LsgCopyRect one = { .first_row = 0, .row_count = 1, .first_col = 0, .col_count = 1 };
  assert_tsv_eq (drive_copy (doc, one, 1 << 16), "a\tb");

  lsg_document_close (doc);
}

/* --- tiny chunks force many pulls whose bytes still concatenate identically --- */

static void
test_bridge_tiny_chunks_concatenate (void)
{
  LsgDocument *doc = open_fixture (FIND_FIXTURE_PATH);
  LsgCopyRect full = { .first_row = 0, .row_count = 8, .first_col = 0, .col_count = 3 };
  assert_tsv_eq (drive_copy (doc, full, 8), k_find_full);      /* 8-byte chunks */
  lsg_document_close (doc);
}

/* --- an empty / out-of-range rect is a valid job that steps DONE with 0 bytes --- */

static void
test_bridge_empty_and_out_of_range_rect (void)
{
  LsgDocument *doc = open_fixture (FIND_FIXTURE_PATH);

  /* row_count 0 -> nothing to serialize. */
  LsgCopyRect empty_rows = { .first_row = 0, .row_count = 0, .first_col = 0, .col_count = 3 };
  GByteArray *a = drive_copy (doc, empty_rows, 1 << 16);
  g_assert_cmpuint (a->len, ==, 0);
  g_byte_array_free (a, TRUE);

  /* col_count 0 -> nothing to serialize. */
  LsgCopyRect empty_cols = { .first_row = 0, .row_count = 8, .first_col = 0, .col_count = 0 };
  GByteArray *b = drive_copy (doc, empty_cols, 1 << 16);
  g_assert_cmpuint (b->len, ==, 0);
  g_byte_array_free (b, TRUE);

  /* first_col + col_count past the column count -> nothing to serialize. */
  LsgCopyRect oor = { .first_row = 0, .row_count = 8, .first_col = 5, .col_count = 3 };
  GByteArray *c = drive_copy (doc, oor, 1 << 16);
  g_assert_cmpuint (c->len, ==, 0);
  g_byte_array_free (c, TRUE);

  lsg_document_close (doc);
}

/* --- close idempotency / NULL-safety, and leaf-before-root teardown --- */

static void
test_bridge_close_and_teardown (void)
{
  /* NULL-safe close. */
  lsg_document_copy_close (NULL);

  LsgDocument *doc = open_fixture (FIND_FIXTURE_PATH);

  /* Open a job and close it WITHOUT draining (the cancel path: stop pulling +
   * close, no thread to join) — must be clean. */
  LsgCopyRect full = { .first_row = 0, .row_count = 8, .first_col = 0, .col_count = 3 };
  LsgCopyJob *job = lsg_document_copy_open (doc, full);
  g_assert_nonnull (job);                 /* RED: the seed vends no job */
  lsg_document_copy_close (job);

  /* Leaf before root: the job is closed, so closing the document is clean. */
  lsg_document_close (doc);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  /* Pure view-model (the streamCopy drive-loop fold + outcomes). */
  g_test_add_func ("/copy/abi-enum-pins", test_abi_enum_pins);
  g_test_add_func ("/copy/begin", test_begin);
  g_test_add_func ("/copy/fold-more-accumulates", test_fold_more_accumulates);
  g_test_add_func ("/copy/fold-done-complete", test_fold_done_complete);
  g_test_add_func ("/copy/fold-done-cell-cap", test_fold_done_cell_cap);
  g_test_add_func ("/copy/fold-byte-budget", test_fold_byte_budget);
  g_test_add_func ("/copy/fold-stalled-advance-and-resume", test_fold_stalled_advance_and_resume);
  g_test_add_func ("/copy/fold-filtered-stall-no-progress", test_fold_filtered_stall_no_progress);
  g_test_add_func ("/copy/cancel", test_cancel);
  g_test_add_func ("/copy/fold-terminal-and-monotone", test_fold_terminal_and_monotone);
  g_test_add_func ("/copy/progress-fraction", test_progress_fraction);

  /* Copy bridge over the real core. */
  g_test_add_func ("/copy/bridge-full-rect-byte-identical", test_bridge_full_rect_byte_identical);
  g_test_add_func ("/copy/bridge-single-cell-raw", test_bridge_single_cell_raw);
  g_test_add_func ("/copy/bridge-empty-field-and-sub-column", test_bridge_empty_field_and_sub_column);
  g_test_add_func ("/copy/bridge-spreadsheet-quoting", test_bridge_spreadsheet_quoting);
  g_test_add_func ("/copy/bridge-tiny-chunks-concatenate", test_bridge_tiny_chunks_concatenate);
  g_test_add_func ("/copy/bridge-empty-and-out-of-range-rect", test_bridge_empty_and_out_of_range_rect);
  g_test_add_func ("/copy/bridge-close-and-teardown", test_bridge_close_and_teardown);

  return g_test_run ();
}
