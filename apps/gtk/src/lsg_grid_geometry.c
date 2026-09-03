/*
 * lsg_grid_geometry.c — the grid's window math. Pure arithmetic over plain
 * numbers. Uniform row height => O(1) vertical geometry; the column half walks
 * only as far as the answer's last column, never a forced full pass.
 *
 * Deliberately uses NO <math.h>: the build links glib but not libm, and every
 * value here is non-negative, so a cast-to-integer IS floor and the ceil cases
 * are handled by a multiply-back boundary check.
 */
#include <lesssheet.h> /* LS_WINDOW_MAX_ROWS (the row-window clamp) */
#include <lsg_grid_geometry.h>
#include <string.h>

/* ------------------------------------------------------------------------- */
/* Vertical: the row window a paint must materialize */
/* ------------------------------------------------------------------------- */

LsgRowSpan
lsg_grid_row_window (gdouble scroll_y, gdouble viewport_h, gdouble row_h,
                     guint overscan, guint64 row_estimate)
{
  LsgRowSpan span = { 0, 0 };

  if (row_h <= 0.0 || viewport_h <= 0.0 || row_estimate == 0)
    return span;
  if (scroll_y < 0.0)
    scroll_y = 0.0;

  /* First visible row: floor(scroll_y / row_h) (non-negative -> cast ==
   * floor). */
  guint64 first_visible = (guint64)(scroll_y / row_h);

  /* Last visible row: the largest i whose pixel span [i*row_h, (i+1)*row_h)
   * still begins before the viewport bottom. A row starting exactly at the
   * bottom edge (exclusive) is NOT visible, so decrement on an exact landing.
   */
  gdouble bottom = scroll_y + viewport_h;
  guint64 last_visible = (guint64)(bottom / row_h);
  if (last_visible > 0 && (gdouble)last_visible * row_h >= bottom)
    last_visible -= 1;

  /* Overscan (the scroll buffer) on each side, then clamp to [0, estimate). */
  guint64 first = (first_visible > overscan) ? first_visible - overscan : 0;
  guint64 last = last_visible + overscan;
  if (first > row_estimate - 1)
    first = row_estimate - 1;
  if (last > row_estimate - 1)
    last = row_estimate - 1;
  if (last < first)
    last = first;

  guint64 count = last - first + 1;
  if (count > LS_WINDOW_MAX_ROWS)
    count = LS_WINDOW_MAX_ROWS;

  span.first_row = first;
  span.row_count = (guint32)count;
  return span;
}

/* ------------------------------------------------------------------------- */
/* Vertical: estimate <-> scrollbar mapping (filler-row math) */
/* ------------------------------------------------------------------------- */

gdouble
lsg_grid_content_height (guint64 row_estimate, gdouble row_h)
{
  if (row_estimate == 0 || row_h <= 0.0)
    return 0.0;
  gdouble h = (gdouble)row_estimate * row_h;
  return (h <= LSG_GRID_MAX_ADJUSTMENT_UPPER) ? h
                                              : LSG_GRID_MAX_ADJUSTMENT_UPPER;
}

/* The content height would overflow the sane adjustment range -> the scrollbar
 * runs in PROPORTIONAL (filler) mode rather than direct pixel mapping. */
static gboolean
is_saturated (guint64 row_estimate, gdouble row_h)
{
  return ((gdouble)row_estimate * row_h) > LSG_GRID_MAX_ADJUSTMENT_UPPER;
}

guint64
lsg_grid_top_row_for_offset (gdouble offset, gdouble upper,
                             guint64 row_estimate, gdouble row_h)
{
  if (row_estimate == 0)
    return 0;
  if (offset < 0.0)
    offset = 0.0;

  guint64 row;
  if (!is_saturated (row_estimate, row_h))
    {
      if (row_h <= 0.0)
        return 0;
      row = (guint64)(offset / row_h); /* direct: floor(offset/row_h) */
    }
  else
    {
      if (upper <= 0.0)
        return 0;
      row = (guint64)((offset / upper)
                      * (gdouble)row_estimate); /* proportional */
    }

  if (row > row_estimate - 1)
    row = row_estimate - 1;
  return row;
}

gdouble
lsg_grid_offset_for_top_row (guint64 row, gdouble upper, guint64 row_estimate,
                             gdouble row_h)
{
  if (row_estimate == 0)
    return 0.0;

  gdouble offset;
  if (!is_saturated (row_estimate, row_h))
    offset = (gdouble)row * row_h; /* direct */
  else
    offset = ((gdouble)row / (gdouble)row_estimate) * upper; /* proportional */

  if (offset < 0.0)
    offset = 0.0;
  if (offset > upper)
    offset = upper;
  return offset;
}

gboolean
lsg_grid_should_apply_estimate (guint64 old_estimate, guint64 new_estimate,
                                gboolean is_overscrolling)
{
  if (new_estimate == old_estimate)
    return FALSE; /* nothing to do */
  if (is_overscrolling)
    return FALSE; /* defer until the kinetic/elastic scroll settles */
  return TRUE;
}

/* ------------------------------------------------------------------------- */
/* Horizontal: the column window a paint must touch (mirrors ColumnLayouting)
 */
/* ------------------------------------------------------------------------- */

LsgColumnWindow
lsg_grid_column_window (const gdouble *widths, guint n, gdouble viewport_x,
                        gdouble viewport_w, guint overscan)
{
  LsgColumnWindow win = { 0, 0, 0.0 };
  if (widths == NULL || n == 0 || viewport_w <= 0.0)
    return win;

  gdouble vstart = viewport_x;
  gdouble vend = viewport_x + viewport_w;

  guint first_idx = 0, last_idx = 0;
  gboolean found = FALSE;
  gdouble x = 0.0;       /* running prefix sum of preceding widths */
  gdouble first_x = 0.0; /* x-offset of the first intersecting column */

  for (guint i = 0; i < n; i++)
    {
      gdouble w = (widths[i] > 0.0) ? widths[i] : 0.0;
      gdouble x_end = x + w;

      /* Column i intersects the viewport iff [x, x_end) overlaps [vstart,
       * vend). */
      if (x_end > vstart && x < vend)
        {
          if (!found)
            {
              first_idx = i;
              first_x = x;
              found = TRUE;
            }
          last_idx = i;
        }
      else if (found && x >= vend)
        {
          break; /* past the viewport; columns are left-to-right */
        }

      x = x_end;
    }

  if (!found)
    return win; /* no column intersects -> {0, 0, 0} */

  /* Overscan on each side, clamped to [0, n). */
  guint fi = (first_idx > overscan) ? first_idx - overscan : 0;
  guint li = last_idx + overscan;
  if (li > n - 1)
    li = n - 1;

  /* first_x of the overscanned first column: back out the widths in [fi,
   * first_idx). */
  gdouble fx = first_x;
  for (guint i = fi; i < first_idx; i++)
    fx -= (widths[i] > 0.0) ? widths[i] : 0.0;
  if (fx < 0.0)
    fx = 0.0;

  win.first = fi;
  win.count = li - fi + 1;
  win.first_x = fx;
  return win;
}

void
lsg_grid_grow_widths (const gdouble *current, guint n, const guint *cols,
                      const gdouble *candidates, guint m, gdouble *out)
{
  if (out == NULL || n == 0)
    return;
  if (current != NULL)
    memcpy (out, current, (gsize)n * sizeof (gdouble));

  if (cols == NULL || candidates == NULL)
    return;

  for (guint j = 0; j < m; j++)
    {
      guint col = cols[j];
      if (col >= n)
        continue; /* out-of-range pair ignored */
      if (candidates[j] > out[col])
        out[col] = candidates[j]; /* monotone: never lowered */
    }
}

gdouble
lsg_grid_column_width_estimate (const char *const *cells, guint n_cells,
                                const char *header, gdouble advance,
                                gdouble padding)
{
  glong max_chars = 0;

  for (guint i = 0; i < n_cells; i++)
    {
      if (cells != NULL && cells[i] != NULL)
        {
          glong len = g_utf8_strlen (cells[i], -1); /* CHARACTERS, not bytes */
          if (len > max_chars)
            max_chars = len;
        }
    }

  if (header != NULL && header[0] != '\0')
    {
      glong len = g_utf8_strlen (header, -1);
      if (len > max_chars)
        max_chars = len;
    }

  return advance * (gdouble)max_chars + padding;
}
