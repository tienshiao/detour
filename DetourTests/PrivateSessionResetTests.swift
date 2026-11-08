import GRDB
import WebKit
import XCTest
@testable import Detour

/// TASK-298: a Private session's data ends with the session. The built-in
/// Private profile object, its non-persistent store and its extension
/// controller are reused by every Private session, so `endPrivateSessionIfUnused`
/// wipes the store and resets the Private extension contexts once no Private
/// window or Private Quick Detour is left — and only then.
nonisolated final class PrivateSessionResetTests: XCTestCase {

    // MARK: - Website data

    @MainActor private func makeStore() throws -> TabStore {
        TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()))
    }

    @MainActor private func privateProfile(of store: TabStore) throws -> Profile {
        try XCTUnwrap(store.profile(withID: TabStore.incognitoProfileID), "the Private profile should exist")
    }

    @MainActor private func setCookie(_ name: String, in profile: Profile) async throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "detour-test.example", .path: "/", .name: name, .value: "1",
        ]))
        await profile.dataStore.httpCookieStore.setCookie(cookie)
    }

    @MainActor private func cookieNames(in profile: Profile) async -> [String] {
        await profile.dataStore.httpCookieStore.allCookies().map(\.name).sorted()
    }

    @MainActor func testClosingTheLastPrivateWindowClearsTheSessionsWebsiteData() async throws {
        let store = try makeStore()
        let space = store.addIncognitoSpace()
        let profile = try privateProfile(of: store)
        try await setCookie("session1", in: profile)
        let before = await cookieNames(in: profile)
        XCTAssertEqual(before, ["session1"], "precondition: the session's cookie is set")

        store.removeIncognitoSpace(id: space.id)
        let reset = try XCTUnwrap(profile.privateSessionReset, "closing the last Private window must reset the session")
        await reset.value

        let after = await cookieNames(in: profile)
        XCTAssertEqual(after, [], "the next Private session must not see the previous one's cookies")
        let records = await profile.dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        XCTAssertTrue(records.isEmpty, "no website data of any type may survive the session: \(records.map(\.displayName))")
    }

    @MainActor func testPrivateWindowsShareTheSessionUntilTheLastOneCloses() async throws {
        let store = try makeStore()
        let first = store.addIncognitoSpace()
        let second = store.addIncognitoSpace()
        let profile = try privateProfile(of: store)
        try await setCookie("shared", in: profile)

        store.removeIncognitoSpace(id: first.id)
        XCTAssertNil(profile.privateSessionReset, "a Private window still open keeps the session")
        let whileOpen = await cookieNames(in: profile)
        XCTAssertEqual(whileOpen, ["shared"], "the open Private window keeps the session's cookies")

        store.removeIncognitoSpace(id: second.id)
        await profile.privateSessionReset?.value
        let after = await cookieNames(in: profile)
        XCTAssertEqual(after, [], "the last Private window closing ends the session")
    }

    @MainActor func testANewSessionAfterTheResetStartsEmptyAndKeepsItsOwnData() async throws {
        let store = try makeStore()
        let space = store.addIncognitoSpace()
        let profile = try privateProfile(of: store)
        try await setCookie("old", in: profile)
        store.removeIncognitoSpace(id: space.id)
        await profile.privateSessionReset?.value

        _ = store.addIncognitoSpace()
        try await setCookie("new", in: profile)
        let names = await cookieNames(in: profile)
        XCTAssertEqual(names, ["new"], "the next session uses the same store, empty, and keeps what it sets")
    }

    @MainActor func testANormalProfileIsNeverReset() {
        let profile = Profile(name: "Normal \(UUID().uuidString.prefix(6))")
        profile.resetPrivateSession()
        XCTAssertNil(profile.privateSessionReset, "only the Private profile has a session to reset")
    }

    // MARK: - Extensions allowed in Private

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var openPages: [WKWebView] = []

    @MainActor override func tearDown() async throws {
        openPages.removeAll()
        for id in registeredExtensionIDs {
            for profile in TabStore.shared.profiles {
                profile.unloadExtension(id: id)
            }
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            Self.deleteRows(forExtension: id)
        }
        registeredExtensionIDs.removeAll()
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    private nonisolated static func deleteRows(forExtension id: String) {
        try? AppDatabase.shared.dbQueue.write { db in
            _ = try ProfileExtensionRecord.filter(Column("extensionID") == id).deleteAll(db)
        }
        AppDatabase.shared.deleteExtension(id: id)
    }

    /// An installed extension with the storage permission and an options page
    /// to run `chrome.storage` from, registered with the shared manager.
    @MainActor private func makeStorageExtension() async throws -> WebExtension {
        let ext = try await makeTestExtension(
            id: "private-reset-\(UUID().uuidString.prefix(8))",
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Private Reset Probe",
                "version": "1.0.0",
                "permissions": ["storage"],
                "options_ui": { "page": "options.html" }
            }
            """,
            files: optionsPageTestFiles)
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(ext.id)
        installTestExtension(ext, in: AppDatabase.shared, manifestJSON: try testExtensionManifestData(ext))
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        return ext
    }

    /// Runs `body` in a fresh options page of `context` and returns its string result.
    @MainActor private func runInExtensionPage(_ body: String, context: WKWebExtensionContext) async throws -> String {
        context.setPermissionStatus(.grantedExplicitly, for: .storage)
        let config = try XCTUnwrap(context.webViewConfiguration, "the context should be loaded")
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        openPages.append(page)
        try await loadAndWait(page, URLRequest(url: context.baseURL.appendingPathComponent("options.html")))
        let raw = try await page.callAsyncJavaScript(body, arguments: [:], contentWorld: .page)
        openPages.removeAll { $0 === page }
        return try XCTUnwrap(raw as? String, "expected a string, got \(String(describing: raw))")
    }

    @MainActor func testAnExtensionAllowedInPrivateIsReloadedWithEmptyStorage() async throws {
        let ext = try await makeStorageExtension()
        let profile = TabStore.shared.ensureIncognitoProfile()
        AppDatabase.shared.saveProfile(profile.toRecord())
        _ = profile.extensionController
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: true)
        let oldContext = try XCTUnwrap(profile.extensionContexts[ext.id], "Allow in Private should load the context")

        let written = try await runInExtensionPage(
            "await chrome.storage.local.set({ k: 'session1' }); return JSON.stringify(await chrome.storage.local.get('k'));",
            context: oldContext)
        XCTAssertEqual(written, #"{"k":"session1"}"#, "precondition: the Private copy stored something")

        profile.resetPrivateSession()
        await profile.privateSessionReset?.value

        let newContext = try XCTUnwrap(profile.extensionContexts[ext.id],
                                       "an extension still allowed in Private is loaded again for the next session")
        XCTAssertFalse(newContext === oldContext, "the reset replaces the context")
        XCTAssertNotEqual(newContext.baseURL, oldContext.baseURL, "the new context runs on a new origin")
        let read = try await runInExtensionPage(
            "return JSON.stringify(await chrome.storage.local.get('k'));", context: newContext)
        XCTAssertEqual(read, "{}", "nothing the extension stored in the previous Private session may survive it")
    }

    @MainActor func testAnExtensionDisallowedDuringTheResetIsNotReloaded() async throws {
        let ext = try await makeStorageExtension()
        let profile = TabStore.shared.ensureIncognitoProfile()
        AppDatabase.shared.saveProfile(profile.toRecord())
        _ = profile.extensionController
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: true)
        XCTAssertNotNil(profile.extensionContexts[ext.id], "precondition: loaded in Private")

        profile.resetPrivateSession()
        // The reset runs on later main-actor turns; turning the extension off
        // in Private before it reloads must win.
        AppDatabase.shared.setProfileExtensionEnabled(extensionID: ext.id, profileID: profile.id.uuidString, enabled: false)
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        await profile.privateSessionReset?.value

        XCTAssertNil(profile.extensionContexts[ext.id], "an extension no longer allowed in Private stays unloaded")
    }
}
