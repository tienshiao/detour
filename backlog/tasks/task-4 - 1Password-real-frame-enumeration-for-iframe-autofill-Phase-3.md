---
id: TASK-4
title: >-
  1Password: iframe autofill — test the empty-URL hypothesis for
  srcdoc/about:blank frames on a real login page
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-11 22:28'
updated_date: '2026-09-14 06:48'
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
1Password logged '[Tabs] Could not collect all frames that were initially found' on 2026-09-11 while trying to fill a login form inside an iframe. It calls webNavigation.getAllFrames({tabId}), filters the frames by URL, fans messages out to each with tabs.sendMessage(tabId, msg, {frameId}), and uses getFrame({tabId, frameId}) for parentFrameId. Phase A (commit c7bb06f, notes below) proved WebKit provides getAllFrames/getFrame natively with its own frame ids, so the originally planned worker-side frame registry is not needed and has been dropped. What remains unexplained is the log line itself. Best hypothesis: WebKit reports url '' for srcdoc, data: and about:blank frames, where Chrome reports about:srcdoc / about:blank, and injects no content script into them, so 1Password's URL filter drops frames it counted, or its fan-out finds no receiver there. This task tests that hypothesis against a controlled three-iframe login page and against real 1Password in the signed production build, records the facts in docs/1password-integration-plan.md, and either files the smallest fix as a new task or closes with the next hypothesis. It does not implement a fix.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 _polyfillDiag records whether webNavigation.getAllFrames and getFrame were provided natively by WebKit
- [x] #2 A test page (served by the LoopbackHTTPServer used in ExtensionPolyfillIntegrationTests) with a login form inside (a) a cross-origin http iframe, (b) a srcdoc iframe, (c) an about:blank iframe populated by script, records what native getAllFrames({tabId}) returns for each frame (url, frameId, parentFrameId) and whether the content script ran there (a frame hello reaches the worker with that sender.frameId)
- [x] #3 The result is written to docs/1password-integration-plan.md as a table: frame kind, URL WebKit reports, Chrome's URL for the same frame (about:srcdoc / about:blank), content script injected yes/no, with the WebKit build noted
- [ ] #4 With the signed production build (scripts/deploy-1password-test.sh) 1Password is tried on the same test page and on at least one real site whose login form is inside an iframe; the 1PW-DEBUG log for each attempt is captured, and whether 'Could not collect all frames that were initially found' appears is recorded per frame kind
- [ ] #5 The hypothesis is confirmed or rejected in the notes. If confirmed, a follow-up task describes the smallest fix (candidates: report about:srcdoc / about:blank for empty-URL frames in the tabs/webNavigation results, or inject the content script into those frames via the manifest's match_about_blank / all_frames semantics) with the file map; if rejected, the note names the next hypothesis and this task is closed
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
First half only (AC #2, #3); AC #4/#5 need the signed production build and 1Password unlocked, which only the user can run.
1. New test in ExtensionPolyfillIntegrationTests: two LoopbackHTTPServers (different ports = different origins) serving a login page with (a) a cross-origin http iframe with a form, (b) a srcdoc iframe with a form, (c) an about:blank iframe populated by script with a form; registered as a probe tab like testContentScriptFrameHellosReachTheWorker.
2. Collect native webNavigation.getAllFrames({tabId}) rows (url, frameId, parentFrameId) and every frame hello (sender.frameId, url); print one measurement line per frame kind; assert only the stable facts (the http iframe is enumerated and its content script said hello; every hello frame id is in getAllFrames).
3. Write the table to docs/1password-integration-plan.md under Phase 3: frame kind, URL WebKit reports, Chrome's URL for the same frame (about:srcdoc / about:blank), content script injected yes/no, with the WebKit/macOS build noted.
4. Leave AC #4/#5 open with a note on what the user must run.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Phase A result (2026-09-12, macOS 26): _polyfillDiag.apis.webNavigationFrames reports getAllFrames and getFrame as NATIVE in both the service worker and extension pages, so the polyfill's fallbacks never install in production. Native getAllFrames({tabId}) for a tab with two http iframes and one srcdoc iframe returned all four frames with WebKit's own ids (top 0, subframes 30064771073..75), parentFrameId -1/0, and URLs; getFrame resolved those ids and tabs.sendMessage(tabId, msg, {frameId}) reached the subframe's content script (pinned by ExtensionPolyfillIntegrationTests.testContentScriptFrameHellosReachTheWorker with a loopback HTTP server). Conclusion: the worker-side registry in AC #2-#5/#7 is not needed and would only risk disagreeing with sender.frameId. Best hypothesis for 1Password's 'Could not collect all frames that were initially found': WebKit returns url '' for srcdoc/data:/about:blank frames (Chrome returns about:srcdoc etc.) and injects no content script into them, so 1Password's URL filter drops frames it saw, or its fan-out has no receiver there. Also learned: content-script -> worker messaging in tests works only when the web view is registered as a tab (didOpenWindow/didOpenTab); the XCTSkipIf comments in WKExtensionIntegrationTests blaming the sandbox are stale. A hello sent while the worker sleeps is silently lost.

Code review (medium) of Phase A: deleting the polyfill's getAllFrames/getFrame fallbacks and their native handler cases (dead in production; the native fallback fabricated phantom frame records, so a WebKit regression would degrade silently instead of failing loudly); diag stored as an object; docstring aligned with the intentional native pin; LoopbackHTTPServer reads the full request head and cleans up on a failed start. Declined: pre-recovery-origin extension pages being rejected after a context reload is TASK-14; recovery re-triggering after the 10-minute window is the documented retry design. Decision needed from the user: close TASK-4 (registry not needed) or repurpose it to chase the empty-URL hypothesis against a real 1Password session; AC #2-#7 describe the registry and are left unchecked.

Repurposed 2026-09-12 on the user's decision: the worker-side frame registry (old AC #2-#7) is dropped because Phase A proved WebKit's native getAllFrames/getFrame already return the right ids. The task now chases the remaining unexplained symptom, 1Password's 'Could not collect all frames that were initially found', with the hypothesis that WebKit reports url '' for srcdoc / data: / about:blank frames (Chrome reports about:srcdoc etc.) and injects no content script into them, so 1Password's URL filter drops frames it saw or its fan-out has no receiver there.

First half done 2026-09-13: ExtensionPolyfillIntegrationTests.testFrameKindsAsReportedByNativeGetAllFrames measures a login page with a cross-origin http iframe, a srcdoc iframe and a script-filled about:blank iframe. Result (macOS 26.6.2, WebKit 21624): all four frames are enumerated by native getAllFrames with distinct ids and parentFrameId 0, but the srcdoc and about:blank frames report url '' (Chrome: about:srcdoc / about:blank), get no content script (no hello), and tabs.sendMessage with their frameId fails silently (callback fires with undefined and no lastError). Table and candidate fixes written to docs/1password-integration-plan.md under Phase 3. Repetition-safe (3 iterations of the class green). AC #4/#5 remain for the user: deploy the signed build (scripts/deploy-1password-test.sh --log), try 1Password on the test page and a real iframe-login site, capture 1PW-DEBUG per frame kind, then decide between fix (a) report about:srcdoc/about:blank and (b) inject per match_about_blank.

Trial 2026-09-13 23:41–23:45 (signed build a68e26e, fixture at http://127.0.0.1:8471/ with a top-level form, a cross-origin iframe from http://localhost:8472, a srcdoc iframe and a script-filled about:blank iframe): 1Password's inline menu appeared on NONE of the four forms, including the top-level control. Cause found in the WebKit Extensions log at page load: 'Exception thrown: Invalid call to permissions.contains(). The origins value is invalid, because http://127.0.0.1:8471/* is not a valid pattern' — WebKit match patterns reject a port, Chrome's accept one, so 1Password's per-page origin check throws and it never gets to the forms. The iframe hypothesis is therefore untested by this fixture; it needs either a fixture on default ports or a polyfill that normalises origin patterns with ports before permissions.contains/request. Extension console text was <private> (ExtensionConsoleLogPublic unset), so 1Password's own 'Could not collect all frames' line could not be read either. Over the last 3 days the only other recurring WebKit API rejection is 'windows.get(): Window not found' (74×, periodic ~every 3 min, also at launch) — consistent with ExtensionManager.openWindowsFor listing only windows whose ACTIVE space belongs to the context's profile, so a window showing another profile's space is invisible to that profile's 1Password; benign-looking but unconfirmed.
<!-- SECTION:NOTES:END -->
