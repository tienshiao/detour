import XCTest
import WebKit
@testable import Detour

/// TASK-132.16: the pure parts of the console and network events — parameter
/// parsing, the event shapes, error and resource type mapping, the scripts.
nonisolated final class ExtensionDebuggerEventsUnitTests: XCTestCase {

    @MainActor func testNetworkEnableParameters() {
        XCTAssertEqual(try? ExtensionDebuggerNetwork.parseEnable([:]).get(), 0, "Chrome's default: no bodies")
        XCTAssertEqual(try? ExtensionDebuggerNetwork.parseEnable(["maxPostDataSize": 65536]).get(), 65536)
        XCTAssertEqual(try? ExtensionDebuggerNetwork.parseEnable(["maxPostDataSize": NSNull()]).get(), 0)
        XCTAssertEqual(try? ExtensionDebuggerNetwork.parseEnable(["maxTotalBufferSize": 1000, "maxResourceBufferSize": 10]).get(), 0)
        for (name, value) in [("maxPostDataSize", "big" as Any), ("maxPostDataSize", 1.5), ("maxPostDataSize", true),
                              ("maxTotalBufferSize", "x"), ("maxResourceBufferSize", 1e20)] {
            guard case .failure(let failure) = ExtensionDebuggerNetwork.parseEnable([name: value]) else {
                return XCTFail("\(name): \(value) should be refused")
            }
            XCTAssertEqual(failure.text, "Invalid parameters: \(name): integer value expected")
        }
    }

    @MainActor func testNetErrorTexts() {
        let cases: [(Int, String, Bool)] = [
            (NSURLErrorCancelled, "net::ERR_ABORTED", true),
            (NSURLErrorCannotFindHost, "net::ERR_NAME_NOT_RESOLVED", false),
            (NSURLErrorTimedOut, "net::ERR_TIMED_OUT", false),
            (NSURLErrorCannotConnectToHost, "net::ERR_CONNECTION_REFUSED", false),
            (NSURLErrorNotConnectedToInternet, "net::ERR_INTERNET_DISCONNECTED", false),
            (NSURLErrorServerCertificateUntrusted, "net::ERR_CERT_AUTHORITY_INVALID", false),
            (NSURLErrorBadServerResponse, "net::ERR_FAILED", false),
        ]
        for (code, text, canceled) in cases {
            let failure = ExtensionDebuggerNetwork.netError(NSError(domain: NSURLErrorDomain, code: code))
            XCTAssertEqual(failure.text, text, "\(code)")
            XCTAssertEqual(failure.canceled, canceled, "\(code)")
        }
        let interrupted = ExtensionDebuggerNetwork.netError(NSError(domain: "WebKitErrorDomain", code: 102))
        XCTAssertEqual(interrupted.text, "net::ERR_ABORTED")
        XCTAssertTrue(interrupted.canceled)
        XCTAssertEqual(ExtensionDebuggerNetwork.netError(NSError(domain: "Other", code: 1)).text, "net::ERR_FAILED")
    }

    @MainActor func testResourceTypes() {
        let cases: [(String, String, String)] = [
            ("script", "https://a.test/app", "Script"),
            ("img", "https://a.test/p", "Image"),
            ("video", "https://a.test/v", "Media"),
            ("iframe", "https://a.test/f", "Document"),
            ("beacon", "https://a.test/b", "Ping"),
            ("link", "https://a.test/site.css?v=1", "Stylesheet"),
            ("css", "https://a.test/font.woff2", "Font"),
            ("css", "https://a.test/bg.png", "Image"),
            ("link", "https://a.test/module.mjs", "Script"),
            ("other", "https://a.test/stream", "Other"),
        ]
        for (initiator, url, type) in cases {
            XCTAssertEqual(ExtensionDebuggerNetwork.resourceType(initiatorType: initiator, url: url), type, "\(initiator) \(url)")
        }
        XCTAssertEqual(ExtensionDebuggerNetwork.securityState("https://a.test/"), "secure")
        XCTAssertEqual(ExtensionDebuggerNetwork.securityState("http://a.test/"), "insecure")
        XCTAssertEqual(ExtensionDebuggerNetwork.securityState("data:text/plain,x"), "neutral")
    }

    @MainActor func testConsoleAPICalledShape() {
        let params = ExtensionDebuggerInstrumentation.consoleAPICalledParams([
            "type": "warning", "args": [["type": "string", "value": "hi"]], "timestamp": 1_700_000_000_000.5,
            "frames": [["functionName": "f", "url": "https://a.test/app.js", "lineNumber": 3, "columnNumber": 7],
                       ["functionName": "", "url": "", "lineNumber": 0, "columnNumber": 0]],
        ])
        XCTAssertEqual(params["type"] as? String, "warning")
        XCTAssertEqual(params["executionContextId"] as? Int, 1)
        XCTAssertEqual(params["timestamp"] as? Double, 1_700_000_000_000.5)
        let frames = (params["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]]
        XCTAssertEqual(frames?.count, 1, "a frame without a URL is left out")
        XCTAssertEqual(frames?.first?["url"] as? String, "https://a.test/app.js")
        XCTAssertEqual(frames?.first?["lineNumber"] as? Int, 3)
        XCTAssertNotNil(frames?.first?["scriptId"] as? String)
        // No frames: no stack trace.
        XCTAssertNil(ExtensionDebuggerInstrumentation.consoleAPICalledParams(["type": "log", "args": []])["stackTrace"])
    }

    @MainActor func testExceptionThrownShape() throws {
        let error = ExtensionDebuggerInstrumentation.exceptionThrownParams([
            "text": "Uncaught", "timestamp": 5.0, "isError": true, "name": "TypeError", "message": "x is null",
            "exception": ["type": "object", "subtype": "error", "className": "TypeError", "description": "TypeError: x is null"],
            "frames": [["functionName": "boom", "url": "https://a.test/", "lineNumber": 4, "columnNumber": 2]],
        ], exceptionID: 9)
        let details = try XCTUnwrap(error["exceptionDetails"] as? [String: Any])
        XCTAssertEqual(details["exceptionId"] as? Int, 9)
        XCTAssertEqual(details["lineNumber"] as? Int, 4)
        XCTAssertEqual(details["url"] as? String, "https://a.test/")
        XCTAssertEqual((details["exception"] as? [String: Any])?["description"] as? String,
                       "TypeError: x is null\n    at boom (https://a.test/:5:3)", "V8's stack text, 1-based")
        // A muted error from another origin's script: the event's own place.
        let muted = ExtensionDebuggerInstrumentation.exceptionThrownParams([
            "text": "Script error.", "url": "", "line": 0, "column": 0, "frames": [],
        ], exceptionID: 10)
        let mutedDetails = try XCTUnwrap(muted["exceptionDetails"] as? [String: Any])
        XCTAssertEqual(mutedDetails["text"] as? String, "Script error.")
        XCTAssertEqual(mutedDetails["lineNumber"] as? Int, 0)
        XCTAssertNil(mutedDetails["url"])
        XCTAssertNil(mutedDetails["exception"])
        // A thrown primitive keeps its value and gets no description.
        let primitive = ExtensionDebuggerInstrumentation.exceptionThrownParams([
            "text": "Uncaught", "exception": ["type": "string", "value": "oops"], "url": "https://a.test/", "line": 3, "column": 9,
        ], exceptionID: 11)
        let primitiveDetails = try XCTUnwrap(primitive["exceptionDetails"] as? [String: Any])
        XCTAssertEqual(primitiveDetails["lineNumber"] as? Int, 2)
        XCTAssertEqual(primitiveDetails["columnNumber"] as? Int, 8)
        XCTAssertNil((primitiveDetails["exception"] as? [String: Any])?["description"])
    }

    @MainActor func testTheScriptsCarryTheirToken() {
        let token = "detour-debugger-ABC"
        let page = ExtensionDebuggerInstrumentationSource.pageSource(token: token)
        let isolated = ExtensionDebuggerInstrumentationSource.isolatedSource(token: token)
        for source in [page, isolated] {
            XCTAssertFalse(source.contains("__TOKEN__"))
            XCTAssertFalse(source.contains("__DESCRIBER__"))
            XCTAssertFalse(source.contains("__STRING_LIMIT__"))
            XCTAssertFalse(source.contains("__STORED_LIMIT__"))
            XCTAssertFalse(source.contains("__HANDLER__"))
            XCTAssertTrue(source.contains("'\(token)'"))
        }
        XCTAssertTrue(page.contains("const remote = (v, byValue)"), "the shared describer")
        XCTAssertTrue(isolated.contains("messageHandlers.\(ExtensionDebuggerInstrumentationSource.handlerName)"))
    }

    @MainActor func testTheScriptsCompileAndThePageHalfInstallsOnce() async throws {
        let webView = WKWebView(frame: .zero)
        try await loadHTMLStringAndWait(webView, html: "<html><body>x</body></html>",
                                        baseURL: URL(string: "https://instrumentation.test/")!)
        let token = "detour-debugger-TEST"
        let world = WKContentWorld.world(name: "InstrumentationUnitTest")
        _ = try await webView.callAsyncJavaScript(ExtensionDebuggerInstrumentationSource.isolatedSource(token: token),
                                                  arguments: [:], in: nil, contentWorld: world)
        let page = ExtensionDebuggerInstrumentationSource.pageSource(token: token)
        _ = try await webView.callAsyncJavaScript("window.__before = console.log; window.__beforeToString = Function.prototype.toString;", arguments: [:], in: nil, contentWorld: .page)
        _ = try await webView.callAsyncJavaScript(page, arguments: [:], in: nil, contentWorld: .page)
        _ = try await webView.callAsyncJavaScript("window.__once = console.log;", arguments: [:], in: nil, contentWorld: .page)
        _ = try await webView.callAsyncJavaScript(page, arguments: [:], in: nil, contentWorld: .page)
        let state = try await webView.callAsyncJavaScript(
            "return [console.log !== window.__before, console.log === window.__once, String(console.log)];",
            arguments: [:], in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(state?[0] as? Bool, true, "wrapped")
        XCTAssertEqual(state?[1] as? Bool, true, "a second run in the same document changes nothing")
        XCTAssertEqual(state?[2] as? String, "function log() {\n    [native code]\n}")
        // Stopped: the originals are back.
        _ = try await webView.callAsyncJavaScript("window.__detourDebuggerInstrumentation.stop();", arguments: [:],
                                                  in: nil, contentWorld: world)
        let restored = try await webView.callAsyncJavaScript(
            "return console.log === window.__before && Function.prototype.toString === window.__beforeToString;",
            arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(restored, true)
        let gone = try await webView.callAsyncJavaScript("return typeof window.__detourDebuggerInstrumentation;",
                                                         arguments: [:], in: nil, contentWorld: world) as? String
        XCTAssertEqual(gone, "undefined")
    }

    @MainActor func testOnlyATabsOwnControllerCountsAsATabs() {
        XCTAssertTrue(Space.isTabUserContentController(Space.makeUserContentController(for: nil)))
        XCTAssertFalse(Space.isTabUserContentController(WKUserContentController()),
                       "an extension page's controller is shared with the extension's other pages")
    }
}
