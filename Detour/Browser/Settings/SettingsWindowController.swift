import AppKit
import WebKit

// MARK: - SettingsWindowController

class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private static let profilesID = NSToolbarItem.Identifier("profiles")
    private static let contentBlockerID = NSToolbarItem.Identifier("contentblocker")

    private static let fixedWidth: CGFloat = 740

    private var panes: [NSToolbarItem.Identifier: NSViewController] = [:]
    private let paneOrder: [NSToolbarItem.Identifier] = [profilesID, contentBlockerID]

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

        let profilesVC = ProfilesSettingsViewController()
        panes[Self.profilesID] = profilesVC

        let contentBlockerVC = ContentBlockerSettingsViewController()
        panes[Self.contentBlockerID] = contentBlockerVC

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Self.profilesID
        window.toolbar = toolbar

        window.contentViewController = profilesVC
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
        case Self.profilesID:
            item.label = "Profiles"
            item.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Profiles")
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
