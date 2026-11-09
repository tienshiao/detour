---
id: TASK-310
title: >-
  Tests: DevToolbarHostingTests.testTheToolbarFollowsNavigationInTheSameTab and
  ExtensionNotificationEventDeliveryTests.testAPrivateWorkerHearsEventsAcrossSessionBoundaries
  fail on main
status: Done
assignee: []
created_date: '2026-11-08T11:35:00Z'
updated_date: '2026-11-09T00:13:00Z'
labels:
  - tests
  - bug
dependencies: []
priority: medium
ordinal: 371000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the Nov 8 2026 batch's full DetourTests run (3882 tests, 18 skipped, 2 failures). Both fail deterministically when run alone, on the batch's branch AND on main before the batch (9043cd2), so they predate TASK-297..309; last known full pass was 3653/0 on Nov 7.
- DevToolbarHostingTests.swift:123: after local → remote → another local URL in the same tab, the Dev Mode toolbar's urlButton still shows http://app.test:3000/ instead of http://app.test:3000/settings?tab=1 (the toolbar shows again but its URL isn't refreshed).
- ExtensionNotificationEventTests.swift:967: the Private worker never answers after a Private session boundary (reply: timeout). Possibly related to TASK-298's change to Private session lifetime (data cleared when the last Private window closes).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Root cause found for each failure (test or product bug)
- [x] #2 Both pass in a full DetourTests run
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, root causes. (1) DevToolbarHostingTests.testTheToolbarFollowsNavigationInTheSameTab: a test race, not a product bug. The test sets tab.url by hand while the tab's real web view is still loading http://app.test:3000/ (never resolves); BrowserTab's webView.url observer writes tab.url when WebKit reports, so a late report put localURL back after the test's assignments and the toolbar (which reads tab.url) showed it. Intermittent (failed on iteration 3 of 10 alone). Fix: wait for the web view's own load to end before moving tab.url (waitForTheWebViewToSettle); 30/30 iterations pass. (2) ExtensionNotificationEventDeliveryTests.testAPrivateWorkerHearsEventsAcrossSessionBoundaries: the test (TASK-264) assumed Private extension contexts stay loaded across a session END; TASK-298 (0997a87, landed just before the 9043cd2 baseline, hence 'pre-existing') resets the Private profile when the last Private window closes: contexts unloaded, data cleared, allowed ones reloaded on a fresh origin. The old page then talked to a gone worker (reply: timeout). Product behaviour is right; the test is rewritten as testAPrivateWorkerHearsEventsAfterTheSessionStartsAndInItsReloadAfterItEnds: the start keeps the park (TASK-264), after the end it awaits profile.privateSessionReset, opens a page on the reloaded context, and checks a dismissal reaches the reloaded worker (new instance). Passes alone and 5/5 iterations. Wiki polyfill-layer bullet corrected (start keeps the park; end resets). Full DetourTests: 3908 tests, 18 skipped, 0 failures, no host restarts.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Both failures were tests out of step, not product bugs: the dev toolbar test raced its tab's real web view load (now waits for it to end), and the Private worker test still expected contexts to survive a Private session's end, which TASK-298 changed to a reset and reload (rewritten to follow the reloaded worker). Full suite 3908/0.
<!-- SECTION:FINAL_SUMMARY:END -->
