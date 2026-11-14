import AppKit
import GRDB

/// Staging for captures (TASK-228.3): a demo world from a fixture file, the
/// displays and exact window placement for screencapture, and (Debug builds)
/// specific UI on demand. What replaced the DemoStage harness of
/// docs/task-110; the capture kit itself lives in docs/capture.
extension AutomationTools {

    var stagingTools: [MCPTool] {
        var tools = [seedWorld, listDisplays, setWindowFrame]
        #if DEBUG
        // Testing-only, like set_debug_override: absent from Release builds.
        tools.append(openUI)
        #endif
        return tools
    }

    // MARK: seed_world

    private var seedWorld: MCPTool {
        MCPTool(
            name: "seed_world",
            title: "Seed a demo world",
            description: "Test runs only. Builds a world from a fixture file (JSON: profiles with favorites; spaces "
                + "with name, emoji, color, profile, pinned pages, nested folders and splits, and tabs and splits; "
                + "history visits with ages; link routes; the active space) into an empty data directory: one "
                + "profile, one space, nothing pinned, no favorites, no tabs with a page, no history and no routes. "
                + "The fixture's first profile is the existing one, renamed; the existing space is replaced. Titles "
                + "come from the file, so nothing loads first: pinned entries and favorites are dormant, tabs asleep. "
                + "The whole file is checked before anything changes (invalid_fixture names the field); a data "
                + "directory with anything in it is not_empty. Saved at once, so it is there after a relaunch.",
            inputSchema: MCPSchema.input([
                ("fixture_path", .string("An absolute path to the fixture's JSON file")),
            ], required: ["fixture_path"]),
            outputSchema: MCPSchema.output([
                "counts": MCPSchema.objectType,
                "profile_ids": MCPSchema.objectType,
                "space_ids": MCPSchema.objectType,
                "active_space_id": MCPSchema.stringType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                try requireStagingTestRun("seed_world")
                let path = try arguments.requiredString("fixture_path")
                guard path.hasPrefix("/") else {
                    throw AutomationToolError(.invalidArguments, "fixture_path must be an absolute path")
                }
                let data: Data
                do {
                    let url = URL(fileURLWithPath: path)
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 4 << 20 else {
                        throw AutomationToolError(.invalidFixture, "\(path) is larger than 4 MB")
                    }
                    data = try Data(contentsOf: url)
                } catch let error as AutomationToolError {
                    throw error
                } catch {
                    throw AutomationToolError(.invalidArguments, "Cannot read \(path): \(error.localizedDescription)")
                }

                let found = try worldContents()
                guard found.isEmpty else {
                    throw AutomationToolError(.notEmpty, "The data directory is not empty: \(found.joined(separator: ", "))",
                                              details: .array(found.map(JSONValue.string)))
                }
                let normalProfiles = store.profiles.filter { !$0.isIncognito }
                let defaultProfile = normalProfiles[0]
                let plan: AutomationWorldFixture.Plan
                do throws(AutomationWorldFixture.Problem) {
                    plan = try AutomationWorldFixture.plan(from: data, defaultProfileID: defaultProfile.id)
                } catch {
                    throw AutomationToolError(.invalidFixture, error.description,
                                              details: ["path": .string(error.path), "message": .string(error.message)])
                }
                return try await seed(plan, defaultProfile: defaultProfile)
            })
    }

    /// Staging moves windows, takes the front and rebuilds the world: only
    /// in the isolated test-run mode, never on the user's own endpoint.
    func requireStagingTestRun(_ tool: String) throws {
        guard environment.isTestRun else {
            throw AutomationToolError(.gateClosed,
                                      "\(tool) works only in a test run (DETOUR_MCP=1 with an isolated DETOUR_DATA_DIR)")
        }
    }

    /// What the store holds beyond a fresh data directory's one empty space,
    /// as short phrases; empty when there is nothing.
    func worldContents() throws -> [String] {
        var found: [String] = []
        let profiles = store.profiles.filter { !$0.isIncognito }
        if profiles.count != 1 { found.append("\(profiles.count) profiles") }
        let favorites = profiles.reduce(0) { $0 + $1.favorites.count }
        if favorites > 0 { found.append("\(favorites) favorites") }
        let spaces = store.nonIncognitoSpaces
        if spaces.count != 1 { found.append("\(spaces.count) spaces") }
        let pinned = spaces.reduce(0) { $0 + $1.pinnedEntries.count }
        if pinned > 0 { found.append("\(pinned) pinned entries") }
        let folders = spaces.reduce(0) { $0 + $1.pinnedFolders.count }
        if folders > 0 { found.append("\(folders) pinned folders") }
        // A fresh window's empty New Tab is not content.
        let pages = spaces.reduce(0) { count, space in
            count + space.tabs.filter { $0.url.map { $0.absoluteString != "about:blank" } ?? false }.count
        }
        if pages > 0 { found.append("\(pages) tabs with a page") }
        let routes = store.linkRoutes
        if !routes.routes.isEmpty { found.append("\(routes.routes.count) link routes") }
        if routes.defaultTarget != .defaultTarget { found.append("a Link Routes default") }
        let visits: Int
        do {
            visits = try store.historyDB.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyVisit") ?? 0
            }
        } catch {
            throw AutomationToolError(.internalError, "Cannot read the history: \(error.localizedDescription)")
        }
        if visits > 0 { found.append("\(visits) history visits") }
        return found
    }

    /// Carries out a checked fixture. The store was empty and the plan was
    /// checked against it, so nothing here is expected to fail; if a step
    /// does, the message says what was done by then.
    private func seed(_ plan: AutomationWorldFixture.Plan, defaultProfile: Profile) async throws -> JSONValue {
        let originals = store.nonIncognitoSpaces
        defaultProfile.name = plan.defaultProfileName
        store.updateProfile(defaultProfile)
        do {
            try store.applyArcImport(plan.world)
        } catch {
            throw AutomationToolError(.internalError, "The world did not fit the store (\(error)); only the profile was renamed")
        }
        for (spaceID, tabID) in plan.selectedTabs {
            store.space(withID: spaceID)?.selectedTabID = tabID
        }
        for route in plan.routes where store.linkRoutes.add(route) == nil {
            throw AutomationToolError(.internalError, "A link route was refused after the spaces were added")
        }
        for controller in openWindows where !controller.isIncognito {
            controller.setActiveSpace(id: plan.activeSpaceID)
        }
        for space in originals {
            let result = store.deleteSpace(id: space.id)
            guard result == .deleted else {
                throw AutomationToolError(.internalError, "The data directory's own space was not removed (\(result))")
            }
        }
        store.lastActiveSpaceID = plan.activeSpaceID
        store.noteSpaceUsed(plan.activeSpaceID)
        // Seeding is not something to undo.
        store.undoManager.removeAllActions()
        guard case .saved = store.saveNow() else {
            throw AutomationToolError(.internalError, "The session could not be saved")
        }
        let historyDB = store.historyDB
        for (spaceID, visits) in plan.history {
            let written = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Int, any Error>, Never>) in
                historyDB.importVisits(visits, spaceID: spaceID.uuidString) { continuation.resume(returning: $0) }
            }
            if case .failure(let error) = written {
                throw AutomationToolError(.internalError, "History visits were not written: \(error.localizedDescription)")
            }
        }

        var profileIDs: [String: JSONValue] = [plan.defaultProfileName: .string(defaultProfile.id.uuidString)]
        for profile in plan.world.profiles { profileIDs[profile.name] = .string(profile.id.uuidString) }
        var spaceIDs: [String: JSONValue] = [:]
        for space in plan.world.spaces { spaceIDs[space.name] = .string(space.id.uuidString) }
        return [
            "counts": .object(plan.counts.mapValues(JSONValue.int)),
            "profile_ids": .object(profileIDs),
            "space_ids": .object(spaceIDs),
            "active_space_id": .string(plan.activeSpaceID.uuidString),
        ]
    }

    // MARK: list_displays

    private var listDisplays: MCPTool {
        MCPTool(
            name: "list_displays",
            title: "List displays",
            description: "Lists the displays (virtual ones included): display_id (the CGDirectDisplayID), frame and "
                + "visible_frame (without the menu bar and Dock) in global points with a top-left origin, as "
                + "screencapture -R takes them, scale (2 on a Retina display), main and name.",
            inputSchema: MCPSchema.input([]),
            outputSchema: MCPSchema.output(["displays": MCPSchema.arrayOfObjects("One entry per display")]),
            annotations: ["readOnlyHint": true],
            handler: { _ in
                ["displays": .array(NSScreen.screens.map(Self.describe))]
            })
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The height global top-left coordinates are flipped by: the primary
    /// display's (AppKit's origin is its bottom-left corner).
    static var primaryDisplayHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    /// An AppKit screen rectangle in global top-left points.
    static func topLeft(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func json(_ rect: CGRect) -> JSONValue {
        ["x": .double(rect.minX), "y": .double(rect.minY), "width": .double(rect.width), "height": .double(rect.height)]
    }

    private static func describe(_ screen: NSScreen) -> JSONValue {
        let id = displayID(of: screen)
        return [
            "display_id": id.map { .int(Int($0)) } ?? .null,
            "name": .string(screen.localizedName),
            "frame": json(topLeft(screen.frame)),
            "visible_frame": json(topLeft(screen.visibleFrame)),
            "scale": .double(screen.backingScaleFactor),
            "main": .bool(id.map { CGDisplayIsMain($0) != 0 } ?? false),
            "pixel_width": id.map { .int(CGDisplayPixelsWide($0)) } ?? .null,
            "pixel_height": id.map { .int(CGDisplayPixelsHigh($0)) } ?? .null,
        ]
    }

    // MARK: set_window_frame

    private var setWindowFrame: MCPTool {
        MCPTool(
            name: "set_window_frame",
            title: "Place a window",
            description: "Test runs only. Moves and sizes a window, in points with a top-left origin: global coordinates, or relative "
                + "to the top-left of display_id (from list_displays) to put it on that display, a virtual one "
                + "included. window_id is a browser window; window_number (a CGWindowID from list_windows, or from "
                + "open_ui in Debug builds) reaches Detour's other windows too, such as Settings. Returns the frame "
                + "read back after "
                + "the move and screen_bounds, the window server's own bounds of the window (what screencapture "
                + "-l and -R see), with window_number for screencapture; settled is false when the window server "
                + "had not caught up within 2 s. activate brings Detour to the front with "
                + "the window key, as a recording of an active window needs (it takes focus from the app in front).",
            inputSchema: MCPSchema.input([
                ("window_id", .integer("A browser window from list_windows")),
                ("window_number", .integer("Or any of Detour's windows by its CGWindowID")),
                ("x", .number("Left edge in points")),
                ("y", .number("Top edge in points, from the top")),
                ("width", .number("Width in points")),
                ("height", .number("Height in points")),
                ("display_id", .integer("Optional: x and y are relative to this display's top-left corner")),
                ("activate", .boolean("Bring Detour to the front with this window key (default false)")),
            ], required: ["x", "y", "width", "height"]),
            outputSchema: MCPSchema.output(Self.placementSchema.merging(["settled": MCPSchema.booleanType]) { $1 }),
            annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true],
            handler: { [self] arguments in
                try requireStagingTestRun("set_window_frame")
                let window = try placeableWindow(arguments)
                let activate = try arguments.bool("activate") ?? false
                var rect = CGRect(x: try arguments.number("x") ?? 0, y: try arguments.number("y") ?? 0,
                                  width: try arguments.number("width") ?? 0, height: try arguments.number("height") ?? 0)
                guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                      rect.width >= 1, rect.height >= 1 else {
                    throw AutomationToolError(.invalidArguments, "width and height must be at least 1, all values finite")
                }
                if let displayID = try arguments.int("display_id") {
                    guard let screen = NSScreen.screens.first(where: { Self.displayID(of: $0).map(Int.init) == displayID }) else {
                        throw AutomationToolError(.unknownDisplay, "No display \(displayID); list_displays names them")
                    }
                    let origin = Self.topLeft(screen.frame).origin
                    rect.origin.x += origin.x
                    rect.origin.y += origin.y
                }
                let appKit = NSRect(x: rect.minX, y: Self.primaryDisplayHeight - rect.maxY,
                                    width: rect.width, height: rect.height)
                window.setFrame(appKit, display: true)
                if activate {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
                // The window server follows a moment later, and a window
                // that has just appeared is still scaling up from its centre
                // (AppKit's open animation): wait until its bounds are the
                // frame, so a recording region taken from them is right.
                var settled = false
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if let bounds = Self.screenBounds(ofWindowNumber: window.windowNumber),
                       Self.matches(bounds, Self.topLeft(window.frame)) {
                        settled = true
                        break
                    }
                }
                var result = placement(of: window)
                result["settled"] = .bool(settled)
                return .object(result)
            })
    }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    static let placementSchema: [String: JSONValue] = [
        "window_id": ["type": ["integer", "null"]],
        "window_number": MCPSchema.integerType,
        "frame": MCPSchema.objectType,
        "screen_bounds": ["type": ["object", "null"]],
        "display_id": ["type": ["integer", "null"]],
        "scale": ["type": "number"],
        "is_key": MCPSchema.booleanType,
        "app_active": MCPSchema.booleanType,
    ]

    /// The window `window_id` or `window_number` names: a browser window
    /// (not a Private one), or another of Detour's windows (Settings, the
    /// Arc import window). Never a Private window, never a sheet (it moves
    /// with its parent).
    private func placeableWindow(_ arguments: ToolArguments) throws -> NSWindow {
        let windowID = try arguments.int("window_id")
        let number = try arguments.int("window_number")
        guard (windowID == nil) != (number == nil) else {
            throw AutomationToolError(.invalidArguments, "Give window_id or window_number")
        }
        if let windowID {
            guard let window = try self.window(id: windowID).window else {
                throw AutomationToolError(.unknownWindow, "Window \(windowID) has no NSWindow")
            }
            return window
        }
        guard let window = NSApp.windows.first(where: { $0.windowNumber == number && $0.isVisible }) else {
            throw AutomationToolError(.unknownWindow, "Detour has no visible window \(number!)")
        }
        guard !AutomationMenus.isPrivate(window), !AutomationMenus.isPrivate(window.sheetParent) else {
            throw AutomationToolError(.privateUnreachable, "Window \(number!) is a Private window")
        }
        guard window.sheetParent == nil else {
            throw AutomationToolError(.invalidArguments, "Window \(number!) is a sheet; move the window it is attached to")
        }
        return window
    }

    /// Where `window` is now: its frame (AppKit's, in global top-left
    /// points) and the window server's bounds of it, which is what a
    /// recording region must be taken from.
    func placement(of window: NSWindow) -> [String: JSONValue] {
        let controller = window.windowController as? BrowserWindowController
        let browserWindowID = controller.flatMap { c in openWindows.contains { $0 === c } ? windowIDs.id(for: c) : nil }
        let screen = window.screen
        return [
            "window_id": browserWindowID.map(JSONValue.int) ?? .null,
            "window_number": .int(window.windowNumber),
            "frame": Self.json(Self.topLeft(window.frame)),
            "screen_bounds": Self.screenBounds(ofWindowNumber: window.windowNumber).map(Self.json) ?? .null,
            "display_id": screen.flatMap(Self.displayID).map { .int(Int($0)) } ?? .null,
            "scale": .double(window.backingScaleFactor),
            // A recording of an active window needs both (coloured traffic lights).
            "is_key": .bool(window.isKeyWindow),
            "app_active": .bool(NSApp.isActive),
        ]
    }

    /// The window server's bounds of an on-screen window, in global top-left
    /// points; nil when it is not on screen.
    static func screenBounds(ofWindowNumber number: Int) -> CGRect? {
        guard number > 0,
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let entry = info.first,
              entry[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    // MARK: open_ui (Debug builds only)

    #if DEBUG
    private var openUI: MCPTool {
        MCPTool(
            name: "open_ui",
            title: "Open UI for staging",
            description: "Debug builds and test runs only. Opens a piece of UI as it would be for a capture. what space_editor: the "
                + "space editor in window_id's sidebar, for a new space or (space_id) an existing one, with a draft "
                + "from name, emoji, color and profile_id (the rest default as the + button's would); its name field "
                + "has keyboard focus, so type_text with window_id types into it. what arc_offer: the launch offer "
                + "to import from Arc, as a sheet on window_id, read from arc_folder (a fake Arc data folder, such "
                + "as docs/capture/make_fake_arc.py makes, inside the data directory or a temporary folder; never "
                + "Arc's own). what arc_import: the Import from Arc window, reading arc_folder. Both arc ones "
                + "point this process's Arc reading at arc_folder until it quits. what "
                + "settings: the Settings window on pane, with row selected in the pane's list. Returns the "
                + "window_number and frame of the window the UI is in, for set_window_frame and screencapture.",
            inputSchema: MCPSchema.input([
                ("what", .enumeration(["space_editor", "arc_offer", "arc_import", "settings"], "The UI to open")),
                ("window_id", .integer("space_editor, arc_offer: the browser window")),
                ("space_id", .string("space_editor: edit this space instead of creating one")),
                ("name", .string("space_editor: the draft's name")),
                ("emoji", .string("space_editor: the draft's emoji")),
                ("color", .string("space_editor: the draft's colour, six hex digits")),
                ("profile_id", .string("space_editor: the draft's profile")),
                ("arc_folder", .string("arc_offer, arc_import: an absolute path to a fake Arc data folder")),
                ("pane", .enumeration(SettingsWindowController.paneNames, "settings: the pane")),
                ("row", .integer("settings: the row to select in the pane's list, from 0")),
            ], required: ["what"]),
            outputSchema: MCPSchema.output(Self.placementSchema.merging([
                "what": MCPSchema.stringType,
                "draft": ["type": ["object", "null"]],
                "rows": ["type": ["integer", "null"]],
            ]) { $1 }),
            annotations: ["readOnlyHint": false, "destructiveHint": false],
            handler: { [self] arguments in
                try requireStagingTestRun("open_ui")
                let what = try arguments.requiredString("what")
                let accepted: Set<String>
                switch what {
                case "space_editor": accepted = ["what", "window_id", "space_id", "name", "emoji", "color", "profile_id"]
                case "arc_offer": accepted = ["what", "window_id", "arc_folder"]
                case "arc_import": accepted = ["what", "arc_folder"]
                case "settings": accepted = ["what", "pane", "row"]
                default: throw AutomationToolError(.invalidArguments, "what is space_editor, arc_offer, arc_import or settings")
                }
                if let extra = arguments.values.keys.sorted().first(where: { !accepted.contains($0) }) {
                    throw AutomationToolError(.invalidArguments, "\(extra) does not apply to \(what)")
                }
                var result: [String: JSONValue]
                switch what {
                case "space_editor": result = try openSpaceEditor(arguments)
                case "arc_offer": result = try await openArcOffer(arguments)
                case "arc_import": result = try await openArcImport(arguments)
                default: result = try await openSettings(arguments)
                }
                result["what"] = .string(what)
                return .object(result)
            })
    }

    private func openSpaceEditor(_ arguments: ToolArguments) throws -> [String: JSONValue] {
        let controller = try window(id: try arguments.requiredInt("window_id"))
        let editing = try arguments.uuid("space_id").map { try space(id: $0) }
        guard var draft = editing.map({ SpaceDraft(name: $0.name, emoji: $0.emoji, colorHex: $0.colorHex,
                                                    profileID: $0.profileID) }) ?? controller.newSpaceDraft() else {
            throw AutomationToolError(.internalError, "The window has no profile for a new space")
        }
        if let name = try arguments.string("name") { draft.name = name }
        if let emoji = try arguments.string("emoji") {
            guard !emoji.isEmpty else { throw AutomationToolError(.invalidArguments, "emoji is empty") }
            draft.emoji = emoji
        }
        if let color = try arguments.string("color") {
            let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else {
                throw AutomationToolError(.invalidArguments, "color is six hex digits such as FF7600")
            }
            draft.colorHex = hex.uppercased()
        }
        if let profileID = try arguments.uuid("profile_id") {
            guard let profile = store.profile(withID: profileID) else {
                throw AutomationToolError(.unknownProfile, "No profile \(profileID.uuidString)")
            }
            guard !profile.isIncognito else {
                throw AutomationToolError(.privateUnreachable, "The Private profile has no spaces")
            }
            draft.profileID = profileID
        }
        if let editing {
            controller.beginEditingSpace(id: editing.id, draft: draft)
        } else {
            controller.beginCreatingSpace(draft: draft)
        }
        guard controller.tabSidebar.isSpaceEditorOpen, let window = controller.window else {
            throw AutomationToolError(.internalError, "The space editor did not open")
        }
        var result = placement(of: window)
        result["draft"] = ["name": .string(draft.name), "emoji": .string(draft.emoji),
                           "color": .string(draft.colorHex), "profile_id": .string(draft.profileID.uuidString)]
        return result
    }

    /// A fake Arc folder a client may point the app at: inside the data
    /// directory or a temporary folder, after symlinks, and with Arc's
    /// sidebar file in it. Never Arc's own folder (TASK-228.3).
    static func fixtureArcFolder(_ path: String, dataDirectory: URL) throws -> URL {
        guard path.hasPrefix("/") else {
            throw AutomationToolError(.invalidArguments, "arc_folder must be an absolute path")
        }
        // realpath, not resolvingSymlinksInPath, which turns /private/tmp
        // into /tmp: every path compared must be spelt the same way.
        func resolved(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            guard let real = realpath(path, nil) else { return path }
            defer { free(real) }
            return String(cString: real)
        }
        let folder = resolved(URL(fileURLWithPath: path, isDirectory: true))
        let roots = [dataDirectory, FileManager.default.temporaryDirectory,
                     URL(fileURLWithPath: "/tmp"), URL(fileURLWithPath: "/private/var/folders")].map(resolved)
        guard roots.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }),
              folder != resolved(ArcSidebarReader.userDataDirectory) else {
            throw AutomationToolError(.invalidArguments,
                                      "arc_folder must be inside the data directory or a temporary folder, never Arc's own")
        }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard ArcSidebarReader.isArcDataPresent(in: url) else {
            throw AutomationToolError(.invalidArguments, "\(folder) has no StorableSidebar.json")
        }
        return url
    }

    private func arcFolder(_ arguments: ToolArguments) throws -> URL {
        return try Self.fixtureArcFolder(try arguments.requiredString("arc_folder"), dataDirectory: detourDataDirectory())
    }

    private func openArcOffer(_ arguments: ToolArguments) async throws -> [String: JSONValue] {
        let controller = try window(id: try arguments.requiredInt("window_id"))
        let folder = try arcFolder(arguments)
        let read = await Task.detached(priority: .userInitiated) { () -> Result<ArcImportSnapshot, ArcImportError> in
            do throws(ArcImportError) { return .success(try ArcSidebarReader.read(dataDirectory: folder)) }
            catch { return .failure(error) }
        }.value
        let snapshot: ArcImportSnapshot
        switch read {
        case .success(let value): snapshot = value
        case .failure(let error):
            throw AutomationToolError(.invalidArguments, "The Arc folder could not be read: \(error.localizedDescription)")
        }
        // Choose… opens the Import from Arc window, which reads the same folder.
        ArcSidebarReader.dataDirectoryOverride.withLock { $0 = folder }
        guard let window = controller.window,
              ArcImportOfferSheetController.present(snapshot, over: controller, store: store) else {
            throw AutomationToolError(.invalidArguments, "The offer is already up, or the window is not visible")
        }
        for _ in 0..<40 where window.attachedSheet == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let sheet = window.attachedSheet else {
            throw AutomationToolError(.timeout, "The offer's sheet did not appear")
        }
        return placement(of: sheet)
    }

    private func openArcImport(_ arguments: ToolArguments) async throws -> [String: JSONValue] {
        let folder = try arcFolder(arguments)
        ArcSidebarReader.dataDirectoryOverride.withLock { $0 = folder }
        let controller = ArcImportWindowController.shared
        controller.present()
        guard let window = controller.window, window.isVisible else {
            throw AutomationToolError(.internalError, "The Import from Arc window did not open")
        }
        return placement(of: window)
    }

    private func openSettings(_ arguments: ToolArguments) async throws -> [String: JSONValue] {
        let pane = try arguments.requiredString("pane")
        let settings = SettingsWindowController.shared
        guard settings.showPane(named: pane) else {
            throw AutomationToolError(.invalidArguments, "pane is one of \(SettingsWindowController.paneNames.joined(separator: ", "))")
        }
        guard let window = settings.window else {
            throw AutomationToolError(.internalError, "The Settings window did not open")
        }
        // Shown a moment later, after its size animates to the pane.
        for _ in 0..<20 where Self.screenBounds(ofWindowNumber: window.windowNumber) == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let table = settings.visiblePaneTables.first
        if let row = try arguments.int("row") {
            guard let table else { throw AutomationToolError(.invalidArguments, "The \(pane) pane has no list") }
            guard (0..<table.numberOfRows).contains(row) else {
                throw AutomationToolError(.invalidArguments, "row is 0 to \(table.numberOfRows - 1) in the \(pane) pane")
            }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        var result = placement(of: window)
        result["rows"] = table.map { .int($0.numberOfRows) } ?? .null
        return result
    }
    #endif
}
