import XCTest
import WebKit
@testable import Detour

/// TASK-132.15: the pure parts of Runtime.evaluate, dialogs and frames.
nonisolated final class ExtensionDebuggerRuntimeUnitTests: XCTestCase {

    private typealias Source = ExtensionDebuggerReplSource

    /// The text each rewrite candidate would assign, latest first.
    @MainActor private func tails(_ code: String) -> [String] {
        let units = Array(code.utf16)
        return Source.rewrites(for: code).map {
            String(utf16CodeUnits: Array(units[$0.start..<$0.end]), count: $0.end - $0.start)
        }
    }

    // MARK: - Tokens

    @MainActor func testTokensSkipStringsTemplatesCommentsAndRegexes() {
        let tokens = Source.tokenize("a = 'x;}' + `t${ {b: 1}.b }u`; // c;}\n/re;}/g.test(s) / 2")
        XCTAssertEqual(tokens.map(\.text), ["a", "=", "'x;}'", "+", "`t${", "{", "b", ":", "1", "}", ".", "b", "}u`",
                                            ";", "/re;}/g", ".", "test", "(", "s", ")", "/", "2"])
        XCTAssertEqual(tokens.first { $0.text == "/re;}/g" }?.kind, .regex)
        XCTAssertEqual(tokens.last { $0.text == "/" }?.kind, .punctuator, "after ) a slash divides")
        XCTAssertEqual(tokens.first { $0.text == "{" }?.depth, 1, "inside the template's hole")
        XCTAssertTrue(tokens.first { $0.text == "/re;}/g" }?.newlineBefore == true)
    }

    @MainActor func testRegexAfterKeywordsAndDivisionAfterOperands() {
        XCTAssertEqual(Source.tokenize("return /x/").last?.kind, .regex)
        XCTAssertEqual(Source.tokenize("x = a / b / c").filter { $0.kind == .regex }.count, 0)
        XCTAssertEqual(Source.tokenize("f(/[/]/)")[2].kind, .regex, "a slash inside a class does not end it")
        XCTAssertEqual(Source.tokenize("{}\n/a/.test(b)")[2].kind, .regex, "after a block, a regex")
        XCTAssertEqual(Source.tokenize("x = {}\n/a/g").filter { $0.kind == .regex }.count, 0, "after an object, division")
    }

    // MARK: - Rewrites

    @MainActor func testTheLastStatementIsFound() {
        XCTAssertEqual(tails("1 + 1").first, "1 + 1")
        XCTAssertEqual(tails("a; b").first, "b")
        XCTAssertEqual(tails("a;\nb;;").first, "b")
        XCTAssertEqual(tails("let x = 1\nx").first, "x")
        XCTAssertEqual(tails("{let x = 1; x + 1\n}").first, "x + 1", "into the block the extension wraps code in")
        XCTAssertEqual(tails("{ a; { b } }").first, "b", "recursively")
        XCTAssertEqual(tails("x = a\n(b)").first, "x = a\n(b)", "a line break before ( continues")
        XCTAssertEqual(tails("x = a\n.b()").first, "x = a\n.b()")
        XCTAssertEqual(tails("x = a +\nb").first, "x = a +\nb", "an operator asks for more")
        XCTAssertEqual(tails("x = 1\n++y").first, "++y", "++ after a line break starts a statement")
        XCTAssertEqual(tails("function f() {}\nf()").first, "f()")
        XCTAssertEqual(tails("function f() {} f()").first, "f()")
        XCTAssertEqual(tails("x = function () {}(1)").first, "x = function () {}(1)")
        XCTAssertEqual(tails("(async()=>{\nreturn 1\n})()"), ["(async()=>{\nreturn 1\n})()"])
        XCTAssertEqual(tails("s = 'a;b'; t = `;${'}'}`; t").first, "t")
    }

    @MainActor func testStatementsThatAreNotExpressionsAreNotRewritten() {
        XCTAssertEqual(tails("let x = 1"), [])
        XCTAssertEqual(tails("1; function f() {}"), [])
        XCTAssertEqual(tails("if (a) b"), [])
        XCTAssertEqual(tails("class A {}"), [])
        XCTAssertEqual(tails("async function g() {}"), [])
        XCTAssertEqual(tails(""), [])
    }

    @MainActor func testApplyAndPositionsMapBack() {
        let code = "let a = 1;\nnull.boom"
        let rewrite = try! XCTUnwrap(Source.rewrites(for: code).first)
        let applied = Source.apply(rewrite, to: code)
        XCTAssertEqual(applied, "let a = 1;\n\(Source.completionName) = (null.boom\n)")
        // In the function, line 0 is `async (…) => {`; `boom` is at line 2 of
        // the function, after the inserted text.
        let column = (Source.completionName + " = (null.").utf16.count
        let mapped = Source.originalPosition(line: 2, column: column, rewrite: rewrite, in: code)
        XCTAssertEqual(mapped.line, 1)
        XCTAssertEqual(mapped.column, 5)
        XCTAssertEqual(Source.originalPosition(line: 1, column: 4, rewrite: rewrite, in: code).column, 4)
    }

    @MainActor func testAwaitIsBlankedForTheScriptCheck() {
        XCTAssertEqual(Source.neutralizingAwait("{ const x = await f(); for await (const y of z) {} }"),
                       "{ const x = void  f(); for       (const y of z) {} }")
        XCTAssertEqual(Source.neutralizingAwait("s = 'await'"), "s = 'await'")
    }

    // MARK: - Requests and messages

    @MainActor func testRequestParsing() {
        let parsed = ExtensionDebuggerEvaluation.Request.parse(["expression": "1", "returnByValue": true,
                                                                "awaitPromise": true, "replMode": true, "timeout": 5000])
        XCTAssertEqual(try? parsed.get(), ExtensionDebuggerEvaluation.Request(expression: "1", returnByValue: true,
                                                                             awaitPromise: true, replMode: true, timeout: 5000))
        XCTAssertEqual(try? parsed.get().awaitsValue, false, "REPL mode returns the value as it is")
        XCTAssertEqual(try? ExtensionDebuggerEvaluation.Request.parse(["expression": "1", "awaitPromise": true]).get().awaitsValue,
                       true)
        if case .success = ExtensionDebuggerEvaluation.Request.parse([:]) { XCTFail("expression is required") }
        if case .success = ExtensionDebuggerEvaluation.Request.parse(["expression": "1", "replMode": 1]) {
            XCTFail("replMode must be a boolean")
        }
        XCTAssertNil(try? ExtensionDebuggerEvaluation.Request.parse(["expression": "1", "timeout": 0]).get().timeout)
    }

    @MainActor func testSyntaxMessagesInV8sWords() {
        XCTAssertEqual(ExtensionDebuggerEvaluation.v8SyntaxMessage("Return statements are only valid inside functions.",
                                                                  awaitOnly: false), "Illegal return statement")
        XCTAssertEqual(ExtensionDebuggerEvaluation.v8SyntaxMessage("SyntaxError: Unexpected end of script", awaitOnly: false),
                       "Unexpected end of input")
        XCTAssertEqual(ExtensionDebuggerEvaluation.v8SyntaxMessage("Unexpected token '}'", awaitOnly: false),
                       "Unexpected token '}'")
        XCTAssertEqual(ExtensionDebuggerEvaluation.v8SyntaxMessage("anything", awaitOnly: true),
                       "await is only valid in async functions and the top level bodies of modules")
    }

    @MainActor func testCompileErrorResultHasNoStackTrace() {
        let result = ExtensionDebuggerEvaluation.compileErrorResult(message: "Illegal return statement", line: 0, column: 1,
                                                                    scriptID: "7")
        let details = result["exceptionDetails"] as? [String: Any]
        XCTAssertEqual(details?["scriptId"] as? String, "7")
        XCTAssertNil(details?["stackTrace"])
        XCTAssertEqual((details?["exception"] as? [String: Any])?["className"] as? String, "SyntaxError")
        XCTAssertEqual((details?["exception"] as? [String: Any])?["description"] as? String,
                       "SyntaxError: Illegal return statement")
    }

    @MainActor func testStackFramesParse() {
        XCTAssertEqual(ExtensionDebuggerEvaluation.parseStackFrame("go@https://a.example/x.js:10:5"),
                       .init(functionName: "go", url: "https://a.example/x.js", line: 9, column: 4))
        XCTAssertEqual(ExtensionDebuggerEvaluation.parseStackFrame("global code@http://h:8080/p.js:1:1"),
                       .init(functionName: "", url: "http://h:8080/p.js", line: 0, column: 0))
        XCTAssertNil(ExtensionDebuggerEvaluation.parseStackFrame("@"))
        XCTAssertNil(ExtensionDebuggerEvaluation.parseStackFrame("map@[native code]"))
    }

    // MARK: - Dialogs and frames

    @MainActor func testDialogDecisions() {
        XCTAssertEqual(ExtensionDebuggerDialogs.decision(pageEnabled: true, displayed: true), .report)
        XCTAssertEqual(ExtensionDebuggerDialogs.decision(pageEnabled: true, displayed: false), .report)
        XCTAssertEqual(ExtensionDebuggerDialogs.decision(pageEnabled: false, displayed: true), .show)
        XCTAssertEqual(ExtensionDebuggerDialogs.decision(pageEnabled: false, displayed: false), .answerAtOnce,
                       "a parked tab's dialog never becomes a sheet over the user's tab")
    }

    @MainActor func testFrameFields() {
        let url = URL(string: "https://www.example.com:8443/a/b?q=1#frag")
        let frame = ExtensionDebuggerFrame(id: "F", loaderID: "L", url: url, mimeType: "text/html", isSecureContext: true)
        let object = frame.protocolObject
        XCTAssertEqual(object["url"] as? String, "https://www.example.com:8443/a/b?q=1")
        XCTAssertEqual(object["urlFragment"] as? String, "#frag")
        XCTAssertEqual(object["securityOrigin"] as? String, "https://www.example.com:8443")
        XCTAssertEqual(object["domainAndRegistry"] as? String, "example.com")
        XCTAssertEqual(object["secureContextType"] as? String, "Secure")
        XCTAssertEqual(object["crossOriginIsolatedContextType"] as? String, "NotIsolated")
        XCTAssertNil(object["parentId"], "a main frame has no parent")
        XCTAssertEqual(ExtensionDebuggerFrame.securityOrigin(URL(string: "http://127.0.0.1:80/")), "http://127.0.0.1")
        XCTAssertEqual(ExtensionDebuggerFrame.securityOrigin(URL(string: "about:blank")), "null")
        XCTAssertEqual(ExtensionDebuggerFrame.domainAndRegistry(URL(string: "http://127.0.0.1:9/")), "")
        XCTAssertEqual(ExtensionDebuggerFrame.secureContextType(URL(string: "http://localhost/"), isSecureContext: true),
                       "SecureLocalhost")
        XCTAssertEqual(ExtensionDebuggerFrame.secureContextType(URL(string: "http://a.test/"), isSecureContext: false),
                       "InsecureScheme")
        let token = ExtensionDebuggerFrames.makeToken()
        XCTAssertEqual(token.count, 32)
        XCTAssertNotEqual(token, ExtensionDebuggerFrames.makeToken())
    }
}
