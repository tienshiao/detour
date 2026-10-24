---
type: Component
title: Tab cell and folder cell
description: "The sidebar's row views — TabCellView, FolderCellView and friends: what each element shows, the progress bar and its stalled-load fade, split rows, hover, and the cell-reuse rules."
tags: [sidebar, cells, progress, split-tabs, appkit]
status: stable
resource: ../../Detour/Browser/Sidebar/TabCellView.swift
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T17:17:19Z }
sources:
  - id: tab-cell
    resource: ../../Detour/Browser/Sidebar/TabCellView.swift
    title: TabCellView.swift
  - id: folder-cell
    resource: ../../Detour/Browser/Sidebar/FolderCellView.swift
    title: FolderCellView.swift
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (cell configuration)
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (isLoadProgressStalled, sidebarProgress)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (subscribeToTab)
  - id: stall-tests
    resource: ../../DetourTests/LoadProgressStallTests.swift
    title: LoadProgressStallTests.swift
  - id: collapse-tests
    resource: ../../DetourTests/TabCellSplitCollapseTests.swift
    title: TabCellSplitCollapseTests.swift
  - id: task-112
    resource: backlog:TASK-112
    title: Some sites never get their favicon and their sidebar rows show a stray grey box
  - id: task-114
    resource: backlog:TASK-114
    title: A background tab whose load stalls shows its URL as the title until it is first shown
  - id: task-124
    resource: backlog:TASK-124
    title: Fade out the progress bar on a background tab whose load has stalled
  - id: dev-mode
    resource: ../features/dev-mode.md
    title: Dev mode
  - id: commit-b9ef265
    resource: commit:b9ef265
    title: "Sidebar: ID-based drag payloads, pure drop resolver, drag fixes"
---

# Role

`TabCellView` is the cell for every tab-like row in the
[sidebar](./overview.md): a normal tab, a pinned entry (live or dormant), and
a split of either kind. `FolderCellView` is the pinned-folder row. The same
file holds `TabRowView` (selection drawing), `NewTabCellView` and
`SeparatorCellView`. The cells have no model properties; the controller
pushes values in through `update…` methods and wires closures for close,
mute, rename and collapse.

# How it works

## Anatomy of a tab cell

| Element | Shown when | Notes |
|---|---|---|
| Favicon | always | Globe symbol when the tab has none. Leading inset is `4 + 16 × indentLevel` (folder depth) |
| Sleep badge (moon) | the tab is sleeping, or a pinned entry is dormant | A split row shows it only when *both* members are asleep or dormant |
| Speaker button | playing audio or muted | Slides the title from 8 to 24 pt. The icon is updated even when the playing/muted union did not change, or muting a playing tab would not swap it |
| Title | always | Pinned entries show `displayTitle`. There is no tooltip: the sidebar's [tab hover card](../features/tab-hover-card.md) replaced it, and the cell's `accessibilityHelp` keeps the old tooltip text (the tab title, a pinned entry's pinned title, a split row's "left — right") |
| Host line | the row is in [dev mode](../features/dev-mode.md) (single rows only) | 10 pt `secondaryLabelColor` label under the title, `hostLineLabel`; the title moves up so both lines are centred in the unchanged 36 pt row |
| Hazard border | the row, or a split half, is in dev mode | Yellow/black dashed `HazardBorderView`, made on first use, framed like the hover background (a split half's border matches its half highlight); over the progress bar, under the content |
| Close button | hover only | Glyph says what it will do: xmark closes a normal tab; **minus** makes a live pinned entry dormant; xmark on a dormant entry removes the pin (`updatePinnedMode`) |
| Peek favicon | the tab has a parked [Peek](../tabs/peek.md) | Trailing chip; never used for split rendering |
| Split segment | the row is a split | See below |
| Progress bar | a load is in flight | See below |
| Hover background | pointer over the row | Extends 6 pt beyond the cell on each side; the drag image and the split-drop overlay mirror this rect |

`TabRowView` draws the selection in the space's tint (alpha 0.35 when
emphasized, 0.15 otherwise), inset 10 pt horizontally.

## Progress bar

`TabCellView.loadingMode` is `.progressBar`. (`.ringSpinner` exists and is
marked in the source as unused and incomplete.) The bar is a faint
accent-coloured rect behind the row content whose width is the row's width
times the progress. It has no constraints: `layout()` derives its frame from
`currentProgress` every pass, and `updateProgress(_:)` animates the frame
over 0.25 s.

- Progress `≤ 0` or `≥ 1` fades the bar out; `updateLoading(false)` does too.
- The controller passes `tab.sidebarProgress`, **not** `estimatedProgress`,
  on all six row paths (normal, pinned, both split kinds, and the two
  in-place reload paths). A split row draws the larger of its members'.
- `TabStore.subscribeToTab` throttles progress notifications to one per
  100 ms per tab, and separately notifies when `isLoadProgressStalled` flips.

### The stalled-load fade

Rows of background tabs used to show a bar that never completed (YouTube
sat at about 0.9) until the tab was selected.[^task-124] The bar was truthful: the page really was still loading. WebKit lowers a
hidden page's web process to background priority about a second after the
navigation commits, and on a busy machine a script-heavy page then makes no
progress until its tab is shown.[^task-124] The cause is on
[hidden web view load stalls](../platform/hidden-webview-load-stalls.md).
The de-prioritisation was accepted; the fix is presentational.

`BrowserTab.isLoadProgressStalled` becomes true when all of these hold for
`loadStallInterval` (2 s):

- a load is in flight (`isLoading`);
- the web view is in no window (`webView?.window == nil`);
- `estimatedProgress` has not changed.

`sidebarProgress` is `0` while stalled, so the cell's existing "hide at 0"
path fades the bar. Any progress or `isLoading` change clears the flag and
restarts the clock. So does `noteShown()`, which the window calls when it
attaches the web view: without it a stall never cleared when the tab was
shown unless progress happened to move (a hung subresource).[^task-124] A
tab that is on screen is re-checked each interval in case it goes to the
background mid-load.

`isLoading` and `estimatedProgress` themselves are untouched, so the Reload
/ Stop button, extension tab status and history recording are unaffected.

Two findings worth keeping:

- The "stray grey box" on some rows in screenshots was this progress bar on
  rows still loading, not a leftover layer.[^task-112]
- A suspected bug — the fade's completion handler zeroing the bar's width
  after progress had resumed mid-fade — does not occur. A diagnostic test
  resuming at 0, 150 and 280 ms into the fade kept the resumed width in
  every sample, because `layout()` re-derives the frame.[^task-124]

The row's *title* and *favicon* had the same dependence on a load finishing
and were fixed at their sources rather than in the cell: titles at commit in
[BrowserTab](../architecture/browser-tab.md)[^task-114], favicons through
the link bridge in [favicons](../features/favicons.md).[^task-112]

## Split rows

A split renders as two equal halves around a divider centred in the cell.
The left half is the ordinary favicon and title; the right half is
`splitFaviconImageView` and `splitTitleLabel`, configured with
`updateSplitPane(favicon:title:emphasized:animatedReveal:departingFavicon:departingTitle:)`.
Passing `nil` for both favicon and title clears split rendering.

- **Emphasis** marks the representative member (the selected pane, else the
  left one): its title is `labelColor`, the other `secondaryLabelColor`.
- **Each half has its own close button.** `splitCloseButton` (left) fires
  `onCloseLeft`; the shared trailing `closeButton` fires `onClose`, which a
  split row wires to the right pane. For a pinned split each glyph follows
  its own entry's live or dormant state (`updateSplitPinnedMode`).
- **Hover is per half.** The tracking area includes `.mouseMoved` so the
  highlight and close button follow the pointer across the divider.
  `updateHover(to:at:)` is the one place hover and the half are decided; it
  reports every change to the cell's `hoverDelegate` (the sidebar, for the
  [tab hover card](../features/tab-hover-card.md)), as do `prepareForReuse`
  and `viewWillMove(toWindow: nil)` for a hovered cell whose row is gone.
- **Formation and dissolve animate inside the row.** The table diff keeps
  the row in place across a split forming or dissolving
  ([row layout](./row-layout.md)), so the same cell is reconfigured from
  single to split or back. With `animatedReveal`, the right segment slides
  and fades in from the divider while the left title retracts; a collapse is
  the mirror image, 0.2 s each. It animates only on a real single↔split
  transition and only when the cell is in a window.
- **The collapse ghost shows the member that left.** The right segment
  holds the old *right* pane, which is the survivor when the left pane
  departed, so the controller passes `departingFavicon` / `departingTitle`
  taken from the pre-update items.
- A clear that arrives while a collapse is running is ignored (a progress
  tick on the survivor would otherwise snap the animation), and
  `splitCollapseGeneration` stops a superseded collapse's completion from
  blanking a segment that has since been revealed again.

## Folder cell

Folder icon button (open or closed image, tinted with the space colour at
0.7 alpha), semibold name, indent `2 + 16 × depth`. Clicking anywhere on the
row toggles the folder: the row is selectable, the controller's selection
handler deselects it and calls `didTogglePinnedFolder`. Rename is inline,
like a pinned entry's.

## Inline rename

`beginEditing()` makes the title label editable in place. Ending the edit
commits a non-empty trimmed name through `onRename` and pulses the hover
background; Esc restores the original text and gives focus to the table.

# Invariants

- **Closures never capture a row or index.** `onClose` asks the table for
  the cell's current row at click time and resolves it through
  `sidebarRow(for:)`.
- **A reused cell must be fully reconfigured.** `moveRow` keeps the cell
  view, so after every batch update the controller reconfigures all visible
  cells; a cell that crossed sections otherwise keeps the other section's
  close handler and glyph.[^commit-b9ef265] `prepareForReuse` resets hover,
  peek, split, indent, rename and the reveal state.
- **Cells on inactive pages get `nil` closures** (`isActive` is false for a
  table that is not the controller's current one).
- **Every path that fills a cell must pass `sidebarProgress`.** There are
  six; a seventh that reads `estimatedProgress` brings the stuck bar back
  for that row kind.
- **The same paths set the dev-mode marking** (`updateDevMode`, through
  `DevMode.rowMarking` / `splitRowMarking`), as does the `applyState` loop
  that turns a dissolved pinned split back into a single row. A path that
  skips it leaves a reused cell with another row's border and host line;
  `prepareForReuse` clears it.

# Gotchas

- **Hover goes stale without mouse events.** A tracking area does not
  reliably send `mouseExited` when scrolling moves a cell from under the
  pointer, and sends nothing during a drag session while rows shift to open
  a gap. `recheckHover()` re-derives hover from
  `mouseLocationOutsideOfEventStream`; the controller calls it after
  scrolls, batch updates, row reloads and drag end.
- **Layer colours are `CGColor`s** and do not follow appearance changes; the
  cells re-resolve them in `viewDidChangeEffectiveAppearance` or inside
  `performAsCurrentDrawingAppearance`.
- **A reused cell can carry zero frames** for the split segment views.
  `revealSplitSegment` lands the split layout without animation first, or
  the segment flies in from the corner.

# Tests

- `LoadProgressStallTests` — hidden stalled, cleared when the load moves,
  cleared by showing, never stalled while hosted. They use a scheme handler
  that holds a request open so the load never ends.
- `TabCellSplitCollapseTests` — collapse and reveal without a window apply
  instantly and leave the segment cleared and hidden.
- `DevModeTests` — the host line and border for a dev-mode row, clearing on
  `.none` and on reuse, and a split's borders on the local halves only.
- Live check of the fade: a background tab whose image request never
  answers showed the bar at 1 s, no bar at 4.5 s, and the bar again after
  selecting the tab.[^task-124]

# Related

- [Sidebar overview](./overview.md) — how cells are configured and reloaded.
- [Row layout](./row-layout.md) — the diff that makes split formation a row continuation.
- [Hidden web view load stalls](../platform/hidden-webview-load-stalls.md) — why background loads stop.
- [Favicons](../features/favicons.md) and [BrowserTab](../architecture/browser-tab.md) — where the row's icon and title come from.
- [Pinned tabs and folders](../tabs/pinned-tabs-and-folders.md) — live and dormant entries, which decide the close glyph.
- [Split tabs](../tabs/split-tabs.md)
- [Dev mode](../features/dev-mode.md) — the hazard border and host line.

[^task-112]: Some sites never get their favicon and their sidebar rows show a stray grey box
[^task-114]: A background tab whose load stalls shows its URL as the title until it is first shown
[^task-124]: Fade out the progress bar on a background tab whose load has stalled
[^commit-b9ef265]: Sidebar: ID-based drag payloads, pure drop resolver, drag fixes
