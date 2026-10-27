import AppKit
import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "quick-detour")

/// The system-wide Quick Detour hotkey (TASK-193.2): the settings, the
/// registration state machine and the Carbon registrar, wired together, plus
/// the File menu item whose key equivalent mirrors the shortcut.
///
/// Carbon's `RegisterEventHotKey` needs no permission (an event tap, the other
/// way to see keys pressed in other apps, needs Input Monitoring or
/// Accessibility). Registered with `kEventHotKeyExclusive`; see
/// `CarbonHotKeyRegistrar` for what that does and does not detect.
/// Whether this process may register the global hotkey at all (TASK-193.2
/// review). The test host never does; a Debug build only when asked with
/// `DETOUR_GLOBAL_HOTKEY=1`: one launched from Xcode has no
/// `DETOUR_DATA_DIR`, counts as the default data directory, and would
/// otherwise take ⌥⌘N exclusively from the installed app. The data directory
/// decides only whether the hotkey starts on (`enabledByDefault`).
enum QuickDetourHotKeyAvailability: Equatable {
    case available
    case testHost
    case debugBuild

    static let optInVariable = "DETOUR_GLOBAL_HOTKEY"

    static func decide(isDebugBuild: Bool, isTestHost: Bool, environment: [String: String]) -> Self {
        if isTestHost { return .testHost }
        if isDebugBuild, environment[optInVariable] != "1" { return .debugBuild }
        return .available
    }

    /// This process's.
    static var current: Self {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return decide(isDebugBuild: isDebugBuild, isTestHost: AppDelegate.isRunningUnitTests,
                      environment: ProcessInfo.processInfo.environment)
    }

    /// What Settings says when the hotkey cannot be registered here.
    var settingsMessage: String? {
        switch self {
        case .available: return nil
        case .debugBuild: return "Debug builds don't register the global shortcut (\(Self.optInVariable)=1 turns it on)."
        case .testHost: return "The test host doesn't register the global shortcut."
        }
    }
}

final class QuickDetourHotKey {
    static let stateDidChangeNotification = Notification.Name("QuickDetourHotKeyStateDidChange")

    static let shared = QuickDetourHotKey(
        settings: QuickDetourHotKeySettings(defaults: UserDefaultsScope.defaults,
                                            // An isolated data directory (a Debug run, the
                                            // test host) starts with it off, so it never
                                            // takes the production app's shortcut.
                                            enabledByDefault: WebKitStorageScope.currentIsDefaultDataDirectory),
        registrar: CarbonHotKeyRegistrar(),
        availability: .current)

    let settings: QuickDetourHotKeySettings
    /// Whether `start` may register anything in this process.
    let availability: QuickDetourHotKeyAvailability
    private let registrar: HotKeyRegistrar
    private let registration: HotKeyRegistration
    private var observers: [NSObjectProtocol] = []
    private var settingsObserver: NSObjectProtocol?
    private(set) var isStarted = false

    /// File > New Quick Detour Window, whose key equivalent is the shortcut.
    weak var menuItem: NSMenuItem? {
        didSet { updateMenuItem() }
    }

    var state: HotKeyRegistrationState { registration.state }

    init(settings: QuickDetourHotKeySettings, registrar: HotKeyRegistrar,
         availability: QuickDetourHotKeyAvailability = .available) {
        self.settings = settings
        self.availability = availability
        self.registrar = registrar
        registration = HotKeyRegistration(registrar: registrar)
        registration.onStateChange = { [weak self] state in
            Self.logState(state)
            NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: self)
        }
        // The menu item follows the settings whether or not this process
        // registers anything (a Debug build without the opt-in, the test host).
        settingsObserver = NotificationCenter.default.addObserver(
            forName: QuickDetourHotKeySettings.didChangeNotification, object: settings, queue: .main) { [weak self] _ in
            self?.apply()
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Registers the hotkey as set and follows the settings from now on.
    /// `onPress` runs on the main thread for each press. Does nothing unless
    /// `availability` is `.available` (never in the test host; in a Debug
    /// build only with `DETOUR_GLOBAL_HOTKEY=1`).
    func start(onPress: @escaping () -> Void) {
        guard !isStarted else { return }
        guard availability == .available else {
            log.notice("Quick Detour hotkey not registered in this process: \(String(describing: self.availability), privacy: .public)")
            return
        }
        isStarted = true
        registrar.onPress = onPress
        // Another app may have let go of a refused shortcut since.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.registration.retryIfFailed()
        })
        apply()
    }

    /// Lets go of the hotkey (at quit).
    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        registration.unregisterAll()
        isStarted = false
    }

    /// While the Settings recorder records, the hotkey is let go, so pressing
    /// the current shortcut records it rather than opening the launcher.
    func setRecording(_ recording: Bool) {
        guard isStarted else { return }
        registration.setSuspended(recording)
    }

    /// Tries a refused shortcut again (the Quick Detour settings pane does when it appears).
    func retryIfFailed() {
        registration.retryIfFailed()
    }

    /// The menu item's shortcut follows the setting even when the global
    /// hotkey is off: it is Detour's own shortcut for the launcher.
    private func apply() {
        updateMenuItem()
        guard isStarted else { return }
        registration.apply(enabled: settings.isEnabled, shortcut: settings.shortcut)
    }

    private func updateMenuItem() {
        guard let menuItem else { return }
        let shortcut = settings.shortcut
        menuItem.keyEquivalent = shortcut?.keyEquivalent ?? ""
        menuItem.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    }

    /// The message Settings shows under the control, or nil.
    static func message(for state: HotKeyRegistrationState) -> String? {
        guard case .failed(let shortcut, let error) = state else { return nil }
        if error.isConflict {
            return "Another app is using \(shortcut.displayString). Choose another shortcut, or change it in that app."
        }
        return "\(shortcut.displayString) could not be set up as a shortcut for every app (error \(error.status))."
    }

    private static func logState(_ state: HotKeyRegistrationState) {
        switch state {
        case .off: log.notice("Quick Detour hotkey off")
        case .noShortcut: log.notice("Quick Detour hotkey on with no shortcut")
        case .suspended: log.notice("Quick Detour hotkey suspended while recording")
        case .registered(let shortcut):
            log.notice("Quick Detour hotkey registered: \(shortcut.displayString, privacy: .public)")
        case .failed(let shortcut, let error):
            log.notice("Quick Detour hotkey refused: \(shortcut.displayString, privacy: .public) status \(error.status)")
        }
    }
}

/// `RegisterEventHotKey`, the registrar of the app.
///
/// What this macOS (26.7) does, probed with two processes (TASK-193.2):
/// - Without `kEventHotKeyExclusive`, a second process registering the same
///   shortcut succeeds, and **both** get every press. Only a second
///   registration in the *same* process is refused (`eventHotKeyExistsErr`).
/// - With it, registering fails with `eventHotKeyExistsErr` only when another
///   process holds the shortcut exclusively too. An exclusive registration
///   over a non-exclusive one succeeds and takes the presses from it; a
///   non-exclusive one over an exclusive one succeeds and gets nothing.
/// - Cmd-Tab is refused (the system holds it exclusively); Cmd-Space and
///   Cmd-Shift-3 are accepted although macOS answers them first, which is why
///   the recorder checks `CopySymbolicHotKeys`.
/// So the refusal Settings reports means another app (or another Detour)
/// holds it exclusively; an app holding it without the option is not seen,
/// and loses the key to Detour.
final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    var onPress: (() -> Void)?

    private static let signature: OSType = 0x4454_5144  // 'DTQD'
    private var handler: EventHandlerRef?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1

    /// The handler holds an unretained pointer to this registrar, so both it
    /// and the hotkeys go with it.
    deinit {
        for ref in hotKeys.values { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ shortcut: HotKeyShortcut) -> Result<Int, HotKeyRegistrationError> {
        // A hotkey with no handler would read as registered and never fire.
        let installed = installHandlerIfNeeded()
        guard installed == noErr else { return .failure(HotKeyRegistrationError(status: installed)) }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return .failure(HotKeyRegistrationError(status: status)) }
        hotKeys[id] = ref
        return .success(Int(id))
    }

    func unregister(_ token: Int) {
        guard let ref = hotKeys.removeValue(forKey: UInt32(token)) else { return }
        UnregisterEventHotKey(ref)
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handler == nil else { return noErr }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
            guard status == noErr, id.signature == CarbonHotKeyRegistrar.signature,
                  registrar.hotKeys[id.id] != nil else { return OSStatus(eventNotHandledErr) }
            log.notice("Quick Detour hotkey pressed")
            registrar.onPress?()
            return noErr
        }, 1, &pressed, context, &handler)
    }
}
