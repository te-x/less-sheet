import Contracts

/// The horizontal column-window geometry and width-merge algebra. Stateless:
/// every call rebuilds what it needs from its arguments alone, so the model can
/// wire it in wherever a fresh window or width merge is needed without owning
/// any lifecycle of its own.
public struct ColumnLayout: ColumnLayouting {
    public init() {}

    // MARK: - window

    /// A single forward scan accumulating the running x-offset, stopping the
    /// instant the last intersecting column is found — so the work is bounded by
    /// the ANSWER's position, never a full pass over `widths`. A cold open
    /// (`viewportX == 0`) or any scroll near the front of a wide document touches
    /// a handful of columns whatever `widths.count` is. A true O(log n) lookup
    /// for an arbitrary position would need an index persisted across calls, and
    /// this contract is a pure function of the widths it is handed each time.
    public func window(widths: [Double], viewportX: Double, viewportWidth: Double, overscan: Int) -> ColumnWindow {
        let count = widths.count
        guard count > 0 else { return ColumnWindow(first: 0, count: 0, firstX: 0) }

        let lowerBound = max(0, viewportX)
        let upperBound = viewportX + max(viewportWidth, 0)
        guard upperBound > lowerBound else { return ColumnWindow(first: 0, count: 0, firstX: 0) }

        var offset = 0.0     // running Σ widths[0..<index], i.e. column index's start x
        var firstHit = -1    // first column whose END exceeds `lowerBound`
        var firstHitX = 0.0  // that column's start x (Σ widths[0..<firstHit])
        var lastHit = -1     // last column whose START is still before `upperBound`
        for index in 0..<count {
            let start = offset
            offset += widths[index] > 0 ? widths[index] : 0
            if firstHit < 0 {
                guard offset > lowerBound else { continue }
                // The FIRST column reaching past `lowerBound` also always
                // qualifies for `lastHit` below (its start is <= lowerBound <
                // upperBound), so the window is never empty once found.
                firstHit = index
                firstHitX = start
            }
            if start < upperBound {
                lastHit = index
            } else {
                break   // every later column starts even later
            }
        }
        // The viewport starts at or past the end of all content.
        guard firstHit >= 0 else { return ColumnWindow(first: 0, count: 0, firstX: 0) }

        let pad = max(0, overscan)
        let first = max(0, firstHit - pad)
        let last = min(count - 1, lastHit + pad)
        // `firstX` must be the exact prefix sum at `first`, which overscan puts
        // at most `pad` columns before `firstHit` — walk back that bounded span
        // rather than re-summing from 0.
        var firstX = firstHitX
        var back = firstHit - 1
        while back >= first {
            firstX -= widths[back] > 0 ? widths[back] : 0
            back -= 1
        }
        return ColumnWindow(first: first, count: last - first + 1, firstX: firstX)
    }

    // MARK: - grown

    /// Per-column, monotone max-merge: only the named columns are touched, each
    /// raised to `max(current[c], candidates[c])`. Independence plus monotonicity
    /// is what makes a horizontal scroll unable to churn an established width —
    /// re-measuring a column over the same row window yields the same candidate,
    /// so merging it again is a no-op.
    public func grown(_ current: [Double], mergingCandidates candidates: [Int: Double]) -> [Double] {
        guard !candidates.isEmpty else { return current }
        var result = current
        for (column, candidate) in candidates where current.indices.contains(column) {
            if candidate > result[column] { result[column] = candidate }
        }
        return result
    }
}
