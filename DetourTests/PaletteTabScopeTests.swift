import XCTest
import GRDB
@testable import Detour

/// TASK-137: which spaces' open tabs a command palette may offer.
///
/// A normal window's palette used to be handed the tabs of every space in the
/// store, the spaces of open Private windows included, so a Private tab's URL,
/// title and favicon could show up as a "Switch to Tab" row or as the top hit
/// in another window.
final class PaletteTabScopeTests: XCTestCase {

    private typealias SpaceRef = PaletteTabScope.SpaceRef

    private let normalA = SpaceRef(id: UUID(), isIncognito: false)
    private let normalB = SpaceRef(id: UUID(), isIncognito: false)
    private let privateA = SpaceRef(id: UUID(), isIncognito: true)
    private let privateB = SpaceRef(id: UUID(), isIncognito: true)

    // MARK: - A normal window

    func testNormalWindowIsNotOfferedAnOpenPrivateWindowsSpace() {
        let offered = PaletteTabScope.offeredSpaceIDs(
            spaces: [normalA, privateA, normalB],
            windowIsPrivate: false, activeSpaceID: normalA.id)

        XCTAssertEqual(offered, [normalA.id, normalB.id],
                       "every normal space, whichever one is active, and no Private one")
    }

    func testNormalWindowIsOfferedNoneOfSeveralPrivateWindowsSpaces() {
        let offered = PaletteTabScope.offeredSpaceIDs(
            spaces: [privateA, normalA, privateB],
            windowIsPrivate: false, activeSpaceID: normalA.id)

        XCTAssertEqual(offered, [normalA.id])
    }

    func testNormalWindowWithoutAnActiveSpaceIsStillOfferedNoPrivateSpace() {
        let offered = PaletteTabScope.offeredSpaceIDs(
            spaces: [normalA, privateA],
            windowIsPrivate: false, activeSpaceID: nil)

        XCTAssertEqual(offered, [normalA.id])
    }

    // MARK: - A Private window

    func testPrivateWindowIsOfferedOnlyItsOwnSpace() {
        let offered = PaletteTabScope.offeredSpaceIDs(
            spaces: [normalA, normalB, privateA],
            windowIsPrivate: true, activeSpaceID: privateA.id)

        XCTAssertEqual(offered, [privateA.id], "no normal space")
    }

    func testPrivateWindowIsNotOfferedAnotherPrivateWindowsSpace() {
        let offered = PaletteTabScope.offeredSpaceIDs(
            spaces: [normalA, privateA, privateB],
            windowIsPrivate: true, activeSpaceID: privateB.id)

        XCTAssertEqual(offered, [privateB.id])
    }

    func testPrivateWindowWithoutAnActiveSpaceIsOfferedNothing() {
        let offered = PaletteTabScope.offeredSpaceIDs(
            spaces: [normalA, privateA],
            windowIsPrivate: true, activeSpaceID: nil)

        XCTAssertEqual(offered, [])
    }

    // MARK: - Failing closed

    /// The window's Private flag reaches the palette through its profile, which
    /// is optional. A palette whose active space is incognito is a Private
    /// window's palette whatever the flag says.
    func testAWindowShowingAnIncognitoSpaceIsTreatedAsPrivateEvenWhenNotFlagged() {
        let offered = PaletteTabScope.offeredSpaceIDs(
            spaces: [normalA, normalB, privateA, privateB],
            windowIsPrivate: false, activeSpaceID: privateA.id)

        XCTAssertEqual(offered, [privateA.id])
    }

    func testAnActiveSpaceTheStoreNoLongerHasOffersNothingToAPrivateWindow() {
        let offered = PaletteTabScope.offeredSpaceIDs(
            spaces: [normalA, privateA],
            windowIsPrivate: true, activeSpaceID: UUID())

        XCTAssertEqual(offered, [])
    }
}

/// The same rule through the view: what `CommandPaletteView.gatherTabInfos`
/// hands the suggestion pipeline from a real store that has a normal space and
/// a Private window's space open at once.
@MainActor
final class PaletteTabScopeWiringTests: XCTestCase {

    private var createdTabs: [BrowserTab] = []

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        super.tearDown()
    }

    /// Nothing listens on port 1, so a load navigates nowhere real.
    private let normalURL = URL(string: "http://127.0.0.1:1/normal")!
    private let privateURL = URL(string: "http://127.0.0.1:1/private")!

    private struct Fixture {
        let store: TabStore
        let normalSpace: Space
        let privateSpace: Space
        let normalTab: BrowserTab
        let privateTab: BrowserTab
    }

    private func makeFixture() throws -> Fixture {
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()),
                             historyDB: try HistoryDatabase(dbQueue: try DatabaseQueue()))
        let profile = store.addProfile(name: "Palette Scope")
        let normalSpace = store.addSpace(name: "Normal", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        let privateSpace = store.addIncognitoSpace()
        XCTAssertTrue(privateSpace.isIncognito)
        XCTAssertFalse(normalSpace.isIncognito)
        let normalTab = store.addTab(in: normalSpace, url: normalURL)
        let privateTab = store.addTab(in: privateSpace, url: privateURL)
        createdTabs.append(contentsOf: [normalTab, privateTab])
        store.undoManager.removeAllActions()
        return Fixture(store: store, normalSpace: normalSpace, privateSpace: privateSpace,
                       normalTab: normalTab, privateTab: privateTab)
    }

    private func makePalette(_ store: TabStore, showing space: Space) -> CommandPaletteView {
        // Configured the way `BrowserWindowController.showCommandPalette` does.
        let palette = CommandPaletteView()
        palette.tabStore = store
        palette.activeSpaceID = space.id
        palette.profile = space.profile
        return palette
    }

    func testNormalWindowPaletteIsNotHandedAPrivateWindowsTabs() throws {
        let fixture = try makeFixture()
        let palette = makePalette(fixture.store, showing: fixture.normalSpace)

        let tabs = palette.gatherTabInfos()

        XCTAssertEqual(tabs.map(\.tabID), [fixture.normalTab.id])
        XCTAssertFalse(tabs.contains { $0.spaceID == fixture.privateSpace.id })
        XCTAssertFalse(tabs.contains { $0.url == privateURL.absoluteString })
    }

    func testPrivateWindowPaletteIsHandedOnlyItsOwnSpacesTabs() throws {
        let fixture = try makeFixture()
        let otherPrivateSpace = fixture.store.addIncognitoSpace()
        let otherPrivateTab = fixture.store.addTab(in: otherPrivateSpace, url: privateURL)
        createdTabs.append(otherPrivateTab)
        let palette = makePalette(fixture.store, showing: fixture.privateSpace)

        let tabs = palette.gatherTabInfos()

        XCTAssertEqual(tabs.map(\.tabID), [fixture.privateTab.id])
    }
}
