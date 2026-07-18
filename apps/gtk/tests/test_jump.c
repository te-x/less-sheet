/*
 * test_jump.c — RED behavior tests for the JUMP module (lsg_jump.h). Slice 3.
 * Display-free (glib only, no GTK). Two halves, mirroring the macOS jump tests
 * (ViewerUiTests: jumpTargetParsingIsOneBasedDigitsOnly64Bit /
 * jumpFlowScansLandsAndCancelsToThePreJumpPosition / jumpBridgeCompletesBehindThe-
 * Frontier), with the two macOS APP-LAYER reject rules (submitJump / foldJump)
 * lifted into the pure view-model so they are gate-pinned here:
 *
 *   PURE VIEW-MODEL — the ABI enum pins; 1-based digits-only 64-bit parse; the
 *   run/reject submit decision (invalid input, and the UNFILTERED upfront
 *   out-of-range reject that a FILTER suppresses); the monotone progress fold;
 *   the landing; the after-scan short-land reject (again FILTER-suppressed —
 *   the "entered number is an ORIGINAL row" rule); and cancel-restores-pre. No
 *   core.
 *
 *   JUMP BRIDGE — the real Zig core through lsg_document_jump_* over the tiny.csv
 *   fixture (header "name,age,city" + 2 data rows: 0 Alice, 1 Bob — the whole
 *   file sits within the initial materialized window, so every jump is behind the
 *   frontier and completes before the start call returns): behind-frontier instant
 *   land, the past-EOF clamp to the last data row, and cancel-after-done as a
 *   no-op — pinning the ls_jump_poll -> LsgJumpStatus mapping.
 *
 * These are RED against the seeded src/lsg_jump.c (a parse that always fails, a
 * submit/resolve/cancel that never leaves IDLE, and a no-op bridge whose poll
 * reports IDLE) and turn GREEN as the module is implemented. Determinism: the
 * fixture is tiny, so the bridge tests assert the IMMEDIATE poll is DONE (the ABI
 * guarantees a behind-frontier / clamped jump completes before the start call
 * returns), which also fails FAST against the IDLE-returning seed.
 */
#include <glib.h>
#include <lesssheet.h>
#include <lsg_document.h>
#include <lsg_jump.h>

/* ========================================================================= */
/* PURE VIEW-MODEL                                                            */
/* ========================================================================= */

/* --- ABI agreement: the frontend jump-state enum mirrors ls_jump_state exactly
 *     (the runtime drift guard; -Werror compilation is the signature guard) --- */

static void
test_abi_enum_pins (void)
{
  g_assert_cmpint (LSG_JUMP_IDLE, ==, LS_JUMP_IDLE);
  g_assert_cmpint (LSG_JUMP_SCANNING, ==, LS_JUMP_SCANNING);
  g_assert_cmpint (LSG_JUMP_DONE, ==, LS_JUMP_DONE);
}

/* --- the initial view-model is idle --- */

static void
test_initial_idle (void)
{
  LsgJumpFlow f = lsg_jump_initial ();
  g_assert_cmpint (f.kind, ==, LSG_JUMP_FLOW_IDLE);
}

/* --- 1-based, digits-only, 64-bit parse (mirrors the macOS parseTarget set) --- */

static void
test_parse (void)
{
  guint64 t = 12345;

  g_assert_true (lsg_jump_parse ("1", &t));
  g_assert_cmpuint (t, ==, 0);
  g_assert_true (lsg_jump_parse ("12", &t));
  g_assert_cmpuint (t, ==, 11);
  g_assert_true (lsg_jump_parse ("007", &t)); /* leading zeros are digits */
  g_assert_cmpuint (t, ==, 6);
  g_assert_true (lsg_jump_parse ("18446744073709551615", &t)); /* G_MAXUINT64 */
  g_assert_cmpuint (t, ==, G_MAXUINT64 - 1);

  /* Every rejection leaves *out_target untouched. */
  const char *rejected[] = {
    "", "0", "00", "12a", "-3", " 5", "5 ", "1.5", "+7", "0x1F",
    "18446744073709551616",       /* > G_MAXUINT64 */
    "99999999999999999999999999", /* far overflow */
    "\xd9\xa1",                   /* Arabic-Indic digit one: non-ASCII */
  };
  for (guint i = 0; i < G_N_ELEMENTS (rejected); i++)
    {
      guint64 sentinel = 777;
      g_assert_false (lsg_jump_parse (rejected[i], &sentinel));
      g_assert_cmpuint (sentinel, ==, 777);
    }
  g_assert_false (lsg_jump_parse (NULL, &t)); /* NULL treated as empty */
}

/* --- submit RUN: a valid, in-range target begins a scan --- */

static void
test_submit_run (void)
{
  /* Exact count, target in range: RUN with the 0-based target + SCANNING. */
  LsgRowCount exact100 = { .count = 100, .exact = TRUE };
  LsgJumpSubmit r = lsg_jump_submit ("100", exact100, FALSE, 5);
  g_assert_cmpint (r.outcome, ==, LSG_JUMP_RUN);
  g_assert_cmpuint (r.target, ==, 99);
  g_assert_cmpint (r.flow.kind, ==, LSG_JUMP_FLOW_SCANNING);
  g_assert_cmpuint (r.flow.target, ==, 99);
  g_assert_cmpuint (r.flow.pre_jump_first_row, ==, 5);
  g_assert_cmpfloat (r.flow.progress, ==, 0.0);
}

/* --- submit REJECTED: invalid input blinks the field, no scan, no move --- */

static void
test_submit_reject_invalid (void)
{
  LsgRowCount exact100 = { .count = 100, .exact = TRUE };
  const char *bad[] = { "", "0", "abc", "18446744073709551616" };
  for (guint i = 0; i < G_N_ELEMENTS (bad); i++)
    {
      LsgJumpSubmit r = lsg_jump_submit (bad[i], exact100, FALSE, 5);
      g_assert_cmpint (r.outcome, ==, LSG_JUMP_REJECTED);
      g_assert_cmpint (r.flow.kind, ==, LSG_JUMP_FLOW_REJECTED);
      g_assert_false (r.flow.has_restore); /* upfront reject: viewport untouched */
    }
}

/* --- submit out-of-range: rejected upfront when EXACT, run when ESTIMATE, and
 *     ALWAYS run when FILTERED (the entered number is an ORIGINAL row) --- */

static void
test_submit_out_of_range (void)
{
  /* Exact + target at/beyond count: rejected upfront, no scan. */
  LsgRowCount exact100 = { .count = 100, .exact = TRUE };
  LsgJumpSubmit at = lsg_jump_submit ("101", exact100, FALSE, 5); /* target 100 == count */
  g_assert_cmpint (at.outcome, ==, LSG_JUMP_REJECTED);
  g_assert_cmpint (at.flow.kind, ==, LSG_JUMP_FLOW_REJECTED);
  g_assert_false (at.flow.has_restore);

  /* The last in-range row (target 99 < 100) still runs. */
  g_assert_cmpint (lsg_jump_submit ("100", exact100, FALSE, 5).outcome, ==, LSG_JUMP_RUN);

  /* Estimate (not exact): out-of-range can only be found by scanning -> RUN. */
  LsgRowCount est100 = { .count = 100, .exact = FALSE };
  LsgJumpSubmit est = lsg_jump_submit ("101", est100, FALSE, 5);
  g_assert_cmpint (est.outcome, ==, LSG_JUMP_RUN);
  g_assert_cmpuint (est.target, ==, 100);

  /* FILTERED: the upfront check is suppressed (target is an ORIGINAL row number,
   * the count is the filtered m) -> RUN even far past the filtered count. */
  LsgJumpSubmit filt = lsg_jump_submit ("1000000", exact100, TRUE, 5);
  g_assert_cmpint (filt.outcome, ==, LSG_JUMP_RUN);
  g_assert_cmpuint (filt.target, ==, 999999);
  g_assert_cmpint (filt.flow.kind, ==, LSG_JUMP_FLOW_SCANNING);
}

/* --- progress folds monotonically; an idle poll never resets a live scan --- */

static void
test_resolve_progress (void)
{
  LsgJumpSubmit r = lsg_jump_submit ("101", (LsgRowCount){ .count = 1000, .exact = TRUE }, FALSE, 5);
  LsgJumpFlow scanning = r.flow; /* SCANNING(target 100, pre 5, 0) */
  g_assert_cmpint (scanning.kind, ==, LSG_JUMP_FLOW_SCANNING);

  LsgJumpFlow p1 = lsg_jump_resolve (scanning, (LsgJumpStatus){ LSG_JUMP_SCANNING, 0.5, 0 }, FALSE);
  g_assert_cmpint (p1.kind, ==, LSG_JUMP_FLOW_SCANNING);
  g_assert_cmpfloat (p1.progress, ==, 0.5);
  g_assert_cmpuint (p1.target, ==, 100);
  g_assert_cmpuint (p1.pre_jump_first_row, ==, 5);

  /* A stale (lower) progress poll never regresses the display. */
  LsgJumpFlow p2 = lsg_jump_resolve (p1, (LsgJumpStatus){ LSG_JUMP_SCANNING, 0.4, 0 }, FALSE);
  g_assert_cmpfloat (p2.progress, ==, 0.5);

  /* An idle poll leaves a live scan unchanged (only cancel ends it). */
  LsgJumpFlow p3 = lsg_jump_resolve (p1, (LsgJumpStatus){ LSG_JUMP_IDLE, 0.0, 0 }, FALSE);
  g_assert_cmpint (p3.kind, ==, LSG_JUMP_FLOW_SCANNING);
  g_assert_cmpfloat (p3.progress, ==, 0.5);
}

/* --- DONE lands on an exact hit; a short land past EOF rejects + restores;
 *     a FILTERED short land LANDS (filtered index, not comparable) --- */

static void
test_resolve_land_and_reject (void)
{
  LsgJumpFlow scanning = lsg_jump_submit ("101", (LsgRowCount){ .count = 1000, .exact = TRUE }, FALSE, 5).flow;
  g_assert_cmpuint (scanning.target, ==, 100);

  /* Exact hit: landed == target -> LANDED. */
  LsgJumpFlow landed = lsg_jump_resolve (scanning, (LsgJumpStatus){ LSG_JUMP_DONE, 1.0, 100 }, FALSE);
  g_assert_cmpint (landed.kind, ==, LSG_JUMP_FLOW_LANDED);
  g_assert_cmpuint (landed.landed_row, ==, 100);

  /* Short land (the core clamped past EOF): landed 42 < target 100, UNFILTERED
   * -> REJECTED, re-anchor to the captured pre-jump first row. */
  LsgJumpFlow shortLand = lsg_jump_resolve (scanning, (LsgJumpStatus){ LSG_JUMP_DONE, 1.0, 42 }, FALSE);
  g_assert_cmpint (shortLand.kind, ==, LSG_JUMP_FLOW_REJECTED);
  g_assert_true (shortLand.has_restore);
  g_assert_cmpuint (shortLand.restore_first_row, ==, 5);

  /* FILTERED short land: landed (a filtered index) < target (an original row) is
   * EXPECTED -> LANDED, never rejected. */
  LsgJumpFlow filtScan = lsg_jump_submit ("1000000", (LsgRowCount){ .count = 10, .exact = TRUE }, TRUE, 5).flow;
  LsgJumpFlow filtLanded = lsg_jump_resolve (filtScan, (LsgJumpStatus){ LSG_JUMP_DONE, 1.0, 4 }, TRUE);
  g_assert_cmpint (filtLanded.kind, ==, LSG_JUMP_FLOW_LANDED);
  g_assert_cmpuint (filtLanded.landed_row, ==, 4);
}

/* --- cancel restores the pre-jump position; non-scanning flows are stable --- */

static void
test_cancel_and_stability (void)
{
  LsgJumpFlow scanning = lsg_jump_submit ("101", (LsgRowCount){ .count = 1000, .exact = TRUE }, FALSE, 5).flow;

  LsgJumpFlow cancelled = lsg_jump_cancel (scanning);
  g_assert_cmpint (cancelled.kind, ==, LSG_JUMP_FLOW_CANCELLED);
  g_assert_cmpuint (cancelled.restore_first_row, ==, 5);

  /* Non-scanning flows are stable under resolve AND cancel. */
  LsgJumpFlow idle = lsg_jump_initial ();
  g_assert_cmpint (lsg_jump_resolve (idle, (LsgJumpStatus){ LSG_JUMP_DONE, 1.0, 9 }, FALSE).kind, ==, LSG_JUMP_FLOW_IDLE);
  g_assert_cmpint (lsg_jump_cancel (idle).kind, ==, LSG_JUMP_FLOW_IDLE);

  LsgJumpFlow landed = lsg_jump_resolve (scanning, (LsgJumpStatus){ LSG_JUMP_DONE, 1.0, 100 }, FALSE);
  g_assert_cmpint (landed.kind, ==, LSG_JUMP_FLOW_LANDED);
  g_assert_cmpint (lsg_jump_resolve (landed, (LsgJumpStatus){ LSG_JUMP_SCANNING, 0.2, 0 }, FALSE).kind, ==, LSG_JUMP_FLOW_LANDED);
  g_assert_cmpint (lsg_jump_cancel (landed).kind, ==, LSG_JUMP_FLOW_LANDED);

  g_assert_cmpint (lsg_jump_cancel (cancelled).kind, ==, LSG_JUMP_FLOW_CANCELLED);
}

/* ========================================================================= */
/* JUMP BRIDGE (over the real core, tiny.csv fixture)                         */
/* ========================================================================= */

static LsgDocument *
open_tiny_fixture (void)
{
  LsgOpenError err = LSG_OPEN_IO;
  LsgDocument *doc = lsg_document_open_local (FIXTURE_PATH, NULL, &err);
  g_assert_nonnull (doc);
  g_assert_cmpint (err, ==, LSG_OPEN_OK);
  return doc;
}

/* --- behind-frontier jumps complete before the start call returns; cancel after
 *     done is a no-op (mirrors macOS jumpBridgeCompletesBehindTheFrontier) --- */

static void
test_bridge_behind_frontier (void)
{
  LsgDocument *doc = open_tiny_fixture ();

  /* The whole tiny file is within the initial window -> jump to data row 1 (Bob)
   * is behind the frontier: DONE immediately, no poll loop. */
  lsg_document_jump_start (doc, 1);
  LsgJumpStatus s = lsg_document_jump_poll (doc);
  g_assert_cmpint (s.state, ==, LSG_JUMP_DONE);
  g_assert_cmpuint (s.landed_row, ==, 1);
  g_assert_cmpfloat (s.progress, ==, 1.0);

  /* Cancel after completion is a no-op: DONE persists (mirrors ls_jump_cancel). */
  lsg_document_jump_cancel (doc);
  s = lsg_document_jump_poll (doc);
  g_assert_cmpint (s.state, ==, LSG_JUMP_DONE);
  g_assert_cmpuint (s.landed_row, ==, 1);

  /* Jump to the first data row (Alice). */
  lsg_document_jump_start (doc, 0);
  s = lsg_document_jump_poll (doc);
  g_assert_cmpint (s.state, ==, LSG_JUMP_DONE);
  g_assert_cmpuint (s.landed_row, ==, 0);

  lsg_document_close (doc);
}

/* --- a target past EOF clamps to the last data row (never denied) --- */

static void
test_bridge_eof_clamp (void)
{
  LsgDocument *doc = open_tiny_fixture ();

  /* 2 data rows (last = index 1); the whole file is scanned (count exact) so a
   * far target clamps to the last data row, DONE before the call returns. */
  lsg_document_jump_start (doc, 1000000000);
  LsgJumpStatus s = lsg_document_jump_poll (doc);
  g_assert_cmpint (s.state, ==, LSG_JUMP_DONE);
  g_assert_cmpuint (s.landed_row, ==, 1);

  lsg_document_close (doc);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  /* Pure view-model. */
  g_test_add_func ("/jump/abi-enum-pins", test_abi_enum_pins);
  g_test_add_func ("/jump/initial-idle", test_initial_idle);
  g_test_add_func ("/jump/parse", test_parse);
  g_test_add_func ("/jump/submit-run", test_submit_run);
  g_test_add_func ("/jump/submit-reject-invalid", test_submit_reject_invalid);
  g_test_add_func ("/jump/submit-out-of-range", test_submit_out_of_range);
  g_test_add_func ("/jump/resolve-progress", test_resolve_progress);
  g_test_add_func ("/jump/resolve-land-and-reject", test_resolve_land_and_reject);
  g_test_add_func ("/jump/cancel-and-stability", test_cancel_and_stability);

  /* Jump bridge over the real core. */
  g_test_add_func ("/jump/bridge-behind-frontier", test_bridge_behind_frontier);
  g_test_add_func ("/jump/bridge-eof-clamp", test_bridge_eof_clamp);

  return g_test_run ();
}
