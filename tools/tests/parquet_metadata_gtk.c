/* Native UI smoke check. Link with the GTK build directory’s liblsgkit.a,
 * src/lsg_metadata_dialog.c and the core; needs a desktop session.
 * argv: Parquet file, optional directory for rendered PNGs. */
#include <glib/gstdio.h>
#include <lsg_metadata_dialog.h>
#include <string.h>

static void settle(void) {
  gint64 until = g_get_monotonic_time() + 250000;
  do {
    while (g_main_context_iteration(NULL, FALSE)) {
    }
    g_usleep(1000);
  } while (g_get_monotonic_time() < until);
}

static GtkWidget *find_type(GtkWidget *root, GType type) {
  if (g_type_is_a(G_OBJECT_TYPE(root), type))
    return root;
  for (GtkWidget *child = gtk_widget_get_first_child(root); child;
       child = gtk_widget_get_next_sibling(child)) {
    GtkWidget *found = find_type(child, type);
    if (found)
      return found;
  }
  return NULL;
}

static guint row_count(GtkWidget *root) {
  guint count = ADW_IS_ACTION_ROW(root) ? 1 : 0;
  for (GtkWidget *child = gtk_widget_get_first_child(root); child;
       child = gtk_widget_get_next_sibling(child))
    count += row_count(child);
  return count;
}

static GtkButton *find_button(GtkWidget *root, const char *label) {
  if (GTK_IS_BUTTON(root) &&
      g_strcmp0(gtk_button_get_label(GTK_BUTTON(root)), label) == 0)
    return GTK_BUTTON(root);
  for (GtkWidget *child = gtk_widget_get_first_child(root); child;
       child = gtk_widget_get_next_sibling(child)) {
    GtkButton *found = find_button(child, label);
    if (found)
      return found;
  }
  return NULL;
}

static void snapshot(GtkWindow *window, const char *directory,
                     const char *name) {
  if (!directory)
    return;
  GtkWidget *widget = GTK_WIDGET(window);
  int width = gtk_widget_get_width(widget),
      height = gtk_widget_get_height(widget);
  GdkPaintable *paintable = gtk_widget_paintable_new(widget);
  GtkSnapshot *shot = gtk_snapshot_new();
  gdk_paintable_snapshot(paintable, shot, width, height);
  GskRenderNode *node = gtk_snapshot_free_to_node(shot);
  g_assert_nonnull(node);
  graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, width, height);
  GdkTexture *texture = gsk_renderer_render_texture(
      gtk_native_get_renderer(GTK_NATIVE(window)), node, &bounds);
  char *path = g_build_filename(directory, name, NULL);
  g_assert_true(gdk_texture_save_to_png(texture, path));
  g_free(path);
  g_object_unref(texture);
  gsk_render_node_unref(node);
  g_object_unref(paintable);
}

int main(int argc, char **argv) {
  if (argc < 2)
    return 2;
  adw_init();
  LsgDocument *doc = lsg_document_open_local(argv[1], NULL, NULL);
  g_assert_nonnull(doc);
  ls_parquet_info info;
  g_assert_true(lsg_document_parquet_info(doc, &info));
  GtkWindow *window = GTK_WINDOW(adw_window_new());
  gtk_window_set_default_size(window, 760, 700);
  gtk_window_present(window);
  settle();
  AdwDialog *dialog = lsg_metadata_dialog_new(doc, argv[1]);
  g_assert_nonnull(dialog);
  adw_dialog_present(dialog, GTK_WIDGET(window));
  settle();
  GtkWidget *root = GTK_WIDGET(dialog);
  g_assert_cmpuint(row_count(root), ==, 7);
  snapshot(window, argc > 2 ? argv[2] : NULL, "overview.png");
  GtkDropDown *section = GTK_DROP_DOWN(find_type(root, GTK_TYPE_DROP_DOWN));
  g_assert_nonnull(section);
  gtk_drop_down_set_selected(section, 1);
  settle();
  g_assert_cmpuint(row_count(root), ==, MIN(info.columns, 64));
  snapshot(window, argc > 2 ? argv[2] : NULL, "schema.png");
  gtk_drop_down_set_selected(section, 2);
  settle();
  g_assert_cmpuint(row_count(root), ==, MAX(1, MIN(info.row_groups, 64)));
  if (info.row_groups > 64) {
    GtkButton *next = find_button(root, "Next");
    g_assert_nonnull(next);
    g_signal_emit_by_name(next, "clicked");
    settle();
    g_assert_cmpuint(row_count(root), ==, MIN(info.row_groups - 64, 64));
    GtkButton *previous = find_button(root, "Previous");
    g_assert_nonnull(previous);
    g_signal_emit_by_name(previous, "clicked");
    settle();
    g_assert_cmpuint(row_count(root), ==, 64);
  }
  snapshot(window, argc > 2 ? argv[2] : NULL, "row-groups.png");
  adw_dialog_force_close(dialog);
  gtk_window_destroy(window);
  lsg_document_close(doc);
  g_print("Native metadata views and bounded pagination passed\n");
  return 0;
}
