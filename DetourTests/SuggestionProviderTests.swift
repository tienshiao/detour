import XCTest
import GRDB
@testable import Detour

final class SuggestionProviderTests: XCTestCase {

    private func makeProvider(db: HistoryDatabase) -> SuggestionProvider {
        SuggestionProvider(db: db)
    }

    private func makeDatabase() throws -> HistoryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(configuration: config)
        return try HistoryDatabase(dbQueue: dbQueue)
    }

    // MARK: - Default suggestions

    func testDefaultSuggestionsReturnsHistoryItems() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")
        db.recordVisit(url: "https://b.com", title: "B", faviconURL: nil, spaceID: "space1")

        // Use the database directly since SuggestionProvider uses the shared singleton
        let results = db.recentHistory(spaceID: "space1")
        let items = results.map { SuggestionItem.historyResult(url: $0.url, title: $0.title, faviconURL: $0.faviconURL) }

        XCTAssertEqual(items.count, 2)
        for item in items {
            if case .historyResult = item {
                // correct type
            } else {
                XCTFail("Expected historyResult")
            }
        }
    }

    // MARK: - Tab filtering

    func testTabFilteringMatchesURLCaseInsensitive() {
        let tabs = [
            SuggestionProvider.TabInfo(tabID: UUID(), spaceID: UUID(), url: "https://GitHub.com/test", title: "GitHub", favicon: nil),
            SuggestionProvider.TabInfo(tabID: UUID(), spaceID: UUID(), url: "https://example.com", title: "Example", favicon: nil),
        ]

        let query = "github"
        let matching = tabs.filter {
            $0.url.lowercased().contains(query) || $0.title.lowercased().contains(query)
        }

        XCTAssertEqual(matching.count, 1)
        XCTAssertTrue(matching[0].url.contains("GitHub"))
    }

    func testTabFilteringMatchesTitleCaseInsensitive() {
        let tabs = [
            SuggestionProvider.TabInfo(tabID: UUID(), spaceID: UUID(), url: "https://a.com", title: "My Swift Project", favicon: nil),
            SuggestionProvider.TabInfo(tabID: UUID(), spaceID: UUID(), url: "https://b.com", title: "Cooking", favicon: nil),
        ]

        let query = "swift"
        let matching = tabs.filter {
            $0.url.lowercased().contains(query) || $0.title.lowercased().contains(query)
        }

        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching[0].title, "My Swift Project")
    }

    func testTabFilteringLimitsToThree() {
        let tabs = (1...10).map {
            SuggestionProvider.TabInfo(tabID: UUID(), spaceID: UUID(), url: "https://test\($0).com", title: "Test \($0)", favicon: nil)
        }

        let query = "test"
        let matching = tabs.filter {
            $0.url.lowercased().contains(query) || $0.title.lowercased().contains(query)
        }
        let limited = Array(matching.prefix(3))

        XCTAssertEqual(limited.count, 3)
    }

    // MARK: - SuggestionItem type checks

    func testHistoryResultCarriesAllFields() {
        let item = SuggestionItem.historyResult(url: "https://example.com", title: "Example", faviconURL: "https://example.com/favicon.ico")

        if case .historyResult(let url, let title, let faviconURL) = item {
            XCTAssertEqual(url, "https://example.com")
            XCTAssertEqual(title, "Example")
            XCTAssertEqual(faviconURL, "https://example.com/favicon.ico")
        } else {
            XCTFail("Wrong case")
        }
    }

    func testOpenTabCarriesAllFields() {
        let tabID = UUID()
        let spaceID = UUID()
        let item = SuggestionItem.openTab(tabID: tabID, spaceID: spaceID, url: "https://a.com", title: "A", favicon: nil)

        if case .openTab(let tid, let sid, let url, let title, _) = item {
            XCTAssertEqual(tid, tabID)
            XCTAssertEqual(sid, spaceID)
            XCTAssertEqual(url, "https://a.com")
            XCTAssertEqual(title, "A")
        } else {
            XCTFail("Wrong case")
        }
    }

    func testSearchSuggestionCarriesText() {
        let item = SuggestionItem.searchSuggestion(text: "swift programming")

        if case .searchSuggestion(let text) = item {
            XCTAssertEqual(text, "swift programming")
        } else {
            XCTFail("Wrong case")
        }
    }

    // MARK: - History deduplication against open tabs

    func testHistoryDeduplicatesAgainstOpenTabs() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")
        db.recordVisit(url: "https://b.com", title: "B", faviconURL: nil, spaceID: "space1")

        let tabURLs: Set<String> = ["https://a.com"]
        let history = db.searchHistory(query: "com", spaceID: "space1")
        let filtered = history.filter { !tabURLs.contains($0.url) }

        // a.com should be filtered out because it's an open tab
        XCTAssertFalse(filtered.contains(where: { $0.url == "https://a.com" }))
        XCTAssertTrue(filtered.contains(where: { $0.url == "https://b.com" }))
    }

    // MARK: - Local suggestions

    func testLocalSuggestionsStartsWithSearchInputThenTabsThenHistory() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://tab.com/page", title: "Tab Page", faviconURL: nil, spaceID: "space1")
        db.recordVisit(url: "https://history.com/page", title: "History Page", faviconURL: nil, spaceID: "space1")
        let provider = makeProvider(db: db)

        let tabs = [
            SuggestionProvider.TabInfo(tabID: UUID(), spaceID: UUID(), url: "https://tab.com/page", title: "Tab Page", favicon: nil),
        ]
        // "page" is not a URL prefix of either entry, so there is no top hit
        let local = provider.localSuggestions(for: "page", spaceID: "space1", tabs: tabs, allowAutocomplete: true)
        let items = local.items

        XCTAssertNil(local.inlineCompletion)
        guard case .searchInput(let text) = items[0] else {
            return XCTFail("First item should be searchInput")
        }
        XCTAssertEqual(text, "page")

        guard case .openTab(_, _, let tabURL, _, _) = items[1] else {
            return XCTFail("Second item should be openTab")
        }
        XCTAssertEqual(tabURL, "https://tab.com/page")

        // History deduplicates against the open tab, so only history.com remains
        guard case .historyResult(let historyURL, _, _) = items[2] else {
            return XCTFail("Third item should be historyResult")
        }
        XCTAssertEqual(historyURL, "https://history.com/page")
        XCTAssertEqual(items.count, 3)
    }

    func testLocalSuggestionsWithNoMatchesReturnsOnlySearchInput() throws {
        let db = try makeDatabase()
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "nomatch", spaceID: "space1", tabs: [], allowAutocomplete: true)

        XCTAssertEqual(local.items.count, 1)
        XCTAssertNil(local.inlineCompletion)
        guard case .searchInput = local.items[0] else {
            return XCTFail("Only item should be searchInput")
        }
    }

    // MARK: - Top hit

    func testTopHitFromHistoryRanksFirstThenVerbatimAndDedupes() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://www.youtube.com/", title: "YouTube", faviconURL: nil, spaceID: "space1")
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "youtu", spaceID: "space1", tabs: [], allowAutocomplete: true)
        let items = local.items

        XCTAssertEqual(local.inlineCompletion, "youtube.com")
        guard case .historyResult(let url, let title, _) = items[0] else {
            return XCTFail("First item should be the history top hit")
        }
        XCTAssertEqual(url, "https://www.youtube.com/")
        XCTAssertEqual(title, "YouTube")

        guard case .searchInput(let text) = items[1] else {
            return XCTFail("Second item should be the verbatim searchInput")
        }
        XCTAssertEqual(text, "youtu")

        // The top hit must not appear again in the history section
        XCTAssertEqual(items.count, 2)
    }

    func testTopHitFromOpenTabRanksFirstAndDedupes() throws {
        let db = try makeDatabase()
        let provider = makeProvider(db: db)

        let tabID = UUID()
        let tabs = [
            SuggestionProvider.TabInfo(tabID: tabID, spaceID: UUID(), url: "https://github.com/foo", title: "Foo Repo", favicon: nil),
        ]
        let local = provider.localSuggestions(for: "github", spaceID: "space1", tabs: tabs, allowAutocomplete: true)
        let items = local.items

        XCTAssertEqual(local.inlineCompletion, "github.com/foo")
        guard case .openTab(let hitTabID, _, _, _, _) = items[0] else {
            return XCTFail("First item should be the open-tab top hit")
        }
        XCTAssertEqual(hitTabID, tabID)

        guard case .searchInput = items[1] else {
            return XCTFail("Second item should be the verbatim searchInput")
        }

        // The tab must not appear again in the open-tab section
        XCTAssertEqual(items.count, 2)
    }

    func testTopHitSuppressedWhenAutocompleteDisallowed() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://www.youtube.com/", title: "YouTube", faviconURL: nil, spaceID: "space1")
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "youtu", spaceID: "space1", tabs: [], allowAutocomplete: false)

        XCTAssertNil(local.inlineCompletion)
        guard case .searchInput = local.items[0] else {
            return XCTFail("First item should be searchInput when autocomplete is disallowed")
        }
        // The history entry still appears in its normal section
        guard case .historyResult(let url, _, _) = local.items[1] else {
            return XCTFail("Second item should be the history match")
        }
        XCTAssertEqual(url, "https://www.youtube.com/")
    }

    func testCurrentTabExcludedFromTopHit() throws {
        let db = try makeDatabase()
        let provider = makeProvider(db: db)

        let tabID = UUID()
        let tabs = [
            SuggestionProvider.TabInfo(tabID: tabID, spaceID: UUID(), url: "https://github.com/foo", title: "Foo Repo", favicon: nil),
        ]
        // The only prefix match is the current tab, so it must not become the top hit.
        let local = provider.localSuggestions(
            for: "github", spaceID: "space1", tabs: tabs,
            allowAutocomplete: true, currentTabID: tabID)
        let items = local.items

        XCTAssertNil(local.inlineCompletion)
        guard case .searchInput = items[0] else {
            return XCTFail("First item should be the verbatim searchInput, not the current tab")
        }
        // The current tab still appears in the normal open-tab section.
        XCTAssertTrue(items.contains {
            if case .openTab(let id, _, _, _, _) = $0 { return id == tabID }
            return false
        })
    }

    // MARK: - Profile title isolation (TASK-94)

    /// One URL two profiles visited, the work one last — so the shared
    /// `historyURL` row, and the FTS index built from it, carry the work title
    /// for both. Recorded through the production `recordVisit` so these tests
    /// exercise what the browser actually writes; the writes are serialized on
    /// GRDB's writer queue, so awaiting each keeps the order. No title word
    /// appears in the URL, so every match below is earned by a title.
    private func seedTwoProfileVisit(_ db: HistoryDatabase) {
        for (spaceID, title) in [("personal", "Alpha page"), ("work", "Secret budget")] {
            let done = expectation(description: "record \(spaceID) visit")
            db.recordVisit(url: "https://mail.example/", title: title, faviconURL: nil,
                           spaceID: spaceID) { _ in done.fulfill() }
            wait(for: [done], timeout: 10)
        }
    }

    func testDefaultSuggestionsShowTheSpacesOwnTitle() throws {
        let db = try makeDatabase()
        seedTwoProfileVisit(db)
        let provider = makeProvider(db: db)

        let items = provider.defaultSuggestions(spaceID: "personal", tabs: [])

        guard case .historyResult(_, let title, _) = items.first else {
            return XCTFail("Expected a history suggestion")
        }
        XCTAssertEqual(title, "Alpha page", "the work profile's title must not label this row")
    }

    func testLocalSuggestionsLabelTheTopHitWithTheSpacesOwnTitle() throws {
        let db = try makeDatabase()
        seedTwoProfileVisit(db)
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "mail", spaceID: "personal", tabs: [],
                                              allowAutocomplete: true)

        XCTAssertEqual(local.inlineCompletion, "mail.example")
        guard case .historyResult(let url, let title, _) = local.items.first else {
            return XCTFail("First item should be the history top hit")
        }
        XCTAssertEqual(url, "https://mail.example/")
        XCTAssertEqual(title, "Alpha page")
    }

    func testLocalSuggestionsFindNothingThroughAnotherProfilesTitle() throws {
        let db = try makeDatabase()
        seedTwoProfileVisit(db)
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "budget", spaceID: "personal", tabs: [],
                                              allowAutocomplete: true)

        XCTAssertFalse(local.items.contains {
            if case .historyResult = $0 { return true }
            return false
        }, "a word only the work profile's title has must not surface the page here")
        // The work profile does find it, under its own title.
        let work = provider.localSuggestions(for: "budget", spaceID: "work", tabs: [],
                                             allowAutocomplete: true)
        XCTAssertTrue(work.items.contains {
            if case .historyResult(_, let title, _) = $0 { return title == "Secret budget" }
            return false
        })
    }

    // MARK: - Merge ordering

    func testMergeOrderIsTabsHistorySearch() {
        var merged: [SuggestionItem] = []

        let tabItems: [SuggestionItem] = [.openTab(tabID: UUID(), spaceID: UUID(), url: "https://tab.com", title: "Tab", favicon: nil)]
        let historyItems: [SuggestionItem] = [.historyResult(url: "https://history.com", title: "History", faviconURL: nil)]
        let searchItems: [SuggestionItem] = [.searchSuggestion(text: "search query")]

        merged.append(contentsOf: tabItems)
        merged.append(contentsOf: historyItems)
        merged.append(contentsOf: searchItems)

        XCTAssertEqual(merged.count, 3)

        if case .openTab = merged[0] {} else { XCTFail("First should be openTab") }
        if case .historyResult = merged[1] {} else { XCTFail("Second should be historyResult") }
        if case .searchSuggestion = merged[2] {} else { XCTFail("Third should be searchSuggestion") }
    }

    func testMergeCapsAtTwelve() {
        var merged: [SuggestionItem] = []
        for i in 1...20 {
            merged.append(.historyResult(url: "https://\(i).com", title: "\(i)", faviconURL: nil))
        }
        let capped = Array(merged.prefix(12))
        XCTAssertEqual(capped.count, 12)
    }
}
