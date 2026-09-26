---
id: TASK-119
title: >-
  Tabs: Archived Tabs page before the first space in the sidebar (browse,
  search, restore closed-tab records)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-25 06:35'
updated_date: '2026-09-26 18:24'
labels:
  - tabs
dependencies:
  - TASK-116
  - TASK-117
priority: medium
ordinal: 119000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Once Reopen Closed Tab skips archived records (TASK-116), archived tabs are only recoverable through history. Build a NATIVE AppKit surface modelled on Arc's Archived Tabs.

Revised 2026-09-26 (user): the Archive is a PAGE IN THE SIDEBAR'S PAGE STRIP, BEFORE THE FIRST SPACE — reached by swiping right past the first space (Arc: 'swipe left from the first space'), like Arc's library pane (Arc also has Media/Downloads/Easels/... there; out of scope, only Archived Tabs). ONE list — no separate Closed/Archived sections: plain closes and archived records mixed, newest first by closedAt, grouped under relative-date headers like Arc ('Today', 'Yesterday', '3 days ago', '1 week ago', '3 weeks ago', ...). The page isn't tied to one space, so it lists EVERY non-incognito space's records; each row shows favicon, title, url without scheme, and a small space-emoji badge. A Filter menu beside the search field narrows to one space (Arc's Filter). Entry points: the swipe and a menu item that slides the sidebar to the page — no bottom-bar button; the space-strip highlight rubber-bands/fades while the page is showing.

Clicking a row restores it through the same path as Reopen Closed Tab (TabStore.restoredTab, extension-page classification included) into the RECORD'S OWN space at its original position, removes the record, switches the window to that space and selects the tab; a context menu offers Restore and Delete. Longer term this page is also the surface for synced closed-tab data (saved page text), so the listing query and restore path live in TabStore/AppDatabase, and grouping/search/filter are pure functions, not view-controller logic.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A page before the first space in each regular window's sidebar lists every non-incognito space's closed and archived records in ONE list, newest first by closedAt, under relative-date headers
- [x] #2 Swiping right past the first space reveals the page (and swiping left leaves it); a menu item slides to it from any space; the space-strip highlight reflects the off-strip position; no bottom-bar button
- [x] #3 Search matches title and url (case/diacritic-insensitive) live; a Filter menu narrows to one space; headers with no matching rows disappear
- [x] #4 Clicking a row (or context-menu Restore) reopens the tab in the record's own space at its original position, deletes the record, switches the window to that space and selects the tab; extension pages follow the TASK-24/28 rules (disabled: not restorable, stays listed; uninstalled: record discarded); context-menu Delete removes the record without reopening
- [x] #5 Records without closedAt (pre-TASK-116) still list, sorted by id, in a trailing undated group
- [x] #6 Incognito windows have no archive page and incognito spaces never appear
- [x] #7 The page updates live when records are added, restored or deleted (from any window)
- [x] #8 'Clear Archive…' in the page's menu and a matching main-menu item delete the listed records (all spaces, or the filtered space) after confirmation
- [x] #9 Unit tests cover the listing query, the pure grouping/search/filter layout, the sidebar page-index mapping, restore (position, space, extension rules) and delete/clear
- [x] #10 Undo Close Tab / Close Both Splits does nothing for a tab whose closed-tab record was consumed (restored from the archive page or by Reopen Closed Tab) or deleted/cleared; a split member whose record is gone stays closed and the other comes back alone; incognito undo unaffected
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Data (TabStore/AppDatabase): archiveEntries() lists every non-incognito space's records (blob-free summaries), classifying extension pages with one shared ExtensionAvailability — uninstalled records purged silently, disabled ones flagged not restorable. restoreClosedTab(recordID:) shares reopenClosedTab's tail (restoredTab + snapped insert at min(sortOrder, count) in the RECORD's space). deleteClosedTabRecord(id:), clearClosedTabRecords(spaceIDs:). New observer callback tabStoreDidUpdateClosedTabRecords() fired after every closedTab mutation in TabStore (close, split close, undo, reopen, restore, delete, clear, space delete/undo).
2. Pure layout (Sidebar/ArchiveListLayout.swift): ArchiveEntry, ArchiveBucket (today/yesterday/N days/N weeks/N months/N years/undated) by calendar-day distance, archiveRows(entries:query:spaceFilter:now:calendar:) — sort closedAt desc then id desc, undated tail by id desc, all-terms search over title + scheme-less url (case/diacritic-insensitive), empty headers dropped; archiveDisplayURL.
3. Pure page-strip mapping (SidebarPageStrip): archive page at strip index 0 when present, space i at i+1; fractional strip page -> space-strip index for the bottom bar highlight.
4. ArchivePageView (search field + Filter menu with spaces and Clear Archive…, table of header/entry rows, empty state, context menu Restore/Delete, Return/Delete keys, swipe passthrough).
5. TabSidebarViewController: archive page in the page strip for non-incognito windows; isShowingArchivePage separate from activeSpaceID; every strip x computation goes through the mapping; neutral tint on the archive page; highlight fades when off-strip; lazy/debounced reload on record changes; showArchivePage(animated:) / dismissArchivePage(animated:).
6. Window + menus: Navigate > Show Archived Tabs and Clear Archived Tabs… (disabled in private windows); restore -> switch to the record's space, select the tab, leave the archive page; Clear confirms with a sheet.
7. Tests: ArchiveListLayoutTests, SidebarPageStripTests, ArchivedTabRestoreTests; then runtime verification.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-09-26: implemented (Opus agent) + reviewed. Full DetourTests: 1728 tests, 0 failures. Review fix: a swipe that interrupts a strip transition now bumps stripAnimationGeneration so the stale completion can't switch spaces mid-swipe. Runtime check (isolated profile, env-gated harness, reverted): Show Archived Tabs slides to the page; 4 records across Home/Work under Today/Yesterday/3 days/1 week headers with space badges; search 'wiki' leaves one row; a posted click on the Work record restored example.net into Work, switched the window there, selected it, left the page, and the list dropped the row live; synthetic swipe right from Home reveals the archive, swipe left returns to Home. Not exercised at runtime: Clear Archive sheet, Filter menu, disabled-extension row (unit-tested in store).

2026-09-26 (user): the archive page has no address bar. The faux address bar moved into the page clip (addressBarHost, frame-based above the strip): it stays put between spaces and rides the first space's page onto the archive (SidebarPageStrip.spaceChromeX, tested); space pages start below it, the archive page takes the full height with its search row centered in the bar's 34pt row. All strip x writes go through setStripX. Verified in-app: space page layout unchanged, mid-swipe the bar slides with the space page, archive shows search in its place. Full suite 1729/0 failures.

2026-09-26 (user): the archive search now matches the address bar — a pill with FauxAddressBar's fill (quaternaryLabel), 0.5 separator border, defaultCornerRadius, 34pt height and 10pt insets, placed exactly in the bar's row; magnifyingglass icon in the lock's spot, borderless text field (system font, tertiary placeholder), clear (xmark.circle.fill) and Filter buttons inside at the trailing end (fixedHoverSize 22, like the bar's buttons). Pill colors re-resolve on appearance change (the address bar itself resolves them once at setup).

2026-09-26 /code-review: undo after restore duplicated the tab (pre-existing with Cmd+Shift+T, easier to hit via the archive). Folded in (user): closeTab's and closeSplitGroup's undo closures check AppDatabase.hasClosedTab(tabID:) and skip consumed/deleted records (incognito pushes none, so it's exempt). Deleted/cleared records' closes no longer undo — the user threw them away. 6 tests in ArchivedTabRestoreTests. Tests run with -derivedDataPath /private/tmp/claude-501/detour-dd because the user's Xcode build shares the default DerivedData (CodeSign 'not signed at all' on the embedded xctest).

Full suite after the undo fix: 1735 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added the Archived Tabs page as the sidebar page left of the first space (swipe or Navigate > Show Archived Tabs): one newest-first list of every non-incognito space's closed and archived records under Arc-style relative-date headers, with search, a space Filter, Clear Archive (menu + main menu, confirmed), and click/context-menu Restore (into the record's own space at its original index, via Reopen Closed Tab's path incl. extension rules) and Delete. Data layer in TabStore/AppDatabase (archiveEntries, restoreClosedTab, delete/clear, tabStoreDidUpdateClosedTabRecords); pure ArchiveListLayout and SidebarPageStrip. Per user feedback the address bar slides away with the first space and the archive's search pill mirrors it. Review fix: close undos skip consumed/deleted records (no duplicate after restore). Verified: full suite 1735/0 failures; in-app harness runs (show, search, cross-space restore, swipe both ways, mid-swipe bar slide, light-mode pill).
<!-- SECTION:FINAL_SUMMARY:END -->
