import XCTest
import WebKit
@testable import Detour

/// Keys web content declined must die at the window controller instead of
/// falling off the responder chain into `noResponderFor(keyDown:)` — NSBeep
/// (TASK-76). Keys unhandled with a *native* first responder keep beeping.
@MainActor
final class UnhandledKeyFallthroughTests: XCTestCase {

    private var controller: BrowserWindowController?

    override func tearDown() {
        controller?.window?.close()
        controller = nil
        super.tearDown()
    }

    // MARK: - The decision

    func testWebViewFirstResponderCountsAsDeclinedByWebContent() {
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertTrue(BrowserWindowController.keyWasDeclinedByWebContent(firstResponder: webView))
    }

    func testViewNestedInsideAWebViewCountsAsDeclinedByWebContent() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let middle = NSView(frame: webView.bounds)
        let leaf = NSView(frame: webView.bounds)
        middle.addSubview(leaf)
        webView.addSubview(middle)
        XCTAssertTrue(BrowserWindowController.keyWasDeclinedByWebContent(firstResponder: leaf))
    }

    func testNativeFirstRespondersDoNotCountAsDeclinedByWebContent() {
        XCTAssertFalse(BrowserWindowController.keyWasDeclinedByWebContent(firstResponder: nil))
        XCTAssertFalse(BrowserWindowController.keyWasDeclinedByWebContent(
            firstResponder: NSTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))))
        XCTAssertFalse(BrowserWindowController.keyWasDeclinedByWebContent(
            firstResponder: NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))))
        // A view merely *hosting* a web view is not itself web content.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        container.addSubview(WKWebView(frame: container.bounds))
        XCTAssertFalse(BrowserWindowController.keyWasDeclinedByWebContent(firstResponder: container))
    }

    // MARK: - The controller

    func testDeclinedKeyStopsAtTheControllerButNativeKeyFallsThrough() throws {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        let window = try XCTUnwrap(wc.window)
        let contentView = try XCTUnwrap(window.contentView)

        var fellThrough: [NSEvent] = []
        wc.unhandledKeyFallthroughForTesting = { fellThrough.append($0) }

        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        contentView.addSubview(webView)
        contentView.addSubview(textField)
        defer {
            webView.removeFromSuperview()
            textField.removeFromSuperview()
        }

        // A key the page declined: WebKit re-dispatches it while the web view
        // still holds first responder.
        XCTAssertTrue(window.makeFirstResponder(webView))
        wc.keyDown(with: try makeKeyDown(in: window, characters: "j", keyCode: 38))
        XCTAssertTrue(fellThrough.isEmpty, "a key web content declined must not reach NSResponder (no beep)")

        // Same key with a native control focused still falls through to the
        // beep, which is the platform's feedback for an unusable key.
        XCTAssertTrue(window.makeFirstResponder(textField))
        let nativeEvent = try makeKeyDown(in: window, characters: "j", keyCode: 38)
        wc.keyDown(with: nativeEvent)
        XCTAssertEqual(fellThrough.count, 1, "a key unhandled by native views keeps its beep")
        XCTAssertTrue(fellThrough.first === nativeEvent)
    }

    private func makeKeyDown(in window: NSWindow, characters: String, keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode))
    }
}
