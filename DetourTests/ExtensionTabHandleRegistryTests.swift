import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-132.2: the native half of the tab id bridge — handles, resolve arms,
/// placement and the validated lookup — without WebKit in the loop. The round
/// trip through a real extension context is `ExtensionTabResolveTests`.
@MainActor
final class ExtensionTabHandleRegistryTests: XCTestCase {

    private var createdTabs: [BrowserTab] = []

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    private final class Box {}

    private struct Fixture {
        let store: TabStore
        let profile: Profile
        let space: Space
    }

    /// A private store on an in-memory database: one profile, one space. The
    /// tabs placed in it are sleeping ones (no web view), so no extension
    /// controller is ever built and nothing is announced to WebKit.
    private func makeFixture() throws -> Fixture {
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()))
        let profile = store.addProfile(name: "Handles")
        let space = store.addSpace(name: "Handles", emoji: "H", colorHex: "007AFF", profileID: profile.id)
        return Fixture(store: store, profile: profile, space: space)
    }

    private func sleepingTab(in space: Space, path: String = "page") -> BrowserTab {
        BrowserTab(id: UUID(), title: path, url: URL(string: "https://example.com/\(path)"),
                   faviconURL: nil, cachedInteractionState: nil, spaceID: space.id)
    }

    /// A tab with a web view built from a bare configuration: no extension
    /// controller, so the placement rule reports it to nobody.
    private func liveTab() -> BrowserTab {
        let tab = BrowserTab(configuration: WKWebViewConfiguration())
        createdTabs.append(tab)
        return tab
    }

    // MARK: - WeakHandleTable

    func testHandlesArePositiveUniqueAndStable() {
        var table = WeakHandleTable<Box>()
        let a = Box(), b = Box()

        let handleA = table.handle(for: a)
        let handleB = table.handle(for: b)

        XCTAssertGreaterThan(handleA, 0)
        XCTAssertGreaterThan(handleB, 0)
        XCTAssertNotEqual(handleA, handleB)
        XCTAssertEqual(table.handle(for: a), handleA, "a handle is stable for its object's lifetime")
        XCTAssertEqual(table.handle(for: b), handleB)
        XCTAssertTrue(table.object(forHandle: handleA) === a)
        XCTAssertTrue(table.object(forHandle: handleB) === b)
    }

    func testAnUnmintedHandleResolvesToNothing() {
        var table = WeakHandleTable<Box>()
        let a = Box()
        let handle = table.handle(for: a)

        XCTAssertNil(table.object(forHandle: handle + 1))
        XCTAssertNil(table.object(forHandle: 0))
        XCTAssertNil(table.object(forHandle: -handle))
    }

    func testAHandleDiesWithItsObjectAndIsNeverReused() {
        var table = WeakHandleTable<Box>()
        var doomed: Box? = Box()
        let dead = table.handle(for: doomed!)
        doomed = nil

        XCTAssertNil(table.object(forHandle: dead), "the table must not keep its objects alive")

        // New objects — some of which are likely to reuse the freed address —
        // must each get a handle of their own.
        var survivors: [Box] = []
        var seen = Set<Int>()
        for _ in 0..<200 {
            let box = Box()
            survivors.append(box)
            let handle = table.handle(for: box)
            XCTAssertNotEqual(handle, dead, "a dead object's handle must never name another object")
            XCTAssertTrue(seen.insert(handle).inserted, "handles must be unique")
        }
        XCTAssertNil(table.object(forHandle: dead))
        for box in survivors {
            XCTAssertTrue(table.object(forHandle: table.handle(for: box)) === box)
        }
    }

    func testDeadEntriesAreSweptAsTheTableGrows() {
        var table = WeakHandleTable<Box>()
        for _ in 0..<500 {
            _ = table.handle(for: Box())   // released at once
        }
        XCTAssertLessThan(table.recordedCount, 200,
                          "handles of dead objects must not accumulate without bound")
    }

    // MARK: - ExtensionTabResolveArms

    func testArmsAreACounterPerKey() {
        var arms = ExtensionTabResolveArms<String>(lifetime: 5, limit: 8)
        XCTAssertTrue(arms.isEmpty)
        XCTAssertFalse(arms.consume("a", now: 0), "nothing armed: an ordinary getZoom")

        XCTAssertTrue(arms.arm("a", now: 0))
        XCTAssertTrue(arms.arm("a", now: 0))
        XCTAssertFalse(arms.isEmpty)
        XCTAssertEqual(arms.count("a", now: 0), 2)
        XCTAssertEqual(arms.count("b", now: 0), 0)
        XCTAssertFalse(arms.consume("b", now: 0), "another context's arms are not this one's")

        XCTAssertTrue(arms.consume("a", now: 1))
        XCTAssertTrue(arms.consume("a", now: 1))
        XCTAssertFalse(arms.consume("a", now: 1), "each arm answers exactly one getZoom")
        XCTAssertTrue(arms.isEmpty)
    }

    func testAnArmExpires() {
        var arms = ExtensionTabResolveArms<String>(lifetime: 5, limit: 8)
        XCTAssertTrue(arms.arm("a", now: 10))
        XCTAssertEqual(arms.count("a", now: 14.9), 1)
        XCTAssertEqual(arms.count("a", now: 15), 0)
        XCTAssertFalse(arms.consume("a", now: 15), "a stale arm must not turn a later getZoom into a handle")
        XCTAssertTrue(arms.isEmpty, "the expired arm is dropped, not kept")
    }

    func testArmsExpireIndependently() {
        var arms = ExtensionTabResolveArms<String>(lifetime: 5, limit: 8)
        XCTAssertTrue(arms.arm("a", now: 0))
        XCTAssertTrue(arms.arm("a", now: 3))
        XCTAssertEqual(arms.count("a", now: 6), 1)
        XCTAssertTrue(arms.consume("a", now: 6))
        XCTAssertFalse(arms.consume("a", now: 6))
    }

    func testExpiredArmsOfAContextThatWentAwayAreDropped() {
        var arms = ExtensionTabResolveArms<String>(lifetime: 5, limit: 8)
        XCTAssertTrue(arms.arm("gone", now: 0))
        // "gone" never consumes, disarms or arms again. Another context does.
        XCTAssertTrue(arms.arm("alive", now: 10))
        XCTAssertTrue(arms.consume("alive", now: 10))
        XCTAssertTrue(arms.isEmpty,
                      "the fast path of every ordinary getZoom must come back once nothing is armed")

        // A live arm of another key is left alone.
        XCTAssertTrue(arms.arm("first", now: 20))
        XCTAssertTrue(arms.arm("second", now: 21))
        XCTAssertEqual(arms.count("first", now: 21), 1)
    }

    func testDisarmTakesBackOneArmIfStillThere() {
        var arms = ExtensionTabResolveArms<String>(lifetime: 5, limit: 8)
        XCTAssertFalse(arms.disarm("a", now: 0))
        XCTAssertTrue(arms.arm("a", now: 0))
        XCTAssertTrue(arms.arm("a", now: 0))
        XCTAssertTrue(arms.disarm("a", now: 1))
        XCTAssertEqual(arms.count("a", now: 1), 1)
        XCTAssertTrue(arms.disarm("a", now: 1))
        XCTAssertFalse(arms.disarm("a", now: 1))
        XCTAssertTrue(arms.isEmpty)
    }

    func testArmsAreCappedPerKey() {
        var arms = ExtensionTabResolveArms<String>(lifetime: 5, limit: 3)
        XCTAssertTrue(arms.arm("a", now: 0))
        XCTAssertTrue(arms.arm("a", now: 0))
        XCTAssertTrue(arms.arm("a", now: 0))
        XCTAssertFalse(arms.arm("a", now: 0), "a context that arms in a loop is refused past the cap")
        XCTAssertTrue(arms.arm("b", now: 0), "the cap is per key")
        XCTAssertTrue(arms.arm("a", now: 6), "expired arms free their slots")
    }

    // MARK: - Registry arms

    func testConsumeArmAnswersWithTheAskedTabsHandleOnlyWhileArmed() throws {
        let f = try makeFixture()
        var now: TimeInterval = 100
        let registry = ExtensionTabHandleRegistry(armLifetime: 5, armLimit: 4, clock: { now })
        let key = ExtensionTabHandleRegistry.ContextKey(profileID: f.profile.id, extensionID: "ext")
        let other = ExtensionTabHandleRegistry.ContextKey(profileID: f.profile.id, extensionID: "other")
        let first = sleepingTab(in: f.space, path: "first")
        let second = sleepingTab(in: f.space, path: "second")

        XCTAssertNil(registry.consumeArm(key, answeringFor: first), "not armed: the tab reports its zoom")

        XCTAssertTrue(registry.arm(key))
        XCTAssertNil(registry.consumeArm(other, answeringFor: first),
                     "an arm belongs to the extension context that set it")
        XCTAssertEqual(registry.armCount(key), 1)

        // Two contexts of one extension resolving at once: whichever getZoom
        // consumes an arm is answered by the tab it asked about.
        XCTAssertTrue(registry.arm(key))
        let handleSecond = try XCTUnwrap(registry.consumeArm(key, answeringFor: second))
        let handleFirst = try XCTUnwrap(registry.consumeArm(key, answeringFor: first))
        XCTAssertEqual(handleSecond, registry.handle(for: second))
        XCTAssertEqual(handleFirst, registry.handle(for: first))
        XCTAssertNotEqual(handleFirst, handleSecond)
        XCTAssertNil(registry.consumeArm(key, answeringFor: first), "both arms are spent")

        XCTAssertTrue(registry.arm(key))
        now += 5
        XCTAssertNil(registry.consumeArm(key, answeringFor: first), "an arm expires after its lifetime")

        XCTAssertTrue(registry.arm(key))
        XCTAssertTrue(registry.disarm(key))
        XCTAssertFalse(registry.disarm(key))
        XCTAssertNil(registry.consumeArm(key, answeringFor: first))
    }

    // MARK: - Placement

    func testPlacementOfEachSection() throws {
        let f = try makeFixture()

        let normal = sleepingTab(in: f.space, path: "normal")
        f.space.tabs.append(normal)

        let pinned = sleepingTab(in: f.space, path: "pinned")
        let entry = PinnedEntry(pinnedURL: try XCTUnwrap(pinned.url), pinnedTitle: "Pinned")
        entry.tab = pinned
        f.space.pinnedEntries.append(entry)

        let favorite = sleepingTab(in: f.space, path: "favorite")
        f.store.addFavorite(from: favorite, profileID: f.profile.id)

        let peek = liveTab()
        normal.peekTab = peek
        let favoritePeek = liveTab()
        favorite.peekTab = favoritePeek

        XCTAssertEqual(extensionTabPlacement(of: normal, in: f.store),
                       ExtensionTabPlacement(kind: .normal, profileID: f.profile.id, spaceID: f.space.id))
        XCTAssertEqual(extensionTabPlacement(of: pinned, in: f.store),
                       ExtensionTabPlacement(kind: .pinned, profileID: f.profile.id, spaceID: f.space.id))
        XCTAssertEqual(extensionTabPlacement(of: favorite, in: f.store),
                       ExtensionTabPlacement(kind: .favorite, profileID: f.profile.id, spaceID: nil))
        XCTAssertEqual(extensionTabPlacement(of: peek, in: f.store),
                       ExtensionTabPlacement(kind: .peek, profileID: f.profile.id, spaceID: f.space.id))
        XCTAssertEqual(extensionTabPlacement(of: favoritePeek, in: f.store),
                       ExtensionTabPlacement(kind: .peek, profileID: f.profile.id, spaceID: nil),
                       "a favourite's Peek is listed by the profile's windows, in no one space")
    }

    func testATabInNoContainerHasNoPlacement() throws {
        let f = try makeFixture()
        let loose = sleepingTab(in: f.space)
        XCTAssertNil(extensionTabPlacement(of: loose, in: f.store),
                     "a spaceID alone is not a placement: no window lists the tab")

        // A parked Peek has no web view; the window enumeration leaves it out.
        let host = sleepingTab(in: f.space, path: "host")
        f.space.tabs.append(host)
        let parked = sleepingTab(in: f.space, path: "parked")
        host.peekTab = parked
        XCTAssertNil(extensionTabPlacement(of: parked, in: f.store))

        // A live Peek whose host is itself unplaced is not listed either.
        let orphanHost = sleepingTab(in: f.space, path: "orphan")
        let orphanPeek = liveTab()
        orphanHost.peekTab = orphanPeek
        XCTAssertNil(extensionTabPlacement(of: orphanPeek, in: f.store))
    }

    // MARK: - Lookup

    private func resolved(_ registry: ExtensionTabHandleRegistry, _ handle: Int, in profile: Profile,
                          store: TabStore) -> BrowserTab? {
        guard case .success(let found) = registry.tab(forHandle: handle, in: profile, store: store) else { return nil }
        return found.tab
    }

    private func refusal(_ registry: ExtensionTabHandleRegistry, _ handle: Int, in profile: Profile,
                         store: TabStore) -> ExtensionTabHandleError? {
        guard case .failure(let error) = registry.tab(forHandle: handle, in: profile, store: store) else { return nil }
        return error
    }

    func testLookupReturnsTheTabAndItsPlacementForEverySection() throws {
        let f = try makeFixture()
        let registry = ExtensionTabHandleRegistry()

        let normal = sleepingTab(in: f.space, path: "normal")
        f.space.tabs.append(normal)
        let pinned = sleepingTab(in: f.space, path: "pinned")
        f.space.tabs.append(pinned)
        f.store.pinTab(id: pinned.id, in: f.space)
        let favorite = sleepingTab(in: f.space, path: "favorite")
        f.store.addFavorite(from: favorite, profileID: f.profile.id)
        let peek = liveTab()
        normal.peekTab = peek

        let expected: [(BrowserTab, ExtensionTabPlacement.Kind)] =
            [(normal, .normal), (pinned, .pinned), (favorite, .favorite), (peek, .peek)]
        for (tab, kind) in expected {
            let handle = registry.handle(for: tab)
            switch registry.tab(forHandle: handle, in: f.profile, store: f.store) {
            case .success(let found):
                XCTAssertTrue(found.tab === tab, "\(kind) handle resolved to another tab")
                XCTAssertEqual(found.placement.kind, kind)
            case .failure(let error):
                XCTFail("\(kind) tab was refused: \(error)")
            }
        }
    }

    func testLookupRefusesBadHandles() throws {
        let f = try makeFixture()
        let registry = ExtensionTabHandleRegistry()
        let tab = sleepingTab(in: f.space)
        f.space.tabs.append(tab)
        let handle = registry.handle(for: tab)

        XCTAssertEqual(refusal(registry, 0, in: f.profile, store: f.store), .invalidHandle)
        XCTAssertEqual(refusal(registry, -handle, in: f.profile, store: f.store), .invalidHandle)
        XCTAssertEqual(refusal(registry, handle + 1000, in: f.profile, store: f.store), .unknownHandle)
        XCTAssertTrue(resolved(registry, handle, in: f.profile, store: f.store) === tab)
    }

    func testLookupRefusesAClosedTab() throws {
        let f = try makeFixture()
        let registry = ExtensionTabHandleRegistry()
        let kept = sleepingTab(in: f.space, path: "kept")
        f.space.tabs.append(kept)
        let keptHandle = registry.handle(for: kept)
        var doomedHandle = 0
        weak var weakDoomed: BrowserTab?
        autoreleasepool {
            let doomed = sleepingTab(in: f.space, path: "doomed")
            weakDoomed = doomed
            f.space.tabs.append(doomed)
            doomedHandle = registry.handle(for: doomed)
            XCTAssertTrue(resolved(registry, doomedHandle, in: f.profile, store: f.store) === doomed)

            // Out of every container but still alive (an undo closure, a
            // closing animation): refused for not being placed.
            f.space.tabs.removeAll { $0 === doomed }
            XCTAssertEqual(refusal(registry, doomedHandle, in: f.profile, store: f.store), .notPlaced)
        }

        // And once it is gone altogether.
        XCTAssertNil(weakDoomed, "precondition: nothing keeps the closed tab alive")
        XCTAssertEqual(refusal(registry, doomedHandle, in: f.profile, store: f.store), .unknownHandle)

        // A tab opened afterwards is a different tab with a different handle.
        let later = sleepingTab(in: f.space, path: "later")
        f.space.tabs.append(later)
        XCTAssertNotEqual(registry.handle(for: later), doomedHandle)
        XCTAssertEqual(refusal(registry, doomedHandle, in: f.profile, store: f.store), .unknownHandle,
                       "a closed tab's handle must never come to mean another tab")
        XCTAssertTrue(resolved(registry, keptHandle, in: f.profile, store: f.store) === kept)
    }

    func testLookupRefusesATabOfAnotherProfile() throws {
        let f = try makeFixture()
        let registry = ExtensionTabHandleRegistry()
        let otherProfile = f.store.addProfile(name: "Other")
        let otherSpace = f.store.addSpace(name: "Other", emoji: "O", colorHex: "34C759",
                                          profileID: otherProfile.id)

        let mine = sleepingTab(in: f.space, path: "mine")
        f.space.tabs.append(mine)
        let theirs = sleepingTab(in: otherSpace, path: "theirs")
        otherSpace.tabs.append(theirs)
        let theirFavorite = sleepingTab(in: otherSpace, path: "their-favorite")
        f.store.addFavorite(from: theirFavorite, profileID: otherProfile.id)

        XCTAssertEqual(refusal(registry, registry.handle(for: theirs), in: f.profile, store: f.store),
                       .otherProfile)
        XCTAssertEqual(refusal(registry, registry.handle(for: theirFavorite), in: f.profile, store: f.store),
                       .otherProfile)
        XCTAssertEqual(refusal(registry, registry.handle(for: mine), in: otherProfile, store: f.store),
                       .otherProfile)
        XCTAssertTrue(resolved(registry, registry.handle(for: theirs), in: otherProfile, store: f.store) === theirs)
        XCTAssertTrue(resolved(registry, registry.handle(for: mine), in: f.profile, store: f.store) === mine)
    }

    func testAHandleFollowsItsTabThroughReorderPinAndSpaceMoves() throws {
        let f = try makeFixture()
        let registry = ExtensionTabHandleRegistry()
        let second = f.store.addSpace(name: "Second", emoji: "S", colorHex: "FF9500", profileID: f.profile.id)

        let tabs = (0..<3).map { sleepingTab(in: f.space, path: "tab-\($0)") }
        for tab in tabs { f.space.tabs.append(tab) }
        let handles = tabs.map { registry.handle(for: $0) }

        func assertAllResolve(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            for (tab, handle) in zip(tabs, handles) {
                XCTAssertEqual(registry.handle(for: tab), handle, "\(step): handle changed", file: file, line: line)
                XCTAssertTrue(resolved(registry, handle, in: f.profile, store: f.store) === tab,
                              "\(step): handle no longer names its tab", file: file, line: line)
            }
        }

        f.store.moveTab(from: 0, to: 2, in: f.space)
        XCTAssertNotEqual(f.space.tabs.map(\.id), tabs.map(\.id), "precondition: the order changed")
        assertAllResolve("after a reorder")

        XCTAssertTrue(f.store.moveTab(id: tabs[1].id, from: f.space, to: second))
        XCTAssertTrue(second.tabs.contains { $0 === tabs[1] }, "precondition: the tab moved")
        assertAllResolve("after a move to another space")
        guard case .success(let moved) = registry.tab(forHandle: handles[1], in: f.profile, store: f.store) else {
            return XCTFail("the moved tab was refused")
        }
        XCTAssertEqual(moved.placement.spaceID, second.id, "placement is read at lookup time")

        f.store.pinTab(id: tabs[2].id, in: f.space)
        assertAllResolve("after a pin")
        guard case .success(let pinned) = registry.tab(forHandle: handles[2], in: f.profile, store: f.store) else {
            return XCTFail("the pinned tab was refused")
        }
        XCTAssertEqual(pinned.placement.kind, .pinned)
    }

    // MARK: - Zoom answer

    func testASleepingTabReportsZoomOneAndIsNotWoken() throws {
        let f = try makeFixture()
        let tab = sleepingTab(in: f.space)
        f.space.tabs.append(tab)

        XCTAssertEqual(tab.extensionZoomFactor(for: nil), 1)
        XCTAssertNil(tab.webView, "answering a zoom question must not build a web view")
        XCTAssertTrue(tab.isSleeping)
    }

    func testALiveTabReportsItsPageZoomToItsOwnController() throws {
        let tab = liveTab()
        let webView = try XCTUnwrap(tab.webView)
        webView.pageZoom = 1.5

        // The bare configuration carries no extension controller, which is the
        // controller this web view "belongs to" for the comparison.
        XCTAssertEqual(tab.extensionZoomFactor(for: nil), 1.5, accuracy: 0.0001)

        // A controller the web view was not built for is told nothing about it.
        let foreign = WKWebExtensionController(configuration: .nonPersistent())
        XCTAssertEqual(tab.extensionZoomFactor(for: foreign), 1)
    }
}
