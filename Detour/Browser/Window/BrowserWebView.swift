import WebKit

class BrowserWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // Find the window controller to set the context menu action
        let windowController = window?.windowController as? BrowserWindowController

        // Find WebKit's "Open Link in New Window" item by identifier
        let openInNewWindowID = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        guard let originalItem = menu.items.first(where: { $0.identifier == openInNewWindowID }) else {
            return  // Not a link context menu
        }

        // Remove WebKit's default link-opening items
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

        // "Open Link in New Tab"
        let newTabItem = NSMenuItem(title: "Open Link in New Tab", action: #selector(BrowserWindowController.contextMenuOpenInNewTab(_:)), keyEquivalent: "")
        newTabItem.representedObject = originalItem
        newTabItem.target = windowController
        newTabItem.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
        menu.insertItem(newTabItem, at: min(insertIndex, menu.items.count))

        // "Open Link in New Window"
        let newWindowItem = NSMenuItem(title: "Open Link in New Window", action: #selector(BrowserWindowController.contextMenuOpenInNewWindow(_:)), keyEquivalent: "")
        newWindowItem.representedObject = originalItem
        newWindowItem.target = windowController
        newWindowItem.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil)
        menu.insertItem(newWindowItem, at: min(insertIndex + 1, menu.items.count))
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
