import XCTest
import AppKit
@testable import Detour

/// TASK-320 AC #3: the choices a parameterised command offers in the palette
/// (`CommandChoices`) and how typed text filters them, and the chip's rules
/// for entering, Backspace and Escape (`PaletteChip`). Pure: no window.
/// (A real palette: `PaletteCommandChipTests`; real windows:
/// `PaletteCommandChipWindowTests`.)
nonisolated final class CommandChoicesTests: XCTestCase {

    // MARK: - Fixtures

    private static let homeProfile = UUID()
    private static let workProfile = UUID()
    private static let home = CommandChoices.SpaceFacts(
        id: UUID(), name: "Home", emoji: "🏠", isIncognito: false, profileID: homeProfile, profileName: "Personal")
    private static let reading = CommandChoices.SpaceFacts(
        id: UUID(), name: "Reading", emoji: "📚", isIncognito: false, profileID: homeProfile, profileName: "Personal")
    private static let work = CommandChoices.SpaceFacts(
        id: UUID(), name: "Work", emoji: "💼", isIncognito: false, profileID: workProfile, profileName: "Work")
    private static let privateSpace = CommandChoices.SpaceFacts(
        id: UUID(), name: "Private", emoji: "🕶", isIncognito: true, profileID: UUID(), profileName: "Private")
    /// Settings › Spaces order, with a Private window's space among them.
    private static let spaces = [home, privateSpace, reading, work]

    @MainActor private func arguments(_ choices: [CommandChoice]) -> [CommandArgument] { choices.map(\.argument) }

    // MARK: - Switch to Space

    @MainActor func testSwitchToSpaceListsTheOtherNormalSpacesInSettingsOrder() {
        let choices = CommandChoices.switchToSpace(spaces: Self.spaces, activeSpaceID: Self.home.id,
                                                   windowIsPrivate: false, windowProfileID: Self.homeProfile)
        XCTAssertEqual(arguments(choices), [.space(Self.reading.id), .space(Self.work.id)],
                       "not the window's own space, never a Private window's")
        XCTAssertEqual(choices.map(\.title), ["Reading", "Work"])
        XCTAssertEqual(choices.first?.icon, .emoji("📚"))
    }

    @MainActor func testASpaceOfAnotherProfileNamesItsProfile() {
        let choices = CommandChoices.switchToSpace(spaces: Self.spaces, activeSpaceID: Self.home.id,
                                                   windowIsPrivate: false, windowProfileID: Self.homeProfile)
        XCTAssertNil(choices[0].detail, "Reading is the window's profile")
        XCTAssertEqual(choices[1].detail, "Work", "Work is another profile's: as the Spaces menu, it is listed")
    }

    @MainActor func testSwitchToSpaceHasNoChoicesInAPrivateWindowOrWithOneSpace() {
        XCTAssertEqual(CommandChoices.switchToSpace(spaces: Self.spaces, activeSpaceID: Self.privateSpace.id,
                                                    windowIsPrivate: true, windowProfileID: nil), [])
        XCTAssertEqual(CommandChoices.switchToSpace(spaces: [Self.home, Self.privateSpace], activeSpaceID: Self.home.id,
                                                    windowIsPrivate: false, windowProfileID: Self.homeProfile), [],
                       "one normal space: nothing to switch to, so the command is not offered")
    }

    // MARK: - Move Tab to Space

    @MainActor func testMoveTabToSpaceLeavesOutItsOwnSpaceAndWhatTheStoreWouldRefuse() {
        var asked: [UUID] = []
        let choices = CommandChoices.moveTabToSpace(
            spaces: Self.spaces, activeSpaceID: Self.home.id, windowIsPrivate: false,
            windowProfileID: Self.homeProfile,
            canMove: { id in asked.append(id); return id != Self.work.id })
        XCTAssertEqual(arguments(choices), [.space(Self.reading.id)], "Work's profile cannot serve the page")
        XCTAssertEqual(asked, [Self.reading.id, Self.work.id], "the store is asked only about normal other spaces")
    }

    @MainActor func testMoveTabToSpaceHasNoChoicesInAPrivateWindowOrWithOneSpace() {
        XCTAssertEqual(CommandChoices.moveTabToSpace(spaces: Self.spaces, activeSpaceID: Self.privateSpace.id,
                                                     windowIsPrivate: true, windowProfileID: nil,
                                                     canMove: { _ in true }), [],
                       "nothing leaves a Private window (TASK-38)")
        XCTAssertEqual(CommandChoices.moveTabToSpace(spaces: [Self.home], activeSpaceID: Self.home.id,
                                                     windowIsPrivate: false, windowProfileID: Self.homeProfile,
                                                     canMove: { _ in true }), [])
    }

    // MARK: - Split with Tab

    private static let selected = CommandChoices.TabFacts(
        id: UUID(), title: "Selected", url: "https://selected.example/", favicon: nil, isInSplit: false)
    private static let docs = CommandChoices.TabFacts(
        id: UUID(), title: "Docs", url: "https://docs.example.com/guide", favicon: nil, isInSplit: false)
    private static let grouped = CommandChoices.TabFacts(
        id: UUID(), title: "Grouped", url: "https://grouped.example/", favicon: nil, isInSplit: true)
    private static let untitled = CommandChoices.TabFacts(
        id: UUID(), title: "", url: "https://untitled.example/page", favicon: nil, isInSplit: false)

    @MainActor func testSplitWithTabListsTheSpacesOtherTabsInNoSplit() {
        let choices = CommandChoices.splitWithTab(tabs: [Self.selected, Self.docs, Self.grouped, Self.untitled],
                                                  selectedTabID: Self.selected.id)
        XCTAssertEqual(arguments(choices), [.tab(Self.docs.id), .tab(Self.untitled.id)],
                       "not the selected tab, not one in a split already")
    }

    @MainActor func testATabChoiceIsShownAsAnOpenTabRow() {
        let docs = CommandChoices.tabChoice(Self.docs)
        XCTAssertEqual(docs.title, "Docs")
        XCTAssertEqual(docs.detail, "docs.example.com")
        XCTAssertEqual(docs.icon, .image(nil), "its favicon; none shows the globe")
        XCTAssertEqual(CommandChoices.tabChoice(Self.untitled).title, "https://untitled.example/page",
                       "no title: its address")
    }

    // MARK: - Profiles and extensions

    @MainActor func testProfilesAreTheNormalOnesAndNoneFromAPrivateWindow() {
        let profiles = [
            CommandChoices.ProfileFacts(id: Self.homeProfile, name: "Personal", isIncognito: false),
            CommandChoices.ProfileFacts(id: UUID(), name: "Private", isIncognito: true),
            CommandChoices.ProfileFacts(id: Self.workProfile, name: "Work", isIncognito: false),
        ]
        XCTAssertEqual(arguments(CommandChoices.profiles(profiles, windowIsPrivate: false)),
                       [.profile(Self.homeProfile), .profile(Self.workProfile)])
        XCTAssertEqual(CommandChoices.profiles(profiles, windowIsPrivate: true), [])
    }

    @MainActor func testExtensionsAreThoseWhoseMenuItemIsLive() {
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let extensions = [
            CommandChoices.ExtensionFacts(id: "with-popup", name: "With Popup", icon: icon),
            CommandChoices.ExtensionFacts(id: "without", name: "Without", icon: nil),
            CommandChoices.ExtensionFacts(id: "no-icon", name: "No Icon", icon: nil),
        ]
        let choices = CommandChoices.extensions(extensions) { $0 != "without" }
        XCTAssertEqual(arguments(choices), [.extension("with-popup"), .extension("no-icon")])
        XCTAssertEqual(choices[0].icon, .image(icon))
        XCTAssertEqual(choices[1].icon, .symbol("puzzlepiece.extension"))
    }

    // MARK: - Filtering

    private static let filterChoices: [CommandChoice] = [
        CommandChoice(argument: .space(UUID()), title: "Side Projects", icon: .emoji("🧪")),
        CommandChoice(argument: .space(UUID()), title: "Work", icon: .emoji("💼")),
        CommandChoice(argument: .space(UUID()), title: "Homework", icon: .emoji("📝")),
        CommandChoice(argument: .tab(UUID()), title: "Release notes", icon: .image(nil),
                      keywords: ["https://github.com/tma/detour/releases"]),
        CommandChoice(argument: .space(UUID()), title: "Projects", icon: .emoji("📁")),
    ]

    @MainActor private func titles(_ query: String) -> [String] {
        CommandChoices.filtered(query, in: Self.filterChoices).map(\.title)
    }

    @MainActor func testAnEmptyFilterIsEveryChoiceInOrder() {
        XCTAssertEqual(titles(""), Self.filterChoices.map(\.title))
        XCTAssertEqual(titles("  "), Self.filterChoices.map(\.title))
    }

    @MainActor func testATitleStartingWithTheTextComesFirstThenWordsThenContains() {
        XCTAssertEqual(titles("proj"), ["Projects", "Side Projects"], "a prefix before a later word")
        XCTAssertEqual(titles("work"), ["Work", "Homework"], "a prefix before text inside a word")
        XCTAssertEqual(titles("WO"), ["Work", "Homework"], "ignoring case")
    }

    @MainActor func testKeywordsMatchAfterTitles() {
        XCTAssertEqual(titles("github"), ["Release notes"], "a tab's address")
        XCTAssertEqual(titles("zzz"), [])
    }

    // MARK: - The chip's rules

    @MainActor func testEnteringKeepsWhatWasTypedAndEmptiesTheField() {
        let entered = PaletteChip.enter("space.switch", typedText: ">swi")
        XCTAssertEqual(entered.state, PaletteChip.CommandState(commandID: "space.switch", enteredText: ">swi"))
        XCTAssertEqual(entered.fieldText, "")
    }

    @MainActor func testBackspaceLeavesOnlyWithTheCaretAtTheStart() {
        XCTAssertTrue(PaletteChip.backspaceLeaves(selection: NSRange(location: 0, length: 0)))
        XCTAssertFalse(PaletteChip.backspaceLeaves(selection: NSRange(location: 3, length: 0)), "deletes a character")
        XCTAssertFalse(PaletteChip.backspaceLeaves(selection: NSRange(location: 0, length: 3)), "deletes the selection")
    }

    @MainActor func testBackspacePutsBackTheTypedTextAndThenTheFilter() {
        let empty = PaletteChip.restoredField(enteredFrom: ">move", query: "")
        XCTAssertEqual(empty.text, ">move")
        XCTAssertEqual(empty.caret, 5)
        let filtered = PaletteChip.restoredField(enteredFrom: "w", query: "swift")
        XCTAssertEqual(filtered.text, "w swift", "as a site search puts back its keyword and query")
        XCTAssertEqual(filtered.caret, 1, "the caret after the entered text")
        XCTAssertEqual(PaletteChip.restoredField(enteredFrom: "👋🏽 go", query: "").caret, 7, "UTF-16 units")
    }

    @MainActor func testEscapeLeavesTheChipBeforeItDismisses() {
        typealias Action = PaletteChip.EscapeAction
        func action(prefilled: Bool = false, chip: Bool = false, completion: Bool = false, empty: Bool = true) -> Action {
            PaletteChip.escapeAction(wasPrepopulated: prefilled, hasChip: chip, hasCompletion: completion,
                                     fieldIsEmpty: empty)
        }
        XCTAssertEqual(action(chip: true), .leaveChip, "first Escape: leave the chip, clearing the field")
        XCTAssertEqual(action(chip: true, empty: false), .leaveChip, "with a filter typed, too")
        XCTAssertEqual(action(), .dismiss, "second Escape: the field is empty")
        XCTAssertEqual(action(prefilled: true, chip: true), .dismiss, "Cmd+L's palette dismisses at once")
        XCTAssertEqual(action(completion: true, empty: false), .dropCompletion)
        XCTAssertEqual(action(empty: false), .clearField)
    }
}
