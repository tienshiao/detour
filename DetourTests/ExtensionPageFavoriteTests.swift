import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-34: moving a favourite out of the favourites bar — into the tab list
/// (`restoreFavoriteAsTab`) or the pinned section (`restoreFavoriteAsPinned`) —
/// and a dormant pinned entry into the favourites bar (`addFavoriteFromEntry`).
///
/// A live favourite's backing tab moves as it is. A dormant extension page is
/// built through `makeTab(loading:)`, so it wakes into its context's
/// configuration (the space configuration cannot load the scheme), on its URL
/// rehomed onto the extension's live origin. A disabled extension's page may only
/// become a dormant pinned entry; an uninstalled one's move is refused and the
/// favourite stays.
///
/// These run against the shared `TabStore` and `ExtensionManager` (the test
/// scheme points `DETOUR_DATA_DIR` at an isolated directory), with real
/// `WKWebExtension` contexts: `BrowserTab.wake` resolves its space from the
/// shared store, and disable, enable and uninstall go through production paths.
@MainActor
final class ExtensionPageFavoriteTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []

    override func tearDown() {
        for spaceID in createdSpaceIDs {
            guard let space = TabStore.shared.space(withID: spaceID) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: spaceID)
        }
        createdSpaceIDs.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        for profile in createdProfiles {
            for favorite in profile.favorites { favorite.tab?.teardown() }
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        createdProfiles.removeAll()
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

    /// A minimal MV3 extension with an options page and no background content,
    /// registered with the shared `ExtensionManager` and database.
    private func makeExtension() async throws -> WebExtension {
        let ext = try await makeOptionsPageTestExtension(idPrefix: "page-favorite",
                                                         name: "Page Favorite Test")
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(ext.id)
        installTestExtension(ext, in: AppDatabase.shared,
                             manifestJSON: try testExtensionManifestData(ext))
        return ext
    }

    private struct Fixture {
        let ext: WebExtension
        let store: TabStore
        let profile: Profile
        let space: Space
        let context: WKWebExtensionContext
    }

    private func makeFixture(_ name: String) async throws -> Fixture {
        let ext = try await makeExtension()
        let store = TabStore.shared
        let profile = store.addProfile(name: "Favorite \(name)")
        createdProfiles.append(profile)
        let space = store.addSpace(name: "Favorite \(name)", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        _ = profile.extensionController
        let context = try loadTestContext(ext, in: profile)
        store.undoManager.removeAllActions()
        return Fixture(ext: ext, store: store, profile: profile, space: space, context: context)
    }

    /// Adds a dormant favourite on `url` and returns it.
    private func dormantFavorite(_ url: URL, title: String = "Fav", in f: Fixture) throws -> Favorite {
        XCTAssertTrue(f.store.addFavoriteFromEntry(url: url, title: title, faviconURL: nil, favicon: nil,
                                                   profileID: f.profile.id, at: f.profile.favorites.count))
        let favorite = try XCTUnwrap(f.profile.favorites.last)
        XCTAssertNil(favorite.tab, "precondition: dormant")
        return favorite
    }

    /// Reloads the context the way production does when its background content
    /// fails (`recoverFromBackgroundLoadFailure`): a new origin, with every page
    /// and tile of the profile retargeted onto it.
    private func reloadContext(_ f: Fixture) throws -> URL {
        f.profile.recoverFromBackgroundLoadFailure(extensionID: f.ext.id, failedContext: f.context)
        let newBase = try XCTUnwrap(f.profile.extensionContext(for: f.ext.id)?.baseURL)
        XCTAssertNotEqual(newBase.host?.lowercased(), f.context.baseURL.host?.lowercased(),
                          "precondition: the reloaded context has a new origin")
        return newBase
    }

    // MARK: - Dormant extension page -> tab list

    func testDormantFavoriteToTabAfterAContextReloadLoadsOnTheNewOrigin() async throws {
        let f = try await makeFixture("ToTab")
        let url = try extensionPageURL("options.html?fav=tab#frag", on: f.context.baseURL)
        let favorite = try dormantFavorite(url, in: f)
        let newBase = try reloadContext(f)
        let expected = try XCTUnwrap(rewriteExtensionPageURL(url, from: f.context.baseURL, to: newBase))

        XCTAssertEqual(f.store.favoriteDropTargets(id: favorite.id, profileID: f.profile.id), .all)
        XCTAssertTrue(f.store.restoreFavoriteAsTab(id: favorite.id, profileID: f.profile.id, in: f.space, at: 0))

        XCTAssertTrue(f.profile.favorites.isEmpty, "the favourite moved")
        let tab = try XCTUnwrap(f.space.tabs.first)
        XCTAssertEqual(tab.url, expected)
        XCTAssertTrue(tab.isSleeping, "an extension page is created sleeping, for wake to build")
        tab.wake()
        XCTAssertEqual(tab.webView?.url, expected, "woken from the context's configuration onto the live origin")
        XCTAssertFalse(f.store.undoManager.canUndo, "favourite moves register no undo")
    }

    /// A favourite restored from the previous launch waits on a dead origin
    /// registered as pending (TASK-24). Moved after its context has loaded but
    /// before the resolution pass, it is rehomed onto the live origin by the move.
    func testDormantFavoriteOnAPendingOriginIsRehomedWhenMoved() async throws {
        let f = try await makeFixture("Pending")
        let deadHost = UUID().uuidString.lowercased()
        let deadBase = try XCTUnwrap(URL(string: "webkit-extension://\(deadHost)/"))
        f.profile.registerPendingExtensionOrigin(host: deadHost, extensionID: f.ext.id)
        let tabURL = try extensionPageURL("options.html?to=tab", on: deadBase)
        let pinnedURL = try extensionPageURL("options.html?to=pinned", on: deadBase)
        // Restored as `restoreSession` does: the stored URL, as it was saved.
        let toTab = Favorite(url: tabURL, title: "To tab")
        let toPinned = Favorite(url: pinnedURL, title: "To pinned")
        f.profile.favorites.append(contentsOf: [toTab, toPinned])
        let live = f.context.baseURL

        XCTAssertTrue(f.store.restoreFavoriteAsTab(id: toTab.id, profileID: f.profile.id, in: f.space, at: 0))
        let tab = try XCTUnwrap(f.space.tabs.first)
        let expectedTabURL = try XCTUnwrap(rewriteExtensionPageURL(tabURL, from: deadBase, to: live))
        XCTAssertEqual(tab.url, expectedTabURL)
        tab.wake()
        XCTAssertEqual(tab.webView?.url, expectedTabURL)

        XCTAssertTrue(f.store.restoreFavoriteAsPinned(id: toPinned.id, profileID: f.profile.id, in: f.space, at: 0))
        let entry = try XCTUnwrap(f.space.pinnedEntries.first)
        XCTAssertEqual(entry.pinnedURL, rewriteExtensionPageURL(pinnedURL, from: deadBase, to: live))
        XCTAssertTrue(f.profile.favorites.isEmpty)
    }

    // MARK: - Dormant extension page -> pinned section

    func testDormantFavoriteToPinnedAfterAContextReloadLoadsOnTheNewOrigin() async throws {
        let f = try await makeFixture("ToPinned")
        let url = try extensionPageURL("options.html?fav=pinned", on: f.context.baseURL)
        let favorite = try dormantFavorite(url, in: f)
        let newBase = try reloadContext(f)
        let expected = try XCTUnwrap(rewriteExtensionPageURL(url, from: f.context.baseURL, to: newBase))

        XCTAssertTrue(f.store.restoreFavoriteAsPinned(id: favorite.id, profileID: f.profile.id, in: f.space, at: 0))

        XCTAssertTrue(f.profile.favorites.isEmpty)
        let entry = try XCTUnwrap(f.space.pinnedEntries.first)
        XCTAssertEqual(entry.pinnedURL, expected)
        XCTAssertNil(entry.tab, "a dormant favourite becomes a dormant entry")

        f.store.activatePinnedEntry(id: entry.id, in: f.space)
        let tab = try XCTUnwrap(entry.tab)
        XCTAssertEqual(tab.url, expected)
        tab.wake()
        XCTAssertEqual(tab.webView?.url, expected, "activating it loads the page on the live origin")
        XCTAssertFalse(f.store.undoManager.canUndo, "favourite moves register no undo")
    }

    // MARK: - Live favourite

    func testLiveFavoriteMovesItsBackingTabAsIs() async throws {
        let f = try await makeFixture("Live")
        let config = try XCTUnwrap(f.context.webViewConfiguration)
        let tabURL = try extensionPageURL("options.html?live=tab", on: f.context.baseURL)
        let pinnedURL = try extensionPageURL("options.html?live=pinned", on: f.context.baseURL)

        let toTab = f.store.addExtensionTab(in: f.space, url: tabURL, configuration: config)
        f.store.detachTab(id: toTab.id, from: f.space)
        f.store.addFavorite(from: toTab, profileID: f.profile.id)
        let toPinned = f.store.addExtensionTab(in: f.space, url: pinnedURL, configuration: config)
        f.store.detachTab(id: toPinned.id, from: f.space)
        f.store.addFavorite(from: toPinned, profileID: f.profile.id)
        let webViewForTab = try XCTUnwrap(toTab.webView)
        XCTAssertEqual(f.profile.favorites.map { $0.tab?.id }, [toTab.id, toPinned.id], "precondition: live")
        XCTAssertTrue(f.space.tabs.isEmpty)

        for favorite in f.profile.favorites {
            XCTAssertEqual(f.store.favoriteDropTargets(id: favorite.id, profileID: f.profile.id), .all)
        }

        XCTAssertTrue(f.store.restoreFavoriteAsTab(id: f.profile.favorites[0].id, profileID: f.profile.id,
                                                   in: f.space, at: 0))
        XCTAssertEqual(f.space.tabs.map(\.id), [toTab.id], "the same tab object moves")
        XCTAssertTrue(f.space.tabs.first === toTab)
        XCTAssertTrue(toTab.webView === webViewForTab, "with its web view")
        XCTAssertEqual(toTab.webView?.url, tabURL)

        XCTAssertTrue(f.store.restoreFavoriteAsPinned(id: f.profile.favorites[0].id, profileID: f.profile.id,
                                                      in: f.space, at: 0))
        let entry = try XCTUnwrap(f.space.pinnedEntries.first)
        XCTAssertTrue(entry.tab === toPinned)
        XCTAssertEqual(entry.pinnedURL, pinnedURL)
        XCTAssertTrue(f.profile.favorites.isEmpty)
    }

    // MARK: - Disabled / uninstalled extension

    /// A disabled extension's dormant favourite may become a dormant pinned
    /// entry, kept on its origin registered as pending so an enable moves it. It
    /// may not become a tab: one would sit unloaded on the pending origin, and
    /// the next restore drops open tabs of a disabled extension.
    func testDisabledDormantFavoriteMovesOnlyToPinnedAndResolvesOnEnable() async throws {
        let f = try await makeFixture("Disabled")
        let url = try extensionPageURL("options.html?disabled=1", on: f.context.baseURL)
        let favorite = try dormantFavorite(url, in: f)

        ExtensionManager.shared.setEnabled(id: f.ext.id, profileID: f.profile.id, enabled: false)
        XCTAssertNil(f.profile.extensionContext(for: f.ext.id), "precondition: unloaded")

        XCTAssertEqual(f.store.favoriteDropTargets(id: favorite.id, profileID: f.profile.id), .pinned)
        XCTAssertFalse(f.store.restoreFavoriteAsTab(id: favorite.id, profileID: f.profile.id, in: f.space, at: 0))
        XCTAssertTrue(f.space.tabs.isEmpty, "no dead tab")
        XCTAssertEqual(f.profile.favorites.map(\.id), [favorite.id], "the favourite stays")
        XCTAssertEqual(favorite.url, url)

        XCTAssertTrue(f.store.restoreFavoriteAsPinned(id: favorite.id, profileID: f.profile.id, in: f.space, at: 0))
        XCTAssertTrue(f.profile.favorites.isEmpty)
        let entry = try XCTUnwrap(f.space.pinnedEntries.first)
        XCTAssertEqual(entry.pinnedURL, url)
        XCTAssertNil(entry.tab)
        XCTAssertTrue(f.profile.isAwaitingExtensionContext(url), "it waits on its pending origin")

        ExtensionManager.shared.setEnabled(id: f.ext.id, profileID: f.profile.id, enabled: true)
        let newBase = try XCTUnwrap(f.profile.extensionContext(for: f.ext.id)?.baseURL)
        XCTAssertEqual(entry.pinnedURL, rewriteExtensionPageURL(url, from: f.context.baseURL, to: newBase),
                       "enabling the extension moves the entry onto the new origin")
    }

    /// An uninstalled extension's dormant favourite can never load again: every
    /// move out of the favourites bar is refused and it stays where it is, as a
    /// dormant pinned entry of that extension is refused a move into the bar.
    func testUninstalledDormantFavoriteIsRefusedAndStays() async throws {
        let f = try await makeFixture("Uninstalled")
        let url = try extensionPageURL("options.html?gone=1", on: f.context.baseURL)
        let pinnedURL = try extensionPageURL("options.html?gone=pinned", on: f.context.baseURL)
        let favorite = try dormantFavorite(url, in: f)

        ExtensionManager.shared.uninstall(id: f.ext.id)
        XCTAssertNil(f.profile.extensionContext(for: f.ext.id), "precondition: unloaded")

        XCTAssertEqual(f.store.favoriteDropTargets(id: favorite.id, profileID: f.profile.id), [])
        XCTAssertFalse(f.store.restoreFavoriteAsTab(id: favorite.id, profileID: f.profile.id, in: f.space, at: 0))
        XCTAssertFalse(f.store.restoreFavoriteAsPinned(id: favorite.id, profileID: f.profile.id, in: f.space, at: 0))
        XCTAssertTrue(f.space.tabs.isEmpty, "no dead tab")
        XCTAssertTrue(f.space.pinnedEntries.isEmpty, "no dead tile")
        XCTAssertEqual(f.profile.favorites.map(\.id), [favorite.id], "the favourite stays")
        XCTAssertEqual(favorite.url, url)

        XCTAssertFalse(f.store.addFavoriteFromEntry(url: pinnedURL, title: "Gone", faviconURL: nil, favicon: nil,
                                                    profileID: f.profile.id, at: 0),
                       "a dormant pinned entry of the extension is refused a move into the bar")
        XCTAssertEqual(f.profile.favorites.map(\.id), [favorite.id])
    }

    /// Clicking a dormant favourite of a disabled extension must not build a tab:
    /// it would sit unloaded on the pending origin, wake blank, and be dropped at
    /// the next restore. The favourite stays dormant instead.
    func testActivateFavoriteOfADisabledExtensionLeavesItDormant() async throws {
        let f = try await makeFixture("ActivateFav")
        let url = try extensionPageURL("options.html?activate=fav", on: f.context.baseURL)
        let favorite = try dormantFavorite(url, in: f)
        ExtensionManager.shared.setEnabled(id: f.ext.id, profileID: f.profile.id, enabled: false)

        f.store.activateFavorite(id: favorite.id, profileID: f.profile.id, in: f.space)

        XCTAssertNil(favorite.tab, "no blank backing tab")
        XCTAssertTrue(f.space.tabs.isEmpty)
        XCTAssertEqual(f.profile.favorites.map(\.id), [favorite.id], "the favourite stays")
    }

    /// A dormant pinned entry of a disabled extension cannot become a tab either:
    /// activating it is a no-op, and unpinning it leaves the tile pinned rather
    /// than removing it and dropping a blank tab into the tab list.
    func testDormantEntryOfADisabledExtensionIsNeitherActivatedNorUnpinned() async throws {
        let f = try await makeFixture("ActivateEntry")
        let url = try extensionPageURL("options.html?activate=entry", on: f.context.baseURL)
        let favorite = try dormantFavorite(url, in: f)
        ExtensionManager.shared.setEnabled(id: f.ext.id, profileID: f.profile.id, enabled: false)
        XCTAssertTrue(f.store.restoreFavoriteAsPinned(id: favorite.id, profileID: f.profile.id, in: f.space, at: 0))
        let entry = try XCTUnwrap(f.space.pinnedEntries.first)
        XCTAssertNil(entry.tab, "precondition: dormant")

        f.store.activatePinnedEntry(id: entry.id, in: f.space)
        XCTAssertNil(entry.tab, "no blank backing tab")

        f.store.unpinTab(id: entry.id, in: f.space)
        XCTAssertEqual(f.space.pinnedEntries.map(\.id), [entry.id], "the entry stays pinned, untouched")
        XCTAssertEqual(entry.pinnedURL, url)
        XCTAssertTrue(f.space.tabs.isEmpty, "nothing lands in the tab list")
        XCTAssertFalse(f.store.undoManager.canUndo, "a refused unpin registers no undo")
    }

    // MARK: - Ordinary pages

    func testOrdinaryFavoritesMoveUnchanged() async throws {
        let f = try await makeFixture("Ordinary")
        let tabURL = try XCTUnwrap(URL(string: "https://example.com/path?q=1#frag"))
        let pinnedURL = try XCTUnwrap(URL(string: "https://example.org/"))
        let liveURL = try XCTUnwrap(URL(string: "https://example.net/"))
        let toTab = try dormantFavorite(tabURL, title: "Tab", in: f)
        let toPinned = try dormantFavorite(pinnedURL, title: "Pinned", in: f)
        let liveTab = BrowserTab(id: UUID(), title: "Live", url: liveURL, faviconURL: nil,
                                 cachedInteractionState: Data([1, 2, 3]), spaceID: f.space.id)
        f.store.addFavorite(from: liveTab, profileID: f.profile.id)
        let live = try XCTUnwrap(f.profile.favorites.last)
        XCTAssertEqual(toTab.url, tabURL, "addFavoriteFromEntry keeps an ordinary URL")

        for favorite in f.profile.favorites {
            XCTAssertEqual(f.store.favoriteDropTargets(id: favorite.id, profileID: f.profile.id), .all)
        }

        XCTAssertTrue(f.store.restoreFavoriteAsTab(id: toTab.id, profileID: f.profile.id, in: f.space, at: 0))
        let tab = try XCTUnwrap(f.space.tabs.first)
        XCTAssertEqual(tab.url, tabURL)
        XCTAssertFalse(tab.isSleeping, "built live from the space configuration, as before")
        XCTAssertEqual(tab.spaceID, f.space.id)

        XCTAssertTrue(f.store.restoreFavoriteAsPinned(id: toPinned.id, profileID: f.profile.id, in: f.space, at: 0))
        let entry = try XCTUnwrap(f.space.pinnedEntries.first)
        XCTAssertEqual(entry.pinnedURL, pinnedURL)
        XCTAssertNil(entry.tab)

        XCTAssertTrue(f.store.restoreFavoriteAsTab(id: live.id, profileID: f.profile.id, in: f.space, at: 1))
        XCTAssertTrue(f.space.tabs.last === liveTab, "a live ordinary tab moves as it is, interaction state included")
        XCTAssertTrue(liveTab.isSleeping)
        XCTAssertEqual(liveTab.url, liveURL)
        XCTAssertTrue(f.profile.favorites.isEmpty)
        XCTAssertFalse(f.store.undoManager.canUndo, "favourite moves register no undo")
    }
}
