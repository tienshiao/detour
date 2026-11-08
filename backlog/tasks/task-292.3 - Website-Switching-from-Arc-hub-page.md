---
id: TASK-292.3
title: 'Website: Switching from Arc hub page'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-08T07:47:00Z'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 7 2026 (from TASK-292.2): Arc's help center (resources.arc.net) answers 403 to scripted fetches, but the Wayback Machine has it: archive.org/wayback/available?url=resources.arc.net/hc/en-us/articles/<id> gives the latest capture, web.archive.org/web/<ts>id_/<url> the original page (gzip). About 220 article URLs captured (CDX: web.archive.org/cdx/search/cdx?url=resources.arc.net/hc/en-us/articles/*&collapse=urlkey). Checked so far: Split View (Dec 2025 capture: ⌘⇧+ or drop a tab in the center; side by side or top-and-bottom; no maximum stated, the 'four' comes from TechCrunch/How-To Geek), Spaces (Jul 2026: + in the sidebar creates one; switch by icon, two-finger swipe, ⌃1/⌃2…, ⌘T + name; theme and icon per Space; Share Space as a link; Air Traffic Control routes), Keyboard Shortcuts (Jul 2026; key column did not extract from the table).
<!-- SECTION:NOTES:END -->
