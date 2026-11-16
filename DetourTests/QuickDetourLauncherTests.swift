import XCTest
import WebKit
@testable import Detour

/// The launcher panel (TASK-193.1, as changed on 2026-10-25): Opt-Cmd-N shows
/// the command palette alone in a panel, like Spotlight. Submitting closes it
/// and opens the Quick Detour window loading the page; Escape or clicking
/// away closes it and opens nothing, so no window ever has an empty page.
nonisolated final class QuickDetourLauncherTests: XCTestCase {

    private var launcher: QuickDetourLauncher!
    private var opened: [(profile: Profile, url: URL, typed: Bool)] = []
    private var createdProfiles: [Profile] = []
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        launcher = QuickDetourLauncher()
        launcher.openWindow = { [unowned self] profile, _, url, typed in
            self.opened.append((profile, url, typed))
        }
    }

    @MainActor override func tearDown() async throws {
        launcher.close()
        launcher = nil
        opened.removeAll()
        for profile in createdProfiles {
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        try await super.tearDown()
    }

    @MainActor private func makeProfile() -> Profile {
        let profile = TabStore.shared.addProfile(name: "Quick Detour Launcher \(UUID().uuidString.prefix(4))")
        createdProfiles.append(profile)
        return profile
    }

    // MARK: - The panel

    @MainActor func testShowingOpensAPalettePanelAndNoWindow() throws {
        let profile = makeProfile()
        let windowsBefore = QuickDetourWindowController.openControllers.count
        let tabsBefore = TabStore.shared.quickDetourTabs.count

        launcher.show(profile: profile, sourceSpace: nil)

        let panel = try XCTUnwrap(launcher.panel)
        XCTAssertTrue(launcher.isShowing)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.canBecomeKey, "it takes typing straight away")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel),
                      "it can take the keyboard while another app stays active (TASK-193.2)")
        XCTAssertFalse(panel.styleMask.contains(.titled), "no title bar")
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .floating)
        let palette = try XCTUnwrap(launcher.palette)
        XCTAssertTrue(palette.isDescendant(of: try XCTUnwrap(panel.contentView)))
        XCTAssertTrue(palette.profile === profile)
        XCTAssertNil(palette.tabStore, "no open tabs: switching to one would open no Quick Detour")
        XCTAssertEqual(palette.historySpaceIDs, PaletteTabScope.historySpaceIDs(profile: profile, in: .shared),
                       "the profile's history, as its History page has it (TASK-209)")
        XCTAssertEqual(QuickDetourWindowController.openControllers.count, windowsBefore, "no window yet")
        XCTAssertEqual(TabStore.shared.quickDetourTabs.count, tabsBefore, "no page yet")
    }

    /// TASK-209: the whole profile's history, whichever window it was asked
    /// from; never the source window's profile's when that is another one.
    @MainActor func testThePaletteSuggestsFromTheWholeProfile() throws {
        let profile = makeProfile()
        let other = makeProfile()
        let space = TabStore.shared.addSpace(name: "Launcher Source", emoji: "L", colorHex: "007AFF",
                                             profileID: profile.id)
        let sibling = TabStore.shared.addSpace(name: "Launcher Sibling", emoji: "S", colorHex: "007AFF",
                                               profileID: profile.id)
        let otherSpace = TabStore.shared.addSpace(name: "Launcher Other", emoji: "O", colorHex: "007AFF",
                                                  profileID: other.id)
        defer {
            for id in [space.id, sibling.id, otherSpace.id] { TabStore.shared.forceRemoveSpace(id: id) }
        }

        launcher.show(profile: profile, sourceSpace: space)
        XCTAssertEqual(Set(launcher.palette?.historySpaceIDs ?? []),
                       [space.id.uuidString, sibling.id.uuidString,
                        QuickDetour.historySpaceIDString(forProfileID: profile.id)])
        launcher.close()

        launcher.show(profile: profile, sourceSpace: otherSpace)
        XCTAssertEqual(Set(launcher.palette?.historySpaceIDs ?? []),
                       [space.id.uuidString, sibling.id.uuidString,
                        QuickDetour.historySpaceIDString(forProfileID: profile.id)],
                       "asked from another profile's window: still this profile's history only")
    }

    @MainActor func testAPrivateLauncherHasNoHistory() throws {
        launcher.show(profile: TabStore.shared.ensureIncognitoProfile(), sourceSpace: nil)
        XCTAssertEqual(launcher.palette?.historySpaceIDs, [])
    }

    @MainActor func testSubmittingAURLClosesThePanelAndOpensTheWindowLoadingIt() throws {
        let profile = makeProfile()
        launcher.show(profile: profile, sourceSpace: nil)
        let palette = try XCTUnwrap(launcher.palette)

        launcher.commandPalette(palette, didSubmitInput: "https://example.com/page")

        XCTAssertFalse(launcher.isShowing)
        XCTAssertNil(launcher.panel)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first?.profile === profile)
        XCTAssertEqual(opened.first?.url, URL(string: "https://example.com/page"))
        XCTAssertEqual(opened.first?.typed, true, "a typed URL is a typed visit")
    }

    @MainActor func testASearchUsesTheProfilesEngine() throws {
        let profile = makeProfile()
        launcher.show(profile: profile, sourceSpace: nil)
        let palette = try XCTUnwrap(launcher.palette)

        launcher.commandPalette(palette, didSubmitInput: "quick lookup words")

        XCTAssertEqual(opened.map(\.url), [profile.searchEngine.searchURL(for: "quick lookup words")].compactMap { $0 })
        XCTAssertEqual(opened.first?.typed, false)
    }

    @MainActor func testChoosingASearchSuggestionOpensIt() throws {
        let profile = makeProfile()
        launcher.show(profile: profile, sourceSpace: nil)
        let palette = try XCTUnwrap(launcher.palette)

        launcher.commandPalette(palette, didSubmitSearch: "suggested")

        XCTAssertEqual(opened.map(\.url), [profile.searchEngine.searchURL(for: "suggested")].compactMap { $0 })
        XCTAssertFalse(launcher.isShowing)
    }

    @MainActor func testEscapeClosesThePanelAndOpensNothing() throws {
        launcher.show(profile: makeProfile(), sourceSpace: nil)

        // What Escape on an empty field ends in (`CommandPaletteView.dismiss`).
        launcher.palette?.dismiss()

        XCTAssertFalse(launcher.isShowing)
        XCTAssertNil(launcher.panel)
        XCTAssertTrue(opened.isEmpty)
    }

    @MainActor func testClickingAwayClosesThePanelAndOpensNothing() throws {
        launcher.show(profile: makeProfile(), sourceSpace: nil)
        let panel = try XCTUnwrap(launcher.panel)

        // The panel resigning key: another window or app was clicked.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)

        XCTAssertFalse(launcher.isShowing)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(opened.isEmpty)
    }

    @MainActor func testShowingAgainKeepsOnePanel() throws {
        let profile = makeProfile()
        launcher.show(profile: profile, sourceSpace: nil)
        let first = try XCTUnwrap(launcher.panel)

        launcher.show(profile: profile, sourceSpace: nil)

        XCTAssertTrue(launcher.panel === first, "Opt-Cmd-N again brings the open panel forward")
    }

    @MainActor func testShowingForAnotherProfileReplacesThePanel() throws {
        launcher.show(profile: makeProfile(), sourceSpace: nil)
        let other = makeProfile()

        launcher.show(profile: other, sourceSpace: nil)

        XCTAssertTrue(launcher.palette?.profile === other)
    }

    /// With nothing of its own window behind it, the palette's glass would
    /// show whatever the screen has there and read light over a light window
    /// in dark mode; the panel tints it to the appearance.
    @MainActor func testThePanelsGlassIsTintedToTheAppearance() throws {
        launcher.show(profile: makeProfile(), sourceSpace: nil)
        XCTAssertTrue(launcher.palette?.glassTint === QuickDetourPalettePanel.glassTint)

        func white(in name: NSAppearance.Name) -> CGFloat {
            var value: CGFloat = -1
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                value = QuickDetourPalettePanel.glassTint.usingColorSpace(.deviceGray)?.whiteComponent ?? -1
            }
            return value
        }
        XCTAssertLessThan(white(in: .darkAqua), 0.3, "dark in dark mode")
        XCTAssertGreaterThan(white(in: .aqua), 0.8, "light in light mode")
    }

    // MARK: - Placement

    @MainActor func testThePanelIsCentredOnTheScreen() {
        let frame = QuickDetour.panelFrame(size: NSSize(width: 540, height: 400),
                                           in: NSRect(x: 100, y: 50, width: 1440, height: 875))
        XCTAssertEqual(frame, NSRect(x: 550, y: 288, width: 540, height: 400))
    }

    // MARK: - End to end

    /// The production `openWindow`: the window opens loading the page, so its
    /// page is never empty.
    @MainActor func testTheRealWindowOpensWithThePage() throws {
        let profile = makeProfile()
        let real = QuickDetourLauncher()
        real.show(profile: profile, sourceSpace: nil)
        let palette = try XCTUnwrap(real.palette)
        let before = QuickDetourWindowController.openControllers.count

        real.commandPalette(palette, didSubmitInput: "https://quick-detour.invalid/")

        let controller = try XCTUnwrap(QuickDetourWindowController.openControllers.last)
        defer { controller.close() }
        XCTAssertEqual(QuickDetourWindowController.openControllers.count, before + 1)
        XCTAssertNotNil(controller.tab?.url, "the window never shows an empty page")
        XCTAssertNil(controller.commandPaletteView, "and no palette of its own")
        XCTAssertTrue(controller.profile === profile)
    }

    // MARK: - Undo (TASK-346)

    private final class Counter { var undone = 0 }

    /// A close on the browser's undo list (`TabStore.undoManager`), counting
    /// its undo; the list is emptied again after the test.
    @MainActor private func seedBrowserUndo() -> Counter {
        let counter = Counter()
        let undoManager = TabStore.shared.undoManager
        undoManager.removeAllActions()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: counter) { $0.undone += 1 }
        undoManager.setActionName("Close Tab")
        undoManager.endUndoGrouping()
        undoManager.groupsByEvent = true
        addTeardownBlock { @MainActor in TabStore.shared.undoManager.removeAllActions() }
        return counter
    }

    @MainActor private func validated(_ command: BrowserCommand, in panel: NSWindow) -> (NSMenuItem, Bool) {
        let item = NSMenuItem(title: command.title, action: command.action, keyEquivalent: "")
        return (item, panel.validateMenuItem(item))
    }

    /// ⌘Z / ⇧⌘Z and Edit > Undo / Redo in the launcher's field undo and redo
    /// its typing, titled from it, and do nothing when there is none; with a
    /// closed tab on the browser's list, that list is never reached (before,
    /// the actions fell through to the main window, a browser window, and
    /// reopened the tab).
    @MainActor func testUndoInTheLauncherIsItsFieldsAndNeverTheBrowsers() throws {
        let browser = seedBrowserUndo()
        launcher.show(profile: makeProfile(), sourceSpace: nil)
        let panel = try XCTUnwrap(launcher.panel)
        try XCTSkipIf(!panel.isKeyWindow, "the panel is not key in this run")
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView, "the palette's field is being edited")
        XCTAssertTrue(editor.allowsUndo, "the field editor records typing")

        // The actions stop at the panel, whichever window is main.
        for command in [BrowserCommands.undo, BrowserCommands.redo] {
            XCTAssertTrue(CommandDispatch.responderTarget(for: command.action, in: panel) === panel, "\(command.id)")
        }

        // Nothing typed: disabled, plain titles, and nothing happens.
        var (item, enabled) = validated(BrowserCommands.undo, in: panel)
        XCTAssertFalse(enabled)
        XCTAssertEqual(item.title, "Undo")
        panel.browserUndo(item)
        XCTAssertEqual(browser.undone, 0)

        editor.insertText("qd", replacementRange: NSRange(location: NSNotFound, length: 0))
        // The typing's undo group closes with the event loop's turn.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(editor.string, "qd")
        XCTAssertTrue(panel.fieldUndoManager !== TabStore.shared.undoManager)
        (item, enabled) = validated(BrowserCommands.undo, in: panel)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Typing")
        panel.browserUndo(item)
        XCTAssertEqual(editor.string, "")

        (item, enabled) = validated(BrowserCommands.redo, in: panel)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Redo Typing")
        panel.browserRedo(item)
        XCTAssertEqual(editor.string, "qd")

        XCTAssertEqual(browser.undone, 0, "TabStore's list is never reached from the launcher")
        XCTAssertTrue(TabStore.shared.undoManager.canUndo, "the closed tab is still there to reopen")
    }

    // MARK: - Browser-window commands (TASK-348)

    /// Every command a window controller answers (the registry's
    /// `.windowController` commands: Close Tab, New Tab, Reopen Closed Tab,
    /// Pin, Reload, History…) stops at the panel, so none falls through to the
    /// main window behind it (measured before the fix: ⌘W closed a tab there,
    /// ⇧⌘T reopened one, ⌘D pinned one, ⌘Y opened History, ⌘T and ⌘L opened
    /// its palette). Close Tab closes the launcher; Undo and Redo are the
    /// field's (TASK-346); every other one is disabled. Read from the
    /// registry, so a command added later is covered too.
    @MainActor func testEveryBrowserWindowCommandStopsAtTheLauncher() throws {
        launcher.show(profile: makeProfile(), sourceSpace: nil)
        let panel = try XCTUnwrap(launcher.panel)
        let commands = BrowserCommands.all.filter {
            if case .windowController = $0.responder { return true }
            return false
        }
        XCTAssertGreaterThan(commands.count, 30)
        for command in commands {
            let target = CommandDispatch.responderTarget(for: command.action, in: panel)
            XCTAssertTrue(target === panel, "\(command.id) stops at the panel, not \(String(describing: target))")
            let item = command.makeMenuItem()
            // As a browser window may have left it ("Unpin Tab").
            if command.contextualTitle != nil { item.title = "Retitled by a browser window" }
            let enabled = panel.validateMenuItem(item)
            if command.contextualTitle != nil {
                XCTAssertEqual(item.title, command.title, "\(command.id) is not left with a browser window's title")
            }
            switch command.id {
            case BrowserCommands.closeTab.id:
                XCTAssertTrue(enabled, "Close Tab closes the launcher")
                XCTAssertEqual(item.title, "Close Tab", "not retitled: browser windows do not retitle it back")
            default:
                XCTAssertFalse(enabled, "\(command.id) is disabled in the launcher (nothing typed for Undo/Redo)")
            }
        }

        // The app's own commands still reach the app delegate (⌥⌘N toggles
        // the launcher, ⌘N opens a window) and AppKit's text items the field.
        for command in [BrowserCommands.newQuickDetourWindow, BrowserCommands.newWindow, BrowserCommands.settings] {
            XCTAssertTrue(CommandDispatch.responderTarget(for: command.action, in: panel) === NSApp.delegate,
                          "\(command.id)")
        }
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView, "the palette's field is being edited")
        XCTAssertTrue(CommandDispatch.responderTarget(for: BrowserCommands.paste.action, in: panel) === editor)
    }

    /// ⌘W in the launcher with a tab open in the browser window behind it:
    /// the launcher closes and opens nothing; the browser window keeps its
    /// tab.
    @MainActor func testCloseTabInTheLauncherClosesItAndLeavesTheBrowserWindowsTab() throws {
        let wc = BrowserWindowController(incognito: true)
        wc.sidebarSplitView.autosaveName = nil
        let browserWindow = try XCTUnwrap(wc.window)
        browserWindow.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in browserWindow.close() }
        let space = try XCTUnwrap(wc.activeSpace)
        let tab = TabStore.shared.addTab(in: space, url: URL(string: "about:blank"))
        wc.selectTab(id: tab.id)
        browserWindow.makeKeyAndOrderFront(nil)
        let tabsBefore = space.tabs.map(\.id)
        XCTAssertTrue(tabsBefore.contains(tab.id))

        launcher.show(profile: makeProfile(), sourceSpace: space)
        let panel = try XCTUnwrap(launcher.panel)
        let close = BrowserCommands.closeTab
        let item = close.makeMenuItem()
        XCTAssertTrue(CommandDispatch.responderTarget(for: close.action, in: panel) === panel)
        // With the panel key and the browser window main, as at runtime, the
        // menu's own resolution (key window's chain, then the main window's)
        // stops at the panel too.
        if panel.isKeyWindow, browserWindow.isMainWindow {
            XCTAssertTrue(NSApp.target(forAction: close.action, to: nil, from: item) as AnyObject === panel)
        }

        XCTAssertTrue(CommandDispatch.perform(close, in: panel, menu: NSApp.mainMenu), "⌘W is answered in the launcher")

        XCTAssertFalse(launcher.isShowing, "the launcher closed")
        XCTAssertNil(launcher.panel)
        XCTAssertTrue(opened.isEmpty, "nothing opened")
        XCTAssertEqual(space.tabs.map(\.id), tabsBefore, "the browser window's tab is still open")
        XCTAssertEqual(wc.selectedTabID, tab.id)
    }
}
