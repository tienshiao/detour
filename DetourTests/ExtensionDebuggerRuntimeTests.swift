import XCTest
import WebKit
@testable import Detour

/// TASK-132.15: `Runtime.evaluate` against real pages in a bare web view —
/// the evaluation pipeline itself, with WebKit's own script engine as the
/// oracle for completion values. The extension-context tests
/// (`ExtensionDebuggerRuntimeExtensionTests`) cover the API around it.
nonisolated final class ExtensionDebuggerRuntimeTests: XCTestCase {

    private var server: LoopbackHTTPServer?
    private var port: UInt16 = 0
    private var webView: WKWebView!

    static let plainPage = "<html><head><title>plain</title></head><body><div id=\"main\" class=\"a b\">hi</div></body></html>"
    static let cspPage = """
        <html><head><meta http-equiv="Content-Security-Policy" content="script-src 'self'">\
        <title>csp</title></head><body>csp</body></html>
        """

    @MainActor override func setUp() async throws {
        try await super.setUp()
        let server = try LoopbackHTTPServer(routes: ["/plain": Self.plainPage, "/csp": Self.cspPage])
        port = try await server.start()
        self.server = server
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    @MainActor override func tearDown() async throws {
        webView?.stopLoading()
        webView = nil
        server?.stop()
        server = nil
        try await super.tearDown()
    }

    @MainActor private func load(_ path: String) async throws {
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!))
        try await waitUntil("the page to load", timeout: 20) {
            guard !self.webView.isLoading else { return false }
            let ready = try? await self.webView.callAsyncJavaScript("return document.readyState === 'complete';",
                                                                    arguments: [:], contentWorld: .page)
            return ready as? Bool == true
        }
    }

    @MainActor private func evaluate(_ expression: String, byValue: Bool = true, awaitPromise: Bool = true,
                                     repl: Bool = false, timeout: Double? = nil) async throws -> [String: Any] {
        let request = ExtensionDebuggerEvaluation.Request(expression: expression, returnByValue: byValue,
                                                          awaitPromise: awaitPromise, replMode: repl, timeout: timeout)
        switch await ExtensionDebuggerEvaluation.run(request, in: webView) {
        case .success(let result): return result
        case .failure(let failure): throw NSError(domain: "evaluate", code: failure.code,
                                                  userInfo: [NSLocalizedDescriptionKey: failure.message])
        }
    }

    @MainActor private func failure(_ expression: String, byValue: Bool = true) async -> ExtensionDebuggerEvaluation.Failure? {
        let request = ExtensionDebuggerEvaluation.Request(expression: expression, returnByValue: byValue)
        if case .failure(let failure) = await ExtensionDebuggerEvaluation.run(request, in: webView) { return failure }
        return nil
    }

    @MainActor private func result(_ answer: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        XCTAssertNil(answer["exceptionDetails"], "unexpected exception: \(answer)", file: file, line: line)
        return try XCTUnwrap(answer["result"] as? [String: Any], file: file, line: line)
    }

    // MARK: - Completion values (AC #1)

    /// WebKit's own completion value of each snippet as a script
    /// (`evaluateJavaScript`) is what the rewrite must reproduce, both plain
    /// and wrapped in the block the Claude extension sends.
    @MainActor func testCompletionValuesMatchWebKitsOwnScriptEvaluation() async throws {
        try await load("plain")
        let snippets = [
            "1 + 1", "let a = 1; a + 1", "var v = 3; v", "x1 = 5; x1 * 2", "[1, 2].map(x => x * 2).join()",
            "'a' + 'b'\n", "1;;", "0, 1, 2", "typeof undefinedThing", "void 0", "let q = 4\nq\n",
            "const o = { a: 1 }\no.a", "function f() { return 7 }\nf()", "class C {}; new C().constructor.name",
            "(function () { return 'iife' })()", "let s = 'a;b}c'\ns.length", "let r = /[;}]/g\n'x;y'.replace(r, '-')",
            "let t = `x${1 + 1}y${`${2}`}`\nt", "// note\n3 // trailing", "/* a; } */ 4", "let n = 6\n-1",
            "document.getElementById('main').textContent",
            "{ 10 }", "{ let w = 1; { w + 1 } }", "label: { 8; break label; }", "if (true) { 2 }",
        ]
        for snippet in snippets {
            for code in [snippet, "{\(snippet)\n}"] {
                let expected = try? await webView.evaluateJavaScript(code, in: nil, contentWorld: .page)
                let answer = try await evaluate(code, repl: true)
                let remote = try result(answer)
                let got = remote["value"]
                let same: Bool
                switch (expected, got) {
                case (nil, nil): same = true
                case (let e as NSNumber, let g as NSNumber): same = e == g
                case (let e as String, let g as String): same = e == g
                default: same = false
                }
                // What the rewrite cannot reach is undefined; flag only a
                // value that is wrong rather than missing.
                if !same, !(got == nil && remote["type"] as? String == "undefined" && Self.unreachable.contains(snippet)) {
                    XCTFail("\(code.debugDescription): expected \(String(describing: expected)), got \(remote)")
                }
            }
        }
    }

    /// Completion values the rewrite does not reach (the docs list them).
    static let unreachable: Set<String> = ["label: { 8; break label; }", "if (true) { 2 }"]

    @MainActor func testTopLevelAwaitAndPromisesInREPLModeAndOut() async throws {
        try await load("plain")
        let awaited = try result(try await evaluate("{ const v = await new Promise(r => setTimeout(() => r(21), 5)); v * 2 }",
                                                    repl: true))
        XCTAssertEqual(awaited["value"] as? Int, 42)
        // Not REPL mode, awaitPromise: the promise is awaited, as in V8.
        let promise = try result(try await evaluate("Promise.resolve(5)", repl: false))
        XCTAssertEqual(promise["type"] as? String, "number")
        XCTAssertEqual(promise["value"] as? Int, 5)
        // REPL mode returns the completion value as it is: a promise, by value {}.
        let unawaited = try result(try await evaluate("Promise.resolve(5)", repl: true))
        XCTAssertEqual(unawaited["type"] as? String, "object")
        XCTAssertEqual((unawaited["value"] as? [String: Any])?.isEmpty, true)
        // Not awaited, not by value: described.
        let described = try result(try await evaluate("Promise.resolve(5)", byValue: false, awaitPromise: false))
        XCTAssertEqual(described["subtype"] as? String, "promise")
        XCTAssertEqual(described["className"] as? String, "Promise")
        // The page's own globals are there.
        _ = try await webView.callAsyncJavaScript("window.pageVariable = 'from the page';", arguments: [:], contentWorld: .page)
        let global = try result(try await evaluate("{ pageVariable }", repl: true))
        XCTAssertEqual(global["value"] as? String, "from the page")
        let selfIsWindow = try result(try await evaluate("this === window", repl: false))
        XCTAssertEqual(selfIsWindow["value"] as? Bool, true)
    }

    // MARK: - RemoteObject shapes (AC #1)

    @MainActor func testByValueShapesFollowV8() async throws {
        try await load("plain")
        let undefinedValue = try result(try await evaluate("undefined"))
        XCTAssertEqual(undefinedValue as NSDictionary, ["type": "undefined"] as NSDictionary)
        let nullValue = try result(try await evaluate("null"))
        XCTAssertEqual(nullValue as NSDictionary, ["type": "object", "subtype": "null", "value": NSNull()] as NSDictionary)
        let number = try result(try await evaluate("1.5"))
        XCTAssertEqual(number as NSDictionary, ["type": "number", "value": 1.5, "description": "1.5"] as NSDictionary)
        for (expression, text) in [("NaN", "NaN"), ("Infinity", "Infinity"), ("-Infinity", "-Infinity"), ("-0", "-0")] {
            let value = try result(try await evaluate(expression))
            XCTAssertEqual(value as NSDictionary, ["type": "number", "unserializableValue": text, "description": text] as NSDictionary,
                           expression)
        }
        let bigint = try result(try await evaluate("10n ** 20n"))
        XCTAssertEqual(bigint as NSDictionary, ["type": "bigint", "unserializableValue": "100000000000000000000n",
                                                "description": "100000000000000000000n"] as NSDictionary)
        let string = try result(try await evaluate("'text'"))
        XCTAssertEqual(string as NSDictionary, ["type": "string", "value": "text"] as NSDictionary)
        let bool = try result(try await evaluate("true"))
        XCTAssertEqual(bool as NSDictionary, ["type": "boolean", "value": true] as NSDictionary)
        // Objects by value: no subtype, no description; undefined properties
        // dropped, NaN as null, nested functions as {}.
        let array = try result(try await evaluate("[1, 'a', null, undefined, NaN]"))
        XCTAssertEqual(array["type"] as? String, "object")
        XCTAssertNil(array["subtype"])
        XCTAssertEqual(array["value"] as? NSArray, [1, "a", NSNull(), NSNull(), NSNull()] as NSArray)
        let object = try result(try await evaluate("({ a: 1, b: undefined, c: { d: [true] }, f() {} })"))
        XCTAssertEqual(object["value"] as? NSDictionary, ["a": 1, "c": ["d": [true]], "f": [:] as [String: Any]] as NSDictionary)
        let node = try result(try await evaluate("document.body"))
        XCTAssertEqual(node as NSDictionary, ["type": "object", "value": [:] as [String: Any]] as NSDictionary)
        let function = try result(try await evaluate("(function named() {})"))
        XCTAssertEqual(function as NSDictionary, ["type": "function", "value": [:] as [String: Any]] as NSDictionary)
        // What V8 cannot return by value fails the command, as in Chrome.
        let circular = await failure("{ const c = {}; c.self = c; c }")
        XCTAssertEqual(circular, ExtensionDebuggerEvaluation.Failure(code: -32000, message: "Object reference chain is too long"))
        let symbol = await failure("Symbol('s')")
        XCTAssertEqual(symbol, ExtensionDebuggerEvaluation.Failure(code: -32000, message: "Object couldn't be returned by value"))
        let nested = await failure("({ big: 1n })")
        XCTAssertEqual(nested?.message, "Object couldn't be returned by value")
    }

    @MainActor func testDescriptionsWithoutReturnByValue() async throws {
        try await load("plain")
        let cases: [(String, String, String?, String, String)] = [
            ("[1, 2, 3]", "object", "array", "Array", "Array(3)"),
            ("document.getElementById('main')", "object", "node", "HTMLDivElement", "div#main.a.b"),
            ("document", "object", "node", "HTMLDocument", "#document"),
            ("new Map([[1, 2]])", "object", "map", "Map", "Map(1)"),
            ("new Set([1])", "object", "set", "Set", "Set(1)"),
            ("/a+/g", "object", "regexp", "RegExp", "/a+/g"),
            ("new Uint8Array(4)", "object", "typedarray", "Uint8Array", "Uint8Array(4)"),
            ("new TypeError('bad')", "object", "error", "TypeError", "TypeError: bad"),
            ("({})", "object", nil, "Object", "Object"),
        ]
        for (expression, type, subtype, className, description) in cases {
            let value = try result(try await evaluate(expression, byValue: false))
            XCTAssertEqual(value["type"] as? String, type, expression)
            XCTAssertEqual(value["subtype"] as? String, subtype, expression)
            XCTAssertEqual(value["className"] as? String, className, expression)
            XCTAssertEqual(value["description"] as? String, description, expression)
            XCTAssertNil(value["value"], expression)
        }
        let function = try result(try await evaluate("(function named(a) { return a })", byValue: false))
        XCTAssertEqual(function["type"] as? String, "function")
        XCTAssertEqual(function["className"] as? String, "Function")
        XCTAssertEqual(function["description"] as? String, "function named(a) { return a }")
        let symbol = try result(try await evaluate("Symbol('s')", byValue: false))
        XCTAssertEqual(symbol as NSDictionary, ["type": "symbol", "description": "Symbol(s)"] as NSDictionary)
    }

    // MARK: - Errors (AC #2)

    @MainActor func testAThrownErrorReportsExceptionDetailsWithAStackTrace() async throws {
        try await load("plain")
        let answer = try await evaluate("{ const a = 1;\n  null.boom }", repl: true)
        let details = try XCTUnwrap(answer["exceptionDetails"] as? [String: Any], "\(answer)")
        XCTAssertEqual(details["text"] as? String, "Uncaught")
        XCTAssertNotNil(details["exceptionId"] as? Int)
        XCTAssertNotNil(details["scriptId"] as? String)
        XCTAssertEqual(details["lineNumber"] as? Int, 1, "\(details)")
        let exception = try XCTUnwrap(details["exception"] as? [String: Any])
        XCTAssertEqual(exception["type"] as? String, "object")
        XCTAssertEqual(exception["subtype"] as? String, "error")
        XCTAssertEqual(exception["className"] as? String, "TypeError")
        let description = try XCTUnwrap(exception["description"] as? String)
        XCTAssertTrue(description.hasPrefix("TypeError: null is not an object"), description)
        XCTAssertTrue(description.contains("at <anonymous>:2:"), description)
        let frames = try XCTUnwrap((details["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]])
        XCTAssertEqual(frames.first?["lineNumber"] as? Int, 1)

        // A thrown non-error is described, not by value.
        let string = try await evaluate("throw 'plain text'")
        let thrownString = try XCTUnwrap((string["exceptionDetails"] as? [String: Any])?["exception"] as? [String: Any])
        XCTAssertEqual(thrownString as NSDictionary, ["type": "string", "value": "plain text"] as NSDictionary)

        // An awaited promise that rejects.
        let rejected = try await evaluate("Promise.reject(new RangeError('out'))")
        let rejection = try XCTUnwrap((rejected["exceptionDetails"] as? [String: Any])?["exception"] as? [String: Any])
        XCTAssertEqual(rejection["className"] as? String, "RangeError")
        XCTAssertTrue((rejection["description"] as? String ?? "").hasPrefix("RangeError: out"))
    }

    /// A compile error has a scriptId and no stack trace; a SyntaxError
    /// thrown at run time (JSON.parse) has a stack trace. Exactly the
    /// distinction the Claude extension's retry rests on.
    @MainActor func testSyntaxErrorsAtCompileAndRunTime() async throws {
        try await load("plain")
        let compile = try await evaluate("{ 1 + }", repl: true)
        let compileDetails = try XCTUnwrap(compile["exceptionDetails"] as? [String: Any])
        XCTAssertNil(compileDetails["stackTrace"])
        XCTAssertNotNil(compileDetails["scriptId"] as? String)
        let compileException = try XCTUnwrap(compileDetails["exception"] as? [String: Any])
        XCTAssertEqual(compileException["className"] as? String, "SyntaxError")
        XCTAssertEqual(compileException["description"] as? String, "SyntaxError: Unexpected token '}'")

        let illegal = try await evaluate("{return 1\n}", repl: true)
        let illegalException = try XCTUnwrap((illegal["exceptionDetails"] as? [String: Any])?["exception"] as? [String: Any])
        XCTAssertEqual(illegalException["description"] as? String, "SyntaxError: Illegal return statement")
        XCTAssertNil((illegal["exceptionDetails"] as? [String: Any])?["stackTrace"])
        // With top-level await around it, too.
        let awaitAndReturn = try await evaluate("{ await 1;\n return 2\n}", repl: true)
        XCTAssertEqual(((awaitAndReturn["exceptionDetails"] as? [String: Any])?["exception"] as? [String: Any])?["description"]
                       as? String, "SyntaxError: Illegal return statement")
        XCTAssertEqual((awaitAndReturn["exceptionDetails"] as? [String: Any])?["lineNumber"] as? Int, 1)
        // Top-level await outside REPL mode: V8's words.
        let awaitOutside = try await evaluate("await 1", repl: false)
        XCTAssertEqual(((awaitOutside["exceptionDetails"] as? [String: Any])?["exception"] as? [String: Any])?["description"]
                       as? String, "SyntaxError: await is only valid in async functions and the top level bodies of modules")

        let runtime = try await evaluate("JSON.parse('{')", repl: true)
        let runtimeDetails = try XCTUnwrap(runtime["exceptionDetails"] as? [String: Any])
        XCTAssertEqual((runtimeDetails["exception"] as? [String: Any])?["className"] as? String, "SyntaxError")
        XCTAssertNotNil(runtimeDetails["stackTrace"], "a run-time SyntaxError has a stack")
    }

    /// The Claude extension's two calls, exactly: the block in REPL mode,
    /// and on "Illegal return statement" the async function outside it.
    @MainActor func testTheClaudeExtensionsReturnRetrySucceeds() async throws {
        try await load("plain")
        let code = "const items = [1, 2, 3];\nif (items.length) return items.length * 10;\nreturn 0"
        let first = try await evaluate("{\(code)\n}", repl: true)
        let details = try XCTUnwrap(first["exceptionDetails"] as? [String: Any])
        let exception = try XCTUnwrap(details["exception"] as? [String: Any])
        let retries = exception["className"] as? String == "SyntaxError" && details["stackTrace"] == nil
            && details["scriptId"] != nil && (exception["description"] as? String ?? "").contains("Illegal return statement")
        XCTAssertTrue(retries, "\(first)")
        let second = try result(try await evaluate("(async()=>{\n\(code)\n})()", repl: false))
        XCTAssertEqual(second["value"] as? Int, 30)
    }

    // MARK: - Timeout (AC #3), let/const (AC #4)

    @MainActor func testTimeoutEndsANeverSettlingEvaluation() async throws {
        try await load("plain")
        let request = ExtensionDebuggerEvaluation.Request(expression: "new Promise(() => {})", returnByValue: true,
                                                          awaitPromise: true, replMode: false, timeout: 300)
        let started = Date()
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
            let reply = ExtensionDebuggerReply { value, error in continuation.resume(returning: (value != nil, error)) }
            // The command path, timer included, without a session.
            ExtensionDebuggerEvaluation.start(request, in: webView, reply: reply)
        }
        XCTAssertFalse(outcome.0)
        XCTAssertEqual(outcome.1, #"{"code":-32000,"message":"Execution was terminated"}"#)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // The page is still usable afterwards.
        let after = try result(try await evaluate("1"))
        XCTAssertEqual(after["value"] as? Int, 1)
    }

    @MainActor func testLetAndConstCanBeDeclaredAgainInTheNextEvaluation() async throws {
        try await load("plain")
        for _ in 0..<2 {
            let value = try result(try await evaluate("let counter = 1; const fixed = 2; counter + fixed", repl: true))
            XCTAssertEqual(value["value"] as? Int, 3)
            let wrapped = try result(try await evaluate("{let counter = 1; const fixed = 2; counter + fixed\n}", repl: true))
            XCTAssertEqual(wrapped["value"] as? Int, 3)
        }
    }

    // MARK: - CSP

    /// A page whose CSP forbids eval: the evaluation still runs in its world,
    /// with its completion value, an awaited promise and its errors.
    @MainActor func testEvaluationWorksOnAPageWhoseCSPForbidsEval() async throws {
        try await load("csp")
        let evalBlocked = try await webView.callAsyncJavaScript(
            "try { (0, eval)('1'); return false; } catch (e) { return e instanceof EvalError; }",
            arguments: [:], contentWorld: .page)
        XCTAssertEqual(evalBlocked as? Bool, true, "the fixture's CSP must forbid eval")
        _ = try await webView.callAsyncJavaScript("window.secret = 41;", arguments: [:], contentWorld: .page)
        let block = try result(try await evaluate("{ const x = await Promise.resolve(1); secret + x }", repl: true))
        XCTAssertEqual(block["value"] as? Int, 42)
        let title = try result(try await evaluate("document.title"))
        XCTAssertEqual(title["value"] as? String, "csp")
        let thrown = try await evaluate("{ undefinedFunction() }", repl: true)
        XCTAssertEqual(((thrown["exceptionDetails"] as? [String: Any])?["exception"] as? [String: Any])?["className"] as? String,
                       "ReferenceError")
        let syntax = try await evaluate("{return 1\n}", repl: true)
        XCTAssertEqual(((syntax["exceptionDetails"] as? [String: Any])?["exception"] as? [String: Any])?["description"]
                       as? String, "SyntaxError: Illegal return statement")
        // eval inside the evaluated code stays subject to the page's CSP.
        let inner = try await evaluate("eval('1')")
        XCTAssertEqual(((inner["exceptionDetails"] as? [String: Any])?["exception"] as? [String: Any])?["className"] as? String,
                       "EvalError")
    }
}
