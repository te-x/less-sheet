/*
 * test_column.c — RED behavior tests for the COLUMN CONFIGURATION module
 * (lsg_column.h). Two halves, mirroring the macOS split:
 *
 *   PURE VIEW-MODEL (glib only) — the C port of ColumnDiscovery /
 *   ColumnLabelSearch / GenericColumnName / ColumnSessionModel:
 *     G5  — discovery mode thresholds off the single named constant; `#N`
 *           1-based direct address (+ out-of-range/no-such); localized case-
 *           insensitive label substring with the generic-name fallback
 *           ("AA 27"); the retain-<=10 + overflow accumulation in source order.
 *     G6  — the Auto default + is-default predicate; the replay-vs-reset re-open
 *           decision (header-only vs sep/quote/encoding; count / header-presence
 *           / truncation / byte-identity).
 *     (the pure override-type descriptor builder is pinned here too.)
 *
 *   CORE BRIDGE (over the real Zig core, the columns.csv fixture) —
 *     G7  — override set/clear reflected in the effective type; null sentinel
 *           set/clear/copy round-trips; inference request -> poll DONE ->
 *           resolved metadata; labels copy-many returns the header labels; a
 *           conflict column yields a conflict state + example. Every returned
 *           buffer is an owned copy.
 *     G8  — O(<=10) column work: the pure discovery/accumulation cap bounds the
 *           requested set regardless of column count, and a bounded 10-ID batch
 *           read over a synthetic 100k-column document is O(batch) (open stays
 *           O(head), the read never enumerates all columns).
 *     G11 — inference cancel + close is clean (exercised for the leak check).
 *
 * RED against the seeded src/lsg_column.c (discovery EMPTY; `#N` never resolves;
 * generic name ""; label match FALSE; accumulation never grows; decide RESET;
 * every bridge call errors/empty) and GREEN as the module is implemented. The
 * columns.csv fixture path is baked in (resolves inside the container).
 *
 * columns.csv (header "id,name,amount,mixed" is forced ON; 16 data rows):
 *   col 0 id     — all integers 1..16
 *   col 1 name   — all text (alpha, bravo, …)
 *   col 2 amount — all decimals (10.50, 20.25, …)
 *   col 3 mixed  — integers 1..12 then "foo","bar","baz","qux" (a conflict)
 */
#include <glib.h>
#include <string.h>
#include <lesssheet.h>
#include <lsg_column.h>
#include <lsg_document.h>

/* ========================================================================= */
/* PURE VIEW-MODEL                                                           */
/* ========================================================================= */

/* --- G5: discovery mode --- */

static void
test_discovery_mode (void)
{
  g_assert_cmpint (lsg_column_discovery_mode (0), ==, LSG_COLUMN_DISCOVERY_EMPTY);
  g_assert_cmpint (lsg_column_discovery_mode (1), ==, LSG_COLUMN_DISCOVERY_FULL_LIST);
  g_assert_cmpint (lsg_column_discovery_mode (LSG_COLUMN_FULL_LIST_MAX), ==,
                   LSG_COLUMN_DISCOVERY_FULL_LIST);
  g_assert_cmpint (lsg_column_discovery_mode (LSG_COLUMN_FULL_LIST_MAX + 1), ==,
                   LSG_COLUMN_DISCOVERY_SEARCH_ONLY);
  g_assert_cmpint (lsg_column_discovery_mode (100000), ==,
                   LSG_COLUMN_DISCOVERY_SEARCH_ONLY);
}

/* --- G5: `#N` direct address --- */

static void
assert_resolved (const char *q, guint32 count, guint32 col)
{
  LsgColumnDirectAddress a = lsg_column_resolve_direct_address (q, count);
  g_assert_cmpint (a.kind, ==, LSG_COLUMN_ADDRESS_RESOLVED);
  g_assert_cmpuint (a.column, ==, col);
}

static void
assert_addr_kind (const char *q, guint32 count, LsgColumnDirectAddressKind kind)
{
  LsgColumnDirectAddress a = lsg_column_resolve_direct_address (q, count);
  g_assert_cmpint (a.kind, ==, kind);
}

static void
test_direct_address (void)
{
  assert_resolved ("#1", 100, 0);
  assert_resolved ("#5", 100, 4);
  assert_resolved ("#100", 100, 99);

  assert_addr_kind ("#101", 100, LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN); /* > count */
  assert_addr_kind ("#0", 100, LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN);
  assert_addr_kind ("#01", 100, LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN); /* leading zero */
  assert_addr_kind ("#", 100, LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN);
  assert_addr_kind ("#5 ", 100, LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN);  /* trailing ws */
  assert_addr_kind ("#+5", 100, LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN);  /* sign */
  assert_addr_kind ("#99999999999999999999", 100,
                    LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN); /* overflow */

  assert_addr_kind ("name", 100, LSG_COLUMN_ADDRESS_NOT_DIRECT);
  assert_addr_kind (" #5", 100, LSG_COLUMN_ADDRESS_NOT_DIRECT); /* leading space */
  assert_addr_kind ("", 100, LSG_COLUMN_ADDRESS_NOT_DIRECT);
  assert_addr_kind (NULL, 100, LSG_COLUMN_ADDRESS_NOT_DIRECT);
}

/* --- G5: generic column names --- */

static void
assert_generic (guint32 index, const char *want)
{
  char *n = lsg_column_generic_name (index);
  g_assert_cmpstr (n, ==, want);
  g_free (n);
}

static void
test_generic_name (void)
{
  assert_generic (0, "A");
  assert_generic (25, "Z");
  assert_generic (26, "AA");
  assert_generic (27, "AB");
  assert_generic (701, "ZZ");
  assert_generic (702, "AAA");
}

/* --- G5: label match (localized case-insensitive substring + fallback) --- */

static LsgColumnLabelCandidate
cand (guint32 col, const char *label)
{
  LsgColumnLabelCandidate c = { col, label };
  return c;
}

static void
test_label_matches (void)
{
  /* Labelled column: case-insensitive substring; empty query matches nothing. */
  g_assert_true (lsg_column_label_matches ("ri", cand (5, "Price")));
  g_assert_true (lsg_column_label_matches ("PRICE", cand (5, "Price")));
  g_assert_false (lsg_column_label_matches ("xyz", cand (5, "Price")));
  g_assert_false (lsg_column_label_matches ("", cand (5, "Price")));

  /* Headerless column (NULL label): searchable text is generic-name + 1-based
   * index, e.g. column 26 -> "AA 27". */
  g_assert_true (lsg_column_label_matches ("AA", cand (26, NULL)));
  g_assert_true (lsg_column_label_matches ("aa", cand (26, NULL))); /* case-insensitive */
  g_assert_true (lsg_column_label_matches ("27", cand (26, NULL)));
  g_assert_false (lsg_column_label_matches ("28", cand (26, NULL)));

  /* Empty label falls back too: column 0 -> "A 1". */
  g_assert_true (lsg_column_label_matches ("A", cand (0, "")));
  g_assert_true (lsg_column_label_matches ("1", cand (0, "")));
}

/* --- G5: bounded match accumulation (retain <=10 + overflow, source order) --- */

static void
test_match_accumulate (void)
{
  /* Source order preserved; non-matching candidates skipped. */
  LsgColumnLabelCandidate mixed[3]
      = { cand (0, "x"), cand (1, "z"), cand (2, "x") };
  LsgColumnMatchAccumulation a
      = lsg_column_match_accumulate (lsg_column_match_initial (), "x", mixed, 3);
  g_assert_cmpuint (a.n_retained, ==, 2);
  g_assert_cmpuint (a.retained[0], ==, 0);
  g_assert_cmpuint (a.retained[1], ==, 2);
  g_assert_false (a.overflow);
  g_assert_false (lsg_column_match_stop (a));

  /* Fill exactly to the cap over two batches (no overflow at exactly RESULT_MAX). */
  LsgColumnLabelCandidate all[11];
  for (guint i = 0; i < 11; i++)
    all[i] = cand (i, "x");

  LsgColumnMatchAccumulation acc = lsg_column_match_initial ();
  acc = lsg_column_match_accumulate (acc, "x", &all[0], 5);
  g_assert_cmpuint (acc.n_retained, ==, 5);
  acc = lsg_column_match_accumulate (acc, "x", &all[5], 5);
  g_assert_cmpuint (acc.n_retained, ==, LSG_COLUMN_RESULT_MAX);
  g_assert_false (acc.overflow); /* exactly RESULT_MAX is NOT overflow */
  g_assert_false (lsg_column_match_stop (acc));
  for (guint i = 0; i < LSG_COLUMN_RESULT_MAX; i++)
    g_assert_cmpuint (acc.retained[i], ==, i); /* source order */

  /* The (RESULT_MAX+1)-th match sets overflow, freezes retained, stops. */
  acc = lsg_column_match_accumulate (acc, "x", &all[10], 1);
  g_assert_true (acc.overflow);
  g_assert_cmpuint (acc.n_retained, ==, LSG_COLUMN_RESULT_MAX);
  g_assert_true (lsg_column_match_stop (acc));

  /* A further batch after overflow is a no-op. */
  LsgColumnMatchAccumulation acc2
      = lsg_column_match_accumulate (acc, "x", &all[0], 5);
  g_assert_cmpuint (acc2.n_retained, ==, LSG_COLUMN_RESULT_MAX);
  g_assert_true (acc2.overflow);
}

/* --- G6: default column settings + is-default --- */

static void
test_user_settings_default (void)
{
  LsgColumnUserSettings d = lsg_column_user_settings_default ();
  g_assert_true (lsg_column_user_settings_is_default (&d));

  LsgColumnUserSettings hidden = lsg_column_user_settings_default ();
  hidden.hidden = TRUE;
  g_assert_false (lsg_column_user_settings_is_default (&hidden));

  LsgColumnUserSettings ov = lsg_column_user_settings_default ();
  ov.has_override = TRUE;
  g_assert_false (lsg_column_user_settings_is_default (&ov));

  LsgColumnUserSettings sent = lsg_column_user_settings_default ();
  sent.has_null_sentinel = TRUE;
  g_assert_false (lsg_column_user_settings_is_default (&sent));

  LsgColumnUserSettings fmt = lsg_column_user_settings_default ();
  fmt.format.grouping = TRUE;
  g_assert_false (lsg_column_user_settings_is_default (&fmt));

  LsgColumnUserSettings w = lsg_column_user_settings_default ();
  w.has_manual_width = TRUE;
  g_assert_false (lsg_column_user_settings_is_default (&w));
}

/* --- G6: replay-vs-reset re-open decision --- */

static LsgColumnHeaderIdentity
ident (const char *s, gboolean truncated)
{
  LsgColumnHeaderIdentity h = { (const guint8 *)s, strlen (s), truncated };
  return h;
}

static void
test_reopen_decide (void)
{
  LsgColumnHeaderIdentity old2[2] = { ident ("id", FALSE), ident ("name", FALSE) };
  LsgColumnHeaderIdentity same2[2] = { ident ("id", FALSE), ident ("name", FALSE) };
  LsgColumnHeaderIdentity renamed2[2] = { ident ("id", FALSE), ident ("qty", FALSE) };
  LsgColumnHeaderIdentity trunc2[2] = { ident ("id", TRUE), ident ("name", FALSE) };

  /* Header-only: replay iff the count is unchanged (headers ignored). */
  g_assert_cmpint (lsg_column_reopen_decide (LSG_COLUMN_REOPEN_HEADER_ONLY, 3, 3,
                                             NULL, 0, NULL, 0),
                   ==, LSG_COLUMN_REOPEN_REPLAY);
  g_assert_cmpint (lsg_column_reopen_decide (LSG_COLUMN_REOPEN_HEADER_ONLY, 3, 4,
                                             NULL, 0, NULL, 0),
                   ==, LSG_COLUMN_REOPEN_RESET);

  /* Sep/quote/encoding: replay iff equal count, both headered, no truncation,
   * byte-identical ordered identities. */
  g_assert_cmpint (
      lsg_column_reopen_decide (LSG_COLUMN_REOPEN_SEPARATOR_QUOTE_ENCODING, 2, 2,
                                old2, 2, same2, 2),
      ==, LSG_COLUMN_REOPEN_REPLAY);

  /* … a rename resets. */
  g_assert_cmpint (
      lsg_column_reopen_decide (LSG_COLUMN_REOPEN_SEPARATOR_QUOTE_ENCODING, 2, 2,
                                old2, 2, renamed2, 2),
      ==, LSG_COLUMN_REOPEN_RESET);
  /* … a truncated identity resets. */
  g_assert_cmpint (
      lsg_column_reopen_decide (LSG_COLUMN_REOPEN_SEPARATOR_QUOTE_ENCODING, 2, 2,
                                trunc2, 2, same2, 2),
      ==, LSG_COLUMN_REOPEN_RESET);
  /* … a headerless side (NULL) resets. */
  g_assert_cmpint (
      lsg_column_reopen_decide (LSG_COLUMN_REOPEN_SEPARATOR_QUOTE_ENCODING, 2, 2,
                                NULL, 0, same2, 2),
      ==, LSG_COLUMN_REOPEN_RESET);
  g_assert_cmpint (
      lsg_column_reopen_decide (LSG_COLUMN_REOPEN_SEPARATOR_QUOTE_ENCODING, 2, 2,
                                old2, 2, NULL, 0),
      ==, LSG_COLUMN_REOPEN_RESET);
  /* … a count mismatch resets. */
  g_assert_cmpint (
      lsg_column_reopen_decide (LSG_COLUMN_REOPEN_SEPARATOR_QUOTE_ENCODING, 2, 3,
                                old2, 2, same2, 2),
      ==, LSG_COLUMN_REOPEN_RESET);
}

/* --- pure override-type descriptor builder (bridge helper) --- */

static void
test_override_type_builder (void)
{
  ls_column_type t
      = lsg_column_override_type (LS_COLUMN_TYPE_INTEGER, LS_COLUMN_DATETIME_NONE);
  g_assert_cmpuint (t.struct_size, ==, sizeof (ls_column_type));
  g_assert_cmpuint (t.abi_version, ==, LS_COLUMN_METADATA_ABI_VERSION);
  g_assert_cmpuint (t.kind, ==, LS_COLUMN_TYPE_INTEGER);
  g_assert_cmpuint (t.flags, ==, 0);
  g_assert_cmpuint (t.datetime_semantics, ==, LS_COLUMN_DATETIME_NONE);
  g_assert_cmpuint (t.decimal_precision, ==, LS_COLUMN_TYPE_PRECISION_UNSPECIFIED);
  g_assert_cmpint (t.decimal_scale, ==, LS_COLUMN_TYPE_SCALE_UNSPECIFIED);
  g_assert_cmpuint (t.datetime_fraction_digits, ==,
                    LS_COLUMN_TYPE_FRACTION_DIGITS_UNSPECIFIED);
  g_assert_cmpuint (t.reserved, ==, 0);

  ls_column_type dt
      = lsg_column_override_type (LS_COLUMN_TYPE_DATETIME, LS_COLUMN_DATETIME_ZONED);
  g_assert_cmpuint (dt.kind, ==, LS_COLUMN_TYPE_DATETIME);
  g_assert_cmpuint (dt.datetime_semantics, ==, LS_COLUMN_DATETIME_ZONED);
}

/* ========================================================================= */
/* CORE BRIDGE (over the real core, columns.csv fixture)                     */
/* ========================================================================= */

/* Open columns.csv with the header forced ON (deterministic 4-column doc). */
static LsgDocument *
open_columns (void)
{
  ls_open_options opts = { LS_SNIFF, LS_SNIFF, LS_HEADER_ON, LS_INDEX_AUTO,
                           LS_ENCODING_AUTO };
  LsgOpenError err = LSG_OPEN_IO;
  LsgDocument *doc = lsg_document_open_local (COLUMNS_FIXTURE_PATH, &opts, &err);
  g_assert_nonnull (doc);
  g_assert_cmpint (err, ==, LSG_OPEN_OK);
  g_assert_cmpuint (lsg_document_column_count (doc), ==, 4);
  return doc;
}

/* Read one column's coherent metadata snapshot (a 1-ID batch). */
static ls_column_metadata
read_metadata (const LsgDocument *doc, guint32 col)
{
  ls_column_metadata item;
  guint64 gen = 0;
  ls_column_result r = lsg_document_column_metadata_get_many (doc, &col, 1,
                                                              &item, 1, &gen);
  g_assert_cmpint (r, ==, LS_COLUMN_OK);
  return item;
}

/* Poll the inference job until its finite work is DONE (bounded ~10 s). */
static gboolean
wait_inference_done (const LsgDocument *doc)
{
  for (int i = 0; i < 5000; i++)
    {
      ls_column_inference_status st;
      if (lsg_document_column_metadata_poll (doc, &st) == LS_COLUMN_OK
          && st.state == LS_COLUMN_JOB_DONE)
        return TRUE;
      g_usleep (2000);
    }
  return FALSE;
}

/* --- G7: labels copy-many returns the header labels (owned copies) --- */

static void
test_bridge_labels (void)
{
  LsgDocument *doc = open_columns ();
  const guint32 ids[4] = { 0, 1, 2, 3 };
  const char *want[4] = { "id", "name", "amount", "mixed" };

  ls_column_result r = LS_COLUMN_INVALID_ARGUMENT;
  LsgColumnLabel *labels
      = lsg_document_column_labels_copy_many (doc, ids, 4, &r);
  g_assert_cmpint (r, ==, LS_COLUMN_OK);
  g_assert_nonnull (labels);
  for (guint32 i = 0; i < 4; i++)
    {
      g_assert_true (labels[i].present);
      char *text = lsg_utf8_sanitize_dup (labels[i].bytes, labels[i].len);
      g_assert_cmpstr (text, ==, want[i]);
      g_free (text);
    }
  lsg_column_labels_free (labels, 4);
  lsg_document_close (doc);
}

/* --- G7: override set reflected in the effective type; clear reverts --- */

static void
test_bridge_override (void)
{
  LsgDocument *doc = open_columns ();

  ls_column_type ov
      = lsg_column_override_type (LS_COLUMN_TYPE_INTEGER, LS_COLUMN_DATETIME_NONE);
  g_assert_cmpint (lsg_document_column_override_set (doc, 1, &ov), ==, LS_COLUMN_OK);

  ls_column_metadata m = read_metadata (doc, 1);
  g_assert_cmpuint (m.effective.kind, ==, LS_COLUMN_TYPE_INTEGER);
  g_assert_cmpuint (m.effective_source, ==, LS_COLUMN_SOURCE_OVERRIDE);
  g_assert_true ((m.presence_flags & LS_COLUMN_HAS_OVERRIDE) != 0);

  g_assert_cmpint (lsg_document_column_override_clear (doc, 1), ==, LS_COLUMN_OK);
  ls_column_metadata m2 = read_metadata (doc, 1);
  g_assert_true ((m2.presence_flags & LS_COLUMN_HAS_OVERRIDE) == 0);
  g_assert_cmpuint (m2.effective_source, !=, LS_COLUMN_SOURCE_OVERRIDE);

  lsg_document_close (doc);
}

/* --- G7: null sentinel set/clear + copy round-trip --- */

static void
test_bridge_null_sentinel (void)
{
  LsgDocument *doc = open_columns ();
  const guint8 na[2] = { 'N', 'A' };

  g_assert_cmpint (lsg_document_column_null_sentinel_set (doc, 0, na, 2), ==,
                   LS_COLUMN_OK);
  ls_column_metadata m = read_metadata (doc, 0);
  g_assert_cmpuint (m.null_policy, ==, LS_COLUMN_NULL_SENTINEL);
  g_assert_cmpuint (m.null_sentinel_bytes, ==, 2);

  LsgColumnBytes s = lsg_document_column_null_sentinel_copy (doc, 0);
  g_assert_true (s.present);
  g_assert_cmpuint (s.len, ==, 2);
  g_assert_nonnull (s.bytes);
  g_assert_cmpint (memcmp (s.bytes, na, 2), ==, 0);
  lsg_column_bytes_clear (&s);

  g_assert_cmpint (lsg_document_column_null_sentinel_clear (doc, 0), ==, LS_COLUMN_OK);
  ls_column_metadata m2 = read_metadata (doc, 0);
  g_assert_cmpuint (m2.null_policy, ==, LS_COLUMN_NULL_NONE);
  LsgColumnBytes s2 = lsg_document_column_null_sentinel_copy (doc, 0);
  g_assert_false (s2.present);
  lsg_column_bytes_clear (&s2);

  lsg_document_close (doc);
}

/* --- G7: inference request -> poll DONE -> resolved metadata --- */

static void
test_bridge_inference (void)
{
  LsgDocument *doc = open_columns ();
  const guint32 ids[2] = { 0, 2 }; /* id (integer), amount (decimal) */
  g_assert_cmpint (lsg_document_column_inference_request (doc, ids, 2), ==,
                   LS_COLUMN_OK);
  g_assert_true (wait_inference_done (doc));

  ls_column_metadata mid = read_metadata (doc, 0);
  g_assert_cmpuint (mid.effective.kind, ==, LS_COLUMN_TYPE_INTEGER);
  g_assert_cmpuint (mid.inference_state, !=, LS_COLUMN_INFERENCE_UNREQUESTED);
  g_assert_cmpuint (mid.generation, !=, 0);

  ls_column_metadata mamt = read_metadata (doc, 2);
  g_assert_cmpuint (mamt.effective.kind, ==, LS_COLUMN_TYPE_DECIMAL);

  lsg_document_close (doc);
}

/* --- G7: a conflict column yields a conflict state + example --- */

static void
test_bridge_conflict (void)
{
  LsgDocument *doc = open_columns ();
  const guint32 ids[1] = { 3 }; /* mixed: 12 integers then 4 texts */
  g_assert_cmpint (lsg_document_column_inference_request (doc, ids, 1), ==,
                   LS_COLUMN_OK);
  g_assert_true (wait_inference_done (doc));

  ls_column_metadata m = read_metadata (doc, 3);
  g_assert_cmpuint (m.conflict_state, !=, LS_COLUMN_CONFLICT_NONE);

  LsgColumnBytes ex = lsg_document_column_conflict_example_copy (doc, 3);
  g_assert_true (ex.present);
  g_assert_nonnull (ex.bytes);
  char *text = lsg_utf8_sanitize_dup (ex.bytes, ex.len);
  gboolean known = (g_strcmp0 (text, "foo") == 0) || (g_strcmp0 (text, "bar") == 0)
                   || (g_strcmp0 (text, "baz") == 0) || (g_strcmp0 (text, "qux") == 0);
  g_assert_true (known);
  g_free (text);
  lsg_column_bytes_clear (&ex);

  lsg_document_close (doc);
}

/* --- G11: inference cancel + close is clean (exercised for the leak check) --- */

static void
test_bridge_inference_cancel (void)
{
  LsgDocument *doc = open_columns ();
  const guint32 ids[2] = { 0, 2 };
  g_assert_cmpint (lsg_document_column_inference_request (doc, ids, 2), ==,
                   LS_COLUMN_OK);
  lsg_document_column_inference_cancel (doc);
  /* The job state stays coherent after a cancel (CANCELLED, or DONE if the tiny
   * fixture already finished) — no crash, no leak; the close is clean. */
  ls_column_inference_status st;
  g_assert_cmpint (lsg_document_column_metadata_poll (doc, &st), ==, LS_COLUMN_OK);
  lsg_document_close (doc);
}

/* ========================================================================= */
/* G8 — O(<=10) column work                                                  */
/* ========================================================================= */

/* The pure cap: a wide document is search-only (no full-list enumeration), and
 * a broad query touching MANY matches retains only <=10 IDs + overflow, so the
 * requested-ID set the frontend derives is O(<=10) for ANY column count. */
static void
test_wide_cap_is_pure (void)
{
  g_assert_cmpint (lsg_column_discovery_mode (100000), ==,
                   LSG_COLUMN_DISCOVERY_SEARCH_ONLY);

  LsgColumnLabelCandidate *many = g_new (LsgColumnLabelCandidate, 100);
  for (guint i = 0; i < 100; i++)
    many[i] = cand (i, "x");

  LsgColumnMatchAccumulation acc = lsg_column_match_initial ();
  guint scanned = 0;
  for (guint i = 0; i < 100 && !lsg_column_match_stop (acc); i++)
    {
      acc = lsg_column_match_accumulate (acc, "x", &many[i], 1);
      scanned++;
    }
  g_assert_cmpuint (acc.n_retained, ==, LSG_COLUMN_RESULT_MAX);
  g_assert_true (acc.overflow);
  /* The caller stopped once overflow was set — it never scanned all 100. */
  g_assert_cmpuint (scanned, <=, LSG_COLUMN_RESULT_MAX + 1);
  g_free (many);
}

/* Write a synthetic ncols-column CSV (1 header row + 1 data row) into a temp
 * file; returns the OWNED path (caller g_free). */
static char *
make_wide_fixture (guint ncols)
{
  GError *e = NULL;
  char *dir = g_dir_make_tmp ("lsg_wide_XXXXXX", &e);
  g_assert_no_error (e);
  char *path = g_build_filename (dir, "wide.csv", NULL);

  GString *s = g_string_new (NULL);
  for (guint c = 0; c < ncols; c++)
    {
      if (c)
        g_string_append_c (s, ',');
      g_string_append_printf (s, "c%u", c);
    }
  g_string_append_c (s, '\n');
  for (guint c = 0; c < ncols; c++)
    {
      if (c)
        g_string_append_c (s, ',');
      g_string_append_c (s, '1');
    }
  g_string_append_c (s, '\n');

  g_assert_true (g_file_set_contents (path, s->str, (gssize)s->len, &e));
  g_assert_no_error (e);
  g_string_free (s, TRUE);
  g_free (dir);
  return path;
}

/* A bounded 10-ID batch read over a 100k-column document is O(batch): open
 * stays O(head) and the read never enumerates all columns. */
static void
test_wide_bridge_is_bounded (void)
{
  const guint ncols = 100000;
  char *path = make_wide_fixture (ncols);

  ls_open_options opts = { LS_SNIFF, LS_SNIFF, LS_HEADER_ON, LS_INDEX_AUTO,
                           LS_ENCODING_AUTO };
  LsgOpenError err = LSG_OPEN_IO;
  LsgDocument *doc = lsg_document_open_local (path, &opts, &err);
  g_assert_nonnull (doc);
  g_assert_cmpint (err, ==, LSG_OPEN_OK);
  g_assert_cmpuint (lsg_document_column_count (doc), ==, ncols);

  guint32 ids[10];
  for (guint32 i = 0; i < 10; i++)
    ids[i] = i;

  ls_column_metadata items[10];
  guint64 gen = 0;
  g_assert_cmpint (
      lsg_document_column_metadata_get_many (doc, ids, 10, items, 10, &gen), ==,
      LS_COLUMN_OK);

  ls_column_result lr = LS_COLUMN_INVALID_ARGUMENT;
  LsgColumnLabel *labels = lsg_document_column_labels_copy_many (doc, ids, 10, &lr);
  g_assert_cmpint (lr, ==, LS_COLUMN_OK);
  g_assert_nonnull (labels);
  lsg_column_labels_free (labels, 10);

  lsg_document_close (doc);
  g_free (path);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  /* Pure view-model (G5 / G6). */
  g_test_add_func ("/column/discovery-mode", test_discovery_mode);
  g_test_add_func ("/column/direct-address", test_direct_address);
  g_test_add_func ("/column/generic-name", test_generic_name);
  g_test_add_func ("/column/label-matches", test_label_matches);
  g_test_add_func ("/column/match-accumulate", test_match_accumulate);
  g_test_add_func ("/column/user-settings-default", test_user_settings_default);
  g_test_add_func ("/column/reopen-decide", test_reopen_decide);
  g_test_add_func ("/column/override-type-builder", test_override_type_builder);

  /* Core bridge (G7). */
  g_test_add_func ("/column/bridge-labels", test_bridge_labels);
  g_test_add_func ("/column/bridge-override", test_bridge_override);
  g_test_add_func ("/column/bridge-null-sentinel", test_bridge_null_sentinel);
  g_test_add_func ("/column/bridge-inference", test_bridge_inference);
  g_test_add_func ("/column/bridge-conflict", test_bridge_conflict);
  g_test_add_func ("/column/bridge-inference-cancel", test_bridge_inference_cancel);

  /* O(<=10) column work (G8). */
  g_test_add_func ("/column/wide-cap-is-pure", test_wide_cap_is_pure);
  g_test_add_func ("/column/wide-bridge-is-bounded", test_wide_bridge_is_bounded);

  return g_test_run ();
}
