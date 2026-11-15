import AppKit
import Sparkle

/// The registry (TASK-320): every command of the main menu, in menu order,
/// with what its menu item is built from and the rule that enables it.
///
/// The rules reproduce what the window controllers' `validateMenuItem`
/// answered before the registry, quirks included: the same action can have a
/// different rule in a browser window and in a Quick Detour (Back is always
/// enabled in a browser window, whose Back may close the tab to its opener,
/// TASK-325; a Quick Detour's needs history), and a command whose action a
/// controller does not implement is not answered in its windows at all.
enum BrowserCommands {

    // MARK: - App menu

    static let about = BrowserCommand(
        "app.about", "About Detour", action: #selector(AppDelegate.showAboutPanel(_:)),
        responder: .appDelegate(explicitTarget: false), aliases: ["version"], symbol: "info.circle")
    static let checkForUpdates = BrowserCommand(
        "app.check-for-updates", "Check for Updates…",
        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), responder: .updater,
        aliases: ["update detour"], symbol: "arrow.down.circle")
    static let settings = BrowserCommand(
        "app.settings", "Settings…", key: KeyEquivalent(","), action: #selector(AppDelegate.openSettings),
        responder: .appDelegate(explicitTarget: false), aliases: ["preferences"], symbol: "gearshape")
    static let hide = BrowserCommand(
        "app.hide", "Hide Detour", key: KeyEquivalent("h"), action: #selector(NSApplication.hide(_:)),
        responder: .appKit, palette: .notOffered(appKitItem))
    static let hideOthers = BrowserCommand(
        "app.hide-others", "Hide Others", key: KeyEquivalent("h", [.command, .option]),
        action: #selector(NSApplication.hideOtherApplications(_:)), responder: .appKit,
        palette: .notOffered(appKitItem))
    static let showAll = BrowserCommand(
        "app.show-all", "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
        responder: .appKit, palette: .notOffered(appKitItem))
    static let quit = BrowserCommand(
        "app.quit", "Quit Detour", key: KeyEquivalent("q"), action: #selector(NSApplication.terminate(_:)),
        responder: .appKit, palette: .notOffered(appKitItem))

    // MARK: - File

    static let newTab = BrowserCommand(
        "tab.new", "New Tab", key: KeyEquivalent("t"), action: #selector(BrowserWindowController.newTab(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        palette: .notOffered("opens the palette in new-tab mode, which Return on typed text already is"))
    static let openLocation = BrowserCommand(
        "location.open", "Open Location…", key: KeyEquivalent("l"),
        action: #selector(BrowserWindowController.focusAddressBar(_:)),
        responder: .windowController(CommandWindowKind.every),
        palette: .notOffered("opens the palette on the page's address"))
    static let closeTab = BrowserCommand(
        "tab.close", "Close Tab", key: KeyEquivalent("w"), action: #selector(BrowserWindowController.closeCurrentTab(_:)),
        responder: .windowController(CommandWindowKind.every), symbol: "xmark")
    static let reopenClosedTab = BrowserCommand(
        "tab.reopen-closed", "Reopen Closed Tab", key: KeyEquivalent("t", [.command, .shift]),
        action: #selector(BrowserWindowController.reopenClosedTab(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        aliases: ["undo close tab", "restore tab"], symbol: "arrow.uturn.backward",
        rule: { $0.hasClosedTabToReopen })
    static let togglePin = BrowserCommand(
        "tab.toggle-pin", "Pin/Unpin Tab", key: KeyEquivalent("d"), action: #selector(BrowserWindowController.togglePinTab(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        aliases: ["pin tab", "unpin tab"], symbol: "pin",
        // Not in a Private window; a page with no address cannot be pinned.
        rule: { $0.hasSelectedTab && $0.commandWindowKind == .normal && ($0.selectedTabIsPinned || $0.selectedTabHasURL) },
        // Retitled only once there is a tab to name, outside Private windows.
        contextualTitle: { context in
            guard context.hasSelectedTab, context.commandWindowKind == .normal else { return nil }
            return context.selectedTabIsPinned ? "Unpin Tab" : "Pin Tab"
        })
    /// Split with Tab (TASK-320 AC #3): forms a split of the selected tab and
    /// the chosen one, as the sidebar's Split with Next Tab does for the next
    /// row (`tabSidebar(_:didRequestCreateSplit:withTabID:edge:)`, the chosen
    /// tab moving to the right of the selected one). No menu item: the
    /// palette asks for the tab (`CommandChoices.splitWithTab`). A split is
    /// formed from unpinned tabs in no split, in a Private window too.
    static let splitWithTab = BrowserCommand(
        "tab.split-with", "Split with Tab", action: #selector(BrowserWindowController.splitSelectedTabWith(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        aliases: ["split view", "side by side"], symbol: "rectangle.split.2x1", parameters: [.tab],
        rule: { $0.hasSelectedTab && !$0.selectedTabIsPinned && !$0.selectedTabIsInSplit })
    static let newWindow = BrowserCommand(
        "window.new", "New Window", key: KeyEquivalent("n"),
        action: #selector(AppDelegate.createNewWindow as (AppDelegate) -> () -> Void),
        responder: .appDelegate(explicitTarget: false), symbol: "macwindow.badge.plus")
    static let newPrivateWindow = BrowserCommand(
        "window.new-private", "New Private Window", key: KeyEquivalent("n", [.command, .shift]),
        action: #selector(AppDelegate.createNewIncognitoWindow), responder: .appDelegate(explicitTarget: false),
        aliases: ["incognito window", "private browsing"], symbol: "eye.slash")
    /// Its key equivalent follows the Quick Detour hotkey's setting
    /// (`QuickDetourHotKey`, TASK-193.2); this is the default.
    static let newQuickDetourWindow = BrowserCommand(
        "quick-detour.new", "New \(QuickDetour.displayName) Window", key: KeyEquivalent("n", [.command, .option]),
        action: #selector(AppDelegate.newQuickDetourWindow(_:)), responder: .appDelegate(explicitTarget: false),
        aliases: ["little arc", "mini window"], symbol: "bolt")
    /// Cmd+O, one item for two windows (TASK-193.3, TASK-307): a Quick
    /// Detour or quarantine opens its page in a space; a browser window with
    /// a Peek up opens the Peek in a new tab.
    static let openInSpace = BrowserCommand(
        "page.open-in-space", QuickDetourWindowController.openInMenuItemTitle, key: KeyEquivalent("o"),
        action: #selector(QuickDetourWindowController.openInDefaultSpace(_:)),
        responder: .windowController(CommandWindowKind.every),
        aliases: ["open peek in new tab", "move to space"], symbol: "arrow.up.forward.app",
        rule: { $0.commandWindowKind.isBrowserWindow ? $0.isPeekShowing : $0.canOpenInSpace },
        contextualTitle: { context in
            guard context.commandWindowKind.isBrowserWindow else { return context.openInSpaceTitle }
            return context.isPeekShowing ? BrowserWindowController.openPeekInNewTabMenuItemTitle
                : QuickDetourWindowController.openInMenuItemTitle
        })
    static let importFromArc = BrowserCommand(
        "app.import-from-arc", "Import from Arc…", action: #selector(AppDelegate.importFromArc(_:)),
        responder: .appDelegate(explicitTarget: false), symbol: "square.and.arrow.down")

    // MARK: - Edit

    /// The browser's undo (`TabStore.undoManager`), or the focused page's
    /// own undo while an editable element in it has focus, never both
    /// (TASK-345). A page gets Cmd+Z first; this runs when it leaves it.
    static let undo = BrowserCommand(
        "edit.undo", "Undo", key: KeyEquivalent("z"), action: #selector(BrowserWindowController.browserUndo(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        palette: .notOffered("acts on whatever had focus; Reopen Closed Tab is the palette's undo for tabs"),
        rule: { $0.isEditingPageText ? $0.canUndoPageEdit : $0.canUndoBrowserAction },
        contextualTitle: { $0.isEditingPageText ? $0.pageUndoTitle : $0.browserUndoTitle })
    static let redo = BrowserCommand(
        "edit.redo", "Redo", key: KeyEquivalent("Z"), action: #selector(BrowserWindowController.browserRedo(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        palette: .notOffered("acts on whatever had focus"),
        rule: { $0.isEditingPageText ? $0.canRedoPageEdit : $0.canRedoBrowserAction },
        contextualTitle: { $0.isEditingPageText ? $0.pageRedoTitle : $0.browserRedoTitle })
    static let cut = BrowserCommand(
        "edit.cut", "Cut", key: KeyEquivalent("x"), action: #selector(NSText.cut(_:)), responder: .appKit,
        palette: .notOffered(textItem))
    static let copy = BrowserCommand(
        "edit.copy", "Copy", key: KeyEquivalent("c"), action: #selector(NSText.copy(_:)), responder: .appKit,
        palette: .notOffered(textItem))
    static let copyURL = BrowserCommand(
        "tab.copy-url", "Copy URL", key: KeyEquivalent("c", [.command, .shift]),
        action: #selector(BrowserWindowController.copyCurrentURL(_:)),
        responder: .windowController(CommandWindowKind.every),
        aliases: ["copy link", "copy address"], symbol: "link", rule: pageRule)
    static let paste = BrowserCommand(
        "edit.paste", "Paste", key: KeyEquivalent("v"), action: #selector(NSText.paste(_:)), responder: .appKit,
        palette: .notOffered(textItem))
    static let selectAll = BrowserCommand(
        "edit.select-all", "Select All", key: KeyEquivalent("a"), action: #selector(NSText.selectAll(_:)),
        responder: .appKit, palette: .notOffered(textItem))
    static let find = BrowserCommand(
        "find.show", "Find...", key: KeyEquivalent("f"), action: #selector(BrowserWindowController.showFindBar(_:)),
        responder: .windowController(CommandWindowKind.every),
        aliases: ["find in page", "search page"], symbol: "magnifyingglass", rule: pageRule)
    static let findNext = BrowserCommand(
        "find.next", "Find Next", key: KeyEquivalent("g"), action: #selector(BrowserWindowController.findNext(_:)),
        responder: .windowController(CommandWindowKind.every), symbol: "chevron.down", rule: pageRule)
    static let findPrevious = BrowserCommand(
        "find.previous", "Find Previous", key: KeyEquivalent("g", [.command, .shift]),
        action: #selector(BrowserWindowController.findPrevious(_:)),
        responder: .windowController(CommandWindowKind.every), symbol: "chevron.up", rule: pageRule)

    // MARK: - View

    static let toggleSidebar = BrowserCommand(
        "sidebar.toggle", "Toggle Sidebar", key: KeyEquivalent("s"),
        action: #selector(BrowserWindowController.toggleSidebarMode(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        aliases: ["hide sidebar", "show sidebar"], symbol: "sidebar.left")
    static let reload = BrowserCommand(
        "page.reload", "Reload Page", key: KeyEquivalent("r"), action: #selector(BrowserWindowController.reloadPage(_:)),
        responder: .windowController(CommandWindowKind.every),
        aliases: ["refresh"], symbol: "arrow.clockwise", rule: pageRule)
    static let actualSize = BrowserCommand(
        "page.zoom-reset", "Actual Size", key: KeyEquivalent("0"),
        action: #selector(BrowserWindowController.zoomActualSize(_:)),
        responder: .windowController(CommandWindowKind.every),
        aliases: ["reset zoom"], symbol: "1.magnifyingglass", rule: pageRule)
    static let zoomIn = BrowserCommand(
        "page.zoom-in", "Zoom In", key: KeyEquivalent("+"), action: #selector(BrowserWindowController.zoomIn(_:)),
        responder: .windowController(CommandWindowKind.every), symbol: "plus.magnifyingglass", rule: pageRule)
    static let zoomOut = BrowserCommand(
        "page.zoom-out", "Zoom Out", key: KeyEquivalent("-"), action: #selector(BrowserWindowController.zoomOut(_:)),
        responder: .windowController(CommandWindowKind.every), symbol: "minus.magnifyingglass", rule: pageRule)

    // MARK: - Navigate

    /// Always enabled in a browser window, whose Back can also close a tab to
    /// the tab it was opened from (TASK-325); a Quick Detour's needs history.
    /// With the page focused the item resolves to the page's `WKWebView`,
    /// whose own `goBack:` is ahead of the controller in the responder chain;
    /// `BrowserWebView` hands it, and its validation, to the controller
    /// (TASK-331), so Cmd+[ there does what the palette's Back does.
    static let back = BrowserCommand(
        "page.back", "Back", key: KeyEquivalent("["), action: #selector(BrowserWindowController.goBack(_:)),
        responder: .windowController(CommandWindowKind.every),
        aliases: ["go back"], symbol: "chevron.backward",
        rule: { $0.commandWindowKind.isBrowserWindow || $0.pageCanGoBack })
    static let forward = BrowserCommand(
        "page.forward", "Forward", key: KeyEquivalent("]"), action: #selector(BrowserWindowController.goForward(_:)),
        responder: .windowController(CommandWindowKind.every),
        aliases: ["go forward"], symbol: "chevron.forward",
        rule: { $0.commandWindowKind.isBrowserWindow || $0.pageCanGoForward })
    static let previousTab = BrowserCommand(
        "tab.previous", "Previous Tab", key: KeyEquivalent("\u{F700}", [.command, .option]),
        action: #selector(BrowserWindowController.selectPreviousTab(_:)),
        responder: .windowController(CommandWindowKind.browserWindows), symbol: "arrow.up",
        rule: { $0.hasTabToStepTo })
    static let nextTab = BrowserCommand(
        "tab.next", "Next Tab", key: KeyEquivalent("\u{F701}", [.command, .option]),
        action: #selector(BrowserWindowController.selectNextTab(_:)),
        responder: .windowController(CommandWindowKind.browserWindows), symbol: "arrow.down",
        rule: { $0.hasTabToStepTo })
    static let showHistory = BrowserCommand(
        "history.show", "Show All History", key: KeyEquivalent("y"), action: #selector(BrowserWindowController.showHistory(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        aliases: ["history"], symbol: "clock.arrow.circlepath")
    static let showArchivedTabs = BrowserCommand(
        "archive.show", "Show Archived Tabs", action: #selector(BrowserWindowController.showArchivedTabs(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        aliases: ["archive", "closed tabs"], symbol: "archivebox",
        rule: { $0.commandWindowKind == .normal })
    static let clearArchivedTabs = BrowserCommand(
        "archive.clear", "Clear Archived Tabs…", action: #selector(BrowserWindowController.clearArchivedTabs(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        aliases: ["empty archive"], symbol: "trash",
        rule: { $0.commandWindowKind == .normal && $0.hasArchivedTabs })

    // MARK: - Spaces

    static let nextSpace = BrowserCommand(
        "space.next", "Next Space", key: KeyEquivalent("\u{F703}", [.command, .option]),
        action: #selector(BrowserWindowController.nextSpace(_:)),
        responder: .windowController(CommandWindowKind.browserWindows), symbol: "arrow.right",
        rule: { $0.commandWindowKind == .normal && $0.hasNextSpace })
    static let previousSpace = BrowserCommand(
        "space.previous", "Previous Space", key: KeyEquivalent("\u{F702}", [.command, .option]),
        action: #selector(BrowserWindowController.previousSpace(_:)),
        responder: .windowController(CommandWindowKind.browserWindows), symbol: "arrow.left",
        rule: { $0.commandWindowKind == .normal && $0.hasPreviousSpace })
    /// Spaces › the first nine spaces (TASK-295): one static item per
    /// position, which `AppDelegate.updateSpacesMenu` titles with the space
    /// at that position (Settings › Spaces order) and hides when there is
    /// none. The space is resolved when the command runs
    /// (`SpaceJump.target(ofPosition:in:)`), so adding, deleting or
    /// reordering spaces needs no menu rebuild.
    ///
    /// Each position has its own action: a hit on the TASK-56 key-equivalent
    /// fast path is sent with the menu, not the item, as sender (measured), so
    /// the position cannot travel on the item. The rule is only the window
    /// kind, not "a space exists at N": an enabled command with nothing to do
    /// swallows the key, a disabled one lets it fall through to the page.
    ///
    /// Default keys ⌃1–⌃9, as Arc's. PROVISIONAL (chosen by Claude while the
    /// user was away): macOS's Mission Control "Switch to Desktop N" takes
    /// ⌃N first when it is turned on; Settings › Shortcuts says so on the row.
    static let jumpToSpace: [BrowserCommand] = {
        // IDs are API: written out, never derived.
        let positions: [(CommandID, Selector)] = [
            ("space.jump-1", #selector(BrowserWindowController.jumpToSpace1(_:))),
            ("space.jump-2", #selector(BrowserWindowController.jumpToSpace2(_:))),
            ("space.jump-3", #selector(BrowserWindowController.jumpToSpace3(_:))),
            ("space.jump-4", #selector(BrowserWindowController.jumpToSpace4(_:))),
            ("space.jump-5", #selector(BrowserWindowController.jumpToSpace5(_:))),
            ("space.jump-6", #selector(BrowserWindowController.jumpToSpace6(_:))),
            ("space.jump-7", #selector(BrowserWindowController.jumpToSpace7(_:))),
            ("space.jump-8", #selector(BrowserWindowController.jumpToSpace8(_:))),
            ("space.jump-9", #selector(BrowserWindowController.jumpToSpace9(_:))),
        ]
        return positions.enumerated().map { index, entry in
            let position = index + 1
            return BrowserCommand(
                entry.0, "Switch to Space \(position)", key: KeyEquivalent("\(position)", [.control]),
                action: entry.1, responder: .windowController(CommandWindowKind.browserWindows),
                aliases: ["jump to space", "go to space"], symbol: "\(position).square",
                palette: .notOffered("names a position, not a space; the Spaces menu shows which space it is"),
                rule: { $0.commandWindowKind == .normal })
        }
    }()
    /// One Spaces-menu item per space after the ninth, titled with its emoji
    /// and name (the first nine are `jumpToSpace`'s items). In the palette
    /// it asks for the space (TASK-320 AC #3): what the Spaces menu offers,
    /// but the window's own (`CommandChoices.switchToSpace`).
    static let switchToSpace = BrowserCommand(
        "space.switch", "Switch to Space", action: #selector(BrowserWindowController.selectSpaceFromMenu(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        aliases: ["go to space", "change space"], symbol: "square.stack.3d.up", parameters: [.space],
        rule: { $0.commandWindowKind == .normal })
    /// Move Tab to Space (TASK-320 AC #3): moves the selected tab or pinned
    /// entry as the sidebar's Move to submenu does
    /// (`tabSidebar(_:didRequestMoveTabAt:isPinned:toSpaceID:)`, TASK-38).
    /// No menu item: the palette asks for the space
    /// (`CommandChoices.moveTabToSpace`). Never from a Private window, and
    /// not for a split (the sidebar offers Move to on neither).
    static let moveTabToSpace = BrowserCommand(
        "tab.move-to-space", "Move Tab to Space", action: #selector(BrowserWindowController.moveSelectedTabToSpace(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        aliases: ["send tab to space"], symbol: "arrow.right.square", parameters: [.space],
        rule: { $0.commandWindowKind == .normal && $0.hasSelectedTab && !$0.selectedTabIsInSplit })
    static let manageSpaces = BrowserCommand(
        "space.manage", "Manage Spaces…", action: #selector(BrowserWindowController.openSpacesSettings(_:)),
        responder: .windowController(CommandWindowKind.browserWindows),
        aliases: ["spaces settings", "edit spaces"], symbol: "square.stack",
        rule: { $0.commandWindowKind == .normal })

    // MARK: - Extensions

    /// "Show Popup" in an extension's submenu; disabled (no action) when it
    /// has no popup. The palette lists the extensions whose item is live in
    /// the window's profile (`ExtensionMenuItems`); a Quick Detour has none.
    static let showExtensionPopup = BrowserCommand(
        "extension.show-popup", "Show Popup", action: #selector(AppDelegate.extensionMenuClicked(_:)),
        responder: .appDelegate(explicitTarget: true), aliases: ["extension popup", "open extension"],
        symbol: "puzzlepiece.extension", parameters: [.extension], paletteTitle: "Show Extension Popup")
    /// "Options…" in an extension's submenu, in the key window's profile (TASK-103).
    static let extensionOptions = BrowserCommand(
        "extension.options", "Options…", action: #selector(AppDelegate.extensionOptionsMenuClicked(_:)),
        responder: .appDelegate(explicitTarget: true), aliases: ["extension settings", "extension preferences"],
        symbol: "puzzlepiece.extension", parameters: [.extension], paletteTitle: "Extension Options")
    static let addExtensions = BrowserCommand(
        "extensions.add", "Add Extensions…", action: #selector(AppDelegate.openChromeWebStore),
        responder: .appDelegate(explicitTarget: false),
        aliases: ["chrome web store", "install extension"], symbol: "puzzlepiece.extension")
    static let manageExtensions = BrowserCommand(
        "extensions.manage", "Manage Extensions…", action: #selector(AppDelegate.showExtensionsSettings),
        responder: .appDelegate(explicitTarget: false), aliases: ["extensions settings"], symbol: "puzzlepiece")
    static let checkForExtensionUpdates = BrowserCommand(
        "extensions.check-for-updates", "Check for Extension Updates",
        action: #selector(AppDelegate.checkForExtensionUpdates), responder: .appDelegate(explicitTarget: false),
        aliases: ["update extensions"], symbol: "arrow.triangle.2.circlepath")

    // MARK: - Develop

    static let webInspector = BrowserCommand(
        "develop.web-inspector", "Web Inspector", key: KeyEquivalent("i", [.command, .option]),
        action: #selector(BrowserWindowController.showWebInspector(_:)),
        responder: .windowController(CommandWindowKind.every),
        aliases: ["developer tools", "devtools", "inspect element", "console"], symbol: "hammer", rule: pageRule)
    static let loadUnpackedExtension = BrowserCommand(
        "develop.load-unpacked-extension", "Load Unpacked Extension…",
        action: #selector(AppDelegate.loadUnpackedExtension), responder: .appDelegate(explicitTarget: false),
        symbol: "folder.badge.plus")
    /// Develop > Inspect "<name>" Offscreen, per enabled extension.
    static let inspectExtensionOffscreen = BrowserCommand(
        "extension.inspect-offscreen", "Inspect Offscreen Document",
        action: #selector(AppDelegate.inspectExtensionOffscreen(_:)),
        responder: .appDelegate(explicitTarget: true), parameters: [.extension],
        palette: .notOffered(developExtensionItem))
    /// Develop > Reload "<name>", per unpacked extension (TASK-113).
    static let reloadUnpackedExtension = BrowserCommand(
        "extension.reload-unpacked", "Reload Unpacked Extension",
        action: #selector(AppDelegate.reloadUnpackedExtension(_:)),
        responder: .appDelegate(explicitTarget: true), parameters: [.extension],
        palette: .notOffered(developExtensionItem))

    // MARK: - Window

    static let minimize = BrowserCommand(
        "window.minimize", "Minimize", key: KeyEquivalent("m"), action: #selector(NSWindow.performMiniaturize(_:)),
        responder: .appKit, palette: .notOffered(appKitItem))
    static let zoomWindow = BrowserCommand(
        "window.zoom", "Zoom", action: #selector(NSWindow.performZoom(_:)), responder: .appKit,
        palette: .notOffered(appKitItem))

    // MARK: - Help

    /// Help's items (TASK-292.10), one per `HelpLinks` page; the item's tag
    /// is the page's index.
    static let help: [BrowserCommand] = HelpLinks.allCases.enumerated().map { index, link in
        BrowserCommand(link.commandID, link.title, action: #selector(AppDelegate.openHelpLink(_:)),
                       responder: .appDelegate(explicitTarget: true), aliases: link.aliases,
                       symbol: "questionmark.circle", tag: index)
    }

    // MARK: - The list

    /// The menus of the menu bar, each with its commands in menu order: how
    /// Settings > Shortcuts groups them (TASK-327). The layout itself
    /// (separators, conditional items) stays in `AppDelegate.setupMainMenu`;
    /// `BrowserCommandRegistryTests` holds the two together.
    static let menus: [CommandMenu] = [
        CommandMenu(title: "Detour", commands: [about, checkForUpdates, settings, hide, hideOthers, showAll, quit]),
        CommandMenu(title: "File", commands: [newTab, openLocation, closeTab, reopenClosedTab, togglePin,
                                              splitWithTab, newWindow, newPrivateWindow, newQuickDetourWindow, openInSpace,
                                              importFromArc]),
        CommandMenu(title: "Edit", commands: [undo, redo, cut, copy, copyURL, paste, selectAll, find, findNext,
                                              findPrevious]),
        CommandMenu(title: "View", commands: [toggleSidebar, reload, actualSize, zoomIn, zoomOut]),
        CommandMenu(title: "Navigate", commands: [back, forward, previousTab, nextTab, showHistory, showArchivedTabs,
                                                  clearArchivedTabs]),
        CommandMenu(title: "Spaces", commands: [nextSpace, previousSpace] + jumpToSpace + [switchToSpace, moveTabToSpace,
                                                                                manageSpaces]),
        CommandMenu(title: "Extensions", commands: [showExtensionPopup, extensionOptions, addExtensions,
                                                    manageExtensions, checkForExtensionUpdates]),
        CommandMenu(title: "Develop", commands: [webInspector, loadUnpackedExtension, inspectExtensionOffscreen,
                                                 reloadUnpackedExtension]),
        CommandMenu(title: "Window", commands: [minimize, zoomWindow]),
        CommandMenu(title: "Help", commands: help),
    ]

    /// Every command, in menu order.
    static let all: [BrowserCommand] = menus.flatMap(\.commands)

    private static let byID: [CommandID: BrowserCommand] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The first command with each action: what an item that is not the
    /// registry's own (a context menu's item with the same action, a
    /// dynamic item) is validated as.
    private static let byAction: [Selector: BrowserCommand] = Dictionary(all.map { ($0.action, $0) },
                                                                          uniquingKeysWith: { first, _ in first })

    static func command(withID id: CommandID) -> BrowserCommand? { byID[id] }

    /// The command `item` is a view of: by its identifier when the registry
    /// built it, else by its action.
    static func command(for item: NSMenuItem) -> BrowserCommand? {
        if let identifier = item.identifier, let command = byID[CommandID(rawValue: identifier.rawValue)] {
            return command
        }
        return item.action.flatMap { byAction[$0] }
    }

    /// What a window controller's `validateMenuItem` answers for `item`: the
    /// command's rule in `context`, after retitling the item as the context
    /// says. An item that is no registry command is enabled, which was every
    /// controller's default before the registry.
    static func validate(_ item: NSMenuItem, in context: any CommandContext) -> Bool {
        guard let command = command(for: item) else { return true }
        if let title = command.contextualTitle?(context) { item.title = title }
        return command.isAvailable(in: context)
    }

    // MARK: - Shared rules and reasons

    /// The page items (Copy URL, Reload, zoom, Find, Web Inspector): always
    /// answered in a browser window; a Quick Detour needs its page to have an
    /// address.
    private static let pageRule: (any CommandContext) -> Bool = {
        $0.commandWindowKind.isBrowserWindow || $0.selectedTabHasURL
    }

    private static let appKitItem = "AppKit's own application and window item"
    private static let textItem = "edits the text of whatever field has focus"
    private static let developExtensionItem =
        "the Develop menu lists every profile's extensions; the palette lists only its window profile's"
}

extension HelpLinks {
    /// The Help item's command ID. Written out per page: IDs are API.
    var commandID: CommandID {
        switch self {
        case .detourHelp: return "help.guide"
        case .keyboardShortcuts: return "help.keyboard-shortcuts"
        case .switchingFromArc: return "help.switching-from-arc"
        case .releaseNotes: return "help.release-notes"
        case .reportAnIssue: return "help.report-issue"
        }
    }

    var aliases: [String] {
        switch self {
        case .detourHelp: return ["help", "user guide"]
        case .keyboardShortcuts: return ["shortcuts", "hotkeys"]
        case .switchingFromArc: return ["arc"]
        case .releaseNotes: return ["changelog", "what's new"]
        case .reportAnIssue: return ["bug report", "feedback"]
        }
    }
}
