---
id: TASK-4
title: '1Password: real frame enumeration for iframe autofill (Phase 3)'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-11 22:28'
updated_date: '2026-09-12 09:05'
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
- [x] #1 _polyfillDiag records whether webNavigation.getAllFrames and getFrame were provided natively by WebKit
- [ ] #2 getAllFrames({tabId}) returns every frame whose content script has run, with frameId values equal to the sender.frameId WebKit reports for that frame, plus url and parentFrameId
- [ ] #3 getFrame({tabId, frameId}) returns the same record for a known frame and null for an unknown one
- [ ] #4 parentFrameId is 0 for frames whose parent is the top document and correct for at least one two-level nested frame
- [ ] #5 Entries are removed when the tab closes or the frame navigates to a new document
- [ ] #6 1Password fills a login form inside a cross-origin iframe on a test page
- [ ] #7 API Explorer shows the frame list for the active tab and tests cover the registry (hello, goodbye, navigation, parent resolution)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Phase A (decide): record in _polyfillDiag.apis.webNavigationFrames whether getAllFrames/getFrame were native before the polyfill touched chrome.webNavigation (Function.prototype.toString contains [native code], captured in webNavigationJS before the patch). Probe in ExtensionPolyfillIntegrationTests from a real extension page; also probe from the worker (round trip) whether content scripts in an ordinary tab can message the worker in the test harness and whether sender.frameId is populated. Report before building.
Phase B (only if WebKit lacks native getAllFrames): registry in the worker polyfill. Content polyfill (all_frames) sends {_detourFrameHello, url, isTop, parentIsTop} on injection and {_detourFrameGoodbye} on pagehide; worker keeps tabId -> frameId -> {url, parentFrameId} keyed by sender.tab.id/sender.frameId, replies with the frame's own id; for depth>1 the child posts {__detourFrameId} to window.parent, whose content script forwards {_detourFrameChild, childFrameId} so the worker learns parentFrameId. Entries dropped on tabs.onRemoved and on the frame's own hello for a new document (navigation) / webNavigation.onCommitted for that frameId. getAllFrames/getFrame served from the registry in the worker (native bridge case becomes unused). Unit tests drive the worker onMessage listener with fake senders in a bare WKWebView (hello, goodbye, navigation, parent resolution, tab removal); one integration test with a page containing an iframe if the harness allows; API Explorer shows the frame list. If native getAllFrames exists, TASK-4 closes with the diag + notes and a doc update.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Phase A result (2026-09-12, macOS 26): _polyfillDiag.apis.webNavigationFrames reports getAllFrames and getFrame as NATIVE in both the service worker and extension pages, so the polyfill's fallbacks never install in production. Native getAllFrames({tabId}) for a tab with two http iframes and one srcdoc iframe returned all four frames with WebKit's own ids (top 0, subframes 30064771073..75), parentFrameId -1/0, and URLs; getFrame resolved those ids and tabs.sendMessage(tabId, msg, {frameId}) reached the subframe's content script (pinned by ExtensionPolyfillIntegrationTests.testContentScriptFrameHellosReachTheWorker with a loopback HTTP server). Conclusion: the worker-side registry in AC #2-#5/#7 is not needed and would only risk disagreeing with sender.frameId. Best hypothesis for 1Password's 'Could not collect all frames that were initially found': WebKit returns url '' for srcdoc/data:/about:blank frames (Chrome returns about:srcdoc etc.) and injects no content script into them, so 1Password's URL filter drops frames it saw, or its fan-out has no receiver there. Also learned: content-script -> worker messaging in tests works only when the web view is registered as a tab (didOpenWindow/didOpenTab); the XCTSkipIf comments in WKExtensionIntegrationTests blaming the sandbox are stale. A hello sent while the worker sleeps is silently lost.

Code review (medium) of Phase A: deleting the polyfill's getAllFrames/getFrame fallbacks and their native handler cases (dead in production; the native fallback fabricated phantom frame records, so a WebKit regression would degrade silently instead of failing loudly); diag stored as an object; docstring aligned with the intentional native pin; LoopbackHTTPServer reads the full request head and cleans up on a failed start. Declined: pre-recovery-origin extension pages being rejected after a context reload is TASK-14; recovery re-triggering after the 10-minute window is the documented retry design. Decision needed from the user: close TASK-4 (registry not needed) or repurpose it to chase the empty-URL hypothesis against a real 1Password session; AC #2-#7 describe the registry and are left unchecked.
<!-- SECTION:NOTES:END -->
