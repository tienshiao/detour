import XCTest
import GRDB
@testable import Detour

/// Local servers among the palette's rows (TASK-411): the order the provider
/// gives them against open tabs and history, and what the palette's field and
/// Return do with them, including a scan that lands late.
nonisolated final class LocalServerSuggestionTests: XCTestCase {

    private static let space = "space-1"
    private static let website = LocalServer(port: 5173, isHTTPS: false, processName: "node",
                                             directory: NSHomeDirectory() + "/Projects/website", listensOnIPv4: true)
    private static let api = LocalServer(port: 3000, isHTTPS: false, processName: "node",
                                         directory: NSHomeDirectory() + "/Projects/marbi-api", listensOnIPv4: true)
    private static let secure = LocalServer(port: 8443, isHTTPS: true, processName: "caddy",
                                            directory: NSHomeDirectory() + "/Projects/secure", listensOnIPv4: true)
    private static let servers = [api, website, secure]

    @MainActor private func makeDatabase() throws -> HistoryDatabase {
        try HistoryDatabase(dbQueue: try DatabaseQueue())
    }

    @MainActor private func suggestions(_ query: String, db: HistoryDatabase, tabs: [SuggestionProvider.TabInfo] = [],
                                        servers: [LocalServer] = servers, allowAutocomplete: Bool = true,
                                        serverTopHitAllowed: Bool = true) -> SuggestionProvider.LocalSuggestions {
        SuggestionProvider(db: db).localSuggestions(
            for: query, historySpaceIDs: [Self.space], tabs: tabs, allowAutocomplete: allowAutocomplete,
            localServers: servers, serverTopHitAllowed: serverTopHitAllowed)
    }

    private func tab(_ url: String, title: String = "Tab") -> SuggestionProvider.TabInfo {
        .init(tabID: UUID(), spaceID: UUID(), url: url, title: title, favicon: nil)
    }

    private func serverRow(_ server: LocalServer, host: String = "localhost") -> SuggestionItem {
        .localServer(url: server.url(host: host), server: server)
    }

    // MARK: - Provider order

    @MainActor func testLocalInputCompletesToTheRunningServer() throws {
        let local = suggestions("localhost:51", db: try makeDatabase())
        XCTAssertEqual(local.items.first, serverRow(Self.website))
        XCTAssertEqual(local.inlineCompletion, "localhost:5173")
        XCTAssertEqual(local.items[1], .searchInput(text: "localhost:51"))
    }

    @MainActor func testTheIPv4LoopbackCompletesOnItsOwnHost() throws {
        let local = suggestions("127.0.0.1:51", db: try makeDatabase())
        XCTAssertEqual(local.items.first, serverRow(Self.website, host: "127.0.0.1"))
        XCTAssertEqual(local.inlineCompletion, "127.0.0.1:5173")
    }

    @MainActor func testAnHTTPSServerOpensOverHTTPS() throws {
        let local = suggestions("localhost:84", db: try makeDatabase())
        guard case .localServer(let url, _) = local.items.first else { return XCTFail("a server top hit") }
        XCTAssertEqual(url, "https://localhost:8443/")
    }

    @MainActor func testAnOpenTabOnTheServerWinsAndTheServerGetsNoRowOfItsOwn() throws {
        let open = tab("http://localhost:5173/", title: "Website – Dev")
        let local = suggestions("localhost:51", db: try makeDatabase(), tabs: [open])
        guard case .openTab(let tabID, _, _, _, _) = local.items.first else { return XCTFail("the tab first") }
        XCTAssertEqual(tabID, open.tabID)
        XCTAssertEqual(local.inlineCompletion, "localhost:5173")
        XCTAssertFalse(local.items.contains { if case .localServer = $0 { true } else { false } })
    }

    @MainActor func testTheRunningServerBeatsHistoryForAPortNoLongerRunning() throws {
        let db = try makeDatabase()
        // Visited often, but nothing runs on 4000 now.
        for _ in 0..<5 {
            db.recordVisit(url: "http://localhost:4000/", title: "Old project", faviconURL: nil, spaceID: Self.space)
        }
        let local = suggestions("localhost", db: db)
        XCTAssertEqual(local.items.first, serverRow(Self.api), "the lowest running port")
        XCTAssertEqual(local.inlineCompletion, "localhost:3000")
        let dead = try XCTUnwrap(local.items.firstIndex {
            if case .historyResult(let url, _, _) = $0 { url == "http://localhost:4000/" } else { false }
        }, "the old project is still offered")
        let lastServer = try XCTUnwrap(local.items.lastIndex {
            if case .localServer = $0 { true } else { false }
        })
        XCTAssertGreaterThan(dead, lastServer, "below the running servers")
    }

    @MainActor func testHistoryForAPortNothingRunsOnGoesLast() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "http://localhost:4000/admin", title: "Dashboard old", faviconURL: nil, spaceID: Self.space)
        db.recordVisit(url: "http://localhost:5173/admin", title: "Dashboard live", faviconURL: nil, spaceID: Self.space)
        db.recordVisit(url: "https://example.com/admin", title: "Dashboard remote", faviconURL: nil, spaceID: Self.space)
        let titles = suggestions("dashboard", db: db, allowAutocomplete: false).items.compactMap {
            if case .historyResult(_, let title, _) = $0 { title } else { nil }
        }
        XCTAssertEqual(titles.last, "Dashboard old")
        XCTAssertEqual(Set(titles.prefix(2)), ["Dashboard live", "Dashboard remote"])
    }

    @MainActor func testAPortSomethingElseListensOnIsNotDemoted() throws {
        let db = try makeDatabase()
        // A Docker container's forward: listening, though not offered.
        db.recordVisit(url: "http://localhost:3300/admin", title: "Dashboard container", faviconURL: nil,
                       spaceID: Self.space)
        db.recordVisit(url: "https://example.com/admin", title: "Dashboard remote", faviconURL: nil, spaceID: Self.space)
        let titles = SuggestionProvider(db: db).localSuggestions(
            for: "dashboard", historySpaceIDs: [Self.space], tabs: [], allowAutocomplete: false,
            localServers: [Self.api], listeningPorts: [3000, 3300]).items.compactMap {
                if case .historyResult(_, let title, _) = $0 { title } else { nil }
            }
        let demoted = SuggestionProvider(db: db).localSuggestions(
            for: "dashboard", historySpaceIDs: [Self.space], tabs: [], allowAutocomplete: false,
            localServers: [Self.api], listeningPorts: [3000]).items.compactMap {
                if case .historyResult(_, let title, _) = $0 { title } else { nil }
            }
        XCTAssertEqual(demoted.last, "Dashboard container", "nothing listens on 3300: demoted")
        XCTAssertEqual(Set(titles), ["Dashboard container", "Dashboard remote"])
        XCTAssertEqual(SuggestionProvider(db: db).localSuggestions(
            for: "dashboard", historySpaceIDs: [Self.space], tabs: [], allowAutocomplete: false,
            localServers: [Self.api], listeningPorts: [3000, 3300]).items,
                       SuggestionProvider(db: db).localSuggestions(
            for: "dashboard", historySpaceIDs: [Self.space], tabs: [], allowAutocomplete: false).items,
                       "listening on 3300: ranked as with no servers known at all")
    }

    @MainActor func testWithNoServersKnownNothingIsDemoted() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "http://localhost:4000/admin", title: "Dashboard old", faviconURL: nil, spaceID: Self.space)
        db.recordVisit(url: "https://example.com/admin", title: "Dashboard remote", faviconURL: nil, spaceID: Self.space)
        // No server is known on 4000 or anywhere: the old project keeps its place.
        let without = suggestions("dashboard", db: db, servers: [], allowAutocomplete: false).items
        let ranked = suggestions("dashboard", db: db, servers: [Self.api], allowAutocomplete: false).items
        XCTAssertEqual(without.count, 3)
        XCTAssertEqual(ranked.count, 3)
        guard case .historyResult(let last, _, _) = ranked.last else { return XCTFail("history rows") }
        XCTAssertEqual(last, "http://localhost:4000/admin", "demoted once servers are known")
    }

    @MainActor func testAHistoryRowOnTheServerStandsForIt() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "http://localhost:5173/docs", title: "Docs", faviconURL: nil, spaceID: Self.space)
        let local = suggestions("51", db: db)
        XCTAssertEqual(local.items.first, .searchInput(text: "51"))
        XCTAssertFalse(local.items.contains(serverRow(Self.website)), "the docs row covers the port")
    }

    @MainActor func testABarePortListsTheServerAfterTheVerbatimRow() throws {
        let local = suggestions("51", db: try makeDatabase())
        XCTAssertEqual(local.items.prefix(2), [.searchInput(text: "51"), serverRow(Self.website)])
        XCTAssertNil(local.inlineCompletion)
    }

    @MainActor func testZeroAddressListsLocalhostRows() throws {
        let local = suggestions("0.0.0.0:51", db: try makeDatabase())
        XCTAssertEqual(local.items.prefix(2), [.searchInput(text: "0.0.0.0:51"), serverRow(Self.website)])
    }

    @MainActor func testAFolderNameListsTheServerAfterTheVerbatimRow() throws {
        let local = suggestions("website", db: try makeDatabase())
        XCTAssertEqual(local.items.prefix(2), [.searchInput(text: "website"), serverRow(Self.website)])
        XCTAssertNil(local.inlineCompletion)
    }

    @MainActor func testAFolderNameFindsTheServersOpenTabWhateverItsTitle() throws {
        let open = tab("http://localhost:5173/dashboard", title: "Untitled")
        let other = tab("http://localhost:3000/", title: "Untitled")
        let local = suggestions("website", db: try makeDatabase(), tabs: [open, other])
        let tabIDs = local.items.compactMap { if case .openTab(let id, _, _, _, _) = $0 { id } else { nil } }
        XCTAssertEqual(tabIDs, [open.tabID])
        XCTAssertFalse(local.items.contains(serverRow(Self.website)), "the tab stands for the server")
    }

    @MainActor func testAServerMayNotTakeTheTopHitOnceTheFieldCompletedElsewhere() throws {
        let local = suggestions("localhost:51", db: try makeDatabase(), serverTopHitAllowed: false)
        XCTAssertEqual(local.items.prefix(2), [.searchInput(text: "localhost:51"), serverRow(Self.website)])
        XCTAssertNil(local.inlineCompletion)
    }

    @MainActor func testWithoutAutocompleteTheServerIsARowAfterTheVerbatimOne() throws {
        let local = suggestions("localhost:51", db: try makeDatabase(), allowAutocomplete: false)
        XCTAssertEqual(local.items.prefix(2), [.searchInput(text: "localhost:51"), serverRow(Self.website)])
    }

    @MainActor func testTheInstantPassTopHitIsTheProvidersServerRule() throws {
        let match = LocalServerRules.match("localhost:51", servers: Self.servers)
        let instant = try XCTUnwrap(SuggestionProvider.serverTopHit(for: match))
        let local = suggestions("localhost:51", db: try makeDatabase())
        XCTAssertEqual(instant.item, local.items.first)
        XCTAssertEqual(instant.inlineCompletion, local.inlineCompletion)
        XCTAssertNil(SuggestionProvider.serverTopHit(for: LocalServerRules.match("51", servers: Self.servers)))
        XCTAssertNil(SuggestionProvider.serverTopHit(for: LocalServerRules.match("website", servers: Self.servers)))
    }

    /// A history row on the server's port stands for it only when it makes
    /// the list: one the cap cuts must not take the server's row with it.
    func testAHistoryRowCutFromTheListDoesNotStandForTheServer() {
        let match = LocalServerRules.match("website", servers: Self.servers)
        let others = (1...7).map { "https://example.com/\($0)" }
        let row = serverRow(Self.website)
        // Eight rows before history leave room for three history rows with
        // the server's row listed.
        XCTAssertEqual(SuggestionProvider.serverRows(
            for: match, coveredURLs: [], historyURLs: others + ["http://localhost:5173/docs"],
            rowsBeforeHistory: 8), [row], "the eighth history row is cut")
        XCTAssertEqual(SuggestionProvider.serverRows(
            for: match, coveredURLs: [], historyURLs: Array(others.prefix(2)) + ["http://localhost:5173/docs"],
            rowsBeforeHistory: 8), [], "the third is listed")
        XCTAssertEqual(SuggestionProvider.serverRows(
            for: match, coveredURLs: [], historyURLs: ["http://localhost:5173/docs"],
            rowsBeforeHistory: 1), [])
    }

    @MainActor func testFillerDoesNotRepeatAServerRow() {
        let row = SuggestionItem.localServer(url: "http://localhost:5173/", server: Self.website)
        let filler = SuggestionItem.historyResult(url: "http://localhost:5173/", title: "Website", faviconURL: nil)
        let rows = PaletteRows.compose(matches: [.searchInput(text: "51"), row], searchSuggestions: [],
                                       filler: [filler])
        XCTAssertEqual(rows, [.searchInput(text: "51"), row])
    }

    // MARK: - The palette

    @MainActor private final class Spy: CommandPaletteDelegate {
        var inputs: [String] = []
        func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) { inputs.append(input) }
        func commandPalette(_ palette: CommandPaletteView, didSubmitSiteSearch url: URL) {}
        func commandPaletteDidDismiss(_ palette: CommandPaletteView) {}
    }

    private nonisolated struct FixedScanner: LocalServerScanning {
        let servers: [LocalServer]
        func scan() async -> LocalServerScan { LocalServerScan(servers: servers) }
    }

    private var window: NSWindow?
    private var spy = Spy()

    @MainActor override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    /// A palette as Cmd+T shows it, over an empty history and no site
    /// searches, reading servers from `directory` (none when nil).
    @MainActor private func showPalette(directory: LocalServerDirectory?,
                                        db: HistoryDatabase? = nil) throws -> CommandPaletteView {
        let siteSearches = SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))
        for entry in siteSearches.entries { siteSearches.remove(id: entry.id) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        self.window = window
        let palette = CommandPaletteView()
        palette.siteSearches = siteSearches
        palette.suggestionProvider = SuggestionProvider(db: try db ?? makeDatabase())
        palette.historySpaceIDs = [Self.space]
        palette.localServerDirectory = directory
        palette.delegate = spy
        palette.show(in: try XCTUnwrap(window.contentView))
        return palette
    }

    @MainActor private func showPaletteWithServers() throws -> CommandPaletteView {
        let palette = try showPalette(directory: LocalServerDirectory(scanner: FixedScanner(servers: Self.servers)))
        waitUntil("the scan landed") { palette.localServers == Self.servers }
        return palette
    }

    @MainActor private func editor() throws -> NSTextView {
        try XCTUnwrap(window?.firstResponder as? NSTextView, "the palette's field is being edited")
    }

    @MainActor private func type(_ text: String) throws {
        let editor = try editor()
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    @MainActor private func pressReturn() throws {
        try editor().doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    @MainActor private func pressDown() throws {
        try editor().doCommand(by: #selector(NSResponder.moveDown(_:)))
    }

    @MainActor private func waitUntil(_ what: String, _ condition: () -> Bool,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    /// Lets the background pass land.
    @MainActor private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    @MainActor func testTypingAPortPrefixCompletesTheFieldAndReturnOpensTheServer() throws {
        let palette = try showPaletteWithServers()
        try type("localhost:51")
        XCTAssertEqual(palette.suggestions.first, serverRow(Self.website), "in the instant pass already")
        XCTAssertEqual(try editor().string, "localhost:5173")
        settle()
        XCTAssertEqual(palette.suggestions.first, serverRow(Self.website), "the background pass agrees")
        try pressReturn()
        XCTAssertEqual(spy.inputs, ["http://localhost:5173/"])
    }

    @MainActor func testReturnOnABarePortStillSubmitsTheText() throws {
        let palette = try showPaletteWithServers()
        try type("51")
        settle()
        XCTAssertEqual(palette.suggestions.prefix(2), [.searchInput(text: "51"), serverRow(Self.website)])
        XCTAssertEqual(try editor().string, "51", "nothing completed")
        try pressReturn()
        XCTAssertEqual(spy.inputs, ["51"])
    }

    @MainActor func testReturnOnAFolderNameStillSubmitsTheTextAndDownReturnOpensTheServer() throws {
        let palette = try showPaletteWithServers()
        try type("website")
        settle()
        XCTAssertEqual(palette.suggestions.prefix(2), [.searchInput(text: "website"), serverRow(Self.website)])
        try pressReturn()
        XCTAssertEqual(spy.inputs, ["website"])
        try pressDown()
        try pressReturn()
        XCTAssertEqual(spy.inputs, ["website", "http://localhost:5173/"])
    }

    @MainActor func testRowsOnARunningServerKnowItsFolder() throws {
        let palette = try showPaletteWithServers()
        XCTAssertEqual(palette.localServerFolder(for: "http://localhost:5173/docs"), "website")
        XCTAssertEqual(palette.localServerFolder(for: "http://127.0.0.1:3000/"), "marbi-api")
        XCTAssertNil(palette.localServerFolder(for: "http://localhost:4000/"), "nothing runs there")
        XCTAssertNil(palette.localServerFolder(for: "https://example.com:5173/"))
    }

    @MainActor func testAPaletteWithoutADirectoryOffersNoServers() throws {
        let palette = try showPalette(directory: nil)
        try type("localhost:51")
        settle()
        XCTAssertEqual(palette.suggestions.first, .searchInput(text: "localhost:51"))
        XCTAssertFalse(palette.suggestions.contains { if case .localServer = $0 { true } else { false } })
    }

    @MainActor func testAScanThatLandsLateTakesTheTopHitWhileTheFieldIsUntouched() throws {
        let palette = try showPalette(directory: nil)
        try type("localhost:51")
        settle()
        XCTAssertEqual(palette.suggestions.first, .searchInput(text: "localhost:51"))
        palette.localServersDidArrive(LocalServerScan(servers: Self.servers))
        waitUntil("the server row") { palette.suggestions.first == serverRow(Self.website) }
        XCTAssertEqual(try editor().string, "localhost:5173")
        XCTAssertEqual(palette.localServerFolder(for: "http://localhost:5173/"), "website")
    }

    @MainActor func testAScanThatLandsAfterTheFieldCompletedToAServerKeepsTheFieldAndTheTopRowTogether() throws {
        let palette = try showPaletteWithServers()
        try type("localhost:51")
        settle()
        XCTAssertEqual(try editor().string, "localhost:5173")
        palette.localServersDidArrive(LocalServerScan(servers: Self.servers, listeningPorts: [3000, 5173, 8443, 9000]))
        settle()
        XCTAssertEqual(palette.suggestions.first, serverRow(Self.website), "another port listening keeps the server")
        XCTAssertEqual(try editor().string, "localhost:5173")
        palette.localServersDidArrive(LocalServerScan(servers: [Self.api, Self.secure]))
        settle()
        XCTAssertEqual(palette.suggestions.first, .searchInput(text: "localhost:51"))
        XCTAssertEqual(try editor().string, "localhost:51", "the completion went with the stopped server's row")
        try pressReturn()
        XCTAssertEqual(spy.inputs, ["localhost:51"])
    }

    @MainActor func testAScanThatLandsAfterTheUserArrowedChangesNoRowAboveTheSelection() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "http://localhost:5173/docs", title: "Docs", faviconURL: nil, spaceID: Self.space)
        let palette = try showPalette(directory: nil, db: db)
        try type("localhost:5")
        settle()
        let before = palette.suggestions
        XCTAssertGreaterThanOrEqual(before.count, 2)
        try pressDown()
        try pressDown()
        let field = try editor().string
        palette.localServersDidArrive(LocalServerScan(servers: Self.servers))
        settle()
        XCTAssertEqual(Array(palette.suggestions.prefix(2)), Array(before.prefix(2)),
                       "the rows up to the selection stay")
        XCTAssertEqual(try editor().string, field, "the field keeps the selected row's text")
        XCTAssertEqual(palette.localServerFolder(for: "http://localhost:5173/docs"), "website",
                       "but the folder is known")
    }
}
