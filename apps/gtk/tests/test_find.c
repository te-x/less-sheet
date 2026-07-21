/*
 * test_find.c — RED behavior tests for the FIND module (lsg_find.h). Slice 2.
 * Display-free (glib only, no GTK). Two halves, mirroring the macOS
 * FindSeekTests:
 *
 *   PURE VIEW-MODEL — the C port of FindControl: the ABI enum/op pins, the
 *   pinned numeric grammar, the "Match case" flag marshaling (draft ->
 *   request), request composition + validation, the growing→final count state
 *   machine, landings, wrap / no-matches / stopped notices, and the next/prev
 *   navigation anchors. No core.
 *
 *   SEARCH BRIDGE — the real Zig core through lsg_document_search_* /
 *   lsg_document_window_match_flags over the find.csv fixture: case-folded text
 *   search (Match case OFF folds ASCII, ON is byte-exact) with live counts +
 *   navigation, typed predicates + validation, exact column scoping, the
 *   fresh/reopened IDLE state, and the per-visible-cell highlight MASK (the
 *   drawing of it is the author's GUI pass; the mask VALUES are gate-pinned here).
 *
 * These are RED against the seeded src/lsg_find.c (empty view-model + no-op
 * bridge) and turn GREEN as the module is implemented. Determinism: the fixture
 * is tiny (8 data rows) so match-scans complete in well under a millisecond;
 * every bridge test asserts lsg_document_search_start(...) == TRUE BEFORE any
 * poll loop, so the unimplemented seed fails FAST instead of waiting out the
 * bounded (~10 s) poll.
 *
 * find.csv data rows (header "name,qty,note" is ON):
 *   0: Widget | 2   | alpha needle      4: Gizmo | 1e2 | delta
 *   1: NEEDLE | 10  | beta              5: café  | 0.5 | CAFÉ
 *   2: needle | 2.0 | gamma             6:       | 5.  | needleneedle
 *   3: gadget | -3  | Needle point      7: plain | abc | end needle
 */
#include <glib.h>
#include <lesssheet.h>
#include <lsg_document.h>
#include <lsg_find.h>

/* ========================================================================= */
/* PURE VIEW-MODEL                                                            */
/* ========================================================================= */

/* --- ABI agreement: the frontend enums mirror ls_search_* exactly (the
 *     runtime drift guard; -Werror compilation is the signature drift guard) --- */

static void
test_abi_enum_pins (void)
{
  g_assert_cmpint (LSG_FIND_TEXT, ==, LS_SEARCH_TEXT);
  g_assert_cmpint (LSG_FIND_PREDICATE, ==, LS_SEARCH_PREDICATE);

  g_assert_cmpint (LSG_SEARCH_OP_EQ, ==, LS_SEARCH_OP_EQ);
  g_assert_cmpint (LSG_SEARCH_OP_NE, ==, LS_SEARCH_OP_NE);
  g_assert_cmpint (LSG_SEARCH_OP_LT, ==, LS_SEARCH_OP_LT);
  g_assert_cmpint (LSG_SEARCH_OP_GT, ==, LS_SEARCH_OP_GT);
  g_assert_cmpint (LSG_SEARCH_OP_LE, ==, LS_SEARCH_OP_LE);
  g_assert_cmpint (LSG_SEARCH_OP_GE, ==, LS_SEARCH_OP_GE);

  g_assert_cmpint (LSG_SEARCH_FORWARD, ==, LS_SEARCH_FORWARD);
  g_assert_cmpint (LSG_SEARCH_BACKWARD, ==, LS_SEARCH_BACKWARD);

  g_assert_cmpint (LSG_SEARCH_NAV_NONE, ==, LS_SEARCH_NAV_NONE);
  g_assert_cmpint (LSG_SEARCH_NAV_SEARCHING, ==, LS_SEARCH_NAV_SEARCHING);
  g_assert_cmpint (LSG_SEARCH_NAV_FOUND, ==, LS_SEARCH_NAV_FOUND);
  g_assert_cmpint (LSG_SEARCH_NAV_EXHAUSTED, ==, LS_SEARCH_NAV_EXHAUSTED);
}

/* --- ordering operators need a numeric value; = / != accept anything --- */

static void
test_op_ordering (void)
{
  g_assert_false (lsg_search_op_is_ordering (LSG_SEARCH_OP_EQ));
  g_assert_false (lsg_search_op_is_ordering (LSG_SEARCH_OP_NE));
  g_assert_true (lsg_search_op_is_ordering (LSG_SEARCH_OP_LT));
  g_assert_true (lsg_search_op_is_ordering (LSG_SEARCH_OP_GT));
  g_assert_true (lsg_search_op_is_ordering (LSG_SEARCH_OP_LE));
  g_assert_true (lsg_search_op_is_ordering (LSG_SEARCH_OP_GE));
}

/* --- the pinned numeric grammar (same accept/reject fixtures as the core) --- */

static void
test_numeric_grammar (void)
{
  const char *accepted[] = {
    "1", "-2", "+1e5", ".5", "5.", " 12 ", "1e5", "\t7\t",
    "-0.0", "+42", "1.5e-3", "2E+4", "0.01", "9007199254740993",
  };
  for (guint i = 0; i < G_N_ELEMENTS (accepted); i++)
    g_assert_true (lsg_numeric_is_numeric (accepted[i]));

  const char *rejected[] = {
    "", " ", "0x1F", "1,000", "1e", "e5", "--1", "1 2", "NaN", "inf",
    "\xd9\xa1\xd9\xa2", "1.2.3", ".", "+.", "5..", "abc", "1.5e", "e", "+",
  };
  for (guint i = 0; i < G_N_ELEMENTS (rejected); i++)
    g_assert_false (lsg_numeric_is_numeric (rejected[i]));

  g_assert_false (lsg_numeric_is_numeric (NULL)); /* NULL treated as empty */
}

/* --- Match case: the draft's case_sensitive marshals 1:1 into the composed
 *     request, ONE session bool shared by TEXT and WHERE, default OFF; the flag
 *     is NEVER derived from the query — smart case is retired (§6 C6, D1). --- */

static void
test_case_mode (void)
{
  guint32 all3[] = { 0, 1, 2 };

  /* Default OFF: a fresh session is case-INSENSITIVE. */
  LsgFindSession s = lsg_find_initial ();
  g_assert_false (s.draft.case_sensitive);

  /* TEXT, OFF -> request.case_sensitive FALSE, even for an uppercase query
   * (the old "uppercase => exact" smart-case auto-rule is GONE: OFF stays
   * insensitive regardless of the query bytes). */
  s.draft.mode = LSG_FIND_TEXT;
  s.draft.text = "USA";
  LsgFindSubmit textOff = lsg_find_submit (s, all3, 3, 3);
  g_assert_cmpint (textOff.outcome, ==, LSG_FIND_RUN);
  g_assert_false (textOff.request.case_sensitive);

  /* TEXT, ON -> request.case_sensitive TRUE (RED on the seed: the composer does
   * not thread the flag yet). */
  s.draft.case_sensitive = TRUE;
  LsgFindSubmit textOn = lsg_find_submit (s, all3, 3, 3);
  g_assert_cmpint (textOn.outcome, ==, LSG_FIND_RUN);
  g_assert_true (textOn.request.case_sensitive);

  /* The SAME session bool is shared by WHERE (predicate) mode — no per-mode
   * case control. ON -> TRUE, OFF -> FALSE, unchanged by the operator/value. */
  s.draft.mode = LSG_FIND_PREDICATE;
  s.draft.column = 0;
  s.draft.op = LSG_SEARCH_OP_EQ;
  s.draft.value = "isabella";
  LsgFindSubmit whereOn = lsg_find_submit (s, all3, 3, 3);
  g_assert_cmpint (whereOn.outcome, ==, LSG_FIND_RUN);
  g_assert_true (whereOn.request.case_sensitive);

  s.draft.case_sensitive = FALSE;
  LsgFindSubmit whereOff = lsg_find_submit (s, all3, 3, 3);
  g_assert_cmpint (whereOff.outcome, ==, LSG_FIND_RUN);
  g_assert_false (whereOff.request.case_sensitive);
}

/* --- initial session is empty (Match case OFF) --- */

static void
test_initial_empty (void)
{
  LsgFindSession s = lsg_find_initial ();
  g_assert_cmpint (s.draft.mode, ==, LSG_FIND_TEXT);
  g_assert_cmpstr (s.draft.text, ==, "");
  g_assert_cmpstr (s.draft.value, ==, "");
  g_assert_cmpuint (s.draft.column, ==, 0);
  g_assert_cmpint (s.draft.op, ==, LSG_SEARCH_OP_EQ);
  g_assert_false (s.draft.case_sensitive); /* default OFF = insensitive */

  g_assert_false (s.display.active);
  g_assert_false (s.display.has_current);
  g_assert_cmpuint (s.display.total, ==, 0);
  g_assert_false (s.display.total_final);
  g_assert_false (s.display.has_progress);
  g_assert_cmpint (s.display.notice, ==, LSG_FIND_NOTICE_NONE);
}

/* --- submit (Enter): text mode compose + scope derivation --- */

static void
test_submit_text_scope (void)
{
  LsgFindSession s = lsg_find_initial ();
  s.draft.mode = LSG_FIND_TEXT;
  s.draft.text = "needle";

  /* Nothing hidden (every column visible): scope nil (all columns). */
  guint32 all3[] = { 0, 1, 2 };
  LsgFindSubmit r = lsg_find_submit (s, all3, 3, 3);
  g_assert_cmpint (r.outcome, ==, LSG_FIND_RUN);
  g_assert_cmpint (r.request.kind, ==, LSG_FIND_TEXT);
  g_assert_cmpstr (r.request.value, ==, "needle");
  g_assert_null (r.request.scope);
  g_assert_cmpuint (r.request.scope_len, ==, 0);

  /* Hidden columns: the visible set is fixed into the request. */
  guint32 vis[] = { 0, 2 };
  r = lsg_find_submit (s, vis, 2, 3);
  g_assert_cmpint (r.outcome, ==, LSG_FIND_RUN);
  g_assert_nonnull (r.request.scope);
  g_assert_cmpuint (r.request.scope_len, ==, 2);
  g_assert_cmpuint (r.request.scope[0], ==, 0);
  g_assert_cmpuint (r.request.scope[1], ==, 2);

  /* The empty query means "no search" — ignored, not an error. */
  s.draft.text = "";
  r = lsg_find_submit (s, all3, 3, 3);
  g_assert_cmpint (r.outcome, ==, LSG_FIND_IGNORED);
}

/* --- submit (Enter): predicate validation --- */

static void
test_submit_predicate (void)
{
  LsgFindSession s = lsg_find_initial ();
  s.draft.mode = LSG_FIND_PREDICATE;
  s.draft.column = 1;
  s.draft.op = LSG_SEARCH_OP_LE;
  s.draft.value = "2.5";
  guint32 vis2[] = { 0, 1 };

  LsgFindSubmit r = lsg_find_submit (s, vis2, 2, 2);
  g_assert_cmpint (r.outcome, ==, LSG_FIND_RUN);
  g_assert_cmpint (r.request.kind, ==, LSG_FIND_PREDICATE);
  g_assert_cmpuint (r.request.column, ==, 1);
  g_assert_cmpint (r.request.op, ==, LSG_SEARCH_OP_LE);
  g_assert_cmpstr (r.request.value, ==, "2.5");

  /* Ordering + non-numeric value -> rejected (blink + shake), before any core
   * call — including the empty value and a grouped "1,000". */
  s.draft.value = "abc";
  g_assert_cmpint (lsg_find_submit (s, vis2, 2, 2).outcome, ==, LSG_FIND_REJECTED);
  s.draft.value = "";
  g_assert_cmpint (lsg_find_submit (s, vis2, 2, 2).outcome, ==, LSG_FIND_REJECTED);
  s.draft.value = "1,000";
  g_assert_cmpint (lsg_find_submit (s, vis2, 2, 2).outcome, ==, LSG_FIND_REJECTED);

  /* = and != accept any value — the empty one matches empty cells. */
  s.draft.op = LSG_SEARCH_OP_EQ;
  s.draft.value = "";
  r = lsg_find_submit (s, vis2, 2, 2);
  g_assert_cmpint (r.outcome, ==, LSG_FIND_RUN);
  g_assert_cmpstr (r.request.value, ==, "");

  /* A hidden column is a legal predicate target... */
  guint32 vis1[] = { 0 };
  g_assert_cmpint (lsg_find_submit (s, vis1, 1, 2).outcome, ==, LSG_FIND_RUN);

  /* ...but a column outside the document is not. */
  s.draft.column = 5;
  g_assert_cmpint (lsg_find_submit (s, vis2, 2, 2).outcome, ==, LSG_FIND_REJECTED);
}

/* --- count state machine: grow monotonically, landing, latch final --- */

static void
test_counts_grow_and_latch (void)
{
  LsgFindSession s = lsg_find_began (lsg_find_initial ());
  g_assert_true (s.display.active);
  g_assert_true (s.display.has_progress);
  g_assert_cmpfloat (s.display.progress, ==, 0.0);
  g_assert_cmpuint (s.display.total, ==, 0);
  g_assert_false (s.display.total_final);

  /* Growing polls fold in. */
  LsgSearchSnapshot grow = {
    .phase = LSG_SEARCH_PHASE_SCANNING, .progress = 0.2,
    .nav = LSG_SEARCH_NAV_SEARCHING, .total = 3, .total_exact = FALSE
  };
  s = lsg_find_resolved (s, TRUE, grow, LSG_SEARCH_FORWARD);
  g_assert_cmpuint (s.display.total, ==, 3);
  g_assert_cmpfloat (s.display.progress, ==, 0.2);

  /* The display never regresses on a stale poll. */
  LsgSearchSnapshot stale = {
    .phase = LSG_SEARCH_PHASE_SCANNING, .progress = 0.1,
    .nav = LSG_SEARCH_NAV_SEARCHING, .total = 2, .total_exact = FALSE
  };
  s = lsg_find_resolved (s, TRUE, stale, LSG_SEARCH_FORWARD);
  g_assert_cmpuint (s.display.total, ==, 3);
  g_assert_cmpfloat (s.display.progress, ==, 0.2);

  /* A landing sets the current match + its exact position. */
  LsgSearchSnapshot land = {
    .phase = LSG_SEARCH_PHASE_SCANNING, .progress = 0.5,
    .nav = LSG_SEARCH_NAV_FOUND, .found = { .row = 7, .column = 1 },
    .position = 2, .total = 5, .total_exact = FALSE
  };
  s = lsg_find_resolved (s, TRUE, land, LSG_SEARCH_FORWARD);
  g_assert_true (s.display.has_current);
  g_assert_cmpuint (s.display.current.row, ==, 7);
  g_assert_cmpuint (s.display.current.column, ==, 1);
  g_assert_cmpuint (s.display.position, ==, 2);
  g_assert_cmpuint (s.display.total, ==, 5);

  /* DONE: total latches final and the progress display ends. */
  LsgSearchSnapshot done = {
    .phase = LSG_SEARCH_PHASE_DONE, .nav = LSG_SEARCH_NAV_FOUND,
    .found = { .row = 7, .column = 1 }, .position = 2,
    .total = 12, .total_exact = TRUE
  };
  s = lsg_find_resolved (s, TRUE, done, LSG_SEARCH_FORWARD);
  g_assert_cmpuint (s.display.total, ==, 12);
  g_assert_true (s.display.total_final);
  g_assert_false (s.display.has_progress);
  g_assert_cmpint (s.display.notice, ==, LSG_FIND_NOTICE_NONE);
}

/* --- exhaustion wraps with a notice in both directions --- */

static void
test_wrap_both_directions (void)
{
  LsgFindSession s = lsg_find_began (lsg_find_initial ());
  LsgSearchSnapshot landed3 = {
    .phase = LSG_SEARCH_PHASE_DONE, .nav = LSG_SEARCH_NAV_FOUND,
    .found = { .row = 9, .column = 0 }, .position = 3,
    .total = 3, .total_exact = TRUE
  };
  s = lsg_find_resolved (s, TRUE, landed3, LSG_SEARCH_FORWARD);

  LsgSearchSnapshot exhausted = {
    .phase = LSG_SEARCH_PHASE_DONE, .nav = LSG_SEARCH_NAV_EXHAUSTED,
    .total = 3, .total_exact = TRUE
  };
  LsgSearchNav nav;

  /* Next past the last match: wrapped-to-start notice + the wrap nav; the old
   * landing holds until the wrap lands. */
  LsgFindSession fwd = lsg_find_resolved (s, TRUE, exhausted, LSG_SEARCH_FORWARD);
  g_assert_cmpint (fwd.display.notice, ==, LSG_FIND_NOTICE_WRAPPED_TO_START);
  g_assert_true (fwd.display.has_current);
  g_assert_cmpuint (fwd.display.current.row, ==, 9);
  g_assert_true (lsg_find_wrap_nav (fwd, &nav));
  g_assert_cmpuint (nav.anchor, ==, 0);
  g_assert_cmpint (nav.direction, ==, LSG_SEARCH_FORWARD);

  /* Previous before the first match: wrapped-to-end + the end nav. */
  LsgFindSession bwd = lsg_find_resolved (s, TRUE, exhausted, LSG_SEARCH_BACKWARD);
  g_assert_cmpint (bwd.display.notice, ==, LSG_FIND_NOTICE_WRAPPED_TO_END);
  g_assert_true (lsg_find_wrap_nav (bwd, &nav));
  g_assert_cmpuint (nav.anchor, ==, G_MAXUINT64);
  g_assert_cmpint (nav.direction, ==, LSG_SEARCH_BACKWARD);

  /* The notice clears when the wrap navigation reports its landing. */
  LsgSearchSnapshot wrapLanded = {
    .phase = LSG_SEARCH_PHASE_DONE, .nav = LSG_SEARCH_NAV_FOUND,
    .found = { .row = 1, .column = 0 }, .position = 1,
    .total = 3, .total_exact = TRUE
  };
  LsgFindSession landed = lsg_find_resolved (fwd, TRUE, wrapLanded, LSG_SEARCH_FORWARD);
  g_assert_cmpint (landed.display.notice, ==, LSG_FIND_NOTICE_NONE);
  g_assert_cmpuint (landed.display.current.row, ==, 1);
  g_assert_cmpuint (landed.display.position, ==, 1);
  g_assert_false (lsg_find_wrap_nav (landed, &nav));
}

/* --- zero matches everywhere is "No matches", not a wrap --- */

static void
test_zero_matches (void)
{
  LsgFindSession s = lsg_find_began (lsg_find_initial ());
  LsgSearchSnapshot none = {
    .phase = LSG_SEARCH_PHASE_DONE, .nav = LSG_SEARCH_NAV_EXHAUSTED,
    .total = 0, .total_exact = TRUE
  };
  s = lsg_find_resolved (s, TRUE, none, LSG_SEARCH_FORWARD);
  g_assert_cmpint (s.display.notice, ==, LSG_FIND_NOTICE_NO_MATCHES);
  g_assert_false (s.display.has_current);
  LsgSearchNav nav;
  g_assert_false (lsg_find_wrap_nav (s, &nav)); /* never wrap into an empty result */

  /* Backward exhaustion with an unfinished scan still wraps (matches may exist
   * ahead): only the FINAL zero reads "No matches". */
  LsgFindSession s2 = lsg_find_began (lsg_find_initial ());
  LsgSearchSnapshot scanning0 = {
    .phase = LSG_SEARCH_PHASE_SCANNING, .progress = 0.4,
    .nav = LSG_SEARCH_NAV_EXHAUSTED, .total = 0, .total_exact = FALSE
  };
  s2 = lsg_find_resolved (s2, TRUE, scanning0, LSG_SEARCH_BACKWARD);
  g_assert_cmpint (s2.display.notice, ==, LSG_FIND_NOTICE_WRAPPED_TO_END);
  g_assert_true (lsg_find_wrap_nav (s2, &nav));
  g_assert_cmpuint (nav.anchor, ==, G_MAXUINT64);
}

/* --- step anchors follow the pinned nav semantics --- */

static void
test_step_anchors (void)
{
  LsgFindSession s = lsg_find_began (lsg_find_initial ());
  LsgSearchNav nav;

  /* No landing yet: navigate relative to the viewport. */
  g_assert_true (lsg_find_step (s, LSG_SEARCH_FORWARD, 42, &nav));
  g_assert_cmpuint (nav.anchor, ==, 42);
  g_assert_cmpint (nav.direction, ==, LSG_SEARCH_FORWARD);
  g_assert_true (lsg_find_step (s, LSG_SEARCH_BACKWARD, 42, &nav));
  g_assert_cmpuint (nav.anchor, ==, 42);
  g_assert_cmpint (nav.direction, ==, LSG_SEARCH_BACKWARD);

  /* With a current match: next = at-or-after row + 1; previous = strictly
   * before the current row (no decrement). */
  LsgSearchSnapshot land = {
    .phase = LSG_SEARCH_PHASE_DONE, .nav = LSG_SEARCH_NAV_FOUND,
    .found = { .row = 10, .column = 2 }, .position = 2,
    .total = 4, .total_exact = TRUE
  };
  s = lsg_find_resolved (s, TRUE, land, LSG_SEARCH_FORWARD);
  g_assert_true (lsg_find_step (s, LSG_SEARCH_FORWARD, 0, &nav));
  g_assert_cmpuint (nav.anchor, ==, 11);
  g_assert_cmpint (nav.direction, ==, LSG_SEARCH_FORWARD);
  g_assert_true (lsg_find_step (s, LSG_SEARCH_BACKWARD, 0, &nav));
  g_assert_cmpuint (nav.anchor, ==, 10);
  g_assert_cmpint (nav.direction, ==, LSG_SEARCH_BACKWARD);

  /* No active search: stepping is a no-op (returns FALSE). */
  g_assert_false (lsg_find_step (lsg_find_initial (), LSG_SEARCH_FORWARD, 5, &nav));
}

/* --- stop keeps partials; Esc / reopen clear the display but keep the draft
 *     (incl. the "Match case" flag — it is session-scoped) --- */

static void
test_stop_close_reopen (void)
{
  LsgFindSession s = lsg_find_initial ();
  s.draft.mode = LSG_FIND_TEXT;
  s.draft.text = "needle";
  s.draft.case_sensitive = TRUE; /* the toggle is part of the retained draft */
  s = lsg_find_began (s);
  LsgSearchSnapshot partial = {
    .phase = LSG_SEARCH_PHASE_SCANNING, .progress = 0.3,
    .nav = LSG_SEARCH_NAV_FOUND, .found = { .row = 2, .column = 0 },
    .position = 1, .total = 2, .total_exact = FALSE
  };
  s = lsg_find_resolved (s, TRUE, partial, LSG_SEARCH_FORWARD);

  /* The scan-cancel affordance: partial knowledge stays, progress UI ends. */
  LsgFindSession stopped = lsg_find_stopped (s);
  g_assert_cmpint (stopped.display.notice, ==, LSG_FIND_NOTICE_STOPPED);
  g_assert_false (stopped.display.has_progress);
  g_assert_cmpuint (stopped.display.total, ==, 2);
  g_assert_true (stopped.display.has_current);
  g_assert_cmpuint (stopped.display.current.row, ==, 2);
  g_assert_cmpstr (stopped.draft.text, ==, "needle");

  /* A CANCELLED-phase poll that CARRIES a landing (nav FOUND) still freezes the
   * partials -- the counts hold and the progress UI ends -- like an explicit
   * stop. Its NOTICE, though, must NOT read "Stopped": a network re-park (nfd_ac6)
   * lands the first match AND parks the scan in one poll, so the count must show.
   * That outcome is pinned mechanism-agnostically by /find/resolved-net-park-
   * landing; here we assert only the mechanism-independent partials, staying
   * neutral on the fix (a landed-match guard and a user-stopped flag fold the
   * partials alike). */
  LsgSearchSnapshot cancelled = {
    .phase = LSG_SEARCH_PHASE_CANCELLED, .progress = 0.3,
    .nav = LSG_SEARCH_NAV_FOUND, .found = { .row = 2, .column = 0 },
    .position = 1, .total = 2, .total_exact = FALSE
  };
  LsgFindSession viaPoll = lsg_find_resolved (s, TRUE, cancelled, LSG_SEARCH_FORWARD);
  g_assert_false (viaPoll.display.has_progress);
  g_assert_cmpuint (viaPoll.display.total, ==, 2);

  /* Esc: active search + highlights clear; the DRAFT is retained (text AND the
   * Match case flag ride along — the session keeps them). */
  LsgFindSession closed = lsg_find_closed (s);
  g_assert_false (closed.display.active);
  g_assert_false (closed.display.has_current);
  g_assert_cmpuint (closed.display.total, ==, 0);
  g_assert_cmpint (closed.display.notice, ==, LSG_FIND_NOTICE_NONE);
  g_assert_cmpstr (closed.draft.text, ==, "needle");
  g_assert_true (closed.draft.case_sensitive);

  /* Dialect re-open (new document identity): same clearing, same retention. */
  LsgFindSession reopened = lsg_find_invalidated (s);
  g_assert_false (reopened.display.active);
  g_assert_cmpstr (reopened.draft.text, ==, "needle");
  g_assert_true (reopened.draft.case_sensitive);
}

/* --- REGRESSION: a network net-park poll (CANCELLED that CARRIES a landing)
 *     presents the count, NOT "Stopped" ---
 *
 * On an http_range (network) document the core drives the fetch frontier via
 * ls_search_nav, lands the first match, then RE-PARKS the scan at CANCELLED by
 * design (nfd_ac6). So ONE poll can carry BOTH a fresh landing (nav == FOUND,
 * position/total set) AND phase == CANCELLED. Folding that poll must PRESENT THE
 * COUNT ("1 of N", non-final) -- the STOPPED notice belongs only to an explicit
 * user Stop (lsg_find_stopped). main.c renders the notice BEFORE the count
 * branch, so a STOPPED here MASKS the real "1 of N". The macOS view-model carries
 * the same latent mislabel (FindLogic.swift), which this GTK OUTCOME pin forbids
 * the port from inheriting. The FIX mechanism is chosen by the implementer -- a
 * landed-match guard, or a user-stopped flag -- so this asserts only the outcome
 * (both mechanisms agree: a CANCELLED poll that carries a landing is not
 * STOPPED). */
static void
test_resolved_net_park_landing (void)
{
  LsgFindSession s = lsg_find_initial ();
  s.draft.mode = LSG_FIND_TEXT;
  s.draft.text = "needle";
  s = lsg_find_began (s);

  /* The net-park poll: the first match has landed (nav FOUND, "1 of 4" so far)
   * while the scan simultaneously parked at CANCELLED (total still growing). */
  LsgSearchSnapshot net_park = {
    .phase = LSG_SEARCH_PHASE_CANCELLED, .progress = 0.4,
    .nav = LSG_SEARCH_NAV_FOUND, .found = { .row = 3, .column = 2 },
    .position = 1, .total = 4, .total_exact = FALSE
  };
  LsgFindSession r = lsg_find_resolved (s, TRUE, net_park, LSG_SEARCH_FORWARD);

  /* The poll landing + partial count fold in as usual (these pass today). */
  g_assert_true (r.display.has_current);
  g_assert_cmpuint (r.display.current.row, ==, 3);
  g_assert_cmpuint (r.display.current.column, ==, 2);
  g_assert_cmpuint (r.display.position, ==, 1);
  g_assert_cmpuint (r.display.total, ==, 4);
  g_assert_false (r.display.total_final);   /* "1 of 4", still growing */
  g_assert_false (r.display.has_progress);  /* CANCELLED ends the % UI */

  /* THE REGRESSION: the landed match must NOT be masked as "Stopped" -- the count
   * shows (notice NONE). RED today (the unconditional CANCELLED -> STOPPED map in
   * lsg_find.c). */
  g_assert_cmpint (r.display.notice, !=, LSG_FIND_NOTICE_STOPPED);
  g_assert_cmpint (r.display.notice, ==, LSG_FIND_NOTICE_NONE);
}

/* --- resolved is stable on idle polls and cleared sessions --- */

static void
test_resolved_stable (void)
{
  /* A stale poll after close/clear never resurrects a display. */
  LsgFindSession cleared = lsg_find_initial ();
  LsgSearchSnapshot done0 = {
    .phase = LSG_SEARCH_PHASE_DONE, .nav = LSG_SEARCH_NAV_EXHAUSTED,
    .total = 0, .total_exact = TRUE
  };
  LsgFindSession r = lsg_find_resolved (cleared, TRUE, done0, LSG_SEARCH_FORWARD);
  g_assert_false (r.display.active);
  g_assert_cmpint (r.display.notice, ==, LSG_FIND_NOTICE_NONE);
  g_assert_cmpuint (r.display.total, ==, 0);

  /* A nil (idle) poll never resets an active display. */
  LsgFindSession active = lsg_find_began (lsg_find_initial ());
  LsgSearchSnapshot ignored = { 0 };
  LsgFindSession r2 = lsg_find_resolved (active, FALSE, ignored, LSG_SEARCH_FORWARD);
  g_assert_true (r2.display.active);
  g_assert_cmpuint (r2.display.total, ==, 0);
  g_assert_false (r2.display.total_final);
}

/* ========================================================================= */
/* SEARCH BRIDGE (over the real core, find.csv fixture)                       */
/* ========================================================================= */

static LsgDocument *
open_find_fixture (void)
{
  LsgOpenError err = LSG_OPEN_IO;
  LsgDocument *doc = lsg_document_open_local (FIND_FIXTURE_PATH, NULL, &err);
  g_assert_nonnull (doc);
  g_assert_cmpint (err, ==, LSG_OPEN_OK);
  return doc;
}

/* Poll until the match-scan is final (total_exact), bounded (~10 s). */
static gboolean
wait_final (LsgDocument *doc, LsgSearchSnapshot *out)
{
  for (int i = 0; i < 5000; i++)
    {
      LsgSearchSnapshot s;
      if (lsg_document_search_poll (doc, &s) && s.total_exact)
        {
          if (out)
            *out = s;
          return TRUE;
        }
      g_usleep (2000);
    }
  return FALSE;
}

/* Poll until a navigation lands (nav == FOUND), bounded (~10 s). */
static gboolean
wait_found (LsgDocument *doc, LsgSearchSnapshot *out)
{
  for (int i = 0; i < 5000; i++)
    {
      LsgSearchSnapshot s;
      if (lsg_document_search_poll (doc, &s) && s.nav == LSG_SEARCH_NAV_FOUND)
        {
          if (out)
            *out = s;
          return TRUE;
        }
      g_usleep (2000);
    }
  return FALSE;
}

/* After DONE, navigation is synchronous (pinned): navigate + one poll asserts
 * the landing. */
static void
nav_found (LsgDocument *doc, LsgSearchNav nav, guint64 row, guint32 col, guint64 pos)
{
  lsg_document_search_nav (doc, nav);
  LsgSearchSnapshot s;
  g_assert_true (lsg_document_search_poll (doc, &s));
  g_assert_cmpint (s.nav, ==, LSG_SEARCH_NAV_FOUND);
  g_assert_cmpuint (s.found.row, ==, row);
  g_assert_cmpuint (s.found.column, ==, col);
  g_assert_cmpuint (s.position, ==, pos);
}

static void
nav_exhausted (LsgDocument *doc, LsgSearchNav nav)
{
  lsg_document_search_nav (doc, nav);
  LsgSearchSnapshot s;
  g_assert_true (lsg_document_search_poll (doc, &s));
  g_assert_cmpint (s.nav, ==, LSG_SEARCH_NAV_EXHAUSTED);
}

/* Walk every match forward from the top (requires a completed scan so each nav
 * resolves synchronously). Returns the ascending match rows (caller frees). */
static GArray *
collect_matches (LsgDocument *doc)
{
  GArray *rows = g_array_new (FALSE, FALSE, sizeof (guint64));
  guint64 anchor = 0;
  for (int i = 0; i < 64; i++)
    {
      LsgSearchNav nav = { anchor, LSG_SEARCH_FORWARD };
      lsg_document_search_nav (doc, nav);
      LsgSearchSnapshot s;
      if (!lsg_document_search_poll (doc, &s) || s.nav != LSG_SEARCH_NAV_FOUND)
        break;
      guint64 row = s.found.row;
      g_array_append_val (rows, row);
      if (row == G_MAXUINT64)
        break;
      anchor = row + 1;
    }
  return rows;
}

/* Start `request`, wait for the scan to finish, and return its ascending match
 * rows (caller frees). */
static GArray *
matched_rows (LsgDocument *doc, LsgSearchRequest request)
{
  g_assert_true (lsg_document_search_start (doc, request));
  LsgSearchSnapshot s;
  g_assert_true (wait_final (doc, &s));
  return collect_matches (doc);
}

static void
assert_rows (GArray *got, const guint64 *want, guint n)
{
  g_assert_cmpuint (got->len, ==, n);
  for (guint i = 0; i < n; i++)
    g_assert_cmpuint (g_array_index (got, guint64, i), ==, want[i]);
}

/* --- text search: Match case OFF default (folds), live counts,
 *     next/prev/ends/wrap-exhaust, then Match case ON (byte-exact) --- */

static void
test_bridge_text_search (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* Match case OFF (default): "needle" folds ASCII -> rows 0,1,2,3,6,7 (m = 6). */
  LsgSearchRequest req = { .kind = LSG_FIND_TEXT, .value = "needle" };
  g_assert_true (lsg_document_search_start (doc, req));
  lsg_document_search_nav (doc, lsg_search_nav_from_top ());

  LsgSearchSnapshot first;
  g_assert_true (wait_found (doc, &first));
  g_assert_cmpuint (first.found.row, ==, 0); /* "alpha needle" */
  g_assert_cmpuint (first.found.column, ==, 2);
  g_assert_cmpuint (first.position, ==, 1);

  LsgSearchSnapshot done;
  g_assert_true (wait_final (doc, &done));
  g_assert_cmpuint (done.total, ==, 6);
  g_assert_cmpint (done.phase, ==, LSG_SEARCH_PHASE_DONE);

  /* After DONE, navigation is synchronous: next / previous / ends / exhaust. */
  nav_found (doc, (LsgSearchNav){ 1, LSG_SEARCH_FORWARD }, 1, 0, 2);  /* "NEEDLE" folds */
  nav_found (doc, (LsgSearchNav){ 1, LSG_SEARCH_BACKWARD }, 0, 2, 1);
  nav_found (doc, lsg_search_nav_from_end (), 7, 2, 6);
  nav_exhausted (doc, (LsgSearchNav){ 8, LSG_SEARCH_FORWARD });
  nav_found (doc, lsg_search_nav_from_top (), 0, 2, 1);

  /* Cancel after completion: DONE persists (mirrors ls_search_cancel). */
  lsg_document_search_cancel (doc);
  LsgSearchSnapshot afterCancel;
  g_assert_true (lsg_document_search_poll (doc, &afterCancel));
  g_assert_cmpint (afterCancel.phase, ==, LSG_SEARCH_PHASE_DONE);

  /* Match case ON is byte-exact: the uppercase "Needle" query matches ONLY the
   * exact bytes "Needle point" (row 3), NOT the folded needle cells. Under the
   * new default this behavior requires case_sensitive = TRUE — the old
   * smart-case "uppercase => exact" auto-rule is gone. */
  LsgSearchRequest exact = { .kind = LSG_FIND_TEXT, .value = "Needle", .case_sensitive = TRUE };
  g_assert_true (lsg_document_search_start (doc, exact));
  LsgSearchSnapshot exactDone;
  g_assert_true (wait_final (doc, &exactDone));
  g_assert_cmpuint (exactDone.total, ==, 1);
  nav_found (doc, lsg_search_nav_from_top (), 3, 2, 1);

  lsg_document_close (doc);
}

/* --- Match case end-to-end through the frontend's BUILT request (§6 C7): a
 *     draft composed by lsg_find_submit drives the core; OFF folds an uppercase
 *     query, ON is byte-exact — for both TEXT and predicate EQ. This exercises
 *     the WHOLE frontend path (draft -> compose -> marshal -> core); it turns
 *     GREEN once the composer threads the flag AND the bridge marshals it. --- */

static void
test_bridge_case_mode (void)
{
  LsgDocument *doc = open_find_fixture ();
  guint32 all3[] = { 0, 1, 2 };
  GArray *m;

  /* TEXT, Match case OFF (default): an uppercase "NEEDLE" folds -> all 6 needle
   * rows (the key departure from smart-case). */
  LsgFindSession s = lsg_find_initial ();
  s.draft.mode = LSG_FIND_TEXT;
  s.draft.text = "NEEDLE";
  s.draft.case_sensitive = FALSE;
  LsgFindSubmit textOff = lsg_find_submit (s, all3, 3, 3);
  g_assert_cmpint (textOff.outcome, ==, LSG_FIND_RUN);
  m = matched_rows (doc, textOff.request);
  assert_rows (m, (const guint64[]){ 0, 1, 2, 3, 6, 7 }, 6);
  g_array_free (m, TRUE);

  /* TEXT, Match case ON: byte-exact "NEEDLE" -> only row 1 ("NEEDLE"). */
  s.draft.case_sensitive = TRUE;
  LsgFindSubmit textOn = lsg_find_submit (s, all3, 3, 3);
  g_assert_cmpint (textOn.outcome, ==, LSG_FIND_RUN);
  m = matched_rows (doc, textOn.request);
  assert_rows (m, (const guint64[]){ 1 }, 1);
  g_array_free (m, TRUE);

  /* PREDICATE EQ, Match case OFF: "widget" matches the "Widget" cell (row 0) —
   * the ARCH's "= isabella matches Isabella" default, over this fixture. */
  s.draft.mode = LSG_FIND_PREDICATE;
  s.draft.column = 0;
  s.draft.op = LSG_SEARCH_OP_EQ;
  s.draft.value = "widget";
  s.draft.case_sensitive = FALSE;
  LsgFindSubmit eqOff = lsg_find_submit (s, all3, 3, 3);
  g_assert_cmpint (eqOff.outcome, ==, LSG_FIND_RUN);
  m = matched_rows (doc, eqOff.request);
  assert_rows (m, (const guint64[]){ 0 }, 1);
  g_array_free (m, TRUE);

  /* PREDICATE EQ, Match case ON: "widget" is byte-exact -> no longer equals
   * "Widget" -> zero matches. */
  s.draft.case_sensitive = TRUE;
  LsgFindSubmit eqOn = lsg_find_submit (s, all3, 3, 3);
  g_assert_cmpint (eqOn.outcome, ==, LSG_FIND_RUN);
  m = matched_rows (doc, eqOn.request);
  assert_rows (m, NULL, 0);
  g_array_free (m, TRUE);

  lsg_document_close (doc);
}

/* --- predicate search + core-side validation --- */

static void
test_bridge_predicate (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* qty <= 2 numerically: rows 0 (2), 2 (2.0), 3 (-3), 5 (0.5) — m = 4. */
  LsgSearchRequest le2 = { .kind = LSG_FIND_PREDICATE, .column = 1, .op = LSG_SEARCH_OP_LE, .value = "2" };
  g_assert_true (lsg_document_search_start (doc, le2));
  lsg_document_search_nav (doc, lsg_search_nav_from_top ());
  LsgSearchSnapshot first;
  g_assert_true (wait_found (doc, &first));
  g_assert_cmpuint (first.found.row, ==, 0);
  g_assert_cmpuint (first.found.column, ==, 1);
  g_assert_cmpuint (first.position, ==, 1);
  LsgSearchSnapshot done;
  g_assert_true (wait_final (doc, &done));
  g_assert_cmpuint (done.total, ==, 4);
  nav_found (doc, lsg_search_nav_from_end (), 5, 1, 4);

  /* Byte-exact equality distinguishes representations ("2.0" vs "2"). */
  GArray *m;
  m = matched_rows (doc, (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 1, .op = LSG_SEARCH_OP_EQ, .value = "2.0" });
  assert_rows (m, (const guint64[]){ 2 }, 1);
  g_array_free (m, TRUE);
  m = matched_rows (doc, (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 1, .op = LSG_SEARCH_OP_EQ, .value = "2" });
  assert_rows (m, (const guint64[]){ 0 }, 1);
  g_array_free (m, TRUE);

  /* The empty value matches the empty cell (ragged/pad rule): row 6's name. */
  m = matched_rows (doc, (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 0, .op = LSG_SEARCH_OP_EQ, .value = "" });
  assert_rows (m, (const guint64[]){ 6 }, 1);
  g_array_free (m, TRUE);

  /* Core-side enforcement mirrors the composer: rejected starts change nothing
   * (the previous search stays polled). */
  g_assert_true (lsg_document_search_start (doc, le2));
  g_assert_true (wait_final (doc, &done));
  g_assert_false (lsg_document_search_start (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 1, .op = LSG_SEARCH_OP_LT, .value = "abc" }));
  g_assert_false (lsg_document_search_start (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "" }));
  g_assert_false (lsg_document_search_start (doc,
      (LsgSearchRequest){ .kind = LSG_FIND_PREDICATE, .column = 9, .op = LSG_SEARCH_OP_EQ, .value = "x" }));
  LsgSearchSnapshot after;
  g_assert_true (lsg_document_search_poll (doc, &after));
  g_assert_cmpuint (after.total, ==, 4);
  g_assert_true (after.total_exact);

  lsg_document_close (doc);
}

/* --- text scope: evaluate only the requested columns --- */

static void
test_bridge_scope (void)
{
  LsgDocument *doc = open_find_fixture ();

  guint32 c0[] = { 0 };
  guint32 c1[] = { 1 };
  guint32 c2[] = { 2 };
  guint32 c02[] = { 0, 2 };
  GArray *m;

  /* "needle" per column: col 0 -> rows 1,2; col 2 -> rows 0,3,6,7. */
  m = matched_rows (doc, (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "needle", .scope = c0, .scope_len = 1 });
  assert_rows (m, (const guint64[]){ 1, 2 }, 2);
  g_array_free (m, TRUE);
  m = matched_rows (doc, (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "needle", .scope = c2, .scope_len = 1 });
  assert_rows (m, (const guint64[]){ 0, 3, 6, 7 }, 4);
  g_array_free (m, TRUE);
  m = matched_rows (doc, (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "needle", .scope = c1, .scope_len = 1 });
  assert_rows (m, NULL, 0);
  g_array_free (m, TRUE);
  m = matched_rows (doc, (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "needle", .scope = c02, .scope_len = 2 });
  assert_rows (m, (const guint64[]){ 0, 1, 2, 3, 6, 7 }, 6);
  g_array_free (m, TRUE);

  lsg_document_close (doc);
}

/* --- a fresh session is IDLE; the header record is never matched --- */

static void
test_bridge_fresh_idle (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* Fresh session: no search state -> "no snapshot". */
  LsgSearchSnapshot s;
  g_assert_false (lsg_document_search_poll (doc, &s));

  /* Header ON: "name" lives in the header record -> never matched. */
  g_assert_true (lsg_document_search_start (doc, (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "name" }));
  g_assert_true (wait_final (doc, &s));
  g_assert_cmpuint (s.total, ==, 0);

  lsg_document_close (doc);
}

/* --- the per-visible-cell highlight MASK (ls_window_match_flags) --- */

static void
test_bridge_match_flags (void)
{
  LsgDocument *doc = open_find_fixture ();

  /* IDLE (no active search): the mask is empty, even with a window set. */
  LsgWindow *w = lsg_document_set_window (doc, 0, 8, 0, 3);
  LsgMatchFlags idle = lsg_document_window_match_flags (doc, 0, 3);
  g_assert_null (idle.flags);
  g_assert_cmpuint (idle.rows, ==, 0);
  g_assert_cmpuint (idle.cols, ==, 0);
  lsg_window_free (w);

  /* Match case OFF (default): text "needle" over all columns marks exactly the
   * matching cells (folding includes "NEEDLE" and "Needle point"). */
  g_assert_true (lsg_document_search_start (doc, (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "needle" }));
  LsgSearchSnapshot done;
  g_assert_true (wait_final (doc, &done));
  g_assert_cmpuint (done.total, ==, 6);

  w = lsg_document_set_window (doc, 0, 8, 0, 3);
  g_assert_cmpuint (lsg_window_row_count (w), ==, 8);
  LsgMatchFlags m = lsg_document_window_match_flags (doc, 0, 3);
  g_assert_nonnull (m.flags);
  g_assert_cmpuint (m.rows, ==, 8);
  g_assert_cmpuint (m.cols, ==, 3);
  /* 1-cells: (0,2) alpha needle; (1,0) NEEDLE; (2,0) needle; (3,2) Needle point;
   * (6,2) needleneedle; (7,2) end needle. */
  static const guint8 want[8][3] = {
    { 0, 0, 1 }, { 1, 0, 0 }, { 1, 0, 0 }, { 0, 0, 1 },
    { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 1 }, { 0, 0, 1 },
  };
  for (guint32 r = 0; r < 8; r++)
    for (guint32 c = 0; c < 3; c++)
      g_assert_cmpuint (m.flags[r * m.cols + c], ==, want[r][c]);
  g_free (m.flags);
  lsg_window_free (w);

  /* Match case ON is byte-exact (the mask inherits case_sensitive too): the
   * uppercase "Needle" query lights only "Needle point" at (3,2). */
  g_assert_true (lsg_document_search_start (doc, (LsgSearchRequest){ .kind = LSG_FIND_TEXT, .value = "Needle", .case_sensitive = TRUE }));
  g_assert_true (wait_final (doc, &done));
  w = lsg_document_set_window (doc, 0, 8, 0, 3);
  LsgMatchFlags mx = lsg_document_window_match_flags (doc, 0, 3);
  g_assert_nonnull (mx.flags);
  for (guint32 r = 0; r < 8; r++)
    for (guint32 c = 0; c < 3; c++)
      g_assert_cmpuint (mx.flags[r * mx.cols + c], ==, (r == 3 && c == 2) ? 1 : 0);
  g_free (mx.flags);
  lsg_window_free (w);

  /* Out-of-range column range: the empty mask. */
  LsgMatchFlags oob = lsg_document_window_match_flags (doc, 99, 1);
  g_assert_null (oob.flags);
  g_assert_cmpuint (oob.rows, ==, 0);

  lsg_document_close (doc);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  /* Pure view-model. */
  g_test_add_func ("/find/abi-enum-pins", test_abi_enum_pins);
  g_test_add_func ("/find/op-ordering", test_op_ordering);
  g_test_add_func ("/find/numeric-grammar", test_numeric_grammar);
  g_test_add_func ("/find/case-mode", test_case_mode);
  g_test_add_func ("/find/initial-empty", test_initial_empty);
  g_test_add_func ("/find/submit-text-scope", test_submit_text_scope);
  g_test_add_func ("/find/submit-predicate", test_submit_predicate);
  g_test_add_func ("/find/counts-grow-and-latch", test_counts_grow_and_latch);
  g_test_add_func ("/find/wrap-both-directions", test_wrap_both_directions);
  g_test_add_func ("/find/zero-matches", test_zero_matches);
  g_test_add_func ("/find/step-anchors", test_step_anchors);
  g_test_add_func ("/find/stop-close-reopen", test_stop_close_reopen);
  g_test_add_func ("/find/resolved-net-park-landing", test_resolved_net_park_landing);
  g_test_add_func ("/find/resolved-stable", test_resolved_stable);

  /* Search bridge over the real core. */
  g_test_add_func ("/find/bridge-text-search", test_bridge_text_search);
  g_test_add_func ("/find/bridge-case-mode", test_bridge_case_mode);
  g_test_add_func ("/find/bridge-predicate", test_bridge_predicate);
  g_test_add_func ("/find/bridge-scope", test_bridge_scope);
  g_test_add_func ("/find/bridge-fresh-idle", test_bridge_fresh_idle);
  g_test_add_func ("/find/bridge-match-flags", test_bridge_match_flags);

  return g_test_run ();
}
