import XCTest
import GRDB
@testable import Detour

/// TASK-287: site-search mode in a real `CommandPaletteView`, driven the way
/// the field editor drives it (`insertText` for typing, `doCommand(by:)` for
/// Return, Tab, Backspace and the arrows, `cancelOperation` for Escape).
nonisolated final class SiteSearchPaletteTests: XCTestCase {

    @MainActor private final class SpyDelegate: CommandPaletteDelegate {
        enum Event: Equatable {
            case input(String)
            case search(String)
            case siteSearch(String)
            case dismissed
        }
        private(set) var events: [Event] = []

        func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) {
            events.append(.input(input))
        }
        func commandPalette(_ palette: CommandPaletteView, didSubmitSearch query: String) {
            events.append(.search(query))
        }
        func commandPalette(_ palette: CommandPaletteView, didSubmitSiteSearch url: URL) {
            events.append(.siteSearch(url.absoluteString))
        }
        func commandPaletteDidDismiss(_ palette: CommandPaletteView) {
            events.append(.dismissed)
        }
    }

    private var window: NSWindow?
    private var palette: CommandPaletteView?
    private var spy = SpyDelegate()
    private var spaceID = UUID().uuidString

    @MainActor override func tearDown() async throws {
        palette?.delegate = nil
        palette?.dismiss()
        palette = nil
        window?.close()
        window = nil
        try await super.tearDown()
    }

    /// A palette whose site searches are Example (`ex`), Wiki (`wi`) and
    /// Videos (no keyword) only,
    /// over a history that knows `visited`. `historyScope: false` is a Private
    /// window's palette: no history at all.
    @MainActor private func showPalette(visited: [(url: String, title: String)] = [],
                                        historyScope: Bool = true) throws -> CommandPaletteView {
        let store = SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))
        for entry in store.entries { store.remove(id: entry.id) }
        XCTAssertNotNil(store.add(SiteSearch(name: "Example", keyword: "ex",
                                             urlTemplate: "https://search.example.com/find?q=%s")))
        XCTAssertNotNil(store.add(SiteSearch(name: "Wiki", keyword: "wi",
                                             urlTemplate: "https://wiki.example.org/search/%s")))
        XCTAssertNotNil(store.add(SiteSearch(name: "Videos", keyword: "",
                                             urlTemplate: "https://videos.example.net/search?q=%s")))

        let db = try HistoryDatabase(dbQueue: try DatabaseQueue())
        for page in visited {
            db.recordVisit(url: page.url, title: page.title, faviconURL: nil, spaceID: spaceID)
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        self.window = window

        let palette = CommandPaletteView()
        palette.siteSearches = store
        palette.suggestionProvider = SuggestionProvider(db: db)
        palette.historySpaceIDs = historyScope ? [spaceID] : []
        palette.delegate = spy
        self.palette = palette
        palette.show(in: try XCTUnwrap(window.contentView))
        return palette
    }

    @MainActor private func fieldEditor() throws -> NSTextView {
        try XCTUnwrap(window?.firstResponder as? NSTextView, "the palette's field is being edited")
    }

    @MainActor private func type(_ text: String) throws {
        let editor = try fieldEditor()
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    @MainActor private func press(_ command: Selector) throws {
        try fieldEditor().doCommand(by: command)
    }

    @MainActor private func pressReturn() throws { try press(#selector(NSResponder.insertNewline(_:))) }
    @MainActor private func pressTab() throws { try press(#selector(NSResponder.insertTab(_:))) }
    @MainActor private func pressBackspace() throws { try press(#selector(NSResponder.deleteBackward(_:))) }
    @MainActor private func pressDown() throws { try press(#selector(NSResponder.moveDown(_:))) }

    /// Spins the run loop until `condition` holds (a background history pass).
    @MainActor private func wait(until condition: () -> Bool, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    // MARK: - Entering

    @MainActor func testKeywordThenSpaceEntersTheSiteSearchAndReturnOpensItsResults() throws {
        let palette = try showPalette()

        try type("ex ")
        XCTAssertEqual(palette.activeSiteSearch?.name, "Example")
        XCTAssertEqual(try fieldEditor().string, "", "the field holds only the query")

        try type("cats & dogs")
        try pressReturn()
        XCTAssertEqual(spy.events, [.siteSearch("https://search.example.com/find?q=cats%20%26%20dogs")])
    }

    @MainActor func testKeywordThenTabEntersTheSiteSearch() throws {
        let palette = try showPalette()

        try type("WI")
        try pressTab()
        XCTAssertEqual(palette.activeSiteSearch?.name, "Wiki", "keywords match ignoring case")

        try type("New York")
        try pressReturn()
        XCTAssertEqual(spy.events, [.siteSearch("https://wiki.example.org/search/New%20York")])
    }

    /// `wi` inline-completes to a visited host; Tab enters the site search
    /// rather than accepting the completion, as in Chrome.
    @MainActor func testTabOnAKeywordWinsOverTheInlineCompletion() throws {
        let palette = try showPalette(visited: [("https://wiki.example.org/", "Wiki home")])

        try type("wi")
        let editor = try fieldEditor()
        wait(until: { editor.string == "wiki.example.org" }, "the history pass completes the field")
        try pressTab()
        XCTAssertEqual(palette.activeSiteSearch?.name, "Wiki")
        XCTAssertEqual(editor.string, "")
    }

    /// Space after a keyword the field completed (`wi` → `wi|ki.example.org`)
    /// replaces the completion, so it still enters the site search.
    @MainActor func testSpaceOverAnInlineCompletionStillEntersTheSiteSearch() throws {
        let palette = try showPalette(visited: [("https://wiki.example.org/", "Wiki home")])

        try type("wi")
        let editor = try fieldEditor()
        wait(until: { editor.string == "wiki.example.org" }, "the history pass completes the field")
        try type(" ")
        XCTAssertEqual(palette.activeSiteSearch?.name, "Wiki")
    }

    @MainActor func testReturnSearchesTheEntryAsSettingsLastSavedIt() throws {
        let palette = try showPalette()

        try type("ex ")
        try type("cats")
        var edited = try XCTUnwrap(palette.siteSearches.entry(forKeyword: "ex"))
        edited.urlTemplate = "https://new.example.com/?q=%s"
        XCTAssertTrue(palette.siteSearches.update(edited))
        try pressReturn()
        XCTAssertEqual(spy.events, [.siteSearch("https://new.example.com/?q=cats")],
                       "the selected search row does not keep the address it was built with")
    }

    @MainActor func testWordsThatAreNotAWholeKeywordStayNormalInput() throws {
        let palette = try showPalette()

        try type("exa ")
        XCTAssertNil(palette.activeSiteSearch, "a longer word")

        palette.switchToCentered()  // clears the field
        try type("e")
        try pressTab()
        XCTAssertNil(palette.activeSiteSearch, "a shorter word")

        palette.switchToCentered()
        try type("cat ex ")
        XCTAssertNil(palette.activeSiteSearch, "the keyword later in a phrase")
        XCTAssertEqual(try fieldEditor().string, "cat ex ")

        palette.switchToCentered()
        try type("zz ")
        XCTAssertNil(palette.activeSiteSearch, "no such keyword")
        try type("top")
        try pressReturn()
        XCTAssertEqual(spy.events, [.input("zz top")], "submitted as normal input")
    }

    @MainActor func testSwitchingToANewTabPaletteLeavesTheSiteSearch() throws {
        let palette = try showPalette()

        try type("ex ")
        palette.switchToCentered()
        XCTAssertNil(palette.activeSiteSearch)
        try type("cats")
        try pressReturn()
        XCTAssertEqual(spy.events, [.input("cats")])
    }

    // MARK: - Without a keyword (Arc)

    /// `vi` completes to a visited host that is a site search's: Tab searches
    /// it, and the row before it says so.
    @MainActor func testTabOnACompletedSiteHostEntersItsSearch() throws {
        let palette = try showPalette(visited: [("https://videos.example.net/", "Videos home")])

        try type("vi")
        let editor = try fieldEditor()
        wait(until: { editor.string == "videos.example.net" }, "the history pass completes the field")
        XCTAssertTrue(palette.suggestions.contains(.siteSearchHint(
            id: try XCTUnwrap(palette.siteSearches.entries.first { $0.name == "Videos" }).id,
            name: "Videos", fieldText: "videos.example.net")))
        try pressTab()
        XCTAssertEqual(palette.activeSiteSearch?.name, "Videos")

        try type("cats")
        try pressReturn()
        XCTAssertEqual(spy.events, [.siteSearch("https://videos.example.net/search?q=cats")])
    }

    @MainActor func testTabOnTheStartOfASiteNameEntersItsSearchWithNoHistory() throws {
        let palette = try showPalette()

        try type("vid")
        try pressTab()
        XCTAssertEqual(palette.activeSiteSearch?.name, "Videos")
    }

    @MainActor func testTabOnACompletionToAnotherSiteStillAcceptsIt() throws {
        let palette = try showPalette(visited: [("https://vintage.example/", "Vintage")])

        try type("vin")
        let editor = try fieldEditor()
        wait(until: { editor.string == "vintage.example" }, "the history pass completes the field")
        try pressTab()
        XCTAssertNil(palette.activeSiteSearch)
        XCTAssertEqual(editor.string, "vintage.example", "the completion is accepted")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 15, length: 0))
    }

    /// Arrowing drops the inline completion, which would leave `vi` a prefix
    /// of Videos: the row must not appear under the selection, nor Tab take it.
    @MainActor func testArrowingKeepsTheSiteRowAsTheCompletionLeftIt() throws {
        let palette = try showPalette(visited: [("https://vintage.example/", "Vintage")])
        let isHint: (SuggestionItem) -> Bool = { if case .siteSearchHint = $0 { true } else { false } }

        try type("vi")
        let editor = try fieldEditor()
        wait(until: { editor.string == "vintage.example" }, "the history pass completes the field")
        XCTAssertFalse(palette.suggestions.contains(where: isHint))
        try pressDown()
        XCTAssertFalse(palette.suggestions.contains(where: isHint), "no row comes in under the selection")
        try pressTab()
        XCTAssertNil(palette.activeSiteSearch, "Tab does what the rows said")
    }

    @MainActor func testBackspacePutsBackTheHostTheSearchWasEnteredFrom() throws {
        let palette = try showPalette(visited: [("https://videos.example.net/", "Videos home")])

        try type("vi")
        let editor = try fieldEditor()
        wait(until: { editor.string == "videos.example.net" }, "the history pass completes the field")
        try pressTab()
        try pressBackspace()
        XCTAssertNil(palette.activeSiteSearch)
        XCTAssertEqual(editor.string, "videos.example.net")
        try pressTab()
        XCTAssertEqual(palette.activeSiteSearch?.name, "Videos", "Tab enters it again")
    }

    @MainActor func testSpaceAfterAHostOrNameIsASpace() throws {
        let palette = try showPalette()

        try type("vid ")
        XCTAssertNil(palette.activeSiteSearch, "Space enters only a keyword's search")
        XCTAssertEqual(try fieldEditor().string, "vid ")
    }

    // MARK: - The keyword row

    @MainActor func testAKeywordShowsARowThatEntersTheSiteSearch() throws {
        let palette = try showPalette()

        try type("ex")
        XCTAssertNil(palette.activeSiteSearch)
        // Row 0 is the verbatim "ex", selected; the keyword row is next.
        XCTAssertEqual(palette.suggestions.prefix(2).last,
                       .siteSearchHint(id: try XCTUnwrap(palette.siteSearches.entry(forKeyword: "ex")).id,
                                       name: "Example", fieldText: "ex"))
        try pressDown()
        XCTAssertEqual(try fieldEditor().string, "ex", "the keyword row shows its keyword")
        try pressReturn()
        XCTAssertEqual(palette.activeSiteSearch?.name, "Example")
        XCTAssertEqual(spy.events, [], "choosing the row submits nothing")
    }

    @MainActor func testReturnOnABareKeywordStillSubmitsItAsTyped() throws {
        _ = try showPalette()

        try type("ex")
        try pressReturn()
        XCTAssertEqual(spy.events, [.input("ex")], "the keyword row does not take the top place")
    }

    // MARK: - Leaving

    @MainActor func testBackspaceOnAnEmptyQueryLeavesWithTheKeywordInTheField() throws {
        let palette = try showPalette()

        try type("ex ")
        try pressBackspace()
        XCTAssertNil(palette.activeSiteSearch)
        XCTAssertEqual(try fieldEditor().string, "ex")

        // The space typed now is a space: the user just declined the site search.
        try type(" cats")
        XCTAssertNil(palette.activeSiteSearch)
        try pressReturn()
        XCTAssertEqual(spy.events, [.input("ex cats")])
    }

    @MainActor func testBackspaceAtTheStartOfAQueryKeepsTheQueryAfterTheKeyword() throws {
        let palette = try showPalette()

        try type("ex ")
        try type("cats")
        let editor = try fieldEditor()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try pressBackspace()
        XCTAssertNil(palette.activeSiteSearch)
        XCTAssertEqual(editor.string, "ex cats")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0), "the caret is after the keyword")
    }

    @MainActor func testBackspaceInsideTheQueryDeletesACharacter() throws {
        let palette = try showPalette()

        try type("ex ")
        try type("cats")
        try pressBackspace()
        XCTAssertEqual(palette.activeSiteSearch?.name, "Example")
        XCTAssertEqual(try fieldEditor().string, "cat")
    }

    @MainActor func testDeletingBackToAKeywordAndASpaceDoesNotEnterTheSiteSearch() throws {
        let palette = try showPalette()

        try type("cats")
        let editor = try fieldEditor()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try type("ex ")
        XCTAssertEqual(editor.string, "ex cats")
        XCTAssertNil(palette.activeSiteSearch)
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        try pressBackspace()
        XCTAssertEqual(editor.string, "ex ")
        XCTAssertNil(palette.activeSiteSearch, "deleting the rest is not typing the space")
    }

    @MainActor func testADeclinedKeywordIsOfferedAgainOnceTheFieldHoldsAnotherWord() throws {
        let palette = try showPalette()

        try type("ex ")
        try pressBackspace()  // declines: "ex"
        try type("a")  // "exa"
        try pressBackspace()  // "ex" again
        try type(" ")
        XCTAssertEqual(palette.activeSiteSearch?.name, "Example",
                       "`exa` was another word, so the keyword is no longer declined")
    }

    @MainActor func testTabEntersTheSiteSearchTheKeywordRowOffersAfterALeadingSpace() throws {
        let palette = try showPalette()

        try type(" ex")
        XCTAssertTrue(palette.suggestions.contains { if case .siteSearchHint = $0 { true } else { false } })
        try pressTab()
        XCTAssertEqual(palette.activeSiteSearch?.name, "Example")
    }

    @MainActor func testEscapeLeavesTheSiteSearchAndClearsTheField() throws {
        let palette = try showPalette()

        try type("ex ")
        try type("cats")
        try fieldEditor().doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(palette.activeSiteSearch)
        XCTAssertEqual(try fieldEditor().string, "")
        XCTAssertEqual(spy.events, [], "the first Escape does not dismiss")
    }

    @MainActor func testReturnOnAnEmptyQuerySubmitsNothing() throws {
        let palette = try showPalette()

        try type("ex ")
        try pressReturn()
        XCTAssertEqual(palette.activeSiteSearch?.name, "Example")
        XCTAssertEqual(spy.events, [])
    }

    // MARK: - Rows

    @MainActor func testTheSitesHistoryFollowsTheSearchRow() throws {
        let palette = try showPalette(visited: [
            ("https://search.example.com/find?q=cats", "cats - Example"),
            ("https://search.example.com/item/cats", "cats - Example item"),
            ("https://other.test/cats", "cats elsewhere"),
        ])

        try type("ex ")
        try type("cats")
        let searchRow = SuggestionItem.siteSearch(name: "Example", query: "cats",
                                                  url: "https://search.example.com/find?q=cats")
        let sitePage = SuggestionItem.historyResult(url: "https://search.example.com/item/cats",
                                                    title: "cats - Example item", faviconURL: nil)
        XCTAssertEqual(palette.suggestions.first, searchRow, "the search row comes first, at once")
        wait(until: { palette.suggestions.count > 1 && palette.suggestions[1] == sitePage },
             "the site's own page follows it once the history pass lands")
        XCTAssertFalse(palette.suggestions.prefix(2).contains {
            if case .historyResult(let url, _, _) = $0 { return url.contains("other.test") } else { return false }
        }, "another site's page is not among the site's rows")
        XCTAssertFalse(palette.suggestions.contains(.historyResult(url: "https://search.example.com/find?q=cats",
                                                                   title: "cats - Example", faviconURL: nil)),
                       "the past search for the same query is the search row, not a second row")

        try pressReturn()
        XCTAssertEqual(spy.events, [.siteSearch("https://search.example.com/find?q=cats")],
                       "Return takes the selected search row")
    }

    @MainActor func testAPrivatePaletteStillSearchesTheSite() throws {
        let palette = try showPalette(historyScope: false)

        try type("ex ")
        try type("cats")
        try pressReturn()
        XCTAssertEqual(palette.activeSiteSearch?.name, "Example")
        XCTAssertEqual(spy.events, [.siteSearch("https://search.example.com/find?q=cats")])
    }
}

/// TASK-287: Settings > Search lists the store's site searches and edits them
/// through `SiteSearchForm`, which never saves what the store would refuse.
nonisolated final class SearchSettingsPaneTests: XCTestCase {

    @MainActor private func makeStore() throws -> SiteSearchStore {
        SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))
    }

    @MainActor func testThePaneListsTheStoreAndFollowsItsChanges() throws {
        let store = try makeStore()
        let pane = SearchSettingsViewController(siteSearches: store)
        _ = pane.view
        XCTAssertEqual(pane.tableView.numberOfRows, SiteSearch.starterSet.count)

        store.remove(id: try XCTUnwrap(store.entry(forKeyword: "yt")).id)
        XCTAssertEqual(pane.tableView.numberOfRows, SiteSearch.starterSet.count - 1)
        store.add(SiteSearch(name: "Docs", keyword: "docs", urlTemplate: "https://docs.example/?q=%s"))
        XCTAssertEqual(pane.tableView.numberOfRows, SiteSearch.starterSet.count)
    }

    @MainActor func testAnEmptyFormCannotBeSavedAndSaysWhy() throws {
        let store = try makeStore()
        let form = SiteSearchForm(store: store, editing: nil)
        var valid: Bool?
        form.onValidityChange = { valid = $0 }
        form.refresh()
        XCTAssertEqual(valid, false)
        XCTAssertEqual(form.problems.first, .emptyName)
        XCTAssertEqual(form.problemMessage, "", "a new form does not open on a complaint")
        XCTAssertNil(form.save())
        XCTAssertEqual(store.entries.count, SiteSearch.starterSet.count)

        form.addressField.stringValue = "https://x.example/"
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(form.problemMessage, SiteSearchProblem.emptyName.message, "after an edit it says why")
    }

    @MainActor func testAFilledFormAddsTheEntry() throws {
        let store = try makeStore()
        let form = SiteSearchForm(store: store, editing: nil)
        form.nameField.stringValue = "Docs"
        form.keywordField.stringValue = "docs"
        form.addressField.stringValue = "https://docs.example/?q=%s"
        XCTAssertEqual(form.problems, [])
        let saved = try XCTUnwrap(form.save())
        XCTAssertEqual(store.entry(forKeyword: "docs")?.id, saved.id)
    }

    @MainActor func testTheFormRefusesADuplicateKeywordAndAnAddressWithoutTheSlot() throws {
        let store = try makeStore()
        let form = SiteSearchForm(store: store, editing: nil)
        form.nameField.stringValue = "Tube"
        form.keywordField.stringValue = "yt"
        form.addressField.stringValue = "https://tube.example/"
        XCTAssertEqual(form.problems, [.duplicateKeyword, .missingPlaceholder])
        XCTAssertNil(form.save())
    }

    @MainActor func testEditingKeepsTheEntryAndItsKeywordIsNotItsOwnDuplicate() throws {
        let store = try makeStore()
        let youtube = try XCTUnwrap(store.entry(forKeyword: "yt"))
        let form = SiteSearchForm(store: store, editing: youtube)
        XCTAssertEqual(form.keywordField.stringValue, "yt")
        XCTAssertEqual(form.problems, [])
        form.nameField.stringValue = "YouTube Music"
        form.addressField.stringValue = "https://music.youtube.com/search?q=%s"
        XCTAssertNotNil(form.save())
        let edited = try XCTUnwrap(store.entry(withID: youtube.id))
        XCTAssertEqual(edited.name, "YouTube Music")
        XCTAssertEqual(edited.sortOrder, youtube.sortOrder)
        XCTAssertEqual(store.entries.count, SiteSearch.starterSet.count)
    }
}
