import XCTest
@testable import Detour

/// TASK-382: the rule both navigation delegates apply to a main-frame
/// navigation to a page of the extension whose configuration built the tab's
/// web view. The integration side (a framed web page, the extension's own
/// navigation) is in `ExtensionPageProvenanceTests`.
nonisolated final class ExtensionPageNavigationPolicyTests: XCTestCase {

    private typealias Requester = ExtensionPageNavigationPolicy.Requester
    private static let served = "3b1c2d4e-0000-4000-8000-000000000001"
    private static let otherExtension = "3b1c2d4e-0000-4000-8000-000000000002"
    private static let page = URL(string: "webkit-extension://\(served)/other.html?x=1")!

    @MainActor private func allows(_ url: URL? = ExtensionPageNavigationPolicyTests.page, mainFrame: Bool = true,
                                   served: String? = ExtensionPageNavigationPolicyTests.served,
                                   by requester: Requester?) -> Bool {
        ExtensionPageNavigationPolicy.allows(url, targetsMainFrame: mainFrame, servedOriginHost: served,
                                             requester: requester)
    }

    private static func frame(main: Bool, _ proto: String, _ host: String) -> Requester {
        Requester(isMainFrame: main, originProtocol: proto, originHost: host)
    }

    private static let webSubframe = frame(main: false, "http", "127.0.0.1")

    @MainActor func testAWebFrameIsRefused() {
        XCTAssertFalse(allows(by: Self.webSubframe))
        XCTAssertFalse(allows(by: Self.frame(main: false, "https", "example.com")))
        // A sandboxed or data: frame has an opaque origin, reported empty.
        XCTAssertFalse(allows(by: Self.frame(main: false, "", "")), "an opaque subframe is no Detour document")
        XCTAssertFalse(allows(by: Self.frame(main: false, "webkit-extension", Self.otherExtension)),
                       "another extension's frame")
        XCTAssertFalse(allows(by: Self.frame(main: false, ErrorPage.scheme, "error")), "an error page is only ever the main frame")
    }

    /// WebKit keeps a web page out of such a tab's main frame today; the rule
    /// does not rely on it.
    @MainActor func testAMainFrameHoldingAWebPageIsRefused() {
        XCTAssertFalse(allows(by: Self.frame(main: true, "http", "127.0.0.1")))
        XCTAssertFalse(allows(by: Self.frame(main: true, "webkit-extension", Self.otherExtension)))
    }

    @MainActor func testTheExtensionsOwnFramesAreAllowed() {
        XCTAssertTrue(allows(by: Self.frame(main: true, "webkit-extension", Self.served)))
        XCTAssertTrue(allows(by: Self.frame(main: false, "webkit-extension", Self.served)), "a frame of its own")
        XCTAssertTrue(allows(by: Self.frame(main: true, "WEBKIT-EXTENSION", Self.served.uppercased())),
                      "scheme and host compare case-insensitively")
        XCTAssertTrue(allows(URL(string: "webkit-extension://\(Self.served.uppercased())/other.html")!,
                             by: Self.frame(main: false, "webkit-extension", Self.served)))
    }

    @MainActor func testDetoursOwnLoadsAreAllowed() {
        XCTAssertTrue(allows(by: nil), "an app load that names no frame")
        XCTAssertTrue(allows(by: Self.frame(main: true, "", "")), "a fresh web view's about:blank")
        XCTAssertTrue(allows(by: Self.frame(main: true, ErrorPage.scheme, "error")), "Reload from the error page")
    }

    @MainActor func testOtherNavigationsAreNotThisRulesBusiness() {
        XCTAssertTrue(allows(mainFrame: false, by: Self.webSubframe), "a subframe load: the scheme handler's")
        XCTAssertTrue(allows(served: nil, by: Self.webSubframe), "a web view no extension configuration built")
        XCTAssertTrue(allows(URL(string: "webkit-extension://\(Self.otherExtension)/options.html")!, by: Self.webSubframe),
                      "another extension's page: WebKit refuses it, and the error page names it")
        XCTAssertTrue(allows(URL(string: "https://example.com/")!, by: Self.webSubframe))
        XCTAssertTrue(allows(nil, by: Self.webSubframe))
    }
}
