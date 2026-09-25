---
id: TASK-122
title: >-
  Navigation: a background (unowned) tab whose load fails never shows the error
  page — BrowserTab's own delegate has no failure handlers
status: Done
assignee:
  - '@claude'
created_date: '2026-09-25 18:35'
updated_date: '2026-09-25 19:24'
labels:
  - bug
  - navigation
dependencies: []
priority: medium
ordinal: 122000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during the TASK-121 review. While no window owns a tab's web view (a Cmd+click / 'Open in New Tab' / tabs.create({active:false}) load, or a tab that has not been selected since its window claimed another), BrowserTab is its own WKNavigationDelegate (see 'Unclaimed web views' in BrowserTab.swift). That delegate implements decidePolicyFor and didCommit only; didFailProvisionalNavigation and didFail are missing. A genuinely failing background load (unreachable host, DNS failure, connection refused) therefore leaves the web view on about:blank or the previous content with no error page, and selecting the tab later does not surface the failure — the window's delegate is installed after the fact. This is also why TASK-121 was window-dependent.

Fix: give BrowserTab's delegate the same two failure callbacks the window controller has, forwarding to the tab's existing didFailProvisionalNavigation(error:) / didFailNavigation(error:) behind the same isIgnoredNavigationError guard. The TASK-45 protection (a failed restore of a cached session keeps the session; restoringSession guard) lives in those tab methods and must keep holding.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A tab loaded while no window owns its web view (BrowserTab(id:) + load(_:), no window) whose navigation fails with a real error shows the error page: webView.url has the browser-error scheme and ErrorPage.originalURL(from:) is the attempted URL
- [x] #2 A superseded background load (load A immediately followed by load B, so A fails with NSURLErrorCancelled) does not show the error page; B's URL is what the web view ends on
- [x] #3 A restored-asleep tab whose wake kick fails for real while unowned keeps its restored session, title and favicon and shows no error page (TASK-45 protection holds through the new delegate path)
- [x] #4 Existing BrowserTabWakeTests and NavigationErrorClassificationTests still pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. In BrowserTab's 'Unclaimed web views' WKNavigationDelegate extension (BrowserTab.swift), add webView(_:didFailProvisionalNavigation:withError:) and webView(_:didFail:withError:) mirroring BrowserWindowController+Navigation: guard !error.isIgnoredNavigationError, then forward to didFailProvisionalNavigation(error:) / didFailNavigation(error:). Update the extension's doc comment (it currently says only policy + commit are implemented).
2. New DetourTests/BrowserTabUnclaimedNavigationTests.swift: real connection-refused failure (127.0.0.1:1) while unowned shows the error page; a superseded load (A then B) shows none; a restored-asleep tab whose kick fails for real while unowned keeps its session (TASK-45), all without calling the tab's didFail* methods directly.
3. xcodegen generate; run BrowserTabWakeTests, NavigationErrorClassificationTests and the new tests (sandbox off, one xcodebuild at a time).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented by adding didFailProvisionalNavigation/didFail to BrowserTab's unclaimed-web-view delegate, guarded by isIgnoredNavigationError, forwarding to the tab's existing handlers (TASK-45 restoringSession guard holds). New BrowserTabUnclaimedNavigationTests (3 tests) use a just-freed loopback port for a real connection-refused failure and a held listen socket for a load that stays provisional. Mutation-checked: without the fix the error-page test fails; without the guard the superseded test fails; without the restoringSession guard the restore test fails. 19 tests pass (3 new + 7 BrowserTabWakeTests + 9 NavigationErrorClassificationTests).

Finding while testing: http://127.0.0.1:1/ never fails in WebKit — port 1 is on WebKit's restricted-port list and it silently commits about:blank with didFinish and no failure callback. So BrowserTabWakeTests' 'connection-refused' comments describe that, not a real failure, and a restricted-port URL shows no error page in Detour at all (owned or unowned). Separate gap, not addressed here.

Code review (/code-review --fix) follow-ups: (1) the isIgnoredNavigationError guard now lives once inside BrowserTab.didFailProvisionalNavigation/didFailNavigation; the tab's and the window's delegate methods are pure forwarders. (2) file-private webKitErrorDomain constant replaces the repeated literal. (3) Window close hands navigation delegates back: a window stays delegate of every web view it ever hosted (nothing clears it on tab switch; tab(owning:) relies on that), and the reference is weak, so after the window closed those web views had no delegate at all — no TASK-69 preferences, no TASK-114/122 bookkeeping. windowWillClose now calls handBackNavigationDelegates(), which resets navigationDelegate to the tab for every space/pinned/favourite tab and peek whose web view still names this window (widened from the review's selected-tab-only version, and moved out from behind releaseOwnedWebViewHandlers' ownership guard). 56 tests pass across BrowserTabUnclaimedNavigation, NavigationErrorClassification, BrowserTabWake, ExtensionActiveTab, ProductionDefaultsIsolation, SidebarVisibilityState, UnhandledKeyFallthrough. Correction to the description: a tab deselected within a live window keeps the window as delegate (reached via tab(owning:)); only never-claimed tabs and tabs of a closed window were delegate-less.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
BrowserTab's own WKNavigationDelegate (used while no window owns the web view) now implements the two failure callbacks, mirroring the window controller, so a failing background load shows the error page instead of sitting silently until selected. Verified with BrowserTabUnclaimedNavigationTests (real refused connection, superseded load, failed restore keeping its TASK-45 session) plus the existing wake and classification tests: 19 pass.
<!-- SECTION:FINAL_SUMMARY:END -->
