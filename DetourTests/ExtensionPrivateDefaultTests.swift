import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-74: extensions are OFF in the built-in Private profile
/// (`TabStore.incognitoProfileID`) until the user allows each one, and
/// unchanged — on — in every other profile. The rule lives in
/// `AppDatabase.extensionEnabledByDefault(inProfile:)` and every reader goes
/// through it: `isExtensionEnabled(extensionID:profileID:)`,
/// `isExtensionEnabledByProfile(extensionID:profileID:)` and
/// `enabledExtensionIDs(for:)` must never disagree.
///
/// Why it was more than a default when it landed: the Private profile's
/// extension pages then ran in WebKit's *default persistent* store, so an
/// extension running there leaked storage past the private session. TASK-73 has
/// since moved them to the profile's own ephemeral store
/// (`ExtensionPrivateStoreTests`); the rule below is unchanged by that.
///
/// The first half drives an in-memory `AppDatabase` (the rule, and the paths
/// that write rows); the second drives the real `ExtensionManager` against the
/// shared `TabStore`'s Private profile (the live load/unload).
@MainActor
final class ExtensionPrivateDefaultTests: XCTestCase {

    private let privateID = TabStore.incognitoProfileID.uuidString
    private let normalID = "11111111-2222-3333-4444-555555555555"

    // MARK: - Database fixtures

    private func makeDatabase() throws -> AppDatabase {
        let db = try AppDatabase(dbQueue: try DatabaseQueue(configuration: Configuration()))
        db.saveProfile(profileRecord(id: privateID, name: "Private"))
        db.saveProfile(profileRecord(id: normalID, name: "Default"))
        return db
    }

    private func profileRecord(id: String, name: String) -> ProfileRecord {
        ProfileRecord(id: id, name: name, userAgentMode: 0, customUserAgent: nil,
                      archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0,
                      searchSuggestionsEnabled: true, isPerTabIsolation: false,
                      isAdBlockingEnabled: true, isEasyListEnabled: true,
                      isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true,
                      isMalwareFilterEnabled: true)
    }

    private func extensionRecord(id: String = "ext-1", version: String = "1.0",
                                 isEnabled: Bool = true) -> ExtensionRecord {
        ExtensionRecord(id: id, name: "Private Default Test", version: version,
                        manifestJSON: Data("{}".utf8), basePath: "/tmp/extensions/\(id)",
                        isEnabled: isEnabled, installedAt: Date().timeIntervalSince1970)
    }

    /// The three readers, asserted together: `isExtensionEnabled` and
    /// `enabledExtensionIDs` answer the whole rule (global AND per-profile),
    /// `isExtensionEnabledByProfile` only the profile's half.
    private func assertState(_ db: AppDatabase, _ extensionID: String, _ profileID: String,
                             enabled: Bool, byProfile: Bool, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(db.isExtensionEnabled(extensionID: extensionID, profileID: profileID), enabled,
                       "isExtensionEnabled: \(message)", file: file, line: line)
        XCTAssertEqual(db.enabledExtensionIDs(for: profileID).contains(extensionID), enabled,
                       "enabledExtensionIDs: \(message)", file: file, line: line)
        XCTAssertEqual(db.isExtensionEnabledByProfile(extensionID: extensionID, profileID: profileID),
                       byProfile, "isExtensionEnabledByProfile: \(message)", file: file, line: line)
    }

    private func rows(_ db: AppDatabase, profileID: String) throws -> [ProfileExtensionRecord] {
        try db.dbQueue.read { db in
            try ProfileExtensionRecord.filter(Column("profileID") == profileID).fetchAll(db)
        }
    }

    // MARK: - The rule

    func testMissingRowIsOffInPrivateAndOnElsewhere() throws {
        let db = try makeDatabase()
        db.saveExtension(extensionRecord())

        XCTAssertFalse(AppDatabase.extensionEnabledByDefault(inProfile: privateID),
                       "the built-in Private profile defaults to off")
        XCTAssertTrue(AppDatabase.extensionEnabledByDefault(inProfile: normalID),
                      "every other profile defaults to on")
        XCTAssertTrue(AppDatabase.extensionEnabledByDefault(inProfile: normalID.uppercased()),
                      "the id is matched as a UUID, not as a string, so case cannot flip the rule")
        XCTAssertTrue(AppDatabase.extensionEnabledByDefault(inProfile: "not-a-uuid"),
                      "only the one Private id is default-off; anything else stays on")

        assertState(db, "ext-1", privateID, enabled: false, byProfile: false,
                    "no row means off in Private")
        assertState(db, "ext-1", normalID, enabled: true, byProfile: true,
                    "no row means on in a normal profile")
        XCTAssertTrue(try rows(db, profileID: privateID).isEmpty,
                      "reading the state must not write a row")
    }

    func testAnExplicitRowWinsInBothProfiles() throws {
        let db = try makeDatabase()
        db.saveExtension(extensionRecord())

        db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: privateID, enabled: true)
        db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: normalID, enabled: false)
        assertState(db, "ext-1", privateID, enabled: true, byProfile: true,
                    "an explicit allow turns it on in Private")
        assertState(db, "ext-1", normalID, enabled: false, byProfile: false,
                    "an explicit disable turns it off in a normal profile")

        db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: privateID, enabled: false)
        db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: normalID, enabled: true)
        assertState(db, "ext-1", privateID, enabled: false, byProfile: false,
                    "disallowing in Private turns it back off")
        assertState(db, "ext-1", normalID, enabled: true, byProfile: true,
                    "re-enabling in a normal profile turns it back on")
    }

    func testTheGlobalFlagStillWinsOverAPrivateAllow() throws {
        let db = try makeDatabase()
        db.saveExtension(extensionRecord())
        db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: privateID, enabled: true)

        db.setEnabled(id: "ext-1", enabled: false)
        assertState(db, "ext-1", privateID, enabled: false, byProfile: true,
                    "globally off beats a Private allow, which is kept")
        assertState(db, "ext-1", normalID, enabled: false, byProfile: true,
                    "globally off beats the default-on profile too")
    }

    func testAnUninstalledIdIsInNeitherAnswerForEitherProfile() throws {
        let db = try makeDatabase()
        db.saveExtension(extensionRecord())
        db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: privateID, enabled: true)
        XCTAssertEqual(db.enabledExtensionIDs(for: privateID), ["ext-1"], "precondition: allowed")

        db.deleteExtension(id: "ext-1")

        // No `extension` row: neither answer may name the id, whichever way the
        // profile's default falls.
        assertState(db, "ext-1", privateID, enabled: false, byProfile: false,
                    "an uninstalled id is never enabled, and its allow is gone with it")
        assertState(db, "ext-1", normalID, enabled: false, byProfile: true,
                    "an uninstalled id is never enabled in a default-on profile either")
        XCTAssertTrue(db.enabledExtensionIDs(for: privateID).isEmpty)
        XCTAssertTrue(db.enabledExtensionIDs(for: normalID).isEmpty)
    }

    func testEnabledExtensionIDsPartitionsBothProfiles() throws {
        let db = try makeDatabase()
        db.saveExtension(extensionRecord(id: "allowed"))
        db.saveExtension(extensionRecord(id: "untouched"))
        db.saveExtension(extensionRecord(id: "refused"))
        db.setProfileExtensionEnabled(extensionID: "allowed", profileID: privateID, enabled: true)
        db.setProfileExtensionEnabled(extensionID: "refused", profileID: privateID, enabled: false)
        db.setProfileExtensionEnabled(extensionID: "refused", profileID: normalID, enabled: false)

        XCTAssertEqual(db.enabledExtensionIDs(for: privateID), ["allowed"],
                       "Private is the intersection with its explicit allows")
        XCTAssertEqual(db.enabledExtensionIDs(for: normalID), ["allowed", "untouched"],
                       "a normal profile subtracts only what it turned off")
        for id in ["allowed", "untouched", "refused"] {
            assertState(db, id, privateID,
                        enabled: id == "allowed", byProfile: id == "allowed",
                        "\(id) in Private")
            assertState(db, id, normalID,
                        enabled: id != "refused", byProfile: id != "refused",
                        "\(id) in a normal profile")
        }
    }

    // MARK: - Install / update / global re-enable leave Private alone

    func testInstallAndUpdateNeverWriteAPrivateRow() throws {
        let db = try makeDatabase()

        // Install: the only row an install writes is the `extension` row.
        db.saveExtension(extensionRecord(version: "1.0"))
        assertState(db, "ext-1", privateID, enabled: false, byProfile: false,
                    "a fresh install is off in Private")
        assertState(db, "ext-1", normalID, enabled: true, byProfile: true,
                    "a fresh install is on in a normal profile")

        // Update: the same row saved again at a new version.
        db.saveExtension(extensionRecord(version: "2.0"))
        assertState(db, "ext-1", privateID, enabled: false, byProfile: false,
                    "an update must not turn it on in Private")
        XCTAssertTrue(try rows(db, profileID: privateID).isEmpty,
                      "neither install nor update writes a per-profile row")
    }

    func testAnUpdateKeepsAPrivateAllow() throws {
        let db = try makeDatabase()
        db.saveExtension(extensionRecord(version: "1.0"))
        db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: privateID, enabled: true)

        db.saveExtension(extensionRecord(version: "2.0"))

        assertState(db, "ext-1", privateID, enabled: true, byProfile: true,
                    "an update must not revoke the user's Private allow")
    }

    func testGlobalDisableAndReEnableLeavePrivateUntouchedBothWays() throws {
        let db = try makeDatabase()
        db.saveExtension(extensionRecord(id: "never-allowed"))
        db.saveExtension(extensionRecord(id: "allowed"))
        db.setProfileExtensionEnabled(extensionID: "allowed", profileID: privateID, enabled: true)

        db.setEnabled(id: "never-allowed", enabled: false)
        db.setEnabled(id: "allowed", enabled: false)
        db.setEnabled(id: "never-allowed", enabled: true)
        db.setEnabled(id: "allowed", enabled: true)

        assertState(db, "never-allowed", privateID, enabled: false, byProfile: false,
                    "a global re-enable must not allow it in Private")
        assertState(db, "allowed", privateID, enabled: true, byProfile: true,
                    "a global re-enable restores the user's Private allow")
        assertState(db, "never-allowed", normalID, enabled: true, byProfile: true,
                    "a global re-enable restores a normal profile")
        XCTAssertEqual(try rows(db, profileID: privateID).map(\.extensionID), ["allowed"],
                       "the global toggle writes no per-profile rows")
    }

    // MARK: - Pinning

    func testPinningInPrivateDoesNotAllowTheExtension() throws {
        let db = try makeDatabase()
        db.saveExtension(extensionRecord())

        db.toggleExtensionPinned(extensionID: "ext-1", profileID: privateID)

        XCTAssertEqual(db.pinnedExtensionIDs(for: privateID), ["ext-1"], "the pin is recorded")
        assertState(db, "ext-1", privateID, enabled: false, byProfile: false,
                    "pinning must not enable it in Private")
    }

    func testPinningInANormalProfileKeepsItEnabled() throws {
        let db = try makeDatabase()
        db.saveExtension(extensionRecord())

        db.toggleExtensionPinned(extensionID: "ext-1", profileID: normalID)

        XCTAssertEqual(db.pinnedExtensionIDs(for: normalID), ["ext-1"])
        assertState(db, "ext-1", normalID, enabled: true, byProfile: true,
                    "pinning must not disable it in a normal profile")
    }

    func testPinningAnAllowedPrivateExtensionKeepsItAllowed() throws {
        let db = try makeDatabase()
        db.saveExtension(extensionRecord())
        db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: privateID, enabled: true)

        db.toggleExtensionPinned(extensionID: "ext-1", profileID: privateID)
        assertState(db, "ext-1", privateID, enabled: true, byProfile: true,
                    "pinning an allowed extension must not revoke the allow")

        db.toggleExtensionPinned(extensionID: "ext-1", profileID: privateID)
        XCTAssertTrue(db.pinnedExtensionIDs(for: privateID).isEmpty, "unpinned again")
        assertState(db, "ext-1", privateID, enabled: true, byProfile: true,
                    "unpinning must not revoke the allow either")
    }

    // MARK: - Live: the real Private profile

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []

    override func tearDown() async throws {
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

    /// The extension's per-profile rows and its own row. Nonisolated so the
    /// synchronous `dbQueue.write` is picked in the async tearDown.
    private nonisolated static func deleteRows(forExtension id: String) {
        try? AppDatabase.shared.dbQueue.write { db in
            _ = try ProfileExtensionRecord.filter(Column("extensionID") == id).deleteAll(db)
        }
        AppDatabase.shared.deleteExtension(id: id)
    }

    /// A globally enabled, installed extension registered with the shared manager.
    private func makeLiveExtension(named name: String) async throws -> WebExtension {
        let ext = try await makeOptionsPageTestExtension(idPrefix: "private-default-\(name)",
                                                         name: "Private Default \(name)")
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(ext.id)
        installTestExtension(ext, in: AppDatabase.shared,
                             manifestJSON: try testExtensionManifestData(ext))
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        return ext
    }

    /// The shared store's built-in Private profile, with its row saved so the
    /// `profileExtension` foreign key can be satisfied.
    private func privateProfile() -> Profile {
        let profile = TabStore.shared.ensureIncognitoProfile()
        AppDatabase.shared.saveProfile(profile.toRecord())
        _ = profile.extensionController
        return profile
    }

    private func isLoaded(_ ext: WebExtension, in profile: Profile) -> Bool {
        profile.extensionContexts[ext.id] != nil
    }

    func testLaunchLoadsNoContextIntoPrivateAndAllowLoadsItLive() async throws {
        let ext = try await makeLiveExtension(named: "live")
        let profile = privateProfile()
        XCTAssertEqual(profile.id, TabStore.incognitoProfileID, "precondition: the built-in Private profile")

        // Launch: the same path AppDelegate takes for every profile.
        ExtensionManager.shared.loadExtensionsIntoProfile(profile)
        XCTAssertFalse(isLoaded(ext, in: profile),
                       "a globally enabled extension must not load in Private by default")
        XCTAssertFalse(ExtensionManager.shared.isEnabled(extensionID: ext.id, inProfile: profile.id),
                       "the rule must agree with the loaded state")
        XCTAssertFalse(ExtensionManager.shared.enabledExtensions(for: profile.id).contains { $0.id == ext.id },
                       "the Private profile's extension list must not list it")

        // Allow in Private: loads the context without a relaunch.
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: true)
        XCTAssertTrue(isLoaded(ext, in: profile), "allowing it in Private loads the context live")
        XCTAssertTrue(ExtensionManager.shared.isEnabled(extensionID: ext.id, inProfile: profile.id))
        XCTAssertTrue(ExtensionManager.shared.enabledExtensions(for: profile.id).contains { $0.id == ext.id })
        // Private windows report `isPrivate`; without private-data access WebKit
        // hides them from the context and the allowed extension does nothing.
        XCTAssertEqual(profile.extensionContexts[ext.id]?.hasAccessToPrivateData, true,
                       "a context allowed in Private must be given access to private data")
        // Negative control: a normal profile's context never gets it.
        let normal = TabStore.shared.profiles.first { !$0.isIncognito }
        if let normalContext = normal?.extensionContexts[ext.id] {
            XCTAssertFalse(normalContext.hasAccessToPrivateData,
                           "private-data access is for the Private profile's contexts only")
        }

        // And back off: unloads it.
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: false)
        XCTAssertFalse(isLoaded(ext, in: profile), "disallowing it unloads the context")
        XCTAssertFalse(ExtensionManager.shared.isEnabled(extensionID: ext.id, inProfile: profile.id))
    }

    /// The negative control for the global toggle: a Private allow survives a
    /// global disable → enable, and an extension never allowed stays unloaded
    /// through the same cycle.
    func testGlobalToggleDoesNotChangeWhatIsLoadedInPrivate() async throws {
        let allowed = try await makeLiveExtension(named: "global-allowed")
        let refused = try await makeLiveExtension(named: "global-refused")
        let profile = privateProfile()

        ExtensionManager.shared.setEnabled(id: allowed.id, profileID: profile.id, enabled: true)
        XCTAssertTrue(isLoaded(allowed, in: profile), "precondition: allowed in Private")
        XCTAssertFalse(isLoaded(refused, in: profile), "precondition: never allowed in Private")

        ExtensionManager.shared.setEnabled(id: allowed.id, enabled: false)
        ExtensionManager.shared.setEnabled(id: refused.id, enabled: false)
        XCTAssertFalse(isLoaded(allowed, in: profile), "a global disable unloads it in Private too")

        ExtensionManager.shared.setEnabled(id: allowed.id, enabled: true)
        ExtensionManager.shared.setEnabled(id: refused.id, enabled: true)
        XCTAssertTrue(isLoaded(allowed, in: profile),
                      "a global re-enable restores the Private allow")
        XCTAssertFalse(isLoaded(refused, in: profile),
                       "a global re-enable must not load one that was never allowed in Private")
    }
}
