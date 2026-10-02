/* Exercise the production update action on a real GTK display. Build:
 * cc -O2 -std=c11 -Wall -Wextra -Werror -DLSG_VERSION='"0.1.5"' \
 *   -Iapps/gtk/include tools/smoke/gtk_updates.c \
 *   apps/gtk/build/lesssheet-resources.c apps/gtk/build/liblsgkit.a \
 *   apps/gtk/.core-linux/lib/liblesssheet.a \
 *   $(pkg-config --cflags --libs gtk4 libadwaita-1) -o /tmp/gtk-updates-smoke
 * /tmp/gtk-updates-smoke          # local deterministic responses
 * /tmp/gtk-updates-smoke --live   # latest public release, actual HTTPS
 * The separate application id and NON_UNIQUE flag leave existing windows alone.
 */
#define main less_sheet_app_main
#include "../../apps/gtk/src/main.c"
#undef main
#include <glib/gstdio.h>

#define HASH "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

static void pump(guint milliseconds) {
  gint64 end = g_get_monotonic_time() + milliseconds * 1000;
  do {
    while (g_main_context_iteration(NULL, FALSE)) {
    }
    g_usleep(1000);
  } while (g_get_monotonic_time() < end);
}

static void await_enabled(GAction *action, guint seconds) {
  gint64 end = g_get_monotonic_time() + seconds * G_USEC_PER_SEC;
  while (!g_action_get_enabled(action)) {
    g_assert_cmpint(g_get_monotonic_time(), <, end);
    pump(10);
  }
}

static AdwAlertDialog *visible_dialog(App *app) {
  AdwDialog *dialog = adw_application_window_get_visible_dialog(
      ADW_APPLICATION_WINDOW(app->window));
  g_assert_true(ADW_IS_ALERT_DIALOG(dialog));
  return ADW_ALERT_DIALOG(dialog);
}

static void write_helper(const char *path, const char *version) {
  g_autofree char *script = NULL;
  if (version == NULL)
    script = g_strdup("#!/bin/sh\nexit 22\n");
  else if (strcmp(version, "sleep") == 0)
    script = g_strdup("#!/bin/sh\nexec /usr/bin/sleep 30\n");
  else
    script = g_strdup_printf("#!/bin/sh\nprintf '%%s\\n' '" HASH
                             "  less-sheet-%s%s'\n",
                             version, update_asset_suffix());
  g_assert_true(g_file_set_contents(path, script, -1, NULL));
  g_assert_cmpint(g_chmod(path, 0700), ==, 0);
}

static void check_result(App *app, GAction *action, const char *heading,
                         const char *expected_version) {
  g_action_activate(action, NULL);
  g_assert_false(g_action_get_enabled(action));
  AdwAlertDialog *dialog = visible_dialog(app);
  g_assert_cmpstr(adw_alert_dialog_get_heading(dialog), ==,
                  "Checking for Updates…");
  await_enabled(action, 35);
  g_assert_cmpstr(adw_alert_dialog_get_heading(dialog), ==, heading);
  const char *uri =
      g_object_get_data(G_OBJECT(dialog), "lsg-update-download-uri");
  if (expected_version != NULL) {
    g_autofree char *expected = g_strdup_printf(
        "https://github.com/te-x/less-sheet/releases/download/v%s/"
        "less-sheet-%s%s",
        expected_version, expected_version, update_asset_suffix());
    g_assert_cmpstr(uri, ==, expected);
    g_assert_true(adw_alert_dialog_has_response(dialog, "download"));
    g_assert_true(GTK_IS_WINDOW(gtk_widget_get_root(GTK_WIDGET(dialog))));
  } else {
    g_assert_null(uri);
    g_assert_false(adw_alert_dialog_has_response(dialog, "download"));
  }
  g_print("PASS: %s\n", heading);
  adw_dialog_close(ADW_DIALOG(dialog));
  pump(400);
}

int main(int argc, char **argv) {
  gboolean live = argc == 2 && strcmp(argv[1], "--live") == 0;
  g_assert_true(argc == 1 || live);
  g_setenv("GSK_RENDERER", LSG_DEFAULT_GSK_RENDERER, FALSE);
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
      "com.lesssheet.UpdateCheckTest", G_APPLICATION_NON_UNIQUE);
  g_assert_true(g_application_register(G_APPLICATION(application), NULL, NULL));
  ensure_window(&app, GTK_APPLICATION(application));
  launch_page_show(&app);
  register_app_shortcuts(&app, G_APPLICATION(application));
  gtk_window_present(app.window);
  pump(300);
  g_assert_true(gtk_widget_get_mapped(GTK_WIDGET(app.window)));
  GAction *action =
      g_action_map_lookup_action(G_ACTION_MAP(application), "check-updates");
  g_assert_nonnull(action);
  g_autoptr(GMenuModel) menu = build_primary_menu(&app);
  g_assert_cmpint(g_menu_model_get_n_items(menu), ==, 4);

  if (live)
    check_result(&app, action, "You're Up to Date", NULL);
  else {
    g_autofree char *dir = g_dir_make_tmp("less-sheet-updates-XXXXXX", NULL);
    g_assert_nonnull(dir);
    g_autofree char *helper = g_build_filename(dir, "curl", NULL);
    g_autofree char *original_path = g_strdup(g_getenv("PATH"));
    g_autofree char *path = g_strconcat(dir, ":", original_path, NULL);
    g_setenv("PATH", path, TRUE);
    write_helper(helper, "99.1.10");
    check_result(&app, action, "Update Available", "99.1.10");
    write_helper(helper, LSG_VERSION);
    check_result(&app, action, "You're Up to Date", NULL);
    write_helper(helper, "0.0.0");
    check_result(&app, action, "You're Up to Date", NULL);
    write_helper(helper, NULL);
    check_result(&app, action, "Could Not Check for Updates", NULL);
    write_helper(helper, "99.1.10-beta");
    check_result(&app, action, "Could Not Check for Updates", NULL);
    write_helper(helper, "sleep");
    g_action_activate(action, NULL);
    g_assert_false(g_action_get_enabled(action));
    /* A second activation cannot start another request. */
    g_action_activate(action, NULL);
    g_assert_cmpuint(
        g_list_model_get_n_items(adw_application_window_get_dialogs(
            ADW_APPLICATION_WINDOW(app.window))),
        ==, 1);
    adw_dialog_close(ADW_DIALOG(visible_dialog(&app)));
    await_enabled(action, 2);
    pump(400);
    g_assert_cmpuint(
        g_list_model_get_n_items(adw_application_window_get_dialogs(
            ADW_APPLICATION_WINDOW(app.window))),
        ==, 0);
    g_print("PASS: cancel and repeated invocation\n");
    g_assert_cmpint(g_unlink(helper), ==, 0);
    g_setenv("PATH", dir, TRUE);
    g_action_activate(action, NULL);
    g_assert_true(g_action_get_enabled(action));
    g_assert_cmpstr(adw_alert_dialog_get_heading(visible_dialog(&app)), ==,
                    "Could Not Check for Updates");
    adw_dialog_close(ADW_DIALOG(visible_dialog(&app)));
    pump(400);
    g_print("PASS: missing download helper\n");
    g_setenv("PATH", original_path, TRUE);
    g_assert_cmpint(g_rmdir(dir), ==, 0);
  }
  gtk_window_destroy(app.window);
  pump(100);
  return 0;
}
