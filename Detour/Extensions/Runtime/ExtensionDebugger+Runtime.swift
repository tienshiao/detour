import Foundation
import WebKit

// TASK-132.15: the CDP Runtime domain — `Runtime.evaluate`, and `enable` /
// `disable` as domain switches (console events are TASK-132.16).
//
// How an evaluation runs, and why (measured on the shipped WebKit with a page
// served under `Content-Security-Policy: script-src 'self'`):
//
//  - `eval` and `new Function` in the page's world are refused under such a
//    CSP ("EvalError: Refused to evaluate a string as JavaScript…"); Chrome's
//    Runtime.evaluate ignores the page's CSP, and many sites have one.
//  - `evaluateJavaScript` of a raw script is not refused and keeps script
//    semantics, but answers by value only (a promise or a DOM node is "an
//    unsupported type"), so nothing can be awaited or described, and
//    top-level `await` is a SyntaxError.
//  - `callAsyncJavaScript` in the page world is not refused either: the code
//    becomes the body of an async function, sees the page's globals and may
//    `await`. A function body has no completion value, though, and allows
//    `return`.
//  - A named content world (Detour's `DetourDebugger`) may `eval` and
//    `new Function` whatever the page's CSP; it shares the DOM, not the
//    page's globals.
//
// So the code is compiled and checked in Detour's world, then run in the page
// world through `callAsyncJavaScript`:
//
//  1. Syntax, in Detour's world, without running anything: as a function body
//     (`new Function`), then as a script (`eval` of `if (0) { code }` inside a
//     function, where `return` is illegal and `var`s stay local). An eval's
//     SyntaxError has the caller's line, so a script-only error is placed by
//     compiling the code in a class static block too. In REPL mode
//     `await` words are blanked first (`ExtensionDebuggerReplSource`), since
//     V8's REPL mode allows top-level await. A failure is reported as V8
//     reports a compile error — `exceptionDetails` with a SyntaxError, a
//     `scriptId` and no `stackTrace` — with JSC's message, V8's wording
//     where the Claude extension depends on it ("Illegal return statement").
//  2. The completion value: the last statement is rewritten to store its value
//     (`ExtensionDebuggerReplSource`); each candidate rewrite is compiled as an
//     async function in Detour's world and the first that compiles is used.
//     None compiling, the code runs unchanged and the value is undefined.
//  3. The page runs the async function, awaits the value when V8 would (not
//     in REPL mode, where V8 returns the completion value as it is; with
//     `awaitPromise` otherwise) and describes the outcome as a CDP
//     RemoteObject: by value (V8's `toProtocolValue`: own enumerable
//     properties, `undefined` ones dropped, depth 1000) with `returnByValue`,
//     otherwise type, subtype, className and description, without object ids.
//
// Not like Chrome:
//  - `let`/`const` never persist between evaluations, and never clash: each
//    evaluation is its own function. Top-level `var` and function declarations
//    are local to the evaluation too, not globals.
//  - Code inside the evaluation that calls `eval`, `new Function` or a string
//    `setTimeout` is still subject to the page's CSP (Chrome lifts it for the
//    evaluation).
//  - `timeout` cannot stop a page that is busy: WebKit has no way to terminate
//    a running script. When it passes, the command answers
//    `{"code":-32000,"message":"Execution was terminated"}` — V8's answer —
//    and whatever the code does later is ignored. Unlike V8, the time spent
//    awaiting a promise counts too, so a promise that never settles ends.
//  - The page's own globals (`Object`, `Promise`, …) are what the description
//    code uses; a page that replaced them can confuse a description.

enum ExtensionDebuggerRuntime {

    /// Returns false for a method this domain does not emulate.
    static func run(_ method: String, params: [String: Any], in session: ExtensionDebuggerSession,
                    reply: ExtensionDebuggerReply) -> Bool {
        switch method {
        case "Runtime.enable":
            session.enabledDomains.insert("Runtime")
            // The document's console messages so far, then each as it comes
            // (TASK-132.16).
            ExtensionDebuggerInstrumentation.stateDidChange(session)
            reply.succeed()
        case "Runtime.disable":
            session.enabledDomains.remove("Runtime")
            ExtensionDebuggerInstrumentation.stateDidChange(session)
            reply.succeed()
        case "Runtime.discardConsoleEntries":
            ExtensionDebuggerInstrumentation.discardConsoleEntries(session)
            reply.succeed()
        case "Runtime.evaluate":
            ExtensionDebuggerEvaluation.evaluate(params: params, in: session, reply: reply)
        default:
            return false
        }
        return true
    }
}

enum ExtensionDebuggerEvaluation {

    struct Request: Equatable {
        var expression: String
        var returnByValue = false
        var awaitPromise = false
        var replMode = false
        /// Milliseconds; nil for none.
        var timeout: Double?

        /// Whether the completion value is awaited: V8 awaits it with
        /// `awaitPromise`, except in REPL mode, where the evaluation's own
        /// promise is awaited and the value inside it returned as it is.
        var awaitsValue: Bool { awaitPromise && !replMode }

        static func parse(_ params: [String: Any]) -> Result<Request, ExtensionDebuggerScreenshot.Failure> {
            guard let expression = params["expression"] as? String else {
                return .failure(.init(message: "Invalid parameters: expression: string value expected"))
            }
            var request = Request(expression: expression)
            for (key, keyPath) in [("returnByValue", \Request.returnByValue), ("awaitPromise", \Request.awaitPromise),
                                   ("replMode", \Request.replMode)] {
                guard let value = params[key], !(value is NSNull) else { continue }
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    return .failure(.init(message: "Invalid parameters: \(key): boolean value expected"))
                }
                request[keyPath: keyPath] = number.boolValue
            }
            if let value = params["timeout"], !(value is NSNull) {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite else {
                    return .failure(.init(message: "Invalid parameters: timeout: number value expected"))
                }
                // Capped: a `Duration` of more milliseconds than this traps.
                request.timeout = number.doubleValue > 0 ? min(number.doubleValue, maximumTimeout) : nil
            }
            return .success(request)
        }

        /// The longest `timeout` honoured, in milliseconds (about 31 years).
        static let maximumTimeout: Double = 1e12
    }

    static let terminatedMessage = "Execution was terminated"
    static let navigatedMessage = "Inspected target navigated or closed"
    static let noContextMessage = "Cannot find default execution context"

    private static var nextExceptionID = 1
    private static var nextScriptID = 1000
    private static var scriptIDsByURL: [String: String] = [:]

    // MARK: Running

    static func evaluate(params: [String: Any], in session: ExtensionDebuggerSession, reply: ExtensionDebuggerReply) {
        let request: Request
        switch Request.parse(params) {
        case .failure(let error):
            reply.fail(code: ExtensionDebugger.invalidParamsCode, message: error.message)
            return
        case .success(let parsed):
            request = parsed
        }
        guard let webView = session.tab?.automationDrivableWebView() ?? session.tab?.webView else {
            reply.fail(code: ExtensionDebugger.serverErrorCode, message: noContextMessage)
            return
        }
        start(request, in: webView, reply: reply)
    }

    /// Runs `request` and answers `reply` once: with the result, or with
    /// "Execution was terminated" when `timeout` passes first.
    static func start(_ request: Request, in webView: WKWebView, reply: ExtensionDebuggerReply) {
        var timer: Task<Void, Never>?
        if let timeout = request.timeout {
            timer = Task {
                guard (try? await Task.sleep(for: .milliseconds(timeout))) != nil else { return }
                reply.fail(code: ExtensionDebugger.serverErrorCode, message: terminatedMessage)
            }
        }
        Task {
            let outcome = await run(request, in: webView)
            timer?.cancel()
            switch outcome {
            case .success(let result): reply.succeed(result)
            case .failure(let error): reply.fail(code: error.code, message: error.message)
            }
        }
    }

    struct Failure: Error, Equatable {
        let code: Int
        let message: String
    }

    /// Evaluates `request` in `webView`'s main frame: the CDP result object,
    /// or the protocol error the command fails with.
    static func run(_ request: Request, in webView: WKWebView) async -> Result<[String: Any], Failure> {
        let scriptID = String(nextScriptID)
        nextScriptID += 1
        let prepared: Prepared
        switch await prepare(request, in: webView) {
        case .failure(let failure): return .failure(failure)
        case .success(.syntaxError(let error)):
            return .success(compileErrorResult(message: error.message, line: error.line, column: error.column,
                                               scriptID: scriptID))
        case .success(.ready(let ready)): prepared = ready
        }
        let options: [String: Any] = ["byValue": request.returnByValue, "awaitValue": request.awaitsValue]
        let optionsJSON = (try? JSONSerialization.data(withJSONObject: options)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let body = "const __detourRun = " + prepared.functionSource + ";\nreturn await (" + pageRunner + ")(__detourRun, "
            + optionsJSON + ");"
        let answer: Any?
        do {
            answer = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            let nsError = error as NSError
            if nsError.domain == WKError.errorDomain, nsError.code == WKError.javaScriptExceptionOccurred.rawValue,
               let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String, message.hasPrefix("SyntaxError") {
                // Code the checks accepted and JSC then refused to compile.
                let text = message.hasPrefix("SyntaxError: ") ? String(message.dropFirst("SyntaxError: ".count)) : message
                return .success(compileErrorResult(message: text, line: 0, column: 0, scriptID: scriptID))
            }
            return .failure(Failure(code: ExtensionDebugger.serverErrorCode, message: navigatedMessage))
        }
        guard let outcome = answer as? [String: Any], let kind = outcome["kind"] as? String else {
            return .failure(Failure(code: ExtensionDebugger.serverErrorCode, message: navigatedMessage))
        }
        switch kind {
        case "result":
            return .success(["result": outcome["result"] ?? ["type": "undefined"]])
        case "fail":
            return .failure(Failure(code: (outcome["code"] as? NSNumber)?.intValue ?? ExtensionDebugger.serverErrorCode,
                                    message: outcome["message"] as? String ?? "Internal error"))
        default:
            return .success(thrownResult(outcome, rewrite: prepared.rewrite, code: request.expression,
                                         scriptID: scriptID))
        }
    }

    // MARK: Preparing

    struct SyntaxErrorInfo: Equatable {
        let message: String
        let line: Int
        let column: Int
    }

    struct Prepared: Equatable {
        /// The async arrow function the page runs.
        let functionSource: String
        /// The rewrite it carries, if any: positions map back through it.
        let rewrite: ExtensionDebuggerReplSource.Rewrite?
    }

    enum Preparation: Equatable {
        case syntaxError(SyntaxErrorInfo)
        case ready(Prepared)
    }

    /// Checks and compiles the code in Detour's content world (see the top of
    /// the file). This is the one boundary a real parser would replace.
    static func prepare(_ request: Request, in webView: WKWebView) async -> Result<Preparation, Failure> {
        let code = request.expression
        let rewrites = ExtensionDebuggerReplSource.rewrites(for: code)
        let candidates = rewrites.map { ExtensionDebuggerReplSource.functionSource(ExtensionDebuggerReplSource.apply($0, to: code)) }
            + [ExtensionDebuggerReplSource.functionSource(code)]
        let arguments: [String: Any] = [
            "code": code,
            "neutralized": ExtensionDebuggerReplSource.neutralizingAwait(code),
            "replMode": request.replMode,
            "candidates": candidates,
        ]
        let answer: Any?
        do {
            answer = try await webView.callAsyncJavaScript(checkScript, arguments: arguments, in: nil,
                                                          contentWorld: ExtensionDebugger.contentWorld)
        } catch {
            return .failure(Failure(code: ExtensionDebugger.serverErrorCode, message: navigatedMessage))
        }
        guard let checked = answer as? [String: Any] else {
            return .failure(Failure(code: ExtensionDebugger.serverErrorCode, message: navigatedMessage))
        }
        if let syntax = checked["syntax"] as? [String: Any] {
            let message = v8SyntaxMessage(syntax["message"] as? String ?? "",
                                          awaitOnly: syntax["awaitOnly"] as? Bool ?? false)
            return .success(.syntaxError(SyntaxErrorInfo(message: message,
                                                         line: max(0, (syntax["line"] as? NSNumber)?.intValue ?? 0),
                                                         column: max(0, (syntax["column"] as? NSNumber)?.intValue ?? 0))))
        }
        let chosen = (checked["chosen"] as? NSNumber)?.intValue ?? -1
        if chosen >= 0, chosen < candidates.count {
            return .success(.ready(Prepared(functionSource: candidates[chosen],
                                            rewrite: chosen < rewrites.count ? rewrites[chosen] : nil)))
        }
        let message = checked["compileError"] as? String ?? "Invalid or unexpected token"
        return .success(.syntaxError(SyntaxErrorInfo(message: v8SyntaxMessage(message, awaitOnly: false), line: 0, column: 0)))
    }

    /// JSC's syntax error text, in V8's words where a client depends on them.
    static func v8SyntaxMessage(_ jsc: String, awaitOnly: Bool) -> String {
        if awaitOnly { return "await is only valid in async functions and the top level bodies of modules" }
        var message = jsc
        if message.hasPrefix("SyntaxError: ") { message = String(message.dropFirst("SyntaxError: ".count)) }
        if message.hasPrefix("Return statements are only valid inside functions") { return "Illegal return statement" }
        if message.hasPrefix("Unexpected end of script") { return "Unexpected end of input" }
        if message.hasPrefix("Unexpected keyword 'return'") { return "Illegal return statement" }
        return message
    }

    // MARK: Results

    /// A compile error, as V8 reports one: no stack trace, the script's id.
    static func compileErrorResult(message: String, line: Int, column: Int, scriptID: String) -> [String: Any] {
        let exception: [String: Any] = [
            "type": "object", "subtype": "error", "className": "SyntaxError",
            "description": "SyntaxError: " + message,
        ]
        let details: [String: Any] = [
            "exceptionId": takeExceptionID(), "text": "Uncaught", "lineNumber": line, "columnNumber": column,
            "scriptId": scriptID, "exception": exception,
        ]
        return ["result": exception, "exceptionDetails": details]
    }

    static func takeExceptionID() -> Int {
        defer { nextExceptionID += 1 }
        return nextExceptionID
    }

    static func urlScriptID(_ url: String) -> String {
        if let existing = scriptIDsByURL[url] { return existing }
        let id = String(nextScriptID)
        nextScriptID += 1
        scriptIDsByURL[url] = id
        return id
    }

    /// One frame of a JSC stack (`name@url:line:column`), 0-based as CDP
    /// counts. Nil for a frame without a place (evaluated code, native code).
    struct StackFrame: Equatable {
        let functionName: String
        let url: String
        let line: Int
        let column: Int
    }

    static func parseStackFrame(_ text: String) -> StackFrame? {
        guard let at = text.firstIndex(of: "@") else { return nil }
        let name = String(text[..<at])
        let location = String(text[text.index(after: at)...])
        let parts = location.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let line = Int(parts[parts.count - 2]), let column = Int(parts[parts.count - 1]) else {
            return nil
        }
        let url = parts.dropLast(2).joined(separator: ":")
        guard !url.isEmpty else { return nil }
        return StackFrame(functionName: name == "global code" ? "" : name, url: url, line: max(0, line - 1),
                          column: max(0, column - 1))
    }

    /// An error's description as V8 gives it — its `stack`: `Name: message`,
    /// then a line per frame (`at fn (url:line:column)`, 1-based).
    static func v8ErrorDescription(name: String, message: String, callFrames: [[String: Any]]) -> String {
        var description = message.isEmpty ? name : (name.isEmpty ? message : "\(name): \(message)")
        for frame in callFrames {
            let url = frame["url"] as? String ?? ""
            let line = (frame["lineNumber"] as? Int ?? 0) + 1
            let column = (frame["columnNumber"] as? Int ?? 0) + 1
            let function = frame["functionName"] as? String ?? ""
            if url.isEmpty {
                description += "\n    at <anonymous>:\(line):\(column)"
            } else if function.isEmpty {
                description += "\n    at \(url):\(line):\(column)"
            } else {
                description += "\n    at \(function) (\(url):\(line):\(column))"
            }
        }
        return description
    }

    /// The result of code that threw (or whose awaited value rejected).
    static func thrownResult(_ outcome: [String: Any], rewrite: ExtensionDebuggerReplSource.Rewrite?, code: String,
                             scriptID: String) -> [String: Any] {
        var exception = outcome["exception"] as? [String: Any] ?? ["type": "undefined"]
        let error = outcome["error"] as? [String: Any]
        let sourceURL = error?["sourceURL"] as? String ?? ""
        let stackText = error?["stack"] as? String ?? ""
        let pageFrames = stackText.split(separator: "\n").compactMap { parseStackFrame(String($0)) }
        // Where the evaluated code threw, when it threw itself.
        var position = (line: 0, column: 0)
        if sourceURL.isEmpty, let line = (error?["line"] as? NSNumber)?.intValue,
           let column = (error?["column"] as? NSNumber)?.intValue {
            // JSC's line counts the page function's first line as 1; ours
            // starts the arrow function there. Its column is 1-based.
            position = ExtensionDebuggerReplSource.originalPosition(line: line - 1, column: column - 1, rewrite: rewrite,
                                                                    in: code)
        }
        var callFrames: [[String: Any]] = []
        if !sourceURL.isEmpty, let top = pageFrames.first {
            for frame in pageFrames {
                callFrames.append(["functionName": frame.functionName, "scriptId": urlScriptID(frame.url),
                                   "url": frame.url, "lineNumber": frame.line, "columnNumber": frame.column])
            }
            position = (top.line, top.column)
        }
        callFrames.append(["functionName": "", "scriptId": scriptID, "url": "",
                           "lineNumber": sourceURL.isEmpty ? position.line : 0,
                           "columnNumber": sourceURL.isEmpty ? position.column : 0])
        if let error, error["isError"] as? Bool == true {
            let name = error["name"] as? String ?? (exception["className"] as? String ?? "Error")
            let message = error["message"] as? String ?? ""
            exception["description"] = v8ErrorDescription(name: name, message: message, callFrames: callFrames)
        }
        var details: [String: Any] = [
            "exceptionId": takeExceptionID(), "text": "Uncaught",
            "lineNumber": position.line, "columnNumber": position.column,
            "scriptId": sourceURL.isEmpty ? scriptID : urlScriptID(sourceURL),
            "stackTrace": ["callFrames": callFrames],
            "exception": exception,
        ]
        if !sourceURL.isEmpty { details["url"] = sourceURL }
        return ["result": exception, "exceptionDetails": details]
    }

    // MARK: Scripts

    /// Runs in Detour's content world: syntax checks, then the first
    /// candidate that compiles (the last candidate is the unchanged code).
    /// Nothing the evaluated code says is run here.
    static let checkScript = """
        const AsyncFunction = (async function () {}).constructor;
        // JSC counts lines from the wrapper's first: find where line 1 of
        // the checked code lands in each check.
        const lineOf = (e) => (typeof e.line === 'number' ? e.line : 0);
        const columnOf = (e) => (typeof e.column === 'number' ? Math.max(0, e.column - 1) : 0);
        const asBody = (src) => { new Function(src); };
        const asScript = (src) => { (function () { eval('if (0) {\\n' + src + '\\n}'); })(); };
        const base = (check) => { try { check('1 1'); } catch (e) { return lineOf(e); } return 1; };
        // An eval's SyntaxError carries the caller's position, not the
        // code's: a script-only error (an illegal `return`) is placed by
        // compiling the code again in a class static block, where `return` is
        // illegal too and positions are the code's own.
        const inStaticBlock = (src) => { new Function('class __detourCheck { static {\\n' + src + '\\n} }'); };
        const bases = [base(asBody), base(asScript), base(inStaticBlock)];
        const scriptError = (src) => {
            try { asBody(src); } catch (e) {
                return { message: String(e && e.message), line: Math.max(0, lineOf(e) - bases[0]), column: columnOf(e) };
            }
            try { asScript(src); } catch (e) {
                const failure = { message: String(e && e.message), line: 0, column: 0 };
                try { inStaticBlock(src); } catch (located) {
                    if (String(located && located.message) === failure.message) {
                        failure.line = Math.max(0, lineOf(located) - bases[2]);
                        failure.column = columnOf(located);
                    }
                }
                return failure;
            }
            return null;
        };
        if (replMode) {
            const failure = scriptError(neutralized);
            if (failure) return { syntax: failure };
        } else {
            const failure = scriptError(code);
            if (failure) {
                failure.awaitOnly = neutralized !== code && scriptError(neutralized) === null;
                return { syntax: failure };
            }
        }
        let compileError = null;
        for (let i = 0; i < candidates.length; i++) {
            try {
                new AsyncFunction('return (' + candidates[i] + '\\n)');
                return { chosen: i };
            } catch (e) {
                compileError = String(e && e.message);
            }
        }
        return { chosen: -1, compileError: compileError };
        """

    /// Describes a value as V8 does, in the page world: `remote(value, byValue)`
    /// gives a `RemoteObject` (throwing `Unreturnable` when a by-value result
    /// cannot be made). It captures the page's intrinsics where it is placed:
    /// at each evaluation in `pageRunner`, and at document start in the
    /// console instrumentation (TASK-132.16), which shares it.
    static let describerSource = """
            const ObjectRef = Object, ArrayRef = Array, StringRef = String;
            const toTag = ObjectRef.prototype.toString, getPrototypeOf = ObjectRef.getPrototypeOf;
            const keysOf = ObjectRef.keys, isArray = ArrayRef.isArray, define = ObjectRef.defineProperty, same = ObjectRef.is;
            const isView = ArrayBuffer.isView, NodeRef = typeof Node === 'function' ? Node : null;
            const DOMExceptionRef = typeof DOMException === 'function' ? DOMException : null;
            const functionText = Function.prototype.toString;
            const tag = (v) => { try { return toTag.call(v); } catch (e) { return '[object Object]'; } };
            const className = (v) => {
                try {
                    const proto = getPrototypeOf(v);
                    const name = proto && proto.constructor && proto.constructor.name;
                    if (typeof name === 'string' && name) return name;
                } catch (e) {}
                return tag(v).slice(8, -1) || 'Object';
            };
            const isNode = (v) => { try { return !!NodeRef && v instanceof NodeRef; } catch (e) { return false; } };
            const isError = (v) => {
                if (tag(v) === '[object Error]') return true;
                try { return !!DOMExceptionRef && v instanceof DOMExceptionRef; } catch (e) { return false; }
            };
            const subtypeOf = (v) => {
                if (isArray(v)) return 'array';
                if (isNode(v)) return 'node';
                switch (tag(v)) {
                case '[object RegExp]': return 'regexp';
                case '[object Date]': return 'date';
                case '[object Map]': return 'map';
                case '[object Set]': return 'set';
                case '[object WeakMap]': return 'weakmap';
                case '[object WeakSet]': return 'weakset';
                case '[object Promise]': return 'promise';
                case '[object ArrayBuffer]': return 'arraybuffer';
                case '[object DataView]': return 'dataview';
                case '[object Generator]': return 'generator';
                }
                try { if (isView(v)) return 'typedarray'; } catch (e) {}
                if (isError(v)) return 'error';
                return undefined;
            };
            const nodeDescription = (node) => {
                try {
                    if (node.nodeType === 1) {
                        let text = StringRef(node.localName || node.nodeName).toLowerCase();
                        if (node.id) text += '#' + node.id;
                        const classes = typeof node.className === 'string' ? node.className.trim() : '';
                        if (classes) text += '.' + classes.split(/\\s+/).join('.');
                        return text;
                    }
                    if (node.nodeType === 10) return '<!DOCTYPE ' + node.name + '>';
                    return StringRef(node.nodeName);
                } catch (e) { return 'Node'; }
            };
            const objectDescription = (v, subtype) => {
                try {
                    switch (subtype) {
                    case 'array': return 'Array(' + v.length + ')';
                    case 'typedarray': return className(v) + '(' + v.length + ')';
                    case 'map': case 'set': return className(v) + '(' + v.size + ')';
                    case 'arraybuffer': case 'dataview': return className(v) + '(' + v.byteLength + ')';
                    case 'node': return nodeDescription(v);
                    case 'regexp': return '/' + v.source + '/' + v.flags;
                    case 'date': return StringRef(v);
                    case 'error': {
                        const name = typeof v.name === 'string' ? v.name : className(v);
                        const message = typeof v.message === 'string' ? v.message : '';
                        return message ? name + ': ' + message : name;
                    }
                    }
                } catch (e) {}
                return className(v);
            };
            class Unreturnable { constructor(message, code) { this.message = message; this.code = code; } }
            let budget = 1000000;
            const take = (count) => { budget -= count; if (budget < 0) throw new Unreturnable('Object is too large to be returned by value', -32000); };
            const toValue = (v, depth) => {
                if (depth <= 0) throw new Unreturnable('Object reference chain is too long', -32000);
                if (v === null || v === undefined) return null;
                switch (typeof v) {
                case 'boolean': return v;
                case 'string': take(v.length / 64); return v;
                case 'number': return isFinite(v) ? (same(v, -0) ? 0 : v) : null;
                case 'bigint': case 'symbol': throw new Unreturnable("Object couldn't be returned by value", -32000);
                }
                if (isArray(v)) {
                    const length = v.length;
                    if (length > 10000000) throw new Unreturnable('Array length exceeds maximum limit', -32000);
                    take(length);
                    const out = [];
                    for (let i = 0; i < length; i++) out.push(toValue(v[i], depth - 1));
                    return out;
                }
                const names = keysOf(v);
                take(names.length);
                const out = {};
                for (const name of names) {
                    const property = v[name];
                    if (property === undefined) continue;
                    define(out, name, { value: toValue(property, depth - 1), enumerable: true, configurable: true, writable: true });
                }
                return out;
            };
            const numberObject = (v) => {
                if (same(v, NaN) || v === Infinity || v === -Infinity || same(v, -0)) {
                    const text = same(v, -0) ? '-0' : StringRef(v);
                    return { type: 'number', unserializableValue: text, description: text };
                }
                return { type: 'number', value: v, description: StringRef(v) };
            };
            const remote = (v, byValue) => {
                switch (typeof v) {
                case 'undefined': return { type: 'undefined' };
                case 'boolean': return { type: 'boolean', value: v };
                case 'string': return { type: 'string', value: v };
                case 'number': return numberObject(v);
                case 'bigint': { const text = StringRef(v) + 'n'; return { type: 'bigint', unserializableValue: text, description: text }; }
                case 'symbol':
                    if (byValue) throw new Unreturnable("Object couldn't be returned by value", -32000);
                    return { type: 'symbol', description: v.toString() };
                }
                if (v === null) return { type: 'object', subtype: 'null', value: null };
                if (typeof v === 'function') {
                    if (byValue) return { type: 'function', value: toValue(v, 1000) };
                    let text = '';
                    try { text = functionText.call(v); } catch (e) {}
                    return { type: 'function', className: className(v), description: text };
                }
                if (byValue) return { type: 'object', value: toValue(v, 1000) };
                const subtype = subtypeOf(v);
                const object = { type: 'object', className: className(v), description: objectDescription(v, subtype) };
                if (subtype) object.subtype = subtype;
                return object;
            };
        """

    /// Runs in the page world, called with the evaluated function and the
    /// options: runs it, awaits as asked, and describes what came out.
    static let pageRunner = "async function (run, options) {\n" + describerSource + "\n" + """
            const thrown = (e) => {
                let exception;
                try { exception = remote(e, false); } catch (failure) { exception = { type: 'object', className: 'Object', description: 'Object' }; }
                const error = { isError: false };
                if (e !== null && (typeof e === 'object' || typeof e === 'function') && isError(e)) {
                    exception = { type: 'object', subtype: 'error', className: className(e) };
                    error.isError = true;
                    try { error.name = StringRef(e.name); } catch (x) {}
                    try { error.message = StringRef(e.message); } catch (x) {}
                }
                if (e !== null && typeof e === 'object') {
                    try { if (typeof e.stack === 'string') error.stack = e.stack; } catch (x) {}
                    try { if (typeof e.line === 'number') error.line = e.line; } catch (x) {}
                    try { if (typeof e.column === 'number') error.column = e.column; } catch (x) {}
                    try { if (typeof e.sourceURL === 'string') error.sourceURL = e.sourceURL; } catch (x) {}
                }
                return { kind: 'thrown', exception: exception, error: error };
            };
            let value;
            try {
                value = (await run(undefined))[0];
            } catch (e) {
                return thrown(e);
            }
            if (options.awaitValue) {
                try { value = await value; } catch (e) { return thrown(e); }
            }
            try {
                return { kind: 'result', result: remote(value, options.byValue) };
            } catch (e) {
                if (e instanceof Unreturnable) return { kind: 'fail', message: e.message, code: e.code };
                return { kind: 'fail', message: 'Internal error', code: -32603 };
            }
        }
        """
}
