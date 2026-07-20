/*
 * lsg_formatter.h — the GTK frontend's display-free CELL FORMATTER engine. The
 * C analog of the macOS `ColumnDisplayFormatting`, reproduced per ARCH
 * decision 8 with GLib + the C-library locale + `GDateTime`, NOT ICU (the
 * single-digit-MB budget forbids ICU). The exact-decimal losslessness macOS
 * gets from Foundation `Decimal.FormatStyle` is reproduced here in base-10
 * ARITHMETIC (never binary floating point).
 *
 * SLICE 1 (frozen already): the DISPLAY-FREE, deterministic primitives — (1)
 * the strict lexical KIND gate; (2) the LOSSLESS exact-decimal / integer
 * formatters; (3) the platform LOCALE GLYPHS. The slice-1 grid renders raw
 * cell spelling (AUTO).
 *
 * SETTINGS + DIALECT SLICE (this growth): the type+options DISPATCHER that the
 * column-config UI drives — given a raw cell, the column's EFFECTIVE type (an
 * ABI `ls_column_type_kind` + datetime semantics), and the session format
 * options (grouping / fixed fraction digits / date preset), it produces the
 * on-screen string over the slice-1 primitives; plus localized DATE / DATETIME
 * preset formatting via `GDateTime` (naive vs zoned honored). The header
 * anticipated this ("the SETTINGS UI that drives non-AUTO options … and
 * localized DATE-PRESET formatting are LATER slices").
 *
 * The core serves RAW cells; nothing here mutates the source, and it is never
 * used by find / filter / copy (those keep the raw value — the ABI's rule).
 * Pure and display-free: no widgets, no display server — all functions run
 * headlessly under `g_test` (locale glyphs are injected explicitly, and the
 * localized-date determinism comes from the process locale/timezone the test
 * pins).
 *
 * Contract role (frozen; the prototypes/structs ARE the signatures — compiled
 * with -Werror so any drift against a stub/caller fails compilation). Symbols
 * are namespaced `lsg_` / `Lsg` / `LSG_` so they never collide with the core's
 * frozen `ls_` / `LS_` ABI in <lesssheet.h>, which this header builds ON.
 */
#ifndef LSG_FORMATTER_H
#define LSG_FORMATTER_H

#include <glib.h>
#include <lesssheet.h> /* ls_column_type_kind + ls_column_datetime_semantics */

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

/*
 * The maximum fixed FRACTION DIGITS the decimal format control offers (F11:
 * the inspector's spinner range is 0..38) — the single named knob for that
 * ceiling (N5). Distinct from LSG_DECIMAL_MAX_SIG_DIGITS (a representability
 * bound): this bounds the UI's fixed-fraction request. A request outside
 * 0..this makes the dispatcher report UNAVAILABLE (never a rounded lie).
 */
#define LSG_COLUMN_FRACTION_DIGITS_MAX (38)

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

/* ------------------------------------------------------------------------- */
/* Column-config format options + the type+options dispatcher (F14)          */
/* ------------------------------------------------------------------------- */

/*
 * Date/datetime display preset (the C analog of `DatePreset`). ORIGINAL keeps
 * the source spelling exactly (incl. 1..9 fraction digits); the three
 * localized presets render via `GDateTime`/`g_date_time_format` under the
 * process locale (the exact CLDR-ish glyphs are the reviewer/host check — the
 * gate pins Original == raw and that a localized preset yields a non-original
 * FORMATTED string, honoring naive vs zoned).
 */
typedef enum
{
  LSG_DATE_PRESET_ORIGINAL = 0,
  LSG_DATE_PRESET_LOCALIZED_SHORT = 1,
  LSG_DATE_PRESET_LOCALIZED_MEDIUM = 2,
  LSG_DATE_PRESET_LOCALIZED_LONG = 3,
} LsgDatePreset;

/*
 * The session-only display format controls for one column (the C analog of
 * `ColumnFormatOptions`). A PLAIN VALUE. `lsg_column_format_options_auto`
 * (all fields default) means "preserve the source spelling exactly". Grouping
 * applies to integer & decimal; fixed fraction digits apply to decimal only
 * (`has_fraction_digits` FALSE preserves the source fractional length); the
 * date preset applies to date/datetime only.
 */
typedef struct
{
  gboolean grouping;
  gboolean
      has_fraction_digits; /* FALSE == preserve the source fractional length */
  gint fraction_digits; /* valid iff has_fraction_digits; the inspector offers
                           0..LSG_COLUMN_FRACTION_DIGITS_MAX */
  LsgDatePreset date_preset;
} LsgColumnFormatOptions;

/* The Auto default: no grouping, source fraction length, Original date preset
 * (preserve the source spelling for every kind). */
LsgColumnFormatOptions lsg_column_format_options_auto (void);

/* TRUE iff `options` equals the Auto default (the dispatcher's AUTO short
 * circuit: every kind renders ORIGINAL). */
gboolean lsg_column_format_options_is_auto (LsgColumnFormatOptions options);

/*
 * The type+options DISPATCHER (the C analog of
 * `ColumnDisplayFormatting.display(raw:type:options:locale:)`) — the single
 * entry the grid's cell paint calls once a column carries options. Produces
 * the display string for `raw` (NUL-terminated) under the column's EFFECTIVE
 * type
 * (`kind` + `semantics` from the core's `ls_column_metadata.effective`) and
 * `options`, over the slice-1 primitives + `GDateTime`. Owned result (free
 * with `lsg_display_clear`). Pinned semantics (the RED seed returns
 * ORIGINAL(raw) for everything):
 *   - `raw` empty OR `options` is Auto -> ORIGINAL(raw) for EVERY kind (source
 *     preserved byte-for-byte).
 *   - TEXT / BOOLEAN / UNKNOWN / UNSUPPORTED -> always ORIGINAL(raw) (no v1
 *     format controls).
 *   - INTEGER: only when `lsg_scalar_kind(raw) == LSG_KIND_INTEGER` AND
 *     `options.grouping` -> the grouped integer (else ORIGINAL(raw); a
 * decimal- spelled value under an integer column is ORIGINAL — kind mismatch).
 *   - DECIMAL: only when `lsg_scalar_kind(raw) == LSG_KIND_DECIMAL` AND
 *     (`options.grouping` OR `options.has_fraction_digits`) -> the lossless
 *     grouped/fixed-fraction decimal (FORMATTED, or UNAVAILABLE when not
 * exactly representable, per `lsg_format_decimal`); a `has_fraction_digits`
 * outside 0..LSG_COLUMN_FRACTION_DIGITS_MAX -> UNAVAILABLE(raw); otherwise
 *     ORIGINAL(raw) (an integer-spelled value, or no control set).
 *   - DATE: only when `lsg_scalar_kind(raw) == LSG_KIND_DATE` AND the preset
 * is not ORIGINAL -> the localized date string (FORMATTED via GDateTime); else
 *     ORIGINAL(raw).
 *   - DATETIME: only when `lsg_scalar_kind(raw)` matches the column's
 * semantics
 *     (`LSG_KIND_DATETIME_ZONED` iff `semantics == LS_COLUMN_DATETIME_ZONED`,
 *     else `LSG_KIND_DATETIME_NAIVE`) AND the preset is not ORIGINAL -> the
 *     localized datetime string, NAIVE keeping its wall time and ZONED kept in
 *     the value's SOURCE offset (never converted to the system zone); else
 *     ORIGINAL(raw).
 * FIND / FILTER / COPY keep the RAW value (the ABI rule) — this is
 * display-only.
 */
LsgDisplay lsg_format_cell (const char *raw, ls_column_type_kind kind,
                            ls_column_datetime_semantics semantics,
                            LsgColumnFormatOptions options,
                            LsgLocaleGlyphs glyphs);

G_END_DECLS

#endif /* LSG_FORMATTER_H */
