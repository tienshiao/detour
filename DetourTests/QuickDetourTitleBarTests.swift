import XCTest
import WebKit
@testable import Detour

/// The Quick Detour bar after TASK-210: its page settings are the main
/// window's site settings acting on the Quick Detour's page and profile; the
/// host and Open in's main part drag the window once a press moves, and are
/// buttons otherwise; the palette asks for a search or a URL.
///
/// The shared store with profiles of the test's own; pages from a loopback
/// server. The bar button gets its events from the application's queue, as
/// its tracking loop reads them.
@MainActor
final class QuickDetourTitleBarTests: XCTestCase {

    private var store: TabStore { .shared }
    private var quickDetours: [QuickDetourWindowController] = []
    private var createdProfiles: [Profile] = []
    private var servers: [LoopbackHTTPServer] = []
    private var windows: [NSWindow] = []
    private static var retainedProfiles: [Profile] = []

    override func tearDown() async throws {
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

    private func makeProfile(_ name: String) -> Profile {
        let profile = store.addProfile(name: "\(name) \(UUID().uuidString.prefix(4))")
        createdProfiles.append(profile)
        return profile
    }

    private func serve() async throws -> URL {
        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>Looked Up</title></head><body>a quick lookup</body></html>",
        ])
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    private func openQuickDetour(on profile: Profile, loading url: URL) async throws -> QuickDetourWindowController {
        let controller = QuickDetourWindowController.open(profile: profile, url: url)
        quickDetours.append(controller)
        let tab = try XCTUnwrap(controller.tab)
        try await waitUntil("the Quick Detour page to load") {
            tab.url == url && !tab.isLoading && tab.title == "Looked Up"
        }
        return controller
    }

    // MARK: - Page settings

    func testThePageSettingsAreForThePageAndItsProfile() async throws {
        let profile = makeProfile("Title Bar Settings")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)

        let settings = controller.makePageSettings()

        XCTAssertEqual(settings.host, "127.0.0.1")
        XCTAssertTrue(settings.isBlockingEnabled)
        XCTAssertNotNil(settings.onBlockingToggle)
        XCTAssertNotNil(settings.onPictureInPictureToggle)
        XCTAssertNotNil(settings.onDevModeToggle)
        XCTAssertNotNil(settings.onPinToggle)
        XCTAssertNotNil(settings.onOpenExtensionSettings)
    }

    /// AC #1, #2: the switch whitelists the site in the Quick Detour's profile
    /// only, and the page loads again for it to take effect.
    func testTurningContentBlockingOffActsOnTheProfileAndReloadsThePage() async throws {
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

    func testThePaletteAsksForASearchOrAURL() async throws {
        let profile = makeProfile("Title Bar Palette")
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)

        controller.showPalette(prefill: nil)

        XCTAssertEqual(controller.commandPaletteView?.placeholder, "Search or enter a URL")
        XCTAssertEqual(CommandPaletteView().placeholder, "Where do you want to go?",
                       "the main window's palette keeps its prompt")
    }

    // MARK: - The bar's buttons drag the window

    private final class Clicks: NSObject {
        var count = 0
        @objc func clicked(_ sender: Any?) { count += 1 }
    }

    /// A bar button in a window of its own, at (20, 20, 100, 24).
    private func makeButton(_ clicks: Clicks) -> (QuickDetourBarButton, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let button = QuickDetourBarButton(title: "example.com", target: clicks, action: #selector(Clicks.clicked(_:)))
        button.frame = NSRect(x: 20, y: 20, width: 100, height: 24)
        window.contentView?.addSubview(button)
        return (button, window)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Presses at `start`, then hands `rest` to the button's tracking loop
    /// one by one. Not through the application's queue: posted mouse events
    /// come back with their locations moved through screen coordinates.
    private func press(_ button: QuickDetourBarButton, in window: NSWindow, at start: NSPoint,
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
    private func press(_ button: QuickDetourBarButton, _ down: NSEvent, then rest: [(NSEvent.EventType, NSPoint)]) {
        guard let window = button.window else { return XCTFail("no window") }
        var queue = rest.map { mouse($0.0, at: $0.1, in: window) }
        button.nextPressEvent = { _ in queue.isEmpty ? nil : queue.removeFirst() }
        button.mouseDown(with: down)
    }

    func testAPressReleasedInPlaceIsAClick() {
        let clicks = Clicks()
        let (button, window) = makeButton(clicks)
        var dragged = false
        button.beginWindowDrag = { _, _ in dragged = true }

        _ = press(button, in: window, at: NSPoint(x: 50, y: 30),
                  then: [(.leftMouseDragged, NSPoint(x: 51, y: 31)), (.leftMouseUp, NSPoint(x: 51, y: 31))])

        XCTAssertEqual(clicks.count, 1)
        XCTAssertFalse(dragged, "a wobble under the threshold is still a click")
    }

    func testAPressThatMovesDragsTheWindowInstead() {
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
    func testAFirstPressOnABackgroundWindowIsNoClickButStillDrags() {
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

    func testAPressReleasedOutsideTheButtonIsNoClick() {
        let clicks = Clicks()
        let (button, window) = makeButton(clicks)
        button.beginWindowDrag = { _, _ in XCTFail("under the threshold") }
        // Down at the button's edge, up just outside it.
        _ = press(button, in: window, at: NSPoint(x: 21, y: 30),
                  then: [(.leftMouseUp, NSPoint(x: 19, y: 30))])

        XCTAssertEqual(clicks.count, 0)
    }
}
