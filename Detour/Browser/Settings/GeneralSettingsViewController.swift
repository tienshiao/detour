import AppKit

class GeneralSettingsViewController: SettingsPaneViewController {
    private var defaultBrowserButton: NSButton!
    private var statusLabel: NSTextField!

    override func makeBody() -> NSView {
        let body = NSView()

        let sectionLabel = NSTextField(labelWithString: "Default Browser")
        sectionLabel.font = .systemFont(ofSize: 13, weight: .semibold)

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

        let stack = NSStackView(views: [sectionLabel, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsMetrics.rowGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)

        // The body ends at the button, so the pane's natural height ends one
        // margin below it (defect 14).
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: body.topAnchor),
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),
            bottomHug(stack.bottomAnchor, body.bottomAnchor),
        ])
        return body
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateStatus()
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
