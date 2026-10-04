---
type: Concept
title: Pinned tabs and folders
description: The pinned section's model (PinnedEntry with an optional backing tab, PinnedFolder, per-level sort order), what live, asleep and dormant mean, how closing and home work, and why a dormant tile can refuse to open.
tags: [tabs, pinned, folders, sidebar, model]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T02:06:47Z }
sources:
  - id: entry
    resource: ../../Detour/Browser/PinnedEntry.swift
    title: PinnedEntry.swift
  - id: folder
    resource: ../../Detour/Browser/PinnedFolder.swift
    title: PinnedFolder.swift
  - id: refusal
    resource: ../../Detour/Browser/DormantTileRefusal.swift
    title: DormantTileRefusal.swift
  - id: flattener
    resource: ../../Detour/Browser/Sidebar/PinnedTreeFlattener.swift
    title: PinnedTreeFlattener.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (pinned tab and pinned folder mutations)
  - id: window-sidebar
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
    title: BrowserWindowController+TabSidebar.swift
  - id: cell
    resource: ../../Detour/Browser/Sidebar/TabCellView.swift
    title: TabCellView.swift (updatePinnedMode)
  - id: lifecycle-doc
    resource: ../../docs/tab-lifecycle.md
    title: docs/tab-lifecycle.md
  - id: task-34
    resource: backlog:TASK-34
    title: Moving an extension page favourite into the tab list or pinned section must give a loadable tab
  - id: task-37
    resource: backlog:TASK-37
    title: Activating or unpinning a dormant pinned entry of a disabled or uninstalled extension gives a dead tab
  - id: task-40
    resource: backlog:TASK-40
    title: Undo actions registered before Delete Space act on a stale Space object after Undo Delete Space
---

# Summary

A pinned tab is a `PinnedEntry`: a durable tile with a home URL and title, plus
an *optional* `BrowserTab`. The tile outlives its tab. Entries are organised
into `PinnedFolder`s, which nest. Both live on the `Space`
(`space.pinnedEntries`, `space.pinnedFolders`) and are per space, unlike
[favourites](./favorites.md), which are per profile.

A pinned entry's backing tab is **not in `space.tabs`**. Code that walks only
`space.tabs` misses every pinned tab; use `space.pinnedTabs`,
`Space.displayableTab(id:)` or `TabStore.tab(hosting:in:)` when the question is
"is this a tab of this space".

# Rules

## Three states of an entry

| State | `entry.tab` | Web view | Selecting it |
|---|---|---|---|
| Live | a tab | yes | shows the page as it is |
| Live but asleep | a tab with `isSleeping` | no | wakes into its cached interaction state ([sleeping](./sleeping-and-archiving.md)) |
| Dormant | nil | no | builds a new tab and loads `pinnedURL` |

"Dormant" and "asleep" are different things. A dormant entry draws its cached
`favicon` / `faviconURL` (copied from the tab when it went dormant) and its
`pinnedTitle`.

## Identity

- `pinTab` creates the entry with **`id` equal to the tab's id**, so an entry id
  and its backing tab's id are usually the same UUID. Do not rely on it:
  `pinURL` and `restoreFavoriteAsPinned` mint a fresh entry id, and a dormant
  entry that is activated gets a tab with a new id.
- Look a pinned tab up by `entry.tab?.id`, an entry by `entry.id`. Sidebar
  delegate calls for pinned rows carry an index into `space.pinnedEntries` or an
  entry id, never a tab id.
- Undo closures capture ids, not objects: Undo Delete Space rebuilds a space's
  entries and folders as fresh objects with the same ids, so a captured instance
  could be an orphan.[^task-40]

## Order is `sortOrder` per level, not array order

**The index of an entry in `space.pinnedEntries` is not its position on
screen.** Display order comes from `folderID` plus `sortOrder`:

- A *level* is the set of entries with a given `folderID` and folders with that
  `parentFolderID`. Entries and folders at one level share a single `sortOrder`
  sequence and are merged by it (`sortedSiblings` in the flattener,
  `pinnedLevelSiblings` in the store).
- A new entry or folder takes `max(all entry orders, all folder orders) + 1`
  across the whole space, which sorts it last at the root.
- `movePinnedTabToFolder` and `movePinnedFolder` place by an anchor
  (`beforeItemID`, nil meaning "end of level") and then renumber that level
  `0…n-1`. Their undo restores a full snapshot of the section's order
  (`capturePinnedOrder` / `restorePinnedOrder`).
- Restoring a saved `sortOrder` can tie with a sibling renumbered since. Where a
  tie could split a [pinned split](./split-tabs.md) pair, the undo paths place
  positionally or re-run `sanitizePinnedSplitGroups`.

## Folders

- `deletePinnedFolder` does not delete the contents. The children take the
  folder's place in the parent level, in their existing order, and that level is
  renumbered.
- `movePinnedFolder` walks up from the target parent and refuses a move into
  itself or a descendant. A cycle would make `flattenPinnedTree` recurse
  forever.
- `isCollapsed` is model state, saved with the folder.

## Flattening for the sidebar

`flattenPinnedTree(entries:folders:collapsedFolderIDs:selectedTabID:)` turns
the tree into `[PinnedItem]`: `.entry`, `.folder` or `.split`, each with a
depth.

- A collapsed folder hides its children, **except** the selected tab's entry,
  which stays exposed one level in so the selection is never invisible. If that
  entry is a split member, the whole `.split` item is exposed: a lone row would
  drag as a single tab while the store moves the pair as a block.
- `pinnedItemID` (diff identity) is the entry id, the folder id, or the group id
  for a split. `itemIDAtDropIndex` returns a split's *first* entry id, so a drop
  anchor always names a real sibling and lands before the group.
- `folderIDForDropIndex` makes a drop above an item inside a folder join that
  folder.

Row arithmetic on top of this list belongs to
[sidebar row layout](../sidebar/row-layout.md).

## Closing a pinned tab

`TabStore.closePinnedTab` **always makes the entry dormant and never removes
it**: it tears the tab down, caches the favicon on the entry and sets
`tab = nil`. Removal is a separate call, `deletePinnedEntry`.

| Gesture | Live entry | Dormant entry |
|---|---|---|
| Cmd+W with the pinned tab selected | goes dormant; the window deselects (or selects the split partner) | n/a |
| The row's hover button | minus glyph: goes dormant | xmark glyph: the entry is deleted |
| An extension's `tabs.remove` | goes dormant | n/a |

The close notifies `tabStoreDidUpdatePinnedEntry`, not a removal, because the
row stays. A background window whose selection was that tab deselects (or
follows a split partner) in that callback. No closed-tab record is written;
the undo ("Close Tab") rebuilds the tab on the entry.

**There is no "reset to home" operation.** Home is reached by closing the tab
and clicking the tile again, which loads `pinnedURL` in a new tab. Closing a
tab that is already at its home URL does not remove the entry either.

## Title shown on the row

`PinnedEntry.displayTitle`: the `pinnedTitle` while dormant or at the home URL;
`"/ <page title>"` once the tab has navigated elsewhere on the same host; the
tab's own title on another host. `renamePinnedEntry` changes `pinnedTitle`.

## Pinning and unpinning

- Pinning needs a URL: a blank new tab is refused. Pinning is disabled in
  incognito windows.
- `pinTab` removes the tab from `space.tabs`, leaves any split it was in, and
  captures the current URL and title as home. `unpinTab` is the reverse and
  inserts the tab at a snapped index (default: the top of the tab list).
- Neither is a close for the extension contexts. The tab keeps its web view and
  registration; only the pinned flag is announced
  (`ExtensionTabLifecycle.didChangePinned`).
- A whole split row pins and unpins as a unit through `pinSplitGroup` /
  `unpinSplitGroup` ([splits survive pinning](../decisions/splits-survive-pinning.md)).

## The anchor rule

A live pinned tab is held to its home host. A link that leaves it, any
`_blank` link and a tab-style `window.open` open in a [Peek](./peek.md) rather
than navigating the pinned tab or opening a new tab. Navigations that are not
link activations (redirects, script-driven location changes) still navigate in
place.

## Dormant tiles that refuse to open

A tile whose home page is a `webkit-extension://` page can only open while that
extension is enabled in the profile. `materializeDormantEntry` returns nil
otherwise, and every caller bails *before* mutating, so the entry stays exactly
as it was.[^task-37]

| Page | May become a tab | May stay or become a dormant pinned tile |
|---|---|---|
| Ordinary page, or an enabled extension's page | yes | yes |
| A disabled extension's page | no | yes (waits on a pending origin until the extension is enabled) |
| An uninstalled extension's page | no | no (the next session restore drops the tile) |

- Refusal is never a deletion. Dropping a tile from a click would delete a user
  tile behind their back and could break a pinned split.[^task-37]
- `activatePinnedEntry`, `unpinTab`, `unpinSplitGroup` and `activateFavorite`
  return `Bool`. `TabStore.dormantTileRefusal(url:in:)` returns the reason as a
  `DormantTileRefusal` (`.extensionDisabled(name:)` or `.extensionUnavailable`).
- **Only user-driven paths show the toast** (`showDormantTileRefusal`): a click,
  a drop, a menu command, the selection a close leaves behind. The store's own
  activations (waking a split partner, restore) stay silent.
- Cmd+Option+Up/Down skips such tiles; otherwise every press would re-target
  the refused tile and toast again ([tab switching](./tab-switching.md)).
- The extension's name is shown only when the extension is loaded, so a raw id
  never reaches the user.

Why a tile needs no extension id in memory: a context reload rewrites tile URLs
onto the new origin, and a restore or a disable registers the origin as
pending. Only an uninstall forgets the origin, which is exactly the refused
case.[^task-34] See [extension pages](../extensions/extension-pages.md).

## Persistence

`pinnedTab` rows hold the home URL and title, favicon URL, `folderID`,
`sortOrder`, the split fields and `tabID`. The backing tab is an ordinary `tab`
row with `sortOrder = -1`. `pinnedFolder` rows are saved in the same
transaction as the entries (the entries reference them).

# Where it lives

- [PinnedEntry.swift](../../Detour/Browser/PinnedEntry.swift),
  [PinnedFolder.swift](../../Detour/Browser/PinnedFolder.swift): the models.
- [TabStore.swift](../../Detour/Browser/TabStore.swift): `pinTab`, `pinURL`,
  `unpinTab`, `closePinnedTab`, `deletePinnedEntry`, `activatePinnedEntry`,
  `materializeDormantEntry`, the folder mutations, `movePinnedEntry` (to another
  space, landing at the destination's root).
- [PinnedTreeFlattener.swift](../../Detour/Browser/Sidebar/PinnedTreeFlattener.swift):
  `flattenPinnedTree`, drop helpers, `sanitizePinnedSplitGroups`.
- [DormantTileRefusal.swift](../../Detour/Browser/DormantTileRefusal.swift):
  the reasons and their messages.

# Tests

`PinnedTreeFlattenerTests`, `PinnedTabMoveTests` (including the cycle
rejection), `TabStoreTests`, `SplitTabTests` (pinned splits),
`ExtensionPageFavoriteTests` (refused activation and unpin),
`UndoAfterDeleteSpaceTests`, `MoveTabToSpaceTests`.

# Related

- [Favourites](./favorites.md): the per-profile sibling of pinned entries, with the same dormant and anchor rules.
- [Split tabs](./split-tabs.md): pinned splits live on the entries.
- [Peek](./peek.md): where links from a pinned tab open.
- [Sidebar row layout](../sidebar/row-layout.md): rows built from the flattened items.
- [Sidebar drag and drop](../sidebar/drag-and-drop.md): pin, unpin and folder drops.
- [Extension pages](../extensions/extension-pages.md): durable identity of extension page tiles.

[^task-34]: Moving an extension page favourite into the tab list or pinned section must give a loadable tab
[^task-37]: Activating or unpinning a dormant pinned entry of a disabled or uninstalled extension gives a dead tab
[^task-40]: Undo actions registered before Delete Space act on a stale Space object after Undo Delete Space
