import AppKit
import Foundation

// The HOLD-TO-ACCELERATE half of the jump-field arrow verification (the single-tap
// half lives in JumpStepProbe.swift, same LESSSHEET_JUMP_STEP hook). Three layers,
// because the ramp's failure mode — staying accelerated into the user's next tap —
// is the worst thing this feature could do:
//
//   1. the tier table and the hold state machine at SYNTHETIC instants, so every
//      threshold and both resets are exact rather than sampled;
//   2. the wrap / clamp at every step size, so a step of 1000 near an end cannot
//      jump over it;
//   3. two REAL holds against the live model and the real clock, pressed at this
//      Mac's auto-repeat cadence — one proving the release reset with no gap, one
//      proving the gap reset with NO release (the swallowed key-up path).

extension JumpStepProbe {
    /// This Mac's measured auto-repeat interval (~11 presses/second).
    static let repeatInterval: Duration = .milliseconds(90)
    /// Long enough to reach the top tier: 3.4 s ≈ 38 presses.
    static let fullHoldMs = 3400
    /// Long enough to reach the step-10 tier only (~1.15 s).
    static let shortHoldMs = 1150
    /// A pause longer than `JumpFieldRamp.holdLapse`.
    static let lapsedGap: Duration = .milliseconds(350)

    static func rampPhase(_ model: DocumentModel) {
        rampTiers()
        rampHoldStateMachine()
        rampBigStepWraps()
        realHold(model)
    }

    // MARK: - 1. Tiers + the hold state machine (synthetic instants)

    /// the author's ramp, read straight off the resolver at each boundary and just
    /// inside it: <1 s step 1, <2 s step 10, <3 s step 100, ≥3 s step 1000.
    static func rampTiers() {
        let probes: [(held: Duration, want: UInt64)] = [
            (.zero, 1), (.milliseconds(999), 1),
            (.seconds(1), 10), (.milliseconds(1999), 10),
            (.seconds(2), 100), (.milliseconds(2999), 100),
            (.seconds(3), 1000), (.seconds(10), 1000)
        ]
        expect("ramp_tiers",
               probes.map { String(JumpFieldRamp.magnitude(held: $0.held)) }.joined(separator: ","),
               probes.map { String($0.want) }.joined(separator: ","),
               extra: "held_ms=0,999,1000,1999,2000,2999,3000,10000")
    }

    /// The state machine at synthetic instants: a 90 ms repeat stream walks the
    /// tiers in order, a release drops it back to step 1, a gap longer than
    /// `holdLapse` drops it back to step 1 WITHOUT any release, and a gap shorter
    /// than `holdLapse` is still the same hold (a real repeat must not be cut off).
    static func rampHoldStateMachine() {
        let base = ContinuousClock().now
        var ramp = JumpFieldRamp()
        var tiers: [UInt64] = []
        var crossedAt: [UInt64: Int] = [:]
        var lastMs = 0
        for press in 0...38 {
            lastMs = press * 90
            let magnitude = ramp.magnitude(pressedAt: base + .milliseconds(lastMs), going: .towardEnd)
            if tiers.last != magnitude {
                tiers.append(magnitude)
                crossedAt[magnitude] = lastMs
            }
        }
        expect("ramp_hold_tiers", tiers.map(String.init).joined(separator: ","), "1,10,100,1000",
               extra: "crossed_at_ms=" + ([1, 10, 100, 1000] as [UInt64])
                   .map { "\($0)@\(crossedAt[$0] ?? -1)" }.joined(separator: ","))
        expect("ramp_hot_at_top",
               String(ramp.magnitude(pressedAt: base + .milliseconds(lastMs), going: .towardEnd)),
               "1000")

        // Reset 1 — the key came up.
        ramp.release()
        expect("ramp_reset_on_release",
               String(ramp.magnitude(pressedAt: base + .milliseconds(lastMs + 90), going: .towardEnd)), "1")

        // Reset 2 — the DANGEROUS path: no release ever arrives, only a gap.
        var hot = JumpFieldRamp()
        for press in 0...38 { _ = hot.magnitude(pressedAt: base + .milliseconds(press * 90), going: .towardEnd) }
        expect("ramp_reset_on_gap_no_release",
               String(hot.magnitude(pressedAt: base + .milliseconds(lastMs) + lapsedGap, going: .towardEnd)), "1")

        // …and a gap UNDER the lapse is the same hold, so a genuine 90 ms repeat
        // stream (or a briefly stuttering one) keeps its acceleration.
        var warm = JumpFieldRamp()
        for press in 0...38 { _ = warm.magnitude(pressedAt: base + .milliseconds(press * 90), going: .towardEnd) }
        expect("ramp_gap_under_lapse_holds",
               String(warm.magnitude(pressedAt: base + .milliseconds(lastMs + 290), going: .towardEnd)), "1000")

        // Reset 3 — the OPPOSITE arrow ends the hold, with no key-up and no gap.
        // This guard came from the GTK implementer, who had it and found this side
        // did not: a swallowed key-up followed within the lapse by the other arrow
        // gave step 1 there and step 1000 here. Both sides now agree on step 1.
        var flip = JumpFieldRamp()
        for press in 0...38 { _ = flip.magnitude(pressedAt: base + .milliseconds(press * 90), going: .towardEnd) }
        expect("ramp_reset_on_direction_flip",
               String(flip.magnitude(pressedAt: base + .milliseconds(lastMs + 20), going: .towardStart)), "1")
        // …and that flip opened a FRESH hold: held for a second IN THE NEW
        // DIRECTION it reaches step 10, on its own clock rather than inheriting the
        // abandoned one. Note this must be a STREAM, not two presses a second
        // apart — my first version asserted the latter and correctly got 1, because
        // a 1 s gap is two taps, not a hold. The lapse is what makes that true.
        var flipMagnitude: UInt64 = 0
        for press in 0...12 {
            flipMagnitude = flip.magnitude(
                pressedAt: base + .milliseconds(lastMs + 20 + press * 90), going: .towardStart)
        }
        expect("ramp_flip_opens_fresh_hold", String(flipMagnitude), "10")
    }

    // MARK: - 2. Wrap + clamp at every step size

    /// A big step snaps to round numbers (the author's 20/30/40 → 200/300/400 →
    /// 2000/3000) and can never overshoot an end: it LANDS on the end, and only a
    /// press made while standing there wraps.
    static func rampBigStepWraps() {
        let bound: UInt64 = 200_000
        let stepDown = JumpFieldStep.towardEnd
        let stepUp = JumpFieldStep.towardStart
        expect("snap_tens", stepDown.applied(from: 12, seed: 1, lastRow: bound, magnitude: 10), "20")
        expect("snap_hundreds", stepDown.applied(from: 130, seed: 1, lastRow: bound, magnitude: 100), "200")
        expect("snap_thousands", stepDown.applied(from: 1300, seed: 1, lastRow: bound, magnitude: 1000), "2000")
        expect("snap_tens_up", stepUp.applied(from: 99, seed: 1, lastRow: bound, magnitude: 10), "90")
        expect("big_step_lands_on_end",
               stepDown.applied(from: 199_500, seed: 1, lastRow: bound, magnitude: 1000), "200000")
        expect("big_step_wraps_at_end",
               stepDown.applied(from: bound, seed: 1, lastRow: bound, magnitude: 1000), "1")
        expect("big_step_lands_on_one",
               stepUp.applied(from: 500, seed: 1, lastRow: bound, magnitude: 1000), "1")
        expect("big_step_wraps_at_one",
               stepUp.applied(from: 1, seed: 1, lastRow: bound, magnitude: 1000), "200000")
        // A step larger than the whole document still stops at its end.
        expect("big_step_short_document",
               stepDown.applied(from: 1, seed: 1, lastRow: 100, magnitude: 1000), "100")
    }

    // MARK: - 3. Two real holds (live model, real clock, real cadence)

    /// Hold ↓ for 3.4 s at the auto-repeat cadence, then check the numbers seen.
    static func realHold(_ model: DocumentModel) {
        model.openJumpField()
        model.jumpFieldText = "1"
        model.endJumpFieldHold()
        hold(model, forMs: fullHoldMs) { samples in
            reportFullHold(model, samples: samples)
            releaseResetInLivePath(model)
        }
    }

    /// Step every `repeatInterval` for `limitMs`, sampling (elapsed, value) at each
    /// press — the auto-repeat stream the OS would deliver to `onKeyPress(.repeat)`.
    static func hold(_ model: DocumentModel, forMs limitMs: Int,
                     then done: @escaping @MainActor ([(ms: Int, value: UInt64)]) -> Void) {
        let clock = ContinuousClock()
        let start = clock.now
        Task { @MainActor in
            var samples: [(ms: Int, value: UInt64)] = []
            while milliseconds(clock.now - start) < limitMs {
                model.stepJumpField(.towardEnd)
                samples.append((milliseconds(clock.now - start), UInt64(model.jumpFieldText) ?? 0))
                try? await Task.sleep(for: repeatInterval)
            }
            done(samples)
        }
    }

    /// Every value a held ↓ passes through must sit on its tier's round multiple
    /// (the two wrap targets excepted), must move forward, and must cover far more
    /// ground than one row per press — the whole point of the ramp.
    private static func reportFullHold(_ model: DocumentModel, samples: [(ms: Int, value: UInt64)]) {
        let bound = max(1, model.jumpRowCountInfo.count)
        let offTier = samples.filter { sample in
            guard sample.value != 1, sample.value != bound else { return false }   // wrap landings
            // ±5 ms of slack at a tier boundary: the value is read just after the
            // step that produced it.
            return ![sample.ms, max(0, sample.ms - 5)]
                .map { JumpFieldRamp.magnitude(held: .milliseconds($0)) }
                .contains { sample.value % $0 == 0 }
        }
        expect("held_values_on_tier", String(offTier.count), "0",
               extra: "presses=\(samples.count) first_off="
                   + (offTier.first.map { "\($0.ms)ms:\($0.value)" } ?? "none"))
        let forward = zip(samples, samples.dropFirst())
            .allSatisfy { $1.value > $0.value || $1.value == 1 || $1.value == bound }
        expect("held_moves_forward", String(forward), "true")
        let reached = samples.last?.value ?? 0
        guard bound >= 100_000 else {
            log("lesssheet.jumpstep.held_beats_step_one skipped rows=\(bound) reached=\(reached)"
                + " presses=\(samples.count) reason=document_too_short_to_hold_without_wrapping")
            return
        }
        expect("held_beats_step_one", String(reached > UInt64(samples.count) * 10), "true",
               extra: "presses=\(samples.count) reached=\(reached)"
                   + " step_one_would_reach=\(samples.count + 1) tiers="
                   + tierTrace(samples))
    }

    /// Where the held run crossed each tier — the numbers for the report.
    private static func tierTrace(_ samples: [(ms: Int, value: UInt64)]) -> String {
        var seen: [UInt64] = []
        var trace: [String] = []
        for sample in samples {
            let magnitude = JumpFieldRamp.magnitude(held: .milliseconds(sample.ms))
            if seen.last != magnitude {
                seen.append(magnitude)
                trace.append("step\(magnitude)@\(sample.ms)ms:row\(sample.value)")
            }
        }
        return trace.joined(separator: ",")
    }

    /// RELEASE reset in the live path: the ramp is hot at step 1000 and the last
    /// press was only one repeat interval ago — far inside `holdLapse` — so the gap
    /// rule cannot be what resets it. Releasing must, and the next tap moves 1 row.
    private static func releaseResetInLivePath(_ model: DocumentModel) {
        let bound = max(1, model.jumpRowCountInfo.count)
        let before = UInt64(model.jumpFieldText) ?? 0
        model.endJumpFieldHold()                       // exactly what `.up` calls
        model.stepJumpField(.towardEnd)
        expect("live_release_reset", model.jumpFieldText, String(before == bound ? 1 : before + 1),
               extra: "before=\(before) gap_ms=0")
        gapResetInLivePath(model)
    }

    /// GAP reset in the live path — the swallowed key-up. Hold until the ramp is
    /// provably hot (step 10), then pause past `holdLapse` and press again WITHOUT
    /// any release: the tap must move exactly one row.
    private static func gapResetInLivePath(_ model: DocumentModel) {
        model.jumpFieldText = "1"
        model.endJumpFieldHold()
        hold(model, forMs: shortHoldMs) { samples in
            let deltas = zip(samples, samples.dropFirst()).map { $1.value &- $0.value }
            let hottest = deltas.max() ?? 0
            let spanMs = (samples.last?.ms ?? 0) - (samples.first?.ms ?? 0)
            // Assert the ramp LEFT step 1; do NOT pin the delta to exactly 10.
            // Two independent reasons, and the second is the fundamental one:
            //   * timing — a 1150 ms target hold is only ~12 presses at this
            //     cadence, so under load the span falls short of the 1 s tier;
            //   * SNAPPING — a step of 10 from row 12 lands on 20, a delta of 8.
            //     With snapping the delta is the distance to the next multiple, so
            //     it is <= the step size and equality can never hold in general.
            // The exact version failed 1 run in 3 and a later run showed
            // hottest_step=8, which is snapping, not load. The synthetic tier checks
            // above pin the boundaries precisely; this one only needs to establish
            // that the live ramp was hot before the gap test runs.
            if spanMs < 1000 {
                log("lesssheet.jumpstep.live_hold_was_hot skipped span_ms=\(spanMs)"
                    + " presses=\(samples.count)"
                    + " reason=hold_never_crossed_the_1s_tier_under_load")
            } else {
                expect("live_hold_was_hot", hottest > 1 ? "hot" : "cold", "hot",
                       extra: "presses=\(samples.count) span_ms=\(spanMs) hottest_step=\(hottest)")
            }
            let before = UInt64(model.jumpFieldText) ?? 0
            after(0.35) {                              // > holdLapse, and NO release
                model.stepJumpField(.towardEnd)
                expect("live_gap_reset_no_release", model.jumpFieldText, String(before + 1),
                       extra: "before=\(before) gap_ms=350 released=false")
                finish()
            }
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
