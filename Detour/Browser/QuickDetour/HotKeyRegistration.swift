import AppKit
import Carbon.HIToolbox

/// Registers and unregisters one system-wide hotkey. The app's is
/// `CarbonHotKeyRegistrar`; tests use a fake.
protocol HotKeyRegistrar: AnyObject {
    /// Runs on the main thread for each press of a registered shortcut.
    var onPress: (() -> Void)? { get set }
    /// Registers `shortcut`; the token to unregister it with, or the OSStatus
    /// the system refused it with.
    func register(_ shortcut: HotKeyShortcut) -> Result<Int, HotKeyRegistrationError>
    func unregister(_ token: Int)
}

struct HotKeyRegistrationError: Error, Equatable {
    let status: OSStatus

    /// `eventHotKeyExistsErr`: another app holds the shortcut exclusively (or,
    /// for a non-exclusive registration, this process already holds it).
    var isConflict: Bool { status == OSStatus(eventHotKeyExistsErr) }
}

/// The global hotkey's state (TASK-193.2).
enum HotKeyRegistrationState: Equatable {
    /// Turned off in Settings.
    case off
    /// Turned on with no shortcut (the recorder was cleared).
    case noShortcut
    /// Held while the Settings recorder records, so pressing the current
    /// shortcut records it instead of opening the launcher.
    case suspended
    case registered(HotKeyShortcut)
    /// Refused; the user's choice is kept and shown with the error.
    case failed(HotKeyShortcut, HotKeyRegistrationError)
}

/// The register/unregister state machine behind the global hotkey: applies
/// the setting (on, off, a new shortcut) to the registrar, holding at most one
/// registration, and retries a refused one when asked.
final class HotKeyRegistration {
    private let registrar: HotKeyRegistrar
    private(set) var state: HotKeyRegistrationState = .off {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// Called after every change of `state`.
    var onStateChange: ((HotKeyRegistrationState) -> Void)?

    /// The last setting applied, which a resume or a retry goes back to.
    private var enabled = false
    private var shortcut: HotKeyShortcut?
    private var suspended = false
    /// The registration held, and what it is for.
    private var held: (token: Int, shortcut: HotKeyShortcut)?

    init(registrar: HotKeyRegistrar) {
        self.registrar = registrar
    }

    /// Makes the registration match the setting.
    func apply(enabled: Bool, shortcut: HotKeyShortcut?) {
        self.enabled = enabled
        self.shortcut = shortcut
        update()
    }

    /// Stops answering the hotkey until `setSuspended(false)`.
    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        update()
    }

    /// Tries a refused registration again (another app may have let it go).
    func retryIfFailed() {
        guard case .failed = state else { return }
        update()
    }

    /// Lets go of the registration, whatever the setting (at quit).
    func unregisterAll() {
        release()
        state = .off
    }

    private func update() {
        guard enabled else {
            release()
            state = .off
            return
        }
        guard !suspended else {
            release()
            state = .suspended
            return
        }
        guard let shortcut else {
            release()
            state = .noShortcut
            return
        }
        if let held, held.shortcut == shortcut { return }
        // Let go first: registering a shortcut this process already holds is
        // refused with eventHotKeyExistsErr.
        release()
        switch registrar.register(shortcut) {
        case .success(let token):
            held = (token, shortcut)
            state = .registered(shortcut)
        case .failure(let error):
            state = .failed(shortcut, error)
        }
    }

    private func release() {
        guard let held else { return }
        self.held = nil
        registrar.unregister(held.token)
    }
}

/// The hotkey's two settings, in the data directory's defaults suite
/// (`UserDefaultsScope.defaults`).
final class QuickDetourHotKeySettings {
    static let didChangeNotification = Notification.Name("QuickDetourHotKeySettingsDidChange")

    static let enabledKey = "QuickDetourHotKeyEnabled"
    static let shortcutKey = "QuickDetourHotKeyShortcut"

    private let defaults: UserDefaults
    private let enabledByDefault: Bool

    init(defaults: UserDefaults, enabledByDefault: Bool) {
        self.defaults = defaults
        self.enabledByDefault = enabledByDefault
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? enabledByDefault }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// The shortcut; Opt-Cmd-N until changed, nil once cleared. A cleared
    /// shortcut is stored as an empty dictionary, so it is not mistaken for
    /// one never set; anything unreadable is the default.
    var shortcut: HotKeyShortcut? {
        get {
            guard let stored = defaults.object(forKey: Self.shortcutKey) else { return .quickDetourDefault }
            if let dictionary = stored as? [String: Any], dictionary.isEmpty { return nil }
            return HotKeyShortcut(propertyList: stored) ?? .quickDetourDefault
        }
        set {
            defaults.set(newValue?.propertyList ?? [String: Any](), forKey: Self.shortcutKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
