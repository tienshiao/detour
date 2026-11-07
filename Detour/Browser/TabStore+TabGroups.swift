import Foundation

// Tab groups (TASK-132.10): the store API and the helpers every tab mutation
// uses to keep the invariants listed on `tabGroupPlacement` (TabGroup.swift).
// Membership lives on `BrowserTab.tabGroupID`, the groups on `Space.tabGroups`.
//
// How a mutation keeps them:
// - a block entering `space.tabs` gets its slot and group from
//   `placement(forGap:intent:in:)` and `assignTabGroup`;
// - a tab leaving `space.tabs` (closed, pinned, made a favourite, moved to
//   another space) goes through `leaveTabGroup`;
// - the mutation ends with `settleTabGroups(in:)`, which reports membership
//   changes and removes the groups it left empty.
//
// The group mutations themselves register no undo: nothing in the app's own
// UI creates or edits a group yet (TASK-132.19 will), only extensions.

extension Space {
    func tabGroup(id: UUID) -> TabGroup? {
        tabGroups.first { $0.id == id }
    }

    /// The group's members in tab-list order.
    func members(ofTabGroup id: UUID) -> [BrowserTab] {
        tabs.filter { $0.tabGroupID == id }
    }
}

extension TabStore {

    // MARK: - Lookups

    /// The group with `id` and the space holding it, in any space.
    func tabGroup(id: UUID) -> (group: TabGroup, space: Space)? {
        for space in spaces {
            if let group = space.tabGroup(id: id) { return (group, space) }
        }
        return nil
    }

    // MARK: - Store API

    /// Puts `tabIDs` (normal tabs of `space`) into a new group and returns it.
    /// As in Chrome, the tabs gather, in list order, where the first of them
    /// is; when that is inside another group the new one lands just past it.
    /// A split pane brings its partner. Each tab leaves the group it was in.
    /// `color` nil takes the colour used least in the space (Chrome's rule).
    @discardableResult
    func createTabGroup(tabIDs: [UUID], title: String = "", color: TabGroupColor? = nil,
                        isCollapsed: Bool = false, in space: Space) throws -> TabGroup {
        let block = try groupableTabs(tabIDs, in: space)
        let blockIDs = Set(block.map(\.id))
        let firstIndex = space.tabs.firstIndex { blockIDs.contains($0.id) } ?? 0
        let group = TabGroup(title: title, color: color ?? .next(after: space.tabGroups.map(\.color)),
                             isCollapsed: isCollapsed)

        let oldOrder = space.tabs.map(\.id)
        var list = space.tabs.filter { !blockIDs.contains($0.id) }
        // Every tab of the block is at or after `firstIndex`, so it is the same
        // gap in the list without them.
        let gap = snappedOutOfTabGroups(firstIndex, slots: tabSlots(list))
        list.insert(contentsOf: block, at: gap)
        space.tabGroups.append(group)
        space.tabs = list
        assignTabGroup(group.id, to: block)

        notifyObservers { $0.tabStoreDidCreateTabGroup(group, in: space) }
        if space.tabs.map(\.id) != oldOrder {
            notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        }
        settleTabGroups(in: space)
        scheduleSave()
        return group
    }

    /// Adds `tabIDs` to the existing group `groupID`. As in Chrome, tabs left
    /// of the group join at its left edge and tabs right of it at its right
    /// edge, each side in list order; members are left where they are.
    func addTabs(_ tabIDs: [UUID], toTabGroup groupID: UUID, in space: Space) throws {
        guard space.tabGroup(id: groupID) != nil else { throw TabGroupError.groupNotFound(groupID) }
        let joining = try groupableTabs(tabIDs, in: space).filter { $0.tabGroupID != groupID }
        guard !joining.isEmpty,
              let firstMember = space.tabs.firstIndex(where: { $0.tabGroupID == groupID }) else { return }
        let joiningIDs = Set(joining.map(\.id))
        // Members are contiguous and a split pair shares its group, so nothing
        // joining sits between two members.
        let indexByID = Dictionary(uniqueKeysWithValues: space.tabs.enumerated().map { ($0.element.id, $0.offset) })
        let left = joining.filter { indexByID[$0.id]! < firstMember }
        let right = joining.filter { indexByID[$0.id]! > firstMember }

        let oldOrder = space.tabs.map(\.id)
        var list = space.tabs.filter { !joiningIDs.contains($0.id) }
        let range = tabGroupRange(of: groupID, in: tabSlots(list))!
        list.insert(contentsOf: right, at: range.upperBound)
        list.insert(contentsOf: left, at: range.lowerBound)
        space.tabs = list
        assignTabGroup(groupID, to: joining)

        if space.tabs.map(\.id) != oldOrder {
            notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        }
        settleTabGroups(in: space)
        scheduleSave()
    }

    /// Takes `tabIDs` out of their groups. A tab between two members that stay
    /// moves to just past the group's right edge; one already at either edge
    /// stays where it is. A group left with no members is removed. Ungrouped
    /// tabs among `tabIDs` are ignored; a split pane brings its partner.
    func ungroupTabs(_ tabIDs: [UUID], in space: Space) throws {
        let leaving = try groupableTabs(tabIDs, in: space).filter { $0.tabGroupID != nil }
        guard !leaving.isEmpty else { return }
        let leavingIDs = Set(leaving.map(\.id))

        let oldOrder = space.tabs.map(\.id)
        var list = space.tabs
        var groupIDs: [UUID] = []
        for tab in leaving where !groupIDs.contains(tab.tabGroupID!) { groupIDs.append(tab.tabGroupID!) }
        for groupID in groupIDs {
            let staying = list.filter { $0.tabGroupID == groupID && !leavingIDs.contains($0.id) }
            guard let firstStaying = staying.first, let lastStaying = staying.last,
                  let lower = list.firstIndex(where: { $0 === firstStaying }),
                  let upper = list.firstIndex(where: { $0 === lastStaying }) else { continue }
            let middle = list.enumerated()
                .filter { $0.offset > lower && $0.offset < upper && leavingIDs.contains($0.element.id) }
                .map(\.element)
            guard !middle.isEmpty else { continue }
            list.removeAll { tab in middle.contains { $0 === tab } }
            let after = list.firstIndex { $0 === lastStaying }! + 1
            list.insert(contentsOf: middle, at: after)
        }
        space.tabs = list
        assignTabGroup(nil, to: leaving)

        if space.tabs.map(\.id) != oldOrder {
            notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        }
        settleTabGroups(in: space)
        scheduleSave()
    }

    /// Changes a group's own state; nil leaves a field as it is.
    func updateTabGroup(_ groupID: UUID, title: String? = nil, color: TabGroupColor? = nil,
                        isCollapsed: Bool? = nil, in space: Space) throws {
        guard let group = space.tabGroup(id: groupID) else { throw TabGroupError.groupNotFound(groupID) }
        var changed = false
        if let title, title != group.title { group.title = title; changed = true }
        if let color, color != group.color { group.color = color; changed = true }
        if let isCollapsed, isCollapsed != group.isCollapsed { group.isCollapsed = isCollapsed; changed = true }
        guard changed else { return }
        notifyObservers { $0.tabStoreDidUpdateTabGroup(group, in: space) }
        scheduleSave()
    }

    /// Moves the whole group so its first member lands at `destinationIndex`
    /// of the list without the group (Chrome's `tabGroups.move` index; past
    /// the end means the end). An index inside another group or a split snaps
    /// forward past it.
    func moveTabGroup(_ groupID: UUID, to destinationIndex: Int, in space: Space) throws {
        guard let group = space.tabGroup(id: groupID) else { throw TabGroupError.groupNotFound(groupID) }
        let members = space.members(ofTabGroup: groupID)
        guard let originalStart = space.tabs.firstIndex(where: { $0.tabGroupID == groupID }) else { return }
        var list = space.tabs.filter { $0.tabGroupID != groupID }
        let gap = snappedOutOfTabGroups(max(0, min(destinationIndex, list.count)), slots: tabSlots(list))
        guard gap != originalStart else { return }
        list.insert(contentsOf: members, at: gap)
        space.tabs = list
        notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        notifyObservers { $0.tabStoreDidMoveTabGroup(group, in: space) }
        scheduleSave()
    }

    /// The normal tabs of `space` named by `ids`, in list order, with the
    /// partner of every split pane among them. Throws before anything changes.
    private func groupableTabs(_ ids: [UUID], in space: Space) throws -> [BrowserTab] {
        guard !ids.isEmpty else { throw TabGroupError.noTabs }
        var chosen = Set<UUID>()
        for id in ids {
            guard let tab = space.tabs.first(where: { $0.id == id }) else {
                // A pinned entry's or a favourite's live tab.
                if space.displayableTab(id: id) != nil { throw TabGroupError.tabNotGroupable(id) }
                throw TabGroupError.tabNotFound(id)
            }
            chosen.insert(id)
            if let split = tab.splitGroupID {
                for partner in space.tabs where partner.splitGroupID == split { chosen.insert(partner.id) }
            }
        }
        return space.tabs.filter { chosen.contains($0.id) }
    }

    // MARK: - Helpers for every tab mutation

    func tabSlots(_ tabs: [BrowserTab]) -> [TabSlot] {
        tabs.map { TabSlot(splitGroupID: $0.splitGroupID, tabGroupID: $0.tabGroupID) }
    }

    /// Where a block entering `space.tabs` at `gap` lands, and its group. The
    /// block must not be in `space.tabs`.
    func placement(forGap gap: Int, intent: TabGroupIntent, in space: Space) -> TabGroupPlacement {
        Detour.tabGroupPlacement(gap: gap, slots: tabSlots(space.tabs), intent: intent)
    }

    /// The intent of a block of existing tabs moving within `space`, taken out
    /// of `space.tabs` already: it carries its group when it is the whole of
    /// it, and otherwise keeps it only while it lands next to a member.
    func movingIntent(for block: [BrowserTab], in space: Space) -> TabGroupIntent {
        guard let group = block.first?.tabGroupID else { return .byPosition(preferring: nil) }
        return space.tabs.contains { $0.tabGroupID == group } ? .byPosition(preferring: group) : .carry(group)
    }

    /// The intent `rule` gives a block of existing tabs re-entering `space`,
    /// taken out of `space.tabs` already. A `.restoring` rule may recreate its
    /// group, so call it only once the block is sure to be put back.
    func intent(for rule: TabMoveGroupRule, block: [BrowserTab], in space: Space) -> TabGroupIntent {
        switch rule {
        case .moving: movingIntent(for: block, in: space)
        case .restoring(let snapshot): restoringIntent(snapshot, in: space)
        }
    }

    /// The intent of a new tab opened from `parentID`: it joins the opener's
    /// group when it lands next to a member (Chrome's rule for tabs opened
    /// from a grouped tab).
    func openedTabIntent(parentID: UUID?, in space: Space) -> TabGroupIntent {
        .byPosition(preferring: parentID.flatMap { id in space.tabs.first { $0.id == id }?.tabGroupID })
    }

    /// The group `tab` is in, as an undo needs it to bring the group back.
    func tabGroupSnapshot(of tab: BrowserTab, in space: Space) -> TabGroupSnapshot? {
        tab.tabGroupID.flatMap { space.tabGroup(id: $0)?.snapshot }
    }

    /// The intent of an undo putting back a tab that was in `snapshot`'s
    /// group: back into it. When the undone action removed the group, the
    /// placement carries it (a rejoin of a group with no members), and
    /// `reinstateTabGroup` brings the record back once the tab is in.
    func restoringIntent(_ snapshot: TabGroupSnapshot?, in space: Space) -> TabGroupIntent {
        snapshot.map { .rejoin($0.id) } ?? .byPosition(preferring: nil)
    }

    /// The second half of a restoring placement: recreates `snapshot`'s group,
    /// same id, title, colour and collapsed state (user decision, 2026-11-07),
    /// when the undone action removed it and a tab is in it again. Call after
    /// the tab is in `space.tabs` with its group and before its insertion or
    /// reorder is reported, so no observer sees a group without members.
    func reinstateTabGroup(_ snapshot: TabGroupSnapshot?, in space: Space) {
        guard let snapshot, space.tabGroup(id: snapshot.id) == nil,
              space.tabs.contains(where: { $0.tabGroupID == snapshot.id }) else { return }
        // An id the space does not have cannot belong to another space: group
        // ids are fresh UUIDs, and a group never moves between spaces.
        let group = snapshot.makeGroup()
        space.tabGroups.append(group)
        notifyObservers { $0.tabStoreDidCreateTabGroup(group, in: space) }
    }

    /// Sets `tabs`' group. With `announce` (existing tabs), a real change is
    /// reported by the next `settleTabGroups`; a new tab's insertion already
    /// carries its group, so it passes false.
    func assignTabGroup(_ groupID: UUID?, to tabs: [BrowserTab], announce: Bool = true) {
        for tab in tabs where tab.tabGroupID != groupID {
            if announce, !pendingTabGroupMembershipChanges.contains(where: { $0.tab === tab }) {
                pendingTabGroupMembershipChanges.append((tab, tab.tabGroupID))
            }
            tab.tabGroupID = groupID
        }
    }

    /// `tab` is leaving `space.tabs`. A closed tab passes `announce: false`:
    /// its removal is the whole story.
    func leaveTabGroup(_ tab: BrowserTab, announce: Bool = true) {
        assignTabGroup(nil, to: [tab], announce: announce)
    }

    /// Ends a mutation: reports the tabs whose group really changed, then
    /// removes (and reports) the groups of `spaces` left with no member.
    func settleTabGroups(in spaces: Space...) {
        let pending = pendingTabGroupMembershipChanges
        pendingTabGroupMembershipChanges = []
        let changed = pending.filter { $0.tab.tabGroupID != $0.original }.map(\.tab)
        if !changed.isEmpty {
            notifyObservers { $0.tabStoreDidChangeTabGroupMembership(of: changed) }
        }
        for space in spaces {
            let memberGroupIDs = Set(space.tabs.compactMap(\.tabGroupID))
            let emptied = space.tabGroups.filter { !memberGroupIDs.contains($0.id) }
            guard !emptied.isEmpty else { continue }
            space.tabGroups.removeAll { !memberGroupIDs.contains($0.id) }
            for group in emptied {
                notifyObservers { $0.tabStoreDidRemoveTabGroup(group, in: space) }
            }
        }
    }

    /// Restores the invariants on a list loaded from disk or rebuilt by Undo
    /// Delete Space, silently: nothing has observed the space yet. Run after
    /// `sanitizeSplitGroups`.
    func sanitizeTabGroups(in space: Space) {
        let ids = sanitizedTabGroupIDs(tabSlots(space.tabs), knownGroupIDs: Set(space.tabGroups.map(\.id)))
        for (tab, id) in zip(space.tabs, ids) { tab.tabGroupID = id }
        let memberGroupIDs = Set(ids.compactMap { $0 })
        space.tabGroups.removeAll { !memberGroupIDs.contains($0.id) }
    }
}
