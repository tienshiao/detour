---
type: Concept
title: Tab insertion and close selection
description: The two pure rules that decide where a new tab lands in a space's list and which tab is selected after one closes, plus what the window layers on top of them.
tags: [tabs, rules, pure-functions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:43:31Z }
sources:
  - id: insertion
    resource: ../../Detour/Browser/TabInsertion.swift
    title: TabInsertion.swift
  - id: close-selection
    resource: ../../Detour/Browser/TabCloseSelection.swift
    title: TabCloseSelection.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift
  - id: insertion-tests
    resource: ../../DetourTests/TabInsertionTests.swift
    title: TabInsertionTests.swift
  - id: close-tests
    resource: ../../DetourTests/TabCloseSelectionTests.swift
    title: TabCloseSelectionTests.swift
  - id: split-tests
    resource: ../../DetourTests/SplitTabTests.swift
    title: SplitTabTests.swift
---

# Summary

The normal-tab list is flat, but each tab remembers the tab it was opened from
(`BrowserTab.parentID`). Two pure functions give the list a tree-like feel
without a tree: `tabInsertionIndex` keeps a parent's children in a run right
below it, and `tabCloseSelectionID` walks siblings, then the parent, then a
neighbour. Both take `(id, parentID)` tuples and the set of pinned backing-tab
ids, so they are testable without a web view. A third function,
`snappedToSplitGroupBoundary`, keeps every insertion out of a
[split group](./split-tabs.md).

# Rules

## Where a new tab goes: `tabInsertionIndex`

| Case | Index |
|---|---|
| No parent (`parentID == nil`) | **0**, the top of the list |
| Parent is a normal tab | after the parent and after the *contiguous* run of its existing children that follows it |
| Parent is a pinned backing tab, or is not in the list | after the first run of that parent's existing children; 0 when it has none |

Consequences:

- A fresh tab from the command palette goes to the top, not the bottom.
  ([docs/tab-lifecycle.md](../../docs/tab-lifecycle.md) says "appended to the
  end"; `testNoParentReturnsIndex0` pins the real behaviour.)
- Links opened from one page stack in the order they were opened, directly
  under it.
- The scan for children stops at the first tab that is not a child. A child the
  user dragged elsewhere no longer extends the run, so later children land
  right under the parent again.
- A child of a pinned tab or favourite cannot sit under its parent (the parent
  is not in `space.tabs`), so children of such tabs collect at the top.

## The split snap: `snappedToSplitGroupBoundary`

`TabStore.insertTab` wraps the index in
`snappedToSplitGroupBoundary(_:groupIDs:)`: an index that falls between the two
members of a split moves forward to just past the group. Every other insertion
into `space.tabs` applies the same snap: restoring a favourite as a tab, the
close undos, reopen, an unpin, a move from another space, dragging a pane out
of a split. If you add a new insertion path, it must snap too, or it breaks the
contiguity invariant.

## Moving: `resolveTabMove`

Reordering is also rule-driven. Moving any member of a split moves the whole
two-tab block, and a destination inside another split snaps past it. There are
two entry points because drops and undo speak different coordinates:

- `resolveTabMove(sourceIndex:destinationIndex:groupIDs:)`: `destinationIndex`
  is where the block's first tab lands in the array *after* the block is
  removed.
- `resolveTabMove(sourceIndex:toGapIndex:groupIDs:)`: `gapIndex` is an insertion
  gap `0...count` in the array *before* removal. Only this function knows the
  block's width, which is why callers must not do a `gap - 1` themselves.

Do not add a "source equals destination, nothing to do" shortcut in front of
them. For the second member of a split the pre-removal source and the
post-removal destination can be the same number and still be a real move
(`testMoveTabNonFirstMemberEqualIndicesStillMoves`); the functions return nil
for a genuine no-op.

## Which tab is selected after a close: `tabCloseSelectionID`

In order, for the tab at `closingIndex`:

1. **Next sibling**: the first *later* tab with the same `parentID` (it does not
   have to be adjacent).
2. **Previous sibling**: the nearest *earlier* tab with the same `parentID`.
3. **Parent**, when it is a normal tab. A pinned parent is skipped here.
4. **Right neighbour**, or the left one when the closing tab is last.

It returns nil when the closing tab is the only one. A root tab (no parent)
skips straight to step 4.

## What the window adds

`BrowserWindowController.settleSelectionLeaving(tabAt:in:)` is the caller, and
it wraps the pure rule:

- **A split partner wins over everything.** Closing one pane selects the other.
- If the rule returns nil (last normal tab): the first live pinned tab, else the
  first pinned entry is activated and selected. If that entry refuses to wake
  (a disabled extension's page), the window deselects and shows the
  [refusal toast](./pinned-tabs-and-folders.md).
- With nothing left, the window shows its empty state.

Selection is settled *before* the tab leaves `space.tabs`, so the store's
removal notification finds nothing to fix. The same helper serves "Move to
Space", which takes a tab out of the list without closing it.

`parentID` is cut when a tab moves to another space (it arrives as a root tab)
and restored if the move is undone while the parent still exists.

# Where it lives

- [TabInsertion.swift](../../Detour/Browser/TabInsertion.swift):
  `tabInsertionIndex`, `snappedToSplitGroupBoundary`, both `resolveTabMove`.
- [TabCloseSelection.swift](../../Detour/Browser/TabCloseSelection.swift):
  `tabCloseSelectionID`.
- [TabStore.swift](../../Detour/Browser/TabStore.swift): `insertTab`,
  `moveTab(from:to:in:)`, `moveTab(id:toGapIndex:in:)`.

# Tests

`TabInsertionTests` (9) and `TabCloseSelectionTests` (17) cover the two rules;
the snap and the block moves are in `SplitTabTests`
(`testSnappedToSplitGroupBoundary`, `testChildTabInsertionNeverLandsInsideGroup`,
the `testResolveTabMove…` and `testGapMove…` cases). These are the suites to
extend first when the rules change: write the failing case, then change the
function.

# Related

- [Tab lifecycle](./tab-lifecycle.md): the creation and close paths that call these rules.
- [Split tabs](./split-tabs.md): the invariant the snap protects.
- [Sidebar row layout](../sidebar/row-layout.md): item indices versus tab indices, which drop gaps are expressed in.
- [Sidebar drag and drop](../sidebar/drag-and-drop.md): where gap indices come from.
