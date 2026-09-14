import XCTest
import GRDB
import WebKit
@testable import Detour

/// The per-site content blocker switch (TASK-69): the host decision, its
/// persistence, and that turning it off for a navigation really stops WebKit
/// blocking — plus the blocked-load counter WebKit itself reports.
@MainActor
final class ContentBlockerWhitelistTests: XCTestCase {

    // MARK: - The decision

    func testCoversMatchesTheExactHost() {
        XCTAssertTrue(ContentBlockerWhitelist.covers(host: "example.com", whitelistedHosts: ["example.com"]))
    }

    func testCoversMatchesASubdomainOfAStoredHost() {
        XCTAssertTrue(ContentBlockerWhitelist.covers(host: "www.example.com", whitelistedHosts: ["example.com"]))
        XCTAssertTrue(ContentBlockerWhitelist.covers(host: "a.b.example.com", whitelistedHosts: ["example.com"]))
    }

    func testCoversDoesNotMatchAParentOfAStoredHost() {
        // Whitelisting www.example.com must not whitelist example.com itself.
        XCTAssertFalse(ContentBlockerWhitelist.covers(host: "example.com", whitelistedHosts: ["www.example.com"]))
    }

    func testCoversDoesNotMatchASiblingSharingTheSuffix() {
        XCTAssertFalse(ContentBlockerWhitelist.covers(host: "notexample.com", whitelistedHosts: ["example.com"]))
        XCTAssertFalse(ContentBlockerWhitelist.covers(host: "evilexample.com", whitelistedHosts: ["example.com"]))
    }

    func testCoversDoesNotMatchAnUnrelatedHost() {
        XCTAssertFalse(ContentBlockerWhitelist.covers(host: "other.test", whitelistedHosts: ["example.com", "a.example"]))
    }

    func testCoversIsCaseInsensitive() {
        XCTAssertTrue(ContentBlockerWhitelist.covers(host: "WWW.Example.COM", whitelistedHosts: ["example.com"]))
        XCTAssertTrue(ContentBlockerWhitelist.covers(host: "www.example.com", whitelistedHosts: ["EXAMPLE.com"]))
    }

    func testCoversRejectsAnEmptyHostAndEmptyEntries() {
        XCTAssertFalse(ContentBlockerWhitelist.covers(host: "", whitelistedHosts: ["example.com"]))
        XCTAssertFalse(ContentBlockerWhitelist.covers(host: "example.com", whitelistedHosts: []))
        XCTAssertFalse(ContentBlockerWhitelist.covers(host: "example.com", whitelistedHosts: [""]))
    }

    // MARK: - Persistence

    /// An in-memory database holding one profile row, so the whitelist's
    /// foreign key holds without touching the shared test database.
    private func makeDatabase(profileID: UUID) throws -> AppDatabase {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        db.saveProfile(ProfileRecord(
            id: profileID.uuidString, name: "Test", userAgentMode: 0, customUserAgent: nil,
            archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0,
            searchSuggestionsEnabled: true, isPerTabIsolation: false, isAdBlockingEnabled: true,
            isEasyListEnabled: true, isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true,
            isMalwareFilterEnabled: true))
        return db
    }

    private func makeWhitelist() throws -> (ContentBlockerWhitelist, UUID, AppDatabase) {
        let profileID = UUID()
        let db = try makeDatabase(profileID: profileID)
        return (ContentBlockerWhitelist(database: db), profileID, db)
    }

    func testTogglingAHostStoresItAndSurvivesAReload() throws {
        let (whitelist, profileID, database) = try makeWhitelist()
        XCTAssertFalse(whitelist.isWhitelisted(host: "example.com", profileID: profileID))

        whitelist.toggleHost("example.com", profileID: profileID)
        XCTAssertTrue(whitelist.isWhitelisted(host: "example.com", profileID: profileID))
        XCTAssertEqual(whitelist.hostsForProfile(profileID), ["example.com"])

        let reloaded = ContentBlockerWhitelist(database: database)
        reloaded.loadFromDatabase()
        XCTAssertTrue(reloaded.isWhitelisted(host: "example.com", profileID: profileID))
        XCTAssertTrue(reloaded.isWhitelisted(host: "www.example.com", profileID: profileID),
                      "a stored host covers its subdomains after a reload too")
    }

    func testTogglingAHostOffRemovesTheStoredEntry() throws {
        let (whitelist, profileID, database) = try makeWhitelist()
        whitelist.toggleHost("example.com", profileID: profileID)
        whitelist.toggleHost("example.com", profileID: profileID)

        XCTAssertFalse(whitelist.isWhitelisted(host: "example.com", profileID: profileID))
        XCTAssertTrue(whitelist.hostsForProfile(profileID).isEmpty)
        XCTAssertTrue(database.loadContentBlockerWhitelist().isEmpty)
    }

    /// Turning the switch back on for a subdomain has to drop the parent entry
    /// that covers it, or blocking would stay off and the switch would not take.
    func testTogglingASubdomainOffAlsoRemovesTheParentEntryCoveringIt() throws {
        let (whitelist, profileID, database) = try makeWhitelist()
        whitelist.toggleHost("example.com", profileID: profileID)
        whitelist.toggleHost("www.example.com", profileID: profileID)  // already covered: turns it back on

        XCTAssertFalse(whitelist.isWhitelisted(host: "www.example.com", profileID: profileID))
        XCTAssertFalse(whitelist.isWhitelisted(host: "example.com", profileID: profileID),
                       "the parent entry went with it")
        XCTAssertTrue(database.loadContentBlockerWhitelist().isEmpty)
    }

    func testTogglingOneHostLeavesUnrelatedEntriesAlone() throws {
        let (whitelist, profileID, _) = try makeWhitelist()
        whitelist.toggleHost("example.com", profileID: profileID)
        whitelist.toggleHost("other.test", profileID: profileID)
        whitelist.toggleHost("example.com", profileID: profileID)

        XCTAssertEqual(whitelist.hostsForProfile(profileID), ["other.test"])
    }

    func testWhitelistEntriesAreScopedToTheProfile() throws {
        let (whitelist, profileID, _) = try makeWhitelist()
        whitelist.toggleHost("example.com", profileID: profileID)
        XCTAssertFalse(whitelist.isWhitelisted(host: "example.com", profileID: UUID()))
    }

    // MARK: - The switch in a real web view

    private let blockedImageURL = URL(string: "http://blocked.example/x.png")!
    private let pageURL = URL(string: "http://site.example/")!
    private var compiledRuleListIdentifier: String?

    /// A rule list blocking anything under `blocked.example`, compiled in the
    /// test data directory's own store (TASK-36).
    private func compileBlockingRuleList() async throws -> WKContentRuleList {
        let identifier = "task69-block-\(UUID().uuidString.prefix(8))"
        let store = ContentBlockerStorage.current.ruleListStore
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: #"[{"trigger":{"url-filter":"blocked\\.example"},"action":{"type":"block"}}]"#
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
        compiledRuleListIdentifier = identifier
        return list
    }

    override func tearDown() async throws {
        if let identifier = compiledRuleListIdentifier {
            compiledRuleListIdentifier = nil
            let store = ContentBlockerStorage.current.ruleListStore
            await withCheckedContinuation { continuation in
                store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
            }
        }
        try await super.tearDown()
    }

    private func makeWebView(with list: WKContentRuleList) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(list)
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
    }

    /// The page HTML: one image WebKit must block, one it may try (and fail) to
    /// load — no network is needed, the block happens before the request.
    private var pageHTML: String { "<html><body><img src='\(blockedImageURL.absoluteString)'></body></html>" }

    /// WebKit reports a blocked subresource load through the private navigation
    /// delegate callback — exactly one blockedLoad for the image.
    func testWebKitReportsTheBlockedSubresourceLoad() async throws {
        let list = try await compileBlockingRuleList()
        let delegate = RecordingNavigationDelegate()
        let webView = makeWebView(with: list)
        defer { webView.navigationDelegate = nil }
        webView.navigationDelegate = delegate

        webView.loadHTMLString(pageHTML, baseURL: pageURL)
        try await waitUntil("the page finished loading") { delegate.finished }
        try await waitUntil("the blocked load is reported") { !delegate.actions.isEmpty }

        XCTAssertTrue(delegate.sawPolicyDecision,
                      "the preferences policy callback must run, or the switch could never apply")
        let blocked = delegate.actions.filter { $0.blockedLoad }
        XCTAssertEqual(blocked.count, 1, "actions: \(delegate.actions)")
        XCTAssertEqual(blocked.first?.url, blockedImageURL)
    }

    /// With the host whitelisted, the production helper disables the content
    /// rule lists for that navigation and nothing is blocked at all.
    func testDisablingContentBlockersForAWhitelistedHostStopsTheBlocking() async throws {
        let list = try await compileBlockingRuleList()
        let (whitelist, profileID, _) = try makeWhitelist()
        whitelist.toggleHost(pageURL.host!, profileID: profileID)

        let delegate = RecordingNavigationDelegate()
        // What `ContentBlockerManager.configure(_:forNavigationTo:profile:)`
        // does, against a whitelist that is not the shared singleton's.
        delegate.configurePreferences = { preferences, url in
            guard let host = url?.host, whitelist.isWhitelisted(host: host, profileID: profileID) else { return }
            ContentBlockerManager.setContentBlockersEnabled(false, on: preferences)
        }
        let webView = makeWebView(with: list)
        defer { webView.navigationDelegate = nil }
        webView.navigationDelegate = delegate

        webView.loadHTMLString(pageHTML, baseURL: pageURL)
        try await waitUntil("the page finished loading") { delegate.finished }
        // Let the image load attempt run out: a blocked one is reported by the
        // time the page finishes, an unblocked one fails at DNS instead.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertTrue(delegate.sawPolicyDecision)
        XCTAssertTrue(delegate.actions.isEmpty,
                      "no rule list may act on a page whose content blockers are off: \(delegate.actions)")
    }

    /// The SPI both halves of the fix depend on is really there on this OS.
    func testTheContentBlockerPreferencesSPIExists() {
        XCTAssertTrue(WKWebpagePreferences().responds(to: NSSelectorFromString("_setContentBlockersEnabled:")))
    }

    // MARK: - The counter

    /// WebKit reports a blocked load once per rule list that acted on it, and
    /// the filter lists overlap: a resource counts once.
    func testABlockedLoadCountsOncePerResource() {
        let tab = BrowserTab(id: UUID(), configuration: WKWebViewConfiguration())
        defer { tab.teardown() }
        tab.recordBlockedLoad(of: blockedImageURL)
        tab.recordBlockedLoad(of: blockedImageURL)
        tab.recordBlockedLoad(of: URL(string: "http://blocked.example/y.png")!)
        XCTAssertEqual(tab.blockedCount, 2)
    }

    func testCommittingANavigationResetsTheBlockedCount() {
        let tab = BrowserTab(id: UUID(), configuration: WKWebViewConfiguration())
        defer { tab.teardown() }
        tab.recordBlockedLoad(of: blockedImageURL)
        tab.didCommitNavigation()
        XCTAssertEqual(tab.blockedCount, 0)
        tab.recordBlockedLoad(of: blockedImageURL)
        XCTAssertEqual(tab.blockedCount, 1, "the next page counts the same resource afresh")
    }

    // MARK: - Unclaimed web views

    /// A tab opened in the background loads before any window installs itself
    /// as navigation delegate; without one WebKit would use the configuration's
    /// default preferences and the switch would never be consulted. The tab is
    /// the delegate of record until a window claims the web view.
    func testAnUnclaimedTabIsItsWebViewsNavigationDelegate() {
        let tab = BrowserTab(id: UUID(), configuration: WKWebViewConfiguration())
        defer { tab.teardown() }
        XCTAssertTrue(tab.webView?.navigationDelegate === tab)
    }
}

/// Records what WebKit reports through the private content-rule-list action
/// callback, and applies whatever the test wants to the navigation's
/// preferences — the same two callbacks `BrowserWindowController` implements.
@MainActor
private final class RecordingNavigationDelegate: NSObject, WKNavigationDelegate {

    struct PerformedAction: CustomStringConvertible {
        let identifier: String
        let blockedLoad: Bool
        let url: URL
        var description: String { "\(identifier) blockedLoad=\(blockedLoad) \(url)" }
    }

    private(set) var actions: [PerformedAction] = []
    private(set) var finished = false
    private(set) var sawPolicyDecision = false
    var configurePreferences: ((WKWebpagePreferences, URL?) -> Void)?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true {
            sawPolicyDecision = true
            configurePreferences?(preferences, navigationAction.request.url)
        }
        decisionHandler(.allow, preferences)
    }

    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String,
                 performedAction action: NSObject, forURL url: URL) {
        // Guarded like production: an undefined key raises an ObjC exception.
        let blockedLoad = action.responds(to: NSSelectorFromString("blockedLoad"))
            && action.value(forKey: "blockedLoad") as? Bool == true
        actions.append(PerformedAction(identifier: identifier, blockedLoad: blockedLoad, url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finished = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        finished = true
    }
}
