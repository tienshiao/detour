import XCTest
import WebKit
@testable import Detour

/// TASK-132.4: the INTERIM `chrome.tabGroups` / `chrome.debugger` stand-ins
/// (`ExtensionAPIPolyfill.interimNamespacesJS`) in a real extension context —
/// the service worker and an extension page.
///
/// They exist for one reason: the Claude extension's worker dereferences
/// `chrome.tabGroups.Color` and `chrome.debugger.onEvent` while its modules are
/// still being evaluated, so without the namespaces the worker never loads. The
/// fixture worker here does the same two things at module evaluation and must
/// come up. TASK-132.12 and TASK-132.13 replace the stand-ins with the real
/// APIs; until then no method of either API may exist.
@MainActor
final class ExtensionInterimNamespacesTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var pages: [WKWebView] = []

    /// Kept alive for the rest of the test process, as in
    /// `ExtensionTabResolveTests`: releasing a profile whose controller hosted
    /// a web view takes its process pool down inside WebKit's IPC dispatch.
    private static var retainedProfiles: [Profile] = []

    override func tearDown() async throws {
        for page in pages { page.stopLoading() }
        pages.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            TabStore.shared.forceRemoveProfile(id: profile.id)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// What the Claude extension's worker does before it registers a single
    /// listener (1.0.98: a class's static field, and a constructor run at
    /// import). A TypeError here fails the whole background load.
    private static let touchAtEvaluationJS = """
    class __DetourTestGroups {
        static SESSION_GROUP_COLORS = [
            chrome.tabGroups.Color.BLUE, chrome.tabGroups.Color.CYAN, chrome.tabGroups.Color.GREEN,
            chrome.tabGroups.Color.ORANGE, chrome.tabGroups.Color.RED, chrome.tabGroups.Color.PINK,
            chrome.tabGroups.Color.PURPLE, chrome.tabGroups.Color.GREY
        ];
    }
    globalThis.__detourTestDebuggerEvents = 0;
    chrome.debugger.onEvent.addListener(() => { globalThis.__detourTestDebuggerEvents += 1; });
    chrome.debugger.onDetach.addListener(() => { globalThis.__detourTestDebuggerEvents += 1; });
    globalThis.__detourTestEvaluated = {
        colors: __DetourTestGroups.SESSION_GROUP_COLORS,
        none: chrome.tabGroups.TAB_GROUP_ID_NONE
    };
    """

    private static let probeJS = """
    async function __detourTestInterimProbe() {
        const tg = chrome.tabGroups;
        const dbg = chrome.debugger;
        const out = {
            tabGroupsType: typeof tg,
            debuggerType: typeof dbg,
            state: globalThis.__detourInterimNamespaces,
            contextKind: globalThis.__detourContextKind,
            tabsGroup: typeof chrome.tabs.group,
            tabsUngroup: typeof chrome.tabs.ungroup,
            evaluated: globalThis.__detourTestEvaluated || null,
            debuggerEvents: globalThis.__detourTestDebuggerEvents === undefined ? null : globalThis.__detourTestDebuggerEvents
        };
        if (tg) {
            out.color = tg.Color;
            out.none = tg.TAB_GROUP_ID_NONE;
            out.tabGroupsKeys = Object.keys(tg).sort();
            out.tabGroupsMethods = ['get', 'query', 'update', 'move', 'onCreated', 'onUpdated', 'onRemoved', 'onMoved']
                .filter((name) => tg[name] !== undefined);
            out.viaBrowserColor = browser.tabGroups ? browser.tabGroups.Color.BLUE : null;
            out.survivesReread = chrome.tabGroups === tg;
        }
        if (dbg) {
            out.debuggerKeys = Object.keys(dbg).sort();
            out.debuggerMethods = ['attach', 'detach', 'sendCommand', 'getTargets']
                .filter((name) => dbg[name] !== undefined);
            const listener = () => {};
            dbg.onEvent.addListener(listener);
            out.hasListener = dbg.onEvent.hasListener(listener);
            dbg.onEvent.removeListener(listener);
            out.removed = !dbg.onEvent.hasListener(listener);
            out.viaBrowserDebugger = browser.debugger ? typeof browser.debugger.onEvent.addListener : null;
        }
        // WebKit's own namespaces must be as they were.
        out.tabsQuery = typeof chrome.tabs.query;
        out.storage = typeof chrome.storage.local.get;
        return out;
    }
    """

    private func makeExtension(permissions: [String], touchingAtEvaluation: Bool) async throws -> WebExtension {
        let id = "interim-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        let manifestObject: [String: Any] = [
            "manifest_version": 3, "name": "Interim Namespaces Test", "version": "1.0.0",
            "permissions": permissions,
            "background": ["service_worker": "background.js", "type": "module"],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))
        try "<html><body>interim namespaces test page</body></html>"
            .write(to: dir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)
        try (ExtensionAPIPolyfill.polyfillJS + "\n\n"
             + (touchingAtEvaluation ? Self.touchAtEvaluationJS : "") + "\n\n" + Self.probeJS + """


        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (!message || message.type !== 'interimProbe') return false;
            __detourTestInterimProbe().then(
                (value) => sendResponse({ ok: true, value: value }),
                (error) => sendResponse({ ok: false, error: String(error && error.message ? error.message : error) }));
            return true;
        });
        """).write(to: dir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        installTestExtension(ext, in: AppDatabase.shared, manifestJSON: manifestData)
        AppDatabase.shared.recordDeclaredPermissions(
            permissions.map { ExtensionPermissionRecord(extensionID: id, key: $0, type: .apiPermission, status: .granted) })
        return ext
    }

    private struct World {
        let context: WKWebExtensionContext
        let page: WKWebView
    }

    private enum Via: String, CaseIterable { case page, worker }

    private func makeWorld(_ ext: WebExtension) async throws -> World {
        let profile = TabStore.shared.addProfile(name: "Interim \(ext.id)")
        createdProfiles.append(profile)
        _ = profile.extensionController
        let context = try loadTestContext(ext, in: profile)
        let config = try XCTUnwrap(context.webViewConfiguration)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        pages.append(page)
        try await loadAndWait(page, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        context.loadBackgroundContent { error in
            if let error { print("loadBackgroundContent failed: \(error)") }
        }
        let world = World(context: context, page: page)
        // The worker is still starting; a worker that failed to load never answers.
        try await waitUntil("the worker to load and answer", timeout: 30) {
            (try? await self.probe(.worker, in: world)) != nil
        }
        return world
    }

    private struct ProbeFailed: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private func probe(_ via: Via, in world: World) async throws -> [String: Any] {
        switch via {
        case .page:
            let raw = try await world.page.callAsyncJavaScript(Self.probeJS + """

                return JSON.stringify(await __detourTestInterimProbe());
                """, arguments: [:], contentWorld: .page)
            let json = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        case .worker:
            let asked = try await askWorker(from: world.page, message: ["type": "interimProbe"], timeout: 20)
            guard let reply = asked["reply"] as? [String: Any], reply["ok"] as? Bool == true,
                  let value = reply["value"] as? [String: Any] else {
                throw ProbeFailed(message: "the worker did not answer the probe: \(asked)")
            }
            return value
        }
    }

    private static let chromeColors = [
        "GREY": "grey", "BLUE": "blue", "RED": "red", "YELLOW": "yellow", "GREEN": "green",
        "PINK": "pink", "PURPLE": "purple", "CYAN": "cyan", "ORANGE": "orange",
    ]

    // MARK: - Tests

    /// The point of the stand-ins: a worker that reads `chrome.tabGroups.Color`
    /// and registers `chrome.debugger` listeners while its module is evaluated
    /// loads, in the shape the Claude extension's does. Both contexts see
    /// constants and never-firing events only — no method of either API.
    func testWorkerThatTouchesBothNamespacesAtEvaluationLoads() async throws {
        let world = try await makeWorld(
            try await makeExtension(permissions: ["tabGroups", "debugger", "tabs", "storage"], touchingAtEvaluation: true))

        let worker = try await probe(.worker, in: world)
        XCTAssertEqual(worker["contextKind"] as? String, "worker")
        let evaluated = try XCTUnwrap(worker["evaluated"] as? [String: Any],
                                      "the worker's module-evaluation code must have run to its end")
        XCTAssertEqual(evaluated["colors"] as? [String],
                       ["blue", "cyan", "green", "orange", "red", "pink", "purple", "grey"])
        XCTAssertEqual(evaluated["none"] as? Int, -1)
        XCTAssertEqual(worker["debuggerEvents"] as? Int, 0, "the stand-in's events never fire")

        for via in Via.allCases {
            let result = try await probe(via, in: world)
            XCTAssertEqual(result["state"] as? [String: String], ["tabGroups": "interim", "debugger": "interim"], "\(via)")
            XCTAssertEqual(result["color"] as? [String: String], Self.chromeColors, "\(via)")
            XCTAssertEqual(result["none"] as? Int, -1, "\(via)")
            XCTAssertEqual(result["tabGroupsKeys"] as? [String], ["Color", "TAB_GROUP_ID_NONE"], "\(via)")
            XCTAssertEqual(result["debuggerKeys"] as? [String], ["onDetach", "onEvent"], "\(via)")
            XCTAssertEqual(result["survivesReread"] as? Bool, true, "\(via)")
            XCTAssertEqual(result["hasListener"] as? Bool, true, "\(via)")
            XCTAssertEqual(result["removed"] as? Bool, true, "\(via)")
            XCTAssertEqual(result["viaBrowserColor"] as? String, "blue", "\(via): browser.tabGroups must be there too")
            XCTAssertEqual(result["viaBrowserDebugger"] as? String, "function", "\(via): browser.debugger must be there too")

            // NEGATIVE: nothing of the real APIs exists yet, so a feature test
            // for any method still says "not here" (TASK-132.12 / 132.13).
            XCTAssertEqual(result["tabGroupsMethods"] as? [String], [], "\(via)")
            XCTAssertEqual(result["debuggerMethods"] as? [String], [], "\(via)")
            XCTAssertEqual(result["tabsGroup"] as? String, "undefined", "\(via)")
            XCTAssertEqual(result["tabsUngroup"] as? String, "undefined", "\(via)")

            // WebKit's own namespaces are untouched.
            XCTAssertEqual(result["tabsQuery"] as? String, "function", "\(via)")
            XCTAssertEqual(result["storage"] as? String, "function", "\(via)")
        }
    }

    /// NEGATIVE: an extension that declares neither permission gets neither
    /// namespace, in the worker and in a page.
    func testWithoutThePermissionsNeitherNamespaceExists() async throws {
        let world = try await makeWorld(
            try await makeExtension(permissions: ["tabs", "storage"], touchingAtEvaluation: false))
        for via in Via.allCases {
            let result = try await probe(via, in: world)
            XCTAssertEqual(result["tabGroupsType"] as? String, "undefined", "\(via)")
            XCTAssertEqual(result["debuggerType"] as? String, "undefined", "\(via)")
            XCTAssertEqual(result["state"] as? [String: String], ["tabGroups": "absent", "debugger": "absent"], "\(via)")
            XCTAssertEqual(result["tabsGroup"] as? String, "undefined", "\(via)")
            XCTAssertEqual(result["tabsQuery"] as? String, "function", "\(via)")
        }
    }

    /// NEGATIVE: each namespace follows its own permission.
    func testEachNamespaceFollowsItsOwnPermission() async throws {
        let world = try await makeWorld(
            try await makeExtension(permissions: ["debugger", "tabs", "storage"], touchingAtEvaluation: false))
        for via in Via.allCases {
            let result = try await probe(via, in: world)
            XCTAssertEqual(result["tabGroupsType"] as? String, "undefined", "\(via)")
            XCTAssertEqual(result["debuggerType"] as? String, "object", "\(via)")
            XCTAssertEqual(result["state"] as? [String: String], ["tabGroups": "absent", "debugger": "interim"], "\(via)")
            XCTAssertEqual(result["debuggerMethods"] as? [String], [], "\(via)")
        }
    }
}
