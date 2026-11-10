import XCTest
import WebKit
@testable import Detour

/// TASK-315: a browser window the user closed must be freed. Each test runs a
/// history in a real window, closes it, and checks that a weak reference to
/// its controller goes nil. When it does not, the test runs `leaks
/// --traceTree` on its own process so the failure names what holds it.
///
/// The window is made and driven inside `assertFreedAfterClose`'s inner scope:
/// no strong local reference may outlive it (in Debug a `let` lives to the end
/// of its scope).
nonisolated final class WindowCloseReleaseTests: XCTestCase {

    private var appDelegate: AppDelegate!
    @MainActor private var store: TabStore { .shared }
    private var windowsBefore: Set<ObjectIdentifier> = []
    private var quickDetoursBefore: Set<ObjectIdentifier> = []
    private var createdSpaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?

    private var work: Space!
    private var home: Space!
    private var base: URL!

    @MainActor override func setUp() async throws {
        try await super.setUp()
        appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        windowsBefore = Set(openBrowserWindows().map(ObjectIdentifier.init))
        quickDetoursBefore = Set(QuickDetourWindowController.openControllers.map(ObjectIdentifier.init))
        previousLastActiveSpaceID = store.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
        let profileID = try XCTUnwrap(store.nonIncognitoSpaces.first).profileID
        work = addSpace("Release Work", profileID)
        home = addSpace("Release Home", profileID)
        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>First</title></head><body><a id=a href=/second>second</a></body></html>",
            "/second": "<html><head><title>Second</title></head><body><input id=q></body></html>",
            "/third": "<html><head><title>Third</title></head><body>third</body></html>",
        ])
        servers.append(server)
        let port = try await server.start()
        base = URL(string: "http://127.0.0.1:\(port)/")!
    }

    @MainActor override func tearDown() async throws {
        for controller in QuickDetourWindowController.openControllers
        where !quickDetoursBefore.contains(ObjectIdentifier(controller)) {
            controller.closeDisposition = .discard
            controller.close()
        }
        for wc in openBrowserWindows() where !windowsBefore.contains(ObjectIdentifier(wc)) {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        for id in createdSpaceIDs {
            if let space = store.space(withID: id) {
                for tab in space.tabs { tab.teardown() }
            }
            store.forceRemoveSpace(id: id)
        }
        createdSpaceIDs.removeAll()
        store.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        store.undoManager.removeAllActions()
        for server in servers { server.stop() }
        servers.removeAll()
        try await super.tearDown()
    }

    private struct WeakWindow {
        weak var window: NSWindow?
        let what: String
        let address: String
    }
    @MainActor private static var lingeringWindows: [WeakWindow] = []

    override class func tearDown() {
        // XCTest runs class setUp/tearDown on the main thread, like the tests.
        MainActor.assumeIsolated {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            for entry in lingeringWindows {
                print("TASK-315 window of \(entry.what) at \(entry.address) after the test pools drained: \(entry.window == nil ? "freed" : "STILL ALIVE")")
            }
        }
        super.tearDown()
    }

    // MARK: - Fixture

    @MainActor private func addSpace(_ name: String, _ profileID: UUID) -> Space {
        let space = store.addSpace(name: name, emoji: "🪟", colorHex: "007AFF", profileID: profileID)
        createdSpaceIDs.append(space.id)
        return space
    }

    @MainActor private func openBrowserWindows() -> [BrowserWindowController] {
        NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.filter { !$0.hasClosed }
    }

    /// A registered normal window on `space`, in front and key.
    @MainActor private func makeWindow(showing space: Space, selecting tab: BrowserTab? = nil) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: tab == nil)
        if let tab { wc.selectTab(id: tab.id) }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        appDelegate.registerWindowController(wc)
        becomeKey(wc)
        return wc
    }

    /// What AppKit tells the window's delegate when the user switches to it.
    @MainActor private func becomeKey(_ wc: BrowserWindowController) {
        wc.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: wc.window))
    }

    @MainActor private func loadedTab(in space: Space, path: String = "") async throws -> BrowserTab {
        let tab = store.addTab(in: space, url: base.appendingPathComponent(path))
        return tab
    }

    @MainActor private func waitForLoad(_ tab: BrowserTab, title: String = "First") async throws {
        try await waitUntil("\(title) loads") { tab.title == title && !tab.isLoading }
    }

    @MainActor private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Makes a window with `make`, runs `history` on it, closes it with the
    /// close button's action, and asserts the controller is freed. On a leak,
    /// prints `leaks --traceTree` for the controller.
    @MainActor private func assertFreedAfterClose(
        _ what: String,
        make: () async throws -> BrowserWindowController,
        history: (BrowserWindowController) async throws -> Void = { _ in },
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        weak var weakController: BrowserWindowController?
        weak var weakWindow: NSWindow?
        var address = ""
        try await {
            let wc = try await make()
            weakController = wc
            weakWindow = wc.window
            address = String(format: "0x%lx", UInt(bitPattern: Unmanaged.passUnretained(wc).toOpaque()))
            try await history(wc)
            wc.window?.performClose(nil)
            XCTAssertTrue(wc.hasClosed, "\(what): the window closed", file: file, line: line)
        }()
        let freed = try await pollUntil(timeout: 3) { weakController == nil }
        guard !freed else {
            // AppKit lets go of the window itself a little later (an
            // autorelease pool), so it gets a wait of its own.
            let windowAddress = weakWindow.map { String(format: "0x%lx", UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque())) }
            if try await pollUntil(timeout: 3, { weakWindow == nil }) { return }
            // Still alive: possibly only in the pool XCTest drains after the
            // test. The class tearDown looks again once that has happened.
            Self.lingeringWindows.append(WeakWindow(window: weakWindow, what: what, address: windowAddress ?? "?"))
            return
        }
        let trace = Self.leaksTraceTree(address)
        let path = NSTemporaryDirectory() + "task315-\(what.replacingOccurrences(of: " ", with: "-")).txt"
        try? trace.write(toFile: path, atomically: true, encoding: .utf8)
        print("TASK-315 retain tree for \(what) at \(address) (\(path)):\n\(trace)")
        XCTFail("\(what): the closed window's controller is still alive; retain tree in \(path)", file: file, line: line)
    }

    @MainActor private static func leaksTraceTree(_ address: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "--traceTree=\(address)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "leaks did not run: \(error)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Histories

    @MainActor func testAPlainWindowIsFreed() async throws {
        try await assertFreedAfterClose("plain", make: { makeWindow(showing: work) })
    }

    @MainActor func testAWindowThatHostedAPageIsFreed() async throws {
        let tab = try await loadedTab(in: work)
        try await assertFreedAfterClose("hosted page", make: { makeWindow(showing: work, selecting: tab) },
                                        history: { _ in try await self.waitForLoad(tab) })
    }

    @MainActor func testAWindowThatNavigatedAndSwitchedTabsIsFreed() async throws {
        let first = try await loadedTab(in: work)
        let second = try await loadedTab(in: work, path: "second")
        try await assertFreedAfterClose("tab switches", make: { makeWindow(showing: work, selecting: first) },
                                        history: { wc in
            try await self.waitForLoad(first)
            wc.selectTab(id: second.id)
            try await self.waitForLoad(second, title: "Second")
            wc.selectTab(id: first.id)
            first.load(self.base.appendingPathComponent("third"))
            try await self.waitForLoad(first, title: "Third")
        })
    }

    @MainActor func testAWindowThatSwitchedSpacesIsFreed() async throws {
        let first = try await loadedTab(in: work)
        let other = try await loadedTab(in: home, path: "second")
        try await assertFreedAfterClose("space switches", make: { makeWindow(showing: work, selecting: first) },
                                        history: { wc in
            try await self.waitForLoad(first)
            wc.setActiveSpace(id: self.home.id)
            wc.selectTab(id: other.id)
            try await self.waitForLoad(other, title: "Second")
            wc.setActiveSpace(id: self.work.id)
        })
    }

    /// Both windows on one space with the same tab; the other window takes the
    /// web view over, then this one is closed.
    @MainActor func testAWindowWhoseSharedTabAnotherWindowTookIsFreed() async throws {
        let tab = try await loadedTab(in: work)
        let keeper = makeWindow(showing: work, selecting: tab)
        try await waitForLoad(tab)
        try await assertFreedAfterClose("shared tab taken", make: { makeWindow(showing: work, selecting: tab) },
                                        history: { wc in
            self.becomeKey(wc)
            XCTAssertTrue(tab.webView?.window === wc.window, "precondition: this window hosts the page")
            self.becomeKey(keeper)
            XCTAssertTrue(tab.webView?.window === keeper.window, "precondition: the other window took it")
            self.becomeKey(wc)
            self.becomeKey(keeper)
        })
    }

    /// Both windows on one space with the same tab; this one hosts the web view
    /// when it is closed.
    @MainActor func testAWindowClosedWhileHostingASharedTabIsFreed() async throws {
        let tab = try await loadedTab(in: work)
        let other = makeWindow(showing: work, selecting: tab)
        try await waitForLoad(tab)
        try await assertFreedAfterClose("shared tab hosted", make: { makeWindow(showing: work, selecting: tab) },
                                        history: { wc in
            self.becomeKey(other)
            self.becomeKey(wc)
            XCTAssertTrue(tab.webView?.window === wc.window, "precondition: this window hosts the page")
        })
        becomeKey(other)
    }

    /// The two windows share a tab, then the other moves to another tab: this
    /// one is left showing a snapshot of a tab nobody hosts.
    @MainActor func testAWindowLeftOnASnapshotIsFreed() async throws {
        let tab = try await loadedTab(in: work)
        let elsewhere = try await loadedTab(in: work, path: "second")
        let other = makeWindow(showing: work, selecting: tab)
        try await waitForLoad(tab)
        try await assertFreedAfterClose("snapshot", make: { makeWindow(showing: work, selecting: tab) },
                                        history: { wc in
            self.becomeKey(wc)
            self.becomeKey(other)
            other.selectTab(id: elsewhere.id)
            try await self.waitForLoad(elsewhere, title: "Second")
            self.spin(0.3)
        })
    }

    @MainActor func testAWindowClosedWithThePaletteOpenIsFreed() async throws {
        let tab = try await loadedTab(in: work)
        try await assertFreedAfterClose("palette", make: { makeWindow(showing: work, selecting: tab) },
                                        history: { wc in
            try await self.waitForLoad(tab)
            wc.focusAddressBar(nil)
            XCTAssertNotNil(wc.commandPaletteView)
        })
    }

    @MainActor func testAWindowClosedWithTheFindBarOpenIsFreed() async throws {
        let tab = try await loadedTab(in: work)
        try await assertFreedAfterClose("find bar", make: { makeWindow(showing: work, selecting: tab) },
                                        history: { wc in
            try await self.waitForLoad(tab)
            wc.showFindBar(nil)
            self.spin(0.3)
        })
    }

    @MainActor func testAWindowClosedWithPeekOpenIsFreed() async throws {
        let tab = try await loadedTab(in: work)
        try await assertFreedAfterClose("peek", make: { makeWindow(showing: work, selecting: tab) },
                                        history: { wc in
            try await self.waitForLoad(tab)
            wc.showPeekOverlay(url: self.base.appendingPathComponent("second"))
            try await waitUntil("the peek loads") { tab.peekTab?.title == "Second" }
        })
    }

    @MainActor func testAWindowThatOpenedAndClosedPeekIsFreed() async throws {
        let tab = try await loadedTab(in: work)
        try await assertFreedAfterClose("peek closed", make: { makeWindow(showing: work, selecting: tab) },
                                        history: { wc in
            try await self.waitForLoad(tab)
            wc.showPeekOverlay(url: self.base.appendingPathComponent("second"))
            try await waitUntil("the peek loads") { tab.peekTab?.title == "Second" }
            wc.closePeekOverlayByUser()
            self.spin(0.6)
        })
    }

    @MainActor func testAWindowShowingASplitIsFreed() async throws {
        let left = try await loadedTab(in: work)
        let right = try await loadedTab(in: work, path: "second")
        store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: work)
        try await assertFreedAfterClose("split", make: { makeWindow(showing: work, selecting: left) },
                                        history: { wc in
            try await self.waitForLoad(left)
            try await self.waitForLoad(right, title: "Second")
            wc.selectTab(id: right.id)
            self.spin(0.3)
        })
    }

    /// A Quick Detour's page moved into this window with Open in.
    @MainActor func testAWindowAQuickDetourOpenedIntoIsFreed() async throws {
        let profile = try XCTUnwrap(work.profile)
        try await assertFreedAfterClose("quick detour open in", make: { makeWindow(showing: work) },
                                        history: { wc in
            let quick = QuickDetourWindowController.open(profile: profile, sourceSpace: self.work, url: self.base)
            let page = try XCTUnwrap(quick.tab)
            try await self.waitForLoad(page)
            quick.openInDefaultSpace(nil)
            XCTAssertEqual(wc.selectedTabID, page.id, "precondition: the page moved into this window")
            self.spin(0.3)
        })
    }

    /// A quarantine's page reloaded in this window's space with Open in.
    @MainActor func testAWindowAQuarantineOpenedIntoIsFreed() async throws {
        try await assertFreedAfterClose("quarantine open in", make: { makeWindow(showing: work) },
                                        history: { wc in
            let quarantine = QuickDetourWindowController.openQuarantine(
                url: self.base, privateProfile: self.store.ensureIncognitoProfile(), sourceSpace: self.work)
            let page = try XCTUnwrap(quarantine.tab)
            try await self.waitForLoad(page)
            quarantine.openInDefaultSpace(nil)
            let moved = try XCTUnwrap(wc.selectedTab, "precondition: the page opened in this window")
            try await self.waitForLoad(moved)
            self.spin(0.3)
        })
    }

    /// The window's own tab closed with Cmd+W, then the window.
    @MainActor func testAWindowThatClosedATabIsFreed() async throws {
        let first = try await loadedTab(in: work)
        let second = try await loadedTab(in: work, path: "second")
        try await assertFreedAfterClose("tab closed", make: { makeWindow(showing: work, selecting: second) },
                                        history: { wc in
            try await self.waitForLoad(second, title: "Second")
            wc.closeCurrentTab(nil)
            try await self.waitForLoad(first)
            self.spin(0.3)
        })
    }

    /// Leaving a tab that plays audio puts it in picture in picture: its
    /// container stays parented for the animation, then is removed on a delay.
    @MainActor func testAWindowThatLeftAPlayingTabIsFreed() async throws {
        let playing = try await loadedTab(in: work)
        let next = try await loadedTab(in: work, path: "second")
        try await assertFreedAfterClose("picture in picture", make: { makeWindow(showing: work, selecting: playing) },
                                        history: { wc in
            try await self.waitForLoad(playing)
            playing.isPlayingAudio = true
            wc.selectTab(id: next.id)
            try await self.waitForLoad(next, title: "Second")
            self.spin(0.8)
        })
    }

    /// The page's inspector docked in its container, then another tab.
    @MainActor func testAWindowThatLeftATabWithADockedInspectorIsFreed() async throws {
        let inspected = try await loadedTab(in: work)
        let next = try await loadedTab(in: work, path: "second")
        try await assertFreedAfterClose("docked inspector", make: { makeWindow(showing: work, selecting: inspected) },
                                        history: { wc in
            try await self.waitForLoad(inspected)
            let webView = try XCTUnwrap(inspected.webView)
            let control = try XCTUnwrap(WebInspectorControl(webView: webView))
            control.show()
            try await waitUntil("the inspector opens") { control.frontendWebView != nil }
            if !control.isAttached, let inspector = webView.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject,
               inspector.responds(to: NSSelectorFromString("attach")) {
                inspector.perform(NSSelectorFromString("attach"))
                _ = try await pollUntil(timeout: 3) { control.isAttached }
            }
            try XCTSkipUnless(control.isAttached, "WebKit opened the inspector undocked")
            let order = webView.superview?.subviews.map { String(describing: type(of: $0)) } ?? []
            print("TASK-315 container subviews with the inspector docked: \(order)")
            wc.selectTab(id: next.id)
            try await self.waitForLoad(next, title: "Second")
            control.close()
            self.spin(0.3)
        })
    }

    // MARK: - Handlers left behind

    /// Which of the window's script message handlers `tab`'s page can post to.
    @MainActor private func windowHandlers(on tab: BrowserTab) async throws -> [String] {
        let webView = try XCTUnwrap(tab.webView)
        let found = try await webView.evaluateJavaScript("""
            ['linkHover', 'editableFieldFocus'].filter(n => !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[n]))
            """) as? [String]
        return found ?? []
    }

    @MainActor func testThePageLeftForPictureInPictureNoLongerReportsToTheWindow() async throws {
        let playing = try await loadedTab(in: work)
        let next = try await loadedTab(in: work, path: "second")
        let wc = makeWindow(showing: work, selecting: playing)
        try await waitForLoad(playing)
        let before = try await windowHandlers(on: playing)
        XCTAssertEqual(before.sorted(), ["editableFieldFocus", "linkHover"],
                       "precondition: the hosted page reports to the window")

        playing.isPlayingAudio = true
        wc.selectTab(id: next.id)
        try await waitForLoad(next, title: "Second")

        let left = try await windowHandlers(on: playing)
        let hosted = try await windowHandlers(on: next)
        XCTAssertEqual(left, [], "the page left for picture in picture")
        XCTAssertEqual(hosted.sorted(), ["editableFieldFocus", "linkHover"])
    }

    /// Back to the PiP page within the capture hold: its container never left
    /// the window, so the claim takes the refresh branch, which must hand the
    /// handlers back.
    @MainActor func testThePageReselectedWithinThePictureInPictureHoldReportsToTheWindowAgain() async throws {
        let playing = try await loadedTab(in: work)
        let next = try await loadedTab(in: work, path: "second")
        let wc = makeWindow(showing: work, selecting: playing)
        try await waitForLoad(playing)

        playing.isPlayingAudio = true
        wc.selectTab(id: next.id)
        let left = try await windowHandlers(on: playing)
        XCTAssertEqual(left, [], "precondition: the page left for picture in picture")
        wc.selectTab(id: playing.id)
        // The test host is not the active app, so the window is not key and
        // the selection only shows a snapshot; the claim comes with key.
        becomeKey(wc)

        let back = try await windowHandlers(on: playing)
        XCTAssertEqual(back.sorted(), ["editableFieldFocus", "linkHover"])
    }

    @MainActor func testThePageLeftWithADockedInspectorNoLongerReportsToTheWindow() async throws {
        let inspected = try await loadedTab(in: work)
        let next = try await loadedTab(in: work, path: "second")
        let wc = makeWindow(showing: work, selecting: inspected)
        try await waitForLoad(inspected)
        let webView = try XCTUnwrap(inspected.webView)
        let control = try XCTUnwrap(WebInspectorControl(webView: webView))
        control.show()
        try await waitUntil("the inspector opens") { control.frontendWebView != nil }
        if !control.isAttached, let inspector = webView.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject,
           inspector.responds(to: NSSelectorFromString("attach")) {
            inspector.perform(NSSelectorFromString("attach"))
            _ = try await pollUntil(timeout: 3) { control.isAttached }
        }
        try XCTSkipUnless(control.isAttached, "WebKit opened the inspector undocked")
        defer { control.close() }

        wc.selectTab(id: next.id)
        try await waitForLoad(next, title: "Second")

        let left = try await windowHandlers(on: inspected)
        XCTAssertEqual(left, [], "the inspected page the window left")
    }
}
