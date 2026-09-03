import AppKit
import Contracts
import Foundation
import SwiftUI

/// Find popup copy: "Match 3 of 47", the growing "Match 3 of 47…", "No matches",
/// "Wrapped to start", "Stopped".
enum FindCopy {
    static func status(_ display: FindDisplay) -> String {
        if let notice = display.notice {
            switch notice {
            case .wrappedToStart: return "Wrapped to start"
            case .wrappedToEnd: return "Wrapped to end"
            case .noMatches: return "No matches"
            case .stopped: return "Stopped"
            }
        }
        if let position = display.position {
            let base = "Match \(position) of \(display.total)"
            return display.totalIsFinal ? base : base + "…"
        }
        if display.total > 0 {
            let base = "\(display.total) match\(display.total == 1 ? "" : "es")"
            return display.totalIsFinal ? base : base + "…"
        }
        return ""
    }
}

extension SearchOperator {
    var glyph: String {
        switch self {
        case .equals: "="
        case .notEquals: "≠"
        case .lessThan: "<"
        case .greaterThan: ">"
        case .lessOrEqual: "≤"
        case .greaterOrEqual: "≥"
        }
    }

    var accessibilityName: String {
        switch self {
        case .equals: "Equals"
        case .notEquals: "Not equal to"
        case .lessThan: "Less than"
        case .greaterThan: "Greater than"
        case .lessOrEqual: "Less than or equal to"
        case .greaterOrEqual: "Greater than or equal to"
        }
    }
}
