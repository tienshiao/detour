---
id: TASK-332
title: 'Tabs: Reopen Closed Tab restores a child tab''s link to its opener'
status: To Do
assignee: []
created_date: '2026-11-14T23:45:00Z'
labels:
  - tabs
dependencies: []
references:
  - TASK-325
  - TASK-117
  - Detour/Browser/TabCloseSelection.swift
  - wiki/tabs/back-swipe-to-opener.md
priority: low
type: bug
ordinal: 406000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-325. A tab opened from another tab carries parentID, which the Back button, ⌘[ and the back swipe use to close it to its opener. After closing such a tab (for example by a back swipe) and bringing it back with Reopen Closed Tab, the restored tab has no parentID, so Back and the swipe no longer return to the opener. Closed tabs are read from the database only (TASK-117), so the record has to carry it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A reopened child tab whose opener is still open gets its parentID back, so Back, ⌘[ and the back swipe close it to that opener again
- [ ] #2 If the opener has been closed, archived or moved to another space meanwhile, the reopened tab has no parentID (no dangling reference)
- [ ] #3 Records written before the change still reopen (migration or tolerant read); tests cover the round trip and the missing-opener cases
<!-- AC:END -->
