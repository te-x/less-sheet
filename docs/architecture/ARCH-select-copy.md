# ARCH — select-copy (dogfood: rectangular cell select + copy + column ergonomics)

**Feature:** turn the pure viewer into a usable tool — rectangular cell selection, lossless copy to the
clipboard, and column resize/auto-fit — while keeping every operation BOUNDED at our scale (100M rows ×
100k cols), so nothing reintroduces the O(document) cost the huge-row / wide-doc / column-windowing work
just removed.

**Read first:** `apps/macos/Sources/LessSheetApp/NativeGrid.swift` (the single-column custom-drawn grid;
`SheetRowView.draw`, `SheetCellHighlight` — the existing find-highlight fill we reuse for selection), the
frozen `api/lesssheet.h` (TEXT/DISPLAY CAP + the borrow rules), `docs/architecture/ARCH-column-windowing.md`
(the column window + `ColumnLayouting` selection/copy must ride), and `[[macos-ui-direction]]` (chromeless
Liquid Glass aesthetic). `[[prefers-native-and-latest]]` — native affordances.

## Problem
The grid is a deliberate pure viewer (`selectionHighlightStyle = .none`, `drawSelection` empty, "No
selection, no drag-resize"). To dogfood it we need to select cells, copy them, and size columns — but a
naive spreadsheet select/copy is O(document): Excel caps at ~1M rows; WE open 100M+. So selection extent
and copy volume must be hard-bounded, and copy must be off the UI thread. Also, the core has NO full-cell
read accessor — `ls_cell` serves only the ≤ `LS_CELL_MAX_BYTES` (4 KiB) display-capped bytes — so faithful
copy of a long cell needs a new bounded read across the ABI.

## Decisions made with the user (2026-07-10 — do not re-litigate)
- **Selection = full spreadsheet-style interactions, UNBOUNDED extent (index-space).** Rectangular cell
  range via click-drag + shift-click extend + arrow/shift-arrow keyboard; whole-row select (gutter click);
  whole-column select (header click); Cmd+A select-all. A selection is just two corner indices — O(1) to
  hold, O(visible) to draw — so there is NO arbitrary row/col count cap; Cmd+A may select the whole
  document. The COST is bounded at COPY, not at selection (below).
- **Copy = lossless, BYTE-bounded (not count-bounded).** Bytes bound cost, counts don't (a 10k×1k
  selection is ~100 MB of tiny cells or tens of GB of large ones). So Copy fetches cells row-major
  off-thread, accumulating TSV until a **~64 MiB byte budget** (a tunable frontend constant — no OS
  clipboard imposes a hard cap; this is our memory/fetch/paste-target sanity bound), then truncates +
  shows a notice ("Copied the first ~64 MB — M rows"). A **cell-count safety valve** also caps the number
  of fetches so a pathological all-EMPTY huge selection (≈0 bytes, 100M cells) can't do O(rows) fetches.
  Each cell is copied COMPLETE (lossless) up to a ~1 MiB/cell cap via a NEW bounded full-cell read
  accessor in the core — not the 4 KiB display bytes.
- **Columns = resize + auto-fit.** Drag the trailing edge to resize; double-click the edge to auto-fit;
  a manually-set width sticks (overrides the automatic content-grow) for the session.

## Constraints (the crux — bounded, never blocks)
- **UI never blocks.** Selection is pure INDEX-space state (anchor + active rect in row/col indices) —
  O(1), no materialization. Copy of up to 10M cells fetches + builds the clipboard payload OFF the main
  thread, with a subtle progress affordance; the UI stays live. Auto-fit measures only the VISIBLE window
  (never O(rows)). Nothing here adds per-frame O(rows/cols) cost.
- **Bounded copy cost (byte-first).** Selection extent is unbounded (index-space, O(1)); the COPY is what's
  bounded: fetch row-major until the **~64 MiB byte budget** OR a **cell-count safety cap** (whichever
  first), then truncate + a brief native notice. Copy runs OFF the main thread. This bounds fetch time +
  clipboard/memory + paste-target load regardless of cell sizes — the byte-budgeting used everywhere else.
- **Works across the frontier / column window.** Selecting rows ahead of the scan frontier or columns
  outside the current column window is fine (index-space); Copy materializes the selected range bounded,
  advancing the frontier as needed (like a jump), never re-lexing giant rows unbounded (reuse the
  huge-row per-row cap).
- **Reuse, don't reinvent.** Selection highlight reuses the `SheetCellHighlight` accent-fill/border style
  already drawn for find matches (chromeless aesthetic). Column widths ride the existing
  `columnWidths`/`ColumnLayouting` machinery — a manual width is an explicit per-column override the
  auto-grow respects.
- **api/ addition is root-planner.** The bounded full-cell accessor crosses the frozen ABI → the ROOT
  planner freezes `api/lesssheet.h` + `backend/contracts`; the backend implements it. Frontend selection/
  copy/resize is macOS-only.

## Design direction (planners work out the mechanism)
- **SelectionModel** (frontend): `anchor` + `active` cell (row,col indices) → a normalized rect, clamped to
  the cap; whole-row/col = a rect spanning the capped extent; Cmd+A = the capped extent from the origin.
  NSTableView gains first-responder + mouse (down/drag/up, shift-click) + keyboard (arrows, shift-arrows,
  Cmd+A, Cmd+C) handling; gutter/header views handle row/column select. `SheetRowView.draw` renders the
  selection overlay from the model (reusing the highlight fill + a range border); O(visible cells).
- **Copy** (frontend + the new accessor): Cmd+C snapshots the selection rect, then OFF the main thread
  fetches each cell via the new bounded full-cell accessor and builds a TSV payload (tab between columns,
  newline between rows; a cell containing tab/newline/quote is quoted per the Excel/Numbers TSV
  convention), setting both a TSV type and a plain-string type on `NSPasteboard`. A subtle progress/notice
  for large copies; on completion the UI is untouched (no scroll/selection change). Single cell → the raw
  value.
- **Bounded full-cell accessor** (ROOT api/ + backend): read a cell's COMPLETE content into a caller
  buffer up to `max_bytes` (caller passes ~1 MiB), returning the byte length + a `truncated` flag if the
  cell exceeds `max_bytes`. O(min(cell bytes, max_bytes)); reads from the mmap; on the caller thread
  (bounded) or the copy worker. Default shape: `ls_cell_copy(doc, row, col, buf, buf_len, out_len,
  out_truncated)` (root planner finalizes the exact signature). NO change to `ls_cell`'s display-cap
  contract.
- **Column resize/auto-fit** (frontend): a hit zone over each column's trailing hairline; drag sets an
  explicit `manualWidth[col]` that `growColumnWidthsToFitWindow` treats as a floor-and-ceiling (never
  auto-overrides a manual width); double-click clears the manual width and auto-fits to the VISIBLE
  window's content for that column (exact fit, O(visible rows)). Manual widths are session-scoped
  (in-memory), keyed by absolute column index. O(1) per resize (no all-column relayout — rides the
  column-window offsets).

## Acceptance criteria (testable)
1. **Selection interactions:** click selects a cell; drag / shift-click / shift-arrow extend a rectangular
   range; arrow keys move the single selection; gutter click selects a whole (capped) row, header click a
   whole (capped) column; Cmd+A selects the capped extent. Frozen tests on the SelectionModel (pure,
   deterministic — the geometry/clamping) + the grid event routing.
2. **Copy is BYTE-bounded + honest:** copy fetches row-major and stops at the ~64 MiB budget (a tunable
   constant) OR the cell-count safety cap; if the selection exceeds it, the clipboard holds the portion
   that fit + a notice states what was copied ("first ~64 MB — M rows"). Selection itself is unbounded
   index-space (Cmd+A on a synthetic 100M×100k doc holds the whole rect, O(1); only copy is bounded).
   Frozen tests: the copy builder stops at the byte budget AND at the cell-count safety (all-empty huge
   selection) and reports truncation.
3. **Copy is lossless + correct:** Cmd+C on a range writes TSV (correct row/col order, standard quoting for
   embedded tab/newline/quote) + a plain-string rep; a cell longer than the 4 KiB display cap is copied
   COMPLETE up to the ~1 MiB full-cell cap (verified against a >4 KiB cell); single-cell copy = the raw
   value. Frozen tests: the new backend accessor (full cell up to cap + truncated flag) + the macOS TSV
   builder (quoting, ordering) + an end-to-end copy of a >4 KiB cell.
4. **Copy is non-blocking:** a budget-filling copy does not block the UI thread (runs off-main) and
   completes in bounded time. Frozen/probe test: the copy worker is off-main and the main thread stays
   responsive during a max (budget-filling) copy.
5. **Column resize + auto-fit:** dragging a column's trailing edge changes only that column's width
   (O(1), other columns unmoved); a manual width persists for the session and is NOT overridden by
   auto-grow; double-click auto-fits to the visible window (O(visible rows)), never O(rows). Frozen tests
   on the width model + the resize/auto-fit logic.
6. **No regression / bounded at scale:** find highlights, the column window, cold-start (< 500 ms),
   landing (< 100 ms), and steady memory (O(viewport)) are unchanged; selection/copy/resize add no
   per-frame O(rows/cols) cost. All existing tests green.
7. **Gates green** (backend + macOS + root); the `api/` addition is frozen by the root planner with the
   backend accessor + its behavior test.

## Contract surface (planners freeze) — MULTI-COMPONENT
- **ROOT `api/lesssheet.h` + `backend/contracts`:** the bounded full-cell read accessor (+ its constant if
  any). Root-planner pass; backend implements + a backend behavior test (full cell up to cap, truncated
  flag, borrow/threading rules).
- **macOS `apps/macos/Sources/Contracts` + `Tests`:** a `Selecting` / `ColumnSizing` protocol (pure,
  testable geometry/clamping + the TSV builder) frozen in Contracts; frozen tests for AC1–5. The
  `DocumentSession` may gain a bounded full-cell read wrapper mirroring the api accessor (additive).
- **Frontend impl:** `NativeGrid.swift` (event routing, selection overlay draw, resize hit zone) +
  `ViewerModel.swift` (selection state, async copy, manual widths) + the Contracts logic impls.

## Cap model (RESOLVED 2026-07-10)
Unbounded index-space selection + a **~64 MiB byte-budget copy** (a tunable frontend constant) + a
cell-count safety cap. Rationale: bytes bound cost, counts don't; and no OS clipboard imposes a hard size
limit (macOS `NSPasteboard`, Linux X11 `INCR`/Wayland streaming, Windows `HGLOBAL` are all memory-bound),
so the budget is our own memory/fetch/paste-target sanity bound, portable across future frontends. Copy is
async with an instant result for small selections + a subtle "Copying…"/"Copied first N MB" notice for
large ones. Clipboard format: TSV with Excel/Numbers-style quoting + a plain-string rep.

## Open questions
None — cap model, copy UX, and clipboard format are decided above.
