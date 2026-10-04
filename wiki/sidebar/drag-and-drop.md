---
type: Concept
title: Sidebar drag and drop
description: "The sidebar's drag pipeline: ID-based payloads, the pure validate / destination / resolve functions, the drop transaction, drop landing and the favorite drop hint."
tags: [sidebar, drag-and-drop, split-tabs, invariants]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:41:30Z }
sources:
  - id: dragdrop
    resource: ../../Detour/Browser/Sidebar/SidebarDragDrop.swift
    title: SidebarDragDrop.swift
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift
  - id: components
    resource: ../../Detour/Browser/Sidebar/SidebarComponents.swift
    title: SidebarComponents.swift
  - id: favorites-bar
    resource: ../../Detour/Browser/Sidebar/FavoritesBarView.swift
    title: FavoritesBarView.swift
  - id: space-page
    resource: ../../Detour/Browser/Sidebar/SpacePageView.swift
    title: SpacePageView.swift
  - id: drop-zone
    resource: ../../Detour/Browser/Window/SplitDropZoneView.swift
    title: SplitDropZoneView.swift
  - id: window-sidebar
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
    title: BrowserWindowController+TabSidebar.swift
  - id: dragdrop-tests
    resource: ../../DetourTests/SidebarDragDropTests.swift
    title: SidebarDragDropTests.swift
  - id: design
    resource: ../../docs/split-tabs-design.md
    title: Split tabs design, section 6 (sidebar rendering and drag/drop)
  - id: task-129
    resource: backlog:TASK-129
    title: Favorite drop hint without a layout shift, and drops that land from the release point
  - id: task-34
    resource: backlog:TASK-34
    title: Moving an extension-page favourite into the tab list or pinned section must give a loadable tab
  - id: commit-b9ef265
    resource: commit:b9ef265
    title: "Sidebar: ID-based drag payloads, pure drop resolver, drag fixes"
---

# Summary

A sidebar drag carries an **ID**, never a row. At drop time the controller
resolves that ID against the current model and runs three pure functions —
validate, destination, resolve — which return a `SidebarDropCommand`. Only
then does AppKit-facing code act, by issuing `TabSidebarDelegate` calls. New
drop behaviour is added by extending the enums and their tests in
`SidebarDragDropTests`, not by branching in
`TabSidebarViewController`. The reasons are in
[ID-based drag payloads](../decisions/id-based-drag-payloads.md).

# Pipeline

```
pasteboardWriterForRow      row → SidebarDragPayload (kind, itemID, spaceID, sidebarID) → JSON string
validateDrop (per move)     localDragPayload → validateSidebarDrop(kind, row, operation, dropZone…) → SidebarDropValidation
acceptDrop                  localDragPayload
                            → resolveDragSource(payload)            SidebarDragSource?  (nil: item is gone)
                            → sidebarDropDestination(row, …)        SidebarDropDestination?
                            → resolveSidebarDrop(source, dest, …)   SidebarDropCommand? (nil: no-op or invalid)
                            → delegate call(s), directly or in performDropTransaction
```

Everything between `localDragPayload` and the delegate calls is in
[SidebarDragDrop.swift](../../Detour/Browser/Sidebar/SidebarDragDrop.swift)
and takes plain values: a [`SidebarRow`](./row-layout.md), a
`SidebarDropOperation` (`.on` / `.above`, mirroring
`NSTableView.DropOperation`), the flattened `[PinnedItem]`, the
`[TabListItem]` list and, for `.on` proposals over a tab row, a `RowDropZone`.

## Payloads

| Payload | Pasteboard type | Fields |
|---|---|---|
| `SidebarDragPayload` | `com.mybrowser.tab-reorder` | `kind`, `itemID`, `spaceID`, `sidebarID` |
| `FavoriteDragPayload` | `com.mybrowser.favorite-reorder` | `favoriteID`, `sidebarID` |

`kind` is one of `normalTab`, `pinnedEntry`, `pinnedFolder`, `splitGroup`,
`splitMember`, `pinnedSplitGroup`, `pinnedSplitMember`. For the two whole-row
split kinds `itemID` is the **first member's** tab or entry ID, not the group
ID; for the member kinds it is that member.

`sidebarID` is a UUID minted per `TabSidebarViewController`. A payload is
ours only if `payload.isLocal(sidebarID:spaceID:)` — same sidebar, and the
space that is active now. That one definition is shared by the table
(`localDragPayload`) and the content-area drop zone
(`validateContentSplitDrop`). Drags from another window's sidebar or another
space are refused outright.

## Resolving the source

`resolveDragSource` looks the payload up at drop time and may *degrade* it,
because the model can change while the pointer is down:

- item no longer exists → `nil`, the drop is refused;
- a `splitGroup` or `splitMember` whose group dissolved → `.normalTab`;
- a `pinnedSplitGroup` / `pinnedSplitMember` whose group dissolved → `.pinnedEntry`.

`SidebarDragSource.normalTab(index:)` and `.splitGroup(index:)` carry an
**item** index, compared against item-space gaps in the resolver.

## Validation

`validateSidebarDrop` returns `.reject`, `.accept`, `.acceptIntoSplit(edge:)`,
or a retarget that redraws the insertion line
(`.retargetToPinnedGap`, `.retargetToNormalTabGap`).

| Proposal | Result |
|---|---|
| `.on` a pinned folder row | accept (into the folder), except a lone split pane, or a folder onto itself |
| `.on` a single tab row, source is a lone normal tab | outer 40% bands → `.acceptIntoSplit(.left / .right)` (rejected onto itself); middle 20% → retarget to the gap above or below (`rowDropZone`) |
| `.on` anything else | reject |
| `.above` the top spacer / the separator | retarget to pinned gap `0` / `items.count`; rejected for `splitMember` |
| `.above` a pinned row | accept; rejected for `splitMember` |
| `.above` the New Tab row | retarget to tab gap `0`; rejected for `pinnedFolder` |
| `.above` a tab row | accept; rejected for `pinnedFolder` |

A dragged favourite is validated the same way, then filtered by
`FavoriteDropTargets`: the store says which sections that favourite may
enter (`TabStore.favoriteDropTargets`), since a dormant page of a disabled
extension may only become a dormant pinned entry and one of an uninstalled
extension may go nowhere.[^task-34]

## Resolution

`resolveSidebarDrop(source:destination:items:)` is an exhaustive switch.
`nil` means "do nothing".

| Source | `.beforeNormalTab` | `.beforePinnedItem` | `.intoFolder` | `.intoSplit` |
|---|---|---|---|---|
| `normalTab` | `reorderNormalTab` (nil for the two gaps touching the source) | `pinTab` | `pinTab` | `createSplit` |
| `pinnedEntry` | `unpinEntry` | `movePinnedEntry` (nil onto its own position) | `movePinnedEntry` | nil |
| `pinnedFolder` | nil | `movePinnedFolder` (nil onto itself or into a descendant) | same | nil |
| `splitGroup` | `reorderNormalTab` with the first member's ID | `pinSplitGroup` | `pinSplitGroup` | nil |
| `splitMember` | `removeFromSplit` (every gap is a real change) | nil | nil | nil |
| `pinnedSplitGroup` | `unpinSplitGroup` | `movePinnedSplitGroup` (nil when the anchor is its own member) | same | nil |
| `pinnedSplitMember` | `unpinSplitMember` | `removeFromPinnedSplit` | nil | nil |

Pinned destinations are expressed as `(folderID, beforeItemID)` using
`folderIDForDropIndex` and `itemIDAtDropIndex` from the
[flattener](./row-layout.md). Tab destinations are item gaps.

# Rules

1. **Payloads carry IDs.** No row number, array index or object pointer goes
   on the pasteboard.
2. **Resolve at drop time**, through `resolveDragSource`. Nothing learned in
   `pasteboardWriterForRow` is trusted later.
3. **Decisions live in the pure functions.** A new drop target or source
   kind means a new enum case, new cases in the three functions, and tests.
   The resolver's switch is exhaustive, so a new source or destination case
   will not compile until every combination is decided.
4. **A drop that issues more than one store mutation goes through
   `performDropTransaction`**, and so does any drop that rewrites rows
   structurally (see below).
5. **Gap indices leave the resolver in item space.** Convert with
   `tabGapIndex(forItemGap:in:)` when calling the delegate.
6. **Drag feedback never changes the list's layout.** Highlights and hints
   are overlays.
7. **Re-check at drop what validation decided.** A final drop can arrive
   before a retargeted proposal: `sidebarDropDestination` resolves a
   middle-band `.on` to the same gap validation would have retargeted to,
   and `acceptFavoriteDrop` asks the store for the favourite's drop targets
   again.

# Applying the command

| Command | How it is applied |
|---|---|
| `reorderNormalTab`, `unpinEntry`, `movePinnedEntry`, `movePinnedFolder`, `movePinnedSplitGroup` | One delegate call; the store notifies, and `applyState` animates the row move at once |
| `pinTab`, `pinSplitGroup` | Transaction: pin, then move the new entry to `(folderID, beforeItemID)`. The move uses the tab's ID as the entry ID — `TabStore.pinTab` creates the entry with `id: tab.id` |
| `createSplit`, `removeFromSplit`, `unpinSplitGroup`, `unpinSplitMember`, `removeFromPinnedSplit` | Transaction, even where it is a single call |

`performDropTransaction` sets `isDragging`, runs the mutations, clears it and
calls `applyPendingState`. While the flag is set `applyState` only stores its
arguments in `pendingState`; afterwards the last stored state is applied once,
on the **next run-loop turn**. Two reasons:

- several mutations would otherwise animate one after the other;
- a split create or break diffs as row removals and insertions, not moves.
  Issued inside `acceptDrop` that batch runs while the drag session is still
  live, which `NSTableView` does not survive: the drop aborts and the session
  is stranded mid-drag. Deferring past the end of the session avoids it.

Details that have bitten:

- `stateGeneration` is bumped by every real `applyState`. If newer state
  lands before the deferred block runs, the stale snapshot is dropped, but
  the selection restore still happens.[^commit-b9ef265]
- A remove-and-insert batch does not carry the table's selection, so
  transactions pass `selectTabID` (captured with
  `selectedTabIDForCurrentRow()`) and re-select afterwards.
- Despite its name, `isDragging` is set only for the length of a
  transaction, not for the whole drag session. Store changes that arrive
  mid-drag are applied immediately, which is why rule 2 exists.
- `TabStore` excludes the moved item from its sibling scan, so an anchor
  naming the item itself would append it to the end of its level. The
  resolver turns "dropped onto its own position" into `nil` instead, and for
  a pinned split member retargets the anchor to its partner.
- `wouldCreateFolderCycle` judges from the flattened list (a collapsed
  folder's descendants are not drop targets anyway);
  `TabStore.movePinnedFolder` re-checks against the full tree. A cycle hung
  `flattenPinnedTree` before the guard existed.[^commit-b9ef265]

# Split rows

- **What a drag grabs** — `splitRowDragKind(forX:rowWidth:indent:)`: a 34 pt
  band at the leading edge of each half (the favicon) drags that member;
  anywhere else drags the whole row. The drag APIs do not give the data
  source the mouse-down event, so `DraggableTableView` records
  `lastMouseDownPoint`. `indent` (16 pt per folder level) shifts the left
  band for pinned splits inside folders.
- **Edge drops** — `NSTableView` can express "on" and "above", not "left
  half". `validateDrop` passes the pointer through `rowDropZone`, and draws
  its own half-row overlay (`showSplitDropOverlay`) because `.sourceList`
  feedback can only mark the whole row. The table delegate is not told when
  a drag leaves, so `DraggableTableView` clears the overlay from
  `draggingExited` / `draggingEnded` (`onDragTargetingEnded`).
- **Scope (v1)** — only an ungrouped normal tab can become a pane, and only
  a single normal-tab row is a split target. A pane of a normal split cannot
  be pinned by drag, and a pane of either kind cannot be dropped on a folder
  row. Leaving one split to join another returns `nil`.
- **Content-area drops** — `willBeginAt` tells the window
  (`dragSessionDidChangeActive`), which installs a `SplitDropZoneView` over
  the web content for the length of the session; a drop on its outer 30%
  bands calls `performContentAreaSplitDrop`, the same transaction as the
  table's `createSplit`. See [split tabs hosting](../tabs/split-tabs-hosting.md).
  The begin signal is sent before the drag-image guard's early return,
  because the end signal in `endedAt` is unconditional and the pair must
  balance.

# Drop landing

Without help, a dropped row is seen travelling from where it was picked up,
because the session's own drag image vanishes when the drop is accepted and
the table animates the real row from its origin.

- `willBeginAt` builds the rounded drag image and keeps it, with its frame
  relative to the row, in `rowDragImage`.
- `acceptDrop` calls `beginDropLanding` when `command.landsAsWholeRow` and
  the payload is not a member kind: the image becomes an overlay
  `NSImageView` at the release point.
- `applyState` wraps the table's batch update in a 0.2 s animation group
  while a landing is pending, and `landDroppedRowIfNeeded` hides the real
  row, flies the proxy to it, then reveals the row and fades the proxy. With
  no visible row to land on (a drop into a collapsed folder) the proxy just
  fades.
- `SidebarDropCommand.landsAsWholeRow` is `false` for `createSplit`,
  `removeFromSplit`, `unpinSplitMember` and `removeFromPinnedSplit`: those
  animate inside the row ([tab cell](./tab-cell.md)).

A proxy of our own rather than `NSDraggingInfo.animatesToDestination`,
because a transaction's destination row only exists a run-loop turn later.
Without pacing the batch update to the proxy, the row's own slide took about
0.4 s and was revealed mid-travel.[^task-129] The cancel for a drop that
changed nothing is queued *after* any deferred state application; queued
before it, it cancelled every transaction drop's landing.[^task-129]

Not verified with a real mouse drag: the harness used a stub
`NSDraggingInfo`, which skips `enumerateDraggingItems`, so the proxy's start
frame came from the pointer-centred fallback.[^task-129]

# Favorites

- `FavoritesBarView` is both a drag source (tiles) and a destination (tabs
  and tiles). `FavoritesBarView.canFavorite` is an allow-list — only
  `normalTab` and `pinnedEntry` — so a new payload kind is rejected by
  default. Favoriting one pane would silently scatter its split.
- **Favourite → list**: `acceptFavoriteDrop`. Into the tab list it is one
  delegate call, and `pendingInsertionOrigin` makes the new row animate in
  from the release point. Into the pinned section it is a transaction: the
  store appends the restored entry, the controller finds it in
  `pendingState` by diffing entry IDs, then moves it to the drop position.
- **The hint**: on a page with no favorites, `FavoriteDropHintView` shows
  "Drop to add favorite" for drags that can become one. It overlays the
  space header at a fixed height and is its own drop target, forwarding to
  `FavoritesBarView.performTabDrop(_:at:)` (the empty bar has no height and
  cannot be the target). Growing the bar instead shifted the whole tab list
  on every drag; with the overlay the scroll view's frame is identical before
  and after the hint appears.[^task-129] It is set `isHidden` once faded —
  a transparent view still takes drags.

# Disagreements with the design document

Section 6 of [split-tabs-design.md](../../docs/split-tabs-design.md) predates
the implementation in places. The code differs as follows:

- `Kind.splitGroup`'s `itemID` is the first member's tab ID, not the group ID.
- There is no `reorderSplitGroup` command or `didMoveSplitGroup` delegate
  method; a whole split row reorders through `reorderNormalTab` and
  `didMoveTab`, and the store moves the block.
- The helpers are `splitRowDragKind(forX:rowWidth:indent:)` and
  `rowDropZone(forX:y:rowSize:)`, not `splitDragKind` / `splitEdge`.
- A split row's context menu has Copy URL, Separate Tabs and Close Both
  Splits only (no Move to Space). Pinned split kinds (section 12) were added
  later.

# Tests

`SidebarDragDropTests` covers payload round trips, validation per kind and
row, destination normalisation, every resolver branch, the geometry helpers
and `landsAsWholeRow`. `SplitDropZoneTests` covers the content-area bands and
`validateContentSplitDrop`. To exercise the real `acceptDrop` at runtime
without a mouse, see the stub `NSDraggingInfo` technique in the
[debug harness playbook](../playbooks/debug-harness.md).

# Related

- [ID-based drag payloads](../decisions/id-based-drag-payloads.md) — why the pipeline has this shape.
- [Sidebar row layout](./row-layout.md) — rows, items and the flattened pinned list the resolver reads.
- [Split tabs](../tabs/split-tabs.md) and [splits survive pinning](../decisions/splits-survive-pinning.md) — what the split commands do in the store.
- [Favorites](../tabs/favorites.md) — moves between favorites, pinned and the tab list.
- [AppKit gotchas](../platform/appkit-gotchas.md) — the table-view and drag-session traps behind several rules here.

[^task-129]: Favorite drop hint without a layout shift, and drops that land from the release point
[^task-34]: Moving an extension-page favourite into the tab list or pinned section must give a loadable tab
[^commit-b9ef265]: Sidebar: ID-based drag payloads, pure drop resolver, drag fixes
