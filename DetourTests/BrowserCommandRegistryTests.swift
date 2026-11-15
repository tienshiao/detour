import XCTest
import AppKit
@testable import Detour

/// Every fact a rule can read, set by the test.
private struct Context: CommandContext {
    var commandWindowKind: CommandWindowKind = .normal
    var hasSelectedTab = false
    var selectedTabHasURL = false
    var selectedTabIsPinned = false
    var pageCanGoBack = false
    var pageCanGoForward = false
    var isPeekShowing = false
    var isEditingPageText = false
    var canUndoPageEdit = false
    var canRedoPageEdit = false
    var pageUndoTitle = "Undo"
    var pageRedoTitle = "Redo"
    var canUndoBrowserAction = false
    var canRedoBrowserAction = false
    var browserUndoTitle = "Undo"
    var browserRedoTitle = "Redo"
    var hasClosedTabToReopen = false
    var hasArchivedTabs = false
    var hasNextSpace = false
    var hasPreviousSpace = false
    var hasTabToStepTo = false
    var openInSpaceTitle = QuickDetourWindowController.openInMenuItemTitle
    var canOpenInSpace = false
    var selectedTabIsInSplit = false
}

/// TASK-320: the command registry. Its identifiers are API (TASK-327 keys
/// user shortcuts by them), its entries agree with the main menu and with
/// which controller answers each action, and its availability rules say what
/// the window controllers' validation said before the registry, over fake
/// contexts. (That the real menu resolves the same way in real windows is
/// `MainMenuCharacterizationTests`.)
nonisolated final class BrowserCommandRegistryTests: XCTestCase {

    @MainActor private func context(_ kind: CommandWindowKind, _ change: (inout Context) -> Void = { _ in }) -> Context {
        var context = Context(commandWindowKind: kind)
        change(&context)
        return context
    }

    // MARK: - Identifiers

    /// The shipped identifiers, in menu order. Adding a command adds a line;
    /// renaming or removing one breaks users' shortcut bindings (TASK-327).
    private static let identifiers: [String] = [
        "app.about", "app.check-for-updates", "app.settings", "app.hide", "app.hide-others", "app.show-all",
        "app.quit",
        "tab.new", "location.open", "tab.close", "tab.reopen-closed", "tab.toggle-pin", "tab.split-with",
        "window.new", "window.new-private", "quick-detour.new", "page.open-in-space", "app.import-from-arc",
        "edit.undo", "edit.redo", "edit.cut", "edit.copy", "tab.copy-url", "edit.paste", "edit.select-all",
        "find.show", "find.next", "find.previous",
        "sidebar.toggle", "page.reload", "page.zoom-reset", "page.zoom-in", "page.zoom-out",
        "page.back", "page.forward", "tab.previous", "tab.next", "history.show", "archive.show", "archive.clear",
        "space.next", "space.previous",
        "space.jump-1", "space.jump-2", "space.jump-3", "space.jump-4", "space.jump-5", "space.jump-6",
        "space.jump-7", "space.jump-8", "space.jump-9",
        "space.switch", "tab.move-to-space", "space.manage",
        "extension.show-popup", "extension.options", "extensions.add", "extensions.manage",
        "extensions.check-for-updates",
        "develop.web-inspector", "develop.load-unpacked-extension", "extension.inspect-offscreen",
        "extension.reload-unpacked",
        "window.minimize", "window.zoom",
        "help.guide", "help.keyboard-shortcuts", "help.switching-from-arc", "help.release-notes", "help.report-issue",
    ]

    @MainActor func testTheIdentifiersAreTheShippedOnes() {
        XCTAssertEqual(BrowserCommands.all.map(\.id.rawValue), Self.identifiers)
    }

    @MainActor func testIdentifiersAreUniqueDottedAndLowercase() throws {
        let ids = BrowserCommands.all.map(\.id.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate identifiers")
        let pattern = try NSRegularExpression(pattern: "^[a-z]+(-[a-z]+)*(\\.[a-z0-9]+(-[a-z0-9]+)*)+$")
        for id in ids {
            XCTAssertNotNil(pattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)), id)
        }
    }

    @MainActor func testEachCommandIsFoundByItsIdentifier() {
        for command in BrowserCommands.all {
            XCTAssertEqual(BrowserCommands.command(withID: command.id)?.id, command.id)
        }
        XCTAssertNil(BrowserCommands.command(withID: "tab.no-such-command"))
    }

    // MARK: - Agreement with the main menu

    /// The main menu's own items (not dynamic, not AppKit's insertions), by
    /// the command they are a view of.
    @MainActor private func mainMenuItems() throws -> [(item: NSMenuItem, path: String)] {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        var found: [(NSMenuItem, String)] = []
        for barItem in menu.items {
            guard let submenu = barItem.submenu else { continue }
            for item in submenu.items where !item.isSeparatorItem && ![7000, 8000, 9000].contains(item.tag) {
                guard let action = item.action, !(item.target is NSWindow),
                      ![#selector(NSMenu.submenuAction(_:)), #selector(NSApplication.orderFrontCharacterPalette(_:)),
                        #selector(NSApplication.arrangeInFront(_:)), NSSelectorFromString("startDictation:"),
                        #selector(NSWindow.makeKeyAndOrderFront(_:))].contains(action) else { continue }
                found.append((item, "\(AutomationMenus.displayTitle(barItem)) › \(item.title)"))
            }
        }
        return found
    }

    /// The registry command with this item's action and tag.
    @MainActor private func command(matching item: NSMenuItem) -> BrowserCommand? {
        BrowserCommands.all.first { $0.action == item.action && $0.tag == item.tag && $0.parameters.isEmpty }
    }

    @MainActor func testEveryMainMenuItemIsARegistryCommandWithItsKeyEquivalentAndTag() throws {
        let retitledByValidation: Set<CommandID> = ["tab.toggle-pin", "page.open-in-space", "edit.undo", "edit.redo"]
        for (item, path) in try mainMenuItems() {
            guard let command = command(matching: item) else {
                XCTFail("\(path) is no registry command")
                continue
            }
            XCTAssertEqual(item.keyEquivalent, command.keyEquivalent?.key ?? "", path)
            XCTAssertEqual(item.keyEquivalentModifierMask, command.keyEquivalent?.modifiers ?? [.command], path)
            if !retitledByValidation.contains(command.id) {
                XCTAssertEqual(item.title, command.title, path)
            }
        }
    }

    @MainActor func testEveryCommandWithoutAParameterHasAMainMenuItem() throws {
        let items = try mainMenuItems().map(\.item)
        for command in BrowserCommands.all where command.parameters.isEmpty {
            // Only a run that starts Sparkle has Check for Updates… (TASK-41).
            if command.id == BrowserCommands.checkForUpdates.id { continue }
            XCTAssertTrue(items.contains { $0.action == command.action && $0.tag == command.tag }, "\(command.id)")
        }
    }

    @MainActor func testTheTitlesValidationChangesAreBuiltAsBefore() {
        XCTAssertEqual(BrowserCommands.togglePin.title, "Pin/Unpin Tab")
        XCTAssertEqual(BrowserCommands.openInSpace.title, "Open Quick Detour in Space")
        XCTAssertEqual(BrowserCommands.undo.title, "Undo")
        XCTAssertEqual(BrowserCommands.redo.title, "Redo")
    }

    // MARK: - Agreement with the responders

    /// A window-controller command is implemented by exactly the controllers
    /// of the kinds it lists, and by no app-level responder; an app delegate
    /// command by the app delegate and neither controller (or the chain would
    /// stop at the controller); AppKit's by none of Detour's.
    @MainActor func testEachCommandIsAnsweredByTheRespondersItDeclares() {
        for command in BrowserCommands.all {
            let browser = BrowserWindowController.instancesRespond(to: command.action)
            let quick = QuickDetourWindowController.instancesRespond(to: command.action)
            let app = AppDelegate.instancesRespond(to: command.action)
            switch command.responder {
            case .windowController(let kinds):
                XCTAssertEqual(browser, kinds.contains(.normal), "\(command.id)")
                XCTAssertEqual(kinds.contains(.normal), kinds.contains(.private), "\(command.id)")
                XCTAssertEqual(quick, kinds.contains(.quickDetour), "\(command.id)")
                XCTAssertEqual(kinds.contains(.quickDetour), kinds.contains(.quarantine), "\(command.id)")
                XCTAssertFalse(app, "\(command.id)")
            case .appDelegate:
                XCTAssertTrue(app, "\(command.id)")
                XCTAssertFalse(browser || quick, "\(command.id)")
            case .updater, .appKit:
                XCTAssertFalse(browser || quick || app, "\(command.id)")
            }
        }
    }

    // MARK: - Parameters and the palette

    /// TASK-320 AC #3: a command whose parameter has a list to choose from
    /// is offered in the palette, which asks for it with a chip; one with a
    /// URL or a position could not be (none is declared yet).
    @MainActor func testAParameterisedCommandIsOfferedWhenItsParameterHasAList() {
        let parameterised = BrowserCommands.all.filter { !$0.parameters.isEmpty }
        XCTAssertEqual(Set(parameterised.map(\.id)), [
            "tab.split-with", "space.switch", "tab.move-to-space", "extension.show-popup", "extension.options",
            "extension.inspect-offscreen", "extension.reload-unpacked",
        ])
        let offered: Set<CommandID> = ["tab.split-with", "space.switch", "tab.move-to-space", "extension.show-popup",
                                       "extension.options"]
        for command in parameterised {
            XCTAssertEqual(command.palette.isOffered, offered.contains(command.id), "\(command.id)")
            XCTAssertNotNil(command.choiceParameter, "\(command.id)")
        }
        XCTAssertEqual(BrowserCommands.switchToSpace.parameters, [.space])
        XCTAssertEqual(BrowserCommands.moveTabToSpace.parameters, [.space])
        XCTAssertEqual(BrowserCommands.splitWithTab.parameters, [.tab])
        XCTAssertEqual(BrowserCommands.showExtensionPopup.titleInPalette, "Show Extension Popup",
                       "its menu title says nothing outside the extension's submenu")
        XCTAssertEqual(BrowserCommands.showExtensionPopup.title, "Show Popup", "the menu's is unchanged")
        // A URL or a position has no list: such a command stays out.
        let url = BrowserCommand("test.open-url", "Open URL", action: #selector(AppDelegate.openSettings),
                                 responder: .appDelegate(explicitTarget: false), parameters: [.url])
        XCTAssertEqual(url.palette, .needsParameter)
        XCTAssertNil(url.choiceParameter)
    }

    @MainActor func testTheChipCommandsRulesFollowTheSidebarsItems() {
        let tab: (inout Context) -> Void = { $0.hasSelectedTab = true; $0.selectedTabHasURL = true }
        XCTAssertTrue(BrowserCommands.moveTabToSpace.isAvailable(in: context(.normal, tab)))
        XCTAssertFalse(BrowserCommands.moveTabToSpace.isAvailable(in: context(.private, tab)), "nothing leaves Private")
        XCTAssertFalse(BrowserCommands.moveTabToSpace.isAvailable(in: context(.normal)), "no tab")
        XCTAssertFalse(BrowserCommands.moveTabToSpace.isAvailable(in: context(.normal) {
            tab(&$0); $0.selectedTabIsInSplit = true
        }), "a split row has no Move to")
        XCTAssertTrue(BrowserCommands.moveTabToSpace.isAvailable(in: context(.normal) {
            tab(&$0); $0.selectedTabIsPinned = true
        }), "a pinned row has one")

        XCTAssertTrue(BrowserCommands.splitWithTab.isAvailable(in: context(.normal, tab)))
        XCTAssertTrue(BrowserCommands.splitWithTab.isAvailable(in: context(.private, tab)), "Private splits too")
        XCTAssertFalse(BrowserCommands.splitWithTab.isAvailable(in: context(.normal) {
            tab(&$0); $0.selectedTabIsPinned = true
        }), "a split is formed from unpinned tabs")
        XCTAssertFalse(BrowserCommands.splitWithTab.isAvailable(in: context(.normal) {
            tab(&$0); $0.selectedTabIsInSplit = true
        }), "one split per tab")
        XCTAssertFalse(BrowserCommands.splitWithTab.isAvailable(in: context(.quickDetour, tab)))

        XCTAssertTrue(BrowserCommands.switchToSpace.isAvailable(in: context(.normal)))
        XCTAssertFalse(BrowserCommands.switchToSpace.isAvailable(in: context(.private)))
    }

    @MainActor func testAppKitsItemsAndThoseThatOpenThePaletteAreNotOffered() {
        for command in BrowserCommands.all where command.responder == .appKit {
            XCTAssertFalse(command.palette.isOffered, "\(command.id)")
        }
        XCTAssertFalse(BrowserCommands.newTab.palette.isOffered)
        XCTAssertFalse(BrowserCommands.openLocation.palette.isOffered)
        XCTAssertFalse(BrowserCommands.undo.palette.isOffered)
        XCTAssertTrue(BrowserCommands.togglePin.palette.isOffered)
        XCTAssertTrue(BrowserCommands.newPrivateWindow.palette.isOffered)
    }

    // MARK: - Availability rules

    @MainActor func testAWindowControllerCommandIsUnavailableInAWindowThatDoesNotAnswerIt() {
        let quick = context(.quickDetour) { $0.hasSelectedTab = true; $0.selectedTabHasURL = true }
        XCTAssertFalse(BrowserCommands.newTab.isAvailable(in: quick))
        XCTAssertFalse(BrowserCommands.toggleSidebar.isAvailable(in: quick))
        XCTAssertFalse(BrowserCommands.showHistory.isAvailable(in: context(.quarantine)))
        XCTAssertTrue(BrowserCommands.reload.isAvailable(in: quick))
        XCTAssertTrue(BrowserCommands.closeTab.isAvailable(in: context(.quarantine)))
    }

    @MainActor func testAppDelegateCommandsAreAvailableEverywhereAndAppKitsAreNeverDecidedHere() {
        for kind in CommandWindowKind.allCases {
            XCTAssertTrue(BrowserCommands.newWindow.isAvailable(in: context(kind)), "\(kind)")
            XCTAssertTrue(BrowserCommands.settings.isAvailable(in: context(kind)), "\(kind)")
            XCTAssertFalse(BrowserCommands.copy.isAvailable(in: context(kind)), "\(kind)")
        }
    }

    @MainActor func testPinningNeedsANormalWindowAndATabWithAnAddressOrAPin() {
        let pin = BrowserCommands.togglePin
        XCTAssertFalse(pin.isAvailable(in: context(.normal)), "no tab")
        XCTAssertNil(pin.contextualTitle?(context(.normal)), "no tab: left as it was")
        XCTAssertFalse(pin.isAvailable(in: context(.normal) { $0.hasSelectedTab = true }), "no address")
        XCTAssertEqual(pin.title(in: context(.normal) { $0.hasSelectedTab = true }), "Pin Tab")
        let page = context(.normal) { $0.hasSelectedTab = true; $0.selectedTabHasURL = true }
        XCTAssertTrue(pin.isAvailable(in: page))
        XCTAssertEqual(pin.title(in: page), "Pin Tab")
        let pinned = context(.normal) { $0.hasSelectedTab = true; $0.selectedTabIsPinned = true }
        XCTAssertTrue(pin.isAvailable(in: pinned), "a pinned tab unpins with no address")
        XCTAssertEqual(pin.title(in: pinned), "Unpin Tab")
        let privatePage = context(.private) { $0.hasSelectedTab = true; $0.selectedTabHasURL = true }
        XCTAssertFalse(pin.isAvailable(in: privatePage))
        XCTAssertNil(pin.contextualTitle?(privatePage), "a Private window leaves the title")
    }

    @MainActor func testSpacesAndArchiveCommandsAreNeverAvailableInAPrivateWindow() {
        let everything: (inout Context) -> Void = {
            $0.hasNextSpace = true; $0.hasPreviousSpace = true; $0.hasArchivedTabs = true
        }
        for command in [BrowserCommands.nextSpace, BrowserCommands.previousSpace, BrowserCommands.manageSpaces,
                        BrowserCommands.switchToSpace, BrowserCommands.showArchivedTabs,
                        BrowserCommands.clearArchivedTabs] + BrowserCommands.jumpToSpace {
            XCTAssertTrue(command.isAvailable(in: context(.normal, everything)), "\(command.id)")
            XCTAssertFalse(command.isAvailable(in: context(.private, everything)), "\(command.id)")
        }
        XCTAssertFalse(BrowserCommands.nextSpace.isAvailable(in: context(.normal)), "no space after this one")
        XCTAssertFalse(BrowserCommands.clearArchivedTabs.isAvailable(in: context(.normal)), "an empty archive")
        XCTAssertTrue(BrowserCommands.showArchivedTabs.isAvailable(in: context(.normal)))
    }

    @MainActor func testPageCommandsAreAlwaysAnsweredInABrowserWindowAndNeedAnAddressInAQuickDetour() {
        for command in [BrowserCommands.copyURL, BrowserCommands.reload, BrowserCommands.find,
                        BrowserCommands.findNext, BrowserCommands.findPrevious, BrowserCommands.actualSize,
                        BrowserCommands.zoomIn, BrowserCommands.zoomOut, BrowserCommands.webInspector] {
            XCTAssertTrue(command.isAvailable(in: context(.normal)), "\(command.id)")
            XCTAssertTrue(command.isAvailable(in: context(.private)), "\(command.id)")
            XCTAssertFalse(command.isAvailable(in: context(.quickDetour)), "\(command.id)")
            XCTAssertTrue(command.isAvailable(in: context(.quarantine) { $0.selectedTabHasURL = true }), "\(command.id)")
        }
    }

    @MainActor func testBackAndForwardAlwaysInABrowserWindowAndByHistoryInAQuickDetour() {
        XCTAssertTrue(BrowserCommands.back.isAvailable(in: context(.normal)), "may close the tab to its opener")
        XCTAssertTrue(BrowserCommands.forward.isAvailable(in: context(.private)))
        XCTAssertFalse(BrowserCommands.back.isAvailable(in: context(.quickDetour)))
        XCTAssertTrue(BrowserCommands.back.isAvailable(in: context(.quickDetour) { $0.pageCanGoBack = true }))
        XCTAssertFalse(BrowserCommands.forward.isAvailable(in: context(.quarantine) { $0.pageCanGoBack = true }))
    }

    @MainActor func testUndoIsThePagesWhileItsTextIsEditedAndTheBrowsersOtherwise() {
        XCTAssertFalse(BrowserCommands.undo.isAvailable(in: context(.normal)))
        XCTAssertEqual(BrowserCommands.undo.title(in: context(.normal)), "Undo")
        let closed = context(.normal) { $0.canUndoBrowserAction = true; $0.browserUndoTitle = "Undo Close Tab" }
        XCTAssertTrue(BrowserCommands.undo.isAvailable(in: closed))
        XCTAssertEqual(BrowserCommands.undo.title(in: closed), "Undo Close Tab")
        // TASK-345: while editing, the page's stack and title, never the browser's.
        let editing = context(.normal) {
            $0.isEditingPageText = true
            $0.canUndoBrowserAction = true; $0.browserUndoTitle = "Undo Close Tab"
            $0.canRedoBrowserAction = true; $0.browserRedoTitle = "Redo Close Tab"
        }
        XCTAssertFalse(BrowserCommands.undo.isAvailable(in: editing), "nothing on the page's stack")
        XCTAssertFalse(BrowserCommands.redo.isAvailable(in: editing))
        XCTAssertEqual(BrowserCommands.undo.title(in: editing), "Undo")
        XCTAssertEqual(BrowserCommands.redo.title(in: editing), "Redo")
        let typed = context(.normal) {
            $0.isEditingPageText = true; $0.canUndoPageEdit = true; $0.pageUndoTitle = "Undo Typing"
        }
        XCTAssertTrue(BrowserCommands.undo.isAvailable(in: typed))
        XCTAssertEqual(BrowserCommands.undo.title(in: typed), "Undo Typing")
        XCTAssertFalse(BrowserCommands.redo.isAvailable(in: typed))
    }

    @MainActor func testOpenInSpaceIsThePeeksInABrowserWindowAndThePagesInAQuickDetour() {
        let command = BrowserCommands.openInSpace
        XCTAssertFalse(command.isAvailable(in: context(.normal)))
        XCTAssertEqual(command.title(in: context(.normal)), "Open Quick Detour in Space")
        let peek = context(.normal) { $0.isPeekShowing = true }
        XCTAssertTrue(command.isAvailable(in: peek))
        XCTAssertEqual(command.title(in: peek), "Open Peek in New Tab")
        let quick = context(.quickDetour) { $0.canOpenInSpace = true; $0.openInSpaceTitle = "Open in 🏠 Home" }
        XCTAssertTrue(command.isAvailable(in: quick))
        XCTAssertEqual(command.title(in: quick), "Open in 🏠 Home")
        XCTAssertFalse(command.isAvailable(in: context(.quarantine)))
    }

    @MainActor func testTabSteppingAndReopeningFollowTheirFacts() {
        XCTAssertFalse(BrowserCommands.nextTab.isAvailable(in: context(.normal)))
        XCTAssertTrue(BrowserCommands.previousTab.isAvailable(in: context(.private) { $0.hasTabToStepTo = true }))
        XCTAssertFalse(BrowserCommands.reopenClosedTab.isAvailable(in: context(.normal)))
        XCTAssertTrue(BrowserCommands.reopenClosedTab.isAvailable(in: context(.normal) { $0.hasClosedTabToReopen = true }))
    }

    /// A context that leaves a fact out has the commands that need it
    /// disabled (the protocol's defaults are false).
    @MainActor func testAContextThatLeavesFactsOutFailsClosed() {
        struct Minimal: CommandContext { var commandWindowKind: CommandWindowKind }
        let minimal = Minimal(commandWindowKind: .quickDetour)
        XCTAssertFalse(BrowserCommands.reload.isAvailable(in: minimal))
        XCTAssertFalse(BrowserCommands.openInSpace.isAvailable(in: minimal))
        XCTAssertTrue(BrowserCommands.closeTab.isAvailable(in: minimal))
    }

    // MARK: - Key equivalents as shown

    @MainActor func testKeyEquivalentsAreShownAsMenusShowThem() {
        XCTAssertEqual(BrowserCommands.reopenClosedTab.keyEquivalent?.displayString, "⇧⌘T")
        XCTAssertEqual(BrowserCommands.redo.keyEquivalent?.displayString, "⇧⌘Z", "an uppercase key implies Shift")
        XCTAssertEqual(BrowserCommands.nextSpace.keyEquivalent?.displayString, "⌥⌘→")
        XCTAssertEqual(BrowserCommands.previousTab.keyEquivalent?.displayString, "⌥⌘↑")
        XCTAssertEqual(BrowserCommands.settings.keyEquivalent?.displayString, "⌘,")
        XCTAssertEqual(BrowserCommands.zoomIn.keyEquivalent?.displayString, "⌘+")
        XCTAssertEqual(BrowserCommands.newQuickDetourWindow.keyEquivalent?.displayString, "⌥⌘N")
        XCTAssertNil(BrowserCommands.showArchivedTabs.keyEquivalent)
        XCTAssertNil(KeyEquivalent.displayString(key: "", modifiers: [.command]))
        XCTAssertEqual(KeyEquivalent.displayString(key: "k", modifiers: [.control, .option, .shift, .command]), "⌃⌥⇧⌘K")
    }

    // MARK: - Menu items built from a command

    @MainActor func testACommandsMenuItemCarriesItsIdentifierKeyAndTag() {
        let item = BrowserCommands.reopenClosedTab.makeMenuItem()
        XCTAssertEqual(item.title, "Reopen Closed Tab")
        XCTAssertEqual(item.keyEquivalent, "t")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(item.action, #selector(BrowserWindowController.reopenClosedTab(_:)))
        XCTAssertNil(item.target)
        XCTAssertEqual(item.identifier?.rawValue, "tab.reopen-closed")
        XCTAssertTrue(BrowserCommands.command(for: item)?.id == "tab.reopen-closed")

        let help = BrowserCommands.help[3].makeMenuItem()
        XCTAssertEqual(help.tag, 3)
        XCTAssertEqual(help.title, "Release Notes")
        XCTAssertEqual(help.keyEquivalent, "")
        XCTAssertEqual(help.keyEquivalentModifierMask, [.command], "NSMenuItem's default, as before")
    }

    @MainActor func testAnItemTheRegistryDidNotBuildIsValidatedByItsAction() {
        let contextMenuItem = NSMenuItem(title: "Pin", action: #selector(BrowserWindowController.togglePinTab(_:)),
                                         keyEquivalent: "")
        XCTAssertEqual(BrowserCommands.command(for: contextMenuItem)?.id, "tab.toggle-pin")
        let other = NSMenuItem(title: "Other", action: #selector(NSView.setNeedsDisplay(_:)), keyEquivalent: "")
        XCTAssertNil(BrowserCommands.command(for: other))
        XCTAssertTrue(BrowserCommands.validate(other, in: context(.private)), "not a command: enabled, as before")
        XCTAssertFalse(BrowserCommands.validate(contextMenuItem, in: context(.private)))
    }
}
