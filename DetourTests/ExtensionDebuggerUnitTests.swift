import XCTest
import WebKit
@testable import Detour

/// TASK-132.13: the pure rules of `chrome.debugger` — protocol versions, which
/// pages an extension may attach to, Chrome's error texts, the screenshot
/// parameters and geometry — and the session's reply bookkeeping.
nonisolated final class ExtensionDebuggerUnitTests: XCTestCase {

    @MainActor override func tearDown() async throws {
        ExtensionDebugger.shared.resetForTesting()
        try await super.tearDown()
    }

    @MainActor func testSupportedProtocolVersions() {
        for version in ["1.0", "1.1", "1.2", "1.3"] {
            XCTAssertTrue(ExtensionDebugger.isSupportedProtocolVersion(version), version)
        }
        for version in ["1.4", "2.0", "0.9", "1", "1.3.0", "", "1.x", " 1.3", "1.-1", "１.３"] {
            XCTAssertFalse(ExtensionDebugger.isSupportedProtocolVersion(version), version)
        }
    }

    @MainActor func testWhichPagesAnExtensionMayAttachTo() {
        let own = "11111111-2222-3333-4444-555555555555"
        let refusal = { (url: String) in ExtensionDebugger.attachRefusal(for: URL(string: url), ownExtensionHost: own) }
        for allowed in ["https://example.com/", "http://127.0.0.1:8080/x", "about:blank", "file:///tmp/a.html",
                        "data:text/html,hi", "blob:https://example.com/0a1b", "browser-error://error?failedURL=x",
                        "webkit-extension://\(own)/panel.html", "WEBKIT-EXTENSION://\(own.uppercased())/x"] {
            XCTAssertNil(refusal(allowed), allowed)
        }
        XCTAssertNil(ExtensionDebugger.attachRefusal(for: nil, ownExtensionHost: own), "a tab with no URL yet")
        XCTAssertEqual(refusal("detour://history/"), "Cannot access a detour:// URL")
        XCTAssertEqual(refusal("detour-favicon://x/y"), "Cannot access a detour-favicon:// URL")
        XCTAssertEqual(refusal("webkit-extension://99999999-2222-3333-4444-555555555555/page.html"),
                       ExtensionDebugger.otherExtensionPageError)
        XCTAssertEqual(ExtensionDebugger.attachRefusal(for: URL(string: "webkit-extension://\(own)/x"), ownExtensionHost: nil),
                       ExtensionDebugger.otherExtensionPageError, "no own host known: every extension page is refused")
        XCTAssertEqual(refusal("https://chromewebstore.google.com/detail/abc"), ExtensionDebugger.galleryError)
        XCTAssertEqual(refusal("blob:detour://history/0a1b"), "Cannot access a detour:// URL",
                       "a blob is judged by the origin that made it")
    }

    @MainActor func testErrorTextsAreChromes() {
        XCTAssertEqual(ExtensionDebugger.alreadyAttachedError(tabID: 5), "Another debugger is already attached to the tab with id: 5.")
        XCTAssertEqual(ExtensionDebugger.notAttachedError(tabID: 5), "Debugger is not attached to the tab with id: 5.")
        XCTAssertEqual(ExtensionDebugger.noTabError(5), "No tab with given id 5.")
        XCTAssertEqual(ExtensionDebugger.unsupportedVersionError("9.9"), "Requested protocol version is not supported: 9.9.")
        XCTAssertEqual(ExtensionDebugger.protocolError(code: -32601, message: "'A.b' wasn't found"),
                       #"{"code":-32601,"message":"'A.b' wasn't found"}"#)
        XCTAssertEqual(ExtensionDebugger.protocolError(code: -32000, message: #"say "hi""#),
                       #"{"code":-32000,"message":"say \"hi\""}"#, "the message is escaped as JSON")
    }

    // MARK: Screenshots

    @MainActor func testScreenshotParameters() {
        typealias Request = ExtensionDebuggerScreenshot.Request
        XCTAssertEqual(try Request.parse([:]).get(), Request())
        let full = try? Request.parse(["format": "jpeg", "quality": 55,
                                       "clip": ["x": 10, "y": 20, "width": 30, "height": 40, "scale": 0.5],
                                       "captureBeyondViewport": false, "fromSurface": true]).get()
        XCTAssertEqual(full?.format, .jpeg)
        XCTAssertEqual(full?.quality, 55)
        XCTAssertEqual(full?.clip, .init(rect: CGRect(x: 10, y: 20, width: 30, height: 40), scale: 0.5))
        XCTAssertEqual(try? Request.parse(["clip": ["x": 0, "y": 0, "width": 5, "height": 5]]).get().clip?.scale, 1,
                       "scale defaults to 1")
        for bad: [String: Any] in [["format": "gif"], ["format": 1], ["quality": 101], ["quality": -1], ["quality": true],
                                   ["clip": ["x": 0, "y": 0, "width": 0, "height": 5]],
                                   ["clip": ["x": 0, "y": 0, "width": 5, "height": 5, "scale": 0]],
                                   ["clip": ["x": 0, "width": 5, "height": 5]], ["clip": "x"]] {
            if case .success = Request.parse(bad) { XCTFail("accepted \(bad)") }
        }
    }

    @MainActor func testScreenshotGeometryFollowsChrome() throws {
        typealias S = ExtensionDebuggerScreenshot
        let viewport = S.Viewport(width: 800, height: 600, scrollX: 0, scrollY: 300, devicePixelRatio: 2)
        let view = CGSize(width: 800, height: 600)

        let whole = try XCTUnwrap(S.geometry(S.Request(), viewport: viewport, viewSize: view))
        XCTAssertEqual(whole.rect, CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(whole.pixelWidth, 1600, "CSS width × devicePixelRatio")
        XCTAssertEqual(whole.pixelHeight, 1200)

        // A clip in document coordinates: the scroll offset comes off.
        var request = S.Request()
        request.clip = S.Clip(rect: CGRect(x: 100, y: 350, width: 200, height: 100), scale: 0.5)
        let clipped = try XCTUnwrap(S.geometry(request, viewport: viewport, viewSize: view))
        XCTAssertEqual(clipped.rect, CGRect(x: 100, y: 50, width: 200, height: 100))
        XCTAssertEqual(clipped.pixelWidth, 200, "200 × 0.5 × 2")
        XCTAssertEqual(clipped.pixelHeight, 100)

        // Zoomed to 150%: a CSS pixel is 1.5 points; the page reports the
        // smaller CSS viewport.
        let zoomed = S.Viewport(width: 800 / 1.5, height: 400, scrollX: 0, scrollY: 0, devicePixelRatio: 2)
        let zoomedClip = try XCTUnwrap(S.geometry(request, viewport: zoomed, viewSize: view))
        XCTAssertEqual(zoomedClip.rect.origin.x, 150, accuracy: 0.001)
        XCTAssertEqual(zoomedClip.rect.width, 300, accuracy: 0.001)

        XCTAssertNil(S.geometry(S.Request(), viewport: S.Viewport(width: 0, height: 0, scrollX: 0, scrollY: 0, devicePixelRatio: 2),
                                viewSize: view), "nothing to capture")
        request.clip = S.Clip(rect: CGRect(x: 0, y: 0, width: 100_000, height: 100_000), scale: 1)
        XCTAssertNil(S.geometry(request, viewport: viewport, viewSize: view), "too large to make")
        // Past Int's range, alone or multiplied: refused, not a trap.
        request.clip = S.Clip(rect: CGRect(x: 0, y: 0, width: 1e300, height: 10), scale: 1)
        XCTAssertNil(S.geometry(request, viewport: viewport, viewSize: view), "width past Int.max")
        request.clip = S.Clip(rect: CGRect(x: 0, y: 0, width: 4e9, height: 4e9), scale: 1)
        XCTAssertNil(S.geometry(request, viewport: viewport, viewSize: view), "area past Int.max")
        request.clip = S.Clip(rect: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 1e300)
        XCTAssertNil(S.geometry(request, viewport: viewport, viewSize: view), "scale past Int.max")
    }

    @MainActor func testEncodingGivesTheExactSizeAndFormat() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let image = try XCTUnwrap(context.makeImage())
        for format in [ExtensionDebuggerScreenshot.Format.png, .jpeg] {
            let data = try ExtensionDebuggerScreenshot.encode(image, width: 7, height: 3, format: format, quality: 50).get()
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 7, "\(format)")
            XCTAssertEqual(decoded.height, 3, "\(format)")
            XCTAssertEqual(CGImageSourceGetType(source) as String?, format.type.identifier)
        }
    }

    // MARK: Replies and sessions

    @MainActor func testAReplyIsAnsweredOnce() {
        var answers: [String] = []
        let reply = ExtensionDebuggerReply { value, error in answers.append(error ?? "\(value ?? "nil")") }
        reply.fail(code: -32000, message: "first")
        reply.succeed(["late": true])
        reply.fail("later")
        XCTAssertEqual(answers, [#"{"code":-32000,"message":"first"}"#])
        XCTAssertTrue(reply.isAnswered)
    }

    /// Ending a session fails what is still in flight with Chrome's text,
    /// and the command's own late answer is dropped.
    @MainActor func testEndingASessionFailsCommandsInFlight() {
        let tab = BrowserTab(id: UUID(), title: "t", url: URL(string: "https://example.com/"), faviconURL: nil,
                             cachedInteractionState: nil, spaceID: UUID())
        let debugger = ExtensionDebugger.shared
        let outcome = debugger.attach(extensionID: "ext-a", profileID: UUID(), tab: tab, tabID: 41, ownExtensionHost: nil)
        XCTAssertEqual(outcome, .attached)
        let session = try! XCTUnwrap(debugger.session(forTabUUID: tab.id))
        XCTAssertTrue(tab.isAutomationAttached)

        var answers: [String] = []
        let reply = ExtensionDebuggerReply { _, error in answers.append(error ?? "ok") }
        session.track(reply)
        XCTAssertEqual(session.pendingCount, 1)
        debugger.end(session, reason: .targetClosed)
        reply.succeed()
        XCTAssertEqual(answers, ["Detached while handling command."])
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertFalse(tab.isAutomationAttached, "the tab is released")
        XCTAssertNil(debugger.session(forTabUUID: tab.id))

        // A finished command leaves the in-flight set.
        let again = debugger.attach(extensionID: "ext-a", profileID: UUID(), tab: tab, tabID: 41, ownExtensionHost: nil)
        XCTAssertEqual(again, .attached)
        let second = try! XCTUnwrap(debugger.session(forTabUUID: tab.id))
        let done = ExtensionDebuggerReply { _, _ in }
        second.track(done)
        done.succeed()
        XCTAssertEqual(second.pendingCount, 0)
    }

    @MainActor func testOneDebuggerPerTab() {
        let tab = BrowserTab(id: UUID(), title: "t", url: URL(string: "https://example.com/"), faviconURL: nil,
                             cachedInteractionState: nil, spaceID: UUID())
        let profileID = UUID()
        let debugger = ExtensionDebugger.shared
        XCTAssertEqual(debugger.attach(extensionID: "ext-a", profileID: profileID, tab: tab, tabID: 3, ownExtensionHost: nil),
                       .attached)
        XCTAssertEqual(debugger.attach(extensionID: "ext-b", profileID: profileID, tab: tab, tabID: 9, ownExtensionHost: nil),
                       .refused("Another debugger is already attached to the tab with id: 9."))
        XCTAssertEqual(debugger.attach(extensionID: "ext-a", profileID: profileID, tab: tab, tabID: 3, ownExtensionHost: nil),
                       .refused("Another debugger is already attached to the tab with id: 3."))
        XCTAssertNotNil(debugger.session(extensionID: "ext-a", profileID: profileID, tabID: 3))
        XCTAssertNil(debugger.session(extensionID: "ext-b", profileID: profileID, tabID: 3), "named by its own extension only")
        XCTAssertNil(debugger.session(extensionID: "ext-a", profileID: UUID(), tabID: 3), "and in its own profile only")
    }

    /// Events reach the session's extension only, and a domain's events only
    /// while it is enabled; a detach is always told.
    @MainActor func testEventsFollowTheEnabledDomainsAndReachTheOwnerOnly() {
        let profileID = UUID()
        let channel = ExtensionEventParking(label: "debugger events", backlogLimit: 100, supersededError: "s",
                                            unloadedError: "u", wakeBackground: { _ in })
        let debugger = ExtensionDebugger.shared
        debugger.register(channel: channel, for: profileID)
        var mine: [[String: Any]] = []
        var theirs: [[String: Any]] = []
        func park() {
            let ack = mine.last?["seq"] as? Int
            channel.awaitEvent(extensionID: "ext-a", isBackground: true, instance: "a", webView: nil, ack: ack) { value, _ in
                mine.append(contentsOf: (value as? [String: Any])?["events"] as? [[String: Any]] ?? [])
            }
            channel.awaitEvent(extensionID: "ext-b", isBackground: true, instance: "b", webView: nil, ack: nil) { value, _ in
                theirs.append(contentsOf: (value as? [String: Any])?["events"] as? [[String: Any]] ?? [])
            }
        }
        park()
        let tab = BrowserTab(id: UUID(), title: "t", url: URL(string: "https://example.com/"), faviconURL: nil,
                             cachedInteractionState: nil, spaceID: UUID())
        _ = debugger.attach(extensionID: "ext-a", profileID: profileID, tab: tab, tabID: 12, ownExtensionHost: nil)
        let session = debugger.session(forTabUUID: tab.id)!
        debugger.emitEvent(session, method: "Page.frameNavigated", params: [:])
        XCTAssertTrue(mine.isEmpty, "Page is not enabled")
        session.enabledDomains.insert("Page")
        debugger.emitEvent(session, method: "Page.frameNavigated", params: ["frame": ["id": "x"]])
        XCTAssertEqual(mine.map { $0["method"] as? String }, ["Page.frameNavigated"])
        XCTAssertEqual(mine.first?["tabId"] as? Int, 12)
        park()
        debugger.end(session, reason: .canceledByUser)
        XCTAssertEqual(mine.last?["kind"] as? String, "detach")
        XCTAssertEqual(mine.last?["reason"] as? String, "canceled_by_user")
        XCTAssertTrue(theirs.isEmpty, "another extension hears nothing")
    }
}
