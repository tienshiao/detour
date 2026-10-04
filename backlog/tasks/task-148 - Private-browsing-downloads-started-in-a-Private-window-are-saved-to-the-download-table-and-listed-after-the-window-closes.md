---
id: TASK-148
title: >-
  Private browsing: downloads started in a Private window are saved to the
  download table and listed after the window closes
status: Done
assignee: []
created_date: '2026-10-04 02:29'
updated_date: '2026-10-04 08:46'
labels: []
dependencies: []
references:
  - Detour/Browser/Downloads/DownloadManager.swift
  - wiki/architecture/incognito.md
priority: medium
ordinal: 171000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
DownloadManager (Detour/Browser/Downloads/) has no notion of incognito: nothing in the directory checks the profile or space a download came from. A download started in a Private window is added to the shared list, shown in every window's downloads popover, and written to the download table in browser.db (filename, source URL, destination path) by the debounced save, so it is still listed after the Private window closes and after a relaunch. Private browsing otherwise records no history and discards its data store on window close (wiki/architecture/incognito.md).

Read from the code while writing wiki/architecture/incognito.md; not observed. The downloaded file itself staying on disk is expected (as in other browsers); the question is the record. Decide the intended behaviour first: Safari and Chrome both keep the file and drop the list entry when the private session ends.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The intended behaviour is decided and recorded in the task (for example: listed while the Private window is open, never written to browser.db, removed from the list when the window closes)
- [x] #2 A download from a Private window leaves no row in the download table, verified by a test that fails before the fix; downloads from normal windows are unaffected
- [x] #3 A Private download is not shown in other windows' popovers if the decision says so
- [x] #4 wiki/architecture/incognito.md and wiki/features/downloads.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Model: DownloadScope (.normal / .incognito(spaceID:)) carried on DownloadItem, with the rules as small pure functions: isPersisted, isListed(inWindowWith:), isOrphaned(liveIncognitoSpaceIDs:).
2. DownloadManager: handleNewDownload / addManualItem take the scope; items(in:), hasActiveDownloads(in:) and clearCompleted(in:) are per scope; saveNow, removeDownload and clearCompleted touch the table only for persisted scopes; a Private state change schedules no save. The manager observes TabStore (tabStoreDidUpdateSpaces) and drops the downloads of incognito spaces that no longer exist; one still in flight moves to an unlisted set that the delegate lookups still search and is discarded at its terminal state.
3. Window: BrowserWindowController.downloadScope (its incognito space, else normal) is passed at the three creation sites, to the popover, and used for the badge.
4. Red first: DownloadManagerTests with the three rule functions stubbed to the old behaviour (everything persisted, listed everywhere, never orphaned), then implement the rules.
5. wiki/architecture/incognito.md (Downloads gap -> what is not kept), wiki/features/downloads.md, lint, log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (AC #1), made by the supervising session before implementation. A download started in a Private (incognito) window:
- is never written to the download table: not by the debounced save and not by the termination flush;
- is listed only in the downloads popover of the Private window it came from (the same incognito space), and only that window's download badge reflects it; other windows' popovers and badges never show it;
- is dropped from the list when its Private window closes (its incognito space is removed). If it is still in flight then, it keeps running to completion and the file stays on disk, as in Safari and Chrome, but it is listed nowhere, and its item is discarded when it reaches a terminal state. The manager keeps the item until then so the WKDownload stays retained and the delegate callbacks still resolve it;
- the file on disk is kept.
Downloads from normal windows are unaffected and stay visible in every normal window.

Implemented on an agent worktree branch, on top of the TASK-143 commit (review and finalization by the supervising session).

What changed
- DownloadScope (.normal / .incognito(spaceID:)) is fixed on every DownloadItem at creation. The rules are three small functions on it: isPersisted (normal only), isListed(inWindowWith:) (equal scopes), isOrphaned(liveIncognitoSpaceIDs:).
- DownloadManager: handleNewDownload / addManualItem take the scope; items(in:), hasActiveDownloads(in:), clearCompleted(in:) replace the unscoped forms; saveNow, removeDownload and clearCompleted touch the download table only for persisted scopes, and a Private state change schedules no save. The termination flush goes through the same saveNow filter.
- Window close: DownloadManager.shared observes TabStore.shared (observeIncognitoSpaces(of:)); on tabStoreDidUpdateSpaces, the only signal removeIncognitoSpace sends, it drops the downloads of incognito spaces that no longer exist. An ended one is discarded; one in flight moves to unlistedItems (read by no window, searched by the WKDownloadDelegate lookups) and is discarded when it ends or is removed.
- BrowserWindowController.downloadScope (the incognito space the window was created with, else .normal) is passed at the three creation sites, to DownloadPopoverViewController(scope:), and used for the badge.

Design choices beyond the recorded decision
- Strict partition: a Private window lists only its own downloads, so it does not list normal downloads either, and Clear in one window never clears another scope's list.
- Cleanup hooks the existing TabStoreObserver callback rather than a direct call from removeIncognitoSpace, reconciling against the store's live incognito spaces, so any path that removes one is covered.

TDD: the plumbing went in first with the three rule functions stubbed to the old behaviour (everything persisted, listed everywhere, never orphaned). Of the 34 tests then, 19 failed: the 3 pure-rule tests (testOnlyANormalWindowsDownloadsArePersisted, testAWindowListsOnlyTheDownloadsOfItsOwnScope, testAPrivateDownloadIsOrphanedOnceItsSpaceIsGone); no-row tests (testAPrivateDownloadLeavesNoRowInTheTable, testANormalDownloadIsStillSavedNextToAPrivateOne, testTheTerminationFlushDoesNotWriteAPrivateDownload, testAPrivateDownloadIsNotListedAfterARelaunch); per-window tests (testEachWindowListsItsOwnDownloads, testNormalWindowsShareOneListNewestFirst, testOnlyTheOwningWindowsBadgeShowsAPrivateDownloadInFlight, testANormalDownloadInFlightDoesNotBadgeAPrivateWindow, testClearInANormalWindowLeavesPrivateDownloadsListed, testClearInAPrivateWindowLeavesNormalDownloadsAndTheirRows); close tests (testClosingThePrivateWindowDropsItsDownloadsFromTheList, testAnotherPrivateWindowKeepsItsDownloads, testADownloadStillRunningWhenItsWindowClosesKeepsRunningUnlisted, testAnUnlistedDownloadThatFailsIsDiscarded, testRemovingAnUnlistedDownloadDiscardsItQuietly); and DownloadWindowScopeTests.testClosingAPrivateWindowDropsItsDownloadsFromTheSharedManager. The 12 TASK-143 tests and 3 guards (other space changes keep a Private download listed, closing a Private window leaves normal downloads and rows, a Private window's downloadScope) passed before and after.

Tests run after the fix (own DerivedData, DETOUR_DATA_DIR=DetourTests-downloads), 76 tests, 0 failures: DownloadManagerTests 32, DownloadWindowScopeTests 2, InitialWindowFocusTests 7, CommandPaletteFocusTests 4, MoveTabToSpaceTests 31 (the last three because they open and close Private windows or add incognito spaces).

Not verified
- Nothing was run in the app: the popover and badge of a Private window next to a normal one were not looked at.
- Whether WebKit keeps a real WKDownload running after removeIncognitoSpace tears down the web view that started it. The tests use a manual item; the item is kept and resolved, but the continued transfer is WebKit's.
- The scope passed at the three creation sites in BrowserWindowController+Navigation is covered only through downloadScope, not by starting a download.
- /code-review and /verify are left to the supervising session.

Noticed, not changed: a CRX fetch started in a Private window that then closes still ends in finishCRXInstall if the window controller is alive (it is captured weakly), as before this task.

Docs: wiki architecture/incognito (downloads moved from the gaps to the rules), features/downloads (Private windows section, edge cases, tests), log; docs/data-model.md download table note.

Runtime check 2026-10-04, harness build of the batch branch at 822e798, isolated profile, SCREEN LOCKED (so no real key or mouse events; calls go through the app's own entry points).
With a normal and a Private window: the normal window listed only normal.bin, the Private window only its two downloads, and only the Private window's badge was on. After the debounce the download table held normal.bin alone. Closing the Private window emptied its list, kept the still-running Private item unlisted, and removed the incognito space. Items were manual ones (no real WKDownload), so whether WebKit keeps a transfer running after the window closes is still not verified.

Integrated on branch bugfix-batch; full DetourTests suite there: 1970 tests, 11 skipped (gated measurement legs), 0 failures. Code review of the batch range run with --fix.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Decision: a Private window's downloads are listed and badged only in that window, never written to the download table, and dropped from the list when the window closes; a download still running then keeps going unlisted and is discarded when it ends; the file stays on disk. A Private window does not list normal downloads either. DownloadScope carries the rules; tests failed before the fix. Checked in the launched app with manual items. Not verified: that WebKit keeps a real transfer running after the Private window closes; such a download cannot be cancelled once its window is gone.
<!-- SECTION:FINAL_SUMMARY:END -->
