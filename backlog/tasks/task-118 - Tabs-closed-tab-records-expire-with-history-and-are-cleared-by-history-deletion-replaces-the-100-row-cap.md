---
id: TASK-118
title: >-
  Tabs: closed-tab records expire with history and are cleared by history
  deletion (replaces the 100-row cap)
status: To Do
assignee: []
created_date: '2026-09-25 06:09'
labels:
  - tabs
  - privacy
dependencies:
  - TASK-116
  - TASK-117
references:
  - Detour/Storage/Database.swift
  - Detour/Storage/HistoryDatabase.swift
  - Detour/Browser/InternalPages/HistoryPageBridge.swift
  - Detour/App/AppDelegate.swift
priority: medium
ordinal: 118000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Each closedTab record keeps the tab's back/forward list (interactionState) plus url/title, i.e. browsing history held outside HistoryDatabase:
- History visits expire after 90 days (HistoryDatabase.expireOldVisits, run from AppDelegate at launch); closed-tab records never expire.
- Deleting history on the History page (HistoryPageBridge -> deleteVisits(ids:spaceIDs:allVisitsOfURL:from:until:) and deleteVisits(spaceIDs:since:)) never touches closedTab, so Cmd+Shift+T can still bring back pages (with full back/forward list) the user just deleted from history.

The only bound today is a global 100-row count cap (Database.closedTabCap), which also evicts across spaces. Once the stack is DB-only (TASK-117) and every record has closedAt (TASK-116), a count cap no longer buys performance; replace it with retention tied to history.

Open design point: the per-URL deletion case (deleting one history row / all visits of a URL) — a closed tab's interactionState can contain that URL in its back/forward list, not just as its current url. Decide whether to match on current url only, or drop/strip records whose back-forward list contains it (the blob is an opaque WebKit archive; matching inside it may not be feasible — record the decision).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Closed-tab records older than the history retention window (90 days, same constant as expireOldVisits) are deleted, off the launch critical path
- [ ] #2 History page 'delete since' / clear-all for a scope deletes that scope's closedTab rows with closedAt in the range (rows with NULL closedAt are treated as old / included in clear-all)
- [ ] #3 Deleting individual history rows deletes closedTab rows whose current url matches within the same spaces and range; the back/forward-list decision is recorded in notes
- [ ] #4 Space deletion and the orphaned-space history sweep (TabStore ~1699) leave no closedTab rows behind
- [ ] #5 The 100-row count cap (Database.closedTabCap) is removed, or replaced by a high per-space backstop whose value and rationale are documented in code
- [ ] #6 Optional blob stripping of old records (reopen by URL only) is decided and recorded in notes
- [ ] #7 Unit tests cover expiry, range deletion, per-URL deletion, and the cap change
<!-- AC:END -->
