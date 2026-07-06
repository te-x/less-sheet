import Contracts

// Viewer-ui pure view-model logic (implementer-owned; conformances pinned by
// the frozen tests, semantics pinned in Sources/Contracts).
//
// STATUS: SEED — conformance-true stubs so the component compiles while the
// frozen behavior tests are red. The build cell implements the pinned
// semantics documented on each protocol.

/// Implements `ColumnVisibilityManaging` (see its pinned semantics).
public struct ColumnVisibilityManager: ColumnVisibilityManaging {
    public init() {}

    public func allVisible(columnCount: Int) -> ColumnVisibility {
        ColumnVisibility(columnCount: columnCount, hiddenColumns: [])
    }

    public func toggling(_ visibility: ColumnVisibility, column: Int) -> ColumnVisibility {
        visibility // SEED: no-op
    }

    public func canHide(_ visibility: ColumnVisibility, column: Int) -> Bool {
        false // SEED
    }

    public func carriedOver(_ visibility: ColumnVisibility, toColumnCount newCount: Int) -> ColumnVisibility {
        visibility // SEED
    }

    public func visibleColumns(_ visibility: ColumnVisibility) -> [Int] {
        [] // SEED
    }
}

/// Implements `JumpControlling` (see its pinned semantics).
public struct JumpControl: JumpControlling {
    public init() {}

    public func parseTarget(_ input: String) -> UInt64? {
        nil // SEED
    }

    public func begin(target: UInt64, preJumpFirstRow: UInt64) -> JumpFlow {
        .idle // SEED
    }

    public func resolve(_ flow: JumpFlow, with status: JumpStatus) -> JumpFlow {
        flow // SEED
    }

    public func cancelled(_ flow: JumpFlow) -> JumpFlow {
        flow // SEED
    }
}

/// Implements `DialectComposing` (see its pinned semantics).
public struct DialectComposer: DialectComposing {
    public init() {}

    public func compose(from current: DialectReport, changing change: DialectChange) -> DialectOverride? {
        nil // SEED
    }
}
