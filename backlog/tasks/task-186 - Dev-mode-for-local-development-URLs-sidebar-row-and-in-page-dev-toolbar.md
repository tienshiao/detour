---
id: TASK-186
title: 'Dev mode for local development URLs: sidebar row and in-page dev toolbar'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-24 09:12'
updated_date: '2026-10-24 17:02'
labels:
  - dev-mode
  - feature
  - epic
dependencies: []
priority: medium
ordinal: 208000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24, modelled on Arc's dev mode (references: docs/dev-mode/arc-sidebar-row.png, docs/dev-mode/arc-dev-toolbar.png). We do not need all of Arc's functionality.

A tab whose page is a local development URL switches to dev mode automatically:
1. **Sidebar row** (subtask): an "under construction" look (Arc: a yellow/black dashed hazard border around the row) and a second line under the title with host:port when the port is non-standard (Arc shows `localhost:4000`).
2. **Dev toolbar** (subtask): a bar across the top of the web content with the same motif (Arc: faint diagonal stripes), holding the page URL.
3. **Capture** (subtask): image capture buttons in the toolbar.
4. **Inspector toggles** (subtask): buttons in the toolbar that open/close the Web Inspector on its Console and Network tabs (Arc also has an element picker).

Shared rule (first subtask): which URLs count as local development. Proposed: http(s) URLs whose host is `localhost`, `*.localhost`, an IPv4 loopback (127.0.0.0/8), `[::1]` or `0.0.0.0`; to decide: LAN IPs, `.test`/`.local`, and whether there is a setting to turn dev mode off. `AddressInputClassifier` already recognises localhost and IP literals for input classification; the dev-mode rule should be its own pure, tested function.

The parent is done when the subtasks are.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24 (user): dev mode is also toggleable per site for any site (not only local URLs), remembered per domain like Arc — TASK-186.5. Effective dev mode = the site's stored override, else the local-development default from TASK-186.1. The toggle lives in the faux address bar's popover, whose icon changes.

Decisions (user, 2026-10-24): automatic dev mode for http(s) on localhost, *.localhost, 127.0.0.0/8, [::1], 0.0.0.0 and *.test; not LAN IPs or .local (any site can be turned on by hand, TASK-186.5). Subtasks committed one at a time in the order 186.1, 186.5, 186.2, 186.4, 186.3.
<!-- SECTION:NOTES:END -->
