/*
 * lsg_document_internal.h — PRIVATE (non-frozen) cross-module seam inside
 * src/.
 *
 * The public frozen surface (include/lsg_document.h) keeps `LsgDocument`
 * opaque, so no other module can construct one. A completed NETWORK open,
 * however, produces an already-open core `ls_doc *` (from
 * `ls_net_open_status.doc`) that must be adopted into a normal `LsgDocument` —
 * the same type a local open returns (see lsg_net_open.h's
 * `lsg_net_open_adopt_document`). This header is the single internal entry
 * point that lets lsg_net_open.c hand that core handle to lsg_document.c's
 * constructor without widening the frozen ABI.
 *
 * It lives under src/ (an implementation path), is not part of the contract,
 * and is included only by the two module sources.
 */
#ifndef LSG_DOCUMENT_INTERNAL_H
#define LSG_DOCUMENT_INTERNAL_H

#include <lsg_document.h>
#include <lsg_find.h> /* LsgSearchRequest — shared by the find + filter bridges */
#include <string.h>

G_BEGIN_DECLS

/*
 * The document session's private layout. It lives here, not in lsg_document.c,
 * so the sibling bridges that also call the core over an `LsgDocument` (find,
 * filter, jump, copy, column) can reach the core handle and the lane locks
 * without widening the public surface — <lsg_document.h> keeps `LsgDocument`
 * opaque.
 *
 * The locks are heap-allocated `GMutex *` so the `const`-qualified poll
 * accessors can lock through a `const LsgDocument *`: locking mutates the
 * pointee, not the const field.
 */
struct _LsgDocument
{
  ls_doc *doc;
  GMutex *window_lock;  /* window lane: set_window, header/cell reads,
                           match-flags */
  GMutex *control_lock; /* reserved for the control lane (copy/find/filter
                           workers) */
};

/*
 * Wrap an already-open core `core_doc` in a fresh OWNED `LsgDocument`
 * (identical to a locally-opened one: same two-lane locks, same accessors,
 * same `lsg_document_close` lifecycle). Takes ownership of `core_doc` —
 * closing the returned document `ls_close`s it. `core_doc` must be non-NULL.
 */
LsgDocument *lsg_document_adopt (ls_doc *core_doc);

/*
 * Marshal the shared `LsgSearchRequest` into the ABI's `ls_search_request` —
 * the SINGLE place the find bridge (`ls_search_start`) and the filter bridge
 * (`ls_filter_set`) build it, so the two can never drift. The `value` and
 * `scope` buffers are borrowed only for the enclosing core call. `static
 * inline` so an including TU that does not use it draws no warning.
 */
static inline ls_search_request
lsg_build_abi_request (LsgSearchRequest request)
{
  ls_search_request req;
  req.value_ptr = (const uint8_t *)request.value;
  req.value_len = (request.value != NULL) ? strlen (request.value) : 0;
  /* The case flag is marshaled at this one choke point, so find, filter,
   * navigation and the highlight mask all inherit it identically. */
  req.case_sensitive = request.case_sensitive;

  if (request.kind == LSG_FIND_TEXT)
    {
      req.kind = LS_SEARCH_TEXT;
      req.op = LS_SEARCH_OP_EQ;      /* ignored for TEXT */
      req.column = 0;                /* ignored for TEXT */
      req.scope_ptr = request.scope; /* NULL means ALL columns */
      req.scope_len = request.scope_len;
    }
  else
    {
      req.kind = LS_SEARCH_PREDICATE;
      req.op = (ls_search_op)
                   request.op; /* LsgSearchOp is pinned to ls_search_op */
      req.column = request.column;
      req.scope_ptr = NULL; /* ignored for PREDICATE */
      req.scope_len = 0;
    }
  return req;
}

G_END_DECLS

#endif /* LSG_DOCUMENT_INTERNAL_H */
