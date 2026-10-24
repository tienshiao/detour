import XCTest
import GRDB
@testable import Detour

/// TASK-144: the palette's selection and submit rules.
///
/// The default list (shown while the user has typed nothing) used to start
/// with its first row keyboard-selected, like the list for a typed query. So
/// Cmd+L followed by Return activated the space's most recent history entry
/// instead of submitting the pre-filled URL, and Cmd+T followed by Return
/// opened that entry from an empty field.
final class PaletteSelectionTests: XCTestCase {

    private let currentURL = "https://current.example.com/"

    // MARK: - The four Return cases

    func testReturnOnAnUneditedPrefilledFieldSubmitsThePrefilledURL() {
        // Cmd+L: the field holds the current URL over a default list of 12 rows.
        let selected = PaletteSelection.initialRow(listIsDefault: true, rowCount: 12)
        XCTAssertNil(selected, "the default list starts with no row selected")

        XCTAssertEqual(
            PaletteSelection.returnAction(selectedRow: selected, rowCount: 12, fieldText: currentURL),
            .submitText(currentURL))
    }

    func testReturnOnAnEmptyFieldDoesNothing() {
        // Cmd+T: an empty field over the same default list.
        let selected = PaletteSelection.initialRow(listIsDefault: true, rowCount: 12)

        XCTAssertEqual(
            PaletteSelection.returnAction(selectedRow: selected, rowCount: 12, fieldText: ""),
            .nothing, "Return no longer opens the most recent history entry")
    }

    func testReturnAfterArrowingToADefaultRowActivatesThatRow() {
        var selected = PaletteSelection.initialRow(listIsDefault: true, rowCount: 12)
        selected = PaletteSelection.row(afterMoving: 1, from: selected, rowCount: 12)
        XCTAssertEqual(selected, 0, "Down from no selection selects the first row")
        XCTAssertEqual(
            PaletteSelection.returnAction(selectedRow: selected, rowCount: 12, fieldText: "https://row0.example.com/"),
            .activateRow(0))

        selected = PaletteSelection.row(afterMoving: 1, from: selected, rowCount: 12)
        XCTAssertEqual(
            PaletteSelection.returnAction(selectedRow: selected, rowCount: 12, fieldText: "https://row1.example.com/"),
            .activateRow(1))
    }

    func testReturnOnATypedQueryActivatesTheTopRow() {
        // Typed input keeps the first row (top hit, else the verbatim input)
        // selected after every rebuild.
        let selected = PaletteSelection.initialRow(listIsDefault: false, rowCount: 3)
        XCTAssertEqual(selected, 0)

        XCTAssertEqual(
            PaletteSelection.returnAction(selectedRow: selected, rowCount: 3, fieldText: "github.com/foo"),
            .activateRow(0))
    }

    // MARK: - Initial selection

    func testAnEmptyListHasNoSelection() {
        XCTAssertNil(PaletteSelection.initialRow(listIsDefault: false, rowCount: 0))
        XCTAssertNil(PaletteSelection.initialRow(listIsDefault: true, rowCount: 0))
    }

    // MARK: - Arrow keys

    func testDownFromNoSelectionSelectsTheFirstRow() {
        XCTAssertEqual(PaletteSelection.row(afterMoving: 1, from: nil, rowCount: 4), 0)
    }

    func testUpFromNoSelectionWrapsToTheLastRow() {
        XCTAssertEqual(PaletteSelection.row(afterMoving: -1, from: nil, rowCount: 4), 3)
    }

    func testArrowsMoveWithinTheList() {
        XCTAssertEqual(PaletteSelection.row(afterMoving: 1, from: 1, rowCount: 4), 2)
        XCTAssertEqual(PaletteSelection.row(afterMoving: -1, from: 1, rowCount: 4), 0)
    }

    func testMovingPastEitherEndClearsTheSelection() {
        XCTAssertNil(PaletteSelection.row(afterMoving: -1, from: 0, rowCount: 4))
        XCTAssertNil(PaletteSelection.row(afterMoving: 1, from: 3, rowCount: 4))
    }

    func testArrowsDoNothingInAnEmptyList() {
        XCTAssertNil(PaletteSelection.row(afterMoving: 1, from: nil, rowCount: 0))
        XCTAssertNil(PaletteSelection.row(afterMoving: -1, from: nil, rowCount: 0))
    }

    // MARK: - Return

    func testReturnTrimsTheSubmittedText() {
        XCTAssertEqual(
            PaletteSelection.returnAction(selectedRow: nil, rowCount: 0, fieldText: "  swift  "),
            .submitText("swift"))
        XCTAssertEqual(
            PaletteSelection.returnAction(selectedRow: nil, rowCount: 5, fieldText: "   "),
            .nothing)
    }

    func testAStaleSelectionPastTheEndOfTheListSubmitsTheText() {
        XCTAssertEqual(
            PaletteSelection.returnAction(selectedRow: 4, rowCount: 2, fieldText: "swift"),
            .submitText("swift"))
    }

    // MARK: - Text restored when the selection is cleared

    func testLeavingTheListRestoresAnUneditedPrefill() {
        XCTAssertEqual(
            PaletteSelection.restoredFieldText(userTypedText: "", uneditedPrefill: currentURL),
            currentURL)
    }

    func testLeavingTheListRestoresWhatTheUserTyped() {
        XCTAssertEqual(
            PaletteSelection.restoredFieldText(userTypedText: "git", uneditedPrefill: nil),
            "git")
        XCTAssertEqual(
            PaletteSelection.restoredFieldText(userTypedText: "", uneditedPrefill: nil),
            "", "a field the user cleared stays cleared")
    }
}

/// The same rules through a real `CommandPaletteView`, driven the way the
/// field editor drives it: commands go to the first responder's
/// `doCommand(by:)`, which asks the palette's `control(_:textView:doCommandBy:)`
/// and otherwise falls through to the field's own action.
@MainActor
final class PaletteReturnKeyTests: XCTestCase {

    private final class SpyDelegate: CommandPaletteDelegate {
        enum Event: Equatable {
            case input(String)
            case search(String)
            case switchToTab(UUID)
            case dismissed
        }
        private(set) var events: [Event] = []

        func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) {
            events.append(.input(input))
        }
        func commandPalette(_ palette: CommandPaletteView, didSubmitSearch query: String) {
            events.append(.search(query))
        }
        func commandPaletteDidDismiss(_ palette: CommandPaletteView) {
            events.append(.dismissed)
        }
        func commandPalette(_ palette: CommandPaletteView, didRequestSwitchToTab tabID: UUID, in spaceID: UUID) {
            events.append(.switchToTab(tabID))
        }
    }

    private let currentURL = "https://current.example.com/"
    /// The space's two most recent history entries, newest first: the default
    /// list's rows 0 and 1. Neither is the page the palette is opened on.
    private let newestURL = "https://newest.example.com/"
    private let olderURL = "https://older.example.com/"

    private var window: NSWindow?
    private var palette: CommandPaletteView?
    private var spy = SpyDelegate()

    override func tearDown() {
        // Cancels the debounced network suggestion fetch a typed query schedules.
        palette?.delegate = nil
        palette?.dismiss()
        palette = nil
        window?.close()
        window = nil
        super.tearDown()
    }

    /// A palette over a default list of [newestURL, olderURL], shown as Cmd+L
    /// shows it (`initialText` = the current URL) or as Cmd+T does (nil).
    private func showPalette(initialText: String?, alsoVisited: [String] = []) throws -> CommandPaletteView {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let db = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let spaceID = UUID()
        // Recorded in order; a tie on the visit time is broken by the newer row.
        db.recordVisit(url: olderURL, title: "Older", faviconURL: nil, spaceID: spaceID.uuidString)
        db.recordVisit(url: newestURL, title: "Newest", faviconURL: nil, spaceID: spaceID.uuidString)
        XCTAssertEqual(db.recentHistory(spaceID: spaceID.uuidString).map(\.url), [newestURL, olderURL])
        for url in alsoVisited {
            db.recordVisit(url: url, title: "", faviconURL: nil, spaceID: spaceID.uuidString)
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        self.window = window

        let palette = CommandPaletteView()
        palette.suggestionProvider = SuggestionProvider(db: db)
        palette.activeSpaceID = spaceID
        palette.delegate = spy
        self.palette = palette
        palette.show(in: try XCTUnwrap(window.contentView), initialText: initialText)
        return palette
    }

    /// The field editor of the palette's text field, which is first responder
    /// while the palette is shown.
    private func fieldEditor() throws -> NSTextView {
        try XCTUnwrap(window?.firstResponder as? NSTextView, "the palette's field is being edited")
    }

    private func press(_ command: Selector) throws {
        try fieldEditor().doCommand(by: command)
    }

    private func pressReturn() throws { try press(#selector(NSResponder.insertNewline(_:))) }
    private func pressDown() throws { try press(#selector(NSResponder.moveDown(_:))) }
    private func pressUp() throws { try press(#selector(NSResponder.moveUp(_:))) }

    private func type(_ text: String) throws {
        let editor = try fieldEditor()
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// Spins the main run loop until the field shows `text`: a history-derived
    /// inline completion lands from the palette's background query.
    private func waitForField(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let editor = try fieldEditor()
        let deadline = Date().addingTimeInterval(5)
        while editor.string != text, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(editor.string, text, file: file, line: line)
    }

    // MARK: - Cmd+L

    /// The reproduction of TASK-144: before the fix the delegate received
    /// `newestURL`, the default list's first row.
    func testCmdLThenReturnSubmitsThePrefilledURL() throws {
        _ = try showPalette(initialText: currentURL)

        try pressReturn()

        XCTAssertEqual(spy.events, [.input(currentURL)])
    }

    func testCmdLThenDownThenReturnActivatesTheFirstDefaultRow() throws {
        _ = try showPalette(initialText: currentURL)

        try pressDown()
        XCTAssertEqual(try fieldEditor().string, newestURL, "the selected row's URL is shown in the field")
        try pressReturn()

        XCTAssertEqual(spy.events, [.input(newestURL)])
    }

    func testCmdLThenDownTwiceThenReturnActivatesTheSecondDefaultRow() throws {
        _ = try showPalette(initialText: currentURL)

        try pressDown()
        try pressDown()
        try pressReturn()

        XCTAssertEqual(spy.events, [.input(olderURL)])
    }

    func testArrowingBackOutOfTheListRestoresThePrefilledURL() throws {
        _ = try showPalette(initialText: currentURL)

        try pressDown()
        try pressUp()
        XCTAssertEqual(try fieldEditor().string, currentURL)
        try pressReturn()

        XCTAssertEqual(spy.events, [.input(currentURL)])
    }

    // MARK: - Cmd+T

    func testCmdTThenReturnOnTheEmptyFieldDoesNothing() throws {
        _ = try showPalette(initialText: nil)

        try pressReturn()

        XCTAssertEqual(spy.events, [], "the most recent history entry is not opened")
    }

    func testCmdTThenDownThenReturnActivatesTheFirstDefaultRow() throws {
        _ = try showPalette(initialText: nil)

        try pressDown()
        try pressReturn()

        XCTAssertEqual(spy.events, [.input(newestURL)])
    }

    func testCmdTThenUpWrapsToTheLastDefaultRow() throws {
        _ = try showPalette(initialText: nil)

        try pressUp()
        try pressReturn()

        XCTAssertEqual(spy.events, [.input(olderURL)])
    }

    // MARK: - Typed input

    /// Typed input keeps today's behaviour: the first row of the rebuilt list
    /// is selected, so Return activates it. With no open tabs the instant
    /// (pre-history) list is just the verbatim typed-input row.
    func testTypedQueryThenReturnActivatesTheTopRow() throws {
        _ = try showPalette(initialText: nil)

        let editor = try fieldEditor()
        editor.insertText("swift", replacementRange: editor.selectedRange())
        try pressReturn()

        XCTAssertEqual(spy.events, [.input("swift")])
    }

    func testTypingOverThePrefilledURLThenReturnSubmitsTheTypedText() throws {
        _ = try showPalette(initialText: currentURL)

        // Cmd+L selects the whole pre-filled URL, so typing replaces it.
        let editor = try fieldEditor()
        editor.insertText("swift", replacementRange: editor.selectedRange())
        try pressReturn()

        XCTAssertEqual(spy.events, [.input("swift")])
    }

    // MARK: - Inline completion (TASK-181)

    private let deepURL = "https://www.example.com/watch?v=abc"

    /// The reproduction of TASK-181: Cmd+Right moved the caret to the end, but
    /// the completion was still pending, so Backspace dropped it and left the
    /// field at the typed prefix instead of deleting the last character.
    func testBackspaceAfterMovingToTheEndDeletesTheLastCharacter() throws {
        _ = try showPalette(initialText: nil, alsoVisited: [deepURL])

        try type("example.com/w")
        try waitForField("example.com/watch?v=abc")
        XCTAssertEqual(try fieldEditor().selectedRange(), NSRange(location: 13, length: 10),
                       "the completed suffix is selected")

        try press(#selector(NSResponder.moveToRightEndOfLine(_:)))
        try press(#selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(try fieldEditor().string, "example.com/watch?v=ab")
        try pressReturn()
        XCTAssertEqual(spy.events.last, .input("example.com/watch?v=ab"),
                       "Return submits the field as edited, not a stale completion")
    }

    /// The caret placed inside the completion (a click, Left arrow) accepts it
    /// too: Backspace deletes before the caret.
    func testBackspaceAfterPlacingTheCaretInsideTheCompletionDeletesBeforeTheCaret() throws {
        _ = try showPalette(initialText: nil, alsoVisited: [deepURL])

        try type("example.com/w")
        try waitForField("example.com/watch?v=abc")

        try fieldEditor().setSelectedRange(NSRange(location: 17, length: 0))
        try press(#selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(try fieldEditor().string, "example.com/watc?v=abc")
    }

    /// Unchanged: with the completion still selected, Backspace removes only
    /// the completion.
    func testBackspaceWhileTheCompletionIsSelectedRemovesOnlyTheCompletion() throws {
        _ = try showPalette(initialText: nil, alsoVisited: [deepURL])

        try type("example.com/w")
        try waitForField("example.com/watch?v=abc")
        try press(#selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(try fieldEditor().string, "example.com/w")
    }

    /// Tab with no completion pending (here: the caret moved off it, which
    /// accepts it) must not move keyboard focus out of the open palette.
    func testTabAfterMovingOffTheCompletionKeepsFocusInTheField() throws {
        let palette = try showPalette(initialText: nil, alsoVisited: [deepURL])
        // Something else focusable in the window, so Tab has somewhere to go.
        let other = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        palette.superview?.addSubview(other, positioned: .below, relativeTo: palette)
        window?.autorecalculatesKeyViewLoop = true
        window?.recalculateKeyViewLoop()

        try type("example.com/w")
        try waitForField("example.com/watch?v=abc")
        let editor = try fieldEditor()
        try press(#selector(NSResponder.moveToRightEndOfLine(_:)))
        try press(#selector(NSResponder.insertTab(_:)))

        XCTAssertTrue(window?.firstResponder === editor, "the palette's field keeps focus")
        XCTAssertEqual(editor.string, "example.com/watch?v=abc")
    }
}
