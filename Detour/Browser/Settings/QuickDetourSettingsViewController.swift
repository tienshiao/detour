import AppKit

/// Settings > Quick Detour (TASK-211; the controls are TASK-193.2's and
/// TASK-193.5's, moved here from the Links pane): the system-wide shortcut
/// with its warning line and help, Opt-Cmd-click, the idle auto-close, and a
/// footnote pointing links from other apps to the Links pane. A grouped form
/// (TASK-338) that scrolls as one body, like General.
final class QuickDetourSettingsViewController: SettingsPaneViewController {
    private var hotKey: QuickDetourHotKey { .shared }
    private var quickDetourSettings: QuickDetourSettings { .shared }

    private var hotKeySwitch: NSSwitch!
    private var hotKeyRecorder: ShortcutRecorderView!
    /// The Shortcut row, whose warning line says why the shortcut is refused
    /// or not registered.
    private(set) var shortcutRow: SettingsFormRow!
    /// Why the recorder refused the last shortcut typed, while it records.
    private var hotKeyRefusal: String?
    private var observers: [NSObjectProtocol] = []
    private var optionCommandSwitch: NSSwitch!
    private var idleTimeoutPopUp: NSPopUpButton!

    override var guidePage: GuidePage? { .quickDetour }

    // MARK: - Building

    /// Opening: "Open Quick Detour from any app [switch]", "Shortcut [⌥⌘N]"
    /// (a row of its own: it is also File > New Quick Detour Window's
    /// shortcut while the switch is off) with a warning line when the
    /// shortcut is refused or not registered, the Opt-Cmd-click switch, and
    /// a footnote saying links from other apps are routed on the Links pane
    /// (no switch of their own). Closing: the idle auto-close pop-up.
    override func makeBody() -> NSView {
        let name = QuickDetour.displayName

        hotKeySwitch = NSSwitch()
        hotKeySwitch.target = self
        hotKeySwitch.action = #selector(hotKeySwitchChanged)
        hotKeySwitch.setAccessibilityIdentifier("quickDetourHotKeyEnabled")
        let hotKeyRow = SettingsFormRow(
            title: "Open \(name) from any app",
            help: "The launcher opens over the app in front; Escape or a click elsewhere closes it.",
            accessory: .toggle(hotKeySwitch))

        hotKeyRecorder = ShortcutRecorderView()
        hotKeyRecorder.setAccessibilityIdentifier("quickDetourHotKeyShortcut")
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
        shortcutRow = SettingsFormRow(
            title: "Shortcut",
            help: "The same shortcut is File > New \(name) Window while Detour is in front, also when the switch above is off.",
            accessory: .shortcut(hotKeyRecorder), accessibilityName: "\(name) shortcut")

        // Opt-Cmd-click on a link or a sidebar tab.
        optionCommandSwitch = NSSwitch()
        optionCommandSwitch.target = self
        optionCommandSwitch.action = #selector(optionCommandSwitchChanged)
        optionCommandSwitch.setAccessibilityIdentifier("quickDetourOptionCommandClick")
        let optionCommandRow = SettingsFormRow(
            title: "Open links and sidebar tabs in \(name) with ⌥⌘-click",
            help: "A sidebar tab opens as a copy; the tab stays where it is.",
            accessory: .toggle(optionCommandSwitch))

        // Links from other apps: routed, so no switch here.
        let linksFootnote = SettingsFormRow(
            footnote: "To open links from other apps in \(name), choose \(name) as a route's Open in, or as the Default, on the Links pane.")

        // The idle auto-close.
        idleTimeoutPopUp = NSPopUpButton()
        idleTimeoutPopUp.setAccessibilityIdentifier("quickDetourIdleTimeout")
        for timeout in QuickDetourIdleTimeout.allCases {
            idleTimeoutPopUp.addItem(withTitle: timeout.title)
            idleTimeoutPopUp.lastItem?.representedObject = timeout.rawValue
        }
        idleTimeoutPopUp.target = self
        idleTimeoutPopUp.action = #selector(idleTimeoutChanged)
        let idleRow = SettingsFormRow(
            title: "Close \(name) windows not used for",
            help: "They go to the archive, marked auto-closed, and reopen from there. The window in front, one playing sound and Private ones stay open.",
            accessory: .popUp(idleTimeoutPopUp))

        return formBody(SettingsForm(sections: [
            SettingsFormSection(title: "Opening", rows: [hotKeyRow, shortcutRow, optionCommandRow],
                                footnote: linksFootnote),
            SettingsFormSection(title: "Closing", rows: [idleRow]),
        ]))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for name in [QuickDetourHotKeySettings.didChangeNotification, QuickDetourHotKey.stateDidChangeNotification,
                     QuickDetourSettings.didChangeNotification] {
            observers.append(NotificationCenter.default.addMainObserver(
                forName: name, object: nil) { [weak self] _ in
                self?.updateControls()
            })
        }
        updateControls()
    }

    /// Isolated: it tears down main-actor state; the object is released on
    /// the main thread in practice, and the teardown hops there otherwise.
    isolated deinit {
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

    @objc private func hotKeySwitchChanged() {
        hotKey.settings.isEnabled = hotKeySwitch.state == .on
    }

    @objc private func optionCommandSwitchChanged() {
        quickDetourSettings.isOptionCommandClickEnabled = optionCommandSwitch.state == .on
    }

    @objc private func idleTimeoutChanged() {
        guard let raw = idleTimeoutPopUp.selectedItem?.representedObject as? String,
              let timeout = QuickDetourIdleTimeout(rawValue: raw) else { return }
        quickDetourSettings.idleTimeout = timeout
    }

    /// The controls from the settings; the warning line from the recorder's
    /// refusal, else the registration's state.
    private func updateControls() {
        optionCommandSwitch.state = quickDetourSettings.isOptionCommandClickEnabled ? .on : .off
        if let index = QuickDetourIdleTimeout.allCases.firstIndex(of: quickDetourSettings.idleTimeout) {
            idleTimeoutPopUp.selectItem(at: index)
        }
        let settings = hotKey.settings
        hotKeySwitch.state = settings.isEnabled ? .on : .off
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
        // The row tells the pane when the warning changes.
        shortcutRow.setWarning(message)
    }
}
