import XCTest
import GRDB
@testable import Detour

/// Which spaces' open tabs a command palette may offer.
///
/// TASK-137: a normal window's palette used to be handed the tabs of every
/// space in the store, the spaces of open Private windows included, so a
/// Private tab's URL, title and favicon could show up as a "Switch to Tab" row
/// or as the top hit in another window.
///
/// TASK-209: it was still handed every other *profile's* spaces, so Switch to
/// Tab could jump into another profile. A palette offers its own profile's
/// spaces only.
final class PaletteTabScopeTests: XCTestCase {

    private typealias SpaceRef = PaletteTabScope.SpaceRef

    private let work = UUID()
    private let home = UUID()
    private let privateProfile = TabStore.incognitoProfileID

    private lazy var normalA = SpaceRef(id: UUID(), isIncognito: false, profileID: work)
    private lazy var normalB = SpaceRef(id: UUID(), isIncognito: false, profileID: work)
    private lazy var homeA = SpaceRef(id: UUID(), isIncognito: false, profileID: home)
    private lazy var homeB = SpaceRef(id: UUID(), isIncognito: false, profileID: home)
    private lazy var privateA = SpaceRef(id: UUID(), isIncognito: true, profileID: privateProfile)
    private lazy var privateB = SpaceRef(id: UUID(), isIncognito: true, profileID: privateProfile)

    // MARK: - A normal window

    func testNormalWindowIsNotOfferedAnOpenPrivateWindowsSpace() {
        let offered = PaletteTabScope.offeredSpaceIDs(
            spaces: [normalA, privateA, normalB],
            windowIsPrivate: false, activeSpaceID: normalA.id)

        XCTAssertEqual(offered, [normalA.id, normalB.id],
                       "every space of the profile, whichever one is active, and no Private one")
    }

    func testNormalWindowIsOfferedNoneOfSeveralPrivateWindowsSpaces() {
        let offered = PaletteTabScope.offeredSpaceIDs(
            spaces: [privateA, normalA, privateB],
            windowIsPrivate: false, activeSpaceID: normalA.id)

        XCTAssertEqual(offered, [normalA.id])
    }

    /// TASK-209: Switch to Tab must not jump into another profile.
    func testNormalWindowIsOfferedOnlyItsOwnProfilesSpaces() {
        let spaces = [normalA, homeA, normalB, homeB, privateA]

        XCTAssertEqual(PaletteTabScope.offeredSpaceIDs(spaces: spaces, windowIsPrivate: false,
                                                       activeSpaceID: normalB.id),
                       [normalA.id, normalB.id], "no home space in a work window")
        XCTAssertEqual(PaletteTabScope.offeredSpaceIDs(spaces: spaces, windowIsPrivate: false,
                                                       activeSpaceID: homeA.id),
                       [homeA.id, homeB.id], "and no work space in a home window")
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

        XCTAssertEqual(offered, [privateB.id], "the same Private profile, but another window's session")
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

    /// TASK-209: with no active space there is no profile to scope to, and
    /// every normal space (TASK-137's answer) would include other profiles'.
    func testNormalWindowWithoutAnActiveSpaceIsOfferedNothing() {
        XCTAssertEqual(PaletteTabScope.offeredSpaceIDs(spaces: [normalA, homeA, privateA],
                                                       windowIsPrivate: false, activeSpaceID: nil), [])
        XCTAssertEqual(PaletteTabScope.offeredSpaceIDs(spaces: [normalA, homeA, privateA],
                                                       windowIsPrivate: false, activeSpaceID: UUID()), [],
                       "nor with an active space the store no longer has")
    }
}

/// TASK-209: the history a palette suggests from is its profile's, the History
/// page's scope (`HistoryPageBridge.scope(forProfile:)`): every space of the
/// profile and its Quick Detour visits. Never another profile's, and nothing
/// for a Private window or a quarantine.
@MainActor
final class PaletteHistoryScopeTests: XCTestCase {

    private func makeStore() throws -> TabStore {
        TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()),
                 historyDB: try HistoryDatabase(dbQueue: try DatabaseQueue()))
    }

    func testThePalettesHistoryIsItsProfilesSpacesAndQuickDetourScope() throws {
        let store = try makeStore()
        let work = store.addProfile(name: "Work")
        let home = store.addProfile(name: "Home")
        let inbox = store.addSpace(name: "Inbox", emoji: "I", colorHex: "007AFF", profileID: work.id)
        let build = store.addSpace(name: "Build", emoji: "B", colorHex: "007AFF", profileID: work.id)
        let family = store.addSpace(name: "Family", emoji: "F", colorHex: "007AFF", profileID: home.id)

        let workScope = PaletteTabScope.historySpaceIDs(profile: work, in: store)
        XCTAssertEqual(Set(workScope), [inbox.id.uuidString, build.id.uuidString,
                                        QuickDetour.historySpaceIDString(forProfileID: work.id)])
        XCTAssertEqual(workScope, HistoryPageBridge.scope(forProfile: work, in: store),
                       "the History page's scope, so the two never disagree")
        XCTAssertFalse(workScope.contains(family.id.uuidString))

        let homeScope = PaletteTabScope.historySpaceIDs(profile: home, in: store)
        XCTAssertEqual(Set(homeScope), [family.id.uuidString,
                                        QuickDetour.historySpaceIDString(forProfileID: home.id)])
    }

    func testAPrivateWindowsPaletteHasNoHistory() throws {
        let store = try makeStore()
        let privateSpace = store.addIncognitoSpace()
        let privateProfile = try XCTUnwrap(privateSpace.profile)
        XCTAssertTrue(privateProfile.isIncognito)

        XCTAssertEqual(PaletteTabScope.historySpaceIDs(profile: privateProfile, in: store), [],
                       "a Private window (and a quarantine, which runs on the Private profile) records nothing "
                       + "and reads no profile's history")
    }

    func testNoProfileOrADeletedOneHasNoHistory() throws {
        let store = try makeStore()
        let gone = store.addProfile(name: "Gone")
        _ = store.addSpace(name: "Gone", emoji: "G", colorHex: "007AFF", profileID: gone.id)
        gone.isDeleted = true

        XCTAssertEqual(PaletteTabScope.historySpaceIDs(profile: nil, in: store), [])
        XCTAssertEqual(PaletteTabScope.historySpaceIDs(profile: gone, in: store), [])
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

    /// TASK-209: another profile's tab at the same URL is not offered, so
    /// Switch to Tab cannot jump into that profile.
    func testNormalWindowPaletteIsNotHandedAnotherProfilesTabs() throws {
        let fixture = try makeFixture()
        let other = fixture.store.addProfile(name: "Other Profile")
        let otherSpace = fixture.store.addSpace(name: "Other", emoji: "🅾️", colorHex: "007AFF",
                                                profileID: other.id)
        let otherTab = fixture.store.addTab(in: otherSpace, url: normalURL)
        createdTabs.append(otherTab)
        let sibling = fixture.store.addSpace(name: "Sibling", emoji: "🅱️", colorHex: "007AFF",
                                             profileID: try XCTUnwrap(fixture.normalSpace.profile).id)
        let siblingTab = fixture.store.addTab(in: sibling, url: privateURL)
        createdTabs.append(siblingTab)

        let tabs = makePalette(fixture.store, showing: fixture.normalSpace).gatherTabInfos()
        XCTAssertEqual(Set(tabs.map(\.tabID)), [fixture.normalTab.id, siblingTab.id],
                       "the profile's other space is offered, another profile's is not")

        let otherTabs = makePalette(fixture.store, showing: otherSpace).gatherTabInfos()
        XCTAssertEqual(otherTabs.map(\.tabID), [otherTab.id])
    }
}

/// TASK-209 through every browser-window entry point: Cmd+T, Cmd+L (the faux
/// address bar, the sidebar's New Tab row and the empty state call the same
/// `showCommandPalette`) configure the palette with the window's profile's
/// history and open tabs, never another profile's.
///
/// The shared store and real windows, with profiles and spaces of the test's
/// own (`QuickDetourOpenInWindowTests`' fixture).
@MainActor
final class PaletteEntryPointScopeTests: XCTestCase {

    private var store: TabStore { .shared }
    private var appDelegate: AppDelegate!
    private var windowsBefore: Set<ObjectIdentifier> = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var previousLastActiveSpaceID: UUID?
    private static var retainedProfiles: [Profile] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        windowsBefore = Set(browserWindows().map(ObjectIdentifier.init))
        previousLastActiveSpaceID = store.lastActiveSpaceID
    }

    override func tearDown() async throws {
        for wc in browserWindows() where !windowsBefore.contains(ObjectIdentifier(wc)) {
            wc.dismissCommandPalette()
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        for id in createdSpaceIDs {
            if let space = store.space(withID: id) {
                for tab in space.tabs { tab.teardown() }
            }
            store.forceRemoveSpace(id: id)
        }
        createdSpaceIDs.removeAll()
        for profile in createdProfiles {
            store.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        store.lastActiveSpaceID = previousLastActiveSpaceID
        store.undoManager.removeAllActions()
        try await super.tearDown()
    }

    private func browserWindows() -> [BrowserWindowController] {
        NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            .filter { $0.window?.isVisible == true }
    }

    private func makeProfile(_ name: String) -> Profile {
        let profile = store.addProfile(name: "\(name) \(UUID().uuidString.prefix(4))")
        createdProfiles.append(profile)
        return profile
    }

    private func addSpace(_ name: String, _ profile: Profile) -> Space {
        let space = store.addSpace(name: name, emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    private func makeWindow(showing space: Space) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        appDelegate.registerWindowController(wc)
        return wc
    }

    func testEveryWindowEntryPointScopesThePaletteToTheWindowsProfile() throws {
        let work = makeProfile("Palette Work")
        let home = makeProfile("Palette Home")
        let inbox = addSpace("Inbox", work)
        let build = addSpace("Build", work)
        let family = addSpace("Family", home)
        let url = URL(string: "http://127.0.0.1:1/shared")!
        let inboxTab = store.addTab(in: inbox, url: url)
        let buildTab = store.addTab(in: build, url: url)
        let familyTab = store.addTab(in: family, url: url)
        let wc = makeWindow(showing: inbox)
        let workHistory = Set([inbox.id.uuidString, build.id.uuidString,
                               QuickDetour.historySpaceIDString(forProfileID: work.id)])

        for (name, open) in [("Cmd+T", { wc.newTab(nil) }), ("Cmd+L", { wc.focusAddressBar(nil) })] {
            open()
            let palette = try XCTUnwrap(wc.commandPaletteView, name)
            XCTAssertEqual(Set(palette.historySpaceIDs), workHistory, "\(name): the profile's history")
            XCTAssertFalse(palette.historySpaceIDs.contains(family.id.uuidString), name)
            XCTAssertEqual(Set(palette.gatherTabInfos().map(\.tabID)), [inboxTab.id, buildTab.id],
                           "\(name): the profile's open tabs, not the home profile's at the same URL")
            XCTAssertFalse(palette.gatherTabInfos().contains { $0.tabID == familyTab.id }, name)
            wc.dismissCommandPalette()
        }

        wc.setActiveSpace(id: family.id, selectTab: false)
        wc.newTab(nil)
        let palette = try XCTUnwrap(wc.commandPaletteView)
        XCTAssertEqual(Set(palette.historySpaceIDs),
                       [family.id.uuidString, QuickDetour.historySpaceIDString(forProfileID: home.id)],
                       "the same window on the home profile's space reads the home profile")
        XCTAssertEqual(palette.gatherTabInfos().map(\.tabID), [familyTab.id])
    }

    /// A palette left open across a space switch (Next Space into a space with
    /// no tab to select, which dismisses nothing) is re-scoped to the new
    /// space's profile rather than keeping the old one's history and tabs.
    func testAPaletteOpenAcrossASwitchToAnotherProfilesEmptySpaceFollowsIt() throws {
        let work = makeProfile("Palette Work")
        let home = makeProfile("Palette Home")
        let inbox = addSpace("Inbox", work)
        let family = addSpace("Family", home)
        _ = store.addTab(in: inbox, url: URL(string: "http://127.0.0.1:1/work")!)
        let wc = makeWindow(showing: inbox)

        wc.newTab(nil)
        let palette = try XCTUnwrap(wc.commandPaletteView)
        wc.setActiveSpace(id: family.id)

        XCTAssertTrue(wc.commandPaletteView === palette, "premise: an empty space dismisses nothing")
        XCTAssertEqual(Set(palette.historySpaceIDs),
                       [family.id.uuidString, QuickDetour.historySpaceIDString(forProfileID: home.id)])
        XCTAssertEqual(palette.gatherTabInfos().map(\.tabID), [], "no work tab follows it into home")
        XCTAssertTrue(palette.profile === home)
    }

    func testAPrivateWindowsPaletteHasNoHistory() throws {
        let wc = BrowserWindowController(incognito: true)
        wc.sidebarSplitView.autosaveName = nil
        wc.showWindow(nil)
        appDelegate.registerWindowController(wc)

        wc.newTab(nil)

        let palette = try XCTUnwrap(wc.commandPaletteView)
        XCTAssertEqual(palette.historySpaceIDs, [], "a Private window reads no profile's history")
    }
}
