/*
 * less-sheet GTK frontend — toolchain skeleton (greenfield bootstrap).
 *
 * This is NOT the real frontend: it only proves the GTK4 + libadwaita
 * toolchain compiles and links (and that the Zig core archive is a valid link
 * input). It initializes libadwaita and shows an empty window. It is built by
 * the gate but NOT run there (a real display is a human/GUI pass, not headless).
 * The real grid/UI is authored later, after the contract is frozen.
 */
#include <adwaita.h>

static void
on_activate (GtkApplication *app, gpointer user_data)
{
  (void) user_data;

  GtkWidget *window = adw_application_window_new (app);
  gtk_window_set_title (GTK_WINDOW (window), "less-sheet");
  gtk_window_set_default_size (GTK_WINDOW (window), 960, 640);

  GtkWidget *status = adw_status_page_new ();
  adw_status_page_set_title (ADW_STATUS_PAGE (status), "less-sheet");
  adw_status_page_set_description (ADW_STATUS_PAGE (status),
                                   "GTK frontend toolchain skeleton");
  adw_application_window_set_content (ADW_APPLICATION_WINDOW (window), status);

  gtk_window_present (GTK_WINDOW (window));
}

int
main (int argc, char *argv[])
{
  g_autoptr (AdwApplication) app =
      adw_application_new ("dev.lesssheet.Gtk", G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect (app, "activate", G_CALLBACK (on_activate), NULL);
  return g_application_run (G_APPLICATION (app), argc, argv);
}
