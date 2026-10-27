import AppKit

/// Settings > Quick Detour (TASK-211; the controls are TASK-193.2's and
/// TASK-193.5's, moved here from the Links pane): the system-wide shortcut
/// with its warning line and help, Opt-Cmd-click, the idle auto-close, and a
/// caption pointing links from other apps to the Links pane. No master list,
/// so the pane scrolls as one body, like General.
final class QuickDetourSettingsViewController: SettingsPaneViewController {
    private var hotKey: QuickDetourHotKey { .shared }
    private var quickDetourSettings: QuickDetourSettings { .shared }

    private var hotKeyCheckbox: NSButton!
    private var hotKeyRecorder: ShortcutRecorderView!
    private var hotKeyWarningIcon: NSImageView!
    private var hotKeyWarningLabel: SettingsWrappingLabel!
    /// The help text sits under the row, or under the warning when one shows.
    private var hotKeyHelpBelowRow: NSLayoutConstraint!
    private var hotKeyHelpBelowWarning: NSLayoutConstraint!
    /// Why the recorder refused the last shortcut typed, while it records.
    private var hotKeyRefusal: String?
    private var observers: [NSObjectProtocol] = []
    private var optionCommandCheckbox: NSButton!
    private var idleTimeoutPopUp: NSPopUpButton!

    /// The width of a full-width line of text in the body.
    private static let textWidth = SettingsMetrics.windowWidth - 2 * SettingsMetrics.paneMargin

    // MARK: - Building

    /// "[✓] Open Quick Detour from any app with [⌥⌘N]", a warning line when
    /// the shortcut is refused or not registered, and the help text; then a
    /// switch for Opt-Cmd-click, the idle auto-close pop-up with its help, and
    /// a caption saying links from other apps are routed on the Links pane
    /// (no switch of their own).
    override func makeBody() -> NSView {
        let container = NSView()
        let name = QuickDetour.displayName

        hotKeyCheckbox = NSButton(checkboxWithTitle: "Open \(name) from any app with",
                                  target: self, action: #selector(hotKeyCheckboxChanged))
        hotKeyCheckbox.translatesAutoresizingMaskIntoConstraints = false
        hotKeyCheckbox.setAccessibilityIdentifier("quickDetourHotKeyEnabled")
        container.addSubview(hotKeyCheckbox)

        hotKeyRecorder = ShortcutRecorderView()
        hotKeyRecorder.setAccessibilityIdentifier("quickDetourHotKeyShortcut")
        hotKeyRecorder.setAccessibilityLabel("\(name) shortcut")
        hotKeyRecorder.problem = { shortcut in
            HotKeyShortcutValidation.problem(for: shortcut, menu: NSApp.mainMenu,
                                             ownAction: #selector(AppDelegate.newQuickDetourWindow(_:)),
                                             systemHotKeys: HotKeyShortcutValidation.currentSystemHotKeys())
        }
        hotKeyRecorder.onChange = { [weak self] shortcut in
            self?.hotKey.settings.shortcut = shortcut
        }
        hotKeyRecorder.onRecordingChange = { [weak self] recording in
            self?.hotKey.setRecording(recording)
        }
        hotKeyRecorder.onRefuse = { [weak self] message in
            self?.hotKeyRefusal = message
            self?.updateControls()
        }
        container.addSubview(hotKeyRecorder)

        hotKeyWarningIcon = LinkRouteCellView.makeWarning().icon
        hotKeyWarningLabel = SettingsWrappingLabel(
            wrapping: "", estimatedWidth: Self.textWidth - LinkRouteCellView.warningIconWidth - LinkRouteCellView.warningIconGap)
        hotKeyWarningLabel.isHidden = true
        container.addSubview(hotKeyWarningIcon)
        container.addSubview(hotKeyWarningLabel)

        let help = SettingsWrappingLabel(
            wrapping: "The launcher opens over the app in front; Escape or a click elsewhere closes it. The same shortcut is File > New \(name) Window while Detour is in front, also when this is off.",
            estimatedWidth: Self.textWidth)
        container.addSubview(help)

        // Opt-Cmd-click on a link or a sidebar tab.
        optionCommandCheckbox = NSButton(checkboxWithTitle: "Open links and sidebar tabs in \(name) with ⌥⌘-click",
                                         target: self, action: #selector(optionCommandCheckboxChanged))
        optionCommandCheckbox.translatesAutoresizingMaskIntoConstraints = false
        optionCommandCheckbox.setAccessibilityIdentifier("quickDetourOptionCommandClick")
        container.addSubview(optionCommandCheckbox)
        let optionCommandHelp = SettingsWrappingLabel(
            wrapping: "A sidebar tab opens as a copy; the tab stays where it is.", estimatedWidth: Self.textWidth)
        container.addSubview(optionCommandHelp)

        // The idle auto-close.
        let idleLabel = NSTextField(labelWithString: "Close \(name) windows not used for")
        idleLabel.font = .systemFont(ofSize: 13)
        idleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(idleLabel)
        idleTimeoutPopUp = NSPopUpButton()
        idleTimeoutPopUp.translatesAutoresizingMaskIntoConstraints = false
        idleTimeoutPopUp.setAccessibilityIdentifier("quickDetourIdleTimeout")
        idleTimeoutPopUp.setAccessibilityLabel("Close \(name) windows not used for")
        for timeout in QuickDetourIdleTimeout.allCases {
            idleTimeoutPopUp.addItem(withTitle: timeout.title)
            idleTimeoutPopUp.lastItem?.representedObject = timeout.rawValue
        }
        idleTimeoutPopUp.target = self
        idleTimeoutPopUp.action = #selector(idleTimeoutChanged)
        container.addSubview(idleTimeoutPopUp)
        let idleHelp = SettingsWrappingLabel(
            wrapping: "They go to the archive, marked auto-closed, and reopen from there. The window in front, one playing sound and Private ones stay open.",
            estimatedWidth: Self.textWidth)
        container.addSubview(idleHelp)

        // Links from other apps: routed, so no switch here.
        let linksCaption = SettingsWrappingLabel(
            wrapping: "To open links from other apps in \(name), choose \(name) as a route's Open in, or as the Default, on the Links pane.",
            estimatedWidth: Self.textWidth)
        container.addSubview(linksCaption)

        hotKeyHelpBelowRow = help.topAnchor.constraint(equalTo: hotKeyRecorder.bottomAnchor,
                                                       constant: SettingsMetrics.controlToHelp)
        hotKeyHelpBelowWarning = help.topAnchor.constraint(equalTo: hotKeyWarningLabel.bottomAnchor,
                                                           constant: SettingsMetrics.controlToHelp)
        NSLayoutConstraint.activate([
            hotKeyRecorder.topAnchor.constraint(equalTo: container.topAnchor),
            hotKeyCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hotKeyCheckbox.centerYAnchor.constraint(equalTo: hotKeyRecorder.centerYAnchor),
            hotKeyRecorder.leadingAnchor.constraint(equalTo: hotKeyCheckbox.trailingAnchor,
                                                    constant: SettingsMetrics.labelToControl),
            hotKeyRecorder.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            hotKeyWarningIcon.leadingAnchor.constraint(equalTo: hotKeyCheckbox.leadingAnchor),
            hotKeyWarningIcon.centerYAnchor.constraint(equalTo: hotKeyWarningLabel.topAnchor,
                                                       constant: LinkRouteCellView.warningFirstLineCenter),
            hotKeyWarningLabel.topAnchor.constraint(equalTo: hotKeyRecorder.bottomAnchor,
                                                    constant: LinkRouteCellView.lineGap),
            hotKeyWarningLabel.leadingAnchor.constraint(equalTo: hotKeyWarningIcon.trailingAnchor,
                                                        constant: LinkRouteCellView.warningIconGap),
            hotKeyWarningLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            hotKeyHelpBelowRow,
            help.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            optionCommandCheckbox.topAnchor.constraint(equalTo: help.bottomAnchor, constant: SettingsMetrics.rowGap),
            optionCommandCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            optionCommandCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            optionCommandHelp.topAnchor.constraint(equalTo: optionCommandCheckbox.bottomAnchor,
                                                   constant: SettingsMetrics.controlToHelp),
            optionCommandHelp.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            optionCommandHelp.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            idleTimeoutPopUp.topAnchor.constraint(equalTo: optionCommandHelp.bottomAnchor, constant: SettingsMetrics.rowGap),
            idleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            idleLabel.firstBaselineAnchor.constraint(equalTo: idleTimeoutPopUp.firstBaselineAnchor),
            idleTimeoutPopUp.leadingAnchor.constraint(equalTo: idleLabel.trailingAnchor,
                                                      constant: SettingsMetrics.labelToControl),
            idleTimeoutPopUp.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            idleHelp.topAnchor.constraint(equalTo: idleTimeoutPopUp.bottomAnchor, constant: SettingsMetrics.controlToHelp),
            idleHelp.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            idleHelp.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            linksCaption.topAnchor.constraint(equalTo: idleHelp.bottomAnchor, constant: SettingsMetrics.rowGap),
            linksCaption.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            linksCaption.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // `<=` plus a weak `==`: a required equality would cap the window.
            linksCaption.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            bottomHug(linksCaption.bottomAnchor, container.bottomAnchor),
        ])
        return container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for name in [QuickDetourHotKeySettings.didChangeNotification, QuickDetourHotKey.stateDidChangeNotification,
                     QuickDetourSettings.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateControls() }
            })
        }
        updateControls()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Another app may have let go of a refused shortcut since.
        hotKey.retryIfFailed()
        updateControls()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // The hotkey is suspended while the recorder records.
        hotKeyRecorder.endRecording()
    }

    // MARK: - Actions

    @objc private func hotKeyCheckboxChanged() {
        hotKey.settings.isEnabled = hotKeyCheckbox.state == .on
    }

    @objc private func optionCommandCheckboxChanged() {
        quickDetourSettings.isOptionCommandClickEnabled = optionCommandCheckbox.state == .on
    }

    @objc private func idleTimeoutChanged() {
        guard let raw = idleTimeoutPopUp.selectedItem?.representedObject as? String,
              let timeout = QuickDetourIdleTimeout(rawValue: raw) else { return }
        quickDetourSettings.idleTimeout = timeout
    }

    /// The controls from the settings; the warning line from the recorder's
    /// refusal, else the registration's state.
    private func updateControls() {
        optionCommandCheckbox.state = quickDetourSettings.isOptionCommandClickEnabled ? .on : .off
        if let index = QuickDetourIdleTimeout.allCases.firstIndex(of: quickDetourSettings.idleTimeout) {
            idleTimeoutPopUp.selectItem(at: index)
        }
        let settings = hotKey.settings
        hotKeyCheckbox.state = settings.isEnabled ? .on : .off
        if !hotKeyRecorder.isRecording {
            hotKeyRecorder.shortcut = settings.shortcut
            hotKeyRefusal = nil
        }

        var message = hotKeyRefusal ?? hotKey.availability.settingsMessage
        if message == nil, settings.isEnabled {
            if hotKey.state == .noShortcut {
                message = "No shortcut: click the field and type one."
            } else {
                message = QuickDetourHotKey.message(for: hotKey.state)
            }
        }
        let shown = hotKeyWarningLabel.isHidden ? nil : hotKeyWarningLabel.stringValue
        LinkRouteCellView.setWarning(message, icon: hotKeyWarningIcon, label: hotKeyWarningLabel)
        // Off first, so the two are never on together.
        if message == nil {
            hotKeyHelpBelowWarning.isActive = false
            hotKeyHelpBelowRow.isActive = true
        } else {
            hotKeyHelpBelowRow.isActive = false
            hotKeyHelpBelowWarning.isActive = true
        }
        if shown != message { contentHeightDidChange() }
    }
}
