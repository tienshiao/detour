import WebKit

class BrowserWebView: WKWebView {
    // MARK: - Undo/Redo

    /// True when the user is focused on an editable element (input, textarea, contentEditable).
    /// Set via a JS focus/blur message handler.
    var isEditingWebContent = false

    /// When editing web content, let WKWebView handle Cmd+Z (text undo).
    /// Otherwise, do browser undo (close tab, move tab, etc.).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "z" {
            if !isEditingWebContent, TabStore.shared.undoManager.canUndo {
                TabStore.shared.undoManager.undo()
                return true
            }
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers == "z" {
            if !isEditingWebContent, TabStore.shared.undoManager.canRedo {
                TabStore.shared.undoManager.redo()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        // Mouse button 3 = back button
        if event.buttonNumber == 3 {
            (window?.windowController as? BrowserWindowController)?.goBack(nil)
            return
        }
        super.otherMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        let windowController = window?.windowController as? BrowserWindowController

        // --- Standard link menu customization ---
        let openInNewWindowID = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        if let originalItem = menu.items.first(where: { $0.identifier == openInNewWindowID }) {
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
        }

        // --- Extension context menu items ---
        appendExtensionMenuItems(to: menu, windowController: windowController)
    }

    private func appendExtensionMenuItems(to menu: NSMenu, windowController: BrowserWindowController?) {
        guard let tab = windowController?.selectedTab,
              let profileID = windowController?.activeSpace?.profileID,
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

}
