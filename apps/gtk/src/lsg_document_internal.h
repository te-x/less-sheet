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
 * Wrap an already-open core `core_doc` in a fresh OWNED `LsgDocument` (identical
 * to a locally-opened one: same two-lane locks, same accessors, same
 * `lsg_document_close` lifecycle). Takes ownership of `core_doc` — closing the
 * returned document `ls_close`s it. `core_doc` must be non-NULL.
 */
LsgDocument *lsg_document_adopt (ls_doc *core_doc);

G_END_DECLS

#endif /* LSG_DOCUMENT_INTERNAL_H */
