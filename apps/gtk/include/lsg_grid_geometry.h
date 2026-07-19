/*
 * lsg_grid_geometry.h — the GTK frontend's display-free GRID GEOMETRY / WINDOW
 * MATH (slice 1). The custom O(viewport) grid is a `GtkDrawingArea` driven by
 * a hand-managed `GtkAdjustment` + `GtkScrollbar` (uniform row height => O(1)
 * geometry). NSTableView owned this math on macOS; here it is explicit, pure,
 * and unit-pinned so the risky grid is verifiable headlessly. The horizontal
 * half mirrors the macOS `ColumnLayouting` (window + monotone width merge).
 *
 * Everything here is ARITHMETIC over plain numbers (pixels as `gdouble`, rows
 * as `guint64`, widths supplied by the frontend's own monospaced measurement)
 * — no widgets, no display server, no text layout. It answers three grid
 * questions:
 *   1. which ROWS a paint must materialize (viewport + overscan, bounded);
 *   2. how the row-count ESTIMATE maps to/from the scrollbar — including the
 *      FILLER mapping when a huge estimate would overflow a sane adjustment
 *      range, plus when to defer applying an estimate change;
 *   3. which COLUMNS a paint must touch (column windowing) and how established
 *      widths grow.
 */
#ifndef LSG_GRID_GEOMETRY_H
#define LSG_GRID_GEOMETRY_H

#include <glib.h>

G_BEGIN_DECLS

/* ------------------------------------------------------------------------- */
/* Vertical: the row window a paint must materialize */
/* ------------------------------------------------------------------------- */

/* A half-open data-row span [first_row, first_row + row_count). */
typedef struct
{
  guint64 first_row;
  guint32 row_count;
} LsgRowSpan;

/*
 * The rows a paint must materialize for a viewport of height `viewport_h`
 * (pixels) whose top is at `scroll_y` (pixels), with uniform `row_h` (pixels):
 * the visible rows (`floor(scroll_y / row_h)` .. covering `scroll_y +
 * viewport_h`) PLUS `overscan` rows on EACH side (the scroll buffer), then
 * clamped to `[0, row_estimate)` and the count clamped to LS_WINDOW_MAX_ROWS.
 * Returns an empty span (row_count 0) when `row_h <= 0`, `viewport_h <= 0`, or
 * `row_estimate == 0`. Independent of file size — the count is bounded by the
 * viewport, not the document.
 */
LsgRowSpan lsg_grid_row_window (gdouble scroll_y, gdouble viewport_h,
                                gdouble row_h, guint overscan,
                                guint64 row_estimate);

/* ------------------------------------------------------------------------- */
/* Vertical: estimate <-> scrollbar mapping (filler-row math) */
/* ------------------------------------------------------------------------- */

/*
 * The maximum `GtkAdjustment` upper the vertical scrollbar uses. A document
 * whose content height (`row_estimate * row_h`) fits within this maps rows to
 * pixels DIRECTLY (offset == row * row_h); a larger estimate SATURATES the
 * upper here and switches to the PROPORTIONAL (filler) mapping below, so a
 * millions/billions-row estimate keeps the adjustment in a precise `gdouble`
 * range instead of overflowing it.
 */
#define LSG_GRID_MAX_ADJUSTMENT_UPPER (1.0e9)

/* The scrollbar's content height (adjustment upper): `row_estimate * row_h`
 * when that is <= LSG_GRID_MAX_ADJUSTMENT_UPPER, else the saturated cap.
 * Always
 * >= 0; 0 for an empty document. */
gdouble lsg_grid_content_height (guint64 row_estimate, gdouble row_h);

/*
 * The top data row for a scrollbar `offset` in [0, upper], where `upper` is
 * the `lsg_grid_content_height` for (row_estimate, row_h). DIRECT mapping
 * (`floor(offset / row_h)`) while unsaturated; PROPORTIONAL filler mapping
 * (`floor(offset / upper * row_estimate)`) once saturated, so dragging the
 * scrollbar over a huge estimate lands a sensible row. Clamped to
 * `[0, row_estimate - 1]` (0 for an empty document).
 */
guint64 lsg_grid_top_row_for_offset (gdouble offset, gdouble upper,
                                     guint64 row_estimate, gdouble row_h);

/*
 * The inverse: the scrollbar `offset` that lands `row` at the viewport top,
 * for the same `upper` / `row_estimate` / `row_h`. DIRECT (`row * row_h`)
 * while unsaturated; PROPORTIONAL (`row / row_estimate * upper`) once
 * saturated. Clamped to [0, upper].
 */
gdouble lsg_grid_offset_for_top_row (guint64 row, gdouble upper,
                                     guint64 row_estimate, gdouble row_h);

/*
 * Whether a row-count ESTIMATE change should be applied to the adjustment
 * upper NOW, or DEFERRED. Returns FALSE when `new_estimate == old_estimate`
 * (nothing to do) or when `is_overscrolling` (applying mid kinetic/elastic
 * overscroll would perturb the live scroll — defer until it settles, mirroring
 * the macOS deferred-estimate-reload rule); TRUE otherwise.
 */
gboolean lsg_grid_should_apply_estimate (guint64 old_estimate,
                                         guint64 new_estimate,
                                         gboolean is_overscrolling);

/* ------------------------------------------------------------------------- */
/* Horizontal: the column window a paint must touch (mirrors ColumnLayouting)
 */
/* ------------------------------------------------------------------------- */

/* One materialized column window: the contiguous run of columns a paint must
 * fetch/draw, plus the exact x-offset of its first column. */
typedef struct
{
  guint first;     /* first in-window column (0 when count == 0) */
  guint count;     /* number of columns; 0 when none intersect / no columns */
  gdouble first_x; /* x-offset of column `first` == sum(widths[0..first)) */
} LsgColumnWindow;

/*
 * The columns whose x-extent intersects [viewport_x, viewport_x + viewport_w)
 * PLUS `overscan` columns on each side, clamped to [0, n). `widths` is the
 * `n` per-column pixel widths (a negative width contributes 0). Covers the
 * viewport exactly (no visible column missed); `first_x` is the exact prefix
 * sum at `first` so in-window columns draw at the same x as a naive
 * full-prefix draw. A viewport spanning every column yields the whole range at
 * first_x 0 (identical to a non-windowed draw). Empty `widths` (n == 0) or a
 * viewport intersecting no column yields {0, 0, 0}. The work is O(the answer's
 * position), never a forced full pass — the O(viewport)-not-O(total) guarantee
 * for wide documents.
 */
LsgColumnWindow lsg_grid_column_window (const gdouble *widths, guint n,
                                        gdouble viewport_x, gdouble viewport_w,
                                        guint overscan);

/*
 * Monotone, per-column width max-merge: writes to `out` (length `n`) a copy of
 * `current` (length `n`) with, for each of the `m` (column, candidate) pairs
 * in `cols`/`candidates`, `out[col] = MAX(current[col], candidate)` — every
 * other column byte-identical to `current`. NEVER lowers a width (monotone)
 * and NEVER lets one column affect another (independence), so a horizontal
 * scroll that re-measures a column over the same vertical row window can never
 * churn its established width. Pairs whose column index is >= n are ignored.
 * `out` may not alias `current`.
 */
void lsg_grid_grow_widths (const gdouble *current, guint n, const guint *cols,
                           const gdouble *candidates, guint m, gdouble *out);

/*
 * The column-width heuristic (ARCH: "monospaced advance x max UTF-8 length, no
 * per-cell text layout at cold open"). Returns `advance` (the monospaced
 * per-character pixel advance the frontend measured for the data font) times
 * the MAXIMUM UTF-8 CHARACTER count (`g_utf8_strlen`) over the `n_cells`
 * sampled cell strings and `header` (NULL / "" ignored), plus `padding`. Pure
 * arithmetic over the head sample; no glyph layout. `cells` entries are
 * NUL-terminated UTF-8; a NULL entry counts as 0 characters. Returns `padding`
 * when there is no text at all.
 */
gdouble lsg_grid_column_width_estimate (const char *const *cells,
                                        guint n_cells, const char *header,
                                        gdouble advance, gdouble padding);

G_END_DECLS

#endif /* LSG_GRID_GEOMETRY_H */
