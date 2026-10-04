import XCTest
import GRDB
@testable import Detour

/// TASK-134: a `runtime.onInstalled` event counts as delivered only when the
/// claiming background context had a listener for it, or had none and its
/// background content did not fail to load. The rule, the ledger undo behind it
/// and the record of provisional claims; the worker side is in
/// `NewProfileExtensionLoadTests`.
final class RuntimeInstalledEventLoadFailureTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(dbQueue: try DatabaseQueue(configuration: Configuration()))
    }

    private func claim(_ db: AppDatabase, version: String, profile: String = "p1") -> RuntimeInstalledEventClaim? {
        db.claimRuntimeInstalledEventKeepingPrevious(extensionID: "ext", profileID: profile,
                                                     isPrivateProfile: false, currentVersion: version)
    }

    private func pending(_ db: AppDatabase, version: String, profile: String = "p1") -> RuntimeInstalledEvent.Details? {
        db.pendingRuntimeInstalledEvent(extensionID: "ext", profileID: profile,
                                        isPrivateProfile: false, currentVersion: version)
    }

    private func rows(_ db: AppDatabase) throws -> [ExtensionInstalledEventRecord] {
        try db.dbQueue.read { db in
            try ExtensionInstalledEventRecord.order(Column("profileID")).fetchAll(db)
        }
    }

    // MARK: - The rule

    func testAClaimWithAListenerIsDelivered() {
        XCTAssertEqual(RuntimeInstalledEvent.claimDisposition(listenerCount: 1, backgroundLoadFailed: false), .deliver)
        XCTAssertEqual(RuntimeInstalledEvent.claimDisposition(listenerCount: 3, backgroundLoadFailed: false), .deliver)
        // A listener was there, so it is a delivery even from a context whose
        // load is reported failed: the alternative risks delivering twice.
        XCTAssertEqual(RuntimeInstalledEvent.claimDisposition(listenerCount: 1, backgroundLoadFailed: true), .deliver)
    }

    func testAClaimWithoutAListenerIsProvisionalWhileTheLoadHasNotFailed() {
        XCTAssertEqual(RuntimeInstalledEvent.claimDisposition(listenerCount: 0, backgroundLoadFailed: false),
                       .deliverProvisionally)
    }

    func testAClaimWithoutAListenerFromAFailedLoadIsWithheld() {
        XCTAssertEqual(RuntimeInstalledEvent.claimDisposition(listenerCount: 0, backgroundLoadFailed: true), .withhold)
    }

    /// A caller that does not say how many listeners it has (a claim sent by
    /// hand) is treated as before the count existed.
    func testAClaimThatDoesNotReportItsListenersIsDelivered() {
        XCTAssertEqual(RuntimeInstalledEvent.claimDisposition(listenerCount: nil, backgroundLoadFailed: false), .deliver)
        XCTAssertEqual(RuntimeInstalledEvent.claimDisposition(listenerCount: nil, backgroundLoadFailed: true), .deliver)
    }

    // MARK: - Undoing a claim

    func testUndoingAnInstallClaimLeavesTheInstallOwed() throws {
        let db = try makeDatabase()
        let made = try XCTUnwrap(claim(db, version: "1.0"))
        XCTAssertEqual(made.details, .init(reason: .install, previousVersion: nil))
        XCTAssertNil(made.previous)
        XCTAssertNil(pending(db, version: "1.0"))

        XCTAssertTrue(db.undoRuntimeInstalledEventClaim(made))
        XCTAssertEqual(try rows(db), [])
        XCTAssertEqual(pending(db, version: "1.0"), .init(reason: .install, previousVersion: nil))
        // Owed once: the next claim takes it, the one after gets nothing.
        XCTAssertEqual(claim(db, version: "1.0")?.details, .init(reason: .install, previousVersion: nil))
        XCTAssertNil(claim(db, version: "1.0"))
    }

    func testUndoingAnUpdateClaimRestoresTheRowItReplaced() throws {
        let db = try makeDatabase()
        let first = try XCTUnwrap(claim(db, version: "1.0"))
        let update = try XCTUnwrap(claim(db, version: "2.0"))
        XCTAssertEqual(update.details, .init(reason: .update, previousVersion: "1.0"))
        XCTAssertEqual(update.previous, first.written)

        XCTAssertTrue(db.undoRuntimeInstalledEventClaim(update))
        XCTAssertEqual(try rows(db), [first.written], "the row is back exactly as it was, delivery time included")
        XCTAssertEqual(pending(db, version: "2.0"), .init(reason: .update, previousVersion: "1.0"))
    }

    /// A reinstall owes `update` from the installed version; undoing the claim
    /// that answered it brings the reinstall mark back.
    func testUndoingAReinstallClaimRestoresTheReinstallMark() throws {
        let db = try makeDatabase()
        _ = try XCTUnwrap(claim(db, version: "1.0"))
        db.markRuntimeInstalledEventReinstalled(extensionID: "ext")
        let reinstall = try XCTUnwrap(claim(db, version: "1.0"))
        XCTAssertEqual(reinstall.details, .init(reason: .update, previousVersion: "1.0"))
        XCTAssertNil(pending(db, version: "1.0"))

        XCTAssertTrue(db.undoRuntimeInstalledEventClaim(reinstall))
        XCTAssertEqual(pending(db, version: "1.0"), .init(reason: .update, previousVersion: "1.0"))
    }

    func testUndoIsOnlyForTheProfileAndExtensionThatClaimed() throws {
        let db = try makeDatabase()
        let other = try XCTUnwrap(claim(db, version: "1.0", profile: "p2"))
        let made = try XCTUnwrap(claim(db, version: "1.0", profile: "p1"))
        XCTAssertTrue(db.undoRuntimeInstalledEventClaim(made))
        XCTAssertEqual(try rows(db), [other.written])
    }

    /// The ledger moved on after the claim: a later delivery, a reinstall mark or
    /// a removed extension is not overwritten by a late failure report.
    func testUndoLeavesALedgerThatMovedOn() throws {
        let db = try makeDatabase()
        let made = try XCTUnwrap(claim(db, version: "1.0"))

        let later = try XCTUnwrap(claim(db, version: "2.0"))
        XCTAssertFalse(db.undoRuntimeInstalledEventClaim(made), "a later version was delivered")
        XCTAssertEqual(try rows(db), [later.written])

        db.markRuntimeInstalledEventReinstalled(extensionID: "ext")
        XCTAssertFalse(db.undoRuntimeInstalledEventClaim(later), "a reinstall was marked")
        XCTAssertEqual(pending(db, version: "2.0"), .init(reason: .update, previousVersion: "2.0"))

        _ = try db.dbQueue.write { db in try ExtensionInstalledEventRecord.deleteAll(db) }
        XCTAssertFalse(db.undoRuntimeInstalledEventClaim(later), "the row is gone")
        XCTAssertEqual(try rows(db), [])
    }

    func testAnUndoneClaimCannotBeUndoneTwice() throws {
        let db = try makeDatabase()
        let made = try XCTUnwrap(claim(db, version: "1.0"))
        XCTAssertTrue(db.undoRuntimeInstalledEventClaim(made))
        XCTAssertFalse(db.undoRuntimeInstalledEventClaim(made))
        // And not after the event was delivered for real.
        _ = try XCTUnwrap(claim(db, version: "1.0"))
        XCTAssertFalse(db.undoRuntimeInstalledEventClaim(made), "the delivery time differs from the undone claim's")
        XCTAssertNil(pending(db, version: "1.0"))
    }

    // MARK: - Provisional claims

    private final class FakeContext {}

    func testTheClaimingContextsLoadFailureUndoesItsClaim() throws {
        let db = try makeDatabase()
        let claims = ProvisionalInstalledEventClaims()
        let context = FakeContext()
        let made = try XCTUnwrap(claim(db, version: "1.0"))
        claims.record(made, context: context, extensionID: "ext", profileID: "p1")

        XCTAssertEqual(claims.contextFailedToLoad(context, extensionID: "ext", profileID: "p1", database: db),
                       .init(reason: .install, previousVersion: nil))
        XCTAssertEqual(pending(db, version: "1.0"), .init(reason: .install, previousVersion: nil))
        // WebKit repeats the notification while the error is listed.
        XCTAssertNil(claims.contextFailedToLoad(context, extensionID: "ext", profileID: "p1", database: db))
    }

    /// The recovery reload gives the extension a new context; a late or
    /// repeated failure report from the old one must not undo the new one's
    /// claim, nor one from another profile or extension.
    func testAnotherContextsFailureUndoesNothing() throws {
        let db = try makeDatabase()
        let claims = ProvisionalInstalledEventClaims()
        let claimant = FakeContext()
        let stale = FakeContext()
        let made = try XCTUnwrap(claim(db, version: "1.0"))
        claims.record(made, context: claimant, extensionID: "ext", profileID: "p1")

        XCTAssertNil(claims.contextFailedToLoad(stale, extensionID: "ext", profileID: "p1", database: db))
        XCTAssertNil(claims.contextFailedToLoad(claimant, extensionID: "ext", profileID: "p2", database: db))
        XCTAssertNil(claims.contextFailedToLoad(claimant, extensionID: "other", profileID: "p1", database: db))
        XCTAssertNil(pending(db, version: "1.0"), "the claim stands")

        XCTAssertNotNil(claims.contextFailedToLoad(claimant, extensionID: "ext", profileID: "p1", database: db))
    }

    func testANewerClaimReplacesAnOlderOneOnRecord() throws {
        let db = try makeDatabase()
        let claims = ProvisionalInstalledEventClaims()
        let old = FakeContext()
        let new = FakeContext()
        let first = try XCTUnwrap(claim(db, version: "1.0"))
        claims.record(first, context: old, extensionID: "ext", profileID: "p1")
        let second = try XCTUnwrap(claim(db, version: "2.0"))
        claims.record(second, context: new, extensionID: "ext", profileID: "p1")

        XCTAssertNil(claims.contextFailedToLoad(old, extensionID: "ext", profileID: "p1", database: db))
        XCTAssertEqual(claims.contextFailedToLoad(new, extensionID: "ext", profileID: "p1", database: db),
                       .init(reason: .update, previousVersion: "1.0"))
        XCTAssertEqual(try rows(db), [first.written])
    }

    func testAClaimWithoutARecordIsNotUndoneByAFailure() throws {
        let db = try makeDatabase()
        let claims = ProvisionalInstalledEventClaims()
        _ = try XCTUnwrap(claim(db, version: "1.0"))
        XCTAssertNil(claims.contextFailedToLoad(FakeContext(), extensionID: "ext", profileID: "p1", database: db))
        XCTAssertNil(pending(db, version: "1.0"))
    }
}
