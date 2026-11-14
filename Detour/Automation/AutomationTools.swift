import AppKit

/// What a page-content tool acts on (TASK-228.1, AC #11): a tab, or one of an
/// extension's contexts (TASK-228.2), named by kind and extension so a
/// scenario written earlier still resolves (AC #10): `popup:<ext>`,
/// `options:<ext>`, `worker:<ext>`, `sidepanel:<ext>`, and `extension:<ext>`
/// (every context of the extension, for the console). `<ext>` is an
/// extension id or its exact manifest name (case-insensitive); a profile is
/// picked with a trailing `@<profile uuid>` when the extension is on in more
/// than one.
nonisolated enum AutomationContextID: Equatable, Sendable {
    case tab(UUID)
    case `extension`(AutomationExtensionContextKind, AutomationExtensionRef)

    var stringValue: String {
        switch self {
        case .tab(let id): "tab:\(id.uuidString)"
        case .extension(let kind, let ref): "\(kind.rawValue):\(ref.stringValue)"
        }
    }

    /// Parses `tab:<uuid>` and the extension forms. A bare UUID is read as a
    /// tab, which is what every list result calls `tab_id`.
    static func parse(_ value: String) throws -> AutomationContextID {
        if let uuid = UUID(uuidString: value) { return .tab(uuid) }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw AutomationToolError(.invalidArguments,
                                      "A context is tab:<uuid> or popup|options|worker|sidepanel|extension:<extension>, got \"\(value)\"")
        }
        switch parts[0] {
        case "tab":
            guard let uuid = UUID(uuidString: parts[1]) else {
                throw AutomationToolError(.invalidArguments, "tab:<uuid> needs a UUID, got \"\(parts[1])\"")
            }
            return .tab(uuid)
        case let name:
            guard let kind = AutomationExtensionContextKind(rawValue: name) else {
                throw AutomationToolError(.invalidArguments, "Unknown context kind \(name)")
            }
            return .extension(kind, try AutomationExtensionRef.parse(parts[1]))
        }
    }
}

/// The kinds of extension context a `context` names (TASK-228.2).
nonisolated enum AutomationExtensionContextKind: String, Sendable, CaseIterable {
    /// The action popup, while it is open.
    case popup
    /// The options page, while a tab shows it.
    case options
    /// The background service worker (or background page).
    case worker
    /// The side panel: not on this build (only the epic branch has one).
    case sidepanel
    /// Every context of the extension: the console reads all of them.
    case `extension`
}

/// An extension as a client names it: its id or its manifest name, and
/// optionally the profile whose context is meant.
nonisolated struct AutomationExtensionRef: Equatable, Sendable {
    var query: String
    var profileID: UUID?

    var stringValue: String {
        query + (profileID.map { "@\($0.uuidString)" } ?? "")
    }

    /// `<ext>` or `<ext>@<profile uuid>`. Only a UUID after the last `@` is a
    /// profile, so a manifest name with an `@` in it still reads as a name.
    static func parse(_ value: String) throws -> AutomationExtensionRef {
        var query = value
        var profileID: UUID?
        if let at = value.lastIndex(of: "@"), let uuid = UUID(uuidString: String(value[value.index(after: at)...])) {
            query = String(value[..<at])
            profileID = uuid
        }
        query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            throw AutomationToolError(.invalidArguments, "An extension context needs an extension id or name, got \"\(value)\"")
        }
        return AutomationExtensionRef(query: query, profileID: profileID)
    }
}

/// Small, stable window numbers for clients (`window_id`), handed out in the
/// order windows are first seen. Not `NSWindow.windowNumber`, which is only
/// assigned once a window is on screen; that number is reported separately
/// as `window_number` (it is the CGWindowID screencapture takes).
final class AutomationWindowIDs {
    private let ids = NSMapTable<BrowserWindowController, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var next = 1

    func id(for controller: BrowserWindowController) -> Int {
        if let existing = ids.object(forKey: controller) { return existing.intValue }
        let id = next
        next += 1
        ids.setObject(NSNumber(value: id), forKey: controller)
        return id
    }
}

/// The app the tools act on. Injected, so tests hand in their own windows and
/// menu instead of the app delegate's.
struct AutomationEnvironment {
    var windowControllers: () -> [BrowserWindowController]
    var mainMenu: () -> NSMenu?
    var store: TabStore
    /// Whether the endpoint runs in the isolated test-run mode
    /// (`AutomationGate.Mode.testRun`). The tools that install extensions or
    /// grant them permissions without the user's prompt answer `gate_closed`
    /// otherwise (TASK-228.2, AC #7).
    var isTestRun = false

    static var live: AutomationEnvironment {
        AutomationEnvironment(
            windowControllers: { (NSApp.delegate as? AppDelegate)?.windowControllers ?? [] },
            mainMenu: { NSApp.mainMenu },
            store: .shared)
    }
}

/// The tools of TASK-228.1's first phase: state, selection, navigation and
/// menu commands. Private windows and spaces are never listed and are refused
/// by ID (`private_unreachable`).
final class AutomationTools {

    let environment: AutomationEnvironment
    let windowIDs = AutomationWindowIDs()
    /// How long `run_menu_item` waits for an action to return before saying it
    /// is still running (an action that opens a modal alert does not return
    /// until the alert closes).
    var menuActionWait: Duration = .milliseconds(1500)
    /// How long an input tool waits for one mouse or key event to be handled
    /// before saying it is still running (it opened a menu or an alert).
    var inputWait: Duration = .milliseconds(1500)

    init(environment: AutomationEnvironment) {
        self.environment = environment
        AutomationMenuTracker.shared.start()
    }

    var all: [MCPTool] {
        [listWindows, listSpaces, listTabs, selectTab, openURL, runMenuItem] + inputTools + captureTools + pageTools
            + extensionTools + compatReportTools
    }

    // MARK: Lookup

    private var store: TabStore { environment.store }

    private var openWindows: [BrowserWindowController] {
        environment.windowControllers().filter { !$0.hasClosed }
    }

    func window(id: Int) throws -> BrowserWindowController {
        guard let controller = openWindows.first(where: { windowIDs.id(for: $0) == id }) else {
            throw AutomationToolError(.unknownWindow, "No open window \(id)")
        }
        guard !controller.isIncognito else {
            throw AutomationToolError(.privateUnreachable, "Window \(id) is a Private window")
        }
        return controller
    }

    func space(id: UUID) throws -> Space {
        guard let space = store.space(withID: id) else {
            throw AutomationToolError(.unknownSpace, "No space \(id.uuidString)")
        }
        guard !space.isIncognito else {
            throw AutomationToolError(.privateUnreachable, "Space \(id.uuidString) is Private")
        }
        return space
    }

    private func windowsSelecting(_ tabID: UUID?) -> [JSONValue] {
        guard let tabID else { return [] }
        return openWindows.filter { !$0.isIncognito && $0.selectedTabID == tabID }
            .map { .int(windowIDs.id(for: $0)) }
    }

    // MARK: list_windows

    private var listWindows: MCPTool {
        MCPTool(
            name: "list_windows",
            title: "List windows",
            description: "Lists Detour's browser windows (Private windows are left out): each one's window_id, frame, "
                + "key/main state, active space and selected tab. window_id is what the other tools take.",
            inputSchema: MCPSchema.input([]),
            outputSchema: MCPSchema.output([
                "app_active": MCPSchema.booleanType,
                "windows": MCPSchema.arrayOfObjects("One entry per window"),
                "hidden_private_windows": MCPSchema.integerType,
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] _ in
                let windows = openWindows
                let visible = windows.filter { !$0.isIncognito }
                return [
                    "app_active": .bool(NSApp.isActive),
                    "windows": .array(visible.map(describe)),
                    "hidden_private_windows": .int(windows.count - visible.count),
                ]
            })
    }

    private func describe(_ controller: BrowserWindowController) -> JSONValue {
        let window = controller.window
        let frame = window?.frame ?? .zero
        return [
            "window_id": .int(windowIDs.id(for: controller)),
            "window_number": .int(window?.windowNumber ?? 0),
            "frame": ["x": .double(frame.origin.x), "y": .double(frame.origin.y),
                      "width": .double(frame.width), "height": .double(frame.height)],
            "is_key": .bool(window?.isKeyWindow ?? false),
            "is_main": .bool(window?.isMainWindow ?? false),
            "is_visible": .bool(window?.isVisible ?? false),
            "is_miniaturized": .bool(window?.isMiniaturized ?? false),
            "active_space_id": .nullable(controller.activeSpaceID?.uuidString),
            "selected_tab_id": .nullable(controller.selectedTabID?.uuidString),
            "selected_tab_url": .nullable(controller.selectedTab?.url?.absoluteString),
            "selected_tab_title": .nullable(controller.selectedTab?.title),
        ]
    }

    // MARK: list_spaces

    private var listSpaces: MCPTool {
        MCPTool(
            name: "list_spaces",
            title: "List spaces",
            description: "Lists the spaces (Private ones are left out) with their profile, tab counts and the "
                + "windows showing each one.",
            inputSchema: MCPSchema.input([]),
            outputSchema: MCPSchema.output(["spaces": MCPSchema.arrayOfObjects("One entry per space")]),
            annotations: ["readOnlyHint": true],
            handler: { [self] _ in
                let windows = openWindows.filter { !$0.isIncognito }
                let spaces: [JSONValue] = store.spaces.filter { !$0.isIncognito }.map { space in
                    [
                        "space_id": .string(space.id.uuidString),
                        "name": .string(space.name),
                        "emoji": .string(space.emoji),
                        "color": .string(space.colorHex),
                        "profile_id": .string(space.profileID.uuidString),
                        "profile_name": .nullable(space.profile?.name),
                        "pinned_count": .int(space.pinnedEntries.count),
                        "tab_count": .int(space.tabs.count),
                        "shown_in_window_ids": .array(windows.filter { $0.activeSpaceID == space.id }
                            .map { .int(windowIDs.id(for: $0)) }),
                    ]
                }
                return ["spaces": .array(spaces)]
            })
    }

    // MARK: list_tabs

    private var listTabs: MCPTool {
        MCPTool(
            name: "list_tabs",
            title: "List tabs",
            description: "Lists a space's sidebar items in order: the profile's favorites, the pinned entries "
                + "(live or dormant) and the normal tabs. Give space_id, or window_id for the window's active space. "
                + "Each item's id is what select_tab takes; tab_id is null for a dormant favorite or pinned entry.",
            inputSchema: MCPSchema.input([
                ("window_id", .integer("A window from list_windows: lists its active space")),
                ("space_id", .string("A space from list_spaces")),
            ]),
            outputSchema: MCPSchema.output([
                "space_id": MCPSchema.stringType,
                "items": MCPSchema.arrayOfObjects("Favorites, then pinned entries, then normal tabs"),
                "folders": MCPSchema.arrayOfObjects("The space's pinned folders"),
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] arguments in
                let space: Space
                if let spaceID = try arguments.uuid("space_id") {
                    space = try self.space(id: spaceID)
                } else if let windowID = try arguments.int("window_id") {
                    let controller = try window(id: windowID)
                    guard let active = controller.activeSpace else {
                        throw AutomationToolError(.unknownSpace, "Window \(windowID) shows no space")
                    }
                    space = active
                } else {
                    throw AutomationToolError(.invalidArguments, "Give window_id or space_id")
                }
                return listing(of: space)
            })
    }

    func listing(of space: Space) -> JSONValue {
        var items: [JSONValue] = []
        for favorite in space.profile?.favorites ?? [] {
            items.append(item(section: "favorite", id: favorite.id, tab: favorite.tab,
                              url: favorite.tab?.url ?? favorite.url,
                              title: favorite.tab?.title ?? favorite.title, extra: [:]))
        }
        for entry in space.pinnedEntries {
            items.append(item(section: "pinned", id: entry.id, tab: entry.tab,
                              url: entry.tab?.url ?? entry.pinnedURL, title: entry.displayTitle,
                              extra: ["folder_id": .nullable(entry.folderID?.uuidString),
                                      "split_group_id": .nullable(entry.splitGroupID?.uuidString)]))
        }
        for tab in space.tabs {
            items.append(item(section: "tab", id: tab.id, tab: tab, url: tab.url, title: tab.title,
                              extra: ["split_group_id": .nullable(tab.splitGroupID?.uuidString)]))
        }
        let folders: [JSONValue] = space.pinnedFolders.map { folder in
            [
                "folder_id": .string(folder.id.uuidString),
                "name": .string(folder.name),
                "parent_folder_id": .nullable(folder.parentFolderID?.uuidString),
                "collapsed": .bool(folder.isCollapsed),
            ]
        }
        return ["space_id": .string(space.id.uuidString), "items": .array(items), "folders": .array(folders)]
    }

    private func item(section: String, id: UUID, tab: BrowserTab?, url: URL?, title: String,
                      extra: [String: JSONValue]) -> JSONValue {
        var fields: [String: JSONValue] = [
            "section": .string(section),
            "id": .string(id.uuidString),
            "tab_id": .nullable(tab?.id.uuidString),
            "context": .nullable(tab.map { AutomationContextID.tab($0.id).stringValue }),
            "live": .bool(tab != nil),
            "url": .nullable(url?.absoluteString),
            "title": .string(title),
            "sleeping": .bool(tab?.isSleeping ?? false),
            "loading": .bool(tab?.isLoading ?? false),
            "selected_in_window_ids": .array(windowsSelecting(tab?.id)),
        ]
        fields.merge(extra) { _, new in new }
        return .object(fields)
    }

    // MARK: select_tab

    private enum SidebarItem {
        case favorite(Favorite, Profile)
        case pinned(PinnedEntry)
        case tab(BrowserTab)
    }

    private var selectTab: MCPTool {
        MCPTool(
            name: "select_tab",
            title: "Select a tab",
            description: "Selects a sidebar item in a window, as a click on its row does: switches the window to "
                + "the item's space if needed and wakes a dormant favorite or pinned entry. id is an item id or "
                + "tab_id from list_tabs. For a favorite shown in several spaces, space_id picks one.",
            inputSchema: MCPSchema.input([
                ("window_id", .integer("The window to select in")),
                ("id", .string("An item id or tab_id from list_tabs")),
                ("space_id", .string("Optional: the space to select the item in")),
            ], required: ["window_id", "id"]),
            outputSchema: MCPSchema.output([
                "window_id": MCPSchema.integerType,
                "space_id": MCPSchema.stringType,
                "selected_tab_id": MCPSchema.stringType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true],
            handler: { [self] arguments in
                let windowID = try arguments.requiredInt("window_id")
                let controller = try window(id: windowID)
                let id = try arguments.requiredUUID("id")
                let preferredSpace = try arguments.uuid("space_id").map { try space(id: $0) }
                let (space, item) = try locate(id, preferring: preferredSpace ?? controller.activeSpace)

                // The live tab first: a dormant item that stays dormant must
                // fail with the window left as it was, not switched to a
                // space with nothing selected.
                let tab: BrowserTab
                switch item {
                case .tab(let normal):
                    tab = normal
                case .pinned(let entry):
                    if entry.tab == nil { _ = store.activatePinnedEntry(id: entry.id, in: space) }
                    guard let live = entry.tab else {
                        throw AutomationToolError(.dormantRefused,
                                                  "The pinned entry stays dormant (its extension is disabled or missing)")
                    }
                    tab = live
                case .favorite(let favorite, let profile):
                    if favorite.tab == nil, !store.activateFavorite(id: favorite.id, profileID: profile.id, in: space) {
                        throw AutomationToolError(.dormantRefused,
                                                  "The favorite stays dormant (its extension is disabled or missing)")
                    }
                    guard let live = favorite.tab else {
                        throw AutomationToolError(.dormantRefused, "The favorite stays dormant")
                    }
                    tab = live
                }
                if controller.activeSpaceID != space.id {
                    controller.setActiveSpace(id: space.id, selectTab: false)
                }
                controller.selectTab(id: tab.id)
                guard controller.selectedTabID == tab.id else {
                    throw AutomationToolError(.internalError, "The window did not select the tab")
                }
                return [
                    "window_id": .int(windowID),
                    "space_id": .string(space.id.uuidString),
                    "selected_tab_id": .string(tab.id.uuidString),
                ]
            })
    }

    /// The space and sidebar item `id` names: an item id (favorite, pinned
    /// entry, tab) or a live tab's id. `preferred` is searched first, so a
    /// favorite, which every space of its profile shows, resolves there.
    private func locate(_ id: UUID, preferring preferred: Space?) throws -> (Space, SidebarItem) {
        let candidates = ([preferred].compactMap { $0 } + store.spaces).filter { !$0.isIncognito }
        for space in candidates {
            if let profile = space.profile,
               let favorite = profile.favorites.first(where: { $0.id == id || $0.tab?.id == id }) {
                return (space, .favorite(favorite, profile))
            }
            if let entry = space.pinnedEntries.first(where: { $0.id == id || $0.tab?.id == id }) {
                return (space, .pinned(entry))
            }
            if let tab = space.tabs.first(where: { $0.id == id }) {
                return (space, .tab(tab))
            }
        }
        if store.spaces.contains(where: { space in
            space.isIncognito && (space.tabs.contains { $0.id == id } || space.pinnedEntries.contains { $0.id == id })
        }) {
            throw AutomationToolError(.privateUnreachable, "Tab \(id.uuidString) is in a Private space")
        }
        throw AutomationToolError(.unknownTab, "No tab or sidebar item \(id.uuidString)")
    }

    // MARK: open_url

    private var openURL: MCPTool {
        MCPTool(
            name: "open_url",
            title: "Open a URL",
            description: "Opens a URL in a window as if it were typed in the command palette: in a new tab "
                + "(Cmd+T), or in the selected tab with in_place (Cmd+L). Link Routes apply to a new tab, as they "
                + "do to typed URLs, so a routed URL can open in another space or window (routed is then true); "
                + "a route into a Private window is refused with private_unreachable.",
            inputSchema: MCPSchema.input([
                ("window_id", .integer("The window to open in")),
                ("url", .string("An absolute URL, or a host such as example.com")),
                ("in_place", .boolean("Load in the selected tab instead of a new one (default false)")),
            ], required: ["window_id", "url"]),
            outputSchema: MCPSchema.output([
                "window_id": MCPSchema.integerType,
                "selected_tab_id": MCPSchema.nullableString,
                "routed": MCPSchema.booleanType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": true],
            handler: { [self] arguments in
                let windowID = try arguments.requiredInt("window_id")
                let controller = try window(id: windowID)
                let input = try arguments.requiredString("url").trimmingCharacters(in: .whitespaces)
                guard let url = controller.directURL(from: input) else {
                    throw AutomationToolError(.invalidArguments, "Not a URL: \(input)")
                }
                guard controller.activeSpace != nil else {
                    throw AutomationToolError(.unknownSpace, "Window \(windowID) shows no space")
                }
                let inPlace = try arguments.bool("in_place") ?? false
                // A route into a Private window would make one reachable from
                // automation, which it never is: refused, not followed. Only
                // where `openTypedURL` would route (the same rule it asks).
                if typedURLIsRoutable(url, isSearch: false, navigatesInPlace: inPlace && controller.selectedTab != nil),
                   let decision = controller.routedTypedDecision(for: url),
                   decision == .privateWindow || decision == .quarantine {
                    throw AutomationToolError(.privateUnreachable,
                                              "A Link Route sends \(url.absoluteString) to a Private window")
                }
                let routed = controller.openTypedURL(url, typed: true, navigateInPlace: inPlace)
                let after = controller.selectedTabID
                return [
                    "window_id": .int(windowID),
                    "selected_tab_id": .nullable(after?.uuidString),
                    "routed": .bool(routed),
                ]
            })
    }

    // MARK: run_menu_item

    private var runMenuItem: MCPTool {
        MCPTool(
            name: "run_menu_item",
            title: "Run a menu command",
            description: "Runs a main-menu command for a window, by menu path (for example [\"File\", \"New Tab\"]) "
                + "or by key equivalent (for example \"cmd+shift+t\", \"cmd+option+down\"). The command goes to that "
                + "window's responder chain and is validated there, so it works while Detour is not frontmost. "
                + "completed is false when the command is still running after a short wait (it opened a modal alert).",
            inputSchema: MCPSchema.input([
                ("window_id", .integer("The window the command is for")),
                ("path", .stringArray("Menu titles from the menu bar down, for example [\"View\", \"Toggle Sidebar\"]")),
                ("key", .string("A key equivalent: modifiers (cmd, shift, option, control) and a key joined by +")),
            ], required: ["window_id"]),
            outputSchema: MCPSchema.output([
                "title": MCPSchema.stringType,
                "path": ["type": "array", "items": ["type": "string"]],
                "completed": MCPSchema.booleanType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                let controller = try window(id: try arguments.requiredInt("window_id"))
                let path = try arguments.stringArray("path")
                let key = try arguments.string("key")
                guard (path == nil) != (key == nil) else {
                    throw AutomationToolError(.invalidArguments, "Give exactly one of path or key")
                }
                guard let menu = environment.mainMenu() else {
                    throw AutomationToolError(.unknownMenuItem, "There is no main menu")
                }
                let found: (item: NSMenuItem, path: [String])
                if let path {
                    found = try AutomationMenus.item(atPath: path, in: menu)
                } else {
                    let (characters, modifiers) = try AutomationMenus.parseKeyEquivalent(key!)
                    found = try AutomationMenus.item(matchingCharacters: characters, modifiers: modifiers, in: menu)
                }
                guard let window = controller.window else {
                    throw AutomationToolError(.unknownWindow, "The window has no NSWindow")
                }
                let (action, target) = try AutomationMenus.resolve(found.item, in: window)
                // From the run loop: see `AutomationInput.runFromRunLoop`.
                let item = found.item
                let completed = await AutomationInput.runFromRunLoop(wait: menuActionWait) {
                    NSApp.sendAction(action, to: target, from: item)
                }
                return [
                    "title": .string(found.item.title),
                    "path": .array(found.path.map(JSONValue.string)),
                    "completed": .bool(completed),
                ]
            })
    }
}

/// Finding, validating and targeting main-menu items for `run_menu_item`.
enum AutomationMenus {

    /// The item at `path` (titles, compared case-insensitively, with "..."
    /// matching "…"). Dynamic menus are rebuilt on the way down.
    static func item(atPath path: [String], in menu: NSMenu) throws -> (item: NSMenuItem, path: [String]) {
        guard !path.isEmpty else { throw AutomationToolError(.invalidArguments, "path is empty") }
        var current = menu
        var titles: [String] = []
        for (index, title) in path.enumerated() {
            refresh(current)
            // The Window menu's entry for a Private window bears its page's
            // title: neither matched nor listed.
            guard let item = current.items.first(where: {
                !$0.isSeparatorItem && !namesPrivateWindow($0) && titlesMatch(displayTitle($0), title)
            }) else {
                let available = current.items.filter { !$0.isSeparatorItem && !$0.isHidden && !namesPrivateWindow($0) }
                    .map(displayTitle)
                throw AutomationToolError(.unknownMenuItem,
                                          "No \"\(title)\" in \(titles.isEmpty ? "the menu bar" : titles.joined(separator: " > ")); "
                                            + "it has: \(available.joined(separator: ", "))")
            }
            titles.append(displayTitle(item))
            if index == path.count - 1 { return (item, titles) }
            guard let submenu = item.submenu else {
                throw AutomationToolError(.unknownMenuItem, "\(titles.joined(separator: " > ")) has no submenu")
            }
            current = submenu
        }
        throw AutomationToolError(.unknownMenuItem, "path is empty")
    }

    /// The first item anywhere under `menu` whose key equivalent is the given
    /// keystroke, with its path.
    static func item(matchingCharacters characters: String, modifiers: NSEvent.ModifierFlags,
                     in menu: NSMenu) throws -> (item: NSMenuItem, path: [String]) {
        if let found = search(menu, characters: characters, modifiers: modifiers, path: []) { return found }
        throw AutomationToolError(.unknownMenuItem, "No menu item has that key equivalent")
    }

    private static func search(_ menu: NSMenu, characters: String, modifiers: NSEvent.ModifierFlags,
                               path: [String]) -> (item: NSMenuItem, path: [String])? {
        refresh(menu)
        if let item = MenuKeyEquivalentMatcher.item(matchingCharacters: characters, modifiers: modifiers, in: menu.items) {
            return (item, path + [displayTitle(item)])
        }
        for item in menu.items {
            if let submenu = item.submenu,
               let found = search(submenu, characters: characters, modifiers: modifiers, path: path + [displayTitle(item)]) {
                return found
            }
        }
        return nil
    }

    /// Whether `window` is a Private browser window, which automation never
    /// reaches.
    static func isPrivate(_ window: NSWindow?) -> Bool {
        (window?.windowController as? BrowserWindowController)?.isIncognito == true
    }

    /// Whether `item` acts on a Private window: the Window menu's entry for
    /// one targets it, and is titled with its selected page's title.
    static func namesPrivateWindow(_ item: NSMenuItem) -> Bool {
        isPrivate(item.target as? NSWindow)
    }

    /// Lets a delegate-built menu (Spaces, Extensions) fill itself in, as it
    /// does when it opens.
    private static func refresh(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
    }

    /// The title a person sees. A menu-bar item's own title is AppKit's
    /// placeholder ("NSMenuItem"); the bar shows its submenu's title.
    static func displayTitle(_ item: NSMenuItem) -> String {
        guard let submenu = item.submenu, item.menu?.supermenu == nil else { return item.title }
        if !submenu.title.isEmpty { return submenu.title }
        // The application menu's submenu has no title; the bar shows the app's name.
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Detour"
    }

    static func titlesMatch(_ title: String, _ wanted: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: "...", with: "…").trimmingCharacters(in: .whitespaces)
        }
        return normalized(title).caseInsensitiveCompare(normalized(wanted)) == .orderedSame
    }

    /// The action and target the item would be sent to in `window`, checked
    /// with the target's own validation: what AppKit does for the key window,
    /// done for a window that need not be key (Detour need not be active).
    static func resolve(_ item: NSMenuItem, in window: NSWindow) throws -> (Selector, AnyObject) {
        // Before the action: AppKit gives an item with a submenu the action
        // `submenuAction:`, which only its own menu tracking may send.
        guard item.submenu == nil else {
            throw AutomationToolError(.unknownMenuItem, "\"\(displayTitle(item))\" opens a submenu; name an item in it")
        }
        guard !item.isSeparatorItem, let action = item.action else {
            throw AutomationToolError(.unknownMenuItem, "\"\(item.title)\" has no action")
        }
        guard !item.isHidden else {
            throw AutomationToolError(.menuItemDisabled, "\"\(item.title)\" is hidden")
        }
        guard !namesPrivateWindow(item) else {
            throw AutomationToolError(.privateUnreachable, "The item acts on a Private window")
        }
        guard let target = item.target ?? responderTarget(for: action, in: window) else {
            throw AutomationToolError(.menuItemDisabled, "Nothing in the window handles \"\(item.title)\"")
        }
        let enabled: Bool
        if item.menu?.autoenablesItems ?? true {
            if let validator = target as? NSMenuItemValidation {
                enabled = validator.validateMenuItem(item)
            } else if let validator = target as? NSUserInterfaceValidations {
                enabled = validator.validateUserInterfaceItem(item)
            } else {
                enabled = true
            }
        } else {
            enabled = item.isEnabled
        }
        guard enabled else {
            throw AutomationToolError(.menuItemDisabled, "\"\(item.title)\" is disabled")
        }
        return (action, target)
    }

    /// The first object along `window`'s responder chain that implements
    /// `action`: the first responder up to the window, then the window's
    /// delegate, the application and its delegate.
    static func responderTarget(for action: Selector, in window: NSWindow) -> AnyObject? {
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if let delegate = window.delegate, delegate.responds(to: action) { return delegate }
        if NSApp.responds(to: action) { return NSApp }
        if let delegate = NSApp.delegate, delegate.responds(to: action) { return delegate }
        return nil
    }

    /// Reads "cmd+shift+t", "cmd+[", "cmd+option+down": modifiers and one key,
    /// joined by "+". Arrow keys, return, tab, escape, delete and space have
    /// names; any other key is its single character ("+" itself is "plus").
    static func parseKeyEquivalent(_ value: String) throws -> (String, NSEvent.ModifierFlags) {
        let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let keyName = parts.last, !keyName.isEmpty else {
            throw AutomationToolError(.invalidArguments, "A key equivalent needs a key, got \"\(value)\"")
        }
        let modifiers = try AutomationInput.modifiers(Array(parts.dropLast()))
        let named: [String: String] = [
            "up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}",
            "return": "\r", "enter": "\r", "tab": "\t", "escape": "\u{1B}", "esc": "\u{1B}",
            "delete": "\u{8}", "backspace": "\u{8}", "forwarddelete": "\u{F728}", "space": " ", "plus": "+",
        ]
        if let character = named[keyName] { return (character, modifiers) }
        guard keyName.count == 1 else {
            throw AutomationToolError(.invalidArguments, "Unknown key \"\(keyName)\"")
        }
        return (keyName, modifiers)
    }
}
