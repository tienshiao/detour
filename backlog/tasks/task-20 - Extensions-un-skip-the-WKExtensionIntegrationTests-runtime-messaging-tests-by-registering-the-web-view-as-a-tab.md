---
id: TASK-20
title: >-
  Extensions: un-skip the WKExtensionIntegrationTests runtime-messaging tests by
  registering the web view as a tab
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 17:29'
labels:
  - extensions
  - webkit
  - tests
dependencies: []
modified_files:
  - DetourTests/WKExtensionIntegrationTests.swift
priority: low
ordinal: 20000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Six tests in DetourTests/WKExtensionIntegrationTests.swift (testRuntimeSendMessagePing, testRuntimeSendMessageSender, testStorageLocalSetAndGet, testStorageOnInstalledFired, testTabsQueryReturnsResults, testAlarmsCreateAndGetAll) are wrapped in XCTSkipIf(DETOUR_DATA_DIR != nil, 'Skipped in test sandbox — requires full WebKit runtime'), and the MARK comment above them says they fail in the unit test sandbox due to missing entitlements. That diagnosis is stale. TASK-4 Phase A (2026-09-12) established that content-script -> worker messaging works in the test process as long as the WKWebView is registered as a tab with the context (context.didOpenWindow(window) + context.didOpenTab(tab), see the probe in ExtensionPolyfillIntegrationTests around line 757); makeWebView() in WKExtensionIntegrationTests never does that, so sendMessageToBackground gets no reply. Also learned there: a message sent while the worker sleeps is silently lost, so the helper should wake/await the worker (or retry once) before asserting. Fix makeWebView to register the web view as a tab (a probe WKWebExtensionWindow/Tab pair like the polyfill integration tests), delete the six XCTSkipIf guards and the stale comment, and make sure the tests actually pass rather than silently no-op. The current full run reports 6 skipped; the target is 0 skipped in this file.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 makeWebView() (or a shared helper) registers the web view with the extension context via didOpenWindow/didOpenTab so the worker can receive content-script messages
- [ ] #2 The six XCTSkipIf guards and the 'missing entitlements' comment are removed
- [ ] #3 All six tests pass under the normal DetourTests run (DETOUR_DATA_DIR set); the full-target summary reports 0 skipped in WKExtensionIntegrationTests
- [ ] #4 sendMessageToBackground tolerates a sleeping worker (wakes it or retries) so the tests are not flaky on the first message
<!-- AC:END -->
