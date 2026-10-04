import XCTest
import WebKit
@testable import Detour

/// TASK-132.2: the tab id bridge end to end — a WebKit tab id from
/// `chrome.tabs`, resolved by the polyfill's `__detourResolveTab` in a real
/// extension context (its service worker over the native-message transport and
/// an extension page over the script message handler), must come back as the
/// handle of exactly the `BrowserTab` WebKit means by that id.
///
/// Everything here is production wiring: real `Profile`s and their lazily built
/// controllers, `TabStore.shared`, real `BrowserWindowController`s (never
/// shown, so never key) and tabs added through the store. The fixture
/// extension declares no permissions at all, which is the point of going
/// through `tabs.getZoom`.
///
/// Ground truth for "which tab is this id" does not come from the bridge:
/// `chrome.windows.getAll({ populate: true })` lists each window's tabs with
/// their `index`, which is the position in `BrowserWindowController.extensionTabs`,
/// and the windows are told apart by the width the test gave them.
@MainActor
final class ExtensionTabResolveTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var windows: [BrowserWindowController] = []
    /// WebKit's window id for each fixture window, learnt on first listing.
    private var webKitWindowIDs: [ObjectIdentifier: Int] = [:]
    private var pages: [WKWebView] = []
    private var server: LoopbackHTTPServer?
    private var serverPort: UInt16 = 0
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?

    /// Profiles whose extension controller hosted a web view stay alive for the
    /// rest of the test process: releasing one takes its process pool down, and
    /// WebKit traps when that lands inside an IPC dispatch (the hazard
    /// `ExtensionPrivateStoreTests` works around the same way).
    private static var retainedProfiles: [Profile] = []

    override func setUp() async throws {
        try await super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
        let server = try LoopbackHTTPServer(routes: Dictionary(uniqueKeysWithValues:
            ["a1", "a2", "a3", "pinned", "favorite", "peek", "b1", "b2", "other"].map {
                ("/\($0)", "<html><head><title>\($0)</title></head><body>\($0)</body></html>")
            }))
        serverPort = try await server.start()
        self.server = server
    }

    override func tearDown() async throws {
        let store = TabStore.shared
        for wc in windows { wc.window?.close() }
        windows.removeAll()
        webKitWindowIDs.removeAll()
        for page in pages { page.stopLoading() }
        pages.removeAll()

        for id in createdSpaceIDs {
            guard let space = store.space(withID: id) else { continue }
            for host in space.tabs + space.pinnedTabs {
                if let peek = host.peekTab {
                    peek.teardown()
                    host.clearPeekState()
                }
            }
            for entry in space.pinnedEntries {
                store.closePinnedTab(id: entry.id, in: space, undoable: false)
            }
            for tab in space.tabs {
                store.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
            }
        }
        for profile in createdProfiles {
            for favorite in profile.favorites {
                if let peek = favorite.tab?.peekTab {
                    peek.teardown()
                    favorite.tab?.clearPeekState()
                }
                store.removeFavorite(id: favorite.id, profileID: profile.id)
            }
        }
        for id in createdSpaceIDs { store.forceRemoveSpace(id: id) }
        createdSpaceIDs.removeAll()
        store.undoManager.removeAllActions()
        // Closing a window saved the session with the fixture spaces in it;
        // save again without them, or their rows keep the profile row alive.
        store.saveNow()

        for profile in createdProfiles {
            profile.unloadAllExtensions()
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            store.forceRemoveProfile(id: profile.id)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()

        store.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        server?.stop()
        server = nil
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture extension

    /// What a test asks a JS context to do, written once and run in both
    /// contexts: the worker carries it in its script, the page gets it with
    /// each `callAsyncJavaScript`.
    private static let tabOpJS = """
    async function __detourTestTabOp(message) {
        const describe = (handle) => __detourPolyfillRequest('tabs.describeHandle', { handle: handle });
        const orNull = (value) => value === undefined ? null : value;
        switch (message.op) {
        case 'windows': {
            const all = await chrome.windows.getAll({ populate: true });
            return all.map((w) => ({
                id: w.id, width: w.width, focused: w.focused,
                tabs: (w.tabs || []).map((t) => ({
                    id: t.id, index: t.index, active: t.active, pinned: t.pinned,
                    hasURL: typeof t.url === 'string' && t.url.length > 0
                }))
            }));
        }
        case 'resolve': {
            const handle = await __detourResolveTab(message.tabId, { fresh: !!message.fresh });
            return { handle: handle, described: await describe(handle) };
        }
        case 'describe':
            return await describe(message.handle);
        case 'getZoom':
            return { zoom: await chrome.tabs.getZoom(message.tabId) };
        case 'nativeGetZoom':
            return { zoom: await chrome.tabs.getZoom._detourNative.call(chrome.tabs, message.tabId) };
        case 'getZoomCallback':
            return await new Promise((resolve) => {
                const returned = chrome.tabs.getZoom(message.tabId, function(zoom) {
                    resolve({
                        argc: arguments.length,
                        zoom: orNull(zoom),
                        lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null,
                        returnedType: typeof returned
                    });
                });
            });
        case 'tabIdForHandle':
            return { tabId: orNull(__detourTabIdForHandle(message.handle)) };
        case 'findTabIdForHandle':
            return { tabId: orNull(await __detourFindTabIdForHandle(message.handle)) };
        case 'install': {
            const internal = ['__detourResolveTab', '__detourTabIdForHandle',
                              '__detourFindTabIdForHandle', '__detourTabResolveInstall'];
            return {
                install: globalThis.__detourTabResolveInstall,
                contextKind: globalThis.__detourContextKind,
                wrapped: chrome.tabs.getZoom._detourZoomWrapper === true,
                nativeKept: __detourNativeness(chrome.tabs.getZoom._detourNative),
                held: globalThis.__detourHeldWrappers.tabs === chrome.tabs,
                browserWrapped: browser.tabs.getZoom._detourZoomWrapper === true,
                defined: internal.filter((name) => typeof globalThis[name] !== 'undefined'),
                enumerable: Object.keys(globalThis).filter((name) => internal.indexOf(name) !== -1)
            };
        }
        case 'storm': {
            // Resolves and genuine getZoom calls issued together, so the
            // genuine calls race the resolver's arms.
            const work = [];
            for (let round = 0; round < message.rounds; round++) {
                for (const id of message.tabIds) {
                    work.push(__detourResolveTab(id, { fresh: true }).then((value) => ({ kind: 'handle', id: id, value: value })));
                    work.push(chrome.tabs.getZoom(id).then((value) => ({ kind: 'zoom', id: id, value: value })));
                    work.push(new Promise((resolve) => {
                        chrome.tabs.getZoom(id, (value) => resolve({ kind: 'zoom', id: id, value: orNull(value) }));
                    }));
                }
            }
            return await Promise.all(work);
        }
        }
        throw new Error('unknown op ' + message.op);
    }
    """

    /// An MV3 extension with a (module) service worker and one page, and no
    /// permissions. The worker carries the polyfill itself — the user script
    /// `Profile.extensionController` installs reaches web views, not workers.
    private func makeExtension() async throws -> WebExtension {
        let id = "tab-resolve-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        try """
        {
            "manifest_version": 3,
            "name": "Tab Resolve Test",
            "version": "1.0.0",
            "background": { "service_worker": "background.js", "type": "module" }
        }
        """.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html><body><div id=\"test\">tab resolve test page</div></body></html>"
            .write(to: dir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)
        try (ExtensionAPIPolyfill.polyfillJS + "\n\n" + Self.tabOpJS + """


        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (!message || message.type !== 'tabOp') return false;
            __detourTestTabOp(message.payload).then(
                (value) => sendResponse({ ok: true, value: value === undefined ? null : value }),
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
        return ext
    }

    // MARK: - Fixture world

    /// One profile with the extension loaded: two spaces, a window on each, an
    /// extension page and the started worker.
    private struct World {
        let ext: WebExtension
        let profile: Profile
        let context: WKWebExtensionContext
        let spaceA: Space
        let spaceB: Space
        let windowA: BrowserWindowController
        let windowB: BrowserWindowController
        let page: WKWebView

        var key: ExtensionTabHandleRegistry.ContextKey {
            ExtensionTabHandleRegistry.ContextKey(profileID: profile.id, extensionID: ext.id)
        }
    }

    private static let windowAWidth: CGFloat = 910
    private static let windowBWidth: CGFloat = 1030

    private func makeWindow(on space: Space, width: CGFloat) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        windows.append(wc)
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        wc.window?.setFrame(NSRect(x: 60, y: 60, width: width, height: 640), display: false)
        wc.setActiveSpace(id: space.id)
        return wc
    }

    private func makeWorld(_ ext: WebExtension, name: String) async throws -> World {
        let store = TabStore.shared
        let profile = store.addProfile(name: name)
        createdProfiles.append(profile)
        _ = profile.extensionController
        let spaceA = store.addSpace(name: "\(name) A", emoji: "A", colorHex: "007AFF", profileID: profile.id)
        let spaceB = store.addSpace(name: "\(name) B", emoji: "B", colorHex: "34C759", profileID: profile.id)
        createdSpaceIDs.append(contentsOf: [spaceA.id, spaceB.id])

        // The windows exist before the context loads: WebKit asks the delegate
        // for the open windows at load, and afterwards only hears of a window
        // when it becomes key — which these never do.
        let windowA = makeWindow(on: spaceA, width: Self.windowAWidth)
        let windowB = makeWindow(on: spaceB, width: Self.windowBWidth)
        XCTAssertEqual(windowA.activeSpaceID, spaceA.id)
        XCTAssertEqual(windowB.activeSpaceID, spaceB.id)
        XCTAssertTrue(extensionBrowserWindows().contains { $0 === windowA },
                      "an unshown window must still be one the extension delegate lists")

        let context = try loadTestContext(ext, in: profile)
        let config = try XCTUnwrap(context.webViewConfiguration)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        pages.append(page)
        try await loadAndWait(page, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        context.loadBackgroundContent { error in
            if let error { print("loadBackgroundContent failed: \(error)") }
        }
        let world = World(ext: ext, profile: profile, context: context, spaceA: spaceA, spaceB: spaceB,
                          windowA: windowA, windowB: windowB, page: page)
        // The worker is still starting; an unreachable worker answers nothing.
        try await waitUntil("the worker to answer", timeout: 30) {
            (try? await self.run(.worker, in: world, ["op": "install"])) != nil
        }
        return world
    }

    private func url(_ name: String) -> URL {
        URL(string: "http://127.0.0.1:\(serverPort)/\(name)")!
    }

    /// A tab added through the store, as the app adds one.
    private func addTab(_ name: String, in space: Space) -> BrowserTab {
        TabStore.shared.addTab(in: space, url: url(name))
    }

    // MARK: - Running an op

    private enum Via: String, CaseIterable { case page, worker }

    private struct OpFailed: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// The worker never ran the op — not a rejection, so never mistaken for one.
    private struct WorkerSilent: Error, CustomStringConvertible {
        let envelope: [String: Any]
        var description: String { "the worker did not answer: \(envelope)" }
    }

    /// Runs one op in the page or the worker. Throws `OpFailed` with the JS
    /// error's message when the op rejected.
    private func run(_ via: Via, in world: World, _ message: [String: Any]) async throws -> Any {
        let envelope: [String: Any]
        switch via {
        case .page:
            let raw = try await world.page.callAsyncJavaScript(Self.tabOpJS + """

                try {
                    const value = await __detourTestTabOp(message);
                    return JSON.stringify({ ok: true, value: value === undefined ? null : value });
                } catch (e) {
                    return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
                }
                """, arguments: ["message": message], contentWorld: .page)
            let json = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
            envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        case .worker:
            let asked = try await askWorker(from: world.page,
                                            message: ["type": "tabOp", "payload": message], timeout: 20)
            guard let reply = asked["reply"] as? [String: Any] else {
                throw WorkerSilent(envelope: asked)
            }
            envelope = reply
        }
        guard envelope["ok"] as? Bool == true else {
            throw OpFailed(message: envelope["error"] as? String ?? "no error text: \(envelope)")
        }
        return envelope["value"] ?? NSNull()
    }

    private func runDict(_ via: Via, in world: World, _ message: [String: Any]) async throws -> [String: Any] {
        let value = try await run(via, in: world, message)
        return try XCTUnwrap(value as? [String: Any], "expected an object, got \(value)")
    }

    /// The op's rejection text, or nil when it resolved.
    private func failure(_ via: Via, in world: World, _ message: [String: Any]) async throws -> String? {
        do {
            _ = try await run(via, in: world, message)
            return nil
        } catch let error as OpFailed {
            return error.message
        }
    }

    // MARK: - Ground truth

    /// WebKit's id for every tab the two windows list, read from
    /// `chrome.windows.getAll({ populate: true })`: a window is recognised by
    /// its width, and a tab by its index in that window's `extensionTabs`.
    private func tabIDs(_ via: Via, in world: World,
                        file: StaticString = #filePath, line: UInt = #line) async throws -> [ObjectIdentifier: Int] {
        let answer = try await run(via, in: world, ["op": "windows"])
        let listed = try XCTUnwrap(answer as? [[String: Any]], file: file, line: line)
        var ids: [ObjectIdentifier: Int] = [:]
        for (wc, width) in [(world.windowA, Self.windowAWidth), (world.windowB, Self.windowBWidth)] {
            // Recognised by width the first time and by WebKit's window id from
            // then on: a window that switches space can come back resized.
            let window: [String: Any]
            if let knownID = webKitWindowIDs[ObjectIdentifier(wc)] {
                window = try XCTUnwrap(listed.first { $0["id"] as? Int == knownID },
                                       "window \(knownID) is gone from \(listed)", file: file, line: line)
            } else {
                window = try XCTUnwrap(
                    listed.first { ($0["width"] as? Double).map { abs($0 - Double(width)) < 0.5 } ?? false },
                    "no window \(width) wide in \(listed)", file: file, line: line)
                webKitWindowIDs[ObjectIdentifier(wc)] = try XCTUnwrap(window["id"] as? Int, file: file, line: line)
            }
            let tabs = try XCTUnwrap(window["tabs"] as? [[String: Any]])
                .sorted { ($0["index"] as? Int ?? -1) < ($1["index"] as? Int ?? -1) }
            let expected = wc.extensionTabs
            // WebKit reports no tabs at all for a window whose active tab is
            // not among them (`WebExtensionWindow::tabs`), so a fixture window
            // with tabs needs one selected.
            if !expected.isEmpty {
                XCTAssertNotNil(wc.extensionActiveTab, "fixture: select a tab in every window that has tabs",
                                file: file, line: line)
            }
            XCTAssertEqual(tabs.count, expected.count,
                           "WebKit and the window must list the same tabs: \(tabs)", file: file, line: line)
            for (entry, tab) in zip(tabs, expected) {
                let id = try XCTUnwrap(entry["id"] as? Int)
                XCTAssertEqual(entry["pinned"] as? Bool, TabStore.shared.isPinned(tab),
                               "the ground truth itself is off: \(entry)", file: file, line: line)
                XCTAssertEqual(entry["hasURL"] as? Bool, false,
                               "the fixture must hold no tabs permission or host access", file: file, line: line)
                if let known = ids[ObjectIdentifier(tab)] {
                    XCTAssertEqual(known, id, "one tab, two ids", file: file, line: line)
                }
                ids[ObjectIdentifier(tab)] = id
            }
        }
        XCTAssertEqual(Set(ids.values).count, ids.count, "two tabs share an id", file: file, line: line)
        return ids
    }

    /// WebKit's id for one listed tab.
    private func tabID(of tab: BrowserTab, _ via: Via, in world: World,
                       file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
        let ids = try await tabIDs(via, in: world, file: file, line: line)
        return try XCTUnwrap(ids[ObjectIdentifier(tab)], "the tab has no id", file: file, line: line)
    }

    /// Resolves `tabID` and checks that the handle it gets names `tab` — by
    /// the native lookup and by what `tabs.describeHandle` reports. Returns
    /// the handle.
    @discardableResult
    private func assertResolves(_ via: Via, in world: World, tabID: Int, to tab: BrowserTab,
                                placement: ExtensionTabPlacement.Kind, selected: Bool? = nil,
                                fresh: Bool = true, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
        let reply = try await runDict(via, in: world, ["op": "resolve", "tabId": tabID, "fresh": fresh])
        let handle = try XCTUnwrap(reply["handle"] as? Int, "\(what) [\(via)]: \(reply)", file: file, line: line)
        XCTAssertGreaterThan(handle, 0, file: file, line: line)
        XCTAssertEqual(handle, ExtensionTabHandleRegistry.shared.handle(for: tab),
                       "\(what) [\(via)]: not this tab's handle", file: file, line: line)

        switch ExtensionTabHandleRegistry.shared.tab(forHandle: handle, in: world.profile) {
        case .success(let found):
            XCTAssertTrue(found.tab === tab, "\(what) [\(via)]: the handler would get another tab", file: file, line: line)
            XCTAssertEqual(found.placement.kind, placement, "\(what) [\(via)]", file: file, line: line)
        case .failure(let error):
            XCTFail("\(what) [\(via)]: the native lookup refused the handle: \(error)", file: file, line: line)
        }

        let described = try XCTUnwrap(reply["described"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(described["tabUUID"] as? String, tab.id.uuidString, "\(what) [\(via)]", file: file, line: line)
        XCTAssertEqual(described["placement"] as? String, placement.rawValue, "\(what) [\(via)]", file: file, line: line)
        if let selected {
            XCTAssertEqual(described["selected"] as? Bool, selected, "\(what) [\(via)]", file: file, line: line)
        }
        return handle
    }

    // MARK: - AC #1: every placement, from both transports

    func testResolvesNormalPinnedFavouritePeekAndUnselectedTabsInWindowsThatAreNotKey() async throws {
        let world = try await makeWorld(try await makeExtension(), name: "Resolve Placements")
        let store = TabStore.shared

        let a1 = addTab("a1", in: world.spaceA)
        let a2 = addTab("a2", in: world.spaceA)
        let pinned = addTab("pinned", in: world.spaceA)
        let favorite = addTab("favorite", in: world.spaceA)
        let b1 = addTab("b1", in: world.spaceB)
        let b2 = addTab("b2", in: world.spaceB)
        try await waitUntil("the tabs to have their URLs") {
            [a1, a2, pinned, favorite, b1, b2].allSatisfy { $0.url != nil }
        }
        store.pinTab(id: pinned.id, in: world.spaceA)
        XCTAssertTrue(store.moveTabToFavorites(id: favorite.id, from: world.spaceA, profileID: world.profile.id))
        world.windowA.selectTab(id: a1.id)
        world.windowA.showPeekOverlay(url: url("peek"))
        let peek = try XCTUnwrap(a1.peekTab, "the Peek should be up on a1")
        world.windowB.selectTab(id: b1.id)

        // Preconditions the acceptance criteria name.
        XCTAssertFalse(world.windowA.window?.isKeyWindow ?? true, "window A must not be key")
        XCTAssertFalse(world.windowB.window?.isKeyWindow ?? true, "window B must not be key")
        XCTAssertEqual(world.windowA.selectedTabID, a1.id)
        XCTAssertEqual(world.windowB.selectedTabID, b1.id)
        XCTAssertTrue(world.windowA.extensionActiveTab === peek)
        XCTAssertEqual(extensionTabPlacement(of: pinned, in: store)?.kind, .pinned)
        XCTAssertEqual(extensionTabPlacement(of: favorite, in: store)?.kind, .favorite)
        XCTAssertEqual(extensionTabPlacement(of: peek, in: store)?.kind, .peek)

        let cases: [(BrowserTab, ExtensionTabPlacement.Kind, Bool, String)] = [
            (a1, .normal, true, "the selected tab behind the Peek"),
            (a2, .normal, false, "an unselected tab"),
            (pinned, .pinned, false, "a pinned tab"),
            (favorite, .favorite, false, "a favourite's backing tab"),
            (peek, .peek, true, "a presented Peek"),
            (b1, .normal, true, "the selected tab of the other window"),
            (b2, .normal, false, "an unselected tab of the other window"),
        ]

        // The reverse lookup with nothing cached yet: the page has resolved no
        // tab, so finding a2 has to walk tabs.query.
        let pageIDs = try await tabIDs(.page, in: world)
        let a2Handle = ExtensionTabHandleRegistry.shared.handle(for: a2)
        let cachedBefore = try await runDict(.page, in: world, ["op": "tabIdForHandle", "handle": a2Handle])
        XCTAssertTrue(cachedBefore["tabId"] is NSNull, "nothing was resolved yet: \(cachedBefore)")
        let found = try await runDict(.page, in: world, ["op": "findTabIdForHandle", "handle": a2Handle])
        XCTAssertEqual(found["tabId"] as? Int, try XCTUnwrap(pageIDs[ObjectIdentifier(a2)]),
                       "the reverse walk must find the tab id of a handle")
        let notFound = try await runDict(.page, in: world, ["op": "findTabIdForHandle", "handle": 987_654_321])
        XCTAssertTrue(notFound["tabId"] is NSNull, "an unknown handle has no tab id: \(notFound)")

        var handlesByVia: [Via: [Int]] = [:]
        for via in Via.allCases {
            let install = try await runDict(via, in: world, ["op": "install"])
            XCTAssertEqual(install["install"] as? String, "polyfill", "[\(via)] \(install)")
            XCTAssertEqual(install["contextKind"] as? String, via == .worker ? "worker" : "page", "[\(via)] \(install)")
            XCTAssertEqual(install["wrapped"] as? Bool, true, "[\(via)] \(install)")
            XCTAssertEqual(install["nativeKept"] as? String, "native", "[\(via)] \(install)")
            XCTAssertEqual(install["held"] as? Bool, true, "the tabs wrapper must be rooted: [\(via)] \(install)")
            XCTAssertEqual(install["browserWrapped"] as? Bool, true,
                           "browser.tabs.getZoom must be wrapped too: [\(via)] \(install)")
            XCTAssertEqual((install["defined"] as? [String])?.count, 4, "[\(via)] \(install)")
            XCTAssertEqual(install["enumerable"] as? [String], [],
                           "the helpers must not be enumerable globals: [\(via)] \(install)")

            let ids = try await tabIDs(via, in: world)
            XCTAssertEqual(ids.count, cases.count, "every fixture tab should have an id")
            var handles: [Int] = []
            for (tab, placement, selected, what) in cases {
                let tabID = try XCTUnwrap(ids[ObjectIdentifier(tab)], "no id for \(what)")
                let handle = try await assertResolves(via, in: world, tabID: tabID, to: tab,
                                                      placement: placement, selected: selected, what)
                handles.append(handle)
                // Cached now, in both directions.
                let cached = try await runDict(via, in: world, ["op": "tabIdForHandle", "handle": handle])
                XCTAssertEqual(cached["tabId"] as? Int, tabID, "[\(via)] \(what)")
                try await assertResolves(via, in: world, tabID: tabID, to: tab, placement: placement,
                                         fresh: false, "\(what), from the cache")
            }
            XCTAssertEqual(Set(handles).count, cases.count, "[\(via)] every tab has its own handle")
            handlesByVia[via] = handles
        }
        XCTAssertEqual(handlesByVia[.page], handlesByVia[.worker],
                       "a tab has one handle, whichever context asks")
        XCTAssertEqual(ExtensionTabHandleRegistry.shared.armCount(world.key), 0, "no arm is left behind")
    }

    // MARK: - AC #2: refusals

    func testAClosedTabIsRefusedAndNeverResolvesToAnotherTab() async throws {
        let world = try await makeWorld(try await makeExtension(), name: "Resolve Closed")
        let store = TabStore.shared
        let registry = ExtensionTabHandleRegistry.shared

        for via in Via.allCases {
            let kept = addTab("a1", in: world.spaceA)
            let doomed = addTab("a2", in: world.spaceA)
            world.windowA.selectTab(id: kept.id)
            let ids = try await tabIDs(via, in: world)
            let keptID = try XCTUnwrap(ids[ObjectIdentifier(kept)])
            let doomedID = try XCTUnwrap(ids[ObjectIdentifier(doomed)])
            let keptHandle = try await assertResolves(via, in: world, tabID: keptID, to: kept,
                                                      placement: .normal, "the tab that stays")
            let doomedHandle = try await assertResolves(via, in: world, tabID: doomedID, to: doomed,
                                                        placement: .normal, "the tab about to close")

            store.closeTab(id: doomed.id, in: world.spaceA, undoable: false, registersUndo: false)

            // The handle the context still holds is refused at once, whatever
            // its cache says.
            var refusals: [String] = []
            refusals.append(try await assertHandleRefused(via, in: world, doomedHandle, "a closed tab's handle"))
            if case .success(let found) = registry.tab(forHandle: doomedHandle, in: world.profile) {
                XCTFail("[\(via)] a closed tab's handle resolved to \(found.tab.id)")
            }

            // The cache forgets the id once tabs.onRemoved arrives: nothing but
            // that event has touched the entry, and only an uncached resolve
            // reaches WebKit to be rejected.
            try await waitUntil("[\(via)] tabs.onRemoved to drop the cached id") {
                try await self.failure(via, in: world, ["op": "resolve", "tabId": doomedID]) != nil
            }
            let cached = try await runDict(via, in: world, ["op": "tabIdForHandle", "handle": doomedHandle])
            XCTAssertTrue(cached["tabId"] is NSNull, "[\(via)] \(cached)")

            let refused = try await failure(via, in: world, ["op": "resolve", "tabId": doomedID, "fresh": true])
            XCTAssertEqual(refused, "No tab with id: \(doomedID).", "[\(via)] a closed tab's id must be refused")
            XCTAssertEqual(registry.armCount(world.key), 0,
                           "[\(via)] the failed resolve must take its arm back")

            // A tab opened afterwards is a different tab: new id, new handle,
            // and the old ones still name nothing.
            let later = addTab("a3", in: world.spaceA)
            let laterID = try await tabID(of: later, via, in: world)
            XCTAssertNotEqual(laterID, doomedID)
            let laterHandle = try await assertResolves(via, in: world, tabID: laterID, to: later,
                                                       placement: .normal, "a tab opened after the close")
            XCTAssertNotEqual(laterHandle, doomedHandle)
            let stillRefused = try await failure(via, in: world, ["op": "resolve", "tabId": doomedID, "fresh": true])
            XCTAssertNotNil(stillRefused, "[\(via)] the closed tab's id must stay refused")
            try await assertResolves(via, in: world, tabID: keptID, to: kept, placement: .normal,
                                     "the tab that stayed, after the close")
            XCTAssertEqual(registry.handle(for: kept), keptHandle)

            // An id WebKit never issued, and things that are not ids.
            let unknown = try await failure(via, in: world, ["op": "resolve", "tabId": 999_999_999])
            XCTAssertEqual(unknown, "No tab with id: 999999999.", "[\(via)]")
            let asString = try await failure(via, in: world, ["op": "resolve", "tabId": "\(keptID)"])
            XCTAssertNotNil(asString, "[\(via)] a string is not a tab id")
            let asFraction = try await failure(via, in: world, ["op": "resolve", "tabId": Double(keptID) + 0.5])
            XCTAssertNotNil(asFraction, "[\(via)] a fraction is not a tab id")

            // Handles that were never handed out.
            for bad in [0, -keptHandle, 987_654_321, 1.5, "\(keptHandle)", true] as [Any] {
                refusals.append(try await assertHandleRefused(via, in: world, bad, "handle \(bad)"))
            }
            XCTAssertEqual(Set(refusals).count, 1,
                           "[\(via)] every refusal must read the same to the extension: \(Set(refusals))")
            XCTAssertEqual(registry.armCount(world.key), 0, "[\(via)] no arm is left behind")
        }
    }

    /// `tabs.describeHandle` must fail for `handle`. Returns the text the
    /// context saw (WebKit wraps a native-message failure in its own sentence,
    /// so the worker's reads differently from the page's).
    private func assertHandleRefused(_ via: Via, in world: World, _ handle: Any, _ what: String,
                                     file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let text = try await failure(via, in: world, ["op": "describe", "handle": handle])
        XCTAssertTrue(text?.contains("no tab for this handle") == true,
                      "[\(via)] \(what) must be refused, got \(String(describing: text))", file: file, line: line)
        return text ?? ""
    }

    func testATabOfAnotherProfileIsRefused() async throws {
        let ext = try await makeExtension()
        let mine = try await makeWorld(ext, name: "Resolve Mine")
        let theirs = try await makeWorld(ext, name: "Resolve Theirs")
        let registry = ExtensionTabHandleRegistry.shared

        let myTab = addTab("a1", in: mine.spaceA)
        let theirTab = addTab("other", in: theirs.spaceA)
        mine.windowA.selectTab(id: myTab.id)
        theirs.windowA.selectTab(id: theirTab.id)

        for via in Via.allCases {
            let myID = try await tabID(of: myTab, via, in: mine)
            let theirID = try await tabID(of: theirTab, via, in: theirs)
            XCTAssertNotEqual(myID, theirID)
            let myHandle = try await assertResolves(via, in: mine, tabID: myID, to: myTab,
                                                    placement: .normal, "my tab, in my profile")
            let theirHandle = try await assertResolves(via, in: theirs, tabID: theirID, to: theirTab,
                                                       placement: .normal, "their tab, in their profile")
            XCTAssertNotEqual(myHandle, theirHandle)

            // The other profile's tab id means nothing in this profile's context.
            let crossed = try await failure(via, in: mine, ["op": "resolve", "tabId": theirID, "fresh": true])
            XCTAssertEqual(crossed, "No tab with id: \(theirID).", "[\(via)]")
            let crossedBack = try await failure(via, in: theirs, ["op": "resolve", "tabId": myID, "fresh": true])
            XCTAssertEqual(crossedBack, "No tab with id: \(myID).", "[\(via)]")

            // Nor does its handle, however the context came by the integer.
            _ = try await assertHandleRefused(via, in: mine, theirHandle, "another profile's handle")
            guard case .failure(let error) = registry.tab(forHandle: theirHandle, in: mine.profile) else {
                return XCTFail("[\(via)] another profile's handle was accepted")
            }
            XCTAssertEqual(error, .otherProfile)

            XCTAssertEqual(registry.armCount(mine.key), 0, "[\(via)] no arm is left behind")
            XCTAssertEqual(registry.armCount(theirs.key), 0, "[\(via)] no arm is left behind")
        }

        // Arms are per profile: one set for this profile's context does not
        // turn the other profile's getZoom into a handle.
        let theirID = try await tabID(of: theirTab, .page, in: theirs)
        XCTAssertTrue(registry.arm(mine.key))
        let zoom = try await runDict(.page, in: theirs, ["op": "nativeGetZoom", "tabId": theirID])
        XCTAssertEqual(zoom["zoom"] as? Double, 1, "the other profile's arm must not be consumed: \(zoom)")
        XCTAssertEqual(registry.armCount(mine.key), 1)
        XCTAssertTrue(registry.disarm(mine.key))
    }

    // MARK: - AC #3: reorder, move between spaces, space switch

    func testResolutionSurvivesReorderSpaceMoveAndSpaceSwitch() async throws {
        let world = try await makeWorld(try await makeExtension(), name: "Resolve Moves")
        let store = TabStore.shared

        let tabs = ["a1", "a2", "a3"].map { addTab($0, in: world.spaceA) }
        let resident = addTab("b1", in: world.spaceB)
        try await waitUntil("the tabs to have their URLs") { (tabs + [resident]).allSatisfy { $0.url != nil } }
        world.windowA.selectTab(id: tabs[0].id)
        world.windowB.selectTab(id: resident.id)

        var idsByVia: [Via: [Int]] = [:]
        var handles: [Int] = []
        for via in Via.allCases {
            let ids = try await tabIDs(via, in: world)
            idsByVia[via] = try tabs.map { try XCTUnwrap(ids[ObjectIdentifier($0)]) }
            handles = []
            for (tab, tabID) in zip(tabs, idsByVia[via]!) {
                handles.append(try await assertResolves(via, in: world, tabID: tabID, to: tab,
                                                        placement: .normal, "before anything moved"))
            }
        }

        /// Both the cached answer and a fresh round trip, from both contexts,
        /// for the ids taken before anything moved.
        func assertAllStillResolve(_ step: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            for via in Via.allCases {
                for (index, tab) in tabs.enumerated() {
                    let tabID = idsByVia[via]![index]
                    for fresh in [false, true] {
                        let handle = try await assertResolves(
                            via, in: world, tabID: tabID, to: tab, placement: .normal, fresh: fresh,
                            "\(step) (\(fresh ? "fresh" : "cached"))", file: file, line: line)
                        XCTAssertEqual(handle, handles[index], "\(step) [\(via)]: the handle changed",
                                       file: file, line: line)
                    }
                }
            }
        }

        // Reordered: the first tab goes last.
        store.moveTab(from: 0, to: 2, in: world.spaceA)
        XCTAssertNotEqual(world.spaceA.tabs.map(\.id), tabs.map(\.id), "precondition: the order changed")
        try await assertAllStillResolve("after a reorder")

        // Moved to the space the other window shows.
        XCTAssertTrue(store.moveTab(id: tabs[1].id, from: world.spaceA, to: world.spaceB))
        XCTAssertTrue(world.spaceB.tabs.contains { $0 === tabs[1] }, "precondition: the tab moved")
        try await assertAllStillResolve("after a move to another space")
        guard case .success(let moved) = ExtensionTabHandleRegistry.shared.tab(forHandle: handles[1], in: world.profile) else {
            return XCTFail("the moved tab's handle was refused")
        }
        XCTAssertEqual(moved.placement.spaceID, world.spaceB.id)

        // The window switches space between two calls: space A is now shown by
        // no window at all, so its tabs are in no window's list.
        world.windowA.setActiveSpace(id: world.spaceB.id)
        XCTAssertEqual(world.windowA.activeSpaceID, world.spaceB.id)
        XCTAssertFalse(world.windowA.extensionTabs.contains { $0 === tabs[0] })
        try await assertAllStillResolve("after the window switched space")

        // And back.
        world.windowA.setActiveSpace(id: world.spaceA.id)
        try await assertAllStillResolve("after the window switched back")

        // The ids themselves did not change either, where WebKit still lists them.
        for via in Via.allCases {
            let ids = try await tabIDs(via, in: world)
            XCTAssertEqual(try tabs.map { try XCTUnwrap(ids[ObjectIdentifier($0)]) }, idsByVia[via])
        }
        XCTAssertEqual(ExtensionTabHandleRegistry.shared.armCount(world.key), 0, "no arm is left behind")
    }

    // MARK: - A genuine tabs.getZoom

    func testAGenuineGetZoomReturnsTheRealZoomEvenWhenItConsumesAnArm() async throws {
        let world = try await makeWorld(try await makeExtension(), name: "Resolve Zoom")
        let registry = ExtensionTabHandleRegistry.shared

        let zoomed = addTab("a1", in: world.spaceA)
        let plain = addTab("a2", in: world.spaceA)
        let third = addTab("a3", in: world.spaceA)
        world.windowA.selectTab(id: plain.id)
        try XCTUnwrap(zoomed.webView).pageZoom = 1.25
        try XCTUnwrap(third.webView).pageZoom = 0.75
        let zooms: [ObjectIdentifier: Double] =
            [ObjectIdentifier(zoomed): 1.25, ObjectIdentifier(plain): 1, ObjectIdentifier(third): 0.75]

        for via in Via.allCases {
            let ids = try await tabIDs(via, in: world)
            let zoomedID = try XCTUnwrap(ids[ObjectIdentifier(zoomed)])
            let plainID = try XCTUnwrap(ids[ObjectIdentifier(plain)])
            let thirdID = try XCTUnwrap(ids[ObjectIdentifier(third)])

            // Nothing armed: the ordinary answer, in both call forms.
            let ordinary = try await runDict(via, in: world, ["op": "getZoom", "tabId": zoomedID])
            XCTAssertEqual(try XCTUnwrap(ordinary["zoom"] as? Double), 1.25, accuracy: 0.0001, "[\(via)]")
            let ordinaryCallback = try await runDict(via, in: world, ["op": "getZoomCallback", "tabId": plainID])
            XCTAssertEqual(ordinaryCallback["zoom"] as? Double, 1, "[\(via)] \(ordinaryCallback)")
            XCTAssertEqual(ordinaryCallback["argc"] as? Int, 1, "[\(via)] \(ordinaryCallback)")
            XCTAssertTrue(ordinaryCallback["lastError"] is NSNull, "[\(via)] \(ordinaryCallback)")
            XCTAssertEqual(ordinaryCallback["returnedType"] as? String, "undefined",
                           "[\(via)] the callback form returns nothing: \(ordinaryCallback)")

            // The mechanism itself: with an arm set, WebKit's own function is
            // answered with the negated handle of the tab that was asked.
            XCTAssertTrue(registry.arm(world.key))
            let raw = try await runDict(via, in: world, ["op": "nativeGetZoom", "tabId": zoomedID])
            XCTAssertEqual(raw["zoom"] as? Double, -Double(registry.handle(for: zoomed)),
                           "[\(via)] WebKit must pass the tab's answer through unclamped: \(raw)")
            XCTAssertEqual(registry.armCount(world.key), 0, "[\(via)] the arm answers one getZoom")
            let rawAfter = try await runDict(via, in: world, ["op": "nativeGetZoom", "tabId": zoomedID])
            XCTAssertEqual(try XCTUnwrap(rawAfter["zoom"] as? Double), 1.25, accuracy: 0.0001,
                           "[\(via)] and only one")

            // A genuine call that consumes an arm still reports the zoom.
            XCTAssertTrue(registry.arm(world.key))
            let stolen = try await runDict(via, in: world, ["op": "getZoom", "tabId": zoomedID])
            XCTAssertEqual(try XCTUnwrap(stolen["zoom"] as? Double), 1.25, accuracy: 0.0001,
                           "[\(via)] the extension must never see a handle as a zoom")
            XCTAssertEqual(registry.armCount(world.key), 0, "[\(via)] precondition: the call did consume the arm")

            XCTAssertTrue(registry.arm(world.key))
            let stolenCallback = try await runDict(via, in: world, ["op": "getZoomCallback", "tabId": thirdID])
            XCTAssertEqual(try XCTUnwrap(stolenCallback["zoom"] as? Double), 0.75, accuracy: 0.0001,
                           "[\(via)] \(stolenCallback)")
            XCTAssertEqual(stolenCallback["argc"] as? Int, 1, "[\(via)] \(stolenCallback)")
            XCTAssertTrue(stolenCallback["lastError"] is NSNull, "[\(via)] \(stolenCallback)")
            XCTAssertEqual(registry.armCount(world.key), 0, "[\(via)] precondition: the call did consume the arm")

            // WebKit's own failure still comes through both forms.
            let rejected = try await failure(via, in: world, ["op": "getZoom", "tabId": 999_999_999])
            XCTAssertTrue(rejected?.contains("tabs.getZoom()") == true, "[\(via)] \(String(describing: rejected))")
            let failedCallback = try await runDict(via, in: world, ["op": "getZoomCallback", "tabId": 999_999_999])
            XCTAssertEqual(failedCallback["argc"] as? Int, 0, "[\(via)] \(failedCallback)")
            XCTAssertTrue((failedCallback["lastError"] as? String)?.contains("tabs.getZoom()") == true,
                          "[\(via)] runtime.lastError must be WebKit's: \(failedCallback)")
        }

        // Resolves and genuine calls in flight together, in the page and the
        // worker at once — the two contexts share the extension's arms.
        let ids = try await tabIDs(.page, in: world)
        let tabIDsToStorm = try [zoomed, plain, third].map { try XCTUnwrap(ids[ObjectIdentifier($0)]) }
        let tabByID = Dictionary(uniqueKeysWithValues: zip(tabIDsToStorm, [zoomed, plain, third]))
        let storm: [String: Any] = ["op": "storm", "tabIds": tabIDsToStorm, "rounds": 4]
        async let pageStorm = run(.page, in: world, storm)
        async let workerStorm = run(.worker, in: world, storm)
        let results = try await [("page", pageStorm), ("worker", workerStorm)]
        for (name, result) in results {
            let entries = try XCTUnwrap(result as? [[String: Any]])
            XCTAssertEqual(entries.count, 4 * 3 * 3, "[\(name)]")
            for entry in entries {
                let tab = try XCTUnwrap(tabByID[try XCTUnwrap(entry["id"] as? Int)])
                switch entry["kind"] as? String {
                case "handle":
                    XCTAssertEqual(entry["value"] as? Int, registry.handle(for: tab),
                                   "[\(name)] a resolve in the storm got another tab's handle: \(entry)")
                case "zoom":
                    let zoom = try XCTUnwrap(entry["value"] as? Double, "[\(name)] \(entry)")
                    XCTAssertEqual(zoom, try XCTUnwrap(zooms[ObjectIdentifier(tab)]), accuracy: 0.0001,
                                   "[\(name)] a genuine getZoom in the storm was not answered with the zoom: \(entry)")
                default:
                    XCTFail("[\(name)] unexpected storm entry \(entry)")
                }
            }
        }
        XCTAssertEqual(registry.armCount(world.key), 0, "no arm is left behind")
    }
}
