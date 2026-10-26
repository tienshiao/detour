import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Detour

/// TASK-193.2: the Quick Detour hotkey's shortcut — one value spelled three
/// ways (Carbon, the menu's key equivalent, the recorder's label), persisted
/// in defaults, validated against Detour's menus and macOS's shortcuts, and
/// what each key press does while the recorder records.
@MainActor
final class HotKeyShortcutTests: XCTestCase {

    private func shortcut(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags, _ character: String = "") -> HotKeyShortcut {
        HotKeyShortcut(keyCode: UInt16(keyCode), modifiers: modifiers, character: character)
    }

    // MARK: - The value

    func testTheDefaultIsOptionCommandN() {
        let shortcut = HotKeyShortcut.quickDetourDefault
        XCTAssertEqual(shortcut.keyCode, UInt16(kVK_ANSI_N))
        XCTAssertEqual(shortcut.modifiers, [.command, .option])
        XCTAssertEqual(shortcut.character, "n")
        XCTAssertEqual(shortcut.displayString, "⌥⌘N")
    }

    func testModifiersAreNarrowedAndTheCharacterLowercased() {
        let recorded = shortcut(kVK_ANSI_K, [.command, .shift, .capsLock, .function, .numericPad], "K")
        XCTAssertEqual(recorded.modifiers, [.command, .shift])
        XCTAssertEqual(recorded.character, "k")
        XCTAssertEqual(recorded, shortcut(kVK_ANSI_K, [.command, .shift], "k"))
    }

    func testShortcutsDifferByKeyAndByModifiers() {
        let base = shortcut(kVK_ANSI_N, [.command, .option], "n")
        XCTAssertEqual(base, HotKeyShortcut.quickDetourDefault)
        XCTAssertNotEqual(base, shortcut(kVK_ANSI_M, [.command, .option], "m"))
        XCTAssertNotEqual(base, shortcut(kVK_ANSI_N, [.command, .control], "n"))
        XCTAssertEqual(Set([base, HotKeyShortcut.quickDetourDefault]).count, 1)
    }

    // MARK: - Carbon

    func testCarbonModifierBits() {
        XCTAssertEqual(shortcut(kVK_ANSI_N, [.command]).carbonModifiers, UInt32(cmdKey))
        XCTAssertEqual(shortcut(kVK_ANSI_N, [.option]).carbonModifiers, UInt32(optionKey))
        XCTAssertEqual(shortcut(kVK_ANSI_N, [.control]).carbonModifiers, UInt32(controlKey))
        XCTAssertEqual(shortcut(kVK_ANSI_N, [.shift]).carbonModifiers, UInt32(shiftKey))
        XCTAssertEqual(HotKeyShortcut.quickDetourDefault.carbonModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(shortcut(kVK_F12, [.control, .option, .command]).carbonModifiers, 6400)
    }

    func testCarbonModifiersRoundTripForEveryCombination() {
        let all: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift]
        for mask in 0..<16 {
            var flags: NSEvent.ModifierFlags = []
            for (bit, flag) in all.enumerated() where mask & (1 << bit) != 0 { flags.insert(flag) }
            let carbon = shortcut(kVK_ANSI_A, flags).carbonModifiers
            XCTAssertEqual(HotKeyShortcut.modifiers(fromCarbon: carbon), flags, "mask \(mask)")
        }
    }

    func testCarbonStateBitsAreIgnored() {
        // Fn (bit 17, on every symbolic hotkey of an F-key or arrow) and Caps Lock.
        let carbon = UInt32(cmdKey) | (1 << 17) | UInt32(alphaLock)
        XCTAssertEqual(HotKeyShortcut.modifiers(fromCarbon: carbon), [.command])
    }

    // MARK: - Menu key equivalent

    func testKeyEquivalents() {
        XCTAssertEqual(HotKeyShortcut.quickDetourDefault.keyEquivalent, "n")
        XCTAssertEqual(shortcut(kVK_F12, [.command]).keyEquivalent, String(UnicodeScalar(UInt16(NSF12FunctionKey))!))
        XCTAssertEqual(shortcut(kVK_F1, [.command]).keyEquivalent, String(UnicodeScalar(UInt16(NSF1FunctionKey))!))
        XCTAssertEqual(shortcut(kVK_LeftArrow, [.command]).keyEquivalent, "\u{F702}")
        XCTAssertEqual(shortcut(kVK_DownArrow, [.command]).keyEquivalent, "\u{F701}")
        XCTAssertEqual(shortcut(kVK_Space, [.control]).keyEquivalent, " ")
        XCTAssertEqual(shortcut(kVK_Return, [.command]).keyEquivalent, "\r")
        XCTAssertEqual(shortcut(kVK_Tab, [.option]).keyEquivalent, "\t")
        XCTAssertEqual(shortcut(kVK_ForwardDelete, [.command]).keyEquivalent, "\u{F728}")
        // A key code with a character of its own uses the character, so the
        // menu shows what the layout prints on the key.
        XCTAssertEqual(shortcut(kVK_ANSI_Z, [.command], "y").keyEquivalent, "y")
    }

    // MARK: - Display

    func testDisplayStringPutsModifiersInApplesOrder() {
        XCTAssertEqual(shortcut(kVK_F12, [.command, .shift, .option, .control]).displayString, "⌃⌥⇧⌘F12")
        XCTAssertEqual(shortcut(kVK_ANSI_K, [.control, .command], "k").displayString, "⌃⌘K")
        XCTAssertEqual(shortcut(kVK_ANSI_1, [.option], "1").displayString, "⌥1")
    }

    func testKeyNamesOfKeysWithoutACharacter() {
        XCTAssertEqual(shortcut(kVK_F12, [.command]).keyName, "F12")
        XCTAssertEqual(shortcut(kVK_F5, [.command]).keyName, "F5")
        XCTAssertEqual(shortcut(kVK_F20, [.command]).keyName, "F20")
        XCTAssertEqual(shortcut(kVK_Space, [.control], " ").keyName, "Space")
        XCTAssertEqual(shortcut(kVK_LeftArrow, [.command]).keyName, "←")
        XCTAssertEqual(shortcut(kVK_UpArrow, [.command]).keyName, "↑")
        XCTAssertEqual(shortcut(kVK_Return, [.command], "\r").keyName, "↩")
        XCTAssertEqual(shortcut(kVK_Delete, [.command]).keyName, "⌫")
        XCTAssertEqual(shortcut(kVK_Escape, [.command]).keyName, "⎋")
        XCTAssertEqual(shortcut(kVK_ANSI_Slash, [.command], "/").keyName, "/")
    }

    func testAKeyWithNoCharacterAndNoNameHasAnEmptyName() {
        XCTAssertEqual(shortcut(kVK_ANSI_A, [.command], "").keyName, "")
    }

    // MARK: - Persistence

    func testPropertyListRoundTrip() {
        let shortcuts = [
            HotKeyShortcut.quickDetourDefault,
            shortcut(kVK_F12, [.control, .option, .command]),
            shortcut(kVK_ANSI_K, [.shift, .command], "k"),
        ]
        for original in shortcuts {
            let plist = original.propertyList
            // Through a real defaults suite, which is how it is stored.
            let suite = "HotKeyShortcutTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(plist, forKey: "shortcut")
            XCTAssertEqual(HotKeyShortcut(propertyList: defaults.object(forKey: "shortcut")), original)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testThePropertyListHoldsCarbonModifiers() {
        let plist = shortcut(kVK_F12, [.control, .option, .command]).propertyList
        XCTAssertEqual(plist["keyCode"] as? Int, kVK_F12)
        XCTAssertEqual(plist["modifiers"] as? Int, 6400)
        XCTAssertEqual(plist["character"] as? String, "")
    }

    func testMalformedPropertyListsAreRefused() {
        XCTAssertNil(HotKeyShortcut(propertyList: nil))
        XCTAssertNil(HotKeyShortcut(propertyList: "⌥⌘N"))
        XCTAssertNil(HotKeyShortcut(propertyList: [String: Any]()))
        XCTAssertNil(HotKeyShortcut(propertyList: ["keyCode": 45, "character": "n"]))
        XCTAssertNil(HotKeyShortcut(propertyList: ["keyCode": "45", "modifiers": 2304, "character": "n"]))
        XCTAssertNil(HotKeyShortcut(propertyList: ["keyCode": 70_000, "modifiers": 2304, "character": "n"]))
        XCTAssertNil(HotKeyShortcut(propertyList: ["keyCode": -1, "modifiers": 2304, "character": "n"]))
        // No character is allowed (an F-key's).
        XCTAssertEqual(HotKeyShortcut(propertyList: ["keyCode": kVK_F12, "modifiers": 256]),
                       shortcut(kVK_F12, [.command]))
    }

    // MARK: - Validation

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        return menu
    }

    private func item(_ title: String, _ key: String, _ mask: NSEvent.ModifierFlags = .command,
                      action: Selector? = #selector(NSResponder.selectAll(_:))) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        return item
    }

    /// A main menu: File (New Tab ⌘T, the Quick Detour item ⌥⌘N), View > Zoom
    /// (Actual Size ⌘0), Edit (Redo ⇧⌘Z spelled "Z"), Navigate (Next Tab ⌥⌘↓).
    private func mainMenu() -> NSMenu {
        let main = NSMenu(title: "Main")
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = menu("File", [
            item("New Tab", "t"),
            item("New Quick Detour Window", "n", [.command, .option],
                 action: #selector(AppDelegate.newQuickDetourWindow(_:))),
        ])
        let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let zoom = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        zoom.submenu = menu("Zoom", [item("Actual Size", "0")])
        view.submenu = menu("View", [zoom])
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = menu("Edit", [item("Redo", "Z")])
        let navigate = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: "")
        navigate.submenu = menu("Navigate", [item("Next Tab", "\u{F701}", [.command, .option])])
        for top in [file, view, edit, navigate] { main.addItem(top) }
        return main
    }

    private func problem(_ shortcut: HotKeyShortcut, menu: NSMenu? = nil,
                         system: [SystemHotKey] = []) -> HotKeyShortcutProblem? {
        HotKeyShortcutValidation.problem(for: shortcut, menu: menu ?? mainMenu(),
                                         ownAction: #selector(AppDelegate.newQuickDetourWindow(_:)),
                                         systemHotKeys: system)
    }

    func testAShortcutNeedsCommandOptionOrControl() {
        XCTAssertEqual(problem(shortcut(kVK_ANSI_K, [], "k")), .needsModifier)
        XCTAssertEqual(problem(shortcut(kVK_ANSI_K, [.shift], "k")), .needsModifier)
        XCTAssertEqual(problem(shortcut(kVK_F12, [])), .needsModifier, "even a function key")
        XCTAssertNil(problem(shortcut(kVK_ANSI_K, [.control], "k")))
        XCTAssertNil(problem(shortcut(kVK_ANSI_K, [.option], "k")))
        XCTAssertNil(problem(shortcut(kVK_ANSI_K, [.command], "k")))
        XCTAssertNil(problem(shortcut(kVK_ANSI_K, [.command, .shift], "k")))
    }

    func testAKeyWithoutANameIsRefused() {
        XCTAssertEqual(problem(shortcut(kVK_ANSI_K, [.command], "")), .unnamedKey)
    }

    func testDetoursOwnMenuShortcutsAreRefusedWithTheItemsPath() {
        XCTAssertEqual(problem(shortcut(kVK_ANSI_T, [.command], "t")), .usedByMenu("File > New Tab"))
        XCTAssertEqual(problem(shortcut(kVK_ANSI_0, [.command], "0")), .usedByMenu("View > Zoom > Actual Size"))
        XCTAssertEqual(problem(shortcut(kVK_DownArrow, [.command, .option])), .usedByMenu("Navigate > Next Tab"),
                       "a function-key item by its key code")
        XCTAssertNil(problem(shortcut(kVK_ANSI_T, [.command, .option], "t")), "other modifiers are another shortcut")
    }

    /// Control-Tab is the recent-tab switcher's (an event monitor, no menu
    /// item): a Carbon hotkey on it would take it from the switcher.
    func testDetoursNonMenuShortcutsAreRefused() {
        XCTAssertEqual(problem(shortcut(kVK_Tab, [.control])), .usedByDetour("switching to a recent tab"))
        XCTAssertEqual(problem(shortcut(kVK_Tab, [.control, .shift])), .usedByDetour("switching to a recent tab"))
        XCTAssertNil(problem(shortcut(kVK_Tab, [.control, .option])))
        XCTAssertEqual(HotKeyShortcutValidation.message(for: .usedByDetour("switching to a recent tab"),
                                                        shortcut: shortcut(kVK_Tab, [.control])),
                       "⌃⇥ is Detour's shortcut for switching to a recent tab.")
    }

    func testAnUppercaseKeyEquivalentMeansShift() {
        XCTAssertEqual(problem(shortcut(kVK_ANSI_Z, [.command, .shift], "z")), .usedByMenu("Edit > Redo"))
        XCTAssertNil(problem(shortcut(kVK_ANSI_Z, [.command], "z")))
    }

    func testTheQuickDetourItemItselfIsNoConflict() {
        XCTAssertNil(problem(.quickDetourDefault))
    }

    func testMacOSShortcutsAreRefused() {
        let spotlight = SystemHotKey(keyCode: UInt16(kVK_Space), carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(problem(shortcut(kVK_Space, [.command], " "), system: [spotlight]), .usedBySystem)
        XCTAssertNil(problem(shortcut(kVK_Space, [.control, .command], " "), system: [spotlight]))
        // macOS lists an F-key's or an arrow's shortcut with the Fn bit.
        let withFn = SystemHotKey(keyCode: UInt16(kVK_F12), carbonModifiers: UInt32(controlKey) | (1 << 17))
        XCTAssertEqual(problem(shortcut(kVK_F12, [.control]), system: [withFn]), .usedBySystem)
    }

    func testAModifierIsCheckedBeforeTheMenus() {
        let item = menu("File", [item("Plain K", "k", [])])
        let main = NSMenu(title: "Main")
        let top = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        top.submenu = item
        main.addItem(top)
        XCTAssertEqual(problem(shortcut(kVK_ANSI_K, [], "k"), menu: main), .needsModifier)
    }

    /// Against the menus that ship (the test host runs
    /// `applicationDidFinishLaunching`): Cmd-T and Shift-Cmd-N are taken, the
    /// Quick Detour item's own shortcut is not.
    func testTheRealMainMenu() {
        let real = NSApp.mainMenu
        let own = #selector(AppDelegate.newQuickDetourWindow(_:))
        XCTAssertEqual(HotKeyShortcutValidation.problem(for: shortcut(kVK_ANSI_T, [.command], "t"), menu: real,
                                                        ownAction: own, systemHotKeys: []),
                       .usedByMenu("File > New Tab"))
        XCTAssertEqual(HotKeyShortcutValidation.problem(for: shortcut(kVK_ANSI_N, [.command, .shift], "n"), menu: real,
                                                        ownAction: own, systemHotKeys: []),
                       .usedByMenu("File > New Private Window"))
        XCTAssertNil(HotKeyShortcutValidation.problem(for: .quickDetourDefault, menu: real,
                                                      ownAction: own, systemHotKeys: []))
        XCTAssertNil(HotKeyShortcutValidation.problem(for: shortcut(kVK_F12, [.control, .option, .command]), menu: real,
                                                      ownAction: own, systemHotKeys: []))
    }

    func testMessagesNameTheConflict() {
        let commandT = shortcut(kVK_ANSI_T, [.command], "t")
        XCTAssertEqual(HotKeyShortcutValidation.message(for: .usedByMenu("File > New Tab"), shortcut: commandT),
                       "⌘T is the shortcut of File > New Tab.")
        XCTAssertEqual(HotKeyShortcutValidation.message(for: .usedBySystem, shortcut: commandT),
                       "⌘T is a macOS shortcut (System Settings > Keyboard > Keyboard Shortcuts).")
        XCTAssertEqual(HotKeyShortcutValidation.message(for: .needsModifier, shortcut: commandT),
                       "Include ⌘, ⌥ or ⌃ in the shortcut.")
        XCTAssertFalse(HotKeyShortcutValidation.message(for: .unnamedKey, shortcut: commandT).isEmpty)
    }

    // MARK: - Recording

    private func outcome(_ shortcut: HotKeyShortcut, problem: HotKeyShortcutProblem? = nil) -> HotKeyRecordingOutcome {
        HotKeyRecordingOutcome.outcome(for: shortcut) { _ in problem }
    }

    func testEscapeCancels() {
        XCTAssertEqual(outcome(shortcut(kVK_Escape, [], "\u{1b}")), .cancel)
    }

    func testDeleteClears() {
        XCTAssertEqual(outcome(shortcut(kVK_Delete, [], "\u{7f}")), .clear)
        XCTAssertEqual(outcome(shortcut(kVK_ForwardDelete, [])), .clear)
    }

    func testEscapeOrDeleteWithAModifierIsAShortcut() {
        let commandEscape = shortcut(kVK_Escape, [.command, .option])
        XCTAssertEqual(outcome(commandEscape), .record(commandEscape))
        let commandDelete = shortcut(kVK_Delete, [.control])
        XCTAssertEqual(outcome(commandDelete), .record(commandDelete))
    }

    func testAValidShortcutIsRecordedAndAProblemRefused() {
        let valid = shortcut(kVK_ANSI_K, [.control, .command], "k")
        XCTAssertEqual(outcome(valid), .record(valid))
        XCTAssertEqual(outcome(valid, problem: .usedBySystem), .refuse(.usedBySystem))
    }
}
