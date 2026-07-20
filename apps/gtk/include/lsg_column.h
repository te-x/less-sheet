/*
 * lsg_column.h — the GTK frontend's COLUMN CONFIGURATION feature (slice
 * "settings + dialect override"). Two layers, mirroring the established GTK
 * split (as in <lsg_find.h> / <lsg_filter.h>):
 *
 *   1. A PURE, display-free column VIEW-MODEL — the C analog of the macOS
 *      `ColumnDiscovery` (`ColumnDiscoveryRouting`) + `ColumnLabelSearch`
 *      (`ColumnLabelSearching`) + `GenericColumnName` + `ColumnSessionModel`
 *      (`ColumnSessionModeling`). It NEVER touches the core or a widget: it
 *      routes discovery by column count, resolves `#N` / label-substring
 *      matches (with the generic-name fallback) under a bounded
 * retain+overflow accumulation, and decides whether user column settings
 * replay ordinally or reset across a dialect re-open.
 *
 *   2. The COLUMN CORE BRIDGE over the real core — the C analog of the macOS
 *      `CoreDocumentSession+Columns`: the SINGLE place this frontend calls
 *      `ls_column_*`. These `lsg_document_column_*` functions extend the
 *      document session frozen in <lsg_document.h> (which stays frozen — the
 *      surface grows per slice) and so take an `LsgDocument *`. They wrap the
 *      ABI's fixed-layout snapshots (passed through directly — they are
 * already caller-owned + window-independent) and marshal the two-pass
 * variable- length copies (labels / sentinel / conflict example) into OWNED
 * buffers, copying every borrowed byte out immediately.
 *
 * THE FRONTEND OWNS NO TYPE INFERENCE. Every per-column type / conflict /
 * proposal / null-policy verdict comes from the core (`ls_column_*`); this
 * module only requests inference for the DISPLAYED columns, reads the
 * metadata, applies user overrides/sentinels, and drives presentation. Display
 * FORMATTING of a typed cell lives in <lsg_formatter.h> (`lsg_format_cell`).
 *
 * O(visible) BY CONSTRUCTION (N2 / decision D — no list virtualization). The
 * discovery mode itself caps the visible list at <= LSG_COLUMN_FULL_LIST_MAX
 * rows for ANY column count, and the label search retains at most
 * LSG_COLUMN_RESULT_MAX matches (+ an overflow bit) scanning bounded batches
 * of LSG_COLUMN_LABEL_BATCH_MAX candidates — so on a 100k-column document the
 * caller ever instantiates / requests metadata + labels + inference for
 * O(<=10) column IDs, never O(column_count).
 *
 * Contract role (frozen; the prototypes/structs ARE the signatures — compiled
 * with -Werror so any drift against a stub/caller fails compilation). Symbols
 * are namespaced `lsg_` / `Lsg` / `LSG_` so they never collide with the core's
 * frozen `ls_` / `LS_` ABI in <lesssheet.h>, which this header builds ON. The
 * ABI's fixed-layout column snapshots (`ls_column_metadata`, `ls_column_type`,
 * `ls_column_inference_status`) and enums are REUSED directly (they are
 * already caller-owned plain values), never mirrored — ARCH decision C's
 * "fewer types".
 *
 * OWNERSHIP: the view-model types (`LsgColumnMatchAccumulation`,
 * `LsgColumnUserSettings`, `LsgColumnHeaderIdentity`,
 * `LsgColumnLabelCandidate`, `LsgColumnDirectAddress`) are PLAIN VALUES with
 * no owned heap; `LsgColumnHeaderIdentity` / `LsgColumnLabelCandidate` BORROW
 * caller-owned bytes for the pure call's duration only. The BRIDGE copy
 * results
 * (`lsg_column_generic_name`, `LsgColumnLabel[]`, `LsgColumnBytes`) OWN heap —
 * free with the named free/clear calls (all g_free-based; NULL-safe).
 *
 * THREADING (mirrors <lsg_document.h>): the pure `lsg_column_*` transforms are
 * pure (any thread). The bridge `lsg_document_column_*` calls sit on the
 * core's POLL/CONTROL lane (internally synchronized; safe from any thread, but
 * not concurrently with `lsg_document_close` — the frontend stops polling
 * before close); none takes the window-lane lock.
 */
#ifndef LSG_COLUMN_H
#define LSG_COLUMN_H

#include <glib.h>
#include <lesssheet.h>
#include <lsg_document.h> /* LsgDocument, lsg_utf8_sanitize_dup (display sanitize) */
#include <lsg_formatter.h> /* LsgColumnFormatOptions (a user setting) */

G_BEGIN_DECLS

/* ========================================================================= */
/* PURE VIEW-MODEL                                                           */
/* ========================================================================= */

/* ---- Discovery mode (F9) ------------------------------------------------ */

/* The greatest logical column count that still shows the full, unfiltered,
 * source-order list (no search field). Above it, discovery is search-only. The
 * single named threshold that resolves the mode (single source of truth, N5).
 */
#define LSG_COLUMN_FULL_LIST_MAX (10)

/* The most ordinary label results discovery ever retains (in source order); an
 * (max+1)-th match sets the overflow bit ("More matches — refine your search")
 * and stops the scan. One named knob (N5). */
#define LSG_COLUMN_RESULT_MAX (10)

/* The maximum candidates a single label-search batch scans (F10: "label
 * batches of at most 1024"). The caller chunks its
 * `ls_column_labels_copy_many` reads into batches of at most this and folds
 * each with `lsg_column_match_accumulate`. One named knob (N5). */
#define LSG_COLUMN_LABEL_BATCH_MAX (1024)

/* What the Columns page's discovery area shows, as a pure function of the
 * logical column count (F9). */
typedef enum
{
  LSG_COLUMN_DISCOVERY_EMPTY
  = 0, /* 0 columns: empty state; no rows/requests */
  LSG_COLUMN_DISCOVERY_FULL_LIST
  = 1, /* 1..LSG_COLUMN_FULL_LIST_MAX: the whole list */
  LSG_COLUMN_DISCOVERY_SEARCH_ONLY
  = 2 /* > max: no list — search + `#N` only */
} LsgColumnDiscoveryMode;

/* The discovery mode for `column_count` (0 -> EMPTY, 1..FULL_LIST_MAX ->
 * FULL_LIST, else SEARCH_ONLY). */
LsgColumnDiscoveryMode lsg_column_discovery_mode (guint32 column_count);

/* ---- `#N` direct address (F10) ------------------------------------------ */

/* The resolution kind of a discovery query. */
typedef enum
{
  LSG_COLUMN_ADDRESS_NOT_DIRECT
  = 0, /* not a `#`-query: hand to label search */
  LSG_COLUMN_ADDRESS_RESOLVED
  = 1, /* a valid `#N`: `column` is the 0-based index */
  LSG_COLUMN_ADDRESS_NO_SUCH_COLUMN
  = 2 /* a `#`-query that is not a valid address */
} LsgColumnDirectAddressKind;

/* The resolution of a discovery query. A PLAIN VALUE; `column` is meaningful
 * only when `kind == LSG_COLUMN_ADDRESS_RESOLVED`. */
typedef struct
{
  LsgColumnDirectAddressKind kind;
  guint32 column; /* 0-based, valid iff RESOLVED */
} LsgColumnDirectAddress;

/*
 * Resolve a `#N` direct-address query (the C analog of
 * `resolveDirectAddress`), layered BEFORE the label search:
 *   - `query` does NOT begin with '#' (incl. NULL/empty, or a leading space
 *     " #5") -> NOT_DIRECT (an ordinary label query for `lsg_column_label_*`);
 *   - otherwise the entire remainder after '#' must be [1-9][0-9]* (ASCII
 *     digits, no leading zero, no sign, no whitespace, no non-ASCII digit) and
 *     parse WITHOUT overflow to n with 1 <= n <= `column_count` -> RESOLVED,
 *     `column` = n - 1;
 *   - every other '#'-prefixed value ("#", "#0", "#01", "#5 ", "#+5", a non-
 *     ASCII digit, an overflowing digit run, or n > column_count) ->
 *     NO_SUCH_COLUMN.
 */
LsgColumnDirectAddress
lsg_column_resolve_direct_address (const char *query, guint32 column_count);

/* ---- Generic column names + label search (F10) -------------------------- */

/*
 * The generic spreadsheet name of the 0-based column `index`: "A".."Z", "AA",
 * "AB", … — 0-based bijective base-26 over A–Z (25 -> "Z", 26 -> "AA",
 * 701 -> "ZZ", 702 -> "AAA"). Returned as a fresh OWNED, NUL-terminated ASCII
 * string (free with g_free). The C analog of `GenericColumnName.name(at:)`.
 */
char *lsg_column_generic_name (guint32 index);

/*
 * One column's label-search candidate (the C analog of
 * `ColumnLabelCandidate`). `label` is BORROWED (caller-owned, NUL-terminated
 * UTF-8) and is the column's effective header label, or NULL / "" when the
 * column is headerless / has an empty header — in which case the searchable
 * text is the generic name + the 1-based index, e.g. column 26 -> "AA 27".
 */
typedef struct
{
  guint32 column;
  const char *label; /* BORROWED; NULL/"" => generic-name fallback */
} LsgColumnLabelCandidate;

/*
 * Whether `candidate` matches `query` (the C analog of
 * `ColumnLabelSearching.matches` for one candidate): a case-insensitive
 * (Unicode-casefold) substring of the candidate's SEARCHABLE text — its label
 * when present/non-empty, else `lsg_column_generic_name(column)` + " " +
 * (column + 1). An empty/NULL `query` matches NOTHING (the page shows its
 * unsearched list). Pure; the frontend never sees label bytes it did not
 * request.
 */
gboolean lsg_column_label_matches (const char *query,
                                   LsgColumnLabelCandidate candidate);

/*
 * The bounded running state of a label search across batches (the C analog of
 * `ColumnMatchAccumulation`). A PLAIN VALUE: it retains at most
 * LSG_COLUMN_RESULT_MAX matching IDs (source order) plus a single overflow bit
 * — NEVER all matches — so a broad query stays O(<=10) in retained memory for
 * ANY column count.
 */
typedef struct
{
  guint32
      retained[LSG_COLUMN_RESULT_MAX]; /* first <=10 matches, source order */
  guint n_retained;                    /* 0..LSG_COLUMN_RESULT_MAX */
  gboolean overflow; /* TRUE once a (RESULT_MAX+1)-th match was seen */
} LsgColumnMatchAccumulation;

/* The empty accumulator a fresh query starts from (`n_retained` 0, no
 * overflow). */
LsgColumnMatchAccumulation lsg_column_match_initial (void);

/* Whether the caller should STOP scanning further batches: TRUE exactly when
 * `overflow` is set (the (RESULT_MAX+1)-th match was found — the UI shows the
 * overflow notice and needs no more IDs). The C analog of
 * `ColumnMatchAccumulation.stop`. */
gboolean lsg_column_match_stop (LsgColumnMatchAccumulation acc);

/*
 * Fold ONE batch of at most LSG_COLUMN_LABEL_BATCH_MAX candidates into `acc`:
 * matches each candidate against `query` (via `lsg_column_label_matches`) in
 * the given SOURCE order, appending the matching IDs, retaining at most
 * LSG_COLUMN_RESULT_MAX, and setting `overflow` once the total matches seen
 * would exceed LSG_COLUMN_RESULT_MAX. Once `overflow` is set, `retained` is
 * frozen at the first LSG_COLUMN_RESULT_MAX IDs and the fold is a no-op (so
 * the caller stops on `lsg_column_match_stop`). Exactly LSG_COLUMN_RESULT_MAX
 * matches is NOT overflow. Composes `matches` + `accumulate` from the macOS
 * split into one pure fold. `batch` may be NULL only when `batch_len` is 0.
 */
LsgColumnMatchAccumulation
lsg_column_match_accumulate (LsgColumnMatchAccumulation acc, const char *query,
                             const LsgColumnLabelCandidate *batch,
                             guint batch_len);

/* ---- Per-session column settings + the re-open decision (F7) ------------ */

/*
 * One column's decoded header identity for the re-open mapping (the C analog
 * of `ColumnHeaderIdentity`). `bytes` is BORROWED (caller-owned; the DECODED
 * source header bytes, NOT display-sanitized, so two distinct labels never
 * compare equal). A present-but-empty header is `len` 0; a WHOLE headerless
 * side is signalled by a NULL identity array to `lsg_column_reopen_decide`.
 */
typedef struct
{
  const guint8 *bytes; /* BORROWED decoded header bytes */
  gsize len;
  gboolean
      truncated; /* the label was display-capped (LS_COLUMN_LABEL_TRUNCATED) */
} LsgColumnHeaderIdentity;

/* The kind of dialect re-open, for the replay-vs-reset decision. */
typedef enum
{
  LSG_COLUMN_REOPEN_HEADER_ONLY
  = 0, /* only the header on/off decision changed */
  LSG_COLUMN_REOPEN_SEPARATOR_QUOTE_ENCODING
  = 1 /* a separator/quote/encoding change */
} LsgColumnReopenChange;

/* The mapping decision for user column settings across a re-open. */
typedef enum
{
  LSG_COLUMN_REOPEN_REPLAY
  = 0, /* SAFE: replay the settings ordinally onto the new doc */
  LSG_COLUMN_REOPEN_RESET
  = 1 /* UNSAFE: reset all column settings (and toast) */
} LsgColumnReopenDecision;

/*
 * The user-authored settings for one column — the ONLY things replayed across
 * a dialect re-open (the C analog of `ColumnUserSettings`). A PLAIN VALUE (no
 * owned heap): the null sentinel is held INLINE, bounded by the ABI's
 * LS_COLUMN_SENTINEL_MAX_BYTES. Inference, conflicts, proposals, automatic
 * widths, active jobs, and generations are NEVER part of it.
 *   has_override / override   — the explicit session type (a valid override
 *                               descriptor, e.g. from
 * `lsg_column_override_type`); `has_override` FALSE == Auto. has_null_sentinel
 * — FALSE == no sentinel; TRUE with `null_sentinel_len` 0 == the empty
 * sentinel. null_sentinel / _len      — the sentinel bytes
 * (0..LS_COLUMN_SENTINEL_MAX_BYTES). format                    — the display
 * format options (<lsg_formatter.h>). hidden                    — visibility.
 *   has_manual_width / width  — a manual column width (`has_manual_width`
 * FALSE
 *                               == auto width).
 */
typedef struct
{
  gboolean has_override;
  ls_column_type override; /* valid iff has_override */
  gboolean has_null_sentinel;
  guint8 null_sentinel[LS_COLUMN_SENTINEL_MAX_BYTES];
  gsize null_sentinel_len;
  LsgColumnFormatOptions format;
  gboolean hidden;
  gboolean has_manual_width;
  gdouble manual_width;
} LsgColumnUserSettings;

/* The default (Auto) settings for one column: no override, no sentinel, Auto
 * format, visible, auto width. The value the frontend resets a column to on a
 * RESET decision or a fresh open. The C analog of
 * `ColumnUserSettings.default`.
 */
LsgColumnUserSettings lsg_column_user_settings_default (void);

/* TRUE iff `settings` carries NO user-authored setting (pure Auto) — the C
 * analog of `ColumnUserSettings.isDefault`. */
gboolean
lsg_column_user_settings_is_default (const LsgColumnUserSettings *settings);

/*
 * The replay-vs-reset decision for a dialect re-open (the C analog of
 * `ColumnSessionModeling.decide`). Before a re-open the frontend snapshots the
 * per-column `LsgColumnUserSettings`; after it, this decides how they map:
 *   - HEADER_ONLY -> REPLAY iff `old_count == new_count`, else RESET;
 *   - SEPARATOR_QUOTE_ENCODING -> REPLAY iff `old_count == new_count` AND both
 *     sides HAVE a header (`old_headers` and `new_headers` both non-NULL) AND
 *     `n_old_headers == old_count` AND `n_new_headers == new_count` AND no
 *     identity on either side is `truncated` AND the ordered decoded header
 *     identities are byte-identical (same `len` + same bytes, per ordinal),
 *     else RESET.
 * A headerless side (a NULL identity array) on a SEPARATOR_QUOTE_ENCODING
 * change is NEVER safe (RESET); a count mismatch, reorder, rename, or
 * truncation is RESET. On REPLAY the frontend re-applies overrides + null
 * sentinels via the bridge (format / visibility / width are replayed as
 * frontend state); on RESET it resets every column to
 * `lsg_column_user_settings_default` and raises the reset toast.
 */
LsgColumnReopenDecision lsg_column_reopen_decide (
    LsgColumnReopenChange change, guint32 old_count, guint32 new_count,
    const LsgColumnHeaderIdentity *old_headers, guint n_old_headers,
    const LsgColumnHeaderIdentity *new_headers, guint n_new_headers);

/* ========================================================================= */
/* THE COLUMN CORE BRIDGE (over the real core; extends <lsg_document.h>)     */
/* ========================================================================= */

/*
 * Build a VALID override type descriptor for
 * `lsg_document_column_override_set` (a pure helper; no core). Fills a
 * canonical `ls_column_type` (struct_size / abi_version set; flags + reserved
 * zero; decimal_precision / decimal_scale / datetime_fraction_digits at their
 * UNSPECIFIED sentinels) with `kind` and, for a DATETIME kind, `semantics`
 * (NAIVE or ZONED); `semantics` is ignored (forced to LS_COLUMN_DATETIME_NONE)
 * for every non-datetime kind. `kind` must be an explicit v1 kind
 * (TEXT/BOOLEAN/INTEGER/DECIMAL/DATE/DATETIME); the core rejects
 * UNKNOWN/UNSUPPORTED and a datetime with NONE semantics.
 */
ls_column_type
lsg_column_override_type (ls_column_type_kind kind,
                          ls_column_datetime_semantics semantics);

/*
 * Read metadata for `ids[0..count]` into `out_items[0..count]` in caller order
 * and write the read generation to `*out_generation` (mirrors
 * `ls_column_metadata_get_many`). The wrapper PRE-SETS each out item's
 * struct_size / abi_version to the v1 values, so the caller need not know the
 * ABI sizes. `count` / `capacity` at most LS_COLUMN_BATCH_MAX, capacity >=
 * count, every ID below `lsg_document_column_count`; a zero-length batch is a
 * valid no-op that still writes `*out_generation`. On success the caller owns
 * the items permanently (window-independent). Poll/control lane; ZERO
 * allocation. Returns the ABI result (LS_COLUMN_OK on success).
 */
ls_column_result lsg_document_column_metadata_get_many (
    const LsgDocument *doc, const guint32 *ids, guint32 count,
    ls_column_metadata *out_items, guint32 capacity, guint64 *out_generation);

/*
 * Write the coherent inference-job + global-generation snapshot into
 * `*out_status` (mirrors `ls_column_metadata_poll`). The wrapper pre-sets
 * `out_status`'s struct_size / abi_version. Poll/control lane; ZERO
 * allocation; never blocks. Returns the ABI result.
 */
ls_column_result
lsg_document_column_metadata_poll (const LsgDocument *doc,
                                   ls_column_inference_status *out_status);

/*
 * Replace the desired active inference ID set with `ids[0..count]` (mirrors
 * `ls_column_inference_request`) — request inference ONLY for the displayed
 * columns (O(visible), N2). `count` must be 1..LS_COLUMN_BATCH_MAX and every
 * ID below `lsg_document_column_count`. Poll/control lane; MAY allocate — on
 * OOM returns LS_COLUMN_OUT_OF_MEMORY, the prior request intact. Returns the
 * ABI result.
 */
ls_column_result lsg_document_column_inference_request (LsgDocument *doc,
                                                        const guint32 *ids,
                                                        guint32 count);

/* Cancel the current desired inference set/job (mirrors
 * `ls_column_inference_cancel`; committed metadata remains). Poll/control
 * lane; ZERO allocation; cannot fail; no-op when idle. */
void lsg_document_column_inference_cancel (LsgDocument *doc);

/*
 * Accept column `column`'s proposed inferred replacement (mirrors
 * `ls_column_inference_accept_proposal`): move the proposal into the inferred/
 * published slot, staying in Auto (no override). Returns LS_COLUMN_NO_PROPOSAL
 * without mutation when there is no proposal. Poll/control lane; ZERO
 * allocation. Returns the ABI result.
 */
ls_column_result
lsg_document_column_inference_accept_proposal (LsgDocument *doc,
                                               guint32 column);

/*
 * Set column `column`'s explicit session override to `*type` and make it
 * effective (mirrors `ls_column_override_set`). Build `*type` with
 * `lsg_column_override_type`. Poll/control lane; MAY allocate — on OOM /
 * validation failure the prior state is untouched. Returns the ABI result
 * (LS_COLUMN_INVALID_ARGUMENT for a bad descriptor).
 */
ls_column_result lsg_document_column_override_set (LsgDocument *doc,
                                                   guint32 column,
                                                   const ls_column_type *type);

/* Idempotently remove column `column`'s override (mirrors
 * `ls_column_override_clear`), revealing the inferred/declared/unknown
 * effective type. Poll/control lane; ZERO allocation. Returns the ABI result.
 */
ls_column_result lsg_document_column_override_clear (LsgDocument *doc,
                                                     guint32 column);

/*
 * Set column `column`'s null sentinel to `bytes[0..len]` (mirrors
 * `ls_column_null_sentinel_set`). `len` is 0..LS_COLUMN_SENTINEL_MAX_BYTES; a
 * NULL `bytes` is valid only when `len` is 0 (the empty sentinel — treat empty
 * fields as null). The bytes must be valid UTF-8. Poll/control lane; MAY
 * allocate — invalid UTF-8 / over-length / OOM leaves the old state untouched.
 * Returns the ABI result.
 */
ls_column_result lsg_document_column_null_sentinel_set (LsgDocument *doc,
                                                        guint32 column,
                                                        const guint8 *bytes,
                                                        gsize len);

/* Idempotently remove column `column`'s null sentinel (mirrors
 * `ls_column_null_sentinel_clear`). Poll/control lane; ZERO allocation.
 * Returns the ABI result. */
ls_column_result lsg_document_column_null_sentinel_clear (LsgDocument *doc,
                                                          guint32 column);

/*
 * An OWNED byte copy out of a two-pass ABI value
 * (`ls_column_null_sentinel_copy` / `ls_column_conflict_example_copy`). A
 * PLAIN VALUE that OWNS `bytes`: present — FALSE when the value is absent (the
 * ABI's LS_COLUMN_NO_VALUE); bytes   — OWNED (g_free), or NULL when `!present`
 * OR when present-but-empty
 *             (`len` 0); NOT NUL-terminated (it is arbitrary bytes);
 *   len     — the byte length (0 for a present-but-empty value).
 * Free with `lsg_column_bytes_clear`. A display consumer sanitizes the bytes
 * to a string with the frozen `lsg_utf8_sanitize_dup(bytes, len)`.
 */
typedef struct
{
  gboolean present;
  guint8 *bytes; /* OWNED (g_free); NULL when !present or empty */
  gsize len;
} LsgColumnBytes;

/* Free an `LsgColumnBytes`'s owned bytes and zero it. NULL-safe. */
void lsg_column_bytes_clear (LsgColumnBytes *b);

/*
 * Copy column `column`'s null sentinel out (mirrors the two-pass
 * `ls_column_null_sentinel_copy`): `{present TRUE, len N}` for a set sentinel
 * (`bytes` NULL iff N == 0), `{present FALSE}` when no sentinel is set. The
 * bytes are compared BYTE-EXACT by the core, so they are copied verbatim (not
 * display-sanitized). Poll/control lane; the caller owns the result. See
 * `lsg_column_bytes_clear`.
 */
LsgColumnBytes lsg_document_column_null_sentinel_copy (const LsgDocument *doc,
                                                       guint32 column);

/*
 * Copy column `column`'s bounded conflict-example prefix out (mirrors the two-
 * pass `ls_column_conflict_example_copy`; the value identified by
 * `ls_column_metadata.conflict_example_bytes`): `{present TRUE, len N}` for an
 * example, `{present FALSE}` when there is none. A display-only value — the
 * caller sanitizes it with `lsg_utf8_sanitize_dup`. Poll/control lane; the
 * caller owns the result.
 */
LsgColumnBytes
lsg_document_column_conflict_example_copy (const LsgDocument *doc,
                                           guint32 column);

/*
 * One column's copied header label (dual-use: the discovery/search DISPLAY and
 * the re-open header IDENTITY). OWNS `bytes`:
 *   present   — a source header label exists (LS_COLUMN_LABEL_PRESENT);
 *   truncated — it was display-capped (LS_COLUMN_LABEL_TRUNCATED);
 *   bytes     — OWNED (g_free); the DECODED label bytes (NOT sanitized), NULL
 *               when `!present`; NOT NUL-terminated;
 *   len       — the byte length (0 when `!present` or an empty label).
 * A display consumer builds a string with `lsg_utf8_sanitize_dup(bytes, len)`
 * (and applies the generic-name fallback when `!present`); the re-open
 * decision builds an `LsgColumnHeaderIdentity{bytes, len, truncated}`
 * directly.
 */
typedef struct
{
  guint32 column;
  gboolean present;
  gboolean truncated;
  guint8 *bytes; /* OWNED (g_free); NULL when !present */
  gsize len;
} LsgColumnLabel;

/*
 * Copy the source header labels for `ids[0..count]` (mirrors the two-pass
 * `ls_column_labels_copy_many`, running BOTH passes internally). Returns a
 * fresh OWNED array of `count` `LsgColumnLabel` in requested order (free with
 * `lsg_column_labels_free`), each carrying its copied label bytes; or NULL and
 * sets `*out_result` to the ABI failure code. `count` at most
 * LS_COLUMN_BATCH_MAX, every ID below `lsg_document_column_count`. A
 * zero-length batch returns a non-NULL empty (zero-length) array with
 * LS_COLUMN_OK. Poll/control lane; the caller owns the result
 * (window-independent). `out_result` may be NULL.
 */
LsgColumnLabel *
lsg_document_column_labels_copy_many (const LsgDocument *doc,
                                      const guint32 *ids, guint32 count,
                                      ls_column_result *out_result);

/* Free a `LsgColumnLabel` array (each `bytes` + the array). NULL-safe;
 * `count` must be the count passed to the copy call. */
void lsg_column_labels_free (LsgColumnLabel *labels, guint32 count);

G_END_DECLS

#endif /* LSG_COLUMN_H */
