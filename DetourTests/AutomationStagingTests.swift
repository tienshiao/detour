import XCTest
import AppKit
import GRDB
@testable import Detour

/// Capture staging on the automation endpoint (TASK-228.3): seeding a demo
/// world from a fixture (the file format, a round trip through a relaunch,
/// the refusals), the displays and window placement, typing into a native
/// field at a pace, and the Debug-only UI on demand.
nonisolated final class AutomationStagingTests: XCTestCase {

    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []
    private var directories: [URL] = []

    @MainActor override func tearDown() async throws {
        for wc in windows {
            if wc.tabSidebar.isSpaceEditorOpen { wc.tabSidebar.endSpaceEditor(animated: false) }
            if let sheet = wc.window?.attachedSheet { wc.window?.endSheet(sheet) }
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for id in spaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        spaceIDs.removeAll()
        SettingsWindowController.shared.window?.close()
        ArcImportWindowController.shared.window?.close()
        ArcSidebarReader.dataDirectoryOverride.withLock { $0 = nil }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        try await super.tearDown()
    }

    // MARK: Helpers

    @MainActor private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    @MainActor private func write(_ text: String) throws -> String {
        let url = try temporaryDirectory().appending(path: "world.json")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @MainActor private func call(_ server: MCPServer, _ name: String, _ arguments: JSONValue = [:]) async throws
        -> (content: JSONValue, isError: Bool) {
        let tool = try XCTUnwrap(server.tools.first { $0.name == name }, name)
        let result = await server.call(tool, arguments: arguments)
        return (try XCTUnwrap(result["structuredContent"]), result["isError"] == true)
    }

    @MainActor private func errorCode(_ server: MCPServer, _ name: String, _ arguments: JSONValue) async throws -> String? {
        let (content, isError) = try await call(server, name, arguments)
        XCTAssertTrue(isError, "\(name) \(arguments.jsonString) should fail")
        return content["error"]?["code"]?.stringValue
    }

    // MARK: A store of its own, as a fresh data directory has it

    private struct World {
        let appDB: AppDatabase
        let historyDB: HistoryDatabase
        let store: TabStore
        let server: MCPServer
    }

    /// A fresh data directory's store: the Default profile and the Home
    /// space, as `ensureDefaultSpace` makes them at a first launch.
    @MainActor private func makeWorld(testRun: Bool = true) throws -> World {
        let appDB = try AppDatabase(dbQueue: try DatabaseQueue())
        var config = Configuration()
        config.foreignKeysEnabled = true
        let historyDB = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let store = TabStore(appDB: appDB, historyDB: historyDB)
        _ = store.restoreSession()
        store.ensureDefaultSpace()
        var environment = AutomationEnvironment(windowControllers: { [] }, mainMenu: { nil }, store: store)
        environment.isTestRun = testRun
        let tools = AutomationTools(environment: environment)
        return World(appDB: appDB, historyDB: historyDB, store: store,
                     server: MCPServer(tools: tools.all, serverVersion: "test", instructions: ""))
    }

    private static let fixture = """
        {
          "version": 1,
          "profiles": [
            {"name": "Work", "favorites": [
              {"url": "https://mail.example.com/", "title": "Mail"},
              {"url": "https://chat.example.com/", "title": "Chat", "favicon_url": "http://127.0.0.1:9/chat.png"}
            ]},
            {"name": "Personal", "favorites": [{"url": "https://news.example.com/", "title": "News"}]}
          ],
          "spaces": [
            {"name": "Desk", "emoji": "🍊", "color": "#ff7600", "profile": "Work",
             "pinned": [
               {"url": "https://docs.example.com/", "title": "Docs"},
               {"folder": "Design", "items": [
                 {"url": "https://a.example.com/", "title": "A"},
                 {"folder": "Deep", "collapsed": true, "items": [{"url": "https://b.example.com/", "title": "B"}]}
               ]},
               {"split": [{"url": "https://left.example.com/", "title": "Left"},
                          {"url": "https://right.example.com/", "title": "Right"}], "fraction": 0.4}
             ],
             "tabs": [
               {"url": "https://one.example.com/", "title": "One"},
               {"split": [{"url": "https://x.example.com/", "title": "X", "selected": true},
                          {"url": "https://y.example.com/"}]}
             ]},
            {"name": "Reading", "emoji": "📚", "color": "1FB6A8", "profile": "Personal",
             "tabs": [{"url": "https://read.example.com/", "title": "Read"}]}
          ],
          "history": [
            {"url": "https://old.example.com/", "title": "Old", "space": "Reading", "ago": ["2h", 86400]},
            {"url": "https://typed.example.com/", "space": "Desk", "ago": [60], "typed": true}
          ],
          "link_routes": [
            {"match": "domain_is", "pattern": "example.org", "target": "space:Reading"},
            {"source_app": "com.apple.TextEdit", "target": "quarantine"}
          ],
          "active_space": "Reading"
        }
        """

    // MARK: seed_world

    @MainActor func testASeededWorldMatchesTheFixtureAfterARelaunch() async throws {
        let world = try makeWorld()
        let seededAt = Date()
        let (content, isError) = try await call(world.server, "seed_world", ["fixture_path": .string(try write(Self.fixture))])
        XCTAssertFalse(isError, content.jsonString)
        XCTAssertEqual(content["counts"]?["spaces"], 2)
        XCTAssertEqual(content["counts"]?["pinned"], 5)
        XCTAssertEqual(content["counts"]?["history_visits"], 3)

        // The relaunch: a new store over the same databases.
        let relaunched = TabStore(appDB: world.appDB, historyDB: world.historyDB)
        let restored = relaunched.restoreSession()
        let spaces = relaunched.nonIncognitoSpaces
        XCTAssertEqual(spaces.map(\.name), ["Desk", "Reading"], "the data directory's Home space is gone")
        XCTAssertEqual(spaces.map(\.emoji), ["🍊", "📚"])
        XCTAssertEqual(spaces.map(\.colorHex), ["FF7600", "1FB6A8"])
        let desk = spaces[0], reading = spaces[1]
        XCTAssertEqual(restored?.spaceID, reading.id, "the active space")

        let profiles = relaunched.profiles.filter { !$0.isIncognito }
        XCTAssertEqual(profiles.map(\.name).sorted(), ["Personal", "Work"], "the default profile, renamed, and a new one")
        let work = try XCTUnwrap(profiles.first { $0.name == "Work" })
        let personal = try XCTUnwrap(profiles.first { $0.name == "Personal" })
        XCTAssertEqual(desk.profileID, work.id)
        XCTAssertEqual(reading.profileID, personal.id)
        XCTAssertEqual(work.favorites.map(\.title), ["Mail", "Chat"])
        XCTAssertEqual(work.favorites.map(\.faviconURL?.absoluteString),
                       ["https://mail.example.com/favicon.ico", "http://127.0.0.1:9/chat.png"])
        XCTAssertEqual(personal.favorites.map(\.title), ["News"])

        let rows: [String] = flattenPinnedTree(entries: desk.pinnedEntries, folders: desk.pinnedFolders,
                                               collapsedFolderIDs: [], selectedTabID: nil).map { item in
            switch item {
            case .entry(let entry, let depth): "\(depth):\(entry.pinnedTitle)"
            case .folder(let folder, let depth): "\(depth):[\(folder.name)]"
            case .split(_, let entries, let depth): "\(depth):split(\(entries.map(\.pinnedTitle).joined(separator: ",")))"
            }
        }
        XCTAssertEqual(rows, ["0:Docs", "0:[Design]", "1:A", "1:[Deep]", "2:B", "0:split(Left,Right)"])
        XCTAssertEqual(desk.pinnedFolders.first { $0.name == "Deep" }?.isCollapsed, true)
        XCTAssertEqual(desk.pinnedFolders.first { $0.name == "Design" }?.isCollapsed, false)
        XCTAssertEqual(desk.pinnedEntries.first { $0.pinnedTitle == "Left" }?.splitFraction, 0.4)

        XCTAssertEqual(desk.tabs.map(\.title), ["One", "X", "y.example.com"], "a missing title is the host")
        XCTAssertNotNil(desk.tabs[1].splitGroupID)
        XCTAssertEqual(desk.tabs[1].splitGroupID, desk.tabs[2].splitGroupID)
        XCTAssertEqual(desk.selectedTabID, desk.tabs[1].id, "the tab marked selected")
        XCTAssertEqual(reading.tabs.map(\.url?.absoluteString), ["https://read.example.com/"])

        let routes = relaunched.linkRoutes.routes
        XCTAssertEqual(routes.map(\.target), [.space(reading.id), .quarantine])
        XCTAssertEqual(routes.first?.match, LinkRouteMatch(kind: .domainIs, pattern: "example.org"))
        XCTAssertEqual(routes.last?.sourceApp, "com.apple.TextEdit")

        struct Visit: Sendable { var url: String, spaceID: String, time: Double, typed: Bool }
        let visits: [Visit] = try await world.historyDB.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.url, v.spaceID, v.visitTime, v.isTyped FROM historyVisit v JOIN historyURL u ON u.id = v.urlID
                ORDER BY v.visitTime
                """).map { Visit(url: $0["url"], spaceID: $0["spaceID"], time: $0["visitTime"], typed: $0["isTyped"]) }
        }
        XCTAssertEqual(visits.count, 3)
        let old = visits.filter { $0.url == "https://old.example.com/" }
        XCTAssertEqual(old.map(\.spaceID), [reading.id.uuidString, reading.id.uuidString])
        let ages = old.map { seededAt.timeIntervalSince1970 - $0.time }.sorted()
        XCTAssertEqual(ages[0], 7200, accuracy: 30, "visit times are relative to now")
        XCTAssertEqual(ages[1], 86400, accuracy: 30)
        let typed = try XCTUnwrap(visits.first { $0.url == "https://typed.example.com/" })
        XCTAssertTrue(typed.typed)
        XCTAssertEqual(typed.spaceID, desk.id.uuidString)
    }

    @MainActor func testAMalformedFixtureIsRefusedAndChangesNothing() async throws {
        let world = try makeWorld()
        // Valid up to a late field, so a half-applied seed would show.
        let broken = Self.fixture.replacingOccurrences(of: "\"target\": \"quarantine\"", with: "\"target\": \"elsewhere\"")
        let (content, isError) = try await call(world.server, "seed_world", ["fixture_path": .string(try write(broken))])
        XCTAssertTrue(isError)
        XCTAssertEqual(content["error"]?["code"], "invalid_fixture")
        XCTAssertEqual(content["error"]?["details"]?["path"], "link_routes[1].target")
        XCTAssertEqual(world.store.nonIncognitoSpaces.map(\.name), ["Home"])
        XCTAssertEqual(world.store.profiles.filter { !$0.isIncognito }.map(\.name), ["Default"])
        XCTAssertTrue(world.store.linkRoutes.routes.isEmpty)

        let notJSON = try await errorCode(world.server, "seed_world", ["fixture_path": .string(try write("{nope"))])
        XCTAssertEqual(notJSON, "invalid_fixture")
        let missing = try await errorCode(world.server, "seed_world", ["fixture_path": "/nonexistent/world.json"])
        XCTAssertEqual(missing, "invalid_arguments")
        let relative = try await errorCode(world.server, "seed_world", ["fixture_path": "world.json"])
        XCTAssertEqual(relative, "invalid_arguments")
    }

    @MainActor func testSeedingIsRefusedOutsideATestRun() async throws {
        let world = try makeWorld(testRun: false)
        let code = try await errorCode(world.server, "seed_world", ["fixture_path": .string(try write(Self.fixture))])
        XCTAssertEqual(code, "gate_closed")
        XCTAssertEqual(world.store.nonIncognitoSpaces.map(\.name), ["Home"])
    }

    @MainActor func testSeedingIsRefusedWhenTheDataDirectoryIsNotEmpty() async throws {
        let world = try makeWorld()
        let home = try XCTUnwrap(world.store.nonIncognitoSpaces.first)
        world.store.pinURL(URL(string: "https://kept.example.com/")!, title: "Kept", faviconURL: nil, in: home)
        let (content, isError) = try await call(world.server, "seed_world", ["fixture_path": .string(try write(Self.fixture))])
        XCTAssertTrue(isError)
        XCTAssertEqual(content["error"]?["code"], "not_empty")
        XCTAssertEqual(content["error"]?["details"], ["1 pinned entries"])
        XCTAssertEqual(world.store.nonIncognitoSpaces.map(\.name), ["Home"])

        // A seeded world is not empty either: seeding twice is refused.
        let fresh = try makeWorld()
        _ = try await call(fresh.server, "seed_world", ["fixture_path": .string(try write(Self.fixture))])
        let again = try await errorCode(fresh.server, "seed_world", ["fixture_path": .string(try write(Self.fixture))])
        XCTAssertEqual(again, "not_empty")
    }

    @MainActor func testFixtureProblemsNameTheField() throws {
        func problem(_ text: String) -> AutomationWorldFixture.Problem? {
            do {
                _ = try AutomationWorldFixture.plan(from: Data(text.utf8), defaultProfileID: UUID())
                return nil
            } catch {
                return error
            }
        }
        let space = #"{"name": "S", "emoji": "S", "color": "112233", "profile": "P""#
        func world(_ spaceExtra: String = "", top: String = "") -> String {
            #"{"profiles": [{"name": "P"}], "spaces": [\#(space)\#(spaceExtra)}]\#(top)}"#
        }
        XCTAssertNil(problem(world()), "a minimal world is fine")
        let cases: [(String, String)] = [
            (#"{"version": 2, "profiles": [], "spaces": []}"#, "version"),
            (#"{"spaces": []}"#, "profiles"),
            (#"{"profiles": [{"name": "P"}], "spaces": []}"#, "spaces"),
            (#"{"profiles": [{"name": "P"}, {"name": "p"}], "spaces": [\#(space)}]}"#, "profiles[1].name"),
            (#"{"profiles": [{"name": "Private"}], "spaces": [\#(space)}]}"#, "profiles[0].name"),
            (#"{"profiles": [{"name": "P", "colour": 1}], "spaces": [\#(space)}]}"#, "profiles[0].colour"),
            (#"{"profiles": [{"name": "P"}], "spaces": [{"name": "S", "emoji": "S", "color": "1122", "profile": "P"}]}"#,
             "spaces[0].color"),
            (#"{"profiles": [{"name": "P"}], "spaces": [{"name": "S", "emoji": "S", "color": "112233", "profile": "Q"}]}"#,
             "spaces[0].profile"),
            (#"{"profiles": [{"name": "P"}], "spaces": [\#(space)}, \#(space)}]}"#, "spaces[1].name"),
            (world(#", "tabs": [{"url": "ftp://x.example.com/"}]"#), "spaces[0].tabs[0].url"),
            (world(#", "tabs": [{"title": "no url"}]"#), "spaces[0].tabs[0].url"),
            (world(#", "tabs": [{"split": [{"url": "https://a.example.com/"}]}]"#), "spaces[0].tabs[0].split"),
            (world(#", "tabs": [{"split": [{"url": "https://a.example.com/"}, {"url": "https://b.example.com/"}], "fraction": 2}]"#),
             "spaces[0].tabs[0].fraction"),
            (world(#", "tabs": [{"url": "https://a.example.com/", "selected": true}, {"url": "https://b.example.com/", "selected": true}]"#),
             "spaces[0].tabs[1]"),
            (world(#", "pinned": [{"folder": "F", "items": [{"url": "nope"}]}]"#), "spaces[0].pinned[0].items[0].url"),
            (world(#", "pinned": [{"url": "https://a.example.com/", "selected": true}]"#), "spaces[0].pinned[0].selected"),
            (world(top: #", "history": [{"url": "https://a.example.com/", "space": "S", "ago": ["3 days"]}]"#),
             "history[0].ago[0]"),
            (world(top: #", "history": [{"url": "https://a.example.com/", "space": "S", "ago": ["100d"]}]"#),
             "history[0].ago[0]"),
            (world(top: #", "history": [{"url": "https://a.example.com/", "space": "T", "ago": [1]}]"#), "history[0].space"),
            (world(top: #", "link_routes": [{"target": "space:S"}]"#), "link_routes[0]"),
            (world(top: #", "link_routes": [{"match": "domain_is", "pattern": "a b", "target": "space:S"}]"#), "link_routes[0]"),
            (world(top: #", "link_routes": [{"match": "starts_with", "pattern": "a", "target": "space:S"}]"#),
             "link_routes[0].match"),
            (world(top: #", "link_routes": [{"source_app": "x", "target": "space:T"}]"#), "link_routes[0].target"),
            (world(top: #", "active_space": "T""#), "active_space"),
            (world(top: #", "extra": 1"#), "extra"),
        ]
        for (text, path) in cases {
            XCTAssertEqual(problem(text)?.path, path, text)
        }
        XCTAssertEqual(problem("[1]")?.path, "")
        XCTAssertNotNil(problem("not json"))
    }

    @MainActor func testFoldersAndSplitsTakeConsecutiveSortOrdersPerLevel() throws {
        let text = #"""
            {"profiles": [{"name": "P"}], "spaces": [{"name": "S", "emoji": "S", "color": "112233", "profile": "P",
              "pinned": [{"url": "https://a.example.com/"}, {"folder": "F", "items": [{"url": "https://b.example.com/"}]},
                         {"split": [{"url": "https://c.example.com/"}, {"url": "https://d.example.com/"}]}]}]}
            """#
        let profileID = UUID()
        let plan = try AutomationWorldFixture.plan(from: Data(text.utf8), defaultProfileID: profileID)
        XCTAssertEqual(plan.defaultProfileName, "P")
        XCTAssertTrue(plan.world.profiles.isEmpty, "the first profile is the existing one")
        XCTAssertEqual(plan.world.spaces.first?.profileID, profileID)
        let folder = try XCTUnwrap(plan.world.folders.first)
        XCTAssertEqual(folder.sortOrder, 1)
        let top = plan.world.pinnedEntries.filter { $0.folderID == nil }
        XCTAssertEqual(top.map(\.sortOrder), [0, 2, 3], "a folder takes a place among the entries")
        XCTAssertEqual(top[1].splitGroupID, top[2].splitGroupID)
        XCTAssertNotNil(top[1].splitGroupID)
        XCTAssertEqual(plan.world.pinnedEntries.first { $0.folderID == folder.id }?.sortOrder, 0)
        XCTAssertEqual(plan.activeSpaceID, plan.world.spaces[0].id, "the first space by default")
    }

    @MainActor func testATestRunIsRequestedOnlyWithAnIsolatedDataDirectory() {
        XCTAssertTrue(AutomationGate.isTestRunRequested(environment: ["DETOUR_MCP": "1", "DETOUR_DATA_DIR": "DetourCapture"]))
        XCTAssertTrue(AutomationGate.isTestRunRequested(environment: ["DETOUR_MCP": "1", "DETOUR_DATA_DIR": "X",
                                                                      "DETOUR_MCP_PORT": "bad"]),
                      "a bad port still keeps the run off the user's Arc folder")
        XCTAssertFalse(AutomationGate.isTestRunRequested(environment: ["DETOUR_MCP": "1"]))
        XCTAssertFalse(AutomationGate.isTestRunRequested(environment: ["DETOUR_MCP": "1", "DETOUR_DATA_DIR": "Detour"]))
        XCTAssertFalse(AutomationGate.isTestRunRequested(environment: ["DETOUR_DATA_DIR": "DetourCapture"]))
    }

    @MainActor func testTheArcReaderFollowsTheOverride() throws {
        XCTAssertEqual(ArcSidebarReader.defaultDataDirectory, ArcSidebarReader.userDataDirectory)
        let folder = try temporaryDirectory()
        ArcSidebarReader.dataDirectoryOverride.withLock { $0 = folder }
        XCTAssertEqual(ArcSidebarReader.defaultDataDirectory, folder)
        XCTAssertFalse(ArcSidebarReader.isArcDataPresent(), "the fixture folder, not the user's")
    }

    // MARK: Windows on TabStore.shared

    private struct Stage {
        let server: MCPServer
        let window: BrowserWindowController
        let windowID: Int
    }

    @MainActor private func makeStage(testRun: Bool = true) throws -> Stage {
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Automation Staging", emoji: "S", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        var environment = AutomationEnvironment(windowControllers: { [wc] }, mainMenu: { nil }, store: store)
        environment.isTestRun = testRun
        let tools = AutomationTools(environment: environment)
        return Stage(server: MCPServer(tools: tools.all, serverVersion: "test", instructions: ""),
                     window: wc, windowID: tools.windowIDs.id(for: wc))
    }

    @MainActor func testDisplaysAreListedInTopLeftPoints() async throws {
        let stage = try makeStage()
        let (content, isError) = try await call(stage.server, "list_displays")
        XCTAssertFalse(isError)
        let displays = try XCTUnwrap(content["displays"]?.arrayValue)
        XCTAssertEqual(displays.count, NSScreen.screens.count)
        let main = try XCTUnwrap(displays.first { $0["main"] == true })
        XCTAssertEqual(main["frame"]?["x"]?.doubleValue, 0)
        XCTAssertEqual(main["frame"]?["y"]?.doubleValue, 0, "the main display is the origin of global coordinates")
        XCTAssertEqual(main["display_id"]?.intValue, Int(CGMainDisplayID()))
        XCTAssertNotNil(main["scale"]?.doubleValue)
    }

    @MainActor func testAWindowIsPlacedOnADisplayAndReadBack() async throws {
        let stage = try makeStage()
        let main = Int(CGMainDisplayID())
        let (content, isError) = try await call(stage.server, "set_window_frame", [
            "window_id": .int(stage.windowID), "x": 40, "y": 60, "width": 700, "height": 480, "display_id": .int(main),
        ])
        XCTAssertFalse(isError, content.jsonString)
        let expected: JSONValue = ["x": .double(40), "y": .double(60), "width": .double(700), "height": .double(480)]
        XCTAssertEqual(content["frame"], expected)
        XCTAssertEqual(content["screen_bounds"], expected, "the window server's own bounds agree once settled")
        XCTAssertEqual(content["settled"], true)
        XCTAssertEqual(content["window_number"]?.intValue, stage.window.window?.windowNumber)
        XCTAssertEqual(content["window_id"]?.intValue, stage.windowID)
        XCTAssertEqual(content["display_id"]?.intValue, main)
        XCTAssertNotNil(content["is_key"]?.boolValue)
        XCTAssertNotNil(content["app_active"]?.boolValue)

        // list_windows says the same, and by window_number reaches the same window.
        let listed = try await call(stage.server, "list_windows")
        XCTAssertEqual(listed.content["windows"]?.arrayValue?.first?["screen_bounds"], expected)
        let number = try XCTUnwrap(stage.window.window?.windowNumber)
        let moved = try await call(stage.server, "set_window_frame", [
            "window_number": .int(number), "x": 50, "y": 70, "width": 700, "height": 480,
        ])
        XCTAssertEqual(moved.content["frame"]?["x"]?.doubleValue, 50)
    }

    @MainActor func testWindowPlacementErrors() async throws {
        let closed = try makeStage(testRun: false)
        let before = closed.window.window?.frame
        let gate = try await errorCode(closed.server, "set_window_frame", [
            "window_id": .int(closed.windowID), "x": 0, "y": 0, "width": 400, "height": 300, "activate": true,
        ])
        XCTAssertEqual(gate, "gate_closed", "the user's own endpoint never moves windows or takes the front")
        XCTAssertEqual(closed.window.window?.frame, before)

        let stage = try makeStage()
        let frame: [String: JSONValue] = ["x": 0, "y": 0, "width": 400, "height": 300]
        func with(_ extra: [String: JSONValue]) -> JSONValue { .object(frame.merging(extra) { $1 }) }
        let unknownWindow = try await errorCode(stage.server, "set_window_frame", with(["window_id": 99]))
        XCTAssertEqual(unknownWindow, "unknown_window")
        let unknownNumber = try await errorCode(stage.server, "set_window_frame", with(["window_number": 987_654_321]))
        XCTAssertEqual(unknownNumber, "unknown_window")
        let unknownDisplay = try await errorCode(stage.server, "set_window_frame",
                                                 with(["window_id": .int(stage.windowID), "display_id": 424_242]))
        XCTAssertEqual(unknownDisplay, "unknown_display")
        let neither = try await errorCode(stage.server, "set_window_frame", .object(frame))
        XCTAssertEqual(neither, "invalid_arguments")
        let both = try await errorCode(stage.server, "set_window_frame",
                                       with(["window_id": .int(stage.windowID), "window_number": 1]))
        XCTAssertEqual(both, "invalid_arguments")
        let empty = try await errorCode(stage.server, "set_window_frame",
                                        .object(frame.merging(["window_id": .int(stage.windowID), "width": 0]) { $1 }))
        XCTAssertEqual(empty, "invalid_arguments")
    }

    // MARK: open_ui (Debug) and typing at a pace

    @MainActor func testOpenUIExistsOnlyInDebugBuilds() throws {
        let tools = AutomationTools(environment: AutomationEnvironment(windowControllers: { [] }, mainMenu: { nil },
                                                                       store: .shared))
        let names = tools.all.map(\.name)
        XCTAssertTrue(names.contains("seed_world") && names.contains("list_displays") && names.contains("set_window_frame"))
        #if DEBUG
        XCTAssertTrue(names.contains("open_ui"))
        #else
        XCTAssertFalse(names.contains("open_ui"))
        #endif
    }

    #if DEBUG
    @MainActor func testTheSpaceEditorOpensWithADraftAndTakesPacedTyping() async throws {
        let stage = try makeStage()
        let profile = try XCTUnwrap(TabStore.shared.profiles.first { !$0.isIncognito })
        let (content, isError) = try await call(stage.server, "open_ui", [
            "what": "space_editor", "window_id": .int(stage.windowID), "name": "Tri", "emoji": "🚀",
            "color": "#2f6fdb", "profile_id": .string(profile.id.uuidString),
        ])
        XCTAssertFalse(isError, content.jsonString)
        XCTAssertTrue(stage.window.tabSidebar.isSpaceEditorOpen)
        XCTAssertEqual(content["draft"]?["color"], "2F6FDB")
        XCTAssertEqual(content["window_number"]?.intValue, stage.window.window?.windowNumber)
        let field = try XCTUnwrap(stage.window.window?.firstResponder as? NSTextView, "the name field has focus")
        XCTAssertEqual(field.string, "Tri")

        let started = ContinuousClock.now
        // The editor selects the name when it takes focus, so typing replaces it.
        let typed = try await call(stage.server, "type_text", ["window_id": .int(stage.windowID), "text": "Trips!",
                                                               "interval_ms": 80])
        let elapsed = ContinuousClock.now - started
        XCTAssertFalse(typed.isError, typed.content.jsonString)
        XCTAssertEqual(field.string, "Trips!")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(400), "the characters are paced")
        XCTAssertEqual(TabStore.shared.spaces.filter { $0.name == "Trips!" }.count, 0, "nothing is created by typing")
    }

    @MainActor func testOpenUIErrors() async throws {
        let stage = try makeStage()
        let id = JSONValue.int(stage.windowID)
        let cases: [(JSONValue, String)] = [
            (["what": "nothing"], "invalid_arguments"),
            (["what": "space_editor", "window_id": id, "pane": "spaces"], "invalid_arguments"),
            (["what": "space_editor", "window_id": 99], "unknown_window"),
            (["what": "space_editor", "window_id": id, "color": "blue"], "invalid_arguments"),
            (["what": "space_editor", "window_id": id, "profile_id": .string(UUID().uuidString)], "unknown_profile"),
            (["what": "space_editor", "window_id": id, "space_id": .string(UUID().uuidString)], "unknown_space"),
            (["what": "settings", "pane": "nowhere"], "invalid_arguments"),
            (["what": "arc_offer", "window_id": id, "arc_folder": "/tmp"], "invalid_arguments"),
            (["what": "arc_import", "arc_folder": "tmp"], "invalid_arguments"),
        ]
        for (arguments, code) in cases {
            let got = try await errorCode(stage.server, "open_ui", arguments)
            XCTAssertEqual(got, code, arguments.jsonString)
        }
        XCTAssertFalse(stage.window.tabSidebar.isSpaceEditorOpen, "nothing opened on a refusal")
    }

    @MainActor func testStagingIsRefusedOutsideATestRun() async throws {
        let stage = try makeStage(testRun: false)
        let id = JSONValue.int(stage.windowID)
        let editor = try await errorCode(stage.server, "open_ui", ["what": "space_editor", "window_id": id])
        XCTAssertEqual(editor, "gate_closed")
        let settings = try await errorCode(stage.server, "open_ui", ["what": "settings", "pane": "general"])
        XCTAssertEqual(settings, "gate_closed")
        XCTAssertFalse(stage.window.tabSidebar.isSpaceEditorOpen)
    }

    @MainActor func testTheArcOfferReadsOnlyAFixtureFolder() async throws {
        let stage = try makeStage()
        let id = JSONValue.int(stage.windowID)
        let empty = try temporaryDirectory()
        let outside = try await errorCode(stage.server, "open_ui", [
            "what": "arc_offer", "window_id": id,
            "arc_folder": .string(FileManager.default.homeDirectoryForCurrentUser.path),
        ])
        XCTAssertEqual(outside, "invalid_arguments", "a folder outside the data directory and the temporary ones")
        let real = try await errorCode(stage.server, "open_ui", [
            "what": "arc_import", "arc_folder": .string(ArcSidebarReader.userDataDirectory.path),
        ])
        XCTAssertEqual(real, "invalid_arguments", "never Arc's own folder")
        let noSidebar = try await errorCode(stage.server, "open_ui", [
            "what": "arc_offer", "window_id": id, "arc_folder": .string(empty.path),
        ])
        XCTAssertEqual(noSidebar, "invalid_arguments")
        XCTAssertEqual(ArcSidebarReader.defaultDataDirectory, ArcSidebarReader.userDataDirectory,
                       "a refusal points nothing anywhere")

        let folder = try temporaryDirectory()
        try Data(Self.arcSidebar.utf8).write(to: folder.appending(path: "StorableSidebar.json"))
        let (content, isError) = try await call(stage.server, "open_ui", [
            "what": "arc_offer", "window_id": id, "arc_folder": .string(folder.path),
        ])
        XCTAssertFalse(isError, content.jsonString)
        let sheet = try XCTUnwrap(stage.window.window?.attachedSheet)
        XCTAssertEqual(content["window_number"]?.intValue, sheet.windowNumber)
        XCTAssertEqual(ArcSidebarReader.defaultDataDirectory.standardizedFileURL.resolvingSymlinksInPath(),
                       folder.standardizedFileURL.resolvingSymlinksInPath(),
                       "Choose… goes on reading the fixture")
    }

    @MainActor func testASettingsPaneOpensWithARowSelected() async throws {
        let stage = try makeStage()
        let (content, isError) = try await call(stage.server, "open_ui", ["what": "settings", "pane": "spaces", "row": 0])
        XCTAssertFalse(isError, content.jsonString)
        let settings = SettingsWindowController.shared
        XCTAssertEqual(content["window_number"]?.intValue, settings.window?.windowNumber)
        let table = try XCTUnwrap(settings.visiblePaneTables.first)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(content["rows"]?.intValue, table.numberOfRows)
        let beyond = try await errorCode(stage.server, "open_ui", ["what": "settings", "pane": "spaces",
                                                                   "row": .int(table.numberOfRows)])
        XCTAssertEqual(beyond, "invalid_arguments")
    }

    /// One Arc space with one pinned tab, in Arc's sidebar format.
    private static let arcSidebar = #"""
        {"version": 1, "sidebar": {"containers": [{"global": {}}, {
          "spaces": ["S", {"id": "S", "title": "Work", "profile": {"default": true},
                           "customInfo": {"iconType": {"emoji_v2": "💼", "emoji": 128188}},
                           "containerIDs": ["unpinned", "S-U", "pinned", "S-P"],
                           "newContainerIDs": [{"pinned": {}}, "S-P", {"unpinned": {"_0": {"shared": {}}}}, "S-U"]}],
          "items": [
            "S-P", {"id": "S-P", "parentID": null, "childrenIds": ["T1"],
                    "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "S"}}}}},
            "T1", {"id": "T1", "parentID": "S-P", "childrenIds": [], "title": null,
                   "data": {"tab": {"savedURL": "https://a.example.com/", "savedTitle": "A"}}},
            "S-U", {"id": "S-U", "parentID": null, "childrenIds": [],
                    "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "S"}}}}}
          ],
          "topAppsContainerIDs": []}]}}
        """#
    #endif
}
