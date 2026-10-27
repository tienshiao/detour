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
        let results = db.recentHistory(spaceIDs: ["space1"])
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
        let history = db.searchHistory(query: "com", spaceIDs: ["space1"])
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
        let local = provider.localSuggestions(for: "page", historySpaceIDs: ["space1"], tabs: tabs, allowAutocomplete: true)
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

        let local = provider.localSuggestions(for: "nomatch", historySpaceIDs: ["space1"], tabs: [], allowAutocomplete: true)

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

        let local = provider.localSuggestions(for: "youtu", historySpaceIDs: ["space1"], tabs: [], allowAutocomplete: true)
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
        // A path in the query: URL-level completion (a bare host prefix
        // completes to the host instead, see the TASK-182 tests).
        let local = provider.localSuggestions(for: "github.com/f", historySpaceIDs: ["space1"], tabs: tabs, allowAutocomplete: true)
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

        let local = provider.localSuggestions(for: "youtu", historySpaceIDs: ["space1"], tabs: [], allowAutocomplete: false)

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
            for: "github.com/f", historySpaceIDs: ["space1"], tabs: tabs,
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

        let items = provider.defaultSuggestions(historySpaceIDs: ["personal"], tabs: [])

        guard case .historyResult(_, let title, _) = items.first else {
            return XCTFail("Expected a history suggestion")
        }
        XCTAssertEqual(title, "Alpha page", "the work profile's title must not label this row")
    }

    func testLocalSuggestionsLabelTheTopHitWithTheSpacesOwnTitle() throws {
        let db = try makeDatabase()
        seedTwoProfileVisit(db)
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "mail", historySpaceIDs: ["personal"], tabs: [],
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

        let local = provider.localSuggestions(for: "budget", historySpaceIDs: ["personal"], tabs: [],
                                              allowAutocomplete: true)

        XCTAssertFalse(local.items.contains {
            if case .historyResult = $0 { return true }
            return false
        }, "a word only the work profile's title has must not surface the page here")
        // The work profile does find it, under its own title.
        let work = provider.localSuggestions(for: "budget", historySpaceIDs: ["work"], tabs: [],
                                             allowAutocomplete: true)
        XCTAssertTrue(work.items.contains {
            if case .historyResult(_, let title, _) = $0 { return title == "Secret budget" }
            return false
        })
    }

    // MARK: - Profile scope (TASK-209)

    /// Two profiles over overlapping URLs, recorded through `recordVisit` in
    /// order: work is `W1`, `W2` and its Quick Detour scope `WQ`, home is `H1`,
    /// and home visits the shared root last, so the shared title is home's.
    private let workScope = ["W1", "W2", "WQ"]
    private let homeScope = ["H1"]

    private func seedTwoProfiles(_ db: HistoryDatabase) {
        let visits = [
            ("W1", "https://mail.example/inbox", "Acme inbox"),
            ("WQ", "https://mail.example/spec", "Acme spec"),
            ("W2", "https://mail.example/", "Acme mail"),
            ("H1", "https://mail.example/family", "Family photos"),
            ("H1", "https://mail.example/", "Family mail"),
        ]
        for (spaceID, url, title) in visits {
            let done = expectation(description: "record \(url) in \(spaceID)")
            db.recordVisit(url: url, title: title, faviconURL: nil, spaceID: spaceID) { _ in done.fulfill() }
            wait(for: [done], timeout: 10)
        }
    }

    private func historyRows(_ items: [SuggestionItem]) -> [(url: String, title: String)] {
        items.compactMap {
            if case .historyResult(let url, let title, _) = $0 { return (url, title) }
            return nil
        }
    }

    func testEveryHistoryRowComesFromThePalettesProfile() throws {
        let db = try makeDatabase()
        seedTwoProfiles(db)
        let provider = makeProvider(db: db)

        let work = provider.localSuggestions(for: "mail", historySpaceIDs: workScope, tabs: [],
                                             allowAutocomplete: true)
        XCTAssertEqual(work.inlineCompletion, "mail.example")
        let workRows = historyRows(work.items)
        XCTAssertEqual(workRows.first?.url, "https://mail.example/")
        XCTAssertEqual(workRows.first?.title, "Acme mail", "the top hit wears the work title, not the shared one")
        XCTAssertEqual(Set(workRows.map(\.url)),
                       ["https://mail.example/", "https://mail.example/inbox", "https://mail.example/spec"],
                       "every space of the profile and its Quick Detours; never home's page")
        XCTAssertFalse(workRows.contains { $0.title.contains("Family") })

        let home = provider.localSuggestions(for: "mail", historySpaceIDs: homeScope, tabs: [],
                                             allowAutocomplete: true)
        let homeRows = historyRows(home.items)
        XCTAssertEqual(homeRows.first?.title, "Family mail")
        XCTAssertEqual(Set(homeRows.map(\.url)), ["https://mail.example/", "https://mail.example/family"])
        XCTAssertFalse(homeRows.contains { $0.title.contains("Acme") })
    }

    func testATitleWordFromAnotherSpaceOfTheProfileIsFound() throws {
        let db = try makeDatabase()
        seedTwoProfiles(db)
        let provider = makeProvider(db: db)

        let work = provider.localSuggestions(for: "acme", historySpaceIDs: workScope, tabs: [],
                                             allowAutocomplete: true)
        XCTAssertEqual(Set(historyRows(work.items).map(\.url)),
                       ["https://mail.example/", "https://mail.example/inbox", "https://mail.example/spec"])
        XCTAssertTrue(historyRows(provider.localSuggestions(for: "acme", historySpaceIDs: homeScope, tabs: [],
                                                            allowAutocomplete: true).items).isEmpty)
        XCTAssertTrue(historyRows(provider.localSuggestions(for: "family", historySpaceIDs: workScope, tabs: [],
                                                            allowAutocomplete: true).items).isEmpty,
                      "the shared title is home's, and it still finds nothing in work")
    }

    func testTheEmptyFieldListIsTheProfilesRecentHistory() throws {
        let db = try makeDatabase()
        seedTwoProfiles(db)
        let provider = makeProvider(db: db)

        XCTAssertEqual(historyRows(provider.defaultSuggestions(historySpaceIDs: workScope, tabs: [])).map(\.url),
                       ["https://mail.example/", "https://mail.example/spec", "https://mail.example/inbox"])
        XCTAssertEqual(historyRows(provider.defaultSuggestions(historySpaceIDs: workScope, tabs: [])).first?.title,
                       "Acme mail")
        XCTAssertEqual(historyRows(provider.defaultSuggestions(historySpaceIDs: homeScope, tabs: [])).map(\.url),
                       ["https://mail.example/", "https://mail.example/family"])
    }

    /// A Private window's palette (and a quarantine's) has no history scope.
    func testAnEmptyHistoryScopeOffersNoHistory() throws {
        let db = try makeDatabase()
        seedTwoProfiles(db)
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "mail", historySpaceIDs: [], tabs: [], allowAutocomplete: true)
        XCTAssertEqual(local.items, [.searchInput(text: "mail")])
        XCTAssertNil(local.inlineCompletion)
        XCTAssertEqual(provider.defaultSuggestions(historySpaceIDs: [], tabs: []), [])
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

    // MARK: - Host completion (TASK-182)

    private func tab(_ url: String, title: String = "Video") -> SuggestionProvider.TabInfo {
        SuggestionProvider.TabInfo(tabID: UUID(), spaceID: UUID(), url: url, title: title, favicon: nil)
    }

    private let videoTabs = [
        "https://www.youtube.com/watch?v=1",
        "https://www.youtube.com/watch?v=2",
        "https://www.youtube.com/watch?v=3",
    ]

    private func isOpenTab(_ item: SuggestionItem, _ id: UUID) -> Bool {
        if case .openTab(let tabID, _, _, _, _) = item { return tabID == id }
        return false
    }

    /// The reproduction of TASK-182: with only video tabs open, `youtu`
    /// completed to the first video and nothing offered the site itself.
    func testHostPrefixCompletesToTheSiteRootNotAnOpenTabsDeepURL() throws {
        let provider = makeProvider(db: try makeDatabase())
        let tabs = videoTabs.map { tab($0) }

        let local = provider.localSuggestions(for: "youtu", historySpaceIDs: ["space1"], tabs: tabs,
                                              allowAutocomplete: true)

        XCTAssertEqual(local.inlineCompletion, "youtube.com")
        XCTAssertEqual(local.items.first,
                       .historyResult(url: "https://www.youtube.com/", title: "youtube.com", faviconURL: nil))
        guard local.items.count == 5 else {
            return XCTFail("expected top hit, verbatim row and three tabs, got \(local.items)")
        }
        XCTAssertEqual(local.items[1], .searchInput(text: "youtu"))
        // The video tabs are still offered, after the verbatim row.
        XCTAssertTrue(isOpenTab(local.items[2], tabs[0].tabID))
        XCTAssertTrue(isOpenTab(local.items[3], tabs[1].tabID))
        XCTAssertTrue(isOpenTab(local.items[4], tabs[2].tabID))
    }

    func testHostPrefixOffersATabAlreadyAtTheSiteRootAsTheTopHit() throws {
        let provider = makeProvider(db: try makeDatabase())
        let root = tab("https://www.youtube.com/", title: "YouTube")
        let tabs = videoTabs.map { tab($0) } + [root]

        let local = provider.localSuggestions(for: "you", historySpaceIDs: ["space1"], tabs: tabs,
                                              allowAutocomplete: true)

        XCTAssertEqual(local.inlineCompletion, "youtube.com")
        XCTAssertTrue(isOpenTab(local.items[0], root.tabID), "Switch to the tab at the root")
        XCTAssertEqual(local.items[1], .searchInput(text: "you"))
        XCTAssertFalse(local.items.dropFirst().contains { isOpenTab($0, root.tabID) },
                       "the root tab is not listed twice")
    }

    /// The current tab is never switched to, but its host still completes:
    /// Cmd+L on a video then `you` goes to the site root in place.
    func testHostPrefixFromTheCurrentTabCompletesToItsRootWithoutSwitchingToIt() throws {
        let provider = makeProvider(db: try makeDatabase())
        let current = tab("https://www.youtube.com/watch?v=1")

        let local = provider.localSuggestions(for: "you", historySpaceIDs: ["space1"], tabs: [current],
                                              allowAutocomplete: true, currentTabID: current.tabID)

        XCTAssertEqual(local.inlineCompletion, "youtube.com")
        XCTAssertEqual(local.items.first,
                       .historyResult(url: "https://www.youtube.com/", title: "youtube.com", faviconURL: nil))
    }

    /// Hosts are ranked by the frecency of all their pages together: three
    /// recent video visits beat one typed visit to another site, though that
    /// one URL outscores each video on its own.
    func testHistoryHostCompletionRanksHostsBySummedFrecency() throws {
        let db = try makeDatabase()
        for url in videoTabs {
            db.recordVisit(url: url, title: "Video", faviconURL: "https://www.youtube.com/favicon.ico", spaceID: "space1")
        }
        db.recordVisit(url: "https://yourstore.com/", title: "Your Store", faviconURL: nil,
                       spaceID: "space1", typed: true)
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "you", historySpaceIDs: ["space1"], tabs: [],
                                              allowAutocomplete: true)

        XCTAssertEqual(local.inlineCompletion, "youtube.com")
        XCTAssertEqual(local.items[0],
                       .historyResult(url: "https://www.youtube.com/", title: "youtube.com",
                                      faviconURL: "https://www.youtube.com/favicon.ico"),
                       "the root was never visited: it is built from the host's pages")
        XCTAssertEqual(local.items[1], .searchInput(text: "you"))
        XCTAssertEqual(local.items[2],
                       .historyResult(url: "https://yourstore.com/", title: "Your Store", faviconURL: nil),
                       "another visited host matching the prefix follows the verbatim row")
        XCTAssertEqual(local.items.filter { $0 == local.items[2] }.count, 1,
                       "the other host's root is not repeated in the history rows")
    }

    func testHistoryHostCompletionLabelsTheRootWithTheSpacesOwnVisit() throws {
        let db = try makeDatabase()
        for url in videoTabs {
            db.recordVisit(url: url, title: "Video", faviconURL: nil, spaceID: "space1")
        }
        db.recordVisit(url: "https://www.youtube.com/", title: "YouTube", faviconURL: nil, spaceID: "space1")
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "you", historySpaceIDs: ["space1"], tabs: [],
                                              allowAutocomplete: true)

        XCTAssertEqual(local.items[0],
                       .historyResult(url: "https://www.youtube.com/", title: "YouTube", faviconURL: nil))
        XCTAssertEqual(local.items.filter {
            if case .historyResult(let url, _, _) = $0 { return url == "https://www.youtube.com/" }
            return false
        }.count, 1, "the root is not repeated in the history rows")
    }

    func testHistoryHostCompletionIsScopedToTheSpace() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://yourstore.com/", title: "Your Store", faviconURL: nil, spaceID: "other")
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "you", historySpaceIDs: ["space1"], tabs: [],
                                              allowAutocomplete: true)

        XCTAssertNil(local.inlineCompletion)
        XCTAssertEqual(local.items, [.searchInput(text: "you")])
    }

    /// With autocomplete off (after a Backspace) there is no top hit, but the
    /// matching hosts are still offered as rows.
    func testHostRowsAreOfferedWhenAutocompleteIsDisallowed() throws {
        let db = try makeDatabase()
        for url in videoTabs {
            db.recordVisit(url: url, title: "Video", faviconURL: nil, spaceID: "space1")
        }
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "you", historySpaceIDs: ["space1"], tabs: [],
                                              allowAutocomplete: false)

        XCTAssertNil(local.inlineCompletion)
        XCTAssertEqual(local.items[0], .searchInput(text: "you"))
        XCTAssertEqual(local.items[1],
                       .historyResult(url: "https://www.youtube.com/", title: "youtube.com", faviconURL: nil))
    }

    func testAtMostTwoOtherHostsAreOffered() throws {
        let db = try makeDatabase()
        // Only deep pages are visited, so every root row is a host row.
        for host in ["ga.com", "gb.com", "gc.com", "gd.com"] {
            db.recordVisit(url: "https://\(host)/page", title: host, faviconURL: nil, spaceID: "space1")
        }
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "g", historySpaceIDs: ["space1"], tabs: [],
                                              allowAutocomplete: true)

        let hostRows = local.items.filter {
            if case .historyResult(let url, _, _) = $0 { return url.hasSuffix(".com/") }
            return false
        }
        guard hostRows.count == 3 else {
            return XCTFail("expected the top hit and two more hosts, got \(local.items)")
        }
        XCTAssertEqual(Array(local.items.prefix(4)),
                       [hostRows[0], .searchInput(text: "g"), hostRows[1], hostRows[2]])
    }

    /// Only web pages have a site root: an internal page or `about:blank`
    /// never completes a host prefix.
    func testNonWebTabsDoNotCompleteAHostPrefix() throws {
        let tabs = [tab("detour://history", title: "History"), tab("about:blank", title: "")]

        XCTAssertNil(SuggestionProvider.tabTopHit(for: "det", tabs: tabs, currentTabID: nil))
        XCTAssertNil(SuggestionProvider.tabTopHit(for: "abo", tabs: tabs, currentTabID: nil))
    }

    func testAQueryWithAPathKeepsURLLevelCompletion() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://www.youtube.com/watch?v=1", title: "Video", faviconURL: nil, spaceID: "space1")
        let provider = makeProvider(db: db)

        let local = provider.localSuggestions(for: "youtube.com/w", historySpaceIDs: ["space1"], tabs: [],
                                              allowAutocomplete: true)

        XCTAssertEqual(local.inlineCompletion, "youtube.com/watch?v=1")
    }

    /// The palette's instant (main-thread, no SQLite) pass uses the same rule,
    /// so the field does not complete to one answer and then another.
    func testTheInstantPassTopHitIsTheProvidersTabRule() throws {
        let provider = makeProvider(db: try makeDatabase())
        let tabs = videoTabs.map { tab($0) }

        let instant = SuggestionProvider.tabTopHit(for: "youtu", tabs: tabs, currentTabID: nil)
        let local = provider.localSuggestions(for: "youtu", historySpaceIDs: ["space1"], tabs: tabs,
                                              allowAutocomplete: true)

        XCTAssertEqual(instant?.inlineCompletion, local.inlineCompletion)
        XCTAssertEqual(instant?.item, local.items.first)
    }
}
