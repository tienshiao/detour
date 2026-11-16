---
id: TASK-393
title: >-
  Tab opener: a dormant pinned tile dragged to the favourites bar loses its
  opener link
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:42:00Z'
labels:
  - tabs
  - opener
  - favorites
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - wiki/tabs/tab-opener.md
priority: low
type: bug
ordinal: 474000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-378, out of its scope); read from code. TASK-378 made a dormant pinned entry or favourite keep its dropped backing tab's opener link (`dormantOpenerID`) and hand it to the tab its wake builds; a dormant favourite dragged into the pinned section hands the link to its new entry (`restoreFavoriteAsPinned`). The other direction does not: `TabStore.addFavoriteFromEntry(url:title:faviconURL:favicon:profileID:at:)` builds a new `Favorite` from the entry's URL, title and icon only, so a dormant pinned tile dragged to the favourites bar starts without its link, and the favourite's first activation gets no opener. Wiki: wiki/tabs/tab-opener.md, wiki/tabs/favorites.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A dormant pinned tile dragged to the favourites bar keeps its opener link: activating the favourite gives the new tab that opener while space.liveOpenerID resolves it
- [ ] #2 A test (TabOpenerRuleTests) covers it
<!-- AC:END -->
