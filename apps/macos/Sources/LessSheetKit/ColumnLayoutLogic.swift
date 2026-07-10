import Contracts

// Real implementation (ARCH-column-windowing) — replaces the RED seed that
// reproduced today's un-windowed frontend (whole-range `window`, no-op
// `grown`). `ColumnLayout` is a pure, stateless struct: every call rebuilds
// whatever it needs from its arguments alone (no AppKit, no cached state —
// see the contract's LAYERING note), so the App wires it in wherever a fresh
// window or a fresh width merge is needed (ViewerModel.horizontalViewportChanged
// / growColumnWidthsToFitWindow) without owning any lifecycle of its own.
public struct ColumnLayout: ColumnLayouting {
    public init() {}

    // MARK: - window

    /// Single forward scan accumulating the running x-offset, stopping the
    /// instant the last intersecting column is found — so the work done is
    /// bounded by THE ANSWER's position (`lastHit`, at most `widths.count`),
    /// never a fixed full pass over the whole array. A cold-open (`viewportX
    /// == 0`, every first paint) or any scroll near the front of a wide
    /// document touches only a HANDFUL of columns, independent of
    /// `widths.count` (ARCH AC2); a scroll deep into the document costs
    /// O(that position) — never worse than a full `widths.count` pass would
    /// be, and far better whenever the position isn't near the very end
    /// (ARCH AC3). (An index structure giving true O(log n) for an
    /// ARBITRARY position would need to persist across calls — this contract
    /// is a stateless pure function of whatever `widths` it is handed each
    /// time, so a fresh scan per call is what "cheap arithmetic, never text
    /// layout" means here; see the contract's LAYERING note.)
    public func window(widths: [Double], viewportX: Double, viewportWidth: Double, overscan: Int) -> ColumnWindow {
        let count = widths.count
        guard count > 0 else { return ColumnWindow(first: 0, count: 0, firstX: 0) }

        let lo = max(0, viewportX)
        let hi = viewportX + max(viewportWidth, 0)
        guard hi > lo else { return ColumnWindow(first: 0, count: 0, firstX: 0) }

        var offset = 0.0     // running Σ widths[0..<i], i.e. column i's start x
        var firstHit = -1    // first column whose END exceeds `lo`
        var firstHitX = 0.0  // that column's start x (Σ widths[0..<firstHit])
        var lastHit = -1     // last column whose START is still before `hi`
        for i in 0..<count {
            let start = offset
            offset += widths[i] > 0 ? widths[i] : 0
            if firstHit < 0 {
                guard offset > lo else { continue }
                // The first column reaching past `lo`: since it is the FIRST
                // such column, the PREVIOUS one's end (== this one's start)
                // is <= lo < hi, so this column always also qualifies for
                // `lastHit` below — the window is never empty once found.
                firstHit = i
                firstHitX = start
            }
            if start < hi {
                lastHit = i
            } else {
                break   // every later column starts even later — done
            }
        }
        // No column's end ever passed `lo`: the viewport starts at/past the
        // end of all content (contract: "a viewport intersecting no column
        // yields an empty window at firstX 0").
        guard firstHit >= 0 else { return ColumnWindow(first: 0, count: 0, firstX: 0) }

        let pad = max(0, overscan)
        let first = max(0, firstHit - pad)
        let last = min(count - 1, lastHit + pad)
        // `firstX` must be the EXACT prefix sum at `first`, which sits at
        // most `pad` columns before `firstHit` once overscan pulls it left —
        // walk back that (small, overscan-bounded) span from the already-
        // known `firstHitX` rather than re-summing from 0.
        var firstX = firstHitX
        var back = firstHit - 1
        while back >= first {
            firstX -= widths[back] > 0 ? widths[back] : 0
            back -= 1
        }
        return ColumnWindow(first: first, count: last - first + 1, firstX: firstX)
    }

    // MARK: - grown

    /// Per-column, monotone max-merge (see the contract doc): only the columns
    /// named in `candidates` are ever touched, each raised to
    /// `max(current[c], candidates[c])`; every other column is returned
    /// byte-identical to `current`. Independence + monotonicity together are
    /// exactly what makes a horizontal scroll unable to churn an established
    /// width — re-measuring a column over the SAME vertical row window always
    /// yields the SAME candidate, so merging it again is a no-op.
    public func grown(_ current: [Double], mergingCandidates candidates: [Int: Double]) -> [Double] {
        guard !candidates.isEmpty else { return current }
        var result = current
        for (column, candidate) in candidates where current.indices.contains(column) {
            if candidate > result[column] { result[column] = candidate }
        }
        return result
    }
}
