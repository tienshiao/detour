---
id: TASK-117
title: >-
  Tabs: closed-tab stack reads from the database only — no launch load, no
  in-memory mirror
status: To Do
assignee: []
created_date: '2026-09-25 06:07'
labels:
  - tabs
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - Detour/Storage/Database.swift
priority: low
ordinal: 117000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TabStore.closedTabStack mirrors the whole closedTab table in memory. It is loaded at launch (TabStore.swift ~1026), including every interactionState blob (measured on a real profile: 100 rows, ~850 KB, largest 188 KB), and every mutation writes both copies, each with its own 100-row trim. None of its users needs that:
- canReopenClosedTab (menu validation) needs only spaceID/url/extensionID per record
- reopenClosedTab scans the space's records newest-first and needs interactionState only for the record it picks
- the launch filter that deletes records of uninstalled extensions duplicates what reopenClosedTab already does lazily (.unavailable -> delete)
- deleteSpace / its undo and the close-undo cleanups snapshot, restore or remove records the DB can query directly

Make the database the only store: small-column queries (no blob) for validation and the reopen scan, fetch interactionState for the chosen row only, an index on (spaceID, id). If menu validation proves too hot for a query, add a lazily filled per-space metadata cache without blobs, not a full mirror.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 No closed-tab records (and no interactionState blobs) are loaded at launch
- [ ] #2 Reopen Closed Tab, its menu enablement, extension-page skip/discard (TASK-24/TASK-28 behavior), Delete Space + undo, and close-undo all behave as before
- [ ] #3 Only the reopened record's interactionState is read from disk
- [ ] #4 closedTab has an index serving the per-space newest-first query
- [ ] #5 closedTabStack (full mirror) is gone; tests that inspected it assert through the store or DB instead
- [ ] #6 Existing tests covering reopen, split-tab close, Move to Space and extension-page closed tabs pass
<!-- AC:END -->
