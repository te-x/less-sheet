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

/* ------------------------------------------------------------------------- */
/* HOLD-TO-ACCELERATE — the ramp                                             */
/* ------------------------------------------------------------------------- */

/*
 * A held arrow repeats at the DESKTOP's key-repeat rate (measured ~12.5/s
 * here, ~11/s on the author's Mac, and user-configurable on both), so a fixed step
 * of 1 makes holding useless past a nudge: row 1,000,000 would take a day.
 * Holding therefore ACCELERATES, on the ramp the author specified:
 *
 *   held < 1 s -> 1     held < 2 s -> 10     held < 3 s -> 100     else 1000
 *
 * KEYED OFF ELAPSED TIME, NOT OFF A REPEAT COUNT. The rungs are wall-clock
 * seconds since the FIRST press of the current hold, so the acceleration is
 * identical on GTK and macOS and under any repeat-rate setting; a count-based
 * ramp would accelerate at different rows per platform and per user.
 *
 * THE RAMP MUST GO COLD AGAIN, and it is defended THREE independent ways,
 * because a ramp left hot would turn the user's next single tap into a
 * 1000-row jump — the worst thing this feature could do:
 *
 *   1. KEY RELEASE resets it (the key controller reports releases).
 *   2. A GAP longer than `LSG_JUMP_STEP_RAMP_GAP_US` since the last step
 *      resets it, so a SWALLOWED OR MISSED RELEASE cannot leave it armed.
 *      The gap sits well above one repeat interval (300 ms vs ~80 ms), so
 *      it never fires mid-hold.
 *   3. A DIRECTION CHANGE resets it: you cannot hold both arrows, so the
 *      other arrow is by definition a new hold. (This third rule is mine,
 *      not in the spec — it closes the swallowed-release-then-flip hole.)
 *
 * Any of the three means the next press starts a fresh hold at step 1.
 */

/* The ONE knob for "the hold ended": no step within this long means cold. */
#define LSG_JUMP_STEP_RAMP_GAP_US (300 * G_TIME_SPAN_MILLISECOND)

/*
 * The hold's state — a PLAIN VALUE the caller owns (no allocation, no timers,
 * no clock reads of its own: the caller passes monotonic microseconds in,
 * which is what makes the ramp exercisable without waiting in real time). `dir
 * == LSG_JUMP_STEP_NONE` is COLD (no hold in progress).
 */
typedef struct
{
  LsgJumpStepDir dir; /* the direction of the hold in progress; NONE = cold */
  gint64 hold_start_us; /* monotonic time of this hold's FIRST press */
  gint64 last_step_us;  /* monotonic time of its most recent step            */
} LsgJumpStepRamp;

/* The cold ramp (all-zero, so a zero-initialized owner starts cold). */
static inline LsgJumpStepRamp
lsg_jump_step_ramp_initial (void)
{
  LsgJumpStepRamp ramp = { LSG_JUMP_STEP_NONE, 0, 0 };
  return ramp;
}

/* Go cold NOW — the key-release path (defence 1). Idempotent. */
static inline void
lsg_jump_step_ramp_reset (LsgJumpStepRamp *ramp)
{
  *ramp = lsg_jump_step_ramp_initial ();
}

/* The step size for a hold that has lasted `held_us`: the ramp itself, in ONE
 * place. A rung boundary belongs to the FASTER rung (>= 1 s steps by 10). */
static inline guint64
lsg_jump_step_ramp_size (gint64 held_us)
{
  static const gint64 rung_after_us[]
      = { 1 * G_USEC_PER_SEC, 2 * G_USEC_PER_SEC, 3 * G_USEC_PER_SEC };
  static const guint64 rung_step[] = { 1, 10, 100, 1000 };
  for (gsize i = 0; i < G_N_ELEMENTS (rung_after_us); i++)
    if (held_us < rung_after_us[i])
      return rung_step[i];
  return rung_step[G_N_ELEMENTS (rung_after_us)];
}

/*
 * Fold one arrow press at `now_us` (monotonic microseconds) into the ramp and
 * return the STEP SIZE that press should move. Starts a fresh hold — step 1 —
 * whenever the ramp is cold, the direction changed (defence 3), the gap since
 * the last step exceeded LSG_JUMP_STEP_RAMP_GAP_US (defence 2), or the clock
 * appears to have gone backwards. `dir` must be EARLIER or LATER.
 */
static inline guint64
lsg_jump_step_ramp_press (LsgJumpStepRamp *ramp, LsgJumpStepDir dir,
                          gint64 now_us)
{
  const gboolean fresh
      = (ramp->dir != dir) || (now_us < ramp->last_step_us)
        || (now_us - ramp->last_step_us > LSG_JUMP_STEP_RAMP_GAP_US);
  if (fresh)
    {
      ramp->dir = dir;
      ramp->hold_start_us = now_us;
    }
  ramp->last_step_us = now_us;
  return lsg_jump_step_ramp_size (now_us - ramp->hold_start_us);
}

/*
 * The 1-based row number the field should show after one step.
 *
 *   text      — the field's current text (borrowed; may be NULL/empty/junk).
 *   dir       — EARLIER / LATER (NONE returns the current value unstepped).
 *   step      — how many rows this press moves (1, or a ramp size from
 *               `lsg_jump_step_ramp_press`); 0 is read as 1.
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
 * SNAPPING. A `step` above 1 does NOT add itself to the current value: it
 * moves to the NEXT MULTIPLE OF ITSELF in the direction of travel. That is
 * what makes the ramp the author approved read 20, 30, 40 … and 200, 300, 400 …
 * instead of the repeat-rate-dependent 12, 22, 32 — you land on 3000, never on
 * 2994. A value already sitting on a multiple advances a whole step (20 ->
 * 30). Snapping is always FORWARD in the direction of travel, so a step can
 * never move backwards: from 25 a step of 10 goes to 30 going LATER and to 20
 * going EARLIER.
 *
 * WRAP AND CLAMP, at EVERY step size — no step size can leap over a wrap. Both
 * ends are ONE rule: a step that would leave the document LANDS ON the end it
 * was heading for, and only a press made while ALREADY standing on that end
 * wraps round. So on a 200000-row file 199500 goes to 200000, and the press
 * after that wraps to 1. A value ABOVE `last_row` (the user typed a number
 * past the end) is CLAMPED to `last_row` first, so an arrow never leaves a
 * number outside 1…`last_row`. With `step` 1 all of this reduces to exactly
 * the original ±1 behaviour (4999 -> 5000 -> 1).
 *
 * Every one of these rules is the macOS frontend's `JumpFieldStep.applied`
 * (Sources/LessSheetApp/JumpFieldStepping.swift), computed the same way — in
 * DISTANCES to the neighbouring multiple rather than absolute multiples, so
 * nothing overflows near G_MAXUINT64. This interaction must not drift between
 * the two frontends.
 *
 * Returns a value >= 1; never 0, and never overflows at any `step`.
 */
static inline guint64
lsg_jump_step_row (const char *text, LsgJumpStepDir dir, guint64 step,
                   guint64 last_row, guint64 seed_row)
{
  const guint64 last = (last_row > 0) ? last_row : 1;
  const guint64 by = (step > 0) ? step : 1;
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
      {
        /* The distance DOWN to the neighbouring multiple of `by` — a whole
         * step when already standing on one. */
        const guint64 rem = cur % by;
        const guint64 retreat = (rem == 0) ? by : rem;
        if (retreat >= cur)             /* the snap would leave the document */
          return (cur == 1) ? last : 1; /* land on row 1; wrap only FROM it */
        return cur - retreat;
      }
    case LSG_JUMP_STEP_LATER:
      {
        /* ... and the distance UP to the next one. */
        const guint64 advance = by - (cur % by);
        if (advance > last - cur) /* would leave the document */
          return (cur == last) ? 1
                               : last; /* land on the end; wrap only FROM it */
        return cur + advance;
      }
    case LSG_JUMP_STEP_NONE:
    default:
      return cur;
    }
}

G_END_DECLS

#endif /* LSG_JUMP_STEP_H */
