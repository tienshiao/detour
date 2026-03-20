import Foundation
import AppKit

/// Manages extension toolbar button identifiers and item creation.
class ExtensionToolbarManager {
    static let itemIdentifierPrefix = "com.detour.extension."

    /// Returns toolbar item identifiers for extensions enabled for the given profile that have an action.
    static func toolbarItemIdentifiers(profileID: UUID? = nil) -> [NSToolbarItem.Identifier] {
        let exts: [WebExtension]
        if let profileID {
            exts = ExtensionManager.shared.enabledExtensions(for: profileID)
        } else {
            exts = ExtensionManager.shared.enabledExtensions
        }
        return exts
            .filter { $0.manifest.action != nil }
            .map { NSToolbarItem.Identifier(itemIdentifierPrefix + $0.id) }
    }

    /// Create a toolbar item for a given extension identifier.
    static func makeToolbarItem(identifier: NSToolbarItem.Identifier, target: AnyObject?) -> NSToolbarItem? {
        let extID = String(identifier.rawValue.dropFirst(itemIdentifierPrefix.count))
        guard let ext = ExtensionManager.shared.extension(withID: extID) else { return nil }

        let item = NSToolbarItem(itemIdentifier: identifier)
        let resolvedName = ExtensionI18n.resolve(ext.manifest.name, messages: ext.messages)
        let resolvedTitle = ext.manifest.action?.defaultTitle.map { ExtensionI18n.resolve($0, messages: ext.messages) }

        item.label = resolvedName
        item.toolTip = ExtensionManager.shared.actionTitle[extID] ?? resolvedTitle ?? resolvedName

        let image = iconImage(for: extID, ext: ext)

        // Use an NSButton as the toolbar item's view so clicks work reliably
        let button = NSButton(image: image, target: target,
                              action: #selector(ExtensionToolbarActions.extensionToolbarItemClicked(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.setFrameSize(NSSize(width: 28, height: 22))
        // Store the extension ID on the button so the handler can retrieve it
        button.identifier = NSUserInterfaceItemIdentifier(extID)
        item.view = button

        return item
    }

    /// Build the icon image for a toolbar button, compositing badge text if set.
    private static func iconImage(for extID: String, ext: WebExtension) -> NSImage {
        let mgr = ExtensionManager.shared
        let baseIcon: NSImage
        if let customIcon = mgr.customIcons[extID] {
            baseIcon = customIcon
        } else if let icon = ext.icon {
            baseIcon = icon
        } else {
            return NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: ext.manifest.name)
                ?? NSImage(named: NSImage.actionTemplateName)!
        }

        let badgeText = mgr.badgeText[extID] ?? ""
        let size = NSSize(width: 20, height: 20)

        if badgeText.isEmpty {
            return NSImage(size: size, flipped: false) { rect in
                baseIcon.draw(in: rect)
                return true
            }
        }

        // Composite icon with badge
        return NSImage(size: size, flipped: false) { rect in
            baseIcon.draw(in: rect)

            let badgeColor = mgr.badgeBackgroundColor[extID] ?? NSColor.systemRed
            let badgeFont = NSFont.systemFont(ofSize: 7, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: badgeFont,
                .foregroundColor: NSColor.white
            ]
            let textSize = (badgeText as NSString).size(withAttributes: attrs)
            let badgeWidth = max(textSize.width + 4, 10)
            let badgeHeight: CGFloat = 9
            let badgeRect = NSRect(
                x: rect.maxX - badgeWidth,
                y: rect.minY,
                width: badgeWidth,
                height: badgeHeight
            )

            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3)
            badgeColor.setFill()
            badgePath.fill()

            let textRect = NSRect(
                x: badgeRect.midX - textSize.width / 2,
                y: badgeRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            (badgeText as NSString).draw(in: textRect, withAttributes: attrs)

            return true
        }
    }

    /// Update the toolbar button for a specific extension (called when action state changes).
    static func updateToolbarButton(for extensionID: String) {
        guard let ext = ExtensionManager.shared.extension(withID: extensionID) else { return }
        let identifier = NSToolbarItem.Identifier(itemIdentifierPrefix + extensionID)

        // Find all windows and update their toolbar items
        for window in NSApp.windows {
            guard let toolbar = window.toolbar else { continue }
            for item in toolbar.items where item.itemIdentifier == identifier {
                let mgr = ExtensionManager.shared
                let resolvedName = ExtensionI18n.resolve(ext.manifest.name, messages: ext.messages)
                let resolvedTitle = ext.manifest.action?.defaultTitle.map { ExtensionI18n.resolve($0, messages: ext.messages) }
                item.toolTip = mgr.actionTitle[extensionID] ?? resolvedTitle ?? resolvedName

                let image = iconImage(for: extensionID, ext: ext)
                if let button = item.view as? NSButton {
                    button.image = image
                }
            }
        }
    }

    /// Extract extension ID from a toolbar item identifier.
    static func extensionID(from identifier: NSToolbarItem.Identifier) -> String? {
        let raw = identifier.rawValue
        guard raw.hasPrefix(itemIdentifierPrefix) else { return nil }
        return String(raw.dropFirst(itemIdentifierPrefix.count))
    }
}

/// Protocol for toolbar item click handling. Adopted by BrowserWindowController.
@objc protocol ExtensionToolbarActions {
    @objc func extensionToolbarItemClicked(_ sender: Any)
}
