import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Detour

/// TASK-327: which shortcut a browser command may have. A key another
/// command's item holds (as the menu is now: bindings and App Shortcuts
/// included), the Quick Detour hotkey's, Detour's outside any menu, or
/// macOS's is refused and the holder named; a shortcut needs ⌘, ⌥ or ⌃
/// unless it is a function key.
nonisolated final class ShortcutConflictTests: XCTestCase {

    @MainActor private func shortcut(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags,
                                     _ character: String = "") -> HotKeyShortcut {
        HotKeyShortcut(keyCode: UInt16(keyCode), modifiers: modifiers, character: character)
    }

    @MainActor private func item(_ title: String, _ key: String, _ mask: NSEvent.ModifierFlags = [.command],
                                 id: CommandID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        item.identifier = id.map { NSUserInterfaceItemIdentifier($0.rawValue) }
        return item
    }

    /// A menu bar: the app menu (Settings… ⌘,), File (New Tab ⌘T, the Quick
    /// Detour item on its setting's ⌥⌘N), View (Reload Page ⌘R), Edit (Emoji &
    /// Symbols ⌃⌘Space, an item AppKit adds and no command is).
    @MainActor private func mainMenu() -> NSMenu {
        let main = NSMenu(title: "Main")
        func add(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            top.submenu = menu
            main.addItem(top)
        }
        add("", [item("Settings…", ",", id: BrowserCommands.settings.id)])
        add("File", [item("New Tab", "t", id: BrowserCommands.newTab.id),
                     item("New Quick Detour Window", "n", [.command, .option],
                          id: BrowserCommands.newQuickDetourWindow.id)])
        add("View", [item("Reload Page", "r", id: BrowserCommands.reload.id)])
        add("Edit", [item("Emoji & Symbols", " ", [.control, .command])])
        return main
    }

    /// The installed US layout, whatever layout the Mac is using, so the
    /// shifted characters are the same on every run (TASK-335).
    @MainActor private static let us = KeyboardLayout.installed(id: "com.apple.keylayout.US")
    @MainActor private static let french = KeyboardLayout.installed(id: "com.apple.keylayout.French")

    @MainActor private static func shifted(on layout: KeyboardLayout?) -> (UInt16) -> String {
        { layout?.character(forKeyCode: $0, shift: true) ?? "" }
    }

    @MainActor private func problem(_ shortcut: HotKeyShortcut, for id: CommandID = BrowserCommands.reload.id,
                                    menu: NSMenu? = nil, quickDetour: HotKeyShortcut? = .quickDetourDefault,
                                    system: [SystemHotKey] = [],
                                    layout: KeyboardLayout? = ShortcutConflictTests.us) -> HotKeyShortcutProblem? {
        HotKeyShortcutValidation.problem(
            for: shortcut, rules: .appShortcut, menu: menu ?? mainMenu(),
            isOwnItem: { item in
                let raw = item.identifier?.rawValue
                return raw == id.rawValue || raw == BrowserCommands.newQuickDetourWindow.id.rawValue
            },
            quickDetourShortcut: quickDetour, systemHotKeys: system, shiftedCharacter: Self.shifted(on: layout))
    }

    // MARK: - Modifiers

    @MainActor func testAShortcutNeedsCommandOptionOrControlUnlessItIsAFunctionKey() {
        XCTAssertEqual(problem(shortcut(kVK_ANSI_K, [], "k")), .needsModifierOrFunctionKey)
        XCTAssertEqual(problem(shortcut(kVK_ANSI_K, [.shift], "k")), .needsModifierOrFunctionKey)
        XCTAssertEqual(problem(shortcut(kVK_Return, [])), .needsModifierOrFunctionKey, "a named key is no function key")
        XCTAssertEqual(problem(shortcut(kVK_RightArrow, [.shift])), .needsModifierOrFunctionKey)
        XCTAssertNil(problem(shortcut(kVK_F5, [])), "a function key alone")
        XCTAssertNil(problem(shortcut(kVK_F19, [.shift])))
        XCTAssertEqual(problem(shortcut(kVK_ANSI_K, [.option], "k")), .needsModifierOrFunctionKey,
                       "⌥ alone types a character in a page's text field instead of firing")
        XCTAssertEqual(problem(shortcut(kVK_ANSI_K, [.option, .shift], "k")), .needsModifierOrFunctionKey)
        XCTAssertNil(problem(shortcut(kVK_ANSI_K, [.control], "k")))
        XCTAssertNil(problem(shortcut(kVK_ANSI_K, [.control, .option], "k")), "⌥ may join ⌘ or ⌃")
        XCTAssertNil(problem(shortcut(kVK_F5, [.option])), "a function key with ⌥")
        XCTAssertEqual(HotKeyShortcutValidation.message(for: .needsModifierOrFunctionKey, shortcut: shortcut(kVK_ANSI_K, [], "k")),
                       "Include ⌘ or ⌃ in the shortcut, or use a function key: with ⌥ alone, a text field types the character instead.")
    }

    @MainActor func testTheQuickDetourHotKeyStillNeedsAModifierOnAFunctionKey() {
        XCTAssertEqual(HotKeyShortcutValidation.problem(for: shortcut(kVK_F5, []), menu: nil, ownAction: nil,
                                                        systemHotKeys: []),
                       .needsModifier, "a global hotkey on F5 would take it from every app")
    }

    // MARK: - Another command

    @MainActor func testAKeyAnotherCommandHoldsIsRefusedWithItsMenuPath() {
        XCTAssertEqual(problem(shortcut(kVK_ANSI_T, [.command], "t")), .usedByMenu("File > New Tab"))
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Comma, [.command], ",")), .usedByMenu("Detour > Settings…"),
                       "the application menu by the app's name")
        XCTAssertEqual(HotKeyShortcutValidation.message(for: .usedByMenu("File > New Tab"),
                                                        shortcut: shortcut(kVK_ANSI_T, [.command], "t")),
                       "⌘T is the shortcut of File > New Tab.")
    }

    @MainActor func testACommandsOwnShortcutIsNoConflict() {
        XCTAssertNil(problem(shortcut(kVK_ANSI_R, [.command], "r")), "Reload Page recording ⌘R again")
        XCTAssertEqual(problem(shortcut(kVK_ANSI_R, [.command], "r"), for: BrowserCommands.newTab.id),
                       .usedByMenu("View > Reload Page"))
    }

    @MainActor func testAnItemThatIsNoCommandStillHoldsItsKey() {
        XCTAssertEqual(problem(shortcut(kVK_Space, [.control, .command], " ")), .usedByMenu("Edit > Emoji & Symbols"))
    }

    // MARK: - The Quick Detour hotkey

    @MainActor func testTheQuickDetourShortcutIsRefusedByItsName() {
        XCTAssertEqual(problem(.quickDetourDefault), .usedByQuickDetour)
        let hyper = shortcut(kVK_F12, [.control, .option, .command])
        XCTAssertEqual(problem(hyper, quickDetour: hyper), .usedByQuickDetour, "whatever it is set to")
        XCTAssertNil(problem(.quickDetourDefault, quickDetour: nil), "a cleared hotkey holds nothing")
        XCTAssertEqual(HotKeyShortcutValidation.message(for: .usedByQuickDetour, shortcut: .quickDetourDefault),
                       "⌥⌘N is the Quick Detour shortcut (Settings > Quick Detour).")
    }

    // MARK: - Detour outside menus, and macOS

    @MainActor func testDetoursKeysOutsideMenusAreRefused() {
        XCTAssertEqual(problem(shortcut(kVK_Tab, [.control])), .usedByDetour("switching to a recent tab"))
        // TASK-345: a page gets ⌘Z and ⇧⌘Z first, then the menu; nothing
        // holds them outside it (Edit > Undo and Redo do, in the real menu bar).
        XCTAssertNil(problem(shortcut(kVK_ANSI_Z, [.command], "z")))
        XCTAssertNil(problem(shortcut(kVK_ANSI_Z, [.command, .shift], "z")))
        XCTAssertNil(problem(shortcut(kVK_ANSI_Z, [.command, .option], "z")))
    }

    @MainActor func testMacOSShortcutsAreRefused() {
        let spotlight = SystemHotKey(keyCode: UInt16(kVK_Space), carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(problem(shortcut(kVK_Space, [.command], " "), system: [spotlight]), .usedBySystem)
        XCTAssertEqual(problem(shortcut(kVK_Tab, [.command])), .reservedBySystem("switching apps"))
        XCTAssertEqual(problem(shortcut(kVK_Escape, [.command, .option])), .reservedBySystem("Force Quit"))
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Q, [.control, .command], "q")), .reservedBySystem("Lock Screen"))
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Q, [.shift, .command], "q")), .reservedBySystem("Log Out"))
        XCTAssertEqual(HotKeyShortcutValidation.message(for: .reservedBySystem("Force Quit"),
                                                        shortcut: shortcut(kVK_Escape, [.command, .option])),
                       "⌥⌘⎋ is the macOS shortcut for Force Quit.")
        // A function key alone that macOS lists (with the Fn bit) too.
        let showDesktop = SystemHotKey(keyCode: UInt16(kVK_F11), carbonModifiers: 1 << 17)
        XCTAssertEqual(problem(shortcut(kVK_F11, []), system: [showDesktop]), .usedBySystem)
    }

    // MARK: - Against the menus that ship

    /// The test host runs `applicationDidFinishLaunching`, so this is the real
    /// menu bar, with every command's default.
    @MainActor func testTheRealMenuBar() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        func problem(_ shortcut: HotKeyShortcut, for command: BrowserCommand) -> HotKeyShortcutProblem? {
            self.problem(shortcut, for: command.id, menu: menu)
        }
        XCTAssertEqual(problem(shortcut(kVK_ANSI_T, [.command], "t"), for: BrowserCommands.reload), .usedByMenu("File > New Tab"))
        XCTAssertEqual(problem(shortcut(kVK_ANSI_C, [.command], "c"), for: BrowserCommands.reload), .usedByMenu("Edit > Copy"))
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Z, [.command], "z"), for: BrowserCommands.reload), .usedByMenu("Edit > Undo"))
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Z, [.command, .shift], "z"), for: BrowserCommands.reload),
                       .usedByMenu("Edit > Redo"))
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Q, [.command], "q"), for: BrowserCommands.reload), .usedByMenu("Detour > Quit Detour"))
        XCTAssertEqual(problem(shortcut(kVK_RightArrow, [.command, .option]), for: BrowserCommands.reload),
                       .usedByMenu("Spaces > Next Space"))
        XCTAssertEqual(problem(.quickDetourDefault, for: BrowserCommands.reload), .usedByQuickDetour)
        XCTAssertNil(problem(shortcut(kVK_ANSI_R, [.command], "r"), for: BrowserCommands.reload))
        XCTAssertNil(problem(shortcut(kVK_ANSI_E, [.command, .option], "e"), for: BrowserCommands.reload))
        XCTAssertNil(problem(shortcut(kVK_F6, []), for: BrowserCommands.importFromArc))
    }

    /// What the recorder of Settings > Shortcuts uses: the pane's own check,
    /// against the live menu, with the Quick Detour setting it is given.
    @MainActor func testThePaneChecksTheLiveMenuAndTheQuickDetourSetting() throws {
        let suite = "ShortcutConflictTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let pane = ShortcutsSettingsViewController(store: ShortcutBindingStore(defaults: defaults),
                                                   mainMenu: { self.mainMenu() }, includesUpdater: false,
                                                   quickDetourShortcut: { .quickDetourDefault },
                                                   systemHotKeys: { [] })
        XCTAssertEqual(pane.problem(for: shortcut(kVK_ANSI_T, [.command], "t"), command: BrowserCommands.reload.id),
                       .usedByMenu("File > New Tab"))
        XCTAssertEqual(pane.problem(for: .quickDetourDefault, command: BrowserCommands.reload.id), .usedByQuickDetour)
        XCTAssertNil(pane.problem(for: shortcut(kVK_ANSI_R, [.command], "r"), command: BrowserCommands.reload.id))
    }

    // MARK: - A shifted key and its character (TASK-335)

    /// View > Zoom In on ⌘+ and an item on ⌘? (no command of Detour's has
    /// it), as a menu spells a shifted character's shortcut.
    @MainActor private func shiftedCharacterMenu(extra: [NSMenuItem] = []) -> NSMenu {
        let main = mainMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            main.addItem(AppDelegate.menuBarItem(for: menu))
        }
        add("Zoom", extra + [item("Zoom In", "+", id: BrowserCommands.zoomIn.id)])
        add("Help", [item("Search Help", "?")])
        return main
    }

    @MainActor func testTheLayoutGivesEachKeysShiftedCharacter() throws {
        let us = try XCTUnwrap(Self.us, "the US layout is always installed")
        XCTAssertEqual(us.character(forKeyCode: UInt16(kVK_ANSI_Equal), shift: false), "=")
        XCTAssertEqual(us.character(forKeyCode: UInt16(kVK_ANSI_Equal), shift: true), "+")
        XCTAssertEqual(us.character(forKeyCode: UInt16(kVK_ANSI_Slash), shift: true), "?")
        XCTAssertEqual(us.character(forKeyCode: UInt16(kVK_ANSI_1), shift: true), "!")
        XCTAssertEqual(us.character(forKeyCode: UInt16(kVK_ANSI_T), shift: true), "T")
        XCTAssertEqual(us.character(forKeyCode: UInt16(kVK_F5), shift: true), "", "a function key types no character")
        XCTAssertEqual(us.character(forKeyCode: UInt16(kVK_Return), shift: false), "")
        // French AZERTY types the digits with Shift, and "+" on the US "/" key.
        let french = try XCTUnwrap(Self.french)
        XCTAssertEqual(french.character(forKeyCode: UInt16(kVK_ANSI_1), shift: false), "&")
        XCTAssertEqual(french.character(forKeyCode: UInt16(kVK_ANSI_1), shift: true), "1")
        XCTAssertEqual(french.character(forKeyCode: UInt16(kVK_ANSI_Slash), shift: true), "+")
        XCTAssertNotNil(KeyboardLayout.current(), "the layout in use has Unicode layout data")
    }

    @MainActor func testAShiftedKeyIsRefusedForTheItemOnItsCharacter() {
        let menu = shiftedCharacterMenu()
        let shiftEqual = shortcut(kVK_ANSI_Equal, [.shift, .command], "=")
        XCTAssertEqual(problem(shiftEqual, menu: menu), .usedByMenuAsShifted(path: "Zoom > Zoom In", shortcut: "⌘+"),
                       "AppKit fires ⌘+ on ⇧⌘=")
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Slash, [.shift, .command], "/"), menu: menu),
                       .usedByMenuAsShifted(path: "Help > Search Help", shortcut: "⌘?"))
        XCTAssertEqual(HotKeyShortcutValidation.message(for: .usedByMenuAsShifted(path: "Zoom > Zoom In", shortcut: "⌘+"),
                                                        shortcut: shiftEqual),
                       "⇧⌘= is ⌘+ on this keyboard, the shortcut of Zoom > Zoom In.")
        XCTAssertNil(problem(shiftEqual, for: BrowserCommands.zoomIn.id, menu: menu), "Zoom In's own key")
    }

    @MainActor func testAKeyWithoutItsShiftedCharacterIsNotRefused() {
        let menu = shiftedCharacterMenu()
        XCTAssertNil(problem(shortcut(kVK_ANSI_Equal, [.command], "="), menu: menu), "⌘= does not fire ⌘+")
        XCTAssertNil(problem(shortcut(kVK_ANSI_Slash, [.command], "/"), menu: menu))
        XCTAssertNil(problem(shortcut(kVK_ANSI_Equal, [.option, .shift, .command], "="), menu: menu),
                     "⌥⇧⌘= does not fire ⌘+ (measured): the other modifiers must match")
        XCTAssertNil(problem(shortcut(kVK_ANSI_Equal, [.shift, .command], "="), menu: menu, layout: nil),
                     "no layout data: only the key itself is compared")
        // A letter's shifted character is the letter: ⇧⌘T is still only itself.
        XCTAssertNil(problem(shortcut(kVK_ANSI_T, [.shift, .command], "t"), menu: menu))
    }

    @MainActor func testTheExactKeyIsNamedBeforeTheShiftedCharacter() {
        // AppKit fires the exact "=" + ⇧⌘ item whatever the order (measured).
        let menu = shiftedCharacterMenu(extra: [item("Actual Size", "=", [.shift, .command])])
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Equal, [.shift, .command], "="), menu: menu),
                       .usedByMenu("Zoom > Actual Size"))
    }

    @MainActor func testTheShiftedCharacterFollowsTheLayout() {
        let menu = shiftedCharacterMenu()
        // On French AZERTY "+" is Shift and the key in the US "/" place;
        // the US "=" key types "-" and "_".
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Slash, [.shift, .command], "="), menu: menu, layout: Self.french),
                       .usedByMenuAsShifted(path: "Zoom > Zoom In", shortcut: "⌘+"))
        XCTAssertNil(problem(shortcut(kVK_ANSI_Equal, [.shift, .command], "-"), menu: menu, layout: Self.french))
    }

    @MainActor func testTheQuickDetourRecorderRefusesAShiftedKeyToo() {
        let menu = shiftedCharacterMenu()
        XCTAssertEqual(HotKeyShortcutValidation.problem(for: shortcut(kVK_ANSI_Equal, [.shift, .command], "="),
                                                        menu: menu, ownAction: nil, systemHotKeys: [],
                                                        shiftedCharacter: Self.shifted(on: Self.us)),
                       .usedByMenuAsShifted(path: "Zoom > Zoom In", shortcut: "⌘+"))
        XCTAssertNil(HotKeyShortcutValidation.problem(for: shortcut(kVK_ANSI_Equal, [.option, .command], "="),
                                                      menu: menu, ownAction: nil, systemHotKeys: [],
                                                      shiftedCharacter: Self.shifted(on: Self.us)))
    }

    @MainActor func testThePaneChecksAShiftedKeyWithItsLayout() throws {
        let suite = "ShortcutConflictTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let menu = shiftedCharacterMenu()
        let pane = ShortcutsSettingsViewController(store: ShortcutBindingStore(defaults: defaults),
                                                   mainMenu: { menu }, includesUpdater: false,
                                                   quickDetourShortcut: { .quickDetourDefault },
                                                   systemHotKeys: { [] },
                                                   systemHotKeyShiftedCharacter: Self.shifted(on: Self.us))
        let shiftEqual = shortcut(kVK_ANSI_Equal, [.shift, .command], "=")
        XCTAssertEqual(pane.problem(for: shiftEqual, command: BrowserCommands.reload.id),
                       .usedByMenuAsShifted(path: "Zoom > Zoom In", shortcut: "⌘+"))
        XCTAssertNil(pane.problem(for: shiftEqual, command: BrowserCommands.zoomIn.id), "Zoom In's own key")
    }

    @MainActor func testTheRealMenuBarsZoomIn() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Equal, [.shift, .command], "="), menu: menu),
                       .usedByMenuAsShifted(path: "View > Zoom In", shortcut: "⌘+"))
        XCTAssertNil(problem(shortcut(kVK_ANSI_Equal, [.shift, .command], "="), for: BrowserCommands.zoomIn.id, menu: menu))
    }
}
