/*
 * lsg_dialect.h — the GTK frontend's DIALECT compose/validate VIEW-MODEL
 * (slice "settings + dialect override"). PURE and display-free — the C analog
 * of the macOS `DialectComposing` + `EncodingPicker` + `DialectCandidates`
 * (apps/macos/Sources/Contracts/Dialect.swift). It touches NO core and NO
 * widgets: it turns one user selection (the header toggle, a separator / quote
 * radio pick or a "Custom…" byte, or an encoding choice) plus the current
 * effective dialect report into the NEXT open's parse profile, and owns the
 * validation that makes an illegal selection a silent no-op.
 *
 * WHY A RE-OPEN. At the ABI a dialect change is a full document re-open
 * (`ls_close` + `ls_open` with a new `ls_open_options`); there is no in-place
 * dialect mutator. So this module's single job is to COMPOSE the next
 * `ls_open_options` (ARCH decision C — it emits the frozen ABI struct itself,
 * no redundant GTK-private override type) and to report the header re-anchor
 * shift the caller applies after the re-open. The re-open itself, the grid
 * rebuild, and the find/filter/jump reset are the caller's (they reuse the
 * existing `lsg_document_open_local` / `lsg_net_open_start` and the frozen
 * `lsg_find_invalidated` / `lsg_jump_initial` / `lsg_filter_initial`).
 *
 * ONE SOURCE OF TRUTH. The three header-bar quick-controls (header toggle,
 * separator ▾, quote ▾), the Preferences "Parsing" page, and this composer all
 * read the SAME state — the effective dialect report (`LsgDialect`, frozen in
 * <lsg_document.h>, reused here, never re-declared). Each affordance shows the
 * current effective value + whether it is forced vs sniffed; each change
 * routes through the ONE `lsg_dialect_compose` funnel, so validation can never
 * drift.
 *
 * Contract role (frozen; the prototypes/structs ARE the signatures — compiled
 * with -Werror so any drift against a stub/caller fails compilation). Symbols
 * are namespaced `lsg_` / `Lsg` / `LSG_` so they never collide with the core's
 * frozen `ls_` / `LS_` ABI in <lesssheet.h>, which this header builds ON
 * (never copies).
 *
 * OWNERSHIP: every type here is a PLAIN VALUE (no owned heap, no free
 * function). `LsgDialectChange` / `LsgDialectCompose` are transient values;
 * the candidate/option accessors return pointers to STATIC const arrays owned
 * by the module (never freed by the caller).
 *
 * THREADING: every function is pure (any thread; no shared state).
 */
#ifndef LSG_DIALECT_H
#define LSG_DIALECT_H

#include <glib.h>
#include <lesssheet.h> /* ls_open_options + the LS_SNIFF / LS_ENCODING_* domains */
#include <lsg_document.h> /* LsgDialect (the effective report), reused not re-declared */

G_BEGIN_DECLS

/* ------------------------------------------------------------------------- */
/* Text encoding domain (the picker's choice set)                            */
/* ------------------------------------------------------------------------- */

/*
 * A text-encoding CHOICE — the domain of `ls_open_options.encoding`: AUTO
 * (detect) plus the five concrete encodings. The C analog of the macOS
 * `EncodingOverride`, but a single enum whose values are PINNED to the ABI's
 * `LS_ENCODING_*` (AUTO == -1, UTF8..WINDOWS1252 == 0..4), so the composer
 * assigns it to `options.encoding` directly and the bridge reads
 * `ls_dialect.encoding` (a concrete value, never AUTO) straight into it (a
 * frozen test pins the equality; -Werror is the signature-drift guard).
 */
typedef enum
{
  LSG_ENCODING_AUTO
  = -1, /* options only: detect from the head (LS_ENCODING_AUTO) */
  LSG_ENCODING_UTF8 = 0,
  LSG_ENCODING_UTF16LE = 1,
  LSG_ENCODING_UTF16BE = 2,
  LSG_ENCODING_LATIN1 = 3, /* ISO-8859-1 */
  LSG_ENCODING_WINDOWS1252 = 4,
} LsgEncoding;

/* ------------------------------------------------------------------------- */
/* One user selection (the compose funnel's input)                           */
/* ------------------------------------------------------------------------- */

/* Which dialect parameter one selection changes. */
typedef enum
{
  LSG_DIALECT_CHANGE_SEPARATOR = 0,
  LSG_DIALECT_CHANGE_QUOTE = 1,
  LSG_DIALECT_CHANGE_HEADER = 2,
  LSG_DIALECT_CHANGE_ENCODING = 3,
} LsgDialectChangeKind;

/*
 * One user selection (the C analog of the macOS `DialectChange`). A PLAIN
 * VALUE; only the field(s) named by `kind` are meaningful. Build it with the
 * constructors below (they hide the tag layout) — a separator/quote pick (a
 * candidate byte OR a "Custom…" byte), quoting-disabled, a header on/off, or
 * an encoding choice.
 */
typedef struct
{
  LsgDialectChangeKind kind;
  guint8 separator;     /* SEPARATOR: the forced byte */
  guint8 quote;         /* QUOTE: the forced byte (when !quote_none) */
  gboolean quote_none;  /* QUOTE: TRUE => quoting disabled (LS_QUOTE_NONE) */
  gboolean header_on;   /* HEADER: TRUE = header on, FALSE = header off */
  LsgEncoding encoding; /* ENCODING: the chosen value (AUTO re-detects) */
} LsgDialectChange;

/* Force the separator byte (a candidate or a validated "Custom…" byte). */
LsgDialectChange lsg_dialect_change_separator (guint8 byte);
/* Force the quote byte (a candidate or a validated "Custom…" byte). */
LsgDialectChange lsg_dialect_change_quote (guint8 byte);
/* Disable quoting (LS_QUOTE_NONE): quote bytes become literal text. */
LsgDialectChange lsg_dialect_change_quote_none (void);
/* Force record 1 to be the header (on) or a data row (off). */
LsgDialectChange lsg_dialect_change_header (gboolean on);
/* Force this encoding (`LSG_ENCODING_AUTO` re-detects on the re-open). */
LsgDialectChange lsg_dialect_change_encoding (LsgEncoding encoding);

/* ------------------------------------------------------------------------- */
/* The composed re-open options (the funnel's output)                        */
/* ------------------------------------------------------------------------- */

/*
 * The result of composing a change onto a report (ARCH decision C — the frozen
 * `ls_open_options` directly). A PLAIN VALUE:
 *   accepted — FALSE means the selection was REJECTED (see the validation rule
 *              in `lsg_dialect_compose`): the caller performs NO re-open (a
 *              silent no-op — parity with macOS). `options` is then
 * unspecified. options  — valid iff `accepted`: the next open's forced parse
 * profile, fed straight to `lsg_document_open_local` / `lsg_net_open_start`.
 */
typedef struct
{
  gboolean accepted;
  ls_open_options options;
} LsgDialectCompose;

/*
 * Compose the next open's `ls_open_options` from `report` (the current
 * effective dialect) and one `change` (the C analog of
 * `DialectComposing.compose(from:changing:)`). Implements F1 carry-forward +
 * F2 validation.
 *
 * CARRY-FORWARD (each parameter's starting point, before the change):
 *   - a parameter the report marks FORCED starts from its effective value as a
 *     forced value (separator/quote byte; header LS_HEADER_ON/OFF; encoding
 * the resolved value); a quote that is forced-disabled carries LS_QUOTE_NONE;
 *   - a NON-forced parameter starts LS_SNIFF (re-sniffed on the re-open, now
 *     excluding any newly forced byte from its candidates — the core's rule);
 *   - encoding carries the resolved value when `encoding_forced`, else
 *     LS_ENCODING_AUTO (re-detected);
 *   - `index_mode` is always LS_INDEX_AUTO (the viewer's default open).
 * The `change` is then applied as the forced value of ITS parameter.
 *
 * VALIDATION (F2; reject => `accepted` FALSE, no options, silent no-op):
 *   - a forced separator/quote BYTE must be ASCII 0x01..0x7F and neither CR
 *     (0x0D) nor LF (0x0A) — this catches an out-of-domain "Custom…" byte;
 *   - a forced separator must not EQUAL the carried forced quote byte, and a
 *     forced quote must not equal the carried forced separator byte. Changing
 * a byte to equal a merely SNIFFED value of the other is ACCEPTED (the re-open
 *     re-sniffs the other and excludes the conflict — the ABI rule).
 * A header change and an encoding change are ALWAYS accepted (an encoding
 * change never touches the dialect bytes; it only sets `options.encoding`).
 */
LsgDialectCompose lsg_dialect_compose (LsgDialect report,
                                       LsgDialectChange change);

/*
 * Parse a "Custom…" separator/quote entry (F3b): TRUE iff `text` is EXACTLY
 * one ASCII byte in 0x01..0x7F that is neither CR nor LF, writing it to
 * `*out_byte`; FALSE (leaving `*out_byte` untouched) for an empty /
 * multi-character / non- ASCII (a >1-byte UTF-8 codepoint) / CR / LF entry.
 * The pure half of the in-popover custom entry: the widget hands the accepted
 * byte to `lsg_dialect_change_separator` / `_quote` and then the SAME compose
 * funnel (which re-checks the byte domain and the separator≠quote collision),
 * so an illegal custom byte is a silent no-op either way. `text` is
 * NUL-terminated UTF-8 (NULL treated as empty → FALSE).
 */
gboolean lsg_dialect_parse_custom_byte (const char *text, guint8 *out_byte);

/* ------------------------------------------------------------------------- */
/* Header re-anchor shift (F5)                                               */
/* ------------------------------------------------------------------------- */

/*
 * The pure viewport re-anchor shift for a header on/off re-open (F5): 0 when
 * the header state is unchanged, -1 when turning the header ON (record that
 * was data row `top` is now `top - 1`), +1 when turning it OFF. The caller
 * captures its current top data-row and re-anchors to `top + shift` (clamped)
 * so the SAME file record stays in view; a separator / quote / encoding change
 * rests at the top-left (its shift is not this function's concern — it is only
 * for a header change, where `old_header` = `report.header` and `new_header` =
 * the toggled value).
 */
gint lsg_dialect_header_shift (gboolean old_header, gboolean new_header);

/* ------------------------------------------------------------------------- */
/* Candidate lists + the encoding picker view-model (F3 / F4)                */
/* ------------------------------------------------------------------------- */

/* The quick-control separator candidates, in the core's sniffer preference
 * order: ',' ';' TAB '|'. View-model only — the user-facing labels/glyphs live
 * in the UI. */
#define LSG_DIALECT_SEPARATOR_CANDIDATE_COUNT (4)
/* The quick-control quote candidates, in order: '"' '\''. (NONE is a separate
 * radio row the UI adds; it maps to `lsg_dialect_change_quote_none`.) */
#define LSG_DIALECT_QUOTE_CANDIDATE_COUNT (2)

/* Pointer to a STATIC const array of LSG_DIALECT_SEPARATOR_CANDIDATE_COUNT
 * separator bytes (module-owned; never freed). */
const guint8 *lsg_dialect_separator_candidates (void);
/* Pointer to a STATIC const array of LSG_DIALECT_QUOTE_CANDIDATE_COUNT quote
 * bytes (module-owned; never freed). */
const guint8 *lsg_dialect_quote_candidates (void);

/* The encoding picker options, in the fixed UI order: Automatic, UTF-8,
 * UTF-16 LE, UTF-16 BE, ISO-8859-1, Windows-1252. */
#define LSG_ENCODING_PICKER_OPTION_COUNT (6)

/* Pointer to a STATIC const array of LSG_ENCODING_PICKER_OPTION_COUNT
 * `LsgEncoding` options in the fixed order above (module-owned; never freed).
 * The C analog of `EncodingPicker.options`. */
const LsgEncoding *lsg_encoding_picker_options (void);

/*
 * The option the picker shows SELECTED for `report`
 * (`EncodingPicker.selection`): the forced encoding when
 * `report.encoding_forced`, else `LSG_ENCODING_AUTO` (detection chose the
 * resolved value).
 */
LsgEncoding lsg_encoding_picker_selection (LsgDialect report);

/*
 * The resolved/detected encoding to surface (`EncodingPicker.detected`) — the
 * "Automatic — detected: X" subtitle in Automatic mode, or the confirmed value
 * when forced. Always the report's concrete resolved encoding (never AUTO).
 */
LsgEncoding lsg_encoding_picker_detected (LsgDialect report);

G_END_DECLS

#endif /* LSG_DIALECT_H */
