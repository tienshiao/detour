import Foundation
import AppKit
import WebKit

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
        let displayName = ExtensionManager.shared.displayName(for: extID)

        item.label = displayName
        item.toolTip = ext.manifest.action?.defaultTitle.map { ext.resolveI18n($0) } ?? displayName

        let image = iconImage(for: extID, ext: ext)

        let button = NSButton(image: image, target: target,
                              action: #selector(ExtensionToolbarActions.extensionToolbarItemClicked(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.setFrameSize(NSSize(width: 28, height: 22))
        button.identifier = NSUserInterfaceItemIdentifier(extID)
        item.view = button

        return item
    }

    /// Build the icon image for a toolbar button, compositing badge text from WKWebExtension.Action.
    private static func iconImage(for extID: String, ext: WebExtension) -> NSImage {
        // Try to get badge info from the native WKWebExtension.Action
        let context = ExtensionManager.shared.context(for: extID)
        let action = context?.action(for: nil) // nil = default action (not tab-specific)
        let badgeText = action?.badgeText ?? ""

        let baseIcon: NSImage
        if let actionIcon = action?.icon(for: NSSize(width: 20, height: 20)) {
            baseIcon = actionIcon
        } else if let icon = ext.icon {
            baseIcon = icon
        } else {
            return NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: ext.manifest.name)
                ?? NSImage(named: NSImage.actionTemplateName)!
        }

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

            let badgeColor = NSColor.systemRed
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

        for window in NSApp.windows {
            guard let toolbar = window.toolbar else { continue }
            for item in toolbar.items where item.itemIdentifier == identifier {
                item.toolTip = ext.manifest.action?.defaultTitle.map { ext.resolveI18n($0) } ?? ExtensionManager.shared.displayName(for: extensionID)

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
