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
/* Compose + validate (F1 carry-forward + F2 validation)                     */
/* ------------------------------------------------------------------------- */

/* A forced separator/quote byte must be ASCII 0x01..0x7F and neither CR nor
 * LF (0x0D / 0x0A both fall inside the ASCII range, so they are excluded
 * explicitly). Catches an out-of-domain "Custom…" byte. */
static gboolean
valid_dialect_byte (guint8 byte)
{
  return byte >= 0x01 && byte <= 0x7F && byte != 0x0D && byte != 0x0A;
}

LsgDialectCompose
lsg_dialect_compose (LsgDialect report, LsgDialectChange change)
{
  LsgDialectCompose out = { 0 };
  out.accepted = FALSE;

  /* CARRY-FORWARD: each parameter starts from its effective FORCED value, or
   * LS_SNIFF / LS_ENCODING_AUTO to be re-sniffed / re-detected on the re-open.
   * A forced-disabled quote carries LS_QUOTE_NONE. */
  ls_open_options o;
  o.separator = report.separator_forced ? (int32_t)report.separator : LS_SNIFF;
  if (report.quote_forced)
    o.quote = report.has_quote ? (int32_t)report.quote : LS_QUOTE_NONE;
  else
    o.quote = LS_SNIFF;
  o.header = report.header_forced
                 ? (report.header ? LS_HEADER_ON : LS_HEADER_OFF)
                 : LS_SNIFF;
  o.index_mode = LS_INDEX_AUTO;
  o.encoding
      = report.encoding_forced ? (int32_t)report.encoding : LS_ENCODING_AUTO;

  /* Apply the change as the forced value of ITS parameter, validating (F2). A
   * separator/quote collision is checked against the CARRIED FORCED byte of
   * the other; equalling a merely SNIFFED byte is accepted (the re-open
   * re-sniffs the other and excludes the conflict). */
  switch (change.kind)
    {
    case LSG_DIALECT_CHANGE_SEPARATOR:
      if (!valid_dialect_byte (change.separator))
        return out;
      if (report.quote_forced && report.has_quote
          && (guint8)report.quote == change.separator)
        return out; /* collides with the carried forced quote */
      o.separator = (int32_t)change.separator;
      break;

    case LSG_DIALECT_CHANGE_QUOTE:
      if (change.quote_none)
        {
          o.quote = LS_QUOTE_NONE; /* disabling quoting is always valid */
          break;
        }
      if (!valid_dialect_byte (change.quote))
        return out;
      if (report.separator_forced && (guint8)report.separator == change.quote)
        return out; /* collides with the carried forced separator */
      o.quote = (int32_t)change.quote;
      break;

    case LSG_DIALECT_CHANGE_HEADER:
      o.header = change.header_on ? LS_HEADER_ON : LS_HEADER_OFF;
      break;

    case LSG_DIALECT_CHANGE_ENCODING:
      /* Encoding never touches the dialect bytes; always accepted. */
      o.encoding = (int32_t)change.encoding;
      break;

    default:
      return out;
    }

  out.accepted = TRUE;
  out.options = o;
  return out;
}

gboolean
lsg_dialect_parse_custom_byte (const char *text, guint8 *out_byte)
{
  if (text == NULL || text[0] == '\0')
    return FALSE; /* NULL / empty */
  if (text[1] != '\0')
    return FALSE; /* > 1 byte (incl. a multi-byte UTF-8 codepoint) */
  guint8 b = (guint8)text[0];
  if (!valid_dialect_byte (b))
    return FALSE; /* out of 0x01..0x7F, or CR / LF */
  *out_byte = b;
  return TRUE;
}

/* ------------------------------------------------------------------------- */
/* Header re-anchor shift (F5)                                               */
/* ------------------------------------------------------------------------- */

gint
lsg_dialect_header_shift (gboolean old_header, gboolean new_header)
{
  if (old_header == new_header)
    return 0;
  return new_header ? -1 : +1; /* header ON => -1, header OFF => +1 */
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
  /* The forced encoding when forced, else Automatic (detection chose the
   * resolved value). */
  return report.encoding_forced ? (LsgEncoding)report.encoding
                                : LSG_ENCODING_AUTO;
}

LsgEncoding
lsg_encoding_picker_detected (LsgDialect report)
{
  /* Always the report's concrete resolved encoding (never AUTO). */
  return (LsgEncoding)report.encoding;
}
