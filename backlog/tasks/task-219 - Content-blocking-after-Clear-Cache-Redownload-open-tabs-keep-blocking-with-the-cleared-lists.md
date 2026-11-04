---
id: TASK-219
title: >-
  Content blocking: after Clear Cache & Redownload, open tabs keep blocking with
  the cleared lists
status: To Do
assignee: []
created_date: '2026-10-27 22:21'
labels:
  - content-blocking
  - bug
dependencies: []
references:
  - wiki/features/content-blocking.md
priority: low
ordinal: 255000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-202. Clear Cache & Redownload removes the compiled lists and recompiles them, but web views that are already open keep the old WKContentRuleLists in their user content controllers until the rules next change (a list toggled, an update compiled). Pre-existing; the wiki's content-blocking page notes it. Open tabs should switch to the recompiled lists (or to none while a list is missing) as soon as the clear lands.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After Clear Cache & Redownload, every open tab's web view uses the freshly compiled lists once they are ready, without a reload by the user
- [ ] #2 If a redownload fails, open tabs stop using the cleared list
- [ ] #3 Covered by a test on the manager's rule-list hand-off, and checked at runtime with a loopback page
<!-- AC:END -->
