---
id: TASK-292.3
title: 'Website: Switching from Arc hub page'
status: To Do
assignee: []
created_date: '2026-11-08T06:59:00Z'
labels:
  - website
dependencies:
  - TASK-292.2
documentation:
  - docs/little-window
  - docs/air-traffic-control
parent_task_id: TASK-292
priority: medium
ordinal: 344000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Arc is no longer developed and its users search for a replacement ("Arc browser alternative", "browser like Arc for Mac"). Detour is no longer pitched as an Arc clone (TASK-292), so this hub is the one place written for Arc users: it maps what they relied on to Detour and is honest about gaps. Known mappings from planning: Spaces, Profiles, pinned tabs and folders, Favorites, Command Bar -> Command Palette, Peek, Split View -> Split Tabs, auto-archive -> Tab Archiving, Little Arc -> Quick Detour (docs/little-window), Air Traffic Control -> Link Routes (docs/air-traffic-control). Not in Detour: Boosts, Easels, Arc Max, among others. Detour has no Arc importer today, so moving over is manual; whether to build one is a separate decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 /arc/ is live with a table mapping Arc features to their Detour counterpart, each linking to its guide page where one exists
- [ ] #2 The page lists what Arc had that Detour does not, and what Detour has that Arc did not
- [ ] #3 The page explains how to move from Arc by hand (pinned tabs, spaces, logins, extensions) given there is no importer
- [ ] #4 Statements about Arc are factual and verifiable; no Arc logos, screenshots or styling
- [ ] #5 Feature pages with a Coming from Arc box link to the hub, and the hub is linked from the home page
<!-- AC:END -->
