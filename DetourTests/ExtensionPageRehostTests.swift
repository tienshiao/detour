import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-14: when a `WKWebExtensionContext` is unloaded and reloaded mid-session,
/// WebKit gives the replacement a fresh `webkit-extension://<UUID>/` base URL and
/// every page still open on the old origin is dead. These tests drive the real
/// production paths — `Profile.recoverFromBackgroundLoadFailure`,
/// `TabStore.addExtensionTab`, `BrowserTab.wake`, `ExtensionManager.setEnabled` —
/// against the shared `TabStore` and `AppDatabase` (the test scheme points
/// `DETOUR_DATA_DIR` at an isolated directory).
@MainActor
final class ExtensionPageRehostTests: XCTestCase {

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
        for profile in createdProfiles {
            for favorite in profile.favorites { favorite.tab?.teardown() }
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            try? AppDatabase.shared.dbQueue.write { db in
                _ = try ExtensionPermissionRecord
                    .filter(Column("extensionID") == id)
                    .deleteAll(db)
            }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A minimal MV3 extension with an options page and no background content
    /// (nothing here needs a worker, and a failing one would trip the recovery
    /// path a second time).
    private func makeTestExtension(named name: String) async throws -> WebExtension {
        let id = "page-rehost-\(name)-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Page Rehost Test \(name)",
            "version": "1.0.0",
            "options_ui": { "page": "options.html" }
        }
        """
        try manifestJSON.write(to: dir.appendingPathComponent("manifest.json"),
                               atomically: true, encoding: .utf8)
        try "<html><body>options</body></html>"
            .write(to: dir.appendingPathComponent("options.html"),
                   atomically: true, encoding: .utf8)

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)

        AppDatabase.shared.saveExtension(ExtensionRecord(
            id: id,
            name: manifest.name,
            version: manifest.version,
            manifestJSON: manifestJSON.data(using: .utf8)!,
            basePath: dir.path,
            isEnabled: true,
            installedAt: Date().timeIntervalSince1970
        ))
        return ext
    }

    private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        return profile
    }

    private func makeSpace(_ name: String, in profile: Profile) -> Space {
        let space = TabStore.shared.addSpace(name: name, emoji: "🧪", colorHex: "007AFF",
                                             profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    private func loadContext(_ profile: Profile, _ ext: WebExtension) throws -> WKWebExtensionContext {
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        return try XCTUnwrap(profile.extensionContexts[ext.id],
                             "the context should be loaded in the profile's controller")
    }

    /// Opens an extension page in a tab exactly as production does (the options
    /// page, an `action` popup expanded into a tab, `chrome.tabs.create` on an
    /// extension URL): a web view built from the *context's* configuration.
    private func openExtensionPage(
        _ context: WKWebExtensionContext, in space: Space, path: String
    ) throws -> (tab: BrowserTab, url: URL) {
        let pageURL = try XCTUnwrap(URL(string: path, relativeTo: context.baseURL)?.absoluteURL)
        let config = try XCTUnwrap(context.webViewConfiguration,
                                   "a loaded context must offer a web view configuration")
        let tab = TabStore.shared.addExtensionTab(in: space, url: pageURL, configuration: config)
        XCTAssertEqual(tab.webView?.url, pageURL,
                       "precondition: the tab should be showing the extension page")
        return (tab, pageURL)
    }

    private func userScriptSources(_ config: WKWebViewConfiguration) -> Set<String> {
        Set(config.userContentController.userScripts.map(\.source))
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 3,
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - AC #1: the recovery path rehosts the open page

    func testRecoveryRehostsOpenExtensionPageOntoTheNewOrigin() async throws {
        let ext = try await makeTestExtension(named: "recover")
        let profile = makeProfile("Rehost Recovery Profile")
        let space = makeSpace("Rehost", in: profile)
        let first = try loadContext(profile, ext)
        let oldHost = try XCTUnwrap(first.baseURL.host)

        let (tab, pageURL) = try openExtensionPage(first, in: space, path: "options.html?tab=general#privacy")
        // The page's own identity survives: this is the same page arriving from a
        // new internal origin, not a navigation somewhere else.
        tab.title = "Extension Options"

        profile.recoverFromBackgroundLoadFailure(extensionID: ext.id, failedContext: first)

        let second = try XCTUnwrap(profile.extensionContexts[ext.id],
                                   "recovery should have loaded a replacement context")
        let newHost = try XCTUnwrap(second.baseURL.host)
        XCTAssertNotEqual(oldHost, newHost, "precondition: a reloaded context gets a fresh origin")

        let rehosted = try XCTUnwrap(tab.url)
        XCTAssertEqual(rehosted.host, newHost, "the open page must move to the new context's origin")
        XCTAssertEqual(rehosted.path, pageURL.path, "the same page, not the extension root")
        XCTAssertEqual(rehosted.query, "tab=general")
        XCTAssertEqual(rehosted.fragment, "privacy")

        XCTAssertTrue(tab.isSleeping, "the tab is left sleeping so the display path rebuilds it")
        XCTAssertNil(tab.webView, "the web view built from the dead context must be gone")
        XCTAssertNil(tab.currentInteractionStateData(),
                     "the cached interaction state would restore the dead URL, so it must be discarded")
        XCTAssertEqual(tab.title, "Extension Options",
                       "the sidebar must not flash a raw webkit-extension:// URL as the title")
    }

    /// The rehosted tab must wake into the *new* context's configuration — the
    /// space's own configuration cannot load `webkit-extension://` at all.
    func testWakingARehostedTabUsesTheNewContextsConfiguration() async throws {
        let ext = try await makeTestExtension(named: "wake")
        let profile = makeProfile("Rehost Wake Profile")
        let space = makeSpace("Rehost Wake", in: profile)
        let first = try loadContext(profile, ext)
        let (tab, _) = try openExtensionPage(first, in: space, path: "options.html")

        profile.recoverFromBackgroundLoadFailure(extensionID: ext.id, failedContext: first)
        let second = try XCTUnwrap(profile.extensionContexts[ext.id])

        tab.wake()

        let webView = try XCTUnwrap(tab.webView, "waking must produce a web view")
        XCTAssertFalse(tab.isSleeping)
        XCTAssertEqual(webView.url?.host, second.baseURL.host,
                       "the woken view loads the page from the new origin")

        let expected = try XCTUnwrap(second.webViewConfiguration).userContentController.userScripts.map(\.source)
        XCTAssertEqual(userScriptSources(webView.configuration), Set(expected),
                       "the tab must wake from the new context's configuration, not the space's")
        XCTAssertFalse(userScriptSources(webView.configuration).contains { $0.contains("linkHover") },
                       "the space configuration's own scripts are the signature of the wrong config")
        XCTAssertTrue(userScriptSources(space.makeWebViewConfiguration()).contains { $0.contains("linkHover") },
                      "precondition: that is in fact the space configuration's signature")
    }

    // MARK: - AC #4: no reliance on an attached web view

    /// A tab whose web view another window owns shows a snapshot here and has no
    /// web view of its own; a sleeping tab has none either. Both must still be
    /// moved to the new origin — the rehost works from `tab.url`.
    func testRehostMovesATabWithNoWebView() async throws {
        let ext = try await makeTestExtension(named: "detached")
        let profile = makeProfile("Rehost Detached Profile")
        let space = makeSpace("Rehost Detached", in: profile)
        let first = try loadContext(profile, ext)
        let (tab, pageURL) = try openExtensionPage(first, in: space, path: "options.html")

        // What a non-owning window's tab looks like: no web view attached.
        tab.sleep(force: true)
        XCTAssertNil(tab.webView)
        XCTAssertEqual(tab.url, pageURL, "precondition: the URL still names the old origin")

        profile.recoverFromBackgroundLoadFailure(extensionID: ext.id, failedContext: first)
        let second = try XCTUnwrap(profile.extensionContexts[ext.id])

        XCTAssertEqual(tab.url?.host, second.baseURL.host,
                       "a tab with no web view must be rehosted like any other")
        XCTAssertNil(tab.currentInteractionStateData(),
                     "the interaction state cached by sleep() must be dropped too — it holds the dead URL")
    }

    // MARK: - AC #3: everything else is left alone

    func testRehostLeavesOtherTabsUntouched() async throws {
        let ext = try await makeTestExtension(named: "mine")
        let other = try await makeTestExtension(named: "other")
        let profile = makeProfile("Rehost Isolation Profile")
        let space = makeSpace("Rehost Isolation", in: profile)
        let first = try loadContext(profile, ext)
        let otherContext = try loadContext(profile, other)

        let (mine, _) = try openExtensionPage(first, in: space, path: "options.html")
        let (theirs, theirURL) = try openExtensionPage(otherContext, in: space, path: "options.html")
        let webTab = TabStore.shared.addTab(in: space, url: URL(string: "https://example.com/page?x=1"))
        let webURL = webTab.url

        profile.recoverFromBackgroundLoadFailure(extensionID: ext.id, failedContext: first)

        XCTAssertNotEqual(mine.url?.host, first.baseURL.host, "precondition: the reloaded extension moved")

        XCTAssertEqual(theirs.url, theirURL, "another extension's page must not be rewritten")
        XCTAssertFalse(theirs.isSleeping, "another extension's tab must keep its web view")
        XCTAssertNotNil(theirs.webView)
        XCTAssertEqual(theirs.webView?.url?.host, otherContext.baseURL.host)

        XCTAssertEqual(webTab.url, webURL, "an ordinary web page must not be rewritten")
        XCTAssertFalse(webTab.isSleeping, "an ordinary web page must keep its web view")
        XCTAssertNotNil(webTab.webView)
    }

    /// Spaces are global; only those on the reloading profile may be touched.
    func testRehostLeavesAnotherProfilesPagesUntouched() async throws {
        let ext = try await makeTestExtension(named: "shared")
        let profile = makeProfile("Rehost Profile A")
        let otherProfile = makeProfile("Rehost Profile B")
        let space = makeSpace("Rehost A", in: profile)
        let otherSpace = makeSpace("Rehost B", in: otherProfile)

        let first = try loadContext(profile, ext)
        let otherFirst = try loadContext(otherProfile, ext)
        let (mine, _) = try openExtensionPage(first, in: space, path: "options.html")
        let (theirs, theirURL) = try openExtensionPage(otherFirst, in: otherSpace, path: "options.html")

        profile.recoverFromBackgroundLoadFailure(extensionID: ext.id, failedContext: first)

        XCTAssertNotEqual(mine.url?.host, first.baseURL.host, "precondition: this profile's page moved")
        XCTAssertEqual(theirs.url, theirURL,
                       "the same extension in another profile has its own context and is unaffected")
        XCTAssertFalse(theirs.isSleeping)
    }

    // MARK: - AC #1: the rehost notification

    func testRehostPostsOneRehostNotificationForTheAffectedSpace() async throws {
        let ext = try await makeTestExtension(named: "notify")
        let profile = makeProfile("Rehost Notify Profile")
        let space = makeSpace("Rehost Notify", in: profile)
        let first = try loadContext(profile, ext)
        _ = try openExtensionPage(first, in: space, path: "options.html")
        _ = try openExtensionPage(first, in: space, path: "popup.html")

        let exp = expectation(forNotification: .spaceTabsNeedRehost, object: nil) { note in
            note.userInfo?["spaceID"] as? UUID == space.id
        }
        exp.assertForOverFulfill = true

        profile.recoverFromBackgroundLoadFailure(extensionID: ext.id, failedContext: first)

        await fulfillment(of: [exp], timeout: 2)
    }

    /// A failed reload leaves no replacement origin, so the pages stay where they
    /// are rather than being moved to nowhere or closed behind the user's back.
    func testFailedReloadLeavesPagesAlone() async throws {
        let ext = try await makeTestExtension(named: "failed")
        let profile = makeProfile("Rehost Failed Profile")
        let space = makeSpace("Rehost Failed", in: profile)
        let first = try loadContext(profile, ext)
        let (tab, pageURL) = try openExtensionPage(first, in: space, path: "options.html")

        // `loadExtensionContext` bails out before loading when the WKWebExtension
        // is missing, so recovery unloads the old context and gets no replacement
        // — the branch where there is no new origin to move anything to.
        let wkExt = ext.wkExtension
        ext.wkExtension = nil
        profile.recoverFromBackgroundLoadFailure(extensionID: ext.id, failedContext: first)
        ext.wkExtension = wkExt

        XCTAssertNil(profile.extensionContexts[ext.id],
                     "precondition: the reload produced no replacement context")
        XCTAssertEqual(tab.url, pageURL, "with no replacement context the page must be left alone")
        XCTAssertFalse(tab.isSleeping, "and the tab must not be disturbed")
        XCTAssertNotNil(tab.webView)
    }

    // MARK: - AC #2: disable and uninstall close the pages

    func testDisablingTheExtensionClosesItsOpenPages() async throws {
        let ext = try await makeTestExtension(named: "disable")
        let profile = makeProfile("Rehost Disable Profile")
        let space = makeSpace("Rehost Disable", in: profile)
        let context = try loadContext(profile, ext)
        let (tab, _) = try openExtensionPage(context, in: space, path: "options.html")
        let webTab = TabStore.shared.addTab(in: space, url: URL(string: "https://example.com"))
        XCTAssertEqual(space.tabs.count, 2)

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: false)

        await waitUntil("the extension page tab to be closed") {
            !space.tabs.contains { $0.id == tab.id }
        }
        XCTAssertNil(tab.webView, "the closed tab must have released its web view")
        XCTAssertTrue(space.tabs.contains { $0.id == webTab.id },
                      "an ordinary web page in the same space must survive the disable")
    }

    func testUninstallingTheExtensionClosesItsOpenPages() async throws {
        let ext = try await makeTestExtension(named: "uninstall")
        let other = try await makeTestExtension(named: "uninstall-other")
        let profile = makeProfile("Rehost Uninstall Profile")
        let space = makeSpace("Rehost Uninstall", in: profile)
        let context = try loadContext(profile, ext)
        let otherContext = try loadContext(profile, other)
        let (tab, _) = try openExtensionPage(context, in: space, path: "options.html")
        let (theirs, _) = try openExtensionPage(otherContext, in: space, path: "options.html")

        ExtensionManager.shared.uninstall(id: ext.id)

        XCTAssertFalse(space.tabs.contains { $0.id == tab.id },
                       "uninstall must close the pages of the extension that is going away")
        XCTAssertTrue(space.tabs.contains { $0.id == theirs.id },
                      "another extension's page must survive")
        XCTAssertFalse(theirs.isSleeping)
    }

    /// A pinned extension page goes dormant (the tile stays), which is what
    /// closing a pinned tab by hand does.
    func testDisablingTheExtensionClosesAPinnedExtensionPage() async throws {
        let ext = try await makeTestExtension(named: "pinned")
        let profile = makeProfile("Rehost Pinned Profile")
        let space = makeSpace("Rehost Pinned", in: profile)
        let context = try loadContext(profile, ext)
        let (tab, _) = try openExtensionPage(context, in: space, path: "options.html")

        TabStore.shared.pinTab(id: tab.id, in: space)
        XCTAssertEqual(space.pinnedEntries.count, 1)
        XCTAssertNotNil(space.pinnedEntries[0].tab)

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: false)

        await waitUntil("the pinned extension page to go dormant") {
            space.pinnedEntries.first?.tab == nil
        }
        XCTAssertEqual(space.pinnedEntries.count, 1, "the pinned tile itself must stay")
    }

    /// A page on a dead origin can never be reopened — its context is gone and
    /// a re-enable mints a fresh one — so closing it must not leave a
    /// closed-tab record (Cmd+Shift+T) or an undo that would restore a blank tab.
    func testClosingExtensionPagesDoesNotRecordThemAsReopenable() async throws {
        let ext = try await makeTestExtension(named: "no-reopen")
        let profile = makeProfile("Rehost No Reopen Profile")
        let space = makeSpace("Rehost No Reopen", in: profile)
        let context = try loadContext(profile, ext)
        let (tab, _) = try openExtensionPage(context, in: space, path: "options.html")
        let stackBefore = TabStore.shared.closedTabStack.count
        TabStore.shared.undoManager.removeAllActions()

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: false)
        await waitUntil("the extension page tab to be closed") {
            !space.tabs.contains { $0.id == tab.id }
        }

        XCTAssertEqual(TabStore.shared.closedTabStack.count, stackBefore,
                       "a dead extension page must not land on the closed-tab stack")
        XCTAssertFalse(TabStore.shared.undoManager.canUndo,
                       "closing a dead extension page must not register an undo")
    }

    /// The bookmark that owns a rehosted page — a pinned entry's `pinnedURL`, a
    /// favourite's `url` — is what a later reactivation loads, so it must move to
    /// the new origin with the tab, dormant or not.
    func testRehostRewritesPinnedAndFavoriteURLs() async throws {
        let ext = try await makeTestExtension(named: "bookmarks")
        let profile = makeProfile("Rehost Bookmarks Profile")
        let space = makeSpace("Rehost Bookmarks", in: profile)
        let first = try loadContext(profile, ext)
        let oldHost = try XCTUnwrap(first.baseURL.host)

        let (pinnedPage, _) = try openExtensionPage(first, in: space, path: "options.html?tab=pinned")
        TabStore.shared.pinTab(id: pinnedPage.id, in: space)
        let entry = try XCTUnwrap(space.pinnedEntries.first)
        XCTAssertEqual(entry.pinnedURL.host, oldHost, "precondition")

        let (favoritePage, _) = try openExtensionPage(first, in: space, path: "options.html?tab=fav")
        TabStore.shared.addFavorite(from: favoritePage, profileID: profile.id)
        let favorite = try XCTUnwrap(profile.favorites.first)

        // A dormant pinned tile on the old origin has no tab to retarget; its
        // URL must be rewritten from the entry itself.
        let dormant = PinnedEntry(pinnedURL: try XCTUnwrap(URL(string: "popup.html", relativeTo: first.baseURL)?.absoluteURL),
                                  pinnedTitle: "Dormant", faviconURL: nil, sortOrder: 99)
        space.pinnedEntries.append(dormant)

        profile.recoverFromBackgroundLoadFailure(extensionID: ext.id, failedContext: first)
        let second = try XCTUnwrap(profile.extensionContexts[ext.id])
        let newHost = try XCTUnwrap(second.baseURL.host)

        XCTAssertEqual(entry.pinnedURL.host, newHost, "a live pinned entry's pinnedURL must move")
        XCTAssertEqual(entry.pinnedURL.query, "tab=pinned")
        XCTAssertEqual(favorite.url.host, newHost, "a favourite's url must move")
        XCTAssertEqual(favorite.url.query, "tab=fav")
        XCTAssertEqual(dormant.pinnedURL.host, newHost, "a dormant pinned tile's pinnedURL must move too")
        XCTAssertEqual(dormant.pinnedURL.path, "/popup.html")
    }

    /// A favourite-backed page is displayable from every space of the profile,
    /// so its notification must reach a window on any of them, and closing it
    /// must move the space's selection off the torn-down tab first.
    func testClosingADisplayedFavoriteMovesSelectionAndNotifiesEverySpace() async throws {
        let ext = try await makeTestExtension(named: "favorite")
        let profile = makeProfile("Rehost Favorite Profile")
        let space = makeSpace("Rehost Favorite A", in: profile)
        let otherSpace = makeSpace("Rehost Favorite B", in: profile)
        let context = try loadContext(profile, ext)
        let (page, _) = try openExtensionPage(context, in: space, path: "options.html")
        let webTab = TabStore.shared.addTab(in: space, url: URL(string: "https://example.com"))
        TabStore.shared.addFavorite(from: page, profileID: profile.id)
        // Favourites are detached from the tab list; both spaces "display" it.
        space.tabs.removeAll { $0.id == page.id }
        space.selectedTabID = page.id
        otherSpace.selectedTabID = page.id

        let notified = expectation(forNotification: .spaceTabsNeedRehost, object: nil) { note in
            note.userInfo?["spaceID"] as? UUID == otherSpace.id
                && (note.userInfo?["tabIDs"] as? Set<UUID>)?.contains(page.id) == true
        }

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: false)
        await fulfillment(of: [notified], timeout: 2)

        XCTAssertNil(profile.favorites.first?.tab, "the favourite goes dormant")
        XCTAssertEqual(space.selectedTabID, webTab.id,
                       "the space's selection must move to a surviving tab before teardown")
        XCTAssertNotEqual(otherSpace.selectedTabID, page.id,
                          "every space of the profile that selected the favourite must move off it")
    }

    /// The rehost notification names the tabs it moved, so a window showing an
    /// untouched tab can leave it alone rather than re-running `selectTab`.
    func testRehostNotificationCarriesTheRetargetedTabIDs() async throws {
        let ext = try await makeTestExtension(named: "tabids")
        let profile = makeProfile("Rehost TabIDs Profile")
        let space = makeSpace("Rehost TabIDs", in: profile)
        let first = try loadContext(profile, ext)
        let (page, _) = try openExtensionPage(first, in: space, path: "options.html")
        let webTab = TabStore.shared.addTab(in: space, url: URL(string: "https://example.com"))

        var tabIDs: Set<UUID>?
        let exp = expectation(forNotification: .spaceTabsNeedRehost, object: nil) { note in
            guard note.userInfo?["spaceID"] as? UUID == space.id else { return false }
            tabIDs = note.userInfo?["tabIDs"] as? Set<UUID>
            return true
        }

        profile.recoverFromBackgroundLoadFailure(extensionID: ext.id, failedContext: first)
        await fulfillment(of: [exp], timeout: 2)

        XCTAssertEqual(tabIDs, [page.id], "only the rehosted tab is named; \(webTab.id) was untouched")
    }
}
