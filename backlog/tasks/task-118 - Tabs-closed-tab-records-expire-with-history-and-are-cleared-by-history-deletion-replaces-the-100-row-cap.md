---
id: TASK-118
title: >-
  Tabs: closed-tab records expire with history and are cleared by history
  deletion
status: To Do
assignee: []
created_date: '2026-09-25 06:09'
updated_date: '2026-09-25 07:17'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Sep 24 2026 review (on hold by user decision; 115/117/116 proceed first). Design notes for when it resumes:
- Coupling point: TabStore.historyDidDelete(_:spaceIDs:requestedAt:...) already receives HistoryDeletionResult.affectedURLs from HistoryPageBridge; delete closedTab rows there (AppDatabase, not HistoryDatabase — the two databases must stay independent). Range for allVisitsOfURL deletes = the bridge's window applied to closedAt; id-only deletes drop matching-url rows in scope with no range.
- Per-URL matching: current url only. The interactionState blob is an opaque WebKit archive; live tabs' back/forward lists also survive history deletion, so this is consistent.
- Cap: replace the row cap with retention (shared 90-day constant with expireOldVisits) plus blob stripping — keep interactionState only for the newest N (≈100, today's reopen depth) rows per space, strip older rows to url/title/favicon at push time via the (spaceID,id) index. Row count is then bounded by retention; no arbitrary per-space backstop needed. Rows without blobs reopen by URL only.
- Orphan sweep: DELETE FROM closedTab WHERE spaceID NOT IN (live spaces ∪ spaceIDsDeletedThisSession), from the same deferred launch block as sweepHistoryOfDeletedSpaces. No FK to space: saveSession deletes and re-inserts every space row, so a cascade would wipe the table on each save.

Sep 25 2026: the user removed the row cap outright (see the 'remove the closed-tab row cap' task) — AC #5 is moot; the Archived Tabs panel (TASK-119) gets a Clear Archive action. When this task resumes, retention/blob stripping is the only automatic bound.
<!-- SECTION:NOTES:END -->
