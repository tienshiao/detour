---
id: TASK-71
title: >-
  Extensions: determine whether the polyfill's chrome.offscreen override or
  WebKit's native offscreen runs in the signed build, and make it observable
status: To Do
assignee: []
created_date: '2026-09-14 04:11'
updated_date: '2026-09-14 04:13'
labels:
  - extensions
  - bug
dependencies: []
priority: medium
ordinal: 71000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Filed by the TASK-68 review on the premise that an offscreen page's close killed 1Password's worker. That premise is withdrawn: the worker was killed by WebKit's tracking-prevention storage purge (TASK-70), and the harness shows neither a Detour-hosted offscreen close nor an ordinary page close touches the worker. What remains is a real, unexplained discrepancy: in the 2026-09-13 20:04 production run 1Password's offscreen document was loaded by WebKit as page 577 inside the worker's WebContent process with loadRequest, WKWebExtension recorded resource errors for it (EXT-LOAD code 2 for background/offscreen/vendor/semver.js and just-pick.js), and Detour's ExtensionPolyfillHandler logged no offscreen.createDocument line — i.e. WebKit's native chrome.offscreen served the call — whereas in the test host the probe worker sees no native chrome.offscreen and the polyfill's OffscreenDocumentHost implementation runs. offscreenJS installs Detour's implementation with __detourDefine(chrome, 'offscreen', ...) unconditionally, and __detourDefine's only failure path is a console.warn a worker never surfaces. Determine which implementation wins in the signed build and why (WebKit feature availability by build/entitlement? manifest permission? define rejected as for connectNative?), decide which one Detour wants, and make the outcome observable (an install marker in the polyfill diag like __detourPrivacyInstall, and a log line naming the implementation), so a future offscreen-related bug can be attributed. Precedent: __detourWebNavFrames's '[native code]' toString check.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The polyfill records which chrome.offscreen implementation is in force (an install marker like __detourOffscreenInstall plus a native-vs-polyfill distinction in __detourPolyfillDiag) and the console bridge logs it once per background start
- [ ] #2 ExtensionPolyfillProfileWiringTests cover the marker/diag with both the polyfill-wins and (simulated) native-present cases
- [ ] #3 The decision (native vs polyfill offscreen) is recorded with its reason, and if Detour's override is meant to win, a failed define is logged as an error rather than a console.warn inside the worker, verified against the signed build's WebKit
<!-- AC:END -->
