---
id: TASK-384
title: >-
  Tab opener: a dormant pinned tab's or favourite's opener link is lost at
  relaunch
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:41:00Z'
labels:
  - tabs
  - opener
  - persistence
dependencies: []
references:
  - wiki/tabs/tab-opener.md
  - Detour/Storage/Database.swift
priority: low
type: task
ordinal: 465000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-378). TASK-378 made a pinned entry or favourite that goes dormant (Cmd+W, the row's minus button, an extension's tabs.remove, a space moved to another profile) keep its dropped backing tab's opener link: `PinnedEntry.dormantOpenerID` / `Favorite.dormantOpenerID`, and the tab its wake builds gets it back through `space.liveOpenerID`. That is kept in memory only. Read from code: `PinnedTabRecord` and `FavoriteRecord` have no column for it (a live backing tab's `parentID` is saved in its `tab` row and read back since TASK-358), so a relaunch while the tile is dormant loses the link.

The user's decision (2026-11-16): keep it across a relaunch. This needs new columns on the `pinnedTab` and `favorite` tables (migration v27, after v26 in `Detour/Storage/Database.swift`), the records and session restore carrying them, and the wiki's "in memory only" limits rewritten (wiki/tabs/tab-opener.md, wiki/tabs/favorites.md, wiki/tabs/pinned-tabs-and-folders.md, wiki/architecture/persistence.md).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A pinned entry or favourite that is dormant at quit gives the tab its first wake after a relaunch builds its opener link, while that opener is still one in the space it wakes in (space.liveOpenerID)
- [ ] #2 A v27 migration adds the columns; a v26 database opens with no dormant link and nothing else changes
- [ ] #3 Tests cover the round trip through the session database for a pinned entry and a favourite, and the migration
<!-- AC:END -->
