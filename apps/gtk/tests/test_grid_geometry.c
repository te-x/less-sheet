/*
 * test_grid_geometry.c — RED behavior tests for the display-free grid geometry
 * / window math (lsg_grid_geometry.h). Display-free (glib only). Maps the
 * slice-1 grid criteria: the viewport ROW window (viewport + overscan, bounded
 * by LS_WINDOW_MAX_ROWS), the estimate<->scrollbar mapping including the FILLER
 * (proportional) mapping at large estimates + the deferred-reload decision, the
 * COLUMN window selection + monotone width merge, and the column-width
 * heuristic.
 */
#include <glib.h>
#include <lesssheet.h>
#include <lsg_grid_geometry.h>

/* --- vertical: the row window a paint must materialize --- */

static void
test_row_window (void)
{
  /* Cold open at the very top: 10 visible rows + 2 overscan below (top clamped). */
  LsgRowSpan a = lsg_grid_row_window (0.0, 220.0, 22.0, 2, 1000);
  g_assert_cmpuint (a.first_row, ==, 0);
  g_assert_cmpuint (a.row_count, ==, 12);

  /* Scrolled to row 100: overscan on both sides. */
  LsgRowSpan b = lsg_grid_row_window (2200.0, 220.0, 22.0, 2, 1000);
  g_assert_cmpuint (b.first_row, ==, 98);
  g_assert_cmpuint (b.row_count, ==, 14);

  /* Near the end: the bottom edge clamps to the estimate. */
  LsgRowSpan c = lsg_grid_row_window (21780.0, 220.0, 22.0, 5, 1000);
  g_assert_cmpuint (c.first_row, ==, 985);
  g_assert_cmpuint (c.row_count, ==, 15);

  /* Degenerate inputs => empty span. */
  g_assert_cmpuint (lsg_grid_row_window (0.0, 220.0, 0.0, 2, 1000).row_count, ==, 0);
  g_assert_cmpuint (lsg_grid_row_window (0.0, 0.0, 22.0, 2, 1000).row_count, ==, 0);
  g_assert_cmpuint (lsg_grid_row_window (0.0, 220.0, 22.0, 2, 0).row_count, ==, 0);

  /* The count is bounded by LS_WINDOW_MAX_ROWS even for an enormous viewport. */
  LsgRowSpan big = lsg_grid_row_window (0.0, 100000.0, 1.0, 0, 1000000000ULL);
  g_assert_cmpuint (big.row_count, ==, LS_WINDOW_MAX_ROWS);
}

/* --- vertical: estimate <-> scrollbar mapping (filler math) --- */

static void
test_content_height (void)
{
  /* Small document: direct pixel height. */
  g_assert_cmpfloat (lsg_grid_content_height (1000, 22.0), ==, 22000.0);
  /* Empty document: zero. */
  g_assert_cmpfloat (lsg_grid_content_height (0, 22.0), ==, 0.0);
  /* Huge estimate saturates the adjustment upper. */
  g_assert_cmpfloat (lsg_grid_content_height (1000000000000000000ULL, 22.0),
                     ==, LSG_GRID_MAX_ADJUSTMENT_UPPER);
}

static void
test_scroll_mapping_direct (void)
{
  /* Unsaturated (upper == estimate*row_h): exact row<->offset. */
  const gdouble upper = 22000.0; /* 1000 rows * 22 px */
  g_assert_cmpuint (lsg_grid_top_row_for_offset (2200.0, upper, 1000, 22.0), ==, 100);
  g_assert_cmpfloat (lsg_grid_offset_for_top_row (100, upper, 1000, 22.0), ==, 2200.0);
}

static void
test_scroll_mapping_filler (void)
{
  /* Saturated (upper == cap): proportional filler mapping. estimate 1e8, so a
   * half-way scrollbar lands the middle row. */
  const gdouble upper = LSG_GRID_MAX_ADJUSTMENT_UPPER; /* 1e9 */
  const guint64 estimate = 100000000ULL;               /* 1e8 */
  g_assert_cmpuint (lsg_grid_top_row_for_offset (0.0, upper, estimate, 22.0), ==, 0);
  g_assert_cmpuint (lsg_grid_top_row_for_offset (upper / 2.0, upper, estimate, 22.0), ==, 50000000ULL);
  /* At/over the end, clamp to the last row. */
  g_assert_cmpuint (lsg_grid_top_row_for_offset (upper, upper, estimate, 22.0), ==, estimate - 1);
  /* Inverse round-trips the mid row. */
  g_assert_cmpfloat (lsg_grid_offset_for_top_row (50000000ULL, upper, estimate, 22.0), ==, upper / 2.0);
}

static void
test_should_apply_estimate (void)
{
  g_assert_true (lsg_grid_should_apply_estimate (100, 200, FALSE));
  g_assert_false (lsg_grid_should_apply_estimate (100, 200, TRUE));  /* defer mid-overscroll */
  g_assert_false (lsg_grid_should_apply_estimate (100, 100, FALSE)); /* no change */
}

/* --- horizontal: the column window a paint must touch --- */

static void
test_column_window (void)
{
  const gdouble widths[5] = { 100, 100, 100, 100, 100 };

  /* Cold open, first 250 px: columns 0,1,2 at x-offset 0. */
  LsgColumnWindow a = lsg_grid_column_window (widths, 5, 0.0, 250.0, 0);
  g_assert_cmpuint (a.first, ==, 0);
  g_assert_cmpuint (a.count, ==, 3);
  g_assert_cmpfloat (a.first_x, ==, 0.0);

  /* Scrolled to x=250, 100 px wide: columns 2,3 at x-offset 200. */
  LsgColumnWindow b = lsg_grid_column_window (widths, 5, 250.0, 100.0, 0);
  g_assert_cmpuint (b.first, ==, 2);
  g_assert_cmpuint (b.count, ==, 2);
  g_assert_cmpfloat (b.first_x, ==, 200.0);

  /* Same viewport, one column of overscan each side. */
  LsgColumnWindow c = lsg_grid_column_window (widths, 5, 250.0, 100.0, 1);
  g_assert_cmpuint (c.first, ==, 1);
  g_assert_cmpuint (c.count, ==, 4);
  g_assert_cmpfloat (c.first_x, ==, 100.0);

  /* Everything fits: the whole range at x 0 (identical to a non-windowed draw). */
  LsgColumnWindow all = lsg_grid_column_window (widths, 5, 0.0, 1000.0, 0);
  g_assert_cmpuint (all.first, ==, 0);
  g_assert_cmpuint (all.count, ==, 5);

  /* No columns / a viewport past the end => empty window. */
  g_assert_cmpuint (lsg_grid_column_window (NULL, 0, 0.0, 100.0, 0).count, ==, 0);
  g_assert_cmpuint (lsg_grid_column_window (widths, 5, 600.0, 100.0, 0).count, ==, 0);
}

static void
test_grow_widths (void)
{
  const gdouble current[3] = { 10, 20, 30 };
  const guint cols[2] = { 0, 2 };
  const gdouble cand[2] = { 5, 40 }; /* col0 shrinks (ignored), col2 grows */
  gdouble out[3] = { 0, 0, 0 };

  lsg_grid_grow_widths (current, 3, cols, cand, 2, out);
  g_assert_cmpfloat (out[0], ==, 10.0); /* monotone: never lowered */
  g_assert_cmpfloat (out[1], ==, 20.0); /* untouched */
  g_assert_cmpfloat (out[2], ==, 40.0); /* raised */

  /* A candidate for a column index >= n is ignored. */
  const guint bad_cols[1] = { 5 };
  const gdouble bad_cand[1] = { 99 };
  gdouble out2[3] = { 0, 0, 0 };
  lsg_grid_grow_widths (current, 3, bad_cols, bad_cand, 1, out2);
  g_assert_cmpfloat (out2[0], ==, 10.0);
  g_assert_cmpfloat (out2[1], ==, 20.0);
  g_assert_cmpfloat (out2[2], ==, 30.0);
}

static void
test_column_width_estimate (void)
{
  /* max(chars over cells + header) * advance + padding: max("Alice"=5,"Bob"=3,
   * header "name"=4) = 5 => 5*8 + 6 = 46. */
  const char *cells[2] = { "Alice", "Bob" };
  g_assert_cmpfloat (lsg_grid_column_width_estimate (cells, 2, "name", 8.0, 6.0), ==, 46.0);

  /* Character count (g_utf8_strlen), not byte count: "é" is 1 char / 2 bytes. */
  const char *accented[1] = { "\xC3\xA9" };
  g_assert_cmpfloat (lsg_grid_column_width_estimate (accented, 1, NULL, 10.0, 0.0), ==, 10.0);

  /* No text at all => just the padding. */
  g_assert_cmpfloat (lsg_grid_column_width_estimate (NULL, 0, NULL, 8.0, 6.0), ==, 6.0);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/grid/row-window", test_row_window);
  g_test_add_func ("/grid/content-height", test_content_height);
  g_test_add_func ("/grid/scroll-mapping-direct", test_scroll_mapping_direct);
  g_test_add_func ("/grid/scroll-mapping-filler", test_scroll_mapping_filler);
  g_test_add_func ("/grid/should-apply-estimate", test_should_apply_estimate);
  g_test_add_func ("/grid/column-window", test_column_window);
  g_test_add_func ("/grid/grow-widths", test_grow_widths);
  g_test_add_func ("/grid/column-width-estimate", test_column_width_estimate);
  return g_test_run ();
}
