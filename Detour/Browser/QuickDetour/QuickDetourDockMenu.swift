import AppKit

// TASK-309: the Dock menu's Hide All / Show All Quick Detour Windows item,
// after Arc's "Show/Hide All Little Arc Windows". Hiding orders the windows
// out: they stay open with their pages, and their idle auto-close keeps
// running (a hidden window is one behind the others: never frontmost).
// Private Quick Detours are included; quarantine windows are not (they are
// not Quick Detours on a profile, and the menu does not name them).

/// Where one Quick Detour window is, as the Dock menu item sees it.
enum QuickDetourDockWindowState: Equatable {
    /// On screen (perhaps behind other windows, or on another desktop).
    case onScreen
    /// Ordered out by the item's Hide All, and still out.
    case hiddenByDockMenu
    /// Neither: minimized, or out with the app hidden.
    case elsewhere
}

/// What the Dock menu item does, and its title.
enum QuickDetourDockAction: String, Equatable {
    case hideAll
    case showAll

    var title: String {
        switch self {
        case .hideAll: return "Hide All \(QuickDetour.displayName) Windows"
        case .showAll: return "Show All \(QuickDetour.displayName) Windows"
        }
    }

    /// The item for the open Quick Detours' `states`: Hide All while any is
    /// on screen (a new one opened after a Hide All shows normally, and the
    /// item then hides it with the others); Show All once none is but some
    /// were hidden by the item; none at all when no Quick Detour is open, or
    /// when every one is minimized (nothing to hide, nothing hidden).
    static func action(for states: [QuickDetourDockWindowState]) -> QuickDetourDockAction? {
        if states.contains(.onScreen) { return .hideAll }
        if states.contains(.hiddenByDockMenu) { return .showAll }
        return nil
    }
}

extension QuickDetourWindowController {
    /// The windows the Dock menu item acts on: every open Quick Detour,
    /// Private ones included, quarantine windows not.
    static var dockMenuControllers: [QuickDetourWindowController] {
        openControllers.filter { !$0.isQuarantine }
    }

    var dockWindowState: QuickDetourDockWindowState {
        guard let window else { return .elsewhere }
        if window.isVisible, !window.isMiniaturized { return .onScreen }
        if isOrderedOutByDockMenu, !window.isVisible, !window.isMiniaturized { return .hiddenByDockMenu }
        return .elsewhere
    }

    /// The Dock menu item's action now; nil when it is not offered.
    static var dockMenuAction: QuickDetourDockAction? {
        QuickDetourDockAction.action(for: dockMenuControllers.map(\.dockWindowState))
    }

    /// Hide All: orders out every Quick Detour on screen. They stay open.
    static func hideAllFromDockMenu() {
        for controller in dockMenuControllers where controller.dockWindowState == .onScreen {
            controller.isOrderedOutByDockMenu = true
            controller.window?.orderOut(nil)
        }
    }

    /// Show All: brings back every Quick Detour the item hid, in the order
    /// they were opened, the newest in front and key, and Detour forward.
    static func showAllFromDockMenu() {
        let hidden = dockMenuControllers.filter { $0.dockWindowState == .hiddenByDockMenu }
        for controller in hidden {
            controller.isOrderedOutByDockMenu = false
            controller.window?.orderFront(nil)
        }
        guard let front = hidden.last?.window else { return }
        NSApp.activate()
        front.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate {
    /// Adds the Hide All / Show All Quick Detour Windows item to the Dock
    /// menu when there is something for it to do.
    func addQuickDetourDockMenuItem(to menu: NSMenu) {
        guard let action = QuickDetourWindowController.dockMenuAction else { return }
        menu.addItem(.separator())
        let item = NSMenuItem(title: action.title, action: #selector(quickDetourDockMenuItemChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        menu.addItem(item)
    }

    /// Does what the item said when the menu was built.
    @objc func quickDetourDockMenuItemChosen(_ sender: NSMenuItem) {
        switch (sender.representedObject as? String).flatMap(QuickDetourDockAction.init(rawValue:)) {
        case .hideAll: QuickDetourWindowController.hideAllFromDockMenu()
        case .showAll: QuickDetourWindowController.showAllFromDockMenu()
        case nil: break
        }
    }
}
