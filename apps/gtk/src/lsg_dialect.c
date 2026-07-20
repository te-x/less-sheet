/*
 * lsg_dialect.c — RED SEED for the dialect compose/validate view-model
 * (lsg_dialect.h). Compiles against the frozen header (so the CONFORMANCE gate
 * passes) but deliberately does NOT implement the behavior: the compose funnel
 * always REJECTS, the header shift is always 0, the custom-byte parse always
 * fails, and the encoding picker always reports Automatic. The value builders
 * and the candidate/option DATA are real (tests need them to construct inputs
 * and to assert the frozen lists), so tests/test_dialect.c is RED strictly on
 * the unimplemented LOGIC (compose / validate / carry-forward / header-shift /
 * custom-byte / picker selection), turning GREEN as the implementer fills it
 * in. Pure + display-free: no core, no widgets.
 */
#include <lsg_dialect.h>

/* ------------------------------------------------------------------------- */
/* Value builders (real — tests construct changes with these)                */
/* ------------------------------------------------------------------------- */

LsgDialectChange
lsg_dialect_change_separator (guint8 byte)
{
  LsgDialectChange c = { 0 };
  c.kind = LSG_DIALECT_CHANGE_SEPARATOR;
  c.separator = byte;
  return c;
}

LsgDialectChange
lsg_dialect_change_quote (guint8 byte)
{
  LsgDialectChange c = { 0 };
  c.kind = LSG_DIALECT_CHANGE_QUOTE;
  c.quote = byte;
  return c;
}

LsgDialectChange
lsg_dialect_change_quote_none (void)
{
  LsgDialectChange c = { 0 };
  c.kind = LSG_DIALECT_CHANGE_QUOTE;
  c.quote_none = TRUE;
  return c;
}

LsgDialectChange
lsg_dialect_change_header (gboolean on)
{
  LsgDialectChange c = { 0 };
  c.kind = LSG_DIALECT_CHANGE_HEADER;
  c.header_on = on;
  return c;
}

LsgDialectChange
lsg_dialect_change_encoding (LsgEncoding encoding)
{
  LsgDialectChange c = { 0 };
  c.kind = LSG_DIALECT_CHANGE_ENCODING;
  c.encoding = encoding;
  return c;
}

/* ------------------------------------------------------------------------- */
/* Compose + validate (SEED: always reject — no re-open)                     */
/* ------------------------------------------------------------------------- */

LsgDialectCompose
lsg_dialect_compose (LsgDialect report, LsgDialectChange change)
{
  (void)report;
  (void)change;
  LsgDialectCompose out = { 0 };
  out.accepted = FALSE; /* SEED: reject every change */
  return out;
}

gboolean
lsg_dialect_parse_custom_byte (const char *text, guint8 *out_byte)
{
  (void)text;
  (void)out_byte;
  return FALSE; /* SEED: never accept a custom byte */
}

/* ------------------------------------------------------------------------- */
/* Header re-anchor shift (SEED: never shift)                                */
/* ------------------------------------------------------------------------- */

gint
lsg_dialect_header_shift (gboolean old_header, gboolean new_header)
{
  (void)old_header;
  (void)new_header;
  return 0; /* SEED: always 0 */
}

/* ------------------------------------------------------------------------- */
/* Candidate lists + encoding picker (DATA real; SELECTION seeded wrong)     */
/* ------------------------------------------------------------------------- */

const guint8 *
lsg_dialect_separator_candidates (void)
{
  static const guint8 seps[LSG_DIALECT_SEPARATOR_CANDIDATE_COUNT]
      = { 0x2C, 0x3B, 0x09, 0x7C }; /* ',' ';' TAB '|' */
  return seps;
}

const guint8 *
lsg_dialect_quote_candidates (void)
{
  static const guint8 quotes[LSG_DIALECT_QUOTE_CANDIDATE_COUNT]
      = { 0x22, 0x27 }; /* '"' '\'' */
  return quotes;
}

const LsgEncoding *
lsg_encoding_picker_options (void)
{
  static const LsgEncoding options[LSG_ENCODING_PICKER_OPTION_COUNT] = {
    LSG_ENCODING_AUTO,    LSG_ENCODING_UTF8,   LSG_ENCODING_UTF16LE,
    LSG_ENCODING_UTF16BE, LSG_ENCODING_LATIN1, LSG_ENCODING_WINDOWS1252,
  };
  return options;
}

LsgEncoding
lsg_encoding_picker_selection (LsgDialect report)
{
  (void)report;
  return LSG_ENCODING_AUTO; /* SEED: always Automatic */
}

LsgEncoding
lsg_encoding_picker_detected (LsgDialect report)
{
  (void)report;
  return LSG_ENCODING_AUTO; /* SEED: never reports the resolved encoding */
}
