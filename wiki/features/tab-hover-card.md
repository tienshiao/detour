---
type: Feature
title: Tab hover card
description: "The card shown beside the sidebar when the pointer rests on a tab row or favourite tile: the full title, the URL with its host emphasised and a page thumbnail; when it shows, what it describes, where thumbnails come from (memory, then a per-row JPEG on disk) and what dismisses it."
tags: [sidebar, tabs, hover, thumbnails, ui]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T11:31:06Z }
sources:
  - id: rules
    resource: ../../Detour/Browser/HoverCard/HoverCardRules.swift
    title: HoverCardRules.swift (timing, text, targets, content, placement)
  - id: controller
    resource: ../../Detour/Browser/HoverCard/TabHoverCardController.swift
    title: TabHoverCardController.swift
  - id: view
    resource: ../../Detour/Browser/HoverCard/TabHoverCardView.swift
    title: TabHoverCardView.swift (card view, thumbnail view, panel)
  - id: cache
    resource: ../../Detour/Browser/HoverCard/TabThumbnailCache.swift
    title: TabThumbnailCache.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (thumbnailKey, liveThumbnailKeys, saveNow sweep)
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (hover-card section)
  - id: tab-cell
    resource: ../../Detour/Browser/Sidebar/TabCellView.swift
    title: TabCellView.swift (TabCellHoverDelegate)
  - id: favorites-bar
    resource: ../../Detour/Browser/Sidebar/FavoritesBarView.swift
    title: FavoritesBarView.swift (tile hover)
  - id: card-tests
    resource: ../../DetourTests/TabHoverCardTests.swift
    title: TabHoverCardTests.swift (rules and controller)
  - id: thumbnail-tests
    resource: ../../DetourTests/TabThumbnailTests.swift
    title: TabThumbnailTests.swift
  - id: harness
    resource: ../../docs/harness/task190-harness.patch
    title: TASK-190 runtime harness
  - id: task-190
    resource: backlog:TASK-190
    title: "Sidebar: custom tab tooltips with the full title, the URL and a page thumbnail"
  - id: task-229
    resource: backlog:TASK-229
    title: "Hover card: show a tab's Peek (its title, URL and thumbnail), including from the Peek favicon in the sidebar row"
  - id: harness-229
    resource: ../../docs/harness/task229-harness.patch
    title: TASK-229 runtime harness
  - id: task-230
    resource: backlog:TASK-230
    title: "Hover card: keep a Peek's picture on disk, so a restored Peek's card has one"
---

Sidebar tab rows have no AppKit tooltip. Resting the pointer on a row (or a
favourite tile) shows a card just outside the sidebar with the page's full
title, its URL and, when one exists, a thumbnail. It replaced the native
tooltip, which was slow and showed only the title.[^task-190]

# What it does

- **Rows that get a card:** normal tabs, pinned entries (live or dormant),
  each half of a split row, and favourite tiles. Folders, the New Tab row,
  the separator and the Archived Tabs page get none. Only the active page's
  rows count: a page sliding past during a swipe is ignored.
- **What it says:** the full title (semibold 13 pt, wrapping to at most
  three lines), then the URL on one line (11 pt, tail-truncated) with the
  host in `labelColor` and the rest in `secondaryLabelColor`.
- **Live pinned entries and favourites** describe the tab's *current* page,
  not the pinned title and URL. A dormant entry or tile describes its own
  saved title and URL.
- **A split row** describes only the half under the pointer
  (`TabCellView`'s `hoveredSplitSide`); moving across the divider swaps the
  card at once.
- **The Peek badge** (the [Peek](../tabs/peek.md)'s favicon at a row's
  trailing end, or the chip in a favourite tile's corner) has its own card,
  describing the Peek; the rest of the row or tile keeps the host's card,
  which says nothing about the Peek (the user's decision, over one card with
  a Peek section).[^task-229] Moving between the badge and the rest of the
  row swaps the card at once, placed as the row's card is. The badge is part
  of its row for dismissal: a card dismissed on the row stays away on the
  badge, and the reverse, until the pointer leaves the row. It works for
  normal rows, pinned rows, favourite tiles and both halves of a split row
  (normal or pinned): each pane's Peek has its own badge, the right pane's
  in the row's trailing slot and the left pane's just before the divider,
  and each describes that pane's Peek. Split rows had no badge at all
  before TASK-229 (the user asked for one).
  - A **live or parked** Peek shows its own title and URL (the URL the host
    saved for it when the Peek tab has none).
  - A Peek **restored after a relaunch** has no tab, only the host's
    `peekURL`, and Peeks record no history, so its card is the URL alone.
  - Its **picture** is the Peek's own in-memory `switcherPreview`, taken
    when its host is left with the Peek up, and kept while the Peek is
    parked; else the one on disk under the Peek's own key, so a restored
    Peek's card has the picture taken before the relaunch.[^task-230] Until
    TASK-230 nothing was written for a Peek and a restored Peek's card was
    text only. No picture while the Peek is presented (over the selected
    tab); the other pane of the selected split is on screen without its
    Peek, so its Peek card keeps its picture (`hoverCardIsOnScreen` answers
    for the presented Peek itself).
  - A Peek page with no favicon gives the host no badge, so no Peek card.
- **Thumbnail:** none for a tab on screen in this window (the selected tab,
  either pane of the selected split, a selected favourite). Otherwise the
  tab's in-memory `switcherPreview`, else the picture on disk. With none the
  card is title and URL only, with no empty box.
- **Timing:** a fresh hover waits 0.45 s (`HoverCardTiming.showDelay`).
  While a card is up, or within 0.3 s of one being hidden by the pointer
  moving off its row (`swapWindow`), the next row's card shows at once.
- **VoiceOver:** each tab cell carries the old tooltip text as
  `accessibilityHelp` (the tab title; a pinned entry's pinned title; a split
  row's "left — right"), so the help VoiceOver read from the tooltip is still
  there.

## The URL line (`HoverCardText`)

| URL | Host | Rest |
|---|---|---|
| `https://www.example.com/a?q=1#x` | `example.com` | `/a?q=1#x` |
| `https://www.example.com/` | `example.com` | (empty) |
| `http://docs.example.com:8080/x` | `docs.example.com:8080` | `/x` |
| `https://user:pw@example.com/p` | `example.com` | `/p` |
| `file:///Users/me/a.html` | (empty) | `/Users/me/a.html` |
| `about:blank`, `detour://history` | the whole URL | (empty) |

Only `http` and `https` lose their scheme; only a leading `www.` goes; the
path is percent-decoded, unless decoding would add control or format
characters (bidi overrides, zero-width), which keep it encoded. A blank title falls back to the URL's display form
(and the URL line is then left out, not repeated); with no URL either it is
"Untitled".

# How it works

```
TabCellView.updateHover ──► TabCellHoverDelegate ─┐
FavoriteTileView hover ───► FavoritesBarDelegate ─┼─► TabSidebarViewController
                                                  │     resolves the row → HoverCardTarget
                                                  └──► TabHoverCardController (one per window)
                                                          ├─ HoverCardTiming / HoverCardContent (pure)
                                                          ├─ TabThumbnailCache (disk read)
                                                          └─ TabHoverCardPanel (child window)
```

- **One hover source.** `TabCellView.updateHover(to:at:)` already decides
  hover and the split half; it now also tells its `hoverDelegate` whenever
  either changes, including from `recheckHover()`, from `prepareForReuse`
  (a reused cell's old row is gone) and from `viewWillMove(toWindow: nil)`
  (a removed row sends no exit). Favourite tiles report through the bar's
  delegate the same way.
- **Row to target.** The sidebar resolves the cell's row with
  `sidebarRow(for:)` and `flattenedPinnedItems` / `tabItems`, then the pure
  `HoverCardTarget.forPinnedItem` / `forTabItem` (which also picks the split
  half). Over the Peek badge, `HoverCardTarget.peekBadge(of:)` turns that
  target into `.peek(host:)` when its live tab has a Peek (`peekTab` or
  `peekURL`); a dormant entry or tile has no tab and no badge.
- **Badge hover.** The cell and the tile decide "over the badge" from fixed
  rects (`TabCellView.peekBadgeHoverRect(in:)`: the badge, its 4 pt inset
  to the row's edge and half the gap to the close button, full row height;
  `leftPanePeekBadgeHoverRect(in:)` for a split's left pane: the badge,
  half the gap to the left pane's close button and the 14 pt gap to the
  divider, ending at the row's middle;
  `FavoriteTileView.peekBadgeHoverRect(in:)`: the chip and its inset to the
  tile's corner), computed from the layout constants rather than the
  badge's frame, which lags a badge that has just appeared. Both report the
  change through `mouseMoved` (the tile's tracking area gained
  `.mouseMoved`), and re-check when the badge appears or goes under a
  resting pointer. Crossing the badge's edge does not end the row's hover:
  the sidebar only begins the new target (`beginCardHover` ends the old one
  only when it is not `isSameRow`, which is how split halves still end each
  other), so the controller swaps the card in place while one is up, and
  its suppression check uses `isSameRow` too. It remembers which view reported which target, so an exit ends that
  target even when the cell has since been reconfigured for another row.
- **Content.** `HoverCardContent.make(for:isOnScreen:thumbnailKey:)` turns a
  target into text, an in-memory preview and the disk key to look under;
  the window answers `isOnScreen` (the selected tab and its split partner)
  and `thumbnailKey` (`TabStore.thumbnailKey(for:)`).
- **Disk read.** The controller starts reading the thumbnail when the hover
  begins, so it has usually arrived when the 0.45 s delay is up. A late
  arrival is put on the card only if the card still shows that key; the
  panel is re-placed with its top fixed.
- **The panel.** `TabHoverCardPanel` is a borderless, non-activating
  `NSPanel` with a clear background, a shadow and `ignoresMouseEvents`,
  added to the browser window with `addChildWindow(_:ordered: .above)` so it
  draws over the web content and past the window's edge and moves with the
  window. The card is a `GlassContainerView` (an `NSGlassEffectView` on
  macOS 26), 260 pt wide; the panel takes the window's effective appearance
  each time it is shown.
- **Placement** (`HoverCardPlacement`): x is the sidebar's visible right edge
  plus 6 pt, the top is level with the hovered row's top, and the frame is
  clamped into the screen's `visibleFrame`. The sidebar edge comes from
  `tabSidebar.view.visibleRect`, so a hover-revealed sidebar works the same.
- **Thumbnail drawing:** 236 pt wide, aspect kept, height capped at 160 pt
  (a tall picture is cropped from the top, so the top of the page shows),
  6 pt corners and a hairline `separatorColor` edge.

## Dismissal

| Event | How it is caught |
|---|---|
| Click, drag start, context menu, rename by double-click, Control-click | local monitor: left, right or other mouse down in this window |
| Scroll, space swipe | local monitor: scroll wheel in this window |
| Typing, Cmd shortcuts, space switch by keyboard | local monitor: key down in this window |
| Window resigns key (another window, another app) | `windowDidResignKey` |
| Sidebar hides (Cmd+S, auto-hide) | `sidebarCollapsedStateChanged(true)` |
| Window closes | `windowWillClose` |
| The row goes away | the cell's `viewWillMove(toWindow: nil)` / `prepareForReuse` |

A dismissal hides the card and suppresses it until the pointer leaves that
row; it does not set the swap window, so the next row waits the full delay.
The monitor is installed only while a card is pending or up, and removed
on the next turn after it fires (not from inside its own handler). Nothing
shows while `NSEvent.pressedMouseButtons != 0`: a hover that begins, or a
delay that ends, with a button down is treated as a dismissal, which keeps
the card out of drags (tracking areas send nothing during a drag session
anyway; see [AppKit gotchas](../platform/appkit-gotchas.md)).

## Thumbnails on disk (`TabThumbnailCache`)

The only picture of a tab is the Control+Tab switcher's `switcherPreview`
([tab switching](../tabs/tab-switching.md)), taken when the tab is left on
screen and kept in memory. The hover card also keeps it on disk so it
survives a relaunch.

- **Written** from the same capture, in `captureSwitcherPreview`: no extra
  snapshot, and no tab is ever woken, hosted or shown to make one (GPU
  surfaces, [GPU IOSurface limit](../platform/gpu-iosurface-limit.md)).
  JPEG at quality 0.7, at the preview's 480 px width (the card shows it
  about 236 pt wide, sharp on Retina), one file per key in
  `<data directory>/TabThumbnails/<key>.jpg`, on a serial utility queue.
- **Key** (`TabStore.thumbnailKey(for:)`): the pinned entry's or
  favourite's own id when the tab backs one, so a dormant tile keeps its
  picture across dormancy and relaunch; else the tab id. For a Peek
  (TASK-230), `TabStore.peekThumbnailKey(hostKey:peekURL:)`: the first 16
  bytes of a SHA-256 of its host row's key and `peekURL`, the URL the
  session saves for the Peek (set when it opens, following its navigations
  while it is presented, the only time it is pictured). Not the Peek tab's
  own `url`, which can differ (an error page keeps the failed URL): a
  picture written under that would be read, and swept, under another key
  after a relaunch (found by the TASK-230 review). It is the same on every launch, and because the URL is in it
  a different Peek on the same host, or the same Peek after navigating, can
  never be shown the old picture; no delete is needed when a Peek closes or
  changes. Nil, so nothing is written, for a Private tab or a Private host's
  Peek, and for a tab no row lists or hosts.
  Pinning reuses the tab's id as the entry's id, so pinning keeps the
  picture; unpinning or favouriting changes the key, and the next capture
  writes the new one.
- **Deleted by sweep.** After a successful `saveNow()` whose live key set
  differs from the last sweep's (so not on navigations or title changes),
  the store sweeps the folder, keeping `liveThumbnailKeys` (every normal tab, every pinned
  entry live or dormant, every profile's favourites, and the current Peek
  of each of their tabs, live, parked or restored). A Peek that closed or
  navigated leaves the set, so its old picture goes with the next sweep. A file whose key is
  not live and was last modified before the sweep started is removed;
  anything that is not `<uuid>.jpg` is left alone. That one rule covers
  closing a tab, archiving, removing a pin or a favourite, and deleting a
  space or profile. Closed and archived records do not keep their tab id
  (reopening builds a new tab), so their pictures could never be shown
  again.[^task-190]

# Edge cases

- **A row reconfigured in place** (a title change through `reloadTab`)
  while its card is up keeps the card's text until the next hover; the text
  is taken when the card shows.
- **Non-key windows of the active app** show cards (the cells' tracking
  areas are `.activeInActiveApp`), as native tooltips did.
- **The selected tab's card** has no thumbnail by decision; a stale picture
  of the page in front of the user would be wrong and a fresh snapshot is a
  cost on every hover.[^task-190]

# Tests

- `TabHoverCardTests`: timing (fresh, swap while showing, swap window,
  expiry, a hide stamp in the future), the URL line and title fallback,
  targets for single, split and pinned rows (no card for folders or a split
  with no side), and content for normal, live/dormant pinned, live/dormant
  favourite, Private and on-screen tabs; placement and screen clamping.
- `TabHoverCardTests`, Peek (TASK-229): the badge target for normal,
  pinned and favourite hosts with a live or restored Peek, none for a
  dormant entry or tile, a host with no Peek or a Peek target; identity by
  host; content for a live Peek (its own preview and disk key, never the
  host's), one without a preview (its own disk key), a Private host's Peek
  (no key), a parked Peek tab with no URL, a restored Peek (URL only, its
  disk key) and a host on screen (neither); the two badge hit rects;
  `isSameRow` for a row and its badge.
- `TabHoverCardControllerTests` (real borderless window, fake host): delay
  then show beside the sidebar, leave before the delay, swap on
  exit-then-enter and enter-then-exit, between a row and its Peek badge,
  dismissal holding across the badge, dismissal suppressing until leave,
  dismissal while pending, no card with the sidebar hidden, monitor removed
  when idle.
- `TabThumbnailTests`: the cache round trip and the sweep rule, keys for
  each row kind and Private, and a closed tab's key leaving the live set;
  Peeks (TASK-230): the derived key (stable, distinct from the host's, per
  URL and per host), a normal, pinned and favourite host's Peek, a parked
  Peek with no URL keyed by the host's saved one, a restored Peek's key
  live, a closed or navigated Peek's key leaving the set, a Private host's
  Peek having none.
- Runtime: [docs/harness/task190-harness.patch](../../docs/harness/task190-harness.patch)
  seeds normal, pinned (live and dormant), favourite and split rows, drives
  hover through the cells' own `mouseEntered`/`mouseMoved`/`mouseExited`
  (posted `mouseMoved` events produce no tracking-area enter or exit), logs
  the card's text, thumbnail and frame against the sidebar's, and posts
  mouse-down and key-down events through `NSApp.postEvent`.
  On 2026-10-24, with the screen locked for the whole session (so no window
  captures), it measured: fresh hovers showing after 0.458 to 0.462 s, the
  row-to-row and split-half swaps at once, the card 6 pt right of the
  sidebar's visible edge with its top level with the row (also on a
  hover-revealed sidebar), no thumbnail on the selected row, the dormant
  pinned row's picture read from disk, and the card hidden within about
  10 ms by a mouse down, a key down, resign key and the sidebar hiding.[^harness]
  A second run with the screen unlocked captured every card kind in light
  and dark (window and panel by window number): the layout matched the
  logged frames. The glass takes its tint from what is behind the panel, not
  from the app's appearance alone: over a white page the card is light even
  in dark mode, as the command palette and the Control+Tab switcher (the same
  `GlassContainerView`) are. Still not seen: a scroll reaching the monitor (a
  `CGEvent`-built scroll `NSEvent` carries no window, and one posted to the
  app's pid is not delivered to a window that is not frontmost).
- Runtime, Peek cards: [docs/harness/task229-harness.patch](../../docs/harness/task229-harness.patch)
  (local fixture pages, a relaunch phase). On 2026-10-28, screen locked:
  the badge swapped the row's card for the Peek's 0.04 s after the move and
  back, in light and dark; a fresh hover straight onto a pinned badge or a
  tile chip waited 0.46 s; every card sat 6 pt outside the sidebar, top
  level with its row; live Peeks (normal, pinned, favourite) showed their
  own title, URL and picture, a parked Peek kept both, the selected host's
  Peek had no picture, and after the relaunch restored Peeks showed the URL
  alone in a 38 pt card. On 2026-10-29 a split row with a Peek on each pane:
  each pane's badge showed its Peek's card and each title area its pane's
  card, badge to badge included, swapping at once in light and dark; the
  left badge sat 4 pt after the left close button and 14 pt before the
  divider, nothing overlapping, the left title keeping 32 pt of a 188 pt
  row. After TASK-230 the relaunch phase showed the restored normal and
  pinned Peeks' pictures from disk (light and dark), their files written
  under the derived keys before quitting and still live after.[^harness-229] No pixels were checked: a locked
  screen gives no window captures, and `cacheDisplay` or `layer.render` of
  the glass card come out blank; the card view is the one TASK-190 checked
  in both appearances.

# Related

- [Tab cell](../sidebar/tab-cell.md) — the hover state the card follows.
- [Tab switching](../tabs/tab-switching.md) — where `switcherPreview` is captured.
- [Visibility and auto-hide](../sidebar/visibility-and-auto-hide.md) — the hover-revealed sidebar the card also works with.
- [Favourites](../tabs/favorites.md) and [Pinned tabs and folders](../tabs/pinned-tabs-and-folders.md) — the ids the thumbnail keys use.

[^task-190]: TASK-190
[^harness]: TASK-190 runtime harness
[^task-229]: TASK-229
[^harness-229]: TASK-229 runtime harness
[^task-230]: TASK-230
