---
id: TASK-356
title: >-
  Link Routes: Open Link in New Tab and Open Link in New Window go through Link
  Routes
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
labels:
  - links
  - link-routes
dependencies: []
references:
  - TASK-191.4
  - wiki/features/link-routing-in-page.md
priority: low
type: feature
ordinal: 436000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user's decision 2026-11-15 on TASK-191.4's unconfirmed choices. Today none of the link menu's actions are routed (linkMenuAction). The user wants the actions that open a new tab or window routed like a Cmd+click, for consistency with other browsers' link rules (Arc Air Traffic Control, Firefox Multi-Account Containers apply rules whatever opened the link). Open Link in Split View (an explicit 'next to this tab') and Open Link in Quick Detour (an explicit 'outside any space') stay unrouted. The other five TASK-191.4 choices were confirmed as built.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Open Link in New Tab and Open Link in New Window open a link that matches a route where the route says, as a Cmd+click would
- [ ] #2 Open Link in Split View and Open Link in Quick Detour are never routed
- [ ] #3 linkRoutingEligibility tests cover each link menu action; checked at runtime
<!-- AC:END -->
