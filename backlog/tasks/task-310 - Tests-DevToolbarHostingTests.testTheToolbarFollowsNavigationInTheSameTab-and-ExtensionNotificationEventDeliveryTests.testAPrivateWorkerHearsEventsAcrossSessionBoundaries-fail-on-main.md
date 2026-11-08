---
id: TASK-310
title: >-
  Tests: DevToolbarHostingTests.testTheToolbarFollowsNavigationInTheSameTab and
  ExtensionNotificationEventDeliveryTests.testAPrivateWorkerHearsEventsAcrossSessionBoundaries
  fail on main
status: To Do
assignee: []
created_date: '2026-11-08T11:35:00Z'
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
- [ ] #1 Root cause found for each failure (test or product bug)
- [ ] #2 Both pass in a full DetourTests run
<!-- AC:END -->
