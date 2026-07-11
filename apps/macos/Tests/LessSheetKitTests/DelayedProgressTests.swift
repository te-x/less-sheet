// Frozen behavior tests — stream-copy slice (planner-owned), the PROGRESS half
// (ARCH-stream-copy win #2 / AC8 + AC9): the reusable "subtle progress after
// ~500 ms" gate `DelayedProgressGating` (implemented in LessSheetKit as
// `DelayedProgressGate`). Same pattern as SelectCopyTests: the pure, no-GUI,
// gate-stable heart is pinned HERE; pixels + the real clock + the actual
// index/jump/filter wiring live in the App / Kit driver (not importable by
// tests) and are the build cell's concern.
//
// HERMETIC — no real wall-clock in the logic (ARCH AC8): the gate reads no
// clock; the driver injects `elapsed`. Every test below feeds the gate a
// controlled `OperationState` and asserts the show/hide decision — deterministic,
// never timing-flaky.
//
// ACCURACY IS A NON-GOAL (ARCH scope + AC8): the indicator conveys "working
// through a lot of data," not a fraction. `ProgressIndication` carries no
// percentage and these tests pin none — on purpose.
//
// WHAT EACH TEST PINS
//   delayedProgressConformancePin ............ signature drift fails the build.
//   AC8 indicatorAppearsOnlyPastThreshold .... visible iff running >= threshold;
//        sub-threshold shows nothing (no flicker).
//   AC8 hiddenOnCompletionOrCancel ........... a settled op (done OR cancelled)
//        shows nothing, however long it ran.
//   AC8 cancelOfferedWhenVisibleAndCancellable  cancel accompanies the indicator
//        iff visible AND the op is cancellable; never when hidden.
//   AC9 thresholdIsASaneAboutFiveHundredMs ... the shared threshold is ~500 ms
//        (a band, not the magic value).
//   AC8 copyProgressAppearsPastThresholdWithCancel  COPY uses the gate: a copy
//        past ~500 ms is visible WITH cancel; a sub-threshold copy shows nothing;
//        gone when the copy settles.
//   AC9 jumpSurfacesProgressPastThreshold / filterSurfacesProgressPastThreshold
//        the existing long ops surface through the SAME gate within ~500 ms
//        ("just wiring"); the AC9 AUDIT NOTE (index/jump/filter/open status) is
//        the implementer's doc deliverable, not a test.
//
// RED SEED (planner freeze) — RED on BEHAVIOR, never compile/import: the Kit
// seed `DelayedProgressGate.indication(for:)` returns `.hidden` for every state,
// so every "appears / surfaces / offers cancel" assertion fails (expects a
// visible indicator, gets hidden) while the tree compiles (the conformance
// holds); the "sub-threshold / settled → hidden" assertions are green-by-
// construction (the no-regression half). The seed `threshold` is a real ~500 ms,
// so the band pin holds from the seed.
//
// RED → GREEN (implementer): implement `indication(for:)` per the protocol
// doc-comment and wire copy (with its cancel) + index/jump/filter through the
// one gate; record the AC9 audit note. No frozen path changes.
import Testing
import Contracts
import LessSheetKit

@Suite("delayed-progress gate (pure)")
struct DelayedProgressTests {

    // Frozen conformance: the Kit type still satisfies the frozen signature.
    @Test func delayedProgressConformancePin() {
        let _: any DelayedProgressGating = DelayedProgressGate()
    }

    // AC8 — the indicator appears ONLY once a running operation has exceeded the
    // threshold; a sub-threshold operation shows nothing (no flicker). RED: the
    // seed returns `.hidden` even past the threshold.
    @Test func indicatorAppearsOnlyPastThreshold() {
        let gate = DelayedProgressGate()
        let t = gate.threshold

        // Sub-threshold → hidden (green-by-construction with the seed).
        #expect(gate.indication(for: .running(elapsed: .zero, cancellable: true)) == .hidden)
        #expect(gate.indication(for: .running(elapsed: t - .milliseconds(1), cancellable: true)) == .hidden)

        // At / past the threshold → visible (RED: seed returns hidden).
        #expect(gate.indication(for: .running(elapsed: t, cancellable: true)).isVisible)
        #expect(gate.indication(for: .running(elapsed: t + .milliseconds(1), cancellable: true)).isVisible)
        #expect(gate.indication(for: .running(elapsed: .seconds(30), cancellable: true)).isVisible)
    }

    // AC8 — a SETTLED operation (completed OR cancelled) shows nothing, however
    // long it ran (gone on completion/cancel). Green-by-construction with the
    // seed; load-bearing once the gate can show anything.
    @Test func hiddenOnCompletionOrCancel() {
        let gate = DelayedProgressGate()
        #expect(gate.indication(for: .settled) == .hidden)
        // Even after a long run, once settled there is no chrome to keep.
        // (.settled models both "completed" and "cancelled" — both hide.)
    }

    // AC8 — the cancel affordance accompanies the indicator IFF it is visible AND
    // the operation is cancellable; never when hidden. RED: the seed is hidden,
    // so the "visible + cancel" expectation fails.
    @Test func cancelOfferedWhenVisibleAndCancellable() {
        let gate = DelayedProgressGate()
        let t = gate.threshold

        // Visible + cancellable → cancel offered.
        let cancellable = gate.indication(for: .running(elapsed: t, cancellable: true))
        #expect(cancellable.isVisible)
        #expect(cancellable.offersCancel)

        // Visible + NOT cancellable → no cancel.
        let notCancellable = gate.indication(for: .running(elapsed: t, cancellable: false))
        #expect(notCancellable.isVisible)
        #expect(!notCancellable.offersCancel)

        // Hidden → never offers cancel (green-by-construction).
        #expect(!gate.indication(for: .running(elapsed: .zero, cancellable: true)).offersCancel)
    }

    // AC9 — the ONE shared threshold is a sane ~500 ms ("subtle progress after
    // ~500 ms" / "within ~500 ms"): a band, not the magic exact value. Holds from
    // the seed (a real threshold); guards against a nonsense value (10 ms / 5 s).
    @Test func thresholdIsASaneAboutFiveHundredMs() {
        let t = DelayedProgressGate().threshold
        #expect(t >= .milliseconds(300))
        #expect(t <= .milliseconds(800))
    }

    // AC8 — COPY uses the gate: a copy still running past ~500 ms shows a subtle
    // indicator WITH cancel (copy carries Task/Esc/Cancel); a sub-threshold copy
    // shows nothing; it is gone once the copy settles (completes or is cancelled).
    // RED: the seed never shows the running-past-threshold indicator.
    @Test func copyProgressAppearsPastThresholdWithCancel() {
        let gate = DelayedProgressGate()
        let t = gate.threshold

        // A fast copy (finished under the threshold) → nothing.
        #expect(gate.indication(for: .running(elapsed: t - .milliseconds(1), cancellable: true)) == .hidden)

        // A long copy → subtle indicator WITH cancel.
        let running = gate.indication(for: .running(elapsed: t + .milliseconds(50), cancellable: true))
        #expect(running.isVisible)
        #expect(running.offersCancel)

        // Copy done / cancelled → indicator gone.
        #expect(gate.indication(for: .settled) == .hidden)
    }

    // AC9 — JUMP surfaces progress through the SAME gate within ~500 ms ("just
    // wiring" of the existing jump poll). RED: the seed never surfaces it.
    @Test func jumpSurfacesProgressPastThreshold() {
        let gate = DelayedProgressGate()
        let t = gate.threshold
        // A jump scanning past the threshold surfaces (jump carries a cancel).
        #expect(gate.indication(for: .running(elapsed: t + .milliseconds(50), cancellable: true)).isVisible)
        // A jump that lands under the threshold shows nothing.
        #expect(gate.indication(for: .running(elapsed: t - .milliseconds(1), cancellable: true)) == .hidden)
        // Landed → gone.
        #expect(gate.indication(for: .settled) == .hidden)
    }

    // AC9 — FILTER-scan surfaces progress through the SAME gate within ~500 ms.
    // (A filter is a persistent view mode, so its indicator need not offer an
    // explicit cancel — we pin only that it SURFACES, not the cancel affordance.)
    // RED: the seed never surfaces it.
    @Test func filterSurfacesProgressPastThreshold() {
        let gate = DelayedProgressGate()
        let t = gate.threshold
        #expect(gate.indication(for: .running(elapsed: t + .milliseconds(50), cancellable: false)).isVisible)
        #expect(gate.indication(for: .running(elapsed: t - .milliseconds(1), cancellable: false)) == .hidden)
        #expect(gate.indication(for: .settled) == .hidden)
    }
}
