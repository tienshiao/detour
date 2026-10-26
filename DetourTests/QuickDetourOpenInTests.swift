import XCTest
import GRDB
import WebKit
@testable import Detour

/// Open in <Space> (TASK-193.3), the model: which space the button names
/// (decision 1), the dropdown (decision 2), Private (decision 3), "a
/// profile's most recently used space", and the store's hand-over of a Quick
/// Detour's page into a space — the same tab and web view, its history scope
/// switching at the move, a Private one's downloads moving with it, and the
/// extension contexts told of a move rather than a close.
///
/// Private `TabStore`s on in-memory databases; pages that must really load
/// come from a loopback server.
@MainActor
final class QuickDetourOpenInTests: XCTestCase {

    private var openedTabs: [(store: TabStore, tab: BrowserTab)] = []
    private var servers: [LoopbackHTTPServer] = []

    override func tearDown() {
        for (store, tab) in openedTabs {
            store.closeQuickDetourTab(tab)
            for space in store.spaces where space.tabs.contains(where: { $0 === tab }) {
                store.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
            }
            tab.teardown()
        }
        openedTabs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        super.tearDown()
    }

    // MARK: - Snapshot fixtures for the pure rules

    private let work = QuickDetourProfileSnapshot(id: UUID(), name: "Work", isPrivate: false, isDeleted: false)
    private let home = QuickDetourProfileSnapshot(id: UUID(), name: "Home", isPrivate: false, isDeleted: false)
    private let privateProfile = QuickDetourProfileSnapshot(id: TabStore.incognitoProfileID, name: "Private",
                                                            isPrivate: true, isDeleted: false)

    private func space(_ name: String, _ emoji: String, _ profile: QuickDetourProfileSnapshot,
                       isPrivate: Bool = false) -> QuickDetourSpaceSnapshot {
        QuickDetourSpaceSnapshot(id: UUID(), name: name, emoji: emoji, profileID: profile.id, isPrivate: isPrivate)
    }

    // MARK: - A profile's most recently used space

    func testTheMostRecentlyUsedSpaceIsTheFirstOfTheProfileInUseOrder() {
        let inbox = space("Inbox", "📥", work)
        let build = space("Build", "🔨", work)
        let fun = space("Fun", "🎉", home)
        let spaces = [inbox, build, fun]

        XCTAssertEqual(QuickDetour.mostRecentlyUsedSpace(ofProfile: work.id, spaces: spaces,
                                                         useOrder: [fun.id, build.id, inbox.id]), build.id,
                       "another profile's more recent space does not count")
        XCTAssertEqual(QuickDetour.mostRecentlyUsedSpace(ofProfile: home.id, spaces: spaces,
                                                         useOrder: [fun.id, build.id]), fun.id)
    }

    func testTheMostRecentlyUsedSpaceSkipsDeletedAndPrivateSpaces() {
        let inbox = space("Inbox", "📥", work)
        let build = space("Build", "🔨", work)
        let gone = UUID()
        let privateSpace = space("Private", "🕶", work, isPrivate: true)

        XCTAssertEqual(QuickDetour.mostRecentlyUsedSpace(ofProfile: work.id, spaces: [inbox, build, privateSpace],
                                                         useOrder: [gone, privateSpace.id, build.id]), build.id)
    }

    func testWithNothingUsedTheProfilesFirstSpaceInSidebarOrder() {
        let inbox = space("Inbox", "📥", work)
        let build = space("Build", "🔨", work)
        let fun = space("Fun", "🎉", home)

        XCTAssertEqual(QuickDetour.mostRecentlyUsedSpace(ofProfile: work.id, spaces: [fun, inbox, build],
                                                         useOrder: []), inbox.id)
        XCTAssertEqual(QuickDetour.mostRecentlyUsedSpace(ofProfile: work.id, spaces: [fun, inbox, build],
                                                         useOrder: [fun.id]), inbox.id)
        XCTAssertNil(QuickDetour.mostRecentlyUsedSpace(ofProfile: UUID(), spaces: [fun, inbox], useOrder: [fun.id]),
                     "a profile with no space has none")
    }

    // MARK: - The default target (decision 1)

    func testTheDefaultIsTheSourceSpaceWhenItIsTheSameProfiles() {
        let inbox = space("Inbox", "📥", work)
        let build = space("Build", "🔨", work)

        XCTAssertEqual(QuickDetour.openInDefaultSpace(profileID: work.id, sourceSpaceID: build.id,
                                                      spaces: [inbox, build], useOrder: [inbox.id]), build.id,
                       "the space in front when it was opened, even if another was used since")
    }

    func testAnotherProfilesSourceSpaceFallsBackToTheProfilesMostRecent() {
        let inbox = space("Inbox", "📥", work)
        let build = space("Build", "🔨", work)
        let fun = space("Fun", "🎉", home)

        XCTAssertEqual(QuickDetour.openInDefaultSpace(profileID: work.id, sourceSpaceID: fun.id,
                                                      spaces: [inbox, build, fun], useOrder: [fun.id, build.id]),
                       build.id)
    }

    func testADeletedSourceSpaceFallsBackToTheProfilesMostRecent() {
        let inbox = space("Inbox", "📥", work)
        let build = space("Build", "🔨", work)

        XCTAssertEqual(QuickDetour.openInDefaultSpace(profileID: work.id, sourceSpaceID: UUID(),
                                                      spaces: [inbox, build], useOrder: [build.id]), build.id)
        XCTAssertEqual(QuickDetour.openInDefaultSpace(profileID: work.id, sourceSpaceID: nil,
                                                      spaces: [inbox, build], useOrder: []), inbox.id,
                       "no source and nothing used: the profile's first space")
    }

    func testAPrivateSourceSpaceIsNeverTheDefault() {
        let inbox = space("Inbox", "📥", work)
        let privateSpace = space("Private", "🕶", work, isPrivate: true)

        XCTAssertEqual(QuickDetour.openInDefaultSpace(profileID: work.id, sourceSpaceID: privateSpace.id,
                                                      spaces: [privateSpace, inbox], useOrder: []), inbox.id)
    }

    func testAProfileWithNoSpaceHasNoDefaultOfItsOwn() {
        let fun = space("Fun", "🎉", home)
        XCTAssertNil(QuickDetour.openInDefaultSpace(profileID: work.id, sourceSpaceID: fun.id, spaces: [fun],
                                                    useOrder: [fun.id]))
    }

    // MARK: - The menu (decision 2)

    func testTheMenuGroupsSpacesByProfileTheWindowsFirst() throws {
        let fun = space("Fun", "🎉", home)
        let inbox = space("Inbox", "📥", work)
        let reading = space("Reading", "📚", home)
        let build = space("Build", "🔨", work)

        let menu = QuickDetour.openInMenu(windowProfile: work, sourceSpaceID: build.id,
                                          spaces: [fun, inbox, reading, build], profiles: [home, work],
                                          useOrder: [])

        XCTAssertEqual(menu.sections.map(\.title), ["Work", "Home"],
                       "the window's own profile first (its spaces keep the page), the others in profile order")
        XCTAssertEqual(menu.sections.map(\.profileID), [work.id, home.id])
        // No subscripts: an empty list (the red step's stub) fails, not crashes.
        XCTAssertEqual(menu.sections.first?.items.map(\.name), ["Inbox", "Build"], "sidebar order within a profile")
        XCTAssertEqual(menu.sections.first?.items.map(\.emoji), ["📥", "🔨"])
        XCTAssertEqual(menu.sections.dropFirst().first?.items.map(\.name), ["Fun", "Reading"])
        XCTAssertTrue(menu.showsSectionHeaders)
        XCTAssertTrue(menu.hasDropdown)
    }

    func testOnlyAnotherProfilesSpacesReload() {
        let inbox = space("Inbox", "📥", work)
        let fun = space("Fun", "🎉", home)

        let menu = QuickDetour.openInMenu(windowProfile: work, sourceSpaceID: nil, spaces: [inbox, fun],
                                          profiles: [work, home], useOrder: [])

        XCTAssertEqual(menu.sections.flatMap(\.items).map(\.reloads), [false, true])
    }

    func testTheDefaultItemIsMarkedAndNamesTheButton() {
        let inbox = space("Inbox", "📥", work)
        let build = space("Build", "🔨", work)
        let fun = space("Fun", "🎉", home)

        let menu = QuickDetour.openInMenu(windowProfile: work, sourceSpaceID: build.id, spaces: [inbox, build, fun],
                                          profiles: [work, home], useOrder: [inbox.id])

        XCTAssertEqual(menu.defaultTarget, .space(build.id))
        XCTAssertEqual(menu.destinationName, "🔨 Build")
        XCTAssertFalse(menu.defaultReloads)
        XCTAssertEqual(menu.sections.flatMap(\.items).filter(\.isDefault).map(\.spaceID), [build.id],
                       "exactly one item is the button's")
    }

    func testOneProfileNeedsNoHeader() {
        let inbox = space("Inbox", "📥", work)
        let build = space("Build", "🔨", work)

        let menu = QuickDetour.openInMenu(windowProfile: work, sourceSpaceID: nil, spaces: [inbox, build],
                                          profiles: [work, home], useOrder: [])

        XCTAssertEqual(menu.sections.count, 1, "a profile with no spaces has no section")
        XCTAssertFalse(menu.showsSectionHeaders)
    }

    func testPrivateAndDeletedProfilesSpacesAreNeverListed() {
        let inbox = space("Inbox", "📥", work)
        let privateSpace = space("Private", "🕶", privateProfile, isPrivate: true)
        let deleted = QuickDetourProfileSnapshot(id: UUID(), name: "Gone", isPrivate: false, isDeleted: true)
        let orphan = space("Orphan", "👻", deleted)
        let unknown = QuickDetourSpaceSnapshot(id: UUID(), name: "Lost", emoji: "?", profileID: UUID(),
                                               isPrivate: false)

        let menu = QuickDetour.openInMenu(windowProfile: work, sourceSpaceID: nil,
                                          spaces: [inbox, privateSpace, orphan, unknown],
                                          profiles: [work, privateProfile, deleted], useOrder: [])

        XCTAssertEqual(menu.sections.flatMap(\.items).map(\.spaceID), [inbox.id])
    }

    func testAProfileWithNoSpaceDefaultsToTheMostRecentSpaceAndReloads() {
        let fun = space("Fun", "🎉", home)
        let reading = space("Reading", "📚", home)

        let menu = QuickDetour.openInMenu(windowProfile: work, sourceSpaceID: nil, spaces: [fun, reading],
                                          profiles: [work, home], useOrder: [reading.id])

        XCTAssertEqual(menu.defaultTarget, .space(reading.id))
        XCTAssertTrue(menu.defaultReloads, "the page cannot move into another profile")
        XCTAssertEqual(menu.sections.map(\.title), ["Home"])
    }

    func testWithNoNormalSpaceAtAllThereIsNoTarget() {
        let menu = QuickDetour.openInMenu(windowProfile: work, sourceSpaceID: nil, spaces: [], profiles: [work],
                                          useOrder: [])
        XCTAssertNil(menu.defaultTarget)
        XCTAssertNil(menu.destinationName)
        XCTAssertFalse(menu.hasDropdown)
    }

    // MARK: - Private (decision 3)

    func testAPrivateQuickDetourOpensInAPrivateWindowWithNoDropdown() {
        let inbox = space("Inbox", "📥", work)
        let privateSpace = space("Private", "🕶", privateProfile, isPrivate: true)

        let menu = QuickDetour.openInMenu(windowProfile: privateProfile, sourceSpaceID: privateSpace.id,
                                          spaces: [inbox, privateSpace], profiles: [work, privateProfile],
                                          useOrder: [inbox.id])

        XCTAssertEqual(menu.defaultTarget, .privateWindow)
        XCTAssertEqual(menu.destinationName, "Private Window")
        XCTAssertFalse(menu.defaultReloads, "the page moves intact")
        XCTAssertTrue(menu.sections.isEmpty, "no normal space: Private never crosses into a profile")
        XCTAssertFalse(menu.hasDropdown)
    }

    // MARK: - The store's use order

    private struct Fixture {
        let store: TabStore
        let appDB: AppDatabase
        let historyDB: HistoryDatabase
        let profile: Profile
        let space: Space
    }

    private func makeFixture(debounce: TimeInterval = 0.2) throws -> Fixture {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let historyDB = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let appDB = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: appDB, historyDB: historyDB, historySettleDebounce: debounce)
        let profile = store.addProfile(name: "Work")
        let space = store.addSpace(name: "Inbox", emoji: "📥", colorHex: "007AFF", profileID: profile.id)
        return Fixture(store: store, appDB: appDB, historyDB: historyDB, profile: profile, space: space)
    }

    func testNoteSpaceUsedKeepsTheMostRecentFirstOnce() throws {
        let f = try makeFixture()
        let build = f.store.addSpace(name: "Build", emoji: "🔨", colorHex: "007AFF", profileID: f.profile.id)

        f.store.noteSpaceUsed(f.space.id)
        f.store.noteSpaceUsed(build.id)
        f.store.noteSpaceUsed(f.space.id)

        XCTAssertEqual(f.store.spaceUseOrder, [f.space.id, build.id])
    }

    func testNoteSpaceUsedIgnoresPrivateAndUnknownSpaces() throws {
        let f = try makeFixture()
        let privateSpace = f.store.addIncognitoSpace()

        f.store.noteSpaceUsed(f.space.id)
        f.store.noteSpaceUsed(privateSpace.id)
        f.store.noteSpaceUsed(UUID())

        XCTAssertEqual(f.store.spaceUseOrder, [f.space.id])
    }

    func testTheStoresMenuUsesItsUseOrder() throws {
        let f = try makeFixture()
        let build = f.store.addSpace(name: "Build", emoji: "🔨", colorHex: "007AFF", profileID: f.profile.id)
        f.store.noteSpaceUsed(build.id)

        let menu = f.store.quickDetourOpenInMenu(profile: f.profile, sourceSpaceID: nil)

        XCTAssertEqual(menu.defaultTarget, .space(build.id))
        XCTAssertEqual(menu.destinationName, "🔨 Build")
    }

    // MARK: - The hand-over

    private func open(in store: TabStore, profile: Profile) -> BrowserTab {
        let tab = store.openQuickDetourTab(profile: profile)
        openedTabs.append((store, tab))
        return tab
    }

    private final class Observer: TabStoreObserver {
        var inserted: [(tab: BrowserTab, index: Int, space: Space)] = []
        var moved: [(tab: BrowserTab, space: Space)] = []
        var closed: [BrowserTab] = []
        func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) {
            inserted.append((tab, index, space))
        }
        func tabStoreDidMoveQuickDetour(_ tab: BrowserTab, into space: Space) {
            moved.append((tab, space))
        }
        func tabStoreDidCloseQuickDetour(_ tab: BrowserTab) {
            closed.append(tab)
        }
    }

    func testTheMoveHandsTheSameTabAndWebViewToTheSpace() throws {
        let f = try makeFixture()
        let existing = f.store.addTab(in: f.space, url: URL(string: "https://existing.invalid/"))
        let quick = open(in: f.store, profile: f.profile)
        let webView = try XCTUnwrap(quick.webView)
        let observer = Observer()
        f.store.addObserver(observer)

        XCTAssertTrue(f.store.canMoveQuickDetourTab(quick, into: f.space))
        XCTAssertTrue(f.store.moveQuickDetourTab(quick, into: f.space))

        XCTAssertFalse(f.store.isQuickDetourTab(quick))
        XCTAssertTrue(f.store.quickDetourTabs.isEmpty)
        XCTAssertEqual(f.space.tabs.map(\.id), [quick.id, existing.id],
                       "the new-tab position (TabInsertion: no parent, the top of the list)")
        XCTAssertTrue(f.space.tabs.first === quick, "the same BrowserTab object, the same id")
        XCTAssertTrue(quick.webView === webView, "the same web view, not torn down")
        XCTAssertEqual(quick.spaceID, f.space.id)
        XCTAssertNil(quick.quickDetourProfile)
        XCTAssertTrue(quick.owningProfile === f.profile)
        XCTAssertEqual(observer.inserted.map(\.tab.id), [quick.id])
        XCTAssertEqual(observer.inserted.first?.index, 0)
        XCTAssertEqual(observer.moved.map(\.tab.id), [quick.id])
        XCTAssertTrue(observer.moved.first?.space === f.space)
        XCTAssertTrue(observer.closed.isEmpty, "a move, not a close")
    }

    func testTheMovedTabIsSavedWithTheSession() throws {
        let f = try makeFixture()
        let quick = open(in: f.store, profile: f.profile)
        quick.load(URL(string: "https://moved.invalid/")!)

        f.store.moveQuickDetourTab(quick, into: f.space)

        let savedTabIDs = f.store.makeSessionSnapshot().spaces.flatMap { $0.1.map(\.id) }
        XCTAssertEqual(savedTabIDs, [quick.id.uuidString], "a space's tab now")
    }

    func testTheMoveRefusesAnotherProfilesSpace() throws {
        let f = try makeFixture()
        let other = f.store.addProfile(name: "Home")
        let otherSpace = f.store.addSpace(name: "Fun", emoji: "🎉", colorHex: "007AFF", profileID: other.id)
        let quick = open(in: f.store, profile: f.profile)

        XCTAssertFalse(f.store.canMoveQuickDetourTab(quick, into: otherSpace), "another data store")
        XCTAssertFalse(f.store.moveQuickDetourTab(quick, into: otherSpace))
        XCTAssertTrue(f.store.isQuickDetourTab(quick), "left exactly where it was")
        XCTAssertTrue(otherSpace.tabs.isEmpty)
        XCTAssertTrue(quick.quickDetourProfile === f.profile)
    }

    func testTheMoveRefusesTheIncognitoBoundary() throws {
        let f = try makeFixture()
        let privateProfile = f.store.ensureIncognitoProfile()
        let privateSpace = f.store.addIncognitoSpace()
        let normal = open(in: f.store, profile: f.profile)
        let privateQuick = open(in: f.store, profile: privateProfile)

        XCTAssertFalse(f.store.canMoveQuickDetourTab(normal, into: privateSpace))
        XCTAssertFalse(f.store.canMoveQuickDetourTab(privateQuick, into: f.space))
        XCTAssertFalse(f.store.moveQuickDetourTab(privateQuick, into: f.space))
        XCTAssertTrue(f.store.isQuickDetourTab(privateQuick))
    }

    func testTheMoveRefusesATabThatIsNoQuickDetoursAndASpaceThatIsGone() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space)
        let quick = open(in: f.store, profile: f.profile)
        let gone = f.store.addSpace(name: "Gone", emoji: "x", colorHex: "007AFF", profileID: f.profile.id)
        f.store.forceRemoveSpace(id: gone.id)

        XCTAssertFalse(f.store.canMoveQuickDetourTab(tab, into: f.space), "already a space's tab")
        XCTAssertFalse(f.store.canMoveQuickDetourTab(quick, into: gone), "a space no longer in the store")
        XCTAssertFalse(f.store.moveQuickDetourTab(quick, into: gone))
        XCTAssertTrue(f.store.isQuickDetourTab(quick))
    }

    func testAPrivateQuickDetourMovesIntoAPrivateSpaceKeepingTheSession() throws {
        let f = try makeFixture()
        let privateProfile = f.store.ensureIncognitoProfile()
        let privateSpace = f.store.addIncognitoSpace()
        let quick = open(in: f.store, profile: privateProfile)
        let webView = try XCTUnwrap(quick.webView)

        XCTAssertTrue(f.store.moveQuickDetourTab(quick, into: privateSpace))

        XCTAssertTrue(privateSpace.tabs.first === quick)
        XCTAssertTrue(quick.webView === webView)
        XCTAssertTrue(webView.configuration.websiteDataStore === privateProfile.dataStore, "the same throwaway store")
        XCTAssertTrue(f.store.hasLivePrivateSession)
    }

    func testTheMoveIsAnnouncedAsAMoveFromTheQuickDetoursWindowNotAClose() throws {
        let f = try makeFixture()
        let recorder = RecordingNotifier()
        let previousNotifier = ExtensionTabLifecycle.notifier
        let previousShowing = ExtensionTabLifecycle.windowShowingTab
        defer {
            ExtensionTabLifecycle.notifier = previousNotifier
            ExtensionTabLifecycle.windowShowingTab = previousShowing
        }
        ExtensionTabLifecycle.notifier = recorder
        let popup = StubWindow()
        ExtensionTabLifecycle.windowShowingTab = { tab in tab.spaceID == nil ? popup : nil }
        let quick = open(in: f.store, profile: f.profile)
        XCTAssertEqual(recorder.events, ["open"], "reported open on entering quickDetourTabs")

        f.store.moveQuickDetourTab(quick, into: f.space)

        XCTAssertEqual(recorder.events, ["open", "move"], "no close and no second open: the tab id stays")
        XCTAssertEqual(recorder.moves.first?.fromIndex, 0, "the one tab of its popup window")
        XCTAssertTrue(recorder.moves.first?.oldWindow === popup, "detached from the Quick Detour's window")
        XCTAssertTrue(recorder.moves.first?.tabWasInSpace == true, "announced once the space lists it")
        XCTAssertTrue(quick.extensionRegisteredProfile === f.profile, "still registered")
    }

    /// Open in selects the tab in its new window before announcing the move
    /// (WebKit lists a window's tabs only while one is selected), so it asks
    /// the store not to announce it.
    func testAMoveTheCallerAnnouncesIsNotAnnouncedByTheStore() throws {
        let f = try makeFixture()
        let recorder = RecordingNotifier()
        let previousNotifier = ExtensionTabLifecycle.notifier
        defer { ExtensionTabLifecycle.notifier = previousNotifier }
        ExtensionTabLifecycle.notifier = recorder
        let quick = open(in: f.store, profile: f.profile)

        XCTAssertTrue(f.store.moveQuickDetourTab(quick, into: f.space, announcingMove: false))

        XCTAssertEqual(recorder.events, ["open"], "neither a move nor a close")
        XCTAssertTrue(quick.extensionRegisteredProfile === f.profile)
    }

    // MARK: - History: the scope switches at the move

    private static let pages = [
        "/": "<html><head><title>Before</title></head><body>before</body></html>",
        "/after": "<html><head><title>After</title></head><body>after</body></html>",
    ]

    private func serve(_ routes: [String: String]) async throws -> URL {
        let server = try LoopbackHTTPServer(routes: routes)
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testVisitsBeforeTheMoveStayUnderTheQuickDetourScopeAndLaterOnesGoToTheSpace() async throws {
        let f = try makeFixture()
        let base = try await serve(Self.pages)
        let quick = open(in: f.store, profile: f.profile)
        let quickScope = QuickDetour.historySpaceIDString(forProfileID: f.profile.id)
        let spaceScope = f.space.id.uuidString

        quick.load(base, typed: true)
        try await waitUntil("the Quick Detour visit") {
            self.pump(0.05)
            return f.historyDB.visits(spaceIDs: [quickScope], limit: 10).first?.title == "Before"
        }

        XCTAssertTrue(f.store.moveQuickDetourTab(quick, into: f.space))
        XCTAssertEqual(quick.historySpaceID, f.space.id, "the scope switches at the move")

        quick.load(base.appendingPathComponent("after"))
        try await waitUntil("the space's visit") {
            self.pump(0.05)
            return f.historyDB.visits(spaceIDs: [spaceScope], limit: 10).first?.title == "After"
        }
        pump(0.5)

        XCTAssertEqual(f.historyDB.visits(spaceIDs: [quickScope], limit: 10).map(\.url), [base.absoluteString],
                       "the earlier visit stays where it was recorded")
        XCTAssertEqual(f.historyDB.visits(spaceIDs: [spaceScope], limit: 10).map(\.url),
                       [base.appendingPathComponent("after").absoluteString],
                       "later visits are the space's")
    }

    // MARK: - Downloads: a Private Quick Detour's move with its page

    func testAPrivateQuickDetoursDownloadsMoveWithItsPage() throws {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: db)
        let manager = DownloadManager(database: db)
        manager.observeIncognitoSpaces(of: store)
        let privateProfile = store.ensureIncognitoProfile()
        let quick = open(in: store, profile: privateProfile)
        let item = manager.addManualItem(filename: "secret.zip", sourceURL: URL(string: "https://example.com/s.zip"),
                                         scope: .incognito(spaceID: quick.id))
        let privateSpace = store.addIncognitoSpace()

        store.moveQuickDetourTab(quick, into: privateSpace)

        XCTAssertEqual(manager.items(in: .incognito(spaceID: privateSpace.id)).map(\.id), [item.id],
                       "listed in the receiving Private window")
        XCTAssertTrue(manager.items(in: .incognito(spaceID: quick.id)).isEmpty)
        XCTAssertEqual(item.state, .downloading, "still running")

        // Any space change reconciles: the download's scope is live.
        let another = store.addIncognitoSpace()
        store.removeIncognitoSpace(id: another.id)
        XCTAssertEqual(manager.items(in: .incognito(spaceID: privateSpace.id)).map(\.id), [item.id])

        // And it goes with that window, as its own downloads do.
        store.removeIncognitoSpace(id: privateSpace.id)
        XCTAssertTrue(manager.items(in: .incognito(spaceID: privateSpace.id)).isEmpty)
    }

    func testANormalQuickDetoursDownloadsStayNormal() throws {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: db)
        let manager = DownloadManager(database: db)
        manager.observeIncognitoSpaces(of: store)
        let profile = store.addProfile(name: "Work")
        let space = store.addSpace(name: "Inbox", emoji: "📥", colorHex: "007AFF", profileID: profile.id)
        let quick = open(in: store, profile: profile)
        let item = manager.addManualItem(filename: "report.pdf", sourceURL: nil, scope: .normal)

        store.moveQuickDetourTab(quick, into: space)

        XCTAssertEqual(item.scope, .normal)
        XCTAssertEqual(manager.items(in: .normal).map(\.id), [item.id])
    }
}

// MARK: - A recorder for the extension seam

@MainActor
private final class RecordingNotifier: ExtensionTabLifecycleNotifying {
    struct Move {
        let tabID: UUID
        let fromIndex: Int
        let oldWindow: (any WKWebExtensionWindow)?
        let tabWasInSpace: Bool
    }
    var events: [String] = []
    var moves: [Move] = []

    func didOpen(_ tab: BrowserTab, in profile: Profile, contexts: [WKWebExtensionContext]?) { events.append("open") }
    func didClose(_ tab: BrowserTab, in profile: Profile) { events.append("close") }
    func didActivate(_ tab: BrowserTab, previousActiveTab: BrowserTab?, in profile: Profile,
                     contexts: [WKWebExtensionContext]?) {}
    func didChangeProperties(_ tab: BrowserTab, in profile: Profile, properties: WKWebExtension.TabChangedProperties) {}
    func didMove(_ tab: BrowserTab, fromIndex: Int, in oldWindow: (any WKWebExtensionWindow)?, in profile: Profile) {
        events.append("move")
        moves.append(Move(tabID: tab.id, fromIndex: fromIndex, oldWindow: oldWindow, tabWasInSpace: tab.spaceID != nil))
    }
}

private final class StubWindow: NSObject, WKWebExtensionWindow {}
