import XCTest
import AppKit
@testable import Detour

/// TASK-320 AC #3 in real windows: Move Tab to Space, Switch to Space and
/// Split with Tab chosen in the palette put their chip in the field, list
/// what the window may choose (Settings › Spaces order, never a Private
/// window's space, not the window's own; the space's own tabs for a split),
/// and Return runs the command on the choice through the path its menu or
/// sidebar item takes; then the palette is gone. A Private window offers
/// neither space command and splits only its own tabs (TASK-137, TASK-209).
///
/// Real windows on `TabStore.shared` with profiles of the test's own; pages
/// are `.invalid` hosts. The field is driven as the field editor drives it.
nonisolated final class PaletteCommandChipWindowTests: XCTestCase {

    @MainActor private var store: TabStore { .shared }
    private var profile: Profile!
    private var otherProfile: Profile!
    private var home: Space!
    private var reading: Space!
    private var elsewhere: Space!
    private var windows: [BrowserWindowController] = []
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        let tag = UUID().uuidString.prefix(4)
        profile = store.addProfile(name: "Chip \(tag)")
        otherProfile = store.addProfile(name: "Chip Other \(tag)")
        home = store.addSpace(name: "Chip Home \(tag)", emoji: "🏠", colorHex: "007AFF", profileID: profile.id)
        reading = store.addSpace(name: "Chip Reading \(tag)", emoji: "📚", colorHex: "34C759", profileID: profile.id)
        elsewhere = store.addSpace(name: "Chip Elsewhere \(tag)", emoji: "🧳", colorHex: "FF9500",
                                   profileID: otherProfile.id)
        store.undoManager.removeAllActions()
    }

    @MainActor override func tearDown() async throws {
        for wc in windows {
            wc.dismissCommandPalette(restoringFocus: false)
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for space in [home, reading, elsewhere].compactMap({ $0 }) {
            for tab in space.tabs { tab.teardown() }
            for entry in space.pinnedEntries { entry.tab?.teardown() }
            store.forceRemoveSpace(id: space.id)
        }
        for profile in [profile, otherProfile].compactMap({ $0 }) {
            store.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        store.undoManager.removeAllActions()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    @MainActor private func spin(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor private func page(_ path: String) -> URL { URL(string: "https://palette-chip.invalid/\(path)")! }

    /// A window on Home with `count` tabs, the first selected.
    @MainActor private func windowOnHome(tabs count: Int = 2) -> (BrowserWindowController, [BrowserTab]) {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: home.id, selectTab: false)
        wc.showWindow(nil)
        windows.append(wc)
        let tabs = (0..<count).map { store.addTab(in: home, url: page("tab\($0)")) }
        wc.selectTab(id: tabs[0].id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (wc, tabs)
    }

    @MainActor private func privateWindow(tabs count: Int) throws -> (BrowserWindowController, [BrowserTab]) {
        let wc = BrowserWindowController(incognito: true)
        wc.sidebarSplitView.autosaveName = nil
        wc.showWindow(nil)
        windows.append(wc)
        let space = try XCTUnwrap(wc.activeSpace)
        let tabs = (0..<count).map { store.addTab(in: space, url: page("private\($0)")) }
        wc.selectTab(id: tabs[0].id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (wc, tabs)
    }

    @MainActor private func fieldEditor(of wc: BrowserWindowController) throws -> NSTextView {
        try XCTUnwrap(wc.window?.firstResponder as? NSTextView, "the palette's field is being edited")
    }

    @MainActor private func type(_ text: String, in wc: BrowserWindowController) throws {
        let editor = try fieldEditor(of: wc)
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    @MainActor private func pressReturn(in wc: BrowserWindowController) throws {
        try fieldEditor(of: wc).doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    @MainActor private func commandIDs(_ wc: BrowserWindowController) -> [CommandID] {
        (wc.commandPaletteView?.suggestions ?? []).compactMap {
            if case .command(let command) = $0 { return command.id } else { return nil }
        }
    }

    @MainActor private func choices(_ wc: BrowserWindowController) -> [CommandArgument] {
        (wc.commandPaletteView?.suggestions ?? []).compactMap {
            if case .commandChoice(let choice) = $0 { return choice.argument } else { return nil }
        }
    }

    /// Cmd+T's palette, `>` + `query`, Return on the first row, which must be
    /// `command`: its chip is in the field.
    @MainActor private func enterChip(_ command: BrowserCommand, typing query: String,
                                      in wc: BrowserWindowController) throws {
        wc.newTab(nil)
        try type(">\(query)", in: wc)
        XCTAssertEqual(commandIDs(wc).first, command.id)
        try pressReturn(in: wc)
        XCTAssertEqual(wc.commandPaletteView?.activeCommandChip?.commandID, command.id)
        XCTAssertEqual(wc.commandPaletteView?.chip.title, command.titleInPalette)
    }

    // MARK: - Move Tab to Space

    @MainActor func testMoveTabToSpaceListsTheOtherSpacesAndMovesTheTabToTheChoice() throws {
        let (wc, tabs) = windowOnHome()
        try enterChip(BrowserCommands.moveTabToSpace, typing: "move tab", in: wc)
        let listed = choices(wc)
        XCTAssertTrue(listed.contains(.space(reading.id)))
        XCTAssertTrue(listed.contains(.space(elsewhere.id)), "another profile's space, as the sidebar's Move to")
        XCTAssertFalse(listed.contains(.space(home.id)), "not the tab's own space")
        let expected = store.nonIncognitoSpaces.map(\.id).filter { $0 != home.id }.map(CommandArgument.space)
        XCTAssertEqual(listed, expected, "Settings › Spaces order")

        try type(reading.name, in: wc)
        XCTAssertEqual(choices(wc), [.space(reading.id)])
        try pressReturn(in: wc)
        XCTAssertNil(wc.commandPaletteView, "the palette is gone")
        XCTAssertTrue(reading.tabs.contains { $0.id == tabs[0].id }, "moved")
        XCTAssertFalse(home.tabs.contains { $0.id == tabs[0].id })
        XCTAssertEqual(wc.selectedTabID, tabs[1].id, "the selection settles on the tab left behind")
        XCTAssertTrue(wc.window?.firstResponder === tabs[1].webView, "the page has the keys, as after any command")
        XCTAssertEqual(store.undoManager.undoActionName, "Move to Space", "the sidebar's move, with its undo")
    }

    @MainActor func testMoveTabToSpaceMovesAPinnedEntry() throws {
        let (wc, tabs) = windowOnHome()
        store.pinTab(id: tabs[0].id, in: home)
        XCTAssertTrue(home.pinnedEntries.contains { $0.tab?.id == tabs[0].id }, "pinned")
        wc.selectTab(id: tabs[0].id)
        try enterChip(BrowserCommands.moveTabToSpace, typing: "move tab", in: wc)
        try type(reading.name, in: wc)
        try pressReturn(in: wc)
        XCTAssertTrue(reading.pinnedEntries.contains { $0.tab?.id == tabs[0].id }, "still pinned, in the other space")
        XCTAssertFalse(home.pinnedEntries.contains { $0.tab?.id == tabs[0].id })
    }

    @MainActor func testMoveTabToSpaceIsNotOfferedForASplit() throws {
        let (wc, tabs) = windowOnHome()
        store.createSplit(draggedTabID: tabs[1].id, targetTabID: tabs[0].id, edge: .right, in: home)
        wc.selectTab(id: tabs[0].id)
        wc.newTab(nil)
        try type(">move tab", in: wc)
        XCTAssertFalse(commandIDs(wc).contains(BrowserCommands.moveTabToSpace.id),
                       "the sidebar has no Move to for a split either")
    }

    // MARK: - Switch to Space

    @MainActor func testSwitchToSpaceSwitchesTheWindowToTheChoice() throws {
        let (wc, _) = windowOnHome()
        try enterChip(BrowserCommands.switchToSpace, typing: "switch to sp", in: wc)
        let expected = store.nonIncognitoSpaces.map(\.id).filter { $0 != home.id }.map(CommandArgument.space)
        XCTAssertEqual(choices(wc), expected, "the Spaces menu's spaces in its order, but the window's own")
        try type(elsewhere.name, in: wc)
        XCTAssertEqual(choices(wc), [.space(elsewhere.id)])
        try pressReturn(in: wc)
        XCTAssertNil(wc.commandPaletteView)
        spin { wc.activeSpaceID == elsewhere.id }
        XCTAssertEqual(wc.activeSpaceID, elsewhere.id)
    }

    @MainActor func testANormalWindowNeverListsAPrivateWindowsSpace() throws {
        let (privateWC, _) = try privateWindow(tabs: 1)
        let privateSpaceID = try XCTUnwrap(privateWC.activeSpaceID)
        let (wc, _) = windowOnHome()
        for command in [BrowserCommands.switchToSpace, BrowserCommands.moveTabToSpace] {
            XCTAssertFalse(wc.commandChoices(for: command.id).contains { $0.argument == .space(privateSpaceID) },
                           "\(command.id)")
        }
    }

    // MARK: - Split with Tab

    @MainActor func testSplitWithTabListsTheSpacesOtherTabsAndFormsTheSplit() throws {
        let (wc, tabs) = windowOnHome(tabs: 3)
        try enterChip(BrowserCommands.splitWithTab, typing: "split with", in: wc)
        XCTAssertEqual(choices(wc), home.tabs.map(\.id).filter { $0 != tabs[0].id }.map(CommandArgument.tab),
                       "the space's other tabs in sidebar order, not the selected one")
        // Matched by its address as well as its title.
        try type("tab2", in: wc)
        XCTAssertEqual(choices(wc), [.tab(tabs[2].id)])
        try pressReturn(in: wc)
        XCTAssertNil(wc.commandPaletteView)
        XCTAssertNotNil(tabs[0].splitGroupID)
        XCTAssertEqual(tabs[0].splitGroupID, tabs[2].splitGroupID, "split with the chosen tab")
        let index = try XCTUnwrap(home.tabs.firstIndex { $0.id == tabs[0].id })
        XCTAssertEqual(home.tabs[index + 1].id, tabs[2].id, "to its right, as Split with Next Tab")
        XCTAssertEqual(wc.selectedTabID, tabs[0].id)
        XCTAssertTrue(wc.window?.firstResponder === tabs[0].webView,
                      "the focused pane has the keys: the split re-hosts its web view, which drops focus")
    }

    /// The choices were read when the chip opened; one gone by Return (the
    /// tab closed meanwhile) is refused, with a beep, not run on nothing.
    @MainActor func testAChoiceGoneBeforeReturnIsRefused() throws {
        let (wc, tabs) = windowOnHome(tabs: 3)
        try enterChip(BrowserCommands.splitWithTab, typing: "split with", in: wc)
        try type("tab2", in: wc)
        XCTAssertEqual(choices(wc), [.tab(tabs[2].id)])
        store.closeTab(id: tabs[2].id, in: home)
        try pressReturn(in: wc)
        XCTAssertNil(wc.commandPaletteView)
        XCTAssertNil(tabs[0].splitGroupID, "nothing split")
        XCTAssertEqual(wc.selectedTabID, tabs[0].id)
    }

    // MARK: - A Private window

    @MainActor func testAPrivateWindowOffersNoSpaceCommandsAndSplitsOnlyItsOwnTabs() throws {
        let (_, normalTabs) = windowOnHome()
        let (wc, tabs) = try privateWindow(tabs: 2)
        XCTAssertEqual(wc.commandChoices(for: BrowserCommands.switchToSpace.id), [])
        XCTAssertEqual(wc.commandChoices(for: BrowserCommands.moveTabToSpace.id), [])

        wc.newTab(nil)
        try type(">space", in: wc)
        let offered = commandIDs(wc)
        XCTAssertFalse(offered.contains(BrowserCommands.switchToSpace.id))
        XCTAssertFalse(offered.contains(BrowserCommands.moveTabToSpace.id))
        wc.dismissCommandPalette()

        try enterChip(BrowserCommands.splitWithTab, typing: "split with", in: wc)
        XCTAssertEqual(choices(wc), [.tab(tabs[1].id)], "its own space's other tab, no other window's")
        XCTAssertFalse(choices(wc).contains { normalTabs.map { .tab($0.id) }.contains($0) })
        try pressReturn(in: wc)
        XCTAssertNil(wc.commandPaletteView)
        XCTAssertNotNil(tabs[0].splitGroupID)
        XCTAssertEqual(tabs[0].splitGroupID, tabs[1].splitGroupID)
    }
}
