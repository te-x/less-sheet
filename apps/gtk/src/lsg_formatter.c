/*
 * lsg_formatter.c — the GTK frontend's display-free CELL FORMATTER engine
 * (lsg_formatter.h). The C analog of the macOS `ColumnDisplayFormatting`,
 * reproduced per ARCH decision 8 with GLib + the C-library locale, NOT ICU.
 * The exact-decimal losslessness macOS gets from Foundation
 * `Decimal.FormatStyle` is reproduced here in base-10 ARITHMETIC over digit
 * strings — never binary floating point — so a value formats to an EXACT round
 * trip or falls back to the raw spelling (UNAVAILABLE), never a rounded lie.
 */
#include <lsg_formatter.h>

#include <limits.h>
#include <locale.h>
#include <string.h>

/* ------------------------------------------------------------------------- */
/* Small ASCII helpers (locale-independent, exactly the pinned v1 grammar) */
/* ------------------------------------------------------------------------- */

/* The numeric grammar's whitespace set: 0x09..0x0D and 0x20 (see HEADER RULE).
 */
static gboolean
is_ws (char c)
{
  return c == ' ' || (c >= 0x09 && c <= 0x0D);
}

static gboolean
is_digit (char c)
{
  return c >= '0' && c <= '9';
}

/* Trim leading/trailing ASCII whitespace, yielding the [*begin, *end) span. */
static void
trim (const char *s, gsize len, const char **begin, const char **end)
{
  const char *b = s;
  const char *e = s + len;
  while (b < e && is_ws (*b))
    b++;
  while (e > b && is_ws (*(e - 1)))
    e--;
  *begin = b;
  *end = e;
}

/* ------------------------------------------------------------------------- */
/* Strict lexical KIND gate */
/* ------------------------------------------------------------------------- */

/* Match the numeric grammar over [p, end):
 *   sign? ( digits ('.' digits?)? | '.' digits ) (('e'|'E') sign? digits)?
 * On a full match, *is_decimal is set TRUE iff a '.' or exponent is present.
 */
static gboolean
match_numeric (const char *p, const char *end, gboolean *is_decimal)
{
  gboolean has_dot = FALSE, has_exp = FALSE;
  gboolean int_digits = FALSE, frac_digits = FALSE;

  if (p == end)
    return FALSE;
  if (*p == '+' || *p == '-')
    p++;

  while (p < end && is_digit (*p))
    {
      p++;
      int_digits = TRUE;
    }
  if (p < end && *p == '.')
    {
      has_dot = TRUE;
      p++;
      while (p < end && is_digit (*p))
        {
          p++;
          frac_digits = TRUE;
        }
    }

  /* Mantissa must carry at least one digit somewhere; "." / "" / "+.e5" fail.
   */
  if (!int_digits && !frac_digits)
    return FALSE;

  if (p < end && (*p == 'e' || *p == 'E'))
    {
      has_exp = TRUE;
      p++;
      if (p < end && (*p == '+' || *p == '-'))
        p++;
      const char *e_start = p;
      while (p < end && is_digit (*p))
        p++;
      if (p == e_start)
        return FALSE; /* exponent needs at least one digit ("1e" fails) */
    }

  if (p != end)
    return FALSE; /* trailing garbage ("1,000", "0x1F", "1 2") */

  *is_decimal = has_dot || has_exp;
  return TRUE;
}

static gboolean
match_bool (const char *p, const char *end)
{
  gsize n = (gsize)(end - p);
  if (n == 4)
    return g_ascii_strncasecmp (p, "true", 4) == 0;
  if (n == 5)
    return g_ascii_strncasecmp (p, "false", 5) == 0;
  return FALSE;
}

static gboolean
is_leap (int y)
{
  return (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
}

static int
days_in_month (int y, int m)
{
  static const int d[13]
      = { 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
  if (m < 1 || m > 12)
    return 0;
  if (m == 2 && is_leap (y))
    return 29;
  return d[m];
}

/* Parse the 4-2-2 date at s[0..10): "YYYY-MM-DD", valid Gregorian. */
static gboolean
match_date_prefix (const char *s, gsize len)
{
  if (len < 10)
    return FALSE;
  for (int i = 0; i < 4; i++)
    if (!is_digit (s[i]))
      return FALSE;
  if (s[4] != '-' || !is_digit (s[5]) || !is_digit (s[6]) || s[7] != '-'
      || !is_digit (s[8]) || !is_digit (s[9]))
    return FALSE;

  int y = (s[0] - '0') * 1000 + (s[1] - '0') * 100 + (s[2] - '0') * 10
          + (s[3] - '0');
  int mo = (s[5] - '0') * 10 + (s[6] - '0');
  int dy = (s[8] - '0') * 10 + (s[9] - '0');
  int dim = days_in_month (y, mo);
  if (dim == 0 || dy < 1 || dy > dim)
    return FALSE;
  return TRUE;
}

/* Classify a datetime "YYYY-MM-DDTHH:MM:SS[.f][Z|±HH:MM]" (exact, no trim).
 * Returns NAIVE (no zone), ZONED (Z or explicit offset), or NONE (not one). */
static LsgScalarKind
match_datetime (const char *s, gsize len)
{
  if (len < 19)
    return LSG_KIND_NONE;
  if (!match_date_prefix (s, len))
    return LSG_KIND_NONE;
  if (s[10] != 'T')
    return LSG_KIND_NONE;
  if (!is_digit (s[11]) || !is_digit (s[12]) || s[13] != ':'
      || !is_digit (s[14]) || !is_digit (s[15]) || s[16] != ':'
      || !is_digit (s[17]) || !is_digit (s[18]))
    return LSG_KIND_NONE;

  int hh = (s[11] - '0') * 10 + (s[12] - '0');
  int mm = (s[14] - '0') * 10 + (s[15] - '0');
  int ss = (s[17] - '0') * 10 + (s[18] - '0');
  if (hh > 23 || mm > 59 || ss > 59)
    return LSG_KIND_NONE;

  gsize i = 19;
  gboolean zoned = FALSE;

  if (i < len && s[i] == '.')
    {
      i++;
      gsize f0 = i;
      while (i < len && is_digit (s[i]))
        i++;
      if (i == f0)
        return LSG_KIND_NONE; /* '.' with no fractional digits */
    }

  if (i < len)
    {
      if (s[i] == 'Z')
        {
          i++;
          zoned = TRUE;
        }
      else if (s[i] == '+' || s[i] == '-')
        {
          if (i + 5 >= len)
            return LSG_KIND_NONE; /* need sign HH ':' MM */
          if (!is_digit (s[i + 1]) || !is_digit (s[i + 2]) || s[i + 3] != ':'
              || !is_digit (s[i + 4]) || !is_digit (s[i + 5]))
            return LSG_KIND_NONE;
          i += 6;
          zoned = TRUE;
        }
      else
        {
          return LSG_KIND_NONE; /* trailing garbage */
        }
    }

  if (i != len)
    return LSG_KIND_NONE; /* garbage after the zone */

  return zoned ? LSG_KIND_DATETIME_ZONED : LSG_KIND_DATETIME_NAIVE;
}

LsgScalarKind
lsg_scalar_kind (const char *raw)
{
  if (raw == NULL)
    return LSG_KIND_NONE;
  gsize len = strlen (raw);
  if (len == 0)
    return LSG_KIND_NONE;

  /* v1 grammar is ASCII-only: any byte >= 0x80 is text (LSG_KIND_NONE). */
  for (gsize i = 0; i < len; i++)
    if ((guchar)raw[i] >= 0x80)
      return LSG_KIND_NONE;

  /* Boolean / numeric trim edge whitespace; date / datetime do NOT. */
  const char *b, *e;
  trim (raw, len, &b, &e);

  if (match_bool (b, e))
    return LSG_KIND_BOOLEAN;

  gboolean is_dec = FALSE;
  if (match_numeric (b, e, &is_dec))
    return is_dec ? LSG_KIND_DECIMAL : LSG_KIND_INTEGER;

  if (len == 10 && match_date_prefix (raw, len))
    return LSG_KIND_DATE;

  LsgScalarKind dt = match_datetime (raw, len);
  if (dt != LSG_KIND_NONE)
    return dt;

  return LSG_KIND_NONE;
}

/* ------------------------------------------------------------------------- */
/* Locale glyphs (the only platform-sourced presentation, kept separate) */
/* ------------------------------------------------------------------------- */

LsgLocaleGlyphs
lsg_locale_glyphs_current (void)
{
  LsgLocaleGlyphs g = { '.', ',', 0 };
  struct lconv *lc = localeconv ();
  if (lc == NULL)
    return g;

  if (lc->decimal_point != NULL && lc->decimal_point[0] != '\0')
    g.decimal_point = g_utf8_get_char_validated (lc->decimal_point, -1);
  if (lc->thousands_sep != NULL && lc->thousands_sep[0] != '\0')
    g.grouping_sep = g_utf8_get_char_validated (lc->thousands_sep, -1);

  /* localeconv grouping is a CHAR_MAX-terminated list of group sizes; the
   * first entry is the least-significant group. 0 or an empty/absent list =>
   * none. */
  if (lc->grouping != NULL && lc->grouping[0] != '\0'
      && lc->grouping[0] != CHAR_MAX && lc->grouping[0] > 0)
    g.grouping_size = (guint)lc->grouping[0];
  else
    g.grouping_size = 0;

  /* g_utf8_get_char_validated can report -1/-2 for a non-UTF-8 locale byte;
   * fall back to sane ASCII so the arithmetic never emits an invalid glyph. */
  if ((gint)g.decimal_point < 0)
    g.decimal_point = '.';
  if ((gint)g.grouping_sep < 0)
    g.grouping_sep = ',';

  return g;
}

/* ------------------------------------------------------------------------- */
/* Display result lifetime */
/* ------------------------------------------------------------------------- */

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
make_display (LsgDisplayKind kind, char *owned_text)
{
  LsgDisplay d;
  d.kind = kind;
  d.text = owned_text;
  return d;
}

static LsgDisplay
unavailable (const char *raw)
{
  return make_display (LSG_DISPLAY_UNAVAILABLE,
                       g_strdup (raw != NULL ? raw : ""));
}

/* ------------------------------------------------------------------------- */
/* Exact base-10 decimal value: parse -> guard -> render */
/* ------------------------------------------------------------------------- */

/*
 * A parsed exact value. `digits` is the full mantissa digit string (integer +
 * fraction digits concatenated, no sign, no dot, leading/trailing zeros kept);
 * `point` is the number of `digits` that lie BEFORE the decimal point after
 * the scientific exponent is folded in (may be <= 0 or > len(digits));
 * `negative` is the sign. The exact value is:
 *      (-1)^negative * digits * 10^(point - strlen(digits))
 */
typedef struct
{
  GString *digits;
  gint64 point;
  gboolean negative;
} ExactDec;

/* Parse a DECIMAL/INTEGER-kind spelling into an ExactDec. Returns FALSE (and
 * frees nothing) if the spelling is not numeric (defensive; the caller gates).
 */
static gboolean
parse_exact (const char *raw, ExactDec *out)
{
  if (raw == NULL)
    return FALSE;
  const char *b, *e;
  trim (raw, strlen (raw), &b, &e);
  if (b == e)
    return FALSE;

  gboolean negative = FALSE;
  if (*b == '+' || *b == '-')
    {
      negative = (*b == '-');
      b++;
    }

  GString *mant = g_string_new (NULL);
  gint64 frac_len = 0;
  gboolean int_digits = FALSE, frac_digits = FALSE;

  while (b < e && is_digit (*b))
    {
      g_string_append_c (mant, *b);
      int_digits = TRUE;
      b++;
    }
  if (b < e && *b == '.')
    {
      b++;
      while (b < e && is_digit (*b))
        {
          g_string_append_c (mant, *b);
          frac_len++;
          frac_digits = TRUE;
          b++;
        }
    }
  if (!int_digits && !frac_digits)
    {
      g_string_free (mant, TRUE);
      return FALSE;
    }

  gint64 exp = 0;
  if (b < e && (*b == 'e' || *b == 'E'))
    {
      b++;
      gboolean eneg = FALSE;
      if (b < e && (*b == '+' || *b == '-'))
        {
          eneg = (*b == '-');
          b++;
        }
      const char *es = b;
      gint64 mag = 0;
      while (b < e && is_digit (*b))
        {
          /* Saturate rather than overflow; a huge exponent fails the guard
           * below. */
          if (mag < (G_GINT64_CONSTANT (1) << 40))
            mag = mag * 10 + (*b - '0');
          b++;
        }
      if (b == es)
        {
          g_string_free (mant, TRUE);
          return FALSE;
        }
      exp = eneg ? -mag : mag;
    }
  if (b != e)
    {
      g_string_free (mant, TRUE);
      return FALSE;
    }

  /* The decimal point sits after (int-digit-count) mantissa digits; the
   * exponent shifts it. int-digit-count = total mantissa digits - frac_len. */
  out->digits = mant;
  out->point = (gint64)mant->len - frac_len + exp;
  out->negative = negative;
  return TRUE;
}

/* Significant-digit count (first..last non-zero) and the normalized
 * least-significant-digit exponent, for the representability guard. */
static void
significance (const ExactDec *v, gsize *num_sig, gint64 *lsd_exp)
{
  const char *d = v->digits->str;
  gsize n = v->digits->len;
  gsize first = 0, last = 0;
  gboolean any = FALSE;

  for (gsize i = 0; i < n; i++)
    if (d[i] != '0')
      {
        if (!any)
          {
            first = i;
            any = TRUE;
          }
        last = i;
      }

  if (!any)
    {
      *num_sig = 0;
      *lsd_exp = 0;
      return;
    }
  *num_sig = last - first + 1;
  /* value = digits * 10^(point - n); dropping trailing zeros past `last`
   * raises the exponent of the least-significant significant digit
   * accordingly. */
  *lsd_exp = (v->point - (gint64)n) + (gint64)(n - 1 - last);
}

/* Insert `sep` every `size` digits (from the right) into the digit string
 * `digits` (length `dlen`); appends the grouped form to `dst`. */
static void
append_grouped (GString *dst, const char *digits, gsize dlen,
                gboolean grouping, gunichar sep, guint size)
{
  if (!grouping || size == 0 || dlen == 0)
    {
      g_string_append_len (dst, digits, (gssize)dlen);
      return;
    }
  char sepbuf[8];
  gint seplen = g_unichar_to_utf8 (sep, sepbuf);

  for (gsize i = 0; i < dlen; i++)
    {
      gsize remaining = dlen - i; /* digits still to emit including this one */
      if (i != 0 && remaining % size == 0)
        g_string_append_len (dst, sepbuf, seplen);
      g_string_append_c (dst, digits[i]);
    }
}

/*
 * Render an ExactDec that has PASSED the representability guard, honoring
 * `fraction_digits` (>=0 fixes the length with HALF-EVEN rounding; <0
 * preserves the source fractional length) and `grouping`/`glyphs`. Returns an
 * owned string.
 */
static char *
render_exact (const ExactDec *v, gboolean grouping, gint fraction_digits,
              LsgLocaleGlyphs glyphs)
{
  const char *md = v->digits->str;
  gint64 n = (gint64)v->digits->len;
  gint64 point = v->point;

  /* Split the mantissa into integer and fraction digit strings around `point`,
   * padding with zeros where the point lies outside the mantissa. */
  GString *int_part = g_string_new (NULL);
  GString *frac_part = g_string_new (NULL);

  if (point <= 0)
    {
      g_string_append (int_part, "0");
      for (gint64 i = 0; i < -point; i++)
        g_string_append_c (frac_part, '0');
      g_string_append_len (frac_part, md, (gssize)n);
    }
  else if (point >= n)
    {
      g_string_append_len (int_part, md, (gssize)n);
      for (gint64 i = 0; i < point - n; i++)
        g_string_append_c (int_part, '0');
    }
  else
    {
      g_string_append_len (int_part, md, (gssize)point);
      g_string_append_len (frac_part, md + point, (gssize)(n - point));
    }

  /* Apply the requested fractional length. */
  if (fraction_digits >= 0)
    {
      gsize want = (gsize)fraction_digits;
      if (frac_part->len <= want)
        {
          while (frac_part->len < want)
            g_string_append_c (frac_part, '0'); /* pad exactly */
        }
      else
        {
          /* Round the exact value to `want` fraction digits, HALF-EVEN. The
           * kept integer is (int_part + frac_part[0..want)); the dropped tail
           * decides the rounding. */
          char round_digit = frac_part->str[want];
          gboolean tail_nonzero = FALSE;
          for (gsize i = want + 1; i < frac_part->len; i++)
            if (frac_part->str[i] != '0')
              {
                tail_nonzero = TRUE;
                break;
              }
          g_string_truncate (frac_part, want);

          gboolean round_up;
          if (round_digit < '5')
            round_up = FALSE;
          else if (round_digit > '5' || tail_nonzero)
            round_up = TRUE;
          else
            {
              /* Exactly halfway: round to even. Last kept digit is the final
               * fraction digit, or the last integer digit when want == 0. */
              char last_kept = (want > 0) ? frac_part->str[want - 1]
                                          : int_part->str[int_part->len - 1];
              round_up = ((last_kept - '0') % 2) != 0;
            }

          if (round_up)
            {
              /* Increment the (int_part . frac_part) digit sequence by 1 unit
               * in the last fraction place, propagating the carry leftward. */
              gboolean carry = TRUE;
              for (gssize i = (gssize)frac_part->len - 1; i >= 0 && carry; i--)
                {
                  if (frac_part->str[i] == '9')
                    frac_part->str[i] = '0';
                  else
                    {
                      frac_part->str[i]++;
                      carry = FALSE;
                    }
                }
              for (gssize i = (gssize)int_part->len - 1; i >= 0 && carry; i--)
                {
                  if (int_part->str[i] == '9')
                    int_part->str[i] = '0';
                  else
                    {
                      int_part->str[i]++;
                      carry = FALSE;
                    }
                }
              if (carry)
                g_string_prepend_c (int_part, '1'); /* e.g. 999 -> 1000 */
            }
        }
    }

  /* Assemble: sign + grouped integer + (decimal point + fraction)?  Suppress a
   * negative sign for a zero result. */
  gboolean nonzero = FALSE;
  for (gsize i = 0; i < int_part->len; i++)
    if (int_part->str[i] != '0')
      {
        nonzero = TRUE;
        break;
      }
  for (gsize i = 0; i < frac_part->len && !nonzero; i++)
    if (frac_part->str[i] != '0')
      nonzero = TRUE;

  GString *out = g_string_new (NULL);
  if (v->negative && nonzero)
    g_string_append_c (out, '-');

  append_grouped (out, int_part->str, int_part->len, grouping,
                  glyphs.grouping_sep, glyphs.grouping_size);

  if (frac_part->len > 0)
    {
      char dpbuf[8];
      gint dplen = g_unichar_to_utf8 (glyphs.decimal_point, dpbuf);
      g_string_append_len (out, dpbuf, dplen);
      g_string_append_len (out, frac_part->str, (gssize)frac_part->len);
    }

  g_string_free (int_part, TRUE);
  g_string_free (frac_part, TRUE);
  return g_string_free (out, FALSE);
}

LsgDisplay
lsg_format_decimal (const char *raw, gboolean grouping, gint fraction_digits,
                    LsgLocaleGlyphs glyphs)
{
  ExactDec v;
  if (!parse_exact (raw, &v))
    return unavailable (raw);

  gsize num_sig;
  gint64 lsd_exp;
  significance (&v, &num_sig, &lsd_exp);

  /* Representability guard, mirroring Foundation Decimal's exact range: at
   * most LSG_DECIMAL_MAX_SIG_DIGITS significant digits AND a base-10 exponent
   * within the exact [-128, 127] range. A value beyond it is not a safe round
   * trip. */
  gboolean representable
      = (num_sig <= LSG_DECIMAL_MAX_SIG_DIGITS)
        && (num_sig == 0 || (lsd_exp >= -128 && lsd_exp <= 127));

  if (!representable)
    {
      g_string_free (v.digits, TRUE);
      return unavailable (raw);
    }

  char *text = render_exact (&v, grouping, fraction_digits, glyphs);
  g_string_free (v.digits, TRUE);
  return make_display (LSG_DISPLAY_FORMATTED, text);
}

LsgDisplay
lsg_format_integer (const char *raw, gboolean grouping, LsgLocaleGlyphs glyphs)
{
  if (!grouping)
    return make_display (LSG_DISPLAY_ORIGINAL,
                         g_strdup (raw != NULL ? raw : ""));

  ExactDec v;
  if (!parse_exact (raw, &v))
    return unavailable (raw);

  gsize num_sig;
  gint64 lsd_exp;
  significance (&v, &num_sig, &lsd_exp);
  gboolean representable
      = (num_sig <= LSG_DECIMAL_MAX_SIG_DIGITS)
        && (num_sig == 0 || (lsd_exp >= -128 && lsd_exp <= 127));
  if (!representable)
    {
      g_string_free (v.digits, TRUE);
      return unavailable (raw);
    }

  /* An integer preserves its (zero-length) source fraction: fraction_digits<0.
   */
  char *text = render_exact (&v, TRUE, -1, glyphs);
  g_string_free (v.digits, TRUE);
  return make_display (LSG_DISPLAY_FORMATTED, text);
}

/* ------------------------------------------------------------------------- */
/* Column-config format options + the type+options dispatcher (SEED)         */
/*                                                                           */
/* The slice-1 primitives above (kind gate, lossless decimal/integer, locale */
/* glyphs) stay implemented (green). This growth adds the settings-driven    */
/* dispatcher + date presets; the seed below always returns the raw spelling */
/* so the new G9 tests are RED until the dispatcher is implemented.          */
/* ------------------------------------------------------------------------- */

LsgColumnFormatOptions
lsg_column_format_options_auto (void)
{
  /* real: the Auto default — a zeroed options value (no grouping, source
   * fraction length, Original preset). */
  LsgColumnFormatOptions o = { FALSE, FALSE, 0, LSG_DATE_PRESET_ORIGINAL };
  return o;
}

gboolean
lsg_column_format_options_is_auto (LsgColumnFormatOptions options)
{
  /* Auto == the source spelling for every kind: no grouping, no fixed
   * fraction, Original date preset (the fraction-digit VALUE is irrelevant
   * when has_fraction_digits is FALSE). */
  return !options.grouping && !options.has_fraction_digits
         && options.date_preset == LSG_DATE_PRESET_ORIGINAL;
}

static LsgDisplay
original (const char *raw)
{
  return make_display (LSG_DISPLAY_ORIGINAL,
                       g_strdup (raw != NULL ? raw : ""));
}

/* ------------------------------------------------------------------------- */
/* Date / datetime preset formatting via GDateTime (F14)                     */
/* ------------------------------------------------------------------------- */

/* Two ASCII digits at s[0..1] -> value (the caller has kind-gated the span).
 */
static int
two_digits (const char *s)
{
  return (s[0] - '0') * 10 + (s[1] - '0');
}

/* Build the GDateTime for a datetime `raw` already gated to the wanted
 * semantics. NAIVE holds its wall clock in UTC (no offset shown); ZONED is
 * held in its SOURCE offset (never converted to the system zone). Returns NULL
 * on an unexpected parse failure. */
static GDateTime *
build_datetime (const char *raw, gboolean zoned)
{
  int y = (raw[0] - '0') * 1000 + (raw[1] - '0') * 100 + (raw[2] - '0') * 10
          + (raw[3] - '0');
  int mo = two_digits (raw + 5);
  int dy = two_digits (raw + 8);
  int hh = two_digits (raw + 11);
  int mm = two_digits (raw + 14);
  int ss = two_digits (raw + 17);

  /* Skip an optional fractional-seconds run; the localized presets render at
   * whole-second resolution (parity with the macOS presets). */
  gsize i = 19;
  gsize len = strlen (raw);
  if (i < len && raw[i] == '.')
    {
      i++;
      while (i < len && is_digit (raw[i]))
        i++;
    }

  GTimeZone *tz = NULL;
  if (zoned && i < len)
    {
      if (raw[i] == 'Z')
        tz = g_time_zone_new_utc ();
      else /* an explicit "+HH:MM" / "-HH:MM" offset identifier */
        tz = g_time_zone_new_identifier (raw + i);
    }
  if (tz == NULL)
    tz = g_time_zone_new_utc (); /* NAIVE wall clock, or a defensive fallback
                                  */

  GDateTime *dt = g_date_time_new (tz, y, mo, dy, hh, mm, (gdouble)ss);
  g_time_zone_unref (tz);
  return dt;
}

static char *
format_date_preset (GDateTime *dt, LsgDatePreset preset)
{
  switch (preset)
    {
    case LSG_DATE_PRESET_LOCALIZED_SHORT:
      return g_date_time_format (dt, "%x");
    case LSG_DATE_PRESET_LOCALIZED_MEDIUM:
      return g_date_time_format (dt, "%b %e, %Y");
    case LSG_DATE_PRESET_LOCALIZED_LONG:
      return g_date_time_format (dt, "%A, %B %e, %Y");
    default:
      return NULL; /* ORIGINAL handled by the caller */
    }
}

static char *
format_datetime_preset (GDateTime *dt, gboolean zoned, LsgDatePreset preset)
{
  switch (preset)
    {
    case LSG_DATE_PRESET_LOCALIZED_SHORT:
      return g_date_time_format (dt, zoned ? "%x %H:%M %:z" : "%x %H:%M");
    case LSG_DATE_PRESET_LOCALIZED_MEDIUM:
      return g_date_time_format (dt, zoned ? "%b %e, %Y, %H:%M:%S %:z"
                                           : "%b %e, %Y, %H:%M:%S");
    case LSG_DATE_PRESET_LOCALIZED_LONG:
      return g_date_time_format (dt, zoned ? "%A, %B %e, %Y, %H:%M:%S %:z"
                                           : "%A, %B %e, %Y, %H:%M:%S");
    default:
      return NULL;
    }
}

/* ------------------------------------------------------------------------- */
/* The type+options dispatcher (F14)                                         */
/* ------------------------------------------------------------------------- */

LsgDisplay
lsg_format_cell (const char *raw, ls_column_type_kind kind,
                 ls_column_datetime_semantics semantics,
                 LsgColumnFormatOptions options, LsgLocaleGlyphs glyphs)
{
  /* Empty cell OR Auto options -> the source spelling for EVERY kind. */
  if (raw == NULL || raw[0] == '\0'
      || lsg_column_format_options_is_auto (options))
    return original (raw);

  switch (kind)
    {
    case LS_COLUMN_TYPE_INTEGER:
      /* Only a grouping request on an integer-kind value formats; a decimal-
       * spelled value under an integer column is a kind mismatch -> raw. */
      if (options.grouping && lsg_scalar_kind (raw) == LSG_KIND_INTEGER)
        return lsg_format_integer (raw, TRUE, glyphs);
      return original (raw);

    case LS_COLUMN_TYPE_DECIMAL:
      {
        if (lsg_scalar_kind (raw) != LSG_KIND_DECIMAL)
          return original (raw); /* integer-spelled / non-numeric -> raw */
        if (options.has_fraction_digits
            && (options.fraction_digits < 0
                || options.fraction_digits > LSG_COLUMN_FRACTION_DIGITS_MAX))
          return unavailable (raw); /* out-of-range request, never a lie */
        if (options.grouping || options.has_fraction_digits)
          return lsg_format_decimal (
              raw, options.grouping,
              options.has_fraction_digits ? options.fraction_digits : -1,
              glyphs);
        return original (raw); /* no control set */
      }

    case LS_COLUMN_TYPE_DATE:
      {
        if (options.date_preset == LSG_DATE_PRESET_ORIGINAL
            || lsg_scalar_kind (raw) != LSG_KIND_DATE)
          return original (raw);
        int y = (raw[0] - '0') * 1000 + (raw[1] - '0') * 100
                + (raw[2] - '0') * 10 + (raw[3] - '0');
        int mo = two_digits (raw + 5);
        int dy = two_digits (raw + 8);
        GDateTime *dt = g_date_time_new_utc (y, mo, dy, 0, 0, 0);
        if (dt == NULL)
          return original (raw);
        char *text = format_date_preset (dt, options.date_preset);
        g_date_time_unref (dt);
        if (text == NULL)
          return original (raw);
        return make_display (LSG_DISPLAY_FORMATTED, text);
      }

    case LS_COLUMN_TYPE_DATETIME:
      {
        LsgScalarKind want = (semantics == LS_COLUMN_DATETIME_ZONED)
                                 ? LSG_KIND_DATETIME_ZONED
                                 : LSG_KIND_DATETIME_NAIVE;
        if (options.date_preset == LSG_DATE_PRESET_ORIGINAL
            || lsg_scalar_kind (raw) != want)
          return original (raw);
        gboolean zoned = (semantics == LS_COLUMN_DATETIME_ZONED);
        GDateTime *dt = build_datetime (raw, zoned);
        if (dt == NULL)
          return original (raw);
        char *text = format_datetime_preset (dt, zoned, options.date_preset);
        g_date_time_unref (dt);
        if (text == NULL)
          return original (raw);
        return make_display (LSG_DISPLAY_FORMATTED, text);
      }

    default:
      /* TEXT / BOOLEAN / UNKNOWN / UNSUPPORTED — no v1 format controls. */
      return original (raw);
    }
}
