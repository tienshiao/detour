import WebKit

class BrowserWebView: WKWebView {
    /// Context info captured from the most recent right-click event.
    var lastContextInfo: [String: String]?

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
        // Detect the active contexts from WebKit's default menu items
        var contexts: Set<String> = ["page"]

        let itemIDs = Set(menu.items.compactMap { $0.identifier?.rawValue })

        // Link context: WebKit adds "OpenLinkInNewWindow" for links
        let hasLink = itemIDs.contains("WKMenuItemIdentifierOpenLinkInNewWindow")
            || itemIDs.contains("WKMenuItemIdentifierOpenLink")
        if hasLink { contexts.insert("link") }

        // Image context: WebKit adds copy/download image items
        let hasImage = itemIDs.contains("WKMenuItemIdentifierCopyImage")
            || itemIDs.contains("WKMenuItemIdentifierDownloadImage")
        if hasImage { contexts.insert("image") }

        // Selection context: WebKit adds "Copy" or "Look Up" items when text is selected
        let hasCopy = itemIDs.contains("WKMenuItemIdentifierCopy")
        let hasLookUp = itemIDs.contains("WKMenuItemIdentifierLookUp")
        if hasCopy || hasLookUp { contexts.insert("selection") }

        // Get the context info we captured from the contextmenu DOM event
        let contextInfo = lastContextInfo

        // Filter to extensions enabled for the current profile
        let profileID = windowController?.activeSpace?.profileID
        let enabledIDs: Set<String>
        if let profileID {
            enabledIDs = Set(ExtensionManager.shared.enabledExtensions(for: profileID).map { $0.id })
        } else {
            enabledIDs = Set(ExtensionManager.shared.enabledExtensions.map { $0.id })
        }

        let extensionItems = ExtensionManager.shared.allContextMenuItems.filter { item, extID in
            guard enabledIDs.contains(extID) else { return false }
            // Show if any of the item's contexts match the detected contexts, or "all"
            return item.contexts.contains("all") || !Set(item.contexts).isDisjoint(with: contexts)
        }

        guard !extensionItems.isEmpty else { return }

        menu.addItem(NSMenuItem.separator())
        for (ctxItem, extID) in extensionItems {
            guard ctxItem.type != "separator" else {
                menu.addItem(NSMenuItem.separator())
                continue
            }

            // Chrome supports %s in titles, replaced with selected text
            var displayTitle = ctxItem.title
            if let sel = contextInfo?["selectionText"], !sel.isEmpty {
                displayTitle = displayTitle.replacingOccurrences(of: "%s", with: sel)
            }

            let menuItem = NSMenuItem(
                title: displayTitle,
                action: #selector(BrowserWindowController.contextMenuExtensionAction(_:)),
                keyEquivalent: ""
            )
            var info: [String: String] = ["menuItemId": ctxItem.id, "extensionID": extID]
            // Attach context info so the action handler has linkUrl/srcUrl/selectionText
            if let contextInfo {
                info.merge(contextInfo) { current, _ in current }
            }
            menuItem.representedObject = info
            menuItem.target = windowController

            if let ext = ExtensionManager.shared.extension(withID: extID),
               let icon = ext.icon {
                let resized = NSImage(size: NSSize(width: 16, height: 16))
                resized.lockFocus()
                icon.draw(in: NSRect(origin: .zero, size: NSSize(width: 16, height: 16)))
                resized.unlockFocus()
                menuItem.image = resized
            }

            menu.addItem(menuItem)
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

    @objc func contextMenuExtensionAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let menuItemId = info["menuItemId"],
              let extensionID = info["extensionID"] else { return }

        guard let space = activeSpace, let tab = selectedTab else { return }

        // Build click info from the pre-captured context
        var clickInfo: [String: Any] = ["menuItemId": menuItemId]
        if let url = tab.url {
            clickInfo["pageUrl"] = url.absoluteString
        }
        if let linkUrl = info["linkUrl"], !linkUrl.isEmpty {
            clickInfo["linkUrl"] = linkUrl
        }
        if let srcUrl = info["srcUrl"], !srcUrl.isEmpty {
            clickInfo["srcUrl"] = srcUrl
        }
        if let selectionText = info["selectionText"], !selectionText.isEmpty {
            clickInfo["selectionText"] = selectionText
        }

        let tabInfo = ExtensionMessageBridge.shared.buildTabInfo(tab: tab, space: space, isActive: true)

        ExtensionManager.shared.dispatchContextMenuClicked(
            menuItemId: menuItemId, info: clickInfo, tab: tabInfo, extensionID: extensionID)
    }
}
