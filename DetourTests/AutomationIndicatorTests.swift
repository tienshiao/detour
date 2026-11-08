import XCTest
import WebKit
import GRDB
@testable import Detour

// TASK-132.13 AC #5: the user can see that a tab is being driven by an
// extension — a sidebar row indicator and a capsule over the pane — and can
// stop it from the capsule.

private let debuggerOwner = TabAutomationOwner(extensionID: "ext-a", reason: "debugger")
private let commandOwner = TabAutomationOwner(extensionID: "ext-a", reason: "command")
private let otherExtensionOwner = TabAutomationOwner(extensionID: "ext-b", reason: "debugger")

// MARK: - What is said, and where the capsule goes

nonisolated final class TabAutomationPresentationTests: XCTestCase {

    @MainActor private func presentation(_ owners: Set<TabAutomationOwner>,
                                         stoppable: Set<String> = []) -> TabAutomationPresentation? {
        TabAutomationPresentation(owners: owners,
                                  displayName: { $0 == "ext-a" ? "Claude" : "Helper" },
                                  isStoppable: { stoppable.contains($0.reason) })
    }

    @MainActor func testNobodyDrivingIsNoPresentation() {
        XCTAssertNil(presentation([]))
    }

    @MainActor func testOneExtensionIsNamed() throws {
        let one = try XCTUnwrap(presentation([debuggerOwner]))
        XCTAssertEqual(one.tooltip, "Controlled by “Claude”")
        XCTAssertEqual(one.bannerTitle, "“Claude” is controlling this tab")
        // Two attachments of the same extension are still one extension.
        XCTAssertEqual(presentation([debuggerOwner, commandOwner]), one)
    }

    @MainActor func testTwoExtensionsAreCounted() throws {
        let two = try XCTUnwrap(presentation([debuggerOwner, commandOwner, otherExtensionOwner]))
        XCTAssertEqual(two.tooltip, "Controlled by 2 extensions")
        XCTAssertEqual(two.bannerTitle, "2 extensions are controlling this tab")
    }

    @MainActor func testStopIsOfferedOnlyWhenSomeOwnerCanBeStopped() throws {
        XCTAssertEqual(presentation([commandOwner])?.canStop, false)
        XCTAssertEqual(presentation([commandOwner], stoppable: ["debugger"])?.canStop, false)
        XCTAssertEqual(presentation([commandOwner, debuggerOwner], stoppable: ["debugger"])?.canStop, true)
    }

    @MainActor func testTheDefaultNameFallsBackToTheExtensionID() throws {
        let unknown = TabAutomationOwner(extensionID: "no-such-extension-\(UUID().uuidString)", reason: "debugger")
        let shown = try XCTUnwrap(TabAutomationPresentation(owners: [unknown]))
        XCTAssertEqual(shown.tooltip, "Controlled by “\(unknown.extensionID)”")
    }

    @MainActor func testTheCapsuleIsCentredOnTheWebViewBelowItsTopEdge() {
        let webView = NSRect(x: 0, y: 0, width: 800, height: 600)
        let fitting = NSSize(width: 300, height: 32)
        let unflipped = AutomationBannerLayout.frame(fittingSize: fitting, webViewFrame: webView, flipped: false)
        XCTAssertEqual(unflipped, NSRect(x: 250, y: 600 - AutomationBannerLayout.topInset - 32, width: 300, height: 32))
        let flipped = AutomationBannerLayout.frame(fittingSize: fitting, webViewFrame: webView, flipped: true)
        XCTAssertEqual(flipped.minY, AutomationBannerLayout.topInset)

        // A web view pushed down by the dev toolbar and narrowed by a docked
        // inspector: the capsule follows the web view, not the container.
        let narrowed = NSRect(x: 0, y: 0, width: 500, height: 560)
        let placed = AutomationBannerLayout.frame(fittingSize: fitting, webViewFrame: narrowed, flipped: false)
        XCTAssertEqual(placed.midX, narrowed.midX)
        XCTAssertEqual(placed.maxY, narrowed.maxY - AutomationBannerLayout.topInset)
    }

    @MainActor func testANarrowPaneClampsTheCapsuleWidth() {
        let webView = NSRect(x: 0, y: 0, width: 200, height: 600)
        let frame = AutomationBannerLayout.frame(fittingSize: NSSize(width: 300, height: 32),
                                                 webViewFrame: webView, flipped: false)
        XCTAssertEqual(frame.width, 200 - 2 * AutomationBannerLayout.sideInset)
        XCTAssertEqual(frame.minX, AutomationBannerLayout.sideInset)
    }
}

// MARK: - The sidebar row's indicator

nonisolated final class TabCellAutomationIndicatorTests: XCTestCase {

    @MainActor func testTheIndicatorFollowsTheTooltipAndIsClearedOnReuse() {
        let cell = TabCellView()
        XCTAssertFalse(cell.isShowingAutomationIndicator)
        XCTAssertTrue(cell.automationIndicator.isHidden)

        cell.updateAutomation(tooltip: "Controlled by “Claude”")
        XCTAssertTrue(cell.isShowingAutomationIndicator)
        XCTAssertFalse(cell.automationIndicator.isHidden)
        XCTAssertEqual(cell.automationIndicator.toolTip, "Controlled by “Claude”")

        cell.updateAutomation(tooltip: "Controlled by 2 extensions")
        XCTAssertEqual(cell.automationIndicator.toolTip, "Controlled by 2 extensions")

        cell.updateAutomation(tooltip: nil)
        XCTAssertFalse(cell.isShowingAutomationIndicator)
        XCTAssertTrue(cell.automationIndicator.isHidden)
        XCTAssertNil(cell.automationIndicator.toolTip)

        cell.updateAutomation(tooltip: "Controlled by “Claude”")
        cell.prepareForReuse()
        XCTAssertFalse(cell.isShowingAutomationIndicator)
        XCTAssertTrue(cell.automationIndicator.isHidden)
    }
}

// MARK: - In a window

nonisolated final class AutomationIndicatorWindowTests: XCTestCase {

    @MainActor private static func page(_ name: String) -> String {
        """
        <!doctype html><html><head><title>\(name)</title></head>
        <body style="margin:0;height:3000px;background:#ddeeff"><p>\(name)</p></body></html>
        """
    }

    private var server: LoopbackHTTPServer?
    private var serverPort: UInt16 = 0
    private var profile: Profile!
    private var space: Space!
    private var windows: [BrowserWindowController] = []
    private var previousLastActiveSpaceID: UUID?
    private var defaultFaviconFetch: ((URL, @escaping @Sendable (NSImage?) -> Void) -> Void)!

    /// Profiles whose configuration hosted a web view stay alive for the rest
    /// of the test process (see `ExtensionTabResolveTests.retainedProfiles`).
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }

        let server = try LoopbackHTTPServer(routes: ["/a": Self.page("a"), "/b": Self.page("b"), "/c": Self.page("c")])
        serverPort = try await server.start()
        self.server = server

        let store = TabStore.shared
        previousLastActiveSpaceID = store.lastActiveSpaceID
        profile = store.addProfile(name: "Automation indicator \(UUID().uuidString.prefix(6))")
        space = store.addSpace(name: "Indicator", emoji: "I", colorHex: "007AFF", profileID: profile.id)
    }

    @MainActor override func tearDown() async throws {
        TabAutomationStop.removeAllHandlersForTesting()
        let store = TabStore.shared
        for wc in windows where !wc.hasClosed { wc.window?.close() }
        windows.removeAll()
        if let space {
            for entry in space.pinnedEntries {
                if let tab = entry.tab { store.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false) }
            }
            for tab in space.tabs {
                store.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
            }
            store.forceRemoveSpace(id: space.id)
        }
        store.undoManager.removeAllActions()
        store.saveNow()
        if let profile {
            profile.unloadAllExtensions()
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            store.forceRemoveProfile(id: profile.id)
            Self.retainedProfiles.append(profile)
        }
        profile = nil
        space = nil
        store.lastActiveSpaceID = previousLastActiveSpaceID
        server?.stop()
        server = nil
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        try await super.tearDown()
    }

    // MARK: Fixtures

    @MainActor private func makeWindow() -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        windows.append(wc)
        wc.sidebarSplitView.autosaveName = nil
        wc.window?.setFrame(NSRect(x: 60, y: 60, width: 900, height: 640), display: false)
        wc.setActiveSpace(id: space.id)
        wc.window?.layoutIfNeeded()
        return wc
    }

    @MainActor private func addTab(_ name: String) -> BrowserTab {
        TabStore.shared.addTab(in: space, url: URL(string: "http://127.0.0.1:\(serverPort)/\(name)")!)
    }

    @MainActor private func waitLoaded(_ tab: BrowserTab, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("page to load", timeout: 60, file: file, line: line) {
            tab.webView?.url != nil && tab.webView?.isLoading == false
        }
    }

    @MainActor private func viewport(_ tab: BrowserTab) async throws -> String {
        let webView = try XCTUnwrap(tab.webView)
        let value = try await webView.callAsyncJavaScript("return innerWidth + 'x' + innerHeight",
                                                          arguments: [:], in: nil, contentWorld: .page)
        return try XCTUnwrap(value as? String)
    }

    /// Registers what Stop does for `"debugger"`: detach, as the debugger does.
    @MainActor private func registerDebuggerStop() -> () -> [TabAutomationOwner] {
        var calls: [TabAutomationOwner] = []
        TabAutomationStop.register(reason: "debugger") { tab, owner in
            calls.append(owner)
            tab.detachAutomation(owner)
        }
        return { calls }
    }

    @MainActor private func banner(_ tab: BrowserTab) -> AutomationBannerView? {
        tab.webViewContainer?.automationBanner
    }

    /// What a press at `point` (in `view`'s coordinates) in `wc`'s window lands on.
    @MainActor private func hit(_ point: NSPoint, in view: NSView, of wc: BrowserWindowController) throws -> NSView? {
        let root = try XCTUnwrap(wc.window?.contentView)
        let inWindow = view.convert(point, to: nil)
        return root.hitTest(root.superview?.convert(inWindow, from: nil) ?? inWindow)
    }

    @MainActor private func cell(forNormalTab tab: BrowserTab, in wc: BrowserWindowController) throws -> TabCellView {
        let sidebar = wc.tabSidebar
        let tabIndex = try XCTUnwrap(space.tabs.firstIndex { $0.id == tab.id })
        let itemIndex = try XCTUnwrap(itemIndex(forTabIndex: tabIndex, in: sidebar.tabItems))
        let row = sidebar.rowForNormalTab(at: itemIndex)
        return try XCTUnwrap(sidebar.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabCellView)
    }

    // MARK: The capsule

    @MainActor func testTheCapsuleAppearsWhenTheDisplayedTabGainsAnOwnerAndGoesWhenItLosesIt() async throws {
        let wc = makeWindow()
        let window = try XCTUnwrap(wc.window)
        let a = addTab("a")
        wc.selectTab(id: a.id)
        try await waitLoaded(a)
        let container = try XCTUnwrap(a.webViewContainer)
        let webView = try XCTUnwrap(a.webView)
        XCTAssertFalse(container.isShowingAutomationBanner)
        XCTAssertTrue(window.firstResponder === webView)
        let containerFrame = container.frame
        let webViewFrame = webView.frame
        let viewportBefore = try await viewport(a)

        a.attachAutomation(debuggerOwner)
        XCTAssertTrue(container.isShowingAutomationBanner, "shown as soon as the tab is attached")
        let shown = try XCTUnwrap(banner(a))
        XCTAssertEqual(shown.titleLabel.stringValue, "“ext-a” is controlling this tab")
        XCTAssertFalse(shown.showsStopButton, "nothing registered a Stop for the debugger")

        // An overlay: the pane and the page keep their size, and the keyboard stays with the page.
        XCTAssertEqual(container.frame, containerFrame)
        XCTAssertEqual(webView.frame, webViewFrame)
        XCTAssertTrue(window.firstResponder === webView)
        XCTAssertFalse(shown.acceptsFirstResponder)
        XCTAssertFalse(shown.stopButton.acceptsFirstResponder)
        let viewportWhileShown = try await viewport(a)
        XCTAssertEqual(viewportWhileShown, viewportBefore)

        // Top centre of the web view, inside it, above the page.
        XCTAssertTrue(shown.superview === container)
        XCTAssertTrue(container.subviews.last === shown)
        XCTAssertEqual(shown.frame.midX, webView.frame.midX, accuracy: 1)
        XCTAssertEqual(shown.frame.maxY, webView.frame.maxY - AutomationBannerLayout.topInset, accuracy: 1)
        XCTAssertGreaterThan(shown.frame.width, 100)
        XCTAssertLessThan(shown.frame.width, webView.frame.width)

        a.attachAutomation(commandOwner)
        XCTAssertTrue(container.isShowingAutomationBanner)
        a.detachAutomation(debuggerOwner)
        XCTAssertTrue(container.isShowingAutomationBanner, "still driven by its command")
        a.detachAutomation(commandOwner)
        XCTAssertFalse(container.isShowingAutomationBanner, "gone with the last owner")
        XCTAssertEqual(webView.frame, webViewFrame)
        XCTAssertTrue(window.firstResponder === webView)
    }

    @MainActor func testOnlyTheCapsuleTakesClicksAndThePageGetsTheRest() async throws {
        let wc = makeWindow()
        let a = addTab("a")
        wc.selectTab(id: a.id)
        try await waitLoaded(a)
        a.attachAutomation(debuggerOwner)
        _ = registerDebuggerStop()
        wc.refreshAutomationBanners()
        let shown = try XCTUnwrap(banner(a))
        XCTAssertTrue(shown.showsStopButton)
        let container = try XCTUnwrap(a.webViewContainer)
        let webView = try XCTUnwrap(a.webView)
        wc.window?.layoutIfNeeded()

        // Under the window's drag strip, which lets the capsule's clicks through.
        let onStop = try hit(NSPoint(x: shown.stopButton.bounds.midX, y: shown.stopButton.bounds.midY),
                             in: shown.stopButton, of: wc)
        XCTAssertTrue(onStop?.isDescendant(of: shown.stopButton) == true, "hit \(String(describing: onStop))")
        let onCapsule = try hit(NSPoint(x: shown.frame.minX + 6, y: shown.frame.midY), in: container, of: wc)
        XCTAssertTrue(onCapsule?.isDescendant(of: shown) == true, "hit \(String(describing: onCapsule))")

        // Beside the capsule and below the strip: the page.
        let beside = try hit(NSPoint(x: shown.frame.minX - 40, y: shown.frame.minY - 60), in: container, of: wc)
        XCTAssertTrue(beside?.isDescendant(of: webView) == true, "hit \(String(describing: beside))")
        let below = try hit(NSPoint(x: shown.frame.midX, y: shown.frame.minY - 60), in: container, of: wc)
        XCTAssertTrue(below?.isDescendant(of: webView) == true, "hit \(String(describing: below))")
    }

    @MainActor func testStopEndsTheAttachmentThroughTheRegisteredHandlerAndTheCapsuleGoes() async throws {
        let calls = registerDebuggerStop()
        let wc = makeWindow()
        let window = try XCTUnwrap(wc.window)
        let a = addTab("a")
        wc.selectTab(id: a.id)
        try await waitLoaded(a)
        let webView = try XCTUnwrap(a.webView)
        let webViewFrame = webView.frame

        a.attachAutomation(debuggerOwner)
        a.attachAutomation(otherExtensionOwner)
        let shown = try XCTUnwrap(banner(a))
        XCTAssertEqual(shown.titleLabel.stringValue, "2 extensions are controlling this tab")
        XCTAssertTrue(shown.showsStopButton)

        shown.stopButton.performClick(nil)

        XCTAssertEqual(Set(calls()), [debuggerOwner, otherExtensionOwner], "every owner is stopped")
        XCTAssertTrue(a.automationOwners.isEmpty)
        XCTAssertFalse(a.webViewContainer?.isShowingAutomationBanner ?? true)
        XCTAssertTrue(window.firstResponder === webView, "pressing Stop leaves the keyboard with the page")
        XCTAssertEqual(webView.frame, webViewFrame)
    }

    @MainActor func testStopLeavesAnOwnerNothingCanStop() async throws {
        let calls = registerDebuggerStop()
        let wc = makeWindow()
        let a = addTab("a")
        wc.selectTab(id: a.id)
        a.attachAutomation(debuggerOwner)
        a.attachAutomation(commandOwner)
        let shown = try XCTUnwrap(banner(a))
        XCTAssertTrue(shown.showsStopButton)

        shown.stopButton.performClick(nil)

        XCTAssertEqual(calls(), [debuggerOwner])
        XCTAssertEqual(a.automationOwners, [commandOwner])
        XCTAssertTrue(a.webViewContainer?.isShowingAutomationBanner == true)
        XCTAssertFalse(shown.showsStopButton, "what is left cannot be stopped")
    }

    @MainActor func testAParkedTabShowsItsCapsuleWhenSelectedAndNotAfterItWasReleasedWhileParked() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        b.attachAutomation(debuggerOwner)
        XCTAssertTrue(b.isAutomationParked)
        wc.selectTab(id: b.id)
        XCTAssertEqual(b.automationHosting, .displayed)
        XCTAssertTrue(b.webViewContainer?.isShowingAutomationBanner == true)
        XCTAssertFalse(a.webViewContainer?.isShowingAutomationBanner ?? false)
        // The page has the frame it had without the capsule: a's, in the same
        // window (the dev toolbar, which 127.0.0.1 pages get, included).
        XCTAssertEqual(b.webView?.frame, a.webView?.frame, "the capsule does not resize the page being driven")

        // Parked again, then released while nobody shows it.
        wc.selectTab(id: a.id)
        XCTAssertTrue(b.isAutomationParked)
        XCTAssertFalse(b.webViewContainer?.isShowingAutomationBanner ?? true, "nobody sees a parked page")
        b.detachAutomation(debuggerOwner)
        wc.selectTab(id: b.id)
        XCTAssertFalse(b.webViewContainer?.isShowingAutomationBanner ?? false)
    }

    @MainActor func testInASplitOnlyTheDrivenPaneHasACapsule() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b"), c = addTab("c")
        TabStore.shared.createSplit(draggedTabID: c.id, targetTabID: b.id, edge: .right, in: space)
        wc.selectTab(id: a.id)
        b.attachAutomation(debuggerOwner)

        wc.selectTab(id: c.id)
        XCTAssertTrue(b.webViewContainer?.superview is NSSplitView)
        XCTAssertTrue(b.webViewContainer?.isShowingAutomationBanner == true)
        XCTAssertFalse(c.webViewContainer?.isShowingAutomationBanner ?? false)

        // The unfocused pane follows its owners too.
        c.attachAutomation(otherExtensionOwner)
        XCTAssertTrue(c.webViewContainer?.isShowingAutomationBanner == true)
        b.detachAutomation(debuggerOwner)
        XCTAssertFalse(b.webViewContainer?.isShowingAutomationBanner ?? true)
        XCTAssertTrue(c.webViewContainer?.isShowingAutomationBanner == true)
        c.detachAutomation(otherExtensionOwner)
    }

    // MARK: The sidebar

    @MainActor func testTheSidebarRowShowsTheIndicatorWhileTheTabIsDriven() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        wc.window?.layoutIfNeeded()
        XCTAssertFalse(try cell(forNormalTab: b, in: wc).isShowingAutomationIndicator)

        b.attachAutomation(debuggerOwner)
        try await waitUntil("the row shows the indicator") {
            try self.cell(forNormalTab: b, in: wc).isShowingAutomationIndicator
        }
        XCTAssertEqual(try cell(forNormalTab: b, in: wc).automationIndicator.toolTip, "Controlled by “ext-a”")
        XCTAssertFalse(try cell(forNormalTab: a, in: wc).isShowingAutomationIndicator)

        b.attachAutomation(otherExtensionOwner)
        try await waitUntil("the tooltip counts both extensions") {
            try self.cell(forNormalTab: b, in: wc).automationIndicator.toolTip == "Controlled by 2 extensions"
        }

        b.detachAutomation(debuggerOwner)
        b.detachAutomation(otherExtensionOwner)
        try await waitUntil("the indicator goes") {
            try !self.cell(forNormalTab: b, in: wc).isShowingAutomationIndicator
        }
    }

    @MainActor func testASplitRowShowsTheIndicatorWhenEitherPaneIsDriven() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b"), c = addTab("c")
        TabStore.shared.createSplit(draggedTabID: c.id, targetTabID: b.id, edge: .right, in: space)
        wc.selectTab(id: a.id)
        wc.window?.layoutIfNeeded()
        XCTAssertFalse(try cell(forNormalTab: b, in: wc).isShowingAutomationIndicator)

        c.attachAutomation(debuggerOwner)
        try await waitUntil("the split row shows the indicator") {
            try self.cell(forNormalTab: b, in: wc).isShowingAutomationIndicator
        }
        c.detachAutomation(debuggerOwner)
        try await waitUntil("the indicator goes") {
            try !self.cell(forNormalTab: b, in: wc).isShowingAutomationIndicator
        }
    }

    @MainActor func testAPinnedRowShowsTheIndicator() async throws {
        let wc = makeWindow()
        let a = addTab("a"), b = addTab("b")
        wc.selectTab(id: a.id)
        TabStore.shared.pinTab(id: b.id, in: space)
        let entryIndex = try XCTUnwrap(space.pinnedEntries.firstIndex { $0.tab === b })
        wc.window?.layoutIfNeeded()
        let sidebar = wc.tabSidebar
        func pinnedCell() throws -> TabCellView {
            let flat = try XCTUnwrap(sidebar.flattenedPinnedItems.firstIndex {
                $0.contains(entryID: self.space.pinnedEntries[entryIndex].id)
            })
            return try XCTUnwrap(sidebar.tableView.view(atColumn: 0, row: sidebar.rowForPinnedItem(at: flat),
                                                        makeIfNecessary: true) as? TabCellView)
        }
        XCTAssertFalse(try pinnedCell().isShowingAutomationIndicator)

        b.attachAutomation(debuggerOwner)
        try await waitUntil("the pinned row shows the indicator") { try pinnedCell().isShowingAutomationIndicator }
        b.detachAutomation(debuggerOwner)
        try await waitUntil("the indicator goes") { try !pinnedCell().isShowingAutomationIndicator }
    }
}
