import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-28: the close undos (Close Tab, Close Both Splits, a pinned entry's Close
/// Tab, Delete Space) rebuild closed tabs from state captured at close time. An
/// extension page cannot load in the space configuration, and its origin dies
/// when the extension's context is reloaded, so each undo resolves the page by
/// the extension id captured at close — as Reopen Closed Tab does (TASK-24).
///
/// Most tests use a `TabStore` on an in-memory `AppDatabase` with real
/// `WKWebExtension` contexts, so a reload hands out the base URL WebKit actually
/// mints. The wake test runs against the shared store, which `BrowserTab.wake`
/// resolves its space from.
@MainActor
final class ExtensionPageUndoTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var loadedProfiles: [Profile] = []
    private var sharedSpaceIDs: [UUID] = []
    private var sharedProfiles: [Profile] = []
    private var sharedExtensionIDs: [String] = []

    override func tearDown() {
        for spaceID in sharedSpaceIDs {
            guard let space = TabStore.shared.space(withID: spaceID) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: spaceID)
            AppDatabase.shared.deleteClosedTabs(spaceID: spaceID.uuidString)
        }
        sharedSpaceIDs.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        for profile in sharedProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        sharedProfiles.removeAll()
        for id in sharedExtensionIDs { AppDatabase.shared.deleteExtension(id: id) }
        sharedExtensionIDs.removeAll()
        for profile in loadedProfiles { profile.unloadAllExtensions() }
        loadedProfiles.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A minimal MV3 extension with an options page and no background content.
    private func makeExtension() async throws -> WebExtension {
        let id = "page-undo-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Page Undo Test",
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

    /// Unloads and loads the context again: WebKit gives it a new origin.
    private func reloadContext(_ ext: WebExtension, in profile: Profile, from oldBase: URL) throws -> URL {
        _ = profile.unloadExtension(id: ext.id)
        let newBase = try loadContext(ext, in: profile).baseURL
        XCTAssertNotEqual(newBase.host?.lowercased(), oldBase.host?.lowercased(),
                          "precondition: the reloaded context has a new origin")
        return newBase
    }

    private func sleepingTab(_ url: URL, title: String = "Page", in space: Space) -> BrowserTab {
        BrowserTab(id: UUID(), title: title, url: url, faviconURL: nil,
                   cachedInteractionState: nil, spaceID: space.id)
    }

    private func pageURL(_ path: String, on base: URL) throws -> URL {
        try XCTUnwrap(URL(string: path, relativeTo: base)?.absoluteURL)
    }

    private struct Fixture {
        let db: AppDatabase
        let ext: WebExtension
        let store: TabStore
        let profile: Profile
        let space: Space
        let base: URL
    }

    private func makeFixture() async throws -> Fixture {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let ext = try await makeExtension()
        install(ext, in: db)
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Undo")
        let space = store.addSpace(name: "Undo", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        let base = try loadContext(ext, in: profile).baseURL
        return Fixture(db: db, ext: ext, store: store, profile: profile, space: space, base: base)
    }

    private func teardownTabs(_ f: Fixture) {
        for tab in f.space.tabs + f.space.pinnedTabs { tab.teardown() }
    }

    // MARK: - Close Tab

    func testUndoCloseTabRestoresASleepingTabOnTheCurrentBase() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let webURL = try XCTUnwrap(URL(string: "https://example.com/"))
        let url = try pageURL("options.html?next=https%3A%2F%2Fa.example%2F#section", on: f.base)
        let web = sleepingTab(webURL, in: f.space)
        let page = sleepingTab(url, title: "Options", in: f.space)
        f.space.tabs.append(contentsOf: [web, page])

        f.store.undoManager.removeAllActions()
        f.store.closeTab(id: page.id, in: f.space)
        XCTAssertEqual(f.store.closedTabStack.first?.extensionID, f.ext.id)

        f.store.undoManager.undo()

        XCTAssertEqual(f.space.tabs.count, 2)
        let restored = f.space.tabs[1]
        XCTAssertNotEqual(restored.id, page.id)
        XCTAssertEqual(restored.url, url)
        XCTAssertEqual(restored.title, "Options")
        XCTAssertTrue(restored.isSleeping, "an extension page comes back sleeping, for wake to build from its context")
        XCTAssertNil(restored.webView)
        XCTAssertFalse(f.profile.isAwaitingExtensionContext(url))
        XCTAssertTrue(f.store.closedTabStack.isEmpty, "the undo consumes the closed-tab record")
        XCTAssertTrue(f.db.loadClosedTabs().isEmpty)

        // Redo closes it again, recording the id again.
        XCTAssertTrue(f.store.undoManager.canRedo)
        f.store.undoManager.redo()
        XCTAssertEqual(f.space.tabs.map(\.id), [web.id])
        XCTAssertEqual(f.store.closedTabStack.map(\.extensionID), [f.ext.id])
    }

    func testUndoCloseTabAfterAContextReloadUsesTheNewBase() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let url = try pageURL("options.html?q=1#frag", on: f.base)
        let page = sleepingTab(url, in: f.space)
        f.space.tabs.append(page)

        f.store.undoManager.removeAllActions()
        f.store.closeTab(id: page.id, in: f.space)
        let newBase = try reloadContext(f.ext, in: f.profile, from: f.base)

        f.store.undoManager.undo()

        let restored = try XCTUnwrap(f.space.tabs.first)
        let expected = try XCTUnwrap(rewriteExtensionPageURL(url, from: f.base, to: newBase))
        XCTAssertEqual(restored.url, expected)
        XCTAssertEqual(restored.url?.query, "q=1")
        XCTAssertEqual(restored.url?.fragment, "frag")
        XCTAssertTrue(restored.isSleeping)
        XCTAssertTrue(f.store.closedTabStack.isEmpty)
    }

    /// Enabled but with no loaded context at undo time (between an unload and
    /// the load): the page waits on a pending origin, resolved when it loads.
    func testUndoCloseTabWithTheContextNotLoadedWaitsOnAPendingOrigin() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let url = try pageURL("options.html", on: f.base)
        let page = sleepingTab(url, in: f.space)
        f.space.tabs.append(page)

        f.store.undoManager.removeAllActions()
        f.store.closeTab(id: page.id, in: f.space)
        _ = f.profile.unloadExtension(id: f.ext.id)

        f.store.undoManager.undo()

        let restored = try XCTUnwrap(f.space.tabs.first)
        XCTAssertEqual(restored.url, url)
        XCTAssertTrue(f.profile.isAwaitingExtensionContext(url))

        let newBase = try loadContext(f.ext, in: f.profile).baseURL
        f.profile.resolvePendingExtensionPages(in: f.store)
        XCTAssertEqual(restored.url, rewriteExtensionPageURL(url, from: f.base, to: newBase))
    }

    func testUndoCloseTabOfADisabledExtensionRestoresNothingAndKeepsTheRecord() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let url = try pageURL("options.html", on: f.base)
        let page = sleepingTab(url, in: f.space)
        f.space.tabs.append(page)

        f.store.undoManager.removeAllActions()
        f.store.closeTab(id: page.id, in: f.space)
        f.db.setProfileExtensionEnabled(extensionID: f.ext.id, profileID: f.profile.id.uuidString, enabled: false)
        _ = f.profile.unloadExtension(id: f.ext.id)

        f.store.undoManager.undo()

        XCTAssertTrue(f.space.tabs.isEmpty, "no dead tab")
        XCTAssertFalse(f.store.undoManager.canRedo, "nothing was restored, so there is nothing to redo")
        XCTAssertEqual(f.store.closedTabStack.map(\.url), [url.absoluteString],
                       "the record stays for a reopen after a later enable")
        XCTAssertEqual(f.db.loadClosedTabs().count, 1)
        XCTAssertFalse(f.store.canReopenClosedTab(in: f.space))
    }

    func testUndoCloseTabOfAnUninstalledExtensionRestoresNothing() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let page = sleepingTab(try pageURL("options.html", on: f.base), in: f.space)
        f.space.tabs.append(page)

        f.store.undoManager.removeAllActions()
        f.store.closeTab(id: page.id, in: f.space)
        _ = f.profile.unloadExtension(id: f.ext.id)
        f.db.deleteExtension(id: f.ext.id)

        f.store.undoManager.undo()

        XCTAssertTrue(f.space.tabs.isEmpty, "no dead tab")
        XCTAssertFalse(f.store.undoManager.canRedo)
        XCTAssertNil(f.store.reopenClosedTab(in: f.space), "Reopen Closed Tab applies TASK-24's rules to the record")
        XCTAssertTrue(f.store.closedTabStack.isEmpty, "and discards it")
    }

    func testUndoCloseTabOfAnOrdinaryTabIsUnchanged() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let tabs = (0..<3).map { i in sleepingTab(URL(string: "https://example.com/\(i)")!, in: f.space) }
        f.space.tabs.append(contentsOf: tabs)
        let groupID = UUID()
        for tab in [tabs[1], tabs[2]] { tab.splitGroupID = groupID; tab.splitFraction = 0.4 }

        f.store.undoManager.removeAllActions()
        f.store.closeTab(id: tabs[2].id, in: f.space)
        XCTAssertNil(tabs[1].splitGroupID)
        XCTAssertNil(f.store.closedTabStack.first?.extensionID)

        f.store.undoManager.undo()

        XCTAssertEqual(f.space.tabs.count, 3)
        let restored = f.space.tabs[2]
        XCTAssertEqual(restored.url, URL(string: "https://example.com/2"))
        XCTAssertFalse(restored.isSleeping, "an ordinary tab still comes back live")
        XCTAssertNotNil(restored.webView)
        XCTAssertNotNil(tabs[1].splitGroupID, "and rejoins its split partner")
        XCTAssertEqual(restored.splitGroupID, tabs[1].splitGroupID)
        XCTAssertEqual(restored.splitFraction, 0.4)
        XCTAssertTrue(f.store.closedTabStack.isEmpty)
        XCTAssertTrue(f.db.loadClosedTabs().isEmpty)
        XCTAssertTrue(f.store.undoManager.canRedo)
    }

    // MARK: - Close Both Splits

    func testUndoCloseBothSplitsRestoresBothOnTheNewBase() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let webURL = try XCTUnwrap(URL(string: "https://example.com/"))
        let extURL = try pageURL("options.html#split", on: f.base)
        let web = sleepingTab(webURL, in: f.space)
        let page = sleepingTab(extURL, in: f.space)
        let groupID = UUID()
        for member in [web, page] {
            member.splitGroupID = groupID
            member.splitFraction = 0.3
            f.space.tabs.append(member)
        }

        f.store.undoManager.removeAllActions()
        f.store.closeSplitGroup(groupID: groupID, in: f.space)
        let newBase = try reloadContext(f.ext, in: f.profile, from: f.base)

        f.store.undoManager.undo()

        XCTAssertEqual(f.space.tabs.map(\.url), [webURL, rewriteExtensionPageURL(extURL, from: f.base, to: newBase)])
        XCTAssertNotNil(f.space.tabs[0].splitGroupID)
        XCTAssertEqual(f.space.tabs[0].splitGroupID, f.space.tabs[1].splitGroupID, "the split is rejoined")
        XCTAssertEqual(f.space.tabs[1].splitFraction, 0.3)
        XCTAssertFalse(f.space.tabs[0].isSleeping)
        XCTAssertTrue(f.space.tabs[1].isSleeping)
        XCTAssertTrue(f.store.closedTabStack.isEmpty)

        f.store.undoManager.redo()
        XCTAssertTrue(f.space.tabs.isEmpty, "redo closes both again")
    }

    func testUndoCloseBothSplitsWithAnUninstalledMemberRestoresTheOtherAlone() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let before = sleepingTab(URL(string: "https://before.example/")!, in: f.space)
        f.space.tabs.append(before)
        let extURL = try pageURL("options.html", on: f.base)
        let webURL = try XCTUnwrap(URL(string: "https://example.com/"))
        let page = sleepingTab(extURL, in: f.space)
        let web = sleepingTab(webURL, in: f.space)
        let groupID = UUID()
        for member in [page, web] {
            member.splitGroupID = groupID
            member.splitFraction = 0.5
            f.space.tabs.append(member)
        }

        f.store.undoManager.removeAllActions()
        f.store.closeSplitGroup(groupID: groupID, in: f.space)
        _ = f.profile.unloadExtension(id: f.ext.id)
        f.db.deleteExtension(id: f.ext.id)

        f.store.undoManager.undo()

        XCTAssertEqual(f.space.tabs.map(\.url), [before.url, webURL], "only the ordinary member comes back")
        XCTAssertNil(f.space.tabs[1].splitGroupID, "alone, without a split group")
        XCTAssertNil(f.space.tabs[1].splitFraction)
        XCTAssertEqual(f.store.closedTabStack.map(\.url), [extURL.absoluteString],
                       "the web member's record is consumed, the extension member's is left alone")

        XCTAssertTrue(f.store.undoManager.canRedo)
        f.store.undoManager.redo()
        XCTAssertEqual(f.space.tabs.map(\.id), [before.id], "redo closes the restored member")
    }

    func testUndoCloseBothSplitsWithBothMembersDisabledRestoresNothing() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let groupID = UUID()
        for query in ["a=1", "b=2"] {
            let member = sleepingTab(try pageURL("options.html?\(query)", on: f.base), in: f.space)
            member.splitGroupID = groupID
            member.splitFraction = 0.5
            f.space.tabs.append(member)
        }

        f.store.undoManager.removeAllActions()
        f.store.closeSplitGroup(groupID: groupID, in: f.space)
        f.db.setProfileExtensionEnabled(extensionID: f.ext.id, profileID: f.profile.id.uuidString, enabled: false)
        _ = f.profile.unloadExtension(id: f.ext.id)

        f.store.undoManager.undo()

        XCTAssertTrue(f.space.tabs.isEmpty)
        XCTAssertFalse(f.store.undoManager.canRedo)
        XCTAssertEqual(f.store.closedTabStack.count, 2)
    }

    // MARK: - Pinned entry Close Tab

    func testUndoClosePinnedEntryTabAfterAContextReloadUsesTheNewBase() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let url = try pageURL("options.html?pinned=1", on: f.base)
        let page = sleepingTab(url, in: f.space)
        f.space.tabs.append(page)
        f.store.pinTab(id: page.id, in: f.space)
        let entry = try XCTUnwrap(f.space.pinnedEntries.first)
        XCTAssertEqual(entry.tab?.id, page.id)

        f.store.undoManager.removeAllActions()
        f.store.closePinnedTab(id: entry.id, in: f.space)
        XCTAssertNil(entry.tab)
        let newBase = try reloadContext(f.ext, in: f.profile, from: f.base)

        f.store.undoManager.undo()

        let restored = try XCTUnwrap(entry.tab)
        XCTAssertEqual(restored.url, rewriteExtensionPageURL(url, from: f.base, to: newBase))
        XCTAssertTrue(restored.isSleeping)

        f.store.undoManager.redo()
        XCTAssertNil(entry.tab, "redo closes it again")
    }

    func testUndoClosePinnedEntryTabOfADisabledExtensionLeavesTheEntryDormant() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let page = sleepingTab(try pageURL("options.html", on: f.base), in: f.space)
        f.space.tabs.append(page)
        f.store.pinTab(id: page.id, in: f.space)
        let entry = try XCTUnwrap(f.space.pinnedEntries.first)

        f.store.undoManager.removeAllActions()
        f.store.closePinnedTab(id: entry.id, in: f.space)
        f.db.setProfileExtensionEnabled(extensionID: f.ext.id, profileID: f.profile.id.uuidString, enabled: false)
        _ = f.profile.unloadExtension(id: f.ext.id)

        f.store.undoManager.undo()

        XCTAssertNil(entry.tab, "no dead tab: the entry stays dormant")
        XCTAssertEqual(f.space.pinnedEntries.map(\.id), [entry.id])
        XCTAssertFalse(f.store.undoManager.canRedo)
    }

    // MARK: - Delete Space

    func testUndoDeleteSpaceRehostsExtensionPagesAndDropsUninstalledOnes() async throws {
        let f = try await makeFixture()
        defer { teardownTabs(f) }
        let other = try await makeExtension()
        install(other, in: f.db)
        let otherBase = try loadContext(other, in: f.profile).baseURL

        let space2 = f.store.addSpace(name: "Two", emoji: "2️⃣", colorHex: "FF0000", profileID: f.profile.id)
        let extURL = try pageURL("options.html?kept=1", on: f.base)
        let goneURL = try pageURL("options.html?gone=1", on: otherBase)
        let pinnedURL = try pageURL("options.html?pinned=1", on: f.base)
        let webURL = try XCTUnwrap(URL(string: "https://example.com/"))

        let kept = sleepingTab(extURL, in: space2)
        let gone = sleepingTab(goneURL, in: space2)
        let web = sleepingTab(webURL, in: space2)
        let groupID = UUID()
        for member in [gone, web] { member.splitGroupID = groupID; member.splitFraction = 0.5 }
        space2.tabs.append(contentsOf: [kept, gone, web])
        space2.selectedTabID = gone.id
        let pinnedTab = sleepingTab(pinnedURL, in: space2)
        space2.tabs.append(pinnedTab)
        f.store.pinTab(id: pinnedTab.id, in: space2)

        f.store.undoManager.removeAllActions()
        f.store.deleteSpace(id: space2.id)
        let newBase = try reloadContext(f.ext, in: f.profile, from: f.base)
        _ = f.profile.unloadExtension(id: other.id)
        f.db.deleteExtension(id: other.id)

        f.store.undoManager.undo()

        let restored = try XCTUnwrap(f.store.space(withID: space2.id))
        defer { for tab in restored.tabs + restored.pinnedTabs { tab.teardown() } }
        func moved(_ url: URL) -> URL? { rewriteExtensionPageURL(url, from: f.base, to: newBase) }

        XCTAssertEqual(restored.tabs.map(\.id), [kept.id, web.id], "the uninstalled extension's tab is dropped")
        XCTAssertEqual(restored.tabs[0].url, moved(extURL))
        XCTAssertTrue(restored.tabs[0].isSleeping)
        XCTAssertEqual(restored.tabs[1].url, webURL)
        XCTAssertNil(restored.tabs[1].splitGroupID, "its split partner is left a lone tab")
        XCTAssertEqual(restored.selectedTabID, kept.id, "selection moves off the dropped tab")

        let entry = try XCTUnwrap(restored.pinnedEntries.first)
        XCTAssertEqual(entry.pinnedURL, moved(pinnedURL), "the entry's home page moves to the live origin")
        XCTAssertEqual(entry.tab?.id, pinnedTab.id)
        XCTAssertEqual(entry.tab?.url, moved(pinnedURL))
    }

    // MARK: - Through the display path

    /// Against the shared store: the restored tab actually wakes into its
    /// context's configuration and loads on the live origin.
    func testUndoneExtensionPageWakesOntoTheLiveOrigin() async throws {
        let ext = try await makeExtension()
        install(ext, in: AppDatabase.shared)
        sharedExtensionIDs.append(ext.id)
        let store = TabStore.shared
        let profile = store.addProfile(name: "Undo-shared")
        sharedProfiles.append(profile)
        let space = store.addSpace(name: "Undo-shared", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        sharedSpaceIDs.append(space.id)
        _ = profile.extensionController
        let base = try loadContext(ext, in: profile).baseURL
        let url = try pageURL("options.html?wake=1", on: base)
        let page = sleepingTab(url, in: space)
        space.tabs.append(page)

        store.undoManager.removeAllActions()
        store.closeTab(id: page.id, in: space)
        let newBase = try reloadContext(ext, in: profile, from: base)
        store.undoManager.undo()

        let restored = try XCTUnwrap(space.tabs.first)
        let expected = try XCTUnwrap(rewriteExtensionPageURL(url, from: base, to: newBase))
        XCTAssertEqual(restored.url, expected)
        restored.wake()
        XCTAssertEqual(restored.webView?.url, expected, "woken from the context's configuration onto the live origin")
    }
}
