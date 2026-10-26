import XCTest
import AppKit
@testable import Detour

/// TASK-193.5: the pure rules of Quick Detour's other entry points and its
/// idle auto-close — the settings, the Opt-Cmd click, a sidebar tab's copy,
/// the profile a link from another app opens on, the idle rule and its
/// intervals, the archive label.
final class QuickDetourEntryPointsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "QuickDetourEntryPointsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Settings

    func testTheSettingsDefaultToOptionCommandOnAndSixHours() {
        let settings = QuickDetourSettings(defaults: defaults)
        XCTAssertTrue(settings.isOptionCommandClickEnabled)
        XCTAssertEqual(settings.idleTimeout, .sixHours)
        XCTAssertEqual(QuickDetourIdleTimeout.default, .sixHours)
    }

    func testTheSettingsPersistAndNotify() {
        let settings = QuickDetourSettings(defaults: defaults)
        var notified = 0
        let observer = NotificationCenter.default.addObserver(
            forName: QuickDetourSettings.didChangeNotification, object: settings, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.isOptionCommandClickEnabled = false
        settings.idleTimeout = .never
        XCTAssertEqual(notified, 2)

        let reread = QuickDetourSettings(defaults: defaults)
        XCTAssertFalse(reread.isOptionCommandClickEnabled)
        XCTAssertEqual(reread.idleTimeout, .never)
        settings.idleTimeout = .oneDay
        XCTAssertEqual(QuickDetourSettings(defaults: defaults).idleTimeout, .oneDay)
    }

    func testAnUnreadableTimeoutIsTheDefault() {
        defaults.set("fortnight", forKey: QuickDetourSettings.idleTimeoutKey)
        XCTAssertEqual(QuickDetourSettings(defaults: defaults).idleTimeout, .sixHours)
        defaults.set(42, forKey: QuickDetourSettings.idleTimeoutKey)
        XCTAssertEqual(QuickDetourSettings(defaults: defaults).idleTimeout, .sixHours)
    }

    func testTheTimeoutsTheirIntervalsAndTitles() {
        XCTAssertEqual(QuickDetourIdleTimeout.allCases, [.never, .oneHour, .sixHours, .twelveHours, .oneDay],
                       "the pop-up's order")
        XCTAssertNil(QuickDetourIdleTimeout.never.interval)
        XCTAssertEqual(QuickDetourIdleTimeout.oneHour.interval, 3600)
        XCTAssertEqual(QuickDetourIdleTimeout.sixHours.interval, 6 * 3600)
        XCTAssertEqual(QuickDetourIdleTimeout.twelveHours.interval, 12 * 3600)
        XCTAssertEqual(QuickDetourIdleTimeout.oneDay.interval, 24 * 3600)
        XCTAssertEqual(QuickDetourIdleTimeout.allCases.map(\.title), ["Never", "1 hour", "6 hours", "12 hours", "1 day"])
    }

    // MARK: - Opt-Cmd-click

    func testTheQuickDetourClickIsCommandAndOption() {
        XCTAssertTrue(QuickDetour.isQuickDetourClick([.command, .option], enabled: true))
        XCTAssertTrue(QuickDetour.isQuickDetourClick([.command, .option, .shift], enabled: true))
        XCTAssertTrue(QuickDetour.isQuickDetourClick([.command, .option, .capsLock], enabled: true))
        XCTAssertFalse(QuickDetour.isQuickDetourClick(.command, enabled: true))
        XCTAssertFalse(QuickDetour.isQuickDetourClick(.option, enabled: true))
        XCTAssertFalse(QuickDetour.isQuickDetourClick([], enabled: true))
        XCTAssertFalse(QuickDetour.isQuickDetourClick([.command, .option], enabled: false), "the setting off")
    }

    func testASplitRowsPaneIsTheHalfClicked() {
        XCTAssertEqual(QuickDetour.splitRowPane(forX: 10, rowWidth: 200), .left)
        XCTAssertEqual(QuickDetour.splitRowPane(forX: 99, rowWidth: 200), .left)
        XCTAssertEqual(QuickDetour.splitRowPane(forX: 100, rowWidth: 200), .right)
        XCTAssertEqual(QuickDetour.splitRowPane(forX: 190, rowWidth: 200), .right)
    }

    func testASidebarTabsCopyIsItsPageElseItsSavedAddress() {
        let page = URL(string: "https://example.com/now")!
        let saved = URL(string: "https://example.com/")!
        XCTAssertEqual(QuickDetour.sidebarCopyURL(liveURL: page, storedURL: saved), page,
                       "a live tab: where it is now, not its pinned home")
        XCTAssertEqual(QuickDetour.sidebarCopyURL(liveURL: nil, storedURL: saved), saved, "a dormant entry or favourite")
        XCTAssertNil(QuickDetour.sidebarCopyURL(liveURL: nil, storedURL: nil), "a new tab with no page")
    }

    // MARK: - Links from other apps

    func testARoutedLinkOpensOnTheFrontmostWindowsProfile() {
        let first = Profile(name: "Default")
        let work = Profile(name: "Work")
        XCTAssertTrue(QuickDetour.profileForRoutedLink(windowProfiles: [work, first], profiles: [first, work]) === work)
    }

    func testARoutedLinkNeverOpensInPrivate() {
        let privateProfile = Profile(id: TabStore.incognitoProfileID, name: "Private", isIncognito: true)
        let first = Profile(name: "Default")
        let work = Profile(name: "Work")
        XCTAssertTrue(QuickDetour.profileForRoutedLink(windowProfiles: [privateProfile, work],
                                                       profiles: [privateProfile, first, work]) === work,
                      "a Private window in front is passed over for the next window's profile")
        XCTAssertTrue(QuickDetour.profileForRoutedLink(windowProfiles: [privateProfile],
                                                       profiles: [privateProfile, first, work]) === first)
    }

    func testARoutedLinkWithNoWindowUsesTheFirstNormalProfile() {
        let privateProfile = Profile(id: TabStore.incognitoProfileID, name: "Private", isIncognito: true)
        let first = Profile(name: "Default")
        let gone = Profile(name: "Gone")
        gone.isDeleted = true
        XCTAssertTrue(QuickDetour.profileForRoutedLink(windowProfiles: [], profiles: [privateProfile, first]) === first)
        XCTAssertTrue(QuickDetour.profileForRoutedLink(windowProfiles: [gone], profiles: [gone, first]) === first)
        XCTAssertNil(QuickDetour.profileForRoutedLink(windowProfiles: [], profiles: [privateProfile]))
    }

    // MARK: - The idle rule

    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    private func idle(_ unusedFor: TimeInterval, frontmost: Bool = false, audible: Bool = false,
                      isPrivate: Bool = false, sheet: Bool = false, interval: TimeInterval? = 3600) -> Bool {
        QuickDetour.shouldAutoClose(
            QuickDetourIdleState(lastUsedAt: start, isFrontmost: frontmost, isAudible: audible,
                                 isPrivate: isPrivate, hasSheet: sheet),
            now: start.addingTimeInterval(unusedFor), interval: interval)
    }

    func testItClosesOnceUnusedForTheInterval() {
        XCTAssertFalse(idle(0))
        XCTAssertFalse(idle(3599))
        XCTAssertTrue(idle(3600))
        XCTAssertTrue(idle(10 * 3600))
    }

    func testNeverMeansNever() {
        XCTAssertFalse(idle(365 * 24 * 3600, interval: nil))
    }

    func testTheFrontmostWindowNeverCloses() {
        XCTAssertFalse(idle(10 * 3600, frontmost: true))
    }

    func testPlayingSoundCountsAsUse() {
        XCTAssertFalse(idle(10 * 3600, audible: true))
    }

    func testAPrivateQuickDetourNeverAutoCloses() {
        // Nothing would be archived, so the timer would simply lose it.
        XCTAssertFalse(idle(10 * 3600, isPrivate: true))
    }

    func testNotWhileASheetIsUp() {
        XCTAssertFalse(idle(10 * 3600, sheet: true))
    }

    func testTimeAsleepCountsAsUnused() {
        // A wall-clock rule: the Mac slept 8 hours since the last use.
        XCTAssertTrue(idle(8 * 3600, interval: 6 * 3600))
    }

    func testAClockSetBackDoesNotClose() {
        XCTAssertFalse(idle(-5 * 3600))
    }

    func testTheTestOverrideReplacesEveryIntervalButNever() {
        XCTAssertEqual(QuickDetour.idleInterval(for: .sixHours, overrideSeconds: nil), 6 * 3600)
        XCTAssertNil(QuickDetour.idleInterval(for: .never, overrideSeconds: nil))
        XCTAssertEqual(QuickDetour.idleInterval(for: .sixHours, overrideSeconds: 5), 5)
        XCTAssertEqual(QuickDetour.idleInterval(for: .oneDay, overrideSeconds: 5), 5)
        XCTAssertNil(QuickDetour.idleInterval(for: .never, overrideSeconds: 5), "Never stays never")
    }

    func testTheCheckRunsEveryMinuteOrFasterWithAnOverride() {
        XCTAssertEqual(QuickDetour.idleCheckInterval(overrideSeconds: nil), 60)
        XCTAssertEqual(QuickDetour.idleCheckInterval(overrideSeconds: 8), 2)
        XCTAssertEqual(QuickDetour.idleCheckInterval(overrideSeconds: 2), 1, "at least a second")
        XCTAssertEqual(QuickDetour.idleCheckInterval(overrideSeconds: 3600), 60, "never slower than a minute")
    }

    // MARK: - The archive

    func testTheArchiveLabel() {
        XCTAssertEqual(QuickDetour.archiveLabel(autoClosed: false), "Quick Detour")
        XCTAssertEqual(QuickDetour.archiveLabel(autoClosed: true), "Quick Detour · auto-closed")
    }
}
