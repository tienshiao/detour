import XCTest
import AppKit
@testable import Detour

/// TASK-320: the main menu is built from the command registry. These tests
/// pin what every item of the real `NSApp.mainMenu` is and does, so the move
/// onto the registry changes nothing a user sees: written against the menu
/// as it was built item by item, and unchanged since.
///
/// - The structure: every item's title, key equivalent, modifier mask,
///   action, target and tag, and the separators, in order.
/// - The enablement and post-validation titles of every item Detour answers
///   (window controllers, the app delegate) in a normal window with a page, a
///   normal window with nothing selected, a Private window, a Quick Detour
///   and a quarantine. Resolved the way `run_menu_item` resolves an item for
///   a window that need not be key (`AutomationMenus.resolve`), from the
///   window itself as first responder, so a page's web view (which answers
///   Back and Forward itself) does not stand in for the controller.
///
/// The test host runs `applicationDidFinishLaunching`, so `NSApp.mainMenu`
/// is the production menu (without Check for Updates…, which only a run
/// that starts Sparkle has).
nonisolated final class MainMenuCharacterizationTests: XCTestCase {

    @MainActor private var store: TabStore { .shared }
    private var profile: Profile!
    private var space: Space!
    private var emptySpace: Space!
    private var windows: [BrowserWindowController] = []
    private var quickDetours: [QuickDetourWindowController] = []
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        profile = store.addProfile(name: "Menu Pin \(UUID().uuidString.prefix(4))")
        space = store.addSpace(name: "Menu Pin", emoji: "📌", colorHex: "007AFF", profileID: profile.id)
        emptySpace = store.addSpace(name: "Menu Empty", emoji: "🫙", colorHex: "007AFF", profileID: profile.id)
        store.undoManager.removeAllActions()
    }

    @MainActor override func tearDown() async throws {
        for controller in quickDetours {
            controller.closeDisposition = .discard
            controller.close()
        }
        quickDetours.removeAll()
        for wc in windows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for space in [space, emptySpace].compactMap({ $0 }) {
            for tab in space.tabs { tab.teardown() }
            for entry in space.pinnedEntries { entry.tab?.teardown() }
            store.clearClosedTabRecords(spaceIDs: [space.id])
            store.forceRemoveSpace(id: space.id)
        }
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

    @MainActor private func makeWindow(showing space: Space?, incognito: Bool = false) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: incognito)
        wc.sidebarSplitView.autosaveName = nil
        if let space { wc.setActiveSpace(id: space.id, selectTab: false) }
        wc.showWindow(nil)
        windows.append(wc)
        return wc
    }

    /// A normal window on the test's space with two pages, the first selected.
    @MainActor private func windowWithPage() -> BrowserWindowController {
        let wc = makeWindow(showing: space)
        let first = store.addTab(in: space, url: URL(string: "https://menu-pin.invalid/one")!)
        _ = store.addTab(in: space, url: URL(string: "https://menu-pin.invalid/two")!)
        wc.selectTab(id: first.id)
        return wc
    }

    /// A Private window with one page selected.
    @MainActor private func privateWindowWithPage() throws -> BrowserWindowController {
        let wc = makeWindow(showing: nil, incognito: true)
        let privateSpace = try XCTUnwrap(wc.activeSpace)
        let tab = store.addTab(in: privateSpace, url: URL(string: "https://menu-pin.invalid/private")!)
        wc.selectTab(id: tab.id)
        return wc
    }

    @MainActor private func quickDetour() -> QuickDetourWindowController {
        let controller = QuickDetourWindowController.open(profile: profile, sourceSpace: space,
                                                           url: URL(string: "https://menu-pin.invalid/quick")!)
        quickDetours.append(controller)
        return controller
    }

    @MainActor private func quarantine() -> QuickDetourWindowController {
        let controller = QuickDetourWindowController.openQuarantine(
            url: URL(string: "https://menu-pin.invalid/quarantine")!,
            privateProfile: store.ensureIncognitoProfile(), sourceSpace: space)
        quickDetours.append(controller)
        return controller
    }

    // MARK: - Reading the menu

    /// The dynamic items (spaces, extensions, Develop's inspect and reload
    /// items) and the window list AppKit keeps in the Window menu depend on
    /// what else the test host has open; they are not built from the registry.
    @MainActor private static func isDynamic(_ item: NSMenuItem) -> Bool {
        [7000, 8000, 9000].contains(item.tag)
            || item.action == #selector(NSWindow.makeKeyAndOrderFront(_:))
            || item.target is NSWindow
    }

    /// What AppKit adds to the menus by itself (Writing Tools, AutoFill,
    /// dictation and Emoji & Symbols to Edit; Bring All to Front to Window),
    /// which varies with the macOS release and is not Detour's.
    @MainActor private static func isAppKitInsertion(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        return [#selector(NSMenu.submenuAction(_:)), #selector(NSApplication.orderFrontCharacterPalette(_:)),
                #selector(NSApplication.arrangeInFront(_:)), NSSelectorFromString("startDictation:")].contains(action)
    }

    /// A menu's own items: not dynamic, not AppKit's, and no separator left
    /// trailing where AppKit's items were.
    @MainActor private static func ownItems(of menu: NSMenu) -> [NSMenuItem] {
        var items = menu.items.filter { !isDynamic($0) && !isAppKitInsertion($0) }
        while items.last?.isSeparatorItem == true { items.removeLast() }
        return items
    }

    @MainActor private static func glyphs(_ mask: NSEvent.ModifierFlags) -> String {
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text
    }

    @MainActor private static func spelled(_ key: String) -> String {
        key.unicodeScalars.map { scalar in
            (0x21...0x7E).contains(scalar.value) ? String(scalar) : String(format: "U+%04X", scalar.value)
        }.joined()
    }

    @MainActor private static func targetName(_ target: AnyObject?) -> String {
        guard let target else { return "nil" }
        return String(describing: type(of: target))
    }

    /// One line per item, under a "[Menu]" line per menu of the bar.
    @MainActor static func structure(of mainMenu: NSMenu) -> [String] {
        var lines: [String] = []
        for barItem in mainMenu.items {
            guard let submenu = barItem.submenu else { continue }
            lines.append("[\(AutomationMenus.displayTitle(barItem))]")
            for item in ownItems(of: submenu) {
                if item.isSeparatorItem {
                    lines.append("---")
                    continue
                }
                let action = item.action.map(NSStringFromSelector) ?? "nil"
                lines.append("\(item.title) | \(glyphs(item.keyEquivalentModifierMask))\(spelled(item.keyEquivalent))"
                             + " | \(action) | \(targetName(item.target as AnyObject?)) | \(item.tag)")
            }
        }
        return lines
    }

    /// Items Detour itself answers: not AppKit's text, window and
    /// application items, whose enablement is AppKit's own.
    @MainActor private static func isDetours(_ item: NSMenuItem) -> Bool {
        guard !item.isSeparatorItem, !isDynamic(item), let action = item.action else { return false }
        if let target = item.target { return target is AppDelegate }
        return BrowserWindowController.instancesRespond(to: action)
            || QuickDetourWindowController.instancesRespond(to: action)
            || AppDelegate.instancesRespond(to: action)
    }

    /// "Menu › action[#tag]: on|off" for every item Detour answers,
    /// resolved in `window` with the window itself first responder, then
    /// "→ Title" when validation retitled the item. Keyed by the action, not
    /// the title, because validation retitles the shared items.
    @MainActor static func enablement(in window: NSWindow) -> [String] {
        window.makeFirstResponder(nil)
        guard let mainMenu = NSApp.mainMenu else { return [] }
        var lines: [String] = []
        for barItem in mainMenu.items {
            guard let submenu = barItem.submenu else { continue }
            let menuTitle = AutomationMenus.displayTitle(barItem)
            for item in submenu.items where isDetours(item) {
                let key = NSStringFromSelector(item.action!) + (item.tag == 0 ? "" : "#\(item.tag)")
                let before = item.title
                item.title = "•"
                let enabled = (try? AutomationMenus.resolve(item, in: window, allowPrivate: true)) != nil
                let retitled = item.title == "•" ? nil : item.title
                item.title = retitled ?? before
                lines.append("\(menuTitle) › \(key) \(enabled ? "on" : "off")" + (retitled.map { " → \($0)" } ?? ""))
            }
        }
        return lines
    }

    // MARK: - Golden

    /// The main menu as it was built item by item before the registry.
    /// Titles that validation sets are shown as "(validated)": the items are
    /// shared, so what they say depends on the last window that validated
    /// them; `BrowserCommandRegistryTests` pins the titles they are built with.
    private static let structureGolden: [String] = [
        "[Detour]",
        "About Detour | ⌘ | showAboutPanel: | nil | 0",
        "---",
        "Settings… | ⌘, | openSettings | nil | 0",
        "---",
        "Hide Detour | ⌘h | hide: | nil | 0",
        "Hide Others | ⌥⌘h | hideOtherApplications: | nil | 0",
        "Show All | ⌘ | unhideAllApplications: | nil | 0",
        "---",
        "Quit Detour | ⌘q | terminate: | nil | 0",
        "[File]",
        "New Tab | ⌘t | newTab: | nil | 0",
        "Open Location… | ⌘l | focusAddressBar: | nil | 0",
        "Close Tab | ⌘w | closeCurrentTab: | nil | 0",
        "Reopen Closed Tab | ⇧⌘t | reopenClosedTab: | nil | 0",
        "Pin/Unpin Tab | ⌘d | togglePinTab: | nil | 0",
        "---",
        "New Window | ⌘n | createNewWindow | nil | 0",
        "New Private Window | ⇧⌘n | createNewIncognitoWindow | nil | 0",
        "New Quick Detour Window | ⌥⌘n | newQuickDetourWindow: | nil | 0",
        "Open Quick Detour in Space | ⌘o | openInDefaultSpace: | nil | 0",
        "---",
        "Import from Arc… | ⌘ | importFromArc: | nil | 0",
        "[Edit]",
        "Undo | ⌘z | browserUndo: | nil | 0",
        "Redo | ⌘Z | browserRedo: | nil | 0",
        "---",
        "Cut | ⌘x | cut: | nil | 0",
        "Copy | ⌘c | copy: | nil | 0",
        "Copy URL | ⇧⌘c | copyCurrentURL: | nil | 0",
        "Paste | ⌘v | paste: | nil | 0",
        "Select All | ⌘a | selectAll: | nil | 0",
        "---",
        "Find... | ⌘f | showFindBar: | nil | 0",
        "Find Next | ⌘g | findNext: | nil | 0",
        "Find Previous | ⇧⌘g | findPrevious: | nil | 0",
        "[View]",
        "Toggle Sidebar | ⌘s | toggleSidebarMode: | nil | 0",
        "Reload Page | ⌘r | reloadPage: | nil | 0",
        "---",
        "Actual Size | ⌘0 | zoomActualSize: | nil | 0",
        "Zoom In | ⌘+ | zoomIn: | nil | 0",
        "Zoom Out | ⌘- | zoomOut: | nil | 0",
        "[Navigate]",
        "Back | ⌘[ | goBack: | nil | 0",
        "Forward | ⌘] | goForward: | nil | 0",
        "---",
        "Previous Tab | ⌥⌘U+F700 | selectPreviousTab: | nil | 0",
        "Next Tab | ⌥⌘U+F701 | selectNextTab: | nil | 0",
        "---",
        "Show All History | ⌘y | showHistory: | nil | 0",
        "Show Archived Tabs | ⌘ | showArchivedTabs: | nil | 0",
        "Clear Archived Tabs… | ⌘ | clearArchivedTabs: | nil | 0",
        "[Spaces]",
        "Next Space | ⌥⌘U+F703 | nextSpace: | nil | 0",
        "Previous Space | ⌥⌘U+F702 | previousSpace: | nil | 0",
        "---",
        "Switch to Space 1 | ⌃1 | jumpToSpace1: | nil | 0",
        "Switch to Space 2 | ⌃2 | jumpToSpace2: | nil | 0",
        "Switch to Space 3 | ⌃3 | jumpToSpace3: | nil | 0",
        "Switch to Space 4 | ⌃4 | jumpToSpace4: | nil | 0",
        "Switch to Space 5 | ⌃5 | jumpToSpace5: | nil | 0",
        "Switch to Space 6 | ⌃6 | jumpToSpace6: | nil | 0",
        "Switch to Space 7 | ⌃7 | jumpToSpace7: | nil | 0",
        "Switch to Space 8 | ⌃8 | jumpToSpace8: | nil | 0",
        "Switch to Space 9 | ⌃9 | jumpToSpace9: | nil | 0",
        "Manage Spaces… | ⌘ | openSpacesSettings: | nil | 0",
        "[Extensions]",
        "Add Extensions… | ⌘ | openChromeWebStore | nil | 0",
        "Manage Extensions… | ⌘ | showExtensionsSettings | nil | 0",
        "Check for Extension Updates | ⌘ | checkForExtensionUpdates | nil | 0",
        "[Develop]",
        "Web Inspector | ⌥⌘i | showWebInspector: | nil | 0",
        "---",
        "Load Unpacked Extension… | ⌘ | loadUnpackedExtension | nil | 0",
        "[Window]",
        "Minimize | ⌘m | performMiniaturize: | nil | 0",
        "Zoom | ⌘ | performZoom: | nil | 0",
        "[Help]",
        "Detour Help | ⌘ | openHelpLink: | AppDelegate | 0",
        "Keyboard Shortcuts | ⌘ | openHelpLink: | AppDelegate | 1",
        "Switching from Arc | ⌘ | openHelpLink: | AppDelegate | 2",
        "---",
        "Release Notes | ⌘ | openHelpLink: | AppDelegate | 3",
        "Report an Issue | ⌘ | openHelpLink: | AppDelegate | 4",
    ]

    /// Every item Detour answers, in menu order, by action (and tag).
    private static let detourItems: [String] = [
        "Detour › showAboutPanel:",
        "Detour › openSettings",
        "File › newTab:",
        "File › focusAddressBar:",
        "File › closeCurrentTab:",
        "File › reopenClosedTab:",
        "File › togglePinTab:",
        "File › createNewWindow",
        "File › createNewIncognitoWindow",
        "File › newQuickDetourWindow:",
        "File › openInDefaultSpace:",
        "File › importFromArc:",
        "Edit › browserUndo:",
        "Edit › browserRedo:",
        "Edit › copyCurrentURL:",
        "Edit › showFindBar:",
        "Edit › findNext:",
        "Edit › findPrevious:",
        "View › toggleSidebarMode:",
        "View › reloadPage:",
        "View › zoomActualSize:",
        "View › zoomIn:",
        "View › zoomOut:",
        "Navigate › goBack:",
        "Navigate › goForward:",
        "Navigate › selectPreviousTab:",
        "Navigate › selectNextTab:",
        "Navigate › showHistory:",
        "Navigate › showArchivedTabs:",
        "Navigate › clearArchivedTabs:",
        "Spaces › nextSpace:",
        "Spaces › previousSpace:",
        "Spaces › jumpToSpace1:",
        "Spaces › jumpToSpace2:",
        "Spaces › jumpToSpace3:",
        "Spaces › jumpToSpace4:",
        "Spaces › jumpToSpace5:",
        "Spaces › jumpToSpace6:",
        "Spaces › jumpToSpace7:",
        "Spaces › jumpToSpace8:",
        "Spaces › jumpToSpace9:",
        "Spaces › openSpacesSettings:",
        "Extensions › openChromeWebStore",
        "Extensions › showExtensionsSettings",
        "Extensions › checkForExtensionUpdates",
        "Develop › showWebInspector:",
        "Develop › loadUnpackedExtension",
        "Help › openHelpLink:",
        "Help › openHelpLink:#1",
        "Help › openHelpLink:#2",
        "Help › openHelpLink:#3",
        "Help › openHelpLink:#4",
    ]

    @MainActor private func expected(off: Set<String>, retitled: [String: String] = [:]) -> [String] {
        Self.detourItems.map { key in
            "\(key) \(off.contains(key) ? "off" : "on")" + (retitled[key].map { " → \($0)" } ?? "")
        }
    }

    /// Store facts the test does not set: whether any space has archived tabs.
    @MainActor private var archiveOff: Set<String> {
        store.hasClosedTabRecords() ? [] : ["Navigate › clearArchivedTabs:"]
    }

    private static let browserTitles = [
        "File › openInDefaultSpace:": "Open Quick Detour in Space",
        "Edit › browserUndo:": "Undo",
        "Edit › browserRedo:": "Redo",
    ]

    /// What a Quick Detour and a quarantine do not answer (no such action on
    /// their controller) or disable (no history to go back or forward in).
    private static let quickDetourOff = Set([
        "File › newTab:", "File › reopenClosedTab:", "File › togglePinTab:", "Edit › browserUndo:",
        "Edit › browserRedo:", "View › toggleSidebarMode:", "Navigate › goBack:", "Navigate › goForward:",
        "Navigate › selectPreviousTab:", "Navigate › selectNextTab:", "Navigate › showHistory:",
        "Navigate › showArchivedTabs:", "Navigate › clearArchivedTabs:", "Spaces › nextSpace:",
        "Spaces › previousSpace:", "Spaces › openSpacesSettings:",
    ] + spaceJumps)

    /// Spaces › the first nine spaces (TASK-295): answered only in a normal window.
    private static let spaceJumps: [String] = (1...9).map { "Spaces › jumpToSpace\($0):" }

    // MARK: - Structure

    @MainActor func testTheMainMenuHasEveryItemItHadBeforeTheRegistry() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        // Validation retitles these; the Spaces menu titles its position
        // items with the space at each position when it opens (TASK-295).
        let retitled = Set(["togglePinTab:", "browserUndo:", "browserRedo:", "openInDefaultSpace:"]
            + (1...9).map { "jumpToSpace\($0):" })
        let lines = Self.structure(of: menu).map { line -> String in
            let fields = line.components(separatedBy: " | ")
            guard fields.count == 5, retitled.contains(fields[2]) else { return line }
            return (["(validated)"] + fields.dropFirst()).joined(separator: " | ")
        }
        let golden = Self.structureGolden.map { line -> String in
            let fields = line.components(separatedBy: " | ")
            guard fields.count == 5, retitled.contains(fields[2]) else { return line }
            return (["(validated)"] + fields.dropFirst()).joined(separator: " | ")
        }
        XCTAssertEqual(lines, golden)
        for (line, want) in zip(lines, golden) where line != want {
            XCTFail("\(line) ≠ \(want)")
        }
    }

    // MARK: - Enablement

    @MainActor func testEnablementInANormalWindowWithAPage() throws {
        let wc = windowWithPage()
        spin()
        var titles = Self.browserTitles
        titles["File › togglePinTab:"] = "Pin Tab"
        XCTAssertEqual(Self.enablement(in: try XCTUnwrap(wc.window)), expected(
            off: Set(["File › reopenClosedTab:", "File › openInDefaultSpace:", "Edit › browserUndo:",
                      "Edit › browserRedo:"]).union(archiveOff),
            retitled: titles))
    }

    @MainActor func testEnablementInANormalWindowWithNothingSelected() throws {
        let wc = makeWindow(showing: emptySpace)
        spin()
        XCTAssertEqual(Self.enablement(in: try XCTUnwrap(wc.window)), expected(
            off: Set(["File › reopenClosedTab:", "File › togglePinTab:", "File › openInDefaultSpace:",
                      "Edit › browserUndo:", "Edit › browserRedo:", "Navigate › selectPreviousTab:",
                      "Navigate › selectNextTab:", "Spaces › nextSpace:"]).union(archiveOff),
            retitled: Self.browserTitles))
    }

    @MainActor func testEnablementInAPrivateWindow() throws {
        let wc = try privateWindowWithPage()
        spin()
        XCTAssertEqual(Self.enablement(in: try XCTUnwrap(wc.window)), expected(
            off: Set(["File › reopenClosedTab:", "File › togglePinTab:", "File › openInDefaultSpace:",
                      "Edit › browserUndo:", "Edit › browserRedo:", "Navigate › selectPreviousTab:",
                      "Navigate › selectNextTab:", "Navigate › showArchivedTabs:", "Navigate › clearArchivedTabs:",
                      "Spaces › nextSpace:", "Spaces › previousSpace:", "Spaces › openSpacesSettings:"]
                      + Self.spaceJumps),
            retitled: Self.browserTitles))
    }

    @MainActor func testEnablementInAQuickDetour() throws {
        let controller = quickDetour()
        spin(0.2)
        XCTAssertEqual(Self.enablement(in: try XCTUnwrap(controller.window)), expected(
            off: Self.quickDetourOff, retitled: ["File › openInDefaultSpace:": "Open in 📌 Menu Pin"]))
    }

    @MainActor func testEnablementInAQuarantine() throws {
        let controller = quarantine()
        spin(0.2)
        XCTAssertEqual(Self.enablement(in: try XCTUnwrap(controller.window)), expected(
            off: Self.quickDetourOff, retitled: ["File › openInDefaultSpace:": "Open in 📌 Menu Pin"]))
    }

    // MARK: - The registry's rule is the menu's (TASK-320 AC #4)

    /// For every command with an item in the live menu: the registry's
    /// availability in `context` is the item's resolution in `window`, and,
    /// where the window answers it, the title the registry gives it is the
    /// one validation left on the item. The palette offers a command by the
    /// same `isAvailable(in:)`, so this is also what it offers.
    @MainActor private func assertRegistryAgrees(in window: NSWindow, context: any CommandContext, _ label: String,
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        window.makeFirstResponder(nil)
        let menu = try XCTUnwrap(NSApp.mainMenu)
        for command in BrowserCommands.all where command.parameters.isEmpty {
            switch command.responder {
            case .appKit, .updater: continue
            case .windowController, .appDelegate: break
            }
            guard let item = CommandDispatch.menuItem(for: command.id, in: menu) else {
                XCTFail("\(command.id) has no item in the main menu", file: file, line: line)
                continue
            }
            let resolved = (try? AutomationMenus.resolve(item, in: window, allowPrivate: true)) != nil
            XCTAssertEqual(command.isAvailable(in: context), resolved, "\(label): \(command.id)", file: file, line: line)
            if command.windowKinds.contains(context.commandWindowKind), let title = command.contextualTitle?(context) {
                XCTAssertEqual(item.title, title, "\(label): \(command.id)", file: file, line: line)
            }
        }
    }

    @MainActor func testTheRegistrysRuleIsWhatTheMenuResolvesInEveryKindOfWindow() throws {
        let normal = windowWithPage()
        spin()
        try assertRegistryAgrees(in: try XCTUnwrap(normal.window), context: normal, "a page")

        let empty = makeWindow(showing: emptySpace)
        spin()
        try assertRegistryAgrees(in: try XCTUnwrap(empty.window), context: empty, "nothing selected")

        let privateWindow = try privateWindowWithPage()
        spin()
        try assertRegistryAgrees(in: try XCTUnwrap(privateWindow.window), context: privateWindow, "Private")

        let quick = quickDetour()
        spin(0.2)
        try assertRegistryAgrees(in: try XCTUnwrap(quick.window), context: quick, "Quick Detour")

        let quarantined = quarantine()
        spin(0.2)
        try assertRegistryAgrees(in: try XCTUnwrap(quarantined.window), context: quarantined, "quarantine")
    }

    @MainActor func testTheRegistrysRuleIsWhatTheMenuResolvesForAPinnedTabAndAnUndoableClose() throws {
        let wc = windowWithPage()
        let pinned = try XCTUnwrap(space.tabs.first)
        store.pinTab(id: pinned.id, in: space)
        wc.selectTab(id: pinned.id)
        if let other = space.tabs.first { store.closeTab(id: other.id, in: space) }
        spin()
        XCTAssertTrue(wc.selectedTabIsPinned, "precondition")
        try assertRegistryAgrees(in: try XCTUnwrap(wc.window), context: wc, "pinned, after a close")
        XCTAssertEqual(CommandDispatch.menuItem(for: "tab.toggle-pin", in: NSApp.mainMenu)?.title, "Unpin Tab")
    }

    /// Every item the menu builds is a view of a registry command and says
    /// which by its identifier, which is how the palette finds the live item.
    @MainActor func testEveryOwnItemCarriesItsCommandsIdentifier() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        for barItem in menu.items {
            guard let submenu = barItem.submenu else { continue }
            for item in Self.ownItems(of: submenu) where !item.isSeparatorItem {
                let id = try XCTUnwrap(item.identifier?.rawValue, "\(item.title)")
                let command = try XCTUnwrap(BrowserCommands.command(withID: CommandID(rawValue: id)), id)
                XCTAssertEqual(command.action, item.action, id)
                XCTAssertEqual(command.tag, item.tag, id)
            }
        }
    }
}
