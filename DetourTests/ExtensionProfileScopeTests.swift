import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-312: an extension is on only in the profiles a `profileExtension` row
/// turns it on in. A missing row is off in every profile
/// (`AppDatabase.extensionEnabledByDefault`), migration v24 wrote the old
/// implicit ON down for the profiles that existed, an install turns the
/// extension on in exactly the profile it was installed from
/// (`ExtensionInstallTarget`), a reinstall or update keeps every row, and
/// Settings' Turn On in All Profiles covers the normal profiles, never Private.
///
/// The default itself, Private's rows and the new-profile load are also covered
/// by `ExtensionPrivateDefaultTests`, `ExtensionEnabledStateTests` and
/// `NewProfileExtensionLoadTests`.
nonisolated final class ExtensionProfileScopeTests: XCTestCase {

    private let privateID = TabStore.incognitoProfileID.uuidString

    // MARK: - Migration v24

    @MainActor private func insertProfile(_ db: GRDB.Database, id: String, name: String) throws {
        try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, ?)", arguments: [id, name])
    }

    @MainActor private func insertExtension(_ db: GRDB.Database, id: String, isEnabled: Bool = true) throws {
        try db.execute(sql: """
            INSERT INTO "extension" (id, name, version, manifestJSON, basePath, isEnabled, installedAt)
            VALUES (?, 'Ext', '1.0', x'7b7d', '/tmp/none', ?, 0)
            """, arguments: [id, isEnabled])
    }

    @MainActor private func insertRow(_ db: GRDB.Database, profile: String, ext: String,
                                      enabled: Bool, pinned: Bool = false) throws {
        try db.execute(sql: """
            INSERT INTO profileExtension (profileID, extensionID, isEnabled, isPinned) VALUES (?, ?, ?, ?)
            """, arguments: [profile, ext, enabled, pinned])
    }

    /// Every row, keyed "profile|extension" → (isEnabled, isPinned).
    @MainActor private func allRows(_ queue: DatabaseQueue) throws -> [String: [Bool]] {
        try queue.read { db in
            var rows: [String: [Bool]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM profileExtension") {
                let key = "\(row["profileID"] as String)|\(row["extensionID"] as String)"
                rows[key] = [row["isEnabled"] as Bool, row["isPinned"] as Bool]
            }
            return rows
        }
    }

    /// A v23 database with two normal profiles, the Private profile and three
    /// installed extensions (one globally off), and the rows a user could have
    /// left: an explicit OFF, a pin, a Private allow and a Private refusal.
    /// After v24 every normal profile × extension without a row has an ON row;
    /// every existing row is unchanged; Private gets nothing.
    @MainActor func testMigrationV24WritesTheOldImplicitOnForNormalProfilesOnly() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v23")
        let work = "AAAAAAAA-0000-0000-0000-000000000002"
        let home = "BBBBBBBB-0000-0000-0000-000000000003"
        try queue.write { db in
            try insertProfile(db, id: work, name: "Work")
            try insertProfile(db, id: home, name: "Home")
            try insertProfile(db, id: privateID, name: "Private")
            try insertExtension(db, id: "password-manager")
            try insertExtension(db, id: "ad-helper")
            try insertExtension(db, id: "globally-off", isEnabled: false)
            try insertRow(db, profile: work, ext: "ad-helper", enabled: false)               // explicit off
            try insertRow(db, profile: home, ext: "password-manager", enabled: true, pinned: true) // a pin
            try insertRow(db, profile: privateID, ext: "password-manager", enabled: true)    // Allow in Private
            try insertRow(db, profile: privateID, ext: "ad-helper", enabled: false)          // refused there
        }
        let before = try allRows(queue)

        let db = try AppDatabase(dbQueue: queue)

        let after = try allRows(queue)
        for (key, value) in before {
            XCTAssertEqual(after[key], value, "an existing row is untouched: \(key)")
        }
        XCTAssertEqual(after["\(work)|password-manager"], [true, false], "the implicit ON is written down")
        XCTAssertEqual(after["\(work)|globally-off"], [true, false],
                       "a globally disabled extension gets its per-profile ON too: re-enabling it restores it there")
        XCTAssertEqual(after["\(home)|ad-helper"], [true, false])
        XCTAssertEqual(after["\(home)|globally-off"], [true, false])
        XCTAssertNil(after["\(privateID)|globally-off"], "the Private profile gets no row")
        XCTAssertEqual(after.keys.filter { $0.hasPrefix(privateID) }.count, 2, "only its own two rows")
        XCTAssertEqual(after.count, before.count + 4, "exactly the four missing normal rows")

        // What the readers answer is what a v23 database meant.
        XCTAssertEqual(db.enabledExtensionIDs(for: work), ["password-manager"])
        XCTAssertEqual(db.enabledExtensionIDs(for: home), ["password-manager", "ad-helper"])
        XCTAssertEqual(db.enabledExtensionIDs(for: privateID), ["password-manager"])
        XCTAssertEqual(db.pinnedExtensionIDs(for: home), ["password-manager"], "the pin survives")
    }

    /// The Private id is matched case-insensitively, as the old default matched
    /// it as a UUID: a lowercased copy of it is not taken for a normal profile.
    @MainActor func testMigrationV24SkipsALowercasedPrivateID() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v23")
        let lowerPrivate = privateID.lowercased()
        let normal = "AAAAAAAA-0000-0000-0000-000000000002"
        try queue.write { db in
            try insertProfile(db, id: lowerPrivate, name: "Private")
            try insertProfile(db, id: normal, name: "Default")
            try insertExtension(db, id: "ext")
        }

        _ = try AppDatabase(dbQueue: queue)

        XCTAssertEqual(try allRows(queue), ["\(normal)|ext": [true, false]])
    }

    @MainActor func testMigrationV24OnADatabaseWithNothingInstalledWritesNoRows() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v23")
        try queue.write { try insertProfile($0, id: "AAAAAAAA-0000-0000-0000-000000000002", name: "Default") }

        _ = try AppDatabase(dbQueue: queue)

        XCTAssertTrue(try allRows(queue).isEmpty)
    }

    /// v24 runs once: a profile or extension added afterwards gets no row from
    /// it, so a new profile starts with no extensions.
    @MainActor func testAProfileAddedAfterTheMigrationStartsWithNoRows() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v23")
        let old = "AAAAAAAA-0000-0000-0000-000000000002"
        try queue.write { db in
            try insertProfile(db, id: old, name: "Default")
            try insertExtension(db, id: "ext")
        }
        let db = try AppDatabase(dbQueue: queue)
        let new = "CCCCCCCC-0000-0000-0000-000000000004"
        try queue.write { try insertProfile($0, id: new, name: "Banking") }
        _ = try AppDatabase(dbQueue: queue)  // a relaunch: migrations already applied

        XCTAssertEqual(db.enabledExtensionIDs(for: old), ["ext"])
        XCTAssertEqual(db.enabledExtensionIDs(for: new), [], "the new profile starts with no extensions")
        XCTAssertNil(try allRows(queue)["\(new)|ext"])
    }

    // MARK: - The target profile (pure)

    private let work = UUID()
    private let home = UUID()
    private let banking = UUID()

    @MainActor func testTheFirstNormalCandidateIsTheTarget() {
        XCTAssertEqual(ExtensionInstallTarget.resolveProfile(candidates: [home, work],
                                                             normalProfiles: [work, home, banking]), home,
                       "the source tab's (or frontmost window's) profile, not the first one")
    }

    @MainActor func testPrivateIsNeverTheTarget() {
        let priv = TabStore.incognitoProfileID
        XCTAssertEqual(ExtensionInstallTarget.resolveProfile(candidates: [priv, banking],
                                                             normalProfiles: [work, home, banking]), banking,
                       "a Private window in front is skipped: the next normal window's profile")
        XCTAssertEqual(ExtensionInstallTarget.resolveProfile(candidates: [priv],
                                                             normalProfiles: [work, home]), work,
                       "a package from a Private tab or Private Quick Detour goes to the first normal profile")
    }

    @MainActor func testNoUsableCandidateFallsBackToTheFirstNormalProfile() {
        XCTAssertEqual(ExtensionInstallTarget.resolveProfile(candidates: [], normalProfiles: [home, work]), home,
                       "no browser window: the first normal profile in TabStore order")
        XCTAssertEqual(ExtensionInstallTarget.resolveProfile(candidates: [nil, nil], normalProfiles: [home]), home,
                       "windows without an active space")
        XCTAssertEqual(ExtensionInstallTarget.resolveProfile(candidates: [UUID()], normalProfiles: [work]), work,
                       "a profile deleted since the download started is no target")
        XCTAssertNil(ExtensionInstallTarget.resolveProfile(candidates: [TabStore.incognitoProfileID],
                                                           normalProfiles: []))
    }

    @MainActor func testTheSharedStoresNormalProfilesExcludePrivate() {
        _ = TabStore.shared.ensureIncognitoProfile()
        let normal = ExtensionInstallTarget.normalProfileIDs()
        XCTAssertFalse(normal.contains(TabStore.incognitoProfileID))
        XCTAssertEqual(normal, TabStore.shared.profiles.filter { !$0.isIncognito }.map(\.id), "in TabStore order")
        XCTAssertEqual(ExtensionInstallTarget.profileForSource(TabStore.incognitoProfileID), normal.first)
    }

    @MainActor func testTheInstalledMessageNamesTheProfile() {
        let text = ExtensionInstallTarget.installedMessage(displayName: "Hello", profileName: "Work")
        XCTAssertTrue(text.contains("\"Hello\""), text)
        XCTAssertTrue(text.contains("turned on in the \"Work\" profile"), text)
        XCTAssertTrue(text.contains("Turn On in All Profiles"), text)
        XCTAssertEqual(ExtensionInstallTarget.installedMessage(displayName: "Hello", profileName: nil),
                       "\"Hello\" has been installed.")
    }

    @MainActor func testTheSettingsProfilesSummary() {
        XCTAssertTrue(ExtensionsSettingsViewController.profilesSummary(onIn: [], normalProfileCount: 3)
            .hasPrefix("Off in every profile."))
        XCTAssertTrue(ExtensionsSettingsViewController.profilesSummary(onIn: ["Work"], normalProfileCount: 3)
            .hasPrefix("On in \u{201C}Work\u{201D}."))
        XCTAssertTrue(ExtensionsSettingsViewController.profilesSummary(onIn: ["Work"], normalProfileCount: 1)
            .hasPrefix("On in \u{201C}Work\u{201D}."), "one profile is named, not 'all'")
        XCTAssertTrue(ExtensionsSettingsViewController.profilesSummary(onIn: ["A", "B"], normalProfileCount: 2)
            .hasPrefix("On in all profiles."))
    }

    // MARK: - Live: install, reinstall, reload, Turn On in All Profiles

    private var tempDirs: [URL] = []
    private var installedIDs: [String] = []
    private var createdProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        try await waitUntil("the host app's installed extensions to load") {
            ExtensionManager.shared.hasLoadedInstalledExtensions
        }
    }

    @MainActor override func tearDown() async throws {
        for id in installedIDs {
            ExtensionManager.shared.uninstall(id: id)
        }
        installedIDs.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        }
        createdProfiles.removeAll()
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    @MainActor private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        _ = profile.extensionController
        return profile
    }

    /// An unpacked extension folder whose manifest key pins the id, so a second
    /// install of it is a reinstall.
    @MainActor private func makeSource() throws -> (url: URL, options: ExtensionInstaller.Options) {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-profile-scope-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        tempDirs.append(source)
        let key = Data("detour-task312-\(UUID().uuidString)".utf8).base64EncodedString()
        try """
        { "manifest_version": 3, "name": "Profile Scope Test", "version": "1.0", "key": "\(key)",
          "options_page": "options.html" }
        """.write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html></html>".write(to: source.appendingPathComponent("options.html"), atomically: true, encoding: .utf8)
        var options = ExtensionInstaller.Options()
        options.source = .unpacked
        options.sourcePath = source
        return (source, options)
    }

    @MainActor private func rows(_ extensionID: String) throws -> [String: Bool] {
        try AppDatabase.shared.dbQueue.read { db in
            Dictionary(uniqueKeysWithValues: try ProfileExtensionRecord
                .filter(Column("extensionID") == extensionID).fetchAll(db).map { ($0.profileID, $0.isEnabled) })
        }
    }

    @MainActor private func loadedProfiles(_ extensionID: String) -> Set<UUID> {
        Set(TabStore.shared.profiles.filter { $0.extensionContext(for: extensionID) != nil }.map(\.id))
    }

    @MainActor func testAnInstallIsOnAndLoadedInItsTargetProfileOnly() async throws {
        let work = makeProfile("Scope Work")
        let home = makeProfile("Scope Home")
        let priv = TabStore.shared.ensureIncognitoProfile()
        AppDatabase.shared.saveProfile(priv.toRecord())
        let (source, options) = try makeSource()

        let ext = try ExtensionManager.shared.install(from: source, options: options, turningOnIn: work.id)
        installedIDs.append(ext.id)

        XCTAssertEqual(try rows(ext.id), [work.id.uuidString: true],
                       "the one row an install writes is its target's, before anything loads")
        try await waitUntil("the install to load in its target profile") {
            work.extensionContext(for: ext.id) != nil
        }
        XCTAssertEqual(loadedProfiles(ext.id), [work.id],
                       "loaded in the target only: not \(home.name), not the host's profiles, not Private")
        XCTAssertTrue(ExtensionManager.shared.isEnabled(extensionID: ext.id, inProfile: work.id))
        XCTAssertFalse(ExtensionManager.shared.isEnabled(extensionID: ext.id, inProfile: home.id))
        XCTAssertFalse(ExtensionManager.shared.isEnabled(extensionID: ext.id, inProfile: priv.id))
        XCTAssertEqual(ExtensionManager.shared.normalProfilesTurnedOn(extensionID: ext.id).map(\.id), [work.id])
    }

    @MainActor func testAPrivateTargetWritesNoRowAndLoadsNowhere() async throws {
        let priv = TabStore.shared.ensureIncognitoProfile()
        AppDatabase.shared.saveProfile(priv.toRecord())
        let (source, options) = try makeSource()

        let ext = try ExtensionManager.shared.install(from: source, options: options,
                                                      turningOnIn: TabStore.incognitoProfileID)
        installedIDs.append(ext.id)
        try await waitUntil("the install to finish loading") { ext.wkExtension != nil }

        XCTAssertTrue(try rows(ext.id).isEmpty, "Private stays off until the user allows it there")
        XCTAssertTrue(loadedProfiles(ext.id).isEmpty)
    }

    /// A reinstall from another profile turns it on there too and leaves every
    /// other choice — an explicit off, a profile turned on by hand — alone; a
    /// reload (the update path) writes nothing at all.
    @MainActor func testReinstallAndReloadKeepEveryProfilesChoice() async throws {
        let work = makeProfile("Scope Reinstall Work")
        let home = makeProfile("Scope Reinstall Home")
        let banking = makeProfile("Scope Reinstall Banking")
        let (source, options) = try makeSource()
        let first = try ExtensionManager.shared.install(from: source, options: options, turningOnIn: work.id)
        installedIDs.append(first.id)
        try await waitUntil("the first install to load") { work.extensionContext(for: first.id) != nil }
        ExtensionManager.shared.setEnabled(id: first.id, profileID: home.id, enabled: true)
        ExtensionManager.shared.setEnabled(id: first.id, profileID: work.id, enabled: false)

        let second = try ExtensionManager.shared.install(from: source, options: options, turningOnIn: banking.id)
        XCTAssertEqual(second.id, first.id, "precondition: the manifest key keeps the id")
        XCTAssertEqual(try rows(first.id), [work.id.uuidString: false, home.id.uuidString: true,
                                            banking.id.uuidString: true],
                       "the reinstall turns it on where it came from and keeps the others")
        try await waitUntil("the reinstall to load") {
            home.extensionContext(for: first.id) != nil && banking.extensionContext(for: first.id) != nil
        }
        XCTAssertNil(work.extensionContext(for: first.id), "the explicit off is honoured by the reload")

        let rowsBefore = try rows(first.id)
        XCTAssertEqual(try ExtensionManager.shared.reloadUnpacked(id: first.id), .installed(version: "1.0"))
        let reloaded = try XCTUnwrap(ExtensionManager.shared.extension(withID: first.id))
        try await waitUntil("the reload to load") {
            reloaded.wkExtension != nil && home.extensionContext(for: first.id) != nil
                && banking.extensionContext(for: first.id) != nil
        }
        XCTAssertEqual(try rows(first.id), rowsBefore, "a reload or update never changes where it is on")
        XCTAssertEqual(loadedProfiles(first.id), [home.id, banking.id])
    }

    @MainActor func testTurnOnInAllProfilesCoversEveryNormalProfileAndNotPrivate() async throws {
        let work = makeProfile("Scope All Work")
        let home = makeProfile("Scope All Home")
        let priv = TabStore.shared.ensureIncognitoProfile()
        AppDatabase.shared.saveProfile(priv.toRecord())
        _ = priv.extensionController
        let (source, options) = try makeSource()
        let ext = try ExtensionManager.shared.install(from: source, options: options, turningOnIn: work.id)
        installedIDs.append(ext.id)
        try await waitUntil("the install to load") { work.extensionContext(for: ext.id) != nil }
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: home.id, enabled: false)

        ExtensionManager.shared.turnOnInAllProfiles(id: ext.id)

        let normal = Set(ExtensionInstallTarget.normalProfileIDs())
        XCTAssertTrue(normal.isSuperset(of: [work.id, home.id]))
        XCTAssertEqual(Set(try rows(ext.id).filter(\.value).keys), Set(normal.map(\.uuidString)),
                       "an ON row in every normal profile, the explicitly-off one included")
        XCTAssertNil(try rows(ext.id)[privateID], "Private stays its own switch")
        XCTAssertEqual(loadedProfiles(ext.id), normal, "loaded live in every normal profile, not in Private")
        XCTAssertEqual(Set(ExtensionManager.shared.normalProfilesTurnedOn(extensionID: ext.id).map(\.id)), normal)
    }
}
