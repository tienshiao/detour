import XCTest
import AppKit
import GRDB
@testable import Detour

/// TASK-320: browser commands in a real `CommandPaletteView`, driven as the
/// field editor drives it, over an in-memory history and a fake command
/// source: how command rows rank against the URL and history rows, the ">"
/// list, what Return does in each, and that only matched commands are
/// resolved. (Real windows and the registry: `PaletteCommandWindowTests`.)
nonisolated final class PaletteCommandRowsTests: XCTestCase {

    @MainActor private final class SpyDelegate: CommandPaletteDelegate {
        enum Event: Equatable {
            case input(String)
            case search(String)
            case command(CommandID)
            case dismissed
        }
        private(set) var events: [Event] = []

        func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) { events.append(.input(input)) }
        func commandPalette(_ palette: CommandPaletteView, didSubmitSearch query: String) { events.append(.search(query)) }
        func commandPalette(_ palette: CommandPaletteView, didSubmitSiteSearch url: URL) {}
        func commandPaletteDidDismiss(_ palette: CommandPaletteView) { events.append(.dismissed) }
        func commandPalette(_ palette: CommandPaletteView, didRequestCommand id: CommandID) { events.append(.command(id)) }
    }

    private var window: NSWindow?
    private var palette: CommandPaletteView?
    private var spy = SpyDelegate()
    /// The IDs the source was asked to resolve, in order.
    private var resolved: [CommandID] = []

    @MainActor override func tearDown() async throws {
        palette?.delegate = nil
        palette?.dismiss()
        palette = nil
        window?.close()
        window = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private static let pinterest = "https://www.pinterest.com/"

    /// The fake window's commands: Show Archived Tabs is unavailable in it.
    private static let commands: [PaletteCommand] = [
        PaletteCommand(id: "tab.toggle-pin", title: "Pin Tab", symbol: "pin", keyEquivalent: "⌘D"),
        PaletteCommand(id: "window.new-private", title: "New Private Window", symbol: nil, keyEquivalent: "⇧⌘N"),
        PaletteCommand(id: "page.reload", title: "Reload Page", symbol: nil, keyEquivalent: "⌘R"),
        PaletteCommand(id: "archive.show", title: "Show Archived Tabs", symbol: nil, keyEquivalent: nil),
    ]
    private static let unavailable: Set<CommandID> = ["archive.show"]

    @MainActor private func source() -> PaletteCommandSource {
        PaletteCommandSource(
            candidates: [
                .init(id: "tab.toggle-pin", title: "Pin/Unpin Tab", aliases: ["pin tab", "unpin tab"]),
                .init(id: "window.new-private", title: "New Private Window", aliases: ["incognito window"]),
                .init(id: "page.reload", title: "Reload Page", aliases: ["refresh"]),
                .init(id: "archive.show", title: "Show Archived Tabs", aliases: ["archive"]),
            ],
            resolve: { [weak self] id in
                self?.resolved.append(id)
                guard !Self.unavailable.contains(id) else { return nil }
                return Self.commands.first { $0.id == id }
            })
    }

    /// A palette as Cmd+T shows it, over a history that has visited
    /// Pinterest, with no site searches; `commands: false` is a palette with
    /// no command source (the Quick Detour launcher's).
    @MainActor private func showPalette(commands: Bool = true) throws -> CommandPaletteView {
        let db = try HistoryDatabase(dbQueue: try DatabaseQueue())
        let spaceID = UUID().uuidString
        db.recordVisit(url: Self.pinterest, title: "Pinterest", faviconURL: nil, spaceID: spaceID)
        db.recordVisit(url: "https://older.example.com/", title: "Older", faviconURL: nil, spaceID: spaceID)

        let siteSearches = SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))
        for entry in siteSearches.entries { siteSearches.remove(id: entry.id) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        self.window = window

        let palette = CommandPaletteView()
        palette.siteSearches = siteSearches
        palette.suggestionProvider = SuggestionProvider(db: db)
        palette.historySpaceIDs = [spaceID]
        if commands { palette.commandSource = source() }
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

    @MainActor private func press(_ command: Selector) throws { try fieldEditor().doCommand(by: command) }
    @MainActor private func pressReturn() throws { try press(#selector(NSResponder.insertNewline(_:))) }
    @MainActor private func pressDown() throws { try press(#selector(NSResponder.moveDown(_:))) }

    /// Spins until `condition` holds: the history pass lands from a background queue.
    @MainActor private func waitUntil(_ what: String, _ condition: () -> Bool,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    @MainActor private func commandIDs(_ rows: [SuggestionItem]) -> [CommandID] {
        rows.compactMap { if case .command(let command) = $0 { return command.id } else { return nil } }
    }

    // MARK: - Ranked in among the URL and history rows

    @MainActor func testAMatchingCommandFollowsTheTopHitAndTheVerbatimRow() throws {
        let palette = try showPalette()
        try type("pin")
        waitUntil("the history top hit") {
            if case .historyResult(let url, _, _) = palette.suggestions.first { return url == Self.pinterest }
            return false
        }
        XCTAssertEqual(palette.suggestions[1], .searchInput(text: "pin"))
        XCTAssertEqual(palette.suggestions[2], .command(Self.commands[0]), "Pin Tab, with its shortcut")
        XCTAssertEqual(commandIDs(palette.suggestions), ["tab.toggle-pin"])
    }

    @MainActor func testReturnOnTypedTextStillTakesTheTopHitNotTheCommand() throws {
        let palette = try showPalette()
        try type("pin")
        waitUntil("the history top hit") {
            if case .historyResult(let url, _, _) = palette.suggestions.first { return url == Self.pinterest }
            return false
        }
        XCTAssertEqual(commandIDs(palette.suggestions), ["tab.toggle-pin"])
        try pressReturn()
        XCTAssertEqual(spy.events.last, .input(Self.pinterest))
    }

    @MainActor func testArrowingToTheCommandAndReturnRunsIt() throws {
        let palette = try showPalette()
        try type("pin")
        waitUntil("the command row") { commandIDs(palette.suggestions) == ["tab.toggle-pin"] }
        let row = try XCTUnwrap(palette.suggestions.firstIndex(of: .command(Self.commands[0])))
        for _ in 0..<row { try pressDown() }
        XCTAssertEqual(try fieldEditor().string, "Pin Tab", "the field shows the command's title")
        try pressReturn()
        XCTAssertEqual(spy.events.last, .command("tab.toggle-pin"))
    }

    @MainActor func testAShortQueryRanksNoCommandIn() throws {
        let palette = try showPalette()
        try type("pi")
        waitUntil("the rows") { palette.suggestions.contains(.searchInput(text: "pi")) }
        XCTAssertEqual(commandIDs(palette.suggestions), [])
        XCTAssertEqual(resolved, [], "nothing matched, nothing resolved")
    }

    @MainActor func testAnAliasMatches() throws {
        let palette = try showPalette()
        try type("refresh")
        waitUntil("the command row") { commandIDs(palette.suggestions) == ["page.reload"] }
    }

    @MainActor func testAnUnavailableCommandIsNotOffered() throws {
        let palette = try showPalette()
        try type("archive")
        waitUntil("the rows for archive") { palette.suggestions.contains(.searchInput(text: "archive")) }
        XCTAssertEqual(commandIDs(palette.suggestions), [], "Show Archived Tabs is unavailable here")
        XCTAssertTrue(resolved.contains("archive.show"), "matched, so its rule was asked")
    }

    @MainActor func testEachMatchedCommandIsResolvedOncePerShowing() throws {
        let palette = try showPalette()
        try type("pin")
        waitUntil("the command row") { commandIDs(palette.suggestions) == ["tab.toggle-pin"] }
        try type(" t")
        waitUntil("the rows for pin t") { palette.suggestions.contains(.searchInput(text: "pin t")) }
        XCTAssertEqual(resolved, ["tab.toggle-pin"], "not on every keystroke, and nothing that did not match")
    }

    // MARK: - The ">" list

    @MainActor func testTheAngleBracketListsEveryAvailableCommandAndNothingElse() throws {
        let palette = try showPalette()
        try type(">")
        XCTAssertEqual(palette.suggestions, [.command(Self.commands[0]), .command(Self.commands[1]),
                                             .command(Self.commands[2])])
        // No late pass adds history, search suggestions or filler to it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(commandIDs(palette.suggestions), ["tab.toggle-pin", "window.new-private", "page.reload"])
        XCTAssertEqual(palette.suggestions.count, 3)
    }

    @MainActor func testTheListNarrowsAsYouTypeAndReturnRunsTheFirstMatch() throws {
        let palette = try showPalette()
        try type(">new pr")
        XCTAssertEqual(palette.suggestions, [.command(Self.commands[1])])
        try pressReturn()
        XCTAssertEqual(spy.events, [.command("window.new-private")])
    }

    @MainActor func testArrowingInTheListKeepsTheFieldAsTyped() throws {
        let palette = try showPalette()
        try type(">")
        try pressDown()
        try pressDown()
        XCTAssertEqual(try fieldEditor().string, ">", "the field is the list's filter")
        try pressReturn()
        XCTAssertEqual(spy.events.last, .command("page.reload"), "the third row")
        XCTAssertEqual(palette.suggestions.count, 3)
    }

    @MainActor func testReturnWithNoMatchingCommandDoesNothing() throws {
        let palette = try showPalette()
        try type(">older")
        XCTAssertEqual(palette.suggestions, [], "history is not listed after >")
        try pressReturn()
        XCTAssertEqual(spy.events, [], "never submitted as a search or an address")
    }

    @MainActor func testLeavingTheAngleBracketGoesBackToTheNormalList() throws {
        let palette = try showPalette()
        try type(">pin")
        XCTAssertEqual(commandIDs(palette.suggestions), ["tab.toggle-pin"])
        for _ in 0..<4 { try press(#selector(NSResponder.deleteBackward(_:))) }
        try type("pin")
        waitUntil("the history top hit") {
            if case .historyResult(let url, _, _) = palette.suggestions.first { return url == Self.pinterest }
            return false
        }
        XCTAssertEqual(palette.suggestions[1], .searchInput(text: "pin"))
    }

    // MARK: - A palette with no commands

    @MainActor func testAPaletteWithoutACommandSourceTreatsTheAngleBracketAsText() throws {
        let palette = try showPalette(commands: false)
        try type(">pin")
        waitUntil("the verbatim row") { palette.suggestions.contains(.searchInput(text: ">pin")) }
        XCTAssertEqual(commandIDs(palette.suggestions), [])
        try pressReturn()
        XCTAssertEqual(spy.events.last, .input(">pin"))
    }
}
