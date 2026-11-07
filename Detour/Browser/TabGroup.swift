import Foundation

// MARK: - Model

/// A tab group's colour: Chrome's nine `tabGroups.Color` names, as raw values
/// (TASK-132.10). The names are what the extension API and the database store;
/// how each one is drawn belongs to the sidebar (TASK-132.11).
enum TabGroupColor: String, CaseIterable, Codable, Sendable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange

    /// The colour a new group gets when none is asked for: the first, in
    /// Chrome's order, of the colours used least by `existing` (Chrome's
    /// `TabGroupsUtil::GetNextColor`). With no groups yet that is grey.
    static func next(after existing: [TabGroupColor]) -> TabGroupColor {
        let counts = Dictionary(existing.map { ($0, 1) }, uniquingKeysWith: +)
        return allCases.min { counts[$0, default: 0] < counts[$1, default: 0] } ?? .grey
    }
}

/// A group of normal tabs in one space (TASK-132.10). Like a split, membership
/// lives on the tabs (`BrowserTab.tabGroupID`); this object holds what belongs
/// to the group itself. `TabStore` keeps the invariants listed on
/// `tabGroupPlacement` in every mutation, and removes a group in the same
/// mutation that leaves it with no members.
final class TabGroup {
    let id: UUID
    var title: String
    var color: TabGroupColor
    var isCollapsed: Bool

    init(id: UUID = UUID(), title: String = "", color: TabGroupColor, isCollapsed: Bool = false) {
        self.id = id
        self.title = title
        self.color = color
        self.isCollapsed = isCollapsed
    }

    /// The group a saved row describes; nil for a row whose id is not a UUID.
    /// An unknown colour loads as grey.
    convenience init?(record: TabGroupRecord) {
        guard let id = UUID(uuidString: record.id) else { return nil }
        self.init(id: id, title: record.title, color: TabGroupColor(rawValue: record.color) ?? .grey,
                  isCollapsed: record.isCollapsed)
    }

    /// The group's row: `sortOrder` is its position in `space.tabGroups`.
    func record(spaceID: UUID, sortOrder: Int) -> TabGroupRecord {
        TabGroupRecord(id: id.uuidString, spaceID: spaceID.uuidString, title: title, color: color.rawValue,
                       isCollapsed: isCollapsed, sortOrder: sortOrder)
    }

    /// What an undo needs to bring the group back after it was removed.
    var snapshot: TabGroupSnapshot {
        TabGroupSnapshot(id: id, title: title, color: color, isCollapsed: isCollapsed)
    }
}

/// A group's own state, kept by an undo whose action may have removed the group.
struct TabGroupSnapshot: Equatable {
    let id: UUID
    let title: String
    let color: TabGroupColor
    let isCollapsed: Bool

    func makeGroup() -> TabGroup {
        TabGroup(id: id, title: title, color: color, isCollapsed: isCollapsed)
    }
}

/// Why a tab group mutation was refused. A refused call changes nothing.
enum TabGroupError: Error, Equatable {
    /// No tab ids were given.
    case noTabs
    /// The id is not a normal tab of the space: unknown, closed, or a tab of
    /// another space.
    case tabNotFound(UUID)
    /// The id is a pinned tab or a favourite of the space, which are never grouped.
    case tabNotGroupable(UUID)
    /// The space has no group with this id.
    case groupNotFound(UUID)
}

// MARK: - Placement rules (pure)

/// One normal tab as the placement rules see it.
struct TabSlot: Equatable {
    var splitGroupID: UUID?
    var tabGroupID: UUID?
}

/// How a block entering the tab list (a lone tab, or both panes of a split)
/// chooses its tab group.
enum TabGroupIntent: Equatable {
    /// The neighbours decide: a block landing between two members of one group
    /// joins it. Otherwise it keeps `preferring` (its own group when it moves,
    /// its opener's when it is new) only if it lands next to a member of that
    /// group, and is ungrouped if not.
    case byPosition(preferring: UUID?)
    /// The block must end up in this group (an undo putting a tab back): the
    /// gap is clamped into the group's current range. If the group has no
    /// members the block carries it, as `carry` does.
    case rejoin(UUID)
    /// The block is the whole of this group (its last member, or every member
    /// moving together): the group goes with it, and the gap snaps out of any
    /// other group's interior.
    case carry(UUID)
}

/// Where a block lands and which tab group it ends up in.
struct TabGroupPlacement: Equatable {
    /// The gap in the list without the block (0...count).
    let insertAt: Int
    let tabGroupID: UUID?
}

/// Resolves where a block entering the tab list at `gap` lands and which group
/// it joins. `slots` is the tab list WITHOUT the block (post-removal
/// coordinates). Insertion never lands inside a split, and the result keeps
/// every tab group invariant, given that `slots` keeps them:
///
/// 1. A group's members are contiguous in the tab list.
/// 2. A split pair is wholly inside or wholly outside a group.
/// 3. Only normal tabs are members (the rules see only normal tabs).
func tabGroupPlacement(gap: Int, slots: [TabSlot], intent: TabGroupIntent) -> TabGroupPlacement {
    let clamped = max(0, min(gap, slots.count))
    switch intent {
    case .carry(let group):
        return TabGroupPlacement(insertAt: snappedOutOfTabGroups(clamped, slots: slots), tabGroupID: group)
    case .rejoin(let group):
        guard let range = tabGroupRange(of: group, in: slots) else {
            return TabGroupPlacement(insertAt: snappedOutOfTabGroups(clamped, slots: slots), tabGroupID: group)
        }
        // A split inside the group ends inside it or at its right edge, so the
        // snap cannot leave the range.
        let inside = min(max(clamped, range.lowerBound), range.upperBound)
        return TabGroupPlacement(
            insertAt: snappedToSplitGroupBoundary(inside, groupIDs: slots.map(\.splitGroupID)),
            tabGroupID: group
        )
    case .byPosition(let preferred):
        let snapped = snappedToSplitGroupBoundary(clamped, groupIDs: slots.map(\.splitGroupID))
        let left = snapped > 0 ? slots[snapped - 1].tabGroupID : nil
        let right = snapped < slots.count ? slots[snapped].tabGroupID : nil
        if let left, left == right {
            return TabGroupPlacement(insertAt: snapped, tabGroupID: left)
        }
        if let preferred, left == preferred || right == preferred {
            return TabGroupPlacement(insertAt: snapped, tabGroupID: preferred)
        }
        return TabGroupPlacement(insertAt: snapped, tabGroupID: nil)
    }
}

/// The range a group's members occupy, or nil when it has none. Assumes the
/// members are contiguous (invariant 1).
func tabGroupRange(of group: UUID, in slots: [TabSlot]) -> Range<Int>? {
    guard let first = slots.firstIndex(where: { $0.tabGroupID == group }),
          let last = slots.lastIndex(where: { $0.tabGroupID == group }) else { return nil }
    return first..<(last + 1)
}

/// `gap` moved forward out of any split's and any tab group's interior. A
/// split lies wholly inside or outside a group, so a group's end is never
/// inside a split.
func snappedOutOfTabGroups(_ gap: Int, slots: [TabSlot]) -> Int {
    var i = snappedToSplitGroupBoundary(gap, groupIDs: slots.map(\.splitGroupID))
    while i > 0, i < slots.count, let group = slots[i - 1].tabGroupID, slots[i].tabGroupID == group {
        i += 1
    }
    return i
}

/// The tabs' group ids with the invariants restored, for a list loaded from
/// disk or rebuilt by Undo Delete Space (a dropped tab can leave anything
/// behind). Run after `sanitizeSplitGroups`. An id that names no group of the
/// space is cleared; a split pair takes its left pane's group; a group whose
/// members form more than one run keeps the first run and the rest are
/// ungrouped. The caller removes the groups left with no member.
func sanitizedTabGroupIDs(_ slots: [TabSlot], knownGroupIDs: Set<UUID>) -> [UUID?] {
    var ids = slots.map { slot in slot.tabGroupID.flatMap { knownGroupIDs.contains($0) ? $0 : nil } }
    for run in splitRuns(of: slots, groupID: { $0.splitGroupID }) where run.groupID != nil {
        let leftPaneGroup = ids[run.range.lowerBound]
        for i in run.range { ids[i] = leftPaneGroup }
    }
    var seen = Set<UUID>()
    var i = 0
    while i < ids.count {
        guard let group = ids[i] else { i += 1; continue }
        var end = i + 1
        while end < ids.count, ids[end] == group { end += 1 }
        if seen.contains(group) {
            for k in i..<end { ids[k] = nil }
        } else {
            seen.insert(group)
        }
        i = end
    }
    return ids
}
