import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Detour

/// TASK-193.2: the hotkey wired up — settings to registration and to the
/// File menu item's key equivalent, the Settings message, the hotkey's
/// toggle, and that the test host never registers anything system-wide.
@MainActor
final class QuickDetourHotKeyTests: XCTestCase {

    private final class FakeRegistrar: HotKeyRegistrar {
        var onPress: (() -> Void)?
        var refused: Set<HotKeyShortcut> = []
        private(set) var held: [Int: HotKeyShortcut] = [:]
        private var next = 1
        func register(_ shortcut: HotKeyShortcut) -> Result<Int, HotKeyRegistrationError> {
            if refused.contains(shortcut) { return .failure(HotKeyRegistrationError(status: OSStatus(eventHotKeyExistsErr))) }
            defer { next += 1 }
            held[next] = shortcut
            return .success(next)
        }
        func unregister(_ token: Int) { held[token] = nil }
    }

    private let hyperF12 = HotKeyShortcut(keyCode: UInt16(kVK_F12), modifiers: [.control, .option, .command], character: "")

    private func makeHotKey(enabledByDefault: Bool = true) -> (QuickDetourHotKey, FakeRegistrar, NSMenuItem) {
        let suite = "QuickDetourHotKeyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let registrar = FakeRegistrar()
        let hotKey = QuickDetourHotKey(settings: QuickDetourHotKeySettings(defaults: defaults, enabledByDefault: enabledByDefault),
                                       registrar: registrar)
        addTeardownBlock { hotKey.stop() }
        let item = NSMenuItem(title: "New Quick Detour Window", action: nil, keyEquivalent: "x")
        hotKey.menuItem = item
        return (hotKey, registrar, item)
    }

    func testTheTestHostNeverRegistersTheHotKey() {
        XCTAssertFalse(QuickDetourHotKey.shared.isStarted)
        XCTAssertEqual(QuickDetourHotKey.shared.state, .off)
        XCTAssertFalse(QuickDetourHotKey.shared.settings.isEnabled,
                       "an isolated data directory (the test host's) starts with it off")
    }

    func testStartingRegistersTheSettingAndFollowsIt() {
        let (hotKey, registrar, _) = makeHotKey()
        hotKey.start {}
        XCTAssertEqual(hotKey.state, .registered(.quickDetourDefault))
        XCTAssertEqual(Array(registrar.held.values), [.quickDetourDefault])

        hotKey.settings.shortcut = hyperF12
        XCTAssertEqual(hotKey.state, .registered(hyperF12), "a change re-registers at once")
        XCTAssertEqual(Array(registrar.held.values), [hyperF12])

        hotKey.settings.isEnabled = false
        XCTAssertEqual(hotKey.state, .off)
        XCTAssertTrue(registrar.held.isEmpty)
    }

    /// The press callback reaches the registrar, whichever registrar it is.
    func testStartingHandsThePressCallbackToTheRegistrar() {
        let (hotKey, registrar, _) = makeHotKey()
        var presses = 0
        hotKey.start { presses += 1 }
        registrar.onPress?()
        XCTAssertEqual(presses, 1)
    }

    func testTheMenuItemMirrorsTheShortcutEvenWhenOff() {
        let (hotKey, _, item) = makeHotKey(enabledByDefault: false)
        XCTAssertEqual(item.keyEquivalent, "n", "set as soon as the item is attached")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        hotKey.start {}
        XCTAssertEqual(hotKey.state, .off)

        hotKey.settings.shortcut = hyperF12
        XCTAssertEqual(item.keyEquivalent, "\u{F70F}")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.control, .option, .command])

        hotKey.settings.shortcut = nil
        XCTAssertEqual(item.keyEquivalent, "", "cleared: no key equivalent")
    }

    func testRecordingSuspendsTheRegistration() {
        let (hotKey, registrar, _) = makeHotKey()
        hotKey.start {}
        hotKey.setRecording(true)
        XCTAssertEqual(hotKey.state, .suspended)
        XCTAssertTrue(registrar.held.isEmpty)
        hotKey.settings.shortcut = hyperF12
        hotKey.setRecording(false)
        XCTAssertEqual(hotKey.state, .registered(hyperF12))
    }

    func testARefusalIsReportedAndRetried() {
        let (hotKey, registrar, _) = makeHotKey()
        registrar.refused = [.quickDetourDefault]
        hotKey.start {}
        XCTAssertEqual(QuickDetourHotKey.message(for: hotKey.state),
                       "Another app is using ⌥⌘N. Choose another shortcut, or change it in that app.")
        XCTAssertTrue(hotKey.settings.isEnabled, "the user's choice is kept")

        registrar.refused = []
        hotKey.retryIfFailed()
        XCTAssertEqual(hotKey.state, .registered(.quickDetourDefault))
        XCTAssertNil(QuickDetourHotKey.message(for: hotKey.state))
    }

    func testBecomingActiveRetriesARefusedShortcut() {
        let (hotKey, registrar, _) = makeHotKey()
        registrar.refused = [.quickDetourDefault]
        hotKey.start {}
        registrar.refused = []
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(hotKey.state, .registered(.quickDetourDefault))
    }

    func testOtherErrorsAreReportedWithTheirStatus() {
        let state = HotKeyRegistrationState.failed(hyperF12, HotKeyRegistrationError(status: OSStatus(eventHotKeyInvalidErr)))
        XCTAssertEqual(QuickDetourHotKey.message(for: state),
                       "⌃⌥⌘F12 could not be set up as a shortcut for every app (error -9879).")
        XCTAssertNil(QuickDetourHotKey.message(for: .off))
        XCTAssertNil(QuickDetourHotKey.message(for: .registered(hyperF12)))
    }

    /// The hotkey toggles the launcher, as Spotlight's does.
    func testTheHotKeyTogglesTheLauncher() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let launcher = QuickDetourLauncher.shared
        addTeardownBlock { launcher.close() }
        XCTAssertFalse(launcher.isShowing)
        appDelegate.quickDetourHotKeyPressed()
        XCTAssertTrue(launcher.isShowing)
        appDelegate.quickDetourHotKeyPressed()
        XCTAssertFalse(launcher.isShowing)
    }

    /// Choosing the menu item (not a key press) while the panel is up keeps it up.
    func testTheMenuItemShowsTheLauncherWithoutToggling() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let launcher = QuickDetourLauncher.shared
        addTeardownBlock { launcher.close() }
        appDelegate.newQuickDetourWindow(nil)
        XCTAssertTrue(launcher.isShowing)
        appDelegate.newQuickDetourWindow(nil)
        XCTAssertTrue(launcher.isShowing)
    }

    /// The real File menu item is the hotkey's menu item.
    func testTheFileMenuItemIsAttached() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let item = try XCTUnwrap(appDelegate.quickDetourMenuItem)
        XCTAssertTrue(QuickDetourHotKey.shared.menuItem === item)
        XCTAssertEqual(item.action, #selector(AppDelegate.newQuickDetourWindow(_:)))
        let shortcut = QuickDetourHotKey.shared.settings.shortcut
        XCTAssertEqual(item.keyEquivalent, shortcut?.keyEquivalent ?? "")
    }

    // MARK: - The recorder

    private func keyEvent(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags, _ characters: String,
                          window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode))!
    }

    private func makeRecorder() -> (ShortcutRecorderView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = ShortcutRecorderView()
        window.contentView?.addSubview(recorder)
        addTeardownBlock { window.close() }
        return (recorder, window)
    }

    func testTheRecorderRecordsCancelsClearsAndRefuses() {
        let (recorder, window) = makeRecorder()
        var changes: [HotKeyShortcut?] = []
        var recording: [Bool] = []
        var refusals: [String?] = []
        recorder.shortcut = .quickDetourDefault
        recorder.onChange = { changes.append($0) }
        recorder.onRecordingChange = { recording.append($0) }
        recorder.onRefuse = { refusals.append($0) }
        recorder.problem = { $0.keyCode == UInt16(kVK_ANSI_T) ? .usedByMenu("File > New Tab") : nil }

        recorder.beginRecording()
        XCTAssertTrue(recorder.isRecording)
        recorder.keyDown(with: keyEvent(kVK_F11, [.control, .option, .command], "\u{F70E}", window: window))
        XCTAssertFalse(recorder.isRecording)
        let f11 = HotKeyShortcut(keyCode: UInt16(kVK_F11), modifiers: [.control, .option, .command], character: "")
        XCTAssertEqual(changes, [f11])
        XCTAssertEqual(recorder.shortcut, f11)

        recorder.beginRecording()
        XCTAssertTrue(recorder.performKeyEquivalent(with: keyEvent(kVK_ANSI_T, [.command], "t", window: window)),
                      "a Cmd key is taken before the menus")
        XCTAssertTrue(recorder.isRecording, "a refused shortcut keeps it recording")
        XCTAssertEqual(refusals.last, "⌘T is the shortcut of File > New Tab.")
        recorder.keyDown(with: keyEvent(kVK_Escape, [], "\u{1b}", window: window))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.shortcut, f11, "Escape keeps the shortcut")

        recorder.beginRecording()
        recorder.keyDown(with: keyEvent(kVK_Delete, [], "\u{7f}", window: window))
        XCTAssertNil(recorder.shortcut)
        XCTAssertEqual(changes.count, 2)
        XCTAssertNil(changes.last ?? .quickDetourDefault, "cleared")
        XCTAssertEqual(recording, [true, false, true, false, true, false])
    }

    func testTheRecorderStopsWhenItsWindowResignsKey() {
        let (recorder, window) = makeRecorder()
        recorder.beginRecording()
        XCTAssertTrue(recorder.isRecording)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(recorder.isRecording, "the hotkey must not stay suspended while the user is elsewhere")
    }

    func testTheRecorderSavesBeforeItStopsRecording() {
        let (recorder, window) = makeRecorder()
        var order: [String] = []
        recorder.onChange = { _ in order.append("change") }
        recorder.onRecordingChange = { order.append($0 ? "start" : "stop") }
        recorder.beginRecording()
        recorder.keyDown(with: keyEvent(kVK_ANSI_K, [.control, .command], "k", window: window))
        XCTAssertEqual(order, ["start", "change", "stop"],
                       "the registration resumes straight onto the new shortcut")
    }

    // MARK: - Where it may register (review follow-up)

    func testTheTestHostNeverRegistersEvenWhenAsked() {
        XCTAssertEqual(QuickDetourHotKeyAvailability.decide(isDebugBuild: true, isTestHost: true,
                                                            environment: ["DETOUR_GLOBAL_HOTKEY": "1"]), .testHost)
        XCTAssertEqual(QuickDetourHotKeyAvailability.decide(isDebugBuild: false, isTestHost: true, environment: [:]),
                       .testHost)
        XCTAssertEqual(QuickDetourHotKeyAvailability.current, .testHost)
    }

    func testADebugBuildRegistersOnlyWhenAsked() {
        XCTAssertEqual(QuickDetourHotKeyAvailability.decide(isDebugBuild: true, isTestHost: false, environment: [:]),
                       .debugBuild, "launched from Xcode: no DETOUR_DATA_DIR, so the default data directory")
        XCTAssertEqual(QuickDetourHotKeyAvailability.decide(isDebugBuild: true, isTestHost: false,
                                                            environment: ["DETOUR_DATA_DIR": "DetourVerify1932"]),
                       .debugBuild, "an isolated data directory does not opt in")
        for value in ["0", "", "true", "yes"] {
            XCTAssertEqual(QuickDetourHotKeyAvailability.decide(isDebugBuild: true, isTestHost: false,
                                                                environment: ["DETOUR_GLOBAL_HOTKEY": value]),
                           .debugBuild, value)
        }
        XCTAssertEqual(QuickDetourHotKeyAvailability.decide(isDebugBuild: true, isTestHost: false,
                                                            environment: ["DETOUR_GLOBAL_HOTKEY": "1"]), .available)
    }

    func testAReleaseBuildRegisters() {
        XCTAssertEqual(QuickDetourHotKeyAvailability.decide(isDebugBuild: false, isTestHost: false, environment: [:]),
                       .available)
        XCTAssertEqual(QuickDetourHotKeyAvailability.decide(isDebugBuild: false, isTestHost: false,
                                                            environment: ["DETOUR_GLOBAL_HOTKEY": "0"]), .available,
                       "the variable only opts a Debug build in")
    }

    func testSettingsSaysWhyItIsInactive() {
        XCTAssertNil(QuickDetourHotKeyAvailability.available.settingsMessage)
        XCTAssertEqual(QuickDetourHotKeyAvailability.debugBuild.settingsMessage,
                       "Debug builds don't register the global shortcut (DETOUR_GLOBAL_HOTKEY=1 turns it on).")
        XCTAssertNotNil(QuickDetourHotKeyAvailability.testHost.settingsMessage)
    }

    /// Found at runtime: in a Debug build without the opt-in the menu item
    /// kept ⌥⌘N after the shortcut changed, because only `start` followed the
    /// settings.
    func testTheMenuItemFollowsTheSettingWhereNothingRegisters() {
        let suite = "QuickDetourHotKeyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let registrar = FakeRegistrar()
        let hotKey = QuickDetourHotKey(settings: QuickDetourHotKeySettings(defaults: defaults, enabledByDefault: true),
                                       registrar: registrar, availability: .debugBuild)
        addTeardownBlock { hotKey.stop() }
        let item = NSMenuItem(title: "New Quick Detour Window", action: nil, keyEquivalent: "")
        hotKey.menuItem = item
        hotKey.start {}
        XCTAssertFalse(hotKey.isStarted)
        hotKey.settings.shortcut = hyperF12
        XCTAssertEqual(item.keyEquivalent, "\u{F70F}")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.control, .option, .command])
        XCTAssertEqual(hotKey.state, .off)
        XCTAssertTrue(registrar.held.isEmpty, "a Debug build without the opt-in registers nothing")
    }

    func testTheSharedHotKeyIsNotAvailableInTheTestHost() {
        XCTAssertEqual(QuickDetourHotKey.shared.availability, .testHost)
    }

    // MARK: - The recorder: a click elsewhere (review follow-up)

    func testAMouseDownOutsideTheRecorderEndsRecording() {
        let bounds = NSRect(x: 0, y: 0, width: 132, height: 22)
        XCTAssertFalse(ShortcutRecorderView.mouseDownEndsRecording(inRecorderWindow: true,
                                                                   pointInRecorder: NSPoint(x: 60, y: 10),
                                                                   recorderBounds: bounds),
                       "on the recorder: its own mouseDown toggles")
        XCTAssertTrue(ShortcutRecorderView.mouseDownEndsRecording(inRecorderWindow: true,
                                                                  pointInRecorder: NSPoint(x: -20, y: 10),
                                                                  recorderBounds: bounds), "the checkbox beside it")
        XCTAssertTrue(ShortcutRecorderView.mouseDownEndsRecording(inRecorderWindow: true,
                                                                  pointInRecorder: NSPoint(x: 60, y: 300),
                                                                  recorderBounds: bounds), "the toolbar above")
        XCTAssertTrue(ShortcutRecorderView.mouseDownEndsRecording(inRecorderWindow: false,
                                                                  pointInRecorder: NSPoint(x: 60, y: 10),
                                                                  recorderBounds: bounds), "another window")
    }

    /// Through the event loop: a mouse-down elsewhere in the window, taken
    /// from the queue and sent as AppKit does, ends recording.
    func testAClickElsewhereInTheWindowEndsRecordingThroughTheMonitor() throws {
        let (recorder, window) = makeRecorder()
        recorder.frame = NSRect(x: 10, y: 10, width: 132, height: 22)
        window.makeKeyAndOrderFront(nil)
        var recording: [Bool] = []
        recorder.onRecordingChange = { recording.append($0) }
        recorder.beginRecording()
        XCTAssertTrue(recorder.isRecording)

        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 250, y: 80),
                                                     modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.postEvent(event, atStart: true)
        if let dequeued = NSApp.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 1),
                                          inMode: .default, dequeue: true) {
            NSApp.sendEvent(dequeued)
        }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recording, [true, false])
    }
}
