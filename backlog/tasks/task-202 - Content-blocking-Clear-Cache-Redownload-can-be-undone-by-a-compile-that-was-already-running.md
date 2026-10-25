---
id: TASK-202
title: >-
  Content blocking: Clear Cache & Redownload can be undone by a compile that was
  already running
status: To Do
assignee: []
created_date: '2026-10-25 09:39'
labels:
  - bug
  - content-blocker
dependencies: []
priority: low
ordinal: 238000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-200 code review 2026-10-25 (finding 1; predates TASK-200, whose per-list compile queue widens the window). ContentRuleStore.invalidateAll (Clear Cache & Redownload) does not cancel compiles waiting in waitingCompiles or already in flight. They complete afterwards and record their chunks and compiled counts, and the manager records rulesFormat, all from text that was just deleted.

Scenario: at launch the TASK-199 recompile from cache is running; the user clicks Clear Cache & Redownload; invalidateAll clears the store; the old compile completes and repopulates compiledLists and rulesFormat. If the redownload then fails (offline), the list the user cleared is back and marked current-format while its cached text, ETag and lastFetch are gone.

Fix direction: a per-list generation (or cancellation token) bumped by invalidateAll and by removing a list (filter list disabled); a compile records its result only if its generation is still current, otherwise removes what it compiled. Decide what a cancelled compile reports to the manager: an empty result triggers onMiss and a full download, so it probably needs a distinct 'superseded' outcome. Related: the drop branch for a superseded download compile never clears refreshingIdentifiers (review finding 2, practically unreachable today).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A compile that started or was queued before Clear Cache & Redownload (or before its list was disabled) does not record its lists, counts or rulesFormat afterwards; tested with an injected slow compile
- [ ] #2 A superseded compile has its own outcome, distinct from 'no cached text', so it doesn't trigger an extra download; refreshingIdentifiers is always cleared
- [ ] #3 Checked at runtime: Clear Cache & Redownload during the launch recompile, offline, leaves no list attached and no stale rulesFormat
<!-- AC:END -->
