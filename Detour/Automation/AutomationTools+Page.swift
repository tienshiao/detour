import AppKit
import WebKit

/// The page inspection tools of TASK-228.4: run JavaScript, read a page's
/// text, HTML and interactive elements, its console and network records,
/// wait for something to happen, and wake a sleeping tab. They take any
/// live tab of a non-Private space (or a favorite), whether or not a window
/// shows it; see `AutomationPage` for the scripts and
/// `AutomationPageCapture` for the console and network records.
extension AutomationTools {

    var pageTools: [MCPTool] {
        [evaluateJS, readPage, consoleMessages, networkRequests, waitFor, wakeTab]
    }

    // MARK: Lookup

    /// The tab a `context` names: a tab of a non-Private space, normal or
    /// pinned, or a live favorite. Live or asleep.
    func resolveTab(context value: String) throws -> BrowserTab {
        guard case .tab(let id) = try AutomationContextID.parse(value) else {
            throw AutomationToolError(.unsupportedContext, "\(value) is not a tab")
        }
        let store = environment.store
        let isPrivate = store.spaces.contains { space in
            space.isIncognito && (space.tabs.contains { $0.id == id } || space.pinnedTabs.contains { $0.id == id })
        }
        if isPrivate { throw AutomationToolError(.privateUnreachable, "Tab \(id.uuidString) is in a Private space") }
        guard let tab = AutomationPageCapture.reachableTabs(in: store).first(where: { $0.id == id }) else {
            throw AutomationToolError(.unknownContext, "No open tab \(id.uuidString)")
        }
        return tab
    }

    /// The tab a `context` names and its web view, which need not be in a
    /// window. A sleeping tab (its page unloaded) is `tab_asleep`.
    func resolvePage(context value: String) throws -> (BrowserTab, WKWebView) {
        let tab = try resolveTab(context: value)
        guard let webView = tab.webView else {
            throw AutomationToolError(.tabAsleep, "Tab \(tab.id.uuidString) is asleep; wake it with wake_tab or select_tab")
        }
        // A web view shown in a Private window is never reachable, whatever
        // the space says.
        if AutomationMenus.isPrivate(webView.window) {
            throw AutomationToolError(.privateUnreachable, "Tab \(tab.id.uuidString) is in a Private window")
        }
        return (tab, webView)
    }

    func boundedInt(_ arguments: ToolArguments, _ name: String, default value: Int,
                    range: ClosedRange<Int>) throws -> Int {
        let given = try arguments.int(name) ?? value
        guard range.contains(given) else {
            throw AutomationToolError(.invalidArguments, "\(name) is \(range.lowerBound) to \(range.upperBound)")
        }
        return given
    }

    // MARK: evaluate_js

    private var evaluateJS: MCPTool {
        MCPTool(
            name: "evaluate_js",
            title: "Run JavaScript in a page",
            description: "Runs JavaScript in a tab's page (its main frame), or in an extension's open popup "
                + "(popup:<ext>) or options page (options:<ext>), and returns the result as JSON. Not in a "
                + "worker: use call_extension_api or read_extension_global there. Give "
                + "expression (one expression, for example document.title) or script (a function body that uses "
                + "return; await works in both). A returned promise is awaited. world page (default) is the page's "
                + "own globals; isolated is Detour's automation world, which shares the DOM but not the page's "
                + "variables or patched built-ins. A value JSON cannot hold is converted: DOM nodes become "
                + "descriptions like <div#id.class>, cycles [Circular], functions [Function name], undefined null "
                + "(type says what it was). A thrown error fails with script_error and its name, message and stack "
                + "in error.details; after timeout_ms it fails with timeout (the script itself keeps running). "
                + "Works for tabs no window shows.",
            inputSchema: MCPSchema.input([
                ("context", .string("A tab_id or tab:<id> from list_tabs, popup:<ext> or options:<ext>")),
                ("expression", .string("A JavaScript expression")),
                ("script", .string("A function body; its return value is the result")),
                ("world", .enumeration(["page", "isolated"], "page (default) or Detour's isolated world")),
                ("timeout_ms", .integer("How long to wait for the result (default 10000, at most 120000)")),
            ], required: ["context"]),
            outputSchema: MCPSchema.output([
                "value": ["description": "The result, as JSON"],
                "type": MCPSchema.stringType,
                "truncated": MCPSchema.booleanType,
                "world": MCPSchema.stringType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true],
            handler: { [self] arguments in
                let script = try arguments.string("script"), expression = try arguments.string("expression")
                guard (script == nil) != (expression == nil) else {
                    throw AutomationToolError(.invalidArguments, "Give exactly one of script or expression")
                }
                let worldName = try arguments.string("world") ?? "page"
                let world = try AutomationPage.world(named: worldName)
                let timeout = try boundedInt(arguments, "timeout_ms", default: 10_000, range: 1...120_000)
                let webView = try resolvePageTarget(context: try arguments.requiredString("context")).webView
                let result = try await AutomationPage.callJSON(
                    AutomationPage.evaluationBody(script: script, expression: expression),
                    in: webView, world: world, limit: .milliseconds(timeout))
                try Self.throwIfScriptFailed(result)
                return [
                    "value": result["value"] ?? .null,
                    "type": result["type"] ?? .null,
                    "truncated": .bool(result["truncated"]?.boolValue ?? false),
                    "world": .string(worldName),
                ]
            })
    }

    /// `script_error` for a wrapped script that threw.
    static func throwIfScriptFailed(_ result: JSONValue) throws {
        guard result["ok"]?.boolValue == false else { return }
        let name = result["name"]?.stringValue
        let message = result["message"]?.stringValue ?? ""
        let details: JSONValue = [
            "name": result["name"] ?? .null,
            "message": .string(message),
            "stack": result["stack"] ?? .null,
            "thrown_type": result["thrown_type"] ?? .null,
        ]
        let summary = [name, message].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
        throw AutomationToolError(.scriptError, "The script threw \(summary)", details: details)
    }

    // MARK: read_page

    private var readPage: MCPTool {
        MCPTool(
            name: "read_page",
            title: "Read a page",
            description: "Reads a tab's page (top document), or an extension's open popup or options page "
                + "(popup:<ext>, options:<ext>): its url, title and ready_state, and as mode asks "
                + "its visible text (text, the default), its HTML (html), its interactive elements (elements), or "
                + "nothing more (summary). selector limits text and html to that element and elements to what is "
                + "inside it. Each element has tag, role, name (accessible name, best effort), selector (unique "
                + "in the document, for click and type_text), rect (CSS pixels in the viewport), visible, "
                + "in_viewport and disabled; links have href, inputs type. text and html are cut at max_length "
                + "characters, elements at max_elements, with truncated true. viewport is the page's size in CSS pixels. "
                + "Works for tabs no window shows; one never shown has a 0 × 0 viewport, so its elements have "
                + "empty rects and are not visible.",
            inputSchema: MCPSchema.input([
                ("context", .string("A tab_id or tab:<id> from list_tabs, popup:<ext> or options:<ext>")),
                ("mode", .enumeration(["text", "html", "elements", "summary"], "What to read (default text)")),
                ("selector", .string("A CSS selector: read only that element")),
                ("max_length", .integer("Most characters of text or html (default 50000, at most 1000000)")),
                ("max_elements", .integer("Most elements (default 200, at most 2000)")),
            ], required: ["context"]),
            outputSchema: MCPSchema.output([
                "url": MCPSchema.stringType,
                "title": MCPSchema.stringType,
                "ready_state": MCPSchema.stringType,
                "viewport": MCPSchema.objectType,
                "text": MCPSchema.stringType,
                "html": MCPSchema.stringType,
                "elements": MCPSchema.arrayOfObjects("Interactive elements in document order"),
                "element_count": MCPSchema.integerType,
                "length": MCPSchema.integerType,
                "truncated": MCPSchema.booleanType,
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] arguments in
                // Not "format": that is a JSON Schema keyword, which some clients trip on.
                let mode = try arguments.string("mode") ?? "text"
                guard ["text", "html", "elements", "summary"].contains(mode) else {
                    throw AutomationToolError(.invalidArguments, "mode is text, html, elements or summary")
                }
                let maxLength = try boundedInt(arguments, "max_length", default: 50_000, range: 1...1_000_000)
                let maxElements = try boundedInt(arguments, "max_elements", default: 200, range: 1...2000)
                let selector = try arguments.string("selector")
                let webView = try resolvePageTarget(context: try arguments.requiredString("context")).webView
                let result = try await AutomationPage.callJSON(
                    AutomationPage.readPageBody,
                    arguments: ["mode": mode, "selector": selector ?? NSNull(), "maxLength": maxLength,
                                "maxElements": maxElements],
                    in: webView, world: AutomationPage.isolatedWorld, limit: .seconds(10))
                try Self.throwIfSelectorFailed(result, selector)
                return result
            })
    }

    static func throwIfSelectorFailed(_ result: JSONValue, _ selector: String?) throws {
        switch result["error"]?.stringValue {
        case "invalid"?:
            throw AutomationToolError(.invalidArguments,
                                      "Invalid selector: \(result["message"]?.stringValue ?? selector ?? "")")
        case "nomatch"?:
            throw AutomationToolError(.selectorNoMatch, "Nothing matches \(selector ?? "")")
        default:
            break
        }
    }

    // MARK: console_messages / network_requests

    private var consoleMessages: MCPTool {
        MCPTool(
            name: "console_messages",
            title: "Read a page's console",
            description: "A tab's console.log/info/warn/error/debug calls, uncaught errors (source uncaught) and "
                + "unhandled promise rejections (source unhandledrejection), from its main frame and subframes "
                + "(frame_url, main_frame), recorded while automation is on; Private tabs are never recorded. Each "
                + "entry has a seq that grows per tab: pass the result's next_seq as after_seq to read only newer "
                + "entries. A tab keeps its newest 1000; dropped counts entries after the cursor that were lost. "
                + "levels filters (log, info, warn, error, debug). Records survive navigation; a page loaded before "
                + "automation was turned on is recorded from then on, its subframes from their next load. "
                + "Extension contexts: worker:<ext>, popup:<ext>, options:<ext> read that context's console "
                + "(as Detour's console bridge forwards it), extension:<ext> all of them (and other extension "
                + "pages); each entry adds context_kind (worker, popup, options, page) and context, and the "
                + "records are kept per extension (one seq) while automation is on, also after a popup closes. "
                + "The bridge's own limit applies there: past a burst of 50, about 20 a second, repeats folded "
                + "into \"(repeated N times)\"; console.debug is not forwarded.",
            inputSchema: MCPSchema.input([
                ("context", .string("A tab_id or tab:<id>, or worker:, popup:, options: or extension:<ext>")),
                ("after_seq", .integer("Only entries with a larger seq (default 0: all kept)")),
                ("levels", .stringArray("Only these levels: log, info, warn, error, debug")),
                ("limit", .integer("Most entries to return (default 200, at most 1000)")),
            ], required: ["context"]),
            outputSchema: MCPSchema.output([
                "messages": MCPSchema.arrayOfObjects(
                    "seq, level, source, text, stack, source_url, line, column, frame_url, main_frame, timestamp"),
                "next_seq": MCPSchema.integerType,
                "dropped": MCPSchema.integerType,
                "has_more": MCPSchema.booleanType,
                "capturing": MCPSchema.booleanType,
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] arguments in
                try records(arguments, filter: "levels", allowed: AutomationPageCapture.consoleLevels,
                            key: "messages") { AutomationPageCapture.shared.console(for: $0) }
            })
    }

    private var networkRequests: MCPTool {
        MCPTool(
            name: "network_requests",
            title: "Read a page's network requests",
            description: "What a tab's page loaded, recorded while automation is on (never for Private tabs): the "
                + "navigation and every resource from Resource Timing (source navigation or resource: url, "
                + "initiator_type, start_ms and duration_ms from the page's time origin, transfer_size, "
                + "encoded_size, decoded_size, protocol, and status where WebKit reports it), and each fetch and "
                + "XMLHttpRequest (source fetch or xhr: method, url, status, ok, or error for a failure), so a "
                + "fetch appears twice, as fetch and as resource. Limits: no headers or bodies; sizes and timing "
                + "of a cross-origin resource are 0 unless it sends Timing-Allow-Origin; a load that failed "
                + "outright has no resource entry; requests made by workers are not seen. Cursors, dropped and "
                + "the 1000-entry bound as in console_messages. sources filters; failed_only keeps "
                + "status 400 and above and failures.",
            inputSchema: MCPSchema.input([
                ("context", .string("A tab_id or tab:<id> from list_tabs")),
                ("after_seq", .integer("Only entries with a larger seq (default 0: all kept)")),
                ("sources", .stringArray("Only these sources: navigation, resource, fetch, xhr")),
                ("failed_only", .boolean("Only failures and responses with status 400 or above (default false)")),
                ("limit", .integer("Most entries to return (default 200, at most 1000)")),
            ], required: ["context"]),
            outputSchema: MCPSchema.output([
                "requests": MCPSchema.arrayOfObjects(
                    "seq, source, url, method, status, ok, error, initiator_type, start_ms, duration_ms, sizes, "
                        + "protocol, frame_url, main_frame, timestamp"),
                "next_seq": MCPSchema.integerType,
                "dropped": MCPSchema.integerType,
                "has_more": MCPSchema.booleanType,
                "capturing": MCPSchema.booleanType,
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] arguments in
                let failedOnly = try arguments.bool("failed_only") ?? false
                return try records(arguments, filter: "sources", allowed: AutomationPageCapture.networkSources,
                                   key: "requests", where: { entry in
                    guard failedOnly else { return true }
                    if case .string = entry.fields["error"] ?? .null { return true }
                    return (entry.fields["status"]?.intValue ?? 0) >= 400
                }) { AutomationPageCapture.shared.network(for: $0) }
            })
    }

    /// The entries of one of a tab's buffers after a cursor, filtered and
    /// limited, with the cursor to read on from.
    private func records(_ arguments: ToolArguments, filter name: String, allowed: Set<String>, key: String,
                         where include: (AutomationRingBuffer.Entry) -> Bool = { _ in true },
                         buffer: (UUID) -> AutomationRingBuffer?) throws -> JSONValue {
        let after = try arguments.int("after_seq") ?? 0
        guard after >= 0 else { throw AutomationToolError(.invalidArguments, "after_seq is 0 or more") }
        let limit = try boundedInt(arguments, "limit", default: 200, range: 1...1000)
        let wanted = try arguments.stringArray(name).map(Set.init)
        if let wanted, !wanted.isSubset(of: allowed) {
            throw AutomationToolError(.invalidArguments,
                                      "\(name) are \(allowed.sorted().joined(separator: ", ")); got "
                                        + wanted.subtracting(allowed).sorted().joined(separator: ", "))
        }
        let contextValue = try arguments.requiredString("context")
        let capturing: Bool
        let buffered: AutomationRingBuffer?
        var kindFilter: String?
        if case .extension(let kind, let ref) = try AutomationContextID.parse(contextValue) {
            // Extension contexts (TASK-228.2): the console bridge's records.
            guard key == "messages" else {
                throw AutomationToolError(.unsupportedContext,
                                          "network_requests reads tabs only: extension contexts' requests are not recorded")
            }
            try Self.refuseSidePanel(kind)
            let target = try resolveExtensionTarget(ref)
            capturing = AutomationExtensionConsole.shared.isActive
            buffered = AutomationExtensionConsole.shared.buffer(extensionID: target.ext.id, profileID: target.profile.id)
            if kind != .extension { kindFilter = kind.rawValue }
        } else {
            let (tab, _) = try resolvePage(context: contextValue)
            capturing = AutomationPageCapture.shared.isActive
            buffered = buffer(tab.id)
        }
        guard let records = buffered else {
            return [key: [], "next_seq": .int(after), "dropped": 0, "has_more": false, "capturing": .bool(capturing)]
        }
        let matching = records.entries(after: after).filter { entry in
            (wanted?.contains(entry.category) ?? true) && include(entry)
                && (kindFilter == nil || entry.fields["context_kind"]?.stringValue == kindFilter)
        }
        let page = matching.prefix(limit)
        let hasMore = matching.count > limit
        let next = hasMore ? (page.last?.seq ?? after) : max(after, records.lastSeq)
        return [
            key: .array(page.map(\.json)),
            "next_seq": .int(next),
            "dropped": .int(records.dropped(after: after)),
            "has_more": .bool(hasMore),
            "capturing": .bool(capturing),
        ]
    }

    // MARK: wait_for

    private var waitFor: MCPTool {
        MCPTool(
            name: "wait_for",
            title: "Wait for a page",
            description: "Waits, checking every 100 ms, until one condition holds in a tab's page: load true (it "
                + "finished loading: not loading and readyState complete), selector (a CSS selector matches; "
                + "with visible true, an element with a visible box), expression (a JavaScript expression is "
                + "truthy, in world page or isolated; one that throws counts as false) or url (the tab's URL "
                + "contains this text; a plain substring, no wildcards). Fails with timeout after timeout_ms "
                + "(default 10000). Works for tabs no window shows, though WebKit may load those slowly, and one never "
                + "shown has no size, so nothing in it is visible. Also for an extension's open popup or options "
                + "page (popup:<ext>, options:<ext>). For worker:<ext>, worker_started true waits until its "
                + "background answers through Detour's automation channel, starting it when it is not running.",
            inputSchema: MCPSchema.input([
                ("context", .string("A tab_id or tab:<id> from list_tabs, popup:<ext>, options:<ext> or worker:<ext>")),
                ("load", .boolean("true: wait for the page to finish loading")),
                ("selector", .string("A CSS selector to wait for")),
                ("visible", .boolean("With selector: wait until a matching element is visible (default false)")),
                ("expression", .string("A JavaScript expression to wait to be truthy")),
                ("world", .enumeration(["page", "isolated"], "With expression: page (default) or isolated")),
                ("url", .string("Text the tab's URL must contain")),
                ("worker_started", .boolean("With worker:<ext>, true: wait for the extension's background to answer")),
                ("timeout_ms", .integer("How long to wait (default 10000, at most 120000)")),
            ], required: ["context"]),
            outputSchema: MCPSchema.output([
                "condition": MCPSchema.stringType,
                "matched": MCPSchema.booleanType,
                "elapsed_ms": MCPSchema.integerType,
                "url": MCPSchema.nullableString,
                "value": ["description": "With expression: its value, as JSON"],
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] arguments in
                let context = try arguments.requiredString("context")
                let conditions = ["load", "selector", "expression", "url", "worker_started"].filter { arguments.has($0) }
                guard conditions.count == 1, let condition = conditions.first else {
                    throw AutomationToolError(.invalidArguments,
                                              "Give exactly one of load, selector, expression, url or worker_started")
                }
                if condition == "load", try arguments.bool("load") != true {
                    throw AutomationToolError(.invalidArguments, "load takes true")
                }
                let isWorker: Bool
                if case .extension(.worker, _) = try AutomationContextID.parse(context) { isWorker = true } else { isWorker = false }
                guard (condition == "worker_started") == isWorker else {
                    throw AutomationToolError(isWorker ? .unsupportedContext : .invalidArguments,
                                              isWorker ? "A worker has no page: wait_for takes worker_started for it"
                                                       : "worker_started goes with a worker:<ext> context")
                }
                if condition == "worker_started" {
                    guard try arguments.bool("worker_started") == true else {
                        throw AutomationToolError(.invalidArguments, "worker_started takes true")
                    }
                    let timeout = try boundedInt(arguments, "timeout_ms", default: 10_000, range: 1...120_000)
                    guard case .extension(_, let ref) = try AutomationContextID.parse(context) else { return .null }
                    let target = try resolveExtensionTarget(ref)
                    let started = ContinuousClock.now
                    do {
                        let ping = try await pingWorker(target, limit: .milliseconds(timeout))
                        return [
                            "condition": "worker_started",
                            "matched": true,
                            "elapsed_ms": .int(AutomationPage.milliseconds(ContinuousClock.now - started)),
                            "url": ping["value"]?["url"] ?? .null,
                            "value": ping["value"] ?? .null,
                        ]
                    } catch let error as AutomationToolError where error.code == .workerNotRunning {
                        throw AutomationToolError(.timeout, error.message)
                    }
                }
                guard !arguments.has("visible") || condition == "selector" else {
                    throw AutomationToolError(.invalidArguments, "visible goes with selector")
                }
                guard !arguments.has("world") || condition == "expression" else {
                    throw AutomationToolError(.invalidArguments, "world goes with expression")
                }
                let visible = try arguments.bool("visible") ?? false
                let selector = try arguments.string("selector")
                let expression = try arguments.string("expression")
                let urlText = try arguments.string("url")
                let world = try AutomationPage.world(named: try arguments.string("world"))
                let timeout = try boundedInt(arguments, "timeout_ms", default: 10_000, range: 1...120_000)
                _ = try resolvePageTarget(context: context)

                let started = ContinuousClock.now
                let deadline = started + .milliseconds(timeout)
                var lastThrown: String?
                var lastFailure: String?
                while true {
                    // Again each time: the tab may close or fall asleep meanwhile.
                    let webView = try resolvePageTarget(context: context).webView
                    let remaining = max(.milliseconds(250), deadline - ContinuousClock.now)
                    var value: JSONValue?
                    let matched: Bool
                    do {
                        switch condition {
                        case "load":
                            if webView.isLoading {
                                matched = false
                            } else {
                                let state = try await AutomationPage.callJSON(
                                    AutomationPage.readyStateBody, in: webView, world: AutomationPage.isolatedWorld,
                                    limit: remaining)
                                matched = state == "complete"
                            }
                        case "selector":
                            let result = try await AutomationPage.callJSON(
                                AutomationPage.selectorMatchBody,
                                arguments: ["selector": selector ?? "", "visible": visible],
                                in: webView, world: AutomationPage.isolatedWorld, limit: remaining)
                            try Self.throwIfSelectorFailed(result, selector)
                            matched = result["matched"]?.boolValue ?? false
                        case "expression":
                            let result = try await AutomationPage.callJSON(
                                AutomationPage.evaluationBody(script: nil, expression: expression),
                                in: webView, world: world, limit: remaining)
                            if result["ok"]?.boolValue == false {
                                lastThrown = [result["name"]?.stringValue, result["message"]?.stringValue]
                                    .compactMap { $0 }.joined(separator: ": ")
                                matched = false
                            } else {
                                matched = result["truthy"]?.boolValue ?? false
                                value = result["value"]
                            }
                        default:
                            matched = webView.url?.absoluteString.contains(urlText ?? "") ?? false
                        }
                    } catch let error as AutomationToolError where error.code == .timeout || error.code == .internalError {
                        // The page was too busy to answer this time, or was
                        // between documents (a navigation replaced the frame
                        // or the web content process): ask again.
                        if error.code == .internalError { lastFailure = error.message }
                        matched = false
                    }
                    if matched {
                        var result: [String: JSONValue] = [
                            "condition": .string(condition),
                            "matched": true,
                            "elapsed_ms": .int(AutomationPage.milliseconds(ContinuousClock.now - started)),
                            "url": .nullable(webView.url?.absoluteString),
                        ]
                        if let value { result["value"] = value }
                        return .object(result)
                    }
                    if ContinuousClock.now >= deadline {
                        let what = switch condition {
                        case "load": "The page did not finish loading"
                        case "selector": "Nothing matched \(selector ?? "")\(visible ? " visibly" : "")"
                        case "expression": "The expression was not truthy" + (lastThrown.map { " (it threw \($0))" } ?? "")
                        default: "The URL did not contain \(urlText ?? "")"
                        }
                        throw AutomationToolError(.timeout, "\(what) within \(timeout) ms"
                                                      + (lastFailure.map { " (last failure: \($0))" } ?? ""))
                    }
                    try? await Task.sleep(for: min(.milliseconds(100), deadline - ContinuousClock.now))
                }
            })
    }

    // MARK: wake_tab

    private var wakeTab: MCPTool {
        MCPTool(
            name: "wake_tab",
            title: "Wake a sleeping tab",
            description: "Loads a sleeping tab's page again without selecting it or changing any window "
                + "(select_tab wakes and shows it). woken is false when the tab was already awake. The page then "
                + "loads in the background; wait_for with load true waits for it.",
            inputSchema: MCPSchema.input([
                ("context", .string("A tab_id or tab:<id> from list_tabs")),
            ], required: ["context"]),
            outputSchema: MCPSchema.output([
                "tab_id": MCPSchema.stringType,
                "woken": MCPSchema.booleanType,
                "url": MCPSchema.nullableString,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true],
            handler: { [self] arguments in
                let tab = try resolveTab(context: try arguments.requiredString("context"))
                let wasAsleep = tab.webView == nil
                if wasAsleep {
                    tab.wake()
                    guard tab.webView != nil else {
                        throw AutomationToolError(.internalError, "The tab did not wake")
                    }
                }
                return [
                    "tab_id": .string(tab.id.uuidString),
                    "woken": .bool(wasAsleep),
                    "url": .nullable(tab.url?.absoluteString),
                ]
            })
    }
}
