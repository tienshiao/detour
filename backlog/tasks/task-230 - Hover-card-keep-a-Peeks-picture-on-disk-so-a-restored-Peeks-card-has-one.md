---
id: TASK-230
title: 'Hover card: keep a Peek''s picture on disk, so a restored Peek''s card has one'
status: To Do
assignee: []
created_date: '2026-10-29T07:20:00Z'
labels:
  - sidebar
  - peek
dependencies: []
references:
  - TASK-229
priority: low
ordinal: 266000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested Oct 29 2026. TASK-229 gave the Peek badge its own hover card, with the Peek's in-memory picture (its switcherPreview, taken when the host is left with the Peek up). Nothing was written to disk because TabStore.thumbnailKey(for:) is nil for a Peek (it is in no sidebar list), so after a relaunch a restored Peek's card is text only until the Peek has been shown and left again. The user wants the picture kept like a tab's (TabThumbnailCache, TASK-190).

Constraints: never wake, host or show a Peek or its host to take a picture (wiki/platform/gpu-iosurface-limit.md); nothing written for Private; a different Peek opened on the same host must never show the previous Peek's picture; files of closed Peeks are swept like other orphans.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A Peek's picture is written to the thumbnail cache from the same capture as its in-memory preview, under a key derived from its host row's key and the Peek's URL, and never for Private
- [ ] #2 After a relaunch, hovering a restored Peek's badge shows its picture from disk; a Peek on a different URL than the one pictured shows none
- [ ] #3 The sweep keeps the picture of every host's current Peek and removes the rest (closed Peeks, a Peek that navigated away)
- [ ] #4 Covered by TabThumbnailTests and TabHoverCardTests, and checked at runtime across a relaunch
<!-- AC:END -->
