import Foundation
import WebKit

// TASK-132.12: what `chrome.tabGroups`, `tabs.group` / `tabs.ungroup` and a
// tab's `groupId` need natively, besides the request handler
// (`ExtensionPolyfillHandler+TabGroups.swift`): session-stable integer ids for
// `TabGroup`s, the group as an extension sees it, Chrome's window index turned
// into a place in the tab list, and the event hub that tells parked contexts
// what changed. The model itself is TASK-132.10's (`TabGroup.swift`).

// MARK: - Ids

/// Chrome gives a group an integer id, unique and stable for the session; a
/// `TabGroup` has a UUID. Ids are minted on first use, at random, and never
/// handed to another group. Process-wide, so a group keeps its id whichever profile's
/// handler names it; an id of another profile's group is refused by the
/// handler exactly like an unknown one.
final class ExtensionTabGroupIDs {
    static let shared = ExtensionTabGroupIDs()

    private var ids: [UUID: Int] = [:]
    private var uuids: [Int: UUID] = [:]
    private var random: () -> Int

    /// `random` draws a candidate id; tests inject their own.
    init(random: @escaping () -> Int = { Int.random(in: 1...Int(Int32.max)) }) {
        self.random = random
    }

    /// `group`'s id, minted on first use. A group an undo brings back has the
    /// same UUID, so it gets its old id back.
    ///
    /// Random rather than counted: ids are process-wide, so a counter would let
    /// an extension in one profile count the groups made in the others —
    /// Private's included — from the gap between two of its own. Positive and
    /// within 32 bits, as Chrome's are, and never reused.
    func id(for group: UUID) -> Int {
        if let id = ids[group] { return id }
        var id = random()
        while id <= 0 || uuids[id] != nil { id = random() }
        ids[group] = id
        uuids[id] = group
        return id
    }

    /// The group an id was minted for, or nil.
    func group(for id: Int) -> UUID? {
        uuids[id]
    }
}

// MARK: - Wire form

extension TabGroup {
    /// The group as the polyfill receives it: Chrome's `TabGroup` without
    /// `windowId`, which only the polyfill can name (from the window of the
    /// member tab whose handle is `memberTabHandle`). `shared` is always
    /// false: Detour has no shared groups.
    @MainActor
    func extensionWireForm(in space: Space) -> [String: Any] {
        var wire: [String: Any] = [
            "id": ExtensionTabGroupIDs.shared.id(for: id),
            "title": title,
            "color": color.rawValue,
            "collapsed": isCollapsed,
            "shared": false,
        ]
        if let member = space.members(ofTabGroup: id).first {
            wire["memberTabHandle"] = ExtensionTabHandleRegistry.shared.handle(for: member)
        }
        return wire
    }
}

// MARK: - tabGroups.move's index

/// Where `tabGroups.move` puts a group, from Chrome's index.
enum TabGroupMoveTarget: Equatable {
    /// The gap in the space's normal tabs without the group's members, which
    /// is `TabStore.moveTabGroup`'s destination.
    case gap(Int)
    /// The index falls among the pinned tabs. Chrome: "Cannot move the group
    /// to an index that is in the middle of pinned tabs."
    case insidePinnedTabs
    /// The index falls between two members of another group. Chrome: "Cannot
    /// move the group to an index that is in the middle of another group."
    case insideAnotherGroup
}

/// One normal tab of the space, as `tabGroupMoveTarget` sees it.
struct TabGroupMoveSlot: Equatable {
    var slot: TabSlot
    /// The tab's Peek is listed right after it (a live Peek), taking an index.
    var hasListedPeek: Bool
}

/// Chrome's index for a group's first tab after `tabGroups.move`, in the
/// window's tab list as WebKit sees it (`extensionWindowTabs`: the listed
/// pinned tabs, then the normal tabs, then the favourites, each followed by
/// its live Peek), turned into a gap in the normal tabs.
///
/// `leadingCount` is how many entries precede the normal tabs (pinned tabs and
/// their Peeks); `rest` is the normal tabs without the moving group's members.
/// -1, or an index at or past the last normal entry, means the end of the
/// normal tabs: favourites come after them, and a group never goes there. An
/// index on a Peek means the place after its host. A gap inside a split moves
/// past the split, as everywhere in the tab list.
func tabGroupMoveTarget(windowIndex: Int, leadingCount: Int, rest: [TabGroupMoveSlot]) -> TabGroupMoveTarget {
    var positions: [(tabIndex: Int, isPeek: Bool)] = []
    for (i, entry) in rest.enumerated() {
        positions.append((i, false))
        if entry.hasListedPeek { positions.append((i, true)) }
    }
    let gap: Int
    if windowIndex < 0 || windowIndex >= leadingCount + positions.count {
        gap = rest.count
    } else if windowIndex < leadingCount {
        return .insidePinnedTabs
    } else {
        let position = positions[windowIndex - leadingCount]
        gap = position.isPeek ? position.tabIndex + 1 : position.tabIndex
    }
    let slots = rest.map(\.slot)
    let outOfSplits = snappedToSplitGroupBoundary(gap, groupIDs: slots.map(\.splitGroupID))
    guard snappedOutOfTabGroups(outOfSplits, slots: slots) == outOfSplits else { return .insideAnotherGroup }
    return .gap(outOfSplits)
}

// MARK: - Events

/// How one profile's extension contexts hear that tab groups changed: the
/// group events of `chrome.tabGroups` (`onCreated`, `onUpdated`, `onRemoved`,
/// `onMoved`) and a tab's `groupId` changing, which the polyfill delivers as
/// `tabs.onUpdated` and keeps in the cache it decorates WebKit's tab objects
/// from.
///
/// There is no push channel into a context, so each context that listens
/// parks a `tabGroups.awaitEvent` request (the notifications pattern, see the
/// polyfill-layer wiki): it is answered with the events not yet acknowledged,
/// and the context parks again with the last `seq` it dispatched.
///
/// Unlike notifications, pages park too: the Claude extension's side panel
/// listens to `tabs.onUpdated` for `groupId` as its worker does. Each JS
/// context (its `__detourContextInstance`) has a slot of its own. A page's
/// slot is held with a weak reference to its web view and dropped once the
/// view is gone; an extension keeps at most `pageSlotLimit` page slots, the
/// one used longest ago going first (a reloaded page leaves its old slot
/// behind until then). The background has one slot; a newer incarnation
/// supersedes the parked request in place and an older one is refused from
/// then on, as for notifications, and an event wakes a background that has
/// listened this launch.
///
/// Group events reach only an extension whose `tabGroups` permission is
/// active (`permits`); `groupId` changes reach every listening extension, as
/// a Tab's `groupId` needs no permission in Chrome.
final class ExtensionTabGroupEvents: TabStoreObserver {

    static let backlogLimit = 64
    static let pageSlotLimit = ExtensionEventParking.pageSlotLimit
    static let supersededError = "tabGroups events: superseded by a newer wait"
    static let unloadedError = "tabGroups events: the extension was unloaded"

    let profileID: UUID
    /// Whether the extension's `tabGroups` permission is active in this profile.
    private let permits: (String) -> Bool
    /// The parked waits and their backlogs (`ExtensionEventParking`).
    private let parking: ExtensionEventParking
    /// Starts an extension's background content for an event (a no-op while
    /// it runs). A seam for tests.
    var wakeBackground: (String) -> Void {
        get { parking.wakeBackground }
        set { parking.wakeBackground = newValue }
    }

    init(profileID: UUID, permits: @escaping (String) -> Bool, wakeBackground: @escaping (String) -> Void) {
        self.profileID = profileID
        self.permits = permits
        self.parking = ExtensionEventParking(
            label: "tabGroups events", backlogLimit: Self.backlogLimit,
            supersededError: Self.supersededError, unloadedError: Self.unloadedError,
            wakeBackground: wakeBackground)
        TabStore.shared.addObserver(self)
    }

    /// Parks `reply` for the context's next events, or answers at once with
    /// those not yet acknowledged (`ExtensionEventParking.awaitEvent`).
    func awaitEvent(extensionID: String, isBackground: Bool, instance: String?, webView: WKWebView?,
                    ack: Int?, reply: @escaping (Any?, String?) -> Void) {
        parking.awaitEvent(extensionID: extensionID, isBackground: isBackground, instance: instance,
                           webView: webView, ack: ack, reply: reply)
    }

    /// Forgets the extension's slots, answering their waits: it was unloaded.
    func drop(extensionID: String) {
        parking.drop(extensionID: extensionID)
    }

    /// Queues the event for every listening context it is for.
    private func deliver(_ payload: [String: Any], isGroupEvent: Bool) {
        parking.deliver(payload, to: { [permits] extensionID in !isGroupEvent || permits(extensionID) })
    }

    #if DEBUG
    /// Slot keys and backlog sizes, for tests.
    func slotsForTesting(_ extensionID: String) -> [String: (parked: Bool, backlog: Int)] {
        parking.slotsForTesting(extensionID)
    }
    #endif

    // MARK: TabStoreObserver

    private func isOurs(_ space: Space) -> Bool { space.profileID == profileID }

    private func groupEvent(_ kind: String, _ group: TabGroup, in space: Space) {
        guard isOurs(space) else { return }
        deliver(["kind": kind, "group": group.extensionWireForm(in: space)], isGroupEvent: true)
    }

    private func membership(of tab: BrowserTab) {
        deliver(["kind": "membership",
                 "tabHandle": ExtensionTabHandleRegistry.shared.handle(for: tab),
                 "groupId": tab.tabGroupID.map { ExtensionTabGroupIDs.shared.id(for: $0) } ?? -1],
                isGroupEvent: false)
    }

    func tabStoreDidCreateTabGroup(_ group: TabGroup, in space: Space) { groupEvent("created", group, in: space) }
    func tabStoreDidUpdateTabGroup(_ group: TabGroup, in space: Space) { groupEvent("updated", group, in: space) }
    func tabStoreDidRemoveTabGroup(_ group: TabGroup, in space: Space) { groupEvent("removed", group, in: space) }
    func tabStoreDidMoveTabGroup(_ group: TabGroup, in space: Space) { groupEvent("moved", group, in: space) }

    func tabStoreDidChangeTabGroupMembership(of tabs: [BrowserTab]) {
        for tab in tabs {
            // Only a tab this profile's windows list: one moved to another
            // profile's space is that profile's business.
            guard let space = TabStore.shared.spaces.first(where: { $0.id == tab.spaceID }), isOurs(space) else { continue }
            membership(of: tab)
        }
    }

    /// A tab placed straight into a group reports only its insertion (the
    /// store's rule), so the cache learns its group here.
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard isOurs(space), tab.tabGroupID != nil else { return }
        membership(of: tab)
    }
}
