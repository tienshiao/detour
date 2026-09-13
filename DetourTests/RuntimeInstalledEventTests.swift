import XCTest
import GRDB
@testable import Detour

/// The `runtime.onInstalled` emission rules (TASK-22, TASK-29): the pure decision,
/// the per-profile ledger that makes delivery exactly-once, the reinstall mark, the
/// Private profile's exclusion, and the migrations that keep an app upgrade from
/// replaying `install` to every installed extension. The worker and page side
/// (suppressing WebKit's event, claiming, dispatching) is covered in
/// `ExtensionPolyfillTests` and `ExtensionPolyfillProfileWiringTests`.
final class RuntimeInstalledEventTests: XCTestCase {

    private static let privateProfileID = TabStore.incognitoProfileID.uuidString

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(dbQueue: try DatabaseQueue(configuration: Configuration()))
    }

    private func pending(_ deliveredVersion: String?, reinstalled: Bool = false, current: String,
                         isPrivate: Bool = false) -> RuntimeInstalledEvent.Details? {
        RuntimeInstalledEvent.pending(
            ledger: deliveredVersion.map { .init(deliveredVersion: $0, reinstallPending: reinstalled) },
            currentVersion: current, isPrivateProfile: isPrivate)
    }

    // MARK: - Decision

    func testNeverDeliveredIsAnInstallWithoutPreviousVersion() {
        let details = pending(nil, current: "1.0")
        XCTAssertEqual(details, .init(reason: .install, previousVersion: nil))
        XCTAssertEqual(details?.dictionary as? [String: String], ["reason": "install"],
                       "previousVersion must be absent, not null, for an install")
    }

    func testVersionChangeIsAnUpdateCarryingTheDeliveredVersion() {
        let details = pending("1.0", current: "1.1")
        XCTAssertEqual(details, .init(reason: .update, previousVersion: "1.0"))
        XCTAssertEqual(details?.dictionary as? [String: String], ["reason": "update", "previousVersion": "1.0"])
    }

    /// A downgrade is a version change too; Chrome reports it as an update.
    func testDowngradeIsAnUpdate() {
        XCTAssertEqual(pending("2.0", current: "1.9"), .init(reason: .update, previousVersion: "2.0"))
    }

    /// A reload (background-load recovery), a relaunch and a disable → enable all
    /// load the version the event was already delivered for: nothing.
    func testSameVersionOwesNothing() {
        XCTAssertNil(pending("1.0", current: "1.0"))
    }

    /// A same-version reinstall is an update from the installed version (TASK-29).
    func testSameVersionReinstallIsAnUpdateFromTheCurrentVersion() {
        let details = pending("1.0", reinstalled: true, current: "1.0")
        XCTAssertEqual(details, .init(reason: .update, previousVersion: "1.0"))
        XCTAssertEqual(details?.dictionary as? [String: String], ["reason": "update", "previousVersion": "1.0"])
    }

    /// A reinstall that also changed the version reports the delivered version,
    /// exactly as a plain update would.
    func testReinstallWithANewVersionIsTheUsualUpdate() {
        XCTAssertEqual(pending("1.0", reinstalled: true, current: "1.1"),
                       .init(reason: .update, previousVersion: "1.0"))
    }

    /// The Private profile is never owed the event — not a first install, not an
    /// update, not a reinstall (TASK-29).
    func testPrivateProfileIsNeverOwedTheEvent() {
        XCTAssertNil(pending(nil, current: "1.0", isPrivate: true))
        XCTAssertNil(pending("1.0", current: "1.1", isPrivate: true))
        XCTAssertNil(pending("1.0", reinstalled: true, current: "1.0", isPrivate: true))
    }

    /// Detour has no browser update to report.
    func testReasonsAreOnlyInstallAndUpdate() {
        XCTAssertNil(RuntimeInstalledEvent.Reason(rawValue: "chrome_update"))
        XCTAssertNil(RuntimeInstalledEvent.Reason(rawValue: "shared_module_update"))
    }

    // MARK: - Ledger

    func testClaimDeliversInstallOnceThenNothing() throws {
        let db = try makeDatabase()
        XCTAssertEqual(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertEqual(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil), "reading what is pending must not consume it")

        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"),
                     "a second worker start (or a reload) for the same version must get nothing")
        XCTAssertNil(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"))
    }

    func testUpdateIsDeliveredOncePerVersionChange() throws {
        let db = try makeDatabase()
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0")

        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.1"),
                       .init(reason: .update, previousVersion: "1.0"))
        XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.1"))
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.2"),
                       .init(reason: .update, previousVersion: "1.1"))
    }

    /// A profile where the extension did not run during an update (disabled there)
    /// gets one update when it next runs, from the version it last saw.
    func testUpdateSkippedInAProfileIsDeliveredFromTheLastDeliveredVersion() throws {
        let db = try makeDatabase()
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0")
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p2", isPrivateProfile: false, currentVersion: "1.0")
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.1")
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.2")

        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p2", isPrivateProfile: false, currentVersion: "1.2"),
                       .init(reason: .update, previousVersion: "1.0"))
    }

    /// Each profile runs its own worker with its own storage: each gets the event.
    func testLedgerIsPerProfileAndPerExtension() throws {
        let db = try makeDatabase()
        XCTAssertNotNil(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"))
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p2", isPrivateProfile: false, currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "other", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
    }

    /// Uninstalling forgets the ledger, so reinstalling under the same id (a
    /// manifest key) is an install again.
    func testDeleteExtensionForgetsTheLedger() throws {
        let db = try makeDatabase()
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0")
        _ = db.claimRuntimeInstalledEvent(extensionID: "keep", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0")
        db.deleteExtension(id: "ext")

        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "keep", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"),
                     "other extensions' rows must survive")
    }

    // MARK: - Reinstall (TASK-29)

    /// A same-version reinstall owes each profile that had the event exactly one
    /// `update` from the installed version; a profile that never had it still gets
    /// `install`; other extensions are untouched.
    func testReinstallDeliversOneUpdatePerProfileFromTheInstalledVersion() throws {
        let db = try makeDatabase()
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0")
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p2", isPrivateProfile: false, currentVersion: "1.0")
        _ = db.claimRuntimeInstalledEvent(extensionID: "other", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0")

        db.markRuntimeInstalledEventReinstalled(extensionID: "ext")

        for profileID in ["p1", "p2"] {
            XCTAssertEqual(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: profileID, isPrivateProfile: false, currentVersion: "1.0"),
                           .init(reason: .update, previousVersion: "1.0"))
            XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: profileID, isPrivateProfile: false, currentVersion: "1.0"),
                           .init(reason: .update, previousVersion: "1.0"), "in \(profileID)")
            XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: profileID, isPrivateProfile: false, currentVersion: "1.0"),
                         "a reinstall is delivered once, in \(profileID)")
        }
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p3", isPrivateProfile: false, currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "other", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"))
    }

    /// After the reinstall is delivered, a reload, relaunch or re-enable (the same
    /// version loaded again, with no new mark) is nothing again.
    func testReloadAfterADeliveredReinstallStillOwesNothing() throws {
        let dbQueue = try DatabaseQueue(configuration: Configuration())
        let db = try AppDatabase(dbQueue: dbQueue)
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0")
        XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"),
                     "a reload before any reinstall owes nothing")

        db.markRuntimeInstalledEventReinstalled(extensionID: "ext")
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0")

        let relaunched = try AppDatabase(dbQueue: dbQueue)
        XCTAssertNil(relaunched.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"))
        XCTAssertNil(relaunched.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"))
    }

    /// The whole path through `ExtensionManager.install`: a first install marks
    /// nothing (nothing to reinstall over), installing the same id and version
    /// again owes one `update` from that version. The extension has no background
    /// content, so nothing claims behind the test's back; the profile id is one no
    /// real profile has.
    @MainActor
    func testSameVersionReinstallThroughExtensionManagerOwesOneUpdate() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-reinstall-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        // A manifest key pins the id, so both installs are the same extension.
        let key = Data("detour-task29-\(UUID().uuidString)".utf8).base64EncodedString()
        try """
        { "manifest_version": 3, "name": "Reinstall Test", "version": "4.2.0", "key": "\(key)" }
        """.write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let db = AppDatabase.shared
        let profileID = "task29-reinstall-\(UUID().uuidString)"
        let first = try ExtensionManager.shared.install(from: source)
        defer { ExtensionManager.shared.uninstall(id: first.id) }
        // install finishes loading on a later main-actor turn; let it, so the two
        // installs' loads never interleave with each other or with the uninstall.
        try await waitUntil("the first install to load") { first.wkExtension != nil }
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: first.id, profileID: profileID, isPrivateProfile: false, currentVersion: "4.2.0"),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertNil(db.pendingRuntimeInstalledEvent(extensionID: first.id, profileID: profileID, isPrivateProfile: false, currentVersion: "4.2.0"),
                     "a reload after the install owes nothing")

        let second = try ExtensionManager.shared.install(from: source)
        XCTAssertEqual(second.id, first.id)
        try await waitUntil("the reinstall to load") { second.wkExtension != nil }
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: first.id, profileID: profileID, isPrivateProfile: false, currentVersion: "4.2.0"),
                       .init(reason: .update, previousVersion: "4.2.0"))
        XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: first.id, profileID: profileID, isPrivateProfile: false, currentVersion: "4.2.0"),
                     "exactly once")
        XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: first.id, profileID: Self.privateProfileID, isPrivateProfile: true, currentVersion: "4.2.0"),
                     "never in the Private profile")
    }

    // MARK: - Private profile (TASK-29)

    /// The Private profile gets nothing on its first run, and nothing after any
    /// number of relaunches (each a fresh, empty Private storage) — and no ledger row
    /// is written for it, so nothing could replay later either. A regular profile
    /// on the same database still gets its install.
    func testPrivateProfileGetsNothingAcrossRelaunches() throws {
        let dbQueue = try DatabaseQueue(configuration: Configuration())
        for launch in 1...3 {
            let db = try AppDatabase(dbQueue: dbQueue)
            XCTAssertNil(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: Self.privateProfileID, isPrivateProfile: true, currentVersion: "1.0"),
                         "launch \(launch)")
            XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: Self.privateProfileID, isPrivateProfile: true, currentVersion: "1.0"),
                         "launch \(launch)")
            db.markRuntimeInstalledEventReinstalled(extensionID: "ext")
            XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: Self.privateProfileID, isPrivateProfile: true, currentVersion: "1.1"),
                         "launch \(launch), after a reinstall and an update")
        }
        let privateRows = try dbQueue.read { db in
            try ExtensionInstalledEventRecord.filter(Column("profileID") == Self.privateProfileID).fetchCount(db)
        }
        XCTAssertEqual(privateRows, 0)

        let db = try AppDatabase(dbQueue: dbQueue)
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", isPrivateProfile: false, currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
    }

    // MARK: - Migration

    /// Extensions installed before the ledger existed must not get `install` when
    /// Detour is upgraded: v9 records them as delivered, at the installed version,
    /// in every saved profile. A profile created afterwards still gets `install`.
    func testMigrationSeedsExistingInstallsAsDelivered() throws {
        let dbQueue = try DatabaseQueue(configuration: Configuration())
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v8")
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES ('profile-a', 'Default')")
            try db.execute(sql: """
                INSERT INTO "extension" (id, name, version, manifestJSON, basePath, isEnabled, installedAt)
                VALUES ('ext', 'Ext', '2.3', x'7b7d', '/tmp/ext', 1, 0)
                """)
        }

        let db = try AppDatabase(dbQueue: dbQueue)

        XCTAssertNil(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "profile-a", isPrivateProfile: false, currentVersion: "2.3"),
                     "an existing install must not be replayed")
        XCTAssertEqual(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "profile-a", isPrivateProfile: false, currentVersion: "2.4"),
                       .init(reason: .update, previousVersion: "2.3"))
        XCTAssertEqual(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "profile-new", isPrivateProfile: false, currentVersion: "2.3"),
                       .init(reason: .install, previousVersion: nil))
    }

    /// v10 adds the reinstall flag, cleared on existing rows, and drops the rows
    /// v9 seeded for the Private profile; other profiles' rows are kept as they
    /// were.
    func testMigrationV10AddsTheReinstallFlagAndDropsPrivateRows() throws {
        let dbQueue = try DatabaseQueue(configuration: Configuration())
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v8")
        try dbQueue.write { db in
            for (id, name) in [("profile-a", "Default"), (Self.privateProfileID, "Private")] {
                try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, ?)", arguments: [id, name])
            }
            try db.execute(sql: """
                INSERT INTO "extension" (id, name, version, manifestJSON, basePath, isEnabled, installedAt)
                VALUES ('ext', 'Ext', '2.3', x'7b7d', '/tmp/ext', 1, 0)
                """)
        }
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v9")
        let seededPrivate = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM extensionInstalledEvent WHERE profileID = ?",
                             arguments: [Self.privateProfileID])
        }
        XCTAssertEqual(seededPrivate, 1, "precondition: v9 seeds the Private profile")

        let db = try AppDatabase(dbQueue: dbQueue)

        let rows = try dbQueue.read { db in try ExtensionInstalledEventRecord.fetchAll(db) }
        XCTAssertEqual(rows.map(\.profileID), ["profile-a"])
        XCTAssertEqual(rows.first?.deliveredVersion, "2.3")
        XCTAssertEqual(rows.first?.reinstallPending, false)
        XCTAssertNil(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "profile-a", isPrivateProfile: false, currentVersion: "2.3"))
    }
}
