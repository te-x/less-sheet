#include <lsg_metadata_dialog.h>

enum { PAGE_SIZE = 64 };
typedef struct
{
  LsgDocument *doc;
  ls_parquet_info info;
  GtkDropDown *section;
  AdwPreferencesGroup *group;
  GtkLabel *page_label;
  GtkWidget *previous, *next, *pager;
  guint64 first;
} Metadata;

static void
add_fact (Metadata *view, const char *title, const char *value)
{
  GtkWidget *row = adw_action_row_new ();
  adw_preferences_row_set_use_markup (ADW_PREFERENCES_ROW (row), FALSE);
  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row), title);
  adw_action_row_set_subtitle (ADW_ACTION_ROW (row), value);
  adw_action_row_set_subtitle_selectable (ADW_ACTION_ROW (row), TRUE);
  adw_preferences_group_add (view->group, row);
  GPtrArray *rows = g_object_get_data (G_OBJECT (view->group), "rows");
  g_ptr_array_add (rows, row);
}

static void
add_count (Metadata *view, const char *title, guint64 count)
{
  char *text = g_strdup_printf ("%" G_GUINT64_FORMAT, count);
  add_fact (view, title, text);
  g_free (text);
}

static void
fill_page (Metadata *view)
{
  /* Only our own rows are direct children of the group's internal listbox.
   * Track them rather than traversing libadwaita's private widget hierarchy. */
  GPtrArray *rows = g_object_get_data (G_OBJECT (view->group), "rows");
  if (rows != NULL)
    for (guint i = 0; i < rows->len; i++)
      adw_preferences_group_remove (view->group, g_ptr_array_index (rows, i));
  g_ptr_array_set_size (rows, 0);
  guint section = gtk_drop_down_get_selected (view->section);
  guint64 total = section == 1 ? view->info.columns : view->info.row_groups;
  gtk_widget_set_visible (view->pager, section != 0 && total > PAGE_SIZE);
  if (section == 0)
    {
      add_count (view, "Rows", view->info.rows);
      add_count (view, "Columns", view->info.columns);
      add_count (view, "Row groups", view->info.row_groups);
      char *size = g_format_size (view->info.file_bytes);
      add_fact (view, "File size", size);
      g_free (size);
      add_count (view, "Parquet format version", view->info.format_version);
      const char *codecs[] = { "Uncompressed", "Snappy", "Gzip", "LZO",
                              "Brotli", "LZ4", "Zstd", "LZ4 raw" };
      GString *compression = g_string_new (NULL);
      for (guint i = 0; i < G_N_ELEMENTS (codecs); i++)
        if (view->info.codec_mask & (1u << i))
          {
            if (compression->len) g_string_append (compression, ", ");
            g_string_append (compression, codecs[i]);
          }
      add_fact (view, "Compression", compression->len ? compression->str : "None (empty file)");
      g_string_free (compression, TRUE);
      char *writer = lsg_document_parquet_writer_dup (view->doc);
      add_fact (view, "Written by", writer[0] ? writer : "Not recorded");
      g_free (writer);
    }
  else
    {
      guint64 end = MIN (total, view->first + PAGE_SIZE);
      for (guint64 i = view->first; i < end; i++)
        {
          if (section == 1)
            {
              char *name = NULL, *type = NULL;
              if (lsg_document_parquet_column_dup (view->doc, i, &name, &type))
                add_fact (view, name, type);
              g_free (name);
              g_free (type);
            }
          else
            {
              ls_parquet_row_group group;
              if (!lsg_document_parquet_row_group (view->doc, i, &group)) continue;
              char *title = g_strdup_printf ("Row group %" G_GUINT64_FORMAT, i + 1);
              char *compressed = g_format_size (group.compressed_bytes);
              char *uncompressed = g_format_size (group.uncompressed_bytes);
              char *detail = g_strdup_printf (
                  "%" G_GUINT64_FORMAT " rows · starts at row %" G_GUINT64_FORMAT
                  "\n%s compressed · %s uncompressed", group.rows,
                  group.first_row + 1, compressed, uncompressed);
              add_fact (view, title, detail);
              g_free (title); g_free (detail); g_free (compressed); g_free (uncompressed);
            }
        }
      if (total == 0) add_fact (view, "No row groups", "This file contains no rows.");
      char *label = g_strdup_printf ("%" G_GUINT64_FORMAT "–%" G_GUINT64_FORMAT
                                    " of %" G_GUINT64_FORMAT, view->first + 1, end, total);
      gtk_label_set_text (view->page_label, label);
      g_free (label);
      gtk_widget_set_sensitive (view->previous, view->first > 0);
      gtk_widget_set_sensitive (view->next, end < total);
    }
}

static void
section_changed (GObject *object, GParamSpec *spec, gpointer data)
{
  (void)object; (void)spec;
  Metadata *view = data;
  view->first = 0;
  fill_page (view);
}

static void
page_clicked (GtkButton *button, gpointer data)
{
  Metadata *view = data;
  if (GTK_WIDGET (button) == view->previous) view->first -= PAGE_SIZE;
  else view->first += PAGE_SIZE;
  fill_page (view);
}

AdwDialog *
lsg_metadata_dialog_new (LsgDocument *doc, const char *name)
{
  Metadata *view = g_new0 (Metadata, 1);
  view->doc = doc;
  if (!lsg_document_parquet_info (doc, &view->info))
    { g_free (view); return NULL; }
  AdwDialog *dialog = adw_dialog_new ();
  adw_dialog_set_title (dialog, "Parquet Metadata");
  adw_dialog_set_content_width (dialog, 620);
  adw_dialog_set_content_height (dialog, 600);
  g_object_set_data_full (G_OBJECT (dialog), "metadata", view, g_free);
  GtkWidget *toolbar = adw_toolbar_view_new ();
  GtkWidget *header = adw_header_bar_new ();
  adw_toolbar_view_add_top_bar (ADW_TOOLBAR_VIEW (toolbar), header);
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 12);
  gtk_widget_set_margin_start (box, 18); gtk_widget_set_margin_end (box, 18);
  gtk_widget_set_margin_top (box, 12); gtk_widget_set_margin_bottom (box, 12);
  GtkWidget *label = gtk_label_new (name);
  gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_MIDDLE);
  gtk_widget_add_css_class (label, "dim-label");
  gtk_box_append (GTK_BOX (box), label);
  const char *sections[] = { "Overview", "Schema", "Row Groups", NULL };
  view->section = GTK_DROP_DOWN (gtk_drop_down_new_from_strings (sections));
  gtk_accessible_update_property (GTK_ACCESSIBLE (view->section),
      GTK_ACCESSIBLE_PROPERTY_LABEL, "Metadata section", -1);
  gtk_box_append (GTK_BOX (box), GTK_WIDGET (view->section));
  GtkWidget *scroll = gtk_scrolled_window_new ();
  gtk_widget_set_vexpand (scroll, TRUE);
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  view->group = ADW_PREFERENCES_GROUP (adw_preferences_group_new ());
  g_object_set_data_full (G_OBJECT (view->group), "rows", g_ptr_array_new (),
                          (GDestroyNotify)g_ptr_array_unref);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroll), GTK_WIDGET (view->group));
  gtk_box_append (GTK_BOX (box), scroll);
  view->pager = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  view->previous = gtk_button_new_with_label ("Previous");
  view->next = gtk_button_new_with_label ("Next");
  view->page_label = GTK_LABEL (gtk_label_new (NULL));
  gtk_widget_set_hexpand (GTK_WIDGET (view->page_label), TRUE);
  gtk_box_append (GTK_BOX (view->pager), view->previous);
  gtk_box_append (GTK_BOX (view->pager), GTK_WIDGET (view->page_label));
  gtk_box_append (GTK_BOX (view->pager), view->next);
  gtk_box_append (GTK_BOX (box), view->pager);
  adw_toolbar_view_set_content (ADW_TOOLBAR_VIEW (toolbar), box);
  adw_dialog_set_child (dialog, toolbar);
  g_signal_connect (view->section, "notify::selected", G_CALLBACK (section_changed), view);
  g_signal_connect (view->previous, "clicked", G_CALLBACK (page_clicked), view);
  g_signal_connect (view->next, "clicked", G_CALLBACK (page_clicked), view);
  fill_page (view);
  return dialog;
}
