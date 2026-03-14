import AppKit
import WebKit

// MARK: - SettingsWindowController

class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private static let generalID = NSToolbarItem.Identifier("general")

    private var panes: [NSToolbarItem.Identifier: NSViewController] = [:]
    private let paneOrder: [NSToolbarItem.Identifier] = [generalID]

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 200),
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
            item.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "General")
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

        let newSize = vc.preferredContentSize
        let oldFrame = window.frame
        let newFrame = NSRect(
            x: oldFrame.origin.x,
            y: oldFrame.origin.y + oldFrame.height - newSize.height - (oldFrame.height - window.contentLayoutRect.height),
            width: newSize.width,
            height: newSize.height + (oldFrame.height - window.contentLayoutRect.height)
        )

        window.contentViewController = vc
        window.setFrame(newFrame, display: true, animate: true)
    }
}

// MARK: - GeneralSettingsViewController

class GeneralSettingsViewController: NSViewController {
    override func loadView() {
        preferredContentSize = NSSize(width: 450, height: 80)

        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        self.view = container

        let margin: CGFloat = 20

        let noteLabel = NSTextField(wrappingLabelWithString: "User agent and archive settings are now configured per-profile. Edit a space to change its profile settings.")
        noteLabel.font = .systemFont(ofSize: 13)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(noteLabel)

        NSLayoutConstraint.activate([
            noteLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            noteLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            noteLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
        ])
    }
}
