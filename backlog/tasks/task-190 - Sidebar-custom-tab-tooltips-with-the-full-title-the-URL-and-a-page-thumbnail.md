---
id: TASK-190
title: 'Sidebar: custom tab tooltips with the full title, the URL and a page thumbnail'
status: To Do
assignee: []
created_date: '2026-10-24 09:30'
updated_date: '2026-10-24 09:32'
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
- [ ] #1 Hovering a sidebar tab row shows a custom card sooner than the native tooltip, with the full title and the URL; native tooltips are removed from tab rows
- [ ] #2 The card shows the tab's thumbnail when one exists and a compact layout when none does; no tab is woken or shown to make one
- [ ] #3 VoiceOver still announces the title; checked at runtime in light and dark mode, with a hover-revealed sidebar too
- [ ] #4 Pinned rows and favourites tiles behave like normal rows: the card shows the tab's current title and current URL
- [ ] #5 On a split row the card describes only the hovered half (its title, URL and thumbnail)
- [ ] #6 Thumbnails are cached to disk as a small image per tab, so they survive relaunch: written when switcherPreview is captured, read lazily for the card, deleted when the tab is closed for good (not while it is reopenable or archived, if those keep their tab id) and with its profile, never written for Private; covered by tests for the store and the deletion paths
- [ ] #7 Click, scroll, drag start, rename, context menu, space swipe, sidebar hide and window deactivation all hide the card; it never shows during a drag
<!-- AC:END -->



## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-24):
- Cache a small thumbnail image on disk (in scope here, not a follow-up). Proposed: JPEG at ~240-320 px wide in the data directory's cache folder, keyed by tab id; reuse the same capture as the switcher preview (no extra snapshots).
- Split rows: only the hovered half.
- Pinned rows and favourites: same as normal rows, current title and current URL (not the pinned title/URL).
Still to decide during the work: thumbnail for the selected tab (none vs fresh), and whether a dormant pinned/favourite tile with a cached image shows it.
<!-- SECTION:NOTES:END -->
