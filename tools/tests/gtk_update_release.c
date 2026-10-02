/* Retained, display-free updater regression tests. Run:
 * cc -std=c11 -Wall -Wextra -Werror tools/tests/gtk_update_release.c \
 *   $(pkg-config --cflags --libs glib-2.0) -o /tmp/gtk-update-release-tests
 * /tmp/gtk-update-release-tests
 */
#include "../../apps/gtk/src/lsg_update_release.h"

#define HASH "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

static void version_order(void) {
  const char *versions[] = {"0.1.9", "0.1.10", "0.2.0", "1.0.0",
                            "18446744073709551615.0.0"};
  for (guint i = 0; i < G_N_ELEMENTS(versions); i++)
    for (guint j = 0; j < G_N_ELEMENTS(versions); j++) {
      LsgUpdateVersion a, b;
      g_assert_true(lsg_update_version_parse(versions[i], &a));
      g_assert_true(lsg_update_version_parse(versions[j], &b));
      g_assert_cmpint(lsg_update_version_compare(&a, &b), ==,
                      i < j   ? -1
                      : i > j ? 1
                              : 0);
    }
}

static void invalid_versions(void) {
  const char *invalid[] = {NULL,
                           "",
                           "1",
                           "1.0",
                           "1.0.0.0",
                           "v1.0.0",
                           "01.0.0",
                           "1.00.0",
                           "1.0.00",
                           "-1.0.0",
                           "1.0.0-beta",
                           "1.0.0+build",
                           "1.0.0\n",
                           "1.0. 0",
                           "18446744073709551616.0.0",
                           "1.18446744073709551616.0",
                           "1.0.18446744073709551616"};
  LsgUpdateVersion parsed;
  for (guint i = 0; i < G_N_ELEMENTS(invalid); i++)
    g_assert_false(lsg_update_version_parse(invalid[i], &parsed));
}

static void assert_release(const char *metadata, const char *suffix,
                           const char *version, const char *filename) {
  g_autofree char *actual = NULL;
  g_autofree char *uri = NULL;
  g_assert_true(lsg_update_release_parse(metadata, strlen(metadata), suffix,
                                         &actual, &uri));
  g_assert_cmpstr(actual, ==, version);
  g_autofree char *expected = g_strdup_printf(
      "https://github.com/te-x/less-sheet/releases/download/v%s/%s", version,
      filename);
  g_assert_cmpstr(uri, ==, expected);
}

static void asset_selection(void) {
  const char *metadata = HASH "  less-sheet-0.1.10-linux-x86_64.tar.gz\n" HASH
                              "  less-sheet-0.1.10-linux-aarch64.tar.gz\n" HASH
                              "  less-sheet-0.1.10-macos-arm64.dmg\n" HASH
                              " *less-sheet-0.1.10-x86_64.flatpak\r\n" HASH
                              "  less-sheet-0.1.10-aarch64.flatpak";
  const char *suffixes[] = {"-linux-x86_64.tar.gz", "-linux-aarch64.tar.gz",
                            "-x86_64.flatpak", "-aarch64.flatpak"};
  for (guint i = 0; i < G_N_ELEMENTS(suffixes); i++) {
    g_autofree char *name = g_strconcat("less-sheet-0.1.10", suffixes[i], NULL);
    assert_release(metadata, suffixes[i], "0.1.10", name);
  }
}

static void assert_rejected(const char *metadata, gsize length) {
  char *version = NULL;
  char *uri = NULL;
  g_assert_false(lsg_update_release_parse(
      metadata, length, "-linux-x86_64.tar.gz", &version, &uri));
  g_assert_null(version);
  g_assert_null(uri);
}

static void malformed_metadata(void) {
  const char *invalid[] = {
      "",
      "<html>Not Found</html>",
      HASH "  less-sheet-0.1.10-linux-aarch64.tar.gz\n",
      "bad-checksum  less-sheet-0.1.10-linux-x86_64.tar.gz\n",
      "g123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      "  less-sheet-0.1.10-linux-x86_64.tar.gz\n",
      HASH "  less-sheet-0.1.10-beta-linux-x86_64.tar.gz\n",
      HASH "  less-sheet-01.1.10-linux-x86_64.tar.gz\n",
      HASH "  less-sheet-18446744073709551616.0.0-linux-x86_64.tar.gz\n",
      HASH "  less-sheet-../../0.1.10-linux-x86_64.tar.gz\n",
      HASH "  less-sheet--linux-x86_64.tar.gz\n",
      HASH "  less-sheet-0.1.10-linux-x86_64.tar.gz\n" HASH
           "  less-sheet-0.1.10-linux-x86_64.tar.gz\n",
      HASH "  less-sheet-0.1.10-linux-x86_64.tar.gz\n" HASH
           "  less-sheet-0.2.0-linux-x86_64.tar.gz\n",
  };
  for (guint i = 0; i < G_N_ELEMENTS(invalid); i++)
    assert_rejected(invalid[i], strlen(invalid[i]));
  const char embedded_nul[] =
      HASH "  less-sheet-0.1.10-linux-x86_64.tar.gz\n\0junk";
  assert_rejected(embedded_nul, sizeof embedded_nul - 1);
  g_autofree char *oversized = g_malloc0(LSG_UPDATE_METADATA_LIMIT + 2);
  memset(oversized, 'x', LSG_UPDATE_METADATA_LIMIT + 1);
  assert_rejected(oversized, LSG_UPDATE_METADATA_LIMIT + 1);
  assert_rejected(NULL, 0);
}

int main(int argc, char **argv) {
  g_test_init(&argc, &argv, NULL);
  g_test_add_func("/updates/version-order", version_order);
  g_test_add_func("/updates/invalid-versions", invalid_versions);
  g_test_add_func("/updates/asset-selection", asset_selection);
  g_test_add_func("/updates/malformed-metadata", malformed_metadata);
  return g_test_run();
}
