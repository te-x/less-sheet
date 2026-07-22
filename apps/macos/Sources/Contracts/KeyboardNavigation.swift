// Keyboard cell-navigation — the PURE, display-free heart of the macOS
// keyboard-nav slice (ARCH-macos-kbdnav), layered exactly like `Selecting` /
// `SelectionModel`: no AppKit, no pixels, no running app — only the
// deterministic geometry the gate can verify headlessly. Three small,
// orthogonal contracts live here; each has a `LessSheetKit` implementation
// pinned by a frozen conformance test, and the frontend (`SheetTableView`
// key routing, `NativeGridController` clip scroll, `SheetRowView` outline
// paint) is the only display-dependent residue (human GUI pass H1–H4):
//
//  - `KeyboardNavigating` — a navigation command → the new `Selection`, built
//    by COMPOSING the frozen `Selecting` (never re-implementing its clamp or
//    anchor/active algebra). This is the target-cell layer over the ONE shared
//    selection; there is no parallel cursor state (ARCH Decision 2).
//  - `RevealScrolling` — the minimal-reveal auto-scroll arithmetic: an active
//    cell + a per-axis viewport descriptor → the minimum new clip origin (or
//    no move). Pure `landOn`-style clamp math, byte-exact (ARCH FR2).
//  - `EscapeResolving` — the Esc-precedence decision (dismiss-popups >
//    cancel-copy > clear-selection > nothing) as one pure truth table, so
//    `handleEscape` dispatches on it rather than duplicating the branch logic
//    (ARCH FR3 / Decision 2).
//
// NOTHING here amends the frozen `Selecting`/`Selection` surface, and this is
// a NEW `Sources/Contracts` file — it edits neither AC23-pinned file
// (`api/lesssheet.h`, `Sources/Contracts/ColumnPanel.swift`).

// MARK: - Keyboard navigation (FR1)

/// A single logical keyboard-navigation command over the shared selection.
/// Every case affects EXACTLY ONE axis — a row target OR a column target,
/// never both — which is what keeps the reducer's target computation two small
/// independent switches. The physical-key → command mapping (arrows, Page
/// Up/Down, Home/End, Cmd+arrows, and their `…AndModifySelection:` variants)
/// is a display-layer routing detail verified against AppKit
/// (`interpretKeyEvents`, ARCH Decision 4); this enum is that mapping's target.
public enum NavigationMotion: Sendable, Equatable, CaseIterable {
    /// ↑ — active corner up one row (column kept). Named to match the frozen
    /// `SelectionDirection.upward`.
    case upward
    /// ↓ — active corner down one row (column kept).
    case down
    /// ← — active corner to the adjacent VISIBLE column to the left (row kept).
    case left
    /// → — active corner to the adjacent VISIBLE column to the right (row kept).
    case right
    /// Page Up — active corner up one page of rows (column kept).
    case pageUp
    /// Page Down — active corner down one page of rows (column kept).
    case pageDown
    /// Home / Cmd+↑ — active corner to the FIRST row (row 0; column kept).
    case documentStart
    /// End / Cmd+↓ — active corner to the LAST row (`lastRow`; column kept).
    case documentEnd
    /// Cmd+← — active corner to the FIRST visible column (row kept).
    case lineStart
    /// Cmd+→ — active corner to the LAST visible column (row kept).
    case lineEnd
}

/// The frontend-supplied context a navigation command resolves against — the
/// state the app already computes each tick, handed to the pure reducer so all
/// visibility / page / seed knowledge lives in one place. Value type, so a
/// command is a pure function of `(selection, motion, extending, context)`.
public struct NavigationContext: Sendable, Equatable {
    /// The current selectable extent (the FILTERED row count while a filter is
    /// active, like every other row index) — the clamp domain, shared with the
    /// frozen `Selecting`.
    public let extent: GridExtent
    /// The ordered ASCENDING absolute indices of the non-hidden columns
    /// (`DocumentModel.visibleColumns`). Column stepping and the line-end
    /// commands walk THIS list, so a hidden column is never a cursor stop
    /// (Q3). Empty exactly when the extent has no columns.
    public let visibleColumns: [Int]
    /// The data row currently at the TOP of the unobscured viewport
    /// (`currentTopDataRow`) — the row of the seed cell.
    public let topVisibleRow: UInt64
    /// The absolute column currently at the LEADING edge of the viewport (the
    /// column window's first column) — the column of the seed cell. Always a
    /// member of `visibleColumns` (only visible columns are ever on screen).
    public let firstVisibleColumn: Int
    /// Data rows per Page Up/Down step (derived once from the live viewport
    /// height and `rowHeight`); ≥ 1 in practice.
    public let pageRows: UInt64

    public init(extent: GridExtent, visibleColumns: [Int], topVisibleRow: UInt64,
                firstVisibleColumn: Int, pageRows: UInt64) {
        self.extent = extent
        self.visibleColumns = visibleColumns
        self.topVisibleRow = topVisibleRow
        self.firstVisibleColumn = firstVisibleColumn
        self.pageRows = pageRows
    }
}

/// The pure keyboard-navigation reducer (ARCH-macos-kbdnav FR1 / Decisions 1–2).
/// Implemented in `LessSheetKit` as `KeyboardNavigator`, pinned by a frozen
/// conformance test (`let _: any KeyboardNavigating = KeyboardNavigator()`),
/// exactly like `Selecting`/`SelectionModel`.
///
/// `navigate` computes a TARGET cell for the command and produces the new
/// selection by delegating the final geometry to the frozen `Selecting`
/// (`select` to collapse, `extend(_:to:in:)` to shift-extend) — it re-implements
/// NEITHER the clamp NOR the anchor/active algebra (Decision 2). Pinned
/// semantics:
///
/// - **Empty extent / no visible columns** → `nil` (nothing is selectable),
///   matching the frozen `Selecting` producing-ops. Every command, extending
///   or not, is a no-op here.
/// - **Seed (no step).** With `selection == nil`, ANY command (including the
///   extending variants — there is no anchor to extend from yet) returns a 1×1
///   selection at `(topVisibleRow, firstVisibleColumn)` and applies NO step
///   (Q1).
/// - **Row commands** (`upward`/`down`/`pageUp`/`pageDown`/`documentStart`/
///   `documentEnd`) move the active corner in row space and KEEP its column.
/// - **Column commands** (`left`/`right`/`lineStart`/`lineEnd`) move the active
///   corner over the VISIBLE columns and KEEP its row; a hidden column is never
///   a target.
/// - **Visible-column resolution.** The active corner's column is first resolved
///   into `visibleColumns` so the RESULT is ALWAYS a visible column (never an
///   invisible cursor): a column already visible is itself; a hidden active
///   column — reachable only via Cmd+A / whole-row / whole-column select, which
///   this reducer does not produce — snaps to the nearest visible column at or
///   below it (else the first visible column). Row commands then keep this
///   resolved column; column commands step from it.
/// - **`extending`** keeps the anchor and moves only the active corner (the rect
///   grows/shrinks and MAY span hidden columns — they are included in the rect
///   and copy exactly as a mouse drag does today; copy is visibility-blind, Q3).
/// - **Clamping.** No non-nil result leaves `0…lastRow` × `visibleColumns` (a
///   step past an edge stays on the edge); the frozen `Selecting` performs the
///   final extent clamp.
public protocol KeyboardNavigating: Sendable {
    func navigate(from selection: Selection?, _ motion: NavigationMotion,
                  extending: Bool, in context: NavigationContext) -> Selection?
}

// MARK: - Minimal-reveal auto-scroll (FR2)

/// Vertical (row-space) reveal inputs — mirrors `landOn`'s clamp exactly. The
/// active row occupies content-y `[activeRow · rowHeight, activeRow · rowHeight
/// + rowHeight)`; the UNOBSCURED data area (below the glass band) is
/// `[originY + contentInsetTop, originY + viewportHeight)`; a revealed origin
/// clamps to `[-contentInsetTop, maxY]`. All fields are the exact values the
/// grid already computes for `landOn` / `currentTopDataRow`.
public struct VerticalReveal: Sendable, Equatable {
    public let activeRow: UInt64
    public let rowHeight: Double
    public let contentInsetTop: Double
    public let originY: Double
    public let viewportHeight: Double
    public let maxY: Double

    public init(activeRow: UInt64, rowHeight: Double, contentInsetTop: Double,
                originY: Double, viewportHeight: Double, maxY: Double) {
        self.activeRow = activeRow
        self.rowHeight = rowHeight
        self.contentInsetTop = contentInsetTop
        self.originY = originY
        self.viewportHeight = viewportHeight
        self.maxY = maxY
    }
}

/// Horizontal (pixel-space) reveal inputs. The active column occupies
/// `[leftX, leftX + width)` in the table's content x; the viewport shows
/// `[originX, originX + viewportWidth)`; a revealed origin clamps to `[0, maxX]`.
/// `leftX` is a prefix-sum the grid computes (columns have variable widths), so
/// unlike the vertical axis it is a pixel, not an index × height.
public struct HorizontalReveal: Sendable, Equatable {
    public let leftX: Double
    public let width: Double
    public let originX: Double
    public let viewportWidth: Double
    public let maxX: Double

    public init(leftX: Double, width: Double, originX: Double,
                viewportWidth: Double, maxX: Double) {
        self.leftX = leftX
        self.width = width
        self.originX = originX
        self.viewportWidth = viewportWidth
        self.maxX = maxX
    }
}

/// The resolved clip origin after a minimal reveal. `originX`/`originY` are the
/// NEW clip origin — equal to the current one on an axis that did not need to
/// move; `movedX`/`movedY` say whether that axis actually changed (each axis is
/// independent). The grid applies a clip scroll only when `moved`.
public struct RevealScroll: Sendable, Equatable {
    public let originX: Double
    public let originY: Double
    public let movedX: Bool
    public let movedY: Bool

    public init(originX: Double, originY: Double, movedX: Bool, movedY: Bool) {
        self.originX = originX
        self.originY = originY
        self.movedX = movedX
        self.movedY = movedY
    }

    /// Whether either axis moved (the viewport does not scroll when false).
    public var moved: Bool { movedX || movedY }
}

/// The pure minimal-reveal auto-scroll math (ARCH-macos-kbdnav FR2 / Decision 1).
/// Implemented in `LessSheetKit` as `RevealScroller`, pinned by a frozen
/// conformance test. Reuses the existing clip-scroll path — no `reloadData`,
/// no relayout, O(1).
///
/// Pinned semantics (per axis, independently): if the active cell is already
/// fully visible on that axis the origin is UNCHANGED (`moved…` false); if it
/// sits past the leading edge (under the band / off the left) the origin scrolls
/// so the cell's leading edge clears the inset; if it sits past the trailing
/// edge (below / off the right) the origin scrolls so the cell's trailing edge
/// meets the viewport edge; the result is clamped to the axis bounds
/// (`[-contentInsetTop, maxY]` vertically, `[0, maxX]` horizontally). Row-by-row
/// / column-by-column scrolling emerges naturally at the edges.
public protocol RevealScrolling: Sendable {
    func reveal(vertical: VerticalReveal, horizontal: HorizontalReveal) -> RevealScroll
}

// MARK: - Escape precedence (FR3)

/// The three Esc-relevant facts, in priority order. `popupOrSearchActive` folds
/// "a find/jump/dialect popup is open" and "a search is active" (the current
/// `handleEscape` checks `anyPopupOpen || findFieldActive`); `copyInFlight` is a
/// running streaming copy; `hasSelection` is a live selection/cursor.
public struct EscapeContext: Sendable, Equatable {
    public let popupOrSearchActive: Bool
    public let copyInFlight: Bool
    public let hasSelection: Bool

    public init(popupOrSearchActive: Bool, copyInFlight: Bool, hasSelection: Bool) {
        self.popupOrSearchActive = popupOrSearchActive
        self.copyInFlight = copyInFlight
        self.hasSelection = hasSelection
    }
}

/// The single Esc action to take. The frontend maps each case to its existing
/// behavior: `dismissPopups` → `dismissPopups()`; `cancelCopy` → `cancelCopy()`;
/// `clearSelection` → `clearSelection()`; `none` → beep/forward (do nothing).
public enum EscapeAction: Sendable, Equatable {
    case dismissPopups
    case cancelCopy
    case clearSelection
    case none
}

/// The pure Esc-precedence resolver (ARCH-macos-kbdnav FR3 / Decision 2).
/// Implemented in `LessSheetKit` as `EscapeResolver`, pinned by a frozen
/// conformance test. `handleEscape` calls `resolve` and dispatches on the
/// action — the branch order lives HERE, once.
///
/// Pinned truth table (strict priority; higher wins regardless of the lower
/// facts):
/// 1. `popupOrSearchActive` → `.dismissPopups`
/// 2. else `copyInFlight` → `.cancelCopy`
/// 3. else `hasSelection` → `.clearSelection`
/// 4. else → `.none`
public protocol EscapeResolving: Sendable {
    func resolve(_ context: EscapeContext) -> EscapeAction
}
