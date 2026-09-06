/*
 * test_sort.c — RED behavior tests for the SORT-BY-COLUMN module
 * (lsg_sort.h). Display-free (glib only, no GTK). Three halves, mirroring the
 * macOS SortByColumnTests:
 *
 *   PURE VIEW-MODEL — the ABI sort-state pin, the exhaustive three-state CYCLE
 *   truth table (start fresh / ascending -> descending -> off / stop an
 *   unlanded pass / retry a failed one), the header INDICATOR (only the sort
 *   column; pending while the pass has not landed; failed styling), and the
 *   accessible description. No core.
 *
 *   THE ONE ACCELERATOR TABLE — Ctrl+Shift+S is declared exactly once, in the
 *   frozen lsg_a11y_shortcuts table, under a Sorting group and in GRID scope
 *   (so it never steals a focused GtkText's key), with a non-empty title for
 *   the shortcuts dialog. This is what keeps the accelerator the dialog shows
 *   equal to the one that fires.
 *
 *   SORT BRIDGE — the real Zig core through lsg_document_sort_* over the
 *   find.csv fixture: set a sort (the view re-orders and the gutter still
 * shows ORIGINAL numbers via the frozen slice-1 lsg_window_source_row), sorted
 * coordinates served WITHOUT waiting for the key pass (Amendment 1's
 * converging prefix), descending as the reversed order, composition over an
 * active filter, clear restoring the PRE-SORT file order, out-of-range
 * rejection leaving the view untouched, and the session-only fresh state on a
 * re-open.
 *
 * RED against the seeded src/lsg_sort.c (CLEAR-always cycle, no-op bridge) and
 * GREEN as the module is implemented. Determinism: the fixture is tiny (8 data
 * rows) so a key pass completes in well under a millisecond; every bridge test
 * asserts lsg_document_sort_set(...) == TRUE BEFORE any poll loop, so the
 * unimplemented seed fails FAST instead of waiting out the bounded (~10 s)
 * poll.
 *
 * find.csv data rows (header "name,qty,note" is ON) — the SAME settled fixture
 * the find and filter tests pin against, reused verbatim:
 *   0: Widget | 2   | alpha needle      4: Gizmo | 1e2 | delta
 *   1: NEEDLE | 10  | beta              5: café  | 0.5 | CAFÉ
 *   2: needle | 2.0 | gamma             6:       | 5.  | needleneedle
 *   3: gadget | -3  | Needle point      7: plain | abc | end needle
 *
 * Sorting by NAME (col 0) with no type override: the effective type is
 * UNKNOWN, which sorts as TEXT — ASCII case folded, byte-exact tiebreak, then
 * source order. Ascending:
 *   ""(6) < café(5) < gadget(3) < Gizmo(4) < NEEDLE(1) < needle(2) < plain(7)
 * < Widget(0)
 */
#include <glib.h>
#include <string.h>

#include <lesssheet.h>
#include <lsg_a11y.h>
#include <lsg_document.h>
#include <lsg_filter.h>
#include <lsg_find.h>
#include <lsg_sort.h>

static const guint64 name_ascending[8] = { 6, 5, 3, 4, 1, 2, 7, 0 };
static const guint64 name_descending[8] = { 0, 7, 2, 1, 4, 3, 5, 6 };

/* ========================================================================= */
/* PURE VIEW-MODEL */
/* ========================================================================= */

/* --- ABI agreement: the core sort values the bridge switch relies on are as
 *     expected (the runtime drift guard; -Werror compilation is the signature
 *     drift guard). --- */

static void
test_abi_sort_pins (void)
{
  g_assert_cmpint (LS_SORT_ASCENDING, ==, 0);
  g_assert_cmpint (LS_SORT_DESCENDING, ==, 1);
  g_assert_cmpint (LS_SORT_IDLE, ==, 0);
  g_assert_cmpint (LS_SORT_BUILDING, ==, 1);
  g_assert_cmpint (LS_SORT_ACTIVE, ==, 2);
  g_assert_cmpint (LS_SORT_PARKED, ==, 3);
  g_assert_cmpint (LS_SORT_FAILED, ==, 4);
  g_assert_cmpint (LS_SORT_OK, ==, 0);
  g_assert_cmpint (LS_SORT_ERROR_STORAGE, ==, 1);
  g_assert_cmpint (LS_SORT_ERROR_MEMORY, ==, 2);
  g_assert_cmpuint (sizeof (ls_sort_status), ==, 24);
  /* The frontend mirror uses the SAME numbering, so a switch cannot silently
   * transpose two states. */
  g_assert_cmpint ((int)LSG_SORT_PHASE_BUILDING, ==, (int)LS_SORT_BUILDING);
  g_assert_cmpint ((int)LSG_SORT_PHASE_ACTIVE, ==, (int)LS_SORT_ACTIVE);
  g_assert_cmpint ((int)LSG_SORT_PHASE_PARKED, ==, (int)LS_SORT_PARKED);
  g_assert_cmpint ((int)LSG_SORT_PHASE_FAILED, ==, (int)LS_SORT_FAILED);
}

static LsgSortSnapshot
snap (LsgSortPhase phase, guint column, LsgSortDirection dir, double progress)
{
  LsgSortSnapshot s = { phase, LSG_SORT_ERROR_NONE, column, dir, progress };
  return s;
}

static LsgSortSnapshot
snap_failed (guint column, LsgSortDirection dir, LsgSortError err)
{
  LsgSortSnapshot s = { LSG_SORT_PHASE_FAILED, err, column, dir, 0.4 };
  return s;
}

static void
assert_set (LsgSortIntent got, guint column, LsgSortDirection dir)
{
  g_assert_cmpint (got.kind, ==, LSG_SORT_INTENT_SET);
  g_assert_cmpuint (got.column, ==, column);
  g_assert_cmpint (got.direction, ==, dir);
}

/* --- the cycle: nothing sorted, or a DIFFERENT column, starts fresh
 *     ascending, whatever the current phase/direction --- */

static void
test_cycle_starts_fresh (void)
{
  assert_set (lsg_sort_next (
                  snap (LSG_SORT_PHASE_NONE, 0, LSG_SORT_ASCENDING, 0.0), 2),
              2, LSG_SORT_ASCENDING);

  const LsgSortPhase phases[4]
      = { LSG_SORT_PHASE_ACTIVE, LSG_SORT_PHASE_BUILDING,
          LSG_SORT_PHASE_PARKED, LSG_SORT_PHASE_FAILED };
  const LsgSortDirection dirs[2] = { LSG_SORT_ASCENDING, LSG_SORT_DESCENDING };
  for (int p = 0; p < 4; p++)
    for (int d = 0; d < 2; d++)
      {
        LsgSortSnapshot s
            = (phases[p] == LSG_SORT_PHASE_FAILED)
                  ? snap_failed (0, dirs[d], LSG_SORT_ERROR_STORAGE)
                  : snap (phases[p], 0, dirs[d], 0.5);
        assert_set (lsg_sort_next (s, 1), 1, LSG_SORT_ASCENDING);
      }
}

/* --- the cycle on the SORTED column: ascending -> descending -> off --- */

static void
test_cycle_advances_on_the_sorted_column (void)
{
  assert_set (lsg_sort_next (
                  snap (LSG_SORT_PHASE_ACTIVE, 1, LSG_SORT_ASCENDING, 1.0), 1),
              1, LSG_SORT_DESCENDING);
  g_assert_cmpint (
      lsg_sort_next (snap (LSG_SORT_PHASE_ACTIVE, 1, LSG_SORT_DESCENDING, 1.0),
                     1)
          .kind,
      ==, LSG_SORT_INTENT_CLEAR);
}

/* --- acting on a pass that has NOT landed means STOP, which is the same
 *     intent Cancel issues (ls_sort_clear is both verbs) --- */

static void
test_cycle_on_unlanded_pass_stops (void)
{
  const LsgSortPhase phases[2]
      = { LSG_SORT_PHASE_BUILDING, LSG_SORT_PHASE_PARKED };
  const LsgSortDirection dirs[2] = { LSG_SORT_ASCENDING, LSG_SORT_DESCENDING };
  for (int p = 0; p < 2; p++)
    for (int d = 0; d < 2; d++)
      g_assert_cmpint (
          lsg_sort_next (snap (phases[p], 2, dirs[d], 0.3), 2).kind, ==,
          LSG_SORT_INTENT_CLEAR);
}

/* --- a FAILED pass RETRIES the same request rather than advancing: silently
 *     moving to a direction the user never saw applied is the wrong answer to
 *     "that didn't work" --- */

static void
test_cycle_on_failed_pass_retries (void)
{
  const LsgSortError errs[2]
      = { LSG_SORT_ERROR_STORAGE, LSG_SORT_ERROR_MEMORY };
  const LsgSortDirection dirs[2] = { LSG_SORT_ASCENDING, LSG_SORT_DESCENDING };
  for (int e = 0; e < 2; e++)
    for (int d = 0; d < 2; d++)
      assert_set (lsg_sort_next (snap_failed (0, dirs[d], errs[e]), 0), 0,
                  dirs[d]);
}

/* --- the header indicator: only the sort column; PENDING while the pass has
 *     not landed. PENDING does NOT mean "unsorted": Amendment 1 has the grid
 *     already showing the exact sorted top of what was scanned; it means that
 *     top is still refining, so the header must not claim a settled order.
 *     --- */

static void
test_indicator_states (void)
{
  LsgSortIndicator none = lsg_sort_indicator (
      snap (LSG_SORT_PHASE_NONE, 0, LSG_SORT_ASCENDING, 0.0), 0);
  g_assert_false (none.sorted);

  LsgSortSnapshot active
      = snap (LSG_SORT_PHASE_ACTIVE, 1, LSG_SORT_DESCENDING, 1.0);
  g_assert_false (
      lsg_sort_indicator (active, 0).sorted); /* a different column */
  LsgSortIndicator on = lsg_sort_indicator (active, 1);
  g_assert_true (on.sorted);
  g_assert_cmpint (on.direction, ==, LSG_SORT_DESCENDING);
  g_assert_false (on.pending);
  g_assert_false (on.failed);

  const LsgSortPhase unlanded[2]
      = { LSG_SORT_PHASE_BUILDING, LSG_SORT_PHASE_PARKED };
  for (int p = 0; p < 2; p++)
    {
      LsgSortIndicator ind = lsg_sort_indicator (
          snap (unlanded[p], 1, LSG_SORT_ASCENDING, 0.2), 1);
      g_assert_true (ind.sorted);
      g_assert_true (ind.pending);
      g_assert_false (ind.failed);
      g_assert_cmpint (ind.direction, ==, LSG_SORT_ASCENDING);
    }

  LsgSortIndicator bad = lsg_sort_indicator (
      snap_failed (1, LSG_SORT_ASCENDING, LSG_SORT_ERROR_MEMORY), 1);
  g_assert_true (bad.sorted);
  g_assert_true (bad.failed);
  g_assert_false (bad.pending);
}

/* --- the accessible description names the column, the direction, and the
 *     state; a labelless column falls back to its 1-BASED number --- */

static void
test_describe (void)
{
  char *s = lsg_sort_describe (
      snap (LSG_SORT_PHASE_NONE, 0, LSG_SORT_ASCENDING, 0.0), "Price");
  g_assert_nonnull (s);
  g_assert_cmpstr (s, ==, "not sorted");
  g_free (s);

  s = lsg_sort_describe (
      snap (LSG_SORT_PHASE_ACTIVE, 1, LSG_SORT_ASCENDING, 1.0), "Price");
  g_assert_nonnull (s);
  g_assert_nonnull (g_strstr_len (s, -1, "Price"));
  g_assert_nonnull (g_strstr_len (s, -1, "ascending"));
  g_free (s);

  s = lsg_sort_describe (
      snap (LSG_SORT_PHASE_ACTIVE, 1, LSG_SORT_DESCENDING, 1.0), NULL);
  g_assert_nonnull (s);
  /* No label -> the 1-BASED column number the user sees (column 1 -> "2"). */
  g_assert_nonnull (g_strstr_len (s, -1, "2"));
  g_assert_nonnull (g_strstr_len (s, -1, "descending"));
  g_free (s);

  s = lsg_sort_describe (
      snap_failed (1, LSG_SORT_ASCENDING, LSG_SORT_ERROR_STORAGE), "Price");
  g_assert_nonnull (s);
  g_assert_nonnull (g_strstr_len (s, -1, "failed"));
  g_free (s);
}

/* ========================================================================= */
/* THE ONE ACCELERATOR TABLE */
/* ========================================================================= */

static void
test_shortcut_is_declared_once (void)
{
  guint n = 0;
  const LsgA11yShortcut *t = lsg_a11y_shortcuts (&n);
  g_assert_nonnull (t);
  g_assert_cmpuint (n, ==, (guint)LSG_A11Y_CMD_N);

  const LsgA11yShortcut *sort = NULL;
  guint seen = 0;
  for (guint i = 0; i < n; i++)
    if (t[i].command == LSG_A11Y_CMD_SORT)
      {
        sort = &t[i];
        seen++;
      }
  g_assert_cmpuint (seen, ==, 1);
  g_assert_nonnull (sort);
  g_assert_cmpstr (sort->accel, ==, "<Control><Shift>s");
  g_assert_null (sort->accel2);
  g_assert_cmpint (sort->group, ==, LSG_A11Y_GROUP_SORTING);
  /* GRID scope: never registered as a global app accel, so a focused GtkText
   * keeps its own Ctrl+Shift+S. */
  g_assert_cmpint (sort->scope, ==, LSG_A11Y_SCOPE_GRID);
  g_assert_null (sort->action_name);
  g_assert_nonnull (sort->title);
  g_assert_cmpuint (strlen (sort->title), >, 0);
}

/* ========================================================================= */
/* SORT BRIDGE (over the real core, find.csv fixture) */
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

/* Poll until the key pass has landed (ACTIVE), bounded (~10 s). */
static gboolean
wait_sort_active (LsgDocument *doc, LsgSortSnapshot *out)
{
  for (int i = 0; i < 5000; i++)
    {
      LsgSortSnapshot s;
      if (lsg_document_sort_poll (doc, &s) && s.phase == LSG_SORT_PHASE_ACTIVE)
        {
          if (out)
            *out = s;
          return TRUE;
        }
      g_usleep (2000);
    }
  return FALSE;
}

/* The ORIGINAL (gutter) row numbers of the first `n` view rows, in view order
 * (via the frozen slice-1 window + source-row accessors). Caller frees. */
static GArray *
view_source_rows (LsgDocument *doc, guint32 n)
{
  GArray *rows = g_array_new (FALSE, FALSE, sizeof (guint64));
  LsgWindow *w = lsg_document_set_window (doc, 0, n, 0, 3);
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

/* --- a fresh document reports NO sort (session-only; nothing persisted) ---
 */

static void
test_bridge_fresh_none (void)
{
  LsgDocument *doc = open_find_fixture ();
  LsgSortSnapshot s;
  g_assert_false (lsg_document_sort_poll (doc, &s));
  g_assert_cmpint (s.phase, ==, LSG_SORT_PHASE_NONE);
  g_assert_cmpint (s.error, ==, LSG_SORT_ERROR_NONE);
  g_assert_cmpuint (s.column, ==, 0);
  g_assert_cmpfloat (s.progress, ==, 0.0);
  lsg_document_close (doc);
}

/* --- set a sort: the view re-orders and the gutter keeps ORIGINAL numbers ---
 */

static void
test_bridge_sorts_and_remaps (void)
{
  LsgDocument *doc = open_find_fixture ();
  g_assert_true (lsg_document_sort_set (doc, 0, LSG_SORT_ASCENDING));
  LsgSortSnapshot s;
  g_assert_true (wait_sort_active (doc, &s));
  g_assert_cmpuint (s.column, ==, 0);
  g_assert_cmpint (s.direction, ==, LSG_SORT_ASCENDING);
  g_assert_cmpfloat (s.progress, ==, 1.0);

  GArray *src = view_source_rows (doc, 8);
  assert_rows (src, name_ascending, 8);
  g_array_free (src, TRUE);

  /* The cells really are in that order, and the row set is unchanged. */
  LsgWindow *w = lsg_document_set_window (doc, 0, 8, 0, 3);
  g_assert_cmpstr (lsg_window_cell (w, 0, 0), ==, "");
  g_assert_cmpstr (lsg_window_cell (w, 1, 0), ==, "café");
  g_assert_cmpstr (lsg_window_cell (w, 4, 0), ==, "NEEDLE");
  g_assert_cmpstr (lsg_window_cell (w, 5, 0), ==, "needle");
  g_assert_cmpstr (lsg_window_cell (w, 7, 0), ==, "Widget");
  lsg_window_free (w);
  g_assert_cmpuint (lsg_document_row_count (doc).count, ==, 8);

  lsg_document_close (doc);
}

/* --- descending is the ascending permutation read backwards --- */

static void
test_bridge_descending_is_reversed (void)
{
  LsgDocument *doc = open_find_fixture ();
  g_assert_true (lsg_document_sort_set (doc, 0, LSG_SORT_ASCENDING));
  g_assert_true (wait_sort_active (doc, NULL));
  g_assert_true (lsg_document_sort_set (doc, 0, LSG_SORT_DESCENDING));
  /* The flip is instant: ACTIVE on the very next poll, no BUILDING in between.
   */
  LsgSortSnapshot s;
  g_assert_true (lsg_document_sort_poll (doc, &s));
  g_assert_cmpint (s.phase, ==, LSG_SORT_PHASE_ACTIVE);
  g_assert_cmpint (s.direction, ==, LSG_SORT_DESCENDING);

  GArray *src = view_source_rows (doc, 8);
  assert_rows (src, name_descending, 8);
  g_array_free (src, TRUE);
  lsg_document_close (doc);
}

/* --- a sort composes OVER an active filter: the sorted set IS the filtered
 *     set, and the key pass drives the filter's counts to completion --- */

static void
test_bridge_composes_with_filter (void)
{
  LsgDocument *doc = open_find_fixture ();
  /* qty (col 1) <= 2 numerically -> original rows 0,2,3,5 (m = 4). */
  g_assert_true (lsg_document_filter_set (
      doc, (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE,
                               .column = 1,
                               .op = LSG_SEARCH_OP_LE,
                               .value = "2" }));
  g_assert_true (lsg_document_sort_set (doc, 0, LSG_SORT_ASCENDING));
  g_assert_true (wait_sort_active (doc, NULL));

  /* Those four rows in name order: café(5) < gadget(3) < needle(2) <
   * Widget(0). */
  g_assert_cmpuint (lsg_document_row_count (doc).count, ==, 4);
  GArray *src = view_source_rows (doc, 4);
  assert_rows (src, (const guint64[]){ 5, 3, 2, 0 }, 4);
  g_array_free (src, TRUE);

  LsgFilterSnapshot fs;
  g_assert_true (lsg_document_filter_poll (doc, &fs));
  g_assert_true (fs.total_exact);
  lsg_document_close (doc);
}

/* --- the view speaks SORTED coordinates without waiting for the key pass
 *     (Amendment 1: latency beats throughput). The window is read on the very
 *     next statement after the set — no poll, no wait for ACTIVE — and must
 *     already be sorted. An implementation that holds the previous order until
 *     the pass completes fails HERE, which is the point of the amendment. ---
 */

static void
test_bridge_serves_sorted_immediately (void)
{
  LsgDocument *doc = open_find_fixture ();
  g_assert_true (lsg_document_sort_set (doc, 0, LSG_SORT_ASCENDING));

  /* find.csv's 8 rows are scanned in one block, so the prefix here is already
   * the whole order; on a large document it would be the sorted top of the
   * scanned region instead. Either way it is never the pre-sort order. */
  GArray *src = view_source_rows (doc, 8);
  g_assert_cmpuint (src->len, >, 0);
  g_assert_cmpuint (g_array_index (src, guint64, 0), ==, name_ascending[0]);
  g_array_free (src, TRUE);

  /* The poll is honest about which phase that was. */
  LsgSortSnapshot s;
  g_assert_true (lsg_document_sort_poll (doc, &s));
  g_assert_cmpuint (s.column, ==, 0);
  g_assert_cmpint (s.direction, ==, LSG_SORT_ASCENDING);
  g_assert_true (s.phase == LSG_SORT_PHASE_BUILDING
                 || s.phase == LSG_SORT_PHASE_ACTIVE);
  lsg_document_close (doc);
}

/* --- clearing restores the PRE-SORT file order (and is also the cancel verb:
 *     a cancelled build's converging prefix is gone, not frozen on screen)
 *     --- */

static void
test_bridge_clear_restores_file_order (void)
{
  LsgDocument *doc = open_find_fixture ();
  g_assert_true (lsg_document_sort_set (doc, 0, LSG_SORT_ASCENDING));
  g_assert_true (wait_sort_active (doc, NULL));
  lsg_document_sort_clear (doc);

  LsgSortSnapshot s;
  g_assert_false (lsg_document_sort_poll (doc, &s));
  g_assert_cmpint (s.phase, ==, LSG_SORT_PHASE_NONE);
  GArray *src = view_source_rows (doc, 8);
  assert_rows (src, (const guint64[]){ 0, 1, 2, 3, 4, 5, 6, 7 }, 8);
  g_array_free (src, TRUE);
  lsg_document_close (doc);
}

/* --- an out-of-range column is rejected and changes NOTHING --- */

static void
test_bridge_reject_unchanged (void)
{
  LsgDocument *doc = open_find_fixture ();
  g_assert_false (
      lsg_document_sort_set (doc, 3, LSG_SORT_ASCENDING)); /* 3 columns */
  g_assert_false (lsg_document_sort_set (doc, 99, LSG_SORT_DESCENDING));
  LsgSortSnapshot s;
  g_assert_false (lsg_document_sort_poll (doc, &s));
  GArray *src = view_source_rows (doc, 8);
  assert_rows (src, (const guint64[]){ 0, 1, 2, 3, 4, 5, 6, 7 }, 8);
  g_array_free (src, TRUE);
  /* ... and a VALID column IS accepted (the half a permanently-rejecting
   * implementation would otherwise pass vacuously). */
  g_assert_true (lsg_document_sort_set (doc, 2, LSG_SORT_ASCENDING));
  lsg_document_close (doc);
}

/* --- sort state is SESSION-ONLY: a re-opened document has none --- */

static void
test_bridge_session_only (void)
{
  LsgDocument *doc = open_find_fixture ();
  g_assert_true (lsg_document_sort_set (doc, 0, LSG_SORT_DESCENDING));
  g_assert_true (wait_sort_active (doc, NULL));
  lsg_document_close (doc);

  LsgDocument *again = open_find_fixture ();
  LsgSortSnapshot s;
  g_assert_false (lsg_document_sort_poll (again, &s));
  GArray *src = view_source_rows (again, 8);
  assert_rows (src, (const guint64[]){ 0, 1, 2, 3, 4, 5, 6, 7 }, 8);
  g_array_free (src, TRUE);
  lsg_document_close (again);
}

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);

  /* Pure view-model. */
  g_test_add_func ("/sort/abi-sort-pins", test_abi_sort_pins);
  g_test_add_func ("/sort/cycle-starts-fresh", test_cycle_starts_fresh);
  g_test_add_func ("/sort/cycle-advances",
                   test_cycle_advances_on_the_sorted_column);
  g_test_add_func ("/sort/cycle-unlanded-stops",
                   test_cycle_on_unlanded_pass_stops);
  g_test_add_func ("/sort/cycle-failed-retries",
                   test_cycle_on_failed_pass_retries);
  g_test_add_func ("/sort/indicator-states", test_indicator_states);
  g_test_add_func ("/sort/describe", test_describe);

  /* The one accelerator table. */
  g_test_add_func ("/sort/shortcut-declared-once",
                   test_shortcut_is_declared_once);

  /* Sort bridge over the real core. */
  g_test_add_func ("/sort/bridge-fresh-none", test_bridge_fresh_none);
  g_test_add_func ("/sort/bridge-sorts-and-remaps",
                   test_bridge_sorts_and_remaps);
  g_test_add_func ("/sort/bridge-serves-immediately",
                   test_bridge_serves_sorted_immediately);
  g_test_add_func ("/sort/bridge-descending",
                   test_bridge_descending_is_reversed);
  g_test_add_func ("/sort/bridge-composes-with-filter",
                   test_bridge_composes_with_filter);
  g_test_add_func ("/sort/bridge-clear",
                   test_bridge_clear_restores_file_order);
  g_test_add_func ("/sort/bridge-reject-unchanged",
                   test_bridge_reject_unchanged);
  g_test_add_func ("/sort/bridge-session-only", test_bridge_session_only);

  return g_test_run ();
}
