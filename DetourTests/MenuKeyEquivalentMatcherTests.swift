import XCTest
import AppKit
@testable import Detour

/// TASK-56: AppDelegate answers AppKit's key-equivalent query itself so that a
/// Cmd+key press no longer rebuilds the Spaces and Extensions menus.
///
/// The matcher is a fast path: on a miss the delegate answers `false` and
/// AppKit scans the existing items itself (verified in the TASK-56 review), but
/// a hit is dispatched *without* AppKit looking, so a false hit fires the wrong
/// thing. The matcher tests below pin what it claims and what it declines; the
/// "menus that ship" tests hold the invariants the delegate relies on against
/// the real main menu (the test host runs `applicationDidFinishLaunching`, so
/// `NSApp.mainMenu` is the production one).
@MainActor
final class MenuKeyEquivalentMatcherTests: XCTestCase {

    // MARK: - Fixtures

    private func keyEvent(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown,
                                           location: .zero,
                                           modifierFlags: modifiers,
                                           timestamp: 0,
                                           windowNumber: 0,
                                           context: nil,
                                           characters: characters,
                                           charactersIgnoringModifiers: characters,
                                           isARepeat: false,
                                           keyCode: 0) else {
            fatalError("could not synthesize a key event for \(characters)")
        }
        return event
    }

    /// The Spaces menu's static layout: Next/Previous Space on the arrow keys,
    /// a separator, then a plain item with no key equivalent.
    private func spacesMenuItems() -> [NSMenuItem] {
        let next = NSMenuItem(title: "Next Space",
                              action: #selector(BrowserWindowController.nextSpace(_:)),
                              keyEquivalent: "\u{F703}")
        next.keyEquivalentModifierMask = [.command, .option]
        let previous = NSMenuItem(title: "Previous Space",
                                  action: #selector(BrowserWindowController.previousSpace(_:)),
                                  keyEquivalent: "\u{F702}")
        previous.keyEquivalentModifierMask = [.command, .option]
        let manage = NSMenuItem(title: "Manage Spaces…",
                                action: #selector(BrowserWindowController.openSpacesSettings(_:)),
                                keyEquivalent: "")
        return [next, previous, .separator(), manage]
    }

    /// The Develop menu's static layout: Web Inspector on Cmd+Option+I.
    private func developMenuItems() -> [NSMenuItem] {
        let inspector = NSMenuItem(title: "Web Inspector",
                                   action: #selector(BrowserWindowController.showWebInspector(_:)),
                                   keyEquivalent: "i")
        inspector.keyEquivalentModifierMask = [.command, .option]
        return [inspector, .separator()]
    }

    // MARK: - Hits

    func testCommandOptionIMatchesWebInspector() {
        let match = MenuKeyEquivalentMatcher.item(matching: keyEvent("i", [.command, .option]),
                                                  in: developMenuItems())
        XCTAssertEqual(match?.title, "Web Inspector")
        XCTAssertEqual(match?.action, #selector(BrowserWindowController.showWebInspector(_:)))
    }

    func testCommandOptionRightArrowMatchesNextSpace() {
        // Real arrow-key events also carry `.function`, which no key equivalent
        // requires: the matcher must ignore modifiers outside the significant set.
        let event = keyEvent("\u{F703}", [.command, .option, .function])
        let match = MenuKeyEquivalentMatcher.item(matching: event, in: spacesMenuItems())
        XCTAssertEqual(match?.title, "Next Space")
    }

    func testCommandOptionLeftArrowMatchesPreviousSpace() {
        let event = keyEvent("\u{F702}", [.command, .option, .function])
        let match = MenuKeyEquivalentMatcher.item(matching: event, in: spacesMenuItems())
        XCTAssertEqual(match?.title, "Previous Space")
    }

    func testAPlainCommandLetterItemWithTheDefaultMaskMatchesACommandPress() {
        // `addItem(withTitle:action:keyEquivalent:)` leaves the mask at its
        // default of [.command].
        let menu = NSMenu(title: "View")
        let item = menu.addItem(withTitle: "Reload Page",
                                action: #selector(BrowserWindowController.reloadPage(_:)),
                                keyEquivalent: "r")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command], "precondition: default mask")

        let match = MenuKeyEquivalentMatcher.item(matching: keyEvent("r", [.command]), in: menu.items)
        XCTAssertEqual(match?.title, "Reload Page")
    }

    func testAnUppercaseKeyEquivalentImpliesShift() {
        let item = NSMenuItem(title: "Redo",
                              action: #selector(BrowserWindowController.browserRedo(_:)),
                              keyEquivalent: "Z")
        XCTAssertNotNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("Z", [.command, .shift]),
                                                      in: [item]))
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("z", [.command]), in: [item]),
                     "a Shift-less press must not fire a Shift-bearing shortcut")
    }

    // MARK: - Misses

    func testCommandIAloneDoesNotMatchTheCommandOptionItem() {
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("i", [.command]),
                                                   in: developMenuItems()))
    }

    func testExtraModifiersDoNotMatch() {
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("i", [.command, .option, .shift]),
                                                   in: developMenuItems()))
    }

    func testAKeyNoItemClaimsDoesNotMatch() {
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("k", [.command, .option]),
                                                   in: developMenuItems()))
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("t", [.command]),
                                                   in: spacesMenuItems()))
    }

    func testSeparatorsNeverMatch() {
        // A separator's keyEquivalent is empty, but assert the behaviour that
        // matters: an all-separator menu answers nothing, whatever is pressed.
        let separators = [NSMenuItem.separator(), NSMenuItem.separator()]
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("i", [.command, .option]),
                                                   in: separators))
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("q", [.command]), in: separators))
    }

    func testAnItemWithNoActionNeverMatches() {
        // The Extensions menu gives a popup-less extension a nil action; AppKit
        // could not dispatch to it, so it must not claim the keystroke.
        let item = NSMenuItem(title: "Some Extension", action: nil, keyEquivalent: "i")
        item.keyEquivalentModifierMask = [.command, .option]
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("i", [.command, .option]),
                                                   in: [item]))
    }

    func testAHiddenItemNeverMatches() {
        let item = NSMenuItem(title: "Web Inspector",
                              action: #selector(BrowserWindowController.showWebInspector(_:)),
                              keyEquivalent: "i")
        item.keyEquivalentModifierMask = [.command, .option]
        item.isHidden = true
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("i", [.command, .option]),
                                                   in: [item]))
    }

    func testTheFirstMatchWins() {
        let first = NSMenuItem(title: "First",
                               action: #selector(BrowserWindowController.reloadPage(_:)),
                               keyEquivalent: "r")
        let second = NSMenuItem(title: "Second",
                                action: #selector(BrowserWindowController.reloadPage(_:)),
                                keyEquivalent: "r")
        let match = MenuKeyEquivalentMatcher.item(matching: keyEvent("r", [.command]),
                                                  in: [first, second])
        XCTAssertEqual(match?.title, "First")
    }

    // MARK: - The menus that ship

    private func mainMenu(titled title: String) -> NSMenu? {
        NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == title }
    }

    /// The menus whose key-equivalent query AppDelegate answers.
    private func delegateDrivenMenus() -> [NSMenu] {
        guard let delegate = NSApp.delegate as? AppDelegate, let mainMenu = NSApp.mainMenu else { return [] }
        return mainMenu.items.compactMap(\.submenu).filter { $0.delegate === delegate }
    }

    func testOnlyTheSpacesAndExtensionsMenusAreDelegateDriven() {
        XCTAssertEqual(Set(delegateDrivenMenus().map(\.title)), ["Spaces", "Extensions"])
    }

    func testTheDevelopMenuHasNoDelegateSoAppKitMatchesWebInspectorItself() {
        // Cmd+Option+I is the one letter shortcut among the dynamic menus. A
        // letter is what a hand-rolled matcher gets wrong on a non-Latin
        // keyboard layout, so it must stay in a menu AppKit matches natively.
        let develop = mainMenu(titled: "Develop")
        XCTAssertNotNil(develop)
        XCTAssertNil(develop?.delegate)
        XCTAssertEqual(develop?.items.first { !$0.keyEquivalent.isEmpty }?.title, "Web Inspector")
    }

    /// The invariant `AppDelegate.menuHasKeyEquivalent` relies on: after a
    /// rebuild, every shortcut in a delegate-driven menu is a static,
    /// Command-bearing, layout-independent function key the matcher answers —
    /// no dynamic item (space, extension) carries one, since such an item
    /// would only exist after the menu had been opened once and would be
    /// dispatched without an `NSMenuItem` sender.
    func testEveryShortcutInADelegateDrivenMenuIsAStaticFunctionKeyTheMatcherAnswers() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let menus = delegateDrivenMenus()
        XCTAssertFalse(menus.isEmpty)

        for menu in menus {
            delegate.menuNeedsUpdate(menu)
            let shortcuts = menu.items.filter { !$0.keyEquivalent.isEmpty }
            for item in shortcuts {
                let scalars = Array(item.keyEquivalent.unicodeScalars)
                XCTAssertEqual(scalars.count, 1, "\(menu.title) › \(item.title)")
                XCTAssertTrue((0xF700...0xF8FF).contains(scalars.first?.value ?? 0),
                              "\(menu.title) › \(item.title) is not a function-key equivalent")
                XCTAssertTrue(item.keyEquivalentModifierMask.contains(.command),
                              "\(menu.title) › \(item.title) has no Command modifier")
                XCTAssertNil(item.representedObject, "\(menu.title) › \(item.title) looks dynamic")

                // A real function-key press also carries `.function`.
                let event = keyEvent(item.keyEquivalent, item.keyEquivalentModifierMask.union(.function))
                XCTAssertTrue(MenuKeyEquivalentMatcher.item(matching: event, in: menu.items) === item,
                              "\(menu.title) › \(item.title) is not answered by the matcher")
            }
        }
        XCTAssertEqual(Set(menus.flatMap { $0.items }.filter { !$0.keyEquivalent.isEmpty }.map(\.title)),
                       ["Next Space", "Previous Space"])
    }
}
