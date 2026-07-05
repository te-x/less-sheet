// less-sheet macOS app entry point.
//
// This file is `main.swift`, so its top-level code is the executable entry:
// mark process-start as early as possible, then hand off to the SwiftUI app.
// (Using a `main.swift` file precludes `@main`; calling `App.main()` explicitly
// is the supported equivalent.) The full UI — window, sticky-header Table,
// in-window error panel, File › Open…, launch-with-file / CLI open, and the
// checkable "First Row Is Header" menu item — lives in AppUI.swift; the
// cold-start timing marker is emitted from LaunchTiming.swift.
import Foundation

LaunchTiming.begin()
LessSheetApp.main()
