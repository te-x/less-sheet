/*
 * lsg_jump_step.h — PRIVATE (non-frozen) pure logic for ARROW-KEY STEPPING of
 * the jump field's row number, inside src/ (same role as
 * lsg_document_internal.h: an implementation-path seam, not part of the
 * contract).
 *
 * WHAT IT IS. With the jump field open, Up/Down step the 1-based row number in
 * the entry WITHOUT jumping (no scan, no landing, no viewport change — Enter
 * still submits, exactly as before). The DIRECTION IS INVERTED relative to a
 * stock stepper, deliberately (the author): the grid's row numbers GROW downward,
 * so "Down" means further DOWN the document (a HIGHER row number) and "Up"
 * means back toward row 1. This is the macOS frontend's behavior too and the
 * two must not drift.
 *
 * WHY A HEADER AND NOT STATICS IN main.c. The whole decision — which key steps
 * which way, the wrap at both ends, the estimate fallback, the seed for an
 * empty field — is pure arithmetic over an entered string, so it is kept
 * display-free and exercisable on its own (the component's g_test suite lives
 * behind the frozen contract in include/ + tests/; this is the same shape
 * those modules have, ready to be promoted there when the contract next
 * opens). All `static inline`: each including TU gets its own copy and an
 * unused TU draws no warning.
 *
 * ONE PARSER. The field's accepted syntax is NOT re-implemented here: the
 * stepper parses with the frozen `lsg_jump_parse` (digits only, 1-based, no
 * zero, no overflow) — the very function Enter/`lsg_jump_submit` uses — so
 * what counts as "a number in the field" can never drift between stepping and
 * submitting.
 */
#ifndef LSG_JUMP_STEP_H
#define LSG_JUMP_STEP_H

#include <gdk/gdkkeysyms.h>
#include <glib.h>
#include <lsg_jump.h>

G_BEGIN_DECLS

/* Which way an arrow steps the entered row number. Named for the DOCUMENT
 * direction rather than the key, because the key mapping is the inverted part:
 * Up = EARLIER (toward row 1), Down = LATER (toward the end). */
typedef enum
{
  LSG_JUMP_STEP_NONE = 0,    /* not a stepping key                          */
  LSG_JUMP_STEP_EARLIER = 1, /* Up:   toward row 1                          */
  LSG_JUMP_STEP_LATER = 2,   /* Down: toward the last row                   */
} LsgJumpStepDir;

/*
 * The stepping direction a keyval requests, or LSG_JUMP_STEP_NONE for every
 * other key. THE INVERSION LIVES HERE: GDK_KEY_Up -> EARLIER (a SMALLER row
 * number), GDK_KEY_Down -> LATER (a BIGGER one). Keypad arrows behave like the
 * main ones (the field's digit entry already treats KP digits as digits).
 * Modifier filtering is the caller's (event-state) business: only bare arrows
 * step — Shift/Ctrl/Alt-arrow is deliberately NOT a page-step.
 */
static inline LsgJumpStepDir
lsg_jump_step_dir_for_keyval (guint keyval)
{
  switch (keyval)
    {
    case GDK_KEY_Up:
    case GDK_KEY_KP_Up:
      return LSG_JUMP_STEP_EARLIER;
    case GDK_KEY_Down:
    case GDK_KEY_KP_Down:
      return LSG_JUMP_STEP_LATER;
    default:
      return LSG_JUMP_STEP_NONE;
    }
}

/*
 * The 1-based row number the field should show after one step.
 *
 *   text      — the field's current text (borrowed; may be NULL/empty/junk).
 *   dir       — EARLIER / LATER (NONE returns the current value unstepped).
 *   last_row  — the 1-based LAST row number as currently known: the
 *               ORIGINAL-row count the jump field speaks in
 *               (`lsg_filter_jump_rowcount`), whether that count is EXACT or
 *               still the core's ESTIMATE. Stepping deliberately accepts the
 *               estimate ("estimate if needed") instead of forcing a scan to
 *               learn the true end: the number is only text until Enter, and
 *               Enter validates it for real. 0 (unknown / no data rows) is
 *               treated as 1, so a degenerate document just clamps to row 1.
 *   seed_row  — the 1-based row to start from when `text` holds no valid
 *               number: the caller passes the TOP VISIBLE row (the number the
 *               gutter shows at the top of the viewport), so the first arrow
 *               press steps off what the user is looking at. 0 is treated
 * as 1.
 *
 * WRAP, both ends: stepping EARLIER past row 1 wraps to `last_row`; stepping
 * LATER at/past `last_row` wraps to 1. A value ABOVE `last_row` (the user
 * typed a number past the end) is first CLAMPED to `last_row`, so an arrow
 * never leaves a number outside 1…`last_row` — byte-identical to the macOS
 * frontend's `JumpFieldStep.applied`
 * (Sources/LessSheetApp/JumpFieldStepping.swift), which is the point: this
 * interaction must not drift between the two frontends.
 *
 * Returns a value >= 1; never 0, never overflows (LATER only increments while
 * strictly below `last_row`).
 */
static inline guint64
lsg_jump_step_row (const char *text, LsgJumpStepDir dir, guint64 last_row,
                   guint64 seed_row)
{
  const guint64 last = (last_row > 0) ? last_row : 1;
  guint64 target0 = 0;
  /* The frozen field parser, so stepping and submitting agree on the syntax.
   */
  guint64 cur
      = lsg_jump_parse (text, &target0)
            ? target0 + 1 /* parse yields 0-based; the field is 1-based */
            : ((seed_row > 0) ? seed_row : 1);
  if (cur > last)
    cur = last; /* the macOS clamp: stepping stays inside 1…last */

  switch (dir)
    {
    case LSG_JUMP_STEP_EARLIER:
      return (cur > 1) ? cur - 1 : last;
    case LSG_JUMP_STEP_LATER:
      return (cur < last) ? cur + 1 : 1;
    case LSG_JUMP_STEP_NONE:
    default:
      return cur;
    }
}

G_END_DECLS

#endif /* LSG_JUMP_STEP_H */
