import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-104: the "show budget" second sleep trigger.
///
/// WebKit's GPU process keeps one byte-capped IOSurfacePool per WebContent
/// process, and every hidden -> visible transition of a web view strands a few
/// purged surfaces in it that only the WebContent process's death frees. The
/// tabs shown most often — pinned entries' and favourites' backing tabs — are
/// exactly the ones the idle rule never sleeps, so a tab that has been hosted
/// `TabStore.sleepShowBudget` times becomes eligible on the much shorter
/// `sleepShowBudgetGrace` instead of the profile's `sleepThreshold`.
///
/// The rule only ever *shortens* a threshold: a selected tab
/// (`lastDeselectedAt == nil`), an audible tab and a tab used within the grace
/// are never slept by it.
@MainActor
final class SleepShowBudgetTests: XCTestCase {

    /// Nothing listens on port 1, so nothing here reaches the network.
    private let pageURL = URL(string: "http://127.0.0.1:1/page")!

    private var createdTabs: [BrowserTab] = []
    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!

    override func setUp() {
        super.setUp()
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
    }

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeStore() throws -> (TabStore, Profile, Space) {
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()))
        let profile = store.addProfile(name: "Budget")
        let space = store.addSpace(name: "Budget", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        return (store, profile, space)
    }

    /// A live (web-view-carrying) tab in the space's tab list.
    @discardableResult
    private func makeNormalTab(_ store: TabStore, in space: Space) -> BrowserTab {
        let tab = store.addTab(in: space)
        tab.url = pageURL
        createdTabs.append(tab)
        return tab
    }

    /// A live tab that belongs to no list yet — what a favourite is backed by.
    private func makeLooseTab(in space: Space) -> BrowserTab {
        let tab = BrowserTab(configuration: space.makeWebViewConfiguration())
        tab.spaceID = space.id
        tab.url = pageURL
        createdTabs.append(tab)
        return tab
    }

    private func makePinnedEntry(_ store: TabStore, in space: Space) -> PinnedEntry {
        let tab = makeNormalTab(store, in: space)
        store.pinTab(id: tab.id, in: space)
        return space.pinnedEntries.first { $0.tab === tab }!
    }

    private func makeFavorite(_ store: TabStore, _ profile: Profile, in space: Space) -> Favorite {
        let tab = makeLooseTab(in: space)
        store.addFavorite(from: tab, profileID: profile.id)
        return profile.favorites.first { $0.tab === tab }!
    }

    /// Spends the tab's whole show budget.
    private func spendBudget(_ tab: BrowserTab) {
        for _ in 0..<TabStore.sleepShowBudget { tab.noteShown() }
    }

    /// Out of sight for longer than the budget grace, but well inside the
    /// profile's one-hour idle threshold — so only the budget rule can fire.
    private func deselectedBeyondGrace(_ tab: BrowserTab, now: Date) {
        tab.lastDeselectedAt = now.addingTimeInterval(-TabStore.sleepShowBudgetGrace - 60)
    }

    // MARK: - The budget rule reaches every section

    func testBudgetAndGraceSleepNormalPinnedAndFavoriteTabs() throws {
        let (store, profile, space) = try makeStore()
        let now = Date()

        let normal = makeNormalTab(store, in: space)
        let entry = makePinnedEntry(store, in: space)
        let favorite = makeFavorite(store, profile, in: space)
        let pinnedTab = try XCTUnwrap(entry.tab)
        let favoriteTab = try XCTUnwrap(favorite.tab)

        for tab in [normal, pinnedTab, favoriteTab] {
            spendBudget(tab)
            deselectedBeyondGrace(tab, now: now)
        }

        store.sleepStaleTabs(now: now)

        XCTAssertTrue(normal.isSleeping, "a normal tab over its show budget sleeps")
        XCTAssertTrue(pinnedTab.isSleeping, "a pinned entry's backing tab over its show budget sleeps")
        XCTAssertTrue(favoriteTab.isSleeping, "a favourite's backing tab over its show budget sleeps")
        // Live but asleep: the entry and the favourite keep their tabs, so
        // selecting them wakes back into the cached session rather than
        // rebuilding a dormant tile.
        XCTAssertTrue(entry.isLive)
        XCTAssertTrue(entry.tab === pinnedTab)
        XCTAssertTrue(favorite.isLive)
        XCTAssertTrue(favorite.tab === favoriteTab)
        XCTAssertNil(pinnedTab.webView, "sleeping releases the web view — the point of the rule")
        XCTAssertNil(favoriteTab.webView)
    }

    func testBudgetWithinGraceDoesNotSleep() throws {
        let (store, profile, space) = try makeStore()
        let now = Date()

        let normal = makeNormalTab(store, in: space)
        let entry = makePinnedEntry(store, in: space)
        let favorite = makeFavorite(store, profile, in: space)
        let tabs = [normal, try XCTUnwrap(entry.tab), try XCTUnwrap(favorite.tab)]

        for tab in tabs {
            spendBudget(tab)
            // Used a minute ago: over budget, but crossing it must never sleep
            // a tab right after it was used.
            tab.lastDeselectedAt = now.addingTimeInterval(-60)
        }

        store.sleepStaleTabs(now: now)

        for tab in tabs {
            XCTAssertFalse(tab.isSleeping, "the grace has not elapsed")
        }
    }

    func testOneShowShortOfTheBudgetDoesNotSleep() throws {
        let (store, _, space) = try makeStore()
        let now = Date()

        let normal = makeNormalTab(store, in: space)
        for _ in 0..<(TabStore.sleepShowBudget - 1) { normal.noteShown() }
        deselectedBeyondGrace(normal, now: now)

        store.sleepStaleTabs(now: now)

        XCTAssertFalse(normal.isSleeping)
    }

    // MARK: - The idle rule is unchanged

    func testIdleRuleUnaffectedBelowTheThreshold() throws {
        let (store, profile, space) = try makeStore()
        let now = Date()

        let normal = makeNormalTab(store, in: space)
        let entry = makePinnedEntry(store, in: space)
        let favorite = makeFavorite(store, profile, in: space)
        let tabs = [normal, try XCTUnwrap(entry.tab), try XCTUnwrap(favorite.tab)]
        // Half an hour idle: past the budget grace, but no budget was spent and
        // the profile sleeps at one hour.
        for tab in tabs { tab.lastDeselectedAt = now.addingTimeInterval(-30 * 60) }

        store.sleepStaleTabs(now: now)

        for tab in tabs { XCTAssertFalse(tab.isSleeping) }
    }

    func testIdleRuleStillSleepsNormalTabsOnlyPastTheThreshold() throws {
        let (store, profile, space) = try makeStore()
        let now = Date()

        let normal = makeNormalTab(store, in: space)
        let entry = makePinnedEntry(store, in: space)
        let favorite = makeFavorite(store, profile, in: space)
        let pinnedTab = try XCTUnwrap(entry.tab)
        let favoriteTab = try XCTUnwrap(favorite.tab)
        let idle = now.addingTimeInterval(-(SleepThreshold.oneHour.rawValue + 60))
        for tab in [normal, pinnedTab, favoriteTab] { tab.lastDeselectedAt = idle }

        store.sleepStaleTabs(now: now)

        XCTAssertTrue(normal.isSleeping, "the old idle rule still sleeps ordinary tabs")
        XCTAssertFalse(pinnedTab.isSleeping, "idle alone never sleeps a pinned entry's tab")
        XCTAssertFalse(favoriteTab.isSleeping, "idle alone never sleeps a favourite's tab")
    }

    // MARK: - Blockers

    func testSelectedTabIsNeverSleptByTheBudget() throws {
        let (store, profile, space) = try makeStore()
        let now = Date()

        let normal = makeNormalTab(store, in: space)
        let entry = makePinnedEntry(store, in: space)
        let favorite = makeFavorite(store, profile, in: space)
        let tabs = [normal, try XCTUnwrap(entry.tab), try XCTUnwrap(favorite.tab)]
        for tab in tabs {
            spendBudget(tab)
            // nil = on screen in some window.
            tab.lastDeselectedAt = nil
        }

        store.sleepStaleTabs(now: now)

        for tab in tabs { XCTAssertFalse(tab.isSleeping, "a tab on screen is never slept") }
    }

    func testAudibleTabIsNeverSleptByTheBudget() throws {
        let (store, profile, space) = try makeStore()
        let now = Date()

        let normal = makeNormalTab(store, in: space)
        let entry = makePinnedEntry(store, in: space)
        let favorite = makeFavorite(store, profile, in: space)
        let tabs = [normal, try XCTUnwrap(entry.tab), try XCTUnwrap(favorite.tab)]
        for tab in tabs {
            spendBudget(tab)
            deselectedBeyondGrace(tab, now: now)
            tab.isPlayingAudio = true
        }

        store.sleepStaleTabs(now: now)

        for tab in tabs { XCTAssertFalse(tab.isSleeping, "audible tabs keep their web view") }
    }

    /// Two windows on one space share a single `lastDeselectedAt`, so the one
    /// that deselects a tab stamps it while the other may still be hosting it.
    /// A parented container means "hosted somewhere" — sleeping would blank that
    /// window's content area.
    func testTabHostedInSomeWindowIsNotSlept() throws {
        let (store, _, space) = try makeStore()
        let now = Date()

        let tab = makeNormalTab(store, in: space)
        spendBudget(tab)
        deselectedBeyondGrace(tab, now: now)
        tab.ensureWebViewContainer()
        let contentArea = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        contentArea.addSubview(try XCTUnwrap(tab.webViewContainer))

        store.sleepStaleTabs(now: now)
        XCTAssertFalse(tab.isSleeping, "a hosted tab stays awake however often it was shown")

        tab.webViewContainer?.removeFromSuperview()
        store.sleepStaleTabs(now: now)
        XCTAssertTrue(tab.isSleeping, "off screen everywhere, it sleeps")
    }

    /// The same hazard under the idle rule: the stamp alone cannot tell a tab
    /// another window still hosts from one nobody shows.
    func testIdleRuleDoesNotSleepATabHostedInSomeWindow() throws {
        let (store, _, space) = try makeStore()
        let now = Date()

        let tab = makeNormalTab(store, in: space)
        tab.lastDeselectedAt = now.addingTimeInterval(-(SleepThreshold.oneHour.rawValue + 60))
        tab.ensureWebViewContainer()
        let contentArea = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        contentArea.addSubview(try XCTUnwrap(tab.webViewContainer))

        store.sleepStaleTabs(now: now)
        XCTAssertFalse(tab.isSleeping, "a hosted tab is never slept, however long ago it was stamped")

        tab.webViewContainer?.removeFromSuperview()
        store.sleepStaleTabs(now: now)
        XCTAssertTrue(tab.isSleeping)
    }

    // MARK: - Splits

    func testSplitWithAFreshPartnerDoesNotSleep() throws {
        let (store, _, space) = try makeStore()
        let now = Date()

        let left = makeNormalTab(store, in: space)
        let right = makeNormalTab(store, in: space)
        store.createSplit(draggedTabID: left.id, targetTabID: right.id, edge: .left, in: space)
        XCTAssertNotNil(left.splitGroupID)

        spendBudget(left)
        deselectedBeyondGrace(left, now: now)
        spendBudget(right)
        right.lastDeselectedAt = now.addingTimeInterval(-60)

        store.sleepStaleTabs(now: now)

        XCTAssertFalse(left.isSleeping, "a split pane never sleeps while its partner is fresh")
        XCTAssertFalse(right.isSleeping)
    }

    func testSplitSleepsWhenBothPanesAreEligible() throws {
        let (store, _, space) = try makeStore()
        let now = Date()

        let left = makeNormalTab(store, in: space)
        let right = makeNormalTab(store, in: space)
        store.createSplit(draggedTabID: left.id, targetTabID: right.id, edge: .left, in: space)

        for tab in [left, right] {
            spendBudget(tab)
            deselectedBeyondGrace(tab, now: now)
        }

        store.sleepStaleTabs(now: now)

        XCTAssertTrue(left.isSleeping)
        XCTAssertTrue(right.isSleeping)
    }

    /// A pinned split's group lives on the entries, not on the backing tabs
    /// (split-tabs-design.md §12), so the partner rule has to resolve it there.
    func testPinnedSplitWithAFreshPartnerDoesNotSleep() throws {
        let (store, _, space) = try makeStore()
        let now = Date()

        let first = makePinnedEntry(store, in: space)
        let second = makePinnedEntry(store, in: space)
        let groupID = UUID()
        for entry in [first, second] {
            entry.splitGroupID = groupID
            entry.splitFraction = 0.5
        }
        let firstTab = try XCTUnwrap(first.tab)
        let secondTab = try XCTUnwrap(second.tab)

        spendBudget(firstTab)
        deselectedBeyondGrace(firstTab, now: now)
        spendBudget(secondTab)
        secondTab.lastDeselectedAt = now.addingTimeInterval(-60)

        store.sleepStaleTabs(now: now)

        XCTAssertFalse(firstTab.isSleeping, "a pinned split pane waits for its partner")
        XCTAssertFalse(secondTab.isSleeping)

        // Both eligible: the pair sleeps together.
        deselectedBeyondGrace(secondTab, now: now)
        store.sleepStaleTabs(now: now)

        XCTAssertTrue(firstTab.isSleeping)
        XCTAssertTrue(secondTab.isSleeping)
        XCTAssertTrue(first.isLive)
        XCTAssertTrue(second.isLive)
    }

    // MARK: - The counter itself

    func testNoteShownIncrementsAndWakeResets() throws {
        let (store, _, space) = try makeStore()
        let tab = makeNormalTab(store, in: space)

        XCTAssertEqual(tab.showsSinceWake, 0, "a fresh web view has been shown nothing yet")
        tab.noteShown()
        tab.noteShown()
        tab.noteShown()
        XCTAssertEqual(tab.showsSinceWake, 3)

        tab.sleep()
        XCTAssertTrue(tab.isSleeping)
        tab.wake()

        XCTAssertEqual(tab.showsSinceWake, 0, "a fresh web view starts a fresh budget")
    }

    // MARK: - Environment overrides

    func testEnvironmentOverridesParse() {
        XCTAssertEqual(TabStore.sleepShowBudgetSetting(environment: ["DETOUR_SLEEP_SHOW_BUDGET": "7"]), 7)
        XCTAssertEqual(
            TabStore.sleepShowBudgetGraceSetting(environment: ["DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS": "30"]),
            30)
    }

    func testUnsetOrUnusableEnvironmentFallsBackToTheDefaults() {
        XCTAssertEqual(TabStore.sleepShowBudgetSetting(environment: [:]), TabStore.defaultSleepShowBudget)
        XCTAssertEqual(TabStore.sleepShowBudgetGraceSetting(environment: [:]),
                       TabStore.defaultSleepShowBudgetGrace)
        for bad in ["", "0", "-4", "lots"] {
            XCTAssertEqual(TabStore.sleepShowBudgetSetting(environment: ["DETOUR_SLEEP_SHOW_BUDGET": bad]),
                           TabStore.defaultSleepShowBudget, "\(bad) is not a budget")
        }
        // "inf" parses as +infinity, which would push the cutoff past every
        // timestamp and silently disable the rule.
        for bad in ["", "-4", "soon", "inf", "nan"] {
            XCTAssertEqual(
                TabStore.sleepShowBudgetGraceSetting(environment: ["DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS": bad]),
                TabStore.defaultSleepShowBudgetGrace, "\(bad) is not a grace")
        }
    }
}
