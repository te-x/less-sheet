import AppKit
import Foundation

// The main menu, assembled in code.
//
// It used to come from a SwiftUI `App` whose entire job was to carry these
// commands: the single window is delegate-owned and the Settings window is a
// plain NSWindow, so the `Scene` graph rendered nothing. Carrying it cost about
// 7 ms of every launch (196.5 -> 189.0 ms median to first row pixels, n=26
// interleaved runs), so the commands moved here and the app runs on AppKit's own
// lifecycle.
//
// The layout mirrors what SwiftUI produced, item for item and shortcut for
// shortcut, with two visible exceptions: SwiftUI's empty "View" menu is gone,
// and the doubled separator its removed Settings group left in the app menu is
// a single one. A hidden "Toggle Sidebar" item it put in Help is gone too.
extension AppDelegate {
    func installMainMenu() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "less-sheet"
        let main = NSMenu()
        main.addItem(container(appMenu(name)))
        main.addItem(container(fileMenu()))
        main.addItem(container(editMenu()))
        main.addItem(container(goMenu()))
        main.addItem(container(findMenu()))
        let windows = windowMenu()
        main.addItem(container(windows))
        let help = helpMenu(name)
        main.addItem(container(help))
        NSApp.mainMenu = main
        // Set AFTER installation: AppKit populates the window list and appends
        // the standard help entry through these two references.
        NSApp.windowsMenu = windows
        NSApp.helpMenu = help
    }

    // MARK: - Menus

    private func appMenu(_ name: String) -> NSMenu {
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                          modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open…", #selector(menuOpenFile(_:)), "o", target: self))
        menu.addItem(item("Open URL…", #selector(menuOpenURL(_:)), "o",
                          modifiers: [.command, .shift], target: self))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    /// Cut/Copy/Paste/Select All keep a nil target on purpose: they travel the
    /// responder chain, which is how the grid's own `copy:` and `selectAll:`
    /// receive ⌘C and ⌘A.
    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:)), ""))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Jump to Row…", #selector(menuJumpToRow(_:)), "j", target: self))
        return menu
    }

    private func findMenu() -> NSMenu {
        let menu = NSMenu(title: "Find")
        menu.addItem(item("Find…", #selector(menuFind(_:)), "f", target: self))
        menu.addItem(item("Find Next", #selector(menuFindNext(_:)), "g", target: self))
        menu.addItem(item("Find Previous", #selector(menuFindPrevious(_:)), "g",
                          modifiers: [.command, .shift], target: self))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        return menu
    }

    private func helpMenu(_ name: String) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("\(name) Help", #selector(NSApplication.showHelp(_:)), "?"))
        return menu
    }

    // MARK: - Building blocks

    private func container(_ submenu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        entry.submenu = submenu
        return entry
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      modifiers: NSEvent.ModifierFlags = .command,
                      target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { entry.keyEquivalentModifierMask = modifiers }
        entry.target = target
        return entry
    }

    // MARK: - Actions

    @objc fileprivate func menuOpenFile(_ sender: Any?) { AppDelegate.openViaPanel() }
    @objc fileprivate func menuOpenURL(_ sender: Any?) { AppDelegate.openURLViaSheet() }
    @objc fileprivate func menuJumpToRow(_ sender: Any?) { DocumentModel.shared.requestJumpFocus() }
    @objc fileprivate func menuFind(_ sender: Any?) { DocumentModel.shared.requestFindFocus() }
    @objc fileprivate func menuFindNext(_ sender: Any?) { DocumentModel.shared.stepFind(.forward) }
    @objc fileprivate func menuFindPrevious(_ sender: Any?) { DocumentModel.shared.stepFind(.backward) }
}
