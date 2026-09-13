---
id: TASK-58
title: >-
  Favourites: a live favourite moved back into the tab list or pinned section
  keeps a stale spaceID
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 17:31'
labels:
  - bug
  - favorites
  - tabs
dependencies: []
priority: low
ordinal: 58000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-54 review. Favourites are per-profile and show in every space that shares the profile, so a live favourite backing tab can be activated in space A and dragged into space B. TabStore.restoreFavoriteAsTab (TabStore.swift ~1224) inserts a live backing tab straight into space.tabs, and restoreFavoriteAsPinned (~1262) hands it to the new PinnedEntry, without setting tab.spaceID to the destination space (insertTab ~1838 does this on every other insert path; both restore paths bypass it). The tab keeps the spaceID of wherever it was activated, or of the space it was originally detached from when it became a favourite (detachTab / detachPinnedEntry do not touch it either).

tab.spaceID is what BrowserTab.wake() (~596) uses to pick the configuration (space lookup -> wakeConfiguration(in:)), what the history/profile lookups at BrowserTab ~276 and ~296 resolve through, and what the session save records. Consequences of the stale value: a tab dragged from a favourite into space B and later slept wakes from space A configuration (fine while both share the profile, wrong if space A was reassigned to another profile or deleted, in which case the space lookup is nil and the tab wakes with no extension controller and no content scripts), and per-space lookups keyed on spaceID point at the wrong space.

Fix: set tab.spaceID = space.id on the live branch of both restore paths (or route them through insertTab / a shared placement helper), and audit the other live-tab hand-offs between sections (addFavorite(from:) after detachTab / detachPinnedEntry, the TASK-54 selection-restore path) for the same gap. Decide and document what spaceID means for a tab while it is a favourite (it currently keeps the space it was activated in).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After restoreFavoriteAsTab and restoreFavoriteAsPinned move a live favourite tab into space B, tab.spaceID == B.id
- [ ] #2 A live favourite tab that was activated in space A, moved to space B, then slept and woken builds its web view from space B configuration, including when space A was deleted in between
- [ ] #3 Session save after the move records the tab under space B
- [ ] #4 Unit tests cover both restore paths for the stale spaceID, plus the delete-source-space wake case
<!-- AC:END -->
