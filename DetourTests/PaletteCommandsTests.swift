import XCTest
import AppKit
@testable import Detour

/// TASK-320: how the palette matches, ranks and places browser commands, as
/// pure rules (`PaletteCommands`, `PaletteRows.insertingCommands`), and what
/// a window's command source offers, over a fake window.
nonisolated final class PaletteCommandsTests: XCTestCase {

    // MARK: - Command mode

    @MainActor func testTheCommandModeQueryIsWhatFollowsTheAngleBracket() {
        XCTAssertEqual(PaletteCommands.commandModeQuery(">pin"), "pin")
        XCTAssertEqual(PaletteCommands.commandModeQuery("> pin tab "), "pin tab")
        XCTAssertEqual(PaletteCommands.commandModeQuery("  >zoom"), "zoom")
        XCTAssertEqual(PaletteCommands.commandModeQuery(">"), "")
        XCTAssertNil(PaletteCommands.commandModeQuery("pin"))
        XCTAssertNil(PaletteCommands.commandModeQuery("a>b"))
        XCTAssertNil(PaletteCommands.commandModeQuery(""))
    }

    // MARK: - Matching

    @MainActor func testWordsSplitAtAnythingButLettersAndDigits() {
        XCTAssertEqual(PaletteCommands.words("Pin/Unpin Tab"), ["pin", "unpin", "tab"])
        XCTAssertEqual(PaletteCommands.words("Find..."), ["find"])
        XCTAssertEqual(PaletteCommands.words("Settings…"), ["settings"])
        XCTAssertEqual(PaletteCommands.words("  New  Quick Detour Window"), ["new", "quick", "detour", "window"])
    }

    @MainActor func testANameThatStartsWithTheTypedTextIsAPrefixMatch() {
        let match = PaletteCommands.match
        XCTAssertEqual(match(["new", "pri"], "New Private Window"), .prefix)
        XCTAssertEqual(match(["pin"], "Pin/Unpin Tab"), .prefix)
        XCTAssertEqual(match(["new", "private", "window"], "New Private Window"), .prefix)
    }

    @MainActor func testTypedWordsThatEachStartAWordAreAWordsMatch() {
        let match = PaletteCommands.match
        XCTAssertEqual(match(["history"], "Show All History"), .words)
        XCTAssertEqual(match(["tab", "close"], "Close Tab"), .words)
        XCTAssertEqual(match(["unpin"], "Pin/Unpin Tab"), .words)
        XCTAssertEqual(match(["clo"], "Reopen Closed Tab"), .words)
    }

    @MainActor func testEveryTypedWordMustMatchADifferentWord() {
        let match = PaletteCommands.match
        XCTAssertNil(match(["tab", "tab"], "Close Tab"))
        XCTAssertNil(match(["zoom", "us"], "Zoom In"), "zoom.us is an address, not Zoom In")
        XCTAssertNil(match(["news"], "New Window"))
        XCTAssertNil(match([], "New Window"))
        XCTAssertNil(match(["new"], "..."))
    }

    // MARK: - Ranking

    private let candidates: [PaletteCommandCandidate] = [
        .init(id: "window.new-private", title: "New Private Window", aliases: ["incognito window"]),
        .init(id: "tab.reopen-closed", title: "Reopen Closed Tab", aliases: ["undo close tab"]),
        .init(id: "window.new", title: "New Window", aliases: []),
        .init(id: "tab.close", title: "Close Tab", aliases: []),
        .init(id: "page.reload", title: "Reload Page", aliases: ["refresh"]),
        .init(id: "quick-detour.new", title: "New Quick Detour Window", aliases: ["little arc"]),
    ]

    @MainActor private func ranked(_ query: String) -> [String] {
        PaletteCommands.ranked(query, in: candidates).map(\.id.rawValue)
    }

    @MainActor func testPrefixMatchesComeFirstThenShorterTitles() {
        XCTAssertEqual(ranked("new"), ["window.new", "window.new-private", "quick-detour.new"])
        XCTAssertEqual(ranked("close"), ["tab.close", "tab.reopen-closed"], "Close Tab starts with it")
    }

    @MainActor func testATitleMatchRanksAboveAnAliasMatchOfTheSameKind() {
        let both: [PaletteCommandCandidate] = [
            .init(id: "a.by-alias", title: "Something Else", aliases: ["reload everything"]),
            .init(id: "b.by-title", title: "Reload Everything Now", aliases: []),
        ]
        XCTAssertEqual(PaletteCommands.ranked("reload", in: both).map(\.id.rawValue), ["b.by-title", "a.by-alias"])
    }

    @MainActor func testAliasesMatch() {
        XCTAssertEqual(ranked("refresh"), ["page.reload"])
        XCTAssertEqual(ranked("incog"), ["window.new-private"])
        XCTAssertEqual(ranked("undo close"), ["tab.reopen-closed"])
    }

    @MainActor func testAnEmptyQueryListsEveryCandidateInRegistryOrder() {
        XCTAssertEqual(ranked(""), candidates.map(\.id.rawValue))
        XCTAssertEqual(ranked("  "), candidates.map(\.id.rawValue))
    }

    @MainActor func testANonMatchingQueryListsNothing() {
        XCTAssertEqual(ranked("github.com"), [])
        XCTAssertEqual(ranked("pizza near me"), [])
    }

    @MainActor func testCommandsAreRankedInOnlyForAQueryOfThreeCharactersOrMore() {
        XCTAssertFalse(PaletteCommands.ranksCommandsIn("ne"))
        XCTAssertFalse(PaletteCommands.ranksCommandsIn(" ne "))
        XCTAssertTrue(PaletteCommands.ranksCommandsIn("new"))
        XCTAssertEqual(PaletteCommands.maximumMixedRows, 2)
    }

    // MARK: - Where command rows go

    private let command = SuggestionItem.command(PaletteCommand(id: "tab.close", title: "Close Tab", symbol: nil,
                                                                keyEquivalent: "⌘W"))
    private let topHit = SuggestionItem.historyResult(url: "https://close.example/", title: "Close", faviconURL: nil)
    private let history = SuggestionItem.historyResult(url: "https://other.example/", title: "Other", faviconURL: nil)

    @MainActor func testCommandRowsGoRightAfterTheVerbatimRow() {
        XCTAssertEqual(PaletteRows.insertingCommands([command], into: [topHit, .searchInput(text: "clo"), history]),
                       [topHit, .searchInput(text: "clo"), command, history])
        XCTAssertEqual(PaletteRows.insertingCommands([command], into: [.searchInput(text: "clo")]),
                       [.searchInput(text: "clo"), command])
    }

    @MainActor func testCommandRowsNeverTakeTheFirstRowWithoutAVerbatimRow() {
        XCTAssertEqual(PaletteRows.insertingCommands([command], into: [history]), [history, command])
        XCTAssertEqual(PaletteRows.insertingCommands([], into: [history]), [history])
    }

    @MainActor func testTheSiteSearchHintStillFollowsTheVerbatimRowWithCommandsAfterIt() {
        let hint = SuggestionItem.siteSearchHint(id: UUID(), name: "Example", fieldText: "ex")
        let withCommands = PaletteRows.insertingCommands([command], into: [.searchInput(text: "exa")])
        XCTAssertEqual(PaletteRows.insertingSiteSearchHint(hint, into: withCommands),
                       [.searchInput(text: "exa"), hint, command])
    }

    // MARK: - A window's source

    /// A window as the source sees it: every fact settable.
    @MainActor private final class FakeWindow: CommandContext {
        var commandWindowKind: CommandWindowKind
        var hasSelectedTab = true
        var selectedTabHasURL = true
        var selectedTabIsPinned = false
        init(_ kind: CommandWindowKind) { commandWindowKind = kind }
    }

    @MainActor private func candidateIDs(_ source: PaletteCommandSource) -> Set<String> {
        Set(source.candidates.map(\.id.rawValue))
    }

    @MainActor func testTheSourceOffersOnlyPaletteCommandsThatKindOfWindowAnswers() {
        let browser = PaletteCommands.source(for: FakeWindow(.normal), menu: { nil })
        let quick = PaletteCommands.source(for: FakeWindow(.quickDetour), menu: { nil })
        XCTAssertTrue(candidateIDs(browser).isSuperset(of: ["tab.toggle-pin", "sidebar.toggle", "page.reload",
                                                            "window.new", "app.settings"]))
        XCTAssertTrue(candidateIDs(quick).isSuperset(of: ["page.reload", "tab.copy-url", "window.new"]))
        XCTAssertTrue(candidateIDs(quick).isDisjoint(with: ["tab.toggle-pin", "sidebar.toggle", "history.show"]))
        for source in [browser, quick] {
            XCTAssertTrue(candidateIDs(source).isDisjoint(with: [
                "tab.new", "location.open", "edit.undo", "edit.copy", "app.quit", "window.minimize",
                "space.switch", "extension.show-popup", "space.jump-1", "space.jump-9",
            ]))
        }
    }

    @MainActor func testTheSourceResolvesACommandByItsRuleTitleAndShortcut() throws {
        let window = FakeWindow(.normal)
        let source = PaletteCommands.source(for: window, menu: { nil })
        XCTAssertEqual(source.resolve("tab.toggle-pin"),
                       PaletteCommand(id: "tab.toggle-pin", title: "Pin Tab", symbol: "pin", keyEquivalent: "⌘D"))
        window.selectedTabIsPinned = true
        XCTAssertEqual(source.resolve("tab.toggle-pin")?.title, "Unpin Tab")
        window.commandWindowKind = .private
        XCTAssertNil(source.resolve("tab.toggle-pin"), "not in a Private window, as its menu item")
        XCTAssertNil(source.resolve("archive.show"))
        XCTAssertNotNil(source.resolve("window.new"))
        XCTAssertNil(source.resolve("app.check-for-updates"), "only through its live item")
        XCTAssertNil(source.resolve("tab.new"), "not offered in the palette at all")
    }

    @MainActor func testTheShortcutShownIsTheLiveMenuItems() throws {
        let menu = NSMenu()
        let item = BrowserCommands.newQuickDetourWindow.makeMenuItem()
        item.keyEquivalent = "k"
        item.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(item)
        let window = FakeWindow(.normal)
        let source = PaletteCommands.source(for: window, menu: { menu })
        XCTAssertEqual(source.resolve("quick-detour.new")?.keyEquivalent, "⌃⌘K")
        item.keyEquivalent = ""
        XCTAssertNil(source.resolve("quick-detour.new")?.keyEquivalent, "a cleared hotkey shows none")
        XCTAssertEqual(source.resolve("page.reload")?.keyEquivalent, "⌘R", "no live item: the default")
        withExtendedLifetime(window) {}
    }

    @MainActor func testTheSourceHoldsItsWindowWeakly() {
        var window: FakeWindow? = FakeWindow(.normal)
        let source = PaletteCommands.source(for: window!, menu: { nil })
        weak var released = window
        window = nil
        XCTAssertNil(released)
        XCTAssertNil(source.resolve("window.new"))
    }
}
