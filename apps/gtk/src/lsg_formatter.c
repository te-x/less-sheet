/*
 * lsg_formatter.c — RED SEED for the cell formatter engine (lsg_formatter.h).
 * Compiles clean under -Werror (conformance GREEN) but classifies nothing and
 * formats nothing (behavior RED): it returns LSG_KIND_NONE for every value and
 * the original spelling for every format request. tests/test_formatter.c fails
 * here and turns GREEN as the strict kind gate + the base-10 exact-decimal
 * arithmetic engine are implemented.
 */
#include <lsg_formatter.h>

LsgScalarKind
lsg_scalar_kind (const char *raw)
{
  (void) raw;
  return LSG_KIND_NONE; /* SEED: classifies nothing */
}

LsgLocaleGlyphs
lsg_locale_glyphs_current (void)
{
  LsgLocaleGlyphs g = { '.', ',', 3 };
  return g;
}

void
lsg_display_clear (LsgDisplay *display)
{
  if (display != NULL)
    {
      g_free (display->text);
      display->text = NULL;
    }
}

static LsgDisplay
seed_original (const char *raw)
{
  LsgDisplay d;
  d.kind = LSG_DISPLAY_ORIGINAL;
  d.text = g_strdup (raw != NULL ? raw : "");
  return d;
}

LsgDisplay
lsg_format_decimal (const char *raw, gboolean grouping, gint fraction_digits, LsgLocaleGlyphs glyphs)
{
  (void) grouping;
  (void) fraction_digits;
  (void) glyphs;
  return seed_original (raw); /* SEED: never formats */
}

LsgDisplay
lsg_format_integer (const char *raw, gboolean grouping, LsgLocaleGlyphs glyphs)
{
  (void) grouping;
  (void) glyphs;
  return seed_original (raw); /* SEED: never groups */
}
