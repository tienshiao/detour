import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-103: browser-side entry points to an extension's options page. The pure
/// rules (`ExtensionOptionsPageEntry`) and the per-profile tab resolution
/// (`ExtensionManager.optionsPageTab(for:in:preferring:)`), driven against real
/// Profiles and Spaces in the shared `TabStore` and `AppDatabase`.
@MainActor
final class ExtensionOptionsPageEntryTests: XCTestCase {

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
        for id in registeredExtensionIDs {
            for profile in TabStore.shared.profiles {
                profile.unloadExtension(id: id)
            }
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            try? AppDatabase.shared.dbQueue.write { db in
                _ = try ProfileExtensionRecord
                    .filter(Column("extensionID") == id)
                    .deleteAll(db)
            }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        createdProfiles.removeAll()
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func parse(_ json: String) throws -> ExtensionManifest {
        try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    }

    private func makeTestExtension(named name: String) async throws -> WebExtension {
        let ext = try await makeOptionsPageTestExtension(idPrefix: "options-entry-\(name)",
                                                         name: "Options Entry Test \(name)")
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(ext.id)
        installTestExtension(ext, in: AppDatabase.shared,
                             manifestJSON: try testExtensionManifestData(ext))
        return ext
    }

    private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        _ = profile.extensionController
        return profile
    }

    private func makeSpace(_ name: String, in profile: Profile) -> Space {
        let space = TabStore.shared.addSpace(name: name, emoji: "🧪", colorHex: "007AFF",
                                             profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    // MARK: - hasOptionsPage

    func testHasOptionsPageFromOptionsPage() throws {
        let manifest = try parse("""
        {"manifest_version": 3, "name": "T", "version": "1.0", "options_page": "options.html"}
        """)
        XCTAssertTrue(ExtensionOptionsPageEntry.hasOptionsPage(manifest))
    }

    func testHasOptionsPageFromOptionsUI() throws {
        let manifest = try parse("""
        {"manifest_version": 3, "name": "T", "version": "1.0", "options_ui": {"page": "settings.html"}}
        """)
        XCTAssertTrue(ExtensionOptionsPageEntry.hasOptionsPage(manifest))
    }

    func testEmptyStringsMeanNoOptionsPage() throws {
        let manifest = try parse("""
        {"manifest_version": 3, "name": "T", "version": "1.0",
         "options_page": "", "options_ui": {"page": ""}}
        """)
        XCTAssertFalse(ExtensionOptionsPageEntry.hasOptionsPage(manifest))
    }

    func testNoOptionsKeysMeansNoOptionsPage() throws {
        let manifest = try parse("""
        {"manifest_version": 3, "name": "T", "version": "1.0"}
        """)
        XCTAssertFalse(ExtensionOptionsPageEntry.hasOptionsPage(manifest))
    }

    func testEmptyOptionsPageFallsBackToOptionsUI() throws {
        let manifest = try parse("""
        {"manifest_version": 3, "name": "T", "version": "1.0",
         "options_page": "", "options_ui": {"page": "options.html"}}
        """)
        XCTAssertTrue(ExtensionOptionsPageEntry.hasOptionsPage(manifest))
    }

    // MARK: - Profile resolution

    private let privateID = TabStore.incognitoProfileID
    private let a = UUID()
    private let b = UUID()

    private func resolve(_ candidates: [UUID], enabled: Set<UUID>) -> UUID? {
        ExtensionOptionsPageEntry.resolveProfile(
            candidates: candidates,
            isEnabled: { enabled.contains($0) },
            isPrivate: { $0 == self.privateID }
        )
    }

    func testResolvesFirstEnabledCandidate() {
        XCTAssertEqual(resolve([a, b], enabled: [a, b]), a)
        XCTAssertEqual(resolve([a, b], enabled: [b]), b,
                       "skips a preferred profile where the extension is off")
        XCTAssertEqual(resolve([a, a, b], enabled: [b]), b, "duplicates are harmless")
    }

    func testNoEnabledCandidateResolvesToNil() {
        XCTAssertNil(resolve([a, b], enabled: []))
        XCTAssertNil(resolve([], enabled: [a]))
    }

    func testPrivateQualifiesWhenFirst() {
        XCTAssertEqual(resolve([privateID, a], enabled: [privateID, a]), privateID,
                       "the main window is Private and the extension is allowed there")
        XCTAssertEqual(resolve([privateID, a], enabled: [a]), a,
                       "Private first but off there: fall through to a normal profile")
    }

    func testPrivateNeverQualifiesAfterTheFirstCandidate() {
        XCTAssertEqual(resolve([a, privateID, b], enabled: [privateID, b]), b,
                       "a background Private window must not capture the click")
        XCTAssertNil(resolve([a, privateID], enabled: [privateID]))
    }

    // MARK: - isOptionsPage

    func testIsOptionsPageMatchesOriginAndPathIgnoringQueryAndFragment() throws {
        let base = try XCTUnwrap(URL(string: "webkit-extension://AAAA/"))
        let options = try XCTUnwrap(URL(string: "webkit-extension://AAAA/options.html"))
        func matches(_ s: String) -> Bool {
            ExtensionManager.isOptionsPage(URL(string: s), optionsURL: options, baseURL: base)
        }
        XCTAssertTrue(matches("webkit-extension://AAAA/options.html"))
        XCTAssertTrue(matches("webkit-extension://AAAA/options.html?tab=2#general"))
        XCTAssertFalse(matches("webkit-extension://BBBB/options.html"), "another context's origin")
        XCTAssertFalse(matches("webkit-extension://AAAA/popup.html"))
        XCTAssertFalse(matches("https://AAAA/options.html"))
        XCTAssertFalse(ExtensionManager.isOptionsPage(nil, optionsURL: options, baseURL: base))
    }

    // MARK: - optionsPageTab (integration)

    func testOptionsPageOpensInTheRequestedProfileAndIsReused() async throws {
        let ext = try await makeTestExtension(named: "per-profile")
        let profileA = makeProfile("Options Entry A")
        let profileB = makeProfile("Options Entry B")
        let spaceA = makeSpace("Options Entry A", in: profileA)
        let spaceB = makeSpace("Options Entry B", in: profileB)
        let contextA = try loadTestContext(ext, in: profileA)
        let contextB = try loadTestContext(ext, in: profileB)
        XCTAssertNotEqual(contextA.baseURL.host, contextB.baseURL.host,
                          "precondition: each profile's context has its own origin")

        // B's page is open first: it must not be mistaken for A's.
        let openedB = try XCTUnwrap(ExtensionManager.shared.optionsPageTab(for: ext.id, in: profileB))
        XCTAssertTrue(openedB.space === spaceB)

        let openedA = try XCTUnwrap(ExtensionManager.shared.optionsPageTab(for: ext.id, in: profileA))
        XCTAssertTrue(openedA.space === spaceA, "the page opens in the requested profile's space")
        XCTAssertNotEqual(openedA.tab.id, openedB.tab.id)
        let urlA = try XCTUnwrap(openedA.tab.webView?.url)
        XCTAssertEqual(urlA.host, contextA.baseURL.host, "served by A's context")
        XCTAssertNotEqual(urlA.host, contextB.baseURL.host)
        XCTAssertEqual(urlA.path, "/options.html")
        XCTAssertTrue(spaceA.tabs.contains { $0.id == openedA.tab.id })

        let again = try XCTUnwrap(ExtensionManager.shared.optionsPageTab(for: ext.id, in: profileA))
        XCTAssertEqual(again.tab.id, openedA.tab.id, "an open options page is reused, not duplicated")
        XCTAssertTrue(again.space === spaceA)
        XCTAssertEqual(spaceA.tabs.filter {
            ExtensionManager.isOptionsPage($0.webView?.url, optionsURL: urlA, baseURL: contextA.baseURL)
        }.count, 1)
    }

    func testOptionsPageOpensInThePreferredSpaceOfTheProfile() async throws {
        let ext = try await makeTestExtension(named: "preferred")
        let profileA = makeProfile("Options Entry Preferred A")
        let profileB = makeProfile("Options Entry Preferred B")
        let firstA = makeSpace("Options Entry Preferred A1", in: profileA)
        let secondA = makeSpace("Options Entry Preferred A2", in: profileA)
        let spaceB = makeSpace("Options Entry Preferred B", in: profileB)
        _ = try loadTestContext(ext, in: profileA)

        // A space of another profile is not a valid preference: first space of A.
        let viaOther = try XCTUnwrap(ExtensionManager.shared.optionsPageTab(
            for: ext.id, in: profileA, preferring: spaceB.id))
        XCTAssertTrue(viaOther.space === firstA)
        XCTAssertFalse(spaceB.tabs.contains { $0.id == viaOther.tab.id })
        viaOther.tab.teardown()
        TabStore.shared.forceRemoveSpace(id: viaOther.space.id)

        let preferred = try XCTUnwrap(ExtensionManager.shared.optionsPageTab(
            for: ext.id, in: profileA, preferring: secondA.id))
        XCTAssertTrue(preferred.space === secondA)
    }

    func testNoTabWhereTheExtensionIsOff() async throws {
        let ext = try await makeTestExtension(named: "off")
        let profileC = makeProfile("Options Entry Off")
        let spaceC = makeSpace("Options Entry Off", in: profileC)
        _ = try loadTestContext(ext, in: profileC)
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profileC.id, enabled: false)
        XCTAssertNil(profileC.extensionContext(for: ext.id), "precondition: unloaded by the toggle")

        XCTAssertNil(ExtensionManager.shared.optionsPageTab(for: ext.id, in: profileC))
        XCTAssertFalse(ExtensionManager.shared.openOptionsPage(for: ext.id, in: profileC))
        XCTAssertTrue(spaceC.tabs.isEmpty, "nothing opens in a profile that has the extension off")
    }

    func testNoTabWhenTheProfileHasNoSpace() async throws {
        let ext = try await makeTestExtension(named: "no-space")
        let profile = makeProfile("Options Entry No Space")
        _ = try loadTestContext(ext, in: profile)
        XCTAssertNil(ExtensionManager.shared.optionsPageTab(for: ext.id, in: profile))
    }
}
