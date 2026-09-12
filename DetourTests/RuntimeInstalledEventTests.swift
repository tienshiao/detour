import XCTest
import GRDB
@testable import Detour

/// The `runtime.onInstalled` emission rules (TASK-22): the pure decision, the
/// per-profile ledger that makes delivery exactly-once, and the migration that
/// keeps an app upgrade from replaying `install` to every installed extension.
/// The worker side (suppressing WebKit's event, claiming, dispatching) is covered
/// in `ExtensionPolyfillTests`.
final class RuntimeInstalledEventTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(dbQueue: try DatabaseQueue(configuration: Configuration()))
    }

    // MARK: - Decision

    func testNeverDeliveredIsAnInstallWithoutPreviousVersion() {
        let details = RuntimeInstalledEvent.pending(deliveredVersion: nil, currentVersion: "1.0")
        XCTAssertEqual(details, .init(reason: .install, previousVersion: nil))
        XCTAssertEqual(details?.dictionary as? [String: String], ["reason": "install"],
                       "previousVersion must be absent, not null, for an install")
    }

    func testVersionChangeIsAnUpdateCarryingTheDeliveredVersion() {
        let details = RuntimeInstalledEvent.pending(deliveredVersion: "1.0", currentVersion: "1.1")
        XCTAssertEqual(details, .init(reason: .update, previousVersion: "1.0"))
        XCTAssertEqual(details?.dictionary as? [String: String], ["reason": "update", "previousVersion": "1.0"])
    }

    /// A downgrade is a version change too; Chrome reports it as an update.
    func testDowngradeIsAnUpdate() {
        XCTAssertEqual(RuntimeInstalledEvent.pending(deliveredVersion: "2.0", currentVersion: "1.9"),
                       .init(reason: .update, previousVersion: "2.0"))
    }

    /// A reload (background-load recovery), a relaunch and a disable → enable all
    /// load the version the event was already delivered for: nothing.
    func testSameVersionOwesNothing() {
        XCTAssertNil(RuntimeInstalledEvent.pending(deliveredVersion: "1.0", currentVersion: "1.0"))
    }

    /// Detour has no browser update to report.
    func testReasonsAreOnlyInstallAndUpdate() {
        XCTAssertNil(RuntimeInstalledEvent.Reason(rawValue: "chrome_update"))
        XCTAssertNil(RuntimeInstalledEvent.Reason(rawValue: "shared_module_update"))
    }

    // MARK: - Ledger

    func testClaimDeliversInstallOnceThenNothing() throws {
        let db = try makeDatabase()
        XCTAssertEqual(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertEqual(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil), "reading what is pending must not consume it")

        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.0"),
                     "a second worker start (or a reload) for the same version must get nothing")
        XCTAssertNil(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.0"))
    }

    func testUpdateIsDeliveredOncePerVersionChange() throws {
        let db = try makeDatabase()
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.0")

        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.1"),
                       .init(reason: .update, previousVersion: "1.0"))
        XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.1"))
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.2"),
                       .init(reason: .update, previousVersion: "1.1"))
    }

    /// A profile where the extension did not run during an update (disabled there)
    /// gets one update when it next runs, from the version it last saw.
    func testUpdateSkippedInAProfileIsDeliveredFromTheLastDeliveredVersion() throws {
        let db = try makeDatabase()
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.0")
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p2", currentVersion: "1.0")
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.1")
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.2")

        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p2", currentVersion: "1.2"),
                       .init(reason: .update, previousVersion: "1.0"))
    }

    /// Each profile runs its own worker with its own storage: each gets the event.
    func testLedgerIsPerProfileAndPerExtension() throws {
        let db = try makeDatabase()
        XCTAssertNotNil(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.0"))
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p2", currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "other", profileID: "p1", currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
    }

    /// Uninstalling forgets the ledger, so reinstalling under the same id (a
    /// manifest key) is an install again.
    func testDeleteExtensionForgetsTheLedger() throws {
        let db = try makeDatabase()
        _ = db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.0")
        _ = db.claimRuntimeInstalledEvent(extensionID: "keep", profileID: "p1", currentVersion: "1.0")
        db.deleteExtension(id: "ext")

        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: "ext", profileID: "p1", currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertNil(db.claimRuntimeInstalledEvent(extensionID: "keep", profileID: "p1", currentVersion: "1.0"),
                     "other extensions' rows must survive")
    }

    // MARK: - Migration

    /// Extensions installed before the ledger existed must not get `install` when
    /// Detour is upgraded: v9 records them as delivered, at the installed version,
    /// in every saved profile. A profile created afterwards still gets `install`.
    func testMigrationSeedsExistingInstallsAsDelivered() throws {
        let dbQueue = try DatabaseQueue(configuration: Configuration())
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v8")
        try dbQueue.write { db in
            for (id, name) in [("profile-a", "Default"), ("00000000-0000-0000-0000-000000000001", "Private")] {
                try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, ?)", arguments: [id, name])
            }
            try db.execute(sql: """
                INSERT INTO "extension" (id, name, version, manifestJSON, basePath, isEnabled, installedAt)
                VALUES ('ext', 'Ext', '2.3', x'7b7d', '/tmp/ext', 1, 0)
                """)
        }

        let db = try AppDatabase(dbQueue: dbQueue)

        for profileID in ["profile-a", "00000000-0000-0000-0000-000000000001"] {
            XCTAssertNil(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: profileID, currentVersion: "2.3"),
                         "an existing install must not be replayed in \(profileID)")
        }
        XCTAssertEqual(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "profile-a", currentVersion: "2.4"),
                       .init(reason: .update, previousVersion: "2.3"))
        XCTAssertEqual(db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: "profile-new", currentVersion: "2.3"),
                       .init(reason: .install, previousVersion: nil))
    }
}
