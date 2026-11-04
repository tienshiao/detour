---
type: Concept
title: Sidebar row layout
description: How a sidebar table row maps to a pinned item or a tab-list item, why an item index is not a tab index, and the pure functions every conversion must go through.
tags: [sidebar, layout, split-tabs, invariants]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T17:17:19Z }
sources:
  - id: sidebar-layout
    resource: ../../Detour/Browser/Sidebar/SidebarLayout.swift
    title: SidebarLayout.swift
  - id: tab-list-items
    resource: ../../Detour/Browser/Sidebar/TabListItems.swift
    title: TabListItems.swift
  - id: flattener
    resource: ../../Detour/Browser/Sidebar/PinnedTreeFlattener.swift
    title: PinnedTreeFlattener.swift
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift
  - id: layout-tests
    resource: ../../DetourTests/SidebarLayoutTests.swift
    title: SidebarLayoutTests.swift
  - id: split-tests
    resource: ../../DetourTests/SplitTabTests.swift
    title: SplitTabTests.swift
  - id: flattener-tests
    resource: ../../DetourTests/PinnedTreeFlattenerTests.swift
    title: PinnedTreeFlattenerTests.swift
  - id: task-82
    resource: backlog:TASK-82
    title: Mid-swipe space page renders pinned rows from the active space
  - id: commit-b9ef265
    resource: commit:b9ef265
    title: "Sidebar: ID-based drag payloads, pure drop resolver, drag fixes"
---

# Summary

Each space page in the [sidebar](./overview.md) is one single-column
`NSTableView`. Its rows are a fixed frame of chrome rows around two variable
sections, and neither section is indexed the way `TabStore` indexes its
arrays: the pinned section is a *flattened tree*, and the tab section is a
list of *items* in which a [split](../tabs/split-tabs.md) is one row holding
two tabs. Every conversion between a table row, an item index and a tab index
goes through a pure function. Arithmetic written inline in the view
controller is the bug this page exists to prevent.

# Row structure

With `P` flattened pinned items and `N` tab-list items:

| Row | `SidebarRow` | Height | Selectable | Notes |
|---|---|---|---|---|
| `0` | `.topSpacer` | 2 | no | Drop target for "top of the pinned section" |
| `1 … P` | `.pinnedItem(index:)` | 36 | yes | Index into the flattened `[PinnedItem]`; a folder row toggles and deselects |
| `P + 1` | `.separator` | 12 | no | Drop target for "end of the pinned section" |
| `P + 2` | `.newTab` | 36 | yes | Selecting it opens the command palette, then deselects |
| `P + 3 … P + 2 + N` | `.normalTab(index:)` | 36 | yes | Index into `[TabListItem]` — an **item** index |

Row heights do not depend on a row's content. A [dev-mode](../features/dev-mode.md)
row's second line (the host) fits inside the 36 pt row by moving the title
up, so it changes nothing here.

The whole mapping is four functions in
[SidebarLayout.swift](../../Detour/Browser/Sidebar/SidebarLayout.swift):
`sidebarRow(for:pinnedItemCount:)`, `rowForPinnedItem(at:)`,
`rowForNormalTab(at:pinnedItemCount:)` and
`totalSidebarRowCount(pinnedItemCount:itemCount:)`.

# The index spaces

Five different integers describe "where" in the sidebar. Mixing two of them
compiles and usually works until a split or a folder is on screen.

| Space | Indexes into | Who speaks it |
|---|---|---|
| Table row | the `NSTableView` | AppKit callbacks only |
| Pinned flat index | `flattenedPinnedItems: [PinnedItem]` | `.pinnedItem(index:)`, `SidebarDropDestination.beforePinnedItem(flatIndex:)` |
| Pinned entry index | `space.pinnedEntries` | `TabSidebarDelegate` (`didSelectPinnedTabAt`, `didRequestClosePinnedTabAt`), the `selectedPinnedTabIndex` setter |
| Item index | `tabItems: [TabListItem]` | `.normalTab(index:)`, `SidebarDragSource.normalTab(index:)` / `.splitGroup(index:)`, `.beforeNormalTab(gapIndex:)`, `SidebarDropCommand` gap indices |
| Tab index | `space.tabs` | `TabSidebarDelegate` (`didSelectTabAt`, `didRequestCloseTabAt`, `didMoveTab … toGapIndex`), `selectedTabIndex`, `TabStore` |

Example: tabs `[A, B, C, D]` where B and C share a `splitGroupID` render as
items `[A, (B|C), D]`. D is item 2 and tab 3. The gap after the split is
item gap 2 and tab gap 3. `SplitTabTests.testItemIndexConversions` pins
exactly this case.

The conversions, all in
[TabListItems.swift](../../Detour/Browser/Sidebar/TabListItems.swift):

| Function | From → to |
|---|---|
| `tabListItems(from:)` | `[BrowserTab]` → `[TabListItem]` (`.single` or `.split(groupID:members:)`) |
| `itemIndex(forTabIndex:in:)` | tab index → item index |
| `itemIndex(containingTabID:in:)` | tab ID → item index |
| `firstTabIndex(forItemIndex:in:)` | item index → index of the item's first tab |
| `tabGapIndex(forItemGap:in:)` | item gap (`0…items.count`) → tab gap (`0…tabs.count`) |

`TabSidebarViewController.tabs` recomputes `tabItems` in its `didSet`, so the
two can never drift; `space.tabs` stays the source of truth.

# Rules

1. **No inline row math.** Go through `SidebarLayout.swift` and
   `TabListItems.swift`. The view controller's own `sidebarRow(for:)`,
   `rowForNormalTab(at:)` and `rowForPinnedItem(at:)` are thin wrappers that
   fill in the current pinned count.
2. **`.normalTab(index:)` is an item index, never a tab index.** To reach a
   tab, index `tabItems` and take the member; to reach `space.tabs`, convert.
3. **Convert at the delegate boundary.** The pure
   [drop resolver](./drag-and-drop.md) works in item space; the delegate and
   `TabStore` work in tab space. `acceptDrop` converts each gap with
   `tabGapIndex(forItemGap:in:)` as it issues the delegate call. The store's
   `moveTab(id:toGapIndex:in:)` takes a *pre-removal* tab gap and does the
   rest itself, because only the store knows the moved block's width (a split
   row moves two tabs).
4. **A split row stands for one representative member.** The delegate API is
   single-tab, so selecting, titling or copying from a split row resolves the
   representative: the selected pane if it is in the group, else the left
   pane (`representativeTab(for:)`, `representativePinnedEntry(of:)`).
5. **Rendering never trusts group data.** `tabListItems` and
   `flattenPinnedTree` render a group ID whose run has one member as a plain
   row. The load-time sanitizers (`sanitizeSplitGroups`,
   `sanitizePinnedSplitGroups`) clear such IDs, but a renderer that assumed
   they had run would crash on a hand-edited database.
6. **One run scan.** `splitRuns(of:groupID:)` is the only code that decides
   adjacency. Tab items, pinned flattening, block moves and both sanitizers
   use it; `validSplitGroupIDs(in:)` defines a valid group as exactly one run
   of exactly two.
7. **Row count and cell content come from the same source, per table.** The
   data source serves every space page, not only the active one, so
   `numberOfRows`, `heightOfRow` and `viewFor` all read through
   `pinnedItemsForTableView(_:)` / `tabItemsForTableView(_:)`. Reading the
   count per page and the content from the active space produced blank and
   mis-sized rows mid-swipe.[^task-82] See [space paging](./space-paging.md).
8. **Never capture an index in a closure.** Cell close handlers call
   `tableView.row(for: cell)` at click time and re-resolve through
   `sidebarRow(for:)`; context menus store the target's UUID
   (`contextMenuTabID`) and look it up when the action fires. Stored indices
   went stale while a menu was open and could target the wrong tab.[^commit-b9ef265]

One asymmetry to know: `selectedPinnedTabIndex`'s setter takes an index into
`pinnedEntries`, but its getter returns the selected row's *flat* index. Only
the setter is used by the window controller.

# Pinned tree flattening

`flattenPinnedTree(entries:folders:collapsedFolderIDs:selectedTabID:)` turns
the [pinned entries and folders](../tabs/pinned-tabs-and-folders.md) of a
space into `[PinnedItem]`: `.entry(_, depth:)`, `.folder(_, depth:)` or
`.split(groupID:entries:depth:)`.

- Entries and folders at one level are merged and ordered by `sortOrder`
  (one sort-order space per sibling level), then walked depth-first.
- A collapsed folder contributes its own row and nothing below it, with one
  exception: if the selected tab is anywhere inside (nested folders
  included), its entry is exposed as a row at `depth + 1`. This is why the
  flattener takes `selectedTabID`, and why the controller must pass the same
  selection it is about to show.
- If that exposed entry is a member of a pinned split, the whole `.split`
  item is exposed. A lone `.entry` row would drag as a single tab while
  `TabStore.movePinnedTabToFolder` block-moves both members, silently pulling
  the hidden partner out of the folder.
- A folder sorted between two members of a group breaks their run, so they
  render as two plain entries.

Two helpers translate a flat drop index back to tree terms, and are the only
place that rule lives:

- `folderIDForDropIndex(_:in:)` — the folder a drop *above* that item joins:
  the item's own parent when it sits at `depth > 0`, else `nil` (top level,
  also past the end).
- `itemIDAtDropIndex(_:in:)` — the sibling the dropped item goes before. For
  a split it is the **first** member's entry ID, so nothing can land inside
  the pair.

Consequence: the gap below a folder's last child belongs to the next
top-level item, so a drop there lands at the top level. Appending to a folder
is a drop *on* the folder row.

# Diffing

`TabSidebarViewController.applyState` does not reload the table. It calls
`diffSidebarState(oldPinnedItems:newPinnedItems:oldTabs:newTabs:)` and feeds
the result to `removeRows` / `insertRows` / `moveRow` inside one
`beginUpdates` block, swapping the model before `endUpdates`.

- **Identity** is `TabListItem.itemID` and `pinnedItemID(_:)`: the tab,
  entry or folder ID, and the **group ID** for a split in either section.
  Pinning or unpinning a whole split therefore diffs as one row changing
  section, not a remove and an insert.
- **Moves** are computed per section with a longest-increasing-subsequence
  pass: items in the LIS stay, the rest move. Moves are sorted by destination
  ascending because `NSTableView` applies them sequentially, and ties prefer
  keeping lower old indices stable, which makes the dragged row the one that
  moves.
- **Split continuation.** A group that forms or dissolves in one update is
  aliased to the member row it morphs from or into
  (`splitContinuationAliases`), so that row stays in place and only the other
  member's row is inserted or removed. The chosen member is the single row
  nearest the group's index; ties go to the later row. The cell then animates
  the change inside the row ([tab cell](./tab-cell.md)).

`resetState` is the non-diffing variant, used for a space switch: it sets the
model and calls `reloadData()`.

# Where it lives

| File | Holds |
|---|---|
| [SidebarLayout.swift](../../Detour/Browser/Sidebar/SidebarLayout.swift) | `SidebarRow`, row ↔ index functions, `SidebarDiff`, `diffSidebarState` |
| [TabListItems.swift](../../Detour/Browser/Sidebar/TabListItems.swift) | `TabListItem`, `splitRuns`, item ↔ tab conversions, `sanitizeSplitGroups` |
| [PinnedTreeFlattener.swift](../../Detour/Browser/Sidebar/PinnedTreeFlattener.swift) | `PinnedItem`, `flattenPinnedTree`, drop-index helpers, `sanitizePinnedSplitGroups` |

All three import only Foundation. Tests: `SidebarLayoutTests` (row mapping,
round trips, every diff case), `SplitTabTests` (items, conversions, gap
moves), `PinnedTreeFlattenerTests` (collapse, exposure, drop-index helpers).
Extend these suites when changing row behaviour; the project's testing
rule for shared rules is in [CLAUDE.md](../../CLAUDE.md).

# Related

- [Sidebar overview](./overview.md) — the controller these functions serve.
- [Sidebar drag and drop](./drag-and-drop.md) — the resolver that consumes rows and produces item gaps.
- [Split tabs](../tabs/split-tabs.md) — the contiguity invariant that makes "adjacent run" a valid definition of a split.
- [Pinned tabs and folders](../tabs/pinned-tabs-and-folders.md) — the tree being flattened.
- [Tab switching](../tabs/tab-switching.md) — `TabNavigation` walks the same flattened items and tab items.

[^task-82]: Mid-swipe space page renders pinned rows from the active space
[^commit-b9ef265]: Sidebar: ID-based drag payloads, pure drop resolver, drag fixes
