/*
 * test_formatter.c — RED behavior tests for the display-free cell formatter
 * engine (lsg_formatter.h). Display-free (glib only). Maps the slice-1
 * formatter criteria (ARCH decision 8, reproduced in base-10 arithmetic, NOT
 * ICU): the strict lexical KIND gate, LOSSLESS exact-decimal round-trip +
 * half-even rounding + raw fallback for the unrepresentable, integer grouping,
 * and locale-glyph presentation (injected explicitly so the tests are
 * deterministic regardless of installed locales).
 */
#include <glib.h>
#include <string.h>
#include <lsg_formatter.h>

/* English and German-style glyph sets (decimal point / grouping separator). */
static const LsgLocaleGlyphs EN = { '.', ',', 3 };
static const LsgLocaleGlyphs DE = { ',', '.', 3 };

static void
assert_display (LsgDisplay d, LsgDisplayKind kind, const char *text)
{
  g_assert_cmpint (d.kind, ==, kind);
  g_assert_cmpstr (d.text, ==, text);
  lsg_display_clear (&d);
}

/* --- strict kind gate --- */

static void
test_scalar_kind (void)
{
  g_assert_cmpint (lsg_scalar_kind ("1"), ==, LSG_KIND_INTEGER);
  g_assert_cmpint (lsg_scalar_kind ("-2"), ==, LSG_KIND_INTEGER);
  g_assert_cmpint (lsg_scalar_kind ("+3"), ==, LSG_KIND_INTEGER);
  g_assert_cmpint (lsg_scalar_kind (" 12 "), ==, LSG_KIND_INTEGER); /* edge whitespace trimmed */

  g_assert_cmpint (lsg_scalar_kind ("1.0"), ==, LSG_KIND_DECIMAL);
  g_assert_cmpint (lsg_scalar_kind ("+1e5"), ==, LSG_KIND_DECIMAL);
  g_assert_cmpint (lsg_scalar_kind (".5"), ==, LSG_KIND_DECIMAL);
  g_assert_cmpint (lsg_scalar_kind ("5."), ==, LSG_KIND_DECIMAL);
  g_assert_cmpint (lsg_scalar_kind ("1e400"), ==, LSG_KIND_DECIMAL); /* kind is syntactic */

  g_assert_cmpint (lsg_scalar_kind ("true"), ==, LSG_KIND_BOOLEAN);
  g_assert_cmpint (lsg_scalar_kind ("FALSE"), ==, LSG_KIND_BOOLEAN);

  g_assert_cmpint (lsg_scalar_kind ("2020-01-02"), ==, LSG_KIND_DATE);
  g_assert_cmpint (lsg_scalar_kind ("2020-13-02"), ==, LSG_KIND_NONE); /* invalid month */
  g_assert_cmpint (lsg_scalar_kind ("2020-01-02 "), ==, LSG_KIND_NONE); /* no edge ws for dates */

  g_assert_cmpint (lsg_scalar_kind ("2020-01-02T03:04:05"), ==, LSG_KIND_DATETIME_NAIVE);
  g_assert_cmpint (lsg_scalar_kind ("2020-01-02T03:04:05Z"), ==, LSG_KIND_DATETIME_ZONED);
  g_assert_cmpint (lsg_scalar_kind ("2020-01-02T03:04:05+05:30"), ==, LSG_KIND_DATETIME_ZONED);

  g_assert_cmpint (lsg_scalar_kind (""), ==, LSG_KIND_NONE);
  g_assert_cmpint (lsg_scalar_kind ("abc"), ==, LSG_KIND_NONE);
  g_assert_cmpint (lsg_scalar_kind ("0x1F"), ==, LSG_KIND_NONE);
  g_assert_cmpint (lsg_scalar_kind ("1,000"), ==, LSG_KIND_NONE);
  g_assert_cmpint (lsg_scalar_kind ("NaN"), ==, LSG_KIND_NONE);
  g_assert_cmpint (lsg_scalar_kind ("1e"), ==, LSG_KIND_NONE);
}

/* --- lossless exact-decimal formatting --- */

static void
test_decimal_lossless (void)
{
  /* Grouping, source fraction preserved. */
  assert_display (lsg_format_decimal ("1234.5", TRUE, -1, EN), LSG_DISPLAY_FORMATTED, "1,234.5");
  /* Fixed fraction digits pad exactly. */
  assert_display (lsg_format_decimal ("1000", TRUE, 2, EN), LSG_DISPLAY_FORMATTED, "1,000.00");
  /* HALF-EVEN rounding of the exact value (never through binary float). */
  assert_display (lsg_format_decimal ("0.125", FALSE, 2, EN), LSG_DISPLAY_FORMATTED, "0.12");
  assert_display (lsg_format_decimal ("0.135", FALSE, 2, EN), LSG_DISPLAY_FORMATTED, "0.14");
  /* Exact round trip of scientific spelling. */
  assert_display (lsg_format_decimal ("1e2", FALSE, 0, EN), LSG_DISPLAY_FORMATTED, "100");
}

static void
test_decimal_locale_glyphs (void)
{
  /* German glyphs: '.' groups, ',' is the decimal point. */
  assert_display (lsg_format_decimal ("1234.5", TRUE, 1, DE), LSG_DISPLAY_FORMATTED, "1.234,5");
}

static void
test_decimal_unrepresentable (void)
{
  /* Exponent far outside the exact base-10 range -> raw fallback, never a lie. */
  assert_display (lsg_format_decimal ("1e400", TRUE, 2, EN), LSG_DISPLAY_UNAVAILABLE, "1e400");

  /* Exactly LSG_DECIMAL_MAX_SIG_DIGITS significant digits formats; one more does not. */
  char at_limit[LSG_DECIMAL_MAX_SIG_DIGITS + 1];
  memset (at_limit, '1', LSG_DECIMAL_MAX_SIG_DIGITS);
  at_limit[LSG_DECIMAL_MAX_SIG_DIGITS] = '\0';
  LsgDisplay d_ok = lsg_format_decimal (at_limit, FALSE, -1, EN);
  g_assert_cmpint (d_ok.kind, ==, LSG_DISPLAY_FORMATTED);
  lsg_display_clear (&d_ok);

  char over_limit[LSG_DECIMAL_MAX_SIG_DIGITS + 2];
  memset (over_limit, '1', LSG_DECIMAL_MAX_SIG_DIGITS + 1);
  over_limit[LSG_DECIMAL_MAX_SIG_DIGITS + 1] = '\0';
  assert_display (lsg_format_decimal (over_limit, FALSE, -1, EN), LSG_DISPLAY_UNAVAILABLE, over_limit);
}

/* --- integer grouping --- */

static void
test_integer_grouping (void)
{
  assert_display (lsg_format_integer ("1000000", TRUE, EN), LSG_DISPLAY_FORMATTED, "1,000,000");
  assert_display (lsg_format_integer ("1000000", TRUE, DE), LSG_DISPLAY_FORMATTED, "1.000.000");
  /* No grouping requested -> the source spelling, unchanged. */
  assert_display (lsg_format_integer ("1000000", FALSE, EN), LSG_DISPLAY_ORIGINAL, "1000000");
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/formatter/scalar-kind", test_scalar_kind);
  g_test_add_func ("/formatter/decimal-lossless", test_decimal_lossless);
  g_test_add_func ("/formatter/decimal-locale-glyphs", test_decimal_locale_glyphs);
  g_test_add_func ("/formatter/decimal-unrepresentable", test_decimal_unrepresentable);
  g_test_add_func ("/formatter/integer-grouping", test_integer_grouping);
  return g_test_run ();
}
