---
id: TASK-305
title: >-
  Tab archiving: a tab playing audio or video is archived (closed) like any idle
  tab
status: To Do
assignee: []
created_date: '2026-11-08T09:53:00Z'
labels:
  - tabs
  - archiving
  - bug
dependencies: []
references:
  - TASK-292.6
priority: medium
type: bug
ordinal: 366000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-292.6 code read (Nov 8 2026, not yet seen at runtime): the archive sweep (TabStore.archiveStaleTabs, ~5249-5279, every ~5 minutes) archives a normal tab once it has been deselected longer than the profile's "Archive tabs after" (12 hours by default). It skips pinned tabs, favorites, Private tabs, the last tab of a space and half-stale splits, but it does not check whether the tab is playing audio or video. Music or a podcast left playing in a background tab is therefore closed mid-playback after 12 hours; the now-playing bar exists precisely to control such tabs. (Sleeping already avoids this in places: a pending media check guards the GPU recycler and sleep; see allLiveTabs / media rules.)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Confirmed at runtime (or ruled out) with a tab playing audio past an injected short archive threshold
- [ ] #2 A tab that is playing audible media is not archived; it becomes eligible once playback stops, counting from then or from its last deselection (rule agreed with the user)
- [ ] #3 Muted or paused media does not block archiving
- [ ] #4 TabStore archive tests cover playing, paused and muted tabs, with an injected clock
- [ ] #5 The website's Tab Archiving page mentions the rule
<!-- AC:END -->
