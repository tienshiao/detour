---
id: TASK-170
title: >-
  Navigation: when a page-started navigation fails, the error page names the
  page the tab was on, and Reload goes back to it
status: Done
assignee:
  - '@claude'
created_date: 2026-10-10 07:46
updated_date: '2026-10-29T03:19:00Z'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/BrowserTab.swift
  - wiki/platform/wkwebview-delegate-order.md
  - DetourTests/PageOpenedWindowTests.swift
priority: medium
ordinal: 193000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-10 by the review of TASK-167 and confirmed with a test (not committed). In an ordinary selected tab showing page P, the page sets location.href to a URL on a server that refuses the connection. The error page appears, but for P: its failedURL is P's URL, the tab's URL is P and Reload retries P instead of the URL that failed. A link clicked to a dead host should behave the same way (not run). A sign-in popup that has committed one page and is then redirected to a dead callback URL is the same case.

Cause as understood: BrowserTab.didFailProvisionalNavigation raises the error page for lastAttemptedURL. For a load the tab starts itself (load(_:)) that is set up front and protected by navigationPending. For a navigation the page starts, the only source is the URL observer on WKWebView.url, and by the time WebKit reports the provisional failure the web view's URL has gone back to the committed page, so the observer has written P back. WebKit's source commits the page load state before calling the failure delegate; the test agrees with that order but did not observe it directly.

The failed URL is in the error (NSURLErrorFailingURLErrorKey). TASK-167 uses it only when the tab has no URL of its own (nil or about:blank), for a window a page opened. Using it more widely changes what existing tabs show: for a typed URL that redirects to a host that fails, the error would name the redirect target rather than what was typed (and that is what Reload would retry), and a restored session's failure is deliberately not an error page at all (TASK-45). Decide those cases, test first.

The test that showed it (PageOpenedWindowTests fixture): open /opener selected in a window; stop a second loopback server to get a dead port; run location.href = '<dead>/target' in the tab; wait for the error scheme; ErrorPage.originalURL(from:) of the web view's URL was the opener's URL, expected the dead one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A failing test in a real window shows the error page naming the wrong URL for a page-started navigation (script location change and a clicked link) to a server that refuses the connection
- [x] #2 The error page, the tab's URL and Reload all use the URL that failed
- [x] #3 The rule for a typed URL that redirects to a failing host is decided and recorded, and a failed session restore still shows no error page (TASK-45)
- [x] #4 A background tab (its own navigation delegate) and a selected tab behave the same
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Failing tests in a real window and an unowned tab against a just-freed loopback port: script location change, clicked link, typed redirect to the dead host, Reload.
2. Ask the user the redirect rule (answer 2026-10-28: the URL that failed, as Chrome/Safari).
3. didFailProvisionalNavigation adopts NSURLErrorFailingURLErrorKey as lastAttemptedURL (not about:blank, the error scheme or an internal URL), after the TASK-45 restore guard.
4. Restore, unclaimed-tab, page-opened-window and internal-page suites; runtime check; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-28: cause confirmed by the red tests - WebKit sets the web view's URL back to the committed page before reporting a page-started navigation's provisional failure, so the URL observer overwrote lastAttemptedURL with the opener. Red run: 5 of 6 failed naming /page (selected tab, unowned tab, clicked link, Reload) or /redirect (typed redirect); the typed dead URL control passed.
Fix: BrowserTab.didFailProvisionalNavigation takes the error's NSURLErrorFailingURLErrorKey as the URL that failed for every provisional failure (after ignored errors and the restoringSession guard), except about:blank, the error scheme and (review fix) internal detour:// URLs, which Reload would otherwise open with internal-page access. Replaces TASK-167's 'only when the tab has no URL' condition.
Decision (user, 2026-10-28): a load the tab started that redirects to a failing host names the redirect target; Reload retries it.
Review (/code-review --fix): internal-URL guard + test, comments on lastAttemptedURL/loadRecordedURL/awaitingFirstURL and wiki/architecture/browser-tab.md. Not changed: Reload on the error page after a failed form POST now issues a GET to the action URL (before: went back to the form page) - raised with the user; an error without a failing URL key still names the previous page (none seen; the deeper fix would record the main-frame target at provisional start); WebKit's normalisation of the error URL; the freed-port fixture under parallel runs.
Tests: NavigationFailureURLTests 7/7; with BrowserTabWakeTests (TASK-45 restore), BrowserTabUnclaimedNavigationTests, CommittedLoadFailureTests, PageOpenedWindowTests (TASK-167) and every suite touching error pages: 209 passed, 13 skipped (long legs); InternalPage suites 30 passed.
Runtime: Debug build, isolated DETOUR_DATA_DIR, loopback page whose script sets location.href to a closed port: tab URL saved as http://127.0.0.1:61171/gone with the error title; window capture shows the error page, sidebar row and address bar all naming 127.0.0.1:61171/gone. Cleaned up.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A failed provisional navigation now names the URL that failed: the error page, the tab's URL and Reload use the error's failing URL, so a page's location change or a clicked link to a dead host no longer shows and retries the page the tab was on. Per the user's decision, a redirect to a failing host names the target, as Chrome and Safari do. A failed session restore still shows no error page, and an internal URL is never adopted as the retry target. Same behaviour in selected and background tabs (tests for both), checked in the running app. Open point raised with the user: Reload after a failed form POST now retries the action URL as a GET.
<!-- SECTION:FINAL_SUMMARY:END -->
