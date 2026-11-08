---
id: TASK-132.13
title: >-
  Extensions: chrome.debugger attach/detach/sendCommand plumbing and
  Page.captureScreenshot
status: Done
assignee:
  - '@claude'
created_date: 2026-10-03 23:09
updated_date: '2026-11-08T01:47:00Z'
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
- [x] #1 attach then getTargets reports the tab attached; detach, closing the tab or disabling the extension fires onDetach with a reason
- [x] #2 attach fails with Chrome's error text for extension pages, internal pages and a tab already attached by another extension
- [x] #3 Page.captureScreenshot returns the visible viewport of a selected tab and of an unselected tab, honours format, quality and clip with scale, and matches the page's CSS pixel size
- [x] #4 A command for a method Detour does not emulate rejects with an error naming the method, and a command to a detached tab rejects with 'Debugger is not attached'
- [x] #5 The user can see that a tab is being driven by an extension and can stop it
- [x] #6 An extension without the debugger permission gets no chrome.debugger; the permission has an install warning; tests cover both
- [x] #7 API Explorer has a debugger section
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Native model ExtensionDebugger: sessions keyed by tab, Chrome's attach rules and texts (debugger_api.cc), lifecycle (detach silent, unload silent, close/leave-profile/refused navigation = target_closed, Stop and Settings denial = canceled_by_user, in-flight commands fail 'Detached while handling command.').
2. Bridge ExtensionPolyfillHandler+Debugger: attach resolves the handle once and keeps the extension's tab id, so commands and events name the tab by id.
3. Extract ExtensionEventParking from the tab group hub; debugger events park per context like tab group events.
4. debuggerJS replaces the interim stand-in: attach/detach/sendCommand/getTargets/onEvent/onDetach, targetId, Chrome's errors.
5. Commands: dispatch per domain (one line each for 132.14/15); Page.enable/disable, Page.captureScreenshot over takeSnapshot (CSS x scale x devicePixelRatio, as Chrome).
6. Permission: polyfill-gated and outside WebKit; install warning says every site.
7. UI (subagent): sidebar indicator + in-window capsule with Stop (TabAutomationStop registry); API Explorer section.
8. Tests in real contexts + unit tests; docs/extensions.md, wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented 2026-11-07. Core (me): ExtensionDebugger.swift, ExtensionDebugger+Commands.swift, ExtensionEventParking.swift (extracted from ExtensionTabGroupEvents, which now wraps it), ExtensionPolyfillHandler+Debugger.swift, debuggerJS (interim stand-in module removed). UI (Opus subagent, branch task-132.13-ui, applied here): AutomationIndicator.swift, BrowserWindowController+AutomationBanner.swift, TabCellView indicator, API Explorer debugger section; I removed the stale interim probe from the API Explorer.

Decisions:
- Screenshot size follows Chrome (CSS size x clip.scale x devicePixelRatio), not literal CSS pixels: the Claude extension (1.0.105) computes width x devicePixelRatio x scale and resizes on a mismatch. AC #3's 'matches the page's CSS pixel size' is read as that geometry.
- Disabling the extension releases its tabs WITHOUT onDetach, as Chrome (the extension is gone; DebuggerDetach / OnExtensionUnloaded close silently). An explicit detach() fires no onDetach either.
- Tab ids kept natively after one bridge resolve at attach (no round trip per command; events reach contexts that never resolved the tab).
- Emulation.setFocusEmulationEnabled (sent by the Claude extension before every worker command) is NOT emulated: 'wasn't found', which the extension ignores. Candidate for TASK-132.14.
- Stop handler re-registered at every attach (a test clearing TabAutomationStop handlers must not leave later attachments unstoppable).

Code review (/code-review medium --fix on the core diff): 6 findings, all fixed - clip size overflow crash (Int conversion of extension-controlled doubles), debugger.awaitEvent refused after a Settings denial stopped the park loop for good (now refused only when not declared), snapshot timeout task not cancelled, getTargets resolved tabs serially (now concurrent), stale API Explorer interim probe, redundant isFinite checks. The review's own API Explorer rewrite was dropped in favour of the subagent's fuller section. The UI branch was not separately reviewed.

Tests: ExtensionDebuggerTests 13, ExtensionDebuggerUnitTests 11+ (review added overflow cases), plus ExtensionPolyfillTests, ExtensionInterimNamespacesTests, ExtensionTabGroupsTests/UnitTests, AutomationParkingWindowTests, TabAutomationAttachmentTests, ExtensionPermissionRestoreTests, TabCellSplitCollapseTests: 378 tests, 0 failures, 1 skipped; the UI classes TabAutomationPresentationTests, TabCellAutomationIndicatorTests, AutomationIndicatorWindowTests: 17, 0 failures. Full suite NOT run.

Runtime (/verify, harness docs/harness/task132.13-harness.patch, isolated profiles DetourVerify13213-1/-2, cleaned): API Explorer installed for real; attach from its page (unselected Bravo, parked) and from its worker (selected Alpha): capsule on Alpha, indicator on both rows, selection and first responder unchanged. Page.captureScreenshot of both: 1372x1100 (CSS size x DPR 1 on this display), Bravo's capture shows its own page; clip 200x200 scale 0.5 JPEG -> 100x100. Unknown method -> CDP JSON error via lastError. Posted click on Stop -> worker onDetach canceled_by_user, row indicator and capsule gone. Closing attached Bravo -> worker onDetach target_closed. Not checked at runtime: a 2x display, dark pages, Peek, two windows, the popup's own buttons (its worker debuggerOp path was exercised), the real Claude extension (TASK-132.20).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
chrome.debugger for extensions declaring the debugger permission: attach / detach / getTargets / sendCommand / onEvent / onDetach over an emulated CDP, with Page.enable/disable and Page.captureScreenshot (format, quality, clip with scale; selected and parked tabs). Attaching makes the tab automation-attached (TASK-132.3), so unselected tabs can be captured. Chrome's attach rules and error texts; one debugger per tab; onDetach target_closed / canceled_by_user; unknown methods fail with CDP's 'wasn't found'. Events reach every listening context through ExtensionEventParking, now shared with the tab group events. The user sees a driven tab (sidebar indicator, capsule over the page) and can Stop it. The install prompt says the permission covers every site. Commands for later domains plug in per domain (TASK-132.14/15). 395 tests across the new and affected suites pass; runtime check with the API Explorer passed; full suite not run.
<!-- SECTION:FINAL_SUMMARY:END -->
