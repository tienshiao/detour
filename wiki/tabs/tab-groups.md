---
type: Concept
title: Tab groups
description: The tab group model behind chrome.tabGroups (a TabGroup per space, membership on the tab), the four invariants TabStore keeps in every mutation, the one placement rule every insertion goes through, what each existing mutation does to a member, undo, observers and persistence.
tags: [tabs, tab-groups, invariants, tabstore, split, persistence]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-07T23:40:00Z }
sources:
  - id: model
    resource: ../../Detour/Browser/TabGroup.swift
    title: TabGroup.swift (model, colours, pure placement rules, sanitizer)
  - id: store
    resource: ../../Detour/Browser/TabStore+TabGroups.swift
    title: TabStore+TabGroups.swift (store API and the helpers mutations use)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (every tab mutation)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (migration v23, tab group save and load)
  - id: placement-tests
    resource: ../../DetourTests/TabGroupPlacementTests.swift
    title: TabGroupPlacementTests.swift
  - id: store-tests
    resource: ../../DetourTests/TabGroupStoreTests.swift
    title: TabGroupStoreTests.swift
  - id: task
    resource: backlog:TASK-132.10
    title: "Tabs: tab group model in TabStore (membership, title, colour, collapsed) with persistence"
  - id: stripe-rule
    resource: ../../Detour/Browser/Sidebar/TabListItems.swift
    title: TabListItems.swift (TabGroupStripe and the stripe rule)
  - id: color-view
    resource: ../../Detour/Browser/Sidebar/TabGroupColorView.swift
    title: TabGroupColorView.swift (colour names drawn as system colours)
  - id: task-stripe
    resource: backlog:TASK-132.11
    title: "Sidebar: colour stripe on tab rows that belong to a tab group"
---

# Summary

Tab groups exist for the Claude extension, which puts its session's tabs in
one `chrome.tabGroups` group and acts only on the tabs in it
(TASK-132).[^task] Like a [split](./split-tabs.md), a group is mostly a
shared id on tabs: `BrowserTab.tabGroupID` names a `TabGroup` in
`Space.tabGroups`, which holds the group's own state (title, one of Chrome's
nine colour names, collapsed). There is no user-facing way to make a group
yet. The extension API is the [tab groups API](../extensions/tab-groups-api.md)
(TASK-132.12) and header rows TASK-132.19; the sidebar shows a group as a
stripe on its members' rows (TASK-132.11, see [In the sidebar](#in-the-sidebar)).

# Invariants

1. A group's members are **contiguous** in `space.tabs` (Chrome's are, and
   header rows need it).
2. A **split pair** is wholly inside or wholly outside one group.
3. Only **normal tabs** are members. Pinned backing tabs, favourites, Peeks
   and Quick Detours always have nil. Pinning, making a favourite and
   moving to another space take a tab out (Chrome ungroups on pin).
4. A group with **no members** does not exist: the mutation that empties it
   removes it.

As with splits, nothing asserts these at run time. They hold by
construction, the tests check them after each mutation, and
`sanitizeTabGroups(in:)` restores them on a list loaded from disk or rebuilt
by Undo Delete Space.[^model]

# One placement rule

Every block (a lone tab, or both panes of a split) that enters `space.tabs`
gets its slot and group from the pure `tabGroupPlacement(gap:slots:intent:)`,
given the list without the block:

| Intent | Used by | Result |
|---|---|---|
| `byPosition(preferring:)` | new tabs, moves, unpin, reopen, Move to Space | between two members of one group: joins it; otherwise keeps `preferring` only if it lands next to a member of it; otherwise ungrouped |
| `rejoin(id)` | undo of a close or a move | the gap is clamped into the group's current range |
| `carry(id)` | a block that is the whole group | the group goes with it; the gap snaps out of any other group's interior |

The gap first snaps out of split interiors, as before. Two consequences of
`byPosition`:

- **At a group's edge, the block's own group decides.** A tab already in the
  group stays in it; an outsider stays out. Drag handling with no header row
  gets a stable answer at the boundary that way.
- **A tab opened from a grouped tab joins the group** when it lands next to a
  member, because its `preferring` is its opener's group (user decision,
  2026-11-07, Chrome's behaviour). It does not join if it follows the
  opener's earlier children placed outside the group.

Moving the only member of a group carries the group, so a one-tab group (the
Claude extension's usual start) survives a drag.

# What each mutation does

| Mutation | Effect on groups |
|---|---|
| `closeTab` (also archive, and the timer archive) | leaves its group; the last member's close removes it |
| `closeSplitGroup` | both panes leave |
| `pinTab`, `pinSplitGroup`, `detachTab` (to a favourite) | the tab leaves; reported as a membership change. The pin undos put it back (see Undo) |
| `moveTab(id:from:to:at:)` to another space | leaves the source group; joins a destination group only between two members |
| `moveTab` within the space | `movingIntent`: `carry` when the block is the whole group, else `byPosition(preferring: own group)` |
| `insertTab` (every new tab, Quick Detour hand-off) | `byPosition(preferring: opener's group)` |
| `createSplit` | the dragged tab takes the target's group (a pair shares one) |
| `addTabInSplit` | the new pane takes the anchor's group |
| `removeTabFromSplit`, `unpinTab`, `unpinSplitGroup`, `restoreFavoriteAsTab`, `reopenClosedTabRecord` | `byPosition` |
| `separateSplit` | both panes keep their group; the undo rejoins only when they still share one |

`reopenClosedTabRecord` (Cmd+Shift+T, the Archived Tabs page) has no group to
restore: `closedTab` rows keep no group.

# Group API

`createTabGroup(tabIDs:title:color:isCollapsed:in:)`,
`addTabs(_:toTabGroup:in:)`, `ungroupTabs(_:in:)`,
`updateTabGroup(_:title:color:isCollapsed:in:)` and
`moveTabGroup(_:to:in:)` follow Chrome's `TabStripModel`:[^store]

- A new group gathers its tabs, in list order, where the first of them is;
  inside another group it lands just past that group.
- Tabs joining an existing group go to its left edge if they were left of
  it, and to its right edge if they were right of it.
- An ungrouped tab between two staying members moves past the group's right
  edge; one already at either edge stays where it is.
- `moveTabGroup` takes Chrome's index (where the first member lands in the
  list without the group) and snaps past another group or a split.
- With no colour given, a new group gets the first colour in Chrome's order
  that the space uses least.
- A split pane brings its partner. A pinned tab or a favourite
  (`tabNotGroupable`), another space's tab or an unknown id (`tabNotFound`),
  or an unknown group (`groupNotFound`) throws, and nothing changes.

None of these register an undo: no user gesture makes them yet.

# Undo

The undo of a close (`closeTab`, `closeSplitGroup`), of a move (within the
space, to another space, `createSplit`) and of a pin (`pinTab`,
`pinSplitGroup`) keeps a `TabGroupSnapshot` of the tab's group. When the
group still exists the tab goes back into it, clamped into its current range
if the group moved. When the action removed the group, the undo recreates it
with the same id, title, colour and collapsed state (user decision,
2026-11-07; the acceptance criterion only asked for a group that still
exists). Making a favourite and Reopen Closed Tab do not restore a group.

The restore is two steps so that no observer ever sees a group without
members: `restoringIntent` places the tab (a `rejoin` of a group with no
members carries it), and `reinstateTabGroup` puts the group record back once
the tab is in the list, before the insertion or reorder is reported. So an
undo that brings a group back reports `tabStoreDidCreateTabGroup`, then the
tab's insertion.

# Observers

| Callback | When |
|---|---|
| `tabStoreDidCreateTabGroup` | `createTabGroup`; a group an undo recreates (already holding its tab, before the tab's insertion is reported); each group of a space Undo Delete Space restores |
| `tabStoreDidUpdateTabGroup` | a real change of title, colour or collapsed |
| `tabStoreDidMoveTabGroup` | `moveTabGroup`, and a tab move that carries a whole group, after `tabStoreDidReorderTabs` |
| `tabStoreDidChangeTabGroupMembership(of:)` | existing tabs whose group really changed, after the mutation's structural callbacks |
| `tabStoreDidRemoveTabGroup` | a group emptied by the mutation (after the membership callback), and each group of a deleted space |

A new tab placed straight into a group reports only its insertion, and a
closed tab only its removal. The mechanism: `assignTabGroup(_:to:announce:)`
records each existing tab's first group, and `settleTabGroups(in:)` at the
end of a mutation reports the ones that differ, then prunes empty groups.
A new mutation path that forgets `settleTabGroups` leaves an empty group
behind until the next mutation of that space.

# Persistence

Migration v23 adds `tab.tabGroupID` and the `tabGroup` table (FK to `space`,
cascade). Groups are saved per space after the session rows, and within the
space's savepoint in the isolating fallback.[^database] `tab.tabGroupID` has
no foreign key: tab rows go in before group rows, and load clears an id that
names no group. The migration is registered on the `epic-claude-extension`
branch, so whoever merges the branch into main renumbers it after main's own
migrations. Incognito spaces are not saved, so their groups end with them.

# In the sidebar

A member's row carries a 3 pt stripe in the group's colour, in the 10 pt
gutter between the tab list's edge and the row highlight; there is no header
row yet.[^task-stripe]

- **Which rows.** The pure `tabGroupStripe(at:in:groups:)` in
  [TabListItems.swift](../../Detour/Browser/Sidebar/TabListItems.swift)
  decides, per tab-list item: a row has a stripe when every tab in it names
  the same `tabGroupID` and that id is a group of the space. A split row is
  one item, so it shows the stripe once for the pair. A pair whose panes
  disagree, or an id naming no group, gets none (rendering never trusts group
  data, as with splits). Pinned rows, favourites and the New Tab row never
  have one.
- **One bar per group.** The stripe runs the row's full height into an
  adjacent row of the same group (`continuesAbove` / `continuesBelow`) and
  is held 7 pt in, with rounded ends, at the group's first and last rows. Two
  adjacent groups of the same colour stay two bars.
- **Where.** In the gutter, the selection, the hover background, the
  progress bar and the dev-mode border never reach it, and it covers none of
  them; the drag image (the cell widened by 6 pt) leaves it out, since the
  drop decides the dragged row's group. It has no constraints and changes no
  row height; an ungrouped row has no stripe view at all (made on first use).
- **Colours.** Each of Chrome's names is the macOS system colour of that
  name (`systemGray`, `systemBlue`, …, `systemCyan`, `systemOrange`):
  `TabGroupColor.displayColor` in
  [TabGroupColorView.swift](../../Detour/Browser/Sidebar/TabGroupColorView.swift).
  `TabGroupColorView` resolves it in `updateLayer` against plain light or
  dark (keeping increased contrast), because the vibrant sidebar's rows and
  its selected row resolve system colours differently ([AppKit
  gotchas](../platform/appkit-gotchas.md)).
- **The title.** The [tab hover card](../features/tab-hover-card.md) of a
  member row names the group above the page title: a dot in its colour and
  the title, "Unnamed group" for an empty one (Chrome's words). The stripe
  is also an accessibility element labelled "Tab group: <title>".
- **Updates in place.** Insert, remove and reorder callbacks already run
  `applyState`, which reconfigures every visible row, stripe included. The
  window answers the five group callbacks with
  `TabSidebarViewController.refreshTabGroupStripes()`, which sets each
  visible row's stripe on its existing cell (no reload), or with
  `inactiveSpaceContentDidChange()` for another space. Groups are read live
  from the page's space in `TabStore` (`tabGroupsForTableView`), like its
  profile, since the rows' tabs carry their live `tabGroupID` anyway.

# Decisions and their alternatives

- **Contiguous members**, not free membership: Chrome's model, required by
  TASK-132.19's header rows, and it lets one positional rule decide
  membership.
- **Membership on the tab** (like `splitGroupID`), not a member list on the
  group: every existing mutation already moves tabs, and a list would need
  updating in each of them.
- **Recreate the group on undo** instead of leaving the tab ungrouped: the
  tab comes back as it was (user).
- **Join the opener's group**, rather than only an explicit `tabs.group`
  adding tabs: Chrome's behaviour, and the Claude extension then sees pages
  its agent tabs open (user).
- **Stripes before header rows**, one stripe per member row visible without
  selecting it, the colour shown nowhere else (user, TASK-132.11).
- **System colours, not Chrome's hex palette**: they come with light, dark
  and increased-contrast variants made for the system's own backgrounds; the
  names match one to one. Chrome's palette would need its own dark and
  contrast values.
- **A joined bar, not a capsule per row**: without a header row the bar is
  what shows where a group starts and ends, and it keeps two same-coloured
  neighbours apart.
- **In the gutter, not inside the highlight**: inside, it would sit under
  the selection tint and over the dev-mode border, and a reused cell would
  need both reconciled.
- **The hover card for the title, not a tooltip**: sidebar rows have no
  tooltips since the hover card replaced them, and a 3 pt stripe is too
  narrow to hover on purpose.

[^task]: TASK-132.10 in Backlog, and the epic TASK-132.
[^model]: `Detour/Browser/TabGroup.swift`.
[^store]: `Detour/Browser/TabStore+TabGroups.swift`.
[^database]: `Detour/Storage/Database.swift`, migration `v23`.
[^task-stripe]: TASK-132.11 in Backlog: the stripe, its colours and the hover card line.
