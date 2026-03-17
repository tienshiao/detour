import AppKit

class ContentBlockerPopoverViewController: NSViewController {
    var host: String = ""
    var isBlockingEnabled: Bool = true
    var blockedCount: Int = 0
    var onToggle: (() -> Void)?

    private let toggleSwitch = NSSwitch()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        self.view = container

        let margin: CGFloat = 16
        let spacing: CGFloat = 8

        let titleLabel = NSTextField(labelWithString: "Content Blocking")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let hostLabel = NSTextField(labelWithString: host.isEmpty ? "No site loaded" : host)
        hostLabel.font = .systemFont(ofSize: 11)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostLabel)

        let blockedLabel = NSTextField(labelWithString: blockedCount > 0 ? "\(blockedCount) resource\(blockedCount == 1 ? "" : "s") blocked on this page" : "No resources blocked yet")
        blockedLabel.font = .systemFont(ofSize: 11)
        blockedLabel.textColor = .tertiaryLabelColor
        blockedLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blockedLabel)

        let toggleLabel = NSTextField(labelWithString: "Block content on this site")
        toggleLabel.font = .systemFont(ofSize: 13)
        toggleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggleLabel)

        toggleSwitch.state = isBlockingEnabled ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(toggleClicked)
        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggleSwitch)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            hostLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            hostLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            blockedLabel.topAnchor.constraint(equalTo: hostLabel.bottomAnchor, constant: spacing),
            blockedLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            toggleLabel.topAnchor.constraint(equalTo: blockedLabel.bottomAnchor, constant: spacing),
            toggleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            toggleSwitch.centerYAnchor.constraint(equalTo: toggleLabel.centerYAnchor),
            toggleSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            container.bottomAnchor.constraint(equalTo: toggleLabel.bottomAnchor, constant: margin),
        ])
    }

    @objc private func toggleClicked() {
        onToggle?()
    }
}
