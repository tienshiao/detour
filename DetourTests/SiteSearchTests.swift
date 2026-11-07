import XCTest
import GRDB
@testable import Detour

/// TASK-287: site searches — the rules (`SiteSearch`, `siteSearchProblems`),
/// the store and its migration (v21, the starter set), and where the
/// palette's site-search rows go.
nonisolated final class SiteSearchRuleTests: XCTestCase {

    private func entry(_ template: String, keyword: String = "ex", name: String = "Example") -> SiteSearch {
        SiteSearch(name: name, keyword: keyword, urlTemplate: template)
    }

    // MARK: URL building

    func testTheQueryReplacesThePlaceholderPercentEncoded() {
        let url = entry("https://search.example.com/find?q=%s").url(for: "cats & dogs")
        XCTAssertEqual(url?.absoluteString, "https://search.example.com/find?q=cats%20%26%20dogs")
    }

    func testCharactersThatWouldEndAParameterOrThePathAreEncoded() {
        let url = entry("https://search.example.com/find?q=%s&lang=en").url(for: "a=b+c/d?e#f%g")
        XCTAssertEqual(url?.absoluteString,
                       "https://search.example.com/find?q=a%3Db%2Bc%2Fd%3Fe%23f%25g&lang=en")
    }

    func testAPlaceholderInThePathWorks() {
        let url = entry("https://en.wikipedia.org/wiki/Special:Search/%s").url(for: "New York")
        XCTAssertEqual(url?.absoluteString, "https://en.wikipedia.org/wiki/Special:Search/New%20York")
    }

    func testEveryPlaceholderIsReplacedAndNonASCIIIsEncodedAsUTF8() {
        let url = entry("https://x.example/%s?q=%s").url(for: "é")
        XCTAssertEqual(url?.absoluteString, "https://x.example/%C3%A9?q=%C3%A9")
    }

    func testUnreservedCharactersStayAsTyped() {
        let url = entry("https://x.example/?q=%s").url(for: "Az09-._~")
        XCTAssertEqual(url?.absoluteString, "https://x.example/?q=Az09-._~")
    }

    // MARK: Host and keyword

    func testTheDisplayHostIsLowercasedWithoutWWW() {
        XCTAssertEqual(entry("https://WWW.YouTube.com/results?search_query=%s").displayHost, "youtube.com")
        XCTAssertEqual(entry("https://en.wikipedia.org/w?search=%s").displayHost, "en.wikipedia.org")
        XCTAssertNil(entry("not a url %s").displayHost)
    }

    func testAKeywordMatchesOnlyAsAWholeWordIgnoringCase() {
        let yt = entry("https://x.example/?q=%s", keyword: "yt")
        XCTAssertTrue(yt.matches(keyword: "yt"))
        XCTAssertTrue(yt.matches(keyword: "YT"))
        XCTAssertFalse(yt.matches(keyword: "y"))
        XCTAssertFalse(yt.matches(keyword: "ytx"))
        XCTAssertFalse(yt.matches(keyword: "yt "))
        XCTAssertFalse(yt.matches(keyword: ""))
    }

    // MARK: Problems

    func testAValidEntryHasNoProblems() {
        XCTAssertEqual(siteSearchProblems(entry("https://x.example/?q=%s"), among: []), [])
        XCTAssertEqual(siteSearchProblems(entry("http://intranet.local/find/%s"), among: []), [])
    }

    func testEachProblemIsReported() {
        XCTAssertEqual(siteSearchProblems(entry("https://x.example/?q=%s", name: "  "), among: []), [.emptyName])
        XCTAssertEqual(siteSearchProblems(entry("https://x.example/?q=%s", keyword: " "), among: []), [],
                       "the keyword is optional")
        XCTAssertEqual(siteSearchProblems(entry("https://x.example/?q=%s", keyword: "y t"), among: []),
                       [.keywordHasWhitespace])
        XCTAssertEqual(siteSearchProblems(entry("https://x.example/?q="), among: []), [.missingPlaceholder])
        XCTAssertEqual(siteSearchProblems(entry("ftp://x.example/%s"), among: []), [.invalidURL])
        XCTAssertEqual(siteSearchProblems(entry("javascript:alert(%s)"), among: []), [.invalidURL])
        XCTAssertEqual(siteSearchProblems(entry("x.example/?q=%s"), among: []), [.invalidURL])
        XCTAssertEqual(siteSearchProblems(entry(""), among: []), [.invalidURL, .missingPlaceholder])
    }

    func testADuplicateKeywordIsRefusedIgnoringCaseButAnEntryIsNotItsOwnDuplicate() {
        let existing = entry("https://a.example/?q=%s", keyword: "ex")
        var other = entry("https://b.example/?q=%s", keyword: "EX")
        XCTAssertEqual(siteSearchProblems(other, among: [existing]), [.duplicateKeyword])
        other.id = existing.id
        XCTAssertEqual(siteSearchProblems(other, among: [existing]), [], "editing an entry keeps its keyword")
    }

    func testFieldsAreCheckedAndSavedTrimmed() {
        let padded = SiteSearch(name: " Ex ", keyword: " ex ", urlTemplate: " https://x.example/?q=%s ")
        XCTAssertEqual(siteSearchProblems(padded, among: []), [])
        XCTAssertEqual(padded.normalized.name, "Ex")
        XCTAssertEqual(padded.normalized.keyword, "ex")
        XCTAssertEqual(padded.normalized.urlTemplate, "https://x.example/?q=%s")
    }

    func testTheStarterSetIsValid() {
        for (index, entry) in SiteSearch.starterSet.enumerated() {
            let others = Array(SiteSearch.starterSet.prefix(index))
            XCTAssertEqual(siteSearchProblems(entry, among: others), [], entry.name)
        }
        XCTAssertEqual(SiteSearch.starterSet.map(\.keyword), ["yt", "w", "gh", "maps", "amz", "r"])
    }

    func testEntriesWithoutAKeywordAreNotDuplicatesOfEachOther() {
        let a = entry("https://a.example/?q=%s", keyword: "")
        let b = entry("https://b.example/?q=%s", keyword: "")
        XCTAssertEqual(siteSearchProblems(b, among: [a]), [])
    }

    // MARK: Which site Tab enters

    private var tabEntries: [SiteSearch] {
        [entry("https://www.youtube.com/results?search_query=%s", keyword: "yt", name: "YouTube"),
         entry("https://en.wikipedia.org/wiki/Special:Search?search=%s", keyword: "", name: "Wikipedia"),
         entry("https://maps.google.com/?q=%s", keyword: "maps", name: "Google Maps")]
    }

    private func tab(_ typed: String, completed: String? = nil) -> String? {
        siteSearchForTab(typed: typed, completedText: completed, entries: tabEntries)?.name
    }

    func testTabTakesAKeywordFirst() {
        XCTAssertEqual(tab("yt"), "YouTube")
        XCTAssertEqual(tab("MAPS", completed: "maps.example.com"), "Google Maps",
                       "a keyword wins over the completion")
    }

    func testTabTakesTheSiteTheFieldCompletesTo() {
        XCTAssertEqual(tab("you", completed: "youtube.com"), "YouTube")
        XCTAssertEqual(tab("en.wi", completed: "en.wikipedia.org"), "Wikipedia", "an entry without a keyword")
        XCTAssertEqual(tab("youtube.com"), "YouTube", "a typed host")
        XCTAssertEqual(tab("https://www.youtube.com/"), "YouTube", "a typed address")
    }

    func testACompletionToAnotherSiteKeepsTab() {
        XCTAssertNil(tab("you", completed: "younger.example"), "Tab accepts the completion")
        XCTAssertNil(tab("goo", completed: "google.com"),
                     "Google Maps is maps.google.com, so google.com is not Maps")
        XCTAssertNil(tab("youtube.com/f", completed: "youtube.com/feed/subscriptions"),
                     "a completion to a page on the site is accepted, not taken for the site")
        XCTAssertNil(tab("https://www.youtube.com/watch?v=1"), "a typed page on the site is not the site")
    }

    func testWithNoCompletionTabTakesTheStartOfANameOrHost() {
        XCTAssertEqual(tab("wiki"), "Wikipedia")
        XCTAssertEqual(tab("Goo"), "Google Maps", "the name, ignoring case")
        XCTAssertEqual(tab("en.w"), "Wikipedia", "the host")
        XCTAssertNil(tab("w"), "one character is not enough")
        XCTAssertNil(tab("zz"))
    }

    func testTextWithWhitespaceIsNeverASite() {
        XCTAssertNil(tab("yt cats"))
        XCTAssertNil(tab(""))
    }

    // MARK: Rows

    @MainActor func testTheKeywordHintGoesRightAfterTheVerbatimRow() {
        let hint = SuggestionItem.siteSearchHint(id: UUID(), name: "YouTube", fieldText: "yt")
        let top = SuggestionItem.historyResult(url: "https://yt.example/", title: "Top", faviconURL: nil)
        let history = SuggestionItem.historyResult(url: "https://h.example/", title: "H", faviconURL: nil)
        XCTAssertEqual(PaletteRows.insertingSiteSearchHint(hint, into: [top, .searchInput(text: "yt"), history]),
                       [top, .searchInput(text: "yt"), hint, history])
        XCTAssertEqual(PaletteRows.insertingSiteSearchHint(hint, into: [.searchInput(text: "yt")]),
                       [.searchInput(text: "yt"), hint])
        XCTAssertEqual(PaletteRows.insertingSiteSearchHint(hint, into: [history]), [hint, history])
    }

    @MainActor func testSiteSearchRowsAreNotFilledAgainByURL() {
        let site = SuggestionItem.siteSearch(name: "Ex", query: "q", url: "https://x.example/?q=q")
        let filler = SuggestionItem.historyResult(url: "https://x.example/?q=q", title: "", faviconURL: nil)
        let other = SuggestionItem.historyResult(url: "https://x.example/other", title: "", faviconURL: nil)
        let rows = PaletteRows.compose(matches: [site], searchSuggestions: [], filler: [filler, other])
        XCTAssertEqual(rows, [site, other], "a recent visit to the search row's own URL is that row, not a second one")
    }
}

nonisolated final class SiteSearchStoreTests: XCTestCase {

    @MainActor private func makeDatabase(_ queue: DatabaseQueue? = nil) throws -> AppDatabase {
        try AppDatabase(dbQueue: queue ?? DatabaseQueue())
    }

    @MainActor func testANewDatabaseStartsWithTheStarterSetInOrder() throws {
        let store = SiteSearchStore(database: try makeDatabase())
        XCTAssertEqual(store.entries.map(\.keyword), SiteSearch.starterSet.map(\.keyword))
        XCTAssertEqual(store.entries.map(\.urlTemplate), SiteSearch.starterSet.map(\.urlTemplate))
        XCTAssertEqual(store.entries.map(\.sortOrder), Array(0..<SiteSearch.starterSet.count))
    }

    /// v21 adds the table, seeded with the starter set, to a database at v20;
    /// rows already there are untouched.
    @MainActor func testMigrationV21SeedsTheStarterSetIntoAV20Database() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v20")
        try queue.write { d in
            try d.execute(sql: "INSERT INTO appState (key, value) VALUES ('lastActiveSpaceID', 'x')")
        }
        XCTAssertFalse(try queue.read { try $0.tableExists("siteSearch") })

        let store = SiteSearchStore(database: try makeDatabase(queue))

        XCTAssertEqual(store.entries.map(\.name), SiteSearch.starterSet.map(\.name))
        XCTAssertEqual(Set(store.entries.map(\.id)).count, SiteSearch.starterSet.count, "each row its own id")
        let state = try queue.read {
            try String.fetchOne($0, sql: "SELECT value FROM appState WHERE key = 'lastActiveSpaceID'")
        }
        XCTAssertEqual(state, "x")
    }

    @MainActor func testADeletedStarterEntryStaysDeletedWhenTheDatabaseIsOpenedAgain() throws {
        let queue = try DatabaseQueue()
        let store = SiteSearchStore(database: try makeDatabase(queue))
        let youtube = try XCTUnwrap(store.entry(forKeyword: "yt"))
        store.remove(id: youtube.id)

        let reopened = SiteSearchStore(database: try makeDatabase(queue))
        XCTAssertNil(reopened.entry(forKeyword: "yt"), "the migration seeds once")
        XCTAssertEqual(reopened.entries.count, SiteSearch.starterSet.count - 1)
    }

    @MainActor func testAddUpdateAndRemoveWriteThrough() throws {
        let db = try makeDatabase()
        let store = SiteSearchStore(database: db)
        let added = try XCTUnwrap(store.add(SiteSearch(name: " Docs ", keyword: "docs",
                                                      urlTemplate: "https://docs.example/?q=%s")))
        XCTAssertEqual(added.name, "Docs", "saved trimmed")
        XCTAssertEqual(added.sortOrder, SiteSearch.starterSet.count, "appended")

        var edited = added
        edited.keyword = "d"
        edited.urlTemplate = "https://docs.example/search/%s"
        XCTAssertTrue(store.update(edited))

        let reloaded = SiteSearchStore(database: db)
        let docs = try XCTUnwrap(reloaded.entry(forKeyword: "D"))
        XCTAssertEqual(docs.id, added.id)
        XCTAssertEqual(docs.urlTemplate, "https://docs.example/search/%s")
        XCTAssertEqual(docs.sortOrder, added.sortOrder, "an edit keeps the entry's place")

        reloaded.remove(id: docs.id)
        XCTAssertNil(SiteSearchStore(database: db).entry(withID: docs.id))
    }

    @MainActor func testTheStoreRefusesWhatTheRulesRefuse() throws {
        let store = SiteSearchStore(database: try makeDatabase())
        let count = store.entries.count
        XCTAssertNil(store.add(SiteSearch(name: "Dup", keyword: "YT", urlTemplate: "https://d.example/?q=%s")))
        XCTAssertNil(store.add(SiteSearch(name: "No slot", keyword: "ns", urlTemplate: "https://d.example/")))
        XCTAssertEqual(store.entries.count, count)

        var youtube = try XCTUnwrap(store.entry(forKeyword: "yt"))
        youtube.keyword = "gh"
        XCTAssertFalse(store.update(youtube), "another entry has gh")
        XCTAssertEqual(store.entry(withID: youtube.id)?.keyword, "yt")
        XCTAssertFalse(store.update(SiteSearch(name: "Gone", keyword: "g", urlTemplate: "https://g.example/%s")),
                       "no such entry")
    }

    @MainActor func testEveryChangePostsTheNotification() throws {
        let store = SiteSearchStore(database: try makeDatabase())
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: SiteSearchStore.didChangeNotification,
                                                           object: store, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let added = try XCTUnwrap(store.add(SiteSearch(name: "N", keyword: "n", urlTemplate: "https://n.example/%s")))
        var edited = added
        edited.name = "M"
        store.update(edited)
        store.remove(id: added.id)
        XCTAssertEqual(posts, 3)
    }
}

nonisolated final class SiteSearchHistoryTests: XCTestCase {

    @MainActor func testSiteSearchHistoryKeepsTheSitesOwnPagesAndItsSubdomains() throws {
        let db = try HistoryDatabase(dbQueue: try DatabaseQueue())
        let space = UUID().uuidString
        db.recordVisit(url: "https://www.example.com/cats", title: "Cats on example", faviconURL: nil, spaceID: space)
        db.recordVisit(url: "https://shop.example.com/cats", title: "Cats in the shop", faviconURL: nil, spaceID: space)
        db.recordVisit(url: "https://other.test/cats", title: "Cats elsewhere", faviconURL: nil, spaceID: space)
        db.recordVisit(url: "https://notexample.com/cats", title: "Cats lookalike", faviconURL: nil, spaceID: space)

        let rows = SuggestionProvider(db: db).siteSearchHistory(for: "cats", host: "example.com",
                                                                historySpaceIDs: [space])
        let urls = Set(rows.compactMap { item -> String? in
            if case .historyResult(let url, _, _) = item { return url } else { return nil }
        })
        XCTAssertEqual(urls, ["https://www.example.com/cats", "https://shop.example.com/cats"])
        XCTAssertEqual(SuggestionProvider(db: db).siteSearchHistory(for: "cats", host: "example.com",
                                                                    historySpaceIDs: []), [],
                       "no scope (a Private window) reads no history")
        let withoutSearchRow = SuggestionProvider(db: db).siteSearchHistory(
            for: "cats", host: "example.com", historySpaceIDs: [space],
            excludingURL: "https://www.example.com/cats")
        XCTAssertEqual(withoutSearchRow, [.historyResult(url: "https://shop.example.com/cats",
                                                         title: "Cats in the shop", faviconURL: nil)],
                       "the search row's own URL is not listed again")
    }
}
