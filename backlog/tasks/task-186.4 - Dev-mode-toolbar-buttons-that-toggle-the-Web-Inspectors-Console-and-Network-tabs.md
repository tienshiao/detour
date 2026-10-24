---
id: TASK-186.4
title: >-
  Dev mode: toolbar buttons that toggle the Web Inspector's Console and Network
  tabs
status: To Do
assignee: []
created_date: '2026-10-24 09:13'
labels:
  - dev-mode
  - webkit
  - feature
dependencies:
  - TASK-186.2
parent_task_id: TASK-186
priority: medium
ordinal: 212000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fourth part of TASK-186. Buttons in the dev toolbar that open/close the docked Web Inspector on the Console and on the Network tab (Arc also has an element picker; optional).

WebKit gives no public API for this. Today the Develop menu opens the inspector through the private `_inspector` object's `show` (BrowserWindowController.showWebInspector). The private _WKInspector also has `showConsole`, `hide`/`close`, `isVisible` and `toggleElementSelection`; there is no Network-tab call, so opening Network needs research (WebKit source: _WKInspector.h / WebInspectorUIProxy; possibly the frontend's own API). Record what works on the shipped macOS and what was rejected, and guard every private selector with respondsToSelector so a WebKit change hides the button instead of crashing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Console button opens the inspector on the Console tab and closes it when it is already showing that tab
- [ ] #2 Network button opens the inspector on the Network tab, or the finding that it cannot be done is recorded and the button is left out
- [ ] #3 Private API use is guarded and documented in the wiki (platform page)
<!-- AC:END -->
