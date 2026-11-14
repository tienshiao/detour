import AppKit
import WebKit

/// `extension_compat_report` (TASK-228.2, part 2): what an extension tried to
/// use that Detour lacks, for a suite that measures compatibility across many
/// extensions and diffs each run against a baseline (ACs #5, #11).
///
/// Built without touching `chrome` or `browser` (a Proxy on them breaks
/// WebKit's message dispatch; wiki: never-replace-chrome-globals), from:
/// 1. a static scan of the extension's scripts for `chrome.X.Y` and
///    `browser.X.Y` references (`AutomationCompatReport.scan`), each checked
///    in the live worker (through the automation channel) and in an extension
///    page (`AutomationExtensionProbePages`): available, missing, or one of the
///    polyfill's stand-ins (`ExtensionPolyfillStubs`);
/// 2. the calls to those stand-ins, counted by the polyfill while automation
///    is on (`AutomationExtensionStubCalls`);
/// 3. the TypeErrors and ReferenceErrors in the extension's console that name
///    an API;
/// 4. the manifest's keys and permissions Detour does not support or
///    ignores, and WebKit's manifest warnings;
/// 5. the worker: whether it started, its load errors and recoveries.
///
/// Every field outside `run` is stable: sorted, no timestamps, ids that
/// change between runs or absolute paths (paths are relative to the
/// extension's root, extension origins carry the extension id). Counts that
/// depend on timing, and the profile id, are under `run`.
extension AutomationTools {

    var compatReportTools: [MCPTool] { [extensionCompatReport] }

    static let compatReportVersion = 1

    private var extensionCompatReport: MCPTool {
        MCPTool(
            name: "extension_compat_report",
            title: "Extension compatibility report",
            description: "What an extension uses that Detour does not have, as structured, sorted JSON a script can "
                + "diff against a saved baseline. references: every chrome.* / browser.* namespace and member its "
                + "scripts name (a static scan of its .js and .mjs files: api, the files and their roles "
                + "background, content_script, page or other, reference counts), each checked at runtime in the "
                + "worker and in an extension page: available, missing, stubbed (one of Detour's stand-ins that "
                + "accepts the call and does nothing real), or not_checked. stubs: the stand-ins it references or "
                + "called. runtime_errors: TypeErrors and ReferenceErrors in its recorded console and uncaught "
                + "errors that name an API (\"undefined is not an object (evaluating 'chrome.sidePanel.open')\"). "
                + "manifest: keys and permissions Detour does not support or ignores, host patterns WebKit refuses, "
                + "WebKit's manifest warnings. worker: whether it started, load errors, recovery. summary: the "
                + "short lists to diff. Everything outside run is stable between runs over the same files; run "
                + "holds the profile id and the counts that depend on timing (stub calls, error repeats). probe "
                + "false skips the runtime checks (no worker start, no page). Console and stub calls are recorded "
                + "only while automation is on, from the start of each context.",
            inputSchema: MCPSchema.input([
                ("extension", .string("The extension's id or manifest name")),
                ("profile_id", .string("The profile, when the extension is on in more than one")),
                ("probe", .boolean("Check each reference in the live worker and an extension page (default true; "
                                   + "starts the worker when it is not running)")),
                ("timeout_ms", .integer("How long each runtime check may take (default 10000, at most 120000)")),
            ], required: ["extension"]),
            outputSchema: MCPSchema.output([
                "report_version": MCPSchema.integerType,
                "extension": MCPSchema.objectType,
                "summary": MCPSchema.objectType,
                "references": MCPSchema.arrayOfObjects("api, namespace, globals, count, files, worker, page, stub"),
                "stubs": MCPSchema.arrayOfObjects("api, kind, note, referenced, called"),
                "runtime_errors": MCPSchema.arrayOfObjects("api, expression, error, contexts, message"),
                "manifest": MCPSchema.objectType,
                "worker": MCPSchema.objectType,
                "scan": MCPSchema.objectType,
                "run": MCPSchema.objectType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": false],
            handler: { [self] arguments in
                let ref = try AutomationExtensionRef.parse(try arguments.requiredString("extension"))
                let target = try resolveExtensionTarget(ref, profileID: try arguments.uuid("profile_id"))
                let probe = try arguments.bool("probe") ?? true
                let timeout = try boundedInt(arguments, "timeout_ms", default: 10_000, range: 1...120_000)
                return await compatReport(target, probe: probe, limit: .milliseconds(timeout))
            })
    }

    // MARK: Building the report

    private struct ReferenceTotal {
        var namespace = ""
        var member: String?
        var globals: Set<String> = []
        var count = 0
        var files: [(path: String, count: Int, roles: [String])] = []
    }

    func compatReport(_ target: ExtensionTarget, probe: Bool, limit: Duration) async -> JSONValue {
        let ext = target.ext
        let basePath = ext.basePath.resolvingSymlinksInPath().standardizedFileURL.path
        let normalise = { (text: String) in
            AutomationCompatReport.normalise(text, extensionID: ext.id, basePath: basePath)
        }
        let manifestData = (try? Data(contentsOf: ext.basePath.appendingPathComponent("manifest.json"))) ?? Data()
        let root = ext.basePath
        let scan = await Task.detached {
            AutomationCompatReport.scan(root: root, manifest: AutomationCompatReport.parseManifest(manifestData) ?? [:])
        }.value
        let rawManifest = AutomationCompatReport.parseManifest(manifestData) ?? [:]

        // 1. References, by api.
        var totals: [String: ReferenceTotal] = [:]
        for file in scan.files {
            var perAPI: [String: Int] = [:]
            for (reference, count) in file.references {
                var total = totals[reference.api] ?? ReferenceTotal(namespace: reference.namespace, member: reference.member)
                total.globals.insert(reference.global)
                total.count += count
                totals[reference.api] = total
                perAPI[reference.api, default: 0] += count
            }
            for (api, count) in perAPI { totals[api]?.files.append((file.path, count, file.roles)) }
        }
        // Under each global the extension names it with (`chrome` and
        // `browser` can be two objects, and the polyfill fills in `chrome`):
        // the namespace and the member, which must be there, and for a stub
        // its first counted function, whose nativeness says whether the
        // stand-in or WebKit's own answers (an object-valued stub, such as
        // storage.managed, has no addListener to tell by).
        func presencePaths(_ global: String, _ total: ReferenceTotal) -> [String] {
            var paths = ["\(global).\(total.namespace)"]
            if let member = total.member { paths.append("\(global).\(total.namespace).\(member)") }
            return paths
        }
        func nativenessPath(_ api: String, _ global: String) -> String? {
            ExtensionPolyfillStubs.byAPI[api]?.paths.first.map { "\(global).\($0)" }
        }
        func probePaths(_ api: String, _ total: ReferenceTotal) -> [String] {
            total.globals.sorted().flatMap { global in
                presencePaths(global, total) + (nativenessPath(api, global).map { [$0] } ?? [])
            }
        }
        let paths = Array(Set(totals.flatMap { probePaths($0.key, $0.value) })).sorted()
        let pathsJSON = JSONValue.array(paths.map(JSONValue.string)).jsonString

        // The runtime checks.
        var workerProbe: [String: JSONValue]?
        var workerStarted: Bool?
        var workerError: String?
        var pageProbe: [String: JSONValue]?
        var pageError: String?
        if probe {
            if target.hasBackground {
                do {
                    let result = try await AutomationExtensionChannel.shared.send(target.channelKey, op: "probe",
                                                                                  argumentsJSON: pathsJSON, limit: limit)
                    try Self.throwIfScriptFailed(result)
                    workerProbe = result["value"]?.objectValue ?? [:]
                    workerStarted = true
                } catch {
                    // A worker that took the command and then threw or ran
                    // out of time did start.
                    let code = (error as? AutomationToolError)?.code ?? .internalError
                    workerStarted = code != .workerNotRunning && code != .internalError
                    workerError = code.rawValue
                }
            }
            do {
                let result = try await AutomationExtensionProbePages.shared.run(
                    ext, context: target.context,
                    command: ["id": 0, "op": "probe", "args": pathsJSON], limit: limit)
                try Self.throwIfScriptFailed(result)
                pageProbe = result["value"]?.objectValue ?? [:]
            } catch {
                pageError = (error as? AutomationToolError).map { "\($0.code.rawValue): \($0.message)" }
                    ?? error.localizedDescription
            }
            // The counting module sends its batch on the next task: give the
            // calls the start-up just made a moment to arrive.
            try? await Task.sleep(for: .milliseconds(300))
        }

        func status(_ api: String, _ total: ReferenceTotal, in results: [String: JSONValue]?) -> String {
            guard let results else { return "not_checked" }
            var stubbed = false
            for global in total.globals.sorted() {
                let presence = presencePaths(global, total)
                for path in presence where results[path]?["present"]?.boolValue != true { return "missing" }
                guard ExtensionPolyfillStubs.byAPI[api] != nil else { continue }
                let native = nativenessPath(api, global).flatMap { results[$0]?["native"]?.boolValue }
                    ?? results[presence.last!]?["native"]?.boolValue
                if native != true { stubbed = true }
            }
            return stubbed ? "stubbed" : "available"
        }

        var references: [JSONValue] = []
        var missingInWorker: [String] = []
        var missingInPage: [String] = []
        var stubbedReferenced: [String] = []
        for api in totals.keys.sorted() {
            let total = totals[api]!
            let worker = target.hasBackground ? status(api, total, in: workerProbe) : "not_checked"
            let page = status(api, total, in: pageProbe)
            if worker == "missing" { missingInWorker.append(api) }
            if page == "missing" { missingInPage.append(api) }
            if worker == "stubbed" || page == "stubbed" { stubbedReferenced.append(api) }
            references.append([
                "api": .string(api),
                "namespace": .string(total.namespace),
                "globals": .array(total.globals.sorted().map(JSONValue.string)),
                "count": .int(total.count),
                "files": .array(total.files.sorted { $0.path < $1.path }.map { file in
                    ["path": .string(file.path), "count": .int(file.count),
                     "roles": .array(file.roles.map(JSONValue.string))]
                }),
                "worker": .string(worker),
                "page": .string(page),
                "stub": .nullable(ExtensionPolyfillStubs.byAPI[api]?.kind.rawValue),
            ])
        }

        // 2. Stub calls.
        let calls = AutomationExtensionStubCalls.shared.calls(extensionID: ext.id, profileID: target.profile.id)
        let calledAPIs = Set(calls.keys.compactMap { ExtensionPolyfillStubs.apiForPath[$0.path] })
        let stubs: [JSONValue] = ExtensionPolyfillStubs.all.filter { totals[$0.api] != nil || calledAPIs.contains($0.api) }
            .map { stub in
                ["api": .string(stub.api), "kind": .string(stub.kind.rawValue), "note": .string(stub.note),
                 "referenced": .bool(totals[stub.api] != nil), "called": .bool(calledAPIs.contains(stub.api))]
            }
        let stubCalls: [JSONValue] = calls.keys.sorted().map { call in
            ["api": .nullable(ExtensionPolyfillStubs.apiForPath[call.path]), "path": .string(call.path),
             "context_kind": .string(call.contextKind), "count": .int(calls[call]!)]
        }

        // 3. Runtime errors in the recorded console.
        struct ErrorKey: Hashable { let api: String, expression: String, error: String }
        var errorContexts: [ErrorKey: Set<String>] = [:]
        var errorMessages: [ErrorKey: String] = [:]
        var errorCounts: [ErrorKey: Int] = [:]
        let buffer = AutomationExtensionConsole.shared.buffer(extensionID: ext.id, profileID: target.profile.id)
        let records = buffer?.entries(after: 0) ?? []
        let patterns = AutomationCompatReport.Patterns.shared
        for record in records {
            guard let text = record.fields["text"]?.stringValue else { continue }
            // A log line about feature detection ("chrome.sidePanel is
            // undefined, using a tab") is not an error: below warn, only text
            // that names the error counts.
            let level = record.fields["level"]?.stringValue
            guard level == "error" || level == "warn" || text.contains("TypeError") || text.contains("ReferenceError")
            else { continue }
            for match in AutomationCompatReport.apiErrors(in: text, patterns: patterns) {
                let key = ErrorKey(api: match.api, expression: match.expression, error: match.error)
                errorContexts[key, default: []].insert(record.fields["context_kind"]?.stringValue ?? "page")
                let message = normalise(match.message)
                errorMessages[key] = min(errorMessages[key] ?? message, message)
                errorCounts[key, default: 0] += 1
            }
        }
        let errorKeys = errorContexts.keys.sorted { ($0.api, $0.expression, $0.error) < ($1.api, $1.expression, $1.error) }
        let runtimeErrors: [JSONValue] = errorKeys.map { key in
            ["api": .string(key.api), "expression": .string(key.expression), "error": .string(key.error),
             "contexts": .array(errorContexts[key]!.sorted().map(JSONValue.string)),
             "message": .string(errorMessages[key] ?? "")]
        }

        // 4. The manifest.
        let wkExtension = ext.wkExtension
        let webKitPermissions = Set(((wkExtension?.requestedPermissions ?? []).union(wkExtension?.optionalPermissions ?? []))
            .map(\.rawValue))
        let webKitPatterns = Set(((wkExtension?.requestedPermissionMatchPatterns ?? [])
            .union(wkExtension?.optionalPermissionMatchPatterns ?? [])).map(\.string))
        let manifest = AutomationCompatReport.manifest(rawManifest, webKitPermissions: webKitPermissions) { pattern in
            webKitPatterns.contains(pattern) || (try? WKWebExtension.MatchPattern(string: pattern)) != nil
        }
        let warnings = (wkExtension?.errors ?? []).map { error -> (String, Int, String) in
            let nsError = error as NSError
            return (nsError.domain, nsError.code, normalise(nsError.localizedDescription))
        }.sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        func strings(_ list: [[String: String]]) -> JSONValue {
            .array(list.map { .object($0.mapValues(JSONValue.string)) })
        }
        let unsupportedKeys = manifest.findings.filter { ["unsupported", "unknown"].contains($0["support"]) }
            .compactMap { $0["key"] }
        let unsupportedPermissions = manifest.permissions.filter { $0["support"] == "unsupported" }
            .compactMap { $0["permission"] }

        // 5. The worker.
        let loadErrors = ExtensionErrorLog.shared.errors(for: ext.id).filter {
            $0.profileID == nil || $0.profileID == target.profile.id
        }
        let failedToLoad = loadErrors.contains {
            $0.domain == WKWebExtensionContext.errorDomain
                && $0.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
        }
        struct LoadErrorKey: Hashable { let source: String, domain: String, code: Int, message: String }
        var loadErrorCounts: [LoadErrorKey: Int] = [:]
        for entry in loadErrors {
            let key = LoadErrorKey(source: entry.source, domain: entry.domain, code: entry.code,
                                   message: normalise(entry.message))
            loadErrorCounts[key, default: 0] += entry.count
        }
        let loadErrorKeys = loadErrorCounts.keys.sorted {
            ($0.source, $0.domain, $0.code, $0.message) < ($1.source, $1.domain, $1.code, $1.message)
        }
        let recoveries = ExtensionErrorLog.shared.recoveryAttempts(for: ext.id, profileID: target.profile.id)

        let background = ext.manifest.background
        let backgroundKind: String = if background?.serviceWorker != nil {
            background?.isModule == true ? "service_worker_module" : "service_worker"
        } else if background?.page != nil {
            "page"
        } else if background?.scripts?.isEmpty == false {
            "scripts"
        } else {
            "none"
        }

        return [
            "report_version": .int(Self.compatReportVersion),
            "extension": [
                "id": .string(ext.id),
                "name": .string(ext.resolveI18n(ext.manifest.name)),
                "version": .string(ext.manifest.version),
                "manifest_version": .int(ext.manifest.manifestVersion),
            ],
            "summary": [
                "missing_in_worker": .array(missingInWorker.map(JSONValue.string)),
                "missing_in_page": .array(missingInPage.map(JSONValue.string)),
                "stubbed_referenced": .array(stubbedReferenced.map(JSONValue.string)),
                "stubs_called": .array(calledAPIs.sorted().map(JSONValue.string)),
                "runtime_error_apis": .array(Set(errorKeys.map(\.api)).sorted().map(JSONValue.string)),
                "unsupported_manifest_keys": .array(unsupportedKeys.map(JSONValue.string)),
                "unsupported_permissions": .array(unsupportedPermissions.map(JSONValue.string)),
                "worker_started": workerStarted.map(JSONValue.bool) ?? .null,
            ],
            "references": .array(references),
            "stubs": .array(stubs),
            "runtime_errors": .array(runtimeErrors),
            "manifest": [
                "supported_keys": .array(manifest.keys.map(JSONValue.string)),
                "keys": strings(manifest.findings),
                "permissions": strings(manifest.permissions),
                "invalid_host_permissions": strings(manifest.invalidHosts),
                "warnings": .array(warnings.map { ["domain": .string($0.0), "code": .int($0.1), "message": .string($0.2)] }),
            ],
            "worker": [
                "background": .string(backgroundKind),
                "probed": .bool(probe && target.hasBackground),
                "started": workerStarted.map(JSONValue.bool) ?? .null,
                "start_error": .nullable(workerError),
                "failed_to_load": .bool(failedToLoad),
                "recovery_attempted": .bool(recoveries > 0),
                "load_errors": .array(loadErrorKeys.map { key in
                    ["source": .string(key.source), "domain": .string(key.domain), "code": .int(key.code),
                     "message": .string(key.message)]
                }),
            ],
            "scan": [
                "scripts": .int(scan.scripts),
                "bytes": .int(scan.bytes),
                "truncated": .bool(scan.truncated),
                "skipped": .array(scan.skipped.map { ["path": .string($0.path), "reason": .string($0.reason)] }),
                "files_with_references": .int(scan.files.filter { !$0.references.isEmpty }.count),
            ],
            "run": [
                "profile_id": .string(target.profile.id.uuidString),
                "page_probe_error": .nullable(pageError),
                "stub_calls": .array(stubCalls),
                "runtime_error_counts": .array(errorKeys.map { key in
                    ["api": .string(key.api), "expression": .string(key.expression), "count": .int(errorCounts[key]!)]
                }),
                "load_error_counts": .array(loadErrorKeys.map { key in
                    ["source": .string(key.source), "code": .int(key.code), "message": .string(key.message),
                     "count": .int(loadErrorCounts[key]!)]
                }),
                "recovery_attempts": .int(recoveries),
                "console_records": .int(records.count),
                "console_dropped": .int(buffer?.dropped(after: 0) ?? 0),
                "console_recording": .bool(AutomationExtensionConsole.shared.isActive),
            ],
        ]
    }
}

extension AutomationCompatReport {
    /// The installed manifest.json as a dictionary (comments allowed, as
    /// Chrome allows them), or nil.
    nonisolated static func parseManifest(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any]
    }
}

/// A hidden page of the extension's own for the compatibility report's
/// runtime check: an empty document, `_detour_probe.html`, written into the
/// installed copy (WebKit reads an extension's resources from disk when
/// they are requested) and loaded in a web view from the context's
/// configuration, so the polyfill runs in it as in any extension page and no
/// script of the extension's does. The report's probe command runs there
/// through `callAsyncJavaScript`, which the page's CSP does not bind. The
/// page's console and stub calls are not recorded as the extension's
/// (`AutomationExtensionConsole.probeKind`). Closed as soon as it answered.
final class AutomationExtensionProbePages: NSObject, WKNavigationDelegate {

    static let shared = AutomationExtensionProbePages()

    static let fileName = "_detour_probe.html"
    static let html = "<!doctype html><meta charset=\"utf-8\"><title>Detour compatibility probe</title>\n"

    private var live: [ObjectIdentifier: WKWebView] = [:]
    private var loads: [ObjectIdentifier: CheckedContinuation<Void, any Error>] = [:]

    func isProbe(_ webView: WKWebView) -> Bool { live[ObjectIdentifier(webView)] != nil }

    /// Loads the probe page into `context`, runs `command` there with the
    /// automation runner and returns its result object.
    func run(_ ext: WebExtension, context: WKWebExtensionContext, command: [String: Any],
             limit: Duration) async throws -> JSONValue {
        guard let configuration = context.webViewConfiguration else {
            throw AutomationToolError(.internalError, "The extension's context has no web view configuration")
        }
        let file = ext.basePath.appendingPathComponent(Self.fileName)
        if (try? String(contentsOf: file, encoding: .utf8)) != Self.html {
            do {
                try Self.html.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                throw AutomationToolError(.internalError, "Cannot write the probe page: \(error.localizedDescription)")
            }
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let id = ObjectIdentifier(webView)
        webView.navigationDelegate = self
        live[id] = webView
        // Cancelled when this run ends: a later probe page can be allocated
        // at this one's address, and so get its ObjectIdentifier, and a
        // timer left running would fail that page's load.
        var loadTimer: Task<Void, Never>?
        defer {
            loadTimer?.cancel()
            webView.stopLoading()
            webView.navigationDelegate = nil
            live[id] = nil
            if let pending = loads.removeValue(forKey: id) { pending.resume(throwing: CancellationError()) }
        }
        let url = context.baseURL.appendingPathComponent(Self.fileName)
        let milliseconds = AutomationPage.milliseconds(limit)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            loads[id] = continuation
            webView.load(URLRequest(url: url))
            loadTimer = Task { @MainActor [weak self] in
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                self?.settle(id, .failure(AutomationToolError(
                    .timeout, "The extension's probe page did not load within \(milliseconds) ms")))
            }
        }
        return try await AutomationPage.callJSON(AutomationExtensionChannel.pageCommandBody,
                                                 arguments: ["command": command], in: webView, world: .page,
                                                 limit: limit)
    }

    private func settle(_ id: ObjectIdentifier, _ result: Result<Void, any Error>) {
        loads.removeValue(forKey: id)?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(ObjectIdentifier(webView), .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        settle(ObjectIdentifier(webView), .failure(AutomationToolError(
            .internalError, "The probe page failed to load: \(error.localizedDescription)")))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        settle(ObjectIdentifier(webView), .failure(AutomationToolError(
            .internalError, "The probe page failed to load: \(error.localizedDescription)")))
    }
}
