import XCTest
import GRDB
@testable import Detour

/// Confirming external application URLs (TASK-84): the remembered-decision
/// store and the prompt-or-not policy.
nonisolated final class ExternalAppPermissionStoreTests: XCTestCase {

    private let profileA = UUID()
    private let profileB = UUID()

    @MainActor private func makeDatabase() throws -> AppDatabase {
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

    @MainActor func testAllowIsRememberedForThatOriginAndScheme() throws {
        let store = ExternalAppPermissionStore(database: try makeDatabase())
        XCTAssertFalse(store.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA))

        store.allow(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA, isPrivateProfile: false)

        XCTAssertTrue(store.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA))
        XCTAssertTrue(store.isAllowed(origin: "HTTPS://Zoom.US", scheme: "ZoomMtg", profileID: profileA),
                      "origin and scheme compare case-insensitively")
    }

    @MainActor func testDecisionIsIsolatedPerOriginSchemeAndProfile() throws {
        let store = ExternalAppPermissionStore(database: try makeDatabase())
        store.allow(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA, isPrivateProfile: false)

        XCTAssertFalse(store.isAllowed(origin: "https://evil.example", scheme: "zoommtg", profileID: profileA))
        XCTAssertFalse(store.isAllowed(origin: "http://zoom.us", scheme: "zoommtg", profileID: profileA))
        XCTAssertFalse(store.isAllowed(origin: "https://zoom.us:8443", scheme: "zoommtg", profileID: profileA))
        XCTAssertFalse(store.isAllowed(origin: "https://zoom.us", scheme: "slack", profileID: profileA))
        XCTAssertFalse(store.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileB))
    }

    @MainActor func testDecisionsPersistAcrossReload() throws {
        let db = try makeDatabase()
        ExternalAppPermissionStore(database: db)
            .allow(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA, isPrivateProfile: false)

        let reloaded = ExternalAppPermissionStore(database: db)
        XCTAssertTrue(reloaded.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: profileA))
        XCTAssertEqual(reloaded.count(for: profileA), 1)
        XCTAssertEqual(reloaded.count(for: profileB), 0)
    }

    @MainActor func testPrivateProfileDecisionIsSessionOnlyAndNeverWritten() throws {
        let db = try makeDatabase()
        let privateID = TabStore.incognitoProfileID
        let store = ExternalAppPermissionStore(database: db)

        store.allow(origin: "https://zoom.us", scheme: "zoommtg", profileID: privateID, isPrivateProfile: true)

        XCTAssertTrue(store.isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: privateID))
        XCTAssertTrue(db.loadExternalAppPermissions().isEmpty, "nothing reaches the database")
        XCTAssertFalse(ExternalAppPermissionStore(database: db)
            .isAllowed(origin: "https://zoom.us", scheme: "zoommtg", profileID: privateID))
    }

    @MainActor func testClearAllRemovesOnlyThatProfilesDecisions() throws {
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

nonisolated final class ExternalAppLaunchPolicyTests: XCTestCase {

    @MainActor private func decide(hasHandler: Bool = true, isAllowed: Bool = false, isHostedInWindow: Bool = true,
                        isMainFrameRequest: Bool = true,
                        isSheetShowing: Bool = false, origin: String? = "https://zoom.us",
                        isPrivateProfile: Bool = false) -> ExternalAppLaunchDecision {
        ExternalAppLaunchPolicy.decide(hasHandler: hasHandler, isAllowed: isAllowed,
                                       isHostedInWindow: isHostedInWindow, isMainFrameRequest: isMainFrameRequest,
                                       isSheetShowing: isSheetShowing,
                                       origin: origin, isPrivateProfile: isPrivateProfile)
    }

    @MainActor func testUnrememberedRequestPromptsWithAlwaysAllow() {
        XCTAssertEqual(decide(), .prompt(canRemember: true))
    }

    @MainActor func testRememberedOriginOpensWithoutPrompt() {
        XCTAssertEqual(decide(isAllowed: true), .open)
        XCTAssertEqual(decide(isAllowed: true, isHostedInWindow: false), .open)
        XCTAssertEqual(decide(isAllowed: true, isSheetShowing: true), .open)
    }

    @MainActor func testMissingHandlerReportsInsteadOfPrompting() {
        XCTAssertEqual(decide(hasHandler: false), .reportNoHandler)
        XCTAssertEqual(decide(hasHandler: false, isAllowed: true), .reportNoHandler)
        XCTAssertEqual(decide(hasHandler: false, isHostedInWindow: false), .ignore,
                       "a background tab does not raise a toast either")
        XCTAssertEqual(decide(hasHandler: false, isMainFrameRequest: false), .ignore,
                       "a subframe (an app probe) does not toast on page load")
    }

    @MainActor func testSubframeRequestWithHandlerStillPrompts() {
        XCTAssertEqual(decide(isMainFrameRequest: false), .prompt(canRemember: true))
    }

    @MainActor func testBackgroundRequestIsDropped() {
        XCTAssertEqual(decide(isHostedInWindow: false), .ignore)
    }

    @MainActor func testRequestWhileASheetIsUpIsDropped() {
        XCTAssertEqual(decide(isSheetShowing: true), .ignore)
    }

    @MainActor func testPrivateProfileCannotRemember() {
        XCTAssertEqual(decide(isPrivateProfile: true), .prompt(canRemember: false))
    }

    @MainActor func testOriginlessRequestPromptsWithoutRememberingAndIsNeverAutoOpened() {
        XCTAssertEqual(decide(origin: nil), .prompt(canRemember: false))
        XCTAssertEqual(decide(isAllowed: true, origin: nil), .prompt(canRemember: false))
    }

    // MARK: - Which schemes are an application's (TASK-159)

    @MainActor func testSchemesAWebViewLoadsItselfAreNotAnApplications() {
        for scheme in ["http", "https", "about", "blob", "data", "webkit-extension", ErrorPage.scheme] {
            XCTAssertFalse(ExternalAppLaunchPolicy.isForExternalApp(scheme: scheme), scheme)
        }
    }

    /// A `data:` URL is a document. Treated as an application's, a tab on
    /// screen never loaded one and a `data:` frame was dropped.
    @MainActor func testADataURLIsLoadedNotHandedToAnApplication() {
        XCTAssertFalse(ExternalAppLaunchPolicy.isForExternalApp(scheme: "data"))
        XCTAssertFalse(ExternalAppLaunchPolicy.isForExternalApp(scheme: "DATA"))
    }

    @MainActor func testOtherSchemesAreAnApplications() {
        for scheme in ["mailto", "zoommtg", "itms-apps", "slack", "tel"] {
            XCTAssertTrue(ExternalAppLaunchPolicy.isForExternalApp(scheme: scheme), scheme)
        }
    }

    @MainActor func testOriginKey() {
        XCTAssertEqual(ExternalAppLaunchPolicy.origin(protocol: "https", host: "Zoom.US", port: 0), "https://zoom.us")
        XCTAssertEqual(ExternalAppLaunchPolicy.origin(protocol: "http", host: "localhost", port: 3000),
                       "http://localhost:3000")
        XCTAssertNil(ExternalAppLaunchPolicy.origin(protocol: "about", host: "", port: 0))
        XCTAssertNil(ExternalAppLaunchPolicy.origin(protocol: "", host: "", port: 0))
    }
}
