import XCTest
import WebKit
@testable import Detour

/// TASK-55: the Extensions menu decides whether an item opens a popup from
/// `presentsPopup` and the manifest only. Reading `WKWebExtension.Action`'s
/// `popupWebView` creates the popup web view and loads the popup page, and
/// `menuNeedsUpdate` runs on every key-equivalent dispatch — which is how a
/// locked 1Password ended up asking to unlock at launch, with no popup shown.
@MainActor
final class ExtensionMenuPopupDecisionTests: XCTestCase {

    // MARK: - Spy

    /// Records that the decision asked for `presentsPopup` — and, having no
    /// `popupWebView` member at all, proves by construction that it could not
    /// have asked for one.
    private final class SpyAction: ExtensionActionPopupDeclaring {
        private let declares: Bool
        private(set) var presentsPopupReads = 0

        init(presentsPopup: Bool) { self.declares = presentsPopup }

        var presentsPopup: Bool {
            presentsPopupReads += 1
            return declares
        }
    }

    // MARK: - The decision

    func testAnActionThatPresentsAPopupIsClickable() {
        let spy = SpyAction(presentsPopup: true)
        XCTAssertTrue(ExtensionMenuPopupDecision.hasPopup(action: spy, manifestDefaultPopup: nil))
        XCTAssertEqual(spy.presentsPopupReads, 1, "the decision should consult the action")
    }

    func testAnActionWithoutAPopupAndNoManifestDefaultIsNotClickable() {
        let spy = SpyAction(presentsPopup: false)
        XCTAssertFalse(ExtensionMenuPopupDecision.hasPopup(action: spy, manifestDefaultPopup: nil))
        XCTAssertEqual(spy.presentsPopupReads, 1, "the decision should consult the action")
    }

    func testTheManifestDefaultPopupMakesItClickableWhenTheActionSaysNo() {
        let spy = SpyAction(presentsPopup: false)
        XCTAssertTrue(ExtensionMenuPopupDecision.hasPopup(action: spy, manifestDefaultPopup: "popup.html"))
        XCTAssertEqual(spy.presentsPopupReads, 1, "the decision should consult the action")
    }

    func testAnEmptyManifestDefaultPopupCountsAsNoPopup() {
        XCTAssertFalse(ExtensionMenuPopupDecision.hasPopup(action: SpyAction(presentsPopup: false),
                                                           manifestDefaultPopup: ""))
    }

    /// An extension whose context is not loaded for the key window's profile has
    /// no action to ask, so the manifest is the whole answer.
    func testWithoutAnActionTheManifestDecides() {
        XCTAssertFalse(ExtensionMenuPopupDecision.hasPopup(action: nil, manifestDefaultPopup: nil))
        XCTAssertTrue(ExtensionMenuPopupDecision.hasPopup(action: nil, manifestDefaultPopup: "popup.html"))
    }

    // MARK: - Integration: the decision does not load the popup page

    private var tempDirs: [URL] = []
    private var createdProfiles: [Profile] = []
    private var beaconServer: LoopbackHTTPServer?

    override func tearDown() async throws {
        beaconServer?.stop()
        beaconServer = nil
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        }
        createdProfiles.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    /// The real thing: a loaded context for an extension that declares a popup
    /// whose page beacons a loopback server when it loads (an `<img>`, since the
    /// MV3 default CSP blocks inline scripts on extension pages). The menu decision must
    /// answer "yes, clickable" without that beacon ever arriving; an explicit
    /// `popupWebView` read then makes it arrive, which is what proves the hook
    /// works and the first assertion is not vacuous.
    func testTheMenuDecisionDoesNotLoadThePopupPageButAnExplicitReadDoes() async throws {
        let server = try LoopbackHTTPServer(routes: [:])
        beaconServer = server
        let port = try await server.start()

        let ext = try await makeTestExtension(
            id: "menu-popup-\(UUID().uuidString.prefix(8))",
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Menu Popup Decision Test",
                "version": "1.0.0",
                "action": { "default_popup": "popup.html" }
            }
            """,
            files: [
                "popup.html": """
                <html><body>popup
                <img src="http://127.0.0.1:\(port)/popup-loaded" width="1" height="1">
                </body></html>
                """
            ]
        )
        tempDirs.append(ext.basePath)

        let profile = TabStore.shared.addProfile(name: "Menu Popup Decision")
        createdProfiles.append(profile)
        let context = try loadTestContext(ext, in: profile)

        let action = context.action(for: nil)
        XCTAssertNotNil(action, "the loaded context should have an action")
        XCTAssertTrue(ExtensionMenuPopupDecision.hasPopup(action: action,
                                                          manifestDefaultPopup: ext.manifest.action?.defaultPopup),
                      "an extension declaring default_popup is clickable in the menu")

        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(server.requestedPaths, [], "the menu decision must not load the popup page")

        // The explicit present path — what a user click does.
        let popupWebView = action?.popupWebView
        XCTAssertNotNil(popupWebView, "reading popupWebView should create the popup web view")
        try await waitUntil("the popup page to load") { !server.requestedPaths.isEmpty }
    }
}
