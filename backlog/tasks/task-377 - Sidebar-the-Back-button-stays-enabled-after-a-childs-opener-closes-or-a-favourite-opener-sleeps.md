---
id: TASK-377
title: >-
  Sidebar: the Back button stays enabled after a child's opener closes or a
  favourite opener sleeps
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:55:00Z'
updated_date: '2026-11-16T21:45:00Z'
labels:
  - sidebar
  - tabs
  - opener
dependencies: []
references:
  - wiki/tabs/tab-opener.md
priority: low
type: bug
ordinal: 458000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-358's agent. The sidebar Back button's enabled state is recomputed only when the selected tab's canGoBack changes; when the selected child's opener closes (or, since TASK-358, a favourite opener goes to sleep) it stays enabled and pressing it does nothing. Pre-existing for normal openers.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Back's enabled state follows whether parentTab(for:) resolves, refreshed when an opener closes, sleeps or moves
- [x] #2 A test covers it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Failing tests first (TabOpenerWindowTests): Back button enabled on a child of a normal / pinned / favourite opener, then disabled when the opener closes, its pinned entry goes dormant, the favourite is deactivated or removed, or the opener moves to another space; re-enabled when the opener comes back by undo; canGoBack keeps it enabled; Navigate > Back validation agrees.
2. One predicate on BrowserWindowController (canNavigateBack: the Peek's canGoBack while one is up, else the selected tab's canGoBack or parentTab(for:) resolving); the canGoBack sink and a refreshBackButton() called from the TabStoreObserver sites that already refresh the swipe mode (opener inserted/removed/pinned/unpinned/slept/woken, favourites updated) both use it.
3. Navigate > Back: BrowserWindowController implements pageCanGoBack with the same predicate and BrowserCommands.back's rule becomes pageCanGoBack in every window (was: always enabled in a browser window); update BrowserCommandRegistryTests.
4. Wiki (tab-opener, back-swipe-to-opener, browser-commands), /verify through the endpoint (run_menu_item refusal + sidebar screenshot), code review, Backlog notes, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Red run (before the fix), new TabOpenerWindowTests: 4 of the 5 Back-state tests failed as expected (button and Navigate > Back stayed enabled after a normal opener moved to another space or closed, a pinned opener went dormant, a favourite opener was deactivated or removed; on a root tab only the menu item was wrong, since it was always enabled in a browser window); the history case passed.
Fix: one predicate, BrowserWindowController.canNavigateBack (a Peek up: its canGoBack; else the selected tab's canGoBack or parentTab(for:) resolving). The displayed tab's canGoBack sink and refreshBackButton() both use it; refreshBackButton() runs from the same TabStoreObserver sites that re-decide the swipe mode (new private openersDidChange in +TabStore: tab inserted/removed, pinned entry inserted/removed/updated, pin/unpin; plus tabStoreDidUpdateFavorites) and from deselectAllTabs (review cleanup: single writer). Navigate > Back: the controller answers pageCanGoBack with canNavigateBack and BrowserCommands.back's rule is pageCanGoBack in every window kind (was isBrowserWindow || pageCanGoBack), so the menu item, Cmd+[ and the palette's Back agree with the button.
Chosen by Claude (not yet confirmed by the user): Navigate > Back (and the palette's Back) is now disabled whenever the sidebar button is, i.e. on a root tab with no history too; alternative: keep it always enabled in a browser window (restore the isBrowserWindow || part of the rule, one line). Forward is left as it was (always enabled in a browser window, the button follows canGoForward); not changed, out of scope.
Tests: TabOpenerWindowTests, TabOpenerRuleTests, BrowserCommandRegistryTests, MainMenuCharacterizationTests (Back off in the three browser-window enablement goldens: root tabs), BackForwardResponderTests, PaletteCommandWindowTests, NavigationSwipeTests, QuickDetourWindowTests, PageOpenedWindowTests, ClosedPeekTests: 155 passed, 0 failed.
Code review (/code-review medium --fix): no correctness findings. Fixed: deselectAllTabs now calls refreshBackButton() instead of writing the button. Added from it: a Peek test (Back follows the Peek's history). Skipped: canNavigateBack follows a saved Peek while another window owns the view (pre-existing navigateBackOrCloseChildTab behaviour); tabStoreDidUpdateSpaces does not refresh Back on a space's profile change (the rehost re-select refreshes it); the pageCanGoBack/canNavigateBack double name; the tests' 50 ms run-loop turn for the sink.
/verify (docs/harness/task377-back-enabled-checks.py, Debug build from .derived, data dir DetourVerify-377, ALL PASSED, 8 checks): Navigate > Back refused as disabled on a root tab; on a target=_blank child the chevron is drawn enabled (darkest luma 113 vs 183); after the opener is archived from its row's menu with the child selected, Navigate > Back and Cmd+[ are refused as disabled, the chevron is drawn as on the root tab (183), the child stays open; Detour stayed in the background. Data dir and defaults keys removed.
Not verified at runtime: the pinned-dormant and favourite cases (tests only); the full suite (the lead's).

User decisions 2026-11-16: kept as built: Navigate > Back (and the palette's Back) is disabled whenever the sidebar button is, a root tab with no history included; Forward unchanged.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The sidebar Back button and Navigate > Back are now enabled by one rule, BrowserWindowController.canNavigateBack: with a Peek up its history, else the selected tab's history or an opener parentTab(for:) resolves. The button is re-read on the tab's canGoBack and on every store change that can make an opener resolve or stop resolving (the TabStoreObserver sites that already re-decide the back swipe's mode: a tab or pinned entry inserted, removed, pinned, unpinned, put to sleep or woken; the favourites changed), so it is disabled once a child's opener closes, goes dormant, is removed or moves to another space, and enabled again when it comes back. Navigate > Back (and Cmd+[, the palette's Back) answers pageCanGoBack with the same rule instead of being always enabled in a browser window (Claude's choice, to confirm). Tests: 6 new window tests (red first), registry and menu goldens updated; 155 tests across 10 suites passed. Runtime: endpoint harness passed (8 checks).
<!-- SECTION:FINAL_SUMMARY:END -->
