import XCTest
import WebKit
@testable import Detour

/// Open in <Space> (TASK-193.3) in real windows: the button and Cmd+O move a
/// Quick Detour's page into a tab of a space, placed by the Link Routes
/// placement rule (a window showing the space comes forward, else the most recent
/// normal window switches to it, else a new window), and close the Quick
/// Detour window; the dropdown picks another space, reloading the address in
/// another profile's; a Private one goes to a Private window. The teardown
/// order: the Quick Detour controller is released, the handed-over web view is
/// not.
///
/// The shared store and `AppDelegate`, with profiles and spaces of the test's
/// own; pages from a loopback server, or `.invalid` hosts that never resolve.
@MainActor
final class QuickDetourOpenInWindowTests: XCTestCase {

    private var appDelegate: AppDelegate!
    private var store: TabStore { .shared }
    private var windowsBefore: Set<ObjectIdentifier> = []
    private var quickDetours: [QuickDetourWindowController] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var previousLastActiveSpaceID: UUID?
    private static var retainedProfiles: [Profile] = []

    private var profile: Profile!
    private var inbox: Space!
    private var build: Space!

    override func setUpWithError() throws {
        try super.setUpWithError()
        appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        windowsBefore = Set(browserWindows().map(ObjectIdentifier.init))
        previousLastActiveSpaceID = store.lastActiveSpaceID
        profile = makeProfile("Open In Work")
        inbox = addSpace("Inbox", "📥", profile)
        build = addSpace("Build", "🔨", profile)
    }

    override func tearDown() async throws {
        for controller in quickDetours { controller.close() }
        quickDetours.removeAll()
        for wc in browserWindows() where !windowsBefore.contains(ObjectIdentifier(wc)) {
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
        // A test's Private windows are closed above; their spaces go with them.
        for profile in createdProfiles {
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        store.lastActiveSpaceID = previousLastActiveSpaceID
        store.undoManager.removeAllActions()
        for server in servers { server.stop() }
        servers.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeProfile(_ name: String) -> Profile {
        let profile = store.addProfile(name: "\(name) \(UUID().uuidString.prefix(4))")
        createdProfiles.append(profile)
        return profile
    }

    private func addSpace(_ name: String, _ emoji: String, _ profile: Profile) -> Space {
        let space = store.addSpace(name: name, emoji: emoji, colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    private func browserWindows() -> [BrowserWindowController] {
        NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            .filter { $0.window?.isVisible == true }
    }

    private func newBrowserWindows() -> [BrowserWindowController] {
        browserWindows().filter { !windowsBefore.contains(ObjectIdentifier($0)) }
    }

    /// A normal window on `space`, in front of the others.
    @discardableResult
    private func makeWindow(showing space: Space) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        appDelegate.registerWindowController(wc)
        return wc
    }

    @discardableResult
    private func makePrivateWindow() -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: true)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        appDelegate.registerWindowController(wc)
        return wc
    }

    private func openQuickDetour(on profile: Profile, from source: Space? = nil,
                                 url: URL = URL(string: "https://open-in.invalid/")!) -> QuickDetourWindowController {
        let controller = QuickDetourWindowController.open(profile: profile, sourceSpace: source, url: url)
        quickDetours.append(controller)
        return controller
    }

    private func serve() async throws -> URL {
        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>First</title></head><body>first</body></html>",
            "/second": "<html><head><title>Second</title></head><body><input id=q></body></html>",
        ])
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func frontBrowserWindow() -> BrowserWindowController? {
        NSApp.browserWindowControllersFrontToBack.first
    }

    private func isOpen(_ controller: QuickDetourWindowController) -> Bool {
        QuickDetourWindowController.openControllers.contains { $0 === controller }
    }

    // MARK: - The button

    func testTheButtonNamesTheSourceSpace() {
        let controller = openQuickDetour(on: profile, from: build)

        XCTAssertFalse(controller.titleBar.openInControl.isHidden)
        XCTAssertEqual(controller.titleBar.openInButton.attributedTitle.string, "Open in 🔨 Build  ⌘O")
        XCTAssertFalse(controller.titleBar.openInMenuButton.isHidden, "a dropdown for a normal profile")
        XCTAssertEqual(controller.openInMenu.defaultTarget, .space(build.id))
    }

    func testADeletedSourceSpaceFallsBackToTheProfilesMostRecent() {
        let controller = openQuickDetour(on: profile, from: build)
        store.noteSpaceUsed(inbox.id)

        XCTAssertEqual(store.deleteSpace(id: build.id), .deleted)

        XCTAssertEqual(controller.openInMenu.defaultTarget, .space(inbox.id))
        XCTAssertEqual(controller.titleBar.openInButton.attributedTitle.string, "Open in 📥 Inbox  ⌘O",
                       "the button follows the store")
    }

    func testCmdOIsTheFileMenusItemWhileAQuickDetourIsKey() throws {
        let controller = openQuickDetour(on: profile, from: build)
        let item = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first {
            $0.action == #selector(QuickDetourWindowController.openInDefaultSpace(_:))
        }, "File > Open Quick Detour in Space")
        XCTAssertEqual(item.keyEquivalent, "o")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)

        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Open in 🔨 Build")
        QuickDetourWindowController.resetOpenInMenuItemTitle()
        XCTAssertEqual(item.title, QuickDetourWindowController.openInMenuItemTitle)
    }

    // MARK: - The same profile: the page moves intact

    func testCmdOMovesThePageIntoTheWindowShowingTheSpace() async throws {
        let base = try await serve()
        let buildWindow = makeWindow(showing: build)
        let inboxWindow = makeWindow(showing: inbox)   // in front
        let controller = openQuickDetour(on: profile, from: build, url: base)
        let page = try XCTUnwrap(controller.tab)
        let webView = try XCTUnwrap(page.webView)
        try await waitUntil("the first page") { page.title == "First" && !page.isLoading }
        page.load(base.appendingPathComponent("second"))
        try await waitUntil("the second page") { page.title == "Second" && !page.isLoading }
        _ = try await webView.evaluateJavaScript("document.getElementById('q').value = 'typed text'; 1")

        controller.openInDefaultSpace(nil)

        XCTAssertFalse(isOpen(controller), "the Quick Detour window closed")
        XCTAssertFalse(controller.window?.isVisible ?? false)
        XCTAssertTrue(build.tabs.first === page, "the same tab, at the new-tab position")
        XCTAssertEqual(buildWindow.selectedTabID, page.id, "selected in the window showing Build")
        XCTAssertTrue(frontBrowserWindow() === buildWindow, "which comes forward")
        XCTAssertEqual(inboxWindow.activeSpaceID, inbox.id, "the other window is left alone")
        XCTAssertTrue(page.webView === webView, "the same web view")
        XCTAssertTrue(webView.window === buildWindow.window, "hosted by the browser window")
        XCTAssertTrue(webView.navigationDelegate === buildWindow)
        XCTAssertTrue(webView.uiDelegate === buildWindow)
        XCTAssertTrue(webView.canGoBack, "the back/forward list survives")
        XCTAssertEqual(webView.backForwardList.backItem?.url, base)
        let typed = try await webView.evaluateJavaScript("document.getElementById('q').value") as? String
        XCTAssertEqual(typed, "typed text", "form state survives")
        XCTAssertFalse(store.isQuickDetourTab(page))
        XCTAssertTrue(AppDatabase.shared.closedTabSummaries(
            spaceID: QuickDetour.historySpaceIDString(forProfileID: profile.id)).isEmpty,
                      "moved, not closed: nothing goes to the archive (TASK-193.5)")
    }

    func testTheButtonDoesWhatCmdODoes() throws {
        let buildWindow = makeWindow(showing: build)
        let controller = openQuickDetour(on: profile, from: build)
        let page = try XCTUnwrap(controller.tab)

        controller.titleBar.openInButton.performClick(nil)

        XCTAssertFalse(isOpen(controller))
        XCTAssertEqual(buildWindow.selectedTabID, page.id)
    }

    func testWithNoWindowOnTheSpaceTheMostRecentNormalWindowSwitches() throws {
        let window = makeWindow(showing: inbox)
        let controller = openQuickDetour(on: profile, from: build)
        let page = try XCTUnwrap(controller.tab)

        controller.open(in: .space(build.id))

        XCTAssertEqual(window.activeSpaceID, build.id, "switched to Build")
        XCTAssertEqual(window.selectedTabID, page.id)
        XCTAssertTrue(page.webView?.window === window.window)
        XCTAssertTrue(newBrowserWindows().allSatisfy { $0 === window }, "no new window")
    }

    func testTheDropdownCanPickAnotherSpaceOfTheProfile() throws {
        let inboxWindow = makeWindow(showing: inbox)
        let controller = openQuickDetour(on: profile, from: build)
        let page = try XCTUnwrap(controller.tab)

        let menu = controller.makeOpenInMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == "📥 Inbox" })
        menu.performActionForItem(at: menu.index(of: item))

        XCTAssertTrue(inbox.tabs.first === page)
        XCTAssertEqual(inboxWindow.selectedTabID, page.id)
        XCTAssertFalse(isOpen(controller))
    }

    func testAnOpenPaletteAndFindBarGoWithTheWindow() throws {
        let buildWindow = makeWindow(showing: build)
        let controller = openQuickDetour(on: profile, from: build)
        let page = try XCTUnwrap(controller.tab)
        controller.showPalette(prefill: nil)
        controller.showFindBar(nil)

        controller.openInDefaultSpace(nil)

        XCTAssertNil(controller.commandPaletteView)
        XCTAssertEqual(buildWindow.selectedTabID, page.id)
        XCTAssertTrue(page.webView?.window === buildWindow.window)
    }

    /// The teardown order: the Quick Detour is told nothing that tears the
    /// page down, and lets go of everything — its controller is released while
    /// the web view lives on in the browser window.
    func testTheQuickDetourIsReleasedAndTheHandedOverWebViewIsNot() throws {
        let buildWindow = makeWindow(showing: build)
        weak var weakController: QuickDetourWindowController?
        weak var weakWebView: WKWebView?
        var pageID: UUID?
        autoreleasepool {
            let controller = QuickDetourWindowController.open(profile: profile, sourceSpace: build,
                                                              url: URL(string: "https://open-in.invalid/")!)
            weakController = controller
            weakWebView = controller.tab?.webView
            pageID = controller.tabID
            controller.openInDefaultSpace(nil)
        }
        for _ in 0..<40 where weakController != nil { spin() }

        XCTAssertNil(weakController, "the Quick Detour window controller is released")
        XCTAssertNotNil(weakWebView, "the web view is not: the tab in Build holds it")
        XCTAssertTrue(build.tabs.first?.webView === weakWebView)
        XCTAssertEqual(build.tabs.first?.id, pageID)
        XCTAssertTrue(weakWebView?.window === buildWindow.window)
        XCTAssertNil(QuickDetourWindowController.controller(forTabID: pageID ?? UUID()))
    }

    // MARK: - Another profile: the address reloads there

    func testAnotherProfilesSpaceReloadsTheAddressThere() throws {
        let url = URL(string: "https://open-in-reload.invalid/page?q=1")!
        let other = makeProfile("Open In Home")
        let fun = addSpace("Fun", "🎉", other)
        let funWindow = makeWindow(showing: fun)
        weak var weakController: QuickDetourWindowController?
        weak var weakOldWebView: WKWebView?
        var pageID: UUID?
        autoreleasepool {
            let controller = QuickDetourWindowController.open(profile: profile, sourceSpace: build, url: url)
            weakController = controller
            let page = controller.tab
            pageID = page?.id
            weakOldWebView = page?.webView

            controller.open(in: .space(fun.id))

            XCTAssertFalse(isOpen(controller), "the Quick Detour window closed")
            XCTAssertNil(page?.webView, "its page went with it")
        }

        let opened = try XCTUnwrap(fun.tabs.first, "a new tab in Fun")
        XCTAssertNotEqual(opened.id, pageID, "a new tab, not the Quick Detour's")
        XCTAssertEqual(opened.url, url, "the same address")
        XCTAssertTrue(opened.webView?.configuration.websiteDataStore === other.dataStore,
                      "the other profile's data store")
        XCTAssertEqual(funWindow.selectedTabID, opened.id)
        XCTAssertTrue(frontBrowserWindow() === funWindow)
        XCTAssertFalse(build.tabs.contains { $0.id == pageID })
        XCTAssertTrue(AppDatabase.shared.closedTabSummaries(
            spaceID: QuickDetour.historySpaceIDString(forProfileID: profile.id)).isEmpty,
                      "moved, not closed: nothing goes to the archive (TASK-193.5)")
        for _ in 0..<40 where weakController != nil || weakOldWebView != nil { spin() }
        XCTAssertNil(weakController)
        XCTAssertNil(weakOldWebView, "the Quick Detour's web view is released")
    }

    func testTheDropdownGroupsByProfileAndMarksTheReloads() throws {
        let other = makeProfile("Open In Home")
        _ = addSpace("Fun", "🎉", other)
        let controller = openQuickDetour(on: profile, from: build)

        let menu = controller.makeOpenInMenu()

        let headers = menu.items.filter(\.isSectionHeader).map(\.title)
        XCTAssertEqual(headers.first, profile.name, "the window's profile first")
        XCTAssertTrue(headers.contains(other.name))
        let inboxItem = try XCTUnwrap(menu.items.first { $0.title == "📥 Inbox" })
        let buildItem = try XCTUnwrap(menu.items.first { $0.title == "🔨 Build" })
        let funItem = try XCTUnwrap(menu.items.first { $0.title == "🎉 Fun" })
        XCTAssertNil(inboxItem.toolTip, "the same profile's spaces keep the page")
        XCTAssertNotNil(funItem.toolTip, "another profile's say in their tooltip that they reload")
        XCTAssertNil(funItem.subtitle, "with no subtitle under the name (TASK-210)")
        XCTAssertEqual(buildItem.keyEquivalent, "o", "the default target carries Cmd+O")
        XCTAssertEqual(inboxItem.keyEquivalent, "")
        XCTAssertLessThan(menu.index(of: buildItem), menu.index(of: funItem))
    }

    // MARK: - Private

    func testAPrivateQuickDetourMovesIntoTheMostRecentPrivateWindow() throws {
        let privateProfile = store.ensureIncognitoProfile()
        let older = makePrivateWindow()
        let recent = makePrivateWindow()
        let controller = openQuickDetour(on: privateProfile)
        let page = try XCTUnwrap(controller.tab)
        let webView = try XCTUnwrap(page.webView)
        XCTAssertEqual(controller.titleBar.openInButton.attributedTitle.string, "Open in Private Window  ⌘O")
        XCTAssertTrue(controller.titleBar.openInMenuButton.isHidden, "no dropdown")

        controller.openInDefaultSpace(nil)

        XCTAssertFalse(isOpen(controller))
        XCTAssertEqual(recent.selectedTabID, page.id)
        XCTAssertTrue(recent.activeSpace?.tabs.first === page)
        XCTAssertNil(older.activeSpace?.tabs.first { $0.id == page.id })
        XCTAssertTrue(page.webView === webView, "intact: no reload")
        XCTAssertTrue(webView.configuration.websiteDataStore === privateProfile.dataStore)
        XCTAssertTrue(webView.window === recent.window)
        XCTAssertTrue(store.hasLivePrivateSession)
    }

    func testWithNoPrivateWindowANewOneOpens() throws {
        let privateProfile = store.ensureIncognitoProfile()
        let controller = openQuickDetour(on: privateProfile)
        let page = try XCTUnwrap(controller.tab)

        controller.open(in: .privateWindow)

        let opened = try XCTUnwrap(newBrowserWindows().first { $0.isIncognito }, "a new Private window")
        XCTAssertEqual(opened.selectedTabID, page.id)
        XCTAssertEqual(opened.activeSpace?.tabs.map(\.id), [page.id], "with only the page, no empty tab")
        XCTAssertTrue(page.webView?.window === opened.window)
    }

    func testANormalQuickDetourCannotOpenInAPrivateWindowNorAPrivateOneInASpace() throws {
        let buildWindow = makeWindow(showing: build)
        let normal = openQuickDetour(on: profile, from: build)
        normal.open(in: .privateWindow)
        XCTAssertTrue(isOpen(normal), "refused: a normal page never enters a Private window")

        let privateQuick = openQuickDetour(on: store.ensureIncognitoProfile())
        privateQuick.open(in: .space(build.id))
        XCTAssertTrue(isOpen(privateQuick), "refused: a Private page never reaches a profile's space")
        XCTAssertNil(buildWindow.selectedTabID.flatMap { id in build.tabs.first { $0.id == id } })
    }

    // MARK: - A sheet on the window

    private func openInItem() throws -> NSMenuItem {
        try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first {
            $0.action == #selector(QuickDetourWindowController.openInDefaultSpace(_:))
        })
    }

    /// A sheet (an alert, a file panel, a sign-in prompt) is waiting on the
    /// page: Open in neither validates nor moves it, and does once it is gone.
    func testASheetOnTheWindowBlocksOpenInUntilItEnds() throws {
        let buildWindow = makeWindow(showing: build)
        let controller = openQuickDetour(on: profile, from: build)
        let page = try XCTUnwrap(controller.tab)
        let window = try XCTUnwrap(controller.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        window.beginSheet(sheet)
        for _ in 0..<20 where window.attachedSheet == nil { spin() }
        XCTAssertNotNil(window.attachedSheet)

        let item = try openInItem()
        XCTAssertFalse(controller.validateMenuItem(item), "Cmd+O disabled while the sheet is up")
        controller.open(in: .space(build.id))
        controller.openInDefaultSpace(nil)
        XCTAssertTrue(isOpen(controller), "nothing moved")
        XCTAssertTrue(store.isQuickDetourTab(page))
        XCTAssertFalse(build.tabs.contains { $0 === page })

        window.endSheet(sheet)
        for _ in 0..<20 where window.attachedSheet != nil { spin() }
        XCTAssertTrue(controller.validateMenuItem(item))
        controller.openInDefaultSpace(nil)
        XCTAssertFalse(isOpen(controller))
        XCTAssertEqual(buildWindow.selectedTabID, page.id)
    }

    /// The case the guard is for: a page's `alert()` runs as a sheet whose
    /// completion WebKit is waiting on; moving the page from under it crashed.
    func testAPageAlertBlocksOpenInUntilItIsDismissed() async throws {
        let base = try await serve()
        let buildWindow = makeWindow(showing: build)
        let controller = openQuickDetour(on: profile, from: build, url: base)
        let page = try XCTUnwrap(controller.tab)
        let window = try XCTUnwrap(controller.window)
        try await waitUntil("the page") { page.title == "First" && !page.isLoading }
        _ = try await page.webView?.evaluateJavaScript("setTimeout(() => alert('Hello from the page'), 0); 1")
        try await waitUntil("the alert sheet") { window.attachedSheet != nil }

        let item = try openInItem()
        XCTAssertFalse(controller.validateMenuItem(item))
        controller.openInDefaultSpace(nil)
        XCTAssertTrue(isOpen(controller), "the page stays while its alert is up")
        XCTAssertTrue(store.isQuickDetourTab(page))

        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await waitUntil("the alert to go") { window.attachedSheet == nil }
        XCTAssertTrue(controller.validateMenuItem(item))
        controller.openInDefaultSpace(nil)
        XCTAssertFalse(isOpen(controller))
        XCTAssertEqual(buildWindow.selectedTabID, page.id)
        let alive = try await page.webView?.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(alive, "First", "the page answers in its new window")
    }

    // MARK: - "Most recently used"

    func testABrowserWindowSwitchingSpaceNotesItsUse() {
        let window = makeWindow(showing: inbox)
        window.setActiveSpace(id: build.id)
        XCTAssertEqual(store.spaceUseOrder.first, build.id)
        window.setActiveSpace(id: inbox.id)
        XCTAssertEqual(store.spaceUseOrder.prefix(2), [inbox.id, build.id])
    }
}
