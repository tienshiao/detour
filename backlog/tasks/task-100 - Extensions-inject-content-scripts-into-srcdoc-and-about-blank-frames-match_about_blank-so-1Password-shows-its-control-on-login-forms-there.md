---
id: TASK-100
title: >-
  Extensions: inject content scripts into srcdoc and about:blank frames
  (match_about_blank), so 1Password shows its control on login forms there
status: To Do
assignee: []
created_date: '2026-09-21 08:12'
labels:
  - extensions
  - 1password
  - webkit
dependencies:
  - TASK-4
documentation:
  - docs/1password-integration-plan.md
priority: medium
ordinal: 100000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by TASK-4. WebKit's native webNavigation.getAllFrames enumerates srcdoc and script-filled about:blank iframes but reports url '' for them (Chrome: about:srcdoc / about:blank), injects no manifest content script into them, and tabs.sendMessage with their frameId fails silently (ExtensionPolyfillIntegrationTests.testFrameKindsAsReportedByNativeGetAllFrames, macOS 26.6.2 / WebKit 21624). Signed build 2026-09-21 with real 1Password 8.12.26.40 on the fixture (top-level form, cross-origin http iframe, srcdoc iframe, script-filled about:blank iframe, served from 127.0.0.1:8471 + localhost:8472): the login forms inside the srcdoc and about:blank frames get NO 1Password control at all. Chrome injects into such frames when the content script declares match_about_blank (or match_origin_as_fallback), matching against the parent/initiator URL. First establish what 1Password's manifest declares for its content scripts and whether WebKit ignores the key or never considers empty-URL frames; then make Detour inject the declared scripts into those frames when the parent frame's URL matches (candidate: a WKUserScript / per-frame evaluate path driven from the manifest, in the extension's content world), and decide whether tabs/webNavigation results should also report about:srcdoc / about:blank instead of '' (plan doc Phase 3, candidates (a) and (b)). Security: only inject where Chrome would — the key must be declared, and the match is against the parent's URL with the extension's granted host access; never into frames whose parent the extension cannot access. Fixture recipe: TASK-4 notes and the plan doc's Phase 3 'Signed build, 2026-09-21' table.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Documented: which of match_about_blank / match_origin_as_fallback 1Password's content scripts declare, and why WebKit does not inject into srcdoc/about:blank frames (WebKit source reference)
- [ ] #2 A content script that declares match_about_blank runs in a srcdoc iframe and in a script-filled about:blank iframe whose parent URL matches its patterns, and a frame hello from each reaches the worker with that frame's sender.frameId
- [ ] #3 Negative cases are tested: a script without the key is not injected there; a frame whose parent URL does not match, or whose parent host the extension has no access to, is not injected
- [ ] #4 tabs.sendMessage(tabId, msg, {frameId}) reaches the content script in those frames, and the URL reported for them by webNavigation.getAllFrames/getFrame is decided and documented (about:srcdoc / about:blank vs '')
- [ ] #5 API Explorer covers the frame kinds, and docs/1password-integration-plan.md Phase 3 records the outcome
- [ ] #6 Signed build: 1Password shows its control in the srcdoc and about:blank forms of the TASK-4 fixture
<!-- AC:END -->
