import XCTest
import WebKit
@testable import Detour

/// TASK-193.5 in real windows: closing a Quick Detour archives it, a Private
/// one is not archived, the archive page's restore reopens a Quick Detour, and
/// the idle monitor closes an unused one into the archive as auto-closed —
/// never the frontmost, never with a sheet up, never with Never set, and
/// what counts as use starting the time again.
///
/// Real windows on `TabStore.shared`, with a profile of the test's own whose
/// records are deleted afterwards; the monitor runs on an injected clock and
/// settings of the test's own.
@MainActor
final class QuickDetourArchiveWindowTests: XCTestCase {

    private var controllers: [QuickDetourWindowController] = []
    private var createdProfiles: [Profile] = []
    private static var retainedProfiles: [Profile] = []
    private var suiteName: String!
    private var monitor: QuickDetourIdleMonitor { .shared }
    private var savedClock: (() -> Date)!
    private var savedSettings: QuickDetourSettings!
    private var clock = Date(timeIntervalSince1970: 1_900_000_000)

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "QuickDetourArchiveWindowTests-\(UUID().uuidString)"
        savedClock = monitor.now
        savedSettings = monitor.settings
        monitor.settings = QuickDetourSettings(defaults: UserDefaults(suiteName: suiteName)!)
        monitor.now = { [unowned self] in self.clock }
    }

    override func tearDown() async throws {
        for controller in QuickDetourWindowController.openControllers where controllers.contains(where: { $0 === controller })
            || createdProfiles.contains(where: { $0 === controller.profile }) {
            controller.closeDisposition = .discard
            controller.close()
        }
        controllers.removeAll()
        for profile in createdProfiles {
            AppDatabase.shared.deleteClosedTabs(spaceID: QuickDetour.historySpaceIDString(forProfileID: profile.id))
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        monitor.now = savedClock
        monitor.settings = savedSettings
        UserDefaults().removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeProfile() -> Profile {
        let profile = TabStore.shared.addProfile(name: "Quick Detour Archive \(UUID().uuidString.prefix(4))")
        createdProfiles.append(profile)
        return profile
    }

    private func open(_ profile: Profile, _ path: String = "a") -> QuickDetourWindowController {
        let controller = QuickDetourWindowController.open(
            profile: profile, url: URL(string: "https://quick-detour-archive.invalid/\(path)")!)
        controllers.append(controller)
        return controller
    }

    private func records(of profile: Profile) -> [ClosedTabSummary] {
        AppDatabase.shared.closedTabSummaries(spaceID: QuickDetour.historySpaceIDString(forProfileID: profile.id))
    }

    private func isOpen(_ controller: QuickDetourWindowController) -> Bool {
        QuickDetourWindowController.openControllers.contains { $0 === controller }
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Closing

    func testClosingTheWindowArchivesItsPage() throws {
        let profile = makeProfile()
        let controller = open(profile, "closed")
        controller.tab?.title = "Closed page"

        controller.closeCurrentTab(nil)

        XCTAssertFalse(isOpen(controller))
        let record = try XCTUnwrap(records(of: profile).first)
        XCTAssertEqual(record.url, "https://quick-detour-archive.invalid/closed")
        XCTAssertEqual(record.title, "Closed page")
        XCTAssertNil(record.archivedAt, "closed by hand")
        let entry = try XCTUnwrap(TabStore.shared.archiveEntries().first { $0.id == record.id })
        XCTAssertEqual(entry.kind, .quickDetour(profileID: profile.id, autoClosed: false))
    }

    func testAPrivateQuickDetourIsNotArchived() throws {
        let privateProfile = TabStore.shared.ensureIncognitoProfile()
        let before = records(of: privateProfile).count
        let controller = open(privateProfile, "private")

        controller.closeCurrentTab(nil)

        XCTAssertFalse(isOpen(controller))
        XCTAssertEqual(records(of: privateProfile).count, before)
    }

    func testMovingThePageWithOpenInIsNotAClose() throws {
        // The profile pill's replacement is a switch, not a close either.
        let profile = makeProfile()
        let other = makeProfile()
        let controller = open(profile, "switched")
        XCTAssertTrue(controller.switchProfile(to: other))
        XCTAssertTrue(records(of: profile).isEmpty, "the old page is replaced, not archived")
    }

    // MARK: - Restoring

    func testRestoringReopensAQuickDetourOnItsProfile() throws {
        let profile = makeProfile()
        let closing = open(profile, "restore-me")
        closing.tab?.title = "Restore me"
        closing.closeCurrentTab(nil)
        let recordID = try XCTUnwrap(records(of: profile).first?.id)

        let restored = try XCTUnwrap(QuickDetourWindowController.restore(recordID: recordID))
        controllers.append(restored)

        XCTAssertTrue(isOpen(restored))
        XCTAssertTrue(restored.profile === profile)
        XCTAssertEqual(restored.tab?.url, URL(string: "https://quick-detour-archive.invalid/restore-me"))
        XCTAssertEqual(restored.tab?.title, "Restore me")
        XCTAssertTrue(restored.window?.isVisible == true)
        XCTAssertTrue(records(of: profile).isEmpty, "the record is consumed")
        XCTAssertNil(QuickDetourWindowController.restore(recordID: recordID), "only once")
    }

    func testRestoringASpacesRecordOpensNoQuickDetour() throws {
        let space = try XCTUnwrap(TabStore.shared.nonIncognitoSpaces.first)
        let tab = TabStore.shared.addTab(in: space, url: URL(string: "https://quick-detour-archive.invalid/tab"))
        TabStore.shared.closeTab(id: tab.id, in: space, undoable: true, registersUndo: false)
        let recordID = try XCTUnwrap(AppDatabase.shared.closedTabSummaries(spaceID: space.id.uuidString).first?.id)
        defer { AppDatabase.shared.deleteClosedTab(id: recordID) }
        let before = QuickDetourWindowController.openControllers.count

        XCTAssertNil(QuickDetourWindowController.restore(recordID: recordID))
        XCTAssertEqual(QuickDetourWindowController.openControllers.count, before)
        XCTAssertNotNil(AppDatabase.shared.closedTabSummary(id: recordID))
    }

    // MARK: - Idle auto-close

    func testAnUnusedQuickDetourClosesIntoTheArchiveAsAutoClosed() throws {
        let profile = makeProfile()
        let idle = open(profile, "idle")
        let front = open(profile, "front")
        XCTAssertTrue(front.idleState.isFrontmost, "the one opened last is in front")
        XCTAssertFalse(idle.idleState.isFrontmost)

        clock = clock.addingTimeInterval(6 * 3600 - 1)
        XCTAssertEqual(monitor.check(), 0, "not yet")
        XCTAssertTrue(isOpen(idle))

        clock = clock.addingTimeInterval(1)
        XCTAssertEqual(monitor.check(), 1)

        XCTAssertFalse(isOpen(idle))
        XCTAssertTrue(isOpen(front), "the frontmost one never closes")
        let record = try XCTUnwrap(records(of: profile).first)
        XCTAssertEqual(record.url, "https://quick-detour-archive.invalid/idle")
        XCTAssertNotNil(record.archivedAt, "auto-closed")
        let entry = try XCTUnwrap(TabStore.shared.archiveEntries().first { $0.id == record.id })
        XCTAssertEqual(entry.kind, .quickDetour(profileID: profile.id, autoClosed: true))
    }

    func testNeverKeepsThemOpen() {
        let profile = makeProfile()
        let idle = open(profile, "never")
        _ = open(profile, "front")
        monitor.settings.idleTimeout = .never

        clock = clock.addingTimeInterval(30 * 24 * 3600)
        XCTAssertEqual(monitor.check(), 0)
        XCTAssertTrue(isOpen(idle))
    }

    func testTheSettingIsReadAtEachCheck() {
        let profile = makeProfile()
        let idle = open(profile, "one-hour")
        _ = open(profile, "front")
        monitor.settings.idleTimeout = .oneHour

        clock = clock.addingTimeInterval(3600)
        XCTAssertEqual(monitor.check(), 1)
        XCTAssertFalse(isOpen(idle))
    }

    func testInputAndBecomingKeyCountAsUse() throws {
        let profile = makeProfile()
        let idle = open(profile, "used")
        _ = open(profile, "front")
        let window = try XCTUnwrap(idle.window)

        clock = clock.addingTimeInterval(5 * 3600)
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 105))
        window.sendEvent(key)
        XCTAssertEqual(idle.lastUsedAt, clock, "a key press in it")

        clock = clock.addingTimeInterval(5 * 3600)
        XCTAssertEqual(monitor.check(), 0, "5 hours since the key press")

        clock = clock.addingTimeInterval(1)
        idle.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        XCTAssertEqual(idle.lastUsedAt, clock, "it stopped being key just now")
        idle.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        XCTAssertEqual(idle.lastUsedAt, clock)
    }

    func testNotWhileASheetIsUp() throws {
        let profile = makeProfile()
        let idle = open(profile, "sheet")
        _ = open(profile, "front")
        let window = try XCTUnwrap(idle.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        window.beginSheet(sheet)
        for _ in 0..<20 where window.attachedSheet == nil { spin() }
        XCTAssertNotNil(window.attachedSheet)
        defer { window.endSheet(sheet) }

        clock = clock.addingTimeInterval(7 * 3600)
        XCTAssertTrue(idle.idleState.hasSheet)
        monitor.check()
        XCTAssertTrue(isOpen(idle), "its sheet's completion would outlive the window")
    }

    func testAPrivateQuickDetourIsNeverClosedByTheTimer() {
        let privateProfile = TabStore.shared.ensureIncognitoProfile()
        let idle = open(privateProfile, "private-idle")
        _ = open(makeProfile(), "front")

        clock = clock.addingTimeInterval(7 * 3600)
        monitor.check()
        XCTAssertTrue(isOpen(idle))
    }
}
