---
id: TASK-326
title: 'Copy URL: Shift-Cmd-C copies the URL with tracking parameters removed'
status: To Do
assignee: []
created_date: '2026-11-14T09:35:00Z'
labels:
  - feature
  - links
dependencies: []
priority: medium
ordinal: 400000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Shift-Cmd-C (Edit > Copy URL) copies the page URL exactly as loaded, so links shared from Detour carry utm_*, fbclid, gclid and similar tracking parameters. The user wants the copied link to be the clean one.

Today (Nov 14 2026) the menu item calls `copyCurrentURL(_:)`, which is implemented twice: `BrowserWindowController.copyCurrentURL` → `copyURL(_:)` (toast "URL copied") and `QuickDetourWindowController.copyCurrentURL` (toast "Link copied"). The sidebar faux address bar link button (`onCopyURL`) also routes through `BrowserWindowController.copyCurrentURL`, and the dev toolbar link button through `copyURL(_:)`. Other copy paths do not: the sidebar row context menu Copy URL / Copy Link (`contextMenuCopyURL`, `QuickDetour.sidebarCopyURL`) and Quick Detour's title-bar Copy Link button. Whether those should strip too is a decision to settle and record when the task is picked up; Shift-Cmd-C is the required scope.

Only the copied string changes: the page's loaded URL, history and session records keep the original.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Shift-Cmd-C in a browser window copies the current URL with known tracking parameters removed (at least utm_*, fbclid, gclid, msclkid, mc_eid/mc_cid, igshid, _ga, yclid, dclid) and all other query parameters kept in their original order and encoding
- [ ] #2 Shift-Cmd-C in a Quick Detour window behaves the same way
- [ ] #3 A URL with only tracking parameters copies without a dangling ? ; a URL with no tracking parameters copies unchanged, including its fragment
- [ ] #4 Parameters whose names only resemble tracking ones (e.g. a site's own `ref` or `source`) are not stripped unless the list says so explicitly, and the list lives in one place
- [ ] #5 The page's loaded URL, history entries and session records are not modified
- [ ] #6 The decision on the other copy entry points (sidebar context menu, faux address bar button, Quick Detour title-bar button, dev toolbar) is recorded in the task, and the shipped behavior matches it
- [ ] #7 Unit tests cover the stripping rule: mixed tracking/non-tracking params, only-tracking params, no params, fragments, percent-encoded values, repeated keys, case of parameter names
<!-- AC:END -->
