import XCTest
import GRDB
import WebKit
@testable import Detour

/// Quarantine (TASK-194): the pure rules in `Quarantine` and
/// `QuickDetour.quarantineOpenInMenu`, and the store's quarantine page — a
/// Quick Detour tab on the Private profile whose web view uses a fresh
/// non-persistent store of its own (`QuarantineSession`), never a profile's.
///
/// Every store here is a private `TabStore` on in-memory databases; pages that
/// must really load come from a loopback HTTP server.
@MainActor
final class QuarantineTests: XCTestCase {

    private var openedTabs: [(store: TabStore, tab: BrowserTab)] = []
    private var servers: [LoopbackHTTPServer] = []
    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)?

    override func tearDown() {
        for (store, tab) in openedTabs { store.closeQuickDetourTab(tab) }
        openedTabs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        if let defaultFaviconFetch {
            FaviconLoader.shared.fetch = defaultFaviconFetch
            FaviconLoader.shared.resetForTesting()
        }
        super.tearDown()
    }

    // MARK: - Link tracking parameters

    private func stripped(_ s: String) -> String {
        Quarantine.removingTrackingParameters(from: URL(string: s)!).absoluteString
    }

    func testClickIDsAndCampaignTagsAreRemoved() {
        XCTAssertEqual(stripped("https://a.test/p?gclid=1&fbclid=2&msclkid=3&utm_source=news&utm_medium=email"
                                + "&utm_campaign=fall&utm_term=t&utm_content=c&mc_eid=4&mc_cid=5"),
                       "https://a.test/p")
        for name in ["gclid", "gclsrc", "dclid", "gbraid", "wbraid", "fbclid", "msclkid", "mc_eid", "mc_cid", "igshid",
                     "yclid", "twclid", "ttclid", "li_fat_id", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id",
                     "oly_enc_id", "vero_id", "rb_clickid", "s_cid", "utm_id", "utm_source_platform"] {
            XCTAssertTrue(Quarantine.isTrackingParameter(name), name)
        }
    }

    func testOtherParametersKeepTheirOrderAndSpelling() {
        XCTAssertEqual(stripped("https://a.test/p?a=1&gclid=x&b=two%20words&utm_source=y&c"),
                       "https://a.test/p?a=1&b=two%20words&c")
        XCTAssertEqual(stripped("https://a.test/search?q=utm_source%3Dx&id=7"), "https://a.test/search?q=utm_source%3Dx&id=7",
                       "a value that mentions a tracking name is not one")
    }

    func testNamesAreComparedWithoutCase() {
        XCTAssertEqual(stripped("https://a.test/?GCLID=1&UTM_Source=x&keep=1"), "https://a.test/?keep=1")
    }

    func testLookalikeNamesAreKept() {
        XCTAssertEqual(stripped("https://a.test/?utm=1&xutm_source=2&gclid_extra=3&fbclid2=4"),
                       "https://a.test/?utm=1&xutm_source=2&gclid_extra=3&fbclid2=4")
        XCTAssertFalse(Quarantine.isTrackingParameter("utm"))
        XCTAssertFalse(Quarantine.isTrackingParameter("id"))
    }

    func testRepeatedAndValuelessTrackingParametersGo() {
        XCTAssertEqual(stripped("https://a.test/?utm_source=a&x=1&utm_source=b&gclid"), "https://a.test/?x=1")
    }

    func testTheFragmentIsKeptAndAnEmptyQueryDropped() {
        XCTAssertEqual(stripped("https://a.test/doc?fbclid=1#section-2"), "https://a.test/doc#section-2")
        XCTAssertEqual(stripped("https://a.test/doc?utm_source=x"), "https://a.test/doc")
    }

    func testAURLWithoutTrackingParametersIsUnchanged() {
        for s in ["https://a.test/", "https://a.test/p?q=1", "http://a.test:8080/p?x=1#y", "https://a.test/p?"] {
            XCTAssertEqual(stripped(s), s)
        }
    }

    func testOnlyWebURLsAreTouched() {
        for s in ["mailto:someone@a.test?utm_source=x", "detour://history?utm_source=x", "data:text/plain,utm_source=x"] {
            XCTAssertEqual(stripped(s), s)
        }
    }

    // MARK: - Which navigations are reloaded without them

    func testAGetNavigationCarryingTrackingParametersIsReloadedWithout() {
        let url = URL(string: "https://a.test/p?utm_campaign=x&id=1")!
        XCTAssertEqual(Quarantine.trackingFreeURL(for: url, httpMethod: "GET", isBackForwardOrReload: false),
                       URL(string: "https://a.test/p?id=1")!)
        XCTAssertEqual(Quarantine.trackingFreeURL(for: url, httpMethod: nil, isBackForwardOrReload: false),
                       URL(string: "https://a.test/p?id=1")!, "no method is a GET")
    }

    func testOtherNavigationsGoThrough() {
        let tracked = URL(string: "https://a.test/p?gclid=1")!
        XCTAssertNil(Quarantine.trackingFreeURL(for: tracked, httpMethod: "POST", isBackForwardOrReload: false),
                     "a form post cannot be replayed")
        XCTAssertNil(Quarantine.trackingFreeURL(for: tracked, httpMethod: "GET", isBackForwardOrReload: true),
                     "back/forward and reload keep their entry")
        XCTAssertNil(Quarantine.trackingFreeURL(for: URL(string: "https://a.test/p?id=1")!, httpMethod: "GET",
                                                isBackForwardOrReload: false), "nothing to remove")
        XCTAssertNil(Quarantine.trackingFreeURL(for: nil, httpMethod: "GET", isBackForwardOrReload: false))
    }

    /// A download keeps its request: loading it again would drop the link's
    /// `download` attribute (the file would show as a page) and its Referer
    /// (code review, TASK-194 follow-up).
    func testADownloadGoesThrough() {
        let tracked = URL(string: "https://a.test/report.pdf?utm_source=x")!
        XCTAssertNil(Quarantine.trackingFreeURL(for: tracked, httpMethod: "GET", isBackForwardOrReload: false,
                                                shouldPerformDownload: true))
    }

    /// A jump to an anchor of the page shown is not a load: removing the
    /// parameters would turn it into one (code review, TASK-194 follow-up).
    func testASameDocumentNavigationGoesThrough() {
        let page = URL(string: "https://a.test/p?utm_source=x")!
        XCTAssertNil(Quarantine.trackingFreeURL(for: URL(string: "https://a.test/p?utm_source=x#section")!,
                                                httpMethod: "GET", isBackForwardOrReload: false, currentURL: page))
        XCTAssertNil(Quarantine.trackingFreeURL(for: URL(string: "https://a.test/p?utm_source=x#b")!,
                                                httpMethod: "GET", isBackForwardOrReload: false,
                                                currentURL: URL(string: "https://a.test/p?utm_source=x#a")!),
                     "from one anchor to another")
        XCTAssertEqual(Quarantine.trackingFreeURL(for: URL(string: "https://a.test/p?utm_source=x")!,
                                                  httpMethod: "GET", isBackForwardOrReload: false, currentURL: page),
                       URL(string: "https://a.test/p")!, "the same address without an anchor is a load")
        XCTAssertEqual(Quarantine.trackingFreeURL(for: URL(string: "https://a.test/q?utm_source=x#s")!,
                                                  httpMethod: "GET", isBackForwardOrReload: false, currentURL: page),
                       URL(string: "https://a.test/q#s")!, "another page's anchor is a load")
    }

    // MARK: - The rewrite always settles

    /// A page or server that sends the clean address straight back to its
    /// parameters (a redirect, `location.replace`) is let through the second
    /// time; it cannot loop the page (code review, TASK-194 follow-up).
    func testTheSameCleanAddressIsRewrittenOnceUntilTheUserNavigates() {
        var rewrites = QuarantineTrackingRewrites()
        let clean = URL(string: "https://a.test/p")!
        XCTAssertTrue(rewrites.allows(clean))
        XCTAssertFalse(rewrites.allows(clean), "back to the parameters: let through")
        XCTAssertFalse(rewrites.allows(clean), "and every time after, until the user navigates")
        XCTAssertTrue(rewrites.allows(URL(string: "https://a.test/other")!), "another address is rewritten")

        rewrites.userNavigated()
        XCTAssertTrue(rewrites.allows(clean), "a click of the user's starts afresh")
    }

    /// A page that keeps inventing new addresses is let through after a
    /// fixed number of rewrites, whatever WebKit tells the policy.
    func testRewritesHaveABudgetPerUserNavigation() {
        var rewrites = QuarantineTrackingRewrites()
        for n in 0..<QuarantineTrackingRewrites.limit {
            XCTAssertTrue(rewrites.allows(URL(string: "https://a.test/p?n=\(n)")!), "rewrite \(n)")
        }
        XCTAssertFalse(rewrites.allows(URL(string: "https://a.test/p?n=new")!), "over budget: let through")
        rewrites.userNavigated()
        XCTAssertTrue(rewrites.allows(URL(string: "https://a.test/p?n=new")!))
    }

    // MARK: - User agent

    func testTheUserAgentIsSafarisWithTheFrozenOSVersionAndNoDetourToken() {
        XCTAssertEqual(Quarantine.userAgent(safariVersion: "26.1"),
                       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                       + "Version/26.1 Safari/605.1.15")
        XCTAssertFalse(Quarantine.userAgent.contains("Detour"))
    }

    // MARK: - WebKit's privacy protections

    func testThePrivacyProtectionsAreSetOnThePreferencesWhenWebKitHasThem() throws {
        let preferences = WKWebpagePreferences()
        guard Quarantine.privacyProtectionsAvailable(on: preferences) else {
            throw XCTSkip("this WebKit has no _networkConnectionIntegrityPolicy")
        }
        XCTAssertTrue(Quarantine.applyPrivacyProtections(to: preferences))
        let set = try XCTUnwrap(Quarantine.privacyProtections(of: preferences))
        XCTAssertEqual(set & Quarantine.privacyProtectionPolicy, Quarantine.privacyProtectionPolicy)
        XCTAssertEqual(Quarantine.privacyProtectionPolicy, 1 | 1 << 6 | 1 << 8,
                       "baseline, fingerprinting protections and link decoration filtering, in WebKit's SPI names")
    }

    func testApplyingThemKeepsWhatWasAlreadySet() throws {
        let preferences = WKWebpagePreferences()
        guard Quarantine.privacyProtectionsAvailable(on: preferences) else {
            throw XCTSkip("this WebKit has no _networkConnectionIntegrityPolicy")
        }
        Quarantine.applyPrivacyProtections(to: preferences)
        Quarantine.applyPrivacyProtections(to: preferences)
        XCTAssertEqual(Quarantine.privacyProtections(of: preferences), Quarantine.privacyProtectionPolicy)
    }

    // MARK: - Open in

    private let personal = QuickDetourProfileSnapshot(id: UUID(), name: "Personal", isPrivate: false, isDeleted: false)
    private let work = QuickDetourProfileSnapshot(id: UUID(), name: "Work", isPrivate: false, isDeleted: false)
    private let gone = QuickDetourProfileSnapshot(id: UUID(), name: "Gone", isPrivate: false, isDeleted: true)
    private let privateProfile = QuickDetourProfileSnapshot(id: TabStore.incognitoProfileID, name: "Private",
                                                            isPrivate: true, isDeleted: false)

    private func space(_ name: String, _ profile: QuickDetourProfileSnapshot, isPrivate: Bool = false) -> QuickDetourSpaceSnapshot {
        QuickDetourSpaceSnapshot(id: UUID(), name: name, emoji: "•", profileID: profile.id, isPrivate: isPrivate)
    }

    func testOpenInListsEverySpaceOfEveryProfileAndEachReloads() {
        let home = space("Home", personal)
        let desk = space("Desk", work)
        let lab = space("Lab", work)
        let menu = QuickDetour.quarantineOpenInMenu(sourceSpaceID: nil, spaces: [home, desk, lab],
                                                    profiles: [privateProfile, personal, work], useOrder: [])
        XCTAssertEqual(menu.sections.map(\.title), ["Personal", "Work"], "profile order; the Private profile has none")
        XCTAssertEqual(menu.sections.map { $0.items.map(\.name) }, [["Home"], ["Desk", "Lab"]])
        XCTAssertTrue(menu.sections.allSatisfy { $0.items.allSatisfy(\.reloads) },
                      "nothing is handed over: every space gets a fresh load on its own profile's store")
        XCTAssertTrue(menu.defaultReloads)
        XCTAssertTrue(menu.showsSectionHeaders)
    }

    func testOpenInNamesTheSpaceTheLinkWasClickedIn() {
        let home = space("Home", personal)
        let desk = space("Desk", work)
        let menu = QuickDetour.quarantineOpenInMenu(sourceSpaceID: desk.id, spaces: [home, desk],
                                                    profiles: [personal, work], useOrder: [home.id])
        XCTAssertEqual(menu.defaultTarget, .space(desk.id))
        XCTAssertEqual(menu.destinationName, "• Desk")
        XCTAssertEqual(menu.sections.flatMap(\.items).filter(\.isDefault).map(\.spaceID), [desk.id])
    }

    func testWithoutASourceOpenInNamesTheMostRecentlyUsedSpace() {
        let home = space("Home", personal)
        let desk = space("Desk", work)
        let menu = QuickDetour.quarantineOpenInMenu(sourceSpaceID: nil, spaces: [home, desk],
                                                    profiles: [personal, work], useOrder: [desk.id, home.id])
        XCTAssertEqual(menu.defaultTarget, .space(desk.id))
        let unused = QuickDetour.quarantineOpenInMenu(sourceSpaceID: nil, spaces: [home, desk],
                                                      profiles: [personal, work], useOrder: [])
        XCTAssertEqual(unused.defaultTarget, .space(home.id), "none used: the first space")
    }

    func testOpenInNeverListsPrivateOrDeletedProfilesSpaces() {
        let home = space("Home", personal)
        let privateSpace = space("Private", privateProfile, isPrivate: true)
        let orphan = space("Orphan", gone)
        let menu = QuickDetour.quarantineOpenInMenu(sourceSpaceID: privateSpace.id, spaces: [privateSpace, orphan, home],
                                                    profiles: [privateProfile, gone, personal],
                                                    useOrder: [privateSpace.id, orphan.id])
        XCTAssertEqual(menu.sections.flatMap(\.items).map(\.spaceID), [home.id])
        XCTAssertEqual(menu.defaultTarget, .space(home.id))
        XCTAssertFalse(menu.showsSectionHeaders, "one profile: no headers")
    }

    func testWithNoNormalSpaceOpenInHasNoTarget() {
        let menu = QuickDetour.quarantineOpenInMenu(sourceSpaceID: nil, spaces: [], profiles: [personal], useOrder: [])
        XCTAssertNil(menu.defaultTarget)
        XCTAssertNil(menu.destinationName)
        XCTAssertFalse(menu.hasDropdown)
    }

    // MARK: - The store: isolation

    private struct Fixture {
        let store: TabStore
        let appDB: AppDatabase
        let historyDB: HistoryDatabase
        let profile: Profile
        let privateProfile: Profile
    }

    private func makeFixture() throws -> Fixture {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let historyDB = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let appDB = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: appDB, historyDB: historyDB, historySettleDebounce: 0.2)
        let profile = store.addProfile(name: "Work")
        _ = store.addSpace(name: "Work", emoji: "W", colorHex: "007AFF", profileID: profile.id)
        return Fixture(store: store, appDB: appDB, historyDB: historyDB, profile: profile,
                       privateProfile: store.ensureIncognitoProfile())
    }

    private func openQuarantine(_ f: Fixture, session: QuarantineSession = QuarantineSession(originalURL: nil),
                                openedWith configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = f.store.openQuickDetourTab(profile: f.privateProfile, openedWith: configuration, quarantine: session)
        openedTabs.append((f.store, tab))
        return tab
    }

    func testTheQuarantinePageHasAFreshStoreOfItsOwn() throws {
        let f = try makeFixture()
        let session = QuarantineSession(originalURL: nil)
        let tab = openQuarantine(f, session: session)
        let store = try XCTUnwrap(tab.webView?.configuration.websiteDataStore)

        XCTAssertTrue(store === session.dataStore)
        XCTAssertFalse(store.isPersistent, "nothing is written to disk")
        XCTAssertFalse(store === f.privateProfile.dataStore, "not the store every Private window shares")
        XCTAssertFalse(store === f.profile.dataStore)
        XCTAssertFalse(store === WKWebsiteDataStore.default())
        XCTAssertTrue(tab.quarantine === session)
        XCTAssertTrue(tab.isQuarantined)
    }

    func testEachQuarantineHasItsOwnStore() throws {
        let f = try makeFixture()
        let first = openQuarantine(f)
        let second = openQuarantine(f)
        XCTAssertFalse(first.webView?.configuration.websiteDataStore === second.webView?.configuration.websiteDataStore)
    }

    func testAWindowThePageOpensSharesItsStore() throws {
        // A `window.open` child must keep its opener, so WebKit hands over a
        // copy of the opener's configuration, store included.
        let f = try makeFixture()
        let session = QuarantineSession(originalURL: nil)
        let opener = openQuarantine(f, session: session)
        let copy = try XCTUnwrap(opener.webView?.configuration.copy() as? WKWebViewConfiguration)
        let child = openQuarantine(f, session: session, openedWith: copy)
        XCTAssertTrue(child.webView?.configuration.websiteDataStore === session.dataStore)
        XCTAssertTrue(child.quarantine === session)
    }

    func testItIsAPrivateQuickDetourWithThePrivateExtensionController() throws {
        let f = try makeFixture()
        let tab = openQuarantine(f)
        XCTAssertTrue(tab.quickDetourProfile === f.privateProfile)
        XCTAssertTrue(tab.webView?.configuration.webExtensionController === f.privateProfile.extensionController,
                      "extensions allowed in Private run in it")
        XCTAssertTrue(f.store.isQuickDetourTab(tab))
        XCTAssertNil(tab.spaceID)
    }

    func testItSendsSafarisUserAgent() throws {
        let f = try makeFixture()
        let tab = openQuarantine(f)
        tab.load(URL(string: "https://quarantine-ua.invalid/")!)
        XCTAssertEqual(tab.webView?.customUserAgent, Quarantine.userAgent)
    }

    func testTheSessionGoesWithItsLastPage() throws {
        let f = try makeFixture()
        weak var weakSession: QuarantineSession?
        var first: BrowserTab!
        var second: BrowserTab!
        do {
            let session = QuarantineSession(originalURL: nil)
            weakSession = session
            first = f.store.openQuickDetourTab(profile: f.privateProfile, quarantine: session)
            let copy = try XCTUnwrap(first.webView?.configuration.copy() as? WKWebViewConfiguration)
            second = f.store.openQuickDetourTab(profile: f.privateProfile, openedWith: copy, quarantine: session)
        }
        f.store.closeQuickDetourTab(first)
        XCTAssertNotNil(weakSession, "the page it opened still uses it")
        f.store.closeQuickDetourTab(second)
        XCTAssertNil(weakSession, "no page left: the store and its data go")
    }

    func testItRecordsNoHistory() async throws {
        let f = try makeFixture()
        let base = try await serve(["/": "<html><head><title>Lookup</title></head><body>x</body></html>"])
        let tab = openQuarantine(f)

        tab.load(base, typed: true)
        try await waitUntil("the page to load") {
            self.pump(0.05)
            return tab.title == "Lookup" && !tab.isLoading
        }
        pump(0.5)

        let everything = try await f.historyDB.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM historyVisit") }
        XCTAssertEqual(everything, 0)
    }

    func testClosingItArchivesNothing() async throws {
        let f = try makeFixture()
        let tab = openQuarantine(f)
        tab.load(URL(string: "https://quarantine-archive.invalid/")!)
        f.store.closeQuickDetourTab(tab, disposition: .archive(autoClosed: false))
        XCTAssertTrue(f.store.archiveEntries().isEmpty)
    }

    func testItFetchesNoFavicon() async throws {
        // A favicon is fetched with the app's own URL session, outside the
        // quarantine's store: a quarantine page has none.
        let f = try makeFixture()
        var fetched: [URL] = []
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { url, completion in
            fetched.append(url)
            completion(nil)
        }
        let base = try await serve(["/": """
            <html><head><title>Icon</title><link rel="icon" href="/icon.png"></head><body>x</body></html>
            """])
        let tab = openQuarantine(f)
        tab.load(base)
        try await waitUntil("the page to load") {
            self.pump(0.05)
            return tab.title == "Icon" && !tab.isLoading
        }
        pump(0.5)
        XCTAssertEqual(fetched, [])
    }

    // MARK: - Helpers

    private func serve(_ routes: [String: String]) async throws -> URL {
        let server = try LoopbackHTTPServer(routes: routes)
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
