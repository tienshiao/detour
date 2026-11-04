---
id: TASK-190
title: 'Sidebar: custom tab tooltips with the full title, the URL and a page thumbnail'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:30'
updated_date: '2026-10-24 15:58'
labels:
  - sidebar
  - ui
  - feature
dependencies: []
priority: low
ordinal: 217000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24. Sidebar tab rows use AppKit's native tooltip today (`cell.toolTip = tab.title` / `entry.pinnedTitle` / the split descriptor in TabSidebarViewController), which is slow to appear and shows only the title.

Custom hover card instead:
- appears a little sooner than the native tooltip (pick a delay, ~0.4-0.5 s; once one is showing, moving to another row swaps immediately);
- the **full title** (wrapping, not truncated), then the **URL** as a secondary line (display form, host emphasised), then a **thumbnail** of the page when one exists;
- placed beside the row, outside the sidebar, so it needs its own borderless child window or panel (it must draw over the web content and the window edge); follows the sidebar's glass/appearance, light and dark;
- dismissed on click, scroll, drag start, rename, context menu, space swipe, sidebar hide, and window deactivation; never shown during a drag;
- covers normal rows, pinned rows (pinned title vs current page: show both if they differ?), favourites tiles, and split rows (one card listing both panes, or the hovered half; decide);
- keeps VoiceOver help (`setAccessibilityHelp` / accessibility tooltip) since the native tooltip goes away.

**Thumbnails are not always available.** The only per-tab picture is the Control+Tab switcher's `BrowserTab.switcherPreview` (TASK-108, wiki/tabs/tab-switching.md): ~480 px wide, taken with `takeSnapshot` when the tab is *left* on screen, **in memory only**, survives sleep. There is none for tabs not shown since launch (the whole restored session, background-opened tabs), dormant pinned/favourite tiles, or a failed capture; the selected tab's is from when it was last left. Never wake or host a hidden tab to take one (GPU surface cost, wiki/platform/gpu-iosurface-limit.md). So:
- the card has a no-thumbnail layout (title and URL only, no empty box);
- the selected tab shows no thumbnail (it is on screen) or a fresh one; decide;
- optional follow-up, recorded as a decision: persist previews to disk (small JPEG per tab in the data directory's cache, deleted with the tab, never for Private) so they survive relaunch.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Hovering a sidebar tab row shows a custom card sooner than the native tooltip, with the full title and the URL; native tooltips are removed from tab rows
- [x] #2 The card shows the tab's thumbnail when one exists and a compact layout when none does; no tab is woken or shown to make one
- [x] #3 VoiceOver still announces the title; checked at runtime in light and dark mode, with a hover-revealed sidebar too
- [x] #4 Pinned rows and favourites tiles behave like normal rows: the card shows the tab's current title and current URL
- [x] #5 On a split row the card describes only the hovered half (its title, URL and thumbnail)
- [x] #6 Thumbnails are cached to disk as a small image per tab, so they survive relaunch: written when switcherPreview is captured, read lazily for the card, deleted when the tab is closed for good (not while it is reopenable or archived, if those keep their tab id) and with its profile, never written for Private; covered by tests for the store and the deletion paths
- [x] #7 Click, scroll, drag start, rename, context menu, space swipe, sidebar hide and window deactivation all hide the card; it never shows during a drag
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decisions taken during planning (2026-10-24):
- Closed and archived records do not keep their tab id (reopenClosedTabRecord builds a new tab via restoredTab), so a closed tab's thumbnail can never be shown again: it is deleted once its key is gone.
- Thumbnail key: a pinned entry's or favourite's own id when the tab backs one (stable across dormancy and relaunch), else the tab id. A dormant pinned/favourite tile with a cached image shows it.
- Selected tab (the window's displayed panes): no thumbnail, it is on screen.
- Stored at the switcher's 480 px width (JPEG ~0.7), not 240-320 px: the card shows it ~240 pt wide, sharp on Retina.
- Deletion by sweep: after each session save, files whose key is not live (normal tab ids, pinned entry ids, favourite ids) and older than the sweep's start are removed; covers close, archive, space and profile deletion, unpin and favourite removal in one place. Pin/unpin changes a tab's key; the old file is swept and the next capture writes the new one.

Slices:
1. TabThumbnailCache (directory in the data directory, async write/read, sweep with a pure orphan rule) + TabStore.thumbnailKey(for:) (nil for Private and unlisted tabs such as Peeks) / liveThumbnailKeys; tests first. Capture hook in captureSwitcherPreview; sweep after save.
2. Hover card: pure timing (show after ~0.45 s; immediate swap while one is showing or just hidden) and text (full title, URL host emphasised) with tests; TabHoverCardView in a borderless non-activating child panel beside the row (glass, light/dark), TabHoverCardController per window; hooks in TabCellView (row and split half), pinned/folder rows, favourites tiles; dismissal on mouse down, scroll, key down (local monitor), sidebar hide, window resign-key, space swipe; suppressed while a mouse button is down. Native tooltips removed from tab rows, setAccessibilityHelp keeps the title for VoiceOver.
3. Harness: hover rows (normal, pinned, split half, favourite, dormant tile) and capture the card light and dark, with a hover-revealed sidebar; check dismissals; check files written / not for Private / swept after close.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-24):
- Cache a small thumbnail image on disk (in scope here, not a follow-up). Proposed: JPEG at ~240-320 px wide in the data directory's cache folder, keyed by tab id; reuse the same capture as the switcher preview (no extra snapshots).
- Split rows: only the hovered half.
- Pinned rows and favourites: same as normal rows, current title and current URL (not the pinned title/URL).
Still to decide during the work: thumbnail for the selected tab (none vs fresh), and whether a dormant pinned/favourite tile with a cached image shows it.

Slice 1 done (2026-10-24): TabThumbnailCache (Browser/HoverCard; <data dir>/TabThumbnails/<key>.jpg, JPEG 0.7 at the switcher's 480 px, one serial utility queue, async read with main-thread completion); TabStore.thumbnailKey(for:) and liveThumbnailKeys; captureSwitcherPreview stores each capture under the key; saveNow sweeps orphans after a successful save (only TabStore.shared has the cache, so test stores never touch disk). Found: pinTab gives the entry the tab's own id, so the key survives pinning. Tests first: TabThumbnailTests 10/10 (red against empty stubs first; two test bugs fixed: a second cache's flush does not wait for the first cache's queue, and the pinned-key assertion assumed different ids).
Slice 2 (card UI, hooks, runtime harness) delegated to an Opus subagent per the user (2026-10-24: use a subagent to conserve context).

Slice 2 done (2026-10-24, Opus subagent): HoverCardRules (HoverCardTiming 0.45 s / 0.3 s swap window; HoverCardText: scheme, www., user info and a bare / dropped, path decoded, file: shows its path, about:/detour: whole, a blank title falls back to the URL; HoverCardTarget for tab items and pinned items, split half by side, none for folders; HoverCardContent: live pins and favourites show the tab's current page, a dormant tile its own with its entry/favourite id as key, an on-screen tab no thumbnail; HoverCardPlacement 6 pt outside the sidebar, top level with the row, clamped to visibleFrame). TabHoverCardView (GlassContainerView, 260 pt, title up to 3 lines, host emphasised) in a borderless non-activating child panel that ignores the mouse; TabHoverCardController per window (local monitor for mouse down/scroll/key down only while a card is pending or up; resign key, sidebar collapse and window close dismiss; nothing while a button is down). Hooks: TabCellHoverDelegate (incl. prepareForReuse and leaving the window), FavoritesBarDelegate hoverChanged; row tooltips became setAccessibilityHelp with the same text. Choices: a dismissal does not open the swap window; text is taken when the card appears; non-key windows of the active app show cards; favourite tiles had no tooltip, so no accessibility help was added.
Review (/code-review --fix, 10 findings): fixed 7 — a remembered disk miss was never reread; a full-opacity flash before the fade-in; a blink on every row-to-row swap; bidi/control characters from a decoded path (the path stays encoded then, new test); the sweep scanned the folder after every save (now only when the live key set changed); real pressedMouseButtons in tests (injected); captures wrote through TabThumbnailCache.shared instead of the store's cache. Skipped: a cell reconfigured in place under the pointer keeps the old target until the pointer leaves (needs re-reporting from every configure path); sharing the URL display helpers (they don't split host and path); a dead .tab branch in the dormant switch.
Tests after the review: 339 tests, 0 failures (TabHoverCardTests, TabHoverCardControllerTests, TabThumbnailTests, SidebarLayoutTests, SplitTabTests, SidebarDragDropTests, FavoriteTileBadgeTests, TabCellSplitCollapseTests, SidebarPageFocusTests, TabStoreTests, SessionSaveAtomicityTests, SessionSaveFailureTests, SessionSnapshotRepairTests, FavoritePeekPersistenceTests, AppDatabaseTests). Red step done for timing, text, target and content; placement and controller tests written after the code.
Runtime (harness docs/harness/task190-harness.patch, injected hover via the cells' own mouseEntered/Moved/Exited, screen locked): logged checks pass — 480x384 previews, the dormant entry's JPEG on disk and on its card, toolTip nil and axHelp = title on every row, card placement 6 pt from the sidebar edge and parented to the window in Aqua and DarkAqua, no thumbnail for the selected row, the live pin showing its current page, the split card swapping halves at once, the favourite tile, a 0.46 s first show and immediate row swaps, hiding within ~10 ms on mouse down, key down, resign key (delegate called directly) and sidebar hide, and the card beside a hover-revealed sidebar. Not verified: the card's pixels in light and dark (captures fail while the screen is locked), scroll dismissal (a synthetic scroll event has no window), real pointer movement and real drags.

Visual check (2026-10-24, screen unlocked, harness run 6, captures by window number): every card kind in light and dark matches the logged frames — 6 pt outside the sidebar, top level with the row, compact card for the selected row, split halves, favourite tile, dormant pin with its disk picture, hover-revealed sidebar. The glass takes its tint from what is behind it (light over a white page even in dark mode), as the palette and the Control+Tab switcher do; left as is. Scroll and space swipe dismissal not seen at runtime: synthetic scrolls never reach a non-frontmost window; they go through the same monitor (scrollWheel in its mask) as the mouse and key dismissals that were seen. Isolated profiles DetourVerify190a-f deleted; harness reverted.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Sidebar tab rows, pinned rows, split halves and favourite tiles show a custom hover card instead of the AppKit tooltip: the full title, the URL with its host emphasised, and a page thumbnail when one exists (none for the tab on screen). It appears after 0.45 s and swaps at once between rows; mouse down, scroll, key down, resign key, window close and the sidebar hiding dismiss it. Thumbnails are the Control+Tab switcher's captures, also written to <data dir>/TabThumbnails as JPEG (keyed by pinned entry, favourite or tab id; never for Private) and swept after a save that changed the live keys, so they survive relaunch and dormant tiles keep theirs. Tooltip text moved to accessibilityHelp. Tests: 339 across 15 suites, 0 failures (new: TabHoverCardTests 35, TabHoverCardControllerTests 7, TabThumbnailTests 10). Runtime: harness docs/harness/task190-harness.patch, light and dark captures checked; scroll dismissal not seen at runtime. Review: 7 of 10 findings fixed; skipped: a cell reconfigured in place under the pointer keeps its old target until the pointer leaves, shared URL display helpers, a dead branch.
<!-- SECTION:FINAL_SUMMARY:END -->
