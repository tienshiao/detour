import XCTest
import WebKit
@testable import Detour

/// TASK-132.14: the CDP Input domain (`Input.dispatchMouseEvent`,
/// `dispatchKeyEvent`, `insertText`) sent by a real extension, from its
/// service worker and from one of its pages, to a parked (unselected) tab and
/// to the displayed one, in a real (never shown) browser window. Every
/// command is answered once the page has handled it, so each check runs right
/// after the `sendCommand` it follows.
nonisolated final class ExtensionDebuggerInputTests: XCTestCase {

    private typealias Via = SidePanelTestWorld.Via
    private var world: SidePanelTestWorld!
    private var menuObserver: (any NSObjectProtocol)?
    /// Native menus that began tracking during the test.
    @MainActor private static var menusOpened: [String] = []
    @MainActor private var menusOpened: [String] { Self.menusOpened }

    @MainActor override func setUp() async throws {
        try await super.setUp()
        world = SidePanelTestWorld(opJS: DebuggerFixture.opJS, workerJS: TabGroupsFixture.workerJS)
        try await world.setUp()
        Self.menusOpened = []
        // A native context menu would hold the main thread in its tracking
        // loop until dismissed: record any that opens, and close it.
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu, menu.supermenu == nil else { return }
                ExtensionDebuggerInputTests.menusOpened.append(menu.items.prefix(2).map(\.title).joined(separator: ", "))
                let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                    nonisolated(unsafe) let menu = menu
                    MainActor.assumeIsolated { menu.cancelTrackingWithoutAnimation() }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    @MainActor override func tearDown() async throws {
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        ExtensionDebugger.shared.resetForTesting()
        await world.tearDown()
        world = nil
        try await super.tearDown()
    }

    @MainActor private struct Scene {
        let loaded: SidePanelTestWorld.Loaded
        let space: Space
        let window: BrowserWindowController
        let tabs: [BrowserTab]
    }

    /// One window, two tabs: the first selected, the second not.
    @MainActor private func makeScene(_ name: String) async throws -> Scene {
        let ext = try await world.makeExtension(name: "Debugger Input Test", permissions: ["debugger", "tabs"],
                                                defaultPath: nil)
        let profile = world.makeProfile(name)
        let space = world.makeSpace(name, in: profile)
        let window = world.makeWindow(on: space)
        var tabs: [BrowserTab] = []
        for page in ["one", "two"] { tabs.append(try await world.addTab(page, in: space)) }
        window.selectTab(id: tabs[0].id)
        let loaded = try await world.load(ext, in: profile)
        for tab in tabs { try await prepare(tab) }
        return Scene(loaded: loaded, space: space, window: window, tabs: tabs)
    }

    /// Replaces the page with the test's controls and a log of every input
    /// event it sees: `type/T|u/target[:details]`, T for trusted.
    @MainActor private func prepare(_ tab: BrowserTab) async throws {
        try await waitUntil("the tab's page to load", timeout: 20) {
            guard let webView = tab.webView, !webView.isLoading else { return false }
            let ready = try? await webView.callAsyncJavaScript("return document.readyState === 'complete';",
                                                               arguments: [:], contentWorld: .page)
            return ready as? Bool == true
        }
        _ = try await page(tab, """
            document.body.style.cssText = 'margin:0;height:3000px;font:16px sans-serif';
            document.body.innerHTML = `
              <button id="b" style="position:absolute;left:20px;top:20px;width:120px;height:40px">btn</button>
              <form id="f" style="position:absolute;left:20px;top:100px;margin:0"><input id="i" style="width:200px;height:30px"></form>
              <input id="j" style="position:absolute;left:260px;top:100px;width:100px;height:30px">
              <p id="p" style="position:absolute;left:20px;top:200px;width:500px;margin:0">Alpha beta gamma. Delta epsilon.</p>
              <textarea id="t" style="position:absolute;left:20px;top:300px;width:200px;height:60px"></textarea>
              <div id="ce" contenteditable="true" style="position:absolute;left:20px;top:400px;width:200px;height:40px;border:1px solid"></div>
              <select id="s" style="position:absolute;left:450px;top:20px;width:120px;height:30px"><option>one</option><option>two</option></select>
              <div id="d" draggable="true" style="position:absolute;left:300px;top:20px;width:100px;height:40px;background:#ccc">drag</div>`;
            window.log = [];
            const name = (target) => (target && (target.id || target.nodeName)) || 'doc';
            for (const type of ['pointerdown', 'mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu', 'auxclick',
                                'keydown', 'keypress', 'input', 'keyup', 'focus', 'dragstart', 'dragend', 'wheel']) {
                document.addEventListener(type, (e) => {
                    let details = '';
                    if (e instanceof KeyboardEvent) {
                        details = ':' + e.key + ':' + e.code + (e.shiftKey ? ':S' : '') + (e.metaKey ? ':M' : '') + (e.ctrlKey ? ':C' : '');
                    } else if (e instanceof MouseEvent) {
                        details = ':b' + e.button + ':d' + e.detail;
                    }
                    log.push(type + '/' + (e.isTrusted ? 'T' : 'u') + '/' + name(e.target) + details);
                }, true);
            }
            document.getElementById('f').addEventListener('submit', (e) => { e.preventDefault(); log.push('submit'); });
            await new Promise((r) => setTimeout(r, 50));
            """)
    }

    @MainActor private func page(_ tab: BrowserTab, _ body: String) async throws -> Any? {
        let webView = try XCTUnwrap(tab.webView)
        return try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    @MainActor private func string(_ tab: BrowserTab, _ body: String) async throws -> String {
        let value = try await page(tab, body)
        return try XCTUnwrap(value as? String)
    }

    /// The page's log since the last call.
    @MainActor private func takeLog(_ tab: BrowserTab) async throws -> [String] {
        let value = try await page(tab, "const l = window.log; window.log = []; return l;")
        return try XCTUnwrap(value as? [String])
    }

    /// The centre of an element, in CSS pixels of the viewport.
    @MainActor private func center(_ tab: BrowserTab, _ id: String) async throws -> (x: Double, y: Double) {
        let value = try await page(tab, """
            const r = document.getElementById('\(id)').getBoundingClientRect();
            return [r.left + r.width / 2, r.top + r.height / 2];
            """)
        let numbers = try XCTUnwrap(value as? [NSNumber]).map(\.doubleValue)
        return (numbers[0], numbers[1])
    }

    @MainActor private func attach(_ tab: BrowserTab, _ via: Via, _ scene: Scene) async throws -> Int {
        let id = try await world.tabID(of: tab, via, in: scene.loaded)
        _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "attach", "args": [["tabId": id], "1.3"]])
        return id
    }

    @discardableResult
    @MainActor private func send(_ via: Via, _ scene: Scene, _ id: Int, _ method: String,
                                 _ params: [String: Any]) async throws -> Any {
        try await world.run(via, in: scene.loaded, ["op": "call", "method": "sendCommand",
                                                     "args": [["tabId": id], method, params]])
    }

    @MainActor private func mouse(_ via: Via, _ scene: Scene, _ id: Int, _ type: String, _ point: (x: Double, y: Double),
                                  _ extra: [String: Any] = [:]) async throws {
        var params: [String: Any] = ["type": type, "x": point.x, "y": point.y]
        params.merge(extra) { $1 }
        try await send(via, scene, id, "Input.dispatchMouseEvent", params)
    }

    /// Press and release, as the Claude extension sends a click (`clickCount`
    /// counting up for a double or triple click).
    @MainActor private func click(_ via: Via, _ scene: Scene, _ id: Int, _ point: (x: Double, y: Double),
                                  button: String = "left", count: Int = 1) async throws {
        let held = ["left": 1, "right": 2, "middle": 4][button] ?? 0
        for n in 1...count {
            try await mouse(via, scene, id, "mousePressed", point, ["button": button, "buttons": held, "clickCount": n])
            try await mouse(via, scene, id, "mouseReleased", point, ["button": button, "buttons": 0, "clickCount": n])
        }
    }

    @MainActor private func key(_ via: Via, _ scene: Scene, _ id: Int, _ params: [String: Any]) async throws {
        try await send(via, scene, id, "Input.dispatchKeyEvent", params)
    }

    /// A key press the way the Claude extension sends one: `keyDown` with
    /// text, or `rawKeyDown` without, then `keyUp`.
    @MainActor private func press(_ via: Via, _ scene: Scene, _ id: Int, key: String, code: String, text: String = "",
                                  keyCode: Int, modifiers: Int = 0, commands: [String] = []) async throws {
        try await self.key(via, scene, id, ["type": text.isEmpty ? "rawKeyDown" : "keyDown", "key": key, "code": code,
                                            "windowsVirtualKeyCode": keyCode, "modifiers": modifiers, "text": text,
                                            "unmodifiedText": text, "commands": commands])
        try await self.key(via, scene, id, ["type": "keyUp", "key": key, "code": code,
                                            "windowsVirtualKeyCode": keyCode, "modifiers": modifiers])
    }

    @MainActor private func typeText(_ via: Via, _ scene: Scene, _ id: Int, _ text: String) async throws {
        for character in text {
            let letter = String(character)
            let upper = letter.uppercased()
            try await press(via, scene, id, key: letter, code: "Key\(upper)", text: letter,
                            keyCode: Int(upper.unicodeScalars.first!.value),
                            modifiers: letter == upper ? 8 : 0)
        }
    }

    @MainActor private func value(_ tab: BrowserTab, _ id: String) async throws -> String {
        try await string(tab, """
            const e = document.getElementById('\(id)');
            return ('value' in e ? e.value : e.textContent) + '|' + (e.selectionStart ?? '') + '-' + (e.selectionEnd ?? '');
            """)
    }

    // MARK: - AC #1: a click lands on the element at the point, trusted, at any zoom and scroll

    @MainActor func testAClickFiresTrustedEventsOnTheElementAtThePointAtAnyZoomAndScroll() async throws {
        let scene = try await makeScene("Input Click")
        let window = try XCTUnwrap(scene.window.window as? BrowserWindow)
        // The parked tab from the worker, the displayed tab from the page.
        for (via, tab) in [(Via.worker, scene.tabs[1]), (Via.page, scene.tabs[0])] {
            let id = try await attach(tab, via, scene)
            _ = try await takeLog(tab)
            try await click(via, scene, id, try await center(tab, "b"))
            let log = try await takeLog(tab)
            for expected in ["pointerdown/T/b:b0:d1", "mousedown/T/b:b0:d1", "mouseup/T/b:b0:d1", "click/T/b:b0:d1"] {
                XCTAssertTrue(log.contains(expected), "[\(via)] missing \(expected) in \(log)")
            }
            XCTAssertFalse(log.contains { $0.contains("/u/") }, "[\(via)] every event is trusted: \(log)")

            // Zoomed in and scrolled: CSS coordinates of the viewport still hit the element.
            let webView = try XCTUnwrap(tab.webView)
            webView.pageZoom = 1.5
            _ = try await page(tab, "window.scrollTo(0, 60); await new Promise((r) => setTimeout(r, 50)); return 1")
            let input = try await center(tab, "i")
            XCTAssertEqual(input.y, 115 - 60, accuracy: 1, "[\(via)] the input is 60 CSS pixels higher")
            try await click(via, scene, id, input)
            let active = try await string(tab, "return document.activeElement.id")
            XCTAssertEqual(active, "i", "[\(via)] the click at the zoomed, scrolled point focused the input")
            let zoomedLog = try await takeLog(tab)
            XCTAssertTrue(zoomedLog.contains("click/T/i:b0:d1"), "[\(via)] \(zoomedLog)")
            webView.pageZoom = 1
            _ = try await page(tab, "window.scrollTo(0, 0); return 1")
            _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "detach", "args": [["tabId": id]]])
        }
        XCTAssertEqual(scene.window.selectedTabID, scene.tabs[0].id, "nothing changed the selection")
        XCTAssertTrue(window.firstResponder === scene.tabs[0].webView, "the displayed page kept its focus")
    }

    // MARK: - AC #2: double and triple click, right click, drag and wheel

    @MainActor func testMultiClicksRightClickDragsAndTheWheel() async throws {
        let scene = try await makeScene("Input Mouse")
        let tab = scene.tabs[1]
        let via = Via.worker
        let id = try await attach(tab, via, scene)
        XCTAssertEqual(tab.automationHosting, .parked)
        let paragraph = try await center(tab, "p")
        let wordStart = (x: 22.0, y: paragraph.y)

        try await click(via, scene, id, wordStart, count: 2)
        let doubleLog = try await takeLog(tab)
        XCTAssertTrue(doubleLog.contains("dblclick/T/p:b0:d2"), "\(doubleLog)")
        let word = try await string(tab, "return String(getSelection())")
        XCTAssertEqual(word.trimmingCharacters(in: .whitespaces), "Alpha")
        try await click(via, scene, id, wordStart, count: 3)
        let line = try await string(tab, "return String(getSelection())")
        XCTAssertEqual(line.trimmingCharacters(in: .whitespacesAndNewlines), "Alpha beta gamma. Delta epsilon.")
        _ = try await takeLog(tab)

        // Right click: the page's contextmenu event, and no native menu.
        let suppressedBefore = AutomationInput.suppressedContextMenuCount
        try await click(via, scene, id, try await center(tab, "b"), button: "right")
        let rightLog = try await takeLog(tab)
        XCTAssertTrue(rightLog.contains("mousedown/T/b:b2:d1"), "\(rightLog)")
        XCTAssertTrue(rightLog.contains { $0.hasPrefix("contextmenu/T/b:b2") }, "\(rightLog)")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(menusOpened, [], "a synthesized right click opens no menu")
        XCTAssertEqual(AutomationInput.suppressedContextMenuCount, suppressedBefore + 1, "WebKit asked, and got none")

        // A <select>'s native popup is a modal menu: it is closed at once.
        let cancelledBefore = AutomationInput.cancelledMenuCount
        try await click(via, scene, id, try await center(tab, "s"))
        try await waitUntil("the select's popup to be closed") {
            AutomationInput.cancelledMenuCount == cancelledBefore + 1
        }
        let selectLog = try await takeLog(tab)
        XCTAssertTrue(selectLog.contains("mousedown/T/s:b0:d1"), "\(selectLog)")
        Self.menusOpened = []

        // Middle click.
        try await click(via, scene, id, try await center(tab, "b"), button: "middle")
        let middleLog = try await takeLog(tab)
        XCTAssertTrue(middleLog.contains("auxclick/T/b:b1:d1"), "\(middleLog)")

        // Drag-select the paragraph's first words: press, moves with the button held, release.
        _ = try await page(tab, "getSelection().removeAllRanges(); return 1")
        try await mouse(via, scene, id, "mouseMoved", wordStart, ["button": "none", "buttons": 0])
        try await mouse(via, scene, id, "mousePressed", wordStart, ["button": "left", "buttons": 1, "clickCount": 1])
        for step in 1...5 {
            try await mouse(via, scene, id, "mouseMoved", (wordStart.x + Double(step) * 18, wordStart.y),
                            ["button": "left", "buttons": 1])
        }
        try await mouse(via, scene, id, "mouseReleased", (wordStart.x + 90, wordStart.y),
                        ["button": "left", "buttons": 0, "clickCount": 1])
        let selected = try await string(tab, "return String(getSelection())")
        XCTAssertTrue(selected.hasPrefix("Alpha b"), "dragging selected text: '\(selected)'")
        _ = try await takeLog(tab)

        // Dragging a draggable element starts the page's drag, never an OS drag session.
        let refusedBefore = AutomationDragGuard.refusedDragCount
        let handle = try await center(tab, "d")
        try await mouse(via, scene, id, "mousePressed", handle, ["button": "left", "buttons": 1, "clickCount": 1])
        for step in 1...5 {
            try await mouse(via, scene, id, "mouseMoved", (handle.x + Double(step) * 30, handle.y + 40),
                            ["button": "left", "buttons": 1])
        }
        try await mouse(via, scene, id, "mouseReleased", (handle.x + 150, handle.y + 40),
                        ["button": "left", "buttons": 0, "clickCount": 1])
        try? await waitUntil("the refused drag to end in the page") {
            (try? await self.page(tab, "return window.log.some((e) => e.startsWith('dragend/'))") as? Bool) == true
        }
        let dragLog = try await takeLog(tab)
        XCTAssertTrue(dragLog.contains { $0.hasPrefix("dragend/T/d") }, "\(dragLog)")
        XCTAssertTrue(dragLog.contains { $0.hasPrefix("dragstart/T/d") }, "\(dragLog)")
        XCTAssertEqual(AutomationDragGuard.refusedDragCount, refusedBefore + 1, "the OS drag session was refused")
        _ = try await send(via, scene, id, "Input.cancelDragging", [:])

        // The wheel scrolls the page under the point.
        try await mouse(via, scene, id, "mouseWheel", (200, 200), ["deltaX": 0, "deltaY": 240])
        try await waitUntil("the page to scroll") {
            (try? await self.page(tab, "return scrollY") as? Double).map { $0 >= 200 } == true
        }
        let wheelLog = try await takeLog(tab)
        XCTAssertTrue(wheelLog.contains { $0.hasPrefix("wheel/T/") }, "\(wheelLog)")
        XCTAssertEqual(tab.automationHosting, .parked)
        XCTAssertEqual(scene.window.selectedTabID, scene.tabs[0].id)
    }

    // MARK: - AC #3: keys reach the focused element

    @MainActor func testKeysReachTheFocusedElementWithTheirKeyCodeAndModifiers() async throws {
        let scene = try await makeScene("Input Keys")
        let tab = scene.tabs[1]
        let via = Via.page
        let id = try await attach(tab, via, scene)
        try await click(via, scene, id, try await center(tab, "i"))
        _ = try await takeLog(tab)

        try await typeText(via, scene, id, "Hi")
        var current = try await value(tab, "i")
        XCTAssertEqual(current, "Hi|2-2")
        let typedLog = try await takeLog(tab)
        for expected in ["keydown/T/i:H:KeyH:S", "keypress/T/i:H:KeyH:S", "input/T/i", "keyup/T/i:i:KeyI"] {
            XCTAssertTrue(typedLog.contains(expected), "missing \(expected) in \(typedLog)")
        }

        try await press(via, scene, id, key: "ArrowLeft", code: "ArrowLeft", keyCode: 37)
        try await typeText(via, scene, id, "x")
        current = try await value(tab, "i")
        XCTAssertEqual(current, "Hxi|2-2", "the arrow moved the caret")
        try await press(via, scene, id, key: "Backspace", code: "Backspace", keyCode: 8)
        current = try await value(tab, "i")
        XCTAssertEqual(current, "Hi|1-1")
        let editLog = try await takeLog(tab)
        XCTAssertTrue(editLog.contains("keydown/T/i:ArrowLeft:ArrowLeft"), "\(editLog)")
        XCTAssertTrue(editLog.contains("keydown/T/i:Backspace:Backspace"), "\(editLog)")

        // Cmd+A, sent the way the extension sends it on a Mac: with the command.
        try await press(via, scene, id, key: "a", code: "KeyA", text: "a", keyCode: 65, modifiers: 4,
                        commands: ["selectAll"])
        current = try await value(tab, "i")
        XCTAssertEqual(current, "Hi|0-2", "select-all")
        let cmdLog = try await takeLog(tab)
        XCTAssertTrue(cmdLog.contains("keydown/T/i:a:KeyA:M"), "\(cmdLog)")
        // ...unless the page took the key down itself.
        _ = try await page(tab, """
            window.preventMeta = (e) => { if (e.metaKey) e.preventDefault(); };
            document.addEventListener('keydown', window.preventMeta);
            document.getElementById('i').setSelectionRange(1, 1);
            return 1;
            """)
        try await press(via, scene, id, key: "a", code: "KeyA", text: "a", keyCode: 65, modifiers: 4,
                        commands: ["selectAll"])
        current = try await value(tab, "i")
        XCTAssertEqual(current, "Hi|1-1", "a key down the page cancelled runs no command")
        _ = try await page(tab, "document.removeEventListener('keydown', window.preventMeta); return 1")

        // Ctrl+A is the text system's own binding: to the start of the line, nothing typed.
        _ = try await page(tab, "document.getElementById('i').setSelectionRange(2, 2); return 1")
        try await press(via, scene, id, key: "a", code: "KeyA", text: "a", keyCode: 65, modifiers: 2,
                        commands: ["moveToBeginningOfParagraph"])
        current = try await value(tab, "i")
        XCTAssertEqual(current, "Hi|0-0")
        _ = try await takeLog(tab)

        // Enter submits the form; Tab moves focus on.
        try await press(via, scene, id, key: "Enter", code: "Enter", text: "\r", keyCode: 13)
        let enterLog = try await takeLog(tab)
        XCTAssertTrue(enterLog.contains("submit"), "\(enterLog)")
        try await press(via, scene, id, key: "Tab", code: "Tab", keyCode: 9)
        let active = try await string(tab, "return document.activeElement.id")
        XCTAssertEqual(active, "j")
        XCTAssertEqual(tab.automationHosting, .parked)
    }

    // MARK: - AC #4: insertText

    @MainActor func testInsertTextIntoInputsTextareasAndContentEditable() async throws {
        let scene = try await makeScene("Input Text")
        for (via, tab) in [(Via.worker, scene.tabs[1]), (Via.page, scene.tabs[0])] {
            let id = try await attach(tab, via, scene)
            let text = "héllo 🎉 日本"
            for target in ["i", "t", "ce"] {
                try await click(via, scene, id, try await center(tab, target))
                try await send(via, scene, id, "Input.insertText", ["text": text])
                let inserted = try await string(tab, """
                    const e = document.getElementById('\(target)'); return 'value' in e ? e.value : e.textContent;
                    """)
                XCTAssertEqual(inserted, text, "[\(via)] \(target)")
            }
            let log = try await takeLog(tab)
            XCTAssertTrue(log.contains("input/T/ce"), "[\(via)] \(log)")
            _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "detach", "args": [["tabId": id]]])
        }
    }

    // MARK: - AC #5: the user keeps typing in the selected tab

    @MainActor func testInputToAParkedTabLeavesTheUserTypingInTheSelectedTab() async throws {
        let scene = try await makeScene("Input Alongside")
        let window = try XCTUnwrap(scene.window.window)
        let (selected, parked) = (scene.tabs[0], scene.tabs[1])
        let selectedView = try XCTUnwrap(selected.webView)
        XCTAssertTrue(window.makeFirstResponder(selectedView))
        _ = try await page(selected, "document.getElementById('i').focus(); return 1")
        let via = Via.worker
        let id = try await attach(parked, via, scene)
        try await click(via, scene, id, try await center(parked, "i"))
        _ = try await takeLog(selected)

        let userText = "user", extensionText = "drive"
        for index in 0..<max(userText.count, extensionText.count) {
            if index < userText.count {
                // A key the user types reaches the first responder: the selected page.
                let character = String(userText[userText.index(userText.startIndex, offsetBy: index)])
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = try XCTUnwrap(NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: character,
                        charactersIgnoringModifiers: character, isARepeat: false,
                        keyCode: ExtensionDebuggerInput.macKeyCode(forDOMCode: "Key\(character.uppercased())") ?? 0))
                    if type == .keyDown { selectedView.keyDown(with: event) } else { selectedView.keyUp(with: event) }
                }
            }
            if index < extensionText.count {
                let character = String(extensionText[extensionText.index(extensionText.startIndex, offsetBy: index)])
                try await typeText(via, scene, id, character)
            }
        }
        try await waitUntil("the user's typing to land") {
            (try? await self.string(selected, "return document.getElementById('i').value")) == userText
        }
        let parkedValue = try await string(parked, "return document.getElementById('i').value")
        XCTAssertEqual(parkedValue, extensionText)
        XCTAssertTrue(window.firstResponder === selectedView, "the user's page keeps first responder")
        XCTAssertEqual(scene.window.selectedTabID, selected.id)
        let selectedLog = try await takeLog(selected)
        XCTAssertEqual(selectedLog.filter { $0.hasPrefix("keydown") }.count, userText.count,
                       "the selected page saw the user's keys and only those: \(selectedLog)")
    }

    // MARK: - AC #6: never Detour's own chrome, never another tab

    @MainActor func testInputNeverReachesTheBrowsersOwnFocusOrAnotherTab() async throws {
        let scene = try await makeScene("Input Contained")
        let window = try XCTUnwrap(scene.window.window as? BrowserWindow)
        let (displayed, other) = (scene.tabs[0], scene.tabs[1])
        // The user is typing in a field of the window's own (as in the address bar or a side panel).
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        window.contentView?.addSubview(field)
        defer { field.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = window.firstResponder
        _ = try await takeLog(other)

        let via = Via.page
        let id = try await attach(displayed, via, scene)
        XCTAssertEqual(displayed.automationHosting, .displayed)
        try await click(via, scene, id, try await center(displayed, "i"))
        let focused = try await string(displayed, "return document.activeElement.id")
        XCTAssertEqual(focused, "i")
        XCTAssertTrue(window.firstResponder === editor, "the click did not take the user's focus")
        try await typeText(via, scene, id, "ok")
        try await press(via, scene, id, key: "a", code: "KeyA", text: "a", keyCode: 65, modifiers: 4,
                        commands: ["selectAll"])
        let typed = try await value(displayed, "i")
        XCTAssertEqual(typed, "ok|0-2")

        // A key the page declines (nothing focused) and a Cmd-key it declines
        // are dropped, not handed to the window's first responder or the menu.
        _ = try await page(displayed, "document.activeElement.blur(); return 1")
        let droppedBefore = AutomationInput.droppedKeyDownCount
        try await typeText(via, scene, id, "q")
        try await press(via, scene, id, key: "w", code: "KeyW", text: "w", keyCode: 87, modifiers: 4)
        try await waitUntil("WebKit to hand the declined keys back") {
            AutomationInput.droppedKeyDownCount >= droppedBefore + 2
        }
        try await click(via, scene, id, try await center(displayed, "b"), button: "right")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(menusOpened, [])

        XCTAssertEqual(field.stringValue, "", "nothing reached the user's field")
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertFalse(scene.window.hasClosed, "Cmd+W did not close the window")
        XCTAssertEqual(scene.space.tabs.count, 2, "Cmd+W did not close a tab")
        let otherLog = try await takeLog(other)
        XCTAssertEqual(otherLog, [], "the other tab saw nothing")
    }

    // MARK: - Errors, in Chrome's words, in both forms

    @MainActor func testBadInputParametersFailInChromesWords() async throws {
        let scene = try await makeScene("Input Errors")
        for via in Via.allCases {
            let id = try await attach(scene.tabs[1], via, scene)
            let cases: [(String, [String: Any], String)] = [
                ("Input.dispatchMouseEvent", ["type": "mouseSqueezed", "x": 1, "y": 1],
                 #"{"code":-32602,"message":"Unexpected event type 'mouseSqueezed'"}"#),
                ("Input.dispatchMouseEvent", ["type": "mousePressed", "x": 1, "y": 1, "button": "thumb"],
                 #"{"code":-32602,"message":"Invalid mouse button"}"#),
                ("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": 1, "y": 1],
                 #"{"code":-32602,"message":"'deltaX' and 'deltaY' are expected for mouseWheel event"}"#),
                ("Input.dispatchKeyEvent", ["type": "keyPress"],
                 #"{"code":-32602,"message":"Unexpected event type 'keyPress'"}"#),
                ("Input.insertText", [:],
                 #"{"code":-32602,"message":"Invalid parameters: text: string value expected"}"#),
            ]
            for (method, params, expected) in cases {
                let rejected = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "sendCommand",
                                                                               "args": [["tabId": id], method, params]])
                XCTAssertEqual(rejected, expected, "[\(via)] \(method) \(params)")
                let called = try await world.runDict(via, in: scene.loaded, ["op": "callback", "method": "sendCommand",
                                                                             "args": [["tabId": id], method, params]])
                XCTAssertEqual(called["lastError"] as? String, expected, "[\(via)] callback form")
                XCTAssertEqual(called["argc"] as? Int, 0)
            }
            _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "detach", "args": [["tabId": id]]])
            let detached = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "sendCommand",
                "args": [["tabId": id], "Input.insertText", ["text": "x"]]])
            XCTAssertEqual(detached, "Debugger is not attached to the tab with id: \(id).", "[\(via)]")
        }
    }

    /// The context-menu SPI is reachable: a Swift method that drifted from
    /// WebKit's selector would stop being called, and menus would open.
    @MainActor func testTheContextMenuDelegateMethodIsVisibleToWebKit() {
        let selector = NSSelectorFromString("_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:")
        XCTAssertTrue(BrowserWindowController.instancesRespond(to: selector))
        XCTAssertTrue(AutomationUIDelegate.instancesRespond(to: selector))
        XCTAssertTrue(QuickDetourWindowController.instancesRespond(to: selector))
    }
}
