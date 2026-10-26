import XCTest
import WebKit
@testable import Detour

/// The profile pill (TASK-193.4) in real windows: it names the window's
/// profile; its menu lists the profiles with Private last and the window's
/// own checked; choosing another reloads the page's address in a new web view
/// on that profile's data store, in the same window — that profile's cookies,
/// its history scope, its spaces in Open in, its Private rules — and asks
/// before leaving Private would cancel a Private download.
///
/// The shared store, with profiles and spaces of the test's own; pages from a
/// loopback server (one reads a cookie the other sets), or `.invalid` hosts
/// that never resolve.
@MainActor
final class QuickDetourProfileSwitchWindowTests: XCTestCase {

    private var store: TabStore { .shared }
    private var quickDetours: [QuickDetourWindowController] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var addedDownloads: [DownloadItem] = []
    private var previousAlert: ((PrivateDownloadClosePolicy.Prompt) -> Bool)!
    private static var retainedProfiles: [Profile] = []

    private var work: Profile!
    private var home: Profile!
    private var workSpace: Space!
    private var homeSpace: Space!

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousAlert = QuickDetourWindowController.runProfileSwitchAlert
        QuickDetourWindowController.runProfileSwitchAlert = { _ in
            XCTFail("no question expected")
            return false
        }
        work = makeProfile("Switch Work")
        home = makeProfile("Switch Home")
        workSpace = addSpace("Desk", "💼", work)
        homeSpace = addSpace("Sofa", "🛋️", home)
    }

    override func tearDown() async throws {
        QuickDetourWindowController.runProfileSwitchAlert = previousAlert
        for controller in quickDetours { controller.close() }
        quickDetours.removeAll()
        for item in addedDownloads { DownloadManager.shared.removeDownload(item) }
        addedDownloads.removeAll()
        for id in createdSpaceIDs {
            if let space = store.space(withID: id) {
                for tab in space.tabs { tab.teardown() }
            }
            store.forceRemoveSpace(id: id)
        }
        createdSpaceIDs.removeAll()
        for profile in createdProfiles {
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
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

    private var privateProfile: Profile { store.ensureIncognitoProfile() }

    private func openQuickDetour(on profile: Profile, from source: Space? = nil,
                                 url: URL = URL(string: "https://profile-switch.invalid/")!) -> QuickDetourWindowController {
        let controller = QuickDetourWindowController.open(profile: profile, sourceSpace: source, url: url)
        quickDetours.append(controller)
        return controller
    }

    /// `/` is titled by whether the `qd` cookie is set; `/login` sets it.
    private func serve() async throws -> (LoopbackHTTPServer, URL) {
        let server = try LoopbackHTTPServer(routes: [
            "/": """
            <html><head><script>
            document.title = document.cookie.includes('qd=signed-in') ? 'Signed in' : 'Signed out';
            </script></head><body>cookie probe</body></html>
            """,
            "/login": """
            <html><head><script>
            document.cookie = 'qd=signed-in; path=/; max-age=3600';
            document.title = 'Logged in';
            </script></head><body>logged in</body></html>
            """,
        ], stalled: ["/slow": "<html><head><title>Slow</title></head><body>slow</body></html>"])
        servers.append(server)
        let port = try await server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)/")!)
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func isOpen(_ controller: QuickDetourWindowController) -> Bool {
        QuickDetourWindowController.openControllers.contains { $0 === controller }
    }

    private func waitForTitle(_ title: String, in controller: QuickDetourWindowController) async throws {
        try await waitUntil("the page titled \(title)", timeout: 10) {
            controller.tab?.title == title && controller.tab?.isLoading == false
        }
    }

    // MARK: - The pill and its menu

    func testThePillNamesTheWindowsProfile() {
        let controller = openQuickDetour(on: work)

        XCTAssertEqual(controller.titleBar.profileName, work.name)
    }

    func testTheMenuListsTheProfilesWithPrivateLastAndTheWindowsChecked() throws {
        _ = privateProfile
        let controller = openQuickDetour(on: home)

        let menu = controller.makeProfileMenu()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)

        let workIndex = try XCTUnwrap(titles.firstIndex(of: work.name))
        let homeIndex = try XCTUnwrap(titles.firstIndex(of: home.name))
        XCTAssertLessThan(workIndex, homeIndex, "in the store's order")
        XCTAssertEqual(menu.items.last?.title, privateProfile.name, "Private last")
        XCTAssertEqual(menu.items.dropLast().last?.isSeparatorItem, true, "after a separator")
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), [home.name], "the window's own checked")
        XCTAssertEqual(controller.profileMenu.items.filter(\.isChecked).map(\.profileID), [home.id])
    }

    func testChoosingAMenuItemSwitches() throws {
        let controller = openQuickDetour(on: work)
        let menu = controller.makeProfileMenu()
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == home.name })

        menu.performActionForItem(at: index)

        XCTAssertTrue(controller.profile === home)
        XCTAssertTrue(controller.tab?.quickDetourProfile === home)
        XCTAssertEqual(controller.titleBar.profileName, home.name)
    }

    // MARK: - Switching

    func testSwitchingReloadsTheAddressUnderTheOtherProfilesCookies() async throws {
        let (_, base) = try await serve()
        let controller = openQuickDetour(on: work, url: base.appendingPathComponent("login"))
        try await waitForTitle("Logged in", in: controller)
        controller.load(base, typed: true)
        try await waitForTitle("Signed in", in: controller)
        let oldID = controller.tabID
        weak var oldWebView = controller.tab?.webView
        let window = controller.window

        XCTAssertTrue(controller.switchProfile(to: home))

        XCTAssertTrue(isOpen(controller), "the same window stays")
        XCTAssertTrue(controller.window === window)
        XCTAssertNotEqual(controller.tabID, oldID, "a new page")
        XCTAssertNil(store.quickDetourTab(withID: oldID), "the old page is gone")
        let page = try XCTUnwrap(controller.tab)
        XCTAssertTrue(page.quickDetourProfile === home)
        XCTAssertTrue(page.webView?.configuration.websiteDataStore === home.dataStore)
        XCTAssertTrue(page.webView?.window === window, "hosted in this window")
        XCTAssertTrue(page.webView?.navigationDelegate === controller)
        XCTAssertEqual(page.url, base)
        try await waitForTitle("Signed out", in: controller)
        XCTAssertFalse(page.canGoBack, "a fresh web view: no back history")
        for _ in 0..<40 where oldWebView != nil { spin() }
        XCTAssertNil(oldWebView, "the old web view is released")

        XCTAssertTrue(controller.switchProfile(to: work))
        try await waitForTitle("Signed in", in: controller)
    }

    func testTheSameProfileIsANoOp() {
        let controller = openQuickDetour(on: work)
        let id = controller.tabID
        let webView = controller.tab?.webView

        XCTAssertFalse(controller.switchProfile(to: work))

        XCTAssertEqual(controller.tabID, id)
        XCTAssertTrue(controller.tab?.webView === webView)
    }

    func testASheetBlocksTheSwitch() throws {
        let controller = openQuickDetour(on: work)
        let window = try XCTUnwrap(controller.window)
        let id = controller.tabID
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        window.beginSheet(sheet)
        defer { window.endSheet(sheet) }

        XCTAssertFalse(controller.switchProfile(to: home), "a sheet's completion would outlive its web view")
        XCTAssertEqual(controller.tabID, id)
    }

    func testAPageMidLoadReloadsItsAddress() async throws {
        let (server, base) = try await serve()
        let slow = base.appendingPathComponent("slow")
        let controller = openQuickDetour(on: work, url: slow)
        XCTAssertEqual(controller.tab?.isLoading, true)
        try await waitUntil("the first request to arrive", timeout: 10) {
            server.requestedPaths.contains("/slow")
        }
        XCTAssertEqual(controller.tab?.isLoading, true, "still loading: the server holds the response")

        XCTAssertTrue(controller.switchProfile(to: home))
        XCTAssertEqual(controller.tab?.url, slow, "the address being loaded")
        try await waitUntil("the new request to arrive", timeout: 10) {
            server.requestedPaths.filter { $0 == "/slow" }.count >= 2
        }
        server.release("/slow")
        try await waitForTitle("Slow", in: controller)
    }

    func testAnInternalPageReloadsAsAnInternalPage() async throws {
        let controller = openQuickDetour(on: work)
        controller.load(InternalPage.history.url, typed: true)
        try await waitUntil("the History page", timeout: 10) {
            controller.tab?.webView?.url?.scheme == InternalPage.scheme && controller.tab?.isLoading == false
        }

        XCTAssertTrue(controller.switchProfile(to: home))

        try await waitUntil("the History page on the other profile", timeout: 10) {
            controller.tab?.webView?.url?.scheme == InternalPage.scheme && controller.tab?.isLoading == false
        }
        XCTAssertEqual(controller.tab?.url, InternalPage.history.url)
        XCTAssertTrue(controller.tab?.quickDetourProfile === home)
    }

    func testThePaletteAndFindBarCloseOnASwitch() {
        let controller = openQuickDetour(on: work)
        controller.showPalette(prefill: nil)
        XCTAssertNotNil(controller.commandPaletteView)

        XCTAssertTrue(controller.switchProfile(to: home))

        XCTAssertNil(controller.commandPaletteView)
        XCTAssertTrue(controller.findBar.isHidden)
    }

    // MARK: - Open in follows the profile

    func testOpenInFollowsTheNewProfile() {
        let controller = openQuickDetour(on: work, from: workSpace)
        XCTAssertEqual(controller.openInMenu.defaultTarget, .space(workSpace.id))

        XCTAssertTrue(controller.switchProfile(to: home))

        XCTAssertEqual(controller.openInMenu.defaultTarget, .space(homeSpace.id),
                       "the source space is another profile's now: the new profile's most recent")
        XCTAssertEqual(controller.openInMenu.sections.first?.profileID, home.id, "its spaces first")
        XCTAssertEqual(controller.titleBar.openInButton.attributedTitle.string, "Open in 🛋️ Sofa  ⌘O")

        XCTAssertTrue(controller.switchProfile(to: work))
        XCTAssertEqual(controller.openInMenu.defaultTarget, .space(workSpace.id), "the source space again")
    }

    // MARK: - Private

    func testSwitchingIntoPrivateMakesItAPrivateQuickDetour() throws {
        let controller = openQuickDetour(on: work, from: workSpace)

        XCTAssertTrue(controller.switchProfile(to: privateProfile))

        let page = try XCTUnwrap(controller.tab)
        XCTAssertTrue(page.webView?.configuration.websiteDataStore === privateProfile.dataStore)
        XCTAssertEqual(controller.window?.appearance?.name, .darkAqua)
        XCTAssertEqual(controller.titleBar.profileName, privateProfile.name)
        XCTAssertEqual(controller.openInMenu.defaultTarget, .privateWindow)
        XCTAssertEqual(controller.downloadScope, .incognito(spaceID: page.id))
        XCTAssertTrue(store.hasLivePrivateSession)
    }

    func testLeavingPrivateRestoresTheNormalWindow() throws {
        let controller = openQuickDetour(on: privateProfile)
        XCTAssertEqual(controller.window?.appearance?.name, .darkAqua)

        XCTAssertTrue(controller.switchProfile(to: work))

        XCTAssertNil(controller.window?.appearance, "the app's appearance again")
        XCTAssertEqual(controller.downloadScope, .normal)
        XCTAssertEqual(controller.openInMenu.defaultTarget, .space(workSpace.id))
    }

    func testLeavingPrivateWithADownloadRunningAsksAndKeepsEverythingOnNo() throws {
        let controller = openQuickDetour(on: privateProfile)
        let id = controller.tabID
        let item = DownloadManager.shared.addManualItem(filename: "secret.zip",
                                                        sourceURL: URL(string: "https://example.com/s.zip"),
                                                        scope: .incognito(spaceID: id))
        addedDownloads.append(item)
        var asked: [PrivateDownloadClosePolicy.Prompt] = []
        QuickDetourWindowController.runProfileSwitchAlert = { asked.append($0); return false }

        XCTAssertFalse(controller.switchProfile(to: work))

        XCTAssertEqual(asked.map(\.messageText), ["Switch to \(work.name)?"])
        XCTAssertEqual(controller.tabID, id, "still the Private page")
        XCTAssertTrue(controller.profile === privateProfile)
        XCTAssertEqual(item.state, .downloading, "Continue Downloading")
    }

    func testLeavingPrivateWithADownloadRunningCancelsItOnYes() throws {
        let controller = openQuickDetour(on: privateProfile)
        let item = DownloadManager.shared.addManualItem(filename: "secret.zip",
                                                        sourceURL: URL(string: "https://example.com/s.zip"),
                                                        scope: .incognito(spaceID: controller.tabID))
        addedDownloads.append(item)
        var asked = 0
        QuickDetourWindowController.runProfileSwitchAlert = { _ in asked += 1; return true }

        XCTAssertTrue(controller.switchProfile(to: work))

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertFalse(DownloadManager.shared.items.contains { $0 === item }, "dropped with the Private page")
        XCTAssertTrue(controller.profile === work)
    }

    func testATargetDeletedWhileAskingRefusesTheSwitchAndKeepsTheDownload() throws {
        let controller = openQuickDetour(on: privateProfile)
        let id = controller.tabID
        let item = DownloadManager.shared.addManualItem(filename: "secret.zip",
                                                        sourceURL: URL(string: "https://example.com/s.zip"),
                                                        scope: .incognito(spaceID: id))
        addedDownloads.append(item)
        let target = work!
        QuickDetourWindowController.runProfileSwitchAlert = { _ in
            target.isDeleted = true
            return true
        }
        defer { target.isDeleted = false }

        XCTAssertFalse(controller.switchProfile(to: target))

        XCTAssertEqual(controller.tabID, id, "still the Private page")
        XCTAssertTrue(controller.profile === privateProfile)
        XCTAssertEqual(item.state, .downloading, "nothing cancelled for a switch that did not happen")
    }

    func testASheetPutUpWhileAskingRefusesTheSwitch() throws {
        let controller = openQuickDetour(on: privateProfile)
        let window = try XCTUnwrap(controller.window)
        let id = controller.tabID
        let item = DownloadManager.shared.addManualItem(filename: "secret.zip",
                                                        sourceURL: URL(string: "https://example.com/s.zip"),
                                                        scope: .incognito(spaceID: id))
        addedDownloads.append(item)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        QuickDetourWindowController.runProfileSwitchAlert = { _ in
            window.beginSheet(sheet)
            return true
        }
        defer { window.endSheet(sheet) }

        XCTAssertFalse(controller.switchProfile(to: work), "a sheet's completion would outlive its web view")

        XCTAssertEqual(controller.tabID, id)
        XCTAssertEqual(item.state, .downloading)
    }

    // MARK: - Teardown

    func testTheWindowStillClosesCleanlyAfterASwitch() {
        weak var weakController: QuickDetourWindowController?
        var tabID: UUID?
        autoreleasepool {
            let controller = QuickDetourWindowController.open(profile: work, url: URL(string: "https://profile-switch.invalid/")!)
            weakController = controller
            XCTAssertTrue(controller.switchProfile(to: home))
            tabID = controller.tabID
            controller.close()
        }
        for _ in 0..<40 where weakController != nil { spin() }

        XCTAssertNil(weakController)
        XCTAssertNil(store.quickDetourTab(withID: tabID ?? UUID()), "the new page closed with the window")
    }
}
