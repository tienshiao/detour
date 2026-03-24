import AppKit

class GeneralSettingsViewController: NSViewController {
    private var defaultBrowserButton: NSButton!
    private var statusLabel: NSTextField!

    override func loadView() {
        preferredContentSize = NSSize(width: 740, height: 120)
        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        view = container

        let sectionLabel = NSTextField(labelWithString: "Default Browser")
        sectionLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor

        defaultBrowserButton = NSButton(title: "Set as Default Browser", target: self, action: #selector(setAsDefaultBrowser))
        defaultBrowserButton.bezelStyle = .rounded

        let margin: CGFloat = 20
        let spacing: CGFloat = 12

        let row = NSStackView(views: [defaultBrowserButton, statusLabel])
        row.orientation = .horizontal
        row.spacing = spacing

        let stack = NSStackView(views: [sectionLabel, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -margin),
        ])
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
