import XCTest
import AppKit
import WebKit
import GRDB
@testable import Detour

/// The extension tools of the automation endpoint (TASK-228.2, part 1)
/// against real extensions installed through `ExtensionManager.shared` into a
/// profile of the test's own: install from a folder and the errors of a bad
/// folder or CRX, listing and addressing by id or name, turning on and off,
/// permission decisions, the action popup and the options page driven with
/// the page and input tools, the worker reached through the automation
/// channel (calls, reads, console, worker_started), and the gate that keeps
/// the management tools to a test run.
nonisolated final class AutomationExtensionTests: XCTestCase {

    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []
    private var profiles: [Profile] = []
    private var installedIDs: Set<String> = []
    private var tempDirs: [URL] = []
    /// Kept for the rest of the process: releasing a profile whose extension
    /// controller hosted a popup traps in WebKit (`WKProcessPool` dealloc),
    /// in whichever suite runs next (wiki: webkit-test-host-traps). The
    /// context is still unloaded and the store row removed.
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        try await waitUntil("the host app's installed extensions to load") {
            ExtensionManager.shared.hasLoadedInstalledExtensions
        }
        AutomationExtensionChannel.shared.isOpen = true
        AutomationExtensionConsole.shared.start()
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
        AutomationExtensionConsole.shared.stop()
        AutomationExtensionChannel.shared.isOpen = false
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        try await super.tearDown()
    }

    // MARK: Fixture

    private struct Fixture {
        let server: MCPServer
        let tools: AutomationTools
        let profile: Profile
        let space: Space
        let window: BrowserWindowController
        let windowID: Int
    }

    /// A profile of its own with one space, shown in a window with a page
    /// selected, and the tools in test-run mode unless `testRun` is false.
    @MainActor private func makeFixture(testRun: Bool = true) async throws -> Fixture {
        let store = TabStore.shared
        let profile = store.addProfile(name: "Automation Ext \(UUID().uuidString.prefix(6))")
        profiles.append(profile)
        _ = profile.extensionController
        let space = store.addSpace(name: "Automation Ext", emoji: "E", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        let tab = store.addTab(in: space, url: URL(string: "about:blank")!)
        wc.selectTab(id: tab.id)
        var environment = AutomationEnvironment(windowControllers: { [wc] }, mainMenu: { nil }, store: store)
        environment.isTestRun = testRun
        let tools = AutomationTools(environment: environment)
        let server = MCPServer(tools: tools.all, serverVersion: "test", instructions: "")
        return Fixture(server: server, tools: tools, profile: profile, space: space, window: wc,
                       windowID: tools.windowIDs.id(for: wc))
    }

    /// An unpacked MV3 extension: a worker with state to read and functions to
    /// call, an action popup with a button, an options page.
    @MainActor private func makeExtensionFolder(name: String, manifest: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-automation-ext-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let files: [String: String] = [
            "manifest.json": manifest ?? """
                { "manifest_version": 3, "name": "\(name)", "version": "1.2.3", "permissions": ["storage"],
                  "background": { "service_worker": "bg.js" },
                  "action": { "default_popup": "popup.html" }, "options_page": "options.html" }
                """,
            "bg.js": """
                self.fixtureState = { count: 3, label: 'ready' };
                self.add = (a, b) => a + b;
                self.neverSettles = () => new Promise(() => {});
                console.log('worker started');
                """,
            "popup.html": "<!doctype html><title>Popup</title><button id=\"b\">Press</button><script src=\"popup.js\"></script>",
            "popup.js": """
                document.getElementById('b').addEventListener('click', () => {
                  document.body.dataset.clicked = 'yes';
                  console.warn('pressed');
                });
                console.log('popup loaded');
                """,
            "options.html": "<!doctype html><title>Fixture Options</title><p id=\"o\">options</p>",
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

    /// Installs `folder` through the tool and returns the extension's id.
    @MainActor private func install(_ f: Fixture, _ folder: URL) async throws -> String {
        let result = try await ok(f, "install_extension", ["path": .string(folder.path),
                                                            "profile_id": .string(f.profile.id.uuidString)])
        let id = try XCTUnwrap(result["extension"]?["id"]?.stringValue)
        installedIDs.insert(id)
        XCTAssertEqual(result["loaded"], true, result.jsonString)
        return id
    }

    // MARK: The gate (AC #7)

    @MainActor func testTheManagementToolsAreRefusedOutsideATestRun() async throws {
        let f = try await makeFixture(testRun: false)
        let folder = try makeExtensionFolder(name: "Gate Fixture")
        let arguments: [(String, JSONValue)] = [
            ("install_extension", ["path": .string(folder.path)]),
            ("uninstall_extension", ["extension": "anything"]),
            ("set_extension_enabled", ["extension": "anything", "enabled": true]),
            ("set_extension_permission", ["extension": "anything", "permission": "tabs", "granted": true]),
        ]
        for (tool, args) in arguments {
            let refused = try await code(f, tool, args)
            XCTAssertEqual(refused, "gate_closed", tool)
        }
        XCTAssertTrue(ExtensionManager.shared.extensions.allSatisfy { $0.sourcePath?.standardizedFileURL.path != folder.path },
                      "nothing was installed")
        // Reading works whenever the endpoint is on.
        try await ok(f, "list_extensions", [:])
    }

    // MARK: Install, list, address (AC #1, #10)

    @MainActor func testInstallListAndAddressByIdOrName() async throws {
        let f = try await makeFixture()
        let name = "Automation Fixture \(UUID().uuidString.prefix(6))"
        let folder = try makeExtensionFolder(name: name)
        let id = try await install(f, folder)

        let listed = try await ok(f, "list_extensions", ["extension": .string(name.uppercased())])
        let entry = try XCTUnwrap(listed["extensions"]?.arrayValue?.first)
        XCTAssertEqual(entry["id"], .string(id), "a manifest name finds it, ignoring case")
        XCTAssertEqual(entry["version"], "1.2.3")
        XCTAssertEqual(entry["source"], "unpacked")
        XCTAssertEqual(entry["has_background"], true)
        let profileEntry = try XCTUnwrap(entry["profiles"]?.arrayValue?.first { $0["profile_id"] == .string(f.profile.id.uuidString) })
        XCTAssertEqual(profileEntry["loaded"], true)
        XCTAssertEqual(profileEntry["turned_on"], true)
        XCTAssertEqual(entry["permission_decisions"], [["permission": "storage", "type": "api", "granted": true]])
        XCTAssertNil(listed["extensions"]?.arrayValue?.first { $0["profiles"]?.arrayValue?.contains { $0["profile_name"] == "Private" } == true },
                     "the Private profile is left out")

        let all = try await ok(f, "list_extensions", [:])
        let ids = all["extensions"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        XCTAssertEqual(ids, ids.sorted(), "sorted by id")
        XCTAssertTrue(ids.contains(id))

        // The same folder again keeps its id; a copy elsewhere with the same
        // name is a second extension, and the name is then ambiguous.
        let again = try await install(f, folder)
        XCTAssertEqual(again, id, "a reinstall from the same folder keeps the id")
        let copy = try makeExtensionFolder(name: name)
        let other = try await install(f, copy)
        XCTAssertNotEqual(other, id)
        let ambiguous = try await code(f, "list_extensions", ["extension": .string(name)])
        XCTAssertEqual(ambiguous, "ambiguous_extension")
        let byID = try await ok(f, "list_extensions", ["extension": .string(id)])
        XCTAssertEqual(byID["extensions"]?.arrayValue?.count, 1, "an id is never ambiguous")
        let unknown = try await code(f, "list_extensions", ["extension": "No Such Extension"])
        XCTAssertEqual(unknown, "unknown_extension")
    }

    @MainActor func testInstallRefusesBadFoldersCRXsAndProfiles() async throws {
        let f = try await makeFixture()
        let relative = try await code(f, "install_extension", ["path": "TestExtensions/hello-world",
                                                              "profile_id": .string(f.profile.id.uuidString)])
        XCTAssertEqual(relative, "invalid_arguments")
        let missing = try await code(f, "install_extension", ["path": "/nonexistent/detour-ext",
                                                             "profile_id": .string(f.profile.id.uuidString)])
        XCTAssertEqual(missing, "invalid_arguments")

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("detour-automation-empty-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        tempDirs.append(empty)
        let noManifest = try await code(f, "install_extension", ["path": .string(empty.path),
                                                                "profile_id": .string(f.profile.id.uuidString)])
        XCTAssertEqual(noManifest, "install_failed")

        let invalid = try makeExtensionFolder(name: "x", manifest: "{ \"name\": \"no version\" ")
        let badManifest = try await code(f, "install_extension", ["path": .string(invalid.path),
                                                                 "profile_id": .string(f.profile.id.uuidString)])
        XCTAssertEqual(badManifest, "install_failed")

        let crx = empty.appendingPathComponent("broken.crx")
        try Data("Cr24 not really a crx".utf8).write(to: crx)
        let badCRX = try await code(f, "install_extension", ["path": .string(crx.path),
                                                            "profile_id": .string(f.profile.id.uuidString)])
        XCTAssertEqual(badCRX, "install_failed")

        let good = try makeExtensionFolder(name: "Profile Check")
        let privateProfile = TabStore.shared.ensureIncognitoProfile()
        let toPrivate = try await code(f, "install_extension", ["path": .string(good.path),
                                                               "profile_id": .string(privateProfile.id.uuidString)])
        XCTAssertEqual(toPrivate, "private_unreachable")
        let toNobody = try await code(f, "install_extension", ["path": .string(good.path),
                                                              "profile_id": .string(UUID().uuidString)])
        XCTAssertEqual(toNobody, "unknown_profile")
        XCTAssertTrue(ExtensionManager.shared.extensions.allSatisfy { $0.sourcePath?.standardizedFileURL.path != good.path },
                      "a refused install installs nothing")
    }

    // MARK: The worker (AC #2, #3, #4, #6)

    @MainActor func testTheWorkerAnswersCallsReadsAndItsConsole() async throws {
        let f = try await makeFixture()
        let id = try await install(f, try makeExtensionFolder(name: "Worker Fixture \(UUID().uuidString.prefix(6))"))
        let worker = JSONValue.string("worker:\(id)")

        let started = try await ok(f, "wait_for", ["context": worker, "worker_started": true, "timeout_ms": 15000])
        XCTAssertEqual(started["matched"], true)
        XCTAssertEqual(started["value"]?["kind"], "worker")

        try await ok(f, "call_extension_api", ["context": worker, "path": "chrome.storage.local.set",
                                               "args": "[{\"answer\": 42}]"])
        let stored = try await ok(f, "call_extension_api", ["context": worker, "path": "chrome.storage.local.get",
                                                            "args": "[\"answer\"]"])
        XCTAssertEqual(stored["value"], ["answer": 42])
        XCTAssertEqual(stored["type"], "object")
        let sum = try await ok(f, "call_extension_api", ["context": worker, "path": "self.add", "args": "[2, 3]"])
        XCTAssertEqual(sum["value"], 5)
        let state = try await ok(f, "read_extension_global", ["context": worker, "path": "self.fixtureState"])
        XCTAssertEqual(state["value"], ["count": 3, "label": "ready"])
        let runtimeID = try await ok(f, "read_extension_global", ["context": worker, "path": "chrome.runtime.id"])
        XCTAssertEqual(runtimeID["value"], .string(id))

        let missing = try await call(f, "call_extension_api", ["context": worker, "path": "chrome.notAnAPI.call"])
        XCTAssertEqual(missing.content["error"]?["code"], "script_error")
        XCTAssertEqual(missing.content["error"]?["details"]?["name"], "TypeError", "what the extension would get")
        let badArgs = try await code(f, "call_extension_api", ["context": worker, "path": "self.add", "args": "{}"])
        XCTAssertEqual(badArgs, "invalid_arguments")
        let slow = try await code(f, "call_extension_api", ["context": worker, "path": "self.neverSettles",
                                                           "timeout_ms": 400])
        XCTAssertEqual(slow, "timeout")

        // The console: the worker's own line, and one logged through a call.
        try await ok(f, "call_extension_api", ["context": worker, "path": "console.error", "args": "[\"from the test\"]"])
        var messages: [JSONValue] = []
        try await waitUntil("the worker's console lines") {
            messages = try await self.ok(f, "console_messages", ["context": worker])["messages"]?.arrayValue ?? []
            return messages.contains { $0["text"] == "from the test" }
        }
        XCTAssertTrue(messages.contains { $0["text"] == "worker started" && $0["level"] == "log" }, "\(messages)")
        let logged = try XCTUnwrap(messages.first { $0["text"] == "from the test" })
        XCTAssertEqual(logged["level"], "error")
        XCTAssertEqual(logged["context_kind"], "worker")
        XCTAssertEqual(logged["context"], .string("worker:\(id)"))
        let errorsOnly = try await ok(f, "console_messages", ["context": worker, "levels": ["error"]])
        XCTAssertTrue(errorsOnly["messages"]?.arrayValue?.allSatisfy { $0["level"] == "error" } ?? false)

        // A worker has no page.
        let evaluate = try await code(f, "evaluate_js", ["context": worker, "expression": "1"])
        XCTAssertEqual(evaluate, "unsupported_context")
        let network = try await code(f, "network_requests", ["context": worker])
        XCTAssertEqual(network, "unsupported_context")
        let load = try await code(f, "wait_for", ["context": worker, "load": true])
        XCTAssertEqual(load, "unsupported_context")
        let mismatched = try await code(f, "wait_for", ["context": .string("tab:\(UUID().uuidString)"), "worker_started": true])
        XCTAssertEqual(mismatched, "invalid_arguments")
    }

    /// With the channel closed, no worker takes a command: worker_not_running,
    /// and wait_for worker_started answers timeout.
    @MainActor func testAClosedChannelReachesNoWorker() async throws {
        let f = try await makeFixture()
        let id = try await install(f, try makeExtensionFolder(name: "Closed Fixture \(UUID().uuidString.prefix(6))"))
        try await ok(f, "wait_for", ["context": .string("worker:\(id)"), "worker_started": true, "timeout_ms": 15000])
        AutomationExtensionChannel.shared.isOpen = false
        let refused = try await code(f, "call_extension_api", ["context": .string("worker:\(id)"), "path": "self.add"])
        XCTAssertEqual(refused, "worker_not_running")
        AutomationExtensionChannel.shared.isOpen = true
        // The worker that started while it was closed was told to stop, and
        // parks again only at its next start.
        let stopped = try await code(f, "wait_for", ["context": .string("worker:\(id)"), "worker_started": true,
                                                    "timeout_ms": 500])
        XCTAssertEqual(stopped, "timeout")
    }

    // MARK: The popup (AC #2, #3, #4)

    @MainActor func testThePopupOpensAndTakesThePageAndInputTools() async throws {
        let f = try await makeFixture()
        let id = try await install(f, try makeExtensionFolder(name: "Popup Fixture \(UUID().uuidString.prefix(6))"))
        let popup = JSONValue.string("popup:\(id)")

        let notOpen = try await code(f, "evaluate_js", ["context": popup, "expression": "1"])
        XCTAssertEqual(notOpen, "context_not_open")

        let opened = try await ok(f, "open_extension_context", ["extension": .string(id), "kind": "popup",
                                                                 "window_id": .int(f.windowID)])
        XCTAssertEqual(opened["context"], popup)
        XCTAssertEqual(opened["window_id"], .int(f.windowID))
        try await ok(f, "wait_for", ["context": popup, "load": true, "timeout_ms": 10000])
        let title = try await ok(f, "evaluate_js", ["context": popup, "expression": "document.title"])
        XCTAssertEqual(title["value"], "Popup")
        let elements = try await ok(f, "read_page", ["context": popup, "mode": "elements"])
        XCTAssertTrue(elements["elements"]?.arrayValue?.contains { $0["selector"] == "#b" } ?? false, elements.jsonString)
        let manifest = try await ok(f, "call_extension_api", ["context": popup, "path": "chrome.runtime.getManifest"])
        XCTAssertEqual(manifest["value"]?["version"], "1.2.3", "chrome.* in the popup page")

        try await waitUntil("the popover to be on screen") {
            AutomationExtensionPopups.shared.popup(.init(extensionID: id, profileID: f.profile.id))?.webView.window != nil
        }
        let clicked = try await ok(f, "click", ["context": popup, "selector": "#b"])
        XCTAssertEqual(clicked["window_id"], .int(f.windowID), "input names the window the popup was opened from")
        try await ok(f, "wait_for", ["context": popup, "expression": "document.body.dataset.clicked === 'yes'"])
        var messages: [JSONValue] = []
        try await waitUntil("the popup's console") {
            messages = try await self.ok(f, "console_messages", ["context": popup])["messages"]?.arrayValue ?? []
            return messages.contains { $0["text"] == "pressed" }
        }
        XCTAssertEqual(messages.first { $0["text"] == "pressed" }?["level"], "warn")
        XCTAssertTrue(messages.allSatisfy { $0["context_kind"] == "popup" })
        let everything = try await ok(f, "console_messages", ["context": .string("extension:\(id)")])
        XCTAssertTrue(everything["messages"]?.arrayValue?.contains { $0["text"] == "popup loaded" } ?? false)

        let shot = try await call(f, "screenshot", ["context": popup, "include_image": false])
        XCTAssertFalse(shot.isError, shot.content.jsonString)

        try await ok(f, "close_extension_context", ["context": popup])
        let closed = try await code(f, "evaluate_js", ["context": popup, "expression": "1"])
        XCTAssertEqual(closed, "context_not_open")
        let again = try await code(f, "close_extension_context", ["context": popup])
        XCTAssertEqual(again, "context_not_open")
        let readAfter = try await ok(f, "console_messages", ["context": popup])
        XCTAssertFalse(readAfter["messages"]?.arrayValue?.isEmpty ?? true, "the records outlive the popup")
    }

    // MARK: The options page

    @MainActor func testTheOptionsPageOpensInATabAndCloses() async throws {
        let f = try await makeFixture()
        let id = try await install(f, try makeExtensionFolder(name: "Options Fixture \(UUID().uuidString.prefix(6))"))
        let options = JSONValue.string("options:\(id)")
        let notOpen = try await code(f, "read_page", ["context": options])
        XCTAssertEqual(notOpen, "context_not_open")

        let opened = try await ok(f, "open_extension_context", ["extension": .string(id), "kind": "options"])
        let tabID = try XCTUnwrap(opened["tab_id"]?.stringValue)
        XCTAssertEqual(opened["window_id"], .null, "opened in the background")
        XCTAssertNotEqual(f.window.selectedTabID?.uuidString, tabID)
        try await ok(f, "wait_for", ["context": options, "load": true])
        let page = try await ok(f, "read_page", ["context": options, "mode": "text"])
        XCTAssertEqual(page["title"], "Fixture Options")
        XCTAssertEqual(page["text"], "options")

        let shown = try await ok(f, "open_extension_context", ["extension": .string(id), "kind": "options",
                                                               "window_id": .int(f.windowID)])
        XCTAssertEqual(shown["tab_id"], .string(tabID), "the open page is reused")
        XCTAssertEqual(f.window.selectedTabID?.uuidString, tabID, "and selected in the window")

        // Only the background takes commands: a page's park is refused, so a
        // page can never take (or answer) the worker's commands.
        let pagePark = try await ok(f, "evaluate_js", ["context": options, "script": """
            try { await __detourPolyfillRequest('automation.awaitCommand', { instance: 'page' }); return 'parked'; }
            catch (error) { return String(error.message); }
            """])
        XCTAssertEqual(pagePark["value"], "automation: only the background context takes commands")
        let pageResult = try await ok(f, "evaluate_js", ["context": options, "script": """
            try { await __detourPolyfillRequest('automation.result', { instance: 'page', result: '{"id": 1}' }); return 'taken'; }
            catch (error) { return String(error.message); }
            """])
        XCTAssertEqual(pageResult["value"], "automation: only the background context takes commands")

        try await ok(f, "close_extension_context", ["context": options])
        let closed = try await code(f, "read_page", ["context": options])
        XCTAssertEqual(closed, "context_not_open")

        // A pinned options page is closed too (its entry stays, dormant).
        let reopened = try await ok(f, "open_extension_context", ["extension": .string(id), "kind": "options"])
        let pinnedTabID = try XCTUnwrap(reopened["tab_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        TabStore.shared.pinTab(id: pinnedTabID, in: f.space)
        XCTAssertTrue(f.space.pinnedTabs.contains { $0.id == pinnedTabID }, "pinned")
        try await ok(f, "close_extension_context", ["context": options])
        XCTAssertFalse(f.space.pinnedTabs.contains { $0.id == pinnedTabID }, "its backing tab is closed")
        let pinnedClosed = try await code(f, "read_page", ["context": options])
        XCTAssertEqual(pinnedClosed, "context_not_open")
    }

    // MARK: Turning on and off, permissions, uninstall (AC #1)

    @MainActor func testEnablePermissionsAndUninstall() async throws {
        let f = try await makeFixture()
        let id = try await install(f, try makeExtensionFolder(name: "Toggle Fixture \(UUID().uuidString.prefix(6))"))
        let worker = JSONValue.string("worker:\(id)")

        let off = try await ok(f, "set_extension_enabled", ["extension": .string(id), "enabled": false,
                                                            "profile_id": .string(f.profile.id.uuidString)])
        let offProfile = off["extension"]?["profiles"]?.arrayValue?.first { $0["profile_id"] == .string(f.profile.id.uuidString) }
        XCTAssertEqual(offProfile?["loaded"], false)
        XCTAssertNil(f.profile.extensionContext(for: id))
        let disabled = try await code(f, "read_extension_global", ["context": worker, "path": "self.fixtureState"])
        XCTAssertEqual(disabled, "extension_disabled")
        try await ok(f, "set_extension_enabled", ["extension": .string(id), "enabled": true,
                                                  "profile_id": .string(f.profile.id.uuidString)])
        XCTAssertNotNil(f.profile.extensionContext(for: id))
        try await ok(f, "set_extension_enabled", ["extension": .string(id), "enabled": false])
        XCTAssertNil(f.profile.extensionContext(for: id), "the global switch")
        try await ok(f, "set_extension_enabled", ["extension": .string(id), "enabled": true])
        XCTAssertNotNil(f.profile.extensionContext(for: id), "the profile's choice survived the global switch")
        let privateProfile = TabStore.shared.ensureIncognitoProfile()
        let toPrivate = try await code(f, "set_extension_enabled", ["extension": .string(id), "enabled": true,
                                                                   "profile_id": .string(privateProfile.id.uuidString)])
        XCTAssertEqual(toPrivate, "private_unreachable")

        let granted = try await ok(f, "set_extension_permission", ["extension": .string(id), "permission": "storage",
                                                                   "granted": false])
        XCTAssertEqual(granted["type"], "api")
        XCTAssertEqual(granted["warnings"], [])
        XCTAssertEqual(AppDatabase.shared.permissionStatus(extensionID: id, key: "storage", type: .apiPermission), .denied)
        let undeclared = try await ok(f, "set_extension_permission", ["extension": .string(id), "permission": "tabs",
                                                                      "granted": true])
        XCTAssertEqual(undeclared["warnings"]?.arrayValue?.count, 1, "tabs is not declared")
        let host = try await ok(f, "set_extension_permission", ["extension": .string(id),
                                                                "permission": "https://example.com/*", "granted": true])
        XCTAssertEqual(host["type"], "match_pattern")
        XCTAssertEqual(host["warnings"]?.arrayValue?.count, 1, "outside the manifest's host patterns: inert")
        XCTAssertTrue(host["permission_decisions"]?.arrayValue?.contains {
            $0["permission"] == "https://example.com/*" && $0["granted"] == true
        } ?? false)
        let badPattern = try await code(f, "set_extension_permission", ["extension": .string(id), "permission": "nope",
                                                                        "type": "match_pattern", "granted": true])
        XCTAssertEqual(badPattern, "invalid_arguments")

        let removed = try await ok(f, "uninstall_extension", ["extension": .string(id)])
        XCTAssertEqual(removed["uninstalled"], true)
        let gone = try await code(f, "read_extension_global", ["context": worker, "path": "self.fixtureState"])
        XCTAssertEqual(gone, "unknown_extension")
    }

    // MARK: Contexts that are not there

    @MainActor func testProfilesSidePanelsAndMissingContexts() async throws {
        let f = try await makeFixture()
        let id = try await install(f, try makeExtensionFolder(name: "Context Fixture \(UUID().uuidString.prefix(6))"))
        let sidePanel = try await code(f, "evaluate_js", ["context": .string("sidepanel:\(id)"), "expression": "1"])
        XCTAssertEqual(sidePanel, "unsupported_context")
        let openSidePanel = try await code(f, "open_extension_context", ["extension": .string(id), "kind": "sidepanel"])
        XCTAssertEqual(openSidePanel, "unsupported_context")
        let unknown = try await code(f, "console_messages", ["context": "worker:no-such-extension"])
        XCTAssertEqual(unknown, "unknown_extension")

        // On in a second profile: the context needs a profile.
        let second = TabStore.shared.addProfile(name: "Automation Ext Second \(UUID().uuidString.prefix(4))")
        profiles.append(second)
        _ = second.extensionController
        ExtensionManager.shared.setEnabled(id: id, profileID: second.id, enabled: true)
        XCTAssertNotNil(second.extensionContext(for: id))
        let ambiguous = try await code(f, "read_extension_global", ["context": .string("worker:\(id)"), "path": "self.add"])
        XCTAssertEqual(ambiguous, "ambiguous_profile")
        let named = try await ok(f, "read_extension_global", ["context": .string("worker:\(id)@\(f.profile.id.uuidString)"),
                                                              "path": "self.fixtureState.label", "timeout_ms": 15000])
        XCTAssertEqual(named["value"], "ready")
    }
}
