import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// The presentation model for the viewer window: owns the live windowed
// `DocumentSession`, pages row windows as the user scrolls, polls progress off
// the main actor, and holds every piece of session-only document state. Every
// open — panel, launch, CLI, drag, dialect re-open — funnels through
// `open(path:forcing:)` or its network twin.
//
// This file holds only the stored state, the nested types and init; the
// behavior lives in the `ViewerModel+*.swift` extensions, which is why the
// members they share are `internal` rather than `private`.

struct PanelColumnLabel {
    let text: String
    let truncated: Bool
}

struct WindowCellPresentation {
    let text: String
    let formatUnavailable: Bool
    let conflict: Bool
}

@MainActor
@Observable
final class DocumentModel {
    static let shared = DocumentModel()

    enum Phase: Equatable {
        case launch                                   // nothing opened yet
        case document                                 // a document is open (may be empty)
        case failure(DocumentOpenError, path: String)
    }

    // MARK: Observable presentation state

    var phase: Phase = .launch
    /// Bumped on every completed open; keys the first-frame timing marker and
    /// the grid's `.task(id:)` refresh.
    var openGeneration = 0

    // Document facts (constant for the open session).
    var path: String = ""
    /// Keys the cold-start marker policy (a network open emits none) and the
    /// window title (a URL is shown as-is, with no filename extraction).
    var currentOpenKind: DocumentOpenKind = .local
    /// The last network-open failure; cleared on a new open.
    var networkOpenError: NetworkOpenError?
    /// Live progress of an in-flight network open. Drives an ALWAYS-visible
    /// affordance: network latency is unpredictable even for a small file, so
    /// this one is deliberately not behind the delayed-progress gate.
    var networkOpenProgress: NetworkOpenProgress?
    /// The in-flight network open's cancel signal, touched only by `openURL` and
    /// `cancelNetworkOpen`.
    var networkCancelToken: NetworkOpenCancelToken?
    var columnCount = 0
    var headerCells: [String]?
    /// Bounded label cache for the grid fetch: every horizontal re-materialize
    /// replaces it with exactly that buffered column window, so it never grows
    /// with the document.
    var windowColumnLabels: [Int: String] = [:]
    var windowTruncatedLabels: Set<Int> = []
    var windowColumnMetadata: [Int: ColumnMetadata] = [:]
    var gridInferenceIDs: [UInt32] = []
    var panelInferenceIDs: [UInt32] = []
    var panelSelectedColumn: UInt32?
    var panelLabels: [Int: PanelColumnLabel] = [:]
    var panelMetadata: [Int: ColumnMetadata] = [:]
    var panelFetchTask: Task<Void, Never>?
    var columnMetadataGeneration: UInt64 = 0
    var columnPresentationRevision = 0
    var columnWidthRevision = 0
    var columnConfigurationRevision = 0
    var columnPanelRevision = 0
    struct ColumnConfigurationEvent {
        let revision: Int
        let columns: Set<Int>
    }
    var columnConfigurationEvents: [ColumnConfigurationEvent] = []
    var columnInferenceProgress: Double?
    var settingsLifecycle = SettingsLifecycleState()
    var settingsDiscoveryRows: [Int] = []
    var dialect = DialectReport(
        separator: 0x2C, quote: 0x22, hasHeader: false,
        separatorForced: false, quoteForced: false, headerForced: false
    )
    var columnWidths: [CGFloat] = []      // per ORIGINAL column index
    /// The column analog of `window`: the contiguous run of columns the live
    /// grid's measure/fetch/draw stays bounded to, reported by the grid from its
    /// horizontal scroll clip. Indices are positions into `visibleColumns`
    /// (render order). Empty until the grid reports its first real viewport.
    /// Assign only through `setColumnWindow`, which keeps `cachedWindowColumns`
    /// in lockstep.
    private(set) var columnWindow = ColumnWindow(first: 0, count: 0, firstX: 0)
    /// `columnWindow`'s slice of `visibleColumns`, as ABSOLUTE indices in render
    /// order — memoized, rebuilt only by `setColumnWindow` / `setVisibility`.
    @ObservationIgnored var cachedWindowColumns: [Int] = []

    // Windowed data + progress knowledge.
    var window = RowWindow(firstRow: 0, rows: [])
    var rowCountInfo = RowCountInfo(count: 0, isExact: true)
    var indexProgress = ScanProgress(bytesScanned: 0, bytesTotal: 0, isComplete: true)

    // Hidden-column + jump view-model state.
    var visibility = ColumnVisibility(columnCount: 0, hiddenColumns: [])
    var columnUserSettings: [Int: ColumnUserSettings] = [:]
    var sessionLocale = Locale.current
    var jumpFlow: JumpFlow = .idle

    // The live rectangular selection (index space) and a brief post-copy notice.
    // Session-scoped, reset on every (re-)open like the find/filter state below.
    var selection: Selection?
    var copyNotice: String?

    /// A brief "what changed" notice for the header toggle, which flips with no
    /// popup of its own — the glyph swap alone is easy to miss.
    var dialectNotice: String?
    @ObservationIgnored var dialectNoticeTask: Task<Void, Never>?

    // The editable find draft plus the active search's display; highlights
    // render exactly while `display.request` is non-nil. The draft survives Esc
    // and a dialect re-open, so re-running is one Enter.
    var findSession: FindSession = FindControl().initial()

    // The active filter's poll snapshot, or nil for the identity view.
    // `filterDocumentRows` captures the base document row count at the moment
    // filtering began and holds it fixed, since the session's own `rowCount()`
    // reports the FILTERED count from then on.
    var filterSnapshot: FilterSnapshot?
    var filterDocumentRows: RowCountInfo?

    // A row the grid should bring into view (jump landing / cancel restore),
    // consumed and cleared by the grid once applied.
    var pendingScrollRow: UInt64?
    /// Direct AppKit hand-off for landings. `pendingScrollRow` is still the
    /// state bridge of record, but SwiftUI can legitimately coalesce an update
    /// while the representable is attaching to its window; the grid installs
    /// this so no landing is lost merely because no further observable mutation
    /// followed it.
    @ObservationIgnored var viewportLandingHandler: ((UInt64) -> Void)?

    // Overlay presentation state.
    var expandedPill: PillKind?
    var jumpFieldActive = false
    /// The jump field's 1-based row text. Model-side, not view-side, because
    /// ↑/↓ step it against document knowledge the view does not own. Survives
    /// closing the popup; a SUCCESSFUL submit clears it.
    var jumpFieldText = ""
    /// Hold-to-accelerate state for the jump field's ↑/↓. Pure control state.
    @ObservationIgnored var jumpFieldRamp = JumpFieldRamp()
    var findFieldActive = false
    var settingsOpen = false
    /// Bumped by ⌘J to open and focus the jump field.
    var jumpFocusRequests = 0
    /// Bumped whenever a jump is rejected (target past the last row, or invalid
    /// input): the field re-arms and blinks/shakes.
    var jumpRejections = 0
    /// Bumped by ⌘F to open and focus the find field.
    var findFocusRequests = 0
    /// Bumped whenever a find submit is rejected (an ordering predicate with a
    /// non-numeric value): the value field blinks and shakes.
    var findRejections = 0

    // MARK: Collaborators (the pure logic in LessSheetKit)

    let opener: any DocumentSessionOpening
    let visibilityManager = ColumnVisibilityManager()
    let columnLayout = ColumnLayout()
    let jumpControl = JumpControl()
    let composer = DialectComposer()
    let findControl = FindControl()
    let filterControl = FilterControl()
    let windowPoll = WindowPoll()
    let selectionModel = SelectionModel()
    let columnSizer = ColumnSizer()
    /// The direction of the outstanding search navigation (drives the wrap
    /// notice's start/end choice when a poll reports exhaustion).
    var searchNavDirection: SearchDirection = .forward
    /// Latches a GENUINE user Cancel, so `foldSearch` can keep saying "Stopped".
    ///
    /// `ls_search_cancel` only clears a pending navigation; an already-landed
    /// match persists. After a user cancel with a match landed — the common case
    /// — the next poll therefore carries a cancelled phase AND a found nav,
    /// which `FindControl.resolved` correctly folds as a count with no notice
    /// (that shape is a SUCCESS on a network document). Without this latch that
    /// fold would immediately clobber "Stopped". Cleared by the next fresh
    /// search or navigation, and by any find-session reset.
    @ObservationIgnored var userStopped = false

    var session: (any DocumentSession)?
    /// Claimed by every `open` / `openURL` call before it suspends on the
    /// opener. Two opens can overlap (a second dialect change while the first
    /// is still opening); the one whose claim no longer matches has been
    /// superseded and must drop its candidate instead of adopting it over the
    /// winner. Pure control state — no view reads it.
    @ObservationIgnored var openRequestSequence = 0
    var markedGeneration = -1
    var firstVisibleRow = 0
    /// `visibleColumns`, memoized. Read many times per frame — every visible
    /// row's cells, truncation flags and highlights, the header labels, the
    /// widths — so a fresh `0..<columnCount` filter per read would itself be the
    /// O(total columns) per-frame cost the column window exists to remove.
    var cachedVisibleColumns: [Int] = []
    /// The render-order widths and their sum, rebuilt together ONLY when
    /// `markLayoutWidthsStale` says a width batch or the visibility changed —
    /// never per scroll tick. Converting and summing 100k CGFloats is not free.
    var cachedLayoutWidths: [Double] = []
    var cachedTotalVisibleWidth: CGFloat = 0
    var layoutWidthsStale = true
    /// The core's per-cell highlight verdicts for the materialized window: one
    /// byte per cell, row-major with stride == the fetched column width. Fetched
    /// once per window-or-request change and then indexed per cell by every
    /// repaint, so a repaint costs no FFI and no matching. A derived cache, not
    /// observable state — views observe `window` and `findSession.display`, and
    /// those are exactly what invalidate it.
    @ObservationIgnored var matchFlagsMask: [UInt8] = []
    @ObservationIgnored var matchFlagsKey: MatchFlagsCacheKey?
    /// Counts REAL mask fetches (cache misses that hit the core), for the probe
    /// that locks the one-fetch-per-materialize cadence.
    @ObservationIgnored var matchFlagsFetchCount = 0
    /// Monotonic content epoch. Window geometry plus request do NOT uniquely
    /// identify the visible bytes — they also depend on which document, dialect
    /// and filter is open — so without this a same-geometry re-open or a filter
    /// toggle would serve the previous content's mask over the new rows.
    @ObservationIgnored var matchFlagsContentGen = 0

    /// The identity of a cached mask: the window geometry it was fetched for,
    /// the active request, and the content epoch that separates two windows
    /// sharing a geometry but holding different bytes.
    struct MatchFlagsCacheKey: Equatable {
        var contentGen: Int
        var firstRow: UInt64
        var firstColumn: Int
        var rowCount: Int
        var columnCount: Int
        var request: SearchRequest?
    }

    /// Call wherever the visible bytes may change under a possibly-unchanged
    /// window geometry.
    func invalidateMatchFlags() {
        matchFlagsContentGen &+= 1
    }

    /// The ONLY place `columnWindow` is set, so its memoized slice
    /// (`windowColumns()`) can never drift from it.
    func setColumnWindow(_ newValue: ColumnWindow) {
        columnWindow = newValue
        refreshWindowColumnsCache()
    }

    /// Rebuilds the memoized window slice from its two inputs. Every row the
    /// grid configures asks for this list several times per scroll tick, so
    /// re-slicing it per call is an allocation worth removing from that path.
    func refreshWindowColumnsCache() {
        let cols = cachedVisibleColumns
        let clamped = columnWindow.range.clamped(to: 0..<cols.count)
        cachedWindowColumns = clamped.isEmpty ? [] : Array(cols[clamped])
    }
    /// How a data-row index shifts across a header on/off re-open, so the
    /// viewport can re-anchor to the same file record: +1 when the header turns
    /// off (the former header becomes data row 0), −1 when it turns on. `nil` for
    /// a fresh open or a separator/quote change, which rest at the top.
    var pendingHeaderShift: Int?
    var lastVisibleCount = 1
    var desiredStart: UInt64 = 0
    var desiredCount = 0
    var pollTask: Task<Void, Never>?
    var wrapNavTask: Task<Void, Never>?
    var copyInFlight = false
    var copyNoticeTask: Task<Void, Never>?
    /// The off-main copy build, stored so a fresh ⌘C, Esc, or the notice's Cancel
    /// button can stop a running one rather than leave it to finish unseen.
    var copyTask: Task<Void, Never>?
    /// Manual column-width overrides, keyed by ABSOLUTE column index and layered
    /// over the auto baseline wherever a width is read. Auto-grow skips an
    /// overridden column, so the two never fight.
    var manualColumnWidths: [Int: Double] = [:]
    /// ONE gate and clock for every long operation this model tracks (copy,
    /// jump-scan, filter-scan), so the whole app shares one threshold band.
    let progressGate = DelayedProgressGate()
    let progressClock = ContinuousClock()
    var copyStartedAt: ContinuousClock.Instant?
    var jumpScanStartedAt: ContinuousClock.Instant?
    var filterScanStartedAt: ContinuousClock.Instant?
    /// Lets the delayed-reveal task ask "am I still THIS copy?", which
    /// `copyInFlight` cannot answer — it is true for any in-flight copy, so a
    /// rapid ⌘C before the threshold would let a stale task reveal progress for
    /// the new copy using the old copy's elapsed time.
    var copyGeneration = 0
    /// Hidden until the running copy passes the shared threshold, then visible
    /// with cancel; cleared when the copy completes or is cancelled.
    var copyProgress: ProgressIndication = .hidden

    init(opener: any DocumentSessionOpening = CoreSessionOpener()) {
        self.opener = opener
    }
}

/// Which guess-pill a control refers to (also the overlay's expansion key).
enum PillKind: Equatable, Hashable {
    case header
    case separator
    case quote
}
