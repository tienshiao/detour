import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-24: WebKit mints a fresh `webkit-extension://<UUID>/` base URL for every
/// context load, so a persisted extension page URL is dead after a relaunch. The
/// extension id is saved alongside it; restore drops pages whose extension is no
/// longer installed or enabled, and `Profile.resolvePendingExtensionPages` moves
/// the rest onto the extension's context once it is loaded.
///
/// The round trips use two `TabStore`s on one in-memory `AppDatabase` (the second
/// store is the relaunch) and real `WKWebExtension` contexts, so each launch gets
/// the base URL WebKit actually hands out.
@MainActor
final class ExtensionPagePersistenceTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var loadedProfiles: [Profile] = []
    private var sharedSpaceIDs: [UUID] = []
    private var sharedProfiles: [Profile] = []

    override func tearDown() {
        for spaceID in sharedSpaceIDs {
            guard let space = TabStore.shared.space(withID: spaceID) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: spaceID)
        }
        sharedSpaceIDs.removeAll()
        for profile in sharedProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        sharedProfiles.removeAll()
        for profile in loadedProfiles { profile.unloadAllExtensions() }
        loadedProfiles.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(dbQueue: DatabaseQueue())
    }

    /// A minimal MV3 extension with an options page and no background content.
    private func makeExtension() async throws -> WebExtension {
        let id = "page-persist-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Page Persistence Test",
            "version": "1.0.0",
            "options_ui": { "page": "options.html" }
        }
        """
        try manifestJSON.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html><body>options</body></html>"
            .write(to: dir.appendingPathComponent("options.html"), atomically: true, encoding: .utf8)

        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = try await WKWebExtension(resourceBaseURL: dir)
        return ext
    }

    private func install(_ ext: WebExtension, in db: AppDatabase) {
        db.saveExtension(ExtensionRecord(
            id: ext.id, name: ext.manifest.name, version: ext.manifest.version,
            manifestJSON: Data("{}".utf8), basePath: ext.basePath.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970
        ))
    }

    private func loadContext(_ ext: WebExtension, in profile: Profile) throws -> WKWebExtensionContext {
        _ = profile.loadExtensionContext(ext)
        loadedProfiles.append(profile)
        return try XCTUnwrap(profile.extensionContext(for: ext.id), "the context should load")
    }

    private func sleepingTab(_ url: URL, title: String = "Page", in space: Space) -> BrowserTab {
        BrowserTab(id: UUID(), title: title, url: url, faviconURL: nil,
                   cachedInteractionState: nil, spaceID: space.id)
    }

    /// An extension page URL with an escaped query and a fragment, which must
    /// both survive the rewrite untouched.
    private func pageURL(_ path: String, on base: URL) throws -> URL {
        try XCTUnwrap(URL(string: path, relativeTo: base)?.absoluteURL)
    }

    private func restoredStore(_ db: AppDatabase) -> TabStore {
        let store = TabStore(appDB: db)
        _ = store.restoreSession()
        return store
    }

    // MARK: - Classifier

    func testClassifierLeavesOrdinaryURLsAlone() {
        XCTAssertEqual(classifyPersistedExtensionPage(url: URL(string: "https://example.com/"), extensionID: nil,
                                                      installedExtensionIDs: [], enabledExtensionIDs: []),
                       .notExtensionPage)
        XCTAssertEqual(classifyPersistedExtensionPage(url: nil, extensionID: "x",
                                                      installedExtensionIDs: ["x"], enabledExtensionIDs: ["x"]),
                       .notExtensionPage)
    }

    func testClassifierRestoresAnEnabledExtensionsPage() {
        let url = URL(string: "webkit-extension://ABCD-1234/options.html#a")
        XCTAssertEqual(classifyPersistedExtensionPage(url: url, extensionID: "ext",
                                                      installedExtensionIDs: ["ext"], enabledExtensionIDs: ["ext"]),
                       .restorable(extensionID: "ext", originHost: "abcd-1234"))
    }

    func testClassifierKeepsAnInstalledButDisabledExtensionsPageDistinct() {
        let url = URL(string: "webkit-extension://ABCD/options.html")
        let page = classifyPersistedExtensionPage(url: url, extensionID: "ext",
                                                  installedExtensionIDs: ["ext"], enabledExtensionIDs: ["other"])
        XCTAssertEqual(page, .disabled(extensionID: "ext", originHost: "abcd"))
        XCTAssertEqual(page.pendingOrigin?.extensionID, "ext")
        XCTAssertEqual(page.pendingOrigin?.originHost, "abcd")
    }

    func testClassifierDropsUninstalledAndLegacyPages() {
        let url = URL(string: "webkit-extension://abcd/options.html")
        XCTAssertEqual(classifyPersistedExtensionPage(url: url, extensionID: "gone",
                                                      installedExtensionIDs: ["other"], enabledExtensionIDs: ["other"]),
                       .unavailable, "an extension no longer installed")
        XCTAssertEqual(classifyPersistedExtensionPage(url: url, extensionID: "gone",
                                                      installedExtensionIDs: [], enabledExtensionIDs: ["gone"]),
                       .unavailable, "installation decides, whatever a stale enabled set says")
        XCTAssertEqual(classifyPersistedExtensionPage(url: url, extensionID: nil,
                                                      installedExtensionIDs: ["other"], enabledExtensionIDs: ["other"]),
                       .unavailable, "a row saved before the extension id was persisted")
        XCTAssertEqual(classifyPersistedExtensionPage(url: url, extensionID: "",
                                                      installedExtensionIDs: [""], enabledExtensionIDs: [""]),
                       .unavailable)
        XCTAssertNil(PersistedExtensionPage.unavailable.pendingOrigin)
    }

    // MARK: - Round trip

    func testExtensionPagesSurviveARelaunchInEveryPlaceTheyLive() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension()
        install(ext, in: db)

        // Launch 1: an extension page as a tab, a pinned entry (live, with its
        // backing tab on the page) and a dormant one, a favourite (live and
        // dormant), and a closed tab.
        let store1 = TabStore(appDB: db)
        let profile1 = store1.addProfile(name: "Persist")
        let space1 = store1.addSpace(name: "Persist", emoji: "🧪", colorHex: "007AFF", profileID: profile1.id)
        let base1 = try loadContext(ext, in: profile1).baseURL

        let tabURL = try pageURL("options.html?next=https%3A%2F%2Fa.example%2F#section", on: base1)
        let pinnedLiveURL = try pageURL("options.html?pinned=live", on: base1)
        let pinnedDormantURL = try pageURL("options.html?pinned=dormant", on: base1)
        let favLiveURL = try pageURL("options.html?fav=live", on: base1)
        let favDormantURL = try pageURL("options.html?fav=dormant", on: base1)
        let closedURL = try pageURL("options.html?closed=1", on: base1)
        let webURL = try XCTUnwrap(URL(string: "https://example.com/"))

        let tab = sleepingTab(tabURL, title: "Options", in: space1)
        space1.tabs.append(tab)
        space1.tabs.append(sleepingTab(webURL, title: "Web", in: space1))
        space1.selectedTabID = tab.id

        let pinnedTab = sleepingTab(pinnedLiveURL, in: space1)
        space1.tabs.append(pinnedTab)
        store1.pinTab(id: pinnedTab.id, in: space1)
        store1.pinURL(pinnedDormantURL, title: "Dormant", faviconURL: nil, in: space1)

        store1.addFavorite(from: sleepingTab(favLiveURL, in: space1), profileID: profile1.id)
        store1.addFavoriteFromEntry(url: favDormantURL, title: "Fav", faviconURL: nil, favicon: nil,
                                    profileID: profile1.id, at: 1)

        let closed = sleepingTab(closedURL, in: space1)
        space1.tabs.append(closed)
        store1.closeTab(id: closed.id, in: space1)

        store1.saveNow()

        // The id is persisted alongside every extension URL, and only those.
        let tabRecords = try await db.dbQueue.read { try TabRecord.fetchAll($0) }
        XCTAssertEqual(Set(tabRecords.filter { $0.url == tabURL.absoluteString }.map(\.extensionID)), [ext.id])
        XCTAssertEqual(tabRecords.first { $0.url == webURL.absoluteString }?.extensionID, nil as String?)
        XCTAssertEqual(tabRecords.first { $0.url == pinnedLiveURL.absoluteString }?.extensionID, ext.id,
                       "the pinned entry's backing tab")
        XCTAssertEqual(tabRecords.first { $0.url == favLiveURL.absoluteString }?.extensionID, ext.id,
                       "the favourite's backing tab")
        let pinnedRecords = try await db.dbQueue.read { try PinnedTabRecord.fetchAll($0) }
        XCTAssertEqual(pinnedRecords.map(\.extensionID), [ext.id, ext.id])
        let favoriteRecords = try await db.dbQueue.read { try FavoriteRecord.fetchAll($0) }
        XCTAssertEqual(favoriteRecords.map(\.extensionID), [ext.id, ext.id])
        let closedRecords = try await db.dbQueue.read { try ClosedTabRecord.fetchAll($0) }
        XCTAssertEqual(closedRecords.map(\.extensionID), [ext.id])

        profile1.unloadAllExtensions()

        // Launch 2: restore runs before any context is loaded, as in the app.
        let store2 = restoredStore(db)
        let profile2 = try XCTUnwrap(store2.profile(withID: profile1.id))
        let space2 = try XCTUnwrap(store2.space(withID: space1.id))
        let oldHost = try XCTUnwrap(base1.host)

        XCTAssertEqual(space2.tabs.map(\.url), [tabURL, webURL])
        let restoredTab = space2.tabs[0]
        XCTAssertTrue(restoredTab.isSleeping, "an extension page is never restored eagerly, selected or not")
        XCTAssertNil(restoredTab.webView)
        XCTAssertEqual(space2.selectedTabID, restoredTab.id)
        XCTAssertEqual(profile2.pendingExtensionOrigins, [oldHost.lowercased(): ext.id])
        XCTAssertTrue(profile2.isAwaitingExtensionContext(tabURL))

        let base2 = try loadContext(ext, in: profile2).baseURL
        XCTAssertNotEqual(base2.host?.lowercased(), oldHost.lowercased(),
                          "precondition: WebKit gives the new context a new origin")
        profile2.resolvePendingExtensionPages(in: store2)

        func moved(_ url: URL) throws -> URL {
            try XCTUnwrap(rewriteExtensionPageURL(url, from: base1, to: base2))
        }
        XCTAssertTrue(profile2.pendingExtensionOrigins.isEmpty)
        XCTAssertEqual(restoredTab.url, try moved(tabURL))
        XCTAssertEqual(restoredTab.url?.query, "next=https%3A%2F%2Fa.example%2F")
        XCTAssertEqual(restoredTab.url?.fragment, "section")
        XCTAssertEqual(space2.tabs[1].url, webURL, "an ordinary tab is untouched")

        XCTAssertEqual(space2.pinnedEntries.count, 2)
        XCTAssertEqual(space2.pinnedEntries[0].pinnedURL, try moved(pinnedLiveURL))
        XCTAssertEqual(space2.pinnedEntries[0].tab?.url, try moved(pinnedLiveURL))
        XCTAssertEqual(space2.pinnedEntries[1].pinnedURL, try moved(pinnedDormantURL))
        XCTAssertNil(space2.pinnedEntries[1].tab)

        XCTAssertEqual(profile2.favorites.map(\.url), [try moved(favLiveURL), try moved(favDormantURL)])
        XCTAssertEqual(profile2.favorites[0].tab?.url, try moved(favLiveURL))
        XCTAssertNil(profile2.favorites[1].tab)

        // A dormant tile opens on the new origin, and the closed tab reopens there.
        store2.activatePinnedEntry(id: space2.pinnedEntries[1].id, in: space2)
        XCTAssertEqual(space2.pinnedEntries[1].tab?.url, try moved(pinnedDormantURL))
        XCTAssertEqual(space2.pinnedEntries[1].tab?.isSleeping, true,
                       "materialised sleeping, so wake builds it from the context's configuration")
        let reopened = try XCTUnwrap(store2.reopenClosedTab(in: space2))
        XCTAssertEqual(reopened.url, try moved(closedURL))

        // The identity is written back out against the new origin.
        store2.saveNow()
        let resaved = try await db.dbQueue.read { try TabRecord.fetchAll($0) }
        XCTAssertEqual(resaved.first { $0.url == (try? moved(tabURL))?.absoluteString }?.extensionID, ext.id)

        for tab in space2.tabs + space2.pinnedTabs + profile2.favorites.compactMap(\.tab) { tab.teardown() }
    }

    /// Quitting before the contexts load must not lose the identity: the pending
    /// origin is what the save writes the id from.
    func testIdentitySurvivesASaveBeforeTheContextLoads() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension()
        install(ext, in: db)

        let store1 = TabStore(appDB: db)
        let profile1 = store1.addProfile(name: "Persist")
        let space1 = store1.addSpace(name: "Persist", emoji: "🧪", colorHex: "007AFF", profileID: profile1.id)
        let base1 = try loadContext(ext, in: profile1).baseURL
        let url = try pageURL("options.html#early-quit", on: base1)
        space1.tabs.append(sleepingTab(url, in: space1))
        store1.saveNow()
        profile1.unloadAllExtensions()

        // Launch 2 restores and quits without ever loading the context.
        let store2 = restoredStore(db)
        store2.saveNow()

        // Launch 3 still resolves it.
        let store3 = restoredStore(db)
        let profile3 = try XCTUnwrap(store3.profile(withID: profile1.id))
        let space3 = try XCTUnwrap(store3.space(withID: space1.id))
        XCTAssertEqual(space3.tabs.map(\.url), [url])
        let base3 = try loadContext(ext, in: profile3).baseURL
        profile3.resolvePendingExtensionPages(in: store3)
        XCTAssertEqual(space3.tabs.first?.url, rewriteExtensionPageURL(url, from: base1, to: base3))
    }

    // MARK: - Uninstalled while the app was closed

    func testPagesOfAnExtensionUninstalledWhileClosedAreDropped() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension()
        install(ext, in: db)

        let store1 = TabStore(appDB: db)
        let profile1 = store1.addProfile(name: "Persist")
        let space1 = store1.addSpace(name: "Persist", emoji: "🧪", colorHex: "007AFF", profileID: profile1.id)
        let base1 = try loadContext(ext, in: profile1).baseURL
        let extURL = try pageURL("options.html", on: base1)
        let webURL = try XCTUnwrap(URL(string: "https://example.com/"))
        let otherWebURL = try XCTUnwrap(URL(string: "https://example.org/"))

        // Normal tabs: the selected extension page in a split with a web page.
        let extTab = sleepingTab(extURL, in: space1)
        let webTab = sleepingTab(webURL, in: space1)
        let normalGroup = UUID()
        for member in [extTab, webTab] {
            member.splitGroupID = normalGroup
            member.splitFraction = 0.5
            space1.tabs.append(member)
        }
        space1.selectedTabID = extTab.id

        // Pinned: an extension-home entry split with a web entry, and a web-home
        // entry whose backing tab has navigated to the extension page.
        store1.pinURL(extURL, title: "Ext home", faviconURL: nil, in: space1)
        store1.pinURL(webURL, title: "Web partner", faviconURL: nil, in: space1)
        let pinnedGroup = UUID()
        for entry in space1.pinnedEntries {
            entry.splitGroupID = pinnedGroup
            entry.splitFraction = 0.5
        }
        store1.pinURL(otherWebURL, title: "Web home", faviconURL: nil, in: space1)
        space1.pinnedEntries[2].tab = sleepingTab(extURL, in: space1)

        // Favourites: one on the extension page, one live on the web whose tab
        // is on the extension page.
        store1.addFavoriteFromEntry(url: extURL, title: "Ext fav", faviconURL: nil, favicon: nil,
                                    profileID: profile1.id, at: 0)
        store1.addFavorite(from: sleepingTab(extURL, in: space1), profileID: profile1.id)
        profile1.favorites[1].url = webURL

        let closed = sleepingTab(extURL, in: space1)
        space1.tabs.append(closed)
        store1.closeTab(id: closed.id, in: space1)

        store1.saveNow()
        for tab in space1.pinnedTabs { tab.teardown() }
        profile1.unloadAllExtensions()

        // Uninstalled while the app is closed.
        db.deleteExtension(id: ext.id)

        let store2 = restoredStore(db)
        let profile2 = try XCTUnwrap(store2.profile(withID: profile1.id))
        let space2 = try XCTUnwrap(store2.space(withID: space1.id))

        XCTAssertEqual(space2.tabs.map(\.url), [webURL], "the extension tab is dropped, not restored blank")
        XCTAssertNil(space2.tabs[0].splitGroupID, "its split partner is left a lone tab")
        XCTAssertEqual(space2.selectedTabID, space2.tabs[0].id, "selection moves off the dropped tab")

        XCTAssertEqual(space2.pinnedEntries.map(\.pinnedURL), [webURL, otherWebURL],
                       "the extension-home entry is dropped")
        XCTAssertNil(space2.pinnedEntries[0].splitGroupID, "the orphaned pinned split partner is dissolved")
        XCTAssertNil(space2.pinnedEntries[1].tab,
                     "a backing tab on the extension page is dropped, leaving its entry dormant")

        XCTAssertEqual(profile2.favorites.map(\.url), [webURL], "the extension favourite is dropped")
        XCTAssertNil(profile2.favorites[0].tab, "and a backing tab on the extension page leaves it dormant")

        XCTAssertFalse(store2.canReopenClosedTab(in: space2), "the closed extension page is discarded")
        XCTAssertNil(store2.reopenClosedTab(in: space2))
        XCTAssertTrue(profile2.pendingExtensionOrigins.isEmpty)

        // The next save drops the rows too.
        store2.saveNow()
        let tabRecords = try await db.dbQueue.read { try TabRecord.fetchAll($0) }
        XCTAssertFalse(tabRecords.contains { $0.url == extURL.absoluteString })
        let closedRecords = try await db.dbQueue.read { try ClosedTabRecord.fetchAll($0) }
        XCTAssertTrue(closedRecords.isEmpty)
    }

    // MARK: - Disabled while the app was closed

    /// A disabled extension's pinned entries, favourites and closed tabs survive a
    /// relaunch (and a second one) with their identity, as a mid-session disable
    /// keeps them; open tabs on its pages are dropped, as that disable closes
    /// them. Enabling it moves the tiles onto the new context's origin.
    func testDisabledExtensionsTilesSurviveARelaunchAndResolveWhenEnabled() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension()
        install(ext, in: db)

        let store1 = TabStore(appDB: db)
        let profile1 = store1.addProfile(name: "Persist")
        let space1 = store1.addSpace(name: "Persist", emoji: "🧪", colorHex: "007AFF", profileID: profile1.id)
        let base1 = try loadContext(ext, in: profile1).baseURL
        let tabURL = try pageURL("options.html?open=1", on: base1)
        let pinnedURL = try pageURL("options.html?pinned=1", on: base1)
        let dormantPinnedURL = try pageURL("options.html?pinned=dormant", on: base1)
        let favURL = try pageURL("options.html?fav=1", on: base1)
        let closedURL = try pageURL("options.html?closed=1", on: base1)
        let webURL = try XCTUnwrap(URL(string: "https://example.com/"))

        let openTab = sleepingTab(tabURL, in: space1)
        space1.tabs.append(openTab)
        space1.tabs.append(sleepingTab(webURL, in: space1))
        space1.selectedTabID = openTab.id
        let pinnedTab = sleepingTab(pinnedURL, in: space1)
        space1.tabs.append(pinnedTab)
        store1.pinTab(id: pinnedTab.id, in: space1)
        store1.pinURL(dormantPinnedURL, title: "Dormant", faviconURL: nil, in: space1)
        store1.addFavorite(from: sleepingTab(favURL, in: space1), profileID: profile1.id)
        let closed = sleepingTab(closedURL, in: space1)
        space1.tabs.append(closed)
        store1.closeTab(id: closed.id, in: space1)
        store1.saveNow()
        for tab in space1.pinnedTabs { tab.teardown() }
        profile1.unloadAllExtensions()

        // Disabled for the profile while the app is closed.
        db.setProfileExtensionEnabled(extensionID: ext.id, profileID: profile1.id.uuidString, enabled: false)

        let store2 = restoredStore(db)
        let profile2 = try XCTUnwrap(store2.profile(withID: profile1.id))
        let space2 = try XCTUnwrap(store2.space(withID: space1.id))
        let oldHost = try XCTUnwrap(base1.host).lowercased()

        XCTAssertEqual(space2.tabs.map(\.url), [webURL], "the open extension tab is dropped, as a disable closes it")
        XCTAssertEqual(space2.selectedTabID, space2.tabs.first?.id)
        XCTAssertEqual(space2.pinnedEntries.map(\.pinnedURL), [pinnedURL, dormantPinnedURL],
                       "pinned entries are kept with their URL")
        XCTAssertTrue(space2.pinnedEntries.allSatisfy { $0.tab == nil },
                      "dormant: the backing tab on the disabled page is dropped")
        XCTAssertEqual(profile2.favorites.map(\.url), [favURL], "the favourite is kept")
        XCTAssertNil(profile2.favorites.first?.tab)
        XCTAssertEqual(profile2.pendingExtensionOrigins, [oldHost: ext.id],
                       "the origin is pending, so a later enable resolves the tiles")

        // Reopen skips the disabled extension's closed tab but keeps it.
        XCTAssertFalse(store2.canReopenClosedTab(in: space2))
        XCTAssertNil(store2.reopenClosedTab(in: space2))
        XCTAssertEqual(store2.closedTabStack.map(\.url), [closedURL.absoluteString])

        // A dormant tile opened while disabled gives a sleeping tab that wake will
        // leave unloaded (a pending origin), not a crash or a dead load.
        store2.activatePinnedEntry(id: space2.pinnedEntries[1].id, in: space2)
        let opened = try XCTUnwrap(space2.pinnedEntries[1].tab)
        XCTAssertTrue(opened.isSleeping)
        XCTAssertTrue(profile2.isAwaitingExtensionContext(opened.url))
        opened.teardown()
        space2.pinnedEntries[1].tab = nil

        // The ids are written back out, and a second relaunch still keeps it all.
        store2.saveNow()
        let pinnedRecords = try await db.dbQueue.read { try PinnedTabRecord.fetchAll($0) }
        XCTAssertEqual(pinnedRecords.map(\.extensionID), [ext.id, ext.id])
        let favoriteRecords = try await db.dbQueue.read { try FavoriteRecord.fetchAll($0) }
        XCTAssertEqual(favoriteRecords.map(\.extensionID), [ext.id])
        let closedRecords = try await db.dbQueue.read { try ClosedTabRecord.fetchAll($0) }
        XCTAssertEqual(closedRecords.map(\.extensionID), [ext.id], "reopen did not delete the skipped record")

        let store3 = restoredStore(db)
        let profile3 = try XCTUnwrap(store3.profile(withID: profile1.id))
        let space3 = try XCTUnwrap(store3.space(withID: space1.id))
        XCTAssertEqual(space3.pinnedEntries.map(\.pinnedURL), [pinnedURL, dormantPinnedURL])
        XCTAssertEqual(profile3.favorites.map(\.url), [favURL])

        // Enabled again: the context loads and the pending origin resolves, as
        // ExtensionManager.applyEnabledState does on `.loaded`.
        db.setProfileExtensionEnabled(extensionID: ext.id, profileID: profile1.id.uuidString, enabled: true)
        let base3 = try loadContext(ext, in: profile3).baseURL
        profile3.resolvePendingExtensionPages(in: store3)
        func moved(_ url: URL) throws -> URL {
            try XCTUnwrap(rewriteExtensionPageURL(url, from: base1, to: base3))
        }
        XCTAssertEqual(space3.pinnedEntries.map(\.pinnedURL), [try moved(pinnedURL), try moved(dormantPinnedURL)])
        XCTAssertEqual(profile3.favorites.map(\.url), [try moved(favURL)])
        XCTAssertTrue(profile3.pendingExtensionOrigins.isEmpty)
        XCTAssertTrue(store3.canReopenClosedTab(in: space3))
        XCTAssertEqual(store3.reopenClosedTab(in: space3)?.url, try moved(closedURL))
        for tab in space3.tabs { tab.teardown() }
    }

    // MARK: - Lazy resolution through the display path

    /// Against the shared store, since `BrowserTab.wake` resolves its space there:
    /// a restored page woken before its context loads stays unloaded (rather than
    /// loading a dead origin into the space configuration), and once the context
    /// loads the resolution pass rehosts it onto the live origin.
    func testRestoredPageWokenBeforeItsContextLoadsIsRehostedOnceItDoes() async throws {
        let ext = try await makeExtension()
        let profile = TabStore.shared.addProfile(name: "Persist-shared")
        sharedProfiles.append(profile)
        let space = TabStore.shared.addSpace(name: "Persist-shared", emoji: "🧪", colorHex: "007AFF",
                                             profileID: profile.id)
        sharedSpaceIDs.append(space.id)

        let deadHost = UUID().uuidString.lowercased()
        let deadURL = try XCTUnwrap(URL(string: "webkit-extension://\(deadHost)/options.html?x=1#y"))
        profile.registerPendingExtensionOrigin(host: deadHost, extensionID: ext.id)
        let tab = sleepingTab(deadURL, in: space)
        space.tabs.append(tab)

        tab.wake()
        XCTAssertNotNil(tab.webView)
        XCTAssertNil(tab.webView?.url, "a page on a pending origin is not loaded")
        XCTAssertEqual(tab.url, deadURL)

        _ = profile.extensionController
        let context = try loadContext(ext, in: profile)
        profile.resolvePendingExtensionPages()

        let expected = try XCTUnwrap(rewriteExtensionPageURL(
            deadURL, from: try XCTUnwrap(extensionOriginBaseURL(host: deadHost)), to: context.baseURL))
        XCTAssertEqual(tab.url, expected)
        XCTAssertNil(tab.webView, "retargeted tabs are left asleep for the display path")

        tab.wake()
        XCTAssertEqual(tab.webView?.url, expected, "woken from the context's configuration onto the live origin")
    }
}
