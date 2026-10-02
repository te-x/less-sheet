/* Private, display-free release metadata parsing. SHA256SUMS is already
 * published with every release; no JSON library or startup work is needed. */
#ifndef LSG_UPDATE_RELEASE_H
#define LSG_UPDATE_RELEASE_H

#include <glib.h>
#include <string.h>

#define LSG_UPDATE_CHECKSUMS_URL                                              \
  "https://github.com/te-x/less-sheet/releases/latest/download/SHA256SUMS"
#define LSG_UPDATE_METADATA_LIMIT (256 * 1024)

typedef struct
{
  guint64 part[3];
} LsgUpdateVersion;

static inline gboolean
lsg_update_version_parse (const char *text, LsgUpdateVersion *version)
{
  if (text == NULL)
    return FALSE;
  for (guint i = 0; i < 3; i++)
    {
      const char *start = text;
      guint64 value = 0;
      if (!g_ascii_isdigit (*text))
        return FALSE;
      while (g_ascii_isdigit (*text))
        {
          guint digit = (guint)(*text++ - '0');
          if (value > (G_MAXUINT64 - digit) / 10)
            return FALSE;
          value = value * 10 + digit;
        }
      if (*start == '0' && text - start > 1)
        return FALSE;
      version->part[i] = value;
      if (i < 2 && *text++ != '.')
        return FALSE;
    }
  return *text == '\0';
}

static inline int
lsg_update_version_compare (const LsgUpdateVersion *a,
                            const LsgUpdateVersion *b)
{
  for (guint i = 0; i < 3; i++)
    if (a->part[i] != b->part[i])
      return a->part[i] > b->part[i] ? 1 : -1;
  return 0;
}

/* Match exactly one architecture/package asset. Reject malformed checksums,
 * prerelease filenames, traversal, and ambiguous matching entries. Both
 * returned strings are owned; outputs are unchanged on failure. */
static inline gboolean
lsg_update_release_parse (const char *text, gsize length, const char *suffix,
                          char **version_out, char **uri_out)
{
  if (text == NULL || suffix == NULL || length > LSG_UPDATE_METADATA_LIMIT
      || memchr (text, '\0', length) != NULL)
    return FALSE;
  g_autofree char *bounded = g_strndup (text, length);
  g_auto (GStrv) lines = g_strsplit (bounded, "\n", -1);
  g_autofree char *found = NULL;
  g_autofree char *filename = NULL;
  for (guint i = 0; lines[i] != NULL; i++)
    {
      char *line = g_strchomp (lines[i]);
      gsize size = strlen (line);
      if (size < 67 || line[64] != ' ' || (line[65] != ' ' && line[65] != '*'))
        continue;
      const char *name = line + 66;
      if (!g_str_has_prefix (name, "less-sheet-")
          || !g_str_has_suffix (name, suffix))
        continue;
      if (strlen (name) <= strlen ("less-sheet-") + strlen (suffix))
        return FALSE;
      for (guint j = 0; j < 64; j++)
        if (!g_ascii_isxdigit (line[j]))
          return FALSE;
      gsize version_length
          = strlen (name) - strlen ("less-sheet-") - strlen (suffix);
      g_autofree char *version
          = g_strndup (name + strlen ("less-sheet-"), version_length);
      LsgUpdateVersion parsed;
      if (found != NULL || !lsg_update_version_parse (version, &parsed))
        return FALSE;
      found = g_steal_pointer (&version);
      filename = g_strdup (name);
    }
  if (found == NULL)
    return FALSE;
  *uri_out = g_strdup_printf (
      "https://github.com/te-x/less-sheet/releases/download/v%s/%s", found,
      filename);
  *version_out = g_steal_pointer (&found);
  return TRUE;
}

#endif
