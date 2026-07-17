/*
 * lsg_grid_geometry.c — RED SEED for the grid geometry / window math
 * (lsg_grid_geometry.h). Compiles clean under -Werror (conformance GREEN) but
 * returns empty/zero geometry (behavior RED): tests/test_grid_geometry.c fails
 * here and turns GREEN as the viewport row window, the estimate<->scrollbar
 * (filler) mapping, the column window + width merge, and the width heuristic
 * are implemented.
 */
#include <lsg_grid_geometry.h>
#include <string.h>

LsgRowSpan
lsg_grid_row_window (gdouble scroll_y, gdouble viewport_h, gdouble row_h,
                     guint overscan, guint64 row_estimate)
{
  (void) scroll_y;
  (void) viewport_h;
  (void) row_h;
  (void) overscan;
  (void) row_estimate;
  LsgRowSpan s = { 0, 0 };
  return s; /* SEED */
}

gdouble
lsg_grid_content_height (guint64 row_estimate, gdouble row_h)
{
  (void) row_estimate;
  (void) row_h;
  return 0.0; /* SEED */
}

guint64
lsg_grid_top_row_for_offset (gdouble offset, gdouble upper, guint64 row_estimate, gdouble row_h)
{
  (void) offset;
  (void) upper;
  (void) row_estimate;
  (void) row_h;
  return 0; /* SEED */
}

gdouble
lsg_grid_offset_for_top_row (guint64 row, gdouble upper, guint64 row_estimate, gdouble row_h)
{
  (void) row;
  (void) upper;
  (void) row_estimate;
  (void) row_h;
  return 0.0; /* SEED */
}

gboolean
lsg_grid_should_apply_estimate (guint64 old_estimate, guint64 new_estimate, gboolean is_overscrolling)
{
  (void) old_estimate;
  (void) new_estimate;
  (void) is_overscrolling;
  return FALSE; /* SEED */
}

LsgColumnWindow
lsg_grid_column_window (const gdouble *widths, guint n, gdouble viewport_x,
                        gdouble viewport_w, guint overscan)
{
  (void) widths;
  (void) n;
  (void) viewport_x;
  (void) viewport_w;
  (void) overscan;
  LsgColumnWindow w = { 0, 0, 0.0 };
  return w; /* SEED */
}

void
lsg_grid_grow_widths (const gdouble *current, guint n,
                      const guint *cols, const gdouble *candidates, guint m,
                      gdouble *out)
{
  (void) cols;
  (void) candidates;
  (void) m;
  /* SEED: copy through with NO merge (so a genuine growth is not applied). */
  if (out != NULL && current != NULL && n > 0)
    memcpy (out, current, (gsize) n * sizeof (gdouble));
}

gdouble
lsg_grid_column_width_estimate (const char *const *cells, guint n_cells,
                                const char *header, gdouble advance, gdouble padding)
{
  (void) cells;
  (void) n_cells;
  (void) header;
  (void) advance;
  (void) padding;
  return 0.0; /* SEED */
}
