---
id: TASK-60
title: 'Tests: chase the one-off timing flake in the polyfill getUserSettings coverage'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 17:31'
updated_date: '2026-09-13 19:29'
labels:
  - tests
  - extensions
  - flake
dependencies: []
priority: low
ordinal: 60000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
During the TASK-55 review run (2026-09-13) one polyfill test around chrome.action.getUserSettings failed once on timing and passed on re-run; the exact test name and assertion were not captured. The candidates are ExtensionPolyfillTests.testActionGetUserSettingsStub / testActionGetUserSettingsNotReplacedWhenNative (DetourTests/ExtensionPolyfillTests.swift ~577-616, bare WKWebView with a shimmed chrome.action) and ExtensionPolyfillIntegrationTests.testGapFillingModulesInRealExtensionContext (~516-545, a real extension context reading __detourPolyfillDiag.apis.actionGetUserSettings). The diag value is written by the polyfill tail (ExtensionAPIPolyfill.swift ~110) from globalThis.__detourActionUserSettingsInstall, set by the actionUserSettingsJS module (~1973-2000), which checks whether chrome.action.getUserSettings already exists when it runs. A timing dependency here would be the test reading the diag or calling the API before the polyfill script has finished, or the shim (shimExtras) racing the polyfill injection order.

First reproduce: loop the two suites (xcodebuild -only-testing with -test-iterations or a shell loop) until it fails again and capture the failing assertion and the diag payload. Then fix the cause (a readiness wait on __detourPolyfillDiag.loaded before the assertion, or an ordering fix in the injection) rather than adding a retry.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The failing test and assertion are identified from a reproduced failure, and the cause is recorded in the task notes
- [x] #2 The two polyfill getUserSettings suites pass 50 consecutive iterations after the fix
- [x] #3 No retry loop or sleep is added to the tests; a readiness wait, if needed, keys on a real signal such as __detourPolyfillDiag.loaded
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce: run the three candidate tests (ExtensionPolyfillTests/testActionGetUserSettingsStub, testActionGetUserSettingsNotReplacedWhenNative, ExtensionPolyfillIntegrationTests/testGapFillingModulesInRealExtensionContext) with xcodebuild -test-iterations 50 -run-tests-until-failure and capture the failing assertion and __detourPolyfillDiag.
2. If it reproduces, fix the cause (a readiness wait keyed on __detourPolyfillDiag.loaded, or an injection-order fix), then re-run 50 iterations green. If it does not reproduce in 50 iterations, record that in the notes and stop; the user decides whether to keep the task open.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Reproduced at iteration 4/50: ExtensionPolyfillIntegrationTests.testGapFillingModulesInRealExtensionContext, line 540, typeof chrome.action.getUserSettings was undefined while the install marker still read polyfill. Cause is a product bug, not a test race: chrome.action is [MainWorldOnly, Dynamic] in WebKit, so every read returns the wrapper from a weak cache; nothing held the patched wrapper, the first GC collected it and the next read minted a fresh wrapper without getUserSettings (the hazard docs/chrome-runtime-patching.md already records for chrome.runtime). Proven with a WeakRef plus forced allocation: 5/5 collected. Affects production feature detection from long-lived pages (1Password). Fix: actionUserSettingsJS holds a strong root to the patched wrapper (globalThis.__detourActionNamespace) and verifies a fresh read sees the patch; same hold on the native+onAuthRequired path of chrome.webRequest. New guard testActionGetUserSettingsSurvivesGarbageCollection forces a collection and asserts the API survives (fails 3/3 without the root). 200/200 iterations green after the fix; ExtensionPolyfillTests 10x 1400/1400. Pre-existing and unrelated: ExtensionPolyfillIntegrationTests.testContentScriptFrameHellosReachTheWorker fails 9/10 under -test-iterations (not repetition-safe) on the unmodified tree; not filed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The one-off getUserSettings failure was a real bug: the polyfilled chrome.action wrapper was garbage-collected and re-minted without the patch. The polyfill now roots the patched wrapper; a GC-forcing test guards it, and the rule is documented in docs/chrome-runtime-patching.md. 200/200 iterations green.
<!-- SECTION:FINAL_SUMMARY:END -->
