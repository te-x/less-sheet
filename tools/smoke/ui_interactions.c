/* Native GTK interaction regression: real pointer drag and Find/Where tabs.
 * Run on an isolated X11 display (Xvfb), never the user's desktop.
 * Build like drop_open.c, adding -lX11 -lXtst.
 */
#define main less_sheet_app_main
#include "../../apps/gtk/src/main.c"
#undef main
#include "../../apps/gtk/src/lsg_document_internal.h"
#include <gdk/x11/gdkx.h>
#include <X11/extensions/XTest.h>

static void
pump(unsigned ms)
{
    gint64 end = g_get_monotonic_time() + ms * 1000;
    do {
        while (g_main_context_iteration(NULL, FALSE)) {}
        g_usleep(1000);
    } while (g_get_monotonic_time() < end);
}

static void
await_search(App *app)
{
    gint64 end = g_get_monotonic_time() + 30000000;
    while (ls_search_poll(app->doc->doc).state != LS_SEARCH_DONE) {
        g_assert_cmpint(g_get_monotonic_time(), <, end);
        pump(1);
    }
}

static void
drag_end(GtkDragSource *source, GdkDrag *drag, gboolean delete_data, gpointer data)
{
    (void)source;
    (void)drag;
    g_assert_false(delete_data);
    ++*(unsigned *)data;
}

static gboolean
log_accept(GtkDropTarget *target, GdkDrop *drop, gpointer data)
{
    (void)data;
    g_autofree char *formats = gdk_content_formats_to_string(gdk_drop_get_formats(drop));
    // GtkDropTarget::accept uses first-wins, so this logger must return the
    // default handler's decision; returning FALSE would reject every drag.
    gboolean accepted = (gdk_drop_get_actions(drop) & gtk_drop_target_get_actions(target)) != 0
        && gdk_content_formats_match_gtype(gtk_drop_target_get_formats(target),
                                          gdk_drop_get_formats(drop)) != G_TYPE_INVALID;
    g_print("Incoming drop: accepted=%d actions=%u formats=%s\n", accepted, gdk_drop_get_actions(drop), formats);
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
        "com.lesssheet.InteractionTest", G_APPLICATION_NON_UNIQUE);
    g_assert_true(g_application_register(G_APPLICATION(application), NULL, NULL));
    ensure_window(&app, GTK_APPLICATION(application));
    launch_page_show(&app);
    g_autoptr(GListModel) controllers = gtk_widget_observe_controllers(GTK_WIDGET(app.window));
    for (guint i = 0; i < g_list_model_get_n_items(controllers); ++i) {
        g_autoptr(GObject) controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_DROP_TARGET(controller))
            g_signal_connect(controller, "accept", G_CALLBACK(log_accept), NULL);
    }
    if (strcmp(argv[1], "--listen") == 0) {
        gtk_window_set_title(app.window, "less-sheet drop diagnostic");
        gtk_window_present(app.window);
        while (app.window != NULL) pump(20);
        return 0;
    }
    gtk_window_present(app.window);

    GtkWidget *source = gtk_window_new();
    gtk_window_set_default_size(GTK_WINDOW(source), 250, 200);
    GtkWidget *button = gtk_button_new_with_label("Drag fixture");
    gtk_window_set_child(GTK_WINDOW(source), button);
    GtkDragSource *drag = gtk_drag_source_new();
    unsigned ended = 0;
    g_signal_connect(drag, "drag-end", G_CALLBACK(drag_end), &ended);
    gtk_drag_source_set_actions(drag, GDK_ACTION_COPY | GDK_ACTION_MOVE);
    g_autofree char *uri = g_filename_to_uri(argv[1], NULL, NULL);
    g_autofree char *payload = g_strconcat(uri, "\r\n", NULL);
    g_autoptr(GBytes) bytes = g_bytes_new(payload, strlen(payload));
    g_autoptr(GdkContentProvider) content = gdk_content_provider_new_for_bytes("text/uri-list", bytes);
    gtk_drag_source_set_content(drag, content);
    gtk_widget_add_controller(button, GTK_EVENT_CONTROLLER(drag));
    gtk_window_present(GTK_WINDOW(source));
    pump(300);

    GdkDisplay *display = gtk_widget_get_display(source);
    g_assert_true(GDK_IS_X11_DISPLAY(display));
    Display *xdisplay = gdk_x11_display_get_xdisplay(display);
    Window src = gdk_x11_surface_get_xid(gtk_native_get_surface(GTK_NATIVE(source)));
    Window dst = gdk_x11_surface_get_xid(gtk_native_get_surface(GTK_NATIVE(app.window)));
    XMoveWindow(xdisplay, dst, 10, 10);
    XMoveWindow(xdisplay, src, 1200, 100);
    XSync(xdisplay, False);
    pump(100);
    g_autofree char *dir = g_dir_make_tmp("less-sheet-drag-XXXXXX", NULL);
    g_autofree char *replacement = g_build_filename(dir, "données with spaces.csv", NULL);
    g_assert_true(g_file_set_contents(replacement, "a,b\nneedle,other\n", -1, NULL));
    for (unsigned pass = 0; pass < 3; ++pass) {
        if (pass > 0) {
            gtk_drag_source_set_actions(drag, GDK_ACTION_MOVE);
            g_autofree char *replacement_uri = g_filename_to_uri(pass == 1 ? replacement : dir, NULL, NULL);
            g_autoptr(GBytes) replacement_bytes = g_bytes_new(replacement_uri, strlen(replacement_uri));
            g_autoptr(GdkContentProvider) replacement_content = gdk_content_provider_new_for_bytes("text/uri-list", replacement_bytes);
            gtk_drag_source_set_content(drag, replacement_content);
        }
        XTestFakeMotionEvent(xdisplay, -1, 1300, 200, 0);
        XSync(xdisplay, False);
        pump(100);
        XTestFakeButtonEvent(xdisplay, 1, True, 0);
        XSync(xdisplay, False);
        pump(100);
        for (int x = 1280; x >= 400; x -= 40) {
            XTestFakeMotionEvent(xdisplay, -1, x, 250, 0);
            XSync(xdisplay, False);
            pump(20);
        }
        pump(100);
        XTestFakeButtonEvent(xdisplay, 1, False, 0);
        XSync(xdisplay, False);
        pump(500);
        g_assert_nonnull(app.doc);
        g_assert_cmpstr(app.doc_path, ==, pass == 0 ? argv[1] : replacement);
        g_assert_cmpuint(ended, ==, pass + 1);
        puts(pass == 0 ? "native COPY drag onto launch page passed" : pass == 1 ? "native MOVE-only drag onto grid passed without requesting source deletion" : "directory drop rejected without requesting source deletion");
    }

    g_autoptr(GFile) fixture = g_file_new_for_path(argv[1]);
    open_file(&app, fixture);
    open_find(&app);
    gtk_editable_set_text(app.find_entry, "needle");
    pump(300);
    await_search(&app);
    ls_search_status before = ls_search_poll(app.doc->doc);
    g_assert_cmpuint(before.total, >, 0);
    gtk_stack_set_visible_child_name(app.find_stack, "where");
    await_search(&app);
    for (unsigned i = 0; i < 4; ++i) {
        gtk_stack_set_visible_child_name(app.find_stack, "text");
        ls_search_status after = ls_search_poll(app.doc->doc);
        g_assert_cmpint(after.state, ==, LS_SEARCH_DONE);
        g_assert_cmpuint(after.total, ==, before.total);
        g_assert_true(after.total_exact);
        g_assert_false(app.find.display.has_progress);
        gtk_stack_set_visible_child_name(app.find_stack, "where");
        g_assert_cmpint(ls_search_poll(app.doc->doc).state, ==, LS_SEARCH_DONE);
    }
    puts("Find / Where tab round trips reuse completed results");
    gtk_window_destroy(GTK_WINDOW(source));
    GtkWindow *window = app.window;
    on_window_destroy(GTK_WIDGET(window), &app);
    gtk_window_destroy(window);
    app_reset_document(&app);
    g_assert_cmpint(unlink(replacement), ==, 0);
    g_assert_cmpint(rmdir(dir), ==, 0);
    return 0;
}
