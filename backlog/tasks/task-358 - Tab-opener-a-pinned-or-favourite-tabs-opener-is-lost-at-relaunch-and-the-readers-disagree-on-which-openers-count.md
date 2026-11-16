---
id: TASK-358
title: >-
  Tab opener: a pinned or favourite tab's opener is lost at relaunch, and the
  readers disagree on which openers count
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
labels:
  - tabs
  - opener
dependencies: []
references:
  - wiki/tabs/tab-opener.md
  - Detour/Browser/TabStore.swift
priority: low
type: bug
ordinal: 439000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 while writing wiki/tabs/tab-opener.md (read from the code, not run). (1) parentID is saved for pinned and favourite backing rows but read back at launch only for normal tabs, so after a relaunch Back on a pinned child no longer selects its opener. (2) The readers accept different openers: tabCloseSelectionID and the Move to Space undo accept only a normal tab; Space.openerTab (Back, swipe, reopen, close undos) also a live pinned tab; webViewDidClose uses displayableTab so a favourite's tab counts; openerPlacement can make a favourite's tab the parent, which Back then never resolves.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A pinned or favourite tab's opener link survives a relaunch, or the decision not to keep it is recorded with its reason
- [ ] #2 Which tabs count as an opener is one rule shared by every reader (or each difference is deliberate and recorded on the wiki page)
- [ ] #3 Tests cover the relaunch case and each reader's opener kinds
<!-- AC:END -->
