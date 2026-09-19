import XCTest
import WebKit
@testable import Detour

/// The pure rules that keep internal pages (`detour://history/`) out of reach
/// of web content: URL classification, the navigation policy, the scheme
/// handler's main-document check and the bridge's sender verification.
final class InternalPageTests: XCTestCase {
    private let history = URL(string: "detour://history/")!
    private let web = URL(string: "https://example.com/")!

    // MARK: - URL classification

    func testPageFromURL() {
        XCTAssertEqual(InternalPage(url: history), .history)
        XCTAssertEqual(InternalPage(url: URL(string: "detour://history/page.css")!), .history)
        XCTAssertEqual(InternalPage(url: URL(string: "detour://history/?q=swift")!), .history)
        XCTAssertEqual(InternalPage(url: URL(string: "DETOUR://History/")!), .history)
        XCTAssertEqual(InternalPage.history.url, history)
    }

    func testUnknownHostIsInternalButNoPage() {
        let unknown = URL(string: "detour://settings/")!
        XCTAssertTrue(InternalPage.isInternal(unknown))
        XCTAssertNil(InternalPage(url: unknown))
    }

    func testOtherSchemesAreNotInternal() {
        XCTAssertFalse(InternalPage.isInternal(web))
        XCTAssertFalse(InternalPage.isInternal(URL(string: "detour-favicon://history/")!))
        XCTAssertFalse(InternalPage.isInternal(URL(string: "https://history/")!))
        XCTAssertFalse(InternalPage.isInternal(nil))
        XCTAssertNil(InternalPage(url: URL(string: "https://history/")!))
    }

    // MARK: - Navigation policy

    private func decision(_ url: URL?, mainFrame: Bool = true, type: WKNavigationType = .other,
                          armed: InternalPage? = nil, entries: Set<URL> = []) -> InternalPageNavigationPolicy.Decision {
        InternalPageNavigationPolicy.decision(for: url, targetsMainFrame: mainFrame, navigationType: type,
                                              armedPage: armed, sessionEntryURLs: entries)
    }

    private func allows(_ url: URL?, mainFrame: Bool = true, type: WKNavigationType = .other,
                        armed: InternalPage? = nil, entries: Set<URL> = []) -> Bool {
        decision(url, mainFrame: mainFrame, type: type, armed: armed, entries: entries).allows
    }

    func testPolicyIgnoresOtherSchemes() {
        XCTAssertTrue(allows(web))
        XCTAssertTrue(allows(web, mainFrame: false, type: .linkActivated))
        XCTAssertTrue(allows(nil))
    }

    func testArmedTabMayLoadItsPage() {
        XCTAssertTrue(allows(history, armed: .history))
        XCTAssertTrue(allows(URL(string: "detour://history/?q=x")!, armed: .history))
    }

    func testUnarmedNavigationIsRefused() {
        // A link, a script navigation, a form, an extension's tabs.update: all
        // arrive without the tab having been armed.
        for type in [WKNavigationType.linkActivated, .other, .formSubmitted, .formResubmitted] {
            XCTAssertFalse(allows(history, type: type), "type \(type.rawValue)")
        }
    }

    func testSubframeAndNewWindowAreRefusedEvenWhenArmed() {
        // `mainFrame: false` covers both an <iframe> and a nil target frame.
        XCTAssertFalse(allows(history, mainFrame: false, armed: .history))
        XCTAssertFalse(allows(history, mainFrame: false, type: .backForward, entries: [history]))
        XCTAssertFalse(allows(history, mainFrame: false, type: .reload, entries: [history]))
    }

    func testBackForwardAndReloadRevisitASessionEntryWithoutArming() {
        // Session restore arrives as .backForward in a fresh, unarmed web view
        // whose list is already in place.
        XCTAssertEqual(decision(history, type: .backForward, entries: [web, history]), .allowedAsRevisit)
        XCTAssertEqual(decision(history, type: .reload, entries: [history]), .allowedAsRevisit)
        let search = URL(string: "detour://history/?q=swift")!
        XCTAssertTrue(allows(search, type: .reload, entries: [search]), "replaceState rewrites the entry")
    }

    func testARedirectDuringBackForwardIsRefused() {
        // Going back to a web page that answers 302 detour://history/?q=… keeps
        // the .backForward type, but its URL is no entry of the list.
        let forged = URL(string: "detour://history/?q=attacker")!
        XCTAssertFalse(allows(forged, type: .backForward, entries: [web, history]))
        XCTAssertFalse(allows(history, type: .backForward, entries: [web]))
        XCTAssertFalse(allows(history, type: .reload))
    }

    func testOnlyAnArmingAllowIsSpent() {
        XCTAssertEqual(decision(history, armed: .history), .allowedByArming)
        XCTAssertEqual(decision(history, type: .backForward, entries: [history]), .allowedAsRevisit)
        XCTAssertEqual(decision(web, armed: .history), .notInternal)
        XCTAssertEqual(decision(history), .refused)
    }

    func testUnknownInternalHostIsAlwaysRefused() {
        let unknown = URL(string: "detour://settings/")!
        XCTAssertFalse(allows(unknown, armed: .history))
        XCTAssertFalse(allows(unknown, type: .backForward, entries: [unknown]))
    }

    // MARK: - Scheme handler

    private func request(_ url: String, mainDocument: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.mainDocumentURL = mainDocument.flatMap(URL.init(string:))
        return request
    }

    func testSchemeHandlerServesOnlyInternalMainDocuments() {
        XCTAssertEqual(InternalPageSchemeHandler.page(serving: request("detour://history/", mainDocument: "detour://history/")), .history)
        XCTAssertEqual(InternalPageSchemeHandler.page(serving: request("detour://history/page.css", mainDocument: "detour://history/?q=x")), .history)
        // Embedded in, or fetched by, a web page.
        XCTAssertNil(InternalPageSchemeHandler.page(serving: request("detour://history/", mainDocument: "https://example.com/")))
        XCTAssertNil(InternalPageSchemeHandler.page(serving: request("detour://history/page.css", mainDocument: "https://example.com/")))
        XCTAssertNil(InternalPageSchemeHandler.page(serving: request("detour://history/", mainDocument: nil)))
        XCTAssertNil(InternalPageSchemeHandler.page(serving: request("detour://settings/", mainDocument: "detour://settings/")))
    }

    func testContentSecurityPolicyAllowsNoScript() {
        let csp = InternalPageSchemeHandler.contentSecurityPolicy
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertFalse(csp.contains("script-src"))
        XCTAssertFalse(csp.contains("unsafe-inline"))
        XCTAssertTrue(csp.contains("frame-ancestors 'none'"))
    }

    // MARK: - Bridge sender verification

    private func authorized(mainFrame: Bool = true, proto: String = "detour", host: String = "history",
                            frame: URL? = URL(string: "detour://history/"),
                            webView: URL? = URL(string: "detour://history/")) -> InternalPage? {
        InternalPageBridge.authorizedPage(isMainFrame: mainFrame, originProtocol: proto, originHost: host,
                                          frameURL: frame, webViewURL: webView)
    }

    func testBridgeAcceptsTheInternalMainFrame() {
        XCTAssertEqual(authorized(), .history)
    }

    func testBridgeRejectsEveryOtherSender() {
        XCTAssertNil(authorized(mainFrame: false), "subframe")
        XCTAssertNil(authorized(proto: "https", host: "example.com", frame: web, webView: web), "web page")
        XCTAssertNil(authorized(proto: "https", host: "history"), "web origin named like the page")
        XCTAssertNil(authorized(proto: "webkit-extension", host: "history"), "extension page")
        XCTAssertNil(authorized(host: "settings"), "unknown internal host")
        XCTAssertNil(authorized(frame: web), "frame URL disagrees")
        XCTAssertNil(authorized(webView: web), "web view URL disagrees")
        XCTAssertNil(authorized(frame: nil))
        XCTAssertNil(authorized(webView: nil))
        XCTAssertNil(authorized(proto: "", host: ""), "opaque origin")
    }

    // MARK: - Installation

    func testInstallIsIdempotent() {
        let configuration = WKWebViewConfiguration()
        InternalPageBridge.install(on: configuration)
        let count = configuration.userContentController.userScripts.count
        // A second registration of the handler name would raise.
        InternalPageBridge.install(on: configuration)
        XCTAssertEqual(configuration.userContentController.userScripts.count, count)
        XCTAssertEqual(count, InternalPage.allCases.count)
    }

    func testUserScriptIsInertOffItsPage() {
        let source = InternalPageBridge.userScriptSource(for: .history)
        XCTAssertTrue(source.contains("location.protocol !== 'detour:'"))
        XCTAssertTrue(source.contains("location.host !== 'history'"))
    }
}
