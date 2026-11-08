import XCTest
import WebKit
@testable import Detour

/// TASK-132.12: `chrome.tabGroups`, `tabs.group` / `tabs.ungroup` and a tab's
/// `groupId`, called from a real extension's service worker and from one of
/// its pages, against `TabStore.shared` (the model is TASK-132.10's).
nonisolated final class ExtensionTabGroupsTests: XCTestCase {

    private typealias Via = SidePanelTestWorld.Via
    private var world: SidePanelTestWorld!

    @MainActor override func setUp() async throws {
        try await super.setUp()
        world = SidePanelTestWorld(opJS: TabGroupsFixture.opJS, workerJS: TabGroupsFixture.workerJS)
        try await world.setUp()
    }

    @MainActor override func tearDown() async throws {
        await world.tearDown()
        world = nil
        try await super.tearDown()
    }

    /// One profile, one space, one window, four tabs (the first selected),
    /// the extension loaded.
    @MainActor private struct Scene {
        let loaded: SidePanelTestWorld.Loaded
        let space: Space
        let window: BrowserWindowController
        let tabs: [BrowserTab]
        var profile: Profile { loaded.profile }
    }

    /// `beforeLoad` runs once the scene's window is open and before the
    /// extension loads, so a window it opens is one WebKit is told about.
    @MainActor private func makeScene(_ name: String, permissions: [String] = ["tabGroups", "tabs"],
                                      beforeLoad: (Profile) -> Void = { _ in }) async throws -> Scene {
        let ext = try await world.makeExtension(name: "Tab Groups Test", permissions: permissions, defaultPath: nil)
        let profile = world.makeProfile(name)
        let space = world.makeSpace(name, in: profile)
        let window = world.makeWindow(on: space)
        beforeLoad(profile)
        var tabs: [BrowserTab] = []
        for page in ["one", "two", "three", "four"] { tabs.append(try await world.addTab(page, in: space)) }
        window.selectTab(id: tabs[0].id)
        let loaded = try await world.load(ext, in: profile)
        // Tabs open newest first: put them in page order so indices read naturally.
        for tab in tabs {
            TabStore.shared.moveTab(id: tab.id, toGapIndex: space.tabs.count, in: space)
        }
        return Scene(loaded: loaded, space: space, window: window, tabs: space.tabs)
    }

    @MainActor private func ids(_ tabs: [BrowserTab], _ via: Via, in scene: Scene) async throws -> [Int] {
        var ids: [Int] = []
        for tab in tabs { ids.append(try await world.tabID(of: tab, via, in: scene.loaded)) }
        return ids
    }

    @MainActor private func call(_ via: Via, _ scene: Scene, _ ns: String, _ method: String, _ args: [Any]) async throws -> Any {
        try await world.run(via, in: scene.loaded, ["op": "call", "ns": ns, "method": method, "args": args])
    }

    @MainActor private func callback(_ via: Via, _ scene: Scene, _ ns: String, _ method: String,
                          _ args: [Any]) async throws -> [String: Any] {
        try await world.runDict(via, in: scene.loaded, ["op": "callback", "ns": ns, "method": method, "args": args])
    }

    @MainActor private func failure(_ via: Via, _ scene: Scene, _ ns: String, _ method: String, _ args: [Any]) async throws -> String? {
        try await world.failure(via, in: scene.loaded, ["op": "call", "ns": ns, "method": method, "args": args])
    }

    // MARK: - The API exists only with the permission (AC #6)

    @MainActor func testTheNamespaceAndTabsGroupExistWithThePermission() async throws {
        let scene = try await makeScene("Groups Namespace")
        for via in Via.allCases {
            let state = try await world.runDict(via, in: scene.loaded, ["op": "install"])
            XCTAssertEqual(state["tabGroupsType"] as? String, "object", "[\(via)]")
            XCTAssertEqual(state["install"] as? String, "polyfill", "[\(via)]")
            XCTAssertEqual(state["keys"] as? [String],
                           ["Color", "TAB_GROUP_ID_NONE", "get", "move", "onCreated", "onMoved", "onRemoved", "onUpdated",
                            "query", "update"], "[\(via)]")
            XCTAssertEqual(state["noneConstant"] as? Int, -1, "[\(via)]")
            XCTAssertEqual(state["viaBrowser"] as? Bool, true, "[\(via)] browser.tabGroups must be the same object")
            XCTAssertEqual(state["groupType"] as? String, "function", "[\(via)]")
            XCTAssertEqual(state["ungroupType"] as? String, "function", "[\(via)]")
            XCTAssertEqual(state["decorated"] as? Bool, true, "[\(via)] tabs.query results carry groupId")
            XCTAssertFalse((state["tabsPatch"] as? String ?? "").contains("not-visible"), "[\(via)] \(state["tabsPatch"] ?? "")")
        }
    }

    /// A second run of the polyfill in the same realm keeps the first run's
    /// namespace, `tabs` wrappers and listener registries: rebuilding them
    /// would split the registries and start a second park loop that
    /// supersedes the first.
    @MainActor func testASecondPolyfillRunKeepsTheFirstRunsObjects() async throws {
        let scene = try await makeScene("Groups Second Run")
        let raw = try await scene.loaded.page.callAsyncJavaScript("""
            const tabGroups = chrome.tabGroups, group = chrome.tabs.group, query = chrome.tabs.query;
            const listener = function() {};
            chrome.tabs.onUpdated.addListener(listener);
            \(ExtensionAPIPolyfill.polyfillJS)
            const out = {
                sameNamespace: chrome.tabGroups === tabGroups,
                sameGroup: chrome.tabs.group === group,
                sameQuery: chrome.tabs.query === query,
                listenerKept: chrome.tabs.onUpdated.hasListener(listener),
                install: globalThis.__detourTabGroupsInstall
            };
            chrome.tabs.onUpdated.removeListener(listener);
            return JSON.stringify(out);
            """, contentWorld: .page)
        let json = try XCTUnwrap(raw as? String)
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(result["sameNamespace"] as? Bool, true)
        XCTAssertEqual(result["sameGroup"] as? Bool, true)
        XCTAssertEqual(result["sameQuery"] as? Bool, true)
        XCTAssertEqual(result["listenerKept"] as? Bool, true)
        XCTAssertEqual(result["install"] as? String, "polyfill")
    }

    /// NEGATIVE: no tabGroups permission, no namespace and no groupId; tabs.group
    /// still exists (Chrome gates it on nothing), and the bridge refuses the
    /// tabGroups calls a page could make directly.
    @MainActor func testWithoutThePermissionThereIsNoNamespaceAndTheBridgeRefuses() async throws {
        let scene = try await makeScene("Groups No Permission", permissions: ["tabs"])
        for via in Via.allCases {
            let state = try await world.runDict(via, in: scene.loaded, ["op": "install"])
            XCTAssertEqual(state["tabGroupsType"] as? String, "undefined", "[\(via)]")
            XCTAssertEqual(state["install"] as? String, "absent", "[\(via)]")
            XCTAssertEqual(state["groupType"] as? String, "function", "[\(via)]")
            XCTAssertEqual(state["decorated"] as? Bool, false, "[\(via)] no groupId without the permission")
        }
        for type in ["tabGroups.get", "tabGroups.query", "tabGroups.update", "tabGroups.move"] {
            let reply = try await postRawPolyfillEnvelope(from: scene.loaded.page, type: type,
                                                          claimedID: scene.loaded.ext.id, params: ["groupId": 1])
            XCTAssertEqual(reply.error, ExtensionPolyfillHandler.tabGroupsPermissionRefusal, type)
        }
        // tabs.group works without it.
        let tabIDs = try await ids(Array(scene.tabs.prefix(2)), .worker, in: scene)
        let groupID = try await call(.worker, scene, "tabs", "group", [["tabIds": tabIDs]])
        XCTAssertNotNil(groupID as? Int)
        XCTAssertEqual(scene.space.tabGroups.count, 1)
    }

    @MainActor func testADenialInTheContextRefusesTheNamespaceAndAGrantRestoresIt() async throws {
        let scene = try await makeScene("Groups Denied")
        let permission = WKWebExtension.Permission(rawValue: "tabGroups")
        scene.loaded.context.setPermissionStatus(.deniedExplicitly, for: permission)
        let denied = try await failure(.page, scene, "tabGroups", "query", [[:]])
        XCTAssertEqual(denied, "tabGroups permission denied by the user")
        scene.loaded.context.setPermissionStatus(.grantedExplicitly, for: permission)
        let awaited1 = try await failure(.page, scene, "tabGroups", "query", [[:]])
        XCTAssertNil(awaited1)
    }

    // MARK: - tabs.group / tabs.ungroup (AC #1)

    @MainActor func testGroupingCreatesAndAddsAndUngroupingRemovesFromBothTransports() async throws {
        let scene = try await makeScene("Groups Group")
        for via in Via.allCases {
            let tabIDs = try await ids(scene.tabs, via, in: scene)
            let awaited2 = try await call(via, scene, "tabs", "group", [["tabIds": [tabIDs[0], tabIDs[1]]]]) as? Int
            let groupID = try XCTUnwrap(awaited2,
                                        "[\(via)]")
            let group = try XCTUnwrap(scene.space.tabGroups.last, "[\(via)]")
            XCTAssertEqual(ExtensionTabGroupIDs.shared.id(for: group.id), groupID, "[\(via)]")
            XCTAssertEqual(scene.space.members(ofTabGroup: group.id).map(\.id), [scene.tabs[0].id, scene.tabs[1].id], "[\(via)]")

            // A single id, into the existing group, callback form.
            let added = try await callback(via, scene, "tabs", "group", [["tabIds": tabIDs[3], "groupId": groupID]])
            XCTAssertNil(added["lastError"] as? String, "[\(via)]")
            XCTAssertEqual(added["arg0"] as? Int, groupID, "[\(via)]")
            XCTAssertEqual(Set(scene.space.members(ofTabGroup: group.id).map(\.id)),
                           Set([scene.tabs[0].id, scene.tabs[1].id, scene.tabs[3].id]), "[\(via)]")

            let awaited3 = try await call(via, scene, "tabs", "get", [tabIDs[3]]) as? [String: Any]
            let got = try XCTUnwrap(awaited3)
            XCTAssertEqual(got["groupId"] as? Int, groupID, "[\(via)] tabs.get carries groupId")

            _ = try await call(via, scene, "tabs", "ungroup", [[tabIDs[0], tabIDs[1], tabIDs[3]]])
            XCTAssertTrue(scene.space.tabGroups.isEmpty, "[\(via)] the emptied group is removed")
            let awaited4 = try await call(via, scene, "tabs", "get", [tabIDs[3]]) as? [String: Any]
            let after = try XCTUnwrap(awaited4)
            XCTAssertEqual(after["groupId"] as? Int, -1, "[\(via)]")
        }
    }

    @MainActor func testGroupErrorsFromBothTransportsChangeNothing() async throws {
        let scene = try await makeScene("Groups Errors")
        let pinned = scene.tabs[3]
        for via in Via.allCases {
            let tabIDs = try await ids(scene.tabs, via, in: scene)
            let awaited5 = try await failure(via, scene, "tabs", "group", [["tabIds": 987_654]])
            XCTAssertEqual(awaited5,
                           "No tab with id: 987654.", "[\(via)]")
            let awaited6 = try await failure(via, scene, "tabs", "group", [["tabIds": [tabIDs[0]], "groupId": 424_242]])
            XCTAssertEqual(awaited6,
                           "No group with id: 424242.", "[\(via)]")
            let awaited7 = try await failure(via, scene, "tabs", "group",
                                             [["tabIds": [tabIDs[0]], "groupId": 1, "createProperties": [:]]])
            XCTAssertEqual(awaited7,
                           "Cannot specify 'createProperties' along with a 'groupId'.", "[\(via)]")
            let awaited8 = try await failure(via, scene, "tabs", "group", [["tabIds": []]])
            XCTAssertNotNil(awaited8, "[\(via)]")
            let awaited9 = try await failure(via, scene, "tabs", "group", [["tabIds": "1"]])
            XCTAssertNotNil(awaited9, "[\(via)]")
            // Callback form: runtime.lastError, no argument.
            let viaCallback = try await callback(via, scene, "tabs", "group", [["tabIds": 987_654]])
            XCTAssertEqual(viaCallback["lastError"] as? String, "No tab with id: 987654.", "[\(via)]")
            XCTAssertEqual(viaCallback["argc"] as? Int, 0, "[\(via)]")
        }
        // A pinned tab (AC #5): refused, and the other tab is not grouped either.
        let pinnedID = try await world.tabID(of: pinned, .page, in: scene.loaded)
        TabStore.shared.pinTab(id: pinned.id, in: scene.space)
        let firstID = try await world.tabID(of: scene.tabs[0], .page, in: scene.loaded)
        for via in Via.allCases {
            let awaited10 = try await failure(via, scene, "tabs", "group", [["tabIds": [firstID, pinnedID]]])
            XCTAssertEqual(awaited10,
                           ExtensionPolyfillHandler.tabGroupNotGroupableError, "[\(via)]")
        }
        XCTAssertTrue(scene.space.tabGroups.isEmpty)
        XCTAssertNil(scene.tabs[0].tabGroupID)
    }

    // MARK: - groupId on Tab objects, tabs.query({groupId}) (AC #2, #3)

    @MainActor func testQueryByGroupReturnsExactlyTheMembersIncludingUnselectedTabs() async throws {
        let scene = try await makeScene("Groups Query")
        let group = try TabStore.shared.createTabGroup(tabIDs: [scene.tabs[1].id, scene.tabs[2].id], in: scene.space)
        let groupID = ExtensionTabGroupIDs.shared.id(for: group.id)
        for via in Via.allCases {
            let windowID = try await world.windowID(listing: scene.tabs[0], via, in: scene.loaded)
            let expected = Set(try await ids([scene.tabs[1], scene.tabs[2]], via, in: scene))
            let awaited11 = try await call(via, scene, "tabs", "query", [["groupId": groupID]]) as? [[String: Any]]
            let members = try XCTUnwrap(awaited11)
            XCTAssertEqual(Set(members.compactMap { $0["id"] as? Int }), expected, "[\(via)]")
            XCTAssertTrue(members.allSatisfy { $0["groupId"] as? Int == groupID }, "[\(via)]")
            let awaited12 = try await call(via, scene, "tabs", "query",
                                                    [["groupId": -1, "windowId": windowID]]) as? [[String: Any]]
            let none = try XCTUnwrap(awaited12)
            XCTAssertEqual(none.count, 2, "[\(via)] the two ungrouped tabs")
            let awaited13 = try await call(via, scene, "tabs", "query", [[:]]) as? [[String: Any]]
            let all = try XCTUnwrap(awaited13)
            XCTAssertTrue(all.allSatisfy { $0["groupId"] is Int }, "[\(via)] every tab has a groupId")
            // Combined with another key, callback form.
            let combined = try await callback(via, scene, "tabs", "query", [["groupId": groupID, "active": true]])
            XCTAssertEqual((combined["arg0"] as? [Any])?.count, 0, "[\(via)] no member is active")
        }
    }

    @MainActor func testCreatedAndUpdatedTabsCarryGroupId() async throws {
        let scene = try await makeScene("Groups Decorate")
        for via in Via.allCases {
            let awaited14 = try await call(via, scene, "tabs", "create", [["url": world.url("one").absoluteString,
                                                                                      "active": false]]) as? [String: Any]
            let created = try XCTUnwrap(awaited14)
            XCTAssertEqual(created["groupId"] as? Int, -1, "[\(via)]")
            let createdID = try XCTUnwrap(created["id"] as? Int)
            let awaited15 = try await call(via, scene, "tabs", "group", [["tabIds": createdID]]) as? Int
            let groupID = try XCTUnwrap(awaited15)
            let awaited16 = try await call(via, scene, "tabs", "update", [createdID, ["url": world.url("two").absoluteString]]) as? [String: Any]
            let updated = try XCTUnwrap(awaited16)
            XCTAssertEqual(updated["groupId"] as? Int, groupID, "[\(via)]")
            _ = try await call(via, scene, "tabs", "remove", [createdID])
        }
    }

    // MARK: - chrome.tabGroups methods (AC #4)

    @MainActor func testGetQueryUpdateAndMoveFromBothTransports() async throws {
        let scene = try await makeScene("Groups Methods")
        for via in Via.allCases {
            let tabIDs = try await ids(scene.tabs, via, in: scene)
            let windowID = try await world.windowID(listing: scene.tabs[0], via, in: scene.loaded)
            let awaited17 = try await call(via, scene, "tabs", "group", [["tabIds": [tabIDs[0], tabIDs[1]]]]) as? Int
            let groupID = try XCTUnwrap(awaited17)

            let awaited18 = try await call(via, scene, "tabGroups", "update",
                                                       [groupID, ["title": "Claude", "color": "orange", "collapsed": true]]) as? [String: Any]
            let updated = try XCTUnwrap(awaited18)
            XCTAssertEqual(updated["title"] as? String, "Claude", "[\(via)]")
            XCTAssertEqual(updated["color"] as? String, "orange", "[\(via)]")
            XCTAssertEqual(updated["collapsed"] as? Bool, true, "[\(via)]")
            let group = try XCTUnwrap(scene.space.tabGroup(id: try XCTUnwrap(ExtensionTabGroupIDs.shared.group(for: groupID))))
            XCTAssertEqual(group.title, "Claude")
            XCTAssertEqual(group.color, .orange)

            let awaited19 = try await call(via, scene, "tabGroups", "get", [groupID]) as? [String: Any]
            let got = try XCTUnwrap(awaited19)
            XCTAssertEqual(got["id"] as? Int, groupID, "[\(via)]")
            XCTAssertEqual(got["windowId"] as? Int, windowID, "[\(via)] windowId comes from a member")
            XCTAssertEqual(got["shared"] as? Bool, false, "[\(via)]")

            for (info, count) in [(["title": "Cl*"], 1), (["title": "Other"], 0), (["color": "orange"], 1),
                                  (["color": "blue"], 0), (["collapsed": true], 1), (["windowId": windowID], 1),
                                  (["title": "Claude", "collapsed": false], 0)] as [([String: Any], Int)] {
                let awaited20 = try await call(via, scene, "tabGroups", "query", [info]) as? [Any]
                let found = try XCTUnwrap(awaited20)
                XCTAssertEqual(found.count, count, "[\(via)] \(info)")
            }

            // To the end of the window, then back to the front.
            let awaited21 = try await call(via, scene, "tabGroups", "move", [groupID, ["index": -1]]) as? [String: Any]
            let moved = try XCTUnwrap(awaited21)
            XCTAssertEqual(moved["id"] as? Int, groupID, "[\(via)]")
            XCTAssertEqual(scene.space.tabs.suffix(2).map(\.tabGroupID), [group.id, group.id], "[\(via)]")
            _ = try await call(via, scene, "tabGroups", "move", [groupID, ["index": 0]])
            XCTAssertEqual(scene.space.tabs.prefix(2).map(\.tabGroupID), [group.id, group.id], "[\(via)]")

            let viaCallback = try await callback(via, scene, "tabGroups", "get", [groupID])
            XCTAssertEqual((viaCallback["arg0"] as? [String: Any])?["title"] as? String, "Claude", "[\(via)]")

            _ = try await call(via, scene, "tabs", "ungroup", [[tabIDs[0], tabIDs[1]]])
        }
    }

    @MainActor func testMethodErrorsFromBothTransports() async throws {
        let scene = try await makeScene("Groups Method Errors")
        let group = try TabStore.shared.createTabGroup(tabIDs: [scene.tabs[0].id], in: scene.space)
        let groupID = ExtensionTabGroupIDs.shared.id(for: group.id)
        for via in Via.allCases {
            let awaited22 = try await failure(via, scene, "tabGroups", "get", [313_131])
            XCTAssertEqual(awaited22, "No group with id: 313131.", "[\(via)]")
            let awaited23 = try await failure(via, scene, "tabGroups", "update", [313_131, ["title": "x"]])
            XCTAssertEqual(awaited23,
                           "No group with id: 313131.", "[\(via)]")
            let awaited24 = try await failure(via, scene, "tabGroups", "update", [groupID, ["color": "magenta"]])
            XCTAssertNotNil(awaited24, "[\(via)]")
            let awaited25 = try await failure(via, scene, "tabGroups", "get", ["1"])
            XCTAssertNotNil(awaited25, "[\(via)]")
            let awaited26 = try await failure(via, scene, "tabGroups", "move", [groupID, [:]])
            XCTAssertNotNil(awaited26, "[\(via)]")
            let viaCallback = try await callback(via, scene, "tabGroups", "get", [313_131])
            XCTAssertEqual(viaCallback["lastError"] as? String, "No group with id: 313131.", "[\(via)]")
            XCTAssertEqual(viaCallback["argc"] as? Int, 0, "[\(via)]")
        }
        XCTAssertEqual(group.color, TabGroupColor.next(after: []), "a refused update changed nothing")
    }

    /// A window with no tab has no group and is never the tabs' or the
    /// group's window: `query` lists nothing for it, and `tabs.group` /
    /// `tabGroups.move` naming it are refused, changing nothing.
    @MainActor func testAWindowWithNoTabIsNeverTheGroupsWindow() async throws {
        let scene = try await makeScene("Groups Empty Window") { profile in
            _ = world.makeWindow(on: world.makeSpace("Groups Empty Window 2", in: profile))
        }
        let group = try TabStore.shared.createTabGroup(tabIDs: [scene.tabs[0].id], in: scene.space)
        let groupID = ExtensionTabGroupIDs.shared.id(for: group.id)
        for via in Via.allCases {
            let awaitedWindows = try await call(via, scene, "windows", "getAll", [["populate": true]]) as? [[String: Any]]
            let windows = try XCTUnwrap(awaitedWindows)
            let empty = try XCTUnwrap(windows.first { ($0["tabs"] as? [Any])?.isEmpty ?? true }?["id"] as? Int,
                                      "[\(via)] the empty window is listed")
            let found = try await call(via, scene, "tabGroups", "query", [["windowId": empty]]) as? [Any]
            XCTAssertEqual(found?.count, 0, "[\(via)]")
            let tabID = try await world.tabID(of: scene.tabs[1], via, in: scene.loaded)
            let grouped = try await failure(via, scene, "tabs", "group",
                                            [["tabIds": tabID, "createProperties": ["windowId": empty]]])
            XCTAssertEqual(grouped, ExtensionPolyfillHandler.tabGroupOtherWindowError, "[\(via)]")
            let moved = try await failure(via, scene, "tabGroups", "move", [groupID, ["index": 0, "windowId": empty]])
            XCTAssertEqual(moved, ExtensionPolyfillHandler.tabGroupMoveOtherWindowError, "[\(via)]")
        }
        XCTAssertNil(scene.tabs[1].tabGroupID, "a refused group changed nothing")
    }

    // MARK: - Isolation (AC #5)

    @MainActor func testAnotherProfilesTabsAndGroupsAreRefused() async throws {
        let scene = try await makeScene("Groups Isolation A")
        let otherProfile = world.makeProfile("Groups Isolation B")
        let otherSpace = world.makeSpace("Groups Isolation B", in: otherProfile)
        let otherTab = try await world.addTab("two", in: otherSpace)
        let otherGroup = try TabStore.shared.createTabGroup(tabIDs: [otherTab.id], in: otherSpace)
        let otherGroupID = ExtensionTabGroupIDs.shared.id(for: otherGroup.id)
        for via in Via.allCases {
            let awaited27 = try await failure(via, scene, "tabGroups", "get", [otherGroupID])
            XCTAssertEqual(awaited27,
                           "No group with id: \(otherGroupID).", "[\(via)]")
            let awaited28 = try await call(via, scene, "tabGroups", "query", [[:]]) as? [Any]
            let found = try XCTUnwrap(awaited28)
            XCTAssertTrue(found.isEmpty, "[\(via)] another profile's group is not listed")
        }
        // A handle of the other profile's tab, sent straight to the bridge.
        let reply = try await postRawPolyfillEnvelope(
            from: scene.loaded.page, type: "tabGroups.group", claimedID: scene.loaded.ext.id,
            params: ["tabHandles": [ExtensionTabHandleRegistry.shared.handle(for: otherTab)]])
        XCTAssertEqual(reply.error, "tabGroups.group: no tab for this handle")
        XCTAssertEqual(otherSpace.members(ofTabGroup: otherGroup.id).map(\.id), [otherTab.id])
    }

    // MARK: - Events (AC #4, tabs.onUpdated groupId)

    @MainActor func testGroupEventsAndGroupIdChangesReachTheWorkerAndAPage() async throws {
        let scene = try await makeScene("Groups Events")
        for via in Via.allCases {
            _ = try await world.run(via, in: scene.loaded, ["op": "listen"])
        }
        // Give both contexts time to park.
        try await waitUntil("both contexts to park") {
            let slots = scene.loaded.profile.polyfillHandler?.tabGroupEvents?.slotsForTesting(scene.loaded.ext.id) ?? [:]
            return slots.count >= 2 && slots.values.allSatisfy(\.parked)
        }

        // As a user would: the store, not the extension.
        let store = TabStore.shared
        let group = try store.createTabGroup(tabIDs: [scene.tabs[1].id, scene.tabs[2].id], title: "Mine", in: scene.space)
        try store.updateTabGroup(group.id, color: .cyan, in: scene.space)
        try store.moveTabGroup(group.id, to: 99, in: scene.space)
        try store.ungroupTabs([scene.tabs[1].id, scene.tabs[2].id], in: scene.space)
        let groupID = ExtensionTabGroupIDs.shared.id(for: group.id)

        for via in Via.allCases {
            let memberIDs = Set(try await ids([scene.tabs[1], scene.tabs[2]], via, in: scene))
            var events: [[String: Any]] = []
            try await waitUntil("[\(via)] the events to arrive", timeout: 15) {
                events = (try? await self.world.run(via, in: scene.loaded, ["op": "events"]) as? [[String: Any]]) ?? []
                return events.contains { $0["event"] as? String == "tabGroups.onRemoved" }
                    && events.filter { $0["event"] as? String == "tabs.onUpdated" && $0["groupId"] as? Int == -1 }.count >= 2
            }
            let kinds = events.compactMap { $0["event"] as? String }.filter { $0.hasPrefix("tabGroups.") }
            XCTAssertEqual(kinds, ["tabGroups.onCreated", "tabGroups.onUpdated", "tabGroups.onMoved", "tabGroups.onRemoved"],
                           "[\(via)]")
            XCTAssertEqual(events.first { $0["event"] as? String == "tabGroups.onCreated" }?["title"] as? String, "Mine", "[\(via)]")
            XCTAssertEqual(events.first { $0["event"] as? String == "tabGroups.onUpdated" }?["color"] as? String, "cyan", "[\(via)]")
            XCTAssertEqual(events.first { $0["event"] as? String == "tabGroups.onCreated" }?["id"] as? Int, groupID, "[\(via)]")
            let joined = events.filter { $0["event"] as? String == "tabs.onUpdated" && $0["groupId"] as? Int == groupID }
            XCTAssertEqual(Set(joined.compactMap { $0["tabId"] as? Int }), memberIDs, "[\(via)]")
            XCTAssertTrue(joined.allSatisfy { $0["tabGroupId"] as? Int == groupID }, "[\(via)] the tab argument agrees")
        }
    }

    /// WebKit's own tabs.onUpdated (a load) hands over a tab whose groupId is
    /// the group another context put it in: the cache follows the events.
    @MainActor func testWebKitsOwnTabEventsCarryTheGroupAnotherContextSet() async throws {
        let scene = try await makeScene("Groups Native Events")
        _ = try await world.run(.worker, in: scene.loaded, ["op": "listen"])
        try await waitUntil("the worker to park") {
            scene.loaded.profile.polyfillHandler?.tabGroupEvents?.slotsForTesting(scene.loaded.ext.id)["background"]?.parked == true
        }
        let member = scene.tabs[2]
        let pageID = try await world.tabID(of: member, .page, in: scene.loaded)
        let grouped = try await call(.page, scene, "tabs", "group", [["tabIds": pageID]])
        let groupID = try XCTUnwrap(grouped as? Int)
        let workerID = try await world.tabID(of: member, .worker, in: scene.loaded)
        try await waitUntil("the worker to hear of the group") {
            let events = (try? await self.world.run(.worker, in: scene.loaded, ["op": "events"]) as? [[String: Any]]) ?? []
            return events.contains { $0["event"] as? String == "tabs.onUpdated" && $0["groupId"] as? Int == groupID }
        }
        _ = try await world.run(.worker, in: scene.loaded, ["op": "clearEvents"])
        member.load(world.url("three"))
        var native: [[String: Any]] = []
        try await waitUntil("WebKit's onUpdated for the load") {
            let events = (try? await self.world.run(.worker, in: scene.loaded, ["op": "events"]) as? [[String: Any]]) ?? []
            native = events.filter { $0["event"] as? String == "tabs.onUpdated.native" && $0["tabId"] as? Int == workerID }
            return !native.isEmpty
        }
        XCTAssertTrue(native.allSatisfy { $0["tabGroupId"] as? Int == groupID }, "\(native)")
    }

    /// Chrome reports a context's own changes too: the worker that groups and
    /// ungroups a tab hears tabs.onUpdated({groupId}) for each (found by the
    /// runtime check: its own call filled the cache first and hid the event).
    @MainActor func testAContextHearsItsOwnGroupAndUngroup() async throws {
        let scene = try await makeScene("Groups Own Events")
        _ = try await world.run(.worker, in: scene.loaded, ["op": "listen"])
        try await waitUntil("the worker to park") {
            scene.loaded.profile.polyfillHandler?.tabGroupEvents?.slotsForTesting(scene.loaded.ext.id)["background"]?.parked == true
        }
        let tabID = try await world.tabID(of: scene.tabs[1], .worker, in: scene.loaded)
        let grouped = try await call(.worker, scene, "tabs", "group", [["tabIds": tabID]])
        let groupID = try XCTUnwrap(grouped as? Int)
        _ = try await call(.worker, scene, "tabs", "get", [tabID])
        _ = try await call(.worker, scene, "tabs", "ungroup", [tabID])
        var seen: [Int] = []
        try await waitUntil("the worker to hear both changes") {
            let events = (try? await self.world.run(.worker, in: scene.loaded, ["op": "events"]) as? [[String: Any]]) ?? []
            seen = events.filter { $0["event"] as? String == "tabs.onUpdated" && $0["tabId"] as? Int == tabID }
                .compactMap { $0["groupId"] as? Int }
            return seen.count >= 2
        }
        XCTAssertEqual(seen, [groupID, -1], "each change once, in order")
    }

    /// tabs.getCurrent() in an extension page that is a tab carries its groupId.
    @MainActor func testGetCurrentCarriesGroupId() async throws {
        let scene = try await makeScene("Groups Get Current")
        let configuration = try XCTUnwrap(scene.loaded.context.webViewConfiguration)
        let pageTab = TabStore.shared.addExtensionTab(
            in: scene.space, url: scene.loaded.context.baseURL.appendingPathComponent("test.html"),
            configuration: configuration)
        let webView = try XCTUnwrap(pageTab.webView)
        try await waitUntil("the extension tab to load") { !webView.isLoading && webView.url != nil }
        let group = try TabStore.shared.createTabGroup(tabIDs: [pageTab.id], in: scene.space)
        let groupID = ExtensionTabGroupIDs.shared.id(for: group.id)
        let current = try await world.run(in: webView, ["op": "call", "ns": "tabs", "method": "getCurrent", "args": []])
        let tab = try XCTUnwrap(current as? [String: Any], "the page is a tab: \(current)")
        XCTAssertEqual(tab["groupId"] as? Int, groupID)
    }

    @MainActor func testAFavouriteIsNotGroupable() async throws {
        let scene = try await makeScene("Groups Favourite")
        let favourite = scene.tabs[3]
        let favouriteID = try await world.tabID(of: favourite, .page, in: scene.loaded)
        XCTAssertTrue(TabStore.shared.moveTabToFavorites(id: favourite.id, from: scene.space, profileID: scene.profile.id))
        for via in Via.allCases {
            let refused = try await failure(via, scene, "tabs", "group", [["tabIds": favouriteID]])
            XCTAssertEqual(refused, ExtensionPolyfillHandler.tabGroupNotGroupableError, "[\(via)]")
        }
        XCTAssertTrue(scene.space.tabGroups.isEmpty)
    }
}

// MARK: - Fixture

enum TabGroupsFixture {

    static let opJS = """
    async function __detourTestPanelOp(message) {
        const orNull = (value) => value === undefined ? null : value;
        const ns = (name) => name === 'tabs' ? chrome.tabs : name === 'windows' ? chrome.windows : chrome.tabGroups;
        const record = (entry) => { (globalThis.__detourTestEvents = globalThis.__detourTestEvents || []).push(entry); };
        switch (message.op) {
        case 'install': {
            let decorated = false;
            try {
                const tabs = await chrome.tabs.query({});
                decorated = tabs.length > 0 && tabs.every((t) => Number.isInteger(t.groupId));
            } catch (e) {}
            return {
                tabGroupsType: typeof chrome.tabGroups,
                install: orNull(globalThis.__detourTabGroupsInstall),
                tabsPatch: orNull(globalThis.__detourTabGroupsTabsPatch),
                keys: chrome.tabGroups ? Object.keys(chrome.tabGroups).sort() : [],
                noneConstant: chrome.tabGroups ? chrome.tabGroups.TAB_GROUP_ID_NONE : null,
                viaBrowser: !!(globalThis.browser && browser.tabGroups && browser.tabGroups === chrome.tabGroups),
                groupType: typeof chrome.tabs.group,
                ungroupType: typeof chrome.tabs.ungroup,
                decorated: decorated
            };
        }
        case 'call': {
            const target = ns(message.ns);
            const value = await target[message.method].apply(target, message.args || []);
            return orNull(value);
        }
        case 'callback': {
            const target = ns(message.ns);
            return await new Promise((resolve) => {
                target[message.method].apply(target, (message.args || []).concat([function() {
                    resolve({
                        argc: arguments.length,
                        arg0: arguments.length ? orNull(arguments[0]) : null,
                        lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
                    });
                }]));
            });
        }
        case 'tabs': {
            const all = await chrome.windows.getAll({ populate: true });
            const out = [];
            for (const w of all) {
                for (const t of (w.tabs || [])) {
                    out.push({ id: t.id, windowId: w.id, active: t.active, handle: await __detourResolveTab(t.id) });
                }
            }
            return { tabs: out, windows: all.map((w) => ({ id: w.id, tabCount: (w.tabs || []).length })) };
        }
        case 'listen': {
            if (globalThis.__detourTestListening) return true;
            globalThis.__detourTestListening = true;
            chrome.tabs.onUpdated.addListener((tabId, info, tab) => {
                if (!info || !('groupId' in info)) {
                    // WebKit's own event: the tab it hands over carries groupId.
                    record({ event: 'tabs.onUpdated.native', tabId: tabId, keys: Object.keys(info || {}),
                             tabGroupId: tab ? orNull(tab.groupId) : null });
                    return;
                }
                record({ event: 'tabs.onUpdated', tabId: tabId, groupId: info.groupId, tabGroupId: tab ? orNull(tab.groupId) : null });
            });
            for (const name of ['onCreated', 'onUpdated', 'onRemoved', 'onMoved']) {
                chrome.tabGroups[name].addListener((group) => {
                    record({ event: 'tabGroups.' + name, id: group.id, title: group.title, color: group.color,
                             collapsed: group.collapsed, windowId: group.windowId });
                });
            }
            return true;
        }
        case 'events':
            return (globalThis.__detourTestEvents || []).slice();
        case 'clearEvents':
            globalThis.__detourTestEvents = [];
            return true;
        }
        throw new Error('unknown op ' + message.op);
    }
    """

    static let workerJS = """

    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message || message.type !== 'panelOp') return false;
        __detourTestPanelOp(message.payload).then(
            (value) => sendResponse({ ok: true, value: value === undefined ? null : value }),
            (error) => sendResponse({ ok: false, error: String(error && error.message ? error.message : error) }));
        return true;
    });
    """
}
