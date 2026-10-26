---
id: TASK-205
title: Routed and new-tab clicks that turn into downloads leave an empty tab
status: To Do
assignee: []
created_date: '2026-10-26 04:22'
labels:
  - links
  - downloads
  - bug
dependencies: []
priority: medium
ordinal: 241000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-191.4 review. A link is routed (Air Traffic Control: a route, or a Default naming a space) at the click, in decidePolicyFor navigationAction, before the response is known. When the server answers with a download (Content-Disposition: attachment, or a type WebKit can't show), the routed space gets a new empty tab and the window has switched space or another window came forward, for nothing. The same empty tab already happens for Cmd+click and target=_blank links that turn into downloads (pre-existing). Proposed: a tab whose first navigation becomes a download closes itself, and a routed open puts back the space or window order it changed. Check against the Private download rules and the downloads scope.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A routed click whose response is a download leaves no empty tab, and the window's space and window order are as before the click
- [ ] #2 Cmd+click and _blank links that become downloads leave no empty tab
- [ ] #3 The download itself proceeds and shows as today
- [ ] #4 The close/restore rule is a pure function with tests; checked at runtime with a loopback attachment response
<!-- AC:END -->
