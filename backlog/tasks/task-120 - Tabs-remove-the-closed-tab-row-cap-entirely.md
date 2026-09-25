---
id: TASK-120
title: 'Tabs: remove the closed-tab row cap entirely'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-25 07:15'
updated_date: '2026-09-25 07:23'
labels:
  - tabs
dependencies: []
ordinal: 120000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Product decision (Sep 25 2026): closed-tab records are never evicted by count. The Archived Tabs panel (TASK-119) gets a 'Clear Archive' button and menu item, which is the user's way to bound the table; retention tied to history stays a separate, on-hold concern (TASK-118). Remove AppDatabase.closedTabCap and trimClosedTabs (both the per-kind trim in pushClosedTab and the trim in insertClosedTabs), their tests, and every doc mention of a cap. Known trade-off: rows and their interactionState blobs (avg ~8.5 KB, max ~188 KB seen) accumulate until cleared.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No closed-tab record is ever deleted because of a row count; pushClosedTab and insertClosedTabs only insert
- [x] #2 closedTabCap and trimClosedTabs are gone from AppDatabase along with the cap tests; a test asserts more than 100 records of one kind survive
- [x] #3 docs/data-model.md and docs/tab-lifecycle.md describe the table as uncapped, bounded only by Clear Archive (TASK-119) and future retention (TASK-118)
- [x] #4 Existing closed-tab, reopen and Delete Space undo tests pass
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (Opus subagent): closedTabCap and trimClosedTabs removed; pushClosedTab/insertClosedTabs only insert; four cap tests replaced by testClosedTabRecordsAreNeverEvictedByCount (150+150 records, none evicted, insertClosedTabs adds without removing). Docs updated. Targeted suites: 149 tests, 0 failures.

Review (/code-review --fix low): clean, nothing applied. Validation: full DetourTests suite passed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The closed-tab row cap is gone: AppDatabase.closedTabCap and trimClosedTabs removed, pushClosedTab and insertClosedTabs only insert, docs describe the table as uncapped (bounded by Clear Archive in TASK-119 and future retention in TASK-118). Verified with testClosedTabRecordsAreNeverEvictedByCount and the full suite.
<!-- SECTION:FINAL_SUMMARY:END -->
