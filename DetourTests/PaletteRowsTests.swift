import XCTest
@testable import Detour

/// TASK-184: the rows the palette shows for a typed query. The list area is a
/// fixed six rows tall, so the rows must fill it: matches first, then search
/// suggestions in the room below six, then rows from the default list.
final class PaletteRowsTests: XCTestCase {

    private let tabID = UUID()
    private let spaceID = UUID()

    private func history(_ url: String) -> SuggestionItem {
        .historyResult(url: url, title: url, faviconURL: nil)
    }

    private func tab(_ url: String, id: UUID? = nil) -> SuggestionItem {
        .openTab(tabID: id ?? UUID(), spaceID: spaceID, url: url, title: url, favicon: nil)
    }

    private var defaultList: [SuggestionItem] {
        (1...12).map { history("https://recent\($0).example/") }
    }

    // MARK: - compose

    func testAQueryWithOnlyTheVerbatimRowIsPaddedFromTheDefaultList() {
        let rows = PaletteRows.compose(matches: [.searchInput(text: "zqxw")],
                                       searchSuggestions: [], filler: defaultList)

        XCTAssertEqual(rows, [.searchInput(text: "zqxw")] + defaultList.prefix(5))
    }

    func testSearchSuggestionsFillTheRoomBelowSixBeforeAnyFiller() {
        let rows = PaletteRows.compose(matches: [.searchInput(text: "you")],
                                       searchSuggestions: ["you1", "you2", "you3", "you4", "you5"],
                                       filler: defaultList)

        XCTAssertEqual(rows, [.searchInput(text: "you")] + ["you1", "you2", "you3", "you4", "you5"]
            .map { SuggestionItem.searchSuggestion(text: $0) },
            "five suggestions under one match fill the six rows; no filler")
    }

    func testALongMatchListStillGetsTheUsualFourSearchSuggestionsAndNoFiller() {
        let matches: [SuggestionItem] = [.searchInput(text: "you")] + (1...7).map { history("https://y\($0).example/") }
        let rows = PaletteRows.compose(matches: matches,
                                       searchSuggestions: ["a", "b", "c", "d", "e"], filler: defaultList)

        XCTAssertEqual(rows, matches + ["a", "b", "c", "d"].map { SuggestionItem.searchSuggestion(text: $0) })
    }

    func testTheListNeverExceedsTheMaximum() {
        let matches: [SuggestionItem] = [.searchInput(text: "you")] + (1...10).map { history("https://y\($0).example/") }
        let rows = PaletteRows.compose(matches: matches,
                                       searchSuggestions: ["a", "b", "c", "d"], filler: defaultList)

        XCTAssertEqual(rows.count, SuggestionProvider.maxSuggestions)
        XCTAssertEqual(Array(rows.prefix(11)), matches)
    }

    func testFillerSkipsRowsForAURLAlreadyListed() {
        let shared = "https://recent1.example/"
        let openID = UUID()
        let matches: [SuggestionItem] = [.searchInput(text: "rec"), tab(shared, id: openID)]
        let filler = [tab(shared, id: openID), history(shared), history("https://recent2.example/"),
                      history("https://recent3.example/"), history("https://recent4.example/"),
                      history("https://recent5.example/"), history("https://recent6.example/")]

        let rows = PaletteRows.compose(matches: matches, searchSuggestions: [], filler: filler)

        XCTAssertEqual(rows, matches + Array(filler.dropFirst(2).prefix(4)),
                       "the open tab and the history row for the same URL are not listed twice")
    }

    func testWithNothingToPadWithTheListStaysShort() {
        let rows = PaletteRows.compose(matches: [.searchInput(text: "zqxw")], searchSuggestions: [], filler: [])
        XCTAssertEqual(rows, [.searchInput(text: "zqxw")])
    }

    // MARK: - carried search suggestions

    func testThePreviousQuerysSuggestionsThatStillMatchAreCarriedOver() {
        let carried = PaletteRows.carriedSearchSuggestions(["youtube", "YouTube Music", "young sheldon", "youtu"],
                                                           to: "youtu")
        XCTAssertEqual(carried, ["youtube", "YouTube Music"],
                       "suggestions the new text no longer prefixes go, and so does the new text itself")
    }

    // MARK: - late passes and the user's selection

    func testALatePassReplacesTheRowsWhileTheSelectionIsWhereTheListPutIt() {
        let old: [SuggestionItem] = [.searchInput(text: "you"), history("https://a.example/")]
        let new: [SuggestionItem] = [history("https://you.example/"), .searchInput(text: "you")]
        XCTAssertEqual(PaletteRows.latePassOutcome(old: old, new: new, selectedRow: 0, selectionMoved: false), .apply)
    }

    func testALatePassKeepsTheSelectionWhenTheRowsUpToItAreUnchanged() {
        let old: [SuggestionItem] = [.searchInput(text: "you"), history("https://a.example/"), history("https://old.example/")]
        let new: [SuggestionItem] = [.searchInput(text: "you"), history("https://a.example/"), .searchSuggestion(text: "youtube")]
        XCTAssertEqual(PaletteRows.latePassOutcome(old: old, new: new, selectedRow: 1, selectionMoved: true),
                       .applyKeepingSelection)
    }

    func testALatePassThatWouldChangeTheSelectedRowIsSkipped() {
        let old: [SuggestionItem] = [.searchInput(text: "you"), history("https://a.example/"), history("https://old.example/")]
        let new: [SuggestionItem] = [.searchInput(text: "you"), history("https://a.example/"), .searchSuggestion(text: "youtube")]
        XCTAssertEqual(PaletteRows.latePassOutcome(old: old, new: new, selectedRow: 2, selectionMoved: true), .skip)
    }

    func testALatePassDoesNotReplaceTheFirstRowOnceTheUserArrowedBackToIt() {
        // Down then Up lands on row 0 again, the row the list itself selects;
        // the user chose it, so a pass that would change it is still skipped.
        let old: [SuggestionItem] = [.searchInput(text: "gi"), history("https://a.example/")]
        let new: [SuggestionItem] = [history("https://github.com/"), .searchInput(text: "gi")]
        XCTAssertEqual(PaletteRows.latePassOutcome(old: old, new: new, selectedRow: 0, selectionMoved: true), .skip)
    }

    func testALatePassAfterTheUserArrowedOffTheListKeepsNoSelection() {
        let old: [SuggestionItem] = [.searchInput(text: "you")]
        let new: [SuggestionItem] = [.searchInput(text: "you"), .searchSuggestion(text: "youtube")]
        XCTAssertEqual(PaletteRows.latePassOutcome(old: old, new: new, selectedRow: nil, selectionMoved: true),
                       .applyKeepingSelection, "the field shows the typed text; a late pass must not select a row")
    }
}
