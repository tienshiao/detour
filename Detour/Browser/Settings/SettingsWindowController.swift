import AppKit
import WebKit

// MARK: - SettingsWindowController

class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private static let generalID = NSToolbarItem.Identifier("general")
    private static let profilesID = NSToolbarItem.Identifier("profiles")
    private static let extensionsID = NSToolbarItem.Identifier("extensions")
    private static let contentBlockerID = NSToolbarItem.Identifier("contentblocker")

    private static let fixedWidth: CGFloat = 740

    private var panes: [NSToolbarItem.Identifier: NSViewController] = [:]
    private let paneOrder: [NSToolbarItem.Identifier] = [generalID, profilesID, extensionsID, contentBlockerID]

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsWindowController.fixedWidth, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.toolbarStyle = .preference
        window.center()

        super.init(window: window)

        let generalVC = GeneralSettingsViewController()
        panes[Self.generalID] = generalVC

        let profilesVC = ProfilesSettingsViewController()
        panes[Self.profilesID] = profilesVC

        let extensionsVC = ExtensionsSettingsViewController()
        panes[Self.extensionsID] = extensionsVC

        let contentBlockerVC = ContentBlockerSettingsViewController()
        panes[Self.contentBlockerID] = contentBlockerVC

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Self.generalID
        window.toolbar = toolbar

        window.contentViewController = generalVC
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.generalID:
            item.label = "General"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        case Self.profilesID:
            item.label = "Profiles"
            item.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Profiles")
        case Self.extensionsID:
            item.label = "Extensions"
            item.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")
        case Self.contentBlockerID:
            item.label = "Content Blocking"
            item.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Content Blocking")
        default:
            return nil
        }
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        paneOrder
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        paneOrder
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        paneOrder
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let vc = panes[sender.itemIdentifier] else { return }
        switchToPane(vc, identifier: sender.itemIdentifier)
    }

    /// Programmatically show the Extensions pane.
    func showExtensionsPane() {
        showWindow(nil)
        guard let vc = panes[Self.extensionsID] else { return }
        switchToPane(vc, identifier: Self.extensionsID)
    }

    private func switchToPane(_ vc: NSViewController, identifier: NSToolbarItem.Identifier) {
        guard let window else { return }
        window.toolbar?.selectedItemIdentifier = identifier

        let newHeight = vc.preferredContentSize.height
        let chrome = window.frame.height - window.contentLayoutRect.height
        let oldFrame = window.frame
        let newFrame = NSRect(
            x: oldFrame.origin.x,
            y: oldFrame.origin.y + oldFrame.height - newHeight - chrome,
            width: Self.fixedWidth,
            height: newHeight + chrome
        )

        window.contentViewController = vc
        window.setFrame(newFrame, display: true, animate: true)
    }
}
