---
id: TASK-358
title: >-
  Tab opener: a pinned or favourite tab's opener is lost at relaunch, and the
  readers disagree on which openers count
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
updated_date: '2026-11-16T09:45:00Z'
labels:
  - tabs
  - opener
dependencies: []
references:
  - wiki/tabs/tab-opener.md
  - Detour/Browser/TabStore.swift
priority: low
type: bug
ordinal: 439000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 while writing wiki/tabs/tab-opener.md (read from the code, not run). (1) parentID is saved for pinned and favourite backing rows but read back at launch only for normal tabs, so after a relaunch Back on a pinned child no longer selects its opener. (2) The readers accept different openers: tabCloseSelectionID and the Move to Space undo accept only a normal tab; Space.openerTab (Back, swipe, reopen, close undos) also a live pinned tab; webViewDidClose uses displayableTab so a favourite's tab counts; openerPlacement can make a favourite's tab the parent, which Back then never resolves.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A pinned or favourite tab's opener link survives a relaunch, or the decision not to keep it is recorded with its reason
- [x] #2 Which tabs count as an opener is one rule shared by every reader (or each difference is deliberate and recorded on the wiki page)
- [x] #3 Tests cover the relaunch case and each reader's opener kinds
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Failing tests first: pinned and favourite backing tabs' parentID through a saveNow/restoreSession round trip; each reader against each opener kind (normal, live pinned, asleep pinned, live favourite, dormant favourite, other space).
2. Part 1: restoreSession reads the saved parentID for pinned and favourite backing rows (raw, unchecked, as for normal tabs; ids are kept so the links resolve). Update the TASK-49 comment in TabRecord+BrowserTab.swift.
3. Part 2: one rule. Space.openerTab(id:) accepts a normal tab, a live pinned tab and a live favourite tab of the space (= displayableTab); every resolving reader goes through it: parentTab(for:) (Back, Cmd+[, swipe), liveOpenerID (reopen, close undos), webViewDidClose, the Move to Space undo (liveOpenerID), tabCloseSelectionID (caller-supplied opener resolution instead of the pinnedTabIDs exclusion, also for a lone tab).
4. Deliberate differences recorded on the wiki: tabInsertionIndex (placement, not resolution), sibling matching by raw id, hasOpenChild (picture cache retention), webViewDidClose opener-before-siblings priority.
5. Check swipe-mode re-evaluation when a favourite is removed or its tab goes dormant.
6. Tests, /verify with relaunch in DetourVerify-358, wiki (tab-opener, back-swipe, tab-insertion-and-close-selection, session-database/persistence), commit.

7. (Built) Move to Space: the forward move keeps the link while it resolves in the destination (liveOpenerID), the undo relinks by the same rule; tabStoreDidUpdateFavorites refreshes the swipe mode.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Red run (before the fix), new TabOpenerRuleTests + TabOpenerWindowTests: 13 of 14 failed as expected (the pinned and favourite relaunch round trips lost parentID; a favourite was no opener for openerTab/reopen/close undo/Back/swipe; Move to Space undo did not relink a live pinned opener; Cmd+W on a lone child of a pinned or favourite opener went to the neighbour); window.close() to a favourite already passed (it used displayableTab). Both parts of the premise confirmed.
Fix: restoreSession reads parentID for pinned and favourite backing rows (raw, unchecked); Space.openerTab(id:) is the one rule (normal, live pinned, live favourite of the space's profile) and every resolving reader goes through it: parentTab(for:), liveOpenerID, webViewDidClose, tabCloseSelectionID (now takes isOpener; a lone child returns to its opener too), Move to Space and its undo; tabStoreDidUpdateFavorites now refreshes the swipe mode.
Green: TabOpenerRuleTests, TabOpenerWindowTests, TabCloseSelectionTests, TabInsertionTests, ClosedTabOpenerTests, MoveTabToSpaceTests, NavigationSwipeTests, PageOpenedWindowTests, FavoritePeekPersistenceTests: 159 passed, 0 failed. TabStoreTests, SplitTabTests, SessionSaveAtomicityTests, ExtensionTabLifecycleTests, MainMenuCharacterizationTests, PrivateWindowUndoTests, QuickDetourArchiveWindowTests, QuickDetourWindowTests, WebKitDelegateReachabilityTests, WindowCloseReleaseTests, ExtensionPageFavoriteTests: 241 passed, 0 failed.
Chosen by Claude (not yet confirmed by the user): (a) a live favourite counts as an opener for every reader, so Back, Cmd+[ and the back swipe on a child of a favourite close it and select the favourite, as for a pinned opener; alternative: drop the favourite line from Space.openerTab (one line), and every reader stops accepting it. (b) closing a child (Cmd+W) returns to its live pinned or favourite opener after its siblings, ahead of the neighbour, as Back does; alternative: isOpener in settleSelectionLeaving accepts only space.tabs (one line). (c) Move to Space keeps a favourite opener when the destination has the same profile (the favourite is there too); alternative: always cut (tab.parentID = nil). (d) A pinned or favourite tab's link is restored unchecked at launch, like a normal tab's (ids are kept, the readers resolve it).

Code review (/code-review medium --fix): no correctness findings; fixed two cleanups (tabStoreDidUpdateFavorites calls refreshNavigationSwipeModes after the active-profile guard instead of the full store-change pass; the Move to Space undo comment corrected for the favourite case); skipped merging openerTab into displayableTab (the one-line-per-kind layout is the flip point), a shared parentID decode helper (matches the existing normal-tab line); I dropped the duplicate close-selection test it flagged. Added TabInsertionTests.testFavouriteParentPlacesLikeAPinnedOne. Rerun after the fixes: the 9 opener suites, 159 passed, 0 failed.
/verify (docs/harness/task358-opener-relaunch-checks.py, Debug build from .derived, data dir DetourVerify-358, three launches, ALL PASSED, 10 checks): a target=_blank child pinned with Cmd+D writes its opener into its backing row (sortOrder -1); after a relaunch Cmd+[ on the pinned child selects the opener and keeps the pinned tab; with the opener's row turned into a favourite with sqlite3 and a relaunch, the normal child has the own swipe with opener_id = the favourite, Cmd+[ closes it and selects the favourite, Cmd+[ on the pinned child selects the favourite, and Cmd+W on a lone Cmd+clicked child of the favourite (neighbour below it) returns to the favourite. Detour stayed in the background; data dir, defaults keys and WebKit stores removed.
Not verified: the real trackpad swipe on a child of a favourite (the mode and opener_id were read through navigation_swipe; the gesture itself is the TASK-325 code path); Cmd+W to a pinned opener at runtime (window test only); the full suite (the lead's).

Correction to decision (c): Move to Space keeps the link while it resolves in the destination by the one rule (a favourite of the destination's profile, or an opener moved there before the child), not only a favourite; before, it was always cut. Alternative: always cut (tab.parentID = nil in moveTab). Covered by TabOpenerRuleTests.testAChildFollowingItsOpenerToAnotherSpaceKeepsTheLink (undo takes the child home unlinked). TabOpenerRuleTests + TabOpenerWindowTests + MoveTabToSpaceTests rerun: 46 passed, 0 failed. Wiki runtime-check section added on tab-opener.md.
Out of scope, found: the sidebar Back button's enabled state is recomputed only in the selected tab's canGoBack sink, so it stays enabled when the selected child's opener closes or (now) a favourite opener goes dormant; pressing it then does nothing. Predates this task (the same for a normal opener closing). A pinned tab or favourite that sleeps loses its own link (waking builds a new tab at its home page).

Follow-up (lead's full run on 0818dadb: ExtensionOriginTrackingPreventionTests.testTrackingPreventionPassSparesOriginsWithALoggedInteraction timed out waiting for itp-purged.example's localStorage to go). No TASK-358 code runs in that test (it adds a profile, loads a probe extension, drives an ITP pass; the test host's session DB had no tabs, so the restore change does nothing; the favourites refresh fires only for a window whose active space is on that profile). It passed 12 times on 0818dadb here (alone, with the suite, after the window suites). Cause found in WebKit: a new ITP database grandfathers the domains that have website data when the store populates, exempting them for 7 days (grandfatheringTime), and the test advanced the clock one day; a passing run's observations.db had itp-kept.example grandfathered and itp-purged.example not, so the population lands mid-write, and a run that also catches itp-purged spares it. Fix in the test: advance eight days (past the window; the pass then ignores and clears grandfathering; interaction expiry counts operating dates, so the kept origin is unaffected). ITP suite 3x 7/7; with the opener suites 167 passed, 0 failed. Wiki: data-store-and-itp.md trap.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A pinned or favourite tab's opener link now survives a relaunch: restoreSession reads the saved parentID for pinned and favourite backing rows, unchecked, as for normal tabs (ids are kept). Which tabs count as an opener is one rule, Space.openerTab(id:) (a normal tab, a live pinned tab or a live favourite of the space's profile), used by every reader that resolves the link: Back, Cmd+[ and the back swipe (parentTab(for:)), the close selection (tabCloseSelectionID now takes an isOpener predicate, and a lone child returns to an opener outside the list), window.close(), Reopen Closed Tab and the close undos (liveOpenerID), and Move to Space and its undo. Deliberate exceptions recorded on wiki/tabs/tab-opener.md: tabInsertionIndex (placement), sibling matching (raw id), hasOpenChild (picture retention), window.close()'s opener-first order. Favourite changes now refresh the swipe mode. Tests: new TabOpenerRuleTests (9) and TabOpenerWindowTests (5), confirmed red first; TabCloseSelectionTests and TabInsertionTests extended; 159 + 241 tests across the affected suites passed. Runtime: three-launch harness passed. Chosen by Claude, to confirm: favourites count as openers; Cmd+W returns to a pinned or favourite opener ahead of the neighbour; Move to Space keeps a favourite opener within the profile.
<!-- SECTION:FINAL_SUMMARY:END -->
