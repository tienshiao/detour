---
id: TASK-4
title: '1Password: real frame enumeration for iframe autofill (Phase 3)'
status: To Do
assignee: []
created_date: '2026-09-11 22:28'
labels:
  - 1password
  - extensions
dependencies:
  - TASK-2
documentation:
  - docs/1password-integration-plan.md
priority: medium
ordinal: 4000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
webNavigation.getAllFrames and getFrame currently return only the top frame (ExtensionPolyfillHandler.defaultFrameInfo). 1Password logged "[Tabs] Could not collect all frames that were initially found" on 2026-09-11. It calls getAllFrames({tabId}), filters by URL, and fans messages out to every frame with tabs.sendMessage(tabId, msg, {frameId}); it calls getFrame({tabId, frameId}) to get parentFrameId and relay messages one level up; it uses frameIds in scripting.insertCSS targets. So the frame IDs returned MUST be WebKit's own (the ones in sender.frameId), or messages go to nonexistent frames. Design in the plan: a content script cannot learn its own frame id but the service worker sees it as sender.frameId, so keep the registry in the service-worker polyfill (no native code): the content polyfill (already injected with all_frames: true) sends a hello on injection and goodbye on pagehide; the worker keeps per-tab frameId -> {url, parentFrameId}. Depth-one frames report parentFrameId 0 when window.parent === window.top; for deeper nesting the worker replies with the frame's id, the content script posts it to window.parent, and the parent's content script forwards {childFrameId} to the worker. Drop entries on tabs.onRemoved and on webNavigation.onCommitted for the same frame id. First, record in _polyfillDiag whether chrome.webNavigation.getAllFrames was already native; the polyfill only installs when WebKit lacks it, and that decides whether this task is needed. Depends on the service worker surviving idle termination so the registry can be verified over time.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 _polyfillDiag records whether webNavigation.getAllFrames and getFrame were provided natively by WebKit
- [ ] #2 getAllFrames({tabId}) returns every frame whose content script has run, with frameId values equal to the sender.frameId WebKit reports for that frame, plus url and parentFrameId
- [ ] #3 getFrame({tabId, frameId}) returns the same record for a known frame and null for an unknown one
- [ ] #4 parentFrameId is 0 for frames whose parent is the top document and correct for at least one two-level nested frame
- [ ] #5 Entries are removed when the tab closes or the frame navigates to a new document
- [ ] #6 1Password fills a login form inside a cross-origin iframe on a test page
- [ ] #7 API Explorer shows the frame list for the active tab and tests cover the registry (hello, goodbye, navigation, parent resolution)
<!-- AC:END -->
