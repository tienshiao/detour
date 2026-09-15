import XCTest
import GRDB
@testable import Detour

/// Confirming external application URLs (TASK-84): the remembered-decision
/// store and the prompt-or-not policy.
final class ExternalAppPermissionStoreTests: XCTestCase {

    private let profileA = UUID()
    private let profileB = UUID()

    private func makeDatabase() throws -> AppDatabase {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        for id in [profileA, profileB] {
            db.saveProfile(ProfileRecord(id: id.uuidString, name: "P", userAgentMode: 0, customUserAgent: nil,
                                         archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0,
                                         searchSuggestionsEnabled: true, isPerTabIsolation: false,
                                         isAdBlockingEnabled: true, isEasyListEnabled: true,
                                         isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true,
                                         isMalwareFilterEnabled: true))
        }
        return db
    }

    func testAllowIsRememberedForThatOriginAndScheme() throws {
        let store = ExternalAppPermissionStore(database: try makeDatabase())
        XCTAssertFalse(store.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA))

        store.allow(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA, isPrivateProfile: false)

        XCTAssertTrue(store.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA))
        XCTAssertTrue(store.isAllowed(origin: "HTTPS://Zoom.US", scheme: "ZoomMtg", profileID: profileA),
                      "origin and scheme compare case-insensitively")
    }

    func testDecisionIsIsolatedPerOriginSchemeAndProfile() throws {
        let store = ExternalAppPermissionStore(database: try makeDatabase())
        store.allow(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA, isPrivateProfile: false)

        XCTAssertFalse(store.isAllowed(origin: "https://evil.example", scheme: "zoommtg", profileID: profileA))
        XCTAssertFalse(store.isAllowed(origin: "http://zoom.us", scheme: "zoommtg", profileID: profileA))
        XCTAssertFalse(store.isAllowed(origin: "https://zoom.us:8443", scheme: "zoommtg", profileID: profileA))
        XCTAssertFalse(store.isAllowed(origin: "https://zoom.us", scheme: "slack", profileID: profileA))
        XCTAssertFalse(store.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileB))
    }

    func testDecisionsPersistAcrossReload() throws {
        let db = try makeDatabase()
        ExternalAppPermissionStore(database: db)
            .allow(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA, isPrivateProfile: false)

        let reloaded = ExternalAppPermissionStore(database: db)
        XCTAssertTrue(reloaded.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA))
        XCTAssertEqual(reloaded.count(for: profileA), 1)
        XCTAssertEqual(reloaded.count(for: profileB), 0)
    }

    func testPrivateProfileDecisionIsSessionOnlyAndNeverWritten() throws {
        let db = try makeDatabase()
        let privateID = TabStore.incognitoProfileID
        let store = ExternalAppPermissionStore(database: db)

        store.allow(origin: "https://zoom.us", scheme: "zoommtg", profileID: privateID, isPrivateProfile: true)

        XCTAssertTrue(store.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: privateID))
        XCTAssertTrue(db.loadExternalAppPermissions().isEmpty, "nothing reaches the database")
        XCTAssertFalse(ExternalAppPermissionStore(database: db)
            .isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: privateID))
    }

    func testClearAllRemovesOnlyThatProfilesDecisions() throws {
        let db = try makeDatabase()
        let store = ExternalAppPermissionStore(database: db)
        store.allow(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA, isPrivateProfile: false)
        store.allow(origin: "https://slack.com", scheme: "slack", profileID: profileA, isPrivateProfile: false)
        store.allow(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileB, isPrivateProfile: false)
        XCTAssertEqual(store.count(for: profileA), 2)

        store.clearAll(for: profileA)

        XCTAssertEqual(store.count(for: profileA), 0)
        XCTAssertFalse(store.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA))
        XCTAssertTrue(store.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileB))
        XCTAssertEqual(db.loadExternalAppPermissions().map(\.profileID), [profileB.uuidString])
    }
}

final class ExternalAppLaunchPolicyTests: XCTestCase {

    private func decide(hasHandler: Bool = true, isAllowed: Bool = false, isHostedInWindow: Bool = true,
                        isMainFrameRequest: Bool = true,
                        isSheetShowing: Bool = false, origin: String? = "https://zoom.us",
                        isPrivateProfile: Bool = false) -> ExternalAppLaunchDecision {
        ExternalAppLaunchPolicy.decide(hasHandler: hasHandler, isAllowed: isAllowed,
                                       isHostedInWindow: isHostedInWindow, isMainFrameRequest: isMainFrameRequest,
                                       isSheetShowing: isSheetShowing,
                                       origin: origin, isPrivateProfile: isPrivateProfile)
    }

    func testUnrememberedRequestPromptsWithAlwaysAllow() {
        XCTAssertEqual(decide(), .prompt(canRemember: true))
    }

    func testRememberedOriginOpensWithoutPrompt() {
        XCTAssertEqual(decide(isAllowed: true), .open)
        XCTAssertEqual(decide(isAllowed: true, isHostedInWindow: false), .open)
        XCTAssertEqual(decide(isAllowed: true, isSheetShowing: true), .open)
    }

    func testMissingHandlerReportsInsteadOfPrompting() {
        XCTAssertEqual(decide(hasHandler: false), .reportNoHandler)
        XCTAssertEqual(decide(hasHandler: false, isAllowed: true), .reportNoHandler)
        XCTAssertEqual(decide(hasHandler: false, isHostedInWindow: false), .ignore,
                       "a background tab does not raise a toast either")
        XCTAssertEqual(decide(hasHandler: false, isMainFrameRequest: false), .ignore,
                       "a subframe (data: iframe, app probe) does not toast on page load")
    }

    func testSubframeRequestWithHandlerStillPrompts() {
        XCTAssertEqual(decide(isMainFrameRequest: false), .prompt(canRemember: true))
    }

    func testBackgroundRequestIsDropped() {
        XCTAssertEqual(decide(isHostedInWindow: false), .ignore)
    }

    func testRequestWhileASheetIsUpIsDropped() {
        XCTAssertEqual(decide(isSheetShowing: true), .ignore)
    }

    func testPrivateProfileCannotRemember() {
        XCTAssertEqual(decide(isPrivateProfile: true), .prompt(canRemember: false))
    }

    func testOriginlessRequestPromptsWithoutRememberingAndIsNeverAutoOpened() {
        XCTAssertEqual(decide(origin: nil), .prompt(canRemember: false))
        XCTAssertEqual(decide(isAllowed: true, origin: nil), .prompt(canRemember: false))
    }

    func testOriginKey() {
        XCTAssertEqual(ExternalAppLaunchPolicy.origin(protocol: "https", host: "Zoom.US", port: 0), "https://zoom.us")
        XCTAssertEqual(ExternalAppLaunchPolicy.origin(protocol: "http", host: "localhost", port: 3000),
                       "http://localhost:3000")
        XCTAssertNil(ExternalAppLaunchPolicy.origin(protocol: "about", host: "", port: 0))
        XCTAssertNil(ExternalAppLaunchPolicy.origin(protocol: "", host: "", port: 0))
    }
}
