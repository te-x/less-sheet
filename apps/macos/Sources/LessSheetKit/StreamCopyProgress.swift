import Contracts

// RED SEED (planner freeze) — the reusable delayed-progress gate
// (ARCH-stream-copy AC8/AC9), implementer-owned and NON-frozen
// (Sources/LessSheetKit). Conforms to the frozen `DelayedProgressGating`
// protocol; the App drives it with a real clock (copy's run time, and the
// existing index/jump/filter poll ages) and renders a subtle, Reduce-Motion-
// respecting indicator from the returned `ProgressIndication`. None of this
// touches a frozen path.
//
// RED on BEHAVIOR, never compile/import: `indication(for:)` returns `.hidden`
// for EVERY state, so NOTHING ever surfaces — the "appears past ~500 ms",
// "offers cancel", and "jump/filter surface progress" tests fail on behavior
// (they expect a visible indicator; they get hidden), while the tree still
// compiles (the conformance holds) and the "sub-threshold / settled show
// nothing" tests are green-by-construction (a no-regression half, like the
// select-copy structural greens). The `threshold` is a real ~500 ms so the
// "sane threshold" band pin holds from the seed.
//
// RED → GREEN (implementer): implement `indication(for:)` per the protocol
// doc-comment (visible iff running and elapsed >= threshold; offersCancel iff
// visible and cancellable; hidden when settled or sub-threshold), build the
// subtle indicator view + wire COPY's run time (AC8, with its existing cancel)
// and the existing long ops (index / jump-scan / filter-scan — AC9 "just
// wiring") through this ONE gate, and record the AC9 AUDIT NOTE (every long
// operation's status: already-compliant / wired-here / fast-follow). No frozen
// path changes.
public struct DelayedProgressGate: DelayedProgressGating {
    public let threshold: Duration

    /// Default threshold: subtle-after-~500 ms (tunable; the frozen tests pin the
    /// behavior + a sane ~500 ms band, never this exact value).
    public init(threshold: Duration = .milliseconds(500)) {
        self.threshold = threshold
    }

    public func indication(for state: OperationState) -> ProgressIndication {
        // SEED: never surfaces — RED for every "appears / surfaces" assertion.
        _ = state
        return .hidden
    }
}
