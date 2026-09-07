import Contracts
import SwiftUI

/// The sort's view-mode indicator and its long-operation affordance in one
/// capsule, next to the filter banner (ARCH-sort-by-column FR11 / AC-s14).
///
/// Deliberately NOT behind the shared delayed-progress gate, exactly like the
/// network-open banner: a key pass is a full pass over the data — around a
/// minute on a 10 GB file and longer over the wire — so its progress and its
/// Cancel are visible for the WHOLE build rather than only past the ~500 ms
/// threshold. Cancel routes through the same `SortCycling` "stop" arm a click on
/// an unlanded sort takes, so the two can never disagree.
struct SortBannerView: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome

    var body: some View {
        if let snapshot = model.sortSnapshot, let text = model.sortBannerText {
            HStack(spacing: 8) {
                if let progress = model.sortProgress {
                    if dumpChrome {
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(width: 40, height: 6)
                            Capsule().fill(Color.accentColor).frame(width: 40 * progress, height: 6)
                        }
                    } else {
                        ProgressView(value: progress).progressViewStyle(.linear).frame(width: 40)
                    }
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if case .failed = snapshot.phase {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if snapshot.isWorking {
                    Button("Cancel", role: .cancel) { model.cancelSort() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .accessibilityLabel("Cancel sorting")
                } else {
                    Button { model.clearSort() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove sort")
                    .accessibilityLabel("Remove sort")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassChrome(.regular, in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text)
        }
    }
}

/// "Loading rows…" — shown while a materialize known to be SLOW is pending
/// (`DocumentModel.windowLoading`). A sorted window means scattered reads, and
/// on a gzip source one of them costs of the order of a second; this is what
/// keeps that from reading as a frozen app. It appears only after a window on
/// this document has actually been measured that slow, so a fast local sort
/// never shows it.
struct WindowLoadingCapsule: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome

    var body: some View {
        if model.windowLoading {
            HStack(spacing: 8) {
                if dumpChrome {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Loading rows…")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassChrome(.regular, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading rows")
        }
    }
}
