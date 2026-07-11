import Contracts
import SwiftUI

// The filtered banner (ARCH-filtered-views app req. 11 / criterion 16): a
// persistent "Filtered — N of M rows" indicator with a Clear (✕) affordance,
// shown while a filter is active. Unlike the bottom-right control row it does
// NOT hover-fade — the filter is a standing view mode, not a transient
// interaction, so its indicator stays put the whole time it's active (the
// same glass language, top-leading, clear of the chromeless title-bar area).

struct FilterBannerView: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome

    var body: some View {
        if let banner = model.filterBanner {
            HStack(spacing: 8) {
                // ARCH-stream-copy AC9 ("just wiring"): the scan-progress bar
                // + % SURFACE only once the shared delayed-progress gate says
                // so (past ~500 ms) — a filter that resolves sooner never
                // flickers it. The "Filtered — N of M rows" text + Clear
                // below stay unconditional: a persistent VIEW-MODE indicator,
                // not a transient long-op affordance (no cancel — ARCH:
                // "Filter's indicator need not offer cancel").
                if let progress = banner.progress, model.filterProgressIndication.isVisible {
                    let fraction = max(0, min(1, progress))
                    if dumpChrome {
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(width: 40, height: 6)
                            Capsule().fill(Color.accentColor).frame(width: 40 * fraction, height: 6)
                        }
                    } else {
                        ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 40)
                    }
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(FilterCopy.summary(banner))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Button { model.clearFilter() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassChrome(.regular, in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(FilterCopy.summary(banner))
        }
    }
}

/// Filtered-banner copy — sentence case, user vocabulary (ARCH req. 11):
/// "Filtered — 5 of 812 rows", the converging "Filtered — 5 of ~812 rows…",
/// and the empty result "Filtered — no matching rows" (criterion 18).
enum FilterCopy {
    static func summary(_ banner: FilterBanner) -> String {
        if banner.isEmptyResult { return "Filtered — no matching rows" }
        let n = RowCountText.abbreviated(banner.matching)
        let m = (banner.documentRowsEstimated ? "~" : "") + RowCountText.abbreviated(banner.documentRows)
        let base = "Filtered — \(n) of \(m) rows"
        return banner.matchingIsFinal ? base : base + "…"
    }
}
