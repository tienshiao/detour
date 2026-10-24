---
id: TASK-186.1
title: 'Dev mode: detect local development URLs and mark the tab''s sidebar row'
status: To Do
assignee: []
created_date: '2026-10-24 09:13'
updated_date: '2026-10-24 09:19'
labels:
  - dev-mode
  - sidebar
  - feature
dependencies: []
parent_task_id: TASK-186
priority: medium
ordinal: 209000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First part of TASK-186. Reference: docs/dev-mode/arc-sidebar-row.png.

1. A pure rule `isLocalDevelopmentURL(_:)` (test-first): which URLs put a tab in dev mode (see the parent for the proposed host set and open questions), and `devModeHostLabel` = host:port when the port is not the scheme's default, else the host.
2. Sidebar: a dev-mode tab's row gets an "under construction" treatment (Arc: yellow/black dashed hazard border around the row) and a second line under the title with the host label. Applies to normal tabs, pinned tabs and favourites' rows where they show titles; split rows need a decision (one pane local, one not).
3. The row follows navigation: leaving the local URL drops the style, coming back restores it. Sleeping tabs use their stored URL.

Row height: the second line must not change the list's row layout math (wiki/sidebar/row-layout.md), or the change goes through SidebarLayout and its tests.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 isLocalDevelopmentURL and the host label are pure functions with tests covering localhost, *.localhost, loopback IPv4/IPv6, 0.0.0.0, default vs non-standard ports, and non-local hosts
- [ ] #2 A tab on a local development URL shows the hazard-style row and host:port second line; navigating away removes it
- [ ] #3 Split rows, pinned rows and favourites are decided and recorded
- [ ] #4 Checked at runtime (sidebar capture) in light and dark mode
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24: the row and (TASK-186.2) toolbar must read the *effective* dev-mode state (per-site override from TASK-186.5, else isLocalDevelopmentURL), so keep the URL rule a separate function the effective rule composes.
<!-- SECTION:NOTES:END -->
