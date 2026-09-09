/* Exercise the real window's drop controller and open path, under a display
 * (Broadway works headlessly). Build after the GTK Meson build:
 * cc -O1 -DLSG_VERSION='"test"' -I apps/gtk/include tools/smoke/drop_open.c \
 *    apps/gtk/build/lesssheet-resources.c apps/gtk/build/liblsgkit.a \
 *    apps/gtk/.core-linux/lib/liblesssheet.a \
 *    $(pkg-config --cflags --libs gtk4 libadwaita-1) -lm -lpthread -o /tmp/drop-open
 * /tmp/drop-open /path/to/fixture.csv.gz
 */
#define main less_sheet_app_main
#include "../../apps/gtk/src/main.c"
#undef main

static gboolean
drop_files(GtkDropTarget *target, GFile **files, gsize count)
{
    GValue value = G_VALUE_INIT;
    g_value_init(&value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(&value, gdk_file_list_new_from_array(files, count));
    gboolean accepted = FALSE;
    g_signal_emit_by_name(target, "drop", &value, 0.0, 0.0, &accepted);
    g_value_unset(&value);
    return accepted;
}

int main(int argc, char **argv)
{
    g_assert_cmpint(argc, ==, 2);
    adw_init();
    App app = {0};
    app.row_estimate = 1;
    app.find = lsg_find_initial();
    app.jump = lsg_jump_initial();
    app.filter = lsg_filter_initial();
    app.font_desc = pango_font_description_from_string("Monospace 10");
    app.header_font_desc = pango_font_description_from_string("Sans Bold 10");
    app.gutter_font_desc = pango_font_description_from_string("Sans 10");
    g_autoptr(AdwApplication) application = adw_application_new(
        "com.lesssheet.DropOpenTest", G_APPLICATION_NON_UNIQUE);
    g_assert_true(g_application_register(G_APPLICATION(application), NULL, NULL));
    ensure_window(&app, GTK_APPLICATION(application));
    launch_page_show(&app);
    g_autoptr(GListModel) controllers = gtk_widget_observe_controllers(GTK_WIDGET(app.window));
    GtkDropTarget *target = NULL;
    for (guint i = 0; i < g_list_model_get_n_items(controllers); ++i) {
        GObject *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_DROP_TARGET(controller)) {
            target = GTK_DROP_TARGET(controller);
            break;
        }
        g_object_unref(controller);
    }
    g_assert_nonnull(target);
    g_assert_cmpint(gtk_drop_target_get_actions(target), ==, GDK_ACTION_COPY | GDK_ACTION_MOVE);

    g_autofree char *dir = g_dir_make_tmp("less-sheet-drop-XXXXXX", NULL);
    g_autofree char *path = g_build_filename(dir, "données with spaces.csv", NULL);
    g_assert_true(g_file_set_contents(path, "a,b\n1,2\n3,4\n", -1, NULL));
    g_autoptr(GFile) first = g_file_new_for_path(path);
    g_autoptr(GFile) second = g_file_new_for_path(argv[1]);
    GFile *files[] = {first, second};
    g_assert_true(drop_files(target, files, 2));
    g_assert_cmpstr(app.doc_path, ==, path);
    g_assert_nonnull(app.doc);

    GValue text = G_VALUE_INIT;
    g_value_init(&text, G_TYPE_STRING);
    g_value_set_string(&text, "not a file drop");
    gboolean accepted = TRUE;
    g_signal_emit_by_name(target, "drop", &text, 0.0, 0.0, &accepted);
    g_assert_false(accepted);
    g_value_unset(&text);
    g_autoptr(GFile) directory = g_file_new_for_path(dir);
    g_assert_false(drop_files(target, &directory, 1));
    g_autoptr(GFile) remote = g_file_new_for_uri("https://example.com/data.csv");
    g_assert_false(drop_files(target, &remote, 1));
    g_assert_cmpstr(app.doc_path, ==, path);

    g_assert_true(drop_files(target, &second, 1));
    g_assert_cmpstr(app.doc_path, ==, argv[1]);
    g_assert_nonnull(app.doc);
    show_error(&app, "Test error", "A new drop should recover from this page.");
    g_assert_true(drop_files(target, &first, 1));
    g_assert_cmpstr(app.doc_path, ==, path);
    g_assert_nonnull(app.doc);

    // This test has no application main loop to drive window teardown. Stop
    // its timers and unparent manually-owned popovers before disposing widgets.
    GtkWindow *window = app.window;
    on_window_destroy(GTK_WIDGET(window), &app);
    gtk_window_destroy(window);
    app_reset_document(&app);
    g_object_unref(target);
    g_assert_cmpint(unlink(path), ==, 0);
    g_assert_cmpint(rmdir(dir), ==, 0);
    puts("drop-open checks passed: launch, replacement, gzip, error recovery, Unicode, multiple files, and rejection");
    return 0;
}
