import AppKit

class GeneralSettingsViewController: SettingsPaneViewController {
    private var defaultBrowserButton: NSButton!
    private var statusLabel: NSTextField!
    private var peekSwitch: NSSwitch!
    private var automationSwitch: NSSwitch!
    private var automationStatus: NSTextField!
    private var automationButtons: NSStackView!
    private var tokenButtons: [NSButton] = []
    private var allowAgainButton: NSButton!
    private var privateSwitch: NSSwitch!
    private var privateHelp: NSTextField!
    private var clientsTitle: NSTextField!
    private var clientsList: NSStackView!
    /// What the client rows show now, so a change rebuilds them only when
    /// something changed (the window resizes with them).
    private var shownClients: [AutomationClientRecord]?
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
        peekSwitch = NSSwitch()
        peekSwitch.target = self
        peekSwitch.action = #selector(peekSwitchChanged)
        peekSwitch.setAccessibilityIdentifier("peekEnabled")
        let peekRow = SettingsSwitchRow.make(peekSwitch, title: "Open links from pinned tabs and favorites in a Peek")
        let peekHelp = SettingsWrappingLabel(
            wrapping: "Off, links to other sites from pinned tabs and favorites open in new tabs. Shift-click still opens a Peek.",
            estimatedWidth: Self.textWidth)
        // TASK-292.11: the Peek guide, under the help that explains it.
        let peekRows = NSStackView(views: [peekRow, peekHelp, SettingsGuideLink(.peek)])
        peekRows.orientation = .vertical
        peekRows.alignment = .leading
        peekRows.spacing = SettingsMetrics.controlToHelp
        let peekSection = NSStackView(views: [peekTitle, peekRows])
        peekSection.orientation = .vertical
        peekSection.alignment = .leading
        peekSection.spacing = SettingsMetrics.sectionTitleToRows

        // Automation (TASK-228.1): the MCP endpoint, off by default.
        let automationTitle = NSTextField.settingsSectionTitle("Automation")
        automationSwitch = NSSwitch()
        automationSwitch.target = self
        automationSwitch.action = #selector(automationSwitchChanged)
        automationSwitch.setAccessibilityIdentifier("automationEnabled")
        let automationRow = SettingsSwitchRow.make(automationSwitch,
                                                   title: "Let AI agents and scripts control Detour (MCP)")
        let automationHelp = SettingsWrappingLabel(
            wrapping: "While this is on, an MCP client you allow, such as Claude Code, can read your pages and act "
                + "in them as you, signed in to your sites. The first time a client connects, Detour asks you to "
                + "allow it. Each window shows which agent is connected; disconnecting it revokes its access. Set "
                + "clients up with the commands below: they run Detour's helper, which finds Detour and keeps the "
                + "client's access itself.",
            estimatedWidth: Self.textWidth)
        privateSwitch = NSSwitch()
        privateSwitch.target = self
        privateSwitch.action = #selector(privateSwitchChanged)
        privateSwitch.setAccessibilityIdentifier("automationAllowPrivate")
        let privateRow = SettingsSwitchRow.make(privateSwitch, title: "Allow agents to use Private windows")
        privateHelp = SettingsWrappingLabel(
            wrapping: "Off, agents cannot see or use Private windows, their tabs or menus, or the Private "
                + "profile's extensions. Turning it off takes effect at once.",
            estimatedWidth: Self.textWidth)
        clientsTitle = NSTextField(labelWithString: "Allowed clients")
        clientsTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        clientsList = NSStackView()
        clientsList.orientation = .vertical
        clientsList.alignment = .leading
        clientsList.spacing = 4
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
        copyToken.toolTip = "For a client that connects to the address itself (advanced): the address changes each "
            + "time Detour starts, so the helper commands are the lasting setup"
        let resetToken = NSButton(title: "Reset Token…", target: self, action: #selector(resetToken))
        allowAgainButton = NSButton(title: "Allow Disconnected Agents Again", target: self,
                                    action: #selector(allowDisconnectedAgents))
        for button in [copyCommand, copyConfig, copyToken, resetToken, allowAgainButton!] { button.bezelStyle = .rounded }
        // A test run's shared token only (TASK-228.5): the user's endpoint
        // has none, each client getting its own through the helper.
        tokenButtons = [copyToken, resetToken]
        automationButtons = NSStackView(views: [copyCommand, copyConfig, copyToken, resetToken])
        automationButtons.orientation = .horizontal
        automationButtons.spacing = SettingsMetrics.labelToControl
        let automationRows = NSStackView(views: [automationRow, automationHelp, privateRow, privateHelp,
                                                 automationStatus, automationButtons, allowAgainButton,
                                                 clientsTitle, clientsList])
        automationRows.orientation = .vertical
        automationRows.alignment = .leading
        automationRows.spacing = SettingsMetrics.controlToHelp
        // The Private switch and the client list are their own groups.
        for view in [automationHelp, privateHelp, automationStatus, automationButtons, allowAgainButton!] as [NSView] {
            automationRows.setCustomSpacing(SettingsMetrics.rowGap, after: view)
        }
        let automationSection = NSStackView(views: [automationTitle, automationRows])
        automationSection.orientation = .vertical
        automationSection.alignment = .leading
        automationSection.spacing = SettingsMetrics.sectionTitleToRows
        // The automation endpoint's input tools refuse views in here (TASK-228.7).
        automationSection.identifier = AutomationWindows.automationSettingsIdentifier

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
            privateHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            clientsList.widthAnchor.constraint(equalTo: stack.widthAnchor),
            automationStatus.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),
            bottomHug(stack.bottomAnchor, body.bottomAnchor),
        ])
        return body
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateStatus()
        peekSwitch.state = PeekSettings.shared.isEnabled ? .on : .off
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
        // The saved setting too: after a failed start the switch stays on
        // (the endpoint will try again at launch) until the user turns it off.
        automationSwitch.state = controller.status.isOn || controller.isEnabledInSettings ? .on : .off
        switch controller.status {
        case .off:
            automationStatus.stringValue = "Off."
        case .starting:
            automationStatus.stringValue = "Starting…"
        case .listening(let port):
            let count = controller.sessions.count
            let agents = count == 0 ? "no agent connected" : count == 1 ? "1 agent connected" : "\(count) agents connected"
            // The address only for a test run, whose clients may connect to
            // it with the shared token; the user's clients use the helper.
            automationStatus.stringValue = controller.usesClientApproval
                ? "On, \(agents)."
                : "On at \(AutomationCredentials.endpointURL(port: port)) (until Detour quits), \(agents)."
        case .failed(let reason):
            automationStatus.stringValue = "Could not start: \(reason)"
        }
        privateSwitch.state = controller.allowsPrivateInSettings ? .on : .off
        let buttonsHidden = !controller.status.isOn
        let allowHidden = controller.blockedClientNames.isEmpty
        let tokenButtonsHidden = controller.usesClientApproval
        let clientsHidden = !controller.usesClientApproval
        var changed = automationButtons.isHidden != buttonsHidden || allowAgainButton.isHidden != allowHidden
            || clientsTitle.isHidden != clientsHidden
        automationButtons.isHidden = buttonsHidden
        allowAgainButton.isHidden = allowHidden
        for button in tokenButtons { button.isHidden = tokenButtonsHidden }
        clientsTitle.isHidden = clientsHidden
        clientsList.isHidden = clientsHidden
        let clients = clientsHidden ? [] : controller.approvedClients
        if clients != shownClients {
            changed = changed || clients.count != (shownClients?.count ?? -1)
            shownClients = clients
            rebuildClientRows(clients)
        }
        // Rows came or went: the window fits the pane again.
        if changed { contentHeightDidChange() }
    }

    /// One row per allowed client: its name, when it was allowed and last
    /// used, and Revoke.
    private func rebuildClientRows(_ clients: [AutomationClientRecord]) {
        for row in clientsList.arrangedSubviews {
            clientsList.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        guard !clients.isEmpty else {
            let empty = NSTextField(labelWithString: "None yet. A client asks the first time it connects.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            clientsList.addArrangedSubview(empty)
            return
        }
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        let now = Date()
        for client in clients {
            let name = NSTextField(labelWithString: client.displayName)
            name.font = .systemFont(ofSize: 12)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var detail = "allowed \(dates.string(from: client.created))"
            if let used = client.lastUsed { detail += ", last used \(AutomationIndicator.age(of: used, now: now))" }
            if client.title != nil { detail = "\(client.name), " + detail }
            let info = NSTextField(labelWithString: detail)
            info.font = .systemFont(ofSize: 11)
            info.textColor = .secondaryLabelColor
            info.lineBreakMode = .byTruncatingTail
            info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let revoke = NSButton(title: "Revoke", target: self, action: #selector(revokeClient(_:)))
            revoke.bezelStyle = .rounded
            revoke.controlSize = .small
            revoke.identifier = NSUserInterfaceItemIdentifier(client.clientID.uuidString)
            revoke.setAccessibilityLabel("Revoke \(client.displayName)")
            revoke.toolTip = "\(client.displayName) loses access at once; it has to ask you again to reconnect."
            let row = NSStackView(views: [name, info, revoke])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = SettingsMetrics.labelToControl
            row.setHuggingPriority(.defaultLow, for: .horizontal)
            clientsList.addArrangedSubview(row)
        }
    }

    @objc private func revokeClient(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        AutomationController.shared.revoke(clientID: id)
    }

    @objc private func privateSwitchChanged() {
        AutomationController.shared.setAllowsPrivate(privateSwitch.state == .on)
    }

    @objc private func automationSwitchChanged() {
        AutomationController.shared.setEnabled(automationSwitch.state == .on)
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

    @objc private func peekSwitchChanged() {
        PeekSettings.shared.isEnabled = peekSwitch.state == .on
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
