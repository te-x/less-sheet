/*
 * less-sheet GTK frontend — the slice-1 viewer ("open + display + scroll").
 *
 * This is the GTK glue + drawing; ALL logic lives in the display-free lsg_*
 * modules (the C analogs of the macOS frontend): lsg_document (windowed
 * session over the Zig core), lsg_grid_geometry (the O(viewport)
 * row/column/scrollbar math), lsg_window_poll (the ~100 ms
 * materialize/keep-polling decision), lsg_net_open (the network-open drive),
 * lsg_formatter (the lossless cell formatter). main.c owns only the
 * AdwApplicationWindow + AdwHeaderBar chrome, the launch / error
 * AdwStatusPages, the header-bar progress widget for long-op / network status,
 * and the custom grid: a
 * GtkDrawingArea painted with Cairo + Pango, driven by a hand-managed
 * GtkAdjustment + GtkScrollbar, materializing ONLY the visible window (+
 * scroll buffer) via lsg_document_set_window — never O(file).
 *
 * The GNOME toolchain (GTK 4.20+/libadwaita 1.8+, decision 7 as raised by
 * ARCH-gtk-a11y decision 1 for AdwShortcutsDialog) is required;
 * this binary is compiled by the gate but run by the author on a real GNOME
 * desktop.
 */
#include <adwaita.h>
#include <gdk/gdkkeysyms.h>
#include <pango/pangocairo.h>

#include <lsg_a11y.h>
#include <lsg_column.h>
#include <lsg_copy.h>
#include <lsg_dialect.h>
#include <lsg_document.h>
#include <lsg_filter.h>
#include <lsg_find.h>
#include <lsg_formatter.h>
#include <lsg_grid_geometry.h>
#include <lsg_jump.h>
#include <lsg_net_open.h>
#include <lsg_window_poll.h>

#include <string.h>

/* Reverse-DNS application id — the single source of truth for it in this file.
 * It is simultaneously the AdwApplication id, the window/about icon NAME, and
 * (with dots as slashes) the GResource path the embedded logo is laid out
 * under, so all three can never drift apart. The matching literals in
 * data/lesssheet.gresource.xml are the one place that must be renamed in step
 * with these, because a .gresource.xml cannot read a #define; that file spells
 * the coupling out. A published app id is effectively permanent. */
#define LSG_APP_ID "com.lesssheet.LessSheet"
/* Root of the embedded hicolor-laid-out icon resource: LSG_APP_ID with '.'
 * -> '/', i.e. the gresource prefix minus its `/scalable/apps` leaf. (Also
 * GApplication's own default resource-base-path convention for the id.) */
#define LSG_ICON_RESOURCE_PATH "/com/lesssheet/LessSheet/icons"
/* Row buffer beyond the viewport (the scroll buffer), each side. */
#define GRID_OVERSCAN 4
/* Poll cadence for the frontier / network drive. */
#define POLL_INTERVAL_MS 100
/* Auto-dismiss delay for the in-app AdwToast notices (single source of truth —
 * every toast goes through settings_toast, which sets this). */
#define TOAST_TIMEOUT_SECONDS 3
/* Poll cadence for the Columns page's async type-inference refresh. */
#define INFER_POLL_INTERVAL_MS 80
/* Bound the per-open width sample so a wide (100k-col) document stays O(head):
 * only these leading columns are measured; the rest take a default width. */
#define WIDTH_SAMPLE_COLS 256
#define WIDTH_SAMPLE_ROWS 64
/* Frontend byte budget for one clipboard copy (the macOS CopyBudget.standard
 * ~64 MiB analog); the core's LS_COPY_MAX_CELLS still bounds a pathological
 * rect. */
#define COPY_BUDGET_BYTES (64u * 1024u * 1024u)
/* Per-pull chunk the copy worker frames. */
#define COPY_CHUNK_BYTES (1u << 16)

typedef struct
{
  AdwApplication *app;
  GtkWindow *window;
  /* Header-bar title: a custom widget (an AdwWindowTitle cannot hold a button)
   * — the document-name label over a subtitle ROW that carries the passive
   * status text PLUS a filtered-only (x) clear-filter button. Mirrors
   * AdwWindowTitle's centering + `.title`/`.subtitle` styling; the (x) is the
   * compact successor to the old full-width filter banner's Clear. */
  GtkWidget *title_box;   /* the title widget packed into the header bar */
  GtkLabel *title_name;   /* document name (.title) */
  GtkLabel *title_status; /* passive status line (.subtitle) */
  GtkButton
      *filter_clear_btn; /* (x) after the status; shown only when filtered
                          */
  AdwToolbarView *toolbar;
  GtkStack *stack; /* "launch" / "grid" / "error" */
  AdwStatusPage *error_page;

  /* Grid widgets. */
  GtkDrawingArea *area;
  GtkAdjustment *vadj;
  GtkAdjustment *hadj;
  GtkWidget *hscroll; /* auto-hidden when all columns fit the viewport */

  /* Open document + derived view state. */
  LsgDocument *doc;
  LsgWindow *win; /* current materialized window (owned) */
  guint32 n_cols;
  gboolean has_header;
  double *col_widths;    /* n_cols pixel widths */
  double char_advance;   /* monospaced per-char pixel advance */
  double line_h;         /* text line height (pixels) */
  double row_h;          /* uniform row height (pixels) */
  double header_h;       /* header strip height (pixels) */
  double gutter_w;       /* row-number gutter width (pixels) */
  guint64 row_estimate;  /* current row-count estimate (>= 1 when non-empty) */
  gboolean window_short; /* last materialize came back short */
  guint poll_id;         /* frontier poll source */

  /* Paint geometry cached by grid_materialize, consumed by grid_draw. */
  guint64 cur_top_row;
  double cur_pixel_off;
  LsgColumnWindow cur_colwin;
  LsgRowSpan cur_span;

  /* Header labels for the CURRENT column window only (lazy; O(visible
   * columns), never O(column_count) — mirrors the macOS per-column-window
   * header fetch). `hdr_labels[i]` is the label of absolute column `hdr_first
   * + i`. */
  char **hdr_labels;
  guint hdr_first;
  guint hdr_count;

  PangoFontDescription *font_desc;        /* data cells: small monospace */
  PangoFontDescription *header_font_desc; /* header row: bold sans-serif */
  PangoFontDescription *gutter_font_desc; /* row-number gutter: sans-serif */

  /* Network open. */
  LsgNetOpen *net;
  guint net_poll_id;
  char *pending_url;

  /* Find (slice 2): the pure view-model session + the popover widgets + the
   * current window's highlight mask (owned; refreshed each materialize). */
  LsgFindSession find;
  LsgSearchDir
      find_nav_direction;    /* direction of the outstanding navigation */
  gboolean find_wrap_issued; /* the wrap follow-up nav has been issued */
  LsgMatchFlags mask;        /* per-visible-cell match flags (OWNED) */
  GtkMenuButton *find_button;
  GtkPopover *find_popover;
  GtkEditable *find_entry;
  GtkLabel *find_status;
  LsgFindNotice
      find_sticky_notice; /* a briefly-lingering wrap notice for the label */
  guint find_notice_id;   /* timeout clearing the sticky notice */

  /* Find "Where" predicate builder: a `Text | Where` mode of the SAME find
   * popover (macOS parity) over the already-frozen predicate engine. The mode
   * lives in `find_stack`; the Where body holds the column picker, the
   * operator glyph dropdown, and the value field. All compose into
   * `find.draft` and go through the frozen `lsg_find_submit`. */
  GtkStack *find_stack;      /* "text" | "where" bodies */
  GtkDropDown *where_column; /* column picker (model built lazily per doc) */
  GtkDropDown *where_op;     /* operator glyph picker (= != < > <= >=) */
  GtkEditable *where_value;  /* the predicate value field */
  guint where_reject_id;     /* timeout clearing the value reject blink */
  gboolean
      where_columns_dirty; /* the column model needs a rebuild (new doc) */
  gboolean where_ui_guard; /* suppress re-run on programmatic model swaps */

  /* "Match case" checkbox: the ONE session-scoped case flag SHARED by both the
   * Text and Where modes (default OFF = ASCII case-insensitive). Read into
   * `find.draft.case_sensitive` by find_read_draft, so every find / filter
   * submit inherits it; toggling it live re-issues the active query. */
  GtkCheckButton *match_case;

  /* Jump-to-row (slice 3): the pure flow + the popover widgets. */
  LsgJumpFlow jump;
  GtkMenuButton *jump_button;
  GtkPopover *jump_popover;
  GtkEditable *jump_entry;
  GtkProgressBar *jump_progress;
  GtkButton *jump_cancel;
  GtkLabel *jump_status;
  guint jump_reject_id;         /* timeout clearing the rejection blink */
  gboolean jump_explicit_close; /* Escape set this before popdown -> the
                                 * closed handler cancels+restores the scan;
                                 * an incidental autohide (FALSE) keeps a
                                 * live deep/net scan alive so it lands. */

  /* Filter-to-matches (slice 4): the pure state + the toggle. The passive
   * "Filtered — N of M rows" status is shown in the header-bar subtitle
   * (update_title_subtitle), not a full-width banner. */
  LsgFilterState filter;
  GtkToggleButton *filter_toggle;
  gboolean filter_ui_guard; /* re-entrancy guard for programmatic toggle */

  /* Network doc (http_range): the core is DEMAND-DRIVEN — a bare ls_window_set
   * fetches nothing, so every viewport landing beyond the fetched frontier
   * (filter-apply, filter/deep scroll) must be driven through ls_jump_start.
   * `net_drive_active` guards an in-flight fetch-drive (async over the tick).
   */
  gboolean is_network;
  gboolean net_drive_active;

  /* Streaming copy (slice 5). Selection is two corners in VIEW row coords
   * (filtered-aware, like the window) + physical column indices; the mode
   * chooses cells / whole-rows / whole-columns. The copy runs on an OFF-MAIN
   * worker so the grid keeps scrolling; the header progress widget shows
   * determinate progress + a cancel while it streams. */
  int sel_mode; /* SEL_* */
  guint64 sel_a_row, sel_b_row;
  guint sel_a_col, sel_b_col;
  gboolean selecting; /* a drag is in progress */
  GtkButton *copy_button;

  GThread *copy_thread;
  struct _CopyOp
      *copy_op;       /* shared worker state (defined in the copy section) */
  guint copy_poll_id; /* main-thread progress/completion poll */

  /* Reusable header-bar progress widget (the author's unified title-bar progress:
   * determinate bar + inline cancel; other long ops can drive it later). */
  GtkWidget *hp_box;
  GtkProgressBar *hp_bar;
  GtkButton *hp_cancel;

  /* Settings + dialect override (this slice). */
  char *doc_path; /* current LOCAL path (OWNED); NULL for a network doc */
  LsgLocaleGlyphs glyphs; /* process-locale glyphs for the cell formatter */
  LsgColumnUserSettings *col_settings; /* n_cols; per-column user settings */
  ls_column_type_kind *col_kind; /* n_cols; cached effective kind (fmt) */
  ls_column_datetime_semantics
      *col_sem; /* n_cols; cached datetime semantics */

  AdwToastOverlay *toasts; /* header-change + column-reset toasts (F3 / F7) */

  /* Dialect quick-controls (header bar) — reflect + drive the ONE dialect
   * state (the effective report), the same state the Preferences "Parsing"
   * page drives, through the one lsg_dialect_compose funnel. */
  GtkToggleButton *header_toggle;
  GtkWidget *header_glyph; /* GtkDrawingArea: the macOS-style "H" glyph */
  GtkMenuButton *sep_button;
  GtkMenuButton *quote_button;
  GtkLabel *sep_glyph_label; /* the CHARACTER line of the stacked Sep button */
  GtkLabel
      *quote_glyph_label; /* the CHARACTER line of the stacked Quote button */
  gboolean
      dialect_ui_guard; /* re-entrancy guard for programmatic control sync */

  /* Preferences "Parsing" page rows (live only while the dialog is open;
   * NULL-reset when it closes). */
  AdwDialog *prefs;                /* current AdwPreferencesDialog, or NULL */
  GtkWidget *prefs_header_row;     /* AdwSwitchRow */
  GtkWidget *prefs_sep_row;        /* AdwComboRow */
  GtkWidget *prefs_sep_custom;     /* AdwEntryRow (revealed on "Custom…") */
  GtkWidget *prefs_quote_row;      /* AdwComboRow */
  GtkWidget *prefs_quote_custom;   /* AdwEntryRow */
  GtkWidget *prefs_enc_row;        /* AdwComboRow */
  GtkWidget *prefs_columns_group;  /* the Columns page's per-column group */
  GtkWidget *prefs_columns_search; /* AdwEntryRow shown in search-only mode */
  GtkWidget
      *prefs_columns_status;  /* a status/overflow/no-such-column label row */
  GtkWidget *prefs_infer_row; /* inference-progress row */
  guint prefs_infer_poll_id;  /* timer refreshing detected types (0 == none) */
  guint64
      prefs_infer_gen; /* last-seen metadata generation (change => refresh) */

  /* Pending dialect re-open state (captured before the re-open, applied in
   * open_document AFTER adoption, so the local + network re-open paths share
   * one post-open re-anchor + column replay/reset). */
  gboolean reopen_pending;
  gboolean reopen_header_change; /* the change was a header on/off */
  gboolean reopen_header_now;    /* the new header state (for the F3 toast) */
  guint64 reopen_top_view;       /* top DATA-row index before the re-open (F5:
                                  * a header toggle keeps this same index — no
                                  * ±1 shift; at top (0) this reveals the
                                  * former-header row as data row 0) */
  guint32 reopen_old_count;
  LsgColumnUserSettings *reopen_snapshot; /* OWNED; reopen_old_count entries */
  LsgColumnLabel *reopen_old_labels;      /* OWNED old identities; or NULL */
  guint reopen_n_old_labels;

  /* Env-gated timing instrumentation (LESSSHEET_GTK_TIMING). Entirely inert —
   * no output, no measurable cost — unless `timing` is set. */
  gboolean timing;
  gint64 t_start;               /* main() entry (monotonic µs) */
  gboolean ui_shown_reported;   /* one-shot: window first mapped */
  gint64 t_open_begin;          /* file-open begin (monotonic µs) */
  gboolean first_frame_pending; /* one-shot: awaiting the first painted grid
                                   frame */
} App;

/* Selection modes (slice 5): a cell rectangle, whole rows (gutter drag), or
 * whole columns (header drag). */
enum
{
  SEL_NONE = 0,
  SEL_CELLS,
  SEL_ROWS,
  SEL_COLS
};

/* ------------------------------------------------------------------------- */
/* Small helpers */
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
  return ((double)app->row_estimate * app->row_h)
         > LSG_GRID_MAX_ADJUSTMENT_UPPER;
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

/* Poll the core jump slot, fold it, and act on land/reject. Defined with the
 * jump helpers below; the poll loop calls it while a jump is scanning. */
static void jump_poll_fold (App *app);

/* Poll the core filter slot, fold it, and refresh the subtitle + grid. Defined
 * with the filter helpers below; the poll loop calls it while filtered. */
static void filter_poll_fold (App *app);

/* Network demand-drive: on an http_range doc, fetch the frontier to
 * `target_row` via ls_jump_start so a subsequent window materialize serves
 * real rows (a bare ls_window_set fetches nothing). Defined with the jump
 * helpers; called from the scroll handler, the filter-apply, and the poll
 * loop. */
static void net_drive_begin (App *app, guint64 target_row);
static void net_drive_poll (App *app);

/* Streaming copy (slice 5): start a copy of the current selection; stop+join
 * the worker before any document teardown (leaf-before-root). Defined in the
 * copy section; called from the key handlers and app_reset_document. */
static void do_copy (App *app);
static void copy_stop_and_join (App *app);
static void copy_update_affordance (App *app);
static gboolean selection_contains (App *app, guint64 row,
                                    guint col); /* grid_draw marquee */

/* Rebuild the grid's dynamic accessible DESCRIPTION from the pure builder;
 * called from the single materialize choke point. Defined in the accessibility
 * section below. */
static void grid_update_a11y_description (App *app);

/* Reusable header-bar progress (defined in the copy section); the network open
 * also drives it (unified long-op status). */
static void header_progress_show (App *app, const char *label);
static void header_progress_set (App *app, gdouble fraction);
static void header_progress_hide (App *app);

/* Filter helpers referenced from the earlier find section (the toggle lives in
 * the find popover); defined with the filter helpers below. */
static void on_filter_toggled (GtkToggleButton *toggle, gpointer data);
static void on_match_case_toggled (GtkCheckButton *button, gpointer data);
static void filter_update_toggle_sensitivity (App *app);

/* Sync the filter toggle + subtitle to state; called after opening a document
 * (the reset cleared any prior filter). Defined with the filter helpers. */
static void filter_sync_ui (App *app);

/* (Re)build the Where column picker's model lazily on first entry into Where
 * mode (never at open — keeps open O(viewport)). Defined with the find
 * helpers; capture_all_labels fetches every column's label (defined far below
 * with the re-open funnel). */
static void where_ensure_columns (App *app);
static LsgColumnLabel *capture_all_labels (App *app, guint *out_n);

/* Input-rejection blink (Adwaita .error red + reduce-motion-aware shake) and
 * its cancel, shared by the jump box + the Where value field. Defined with the
 * jump helpers; used by the find/filter reject paths + app_reset_document. */
static void entry_reject_feedback (GtkWidget *entry, guint *id_slot);
static void entry_clear_feedback (GtkWidget *entry, guint *id_slot);

/* Open the jump popover pre-filled with a digit typed on the grid (macOS
 * parity). Defined with the jump helpers; the grid key handler calls it. */
static void open_jump_with_digit (App *app, char digit);

/* Open the jump popover. Defined with the jump helpers; the app.jump action
 * (Ctrl+G / Ctrl+L) calls it. */
static void open_jump (App *app);

/* Settings + dialect override (this slice). Defined with the settings region
 * below `ensure_window`; called from `open_document` (which is the single
 * post-adoption choke point for BOTH the local and network re-open). */
static void dialect_sync_quick_controls (App *app); /* sync header/sep/quote */
static void
settings_reopen_apply (App *app); /* F5 re-anchor + F7 replay/reset */
static void column_cache_effective (App *app, guint32 col); /* fmt kind/sem */
static void reopen_state_clear (App *app); /* drop a pending dialect re-open */

/* ------------------------------------------------------------------------- */
/* View teardown */
/* ------------------------------------------------------------------------- */

static void
app_reset_document (App *app)
{
  /* LEAF BEFORE ROOT: stop + join any copy worker (and close its job) BEFORE
   * the document is closed below — a job must never outlive its document. */
  copy_stop_and_join (app);
  app->sel_mode = SEL_NONE;
  app->selecting = FALSE;
  copy_update_affordance (app);

  if (app->poll_id != 0)
    {
      g_source_remove (app->poll_id);
      app->poll_id = 0;
    }
  g_clear_pointer (&app->win, lsg_window_free);
  free_window_headers (app);
  g_clear_pointer (&app->col_widths, g_free);
  g_clear_pointer (&app->col_settings, g_free);
  g_clear_pointer (&app->col_kind, g_free);
  g_clear_pointer (&app->col_sem, g_free);
  g_clear_pointer (&app->doc, lsg_document_close);
  app->n_cols = 0;
  app->row_estimate = 1;
  app->window_short = FALSE;

  /* The old document's search state died with its core handle: clear the find
   * display + highlights (the DRAFT is retained, so re-running is one Enter).
   */
  if (app->find_notice_id != 0)
    {
      g_source_remove (app->find_notice_id);
      app->find_notice_id = 0;
    }
  app->find = lsg_find_invalidated (app->find);
  app->find_sticky_notice = LSG_FIND_NOTICE_NONE;
  app->find_wrap_issued = FALSE;
  find_clear_mask (app);
  /* Drop any lingering Where value reject blink; the column model is rebuilt
   * for the new document (dirty is re-armed in open_document). */
  entry_clear_feedback (GTK_WIDGET (app->where_value), &app->where_reject_id);

  /* The old document's jump slot died with its core handle: reset the flow. */
  if (app->jump_reject_id != 0)
    {
      g_source_remove (app->jump_reject_id);
      app->jump_reject_id = 0;
    }
  app->jump = lsg_jump_initial ();

  /* The old document's filter died with its core handle: back to identity. */
  app->filter = lsg_filter_initial ();

  app->is_network = FALSE;
  app->net_drive_active = FALSE;
}

/* ------------------------------------------------------------------------- */
/* Error / launch pages */
/* ------------------------------------------------------------------------- */

/* Set the header-bar subtitle text on the custom title widget, mirroring
 * AdwWindowTitle: an empty subtitle is HIDDEN so the name centers. The
 * filtered-only (x) button's visibility is a separate rule owned by
 * update_title_subtitle (it tracks filter.active, not this text). */
static void
title_set_status (App *app, const char *text)
{
  if (app->title_status == NULL)
    return;
  gtk_label_set_text (app->title_status, (text != NULL) ? text : "");
  gtk_widget_set_visible (GTK_WIDGET (app->title_status),
                          text != NULL && text[0] != '\0');
}

static void
show_error (App *app, const char *title, const char *description)
{
  adw_status_page_set_title (app->error_page, title);
  adw_status_page_set_description (app->error_page, description);
  gtk_stack_set_visible_child_name (app->stack, "error");
  title_set_status (app, "");
  if (app->filter_clear_btn != NULL)
    gtk_widget_set_visible (GTK_WIDGET (app->filter_clear_btn), FALSE);
}

static const char *
open_error_text (LsgOpenError e)
{
  switch (e)
    {
    case LSG_OPEN_NOT_FOUND:
      return "The file could not be found.";
    case LSG_OPEN_PERMISSION_DENIED:
      return "Permission to read the file was denied.";
    case LSG_OPEN_IO:
      return "The file could not be read.";
    case LSG_OPEN_INVALID_ARGUMENT:
      return "The parse options were invalid.";
    default:
      return "The file could not be opened.";
    }
}

/* ------------------------------------------------------------------------- */
/* Grid geometry glue */
/* ------------------------------------------------------------------------- */

static void
grid_update_gutter (App *app)
{
  guint d = digits_of (app->row_estimate);
  if (d < 4)
    d = 4;
  app->gutter_w = app->char_advance * (double)(d + 1) + 16.0;
}

static void
grid_update_vadjustment (App *app)
{
  double content_h = lsg_grid_content_height (app->row_estimate, app->row_h);
  int h = gtk_widget_get_height (GTK_WIDGET (app->area));
  double page = (double)h - app->header_h;
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
  double content = 0.0;
  for (guint32 i = 0; i < app->n_cols; i++)
    content += (app->col_widths[i] > 0.0) ? app->col_widths[i] : 0.0;
  int w = gtk_widget_get_width (GTK_WIDGET (app->area));
  double page = (double)w - app->gutter_w;
  if (page < 0.0)
    page = 0.0;

  /* upper == actual content width (clamped to at least page for a sane empty
   * value range); the scrollbar is HIDDEN when everything fits, so no dead,
   * non-interactive horizontal scrollbar shows. */
  gboolean overflow = content > page + 0.5;
  gtk_adjustment_set_lower (app->hadj, 0.0);
  gtk_adjustment_set_upper (app->hadj, overflow ? content : page);
  gtk_adjustment_set_page_size (app->hadj, page);
  gtk_adjustment_set_step_increment (app->hadj, app->char_advance * 4.0);
  gtk_adjustment_set_page_increment (app->hadj, page);

  if (app->hscroll != NULL)
    gtk_widget_set_visible (app->hscroll, overflow);
}

/* Fetch header labels for the current column window only — O(visible columns),
 * never O(column_count). `first`/`count` are the materialized column window.
 */
static void
grid_window_headers (App *app, guint first, guint count)
{
  free_window_headers (app);
  if (count == 0)
    return;
  /* With a header, the column labels are its cells; with NO header they are
   * the generic spreadsheet letters A, B, C, … (macOS parity —
   * GenericColumnName), so the sticky header row is never blank. Still
   * O(visible columns). */
  app->hdr_labels = g_new0 (char *, count);
  for (guint i = 0; i < count; i++)
    app->hdr_labels[i]
        = app->has_header ? lsg_document_header_cell_dup (app->doc, first + i)
                          : lsg_column_generic_name (first + i);
  app->hdr_first = first;
  app->hdr_count = count;
}

/*
 * Auto-fit: monotonically GROW the visible columns' established widths from
 * the cells actually materialized this window (+ their header labels), via the
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

  guint nfit = 0; /* only the non-manual columns are auto-fit candidates */
  for (guint32 ci = 0; ci < gc; ci++)
    {
      guint32 abscol = colwin.first + ci;
      /* A user-set manual width is authoritative — never let the monotone
       * auto-fit grow re-widen it (Finding 3). A HIDDEN column is pinned to
       * width 0 (its hide mechanism), so never grow it either. */
      if (app->col_settings != NULL && abscol < app->n_cols
          && (app->col_settings[abscol].has_manual_width
              || app->col_settings[abscol].hidden))
        continue;
      guint cnt = 0;
      for (guint32 r = 0; r < gr; r++)
        buf[cnt++] = lsg_window_cell (win, r, ci);
      const char *hdr = (app->hdr_labels != NULL && ci < app->hdr_count)
                            ? app->hdr_labels[ci]
                            : NULL;
      double wpx = lsg_grid_column_width_estimate (
          buf, cnt, hdr, app->char_advance, app->char_advance * 2.0 + 12.0);
      if (wpx > max_w)
        wpx = max_w;
      cand[nfit] = wpx;
      cols[nfit] = abscol;
      nfit++;
    }

  gdouble *out = g_new (gdouble, app->n_cols);
  lsg_grid_grow_widths (app->col_widths, app->n_cols, cols, cand, nfit, out);
  gboolean changed
      = memcmp (out, app->col_widths, (gsize)app->n_cols * sizeof (gdouble))
        != 0;
  g_free (app->col_widths);
  app->col_widths = out;

  g_free (cols);
  g_free (cand);
  g_free (buf);

  if (changed)
    grid_update_hadjustment (
        app); /* only grows the upper; never re-materializes */
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

  double cell_area_w = (double)w - app->gutter_w;
  double cell_area_h = (double)h - app->header_h;
  if (cell_area_w < 0.0)
    cell_area_w = 0.0;
  if (cell_area_h < 0.0)
    cell_area_h = 0.0;

  double vval = gtk_adjustment_get_value (app->vadj);
  double vupper = gtk_adjustment_get_upper (app->vadj);
  guint64 top = lsg_grid_top_row_for_offset (vval, vupper, app->row_estimate,
                                             app->row_h);

  /* Sub-row pixel offset only makes sense in direct (unsaturated) mode; in the
   * filler regime one scrollbar pixel spans many rows, so snap to whole rows.
   */
  double pixel_off
      = is_saturated (app) ? 0.0 : (vval - (double)top * app->row_h);
  if (pixel_off < 0.0)
    pixel_off = 0.0;

  /* Feed the frozen row-window math a synthetic pixel offset for the mapped
   * top row, so the same function serves both the direct and filler regimes.
   */
  double scroll_y_synth = (double)top * app->row_h;
  LsgRowSpan span
      = lsg_grid_row_window (scroll_y_synth, cell_area_h, app->row_h,
                             GRID_OVERSCAN, app->row_estimate);

  double hval = gtk_adjustment_get_value (app->hadj);
  LsgColumnWindow colwin = lsg_grid_column_window (
      app->col_widths, app->n_cols, hval, cell_area_w, 1);

  LsgWindow *nw = lsg_document_set_window (
      app->doc, span.first_row, span.row_count, colwin.first, colwin.count);
  g_clear_pointer (&app->win, lsg_window_free);
  app->win = nw;
  app->cur_top_row = top;
  app->cur_pixel_off = pixel_off;
  app->cur_colwin = colwin;
  app->cur_span = span;

  /* Lazily fetch this window's header labels, then auto-fit the visible
   * columns (both O(visible), using the actual materialized window). */
  grid_window_headers (app, colwin.first, colwin.count);
  grid_autofit_widths (app, colwin, nw);

  /* Refresh the per-visible-cell find highlight mask for THIS window
   * (O(viewport) — only the visible column range is evaluated by the core).
   * Empty when no search is active. Fetched right after set_window (window
   * lane). */
  find_clear_mask (app);
  if (app->find.display.active)
    app->mask = lsg_document_window_match_flags (app->doc, colwin.first,
                                                 colwin.count);

  /* Short => rows beyond the frontier are not yet servable; re-issue on poll.
   */
  app->window_short = (lsg_window_row_count (nw) < span.row_count);

  /* Refresh the grid's accessible description (position/extent/filter state)
   * off the freshly-materialized window. O(1) string build on a discrete state
   * change (scroll/resize/open/filter), never per frame / per scanned byte;
   * set as a property, never announced (FR3). */
  grid_update_a11y_description (app);
}

/* The header-bar subtitle is the ONE passive-status line (single source of
 * truth): the "Filtered — N of M rows" status when a filter owns the view,
 * otherwise the document's row count. Everything is re-derived from `app`
 * state, so every caller (open, poll tick, filter apply/clear/poll) funnels
 * through here. Replaces the old full-width filter AdwBanner. */
static void
update_title_subtitle (App *app)
{
  if (app->title_status == NULL || app->doc == NULL)
    return;

  char *sub;
  LsgFilterBanner b;
  if (app->filter.active && lsg_filter_banner (app->filter, &b))
    {
      const char *tilde = b.document_rows_estimated ? "~" : "";
      if (b.is_empty_result)
        sub = g_strdup ("Filtered — no matching rows");
      else if (b.has_progress)
        sub = g_strdup_printf ("Filtered — %" G_GUINT64_FORMAT
                               " of %s%" G_GUINT64_FORMAT " rows · %d%%",
                               b.matching, tilde, b.document_rows,
                               (int)(b.progress * 100.0));
      else
        sub = g_strdup_printf ("Filtered — %" G_GUINT64_FORMAT
                               " of %s%" G_GUINT64_FORMAT " rows",
                               b.matching, tilde, b.document_rows);
    }
  else
    {
      LsgRowCount rc = lsg_document_row_count (app->doc);
      if (rc.exact)
        sub = g_strdup_printf ("%" G_GUINT64_FORMAT " rows", rc.count);
      else
        {
          LsgScanProgress prog = lsg_document_index_progress (app->doc);
          double frac = lsg_scan_progress_fraction (prog);
          sub = g_strdup_printf ("~%" G_GUINT64_FORMAT " rows · indexing %d%%",
                                 rc.count, (int)(frac * 100.0));
        }
    }

  title_set_status (app, sub);
  g_free (sub);
  /* The (x) clear-filter button lives right after the subtitle and shows ONLY
   * while a filter owns the view (no (x) on the plain row-count). */
  if (app->filter_clear_btn != NULL)
    gtk_widget_set_visible (GTK_WIDGET (app->filter_clear_btn),
                            app->filter.active);
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

  update_title_subtitle (app);

  /* Keep polling (and folding search snapshots) while a find is active, so its
   * live count grows, its landing scrolls into view, and the highlight mask
   * tracks the scan — even after the index poll would otherwise stop. */
  gboolean keep = d.continue_polling;
  if (app->find.display.active)
    {
      find_poll_fold (app);
      keep = TRUE;
    }

  /* Keep ticking while a jump scans (ORed at the widget with the frozen
   * window-poll decision — lsg_window_poll.h is untouched). */
  if (app->jump.kind == LSG_JUMP_FLOW_SCANNING)
    {
      jump_poll_fold (app);
      if (app->jump.kind == LSG_JUMP_FLOW_SCANNING)
        keep = TRUE;
    }

  /* Keep ticking while a filter-scan is not yet final (the "N of M" subtitle
   * grows and the grid materializes the widening filtered view). Under
   * LS_INDEX_AUTO a CANCELLED scan (a jump/find took the slot) auto-resumes to
   * DONE without caller input, so `!total_exact` is more robust than `phase ==
   * SCANNING`. */
  if (app->filter.active)
    {
      filter_poll_fold (app);
      if (!app->filter.snapshot.total_exact)
        keep = TRUE;
    }

  /* Keep ticking while a network fetch-drive is in flight (net-park). */
  if (app->net_drive_active)
    {
      net_drive_poll (app);
      if (app->net_drive_active)
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
/* Drawing */
/* ------------------------------------------------------------------------- */

/* Set `layout`'s text and ellipsize width, then paint it left-aligned and
 * vertically centered in the row at (x, y). */
static void
draw_text (cairo_t *cr, PangoLayout *layout, const char *text, double x,
           double y, double avail_w, double row_h, double line_h)
{
  if (avail_w < 1.0)
    return;
  pango_layout_set_text (layout, (text != NULL) ? text : "", -1);
  pango_layout_set_width (layout, (int)(avail_w * PANGO_SCALE));
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
      g_printerr (
          "[timing] window-fill (open begin -> first frame): %.1f ms\n",
          (double)dt / 1000.0);
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
      GdkRGBA *a = adw_style_manager_get_accent_color_rgba (
          adw_style_manager_get_default ());
      if (a != NULL)
        {
          accent = *a;
          gdk_rgba_free (a);
          have_accent = TRUE;
        }
    }

  /* --- cells (clipped to the scrolling body region) --- */
  cairo_save (cr);
  cairo_rectangle (cr, gutter, header_h, (double)width - gutter,
                   (double)height - header_h);
  cairo_clip (cr);
  gdk_cairo_set_source_rgba (cr, &fg);

  /* Keyboard cursor: the active (`_b_`) corner of the selection rectangle gets
   * a theme-accent focus outline (in addition to the muted marquee). Captured
   * during the cell loop, stroked after it. */
  gboolean have_cursor = FALSE;
  double cur_x = 0.0, cur_y = 0.0, cur_w = 0.0;

  for (guint32 ri = 0; ri < got_rows; ri++)
    {
      guint64 view_row = span.first_row + ri;
      double y
          = header_h + (double)((gint64)(view_row - top)) * row_h - pixel_off;
      if (y + row_h < header_h || y > (double)height)
        continue;

      double x = gutter + (cw.first_x - hval);
      for (guint32 ci = 0; ci < got_cols; ci++)
        {
          guint col = cw.first + ci;
          double colw = (col < app->n_cols && app->col_widths[col] > 0.0)
                            ? app->col_widths[col]
                            : 0.0;

          /* Remember the active-corner cell for the accent focus outline. */
          if (app->sel_mode != SEL_NONE && view_row == app->sel_b_row
              && col == app->sel_b_col)
            {
              have_cursor = TRUE;
              cur_x = x;
              cur_y = y;
              cur_w = colw;
            }

          /* Selection marquee: a MUTED-GRAY fill (the macOS NSColor.systemGray
           * equivalent, theme-derived from fg so it reads in light + dark),
           * drawn BEHIND the accent find highlight (which stays accent). */
          if (selection_contains (app, view_row, col))
            {
              GdkRGBA sel = fg;
              sel.alpha = 0.20;
              gdk_cairo_set_source_rgba (cr, &sel);
              cairo_rectangle (cr, x, y, colw, row_h);
              cairo_fill (cr);
              gdk_cairo_set_source_rgba (cr, &fg);
            }

          /* Highlight a matching cell from the core's mask (accent tint); the
           * current match cell gets a stronger tint. */
          if (have_accent && app->mask.flags != NULL && ri < app->mask.rows
              && ci < app->mask.cols
              && app->mask.flags[(gsize)ri * app->mask.cols + ci])
            {
              gboolean is_current
                  = app->find.display.has_current
                    && app->find.display.current.row == view_row
                    && app->find.display.current.column == col;
              GdkRGBA h = accent;
              h.alpha = is_current ? 0.55 : 0.28;
              gdk_cairo_set_source_rgba (cr, &h);
              cairo_rectangle (cr, x, y, colw, row_h);
              cairo_fill (cr);
              gdk_cairo_set_source_rgba (cr, &fg); /* restore for the text */
            }

          const char *raw = lsg_window_cell (app->win, ri, ci);
          /* Display formatting (F14): AUTO / no-option columns paint the raw
           * spelling with NO allocation (the common case); a configured column
           * runs the type+options dispatcher (find/filter/copy still use raw —
           * the ABI rule). */
          if (col < app->n_cols && app->col_settings != NULL
              && !lsg_column_format_options_is_auto (
                  app->col_settings[col].format))
            {
              LsgDisplay disp = lsg_format_cell (
                  raw, app->col_kind[col], app->col_sem[col],
                  app->col_settings[col].format, app->glyphs);
              draw_text (cr, layout, disp.text, x + pad, y, colw - 2.0 * pad,
                         row_h, line_h);
              lsg_display_clear (&disp);
            }
          else
            {
              draw_text (cr, layout, raw, x + pad, y, colw - 2.0 * pad, row_h,
                         line_h);
            }
          x += colw;
        }
    }

  /* Cell-area horizontal hairlines. */
  gdk_cairo_set_source_rgba (cr, &line);
  cairo_set_line_width (cr, 1.0);
  for (guint32 ri = 0; ri < got_rows; ri++)
    {
      guint64 view_row = span.first_row + ri;
      double y = header_h + (double)((gint64)(view_row - top + 1)) * row_h
                 - pixel_off;
      cairo_move_to (cr, gutter, y + 0.5);
      cairo_line_to (cr, (double)width, y + 0.5);
    }
  cairo_stroke (cr);

  /* Accent focus outline on the active cell (keyboard cursor), resolved from
   * the GNOME theme accent — NO literal color constant (G6/G7), tracks
   * light/dark + live accent changes. Drawn last so it sits atop the marquee,
   * any find highlight, and the cell text. */
  if (have_cursor && cur_w > 0.0)
    {
      GdkRGBA *ac = adw_style_manager_get_accent_color_rgba (
          adw_style_manager_get_default ());
      GdkRGBA outline = (ac != NULL) ? *ac : fg;
      if (ac != NULL)
        gdk_rgba_free (ac);
      gdk_cairo_set_source_rgba (cr, &outline);
      cairo_set_line_width (cr, 2.0);
      cairo_rectangle (cr, cur_x + 1.0, cur_y + 1.0, cur_w - 2.0, row_h - 2.0);
      cairo_stroke (cr);
      gdk_cairo_set_source_rgba (cr, &fg);
    }
  cairo_restore (cr);

  /* --- row-number gutter (sticky left; scrolls vertically only) --- */
  cairo_save (cr);
  cairo_rectangle (cr, 0.0, header_h, gutter, (double)height - header_h);
  cairo_clip (cr);
  gdk_cairo_set_source_rgba (cr, &tint);
  cairo_rectangle (cr, 0.0, header_h, gutter, (double)height - header_h);
  cairo_fill (cr);
  gdk_cairo_set_source_rgba (cr, &fg);
  pango_layout_set_font_description (
      layout, app->gutter_font_desc); /* sans row numbers */
  for (guint32 ri = 0; ri < got_rows; ri++)
    {
      guint64 view_row = span.first_row + ri;
      double y
          = header_h + (double)((gint64)(view_row - top)) * row_h - pixel_off;
      if (y + row_h < header_h || y > (double)height)
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
  pango_layout_set_font_description (layout,
                                     app->font_desc); /* back to data cells */
  cairo_restore (cr);

  /* --- column header (sticky top; scrolls horizontally only) --- */
  cairo_save (cr);
  cairo_rectangle (cr, gutter, 0.0, (double)width - gutter, header_h);
  cairo_clip (cr);
  gdk_cairo_set_source_rgba (cr, &tint);
  cairo_rectangle (cr, gutter, 0.0, (double)width - gutter, header_h);
  cairo_fill (cr);
  if (app->hdr_labels != NULL)
    {
      gdk_cairo_set_source_rgba (cr, &fg);
      pango_layout_set_font_description (layout,
                                         app->header_font_desc); /* bold */
      double x = gutter + (cw.first_x - hval);
      for (guint32 ci = 0; ci < cw.count; ci++)
        {
          guint col = cw.first + ci;
          if (col >= app->n_cols)
            break;
          double colw
              = (app->col_widths[col] > 0.0) ? app->col_widths[col] : 0.0;
          const char *label = (ci < app->hdr_count) ? app->hdr_labels[ci] : "";
          draw_text (cr, layout, label, x + pad, 0.0, colw - 2.0 * pad,
                     header_h, line_h);
          x += colw;
        }
      pango_layout_set_font_description (layout,
                                         app->font_desc); /* back to cells */
    }
  cairo_restore (cr);

  /* --- corner + separating hairlines --- */
  gdk_cairo_set_source_rgba (cr, &tint);
  cairo_rectangle (cr, 0.0, 0.0, gutter, header_h);
  cairo_fill (cr);
  gdk_cairo_set_source_rgba (cr, &line);
  cairo_set_line_width (cr, 1.0);
  cairo_move_to (cr, 0.0, header_h + 0.5);
  cairo_line_to (cr, (double)width, header_h + 0.5);
  cairo_move_to (cr, gutter + 0.5, 0.0);
  cairo_line_to (cr, gutter + 0.5, (double)height);
  cairo_stroke (cr);

  g_object_unref (layout);
}

/* ------------------------------------------------------------------------- */
/* Open a document into the grid */
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

  app->char_advance = (double)char_w / PANGO_SCALE;
  if (app->char_advance < 1.0)
    app->char_advance = 8.0;
  app->line_h = (double)(ascent + descent) / PANGO_SCALE;
  if (app->line_h < 1.0)
    app->line_h = 16.0;
  app->row_h = app->line_h + 10.0;
  app->header_h = app->line_h + 12.0;
}

static void
sample_column_widths (App *app)
{
  guint32 sample_cols
      = (app->n_cols < WIDTH_SAMPLE_COLS) ? app->n_cols : WIDTH_SAMPLE_COLS;
  double default_w = app->char_advance * 12.0 + 12.0;
  for (guint32 c = 0; c < app->n_cols; c++)
    app->col_widths[c] = default_w;
  if (sample_cols == 0)
    return;

  LsgWindow *sw = lsg_document_set_window (app->doc, 0, WIDTH_SAMPLE_ROWS, 0,
                                           sample_cols);
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
      char *hdr = app->has_header ? lsg_document_header_cell_dup (app->doc, c)
                                  : NULL;
      double wpx = lsg_grid_column_width_estimate (
          cells, cnt, hdr, app->char_advance, app->char_advance * 2.0 + 12.0);
      g_free (hdr);
      if (wpx < min_w)
        wpx = min_w;
      if (wpx > max_w)
        wpx = max_w;
      app->col_widths[c] = wpx;
    }
  lsg_window_free (sw);
}

/* Re-sample ONE column's auto width from the head window (the "Reset to Auto"
 * path — a manual width must be able to SHRINK back, so we recompute rather
 * than leave the widened value). O(head rows) for the single column. */
static void
sample_one_column_width (App *app, guint32 col)
{
  if (app->doc == NULL || app->col_widths == NULL || col >= app->n_cols)
    return;
  double wpx = app->char_advance * 12.0 + 12.0; /* default */
  double min_w = app->char_advance * 3.0 + 12.0;
  double max_w = app->char_advance * 60.0 + 12.0;

  LsgWindow *sw
      = lsg_document_set_window (app->doc, 0, WIDTH_SAMPLE_ROWS, col, 1);
  guint32 got = lsg_window_row_count (sw);
  if (lsg_window_col_count (sw) > 0)
    {
      const char *cells[WIDTH_SAMPLE_ROWS];
      guint cnt = 0;
      for (guint32 r = 0; r < got && cnt < WIDTH_SAMPLE_ROWS; r++)
        cells[cnt++] = lsg_window_cell (sw, r, 0);
      char *hdr = app->has_header
                      ? lsg_document_header_cell_dup (app->doc, col)
                      : NULL;
      wpx = lsg_grid_column_width_estimate (cells, cnt, hdr, app->char_advance,
                                            app->char_advance * 2.0 + 12.0);
      g_free (hdr);
      if (wpx < min_w)
        wpx = min_w;
      if (wpx > max_w)
        wpx = max_w;
    }
  lsg_window_free (sw);
  app->col_widths[col] = wpx;
}

static void
open_document (App *app, LsgDocument *doc, const char *title,
               gboolean is_network)
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
  app->is_network = is_network; /* gates the demand-driven fetch (net-park) */

  app->n_cols = lsg_document_column_count (doc);
  app->has_header = lsg_document_has_header (doc);
  app->where_columns_dirty
      = TRUE; /* the Where column picker needs a rebuild */
  /* Header labels are NOT prefetched for every column (that would be
   * O(column_count) window-lane calls + retained strings, breaking the
   * wide-doc viewport-only NFR). They are fetched lazily for the visible
   * column window in grid_materialize, exactly as the cells are. */
  guint32 nc_alloc = (app->n_cols > 0) ? app->n_cols : 1;
  app->col_widths = g_new0 (double, nc_alloc);
  /* Per-column user settings + cached effective type for the cell formatter.
   * All-zero == all-Auto (raw spellings, no inference) — the O(viewport) open
   * does NO column work (N1). col_kind zero == LS_COLUMN_TYPE_UNKNOWN -> raw.
   */
  app->col_settings = g_new0 (LsgColumnUserSettings, nc_alloc);
  app->col_kind = g_new0 (ls_column_type_kind, nc_alloc);
  app->col_sem = g_new0 (ls_column_datetime_semantics, nc_alloc);
  app->glyphs = lsg_locale_glyphs_current ();

  LsgRowCount rc = lsg_document_row_count (doc);
  app->row_estimate = (rc.count > 0) ? rc.count : 1;

  measure_font (app);
  sample_column_widths (app);
  grid_update_gutter (app);
  grid_update_vadjustment (app);
  grid_update_hadjustment (app);
  gtk_adjustment_set_value (app->vadj, 0.0);
  gtk_adjustment_set_value (app->hadj, 0.0);

  if (app->title_name != NULL)
    gtk_label_set_text (app->title_name,
                        (title != NULL) ? title : "less-sheet");
  update_title_subtitle (app);

  gtk_stack_set_visible_child_name (app->stack, "grid");
  grid_materialize (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
  filter_sync_ui (app); /* the reset cleared any prior filter (F6) */

  /* Reflect the (possibly re-sniffed) dialect into the header-bar quick
   * controls + any open Parsing page — the ONE state, three affordances. */
  dialect_sync_quick_controls (app);

  /* A dialect re-open applies its viewport re-anchor (F5) + column-settings
   * replay-or-reset (F7) + toasts here — the shared post-adoption step for
   * both the local re-open and the async network re-open (F8). */
  if (app->reopen_pending)
    settings_reopen_apply (app);

  if (app->poll_id == 0)
    app->poll_id = g_timeout_add (POLL_INTERVAL_MS, grid_poll_tick, app);
}

/* ------------------------------------------------------------------------- */
/* Open local file */
/* ------------------------------------------------------------------------- */

/* Open one local GFile into the grid (or an error page). Does NOT take
 * ownership of `file`. Shared by the file dialog, drag-open (future), and the
 * command-line "open" path. */
static void
open_file (App *app, GFile *file)
{
  /* A fresh user open is never a dialect re-open — drop any pending capture so
   * a prior failed re-open can't fire a stale settings_reopen_apply here. */
  reopen_state_clear (app);

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
      /* Remember the LOCAL path so a dialect change can re-open it (F1). A
       * fresh user open (not a dialect re-open) clears any pending re-open
       * state. */
      g_clear_pointer (&app->doc_path, g_free);
      app->doc_path = g_strdup (path);
      open_document (app, doc, base, FALSE); /* local file */
    }

  g_free (path);
  g_free (base);
}

static void
on_file_opened (GObject *source, GAsyncResult *res, gpointer data)
{
  App *app = data;
  GError *error = NULL;
  GFile *file
      = gtk_file_dialog_open_finish (GTK_FILE_DIALOG (source), res, &error);
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
  (void)button;
  App *app = data;
  GtkFileDialog *dialog = gtk_file_dialog_new ();
  gtk_file_dialog_set_title (dialog, "Open Delimited File");
  gtk_file_dialog_open (dialog, app->window, NULL, on_file_opened, app);
  g_object_unref (dialog);
}

/* ------------------------------------------------------------------------- */
/* Open URL (network) */
/* ------------------------------------------------------------------------- */

/* Drive the reusable header-bar progress from a network-open poll (the unified
 * long-op status location — same widget copy uses). Pulse while connecting /
 * before a byte-fraction is known; determinate "Fetching N%" once head bytes
 * arrive. This SUBSUMES the old AdwBanner "Fetching …" (one indicator, not
 * two). */
static void
update_net_progress (App *app, const LsgNetProgress *p)
{
  if (app->hp_bar == NULL)
    return;
  char *text;
  if (p->has_fraction)
    {
      header_progress_set (app, p->fraction); /* determinate */
      text = g_strdup_printf ("Fetching %d%%", (int)(p->fraction * 100.0));
    }
  else
    {
      header_progress_set (app, -1.0); /* indeterminate pulse */
      text = (p->bytes_fetched > 0)
                 ? g_strdup_printf ("Fetching %" G_GUINT64_FORMAT " bytes",
                                    p->bytes_fetched)
                 : g_strdup ("Connecting…");
    }
  gtk_progress_bar_set_show_text (app->hp_bar, TRUE);
  gtk_progress_bar_set_text (app->hp_bar, text);
  g_free (text);
}

static const char *
net_error_text (LsgNetError e)
{
  switch (e)
    {
    case LSG_NET_ERROR_INVALID_ARGUMENT:
      return "The URL or scheme is not valid (use http:// or https://).";
    case LSG_NET_ERROR_UNREACHABLE:
      return "The host could not be reached.";
    case LSG_NET_ERROR_TIMEOUT:
      return "The connection timed out.";
    case LSG_NET_ERROR_HTTP_STATUS:
      return "The server returned an error status.";
    case LSG_NET_ERROR_TOO_MANY_REDIRECTS:
      return "The redirect chain was too long.";
    case LSG_NET_ERROR_IO:
      return "A local spool-file error occurred.";
    case LSG_NET_ERROR_CANCELLED:
      return "The open was cancelled.";
    default:
      return "The network document could not be opened.";
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

  if (!lsg_net_state_is_terminal (p.state))
    {
      update_net_progress (app, &p); /* moving header-bar feedback */
      return G_SOURCE_CONTINUE;
    }

  header_progress_hide (app); /* clears as rows paint / on error */
  if (p.state == LSG_NET_DONE)
    {
      LsgDocument *doc = lsg_net_open_adopt_document (app->net);
      lsg_net_open_release (app->net);
      app->net = NULL;
      if (doc != NULL)
        open_document (app, doc,
                       (app->pending_url != NULL) ? app->pending_url : "URL",
                       TRUE);
      else
        {
          /* Adopt failed: a pending dialect re-open must not fire stale. */
          reopen_state_clear (app);
          show_error (app, "Could not open URL",
                      "The network document could not be adopted.");
        }
    }
  else
    {
      /* FAILED / CANCELLED: no adoption, so drop any pending dialect re-open
       * capture (else the next fresh open runs a stale settings_reopen_apply).
       */
      reopen_state_clear (app);
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
on_url_response (AdwAlertDialog *dialog, const char *response, gpointer data)
{
  App *app = data;
  if (g_strcmp0 (response, "open") != 0)
    return;

  GtkEditable *entry = g_object_get_data (G_OBJECT (dialog), "url-entry");
  const char *url = (entry != NULL) ? gtk_editable_get_text (entry) : NULL;
  if (url == NULL || url[0] == '\0')
    return;

  /* A fresh URL open is never a dialect re-open — clear any pending capture.
   */
  reopen_state_clear (app);

  g_clear_pointer (&app->pending_url, g_free);
  app->pending_url = g_strdup (url);
  g_clear_pointer (&app->doc_path, g_free); /* network doc: no local path */

  /* A URL open replaces the current doc, so stop any copy of the OLD doc NOW —
   * before the net open goes in flight and takes over the shared header
   * progress. Without this, the old doc + its copy stay alive until the open
   * reaches DONE (open_document→app_reset_document→copy_stop_and_join), so the
   * two ops would overlap and fight over the one progress widget / ✕. Stopping
   * here (plus the app->net gate in do_copy) makes "no copy while a net open
   * is in flight" a hard invariant — same pattern as do_apply_filter. */
  copy_stop_and_join (app);

  if (app->net != NULL)
    {
      lsg_net_open_cancel (app->net);
      lsg_net_open_release (app->net);
      app->net = NULL;
    }
  app->net = lsg_net_open_start (url, NULL);
  if (app->net == NULL)
    {
      show_error (app, "Could not open URL",
                  "The open job could not be started.");
      return;
    }

  /* Unified header-bar progress (pulse until a byte-fraction is known); the ✕
   * cancels the open (routed in on_hp_cancel_clicked). */
  header_progress_show (app, "Connecting…");
  header_progress_set (app, -1.0);
  if (app->net_poll_id == 0)
    app->net_poll_id = g_timeout_add (POLL_INTERVAL_MS, net_poll_tick, app);
}

static void
action_open_url (GtkButton *button, gpointer data)
{
  (void)button;
  App *app = data;

  AdwDialog *dialog = adw_alert_dialog_new ("Open URL", NULL);
  adw_alert_dialog_set_body (
      ADW_ALERT_DIALOG (dialog),
      "Enter an http:// or https:// address of a .csv or .csv.gz file.");

  GtkWidget *entry = gtk_entry_new ();
  gtk_entry_set_input_purpose (GTK_ENTRY (entry), GTK_INPUT_PURPOSE_URL);
  gtk_entry_set_placeholder_text (GTK_ENTRY (entry),
                                  "https://example.com/data.csv");
  adw_alert_dialog_set_extra_child (ADW_ALERT_DIALOG (dialog), entry);
  g_object_set_data (G_OBJECT (dialog), "url-entry", entry);

  adw_alert_dialog_add_response (ADW_ALERT_DIALOG (dialog), "cancel",
                                 "Cancel");
  adw_alert_dialog_add_response (ADW_ALERT_DIALOG (dialog), "open", "Open");
  adw_alert_dialog_set_response_appearance (ADW_ALERT_DIALOG (dialog), "open",
                                            ADW_RESPONSE_SUGGESTED);
  adw_alert_dialog_set_default_response (ADW_ALERT_DIALOG (dialog), "open");
  adw_alert_dialog_set_close_response (ADW_ALERT_DIALOG (dialog), "cancel");

  g_signal_connect (dialog, "response", G_CALLBACK (on_url_response), app);
  adw_dialog_present (dialog, GTK_WIDGET (app->window));
}

/* ------------------------------------------------------------------------- */
/* Scroll / keyboard input on the grid */
/* ------------------------------------------------------------------------- */

static gboolean
on_scroll (GtkEventControllerScroll *ctrl, double dx, double dy, gpointer data)
{
  App *app = data;
  if (app->doc == NULL)
    return GDK_EVENT_PROPAGATE;

  /* Shift+wheel scrolls HORIZONTALLY — the GNOME/GTK convention, and the only
   * way to pan a wide document with a plain mouse. A wheel reports dy ONLY
   * (dx arrives from trackpads and tilt wheels, hence BOTH_AXES), so without
   * consulting the modifier the Shift was simply ignored and Shift+wheel
   * scrolled vertically like a bare wheel. Redirect dy INTO dx rather than
   * adding a second write path, so the step sizes below stay the one place
   * either axis is tuned. Guarded on `dx == 0.0` so a trackpad already
   * reporting a real horizontal delta is left alone. */
  GdkModifierType state = gtk_event_controller_get_current_event_state (
      GTK_EVENT_CONTROLLER (ctrl));
  if ((state & GDK_SHIFT_MASK) != 0 && dy != 0.0 && dx == 0.0)
    {
      dx = dy;
      dy = 0.0;
    }

  if (dy != 0.0)
    gtk_adjustment_set_value (app->vadj, gtk_adjustment_get_value (app->vadj)
                                             + dy * app->row_h * 3.0);
  if (dx != 0.0)
    gtk_adjustment_set_value (app->hadj, gtk_adjustment_get_value (app->hadj)
                                             + dx * app->char_advance * 6.0);
  return GDK_EVENT_STOP;
}

/* ------------------------------------------------------------------------- */
/* Accessibility (gtk-a11y): keyboard cell cursor + live announcements over */
/* the pure lsg_a11y module. The reducer / string builders / accel table are */
/* in lsg_a11y.c (gate-tested); this is the display/AT glue (human GNOME/Orca
 */
/* pass). */
/* ------------------------------------------------------------------------- */

/* The current displayed view's row count — the ONE resolver every a11y
 * consumer reads (the cursor-reducer extent, the grid description,
 * select-all). Filtered-aware: the filtered match count while a filter owns
 * the view, the document row count otherwise. `*estimated` (may be NULL)
 * reports whether that count is still growing (an estimate). Never forces a
 * full scan. */
static guint64
a11y_view_rows (App *app, gboolean *estimated)
{
  if (app->doc == NULL)
    {
      if (estimated != NULL)
        *estimated = FALSE;
      return 0;
    }
  if (app->filter.active)
    {
      LsgFilterBanner b;
      if (lsg_filter_banner (app->filter, &b))
        {
          if (estimated != NULL)
            *estimated = !app->filter.snapshot.total_exact;
          return b.matching;
        }
    }
  LsgRowCount rc = lsg_document_row_count (app->doc);
  if (estimated != NULL)
    *estimated = !rc.exact;
  return rc.count;
}

/* Post `msg` (which this call OWNS and frees) to the grid's live region at
 * `prio`. A no-op if there is no grid / no message. */
static void
a11y_announce (App *app, char *msg, GtkAccessibleAnnouncementPriority prio)
{
  if (app->area != NULL && msg != NULL && msg[0] != '\0')
    gtk_accessible_announce (GTK_ACCESSIBLE (app->area), msg, prio);
  g_free (msg);
}

/* Announce the current header-bar subtitle text (MEDIUM) — the existing
 * "Filtered — N of M rows" / row-count line. Called on the DISCRETE filter
 * apply/clear events (never per poll tick, which would spam). */
static void
a11y_announce_subtitle (App *app)
{
  if (app->area == NULL || app->title_status == NULL)
    return;
  const char *s = gtk_label_get_text (app->title_status);
  a11y_announce (app, g_strdup (s != NULL ? s : ""),
                 GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
}

/* Set a bare control's accessible name (FR4) from the single lsg_a11y source —
 * no drift from the tooltip text. */
static void
a11y_name (GtkWidget *w, LsgA11yControl control)
{
  gtk_accessible_update_property (GTK_ACCESSIBLE (w),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  lsg_a11y_control_name (control), -1);
}

/* The 1-based gutter row number the grid draws for a view row (the SOURCE row
 * under a filter). Uses the materialized window when the row is visible (the
 * common case after a reveal); falls back to `view_row + 1` otherwise (the
 * identity mapping). */
static guint64
a11y_gutter_for_view_row (App *app, guint64 view_row)
{
  if (app->win != NULL && view_row >= app->cur_span.first_row)
    {
      guint64 ri = view_row - app->cur_span.first_row;
      if (ri < lsg_window_row_count (app->win))
        {
          guint64 src = lsg_window_source_row (app->win, (guint32)ri);
          if (src != LSG_NO_ROW)
            return src + 1;
        }
    }
  return view_row + 1;
}

/* The column's accessible name for an announcement: the header label
 * (has_header) else the generic spreadsheet name — the SAME label the sticky
 * header draws. Newly-allocated (free with g_free). */
static char *
a11y_column_name (App *app, guint col)
{
  if (app->hdr_labels != NULL && col >= app->hdr_first
      && col < app->hdr_first + app->hdr_count)
    return g_strdup (app->hdr_labels[col - app->hdr_first]);
  if (app->has_header)
    return lsg_document_header_cell_dup (app->doc, col);
  return lsg_column_generic_name (col);
}

/* The DISPLAYED (formatted) text of the cell at (view_row, col), mirroring
 * grid_draw's per-cell rendering (raw for AUTO columns, the type+options
 * dispatcher for a configured one). Newly-allocated (free with g_free); ""
 * when the cell is not in the current window. */
static char *
a11y_cell_value (App *app, guint64 view_row, guint col)
{
  if (app->win == NULL || view_row < app->cur_span.first_row
      || col < app->cur_colwin.first)
    return g_strdup ("");
  guint64 ri = view_row - app->cur_span.first_row;
  guint ci = col - app->cur_colwin.first;
  if (ri >= lsg_window_row_count (app->win)
      || ci >= lsg_window_col_count (app->win))
    return g_strdup ("");

  const char *raw = lsg_window_cell (app->win, (guint32)ri, ci);
  if (col < app->n_cols && app->col_settings != NULL
      && !lsg_column_format_options_is_auto (app->col_settings[col].format))
    {
      LsgDisplay disp
          = lsg_format_cell (raw, app->col_kind[col], app->col_sem[col],
                             app->col_settings[col].format, app->glyphs);
      char *out = g_strdup (disp.text != NULL ? disp.text : "");
      lsg_display_clear (&disp);
      return out;
    }
  return g_strdup (raw != NULL ? raw : "");
}

static void
grid_update_a11y_description (App *app)
{
  if (app->area == NULL)
    return;

  const char *name
      = (app->title_name != NULL) ? gtk_label_get_text (app->title_name) : "";
  gboolean estimated = FALSE;
  guint64 rows = a11y_view_rows (app, &estimated);

  /* Gutter numbers of the first / last CURRENTLY-VISIBLE data rows. */
  guint64 first = 0, last = 0;
  if (app->doc != NULL && rows > 0 && app->win != NULL)
    {
      int h = gtk_widget_get_height (GTK_WIDGET (app->area));
      double body_h = (double)h - app->header_h;
      guint64 vis = (body_h > 0.0 && app->row_h > 0.0)
                        ? (guint64)(body_h / app->row_h)
                        : 1;
      if (vis == 0)
        vis = 1;
      guint64 first_view = app->cur_top_row;
      guint64 last_view = first_view + vis - 1;
      if (last_view > rows - 1)
        last_view = rows - 1;
      first = a11y_gutter_for_view_row (app, first_view);
      last = a11y_gutter_for_view_row (app, last_view);
    }

  char *desc = lsg_a11y_grid_description (name, app->n_cols, rows, estimated,
                                          first, last, app->filter.active);
  gtk_accessible_update_property (GTK_ACCESSIBLE (app->area),
                                  GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, desc,
                                  -1);
  g_free (desc);
}

/* Scroll the MINIMUM needed to bring cell (row, col) fully into view — no move
 * if it is already visible (FR1 auto-scroll). Setting the adjustments fires
 * the existing materialize + repaint (+ net-park drive) via
 * on_adjustment_changed.
 */
static void
a11y_reveal_cell (App *app, guint64 row, guint col)
{
  /* Vertical. */
  int h = gtk_widget_get_height (GTK_WIDGET (app->area));
  double body_h = (double)h - app->header_h;
  if (body_h > 0.0 && app->row_h > 0.0)
    {
      guint64 vis = (guint64)(body_h / app->row_h);
      if (vis == 0)
        vis = 1;
      double upper = gtk_adjustment_get_upper (app->vadj);
      if (row < app->cur_top_row)
        gtk_adjustment_set_value (
            app->vadj, lsg_grid_offset_for_top_row (
                           row, upper, app->row_estimate, app->row_h));
      else if (row > app->cur_top_row + vis - 1)
        {
          guint64 target_top = row - (vis - 1);
          gtk_adjustment_set_value (
              app->vadj,
              lsg_grid_offset_for_top_row (target_top, upper,
                                           app->row_estimate, app->row_h));
        }
    }

  /* Horizontal. */
  if (col < app->n_cols)
    {
      double col_x = 0.0;
      for (guint c = 0; c < col; c++)
        col_x += (app->col_widths[c] > 0.0) ? app->col_widths[c] : 0.0;
      double col_w = (app->col_widths[col] > 0.0) ? app->col_widths[col] : 0.0;
      double page_w = gtk_adjustment_get_page_size (app->hadj);
      double hval = gtk_adjustment_get_value (app->hadj);
      if (col_x < hval)
        gtk_adjustment_set_value (app->hadj, col_x);
      else if (col_x + col_w > hval + page_w)
        {
          double nv = col_x + col_w - page_w;
          gtk_adjustment_set_value (app->hadj, (nv < 0.0) ? 0.0 : nv);
        }
    }
}

/* Route one keyboard command through the pure cursor reducer, apply the result
 * to the ONE shared selection rectangle, auto-scroll, repaint, and announce
 * per the FR3 verbosity table. */
static void
grid_cursor_apply (App *app, LsgA11yCursorCommand command, gboolean extend)
{
  if (app->doc == NULL || app->n_cols == 0)
    return;

  LsgA11yExtent ext = { a11y_view_rows (app, NULL), app->n_cols };
  if (ext.rows == 0)
    return; /* empty view: every command is a no-op */

  LsgA11yCursor cur;
  cur.mode
      = (app->sel_mode == SEL_NONE) ? LSG_A11Y_SEL_NONE : LSG_A11Y_SEL_CELLS;
  cur.anchor.row = app->sel_a_row;
  cur.anchor.col = app->sel_a_col;
  cur.active.row = app->sel_b_row;
  cur.active.col = app->sel_b_col;

  int h = gtk_widget_get_height (GTK_WIDGET (app->area));
  double body_h = (double)h - app->header_h;
  guint32 page_rows = (body_h > 0.0 && app->row_h > 0.0)
                          ? (guint32)(body_h / app->row_h)
                          : 1;
  LsgA11yView view
      = { app->cur_top_row, app->cur_colwin.first, page_rows ? page_rows : 1 };

  LsgA11yCursorResult r
      = lsg_a11y_cursor_apply (cur, ext, view, command, extend);

  app->sel_mode = (r.cursor.mode == LSG_A11Y_SEL_CELLS) ? SEL_CELLS : SEL_NONE;
  app->sel_a_row = r.cursor.anchor.row;
  app->sel_a_col = r.cursor.anchor.col;
  app->sel_b_row = r.cursor.active.row;
  app->sel_b_col = r.cursor.active.col;

  if (r.should_reveal)
    a11y_reveal_cell (app, r.reveal.row, r.reveal.col);

  grid_materialize (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
  copy_update_affordance (app);

  /* Announcements (FR3): plain move / seed -> the landing cell (LOW); extend /
   * select-all -> the rect dimensions (MEDIUM); clear -> nothing. */
  if (command == LSG_A11Y_CURSOR_CLEAR)
    return;

  if (command == LSG_A11Y_CURSOR_SELECT_ALL
      || (extend && r.cursor.mode == LSG_A11Y_SEL_CELLS))
    {
      guint64 rr = ((r.cursor.active.row >= r.cursor.anchor.row)
                        ? r.cursor.active.row - r.cursor.anchor.row
                        : r.cursor.anchor.row - r.cursor.active.row)
                   + 1;
      guint cc = ((r.cursor.active.col >= r.cursor.anchor.col)
                      ? r.cursor.active.col - r.cursor.anchor.col
                      : r.cursor.anchor.col - r.cursor.active.col)
                 + 1;
      a11y_announce (app, lsg_a11y_announce_selection (rr, cc),
                     GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
    }
  else if (r.cursor.mode == LSG_A11Y_SEL_CELLS)
    {
      guint64 gutter = a11y_gutter_for_view_row (app, r.cursor.active.row);
      char *col = a11y_column_name (app, r.cursor.active.col);
      char *val
          = a11y_cell_value (app, r.cursor.active.row, r.cursor.active.col);
      a11y_announce (app, lsg_a11y_announce_cursor (gutter, col, val),
                     GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_LOW);
      g_free (col);
      g_free (val);
    }
}

static gboolean
on_key_pressed (GtkEventControllerKey *ctrl, guint keyval, guint keycode,
                GdkModifierType state, gpointer data)
{
  (void)ctrl;
  (void)keycode;
  App *app = data;
  if (app->doc == NULL)
    return GDK_EVENT_PROPAGATE;

  gboolean ctrl_held = (state & GDK_CONTROL_MASK) != 0;
  gboolean shift_held = (state & GDK_SHIFT_MASK) != 0;

  /* Ctrl+C copies the current selection; Ctrl+A selects the whole view extent.
   * BOTH stay on the grid key controller (grid-focus-scoped, G-A7) so a
   * focused text entry keeps its own Ctrl+C / Ctrl+A — never registered as
   * global app accelerators. */
  if (ctrl_held && (keyval == GDK_KEY_c || keyval == GDK_KEY_C))
    {
      do_copy (app);
      return GDK_EVENT_STOP;
    }
  if (ctrl_held && (keyval == GDK_KEY_a || keyval == GDK_KEY_A))
    {
      grid_cursor_apply (app, LSG_A11Y_CURSOR_SELECT_ALL, FALSE);
      return GDK_EVENT_STOP;
    }

  /* A plain digit typed on the grid opens the jump field, pre-filled. */
  if (!(state & (GDK_CONTROL_MASK | GDK_ALT_MASK)))
    {
      if (keyval >= GDK_KEY_0 && keyval <= GDK_KEY_9)
        {
          open_jump_with_digit (app, (char)('0' + (keyval - GDK_KEY_0)));
          return GDK_EVENT_STOP;
        }
      if (keyval >= GDK_KEY_KP_0 && keyval <= GDK_KEY_KP_9)
        {
          open_jump_with_digit (app, (char)('0' + (keyval - GDK_KEY_KP_0)));
          return GDK_EVENT_STOP;
        }
    }

  /* Escape (lowest-priority fallback): cancel an in-flight copy, else clear
   * the cursor/selection; otherwise propagate. An open find/jump/dialect
   * popover dismisses via its own controller (it holds focus), so when the
   * event reaches the grid no popover is open. */
  if (keyval == GDK_KEY_Escape && !ctrl_held)
    {
      if (app->copy_op != NULL)
        {
          copy_stop_and_join (app);
          return GDK_EVENT_STOP;
        }
      if (app->sel_mode != SEL_NONE)
        {
          grid_cursor_apply (app, LSG_A11Y_CURSOR_CLEAR, FALSE);
          return GDK_EVENT_STOP;
        }
      return GDK_EVENT_PROPAGATE;
    }

  /* Cursor navigation (no Ctrl); Shift extends the selection. Arrows move a
   * cell cursor (seeding at the top-left visible cell on the first press),
   * Page/Home/End reposition it, Left/Right also scroll horizontally — all via
   * the pure reducer + minimal auto-scroll. */
  if (!ctrl_held)
    {
      LsgA11yCursorCommand cmd;
      gboolean is_cmd = TRUE;
      switch (keyval)
        {
        case GDK_KEY_Down:
          cmd = LSG_A11Y_CURSOR_DOWN;
          break;
        case GDK_KEY_Up:
          cmd = LSG_A11Y_CURSOR_UP;
          break;
        case GDK_KEY_Left:
          cmd = LSG_A11Y_CURSOR_LEFT;
          break;
        case GDK_KEY_Right:
          cmd = LSG_A11Y_CURSOR_RIGHT;
          break;
        case GDK_KEY_Page_Down:
          cmd = LSG_A11Y_CURSOR_PAGE_DOWN;
          break;
        case GDK_KEY_Page_Up:
          cmd = LSG_A11Y_CURSOR_PAGE_UP;
          break;
        case GDK_KEY_Home:
          cmd = LSG_A11Y_CURSOR_HOME;
          break;
        case GDK_KEY_End:
          cmd = LSG_A11Y_CURSOR_END;
          break;
        default:
          is_cmd = FALSE;
          break;
        }
      if (is_cmd)
        {
          grid_cursor_apply (app, cmd, shift_held);
          return GDK_EVENT_STOP;
        }
    }

  return GDK_EVENT_PROPAGATE;
}

static void
on_adjustment_changed (GtkAdjustment *adj, gpointer data)
{
  (void)adj;
  App *app = data;
  if (app->doc == NULL)
    return;
  grid_materialize (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
  /* Net-park: a scroll landing beyond the fetched frontier comes back SHORT (a
   * bare ls_window_set fetched nothing) — drive the fetch to the top row so
   * the target rows appear. Identity view: cur_top_row is an original row.
   * Filtered: it is a filtered index driven as an original row, which still
   * advances the filter frontier (best-effort; a monotone scroll converges).
   */
  if (app->is_network && app->window_short && !app->net_drive_active)
    net_drive_begin (app, app->cur_top_row);
}

static void
on_area_resize (GtkDrawingArea *area, int width, int height, gpointer data)
{
  (void)area;
  (void)width;
  (void)height;
  App *app = data;

  /* The grid resizes with the window; re-anchor any OPEN popover to its
   * header-bar button (GTK4 doesn't always re-anchor an already-visible
   * popover when the parent's allocation changes on resize). */
  if (app->find_popover != NULL
      && gtk_widget_get_mapped (GTK_WIDGET (app->find_popover)))
    gtk_popover_present (app->find_popover);
  if (app->jump_popover != NULL
      && gtk_widget_get_mapped (GTK_WIDGET (app->jump_popover)))
    gtk_popover_present (app->jump_popover);

  if (app->doc == NULL)
    return;
  grid_update_vadjustment (app);
  grid_update_hadjustment (app);
  grid_materialize (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
}

/* ------------------------------------------------------------------------- */
/* Find (slice 2): the popover UI + highlight glue over lsg_find */
/* ------------------------------------------------------------------------- */

static void
ensure_poll (App *app)
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
        owned = g_strdup_printf (
            "%" G_GUINT64_FORMAT " of %" G_GUINT64_FORMAT "%s", d->position,
            d->total, d->total_final ? "" : "…");
      else if (d->total > 0)
        owned = g_strdup_printf ("%" G_GUINT64_FORMAT " matches%s", d->total,
                                 d->total_final ? "" : "…");
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
  double visible = ((double)h - app->header_h) / app->row_h;
  if (row >= app->cur_top_row
      && (double)(row - app->cur_top_row) < visible - 1.0)
    return;                                 /* already on screen */
  guint64 target = (row > 2) ? row - 2 : 0; /* leave a small top margin */
  double upper = gtk_adjustment_get_upper (app->vadj);
  double off = lsg_grid_offset_for_top_row (target, upper, app->row_estimate,
                                            app->row_h);
  gtk_adjustment_set_value (app->vadj, off); /* fires materialize + repaint */
}

/* Re-anchor the viewport so `row` is exactly the first visible row (the
 * cancel/reject restore, and the jump landing puts the target at the top). */
static void
scroll_to_first_row (App *app, guint64 row)
{
  double upper = gtk_adjustment_get_upper (app->vadj);
  double off = lsg_grid_offset_for_top_row (row, upper, app->row_estimate,
                                            app->row_h);
  gtk_adjustment_set_value (app->vadj, off); /* fires materialize + repaint */
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

/* Read the whole find draft out of the popover widgets: the mode from the
 * Text|Where stack, the TEXT query, and the WHERE column / operator / value.
 * `text` and `value` borrow the entries' buffers (valid while they live), so
 * the draft is consumed immediately (submit). The one canonical widgets->draft
 * funnel — find_run_query, do_apply_filter, and the toggle-sensitivity gate
 * all call it, so predicate-find and predicate-filter always see the same
 * draft. */
static void
find_read_draft (App *app)
{
  gboolean where
      = (app->find_stack != NULL)
        && g_strcmp0 (gtk_stack_get_visible_child_name (app->find_stack),
                      "where")
               == 0;
  app->find.draft.mode = where ? LSG_FIND_PREDICATE : LSG_FIND_TEXT;
  app->find.draft.text = (app->find_entry != NULL)
                             ? gtk_editable_get_text (app->find_entry)
                             : "";
  if (app->where_column != NULL)
    {
      guint sel = gtk_drop_down_get_selected (app->where_column);
      app->find.draft.column
          = (sel == GTK_INVALID_LIST_POSITION) ? 0 : (guint32)sel;
    }
  if (app->where_op != NULL)
    {
      guint sel = gtk_drop_down_get_selected (app->where_op);
      app->find.draft.op = (sel == GTK_INVALID_LIST_POSITION)
                               ? LSG_SEARCH_OP_EQ
                               : (LsgSearchOp)sel;
    }
  app->find.draft.value = (app->where_value != NULL)
                              ? gtk_editable_get_text (app->where_value)
                              : "";
  /* One session flag shared by both modes; the checkbox is the ONLY thing that
   * decides folding (smart case is retired). */
  app->find.draft.case_sensitive
      = (app->match_case != NULL)
        && gtk_check_button_get_active (app->match_case);
}

/* Reject feedback for a rejected predicate submit: keep the popover open,
 * focus
 * + select-all the value field, blink it (red + shake, reduce-motion aware),
 * and make NO core call. Shared by find_run_query + do_apply_filter. */
static void
where_reject_value (App *app)
{
  GtkWidget *v = GTK_WIDGET (app->where_value);
  if (v != NULL)
    {
      gtk_widget_grab_focus (v);
      gtk_editable_select_region (app->where_value, 0, -1);
    }
  entry_reject_feedback (v, &app->where_reject_id);
}

/* (Re)run the current draft as a live search: a TEXT substring query, or a
 * WHERE predicate; clear on an empty text query; blink on a rejected
 * predicate.
 */
static void
find_run_query (App *app)
{
  if (app->doc == NULL)
    return;
  /* A find's ls_search_start / ls_search_nav ALSO take the shared core scan
   * slot and would cancel a running copy's frontier-advance jump -> the copy
   * times out at FRONTIER = a TRUNCATED copy (the same slot-contention class
   * as jump). Yield the slot to a live copy (bounded + ✕-cancellable). See
   * also do_find_step. */
  if (app->copy_op != NULL)
    return;

  find_read_draft (app);

  /* Find is over ALL columns (predicate targets a single column and ignores
   * the scope; a hidden column is a legal predicate target): the whole column
   * set is visible, so the composed TEXT scope is NULL. */
  LsgFindSubmit sub
      = lsg_find_submit (app->find, NULL, app->n_cols, app->n_cols);

  if (sub.outcome == LSG_FIND_REJECTED)
    {
      /* Invalid predicate (out-of-range column, or an ordering op < > <= >=
       * with a non-numeric/empty value): NO core call — the active search and
       * its highlights are left exactly as they were; just blink the value. */
      where_reject_value (app);
      filter_update_toggle_sensitivity (app);
      return;
    }

  if (sub.outcome == LSG_FIND_RUN
      && lsg_document_search_start (app->doc, sub.request))
    {
      /* ls_search_start just TOOK the shared scan slot, cancelling any jump in
       * LS_JUMP_SCANNING to LS_JUMP_IDLE (ABI). A jump preserved past its
       * popover (the incidental-autohide case) would now be phantom-SCANNING
       * forever — an IDLE poll never resets a live flow, so grid_poll_tick
       * would never stop and net_drive would keep yielding (0-row fetches).
       * Retire it here, mirroring do_apply_filter. */
      app->jump = lsg_jump_initial ();
      app->find = lsg_find_began (app->find);
      app->find_nav_direction = LSG_SEARCH_FORWARD;
      app->find_wrap_issued = FALSE;
      lsg_document_search_nav (app->doc, lsg_search_nav_from_top ());
      ensure_poll (app);
    }
  else
    {
      /* Empty text query (IGNORED) or a failed start: clear the search. */
      lsg_document_search_cancel (app->doc);
      app->find = lsg_find_closed (app->find);
    }

  grid_materialize (app); /* refresh (or clear) the highlight mask */
  find_update_labels (app);
  filter_update_toggle_sensitivity (
      app); /* canApplyFilter follows the query */
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

  app->find
      = lsg_find_resolved (app->find, has, snap, app->find_nav_direction);

  /* A wrap notice asks for a follow-up navigation (issued once); it
   * self-clears when the wrap lands as a FOUND poll. Suppress it while a copy
   * runs — an ls_search_nav here would also take the shared scan slot from the
   * copy's jump (deferred, not lost: it re-issues on the next tick once the
   * copy is done). */
  LsgSearchNav wnav;
  if (app->copy_op == NULL && lsg_find_wrap_nav (app->find, &wnav))
    {
      if (!app->find_wrap_issued)
        {
          app->find_nav_direction = wnav.direction;
          app->find_wrap_issued = TRUE;
          lsg_document_search_nav (app->doc, wnav);
          find_set_sticky_notice (app, app->find.display.notice);
        }
    }
  else if (app->copy_op == NULL)
    {
      app->find_wrap_issued = FALSE;
    }

  gboolean landed
      = app->find.display.has_current
        && (!prev_has || app->find.display.current.row != prev_row);
  if (landed)
    scroll_to_match (app, app->find.display.current.row);

  grid_materialize (app); /* refresh the highlight mask as the scan advances */
  find_update_labels (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));

  /* Find-navigation landing (MEDIUM): "Match n of m, row R" — the same n/m the
   * status shows, R the landing's gutter row number (read off the now-
   * materialized window). Only on a NEW landing, never on plain scan ticks. */
  if (landed)
    a11y_announce (
        app,
        lsg_a11y_announce_find_landing (
            app->find.display.position, app->find.display.total,
            a11y_gutter_for_view_row (app, app->find.display.current.row)),
        GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
}

static void
do_find_step (App *app, LsgSearchDir direction)
{
  if (app->doc == NULL || !app->find.display.active)
    return;
  if (app->copy_op != NULL) /* yield the scan slot to a live copy */
    return;
  LsgSearchNav nav;
  if (lsg_find_step (app->find, direction, app->cur_top_row, &nav))
    {
      /* A scanning nav can take the shared slot too (ABI: "a nav that must
       * scan
       * ... cancelling a jump in LS_JUMP_SCANNING"). Retire any preserved jump
       * so it can't be left phantom-SCANNING. Reachable only after
       * find_run_query (find must be active), which already retired it, so
       * this is normally a no-op — kept for symmetry with the slot-taking
       * find_run_query branch. */
      app->jump = lsg_jump_initial ();
      app->find_nav_direction = direction;
      app->find_wrap_issued = FALSE;
      lsg_document_search_nav (app->doc, nav);
      ensure_poll (app);
    }
}

static void
on_find_search_changed (GtkSearchEntry *entry, gpointer data)
{
  (void)entry;
  find_run_query ((App *)data);
}

static void
on_find_next_clicked (GtkButton *button, gpointer data)
{
  (void)button;
  do_find_step ((App *)data, LSG_SEARCH_FORWARD);
}

static void
on_find_prev_clicked (GtkButton *button, gpointer data)
{
  (void)button;
  do_find_step ((App *)data, LSG_SEARCH_BACKWARD);
}

static gboolean
on_find_entry_key (GtkEventControllerKey *ctrl, guint keyval, guint keycode,
                   GdkModifierType state, gpointer data)
{
  (void)ctrl;
  (void)keycode;
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

/* Esc / click-away: cancel the core search + clear highlights; keep the draft.
 */
static void
on_find_popover_closed (GtkPopover *popover, gpointer data)
{
  (void)popover;
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

/* Opening (re)focuses the mode's field and re-runs any retained query to
 * re-highlight. In Where mode the column model is built lazily here. */
static void
on_find_popover_show (GtkWidget *popover, gpointer data)
{
  (void)popover;
  App *app = data;
  gboolean where
      = (app->find_stack != NULL)
        && g_strcmp0 (gtk_stack_get_visible_child_name (app->find_stack),
                      "where")
               == 0;
  if (where)
    {
      where_ensure_columns (app);
      if (app->where_value != NULL)
        gtk_widget_grab_focus (GTK_WIDGET (app->where_value));
      find_run_query (app); /* re-run the retained predicate */
    }
  else
    {
      gtk_widget_grab_focus (GTK_WIDGET (app->find_entry));
      const char *text = gtk_editable_get_text (app->find_entry);
      if (text != NULL && text[0] != '\0')
        find_run_query (app);
    }
}

static void
open_find (App *app)
{
  if (app->doc == NULL || app->find_button == NULL)
    return;
  gtk_menu_button_popup (app->find_button);
}

/* The app-level keyboard shortcuts (Ctrl+F Find, Ctrl+G/L Jump, Ctrl+O Open,
 * Ctrl+Shift+O Open URL, Ctrl+comma Preferences, Ctrl+?/F1 Shortcuts) are no
 * longer handled by an ad-hoc window key controller: they are promoted to
 * GActions with gtk_application_set_accels_for_action, sourced from the single
 * lsg_a11y accelerator table (see register_app_shortcuts). Grid-contextual
 * keys (arrows / digits / Ctrl+C / Ctrl+A / Esc) stay on the grid key
 * controller so they never fire while a text entry is focused (FR5 / G-A7). */

/* The WHERE operator dropdown: glyphs shown, names in per-item tooltips +
 * accessible labels. Index i maps 1:1 to LsgSearchOp i (EQ..GE). */
static const char *const WHERE_OP_GLYPHS[] = { "=", "≠", "<", ">", "≤", "≥" };
static const char *const WHERE_OP_NAMES[]
    = { "Equals",       "Not equal",          "Less than",
        "Greater than", "Less than or equal", "Greater than or equal" };

static void
where_op_setup (GtkSignalListItemFactory *f, GtkListItem *item, gpointer d)
{
  (void)f;
  (void)d;
  GtkWidget *lbl = gtk_label_new (NULL);
  gtk_widget_set_halign (lbl, GTK_ALIGN_CENTER);
  gtk_list_item_set_child (item, lbl);
}

static void
where_op_bind (GtkSignalListItemFactory *f, GtkListItem *item, gpointer d)
{
  (void)f;
  (void)d;
  guint pos = gtk_list_item_get_position (item);
  GtkWidget *lbl = gtk_list_item_get_child (item);
  if (lbl == NULL || pos >= G_N_ELEMENTS (WHERE_OP_GLYPHS))
    return;
  gtk_label_set_text (GTK_LABEL (lbl), WHERE_OP_GLYPHS[pos]);
  gtk_widget_set_tooltip_text (lbl, WHERE_OP_NAMES[pos]);
  gtk_accessible_update_property (GTK_ACCESSIBLE (lbl),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  WHERE_OP_NAMES[pos], -1);
}

/* A mode / column / operator change re-runs the query, mirroring macOS
 * `.onChange` (the value field is submit-validated instead — on Enter — so a
 * half-typed number does not blink on every keystroke). */
static void
on_where_changed (GObject *obj, GParamSpec *pspec, gpointer data)
{
  (void)obj;
  (void)pspec;
  App *app = data;
  if (app->where_ui_guard)
    return; /* programmatic model/selection swap: not a user change */
  find_run_query (app);
}

/* The Text|Where stack switched: build the Where column model on first entry,
 * focus the mode's field, and re-run (a mode change re-runs, macOS parity). */
static void
on_find_mode_changed (GObject *stack, GParamSpec *pspec, gpointer data)
{
  (void)stack;
  (void)pspec;
  App *app = data;
  gboolean where
      = g_strcmp0 (gtk_stack_get_visible_child_name (app->find_stack), "where")
        == 0;
  if (where)
    {
      where_ensure_columns (app);
      if (app->where_value != NULL)
        gtk_widget_grab_focus (GTK_WIDGET (app->where_value));
    }
  else if (app->find_entry != NULL)
    gtk_widget_grab_focus (GTK_WIDGET (app->find_entry));
  find_run_query (app);
}

/* Enter submits the predicate (validated by lsg_find_submit; a reject blinks);
 * Esc closes the popover. Capture phase so we see Return before the entry's
 * internal activate. */
static gboolean
on_where_value_key (GtkEventControllerKey *ctrl, guint keyval, guint keycode,
                    GdkModifierType state, gpointer data)
{
  (void)ctrl;
  (void)keycode;
  (void)state;
  App *app = data;
  switch (keyval)
    {
    case GDK_KEY_Escape:
      gtk_popover_popdown (app->find_popover);
      return GDK_EVENT_STOP;
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
      find_run_query (app);
      return GDK_EVENT_STOP;
    default:
      return GDK_EVENT_PROPAGATE;
    }
}

/* Forward-declared above: (re)build the column picker's model from every
 * column's label. Lazy (first Where entry / popover show), never at open. */
static void
where_ensure_columns (App *app)
{
  if (app->where_column == NULL || !app->where_columns_dirty
      || app->doc == NULL)
    return;
  app->where_columns_dirty = FALSE;

  GtkStringList *list = gtk_string_list_new (NULL);
  guint n = 0;
  LsgColumnLabel *labels = capture_all_labels (app, &n);
  for (guint32 i = 0; i < app->n_cols; i++)
    {
      char *base;
      if (labels != NULL && i < n && labels[i].present)
        base = lsg_utf8_sanitize_dup (labels[i].bytes, labels[i].len);
      else
        base = lsg_column_generic_name (i); /* A, B, C … (no source header) */
      gboolean hidden
          = (app->col_settings != NULL && app->col_settings[i].hidden);
      if (hidden)
        {
          /* Hidden columns are LEGAL predicate targets — mark, don't drop. */
          char *tagged = g_strdup_printf ("%s  (hidden)", base);
          gtk_string_list_append (list, tagged);
          g_free (tagged);
        }
      else
        gtk_string_list_append (list, base);
      g_free (base);
    }
  if (labels != NULL)
    lsg_column_labels_free (labels, n);

  /* Swapping the model resets the selection (emits notify::selected): guard so
   * it does not spuriously re-run mid-rebuild. */
  app->where_ui_guard = TRUE;
  gtk_drop_down_set_model (app->where_column, G_LIST_MODEL (list));
  guint sel = gtk_drop_down_get_selected (app->where_column);
  if (app->n_cols > 0
      && (sel == GTK_INVALID_LIST_POSITION || sel >= app->n_cols))
    gtk_drop_down_set_selected (app->where_column, 0);
  app->where_ui_guard = FALSE;
  g_object_unref (list);
}

/* The Where builder body: a column picker (searchable, over the column
 * labels), an operator glyph dropdown, and a value field. */
static GtkWidget *
build_where_body (App *app)
{
  GtkWidget *body = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  gtk_widget_set_size_request (body, 240, -1);

  /* Column picker: a searchable GtkDropDown over the label strings. The model
   * is set lazily (where_ensure_columns) so open stays O(viewport). */
  GtkExpression *expr
      = gtk_property_expression_new (GTK_TYPE_STRING_OBJECT, NULL, "string");
  GtkWidget *col = gtk_drop_down_new (NULL, expr); /* takes the expression */
  gtk_drop_down_set_enable_search (GTK_DROP_DOWN (col), TRUE);
  gtk_widget_set_hexpand (col, TRUE);
  gtk_accessible_update_property (GTK_ACCESSIBLE (col),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  "Filter column", -1);
  app->where_column = GTK_DROP_DOWN (col);

  /* Operator glyph dropdown (= != < > <= >=), names in tooltips. */
  const char *const op_items[] = { "=", "!=", "<", ">", "<=", ">=", NULL };
  GtkStringList *op_model = gtk_string_list_new (op_items);
  GtkListItemFactory *op_factory = gtk_signal_list_item_factory_new ();
  g_signal_connect (op_factory, "setup", G_CALLBACK (where_op_setup), NULL);
  g_signal_connect (op_factory, "bind", G_CALLBACK (where_op_bind), NULL);
  GtkWidget *op = gtk_drop_down_new (G_LIST_MODEL (op_model),
                                     NULL); /* takes the model */
  gtk_drop_down_set_factory (GTK_DROP_DOWN (op), op_factory);
  g_object_unref (op_factory);
  gtk_accessible_update_property (GTK_ACCESSIBLE (op),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  "Comparison operator", -1);
  app->where_op = GTK_DROP_DOWN (op);

  GtkWidget *value = gtk_entry_new ();
  gtk_entry_set_placeholder_text (GTK_ENTRY (value), "Value");
  gtk_widget_set_hexpand (value, TRUE);
  gtk_accessible_update_property (GTK_ACCESSIBLE (value),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  "Filter value", -1);
  app->where_value = GTK_EDITABLE (value);

  GtkWidget *opval = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  gtk_box_append (GTK_BOX (opval), op);
  gtk_box_append (GTK_BOX (opval), value);

  gtk_box_append (GTK_BOX (body), col);
  gtk_box_append (GTK_BOX (body), opval);

  g_signal_connect (col, "notify::selected", G_CALLBACK (on_where_changed),
                    app);
  g_signal_connect (op, "notify::selected", G_CALLBACK (on_where_changed),
                    app);

  GtkEventController *vkeys = gtk_event_controller_key_new ();
  gtk_event_controller_set_propagation_phase (vkeys, GTK_PHASE_CAPTURE);
  g_signal_connect (vkeys, "key-pressed", G_CALLBACK (on_where_value_key),
                    app);
  gtk_widget_add_controller (value, vkeys);
  return body;
}

static void
build_find_popover (App *app)
{
  GtkWidget *pop = gtk_popover_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);

  /* A `Text | Where` segmented switch at the TOP (a GtkStackSwitcher over the
   * two-page body stack) — macOS parity. */
  GtkWidget *stack = gtk_stack_new ();
  gtk_stack_set_transition_type (GTK_STACK (stack),
                                 GTK_STACK_TRANSITION_TYPE_NONE);
  /* Each page sizes to ITS OWN content: a homogeneous stack would stretch
   * the small Text search entry to the width AND height of the larger Where
   * builder page. With homogeneity off the Text page stays a compact entry
   * and the popover grows only when switched to Where; interpolate-size
   * makes that grow smooth. */
  gtk_stack_set_hhomogeneous (GTK_STACK (stack), FALSE);
  gtk_stack_set_vhomogeneous (GTK_STACK (stack), FALSE);
  gtk_stack_set_interpolate_size (GTK_STACK (stack), TRUE);
  app->find_stack = GTK_STACK (stack);
  GtkWidget *switcher = gtk_stack_switcher_new ();
  gtk_stack_switcher_set_stack (GTK_STACK_SWITCHER (switcher),
                                GTK_STACK (stack));
  gtk_widget_set_halign (switcher, GTK_ALIGN_CENTER);

  /* TEXT body: the substring search entry (page "text"). */
  GtkWidget *entry = gtk_search_entry_new ();
  gtk_widget_set_hexpand (entry, TRUE);
  gtk_widget_set_size_request (entry, 220, -1);
  a11y_name (entry, LSG_A11Y_CONTROL_SEARCH_ENTRY);
  app->find_entry = GTK_EDITABLE (entry);
  gtk_stack_add_titled (GTK_STACK (stack), entry, "text", "Text");

  /* WHERE body: the predicate builder (page "where"). */
  GtkWidget *where_body = build_where_body (app);
  gtk_stack_add_titled (GTK_STACK (stack), where_body, "where", "Where");

  /* Shared find navigation (both modes): prev / next beside the mode body. */
  GtkWidget *prev = gtk_button_new_from_icon_name ("go-up-symbolic");
  gtk_widget_set_tooltip_text (prev, "Previous match (Shift+Enter)");
  a11y_name (prev, LSG_A11Y_CONTROL_FIND_PREV);
  gtk_widget_add_css_class (prev, "flat");
  gtk_widget_set_valign (prev, GTK_ALIGN_CENTER);
  GtkWidget *next = gtk_button_new_from_icon_name ("go-down-symbolic");
  gtk_widget_set_tooltip_text (next, "Next match (Enter)");
  a11y_name (next, LSG_A11Y_CONTROL_FIND_NEXT);
  gtk_widget_add_css_class (next, "flat");
  gtk_widget_set_valign (next, GTK_ALIGN_CENTER);

  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  gtk_widget_set_hexpand (stack, TRUE);
  gtk_box_append (GTK_BOX (row), stack);
  gtk_box_append (GTK_BOX (row), prev);
  gtk_box_append (GTK_BOX (row), next);

  GtkWidget *status = gtk_label_new ("");
  gtk_widget_set_halign (status, GTK_ALIGN_START);
  gtk_widget_add_css_class (status, "dim-label");
  app->find_status = GTK_LABEL (status);

  /* "Filter to matches" — applies the current find query (text OR predicate)
   * as a filter (shared across both modes). */
  GtkWidget *toggle = gtk_toggle_button_new_with_label ("Filter to matches");
  gtk_widget_set_sensitive (toggle, FALSE);
  app->filter_toggle = GTK_TOGGLE_BUTTON (toggle);
  g_signal_connect (toggle, "toggled", G_CALLBACK (on_filter_toggled), app);

  /* "Match case" — the one session case flag SHARED by Text and Where; default
   * OFF (unchecked = ASCII case-insensitive). Toggling it re-issues the active
   * query. Sits beside "Filter to matches". */
  GtkWidget *match_case = gtk_check_button_new_with_label ("Match case");
  app->match_case = GTK_CHECK_BUTTON (match_case);
  g_signal_connect (match_case, "toggled", G_CALLBACK (on_match_case_toggled),
                    app);

  GtkWidget *actions = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_widget_set_hexpand (toggle, TRUE);
  gtk_widget_set_halign (toggle, GTK_ALIGN_START);
  gtk_widget_set_valign (match_case, GTK_ALIGN_CENTER);
  gtk_box_append (GTK_BOX (actions), toggle);
  gtk_box_append (GTK_BOX (actions), match_case);

  gtk_box_append (GTK_BOX (box), switcher);
  gtk_box_append (GTK_BOX (box), row);
  gtk_box_append (GTK_BOX (box), status);
  gtk_box_append (GTK_BOX (box), actions);
  gtk_popover_set_child (GTK_POPOVER (pop), box);
  app->find_popover = GTK_POPOVER (pop);

  g_signal_connect (entry, "search-changed",
                    G_CALLBACK (on_find_search_changed), app);
  g_signal_connect (prev, "clicked", G_CALLBACK (on_find_prev_clicked), app);
  g_signal_connect (next, "clicked", G_CALLBACK (on_find_next_clicked), app);
  g_signal_connect (stack, "notify::visible-child-name",
                    G_CALLBACK (on_find_mode_changed), app);
  g_signal_connect (pop, "closed", G_CALLBACK (on_find_popover_closed), app);
  g_signal_connect (pop, "show", G_CALLBACK (on_find_popover_show), app);

  /* CAPTURE phase so Enter/Shift+Enter/Esc reach us BEFORE the entry's
   * internal GtkText consumes Return (its "activate") — that's why Enter did
   * nothing. In capture we see Return first and return STOP, so Enter advances
   * to the next match (Shift+Enter → previous), the popover stays open for
   * repeated Enter, and Esc still closes. Other keys PROPAGATE so
   * typing/search-changed work. */
  GtkEventController *keys = gtk_event_controller_key_new ();
  gtk_event_controller_set_propagation_phase (keys, GTK_PHASE_CAPTURE);
  g_signal_connect (keys, "key-pressed", G_CALLBACK (on_find_entry_key), app);
  gtk_widget_add_controller (entry, keys);
}

/* ------------------------------------------------------------------------- */
/* Jump-to-row (slice 3): the popover UI over lsg_jump */
/* ------------------------------------------------------------------------- */

/* Show progress + cancel only while scanning; keep the fraction current. */
static void
jump_update_ui (App *app)
{
  gboolean scanning = (app->jump.kind == LSG_JUMP_FLOW_SCANNING);
  if (app->jump_progress != NULL)
    {
      gtk_widget_set_visible (GTK_WIDGET (app->jump_progress), scanning);
      if (scanning)
        gtk_progress_bar_set_fraction (app->jump_progress, app->jump.progress);
    }
  if (app->jump_cancel != NULL)
    gtk_widget_set_visible (GTK_WIDGET (app->jump_cancel), scanning);
}

/* Duration of the input-rejection blink (Adwaita .error red + shake), the ONE
 * knob shared by the jump box and the Where value field. */
#define LSG_REJECT_BLINK_MS 700

/* Per-shake context for the auto-clear timeout: which entry to un-style and
 * which App id-slot to zero. Freed by the source's destroy notify. */
typedef struct
{
  GtkWidget *entry;
  guint *id_slot;
} LsgRejectClear;

static gboolean
reject_shake_add (gpointer entry)
{
  gtk_widget_add_css_class (GTK_WIDGET (entry), "lsg-shake");
  return G_SOURCE_REMOVE;
}

static gboolean
reject_clear_timeout (gpointer data)
{
  LsgRejectClear *c = data;
  gtk_widget_remove_css_class (c->entry, "error");
  gtk_widget_remove_css_class (c->entry, "lsg-shake");
  *c->id_slot = 0; /* the ctx itself is freed by the source destroy notify */
  return G_SOURCE_REMOVE;
}

/* Whether the desktop wants animations — the reduce-motion switch
 * (gtk-enable-animations). A FALSE means honor reduce-motion: skip the shake.
 */
static gboolean
animations_enabled (GtkWidget *w)
{
  gboolean anim = TRUE;
  GtkSettings *s = gtk_widget_get_settings (w);
  if (s != NULL)
    g_object_get (s, "gtk-enable-animations", &anim, NULL);
  return anim;
}

/* Rejection feedback shared by the jump box and the Where value field: the
 * Adwaita error state (red) plus a short shake, auto-cleared after
 * LSG_REJECT_BLINK_MS. The shake class is removed then re-added on an idle so
 * the animation restarts on a repeated reject; it is SKIPPED entirely under
 * reduce-motion (the red state still shows). The pending clear-timeout id
 * lives in *id_slot so the reset/teardown paths can cancel it. */
static void
entry_reject_feedback (GtkWidget *entry, guint *id_slot)
{
  if (entry == NULL)
    return;
  gtk_widget_add_css_class (entry, "error");
  gtk_widget_remove_css_class (entry, "lsg-shake");
  if (animations_enabled (entry))
    g_idle_add (reject_shake_add, entry);
  if (*id_slot != 0)
    g_source_remove (*id_slot);
  LsgRejectClear *c = g_new (LsgRejectClear, 1);
  c->entry = entry;
  c->id_slot = id_slot;
  *id_slot = g_timeout_add_full (G_PRIORITY_DEFAULT, LSG_REJECT_BLINK_MS,
                                 reject_clear_timeout, c, g_free);
}

/* Cancel a pending reject blink and drop the styling now. */
static void
entry_clear_feedback (GtkWidget *entry, guint *id_slot)
{
  if (*id_slot != 0)
    {
      g_source_remove (*id_slot); /* frees the ctx via the destroy notify */
      *id_slot = 0;
    }
  if (entry != NULL)
    {
      gtk_widget_remove_css_class (entry, "error");
      gtk_widget_remove_css_class (entry, "lsg-shake");
    }
}

static void
jump_reject_feedback (App *app)
{
  entry_reject_feedback (GTK_WIDGET (app->jump_entry), &app->jump_reject_id);
}

static void
jump_clear_feedback (App *app)
{
  entry_clear_feedback (GTK_WIDGET (app->jump_entry), &app->jump_reject_id);
}

/* Forward-declared above; fold one core jump poll and act on the outcome. */
static void
jump_poll_fold (App *app)
{
  if (app->doc == NULL || app->jump.kind != LSG_JUMP_FLOW_SCANNING)
    return;

  LsgJumpStatus st = lsg_document_jump_poll (app->doc);
  /* Composition: a filtered short-land LANDS (filtered index vs original
   * target are not comparable), never rejects. */
  app->jump = lsg_jump_resolve (app->jump, st, app->filter.active);

  switch (app->jump.kind)
    {
    case LSG_JUMP_FLOW_LANDED:
      scroll_to_first_row (app, app->jump.landed_row);
      gtk_popover_popdown (app->jump_popover); /* closes -> resets to idle */
      break;
    case LSG_JUMP_FLOW_REJECTED:
      if (app->jump.has_restore)
        scroll_to_first_row (app, app->jump.restore_first_row);
      jump_reject_feedback (app);
      /* Keep the field open + re-armed; the flow is terminal (not scanning).
       */
      break;
    default:
      break; /* still SCANNING: progress updated below */
    }
  jump_update_ui (app);
}

/*
 * NETWORK DEMAND-DRIVE (net-park rule). On an http_range document the core
 * advances the fetch/filter frontier ONLY when the frontend issues an
 * ls_jump_start / ls_search_nav; a bare ls_window_set fetches nothing. So any
 * viewport landing beyond the fetched frontier — filter-apply, filter scroll,
 * deep scroll — must first drive a jump to the target row. This is the
 * plumbing; it deliberately does NOT touch the user's jump-popover flow
 * (`app->jump`). It is a no-op on local documents (their frontier is already
 * ahead), and it is not gate-testable (no fake network at the C ABI) —
 * verified on a real desktop.
 */
static void
net_drive_begin (App *app, guint64 target_row)
{
  if (!app->is_network || app->doc == NULL)
    return;
  /* The user's manual jump owns the single core scan slot; a net fetch-drive
   * (from a scroll or filter-apply) must NOT retarget it to `target_row`
   * mid-scan and mis-land the user's jump. Filter-apply resets the jump to
   * IDLE before it drives, so this only suppresses a scroll-drive during a
   * live user jump. */
  if (app->jump.kind == LSG_JUMP_FLOW_SCANNING)
    return;
  /* A streaming copy also drives the shared frontier (to its own stalled_row);
   * a scroll-drive that retargets the slot BELOW that row would leave the
   * copy's frontier short -> a re-stall on the same row -> a TRUNCATED copy.
   * Yield: the copy advances the frontier itself; scrolling far ahead just
   * waits for it. */
  if (app->copy_op != NULL)
    return;
  app->net_drive_active = TRUE;
  lsg_document_jump_start (app->doc, target_row);
  /* Fold the immediate poll (a behind-frontier / small fetch completes at
   * once); otherwise the ~100 ms tick keeps folding until DONE. */
  net_drive_poll (app);
  if (app->net_drive_active)
    ensure_poll (app);
}

static void
net_drive_poll (App *app)
{
  if (!app->net_drive_active || app->doc == NULL)
    return;
  LsgJumpStatus st = lsg_document_jump_poll (app->doc);
  if (st.state == LSG_JUMP_DONE)
    {
      app->net_drive_active = FALSE;
      grid_materialize (app); /* the target rows are now fetched */
      gtk_widget_queue_draw (GTK_WIDGET (app->area));
    }
}

/* Enter / Go: parse + validate + start (or reject) the jump. */
static void
do_jump_submit (App *app)
{
  if (app->doc == NULL)
    return;

  /* A streaming copy owns the shared core scan slot (it advances the frontier
   * to its own stalled_row from the worker). A user jump's ls_jump_start would
   * retarget that slot and TRUNCATE the copy (and the copy's bg jump would
   * mis-land this one). Deny while a copy runs — it is bounded + has a ✕
   * cancel; signal the denial with the field's reject blink ("cancel the copy
   * first"). */
  if (app->copy_op != NULL)
    {
      jump_reject_feedback (app);
      return;
    }

  const char *text = gtk_editable_get_text (app->jump_entry);
  /* Composition: while filtered the jump box takes ORIGINAL row numbers, so
   * hint with the base document count M and drive the frozen jump with
   * filtered=TRUE (which suppresses its out-of-range reject). */
  LsgRowCount rc = lsg_filter_jump_rowcount (
      app->filter, lsg_document_row_count (app->doc));
  LsgJumpSubmit sub
      = lsg_jump_submit (text, rc, app->filter.active, app->cur_top_row);
  app->jump = sub.flow;

  if (sub.outcome == LSG_JUMP_RUN)
    {
      lsg_document_jump_start (app->doc, sub.target);
      /* A behind-frontier / clamped target completes before the start returns
       * — fold the immediate poll so it lands without a tick. */
      jump_poll_fold (app);
      if (app->jump.kind == LSG_JUMP_FLOW_SCANNING)
        ensure_poll (app);
    }
  else
    {
      jump_reject_feedback (app); /* upfront reject: no scan, no move */
    }
  jump_update_ui (app);
}

static void
do_jump_cancel (App *app)
{
  if (app->jump.kind != LSG_JUMP_FLOW_SCANNING)
    return;
  if (app->doc != NULL)
    lsg_document_jump_cancel (app->doc);
  app->jump = lsg_jump_cancel (app->jump);
  if (app->jump.kind == LSG_JUMP_FLOW_CANCELLED)
    scroll_to_first_row (app, app->jump.restore_first_row);
  jump_update_ui (app);
}

static void
on_jump_go_clicked (GtkButton *button, gpointer data)
{
  (void)button;
  do_jump_submit ((App *)data);
}

/* Enter in the jump entry submits (a plain GtkEntry consumes Return as its
 * "activate" signal, so the key controller never sees it — wire activate). */
static void
on_jump_activate (GtkEntry *entry, gpointer data)
{
  (void)entry;
  do_jump_submit ((App *)data);
}

static void
on_jump_cancel_clicked (GtkButton *button, gpointer data)
{
  (void)button;
  do_jump_cancel ((App *)data);
}

static gboolean
on_jump_entry_key (GtkEventControllerKey *ctrl, guint keyval, guint keycode,
                   GdkModifierType state, gpointer data)
{
  (void)ctrl;
  (void)keycode;
  (void)state;
  App *app = data;
  /* Enter is handled by the entry's "activate" signal (the internal GtkText
   * consumes Return before this bubble-phase controller — that was the bug);
   * here we only need Escape to close. */
  if (keyval == GDK_KEY_Escape)
    {
      /* Escape is an EXPLICIT close: flag it so the closed handler cancels the
       * in-flight scan + restores the viewport (an incidental autohide does
       * not set this, and instead keeps a live deep/net scan running). */
      app->jump_explicit_close = TRUE;
      gtk_popover_popdown (app->jump_popover);
      return GDK_EVENT_STOP;
    }
  return GDK_EVENT_PROPAGATE;
}

/*
 * Close handler. There are two very different reasons the popover closes and
 * they must NOT be conflated (this was the valid-deep-jump-vanishes gap):
 *
 *  - EXPLICIT close (Escape; app->jump_explicit_close == TRUE): the user is
 *    abandoning the jump -> cancel the in-flight scan + restore the viewport +
 *    reset to idle, as before. (The ✕ cancel button takes do_jump_cancel,
 * which cancels in place and leaves the popover open, so it never reaches
 * here.)
 *
 *  - INCIDENTAL autohide (click-away / focus shift; flag FALSE): the popover
 *    vanished for an unrelated reason while a legitimately slow deep/network
 *    scan is still running (a deep net jump is real fetch time — tens of MB /
 *    seconds). Cancelling it here would silently throw away a valid jump. So
 *    KEEP the scan alive: do NOT cancel, restore, or reset the flow. The
 * global grid_poll_tick keeps folding jump_poll_fold (it is not tied to the
 *    popover), so when the scan reaches DONE the viewport scrolls to the
 * target and the flow resets to idle exactly as a normal land would.
 */
static void
on_jump_popover_closed (GtkPopover *popover, gpointer data)
{
  (void)popover;
  App *app = data;
  gboolean explicit = app->jump_explicit_close;
  app->jump_explicit_close
      = FALSE; /* consume: never leak into a later close */

  if (!explicit && app->doc != NULL
      && app->jump.kind == LSG_JUMP_FLOW_SCANNING)
    {
      /* Incidental autohide mid-scan: preserve the live jump so it still
       * lands; only tidy the transient reject blink. */
      jump_clear_feedback (app);
      return;
    }

  if (app->doc != NULL && app->jump.kind == LSG_JUMP_FLOW_SCANNING)
    {
      lsg_document_jump_cancel (app->doc);
      LsgJumpFlow c = lsg_jump_cancel (app->jump);
      if (c.kind == LSG_JUMP_FLOW_CANCELLED)
        scroll_to_first_row (app, c.restore_first_row);
    }
  app->jump = lsg_jump_initial ();
  jump_clear_feedback (app);
  jump_update_ui (app);
}

static void
on_jump_popover_show (GtkWidget *popover, gpointer data)
{
  (void)popover;
  App *app = data;
  app->jump_explicit_close
      = FALSE; /* fresh open: default to incidental close */
  gtk_widget_grab_focus (GTK_WIDGET (app->jump_entry));
  gtk_editable_set_position (app->jump_entry, -1);
}

static void
open_jump (App *app)
{
  if (app->doc == NULL || app->jump_button == NULL)
    return;
  gtk_menu_button_popup (app->jump_button);
}

/* Digit typed on the grid opens the jump field pre-filled (macOS parity). */
static void
open_jump_with_digit (App *app, char digit)
{
  if (app->doc == NULL || app->jump_entry == NULL)
    return;
  char text[2] = { digit, '\0' };
  gtk_editable_set_text (app->jump_entry, text);
  open_jump (app);
  gtk_editable_set_position (app->jump_entry, -1);
}

static void
build_jump_popover (App *app)
{
  GtkWidget *pop = gtk_popover_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);

  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *entry = gtk_entry_new ();
  gtk_entry_set_input_purpose (GTK_ENTRY (entry), GTK_INPUT_PURPOSE_DIGITS);
  gtk_entry_set_placeholder_text (GTK_ENTRY (entry), "Row number");
  gtk_widget_set_hexpand (entry, TRUE);
  gtk_widget_set_size_request (entry, 160, -1);
  app->jump_entry = GTK_EDITABLE (entry);

  GtkWidget *go = gtk_button_new_with_label ("Go");
  gtk_widget_add_css_class (go, "suggested-action");

  gtk_box_append (GTK_BOX (row), entry);
  gtk_box_append (GTK_BOX (row), go);

  GtkWidget *progress = gtk_progress_bar_new ();
  gtk_widget_set_visible (progress, FALSE);
  app->jump_progress = GTK_PROGRESS_BAR (progress);

  GtkWidget *cancel = gtk_button_new_with_label ("Cancel");
  gtk_widget_set_halign (cancel, GTK_ALIGN_END);
  gtk_widget_set_visible (cancel, FALSE);
  app->jump_cancel = GTK_BUTTON (cancel);

  gtk_box_append (GTK_BOX (box), row);
  gtk_box_append (GTK_BOX (box), progress);
  gtk_box_append (GTK_BOX (box), cancel);
  gtk_popover_set_child (GTK_POPOVER (pop), box);
  app->jump_popover = GTK_POPOVER (pop);

  g_signal_connect (go, "clicked", G_CALLBACK (on_jump_go_clicked), app);
  g_signal_connect (cancel, "clicked", G_CALLBACK (on_jump_cancel_clicked),
                    app);
  g_signal_connect (pop, "closed", G_CALLBACK (on_jump_popover_closed), app);
  g_signal_connect (pop, "show", G_CALLBACK (on_jump_popover_show), app);
  g_signal_connect (entry, "activate", G_CALLBACK (on_jump_activate),
                    app); /* Enter = Go */

  GtkEventController *keys = gtk_event_controller_key_new ();
  g_signal_connect (keys, "key-pressed", G_CALLBACK (on_jump_entry_key), app);
  gtk_widget_add_controller (entry, keys);
}

/* Install the one-time CSS for the rejection shake animation. */
static void
install_jump_css (void)
{
  GtkCssProvider *css = gtk_css_provider_new ();
  /* Shake via `transform: translate` (NOT margins): a transform is a
   * paint-time offset that does NOT change the widget's allocation, so the
   * parent GtkPopover never re-measures / re-anchors mid-animation (which
   * visually detached it). */
  gtk_css_provider_load_from_string (
      css, "@keyframes lsg-shake {"
           "  0%   { transform: translateX(0px); }"
           "  20%  { transform: translateX(6px); }"
           "  40%  { transform: translateX(-5px); }"
           "  60%  { transform: translateX(4px); }"
           "  80%  { transform: translateX(-2px); }"
           "  100% { transform: translateX(0px); }"
           "}"
           ".lsg-shake { animation: lsg-shake 300ms ease; }"
           /* The dialect dropdown's GtkListBox: drop the `list` node's own
            * `@view_bg_color` fill (darker than the popover on dark themes)
            * so the standard popover background shows through — matching the
            * Find/Jump popovers. Row hover-highlight is unaffected (it comes
            * from the activatable rows, not this background). */
           ".lsg-flat-list { background: none; }");
  GdkDisplay *display = gdk_display_get_default ();
  if (display != NULL)
    gtk_style_context_add_provider_for_display (
        display, GTK_STYLE_PROVIDER (css),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_object_unref (css);
}

/*
 * The jump-to-row button glyph — a Cairo replication of the macOS
 * `JumpArrowGlyph` (OverlayView.swift): two small circles (a "here" and a
 * "there") joined by a right-bulging circular arc that arrows south-west into
 * the lower circle. the author finds this clearer than the stock
 * `go-jump-symbolic`. Design bbox x[19,56] y[7,93], mapped/centred into the
 * drawing area; the fixed-geometry angles and unit vectors are hardcoded so
 * the app needs no libm. Tinted with the widget's current foreground color
 * (gtk_widget_get_color), so it reads correctly in both light and dark, like
 * the accent handling elsewhere.
 */
static void
jump_glyph_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
                 gpointer data)
{
  (void)data;
  GdkRGBA fg;
  gtk_widget_get_color (GTK_WIDGET (area), &fg);
  gdk_cairo_set_source_rgba (cr, &fg);

  const double b_min_x = 19.0, b_max_x = 56.0, b_min_y = 7.0, b_max_y = 93.0;
  const double bw = b_max_x - b_min_x, bh = b_max_y - b_min_y;
  const double fill = 0.88; /* leave the stroke a small margin */
  double kx = (double)width / bw, ky = (double)height / bh;
  double k = (kx < ky ? kx : ky) * fill;
  double ox = ((double)width - bw * k) / 2.0 - b_min_x * k;
  double oy = ((double)height - bh * k) / 2.0 - b_min_y * k;
#define GX(x) (ox + (x) * k)
#define GY(y) (oy + (y) * k)

  /* Match the sibling Adwaita symbolic stroke weight (search / insert-link /
   * edit-copy): they render a thin ~1.2-1.3px stroke at 16px. 0.11*height read
   * heavier than them; 0.08 gives ~1.28px at the 16px glyph. */
  double lw = (double)height * 0.08;
  if (lw < 1.0)
    lw = 1.0;
  cairo_set_line_width (cr, lw);
  cairo_set_line_cap (cr, CAIRO_LINE_CAP_ROUND);
  cairo_set_line_join (cr, CAIRO_LINE_JOIN_ROUND);

  /* Two small circles: the "here" (top) and "there" (bottom). */
  double rr = 11.0 * k;
  cairo_new_sub_path (cr);
  cairo_arc (cr, GX (30), GY (18), rr, 0.0, 2.0 * G_PI);
  cairo_new_sub_path (cr);
  cairo_arc (cr, GX (30), GY (82), rr, 0.0, 2.0 * G_PI);
  cairo_stroke (cr);

  /* Right-bulging arc from (40,26) to (40,74): centre (30,50), radius 26,
   * angles atan2(∓24,10). */
  double ex = GX (40), ey = GY (74);
  const double a1 = -1.17600521, a2 = 1.17600521;
  cairo_new_sub_path (cr);
  cairo_arc (cr, GX (30), GY (50), 26.0 * k, a1, a2);
  cairo_stroke (cr);

  /* Arrowhead at the arc's arrival: barbs the unit back-vector (12/13, -5/13)
   * rotated by ±0.55 rad, opening SW into the lower circle. */
  const double bxu = 12.0 / 13.0, byu = -5.0 / 13.0;
  const double ca = 0.85252452, sa = 0.52268723; /* cos/sin(0.55) */
  double barb = 12.0 * k;
  cairo_move_to (cr, ex + barb * (bxu * ca - byu * sa),
                 ey + barb * (bxu * sa + byu * ca));
  cairo_line_to (cr, ex, ey);
  cairo_line_to (cr, ex + barb * (bxu * ca + byu * sa),
                 ey + barb * (-bxu * sa + byu * ca));
  cairo_stroke (cr);
#undef GX
#undef GY
}

/*
 * The header on/off glyph — a macOS-parity "H" (see the macOS `HeaderGlyph`).
 * When the first row IS a header the "H" is drawn solid; when it is DATA the
 * "H" fades to ~0.3 and a FULL-strength diagonal slash crosses it, so the
 * slash (not the H) carries the "not a header" meaning. Theme-tinted via
 * `gtk_widget_get_color`, so it reads in light and dark. Reads the live state
 * from `app->header_toggle`; the caller queue_draws it whenever that flips.
 */
static void
header_glyph_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
                   gpointer data)
{
  App *app = data;
  gboolean on = (app->header_toggle != NULL)
                    ? gtk_toggle_button_get_active (app->header_toggle)
                    : TRUE;
  GdkRGBA fg;
  gtk_widget_get_color (GTK_WIDGET (area), &fg);

  /* The "H", centred, semibold, sized to the glyph box. */
  PangoLayout *layout
      = gtk_widget_create_pango_layout (GTK_WIDGET (area), "H");
  PangoFontDescription *fd = pango_font_description_new ();
  pango_font_description_set_weight (fd, PANGO_WEIGHT_SEMIBOLD);
  pango_font_description_set_absolute_size (fd, (double)height * 0.72
                                                    * PANGO_SCALE);
  pango_layout_set_font_description (layout, fd);
  pango_font_description_free (fd);

  int lw, lh;
  pango_layout_get_pixel_size (layout, &lw, &lh);
  GdkRGBA hcol = fg;
  hcol.alpha = on ? fg.alpha : fg.alpha * 0.3; /* faint H in the data state */
  gdk_cairo_set_source_rgba (cr, &hcol);
  cairo_move_to (cr, ((double)width - lw) / 2.0, ((double)height - lh) / 2.0);
  pango_cairo_show_layout (cr, layout);
  g_object_unref (layout);

  if (!on)
    {
      /* Full-strength forward slash (macOS: a 3x24 capsule rotated 45deg). */
      gdk_cairo_set_source_rgba (cr, &fg);
      double lwp = (double)height * 0.14;
      if (lwp < 2.0)
        lwp = 2.0;
      cairo_set_line_width (cr, lwp);
      cairo_set_line_cap (cr, CAIRO_LINE_CAP_ROUND);
      cairo_move_to (cr, (double)width * 0.22, (double)height * 0.82);
      cairo_line_to (cr, (double)width * 0.78, (double)height * 0.18);
      cairo_stroke (cr);
    }
}

/*
 * A 2-line header-bar menu-button child: a small, dimmed CATEGORY word ("Sep"
 * / "Quote") stacked over the current CHARACTER glyph (kept up to date by
 * dialect_sync_quick_controls via `*out_glyph`). Using set_child (not
 * set_label) also drops the GtkMenuButton dropdown arrow.
 */
static GtkWidget *
build_dialect_button_child (const char *category, GtkLabel **out_glyph)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_valign (box, GTK_ALIGN_CENTER);
  GtkWidget *cat = gtk_label_new (category);
  gtk_widget_add_css_class (cat, "caption");   /* small */
  gtk_widget_add_css_class (cat, "dim-label"); /* muted */
  GtkWidget *glyph = gtk_label_new ("");
  gtk_box_append (GTK_BOX (box), cat);
  gtk_box_append (GTK_BOX (box), glyph);
  *out_glyph = GTK_LABEL (glyph);
  return box;
}

/* ------------------------------------------------------------------------- */
/* Filter-to-matches (slice 4): the toggle + subtitle status over lsg_filter */
/* ------------------------------------------------------------------------- */

/* The toggle may turn ON only when the current find draft is filterable
 * (canApplyFilter = the compose is not IGNORED — an empty TEXT query), or stay
 * live to turn OFF. Reads the whole draft (text OR predicate) through the one
 * find_read_draft funnel so predicate drafts enable it too: a REJECTED
 * predicate still counts as filterable (the reject blinks at apply time). */
static void
filter_update_toggle_sensitivity (App *app)
{
  if (app->filter_toggle == NULL)
    return;
  gboolean can = app->filter.active;
  if (!can && app->doc != NULL)
    {
      find_read_draft (app);
      LsgFindSubmit sub
          = lsg_find_submit (app->find, NULL, app->n_cols, app->n_cols);
      can = (sub.outcome != LSG_FIND_IGNORED);
    }
  gtk_widget_set_sensitive (GTK_WIDGET (app->filter_toggle),
                            app->doc != NULL && can);
}

static void
filter_set_toggle (App *app, gboolean active)
{
  if (app->filter_toggle == NULL)
    return;
  app->filter_ui_guard = TRUE;
  gtk_toggle_button_set_active (app->filter_toggle, active);
  app->filter_ui_guard = FALSE;
}

/* Sync the whole filter UI (toggle position + sensitivity + subtitle) to
 * state. */
static void
filter_sync_ui (App *app)
{
  filter_set_toggle (app, app->filter.active);
  filter_update_toggle_sensitivity (app);
  update_title_subtitle (app);
}

/* Capture the ORIGINAL row number of the top visible (filtered) row, so the
 * identity view can re-anchor there after clearing (ARCH criterion 13). */
static guint64
capture_top_source_row (App *app)
{
  guint64 sr = 0;
  if (app->doc == NULL)
    return 0;
  LsgWindow *w = lsg_document_set_window (app->doc, app->cur_top_row, 1, 0, 1);
  guint64 s = lsg_window_source_row (w, 0);
  if (s != LSG_NO_ROW)
    sr = s;
  lsg_window_free (w);
  return sr;
}

/* Reflect a filtered/identity row-count change into the grid geometry and land
 * the viewport on `first_row` (filtered row 0 on apply, the captured source
 * row on clear). */
static void
filter_rebuild_grid (App *app, guint64 first_row)
{
  LsgRowCount rc = lsg_document_row_count (app->doc);
  app->row_estimate = (rc.count > 0) ? rc.count : 1;
  grid_update_gutter (app);
  grid_update_vadjustment (app);
  scroll_to_first_row (app, first_row); /* fires materialize + repaint */
  grid_materialize (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
}

/* Apply the CURRENT find draft as a filter (routes the same request Find would
 * run to the filter bridge). */
static void
do_apply_filter (App *app)
{
  if (app->doc == NULL)
    return;

  find_read_draft (app); /* text OR predicate — the same draft Find runs */
  LsgFindSubmit sub
      = lsg_find_submit (app->find, NULL, app->n_cols, app->n_cols);
  if (sub.outcome != LSG_FIND_RUN)
    {
      /* A rejected PREDICATE (out-of-range column / non-numeric ordering
       * value) blinks the value field, exactly like a rejected predicate find;
       * an empty TEXT query is a silent no-op. Either way, no filter is set.
       */
      if (sub.outcome == LSG_FIND_REJECTED)
        where_reject_value (app);
      filter_set_toggle (app, FALSE); /* not filterable (empty / rejected) */
      return;
    }

  /* A filter changes the copy job's coordinate space (identity <-> filtered),
   * which the frozen contract says invalidates an open job ("close this job
   * and open a fresh one"). STOP any in-flight copy BEFORE the view change — a
   * mid- copy filter would otherwise pull ls_copy_next in the wrong coordinate
   * space. */
  copy_stop_and_join (app);

  LsgRowCount id_rc
      = lsg_document_row_count (app->doc); /* base M (first apply) */
  if (!lsg_document_filter_set (app->doc, sub.request))
    {
      filter_set_toggle (app, FALSE); /* the core rejected it */
      return;
    }

  /* The guaranteed non-idle post-set poll makes the subtitle correct
   * immediately. */
  LsgFilterSnapshot snap = { LSG_FILTER_PHASE_SCANNING, 0.0, 0, FALSE };
  lsg_document_filter_poll (app->doc, &snap);
  app->filter = lsg_filter_applied (app->filter, id_rc, snap);

  /* Applying a filter resets the active find + jump (the coordinate space
   * changed); the find DRAFT is retained. */
  app->find = lsg_find_invalidated (app->find);
  app->find_sticky_notice = LSG_FIND_NOTICE_NONE;
  app->find_wrap_issued = FALSE;
  find_clear_mask (app);
  app->jump = lsg_jump_initial ();

  filter_rebuild_grid (app, 0); /* land on filtered row 0 */
  /* Net-park (Bug 2): ls_filter_set parks the filter-scan immediately (count
   * 0); the filtered frontier advances ONLY via a filtered ls_jump_start.
   * Drive it to original row 0 so the first matching rows are fetched and the
   * view is not empty (a bare ls_window_set fetched nothing). No-op on a local
   * doc. */
  net_drive_begin (app, 0);
  update_title_subtitle (app);
  a11y_announce_subtitle (app); /* filter apply -> the new status (MEDIUM) */
  filter_update_toggle_sensitivity (app);
  ensure_poll (app);
}

/* Clear the active filter, restoring the identity view re-anchored near the
 * row that was on screen. Reachable from the popover toggle AND the header-bar
 * (x) button, so it always syncs the toggle back OFF (guarded — no re-entry).
 */
static void
do_clear_filter (App *app)
{
  if (app->doc == NULL || !app->filter.active)
    {
      app->filter = lsg_filter_cleared (app->filter); /* no-op */
      filter_set_toggle (app, FALSE);
      update_title_subtitle (app);
      return;
    }

  /* Clearing the filter also changes the copy job's coordinate space (filtered
   * -> identity) — stop any in-flight copy first (same rule as apply). */
  copy_stop_and_join (app);

  guint64 restore = capture_top_source_row (app); /* BEFORE clearing */
  lsg_document_filter_clear (app->doc);
  app->filter = lsg_filter_cleared (app->filter);

  app->find = lsg_find_invalidated (app->find);
  app->find_sticky_notice = LSG_FIND_NOTICE_NONE;
  find_clear_mask (app);
  app->jump = lsg_jump_initial ();

  filter_set_toggle (app, FALSE); /* the (x) path also un-presses the toggle */
  filter_rebuild_grid (app, restore); /* identity view, re-anchored */
  update_title_subtitle (app);
  a11y_announce_subtitle (
      app); /* filter clear -> the row-count line (MEDIUM) */
  filter_update_toggle_sensitivity (app);
}

/* The header-bar (x) after the "Filtered — N of M rows" subtitle: the compact
 * successor to the old banner's Clear button. Shown only while filtered. */
static void
on_filter_clear_clicked (GtkButton *button, gpointer data)
{
  (void)button;
  do_clear_filter ((App *)data);
}

/* Forward-declared above; fold one filter poll into the subtitle + grid. */
static void
filter_poll_fold (App *app)
{
  if (app->doc == NULL || !app->filter.active)
    return;
  LsgFilterSnapshot snap;
  gboolean has = lsg_document_filter_poll (app->doc, &snap);
  app->filter = lsg_filter_resolved (app->filter, has, snap);
  update_title_subtitle (app);
  /* The filtered row count m grows as the scan advances AND jumps to its
   * final value on the SCANNING->DONE transition; the poll STOPS right after
   * total_exact latches (grid_poll_tick keeps ticking only while
   * !total_exact), so the DONE fold is the LAST chance to paint the completed
   * set. A phase==SCANNING guard here dropped that final repaint: a fast
   * local scan finishing before the first ~100 ms tick left the grid frozen
   * on the near-empty apply-time window until a manual click forced a redraw.
   * Re-materialize on EVERY fold (O(viewport), matcher-independent) so both
   * the widening view and the final batch paint with no click — the GTK
   * analog of the macOS REPAINT-FAMILY rule (a mutation with no scroll defers
   * its draw -> drive a synchronous repaint). */
  grid_materialize (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
}

static void
on_filter_toggled (GtkToggleButton *toggle, gpointer data)
{
  App *app = data;
  if (app->filter_ui_guard)
    return; /* programmatic set: ignore */
  if (gtk_toggle_button_get_active (toggle))
    do_apply_filter (app);
  else
    do_clear_filter (app);
}

/* Toggling "Match case" re-issues whatever the flag governs so the new
 * folding takes effect at once (find_read_draft reads the checkbox fresh):
 * a live find re-runs, and an active filter re-applies. Order matters:
 * re-applying the filter re-folds the visible SET (and invalidates the
 * find), so capture the find's live state first and re-run it afterwards,
 * restoring highlights within the freshly re-folded view. */
static void
on_match_case_toggled (GtkCheckButton *button, gpointer data)
{
  App *app = data;
  (void)button;
  if (app->doc == NULL)
    return;
  gboolean find_was_active = app->find.display.active;
  if (app->filter.active)
    do_apply_filter (app);
  if (find_was_active)
    find_run_query (app);
}

/* ------------------------------------------------------------------------- */
/* Streaming copy (slice 5): selection + off-main worker + clipboard + the */
/* reusable header-bar progress widget */
/* ------------------------------------------------------------------------- */

/* The off-main copy worker's shared state (defined up-front so the cancel
 * affordance and the drive can both reach it). */
struct _CopyOp
{
  LsgDocument *doc; /* captured at launch (stable per leaf-before-root) */
  LsgCopyRect rect;
  guint64 budget;
  gint cancel; /* g_atomic; set by the main thread */
  GMutex lock; /* guards `progress` / `finished` / results */
  gdouble progress;
  gboolean finished;
  GByteArray *blob; /* worker-owned; read by main after join */
  LsgCopyOutcome outcome;
  guint64 rows_done;
};

/* --- reusable header-bar progress: a determinate bar + inline cancel. Hidden
 *     by default; any long op (copy now, scan/index/network later) drives it
 * via header_progress_show / _set / _hide. --- */

static void
on_hp_cancel_clicked (GtkButton *button, gpointer data)
{
  (void)button;
  App *app = data;
  /* The header progress is shared, but by construction only one owner is ever
   * live: a URL open runs copy_stop_and_join before it goes in flight, and
   * do_copy refuses to start while app->net != NULL. So at most one of copy_op
   * / net is non-NULL here, and the copy-first check cancels the true owner.
   */
  if (app->copy_op != NULL)
    g_atomic_int_set (&app->copy_op->cancel,
                      1); /* the worker stops promptly */
  else if (app->net != NULL)
    lsg_net_open_cancel (app->net); /* the poll folds to CANCELLED */
}

static void
build_header_progress (App *app)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *bar = gtk_progress_bar_new ();
  gtk_widget_set_valign (bar, GTK_ALIGN_CENTER);
  gtk_widget_set_size_request (bar, 150, -1);
  GtkWidget *cancel = gtk_button_new_from_icon_name ("window-close-symbolic");
  gtk_widget_add_css_class (cancel, "flat");
  gtk_widget_set_tooltip_text (cancel, "Cancel");
  gtk_box_append (GTK_BOX (box), bar);
  gtk_box_append (GTK_BOX (box), cancel);
  gtk_widget_set_visible (box, FALSE);
  app->hp_box = box;
  app->hp_bar = GTK_PROGRESS_BAR (bar);
  app->hp_cancel = GTK_BUTTON (cancel);
  g_signal_connect (cancel, "clicked", G_CALLBACK (on_hp_cancel_clicked), app);
}

static void
header_progress_show (App *app, const char *label)
{
  if (app->hp_box == NULL)
    return;
  gtk_progress_bar_set_fraction (app->hp_bar, 0.0);
  if (label != NULL)
    {
      gtk_progress_bar_set_show_text (app->hp_bar, TRUE);
      gtk_progress_bar_set_text (app->hp_bar, label);
    }
  gtk_widget_set_visible (app->hp_box, TRUE);
}

/* fraction >= 0 => determinate; < 0 => indeterminate pulse. */
static void
header_progress_set (App *app, gdouble fraction)
{
  if (app->hp_bar == NULL)
    return;
  if (fraction >= 0.0)
    gtk_progress_bar_set_fraction (app->hp_bar, fraction);
  else
    gtk_progress_bar_pulse (app->hp_bar);
}

static void
header_progress_hide (App *app)
{
  if (app->hp_box != NULL)
    gtk_widget_set_visible (app->hp_box, FALSE);
}

/* --- selection algebra (view rows + physical columns) --- */

/* Normalize the two selection corners (+ mode) into the half-open copy rect.
 */
static LsgCopyRect
selection_rect (App *app)
{
  LsgCopyRect r = { 0, 0, 0, 0 };
  if (app->sel_mode == SEL_NONE || app->n_cols == 0)
    return r;

  guint64 r0 = MIN (app->sel_a_row, app->sel_b_row);
  guint64 r1 = MAX (app->sel_a_row, app->sel_b_row);
  guint c0 = MIN (app->sel_a_col, app->sel_b_col);
  guint c1 = MAX (app->sel_a_col, app->sel_b_col);

  if (app->sel_mode == SEL_ROWS) /* whole rows -> all columns */
    {
      c0 = 0;
      c1 = app->n_cols - 1;
    }
  if (app->sel_mode == SEL_COLS) /* whole columns -> all rows */
    {
      r0 = 0;
      r1 = (app->row_estimate > 0) ? app->row_estimate - 1 : 0;
    }

  r.first_row = r0;
  r.row_count = r1 - r0 + 1;
  r.first_col = c0;
  r.col_count = c1 - c0 + 1;
  return r;
}

/* Whether a cell (view row, physical col) is inside the current selection. */
static gboolean
selection_contains (App *app, guint64 row, guint col)
{
  if (app->sel_mode == SEL_NONE || app->n_cols == 0)
    return FALSE;
  guint64 r0 = MIN (app->sel_a_row, app->sel_b_row);
  guint64 r1 = MAX (app->sel_a_row, app->sel_b_row);
  guint c0 = MIN (app->sel_a_col, app->sel_b_col);
  guint c1 = MAX (app->sel_a_col, app->sel_b_col);
  if (app->sel_mode == SEL_ROWS)
    {
      c0 = 0;
      c1 = app->n_cols - 1;
    }
  if (app->sel_mode == SEL_COLS)
    {
      r0 = 0;
      r1 = G_MAXUINT64;
    }
  return row >= r0 && row <= r1 && col >= c0 && col <= c1;
}

/* Hit-test a pointer (x,y) to a view row + physical column, and which region
 * (0 = cell body, 1 = row-number gutter, 2 = header, 3 = corner). */
static int
hit_test (App *app, double x, double y, guint64 *out_row, guint *out_col)
{
  gboolean in_gutter = (x < app->gutter_w);
  gboolean in_header = (y < app->header_h);

  double yy = y - app->header_h + app->cur_pixel_off;
  if (yy < 0.0)
    yy = 0.0;
  guint64 row = app->cur_top_row + (guint64)(yy / app->row_h);
  if (app->row_estimate > 0 && row > app->row_estimate - 1)
    row = app->row_estimate - 1;

  double hval = gtk_adjustment_get_value (app->hadj);
  double xx = x - app->gutter_w + hval;
  if (xx < 0.0)
    xx = 0.0;
  guint col = 0;
  double acc = 0.0;
  for (col = 0; col < app->n_cols; col++)
    {
      double w = (app->col_widths[col] > 0.0) ? app->col_widths[col] : 0.0;
      if (xx < acc + w)
        break;
      acc += w;
    }
  if (app->n_cols > 0 && col >= app->n_cols)
    col = app->n_cols - 1;

  *out_row = row;
  *out_col = col;
  if (in_gutter && in_header)
    return 3;
  if (in_gutter)
    return 1;
  if (in_header)
    return 2;
  return 0;
}

static void
copy_update_affordance (App *app)
{
  if (app->copy_button != NULL)
    gtk_widget_set_sensitive (GTK_WIDGET (app->copy_button),
                              app->doc != NULL && app->sel_mode != SEL_NONE);
}

/* --- the off-main copy worker --- */

static gpointer
copy_worker (gpointer data)
{
  struct _CopyOp *op = data;
  LsgDocument *doc = op->doc;
  guint8 *buf = g_malloc (COPY_CHUNK_BYTES);
  GByteArray *blob = g_byte_array_new ();

  LsgCopyFlow flow = lsg_copy_begin (op->rect, op->budget);
  LsgCopyJob *job = lsg_document_copy_open (doc, op->rect);

  while (job != NULL && flow.kind != LSG_COPY_FLOW_DONE)
    {
      if (g_atomic_int_get (&op->cancel))
        {
          flow = lsg_copy_cancel (flow);
          break;
        }

      /* A stall (row past the demand-driven / still-indexing frontier):
       * advance the shared frontier via a jump, bounded (~2 s), then pull
       * again. The fold's no-progress guard turns a re-stall on the same row
       * into FRONTIER. */
      if (flow.kind == LSG_COPY_FLOW_STALLED)
        {
          lsg_document_jump_start (doc, flow.stalled_row);
          gboolean settled = FALSE;
          for (int i = 0; i < 40; i++) /* 40 * 50 ms = ~2 s */
            {
              if (g_atomic_int_get (&op->cancel))
                break;
              g_usleep (50000);
              if (lsg_document_jump_poll (doc).state == LSG_JUMP_DONE)
                {
                  settled = TRUE;
                  break;
                }
            }
          if (g_atomic_int_get (&op->cancel))
            {
              flow = lsg_copy_cancel (flow);
              break;
            }
          if (!settled)
            {
              flow.kind = LSG_COPY_FLOW_DONE;
              flow.outcome = LSG_COPY_OUTCOME_FRONTIER;
              break;
            }
        }

      LsgCopyStep s = lsg_document_copy_next (job, buf, COPY_CHUNK_BYTES);
      g_byte_array_append (blob, buf, s.written);
      flow = lsg_copy_fold (flow, s);

      g_mutex_lock (&op->lock);
      op->progress = lsg_copy_progress_fraction (flow);
      g_mutex_unlock (&op->lock);
    }

  if (job != NULL)
    lsg_document_copy_close (job); /* leaf: close the job before the doc */
  g_free (buf);

  g_mutex_lock (&op->lock);
  op->blob = blob;
  op->outcome = flow.outcome;
  op->rows_done = flow.rows_done;
  op->progress = lsg_copy_progress_fraction (flow);
  op->finished = TRUE;
  g_mutex_unlock (&op->lock);
  return NULL;
}

/* Join the worker and free the op — NO widget access, so it is safe both
 * during a normal open-new-file reset and at window destroy / process exit. */
static void
copy_dispose (App *app)
{
  if (app->copy_thread != NULL)
    {
      g_thread_join (app->copy_thread);
      app->copy_thread = NULL;
    }
  struct _CopyOp *op = app->copy_op;
  if (op != NULL)
    {
      if (op->blob != NULL)
        g_byte_array_free (op->blob, TRUE);
      g_mutex_clear (&op->lock);
      g_free (op);
      app->copy_op = NULL;
    }
}

static gboolean
copy_tick (gpointer data)
{
  App *app = data;
  struct _CopyOp *op = app->copy_op;
  if (op == NULL)
    {
      app->copy_poll_id = 0;
      return G_SOURCE_REMOVE;
    }
  g_mutex_lock (&op->lock);
  gdouble prog = op->progress;
  gboolean finished = op->finished;
  g_mutex_unlock (&op->lock);

  header_progress_set (app, prog); /* determinate rows_done / row_count */
  if (!finished)
    return G_SOURCE_CONTINUE;

  /* Deliver the payload to the clipboard (widgets alive on this path — the
   * timer is stopped at teardown before the window is gone); a cancelled copy
   * drops its partial. */
  if (op->outcome != LSG_COPY_OUTCOME_CANCELLED && op->blob != NULL
      && op->blob->len > 0 && app->window != NULL)
    {
      GdkClipboard *clip = gtk_widget_get_clipboard (GTK_WIDGET (app->window));
      /* NUL-terminate the payload IN PLACE (one appended byte) so it can go
       * straight to the clipboard — avoids a second ~64 MiB g_strndup copy of
       * the blob; gdk_clipboard_set_text makes its own internal copy of the
       * TSV. */
      guint8 nul = 0;
      g_byte_array_append (op->blob, &nul, 1);
      gdk_clipboard_set_text (clip, (const char *)op->blob->data);
      if (app->title_status != NULL)
        {
          char *note = g_strdup_printf ("Copied %" G_GUINT64_FORMAT " rows",
                                        op->rows_done);
          title_set_status (app, note);
          /* Copy completion (MEDIUM): announce the same copy-complete text. */
          a11y_announce (app, g_strdup (note),
                         GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
          g_free (note);
        }
    }
  header_progress_hide (app);
  copy_dispose (app);
  app->copy_poll_id = 0;
  return G_SOURCE_REMOVE;
}

/* Forward-declared: start a copy of the current selection on the off-main
 * worker. */
static void
do_copy (App *app)
{
  /* app->net != NULL: a URL open is in flight and about to replace the doc —
   * refuse to start a copy of the doomed doc. With copy_stop_and_join at the
   * start of the net-open flow, this closes the other overlap direction so the
   * two never share the header progress. */
  if (app->doc == NULL || app->sel_mode == SEL_NONE || app->copy_op != NULL
      || app->net != NULL)
    return;

  /* The copy worker advances the shared frontier with
   * ls_jump_start(stalled_row) on its bg thread. A jump preserved past its
   * popover would then resolve to LANDED(stalled_row) = a wrong scroll to the
   * copy's stall row. Retire it now, and free the core slot (jump_cancel) so
   * the worker's ls_jump_start has it cleanly — mirrors do_apply_filter's jump
   * retire before a view change. */
  if (app->jump.kind == LSG_JUMP_FLOW_SCANNING)
    lsg_document_jump_cancel (app->doc);
  app->jump = lsg_jump_initial ();

  struct _CopyOp *op = g_new0 (struct _CopyOp, 1);
  op->doc = app->doc;
  op->rect = selection_rect (app);
  op->budget = COPY_BUDGET_BYTES;
  g_mutex_init (&op->lock);
  op->progress = 0.0;
  app->copy_op = op;

  header_progress_show (app, "Copying…");
  app->copy_thread = g_thread_new ("lsg-copy", copy_worker, op);
  if (app->copy_poll_id == 0)
    app->copy_poll_id = g_timeout_add (80, copy_tick, app);
}

/* Forward-declared: stop the worker + dispose (leaf-before-root, before any
 * document teardown). Drops any partial payload (no clipboard). The widget
 * updates are NULL-guarded, so this is also safe at window destroy / exit. */
static void
copy_stop_and_join (App *app)
{
  if (app->copy_op == NULL)
    {
      header_progress_hide (app);
      return;
    }
  g_atomic_int_set (&app->copy_op->cancel, 1);
  if (app->copy_poll_id != 0)
    {
      g_source_remove (app->copy_poll_id);
      app->copy_poll_id = 0;
    }
  copy_dispose (app);           /* join + free (no widgets) */
  header_progress_hide (app);   /* NULL-guarded */
  copy_update_affordance (app); /* NULL-guarded */
}

/* --- drag-to-select + the copy affordance --- */

static void
on_sel_drag_begin (GtkGestureDrag *gesture, double x, double y, gpointer data)
{
  (void)gesture;
  App *app = data;
  if (app->doc == NULL)
    return;

  guint64 row;
  guint col;
  int region = hit_test (app, x, y, &row, &col);
  if (region == 3) /* the corner clears the selection */
    {
      app->sel_mode = SEL_NONE;
      app->selecting = FALSE;
      copy_update_affordance (app);
      gtk_widget_queue_draw (GTK_WIDGET (app->area));
      return;
    }

  app->selecting = TRUE;
  app->sel_a_row = app->sel_b_row = row;
  app->sel_a_col = app->sel_b_col = col;
  app->sel_mode = (region == 1)   ? SEL_ROWS
                  : (region == 2) ? SEL_COLS
                                  : SEL_CELLS;
  gtk_widget_grab_focus (GTK_WIDGET (app->area)); /* so grid Ctrl+C fires */
  copy_update_affordance (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
}

static void
on_sel_drag_update (GtkGestureDrag *gesture, double ox, double oy,
                    gpointer data)
{
  App *app = data;
  if (!app->selecting)
    return;
  double sx = 0, sy = 0;
  gtk_gesture_drag_get_start_point (gesture, &sx, &sy);
  guint64 row;
  guint col;
  hit_test (app, sx + ox, sy + oy, &row, &col);
  app->sel_b_row = row;
  app->sel_b_col = col;
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
}

static void
on_sel_drag_end (GtkGestureDrag *gesture, double ox, double oy, gpointer data)
{
  (void)gesture;
  (void)ox;
  (void)oy;
  App *app = data;
  app->selecting = FALSE;
  copy_update_affordance (app);
}

/* ------------------------------------------------------------------------- */
/* UI construction */
/* ------------------------------------------------------------------------- */

static GtkWidget *
build_launch_page (App *app)
{
  GtkWidget *status = adw_status_page_new ();
  adw_status_page_set_icon_name (ADW_STATUS_PAGE (status),
                                 "x-office-spreadsheet-symbolic");
  adw_status_page_set_title (ADW_STATUS_PAGE (status), "less-sheet");
  adw_status_page_set_description (
      ADW_STATUS_PAGE (status),
      "Open a delimited file, or a CSV over the network.");

  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_widget_set_halign (box, GTK_ALIGN_CENTER);

  GtkWidget *open = gtk_button_new_with_label ("Open File…");
  gtk_widget_add_css_class (open, "pill");
  gtk_widget_add_css_class (open, "suggested-action");
  gtk_widget_set_tooltip_text (open, "Open File (Ctrl+O)");
  g_signal_connect (open, "clicked", G_CALLBACK (action_open), app);

  GtkWidget *open_url = gtk_button_new_with_label ("Open URL…");
  gtk_widget_add_css_class (open_url, "pill");
  gtk_widget_set_tooltip_text (open_url, "Open URL (Ctrl+Shift+O)");
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

  /* The grid is a labeled region for AT (FR3, Decision 3): a GROUP role (set
   * as a construct property — roles are immutable post-construction) + the
   * fixed name "Data grid"; the dynamic description is set from
   * grid_materialize. NOT a per-cell GRID/ROW/CELL tree (the
   * deliberately-deferred deepening). */
  app->area = GTK_DRAWING_AREA (
      g_object_new (GTK_TYPE_DRAWING_AREA, "accessible-role",
                    GTK_ACCESSIBLE_ROLE_GROUP, NULL));
  gtk_accessible_update_property (GTK_ACCESSIBLE (app->area),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  LSG_A11Y_GRID_NAME, -1);
  gtk_widget_set_hexpand (GTK_WIDGET (app->area), TRUE);
  gtk_widget_set_vexpand (GTK_WIDGET (app->area), TRUE);
  gtk_widget_set_focusable (GTK_WIDGET (app->area), TRUE);
  gtk_drawing_area_set_draw_func (app->area, grid_draw, app, NULL);
  g_signal_connect (app->area, "resize", G_CALLBACK (on_area_resize), app);

  GtkWidget *vscroll = gtk_scrollbar_new (GTK_ORIENTATION_VERTICAL, app->vadj);
  GtkWidget *hscroll
      = gtk_scrollbar_new (GTK_ORIENTATION_HORIZONTAL, app->hadj);
  app->hscroll = hscroll;

  g_signal_connect (app->vadj, "value-changed",
                    G_CALLBACK (on_adjustment_changed), app);
  g_signal_connect (app->hadj, "value-changed",
                    G_CALLBACK (on_adjustment_changed), app);

  GtkEventController *scroll = gtk_event_controller_scroll_new (
      GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
  g_signal_connect (scroll, "scroll", G_CALLBACK (on_scroll), app);
  gtk_widget_add_controller (GTK_WIDGET (app->area), scroll);

  GtkEventController *keys = gtk_event_controller_key_new ();
  g_signal_connect (keys, "key-pressed", G_CALLBACK (on_key_pressed), app);
  gtk_widget_add_controller (GTK_WIDGET (app->area), keys);

  /* Drag-to-select a cell rectangle (or whole rows via the gutter / whole
   * columns via the header). */
  GtkGesture *drag = gtk_gesture_drag_new ();
  g_signal_connect (drag, "drag-begin", G_CALLBACK (on_sel_drag_begin), app);
  g_signal_connect (drag, "drag-update", G_CALLBACK (on_sel_drag_update), app);
  g_signal_connect (drag, "drag-end", G_CALLBACK (on_sel_drag_end), app);
  gtk_widget_add_controller (GTK_WIDGET (app->area),
                             GTK_EVENT_CONTROLLER (drag));

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
  (void)widget;
  App *app = data;
  if (!app->timing || app->ui_shown_reported)
    return;
  app->ui_shown_reported = TRUE;
  gint64 dt = g_get_monotonic_time () - app->t_start;
  g_printerr ("[timing] ui cold-start (main -> window mapped): %.1f ms\n",
              (double)dt / 1000.0);
}

/* On window destroy (app quit): stop timers + JOIN the copy worker while the
 * document is still alive (leaf-before-root), then NULL widget pointers so any
 * later teardown code is a guarded no-op (avoids touching freed widgets). */
static void
on_window_destroy (GtkWidget *widget, gpointer data)
{
  (void)widget;
  App *app = data;
  if (app->poll_id != 0)
    {
      g_source_remove (app->poll_id);
      app->poll_id = 0;
    }
  if (app->net_poll_id != 0)
    {
      g_source_remove (app->net_poll_id);
      app->net_poll_id = 0;
    }
  if (app->find_notice_id != 0)
    {
      g_source_remove (app->find_notice_id);
      app->find_notice_id = 0;
    }
  if (app->jump_reject_id != 0)
    {
      g_source_remove (app->jump_reject_id);
      app->jump_reject_id = 0;
    }
  if (app->where_reject_id != 0)
    {
      g_source_remove (app->where_reject_id);
      app->where_reject_id = 0;
    }
  if (app->prefs_infer_poll_id != 0)
    {
      g_source_remove (app->prefs_infer_poll_id);
      app->prefs_infer_poll_id = 0;
    }
  app->window = NULL;
  app->title_box = NULL;
  app->title_name = NULL;
  app->title_status = NULL;
  app->filter_clear_btn = NULL;
  app->find_stack = NULL;
  app->where_column = NULL;
  app->where_op = NULL;
  app->where_value = NULL;
  app->area = NULL;
  app->hp_box = NULL;
  app->hp_bar = NULL;
  app->hp_cancel = NULL;
  app->copy_button = NULL;
  app->header_toggle = NULL;
  app->header_glyph = NULL;
  app->sep_glyph_label = NULL;
  app->quote_glyph_label = NULL;
  app->sep_button = NULL;
  app->quote_button = NULL;
  app->toasts = NULL;
  app->prefs = NULL; /* the dialog is destroyed with the window */
  app->prefs_header_row = NULL;
  app->prefs_sep_row = NULL;
  app->prefs_quote_row = NULL;
  app->prefs_enc_row = NULL;
  app->prefs_columns_group = NULL;
  copy_stop_and_join (app); /* joins the worker; widget calls now no-op */
}

/* ========================================================================= */
/* Settings + dialect override (this slice)                                  */
/*                                                                           */
/* The three header-bar quick-controls (header toggle, separator ▾, quote ▾),*/
/* the Preferences "Parsing" page, and this compose/re-open funnel all read +
 */
/* drive the ONE dialect state (the effective report from
 * lsg_document_dialect*/
/* through the single lsg_dialect_compose funnel. A dialect change is an ABI */
/* re-open (F1); a network doc re-opens through the NETWORK funnel (F8). */
/* ========================================================================= */

/* Separator/quote dropdown item tags (object data on each radio + the item's
 * forced byte). */
#define DIALECT_KIND_SEP 0
#define DIALECT_KIND_QUOTE 1

/* Forward declarations for the settings region (callee-before-caller cycles).
 */
static void settings_present (App *app);
static void columns_group_rebuild (App *app);
static void column_row_sync (App *app, GtkWidget *expander, guint32 col);

/* -------- toast (F3 / F7) ------------------------------------------------ */

static void
settings_toast (App *app, const char *text)
{
  if (app->toasts != NULL)
    {
      AdwToast *t = adw_toast_new (text);
      adw_toast_set_timeout (t,
                             TOAST_TIMEOUT_SECONDS); /* one place, one knob */
      adw_toast_overlay_add_toast (app->toasts, t);
    }
}

/* Set an AdwComboRow's string model (set_model is transfer-none, so drop our
 * creation ref after the row takes its own). */
static void
combo_set_items (GtkWidget *combo, const char *const *items)
{
  GtkStringList *m = gtk_string_list_new (items);
  adw_combo_row_set_model (ADW_COMBO_ROW (combo), G_LIST_MODEL (m));
  g_object_unref (m);
}

/* -------- cached effective type for the cell formatter --------------------
 */

static void
column_cache_effective (App *app, guint32 col)
{
  if (app->doc == NULL || app->col_kind == NULL || col >= app->n_cols)
    return;
  ls_column_metadata m;
  guint64 gen = 0;
  if (lsg_document_column_metadata_get_many (app->doc, &col, 1, &m, 1, &gen)
      == LS_COLUMN_OK)
    {
      app->col_kind[col] = (ls_column_type_kind)m.effective.kind;
      app->col_sem[col]
          = (ls_column_datetime_semantics)m.effective.datetime_semantics;
    }
}

/* -------- re-open capture helpers (F7) ----------------------------------- */

static gboolean
columns_any_authored (App *app)
{
  if (app->col_settings == NULL)
    return FALSE;
  for (guint32 i = 0; i < app->n_cols; i++)
    if (!lsg_column_user_settings_is_default (&app->col_settings[i]))
      return TRUE;
  return FALSE;
}

/* Copy every column's header label out (owned), in bounded LS_COLUMN_BATCH_MAX
 * batches — used only for the F7 re-open identity comparison (never the open
 * path). Returns a fresh n_cols array, or NULL. */
static LsgColumnLabel *
capture_all_labels (App *app, guint *out_n)
{
  guint32 total = app->n_cols;
  *out_n = total;
  if (total == 0 || app->doc == NULL)
    {
      *out_n = 0;
      return NULL;
    }
  LsgColumnLabel *all = g_new0 (LsgColumnLabel, total);
  guint32 done = 0;
  while (done < total)
    {
      guint32 batch = MIN ((guint32)LS_COLUMN_BATCH_MAX, total - done);
      guint32 *ids = g_new (guint32, batch);
      for (guint32 i = 0; i < batch; i++)
        ids[i] = done + i;
      ls_column_result r = LS_COLUMN_INVALID_ARGUMENT;
      LsgColumnLabel *part
          = lsg_document_column_labels_copy_many (app->doc, ids, batch, &r);
      g_free (ids);
      if (part == NULL || r != LS_COLUMN_OK)
        {
          if (part != NULL)
            lsg_column_labels_free (part, batch);
          break; /* leave the rest zeroed -> a short/mismatch drives RESET */
        }
      for (guint32 i = 0; i < batch; i++)
        {
          all[done + i] = part[i]; /* steal the owned bytes */
          part[i].bytes = NULL;
        }
      lsg_column_labels_free (part, batch);
      done += batch;
    }
  return all;
}

/* Build borrowed identity views over an owned label array (freed with it). */
static LsgColumnHeaderIdentity *
labels_to_identities (LsgColumnLabel *labels, guint n)
{
  if (labels == NULL || n == 0)
    return NULL;
  LsgColumnHeaderIdentity *ids = g_new0 (LsgColumnHeaderIdentity, n);
  for (guint i = 0; i < n; i++)
    {
      ids[i].bytes = labels[i].bytes;
      ids[i].len = labels[i].len;
      ids[i].truncated = labels[i].truncated;
    }
  return ids;
}

/* -------- the re-open funnel (F1 / F8) ----------------------------------- */

/* Drop the pending dialect re-open capture. Called on the end of a successful
 * apply, on EVERY re-open failure / cancel path, and defensively at a fresh
 * user open — so a failed re-open never leaves a STALE settings_reopen_apply
 * to fire against the next document (spurious replay/reset + wrong viewport).
 */
static void
reopen_state_clear (App *app)
{
  app->reopen_pending = FALSE;
  g_clear_pointer (&app->reopen_snapshot, g_free);
  if (app->reopen_old_labels != NULL)
    {
      lsg_column_labels_free (app->reopen_old_labels,
                              app->reopen_n_old_labels);
      app->reopen_old_labels = NULL;
      app->reopen_n_old_labels = 0;
    }
  app->reopen_old_count = 0;
}

/* Close + re-open the current document with `options`. Local re-opens
 * synchronously (open_document runs the post-open re-anchor/replay); a NETWORK
 * doc re-opens through the net funnel — never fed to the local open (F8) — and
 * the async net poll adopts into the SAME open_document choke point. Every
 * failure path clears the pending capture so it can never fire stale. */
static void
dialect_reopen (App *app, ls_open_options options)
{
  if (app->is_network)
    {
      if (app->pending_url == NULL)
        {
          reopen_state_clear (app);
          return;
        }
      copy_stop_and_join (app);
      if (app->net != NULL)
        {
          lsg_net_open_cancel (app->net);
          lsg_net_open_release (app->net);
          app->net = NULL;
        }
      app->net = lsg_net_open_start (app->pending_url, &options);
      if (app->net == NULL)
        {
          reopen_state_clear (app);
          show_error (app, "Could not re-open URL",
                      "The open job could not be started.");
          return;
        }
      header_progress_show (app, "Connecting…");
      if (app->net_poll_id == 0)
        app->net_poll_id
            = g_timeout_add (POLL_INTERVAL_MS, net_poll_tick, app);
    }
  else
    {
      if (app->doc_path == NULL)
        {
          reopen_state_clear (app);
          return;
        }
      LsgOpenError err = LSG_OPEN_OK;
      LsgDocument *doc
          = lsg_document_open_local (app->doc_path, &options, &err);
      if (doc == NULL)
        {
          reopen_state_clear (app);
          show_error (app, "Could not re-open file", open_error_text (err));
          return;
        }
      char *base = g_path_get_basename (app->doc_path);
      open_document (app, doc, base, FALSE); /* doc_path preserved by reset */
      g_free (base);
    }
}

/* One user selection -> compose -> validate -> capture -> re-open (F1). A
 * rejected compose is a silent no-op (F2). */
static void
dialect_apply_change (App *app, LsgDialectChange change)
{
  if (app->doc == NULL)
    return;
  LsgDialect report = lsg_document_dialect (app->doc);
  LsgDialectCompose c = lsg_dialect_compose (report, change);
  if (!c.accepted)
    return; /* silent no-op */

  gboolean header_change = (change.kind == LSG_DIALECT_CHANGE_HEADER);
  gboolean new_header = header_change ? change.header_on : report.header;

  reopen_state_clear (app); /* drop any stale capture before the new one */

  app->reopen_pending = TRUE;
  app->reopen_header_change = header_change;
  app->reopen_header_now = new_header;
  /* F5 (header toggle): re-anchor to the SAME top data-row index across the
   * re-open — no ±1 record shift. At the top (index 0) this keeps data row 0
   * pinned, so header->data REVEALS the former-header row as the new data row
   * 0 (it used to be shifted out of view just above the top); when scrolled
   * (index > 0) the scroll position is preserved and only the labels flip. */
  app->reopen_top_view = app->cur_top_row;
  app->reopen_old_count = app->n_cols;

  /* Snapshot the user column settings + (for a byte change over a headered
   * doc) the header identities — only when some settings were authored, so the
   * common all-Auto case does no O(column_count) label work (N1 / N2). */
  if (columns_any_authored (app))
    {
      guint32 nc = (app->n_cols > 0) ? app->n_cols : 1;
      app->reopen_snapshot = g_new0 (LsgColumnUserSettings, nc);
      for (guint32 i = 0; i < app->n_cols; i++)
        app->reopen_snapshot[i] = app->col_settings[i];
      if (!header_change && report.header && app->n_cols > 0)
        app->reopen_old_labels
            = capture_all_labels (app, &app->reopen_n_old_labels);
    }

  dialect_reopen (app, c.options);
}

/* Post-adoption re-anchor (F5) + column replay/reset (F7) + toasts (F3/F7).
 * Runs at the end of open_document for BOTH the local and network re-open. */
static void
settings_reopen_apply (App *app)
{
  app->reopen_pending = FALSE;

  /* --- F5: viewport re-anchor (header toggle only; no ±1 shift) --- */
  if (app->reopen_header_change)
    {
      guint64 row = app->reopen_top_view;
      scroll_to_first_row (app, row);
      grid_materialize (app);
      gtk_widget_queue_draw (GTK_WIDGET (app->area));
      if (app->is_network)
        net_drive_begin (app, row); /* F8: net funnel drives the landing */
      settings_toast (app, app->reopen_header_now ? "First row is now a header"
                                                  : "First row is now data");
    }
  /* separator/quote/encoding rest at top-left (open_document already did). */

  /* --- F7: column-settings replay or reset --- */
  if (app->reopen_snapshot != NULL)
    {
      LsgColumnReopenChange kind
          = app->reopen_header_change
                ? LSG_COLUMN_REOPEN_HEADER_ONLY
                : LSG_COLUMN_REOPEN_SEPARATOR_QUOTE_ENCODING;

      LsgColumnHeaderIdentity *old_ids = NULL, *new_ids = NULL;
      guint n_old = 0, n_new = 0;
      LsgColumnLabel *new_labels = NULL;
      if (!app->reopen_header_change && app->reopen_old_labels != NULL
          && app->n_cols > 0 && lsg_document_has_header (app->doc))
        {
          new_labels = capture_all_labels (app, &n_new);
          if (new_labels != NULL && n_new == app->n_cols)
            {
              n_old = app->reopen_n_old_labels;
              old_ids = labels_to_identities (app->reopen_old_labels, n_old);
              new_ids = labels_to_identities (new_labels, n_new);
            }
        }

      LsgColumnReopenDecision decision
          = lsg_column_reopen_decide (kind, app->reopen_old_count, app->n_cols,
                                      old_ids, n_old, new_ids, n_new);
      g_free (old_ids);
      g_free (new_ids);
      if (new_labels != NULL)
        lsg_column_labels_free (new_labels, n_new);

      if (decision == LSG_COLUMN_REOPEN_REPLAY)
        {
          guint32 n = MIN (app->reopen_old_count, app->n_cols);
          for (guint32 i = 0; i < n; i++)
            {
              LsgColumnUserSettings s = app->reopen_snapshot[i];
              app->col_settings[i] = s; /* format / hidden / width */
              if (s.hidden && app->col_widths != NULL)
                app->col_widths[i] = 0.0; /* keep hidden cols out of layout */
              if (s.has_override)
                {
                  ls_column_type t = lsg_column_override_type (
                      (ls_column_type_kind)s.override.kind,
                      (ls_column_datetime_semantics)
                          s.override.datetime_semantics);
                  lsg_document_column_override_set (app->doc, i, &t);
                }
              if (s.has_null_sentinel)
                lsg_document_column_null_sentinel_set (
                    app->doc, i, s.null_sentinel_len ? s.null_sentinel : NULL,
                    s.null_sentinel_len);
              /* Cache the effective type ONLY for columns that feed the
               * formatter — never O(column_count) metadata reads on a wide
               * doc (N2: O(visible) column work). A pure-default column needs
               * no cache (it paints raw). */
              if (s.has_override
                  || !lsg_column_format_options_is_auto (s.format))
                column_cache_effective (app, i);
            }
          grid_materialize (app);
          gtk_widget_queue_draw (GTK_WIDGET (app->area));
        }
      else
        {
          /* RESET: the fresh col_settings are already all-Auto; just notify.
           */
          settings_toast (app, "Column settings were reset — columns changed");
        }
    }

  /* Refresh an open Columns page against the re-parsed document. */
  if (app->prefs != NULL && app->prefs_columns_group != NULL)
    columns_group_rebuild (app);

  reopen_state_clear (app);
}

/* -------- quick-control reflection --------------------------------------- */

static const char *
sep_short_label (guint8 b)
{
  switch (b)
    {
    case ',':
      return "Comma ,";
    case ';':
      return "Semicolon ;";
    case '\t':
      return "Tab ⇥";
    case '|':
      return "Pipe |";
    default:
      return "Custom";
    }
}

static const char *
quote_short_label (gboolean has_quote, guint8 b)
{
  if (!has_quote)
    return "None";
  switch (b)
    {
    case '"':
      return "Double \"";
    case '\'':
      return "Single '";
    default:
      return "Custom";
    }
}

/* Header-bar quick-control button labels: the GLYPH ONLY (compact). A custom
 * byte (validated ASCII 0x01..0x7F by the compose funnel) renders as its
 * literal character; a disabled quote renders as the ∅ "none" marker. The
 * returned pointer is either a string literal or a module-static one-char
 * buffer — read immediately (main thread), never stored. */
static const char *
sep_glyph (guint8 b)
{
  switch (b)
    {
    case ',':
      return ",";
    case ';':
      return ";";
    case '\t':
      return "⇥";
    case '|':
      return "|";
    default:
      {
        static char buf[2];
        buf[0] = (char)b;
        buf[1] = '\0';
        return buf;
      }
    }
}

static const char *
quote_glyph (gboolean has_quote, guint8 b)
{
  if (!has_quote)
    return "∅";
  switch (b)
    {
    case '"':
      return "\"";
    case '\'':
      return "'";
    default:
      {
        static char buf[2];
        buf[0] = (char)b;
        buf[1] = '\0';
        return buf;
      }
    }
}

/* Reflect the effective dialect into the open Parsing page (guarded so the
 * programmatic set never re-enters the compose funnel). */
static void
parsing_page_sync (App *app, LsgDialect d)
{
  if (app->prefs == NULL)
    return;
  const guint8 *seps = lsg_dialect_separator_candidates ();
  const guint8 *quotes = lsg_dialect_quote_candidates ();

  if (app->prefs_header_row != NULL)
    adw_switch_row_set_active (ADW_SWITCH_ROW (app->prefs_header_row),
                               d.header);

  if (app->prefs_sep_row != NULL)
    {
      guint idx = 4; /* Custom… */
      for (guint i = 0; i < LSG_DIALECT_SEPARATOR_CANDIDATE_COUNT; i++)
        if (seps[i] == d.separator)
          {
            idx = i;
            break;
          }
      adw_combo_row_set_selected (ADW_COMBO_ROW (app->prefs_sep_row), idx);
      char *sub = g_strdup_printf ("%s: %s",
                                   d.separator_forced ? "forced" : "detected",
                                   sep_short_label (d.separator));
      adw_action_row_set_subtitle (ADW_ACTION_ROW (app->prefs_sep_row), sub);
      g_free (sub);
    }

  if (app->prefs_quote_row != NULL)
    {
      guint idx = 3; /* Custom… */
      if (!d.has_quote)
        idx = 2; /* None */
      else
        for (guint i = 0; i < LSG_DIALECT_QUOTE_CANDIDATE_COUNT; i++)
          if (quotes[i] == d.quote)
            {
              idx = i;
              break;
            }
      adw_combo_row_set_selected (ADW_COMBO_ROW (app->prefs_quote_row), idx);
      char *sub
          = g_strdup_printf ("%s: %s", d.quote_forced ? "forced" : "detected",
                             quote_short_label (d.has_quote, d.quote));
      adw_action_row_set_subtitle (ADW_ACTION_ROW (app->prefs_quote_row), sub);
      g_free (sub);
    }

  if (app->prefs_enc_row != NULL)
    {
      LsgEncoding sel = lsg_encoding_picker_selection (d);
      LsgEncoding det = lsg_encoding_picker_detected (d);
      static const char *names[LSG_ENCODING_PICKER_OPTION_COUNT]
          = { "Automatic", "UTF-8",      "UTF-16 LE",
              "UTF-16 BE", "ISO-8859-1", "Windows-1252" };
      /* Selection maps AUTO->0, else the concrete value + 1 (fixed order). */
      guint sidx = (sel == LSG_ENCODING_AUTO) ? 0 : (guint)(sel + 1);
      adw_combo_row_set_selected (ADW_COMBO_ROW (app->prefs_enc_row), sidx);
      guint didx = (guint)(det + 1);
      if (didx < LSG_ENCODING_PICKER_OPTION_COUNT)
        {
          char *sub = g_strdup_printf ("detected: %s", names[didx]);
          adw_action_row_set_subtitle (ADW_ACTION_ROW (app->prefs_enc_row),
                                       sub);
          g_free (sub);
        }
    }
}

static void
dialect_sync_quick_controls (App *app)
{
  if (app->doc == NULL)
    return;
  LsgDialect d = lsg_document_dialect (app->doc);
  app->dialect_ui_guard = TRUE;
  if (app->header_toggle != NULL)
    gtk_toggle_button_set_active (app->header_toggle, d.header);
  if (app->header_glyph != NULL)
    gtk_widget_queue_draw (
        app->header_glyph); /* solid H <-> faint H + slash */
  if (app->sep_glyph_label != NULL)
    gtk_label_set_text (app->sep_glyph_label, sep_glyph (d.separator));
  if (app->quote_glyph_label != NULL)
    gtk_label_set_text (app->quote_glyph_label,
                        quote_glyph (d.has_quote, d.quote));
  parsing_page_sync (app, d);
  app->dialect_ui_guard = FALSE;
}

/* -------- header-bar quick controls (F3 / F3b) --------------------------- */

static void
on_header_toggle_toggled (GtkToggleButton *btn, gpointer data)
{
  App *app = data;
  if (app->header_glyph != NULL)
    gtk_widget_queue_draw (app->header_glyph); /* reflect the new H/slash */
  if (app->dialect_ui_guard)
    return;
  dialect_apply_change (
      app, lsg_dialect_change_header (gtk_toggle_button_get_active (btn)));
}

/*
 * A separator/quote preset ROW was clicked in a header-bar dropdown. The
 * dropdown is a plain (autohide) GtkPopover holding a GtkListBox of presets
 * plus an always-visible "Custom" entry below the list; a preset applies the
 * change and popdowns, while a custom byte is typed into the entry and applied
 * on its Enter (on_dialect_custom_activate). No GtkPopoverMenu / menu-model
 * and no radios, so nothing auto-dismisses on activation.
 */
static void
on_dialect_row_activated (GtkListBox *list, GtkListBoxRow *row, gpointer data)
{
  App *app = data;
  if (app->dialect_ui_guard)
    return;

  GtkWidget *pop
      = gtk_widget_get_ancestor (GTK_WIDGET (list), GTK_TYPE_POPOVER);
  int kind = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (row), "lsg-kind"));
  gboolean is_none = g_object_get_data (G_OBJECT (row), "lsg-none") != NULL;

  if (kind == DIALECT_KIND_SEP)
    {
      guint8 b = (guint8)GPOINTER_TO_INT (
          g_object_get_data (G_OBJECT (row), "lsg-byte"));
      dialect_apply_change (app, lsg_dialect_change_separator (b));
    }
  else if (is_none)
    dialect_apply_change (app, lsg_dialect_change_quote_none ());
  else
    {
      guint8 b = (guint8)GPOINTER_TO_INT (
          g_object_get_data (G_OBJECT (row), "lsg-byte"));
      dialect_apply_change (app, lsg_dialect_change_quote (b));
    }
  if (pop != NULL)
    gtk_popover_popdown (GTK_POPOVER (pop)); /* only a VALID pick dismisses */
}

static void
on_dialect_custom_activate (GtkWidget *entry, gpointer data)
{
  App *app = data;
  int kind
      = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (entry), "lsg-kind"));
  guint8 b = 0;
  if (lsg_dialect_parse_custom_byte (
          gtk_editable_get_text (GTK_EDITABLE (entry)), &b))
    {
      if (kind == DIALECT_KIND_SEP)
        dialect_apply_change (app, lsg_dialect_change_separator (b));
      else
        dialect_apply_change (app, lsg_dialect_change_quote (b));
      GtkWidget *pop = gtk_widget_get_ancestor (entry, GTK_TYPE_POPOVER);
      if (pop != NULL)
        gtk_popover_popdown (GTK_POPOVER (pop));
    }
  /* An invalid byte is a silent no-op (F3b) — leave the entry for a retry. */
}

/* Append one clickable preset ROW to the dropdown list (no radios): the
 * CHARACTER glyph far-LEFT and the DIMMED name far-RIGHT (space-between), no
 * parentheses. The row is activatable, so Adwaita highlights it on hover. */
static void
add_dialect_row (GtkWidget *list, const char *glyph, const char *name,
                 int kind, int byte, gboolean is_none)
{
  GtkWidget *row = gtk_list_box_row_new ();
  GtkWidget *rb = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_widget_set_margin_start (rb, 10);
  gtk_widget_set_margin_end (rb, 10);
  gtk_widget_set_margin_top (rb, 6);
  gtk_widget_set_margin_bottom (rb, 6);
  GtkWidget *gl = gtk_label_new (glyph); /* character, at the start */
  gtk_widget_set_halign (gl, GTK_ALIGN_START);
  GtkWidget *nl = gtk_label_new (name); /* dimmed name, pushed to the end */
  gtk_widget_add_css_class (nl, "dim-label");
  gtk_widget_set_hexpand (nl, TRUE);
  gtk_widget_set_halign (nl, GTK_ALIGN_END);
  gtk_box_append (GTK_BOX (rb), gl);
  gtk_box_append (GTK_BOX (rb), nl);
  gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), rb);
  g_object_set_data (G_OBJECT (row), "lsg-kind", GINT_TO_POINTER (kind));
  g_object_set_data (G_OBJECT (row), "lsg-byte", GINT_TO_POINTER (byte));
  if (is_none)
    g_object_set_data (G_OBJECT (row), "lsg-none", GINT_TO_POINTER (1));
  gtk_list_box_append (GTK_LIST_BOX (list), row);
}

static GtkWidget *
build_dialect_dropdown_popover (App *app, int kind)
{
  GtkWidget *pop = gtk_popover_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  gtk_widget_set_margin_top (box, 6);
  gtk_widget_set_margin_bottom (box, 6);
  gtk_widget_set_margin_start (box, 6);
  gtk_widget_set_margin_end (box, 6);

  /* A plain clickable presets list (hover-highlighted rows), NOT radios and
   * NOT a menu-model. The `.lsg-flat-list` class drops the GtkListBox's own
   * `@view_bg_color` fill so the standard popover background shows through
   * (matching Find/Jump) on both light and dark themes. A preset applies +
   * popdowns via on_dialect_row_activated. */
  GtkWidget *list = gtk_list_box_new ();
  gtk_list_box_set_selection_mode (GTK_LIST_BOX (list), GTK_SELECTION_NONE);
  gtk_widget_add_css_class (list, "lsg-flat-list");
  g_signal_connect (list, "row-activated",
                    G_CALLBACK (on_dialect_row_activated), app);

  if (kind == DIALECT_KIND_SEP)
    {
      const guint8 *s = lsg_dialect_separator_candidates ();
      add_dialect_row (list, ",", "Comma", kind, s[0], FALSE);
      add_dialect_row (list, ";", "Semicolon", kind, s[1], FALSE);
      add_dialect_row (list, "⇥", "Tab", kind, s[2], FALSE);
      add_dialect_row (list, "|", "Pipe", kind, s[3], FALSE);
    }
  else
    {
      const guint8 *q = lsg_dialect_quote_candidates ();
      add_dialect_row (list, "\"", "Double", kind, q[0], FALSE);
      add_dialect_row (list, "'", "Single", kind, q[1], FALSE);
      add_dialect_row (list, "∅", "None", kind, 0, TRUE);
    }

  /* An ALWAYS-visible one-char custom entry below the presets: placeholder
   * "Custom" (vanishes on type); Enter parses + applies via the compose funnel
   * (on_dialect_custom_activate). No separate "Custom…" row. */
  GtkWidget *entry = gtk_entry_new ();
  gtk_entry_set_max_length (GTK_ENTRY (entry), 1);
  gtk_entry_set_placeholder_text (GTK_ENTRY (entry), "Custom");
  g_object_set_data (G_OBJECT (entry), "lsg-kind", GINT_TO_POINTER (kind));
  g_signal_connect (entry, "activate", G_CALLBACK (on_dialect_custom_activate),
                    app);

  gtk_box_append (GTK_BOX (box), list);
  gtk_box_append (GTK_BOX (box), entry);
  gtk_popover_set_child (GTK_POPOVER (pop), box);
  return pop;
}

/* -------- primary menu: Preferences / Keyboard Shortcuts / About --------- */

/* The native shortcuts surface (Decision 1: AdwShortcutsDialog, the modern
 * replacement for the deprecated GtkShortcutsWindow) generated ENTIRELY from
 * the single lsg_a11y accelerator table — one AdwShortcutsSection per group,
 * one AdwShortcutsItem per command. APP-scope entries use the action name so
 * the displayed accelerator is resolved from the registered app accels (which
 * the SAME table drives); GRID / DISPLAY entries carry the table's accel /
 * display token directly. No hand-typed list anywhere (FR5 / G-A4). */
static void
action_shortcuts (GSimpleAction *a, GVariant *p, gpointer data)
{
  (void)a;
  (void)p;
  App *app = data;
  if (app->window == NULL)
    return;

  static const char *const group_titles[] = {
    [LSG_A11Y_GROUP_GENERAL] = "General",
    [LSG_A11Y_GROUP_FIND] = "Find",
    [LSG_A11Y_GROUP_NAVIGATION] = "Navigation",
    [LSG_A11Y_GROUP_SELECTION] = "Selection",
  };

  guint n = 0;
  const LsgA11yShortcut *t = lsg_a11y_shortcuts (&n);
  AdwDialog *dlg = adw_shortcuts_dialog_new ();

  for (guint g = 0; g < G_N_ELEMENTS (group_titles); g++)
    {
      AdwShortcutsSection *sec = adw_shortcuts_section_new (group_titles[g]);
      for (guint i = 0; i < n; i++)
        {
          if ((guint)t[i].group != g)
            continue;
          AdwShortcutsItem *item;
          if (t[i].scope == LSG_A11Y_SCOPE_APP && t[i].action_name != NULL)
            {
              /* Accelerator(s) resolved from the registered app action —
               * single-sourced, and shows every registered alternative (e.g.
               * both Ctrl+G and Ctrl+L for Jump). */
              item = adw_shortcuts_item_new_from_action (t[i].title,
                                                         t[i].action_name);
            }
          else
            {
              /* GRID / DISPLAY: the table's accel string / display token
               * (accel2 is NULL for every non-APP entry). */
              item = adw_shortcuts_item_new (t[i].title, t[i].accel);
            }
          adw_shortcuts_section_add (sec, item); /* takes ownership */
        }
      adw_shortcuts_dialog_add (ADW_SHORTCUTS_DIALOG (dlg),
                                sec); /* takes ownership */
    }

  adw_dialog_present (dlg, GTK_WIDGET (app->window));
}

static void
action_about (GSimpleAction *a, GVariant *p, gpointer data)
{
  (void)a;
  (void)p;
  App *app = data;
  if (app->window == NULL)
    return;
  AdwDialog *about = ADW_DIALOG (adw_about_dialog_new ());
  adw_about_dialog_set_application_name (ADW_ABOUT_DIALOG (about),
                                         "less-sheet");
  adw_about_dialog_set_application_icon (ADW_ABOUT_DIALOG (about), LSG_APP_ID);
  adw_about_dialog_set_developer_name (ADW_ABOUT_DIALOG (about), "less-sheet");
  /* LSG_VERSION is meson.project_version(), i.e. the root VERSION file: the
   * displayed version is never hand-typed here. */
  adw_about_dialog_set_version (ADW_ABOUT_DIALOG (about), LSG_VERSION);
  adw_about_dialog_set_comments (ADW_ABOUT_DIALOG (about),
                                 "A fast viewer for large delimited files.");
  adw_about_dialog_set_license_type (ADW_ABOUT_DIALOG (about),
                                     GTK_LICENSE_MIT_X11);
  adw_dialog_present (about, GTK_WIDGET (app->window));
}

static void
action_preferences (GSimpleAction *a, GVariant *p, gpointer data)
{
  (void)a;
  (void)p;
  settings_present ((App *)data);
}

static GMenuModel *
build_primary_menu (App *app)
{
  (void)app;
  /* Preferences / Shortcuts / About are now APP-level GActions (registered in
   * register_app_shortcuts, so their accelerators are real and the menu shares
   * the one action set); the menu just references them. */
  GMenu *menu = g_menu_new ();
  g_menu_append (menu, "Preferences", "app.preferences");
  g_menu_append (menu, "Keyboard Shortcuts", "app.shortcuts");
  g_menu_append (menu, "About less-sheet", "app.about");
  return G_MENU_MODEL (menu);
}

/* ========================================================================= */
/* Preferences dialog: "Parsing" + "Columns" pages                           */
/* ========================================================================= */

static void
on_prefs_closed (AdwDialog *dialog, gpointer data)
{
  (void)dialog;
  App *app = data;
  if (app->prefs_infer_poll_id != 0)
    {
      g_source_remove (app->prefs_infer_poll_id);
      app->prefs_infer_poll_id = 0;
    }
  if (app->doc != NULL)
    lsg_document_column_inference_cancel (app->doc); /* free the core job */
  app->prefs = NULL;
  app->prefs_header_row = NULL;
  app->prefs_sep_row = NULL;
  app->prefs_sep_custom = NULL;
  app->prefs_quote_row = NULL;
  app->prefs_quote_custom = NULL;
  app->prefs_enc_row = NULL;
  app->prefs_columns_group = NULL;
  app->prefs_columns_search = NULL;
  app->prefs_columns_status = NULL;
  app->prefs_infer_row = NULL;
}

/* -------- Parsing page --------------------------------------------------- */

static void
on_parsing_header_active (GObject *row, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  dialect_apply_change (app,
                        lsg_dialect_change_header (
                            adw_switch_row_get_active (ADW_SWITCH_ROW (row))));
}

static void
on_parsing_sep_selected (GObject *row, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  guint idx = adw_combo_row_get_selected (ADW_COMBO_ROW (row));
  if (idx == 4) /* Custom… */
    {
      if (app->prefs_sep_custom != NULL)
        {
          gtk_widget_set_visible (app->prefs_sep_custom, TRUE);
          gtk_widget_grab_focus (app->prefs_sep_custom);
        }
      return;
    }
  const guint8 *s = lsg_dialect_separator_candidates ();
  if (idx < LSG_DIALECT_SEPARATOR_CANDIDATE_COUNT)
    dialect_apply_change (app, lsg_dialect_change_separator (s[idx]));
}

static void
on_parsing_quote_selected (GObject *row, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  guint idx = adw_combo_row_get_selected (ADW_COMBO_ROW (row));
  const guint8 *q = lsg_dialect_quote_candidates ();
  if (idx == 2) /* None */
    dialect_apply_change (app, lsg_dialect_change_quote_none ());
  else if (idx == 3) /* Custom… */
    {
      if (app->prefs_quote_custom != NULL)
        {
          gtk_widget_set_visible (app->prefs_quote_custom, TRUE);
          gtk_widget_grab_focus (app->prefs_quote_custom);
        }
    }
  else if (idx < LSG_DIALECT_QUOTE_CANDIDATE_COUNT)
    dialect_apply_change (app, lsg_dialect_change_quote (q[idx]));
}

static void
on_parsing_enc_selected (GObject *row, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  guint idx = adw_combo_row_get_selected (ADW_COMBO_ROW (row));
  const LsgEncoding *opts = lsg_encoding_picker_options ();
  if (idx < LSG_ENCODING_PICKER_OPTION_COUNT)
    dialect_apply_change (app, lsg_dialect_change_encoding (opts[idx]));
}

static void
on_parsing_sep_custom_apply (GtkWidget *entry, gpointer data)
{
  App *app = data;
  guint8 b = 0;
  if (lsg_dialect_parse_custom_byte (
          gtk_editable_get_text (GTK_EDITABLE (entry)), &b))
    dialect_apply_change (app, lsg_dialect_change_separator (b));
}

static void
on_parsing_quote_custom_apply (GtkWidget *entry, gpointer data)
{
  App *app = data;
  guint8 b = 0;
  if (lsg_dialect_parse_custom_byte (
          gtk_editable_get_text (GTK_EDITABLE (entry)), &b))
    dialect_apply_change (app, lsg_dialect_change_quote (b));
}

static GtkWidget *
build_parsing_page (App *app)
{
  GtkWidget *page = adw_preferences_page_new ();
  adw_preferences_page_set_title (ADW_PREFERENCES_PAGE (page), "Parsing");
  adw_preferences_page_set_icon_name (ADW_PREFERENCES_PAGE (page),
                                      "document-properties-symbolic");

  GtkWidget *grp = adw_preferences_group_new ();
  adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (grp),
                                   "File parsing");

  /* Header switch. */
  GtkWidget *hdr = adw_switch_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (hdr),
                                 "First row is a header");
  app->prefs_header_row = hdr;
  g_signal_connect (hdr, "notify::active",
                    G_CALLBACK (on_parsing_header_active), app);
  adw_preferences_group_add (ADW_PREFERENCES_GROUP (grp), hdr);

  /* Separator combo + custom entry. */
  GtkWidget *sep = adw_combo_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (sep), "Field separator");
  const char *sep_items[]
      = { "Comma", "Semicolon", "Tab", "Pipe", "Custom…", NULL };
  combo_set_items (sep, sep_items);
  app->prefs_sep_row = sep;
  g_signal_connect (sep, "notify::selected",
                    G_CALLBACK (on_parsing_sep_selected), app);
  adw_preferences_group_add (ADW_PREFERENCES_GROUP (grp), sep);

  GtkWidget *sepc = adw_entry_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (sepc),
                                 "Custom separator (one character)");
  gtk_widget_set_visible (sepc, FALSE);
  app->prefs_sep_custom = sepc;
  g_signal_connect (sepc, "apply", G_CALLBACK (on_parsing_sep_custom_apply),
                    app);
  adw_preferences_group_add (ADW_PREFERENCES_GROUP (grp), sepc);

  /* Quote combo + custom entry. */
  GtkWidget *quote = adw_combo_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (quote),
                                 "Quote character");
  const char *q_items[]
      = { "Double quote", "Single quote", "None", "Custom…", NULL };
  combo_set_items (quote, q_items);
  app->prefs_quote_row = quote;
  g_signal_connect (quote, "notify::selected",
                    G_CALLBACK (on_parsing_quote_selected), app);
  adw_preferences_group_add (ADW_PREFERENCES_GROUP (grp), quote);

  GtkWidget *quotec = adw_entry_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (quotec),
                                 "Custom quote (one character)");
  gtk_widget_set_visible (quotec, FALSE);
  app->prefs_quote_custom = quotec;
  g_signal_connect (quotec, "apply",
                    G_CALLBACK (on_parsing_quote_custom_apply), app);
  adw_preferences_group_add (ADW_PREFERENCES_GROUP (grp), quotec);

  /* Encoding combo. */
  GtkWidget *enc = adw_combo_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (enc), "Text encoding");
  const char *enc_items[]
      = { "Automatic",  "UTF-8",        "UTF-16 LE", "UTF-16 BE",
          "ISO-8859-1", "Windows-1252", NULL };
  combo_set_items (enc, enc_items);
  app->prefs_enc_row = enc;
  g_signal_connect (enc, "notify::selected",
                    G_CALLBACK (on_parsing_enc_selected), app);
  adw_preferences_group_add (ADW_PREFERENCES_GROUP (grp), enc);

  adw_preferences_page_add (ADW_PREFERENCES_PAGE (page),
                            ADW_PREFERENCES_GROUP (grp));

  if (app->doc != NULL)
    {
      LsgDialect d = lsg_document_dialect (app->doc);
      app->dialect_ui_guard = TRUE;
      parsing_page_sync (app, d);
      app->dialect_ui_guard = FALSE;
    }
  return page;
}

/* -------- Columns page --------------------------------------------------- */

/* Repaint the grid after a column mutation (F13 — the GTK REPAINT-FAMILY
 * analog: a synchronous poke, never wait for scroll). */
static void
column_repaint (App *app)
{
  grid_materialize (app);
  gtk_widget_queue_draw (GTK_WIDGET (app->area));
}

/* Map a type combo index to a kind (0 == Auto). */
static ls_column_type_kind
type_index_to_kind (guint idx)
{
  switch (idx)
    {
    case 1:
      return LS_COLUMN_TYPE_TEXT;
    case 2:
      return LS_COLUMN_TYPE_BOOLEAN;
    case 3:
      return LS_COLUMN_TYPE_INTEGER;
    case 4:
      return LS_COLUMN_TYPE_DECIMAL;
    case 5:
      return LS_COLUMN_TYPE_DATE;
    case 6:
      return LS_COLUMN_TYPE_DATETIME;
    default:
      return LS_COLUMN_TYPE_UNKNOWN; /* Auto */
    }
}

static guint
kind_to_type_index (ls_column_type_kind kind)
{
  switch (kind)
    {
    case LS_COLUMN_TYPE_TEXT:
      return 1;
    case LS_COLUMN_TYPE_BOOLEAN:
      return 2;
    case LS_COLUMN_TYPE_INTEGER:
      return 3;
    case LS_COLUMN_TYPE_DECIMAL:
      return 4;
    case LS_COLUMN_TYPE_DATE:
      return 5;
    case LS_COLUMN_TYPE_DATETIME:
      return 6;
    default:
      return 0;
    }
}

static guint32
col_of (GtkWidget *w)
{
  return (guint32)GPOINTER_TO_UINT (
      g_object_get_data (G_OBJECT (w), "lsg-col"));
}

/* Re-apply the column's type override (or clear it) from its user settings. */
static void
column_apply_type (App *app, guint32 col)
{
  LsgColumnUserSettings *s = &app->col_settings[col];
  if (s->has_override)
    {
      ls_column_type t = lsg_column_override_type (
          (ls_column_type_kind)s->override.kind,
          (ls_column_datetime_semantics)s->override.datetime_semantics);
      lsg_document_column_override_set (app->doc, col, &t);
    }
  else
    lsg_document_column_override_clear (app->doc, col);
  column_cache_effective (app, col);
}

/* A one-line summary of column `col`'s CURRENT settings, for the collapsed
 * row subtitle (seen at a glance before expanding): the effective/forced type,
 * then any format / visibility / width / null-sentinel that is set. OWNED
 * (g_free). */
static char *
column_summary_dup (App *app, guint32 col)
{
  static const char *kn[]
      = { "Unknown", "Unsupported", "Text", "Boolean",
          "Integer", "Decimal",     "Date", "Date & time" };
  static const char *dp[] = { "Original", "Short", "Medium", "Long" };
  LsgColumnUserSettings *s = &app->col_settings[col];
  ls_column_type_kind kind = s->has_override
                                 ? (ls_column_type_kind)s->override.kind
                                 : app->col_kind[col];
  guint ki = (guint)kind;
  GString *g = g_string_new (NULL);
  if (s->has_override)
    g_string_append_printf (g, "%s (forced)",
                            (ki < G_N_ELEMENTS (kn)) ? kn[ki] : "Text");
  else if (kind >= LS_COLUMN_TYPE_TEXT && ki < G_N_ELEMENTS (kn))
    g_string_append (g, kn[ki]);
  else
    g_string_append (g, "Auto");
  if (s->hidden)
    g_string_append (g, " · Hidden");
  if (s->format.grouping)
    g_string_append (g, " · grouping");
  if (s->format.has_fraction_digits)
    g_string_append_printf (g, " · %d frac", s->format.fraction_digits);
  if ((kind == LS_COLUMN_TYPE_DATE || kind == LS_COLUMN_TYPE_DATETIME)
      && (guint)s->format.date_preset > 0
      && (guint)s->format.date_preset < G_N_ELEMENTS (dp))
    g_string_append_printf (g, " · %s", dp[(guint)s->format.date_preset]);
  if (s->has_null_sentinel)
    {
      if (s->null_sentinel_len > 0)
        {
          char *v
              = lsg_utf8_sanitize_dup (s->null_sentinel, s->null_sentinel_len);
          g_string_append_printf (g, " · null=%s", v);
          g_free (v);
        }
      else
        g_string_append (g, " · null=empty");
    }
  if (s->has_manual_width)
    g_string_append_printf (g, " · %.0fpx", s->manual_width);
  return g_string_free (g, FALSE);
}

/* Refresh the collapsed-row settings summary of every displayed column (the
 * subtitle on each expander). Cheap — O(<=10 displayed rows). */
static void
columns_refresh_summaries (App *app)
{
  if (app->prefs_columns_group == NULL)
    return;
  GPtrArray *rows
      = g_object_get_data (G_OBJECT (app->prefs_columns_group), "lsg-rows");
  if (rows == NULL)
    return;
  for (guint i = 0; i < rows->len; i++)
    {
      GtkWidget *exp = g_ptr_array_index (rows, i);
      guint32 col
          = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (exp), "lsg-col"));
      if (col >= app->n_cols)
        continue;
      char *sum = column_summary_dup (app, col);
      adw_expander_row_set_subtitle (ADW_EXPANDER_ROW (exp), sum);
      g_free (sum);
    }
}

/* Set column `col`'s visibility. A hidden column is removed from the grid by
 * pinning its layout width to 0 (the frozen lsg_grid_column_window treats a
 * 0/negative width as contributing no space, so following columns close the
 * gap and the contiguous fetch just draws it at zero width); showing it again
 * restores its manual width, else re-samples the auto width. O(1) per column
 * (plus one head-window sample on show) — no per-frame O(column_count) work.
 */
static void
set_column_hidden (App *app, guint32 col, gboolean hidden)
{
  if (app->col_settings == NULL || app->col_widths == NULL
      || col >= app->n_cols)
    return;
  app->col_settings[col].hidden = hidden;
  if (hidden)
    app->col_widths[col] = 0.0;
  else if (app->col_settings[col].has_manual_width)
    app->col_widths[col] = app->col_settings[col].manual_width;
  else
    sample_one_column_width (app, col); /* restore the auto width */
}

static void
on_col_visibility (GtkCheckButton *check, gpointer data)
{
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  guint32 col = col_of (GTK_WIDGET (check));
  if (col < app->n_cols)
    {
      set_column_hidden (app, col, !gtk_check_button_get_active (check));
      grid_update_hadjustment (app); /* total width changed */
      column_repaint (app); /* F13 synchronous poke — hide/show live */
      columns_refresh_summaries (app);
    }
}

static void
on_col_type (GObject *row, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  guint32 col = col_of (GTK_WIDGET (row));
  if (col >= app->n_cols)
    return;
  guint idx = adw_combo_row_get_selected (ADW_COMBO_ROW (row));
  ls_column_type_kind kind = type_index_to_kind (idx);
  LsgColumnUserSettings *s = &app->col_settings[col];
  if (kind == LS_COLUMN_TYPE_UNKNOWN)
    {
      s->has_override = FALSE;
    }
  else
    {
      s->has_override = TRUE;
      s->override = lsg_column_override_type (
          kind, (kind == LS_COLUMN_TYPE_DATETIME) ? LS_COLUMN_DATETIME_NAIVE
                                                  : LS_COLUMN_DATETIME_NONE);
    }
  column_apply_type (app, col);
  /* Reveal/hide the datetime-semantics + format rows for the new kind. */
  GtkWidget *expander
      = gtk_widget_get_ancestor (GTK_WIDGET (row), ADW_TYPE_EXPANDER_ROW);
  if (expander != NULL)
    column_row_sync (app, expander, col);
  column_repaint (app);
}

static void
on_col_datetime_sem (GObject *row, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  guint32 col = col_of (GTK_WIDGET (row));
  if (col >= app->n_cols)
    return;
  LsgColumnUserSettings *s = &app->col_settings[col];
  if (!s->has_override || s->override.kind != LS_COLUMN_TYPE_DATETIME)
    return;
  guint idx = adw_combo_row_get_selected (ADW_COMBO_ROW (row));
  ls_column_datetime_semantics sem
      = (idx == 1) ? LS_COLUMN_DATETIME_ZONED : LS_COLUMN_DATETIME_NAIVE;
  s->override = lsg_column_override_type (LS_COLUMN_TYPE_DATETIME, sem);
  column_apply_type (app, col);
  column_repaint (app);
}

static void
on_col_grouping (GObject *row, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  guint32 col = col_of (GTK_WIDGET (row));
  if (col < app->n_cols)
    {
      app->col_settings[col].format.grouping
          = adw_switch_row_get_active (ADW_SWITCH_ROW (row));
      column_repaint (app);
    }
}

static void
on_col_has_fraction (GObject *row, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  guint32 col = col_of (GTK_WIDGET (row));
  if (col < app->n_cols)
    {
      app->col_settings[col].format.has_fraction_digits
          = adw_switch_row_get_active (ADW_SWITCH_ROW (row));
      column_repaint (app);
    }
}

static void
on_col_fraction_value (GtkAdjustment *adj, gpointer data)
{
  App *app = g_object_get_data (G_OBJECT (adj), "lsg-app");
  (void)data;
  if (app == NULL || app->dialect_ui_guard)
    return;
  guint32 col = (guint32)GPOINTER_TO_UINT (
      g_object_get_data (G_OBJECT (adj), "lsg-col"));
  if (col < app->n_cols)
    {
      app->col_settings[col].format.fraction_digits
          = (gint)gtk_adjustment_get_value (adj);
      column_repaint (app);
    }
}

static void
on_col_date_preset (GObject *row, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  guint32 col = col_of (GTK_WIDGET (row));
  if (col < app->n_cols)
    {
      app->col_settings[col].format.date_preset
          = (LsgDatePreset)adw_combo_row_get_selected (ADW_COMBO_ROW (row));
      column_repaint (app);
    }
}

static void
on_col_null_enabled (GObject *row, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  guint32 col = col_of (GTK_WIDGET (row));
  if (col >= app->n_cols)
    return;
  LsgColumnUserSettings *s = &app->col_settings[col];
  if (adw_switch_row_get_active (ADW_SWITCH_ROW (row)))
    {
      s->has_null_sentinel = TRUE;
      lsg_document_column_null_sentinel_set (
          app->doc, col, s->null_sentinel_len ? s->null_sentinel : NULL,
          s->null_sentinel_len);
    }
  else
    {
      s->has_null_sentinel = FALSE;
      lsg_document_column_null_sentinel_clear (app->doc, col);
    }
  column_cache_effective (app, col);
  column_repaint (app);
}

static void
on_col_null_value_apply (GtkWidget *entry, gpointer data)
{
  App *app = data;
  guint32 col = col_of (entry);
  if (col >= app->n_cols)
    return;
  LsgColumnUserSettings *s = &app->col_settings[col];
  const char *text = gtk_editable_get_text (GTK_EDITABLE (entry));
  gsize len = (text != NULL) ? strlen (text) : 0;
  if (len > LS_COLUMN_SENTINEL_MAX_BYTES)
    len = LS_COLUMN_SENTINEL_MAX_BYTES;
  memcpy (s->null_sentinel, (text != NULL) ? text : "", len);
  s->null_sentinel_len = len;
  s->has_null_sentinel = TRUE;
  lsg_document_column_null_sentinel_set (app->doc, col,
                                         len ? s->null_sentinel : NULL, len);
  column_cache_effective (app, col);
  column_repaint (app);
}

static void
on_col_width_value (GtkAdjustment *adj, gpointer data)
{
  App *app = g_object_get_data (G_OBJECT (adj), "lsg-app");
  (void)data;
  if (app == NULL || app->dialect_ui_guard)
    return;
  guint32 col = (guint32)GPOINTER_TO_UINT (
      g_object_get_data (G_OBJECT (adj), "lsg-col"));
  if (col < app->n_cols)
    {
      app->col_settings[col].has_manual_width = TRUE;
      app->col_settings[col].manual_width = gtk_adjustment_get_value (adj);
      app->col_widths[col] = gtk_adjustment_get_value (adj);
      grid_update_hadjustment (app);
      column_repaint (app);
    }
}

static void
on_col_reset (GtkButton *btn, gpointer data)
{
  App *app = data;
  guint32 col = col_of (GTK_WIDGET (btn));
  if (col >= app->n_cols)
    return;
  app->col_settings[col] = lsg_column_user_settings_default ();
  lsg_document_column_override_clear (app->doc, col);
  lsg_document_column_null_sentinel_clear (app->doc, col);
  column_cache_effective (app, col);
  /* Reset cleared has_manual_width — re-sample the auto width so a previously
   * widened column shrinks back (Finding 3). */
  sample_one_column_width (app, col);
  grid_update_hadjustment (app);
  column_repaint (app);
  columns_group_rebuild (app); /* re-reflect every control from the reset */
}

static void
on_col_expanded (GObject *expander, GParamSpec *pspec, gpointer data)
{
  (void)pspec;
  App *app = data;
  if (app->dialect_ui_guard)
    return;
  /* Any expand/collapse is a natural moment to refresh the collapsed-row
   * settings summaries (so edits made in a row show once it collapses). */
  columns_refresh_summaries (app);
  if (!adw_expander_row_get_expanded (ADW_EXPANDER_ROW (expander)))
    return;
  /* Auto-collapse the previously-open row (F11: at most one usefully open). */
  GtkWidget *grp = app->prefs_columns_group;
  if (grp == NULL)
    return;
  app->dialect_ui_guard = TRUE;
  /* Iterate the group's rows and collapse the others. AdwPreferencesGroup has
   * no child iterator; walk via the shared expander list stored on the group.
   */
  GPtrArray *rows = g_object_get_data (G_OBJECT (grp), "lsg-rows");
  if (rows != NULL)
    for (guint i = 0; i < rows->len; i++)
      {
        GtkWidget *e = g_ptr_array_index (rows, i);
        if (e != (GtkWidget *)expander)
          adw_expander_row_set_expanded (ADW_EXPANDER_ROW (e), FALSE);
      }
  app->dialect_ui_guard = FALSE;
}

/* Reflect the datetime-semantics + format rows' visibility for the current
 * effective/override kind of `col`. */
static void
column_row_sync (App *app, GtkWidget *expander, guint32 col)
{
  ls_column_type_kind kind
      = app->col_settings[col].has_override
            ? (ls_column_type_kind)app->col_settings[col].override.kind
            : app->col_kind[col];
  gboolean is_num
      = (kind == LS_COLUMN_TYPE_INTEGER || kind == LS_COLUMN_TYPE_DECIMAL);
  gboolean is_dec = (kind == LS_COLUMN_TYPE_DECIMAL);
  gboolean is_date
      = (kind == LS_COLUMN_TYPE_DATE || kind == LS_COLUMN_TYPE_DATETIME);
  gboolean is_dt = (kind == LS_COLUMN_TYPE_DATETIME);

  GtkWidget *w;
  if ((w = g_object_get_data (G_OBJECT (expander), "row-datetime")) != NULL)
    gtk_widget_set_visible (w, is_dt);
  if ((w = g_object_get_data (G_OBJECT (expander), "row-grouping")) != NULL)
    gtk_widget_set_visible (w, is_num);
  if ((w = g_object_get_data (G_OBJECT (expander), "row-hasfrac")) != NULL)
    gtk_widget_set_visible (w, is_dec);
  if ((w = g_object_get_data (G_OBJECT (expander), "row-frac")) != NULL)
    gtk_widget_set_visible (w, is_dec);
  if ((w = g_object_get_data (G_OBJECT (expander), "row-datepreset")) != NULL)
    gtk_widget_set_visible (w, is_date);
}

/* Build one column's inline expander-row inspector (F11). */
static GtkWidget *
build_column_row (App *app, guint32 col)
{
  column_cache_effective (app, col);
  LsgColumnUserSettings *s = &app->col_settings[col];

  char *label = lsg_document_header_cell_dup (app->doc, col);
  char *title;
  if (label != NULL && label[0] != '\0')
    title = g_strdup (label);
  else
    {
      char *gn = lsg_column_generic_name (col);
      title = g_strdup_printf ("%s (#%u)", gn, col + 1);
      g_free (gn);
    }
  g_free (label);

  GtkWidget *exp = adw_expander_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (exp), title);
  g_free (title);
  g_object_set_data (G_OBJECT (exp), "lsg-col", GUINT_TO_POINTER (col));
  {
    char *sum = column_summary_dup (app, col); /* current-settings summary */
    adw_expander_row_set_subtitle (ADW_EXPANDER_ROW (exp), sum);
    g_free (sum);
  }

  /* Visibility check as the row prefix. */
  GtkWidget *vis = gtk_check_button_new ();
  gtk_check_button_set_active (GTK_CHECK_BUTTON (vis), !s->hidden);
  gtk_widget_set_valign (vis, GTK_ALIGN_CENTER);
  gtk_widget_set_tooltip_text (vis, "Visible");
  g_object_set_data (G_OBJECT (vis), "lsg-col", GUINT_TO_POINTER (col));
  g_signal_connect (vis, "toggled", G_CALLBACK (on_col_visibility), app);
  adw_expander_row_add_prefix (ADW_EXPANDER_ROW (exp), vis);

  /* Type. */
  GtkWidget *type = adw_combo_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (type), "Type");
  const char *type_items[] = { "Auto",    "Text", "Boolean",     "Integer",
                               "Decimal", "Date", "Date & time", NULL };
  combo_set_items (type, type_items);
  adw_combo_row_set_selected (
      ADW_COMBO_ROW (type),
      s->has_override
          ? kind_to_type_index ((ls_column_type_kind)s->override.kind)
          : 0);
  g_object_set_data (G_OBJECT (type), "lsg-col", GUINT_TO_POINTER (col));
  g_signal_connect (type, "notify::selected", G_CALLBACK (on_col_type), app);
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), type);

  /* Guessed-type read-out. */
  GtkWidget *guessed = adw_action_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (guessed),
                                 "Detected type");
  {
    static const char *kn[]
        = { "Unknown", "Unsupported", "Text", "Boolean",
            "Integer", "Decimal",     "Date", "Date & time" };
    guint ki = (guint)app->col_kind[col];
    adw_action_row_set_subtitle (ADW_ACTION_ROW (guessed),
                                 (ki < G_N_ELEMENTS (kn)) ? kn[ki]
                                                          : "Unknown");
  }
  g_object_set_data (G_OBJECT (exp), "row-detected",
                     guessed); /* async refresh */
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), guessed);

  /* Datetime semantics. */
  GtkWidget *dtsem = adw_combo_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (dtsem),
                                 "Date-time zone");
  const char *dt_items[] = { "Naive (no zone)", "With time zone", NULL };
  combo_set_items (dtsem, dt_items);
  adw_combo_row_set_selected (
      ADW_COMBO_ROW (dtsem),
      (s->has_override
       && s->override.datetime_semantics == LS_COLUMN_DATETIME_ZONED)
          ? 1
          : 0);
  g_object_set_data (G_OBJECT (dtsem), "lsg-col", GUINT_TO_POINTER (col));
  g_signal_connect (dtsem, "notify::selected",
                    G_CALLBACK (on_col_datetime_sem), app);
  g_object_set_data (G_OBJECT (exp), "row-datetime", dtsem);
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), dtsem);

  /* Number grouping. */
  GtkWidget *grouping = adw_switch_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (grouping),
                                 "Thousands grouping");
  adw_switch_row_set_active (ADW_SWITCH_ROW (grouping), s->format.grouping);
  g_object_set_data (G_OBJECT (grouping), "lsg-col", GUINT_TO_POINTER (col));
  g_signal_connect (grouping, "notify::active", G_CALLBACK (on_col_grouping),
                    app);
  g_object_set_data (G_OBJECT (exp), "row-grouping", grouping);
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), grouping);

  /* Fixed fraction digits (decimal only). */
  GtkWidget *hasfrac = adw_switch_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (hasfrac),
                                 "Fixed fraction digits");
  adw_switch_row_set_active (ADW_SWITCH_ROW (hasfrac),
                             s->format.has_fraction_digits);
  g_object_set_data (G_OBJECT (hasfrac), "lsg-col", GUINT_TO_POINTER (col));
  g_signal_connect (hasfrac, "notify::active",
                    G_CALLBACK (on_col_has_fraction), app);
  g_object_set_data (G_OBJECT (exp), "row-hasfrac", hasfrac);
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), hasfrac);

  GtkWidget *frac = adw_spin_row_new_with_range (
      0.0, (double)LSG_COLUMN_FRACTION_DIGITS_MAX, 1.0);
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (frac),
                                 "Fraction digits");
  adw_spin_row_set_value (
      ADW_SPIN_ROW (frac),
      s->format.has_fraction_digits ? (double)s->format.fraction_digits : 2.0);
  {
    GtkAdjustment *adj = adw_spin_row_get_adjustment (ADW_SPIN_ROW (frac));
    g_object_set_data (G_OBJECT (adj), "lsg-app", app);
    g_object_set_data (G_OBJECT (adj), "lsg-col", GUINT_TO_POINTER (col));
    g_signal_connect (adj, "value-changed", G_CALLBACK (on_col_fraction_value),
                      NULL);
  }
  g_object_set_data (G_OBJECT (exp), "row-frac", frac);
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), frac);

  /* Date preset (date / datetime only). */
  GtkWidget *dpreset = adw_combo_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (dpreset), "Date format");
  const char *dp_items[] = { "Original", "Short", "Medium", "Long", NULL };
  combo_set_items (dpreset, dp_items);
  adw_combo_row_set_selected (ADW_COMBO_ROW (dpreset),
                              (guint)s->format.date_preset);
  g_object_set_data (G_OBJECT (dpreset), "lsg-col", GUINT_TO_POINTER (col));
  g_signal_connect (dpreset, "notify::selected",
                    G_CALLBACK (on_col_date_preset), app);
  g_object_set_data (G_OBJECT (exp), "row-datepreset", dpreset);
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), dpreset);

  /* Null sentinel. */
  GtkWidget *nullen = adw_switch_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (nullen),
                                 "Treat a value as null");
  adw_switch_row_set_active (ADW_SWITCH_ROW (nullen), s->has_null_sentinel);
  g_object_set_data (G_OBJECT (nullen), "lsg-col", GUINT_TO_POINTER (col));
  g_signal_connect (nullen, "notify::active", G_CALLBACK (on_col_null_enabled),
                    app);
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), nullen);

  GtkWidget *nullval = adw_entry_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (nullval),
                                 "Null value (exact text)");
  if (s->has_null_sentinel && s->null_sentinel_len > 0)
    {
      char *v = lsg_utf8_sanitize_dup (s->null_sentinel, s->null_sentinel_len);
      gtk_editable_set_text (GTK_EDITABLE (nullval), v);
      g_free (v);
    }
  g_object_set_data (G_OBJECT (nullval), "lsg-col", GUINT_TO_POINTER (col));
  g_signal_connect (nullval, "apply", G_CALLBACK (on_col_null_value_apply),
                    app);
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), nullval);

  /* Width + auto-fit + reset. */
  double cur_w = (col < app->n_cols && app->col_widths[col] > 0.0)
                     ? app->col_widths[col]
                     : 100.0;
  GtkWidget *width = adw_spin_row_new_with_range (30.0, 800.0, 5.0);
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (width), "Column width");
  adw_spin_row_set_value (ADW_SPIN_ROW (width), cur_w);
  {
    GtkAdjustment *adj = adw_spin_row_get_adjustment (ADW_SPIN_ROW (width));
    g_object_set_data (G_OBJECT (adj), "lsg-app", app);
    g_object_set_data (G_OBJECT (adj), "lsg-col", GUINT_TO_POINTER (col));
    g_signal_connect (adj, "value-changed", G_CALLBACK (on_col_width_value),
                      NULL);
  }
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), width);

  GtkWidget *reset = gtk_button_new_with_label ("Reset to Auto");
  gtk_widget_add_css_class (reset, "flat");
  gtk_widget_set_margin_top (reset, 6);
  gtk_widget_set_margin_bottom (reset, 6);
  gtk_widget_set_margin_start (reset, 6);
  gtk_widget_set_margin_end (reset, 6);
  g_object_set_data (G_OBJECT (reset), "lsg-col", GUINT_TO_POINTER (col));
  g_signal_connect (reset, "clicked", G_CALLBACK (on_col_reset), app);
  adw_expander_row_add_row (ADW_EXPANDER_ROW (exp), reset);

  g_signal_connect (exp, "notify::expanded", G_CALLBACK (on_col_expanded),
                    app);

  column_row_sync (app, exp, col); /* hide the rows irrelevant to the kind */
  return exp;
}

static void
on_columns_search_changed (GtkEditable *entry, gpointer data)
{
  (void)entry;
  App *app = data;
  columns_group_rebuild (app);
}

/* BUG A: re-read the RESOLVED type of each displayed column and refresh its
 * "Detected type" subtitle, its kind-dependent rows, and its collapsed
 * summary. Called from the inference poll once the core commits a generation,
 * so the initial "Unknown" is replaced by the real inferred kind. */
static void
columns_refresh_types (App *app)
{
  if (app->prefs_columns_group == NULL)
    return;
  GPtrArray *rows
      = g_object_get_data (G_OBJECT (app->prefs_columns_group), "lsg-rows");
  if (rows == NULL)
    return;
  static const char *kn[]
      = { "Unknown", "Unsupported", "Text", "Boolean",
          "Integer", "Decimal",     "Date", "Date & time" };
  for (guint i = 0; i < rows->len; i++)
    {
      GtkWidget *exp = g_ptr_array_index (rows, i);
      guint32 col
          = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (exp), "lsg-col"));
      if (col >= app->n_cols)
        continue;
      column_cache_effective (app,
                              col); /* re-read effective (inferred) kind */
      GtkWidget *det = g_object_get_data (G_OBJECT (exp), "row-detected");
      if (det != NULL)
        {
          guint ki = (guint)app->col_kind[col];
          adw_action_row_set_subtitle (ADW_ACTION_ROW (det),
                                       (ki < G_N_ELEMENTS (kn)) ? kn[ki]
                                                                : "Unknown");
        }
      column_row_sync (app, exp, col); /* reveal kind-dependent format rows */
    }
  columns_refresh_summaries (app);
}

/* Poll the core's async type-inference job while the Columns page is open;
 * refresh the displayed types whenever the metadata generation advances, and
 * stop once the job settles (BUG A wiring). */
static gboolean
prefs_infer_poll_cb (gpointer data)
{
  App *app = data;
  if (app->doc == NULL || app->prefs == NULL)
    {
      app->prefs_infer_poll_id = 0;
      return G_SOURCE_REMOVE;
    }
  ls_column_inference_status st;
  if (lsg_document_column_metadata_poll (app->doc, &st) != LS_COLUMN_OK)
    {
      app->prefs_infer_poll_id = 0;
      return G_SOURCE_REMOVE;
    }
  if (st.metadata_generation != app->prefs_infer_gen)
    {
      app->prefs_infer_gen = st.metadata_generation;
      columns_refresh_types (app);
      column_repaint (app); /* typed cell formatting for displayed columns */
    }
  if (app->prefs_infer_row != NULL)
    {
      char *sub = (st.state == LS_COLUMN_JOB_QUEUED
                   || st.state == LS_COLUMN_JOB_RUNNING)
                      ? g_strdup_printf ("Detecting types… %u of %u",
                                         st.completed_column_count,
                                         st.requested_column_count)
                      : g_strdup ("Type detection complete");
      adw_action_row_set_subtitle (ADW_ACTION_ROW (app->prefs_infer_row), sub);
      g_free (sub);
    }
  if (st.state != LS_COLUMN_JOB_QUEUED && st.state != LS_COLUMN_JOB_RUNNING)
    {
      app->prefs_infer_poll_id = 0;
      return G_SOURCE_REMOVE; /* settled */
    }
  return G_SOURCE_CONTINUE;
}

/* Request type inference for exactly the currently-displayed columns and
 * (re)start the poll that refreshes their types. O(<=10) IDs (N2). */
static void
columns_request_inference (App *app)
{
  GtkWidget *grp = app->prefs_columns_group;
  if (grp == NULL || app->doc == NULL)
    return;
  GPtrArray *rows = g_object_get_data (G_OBJECT (grp), "lsg-rows");
  if (rows == NULL || rows->len == 0)
    return;
  guint32 *ids = g_new (guint32, rows->len);
  guint32 n = 0;
  for (guint i = 0; i < rows->len; i++)
    {
      GtkWidget *exp = g_ptr_array_index (rows, i);
      ids[n++]
          = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (exp), "lsg-col"));
    }
  lsg_document_column_inference_request (app->doc, ids, n);
  g_free (ids);
  app->prefs_infer_gen = 0; /* force a refresh on the next poll tick */
  if (app->prefs_infer_poll_id == 0)
    app->prefs_infer_poll_id
        = g_timeout_add (INFER_POLL_INTERVAL_MS, prefs_infer_poll_cb, app);
}

/* (Re)populate the Columns page's per-column group from the discovery mode +
 * current search (O(<=10) rows — N2). */
static void
columns_group_rebuild (App *app)
{
  GtkWidget *grp = app->prefs_columns_group;
  if (grp == NULL || app->doc == NULL)
    return;

  /* Drop the previous rows. */
  GPtrArray *rows = g_object_get_data (G_OBJECT (grp), "lsg-rows");
  if (rows != NULL)
    {
      for (guint i = 0; i < rows->len; i++)
        adw_preferences_group_remove (ADW_PREFERENCES_GROUP (grp),
                                      g_ptr_array_index (rows, i));
      g_ptr_array_set_size (rows, 0);
    }
  else
    {
      rows = g_ptr_array_new ();
      g_object_set_data_full (G_OBJECT (grp), "lsg-rows", rows,
                              (GDestroyNotify)g_ptr_array_unref);
    }

  LsgColumnDiscoveryMode mode = lsg_column_discovery_mode (app->n_cols);
  const char *status = NULL;

  if (mode == LSG_COLUMN_DISCOVERY_SEARCH_ONLY)
    gtk_widget_set_visible (app->prefs_columns_search, TRUE);
  else
    gtk_widget_set_visible (app->prefs_columns_search, FALSE);

  if (mode == LSG_COLUMN_DISCOVERY_EMPTY)
    {
      status = "This document has no columns.";
    }
  else if (mode == LSG_COLUMN_DISCOVERY_FULL_LIST)
    {
      for (guint32 c = 0; c < app->n_cols; c++)
        {
          GtkWidget *row = build_column_row (app, c);
          adw_preferences_group_add (ADW_PREFERENCES_GROUP (grp), row);
          g_ptr_array_add (rows, row);
        }
    }
  else /* SEARCH_ONLY */
    {
      const char *q = (app->prefs_columns_search != NULL)
                          ? gtk_editable_get_text (
                                GTK_EDITABLE (app->prefs_columns_search))
                          : "";
      LsgColumnDirectAddress a
          = lsg_column_resolve_direct_address (q, app->n_cols);
      if (a.kind == LSG_COLUMN_ADDRESS_RESOLVED)
        {
          GtkWidget *row = build_column_row (app, a.column);
          adw_preferences_group_add (ADW_PREFERENCES_GROUP (grp), row);
          g_ptr_array_add (rows, row);
        }
      else if (a.kind == LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN)
        {
          status = "No such column.";
        }
      else if (q == NULL || q[0] == '\0')
        {
          status = "Search by name, or type #N for a column number.";
        }
      else
        {
          /* Label substring search, in bounded batches, retaining <=10. */
          LsgColumnMatchAccumulation acc = lsg_column_match_initial ();
          guint32 done = 0;
          while (done < app->n_cols && !lsg_column_match_stop (acc))
            {
              guint32 batch = MIN ((guint32)LSG_COLUMN_LABEL_BATCH_MAX,
                                   app->n_cols - done);
              guint32 *ids = g_new (guint32, batch);
              for (guint32 i = 0; i < batch; i++)
                ids[i] = done + i;
              ls_column_result r = LS_COLUMN_INVALID_ARGUMENT;
              LsgColumnLabel *labels = lsg_document_column_labels_copy_many (
                  app->doc, ids, batch, &r);
              if (labels == NULL || r != LS_COLUMN_OK)
                {
                  g_free (ids);
                  if (labels != NULL)
                    lsg_column_labels_free (labels, batch);
                  break;
                }
              LsgColumnLabelCandidate *cands
                  = g_new0 (LsgColumnLabelCandidate, batch);
              char **strs = g_new0 (char *, batch);
              for (guint32 i = 0; i < batch; i++)
                {
                  cands[i].column = ids[i];
                  if (labels[i].present && labels[i].len > 0)
                    {
                      strs[i] = lsg_utf8_sanitize_dup (labels[i].bytes,
                                                       labels[i].len);
                      cands[i].label = strs[i];
                    }
                  else
                    cands[i].label = NULL; /* generic-name fallback */
                }
              acc = lsg_column_match_accumulate (acc, q, cands, batch);
              for (guint32 i = 0; i < batch; i++)
                g_free (strs[i]);
              g_free (strs);
              g_free (cands);
              g_free (ids);
              lsg_column_labels_free (labels, batch);
              done += batch;
            }

          for (guint i = 0; i < acc.n_retained; i++)
            {
              GtkWidget *row = build_column_row (app, acc.retained[i]);
              adw_preferences_group_add (ADW_PREFERENCES_GROUP (grp), row);
              g_ptr_array_add (rows, row);
            }
          if (acc.n_retained == 0)
            status = "No matching columns.";
          else if (acc.overflow)
            status = "More matches — refine your search.";
        }
    }

  if (app->prefs_columns_status != NULL)
    {
      if (status != NULL)
        {
          adw_preferences_row_set_title (
              ADW_PREFERENCES_ROW (app->prefs_columns_status), status);
          gtk_widget_set_visible (app->prefs_columns_status, TRUE);
        }
      else
        gtk_widget_set_visible (app->prefs_columns_status, FALSE);
    }

  /* BUG A: infer the types of exactly these displayed columns, then poll +
   * refresh their "Detected type" as the core commits. */
  columns_request_inference (app);
}

static void
on_show_all_columns (GtkButton *btn, gpointer data)
{
  (void)btn;
  App *app = data;
  for (guint32 c = 0; c < app->n_cols; c++)
    if (app->col_settings[c].hidden)
      set_column_hidden (app, c, FALSE); /* restore width + clear hidden */
  grid_update_hadjustment (app);         /* total width changed */
  column_repaint (app);
  columns_group_rebuild (app);
}

static GtkWidget *
build_columns_page (App *app)
{
  GtkWidget *page = adw_preferences_page_new ();
  adw_preferences_page_set_title (ADW_PREFERENCES_PAGE (page), "Columns");
  adw_preferences_page_set_icon_name (ADW_PREFERENCES_PAGE (page),
                                      "view-grid-symbolic");

  /* Discovery search (shown only in search-only mode). */
  GtkWidget *search_grp = adw_preferences_group_new ();
  GtkWidget *search = adw_entry_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (search),
                                 "Search columns (name or #N)");
  app->prefs_columns_search = search;
  g_signal_connect (search, "changed", G_CALLBACK (on_columns_search_changed),
                    app);
  adw_preferences_group_add (ADW_PREFERENCES_GROUP (search_grp), search);

  GtkWidget *status = adw_action_row_new ();
  gtk_widget_set_visible (status, FALSE);
  app->prefs_columns_status = status;
  adw_preferences_group_add (ADW_PREFERENCES_GROUP (search_grp), status);
  adw_preferences_page_add (ADW_PREFERENCES_PAGE (page),
                            ADW_PREFERENCES_GROUP (search_grp));

  /* The per-column rows group. */
  GtkWidget *grp = adw_preferences_group_new ();
  adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (grp), "Columns");
  app->prefs_columns_group = grp;
  adw_preferences_page_add (ADW_PREFERENCES_PAGE (page),
                            ADW_PREFERENCES_GROUP (grp));

  /* Show All + inference progress. */
  GtkWidget *tools = adw_preferences_group_new ();
  GtkWidget *show_all = adw_action_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (show_all),
                                 "Show all columns");
  GtkWidget *sa_btn = gtk_button_new_with_label ("Show All");
  gtk_widget_set_valign (sa_btn, GTK_ALIGN_CENTER);
  g_signal_connect (sa_btn, "clicked", G_CALLBACK (on_show_all_columns), app);
  adw_action_row_add_suffix (ADW_ACTION_ROW (show_all), sa_btn);
  adw_preferences_group_add (ADW_PREFERENCES_GROUP (tools), show_all);

  GtkWidget *infer = adw_action_row_new ();
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (infer),
                                 "Type detection runs for shown columns");
  app->prefs_infer_row = infer;
  adw_preferences_group_add (ADW_PREFERENCES_GROUP (tools), infer);
  adw_preferences_page_add (ADW_PREFERENCES_PAGE (page),
                            ADW_PREFERENCES_GROUP (tools));

  columns_group_rebuild (app);
  return page;
}

static void
settings_present (App *app)
{
  if (app->doc == NULL || app->window == NULL)
    return;
  AdwDialog *dlg = ADW_DIALOG (adw_preferences_dialog_new ());
  app->prefs = dlg;
  adw_preferences_dialog_add (ADW_PREFERENCES_DIALOG (dlg),
                              ADW_PREFERENCES_PAGE (build_parsing_page (app)));
  adw_preferences_dialog_add (ADW_PREFERENCES_DIALOG (dlg),
                              ADW_PREFERENCES_PAGE (build_columns_page (app)));
  g_signal_connect (dlg, "closed", G_CALLBACK (on_prefs_closed), app);
  adw_dialog_present (dlg, GTK_WIDGET (app->window));
}

/* Build the single window once (idempotent). Shared by "activate" (no file)
 * and "open" (a file passed on the command line / by the file manager). */
static void
ensure_window (App *app, GtkApplication *gtk_app)
{
  if (app->window != NULL)
    return;
  app->app = ADW_APPLICATION (gtk_app);
  install_jump_css ();

  GtkWidget *win = adw_application_window_new (gtk_app);
  app->window = GTK_WINDOW (win);
  g_signal_connect (win, "map", G_CALLBACK (on_window_map), app);
  g_signal_connect (win, "destroy", G_CALLBACK (on_window_destroy), app);

  /* App-level shortcuts (Find / Jump / Open / Preferences / Shortcuts) are
   * GActions with accelerators (register_app_shortcuts, from the single accel
   * table), so no window-level key controller is needed here. */
  gtk_window_set_title (app->window, "less-sheet");
  gtk_window_set_default_size (app->window, 1024, 720);

  /* App logo: register the embedded GResource icon (compiled into the binary
   * as a hicolor-laid-out resource) so the running app shows it without an
   * install, then name the window's icon after the app id. */
  GdkDisplay *display = gdk_display_get_default ();
  if (display != NULL)
    gtk_icon_theme_add_resource_path (gtk_icon_theme_get_for_display (display),
                                      LSG_ICON_RESOURCE_PATH);
  gtk_window_set_icon_name (app->window, LSG_APP_ID);

  /* Header bar: Open + Open URL on the left, filename title in the center.
   * The title is a CUSTOM widget (not an AdwWindowTitle) so the filtered
   * subtitle can carry a (x) clear-filter button: a centered document-name
   * label over a subtitle ROW (the status label + the filtered-only (x)).
   * `.title`/`.subtitle` + ellipsize + centering match AdwWindowTitle, so the
   * unfiltered look is unchanged (the (x) is hidden, taking no space). */
  GtkWidget *header = adw_header_bar_new ();
  GtkWidget *title_box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_valign (title_box, GTK_ALIGN_CENTER);

  GtkWidget *title_name = gtk_label_new ("less-sheet");
  gtk_widget_add_css_class (title_name, "title");
  gtk_label_set_single_line_mode (GTK_LABEL (title_name), TRUE);
  gtk_label_set_ellipsize (GTK_LABEL (title_name), PANGO_ELLIPSIZE_END);
  gtk_widget_set_halign (title_name, GTK_ALIGN_CENTER);

  GtkWidget *subrow = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 4);
  gtk_widget_set_halign (subrow, GTK_ALIGN_CENTER);
  GtkWidget *title_status = gtk_label_new ("");
  gtk_widget_add_css_class (title_status, "subtitle");
  gtk_label_set_single_line_mode (GTK_LABEL (title_status), TRUE);
  gtk_label_set_ellipsize (GTK_LABEL (title_status), PANGO_ELLIPSIZE_END);
  gtk_widget_set_visible (title_status, FALSE); /* empty => hidden, like Adw */

  GtkWidget *fx = gtk_button_new_from_icon_name ("window-close-symbolic");
  gtk_widget_add_css_class (fx, "flat");
  gtk_widget_add_css_class (fx, "circular");
  gtk_widget_set_tooltip_text (fx, "Clear filter");
  a11y_name (fx, LSG_A11Y_CONTROL_CLEAR_FILTER);
  gtk_widget_set_valign (fx, GTK_ALIGN_CENTER);
  gtk_widget_set_visible (fx, FALSE); /* filtered-only; no space when hidden */
  g_signal_connect (fx, "clicked", G_CALLBACK (on_filter_clear_clicked), app);

  gtk_box_append (GTK_BOX (subrow), title_status);
  gtk_box_append (GTK_BOX (subrow), fx);
  gtk_box_append (GTK_BOX (title_box), title_name);
  gtk_box_append (GTK_BOX (title_box), subrow);
  adw_header_bar_set_title_widget (ADW_HEADER_BAR (header), title_box);
  app->title_box = title_box;
  app->title_name = GTK_LABEL (title_name);
  app->title_status = GTK_LABEL (title_status);
  app->filter_clear_btn = GTK_BUTTON (fx);

  GtkWidget *open_btn
      = gtk_button_new_from_icon_name ("document-open-symbolic");
  gtk_widget_set_tooltip_text (open_btn, "Open File (Ctrl+O)");
  a11y_name (open_btn, LSG_A11Y_CONTROL_OPEN_FILE);
  g_signal_connect (open_btn, "clicked", G_CALLBACK (action_open), app);
  adw_header_bar_pack_start (ADW_HEADER_BAR (header), open_btn);

  /* `insert-link-symbolic` is a minimal link glyph present in current Adwaita;
   * the old `emblem-web-symbolic` was dropped from the theme and rendered
   * blank. */
  GtkWidget *url_btn = gtk_button_new_from_icon_name ("insert-link-symbolic");
  gtk_widget_set_tooltip_text (url_btn, "Open URL (Ctrl+Shift+O)");
  a11y_name (url_btn, LSG_A11Y_CONTROL_OPEN_URL);
  g_signal_connect (url_btn, "clicked", G_CALLBACK (action_open_url), app);
  adw_header_bar_pack_start (ADW_HEADER_BAR (header), url_btn);

  /* Find: a menu button on the right whose popover is the find UI (Ctrl+F). */
  GtkWidget *find_btn = gtk_menu_button_new ();
  gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (find_btn),
                                 "edit-find-symbolic");
  gtk_widget_set_tooltip_text (find_btn, "Find (Ctrl+F)");
  a11y_name (find_btn, LSG_A11Y_CONTROL_FIND);
  app->find_button = GTK_MENU_BUTTON (find_btn);
  build_find_popover (app);
  gtk_menu_button_set_popover (GTK_MENU_BUTTON (find_btn),
                               GTK_WIDGET (app->find_popover));
  /* Packed at the end in the signed order (see below). */

  /* Jump-to-row: a menu button whose popover is the jump UI (Ctrl+G / Ctrl+L,
   * or type a digit on the grid). Its icon is the custom macOS-style jump
   * glyph (drawn into a 16px GtkDrawingArea child, tinting with the theme fg).
   */
  GtkWidget *jump_btn = gtk_menu_button_new ();
  /* Flat like the other header-bar buttons (background only on hover/active).
   * GtkMenuButton defaults has-frame TRUE, and a custom `set_child` icon
   * doesn't get the `image-button` flattening `set_icon_name` gives the find
   * button, so without this the jump button looks permanently highlighted. */
  gtk_menu_button_set_has_frame (GTK_MENU_BUTTON (jump_btn), FALSE);
  /* The drawn glyph is decorative (role NONE / presentational, construct-only)
   * so the interactive parent button is the single named AT stop (FR3). */
  GtkWidget *jump_glyph
      = g_object_new (GTK_TYPE_DRAWING_AREA, "accessible-role",
                      GTK_ACCESSIBLE_ROLE_NONE, NULL);
  gtk_widget_set_size_request (jump_glyph, 16, 16);
  gtk_widget_set_halign (jump_glyph, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (jump_glyph, GTK_ALIGN_CENTER);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (jump_glyph),
                                  jump_glyph_draw, NULL, NULL);
  gtk_menu_button_set_child (GTK_MENU_BUTTON (jump_btn), jump_glyph);
  gtk_widget_set_tooltip_text (jump_btn, "Jump to row (Ctrl+G)");
  a11y_name (jump_btn, LSG_A11Y_CONTROL_JUMP);
  app->jump_button = GTK_MENU_BUTTON (jump_btn);
  build_jump_popover (app);
  gtk_menu_button_set_popover (GTK_MENU_BUTTON (jump_btn),
                               GTK_WIDGET (app->jump_popover));
  /* Packed at the end in the signed order (see below). */

  /* Copy button is DROPPED (F15): Ctrl+C on the grid still copies the
   * selection (on_key_pressed -> do_copy); only the bar button is removed.
   * app->copy_button stays NULL (copy_update_affordance is NULL-guarded). */

  /* Dialect quick-controls (F3): a header toggle + separator ▾ + quote ▾, all
   * driving the ONE lsg_dialect_compose funnel and reflecting the effective
   * report (kept in sync by dialect_sync_quick_controls after every open). */
  GtkWidget *hdr_toggle = gtk_toggle_button_new ();
  gtk_widget_set_tooltip_text (hdr_toggle, "First row is a header");
  a11y_name (hdr_toggle, LSG_A11Y_CONTROL_HEADER_TOGGLE);
  app->header_toggle = GTK_TOGGLE_BUTTON (hdr_toggle);
  /* Decorative drawn glyph -> role NONE (the toggle button is the named stop).
   */
  app->header_glyph = g_object_new (GTK_TYPE_DRAWING_AREA, "accessible-role",
                                    GTK_ACCESSIBLE_ROLE_NONE, NULL);
  gtk_widget_set_size_request (app->header_glyph, 16, 16);
  gtk_widget_set_halign (app->header_glyph, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (app->header_glyph, GTK_ALIGN_CENTER);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (app->header_glyph),
                                  header_glyph_draw, app, NULL);
  gtk_button_set_child (GTK_BUTTON (hdr_toggle), app->header_glyph);
  g_signal_connect (hdr_toggle, "toggled",
                    G_CALLBACK (on_header_toggle_toggled), app);

  GtkWidget *sep_btn = gtk_menu_button_new ();
  gtk_menu_button_set_child (
      GTK_MENU_BUTTON (sep_btn),
      build_dialect_button_child ("Sep", &app->sep_glyph_label));
  gtk_widget_set_tooltip_text (sep_btn, "Field separator");
  a11y_name (sep_btn, LSG_A11Y_CONTROL_SEPARATOR);
  app->sep_button = GTK_MENU_BUTTON (sep_btn);
  gtk_menu_button_set_popover (
      GTK_MENU_BUTTON (sep_btn),
      GTK_WIDGET (build_dialect_dropdown_popover (app, DIALECT_KIND_SEP)));

  GtkWidget *quote_btn = gtk_menu_button_new ();
  gtk_menu_button_set_child (
      GTK_MENU_BUTTON (quote_btn),
      build_dialect_button_child ("Quote", &app->quote_glyph_label));
  gtk_widget_set_tooltip_text (quote_btn, "Quote character");
  a11y_name (quote_btn, LSG_A11Y_CONTROL_QUOTE);
  app->quote_button = GTK_MENU_BUTTON (quote_btn);
  gtk_menu_button_set_popover (
      GTK_MENU_BUTTON (quote_btn),
      GTK_WIDGET (build_dialect_dropdown_popover (app, DIALECT_KIND_QUOTE)));

  /* Settings gear: the primary menu (Preferences + Keyboard Shortcuts +
   * About). */
  GtkWidget *settings_btn = gtk_menu_button_new ();
  gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (settings_btn),
                                 "open-menu-symbolic");
  gtk_widget_set_tooltip_text (settings_btn, "Main menu");
  a11y_name (settings_btn, LSG_A11Y_CONTROL_MENU);
  GMenuModel *primary = build_primary_menu (app);
  gtk_menu_button_set_menu_model (GTK_MENU_BUTTON (settings_btn), primary);
  g_object_unref (primary); /* the button holds its own ref */

  /* Reusable header-bar progress (determinate bar + inline cancel) for long
   * ops; hidden until a copy / network op drives it. */
  build_header_progress (app);

  /* Signed right-side layout (E). pack_end is right-anchored (first packed =
   * rightmost), so pack in reverse of the L-to-R order
   * [Find][Jump][Header][Separator ▾][Quote ▾][Settings]; the progress box
   * sits leftmost of the group, next to the title. */
  adw_header_bar_pack_end (ADW_HEADER_BAR (header), settings_btn);
  adw_header_bar_pack_end (ADW_HEADER_BAR (header), quote_btn);
  adw_header_bar_pack_end (ADW_HEADER_BAR (header), sep_btn);
  adw_header_bar_pack_end (ADW_HEADER_BAR (header), hdr_toggle);
  adw_header_bar_pack_end (ADW_HEADER_BAR (header), jump_btn);
  adw_header_bar_pack_end (ADW_HEADER_BAR (header), find_btn);
  adw_header_bar_pack_end (ADW_HEADER_BAR (header), app->hp_box);

  app->stack = GTK_STACK (gtk_stack_new ());
  gtk_widget_set_vexpand (GTK_WIDGET (app->stack), TRUE);
  gtk_stack_add_named (app->stack, build_launch_page (app), "launch");
  gtk_stack_add_named (app->stack, build_grid_page (app), "grid");

  GtkWidget *error = adw_status_page_new ();
  adw_status_page_set_icon_name (ADW_STATUS_PAGE (error),
                                 "dialog-error-symbolic");
  app->error_page = ADW_STATUS_PAGE (error);
  gtk_stack_add_named (app->stack, error, "error");

  gtk_stack_set_visible_child_name (app->stack, "launch");

  /* Toast overlay for the header-change + column-reset notices (F3 / F7). The
   * passive filter status lives in the header-bar subtitle, so the stack is
   * the overlay's sole child (no full-width status banner above it). */
  GtkWidget *toasts = adw_toast_overlay_new ();
  app->toasts = ADW_TOAST_OVERLAY (toasts);
  adw_toast_overlay_set_child (ADW_TOAST_OVERLAY (toasts),
                               GTK_WIDGET (app->stack));

  GtkWidget *toolbar = adw_toolbar_view_new ();
  app->toolbar = ADW_TOOLBAR_VIEW (toolbar);
  adw_toolbar_view_add_top_bar (ADW_TOOLBAR_VIEW (toolbar), header);
  adw_toolbar_view_set_content (ADW_TOOLBAR_VIEW (toolbar), toasts);

  adw_application_window_set_content (ADW_APPLICATION_WINDOW (win), toolbar);
}

/* GAction wrappers: adapt the existing button/open helpers to the
 * GSimpleAction activate signature so the app-level accelerators can drive
 * them. action_open / action_open_url ignore their button arg (comment above),
 * so NULL is fine. */
static void
act_open (GSimpleAction *a, GVariant *p, gpointer d)
{
  (void)a;
  (void)p;
  action_open (NULL, d);
}

static void
act_open_url (GSimpleAction *a, GVariant *p, gpointer d)
{
  (void)a;
  (void)p;
  action_open_url (NULL, d);
}

static void
act_find (GSimpleAction *a, GVariant *p, gpointer d)
{
  (void)a;
  (void)p;
  open_find (d);
}

static void
act_jump (GSimpleAction *a, GVariant *p, gpointer d)
{
  (void)a;
  (void)p;
  open_jump (d);
}

/* Register the app-level GActions and wire their accelerators from the SINGLE
 * lsg_a11y accelerator table (SCOPE_APP entries) via
 * gtk_application_set_accels_for_action — so every app accelerator is real,
 * centrally defined, and identical to what the shortcuts surface displays (FR5
 * / G-A4). Grid-scoped keys (Copy / Select-All / cursor moves / digit-jump /
 * Esc) are deliberately NOT here — they stay on the grid key controller so a
 * focused text entry keeps its own Ctrl+C / Ctrl+A (G-A7). */
static void
register_app_shortcuts (App *app, GApplication *gapp)
{
  const GActionEntry entries[] = {
    { "open", act_open, NULL, NULL, NULL, { 0, 0, 0 } },
    { "open-url", act_open_url, NULL, NULL, NULL, { 0, 0, 0 } },
    { "find", act_find, NULL, NULL, NULL, { 0, 0, 0 } },
    { "jump", act_jump, NULL, NULL, NULL, { 0, 0, 0 } },
    { "preferences", action_preferences, NULL, NULL, NULL, { 0, 0, 0 } },
    { "shortcuts", action_shortcuts, NULL, NULL, NULL, { 0, 0, 0 } },
    { "about", action_about, NULL, NULL, NULL, { 0, 0, 0 } },
  };
  g_action_map_add_action_entries (G_ACTION_MAP (gapp), entries,
                                   G_N_ELEMENTS (entries), app);

  guint n = 0;
  const LsgA11yShortcut *t = lsg_a11y_shortcuts (&n);
  for (guint i = 0; i < n; i++)
    {
      if (t[i].scope != LSG_A11Y_SCOPE_APP || t[i].action_name == NULL)
        continue;
      /* NULL-terminated: {accel, NULL} for a single accel, {accel, accel2,
       * NULL} for two (accel2 is NULL for single-accel entries). */
      const char *accels[] = { t[i].accel, t[i].accel2, NULL };
      gtk_application_set_accels_for_action (GTK_APPLICATION (gapp),
                                             t[i].action_name, accels);
    }
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
  (void)hint;
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
  app.t_start = g_get_monotonic_time (); /* capture entry ASAP */
  app.timing = (g_getenv ("LESSSHEET_GTK_TIMING") != NULL);
  app.row_estimate = 1;
  app.find = lsg_find_initial ();
  app.find_nav_direction = LSG_SEARCH_FORWARD;
  app.jump = lsg_jump_initial ();
  app.filter = lsg_filter_initial ();
  /* Data cell VALUES: small MONOSPACE (uniform advance -> accurate O(1) column
   * widths + macOS parity). Headers + all chrome stay sans-serif. */
  app.font_desc = pango_font_description_from_string ("Monospace 10");
  app.header_font_desc = pango_font_description_from_string ("Sans Bold 10");
  app.gutter_font_desc = pango_font_description_from_string ("Sans 10");

  g_autoptr (AdwApplication) application
      = adw_application_new (LSG_APP_ID, G_APPLICATION_HANDLES_OPEN);
  g_signal_connect (application, "activate", G_CALLBACK (on_activate), &app);
  g_signal_connect (application, "open", G_CALLBACK (on_open), &app);
  register_app_shortcuts (&app, G_APPLICATION (application));
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
  if (app.jump_reject_id != 0)
    g_source_remove (app.jump_reject_id);
  if (app.where_reject_id != 0)
    g_source_remove (app.where_reject_id);
  find_clear_mask (&app);
  g_clear_pointer (&app.pending_url, g_free);
  g_clear_pointer (&app.doc_path, g_free);
  g_clear_pointer (&app.reopen_snapshot, g_free);
  if (app.reopen_old_labels != NULL)
    lsg_column_labels_free (app.reopen_old_labels, app.reopen_n_old_labels);
  g_clear_pointer (&app.vadj, g_object_unref);
  g_clear_pointer (&app.hadj, g_object_unref);
  pango_font_description_free (app.font_desc);
  pango_font_description_free (app.header_font_desc);
  pango_font_description_free (app.gutter_font_desc);
  return status;
}
