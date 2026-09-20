import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-26: an extension is enabled in a profile iff it is enabled globally AND
/// the profile's own answer is on (no per-profile row = the profile's default:
/// on, except in the built-in Private profile — TASK-74,
/// `ExtensionPrivateDefaultTests`). The global and
/// per-profile toggles each write only their own flag, and every path that
/// loads a context — launch (`loadExtensionsIntoProfile`) and both
/// `ExtensionManager.setEnabled` overloads — applies that one rule. These tests
/// drive the real toggles against real Profiles in the shared `TabStore` and
/// `AppDatabase` (the test scheme isolates the data directory).
@MainActor
final class ExtensionEnabledStateTests: XCTestCase {

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
            // A global enable reaches every profile in the store, including the
            // host app's own, so unload from all of them.
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

    /// A minimal MV3 extension with an options page and no background content,
    /// installed (DB row) as globally enabled.
    private func makeTestExtension(named name: String) async throws -> WebExtension {
        let ext = try await makeOptionsPageTestExtension(idPrefix: "enabled-state-\(name)",
                                                         name: "Enabled State Test \(name)")
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

    private func openOptionsPage(_ ext: WebExtension, in profile: Profile, space: Space) throws -> BrowserTab {
        let context = try XCTUnwrap(profile.extensionContexts[ext.id],
                                    "precondition: the context should be loaded in \(profile.name)")
        let pageURL = try XCTUnwrap(URL(string: "options.html", relativeTo: context.baseURL)?.absoluteURL)
        let config = try XCTUnwrap(context.webViewConfiguration)
        let tab = TabStore.shared.addExtensionTab(in: space, url: pageURL, configuration: config)
        XCTAssertEqual(tab.webView?.url, pageURL, "precondition: the tab should show the extension page")
        return tab
    }

    private func isLoaded(_ ext: WebExtension, in profile: Profile) -> Bool {
        profile.extensionContexts[ext.id] != nil
    }

    private func assertLoaded(_ ext: WebExtension, in profile: Profile, _ expected: Bool,
                              _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(isLoaded(ext, in: profile), expected, "\(profile.name): \(message)",
                       file: file, line: line)
        XCTAssertEqual(ExtensionManager.shared.isEnabled(extensionID: ext.id, inProfile: profile.id), expected,
                       "\(profile.name): the rule must agree with the loaded state — \(message)",
                       file: file, line: line)
        XCTAssertEqual(ExtensionManager.shared.enabledExtensions(for: profile.id).contains { $0.id == ext.id },
                       expected,
                       "\(profile.name): the per-profile extension list must agree — \(message)",
                       file: file, line: line)
    }

    private func profileRow(_ ext: WebExtension, _ profile: Profile) -> Bool {
        AppDatabase.shared.isExtensionEnabledByProfile(extensionID: ext.id, profileID: profile.id.uuidString)
    }

    // MARK: - AC #1: global enable respects per-profile rows

    func testGlobalReEnableSkipsAProfileThatTurnedTheExtensionOff() async throws {
        let ext = try await makeTestExtension(named: "global-reenable")
        let a = makeProfile("Enabled State A")
        let b = makeProfile("Enabled State B")
        ExtensionManager.shared.loadExtensionsIntoProfile(a)
        ExtensionManager.shared.loadExtensionsIntoProfile(b)
        assertLoaded(ext, in: a, true, "precondition: loads at launch with no rows")
        assertLoaded(ext, in: b, true, "precondition: loads at launch with no rows")

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: b.id, enabled: false)
        assertLoaded(ext, in: a, true, "a per-profile disable elsewhere must not unload it here")
        assertLoaded(ext, in: b, false, "a per-profile disable unloads it")

        ExtensionManager.shared.setEnabled(id: ext.id, enabled: false)
        assertLoaded(ext, in: a, false, "a global disable unloads it everywhere")
        assertLoaded(ext, in: b, false, "a global disable unloads it everywhere")
        XCTAssertFalse(profileRow(ext, b), "a global disable must keep the per-profile choice")
        XCTAssertTrue(profileRow(ext, a), "a global disable must not write per-profile rows")

        ExtensionManager.shared.setEnabled(id: ext.id, enabled: true)
        assertLoaded(ext, in: a, true, "a global enable loads it where the profile has no row")
        assertLoaded(ext, in: b, false, "a global enable must not load it where the profile turned it off")
    }

    func testGlobalEnableLoadsWhereTheProfileRowIsExplicitlyOn() async throws {
        let ext = try await makeTestExtension(named: "explicit-on")
        let a = makeProfile("Enabled State Explicit A")
        let b = makeProfile("Enabled State Explicit B")
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: a.id, enabled: true)
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: b.id, enabled: false)
        ExtensionManager.shared.setEnabled(id: ext.id, enabled: false)

        ExtensionManager.shared.setEnabled(id: ext.id, enabled: true)
        assertLoaded(ext, in: a, true, "an explicitly-on row loads on global enable")
        assertLoaded(ext, in: b, false, "an explicitly-off row stays unloaded on global enable")
    }

    // MARK: - AC #2: per-profile toggles while globally disabled

    func testPerProfileEnableWhileGloballyDisabledDoesNotLoad() async throws {
        let ext = try await makeTestExtension(named: "profile-enable-while-off")
        let a = makeProfile("Enabled State Off A")
        let b = makeProfile("Enabled State Off B")
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: b.id, enabled: false)
        ExtensionManager.shared.setEnabled(id: ext.id, enabled: false)

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: b.id, enabled: true)
        assertLoaded(ext, in: b, false, "a per-profile enable while globally off must not load it")
        assertLoaded(ext, in: a, false, "nor load it in any other profile")
        XCTAssertTrue(profileRow(ext, b), "the per-profile choice is still saved")

        ExtensionManager.shared.setEnabled(id: ext.id, enabled: true)
        assertLoaded(ext, in: a, true, "the saved choice takes effect on global enable")
        assertLoaded(ext, in: b, true, "the saved choice takes effect on global enable")
    }

    func testPerProfileDisableWhileGloballyDisabledIsHonouredOnReEnable() async throws {
        let ext = try await makeTestExtension(named: "profile-disable-while-off")
        let a = makeProfile("Enabled State Off Disable A")
        let b = makeProfile("Enabled State Off Disable B")
        ExtensionManager.shared.setEnabled(id: ext.id, enabled: false)

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: a.id, enabled: false)
        assertLoaded(ext, in: a, false, "a per-profile disable while globally off is a no-op for loading")
        assertLoaded(ext, in: b, false, "still globally off")

        ExtensionManager.shared.setEnabled(id: ext.id, enabled: true)
        assertLoaded(ext, in: a, false, "the choice made while globally off must stick")
        assertLoaded(ext, in: b, true, "an untouched profile loads it")
    }

    func testRepeatedTogglesAreIdempotent() async throws {
        let ext = try await makeTestExtension(named: "idempotent")
        let a = makeProfile("Enabled State Idempotent")
        ExtensionManager.shared.loadExtensionsIntoProfile(a)
        let first = try XCTUnwrap(a.extensionContexts[ext.id])

        ExtensionManager.shared.setEnabled(id: ext.id, enabled: true)
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: a.id, enabled: true)
        XCTAssertTrue(a.extensionContexts[ext.id] === first,
                      "enabling an already-enabled extension must not replace its context")
    }

    // MARK: - Launch path uses the same rule

    func testLaunchLoadAppliesBothFlags() async throws {
        let ext = try await makeTestExtension(named: "launch")
        let a = makeProfile("Enabled State Launch A")
        let b = makeProfile("Enabled State Launch B")
        // Saved state as a previous session left it.
        AppDatabase.shared.setProfileExtensionEnabled(extensionID: ext.id, profileID: b.id.uuidString, enabled: false)

        ExtensionManager.shared.loadExtensionsIntoProfile(a)
        ExtensionManager.shared.loadExtensionsIntoProfile(b)
        assertLoaded(ext, in: a, true, "launch loads it where the profile has no row")
        assertLoaded(ext, in: b, false, "launch must not load it where the profile turned it off")

        for profile in [a, b] { profile.unloadAllExtensions() }
        AppDatabase.shared.setEnabled(id: ext.id, enabled: false)
        AppDatabase.shared.setProfileExtensionEnabled(extensionID: ext.id, profileID: b.id.uuidString, enabled: true)
        ext.isEnabled = false
        ExtensionManager.shared.invalidateEnabledExtensionsCache()

        ExtensionManager.shared.loadExtensionsIntoProfile(a)
        ExtensionManager.shared.loadExtensionsIntoProfile(b)
        assertLoaded(ext, in: a, false, "launch must not load a globally disabled extension")
        assertLoaded(ext, in: b, false, "an explicitly-on row does not override the global flag")
    }

    // MARK: - Pages close only in the profile that unloaded

    func testDisablingInOneProfileClosesOnlyThatProfilesPages() async throws {
        let ext = try await makeTestExtension(named: "pages")
        let a = makeProfile("Enabled State Pages A")
        let b = makeProfile("Enabled State Pages B")
        let spaceA = makeSpace("Enabled State Pages A", in: a)
        let spaceB = makeSpace("Enabled State Pages B", in: b)
        ExtensionManager.shared.loadExtensionsIntoProfile(a)
        ExtensionManager.shared.loadExtensionsIntoProfile(b)
        let pageA = try openOptionsPage(ext, in: a, space: spaceA)
        let pageB = try openOptionsPage(ext, in: b, space: spaceB)

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: b.id, enabled: false)
        XCTAssertFalse(spaceB.tabs.contains { $0.id == pageB.id },
                       "the page in the profile that turned the extension off must close")
        XCTAssertTrue(spaceA.tabs.contains { $0.id == pageA.id },
                      "the same extension's page in another profile must survive")
        XCTAssertNotNil(pageA.webView)

        // Globally off: only the profile that still had a context has pages to close.
        ExtensionManager.shared.setEnabled(id: ext.id, enabled: false)
        XCTAssertFalse(spaceA.tabs.contains { $0.id == pageA.id },
                       "a global disable closes the remaining profile's page")

        // A per-profile toggle while globally off neither loads nor opens anything.
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: b.id, enabled: true)
        assertLoaded(ext, in: b, false, "still globally off")
    }

    // MARK: - Pinned toolbar icons follow the rule

    func testPinnedExtensionsHideWhereTheExtensionIsDisabled() async throws {
        let ext = try await makeTestExtension(named: "pinned")
        let a = makeProfile("Enabled State Pinned")
        AppDatabase.shared.toggleExtensionPinned(extensionID: ext.id, profileID: a.id.uuidString)
        XCTAssertTrue(ExtensionManager.shared.pinnedExtensions(for: a.id).contains { $0.id == ext.id })

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: a.id, enabled: false)
        XCTAssertFalse(ExtensionManager.shared.pinnedExtensions(for: a.id).contains { $0.id == ext.id },
                       "a pinned icon must not show in a profile that turned the extension off")

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: a.id, enabled: true)
        ExtensionManager.shared.setEnabled(id: ext.id, enabled: false)
        XCTAssertFalse(ExtensionManager.shared.pinnedExtensions(for: a.id).contains { $0.id == ext.id },
                       "nor while the extension is globally off")
    }
}
