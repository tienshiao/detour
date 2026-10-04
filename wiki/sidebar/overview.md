---
type: Overview
title: Sidebar overview
description: A map of the sidebar — TabSidebarViewController, its pages, cells and pure helper files — and how actions flow through TabSidebarDelegate to the window controller and TabStore.
tags: [sidebar, overview, appkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:41:30Z }
sources:
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift
  - id: space-page
    resource: ../../Detour/Browser/Sidebar/SpacePageView.swift
    title: SpacePageView.swift
  - id: components
    resource: ../../Detour/Browser/Sidebar/SidebarComponents.swift
    title: SidebarComponents.swift
  - id: window-sidebar
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
    title: BrowserWindowController+TabSidebar.swift
  - id: window-store
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabStore.swift
    title: BrowserWindowController+TabStore.swift
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift
  - id: commit-b9ef265
    resource: commit:b9ef265
    title: "Sidebar: ID-based drag payloads, pure drop resolver, drag fixes"
  - id: task-82
    resource: backlog:TASK-82
    title: Mid-swipe space page renders pinned rows from the active space
---

# Summary

The sidebar is the left item of each window's split view: one
`TabSidebarViewController` per
[BrowserWindowController](../architecture/browser-window-controller.md). It
shows the active [space](../architecture/profiles-and-spaces.md)'s favorites,
pinned tree and tabs, a read-only address bar, navigation buttons and the
space switcher. It holds no tab state of its own beyond a copy of what it was
last told to show: it renders what the window hands it and reports gestures
through `TabSidebarDelegate`. The window turns those into
[TabStore](../architecture/tabstore.md) mutations, and the store's observer
callbacks come back down as new state.

Everything that is a *rule* — which row is what, where a drop goes, which
page sits where — is a pure function in its own file, unit-tested without
AppKit. The view controller is large (about 3,500 lines) but is meant to stay
a dispatcher.

# Parts

## Views

| Part | File | What it is |
|---|---|---|
| `TabSidebarViewController` | [TabSidebarViewController.swift](../../Detour/Browser/Sidebar/TabSidebarViewController.swift) | The controller. Data source, delegate and menu delegate for every page's table |
| Title-bar row | same | Sidebar toggle, Back / Forward / Reload (`HoverButton`). Reload becomes Stop while loading |
| `FauxAddressBar` | [FauxAddressBar.swift](../../Detour/Browser/Sidebar/FauxAddressBar.swift) | Read-only host display; click opens the [command palette](../features/command-palette.md) in place; hosts the site-settings button and pinned extension buttons |
| `SpacePageView` | [SpacePageView.swift](../../Detour/Browser/Sidebar/SpacePageView.swift) | One per space: `FavoritesBarView`, `SpaceHeaderView`, `FavoriteDropHintView`, a scroll view with the tab table, fade shadows |
| `ArchivePageView` | [ArchivePageView.swift](../../Detour/Browser/Sidebar/ArchivePageView.swift) | The Archived Tabs page, left of the first space; see [closed tabs and archive](../tabs/closed-tabs-and-archive.md) |
| `TabCellView`, `FolderCellView`, `NewTabCellView`, `SeparatorCellView`, `TabRowView` | [TabCellView.swift](../../Detour/Browser/Sidebar/TabCellView.swift), [FolderCellView.swift](../../Detour/Browser/Sidebar/FolderCellView.swift) | Row views; see [tab cell](./tab-cell.md) |
| `FavoritesBarView` | [FavoritesBarView.swift](../../Detour/Browser/Sidebar/FavoritesBarView.swift) | The tile grid above the list; see [favorites](../tabs/favorites.md) |
| Bottom bar | controller | Downloads button with activity badge, the space buttons strip, Add Space |
| `FocusGatedTableView`, `DraggableTableView`, `DraggableScrollView`, `DraggableClipView`, `DraggableBarView`, `FadeShadowView` | [SidebarComponents.swift](../../Detour/Browser/Sidebar/SidebarComponents.swift) | Small AppKit subclasses: focus gating, drag bookkeeping, window dragging from empty areas, the swipe hook |
| `SettingsPopoverViewController` | [SettingsPopoverViewController.swift](../../Detour/Browser/Sidebar/SettingsPopoverViewController.swift) | The per-site popover (content blocking switch, extensions list) the address bar's button opens |

## Pure rule files

| File | Rules | Page |
|---|---|---|
| [SidebarLayout.swift](../../Detour/Browser/Sidebar/SidebarLayout.swift) | Row ↔ index mapping, the table diff | [Row layout](./row-layout.md) |
| [TabListItems.swift](../../Detour/Browser/Sidebar/TabListItems.swift) | Tabs → items (a split is one item), index conversions | [Row layout](./row-layout.md) |
| [PinnedTreeFlattener.swift](../../Detour/Browser/Sidebar/PinnedTreeFlattener.swift) | Pinned tree → flat rows | [Row layout](./row-layout.md) |
| [SidebarDragDrop.swift](../../Detour/Browser/Sidebar/SidebarDragDrop.swift) | Payloads, drop validation and resolution | [Drag and drop](./drag-and-drop.md) |
| [SidebarPageStrip.swift](../../Detour/Browser/Sidebar/SidebarPageStrip.swift) | Page ↔ strip position | [Space paging](./space-paging.md) |
| [TabNavigation.swift](../../Detour/Browser/Sidebar/TabNavigation.swift) | Cmd+Option+Up/Down order | [Tab switching](../tabs/tab-switching.md) |
| [ArchiveListLayout.swift](../../Detour/Browser/Sidebar/ArchiveListLayout.swift) | Archive grouping, search, filter | [Closed tabs and archive](../tabs/closed-tabs-and-archive.md) |
| [SidebarVisibilityState.swift](../../Detour/Browser/Window/SidebarVisibilityState.swift) | Pinned vs auto-hide mode (lives in `Window/`) | [Visibility and auto-hide](./visibility-and-auto-hide.md) |

# How they connect

## Down: window → sidebar

`BrowserWindowController` is a `TabStoreObserver`
([BrowserWindowController+TabStore.swift](../../Detour/Browser/Window/BrowserWindowController+TabStore.swift)).
Each callback is first filtered by space: a change in a space other than the
window's active one only calls `inactiveSpaceContentDidChange()`.

| Call | Effect |
|---|---|
| `applyState(pinnedEntries:pinnedFolders:tabs:selectedTabID:)` | Diff against the current rows and animate ([row layout](./row-layout.md)). Used for every structural change, and by `selectTab` |
| `resetState(...)` | No diff: set the model, `reloadData()`. Used by `setActiveSpace` |
| `reloadTab(at:)` / `reloadPinnedEntry(at:)` | Update one visible cell in place (title, favicon, progress, audio). In place so the hover state survives and progress animates |
| `selectedTabIndex` / `selectedPinnedTabIndex` | Move the row highlight. Always inside `suppressingSelectionCallbacks` |
| `updateFavorites`, `updateFavoriteSelection`, `refreshFavoriteTile(forTabID:)` | Favorites bar |
| `activeSpaceID`, `tintColor`, `updateSpaceButtons(spaces:activeSpaceID:)` | Space switch; the last one rebuilds pages if the space list changed |
| `closedTabRecordsDidChange()`, `showArchivePage` / `dismissArchivePage` | Archive page |

`applyState` is the heart of it: flatten the incoming pinned tree, diff,
declare removals / insertions / moves between `beginUpdates` and
`endUpdates` with the model swapped in between, then **reconfigure every
visible cell**. That last step is not optional. `moveRow` keeps the row's
cell view, including its closures, so a cell that moved from the pinned
section into the tab list still has its pinned close handler, whose row guard
then fails; close and mute buttons stopped working after a pin and unpin
round trip until this was added.[^commit-b9ef265]

## Up: sidebar → window → store

`TabSidebarDelegate` has nearly sixty methods, most with empty default
implementations. `BrowserWindowController` implements them in
[BrowserWindowController+TabSidebar.swift](../../Detour/Browser/Window/BrowserWindowController+TabSidebar.swift).
The window, not the sidebar, owns the consequences of a gesture: settling
selection before a close, remembering which pane of a split had focus
(`lastFocusedSplitMember`), waking a dormant pinned entry, explaining a
refused tile with a toast, arming split animations.

The delegate speaks **tab indexes and IDs**, never table rows or item
indexes. Converting is the sidebar's job ([row layout](./row-layout.md)).

Three places bypass the delegate, all read-only or tab-local: `relevantSpaces`
reads `TabStore.shared.spaces` to build pages, the archive page reads
`TabStore.shared.archiveEntries()`, and a row's speaker button calls
`tab.toggleMute()` directly.

# Things to know before editing

- **One controller, many tables.** `tableView` and `scrollView` are
  re-pointed at the active space's page by `updateActivePage()`. Data source
  and delegate methods are still called for the other pages' tables, so each
  must take the table it is handed and read through
  `pinnedItemsForTableView(_:)` / `tabItemsForTableView(_:)`. Inactive pages
  get `nil` closures, vend no drag payload, and their selection changes are
  ignored.[^task-82] See [space paging](./space-paging.md).
- **Selection is a feedback loop.** Changing the table's selection fires
  `tableViewSelectionDidChange`, which calls `didSelectTabAt`, which runs
  `selectTab` and its side effects (waking a dormant split partner, moving
  focus). Any programmatic highlight change must be wrapped in
  `suppressingSelectionCallbacks`.
- **Folder and New Tab rows are selectable on purpose.** Selecting one is
  how a click is delivered; the handler deselects the row and toggles the
  folder or opens the palette.
- **Targets are remembered by ID.** Context menus store `contextMenuTabID`
  / `contextMenuFolderID` / `contextMenuSplitGroupID` and resolve them when
  the action fires; cell closures ask the table for the cell's current row.
- **`sidebarID`** is a per-controller UUID stamped into drag payloads so
  another window's drags are refused.
- **Incognito** (`isIncognito`): one page for the window's own space, no
  archive page, no Add Space button, no swipe, and no pin, rename, archive
  or Move to items in the tab context menu.
- **Title-bar alignment.** The toggle and navigation buttons sit in the
  title-bar area beside the traffic lights at fixed offsets
  (`defaultToggleLeading` 74, `defaultNavTop` 6). On macOS 27 and later
  `alignTitleBarControls()` derives both from the zoom button's measured
  frame instead, and skips the measurement mid-fullscreen-transition, when
  the button belongs to another window.
- **Size.** The sidebar split item is 200–350 pt wide and collapsible
  (`setupSplitView`).

# Related

- [Row layout](./row-layout.md) — rows, items, tab indexes and the diff.
- [Drag and drop](./drag-and-drop.md) — the payload and resolver pipeline.
- [Space paging](./space-paging.md) — the page strip, swipes and the archive page.
- [Visibility and auto-hide](./visibility-and-auto-hide.md) — collapsing, hover reveal.
- [Keyboard focus](./keyboard-focus.md) — which control holds the keyboard and when it is handed back to the page.
- [Tab cell](./tab-cell.md) — the row views.
- [Architecture overview](../architecture/overview.md) — where the sidebar sits among the app's components.
- [Observer protocol over Combine](../decisions/observer-protocol-over-combine.md) — why changes arrive as `TabStoreObserver` callbacks.
- [AppKit gotchas](../platform/appkit-gotchas.md) — table view, drag and focus traps met here.

[^commit-b9ef265]: Sidebar: ID-based drag payloads, pure drop resolver, drag fixes
[^task-82]: Mid-swipe space page renders pinned rows from the active space
