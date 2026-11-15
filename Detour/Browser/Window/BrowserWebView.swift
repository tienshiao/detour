import WebKit

class BrowserWebView: WKWebView {
    /// The link menu's Quick Detour item (TASK-300).
    static let openLinkInQuickDetourTitle = "Open Link in \(QuickDetour.displayName)"

    // MARK: - Split pane focus

    /// Clicking a pane of a split tab moves focus between panes; the window
    /// controller retargets `selectedTabID` and rebinds chrome (no-op when the
    /// selected tab isn't in a split).
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            (window?.windowController as? BrowserWindowController)?
                .browserWebViewDidBecomeFirstResponder(self)
        }
        return accepted
    }

    // MARK: - Navigation swipe (TASK-325)

    /// Detour's own back swipe on this web view; the window that hosts it
    /// keeps it (`BrowserWindowController+NavigationSwipe`).
    var navigationSwipe = NavigationSwipeViewState()

    /// A three-finger "swipe between pages" arrives here as one discrete
    /// event, and WebKit ignores it while its own gesture is off: in the own
    /// mode the window does what the swipe asks.
    override func swipe(with event: NSEvent) {
        if (window?.windowController as? BrowserWindowController)?.handleDiscreteNavigationSwipe(event, on: self) == true {
            return
        }
        super.swipe(with: event)
    }

    /// The rest of a gesture that completed Detour's own swipe (its momentum)
    /// must not scroll the page now under the pointer: after a close, the
    /// opener's.
    override func scrollWheel(with event: NSEvent) {
        if (window?.windowController as? BrowserWindowController)?.swallowsScrollAfterNavigationSwipe(event) == true {
            return
        }
        super.scrollWheel(with: event)
    }

    // MARK: - Back and Forward (TASK-331)

    /// `WKWebView` has its own `goBack:` and `goForward:` actions, enabled by
    /// WebKit's back list, and while the page has the keys it is ahead of the
    /// window controller in the responder chain: Navigate > Back (Cmd+[, or
    /// whatever key the user bound) on a tab opened from another one, with no
    /// back item, found it disabled instead of closing the tab to its opener.
    /// In a browser window both go to the controller, which acts on the
    /// focused pane (this view, once first responder) or an open Peek, and
    /// are enabled by its rule. A Quick Detour window keeps WebKit's.
    /// The hand-off stays the last thing these do: Back can close the tab
    /// that owns this view.
    override func goBack(_ sender: Any?) {
        guard let controller = window?.windowController as? BrowserWindowController else {
            return super.goBack(sender)
        }
        controller.goBack(sender)
    }

    override func goForward(_ sender: Any?) {
        guard let controller = window?.windowController as? BrowserWindowController else {
            return super.goForward(sender)
        }
        controller.goForward(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let back = #selector(goBack(_:)), forward = #selector(goForward(_:))
        guard let controller = window?.windowController as? BrowserWindowController,
              let action = item.action, action == back || action == forward else {
            return super.validateUserInterfaceItem(item)
        }
        if let menuItem = item as? NSMenuItem { return controller.validateMenuItem(menuItem) }
        return (action == back ? BrowserCommands.back : BrowserCommands.forward).isAvailable(in: controller)
    }

    // MARK: - Undo/Redo (TASK-345)

    /// True when the user is focused on an editable element (input, textarea, contentEditable).
    /// Set by the `editableFieldFocus` script (focus changes, page loads, and
    /// Cmd+Z itself; `Space.editableFieldFocusScript`). While it is, and this view is
    /// the window's first responder, Edit > Undo and Redo run this page's
    /// undo (`BrowserWindowController.undoTarget`).
    var isEditingWebContent = false

    /// This page's own undo stack. WebKit registers the page's edits with the
    /// view's `undoManager` (`WebViewImpl::registerEditCommand`) and runs the
    /// page's `execCommand('undo')` on it; inherited, that was the window's
    /// (measured: TASK-345), shared by both panes of a split and by the
    /// window's own text fields, so one page's undo could reach the other
    /// pane's edits or a field's. WebKit still drops the page's edits whenever the view moves into or
    /// out of a window (`viewWillMoveToWindow` -> `clearAllEditCommands`):
    /// after a tab switch the page has nothing to undo.
    private let pageUndoManager = UndoManager()

    override var undoManager: UndoManager? { pageUndoManager }

    /// The page in `window` whose own undo Edit > Undo and Redo run now, if
    /// any (`BrowserWindowController.undoTarget`), in a browser window or a
    /// Quick Detour one. Its editing flag alone is not enough: it stays set
    /// when the keys move out of the page with a field focused (no
    /// focusout), so the web view must also have the window's keys.
    static func editingPage(in window: NSWindow?) -> BrowserWebView? {
        guard let window, let webView = window.firstResponder as? BrowserWebView else { return nil }
        let isKeyWindow = NSApp.keyWindow.map { $0 === window } ?? true
        guard BrowserWindowController.undoTarget(focusedPageIsEditing: webView.isEditingWebContent,
                                                 isKeyWindow: isKeyWindow) == .page else { return nil }
        return webView
    }

    // Cmd+Z and Shift+Cmd+Z are not taken here (TASK-345): with this view
    // first responder, WebKit's `performKeyEquivalent` sends the key to the
    // page; one the page does not handle comes back through
    // `-[NSApp sendEvent:]` (`WebViewImpl::doneWithKeyEvent`), and on that
    // pass WebKit hands it straight to AppKit, so the main menu's Edit > Undo
    // or Redo gets it, once. An override here would see the key on both
    // passes and could not tell them apart.

    override func otherMouseDown(with event: NSEvent) {
        // Mouse button 3 = back button
        if event.buttonNumber == 3 {
            // A browser window or a Quick Detour window (TASK-193.1).
            let goBack = #selector(BrowserWindowController.goBack(_:))
            if let controller = window?.windowController, controller.responds(to: goBack) {
                controller.perform(goBack, with: nil)
            }
            return
        }
        super.otherMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        let windowController = window?.windowController as? BrowserWindowController

        // --- Standard link menu customization ---
        // Only a browser window replaces WebKit's link items: a Quick Detour
        // window keeps Open Link (in place) and Open Link in New Window, which
        // opens another Quick Detour (TASK-193.1).
        let openInNewWindowID = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        if windowController != nil, let originalItem = menu.items.first(where: { $0.identifier == openInNewWindowID }) {
            let linkIdentifiers: Set<NSUserInterfaceItemIdentifier> = [
                NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow"),
                NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink"),
            ]
            let insertIndex = menu.items.firstIndex(where: {
                guard let id = $0.identifier else { return false }
                return linkIdentifiers.contains(id)
            }) ?? 0
            menu.items.removeAll {
                guard let id = $0.identifier else { return false }
                return linkIdentifiers.contains(id)
            }

            let newTabItem = NSMenuItem(title: "Open Link in New Tab", action: #selector(BrowserWindowController.contextMenuOpenInNewTab(_:)), keyEquivalent: "")
            newTabItem.representedObject = originalItem
            newTabItem.target = windowController
            newTabItem.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
            menu.insertItem(newTabItem, at: min(insertIndex, menu.items.count))

            let newWindowItem = NSMenuItem(title: "Open Link in New Window", action: #selector(BrowserWindowController.contextMenuOpenInNewWindow(_:)), keyEquivalent: "")
            newWindowItem.representedObject = originalItem
            newWindowItem.target = windowController
            newWindowItem.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil)
            menu.insertItem(newWindowItem, at: min(insertIndex + 1, menu.items.count))

            // What Opt-Cmd-click does (TASK-300), offered whatever its setting
            // says (the setting governs only the gesture), inside a Peek too.
            let quickDetourItem = NSMenuItem(title: Self.openLinkInQuickDetourTitle,
                                             action: #selector(BrowserWindowController.contextMenuOpenInQuickDetour(_:)),
                                             keyEquivalent: "")
            quickDetourItem.representedObject = originalItem
            quickDetourItem.target = windowController
            quickDetourItem.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
            menu.insertItem(quickDetourItem, at: min(insertIndex + 2, menu.items.count))

            // Not in a Peek: its page hands over to a split by the panel's own
            // button, and Option-click inside a Peek is left alone too.
            if let windowController, windowController.selectedTab?.peekTab?.webView !== self {
                let splitItem = NSMenuItem(title: "Open Link in Split View", action: #selector(BrowserWindowController.contextMenuOpenInSplitView(_:)), keyEquivalent: "")
                splitItem.representedObject = originalItem
                splitItem.target = windowController
                splitItem.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
                menu.insertItem(splitItem, at: min(insertIndex + 3, menu.items.count))
            }
        }

        // --- Extension context menu items ---
        if let windowController {
            appendExtensionMenuItems(to: menu, tab: windowController.selectedTab,
                                     profileID: windowController.activeSpace?.profileID)
        } else if let quick = window?.windowController as? QuickDetourWindowController {
            appendExtensionMenuItems(to: menu, tab: quick.tab, profileID: quick.profile.id)
        }
    }

    private func appendExtensionMenuItems(to menu: NSMenu, tab: BrowserTab?, profileID: UUID?) {
        guard let tab, let profileID,
              let profile = TabStore.shared.profiles.first(where: { $0.id == profileID }) else { return }

        // Use the native WKWebExtensionContext.menuItems(for:) API — WKWebExtension
        // handles chrome.contextMenus internally and returns ready-to-use NSMenuItems.
        var allItems: [NSMenuItem] = []
        for context in profile.extensionContexts.values {
            context.userGesturePerformed(in: tab)
            let items = context.menuItems(for: tab)
            allItems.append(contentsOf: items)
        }

        guard !allItems.isEmpty else { return }
        menu.addItem(NSMenuItem.separator())
        for item in allItems {
            menu.addItem(item)
        }
    }
}

// Actions are on BrowserWindowController so they have access to tab/space state
extension BrowserWindowController {
    @objc func contextMenuOpenInNewTab(_ sender: NSMenuItem) {
        guard let originalItem = sender.representedObject as? NSMenuItem else { return }
        contextMenuLinkAction = .openInNewTab
        _ = originalItem.target?.perform(originalItem.action, with: originalItem)
    }

    @objc func contextMenuOpenInNewWindow(_ sender: NSMenuItem) {
        guard let originalItem = sender.representedObject as? NSMenuItem else { return }
        contextMenuLinkAction = .openInNewWindow
        _ = originalItem.target?.perform(originalItem.action, with: originalItem)
    }

    /// Open Link in Split View: Option-click's rules for the tab the menu is in
    /// (TASK-185), applied in `createWebViewWith`.
    @objc func contextMenuOpenInSplitView(_ sender: NSMenuItem) {
        guard let originalItem = sender.representedObject as? NSMenuItem else { return }
        contextMenuLinkAction = .openInSplitView
        _ = originalItem.target?.perform(originalItem.action, with: originalItem)
    }

    /// Open Link in Quick Detour (TASK-300): Opt-Cmd-click's rules for the
    /// link, applied in `createWebViewWith`.
    @objc func contextMenuOpenInQuickDetour(_ sender: NSMenuItem) {
        guard let originalItem = sender.representedObject as? NSMenuItem else { return }
        contextMenuLinkAction = .openInQuickDetour
        _ = originalItem.target?.perform(originalItem.action, with: originalItem)
    }

}
