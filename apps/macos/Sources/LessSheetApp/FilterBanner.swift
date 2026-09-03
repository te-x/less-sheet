import Contracts
import SwiftUI

/// The "Filtered — N of M rows" indicator, with its Clear affordance. A filter
/// is a standing view mode, so this stays put the whole time one is active.
struct FilterBannerView: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome

    var body: some View {
        if let banner = model.filterBanner {
            HStack(spacing: 8) {
                // Only the progress bar is gated by the shared delay, so a filter
                // that resolves quickly never flickers it. The text and Clear stay
                // unconditional: they are the view-mode indicator, not a
                // transient long-op affordance.
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

/// "Filtered — 5 of 812 rows", the converging "Filtered — 5 of ~812 rows…", and
/// the empty "Filtered — no matching rows".
enum FilterCopy {
    static func summary(_ banner: FilterBanner) -> String {
        if banner.isEmptyResult { return "Filtered — no matching rows" }
        let matchingText = RowCountText.abbreviated(banner.matching)
        let totalText = (banner.documentRowsEstimated ? "~" : "") + RowCountText.abbreviated(banner.documentRows)
        let base = "Filtered — \(matchingText) of \(totalText) rows"
        return banner.matchingIsFinal ? base : base + "…"
    }
}
