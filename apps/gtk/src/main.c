/*
 * less-sheet GTK frontend — the slice-1 viewer ("open + display + scroll").
 *
 * This is the GTK glue + drawing; ALL logic lives in the display-free lsg_*
 * modules (the C analogs of the macOS frontend): lsg_document (windowed session
 * over the Zig core), lsg_grid_geometry (the O(viewport) row/column/scrollbar
 * math), lsg_window_poll (the ~100 ms materialize/keep-polling decision),
 * lsg_net_open (the network-open drive), lsg_formatter (the lossless cell
 * formatter). main.c owns only the AdwApplicationWindow + AdwHeaderBar chrome,
 * the launch / error AdwStatusPages, the AdwBanner for network progress, and the
 * custom grid: a GtkDrawingArea painted with Cairo + Pango, driven by a
 * hand-managed GtkAdjustment + GtkScrollbar, materializing ONLY the visible
 * window (+ scroll buffer) via lsg_document_set_window — never O(file).
 *
 * The GNOME toolchain (GTK 4.16+/libadwaita 1.6+, decision 7) is required; this
 * binary is compiled by the gate but run by the author on a real GNOME desktop.
 */
#include <adwaita.h>
#include <pango/pangocairo.h>
#include <gdk/gdkkeysyms.h>

#include <lsg_document.h>
#include <lsg_net_open.h>
#include <lsg_grid_geometry.h>
#include <lsg_window_poll.h>
#include <lsg_formatter.h>
#include <lsg_find.h>

#include <string.h>

/* Row buffer beyond the viewport (the scroll buffer), each side. */
#define GRID_OVERSCAN 4
/* Poll cadence for the frontier / network drive. */
#define POLL_INTERVAL_MS 100
/* Bound the per-open width sample so a wide (100k-col) document stays O(head):
 * only these leading columns are measured; the rest take a default width. */
#define WIDTH_SAMPLE_COLS 256
#define WIDTH_SAMPLE_ROWS 64

typedef struct {
  AdwApplication *app;
  GtkWindow *window;
  AdwWindowTitle *title;
  AdwToolbarView *toolbar;
  AdwBanner *banner;
  GtkStack *stack;             /* "launch" / "grid" / "error" */
  AdwStatusPage *error_page;

  /* Grid widgets. */
  GtkDrawingArea *area;
  GtkAdjustment *vadj;
  GtkAdjustment *hadj;

  /* Open document + derived view state. */
  LsgDocument *doc;
  LsgWindow *win;              /* current materialized window (owned) */
  guint32 n_cols;
  gboolean has_header;
  double *col_widths;          /* n_cols pixel widths */
  double char_advance;         /* monospaced per-char pixel advance */
  double line_h;               /* text line height (pixels) */
  double row_h;                /* uniform row height (pixels) */
  double header_h;             /* header strip height (pixels) */
  double gutter_w;             /* row-number gutter width (pixels) */
  guint64 row_estimate;        /* current row-count estimate (>= 1 when non-empty) */
  gboolean window_short;       /* last materialize came back short */
  guint poll_id;               /* frontier poll source */

  /* Paint geometry cached by grid_materialize, consumed by grid_draw. */
  guint64 cur_top_row;
  double cur_pixel_off;
  LsgColumnWindow cur_colwin;
  LsgRowSpan cur_span;

  /* Header labels for the CURRENT column window only (lazy; O(visible columns),
   * never O(column_count) — mirrors the macOS per-column-window header fetch).
   * `hdr_labels[i]` is the label of absolute column `hdr_first + i`. */
  char **hdr_labels;
  guint hdr_first;
  guint hdr_count;

  PangoFontDescription *font_desc;

  /* Network open. */
  LsgNetOpen *net;
  guint net_poll_id;
  char *pending_url;

  /* Find (slice 2): the pure view-model session + the popover widgets + the
   * current window's highlight mask (owned; refreshed each materialize). */
  LsgFindSession find;
  LsgSearchDir find_nav_direction;   /* direction of the outstanding navigation */
  gboolean find_wrap_issued;         /* the wrap follow-up nav has been issued */
  LsgMatchFlags mask;                /* per-visible-cell match flags (OWNED) */
  GtkMenuButton *find_button;
  GtkPopover *find_popover;
  GtkEditable *find_entry;
  GtkLabel *find_status;
  LsgFindNotice find_sticky_notice;  /* a briefly-lingering wrap notice for the label */
  guint find_notice_id;              /* timeout clearing the sticky notice */

  /* Env-gated timing instrumentation (LESSSHEET_GTK_TIMING). Entirely inert —
   * no output, no measurable cost — unless `timing` is set. */
  gboolean timing;
  gint64 t_start;              /* main() entry (monotonic µs) */
  gboolean ui_shown_reported;  /* one-shot: window first mapped */
  gint64 t_open_begin;         /* file-open begin (monotonic µs) */
  gboolean first_frame_pending;/* one-shot: awaiting the first painted grid frame */
} App;

/* ------------------------------------------------------------------------- */
/* Small helpers                                                              */
/* ------------------------------------------------------------------------- */

static guint
digits_of (guint64 v)
{
  guint d = 1;
  while (v >= 10)
    {
      v /= 10;
      d++;
    }
  return d;
}

static gboolean
is_saturated (const App *app)
{
  return ((double) app->row_estimate * app->row_h) > LSG_GRID_MAX_ADJUSTMENT_UPPER;
}

static void
free_window_headers (App *app)
{
  if (app->hdr_labels != NULL)
    {
      for (guint i = 0; i < app->hdr_count; i++)
        g_free (app->hdr_labels[i]);
      g_clear_pointer (&app->hdr_labels, g_free);
    }
  app->hdr_first = 0;
  app->hdr_count = 0;
}

static void
find_clear_mask (App *app)
{
  g_clear_pointer (&app->mask.flags, g_free);
  app->mask.rows = 0;
  app->mask.cols = 0;
}

/* Poll the active search, fold it into the display, refresh the mask + labels,
 * and scroll to a new landing. Defined with the other find helpers below; the
 * poll loop (grid_poll_tick) calls it. */
static void find_poll_fold (App *app);

/* ------------------------------------------------------------------------- */
/* View teardown                                                              */
/* ------------------------------------------------------------------------- */

static void
app_reset_document (App *app)
{
  if (app->poll_id != 0)
    {
      g_source_remove (app->poll_id);
      app->poll_id = 0;
    }
  g_clear_pointer (&app->win, lsg_window_free);
  free_window_headers (app);
  g_clear_pointer (&app->col_widths, g_free);
  g_clear_pointer (&app->doc, lsg_document_close);
  app->n_cols = 0;
  app->row_estimate = 1;
  app->window_short = FALSE;

  /* The old document's search state died with its core handle: clear the find
   * display + highlights (the DRAFT is retained, so re-running is one Enter). */
  if (app->find_notice_id != 0)
    {
      g_source_remove (app->find_notice_id);
      app->find_notice_id = 0;
    }
  app->find = lsg_find_invalidated (app->find);
  app->find_sticky_notice = LSG_FIND_NOTICE_NONE;
  app->find_wrap_issued = FALSE;
  find_clear_mask (app);
}

/* ------------------------------------------------------------------------- */
/* Error / launch pages                                                       */
/* ------------------------------------------------------------------------- */

static void
show_error (App *app, const char *title, const char *description)
{
  adw_status_page_set_title (app->error_page, title);
  adw_status_page_set_description (app->error_page, description);
  gtk_stack_set_visible_child_name (app->stack, "error");
  adw_window_title_set_subtitle (app->title, "");
}

static const char *
open_error_text (LsgOpenError e)
{
  switch (e)
    {
    case LSG_OPEN_NOT_FOUND:          return "The file could not be found.";
    case LSG_OPEN_PERMISSION_DENIED:  return "Permission to read the file was denied.";
    case LSG_OPEN_IO:                 return "The file could not be read.";
    case LSG_OPEN_INVALID_ARGUMENT:   return "The parse options were invalid.";
    default:                          return "The file could not be opened.";
    }
}

/* ------------------------------------------------------------------------- */
/* Grid geometry glue                                                         */
/* ------------------------------------------------------------------------- */

static void
grid_update_gutter (App *app)
{
  guint d = digits_of (app->row_estimate);
  if (d < 4)
    d = 4;
  app->gutter_w = app->char_advance * (double) (d + 1) + 16.0;
}

static void
grid_update_vadjustment (App *app)
{
  double content_h = lsg_grid_content_height (app->row_estimate, app->row_h);
  int h = gtk_widget_get_height (GTK_WIDGET (app->area));
  double page = (double) h - app->header_h;
  if (page < app->row_h)
    page = app->row_h;
  if (content_h < page)
    content_h = page;
  gtk_adjustment_set_lower (app->vadj, 0.0);
  gtk_adjustment_set_upper (app->vadj, content_h);
  gtk_adjustment_set_page_size (app->vadj, page);
  gtk_adjustment_set_step_increment (app->vadj, app->row_h);
  gtk_adjustment_set_page_increment (app->vadj, page);
}

static void
grid_update_hadjustment (App *app)
{
  double total = 0.0;
  for (guint32 i = 0; i < app->n_cols; i++)
    total += (app->col_widths[i] > 0.0) ? app->col_widths[i] : 0.0;
  int w = gtk_widget_get_width (GTK_WIDGET (app->area));
  double page = (double) w - app->gutter_w;
  if (page < 0.0)
    page = 0.0;
  if (total < page)
    total = page;
  gtk_adjustment_set_lower (app->hadj, 0.0);
  gtk_adjustment_set_upper (app->hadj, total);
  gtk_adjustment_set_page_size (app->hadj, page);
  gtk_adjustment_set_step_increment (app->hadj, app->char_advance * 4.0);
  gtk_adjustment_set_page_increment (app->hadj, page);
}

/* Fetch header labels for the current column window only — O(visible columns),
 * never O(column_count). `first`/`count` are the materialized column window. */
static void
grid_window_headers (App *app, guint first, guint count)
{
  free_window_headers (app);
  if (!app->has_header || count == 0)
    return;
  app->hdr_labels = g_new0 (char *, count);
  for (guint i = 0; i < count; i++)
    app->hdr_labels[i] = lsg_document_header_cell_dup (app->doc, first + i);
  app->hdr_first = first;
  app->hdr_count = count;
}

/*
 * Auto-fit: monotonically GROW the visible columns' established widths from the
 * cells actually materialized this window (+ their header labels), via the
 * frozen monotone max-merge. O(visible cells), never O(rows)/O(column_count).
 * Only the columns IN the window are candidates, and the merge never lowers a
 * width, so an established column can never churn on scroll and the prefix sum
 * for columns before the window (hence `first_x`) is unaffected this frame.
 */
static void
grid_autofit_widths (App *app, LsgColumnWindow colwin, LsgWindow *win)
{
  guint32 gc = lsg_window_col_count (win);
  guint32 gr = lsg_window_row_count (win);
  if (gc == 0 || app->n_cols == 0)
    return;

  guint *cols = g_new (guint, gc);
  gdouble *cand = g_new (gdouble, gc);
  const char **buf = g_new (const char *, (gr > 0) ? gr : 1);
  double max_w = app->char_advance * 60.0 + 12.0;

  for (guint32 ci = 0; ci < gc; ci++)
    {
      guint cnt = 0;
      for (guint32 r = 0; r < gr; r++)
        buf[cnt++] = lsg_window_cell (win, r, ci);
      const char *hdr = (app->hdr_labels != NULL && ci < app->hdr_count)
                            ? app->hdr_labels[ci]
                            : NULL;
      double wpx = lsg_grid_column_width_estimate (buf, cnt, hdr, app->char_advance,
                                                   app->char_advance * 2.0 + 12.0);
      if (wpx > max_w)
        wpx = max_w;
      cand[ci] = wpx;
      cols[ci] = colwin.first + ci;
    }

  gdouble *out = g_new (gdouble, app->n_cols);
  lsg_grid_grow_widths (app->col_widths, app->n_cols, cols, cand, gc, out);
  gboolean changed =
      memcmp (out, app->col_widths, (gsize) app->n_cols * sizeof (gdouble)) != 0;
  g_free (app->col_widths);
  app->col_widths = out;

  g_free (cols);
  g_free (cand);
  g_free (buf);

  if (changed)
    grid_update_hadjustment (app);   /* only grows the upper; never re-materializes */
}

/* Choose the visible row/column window and materialize it (O(viewport)). */
static void
grid_materialize (App *app)
{
  if (app->doc == NULL)
    return;
  int w = gtk_widget_get_width (GTK_WIDGET (app->area));
  int h = gtk_widget_get_height (GTK_WIDGET (app->area));
  if (w <= 0 || h <= 0)
    return;

  double cell_area_w = (double) w - app->gutter_w;
  double cell_area_h = (double) h - app->header_h;
  if (cell_area_w < 0.0)
    cell_area_w = 0.0;
  if (cell_area_h < 0.0)
    cell_area_h = 0.0;

  double vval = gtk_adjustment_get_value (app->vadj);
  double vupper = gtk_adjustment_get_upper (app->vadj);
  guint64 top =
      lsg_grid_top_row_for_offset (vval, vupper, app->row_estimate, app->row_h);

  /* Sub-row pixel offset only makes sense in direct (unsaturated) mode; in the
   * filler regime one scrollbar pixel spans many rows, so snap to whole rows. */
  double pixel_off = is_saturated (app) ? 0.0 : (vval - (double) top * app->row_h);
  if (pixel_off < 0.0)
    pixel_off = 0.0;

  /* Feed the frozen row-window math a synthetic pixel offset for the mapped top
   * row, so the same function serves both the direct and filler regimes. */
  double scroll_y_synth = (double) top * app->row_h;
  LsgRowSpan span = lsg_grid_row_window (scroll_y_synth, cell_area_h, app->row_h,
                                         GRID_OVERSCAN, app->row_estimate);

  double hval = gtk_adjustment_get_value (app->hadj);
  LsgColumnWindow colwin =
      lsg_grid_column_window (app->col_widths, app->n_cols, hval, cell_area_w, 1);

  LsgWindow *nw = lsg_document_set_window (app->doc, span.first_row,
                                           span.row_count, colwin.first,
                                           colwin.count);
  g_clear_pointer (&app->win, lsg_window_free);
  app->win = nw;
  app->cur_top_row = top;
  app->cur_pixel_off = pixel_off;
  app->cur_colwin = colwin;
  app->cur_span = span;

  /* Lazily fetch this window's header labels, then auto-fit the visible columns
   * (both O(visible), using the actual materialized window). */
  grid_window_headers (app, colwin.first, colwin.count);
  grid_autofit_widths (app, colwin, nw);

  /* Refresh the per-visible-cell find highlight mask for THIS window (O(viewport)
   * — only the visible column range is evaluated by the core). Empty when no
   * search is active. Fetched right after set_window (window lane). */
  find_clear_mask (app);
  if (app->find.display.active)
    app->mask = lsg_document_window_match_flags (app->doc, colwin.first, colwin.count);

  /* Short => rows beyond the frontier are not yet servable; re-issue on poll. */
  app->window_short = (lsg_window_row_count (nw) < span.row_count);
}

static void
grid_update_title_counts (App *app, LsgRowCount rc, LsgScanProgress prog)
{
  char *sub;
  if (rc.exact)
    sub = g_strdup_printf ("%" G_GUINT64_FORMAT " rows", rc.count);
  else
    {
      double frac = lsg_scan_progress_fraction (prog);
      sub = g_strdup_printf ("~%" G_GUINT64_FORMAT " rows · indexing %d%%",
                             rc.count, (int) (frac * 100.0));
    }
  adw_window_title_set_subtitle (app->title, sub);
  g_free (sub);
}

static gboolean
grid_poll_tick (gpointer data)
{
  App *app = data;
  if (app->doc == NULL)
    {
      app->poll_id = 0;
      return G_SOURCE_REMOVE;
    }

  LsgRowCount rc = lsg_document_row_count (app->doc);
  LsgScanProgress prog = lsg_document_index_progress (app->doc);

  guint64 new_est = (rc.count > 0) ? rc.count : 1;
  if (lsg_grid_should_apply_estimate (app->row_estimate, new_est, FALSE))
    {
      app->row_estimate = new_est;
      grid_update_gutter (app);
      grid_update_vadjustment (app);
    }

  LsgWindowPollInputs in = { app->window_short, prog.complete };
  LsgWindowPollDecision d = lsg_window_poll_decide (in);
  if (d.reissue_window)
    {
      grid_materialize (app);
      gtk_widget_queue_draw (GTK_WIDGET (app->area));
    }

  grid_update_title_counts (app, rc, prog);

  /* Keep polling (and folding search snapshots) while a find is active, so its
   * live count grows, its landing scrolls into view, and the highlight mask
   * tracks the scan — even after the index poll would otherwise stop. */
  gboolean keep = d.continue_polling;
  if (app->find.display.active)
    {
      find_poll_fold (app);
      keep = TRUE;
    }

  if (!keep)
    {
      app->poll_id = 0;
      return G_SOURCE_REMOVE;
    }
  return G_SOURCE_CONTINUE;
}

/* ------------------------------------------------------------------------- */
/* Drawing                                                                    */
/* ------------------------------------------------------------------------- */

/* Set `layout`'s text and ellipsize width, then paint it left-aligned and
 * vertically centered in the row at (x, y). */
static void
draw_text (cairo_t *cr, PangoLayout *layout, const char *text,
           double x, double y, double avail_w, double row_h, double line_h)
{
  if (avail_w < 1.0)
    return;
  pango_layout_set_text (layout, (text != NULL) ? text : "", -1);
  pango_layout_set_width (layout, (int) (avail_w * PANGO_SCALE));
  cairo_move_to (cr, x, y + (row_h - line_h) / 2.0);
  pango_cairo_show_layout (cr, layout);
}

static void
grid_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
           gpointer data)
{
  App *app = data;
  if (app->doc == NULL || app->win == NULL)
    return;

  /* Milestone 2: window-fill = file-open begin -> first painted grid frame.
   * Cheap one-shot flag check; the delta is recorded here on the first real
   * paint after a document loads. */
  if (app->timing && app->first_frame_pending)
    {
      app->first_frame_pending = FALSE;
      gint64 dt = g_get_monotonic_time () - app->t_open_begin;
      g_printerr ("[timing] window-fill (open begin -> first frame): %.1f ms\n",
                  (double) dt / 1000.0);
    }

  /* All colors resolve from the active theme — no literal color constants. */
  GdkRGBA fg;
  gtk_widget_get_color (GTK_WIDGET (area), &fg);

  const double gutter = app->gutter_w;
  const double header_h = app->header_h;
  const double row_h = app->row_h;
  const double line_h = app->line_h;
  const double pad = 6.0;
  const double hval = gtk_adjustment_get_value (app->hadj);

  PangoLayout *layout = pango_cairo_create_layout (cr);
  pango_layout_set_font_description (layout, app->font_desc);
  pango_layout_set_ellipsize (layout, PANGO_ELLIPSIZE_END);
  pango_layout_set_single_paragraph_mode (layout, TRUE);

  const LsgColumnWindow cw = app->cur_colwin;
  const LsgRowSpan span = app->cur_span;
  const guint64 top = app->cur_top_row;
  const double pixel_off = app->cur_pixel_off;
  const guint32 got_rows = lsg_window_row_count (app->win);
  const guint32 got_cols = lsg_window_col_count (app->win);

  /* Subtle header / gutter tints and hairlines derived from the fg color. */
  GdkRGBA tint = fg;
  tint.alpha = 0.05;
  GdkRGBA line = fg;
  line.alpha = 0.15;

  /* Find highlights use the live system accent (Adwaita), never a hardcoded
   * color: subtle for in-scope matches, strong for the current match. */
  GdkRGBA accent = { 0, 0, 0, 0 };
  gboolean have_accent = FALSE;
  if (app->find.display.active)
    {
      GdkRGBA *a = adw_style_manager_get_accent_color_rgba (adw_style_manager_get_default ());
      if (a != NULL)
        {
          accent = *a;
          gdk_rgba_free (a);
          have_accent = TRUE;
        }
    }

  /* --- cells (clipped to the scrolling body region) --- */
  cairo_save (cr);
  cairo_rectangle (cr, gutter, header_h, (double) width - gutter,
                   (double) height - header_h);
  cairo_clip (cr);
  gdk_cairo_set_source_rgba (cr, &fg);

  for (guint32 ri = 0; ri < got_rows; ri++)
    {
      guint64 view_row = span.first_row + ri;
      double y = header_h + (double) ((gint64) (view_row - top)) * row_h - pixel_off;
      if (y + row_h < header_h || y > (double) height)
        continue;

      double x = gutter + (cw.first_x - hval);
      for (guint32 ci = 0; ci < got_cols; ci++)
        {
          guint col = cw.first + ci;
          double colw = (col < app->n_cols && app->col_widths[col] > 0.0)
                            ? app->col_widths[col]
                            : 0.0;

          /* Highlight a matching cell from the core's mask (accent tint); the
           * current match cell gets a stronger tint. */
          if (have_accent && app->mask.flags != NULL && ri < app->mask.rows
              && ci < app->mask.cols
              && app->mask.flags[(gsize) ri * app->mask.cols + ci])
            {
              gboolean is_current = app->find.display.has_current
                                    && app->find.display.current.row == view_row
                                    && app->find.display.current.column == col;
              GdkRGBA h = accent;
              h.alpha = is_current ? 0.55 : 0.28;
              gdk_cairo_set_source_rgba (cr, &h);
              cairo_rectangle (cr, x, y, colw, row_h);
              cairo_fill (cr);
              gdk_cairo_set_source_rgba (cr, &fg);   /* restore for the text */
            }

          const char *text = lsg_window_cell (app->win, ri, ci);
          draw_text (cr, layout, text, x + pad, y, colw - 2.0 * pad, row_h, line_h);
          x += colw;
        }
    }

  /* Cell-area horizontal hairlines. */
  gdk_cairo_set_source_rgba (cr, &line);
  cairo_set_line_width (cr, 1.0);
  for (guint32 ri = 0; ri < got_rows; ri++)
    {
      guint64 view_row = span.first_row + ri;
      double y = header_h + (double) ((gint64) (view_row - top + 1)) * row_h - pixel_off;
      cairo_move_to (cr, gutter, y + 0.5);
      cairo_line_to (cr, (double) width, y + 0.5);
    }
  cairo_stroke (cr);
  cairo_restore (cr);

  /* --- row-number gutter (sticky left; scrolls vertically only) --- */
  cairo_save (cr);
  cairo_rectangle (cr, 0.0, header_h, gutter, (double) height - header_h);
  cairo_clip (cr);
  gdk_cairo_set_source_rgba (cr, &tint);
  cairo_rectangle (cr, 0.0, header_h, gutter, (double) height - header_h);
  cairo_fill (cr);
  gdk_cairo_set_source_rgba (cr, &fg);
  for (guint32 ri = 0; ri < got_rows; ri++)
    {
      guint64 view_row = span.first_row + ri;
      double y = header_h + (double) ((gint64) (view_row - top)) * row_h - pixel_off;
      if (y + row_h < header_h || y > (double) height)
        continue;
      guint64 src = lsg_window_source_row (app->win, ri);
      char *label;
      if (src == LSG_NO_ROW)
        label = g_strdup ("");
      else if (lsg_window_row_oversized (app->win, ri))
        label = g_strdup_printf ("%" G_GUINT64_FORMAT "…", src + 1);
      else
        label = g_strdup_printf ("%" G_GUINT64_FORMAT, src + 1);
      draw_text (cr, layout, label, pad, y, gutter - 2.0 * pad, row_h, line_h);
      g_free (label);
    }
  cairo_restore (cr);

  /* --- column header (sticky top; scrolls horizontally only) --- */
  cairo_save (cr);
  cairo_rectangle (cr, gutter, 0.0, (double) width - gutter, header_h);
  cairo_clip (cr);
  gdk_cairo_set_source_rgba (cr, &tint);
  cairo_rectangle (cr, gutter, 0.0, (double) width - gutter, header_h);
  cairo_fill (cr);
  if (app->has_header && app->hdr_labels != NULL)
    {
      gdk_cairo_set_source_rgba (cr, &fg);
      double x = gutter + (cw.first_x - hval);
      for (guint32 ci = 0; ci < cw.count; ci++)
        {
          guint col = cw.first + ci;
          if (col >= app->n_cols)
            break;
          double colw = (app->col_widths[col] > 0.0) ? app->col_widths[col] : 0.0;
          const char *label = (ci < app->hdr_count) ? app->hdr_labels[ci] : "";
          draw_text (cr, layout, label, x + pad, 0.0,
                     colw - 2.0 * pad, header_h, line_h);
          x += colw;
        }
    }
  cairo_restore (cr);

  /* --- corner + separating hairlines --- */
  gdk_cairo_set_source_rgba (cr, &tint);
  cairo_rectangle (cr, 0.0, 0.0, gutter, header_h);
  cairo_fill (cr);
  gdk_cairo_set_source_rgba (cr, &line);
  cairo_set_line_width (cr, 1.0);
  cairo_move_to (cr, 0.0, header_h + 0.5);
  cairo_line_to (cr, (double) width, header_h + 0.5);
  cairo_move_to (cr, gutter + 0.5, 0.0);
  cairo_line_to (cr, gutter + 0.5, (double) height);
  cairo_stroke (cr);

  g_object_unref (layout);
}

/* ------------------------------------------------------------------------- */
/* Open a document into the grid                                              */
/* ------------------------------------------------------------------------- */

static void
measure_font (App *app)
{
  PangoContext *pctx = gtk_widget_get_pango_context (GTK_WIDGET (app->area));
  PangoFontMetrics *m = pango_context_get_metrics (pctx, app->font_desc, NULL);
  int char_w = pango_font_metrics_get_approximate_char_width (m);
  int ascent = pango_font_metrics_get_ascent (m);
  int descent = pango_font_metrics_get_descent (m);
  pango_font_metrics_unref (m);

  app->char_advance = (double) char_w / PANGO_SCALE;
  if (app->char_advance < 1.0)
    app->char_advance = 8.0;
  app->line_h = (double) (ascent + descent) / PANGO_SCALE;
  if (app->line_h < 1.0)
    app->line_h = 16.0;
  app->row_h = app->line_h + 10.0;
  app->header_h = app->line_h + 12.0;
}

static void
sample_column_widths (App *app)
{
  guint32 sample_cols = (app->n_cols < WIDTH_SAMPLE_COLS) ? app->n_cols
                                                          : WIDTH_SAMPLE_COLS;
  double default_w = app->char_advance * 12.0 + 12.0;
  for (guint32 c = 0; c < app->n_cols; c++)
    app->col_widths[c] = default_w;
  if (sample_cols == 0)
    return;

  LsgWindow *sw =
      lsg_document_set_window (app->doc, 0, WIDTH_SAMPLE_ROWS, 0, sample_cols);
  guint32 got = lsg_window_row_count (sw);
  guint32 gotc = lsg_window_col_count (sw);

  double min_w = app->char_advance * 3.0 + 12.0;
  double max_w = app->char_advance * 60.0 + 12.0;
  for (guint32 c = 0; c < gotc; c++)
    {
      const char *cells[WIDTH_SAMPLE_ROWS];
      guint cnt = 0;
      for (guint32 r = 0; r < got && cnt < WIDTH_SAMPLE_ROWS; r++)
        cells[cnt++] = lsg_window_cell (sw, r, c);
      /* Header dup is fetched locally and freed — bounded to the sampled
       * (head) columns, so open stays O(head), never O(column_count). */
      char *hdr = app->has_header ? lsg_document_header_cell_dup (app->doc, c) : NULL;
      double wpx = lsg_grid_column_width_estimate (cells, cnt, hdr,
                                                   app->char_advance,
                                                   app->char_advance * 2.0 + 12.0);
      g_free (hdr);
      if (wpx < min_w)
        wpx = min_w;
      if (wpx > max_w)
        wpx = max_w;
      app->col_widths[c] = wpx;
    }
  lsg_window_free (sw);
}

static void
open_document (App *app, LsgDocument *doc, const char *title)
{
  /* Arm the window-fill timer if an outer caller (open_file) has not already —
   * e.g. the network-adopt path enters here directly. */
  if (app->timing && !app->first_frame_pending)
    {
      app->t_open_begin = g_get_monotonic_time ();
      app->first_frame_pending = TRUE;
    }

  app_reset_document (app);
  app->doc = doc;

  app->n_cols = lsg_document_column_count (doc);
  app->has_header = lsg_document_has_header (doc);
  /* Header labels are NOT prefetched for every column (that would be
   * O(column_count) window-lane calls + retained strings, breaking the
   * wide-doc viewport-only NFR). They are fetched lazily for the visible
   * column window in grid_materialize, exactly as the cells are. */
  app->col_widths = g_new0 (double, (app->n_cols > 0) ? app->n_cols : 1);

  LsgRowCount rc = lsg_document_row_count (doc);
  app->row_estimate = (rc.count > 0) ? rc.count : 1;

  measure_font (app);
  sample_column_widths (app);
  grid_update_gutter (app);
  grid_update_vadjustment (app);
  grid_update_hadjustment (app);
  gtk_adjustment_set_value (app->vadj, 0.0);
  gtk_adjustment_set_value (app->hadj, 0.0);

  adw_window_title_set_title (app->title, (title != NULL) ? title : "less-sheet");
  grid_update_title_counts (app, rc, lsg_document_index_progress (doc));

  gtk_stack_set_visible_child_name (app->stack, "grid");
  grid_materialize (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));

  if (app->poll_id == 0)
    app->poll_id = g_timeout_add (POLL_INTERVAL_MS, grid_poll_tick, app);
}

/* ------------------------------------------------------------------------- */
/* Open local file                                                            */
/* ------------------------------------------------------------------------- */

/* Open one local GFile into the grid (or an error page). Does NOT take
 * ownership of `file`. Shared by the file dialog, drag-open (future), and the
 * command-line "open" path. */
static void
open_file (App *app, GFile *file)
{
  char *path = g_file_get_path (file);
  char *base = g_file_get_basename (file);

  if (path == NULL)
    {
      show_error (app, "Unsupported location",
                  "Only local files can be opened this way.");
      g_free (base);
      return;
    }

  /* Window-fill begin edge is captured BEFORE the open so the measured time
   * includes the O(head) ls_open cost; armed only on success. */
  gint64 begin = app->timing ? g_get_monotonic_time () : 0;
  LsgOpenError err = LSG_OPEN_OK;
  LsgDocument *doc = lsg_document_open_local (path, NULL, &err);
  if (doc == NULL)
    {
      show_error (app, "Could not open file", open_error_text (err));
    }
  else
    {
      if (app->timing)
        {
          app->t_open_begin = begin;
          app->first_frame_pending = TRUE;
        }
      open_document (app, doc, base);
    }

  g_free (path);
  g_free (base);
}

static void
on_file_opened (GObject *source, GAsyncResult *res, gpointer data)
{
  App *app = data;
  GError *error = NULL;
  GFile *file =
      gtk_file_dialog_open_finish (GTK_FILE_DIALOG (source), res, &error);
  if (file == NULL)
    {
      /* User cancellation is not an error to surface. */
      g_clear_error (&error);
      return;
    }
  open_file (app, file);
  g_object_unref (file);
}

static void
action_open (GtkButton *button, gpointer data)
{
  (void) button;
  App *app = data;
  GtkFileDialog *dialog = gtk_file_dialog_new ();
  gtk_file_dialog_set_title (dialog, "Open Delimited File");
  gtk_file_dialog_open (dialog, app->window, NULL, on_file_opened, app);
  g_object_unref (dialog);
}

/* ------------------------------------------------------------------------- */
/* Open URL (network)                                                         */
/* ------------------------------------------------------------------------- */

static void
update_net_banner (App *app, const LsgNetProgress *p)
{
  char *text;
  if (p->has_fraction)
    text = g_strdup_printf ("Fetching %s — %d%%",
                            (app->pending_url != NULL) ? app->pending_url : "",
                            (int) (p->fraction * 100.0));
  else
    text = g_strdup_printf ("Fetching %s — %" G_GUINT64_FORMAT " bytes",
                            (app->pending_url != NULL) ? app->pending_url : "",
                            p->bytes_fetched);
  adw_banner_set_title (app->banner, text);
  g_free (text);
}

static const char *
net_error_text (LsgNetError e)
{
  switch (e)
    {
    case LSG_NET_ERROR_INVALID_ARGUMENT:   return "The URL or scheme is not valid (use http:// or https://).";
    case LSG_NET_ERROR_UNREACHABLE:        return "The host could not be reached.";
    case LSG_NET_ERROR_TIMEOUT:            return "The connection timed out.";
    case LSG_NET_ERROR_HTTP_STATUS:        return "The server returned an error status.";
    case LSG_NET_ERROR_TOO_MANY_REDIRECTS: return "The redirect chain was too long.";
    case LSG_NET_ERROR_IO:                 return "A local spool-file error occurred.";
    case LSG_NET_ERROR_CANCELLED:          return "The open was cancelled.";
    default:                               return "The network document could not be opened.";
    }
}

static gboolean
net_poll_tick (gpointer data)
{
  App *app = data;
  if (app->net == NULL)
    {
      app->net_poll_id = 0;
      return G_SOURCE_REMOVE;
    }

  LsgNetProgress p = lsg_net_open_poll (app->net);
  update_net_banner (app, &p);

  if (!lsg_net_state_is_terminal (p.state))
    return G_SOURCE_CONTINUE;

  adw_banner_set_revealed (app->banner, FALSE);
  if (p.state == LSG_NET_DONE)
    {
      LsgDocument *doc = lsg_net_open_adopt_document (app->net);
      lsg_net_open_release (app->net);
      app->net = NULL;
      if (doc != NULL)
        open_document (app, doc, (app->pending_url != NULL) ? app->pending_url : "URL");
      else
        show_error (app, "Could not open URL",
                    "The network document could not be adopted.");
    }
  else
    {
      char http[64];
      const char *msg = net_error_text (p.error);
      if (p.error == LSG_NET_ERROR_HTTP_STATUS)
        {
          g_snprintf (http, sizeof http, "HTTP status %d.", p.http_status);
          msg = http;
        }
      lsg_net_open_release (app->net);
      app->net = NULL;
      if (p.state == LSG_NET_FAILED)
        show_error (app, "Could not open URL", msg);
    }

  app->net_poll_id = 0;
  return G_SOURCE_REMOVE;
}

static void
on_banner_cancel (AdwBanner *banner, gpointer data)
{
  (void) banner;
  App *app = data;
  if (app->net != NULL)
    lsg_net_open_cancel (app->net);
}

static void
on_url_response (AdwAlertDialog *dialog, const char *response, gpointer data)
{
  App *app = data;
  if (g_strcmp0 (response, "open") != 0)
    return;

  GtkEditable *entry = g_object_get_data (G_OBJECT (dialog), "url-entry");
  const char *url = (entry != NULL) ? gtk_editable_get_text (entry) : NULL;
  if (url == NULL || url[0] == '\0')
    return;

  g_clear_pointer (&app->pending_url, g_free);
  app->pending_url = g_strdup (url);

  if (app->net != NULL)
    {
      lsg_net_open_cancel (app->net);
      lsg_net_open_release (app->net);
      app->net = NULL;
    }
  app->net = lsg_net_open_start (url, NULL);
  if (app->net == NULL)
    {
      show_error (app, "Could not open URL", "The open job could not be started.");
      return;
    }

  adw_banner_set_title (app->banner, "Connecting…");
  adw_banner_set_button_label (app->banner, "Cancel");
  adw_banner_set_revealed (app->banner, TRUE);
  if (app->net_poll_id == 0)
    app->net_poll_id = g_timeout_add (POLL_INTERVAL_MS, net_poll_tick, app);
}

static void
action_open_url (GtkButton *button, gpointer data)
{
  (void) button;
  App *app = data;

  AdwDialog *dialog = adw_alert_dialog_new ("Open URL", NULL);
  adw_alert_dialog_set_body (ADW_ALERT_DIALOG (dialog),
                             "Enter an http:// or https:// address of a .csv or .csv.gz file.");

  GtkWidget *entry = gtk_entry_new ();
  gtk_entry_set_input_purpose (GTK_ENTRY (entry), GTK_INPUT_PURPOSE_URL);
  gtk_entry_set_placeholder_text (GTK_ENTRY (entry), "https://example.com/data.csv");
  adw_alert_dialog_set_extra_child (ADW_ALERT_DIALOG (dialog), entry);
  g_object_set_data (G_OBJECT (dialog), "url-entry", entry);

  adw_alert_dialog_add_response (ADW_ALERT_DIALOG (dialog), "cancel", "Cancel");
  adw_alert_dialog_add_response (ADW_ALERT_DIALOG (dialog), "open", "Open");
  adw_alert_dialog_set_response_appearance (ADW_ALERT_DIALOG (dialog), "open",
                                            ADW_RESPONSE_SUGGESTED);
  adw_alert_dialog_set_default_response (ADW_ALERT_DIALOG (dialog), "open");
  adw_alert_dialog_set_close_response (ADW_ALERT_DIALOG (dialog), "cancel");

  g_signal_connect (dialog, "response", G_CALLBACK (on_url_response), app);
  adw_dialog_present (dialog, GTK_WIDGET (app->window));
}

/* ------------------------------------------------------------------------- */
/* Scroll / keyboard input on the grid                                        */
/* ------------------------------------------------------------------------- */

static gboolean
on_scroll (GtkEventControllerScroll *ctrl, double dx, double dy, gpointer data)
{
  (void) ctrl;
  App *app = data;
  if (app->doc == NULL)
    return GDK_EVENT_PROPAGATE;

  if (dy != 0.0)
    gtk_adjustment_set_value (app->vadj,
                              gtk_adjustment_get_value (app->vadj) + dy * app->row_h * 3.0);
  if (dx != 0.0)
    gtk_adjustment_set_value (app->hadj,
                              gtk_adjustment_get_value (app->hadj) + dx * app->char_advance * 6.0);
  return GDK_EVENT_STOP;
}

static gboolean
on_key_pressed (GtkEventControllerKey *ctrl, guint keyval, guint keycode,
                GdkModifierType state, gpointer data)
{
  (void) ctrl;
  (void) keycode;
  (void) state;
  App *app = data;
  if (app->doc == NULL)
    return GDK_EVENT_PROPAGATE;

  double v = gtk_adjustment_get_value (app->vadj);
  double page = gtk_adjustment_get_page_size (app->vadj);
  switch (keyval)
    {
    case GDK_KEY_Down:      gtk_adjustment_set_value (app->vadj, v + app->row_h); return GDK_EVENT_STOP;
    case GDK_KEY_Up:        gtk_adjustment_set_value (app->vadj, v - app->row_h); return GDK_EVENT_STOP;
    case GDK_KEY_Page_Down: gtk_adjustment_set_value (app->vadj, v + page);       return GDK_EVENT_STOP;
    case GDK_KEY_Page_Up:   gtk_adjustment_set_value (app->vadj, v - page);       return GDK_EVENT_STOP;
    case GDK_KEY_Home:      gtk_adjustment_set_value (app->vadj, 0.0);            return GDK_EVENT_STOP;
    case GDK_KEY_End:       gtk_adjustment_set_value (app->vadj,
                                                      gtk_adjustment_get_upper (app->vadj)); return GDK_EVENT_STOP;
    default:                return GDK_EVENT_PROPAGATE;
    }
}

static void
on_adjustment_changed (GtkAdjustment *adj, gpointer data)
{
  (void) adj;
  App *app = data;
  if (app->doc == NULL)
    return;
  grid_materialize (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
}

static void
on_area_resize (GtkDrawingArea *area, int width, int height, gpointer data)
{
  (void) area;
  (void) width;
  (void) height;
  App *app = data;
  if (app->doc == NULL)
    return;
  grid_update_vadjustment (app);
  grid_update_hadjustment (app);
  grid_materialize (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
}

/* ------------------------------------------------------------------------- */
/* Find (slice 2): the popover UI + highlight glue over lsg_find               */
/* ------------------------------------------------------------------------- */

static void
find_ensure_poll (App *app)
{
  if (app->poll_id == 0 && app->doc != NULL)
    app->poll_id = g_timeout_add (POLL_INTERVAL_MS, grid_poll_tick, app);
}

/* Compose the count / notice label from the pure display (+ a lingering wrap
 * notice, which is otherwise a single-tick state). */
static void
find_update_labels (App *app)
{
  if (app->find_status == NULL)
    return;
  const LsgFindDisplay *d = &app->find.display;
  char *owned = NULL;
  const char *text = "";

  if (app->find_sticky_notice == LSG_FIND_NOTICE_WRAPPED_TO_START)
    text = "Wrapped to start";
  else if (app->find_sticky_notice == LSG_FIND_NOTICE_WRAPPED_TO_END)
    text = "Wrapped to end";
  else if (d->notice == LSG_FIND_NOTICE_NO_MATCHES)
    text = "No matches";
  else if (d->notice == LSG_FIND_NOTICE_STOPPED)
    text = "Stopped";
  else if (d->active)
    {
      if (d->has_current)
        owned = g_strdup_printf ("%" G_GUINT64_FORMAT " of %" G_GUINT64_FORMAT "%s",
                                 d->position, d->total, d->total_final ? "" : "…");
      else if (d->total > 0)
        owned = g_strdup_printf ("%" G_GUINT64_FORMAT " matches%s",
                                 d->total, d->total_final ? "" : "…");
      else
        text = "Searching…";
    }

  gtk_label_set_text (app->find_status, owned != NULL ? owned : text);
  g_free (owned);
}

/* Scroll the grid so `row` is comfortably visible (no-op if it already is). */
static void
scroll_to_match (App *app, guint64 row)
{
  int h = gtk_widget_get_height (GTK_WIDGET (app->area));
  if (h <= 0 || app->row_h <= 0.0)
    return;
  double visible = ((double) h - app->header_h) / app->row_h;
  if (row >= app->cur_top_row && (double) (row - app->cur_top_row) < visible - 1.0)
    return;                                   /* already on screen */
  guint64 target = (row > 2) ? row - 2 : 0;   /* leave a small top margin */
  double upper = gtk_adjustment_get_upper (app->vadj);
  double off = lsg_grid_offset_for_top_row (target, upper, app->row_estimate, app->row_h);
  gtk_adjustment_set_value (app->vadj, off);  /* fires materialize + repaint */
}

static gboolean
find_notice_clear (gpointer data)
{
  App *app = data;
  app->find_sticky_notice = LSG_FIND_NOTICE_NONE;
  app->find_notice_id = 0;
  find_update_labels (app);
  return G_SOURCE_REMOVE;
}

static void
find_set_sticky_notice (App *app, LsgFindNotice notice)
{
  app->find_sticky_notice = notice;
  if (app->find_notice_id != 0)
    g_source_remove (app->find_notice_id);
  app->find_notice_id = g_timeout_add (2500, find_notice_clear, app);
}

/* (Re)run the current entry text as a live TEXT search, or clear when empty. */
static void
find_run_query (App *app)
{
  if (app->doc == NULL)
    return;

  app->find.draft.mode = LSG_FIND_TEXT;
  app->find.draft.text = gtk_editable_get_text (app->find_entry); /* borrowed */

  /* Slice-2 UI is text find over ALL columns (no column hiding yet): the whole
   * column set is visible, so the composed scope is NULL. */
  LsgFindSubmit sub = lsg_find_submit (app->find, NULL, app->n_cols, app->n_cols);
  if (sub.outcome == LSG_FIND_RUN
      && lsg_document_search_start (app->doc, sub.request))
    {
      app->find = lsg_find_began (app->find);
      app->find_nav_direction = LSG_SEARCH_FORWARD;
      app->find_wrap_issued = FALSE;
      lsg_document_search_nav (app->doc, lsg_search_nav_from_top ());
      find_ensure_poll (app);
    }
  else
    {
      /* Empty query (IGNORED) or a rejected/failed start: clear the search. */
      lsg_document_search_cancel (app->doc);
      app->find = lsg_find_closed (app->find);
    }

  grid_materialize (app);          /* refresh (or clear) the highlight mask */
  find_update_labels (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
}

/* Forward-declared above; folds one search poll into the display. */
static void
find_poll_fold (App *app)
{
  LsgSearchSnapshot snap;
  gboolean has = lsg_document_search_poll (app->doc, &snap);

  gboolean prev_has = app->find.display.has_current;
  guint64 prev_row = prev_has ? app->find.display.current.row : 0;

  app->find = lsg_find_resolved (app->find, has, snap, app->find_nav_direction);

  /* A wrap notice asks for a follow-up navigation (issued once); it self-clears
   * when the wrap lands as a FOUND poll. */
  LsgSearchNav wnav;
  if (lsg_find_wrap_nav (app->find, &wnav))
    {
      if (!app->find_wrap_issued)
        {
          app->find_nav_direction = wnav.direction;
          app->find_wrap_issued = TRUE;
          lsg_document_search_nav (app->doc, wnav);
          find_set_sticky_notice (app, app->find.display.notice);
        }
    }
  else
    {
      app->find_wrap_issued = FALSE;
    }

  if (app->find.display.has_current
      && (!prev_has || app->find.display.current.row != prev_row))
    scroll_to_match (app, app->find.display.current.row);

  grid_materialize (app);          /* refresh the highlight mask as the scan advances */
  find_update_labels (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
}

static void
do_find_step (App *app, LsgSearchDir direction)
{
  if (app->doc == NULL || !app->find.display.active)
    return;
  LsgSearchNav nav;
  if (lsg_find_step (app->find, direction, app->cur_top_row, &nav))
    {
      app->find_nav_direction = direction;
      app->find_wrap_issued = FALSE;
      lsg_document_search_nav (app->doc, nav);
      find_ensure_poll (app);
    }
}

static void
on_find_search_changed (GtkSearchEntry *entry, gpointer data)
{
  (void) entry;
  find_run_query ((App *) data);
}

static void
on_find_next_clicked (GtkButton *button, gpointer data)
{
  (void) button;
  do_find_step ((App *) data, LSG_SEARCH_FORWARD);
}

static void
on_find_prev_clicked (GtkButton *button, gpointer data)
{
  (void) button;
  do_find_step ((App *) data, LSG_SEARCH_BACKWARD);
}

static gboolean
on_find_entry_key (GtkEventControllerKey *ctrl, guint keyval, guint keycode,
                   GdkModifierType state, gpointer data)
{
  (void) ctrl;
  (void) keycode;
  App *app = data;
  switch (keyval)
    {
    case GDK_KEY_Escape:
      gtk_popover_popdown (app->find_popover);
      return GDK_EVENT_STOP;
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
      do_find_step (app, (state & GDK_SHIFT_MASK) ? LSG_SEARCH_BACKWARD
                                                  : LSG_SEARCH_FORWARD);
      return GDK_EVENT_STOP;
    default:
      return GDK_EVENT_PROPAGATE;
    }
}

/* Esc / click-away: cancel the core search + clear highlights; keep the draft. */
static void
on_find_popover_closed (GtkPopover *popover, gpointer data)
{
  (void) popover;
  App *app = data;
  if (app->doc != NULL)
    lsg_document_search_cancel (app->doc);
  app->find = lsg_find_closed (app->find);
  app->find_wrap_issued = FALSE;
  app->find_sticky_notice = LSG_FIND_NOTICE_NONE;
  if (app->find_notice_id != 0)
    {
      g_source_remove (app->find_notice_id);
      app->find_notice_id = 0;
    }
  find_clear_mask (app);
  find_update_labels (app);
  if (app->doc != NULL)
    {
      grid_materialize (app);
      gtk_widget_queue_draw (GTK_WIDGET (app->area));
    }
}

/* Opening (re)focuses the entry and re-runs any retained query to re-highlight. */
static void
on_find_popover_show (GtkWidget *popover, gpointer data)
{
  (void) popover;
  App *app = data;
  gtk_widget_grab_focus (GTK_WIDGET (app->find_entry));
  const char *text = gtk_editable_get_text (app->find_entry);
  if (text != NULL && text[0] != '\0')
    find_run_query (app);
}

static void
open_find (App *app)
{
  if (app->doc == NULL || app->find_button == NULL)
    return;
  gtk_menu_button_popup (app->find_button);
}

static gboolean
on_window_key (GtkEventControllerKey *ctrl, guint keyval, guint keycode,
               GdkModifierType state, gpointer data)
{
  (void) ctrl;
  (void) keycode;
  App *app = data;
  if ((state & GDK_CONTROL_MASK)
      && (keyval == GDK_KEY_f || keyval == GDK_KEY_F))
    {
      open_find (app);
      return GDK_EVENT_STOP;
    }
  return GDK_EVENT_PROPAGATE;
}

static void
build_find_popover (App *app)
{
  GtkWidget *pop = gtk_popover_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);

  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *entry = gtk_search_entry_new ();
  gtk_widget_set_hexpand (entry, TRUE);
  gtk_widget_set_size_request (entry, 220, -1);
  app->find_entry = GTK_EDITABLE (entry);

  GtkWidget *prev = gtk_button_new_from_icon_name ("go-up-symbolic");
  gtk_widget_set_tooltip_text (prev, "Previous match (Shift+Enter)");
  gtk_widget_add_css_class (prev, "flat");
  GtkWidget *next = gtk_button_new_from_icon_name ("go-down-symbolic");
  gtk_widget_set_tooltip_text (next, "Next match (Enter)");
  gtk_widget_add_css_class (next, "flat");

  gtk_box_append (GTK_BOX (row), entry);
  gtk_box_append (GTK_BOX (row), prev);
  gtk_box_append (GTK_BOX (row), next);

  GtkWidget *status = gtk_label_new ("");
  gtk_widget_set_halign (status, GTK_ALIGN_START);
  gtk_widget_add_css_class (status, "dim-label");
  app->find_status = GTK_LABEL (status);

  gtk_box_append (GTK_BOX (box), row);
  gtk_box_append (GTK_BOX (box), status);
  gtk_popover_set_child (GTK_POPOVER (pop), box);
  app->find_popover = GTK_POPOVER (pop);

  g_signal_connect (entry, "search-changed", G_CALLBACK (on_find_search_changed), app);
  g_signal_connect (prev, "clicked", G_CALLBACK (on_find_prev_clicked), app);
  g_signal_connect (next, "clicked", G_CALLBACK (on_find_next_clicked), app);
  g_signal_connect (pop, "closed", G_CALLBACK (on_find_popover_closed), app);
  g_signal_connect (pop, "show", G_CALLBACK (on_find_popover_show), app);

  GtkEventController *keys = gtk_event_controller_key_new ();
  g_signal_connect (keys, "key-pressed", G_CALLBACK (on_find_entry_key), app);
  gtk_widget_add_controller (entry, keys);
}

/* ------------------------------------------------------------------------- */
/* UI construction                                                            */
/* ------------------------------------------------------------------------- */

static GtkWidget *
build_launch_page (App *app)
{
  GtkWidget *status = adw_status_page_new ();
  adw_status_page_set_icon_name (ADW_STATUS_PAGE (status),
                                 "x-office-spreadsheet-symbolic");
  adw_status_page_set_title (ADW_STATUS_PAGE (status), "less-sheet");
  adw_status_page_set_description (ADW_STATUS_PAGE (status),
                                   "Open a delimited file, or a CSV over the network.");

  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_widget_set_halign (box, GTK_ALIGN_CENTER);

  GtkWidget *open = gtk_button_new_with_label ("Open File…");
  gtk_widget_add_css_class (open, "pill");
  gtk_widget_add_css_class (open, "suggested-action");
  g_signal_connect (open, "clicked", G_CALLBACK (action_open), app);

  GtkWidget *open_url = gtk_button_new_with_label ("Open URL…");
  gtk_widget_add_css_class (open_url, "pill");
  g_signal_connect (open_url, "clicked", G_CALLBACK (action_open_url), app);

  gtk_box_append (GTK_BOX (box), open);
  gtk_box_append (GTK_BOX (box), open_url);
  adw_status_page_set_child (ADW_STATUS_PAGE (status), box);
  return status;
}

static GtkWidget *
build_grid_page (App *app)
{
  GtkWidget *grid = gtk_grid_new ();

  app->vadj = g_object_ref_sink (gtk_adjustment_new (0, 0, 1, 1, 1, 1));
  app->hadj = g_object_ref_sink (gtk_adjustment_new (0, 0, 1, 1, 1, 1));

  app->area = GTK_DRAWING_AREA (gtk_drawing_area_new ());
  gtk_widget_set_hexpand (GTK_WIDGET (app->area), TRUE);
  gtk_widget_set_vexpand (GTK_WIDGET (app->area), TRUE);
  gtk_widget_set_focusable (GTK_WIDGET (app->area), TRUE);
  gtk_drawing_area_set_draw_func (app->area, grid_draw, app, NULL);
  g_signal_connect (app->area, "resize", G_CALLBACK (on_area_resize), app);

  GtkWidget *vscroll = gtk_scrollbar_new (GTK_ORIENTATION_VERTICAL, app->vadj);
  GtkWidget *hscroll = gtk_scrollbar_new (GTK_ORIENTATION_HORIZONTAL, app->hadj);

  g_signal_connect (app->vadj, "value-changed", G_CALLBACK (on_adjustment_changed), app);
  g_signal_connect (app->hadj, "value-changed", G_CALLBACK (on_adjustment_changed), app);

  GtkEventController *scroll =
      gtk_event_controller_scroll_new (GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
  g_signal_connect (scroll, "scroll", G_CALLBACK (on_scroll), app);
  gtk_widget_add_controller (GTK_WIDGET (app->area), scroll);

  GtkEventController *keys = gtk_event_controller_key_new ();
  g_signal_connect (keys, "key-pressed", G_CALLBACK (on_key_pressed), app);
  gtk_widget_add_controller (GTK_WIDGET (app->area), keys);

  gtk_grid_attach (GTK_GRID (grid), GTK_WIDGET (app->area), 0, 0, 1, 1);
  gtk_grid_attach (GTK_GRID (grid), vscroll, 1, 0, 1, 1);
  gtk_grid_attach (GTK_GRID (grid), hscroll, 0, 1, 1, 1);
  return grid;
}

/* Milestone 1: UI cold-start = main() entry -> the window first mapped/shown.
 * One-shot (map can fire again on remap); inert unless timing is enabled. */
static void
on_window_map (GtkWidget *widget, gpointer data)
{
  (void) widget;
  App *app = data;
  if (!app->timing || app->ui_shown_reported)
    return;
  app->ui_shown_reported = TRUE;
  gint64 dt = g_get_monotonic_time () - app->t_start;
  g_printerr ("[timing] ui cold-start (main -> window mapped): %.1f ms\n",
              (double) dt / 1000.0);
}

/* Build the single window once (idempotent). Shared by "activate" (no file) and
 * "open" (a file passed on the command line / by the file manager). */
static void
ensure_window (App *app, GtkApplication *gtk_app)
{
  if (app->window != NULL)
    return;
  app->app = ADW_APPLICATION (gtk_app);

  GtkWidget *win = adw_application_window_new (gtk_app);
  app->window = GTK_WINDOW (win);
  g_signal_connect (win, "map", G_CALLBACK (on_window_map), app);

  /* Ctrl+F opens find from anywhere in the window (capture phase). */
  GtkEventController *win_keys = gtk_event_controller_key_new ();
  gtk_event_controller_set_propagation_phase (win_keys, GTK_PHASE_CAPTURE);
  g_signal_connect (win_keys, "key-pressed", G_CALLBACK (on_window_key), app);
  gtk_widget_add_controller (win, win_keys);
  gtk_window_set_title (app->window, "less-sheet");
  gtk_window_set_default_size (app->window, 1024, 720);

  /* Header bar: Open + Open URL on the left, filename title in the center. */
  GtkWidget *header = adw_header_bar_new ();
  app->title = ADW_WINDOW_TITLE (adw_window_title_new ("less-sheet", ""));
  adw_header_bar_set_title_widget (ADW_HEADER_BAR (header), GTK_WIDGET (app->title));

  GtkWidget *open_btn = gtk_button_new_from_icon_name ("document-open-symbolic");
  gtk_widget_set_tooltip_text (open_btn, "Open File");
  g_signal_connect (open_btn, "clicked", G_CALLBACK (action_open), app);
  adw_header_bar_pack_start (ADW_HEADER_BAR (header), open_btn);

  GtkWidget *url_btn = gtk_button_new_from_icon_name ("emblem-web-symbolic");
  gtk_widget_set_tooltip_text (url_btn, "Open URL");
  g_signal_connect (url_btn, "clicked", G_CALLBACK (action_open_url), app);
  adw_header_bar_pack_start (ADW_HEADER_BAR (header), url_btn);

  /* Find: a menu button on the right whose popover is the find UI (Ctrl+F). */
  GtkWidget *find_btn = gtk_menu_button_new ();
  gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (find_btn), "edit-find-symbolic");
  gtk_widget_set_tooltip_text (find_btn, "Find (Ctrl+F)");
  app->find_button = GTK_MENU_BUTTON (find_btn);
  build_find_popover (app);
  gtk_menu_button_set_popover (GTK_MENU_BUTTON (find_btn), GTK_WIDGET (app->find_popover));
  adw_header_bar_pack_end (ADW_HEADER_BAR (header), find_btn);

  /* Banner (network progress) above the swappable content stack. */
  app->banner = ADW_BANNER (adw_banner_new (""));
  adw_banner_set_revealed (app->banner, FALSE);
  g_signal_connect (app->banner, "button-clicked", G_CALLBACK (on_banner_cancel), app);

  app->stack = GTK_STACK (gtk_stack_new ());
  gtk_widget_set_vexpand (GTK_WIDGET (app->stack), TRUE);
  gtk_stack_add_named (app->stack, build_launch_page (app), "launch");
  gtk_stack_add_named (app->stack, build_grid_page (app), "grid");

  GtkWidget *error = adw_status_page_new ();
  adw_status_page_set_icon_name (ADW_STATUS_PAGE (error), "dialog-error-symbolic");
  app->error_page = ADW_STATUS_PAGE (error);
  gtk_stack_add_named (app->stack, error, "error");

  gtk_stack_set_visible_child_name (app->stack, "launch");

  GtkWidget *content = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_box_append (GTK_BOX (content), GTK_WIDGET (app->banner));
  gtk_box_append (GTK_BOX (content), GTK_WIDGET (app->stack));

  GtkWidget *toolbar = adw_toolbar_view_new ();
  app->toolbar = ADW_TOOLBAR_VIEW (toolbar);
  adw_toolbar_view_add_top_bar (ADW_TOOLBAR_VIEW (toolbar), header);
  adw_toolbar_view_set_content (ADW_TOOLBAR_VIEW (toolbar), content);

  adw_application_window_set_content (ADW_APPLICATION_WINDOW (win), toolbar);
}

/* No file: launch screen. */
static void
on_activate (GtkApplication *gtk_app, gpointer data)
{
  App *app = data;
  ensure_window (app, gtk_app);
  gtk_window_present (app->window);
}

/*
 * Command-line / file-manager open (G_APPLICATION_HANDLES_OPEN). Opens the
 * FIRST passed file via the shared local-open path; extra files are ignored
 * (single-window slice 1). The GFile array is owned by GApplication for the
 * duration of the call — we borrow, never unref.
 */
static void
on_open (GApplication *gapp, GFile **files, gint n_files, const char *hint,
         gpointer data)
{
  (void) hint;
  App *app = data;
  ensure_window (app, GTK_APPLICATION (gapp));
  gtk_window_present (app->window);
  if (n_files >= 1 && files != NULL && files[0] != NULL)
    open_file (app, files[0]);
}

int
main (int argc, char *argv[])
{
  App app = { 0 };
  app.t_start = g_get_monotonic_time ();            /* capture entry ASAP */
  app.timing = (g_getenv ("LESSSHEET_GTK_TIMING") != NULL);
  app.row_estimate = 1;
  app.find = lsg_find_initial ();
  app.find_nav_direction = LSG_SEARCH_FORWARD;
  app.font_desc = pango_font_description_from_string ("Monospace 11");

  g_autoptr (AdwApplication) application =
      adw_application_new ("dev.lesssheet.Gtk", G_APPLICATION_HANDLES_OPEN);
  g_signal_connect (application, "activate", G_CALLBACK (on_activate), &app);
  g_signal_connect (application, "open", G_CALLBACK (on_open), &app);
  int status = g_application_run (G_APPLICATION (application), argc, argv);

  app_reset_document (&app);
  if (app.net != NULL)
    {
      lsg_net_open_release (app.net);
      app.net = NULL;
    }
  if (app.net_poll_id != 0)
    g_source_remove (app.net_poll_id);
  if (app.find_notice_id != 0)
    g_source_remove (app.find_notice_id);
  find_clear_mask (&app);
  g_clear_pointer (&app.pending_url, g_free);
  g_clear_pointer (&app.vadj, g_object_unref);
  g_clear_pointer (&app.hadj, g_object_unref);
  pango_font_description_free (app.font_desc);
  return status;
}
