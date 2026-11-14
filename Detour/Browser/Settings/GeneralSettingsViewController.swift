import AppKit

class GeneralSettingsViewController: SettingsPaneViewController {
    private var defaultBrowserButton: NSButton!
    private var statusLabel: NSTextField!
    private var peekCheckbox: NSButton!
    private var automationCheckbox: NSButton!
    private var automationStatus: NSTextField!
    private var automationButtons: NSStackView!
    private var allowAgainButton: NSButton!
    private var automationObserver: (any NSObjectProtocol)?
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

        // Automation (TASK-228.1): the MCP endpoint, off by default.
        let automationTitle = NSTextField.settingsSectionTitle("Automation")
        automationCheckbox = NSButton(checkboxWithTitle: "Let AI agents and scripts control Detour (MCP)",
                                      target: self, action: #selector(automationCheckboxChanged))
        automationCheckbox.setAccessibilityIdentifier("automationEnabled")
        let automationHelp = SettingsWrappingLabel(
            wrapping: "While this is on, an MCP client given this Mac's token, such as Claude Code, can read your "
                + "pages and act in them as you, signed in to your sites. Private windows are never reachable. "
                + "Each window shows which agent is connected, with a way to disconnect it.",
            estimatedWidth: Self.textWidth)
        automationStatus = NSTextField(labelWithString: "")
        automationStatus.font = .systemFont(ofSize: 12)
        automationStatus.textColor = .secondaryLabelColor
        automationStatus.isSelectable = true
        automationStatus.lineBreakMode = .byTruncatingMiddle
        let copyCommand = NSButton(title: "Copy Claude Code Command", target: self, action: #selector(copyClaudeCommand))
        copyCommand.toolTip = "claude mcp add with Detour's helper, which finds the address and token itself"
        let copyConfig = NSButton(title: "Copy MCP Config", target: self, action: #selector(copyMCPConfig))
        copyConfig.toolTip = "The mcpServers entry for Claude Desktop, Cursor and other MCP clients"
        let copyToken = NSButton(title: "Copy Token", target: self, action: #selector(copyToken))
        let resetToken = NSButton(title: "Reset Token…", target: self, action: #selector(resetToken))
        allowAgainButton = NSButton(title: "Allow Disconnected Agents Again", target: self,
                                    action: #selector(allowDisconnectedAgents))
        for button in [copyCommand, copyConfig, copyToken, resetToken, allowAgainButton!] { button.bezelStyle = .rounded }
        automationButtons = NSStackView(views: [copyCommand, copyConfig, copyToken, resetToken])
        automationButtons.orientation = .horizontal
        automationButtons.spacing = SettingsMetrics.labelToControl
        let automationRows = NSStackView(views: [automationCheckbox, automationHelp, automationStatus,
                                                 automationButtons, allowAgainButton])
        automationRows.orientation = .vertical
        automationRows.alignment = .leading
        automationRows.spacing = SettingsMetrics.controlToHelp
        let automationSection = NSStackView(views: [automationTitle, automationRows])
        automationSection.orientation = .vertical
        automationSection.alignment = .leading
        automationSection.spacing = SettingsMetrics.sectionTitleToRows

        let stack = NSStackView(views: [browserSection, peekSection, automationSection])
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
            automationHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            automationStatus.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),
            bottomHug(stack.bottomAnchor, body.bottomAnchor),
        ])
        return body
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateStatus()
        peekCheckbox.state = PeekSettings.shared.isEnabled ? .on : .off
        updateAutomation()
        if automationObserver == nil {
            automationObserver = NotificationCenter.default.addMainObserver(
                forName: AutomationController.didChangeNotification, object: nil
            ) { [weak self] _ in
                self?.updateAutomation()
            }
        }
    }

    // MARK: Automation (TASK-228.1)

    private func updateAutomation() {
        let controller = AutomationController.shared
        // The saved setting too: after a failed start the box stays checked
        // (the endpoint will try again at launch) until the user unchecks it.
        automationCheckbox.state = controller.status.isOn || controller.isEnabledInSettings ? .on : .off
        switch controller.status {
        case .off:
            automationStatus.stringValue = "Off."
        case .starting:
            automationStatus.stringValue = "Starting…"
        case .listening(let port):
            let count = controller.sessions.count
            let agents = count == 0 ? "no agent connected" : count == 1 ? "1 agent connected" : "\(count) agents connected"
            automationStatus.stringValue = "On at \(AutomationCredentials.endpointURL(port: port)), \(agents)."
        case .failed(let reason):
            automationStatus.stringValue = "Could not start: \(reason)"
        }
        let buttonsHidden = !controller.status.isOn
        let allowHidden = controller.blockedClientNames.isEmpty
        if automationButtons.isHidden != buttonsHidden || allowAgainButton.isHidden != allowHidden {
            automationButtons.isHidden = buttonsHidden
            allowAgainButton.isHidden = allowHidden
            // Rows came or went: the window fits the pane again.
            contentHeightDidChange()
        }
    }

    @objc private func automationCheckboxChanged() {
        AutomationController.shared.setEnabled(automationCheckbox.state == .on)
    }

    /// The bundled stdio helper (TASK-228.1): clients run it, and it finds
    /// the endpoint and token itself.
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/detour-mcp").path
    }

    /// The helper's environment: the data directory, when it is not the
    /// default one (a test run), so the helper finds that run's endpoint.
    static func helperEnvironment(dataDirectory: String = detourDataDirectoryName()) -> [String: String] {
        dataDirectory == defaultDetourDataDirectoryName ? [:] : ["DETOUR_DATA_DIR": dataDirectory]
    }

    /// `claude mcp add` running the helper.
    static func claudeCodeCommand(helperPath: String, environment: [String: String]) -> String {
        let env = environment.keys.sorted().map { " -e \(shellQuoted("\($0)=\(environment[$0]!)"))" }.joined()
        return "claude mcp add detour\(env) -- \(shellQuoted(helperPath))"
    }

    /// `value` as one shell word: single-quoted, so spaces, `$` and quotes
    /// in a path or a data directory name stay literal.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `mcpServers` entry most MCP clients' config files take.
    static func mcpConfig(helperPath: String, environment: [String: String]) -> String {
        var server: [String: JSONValue] = ["command": .string(helperPath)]
        if !environment.isEmpty { server["env"] = .object(environment.mapValues(JSONValue.string)) }
        let config: JSONValue = ["mcpServers": ["detour": .object(server)]]
        return config.jsonString
    }

    @objc private func copyClaudeCommand() {
        copy(Self.claudeCodeCommand(helperPath: Self.helperPath, environment: Self.helperEnvironment()))
    }

    @objc private func copyMCPConfig() {
        copy(Self.mcpConfig(helperPath: Self.helperPath, environment: Self.helperEnvironment()))
    }

    @objc private func copyToken() {
        guard let token = try? AutomationController.shared.token() else { return }
        copy(token, concealed: true)
    }

    /// A concealed copy (the token) stays on this Mac (no Universal
    /// Clipboard) and carries the marker clipboard managers skip.
    private func copy(_ string: String, concealed: Bool = false) {
        let pasteboard = NSPasteboard.general
        if concealed {
            pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
            pasteboard.clearContents()
        }
        pasteboard.setString(string, forType: .string)
        if concealed { pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
    }

    @objc private func resetToken() {
        let alert = NSAlert()
        alert.messageText = "Reset the automation token?"
        alert.informativeText = "Every connected agent is disconnected. An agent set up with the token itself has "
            + "to be set up again with the new one; one set up with Detour's helper (Copy Claude Code Command, Copy "
            + "MCP Config) reads the new token and reconnects on its own."
        alert.addButton(withTitle: "Reset Token")
        alert.addButton(withTitle: "Cancel")
        let reset = { try? AutomationController.shared.resetToken() }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { _ = reset() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            _ = reset()
        }
    }

    @objc private func allowDisconnectedAgents() {
        let controller = AutomationController.shared
        for name in controller.blockedClientNames { controller.allow(clientName: name) }
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
