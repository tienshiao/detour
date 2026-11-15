import AppKit

/// Settings > General: the default browser, Peek and Automation, as a grouped
/// form (TASK-338). The Automation and Allowed Clients sections carry the
/// identifier the automation endpoint's input tools refuse (TASK-228.7).
class GeneralSettingsViewController: SettingsPaneViewController {
    private var defaultBrowserButton: NSButton!
    private var statusLabel: NSTextField!
    private var peekSwitch: NSSwitch!
    private var automationSwitch: NSSwitch!
    private var automationStatus: SettingsFormRow!
    private var automationSection: SettingsFormSection!
    private var tokenButtons: [NSButton] = []
    private var allowAgainRow: SettingsFormRow!
    private var privateSwitch: NSSwitch!
    private var clientsSection: SettingsFormSection!
    /// What the client rows show now, so a change rebuilds them only when
    /// something changed (the window resizes with them).
    private var shownClients: [AutomationClientRecord]?
    private var automationObserver: (any NSObjectProtocol)?

    override func makeBody() -> NSView {
        // Default Browser: which app opens links, and the button to make it Detour.
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: SettingsMetrics.formTitleFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        defaultBrowserButton = NSButton(title: "Set as Default Browser", target: self, action: #selector(setAsDefaultBrowser))
        defaultBrowserButton.bezelStyle = .rounded
        let browserRow = SettingsFormRow(title: "Default web browser",
                                         accessory: .value(statusLabel, button: defaultBrowserButton))

        // Peek (TASK-307): app-wide.
        peekSwitch = NSSwitch()
        peekSwitch.target = self
        peekSwitch.action = #selector(peekSwitchChanged)
        peekSwitch.setAccessibilityIdentifier("peekEnabled")
        let peekRow = SettingsFormRow(
            title: "Open links from pinned tabs and favorites in a Peek",
            help: "Off, links to other sites from pinned tabs and favorites open in new tabs. Shift-click still opens a Peek.",
            accessory: .toggle(peekSwitch))
        // TASK-292.11: the Peek guide, under the help that explains it.
        peekRow.addLink(SettingsGuideLink(.peek))

        // Automation (TASK-228.1): the MCP endpoint, off by default.
        automationSwitch = NSSwitch()
        automationSwitch.target = self
        automationSwitch.action = #selector(automationSwitchChanged)
        automationSwitch.setAccessibilityIdentifier("automationEnabled")
        let automationRow = SettingsFormRow(
            title: "Let AI agents and scripts control Detour (MCP)",
            help: "While this is on, an MCP client you allow, such as Claude Code, can read your pages and act "
                + "in them as you, signed in to your sites. The first time a client connects, Detour asks you to "
                + "allow it. Each window shows which agent is connected; disconnecting it revokes its access. Set "
                + "clients up with the commands below: they run Detour's helper, which finds Detour and keeps the "
                + "client's access itself.",
            accessory: .toggle(automationSwitch))
        privateSwitch = NSSwitch()
        privateSwitch.target = self
        privateSwitch.action = #selector(privateSwitchChanged)
        privateSwitch.setAccessibilityIdentifier("automationAllowPrivate")
        let privateRow = SettingsFormRow(
            title: "Allow agents to use Private windows",
            help: "Off, agents cannot see or use Private windows, their tabs or menus, or the Private "
                + "profile's extensions. Turning it off takes effect at once.",
            accessory: .toggle(privateSwitch))
        let allowAgainButton = NSButton(title: "Allow Again", target: self, action: #selector(allowDisconnectedAgents))
        allowAgainButton.bezelStyle = .rounded
        allowAgainRow = SettingsFormRow(
            title: "Disconnected agents",
            help: "Agents you disconnected cannot connect until you allow them again.",
            accessory: .button(allowAgainButton))
        automationStatus = SettingsFormRow(footnote: " ")
        automationStatus.helpLabel.isSelectable = true

        let copyCommand = NSButton(title: "Copy Claude Code Command", target: self, action: #selector(copyClaudeCommand))
        copyCommand.toolTip = "claude mcp add with Detour's helper, which finds the address and token itself"
        let copyConfig = NSButton(title: "Copy MCP Config", target: self, action: #selector(copyMCPConfig))
        copyConfig.toolTip = "The mcpServers entry for Claude Desktop, Cursor and other MCP clients"
        let copyToken = NSButton(title: "Copy Token", target: self, action: #selector(copyToken))
        copyToken.toolTip = "For a client that connects to the address itself (advanced): the address changes each "
            + "time Detour starts, so the helper commands are the lasting setup"
        let resetToken = NSButton(title: "Reset Token…", target: self, action: #selector(resetToken))
        for button in [copyCommand, copyConfig, copyToken, resetToken] { button.bezelStyle = .rounded }
        // A test run's shared token only (TASK-228.5): the user's endpoint
        // has none, each client getting its own through the helper.
        tokenButtons = [copyToken, resetToken]
        automationSection = SettingsFormSection(
            title: "Automation", rows: [automationRow, privateRow, allowAgainRow], footnote: automationStatus,
            buttons: [copyCommand, copyConfig, copyToken, resetToken])
        // The automation endpoint's input tools refuse views in here (TASK-228.7).
        automationSection.identifier = AutomationWindows.automationSettingsIdentifier

        // The allowed clients: a row each, rebuilt when they change.
        clientsSection = SettingsFormSection(title: "Allowed Clients", rows: [])
        clientsSection.identifier = AutomationWindows.automationSettingsIdentifier

        let form = SettingsForm(sections: [
            SettingsFormSection(title: "Default Browser", rows: [browserRow]),
            SettingsFormSection(title: "Peek", rows: [peekRow]),
            automationSection,
            clientsSection,
        ])
        return formBody(form)
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
        let status: String
        switch controller.status {
        case .off:
            status = "Off."
        case .starting:
            status = "Starting…"
        case .listening(let port):
            let count = controller.sessions.count
            let agents = count == 0 ? "no agent connected" : count == 1 ? "1 agent connected" : "\(count) agents connected"
            // The address only for a test run, whose clients may connect to
            // it with the shared token; the user's clients use the helper.
            status = controller.usesClientApproval
                ? "On, \(agents)."
                : "On at \(AutomationCredentials.endpointURL(port: port)) (until Detour quits), \(agents)."
        case .failed(let reason):
            status = "Could not start: \(reason)"
        }
        automationStatus.setHelp(status)
        privateSwitch.state = controller.allowsPrivateInSettings ? .on : .off
        let buttonsHidden = !controller.status.isOn
        let allowHidden = controller.blockedClientNames.isEmpty
        let tokenButtonsHidden = controller.usesClientApproval
        let clientsHidden = !controller.usesClientApproval
        // The button row and the client rows refit the pane themselves.
        let changed = allowAgainRow.isHidden != allowHidden || clientsSection.isHidden != clientsHidden
        automationSection.isButtonRowHidden = buttonsHidden
        allowAgainRow.isHidden = allowHidden
        for button in tokenButtons { button.isHidden = tokenButtonsHidden }
        clientsSection.isHidden = clientsHidden
        let clients = clientsHidden ? [] : controller.approvedClients
        if clients != shownClients {
            shownClients = clients
            rebuildClientRows(clients)
        }
        // Rows came or went: the window fits the pane again.
        if changed { contentHeightDidChange() }
    }

    /// One row per allowed client: its name, when it was allowed and last
    /// used under it, and Revoke.
    private func rebuildClientRows(_ clients: [AutomationClientRecord]) {
        guard !clients.isEmpty else {
            clientsSection.setRows([SettingsFormRow(footnote: "None yet. A client asks the first time it connects.")])
            return
        }
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        let now = Date()
        clientsSection.setRows(clients.map { client in
            var detail = "Allowed \(dates.string(from: client.created))"
            if let used = client.lastUsed { detail += ", last used \(AutomationIndicator.age(of: used, now: now))" }
            if client.title != nil { detail = "\(client.name). " + detail }
            let revoke = NSButton(title: "Revoke", target: self, action: #selector(revokeClient(_:)))
            revoke.bezelStyle = .rounded
            revoke.identifier = NSUserInterfaceItemIdentifier(client.clientID.uuidString)
            revoke.setAccessibilityLabel("Revoke \(client.displayName)")
            revoke.toolTip = "\(client.displayName) loses access at once; it has to ask you again to reconnect."
            return SettingsFormRow(title: client.displayName, help: detail, accessory: .button(revoke))
        })
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

    /// The row's value: the app that opens web links now; the button is off
    /// while it is Detour (hidden, the row would keep a button row's height).
    private func updateStatus() {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        let isDetour = handler?.path == Bundle.main.bundleURL.path
        statusLabel.stringValue = isDetour ? "Detour" : handler.map { FileManager.default.displayName(atPath: $0.path) }
            .map { ($0 as NSString).deletingPathExtension } ?? ""
        defaultBrowserButton.isEnabled = !isDetour
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
