import Foundation

/// The pure parts of `extension_compat_report` (TASK-228.2): the static scan
/// of an extension's scripts for `chrome.*` / `browser.*` references, the
/// manifest's keys and permissions against what WebKit and Detour handle,
/// and the parsing of JavaScriptCore's TypeErrors and ReferenceErrors that
/// name an API. No WebKit, no state: the tool (`AutomationTools+CompatReport`)
/// feeds them and probes the live contexts. Everything returned is sorted,
/// and paths are relative to the extension's root, so two runs over the same
/// files give the same answer.
nonisolated enum AutomationCompatReport {

    // MARK: Namespaces

    /// Chrome's published extension namespaces (developer.chrome.com
    /// /docs/extensions/reference/api, November 2026), plus the Firefox and
    /// Safari ones an extension written for `browser.*` uses. A reference to
    /// any other name after `chrome.` or `browser.` is not reported: it is a
    /// web page's `chrome.loadTimes`, a URL like `chrome.google.com` in a
    /// string, or a library's own `browser` object (`browser.version`).
    static let knownNamespaces: Set<String> = [
        "accessibilityFeatures", "action", "alarms", "audio", "bookmarks", "browserAction", "browsingData",
        "certificateProvider", "commands", "contentSettings", "contextMenus", "cookies", "debugger",
        "declarativeContent", "declarativeNetRequest", "desktopCapture", "devtools", "dns", "documentScan", "dom",
        "downloads", "enterprise", "events", "extension", "extensionTypes", "fileBrowserHandler",
        "fileSystemProvider", "fontSettings", "gcm", "history", "i18n", "identity", "idle", "input", "instanceID",
        "loginState", "management", "notifications", "offscreen", "omnibox", "pageAction", "pageCapture",
        "permissions", "platformKeys", "power", "printerProvider", "printing", "printingMetrics", "privacy",
        "processes", "proxy", "readingList", "runtime", "scripting", "search", "sessions", "sidePanel", "storage",
        "system", "systemLog", "tabCapture", "tabGroups", "tabs", "topSites", "tts", "ttsEngine", "types",
        "userScripts", "vpnProvider", "wallpaper", "webAuthenticationProxy", "webNavigation", "webRequest",
        "windows",
        // Firefox / Safari
        "browserSettings", "captivePortal", "contextualIdentities", "find", "menus", "pkcs11", "sidebarAction",
        "theme",
    ]

    /// One reference in source: `chrome.storage.local` is global chrome,
    /// namespace storage, member local (deeper segments are not kept).
    struct Reference: Hashable, Sendable {
        let global: String
        let namespace: String
        let member: String?

        /// The report's key: `storage.local`, or `storage` alone.
        var api: String { member.map { "\(namespace).\($0)" } ?? namespace }
    }

    // MARK: The static scan

    struct Patterns: @unchecked Sendable {
        // @unchecked: NSRegularExpression is immutable and documented as
        // safe to use from any thread once built.
        let reference: NSRegularExpression
        let chain: NSRegularExpression
        let importScripts: NSRegularExpression
        let stringLiteral: NSRegularExpression
        let esImport: NSRegularExpression
        let esExport: NSRegularExpression
        let dynamicImport: NSRegularExpression
        let scriptSource: NSRegularExpression
        let missingVariable: NSRegularExpression
        let extensionOrigin: NSRegularExpression

        /// Built once: compiling them is most of a short scan's cost.
        static let shared = Patterns()

        init() {
            func regex(_ pattern: String) -> NSRegularExpression {
                try! NSRegularExpression(pattern: pattern, options: [])
            }
            let segment = #"(?:\??\.([A-Za-z_$][\w$]*)|\[\s*["']([A-Za-z_$][\w$]*)["']\s*\])"#
            reference = regex(#"(?<![\w$.])(?:(?:globalThis|window|self)\??\.)?(chrome|browser)"# + segment + segment + "?")
            chain = regex(#"(?<![\w$.])(chrome|browser)((?:\??\.[A-Za-z_$][\w$]*)+)"#)
            importScripts = regex(#"\bimportScripts\s*\(([^)]*)\)"#)
            stringLiteral = regex(#"["']([^"'\n]+)["']"#)
            esImport = regex(#"(?<![\w$.])import\s*(?:[\w$*{}\s,]*?\bfrom\s*)?["']([^"'\n]+)["']"#)
            esExport = regex(#"(?<![\w$.])export\s*(?:\*(?:\s*as\s+[\w$]+)?|\{[^}]*\})\s*from\s*["']([^"'\n]+)["']"#)
            dynamicImport = regex(#"(?<![\w$.])import\s*\(\s*["']([^"'\n]+)["']\s*\)"#)
            scriptSource = regex(#"<script\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']"#)
            missingVariable = regex(#"Can't find variable: (chrome|browser)\b"#)
            extensionOrigin = regex(#"webkit-extension://([A-Za-z0-9-]+)"#)
        }
    }

    /// The references in one script, counted.
    static func references(in source: String, patterns: Patterns = .shared) -> [Reference: Int] {
        guard source.contains("chrome") || source.contains("browser") else { return [:] }
        let text = source as NSString
        var found: [Reference: Int] = [:]
        patterns.reference.enumerateMatches(in: source, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }
            guard let global = group(1), let namespace = group(2) ?? group(3),
                  knownNamespaces.contains(namespace) else { return }
            found[Reference(global: global, namespace: namespace, member: group(4) ?? group(5)), default: 0] += 1
        }
        return found
    }

    /// The scripts a script loads by relative path: `importScripts(...)`,
    /// static and dynamic `import`, `export ... from`. Relative to `directory`
    /// (the importing file's, relative to the root); bare specifiers and URLs
    /// are left out.
    static func imports(in source: String, directory: String, patterns: Patterns = .shared) -> [String] {
        guard source.contains("import") else { return [] }
        let text = source as NSString
        let whole = NSRange(location: 0, length: text.length)
        var specifiers: [(String, Bool)] = []   // (specifier, from importScripts)
        patterns.importScripts.enumerateMatches(in: source, range: whole) { match, _, _ in
            guard let match else { return }
            let list = text.substring(with: match.range(at: 1))
            let inner = list as NSString
            patterns.stringLiteral.enumerateMatches(in: list, range: NSRange(location: 0, length: inner.length)) { literal, _, _ in
                if let literal { specifiers.append((inner.substring(with: literal.range(at: 1)), true)) }
            }
        }
        for pattern in [patterns.esImport, patterns.esExport, patterns.dynamicImport] {
            pattern.enumerateMatches(in: source, range: whole) { match, _, _ in
                if let match { specifiers.append((text.substring(with: match.range(at: 1)), false)) }
            }
        }
        return specifiers.compactMap { specifier, classic in
            guard !specifier.contains("://"), !specifier.hasPrefix("data:") else { return nil }
            // A module specifier must be relative; importScripts resolves any
            // path against the worker's URL.
            guard classic || specifier.hasPrefix("./") || specifier.hasPrefix("../") || specifier.hasPrefix("/") else {
                return nil
            }
            return resolve(specifier, from: directory)
        }
    }

    /// The `<script src>` paths of an HTML page.
    static func scriptSources(inHTML html: String, directory: String, patterns: Patterns = .shared) -> [String] {
        let text = html as NSString
        var paths: [String] = []
        patterns.scriptSource.enumerateMatches(in: html, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            let source = text.substring(with: match.range(at: 1))
            guard !source.contains("://"), !source.hasPrefix("data:"), !source.hasPrefix("//") else { return }
            if let path = resolve(source, from: directory) { paths.append(path) }
        }
        return paths
    }

    /// `specifier` resolved against `directory` (both relative to the root,
    /// `/`-separated; a leading `/` is the root). Nil when it leaves the root.
    static func resolve(_ specifier: String, from directory: String) -> String? {
        var path = specifier
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
        guard !path.isEmpty else { return nil }
        var parts = path.hasPrefix("/") ? [] : directory.split(separator: "/").map(String.init)
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(component))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    struct ScannedFile: Sendable {
        let path: String
        /// background, content_script, page, or other.
        let roles: [String]
        let references: [Reference: Int]
    }

    struct ScanResult: Sendable {
        var files: [ScannedFile] = []
        var scripts = 0
        var bytes = 0
        var truncated = false
        /// Files left out, with why (too large), sorted by path.
        var skipped: [(path: String, reason: String)] = []
    }

    struct Limits: Sendable {
        var maximumScripts = 3000
        var maximumFileBytes = 16 * 1024 * 1024
        var maximumTotalBytes = 160 * 1024 * 1024
        var maximumEntries = 30_000
    }

    /// Detour's own files in the installed copy (the polyfill, the content
    /// polyfill, the report's probe page): not the extension's code.
    static func isDetourFile(_ name: String) -> Bool { name.hasPrefix("_detour_") }

    /// Scans the installed extension at `root`: every `.js` and `.mjs` file
    /// (Detour's own and `_metadata/` left out), bounded by `limits`, with
    /// the role each file plays from `manifest` (the installed manifest.json)
    /// and the pages' `<script src>`, followed through imports: a worker, a
    /// background page's or `background.scripts` file is `background`, a
    /// manifest content script `content_script`, a page's script `page`,
    /// anything reached from none of them `other`.
    static func scan(root: URL, manifest: [String: Any], limits: Limits = Limits()) -> ScanResult {
        let patterns = Patterns.shared
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var result = ScanResult()
        var sources: [String: String] = [:]
        var htmlPages: [String: String] = [:]
        var entries = 0
        var total = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: base), includingPropertiesForKeys: keys,
                                                               options: [.skipsPackageDescendants]) else {
            return result
        }
        var relativePaths: [(String, URL, Int)] = []
        for case let url as URL in enumerator {
            entries += 1
            if entries > limits.maximumEntries {
                result.truncated = true
                break
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if name == "_metadata" { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, !isDetourFile(name) else { continue }
            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            relativePaths.append((String(full.dropFirst(base.count + 1)), url, values?.fileSize ?? 0))
        }
        // Sorted, so which files a bound leaves out does not depend on the
        // file system's order.
        relativePaths.sort { $0.0 < $1.0 }
        for (path, url, size) in relativePaths {
            let lower = path.lowercased()
            let isScript = lower.hasSuffix(".js") || lower.hasSuffix(".mjs")
            let isHTML = lower.hasSuffix(".html") || lower.hasSuffix(".htm")
            guard isScript || isHTML else { continue }
            if size > limits.maximumFileBytes {
                result.skipped.append((path, "larger than \(limits.maximumFileBytes) bytes"))
                continue
            }
            if isScript {
                guard result.scripts < limits.maximumScripts, total + size <= limits.maximumTotalBytes else {
                    result.truncated = true
                    continue
                }
                guard let data = try? Data(contentsOf: url) else { continue }
                total += data.count
                result.scripts += 1
                sources[path] = String(decoding: data, as: UTF8.self)
            } else if let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 {
                htmlPages[path] = String(decoding: data, as: UTF8.self)
            }
        }
        result.bytes = total

        // Roles: the manifest's entry points and the pages' scripts, then
        // every script they import, transitively.
        var roles: [String: Set<String>] = [:]
        var queue: [(String, String)] = []
        func mark(_ path: String?, _ role: String) {
            guard let path, !isDetourFile((path as NSString).lastPathComponent) else { return }
            queue.append((path, role))
        }
        let background = manifest["background"] as? [String: Any]
        var backgroundPage: String?
        if let worker = background?["service_worker"] as? String { mark(resolve(worker, from: ""), "background") }
        for script in background?["scripts"] as? [String] ?? [] { mark(resolve(script, from: ""), "background") }
        if let page = background?["page"] as? String { backgroundPage = resolve(page, from: "") }
        for entry in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            for script in entry["js"] as? [String] ?? [] { mark(resolve(script, from: ""), "content_script") }
        }
        for (page, html) in htmlPages {
            let directory = (page as NSString).deletingLastPathComponent
            let role = page == backgroundPage ? "background" : "page"
            for script in scriptSources(inHTML: html, directory: directory, patterns: patterns) { mark(script, role) }
        }
        var importsCache: [String: [String]] = [:]
        while let (path, role) = queue.popLast() {
            guard roles[path, default: []].insert(role).inserted, let source = sources[path] else { continue }
            let imported = importsCache[path] ?? imports(in: source, directory: (path as NSString).deletingLastPathComponent,
                                                         patterns: patterns)
            importsCache[path] = imported
            for next in imported { queue.append((next, role)) }
        }

        result.files = sources.keys.sorted().map { path in
            ScannedFile(path: path, roles: (roles[path].map { Array($0) } ?? ["other"]).sorted(),
                        references: references(in: sources[path]!, patterns: patterns))
        }
        result.skipped.sort { $0.path < $1.path }
        return result
    }

    // MARK: The manifest

    /// How Detour treats a manifest key or permission.
    enum Support: String, Sendable {
        /// WebKit and Detour act on it.
        case supported
        /// Detour's polyfill implements it (WebKit does not, or Detour's
        /// version replaces WebKit's).
        case polyfill
        /// The polyfill stands in for it without doing the real thing
        /// (`ExtensionPolyfillStubs`).
        case stubbed
        /// WebKit parses it, but what it asks for is not wired up in Detour,
        /// or Detour lacks the feature.
        case unsupported
        /// No effect anywhere, by design (informational keys).
        case ignored
        /// WebKit parses it; whether Detour honours it has not been checked.
        case unverified
        /// Not a key Chrome, WebKit or Detour knows.
        case unknown
    }

    /// The top-level manifest keys, from WebKit's parser
    /// (`Source/WebKit/UIProcess/Extensions/WebExtension.cpp` on main,
    /// read 2026-11-14: every `…ManifestKey` it reads) and from what Detour
    /// itself reads (`ExtensionManifest`, `ExtensionManager`). The note says
    /// why a key is not plainly supported. A key in none of these lists is
    /// `unknown`.
    static let manifestKeys: [String: (Support, String?)] = {
        var table: [String: (Support, String?)] = [:]
        for key in ["manifest_version", "name", "short_name", "version", "version_name", "description",
                    "default_locale", "icons", "action", "browser_action", "page_action", "background",
                    "content_scripts", "content_security_policy", "options_page", "options_ui", "permissions",
                    "optional_permissions", "host_permissions", "optional_host_permissions",
                    "web_accessible_resources", "externally_connectable", "declarative_net_request"] {
            table[key] = (.supported, nil)
        }
        table["key"] = (.supported, "Detour derives the extension id from it")
        table["update_url"] = (.supported, "Detour polls it for a CRX install's updates")
        table["message_serialization"] = (.supported, "Safari's key; WebKit reads it")
        table["icon_variants"] = (.unverified, "WebKit reads it only when built with icon variants")
        table["devtools_page"] = (.unverified, "WebKit reads it for Web Inspector; not checked in Detour")
        table["commands"] = (.unsupported,
                             "WebKit parses it, but Detour never calls performCommand(for:), so shortcuts do not run")
        table["chrome_url_overrides"] = (.unsupported, "WebKit parses it; Detour's new tab page is its own")
        table["browser_url_overrides"] = (.unsupported, "WebKit parses it; Detour's new tab page is its own")
        table["side_panel"] = (.unsupported, "This build of Detour has no extension side panels")
        table["sidebar_action"] = (.unsupported, "This build of Detour has no extension side panels")
        table["incognito"] = (.unsupported, "Detour's per-profile Private switch decides instead")
        for key in ["omnibox", "storage", "sandbox", "oauth2", "tts_engine", "file_browser_handlers",
                    "file_system_provider_capabilities", "input_components", "nacl_modules", "chrome_settings_overrides",
                    "cross_origin_embedder_policy", "cross_origin_opener_policy", "export", "import", "requirements",
                    "event_rules", "automation", "theme", "protocol_handlers", "user_scripts", "content_capabilities",
                    "replacement_web_app", "natively_connectable", "chrome_os_system_extension", "trial_tokens"] {
            table[key] = (.unsupported, "Not implemented by WebKit or Detour")
        }
        for key in ["author", "homepage_url", "minimum_chrome_version", "offline_enabled", "browser_specific_settings",
                    "applications", "developer", "$schema", "current_locale", "differential_fingerprint",
                    "short_description", "converted_from_user_script"] {
            table[key] = (.ignored, "Informational; no effect")
        }
        return table
    }()

    /// API permissions the polyfill implements (whatever WebKit does with
    /// the name), and those it only stands in for.
    static let polyfillPermissions: Set<String> = ["history", "management", "notifications", "idle", "fontSettings",
                                                   "sessions", "search", "offscreen", "favicon"]
    static let stubbedPermissions: [String: String] = [
        "privacy": "chrome.privacy is a stand-in: settings read false and cannot be changed",
        "webRequest": "chrome.webRequest listeners are accepted and never fire",
    ]
    static let ignoredPermissions: [String: String] = [
        "background": "No effect: a worker starts on events",
    ]

    /// Whether a permissions entry is a host pattern (MV2 lists hosts there).
    static func isHostPattern(_ value: String) -> Bool {
        value == "<all_urls>" || value.contains("://")
    }

    /// The manifest's keys and permissions. `webKitPermissions` are the API
    /// permissions WebKit kept (`requestedPermissions` and
    /// `optionalPermissions`: it drops names it does not support);
    /// `isSupportedPattern` says whether WebKit takes a host pattern.
    static func manifest(_ raw: [String: Any], webKitPermissions: Set<String>,
                         isSupportedPattern: (String) -> Bool) -> (keys: [String], findings: [[String: String]],
                                                                   permissions: [[String: String]],
                                                                   invalidHosts: [[String: String]]) {
        var supportedKeys: [String] = []
        var findings: [[String: String]] = []
        for key in raw.keys.sorted() {
            let (support, note) = manifestKeys[key] ?? (.unknown, nil)
            if support == .supported {
                supportedKeys.append(key)
            } else {
                var finding = ["key": key, "support": support.rawValue]
                if let note { finding["note"] = note }
                findings.append(finding)
            }
        }
        var permissions: [[String: String]] = []
        var invalidHosts: [[String: String]] = []
        for list in ["permissions", "optional_permissions"] {
            for value in Set(raw[list] as? [String] ?? []).sorted() {
                if isHostPattern(value) {
                    if !isSupportedPattern(value) { invalidHosts.append(["pattern": value, "list": list]) }
                    continue
                }
                var entry = ["permission": value, "list": list]
                if let note = stubbedPermissions[value] {
                    entry["support"] = Support.stubbed.rawValue
                    entry["note"] = note
                } else if polyfillPermissions.contains(value) {
                    entry["support"] = Support.polyfill.rawValue
                } else if webKitPermissions.contains(value) {
                    entry["support"] = Support.supported.rawValue
                } else if let note = ignoredPermissions[value] {
                    entry["support"] = Support.ignored.rawValue
                    entry["note"] = note
                } else {
                    entry["support"] = Support.unsupported.rawValue
                    entry["note"] = "WebKit drops it and Detour does not implement it"
                }
                permissions.append(entry)
            }
        }
        for list in ["host_permissions", "optional_host_permissions"] {
            for value in Set(raw[list] as? [String] ?? []).sorted() where !isSupportedPattern(value) {
                invalidHosts.append(["pattern": value, "list": list])
            }
        }
        return (supportedKeys, findings, permissions, invalidHosts)
    }

    // MARK: Runtime errors

    /// One API a runtime error names.
    struct ErrorMatch: Hashable, Sendable {
        /// `sidePanel.setOptions`, or the global (`chrome`) for a
        /// ReferenceError naming it.
        let api: String
        /// The whole chain the message names: `chrome.sidePanel.setOptions`.
        let expression: String
        /// TypeError or ReferenceError.
        let error: String
        /// From the error's name on, one line, origins normalised.
        let message: String
    }

    /// The `chrome.*` / `browser.*` members a console or uncaught-error
    /// record's text names as missing, in JavaScriptCore's wording:
    /// "undefined is not an object (evaluating 'chrome.sidePanel.setOptions')",
    /// "chrome.x.y is not a function. (In 'chrome.x.y()', 'chrome.x.y' is
    /// undefined)", "Can't find variable: chrome". A chain that is a prefix of
    /// another in the same text is folded into the longer one. Detour's own
    /// polyfill warnings and unchecked lastError reports are skipped.
    static func apiErrors(in text: String, patterns: Patterns = .shared) -> [ErrorMatch] {
        guard !text.hasPrefix("[Detour polyfill]"), !text.contains("Unchecked runtime.lastError") else { return [] }
        let error: String
        if text.contains("ReferenceError") || text.contains("Can't find variable") {
            error = "ReferenceError"
        } else if text.contains("TypeError") || text.contains("is not an object") || text.contains("is not a function")
                    || text.contains("is undefined") || text.contains("is not a constructor") {
            error = "TypeError"
        } else {
            return []
        }
        let message = errorLine(text, name: error)
        if error == "ReferenceError" {
            let nsText = text as NSString
            if let match = patterns.missingVariable.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let global = nsText.substring(with: match.range(at: 1))
                return [ErrorMatch(api: global, expression: global, error: error, message: message)]
            }
        }
        let nsText = text as NSString
        var chains: [String] = []
        patterns.chain.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match else { return }
            let chain = nsText.substring(with: match.range).replacingOccurrences(of: "?.", with: ".")
            if !chains.contains(chain) { chains.append(chain) }
        }
        let longest = chains.filter { chain in !chains.contains { $0 != chain && $0.hasPrefix(chain + ".") } }
        return longest.compactMap { chain in
            let parts = chain.split(separator: ".").map(String.init)
            guard parts.count >= 2, knownNamespaces.contains(parts[1]) else { return nil }
            let api = parts.count >= 3 ? "\(parts[1]).\(parts[2])" : parts[1]
            return ErrorMatch(api: api, expression: chain, error: error, message: message)
        }.sorted { ($0.api, $0.expression) < ($1.api, $1.expression) }
    }

    /// The line of `text` holding the error, from its name on when it is
    /// there, at most 300 characters.
    private static func errorLine(_ text: String, name: String) -> String {
        let line: Substring
        if let range = text.range(of: name + ":") {
            line = text[range.lowerBound...].prefix { $0 != "\n" }
        } else {
            line = text.split(separator: "\n", omittingEmptySubsequences: true).first(where: {
                $0.contains("chrome") || $0.contains("browser")
            }) ?? text.prefix { $0 != "\n" }
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
    }

    // MARK: Normalising

    /// `text` with every `webkit-extension://<host>` origin made
    /// `webkit-extension://<extensionID>`, and `basePath` made relative: an
    /// extension's base URL is new at every load, and its installed folder
    /// is under the run's data directory.
    static func normalise(_ text: String, extensionID: String, basePath: String?) -> String {
        var out = text
        if let basePath, !basePath.isEmpty { out = out.replacingOccurrences(of: basePath + "/", with: "") }
        return nameExtensionOrigins(out) { _ in extensionID }
    }

    /// `text` with each `webkit-extension://<host>` written
    /// `webkit-extension://<name(host)>`.
    static func nameExtensionOrigins(_ text: String, _ name: (String) -> String) -> String {
        guard text.contains("webkit-extension://") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in Patterns.shared.extensionOrigin.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += "webkit-extension://" + name(ns.substring(with: match.range(at: 1)))
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }
}
