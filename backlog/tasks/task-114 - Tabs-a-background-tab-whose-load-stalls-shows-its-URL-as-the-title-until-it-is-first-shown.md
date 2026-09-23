---
id: TASK-114
title: >-
  Tabs: a background tab whose load stalls shows its URL as the title until it
  is first shown
status: Done
assignee: []
created_date: '2026-09-23 21:17'
updated_date: '2026-09-23 21:22'
labels:
  - bug
  - tabs
dependencies: []
priority: low
ordinal: 114000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-112 (Sep 23 2026). A tab opened in the background with store.addTab loads in a hidden web view, which WebKit can leave unfinished for a long time when several load at once (see TASK-112 notes). Its sidebar row shows the stripped URL (e.g. 'raycast.com') instead of the document title, even though webView.title is already set, until the tab is first shown.
Cause: load(_:) sets navigationPending, and updateTitle() shows lastAttemptedURL while it is set. The flag is cleared by BrowserTab.didCommitNavigation(), which only the window's navigation delegate calls (BrowserWindowController+Navigation didCommit), or when isLoading goes false. A web view no window has claimed has BrowserTab as its navigation delegate, and that delegate implements only decidePolicy. So the commit never reaches the tab, and the title waits for the load to finish.
Fix direction: have BrowserTab's own WKNavigationDelegate forward didCommit to didCommitNavigation(), skipping error pages the way the window does, so claimed and unclaimed tabs behave the same at commit.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An unclaimed background tab shows the document title once the navigation commits, while the page is still loading
- [x] #2 A claimed tab's behaviour at commit is unchanged (the window still calls didCommitNavigation)
- [x] #3 Regression test with a page whose load never finishes
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Fix (Sep 23 2026): BrowserTab's own WKNavigationDelegate (the unclaimed-web-view delegate) now forwards didCommit to didCommitNavigation(), skipping error pages the same way BrowserWindowController does. didCommitNavigation() now ignores the about:blank commit of a failed session restore (restoringSession && url == about:blank), the same rule as the URL observer's blankAfterFailedRestore. Without it, BrowserTabWakeTests.testFailedWakeOfARestoredTabKeepsItsSession failed (title became 'about:blank'), and the window's commit path had the same latent problem. Tests: DetourTests/BackgroundTabTitleTests (title at commit while a load never finishes; a script-set title while loading). BrowserTabWake, ContentBlockerWhitelist, HistoryTitleUpdate, FaviconLinkBridge, FavoriteFavicon, InternalPage(Integration), TabStore and TabNavigation pass (129 tests). /code-review --fix found nothing.
<!-- SECTION:NOTES:END -->
