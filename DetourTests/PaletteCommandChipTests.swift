import XCTest
import AppKit
import GRDB
@testable import Detour

/// TASK-320 AC #3: a command that needs a space, a tab or an extension asks
/// for it with a chip in the field, as a site search does. A real
/// `CommandPaletteView` over a fake command source, driven as the field
/// editor drives it (`insertText` for typing, `doCommand(by:)` for Return,
/// the arrows, Backspace and Tab, `cancelOperation` for Escape). (The rules
/// alone: `CommandChoicesTests`; real windows and the registry:
/// `PaletteCommandChipWindowTests`.)
nonisolated final class PaletteCommandChipTests: XCTestCase {

    @MainActor private final class SpyDelegate: CommandPaletteDelegate {
        enum Event: Equatable {
            case input(String)
            case search(String)
            case siteSearch(String)
            case command(CommandID, CommandArgument?)
            case dismissed
        }
        private(set) var events: [Event] = []

        func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) { events.append(.input(input)) }
        func commandPalette(_ palette: CommandPaletteView, didSubmitSearch query: String) { events.append(.search(query)) }
        func commandPalette(_ palette: CommandPaletteView, didSubmitSiteSearch url: URL) {
            events.append(.siteSearch(url.absoluteString))
        }
        func commandPaletteDidDismiss(_ palette: CommandPaletteView) { events.append(.dismissed) }
        func commandPalette(_ palette: CommandPaletteView, didRequestCommand id: CommandID, argument: CommandArgument?) {
            events.append(.command(id, argument))
        }
    }

    private var window: NSWindow?
    private var palette: CommandPaletteView?
    private var spy = SpyDelegate()

    @MainActor override func tearDown() async throws {
        palette?.delegate = nil
        palette?.dismiss()
        palette = nil
        window?.close()
        window = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private static let work = UUID(), homework = UUID(), reading = UUID()
    private static let spaceChoices: [CommandChoice] = [
        CommandChoice(argument: .space(work), title: "Work", icon: .emoji("💼")),
        CommandChoice(argument: .space(homework), title: "Homework", icon: .emoji("📝")),
        CommandChoice(argument: .space(reading), title: "Reading", detail: "Personal", icon: .emoji("📚")),
    ]
    private static let switchToSpace = PaletteCommand(id: "space.switch", title: "Switch to Space",
                                                      symbol: "square.stack.3d.up", keyEquivalent: nil, parameter: .space)
    private static let pin = PaletteCommand(id: "tab.toggle-pin", title: "Pin Tab", symbol: "pin", keyEquivalent: "⌘D")

    @MainActor private func source() -> PaletteCommandSource {
        PaletteCommandSource(
            candidates: [
                .init(id: "space.switch", title: "Switch to Space", aliases: ["go to space"]),
                .init(id: "tab.toggle-pin", title: "Pin/Unpin Tab", aliases: ["pin tab"]),
                // A command with a parameter but nothing to choose here
                // (Move Tab to Space with one space): not offered.
                .init(id: "tab.move-to-space", title: "Move Tab to Space", aliases: []),
            ],
            resolve: { id in
                switch id {
                case "space.switch": return Self.switchToSpace
                case "tab.toggle-pin": return Self.pin
                default: return nil
                }
            },
            choices: { id in id == "space.switch" ? Self.spaceChoices : [] })
    }

    /// A palette as Cmd+T shows it (`prefill` as Cmd+L shows it), over a
    /// history that has visited a page about switches, with one site search
    /// (Example, keyword `ex`).
    @MainActor private func showPalette(prefill: String? = nil) throws -> CommandPaletteView {
        let db = try HistoryDatabase(dbQueue: try DatabaseQueue())
        let spaceID = UUID().uuidString
        db.recordVisit(url: "https://switches.example.com/", title: "Switch to tabs", faviconURL: nil, spaceID: spaceID)

        let siteSearches = SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))
        for entry in siteSearches.entries { siteSearches.remove(id: entry.id) }
        XCTAssertNotNil(siteSearches.add(SiteSearch(name: "Example", keyword: "ex",
                                                    urlTemplate: "https://search.example.com/find?q=%s")))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        self.window = window

        let palette = CommandPaletteView()
        palette.siteSearches = siteSearches
        palette.suggestionProvider = SuggestionProvider(db: db)
        palette.historySpaceIDs = [spaceID]
        palette.commandSource = source()
        palette.delegate = spy
        self.palette = palette
        palette.show(in: try XCTUnwrap(window.contentView), initialText: prefill)
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
    @MainActor private func pressBackspace() throws { try press(#selector(NSResponder.deleteBackward(_:))) }
    @MainActor private func pressEscape() throws { try press(#selector(NSResponder.cancelOperation(_:))) }

    @MainActor private func waitUntil(_ what: String, _ condition: () -> Bool,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    @MainActor private func choiceTitles(_ palette: CommandPaletteView) -> [String] {
        palette.suggestions.compactMap { if case .commandChoice(let choice) = $0 { return choice.title } else { return nil } }
    }

    /// `>switch` and Return: Switch to Space's chip, listing its spaces.
    @MainActor private func enterSwitchChip() throws -> CommandPaletteView {
        let palette = try showPalette()
        try type(">switch")
        XCTAssertEqual(palette.suggestions.first, .command(Self.switchToSpace))
        try pressReturn()
        return palette
    }

    // MARK: - Entering the chip

    @MainActor func testReturnOnAParameterisedCommandPutsItsChipInTheField() throws {
        let palette = try enterSwitchChip()
        XCTAssertEqual(palette.activeCommandChip,
                       PaletteChip.CommandState(commandID: "space.switch", enteredText: ">switch"))
        XCTAssertFalse(palette.chip.isHidden)
        XCTAssertEqual(palette.chip.title, "Switch to Space")
        XCTAssertEqual(palette.chip.symbol, "square.stack.3d.up")
        XCTAssertEqual(try fieldEditor().string, "", "the field is emptied to filter the choices")
        XCTAssertEqual(palette.placeholder, "Choose a space")
        XCTAssertEqual(choiceTitles(palette), ["Work", "Homework", "Reading"], "every choice, in its order")
        XCTAssertEqual(palette.suggestions.count, 3, "nothing else")
        XCTAssertEqual(spy.events, [], "nothing runs until a choice is made")
    }

    @MainActor func testArrowingToTheCommandAmongTheURLRowsAndReturnEntersTheChip() throws {
        let palette = try showPalette()
        try type("switch to")
        waitUntil("the command row") { palette.suggestions.contains(.command(Self.switchToSpace)) }
        let row = try XCTUnwrap(palette.suggestions.firstIndex(of: .command(Self.switchToSpace)))
        for _ in 0..<row { try pressDown() }
        XCTAssertEqual(try fieldEditor().string, "Switch to Space", "the field shows the row's title")
        try pressReturn()
        XCTAssertEqual(palette.activeCommandChip?.enteredText, "switch to", "what was typed, not the row's title")
        XCTAssertEqual(choiceTitles(palette), ["Work", "Homework", "Reading"])
    }

    @MainActor func testACommandWithoutChoicesIsNotOffered() throws {
        let palette = try showPalette()
        try type(">move")
        XCTAssertEqual(palette.suggestions, [])
    }

    @MainActor func testACommandWithoutAParameterStillRunsAtOnce() throws {
        let palette = try showPalette()
        try type(">pin")
        try pressReturn()
        XCTAssertNil(palette.activeCommandChip)
        XCTAssertEqual(spy.events, [.command("tab.toggle-pin", nil)])
    }

    // MARK: - Choosing

    @MainActor func testTypingFiltersTheChoicesAndReturnRunsTheCommandOnTheFirst() throws {
        let palette = try enterSwitchChip()
        try type("wo")
        XCTAssertEqual(choiceTitles(palette), ["Work", "Homework"], "a prefix before a match inside a word")
        try pressReturn()
        XCTAssertEqual(spy.events, [.command("space.switch", .space(Self.work))])
    }

    @MainActor func testArrowingThroughTheChoicesKeepsTheFilter() throws {
        let palette = try enterSwitchChip()
        try pressDown()
        XCTAssertEqual(try fieldEditor().string, "", "the field is the filter")
        XCTAssertEqual(palette.suggestions.count, 3)
        try pressReturn()
        XCTAssertEqual(spy.events, [.command("space.switch", .space(Self.homework))], "the second choice")
    }

    @MainActor func testReturnWithNoMatchingChoiceDoesNothing() throws {
        let palette = try enterSwitchChip()
        try type("zzz")
        XCTAssertEqual(palette.suggestions, [])
        try pressReturn()
        XCTAssertEqual(spy.events, [], "the filter is never submitted as a search or an address")
        XCTAssertNotNil(palette.activeCommandChip)
    }

    @MainActor func testTheChipListsOnlyChoicesNoHistoryOrSearches() throws {
        let palette = try enterSwitchChip()
        try type("switch")
        // No late pass (history, search suggestions, filler) adds to it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(palette.suggestions, [], "the history page about switches is not listed")
    }

    @MainActor func testAFilterThatLooksLikeACommandOrASiteSearchStaysAFilter() throws {
        let palette = try enterSwitchChip()
        try type(">")
        XCTAssertNotNil(palette.activeCommandChip, "not the command list")
        try pressBackspace()
        try type("ex ")
        XCTAssertNil(palette.activeSiteSearch, "a keyword and Space do not enter a site search")
        XCTAssertEqual(palette.chip.title, "Switch to Space")
        try press(#selector(NSResponder.insertTab(_:)))
        XCTAssertNil(palette.activeSiteSearch, "nor does Tab")
        XCTAssertNotNil(palette.activeCommandChip)
    }

    // MARK: - Leaving it: Backspace

    @MainActor func testBackspaceOnTheEmptyFieldPutsBackTheTypedText() throws {
        let palette = try enterSwitchChip()
        try pressBackspace()
        XCTAssertNil(palette.activeCommandChip)
        XCTAssertTrue(palette.chip.isHidden)
        XCTAssertEqual(try fieldEditor().string, ">switch")
        XCTAssertEqual(try fieldEditor().selectedRange(), NSRange(location: 7, length: 0), "the caret after it")
        XCTAssertEqual(palette.suggestions, [.command(Self.switchToSpace)], "the command list again")
        XCTAssertEqual(palette.placeholder, "Where do you want to go?", "the placeholder is put back")
    }

    @MainActor func testBackspaceAfterArrowingToTheCommandPutsBackWhatWasTyped() throws {
        let palette = try showPalette()
        try type("switch to")
        waitUntil("the command row") { palette.suggestions.contains(.command(Self.switchToSpace)) }
        let row = try XCTUnwrap(palette.suggestions.firstIndex(of: .command(Self.switchToSpace)))
        for _ in 0..<row { try pressDown() }
        try pressReturn()
        try pressBackspace()
        XCTAssertEqual(try fieldEditor().string, "switch to")
    }

    @MainActor func testBackspaceDeletesTheFilterBeforeItLeaves() throws {
        let palette = try enterSwitchChip()
        try type("w")
        try pressBackspace()
        XCTAssertNotNil(palette.activeCommandChip, "the first Backspace deletes the w")
        XCTAssertEqual(try fieldEditor().string, "")
        XCTAssertEqual(choiceTitles(palette), ["Work", "Homework", "Reading"])
        try pressBackspace()
        XCTAssertNil(palette.activeCommandChip, "the next leaves")
        XCTAssertEqual(try fieldEditor().string, ">switch")
    }

    @MainActor func testBackspaceAtTheStartOfAFilterPutsTheFilterBackAfterTheTypedText() throws {
        let palette = try enterSwitchChip()
        try type("wo")
        try fieldEditor().selectedRange = NSRange(location: 0, length: 0)
        try pressBackspace()
        XCTAssertNil(palette.activeCommandChip)
        XCTAssertEqual(try fieldEditor().string, ">switch wo", "as a site search puts back its query")
        XCTAssertEqual(try fieldEditor().selectedRange(), NSRange(location: 7, length: 0))
    }

    // MARK: - Leaving it: Escape

    @MainActor func testEscapeLeavesTheChipAndASecondEscapeDismisses() throws {
        let palette = try enterSwitchChip()
        try type("wo")
        try pressEscape()
        XCTAssertNil(palette.activeCommandChip)
        XCTAssertTrue(palette.chip.isHidden)
        XCTAssertEqual(try fieldEditor().string, "", "the field is cleared")
        XCTAssertEqual(spy.events, [], "the first Escape does not dismiss")
        try pressEscape()
        XCTAssertEqual(spy.events, [.dismissed])
    }

    @MainActor func testEscapeInAPrefilledPaletteDismissesAtOnce() throws {
        let palette = try showPalette(prefill: "https://example.com/page")
        try type(">switch")
        try pressReturn()
        XCTAssertNotNil(palette.activeCommandChip)
        try pressEscape()
        XCTAssertEqual(spy.events, [.dismissed], "as a site search in Cmd+L's palette")
    }
}
