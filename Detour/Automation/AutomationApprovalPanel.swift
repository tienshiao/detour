import AppKit

/// The Allow / Deny prompt of the user's automation endpoint (TASK-228.5):
/// '"<name>" wants to control Detour', in a panel of Detour's own.
///
/// - Non-modal, never an app-modal alert: a modal run from a main-queue
///   block froze the whole endpoint (wiki: automation-endpoint, Traps), and
///   an app-modal alert in an app that is not active goes unseen. The HTTP
///   request waits for the answer instead (`AutomationApprovals`).
/// - A non-activating floating panel on every Space, ordered front without
///   activating Detour, so it shows over the app in use without taking the
///   keyboard from it; the Dock icon bounces once.
/// - Allow is not the default button, and both buttons are enabled only
///   `armDelay` after the panel appears, so a click or a Return meant for
///   the app in front cannot approve a client.
/// - No automation tool reaches it: the input tools act only on browser
///   windows, so an approved agent cannot approve another.
final class AutomationApprovalPanelPrompter: AutomationApprovalPrompter {

    /// How long the buttons stay disabled after the panel appears.
    static let armDelay: TimeInterval = 1.0

    private var shown = 0

    func present(_ request: AutomationApprovalRequest,
                 answer: @escaping (AutomationApprovalAnswer) -> Void) -> AutomationApprovalPrompt {
        let prompt = AutomationApprovalPanel(request: request, answer: answer)
        prompt.show(cascade: shown)
        shown += 1
        prompt.onDismiss = { [weak self] in self?.shown = max(0, (self?.shown ?? 1) - 1) }
        return prompt
    }
}

final class AutomationApprovalPanel: NSObject, AutomationApprovalPrompt, NSWindowDelegate {

    static let panelIdentifier = NSUserInterfaceItemIdentifier("automationApproval")
    static let allowIdentifier = NSUserInterfaceItemIdentifier("automationApprovalAllow")
    static let denyIdentifier = NSUserInterfaceItemIdentifier("automationApprovalDeny")

    let panel: NSPanel
    let allowButton: NSButton
    let denyButton: NSButton
    var onDismiss: (() -> Void)?
    private var answer: ((AutomationApprovalAnswer) -> Void)?
    private var attentionRequest: Int?

    init(request: AutomationApprovalRequest, answer: @escaping (AutomationApprovalAnswer) -> Void) {
        self.answer = answer
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        allowButton = NSButton(title: "Allow", target: nil, action: nil)
        denyButton = NSButton(title: "Deny", target: nil, action: nil)
        super.init()

        panel.identifier = Self.panelIdentifier
        panel.title = "Detour Automation"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)

        let heading = NSTextField(wrappingLabelWithString: "“\(request.displayName)” wants to control Detour")
        heading.font = .boldSystemFont(ofSize: 13)
        heading.setAccessibilityIdentifier("automationApprovalHeading")

        let body = NSTextField(wrappingLabelWithString:
            "If you allow it, it can read your pages and act in them as you, signed in to your sites, and use "
            + "Detour's windows, tabs and menus, until you disconnect it. The name is the one the client gave "
            + "itself: allow it only if you just started or set up this client.")
        body.font = .systemFont(ofSize: 12)

        var detailParts: [String] = []
        if request.title != nil { detailParts.append("Client name: \(request.name)") }
        if let version = request.version { detailParts.append("Version \(version)") }
        let detail = NSTextField(labelWithString: detailParts.joined(separator: " · "))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.isHidden = detailParts.isEmpty

        for button in [allowButton, denyButton] {
            button.bezelStyle = .rounded
            button.target = self
            button.isEnabled = false
        }
        allowButton.action = #selector(allow)
        denyButton.action = #selector(deny)
        allowButton.setAccessibilityIdentifier(Self.allowIdentifier.rawValue)
        denyButton.setAccessibilityIdentifier(Self.denyIdentifier.rawValue)
        // Escape denies; nothing approves from the keyboard alone.
        denyButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [denyButton, allowButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let text = NSStackView(views: [heading, body, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6

        let content = NSView()
        for view in [icon, text, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            heading.widthAnchor.constraint(equalTo: text.widthAnchor),
            body.widthAnchor.constraint(equalTo: text.widthAnchor),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor, constant: 16),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 420),
        ])
        panel.contentView = content
        panel.setAccessibilityLabel("“\(request.displayName)” wants to control Detour")
    }

    /// Shows the panel over every app without activating Detour, offset by
    /// `cascade` steps from the screen's centre when other prompts are up.
    func show(cascade: Int) {
        panel.layoutIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 420, height: 180))
        panel.center()
        if cascade > 0 {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + CGFloat(24 * cascade),
                                         y: panel.frame.minY - CGFloat(24 * cascade)))
        }
        panel.orderFrontRegardless()
        attentionRequest = NSApp.requestUserAttention(.informationalRequest)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AutomationApprovalPanelPrompter.armDelay))
            guard let self, self.answer != nil else { return }
            self.allowButton.isEnabled = true
            self.denyButton.isEnabled = true
        }
    }

    @objc private func allow() { respond(.allow) }
    @objc private func deny() { respond(.deny) }

    private func respond(_ value: AutomationApprovalAnswer) {
        guard let answer else { return }
        self.answer = nil
        dismiss()
        answer(value)
    }

    func dismiss() {
        answer = nil
        if let attentionRequest {
            NSApp.cancelUserAttentionRequest(attentionRequest)
            self.attentionRequest = nil
        }
        guard panel.isVisible || onDismiss != nil else { return }
        panel.orderOut(nil)
        panel.close()
        onDismiss?()
        onDismiss = nil
    }
}
