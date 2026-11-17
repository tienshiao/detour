import GRDB
import XCTest
@testable import Detour

/// TASK-408: tabs hidden for 15 minutes have their back/forward cache trimmed,
/// once per hidden stretch, sparing hosted, audible and capturing tabs.
nonisolated final class BackForwardCacheTrimTests: XCTestCase {

    /// Nothing listens on port 1, so nothing here reaches the network.
    private let pageURL = URL(string: "http://127.0.0.1:1/page")!
    /// TabStore.defaultBackForwardTrimDelay (main-actor isolated, so not read here).
    private let delay: TimeInterval = 15 * 60
    private var createdTabs: [BrowserTab] = []

    @MainActor override func tearDown() async throws {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        try await super.tearDown()
    }

    private final class CapturingTab: BrowserTab {
        override var isCapturingMedia: Bool { true }
    }

    @MainActor private func makeStore() throws -> (TabStore, Profile, Space) {
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()))
        let profile = store.addProfile(name: "Trim")
        let space = store.addSpace(name: "Trim", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        return (store, profile, space)
    }

    @MainActor private func makeTab(_ store: TabStore, in space: Space, hiddenFor seconds: TimeInterval?,
                                    now: Date) -> BrowserTab {
        let tab = store.addTab(in: space)
        tab.url = pageURL
        tab.lastDeselectedAt = seconds.map { now.addingTimeInterval(-$0) }
        createdTabs.append(tab)
        return tab
    }

    @MainActor func testTheDefaultDelayIsFifteenMinutes() {
        XCTAssertEqual(TabStore.defaultBackForwardTrimDelay, delay)
    }

    @MainActor func testOnlyTabsHiddenPastTheDelayAreTrimmed() throws {
        let (store, _, space) = try makeStore()
        let now = Date()
        let old = makeTab(store, in: space, hiddenFor: delay + 1, now: now)
        let recent = makeTab(store, in: space, hiddenFor: delay - 60, now: now)
        let selected = makeTab(store, in: space, hiddenFor: nil, now: now)

        let trimmed = store.trimStaleBackForwardCaches(now: now)

        XCTAssertTrue(trimmed.contains { $0 === old })
        XCTAssertFalse(trimmed.contains { $0 === recent }, "hidden less than 15 minutes")
        XCTAssertFalse(trimmed.contains { $0 === selected }, "a selected tab has no deselection time")
        XCTAssertNotNil(old.webView, "trimming keeps the page live")
        XCTAssertFalse(old.isSleeping)
    }

    @MainActor func testATabIsTrimmedOncePerHiddenStretch() throws {
        let (store, _, space) = try makeStore()
        let now = Date()
        let tab = makeTab(store, in: space, hiddenFor: delay + 1, now: now)

        XCTAssertEqual(store.trimStaleBackForwardCaches(now: now).count, 1)
        XCTAssertTrue(store.trimStaleBackForwardCaches(now: now.addingTimeInterval(300)).isEmpty,
                      "the same stretch is not trimmed again")

        // Shown and hidden again: a new stretch, due again after the delay.
        let later = now.addingTimeInterval(3600)
        tab.lastDeselectedAt = later
        XCTAssertTrue(store.trimStaleBackForwardCaches(now: later.addingTimeInterval(delay - 1)).isEmpty)
        XCTAssertEqual(store.trimStaleBackForwardCaches(now: later.addingTimeInterval(delay)).map(\.id), [tab.id])

        // Released web view: a woken one starts its own cache, so the marker goes.
        tab.sleep(force: true)
        XCTAssertNil(tab.backForwardCacheTrimmedForDeselection)
    }

    @MainActor func testPinnedAndFavouriteBackingTabsAreTrimmedToo() throws {
        let (store, profile, space) = try makeStore()
        let now = Date()
        let pinned = makeTab(store, in: space, hiddenFor: nil, now: now)
        store.pinTab(id: pinned.id, in: space)
        let loose = BrowserTab(configuration: space.makeWebViewConfiguration())
        loose.spaceID = space.id
        loose.url = pageURL
        createdTabs.append(loose)
        store.addFavorite(from: loose, profileID: profile.id)
        let pinnedTab = try XCTUnwrap(space.pinnedEntries.first?.tab)
        let favoriteTab = try XCTUnwrap(profile.favorites.first?.tab)
        for tab in [pinnedTab, favoriteTab] { tab.lastDeselectedAt = now.addingTimeInterval(-delay - 1) }

        let trimmed = store.trimStaleBackForwardCaches(now: now)

        XCTAssertTrue(trimmed.contains { $0 === pinnedTab }, "a pinned entry's backing tab")
        XCTAssertTrue(trimmed.contains { $0 === favoriteTab }, "a favourite's backing tab")
    }

    @MainActor func testSoundCaptureAndSleepAreLeftAlone() throws {
        let (store, _, space) = try makeStore()
        let now = Date()
        let audible = makeTab(store, in: space, hiddenFor: delay + 1, now: now)
        audible.isPlayingAudio = true
        let capturing = CapturingTab(configuration: space.makeWebViewConfiguration())
        capturing.url = pageURL
        capturing.lastDeselectedAt = now.addingTimeInterval(-delay - 1)
        createdTabs.append(capturing)
        store.insertTab(capturing, in: space, parentID: nil)
        let asleep = makeTab(store, in: space, hiddenFor: delay + 1, now: now)
        asleep.sleep(force: true)

        let trimmed = store.trimStaleBackForwardCaches(now: now)

        XCTAssertFalse(trimmed.contains { $0 === audible }, "a tab playing sound")
        XCTAssertFalse(trimmed.contains { $0 === capturing }, "a tab on a call")
        XCTAssertFalse(trimmed.contains { $0 === asleep }, "no web view, nothing to trim")
        XCTAssertNil(audible.backForwardCacheTrimmedForDeselection, "it is tried again once the sound stops")
    }

    @MainActor func testAHostedTabIsLeftAlone() throws {
        let (store, _, space) = try makeStore()
        let now = Date()
        let tab = makeTab(store, in: space, hiddenFor: delay + 1, now: now)
        // Another window still shows it: two windows on one space share one
        // lastDeselectedAt, so a hosted container is what counts.
        let contentArea = NSView()
        tab.ensureWebViewContainer()
        contentArea.addSubview(try XCTUnwrap(tab.webViewContainer))
        defer { tab.webViewContainer?.removeFromSuperview() }

        XCTAssertTrue(store.trimStaleBackForwardCaches(now: now).isEmpty)
    }

    @MainActor func testDelaySettingReadsTheEnvironment() {
        XCTAssertEqual(TabStore.backForwardTrimDelaySetting(environment: [:]), 15 * 60)
        XCTAssertEqual(TabStore.backForwardTrimDelaySetting(environment: ["DETOUR_BACK_FORWARD_TRIM_SECONDS": "10"]), 10)
        XCTAssertEqual(TabStore.backForwardTrimDelaySetting(environment: ["DETOUR_BACK_FORWARD_TRIM_SECONDS": "-1"]), 15 * 60)
        XCTAssertEqual(TabStore.backForwardTrimDelaySetting(environment: ["DETOUR_BACK_FORWARD_TRIM_SECONDS": "x"]), 15 * 60)
    }
}
