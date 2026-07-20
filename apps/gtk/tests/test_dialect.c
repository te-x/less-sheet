/*
 * test_dialect.c — RED behavior tests for the DIALECT compose/validate view-
 * model (lsg_dialect.h). Display-free (glib only, no core, no GTK). Maps the
 * GATE acceptance criteria of ARCH-gtk-settings-dialect:
 *
 *   G2  — compose + validate: F1 carry-forward matrix (forced re-emits forced,
 *         non-forced -> LS_SNIFF; encoding forced-value vs AUTO) and F2
 *         validation (byte domain incl. a custom byte, the separator == carried
 *         forced quote collision + the mirror, the merely-sniffed acceptance,
 *         header/encoding always accepted, encoding leaves the bytes).
 *   G3  — header re-anchor shift 0 / -1 / +1.
 *   G4  — encoding picker: the six options in fixed order + the ABI value pins;
 *         the selection for a forced vs Automatic report; the detected value.
 *   G10 — compose -> ls_open_options feeds the correct field for each of the
 *         four change kinds (the field-mapping half; the replay-vs-reset branch
 *         is pinned in test_column.c, and the find/filter/jump reset wiring is
 *         the main.c integration verified by the human GUI pass).
 *
 * RED against the seeded src/lsg_dialect.c (compose always rejects; header
 * shift always 0; custom-byte parse always FALSE; picker always Automatic) and
 * GREEN as the module is implemented. The value builders + candidate/option
 * DATA are real in the seed, so the failures are strictly on the logic.
 */
#include <glib.h>
#include <lesssheet.h>
#include <lsg_dialect.h>
#include <lsg_document.h>

/* A fully-sniffed report: separator ',', quote '"', header off, UTF-8, nothing
 * forced. Tests flip the *_forced bits (and the effective values) for the
 * carry-forward variants. */
static LsgDialect
sniffed (void)
{
  LsgDialect d = { ',', '"', TRUE, FALSE, LS_ENCODING_UTF8,
                   FALSE, FALSE, FALSE, FALSE };
  return d;
}

/* ------------------------------------------------------------------------- */
/* G4 — the LsgEncoding <-> LS_ENCODING_* value pins (the runtime drift guard;
 *      -Werror compilation is the signature drift guard)                    */
/* ------------------------------------------------------------------------- */

static void
test_encoding_abi_pins (void)
{
  g_assert_cmpint (LSG_ENCODING_AUTO, ==, LS_ENCODING_AUTO);
  g_assert_cmpint (LSG_ENCODING_UTF8, ==, LS_ENCODING_UTF8);
  g_assert_cmpint (LSG_ENCODING_UTF16LE, ==, LS_ENCODING_UTF16LE);
  g_assert_cmpint (LSG_ENCODING_UTF16BE, ==, LS_ENCODING_UTF16BE);
  g_assert_cmpint (LSG_ENCODING_LATIN1, ==, LS_ENCODING_LATIN1);
  g_assert_cmpint (LSG_ENCODING_WINDOWS1252, ==, LS_ENCODING_WINDOWS1252);
}

/* ------------------------------------------------------------------------- */
/* G2 — carry-forward                                                        */
/* ------------------------------------------------------------------------- */

static void
test_carry_forward_non_forced (void)
{
  /* Nothing forced: a separator change forces only the separator; every other
   * parameter starts LS_SNIFF (re-sniffed), encoding LS_ENCODING_AUTO. */
  LsgDialectCompose c = lsg_dialect_compose (sniffed (),
                                             lsg_dialect_change_separator (';'));
  g_assert_true (c.accepted);
  g_assert_cmpint (c.options.separator, ==, ';');
  g_assert_cmpint (c.options.quote, ==, LS_SNIFF);
  g_assert_cmpint (c.options.header, ==, LS_SNIFF);
  g_assert_cmpint (c.options.encoding, ==, LS_ENCODING_AUTO);
  g_assert_cmpint (c.options.index_mode, ==, LS_INDEX_AUTO);
}

static void
test_carry_forward_forced (void)
{
  /* A forced quote carries as its forced value while the separator changes. */
  LsgDialect r = sniffed ();
  r.quote_forced = TRUE; /* quote '"' forced */
  LsgDialectCompose c
      = lsg_dialect_compose (r, lsg_dialect_change_separator (';'));
  g_assert_true (c.accepted);
  g_assert_cmpint (c.options.separator, ==, ';');
  g_assert_cmpint (c.options.quote, ==, '"'); /* carried forced */

  /* A forced separator carries while the quote changes. */
  LsgDialect r2 = sniffed ();
  r2.separator_forced = TRUE; /* separator ',' forced */
  LsgDialectCompose c2
      = lsg_dialect_compose (r2, lsg_dialect_change_quote ('\''));
  g_assert_true (c2.accepted);
  g_assert_cmpint (c2.options.separator, ==, ','); /* carried forced */
  g_assert_cmpint (c2.options.quote, ==, '\'');

  /* A forced header carries as LS_HEADER_ON while the separator changes. */
  LsgDialect r3 = sniffed ();
  r3.header = TRUE;
  r3.header_forced = TRUE;
  LsgDialectCompose c3
      = lsg_dialect_compose (r3, lsg_dialect_change_separator (';'));
  g_assert_true (c3.accepted);
  g_assert_cmpint (c3.options.header, ==, LS_HEADER_ON);

  /* A forced encoding carries as its value while the separator changes. */
  LsgDialect r4 = sniffed ();
  r4.encoding = LS_ENCODING_LATIN1;
  r4.encoding_forced = TRUE;
  LsgDialectCompose c4
      = lsg_dialect_compose (r4, lsg_dialect_change_separator (';'));
  g_assert_true (c4.accepted);
  g_assert_cmpint (c4.options.encoding, ==, LS_ENCODING_LATIN1);
}

static void
test_quote_none (void)
{
  LsgDialectCompose c
      = lsg_dialect_compose (sniffed (), lsg_dialect_change_quote_none ());
  g_assert_true (c.accepted);
  g_assert_cmpint (c.options.quote, ==, LS_QUOTE_NONE);
}

/* ------------------------------------------------------------------------- */
/* G2 — validation                                                           */
/* ------------------------------------------------------------------------- */

static void
test_reject_collision_with_forced (void)
{
  /* Forcing the separator equal to the CARRIED FORCED quote is rejected (silent
   * no-op). */
  LsgDialect r = sniffed ();
  r.quote_forced = TRUE; /* quote '"' forced */
  LsgDialectCompose c
      = lsg_dialect_compose (r, lsg_dialect_change_separator ('"'));
  g_assert_false (c.accepted);

  /* The mirror: forcing the quote equal to the carried forced separator. */
  LsgDialect r2 = sniffed ();
  r2.separator = ',';
  r2.separator_forced = TRUE;
  LsgDialectCompose c2
      = lsg_dialect_compose (r2, lsg_dialect_change_quote (','));
  g_assert_false (c2.accepted);
}

static void
test_accept_equal_sniffed (void)
{
  /* Forcing the separator equal to a merely SNIFFED quote is ACCEPTED (the
   * re-open re-sniffs the quote and excludes the conflict — the ABI rule). */
  LsgDialect r = sniffed (); /* quote '"' sniffed, not forced */
  LsgDialectCompose c
      = lsg_dialect_compose (r, lsg_dialect_change_separator ('"'));
  g_assert_true (c.accepted);
  g_assert_cmpint (c.options.separator, ==, '"');
  g_assert_cmpint (c.options.quote, ==, LS_SNIFF);
}

static void
test_reject_bad_byte (void)
{
  /* A forced separator/quote byte outside ASCII 0x01..0x7F, or CR / LF. */
  g_assert_false (
      lsg_dialect_compose (sniffed (), lsg_dialect_change_separator (0x0A))
          .accepted); /* LF */
  g_assert_false (
      lsg_dialect_compose (sniffed (), lsg_dialect_change_separator (0x0D))
          .accepted); /* CR */
  g_assert_false (
      lsg_dialect_compose (sniffed (), lsg_dialect_change_separator (0x00))
          .accepted);
  g_assert_false (
      lsg_dialect_compose (sniffed (), lsg_dialect_change_quote (200))
          .accepted); /* > 0x7F */
}

static void
test_header_encoding_always_accepted (void)
{
  /* Header and encoding changes are always valid; an encoding change never
   * touches the dialect bytes. */
  LsgDialectCompose h
      = lsg_dialect_compose (sniffed (), lsg_dialect_change_header (TRUE));
  g_assert_true (h.accepted);
  g_assert_cmpint (h.options.header, ==, LS_HEADER_ON);

  LsgDialectCompose e = lsg_dialect_compose (
      sniffed (), lsg_dialect_change_encoding (LSG_ENCODING_UTF16LE));
  g_assert_true (e.accepted);
  g_assert_cmpint (e.options.encoding, ==, LS_ENCODING_UTF16LE);
  g_assert_cmpint (e.options.separator, ==, LS_SNIFF); /* bytes untouched */
  g_assert_cmpint (e.options.quote, ==, LS_SNIFF);
}

/* ------------------------------------------------------------------------- */
/* G2 — the "Custom…" single-ASCII-byte entry (F3b)                          */
/* ------------------------------------------------------------------------- */

static void
test_parse_custom_byte (void)
{
  guint8 b = 0;
  g_assert_true (lsg_dialect_parse_custom_byte ("|", &b));
  g_assert_cmpuint (b, ==, 0x7C);
  g_assert_true (lsg_dialect_parse_custom_byte (";", &b));
  g_assert_cmpuint (b, ==, ';');

  /* Rejected entries (leaving the byte for the caller to ignore). */
  g_assert_false (lsg_dialect_parse_custom_byte ("", &b));      /* empty */
  g_assert_false (lsg_dialect_parse_custom_byte ("ab", &b));    /* 2 chars */
  g_assert_false (lsg_dialect_parse_custom_byte ("\xC3\xA9", &b)); /* 'é' (2 bytes) */
  g_assert_false (lsg_dialect_parse_custom_byte ("\n", &b));    /* LF */
  g_assert_false (lsg_dialect_parse_custom_byte ("\r", &b));    /* CR */
  g_assert_false (lsg_dialect_parse_custom_byte (NULL, &b));    /* NULL */

  /* End-to-end: a parsed custom byte still routes through compose's collision
   * check — forcing separator '"' when the quote is a carried forced '"' is a
   * silent no-op. */
  guint8 cb = 0;
  g_assert_true (lsg_dialect_parse_custom_byte ("\"", &cb));
  g_assert_cmpuint (cb, ==, 0x22);
  LsgDialect r = sniffed ();
  r.quote_forced = TRUE;
  g_assert_false (
      lsg_dialect_compose (r, lsg_dialect_change_separator (cb)).accepted);
}

/* ------------------------------------------------------------------------- */
/* G3 — header re-anchor shift                                               */
/* ------------------------------------------------------------------------- */

static void
test_header_shift (void)
{
  g_assert_cmpint (lsg_dialect_header_shift (FALSE, FALSE), ==, 0);
  g_assert_cmpint (lsg_dialect_header_shift (TRUE, TRUE), ==, 0);
  g_assert_cmpint (lsg_dialect_header_shift (FALSE, TRUE), ==, -1); /* header ON */
  g_assert_cmpint (lsg_dialect_header_shift (TRUE, FALSE), ==, +1); /* header OFF */
}

/* ------------------------------------------------------------------------- */
/* G4 — encoding picker + candidate lists                                    */
/* ------------------------------------------------------------------------- */

static void
test_encoding_picker (void)
{
  const LsgEncoding *o = lsg_encoding_picker_options ();
  g_assert_cmpint (LSG_ENCODING_PICKER_OPTION_COUNT, ==, 6);
  g_assert_cmpint (o[0], ==, LSG_ENCODING_AUTO);
  g_assert_cmpint (o[1], ==, LSG_ENCODING_UTF8);
  g_assert_cmpint (o[2], ==, LSG_ENCODING_UTF16LE);
  g_assert_cmpint (o[3], ==, LSG_ENCODING_UTF16BE);
  g_assert_cmpint (o[4], ==, LSG_ENCODING_LATIN1);
  g_assert_cmpint (o[5], ==, LSG_ENCODING_WINDOWS1252);

  /* Automatic mode (not forced): the selection is Automatic, the detected value
   * is the resolved concrete encoding. */
  LsgDialect r = sniffed ();
  r.encoding = LS_ENCODING_WINDOWS1252; /* what detection resolved */
  g_assert_cmpint (lsg_encoding_picker_selection (r), ==, LSG_ENCODING_AUTO);
  g_assert_cmpint (lsg_encoding_picker_detected (r), ==, LSG_ENCODING_WINDOWS1252);

  /* Forced mode: the selection is the forced value. */
  LsgDialect rf = sniffed ();
  rf.encoding = LS_ENCODING_LATIN1;
  rf.encoding_forced = TRUE;
  g_assert_cmpint (lsg_encoding_picker_selection (rf), ==, LSG_ENCODING_LATIN1);
  g_assert_cmpint (lsg_encoding_picker_detected (rf), ==, LSG_ENCODING_LATIN1);
}

static void
test_candidates (void)
{
  const guint8 *s = lsg_dialect_separator_candidates ();
  g_assert_cmpint (LSG_DIALECT_SEPARATOR_CANDIDATE_COUNT, ==, 4);
  g_assert_cmpuint (s[0], ==, 0x2C); /* , */
  g_assert_cmpuint (s[1], ==, 0x3B); /* ; */
  g_assert_cmpuint (s[2], ==, 0x09); /* TAB */
  g_assert_cmpuint (s[3], ==, 0x7C); /* | */

  const guint8 *q = lsg_dialect_quote_candidates ();
  g_assert_cmpint (LSG_DIALECT_QUOTE_CANDIDATE_COUNT, ==, 2);
  g_assert_cmpuint (q[0], ==, 0x22); /* " */
  g_assert_cmpuint (q[1], ==, 0x27); /* ' */
}

/* ------------------------------------------------------------------------- */
/* G10 — compose feeds the correct field for each of the four change kinds   */
/* ------------------------------------------------------------------------- */

static void
test_compose_four_changes (void)
{
  LsgDialectCompose sep
      = lsg_dialect_compose (sniffed (), lsg_dialect_change_separator (';'));
  g_assert_true (sep.accepted);
  g_assert_cmpint (sep.options.separator, ==, ';');

  LsgDialectCompose q
      = lsg_dialect_compose (sniffed (), lsg_dialect_change_quote ('\''));
  g_assert_true (q.accepted);
  g_assert_cmpint (q.options.quote, ==, '\'');

  LsgDialectCompose h
      = lsg_dialect_compose (sniffed (), lsg_dialect_change_header (FALSE));
  g_assert_true (h.accepted);
  g_assert_cmpint (h.options.header, ==, LS_HEADER_OFF);

  LsgDialectCompose e = lsg_dialect_compose (
      sniffed (), lsg_dialect_change_encoding (LSG_ENCODING_UTF16BE));
  g_assert_true (e.accepted);
  g_assert_cmpint (e.options.encoding, ==, LS_ENCODING_UTF16BE);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/dialect/encoding-abi-pins", test_encoding_abi_pins);
  g_test_add_func ("/dialect/carry-forward-non-forced", test_carry_forward_non_forced);
  g_test_add_func ("/dialect/carry-forward-forced", test_carry_forward_forced);
  g_test_add_func ("/dialect/quote-none", test_quote_none);
  g_test_add_func ("/dialect/reject-collision-with-forced", test_reject_collision_with_forced);
  g_test_add_func ("/dialect/accept-equal-sniffed", test_accept_equal_sniffed);
  g_test_add_func ("/dialect/reject-bad-byte", test_reject_bad_byte);
  g_test_add_func ("/dialect/header-encoding-always-accepted", test_header_encoding_always_accepted);
  g_test_add_func ("/dialect/parse-custom-byte", test_parse_custom_byte);
  g_test_add_func ("/dialect/header-shift", test_header_shift);
  g_test_add_func ("/dialect/encoding-picker", test_encoding_picker);
  g_test_add_func ("/dialect/candidates", test_candidates);
  g_test_add_func ("/dialect/compose-four-changes", test_compose_four_changes);
  return g_test_run ();
}
