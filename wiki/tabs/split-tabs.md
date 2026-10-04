---
type: Concept
title: Split tabs
description: The data model of a split (two adjacent tabs sharing a splitGroupID), the contiguity invariants TabStore keeps in every mutation, and where a pinned split's group lives.
tags: [tabs, split, invariants, tabstore, pinned]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:43:31Z }
sources:
  - id: design
    resource: ../../docs/split-tabs-design.md
    title: Split Tabs design document (sections 2 to 4 and 12)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (Split Tab Mutations, Pinned Split Mutations)
  - id: items
    resource: ../../Detour/Browser/Sidebar/TabListItems.swift
    title: TabListItems.swift (splitRuns, validSplitGroupIDs, sanitizeSplitGroups)
  - id: insertion
    resource: ../../Detour/Browser/TabInsertion.swift
    title: TabInsertion.swift (snap and block moves)
  - id: flattener
    resource: ../../Detour/Browser/Sidebar/PinnedTreeFlattener.swift
    title: PinnedTreeFlattener.swift (pinned split items, sanitizePinnedSplitGroups)
  - id: entry
    resource: ../../Detour/Browser/PinnedEntry.swift
    title: PinnedEntry.swift
  - id: record-factory
    resource: ../../Detour/Browser/TabRecord+BrowserTab.swift
    title: TabRecord+BrowserTab.swift
  - id: tests
    resource: ../../DetourTests/SplitTabTests.swift
    title: SplitTabTests.swift
  - id: task-38
    resource: backlog:TASK-38
    title: Move to Space loses extension pages (rebuilds the tab in the space configuration)
---

# Summary

A split is **not an object**. It is two tabs that carry the same
`splitGroupID`. Everything else (one sidebar row, two panes in the window, one
stop for keyboard navigation) is derived from that. The model only works
because `TabStore` keeps the members adjacent and exactly two in every
mutation; this page is the list of those rules. The window side is
[split tab hosting](./split-tabs-hosting.md); the reasons are in
[two-pane splits](../decisions/two-pane-splits.md) and
[splits survive pinning](../decisions/splits-survive-pinning.md).

# The model

| Kind | Where the group lives | Members |
|---|---|---|
| Normal split | `BrowserTab.splitGroupID` / `splitFraction` on two tabs in `space.tabs` | the two tabs, left pane first |
| Pinned split | `PinnedEntry.splitGroupID` / `splitFraction` on two entries | the two entries; **their backing tabs' `splitGroupID` stays nil** |

`splitFraction` is the left pane's share of the width. Both members store the
same value and readers take the first member's. `setSplitFraction` clamps it to
0.2…0.8, writes to whichever side owns the group, registers no undo, and fires
`tabStoreDidUpdateSplitLayout` (the only split-specific observer callback;
structural changes arrive as the ordinary insert, remove and reorder
callbacks).

## One function resolves both kinds

`TabStore.splitGroup(containing:in:)` takes a **tab** id and returns
`(groupID, members: [BrowserTab])` for either kind. For a pinned split the
members are the entries' *live* tabs in `sortOrder` order.

A dormant pinned member is therefore **absent** from `members`. A pinned split
with one dormant side resolves to a one-element group until selection wakes the
other entry, and callers that test `members.count == 2` see a single pane in
the meantime. `splitFraction(containing:in:)` is the matching reader for the
fraction. Use these two; do not read `tab.splitGroupID` to ask "is this tab in
a split", because it is nil for every pinned split member.

# Invariants

For a normal split:

1. A group has **exactly two** members.
2. The members are **adjacent** in `space.tabs`, in visual order (left first).
3. A tab is in at most one group.
4. A group of one does not exist: it is dissolved in the same mutation.

For a pinned split:

5. Exactly two entries, with the **same `folderID`**, **consecutive in sibling
   sort order**. Nothing, entry or folder, sorts between them at their level.
6. While pinned, the group is on the entries only.
7. `closePinnedTab` does **not** dissolve the group. A dormant member stays a
   member and wakes when the row is selected.

Splits are never *created* in the pinned section; they arrive there by pinning
an existing split. Favourites and Peeks are never members.

There is no runtime assertion of these. The design document mentions an
`assertSplitInvariants()` in DEBUG; it does not exist in the code. The
invariants are held by construction and checked by `SplitTabTests`.

# How each mutation keeps them

## Insertions snap out of group interiors

`snappedToSplitGroupBoundary(_:groupIDs:)` moves an index that falls between
two members forward to just past the group. It is applied by `insertTab`,
`restoreFavoriteAsTab`, the `closeTab` and `closeSplitGroup` undos,
`reopenClosedTabRecord`, `unpinTab`, `unpinSplitGroup`, `removeTabFromSplit`
and the cross-space `moveTab`. A new insertion path that forgets it can put a
tab between two panes.

## Moves move the block

`moveTab` goes through `resolveTabMove`: moving either member moves both, and a
destination inside another group snaps past it
([tab insertion and close selection](./tab-insertion-and-close-selection.md)).
The drop entry point takes a pre-removal gap and lets the store convert it,
because only the store knows the block is two tabs wide.

## Every exit runs through `leaveSplitGroup`

`leaveSplitGroup(_:in:)` clears the leaving tab's membership and then
`dissolveUndersizedSplitGroup` clears the partner's. It is called by
`closeTab`, `pinTab`, `detachTab` (a tab becoming a favourite),
`removeTabFromSplit`, the undo of `addTabInSplit`, and the cross-space
`moveTab`. The pinned counterpart is `dissolvePinnedSplit(around:groupID:in:)`,
called by `unpinTab` (single member), `deletePinnedEntry`,
`detachPinnedEntry`, `removePinnedEntryFromSplit` and `movePinnedEntry` (to
another space).

## Store API

| Call | Effect | Undo |
|---|---|---|
| `createSplit(draggedTabID:targetTabID:edge:fraction:in:)` | moves the dragged tab next to the target (left edge: before, right: after), fresh group id on both. Refuses if either is already grouped | `removeTabFromSplit` back to the original gap |
| `addTabInSplit(with:url:in:)` | Option-click: new tab right after the anchor, grouped, loads the URL. Returns nil unless the anchor is an ungrouped *normal* tab | removes the new tab **without** a closed-tab record (the pane never existed as a lone tab) |
| `separateSplit(groupID:in:)` | clears both; they stay adjacent as two rows | rejoins only if still adjacent and ungrouped |
| `removeTabFromSplit(tabID:toGapIndex:in:)` | one member leaves to a pre-removal gap; the group dissolves | `createSplit` on the same side with the saved fraction |
| `closeSplitGroup(groupID:in:)` | closes both as one gesture, two closed-tab records sharing one `closedAt` | one undo restores the pair |
| `pinSplitGroup(groupID:in:)` | both tabs become adjacent entries at the end of the pinned section, **keeping the group id** | `unpinSplitGroup` to the original index |
| `unpinSplitGroup(groupID:toGapIndex:in:)` | both entries become adjacent tabs with the group restored; a dormant member gets a tab. All or nothing | `pinSplitGroup` plus positional placement |
| `separatePinnedSplit(groupID:in:)` | clears both entries; they stay adjacent | rejoin, then sanitize |
| `removePinnedEntryFromSplit(entryID:folderID:beforeItemID:in:)` | a member breaks out to its own pinned row | restores the section's order snapshot |

`pinTab` on one member is **not** `pinSplitGroup`: it leaves the group first, so
the survivor becomes a plain tab.

## Pinned placement

- `movePinnedTabToFolder` moves a grouped entry's **whole pair** as a block.
- `snappedPinnedAnchor` retargets a `beforeItemID` that names the right member
  to the left member, so neither an entry nor a folder can land inside a pair.
  `placePinnedFolder` uses the same snap.
- `deletePinnedFolder` splices the folder's children into the parent level and
  renumbers. Reparenting them with their old per-level `sortOrder`s could tie
  with the parent level's numbering, and a tie interleaving into a pair renders
  the pair broken while the group survives in the model.
- `movePinnedEntry` to another space dissolves the split; both members would
  have to move together to survive.

# Undo rules worth knowing

- **Rejoins mint a new group id.** Undoing a single-pane close, a separate, or a
  "Close Both Splits" forms the split again under a fresh UUID (and the restored
  tabs have fresh ids too). Only pin and unpin of a whole split carry the group
  id across, so the sidebar diff treats it as one row moving between sections.
- A close undo rejoins only if the partner is still an ungrouped normal tab.
- "Close Both Splits" needs its own mutation because two sequential `closeTab`
  undos could not pair up: each mints fresh tab ids.
- **Reopen Closed Tab restores a split member unsplit.** `ClosedTabRecord` has
  no group field.
- Undoing "Move to Space" restores the section and index, not the split the move
  dissolved: re-forming one needs the two members adjacent, which an index
  cannot promise.[^task-38]
- `unpinSplitGroup`'s undo places the pair *positionally* (before the sibling
  that followed it). Restoring raw `sortOrder`s can collide with items pinned
  since, interleave the pair, and make the sanitizer dissolve the very group the
  undo is restoring (`testUnpinSplitGroupUndoSurvivesSortOrderCollision`).

# Persistence and the sanitizers

- Normal splits: `splitGroupID` and `splitFraction` columns on `tab`
  (migration v6). Pinned splits: the same two columns on `pinnedTab` (v7).
- `TabRecord.init(tab:…)` takes the split fields as **parameters** instead of
  reading them off the tab, because a pinned backing tab's row must not carry a
  group. Only the normal-tab call site passes them.
- Anything that snapshots a space must capture the entry fields explicitly.
  `deleteSpace`'s undo snapshot does (`EntrySnapshot.splitGroupID`); the backing
  tab's snapshot has nil there and nothing re-derives it.

One scan defines adjacency everywhere: `splitRuns(of:groupID:)` partitions a
list into maximal runs sharing a group id. `validSplitGroupIDs(in:)` accepts a
group only if it forms **exactly one run of exactly two**.

- `sanitizeSplitGroups(_:)` clears invalid groups on `space.tabs`: singleton,
  non-adjacent, or oversized (a three-member group is cleared entirely). Run at
  session restore and in the Delete Space undo.
- `sanitizePinnedSplitGroups(entries:folders:)` does the same per sibling level,
  where a folder sorted between two members breaks their run. Run at restore,
  after `deletePinnedFolder`, and in the pinned undos that restore a saved order
  or rejoin a group. The rule in those paths: never trust a snapshot over the
  invariant.
- Rendering never trusts the data either: `tabListItems` and `flattenPinnedTree`
  render a run of one as a plain row.

# What other subsystems do with a split

- **Sidebar**: one row per group. `TabListItem.split` and `PinnedItem.split`
  both use the group id as the row identity
  ([row layout](../sidebar/row-layout.md), [drag and drop](../sidebar/drag-and-drop.md)).
- **Sleep and archive**: a member sleeps only when its partner is asleep or
  eligible too; a member is archived only when the whole group is stale. The
  sweep resolves a pinned split's partner through the entries
  ([sleeping and archiving](./sleeping-and-archiving.md)).
- **Extensions**: both panes are ordinary tabs, so `tabs.query` lists both.
  That is the main reason for the model.
- **Keyboard**: a split is one stop for Cmd+Option+Up/Down and one card in the
  Control+Tab switcher ([tab switching](./tab-switching.md)).

# Where it lives

- [TabStore.swift](../../Detour/Browser/TabStore.swift): the two `MARK`
  sections "Split Tab Mutations" and "Pinned Split Mutations (§12)".
- [TabListItems.swift](../../Detour/Browser/Sidebar/TabListItems.swift):
  `SplitEdge`, `TabListItem`, `splitRuns`, `validSplitGroupIDs`,
  `sanitizeSplitGroups`.
- [TabInsertion.swift](../../Detour/Browser/TabInsertion.swift):
  `snappedToSplitGroupBoundary`, `resolveTabMove`.
- [PinnedTreeFlattener.swift](../../Detour/Browser/Sidebar/PinnedTreeFlattener.swift):
  `PinnedItem.split`, `sanitizePinnedSplitGroups`.

# Tests

`SplitTabTests` (63 cases) is the suite: the flattener and sanitizers, the snap
and block moves, every store mutation with its undo, pinned splits including
dormant members and folder deletion, and persistence across save and load.
Also `SleepShowBudgetTests` (partner rules), `ArchivedTabRestoreTests`
(restore snaps out of a group; the split-close undo with a consumed record) and
`SidebarDragDropTests`. Extend these first when changing a rule.

# Related

- [Split tab hosting](./split-tabs-hosting.md): how the window shows the two panes.
- [Two-pane splits](../decisions/two-pane-splits.md): why a shared id and not a container or a partner pointer.
- [Splits survive pinning](../decisions/splits-survive-pinning.md): why the pinned group is on the entries.
- [Pinned tabs and folders](./pinned-tabs-and-folders.md): sort order and levels that the pinned invariants are stated in.
- [TabStore](../architecture/tabstore.md): the store these mutations belong to.
- [Session database](../architecture/session-database.md): migrations v6 and v7.

[^task-38]: Move to Space loses extension pages (rebuilds the tab in the space configuration)
