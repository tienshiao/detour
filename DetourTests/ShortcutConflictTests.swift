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

    // MARK: - Saved shortcuts on one keystroke (TASK-343)

    @MainActor private static func shiftedEquivalents(on layout: KeyboardLayout?) -> (KeyEquivalent) -> [KeyEquivalent] {
        { $0.shiftedKeyEquivalents(on: layout) }
    }

    @MainActor private func throwawayStore() throws -> ShortcutBindingStore {
        let suite = "ShortcutConflictTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ShortcutBindingStore(defaults: defaults)
    }

    @MainActor private func pane(_ store: ShortcutBindingStore, layout: @escaping () -> KeyboardLayout?,
                                 layoutChangeCenter: NotificationCenter = NotificationCenter())
        -> ShortcutsSettingsViewController {
        let pane = ShortcutsSettingsViewController(store: store, mainMenu: { self.shiftedCharacterMenu() },
                                                   includesUpdater: false, quickDetourShortcut: { .quickDetourDefault },
                                                   systemHotKeys: { [] },
                                                   systemHotKeyShiftedCharacter: { layout()?.character(forKeyCode: $0, shift: true) ?? "" },
                                                   shiftedEquivalents: { $0.shiftedKeyEquivalents(on: layout()) },
                                                   layoutChangeCenter: layoutChangeCenter)
        _ = pane.view
        return pane
    }

    /// The saved-shortcut side of TASK-335's mapping: a key equivalent names
    /// a character, so the keys typing it are looked up, and the recorder's
    /// rule asked for each.
    @MainActor func testASavedShortcutsShiftedEquivalentFollowsTheLayout() throws {
        let us = try XCTUnwrap(Self.us)
        let french = try XCTUnwrap(Self.french)
        XCTAssertTrue(us.keyCodes(typing: "=").contains(UInt16(kVK_ANSI_Equal)))
        XCTAssertEqual(us.keyCodes(typing: "+"), [UInt16(kVK_ANSI_KeypadPlus)], "only the keypad types + without Shift")
        let shiftEqual = KeyEquivalent("=", [.shift, .command])
        XCTAssertEqual(shiftEqual.shiftedKeyEquivalents(on: us), [KeyEquivalent("+", [.command])])
        // French: "=" and "+" share the key in the US "/" place.
        XCTAssertEqual(shiftEqual.shiftedKeyEquivalents(on: french), [KeyEquivalent("+", [.command])])
        XCTAssertEqual(KeyEquivalent("/", [.shift, .command]).shiftedKeyEquivalents(on: us), [KeyEquivalent("?", [.command])])
        XCTAssertEqual(KeyEquivalent("/", [.shift, .command]).shiftedKeyEquivalents(on: french), [],
                       "French types / with Shift: no key types it alone")
        // French digits are the shifted characters: ⇧⌘à is ⌘0's keystroke.
        XCTAssertEqual(KeyEquivalent("à", [.shift, .command]).shiftedKeyEquivalents(on: french), [KeyEquivalent("0", [.command])])
        XCTAssertEqual(KeyEquivalent("à", [.shift, .command]).shiftedKeyEquivalents(on: us), [])
        // Not a shifted character: no Shift, another modifier set, a letter.
        XCTAssertEqual(KeyEquivalent("=", [.command]).shiftedKeyEquivalents(on: us), [])
        XCTAssertEqual(KeyEquivalent("=", [.option, .shift, .command]).shiftedKeyEquivalents(on: us),
                       [KeyEquivalent("+", [.option, .command])], "⌥⇧⌘= is ⌥⌘+'s keystroke, not ⌘+'s")
        XCTAssertEqual(KeyEquivalent("T", [.command]).shiftedKeyEquivalents(on: us), [], "⇧⌘T is only itself")
        XCTAssertEqual(shiftEqual.shiftedKeyEquivalents(on: nil), [])
        XCTAssertTrue(KeyEquivalent("+").firesOnSameKeystroke(as: shiftEqual, shiftedEquivalents: Self.shiftedEquivalents(on: us)))
        XCTAssertTrue(shiftEqual.firesOnSameKeystroke(as: KeyEquivalent("+"), shiftedEquivalents: Self.shiftedEquivalents(on: us)))
        XCTAssertFalse(KeyEquivalent("+").firesOnSameKeystroke(as: KeyEquivalent("="), shiftedEquivalents: Self.shiftedEquivalents(on: us)))
    }

    /// Reload Page saved on ⇧⌘= (before TASK-335's recorder check, say):
    /// with Zoom In's ⌘+ that is one keystroke, found on US and French, and
    /// both commands keep their shortcuts.
    @MainActor func testASavedPairOnOneKeystrokeIsFoundAndBothAreKept() throws {
        let store = try throwawayStore()
        store.setKeyEquivalent(KeyEquivalent("=", [.shift, .command]), for: BrowserCommands.reload.id)
        let pair: [CommandID: CommandID] = [BrowserCommands.reload.id: BrowserCommands.zoomIn.id,
                                            BrowserCommands.zoomIn.id: BrowserCommands.reload.id]
        XCTAssertEqual(store.sameKeystrokeConflicts(shiftedEquivalents: Self.shiftedEquivalents(on: Self.us)), pair)
        XCTAssertEqual(store.sameKeystrokeConflicts(shiftedEquivalents: Self.shiftedEquivalents(on: Self.french)), pair)
        XCTAssertEqual(store.reportSameKeystrokeConflicts(shiftedEquivalents: Self.shiftedEquivalents(on: Self.us)), pair)
        XCTAssertEqual(store.keyEquivalent(for: BrowserCommands.reload.id), KeyEquivalent("=", [.shift, .command]))
        XCTAssertEqual(store.keyEquivalent(for: BrowserCommands.zoomIn.id), KeyEquivalent("+"), "not dropped")
        XCTAssertEqual(store.sameKeystrokeConflicts(shiftedEquivalents: { _ in [] }), [:], "no layout data")
    }

    /// A pair on one layout only: ⇧⌘à is Actual Size's ⌘0 on French, and
    /// no keystroke of a US keyboard.
    @MainActor func testASavedPairCanCollideOnOneLayoutOnly() throws {
        let store = try throwawayStore()
        store.setKeyEquivalent(KeyEquivalent("à", [.shift, .command]), for: BrowserCommands.reload.id)
        XCTAssertEqual(store.sameKeystrokeConflicts(shiftedEquivalents: Self.shiftedEquivalents(on: Self.french)),
                       [BrowserCommands.reload.id: BrowserCommands.actualSize.id,
                        BrowserCommands.actualSize.id: BrowserCommands.reload.id])
        XCTAssertEqual(store.sameKeystrokeConflicts(shiftedEquivalents: Self.shiftedEquivalents(on: Self.us)), [:])
    }

    /// Settings > Shortcuts marks both rows, naming the other command and
    /// which of the two the keystroke runs (the Shift-held, exact one).
    @MainActor func testThePaneMarksBothRowsOfAPair() throws {
        let store = try throwawayStore()
        store.setKeyEquivalent(KeyEquivalent("=", [.shift, .command]), for: BrowserCommands.reload.id)
        let pane = pane(store, layout: { Self.us })
        let reload = try XCTUnwrap(BrowserCommands.command(withID: BrowserCommands.reload.id))
        let zoomIn = try XCTUnwrap(BrowserCommands.command(withID: BrowserCommands.zoomIn.id))
        XCTAssertEqual(pane.rowState(for: reload).sameKeystroke,
                       .init(otherTitle: "Zoom In", otherShortcut: "⌘+", runner: "Reload Page"))
        XCTAssertEqual(pane.rowState(for: zoomIn).sameKeystroke,
                       .init(otherTitle: "Reload Page", otherShortcut: "⇧⌘=", runner: "Reload Page"))
        XCTAssertNil(pane.rowState(for: try XCTUnwrap(BrowserCommands.command(withID: BrowserCommands.newTab.id))).sameKeystroke)

        let row = ShortcutRowView(identifier: NSUserInterfaceItemIdentifier("row"))
        row.show(pane.rowState(for: zoomIn), commandID: zoomIn.id)
        XCTAssertFalse(row.noteLabel.isHidden)
        XCTAssertEqual(row.noteLabel.stringValue, "Same key as Reload Page")
        XCTAssertEqual(row.toolTip, "⌘+ and Reload Page's ⇧⌘= are one keystroke on this keyboard, which runs Reload Page. Record another shortcut for one of them.")
        // macOS's mark comes first: it takes the key before either.
        var taken = pane.rowState(for: zoomIn)
        taken.isTakenByMacOS = true
        row.show(taken, commandID: zoomIn.id)
        XCTAssertEqual(row.noteLabel.stringValue, ShortcutRowView.takenByMacOSNote)
    }

    /// The rows follow the keyboard layout: marked on French for ⇧⌘à, not
    /// on US, and marked again when the layout changes (the input source
    /// change notification reloads the pane). Posted on a private center:
    /// the distributed one would reach every app on the Mac.
    @MainActor func testThePaneMarksAgainWhenTheLayoutChanges() throws {
        let store = try throwawayStore()
        store.setKeyEquivalent(KeyEquivalent("à", [.shift, .command]), for: BrowserCommands.reload.id)
        var layout = Self.us
        let center = NotificationCenter()
        let pane = pane(store, layout: { layout }, layoutChangeCenter: center)
        XCTAssertEqual(pane.sameKeystrokeConflicts, [:])
        layout = Self.french
        center.post(name: KeyboardLayout.selectionDidChangeNotification, object: nil)
        // After the reload the pane's observer scheduled on the main queue.
        let marked = expectation(description: "reloaded on the layout change")
        DispatchQueue.main.async { marked.fulfill() }
        wait(for: [marked], timeout: 10)
        XCTAssertEqual(pane.sameKeystrokeConflicts[BrowserCommands.reload.id], BrowserCommands.actualSize.id)
    }

    /// Resetting Zoom In to ⌘+ while Reload Page holds ⇧⌘= is refused with
    /// the holder named, as recording ⇧⌘= is; on French too, and on French
    /// only for Actual Size's ⌘0 against ⇧⌘à.
    @MainActor func testAResetOntoAnotherBindingsKeystrokeIsRefused() throws {
        for layout in [Self.us, Self.french] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("=", [.option, .command]), for: BrowserCommands.zoomIn.id)
            store.setKeyEquivalent(KeyEquivalent("=", [.shift, .command]), for: BrowserCommands.reload.id)
            let pane = pane(store, layout: { layout })
            pane.reset(BrowserCommands.zoomIn.id)
            XCTAssertEqual(store.override(for: BrowserCommands.zoomIn.id), .key(KeyEquivalent("=", [.option, .command])),
                           "kept")
            XCTAssertFalse(pane.warningLabel.isHidden)
            XCTAssertEqual(pane.warningLabel.stringValue,
                           "⌘+ and ⇧⌘= are one keystroke on this keyboard, and ⇧⌘= is now Reload Page's shortcut. Change that one first.")
            // Reload Page back to ⌘R: the reset goes through.
            pane.reset(BrowserCommands.reload.id)
            pane.reset(BrowserCommands.zoomIn.id)
            XCTAssertFalse(store.hasOverrides)
            XCTAssertTrue(pane.warningLabel.isHidden)
        }

        for (layout, refused) in [(Self.french, true), (Self.us, false)] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("0", [.option, .command]), for: BrowserCommands.actualSize.id)
            store.setKeyEquivalent(KeyEquivalent("à", [.shift, .command]), for: BrowserCommands.reload.id)
            let pane = pane(store, layout: { layout })
            pane.reset(BrowserCommands.actualSize.id)
            XCTAssertEqual(store.isOverridden(BrowserCommands.actualSize.id), refused)
            XCTAssertEqual(pane.warningLabel.isHidden, !refused)
        }
    }

    /// The other direction: a default holding Shift on a key whose shifted
    /// character another binding has (⇧⌘[ against ⌘{).
    @MainActor func testTheResetCheckFindsTheHolderInEitherDirection() throws {
        let store = try throwawayStore()
        store.setKeyEquivalent(KeyEquivalent("{", [.command]), for: BrowserCommands.reload.id)
        func conflict(_ builtIn: KeyEquivalent) -> ShortcutResetConflict? {
            ShortcutResolution.resetConflict(of: BrowserCommands.back.id, builtIn: builtIn, others: store.effectiveKeys,
                                             holders: [], shiftedEquivalents: Self.shiftedEquivalents(on: Self.us))
        }
        XCTAssertEqual(conflict(KeyEquivalent("[", [.shift, .command])),
                       .sameKeystroke(BrowserCommands.reload.id, KeyEquivalent("{", [.command])))
        XCTAssertNil(conflict(KeyEquivalent("[", [.command])), "⌘[ is not ⌘{'s keystroke")
        XCTAssertEqual(conflict(KeyEquivalent("{")), .heldBy(BrowserCommands.reload.id), "the very same shortcut first")
        XCTAssertNil(ShortcutResolution.resetConflict(of: BrowserCommands.reload.id, builtIn: KeyEquivalent("{"),
                                                      others: store.effectiveKeys, holders: [],
                                                      shiftedEquivalents: Self.shiftedEquivalents(on: Self.us)),
                     "a command's own shortcut is no conflict")
    }

    // MARK: - Holders outside the commands (TASK-350)

    /// `shiftedCharacterMenu` (Search Help on ⌘?, an item no command is)
    /// with a menu "Extra" of more such items.
    @MainActor private func outsideMenu(_ extra: [NSMenuItem] = []) -> NSMenu {
        let main = shiftedCharacterMenu()
        let menu = NSMenu(title: "Extra")
        extra.forEach(menu.addItem)
        main.addItem(AppDelegate.menuBarItem(for: menu))
        return main
    }

    @MainActor private func pane(_ store: ShortcutBindingStore, layout: KeyboardLayout?, menu: NSMenu,
                                 quickDetour: HotKeyShortcut? = .quickDetourDefault) -> ShortcutsSettingsViewController {
        let pane = ShortcutsSettingsViewController(store: store, mainMenu: { menu }, includesUpdater: false,
                                                   quickDetourShortcut: { quickDetour }, systemHotKeys: { [] },
                                                   systemHotKeyShiftedCharacter: Self.shifted(on: layout),
                                                   shiftedEquivalents: Self.shiftedEquivalents(on: layout),
                                                   layoutChangeCenter: NotificationCenter())
        _ = pane.view
        return pane
    }

    @MainActor private func command(_ id: CommandID) throws -> BrowserCommand {
        try XCTUnwrap(BrowserCommands.command(withID: id))
    }

    /// The menu bar that ships, with every default: no command's default
    /// shares a keystroke with an item outside the commands (AppKit's, the
    /// fixed Edit commands) or the Quick Detour hotkey, on US or French, so
    /// no reset is refused and no row is marked on a fresh install.
    @MainActor func testTheShippedDefaultsShareNoKeystrokeWithAHolderOutsideTheCommands() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let store = try throwawayStore()
        let holders = HotKeyShortcutValidation.keystrokeHolders(
            in: menu,
            isExcluded: { store.isCommandItem($0) || $0.identifier?.rawValue == BrowserCommands.newQuickDetourWindow.id.rawValue },
            quickDetourShortcut: .quickDetourDefault)
        XCTAssertTrue(holders.contains { $0.kind == .menuItem(path: "Edit > Copy") }, "a fixed command is a holder")
        XCTAssertTrue(holders.contains { $0.kind == .quickDetour && $0.key == KeyEquivalent("n", [.command, .option]) })
        XCTAssertFalse(holders.contains { $0.title == "New Tab" }, "the store's commands are compared by their bindings")
        XCTAssertFalse(holders.contains { $0.title == "New Quick Detour Window" }, "named from the setting instead")
        let defaults = BrowserCommands.bindable.compactMap { command in command.keyEquivalent.map { (id: command.id, key: $0) } }
        for layout in [Self.us, Self.french] {
            XCTAssertEqual(ShortcutResolution.outsideHolderConflicts(of: defaults, holders: holders,
                                                                     shiftedEquivalents: Self.shiftedEquivalents(on: layout)),
                           [:])
            XCTAssertEqual(pane(store, layout: layout, menu: menu).outsideConflicts, [:])
        }
        // A saved shortcut on a fixed command's key is marked; which of the
        // two fires is not claimed.
        store.setKeyEquivalent(KeyEquivalent("c"), for: BrowserCommands.reload.id)
        let pane = pane(store, layout: Self.us, menu: menu)
        let same = try XCTUnwrap(pane.rowState(for: try command(BrowserCommands.reload.id)).sameKeystroke)
        XCTAssertEqual(same.otherTitle, "Copy")
        XCTAssertNil(same.runner)
        XCTAssertEqual(ShortcutRowView.sameKeystrokeToolTip(same, shortcut: "⌘C"),
                       "⌘C is also the shortcut of Edit > Copy, and only one of them can have it. "
                       + "Record another shortcut for this command.")
    }

    /// AppKit gives a key equivalent to one item of the bar only: a binding
    /// on Copy's ⌘C saved before launch takes it from Copy's item, which is
    /// left with none (measured, TASK-350). Copy still holds ⌘C for the
    /// check, from the registry.
    @MainActor func testAFixedCommandHoldsItsKeyAfterAppKitClearedItsItem() throws {
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.identifier = NSUserInterfaceItemIdentifier(BrowserCommands.copy.id.rawValue)
        let store = try throwawayStore()
        store.setKeyEquivalent(KeyEquivalent("c"), for: BrowserCommands.reload.id)
        let pane = pane(store, layout: Self.us, menu: outsideMenu([copy]))
        XCTAssertEqual(pane.outsideConflicts[BrowserCommands.reload.id]?.kind, .menuItem(path: "Extra > Copy"))
        // An item no command is keeps only what it holds now.
        let cleared = item("Thing", "")
        XCTAssertTrue(HotKeyShortcutValidation.keystrokeHolders(in: outsideMenu([cleared]), isExcluded: { _ in false },
                                                                quickDetourShortcut: nil)
            .allSatisfy { $0.title != "Thing" })
    }

    /// Reload Page rebound, the Quick Detour hotkey then set to ⌘R: Reload
    /// Page's reset is refused with the hotkey named, as recording ⌘R is.
    @MainActor func testAResetOntoTheQuickDetourShortcutIsRefused() throws {
        let commandR = shortcut(kVK_ANSI_R, [.command], "r")
        for (quickDetour, refused) in [(commandR, true), (nil, false)] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("e", [.option, .command]), for: BrowserCommands.reload.id)
            let pane = pane(store, layout: Self.us, menu: outsideMenu(), quickDetour: quickDetour)
            pane.reset(BrowserCommands.reload.id)
            XCTAssertEqual(store.isOverridden(BrowserCommands.reload.id), refused)
            XCTAssertEqual(pane.warningLabel.isHidden, !refused)
            if refused {
                XCTAssertEqual(pane.warningLabel.stringValue,
                               "⌘R is the Quick Detour shortcut (Settings > Quick Detour). Change that one first.")
            }
        }
    }

    /// The Quick Detour hotkey on ⇧⌘ and the key typing "=" (a different
    /// key on US and French) is Zoom In's ⌘+ keystroke: Zoom In's reset is
    /// refused on both layouts.
    @MainActor func testAResetOntoTheQuickDetourKeystrokeIsRefused() throws {
        for (layout, keyCode) in [(Self.us, kVK_ANSI_Equal), (Self.french, kVK_ANSI_Slash)] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("=", [.option, .command]), for: BrowserCommands.zoomIn.id)
            let pane = pane(store, layout: layout, menu: outsideMenu(),
                            quickDetour: shortcut(keyCode, [.shift, .command], "="))
            pane.reset(BrowserCommands.zoomIn.id)
            XCTAssertTrue(store.isOverridden(BrowserCommands.zoomIn.id), "kept")
            XCTAssertEqual(pane.warningLabel.stringValue,
                           "⌘+ and ⇧⌘= are one keystroke on this keyboard, and ⇧⌘= is the Quick Detour shortcut "
                           + "(Settings > Quick Detour). Change that one first.")
        }
    }

    /// An item no command is (AppKit's, say): Reload Page's default on it is
    /// refused; Actual Size's ⌘0 against one on ⇧⌘à on French only.
    @MainActor func testAResetOntoAnItemOutsideTheCommandsIsRefused() throws {
        let store = try throwawayStore()
        store.setKeyEquivalent(KeyEquivalent("e", [.option, .command]), for: BrowserCommands.reload.id)
        let exact = pane(store, layout: Self.us, menu: outsideMenu([item("Thing", "r")]))
        exact.reset(BrowserCommands.reload.id)
        XCTAssertTrue(store.isOverridden(BrowserCommands.reload.id))
        XCTAssertEqual(exact.warningLabel.stringValue, "⌘R is the shortcut of Extra > Thing, which cannot be changed here.")

        for (layout, refused) in [(Self.french, true), (Self.us, false)] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("0", [.option, .command]), for: BrowserCommands.actualSize.id)
            let pane = pane(store, layout: layout, menu: outsideMenu([item("Thing", "à", [.shift, .command])]))
            pane.reset(BrowserCommands.actualSize.id)
            XCTAssertEqual(store.isOverridden(BrowserCommands.actualSize.id), refused)
            if refused {
                XCTAssertEqual(pane.warningLabel.stringValue,
                               "⌘0 and ⇧⌘À are one keystroke on this keyboard, and ⇧⌘À is the shortcut of Extra > Thing, "
                               + "which cannot be changed here.")
            } else {
                XCTAssertTrue(pane.warningLabel.isHidden)
            }
        }
    }

    /// Either direction: the shortcut holding Shift on a key whose shifted
    /// character the holder has (⇧⌘[ against ⌘{), or the other way round.
    @MainActor func testAnOutsideHolderIsFoundInEitherDirection() {
        let holder = { (key: KeyEquivalent) in KeystrokeHolder(kind: .menuItem(path: "Extra > Thing"), title: "Thing", key: key) }
        let us = Self.shiftedEquivalents(on: Self.us)
        let back = BrowserCommands.back.id
        XCTAssertEqual(ShortcutResolution.outsideHolderConflicts(of: [(id: back, key: KeyEquivalent("[", [.shift, .command]))],
                                                                 holders: [holder(KeyEquivalent("{"))], shiftedEquivalents: us),
                       [back: holder(KeyEquivalent("{"))])
        XCTAssertEqual(ShortcutResolution.outsideHolderConflicts(of: [(id: back, key: KeyEquivalent("{"))],
                                                                 holders: [holder(KeyEquivalent("[", [.shift, .command]))],
                                                                 shiftedEquivalents: us),
                       [back: holder(KeyEquivalent("[", [.shift, .command]))])
        XCTAssertEqual(ShortcutResolution.outsideHolderConflicts(of: [(id: back, key: KeyEquivalent("["))],
                                                                 holders: [holder(KeyEquivalent("{"))], shiftedEquivalents: us),
                       [:], "⌘[ is not ⌘{'s keystroke")
        // The very same shortcut is named before one on the keystroke.
        let exact = holder(KeyEquivalent("{"))
        XCTAssertEqual(ShortcutResolution.outsideHolderConflicts(
            of: [(id: back, key: KeyEquivalent("{"))],
            holders: [holder(KeyEquivalent("[", [.shift, .command])), exact], shiftedEquivalents: us)[back], exact)
    }

    /// Saved shortcuts sharing a keystroke with an item no command is, or
    /// with the Quick Detour hotkey, are marked on their row like a pair.
    @MainActor func testASavedShortcutSharingAnOutsideHoldersKeystrokeIsMarked() throws {
        let reload = try command(BrowserCommands.reload.id)
        // ⇧⌘/ is Search Help's ⌘? on US (the saved shortcut holds Shift), and
        // no keystroke of it on French.
        for (layout, marked) in [(Self.us, true), (Self.french, false)] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("/", [.shift, .command]), for: reload.id)
            let pane = pane(store, layout: layout, menu: outsideMenu())
            let same = pane.rowState(for: reload).sameKeystroke
            if marked {
                let holder = try XCTUnwrap(pane.outsideConflicts[reload.id])
                XCTAssertEqual(holder.kind, .menuItem(path: "Help > Search Help"))
                XCTAssertEqual(same, .init(otherTitle: "Search Help", otherShortcut: "⌘?", runner: "Reload Page", outside: holder))
                let row = ShortcutRowView(identifier: NSUserInterfaceItemIdentifier("row"))
                row.show(pane.rowState(for: reload), commandID: reload.id)
                XCTAssertFalse(row.noteLabel.isHidden)
                XCTAssertEqual(row.noteLabel.stringValue, "Same key as Search Help")
                XCTAssertEqual(row.toolTip, "⇧⌘/ and ⌘?, the shortcut of Help > Search Help, are one keystroke on this "
                               + "keyboard, which runs Reload Page. Record another shortcut for this command.")
            } else {
                XCTAssertNil(same)
            }
        }
        // The holder holding Shift: ⌘+ saved against an item on ⇧⌘=, on both
        // layouts (the keystroke runs the item).
        for layout in [Self.us, Self.french] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("+"), for: reload.id)
            let pane = pane(store, layout: layout, menu: outsideMenu([item("Thing", "=", [.shift, .command])]))
            XCTAssertEqual(pane.rowState(for: reload).sameKeystroke?.runner, "Thing")
        }
        // French only: ⌥⇧⌘à is ⌥⌘0's keystroke there.
        for (layout, marked) in [(Self.french, true), (Self.us, false)] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("à", [.option, .shift, .command]), for: reload.id)
            let pane = pane(store, layout: layout, menu: outsideMenu([item("Thing", "0", [.option, .command])]))
            XCTAssertEqual(pane.rowState(for: reload).sameKeystroke?.otherTitle, marked ? "Thing" : nil)
        }
    }

    @MainActor func testASavedShortcutOnTheQuickDetourShortcutIsMarked() throws {
        let reload = try command(BrowserCommands.reload.id)
        for layout in [Self.us, Self.french] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("n", [.option, .command]), for: reload.id)
            let pane = pane(store, layout: layout, menu: outsideMenu())
            let same = try XCTUnwrap(pane.rowState(for: reload).sameKeystroke)
            XCTAssertEqual(same.otherTitle, "Quick Detour")
            XCTAssertNil(same.runner, "the very same shortcut: which fires is not claimed")
            let row = ShortcutRowView(identifier: NSUserInterfaceItemIdentifier("row"))
            row.show(pane.rowState(for: reload), commandID: reload.id)
            XCTAssertEqual(row.noteLabel.stringValue, "Same key as Quick Detour")
            XCTAssertEqual(row.toolTip, "⌥⌘N is also the Quick Detour shortcut (Settings > Quick Detour), which takes "
                           + "the key first while it is on. Record another shortcut for this command.")
            XCTAssertNil(self.pane(store, layout: layout, menu: outsideMenu(), quickDetour: nil)
                .rowState(for: reload).sameKeystroke, "no hotkey set")
        }
        // On its keystroke: the hotkey on ⇧⌘ and the "=" key, Zoom In's ⌘+.
        let zoomIn = try command(BrowserCommands.zoomIn.id)
        for (layout, keyCode) in [(Self.us, kVK_ANSI_Equal), (Self.french, kVK_ANSI_Slash)] {
            let pane = pane(try throwawayStore(), layout: layout, menu: outsideMenu(),
                            quickDetour: shortcut(keyCode, [.shift, .command], "="))
            let same = try XCTUnwrap(pane.rowState(for: zoomIn).sameKeystroke)
            XCTAssertEqual(same.otherTitle, "Quick Detour")
            XCTAssertEqual(same.runner, "Quick Detour", "the Shift-held one is the exact match")
        }
    }

    /// A pair of commands is named before a holder outside them.
    @MainActor func testACommandPairIsNamedBeforeAnOutsideHolder() throws {
        let store = try throwawayStore()
        store.setKeyEquivalent(KeyEquivalent("=", [.shift, .command]), for: BrowserCommands.reload.id)
        let pane = pane(store, layout: Self.us, menu: outsideMenu([item("Thing", "+", [.command])]))
        XCTAssertEqual(pane.rowState(for: try command(BrowserCommands.reload.id)).sameKeystroke?.otherTitle, "Zoom In")
    }

    // MARK: - Restore Defaults (TASK-374)

    /// Reload Page rebound, the Quick Detour hotkey then set to ⌘R: Restore
    /// Defaults gives every other command its default back and leaves Reload
    /// Page as it is, named on the warning line with Reset's reason. Without
    /// the hotkey on ⌘R everything is restored.
    @MainActor func testRestoreDefaultsLeavesACommandWhoseDefaultIsTheQuickDetourShortcut() throws {
        let commandR = shortcut(kVK_ANSI_R, [.command], "r")
        for (quickDetour, kept) in [(commandR, true), (nil, false)] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("e", [.option, .command]), for: BrowserCommands.reload.id)
            store.setKeyEquivalent(nil, for: BrowserCommands.closeTab.id)
            let pane = pane(store, layout: Self.us, menu: outsideMenu(), quickDetour: quickDetour)
            pane.reload()
            pane.restoreDefaultsButton.performClick(nil)
            XCTAssertFalse(store.isOverridden(BrowserCommands.closeTab.id), "the others are restored")
            XCTAssertEqual(store.override(for: BrowserCommands.reload.id),
                           kept ? .key(KeyEquivalent("e", [.option, .command])) : nil)
            XCTAssertEqual(pane.warningLabel.isHidden, !kept)
            if kept {
                XCTAssertEqual(pane.warningLabel.stringValue,
                               "Restore Defaults left Reload Page as it is: ⌘R is the Quick Detour shortcut "
                               + "(Settings > Quick Detour). Change that one first.")
            }
        }
    }

    /// The Quick Detour hotkey on Zoom In's ⌘+ keystroke (⇧⌘ and the key
    /// typing "=", a different key on US and French): Zoom In is left as it
    /// is on both layouts.
    @MainActor func testRestoreDefaultsLeavesACommandWhoseDefaultIsTheQuickDetourKeystroke() throws {
        for (layout, keyCode) in [(Self.us, kVK_ANSI_Equal), (Self.french, kVK_ANSI_Slash)] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("=", [.option, .command]), for: BrowserCommands.zoomIn.id)
            store.setKeyEquivalent(KeyEquivalent("e", [.option, .command]), for: BrowserCommands.reload.id)
            let pane = pane(store, layout: layout, menu: outsideMenu(),
                            quickDetour: shortcut(keyCode, [.shift, .command], "="))
            pane.reload()
            pane.restoreDefaultsButton.performClick(nil)
            XCTAssertTrue(store.isOverridden(BrowserCommands.zoomIn.id), "kept")
            XCTAssertFalse(store.isOverridden(BrowserCommands.reload.id))
            XCTAssertEqual(pane.warningLabel.stringValue,
                           "Restore Defaults left Zoom In as it is: ⌘+ and ⇧⌘= are one keystroke on this keyboard, "
                           + "and ⇧⌘= is the Quick Detour shortcut (Settings > Quick Detour). Change that one first.")
        }
    }

    /// An item no command is on ⇧⌘à: Actual Size's ⌘0 is that keystroke on
    /// French only, so it is left as it is there and restored on US.
    @MainActor func testRestoreDefaultsLeavesACommandWhoseDefaultAnItemOutsideTheCommandsHolds() throws {
        for (layout, kept) in [(Self.french, true), (Self.us, false)] {
            let store = try throwawayStore()
            store.setKeyEquivalent(KeyEquivalent("0", [.option, .command]), for: BrowserCommands.actualSize.id)
            let pane = pane(store, layout: layout, menu: outsideMenu([item("Thing", "à", [.shift, .command])]))
            pane.reload()
            pane.restoreDefaultsButton.performClick(nil)
            XCTAssertEqual(store.isOverridden(BrowserCommands.actualSize.id), kept)
            XCTAssertEqual(pane.warningLabel.isHidden, !kept)
            if kept {
                XCTAssertEqual(pane.warningLabel.stringValue,
                               "Restore Defaults left Actual Size as it is: ⌘0 and ⇧⌘À are one keystroke on this "
                               + "keyboard, and ⇧⌘À is the shortcut of Extra > Thing, which cannot be changed here.")
            }
        }
    }

    /// A command left as it is keeps its own shortcut, so a command whose
    /// default that shortcut is stays as it is too: New Tab cleared and its
    /// ⌘T given to Reload Page, the Quick Detour hotkey then on ⌘R.
    @MainActor func testRestoreDefaultsLeavesACommandWhoseDefaultAnotherLeftCommandHolds() throws {
        let store = try throwawayStore()
        store.setKeyEquivalent(nil, for: BrowserCommands.newTab.id)
        store.setKeyEquivalent(KeyEquivalent("t"), for: BrowserCommands.reload.id)
        store.setKeyEquivalent(nil, for: BrowserCommands.closeTab.id)
        let pane = pane(store, layout: Self.us, menu: outsideMenu(), quickDetour: shortcut(kVK_ANSI_R, [.command], "r"))
        pane.reload()
        pane.restoreDefaultsButton.performClick(nil)
        XCTAssertEqual(store.override(for: BrowserCommands.reload.id), .key(KeyEquivalent("t")))
        XCTAssertEqual(store.override(for: BrowserCommands.newTab.id), ShortcutOverride.none)
        XCTAssertFalse(store.isOverridden(BrowserCommands.closeTab.id))
        XCTAssertEqual(pane.warningLabel.stringValue,
                       "Restore Defaults left 2 commands as they are. New Tab: ⌘T is now Reload Page's shortcut. "
                       + "Change that one first. Reload Page: ⌘R is the Quick Detour shortcut (Settings > Quick "
                       + "Detour). Change that one first.")
        // On the keystroke too: Zoom In cleared, Reload Page on ⇧⌘= (its ⌘+
        // keystroke on US), the hotkey on ⌘R.
        let keystroke = ShortcutResolution.restoreDefaultsConflicts(
            of: BrowserCommands.bindable.map { (id: $0.id, default: $0.keyEquivalent) },
            overrides: [BrowserCommands.zoomIn.id: ShortcutOverride.none,
                        BrowserCommands.reload.id: .key(KeyEquivalent("=", [.shift, .command]))],
            holders: [KeystrokeHolder(kind: .quickDetour, title: "Quick Detour", key: KeyEquivalent("r"))],
            shiftedEquivalents: Self.shiftedEquivalents(on: Self.us))
        XCTAssertEqual(keystroke.map(\.id), [BrowserCommands.reload.id, BrowserCommands.zoomIn.id])
        XCTAssertEqual(keystroke.last?.conflict,
                       .sameKeystroke(BrowserCommands.reload.id, KeyEquivalent("=", [.shift, .command])))
    }

    /// The state the restore leaves is what counts, not today's bindings:
    /// two commands that swapped their defaults are both restored.
    @MainActor func testRestoreDefaultsRestoresASwap() throws {
        let store = try throwawayStore()
        store.setKeyEquivalent(KeyEquivalent("r"), for: BrowserCommands.newTab.id)
        store.setKeyEquivalent(KeyEquivalent("t"), for: BrowserCommands.reload.id)
        let pane = pane(store, layout: Self.us, menu: outsideMenu())
        pane.reset(BrowserCommands.reload.id)
        XCTAssertFalse(pane.warningLabel.isHidden, "one row's reset is refused: New Tab holds ⌘R today")
        pane.reload()
        pane.restoreDefaultsButton.performClick(nil)
        XCTAssertFalse(store.hasOverrides)
        XCTAssertTrue(pane.warningLabel.isHidden, "the refusal shown before goes")
    }
}
