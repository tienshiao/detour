import XCTest
import AppKit
@testable import Detour

/// TASK-327: a user's shortcut on the menus that ship. The test host runs
/// `applicationDidFinishLaunching`, so `NSApp.mainMenu` is the real menu bar
/// and the app delegate applies `ShortcutBindingStore.shared` to it. That
/// store is the test host's own defaults suite (its data directory's), and
/// every test here restores it, so the other suites see the built-in
/// shortcuts (`MainMenuCharacterizationTests` pins them).
nonisolated final class ShortcutMenuTests: XCTestCase {

    @MainActor private var store: ShortcutBindingStore { .shared }

    @MainActor override func setUp() async throws {
        try await super.setUp()
        store.resetAll()
    }

    @MainActor override func tearDown() async throws {
        store.resetAll()
        try await super.tearDown()
    }

    @MainActor private func liveItem(_ command: BrowserCommand) throws -> NSMenuItem {
        try XCTUnwrap(CommandDispatch.menuItem(for: command.id, in: NSApp.mainMenu), "\(command.id)")
    }

    @MainActor private func barMenu(_ title: String) throws -> NSMenu {
        let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == title }
        return try XCTUnwrap(menu, title)
    }

    @MainActor private func keyEvent(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: 0)!
    }

    // MARK: - The menu item

    @MainActor func testABindingReachesTheMenuItemAtOnce() throws {
        let reload = try liveItem(BrowserCommands.reload)
        store.setKeyEquivalent(KeyEquivalent("e", [.command, .option]), for: BrowserCommands.reload.id)
        XCTAssertEqual(reload.keyEquivalent, "e")
        XCTAssertEqual(reload.keyEquivalentModifierMask, [.command, .option])

        // AppKit's own matching of the View menu: the new key, not the old one.
        let view = try barMenu("View")
        XCTAssertTrue(MenuKeyEquivalentMatcher.item(matching: keyEvent("e", [.command, .option]), in: view.items) === reload)
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("r", [.command]), in: view.items))
    }

    @MainActor func testAClearedShortcutLeavesTheItemWithNone() throws {
        let closeTab = try liveItem(BrowserCommands.closeTab)
        store.setKeyEquivalent(nil, for: BrowserCommands.closeTab.id)
        XCTAssertEqual(closeTab.keyEquivalent, "")
        XCTAssertNil(CommandDispatch.keyEquivalentLabel(for: BrowserCommands.closeTab, in: NSApp.mainMenu))
    }

    @MainActor func testACommandWithNoShortcutGetsOneAndRestoreDefaultsTakesItAway() throws {
        let importItem = try liveItem(BrowserCommands.importFromArc)
        store.setKeyEquivalent(KeyEquivalent("\u{F708}", []), for: BrowserCommands.importFromArc.id)
        XCTAssertEqual(importItem.keyEquivalent, "\u{F708}")
        XCTAssertEqual(CommandDispatch.keyEquivalentLabel(for: BrowserCommands.importFromArc, in: NSApp.mainMenu), "F5")

        store.resetAll()
        XCTAssertEqual(importItem.keyEquivalent, "")
        XCTAssertEqual(importItem.keyEquivalentModifierMask, [.command], "as an item built with none has")
    }

    @MainActor func testResetGivesTheItemItsBuiltInShortcutBack() throws {
        let redoLike = try liveItem(BrowserCommands.reopenClosedTab)
        store.setKeyEquivalent(KeyEquivalent("r", [.command, .control]), for: BrowserCommands.reopenClosedTab.id)
        store.reset(BrowserCommands.reopenClosedTab.id)
        XCTAssertEqual(redoLike.keyEquivalent, "t")
        XCTAssertEqual(redoLike.keyEquivalentModifierMask, [.command, .shift])
    }

    @MainActor func testTheQuickDetourItemIsNotTheStoresToWrite() throws {
        let item = try liveItem(BrowserCommands.newQuickDetourWindow)
        let before = (item.keyEquivalent, item.keyEquivalentModifierMask)
        store.setKeyEquivalent(KeyEquivalent("e", [.command, .option]), for: BrowserCommands.newQuickDetourWindow.id)
        store.apply(to: NSApp.mainMenu)
        XCTAssertEqual(item.keyEquivalent, before.0, "QuickDetourHotKey sets it from its own setting")
        XCTAssertEqual(item.keyEquivalentModifierMask, before.1)
    }

    // MARK: - Where else the shortcut shows

    @MainActor func testThePalettesShortcutColumnFollows() throws {
        store.setKeyEquivalent(KeyEquivalent("e", [.command, .option]), for: BrowserCommands.reload.id)
        XCTAssertEqual(CommandDispatch.keyEquivalentLabel(for: BrowserCommands.reload, in: NSApp.mainMenu), "⌥⌘E")
        let context = FakeContext()
        XCTAssertEqual(PaletteCommands.resolve(BrowserCommands.reload, in: context, menu: NSApp.mainMenu)?.keyEquivalent,
                       "⌥⌘E")
    }

    @MainActor func testAContextMenuItemShowsTheCommandsShortcut() {
        let copy = NSMenuItem(title: "Copy URL", action: nil, keyEquivalent: "")
        copy.showShortcut(ofCommand: BrowserCommands.copyURL.id)
        XCTAssertEqual(KeyEquivalent.displayString(key: copy.keyEquivalent, modifiers: copy.keyEquivalentModifierMask),
                       "⇧⌘C")
        store.setKeyEquivalent(KeyEquivalent("u", [.command, .control]), for: BrowserCommands.copyURL.id)
        copy.showShortcut(ofCommand: BrowserCommands.copyURL.id)
        XCTAssertEqual(KeyEquivalent.displayString(key: copy.keyEquivalent, modifiers: copy.keyEquivalentModifierMask),
                       "⌃⌘U")
        store.setKeyEquivalent(nil, for: BrowserCommands.copyURL.id)
        copy.showShortcut(ofCommand: BrowserCommands.copyURL.id)
        XCTAssertEqual(copy.keyEquivalent, "")
    }

    // MARK: - The TASK-56 fast path

    /// `menuHasKeyEquivalent` answers for the delegate-driven Spaces and
    /// Extensions menus from their live items, so a binding on one of their
    /// static items (a letter, which no built-in shortcut there is) is answered,
    /// and a cleared one is not.
    @MainActor func testTheFastPathAnswersABindingInADelegateDrivenMenu() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let extensions = try barMenu("Extensions")
        let event = keyEvent("E", [.command, .shift])
        func answer() -> Selector? {
            var target: AnyObject?
            var action: Selector?
            let handled = delegate.menuHasKeyEquivalent(extensions, for: event, target: &target, action: &action)
            return handled ? action : nil
        }
        XCTAssertNil(answer(), "nothing has ⇧⌘E by default")

        store.setKeyEquivalent(KeyEquivalent("e", [.command, .shift]), for: BrowserCommands.addExtensions.id)
        XCTAssertEqual(answer(), BrowserCommands.addExtensions.action)

        store.setKeyEquivalent(nil, for: BrowserCommands.addExtensions.id)
        XCTAssertNil(answer())
    }

    @MainActor func testTheFastPathSeesABindingOnSpacesManageSpaces() throws {
        let spaces = try barMenu("Spaces")
        let manage = try liveItem(BrowserCommands.manageSpaces)
        store.setKeyEquivalent(KeyEquivalent("m", [.command, .control]), for: BrowserCommands.manageSpaces.id)
        XCTAssertTrue(MenuKeyEquivalentMatcher.item(matching: keyEvent("m", [.command, .control]), in: spaces.items) === manage)
        store.reset(BrowserCommands.manageSpaces.id)
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("m", [.command, .control]), in: spaces.items))
    }

    // MARK: - The registry's menus

    /// Settings > Shortcuts groups the commands by `BrowserCommands.menus`;
    /// each command with an item is in the bar menu of that title.
    @MainActor func testTheRegistrysMenusAreTheMenuBarsMenus() throws {
        let bar = try XCTUnwrap(NSApp.mainMenu)
        var checked = 0
        for menu in BrowserCommands.menus {
            for command in menu.commands {
                guard let item = CommandDispatch.menuItem(for: command.id, in: bar) else { continue }
                var submenu = item.menu
                while let current = submenu, let parent = current.supermenu, parent !== bar { submenu = parent }
                let barItem = try XCTUnwrap(bar.items.first { $0.submenu === submenu }, "\(command.id)")
                XCTAssertEqual(AutomationMenus.displayTitle(barItem), menu.title, "\(command.id)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 40)
    }
}

/// A normal browser window with a page, for availability.
private struct FakeContext: CommandContext {
    var commandWindowKind: CommandWindowKind { .normal }
    var hasSelectedTab: Bool { true }
    var selectedTabHasURL: Bool { true }
}
