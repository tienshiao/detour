---
id: TASK-116
title: 'Tabs: Reopen Closed Tab should distinguish archived tabs from closed ones'
status: To Do
assignee: []
created_date: '2026-09-25 05:57'
updated_date: '2026-09-25 06:07'
labels:
  - tabs
dependencies:
  - TASK-115
  - TASK-117
references:
  - Detour/Storage/Database.swift
  - Detour/Browser/TabStore.swift
  - Detour/Storage/Models/ClosedTabRecord.swift
priority: low
ordinal: 116000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Archived tabs (timer sweep in TabStore.archiveStaleTabs, and the sidebar Archive menu items once TASK-115 lands) go on the same closed-tab stack as Cmd+W closes. Reopen Closed Tab (Database.popClosedTab / TabStore.closedTabStack) ignores ClosedTabRecord.archivedAt, so Cmd+Shift+T can bring back a tab the archive timer took hours ago instead of the one the user just closed. Archive sweeps also share the 100-entry cap (Database.closedTabCap and the in-memory trim in TabStore.closeTab), so one large sweep can evict every recently closed tab.

Decision to make first: whether Reopen Closed Tab skips archived records entirely, or only prefers explicit closes. Recommendation: skip them, and keep archived tabs recoverable some other way (at minimum they stay in history; ideally a future Archived Tabs list backed by the same records). Skipping must not make archived tabs unrecoverable without a follow-up task for that list.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The skip-vs-deprioritize behavior is decided and recorded in the task notes
- [ ] #2 Cmd+Shift+T after closing a tab reopens that tab even if an archive sweep ran after the close
- [ ] #3 Archived records no longer evict explicitly closed tabs under the cap (e.g. separate caps, or eviction that prefers archived records)
- [ ] #4 Space-scoped behavior (popClosedTab(spaceID:)) and incognito exclusion are unchanged
- [ ] #5 Records written before this change (archivedAt NULL for manual archives) keep working
- [ ] #6 Unit tests cover reopen ordering with mixed closed and archived records, and cap eviction
- [ ] #7 closedTab gains a closedAt column (migration), set on every closed-tab record — plain close, manual archive, timer archive; existing rows backfill from archivedAt where present, else stay NULL and sort by id
- [ ] #8 Ordering in the reopen path is unaffected by the column (still newest-first); closedAt is available for time-based retention and display
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
closedTab currently has no close timestamp: order comes only from the autoincrement id, and only timer-archived rows carry a time (archivedAt). With closedAt present, consider whether archivedAt should become a flag / archive-reason column instead of a second timestamp.
<!-- SECTION:NOTES:END -->
