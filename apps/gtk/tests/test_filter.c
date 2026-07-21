/*
 * test_filter.c — RED behavior tests for the FILTER-TO-MATCHES module
 * (lsg_filter.h). Slice 4. Display-free (glib only, no GTK). Two halves,
 * mirroring the macOS FilteredViewsTests + the ViewerModel toggle state:
 *
 *   PURE VIEW-MODEL — the C port of FilterControl + the macOS toggle app-state:
 *   the ABI filter-state pin, the identity/apply/clear/fold transitions (incl.
 *   the RE-APPLY keeps-M rule and the persistent-mode fold guard), the
 *   "Filtered — N of M rows" banner state machine (scanning / done / cancelled /
 *   estimated M / empty result), and the two composition facts — the jump
 *   row-count hint (M while filtered) + driving the FROZEN jump view-model with
 *   `filtered = active`, and the find compose reuse (apply resets find, keeps the
 *   draft). No core.
 *
 *   FILTER BRIDGE — the real Zig core through lsg_document_filter_* over the
 *   find.csv fixture: set a WHERE / TEXT filter (the view swaps to the matching
 *   rows, row count = m, the gutter shows ORIGINAL numbers via the frozen
 *   slice-1 lsg_window_source_row), clear (identity restored), invalid-request
 *   rejection leaving the view unchanged, the zero-match empty view, the
 *   fresh/re-opened IDLE state, the Match-case flag (the filter inherits
 *   case_sensitive from the same request), and the two compositions END-TO-END
 *   over the core — a filtered jump lands on the nearest match's filtered index,
 *   and a find within a filter counts only the filtered rows.
 *
 * These are RED against the seeded src/lsg_filter.c (identity-only view-model +
 * no-op bridge) and turn GREEN as the module is implemented. Determinism: the
 * fixture is tiny (8 data rows) so filter/match/jump scans complete in well under
 * a millisecond; every bridge test asserts lsg_document_filter_set(...) == TRUE
 * BEFORE any poll loop, so the unimplemented seed fails FAST instead of waiting
 * out the bounded (~10 s) poll.
 *
 * find.csv data rows (header "name,qty,note" is ON) — the SAME settled fixture
 * the find tests pin against, reused verbatim:
 *   0: Widget | 2   | alpha needle      4: Gizmo | 1e2 | delta
 *   1: NEEDLE | 10  | beta              5: café  | 0.5 | CAFÉ
 *   2: needle | 2.0 | gamma             6:       | 5.  | needleneedle
 *   3: gadget | -3  | Needle point      7: plain | abc | end needle
 *
 *   TEXT "needle" (case-insensitive default, all columns) -> rows 0,1,2,3,6,7 (m = 6)
 *   WHERE qty <= 2 (numeric)                               -> rows 0,2,3,5     (m = 4)
 */
#include <glib.h>
#include <lesssheet.h>
#include <lsg_document.h>
#include <lsg_find.h>
#include <lsg_jump.h>
#include <lsg_filter.h>

/* ========================================================================= */
/* PURE VIEW-MODEL                                                            */
/* ========================================================================= */

/* --- ABI agreement: the core filter-state values the bridge switch relies on
 *     are as expected (the runtime drift guard; -Werror compilation is the
 *     signature drift guard). --- */

static void
test_abi_filter_pins (void)
{
  g_assert_cmpint (LS_FILTER_IDLE, ==, 0);
  g_assert_cmpint (LS_FILTER_SCANNING, ==, 1);
  g_assert_cmpint (LS_FILTER_DONE, ==, 2);
  g_assert_cmpint (LS_FILTER_CANCELLED, ==, 3);
}

/* --- the initial state is the identity view (no filter) --- */

static void
test_initial_identity (void)
{
  LsgFilterState s = lsg_filter_initial ();
  g_assert_false (s.active);

  /* No banner in the identity view. */
  LsgFilterBanner b;
  g_assert_false (lsg_filter_banner (s, &b));

  /* The jump hint passes the identity row-count through unchanged. */
  LsgRowCount id = { .count = 1000, .exact = TRUE };
  LsgRowCount hint = lsg_filter_jump_rowcount (s, id);
  g_assert_cmpuint (hint.count, ==, 1000);
  g_assert_true (hint.exact);
}

/* --- apply captures the base M; re-apply keeps the original M --- */

static void
test_applied_captures_m (void)
{
  LsgFilterState s = lsg_filter_initial ();

  /* First apply: capture M = the identity count read before the set. */
  LsgRowCount baseM = { .count = 1000, .exact = TRUE };
  LsgFilterSnapshot scanning = {
    .phase = LSG_FILTER_PHASE_SCANNING, .progress = 0.0, .total = 12, .total_exact = FALSE
  };
  s = lsg_filter_applied (s, baseM, scanning);
  g_assert_true (s.active);
  g_assert_cmpuint (s.document_rows.count, ==, 1000);
  g_assert_true (s.document_rows.exact);
  g_assert_cmpuint (s.snapshot.total, ==, 12);
  g_assert_cmpint (s.snapshot.phase, ==, LSG_FILTER_PHASE_SCANNING);

  /* The jump hint now reports the base document count M, not the filtered m. */
  LsgRowCount filteredM = { .count = 12, .exact = FALSE };  /* the session now reports m */
  LsgRowCount hint = lsg_filter_jump_rowcount (s, filteredM);
  g_assert_cmpuint (hint.count, ==, 1000);
  g_assert_true (hint.exact);

  /* Re-apply while already filtered: the passed count is the filtered m (the
   * base is no longer knowable through the session) and MUST be ignored — M is
   * retained from the first capture. */
  LsgRowCount wrongM = { .count = 12, .exact = FALSE };
  LsgFilterSnapshot rescan = {
    .phase = LSG_FILTER_PHASE_SCANNING, .progress = 0.0, .total = 3, .total_exact = FALSE
  };
  s = lsg_filter_applied (s, wrongM, rescan);
  g_assert_true (s.active);
  g_assert_cmpuint (s.document_rows.count, ==, 1000);   /* kept */
  g_assert_true (s.document_rows.exact);
  g_assert_cmpuint (s.snapshot.total, ==, 3);           /* new filter's fresh poll */
}

/* --- clear restores the identity view; no-op when already unfiltered --- */

static void
test_cleared_restores_identity (void)
{
  LsgRowCount baseM = { .count = 500, .exact = TRUE };
  LsgFilterSnapshot done = {
    .phase = LSG_FILTER_PHASE_DONE, .progress = 1.0, .total = 40, .total_exact = TRUE
  };
  LsgFilterState s = lsg_filter_applied (lsg_filter_initial (), baseM, done);
  g_assert_true (s.active);

  LsgFilterState cleared = lsg_filter_cleared (s);
  g_assert_false (cleared.active);
  LsgFilterBanner b;
  g_assert_false (lsg_filter_banner (cleared, &b));

  /* Clearing the identity view is a harmless no-op (still unfiltered). */
  LsgFilterState c2 = lsg_filter_cleared (lsg_filter_initial ());
  g_assert_false (c2.active);
}

/* --- fold: replace on a real poll; unchanged on nil/idle or when unfiltered --- */

static void
test_resolved_fold (void)
{
  LsgRowCount baseM = { .count = 1000, .exact = TRUE };
  LsgFilterSnapshot first = {
    .phase = LSG_FILTER_PHASE_SCANNING, .progress = 0.2, .total = 3, .total_exact = FALSE
  };
  LsgFilterState s = lsg_filter_applied (lsg_filter_initial (), baseM, first);

  /* A growing poll folds in (the core guarantees total monotone). */
  LsgFilterSnapshot grow = {
    .phase = LSG_FILTER_PHASE_SCANNING, .progress = 0.6, .total = 9, .total_exact = FALSE
  };
  s = lsg_filter_resolved (s, TRUE, grow);
  g_assert_cmpuint (s.snapshot.total, ==, 9);
  g_assert_cmpfloat (s.snapshot.progress, ==, 0.6);
  g_assert_true (s.active);
  g_assert_cmpuint (s.document_rows.count, ==, 1000);   /* M unchanged by a fold */

  /* Completion folds in and latches. */
  LsgFilterSnapshot done = {
    .phase = LSG_FILTER_PHASE_DONE, .progress = 1.0, .total = 9, .total_exact = TRUE
  };
  s = lsg_filter_resolved (s, TRUE, done);
  g_assert_cmpint (s.snapshot.phase, ==, LSG_FILTER_PHASE_DONE);
  g_assert_true (s.snapshot.total_exact);

  /* A nil (idle) poll never drops filtered mode — a filter persists in the core
   * until an explicit clear / re-open. */
  LsgFilterSnapshot ignored = { 0 };
  LsgFilterState r = lsg_filter_resolved (s, FALSE, ignored);
  g_assert_true (r.active);
  g_assert_cmpuint (r.snapshot.total, ==, 9);

  /* Folding an (unfiltered) identity state is a no-op. */
  LsgFilterState idn = lsg_filter_resolved (lsg_filter_initial (), TRUE, done);
  g_assert_false (idn.active);
}

/* --- the banner state machine (Filtered — N of M rows / no matching rows) --- */

static void
test_banner_states (void)
{
  LsgFilterBanner b;

  /* SCANNING: N converging, progress shown, not final; M exact. */
  LsgRowCount baseM = { .count = 1000, .exact = TRUE };
  LsgFilterSnapshot scanning = {
    .phase = LSG_FILTER_PHASE_SCANNING, .progress = 0.4, .total = 250, .total_exact = FALSE
  };
  LsgFilterState s = lsg_filter_applied (lsg_filter_initial (), baseM, scanning);
  g_assert_true (lsg_filter_banner (s, &b));
  g_assert_cmpuint (b.matching, ==, 250);
  g_assert_cmpuint (b.document_rows, ==, 1000);
  g_assert_false (b.document_rows_estimated);
  g_assert_false (b.matching_is_final);
  g_assert_true (b.has_progress);
  g_assert_cmpfloat (b.progress, ==, 0.4);
  g_assert_false (b.is_empty_result);

  /* DONE: N final, no progress. */
  LsgFilterSnapshot done = {
    .phase = LSG_FILTER_PHASE_DONE, .progress = 1.0, .total = 300, .total_exact = TRUE
  };
  s = lsg_filter_resolved (s, TRUE, done);
  g_assert_true (lsg_filter_banner (s, &b));
  g_assert_cmpuint (b.matching, ==, 300);
  g_assert_true (b.matching_is_final);
  g_assert_false (b.has_progress);
  g_assert_false (b.is_empty_result);

  /* CANCELLED (a jump/find took the scan slot): the mode persists, the banner
   * keeps its frozen progress and is NOT final. */
  LsgFilterSnapshot cancelled = {
    .phase = LSG_FILTER_PHASE_CANCELLED, .progress = 0.7, .total = 280, .total_exact = FALSE
  };
  s = lsg_filter_resolved (s, TRUE, cancelled);
  g_assert_true (lsg_filter_banner (s, &b));
  g_assert_cmpuint (b.matching, ==, 280);
  g_assert_true (b.has_progress);
  g_assert_cmpfloat (b.progress, ==, 0.7);
  g_assert_false (b.matching_is_final);

  /* Estimated M renders with a "~": document_rows_estimated tracks !exact. */
  LsgRowCount estM = { .count = 900000, .exact = FALSE };
  LsgFilterState se = lsg_filter_applied (lsg_filter_initial (), estM, scanning);
  g_assert_true (lsg_filter_banner (se, &b));
  g_assert_true (b.document_rows_estimated);

  /* Empty result: the scan finished with zero matches -> "no matching rows". */
  LsgFilterSnapshot empty = {
    .phase = LSG_FILTER_PHASE_DONE, .progress = 1.0, .total = 0, .total_exact = TRUE
  };
  LsgFilterState z = lsg_filter_applied (lsg_filter_initial (), baseM, empty);
  g_assert_true (lsg_filter_banner (z, &b));
  g_assert_cmpuint (b.matching, ==, 0);
  g_assert_true (b.matching_is_final);
  g_assert_true (b.is_empty_result);
}

/* --- composition: filter -> jump (the row-count hint + the `filtered` flag drive
 *     the FROZEN jump view-model to suppress the out-of-range reject) --- */

static void
test_compose_jump (void)
{
  /* Base document has 1000 rows; a WHERE filter keeps only 5 (m = 5). */
  LsgRowCount baseM = { .count = 1000, .exact = TRUE };
  LsgFilterSnapshot done5 = {
    .phase = LSG_FILTER_PHASE_DONE, .progress = 1.0, .total = 5, .total_exact = TRUE
  };
  LsgFilterState filtered = lsg_filter_applied (lsg_filter_initial (), baseM, done5);
  /* The session now reports the filtered m = 5. */
  LsgRowCount filteredRC = { .count = 5, .exact = TRUE };

  /* Jump hint = base M (1000) while filtered (the jump box takes ORIGINAL
   * numbers), not the filtered m (5). */
  LsgRowCount hint = lsg_filter_jump_rowcount (filtered, filteredRC);
  g_assert_cmpuint (hint.count, ==, 1000);

  /* Drive the FROZEN jump submit with `filtered = state.active`: an ORIGINAL row
   * (row 900) far past the filtered m is NOT rejected — a filtered jump clamps to
   * the last match. "901" is 1-based -> original row 900. */
  LsgJumpSubmit run = lsg_jump_submit ("901", hint, filtered.active, 0);
  g_assert_cmpint (run.outcome, ==, LSG_JUMP_RUN);
  g_assert_cmpuint (run.target, ==, 900);

  /* The SAME target UNFILTERED, with the (smaller, exact) filtered count, would
   * reject upfront — proving the `filtered` flag is what suppresses it. */
  LsgFilterState identity = lsg_filter_initial ();
  LsgRowCount idHint = lsg_filter_jump_rowcount (identity, filteredRC);
  g_assert_cmpuint (idHint.count, ==, 5);
  LsgJumpSubmit rej = lsg_jump_submit ("901", idHint, identity.active, 0);
  g_assert_cmpint (rej.outcome, ==, LSG_JUMP_REJECTED);

  /* A filtered short-land (landed filtered index < the ORIGINAL target) LANDS,
   * never rejects — the resolve composition (r is a filtered index, target an
   * original row: not comparable). */
  LsgJumpFlow scanning = run.flow;
  LsgJumpStatus shortLand = { .state = LSG_JUMP_DONE, .progress = 1.0, .landed_row = 4 };
  LsgJumpFlow landed = lsg_jump_resolve (scanning, shortLand, filtered.active);
  g_assert_cmpint (landed.kind, ==, LSG_JUMP_FLOW_LANDED);
  g_assert_cmpuint (landed.landed_row, ==, 4);

  /* Unfiltered, the identical short-land is the after-scan out-of-range reject. */
  LsgJumpFlow uScanning = lsg_jump_submit ("6", (LsgRowCount){ .count = 5, .exact = FALSE }, FALSE, 2).flow;
  LsgJumpFlow uRej = lsg_jump_resolve (uScanning, shortLand, FALSE);
  g_assert_cmpint (uRej.kind, ==, LSG_JUMP_FLOW_REJECTED);
}

/* --- composition: filter <-> find (apply reuses the find compose + resets the
 *     active find, keeping the draft; the toggle-enable rule) --- */

static void
test_compose_find (void)
{
  /* An empty find draft is NOT filterable (macOS canApplyFilter): the toggle may
   * only turn ON when the compose is not IGNORED. */
  LsgFindSession empty = lsg_find_initial ();
  guint32 all3[] = { 0, 1, 2 };
  g_assert_cmpint (lsg_find_submit (empty, all3, 3, 3).outcome, ==, LSG_FIND_IGNORED);

  /* A composed draft yields the SAME request Find would run — the one routed to
   * the filter bridge. */
  LsgFindSession fs = lsg_find_initial ();
  fs.draft.mode = LSG_FIND_TEXT;
  fs.draft.text = "needle";
  fs = lsg_find_began (fs);                 /* an active find is running */
  g_assert_true (fs.display.active);
  LsgFindSubmit sub = lsg_find_submit (fs, all3, 3, 3);
  g_assert_cmpint (sub.outcome, ==, LSG_FIND_RUN);
  g_assert_cmpstr (sub.request.value, ==, "needle");

  /* Applying a filter enters filtered mode; the caller resets the active find
   * (lsg_find_invalidated) and jump (lsg_jump_initial). The find DISPLAY clears
   * but the DRAFT is retained (re-running / editing the predicate is one Enter). */
  LsgRowCount baseM = { .count = 8, .exact = TRUE };
  LsgFilterSnapshot done6 = {
    .phase = LSG_FILTER_PHASE_DONE, .progress = 1.0, .total = 6, .total_exact = TRUE
  };
  LsgFilterState filter = lsg_filter_applied (lsg_filter_initial (), baseM, done6);
  LsgFindSession afterFind = lsg_find_invalidated (fs);
  LsgJumpFlow afterJump = lsg_jump_initial ();

  g_assert_true (filter.active);
  g_assert_false (afterFind.display.active);
  g_assert_cmpstr (afterFind.draft.text, ==, "needle");  /* draft retained */
  g_assert_cmpint (afterJump.kind, ==, LSG_JUMP_FLOW_IDLE);
}

/* ========================================================================= */
/* FILTER BRIDGE (over the real core, find.csv fixture)                       */
/* ========================================================================= */

static LsgDocument *
open_find_fixture (void)
{
  LsgOpenError err = LSG_OPEN_IO;
  LsgDocument *doc = lsg_document_open_local (FIND_FIXTURE_PATH, NULL, &err);
  g_assert_nonnull (doc);
  g_assert_cmpint (err, ==, LSG_OPEN_OK);
  return doc;
}

/* Poll until the filter-scan is final (total_exact), bounded (~10 s). */
static gboolean
wait_filter_final (LsgDocument *doc, LsgFilterSnapshot *out)
{
  for (int i = 0; i < 5000; i++)
    {
      LsgFilterSnapshot s;
      if (lsg_document_filter_poll (doc, &s) && s.total_exact)
        {
          if (out)
            *out = s;
          return TRUE;
        }
      g_usleep (2000);
    }
  return FALSE;
}

/* Poll a jump until DONE, bounded (~10 s). */
static gboolean
wait_jump_done (LsgDocument *doc, LsgJumpStatus *out)
{
  for (int i = 0; i < 5000; i++)
    {
      LsgJumpStatus s = lsg_document_jump_poll (doc);
      if (s.state == LSG_JUMP_DONE)
        {
          if (out)
            *out = s;
          return TRUE;
        }
      g_usleep (2000);
    }
  return FALSE;
}

/* Poll a search until final (total_exact), bounded (~10 s). */
static gboolean
wait_search_final (LsgDocument *doc, LsgSearchSnapshot *out)
{
  for (int i = 0; i < 5000; i++)
    {
      LsgSearchSnapshot s;
      if (lsg_document_search_poll (doc, &s) && s.total_exact)
        {
          if (out)
            *out = s;
          return TRUE;
        }
      g_usleep (2000);
    }
  return FALSE;
}

/* Poll the search NAV slot until it RESOLVES — the pending SEARCHING/NONE state
 * gives way to FOUND or EXHAUSTED — bounded (~10 s). The caller issues the nav
 * first (as with wait_jump_done / wait_search_final above, and mirroring the macOS
 * `navFound` helper in FilteredViewsTests): the ABI makes a nav synchronous once
 * the scan is DONE, but the poll/control lane still RESOLVES it by polling (the
 * production `find_poll_fold` folds the nav every tick), so a test reads the
 * landing off a poll loop — never a single post-nav poll. */
static gboolean
wait_search_nav_resolved (LsgDocument *doc, LsgSearchSnapshot *out)
{
  for (int i = 0; i < 5000; i++)
    {
      LsgSearchSnapshot s;
      if (lsg_document_search_poll (doc, &s)
          && (s.nav == LSG_SEARCH_NAV_FOUND || s.nav == LSG_SEARCH_NAV_EXHAUSTED))
        {
          if (out)
            *out = s;
          return TRUE;
        }
      g_usleep (2000);
    }
  return FALSE;
}

/* The ORIGINAL (gutter) row numbers of the first `m` filtered rows, in filtered
 * order (via the frozen slice-1 window + source-row accessors). Caller frees. */
static GArray *
filtered_source_rows (LsgDocument *doc, guint32 m)
{
  GArray *rows = g_array_new (FALSE, FALSE, sizeof (guint64));
  LsgWindow *w = lsg_document_set_window (doc, 0, m, 0, 3);
  guint32 got = lsg_window_row_count (w);
  for (guint32 i = 0; i < got; i++)
    {
      guint64 sr = lsg_window_source_row (w, i);
      g_array_append_val (rows, sr);
    }
  lsg_window_free (w);
  return rows;
}

static void
assert_rows (GArray *got, const guint64 *want, guint n)
{
  g_assert_cmpuint (got->len, ==, n);
  for (guint i = 0; i < n; i++)
    g_assert_cmpuint (g_array_index (got, guint64, i), ==, want[i]);
}

/* --- a fresh session has no filter (IDLE -> no snapshot) --- */

static void
test_bridge_fresh_idle (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* Fresh session: no filter -> "no snapshot". */
  LsgFilterSnapshot fs;
  g_assert_false (lsg_document_filter_poll (doc, &fs));

  /* Identity row count is the full document (8 data rows). */
  LsgRowCount rc = lsg_document_row_count (doc);
  g_assert_cmpuint (rc.count, ==, 8);
  g_assert_true (rc.exact);

  /* Setting a valid filter flips the poll to a real snapshot (RED on the seed). */
  g_assert_true (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 1, .op = LSG_SEARCH_OP_LE, .value = "2" }));
  g_assert_true (wait_filter_final (doc, &fs));

  lsg_document_close (doc);
}

/* --- set a WHERE filter: the view swaps to the matching rows, count = m, the
 *     gutter shows ORIGINAL numbers --- */

static void
test_bridge_set_where_filter (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* qty <= 2 numerically -> original rows 0,2,3,5 (m = 4). */
  g_assert_true (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 1, .op = LSG_SEARCH_OP_LE, .value = "2" }));
  LsgFilterSnapshot fs;
  g_assert_true (wait_filter_final (doc, &fs));
  g_assert_cmpint (fs.phase, ==, LSG_FILTER_PHASE_DONE);
  g_assert_cmpuint (fs.total, ==, 4);
  g_assert_true (fs.total_exact);

  /* The document now reports the filtered match count m as its row count. */
  LsgRowCount rc = lsg_document_row_count (doc);
  g_assert_cmpuint (rc.count, ==, 4);
  g_assert_true (rc.exact);

  /* The filtered window serves those rows; the gutter shows their ORIGINAL
   * (non-contiguous) numbers. */
  GArray *src = filtered_source_rows (doc, 4);
  assert_rows (src, (const guint64[]){ 0, 2, 3, 5 }, 4);
  g_array_free (src, TRUE);

  lsg_document_close (doc);
}

/* --- set a TEXT filter: case-insensitive substring (Match case OFF default)
 *     over all columns --- */

static void
test_bridge_set_text_filter (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* "needle" folds ASCII (Match case OFF) -> original rows 0,1,2,3,6,7 (m = 6). */
  g_assert_true (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "needle" }));
  LsgFilterSnapshot fs;
  g_assert_true (wait_filter_final (doc, &fs));
  g_assert_cmpuint (fs.total, ==, 6);

  LsgRowCount rc = lsg_document_row_count (doc);
  g_assert_cmpuint (rc.count, ==, 6);

  GArray *src = filtered_source_rows (doc, 6);
  assert_rows (src, (const guint64[]){ 0, 1, 2, 3, 6, 7 }, 6);
  g_array_free (src, TRUE);

  lsg_document_close (doc);
}

/* --- the filter honors the request's Match-case flag identically to Find (§6
 *     A3 cross-surface; C8 re-apply): Match case OFF folds an uppercase query,
 *     ON is byte-exact. The filter bridge marshals case_sensitive at the SAME
 *     choke point as Find, so this is RED until that marshaling lands. --- */

static void
test_bridge_filter_case_mode (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* Match case OFF (default): an uppercase "NEEDLE" filter folds -> the 6 needle
   * rows (the SAME set as the lowercase "needle" filter). */
  g_assert_true (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "NEEDLE" }));
  LsgFilterSnapshot fs;
  g_assert_true (wait_filter_final (doc, &fs));
  g_assert_cmpuint (fs.total, ==, 6);
  GArray *src = filtered_source_rows (doc, 6);
  assert_rows (src, (const guint64[]){ 0, 1, 2, 3, 6, 7 }, 6);
  g_array_free (src, TRUE);

  /* Match case ON: the byte-exact "Needle" filter keeps only "Needle point"
   * (original row 3) -> the filtered view inherits case_sensitive. */
  g_assert_true (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "Needle", .case_sensitive = TRUE }));
  g_assert_true (wait_filter_final (doc, &fs));
  g_assert_cmpuint (fs.total, ==, 1);
  src = filtered_source_rows (doc, 1);
  assert_rows (src, (const guint64[]){ 3 }, 1);
  g_array_free (src, TRUE);

  lsg_document_close (doc);
}

/* --- clear restores the identity view --- */

static void
test_bridge_clear_restores_identity (void)
{
  LsgDocument *doc = open_find_fixture ();

  g_assert_true (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "needle" }));
  LsgFilterSnapshot fs;
  g_assert_true (wait_filter_final (doc, &fs));
  g_assert_cmpuint (lsg_document_row_count (doc).count, ==, 6);

  lsg_document_filter_clear (doc);

  /* No filter -> IDLE (no snapshot); the identity view is back. */
  g_assert_false (lsg_document_filter_poll (doc, &fs));
  LsgRowCount rc = lsg_document_row_count (doc);
  g_assert_cmpuint (rc.count, ==, 8);
  g_assert_true (rc.exact);

  /* Row i addresses physical data row i again (source_row identity). */
  LsgWindow *w = lsg_document_set_window (doc, 0, 8, 0, 3);
  g_assert_cmpuint (lsg_window_source_row (w, 0), ==, 0);
  g_assert_cmpuint (lsg_window_source_row (w, 5), ==, 5);
  lsg_window_free (w);

  lsg_document_close (doc);
}

/* --- an invalid filter request is rejected and leaves the view unchanged --- */

static void
test_bridge_reject_unchanged (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* An active WHERE filter (m = 4). */
  g_assert_true (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 1, .op = LSG_SEARCH_OP_LE, .value = "2" }));
  LsgFilterSnapshot fs;
  g_assert_true (wait_filter_final (doc, &fs));
  g_assert_cmpuint (fs.total, ==, 4);

  /* Rejected sets change NOTHING (empty TEXT; ordering op + non-numeric value;
   * out-of-range column) — same rejection rules as Find / ls_search_start. */
  g_assert_false (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "" }));
  g_assert_false (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 1, .op = LSG_SEARCH_OP_LT, .value = "abc" }));
  g_assert_false (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 9, .op = LSG_SEARCH_OP_EQ, .value = "x" }));

  /* The previously active filter is untouched: still m = 4. */
  g_assert_true (lsg_document_filter_poll (doc, &fs));
  g_assert_cmpuint (fs.total, ==, 4);
  g_assert_true (fs.total_exact);
  g_assert_cmpuint (lsg_document_row_count (doc).count, ==, 4);

  lsg_document_close (doc);
}

/* --- a filter matching nothing yields a 0-row view (no matching rows) --- */

static void
test_bridge_empty_result (void)
{
  LsgDocument *doc = open_find_fixture ();

  g_assert_true (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "zzzznomatch" }));
  LsgFilterSnapshot fs;
  g_assert_true (wait_filter_final (doc, &fs));
  g_assert_cmpint (fs.phase, ==, LSG_FILTER_PHASE_DONE);
  g_assert_cmpuint (fs.total, ==, 0);
  g_assert_true (fs.total_exact);

  /* The filtered view has exactly 0 rows. */
  LsgRowCount rc = lsg_document_row_count (doc);
  g_assert_cmpuint (rc.count, ==, 0);
  g_assert_true (rc.exact);
  LsgWindow *w = lsg_document_set_window (doc, 0, 8, 0, 3);
  g_assert_cmpuint (lsg_window_row_count (w), ==, 0);
  lsg_window_free (w);

  /* The banner derived from this poll reads "no matching rows". */
  LsgRowCount baseM = { .count = 8, .exact = TRUE };
  LsgFilterState st = lsg_filter_applied (lsg_filter_initial (), baseM, fs);
  LsgFilterBanner b;
  g_assert_true (lsg_filter_banner (st, &b));
  g_assert_true (b.is_empty_result);

  lsg_document_close (doc);
}

/* --- composition END-TO-END: a jump under a filter lands on the nearest match's
 *     FILTERED index (the entered number is an ORIGINAL row) --- */

static void
test_bridge_jump_under_filter (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* Filter qty <= 2 -> original rows 0,2,3,5 at filtered indices 0,1,2,3. */
  g_assert_true (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 1, .op = LSG_SEARCH_OP_LE, .value = "2" }));
  LsgFilterSnapshot fs;
  g_assert_true (wait_filter_final (doc, &fs));
  g_assert_cmpuint (fs.total, ==, 4);

  /* Jump to ORIGINAL row 1 (not itself a match): the nearest match at/after it is
   * original row 2 -> filtered index 1. */
  lsg_document_jump_start (doc, 1);
  LsgJumpStatus js;
  g_assert_true (wait_jump_done (doc, &js));
  g_assert_cmpuint (js.landed_row, ==, 1);

  /* That landed filtered row's gutter shows its ORIGINAL number (2), >= the
   * requested original row. */
  LsgWindow *w = lsg_document_set_window (doc, js.landed_row, 1, 0, 3);
  g_assert_cmpuint (lsg_window_source_row (w, 0), ==, 2);
  lsg_window_free (w);

  lsg_document_close (doc);
}

/* --- composition END-TO-END: a find within a filter counts only filtered rows -- */

static void
test_bridge_find_within_filter (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* Filter qty <= 2 -> original rows 0,2,3,5. */
  g_assert_true (lsg_document_filter_set (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 1, .op = LSG_SEARCH_OP_LE, .value = "2" }));
  LsgFilterSnapshot fs;
  g_assert_true (wait_filter_final (doc, &fs));
  g_assert_cmpuint (fs.total, ==, 4);

  /* Find "needle" WITHIN the filter: of the filtered rows only originals 0
   * ("alpha needle"), 2 ("needle"), 3 ("Needle point") match -> total 3, in
   * FILTERED coordinates. */
  g_assert_true (lsg_document_search_start (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "needle" }));
  LsgSearchSnapshot ss;
  g_assert_true (wait_search_final (doc, &ss));
  g_assert_cmpuint (ss.total, ==, 3);

  /* The first match is filtered index 0 (original row 0). Poll the nav for FOUND
   * off a loop — mirroring the macOS `navFound` helper and this file's own wait_*
   * pollers: the ABI makes a nav synchronous once the scan is DONE, but the
   * poll/control lane resolves it by polling (production `find_poll_fold` folds it
   * every tick), so we never assume a single post-nav poll has already left
   * SEARCHING. */
  lsg_document_search_nav (doc, lsg_search_nav_from_top ());
  g_assert_true (wait_search_nav_resolved (doc, &ss));
  g_assert_cmpint (ss.nav, ==, LSG_SEARCH_NAV_FOUND);
  g_assert_cmpuint (ss.found.row, ==, 0);

  lsg_document_close (doc);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  /* Pure view-model. */
  g_test_add_func ("/filter/abi-filter-pins", test_abi_filter_pins);
  g_test_add_func ("/filter/initial-identity", test_initial_identity);
  g_test_add_func ("/filter/applied-captures-m", test_applied_captures_m);
  g_test_add_func ("/filter/cleared-restores-identity", test_cleared_restores_identity);
  g_test_add_func ("/filter/resolved-fold", test_resolved_fold);
  g_test_add_func ("/filter/banner-states", test_banner_states);
  g_test_add_func ("/filter/compose-jump", test_compose_jump);
  g_test_add_func ("/filter/compose-find", test_compose_find);

  /* Filter bridge over the real core. */
  g_test_add_func ("/filter/bridge-fresh-idle", test_bridge_fresh_idle);
  g_test_add_func ("/filter/bridge-set-where-filter", test_bridge_set_where_filter);
  g_test_add_func ("/filter/bridge-set-text-filter", test_bridge_set_text_filter);
  g_test_add_func ("/filter/bridge-filter-case-mode", test_bridge_filter_case_mode);
  g_test_add_func ("/filter/bridge-clear-restores-identity", test_bridge_clear_restores_identity);
  g_test_add_func ("/filter/bridge-reject-unchanged", test_bridge_reject_unchanged);
  g_test_add_func ("/filter/bridge-empty-result", test_bridge_empty_result);
  g_test_add_func ("/filter/bridge-jump-under-filter", test_bridge_jump_under_filter);
  g_test_add_func ("/filter/bridge-find-within-filter", test_bridge_find_within_filter);

  return g_test_run ();
}
