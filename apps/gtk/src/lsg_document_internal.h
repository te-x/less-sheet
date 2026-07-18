/*
 * lsg_document_internal.h — PRIVATE (non-frozen) cross-module seam inside src/.
 *
 * The public frozen surface (include/lsg_document.h) keeps `LsgDocument` opaque,
 * so no other module can construct one. A completed NETWORK open, however,
 * produces an already-open core `ls_doc *` (from `ls_net_open_status.doc`) that
 * must be adopted into a normal `LsgDocument` — the same type a local open
 * returns (see lsg_net_open.h's `lsg_net_open_adopt_document`). This header is
 * the single internal entry point that lets lsg_net_open.c hand that core handle
 * to lsg_document.c's constructor without widening the frozen ABI.
 *
 * It lives under src/ (an implementation path), is not part of the contract, and
 * is included only by the two module sources.
 */
#ifndef LSG_DOCUMENT_INTERNAL_H
#define LSG_DOCUMENT_INTERNAL_H

#include <lsg_document.h>

G_BEGIN_DECLS

/*
 * The document session's private layout. Defined here (not in lsg_document.c) so
 * the sibling slice modules that also call the core over an `LsgDocument` — the
 * find bridge in lsg_find.c (`ls_search_*` / `ls_window_match_flags`) — can reach
 * the core handle and the window-lane lock without widening the frozen public
 * surface (<lsg_document.h> keeps `LsgDocument` opaque). The `ls_doc *doc` and
 * `window_lock` are the two members those bridges need: poll/control-lane search
 * calls are lockless (the core is internally synchronized), and the window-lane
 * `ls_window_match_flags` takes `window_lock`, exactly like a cell read.
 *
 * The heap-allocated `GMutex *` locks let the `const`-qualified poll accessors
 * lock through a `const LsgDocument *` (locking mutates the pointee, not the
 * const field).
 */
struct _LsgDocument {
  ls_doc *doc;
  GMutex *window_lock;   /* window lane: set_window, header/cell reads, match-flags */
  GMutex *control_lock;  /* reserved for the control lane (copy/find/filter workers) */
};

/*
 * Wrap an already-open core `core_doc` in a fresh OWNED `LsgDocument` (identical
 * to a locally-opened one: same two-lane locks, same accessors, same
 * `lsg_document_close` lifecycle). Takes ownership of `core_doc` — closing the
 * returned document `ls_close`s it. `core_doc` must be non-NULL.
 */
LsgDocument *lsg_document_adopt (ls_doc *core_doc);

G_END_DECLS

#endif /* LSG_DOCUMENT_INTERNAL_H */
