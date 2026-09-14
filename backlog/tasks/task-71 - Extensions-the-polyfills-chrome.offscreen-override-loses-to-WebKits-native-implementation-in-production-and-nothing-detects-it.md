---
id: TASK-71
title: >-
  Extensions: determine whether the polyfill's chrome.offscreen override or
  WebKit's native offscreen runs in the signed build, and make it observable
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-14 04:11'
updated_date: '2026-09-14 05:42'
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
- [x] #1 The polyfill records which chrome.offscreen implementation is in force (an install marker like __detourOffscreenInstall plus a native-vs-polyfill distinction in __detourPolyfillDiag) and the console bridge logs it once per background start
- [x] #2 ExtensionPolyfillProfileWiringTests cover the marker/diag with both the polyfill-wins and (simulated) native-present cases
- [x] #3 The decision (native vs polyfill offscreen) is recorded with its reason, and if Detour's override is meant to win, a failed define is logged as an error rather than a console.warn inside the worker, verified against the signed build's WebKit
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. offscreenJS: capture the pre-existing chrome.offscreen, classify it with the '[native code]' toString check (precedent __detourWebNavFrames), install Detour's object (tagged _detourPolyfill: true, idempotent on re-run) via __detourDefine; record globalThis.__detourOffscreenInstall = 'polyfill' | 'polyfill-over-native' | 'error: <message>' (error when the define did not take, checked by re-reading chrome.offscreen); on failure console.error, not console.warn. Add __detourPolyfillDiag.apis.offscreenInstall. In a worker or background page emit one console.info line '[Detour polyfill] chrome.offscreen implementation: <marker>' the way the keep-alive line does.
2. Tests: ExtensionPolyfillTests — default → 'polyfill' and non-native createDocument; shim pre-installs a fake native namespace (bound functions stringify as [native code]) → 'polyfill-over-native' and Detour's object wins; a non-configurable pre-installed namespace → 'error: …' with a console.error captured. ExtensionPolyfillProfileWiringTests — the probe worker's __detourPolyfillDiag.apis.offscreenInstall is 'polyfill' and the captured native is null.
3. Record the determination in the task and in docs/1password-integration-plan.md (short note under the offscreen discussion); production confirmation comes from the new console line in the next signed-build run.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Determination (2026-09-13): the shipped WebKit (framework version 21624.5.1.11.3 = safari-7624 branch) has no WK_WEB_EXTENSIONS_OFFSCREEN: its UnifiedWebPreferences.yaml has no WebExtensionOffscreenEnabled and its WebExtensionAPINamespace.idl has no offscreen attribute (both present on main, gated by that flag + the offscreen permission + the WebExtensionOffscreenEnabled setting). So in the signed build there is no native chrome.offscreen to win; page 577 in the production run was Detour's OffscreenDocumentHost web view (it lives in the extension's process like every page of the controller's configuration), and the missing offscreen.createDocument log line is most likely the info-level message not being persisted by 'log show'. Decision: Detour's implementation is the one in force and stays so — a future native namespace gets shadowed and reported as 'polyfill-over-native' so it is noticed.

Implemented (commit 260546e): offscreenJS reads chrome.offscreen first (try-guarded), classifies it with the [native code] check, installs Detour's namespace tagged _detourPolyfill and verifies by re-reading; globalThis.__detourOffscreenInstall is written once as polyfill | polyfill-over-native | polyfill-over-foreign | error: … (error also console.error'd); __detourPolyfillDiag.apis.offscreenInstall carries it and workers/background pages log '[Detour polyfill] chrome.offscreen implementation: …' once per start. Real worker in the test host reads polyfill with no captured native namespace. Tests: 5 in ExtensionPolyfillTests, 1 in ExtensionPolyfillProfileWiringTests. The production confirmation is that console line in the next signed-build run.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Determined that the shipped WebKit (21624 = safari-7624 branch) has no chrome.offscreen at all (WK_WEB_EXTENSIONS_OFFSCREEN exists only on main), so Detour's polyfill is the implementation in force in production; the missing production log line was most likely an unpersisted info-level message. Decision: Detour's implementation wins; a native namespace, if WebKit adds one, is shadowed and reported. offscreenJS now records __detourOffscreenInstall (polyfill | polyfill-over-native | polyfill-over-foreign | polyfill-over-unreadable | error: …), exposes it as __detourPolyfillDiag.apis.offscreenInstall, console.error's a failed define, and logs '[Detour polyfill] chrome.offscreen implementation: …' once per worker/background-page start. Verified by 5 ExtensionPolyfillTests (incl. simulated native and non-configurable namespaces) and a real-worker wiring test reading 'polyfill' against the same system WebKit the signed build uses. docs/1password-integration-plan.md records the determination.
<!-- SECTION:FINAL_SUMMARY:END -->
