/* Run the production application with independent capture window state.
 * This helper uses the production application and capture state handlers.
 * NON_UNIQUE prevents forwarding into another open window.
 */
#include <adwaita.h>

static AdwApplication *capture_application_new(const char *id,
                                               GApplicationFlags flags) {
  return adw_application_new(id, flags | G_APPLICATION_NON_UNIQUE);
}

#define adw_application_new capture_application_new
#define main less_sheet_main
#include "../../apps/gtk/src/main.c"
#undef main
#undef adw_application_new

int main(int argc, char **argv) { return less_sheet_main(argc, argv); }
