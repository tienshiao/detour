import XCTest
import AppKit
import WebKit
@testable import Detour

/// The agent pointer (TASK-228.11): where the endpoint clicks and types,
/// drawn in a click-through child window of the target window. A click waits
/// for the pointer's glide and is then delivered as before; with the pointer
/// off nothing waits and nothing is drawn. The overlay never becomes key or
/// main, takes no click and changes no hit test or focus; it goes with its
/// window; a window screenshot leaves it out. The glide's wait is injected
/// (`AutomationAgentPointer.pause`), so these tests see it without spending it.
nonisolated final class AutomationAgentPointerTests: XCTestCase {

    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var defaultsSuites: [String] = []

    @MainActor override func tearDown() async throws {
        AutomationAgentPointerSetting.debugOverride = nil
        MotionPreference.reduceMotionOverride = nil
        UserDefaultsScope.defaults.removeObject(forKey: AutomationAgentPointerSetting.enabledKey)
        for suite in defaultsSuites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaultsSuites.removeAll()
        await AutomationMenuTracker.shared.closeAll()
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
        TabStore.shared.undoManager.removeAllActions()
        try await super.tearDown()
    }

    private static let page = """
        <!doctype html><html><head><title>Pointer</title></head>
        <body style="margin:20px;background:#fff">
        <button id="btn" style="width:120px;height:40px">Button</button>
        <input id="field" style="width:200px">
        <script>
        window.events = [];
        ['mousedown','mouseup','click','keydown'].forEach(t =>
          document.addEventListener(t, e => window.events.push({ type: e.type, id: e.target.id, key: e.key }), true));
        </script></body></html>
        """

    /// Whether the pointer is on, as the environment asks it per call.
    @MainActor private final class Flag {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }

    /// What the injected glide wait saw.
    @MainActor private final class Waits {
        var durations: [Duration] = []
        /// Whether the window had heard of a click when each wait began: the
        /// click must come after the glide.
        var clickedBefore: [Bool] = []
        var during: (() -> Void)?
        var realWait: Duration = .zero
    }

    private struct Fixture {
        let tools: AutomationTools
        let server: MCPServer
        let window: BrowserWindowController
        let windowID: Int
        let tab: BrowserTab
        let pointer: AutomationAgentPointer
        let flag: Flag
        let waits: Waits
    }

    @MainActor private func makeFixture(pointerOn: Bool = true) async throws -> Fixture {
        let http = try LoopbackHTTPServer(routes: ["/": Self.page])
        servers.append(http)
        let port = try await http.start()
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Agent Pointer", emoji: "P", colorHex: "FF7600", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        let tab = store.addTab(in: space, url: URL(string: "http://127.0.0.1:\(port)/")!)
        wc.selectTab(id: tab.id)
        try await waitUntil("the page to load") { tab.webView?.title == "Pointer" && !tab.isLoading }

        let flag = Flag(pointerOn)
        var environment = AutomationEnvironment(windowControllers: { [wc] }, mainMenu: { nil }, store: store)
        environment.showsAgentPointer = { flag.on }
        let tools = AutomationTools(environment: environment)
        tools.inputWait = .milliseconds(400)
        let pointer = AutomationAgentPointer()
        let waits = Waits()
        pointer.pause = { [weak wc] duration in
            waits.durations.append(duration)
            waits.clickedBefore.append(wc?.lastWebContentClick != nil)
            waits.during?()
            if waits.realWait > .zero { try? await Task.sleep(for: waits.realWait) }
        }
        tools.agentPointer = pointer
        let server = MCPServer(tools: tools.all, serverVersion: "test", instructions: "")
        return Fixture(tools: tools, server: server, window: wc, windowID: tools.windowIDs.id(for: wc), tab: tab,
                       pointer: pointer, flag: flag, waits: waits)
    }

    @MainActor private func call(_ f: Fixture, _ name: String, _ arguments: JSONValue = [:]) async throws
        -> (content: JSONValue, isError: Bool) {
        let tool = try XCTUnwrap(f.server.tools.first { $0.name == name }, name)
        let result = await f.server.call(tool, arguments: arguments)
        return (try XCTUnwrap(result["structuredContent"]), result["isError"] == true)
    }

    @MainActor private func events(_ f: Fixture) async throws -> [[String: Any]] {
        let value = try await XCTUnwrap(f.tab.webView).evaluateJavaScript("window.events")
        return value as? [[String: Any]] ?? []
    }

    @MainActor private func context(_ f: Fixture) -> JSONValue { .string(f.tab.id.uuidString) }

    @MainActor private func contentCentre(of view: NSView) throws -> (Double, Double) {
        let content = try XCTUnwrap(view.window?.contentView)
        let r = view.convert(view.bounds, to: content)
        return (r.midX, content.isFlipped ? r.midY : content.bounds.height - r.midY)
    }

    /// An element's box in window coordinates.
    @MainActor private func elementRect(_ f: Fixture, _ selector: String) async throws -> NSRect {
        let webView = try XCTUnwrap(f.tab.webView)
        let value = try await webView.evaluateJavaScript(
            "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); "
                + "return [r.left, r.top, r.width, r.height]; })()")
        let numbers = try XCTUnwrap(value as? [NSNumber]).map(\.doubleValue)
        let zoom = webView.pageZoom
        return webView.convert(NSRect(x: numbers[0] * zoom, y: numbers[1] * zoom, width: numbers[2] * zoom,
                                      height: numbers[3] * zoom), to: nil)
    }

    @MainActor private final class ClickView: NSView {
        var downs = 0
        var rightDowns = 0
        override func mouseDown(with event: NSEvent) { downs += 1 }
        override func rightMouseDown(with event: NSEvent) { rightDowns += 1 }
        override func mouseUp(with event: NSEvent) {}
    }

    // MARK: Off

    /// Off, a click and typing wait for nothing and draw nothing (AC #4, #6):
    /// the glide's wait is never asked for and no overlay window is made.
    @MainActor func testWithThePointerOffInputWaitsForNothingAndDrawsNothing() async throws {
        let f = try await makeFixture(pointerOn: false)
        let window = try XCTUnwrap(f.window.window)
        let (clicked, clickError) = try await call(f, "click", ["context": context(f), "selector": "#btn"])
        XCTAssertFalse(clickError, clicked.jsonString)
        let (typed, typeError) = try await call(f, "type_text", ["context": context(f), "selector": "#field", "text": "ab"])
        XCTAssertFalse(typeError, typed.jsonString)
        let (pressed, pressError) = try await call(f, "press_key", ["context": context(f), "key": "x"])
        XCTAssertFalse(pressError, pressed.jsonString)
        try await waitUntil("the keys", timeout: 5) {
            ((try? await self.events(f)) ?? []).filter { $0["type"] as? String == "keydown" }.count == 3
        }
        XCTAssertEqual(f.waits.durations, [], "nothing waited for a glide")
        XCTAssertNil(f.pointer.existingOverlay(for: window), "no overlay was made")
        XCTAssertFalse(window.childWindows?.contains { $0 is AutomationAgentPointerWindow } ?? false)
    }

    // MARK: On

    /// On, a click glides the pointer to the point, then the click is
    /// delivered (AC #1): the wait comes first, with no click yet, and the
    /// overlay is a click-through child of the window that is never key or
    /// main; the app's key and main windows do not change.
    @MainActor func testAClickGlidesThePointerThenDeliversTheClick() async throws {
        let f = try await makeFixture()
        let window = try XCTUnwrap(f.window.window)
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        let (clicked, isError) = try await call(f, "click", ["context": context(f), "selector": "#btn"])
        XCTAssertFalse(isError, clicked.jsonString)
        XCTAssertEqual(f.waits.durations, [.milliseconds(150)], "a short glide by default")
        XCTAssertEqual(f.waits.clickedBefore, [false], "the click is delivered after the glide, not during it")
        try await waitUntil("the click", timeout: 5) {
            ((try? await self.events(f)) ?? []).contains { $0["type"] as? String == "click" && $0["id"] as? String == "btn" }
        }
        let overlay = try XCTUnwrap(f.pointer.existingOverlay(for: window))
        XCTAssertTrue(overlay.isShown)
        let overlayWindow = try XCTUnwrap(overlay.overlayWindow)
        XCTAssertTrue(overlayWindow.parent === window, "a child of the target window, so it moves with it")
        XCTAssertEqual(overlayWindow.frame, window.frame)
        XCTAssertTrue(overlayWindow.ignoresMouseEvents)
        XCTAssertFalse(overlayWindow.canBecomeKey)
        XCTAssertFalse(overlayWindow.canBecomeMain)
        XCTAssertTrue(overlayWindow.isExcludedFromWindowsMenu)
        XCTAssertTrue(NSApp.keyWindow === keyBefore)
        XCTAssertTrue(NSApp.mainWindow === mainBefore)
        let rect = try await elementRect(f, "#btn")
        let point = try XCTUnwrap(overlay.lastPoint)
        XCTAssertEqual(point.x, rect.midX, accuracy: 1)
        XCTAssertEqual(point.y, rect.midY, accuracy: 1)
        // The overlay is no window a client can address.
        let (listed, _) = try await call(f, "list_windows")
        XCTAssertEqual(listed["windows"]?.arrayValue?.count, 1)
    }

    /// The glide is slower once capture staging is in use, and with Reduce
    /// Motion there is none: the pointer appears and nothing waits.
    @MainActor func testStagingGlidesSlowerAndReduceMotionDoesNotGlide() async throws {
        let f = try await makeFixture()
        let window = try XCTUnwrap(f.window.window)
        f.tools.stagingInUse = true
        _ = try await call(f, "click", ["context": context(f), "selector": "#btn"])
        XCTAssertEqual(f.waits.durations, [.milliseconds(600)])

        MotionPreference.reduceMotionOverride = true
        let (clicked, isError) = try await call(f, "click", ["context": context(f), "selector": "#field"])
        XCTAssertFalse(isError, clicked.jsonString)
        XCTAssertEqual(f.waits.durations, [.milliseconds(600)], "no wait with Reduce Motion")
        let overlay = try XCTUnwrap(f.pointer.existingOverlay(for: window))
        XCTAssertTrue(overlay.isShown, "the pointer still appears")
        let rect = try await elementRect(f, "#field")
        XCTAssertEqual(try XCTUnwrap(overlay.lastPoint).x, rect.midX, accuracy: 1)
    }

    /// The overlay takes no click, key status or focus, and changes no hit
    /// test (AC #3): with the pointer over a native view, hit_test reports
    /// the same view and frame, a click there reaches the view, and the
    /// window's first responder stays as it was.
    @MainActor func testThePointerTakesNoClickKeyOrFocus() async throws {
        let f = try await makeFixture()
        let window = try XCTUnwrap(f.window.window)
        let content = try XCTUnwrap(window.contentView)
        let view = ClickView(frame: NSRect(x: content.bounds.midX - 60, y: content.bounds.midY - 15, width: 120, height: 30))
        content.addSubview(view)
        defer { view.removeFromSuperview() }
        let (x, y) = try contentCentre(of: view)
        let (before, _) = try await call(f, "hit_test", ["window_id": .int(f.windowID), "x": .double(x), "y": .double(y)])
        let responder = window.firstResponder

        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        await f.pointer.glide(to: point, in: window, slow: false)
        let overlayWindow = try XCTUnwrap(f.pointer.existingOverlay(for: window)?.overlayWindow)
        XCTAssertTrue(overlayWindow.isVisible)
        XCTAssertTrue(window.firstResponder === responder, "showing the pointer moves no focus")
        overlayWindow.makeKey()
        XCTAssertFalse(overlayWindow.isKeyWindow, "it cannot be made key")
        XCTAssertFalse(NSApp.keyWindow === overlayWindow)
        XCTAssertFalse(NSApp.mainWindow === overlayWindow)
        let (after, _) = try await call(f, "hit_test", ["window_id": .int(f.windowID), "x": .double(x), "y": .double(y)])
        XCTAssertEqual(after, before, "the same view and frame under the pointer")
        XCTAssertEqual(after["view"], "ClickView")

        let (clicked, isError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(x), "y": .double(y)])
        XCTAssertFalse(isError, clicked.jsonString)
        XCTAssertEqual(view.downs, 1, "the click went through the pointer to the view")

        // A right click glides too, and reaches the view.
        let waited = f.waits.durations.count
        let (right, rightError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(x),
                                                              "y": .double(y), "button": "right"])
        XCTAssertFalse(rightError, right.jsonString)
        XCTAssertEqual(right["view"], "ClickView")
        XCTAssertEqual(f.waits.durations.count, waited + 1, "a right click waits for the glide too")
        XCTAssertEqual(view.rightDowns, 1)
    }

    /// Input keeps the order the calls came in while a click waits for its
    /// glide: keys sent while the click glides arrive after it.
    @MainActor func testInputKeepsItsOrderWhileAClickGlides() async throws {
        let f = try await makeFixture()
        f.waits.realWait = .milliseconds(300)
        let server = f.server
        let clickTool = try XCTUnwrap(server.tools.first { $0.name == "click" })
        let clickArguments: JSONValue = ["context": context(f), "selector": "#field"]
        let clicked = Task { await server.call(clickTool, arguments: clickArguments) }
        // The click is in its glide when the keys come.
        try await waitUntil("the glide to start", timeout: 3) { !f.waits.durations.isEmpty }
        let (pressed, pressError) = try await call(f, "press_key", ["context": context(f), "key": "x"])
        let clickReply = await clicked.value
        XCTAssertNotEqual(clickReply["isError"], true, clickReply.jsonString)
        XCTAssertFalse(pressError, pressed.jsonString)
        try await waitUntil("the key", timeout: 5) {
            ((try? await self.events(f)) ?? []).contains { $0["type"] as? String == "keydown" }
        }
        let types = try await events(f).compactMap { $0["type"] as? String }
        let down = try XCTUnwrap(types.firstIndex(of: "mousedown"))
        let key = try XCTUnwrap(types.firstIndex(of: "keydown"))
        XCTAssertLessThan(down, key, "the click that came first is delivered first: \(types)")
    }

    /// The glide is a wait between the click's checks and its delivery, so
    /// they are made again after it: a view put over the point meanwhile gets
    /// the click, and the gate on Settings' Automation section still holds.
    @MainActor func testAClickChecksItsTargetAgainAfterTheGlide() async throws {
        let f = try await makeFixture()
        let content = try XCTUnwrap(f.window.window?.contentView)
        let under = ClickView(frame: NSRect(x: content.bounds.midX - 60, y: content.bounds.midY - 15, width: 120, height: 30))
        content.addSubview(under)
        let over = ClickView(frame: under.frame)
        defer {
            under.removeFromSuperview()
            over.removeFromSuperview()
        }
        let (x, y) = try contentCentre(of: under)
        f.waits.during = { content.addSubview(over) }
        let (clicked, isError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(x), "y": .double(y)])
        XCTAssertFalse(isError, clicked.jsonString)
        XCTAssertEqual(over.downs, 1, "the view under the point after the glide")
        XCTAssertEqual(under.downs, 0)

        over.removeFromSuperview()
        let gate = NSView(frame: under.frame)
        gate.identifier = AutomationWindows.automationSettingsIdentifier
        f.waits.during = { content.addSubview(gate) }
        defer { gate.removeFromSuperview() }
        let (refused, refusedError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(x),
                                                                  "y": .double(y)])
        XCTAssertTrue(refusedError)
        XCTAssertEqual(refused["error"]?["code"], "gate_closed")
        XCTAssertEqual(under.downs, 0)
    }

    /// Typing outlines the field that gets the keys (AC #2): a page's focused
    /// element, and a native field (by its field editor's field).
    @MainActor func testTypingOutlinesTheFieldThatGetsTheKeys() async throws {
        let f = try await makeFixture()
        let window = try XCTUnwrap(f.window.window)
        let (typed, isError) = try await call(f, "type_text", ["context": context(f), "selector": "#field", "text": "hi"])
        XCTAssertFalse(isError, typed.jsonString)
        try await waitUntil("the page's field to hold the text", timeout: 5) {
            (try? await f.tab.webView?.evaluateJavaScript("document.getElementById('field').value")) as? String == "hi"
        }
        let field = try await elementRect(f, "#field")
        let overlay = try XCTUnwrap(f.pointer.existingOverlay(for: window))
        try await waitUntil("the field's outline", timeout: 5) { overlay.highlightedRect != nil }
        let outlined = try XCTUnwrap(overlay.highlightedRect)
        XCTAssertEqual(outlined.midX, field.midX, accuracy: 1)
        XCTAssertEqual(outlined.midY, field.midY, accuracy: 1)
        XCTAssertEqual(outlined.width, field.width, accuracy: 1)

        let content = try XCTUnwrap(window.contentView)
        let textField = NSTextField(frame: NSRect(x: content.bounds.midX - 100, y: content.bounds.midY, width: 200, height: 22))
        content.addSubview(textField)
        defer { textField.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(textField))
        let (native, nativeError) = try await call(f, "type_text", ["window_id": .int(f.windowID), "text": "ok"])
        XCTAssertFalse(nativeError, native.jsonString)
        XCTAssertEqual(textField.stringValue, "ok")
        XCTAssertEqual(overlay.highlightedRect, textField.convert(textField.visibleRect, to: nil),
                       "the field, not its field editor")
    }

    /// A window screenshot (drawn inside Detour) leaves the pointer out
    /// (AC #5): where the overlay draws the orange arrow, the screenshot has
    /// the page's white. The screen source is checked at runtime.
    @MainActor func testAWindowScreenshotLeavesThePointerOut() async throws {
        let f = try await makeFixture()
        let window = try XCTUnwrap(f.window.window)
        let webView = try XCTUnwrap(f.tab.webView)
        // Low in the page, away from the fixture's controls.
        let point = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.maxY - 120), to: nil)
        await f.pointer.glide(to: point, in: window, slow: false)
        let overlayWindow = try XCTUnwrap(f.pointer.existingOverlay(for: window)?.overlayWindow)
        // The arrow's body, a few points below and right of its tip.
        let probe = NSPoint(x: point.x + 3, y: point.y - 9)

        // The overlay itself draws orange there.
        let overlayContent = try XCTUnwrap(overlayWindow.contentView)
        let drawn = try XCTUnwrap(overlayContent.bitmapImageRepForCachingDisplay(in: overlayContent.bounds))
        drawn.size = overlayContent.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: drawn))
        let scale = CGFloat(drawn.pixelsWide) / overlayContent.bounds.width
        context.cgContext.scaleBy(x: scale, y: scale)
        try XCTUnwrap(overlayContent.layer).render(in: context.cgContext)
        context.flushGraphics()
        XCTAssertTrue(isOrange(drawn, at: probe, height: overlayContent.bounds.height, scale: scale),
                      "the overlay draws the arrow at the probe")

        let (shot, isError) = try await call(f, "screenshot", ["window_id": .int(f.windowID), "include_image": false,
                                                               "save_to": .string(temporaryPNG())])
        XCTAssertFalse(isError, shot.jsonString)
        let path = try XCTUnwrap(shot["saved_to"]?.stringValue ?? shot["path"]?.stringValue, shot.jsonString)
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
        let content = try XCTUnwrap(window.contentView)
        let local = content.convert(probe, from: nil)
        let shotScale = CGFloat(image.pixelsWide) / content.bounds.width
        XCTAssertFalse(isOrange(image, at: local, height: content.bounds.height, scale: shotScale),
                       "the screenshot has no pointer there")
    }

    /// Whether `rep` is orange at `point` (bottom-left points in a view of
    /// `height`).
    @MainActor private func isOrange(_ rep: NSBitmapImageRep, at point: NSPoint, height: CGFloat, scale: CGFloat) -> Bool {
        let x = Int(point.x * scale), y = Int((height - point.y) * scale)
        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        return colour.redComponent > 0.8 && colour.greenComponent > 0.3 && colour.greenComponent < 0.75
            && colour.blueComponent < 0.35
    }

    private func temporaryPNG() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("pointer-\(UUID().uuidString).png").path
    }

    // MARK: Lifecycle

    /// The pointer goes with its window: hidden as the window minimizes, and
    /// gone, overlay and all, when the window closes.
    @MainActor func testThePointerGoesWithItsWindow() async throws {
        let f = try await makeFixture()
        let window = try XCTUnwrap(f.window.window)
        let point = NSPoint(x: 300, y: 200)
        await f.pointer.glide(to: point, in: window, slow: false)
        let overlay = try XCTUnwrap(f.pointer.existingOverlay(for: window))
        let overlayWindow = try XCTUnwrap(overlay.overlayWindow)
        XCTAssertTrue(overlay.isShown)
        NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: window)
        XCTAssertFalse(overlay.isShown, "hidden as the window minimizes")
        XCTAssertFalse(window.childWindows?.contains(overlayWindow) ?? false)

        await f.pointer.glide(to: point, in: window, slow: false)
        XCTAssertTrue(overlay.isShown, "shown again by the next click")
        XCTAssertEqual(f.waits.durations.count, 2)
        f.window.sidebarSplitView.autosaveName = nil
        window.close()
        XCTAssertFalse(overlayWindow.isVisible, "gone with its window")
        XCTAssertNil(f.pointer.existingOverlay(for: window), "and forgotten")
        XCTAssertFalse(f.pointer.canShow(in: window))
    }

    // MARK: Setting and override

    /// The setting is on by default for the user, off by default in a test
    /// run (PROVISIONAL), and the Debug override wins over it; turning the
    /// pointer off hides one on screen.
    @MainActor func testTheSettingItsDefaultsAndTheOverride() async throws {
        let suite = "AutomationAgentPointerTests-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(AutomationAgentPointerSetting.isEnabled(in: defaults, testRun: false), "on by default")
        XCTAssertFalse(AutomationAgentPointerSetting.isEnabled(in: defaults, testRun: true),
                       "off by default in a test run, so harnesses keep their speed")
        AutomationAgentPointerSetting.set(false, in: defaults)
        XCTAssertFalse(AutomationAgentPointerSetting.isEnabled(in: defaults, testRun: false))
        AutomationAgentPointerSetting.set(true, in: defaults)
        XCTAssertTrue(AutomationAgentPointerSetting.isEnabled(in: defaults, testRun: true), "a saved choice wins")
        AutomationAgentPointerSetting.debugOverride = false
        XCTAssertFalse(AutomationAgentPointerSetting.isEnabled(in: defaults, testRun: false), "the override wins")
        AutomationAgentPointerSetting.debugOverride = nil

        // Live, the environment reads it per call.
        AutomationAgentPointerSetting.debugOverride = true
        XCTAssertTrue(AutomationEnvironment.live.showsAgentPointer())
        AutomationAgentPointerSetting.debugOverride = false
        XCTAssertFalse(AutomationEnvironment.live.showsAgentPointer())
        AutomationAgentPointerSetting.debugOverride = nil
    }

    /// `set_debug_override agent_pointer` works in a test run only (the
    /// user's endpoint never hides where an agent acts), is listed with the
    /// other overrides, and turned off hides a pointer on screen.
    @MainActor func testTheDebugOverrideIsForTestRunsAndHidesThePointer() async throws {
        let f = try await makeFixture()
        let window = try XCTUnwrap(f.window.window)
        let (refused, refusedError) = try await call(f, "set_debug_override", ["name": "agent_pointer", "value": "off"])
        XCTAssertTrue(refusedError)
        XCTAssertEqual(refused["error"]?["code"], "gate_closed")
        XCTAssertNil(AutomationAgentPointerSetting.debugOverride)

        var environment = AutomationEnvironment(windowControllers: { [f.window] }, mainMenu: { nil }, store: .shared)
        environment.isTestRun = true
        environment.showsAgentPointer = { AutomationAgentPointerSetting.isEnabled(testRun: true) }
        let tools = AutomationTools(environment: environment)
        tools.agentPointer = f.pointer
        let server = MCPServer(tools: tools.all, serverVersion: "test", instructions: "")
        let tool = try XCTUnwrap(server.tools.first { $0.name == "set_debug_override" })
        let on = await server.call(tool, arguments: ["name": "agent_pointer", "value": "on"])
        XCTAssertEqual(on["structuredContent"]?["overrides"]?["agent_pointer"], true)
        XCTAssertTrue(environment.showsAgentPointer())
        await f.pointer.glide(to: NSPoint(x: 300, y: 200), in: window, slow: false)
        let overlay = try XCTUnwrap(f.pointer.existingOverlay(for: window))
        XCTAssertTrue(overlay.isShown)
        let off = await server.call(tool, arguments: ["name": "agent_pointer", "value": "off"])
        XCTAssertEqual(off["structuredContent"]?["overrides"]?["agent_pointer"], false)
        XCTAssertFalse(overlay.isShown, "turned off, the pointer on screen goes")
        let cleared = await server.call(tool, arguments: ["name": "agent_pointer", "value": "default"])
        XCTAssertEqual(cleared["structuredContent"]?["overrides"]?["agent_pointer"], .null)
    }

    /// Settings > General > Automation's switch shows and saves the setting
    /// (AC #4), and turning it off hides a pointer on screen.
    @MainActor func testTheSettingsSwitch() async throws {
        let f = try await makeFixture()
        let window = try XCTUnwrap(f.window.window)
        UserDefaultsScope.defaults.removeObject(forKey: AutomationAgentPointerSetting.enabledKey)
        let pane = GeneralSettingsViewController()
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: 900))
        pane.viewWillAppear()
        let toggle = try XCTUnwrap(pane.agentPointerSwitch)
        XCTAssertEqual(toggle.state, AutomationAgentPointerSetting.isTestRun ? .off : .on, "on by default")

        let shared = AutomationAgentPointer.shared
        let pause = shared.pause
        shared.pause = { _ in }
        defer { shared.pause = pause }
        await shared.glide(to: NSPoint(x: 300, y: 200), in: window, slow: false)
        let overlay = try XCTUnwrap(shared.existingOverlay(for: window))
        XCTAssertTrue(overlay.isShown)
        toggle.state = .off
        pane.agentPointerSwitchChanged()
        XCTAssertEqual(UserDefaultsScope.defaults.object(forKey: AutomationAgentPointerSetting.enabledKey) as? Bool, false)
        XCTAssertFalse(AutomationAgentPointerSetting.isEnabled())
        XCTAssertFalse(overlay.isShown, "turned off, the pointer on screen goes")
        toggle.state = .on
        pane.agentPointerSwitchChanged()
        XCTAssertTrue(AutomationAgentPointerSetting.isEnabled())
    }
}
