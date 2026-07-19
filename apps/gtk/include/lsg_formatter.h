/*
 * lsg_formatter.h — the GTK frontend's display-free CELL FORMATTER engine
 * (slice 1). The C analog of the macOS `ColumnDisplayFormatting`, reproduced
 * per ARCH decision 8 with GLib + the C-library locale + `GDateTime`, NOT ICU
 * (the single-digit-MB budget forbids ICU). The exact-decimal losslessness
 * macOS gets from Foundation `Decimal.FormatStyle` is reproduced here in
 * base-10 ARITHMETIC (never binary floating point).
 *
 * SCOPE (slice 1): the DISPLAY-FREE, deterministic core — (1) the strict
 * lexical KIND gate; (2) the LOSSLESS exact-decimal / integer formatters; (3)
 * the platform LOCALE GLYPHS. The slice-1 grid renders raw cell spelling
 * (AUTO), so these engines are frozen + unit-pinned now (decision 8 is a
 * confirmed slice-1 technology choice and the biggest cross-frontend
 * correctness risk), but the SETTINGS UI that drives non-AUTO options
 * (grouping / fraction digits / type override) and localized DATE-PRESET
 * formatting are LATER slices (column-config); this header intentionally does
 * NOT freeze a `type + options`-driven dispatcher or date-preset formatting
 * yet.
 *
 * The core serves RAW cells; nothing here mutates the source, and it is never
 * used by find / filter / copy (those keep the raw value — the ABI's rule).
 * Pure and display-free: no widgets, no display server — all functions run
 * headlessly under `g_test`.
 */
#ifndef LSG_FORMATTER_H
#define LSG_FORMATTER_H

#include <glib.h>

G_BEGIN_DECLS

/*
 * The strict base kind of a single raw value (the C analog of
 * `ColumnScalarKind`; LSG_KIND_NONE == matches no strict type, i.e. text). The
 * pinned v1 grammar (ASCII-only, locale-independent) is exactly the macOS
 * `strictKind(of:)` / the ABI HEADER RULE numeric grammar:
 *   - non-empty and all bytes < 0x80;
 *   - BOOLEAN: trims ASCII whitespace, then case-insensitive "true" / "false";
 *   - INTEGER / DECIMAL: trims ASCII whitespace, then the numeric grammar
 *       sign? ( digits ('.' digits?)? | '.' digits ) (('e'|'E') sign? digits)?
 *     DECIMAL iff it has a '.' or an exponent, else INTEGER (magnitude is
 *     irrelevant to the kind — a syntactically valid huge value is still
 *     DECIMAL, then formats UNAVAILABLE; see below);
 *   - DATE: exactly YYYY-MM-DD, no edge whitespace, a valid Gregorian date;
 *   - DATETIME: exactly YYYY-MM-DDTHH:MM:SS[.f][Z|+/-HH:MM] — NAIVE with no
 *     offset, ZONED with Z or an explicit offset.
 */
typedef enum
{
  LSG_KIND_NONE = 0,
  LSG_KIND_BOOLEAN,
  LSG_KIND_INTEGER,
  LSG_KIND_DECIMAL,
  LSG_KIND_DATE,
  LSG_KIND_DATETIME_NAIVE,
  LSG_KIND_DATETIME_ZONED,
} LsgScalarKind;

/* The strict kind of `raw` (NUL-terminated UTF-8). */
LsgScalarKind lsg_scalar_kind (const char *raw);

/*
 * Locale presentation glyphs — the ONLY thing taken from the platform (the
 * C-library locale), kept separate from the arithmetic so the formatters are
 * deterministic under `g_test` (tests inject an explicit glyph set).
 * Reproduces `localeconv`'s decimal point / thousands separator / grouping
 * size.
 */
typedef struct
{
  gunichar decimal_point; /* e.g. '.' (en) or ',' (de) */
  gunichar grouping_sep;  /* e.g. ',' (en) or '.' (de) */
  guint
      grouping_size; /* digits per group (typically 3); 0 disables grouping */
} LsgLocaleGlyphs;

/* The current process locale's glyphs, read from `localeconv` (the thin
 * platform adapter; its C-locale sourcing is exercised by the
 * human/real-locale pass, the arithmetic by the injected-glyph unit tests). A
 * locale with no grouping information yields `grouping_size == 0`. */
LsgLocaleGlyphs lsg_locale_glyphs_current (void);

/*
 * The maximum significant digits an exact-decimal value may carry and still be
 * FORMATTED (matching Foundation `Decimal`'s ~38-digit exact range that the
 * macOS formatter gates on: `significantDigits <= 38`). A value needing more —
 * or an exponent outside the exact base-10 range — is not safely representable
 * and formats UNAVAILABLE (raw fallback), never rounded through binary float.
 */
#define LSG_DECIMAL_MAX_SIG_DIGITS (38)

/* The display outcome for one cell (mirrors `ColumnDisplay`). */
typedef enum
{
  LSG_DISPLAY_ORIGINAL = 0, /* show the source spelling exactly */
  LSG_DISPLAY_FORMATTED
  = 1, /* show this exact formatted string (an exact round trip) */
  LSG_DISPLAY_UNAVAILABLE
  = 2, /* NOT safely representable -> show the raw spelling, no lie */
} LsgDisplayKind;

/* A formatter result. `text` is an OWNED, NUL-terminated UTF-8 string (free
 * via `lsg_display_clear`, or g_free directly). For ORIGINAL / UNAVAILABLE it
 * is the raw spelling verbatim. */
typedef struct
{
  LsgDisplayKind kind;
  char *text;
} LsgDisplay;

/* Free an `LsgDisplay`'s owned text and zero it. NULL-safe. */
void lsg_display_clear (LsgDisplay *display);

/*
 * Lossless exact-decimal format of `raw` (NUL-terminated; assumed a DECIMAL/
 * INTEGER-kind spelling — the caller gates with `lsg_scalar_kind`). Parses the
 * exact base-10 value (coefficient + exponent) with NO binary float, verifies
 * an exact canonical round trip, then renders:
 *   - `grouping` TRUE inserts the locale `grouping_sep` every `grouping_size`
 *     integer digits (FALSE emits none);
 *   - `fraction_digits >= 0` fixes the fractional length with HALF-EVEN
 *     rounding of the exact value; `fraction_digits < 0` preserves the source
 *     fractional length;
 *   - the locale `decimal_point` glyph separates the fraction.
 * Returns LSG_DISPLAY_FORMATTED with the rendered text when the value is
 * exactly representable (<= LSG_DECIMAL_MAX_SIG_DIGITS significant digits and
 * a base-10 exponent within the exact range), else LSG_DISPLAY_UNAVAILABLE
 * with `raw` (e.g. "1e400", or a 39+-significant-digit value). Never returns
 * ORIGINAL (the caller chooses AUTO before calling).
 */
LsgDisplay lsg_format_decimal (const char *raw, gboolean grouping,
                               gint fraction_digits, LsgLocaleGlyphs glyphs);

/*
 * Lossless integer grouping of `raw` (NUL-terminated; assumed INTEGER-kind).
 * With `grouping` TRUE returns LSG_DISPLAY_FORMATTED with the locale grouping
 * separator inserted (subject to the same exact-representability guard as
 * `lsg_format_decimal`; an over-long integer -> LSG_DISPLAY_UNAVAILABLE(raw)).
 * With `grouping` FALSE returns LSG_DISPLAY_ORIGINAL(raw) (nothing to do).
 */
LsgDisplay lsg_format_integer (const char *raw, gboolean grouping,
                               LsgLocaleGlyphs glyphs);

G_END_DECLS

#endif /* LSG_FORMATTER_H */
