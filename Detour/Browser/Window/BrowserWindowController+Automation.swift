import AppKit

/// The automation indicator (TASK-228.1, AC #10, #17): while an agent is
/// connected through the automation endpoint, every browser window shows a
/// capsule at the bottom right of its content naming the client, whether
/// the sidebar is shown or not. Clicking it lists the clients, each with
/// Disconnect, and offers Turn Off Automation.
extension BrowserWindowController {

    func setupAutomationIndicator() {
        let indicator = automationIndicator
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.isHidden = true
        // Above every page: content goes in below the drag handle.
        contentContainerView.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor, constant: -10),
            indicator.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor, constant: -10),
        ])
        indicator.menuProvider = { [weak self] in self?.automationMenu() ?? NSMenu() }
        automationObserver = NotificationCenter.default.addMainObserver(
            forName: AutomationController.didChangeNotification, object: nil
        ) { [weak self] _ in
            self?.updateAutomationIndicator()
        }
        updateAutomationIndicator()
    }

    func updateAutomationIndicator(sessions: [MCPSessionStore.Session] = AutomationController.shared.sessions) {
        let title = AutomationIndicator.title(for: sessions)
        automationIndicator.title = title ?? ""
        automationIndicator.isHidden = title == nil
    }

    private func automationMenu() -> NSMenu {
        let controller = AutomationController.shared
        let menu = NSMenu(title: "Automation")
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Agents connected to Detour", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let now = Date()
        for session in controller.sessions {
            let item = NSMenuItem(title: "Disconnect \(session.clientName)",
                                  action: #selector(disconnectAutomationClient(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            item.toolTip = "Connected \(AutomationIndicator.age(of: session.startedAt, now: now)), "
                + "last request \(AutomationIndicator.age(of: session.lastSeen, now: now))"
            menu.addItem(item)
        }
        for name in controller.blockedClientNames {
            let item = NSMenuItem(title: "Allow \(name) Again", action: #selector(allowAutomationClient(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let off = NSMenuItem(title: "Turn Off Automation", action: #selector(turnOffAutomation(_:)), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        let settings = NSMenuItem(title: "Automation Settings…", action: #selector(showAutomationSettings(_:)),
                                  keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc func disconnectAutomationClient(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AutomationController.shared.disconnect(sessionID: id)
    }

    @objc func allowAutomationClient(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        AutomationController.shared.allow(clientName: name)
    }

    @objc func turnOffAutomation(_ sender: Any?) {
        AutomationController.shared.setEnabled(false)
    }

    @objc func showAutomationSettings(_ sender: Any?) {
        SettingsWindowController.shared.showGeneralPane()
    }
}

/// The capsule itself: an orange pill with the antenna symbol and the
/// client's name; a click pops up the menu `menuProvider` builds.
final class AutomationIndicatorView: NSView {

    var menuProvider: (() -> NSMenu)?

    var title: String = "" {
        didSet {
            label.stringValue = title
            setAccessibilityLabel(title.isEmpty ? nil : "Automation: \(title) connected")
            toolTip = title.isEmpty ? nil : "\(title) is connected to Detour and can control it. Click to disconnect."
        }
    }

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.systemOrange.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        setAccessibilityRole(.button)
        setAccessibilityElement(true)

        icon.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.contentTintColor = .white
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) ?? NSImage())
        chevron.contentTintColor = .white
        for part in [icon, chevron] as [NSView] { part.setAccessibilityElement(false) }
        label.setAccessibilityElement(false)

        let stack = NSStackView(views: [icon, label, chevron])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The whole capsule is one button: its symbol and label take no hits.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates, as `frame` is.
        guard !isHidden else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
    }

    /// Opens the menu above the capsule with their right edges aligned: the
    /// capsule sits at the window's right edge, and a menu hanging off its
    /// left edge ran past the screen's.
    @discardableResult
    private func showMenu() -> Bool {
        guard let menu = menuProvider?() else { return false }
        let x = bounds.width - menu.size.width
        let y = isFlipped ? -4 : bounds.height + 4
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: self)
        return true
    }
}
