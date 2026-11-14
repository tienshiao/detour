import AppKit
import WebKit

/// The extension tools of TASK-228.2 (part 1): install, list, turn on and
/// off, uninstall and grant permissions to extensions, open and close their
/// popup and options page, and call into their background. An extension is
/// named by its id or its exact manifest name (AC #10); its contexts by kind
/// and extension (`popup:<ext>`, `options:<ext>`, `worker:<ext>`), which the
/// page tools (evaluate_js, read_page, console_messages, wait_for, click,
/// type_text, press_key, screenshot) take as their `context` too.
///
/// Install, uninstall, turning on and off and permission decisions skip the
/// user's prompts, so they answer `gate_closed` unless the endpoint runs in
/// the isolated test-run mode (AC #7; whether a Release build ever offers
/// them is the user's decision). The Private profile is never a target and
/// its contexts are never reached.
extension AutomationTools {

    var extensionTools: [MCPTool] {
        [listExtensions, installExtension, uninstallExtension, setExtensionEnabled, setExtensionPermission,
         openExtensionContext, closeExtensionContext, callExtensionAPI, readExtensionGlobal]
    }

    // MARK: Addressing

    /// An extension's context in one profile, as a tool resolved it.
    struct ExtensionTarget {
        let ext: WebExtension
        let profile: Profile
        let context: WKWebExtensionContext
        /// Whether the client named the profile: it is kept in the context
        /// strings handed back, so they resolve the same way next time.
        let namedProfile: Bool

        var channelKey: AutomationExtensionChannel.Key { .init(extensionID: ext.id, profileID: profile.id) }
        var popupKey: AutomationExtensionPopups.Key { .init(extensionID: ext.id, profileID: profile.id) }

        func contextString(_ kind: AutomationExtensionContextKind) -> String {
            "\(kind.rawValue):\(ext.id)" + (namedProfile ? "@\(profile.id.uuidString)" : "")
        }

        var hasBackground: Bool {
            ext.wkExtension?.hasBackgroundContent ?? ext.manifest.background?.hasBackgroundContent ?? false
        }
    }

    /// The installed extension `query` names: its id, else the one extension
    /// whose manifest name (localised or as written) is `query`, ignoring case.
    func resolveExtension(_ query: String) throws -> WebExtension {
        let all = ExtensionManager.shared.extensions
        if let exact = all.first(where: { $0.id == query }) { return exact }
        let named = all.filter { ext in
            [ext.resolveI18n(ext.manifest.name), ext.manifest.name].contains {
                $0.caseInsensitiveCompare(query) == .orderedSame
            }
        }
        switch named.count {
        case 0:
            throw AutomationToolError(.unknownExtension, "No installed extension has the id or name \"\(query)\"")
        case 1:
            return named[0]
        default:
            throw AutomationToolError(.ambiguousExtension,
                                      "\(named.count) extensions are named \"\(query)\"; use an id: "
                                        + named.map(\.id).sorted().joined(separator: ", "))
        }
    }

    /// A normal profile by id. The Private profile is `private_unreachable`.
    func normalProfile(id: UUID) throws -> Profile {
        guard let profile = environment.store.profiles.first(where: { $0.id == id }) else {
            throw AutomationToolError(.unknownProfile, "No profile \(id.uuidString)")
        }
        guard !profile.isIncognito else {
            throw AutomationToolError(.privateUnreachable, "The Private profile is not reachable")
        }
        return profile
    }

    /// The extension's context in the named profile, or in the only normal
    /// profile it is on in.
    func resolveExtensionTarget(_ ref: AutomationExtensionRef, profileID: UUID? = nil) throws -> ExtensionTarget {
        if let profileID, let named = ref.profileID, named != profileID {
            throw AutomationToolError(.invalidArguments, "The context names profile \(named.uuidString), profile_id another")
        }
        let ext = try resolveExtension(ref.query)
        if let wanted = ref.profileID ?? profileID {
            let profile = try normalProfile(id: wanted)
            guard let context = profile.extensionContext(for: ext.id) else {
                throw AutomationToolError(.extensionDisabled,
                                          "\(Self.name(of: ext)) is not on in profile \(profile.name)")
            }
            return ExtensionTarget(ext: ext, profile: profile, context: context, namedProfile: true)
        }
        let loaded = environment.store.profiles.filter { !$0.isIncognito }.compactMap { profile in
            profile.extensionContext(for: ext.id).map { (profile, $0) }
        }
        switch loaded.count {
        case 0:
            throw AutomationToolError(.extensionDisabled, "\(Self.name(of: ext)) is not on in any profile")
        case 1:
            return ExtensionTarget(ext: ext, profile: loaded[0].0, context: loaded[0].1, namedProfile: false)
        default:
            throw AutomationToolError(.ambiguousProfile,
                                      "\(Self.name(of: ext)) is on in \(loaded.count) profiles; add @<profile_id> to "
                                        + "the context or pass profile_id: "
                                        + loaded.map { "\($0.0.name) \($0.0.id.uuidString)" }.joined(separator: ", "))
        }
    }

    static func name(of ext: WebExtension) -> String {
        "\"\(ext.resolveI18n(ext.manifest.name))\""
    }

    /// A web view a page tool acts on: a tab's, or an extension page's.
    struct PageTarget {
        let webView: WKWebView
        let tab: BrowserTab?
        /// For messages: "Tab <id>", "The popup of "Name"".
        let label: String
    }

    /// What `context` names, as a web view: a tab (`resolvePage`), the open
    /// popup or the options page of an extension. A worker has no page.
    func resolvePageTarget(context value: String) throws -> PageTarget {
        switch try AutomationContextID.parse(value) {
        case .tab:
            let (tab, webView) = try resolvePage(context: value)
            return PageTarget(webView: webView, tab: tab, label: "Tab \(tab.id.uuidString)")
        case .extension(let kind, let ref):
            return try resolveExtensionPage(kind: kind, ref: ref)
        }
    }

    private func resolveExtensionPage(kind: AutomationExtensionContextKind, ref: AutomationExtensionRef) throws -> PageTarget {
        try Self.refuseSidePanel(kind)
        let target = try resolveExtensionTarget(ref)
        let name = Self.name(of: target.ext)
        switch kind {
        case .popup:
            if let webView = popupWebView(target) {
                return PageTarget(webView: webView, tab: nil, label: "The popup of \(name)")
            }
            throw AutomationToolError(.contextNotOpen,
                                      "No popup of \(name) is open; open_extension_context with kind popup opens it")
        case .options:
            guard target.context.optionsPageURL != nil else {
                throw AutomationToolError(.unsupportedContext, "\(name) has no options page")
            }
            guard let (tab, _) = ExtensionManager.shared.existingOptionsPageTab(for: target.context, in: target.profile) else {
                throw AutomationToolError(.contextNotOpen,
                                          "No tab shows the options page of \(name); open_extension_context with kind options opens it")
            }
            guard let webView = tab.webView else {
                throw AutomationToolError(.tabAsleep, "The options page's tab \(tab.id.uuidString) is asleep; wake it with wake_tab")
            }
            return PageTarget(webView: webView, tab: tab, label: "The options page of \(name)")
        case .worker:
            throw AutomationToolError(.unsupportedContext,
                                      "worker:\(target.ext.id) has no page: use call_extension_api, read_extension_global, "
                                        + "console_messages, or wait_for with worker_started")
        case .extension:
            throw AutomationToolError(.unsupportedContext,
                                      "extension:\(target.ext.id) names every context of the extension; only console_messages reads it")
        case .sidepanel:
            throw AutomationToolError(.unsupportedContext, "No side panel")
        }
    }

    /// The popup's web view: one the endpoint opened, else one the extension
    /// opened itself in this profile.
    func popupWebView(_ target: ExtensionTarget) -> WKWebView? {
        if let open = AutomationExtensionPopups.shared.popup(target.popupKey) { return open.webView }
        if let webView = ExtensionManager.shared.extensionOpenedPopupWebView(extensionID: target.ext.id),
           webView.configuration.webExtensionController === target.profile.extensionController {
            return webView
        }
        return nil
    }

    /// Side panels exist only on the epic branch (TASK-132).
    static func refuseSidePanel(_ kind: AutomationExtensionContextKind) throws {
        if kind == .sidepanel {
            throw AutomationToolError(.unsupportedContext, "This build of Detour has no extension side panels")
        }
    }

    /// `gate_closed` outside the isolated test-run mode.
    func requireTestRun(_ tool: String) throws {
        guard environment.isTestRun else {
            throw AutomationToolError(.gateClosed,
                                      "\(tool) skips the user's prompts, so it is available only in a test run "
                                        + "(DETOUR_MCP=1 with an isolated DETOUR_DATA_DIR)")
        }
    }

    // MARK: Describing an extension

    func describe(_ ext: WebExtension) -> JSONValue {
        let manifest = ext.manifest
        let profiles: [JSONValue] = environment.store.profiles.filter { !$0.isIncognito }.map { profile in
            let context = profile.extensionContext(for: ext.id)
            let key = AutomationExtensionChannel.Key(extensionID: ext.id, profileID: profile.id)
            var contexts: [JSONValue] = []
            if let context {
                if ext.wkExtension?.hasBackgroundContent == true { contexts.append(.string("worker:\(ext.id)")) }
                if AutomationExtensionPopups.shared.popup(.init(extensionID: ext.id, profileID: profile.id)) != nil {
                    contexts.append(.string("popup:\(ext.id)"))
                }
                if ExtensionManager.shared.existingOptionsPageTab(for: context, in: profile) != nil {
                    contexts.append(.string("options:\(ext.id)"))
                }
            }
            return [
                "profile_id": .string(profile.id.uuidString),
                "profile_name": .string(profile.name),
                "turned_on": .bool(AppDatabase.shared.isExtensionEnabledByProfile(extensionID: ext.id,
                                                                                  profileID: profile.id.uuidString)),
                "loaded": .bool(context != nil),
                "worker_parked": .bool(AutomationExtensionChannel.shared.hasParked(key)),
                "open_contexts": .array(contexts),
                "context_errors": .array((context?.errors ?? []).map(Self.describe)),
            ]
        }
        let decisions: [JSONValue] = AppDatabase.shared.loadPermissions(extensionID: ext.id)
            .sorted { ($0.permissionType, $0.permissionKey) < ($1.permissionType, $1.permissionKey) }
            .map { record in
                [
                    "permission": .string(record.permissionKey),
                    "type": .string(Self.permissionTypeName(record.permissionType)),
                    "granted": .bool(record.status == ExtensionPermissionStatus.granted.rawValue),
                ]
            }
        let recorded: [JSONValue] = ExtensionErrorLog.shared.errors(for: ext.id).map { entry in
            [
                "source": .string(entry.source),
                "profile_id": .nullable(entry.profileID?.uuidString),
                "domain": .string(entry.domain),
                "code": .int(entry.code),
                "message": .string(entry.message),
                "count": .int(entry.count),
            ]
        }
        func strings(_ list: [String]?) -> JSONValue { .array((list ?? []).map(JSONValue.string)) }
        return [
            "id": .string(ext.id),
            "name": .string(ext.resolveI18n(manifest.name)),
            "version": .string(manifest.version),
            "manifest_version": .int(manifest.manifestVersion),
            "source": .string(ext.source.rawValue),
            "enabled": .bool(ext.isEnabled),
            "loaded": .bool(ext.wkExtension != nil),
            "load_failed": .bool(ext.loadFailed),
            "has_background": .bool(ext.wkExtension?.hasBackgroundContent ?? manifest.background?.hasBackgroundContent ?? false),
            "has_options_page": .bool(manifest.optionsUI != nil || manifest.optionsPage != nil),
            "profiles": .array(profiles),
            "requested_permissions": [
                "permissions": strings(manifest.permissions),
                "host_permissions": strings(manifest.hostPermissions),
                "optional_permissions": strings(manifest.optionalPermissions),
                "optional_host_permissions": strings(manifest.optionalHostPermissions),
            ],
            "permission_decisions": .array(decisions),
            "manifest_errors": .array((ext.wkExtension?.errors ?? []).map(Self.describe)),
            "load_errors": .array(recorded),
        ]
    }

    static func describe(_ error: any Error) -> JSONValue {
        let nsError = error as NSError
        return ["domain": .string(nsError.domain), "code": .int(nsError.code), "message": .string(nsError.localizedDescription)]
    }

    static func permissionTypeName(_ raw: Int) -> String {
        switch ExtensionPermissionType(rawValue: raw) {
        case .apiPermission?: "api"
        case .matchPattern?: "match_pattern"
        case .url?: "url"
        case nil: "unknown"
        }
    }

    // MARK: list_extensions

    private var listExtensions: MCPTool {
        MCPTool(
            name: "list_extensions",
            title: "List extensions",
            description: "Lists the installed extensions, sorted by id, or the one extension names (its id or exact "
                + "manifest name, ignoring case). Each has id, name, version, source (unpacked, crx, webStore), "
                + "enabled (the global switch), loaded and load_failed (whether WebKit read its files), "
                + "has_background, has_options_page, and per normal profile: turned_on (the profile's switch), "
                + "loaded (its context is loaded there), worker_parked (its background opened the automation "
                + "channel), open_contexts (the context strings to use) and context_errors (what WebKit reports "
                + "now). requested_permissions is the manifest's lists; permission_decisions the saved grants and "
                + "denials (type api, match_pattern or url); manifest_errors WebKit's manifest warnings; "
                + "load_errors every load error recorded this session (reading the files, loading the context, a "
                + "background that failed to load), with a count of repeats. The Private profile is left out.",
            inputSchema: MCPSchema.input([
                ("extension", .string("Optional: one extension, by id or manifest name")),
            ]),
            outputSchema: MCPSchema.output(["extensions": MCPSchema.arrayOfObjects("One entry per extension")]),
            annotations: ["readOnlyHint": true],
            handler: { [self] arguments in
                let list = try arguments.string("extension").map { [try resolveExtension($0)] }
                    ?? ExtensionManager.shared.extensions.sorted { $0.id < $1.id }
                return ["extensions": .array(list.map(describe))]
            })
    }

    // MARK: install_extension

    private var installExtension: MCPTool {
        MCPTool(
            name: "install_extension",
            title: "Install an extension",
            description: "Test runs only (gate_closed otherwise): installs an extension without the install prompt, "
                + "from an unpacked folder (path to the folder holding manifest.json) or a .crx file, and turns it "
                + "on in profile_id (default: the only normal profile; ambiguous_profile when there are several). "
                + "A CRX must pass the same signature checks as a download (its developer signature) and never "
                + "updates; an id already installed is replaced. Waits up to timeout_ms for the extension to load "
                + "in the profile and returns it as list_extensions describes it, with loaded false and its "
                + "load_errors when it did not load. A missing or invalid manifest or a refused CRX is "
                + "install_failed. Its worker may still be starting: wait_for with worker_started waits for it.",
            inputSchema: MCPSchema.input([
                ("path", .string("An absolute path: an unpacked extension's folder, or a .crx file")),
                ("profile_id", .string("The profile to turn it on in (a normal profile)")),
                ("timeout_ms", .integer("How long to wait for it to load (default 15000, at most 120000)")),
            ], required: ["path"]),
            outputSchema: MCPSchema.output([
                "extension": MCPSchema.objectType,
                "profile_id": MCPSchema.stringType,
                "loaded": MCPSchema.booleanType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                try requireTestRun("install_extension")
                let path = try arguments.requiredString("path")
                guard path.hasPrefix("/") else { throw AutomationToolError(.invalidArguments, "path must be absolute") }
                let timeout = try boundedInt(arguments, "timeout_ms", default: 15_000, range: 1...120_000)
                let profile = try installProfile(try arguments.uuid("profile_id"))
                let url = URL(fileURLWithPath: path).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    throw AutomationToolError(.invalidArguments, "Nothing at \(url.path)")
                }
                let ext: WebExtension
                if isDirectory.boolValue {
                    ext = try installUnpacked(url, profile: profile)
                } else if url.pathExtension.lowercased() == "crx" {
                    ext = try installCRX(url, profile: profile)
                } else {
                    throw AutomationToolError(.invalidArguments, "path is an extension folder or a .crx file")
                }
                let loaded = await waitForLoad(ext, in: profile, limit: .milliseconds(timeout))
                let current = ExtensionManager.shared.extension(withID: ext.id) ?? ext
                return [
                    "extension": describe(current),
                    "profile_id": .string(profile.id.uuidString),
                    "loaded": .bool(loaded),
                ]
            })
    }

    /// The profile an install turns the extension on in.
    private func installProfile(_ id: UUID?) throws -> Profile {
        if let id { return try normalProfile(id: id) }
        let normal = environment.store.profiles.filter { !$0.isIncognito }
        guard normal.count == 1 else {
            throw AutomationToolError(.ambiguousProfile,
                                      "There are \(normal.count) profiles; pass profile_id: "
                                        + normal.map { "\($0.name) \($0.id.uuidString)" }.joined(separator: ", "))
        }
        return normal[0]
    }

    private func installUnpacked(_ folder: URL, profile: Profile) throws -> WebExtension {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw AutomationToolError(.installFailed, "\(folder.path) has no manifest.json")
        }
        let manifest: ExtensionManifest
        do {
            manifest = try ExtensionManifest.parse(at: manifestURL)
        } catch {
            throw AutomationToolError(.installFailed, "manifest.json is not a valid manifest: \(error.localizedDescription)")
        }
        var options = ExtensionInstaller.Options()
        options.source = .unpacked
        options.sourcePath = folder
        // A manifest without a key gets a new random id at each install;
        // installing the same folder again keeps the id it has (as Reload
        // does), so a scenario's saved id still names it (AC #10).
        if manifest.key == nil,
           let existing = ExtensionManager.shared.extensions.first(where: {
               $0.source == .unpacked && $0.sourcePath?.standardizedFileURL.path == folder.path
           }) {
            options.forcedID = existing.id
        }
        do {
            return try ExtensionManager.shared.install(from: folder, options: options, turningOnIn: profile.id)
        } catch {
            throw AutomationToolError(.installFailed, "The folder did not install: \(error.localizedDescription)")
        }
    }

    private func installCRX(_ file: URL, profile: Profile) throws -> WebExtension {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw AutomationToolError(.invalidArguments, "Cannot read \(file.path): \(error.localizedDescription)")
        }
        // The download path's gate, with a file URL (its developer signature
        // is checked; a reinstall of an installed id is allowed here).
        let candidate: CRXInstallGate.Candidate
        do {
            candidate = try CRXInstallGate.admit(crxData: data, downloadURL: file) { _ in nil }
        } catch {
            throw AutomationToolError(.installFailed, "The CRX was refused: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: candidate.directory) }
        var options = ExtensionInstaller.Options()
        // Never polled for updates: a test run must not reach the store.
        options.source = .crx
        options.updateURL = nil
        do {
            return try ExtensionManager.shared.install(from: candidate.directory, publicKey: candidate.publicKey,
                                                       options: options, turningOnIn: profile.id)
        } catch {
            throw AutomationToolError(.installFailed, "The CRX did not install: \(error.localizedDescription)")
        }
    }

    /// Waits for `ext` to load into `profile` (true), to fail to (false), or
    /// for `limit`.
    private func waitForLoad(_ ext: WebExtension, in profile: Profile, limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        let loadErrorsBefore = Self.contextLoadErrors(ext.id, profile.id)
        while ContinuousClock.now < deadline {
            if ext.loadFailed { return false }
            if ext.wkExtension != nil {
                if profile.extensionContext(for: ext.id) != nil { return true }
                if Self.contextLoadErrors(ext.id, profile.id) > loadErrorsBefore { return false }
                if !ExtensionManager.shared.isEnabled(extensionID: ext.id, inProfile: profile.id) { return false }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return profile.extensionContext(for: ext.id) != nil
    }

    private static func contextLoadErrors(_ extensionID: String, _ profileID: UUID) -> Int {
        ExtensionErrorLog.shared.errors(for: extensionID)
            .filter { $0.source == "context_load" && $0.profileID == profileID }
            .reduce(0) { $0 + $1.count }
    }

    // MARK: uninstall_extension

    private var uninstallExtension: MCPTool {
        MCPTool(
            name: "uninstall_extension",
            title: "Uninstall an extension",
            description: "Test runs only (gate_closed otherwise): uninstalls an extension from every profile, as "
                + "Settings' Uninstall does (its data and open pages go with it), without asking.",
            inputSchema: MCPSchema.input([
                ("extension", .string("The extension's id or manifest name")),
            ], required: ["extension"]),
            outputSchema: MCPSchema.output(["extension_id": MCPSchema.stringType, "uninstalled": MCPSchema.booleanType]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                try requireTestRun("uninstall_extension")
                let ext = try resolveExtension(try arguments.requiredString("extension"))
                AutomationExtensionPopups.shared.closeAll(extensionID: ext.id)
                ExtensionManager.shared.uninstall(id: ext.id)
                AutomationExtensionConsole.shared.forget(extensionID: ext.id)
                return ["extension_id": .string(ext.id), "uninstalled": .bool(ExtensionManager.shared.extension(withID: ext.id) == nil)]
            })
    }

    // MARK: set_extension_enabled

    private var setExtensionEnabled: MCPTool {
        MCPTool(
            name: "set_extension_enabled",
            title: "Turn an extension on or off",
            description: "Test runs only (gate_closed otherwise): turns an extension on or off, as Settings does: "
                + "with profile_id, that profile's switch (the Private profile is refused); without, the global "
                + "switch, which leaves each profile's choice alone. Its contexts load or unload at once (turning "
                + "it off closes its pages). Returns the extension as list_extensions describes it.",
            inputSchema: MCPSchema.input([
                ("extension", .string("The extension's id or manifest name")),
                ("enabled", .boolean("true turns it on, false off")),
                ("profile_id", .string("Optional: one normal profile's switch instead of the global one")),
            ], required: ["extension", "enabled"]),
            outputSchema: MCPSchema.output(["extension": MCPSchema.objectType]),
            annotations: ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": true],
            handler: { [self] arguments in
                try requireTestRun("set_extension_enabled")
                let ext = try resolveExtension(try arguments.requiredString("extension"))
                guard let enabled = try arguments.bool("enabled") else {
                    throw AutomationToolError(.invalidArguments, "Missing required argument enabled")
                }
                if let profileID = try arguments.uuid("profile_id") {
                    let profile = try normalProfile(id: profileID)
                    if !enabled { AutomationExtensionPopups.shared.close(.init(extensionID: ext.id, profileID: profile.id)) }
                    ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: enabled)
                } else {
                    if !enabled { AutomationExtensionPopups.shared.closeAll(extensionID: ext.id) }
                    ExtensionManager.shared.setEnabled(id: ext.id, enabled: enabled)
                }
                return ["extension": describe(ext)]
            })
    }

    // MARK: set_extension_permission

    private var setExtensionPermission: MCPTool {
        MCPTool(
            name: "set_extension_permission",
            title: "Grant or revoke an extension permission",
            description: "Test runs only (gate_closed otherwise): saves a grant or a denial without a prompt and "
                + "applies it to the extension's contexts in every profile, as Settings' switch does. permission "
                + "is an API permission (\"storage\", \"tabs\"), a match pattern (\"https://*.example.com/*\", "
                + "\"<all_urls>\") or, with type url, one site's URL. type is inferred: a value with :// or "
                + "<all_urls> is a match pattern, anything else an API permission. warnings says when the "
                + "decision has no effect: a host outside the manifest's host_permissions and "
                + "optional_host_permissions is saved but stays inert, and an API permission the manifest does "
                + "not declare is not restored at the next launch; nativeMessaging gates only real native hosts.",
            inputSchema: MCPSchema.input([
                ("extension", .string("The extension's id or manifest name")),
                ("permission", .string("An API permission name, a match pattern, or a URL with type url")),
                ("granted", .boolean("true grants, false denies")),
                ("type", .enumeration(["api", "match_pattern", "url"], "What permission is (default: inferred)")),
            ], required: ["extension", "permission", "granted"]),
            outputSchema: MCPSchema.output([
                "extension_id": MCPSchema.stringType,
                "permission": MCPSchema.stringType,
                "type": MCPSchema.stringType,
                "granted": MCPSchema.booleanType,
                "warnings": ["type": "array", "items": ["type": "string"]],
                "permission_decisions": MCPSchema.arrayOfObjects("Every saved decision, after this one"),
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": true],
            handler: { [self] arguments in
                try requireTestRun("set_extension_permission")
                let ext = try resolveExtension(try arguments.requiredString("extension"))
                let key = try arguments.requiredString("permission").trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { throw AutomationToolError(.invalidArguments, "permission is empty") }
                guard let granted = try arguments.bool("granted") else {
                    throw AutomationToolError(.invalidArguments, "Missing required argument granted")
                }
                let typeName = try arguments.string("type")
                    ?? (key.contains("://") || key == "<all_urls>" ? "match_pattern" : "api")
                var warnings: [String] = []
                let type: ExtensionPermissionType
                switch typeName {
                case "api":
                    type = .apiPermission
                    if key == ExtensionPermissionRecord.nativeMessagingKey {
                        warnings.append("nativeMessaging stays granted to the context; the decision gates real native messaging hosts only")
                    } else if !ext.restorablePermissions.contains(WKWebExtension.Permission(rawValue: key)) {
                        warnings.append("\(key) is not in the manifest's permissions or optional_permissions: the decision is not restored at the next launch")
                    }
                case "match_pattern":
                    type = .matchPattern
                    guard let pattern = try? WKWebExtension.MatchPattern(string: key) else {
                        throw AutomationToolError(.invalidArguments, "Not a match pattern: \(key)")
                    }
                    if !ext.askableMatchPatterns.contains(where: { $0.matches(pattern) }) {
                        warnings.append("\(key) is outside the manifest's host_permissions and optional_host_permissions: saved, but inert")
                    }
                case "url":
                    type = .url
                    guard let url = URL(string: key), url.scheme != nil, url.host != nil else {
                        throw AutomationToolError(.invalidArguments, "Not a URL: \(key)")
                    }
                    if !ext.canAskForAccess(to: url) {
                        warnings.append("\(key) is outside the manifest's host_permissions and optional_host_permissions: saved, but inert")
                    }
                default:
                    throw AutomationToolError(.invalidArguments, "type is api, match_pattern or url")
                }
                ExtensionManager.shared.setPermissionDecision(extensionID: ext.id, key: key, type: type, granted: granted)
                return [
                    "extension_id": .string(ext.id),
                    "permission": .string(key),
                    "type": .string(typeName),
                    "granted": .bool(granted),
                    "warnings": .array(warnings.map(JSONValue.string)),
                    "permission_decisions": describe(ext)["permission_decisions"] ?? [],
                ]
            })
    }

    // MARK: open_extension_context / close_extension_context

    private var openExtensionContext: MCPTool {
        MCPTool(
            name: "open_extension_context",
            title: "Open an extension context",
            description: "Opens one of an extension's contexts and returns the context string the page tools take. "
                + "kind popup opens its action popup in a window (window_id, default the first window showing a "
                + "space of the extension's profile), anchored at its button as a click is, with the user gesture "
                + "a click records (activeTab); it works with Detour in the background. A popup already open is "
                + "reopened. The popover appears once the page loads; wait_for with load true waits for that. An "
                + "extension without a popup is unsupported_context (its action would fire onClicked instead). "
                + "kind options opens its options page in a tab (an existing one is reused), selected in window_id "
                + "when given, else in the background. kind worker starts its background and waits for it to "
                + "answer (the same as wait_for worker_started). sidepanel is unsupported_context on this build. "
                + "profile_id picks the profile when the extension is on in several.",
            inputSchema: MCPSchema.input([
                ("extension", .string("The extension's id or manifest name")),
                ("kind", .enumeration(["popup", "options", "worker", "sidepanel"], "Which context")),
                ("window_id", .integer("popup: the window to open it in; options: the window to show it in")),
                ("profile_id", .string("The profile, when the extension is on in more than one")),
                ("timeout_ms", .integer("worker: how long to wait for it to answer (default 10000, at most 120000)")),
            ], required: ["extension", "kind"]),
            outputSchema: MCPSchema.output([
                "context": MCPSchema.stringType,
                "profile_id": MCPSchema.stringType,
                "window_id": ["type": ["integer", "null"]],
                "tab_id": MCPSchema.nullableString,
                "url": MCPSchema.nullableString,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": false],
            handler: { [self] arguments in
                let kindName = try arguments.requiredString("kind")
                guard let kind = AutomationExtensionContextKind(rawValue: kindName), kind != .extension else {
                    throw AutomationToolError(.invalidArguments, "kind is popup, options, worker or sidepanel")
                }
                try Self.refuseSidePanel(kind)
                let ref = try AutomationExtensionRef.parse(try arguments.requiredString("extension"))
                let target = try resolveExtensionTarget(ref, profileID: try arguments.uuid("profile_id"))
                let windowID = try arguments.int("window_id")
                switch kind {
                case .popup:
                    return try openPopup(target, windowID: windowID)
                case .options:
                    return try openOptions(target, windowID: windowID)
                default:
                    let timeout = try boundedInt(arguments, "timeout_ms", default: 10_000, range: 1...120_000)
                    let ping = try await pingWorker(target, limit: .milliseconds(timeout))
                    return [
                        "context": .string(target.contextString(.worker)),
                        "profile_id": .string(target.profile.id.uuidString),
                        "window_id": .null,
                        "tab_id": .null,
                        "url": ping["value"]?["url"] ?? .null,
                    ]
                }
            })
    }

    private func openPopup(_ target: ExtensionTarget, windowID: Int?) throws -> JSONValue {
        let controller: BrowserWindowController
        if let windowID {
            controller = try window(id: windowID)
            guard controller.activeSpace?.profileID == target.profile.id else {
                throw AutomationToolError(.invalidArguments,
                                          "Window \(windowID) does not show a space of profile \(target.profile.name)")
            }
        } else {
            guard let first = environment.windowControllers().first(where: {
                !$0.hasClosed && !$0.isIncognito && $0.activeSpace?.profileID == target.profile.id
            }) else {
                throw AutomationToolError(.unknownWindow, "No window shows a space of profile \(target.profile.name)")
            }
            controller = first
        }
        let tab = controller.extensionActiveTab
        guard target.context.action(for: tab)?.presentsPopup == true else {
            throw AutomationToolError(.unsupportedContext, "\(Self.name(of: target.ext)) has no popup for this tab")
        }
        guard let webView = AutomationExtensionPopups.shared.show(extensionID: target.ext.id, profile: target.profile,
                                                                   tab: tab, in: controller) else {
            throw AutomationToolError(.internalError, "The popup did not open")
        }
        return [
            "context": .string(target.contextString(.popup)),
            "profile_id": .string(target.profile.id.uuidString),
            "window_id": .int(windowIDs.id(for: controller)),
            "tab_id": .null,
            "url": .nullable(webView.url?.absoluteString),
        ]
    }

    private func openOptions(_ target: ExtensionTarget, windowID: Int?) throws -> JSONValue {
        guard target.context.optionsPageURL != nil else {
            throw AutomationToolError(.unsupportedContext, "\(Self.name(of: target.ext)) has no options page")
        }
        // A window showing another profile is switched to the page's space,
        // as the Extensions menu's Options… does.
        let controller = try windowID.map { try window(id: $0) }
        let preferred = controller?.activeSpace?.profileID == target.profile.id ? controller?.activeSpaceID : nil
        guard let (tab, space) = ExtensionManager.shared.optionsPageTab(for: target.ext.id, in: target.profile,
                                                                        preferring: preferred) else {
            throw AutomationToolError(.unknownSpace, "Profile \(target.profile.name) has no space to open the options page in")
        }
        if let controller {
            if controller.activeSpaceID != space.id { controller.setActiveSpace(id: space.id, selectTab: false) }
            controller.selectTab(id: tab.id)
        }
        return [
            "context": .string(target.contextString(.options)),
            "profile_id": .string(target.profile.id.uuidString),
            "window_id": controller.map { .int(windowIDs.id(for: $0)) } ?? .null,
            "tab_id": .string(tab.id.uuidString),
            "url": .nullable((tab.webView?.url ?? tab.url)?.absoluteString),
        ]
    }

    private var closeExtensionContext: MCPTool {
        MCPTool(
            name: "close_extension_context",
            title: "Close an extension context",
            description: "Closes an extension's popup (popup:<ext>) or the tab showing its options page "
                + "(options:<ext>). context_not_open when it is not open. A worker is not closed from here: "
                + "WebKit unloads an idle background by itself after about 30 seconds.",
            inputSchema: MCPSchema.input([
                ("context", .string("popup:<extension> or options:<extension>")),
            ], required: ["context"]),
            outputSchema: MCPSchema.output(["context": MCPSchema.stringType, "closed": MCPSchema.booleanType]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                let value = try arguments.requiredString("context")
                guard case .extension(let kind, let ref) = try AutomationContextID.parse(value) else {
                    throw AutomationToolError(.invalidArguments, "close_extension_context takes popup:<extension> or options:<extension>")
                }
                try Self.refuseSidePanel(kind)
                let target = try resolveExtensionTarget(ref)
                switch kind {
                case .popup:
                    guard AutomationExtensionPopups.shared.close(target.popupKey) else {
                        throw AutomationToolError(.contextNotOpen, "No popup the endpoint opened is open for \(Self.name(of: target.ext))")
                    }
                case .options:
                    guard let (tab, space) = ExtensionManager.shared.existingOptionsPageTab(for: target.context,
                                                                                            in: target.profile) else {
                        throw AutomationToolError(.contextNotOpen, "No tab shows the options page of \(Self.name(of: target.ext))")
                    }
                    environment.store.closeTab(id: tab.id, in: space)
                default:
                    throw AutomationToolError(.unsupportedContext, "Only a popup or an options page is closed here")
                }
                return ["context": .string(value), "closed": true]
            })
    }

    // MARK: call_extension_api / read_extension_global

    private var callExtensionAPI: MCPTool {
        MCPTool(
            name: "call_extension_api",
            title: "Call an extension API",
            description: "Calls the function at a dotted path, usually a chrome.* or browser.* API such as "
                + "chrome.storage.local.get, with JSON arguments, in an extension context, and returns what it "
                + "returns (a promise is awaited), converted to JSON as evaluate_js converts. In worker:<ext> it "
                + "runs in the service worker (or background page) through Detour's automation channel, since a "
                + "worker cannot evaluate script; the background is started when it is not running. In "
                + "popup:<ext>, options:<ext> or a tab it runs in the page. A missing member or a non-function is "
                + "a TypeError, and what the call throws or rejects with is script_error with name, message and "
                + "stack in error.details. Only the promise form is called: a callback-only API gets no callback. "
                + "worker_not_running when the background did not take the call in time; timeout when it took it "
                + "and did not finish.",
            inputSchema: MCPSchema.input([
                ("context", .string("worker:<ext>, popup:<ext>, options:<ext>, or a tab")),
                ("path", .string("A dotted path from the global scope, for example chrome.storage.local.get")),
                ("args", .string("The arguments as a JSON array, for example [\"key\"] or [{\"a\": 1}] (default [])")),
                ("timeout_ms", .integer("How long to wait (default 10000, at most 120000)")),
            ], required: ["context", "path"]),
            outputSchema: MCPSchema.output([
                "value": ["description": "The result, as JSON"],
                "type": MCPSchema.stringType,
                "truncated": MCPSchema.booleanType,
                "context": MCPSchema.stringType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                // A JSON string, as the schema says; an array as such is taken
                // too (a client that parses what it is given sends one).
                let argumentsJSON = if let array = arguments.values["args"], array.arrayValue != nil {
                    array.jsonString
                } else {
                    try arguments.string("args") ?? "[]"
                }
                guard let parsed = try? JSONValue.parse(Data(argumentsJSON.utf8)), parsed.arrayValue != nil else {
                    throw AutomationToolError(.invalidArguments, "args must be a JSON array")
                }
                return try await runInContext(arguments, op: "call", argumentsJSON: argumentsJSON)
            })
    }

    private var readExtensionGlobal: MCPTool {
        MCPTool(
            name: "read_extension_global",
            title: "Read a value in an extension context",
            description: "Reads the value at a dotted path from the global scope (self.state.count, "
                + "chrome.runtime.id) in an extension context and returns it as JSON, as call_extension_api does "
                + "(a promise is not awaited). The way to read a service worker's own variables: worker:<ext> "
                + "goes through Detour's automation channel. A missing path segment is a TypeError (script_error).",
            inputSchema: MCPSchema.input([
                ("context", .string("worker:<ext>, popup:<ext>, options:<ext>, or a tab")),
                ("path", .string("A dotted path, for example self.cache.size")),
                ("timeout_ms", .integer("How long to wait (default 10000, at most 120000)")),
            ], required: ["context", "path"]),
            outputSchema: MCPSchema.output([
                "value": ["description": "The value, as JSON"],
                "type": MCPSchema.stringType,
                "truncated": MCPSchema.booleanType,
                "context": MCPSchema.stringType,
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] arguments in
                try await runInContext(arguments, op: "get", argumentsJSON: nil)
            })
    }

    private func runInContext(_ arguments: ToolArguments, op: String, argumentsJSON: String?) async throws -> JSONValue {
        let value = try arguments.requiredString("context")
        let path = try arguments.requiredString("path")
        let timeout = try boundedInt(arguments, "timeout_ms", default: 10_000, range: 1...120_000)
        let result: JSONValue
        if case .extension(.worker, let ref) = try AutomationContextID.parse(value) {
            let target = try resolveExtensionTarget(ref)
            guard target.hasBackground else {
                throw AutomationToolError(.unsupportedContext, "\(Self.name(of: target.ext)) has no background")
            }
            result = try await AutomationExtensionChannel.shared.send(target.channelKey, op: op, path: path,
                                                                      argumentsJSON: argumentsJSON,
                                                                      limit: .milliseconds(timeout))
        } else {
            let page = try resolvePageTarget(context: value)
            var command: [String: Any] = ["id": 0, "op": op, "path": path]
            if let argumentsJSON { command["args"] = argumentsJSON }
            result = try await AutomationPage.callJSON(AutomationExtensionChannel.pageCommandBody,
                                                       arguments: ["command": command], in: page.webView,
                                                       world: .page, limit: .milliseconds(timeout))
        }
        try Self.throwIfScriptFailed(result)
        return [
            "value": result["value"] ?? .null,
            "type": result["type"] ?? .null,
            "truncated": .bool(result["truncated"]?.boolValue ?? false),
            "context": .string(value),
        ]
    }

    /// Starts the background when it is not running and waits for it to
    /// answer a ping: `{kind, url}` in `value`.
    func pingWorker(_ target: ExtensionTarget, limit: Duration) async throws -> JSONValue {
        guard target.hasBackground else {
            throw AutomationToolError(.unsupportedContext, "\(Self.name(of: target.ext)) has no background")
        }
        let result = try await AutomationExtensionChannel.shared.send(target.channelKey, op: "ping", limit: limit)
        try Self.throwIfScriptFailed(result)
        return result
    }
}
