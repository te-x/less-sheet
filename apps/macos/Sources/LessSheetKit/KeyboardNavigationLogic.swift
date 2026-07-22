import Contracts

// RED SEED (planner freeze) — the pure keyboard-navigation logic
// (ARCH-macos-kbdnav). Each type CONFORMS to its frozen `Contracts` protocol so
// the tree COMPILES and the conformance pins hold, but the bodies return
// trivial results — so every behavior test (G1–G7) fails on BEHAVIOR, never on
// compile/import, exactly like the original SelectCopyLogic seed.
//
//   KeyboardNavigator ... returns the incoming selection UNCHANGED (so a seed
//     yields nil instead of the top-left cell, and no command moves/collapses).
//   RevealScroller ...... always reports NO move at the current origin (so every
//     off-screen cell fails the "should scroll" assertions).
//   EscapeResolver ...... always returns `.none` (so the precedence truth table
//     fails on every row that should act).
//
// RED → GREEN (implementer): implement the three per the `Contracts`
// doc-comments — `KeyboardNavigator` COMPOSING the injected `Selecting`
// (`select` / `extend(_:to:in:)`, never re-implementing its algebra), the 1-D
// minimal-reveal clamp on each axis, and the Esc precedence — then wire the App
// (key routing, clip scroll, outline paint, and `handleEscape` dispatching on
// `EscapeResolver`). No frozen path changes.

// MARK: - KeyboardNavigating (FR1)

/// The target-cell reducer over the ONE shared selection. Holds a `Selecting`
/// (default `SelectionModel`) and produces every result through it, so there is
/// a single source of selection geometry.
public struct KeyboardNavigator: KeyboardNavigating {
    private let selecting: any Selecting

    public init(selecting: any Selecting = SelectionModel()) {
        self.selecting = selecting
    }

    public func navigate(from selection: Selection?, _ motion: NavigationMotion,
                         extending: Bool, in context: NavigationContext) -> Selection? {
        // SEED: trivially returns the input unchanged (nil → nil) instead of the
        // top-left seed cell / a stepped-or-extended selection.
        selection
    }
}

// MARK: - RevealScrolling (FR2)

/// The minimal-reveal auto-scroll math.
public struct RevealScroller: RevealScrolling {
    public init() {}

    public func reveal(vertical: VerticalReveal, horizontal: HorizontalReveal) -> RevealScroll {
        // SEED: never scrolls — reports the current origin with no move on either
        // axis, so the off-screen reveal cases (which must move) all fail.
        RevealScroll(originX: horizontal.originX, originY: vertical.originY,
                     movedX: false, movedY: false)
    }
}

// MARK: - EscapeResolving (FR3)

/// The Esc-precedence resolver.
public struct EscapeResolver: EscapeResolving {
    public init() {}

    public func resolve(_ context: EscapeContext) -> EscapeAction {
        // SEED: always "do nothing", so every acting row of the precedence truth
        // table fails.
        .none
    }
}
