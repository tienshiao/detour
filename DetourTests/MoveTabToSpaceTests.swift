import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-38: the sidebar's "Move to Space".
///
/// It used to be a close plus a create: `closeTab` / `closePinnedTab` on the
/// source, then `addTab(in: destination, url:)`. That archived the tab on the
/// closed-tab stack, registered a Close Tab undo, dropped the back/forward list
/// and the interaction state, turned a pinned entry into an ordinary tab, and —
/// worst — rebuilt the page from the *destination space's* configuration, which
/// cannot load `webkit-extension://` at all (TASK-24). The characterization
/// tests record that behaviour (AC #1); the rest assert what
/// `moveTab(id:from:to:)` and `movePinnedEntry(id:from:to:)` do instead.
///
/// The private-store tests run against their own in-memory database. The ones
/// that wake a tab, or need a real `WKWebExtensionContext`, run against
/// `TabStore.shared` and `ExtensionManager.shared` (the test scheme points
/// `DETOUR_DATA_DIR` at an isolated directory), because `BrowserTab.wake`
/// resolves its space through the shared store.
@MainActor
final class MoveTabToSpaceTests: XCTestCase {

    private var createdTabs: [BrowserTab] = []
    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var sharedProfiles: [Profile] = []
    private var sharedSpaceIDs: [UUID] = []

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        for id in sharedSpaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        sharedSpaceIDs.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        for profile in sharedProfiles {
            for favorite in profile.favorites { favorite.tab?.teardown() }
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        sharedProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Nothing listens on port 1, so a load navigates nowhere real.
    private let pageURL = URL(string: "http://127.0.0.1:1/page")!

    private struct Fixture {
        let db: AppDatabase
        let store: TabStore
        let profile: Profile
        let other: Profile
        /// `a` and `b` share `profile`; `c` is on `other`.
        let a: Space
        let b: Space
        let c: Space
    }

    /// A private store with two profiles: two spaces on one, one on the other.
    private func makeFixture() throws -> Fixture {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Move")
        let other = store.addProfile(name: "Move Other")
        let a = store.addSpace(name: "A", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        let b = store.addSpace(name: "B", emoji: "🅱️", colorHex: "FF9500", profileID: profile.id)
        let c = store.addSpace(name: "C", emoji: "🇨", colorHex: "34C759", profileID: other.id)
        store.undoManager.removeAllActions()
        return Fixture(db: db, store: store, profile: profile, other: other, a: a, b: b, c: c)
    }

    /// The same shape on `TabStore.shared`, for the tests that wake a tab.
    private func makeSharedFixture(_ name: String) -> (store: TabStore, profile: Profile,
                                                       other: Profile, a: Space, b: Space, c: Space) {
        let store = TabStore.shared
        let profile = store.addProfile(name: "Move \(name)")
        let other = store.addProfile(name: "Move \(name) Other")
        sharedProfiles.append(contentsOf: [profile, other])
        let a = store.addSpace(name: "Move \(name) A", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        let b = store.addSpace(name: "Move \(name) B", emoji: "🅱️", colorHex: "FF9500", profileID: profile.id)
        let c = store.addSpace(name: "Move \(name) C", emoji: "🇨", colorHex: "34C759", profileID: other.id)
        sharedSpaceIDs.append(contentsOf: [a.id, b.id, c.id])
        store.undoManager.removeAllActions()
        return (store, profile, other, a, b, c)
    }

    /// A minimal MV3 extension with an options page, registered with the shared
    /// manager and database.
    private func makeExtension() async throws -> WebExtension {
        let ext = try await makeOptionsPageTestExtension(idPrefix: "move-to-space",
                                                         name: "Move To Space Test")
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(ext.id)
        installTestExtension(ext, in: AppDatabase.shared,
                             manifestJSON: try testExtensionManifestData(ext))
        return ext
    }

    // MARK: - Characterization: the old close-and-recreate (AC #1)

    /// The old sequence for an ordinary tab: the tab is archived on the
    /// closed-tab stack, a Close Tab undo is registered, and what lands in the
    /// destination is a *different* tab with a different web view.
    func testCharacterizationCloseAndRecreateArchivesTheTabAndLosesItsIdentity() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(tab)
        let webView = try XCTUnwrap(tab.webView)

        // What `tabSidebar(_:didRequestMoveTabAt:isPinned:toSpaceID:)` used to do.
        f.store.closeTab(id: tab.id, in: f.a)
        let rebuilt = f.store.addTab(in: f.b, url: pageURL)
        createdTabs.append(rebuilt)

        XCTAssertNotEqual(rebuilt.id, tab.id, "a new tab, not the one that was moved")
        XCTAssertFalse(rebuilt.webView === webView, "with a new web view, so no back/forward list")
        XCTAssertTrue(f.store.canReopenClosedTab(in: f.a),
                      "the moved tab sits on the source's closed-tab stack")
        XCTAssertEqual(f.store.undoManager.undoActionName, "Close Tab",
                       "and undo offers to reopen it rather than to move it back")
    }

    /// The old sequence for a pinned entry: it stops being pinned.
    func testCharacterizationCloseAndRecreateUnpinsAPinnedEntry() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(tab)
        f.store.pinTab(id: tab.id, in: f.a)
        let entry = try XCTUnwrap(f.a.pinnedEntries.first)

        f.store.closePinnedTab(id: entry.id, in: f.a)
        let rebuilt = f.store.addTab(in: f.b, url: pageURL)
        createdTabs.append(rebuilt)

        XCTAssertTrue(f.b.pinnedEntries.isEmpty, "nothing pinned in the destination")
        XCTAssertEqual(f.b.tabs.map(\.id), [rebuilt.id], "the entry came back as an ordinary tab")
    }

    /// The old sequence for an extension page: `addTab` loads the URL eagerly in
    /// a web view built from the space configuration, which has no handler for
    /// `webkit-extension://`. Only the context's own configuration can load it,
    /// and only `makeTab(loading:)` — which leaves the tab sleeping for `wake()`
    /// to pick that configuration — ever gets there (TASK-24).
    func testCharacterizationCloseAndRecreateRebuildsAnExtensionPageInTheSpaceConfiguration() async throws {
        let ext = try await makeExtension()
        let f = makeSharedFixture("Characterize")
        _ = f.profile.extensionController
        let context = try loadTestContext(ext, in: f.profile)
        let contextConfig = try XCTUnwrap(context.webViewConfiguration)
        let url = try extensionPageURL("options.html?old=1", on: context.baseURL)
        let tab = f.store.addExtensionTab(in: f.a, url: url, configuration: contextConfig)
        createdTabs.append(tab)
        let webView = try XCTUnwrap(tab.webView)

        f.store.closeTab(id: tab.id, in: f.a)
        let rebuilt = f.store.addTab(in: f.b, url: url)
        createdTabs.append(rebuilt)

        XCTAssertNotEqual(rebuilt.id, tab.id, "a different tab")
        XCTAssertFalse(rebuilt.webView === webView,
                       "with a new web view, built from the space configuration")
        XCTAssertFalse(rebuilt.isSleeping,
                       "loaded eagerly, so wake never gets to choose the context's configuration — "
                       + "which `makeTab(loading:)` exists to allow (TASK-24)")
        XCTAssertTrue(webView.configuration.webExtensionController === f.profile.extensionController,
                      "the page it replaced was served by a real context of the profile")
    }

    // MARK: - Within one profile: the tab itself moves

    func testMoveTabWithinAProfileKeepsTheTabItsWebViewAndItsIdentity() throws {
        let f = try makeFixture()
        let stay = f.store.addTab(in: f.a, url: pageURL)
        let tab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(contentsOf: [stay, tab])
        let webView = try XCTUnwrap(tab.webView)

        XCTAssertTrue(f.store.moveTab(id: tab.id, from: f.a, to: f.b))

        XCTAssertEqual(f.a.tabs.map(\.id), [stay.id])
        XCTAssertEqual(f.b.tabs.map(\.id), [tab.id])
        XCTAssertTrue(f.b.tabs.first === tab, "the same tab object")
        XCTAssertTrue(tab.webView === webView, "with the web view it already had, so its history survives")
        XCTAssertFalse(tab.isSleeping, "a same-profile move never has to rebind the tab")
        XCTAssertEqual(tab.spaceID, f.b.id, "rehomed onto the destination space")
    }

    func testMoveTabArchivesNothingAndRegistersOneMoveUndo() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(tab)

        XCTAssertTrue(f.store.moveTab(id: tab.id, from: f.a, to: f.b))

        XCTAssertFalse(f.store.canReopenClosedTab(in: f.a), "no closed-tab record: nothing was closed")
        XCTAssertEqual(f.store.undoManager.undoActionName, "Move to Space")
    }

    func testUndoMovesTheTabBackToTheIndexItLeft() throws {
        let f = try makeFixture()
        // A new tab opens at the top of the list, so the creation order is not
        // the list order — read the order off the space.
        for _ in 0..<3 { f.store.addTab(in: f.a, url: pageURL) }
        createdTabs.append(contentsOf: f.a.tabs)
        let order = f.a.tabs.map(\.id)
        let moved = f.a.tabs[1]

        XCTAssertTrue(f.store.moveTab(id: moved.id, from: f.a, to: f.b))
        XCTAssertEqual(f.a.tabs.map(\.id), [order[0], order[2]])

        f.store.undoManager.undo()

        XCTAssertEqual(f.a.tabs.map(\.id), order, "back where it was, in the middle")
        XCTAssertTrue(f.b.tabs.isEmpty)
        XCTAssertTrue(f.a.tabs[1] === moved, "still the same tab")
        XCTAssertEqual(f.store.undoManager.redoActionName, "Move to Space", "and redo moves it away again")
    }

    /// The store resolves both spaces by id when the undo actually runs, so a
    /// space deleted in between leaves the tab where it is instead of crashing
    /// or resurrecting a dead space.
    func testUndoOfAMoveIntoADeletedSpaceDoesNothing() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(tab)
        XCTAssertTrue(f.store.moveTab(id: tab.id, from: f.a, to: f.b))

        f.store.forceRemoveSpace(id: f.a.id)
        f.store.undoManager.undo()

        XCTAssertEqual(f.b.tabs.map(\.id), [tab.id], "the tab stays in the destination")
    }

    func testMovingTheSelectedTabLeavesTheSourceSelectionOnATabThatStillLivesThere() throws {
        let f = try makeFixture()
        let stay = f.store.addTab(in: f.a, url: pageURL)
        let tab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(contentsOf: [stay, tab])
        f.a.selectedTabID = tab.id

        XCTAssertTrue(f.store.moveTab(id: tab.id, from: f.a, to: f.b))

        XCTAssertEqual(f.a.selectedTabID, stay.id)
    }

    // MARK: - Split members

    func testMovingASplitMemberLeavesItsGroupAndDissolvesTheGroup() throws {
        let f = try makeFixture()
        let left = f.store.addTab(in: f.a, url: pageURL)
        let right = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(contentsOf: [left, right])
        f.store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: f.a)
        XCTAssertNotNil(left.splitGroupID, "precondition: a split")
        XCTAssertEqual(left.splitGroupID, right.splitGroupID)

        XCTAssertTrue(f.store.moveTab(id: right.id, from: f.a, to: f.b))

        XCTAssertNil(right.splitGroupID, "the mover leaves its group")
        XCTAssertNil(left.splitGroupID, "and the partner's undersized group dissolves")
        XCTAssertEqual(f.a.tabs.map(\.id), [left.id])
        XCTAssertEqual(f.b.tabs.map(\.id), [right.id])
    }

    /// Appending to the destination must not land between two members of a split
    /// that already lives there — the contiguity invariant every TabStore
    /// mutation keeps.
    func testAMovedTabLandsOutsideADestinationSplitGroup() throws {
        let f = try makeFixture()
        let left = f.store.addTab(in: f.b, url: pageURL)
        let right = f.store.addTab(in: f.b, url: pageURL)
        let mover = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(contentsOf: [left, right, mover])
        f.store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: f.b)

        XCTAssertTrue(f.store.moveTab(id: mover.id, from: f.a, to: f.b))

        XCTAssertEqual(f.b.tabs.map(\.id), [left.id, right.id, mover.id])
        XCTAssertEqual(left.splitGroupID, right.splitGroupID, "the destination's split is intact")
    }

    // MARK: - Pinned entries

    func testMoveLivePinnedEntryStaysPinnedAndKeepsItsTab() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(tab)
        f.store.pinTab(id: tab.id, in: f.a)
        let entry = try XCTUnwrap(f.a.pinnedEntries.first)
        let webView = try XCTUnwrap(tab.webView)

        XCTAssertTrue(f.store.movePinnedEntry(id: entry.id, from: f.a, to: f.b))

        XCTAssertTrue(f.a.pinnedEntries.isEmpty)
        XCTAssertEqual(f.b.pinnedEntries.map(\.id), [entry.id], "the same entry, still pinned")
        XCTAssertTrue(f.b.pinnedEntries.first?.tab === tab)
        XCTAssertTrue(tab.webView === webView)
        XCTAssertEqual(tab.spaceID, f.b.id)
        XCTAssertTrue(f.b.tabs.isEmpty, "and not as an ordinary tab")
        XCTAssertEqual(f.store.undoManager.undoActionName, "Move to Space")
    }

    func testMoveDormantPinnedEntryStaysDormant() throws {
        let f = try makeFixture()
        f.store.pinURL(pageURL, title: "Dormant", faviconURL: nil, in: f.a)
        let entry = try XCTUnwrap(f.a.pinnedEntries.first)
        XCTAssertNil(entry.tab, "precondition: dormant")

        XCTAssertTrue(f.store.movePinnedEntry(id: entry.id, from: f.a, to: f.b))

        XCTAssertEqual(f.b.pinnedEntries.map(\.id), [entry.id])
        XCTAssertNil(entry.tab, "still a tile, not materialized by the move")
        XCTAssertEqual(entry.pinnedURL, pageURL)
    }

    /// Pinned folders belong to their space, so the entry arrives at the
    /// destination's root — and goes home into its folder on undo.
    func testMovedPinnedEntryLandsAtTheDestinationRootAndUndoRestoresItsFolder() throws {
        let f = try makeFixture()
        let folder = f.store.addPinnedFolder(name: "Work", in: f.a)
        f.store.pinURL(pageURL, title: "Filed", faviconURL: nil, in: f.a)
        let entry = try XCTUnwrap(f.a.pinnedEntries.first)
        f.store.movePinnedTabToFolder(tabID: entry.id, folderID: folder.id, in: f.a)
        XCTAssertEqual(entry.folderID, folder.id, "precondition: inside a folder")
        let sortOrder = entry.sortOrder
        f.store.pinURL(pageURL, title: "Occupant", faviconURL: nil, in: f.b)
        // NSUndoManager groups by event, so the setup's own "Move Tab" undo
        // would be undone together with the move under test.
        f.store.undoManager.removeAllActions()

        XCTAssertTrue(f.store.movePinnedEntry(id: entry.id, from: f.a, to: f.b))
        XCTAssertNil(entry.folderID, "the source's folder does not exist over here")
        XCTAssertEqual(entry.sortOrder, 1, "and it takes a fresh sort order after the occupant")

        f.store.undoManager.undo()

        XCTAssertEqual(f.a.pinnedEntries.map(\.id), [entry.id])
        XCTAssertEqual(entry.folderID, folder.id)
        XCTAssertEqual(entry.sortOrder, sortOrder)
    }

    /// A pinned split is two entries; moving one is the pinned mirror of moving
    /// one normal split member, and the pair dissolves (§12).
    func testMovingOnePinnedSplitMemberDissolvesThePinnedSplit() throws {
        let f = try makeFixture()
        let left = f.store.addTab(in: f.a, url: pageURL)
        let right = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(contentsOf: [left, right])
        f.store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: f.a)
        let groupID = try XCTUnwrap(left.splitGroupID)
        f.store.pinSplitGroup(groupID: groupID, in: f.a)
        let entries = f.a.pinnedEntries
        XCTAssertEqual(entries.count, 2)
        XCTAssertNotNil(entries[0].splitGroupID, "precondition: a pinned split")

        XCTAssertTrue(f.store.movePinnedEntry(id: entries[1].id, from: f.a, to: f.b))

        XCTAssertNil(entries[1].splitGroupID)
        XCTAssertNil(entries[0].splitGroupID, "the partner's group dissolves")
        XCTAssertEqual(f.a.pinnedEntries.map(\.id), [entries[0].id])
        XCTAssertEqual(f.b.pinnedEntries.map(\.id), [entries[1].id])
    }

    // MARK: - Across profiles

    /// The web view was built from the source profile's data store and extension
    /// controller, and a configuration is only chosen at creation and at `wake`.
    /// So the tab has to release it and wake rebuilt from the destination.
    func testCrossProfileMoveSleepsTheTabWhichWakesFromTheDestinationProfile() throws {
        let f = makeSharedFixture("CrossProfile")
        let tab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(tab)
        XCTAssertNotNil(tab.webView, "precondition: live")

        XCTAssertTrue(f.store.moveTab(id: tab.id, from: f.a, to: f.c))

        XCTAssertTrue(f.c.tabs.first === tab, "the same tab object still")
        XCTAssertTrue(tab.isSleeping)
        XCTAssertNil(tab.webView, "it released the web view bound to the old profile")
        XCTAssertEqual(tab.spaceID, f.c.id)

        tab.wake()
        let webView = try XCTUnwrap(tab.webView)
        XCTAssertTrue(webView.configuration.websiteDataStore === f.other.dataStore,
                      "woken from the destination profile's data store")
        XCTAssertTrue(webView.configuration.webExtensionController === f.other.extensionController)
    }

    /// An ordinary page crosses profiles by `sleep(force:)`, which keeps the
    /// interaction state — so the back/forward list comes back on the wake,
    /// where the close-and-recreate dropped it.
    func testCrossProfileMoveKeepsAnOrdinaryPagesSavedSession() throws {
        let f = try makeFixture()
        let state = Data("session".utf8)
        let tab = BrowserTab(id: UUID(), title: "Page", url: pageURL, faviconURL: nil,
                             cachedInteractionState: state, spaceID: f.a.id)
        f.a.tabs.append(tab)
        createdTabs.append(tab)

        XCTAssertTrue(f.store.moveTab(id: tab.id, from: f.a, to: f.c))

        XCTAssertEqual(tab.currentInteractionStateData(), state,
                       "the session the tab was sleeping on travels with it")
        XCTAssertEqual(tab.spaceID, f.c.id)
    }

    // MARK: - Extension pages (AC #2)

    /// Within one profile an extension page keeps everything: the same tab, the
    /// same web view from its context's configuration, the same URL. Nothing has
    /// to be rebuilt, so there is nothing to rebuild wrongly.
    func testExtensionPageTabMovedWithinAProfileKeepsItsWebViewAndURL() async throws {
        let ext = try await makeExtension()
        let f = makeSharedFixture("ExtSameProfile")
        _ = f.profile.extensionController
        let context = try loadTestContext(ext, in: f.profile)
        let contextConfig = try XCTUnwrap(context.webViewConfiguration)
        let url = try extensionPageURL("options.html?same=1#frag", on: context.baseURL)
        let tab = f.store.addExtensionTab(in: f.a, url: url, configuration: contextConfig)
        createdTabs.append(tab)
        let webView = try XCTUnwrap(tab.webView)

        XCTAssertTrue(f.store.moveTab(id: tab.id, from: f.a, to: f.b))

        XCTAssertTrue(f.b.tabs.first === tab, "the same tab")
        XCTAssertTrue(tab.webView === webView, "with the context's own web view, which can load the scheme")
        XCTAssertFalse(tab.isSleeping, "nothing had to be rebuilt, so nothing had to be rebound")
        XCTAssertEqual(tab.webView?.url, url, "still showing the extension page")
        XCTAssertFalse(f.store.canReopenClosedTab(in: f.a))
    }

    /// Across profiles the page has to be rehomed: the destination profile runs
    /// its own context for the extension, on its own origin. The tab is
    /// retargeted onto it and wakes there (TASK-34).
    func testExtensionPageTabMovedToAProfileWithTheExtensionLoadsOnItsOrigin() async throws {
        let ext = try await makeExtension()
        let f = makeSharedFixture("ExtCrossProfile")
        _ = f.profile.extensionController
        _ = f.other.extensionController
        let source = try loadTestContext(ext, in: f.profile)
        let destination = try loadTestContext(ext, in: f.other)
        XCTAssertNotEqual(source.baseURL.host?.lowercased(), destination.baseURL.host?.lowercased(),
                          "precondition: each profile's context has its own origin")
        let url = try extensionPageURL("options.html?cross=1#frag", on: source.baseURL)
        let expected = try XCTUnwrap(rewriteExtensionPageURL(url, from: source.baseURL,
                                                             to: destination.baseURL))
        let tab = f.store.addExtensionTab(in: f.a, url: url,
                                          configuration: try XCTUnwrap(source.webViewConfiguration))
        createdTabs.append(tab)

        XCTAssertTrue(f.store.moveTab(id: tab.id, from: f.a, to: f.c))

        XCTAssertTrue(f.c.tabs.first === tab, "the same tab, not a rebuilt one")
        XCTAssertEqual(tab.url, expected, "retargeted onto the destination profile's origin")
        XCTAssertTrue(tab.isSleeping, "left for wake to pick the destination context's configuration")
        XCTAssertNil(tab.currentInteractionStateData(),
                     "its back/forward list lived on the old origin, so it is discarded")

        tab.wake()
        // `WKWebView.configuration` is a copy, so the configuration itself
        // cannot be compared by identity — the controller it carries can, and it
        // is the destination profile's, which only that context's configuration
        // has.
        XCTAssertTrue(tab.webView?.configuration.webExtensionController === f.other.extensionController,
                      "woken from the destination profile's context, the only one serving this origin")
        XCTAssertEqual(tab.webView?.url, expected)
    }

    /// A profile where the extension is off has only a pending origin, which a
    /// tab may not wait on: it would wake blank and the next restore would drop
    /// it. So the move is refused and nothing at all happens — the tab keeps its
    /// space, its web view and its URL, and the store can say why (TASK-37).
    func testExtensionPageTabMovedToAProfileWithoutTheExtensionIsRefused() async throws {
        let ext = try await makeExtension()
        let f = makeSharedFixture("ExtRefused")
        _ = f.profile.extensionController
        let context = try loadTestContext(ext, in: f.profile)
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: f.other.id, enabled: false)
        XCTAssertNil(f.other.extensionContext(for: ext.id), "precondition: off in the destination profile")
        let url = try extensionPageURL("options.html?refused=1", on: context.baseURL)
        let tab = f.store.addExtensionTab(in: f.a, url: url,
                                          configuration: try XCTUnwrap(context.webViewConfiguration))
        createdTabs.append(tab)
        let webView = try XCTUnwrap(tab.webView)

        XCTAssertFalse(f.store.moveTab(id: tab.id, from: f.a, to: f.c))

        XCTAssertEqual(f.a.tabs.map(\.id), [tab.id], "the tab did not move")
        XCTAssertTrue(f.c.tabs.isEmpty)
        XCTAssertTrue(tab.webView === webView, "and nothing was torn down")
        XCTAssertEqual(tab.url, url)
        XCTAssertEqual(tab.spaceID, f.a.id)
        XCTAssertFalse(f.store.undoManager.canUndo, "a refused move registers no undo")
        XCTAssertNotNil(f.store.dormantTileRefusal(url: url, in: f.other),
                        "the window has a reason to show")
    }

    /// A dormant tile *may* wait on a pending origin — that is what a disabled
    /// extension's pinned entry is — so the pinned move is allowed where the tab
    /// move is refused, and a later enable in the destination profile moves the
    /// entry onto the new origin.
    func testDormantExtensionPinnedEntryMovesToAProfileWhereTheExtensionIsOff() async throws {
        let ext = try await makeExtension()
        let f = makeSharedFixture("ExtPinnedOff")
        _ = f.profile.extensionController
        let context = try loadTestContext(ext, in: f.profile)
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: f.other.id, enabled: false)
        let url = try extensionPageURL("options.html?pinned=off", on: context.baseURL)
        f.store.pinURL(url, title: "Options", faviconURL: nil, in: f.a)
        let entry = try XCTUnwrap(f.a.pinnedEntries.first)

        XCTAssertTrue(f.store.movePinnedEntry(id: entry.id, from: f.a, to: f.c))

        XCTAssertEqual(f.c.pinnedEntries.map(\.id), [entry.id], "still pinned, still dormant")
        XCTAssertNil(entry.tab)
        XCTAssertEqual(entry.pinnedURL, url)
        XCTAssertTrue(f.other.isAwaitingExtensionContext(url),
                      "waiting on its origin in the destination profile")

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: f.other.id, enabled: true)
        let newBase = try XCTUnwrap(f.other.extensionContext(for: ext.id)?.baseURL)
        XCTAssertEqual(entry.pinnedURL, rewriteExtensionPageURL(url, from: context.baseURL, to: newBase),
                       "enabling it there moves the entry onto that profile's origin")
    }

    /// An extension nothing has installed can never serve the page again, so
    /// even the pinned move is refused and the entry stays where it is.
    func testExtensionPinnedEntryMoveIsRefusedWhenTheExtensionIsUninstalled() async throws {
        let ext = try await makeExtension()
        let f = makeSharedFixture("ExtPinnedGone")
        _ = f.profile.extensionController
        let context = try loadTestContext(ext, in: f.profile)
        let url = try extensionPageURL("options.html?pinned=gone", on: context.baseURL)
        f.store.pinURL(url, title: "Options", faviconURL: nil, in: f.a)
        let entry = try XCTUnwrap(f.a.pinnedEntries.first)
        ExtensionManager.shared.uninstall(id: ext.id)

        XCTAssertFalse(f.store.movePinnedEntry(id: entry.id, from: f.a, to: f.c))

        XCTAssertEqual(f.a.pinnedEntries.map(\.id), [entry.id], "the tile is kept where it was")
        XCTAssertEqual(entry.pinnedURL, url)
        XCTAssertTrue(f.c.pinnedEntries.isEmpty)
        XCTAssertFalse(f.store.undoManager.canUndo)
        XCTAssertEqual(f.store.dormantTileRefusal(url: url, in: f.other), .extensionUnavailable)
    }

    // MARK: - Refused up front

    func testMoveToTheSameSpaceIsARefusalThatChangesNothing() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(tab)

        XCTAssertFalse(f.store.moveTab(id: tab.id, from: f.a, to: f.a))
        XCTAssertFalse(f.store.movePinnedEntry(id: tab.id, from: f.a, to: f.a))

        XCTAssertEqual(f.a.tabs.map(\.id), [tab.id])
        XCTAssertFalse(f.store.undoManager.canUndo)
    }

    /// Moving the tab itself would take an incognito web view and its whole
    /// session history into a persistent profile, which `scheduleSave` then
    /// writes to the session database. The sidebar hides the menu in an
    /// incognito window; the store refuses the move regardless.
    func testMoveOutOfAnIncognitoSpaceIsRefused() throws {
        let f = try makeFixture()
        let incognito = f.store.addIncognitoSpace()
        let tab = f.store.addTab(in: incognito, url: pageURL)
        createdTabs.append(tab)
        f.store.pinURL(pageURL, title: "Pinned", faviconURL: nil, in: incognito)
        let entry = try XCTUnwrap(incognito.pinnedEntries.first)

        XCTAssertFalse(f.store.moveTab(id: tab.id, from: incognito, to: f.a))
        XCTAssertFalse(f.store.movePinnedEntry(id: entry.id, from: incognito, to: f.a))

        XCTAssertEqual(incognito.tabs.map(\.id), [tab.id])
        XCTAssertEqual(incognito.pinnedEntries.map(\.id), [entry.id])
        XCTAssertTrue(f.a.tabs.isEmpty)
        XCTAssertTrue(f.a.pinnedEntries.isEmpty)

        let normalTab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(normalTab)
        XCTAssertFalse(f.store.moveTab(id: normalTab.id, from: f.a, to: incognito), "nor the other way")
        XCTAssertEqual(f.a.tabs.map(\.id), [normalTab.id])
        XCTAssertEqual(incognito.tabs.map(\.id), [tab.id])

        f.store.removeIncognitoSpace(id: incognito.id)
    }

    func testMoveOfAnUnknownTabOrEntryIsARefusal() throws {
        let f = try makeFixture()
        XCTAssertFalse(f.store.moveTab(id: UUID(), from: f.a, to: f.b))
        XCTAssertFalse(f.store.movePinnedEntry(id: UUID(), from: f.a, to: f.b))
        XCTAssertFalse(f.store.undoManager.canUndo)
    }

    // MARK: - Session persistence

    /// The session row follows the space the tab is in, so the move must not
    /// leave a row under the source.
    func testSessionSaveRecordsAMovedTabUnderTheDestinationSpace() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.a, url: pageURL)
        createdTabs.append(tab)
        XCTAssertTrue(f.store.moveTab(id: tab.id, from: f.a, to: f.b))

        f.store.saveNow()

        let session = try XCTUnwrap(f.db.loadSession())
        let inB = session.spaces.first { $0.0.id == f.b.id.uuidString }?.1 ?? []
        let inA = session.spaces.first { $0.0.id == f.a.id.uuidString }?.1 ?? []
        XCTAssertEqual(inB.first { $0.id == tab.id.uuidString }?.spaceID, f.b.id.uuidString)
        XCTAssertFalse(inA.contains { $0.id == tab.id.uuidString }, "and nothing under the source")
    }
}
