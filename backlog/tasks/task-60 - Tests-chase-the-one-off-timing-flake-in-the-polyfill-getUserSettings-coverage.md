---
id: TASK-60
title: 'Tests: chase the one-off timing flake in the polyfill getUserSettings coverage'
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 17:31'
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
- [ ] #1 The failing test and assertion are identified from a reproduced failure, and the cause is recorded in the task notes
- [ ] #2 The two polyfill getUserSettings suites pass 50 consecutive iterations after the fix
- [ ] #3 No retry loop or sleep is added to the tests; a readiness wait, if needed, keys on a real signal such as __detourPolyfillDiag.loaded
<!-- AC:END -->
