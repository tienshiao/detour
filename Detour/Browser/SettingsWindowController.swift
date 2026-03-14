import AppKit
import WebKit

// MARK: - UserAgentMode

enum UserAgentMode: Int {
    case detour = 0
    case safari = 1
    case custom = 2

    static var current: UserAgentMode {
        UserAgentMode(rawValue: UserDefaults.standard.integer(forKey: "userAgentMode")) ?? .detour
    }

    /// Constructs a Safari-matching UA using the real macOS version and Safari version.
    /// AppleWebKit/605.1.15 and Safari/605.1.15 are frozen tokens that never change.
    static var safariUserAgent: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion)_\(os.minorVersion)_\(os.patchVersion)"
        let safariVersion: String
        if let bundle = Bundle(path: "/Applications/Safari.app"),
           let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
            safariVersion = version
        } else {
            safariVersion = "18.0"
        }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osString)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }

    static var detourAppName: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        let major = version.split(separator: ".").first.map(String.init) ?? "1"
        return "Detour/\(major)"
    }
}

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
    private let popUpButton = NSPopUpButton()
    private let customField = NSTextField()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private var baseUserAgent: String = ""
    private var uaProbeWebView: WKWebView?

    // Constraints toggled when custom row shows/hides
    private var customRowTopConstraint: NSLayoutConstraint!
    private var previewTopToCustomConstraint: NSLayoutConstraint!
    private var previewTopToPopupConstraint: NSLayoutConstraint!

    override func loadView() {
        preferredContentSize = NSSize(width: 450, height: 150)

        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        self.view = container

        let labelWidth: CGFloat = 90
        let margin: CGFloat = 20
        let controlLeading: CGFloat = margin + labelWidth + 8

        // Row 1: User Agent
        let uaLabel = NSTextField(labelWithString: "User Agent:")
        uaLabel.alignment = .right
        uaLabel.font = .systemFont(ofSize: 13)

        popUpButton.addItems(withTitles: ["Detour (default)", "Safari", "Custom"])
        popUpButton.target = self
        popUpButton.action = #selector(userAgentModeChanged(_:))

        // Row 2: Custom field (conditional)
        customField.placeholderString = "Enter custom user agent string…"
        customField.font = .systemFont(ofSize: 12)
        customField.target = self
        customField.action = #selector(customUserAgentChanged(_:))

        // Row 3: Preview
        let previewHeaderLabel = NSTextField(labelWithString: "Preview:")
        previewHeaderLabel.alignment = .right
        previewHeaderLabel.font = .systemFont(ofSize: 13)

        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.isSelectable = true
        previewLabel.maximumNumberOfLines = 3

        for v: NSView in [uaLabel, popUpButton, customField, previewHeaderLabel, previewLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }

        // Build constraints
        previewTopToCustomConstraint = previewHeaderLabel.topAnchor.constraint(equalTo: customField.bottomAnchor, constant: 12)
        previewTopToPopupConstraint = previewHeaderLabel.topAnchor.constraint(equalTo: popUpButton.bottomAnchor, constant: 12)

        NSLayoutConstraint.activate([
            // Row 1
            uaLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            uaLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            uaLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            popUpButton.centerYAnchor.constraint(equalTo: uaLabel.centerYAnchor),
            popUpButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: controlLeading),

            // Row 2: custom field
            customField.topAnchor.constraint(equalTo: popUpButton.bottomAnchor, constant: 8),
            customField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: controlLeading),
            customField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            // Row 3: preview
            previewHeaderLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            previewHeaderLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            previewLabel.topAnchor.constraint(equalTo: previewHeaderLabel.topAnchor),
            previewLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: controlLeading),
            previewLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
        ])

        // Load current values
        let mode = UserAgentMode.current
        popUpButton.selectItem(at: mode.rawValue)
        customField.stringValue = UserDefaults.standard.string(forKey: "customUserAgent") ?? ""
        updateCustomFieldVisibility(mode: mode, animated: false)

        // Fetch the base WebKit user agent string for preview
        fetchBaseUserAgent()
    }

    private func fetchBaseUserAgent() {
        let probe = WKWebView(frame: .zero)
        uaProbeWebView = probe
        probe.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            guard let self, let ua = result as? String else { return }
            self.baseUserAgent = ua
            self.uaProbeWebView = nil
            self.updatePreview()
        }
    }

    private func updateCustomFieldVisibility(mode: UserAgentMode, animated: Bool = true) {
        let showCustom = mode == .custom
        customField.isHidden = !showCustom

        previewTopToCustomConstraint.isActive = showCustom
        previewTopToPopupConstraint.isActive = !showCustom

        let newHeight: CGFloat = showCustom ? 175 : 150
        preferredContentSize = NSSize(width: 450, height: newHeight)

        if animated, let window = view.window {
            let oldFrame = window.frame
            let titleBarHeight = oldFrame.height - window.contentLayoutRect.height
            let newFrame = NSRect(
                x: oldFrame.origin.x,
                y: oldFrame.maxY - newHeight - titleBarHeight,
                width: oldFrame.width,
                height: newHeight + titleBarHeight
            )
            window.animator().setFrame(newFrame, display: true)
        }
    }

    private func updatePreview() {
        let mode = UserAgentMode.current
        switch mode {
        case .detour:
            previewLabel.stringValue = "\(UserAgentMode.safariUserAgent) \(UserAgentMode.detourAppName)"
        case .safari:
            previewLabel.stringValue = UserAgentMode.safariUserAgent
        case .custom:
            let custom = UserDefaults.standard.string(forKey: "customUserAgent") ?? ""
            previewLabel.stringValue = custom.isEmpty ? "(empty)" : custom
        }
    }

    @objc private func userAgentModeChanged(_ sender: NSPopUpButton) {
        let mode = UserAgentMode(rawValue: sender.indexOfSelectedItem) ?? .detour
        UserDefaults.standard.set(mode.rawValue, forKey: "userAgentMode")
        updateCustomFieldVisibility(mode: mode)
        updatePreview()
        NotificationCenter.default.post(name: .init("UserAgentDidChange"), object: nil)
    }

    @objc private func customUserAgentChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(sender.stringValue, forKey: "customUserAgent")
        updatePreview()
        NotificationCenter.default.post(name: .init("UserAgentDidChange"), object: nil)
    }
}
