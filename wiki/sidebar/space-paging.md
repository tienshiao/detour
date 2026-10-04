---
type: Component
title: Sidebar space paging
description: The sidebar's horizontal page strip — one page per space plus the Archived Tabs page before the first — and how swipes, space buttons and the active space move it.
tags: [sidebar, spaces, archive, animation]
status: stable
resource: ../../Detour/Browser/Sidebar/SidebarPageStrip.swift
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:41:30Z }
sources:
  - id: page-strip
    resource: ../../Detour/Browser/Sidebar/SidebarPageStrip.swift
    title: SidebarPageStrip.swift
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift
  - id: space-page
    resource: ../../Detour/Browser/Sidebar/SpacePageView.swift
    title: SpacePageView.swift
  - id: strip-tests
    resource: ../../DetourTests/SidebarPageStripTests.swift
    title: SidebarPageStripTests.swift
  - id: focus-tests
    resource: ../../DetourTests/SidebarPageFocusTests.swift
    title: SidebarPageFocusTests.swift
  - id: task-82
    resource: backlog:TASK-82
    title: Mid-swipe space page renders pinned rows from the active space
  - id: task-119
    resource: backlog:TASK-119
    title: Archived Tabs page before the first space in the sidebar
  - id: task-131
    resource: backlog:TASK-131
    title: A focused tab list loses keyboard focus when the space list changes
---

# Role

Between the navigation row and the bottom bar, the [sidebar](./overview.md)
is a clipped horizontal strip of pages. Each non-incognito
[space](../architecture/profiles-and-spaces.md) has a `SpacePageView`
(favorites, header, tab list); a regular window also has an
`ArchivePageView` to the left of the first space. The strip slides under a
two-finger swipe, a space button click, a keyboard space switch or
Navigate > Show Archived Tabs.

Two things are deliberately separate:

- **the active space** (`activeSpaceID`) — which space the window shows; it
  changes only when the window's `setActiveSpace` runs;
- **where the strip rests** — on the active space's page, or on the archive
  page (`isShowingArchivePage`). Showing the archive does not change the
  active space: the window keeps showing its tabs.

# How it works

## Structure

```
pageClipView  (masks to bounds; Auto Layout positions it)
├── pageStripView   frame-based, x = -stripIndex × pageWidth
│   ├── archivePage      strip index 0, full height        (absent in incognito)
│   └── spacePages[i]    strip index i + 1, below the address bar row
└── addressBarHost   frame-based, above the strip; holds FauxAddressBar
```

`SidebarPageStrip(hasArchivePage:spaceCount:)` is the pure mapping between a
`SidebarPage` (`.archive` or `.space(i)`) and a strip index, so the "+1 when
there is an archive page" offset exists in exactly one place.

| Function | Answers |
|---|---|
| `stripIndex(for:)`, `page(atStripIndex:)`, `pageCount` | Page ↔ position |
| `spaceButtonIndex(forFractionalStripIndex:)` | The bottom bar's (fractional) button index; negative while moving onto the archive, `-1` on it |
| `spaceChromeX(forStripX:pageWidth:)` | Where the address bar sits: `0` on any space page, riding the first space's page on the way to the archive, off to the right once there |

The archive page has no address bar; its search field occupies the same row.
So the address bar stays put between spaces but slides away with the first
space's page.[^task-119] `setStripX(_:animated:)` moves the strip and the
address bar together and is the only writer of either frame's x.

## Active page and inactive pages

`activePageIndex` is an index into `spacePages` — a *space* index, never a
strip index — and keeps naming the active space's page while the archive
shows. `updateActivePage()` re-points the controller's `tableView` and
`scrollView` at that page.

The controller's own model (`pinnedEntries`, `tabs`, `flattenedPinnedItems`)
describes the active space only. Every other page renders from an
`InactivePageContent` snapshot — flattened pinned items, tab items and tint,
taken from `TabStore` at reload time — keyed by its table view. Row count,
row heights and cell content all read the same snapshot, so they cannot
disagree with what the table has cached.

Snapshots are refreshed (`reloadInactivePages`):

- when pages are rebuilt, and when a page stops being the active one;
- when the strip starts moving (swipe begin, `animateToSpace`, archive show
  or dismiss);
- while the strip is moving, whenever another space changes
  (`inactiveSpaceContentDidChange()`, coalesced to one reload per run-loop
  turn because load progress can arrive many times a frame).

Before this, an incoming page drew its pinned rows from the *active* space's
list, and a page loaded once with an empty model in a new window was never
reloaded: swiping from a space with no pinned items to one with two showed
blank cells at separator height.[^task-82] The snapshot is flattened with the
space's remembered `selectedTabID`, so a selected tab inside a collapsed
folder keeps its exposed row and the retained highlight lands on the right
row.[^task-82]

## Moving the strip

| Trigger | Path |
|---|---|
| Two-finger swipe | `DraggableScrollView.onScrollWheel` → `handleSpaceSwipe` → `updateStripPosition` per event → `handleSwipeEnd` |
| Space button click, Next / Previous Space | `animateToSpace(id:)` → `animateStrip` → `finishTransition(onSpaceAt:)` |
| Show Archived Tabs, restore from the archive | `showArchivePage(animated:)` / `dismissArchivePage(animated:)` → `slideStripToCurrentPage` |
| The window changed space by itself | `activeSpaceID` `didSet` → `updateActivePage()` (snap), or a 0.2 s slide if the archive was showing |

Swipe details:

- A swipe starts only when `|deltaX| > |deltaY|` on an event with a phase;
  momentum events with no active tracking are ignored. Incognito windows do
  not swipe.
- Once tracking, a local `NSEvent` monitor for `.scrollWheel` keeps feeding
  the handler, because the scroll view the gesture began on slides out from
  under the pointer. The scroll view and the monitor both see each event;
  `processSwipeEvent` dedupes by event identity.
- Past either end the strip rubber-bands. On release it commits to the
  neighbouring page when the travel exceeds half a page, else to the nearest.
- The background tint blends between the two pages' space colours (grey for
  the archive) as the strip moves.

**The sidebar asks, the window decides.** A committed transition ends in
`finishTransition`, which clears `isShowingArchivePage` and *then* calls
`tabSidebarDidRequestSwitchToSpace`; the window's `setActiveSpace` sets
`activeSpaceID` back on the sidebar. Clearing the flag first makes that
assignment snap instead of sliding a second time. Landing on the archive
page sets the flag and asks the window for nothing.

`stripAnimationGeneration` is bumped by every transition and checked by
every completion handler, so a superseded animation's completion does
nothing. A swipe that begins mid-animation bumps it too: otherwise the stale
completion would switch spaces under the user's fingers.[^task-119]

## Bottom bar

The space buttons are their own small strip (`spaceStripView` in
`spaceClipView`), driven by the same fractional index. The highlight
stretches between buttons while sliding, squishes on overscroll and fades
out as the index goes negative (the archive has no button). When more spaces
exist than fit, buttons near the clip edges shrink into dots.
`rebuildAllSpaceButtons` skips its work unless the space count, active
index, bar width or the emoji-and-colour signature changed.

## Archive page loading

The archive list is not kept live while off screen.
`closedTabRecordsDidChange()` marks it stale and reloads at most once per
run-loop turn, and only if the page is showing or the strip is moving;
otherwise the reload happens when a swipe starts or `showArchivePage` runs.
It also reloads when it was last loaded on an earlier day, since its headers
are relative dates.

# Invariants

- Every strip x goes through `SidebarPageStrip` and `setStripX`.
- `activePageIndex` is a space-page index. Strip positions come from
  `currentStripIndex`.
- A table's row count and its cells come from the same per-table source
  ([row layout](./row-layout.md), rule 7).
- Inactive pages are inert: no cell closures, no drag payloads, selection
  changes ignored (`tableView === self.tableView` guards).
- Only the page the strip rests on accepts keyboard focus
  (`updatePageKeyboardFocus`); see [keyboard focus](./keyboard-focus.md).

# Gotchas

- **`rebuildPages()` recreates every space page** whenever the list of space
  IDs changes (add, delete, reorder, undo). It carries the active list's
  selected row and keyboard focus across, but only if the active page still
  shows the same space afterwards.[^task-131] Left open by that task's
  review: the rebuild resets the list's scroll position (read from the code,
  not confirmed in the app) and ends a rename in progress, which may commit
  a half-typed name. Reusing the page of each surviving space would remove
  the need to carry anything. The archive page is kept.
- `activeSpaceID`'s `didSet` runs on every assignment, and `rebuildPages`
  and friends assign the same value often. Only a real change while the
  archive shows leaves the archive.
- `updateActivePage()` does not snap the strip while an animation is in
  flight; the animation's completion re-snaps to whatever is current.
- The page strip and address bar are frame-based inside an Auto Layout
  parent; `relayoutPages()` re-frames them from `viewDidLayout`.

# Tests

- `SidebarPageStripTests` — the mapping, round trips, out-of-range indexes,
  the fractional button index, the address bar riding the first page.
- `SidebarPageFocusTests` — which page accepts focus, and what a rebuild
  carries across.
- At runtime a swipe can be driven without a trackpad by sending synthetic
  scroll-phase events to a page's scroll view; the recipe is in the
  [debug harness playbook](../playbooks/debug-harness.md). TASK-82 and
  TASK-119 were verified that way.[^task-82][^task-119]

# Related

- [Sidebar overview](./overview.md) — the controller that owns the strip.
- [Closed tabs and archive](../tabs/closed-tabs-and-archive.md) — what the archive page lists and how restore works.
- [Profiles and spaces](../architecture/profiles-and-spaces.md) — per-window active space, space lifecycle.
- [Keyboard focus](./keyboard-focus.md) — the focus gate tied to the current page.
- [Incognito](../architecture/incognito.md) — why a private window has a single page.

[^task-82]: Mid-swipe space page renders pinned rows from the active space
[^task-119]: Archived Tabs page before the first space in the sidebar
[^task-131]: A focused tab list loses keyboard focus when the space list changes
