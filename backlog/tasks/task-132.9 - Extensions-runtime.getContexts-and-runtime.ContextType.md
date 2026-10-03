---
id: TASK-132.9
title: 'Extensions: runtime.getContexts and runtime.ContextType'
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
labels: []
dependencies:
  - TASK-132.8
parent_task_id: TASK-132
priority: medium
ordinal: 141000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Claude extension's Cmd+E handler calls chrome.runtime.getContexts({contextTypes: [chrome.runtime.ContextType.SIDE_PANEL]}) and reads each context's documentUrl to see whether a panel for that tab is already open; with ContextType undefined the handler throws. WebKit vends neither. chrome.runtime is patchable in place (pin the wrapper, see docs/chrome-runtime-patching.md).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 runtime.ContextType has TAB, POPUP, BACKGROUND, OFFSCREEN_DOCUMENT and SIDE_PANEL
- [ ] #2 getContexts returns the extension's open contexts with contextType, documentUrl, tabId and windowId, and honours the contextTypes, tabIds, windowIds and documentUrls filters
- [ ] #3 An open side panel is reported as SIDE_PANEL with its full URL including the query; a closed one is not reported
- [ ] #4 Contexts of another extension or another profile are never returned
- [ ] #5 The patch survives garbage collection (rooted wrapper); tests and API Explorer cover it
<!-- AC:END -->
