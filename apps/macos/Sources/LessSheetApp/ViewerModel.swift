import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// The presentation model for one viewer window. Owns the live windowed
// `DocumentSession`, pages row windows as the user scrolls (O(viewport)),
// polls index/jump progress OFF the main actor, drives the jump flow, holds
// hidden-column and dialect override state, and the floating overlay's
// reveal/fade presentation state. Every open — panel, launch, CLI, drag,
// dialect re-open — funnels through `open(path:forcing:)`.
//
// This file holds ONLY the stored state + nested types + init. The behavior is
// split across `ViewerModel+*.swift` extensions (opening, paging, grid, copy,
// find, filter, columns, jump, lifecycle) — the members those extensions share
// are `internal` (a type's implementation cannot be `private` across files).

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
    /// Whether the current document was opened locally or over the network
    /// (ARCH-network-source): keys the cold-start marker policy (AC10) and the
    /// window title (the URL is shown as-is, no filename extraction — req 11).
    var currentOpenKind: DocumentOpenKind = .local
    /// The last network-open failure (for the affordance); cleared on a new open.
    var networkOpenError: NetworkOpenError?
    /// Live progress of an in-flight network open (nil when none). Drives the
    /// always-visible progress affordance (req 10 / AC9); no 500 ms delay gate.
    var networkOpenProgress: NetworkOpenProgress?
    /// The in-flight network open's cancel signal (nil when none); `cancelNetworkOpen()`
    /// fires it. Not `@Observable`-visible state on its own (the affordance reads
    /// `networkOpenProgress`); only `openURL`/`cancelNetworkOpen` touch it.
    var networkCancelToken: NetworkOpenCancelToken?
    var columnCount = 0
    var headerCells: [String]?
    /// Bounded label cache for the core-backed grid fetch. Unlike the legacy
    /// protocol property, this never grows with the document: every horizontal
    /// re-materialize replaces it with exactly that buffered column window.
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
    /// The current horizontal column window (ARCH-column-windowing) — the
    /// column analog of `window` (`RowWindow`): the contiguous run of columns
    /// the live grid's measure/fetch/draw stays bounded to, reported by the
    /// grid from its horizontal scroll clip (see `horizontalViewportChanged`).
    /// Indices are positions into `visibleColumns` (render order), matching
    /// what `ColumnLayouting.window(widths:...)` was given. Empty until the
    /// grid reports its first real viewport (fresh open, before any layout).
    var columnWindow = ColumnWindow(first: 0, count: 0, firstX: 0)

    // Windowed data + progress knowledge.
    var window = RowWindow(firstRow: 0, rows: [])
    var rowCountInfo = RowCountInfo(count: 0, isExact: true)
    var indexProgress = ScanProgress(bytesScanned: 0, bytesTotal: 0, isComplete: true)

    // Hidden-column + jump view-model state.
    var visibility = ColumnVisibility(columnCount: 0, hiddenColumns: [])
    var columnUserSettings: [Int: ColumnUserSettings] = [:]
    var sessionLocale = Locale.current
    var jumpFlow: JumpFlow = .idle

    // Selection + copy (ARCH-select-copy AC1-4): the live rectangular
    // selection (index space; nil = nothing selected) and a brief post-copy
    // status line (ARCH AC2: "a subtle notice"). Both session-scoped, reset
    // on every (re-)open like the find/filter state below.
    var selection: Selection?
    var copyNotice: String?

    /// A brief, auto-fading "what changed" notice for immediate dialect
    /// toggles — the header button flips with no popup, so the glyph swap
    /// alone is easy to miss. Mirrors `copyNotice`'s lifecycle (set on the
    /// action, cleared by its own task after a readable beat).
    var dialectNotice: String?
    @ObservationIgnored var dialectNoticeTask: Task<Void, Never>?

    // Find (search) session state: the editable draft + the active search's
    // display (highlights render exactly while `display.request` is non-nil).
    // The draft survives Esc / dialect re-open (query-retained semantics).
    var findSession: FindSession = FindControl().initial()

    // Filter (filtered-views) state: the active filter's poll snapshot, or nil
    // for the identity view (ARCH-filtered-views reqs. 10-18).
    // `filterDocumentRows` captures M — the base (unfiltered) row-count
    // knowledge from the identity view at the moment filtering began — held
    // fixed while filtered, since the session's own `rowCount()` reports the
    // filtered m from then on.
    var filterSnapshot: FilterSnapshot?
    var filterDocumentRows: RowCountInfo?

    // A row the grid should bring into view (jump landing / cancel restore),
    // consumed and cleared by the grid once applied.
    var pendingScrollRow: UInt64?
    /// Direct AppKit hand-off for jump/find landings. SwiftUI observation is
    /// still the state bridge of record (`pendingScrollRow`), but an update can
    /// legitimately be coalesced while the representable is attaching to its
    /// window. The native controller installs this weak callback so every
    /// landing also schedules a post-layout apply; no request is lost merely
    /// because there was no subsequent observable mutation.
    @ObservationIgnored var viewportLandingHandler: ((UInt64) -> Void)?

    // Overlay presentation state.
    var expandedPill: PillKind?
    var jumpFieldActive = false
    var findFieldActive = false
    var settingsOpen = false
    /// Bumped by the ⌘J command to ask the overlay to reveal + focus the jump
    /// field (the keyboard reveal path).
    var jumpFocusRequests = 0
    /// Bumped whenever a jump is REJECTED (target past the last row, or invalid
    /// input): the jump field re-arms and the overlay blinks/shakes it (item 4).
    var jumpRejections = 0
    /// Bumped by ⌘F to reveal the overlay + focus the find field.
    var findFocusRequests = 0
    /// Bumped whenever a find submit is REJECTED (ordering predicate with a
    /// non-numeric value): the value field blinks red + shakes (Reduce Motion =
    /// blink only), reusing the jump rejection components.
    var findRejections = 0

    // MARK: Collaborators (pure view-model logic; pinned by frozen tests)

    let opener: any DocumentSessionOpening
    let visibilityManager = ColumnVisibilityManager()
    /// The pure horizontal column-window geometry + width-growth algebra
    /// (ARCH-column-windowing); see `horizontalViewportChanged` /
    /// `growColumnWidthsToFitWindow`.
    let columnLayout = ColumnLayout()
    let jumpControl = JumpControl()
    let composer = DialectComposer()
    let findControl = FindControl()
    let filterControl = FilterControl()
    let windowPoll = WindowPoll()
    /// The pure selection geometry and column-width algebra (ARCH-select-copy)
    /// — same layering as the collaborators above. TSV copy framing now lives in
    /// the core (ARCH-thin-frontend-shared-core Phase 2): `copySelection` streams
    /// it off `DocumentSession.openCopy` instead of a frontend `TSVCopyBuilder`.
    let selectionModel = SelectionModel()
    let columnSizer = ColumnSizer()
    /// The direction of the outstanding search navigation (drives the wrap
    /// notice's start/end choice when a poll reports exhaustion).
    var searchNavDirection: SearchDirection = .forward
    /// Genuine-user-Cancel latch (the Stop affordance → `cancelFind`). Set true
    /// there, honored in `foldSearch`, cleared on the next fresh search /
    /// navigation (submitFind / stepFind) and on any find-session reset
    /// (closeFind / filter enter-exit / new document).
    ///
    /// WHY it exists: the core's `ls_search_cancel` only nils a PENDING
    /// `NAV_SEARCHING`; an already-landed `NAV_FOUND` PERSISTS (api/lesssheet.h
    /// 191-193, 764-767). So after a user cancel with a match landed (the
    /// common case — submitFind navigates `.fromTop`), the next ~100ms poll
    /// carries `phase=.cancelled, nav=.found`. `FindControl.resolved` folds
    /// THAT (correctly, for a network net-park — api nfd_ac6) as the count with
    /// notice=nil, which would CLOBBER the "Stopped" `cancelFind` set. The latch
    /// re-asserts "Stopped" across that follow-up fold. A net-park never sets
    /// the latch (no user stop), so its count path is untouched. Not observed
    /// by any view — pure control state.
    @ObservationIgnored var userStopped = false

    var session: (any DocumentSession)?
    var markedGeneration = -1
    var firstVisibleRow = 0
    /// `visibilityManager.visibleColumns(visibility)`, memoized: kept in
    /// lockstep by `setVisibility` (the ONLY place `visibility` is assigned)
    /// so every read is O(1) — this list is read many times per frame (every
    /// visible row's cells/truncation/highlights, the header labels, the
    /// widths) and a fresh `0..<columnCount` filter on each of those reads
    /// would itself be the O(total-columns) cost this slice removes, on a
    /// wide document with nothing hidden (ARCH-column-windowing).
    var cachedVisibleColumns: [Int] = []
    /// `visibleColumns.map { Double(columnWidths[$0]) }`, plus its sum, both
    /// memoized together and rebuilt ONLY when `markLayoutWidthsStale` is
    /// called — after a width batch changes (open, or a monotone grow) or
    /// `visibility` changes — never per scroll tick. ARCH-column-windowing
    /// calls for exactly this ("rebuilt only when a width batch changes, off
    /// the per-frame path"): converting/summing 100k `CGFloat`s is measurably
    /// NOT free in a debug build (tens of ms, closure/array overhead), so
    /// recomputing either on every call would silently reintroduce an
    /// O(columnCount) per-frame cost this whole slice exists to remove.
    var cachedLayoutWidths: [Double] = []
    var cachedTotalVisibleWidth: CGFloat = 0
    var layoutWidthsStale = true
    /// The per-window MATCH-FLAGS mask (ARCH-thin-frontend-shared-core Phase 1):
    /// the highlight verdicts computed by the CORE (`ls_window_match_flags` via
    /// `DocumentSession.windowMatchFlags`) instead of a frontend matcher — one
    /// flag byte per materialized cell (1 = the cell matches the active
    /// find/predicate request, 0 = not; row-major, stride == the fetched column
    /// width). Fetched ONCE whenever the window geometry or the active request
    /// changes (`ensureMatchFlagsFresh`), then indexed per cell by every repaint
    /// (`matchFlag`) — O(viewport), with NO per-cell FFI and NO per-frame
    /// matching. `@ObservationIgnored`: a derived cache, not observable state —
    /// views observe `window` / `findSession.display`, and those changes are
    /// exactly what invalidate the mask below.
    @ObservationIgnored var matchFlagsMask: [UInt8] = []
    @ObservationIgnored var matchFlagsKey: MatchFlagsCacheKey?
    /// Cumulative count of REAL `windowMatchFlags` ABI fetches (a cache miss in
    /// `ensureMatchFlagsFresh` that actually hit the core — NOT cache hits, NOT
    /// the empty no-search branch). Pure instrumentation for `MatchFlagsFetchProbe`
    /// (the AC5 fetch-cadence lock). `@ObservationIgnored`: never observed.
    @ObservationIgnored var matchFlagsFetchCount = 0
    /// Monotonic CONTENT/materialization epoch — the mask cache's window-content
    /// identity. Window GEOMETRY + request do NOT uniquely determine the visible
    /// bytes (they also depend on which document/dialect/filter is open), so the
    /// mask key alone could serve one document's mask over another's rows after a
    /// same-geometry re-open (or a filter set/clear). This counter is bumped on
    /// EVERY materialization (`materialize`) and on every content-swap that can
    /// keep an identical geometry — `adoptSession` (new document) and both filter
    /// paths (`applyFindAsFilter` / `clearFilter`). `@ObservationIgnored`: pure
    /// cache-invalidation state, never observed.
    @ObservationIgnored var matchFlagsContentGen = 0

    /// Identity of a cached match-flags mask: the materialized window geometry it
    /// was fetched for, PLUS the active request, PLUS the content epoch
    /// (`matchFlagsContentGen`) — the last is what distinguishes two windows that
    /// share a geometry+request but hold different bytes (a same-dims re-open, a
    /// filter set/clear). A change in any field means the mask must be refetched
    /// (Equatable is auto-synthesized).
    struct MatchFlagsCacheKey: Equatable {
        var contentGen: Int
        var firstRow: UInt64
        var firstColumn: Int
        var rowCount: Int
        var columnCount: Int
        var request: SearchRequest?
    }

    /// Bumps the match-flags content epoch (see `matchFlagsContentGen`). Called
    /// wherever the visible bytes may change under a possibly-unchanged geometry.
    func invalidateMatchFlags() {
        matchFlagsContentGen &+= 1
    }
    /// Set on a header on/off re-open (consumed by the grid): how a data-row
    /// index shifts across the re-derivation so the viewport can re-anchor to the
    /// SAME file record. +1 when the header turns OFF (the former header record
    /// becomes data row 0, pushing every data row down one), −1 when it turns ON
    /// (the first data row is absorbed as the header), 0 for a no-op. `nil` for a
    /// fresh open or a separator/quote change (those rest at the top as before).
    var pendingHeaderShift: Int?
    var lastVisibleCount = 1
    var desiredStart: UInt64 = 0
    var desiredCount = 0
    var pollTask: Task<Void, Never>?
    var wrapNavTask: Task<Void, Never>?
    /// Whether a copy build is currently running off-main. Verification
    /// (`SelectCopyProbe`) polls for a SPECIFIC copy's completion without racing
    /// a stale `copyNotice` left over from a PRIOR copy.
    var copyInFlight = false
    var copyNoticeTask: Task<Void, Never>?
    /// The off-main copy build (ARCH-select-copy round 2, findings 2/3):
    /// stored so a fresh ⌘C, Esc, or the "Copying…" notice's Cancel button
    /// can cancel a running one (`cancelCopy`) rather than leaving it to
    /// finish unseen.
    var copyTask: Task<Void, Never>?
    /// Manual column-width overrides (ARCH-select-copy AC5), keyed by ABSOLUTE
    /// column index — session-scoped, reset on every (re-)open. Layered over
    /// the AUTO baseline (`columnWidths`) via `ColumnSizing.effectiveWidths`
    /// wherever a width is read for drawing/layout; `growColumnWidthsToFitWindow`
    /// skips an overridden column so auto-grow never fights it.
    var manualColumnWidths: [Int: Double] = [:]
    /// ARCH-stream-copy AC8/AC9: ONE shared gate + clock driving the "subtle
    /// progress after ~500 ms" affordance for every long op this model tracks
    /// (copy / jump-scan / filter-scan) — see `copyProgress` /
    /// `jumpProgressIndication` / `filterProgressIndication`. One instance means
    /// one shared threshold band the whole app reads consistently.
    let progressGate = DelayedProgressGate()
    let progressClock = ContinuousClock()
    var copyStartedAt: ContinuousClock.Instant?
    var jumpScanStartedAt: ContinuousClock.Instant?
    var filterScanStartedAt: ContinuousClock.Instant?
    /// Bumped on every `copySelection()` call — lets the delayed-reveal task
    /// tell "am I still THIS copy?" apart from the shared `copyInFlight` flag,
    /// which is true for ANY in-flight copy: a rapid supersede (⌘C again before
    /// the threshold) would otherwise let a stale task, woken at the OLD copy's
    /// threshold, reveal progress for the NEW copy using the old elapsed.
    var copyGeneration = 0
    /// COPY's live delayed-progress indication (AC8): hidden until the
    /// running copy passes the shared threshold, then visible with cancel;
    /// cleared by `completeCopy`/`cancelCopy`. Recomputed once, at the
    /// threshold tick in `copySelection`.
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
