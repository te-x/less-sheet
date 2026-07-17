/*
 * lsg_net_open.h — the GTK frontend's NETWORK OPEN drive + progress reducer
 * (slice 1: open a CSV / .csv.gz over HTTP(S)). The C analog of the macOS
 * `DocumentSessionOpening.openURL` drive plus the `NetworkOpenState` /
 * `NetworkOpenError` / `NetworkOpenProgress` reducer types.
 *
 * A network open is never instant, so it mirrors the core's async-job idiom
 * (`ls_open_url_start` -> `ls_net_open_poll` -> `ls_net_open_release`). This
 * module wraps that lifecycle and folds each raw poll snapshot into an owned,
 * C-free `LsgNetProgress` the frontend paints into its always-visible banner
 * (the <500 ms cold-start budget does NOT apply to a network open — see the ABI
 * NETWORK SOURCE EXTENSION). On DONE the produced `ls_doc` is adopted into a
 * normal `LsgDocument` (see <lsg_document.h>), thereafter identical to a local
 * document through every viewer accessor.
 *
 * GATE COVERAGE (honest): the pure mappers + reducer
 * (`lsg_net_state_from_abi` / `lsg_net_error_from_abi` /
 * `lsg_net_progress_from_status`) are fully unit-pinned over synthetic ABI
 * snapshots, and the SYNCHRONOUS scheme-rejection path
 * (`lsg_net_open_start` on a non-http/https URL -> FAILED / INVALID_ARGUMENT,
 * touching no network) is pinned through the real ABI. A REAL successful fetch
 * over the wire (TLS, a live host) is NOT reachable in the sealed container
 * gate (the core's fake transport is a Zig-internal test seam, not a C-ABI
 * entry point) and is the author's human GUI pass (ARCH H5).
 *
 * THREADING: the drive is on the poll/control lane — `_poll` / `_cancel` /
 * `_adopt_document` / `_release` are safe from any thread, but do not race two
 * control calls on the SAME job, and do not use a job after `_release`.
 */
#ifndef LSG_NET_OPEN_H
#define LSG_NET_OPEN_H

#include <glib.h>
#include <lesssheet.h>
#include <lsg_document.h>

G_BEGIN_DECLS

/* The async open-job state, mirroring `ls_net_open_state` 1:1. */
typedef enum {
  LSG_NET_PENDING = 0,   /* LS_NET_OPEN_PENDING — probing range support */
  LSG_NET_FETCHING = 1,  /* LS_NET_OPEN_FETCHING — head / sequential fetch in flight */
  LSG_NET_DONE = 2,      /* LS_NET_OPEN_DONE — the document is open (terminal) */
  LSG_NET_FAILED = 3,    /* LS_NET_OPEN_FAILED — see the error (terminal) */
  LSG_NET_CANCELLED = 4, /* LS_NET_OPEN_CANCELLED — cancelled before DONE (terminal) */
} LsgNetState;

/* Map a raw `ls_net_open_state` value; an unrecognized code maps to
 * LSG_NET_FAILED (mirrors the macOS `?? .failed` fallback). */
LsgNetState lsg_net_state_from_abi (gint32 abi_state);

/* Whether a state is terminal (polling can stop): DONE / FAILED / CANCELLED. */
gboolean lsg_net_state_is_terminal (LsgNetState state);

/* Network-open outcome, mirroring `ls_net_status` 1:1 (with an explicit OK).
 * A materially different taxonomy from local-file `LsgOpenError` — kept
 * separate exactly as the ABI keeps `ls_net_status` distinct from `ls_status`. */
typedef enum {
  LSG_NET_OK = 0,                        /* LS_NET_OK — no error */
  LSG_NET_ERROR_INVALID_ARGUMENT = 1,    /* bad scheme / URL / option (rejected synchronously) */
  LSG_NET_ERROR_UNREACHABLE = 2,         /* DNS / TCP / TLS connection failure */
  LSG_NET_ERROR_TIMEOUT = 3,             /* no forward progress within the timeout */
  LSG_NET_ERROR_HTTP_STATUS = 4,         /* non-2xx (http_status carries the code) */
  LSG_NET_ERROR_TOO_MANY_REDIRECTS = 5,  /* redirect chain exceeded the cap */
  LSG_NET_ERROR_IO = 6,                  /* local spool-file failure */
  LSG_NET_ERROR_CANCELLED = 7,           /* cancelled before DONE */
} LsgNetError;

/* Map a raw `ls_net_status` value; 0 -> LSG_NET_OK, 1..7 -> the codes above.
 * An unrecognized code maps to LSG_NET_OK (mirrors the macOS `nil` for an
 * unknown/absent error; the reducer only reads the error when state==FAILED). */
LsgNetError lsg_net_error_from_abi (gint32 abi_error);

/*
 * One network-open progress snapshot (mirrors `ls_net_open_status`, minus the
 * core-owned `doc` pointer the drive consumes internally). `has_fraction` is
 * false when the ABI reports LS_NET_PROGRESS_UNKNOWN (-1.0) — the UI then shows
 * an indeterminate spinner plus the live `bytes_fetched` counter. `error` /
 * `http_status` are meaningful only when `state == LSG_NET_FAILED`.
 */
typedef struct {
  LsgNetState state;
  gboolean has_fraction;
  gdouble fraction;       /* valid iff has_fraction; in [0.0, 1.0] */
  guint64 bytes_fetched;
  guint64 bytes_total;    /* 0 when unknown */
  LsgNetError error;
  gint32 http_status;     /* valid iff error == LSG_NET_ERROR_HTTP_STATUS */
} LsgNetProgress;

/* PURE reducer: fold a raw `ls_net_open_status` (non-NULL) into an
 * `LsgNetProgress`. Maps `progress < 0` -> has_fraction false. */
LsgNetProgress lsg_net_progress_from_status (const ls_net_open_status *status);

/* Opaque drive handle wrapping one `ls_net_open_job`. */
typedef struct _LsgNetOpen LsgNetOpen;

/*
 * Start an asynchronous open of the CSV / .csv.gz at `url` (NUL-terminated),
 * forcing `options` (NULL = defaults, exactly like `ls_open_url_start`).
 * Returns a drive handle immediately, or NULL only if the handle itself could
 * not be allocated. A bad scheme / malformed URL / out-of-domain option is NOT
 * a NULL return — it is a valid handle that immediately polls
 * LSG_NET_FAILED / LSG_NET_ERROR_INVALID_ARGUMENT, touching no network. The
 * caller MUST eventually `lsg_net_open_release` the handle.
 */
LsgNetOpen *lsg_net_open_start (const char *url, const ls_open_options *options);

/* Fold the job's current `ls_net_open_poll` snapshot into an `LsgNetProgress`.
 * Never blocks; safe from any thread. */
LsgNetProgress lsg_net_open_poll (LsgNetOpen *job);

/* Request cancellation of an in-flight open (no-op once terminal). Does not
 * block. */
void lsg_net_open_cancel (LsgNetOpen *job);

/*
 * On DONE, adopt the produced `ls_doc` into a new OWNED `LsgDocument` (the same
 * type a local open returns), returning it; the adopted document then follows
 * the normal `lsg_document_close` lifecycle, INDEPENDENT of releasing this job.
 * Returns NULL if the job is not (yet) DONE, or if it was already adopted.
 */
LsgDocument *lsg_net_open_adopt_document (LsgNetOpen *job);

/* Release the drive handle (call exactly once; invalid afterward). If still in
 * flight this first cancels and joins the fetch. Does NOT close a document
 * already adopted via `lsg_net_open_adopt_document`. NULL-safe. */
void lsg_net_open_release (LsgNetOpen *job);

G_END_DECLS

#endif /* LSG_NET_OPEN_H */
