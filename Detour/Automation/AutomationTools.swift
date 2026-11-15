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
/// order windows are first seen, one counter for every kind of window
/// (TASK-228.7). Not `NSWindow.windowNumber`, which is only assigned once a
/// window is on screen; that number is reported separately as
/// `window_number` (it is the CGWindowID screencapture takes). Settings keeps
/// its id across closing and reopening: its controller lives on.
final class AutomationWindowIDs {
    private let ids = NSMapTable<NSWindowController, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var next = 1

    func id(for controller: NSWindowController) -> Int {
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
    /// The other windows a client can address (TASK-228.7): Quick Detour,
    /// quarantine and Settings windows. Any other controller is ignored.
    /// None unless given, so a test lists only its own windows.
    var otherWindows: () -> [NSWindowController] = { [] }
    /// Whether the endpoint runs in the isolated test-run mode
    /// (`AutomationGate.Mode.testRun`). The tools that install extensions or
    /// grant them permissions without the user's prompt answer `gate_closed`
    /// otherwise (TASK-228.2, AC #7).
    var isTestRun = false
    /// Whether the user allows agents to use Private windows (TASK-228.5).
    /// Asked at every check: turning it off refuses again at once.
    var allowsPrivate: () -> Bool = { AutomationPrivateAccess.isAllowed() }

    static var live: AutomationEnvironment {
        AutomationEnvironment(
            windowControllers: { (NSApp.delegate as? AppDelegate)?.windowControllers ?? [] },
            mainMenu: { NSApp.mainMenu },
            store: .shared,
            otherWindows: AutomationWindows.liveOtherWindows)
    }
}

/// The tools of TASK-228.1's first phase: state, selection, navigation and
/// menu commands. Private windows and spaces are left out of lists and
/// refused by ID (`private_unreachable`) unless the user allows agents to use
/// Private windows (`AutomationEnvironment.allowsPrivate`, TASK-228.5).
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
            + extensionTools + compatReportTools + stagingTools + navigationSwipeTools
    }

    // MARK: Lookup

    var store: TabStore { environment.store }

    var openWindows: [BrowserWindowController] {
        environment.windowControllers().filter { !$0.hasClosed }
    }

    /// Whether Private windows, spaces and tabs are reachable now.
    var privateAllowed: Bool { environment.allowsPrivate() }

    /// The open windows a client may see: Private ones only while allowed.
    var reachableWindows: [BrowserWindowController] {
        let allowed = privateAllowed
        return openWindows.filter { AutomationWindows.access(of: $0 as NSWindowController).allows(allowed) }
    }

    /// The spaces a client may see: Private ones only while allowed.
    var reachableSpaces: [Space] {
        let allowed = privateAllowed
        return store.spaces.filter { allowed || !$0.isIncognito }
    }

    /// A message for a refused Private window, space or tab.
    static let privateHint = "; the user can allow agents to use Private windows in Detour's Settings"

    /// Every addressable window: browser windows, then Quick Detour,
    /// quarantine and Settings windows (TASK-228.7), reachable or not.
    var addressableWindows: [AutomationWindow] {
        openWindows.compactMap(AutomationWindows.describe)
            + environment.otherWindows().compactMap(AutomationWindows.describe)
                .filter { !($0.controller is BrowserWindowController) }
    }

    /// The window `window_id` names, of any kind. A Private one (a Private
    /// browser window, a Private Quick Detour or a quarantine window) only
    /// while the user allows it (`AutomationWindows.access(of:)`).
    func anyWindow(id: Int) throws -> AutomationWindow {
        guard let found = addressableWindows.first(where: { windowIDs.id(for: $0.controller) == id }) else {
            throw AutomationToolError(.unknownWindow, "No open window \(id)")
        }
        guard found.access.allows(privateAllowed) else { throw found.access.refusal("Window \(id)") }
        return found
    }

    /// The window `window_id` names for a tool that sends it input or a
    /// command. Settings takes them only in a test run (an isolated data
    /// directory): on the user's own endpoint its panes would let an agent
    /// do what the tools keep to test runs or to the user (installing and
    /// turning on extensions, permissions, profiles, Link Routes).
    func inputWindow(id: Int) throws -> AutomationWindow {
        let found = try anyWindow(id: id)
        if found.kind == .settings && !environment.isTestRun {
            throw AutomationToolError(.gateClosed,
                                      "Settings takes clicks, keys and menu commands only in a test run; "
                                        + "screenshot and hit_test work on it")
        }
        return found
    }

    /// Refuses input that would reach Settings' Automation section (its
    /// switches, token buttons and client list): a click on a view in it, or
    /// keys or a command while something in it has the keyboard. The user's,
    /// in a test run too: no tool turns on Private access (TASK-228.5).
    func refuseAutomationSettings(_ responder: NSResponder?) throws {
        guard AutomationWindows.isInAutomationSettings(responder) else { return }
        throw AutomationToolError(.gateClosed, "Settings' Automation section is the user's; no tool changes it")
    }

    /// The browser window `window_id` names, for the tools that act on its
    /// spaces and tabs. Another kind of window is `unsupported_window`.
    func window(id: Int) throws -> BrowserWindowController {
        let found = try anyWindow(id: id)
        guard let browser = found.browser else {
            throw AutomationToolError(.unsupportedWindow,
                                      "Window \(id) is a \(found.kind.rawValue) window; this tool takes a browser window")
        }
        return browser
    }

    func space(id: UUID) throws -> Space {
        guard let space = store.space(withID: id) else {
            throw AutomationToolError(.unknownSpace, "No space \(id.uuidString)")
        }
        guard privateAllowed || !space.isIncognito else {
            throw AutomationToolError(.privateUnreachable, "Space \(id.uuidString) is Private" + Self.privateHint)
        }
        return space
    }

    private func windowsSelecting(_ tabID: UUID?) -> [JSONValue] {
        guard let tabID else { return [] }
        return reachableWindows.filter { $0.selectedTabID == tabID }
            .map { .int(windowIDs.id(for: $0)) }
    }

    // MARK: list_windows

    private var listWindows: MCPTool {
        MCPTool(
            name: "list_windows",
            title: "List windows",
            description: "Lists Detour's windows with their kind: browser, quick_detour, quarantine and settings "
                + "(Private windows, Private Quick Detour and quarantine windows included, are left out unless the "
                + "user allows agents to use Private windows; is_private says which is one): each one's window_id, "
                + "window_number (its CGWindowID), frame (AppKit's, bottom-left origin), screen_bounds (the window "
                + "server's, top-left origin, as screencapture takes it), display_id, key/main state, active space "
                + "and selected tab (a Quick Detour's page). window_id is what the other tools take; the tools for "
                + "spaces and tabs take browser windows only. Settings takes input only in a test run.",
            inputSchema: MCPSchema.input([]),
            outputSchema: MCPSchema.output([
                "app_active": MCPSchema.booleanType,
                "windows": MCPSchema.arrayOfObjects("One entry per window"),
                "hidden_private_windows": MCPSchema.integerType,
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] _ in
                let windows = addressableWindows
                let allowed = privateAllowed
                let visible = windows.filter { $0.access.allows(allowed) }
                return [
                    "app_active": .bool(NSApp.isActive),
                    "windows": .array(visible.map(describe)),
                    "hidden_private_windows": .int(windows.count - visible.count),
                ]
            })
    }

    private func describe(_ entry: AutomationWindow) -> JSONValue {
        let window = entry.window
        let frame = window.frame
        let controller = entry.browser
        // A Quick Detour's page is not a tab of a space: the page tools do not
        // take it, so its id is not given, only what the window shows.
        let quickDetourTab = (entry.controller as? QuickDetourWindowController)?.tab
        let selectedTab = controller?.selectedTab ?? quickDetourTab
        return [
            "window_id": .int(windowIDs.id(for: entry.controller)),
            "kind": .string(entry.kind.rawValue),
            "window_number": .int(window.windowNumber),
            "frame": ["x": .double(frame.origin.x), "y": .double(frame.origin.y),
                      "width": .double(frame.width), "height": .double(frame.height)],
            // Global top-left points, as screencapture takes them (TASK-228.3):
            // the window server's bounds, null while the window is off screen.
            "screen_bounds": Self.screenBounds(ofWindowNumber: window.windowNumber).map(Self.json) ?? .null,
            "display_id": window.screen.flatMap(Self.displayID).map { .int(Int($0)) } ?? .null,
            "is_key": .bool(window.isKeyWindow),
            "is_main": .bool(window.isMainWindow),
            "is_visible": .bool(window.isVisible),
            "is_miniaturized": .bool(window.isMiniaturized),
            "is_private": .bool(entry.access != .open),
            "active_space_id": .nullable(controller?.activeSpaceID?.uuidString),
            "selected_tab_id": .nullable(controller?.selectedTabID?.uuidString),
            "selected_tab_url": .nullable(selectedTab?.url?.absoluteString),
            "selected_tab_title": .nullable(selectedTab?.title),
        ]
    }

    // MARK: list_spaces

    private var listSpaces: MCPTool {
        MCPTool(
            name: "list_spaces",
            title: "List spaces",
            description: "Lists the spaces (Private ones are left out unless the user allows agents to use Private "
                + "windows) with their profile, tab counts and the windows showing each one.",
            inputSchema: MCPSchema.input([]),
            outputSchema: MCPSchema.output(["spaces": MCPSchema.arrayOfObjects("One entry per space")]),
            annotations: ["readOnlyHint": true],
            handler: { [self] _ in
                let windows = reachableWindows
                let spaces: [JSONValue] = reachableSpaces.map { space in
                    [
                        "space_id": .string(space.id.uuidString),
                        "name": .string(space.name),
                        "emoji": .string(space.emoji),
                        "color": .string(space.colorHex),
                        "profile_id": .string(space.profileID.uuidString),
                        "profile_name": .nullable(space.profile?.name),
                        "is_private": .bool(space.isIncognito),
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
        let allowed = privateAllowed
        let candidates = ([preferred].compactMap { $0 } + store.spaces).filter { allowed || !$0.isIncognito }
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
            throw AutomationToolError(.privateUnreachable, "Tab \(id.uuidString) is in a Private space" + Self.privateHint)
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
                + "a route into a Private window is refused with private_unreachable unless the user allows agents "
                + "to use Private windows. Routes never send a typed URL to a quarantine.",
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
                // A route into a Private window would make one reachable
                // from automation: refused, not followed, unless the user
                // allows Private windows (TASK-228.5). A typed URL is never
                // quarantined (the resolver's rule), so `.quarantine` cannot
                // come back here today; if it ever does, it follows the same
                // setting, as open quarantine windows do (TASK-228.7, the
                // user's decision of 2026-11-15). Only where `openTypedURL`
                // would route (the same rule it asks).
                if typedURLIsRoutable(url, isSearch: false, navigatesInPlace: inPlace && controller.selectedTab != nil),
                   let decision = controller.routedTypedDecision(for: url),
                   decision == .quarantine || decision == .privateWindow, !privateAllowed {
                    throw AutomationToolError(.privateUnreachable,
                                              "A Link Route sends \(url.absoluteString) to a "
                                                + (decision == .quarantine ? "quarantine" : "Private window"))
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
                + "window's responder chain and is validated there, so it works while Detour is not frontmost. Menus "
                + "are validated for that window before a path is matched, so a title that changes with the window "
                + "(Pin Tab, Unpin Tab) is the one it shows there. Any kind of window from list_windows. "
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
                let addressed = try inputWindow(id: try arguments.requiredInt("window_id"))
                let path = try arguments.stringArray("path")
                let key = try arguments.string("key")
                guard (path == nil) != (key == nil) else {
                    throw AutomationToolError(.invalidArguments, "Give exactly one of path or key")
                }
                guard let menu = environment.mainMenu() else {
                    throw AutomationToolError(.unknownMenuItem, "There is no main menu")
                }
                let window = addressed.window
                try refuseAutomationSettings(window.firstResponder)
                let found: (item: NSMenuItem, path: [String])
                let allowPrivate = privateAllowed
                if let path {
                    found = try AutomationMenus.item(atPath: path, in: menu, validatingFor: window,
                                                     allowPrivate: allowPrivate)
                } else {
                    let (characters, modifiers) = try AutomationMenus.parseKeyEquivalent(key!)
                    found = try AutomationMenus.item(matchingCharacters: characters, modifiers: modifiers, in: menu)
                }
                let (action, target) = try AutomationMenus.resolve(found.item, in: window, allowPrivate: allowPrivate)
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
    /// matching "…"). Each menu on the way down is brought up to date as it
    /// is before it opens: a delegate-built one is rebuilt, and its items are
    /// validated for `window` (TASK-228.7), which retitles the ones that
    /// change with it ("Pin Tab" / "Unpin Tab"), so the title matched is the
    /// one the person would see there. A Private window's Window-menu entry
    /// only with `allowPrivate`.
    static func item(atPath path: [String], in menu: NSMenu, validatingFor window: NSWindow?,
                     allowPrivate: Bool) throws -> (item: NSMenuItem, path: [String]) {
        guard !path.isEmpty else { throw AutomationToolError(.invalidArguments, "path is empty") }
        var current = menu
        var titles: [String] = []
        for (index, title) in path.enumerated() {
            refresh(current)
            if let window { validate(current, for: window) }
            // The Window menu's entry for a Private window bears its page's
            // title: neither matched nor listed, unless Private is allowed.
            let hidden: (NSMenuItem) -> Bool = { namesUnreachableWindow($0, allowPrivate: allowPrivate) }
            guard let item = current.items.first(where: {
                !$0.isSeparatorItem && !hidden($0) && titlesMatch(displayTitle($0), title)
            }) else {
                let available = current.items.filter { !$0.isSeparatorItem && !$0.isHidden && !hidden($0) }
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

    /// Whether `item` acts on a window a client may not reach with
    /// `allowPrivate`: the Window menu's entry for a Private window (browser,
    /// Quick Detour or quarantine) targets it, and is titled with its page's
    /// title.
    static func namesUnreachableWindow(_ item: NSMenuItem, allowPrivate: Bool) -> Bool {
        guard let window = item.target as? NSWindow else { return false }
        return !AutomationWindows.access(of: window).allows(allowPrivate)
    }

    /// The refusal for an item that acts on such a window.
    static func refusal(for item: NSMenuItem) -> AutomationToolError {
        AutomationWindows.access(of: item.target as? NSWindow).refusal("The window the item acts on")
    }

    /// Lets a delegate-built menu (Spaces, Extensions) fill itself in, as it
    /// does when it opens.
    private static func refresh(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
    }

    /// Validates `menu`'s items as AppKit does before showing it, for
    /// `window` rather than the key window: each item's target (its own, or
    /// the first along the window's responder chain) is asked, which is
    /// where a command retitles its item (`BrowserCommands.validate`).
    /// `NSMenu.update()` is not used: it asks the key window's chain, and
    /// with Detour in the background there may be none, or another window.
    /// Items with submenus are skipped (their own menu is validated when the
    /// path goes into it), and so are the Window menu's entries, whose
    /// target is the window they name.
    static func validate(_ menu: NSMenu, for window: NSWindow) {
        for item in menu.items where !item.isSeparatorItem && item.submenu == nil {
            guard let action = item.action, !(item.target is NSWindow),
                  let target = item.target ?? CommandDispatch.responderTarget(for: action, in: window) else { continue }
            // For the retitling; the enable decision is `resolve`'s, at the end.
            _ = CommandDispatch.isEnabled(item, autoenables: menu.autoenablesItems, target: target)
        }
    }

    /// The title a person sees. The bar shows a menu-bar item's submenu
    /// title; Detour's bar items carry the same title (TASK-334), but one
    /// made with `NSMenuItem()` reports AppKit's placeholder ("NSMenuItem").
    static func displayTitle(_ item: NSMenuItem) -> String {
        guard let submenu = item.submenu, item.menu?.supermenu == nil else { return item.title }
        if !submenu.title.isEmpty { return submenu.title }
        // An untitled application menu: the bar shows the app's name.
        return AppDelegate.appName
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
    /// The resolution and the enable decision are `CommandDispatch`'s, which
    /// the command palette runs its commands through too (TASK-320).
    static func resolve(_ item: NSMenuItem, in window: NSWindow, allowPrivate: Bool) throws -> (Selector, AnyObject) {
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
        guard !namesUnreachableWindow(item, allowPrivate: allowPrivate) else { throw refusal(for: item) }
        guard let target = item.target ?? CommandDispatch.responderTarget(for: action, in: window) else {
            throw AutomationToolError(.menuItemDisabled, "Nothing in the window handles \"\(item.title)\"")
        }
        guard CommandDispatch.isEnabled(item, autoenables: item.menu?.autoenablesItems ?? true, target: target) else {
            throw AutomationToolError(.menuItemDisabled, "\"\(item.title)\" is disabled")
        }
        return (action, target)
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
