/*
 * lsg_column.c — RED SEED for the column-configuration feature (lsg_column.h).
 * Compiles against the frozen header (so the CONFORMANCE gate passes) but
 * deliberately does NOT implement the behavior:
 *
 *   PURE VIEW-MODEL — discovery reports EMPTY for every count, `#N` never
 *   resolves, the generic name is "", the label match is always FALSE, the
 *   match accumulation never grows / never overflows, and the re-open decision
 *   is always RESET. The empty-accumulator and default-settings VALUES are
 * real (inputs the tests build on), so tests/test_column.c is RED strictly on
 * the unimplemented LOGIC.
 *
 *   CORE BRIDGE — every `lsg_document_column_*` call returns an error / empty
 *   without touching the core (`ls_column_*`), so the real-core round-trip
 *   tests (override / null sentinel / inference / labels / conflict) are RED.
 *
 * The implementer replaces the stubs; the bridge then reaches the core handle
 * through the non-frozen `struct _LsgDocument` seam (lsg_document_internal.h),
 * exactly like the find/filter bridges.
 */
#include <lsg_column.h>

#include <string.h>

/* ========================================================================= */
/* PURE VIEW-MODEL (SEED) */
/* ========================================================================= */

LsgColumnDiscoveryMode
lsg_column_discovery_mode (guint32 column_count)
{
  (void)column_count;
  return LSG_COLUMN_DISCOVERY_EMPTY; /* SEED: never a list / search */
}

LsgColumnDirectAddress
lsg_column_resolve_direct_address (const char *query, guint32 column_count)
{
  (void)query;
  (void)column_count;
  LsgColumnDirectAddress out = { LSG_COLUMN_ADDRESS_NOT_DIRECT, 0 };
  return out; /* SEED: never recognizes `#N` */
}

char *
lsg_column_generic_name (guint32 index)
{
  (void)index;
  return g_strdup (""); /* SEED: no name */
}

gboolean
lsg_column_label_matches (const char *query, LsgColumnLabelCandidate candidate)
{
  (void)query;
  (void)candidate;
  return FALSE; /* SEED: matches nothing */
}

LsgColumnMatchAccumulation
lsg_column_match_initial (void)
{
  LsgColumnMatchAccumulation acc = { { 0 }, 0, FALSE };
  return acc; /* real: the empty accumulator */
}

gboolean
lsg_column_match_stop (LsgColumnMatchAccumulation acc)
{
  (void)acc;
  return FALSE; /* SEED: never stops (real: acc.overflow) */
}

LsgColumnMatchAccumulation
lsg_column_match_accumulate (LsgColumnMatchAccumulation acc, const char *query,
                             const LsgColumnLabelCandidate *batch,
                             guint batch_len)
{
  (void)query;
  (void)batch;
  (void)batch_len;
  return acc; /* SEED: never folds a match */
}

LsgColumnUserSettings
lsg_column_user_settings_default (void)
{
  LsgColumnUserSettings s;
  memset (&s, 0, sizeof s); /* real: all-Auto (zeroed format == auto) */
  return s;
}

gboolean
lsg_column_user_settings_is_default (const LsgColumnUserSettings *settings)
{
  (void)settings;
  return FALSE; /* SEED: never reports default */
}

LsgColumnReopenDecision
lsg_column_reopen_decide (LsgColumnReopenChange change, guint32 old_count,
                          guint32 new_count,
                          const LsgColumnHeaderIdentity *old_headers,
                          guint n_old_headers,
                          const LsgColumnHeaderIdentity *new_headers,
                          guint n_new_headers)
{
  (void)change;
  (void)old_count;
  (void)new_count;
  (void)old_headers;
  (void)n_old_headers;
  (void)new_headers;
  (void)n_new_headers;
  return LSG_COLUMN_REOPEN_RESET; /* SEED: never replays */
}

/* ========================================================================= */
/* THE COLUMN CORE BRIDGE (SEED: error / empty; touches no core)             */
/* ========================================================================= */

ls_column_type
lsg_column_override_type (ls_column_type_kind kind,
                          ls_column_datetime_semantics semantics)
{
  (void)kind;
  (void)semantics;
  ls_column_type t;
  memset (&t, 0, sizeof t); /* SEED: not a valid descriptor (struct_size 0) */
  return t;
}

ls_column_result
lsg_document_column_metadata_get_many (const LsgDocument *doc,
                                       const guint32 *ids, guint32 count,
                                       ls_column_metadata *out_items,
                                       guint32 capacity,
                                       guint64 *out_generation)
{
  (void)doc;
  (void)ids;
  (void)count;
  (void)out_items;
  (void)capacity;
  (void)out_generation;
  return LS_COLUMN_INVALID_ARGUMENT; /* SEED */
}

ls_column_result
lsg_document_column_metadata_poll (const LsgDocument *doc,
                                   ls_column_inference_status *out_status)
{
  (void)doc;
  (void)out_status;
  return LS_COLUMN_INVALID_ARGUMENT; /* SEED */
}

ls_column_result
lsg_document_column_inference_request (LsgDocument *doc, const guint32 *ids,
                                       guint32 count)
{
  (void)doc;
  (void)ids;
  (void)count;
  return LS_COLUMN_INVALID_ARGUMENT; /* SEED */
}

void
lsg_document_column_inference_cancel (LsgDocument *doc)
{
  (void)doc; /* SEED: no-op */
}

ls_column_result
lsg_document_column_inference_accept_proposal (LsgDocument *doc,
                                               guint32 column)
{
  (void)doc;
  (void)column;
  return LS_COLUMN_INVALID_ARGUMENT; /* SEED */
}

ls_column_result
lsg_document_column_override_set (LsgDocument *doc, guint32 column,
                                  const ls_column_type *type)
{
  (void)doc;
  (void)column;
  (void)type;
  return LS_COLUMN_INVALID_ARGUMENT; /* SEED */
}

ls_column_result
lsg_document_column_override_clear (LsgDocument *doc, guint32 column)
{
  (void)doc;
  (void)column;
  return LS_COLUMN_INVALID_ARGUMENT; /* SEED */
}

ls_column_result
lsg_document_column_null_sentinel_set (LsgDocument *doc, guint32 column,
                                       const guint8 *bytes, gsize len)
{
  (void)doc;
  (void)column;
  (void)bytes;
  (void)len;
  return LS_COLUMN_INVALID_ARGUMENT; /* SEED */
}

ls_column_result
lsg_document_column_null_sentinel_clear (LsgDocument *doc, guint32 column)
{
  (void)doc;
  (void)column;
  return LS_COLUMN_INVALID_ARGUMENT; /* SEED */
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

LsgColumnBytes
lsg_document_column_null_sentinel_copy (const LsgDocument *doc, guint32 column)
{
  (void)doc;
  (void)column;
  LsgColumnBytes out = { FALSE, NULL, 0 };
  return out; /* SEED: no sentinel */
}

LsgColumnBytes
lsg_document_column_conflict_example_copy (const LsgDocument *doc,
                                           guint32 column)
{
  (void)doc;
  (void)column;
  LsgColumnBytes out = { FALSE, NULL, 0 };
  return out; /* SEED: no example */
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
  (void)doc;
  (void)ids;
  (void)count;
  if (out_result != NULL)
    *out_result = LS_COLUMN_INVALID_ARGUMENT;
  return NULL; /* SEED: no labels */
}
