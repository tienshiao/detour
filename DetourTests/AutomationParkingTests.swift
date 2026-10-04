import XCTest
import WebKit
import GRDB
@testable import Detour

// TASK-132.3: an automation-attached tab stays awake and, while no window
// displays it, parked hidden in a window — so an extension can snapshot it and
// send it synthesized input — without its priority (or any other tab's) being
// raised, and without the selected tab, the key window or the first responder
// changing.

private let owner = TabAutomationOwner(extensionID: "ext-a", reason: "debugger")
private let secondOwner = TabAutomationOwner(extensionID: "ext-a", reason: "command")

// MARK: - The attachment model and the sleep/archive exemption

@MainActor
final class TabAutomationAttachmentTests: XCTestCase {

    /// Nothing listens on port 1, so nothing here reaches the network.
    private let pageURL = URL(string: "http://127.0.0.1:1/page")!

    private var createdTabs: [BrowserTab] = []
    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!

    override func setUp() {
        super.setUp()
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
    }

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        super.tearDown()
    }

    private func makeStore() throws -> (TabStore, Profile, Space) {
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()))
        let profile = store.addProfile(name: "Automation")
        let space = store.addSpace(name: "Automation", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        return (store, profile, space)
    }

    @discardableResult
    private func makeTab(_ store: TabStore, in space: Space) -> BrowserTab {
        let tab = store.addTab(in: space)
        tab.url = pageURL
        createdTabs.append(tab)
        return tab
    }

    /// Takes a parked container out of whatever window took it, so that only
    /// the attachment — not "its container is in a window" — can be what keeps
    /// the tab awake.
    private func unparent(_ tab: BrowserTab) {
        tab.webViewContainer?.removeFromSuperview()
    }

    // MARK: Owners

    func testOwnersAreCountedAsASet() throws {
        let (store, _, space) = try makeStore()
        let tab = makeTab(store, in: space)
        XCTAssertFalse(tab.isAutomationAttached)
        XCTAssertEqual(tab.automationHosting, .notAttached)

        XCTAssertTrue(tab.attachAutomation(owner))
        XCTAssertTrue(tab.attachAutomation(owner), "attaching the same owner again is not an error")
        XCTAssertEqual(tab.automationOwners, [owner])

        XCTAssertTrue(tab.attachAutomation(secondOwner))
        tab.detachAutomation(owner)
        XCTAssertTrue(tab.isAutomationAttached, "the tab stays attached until every owner is gone")
        tab.detachAutomation(TabAutomationOwner(extensionID: "ext-b", reason: "debugger"))
        XCTAssertEqual(tab.automationOwners, [secondOwner], "an owner that never attached removes nothing")

        tab.detachAutomation(secondOwner)
        XCTAssertFalse(tab.isAutomationAttached)
        XCTAssertEqual(tab.automationHosting, .notAttached)
        XCTAssertFalse(tab.isAutomationParked)
    }

    func testAttachingWakesASleepingTab() throws {
        let (store, _, space) = try makeStore()
        let tab = makeTab(store, in: space)
        tab.sleep()
        XCTAssertNil(tab.webView)
        XCTAssertTrue(tab.isSleeping)

        tab.attachAutomation(owner)
        XCTAssertNotNil(tab.webView)
        XCTAssertFalse(tab.isSleeping)
    }

    func testClosingATabDropsItsAttachmentsAndItCannotBeAttachedAgain() throws {
        let (store, _, space) = try makeStore()
        let tab = makeTab(store, in: space)
        tab.attachAutomation(owner)

        tab.teardown()
        XCTAssertFalse(tab.isAutomationAttached)
        XCTAssertNil(tab.webView)
        XCTAssertNil(tab.webViewContainer)

        XCTAssertFalse(tab.attachAutomation(owner), "a closed tab is not woken to be driven")
        XCTAssertNil(tab.webView)
        XCTAssertNil(tab.automationDrivableWebView())
    }

    func testDrivableWebViewIsOnlyForAnAttachedTab() throws {
        let (store, _, space) = try makeStore()
        let tab = makeTab(store, in: space)
        XCTAssertNil(tab.automationDrivableWebView())
    }

    // MARK: Sleep

    func testAnAttachedTabRefusesToSleepAndSleepsAgainOnceReleased() throws {
        let (store, _, space) = try makeStore()
        let tab = makeTab(store, in: space)
        tab.attachAutomation(owner)

        tab.sleep()
        XCTAssertNotNil(tab.webView, "sleep() spares an attached tab")

        tab.detachAutomation(owner)
        tab.sleep()
        XCTAssertNil(tab.webView)
    }

    func testIdleRuleSkipsAnAttachedTabUntilItIsReleased() throws {
        let (store, _, space) = try makeStore()
        let now = Date()
        let attachedTab = makeTab(store, in: space)
        let plainTab = makeTab(store, in: space)
        // Well past the profile's one-hour idle threshold.
        for tab in [attachedTab, plainTab] { tab.lastDeselectedAt = now.addingTimeInterval(-2 * 3600) }
        attachedTab.attachAutomation(owner)
        unparent(attachedTab)

        store.sleepStaleTabs(now: now)
        XCTAssertFalse(attachedTab.isSleeping, "an attached tab is exempt from the idle rule")
        XCTAssertTrue(plainTab.isSleeping, "an unattached tab next to it still sleeps")

        attachedTab.detachAutomation(owner)
        store.sleepStaleTabs(now: now)
        XCTAssertTrue(attachedTab.isSleeping, "released, it is an ordinary idle tab")
    }

    func testShowBudgetRuleSkipsAttachedNormalPinnedAndFavoriteTabs() throws {
        let (store, profile, space) = try makeStore()
        let now = Date()

        let normal = makeTab(store, in: space)
        let pinned = makeTab(store, in: space)
        store.pinTab(id: pinned.id, in: space)
        let favorite = BrowserTab(configuration: space.makeWebViewConfiguration())
        favorite.spaceID = space.id
        favorite.url = pageURL
        createdTabs.append(favorite)
        store.addFavorite(from: favorite, profileID: profile.id)

        let tabs = [normal, pinned, favorite]
        for tab in tabs {
            for _ in 0..<TabStore.sleepShowBudget { tab.noteShown() }
            tab.lastDeselectedAt = now.addingTimeInterval(-TabStore.sleepShowBudgetGrace - 60)
            tab.attachAutomation(owner)
            unparent(tab)
        }

        store.sleepStaleTabs(now: now)
        for tab in tabs { XCTAssertFalse(tab.isSleeping, "an attached tab is exempt from the show-budget rule") }

        for tab in tabs { tab.detachAutomation(owner) }
        store.sleepStaleTabs(now: now)
        for tab in tabs { XCTAssertTrue(tab.isSleeping) }
    }

    func testSplitPartnerOfAnAttachedTabStaysAwake() throws {
        let (store, _, space) = try makeStore()
        let now = Date()
        let left = makeTab(store, in: space)
        let right = makeTab(store, in: space)
        let groupID = UUID()
        for tab in [left, right] {
            tab.splitGroupID = groupID
            tab.lastDeselectedAt = now.addingTimeInterval(-2 * 3600)
        }
        left.attachAutomation(owner)
        unparent(left)

        store.sleepStaleTabs(now: now)
        XCTAssertFalse(left.isSleeping)
        XCTAssertFalse(right.isSleeping, "a split sleeps as a unit, so the partner stays up too")
    }

    func testAForcedSleepOfAnAttachedTabIsFollowedByAWake() async throws {
        let (store, _, space) = try makeStore()
        let tab = makeTab(store, in: space)
        tab.attachAutomation(owner)

        tab.sleep(force: true)
        XCTAssertNil(tab.webView, "a forced sleep (profile swap, move across profiles) still releases the web view")
        XCTAssertTrue(tab.isAutomationAttached)

        try await waitUntil("the attached tab to be woken again") { tab.webView != nil }
        XCTAssertFalse(tab.isSleeping)
    }

    // MARK: Archive

    func testArchiveSweepSkipsAnAttachedTabUntilItIsReleased() throws {
        let (store, _, space) = try makeStore()
        let now = Date()
        let keeper = makeTab(store, in: space)
        let attachedTab = makeTab(store, in: space)
        let plainTab = makeTab(store, in: space)
        keeper.lastDeselectedAt = nil // selected somewhere
        // Well past the profile's twelve-hour archive threshold.
        for tab in [attachedTab, plainTab] { tab.lastDeselectedAt = now.addingTimeInterval(-13 * 3600) }
        attachedTab.attachAutomation(owner)

        store.archiveStaleTabs(now: now)
        XCTAssertEqual(Set(space.tabs.map(\.id)), [keeper.id, attachedTab.id],
                       "the unattached stale tab is archived, the attached one is not")
        XCTAssertNotNil(attachedTab.webView)
        XCTAssertTrue(attachedTab.isAutomationAttached)

        attachedTab.detachAutomation(owner)
        store.archiveStaleTabs(now: now)
        XCTAssertEqual(space.tabs.map(\.id), [keeper.id], "released, it is archived like any stale tab")
    }

    func testAttachedMemberKeepsItsSplitOutOfTheArchive() throws {
        let (store, _, space) = try makeStore()
        let now = Date()
        let keeper = makeTab(store, in: space)
        let left = makeTab(store, in: space)
        let right = makeTab(store, in: space)
        let groupID = UUID()
        for tab in [left, right] {
            tab.splitGroupID = groupID
            tab.lastDeselectedAt = now.addingTimeInterval(-13 * 3600)
        }
        left.attachAutomation(owner)

        store.archiveStaleTabs(now: now)
        XCTAssertEqual(Set(space.tabs.map(\.id)), [keeper.id, left.id, right.id])
    }

    // MARK: Which window parks a tab

    func testParkingWindowRule() {
        let spaceA = UUID(), spaceB = UUID(), profile1 = UUID(), profile2 = UUID()
        let onA = AutomationParkingCandidate(activeSpaceID: spaceA, profileID: profile1)
        let onB = AutomationParkingCandidate(activeSpaceID: spaceB, profileID: profile1)
        let other = AutomationParkingCandidate(activeSpaceID: UUID(), profileID: profile2)
        func pick(space: UUID?, profile: UUID?, preferred: Int? = nil,
                  _ candidates: [AutomationParkingCandidate]) -> Int? {
            automationParkingWindowIndex(tabSpaceID: space, tabProfileID: profile, preferred: preferred,
                                         candidates: candidates)
        }

        XCTAssertNil(pick(space: spaceA, profile: profile1, []), "no window: the tab waits unhosted")
        XCTAssertEqual(pick(space: spaceB, profile: profile1, [other, onA, onB]), 2,
                       "the window showing the tab's space")
        XCTAssertEqual(pick(space: spaceB, profile: profile1, [other, onA]), 1,
                       "else the first window on the tab's profile")
        XCTAssertEqual(pick(space: spaceB, profile: profile1, [other]), 0, "else the first window")
        XCTAssertEqual(pick(space: spaceA, profile: profile1, [onA, onA]), 0, "ties go to the first listed")
        XCTAssertEqual(pick(space: spaceA, profile: profile1, preferred: 0, [other, onA]), 0,
                       "the window that just stopped displaying the tab wins over the rest")
        XCTAssertEqual(pick(space: spaceA, profile: profile1, preferred: 5, [other, onA]), 1,
                       "a preferred window that cannot take it is ignored")
        XCTAssertEqual(pick(space: nil, profile: nil, [other, onA]), 0)
    }
}

// MARK: - Parking in a real window

/// Real `BrowserWindowController`s, never shown — so never key, and the app is
/// never activated — on a real profile and space of `TabStore.shared`, with
/// pages served by a loopback server.
@MainActor
final class AutomationParkingWindowTests: XCTestCase {

    /// The page from the spike: a button, an input, and a log of every input
    /// event with whether it was trusted.
    private static func page(_ name: String, background: String) -> String {
        """
        <!doctype html><html><head><title>\(name)</title></head>
        <body style="margin:0;background:\(background)">
        <button id="b" style="position:absolute;left:20px;top:20px;width:120px;height:40px">btn</button>
        <input id="i" style="position:absolute;left:20px;top:100px;width:200px;height:30px">
        <script>
        window.log = [];
        for (const type of ['mousedown', 'mouseup', 'click', 'keydown', 'keypress', 'beforeinput', 'input', 'keyup']) {
            document.addEventListener(type, (e) => {
                log.push(type + '/' + (e.isTrusted ? 'T' : 'u') + '/' + (e.target.id || e.target.nodeName));
            }, true);
        }
        </script>
        </body></html>
        """
    }

    private var server: LoopbackHTTPServer?
    private var serverPort: UInt16 = 0
    private var profile: Profile!
    private var space: Space!
    private var otherSpace: Space!
    private var windows: [BrowserWindowController] = []
    private var previousLastActiveSpaceID: UUID?
    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!
    /// The fixture extension of the context-menu tests: its directory, and its
    /// id in `ExtensionManager`.
    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []

    /// Profiles whose configuration hosted a web view stay alive for the rest
    /// of the test process (see `ExtensionTabResolveTests.retainedProfiles`).
    private static var retainedProfiles: [Profile] = []

    override func setUp() async throws {
        try await super.setUp()
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }

        let server = try LoopbackHTTPServer(routes: [
            "/a": Self.page("a", background: "#0000cc"),
            "/b": Self.page("b", background: "#cc0000"),
            "/c": Self.page("c", background: "#cccc00"),
        ])
        serverPort = try await server.start()
        self.server = server

        let store = TabStore.shared
        previousLastActiveSpaceID = store.lastActiveSpaceID
        profile = store.addProfile(name: "Automation parking \(UUID().uuidString.prefix(6))")
        space = store.addSpace(name: "Parking", emoji: "P", colorHex: "007AFF", profileID: profile.id)
        otherSpace = store.addSpace(name: "Other", emoji: "O", colorHex: "34C759", profileID: profile.id)
    }

    override func tearDown() async throws {
        AutomationParking.revealsParkedWebViews = false
        let store = TabStore.shared
        for wc in windows where !wc.hasClosed { wc.window?.close() }
        windows.removeAll()
        for space in [space, otherSpace].compactMap({ $0 }) {
            for tab in space.tabs {
                store.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
            }
            store.forceRemoveSpace(id: space.id)
        }
        store.undoManager.removeAllActions()
        // Closing a window saved the session with the fixture spaces in it.
        store.saveNow()
        if let profile {
            profile.unloadAllExtensions()
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            store.forceRemoveProfile(id: profile.id)
            Self.retainedProfiles.append(profile)
        }
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        profile = nil
        space = nil
        otherSpace = nil
        store.lastActiveSpaceID = previousLastActiveSpaceID
        server?.stop()
        server = nil
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        try await super.tearDown()
    }

    // MARK: Fixtures

    private func makeWindow(on space: Space? = nil, width: CGFloat = 900, height: CGFloat = 640) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        windows.append(wc)
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        wc.window?.setFrame(NSRect(x: 60, y: 60, width: width, height: height), display: false)
        wc.setActiveSpace(id: (space ?? self.space).id)
        wc.window?.layoutIfNeeded()
        return wc
    }

    private func url(_ name: String) -> URL {
        URL(string: "http://127.0.0.1:\(serverPort)/\(name)")!
    }

    private func addTab(_ name: String, in space: Space? = nil) -> BrowserTab {
        TabStore.shared.addTab(in: space ?? self.space, url: url(name))
    }

    private func waitLoaded(_ tab: BrowserTab, _ name: String,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let expected = url(name)
        try await waitUntil("page \(name) to load", timeout: 60, file: file, line: line) {
            tab.webView?.url == expected && tab.webView?.isLoading == false
        }
    }

    private func js(_ tab: BrowserTab, _ body: String) async throws -> Any? {
        let webView = try XCTUnwrap(tab.webView)
        return try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    private func string(_ tab: BrowserTab, _ body: String) async throws -> String {
        let value = try await js(tab, body)
        return try XCTUnwrap(value as? String)
    }

    private func eventLog(_ tab: BrowserTab) async throws -> String {
        try await string(tab, "return window.log.join(' ')")
    }

    private func windowPoint(in webView: WKWebView, pageX: CGFloat, pageY: CGFloat) -> NSPoint {
        let inView = NSPoint(x: pageX, y: webView.isFlipped ? pageY : webView.bounds.height - pageY)
        return webView.convert(inView, to: nil)
    }

    /// A mouse press and release sent straight to the view, as an extension's
    /// input emulation will.
    private func click(_ webView: WKWebView, pageX: CGFloat, pageY: CGFloat) throws {
        let window = try XCTUnwrap(webView.window)
        let location = windowPoint(in: webView, pageX: pageX, pageY: pageY)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        webView.mouseDown(with: try event(.leftMouseDown))
        webView.mouseUp(with: try event(.leftMouseUp))
    }

    private func key(_ type: NSEvent.EventType, _ characters: String, keyCode: UInt16, in webView: WKWebView) throws -> NSEvent {
        let window = try XCTUnwrap(webView.window)
        return try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
    }

    private func typeKey(_ characters: String, keyCode: UInt16, in webView: WKWebView) throws {
        AutomationInput.sendKey(try key(.keyDown, characters, keyCode: keyCode, in: webView), to: webView)
        AutomationInput.sendKey(try key(.keyUp, characters, keyCode: keyCode, in: webView), to: webView)
    }

    /// The sRGB colour of a snapshot's pixel three quarters of the way down
    /// its middle column — clear of the page's controls.
    private func snapshot(_ webView: WKWebView) async throws -> (size: NSSize, red: CGFloat, green: CGFloat, blue: CGFloat) {
        let image = try await webView.takeSnapshot(configuration: nil)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh * 3 / 4)?
            .usingColorSpace(.sRGB))
        return (image.size, color.redComponent, color.greenComponent, color.blueComponent)
    }

    /// The selected tab is hosted live, visibly, filling the content area.
    private func assertDisplays(_ wc: BrowserWindowController, _ tab: BrowserTab,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(wc.selectedTabID, tab.id, file: file, line: line)
        let container = tab.webViewContainer
        XCTAssertTrue(container?.superview === wc.contentContainerView, "no blank pane", file: file, line: line)
        XCTAssertEqual(container?.isHidden, false, file: file, line: line)
        XCTAssertEqual(container?.frame, wc.contentContainerView.bounds, file: file, line: line)
        XCTAssertTrue(tab.webView?.superview === container, file: file, line: line)
        XCTAssertFalse(tab.isAutomationParked, "not double-hosted", file: file, line: line)
    }

    /// The tab is parked in `wc`: in its window, hidden, at content-area size.
    private func assertParked(_ tab: BrowserTab, in wc: BrowserWindowController,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(tab.automationHosting, .parked, file: file, line: line)
        let container = tab.webViewContainer
        XCTAssertTrue(container?.superview === wc.automationParkingView, file: file, line: line)
        XCTAssertEqual(container?.isHidden, true, file: file, line: line)
        XCTAssertTrue(tab.webView?.window === wc.window, file: file, line: line)
        XCTAssertEqual(container?.frame.size, wc.contentContainerView.bounds.size, file: file, line: line)
        XCTAssertEqual(tab.webView?.frame.size, wc.contentContainerView.bounds.size, file: file, line: line)
        XCTAssertFalse(wc.contentContainerView.bounds.isEmpty, file: file, line: line)
    }

    private func assertNotInAnyWindow(_ tab: BrowserTab, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(tab.webView?.window, file: file, line: line)
        XCTAssertNil(tab.webViewContainer?.superview, file: file, line: line)
    }

    // MARK: Attach

    func testAttachingParksAHiddenTabAndChangesNeitherSelectionNorFocus() async throws {
        let wc = makeWindow()
        let window = try XCTUnwrap(wc.window)
        let a = addTab("a"), b = addTab("b"), c = addTab("c")
        wc.selectTab(id: a.id)
        XCTAssertTrue(window.firstResponder === a.webView)
        XCTAssertTrue(wc.automationParkingView === wc.contentContainerView.subviews.first,
                      "the parking host is at the bottom of the content area's z-order")

        let keyWindowBefore = NSApp.keyWindow
        let appWasActive = NSApp.isActive
        XCTAssertTrue(b.attachAutomation(owner))

        assertParked(b, in: wc)
        assertDisplays(wc, a)
        XCTAssertEqual(space.selectedTabID, a.id)
        XCTAssertTrue(window.firstResponder === a.webView, "attaching leaves the first responder alone")
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore, "attaching leaves the key window alone")
        XCTAssertEqual(NSApp.isActive, appWasActive)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(b.automationDrivableWebView() === b.webView)

        // Only the attached tab is kept in a window: its neighbour — which an
        // extension would have in the same tab group — is untouched.
        assertNotInAnyWindow(c)
        XCTAssertEqual(c.automationHosting, .notAttached)
        XCTAssertEqual(wc.automationParkedContainers.count, 1)
    }

    func testAttachingTheDisplayedTabLeavesItDisplayed() async throws {
        let wc = makeWindow()
        let a = addTab("a")
        wc.selectTab(id: a.id)

        a.attachAutomation(owner)
        XCTAssertEqual(a.automationHosting, .displayed)
        assertDisplays(wc, a)
        XCTAssertTrue(wc.automationParkedContainers.isEmpty)
        XCTAssertTrue(a.automationDrivableWebView() === a.webView)
    }

    func testAttachingWakesASleepingTabAndParksIt() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        try await waitLoaded(b, "b")
        b.sleep()
        XCTAssertNil(b.webView)

        b.attachAutomation(owner)
        XCTAssertFalse(b.isSleeping)
        assertParked(b, in: wc)
        try await waitLoaded(b, "b")
        let title = try await string(b, "return document.title")
        XCTAssertEqual(title, "b")
        assertDisplays(wc, a)
    }

    // MARK: Snapshot

    func testAParkedTabSnapshotsItsCurrentPageAtTheContentAreaSize() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        b.attachAutomation(owner)
        try await waitLoaded(b, "b")
        assertParked(b, in: wc)
        let webView = try XCTUnwrap(b.automationDrivableWebView())

        let before = try await snapshot(webView)
        XCTAssertEqual(before.size, wc.contentContainerView.bounds.size)
        XCTAssertGreaterThan(before.red, 0.6, "the page's own red background")
        XCTAssertLessThan(before.green, 0.2)

        // The page changes while parked: the next snapshot must show it.
        _ = try await js(b, "document.body.style.background = '#00ff00'; return 1")
        let after = try await snapshot(webView)
        XCTAssertEqual(after.size, wc.contentContainerView.bounds.size)
        XCTAssertGreaterThan(after.green, 0.8, "a snapshot of a parked tab is freshly painted, not stale")
        XCTAssertLessThan(after.red, 0.2)

        // Nothing was elevated to get it: the parked page is still hidden.
        let visibility = try await string(b, "return document.visibilityState")
        XCTAssertEqual(visibility, "hidden")
        assertParked(b, in: wc)
    }

    func testTheParkedContainerFollowsTheContentAreaSize() async throws {
        let wc = makeWindow(width: 900, height: 640)
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        b.attachAutomation(owner)
        try await waitLoaded(b, "b")
        let sizeBefore = wc.contentContainerView.bounds.size

        wc.window?.setFrame(NSRect(x: 60, y: 60, width: 1100, height: 720), display: false)
        wc.window?.layoutIfNeeded()
        XCTAssertNotEqual(wc.contentContainerView.bounds.size, sizeBefore)
        assertParked(b, in: wc)

        let webView = try XCTUnwrap(b.automationDrivableWebView())
        let image = try await snapshot(webView)
        XCTAssertEqual(image.size, wc.contentContainerView.bounds.size)
        try await waitUntil("the parked page to lay out at the new size") {
            (try await self.js(b, "return window.innerWidth") as? Double).map { CGFloat($0) }
                == wc.contentContainerView.bounds.width
        }
    }

    // MARK: Input

    func testSynthesizedInputReachesAParkedPageAsTrustedEventsWhileTheSelectedTabKeepsFocus() async throws {
        let wc = makeWindow()
        let window = try XCTUnwrap(wc.window as? BrowserWindow)
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        b.attachAutomation(owner)
        try await waitLoaded(a, "a")
        try await waitLoaded(b, "b")
        assertParked(b, in: wc)

        // The user is typing in the selected tab.
        XCTAssertTrue(window.firstResponder === a.webView)
        _ = try await js(a, "document.getElementById('i').focus(); return 1")
        let keyWindowBefore = NSApp.keyWindow
        let browserUndoBefore = TabStore.shared.undoManager.canUndo

        let webView = try XCTUnwrap(b.automationDrivableWebView())
        XCTAssertTrue(webView.isHiddenOrHasHiddenAncestor)

        try click(webView, pageX: 80, pageY: 40) // the button
        try await waitUntil("the click on the parked page's button") {
            try await self.eventLog(b).contains("click/T/b")
        }
        var log = try await eventLog(b)
        XCTAssertTrue(log.contains("mousedown/T/b"), log)
        XCTAssertTrue(log.contains("mouseup/T/b"), log)
        // What WebKit does on a mouse press whenever its page wants focus.
        let refusedBefore = window.refusedParkedFirstResponderCount
        XCTAssertFalse(window.makeFirstResponder(webView), "a parked web view is refused first responder")
        XCTAssertEqual(window.refusedParkedFirstResponderCount, refusedBefore + 1)
        XCTAssertTrue(window.firstResponder === a.webView)

        try click(webView, pageX: 120, pageY: 115) // the input
        try await waitUntil("the parked page's input to take focus") {
            try await self.string(b, "return document.activeElement.id") == "i"
        }
        try typeKey("a", keyCode: 0, in: webView)
        try await waitUntil("the typed key in the parked page's input") {
            try await self.string(b, "return document.getElementById('i').value") == "a"
        }
        // `NSTextInputClient`, which WKWebView implements without declaring it.
        let textInput = try XCTUnwrap(webView as? NSTextInputClient)
        textInput.insertText("héllo", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil("the inserted text in the parked page's input") {
            try await self.string(b, "return document.getElementById('i').value") == "ahéllo"
        }
        log = try await eventLog(b)
        for expected in ["keydown/T/i", "keypress/T/i", "beforeinput/T/i", "input/T/i", "keyup/T/i"] {
            XCTAssertTrue(log.contains(expected), "missing \(expected) in: \(log)")
        }
        XCTAssertFalse(log.contains("/u/"), "every event the parked page saw was trusted: \(log)")

        // None of it touched the tab the user is in.
        XCTAssertTrue(window.firstResponder === a.webView, "the selected tab keeps first responder")
        XCTAssertEqual(wc.selectedTabID, a.id)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
        let selectedLog = try await eventLog(a)
        XCTAssertEqual(selectedLog, "", "the selected page saw none of the parked page's input")
        let selectedFocus = try await string(a, "return document.activeElement.id")
        XCTAssertEqual(selectedFocus, "i", "the selected page keeps its focused field")
        let selectedValue = try await string(a, "return document.getElementById('i').value")
        XCTAssertEqual(selectedValue, "")
        XCTAssertEqual(TabStore.shared.undoManager.canUndo, browserUndoBefore,
                       "typing in a parked page registers nothing with the browser's undo manager")
        let visibility = try await string(b, "return document.visibilityState")
        XCTAssertEqual(visibility, "hidden")
        assertParked(b, in: wc)
        assertDisplays(wc, a)
        print("TASK132.3 first-responder requests WebKit made for the parked view: \(window.refusedParkedFirstResponderCount - 1)")
    }

    /// A key down the parked page declines is handed back by WebKit through
    /// `NSApp.sendEvent`, which routes it to the app's key window and its
    /// first responder — the page the user is in (the spike saw it typed into
    /// that page's focused field, and a declined Cmd-key fire a menu item).
    /// Sent through `AutomationInput` it is dropped on the way back.
    func testAKeyTheParkedPageDeclinesIsDroppedWhenWebKitHandsItBack() async throws {
        final class Probe: NSResponder {
            var received: [NSEvent] = []
            override func keyDown(with event: NSEvent) { received.append(event) }
        }
        let wc = makeWindow()
        let window = try XCTUnwrap(wc.window)
        let probe = Probe()
        wc.nextResponder = probe
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        b.attachAutomation(owner)
        try await waitLoaded(a, "a")
        try await waitLoaded(b, "b")
        XCTAssertTrue(window.firstResponder === a.webView)
        _ = try await js(a, "document.getElementById('i').focus(); return 1")

        let webView = try XCTUnwrap(b.automationDrivableWebView())
        let droppedBefore = AutomationInput.droppedKeyDownCount
        // Nothing is focused in the parked page, so it declines the key.
        let down = try key(.keyDown, "j", keyCode: 38, in: webView)
        AutomationInput.sendKey(down, to: webView)
        AutomationInput.sendKey(try key(.keyUp, "j", keyCode: 38, in: webView), to: webView)
        XCTAssertTrue(AutomationInput.isDrivenKeyDown(down))

        try await waitUntil("WebKit to hand the declined key back") {
            AutomationInput.droppedKeyDownCount == droppedBefore + 1
        }
        let parkedLog = try await eventLog(b)
        XCTAssertTrue(parkedLog.contains("keydown/T/BODY"), "the parked page did see the key: \(parkedLog)")
        // Long enough for a key that got through to be typed.
        try await Task.sleep(nanoseconds: 300_000_000)

        let selectedLog = try await eventLog(a)
        XCTAssertEqual(selectedLog, "", "the declined key must not be typed into the selected page")
        let selectedValue = try await string(a, "return document.getElementById('i').value")
        XCTAssertEqual(selectedValue, "")
        XCTAssertTrue(probe.received.isEmpty, "the declined key must not reach the window controller")
        XCTAssertTrue(window.firstResponder === a.webView)

        // A key the page takes is not handed back, and so not counted.
        try click(webView, pageX: 120, pageY: 115)
        try await waitUntil("the parked page's input to take focus") {
            try await self.string(b, "return document.activeElement.id") == "i"
        }
        try typeKey("k", keyCode: 40, in: webView)
        try await waitUntil("the typed key in the parked page's input") {
            try await self.string(b, "return document.getElementById('i').value") == "k"
        }
        XCTAssertEqual(AutomationInput.droppedKeyDownCount, droppedBefore + 1)
    }

    func testOnlyKeyDownsSentThroughAutomationInputAreDropped() throws {
        let wc = makeWindow()
        let window = try XCTUnwrap(wc.window)
        func keyDown() throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        }
        let typedByTheUser = try keyDown()
        XCTAssertFalse(AutomationInput.isDrivenKeyDown(typedByTheUser))
        XCTAssertTrue(AutomationInput.filter(typedByTheUser) === typedByTheUser, "an ordinary key passes")

        // Sent to a web view in no window: nothing answers, the event is only remembered.
        let driven = try keyDown()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        AutomationInput.sendKey(driven, to: webView)
        XCTAssertTrue(AutomationInput.isDrivenKeyDown(driven))
        let droppedBefore = AutomationInput.droppedKeyDownCount
        XCTAssertNil(AutomationInput.filter(driven))
        XCTAssertEqual(AutomationInput.droppedKeyDownCount, droppedBefore + 1)
        // By identity: an identical event typed by the user is not the driven one.
        XCTAssertFalse(AutomationInput.isDrivenKeyDown(try keyDown()))
    }

    // MARK: Context menu

    private static let extensionMenuItemTitle = "Parking test item"

    /// An extension with `activeTab` and one context-menu item, loaded into
    /// the fixture profile with its worker started. Call it after the window
    /// exists: WebKit asks for the open windows when a context loads, and
    /// afterwards only hears of a window when it becomes key — which these
    /// never do.
    private func loadMenuExtension() async throws -> WKWebExtensionContext {
        let ext = try await makeTestExtension(
            id: "parking-menu-\(UUID().uuidString.prefix(8).lowercased())",
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Parking Menu Test",
                "version": "1.0.0",
                "permissions": ["activeTab", "contextMenus"],
                "background": { "service_worker": "background.js" }
            }
            """,
            files: ["background.js": """
            chrome.contextMenus.create({ id: 'parking', title: '\(Self.extensionMenuItemTitle)', contexts: ['all', 'tab'] });
            """])
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(ext.id)

        let context = try loadTestContext(ext, in: profile)
        // What an install records and a load restores (`recordDeclaredPermissions`).
        context.setPermissionStatus(.grantedExplicitly, for: .activeTab)
        context.setPermissionStatus(.grantedExplicitly, for: .contextMenus)
        context.loadBackgroundContent { error in
            if let error { print("loadBackgroundContent failed: \(error)") }
        }
        return context
    }

    /// The event WebKit hands `willOpenMenu` for a right click on the page.
    private func rightMouseDown(in webView: WKWebView) throws -> NSEvent {
        let window = try XCTUnwrap(webView.window)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: windowPoint(in: webView, pageX: 300, pageY: 300), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// The selected tab `a` and the parked, attached tab `b`, both loaded, in
    /// a window whose profile has the menu extension running.
    private func makeMenuFixture() async throws
        -> (wc: BrowserWindowController, context: WKWebExtensionContext, a: BrowserTab, b: BrowserTab) {
        let wc = makeWindow()
        let context = try await loadMenuExtension()
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        b.attachAutomation(owner)
        try await waitLoaded(a, "a")
        try await waitLoaded(b, "b")
        assertParked(b, in: wc)
        assertDisplays(wc, a)
        // The worker has run once its menu item exists.
        try await waitUntil("the extension to create its menu item", timeout: 60) {
            !context.menuItems(for: a).isEmpty
        }
        XCTAssertFalse(context.hasActiveUserGesture(in: a), "nothing has been clicked yet")
        XCTAssertFalse(context.hasActiveUserGesture(in: b))
        return (wc, context, a, b)
    }

    /// A right click an extension synthesizes on a parked page makes WebKit
    /// build a context menu and offer it to the web view (`willOpenMenu`).
    /// `BrowserWebView` fills in the extensions' items for the window's
    /// *selected* tab, and reports a user gesture in it — which is what hands
    /// an extension `activeTab` there. For a parked page that tab is the one
    /// the user is looking at, and nobody clicked in it.
    func testAContextMenuOnAParkedPageGrantsNoUserGestureInTheSelectedTab() async throws {
        let (wc, context, a, b) = try await makeMenuFixture()
        let parked = try XCTUnwrap(b.automationDrivableWebView() as? BrowserWebView)
        XCTAssertTrue(parked.isInAutomationParking)
        XCTAssertFalse(try XCTUnwrap(wc.window).isKeyWindow)

        let menu = NSMenu()
        parked.willOpenMenu(menu, with: try rightMouseDown(in: parked))

        XCTAssertFalse(context.hasActiveUserGesture(in: a),
                       "a menu on a parked page is not a user gesture in the selected tab")
        XCTAssertFalse(context.hasActiveUserGesture(in: b))
        XCTAssertTrue(menu.items.isEmpty,
                      "no extension items — they would be the selected tab's: \(menu.items.map(\.title))")
        assertParked(b, in: wc)
        assertDisplays(wc, a)
    }

    /// The other side of the rule above: the page the user right-clicked is
    /// the selected tab, and its menu still carries the extensions' items and
    /// still counts as a gesture — with a tab parked in the same window.
    func testAContextMenuOnTheDisplayedPageStillGrantsTheUserGestureAndAddsExtensionItems() async throws {
        let (wc, context, a, b) = try await makeMenuFixture()
        let displayed = try XCTUnwrap(a.webView as? BrowserWebView)
        XCTAssertFalse(displayed.isInAutomationParking)

        let menu = NSMenu()
        displayed.willOpenMenu(menu, with: try rightMouseDown(in: displayed))

        XCTAssertTrue(context.hasActiveUserGesture(in: a), "a right click on the selected page is a user gesture in it")
        XCTAssertFalse(context.hasActiveUserGesture(in: b), "and in no other tab")
        XCTAssertTrue(menu.items.contains { $0.title == Self.extensionMenuItemTitle },
                      "the extension's item is in the menu: \(menu.items.map(\.title))")
        assertParked(b, in: wc)
    }

    // MARK: Selection round trip

    func testSelectingAnAttachedTabDisplaysItAndDeselectingParksItAgain() async throws {
        let wc = makeWindow()
        let window = try XCTUnwrap(wc.window)
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        b.attachAutomation(owner)
        try await waitLoaded(b, "b")
        assertParked(b, in: wc)
        let webView = try XCTUnwrap(b.webView)
        let shownBefore = b.showsSinceWake

        wc.selectTab(id: b.id)
        assertDisplays(wc, b)
        XCTAssertEqual(b.automationHosting, .displayed)
        XCTAssertTrue(b.webView === webView, "the same web view moved from parking to the pane")
        XCTAssertTrue(wc.automationParkedContainers.isEmpty)
        XCTAssertEqual(b.showsSinceWake, shownBefore + 1, "leaving parking for the pane is a show")
        XCTAssertTrue(window.firstResponder === b.webView, "displayed, it takes focus like any selected tab")
        assertNotInAnyWindow(a) // the unattached tab leaves the window as before

        wc.selectTab(id: a.id)
        assertDisplays(wc, a)
        assertParked(b, in: wc)
        XCTAssertTrue(b.webView === webView)
        XCTAssertTrue(window.firstResponder === a.webView)
        let title = try await string(b, "return document.title")
        XCTAssertEqual(title, "b", "the page survived the round trip")
    }

    func testDeselectingEverythingParksTheAttachedTab() async throws {
        let wc = makeWindow()
        let a = addTab("a")
        wc.selectTab(id: a.id)
        a.attachAutomation(owner)

        wc.deselectAllTabs()
        XCTAssertNil(wc.selectedTabID)
        assertParked(a, in: wc)

        wc.selectTab(id: a.id)
        assertDisplays(wc, a)
    }

    func testSwitchingSpacesParksTheAttachedTab() async throws {
        let wc = makeWindow()
        let a = addTab("a")
        let elsewhere = addTab("c", in: otherSpace)
        wc.selectTab(id: a.id)
        a.attachAutomation(owner)

        wc.setActiveSpace(id: otherSpace.id)
        wc.selectTab(id: elsewhere.id)
        assertDisplays(wc, elsewhere)
        assertParked(a, in: wc)

        wc.setActiveSpace(id: space.id)
        assertDisplays(wc, a)
        assertNotInAnyWindow(elsewhere)
    }

    func testASplitPaneCountsAsDisplayed() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b"), c = addTab("c")
        TabStore.shared.createSplit(draggedTabID: c.id, targetTabID: b.id, edge: .right, in: space)
        XCTAssertNotNil(TabStore.shared.splitGroup(containing: b.id, in: space))
        wc.selectTab(id: a.id)
        b.attachAutomation(owner)
        assertParked(b, in: wc)

        // Selecting its partner shows the split: both panes are on screen.
        wc.selectTab(id: c.id)
        XCTAssertEqual(b.automationHosting, .displayed)
        XCTAssertTrue(b.webViewContainer?.superview is NSSplitView)
        XCTAssertTrue(b.webViewContainer?.superview === c.webViewContainer?.superview)
        XCTAssertEqual(b.webViewContainer?.isHidden, false)
        XCTAssertTrue(wc.automationParkedContainers.isEmpty)

        // Leaving the split parks the attached pane only.
        wc.selectTab(id: a.id)
        assertDisplays(wc, a)
        assertParked(b, in: wc)
        assertNotInAnyWindow(c)
    }

    // MARK: Two windows

    func testAParkedTabFollowsOwnershipToASecondWindow() async throws {
        let first = makeWindow(width: 900)
        let second = makeWindow(width: 1000)
        let a = addTab("a"), b = addTab("b"), c = addTab("c")
        first.selectTab(id: a.id)
        second.selectTab(id: c.id)
        b.attachAutomation(owner)
        // Hosted nowhere before: the first window showing its space parks it.
        assertParked(b, in: first)
        let webView = try XCTUnwrap(b.webView)

        // The second window shows it: one web view, hosted once.
        second.selectTab(id: b.id)
        assertDisplays(second, b)
        XCTAssertTrue(b.webView === webView)
        XCTAssertTrue(first.automationParkedContainers.isEmpty)
        assertDisplays(first, a)

        // ... and parks it when it stops showing it.
        second.selectTab(id: c.id)
        assertParked(b, in: second)
        XCTAssertTrue(first.automationParkedContainers.isEmpty)
        assertDisplays(second, c)

        // The first window takes it from the second window's parking.
        first.selectTab(id: b.id)
        assertDisplays(first, b)
        XCTAssertTrue(second.automationParkedContainers.isEmpty)
        XCTAssertTrue(b.webView === webView)
        assertDisplays(second, c)
    }

    func testAWindowShowingASnapshotClaimsTheTabOutOfParking() async throws {
        let first = makeWindow(width: 900)
        let second = makeWindow(width: 1000)
        let a = addTab("a"), b = addTab("b")
        first.selectTab(id: b.id)
        b.attachAutomation(owner)
        // Not key, and the first window displays it: the second shows a snapshot.
        second.selectTab(id: b.id)
        assertDisplays(first, b)
        XCTAssertFalse(b.webViewContainer?.isDescendant(of: second.contentContainerView) ?? true)

        first.selectTab(id: a.id)
        assertParked(b, in: first)
        XCTAssertEqual(second.selectedTabID, b.id)

        // What `windowDidBecomeKey` and a navigation in that window do.
        second.ensureOwnsWebView()
        assertDisplays(second, b)
        XCTAssertTrue(first.automationParkedContainers.isEmpty)
        assertDisplays(first, a)
    }

    func testClosingTheWindowMovesItsAttachedTabsToAnotherWindow() async throws {
        let first = makeWindow(width: 900)
        let second = makeWindow(width: 1000)
        let a = addTab("a"), b = addTab("b"), c = addTab("c")
        first.selectTab(id: a.id)
        second.selectTab(id: b.id)
        b.attachAutomation(owner)
        c.attachAutomation(owner)
        second.selectTab(id: c.id)
        assertParked(b, in: second) // parked there
        assertDisplays(second, c)   // displayed there

        second.window?.close()
        XCTAssertTrue(second.hasClosed)
        assertParked(b, in: first)
        assertParked(c, in: first)
        XCTAssertFalse(b.webViewContainer?.isDescendant(of: second.contentContainerView) ?? true)
        XCTAssertFalse(c.webViewContainer?.isDescendant(of: second.contentContainerView) ?? true)
        assertDisplays(first, a)
        XCTAssertTrue(b.isAutomationAttached)

        // With that window gone too the attachment stands, and the tab is
        // parked in whatever browser window is left — or waits for one.
        first.window?.close()
        XCTAssertFalse(b.webViewContainer?.isDescendant(of: first.contentContainerView) ?? true)
        XCTAssertTrue(b.isAutomationAttached)
        XCTAssertNotNil(b.webView)
        let remaining = extensionBrowserWindows().filter(\.canParkAutomationTabs)
        if remaining.isEmpty {
            XCTAssertEqual(b.automationHosting, .unhosted)
            XCTAssertNil(b.automationDrivableWebView())
        } else {
            XCTAssertEqual(b.automationHosting, .parked)
            XCTAssertTrue(remaining.contains { $0 === b.automationParkingHost?.controller })
        }

        // A new window takes what is waiting, or selects it out of parking.
        let third = makeWindow(width: 950)
        XCTAssertEqual(b.automationHosting, .parked)
        third.selectTab(id: b.id)
        assertDisplays(third, b)
        b.detachAutomation(owner)
        c.detachAutomation(owner)
    }

    // MARK: Close

    func testClosingAParkedTabTearsParkingDown() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        b.attachAutomation(owner)
        assertParked(b, in: wc)
        let container = try XCTUnwrap(b.webViewContainer)

        TabStore.shared.closeTab(id: b.id, in: space, undoable: false, registersUndo: false)
        XCTAssertFalse(b.isAutomationAttached)
        XCTAssertEqual(b.automationHosting, .notAttached)
        XCTAssertNil(b.webView)
        XCTAssertNil(container.superview)
        XCTAssertTrue(wc.automationParkedContainers.isEmpty)
        assertDisplays(wc, a)

        // Nothing brings it back.
        AutomationParking.reconcile(preferring: wc)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(b.webView)
        XCTAssertTrue(wc.automationParkedContainers.isEmpty)
    }

    func testClosingTheDisplayedAttachedTabLeavesTheWindowOnItsNeighbour() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: b.id)
        b.attachAutomation(owner)

        let index = try XCTUnwrap(space.tabs.firstIndex { $0 === b })
        wc.closeTab(at: index, wasSelected: true)
        XCTAssertFalse(b.isAutomationAttached)
        XCTAssertNil(b.webView)
        assertDisplays(wc, a)
        XCTAssertTrue(wc.automationParkedContainers.isEmpty)
    }

    // MARK: Release

    func testReleasingTheAttachmentMakesItAnOrdinaryHiddenTabAgain() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        b.attachAutomation(owner)
        b.attachAutomation(secondOwner)
        assertParked(b, in: wc)
        let container = try XCTUnwrap(b.webViewContainer)

        b.detachAutomation(owner)
        assertParked(b, in: wc) // one owner left

        b.detachAutomation(secondOwner)
        XCTAssertEqual(b.automationHosting, .notAttached)
        assertNotInAnyWindow(b)
        XCTAssertFalse(container.isHidden, "it must not come back hidden when next displayed")
        XCTAssertNotNil(b.webView, "releasing does not sleep the tab; the sleep policy does")
        XCTAssertTrue(wc.automationParkedContainers.isEmpty)
        XCTAssertNil(b.automationDrivableWebView())

        // Selecting and leaving it now takes it out of the window, as for any tab.
        wc.selectTab(id: b.id)
        assertDisplays(wc, b)
        wc.selectTab(id: a.id)
        assertNotInAnyWindow(b)
        XCTAssertTrue(wc.automationParkedContainers.isEmpty)

        // ... and it sleeps on the idle rule again.
        let now = Date()
        b.lastDeselectedAt = now.addingTimeInterval(-2 * 3600)
        TabStore.shared.sleepStaleTabs(now: now)
        XCTAssertTrue(b.isSleeping)
    }

    // MARK: The reserve switch

    func testRevealSwitchUnhidesOnlyParkedContainersAndKeepsThemOffScreen() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        b.attachAutomation(owner)
        assertParked(b, in: wc)
        XCTAssertFalse(AutomationParking.revealsParkedWebViews, "off by default")

        AutomationParking.revealsParkedWebViews = true
        let container = try XCTUnwrap(b.webViewContainer)
        XCTAssertFalse(container.isHidden)
        XCTAssertTrue(container.superview === wc.automationParkingView)
        XCTAssertEqual(wc.automationParkingView.alphaValue, 0, "an un-hidden parked page is still not drawn")
        let center = NSPoint(x: wc.contentContainerView.bounds.midX, y: wc.contentContainerView.bounds.midY)
        let hit = wc.contentContainerView.hitTest(wc.contentContainerView.convert(center, to: wc.contentContainerView.superview))
        XCTAssertFalse(hit?.isInAutomationParking ?? false, "... and takes no real clicks")
        XCTAssertEqual(a.webViewContainer?.isHidden, false)

        AutomationParking.revealsParkedWebViews = false
        XCTAssertTrue(container.isHidden)
    }

    // MARK: By hand

    /// Not a regression test: prints what `log show` needs for the process
    /// assertion comparison of acceptance criterion 7. It puts a window on
    /// screen (never key, the app never activated), so it only runs when asked:
    /// `TEST_RUNNER_DETOUR_TASK132_3_PROBE=1 xcodebuild … -only-testing:…/testProcessAssertionProbe`.
    func testProcessAssertionProbe() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DETOUR_TASK132_3_PROBE"] == "1",
                          "by-hand probe; set TEST_RUNNER_DETOUR_TASK132_3_PROBE=1")
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b"), c = addTab("c")
        wc.selectTab(id: a.id)
        wc.window?.orderFrontRegardless()
        b.attachAutomation(owner)
        for (tab, name) in [(a, "a"), (b, "b"), (c, "c")] { try await waitLoaded(tab, name) }

        let stateJS = """
        if (!window.probeStarted) { window.probeStarted = true; window.ticks = 0; window.frames = 0;
            setInterval(() => window.ticks++, 100);
            (function frame() { window.frames++; requestAnimationFrame(frame); })(); }
        return JSON.stringify({ visibility: document.visibilityState, ticks: window.ticks, frames: window.frames });
        """
        func report(_ label: String) async throws {
            for (tab, name) in [(a, "A selected"), (b, "B attached+parked"), (c, "C plain hidden")] {
                let pid = tab.webView?.value(forKey: "_webProcessIdentifier") as? Int ?? -1
                let state = try await string(tab, stateJS)
                print("TASK132.3-PROBE \(label) | \(name) | pid \(pid) | hosting \(tab.automationHosting) | \(state)")
            }
        }
        print("TASK132.3-PROBE window visible=\(wc.window?.isVisible ?? false) occlusionVisible=\(wc.window?.occlusionState.contains(.visible) ?? false) key=\(wc.window?.isKeyWindow ?? false) appActive=\(NSApp.isActive)")
        try await report("start")
        try await Task.sleep(nanoseconds: 4_000_000_000)
        try await report("after 4 s")
        print("TASK132.3-PROBE phase-1-end \(Date())")

        // On screen: does WebKit ask for first responder on a press in the parked page?
        let browserWindow = try XCTUnwrap(wc.window as? BrowserWindow)
        let parked = try XCTUnwrap(b.automationDrivableWebView())
        try click(parked, pageX: 80, pageY: 40)
        try click(parked, pageX: 120, pageY: 115)
        try typeKey("a", keyCode: 0, in: parked)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        print("TASK132.3-PROBE input | B log: \(try await eventLog(b)) | B value: \(try await string(b, "return document.getElementById('i').value")) | first-responder requests refused: \(browserWindow.refusedParkedFirstResponderCount) | first responder is A: \(browserWindow.firstResponder === a.webView) | key=\(browserWindow.isKeyWindow) appActive=\(NSApp.isActive)")

        AutomationParking.revealsParkedWebViews = true
        try await Task.sleep(nanoseconds: 4_000_000_000)
        try await report("revealed, after 4 s")
        print("TASK132.3-PROBE phase-2-end \(Date())")

        AutomationParking.revealsParkedWebViews = false
        try await Task.sleep(nanoseconds: 4_000_000_000)
        try await report("hidden again, after 4 s")
        print("TASK132.3-PROBE phase-3-end \(Date())")
    }
}
