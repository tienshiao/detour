import XCTest
import AppKit
import WebKit
@testable import Detour

/// `extension_compat_report` (TASK-228.2, part 2): the pure parts (the
/// static scan of an extension's scripts, the manifest's keys and
/// permissions, JavaScriptCore's error messages, normalising origins, the
/// stub registry), then a report for a real extension installed through the
/// endpoint into a profile of the test's own, with the worker and a page
/// checked at runtime, stub calls counted from the worker (native-message
/// transport) and the popup (message-handler transport), and a TypeError
/// naming an API; and the stable forms of list_extensions and
/// console_messages that a baseline diff needs (AC #11).
nonisolated final class AutomationCompatReportTests: XCTestCase {

    // MARK: The static scan

    @MainActor func testReferencesAreFoundInEveryFormAndOnlyForExtensionNamespaces() {
        let source = """
            chrome.storage.local.get('a');
            chrome.storage.local.set({});
            browser.tabs.query({});
            chrome?.runtime?.id;
            chrome['scripting'].executeScript;
            globalThis.chrome.alarms.create('x');
            if (typeof chrome.sidePanel === 'undefined') {}
            chrome.identity
            browser.version;                // a library's own browser object
            const url = 'https://chrome.google.com/webstore';
            window.foo.chrome.tabs.query();  // not the global
            mychrome.tabs.create();
            """
        let found = AutomationCompatReport.references(in: source)
        func count(_ global: String, _ namespace: String, _ member: String?) -> Int? {
            found[.init(global: global, namespace: namespace, member: member)]
        }
        XCTAssertEqual(count("chrome", "storage", "local"), 2)
        XCTAssertEqual(count("browser", "tabs", "query"), 1)
        XCTAssertEqual(count("chrome", "runtime", "id"), 1, "optional chaining")
        XCTAssertEqual(count("chrome", "scripting", "executeScript"), 1, "a bracket with a string")
        XCTAssertEqual(count("chrome", "alarms", "create"), 1, "through globalThis")
        XCTAssertEqual(count("chrome", "sidePanel", nil), 1, "a namespace alone")
        XCTAssertEqual(count("chrome", "identity", nil), 1)
        XCTAssertEqual(found.count, 7, "\(found)")
        XCTAssertEqual(Set(found.keys.map(\.api)),
                       ["storage.local", "tabs.query", "runtime.id", "scripting.executeScript", "alarms.create",
                        "sidePanel", "identity"])
    }

    @MainActor func testImportsAndScriptSourcesResolveAgainstTheirFile() {
        let source = """
            importScripts('lib/a.js', "b.js");
            import x from './mod/c.mjs';
            import { y } from "../d.js";
            import './e.js';
            export * from './f.js';
            const later = import('./g.js');
            import bare from 'some-package';
            importScripts('https://example.com/remote.js');
            """
        XCTAssertEqual(Set(AutomationCompatReport.imports(in: source, directory: "bg")),
                       ["bg/lib/a.js", "bg/b.js", "bg/mod/c.mjs", "d.js", "bg/e.js", "bg/f.js", "bg/g.js"])
        let html = #"<script src="popup.js"></script><script type="module" src="/lib/m.js?v=1"></script><script src="https://cdn/x.js"></script>"#
        XCTAssertEqual(AutomationCompatReport.scriptSources(inHTML: html, directory: "pages"), ["pages/popup.js", "lib/m.js"])
        XCTAssertNil(AutomationCompatReport.resolve("../../outside.js", from: "a"), "nothing outside the root")
    }

    @MainActor func testTheScanGivesRolesSkipsDetourFilesAndIsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detour-compat-scan-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let files: [String: String] = [
            "manifest.json": "{}",
            "bg.js": "importScripts('lib/shared.js'); chrome.alarms.create('a');",
            "lib/shared.js": "chrome.storage.local.get();",
            "content.js": "chrome.runtime.sendMessage({});",
            "popup.html": "<script src=\"popup.js\"></script>",
            "popup.js": "chrome.tabs.query({}); chrome.tabs.query({});",
            "unused.js": "chrome.bookmarks.search('x');",
            "_detour_polyfill.js": "chrome.privacy.services;",
            "_metadata/verified.js": "chrome.downloads.download();",
            "big.js": String(repeating: "x", count: 2000),
        ]
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let manifest: [String: Any] = [
            "background": ["service_worker": "bg.js"],
            "content_scripts": [["matches": ["<all_urls>"], "js": ["_detour_content_polyfill.js", "content.js"]]],
        ]
        var limits = AutomationCompatReport.Limits()
        limits.maximumFileBytes = 1000
        let scan = AutomationCompatReport.scan(root: root, manifest: manifest, limits: limits)
        XCTAssertEqual(scan.files.map(\.path), ["bg.js", "content.js", "lib/shared.js", "popup.js", "unused.js"],
                       "sorted, relative, without Detour's files, _metadata or the file over the bound")
        let roles = Dictionary(uniqueKeysWithValues: scan.files.map { ($0.path, $0.roles) })
        XCTAssertEqual(roles["bg.js"], ["background"])
        XCTAssertEqual(roles["lib/shared.js"], ["background"], "followed through importScripts")
        XCTAssertEqual(roles["content.js"], ["content_script"])
        XCTAssertEqual(roles["popup.js"], ["page"])
        XCTAssertEqual(roles["unused.js"], ["other"])
        XCTAssertEqual(scan.skipped.map(\.path), ["big.js"])
        XCTAssertEqual(scan.files.first { $0.path == "popup.js" }?.references[.init(global: "chrome", namespace: "tabs", member: "query")], 2)

        var few = AutomationCompatReport.Limits()
        few.maximumScripts = 2
        let truncated = AutomationCompatReport.scan(root: root, manifest: manifest, limits: few)
        XCTAssertTrue(truncated.truncated)
        XCTAssertEqual(truncated.files.map(\.path), ["bg.js", "big.js"], "the first files in path order")
    }

    // MARK: The manifest

    @MainActor func testManifestKeysAndPermissionsAreClassified() {
        let raw: [String: Any] = [
            "manifest_version": 3, "name": "x", "version": "1", "background": [:], "permissions": [
                "storage", "privacy", "history", "fooBar", "background", "storage",
            ],
            "optional_permissions": ["sessions", "https://legacy.example/*"],
            "host_permissions": ["https://example.com/*", "not a pattern"],
            "omnibox": [:], "commands": [:], "minimum_chrome_version": "100", "weird_key": 1, "key": "abc",
        ]
        let result = AutomationCompatReport.manifest(raw, webKitPermissions: ["storage"]) { $0.contains("://") }
        XCTAssertEqual(result.keys, ["background", "host_permissions", "key", "manifest_version", "name",
                                     "optional_permissions", "permissions", "version"])
        let keys = Dictionary(uniqueKeysWithValues: result.findings.map { ($0["key"]!, $0["support"]!) })
        XCTAssertEqual(keys, ["commands": "unsupported", "minimum_chrome_version": "ignored", "omnibox": "unsupported",
                              "weird_key": "unknown"])
        XCTAssertEqual(result.findings.map { $0["key"]! }, ["commands", "minimum_chrome_version", "omnibox", "weird_key"])
        let permissions = result.permissions.map { "\($0["list"]!):\($0["permission"]!)=\($0["support"]!)" }
        XCTAssertEqual(permissions, [
            "permissions:background=ignored", "permissions:fooBar=unsupported", "permissions:history=polyfill",
            "permissions:privacy=stubbed", "permissions:storage=supported", "optional_permissions:sessions=polyfill",
        ], "sorted per list, a repeat once, an MV2 host left to the host check")
        XCTAssertEqual(result.invalidHosts, [["pattern": "not a pattern", "list": "host_permissions"]])
    }

    // MARK: Runtime errors

    @MainActor func testJavaScriptCoreErrorsNameTheAPI() {
        func parse(_ text: String) -> [String] {
            AutomationCompatReport.apiErrors(in: text).map { "\($0.error) \($0.api) \($0.expression)" }
        }
        XCTAssertEqual(parse("TypeError: undefined is not an object (evaluating 'chrome.sidePanel.setOptions')"),
                       ["TypeError sidePanel.setOptions chrome.sidePanel.setOptions"])
        XCTAssertEqual(parse("[uncaught exception] bg.js:4:9 TypeError: chrome.tabGroups.query is not a function. "
                             + "(In 'chrome.tabGroups.query({})', 'chrome.tabGroups.query' is undefined)\nat bg.js:4"),
                       ["TypeError tabGroups.query chrome.tabGroups.query"])
        XCTAssertEqual(parse("undefined is not an object (evaluating 'browser.identity.getAuthToken')"),
                       ["TypeError identity.getAuthToken browser.identity.getAuthToken"],
                       "the JSC wording without the name is a TypeError")
        XCTAssertEqual(parse("ReferenceError: Can't find variable: chrome"), ["ReferenceError chrome chrome"])
        XCTAssertEqual(parse("TypeError: undefined is not an object (evaluating 'chrome?.offscreen.createDocument')"),
                       ["TypeError offscreen.createDocument chrome.offscreen.createDocument"])
        XCTAssertEqual(parse("TypeError: undefined is not an object (evaluating 'e.sidePanel.open')"), [],
                       "a minified alias names no global")
        XCTAssertEqual(parse("Unchecked runtime.lastError: chrome.tabs.get is not a function"), [])
        XCTAssertEqual(parse("[Detour polyfill] chrome.action.getUserSettings patch is not visible"), [])
        XCTAssertEqual(parse("all fine: chrome.tabs.query returned"), [], "not an error")
        let match = AutomationCompatReport.apiErrors(
            in: "[uncaught exception] x TypeError: undefined is not an object (evaluating 'chrome.foo.bar')").first
        XCTAssertNil(match, "foo is not an extension namespace")
        let message = AutomationCompatReport.apiErrors(
            in: "boom TypeError: undefined is not an object (evaluating 'chrome.sidePanel.open')\n  at f (bg.js:1)").first?.message
        XCTAssertEqual(message, "TypeError: undefined is not an object (evaluating 'chrome.sidePanel.open')")
    }

    @MainActor func testOriginsAndInstalledPathsAreNormalised() {
        let text = "at webkit-extension://3F2A9C1E-0000-4000-8000-ABCDEF012345/bg.js:3 and /data/Extensions/abc/lib.js"
        XCTAssertEqual(AutomationCompatReport.normalise(text, extensionID: "abc", basePath: "/data/Extensions/abc"),
                       "at webkit-extension://abc/bg.js:3 and lib.js")
        XCTAssertEqual(AutomationTools.nameExtensionOrigins("webkit-extension://h1/x webkit-extension://h2/y") { $0 == "h1" ? "one" : "unknown" },
                       "webkit-extension://one/x webkit-extension://unknown/y")
    }

    @MainActor func testTheStubRegistryIsSortedAndEveryPathBelongsToOneStub() {
        let apis = ExtensionPolyfillStubs.all.map(\.api)
        XCTAssertEqual(apis, apis.sorted())
        XCTAssertEqual(Set(apis).count, apis.count)
        for stub in ExtensionPolyfillStubs.all {
            XCTAssertTrue(apis.contains(stub.api))
            for path in stub.paths {
                XCTAssertTrue(path.hasPrefix(stub.api + ".") || path == stub.api, "\(path) under \(stub.api)")
                XCTAssertEqual(ExtensionPolyfillStubs.apiForPath[path], stub.api)
            }
        }
        XCTAssertNotNil(ExtensionPolyfillStubs.byAPI["webRequest.onBeforeRequest"])
        XCTAssertNotNil(ExtensionPolyfillStubs.byAPI["storage.managed"])
        XCTAssertNil(ExtensionPolyfillStubs.byAPI["notifications.onClicked"], "delivered since TASK-247")
    }

    // MARK: A real extension

    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []
    private var profiles: [Profile] = []
    private var installedIDs: Set<String> = []
    private var tempDirs: [URL] = []
    /// Kept for the rest of the process: releasing a profile whose extension
    /// controller hosted a popup traps in WebKit (wiki: webkit-test-host-traps).
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        try await waitUntil("the host app's installed extensions to load") {
            ExtensionManager.shared.hasLoadedInstalledExtensions
        }
        AutomationExtensionChannel.shared.isOpen = true
        AutomationExtensionConsole.shared.start()
        AutomationExtensionStubCalls.shared.start()
    }

    @MainActor override func tearDown() async throws {
        AutomationExtensionPopups.shared.closeAll()
        for wc in windows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for id in installedIDs where ExtensionManager.shared.extension(withID: id) != nil {
            ExtensionManager.shared.uninstall(id: id)
        }
        installedIDs.removeAll()
        for id in spaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        spaceIDs.removeAll()
        for profile in profiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            _ = AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        profiles.removeAll()
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        AutomationExtensionStubCalls.shared.stop()
        AutomationExtensionConsole.shared.stop()
        AutomationExtensionChannel.shared.isOpen = false
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        try await super.tearDown()
    }

    private struct Fixture {
        let server: MCPServer
        let profile: Profile
        let windowID: Int
    }

    @MainActor private func makeFixture() async throws -> Fixture {
        let store = TabStore.shared
        let profile = store.addProfile(name: "Compat \(UUID().uuidString.prefix(6))")
        profiles.append(profile)
        _ = profile.extensionController
        let space = store.addSpace(name: "Compat", emoji: "C", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        let tab = store.addTab(in: space, url: URL(string: "about:blank")!)
        wc.selectTab(id: tab.id)
        var environment = AutomationEnvironment(windowControllers: { [wc] }, mainMenu: { nil }, store: store)
        environment.isTestRun = true
        let tools = AutomationTools(environment: environment)
        return Fixture(server: MCPServer(tools: tools.all, serverVersion: "test", instructions: ""), profile: profile,
                       windowID: tools.windowIDs.id(for: wc))
    }

    /// An MV3 extension whose worker calls a stub at start-up (a privacy
    /// setting), logs the TypeError of a missing API (chrome.identity) and
    /// throws another uncaught; whose scripts name an API Detour lacks, a
    /// stub and an available one; with manifest keys and permissions Detour
    /// does not support.
    @MainActor private func makeExtensionFolder(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-compat-ext-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)
        tempDirs.append(dir)
        let files: [String: String] = [
            "manifest.json": """
                { "manifest_version": 3, "name": "\(name)", "version": "2.0.0",
                  "permissions": ["storage", "privacy", "fooBarPermission"],
                  "host_permissions": ["https://example.com/*"],
                  "background": { "service_worker": "bg.js" },
                  "action": { "default_popup": "popup.html" },
                  "content_scripts": [{ "matches": ["https://example.com/*"], "js": ["content.js"] }],
                  "omnibox": { "keyword": "x" }, "minimum_chrome_version": "110", "detour_unknown_key": true }
                """,
            "bg.js": """
                importScripts('lib/helpers.js');
                chrome.privacy.services.passwordSavingEnabled.get({}, () => {});
                try { chrome.identity.getAuthToken({ interactive: false }); } catch (e) { console.error(String(e)); }
                setTimeout(() => { chrome.identity.launchWebAuthFlow({}); }, 0);
                self.ready = true;
                """,
            "lib/helpers.js": "self.readLocal = () => chrome.storage.local.get('k');",
            "content.js": "chrome.runtime.sendMessage({ hello: true });",
            "popup.html": "<!doctype html><title>Popup</title><script src=\"popup.js\"></script>",
            "popup.js": "document.title = 'Popup'; const sessions = () => chrome.sessions.getRecentlyClosed();",
        ]
        for (file, contents) in files {
            try contents.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @MainActor private func call(_ f: Fixture, _ name: String, _ arguments: JSONValue) async throws
        -> (content: JSONValue, isError: Bool) {
        let tool = try XCTUnwrap(f.server.tools.first { $0.name == name }, name)
        let result = await f.server.call(tool, arguments: arguments)
        return (try XCTUnwrap(result["structuredContent"]), result["isError"] == true)
    }

    @MainActor @discardableResult
    private func ok(_ f: Fixture, _ name: String, _ arguments: JSONValue,
                    file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let (content, isError) = try await call(f, name, arguments)
        XCTAssertFalse(isError, "\(name) \(arguments.jsonString): \(content.jsonString)", file: file, line: line)
        return content
    }

    @MainActor private func code(_ f: Fixture, _ name: String, _ arguments: JSONValue) async throws -> String? {
        let (content, isError) = try await call(f, name, arguments)
        XCTAssertTrue(isError, "\(name) \(arguments.jsonString) should fail: \(content.jsonString)")
        return content["error"]?["code"]?.stringValue
    }

    @MainActor private func install(_ f: Fixture, _ folder: URL) async throws -> String {
        let result = try await ok(f, "install_extension", ["path": .string(folder.path),
                                                            "profile_id": .string(f.profile.id.uuidString)])
        let id = try XCTUnwrap(result["extension"]?["id"]?.stringValue)
        installedIDs.insert(id)
        XCTAssertEqual(result["loaded"], true, result.jsonString)
        return id
    }

    private func entry(_ list: JSONValue?, _ key: String, _ value: String) -> JSONValue? {
        list?.arrayValue?.first { $0[key]?.stringValue == value }
    }

    @MainActor func testAReportForARealExtension() async throws {
        let f = try await makeFixture()
        let id = try await install(f, try makeExtensionFolder(name: "Compat Fixture \(UUID().uuidString.prefix(6))"))
        let worker = JSONValue.string("worker:\(id)")
        try await ok(f, "wait_for", ["context": worker, "worker_started": true, "timeout_ms": 15000])
        try await waitUntil("the worker's errors in its console") {
            let messages = try await self.ok(f, "console_messages", ["context": worker])["messages"]?.arrayValue ?? []
            return messages.contains { $0["text"]?.stringValue?.contains("launchWebAuthFlow") == true }
        }
        // A stub called from a page (the message-handler transport).
        try await ok(f, "open_extension_context", ["extension": .string(id), "kind": "popup",
                                                    "window_id": .int(f.windowID)])
        try await ok(f, "wait_for", ["context": .string("popup:\(id)"), "load": true, "timeout_ms": 10000])
        try await ok(f, "call_extension_api", ["context": .string("popup:\(id)"), "path": "chrome.sessions.getRecentlyClosed"])

        let report = try await ok(f, "extension_compat_report", ["extension": .string(id)])
        XCTAssertEqual(report["report_version"], 1)
        XCTAssertEqual(report["extension"]?["id"], .string(id))

        // References, checked in both contexts.
        let references = report["references"]
        let apis = references?.arrayValue?.compactMap { $0["api"]?.stringValue } ?? []
        XCTAssertEqual(apis, apis.sorted())
        let identity = try XCTUnwrap(entry(references, "api", "identity.getAuthToken"), report.jsonString)
        XCTAssertEqual(identity["worker"], "missing")
        XCTAssertEqual(identity["page"], "missing")
        XCTAssertEqual(identity["files"]?.arrayValue?.first?["path"], "bg.js")
        XCTAssertEqual(identity["files"]?.arrayValue?.first?["roles"], ["background"])
        let privacy = try XCTUnwrap(entry(references, "api", "privacy.services"))
        XCTAssertEqual(privacy["worker"], "stubbed")
        XCTAssertEqual(privacy["page"], "stubbed")
        XCTAssertEqual(privacy["stub"], "fixed_answer")
        let storage = try XCTUnwrap(entry(references, "api", "storage.local"))
        XCTAssertEqual(storage["worker"], "available")
        XCTAssertEqual(storage["files"]?.arrayValue?.first?["path"], "lib/helpers.js")
        XCTAssertEqual(storage["files"]?.arrayValue?.first?["roles"], ["background"], "followed through importScripts")
        XCTAssertEqual(entry(references, "api", "runtime.sendMessage")?["files"]?.arrayValue?.first?["roles"], ["content_script"])
        XCTAssertEqual(entry(references, "api", "sessions.getRecentlyClosed")?["page"], "stubbed")
        XCTAssertTrue(report["summary"]?["missing_in_worker"]?.arrayValue?.contains("identity.getAuthToken") ?? false)
        XCTAssertTrue(report["summary"]?["missing_in_worker"]?.arrayValue?.contains("identity.launchWebAuthFlow") ?? false)
        XCTAssertEqual(report["summary"]?["worker_started"], true)

        // Stub calls, from the worker and the popup.
        XCTAssertEqual(entry(report["stubs"], "api", "privacy.services")?["called"], true)
        XCTAssertEqual(entry(report["stubs"], "api", "sessions.getRecentlyClosed")?["called"], true)
        let calls = report["run"]?["stub_calls"]?.arrayValue ?? []
        XCTAssertTrue(calls.contains { $0["path"] == "privacy.services.passwordSavingEnabled.get" && $0["context_kind"] == "worker" },
                      "\(calls)")
        XCTAssertTrue(calls.contains { $0["path"] == "sessions.getRecentlyClosed" && $0["context_kind"] == "popup" },
                      "\(calls)")
        XCTAssertFalse(calls.contains { $0["context_kind"] == "probe" }, "the report's own page is not the extension's")

        // Runtime errors naming an API.
        let errors = report["runtime_errors"]
        let caught = try XCTUnwrap(entry(errors, "api", "identity.getAuthToken"), report.jsonString)
        XCTAssertEqual(caught["error"], "TypeError")
        XCTAssertEqual(caught["contexts"], ["worker"])
        XCTAssertEqual(caught["expression"], "chrome.identity.getAuthToken")
        XCTAssertNotNil(entry(errors, "api", "identity.launchWebAuthFlow"), "the uncaught one")

        // The manifest.
        let keys = report["manifest"]?["keys"]
        XCTAssertEqual(entry(keys, "key", "omnibox")?["support"], "unsupported")
        XCTAssertEqual(entry(keys, "key", "minimum_chrome_version")?["support"], "ignored")
        XCTAssertEqual(entry(keys, "key", "detour_unknown_key")?["support"], "unknown")
        let permissions = report["manifest"]?["permissions"]
        XCTAssertEqual(entry(permissions, "permission", "fooBarPermission")?["support"], "unsupported")
        XCTAssertEqual(entry(permissions, "permission", "privacy")?["support"], "stubbed")
        XCTAssertEqual(entry(permissions, "permission", "storage")?["support"], "supported")
        XCTAssertEqual(report["summary"]?["unsupported_manifest_keys"], ["detour_unknown_key", "omnibox"])
        XCTAssertEqual(report["summary"]?["unsupported_permissions"], ["fooBarPermission"])

        // The worker.
        XCTAssertEqual(report["worker"]?["background"], "service_worker")
        XCTAssertEqual(report["worker"]?["started"], true)
        XCTAssertEqual(report["worker"]?["failed_to_load"], false)

        // Stable between two reports: everything outside run.
        let again = try await ok(f, "extension_compat_report", ["extension": .string(id)])
        func stablePart(_ value: JSONValue) -> String {
            var fields = value.objectValue ?? [:]
            fields["run"] = nil
            return JSONValue.object(fields).jsonString
        }
        XCTAssertEqual(stablePart(report), stablePart(again))
        XCTAssertFalse(stablePart(report).contains(f.profile.id.uuidString), "no run-specific id outside run")
        XCTAssertFalse(stablePart(report).contains(NSHomeDirectory()), "no absolute path")

        // Without the runtime checks.
        let staticOnly = try await ok(f, "extension_compat_report", ["extension": .string(id), "probe": false])
        XCTAssertEqual(entry(staticOnly["references"], "api", "identity.getAuthToken")?["worker"], "not_checked")
        XCTAssertEqual(staticOnly["worker"]?["started"], .null)
    }

    @MainActor func testReportErrorsAndAWorkerThatDoesNotAnswer() async throws {
        let f = try await makeFixture()
        let unknown = try await code(f, "extension_compat_report", ["extension": "No Such Extension"])
        XCTAssertEqual(unknown, "unknown_extension")
        let id = try await install(f, try makeExtensionFolder(name: "Compat Errors \(UUID().uuidString.prefix(6))"))
        try await ok(f, "wait_for", ["context": .string("worker:\(id)"), "worker_started": true, "timeout_ms": 15000])

        AutomationExtensionChannel.shared.isOpen = false
        let closed = try await ok(f, "extension_compat_report", ["extension": .string(id), "timeout_ms": 500])
        XCTAssertEqual(closed["worker"]?["started"], false)
        XCTAssertEqual(closed["worker"]?["start_error"], "worker_not_running")
        XCTAssertEqual(entry(closed["references"], "api", "storage.local")?["worker"], "not_checked")
        XCTAssertEqual(entry(closed["references"], "api", "storage.local")?["page"], "available", "the page still answers")
        AutomationExtensionChannel.shared.isOpen = true

        try await ok(f, "set_extension_enabled", ["extension": .string(id), "enabled": false,
                                                  "profile_id": .string(f.profile.id.uuidString)])
        let off = try await code(f, "extension_compat_report", ["extension": .string(id)])
        XCTAssertEqual(off, "extension_disabled")
    }

    /// The counts' handler takes registry paths only, and answers stop while
    /// automation is off so a context stops sending.
    @MainActor func testStubCallReportsTakeRegistryPathsOnlyAndStopWhenOff() async throws {
        let f = try await makeFixture()
        let id = try await install(f, try makeExtensionFolder(name: "Compat Counts \(UUID().uuidString.prefix(6))"))
        try await ok(f, "open_extension_context", ["extension": .string(id), "kind": "popup",
                                                    "window_id": .int(f.windowID)])
        let popup = JSONValue.string("popup:\(id)")
        try await ok(f, "wait_for", ["context": popup, "load": true, "timeout_ms": 10000])
        let request = "[\"automation.stubCalls\", {\"counts\": {\"no.such.path\": 5, \"sessions.getDevices\": 2, \"history.addUrl\": true}}]"
        let accepted = try await ok(f, "call_extension_api", ["context": popup, "path": "__detourPolyfillRequest",
                                                              "args": .string(request)])
        XCTAssertEqual(accepted["value"]?["stop"], false)
        let calls = AutomationExtensionStubCalls.shared.calls(extensionID: id, profileID: f.profile.id)
            .filter { $0.key.contextKind == "popup" }
        XCTAssertEqual(calls, [.init(path: "sessions.getDevices", contextKind: "popup"): 2],
                       "an unknown path and a non-number are left out")

        AutomationExtensionStubCalls.shared.stop()
        let refused = try await ok(f, "call_extension_api", ["context": popup, "path": "__detourPolyfillRequest",
                                                             "args": .string(request)])
        XCTAssertEqual(refused["value"]?["stop"], true)
        XCTAssertTrue(AutomationExtensionStubCalls.shared.calls(extensionID: id, profileID: f.profile.id).isEmpty)
    }

    // MARK: Stable list and console (AC #11)

    @MainActor func testStableListAndConsoleLeaveOutWhatChangesBetweenRuns() async throws {
        let f = try await makeFixture()
        let id = try await install(f, try makeExtensionFolder(name: "Compat Stable \(UUID().uuidString.prefix(6))"))
        let worker = JSONValue.string("worker:\(id)")
        try await ok(f, "wait_for", ["context": worker, "worker_started": true, "timeout_ms": 15000])
        let origin = try XCTUnwrap(f.profile.extensionContext(for: id)?.baseURL.absoluteString)
        try await ok(f, "call_extension_api", ["context": worker, "path": "console.log",
                                               "args": .string("[\"at \(origin)bg.js\"]")])

        let listed = try await ok(f, "list_extensions", ["extension": .string(id), "stable": true])
        let profile = try XCTUnwrap(listed["extensions"]?.arrayValue?.first?["profiles"]?.arrayValue?.first)
        XCTAssertNil(profile["profile_id"])
        XCTAssertNil(profile["worker_parked"])
        XCTAssertNotNil(profile["profile_name"])
        XCTAssertFalse(listed.jsonString.contains(f.profile.id.uuidString))
        let full = try await ok(f, "list_extensions", ["extension": .string(id)])
        XCTAssertNotNil(full["extensions"]?.arrayValue?.first?["profiles"]?.arrayValue?.first?["profile_id"], "the default keeps them")

        var messages: [JSONValue] = []
        try await waitUntil("the logged origin") {
            messages = try await self.ok(f, "console_messages", ["context": worker, "stable": true])["messages"]?.arrayValue ?? []
            return messages.contains { $0["text"]?.stringValue?.contains("bg.js") == true }
        }
        XCTAssertTrue(messages.allSatisfy { $0["seq"] == nil && $0["timestamp"] == nil })
        let logged = try XCTUnwrap(messages.first { $0["text"]?.stringValue?.contains("bg.js") == true })
        let text = try XCTUnwrap(logged["text"]?.stringValue)
        XCTAssertTrue(text.contains("webkit-extension://\(id)/bg.js"), text)
        XCTAssertFalse(text.contains(try XCTUnwrap(f.profile.extensionContext(for: id)?.baseURL.host)), text)
    }
}
