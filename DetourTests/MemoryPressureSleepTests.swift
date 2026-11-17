import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-407: sleeping tabs on macOS memory pressure — the user's "shorten, then
/// sweep" rule.
///
/// - Warning: for two minutes after the last warning, hidden normal tabs sleep
///   once out of sight for five minutes (the profile's threshold is shortened,
///   never lengthened; a never-sleep profile is honoured).
/// - Critical: every eligible hidden tab sleeps now, pinned entries' and
///   favourites' backing tabs included.
/// - At most one pressure sweep per 30 s; a burst defers, never drops.
///
/// Events are delivered through `MemoryPressureSleeper.receive(_:)` with an
/// injected clock and a manual scheduler: no real dispatch source, no timers.
nonisolated final class MemoryPressureSleepTests: XCTestCase {

    /// Nothing listens on port 1, so nothing here reaches the network.
    private let pageURL = URL(string: "http://127.0.0.1:1/page")!
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private var createdTabs: [BrowserTab] = []
    private var defaultFaviconFetch: ((URL, @escaping @Sendable (NSImage?) -> Void) -> Void)!

    @MainActor override func setUp() async throws {
        try await super.setUp()
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
    }

    @MainActor override func tearDown() async throws {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// Stands in for a page capturing the camera or microphone, which WebKit
    /// will not start without a device and a permission prompt.
    private final class CapturingTab: BrowserTab {
        override var isCapturingMedia: Bool { true }
    }

    /// The sleeper's clock and its re-checks, driven by hand.
    @MainActor private final class ManualClock {
        var now: Date
        /// How late each armed check fires, as real timers do.
        var lateness: TimeInterval = 0
        private var pending: [(at: Date, fire: @MainActor @Sendable () -> Void)] = []

        init(now: Date, driving sleeper: MemoryPressureSleeper) {
            self.now = now
            // Held strongly: a test may drop its handle while the sleeper
            // still reads the clock.
            sleeper.clock = { self.now }
            sleeper.schedule = { delay, fire in
                self.pending.append((self.now.addingTimeInterval(delay), fire))
            }
            // Batches run back to back; `testCriticalIsStaggeredAndRechecksEachTurn`
            // queues them instead.
            sleeper.nextTurn = { turn in turn() }
        }

        /// The time of the earliest armed check.
        var nextCheckAt: Date? { pending.map(\.at).min() }

        /// Moves the clock to `time`, firing every check armed for that time or
        /// earlier, in order.
        func advance(to time: Date) {
            while let index = pending.indices.min(by: { pending[$0].at < pending[$1].at }),
                  pending[index].at <= time {
                let check = pending.remove(at: index)
                now = check.at.addingTimeInterval(lateness)
                check.fire()
            }
            now = time
        }
    }

    @MainActor private func makeStore() throws -> (TabStore, Profile, Space, ManualClock) {
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()))
        let profile = store.addProfile(name: "Pressure")
        let space = store.addSpace(name: "Pressure", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        return (store, profile, space, ManualClock(now: start, driving: store.memoryPressureSleeper))
    }

    @discardableResult
    @MainActor private func makeNormalTab(_ store: TabStore, in space: Space) -> BrowserTab {
        let tab = store.addTab(in: space)
        tab.url = pageURL
        createdTabs.append(tab)
        return tab
    }

    @MainActor private func makePinnedEntry(_ store: TabStore, in space: Space) -> PinnedEntry {
        let tab = makeNormalTab(store, in: space)
        store.pinTab(id: tab.id, in: space)
        return space.pinnedEntries.first { $0.tab === tab }!
    }

    @MainActor private func makeFavorite(_ store: TabStore, _ profile: Profile, in space: Space) -> Favorite {
        let tab = BrowserTab(configuration: space.makeWebViewConfiguration())
        tab.spaceID = space.id
        tab.url = pageURL
        createdTabs.append(tab)
        store.addFavorite(from: tab, profileID: profile.id)
        return profile.favorites.first { $0.tab === tab }!
    }

    @MainActor private func hide(_ tab: BrowserTab, for seconds: TimeInterval, before now: Date) {
        tab.lastDeselectedAt = now.addingTimeInterval(-seconds)
    }

    // MARK: - Policy

    @MainActor func testLevelFromTheSourceEvent() {
        XCTAssertEqual(MemoryPressureSleepPolicy.Level(.warning), .warning)
        XCTAssertEqual(MemoryPressureSleepPolicy.Level(.critical), .critical)
        XCTAssertEqual(MemoryPressureSleepPolicy.Level([.warning, .critical]), .critical)
        XCTAssertNil(MemoryPressureSleepPolicy.Level(.normal), "a return to normal changes nothing")
    }

    @MainActor func testWarningCapLastsTwoMinutes() {
        var policy = MemoryPressureSleepPolicy()
        XCTAssertNil(policy.idleThresholdCap(at: start))
        policy.note(.warning, at: start)
        XCTAssertEqual(policy.idleThresholdCap(at: start), 5 * 60)
        XCTAssertEqual(policy.idleThresholdCap(at: start.addingTimeInterval(120)), 5 * 60)
        XCTAssertNil(policy.idleThresholdCap(at: start.addingTimeInterval(121)))
        // A later warning restarts the window.
        policy.note(.warning, at: start.addingTimeInterval(100))
        XCTAssertEqual(policy.idleThresholdCap(at: start.addingTimeInterval(220)), 5 * 60)
    }

    @MainActor func testWarningWindowIsRescannedEveryThirtySecondsUntilItCloses() {
        var policy = MemoryPressureSleepPolicy()
        policy.note(.warning, at: start)
        var sweeps: [TimeInterval] = []
        var now = start
        while true {
            if let level = policy.takeDueSweep(at: now) {
                XCTAssertEqual(level, .warning)
                sweeps.append(now.timeIntervalSince(start))
            }
            guard let next = policy.nextCheck(after: now) else { break }
            XCTAssertGreaterThan(next, now, "a check never re-arms for the same instant")
            now = next
        }
        XCTAssertEqual(sweeps, [0, 30, 60, 90, 120])
    }

    @MainActor func testCriticalSoonAfterASweepIsDeferredNotDropped() {
        var policy = MemoryPressureSleepPolicy()
        policy.note(.warning, at: start)
        XCTAssertEqual(policy.takeDueSweep(at: start), .warning)

        let tenSecondsLater = start.addingTimeInterval(10)
        policy.note(.critical, at: tenSecondsLater)
        XCTAssertNil(policy.takeDueSweep(at: tenSecondsLater), "within 30 s of the last sweep")
        XCTAssertEqual(policy.nextCheck(after: tenSecondsLater), start.addingTimeInterval(30))
        XCTAssertEqual(policy.takeDueSweep(at: start.addingTimeInterval(30)), .critical,
                       "a pending critical outranks the warning window")
    }

    @MainActor func testCriticalIsOneShot() {
        var policy = MemoryPressureSleepPolicy()
        policy.note(.critical, at: start)
        XCTAssertEqual(policy.takeDueSweep(at: start), .critical)
        XCTAssertNil(policy.nextCheck(after: start), "no warning window: nothing more is due")
        XCTAssertNil(policy.idleThresholdCap(at: start))
    }

    // MARK: - Warning

    @MainActor func testWarningSleepsNormalTabsHiddenFiveMinutes() throws {
        let (store, profile, space, _) = try makeStore()
        let stale = makeNormalTab(store, in: space)
        let recent = makeNormalTab(store, in: space)
        let pinnedTab = try XCTUnwrap(makePinnedEntry(store, in: space).tab)
        let favoriteTab = try XCTUnwrap(makeFavorite(store, profile, in: space).tab)
        hide(stale, for: 5 * 60 + 1, before: start)
        hide(recent, for: 4 * 60, before: start)
        hide(pinnedTab, for: 30 * 60, before: start)
        hide(favoriteTab, for: 30 * 60, before: start)

        store.memoryPressureSleeper.receive(.warning)

        XCTAssertTrue(stale.isSleeping, "hidden past 5 min, well inside the profile's hour")
        XCTAssertFalse(recent.isSleeping)
        XCTAssertFalse(pinnedTab.isSleeping, "a warning leaves pinned entries to their usual rules")
        XCTAssertFalse(favoriteTab.isSleeping, "a warning leaves favourites to their usual rules")
    }

    /// A tab that crosses five minutes inside the window is caught by the
    /// rescans, not left for the periodic five-minute sweep.
    @MainActor func testWarningRescansCatchATabCrossingFiveMinutesInsideTheWindow() throws {
        let (store, _, space, clock) = try makeStore()
        let tab = makeNormalTab(store, in: space)
        hide(tab, for: 4 * 60 + 15, before: start)

        store.memoryPressureSleeper.receive(.warning)
        XCTAssertFalse(tab.isSleeping)
        XCTAssertEqual(clock.nextCheckAt, start.addingTimeInterval(30))

        clock.advance(to: start.addingTimeInterval(30))
        XCTAssertFalse(tab.isSleeping, "4:45 hidden at the first rescan")
        clock.advance(to: start.addingTimeInterval(60))
        XCTAssertTrue(tab.isSleeping, "5:15 hidden at the second rescan")
    }

    /// Real timers fire late. The last rescan, at +120 s, must still run, or a
    /// tab crossing 5 minutes between +90 s and +120 s is missed.
    @MainActor func testTheLastRescanRunsWhenTimersFireLate() throws {
        let (store, _, space, clock) = try makeStore()
        clock.lateness = 0.05
        let tab = makeNormalTab(store, in: space)
        hide(tab, for: 3 * 60 + 15, before: start)

        store.memoryPressureSleeper.receive(.warning)
        clock.advance(to: start.addingTimeInterval(100))
        XCTAssertFalse(tab.isSleeping, "4:45 hidden at the +90 s rescan")

        clock.advance(to: start.addingTimeInterval(200))
        XCTAssertTrue(tab.isSleeping, "5:15 hidden at the +120 s rescan")
        XCTAssertNil(clock.nextCheckAt)
    }

    @MainActor func testWarningWindowEndsTwoMinutesAfterTheLastWarning() throws {
        let (store, _, space, clock) = try makeStore()
        let tab = makeNormalTab(store, in: space)
        // Not hidden yet when the warning comes; hidden 5 min only after the
        // window has closed.
        store.memoryPressureSleeper.receive(.warning)
        clock.advance(to: start.addingTimeInterval(1_000))
        XCTAssertNil(clock.nextCheckAt, "no rescans once the window has closed")

        hide(tab, for: 10 * 60, before: clock.now)
        store.sleepStaleTabs(now: clock.now)
        XCTAssertFalse(tab.isSleeping, "outside the window the profile's hour applies again")
    }

    @MainActor func testThePeriodicSweepInsideTheWindowUsesTheShortenedThreshold() throws {
        let (store, _, space, _) = try makeStore()
        store.memoryPressureSleeper.receive(.warning)

        let tab = makeNormalTab(store, in: space)
        let now = start.addingTimeInterval(90)
        hide(tab, for: 6 * 60, before: now)
        store.sleepStaleTabs(now: now)

        XCTAssertTrue(tab.isSleeping)
    }

    @MainActor func testWarningHonoursANeverSleepProfile() throws {
        let (store, profile, space, _) = try makeStore()
        profile.sleepThreshold = .never
        let tab = makeNormalTab(store, in: space)
        hide(tab, for: 3 * 60 * 60, before: start)

        store.memoryPressureSleeper.receive(.warning)

        XCTAssertFalse(tab.isSleeping)
    }

    // MARK: - Critical

    @MainActor func testCriticalSleepsEveryHiddenTabIncludingPinnedAndFavorites() throws {
        let (store, profile, space, _) = try makeStore()
        let normal = makeNormalTab(store, in: space)
        let entry = makePinnedEntry(store, in: space)
        let favorite = makeFavorite(store, profile, in: space)
        let pinnedTab = try XCTUnwrap(entry.tab)
        let favoriteTab = try XCTUnwrap(favorite.tab)
        for tab in [normal, pinnedTab, favoriteTab] { hide(tab, for: 1, before: start) }

        store.memoryPressureSleeper.receive(.critical)

        XCTAssertTrue(normal.isSleeping)
        XCTAssertTrue(pinnedTab.isSleeping)
        XCTAssertTrue(favoriteTab.isSleeping)
        // Live but asleep: selecting them wakes into the cached session.
        XCTAssertTrue(entry.tab === pinnedTab)
        XCTAssertTrue(favorite.tab === favoriteTab)
    }

    @MainActor func testCriticalReportsHowManyTabsSlept() throws {
        let (store, _, space, _) = try makeStore()
        for _ in 0..<3 { hide(makeNormalTab(store, in: space), for: 1, before: start) }
        let selected = makeNormalTab(store, in: space)
        selected.lastDeselectedAt = nil

        XCTAssertEqual(store.sleepStaleTabs(now: start, pressure: .critical), 3)
        XCTAssertEqual(store.sleepStaleTabs(now: start, pressure: .critical), 0, "already asleep")
    }

    @MainActor func testCriticalSparesSelectedAudibleCapturingAndHostedTabs() throws {
        let (store, profile, space, _) = try makeStore()

        let selected = makeNormalTab(store, in: space)
        selected.lastDeselectedAt = nil
        let selectedFavorite = try XCTUnwrap(makeFavorite(store, profile, in: space).tab)
        selectedFavorite.lastDeselectedAt = nil

        let audible = makeNormalTab(store, in: space)
        hide(audible, for: 1, before: start)
        audible.isPlayingAudio = true
        let audiblePinned = try XCTUnwrap(makePinnedEntry(store, in: space).tab)
        hide(audiblePinned, for: 1, before: start)
        audiblePinned.isPlayingAudio = true

        let capturing = CapturingTab(configuration: space.makeWebViewConfiguration())
        capturing.url = pageURL
        createdTabs.append(capturing)
        store.insertTab(capturing, in: space, parentID: nil)
        hide(capturing, for: 1, before: start)

        let hosted = makeNormalTab(store, in: space)
        hide(hosted, for: 1, before: start)
        hosted.ensureWebViewContainer()
        let contentArea = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        contentArea.addSubview(try XCTUnwrap(hosted.webViewContainer))

        store.memoryPressureSleeper.receive(.critical)

        XCTAssertFalse(selected.isSleeping, "on screen")
        XCTAssertFalse(selectedFavorite.isSleeping, "on screen")
        XCTAssertFalse(audible.isSleeping, "audible")
        XCTAssertFalse(audiblePinned.isSleeping, "audible")
        XCTAssertFalse(capturing.isSleeping, "capturing camera or microphone")
        XCTAssertFalse(hosted.isSleeping, "hosted in some window")
    }

    /// `sleep()` itself spares capture, so a hidden host whose Peek is on a
    /// call parks everything but that Peek; a forced sleep still stops it.
    @MainActor func testSleepSparesACapturingPeekAndForceStopsIt() throws {
        let (store, _, space, _) = try makeStore()
        let host = makeNormalTab(store, in: space)
        hide(host, for: 1, before: start)
        let peek = CapturingTab(configuration: space.makeWebViewConfiguration())
        peek.url = pageURL
        createdTabs.append(peek)
        host.peekTab = peek
        XCTAssertNotNil(peek.webView)

        store.memoryPressureSleeper.receive(.critical)

        XCTAssertTrue(host.isSleeping)
        XCTAssertFalse(peek.isSleeping, "a capturing Peek is not slept with its host")
        XCTAssertNotNil(peek.webView)

        peek.sleep(force: true)
        XCTAssertTrue(peek.isSleeping, "a forced sleep stops capture")
    }

    @MainActor func testCriticalHonoursANeverSleepProfile() throws {
        let (store, profile, space, _) = try makeStore()
        profile.sleepThreshold = .never
        let normal = makeNormalTab(store, in: space)
        let pinnedTab = try XCTUnwrap(makePinnedEntry(store, in: space).tab)
        let favoriteTab = try XCTUnwrap(makeFavorite(store, profile, in: space).tab)
        for tab in [normal, pinnedTab, favoriteTab] { hide(tab, for: 60 * 60, before: start) }

        store.memoryPressureSleeper.receive(.critical)

        XCTAssertFalse(normal.isSleeping)
        XCTAssertFalse(pinnedTab.isSleeping)
        XCTAssertFalse(favoriteTab.isSleeping)
    }

    @MainActor func testCriticalSparesASplitWhosePartnerIsOnScreen() throws {
        let (store, _, space, _) = try makeStore()
        let left = makeNormalTab(store, in: space)
        let right = makeNormalTab(store, in: space)
        store.createSplit(draggedTabID: left.id, targetTabID: right.id, edge: .left, in: space)
        XCTAssertNotNil(left.splitGroupID)
        hide(left, for: 60, before: start)
        right.lastDeselectedAt = nil

        store.memoryPressureSleeper.receive(.critical)

        XCTAssertFalse(left.isSleeping, "a split pane never sleeps while its partner is on screen")
        XCTAssertFalse(right.isSleeping)
    }

    @MainActor func testCriticalSparesAPinnedSplitWhosePartnerIsOnScreen() throws {
        let (store, _, space, clock) = try makeStore()
        let first = makePinnedEntry(store, in: space)
        let second = makePinnedEntry(store, in: space)
        let groupID = UUID()
        for entry in [first, second] {
            entry.splitGroupID = groupID
            entry.splitFraction = 0.5
        }
        let firstTab = try XCTUnwrap(first.tab)
        let secondTab = try XCTUnwrap(second.tab)
        hide(firstTab, for: 60, before: start)
        secondTab.lastDeselectedAt = nil

        store.memoryPressureSleeper.receive(.critical)

        XCTAssertFalse(firstTab.isSleeping, "a pinned split pane waits for its partner")
        XCTAssertFalse(secondTab.isSleeping)

        // Both hidden: the pair sleeps together on the next critical sweep.
        clock.advance(to: start.addingTimeInterval(30))
        hide(secondTab, for: 1, before: clock.now)
        store.memoryPressureSleeper.receive(.critical)
        XCTAssertTrue(firstTab.isSleeping)
        XCTAssertTrue(secondTab.isSleeping)
    }

    @MainActor func testTheSweepIsLoggedWithItsLevelAndCount() throws {
        let (store, _, space, _) = try makeStore()
        for _ in 0..<6 { hide(makeNormalTab(store, in: space), for: 1, before: start) }

        store.memoryPressureSleeper.receive(.critical)

        XCTAssertEqual(store.memoryPressureSleeper.lastSweepResult, .init(level: .critical, slept: 6),
                       "six tabs over two batches of four, reported once")
    }

    /// A critical sweep sleeps `tabsPerTurn` tabs per main-loop turn and asks
    /// for the candidates again each turn, so a tab selected between batches
    /// keeps its web view.
    @MainActor func testCriticalIsStaggeredAndRechecksEachTurn() throws {
        let (store, _, space, _) = try makeStore()
        let sleeper = store.memoryPressureSleeper
        var turns: [@MainActor @Sendable () -> Void] = []
        sleeper.nextTurn = { turns.append($0) }
        let tabs = (0..<9).map { _ in makeNormalTab(store, in: space) }
        for tab in tabs { hide(tab, for: 1, before: start) }

        sleeper.receive(.critical)
        XCTAssertEqual(tabs.filter(\.isSleeping).count, 4, "the first batch only")
        XCTAssertEqual(turns.count, 1)
        XCTAssertNil(sleeper.lastSweepResult, "not logged until the last batch")

        let selectedMeanwhile = try XCTUnwrap(tabs.first { !$0.isSleeping })
        selectedMeanwhile.lastDeselectedAt = nil

        while !turns.isEmpty { turns.removeFirst()() }

        XCTAssertFalse(selectedMeanwhile.isSleeping, "selected between batches")
        XCTAssertEqual(tabs.filter(\.isSleeping).count, 8)
        XCTAssertEqual(sleeper.lastSweepResult, .init(level: .critical, slept: 8))
    }

    // MARK: - Rate limit

    @MainActor func testABurstOfEventsSweepsOnceThenDefersToThirtySeconds() throws {
        let (store, _, space, clock) = try makeStore()
        store.memoryPressureSleeper.receive(.critical)

        // Hidden only after the first sweep: the burst below must not reach it
        // until the rescan interval is over.
        let tab = makeNormalTab(store, in: space)
        for second in 1...10 {
            clock.advance(to: start.addingTimeInterval(TimeInterval(second)))
            hide(tab, for: 0.5, before: clock.now)
            store.memoryPressureSleeper.receive(.critical)
            XCTAssertFalse(tab.isSleeping, "no second sweep within 30 s (t+\(second))")
        }
        XCTAssertEqual(clock.nextCheckAt, start.addingTimeInterval(30), "deferred, not dropped")

        clock.advance(to: start.addingTimeInterval(30))
        XCTAssertTrue(tab.isSleeping, "the deferred critical sweep ran at the 30 s mark")
        XCTAssertNil(clock.nextCheckAt)
    }

    @MainActor func testSupersededChecksDoNotRunExtraSweeps() throws {
        let (store, _, space, clock) = try makeStore()
        store.memoryPressureSleeper.receive(.critical)
        // Three deferrals arm three checks; only the latest may sweep.
        for second in [5, 10, 15] {
            clock.advance(to: start.addingTimeInterval(TimeInterval(second)))
            store.memoryPressureSleeper.receive(.critical)
        }
        let tab = makeNormalTab(store, in: space)
        hide(tab, for: 1, before: start.addingTimeInterval(30))
        clock.advance(to: start.addingTimeInterval(30))
        XCTAssertTrue(tab.isSleeping)

        // The sweep at 30 s was the only one: a tab hidden right after it waits
        // for another event.
        let later = makeNormalTab(store, in: space)
        hide(later, for: 1, before: start.addingTimeInterval(45))
        clock.advance(to: start.addingTimeInterval(45))
        XCTAssertFalse(later.isSleeping)
    }

    // MARK: - Cost (measurement leg)

    /// How long a critical sweep holds the main thread over 40 live tabs with
    /// loaded pages. Run with `TEST_RUNNER_DETOUR_MEASURE_PRESSURE_SWEEP=1`;
    /// it prints the figure. The test host has no window or sidebar observing
    /// the tabs, so the app pays a little more per tab than measured here.
    @MainActor func testMeasureCriticalSweepCost() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DETOUR_MEASURE_PRESSURE_SWEEP"] == "1",
                          "measurement leg: set TEST_RUNNER_DETOUR_MEASURE_PRESSURE_SWEEP=1")
        let (store, _, space, _) = try makeStore()
        var tabs: [BrowserTab] = []
        for index in 0..<40 {
            let tab = makeNormalTab(store, in: space)
            let body = String(repeating: "<p>Paragraph of text with <a href=\"#\">a link</a>.</p>", count: 300)
            tab.webView?.loadHTMLString("<html><body><h1>Tab \(index)</h1>\(body)</body></html>",
                                        baseURL: URL(string: "https://example.invalid/\(index)"))
            tabs.append(tab)
        }
        let deadline = Date().addingTimeInterval(30)
        while tabs.contains(where: { $0.webView?.isLoading ?? true }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(1))
        let now = Date()
        for tab in tabs { hide(tab, for: 1, before: now) }

        let clock = ContinuousClock()
        let started = clock.now
        let slept = store.sleepStaleTabs(now: now, pressure: .critical)
        let sweep = clock.now - started
        // What the released web views cost on the next turns of the main loop.
        let drainStarted = clock.now
        try await Task.sleep(for: .milliseconds(1))
        let drain = clock.now - drainStarted
        print("MEASURE pressure sweep: slept \(slept) tabs in \(sweep) (\(sweep / max(slept, 1)) per tab); next main-loop turn \(drain)")
        XCTAssertEqual(slept, tabs.count)
    }
}
