/*
 * lsg_column.c — column configuration, in two layers:
 *
 *   1. A pure view-model: discovery routing, `#N` and label-substring
 *      resolution (with the generic-name fallback) under a bounded
 *      retain-plus-overflow accumulation, and the replay-vs-reset decision a
 *      re-open needs. Touches neither core nor widget.
 *
 *   2. The column bridge — the SINGLE place this frontend calls `ls_column_*`.
 *      It marshals the ABI's two-pass variable-length copies (labels, null
 *      sentinel, conflict example) into OWNED buffers, copying every borrowed
 *      byte out immediately.
 */
#include "lsg_document_internal.h"
#include <lsg_column.h>

#include <string.h>

/* ========================================================================= */
/* PURE VIEW-MODEL                                                           */
/* ========================================================================= */

/* ---- Discovery mode ----------------------------------------------------- */

LsgColumnDiscoveryMode
lsg_column_discovery_mode (guint32 column_count)
{
  if (column_count == 0)
    return LSG_COLUMN_DISCOVERY_EMPTY;
  if (column_count <= LSG_COLUMN_FULL_LIST_MAX)
    return LSG_COLUMN_DISCOVERY_FULL_LIST;
  return LSG_COLUMN_DISCOVERY_SEARCH_ONLY;
}

/* ---- `#N` direct address ------------------------------------------------ */

LsgColumnDirectAddress
lsg_column_resolve_direct_address (const char *query, guint32 column_count)
{
  LsgColumnDirectAddress out = { LSG_COLUMN_ADDRESS_NOT_DIRECT, 0 };

  /* Not a `#`-query (incl. NULL / empty / a leading space) -> label search. */
  if (query == NULL || query[0] != '#')
    return out;

  const char *p = query + 1;
  /* The remainder must be [1-9][0-9]* — no "#", no leading zero, no sign, no
   * whitespace, no non-ASCII digit. */
  if (*p < '1' || *p > '9')
    {
      out.kind = LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN;
      return out;
    }

  guint64 n = 0;
  for (; *p != '\0'; p++)
    {
      if (*p < '0' || *p > '9')
        {
          out.kind = LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN;
          return out;
        }
      n = n * 10 + (guint64)(*p - '0');
      if (n
          > G_MAXUINT32) /* out of any 32-bit column range (and no overflow) */
        {
          out.kind = LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN;
          return out;
        }
    }

  if (n < 1 || n > column_count)
    {
      out.kind = LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN;
      return out;
    }

  out.kind = LSG_COLUMN_ADDRESS_RESOLVED;
  out.column = (guint32)(n - 1); /* 1-based query -> 0-based column */
  return out;
}

/* ---- Generic column names + label search -------------------------------- */

char *
lsg_column_generic_name (guint32 index)
{
  /* 0-based bijective base-26 over A–Z: 0 -> "A", 25 -> "Z", 26 -> "AA". */
  GString *s = g_string_new (NULL);
  guint64 n = (guint64)index + 1;
  while (n > 0)
    {
      n--;
      g_string_prepend_c (s, (char)('A' + (n % 26)));
      n /= 26;
    }
  return g_string_free (s, FALSE);
}

/* The candidate's SEARCHABLE text: its label when present + non-empty, else
 * the generic name + " " + the 1-based index (e.g. column 26 -> "AA 27"). An
 * OWNED string (g_free). */
static char *
searchable_text (LsgColumnLabelCandidate candidate)
{
  if (candidate.label != NULL && candidate.label[0] != '\0')
    return g_strdup (candidate.label);

  char *generic = lsg_column_generic_name (candidate.column);
  char *out = g_strdup_printf ("%s %u", generic, candidate.column + 1);
  g_free (generic);
  return out;
}

gboolean
lsg_column_label_matches (const char *query, LsgColumnLabelCandidate candidate)
{
  /* An empty / NULL query matches nothing (the page shows its unsearched
   * list). */
  if (query == NULL || query[0] == '\0')
    return FALSE;

  char *text = searchable_text (candidate);
  char *hay = g_utf8_casefold (text, -1);
  char *needle = g_utf8_casefold (query, -1);
  gboolean found = (strstr (hay, needle) != NULL);
  g_free (needle);
  g_free (hay);
  g_free (text);
  return found;
}

LsgColumnMatchAccumulation
lsg_column_match_initial (void)
{
  LsgColumnMatchAccumulation acc = { { 0 }, 0, FALSE };
  return acc;
}

gboolean
lsg_column_match_stop (LsgColumnMatchAccumulation acc)
{
  return acc.overflow; /* the UI has its overflow notice; no more IDs needed */
}

LsgColumnMatchAccumulation
lsg_column_match_accumulate (LsgColumnMatchAccumulation acc, const char *query,
                             const LsgColumnLabelCandidate *batch,
                             guint batch_len)
{
  if (acc.overflow)
    return acc; /* frozen once overflowed: a no-op */

  for (guint i = 0; i < batch_len; i++)
    {
      if (!lsg_column_label_matches (query, batch[i]))
        continue;
      if (acc.n_retained < LSG_COLUMN_RESULT_MAX)
        {
          acc.retained[acc.n_retained] = batch[i].column;
          acc.n_retained++;
        }
      else
        {
          /* The (RESULT_MAX+1)-th match: freeze `retained`, set overflow,
           * stop.
           */
          acc.overflow = TRUE;
          return acc;
        }
    }
  return acc;
}

/* ---- Per-session column settings + the re-open decision ----------------- */

LsgColumnUserSettings
lsg_column_user_settings_default (void)
{
  LsgColumnUserSettings s;
  memset (&s, 0,
          sizeof s); /* all-Auto: no override / sentinel / format /
                      * hidden / manual width (a zeroed format == auto) */
  return s;
}

gboolean
lsg_column_user_settings_is_default (const LsgColumnUserSettings *settings)
{
  if (settings == NULL)
    return TRUE;
  if (settings->has_override || settings->has_null_sentinel || settings->hidden
      || settings->has_manual_width)
    return FALSE;
  return lsg_column_format_options_is_auto (settings->format);
}

LsgColumnReopenDecision
lsg_column_reopen_decide (LsgColumnReopenChange change, guint32 old_count,
                          guint32 new_count,
                          const LsgColumnHeaderIdentity *old_headers,
                          guint n_old_headers,
                          const LsgColumnHeaderIdentity *new_headers,
                          guint n_new_headers)
{
  /* HEADER_ONLY: the column count is the only safety condition (the header
   * labels shift by definition, so identities are ignored). */
  if (change == LSG_COLUMN_REOPEN_HEADER_ONLY)
    return (old_count == new_count) ? LSG_COLUMN_REOPEN_REPLAY
                                    : LSG_COLUMN_REOPEN_RESET;

  /* SEPARATOR_QUOTE_ENCODING: equal count, both headered, no truncation, and
   * byte-identical ordered identities — else reset. */
  if (old_count != new_count)
    return LSG_COLUMN_REOPEN_RESET;
  if (old_headers == NULL || new_headers == NULL)
    return LSG_COLUMN_REOPEN_RESET; /* a headerless side is never safe */
  if (n_old_headers != old_count || n_new_headers != new_count)
    return LSG_COLUMN_REOPEN_RESET;

  for (guint32 i = 0; i < old_count; i++)
    {
      if (old_headers[i].truncated || new_headers[i].truncated)
        return LSG_COLUMN_REOPEN_RESET;
      if (old_headers[i].len != new_headers[i].len)
        return LSG_COLUMN_REOPEN_RESET;
      if (old_headers[i].len != 0
          && memcmp (old_headers[i].bytes, new_headers[i].bytes,
                     old_headers[i].len)
                 != 0)
        return LSG_COLUMN_REOPEN_RESET;
    }
  return LSG_COLUMN_REOPEN_REPLAY;
}

/* ========================================================================= */
/* THE COLUMN CORE BRIDGE (over the real core; reaches doc->doc)             */
/* ========================================================================= */

ls_column_type
lsg_column_override_type (ls_column_type_kind kind,
                          ls_column_datetime_semantics semantics)
{
  ls_column_type t;
  memset (&t, 0, sizeof t);
  t.struct_size = (uint32_t)sizeof (ls_column_type);
  t.abi_version = LS_COLUMN_METADATA_ABI_VERSION;
  t.kind = (uint32_t)kind;
  t.flags = 0;
  t.decimal_precision = LS_COLUMN_TYPE_PRECISION_UNSPECIFIED;
  t.decimal_scale = LS_COLUMN_TYPE_SCALE_UNSPECIFIED;
  /* datetime semantics only apply to a DATETIME override; every other kind is
   * forced to NONE. */
  t.datetime_semantics = (kind == LS_COLUMN_TYPE_DATETIME)
                             ? (uint32_t)semantics
                             : (uint32_t)LS_COLUMN_DATETIME_NONE;
  t.datetime_fraction_digits = LS_COLUMN_TYPE_FRACTION_DIGITS_UNSPECIFIED;
  t.reserved = 0;
  return t;
}

ls_column_result
lsg_document_column_metadata_get_many (const LsgDocument *doc,
                                       const guint32 *ids, guint32 count,
                                       ls_column_metadata *out_items,
                                       guint32 capacity,
                                       guint64 *out_generation)
{
  if (doc == NULL || doc->doc == NULL || out_items == NULL)
    return LS_COLUMN_INVALID_ARGUMENT;
  /* Pre-set each out item's struct_size / abi_version (the ABI requires it).
   */
  for (guint32 i = 0; i < capacity; i++)
    {
      out_items[i].struct_size = (uint32_t)sizeof (ls_column_metadata);
      out_items[i].abi_version = LS_COLUMN_METADATA_ABI_VERSION;
    }
  return ls_column_metadata_get_many (doc->doc, ids, count, out_items,
                                      capacity, out_generation);
}

ls_column_result
lsg_document_column_metadata_poll (const LsgDocument *doc,
                                   ls_column_inference_status *out_status)
{
  if (doc == NULL || doc->doc == NULL || out_status == NULL)
    return LS_COLUMN_INVALID_ARGUMENT;
  out_status->struct_size = (uint32_t)sizeof (ls_column_inference_status);
  out_status->abi_version = LS_COLUMN_METADATA_ABI_VERSION;
  return ls_column_metadata_poll (doc->doc, out_status);
}

ls_column_result
lsg_document_column_inference_request (LsgDocument *doc, const guint32 *ids,
                                       guint32 count)
{
  if (doc == NULL || doc->doc == NULL)
    return LS_COLUMN_INVALID_ARGUMENT;
  return ls_column_inference_request (doc->doc, ids, count);
}

void
lsg_document_column_inference_cancel (LsgDocument *doc)
{
  if (doc == NULL || doc->doc == NULL)
    return;
  ls_column_inference_cancel (doc->doc);
}

ls_column_result
lsg_document_column_inference_accept_proposal (LsgDocument *doc,
                                               guint32 column)
{
  if (doc == NULL || doc->doc == NULL)
    return LS_COLUMN_INVALID_ARGUMENT;
  return ls_column_inference_accept_proposal (doc->doc, column);
}

ls_column_result
lsg_document_column_override_set (LsgDocument *doc, guint32 column,
                                  const ls_column_type *type)
{
  if (doc == NULL || doc->doc == NULL || type == NULL)
    return LS_COLUMN_INVALID_ARGUMENT;
  return ls_column_override_set (doc->doc, column, type);
}

ls_column_result
lsg_document_column_override_clear (LsgDocument *doc, guint32 column)
{
  if (doc == NULL || doc->doc == NULL)
    return LS_COLUMN_INVALID_ARGUMENT;
  return ls_column_override_clear (doc->doc, column);
}

ls_column_result
lsg_document_column_null_sentinel_set (LsgDocument *doc, guint32 column,
                                       const guint8 *bytes, gsize len)
{
  if (doc == NULL || doc->doc == NULL)
    return LS_COLUMN_INVALID_ARGUMENT;
  return ls_column_null_sentinel_set (doc->doc, column, bytes, len);
}

ls_column_result
lsg_document_column_null_sentinel_clear (LsgDocument *doc, guint32 column)
{
  if (doc == NULL || doc->doc == NULL)
    return LS_COLUMN_INVALID_ARGUMENT;
  return ls_column_null_sentinel_clear (doc->doc, column);
}

void
lsg_column_bytes_clear (LsgColumnBytes *b)
{
  if (b != NULL)
    {
      g_free (b->bytes);
      b->bytes = NULL;
      b->len = 0;
      b->present = FALSE;
    }
}

/* Shared two-pass copy of a single bounded ABI value (null sentinel / conflict
 * example) into an OWNED LsgColumnBytes. `copy` is the ABI two-pass call. */
typedef ls_column_result (*two_pass_copy_fn) (const ls_doc *doc,
                                              uint32_t column, uint8_t *buf,
                                              size_t buf_capacity,
                                              size_t *out_required);

static LsgColumnBytes
copy_two_pass (const LsgDocument *doc, guint32 column, two_pass_copy_fn copy)
{
  LsgColumnBytes out = { FALSE, NULL, 0 };
  if (doc == NULL || doc->doc == NULL)
    return out;

  size_t required = 0;
  ls_column_result r = copy (doc->doc, column, NULL, 0, &required);
  if (r != LS_COLUMN_OK) /* NO_VALUE (absent) or an error -> not present */
    return out;

  out.present = TRUE;
  out.len = required;
  if (required > 0)
    {
      out.bytes = g_malloc (required);
      size_t got = 0;
      r = copy (doc->doc, column, out.bytes, required, &got);
      if (r != LS_COLUMN_OK)
        {
          g_free (out.bytes);
          out.bytes = NULL;
          out.len = 0;
          out.present = FALSE;
        }
    }
  return out;
}

LsgColumnBytes
lsg_document_column_null_sentinel_copy (const LsgDocument *doc, guint32 column)
{
  return copy_two_pass (doc, column, ls_column_null_sentinel_copy);
}

LsgColumnBytes
lsg_document_column_conflict_example_copy (const LsgDocument *doc,
                                           guint32 column)
{
  return copy_two_pass (doc, column, ls_column_conflict_example_copy);
}

void
lsg_column_labels_free (LsgColumnLabel *labels, guint32 count)
{
  if (labels == NULL)
    return;
  for (guint32 i = 0; i < count; i++)
    g_free (labels[i].bytes);
  g_free (labels);
}

LsgColumnLabel *
lsg_document_column_labels_copy_many (const LsgDocument *doc,
                                      const guint32 *ids, guint32 count,
                                      ls_column_result *out_result)
{
  if (doc == NULL || doc->doc == NULL)
    {
      if (out_result != NULL)
        *out_result = LS_COLUMN_INVALID_ARGUMENT;
      return NULL;
    }

  /* Pass 1: fill the spans + the required arena length (NULL/zero arena). */
  guint32 slots = (count > 0) ? count : 1; /* keep a non-NULL empty array */
  ls_column_label_span *spans = g_new0 (ls_column_label_span, slots);
  for (guint32 i = 0; i < count; i++)
    {
      spans[i].struct_size = (uint32_t)sizeof (ls_column_label_span);
      spans[i].abi_version = LS_COLUMN_METADATA_ABI_VERSION;
    }

  size_t required = 0;
  ls_column_result r = ls_column_labels_copy_many (doc->doc, ids, count, spans,
                                                   count, NULL, 0, &required);
  if (r != LS_COLUMN_OK)
    {
      g_free (spans);
      if (out_result != NULL)
        *out_result = r;
      return NULL;
    }

  /* Pass 2: copy the label bytes into an arena of the required size. */
  uint8_t *arena = NULL;
  if (required > 0)
    {
      arena = g_malloc (required);
      r = ls_column_labels_copy_many (doc->doc, ids, count, spans, count,
                                      arena, required, &required);
      if (r != LS_COLUMN_OK)
        {
          g_free (arena);
          g_free (spans);
          if (out_result != NULL)
            *out_result = r;
          return NULL;
        }
    }

  LsgColumnLabel *labels = g_new0 (LsgColumnLabel, slots);
  for (guint32 i = 0; i < count; i++)
    {
      labels[i].column = (ids != NULL) ? ids[i] : spans[i].column;
      labels[i].present = (spans[i].flags & LS_COLUMN_LABEL_PRESENT) != 0;
      labels[i].truncated = (spans[i].flags & LS_COLUMN_LABEL_TRUNCATED) != 0;
      labels[i].len = (gsize)spans[i].len;
      if (labels[i].present && spans[i].len > 0 && arena != NULL)
        {
          labels[i].bytes = g_malloc ((gsize)spans[i].len);
          memcpy (labels[i].bytes, arena + spans[i].offset,
                  (gsize)spans[i].len);
        }
      else
        {
          labels[i].bytes = NULL;
        }
    }

  g_free (arena);
  g_free (spans);
  if (out_result != NULL)
    *out_result = LS_COLUMN_OK;
  return labels;
}
