---
id: TASK-378
title: >-
  Tab opener: a pinned tab or favourite that goes to sleep loses its own opener
  link
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:55:00Z'
updated_date: '2026-11-16T22:11:00Z'
labels:
  - tabs
  - opener
dependencies: []
references:
  - wiki/tabs/tab-opener.md
priority: low
type: bug
ordinal: 459000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-358's agent. Waking a sleeping pinned tab or favourite builds a new tab at its home page, so the backing tab's own parentID (restored since TASK-358) is lost on wake.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The link survives sleep and wake, or the decision not to keep it is recorded on the tab-opener page
- [x] #2 A test covers it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Premise: the sleep sweep keeps a pinned or favourite backing tab live but asleep (same BrowserTab, parentID kept); the loss is on the DORMANT path: Cmd+W on a pinned tab (closePinnedTab) or a favourite (deactivateFavorite) drops the backing tab, and waking (activatePinnedEntry / activateFavorite, unpin of a dormant entry, a dormant favourite dragged to the tab list) builds a new tab with no parentID. The pinned close's own undo also rebuilds it without the link, unlike the normal close undos (TASK-332).
1. Failing tests first (TabOpenerWindowTests): a pinned child and a favourite child keep their opener across dormant + wake, Back on the woken pinned tab selects the opener; Undo Close Tab of a pinned child keeps it; an opener closed meanwhile leaves none; unpinning a dormant entry carries it; the sweep's sleep/wake keeps it (premise).
2. PinnedEntry and Favorite remember the backing tab's parentID when it goes dormant (in memory: dormantOpenerID); materializeDormantEntry, activateFavorite and restoreFavoriteAsTab put it back through space.liveOpenerID (the TASK-332 rule for a tab coming back with a new id); the closePinnedTab undo does the same.
3. Not persisted while dormant: a relaunch with the entry dormant drops it (needs new columns on pinnedTab and favorite = a migration; not added, reported as a question).
4. Wiki tab-opener (separate asleep from dormant), pinned-tabs-and-folders, favorites; code review; Backlog; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Premise checked: the sleep sweep never lost the link (a pinned or favourite backing tab stays live but asleep, the same BrowserTab; sleep/wake do not touch parentID; TabOpenerWindowTests.testAPinnedTabPutToSleepAndWokenKeepsItsOpener). The loss is on the DORMANT path (Cmd+W, the row's minus button, an extension's tabs.remove, Edit Space moving the space to another profile): the backing tab is dropped and the wake builds a new tab (new id) with no parentID.
Red run (before the fix): 5 of the new tests failed as expected (pinned dormant + wake, pinned close undo, unpin of a dormant entry, favourite dormant + wake and drag to the tab list, Back on a woken pinned tab); the unlinked cases and the sleep premise passed.
Fix: PinnedEntry and Favorite keep dormantOpenerID (in memory), set when the backing tab is dropped (closePinnedTab, deactivateFavorite via a new makeFavoriteDormant shared with the Edit Space profile swap); the tab a wake builds gets it back through space.liveOpenerID in the space it wakes in (materializeDormantEntry: activation and unpin; activateFavorite; restoreFavoriteAsTab); the pinned close undo restores the captured parentID through liveOpenerID, as the normal close undo (TASK-332). From the review: Undo Delete Space (EntrySnapshot) and the deletePinnedEntry undo bring a dormant entry back with the link, and restoreFavoriteAsPinned hands a dormant favourite's link to the new entry.
Chosen by Claude (not yet confirmed by the user): (a) keep the link across dormancy rather than record not keeping it; alternative: drop dormantOpenerID (the woken tab is a fresh home page). (b) put back through space.liveOpenerID in the space the tile wakes in (the rule for a tab coming back with a new id), so a favourite woken in another space than its opener's is unlinked; alternatives: restore unchecked, or check every space of the profile. (c) in memory only.
QUESTION for the user/lead: keeping the link across a relaunch while the tile is dormant needs new columns on the pinnedTab and favorite tables (a migration v27); not added (two lanes running, expensive to reverse).
Not kept (out of scope, reported): a dormant pinned tile dragged to the favourites bar (addFavoriteFromEntry) starts without the link; and the other direction: children of a pinned tab or favourite that went dormant no longer resolve it after its wake (the woken tab has a new id).
Tests: TabOpenerRuleTests + TabOpenerWindowTests + TabStoreTests, ClosedTabOpenerTests, MoveTabToSpaceTests, ExtensionPageFavoriteTests, FavoritePeekPersistenceTests, SplitTabTests, ExtensionTabLifecycleTests, SessionSaveAtomicityTests: 256 passed, 0 failed; UndoAfterDeleteSpaceTests, ExtensionPageUndoTests, FavoriteSpaceHandoffTests, ProfileDeletionUndoTests, PrivateWindowUndoTests, ArcImportTabStoreTests, ProfileDataRemovalTests: 103 passed, 0 failed.
Code review (/code-review medium --fix): fixed by the review (above: Undo Delete Space, Undo Delete pinned, favourite-to-pinned, makeFavoriteDormant dedupe; 3 tests added). Skipped: one makeTab(loading:) opener parameter for the 4 wake sites (cleanup); clearing dormantOpenerID on wake (would lose it when unpinSplitGroup materializes then bails; every dormant transition overwrites it); persistence (question above).
/verify (docs/harness/task378-dormant-opener-checks.py, Debug build from .derived, data dir DetourVerify-377, ALL PASSED, 6 checks): a target=_blank child pinned with Cmd+D, closed to a dormant tile with Cmd+W, woken by selecting the tile (new tab id); Cmd+[ selects the opener and keeps the pinned tab; dormant again with the opener closed meanwhile, Navigate > Back is disabled on the woken tab. Data dir and defaults keys removed.
Not verified at runtime: the favourite cases and the undos (tests only); the full suite (the lead's).

User decisions 2026-11-16: CHANGED (c): YES, keep a dormant pinned tab's or favourite's opener link across a relaunch (new columns on pinnedTab and favorite, migration v27); filed as TASK-384. (a) keeping the link across dormancy stands (the relaunch decision builds on it). (b) (put back through space.liveOpenerID in the space the tile wakes in) was not addressed in the user's answer and stays as built. Also filed: TASK-393 (a dormant pinned tile dragged to the favourites bar loses the link), TASK-394 (children of a tile that went dormant lose their opener after its wake).

User decision 2026-11-16 (later): choice (b) confirmed — a woken pinned tile or favourite gets its opener link back only when the opener resolves in the space it wakes in.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A pinned tab or favourite that goes dormant (Cmd+W and the other paths that drop its backing tab) now keeps its own opener link: the entry or favourite remembers the dropped tab's parentID (dormantOpenerID, in memory) and the tab its wake builds (a click, an unpin, a dormant favourite dragged to the tab list or the pinned section) gets it back through space.liveOpenerID, as does the pinned close undo and the Undo Delete / Undo Delete Space of a dormant entry. The sleep sweep never lost it (same tab). Limits recorded on wiki/tabs/tab-opener.md: not kept across a relaunch while dormant (needs a migration; question), not for a dormant pinned tile dragged to the favourites, not for the tab's own children (the woken tab has a new id). Tests: 9 new (red first), 359 tests across 17 suites passed. Runtime: endpoint harness passed (6 checks).
<!-- SECTION:FINAL_SUMMARY:END -->
