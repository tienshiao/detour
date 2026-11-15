import XCTest
import AppKit
@testable import Detour

/// TASK-320: the palette's browser commands in real windows. A window's
/// palette offers exactly the palette commands whose main-menu item is
/// enabled in that window (AC #4: by the same rule), in a normal window, a
/// Private window, a Quick Detour and a quarantine; rows show the live
/// item's shortcut; Return runs the command through its menu item and the
/// palette is gone.
///
/// Real windows on `TabStore.shared` with a profile of the test's own; pages
/// are `.invalid` hosts. The field is driven as the field editor drives it.
nonisolated final class PaletteCommandWindowTests: XCTestCase {

    @MainActor private var store: TabStore { .shared }
    private var profile: Profile!
    private var space: Space!
    private var windows: [BrowserWindowController] = []
    private var quickDetours: [QuickDetourWindowController] = []
    private var pasteboard: NSPasteboard!
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        profile = store.addProfile(name: "Palette Commands \(UUID().uuidString.prefix(4))")
        space = store.addSpace(name: "Commands", emoji: "⌘", colorHex: "007AFF", profileID: profile.id)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("DetourTests.paletteCommands.\(UUID().uuidString)"))
        store.undoManager.removeAllActions()
    }

    @MainActor override func tearDown() async throws {
        pasteboard.releaseGlobally()
        for controller in quickDetours {
            controller.dismissPalette()
            controller.closeDisposition = .discard
            controller.close()
        }
        quickDetours.removeAll()
        for wc in windows {
            wc.dismissCommandPalette(restoringFocus: false)
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for tab in space.tabs { tab.teardown() }
        for entry in space.pinnedEntries { entry.tab?.teardown() }
        store.forceRemoveSpace(id: space.id)
        store.forceRemoveProfile(id: profile.id)
        AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        Self.retainedProfiles.append(profile)
        store.undoManager.removeAllActions()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    @MainActor private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor private func windowWithPage() -> (BrowserWindowController, BrowserTab) {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        windows.append(wc)
        let tab = store.addTab(in: space, url: URL(string: "https://palette-commands.invalid/page")!)
        wc.selectTab(id: tab.id)
        return (wc, tab)
    }

    @MainActor private func privateWindowWithPage() throws -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: true)
        wc.sidebarSplitView.autosaveName = nil
        wc.showWindow(nil)
        windows.append(wc)
        let tab = store.addTab(in: try XCTUnwrap(wc.activeSpace), url: URL(string: "https://palette-commands.invalid/private")!)
        wc.selectTab(id: tab.id)
        return wc
    }

    @MainActor private func quickDetour(quarantine: Bool = false) -> QuickDetourWindowController {
        let url = URL(string: "https://palette-commands.invalid/quick")!
        let controller = quarantine
            ? QuickDetourWindowController.openQuarantine(url: url, privateProfile: store.ensureIncognitoProfile(),
                                                         sourceSpace: space)
            : QuickDetourWindowController.open(profile: profile, sourceSpace: space, url: url)
        quickDetours.append(controller)
        return controller
    }

    @MainActor private func fieldEditor(of window: NSWindow?) throws -> NSTextView {
        try XCTUnwrap(window?.firstResponder as? NSTextView, "the palette's field is being edited")
    }

    @MainActor private func type(_ text: String, in window: NSWindow?) throws {
        let editor = try fieldEditor(of: window)
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    @MainActor private func pressReturn(in window: NSWindow?) throws {
        try fieldEditor(of: window).doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    @MainActor private func commandRows(_ palette: CommandPaletteView?) -> [PaletteCommand] {
        (palette?.suggestions ?? []).compactMap { if case .command(let command) = $0 { return command } else { return nil } }
    }

    /// The palette commands whose main-menu item is enabled in `window`,
    /// resolved as `run_menu_item` resolves it, with the window itself first
    /// responder (as after the palette is dismissed and before the page
    /// takes the keys back), in registry order. A parameterised command has
    /// no item of its own (TASK-320 AC #3): it is expected when the window's
    /// rule holds and it has a value to choose (`PaletteCommandChipWindowTests`
    /// checks the values).
    @MainActor private func menuEnabledPaletteCommands(in window: NSWindow,
                                                       context: any CommandContext) throws -> [CommandID] {
        window.makeFirstResponder(nil)
        let menu = try XCTUnwrap(NSApp.mainMenu)
        return BrowserCommands.all.filter { command in
            guard command.palette.isOffered else { return false }
            if command.choiceParameter != nil {
                return command.isAvailable(in: context) && !context.commandChoices(for: command.id).isEmpty
            }
            guard let item = CommandDispatch.menuItem(for: command.id, in: menu) else { return false }
            return (try? AutomationMenus.resolve(item, in: window, allowPrivate: true)) != nil
        }.map(\.id)
    }

    // MARK: - What each window offers is what its menu enables

    @MainActor func testANormalWindowsPaletteOffersWhatItsMenuEnables() throws {
        let (wc, _) = windowWithPage()
        spin()
        let window = try XCTUnwrap(wc.window)
        let expected = try menuEnabledPaletteCommands(in: window, context: wc)
        wc.newTab(nil)
        try type(">", in: window)
        XCTAssertEqual(commandRows(wc.commandPaletteView).map(\.id), expected)
        XCTAssertTrue(expected.contains("tab.toggle-pin"))
        XCTAssertTrue(expected.contains("archive.show"))
        XCTAssertFalse(expected.contains("tab.new"), "opens the palette: not offered in it")
        let pin = try XCTUnwrap(commandRows(wc.commandPaletteView).first { $0.id == "tab.toggle-pin" })
        XCTAssertEqual(pin.title, "Pin Tab")
        XCTAssertEqual(pin.keyEquivalent, "⌘D")
    }

    @MainActor func testAPrivateWindowsPaletteOffersWhatItsMenuEnables() throws {
        let wc = try privateWindowWithPage()
        spin()
        let window = try XCTUnwrap(wc.window)
        let expected = try menuEnabledPaletteCommands(in: window, context: wc)
        wc.newTab(nil)
        try type(">", in: window)
        let offered = commandRows(wc.commandPaletteView).map(\.id)
        XCTAssertEqual(offered, expected)
        for id: CommandID in ["tab.toggle-pin", "archive.show", "archive.clear", "space.next", "space.previous",
                              "space.manage"] {
            XCTAssertFalse(offered.contains(id), "\(id) is disabled in a Private window's menu")
        }
        XCTAssertTrue(offered.contains("window.new"))
        XCTAssertTrue(offered.contains("page.reload"))
    }

    @MainActor func testAQuickDetoursPaletteOffersWhatItsMenuEnables() throws {
        let controller = quickDetour()
        spin(0.2)
        let window = try XCTUnwrap(controller.window)
        let expected = try menuEnabledPaletteCommands(in: window, context: controller)
        controller.showPalette(prefill: nil)
        try type(">", in: window)
        let offered = commandRows(controller.commandPaletteView).map(\.id)
        XCTAssertEqual(offered, expected)
        XCTAssertTrue(offered.contains("page.reload"))
        XCTAssertTrue(offered.contains("page.open-in-space"))
        XCTAssertEqual(commandRows(controller.commandPaletteView).first { $0.id == "page.open-in-space" }?.title,
                       "Open in ⌘ Commands", "the title its menu item has in this window")
        for id: CommandID in ["sidebar.toggle", "history.show", "tab.toggle-pin", "tab.next"] {
            XCTAssertFalse(offered.contains(id), "\(id) is not answered in a Quick Detour")
        }
    }

    @MainActor func testAQuarantinesPaletteOffersWhatItsMenuEnables() throws {
        let controller = quickDetour(quarantine: true)
        spin(0.2)
        let window = try XCTUnwrap(controller.window)
        let expected = try menuEnabledPaletteCommands(in: window, context: controller)
        controller.showPalette(prefill: nil)
        try type(">", in: window)
        XCTAssertEqual(commandRows(controller.commandPaletteView).map(\.id), expected)
    }

    // MARK: - Running a command

    @MainActor func testReturnRunsTheCommandThroughItsMenuItemAndThePaletteGoes() throws {
        let (wc, tab) = windowWithPage()
        spin()
        let window = try XCTUnwrap(wc.window)
        wc.newTab(nil)
        try type(">pin", in: window)
        XCTAssertEqual(commandRows(wc.commandPaletteView).first?.id, "tab.toggle-pin")
        try pressReturn(in: window)
        XCTAssertNil(wc.commandPaletteView)
        XCTAssertTrue(space.pinnedEntries.contains { $0.tab?.id == tab.id }, "pinned")

        wc.focusAddressBar(nil)
        try type(">unpin", in: window)
        XCTAssertEqual(commandRows(wc.commandPaletteView).first?.title, "Unpin Tab")
        try pressReturn(in: window)
        XCTAssertFalse(space.pinnedEntries.contains { $0.tab?.id == tab.id }, "unpinned")
    }

    /// `NSWindow` declares `selectNextTab:` itself (window tabbing) and is in
    /// front of the controller in the responder chain. Whether a Detour
    /// window takes it is not shown here (the class responds; the menu's
    /// resolution follows the controller's rule), but the command must reach
    /// the controller whose rule offered it either way.
    @MainActor func testNextTabRunsInTheControllerNotTheWindowsOwnTabbing() throws {
        let (wc, first) = windowWithPage()
        let second = store.addTab(in: space, url: URL(string: "https://palette-commands.invalid/second")!)
        wc.selectTab(id: first.id)
        spin()
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(NSWindow.instancesRespond(to: BrowserCommands.nextTab.action), "why the controller is named")
        wc.newTab(nil)
        try type(">next tab", in: window)
        XCTAssertEqual(commandRows(wc.commandPaletteView).first?.id, "tab.next")
        try pressReturn(in: window)
        XCTAssertNil(wc.commandPaletteView)
        XCTAssertEqual(wc.selectedTabID, second.id)
    }

    /// With the page focused, `WKWebView`'s own `goBack:` is ahead of the
    /// controller in the responder chain, and has no history item to go back
    /// to on a tab opened from another (TASK-325; `BrowserWebView` hands it to
    /// the controller since TASK-331). The palette's Back goes to the
    /// controller, whose rule offered it, so it closes the tab to its opener.
    @MainActor func testBackFromThePaletteClosesAChildTabToItsOpener() throws {
        let (wc, opener) = windowWithPage()
        let child = store.addTab(in: space, url: URL(string: "https://palette-commands.invalid/child")!,
                                 parentID: opener.id)
        wc.selectTab(id: child.id)
        spin()
        let window = try XCTUnwrap(wc.window)
        wc.newTab(nil)
        try type(">back", in: window)
        XCTAssertEqual(commandRows(wc.commandPaletteView).first?.id, "page.back")
        try pressReturn(in: window)
        XCTAssertNil(wc.commandPaletteView)
        XCTAssertFalse(space.tabs.contains { $0.id == child.id }, "closed")
        XCTAssertEqual(wc.selectedTabID, opener.id, "to its opener")
    }

    @MainActor func testTypedTextRanksACommandInAfterTheVerbatimRow() throws {
        let (wc, _) = windowWithPage()
        spin()
        let window = try XCTUnwrap(wc.window)
        wc.newTab(nil)
        try type("toggle side", in: window)
        let rows = try XCTUnwrap(wc.commandPaletteView?.suggestions)
        let verbatim = try XCTUnwrap(rows.firstIndex(of: .searchInput(text: "toggle side")))
        guard case .command(let command) = rows[verbatim + 1] else {
            return XCTFail("no command after the verbatim row: \(rows)")
        }
        XCTAssertEqual(command.id, "sidebar.toggle")
        XCTAssertEqual(command.keyEquivalent, "⌘S")
    }

    @MainActor func testAQuickDetoursCommandRunsInItsOwnWindow() throws {
        let controller = quickDetour()
        controller.urlPasteboard = pasteboard
        spin(0.2)
        let window = try XCTUnwrap(controller.window)
        controller.showPalette(prefill: nil)
        try type(">copy url", in: window)
        XCTAssertEqual(commandRows(controller.commandPaletteView).first?.id, "tab.copy-url")
        try pressReturn(in: window)
        XCTAssertNil(controller.commandPaletteView)
        XCTAssertEqual(pasteboard.string(forType: .string), "https://palette-commands.invalid/quick")
    }
}
