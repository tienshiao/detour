import WebKit
import XCTest
@testable import Detour

/// TASK-405/408: the endpoint's gpu_process_stats and trim_back_forward_cache.
nonisolated final class AutomationGPUToolsTests: XCTestCase {

    private var spaceIDs: [UUID] = []

    @MainActor override func tearDown() async throws {
        for id in spaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        spaceIDs.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        try await super.tearDown()
    }

    @MainActor private func makeServer(allowsPrivate: Bool = false) -> MCPServer {
        var environment = AutomationEnvironment(windowControllers: { [] }, mainMenu: { nil }, store: .shared)
        environment.allowsPrivate = { allowsPrivate }
        let tools = AutomationTools(environment: environment)
        return MCPServer(tools: tools.all, serverVersion: "test", instructions: "")
    }

    @MainActor private func call(_ server: MCPServer, _ name: String, _ arguments: JSONValue = [:]) async throws
        -> (content: JSONValue, isError: Bool) {
        let tool = try XCTUnwrap(server.tools.first { $0.name == name }, name)
        let result = await server.call(tool, arguments: arguments)
        return (try XCTUnwrap(result["structuredContent"]), result["isError"] == true)
    }

    /// Two live tabs in a space of their own; neither is hosted by a window.
    @MainActor private func makeTabs() throws -> (BrowserTab, BrowserTab) {
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "GPU tools", emoji: "G", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        return (store.addTab(in: space), store.addTab(in: space))
    }

    @MainActor private func entry(_ content: JSONValue, tab: BrowserTab) -> JSONValue? {
        content["tabs"]?.arrayValue?.first { $0["tab_id"]?.stringValue == tab.id.uuidString }
    }

    @MainActor func testBothToolsAreAlwaysListed() {
        let names = makeServer().tools.map(\.name)
        XCTAssertTrue(names.contains("gpu_process_stats"))
        XCTAssertTrue(names.contains("trim_back_forward_cache"))
    }

    @MainActor func testStatsPlaceEveryLiveTabInAPool() async throws {
        let (first, second) = try makeTabs()
        let (content, isError) = try await call(makeServer(), "gpu_process_stats", ["detail": true])
        XCTAssertFalse(isError, content.jsonString)

        let pools = try XCTUnwrap(content["process_pools"]?.arrayValue)
        let firstPool = try XCTUnwrap(entry(content, tab: first)?["pool"]?.intValue)
        let secondPool = try XCTUnwrap(entry(content, tab: second)?["pool"]?.intValue)
        XCTAssertTrue(pools.indices.contains(firstPool) && pools.indices.contains(secondPool))
        // What TASK-405 measured: a fresh configuration brings its own pool.
        XCTAssertNotEqual(firstPool, secondPool, "each tab's configuration has a WKProcessPool of its own")
        XCTAssertEqual(pools[firstPool]["tab_web_views"]?.intValue, 1)

        let liveViews = TabStore.shared.allLiveTabs.compactMap(\.webView).count
        XCTAssertEqual(content["live_web_views"]?.intValue, liveViews)
        XCTAssertLessThanOrEqual(content["tab_processes"]?.intValue ?? .max, liveViews)
        XCTAssertNotNil(content["tab_process_footprint_mb"]?.intValue)
        // gpu_pid and the counts are null together when no GPU process runs.
        XCTAssertEqual(content["gpu_pid"] == .null, content["total"] == .null)
    }

    @MainActor func testWithoutDetailThereIsNoTabList() async throws {
        _ = try makeTabs()
        let (content, isError) = try await call(makeServer(), "gpu_process_stats")
        XCTAssertFalse(isError)
        XCTAssertNil(content["tabs"])
    }

    @MainActor func testASleepingTabHasNoPool() async throws {
        let (first, _) = try makeTabs()
        first.sleep(force: true)
        let (content, _) = try await call(makeServer(), "gpu_process_stats", ["detail": true])
        XCTAssertEqual(entry(content, tab: first)?["asleep"], true)
        XCTAssertEqual(entry(content, tab: first)?["pool"], .null)
        XCTAssertEqual(entry(content, tab: first)?["web_process"], .null)
    }

    @MainActor func testTrimTakesOneTabOrEveryHiddenOne() async throws {
        let (first, second) = try makeTabs()
        let server = makeServer()

        let (one, oneError) = try await call(server, "trim_back_forward_cache",
                                             ["context": .string(first.id.uuidString)])
        XCTAssertFalse(oneError, one.jsonString)
        XCTAssertEqual(one["trimmed"], [.string(first.id.uuidString)])

        let (all, _) = try await call(server, "trim_back_forward_cache")
        let trimmed = Set(all["trimmed"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        XCTAssertTrue(trimmed.isSuperset(of: [first.id.uuidString, second.id.uuidString]),
                      "no window hosts either tab, so both are hidden")
    }

    @MainActor func testTrimSkipsASleepingTab() async throws {
        let (first, _) = try makeTabs()
        first.sleep(force: true)
        let (content, isError) = try await call(makeServer(), "trim_back_forward_cache",
                                                ["context": .string(first.id.uuidString)])
        XCTAssertFalse(isError)
        XCTAssertEqual(content["trimmed"], [])
        XCTAssertFalse(first.clearBackForwardCache(), "nothing to clear without a web view")
    }

    @MainActor func testTrimRefusesAnUnknownTab() async throws {
        let (content, isError) = try await call(makeServer(), "trim_back_forward_cache",
                                                ["context": .string(UUID().uuidString)])
        XCTAssertTrue(isError)
        XCTAssertNotNil(content["error"]?["code"]?.stringValue)
    }

    @MainActor func testPrivateTabsNeedPrivateAccess() async throws {
        let space = TabStore.shared.addIncognitoSpace()
        spaceIDs.append(space.id)
        let tab = TabStore.shared.addTab(in: space)

        let (closed, _) = try await call(makeServer(), "gpu_process_stats", ["detail": true])
        XCTAssertNil(entry(closed, tab: tab), "a Private tab is listed only with Private access")
        let (trimmedClosed, _) = try await call(makeServer(), "trim_back_forward_cache")
        XCTAssertFalse(trimmedClosed["trimmed"]?.arrayValue?.contains(.string(tab.id.uuidString)) ?? true)

        let (open, _) = try await call(makeServer(allowsPrivate: true), "gpu_process_stats", ["detail": true])
        XCTAssertNotNil(entry(open, tab: tab))
        let (trimmedOpen, _) = try await call(makeServer(allowsPrivate: true), "trim_back_forward_cache")
        XCTAssertTrue(trimmedOpen["trimmed"]?.arrayValue?.contains(.string(tab.id.uuidString)) ?? false)
    }
}
