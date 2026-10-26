import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Detour

/// TASK-193.2: the global hotkey's register/unregister state machine, against
/// a fake registrar, and its two settings in a defaults suite of their own.
final class HotKeyRegistrationTests: XCTestCase {

    /// Records every call; refuses the shortcuts in `refused`.
    private final class FakeRegistrar: HotKeyRegistrar {
        enum Call: Equatable {
            case register(HotKeyShortcut)
            case unregister(Int)
        }
        var onPress: (() -> Void)?
        var calls: [Call] = []
        var refused: [HotKeyShortcut: OSStatus] = [:]
        private var nextToken = 1
        private(set) var held: [Int: HotKeyShortcut] = [:]

        func register(_ shortcut: HotKeyShortcut) -> Result<Int, HotKeyRegistrationError> {
            calls.append(.register(shortcut))
            if let status = refused[shortcut] { return .failure(HotKeyRegistrationError(status: status)) }
            let token = nextToken
            nextToken += 1
            held[token] = shortcut
            return .success(token)
        }

        func unregister(_ token: Int) {
            calls.append(.unregister(token))
            held[token] = nil
        }
    }

    private var registrar: FakeRegistrar!
    private var registration: HotKeyRegistration!
    private var states: [HotKeyRegistrationState] = []

    private let optionCommandN = HotKeyShortcut.quickDetourDefault
    private let hyperF12 = HotKeyShortcut(keyCode: UInt16(kVK_F12), modifiers: [.control, .option, .command], character: "")
    private let conflict = HotKeyRegistrationError(status: OSStatus(eventHotKeyExistsErr))

    override func setUp() {
        super.setUp()
        registrar = FakeRegistrar()
        registration = HotKeyRegistration(registrar: registrar)
        registration.onStateChange = { [unowned self] in self.states.append($0) }
    }

    override func tearDown() {
        registration = nil
        registrar = nil
        states.removeAll()
        super.tearDown()
    }

    // MARK: - On, off

    func testItStartsOffAndOffRegistersNothing() {
        XCTAssertEqual(registration.state, .off)
        registration.apply(enabled: false, shortcut: optionCommandN)
        XCTAssertEqual(registration.state, .off)
        XCTAssertEqual(registrar.calls, [])
        XCTAssertEqual(states, [], "no change, no callback")
    }

    func testTurningItOnRegistersTheShortcut() {
        registration.apply(enabled: true, shortcut: optionCommandN)
        XCTAssertEqual(registration.state, .registered(optionCommandN))
        XCTAssertEqual(registrar.calls, [.register(optionCommandN)])
        XCTAssertEqual(states, [.registered(optionCommandN)])
    }

    func testApplyingTheSameSettingAgainDoesNothing() {
        registration.apply(enabled: true, shortcut: optionCommandN)
        registration.apply(enabled: true, shortcut: optionCommandN)
        XCTAssertEqual(registrar.calls, [.register(optionCommandN)])
        XCTAssertEqual(states.count, 1)
    }

    func testTurningItOffUnregisters() {
        registration.apply(enabled: true, shortcut: optionCommandN)
        registration.apply(enabled: false, shortcut: optionCommandN)
        XCTAssertEqual(registration.state, .off)
        XCTAssertEqual(registrar.calls, [.register(optionCommandN), .unregister(1)])
        XCTAssertTrue(registrar.held.isEmpty)
        XCTAssertEqual(states, [.registered(optionCommandN), .off])
    }

    // MARK: - Changing the shortcut

    func testChangingTheShortcutUnregistersTheOldOneFirst() {
        registration.apply(enabled: true, shortcut: optionCommandN)
        registration.apply(enabled: true, shortcut: hyperF12)
        XCTAssertEqual(registration.state, .registered(hyperF12))
        // Unregister before register: re-registering a shortcut this process
        // holds would be refused with eventHotKeyExistsErr.
        XCTAssertEqual(registrar.calls, [.register(optionCommandN), .unregister(1), .register(hyperF12)])
        XCTAssertEqual(Array(registrar.held.values), [hyperF12], "one registration at a time")
    }

    func testClearingTheShortcutUnregisters() {
        registration.apply(enabled: true, shortcut: optionCommandN)
        registration.apply(enabled: true, shortcut: nil)
        XCTAssertEqual(registration.state, .noShortcut)
        XCTAssertEqual(registrar.calls, [.register(optionCommandN), .unregister(1)])
    }

    func testOnWithNoShortcutRegistersNothing() {
        registration.apply(enabled: true, shortcut: nil)
        XCTAssertEqual(registration.state, .noShortcut)
        XCTAssertEqual(registrar.calls, [])
    }

    // MARK: - Failure

    func testARefusedShortcutKeepsTheChoiceAndHoldsNothing() {
        registrar.refused[hyperF12] = OSStatus(eventHotKeyExistsErr)
        registration.apply(enabled: true, shortcut: hyperF12)
        XCTAssertEqual(registration.state, .failed(hyperF12, conflict))
        XCTAssertTrue(registrar.held.isEmpty)

        registration.apply(enabled: false, shortcut: hyperF12)
        XCTAssertEqual(registration.state, .off)
        XCTAssertEqual(registrar.calls, [.register(hyperF12)], "nothing held, nothing to unregister")
    }

    func testChangingAwayFromARefusedShortcutLetsGoOfTheOldRegistration() {
        registration.apply(enabled: true, shortcut: optionCommandN)
        registrar.refused[hyperF12] = OSStatus(eventHotKeyExistsErr)
        registration.apply(enabled: true, shortcut: hyperF12)
        XCTAssertEqual(registration.state, .failed(hyperF12, conflict))
        XCTAssertTrue(registrar.held.isEmpty, "the old shortcut is not kept as a fallback")

        registration.apply(enabled: true, shortcut: optionCommandN)
        XCTAssertEqual(registration.state, .registered(optionCommandN))
    }

    func testRetryRegistersOnceTheOtherAppLetsGo() {
        registrar.refused[hyperF12] = OSStatus(eventHotKeyExistsErr)
        registration.apply(enabled: true, shortcut: hyperF12)
        registration.retryIfFailed()
        XCTAssertEqual(registration.state, .failed(hyperF12, conflict), "still held elsewhere")

        registrar.refused[hyperF12] = nil
        registration.retryIfFailed()
        XCTAssertEqual(registration.state, .registered(hyperF12))
        XCTAssertEqual(registrar.calls, [.register(hyperF12), .register(hyperF12), .register(hyperF12)])
    }

    func testApplyingARefusedSettingAgainRetries() {
        registrar.refused[hyperF12] = OSStatus(eventHotKeyExistsErr)
        registration.apply(enabled: true, shortcut: hyperF12)
        registrar.refused[hyperF12] = nil
        registration.apply(enabled: true, shortcut: hyperF12)
        XCTAssertEqual(registration.state, .registered(hyperF12))
    }

    func testRetryDoesNothingUnlessRefused() {
        registration.retryIfFailed()
        registration.apply(enabled: true, shortcut: optionCommandN)
        registration.retryIfFailed()
        XCTAssertEqual(registrar.calls, [.register(optionCommandN)])
        XCTAssertEqual(registration.state, .registered(optionCommandN))
    }

    func testOnlyExistsErrIsAConflict() {
        XCTAssertTrue(HotKeyRegistrationError(status: OSStatus(eventHotKeyExistsErr)).isConflict)
        XCTAssertFalse(HotKeyRegistrationError(status: OSStatus(eventHotKeyInvalidErr)).isConflict)
        XCTAssertFalse(HotKeyRegistrationError(status: OSStatus(paramErr)).isConflict)
    }

    // MARK: - Suspended while recording

    func testSuspendingLetsGoAndResumingRegistersTheLatestSetting() {
        registration.apply(enabled: true, shortcut: optionCommandN)
        registration.setSuspended(true)
        XCTAssertEqual(registration.state, .suspended)
        XCTAssertTrue(registrar.held.isEmpty)

        registration.apply(enabled: true, shortcut: hyperF12)
        XCTAssertEqual(registration.state, .suspended, "a change while recording waits")
        XCTAssertEqual(registrar.calls, [.register(optionCommandN), .unregister(1)])

        registration.setSuspended(false)
        XCTAssertEqual(registration.state, .registered(hyperF12))
        XCTAssertEqual(registrar.calls.last, .register(hyperF12))
    }

    func testResumingWhenOffStaysOff() {
        registration.setSuspended(true)
        registration.apply(enabled: false, shortcut: optionCommandN)
        registration.setSuspended(false)
        XCTAssertEqual(registration.state, .off)
        XCTAssertEqual(registrar.calls, [])
    }

    func testRetryWaitsWhileSuspended() {
        registrar.refused[hyperF12] = OSStatus(eventHotKeyExistsErr)
        registration.apply(enabled: true, shortcut: hyperF12)
        registration.setSuspended(true)
        registrar.refused[hyperF12] = nil
        registration.retryIfFailed()
        XCTAssertEqual(registration.state, .suspended)
        registration.setSuspended(false)
        XCTAssertEqual(registration.state, .registered(hyperF12))
    }

    // MARK: - Settings

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "HotKeyRegistrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }

    func testSettingsDefaults() {
        let (defaults, _) = makeDefaults()
        let on = QuickDetourHotKeySettings(defaults: defaults, enabledByDefault: true)
        XCTAssertTrue(on.isEnabled)
        XCTAssertEqual(on.shortcut, .quickDetourDefault)
        let off = QuickDetourHotKeySettings(defaults: defaults, enabledByDefault: false)
        XCTAssertFalse(off.isEnabled, "an isolated data directory starts with it off")
        XCTAssertEqual(off.shortcut, .quickDetourDefault)
    }

    func testSettingsPersistAndNotify() {
        let (defaults, _) = makeDefaults()
        let settings = QuickDetourHotKeySettings(defaults: defaults, enabledByDefault: true)
        let notified = expectation(forNotification: QuickDetourHotKeySettings.didChangeNotification, object: settings)
        notified.expectedFulfillmentCount = 2
        settings.isEnabled = false
        settings.shortcut = hyperF12
        wait(for: [notified], timeout: 1)

        let reloaded = QuickDetourHotKeySettings(defaults: defaults, enabledByDefault: true)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertEqual(reloaded.shortcut, hyperF12)
    }

    func testAClearedShortcutStaysCleared() {
        let (defaults, _) = makeDefaults()
        let settings = QuickDetourHotKeySettings(defaults: defaults, enabledByDefault: true)
        settings.shortcut = nil
        XCTAssertNil(settings.shortcut)
        XCTAssertNil(QuickDetourHotKeySettings(defaults: defaults, enabledByDefault: true).shortcut,
                     "cleared is not the same as never set")
    }

    func testAMalformedStoredShortcutFallsBackToTheDefault() {
        let (defaults, _) = makeDefaults()
        defaults.set("garbage", forKey: QuickDetourHotKeySettings.shortcutKey)
        XCTAssertEqual(QuickDetourHotKeySettings(defaults: defaults, enabledByDefault: true).shortcut,
                       .quickDetourDefault)
    }
}
