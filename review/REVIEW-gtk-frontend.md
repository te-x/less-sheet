# REVIEW — gtk-frontend (incremental; Slice 1 = core viewer)

Component: `apps/gtk/` (GNOME-native GTK4 + libadwaita frontend, C; pure consumer of the frozen
workspace `api/lesssheet.h`). Signed ARCH: `docs/architecture/ARCH-gtk-frontend.md`. Delivered in
INCREMENTAL SLICES (the author) toward full macOS parity. This record covers **Slice 1**; later slices
(find → jump → filter → copy → Settings → dialect) append their own sections.

## Slice 1 (core viewer: open local + network → O(viewport) grid → scroll)

**Verdict: PASS (converged in 2 rounds).** Bootstrap `c04de87`; frozen contract `fce4f80`; ARCH
decision-2 amendment `8753737`; implementation committed on top. Gate runs WHOLLY in a pinned
`less-sheet-gtk-ci:fedora42` container (GTK 4.18 / libadwaita 1.7 / meson 1.7 / gcc 15); the Zig core is
cross-built by zig to a glibc static `.a` (arch-adaptive `aarch64`/`x86_64-linux-gnu`) and linked by meson.

### What shipped (all in `apps/gtk/src/`, IMPLEMENTATION only — frozen `include/`/`tests/` untouched)
Five `lsg_*` logic modules implementing the frozen module headers, + `main.c` the real GTK viewer:
- `lsg_document.c` — windowed session over the core's two-lane access (local open, column-windowed
  `set_window` copying every cell out under the window lock, row-count/scan polls, U+FFFD sanitize).
- `lsg_net_open.c` — URL-open drive + state/error/progress reducer over `ls_open_url_*`; adopts the
  completed core `ls_doc*` via a private src-internal seam `lsg_document_internal.h` (`lsg_document_adopt`).
- `lsg_formatter.c` — display-free formatter (GLib/C-locale/`GDateTime`, NO ICU): strict kind gate,
  lossless base-10 exact-decimal (digit-string arithmetic, HALF-EVEN, ≤38-sig + `[-128,127]` exponent
  guard → else raw), locale glyphs, grouping. No binary float.
- `lsg_grid_geometry.c` — O(viewport) math: row window, filler/proportional scroll↔row mapping, deferred
  estimate, column window, monotone width merge, the width heuristic (no `<math.h>`).
- `lsg_window_poll.c` — the re-issue-while-short / poll-while-indexing decision.
- `main.c` — `AdwApplicationWindow` + `AdwToolbarView`/`AdwHeaderBar` (Open + Open URL, filename/row-count
  title), launch `AdwStatusPage`, error state, `AdwBanner` for network progress, and the **custom
  O(viewport) grid**: a `GtkDrawingArea` (Cairo + PangoCairo) with a hand-driven `GtkAdjustment` +
  `GtkScrollbar`, uniform row height, per-frame materialization of only the visible row × column window,
  lazy per-window header labels, and `lsg_grid_grow_widths` auto-fit-on-scroll. Local open via
  `GtkFileDialog`; URL open via `AdwAlertDialog`; 100 ms frontier poll; wheel/keyboard scrolling.

### Findings (both in the compile-only `main.c`; frozen modules were correct from R1)
- **R1 [design] — rendering primitive.** Built with `GtkDrawingArea` + Cairo/PangoCairo vs the ARCH's
  literal "GtkSnapshot/GSK". The reviewer would not unilaterally bless a signed-decision deviation it
  couldn't measure headlessly (perf = the H4 GUI pass). **Resolved: the author ratified Cairo/PangoCairo;**
  ARCH decision 2 amended + committed (`8753737`) — the "GtkSnapshot/GSK" wording was internally
  inconsistent (a `GtkDrawingArea`'s only paint API is the Cairo `draw_func`); paint is viewport-bounded.
- **R1 [impl] — eager O(column_count) header prefetch at open → FIXED (R2, verified).** The whole-doc
  `header_cell_dup` loop + retained `char **headers` deleted; headers now fetched lazily per visible
  column window (`grid_window_headers`), freed/rebuilt each materialize — open is O(head), matching the
  macOS lazy-per-window design (touches ~hundreds, not 100k, headers on a wide doc).
- **R2 — `lsg_grid_grow_widths` auto-fit wired (verified glitch-free):** monotone merge, only in-window
  columns are candidates, only `"value-changed"` connected (never `"changed"`) so growing the adjustment
  upper can't re-enter materialize; `first_x` frame-consistent; never under-materializes; O(visible cells)
  + a cheap O(col_count) arithmetic width-merge per frame. `is_overscrolling=FALSE` confirmed correct for
  slice 1 (no kinetic scroll source; the deferred TRUE branch is reserved + unit-pinned for a later slice).

### Verified correct (against the macOS originals) — no action
Formatter losslessness + HALF-EVEN; grid geometry (all vectors, edge cases); two-lane locking (window/
control order, borrows copied under the lock, no use-after-free/deadlock); viewport-only paint/scroll;
the private seam header (LsgDocument stays opaque in the frozen header — no contract widening);
net-open mappers + adopt-on-DONE.

### Non-blocking / deferred (recorded)
- **G6 headless GTK smoke** is a deliberate planner-scoped slice-1 gap (frozen tests are display-free;
  `main.c` is compile-only in-gate) — recommend the planner track a Xvfb/Broadway smoke for the first GUI
  slice. NOTE: the app was run headlessly under Xvfb during this cell and rendered its launch screen
  cleanly (`~/Desktop/shots/less-sheet-gtk-launch.png`) — an ad-hoc smoke, not a gate check.
- Formatter `[-128,127]` guard is slightly more conservative than Foundation `Decimal` at the
  high-exponent/low-significand corner (never a wrong value, only occasional raw) — a one-line note for
  the later formatter-wiring slice (formatter isn't user-visible in slice 1).
- The autofit width-merge does an O(col_count) arithmetic pass per frame (cheap; ~tens of µs at 100k cols)
  — a "skip merge when no candidate exceeds current" pre-check removes it if H4 ever shows a cost.

### Pending — human GUI pass (the author, real GNOME; ARCH H1–H6)
The gate proves compile + display-free logic (6/6). It cannot judge the rendered UI. Outstanding:
native look + live dark/accent (H1), cold-start <500 ms + big-file O(viewport) smoothness (H2/H4),
interaction parity so far (H3), a real HTTPS `.csv`/`.csv.gz` open over TLS (H5). Accessibility (H6)
remains the deferred item across all slices.
