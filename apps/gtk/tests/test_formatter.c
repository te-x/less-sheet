/*
 * test_formatter.c — RED behavior tests for the display-free cell formatter
 * engine (lsg_formatter.h). Display-free (glib only). Two parts:
 *
 *   SLICE 1 (green, unchanged): the strict lexical KIND gate, LOSSLESS exact-
 *   decimal round-trip + half-even + raw fallback, integer grouping, and
 *   locale-glyph presentation (injected explicitly for determinism).
 *
 *   SETTINGS + DIALECT SLICE (G9, RED): the type+options DISPATCHER
 *   (`lsg_format_cell`) — number grouping / fixed fraction (half-even) /
 *   UNAVAILABLE gating, AUTO / no-option / kind-mismatch -> raw, and the
 *   date/datetime presets (Original preserves the raw byte-for-byte; a
 *   localized preset yields a non-original FORMATTED string; naive vs zoned
 *   semantics are honored at the gate). The exact localized date STRINGS are a
 *   reviewer/host check (CLDR output is not a robust frozen pin) — the gate
 *   pins the deterministic core under the C locale. RED against the seeded
 *   `lsg_format_cell` (always returns the raw spelling).
 */
#include <glib.h>
#include <locale.h>
#include <string.h>
#include <lesssheet.h>
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

/* ========================================================================= */
/* G9 — the type+options dispatcher + date presets                           */
/* ========================================================================= */

static LsgColumnFormatOptions
opt (gboolean grouping, gboolean has_frac, gint frac, LsgDatePreset preset)
{
  LsgColumnFormatOptions o = { grouping, has_frac, frac, preset };
  return o;
}

/* --- number dispatch (deterministic under injected glyphs) --- */

static void
test_dispatch_number (void)
{
  LsgColumnFormatOptions group = opt (TRUE, FALSE, 0, LSG_DATE_PRESET_ORIGINAL);
  LsgColumnFormatOptions frac2 = opt (FALSE, TRUE, 2, LSG_DATE_PRESET_ORIGINAL);
  LsgColumnFormatOptions frac39 = opt (FALSE, TRUE, 39, LSG_DATE_PRESET_ORIGINAL);
  LsgColumnFormatOptions plain = opt (FALSE, FALSE, 0, LSG_DATE_PRESET_ORIGINAL);

  /* INTEGER column: grouping formats an integer-kind value; no grouping / a
   * decimal-kind value under an integer column -> raw. */
  assert_display (lsg_format_cell ("1000000", LS_COLUMN_TYPE_INTEGER,
                                   LS_COLUMN_DATETIME_NONE, group, EN),
                  LSG_DISPLAY_FORMATTED, "1,000,000");
  assert_display (lsg_format_cell ("1000000", LS_COLUMN_TYPE_INTEGER,
                                   LS_COLUMN_DATETIME_NONE, plain, EN),
                  LSG_DISPLAY_ORIGINAL, "1000000");
  assert_display (lsg_format_cell ("1.5", LS_COLUMN_TYPE_INTEGER,
                                   LS_COLUMN_DATETIME_NONE, group, EN),
                  LSG_DISPLAY_ORIGINAL, "1.5"); /* kind mismatch */

  /* DECIMAL column: fixed fraction (half-even) + grouping on a decimal-kind
   * value; an integer-kind or non-numeric value -> raw; over-range fraction or
   * an unrepresentable value -> UNAVAILABLE. */
  assert_display (lsg_format_cell ("0.125", LS_COLUMN_TYPE_DECIMAL,
                                   LS_COLUMN_DATETIME_NONE, frac2, EN),
                  LSG_DISPLAY_FORMATTED, "0.12");
  assert_display (lsg_format_cell ("1234.5", LS_COLUMN_TYPE_DECIMAL,
                                   LS_COLUMN_DATETIME_NONE, group, EN),
                  LSG_DISPLAY_FORMATTED, "1,234.5");
  assert_display (lsg_format_cell ("5", LS_COLUMN_TYPE_DECIMAL,
                                   LS_COLUMN_DATETIME_NONE, frac2, EN),
                  LSG_DISPLAY_ORIGINAL, "5"); /* integer-kind under a decimal column */
  assert_display (lsg_format_cell ("abc", LS_COLUMN_TYPE_DECIMAL,
                                   LS_COLUMN_DATETIME_NONE, frac2, EN),
                  LSG_DISPLAY_ORIGINAL, "abc");
  assert_display (lsg_format_cell ("1.5", LS_COLUMN_TYPE_DECIMAL,
                                   LS_COLUMN_DATETIME_NONE, frac39, EN),
                  LSG_DISPLAY_UNAVAILABLE, "1.5"); /* fraction > ceiling */
  assert_display (lsg_format_cell ("1e400", LS_COLUMN_TYPE_DECIMAL,
                                   LS_COLUMN_DATETIME_NONE, frac2, EN),
                  LSG_DISPLAY_UNAVAILABLE, "1e400"); /* unrepresentable */
}

static void
test_dispatch_auto_and_text (void)
{
  LsgColumnFormatOptions a = lsg_column_format_options_auto ();
  LsgColumnFormatOptions group = opt (TRUE, FALSE, 0, LSG_DATE_PRESET_ORIGINAL);

  /* AUTO -> raw for every kind. */
  assert_display (lsg_format_cell ("1000000", LS_COLUMN_TYPE_INTEGER,
                                   LS_COLUMN_DATETIME_NONE, a, EN),
                  LSG_DISPLAY_ORIGINAL, "1000000");
  assert_display (lsg_format_cell ("2020-01-02", LS_COLUMN_TYPE_DATE,
                                   LS_COLUMN_DATETIME_NONE, a, EN),
                  LSG_DISPLAY_ORIGINAL, "2020-01-02");

  /* TEXT / BOOLEAN columns have no v1 controls -> always raw. */
  assert_display (lsg_format_cell ("hello", LS_COLUMN_TYPE_TEXT,
                                   LS_COLUMN_DATETIME_NONE, group, EN),
                  LSG_DISPLAY_ORIGINAL, "hello");
  assert_display (lsg_format_cell ("true", LS_COLUMN_TYPE_BOOLEAN,
                                   LS_COLUMN_DATETIME_NONE, group, EN),
                  LSG_DISPLAY_ORIGINAL, "true");
}

/* A localized date/datetime preset yields a non-original FORMATTED string. */
static void
assert_formatted_non_original (LsgDisplay d, const char *raw)
{
  g_assert_cmpint (d.kind, ==, LSG_DISPLAY_FORMATTED);
  g_assert_nonnull (d.text);
  g_assert_true (g_strcmp0 (d.text, raw) != 0);
  lsg_display_clear (&d);
}

static void
test_dispatch_dates (void)
{
  LsgColumnFormatOptions orig = opt (FALSE, FALSE, 0, LSG_DATE_PRESET_ORIGINAL);
  LsgColumnFormatOptions shortp = opt (FALSE, FALSE, 0, LSG_DATE_PRESET_LOCALIZED_SHORT);
  LsgColumnFormatOptions medp = opt (FALSE, FALSE, 0, LSG_DATE_PRESET_LOCALIZED_MEDIUM);

  /* DATE: Original preserves the raw; a localized preset formats; a non-date
   * value falls back to raw. */
  assert_display (lsg_format_cell ("2020-01-02", LS_COLUMN_TYPE_DATE,
                                   LS_COLUMN_DATETIME_NONE, orig, EN),
                  LSG_DISPLAY_ORIGINAL, "2020-01-02");
  assert_formatted_non_original (
      lsg_format_cell ("2020-01-02", LS_COLUMN_TYPE_DATE, LS_COLUMN_DATETIME_NONE,
                       shortp, EN),
      "2020-01-02");
  assert_display (lsg_format_cell ("notadate", LS_COLUMN_TYPE_DATE,
                                   LS_COLUMN_DATETIME_NONE, shortp, EN),
                  LSG_DISPLAY_ORIGINAL, "notadate");

  /* DATETIME naive + zoned each format under the matching column semantics. */
  assert_formatted_non_original (
      lsg_format_cell ("2020-01-02T03:04:05", LS_COLUMN_TYPE_DATETIME,
                       LS_COLUMN_DATETIME_NAIVE, medp, EN),
      "2020-01-02T03:04:05");
  assert_formatted_non_original (
      lsg_format_cell ("2020-01-02T03:04:05+05:00", LS_COLUMN_TYPE_DATETIME,
                       LS_COLUMN_DATETIME_ZONED, medp, EN),
      "2020-01-02T03:04:05+05:00");

  /* A value whose datetime semantics disagree with the column -> raw. */
  assert_display (lsg_format_cell ("2020-01-02T03:04:05", LS_COLUMN_TYPE_DATETIME,
                                   LS_COLUMN_DATETIME_ZONED, medp, EN),
                  LSG_DISPLAY_ORIGINAL, "2020-01-02T03:04:05");
  assert_display (lsg_format_cell ("2020-01-02T03:04:05Z", LS_COLUMN_TYPE_DATETIME,
                                   LS_COLUMN_DATETIME_NAIVE, medp, EN),
                  LSG_DISPLAY_ORIGINAL, "2020-01-02T03:04:05Z");
}

int
main (int argc, char *argv[])
{
  /* Pin the locale + timezone so the localized-date presets are deterministic
   * (only the presence + non-originality of the formatted string is gate-pinned;
   * the exact CLDR-ish glyphs are the reviewer/host check). */
  setlocale (LC_ALL, "C");
  g_setenv ("TZ", "UTC", TRUE);

  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/formatter/scalar-kind", test_scalar_kind);
  g_test_add_func ("/formatter/decimal-lossless", test_decimal_lossless);
  g_test_add_func ("/formatter/decimal-locale-glyphs", test_decimal_locale_glyphs);
  g_test_add_func ("/formatter/decimal-unrepresentable", test_decimal_unrepresentable);
  g_test_add_func ("/formatter/integer-grouping", test_integer_grouping);
  g_test_add_func ("/formatter/dispatch-number", test_dispatch_number);
  g_test_add_func ("/formatter/dispatch-auto-and-text", test_dispatch_auto_and_text);
  g_test_add_func ("/formatter/dispatch-dates", test_dispatch_dates);
  return g_test_run ();
}
