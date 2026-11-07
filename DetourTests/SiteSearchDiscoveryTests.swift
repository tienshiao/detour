import XCTest
import GRDB
import WebKit
@testable import Detour

/// TASK-288: site searches discovered from a page's OpenSearch description —
/// parsing the description and converting its template, the rules for what
/// may be fetched and added, the store's discovered entries and removed
/// hosts (migration v22), Tab on a discovered entry, the discoverer, the
/// fetcher against a loopback server, and the whole path from a tab's load.
nonisolated final class OpenSearchDescriptionTests: XCTestCase {

    private func parse(_ xml: String) -> OpenSearchDescription? {
        OpenSearchDescription(data: Data(xml.utf8))
    }

    private func description(name: String = "Example", urls: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <ShortName>\(name)</ShortName>
          <Description>Search Example</Description>
          \(urls)
        </OpenSearchDescription>
        """
    }

    // MARK: Parsing

    func testAValidDescriptionGivesItsNameAndResultsTemplate() {
        let parsed = parse(description(urls: """
            <Url type="application/x-suggestions+json" template="https://example.com/suggest?q={searchTerms}"/>
            <Url type="text/html" method="get" template="https://example.com/search?q={searchTerms}&amp;src=os"/>
            """))
        XCTAssertEqual(parsed, OpenSearchDescription(name: "Example",
                                                     urlTemplate: "https://example.com/search?q=%s&src=os"))
    }

    /// Wikipedia's form: a prefixed namespace, a `rel`, an optional parameter.
    func testAPrefixedNamespaceAndOptionalParametersParse() {
        let parsed = parse("""
            <?xml version="1.0"?>
            <os:OpenSearchDescription xmlns:os="http://a9.com/-/spec/opensearch/1.1/">
              <os:ShortName>  Wikipedia
                 (en) </os:ShortName>
              <os:Url type="TEXT/HTML" rel="results"
                      template="https://en.wikipedia.org/w/index.php?title=Special:Search&amp;search={searchTerms}&amp;page={startPage?}"/>
            </os:OpenSearchDescription>
            """)
        XCTAssertEqual(parsed?.name, "Wikipedia (en)", "whitespace collapsed")
        XCTAssertEqual(parsed?.urlTemplate,
                       "https://en.wikipedia.org/w/index.php?title=Special:Search&search=%s&page=")
    }

    func testMalformedXMLGivesNothing() {
        XCTAssertNil(parse("<OpenSearchDescription><ShortName>Broken</ShortName><Url type=\"text/html\""))
        XCTAssertNil(parse("not xml at all"))
        XCTAssertNil(parse(""))
    }

    func testADescriptionWithoutAResultsTemplateGivesNothing() {
        XCTAssertNil(parse(description(urls: "")), "no Url")
        XCTAssertNil(parse(description(urls: "<Url type=\"text/html\"/>")), "no template")
        XCTAssertNil(parse(description(urls: """
            <Url type="application/x-suggestions+json" template="https://example.com/s?q={searchTerms}"/>
            """)), "suggestions only")
        XCTAssertNil(parse(description(urls: """
            <Url type="text/html" method="post" template="https://example.com/search"/>
            """)), "POST only")
        XCTAssertNil(parse(description(urls: """
            <Url type="text/html" rel="suggestions" template="https://example.com/s?q={searchTerms}"/>
            """)), "not a results URL")
        XCTAssertNil(parse(description(urls: """
            <Url type="text/html" template="https://example.com/browse"/>
            """)), "no {searchTerms}")
    }

    func testTheFirstUsableResultsTemplateWins() {
        let parsed = parse(description(urls: """
            <Url type="text/html" template="https://example.com/a?q={unknownRequired}"/>
            <Url type="text/html" template="https://example.com/b?q={searchTerms}"/>
            <Url type="text/html" template="https://example.com/c?q={searchTerms}"/>
            """))
        XCTAssertEqual(parsed?.urlTemplate, "https://example.com/b?q=%s")
    }

    func testAnotherRootOrANestedUrlIsNotADescription() {
        XCTAssertNil(parse("<html><Url type=\"text/html\" template=\"https://e.com/?q={searchTerms}\"/></html>"))
        XCTAssertNil(parse(description(urls: """
            <Extension><Url type="text/html" template="https://example.com/?q={searchTerms}"/></Extension>
            """)), "a Url inside another element is not the description's")
    }

    func testANameIsOptionalAndCappedInLength() {
        XCTAssertEqual(parse("""
            <OpenSearchDescription><Url type="text/html" template="https://e.com/?q={searchTerms}"/></OpenSearchDescription>
            """)?.name, "")
        let long = String(repeating: "N", count: 200)
        XCTAssertEqual(parse(description(name: long, urls: """
            <Url type="text/html" template="https://e.com/?q={searchTerms}"/>
            """))?.name.count, OpenSearchDescription.maxNameLength)
    }

    func testExternalEntitiesAreNeverResolved() throws {
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("opensearch-xxe-\(UUID()).txt")
        try "the secret".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        let parsed = parse("""
            <?xml version="1.0"?>
            <!DOCTYPE OpenSearchDescription [<!ENTITY leak SYSTEM "\(secret.absoluteString)">]>
            <OpenSearchDescription>
              <ShortName>A&leak;</ShortName>
              <Url type="text/html" template="https://e.com/?q={searchTerms}"/>
            </OpenSearchDescription>
            """)
        XCTAssertFalse(parsed?.name.contains("secret") ?? false, "the file's contents must not be read in")
    }

    // MARK: Template conversion

    func testTemplateParametersAreConverted() {
        XCTAssertEqual(siteSearchTemplate(fromOpenSearch: "https://e.com/?q={searchTerms}"), "https://e.com/?q=%s")
        XCTAssertEqual(siteSearchTemplate(fromOpenSearch: "https://e.com/{searchTerms}/{searchTerms?}"),
                       "https://e.com/%s/%s", "every occurrence, optional or not")
        XCTAssertEqual(siteSearchTemplate(fromOpenSearch: "https://e.com/?q={searchTerms}&ie={inputEncoding}&oe={outputEncoding?}&hl={language}"),
                       "https://e.com/?q=%s&ie=UTF-8&oe=UTF-8&hl=*")
        XCTAssertEqual(siteSearchTemplate(fromOpenSearch: "https://e.com/?q={searchTerms}&n={count}&i={startIndex}&p={startPage}"),
                       "https://e.com/?q=%s&n=20&i=1&p=1", "required paging parameters take their first value")
        XCTAssertEqual(siteSearchTemplate(fromOpenSearch: "https://e.com/?q={searchTerms}&n={count?}&x={moz:locale?}"),
                       "https://e.com/?q=%s&n=&x=", "optional parameters Detour does not fill are empty")
        XCTAssertEqual(siteSearchTemplate(fromOpenSearch: "  https://e.com/?q={searchTerms}\n"), "https://e.com/?q=%s")
    }

    func testTemplatesThatCannotBeConvertedAreRefused() {
        XCTAssertNil(siteSearchTemplate(fromOpenSearch: "https://e.com/browse"), "no {searchTerms}")
        XCTAssertNil(siteSearchTemplate(fromOpenSearch: "https://e.com/?q={searchTerms}&b={google:baseURL}"),
                     "a required parameter Detour does not know")
        XCTAssertNil(siteSearchTemplate(fromOpenSearch: "https://e.com/?q={searchTerms}&x={whatever}"))
        XCTAssertNil(siteSearchTemplate(fromOpenSearch: "https://e.com/?q={searchTerms"), "an unclosed brace")
        XCTAssertNil(siteSearchTemplate(fromOpenSearch: "https://e.com/?q={searchTerms}}"), "a stray brace")
        XCTAssertNil(siteSearchTemplate(fromOpenSearch: "https://e.com/%s?q={searchTerms}"),
                     "a template already holding %s would get the query there too")
    }
}

nonisolated final class SiteSearchDiscoveryRuleTests: XCTestCase {

    private let page = URL(string: "https://www.example.com/docs/page")!

    func testOnlyANormalProfilesHttpPageIsLookedAt() {
        XCTAssertTrue(SiteSearchDiscovery.mayLook(at: page, isPrivate: false, isQuarantined: false))
        XCTAssertTrue(SiteSearchDiscovery.mayLook(at: URL(string: "http://127.0.0.1:8080/")!,
                                                  isPrivate: false, isQuarantined: false))
        XCTAssertFalse(SiteSearchDiscovery.mayLook(at: page, isPrivate: true, isQuarantined: false), "Private")
        XCTAssertFalse(SiteSearchDiscovery.mayLook(at: page, isPrivate: false, isQuarantined: true), "quarantine")
        XCTAssertFalse(SiteSearchDiscovery.mayLook(at: page, isPrivate: true, isQuarantined: true))
        for other in ["browser-error://x/", "detour://history", "file:///tmp/a.html", "about:blank",
                      "webkit-extension://abc/page.html", "data:text/html,hi"] {
            XCTAssertFalse(SiteSearchDiscovery.mayLook(at: URL(string: other), isPrivate: false, isQuarantined: false),
                           other)
        }
        XCTAssertFalse(SiteSearchDiscovery.mayLook(at: nil, isPrivate: false, isQuarantined: false))
    }

    func testTheDescriptionMustBeOnThePagesSite() {
        XCTAssertEqual(SiteSearchDiscovery.descriptionURL(href: "/opensearch.xml", pageURL: page)?.absoluteString,
                       "https://www.example.com/opensearch.xml", "resolved against the page")
        XCTAssertEqual(SiteSearchDiscovery.descriptionURL(href: "https://example.com/os.xml", pageURL: page)?
            .absoluteString, "https://example.com/os.xml", "www. does not count")
        XCTAssertNotNil(SiteSearchDiscovery.descriptionURL(href: "HTTPS://WWW.EXAMPLE.COM/os.xml", pageURL: page))
        XCTAssertNil(SiteSearchDiscovery.descriptionURL(href: "https://cdn.example.net/os.xml", pageURL: page),
                     "another host")
        XCTAssertNil(SiteSearchDiscovery.descriptionURL(href: "https://search.example.com/os.xml", pageURL: page),
                     "a subdomain is another host")
        XCTAssertNil(SiteSearchDiscovery.descriptionURL(href: "http://www.example.com/os.xml", pageURL: page),
                     "no https-to-http downgrade")
        XCTAssertNotNil(SiteSearchDiscovery.descriptionURL(href: "https://www.example.com/os.xml",
                                                           pageURL: URL(string: "http://www.example.com/")!),
                        "an http page may name an https description")
        XCTAssertNil(SiteSearchDiscovery.descriptionURL(href: "ftp://www.example.com/os.xml", pageURL: page))
        XCTAssertNil(SiteSearchDiscovery.descriptionURL(href: "javascript:alert(1)", pageURL: page))
        XCTAssertNil(SiteSearchDiscovery.descriptionURL(href: "https://u:p@www.example.com/os.xml", pageURL: page),
                     "no credentials")
    }

    func testTheFirstLinkOnThePagesSiteIsTheDescription() {
        XCTAssertEqual(SiteSearchDiscovery.descriptionURL(
            hrefs: ["https://cdn.other.example/os.xml", "/opensearch.xml", "/second.xml"], pageURL: page)?
            .absoluteString, "https://www.example.com/opensearch.xml", "a foreign link first does not hide it")
        XCTAssertNil(SiteSearchDiscovery.descriptionURL(hrefs: ["https://cdn.other.example/os.xml"], pageURL: page))
        XCTAssertNil(SiteSearchDiscovery.descriptionURL(hrefs: [], pageURL: page))
    }

    func testAResultsTemplateOnAnotherSiteOrSchemeIsIgnored() {
        func entry(_ template: String, name: String = "Example") -> SiteSearch? {
            SiteSearchDiscovery.entry(from: OpenSearchDescription(name: name, urlTemplate: template), pageURL: page)
        }
        let found = entry("https://www.example.com/search?q=%s")
        XCTAssertEqual(found?.name, "Example")
        XCTAssertEqual(found?.keyword, "")
        XCTAssertNotNil(entry("https://example.com/search?q=%s"), "www. does not count")
        XCTAssertNil(entry("https://evil.example.net/search?q=%s"), "another host")
        XCTAssertNil(entry("https://search.example.com/?q=%s"), "a subdomain is another host")
        XCTAssertNil(entry("http://www.example.com/search?q=%s"), "no https-to-http downgrade")
        XCTAssertNil(entry("ftp://www.example.com/%s"), "not http(s)")
        XCTAssertNil(entry("javascript:alert('%s')"))
        XCTAssertEqual(entry("https://www.example.com/search?q=%s", name: "")?.name, "example.com",
                       "a description without a name is named after the site")
    }

    func testARedirectIsFollowedOnlyWithinTheSite() {
        let start = URL(string: "https://www.example.com/os.xml")!
        XCTAssertTrue(SiteSearchDiscovery.allowsRedirect(start, URL(string: "https://example.com/opensearch.xml")!))
        XCTAssertFalse(SiteSearchDiscovery.allowsRedirect(start, URL(string: "https://other.example/os.xml")!))
        XCTAssertFalse(SiteSearchDiscovery.allowsRedirect(start, URL(string: "http://www.example.com/os.xml")!))
    }

    // MARK: Tab on a discovered entry

    func testADiscoveredEntryTakesTabOnlyWhenTheFieldIsItsSite() {
        var found = SiteSearch(name: "Stack Overflow", keyword: "",
                               urlTemplate: "https://stackoverflow.com/search?q=%s")
        found.isDiscovered = true
        let entries = [found]
        XCTAssertEqual(siteSearchForTab(typed: "stack", completedText: "stackoverflow.com", entries: entries)?.id,
                       found.id, "the field completes to the site")
        XCTAssertEqual(siteSearchForTab(typed: "stackoverflow.com", completedText: nil, entries: entries)?.id,
                       found.id, "the site typed out")
        XCTAssertNil(siteSearchForTab(typed: "stack", completedText: nil, entries: entries),
                     "not the start of its name")
        XCTAssertNil(siteSearchForTab(typed: "stackov", completedText: nil, entries: entries),
                     "nor of its host")

        var adopted = found
        adopted.isDiscovered = false
        XCTAssertEqual(siteSearchForTab(typed: "stack", completedText: nil, entries: [adopted])?.id, found.id,
                       "once the user has made it theirs, it is matched like any entry")
    }
}

nonisolated final class SiteSearchDiscoveryStoreTests: XCTestCase {

    @MainActor private func makeStore(_ queue: DatabaseQueue? = nil) throws -> SiteSearchStore {
        SiteSearchStore(database: try AppDatabase(dbQueue: queue ?? DatabaseQueue()))
    }

    private func found(_ template: String, name: String = "Docs") -> SiteSearch {
        SiteSearch(name: name, keyword: "", urlTemplate: template)
    }

    @MainActor func testADiscoveredEntryIsAddedMarkedWithoutAKeywordAndKept() throws {
        let queue = try DatabaseQueue()
        let store = try makeStore(queue)
        var withKeyword = found("https://docs.example/?q=%s")
        withKeyword.keyword = "d"
        let added = try XCTUnwrap(store.addDiscovered(withKeyword))
        XCTAssertTrue(added.isDiscovered)
        XCTAssertEqual(added.keyword, "", "discovery never sets a keyword")
        XCTAssertEqual(added.sortOrder, SiteSearch.starterSet.count, "appended")

        let reopened = try makeStore(queue)
        XCTAssertEqual(reopened.entry(withID: added.id)?.isDiscovered, true, "the mark is stored")
    }

    @MainActor func testASiteAlreadyListedIsNotAddedAgain() throws {
        let store = try makeStore()
        let count = store.entries.count
        XCTAssertFalse(store.mayDiscover(host: "youtube.com"), "a starter entry")
        XCTAssertNil(store.addDiscovered(found("https://youtube.com/results?search_query=%s", name: "YouTube")),
                     "the same site, with or without www.")
        XCTAssertNotNil(store.addDiscovered(found("https://docs.example/?q=%s")))
        XCTAssertNil(store.addDiscovered(found("https://docs.example/other?q=%s")), "discovered once")
        XCTAssertEqual(store.entries.count, count + 1)
        XCTAssertTrue(store.mayDiscover(host: "de.wikipedia.org"), "another host of a listed site is another site")
    }

    @MainActor func testASiteTheUserRemovedIsNeverAddedAgain() throws {
        let queue = try DatabaseQueue()
        let store = try makeStore(queue)
        let docs = try XCTUnwrap(store.addDiscovered(found("https://docs.example/?q=%s")))
        store.remove(id: docs.id)
        XCTAssertFalse(store.mayDiscover(host: "docs.example"))
        XCTAssertNil(store.addDiscovered(found("https://docs.example/?q=%s")))

        let youtube = try XCTUnwrap(store.entry(forKeyword: "yt"))
        store.remove(id: youtube.id)
        XCTAssertNil(store.addDiscovered(found("https://www.youtube.com/results?search_query=%s")),
                     "a removed starter entry stays removed too")

        let reopened = try makeStore(queue)
        XCTAssertFalse(reopened.mayDiscover(host: "docs.example"), "kept across launches")
        XCTAssertFalse(reopened.mayDiscover(host: "youtube.com"))
        XCTAssertNil(reopened.addDiscovered(found("https://docs.example/?q=%s")))

        XCTAssertNotNil(reopened.add(SiteSearch(name: "Docs", keyword: "dx", urlTemplate: "https://docs.example/?q=%s")),
                        "the user can still add the site by hand")
    }

    @MainActor func testEditingADiscoveredEntryMakesItTheUsers() throws {
        let store = try makeStore()
        let docs = try XCTUnwrap(store.addDiscovered(found("https://docs.example/?q=%s")))
        XCTAssertTrue(store.update(SiteSearch(id: docs.id, name: "Docs", keyword: "",
                                              urlTemplate: "https://docs.example/?q=%s")))
        XCTAssertEqual(store.entry(withID: docs.id)?.isDiscovered, true, "saving it unchanged keeps the mark")

        XCTAssertTrue(store.update(SiteSearch(id: docs.id, name: "Docs", keyword: "dd",
                                              urlTemplate: "https://docs.example/?q=%s")))
        let edited = try XCTUnwrap(store.entry(withID: docs.id))
        XCTAssertFalse(edited.isDiscovered, "given a keyword, it is the user's")
        XCTAssertEqual(edited.keyword, "dd")
        XCTAssertEqual(edited.sortOrder, docs.sortOrder)
    }

    /// An edit that moves an entry to another site removes the old site's
    /// search, so discovery does not bring it back.
    @MainActor func testMovingAnEntryToAnotherSiteRemembersTheOldSite() throws {
        let queue = try DatabaseQueue()
        let store = try makeStore(queue)
        let docs = try XCTUnwrap(store.addDiscovered(found("https://docs.example/?q=%s")))
        XCTAssertTrue(store.update(SiteSearch(id: docs.id, name: "Docs", keyword: "",
                                              urlTemplate: "https://www.docs.example/find?q=%s")))
        XCTAssertFalse(store.removedHosts.contains("docs.example"), "the same site under www. is not a move")
        XCTAssertTrue(store.update(SiteSearch(id: docs.id, name: "Other", keyword: "",
                                              urlTemplate: "https://other.example/?q=%s")))
        XCTAssertFalse(store.mayDiscover(host: "docs.example"))
        XCTAssertNil(store.addDiscovered(found("https://docs.example/?q=%s")))
        XCTAssertFalse(try makeStore(queue).mayDiscover(host: "docs.example"), "kept across launches")
    }

    /// v22 adds the mark (false for every row there) and the removed hosts to
    /// a database at v21.
    @MainActor func testMigrationV22KeepsAV21DatabasesEntries() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v21")
        try queue.write { d in
            try d.execute(sql: """
                INSERT INTO siteSearch (id, name, keyword, urlTemplate, sortOrder)
                VALUES ('\(UUID().uuidString)', 'Mine', 'mi', 'https://mine.example/?q=%s', 99)
                """)
        }
        XCTAssertFalse(try queue.read { try $0.tableExists("siteSearchRemovedHost") })

        let store = try makeStore(queue)
        XCTAssertEqual(store.entries.count, SiteSearch.starterSet.count + 1)
        XCTAssertFalse(store.entries.contains(where: \.isDiscovered))
        XCTAssertEqual(store.entry(forKeyword: "mi")?.urlTemplate, "https://mine.example/?q=%s")
        XCTAssertTrue(store.removedHosts.isEmpty)
    }
}

nonisolated final class SiteSearchDiscovererTests: XCTestCase {

    private let page = URL(string: "https://docs.example/guide")!
    private let descriptionXML = """
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <ShortName>Docs</ShortName>
          <Url type="text/html" template="https://docs.example/search?q={searchTerms}"/>
        </OpenSearchDescription>
        """

    @MainActor private final class FakeFetch {
        var requested: [URL] = []
        var body: Data?
        func fetch(_ url: URL) async -> Data? {
            requested.append(url)
            return body
        }
    }

    @MainActor private func makeDiscoverer(body: String? = nil) throws
        -> (SiteSearchDiscoverer, SiteSearchStore, FakeFetch) {
        let store = SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))
        let fake = FakeFetch()
        fake.body = (body ?? descriptionXML).data(using: .utf8)
        return (SiteSearchDiscoverer(store: store, fetch: fake.fetch), store, fake)
    }

    @MainActor func testADescriptionOnThePagesSiteAddsItsSiteSearch() async throws {
        let (discoverer, store, fake) = try makeDiscoverer()
        let added = await discoverer.discover(descriptionHrefs: ["/opensearch.xml"], pageURL: page)?.value
        XCTAssertEqual(fake.requested, [URL(string: "https://docs.example/opensearch.xml")!])
        XCTAssertEqual(added?.name, "Docs")
        XCTAssertEqual(added?.urlTemplate, "https://docs.example/search?q=%s")
        XCTAssertEqual(store.entries.last?.id, added?.id)
        XCTAssertEqual(store.entries.last?.isDiscovered, true)
    }

    @MainActor func testASiteIsFetchedAtMostOncePerLaunch() async throws {
        let (discoverer, store, fake) = try makeDiscoverer(body: "not a description")
        let count = store.entries.count
        let first = await discoverer.discover(descriptionHrefs: ["/opensearch.xml"], pageURL: page)?.value
        XCTAssertNil(first, "nothing usable")
        XCTAssertNil(discoverer.discover(descriptionHrefs: ["/opensearch.xml"], pageURL: page),
                     "not fetched again, even after a failure")
        XCTAssertNil(discoverer.discover(descriptionHrefs: ["/other.xml"],
                                         pageURL: URL(string: "https://www.docs.example/b")!),
                     "the same site under www.")
        XCTAssertEqual(fake.requested.count, 1)
        XCTAssertEqual(store.entries.count, count)
        XCTAssertEqual(discoverer.attemptedHosts, ["docs.example"])
    }

    @MainActor func testAListedOrRemovedSiteIsNotFetched() async throws {
        let (discoverer, store, fake) = try makeDiscoverer()
        XCTAssertNil(discoverer.discover(descriptionHrefs: ["/opensearch"],
                                         pageURL: URL(string: "https://www.youtube.com/")!), "listed")
        let github = try XCTUnwrap(store.entry(forKeyword: "gh"))
        store.remove(id: github.id)
        XCTAssertNil(discoverer.discover(descriptionHrefs: ["/opensearch.xml"],
                                         pageURL: URL(string: "https://github.com/")!), "removed")
        XCTAssertEqual(fake.requested, [])
        XCTAssertEqual(discoverer.attemptedHosts, [], "a site not fetched can be looked at once it may be")
    }

    @MainActor func testADescriptionOnAnotherSiteIsNotFetched() async throws {
        let (discoverer, _, fake) = try makeDiscoverer()
        XCTAssertNil(discoverer.discover(descriptionHrefs: ["https://cdn.other.example/os.xml"], pageURL: page))
        XCTAssertEqual(fake.requested, [])
    }

    @MainActor func testAResultsTemplateOnAnotherSiteIsNotAdded() async throws {
        let (discoverer, store, _) = try makeDiscoverer(body: """
            <OpenSearchDescription><ShortName>Evil</ShortName>
              <Url type="text/html" template="https://evil.example/?q={searchTerms}"/></OpenSearchDescription>
            """)
        let count = store.entries.count
        let added = await discoverer.discover(descriptionHrefs: ["/opensearch.xml"], pageURL: page)?.value
        XCTAssertNil(added)
        XCTAssertEqual(store.entries.count, count)
        XCTAssertTrue(store.mayDiscover(host: "evil.example"))
    }

    @MainActor func testASiteListedWhileTheDescriptionWasOnItsWayIsNotAddedTwice() async throws {
        let (discoverer, store, _) = try makeDiscoverer()
        let task = discoverer.discover(descriptionHrefs: ["/opensearch.xml"], pageURL: page)
        store.add(SiteSearch(name: "My Docs", keyword: "md", urlTemplate: "https://docs.example/find/%s"))
        let added = await task?.value
        XCTAssertNil(added)
        XCTAssertEqual(store.entries.filter { $0.displayHost == "docs.example" }.map(\.name), ["My Docs"])
    }
}

/// The fetcher against a real loopback server: the size and time limits, the
/// redirect rule, a failed response.
nonisolated final class OpenSearchFetcherTests: XCTestCase {

    private var server: LoopbackHTTPServer?
    private var fetcher: OpenSearchFetcher?

    @MainActor override func tearDown() async throws {
        fetcher?.invalidate()
        server?.stop()
        try await super.tearDown()
    }

    @MainActor private func start(routes: [String: String] = [:], stalled: [String: String] = [:],
                                  redirects: [String: String] = [:], timeout: TimeInterval = 10)
        async throws -> (OpenSearchFetcher, LoopbackHTTPServer, URL) {
        let server = try LoopbackHTTPServer(routes: routes, stalled: stalled, redirects: redirects)
        let port = try await server.start()
        self.server = server
        let fetcher = OpenSearchFetcher(configuration: OpenSearchFetcher.makeSessionConfiguration(timeout: timeout))
        self.fetcher = fetcher
        return (fetcher, server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    @MainActor func testADescriptionIsFetched() async throws {
        let (fetcher, _, base) = try await start(routes: ["/os.xml": "<OpenSearchDescription/>"])
        let data = await fetcher.fetch(base.appendingPathComponent("os.xml"))
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "<OpenSearchDescription/>")
    }

    @MainActor func testAnythingOverTheSizeLimitIsRefused() async throws {
        let big = String(repeating: "x", count: SiteSearchDiscovery.sizeLimit + 1)
        let (fetcher, _, base) = try await start(routes: ["/big.xml": big])
        let data = await fetcher.fetch(base.appendingPathComponent("big.xml"))
        XCTAssertNil(data)
    }

    @MainActor func testAFailedResponseGivesNothing() async throws {
        let (fetcher, _, base) = try await start()
        let data = await fetcher.fetch(base.appendingPathComponent("missing.xml"))
        XCTAssertNil(data, "a 404's body is not a description")
    }

    @MainActor func testASlowDescriptionTimesOut() async throws {
        let (fetcher, _, base) = try await start(stalled: ["/slow.xml": "<OpenSearchDescription/>"], timeout: 1)
        let started = Date()
        let data = await fetcher.fetch(base.appendingPathComponent("slow.xml"))
        XCTAssertNil(data)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "the limit, not the system's minute")
    }

    @MainActor func testARedirectIsFollowedOnlyWithinTheSite() async throws {
        let (fetcher, server, base) = try await start(
            routes: ["/os.xml": "<OpenSearchDescription/>", "/elsewhere.xml": "<OpenSearchDescription/>"],
            redirects: ["/moved": "http://127.0.0.1:{port}/os.xml", "/away": "http://localhost:{port}/elsewhere.xml"])
        let moved = await fetcher.fetch(base.appendingPathComponent("moved"))
        XCTAssertNotNil(moved, "the same host")
        let away = await fetcher.fetch(base.appendingPathComponent("away"))
        XCTAssertNil(away, "localhost is another host than 127.0.0.1")
        XCTAssertFalse(server.requestedPaths.contains("/elsewhere.xml"), "the other host is never contacted")
    }
}

/// The whole path, from a tab's load ending in a real web view: the lookup
/// in its own content world, the fetch, the entry — and none of it for a
/// Private space.
nonisolated final class SiteSearchDiscoveryTabTests: XCTestCase {

    private var tabs: [BrowserTab] = []
    private var server: LoopbackHTTPServer?
    private var fetcher: OpenSearchFetcher?

    @MainActor override func tearDown() async throws {
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        fetcher?.invalidate()
        server?.stop()
        try await super.tearDown()
    }

    private static let page = """
        <html><head><title>Fixture</title>
        <link rel="search" type="application/opensearchdescription+xml" href="http://localhost/elsewhere.xml">
        <link rel="Search" type="application/OpenSearchDescription+xml" title="Fixture" href="/opensearch.xml">
        </head><body>hello</body></html>
        """
    private static let description = """
        <?xml version="1.0"?>
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <ShortName>Fixture Search</ShortName>
          <Url type="text/html" template="http://127.0.0.1/search?q={searchTerms}"/>
        </OpenSearchDescription>
        """

    @MainActor private func makeFixture(privateSpace: Bool) async throws
        -> (TabStore, SiteSearchStore, Space, URL, LoopbackHTTPServer) {
        let server = try LoopbackHTTPServer(routes: ["/": Self.page, "/opensearch.xml": Self.description,
                                                     "/plain": "<html><head><title>Plain</title></head></html>"])
        let port = try await server.start()
        self.server = server
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()),
                             historyDB: try HistoryDatabase(dbQueue: try DatabaseQueue()))
        let siteSearches = SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))
        let fetcher = OpenSearchFetcher()
        self.fetcher = fetcher
        store.siteSearchDiscoverer = SiteSearchDiscoverer(store: siteSearches, fetch: fetcher.fetch)
        let space: Space
        if privateSpace {
            space = store.addIncognitoSpace()
        } else {
            let profile = store.addProfile(name: "Discovery")
            space = store.addSpace(name: "Discovery", emoji: "D", colorHex: "007AFF", profileID: profile.id)
        }
        return (store, siteSearches, space, URL(string: "http://127.0.0.1:\(port)/")!, server)
    }

    @MainActor func testAPageLinkingADescriptionAddsItsSiteSearch() async throws {
        let (store, siteSearches, space, base, server) = try await makeFixture(privateSpace: false)
        let tab = store.addTab(in: space)
        tabs.append(tab)
        try await loadAndWait(try XCTUnwrap(tab.webView), URLRequest(url: base))

        try await waitUntil("the discovered site search") {
            siteSearches.entries.contains { $0.isDiscovered }
        }
        let found = try XCTUnwrap(siteSearches.entries.first { $0.isDiscovered })
        XCTAssertEqual(found.name, "Fixture Search")
        XCTAssertEqual(found.keyword, "")
        XCTAssertEqual(found.urlTemplate, "http://127.0.0.1/search?q=%s")
        XCTAssertEqual(server.requestedPaths.filter { $0 == "/opensearch.xml" }.count, 1)

        try await loadAndWait(try XCTUnwrap(tab.webView), URLRequest(url: base))
        _ = try await pollUntil(timeout: 1) { false }
        XCTAssertEqual(server.requestedPaths.filter { $0 == "/opensearch.xml" }.count, 1, "once per site")
        XCTAssertEqual(siteSearches.entries.filter(\.isDiscovered).count, 1)
    }

    /// A site whose pages name no description is asked on a few pages per
    /// launch, then left alone.
    @MainActor func testASiteWithoutALinkIsAskedOnAFewPagesOnly() async throws {
        let (store, siteSearches, space, base, _) = try await makeFixture(privateSpace: false)
        let discoverer = try XCTUnwrap(store.siteSearchDiscoverer)
        let tab = store.addTab(in: space)
        tabs.append(tab)
        for _ in 0..<(SiteSearchDiscovery.pagesAskedPerSite + 2) {
            try await loadAndWait(try XCTUnwrap(tab.webView), URLRequest(url: base.appendingPathComponent("plain")))
            _ = try await pollUntil(timeout: 0.3) { false }
        }
        XCTAssertEqual(discoverer.pagesAsked["127.0.0.1"], SiteSearchDiscovery.pagesAskedPerSite)
        XCTAssertFalse(siteSearches.entries.contains(where: \.isDiscovered))
    }

    @MainActor func testAPrivatePageDiscoversNothing() async throws {
        let (store, siteSearches, space, base, server) = try await makeFixture(privateSpace: true)
        let tab = store.addTab(in: space)
        tabs.append(tab)
        let count = siteSearches.entries.count
        try await loadAndWait(try XCTUnwrap(tab.webView), URLRequest(url: base))
        _ = try await pollUntil(timeout: 1.5) { false }
        XCTAssertFalse(server.requestedPaths.contains("/opensearch.xml"), "nothing fetched for a Private page")
        XCTAssertEqual(siteSearches.entries.count, count)
    }

    /// The lookup runs in its own content world: page script cannot hide or
    /// forge the link by patching `querySelectorAll`.
    @MainActor func testTheLookupIgnoresThePagesOwnScript() async throws {
        let webView = WKWebView(frame: .zero)
        try await loadHTMLStringAndWait(webView, html: """
            <html><head><link rel="search" type="application/opensearchdescription+xml" href="/os.xml">
            <script>Document.prototype.querySelectorAll = () => [{ href: "https://evil.example/os.xml" }];</script>
            </head></html>
            """, baseURL: URL(string: "https://site.example/page")!)
        let hrefs = try await webView.evaluateJavaScript(SiteSearchDiscovery.lookupScript, in: nil,
                                                         contentWorld: SiteSearchDiscoverer.contentWorld)
        XCTAssertEqual(hrefs as? [String], ["https://site.example/os.xml"])

        try await loadHTMLStringAndWait(webView, html: "<html><head><title>none</title></head></html>",
                                        baseURL: URL(string: "https://site.example/")!)
        let none = try await webView.evaluateJavaScript(SiteSearchDiscovery.lookupScript, in: nil,
                                                        contentWorld: SiteSearchDiscoverer.contentWorld)
        XCTAssertEqual(none as? [String], [], "a page without the link names nothing")
    }
}
