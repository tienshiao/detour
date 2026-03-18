import Foundation
import AppKit

/// Manages extension toolbar button identifiers and item creation.
class ExtensionToolbarManager {
    static let itemIdentifierPrefix = "com.detour.extension."

    /// Returns toolbar item identifiers for all enabled extensions that have an action.
    static func toolbarItemIdentifiers() -> [NSToolbarItem.Identifier] {
        ExtensionManager.shared.enabledExtensions
            .filter { $0.manifest.action != nil }
            .map { NSToolbarItem.Identifier(itemIdentifierPrefix + $0.id) }
    }

    /// Create a toolbar item for a given extension identifier.
    static func makeToolbarItem(identifier: NSToolbarItem.Identifier, target: AnyObject?) -> NSToolbarItem? {
        let extID = String(identifier.rawValue.dropFirst(itemIdentifierPrefix.count))
        guard let ext = ExtensionManager.shared.extension(withID: extID) else { return nil }

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = ext.manifest.name
        item.toolTip = ext.manifest.action?.defaultTitle ?? ext.manifest.name

        let image: NSImage
        if let icon = ext.icon {
            let size = NSSize(width: 20, height: 20)
            image = NSImage(size: size, flipped: false) { rect in
                icon.draw(in: rect)
                return true
            }
        } else {
            image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: ext.manifest.name)
                ?? NSImage(named: NSImage.actionTemplateName)!
        }

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
