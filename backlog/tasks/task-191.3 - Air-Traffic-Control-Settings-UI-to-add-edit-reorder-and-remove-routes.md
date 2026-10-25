---
id: TASK-191.3
title: 'Air Traffic Control: Settings UI to add, edit, reorder and remove routes'
status: To Do
assignee: []
created_date: '2026-10-24 09:44'
updated_date: '2026-10-25 08:46'
labels:
  - links
  - settings
  - ui
  - feature
dependencies:
  - TASK-191.1
parent_task_id: TASK-191
priority: medium
ordinal: 221000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Third part of TASK-191. A Links pane in Settings (or a section of the Spaces pane; decide), following Arc's sheet (docs/air-traffic-control/): a list of routes, each row `URL [match kind ▾] [pattern] ⊖` with `↳ Open in [space ▾]`; New Route; drag to reorder; a Default popup at the bottom. The space popup lists the non-Private spaces with their emoji and name, plus Most Recent Space. A route whose space is gone shows as broken. Follow the shared layout rules from TASK-189 if they have landed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Routes can be added, edited, reordered and removed, and the Default target set; changes take effect for the next link without a restart
- [ ] #2 Broken routes (deleted space) are shown as such
- [ ] #3 Checked at runtime with captures, light and dark
- [ ] #4 A route can be given a From app condition with an app picker (icon and name shown, bundle ID stored), and app-only routes are supported or explicitly ruled out
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24: each route gets an optional 'From app' condition: an app picker (running apps plus Choose… for any .app; shows icon and name, stores the bundle ID), shown as an extra line under the URL line. A route may also be app-only (any URL from that app) — decide whether the URL part can be left empty.

2026-10-24: the Open in popup lists Private Window (and Quarantine, for routes that can only match links from other apps, and for the Default) after the spaces and Most Recent Space.

User 2026-10-25: own Links pane (not a Spaces section); app-only routes allowed (URL part optional when a From app is set; a route needs at least one condition). Space deletion in the sidebar and in the Spaces pane is blocked while routes target the space: the alert names the routes and offers to open the Links pane. Hide the Quarantine/Quick Detour targets until their tasks land.
<!-- SECTION:NOTES:END -->
