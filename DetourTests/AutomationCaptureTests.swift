import XCTest
import AppKit
import WebKit
@testable import Detour

/// Screenshots, appearance and Debug overrides of the automation endpoint
/// (TASK-228.1 phase 3, AC #4, #8, #16): PNGs of a window, its sidebar and a
/// page, returned as image content and written to save_to; light and dark;
/// the Reduce Motion and space toss overrides; and their errors.
nonisolated final class AutomationCaptureTests: XCTestCase {

    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var directories: [URL] = []

    @MainActor override func tearDown() async throws {
        NSApp.appearance = nil
        #if DEBUG
        MotionPreference.reduceMotionOverride = nil
        UserDefaultsScope.defaults.removeObject(forKey: AutomationTools.spaceTossHopKey)
        UserDefaultsScope.defaults.removeObject(forKey: AutomationTools.spaceTossGravityKey)
        #endif
        for wc in windows {
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
        for server in servers { server.stop() }
        servers.removeAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        try await super.tearDown()
    }

    private struct Fixture {
        let server: MCPServer
        let window: BrowserWindowController
        let windowID: Int
        let tab: BrowserTab
    }

    @MainActor private func makeFixture() async throws -> Fixture {
        let http = try LoopbackHTTPServer(routes: ["/": "<title>Capture</title><body style='background:#123456'>Hi</body>"])
        servers.append(http)
        let port = try await http.start()
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Automation Capture", emoji: "C", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        let tab = store.addTab(in: space, url: URL(string: "http://127.0.0.1:\(port)/")!)
        wc.selectTab(id: tab.id)
        try await waitUntil("the page to load") { tab.webView?.title == "Capture" && !tab.isLoading }
        let tools = AutomationTools(environment: AutomationEnvironment(windowControllers: { [wc] }, mainMenu: { nil },
                                                                       store: store))
        let server = MCPServer(tools: tools.all, serverVersion: "test", instructions: "")
        return Fixture(server: server, window: wc, windowID: tools.windowIDs.id(for: wc), tab: tab)
    }

    /// The whole tool result, as a client gets it.
    @MainActor private func result(_ f: Fixture, _ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let tool = try XCTUnwrap(f.server.tools.first { $0.name == name }, name)
        return await f.server.call(tool, arguments: arguments)
    }

    @MainActor private func errorCode(_ f: Fixture, _ name: String, _ arguments: JSONValue) async throws -> String? {
        let reply = try await result(f, name, arguments)
        XCTAssertEqual(reply["isError"], true, "\(name) \(arguments.jsonString) should fail")
        return reply["structuredContent"]?["error"]?["code"]?.stringValue
    }

    /// The PNG in a result's image content.
    private func image(in reply: JSONValue) throws -> NSBitmapImageRep {
        let block = try XCTUnwrap(reply["content"]?.arrayValue?.first { $0["type"] == "image" }, "no image content")
        XCTAssertEqual(block["mimeType"], "image/png")
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(block["data"]?.stringValue)))
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    // MARK: screenshot

    @MainActor func testAWindowScreenshotIsAPNGOfItsContentReturnedAndSaved() async throws {
        let f = try await makeFixture()
        let content = try XCTUnwrap(f.window.window?.contentView)
        let path = try temporaryDirectory().appendingPathComponent("window.png").path
        let reply = try await result(f, "screenshot", ["window_id": .int(f.windowID), "save_to": .string(path)])
        XCTAssertEqual(reply["isError"], false, reply.jsonString.prefix(300).description)
        let structured = try XCTUnwrap(reply["structuredContent"])
        XCTAssertEqual(structured["width"], .int(Int(content.bounds.width.rounded())))
        XCTAssertEqual(structured["height"], .int(Int(content.bounds.height.rounded())))
        XCTAssertEqual(structured["saved_to"], .string(path))
        let png = try image(in: reply)
        XCTAssertEqual(png.pixelsWide, Int(content.bounds.width.rounded()), "scale 1 by default")
        let saved = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertEqual(saved.pixelsWide, png.pixelsWide)
        XCTAssertEqual(structured["bytes"], .int(try Data(contentsOf: URL(fileURLWithPath: path)).count))
        XCTAssertEqual(reply["content"]?.arrayValue?.first?["type"], "text", "the structured JSON comes first, as text")
    }

    @MainActor func testScaleTwoNeverUpsamplesAndIncludeImageFalseSendsNone() async throws {
        let f = try await makeFixture()
        let reply = try await result(f, "screenshot", ["window_id": .int(f.windowID), "scale": 2, "include_image": false])
        XCTAssertEqual(reply["isError"], false)
        let structured = try XCTUnwrap(reply["structuredContent"])
        let backing = Int(try XCTUnwrap(f.window.window).backingScaleFactor)
        XCTAssertEqual(structured["scale"]?.intValue, min(2, backing), "at most the display's own pixels")
        XCTAssertEqual(structured["pixel_width"]?.intValue, (structured["width"]?.intValue ?? 0) * min(2, backing))
        XCTAssertNil(reply["content"]?.arrayValue?.first { $0["type"] == "image" })
    }

    @MainActor func testAnExistingFileIsReplacedOnlyWithOverwrite() async throws {
        let f = try await makeFixture()
        let path = try temporaryDirectory().appendingPathComponent("existing.png").path
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        let refused = try await errorCode(f, "screenshot", ["window_id": .int(f.windowID), "save_to": .string(path)])
        XCTAssertEqual(refused, "invalid_arguments")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("keep".utf8), "the file is untouched")
        let replaced = try await result(f, "screenshot", ["window_id": .int(f.windowID), "save_to": .string(path),
                                                          "overwrite": true, "include_image": false])
        XCTAssertEqual(replaced["isError"], false)
        XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
    }

    @MainActor func testTheSidebarAndAPageCanBeTakenAlone() async throws {
        let f = try await makeFixture()
        let sidebar = try await result(f, "screenshot", ["window_id": .int(f.windowID), "part": "sidebar"])
        XCTAssertEqual(sidebar["isError"], false, sidebar["structuredContent"]?.jsonString ?? "")
        XCTAssertEqual(sidebar["structuredContent"]?["width"], .int(Int(f.window.tabSidebar.view.bounds.width.rounded())))

        let page = try await result(f, "screenshot", ["context": .string(f.tab.id.uuidString)])
        XCTAssertEqual(page["isError"], false, page["structuredContent"]?.jsonString ?? "")
        let webView = try XCTUnwrap(f.tab.webView)
        XCTAssertEqual(page["structuredContent"]?["width"], .int(Int(webView.bounds.width.rounded())))
        // The page's background, from WebKit's own snapshot.
        let png = try image(in: page)
        let colour = try XCTUnwrap(png.colorAt(x: png.pixelsWide / 2, y: png.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        // #123456, give or take the display's colour profile: dark, blue over green over red.
        XCTAssertGreaterThan(colour.blueComponent, colour.greenComponent)
        XCTAssertGreaterThan(colour.greenComponent, colour.redComponent)
        XCTAssertLessThan(colour.blueComponent, 0.6)
    }

    @MainActor func testTheWindowServersPictureNeedsScreenRecordingAndAWholeWindow() async throws {
        let f = try await makeFixture()
        let reply = try await result(f, "screenshot", ["window_id": .int(f.windowID), "source": "screen",
                                                       "include_image": false])
        if CGPreflightScreenCaptureAccess() {
            XCTAssertEqual(reply["isError"], false, reply["structuredContent"]?.jsonString ?? "")
            let content = try XCTUnwrap(f.window.window?.contentView)
            XCTAssertEqual(reply["structuredContent"]?["width"]?.doubleValue ?? 0, content.bounds.width.rounded(), accuracy: 1)
        } else {
            XCTAssertEqual(reply["structuredContent"]?["error"]?["code"], "permission_denied",
                           "refused without asking, when the grant is missing")
        }
        let sidebar = try await errorCode(f, "screenshot", ["window_id": .int(f.windowID), "source": "screen",
                                                            "part": "sidebar"])
        XCTAssertEqual(sidebar, "invalid_arguments")
        let page = try await errorCode(f, "screenshot", ["context": .string(f.tab.id.uuidString), "source": "screen"])
        XCTAssertEqual(page, "invalid_arguments")
        let unknown = try await errorCode(f, "screenshot", ["window_id": .int(f.windowID), "source": "camera"])
        XCTAssertEqual(unknown, "invalid_arguments")
    }

    @MainActor func testScreenshotErrors() async throws {
        let f = try await makeFixture()
        let window: JSONValue = .int(f.windowID)
        let cases: [(JSONValue, String)] = [
            ([:], "invalid_arguments"),
            (["window_id": window, "save_to": "relative.png"], "invalid_arguments"),
            (["window_id": window, "save_to": "/tmp/nope.jpg"], "invalid_arguments"),
            (["window_id": window, "save_to": "/no/such/folder/x.png"], "invalid_arguments"),
            (["window_id": window, "scale": 3], "invalid_arguments"),
            (["window_id": window, "part": "toolbar"], "invalid_arguments"),
            (["window_id": window, "context": .string(f.tab.id.uuidString)], "invalid_arguments"),
            (["window_id": 9999], "unknown_window"),
            (["context": .string(UUID().uuidString)], "unknown_context"),
        ]
        for (arguments, expected) in cases {
            let code = try await errorCode(f, "screenshot", arguments)
            XCTAssertEqual(code, expected, arguments.jsonString)
        }
    }

    // MARK: Appearance

    @MainActor func testAppearanceSwitchesLightDarkAndBackToTheSystem() async throws {
        let f = try await makeFixture()
        let dark = try await result(f, "set_appearance", ["appearance": "dark"])
        XCTAssertEqual(dark["structuredContent"]?["effective"], "dark")
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        let light = try await result(f, "set_appearance", ["appearance": "light"])
        XCTAssertEqual(light["structuredContent"]?["effective"], "light")
        _ = try await result(f, "set_appearance", ["appearance": "system"])
        XCTAssertNil(NSApp.appearance)
        let bad = try await errorCode(f, "set_appearance", ["appearance": "sepia"])
        XCTAssertEqual(bad, "invalid_arguments")
    }

    // MARK: Debug overrides (AC #8: Debug builds only)

    @MainActor func testDebugOverridesExistOnlyInDebugBuilds() async throws {
        let f = try await makeFixture()
        let names = f.server.tools.map(\.name)
        #if DEBUG
        XCTAssertTrue(names.contains("set_debug_override"))
        #else
        XCTAssertFalse(names.contains("set_debug_override"))
        #endif
    }

    #if DEBUG
    @MainActor func testReduceMotionAndTheTossCanBeOverriddenAndCleared() async throws {
        let f = try await makeFixture()
        let system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let on = try await result(f, "set_debug_override", ["name": "reduce_motion", "value": "on"])
        XCTAssertEqual(on["structuredContent"]?["overrides"]?["reduce_motion"], true)
        XCTAssertTrue(MotionPreference.reduceMotion)
        _ = try await result(f, "set_debug_override", ["name": "reduce_motion", "value": "off"])
        XCTAssertFalse(MotionPreference.reduceMotion)
        _ = try await result(f, "set_debug_override", ["name": "reduce_motion", "value": "default"])
        XCTAssertEqual(MotionPreference.reduceMotion, system, "back to the system setting")

        let hop = try await result(f, "set_debug_override", ["name": "space_toss_hop", "value": "20"])
        XCTAssertEqual(hop["structuredContent"]?["overrides"]?["space_toss_hop"]?.doubleValue, 20)
        XCTAssertEqual(UserDefaultsScope.defaults.double(forKey: AutomationTools.spaceTossHopKey), 20)
        _ = try await result(f, "set_debug_override", ["name": "space_toss_gravity", "value": "3000"])
        XCTAssertEqual(UserDefaultsScope.defaults.double(forKey: AutomationTools.spaceTossGravityKey), 3000)
        let cleared = try await result(f, "set_debug_override", ["name": "space_toss_hop", "value": "default"])
        XCTAssertEqual(cleared["structuredContent"]?["overrides"]?["space_toss_hop"], .null)

        for (name, value) in [("reduce_motion", "maybe"), ("space_toss_gravity", "0"), ("space_toss_hop", "-1"),
                              ("space_toss_hop", "high"), ("gravity", "1")] {
            let code = try await errorCode(f, "set_debug_override", ["name": .string(name), "value": .string(value)])
            XCTAssertEqual(code, "invalid_arguments", "\(name)=\(value)")
        }
    }
    #endif

    // MARK: Results with images

    @MainActor func testAToolResultCarriesItsImagesAfterTheText() {
        let reply = MCPServer.toolResult(["ok": true], isError: false, images: [Data([1, 2, 3])])
        let content = reply["content"]?.arrayValue ?? []
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"], "text")
        XCTAssertEqual(content[1], ["type": "image", "data": "AQID", "mimeType": "image/png"])
    }
}
