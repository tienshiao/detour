import XCTest
import WebKit
@testable import Detour

/// TASK-132.12, the parts with no extension context: session group ids,
/// `tabGroups.move`'s index, `tabGroups.query`'s title pattern, and the event
/// hub's parking rules. The API end to end is `ExtensionTabGroupsTests`.
nonisolated final class ExtensionTabGroupsUnitTests: XCTestCase {

    // MARK: - Ids

    @MainActor func testGroupIdsAreStableDistinctAndReversible() {
        let ids = ExtensionTabGroupIDs()
        let a = UUID(), b = UUID()
        let first = ids.id(for: a)
        XCTAssertEqual(ids.id(for: a), first)
        XCTAssertNotEqual(ids.id(for: b), first)
        XCTAssertEqual(ids.group(for: first), a)
        XCTAssertNil(ids.group(for: 999_999))
        XCTAssertGreaterThan(first, 0)
    }

    /// Ids say nothing about how many groups were made in between (another
    /// profile's, Private's): they are drawn at random, never repeated, and a
    /// draw that is taken or not positive is drawn again.
    @MainActor func testGroupIdsAreDrawnAtRandomAndNeverReused() {
        var draws = [7, 7, 0, -3, 9]
        let ids = ExtensionTabGroupIDs(random: { draws.removeFirst() })
        XCTAssertEqual(ids.id(for: UUID()), 7)
        XCTAssertEqual(ids.id(for: UUID()), 9, "a taken id and non-positive draws are skipped")
        let real = ExtensionTabGroupIDs()
        let minted = (0..<50).map { _ in real.id(for: UUID()) }
        XCTAssertEqual(Set(minted).count, 50)
        XCTAssertTrue(minted.allSatisfy { $0 > 0 && $0 <= Int(Int32.max) })
        XCTAssertNotEqual(minted.sorted(), Array(minted.first!...(minted.first! + 49)), "not a counter")
    }

    // MARK: - tabGroups.move's index

    @MainActor private func rest(_ spec: [(UUID?, UUID?, Bool)]) -> [TabGroupMoveSlot] {
        spec.map { TabGroupMoveSlot(slot: TabSlot(splitGroupID: $0.1, tabGroupID: $0.0), hasListedPeek: $0.2) }
    }

    @MainActor func testTheIndexCountsPinnedTabsAndPeeksBeforeTheNormalTabs() {
        let list = rest([(nil, nil, false), (nil, nil, true), (nil, nil, false)])
        // Two pinned entries (a tab and its Peek) come first.
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 0, leadingCount: 2, rest: list), .insidePinnedTabs)
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 1, leadingCount: 2, rest: list), .insidePinnedTabs)
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 2, leadingCount: 2, rest: list), .gap(0))
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 3, leadingCount: 2, rest: list), .gap(1))
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 4, leadingCount: 2, rest: list), .gap(2), "the Peek: after its host")
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 5, leadingCount: 2, rest: list), .gap(2))
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: -1, leadingCount: 2, rest: list), .gap(3))
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 40, leadingCount: 2, rest: list), .gap(3), "past the end: the end")
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 0, leadingCount: 0, rest: []), .gap(0))
    }

    @MainActor func testAnIndexInsideAnotherGroupIsRefusedAndOneInsideASplitSnapsPastIt() {
        let other = UUID(), split = UUID()
        let list = rest([(nil, nil, false), (other, nil, false), (other, nil, false), (nil, split, false), (nil, split, false)])
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 1, leadingCount: 0, rest: list), .gap(1), "the other group's edge")
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 2, leadingCount: 0, rest: list), .insideAnotherGroup)
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 3, leadingCount: 0, rest: list), .gap(3))
        XCTAssertEqual(tabGroupMoveTarget(windowIndex: 4, leadingCount: 0, rest: list), .gap(5), "between the panes: past the split")
    }

    // MARK: - tabGroups.query's title

    @MainActor func testTitlePatterns() {
        let matches = ExtensionPolyfillHandler.tabGroupTitle(_:matches:)
        XCTAssertTrue(matches("Claude", "Claude"))
        XCTAssertFalse(matches("Claude", "claude"), "case matters, as in base::MatchPattern")
        XCTAssertTrue(matches("Claude session", "Claude*"))
        XCTAssertTrue(matches("Claude", "*"))
        XCTAssertTrue(matches("", "*"))
        XCTAssertTrue(matches("Cat", "C?t"))
        XCTAssertFalse(matches("Ct", "C?t"))
        XCTAssertTrue(matches("a-b-c", "a*c"))
        XCTAssertFalse(matches("a-b-d", "a*c"))
        XCTAssertFalse(matches("", "x"))
    }

    // MARK: - Event hub

    @MainActor private final class Replies {
        var answers: [String: [(events: [[String: Any]]?, error: String?)]] = [:]
        func reply(_ name: String) -> (Any?, String?) -> Void {
            { [weak self] value, error in
                self?.answers[name, default: []].append(((value as? [String: Any])?["events"] as? [[String: Any]], error))
            }
        }
        func events(_ name: String) -> [[String: Any]] { answers[name]?.last?.events ?? [] }
        func error(_ name: String) -> String? { answers[name]?.last?.error }
        func count(_ name: String) -> Int { answers[name]?.count ?? 0 }
    }

    @MainActor private func makeHub(profileID: UUID = UUID(), permits: Bool = true,
                         woke: @escaping (String) -> Void = { _ in }) -> ExtensionTabGroupEvents {
        ExtensionTabGroupEvents(profileID: profileID, permits: { _ in permits }, wakeBackground: woke)
    }

    @MainActor private func space(for profileID: UUID) -> Space {
        Space(name: "S", emoji: "S", colorHex: "007AFF", profileID: profileID)
    }

    @MainActor func testAParkIsAnsweredWithTheEventAndTheAckDropsIt() {
        let profileID = UUID()
        var wakes: [String] = []
        let hub = makeHub(profileID: profileID, woke: { wakes.append($0) })
        let replies = Replies()
        hub.awaitEvent(extensionID: "x", isBackground: true, instance: "w1", webView: nil, ack: nil, reply: replies.reply("a"))
        XCTAssertEqual(replies.count("a"), 0, "parked")

        let group = TabGroup(title: "G", color: .red)
        hub.tabStoreDidCreateTabGroup(group, in: space(for: profileID))
        let first = replies.events("a")
        XCTAssertEqual(first.map { $0["kind"] as? String }, ["created"])
        XCTAssertEqual((first.first?["group"] as? [String: Any])?["title"] as? String, "G")
        XCTAssertEqual(wakes, ["x"], "a background that listens is woken")

        // Parks again acknowledging it: nothing left, so it waits.
        let seq = first.first?["seq"] as? Int
        hub.awaitEvent(extensionID: "x", isBackground: true, instance: "w1", webView: nil, ack: seq, reply: replies.reply("b"))
        XCTAssertEqual(replies.count("b"), 0)
        // Without the ack, the same event comes again (a worker that died
        // before acknowledging).
        hub.awaitEvent(extensionID: "x", isBackground: true, instance: "w1", webView: nil, ack: nil, reply: replies.reply("c"))
        XCTAssertEqual(replies.error("b"), ExtensionTabGroupEvents.supersededError, "the earlier wait is answered")
        XCTAssertEqual(replies.count("c"), 0, "acknowledged events do not come back")
    }

    @MainActor func testEventsOfAnotherProfileAreIgnored() {
        let hub = makeHub()
        let replies = Replies()
        hub.awaitEvent(extensionID: "x", isBackground: true, instance: "w1", webView: nil, ack: nil, reply: replies.reply("a"))
        hub.tabStoreDidCreateTabGroup(TabGroup(color: .red), in: space(for: UUID()))
        XCTAssertEqual(replies.count("a"), 0)
    }

    @MainActor func testANewerBackgroundIncarnationSupersedesAndTheOlderIsRefused() {
        let hub = makeHub()
        let replies = Replies()
        hub.awaitEvent(extensionID: "x", isBackground: true, instance: "old", webView: nil, ack: nil, reply: replies.reply("old"))
        hub.awaitEvent(extensionID: "x", isBackground: true, instance: "new", webView: nil, ack: nil, reply: replies.reply("new"))
        XCTAssertEqual(replies.error("old"), ExtensionTabGroupEvents.supersededError)
        hub.awaitEvent(extensionID: "x", isBackground: true, instance: "old", webView: nil, ack: nil, reply: replies.reply("again"))
        XCTAssertEqual(replies.error("again"), ExtensionTabGroupEvents.supersededError)
        XCTAssertEqual(replies.count("new"), 0, "the newer wait stands")
    }

    @MainActor func testWithoutThePermissionOnlyGroupIdChangesArrive() {
        let profileID = UUID()
        let hub = makeHub(profileID: profileID, permits: false)
        let replies = Replies()
        let s = space(for: profileID)
        hub.awaitEvent(extensionID: "x", isBackground: true, instance: "w", webView: nil, ack: nil, reply: replies.reply("a"))
        hub.tabStoreDidCreateTabGroup(TabGroup(color: .red), in: s)
        XCTAssertEqual(replies.count("a"), 0, "no group event without tabGroups")
        let tab = BrowserTab(id: UUID(), title: "t", url: nil, faviconURL: nil, cachedInteractionState: nil, spaceID: s.id)
        tab.tabGroupID = UUID()
        hub.tabStoreDidInsertTab(tab, at: 0, in: s)
        XCTAssertEqual(replies.events("a").map { $0["kind"] as? String }, ["membership"])
        XCTAssertEqual(replies.events("a").first?["tabHandle"] as? Int, ExtensionTabHandleRegistry.shared.handle(for: tab))
    }

    @MainActor func testPagesParkPerInstanceAreDroppedWithTheirViewAndAreBounded() async throws {
        let profileID = UUID()
        let hub = makeHub(profileID: profileID)
        let replies = Replies()
        // No instance, no slot.
        hub.awaitEvent(extensionID: "x", isBackground: false, instance: nil, webView: nil, ack: nil, reply: replies.reply("bad"))
        XCTAssertNotNil(replies.error("bad"))

        weak var probe: WKWebView?
        autoreleasepool {
            let view = WKWebView()
            probe = view
            hub.awaitEvent(extensionID: "x", isBackground: false, instance: "p1", webView: view, ack: nil, reply: replies.reply("p1"))
        }
        XCTAssertEqual(hub.slotsForTesting("x").keys.sorted(), ["page:p1"])
        // WebKit lets a web view go a turn or two after its last reference.
        try await waitUntil("the web view to be released", timeout: 5) { probe == nil }
        hub.tabStoreDidCreateTabGroup(TabGroup(color: .red), in: space(for: profileID))
        XCTAssertTrue(hub.slotsForTesting("x").isEmpty, "a page whose view is gone loses its slot")
        XCTAssertEqual(replies.error("p1"), ExtensionTabGroupEvents.unloadedError,
                       "its wait is answered, not released uncalled")

        let views = (0..<(ExtensionTabGroupEvents.pageSlotLimit + 2)).map { _ in WKWebView() }
        for (i, view) in views.enumerated() {
            hub.awaitEvent(extensionID: "x", isBackground: false, instance: "q\(i)", webView: view, ack: nil,
                           reply: replies.reply("q\(i)"))
        }
        XCTAssertEqual(hub.slotsForTesting("x").count, ExtensionTabGroupEvents.pageSlotLimit)
        XCTAssertEqual(replies.error("q0"), ExtensionTabGroupEvents.supersededError, "the stalest page goes first")
        XCTAssertNil(hub.slotsForTesting("x")["page:q0"])
        XCTAssertNotNil(hub.slotsForTesting("x")["page:q\(views.count - 1)"])
        _ = views
    }

    @MainActor func testDroppingTheExtensionAnswersItsWaits() {
        let hub = makeHub()
        let replies = Replies()
        let view = WKWebView()
        hub.awaitEvent(extensionID: "x", isBackground: true, instance: "w", webView: nil, ack: nil, reply: replies.reply("w"))
        hub.awaitEvent(extensionID: "x", isBackground: false, instance: "p", webView: view, ack: nil, reply: replies.reply("p"))
        hub.drop(extensionID: "x")
        XCTAssertEqual(replies.error("w"), ExtensionTabGroupEvents.unloadedError)
        XCTAssertEqual(replies.error("p"), ExtensionTabGroupEvents.unloadedError)
        XCTAssertTrue(hub.slotsForTesting("x").isEmpty)
        _ = view
    }

    @MainActor func testTheBacklogIsBounded() {
        let profileID = UUID()
        let hub = makeHub(profileID: profileID)
        let replies = Replies()
        let s = space(for: profileID)
        hub.awaitEvent(extensionID: "x", isBackground: true, instance: "w", webView: nil, ack: nil, reply: replies.reply("w"))
        for _ in 0..<(ExtensionTabGroupEvents.backlogLimit + 10) {
            hub.tabStoreDidUpdateTabGroup(TabGroup(color: .red), in: s)
        }
        XCTAssertEqual(hub.slotsForTesting("x")["background"]?.backlog, ExtensionTabGroupEvents.backlogLimit)
    }
}
