import XCTest
import AppKit
@testable import Detour

/// TASK-295: Spaces › the first nine spaces, on ⌃1–⌃9 by default.
///
/// The pure mapping (`SpaceJump`), then the real menu bar of the test host
/// (`applicationDidFinishLaunching` builds it) and real windows: the nine
/// static items, how `updateSpacesMenu` titles and hides them, the key
/// matching of a hidden one, and that adding, reordering and deleting spaces
/// changes what a shortcut opens with no menu rebuild.
nonisolated final class SpaceJumpTests: XCTestCase {

    // MARK: - The mapping (pure)

    @MainActor func testFewerThanNineSpacesLeaveTheLaterPositionsEmpty() {
        let spaces = ["a", "b", "c"]
        XCTAssertEqual(SpaceJump.target(ofPosition: 1, in: spaces), "a")
        XCTAssertEqual(SpaceJump.target(ofPosition: 3, in: spaces), "c")
        for position in 4...9 {
            XCTAssertNil(SpaceJump.target(ofPosition: position, in: spaces), "\(position)")
        }
        XCTAssertTrue(SpaceJump.unnumbered(spaces).isEmpty)
        XCTAssertNil(SpaceJump.target(ofPosition: 1, in: [String]()), "no spaces at all")
    }

    @MainActor func testMoreThanNineSpacesNumberOnlyTheFirstNine() {
        let spaces = (1...12).map { "s\($0)" }
        for position in 1...9 {
            XCTAssertEqual(SpaceJump.target(ofPosition: position, in: spaces), "s\(position)")
        }
        XCTAssertNil(SpaceJump.target(ofPosition: 10, in: spaces), "only nine positions have a shortcut")
        XCTAssertEqual(Array(SpaceJump.unnumbered(spaces)), ["s10", "s11", "s12"])
    }

    @MainActor func testExactlyNineSpacesLeaveNoneUnnumbered() {
        let spaces = (1...9).map { "s\($0)" }
        XCTAssertEqual(SpaceJump.target(ofPosition: 9, in: spaces), "s9")
        XCTAssertTrue(SpaceJump.unnumbered(spaces).isEmpty)
    }

    @MainActor func testAReorderMovesWhatAPositionOpens() {
        var spaces = ["work", "home", "study"]
        XCTAssertEqual(SpaceJump.target(ofPosition: 1, in: spaces), "work")
        spaces.insert(spaces.remove(at: 2), at: 0)
        XCTAssertEqual(SpaceJump.target(ofPosition: 1, in: spaces), "study")
        XCTAssertEqual(SpaceJump.target(ofPosition: 2, in: spaces), "work")
    }

    @MainActor func testPositionsOutsideOneToNineOpenNothing() {
        let spaces = (1...12).map { "s\($0)" }
        XCTAssertNil(SpaceJump.target(ofPosition: 0, in: spaces))
        XCTAssertNil(SpaceJump.target(ofPosition: -1, in: spaces))
    }

    // MARK: - The registry

    @MainActor func testNineParameterlessCommandsOnControlDigits() {
        let commands = BrowserCommands.jumpToSpace
        XCTAssertEqual(commands.map(\.id.rawValue), (1...9).map { "space.jump-\($0)" })
        XCTAssertEqual(commands.map(\.title), (1...9).map { "Switch to Space \($0)" })
        XCTAssertEqual(commands.compactMap(\.keyEquivalent?.displayString), (1...9).map { "⌃\($0)" })
        XCTAssertEqual(Set(commands.map(\.action)).count, 9, "one action per position")
        for command in commands {
            XCTAssertTrue(command.parameters.isEmpty, "\(command.id)")
            XCTAssertEqual(command.bindability, .bindable, "\(command.id): listed in Settings > Shortcuts")
            XCTAssertFalse(command.palette.isOffered, "\(command.id)")
            XCTAssertTrue(BrowserWindowController.instancesRespond(to: command.action), "\(command.id)")
            XCTAssertFalse(QuickDetourWindowController.instancesRespond(to: command.action), "\(command.id)")
        }
        let spaces = BrowserCommands.menus.first { $0.title == "Spaces" }?.commands.map(\.id.rawValue) ?? []
        XCTAssertEqual(spaces, ["space.next", "space.previous"] + (1...9).map { "space.jump-\($0)" }
                       + ["space.switch", "tab.move-to-space", "space.manage"])
    }

    @MainActor func testAvailableInANormalWindowOnly() {
        struct Context: CommandContext { let commandWindowKind: CommandWindowKind }
        for command in BrowserCommands.jumpToSpace {
            XCTAssertTrue(command.isAvailable(in: Context(commandWindowKind: .normal)), "\(command.id)")
            for kind in [CommandWindowKind.private, .quickDetour, .quarantine] {
                XCTAssertFalse(command.isAvailable(in: Context(commandWindowKind: kind)), "\(command.id) in \(kind)")
            }
        }
    }

    // MARK: - The menu

    @MainActor private var store: TabStore { .shared }
    private var profile: Profile!
    private var createdSpaces: [Space] = []
    private var windows: [BrowserWindowController] = []
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        ShortcutBindingStore.shared.resetAll()
        profile = store.addProfile(name: "Jump \(UUID().uuidString.prefix(4))")
    }

    @MainActor override func tearDown() async throws {
        for wc in windows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for space in createdSpaces where store.spaces.contains(where: { $0.id == space.id }) {
            store.forceRemoveSpace(id: space.id)
        }
        createdSpaces.removeAll()
        if let profile {
            store.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        ShortcutBindingStore.shared.resetAll()
        store.undoManager.removeAllActions()
        try await super.tearDown()
    }

    @MainActor private func addSpace(_ name: String) -> Space {
        let space = store.addSpace(name: name, emoji: "🧭", colorHex: "007AFF", profileID: profile.id)
        createdSpaces.append(space)
        return space
    }

    @MainActor private func spacesMenu() throws -> NSMenu {
        try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Spaces" })
    }

    @MainActor private func jumpItem(_ position: Int) throws -> NSMenuItem {
        try XCTUnwrap(CommandDispatch.menuItem(for: BrowserCommands.jumpToSpace[position - 1].id, in: NSApp.mainMenu))
    }

    @MainActor private func rebuild() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        delegate.menuNeedsUpdate(try spacesMenu())
    }

    @MainActor private func keyEvent(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: 0)!
    }

    /// Runs the run loop until `condition` holds or `timeout` passes. A
    /// press switches spaces when the sidebar's 0.08–0.15 s slide ends (its
    /// `NSAnimationContext` completion), measured at 0.08–0.17 s in a group
    /// run; the one failure under load (TASK-365, its line not recorded) is
    /// most likely that slide outlasting the old 2 s, so the wait is
    /// generous. A met condition returns at once.
    @MainActor private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor private func makeWindow(showing space: Space?, incognito: Bool = false) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: incognito)
        wc.sidebarSplitView.autosaveName = nil
        if let space { wc.setActiveSpace(id: space.id, selectTab: false) }
        wc.showWindow(nil)
        windows.append(wc)
        return wc
    }

    /// Presses ⌃`position` as the Spaces menu's key matching sees it, and runs
    /// the matched item in `window` as AppKit runs a key equivalent (its
    /// target along the window's responder chain, its validation).
    @MainActor @discardableResult
    private func press(_ position: Int, in window: NSWindow) throws -> Bool {
        let menu = try spacesMenu()
        guard let item = MenuKeyEquivalentMatcher.item(matching: keyEvent("\(position)", [.control]), in: menu.items),
              let command = BrowserCommands.command(for: item) else { return false }
        return CommandDispatch.perform(command, in: window, menu: NSApp.mainMenu)
    }

    @MainActor func testTheNineItemsAreStaticWithControlDigitsAndKeepTheirKeysWhenHidden() throws {
        let menu = try spacesMenu()
        for position in 1...9 {
            let item = try jumpItem(position)
            XCTAssertTrue(item.menu === menu, "\(position)")
            XCTAssertEqual(item.keyEquivalent, "\(position)")
            XCTAssertEqual(item.keyEquivalentModifierMask, [.control])
            XCTAssertTrue(item.allowsKeyEquivalentWhenHidden, "\(position): a hidden one swallows the press")
            XCTAssertNil(item.target, "the key window's controller, through the responder chain")
        }
        let titles = menu.items.map { $0.isSeparatorItem ? "---" : ($0.identifier?.rawValue ?? "dynamic") }
        let manage = try XCTUnwrap(titles.firstIndex(of: "space.manage"))
        XCTAssertEqual(Array(titles[0..<12]), ["space.next", "space.previous", "---"] + (1...9).map { "space.jump-\($0)" })
        XCTAssertGreaterThan(manage, 11)
    }

    @MainActor func testTheMenuTitlesTheFirstNineSpacesAndHidesEmptyPositions() throws {
        _ = addSpace("Jump A")
        try rebuild()
        let spaces = store.nonIncognitoSpaces
        for position in 1...9 {
            let item = try jumpItem(position)
            if let space = SpaceJump.target(ofPosition: position, in: spaces) {
                XCTAssertFalse(item.isHidden, "\(position)")
                XCTAssertEqual(item.title, "\(space.emoji) \(space.name)")
            } else {
                XCTAssertTrue(item.isHidden, "\(position) has no space")
                XCTAssertEqual(item.title, "Switch to Space \(position)")
            }
        }
        // No dynamic space.switch item stands for one of the first nine.
        let dynamic = try spacesMenu().items.filter { $0.action == BrowserCommands.switchToSpace.action }
        XCTAssertEqual(dynamic.count, max(0, spaces.count - 9))
    }

    @MainActor func testSpacesAfterTheNinthAreListedWithNoShortcut() throws {
        let missing = max(0, 11 - store.nonIncognitoSpaces.count)
        for index in 0..<missing { _ = addSpace("Jump \(index)") }
        try rebuild()
        let spaces = store.nonIncognitoSpaces
        XCTAssertGreaterThanOrEqual(spaces.count, 11)
        for position in 1...9 {
            XCTAssertFalse(try jumpItem(position).isHidden, "\(position)")
        }
        let dynamic = try spacesMenu().items.filter { $0.action == BrowserCommands.switchToSpace.action }
        XCTAssertEqual(dynamic.compactMap { $0.representedObject as? UUID }, spaces.dropFirst(9).map(\.id))
        XCTAssertTrue(dynamic.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    @MainActor func testAHiddenPositionItemIsStillMatchedSoThePressIsSwallowed() throws {
        try rebuild()
        let position = try XCTUnwrap((1...9).first { SpaceJump.target(ofPosition: $0, in: store.nonIncognitoSpaces) == nil },
                                     "the test host has fewer than nine spaces")
        let item = try jumpItem(position)
        XCTAssertTrue(item.isHidden)
        let menu = try spacesMenu()
        XCTAssertTrue(MenuKeyEquivalentMatcher.item(matching: keyEvent("\(position)", [.control]), in: menu.items) === item)
    }

    /// AC #4: what a shortcut opens follows adds, reorders and deletes at
    /// once, with no menu rebuild in between (the menu is only rebuilt when
    /// it opens).
    @MainActor func testAddReorderAndDeleteChangeWhatAShortcutOpensWithNoMenuRebuild() throws {
        let first = addSpace("Jump First")
        let wc = makeWindow(showing: first)
        let window = try XCTUnwrap(wc.window)
        try rebuild()

        // Added after the last rebuild: its position's item is still hidden.
        let added = addSpace("Jump Added")
        let addedPosition = try XCTUnwrap(store.nonIncognitoSpaces.firstIndex { $0.id == added.id }) + 1
        try XCTSkipIf(addedPosition > 9, "the test host already has nine spaces")
        XCTAssertTrue(try jumpItem(addedPosition).isHidden, "precondition: not rebuilt")
        XCTAssertTrue(try press(addedPosition, in: window))
        spin { wc.activeSpaceID == added.id }
        XCTAssertEqual(wc.activeSpaceID, added.id, "the new space, before the menu was rebuilt")

        // Reordered: the added space moves to the front.
        let from = try XCTUnwrap(store.spaces.firstIndex { $0.id == added.id })
        store.moveSpace(from: from, to: 0)
        let firstPosition = try XCTUnwrap(store.nonIncognitoSpaces.firstIndex { $0.id == first.id }) + 1
        XCTAssertTrue(try press(firstPosition, in: window))
        spin { wc.activeSpaceID == first.id }
        XCTAssertEqual(wc.activeSpaceID, first.id)
        XCTAssertTrue(try press(1, in: window))
        spin { wc.activeSpaceID == added.id }
        XCTAssertEqual(wc.activeSpaceID, added.id, "position 1 is the moved space now")

        // Deleted: the last position has no space; the press is answered
        // (enabled, so it is swallowed) and changes nothing.
        let lastPosition = store.nonIncognitoSpaces.count
        store.forceRemoveSpace(id: first.id)
        XCTAssertNil(SpaceJump.target(ofPosition: lastPosition, in: store.nonIncognitoSpaces))
        let before = wc.activeSpaceID
        XCTAssertTrue(try press(lastPosition, in: window), "enabled: the press does not fall through")
        spin(until: { false }, timeout: 0.2)
        XCTAssertEqual(wc.activeSpaceID, before)
    }

    @MainActor func testOnlyTheWindowItRunsInSwitches() throws {
        let a = addSpace("Jump A")
        let b = addSpace("Jump B")
        let one = makeWindow(showing: a)
        let two = makeWindow(showing: a)
        let bPosition = try XCTUnwrap(store.nonIncognitoSpaces.firstIndex { $0.id == b.id }) + 1
        try XCTSkipIf(bPosition > 9, "the test host already has nine spaces")
        XCTAssertTrue(try press(bPosition, in: try XCTUnwrap(two.window)))
        spin { two.activeSpaceID == b.id }
        XCTAssertEqual(two.activeSpaceID, b.id)
        XCTAssertEqual(one.activeSpaceID, a.id, "the other window keeps its space")
    }

    @MainActor func testDisabledInAPrivateWindow() throws {
        _ = addSpace("Jump A")
        let wc = makeWindow(showing: nil, incognito: true)
        let privateSpace = wc.activeSpaceID
        XCTAssertFalse(try press(1, in: try XCTUnwrap(wc.window)), "disabled")
        XCTAssertEqual(wc.activeSpaceID, privateSpace)
        wc.jumpToSpace(position: 1)
        XCTAssertEqual(wc.activeSpaceID, privateSpace, "the action itself refuses too")
    }

    // MARK: - Bindings (TASK-327)

    @MainActor func testARebindingMovesThePositionsShortcut() throws {
        let store = ShortcutBindingStore.shared
        let id = BrowserCommands.jumpToSpace[1].id
        store.setKeyEquivalent(KeyEquivalent("2", [.command]), for: id)
        let item = try jumpItem(2)
        XCTAssertEqual(item.keyEquivalent, "2")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        let menu = try spacesMenu()
        XCTAssertTrue(MenuKeyEquivalentMatcher.item(matching: keyEvent("2", [.command]), in: menu.items) === item)
        XCTAssertNil(MenuKeyEquivalentMatcher.item(matching: keyEvent("2", [.control]), in: menu.items))
        store.reset(id)
        XCTAssertEqual(item.keyEquivalent, "2")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.control])
    }
}
