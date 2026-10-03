---
id: TASK-132.13
title: >-
  Extensions: chrome.debugger attach/detach/sendCommand plumbing and
  Page.captureScreenshot
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
updated_date: '2026-10-03 23:09'
labels: []
dependencies:
  - TASK-132.2
  - TASK-132.3
parent_task_id: TASK-132
priority: high
ordinal: 145000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
WebKit has no chrome.debugger and no CDP. Emulate the small CDP surface the Claude extension uses, natively. This task is the plumbing and the first command: attach({tabId}, '1.3'), detach, getTargets, sendCommand, onEvent, onDetach, with events pushed to workers and pages; Page.enable; Page.captureScreenshot ({format: jpeg|png, quality, clip: {x, y, width, height, scale}, captureBeyondViewport: false, fromSurface: true}) returning base64 {data}. Unknown methods fail with a CDP-style error. The extension attaches from both its service worker and its side panel page. Attaching makes the tab automation-attached (see the unselected-tabs task). The debugger permission lets an extension read and drive any page, so the install prompt must say so.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 attach then getTargets reports the tab attached; detach, closing the tab or disabling the extension fires onDetach with a reason
- [ ] #2 attach fails with Chrome's error text for extension pages, internal pages and a tab already attached by another extension
- [ ] #3 Page.captureScreenshot returns the visible viewport of a selected tab and of an unselected tab, honours format, quality and clip with scale, and matches the page's CSS pixel size
- [ ] #4 A command for a method Detour does not emulate rejects with an error naming the method, and a command to a detached tab rejects with 'Debugger is not attached'
- [ ] #5 The user can see that a tab is being driven by an extension and can stop it
- [ ] #6 An extension without the debugger permission gets no chrome.debugger; the permission has an install warning; tests cover both
- [ ] #7 API Explorer has a debugger section
<!-- AC:END -->
