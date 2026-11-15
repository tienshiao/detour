---
id: TASK-332
title: 'Tabs: Reopen Closed Tab restores a child tab''s link to its opener'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T23:45:00Z'
updated_date: '2026-11-15T00:37:00Z'
labels:
  - tabs
dependencies: []
references:
  - TASK-325
  - TASK-117
  - Detour/Browser/TabCloseSelection.swift
  - wiki/tabs/back-swipe-to-opener.md
priority: low
type: bug
ordinal: 406000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-325. A tab opened from another tab carries parentID, which the Back button, ⌘[ and the back swipe use to close it to its opener. After closing such a tab (for example by a back swipe) and bringing it back with Reopen Closed Tab, the restored tab has no parentID, so Back and the swipe no longer return to the opener. Closed tabs are read from the database only (TASK-117), so the record has to carry it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A reopened child tab whose opener is still open gets its parentID back, so Back, ⌘[ and the back swipe close it to that opener again
- [x] #2 If the opener has been closed, archived or moved to another space meanwhile, the reopened tab has no parentID (no dangling reference)
- [x] #3 Records written before the change still reopen (migration or tolerant read); tests cover the round trip and the missing-opener cases
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Migration v26: closedTab.parentID TEXT (nil for every row before it, which reopen as before). ClosedTabRecord.parentID (default nil); summaries unchanged.
2. Write it on every path that writes a closed-tab record for a normal tab: closeTab (Cmd+W, Back button / back swipe close to opener, archive sweep and manual archive) and closeSplitGroup. Peeks and Quick Detours have no opener (nil). Window close writes no records (spaces are global; Private writes none).
3. One opener rule: Space.openerTab(id:) = a normal tab of the space or a live pinned tab of it; BrowserWindowController.parentTab(for:) uses it on the active space (unchanged behaviour). moveTab's undo keeps its own normal-tabs-only check (out of scope; reported).
4. reopenClosedTabRecord (Reopen Closed Tab and the Archived Tabs page restore) sets parentID only when Space.openerTab resolves it in the space it reopens into; otherwise nil (closed, archived, moved to another space, asleep pinned). The close undos (closeTab, closeSplitGroup) keep restoring their captured parentID unchecked, as before: parentTab(for:) resolves it when used, so a link to a tab that is gone does nothing (Private spaces: undo only).
5. Tests (TabStore level): round trip, closed / archived / moved / Private opener, split close, undo, v25 -> v26 migration keeps old rows reopening.
6. /verify: fixture page, open a child via a target=_blank link, close, reopen, Back closes to the opener; again after closing the opener.
7. Wiki: closed-tabs-and-archive + back-swipe-to-opener (Reopened child row), session-database migration list; log line.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Writers checked: closeTab (Cmd+W, the Back button's / Cmd+['s / the back swipe's close to the opener via navigateBackOrCloseChildTab, manual archive, archive sweep) and closeSplitGroup now write closedTab.parentID; recordClosedPeek and archiveQuickDetourTab have no opener (nil); window close writes no records (spaces are global, Private writes none); Undo Delete Space re-inserts whole records (insertClosedTabs), so the column travels. No other branch (main, epic-claude-extension, batch-b) has a v26.
Decision: the close undos (closeTab, closeSplitGroup) still restore their captured parentID without the reopen check (as before): parentTab(for:) resolves it when used, so a link to a tab that is gone does nothing; AC #2 is about reopen. Private: no record is written, so the Private case is 'no record, the undo keeps the link' plus 'a record naming a Private-space tab reopens unlinked'.
An asleep pinned opener is dropped on reopen (same rule as parentTab(for:)), although its backing tab would keep its id on waking.
Tests: ClosedTabOpenerTests 15/0 (new); with the neighbours: AppDatabaseTests 28, ArchivedTabRestoreTests 20, ClosedPeekTests 11, NavigationSwipeTests 37, QuickDetourArchiveTests 17, SplitTabTests 63, TabStoreTests 40: 231 tests, 0 failures. After the review fixes: ClosedTabOpenerTests 15, MoveTabToSpaceTests 31, NavigationSwipeTests 37: 0 failures.
Runtime (/verify, Debug build, isolated DETOUR_DATA_DIR, automation endpoint, docs/harness/task332-reopen-opener-checks.py, 9/9 passed): target=_blank child -> Cmd+W -> the closedTab row carries the opener id -> Reopen Closed Tab: own swipe mode with opener_id = opener; Cmd+[ with the page focused closes it to the opener; reopened again, a back swipe's completion (navigation_swipe, scripted tracker) closes it to the opener; reopened again, the sidebar's Back button does; then child closed, opener closed, Reopen twice: the opener (new id) and the child with opener_id nil, WebKit's gesture, Cmd+[ leaves it open. The run was on the build before the review's two cosmetic edits (lazy pinned search; a moveTab-undo edit reverted). Not verified: a real trackpad swipe (synthetic events cannot drive trackSwipeEvent), the palette's Back.
Review (/code-review medium --fix): plan step 4 corrected to say the undos are unchecked; openerTab searches the pinned entries lazily; the reviewer also switched moveTab's undo to openerTab (relinks a live pinned opener too), which I reverted as out of scope (reported).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Closed-tab records now carry the tab a closed tab was opened from (closedTab.parentID, migration v26), written by closeTab and closeSplitGroup. Reopen Closed Tab and the Archived Tabs page restore the link only when Space.openerTab(id:) — the Back button's rule, now shared with BrowserWindowController.parentTab(for:) — resolves it in the space the tab reopens into, so a reopened child closes to its opener again by Back, Cmd+[ and the back swipe, and an opener that was closed, archived, moved, or is asleep in a pinned slot leaves no link. Older rows reopen unlinked. Tests: ClosedTabOpenerTests (15) plus neighbouring suites, 0 failures; runtime check docs/harness/task332-reopen-opener-checks.py passed 9/9. Not checked: a real trackpad swipe, the palette's Back. Close undos still restore their captured link unchecked (harmless, resolved at use).
<!-- SECTION:FINAL_SUMMARY:END -->
