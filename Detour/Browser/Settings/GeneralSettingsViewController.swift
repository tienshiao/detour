import AppKit

class GeneralSettingsViewController: SettingsPaneViewController {
    private var defaultBrowserButton: NSButton!
    private var statusLabel: NSTextField!
    private var peekCheckbox: NSButton!
    private static let textWidth = SettingsMetrics.windowWidth - 2 * SettingsMetrics.paneMargin

    override func makeBody() -> NSView {
        let body = NSView()

        let sectionLabel = NSTextField.settingsSectionTitle("Default Browser")

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        defaultBrowserButton = NSButton(title: "Set as Default Browser", target: self, action: #selector(setAsDefaultBrowser))
        defaultBrowserButton.bezelStyle = .rounded

        let row = NSStackView(views: [defaultBrowserButton, statusLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = SettingsMetrics.labelToControl

        let browserSection = NSStackView(views: [sectionLabel, row])
        browserSection.orientation = .vertical
        browserSection.alignment = .leading
        browserSection.spacing = SettingsMetrics.sectionTitleToRows

        // Peek (TASK-307): app-wide.
        let peekTitle = NSTextField.settingsSectionTitle("Peek")
        peekCheckbox = NSButton(checkboxWithTitle: "Open links from pinned tabs and favorites in a Peek",
                                target: self, action: #selector(peekCheckboxChanged))
        peekCheckbox.setAccessibilityIdentifier("peekEnabled")
        let peekHelp = SettingsWrappingLabel(
            wrapping: "Off, links to other sites from pinned tabs and favorites open in new tabs. Shift-click still opens a Peek.",
            estimatedWidth: Self.textWidth)
        let peekRows = NSStackView(views: [peekCheckbox, peekHelp])
        peekRows.orientation = .vertical
        peekRows.alignment = .leading
        peekRows.spacing = SettingsMetrics.controlToHelp
        let peekSection = NSStackView(views: [peekTitle, peekRows])
        peekSection.orientation = .vertical
        peekSection.alignment = .leading
        peekSection.spacing = SettingsMetrics.sectionTitleToRows

        let stack = NSStackView(views: [browserSection, peekSection])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsMetrics.sectionGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)

        // The body ends at the last row, so the pane's natural height ends one
        // margin below it (defect 14).
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: body.topAnchor),
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            // Full width, so the Peek help wraps at the pane's width.
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            peekHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),
            bottomHug(stack.bottomAnchor, body.bottomAnchor),
        ])
        return body
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateStatus()
        peekCheckbox.state = PeekSettings.shared.isEnabled ? .on : .off
    }

    @objc private func peekCheckboxChanged() {
        PeekSettings.shared.isEnabled = peekCheckbox.state == .on
    }

    private func updateStatus() {
        if isDefaultBrowser() {
            statusLabel.stringValue = "Detour is your default browser."
            defaultBrowserButton.isEnabled = false
        } else {
            statusLabel.stringValue = ""
            defaultBrowserButton.isEnabled = true
        }
    }

    private func isDefaultBrowser() -> Bool {
        guard let defaultHandler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        else { return false }
        return defaultHandler.path == Bundle.main.bundleURL.path
    }

    @objc private func setAsDefaultBrowser() {
        let bundleURL = Bundle.main.bundleURL
        let schemes = ["http", "https"]
        let group = DispatchGroup()

        for scheme in schemes {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpenURLsWithScheme: scheme) { _ in
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.updateStatus()
        }
    }
}
