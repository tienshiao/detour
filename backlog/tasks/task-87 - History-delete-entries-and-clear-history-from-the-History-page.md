---
id: TASK-87
title: 'History: delete entries and clear history from the History page'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-19 16:51'
updated_date: '2026-09-19 21:28'
labels: []
dependencies:
  - TASK-86
references:
  - Detour/Storage/HistoryDatabase.swift
  - Detour/Browser/TabStore.swift
priority: medium
ordinal: 87000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-86. The History page is read-only; users need to remove entries. HistoryDatabase has no delete API today - only expireOldVisits (90-day expiry at launch).

Deletion is scoped like the view: it removes the PROFILE's visits (historyVisit rows whose spaceID belongs to a space using the tab's profile), never another profile's.

Things to get right:
- historyURL is one global row per URL shared by all profiles. After deleting visits, recompute visitCount / lastVisitTime from the remaining visits, and delete the historyURL row only when no visit in any profile remains. See how expireOldVisits prunes orphans and keep the behaviour consistent.
- historySearch is an FTS5 table synchronized with historyURL; verify row deletes propagate (GRDB synchronize triggers) so deleted URLs stop appearing in search and in command-palette suggestions / bestURLCompletion.
- TabStore keeps an in-memory history dedup cache keyed "url|spaceID" (near recordHistoryVisit); invalidate affected keys so a revisit right after deletion is recorded.
- The delete bridge messages inherit TASK-86's restrictions (main frame of the internal page only); destructive calls must not be reachable from web content or extensions.
- Decide here whether deleting a space should also delete its visits (deleteSpace currently leaves them to age out, invisible to every profile). Recommended: delete them at space deletion.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A single entry can be deleted from the page (button/context menu and Delete key on selection); it disappears without a full reload
- [x] #2 Multiple selected entries can be deleted at once
- [x] #3 A Clear History action offers time ranges (last hour, today, all time) and asks for confirmation before deleting
- [x] #4 Deletion only removes visits belonging to the tab's profile; another profile's visits to the same URL survive, with its visitCount/lastVisitTime recomputed (test)
- [x] #5 A historyURL row is removed only when no visits remain in any profile, and then no longer appears in FTS search, command-palette suggestions, or URL completion (test)
- [x] #6 Revisiting a URL immediately after deleting it records a new visit (dedup cache invalidated) (test)
- [x] #7 Delete bridge messages are rejected from anything but the internal page's main frame (negative tests)
- [x] #8 Deleting a space removes that space's visits (or the task records the decision not to)
- [x] #9 Unit tests cover the new HistoryDatabase delete APIs including aggregate recomputation and orphan pruning
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design decisions (Fable):
A. Bridge stays scope-free: history.delete {ids:[visitID], max 500} and history.clear {range: 'hour'|'today'|'all'}. Native derives the profile's space IDs from the sending tab (HistoryPageBridge.scope) and the SQL deletes only rows WHERE id IN (...) AND spaceID IN (scope) - a forged id from another profile deletes nothing. The page never sends timestamps: native computes the cutoff (today = start of the local day).
B. history.clear is confirmed NATIVELY: an NSAlert sheet on the sending tab's window (destructive button, names the range and the profile). The page cannot fake or skip it; no window (unhosted tab) -> refused. Single/multi delete needs no confirmation (Chrome/Safari parity).
C. In list mode a row is one visit -> delete that visit. In search mode a row stands for a URL (latest in-scope visit) -> the page sends {ids, allVisitsOfURL: true} and native deletes every in-scope visit of those rows' URLs.
D. HistoryDatabase delete APIs run in ONE write transaction: collect affected urlIDs -> delete visits -> for each affected URL set lastVisitTime = MAX(remaining visitTime) and visitCount = MAX(visitCount - deleted, remaining count) (visitCount historically exceeds the visit rows because expireOldVisits never decrements; a plain COUNT would punish other profiles) -> delete historyURL rows with no visits left (FTS follows the synchronized table). Completion returns the affected URL strings.
E. TabStore invalidates recentHistoryWrites for the affected url|spaceID keys (all keys of the scope's spaces for a clear) so an immediate revisit is recorded. If TASK-88 landed: also clear lastRecordedHistoryURL on tabs showing a deleted URL so a later title change cannot touch a row that no longer exists (UPDATE would be a no-op anyway - verify).
F. AC #8: NOT at deleteSpace time - Undo Delete Space restores the space with the same id and must get its history back. Instead sweep visits whose spaceID matches no existing space at launch, next to expireOldVisits, after TabStore has restored spaces (the undo stack does not survive a relaunch).
G. Page UI: row selection (click on a checkbox-like affordance / Shift-range / Cmd+A within the list), Delete/Backspace key, per-row delete button on hover, a selection bar ('N selected - Delete'), and a Clear History menu button with the three ranges. Rows are removed from the DOM on success without a reload; empty day headings removed; pagination keeps working. Still textContent-only, no inline styles/scripts.

Steps: 1. (Opus) DB APIs + tests. 2. (Fable) bridge methods, native confirmation, scope enforcement, cache invalidation, launch sweep. 3. (Opus) page UI + integration tests incl. negative bridge cases for the delete methods and a cross-profile forged-id test. 4. /code-review, in-process runtime verification (click, key, clear + sheet, dark mode), merge.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Committed on task-87-history-deletion (f1686e7); NOT merged yet. AC #8 decision: visits are not deleted in deleteSpace (Undo Delete Space restores the space under the same id and must get its history back); instead visits of spaces that no longer exist are swept at launch, treating spaces deleted this session as existing, and refusing to sweep unless a surviving space has visits (a session DB that failed to restore must not orphan the whole history). Review pass fixed: failed write reported as success; delete mode taken from state.query instead of the rendered row; removal by captured element instead of the live DOM; partial multi-batch failure; clear scope captured before the sheet; sweep vs undo in the first 5 s; historyDidDelete erasing state of visits recorded after the request; per-URL work inside the write transaction (now set-based via a temp staging table); false empty state. Validation: targeted suites 138 tests x3 stable; full suite 1343-1344 tests, 5 skipped - 0 failures in one run, and 1 failure in two runs, both the same unrelated JS-GC timing test (ExtensionPolyfillIntegrationTests.testStorageManagedInRealExtensionContextSurvivesGarbageCollection). Runtime (isolated instance, SCREEN LOCKED so script-driven page events only): row delete, Shift range, Cmd+A, Escape, Clear menu, native sheet text/profile name/destructive button, second clear ignored while the sheet is up, Cancel = no change, Clear All = empty list and 0 visits / 0 URLs / 0 FTS rows; launch sweep removed a vanished space's visits and corrected the shared URL's visitCount. STILL TO VERIFY ON AN UNLOCKED SCREEN before merge / AC #1: real mouse clicks and the Delete key through AppKit, Cmd+A on the page vs the Edit > Select All menu item, and the visual pass in light/dark.
<!-- SECTION:NOTES:END -->
