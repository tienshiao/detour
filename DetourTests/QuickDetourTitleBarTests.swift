import XCTest
import WebKit
@testable import Detour

/// The Quick Detour bar after TASK-210: its page settings are the main
/// window's site settings acting on the Quick Detour's page and profile; the
/// host and Open in's main part drag the window once a press moves, and are
/// buttons otherwise; the palette asks for a search or a URL. TASK-322: the
/// back button, the capsule's empty space opening the palette, and its load
/// progress.
///
/// The shared store with profiles of the test's own; pages from a loopback
/// server. The bar button gets its events from the application's queue, as
/// its tracking loop reads them.
nonisolated final class QuickDetourTitleBarTests: XCTestCase {

    @MainActor private var store: TabStore { .shared }
    private var quickDetours: [QuickDetourWindowController] = []
    private var createdProfiles: [Profile] = []
    private var servers: [LoopbackHTTPServer] = []
    private var windows: [NSWindow] = []
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func tearDown() async throws {
        for controller in quickDetours { controller.close() }
        quickDetours.removeAll()
        for window in windows { window.close() }
        windows.removeAll()
        for profile in createdProfiles {
            for host in ContentBlockerManager.shared.whitelist.hostsForProfile(profile.id) {
                ContentBlockerManager.shared.whitelist.toggleHost(host, profileID: profile.id)
            }
            store.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    @MainActor private func makeProfile(_ name: String) -> Profile {
        let profile = store.addProfile(name: "\(name) \(UUID().uuidString.prefix(4))")
        createdProfiles.append(profile)
        return profile
    }

    @MainActor private func serve() async throws -> URL {
        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>Looked Up</title></head><body>a quick lookup</body></html>",
            "/next": "<html><head><title>Next Page</title></head><body>a second page</body></html>",
        ])
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    @MainActor private func openQuickDetour(on profile: Profile, loading url: URL) async throws -> QuickDetourWindowController {
        let controller = QuickDetourWindowController.open(profile: profile, url: url)
        quickDetours.append(controller)
        let tab = try XCTUnwrap(controller.tab)
        try await waitUntil("the Quick Detour page to load") {
            tab.url == url && !tab.isLoading && tab.title == "Looked Up"
        }
        return controller
    }

    // MARK: - Page settings

    @MainActor func testThePageSettingsAreForThePageAndItsProfile() async throws {
        let profile = makeProfile("Title Bar Settings")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)

        let settings = controller.makePageSettings()

        XCTAssertEqual(settings.host, "127.0.0.1")
        XCTAssertTrue(settings.isBlockingEnabled)
        XCTAssertNotNil(settings.onBlockingToggle)
        XCTAssertNotNil(settings.onPinToggle)
        XCTAssertNotNil(settings.onOpenExtensionSettings)
    }

    @MainActor private func switchLabels(in view: NSView) -> [String] {
        if let control = view as? NSSwitch { return [control.accessibilityLabel() ?? ""] }
        return view.subviews.flatMap(switchLabels(in:))
    }

    /// TASK-213: picture in picture acts on tab switching and dev mode on the
    /// sidebar; a Quick Detour has neither, so it offers only content blocking.
    @MainActor func testThePageSettingsHaveNoTabSwitches() async throws {
        let profile = makeProfile("Title Bar Switches")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)

        let settings = controller.makePageSettings()

        XCTAssertFalse(settings.showsTabSwitches)
        XCTAssertEqual(switchLabels(in: settings.view), ["Block content on this site"])
        XCTAssertNil(settings.onPictureInPictureToggle)
        XCTAssertNil(settings.onDevModeToggle)
    }

    @MainActor func testTheMainWindowsPageSettingsKeepTheTabSwitches() {
        let profile = makeProfile("Title Bar Main Switches")
        let settings = SettingsPopoverViewController.forPage(
            url: URL(string: "https://example.com/"), blockedCount: 0, profileID: profile.id,
            pages: { [] }, openExtension: { _ in })

        XCTAssertEqual(switchLabels(in: settings.view),
                       ["Block content on this site", "Picture in picture on tab switch", "Dev mode for this site"])
        XCTAssertNotNil(settings.onPictureInPictureToggle)
        XCTAssertNotNil(settings.onDevModeToggle)
    }

    /// AC #1, #2: the switch whitelists the site in the Quick Detour's profile
    /// only, and the page loads again for it to take effect.
    @MainActor func testTurningContentBlockingOffActsOnTheProfileAndReloadsThePage() async throws {
        let profile = makeProfile("Title Bar Blocking")
        let other = makeProfile("Title Bar Blocking Other")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)
        let page = try XCTUnwrap(controller.tab)
        let webView = try XCTUnwrap(page.webView)
        _ = try await webView.evaluateJavaScript("window.__beforeToggle = 1; 1")

        controller.makePageSettings().onBlockingToggle?()

        let whitelist = ContentBlockerManager.shared.whitelist
        XCTAssertTrue(whitelist.isWhitelisted(host: "127.0.0.1", profileID: profile.id))
        XCTAssertFalse(whitelist.isWhitelisted(host: "127.0.0.1", profileID: other.id),
                       "another profile's blocking is left alone")
        try await waitUntil("the page to load again") {
            let marked = try await webView.evaluateJavaScript("window.__beforeToggle === 1") as? Bool
            return marked == false && !page.isLoading
        }
        XCTAssertFalse(controller.makePageSettings().isBlockingEnabled, "the next popover reads the new state")
    }

    // MARK: - The palette

    @MainActor func testThePaletteAsksForASearchOrAURL() async throws {
        let profile = makeProfile("Title Bar Palette")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)

        controller.showPalette(prefill: nil)

        XCTAssertEqual(controller.commandPaletteView?.placeholder, "Search or enter a URL")
        XCTAssertEqual(CommandPaletteView().placeholder, "Where do you want to go?",
                       "the main window's palette keeps its prompt")
    }

    // MARK: - Back (TASK-322)

    @MainActor func testTheBackButtonGoesBackAndOnlyWhenThereIsAPageToGoBackTo() async throws {
        let profile = makeProfile("Title Bar Back")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)
        let tab = try XCTUnwrap(controller.tab)
        let back = controller.titleBar.backButton
        XCTAssertFalse(back.isEnabled, "the first page has nothing to go back to")

        let next = URL(string: "next", relativeTo: url)!.absoluteURL
        controller.load(next, typed: true)
        try await waitUntil("the second page to load and the button to enable") {
            tab.url == next && !tab.isLoading && back.isEnabled
        }

        back.performClick(nil)
        try await waitUntil("the first page again, with the button disabled") {
            tab.url == url && !tab.isLoading && !back.isEnabled
        }
    }

    @MainActor func testTheBackButtonSitsBetweenTheTrafficLightsAndTheCapsule() async throws {
        let profile = makeProfile("Title Bar Back Place")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)
        let bar = controller.titleBar
        bar.layoutSubtreeIfNeeded()
        let zoom = try XCTUnwrap(controller.window?.standardWindowButton(.zoomButton))
        let zoomMaxX = bar.convert(zoom.bounds, from: zoom).maxX

        XCTAssertGreaterThan(bar.backButton.frame.minX, zoomMaxX, "clear of the traffic lights")
        XCTAssertLessThan(bar.backButton.frame.maxX, bar.capsule.frame.minX, "before the capsule")
        XCTAssertEqual(bar.backButton.frame.midY, bar.capsule.frame.midY, accuracy: 1)
    }

    // MARK: - The capsule opens the palette (TASK-322)

    @MainActor func testTheCapsuleHandsPressesItsControlsDoNotTakeToTheHost() async throws {
        let profile = makeProfile("Title Bar Capsule")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)
        let bar = controller.titleBar
        bar.layoutSubtreeIfNeeded()
        let capsule = bar.capsule
        /// What a press at `x` (capsule coordinates), halfway down, lands on.
        func hit(_ x: CGFloat) -> NSView? {
            capsule.hitTest(capsule.convert(NSPoint(x: x, y: capsule.bounds.midY), to: bar))
        }
        func midX(_ view: NSView) -> CGFloat { capsule.convert(view.bounds, from: view).midX }

        let pillEnd = capsule.convert(bar.pill.bounds, from: bar.pill).maxX
        let hostStart = capsule.convert(bar.hostButton.bounds, from: bar.hostButton).minX
        XCTAssertGreaterThan(hostStart - pillEnd, 4, "there is empty space between the pill and the host")
        XCTAssertTrue(hit((pillEnd + hostStart) / 2) === bar.hostButton, "the empty space is the host's")
        XCTAssertTrue(hit(midX(bar.hostButton)) === bar.hostButton)
        XCTAssertTrue(hit(capsule.bounds.maxX - 1) === bar.hostButton, "so is the capsule's very edge")

        let onPill = try XCTUnwrap(hit(midX(bar.pill)))
        XCTAssertTrue(onPill.isDescendant(of: bar.pill), "the pill keeps its own press")
        XCTAssertTrue(hit(midX(bar.copyButton)) === bar.copyButton)
        XCTAssertTrue(hit(midX(bar.pageSettingsButton)) === bar.pageSettingsButton)

        // Under the pointer a button shows its hover background, a subview the
        // press lands on: still the button's, not the host's.
        bar.copyButton.subviews.forEach { $0.isHidden = false }
        let onHoveredCopy = try XCTUnwrap(hit(midX(bar.copyButton)))
        XCTAssertTrue(onHoveredCopy.isDescendant(of: bar.copyButton), "the hovered button keeps its press")
    }

    @MainActor func testAClickOnTheCapsulesEmptySpaceOpensThePalette() async throws {
        let profile = makeProfile("Title Bar Capsule Click")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)
        let bar = controller.titleBar
        let window = try XCTUnwrap(controller.window)
        bar.layoutSubtreeIfNeeded()
        let capsule = bar.capsule
        let pillEnd = capsule.convert(bar.pill.bounds, from: bar.pill).maxX
        let hostStart = capsule.convert(bar.hostButton.bounds, from: bar.hostButton).minX
        let point = capsule.convert(NSPoint(x: (pillEnd + hostStart) / 2, y: capsule.bounds.midY), to: nil)
        let host = try XCTUnwrap(capsule.hitTest(bar.convert(point, from: nil)) as? QuickDetourBarButton)
        XCTAssertTrue(host === bar.hostButton)
        var queue = [mouse(.leftMouseUp, at: point, in: window)]
        host.nextPressEvent = { _ in queue.isEmpty ? nil : queue.removeFirst() }

        host.mouseDown(with: mouse(.leftMouseDown, at: point, in: window))

        XCTAssertNotNil(controller.commandPaletteView, "released beside the host, on the capsule: the palette")
    }

    @MainActor func testAReleaseInTheClickAreaOutsideTheButtonIsAClick() {
        let clicks = Clicks()
        let (button, window) = makeButton(clicks)
        let area = NSView(frame: NSRect(x: 10, y: 10, width: 180, height: 44))
        window.contentView?.addSubview(area, positioned: .below, relativeTo: button)
        button.clickArea = area
        button.beginWindowDrag = { _, _ in XCTFail("under the threshold") }

        _ = press(button, in: window, at: NSPoint(x: 150, y: 30), then: [(.leftMouseUp, NSPoint(x: 151, y: 30))])
        XCTAssertEqual(clicks.count, 1, "released in the area, beside the button")

        _ = press(button, in: window, at: NSPoint(x: 11, y: 30), then: [(.leftMouseUp, NSPoint(x: 9, y: 30))])
        XCTAssertEqual(clicks.count, 1, "released outside the area")
    }

    // MARK: - Load progress (TASK-322)

    @MainActor func testTheCapsuleShowsProgressOnlyWhileALoadIsInFlight() {
        typealias Bar = QuickDetourTitleBar
        XCTAssertNil(Bar.displayedProgress(isLoading: false, estimatedProgress: 0))
        XCTAssertNil(Bar.displayedProgress(isLoading: false, estimatedProgress: 0.6), "stopped part way")
        XCTAssertNil(Bar.displayedProgress(isLoading: true, estimatedProgress: 1), "done, the flag not yet down")
        XCTAssertEqual(Bar.displayedProgress(isLoading: true, estimatedProgress: 0.6), 0.6)
        XCTAssertEqual(Bar.displayedProgress(isLoading: true, estimatedProgress: 0),
                       Bar.minimumDisplayedProgress, "a sliver from the start")

        let bar = Bar(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        bar.setLoadProgress(isLoading: true, estimatedProgress: 0.5)
        XCTAssertEqual(bar.capsule.progress, 0.5)
        XCTAssertEqual(bar.capsule.progressView.alphaValue, 1)
        bar.setLoadProgress(isLoading: false, estimatedProgress: 1)
        XCTAssertNil(bar.capsule.progress)
    }

    @MainActor func testTheCapsuleFollowsThePagesLoad() async throws {
        let profile = makeProfile("Title Bar Progress")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)
        let tab = try XCTUnwrap(controller.tab)
        try await waitUntil("the capsule to clear after the load") { controller.titleBar.capsule.progress == nil }

        tab.estimatedProgress = 0.4
        tab.isLoading = true
        try await waitUntil("the capsule to show the load") { controller.titleBar.capsule.progress == 0.4 }
        tab.isLoading = false
        try await waitUntil("the capsule to clear") { controller.titleBar.capsule.progress == nil }
    }

    // MARK: - The bar's buttons drag the window

    @MainActor private final class Clicks: NSObject {
        var count = 0
        @objc func clicked(_ sender: Any?) { count += 1 }
    }

    /// A bar button in a window of its own, at (20, 20, 100, 24).
    @MainActor private func makeButton(_ clicks: Clicks) -> (QuickDetourBarButton, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let button = QuickDetourBarButton(title: "example.com", target: clicks, action: #selector(Clicks.clicked(_:)))
        button.frame = NSRect(x: 20, y: 20, width: 100, height: 24)
        window.contentView?.addSubview(button)
        return (button, window)
    }

    @MainActor private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Presses at `start`, then hands `rest` to the button's tracking loop
    /// one by one. Not through the application's queue: posted mouse events
    /// come back with their locations moved through screen coordinates.
    @MainActor private func press(_ button: QuickDetourBarButton, in window: NSWindow, at start: NSPoint,
                       then rest: [(NSEvent.EventType, NSPoint)]) -> NSEvent {
        let down = mouse(.leftMouseDown, at: start, in: window)
        var queue = rest.map { mouse($0.0, at: $0.1, in: window) }
        button.nextPressEvent = { _ in queue.isEmpty ? nil : queue.removeFirst() }
        button.mouseDown(with: down)
        XCTAssertTrue(queue.isEmpty || queue.first?.type == .leftMouseUp,
                      "the loop reads up to the release or the drag")
        return down
    }

    /// Hands `down` to the button, then `rest` to its tracking loop.
    @MainActor private func press(_ button: QuickDetourBarButton, _ down: NSEvent, then rest: [(NSEvent.EventType, NSPoint)]) {
        guard let window = button.window else { return XCTFail("no window") }
        var queue = rest.map { mouse($0.0, at: $0.1, in: window) }
        button.nextPressEvent = { _ in queue.isEmpty ? nil : queue.removeFirst() }
        button.mouseDown(with: down)
    }

    @MainActor func testAPressReleasedInPlaceIsAClick() {
        let clicks = Clicks()
        let (button, window) = makeButton(clicks)
        var dragged = false
        button.beginWindowDrag = { _, _ in dragged = true }

        _ = press(button, in: window, at: NSPoint(x: 50, y: 30),
                  then: [(.leftMouseDragged, NSPoint(x: 51, y: 31)), (.leftMouseUp, NSPoint(x: 51, y: 31))])

        XCTAssertEqual(clicks.count, 1)
        XCTAssertFalse(dragged, "a wobble under the threshold is still a click")
    }

    @MainActor func testAPressThatMovesDragsTheWindowInstead() {
        let clicks = Clicks()
        let (button, window) = makeButton(clicks)
        var drag: (NSWindow, NSEvent)?
        button.beginWindowDrag = { window, press in drag = (window, press) }

        let down = press(button, in: window, at: NSPoint(x: 50, y: 30),
                         then: [(.leftMouseDragged, NSPoint(x: 50 + QuickDetourBarButton.dragThreshold, y: 30)),
                                (.leftMouseUp, NSPoint(x: 80, y: 30))])

        XCTAssertTrue(drag?.0 === window, "the button's window is dragged")
        XCTAssertTrue(drag?.1 === down, "from the press")
        XCTAssertEqual(clicks.count, 0, "and nothing is clicked")
    }

    /// The first press on a window in the background only brings it forward
    /// (AppKit asks `acceptsFirstMouse` for it); moving, it drags.
    @MainActor func testAFirstPressOnABackgroundWindowIsNoClickButStillDrags() {
        let clicks = Clicks()
        let (button, window) = makeButton(clicks)
        var dragged = 0
        button.beginWindowDrag = { _, _ in dragged += 1 }
        let start = NSPoint(x: 50, y: 30)

        var down = mouse(.leftMouseDown, at: start, in: window)
        XCTAssertTrue(button.acceptsFirstMouse(for: down))
        press(button, down, then: [(.leftMouseUp, start)])
        XCTAssertEqual(clicks.count, 0, "the press only brought the window forward")

        down = mouse(.leftMouseDown, at: start, in: window)
        XCTAssertTrue(button.acceptsFirstMouse(for: down))
        press(button, down, then: [(.leftMouseDragged, NSPoint(x: 60, y: 30))])
        XCTAssertEqual(dragged, 1, "but it can drag the window")

        _ = button.acceptsFirstMouse(for: mouse(.leftMouseDown, at: start, in: window))
        _ = press(button, in: window, at: start, then: [(.leftMouseUp, start)])
        XCTAssertEqual(clicks.count, 1, "another press, not the one asked about, clicks")
    }

    @MainActor func testAPressReleasedOutsideTheButtonIsNoClick() {
        let clicks = Clicks()
        let (button, window) = makeButton(clicks)
        button.beginWindowDrag = { _, _ in XCTFail("under the threshold") }
        // Down at the button's edge, up just outside it.
        _ = press(button, in: window, at: NSPoint(x: 21, y: 30),
                  then: [(.leftMouseUp, NSPoint(x: 19, y: 30))])

        XCTAssertEqual(clicks.count, 0)
    }
}
