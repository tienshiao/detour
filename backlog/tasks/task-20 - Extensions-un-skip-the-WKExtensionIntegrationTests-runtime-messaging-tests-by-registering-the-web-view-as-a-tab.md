---
id: TASK-20
title: >-
  Extensions: un-skip the WKExtensionIntegrationTests runtime-messaging tests by
  registering the web view as a tab
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 17:29'
updated_date: '2026-09-12 18:47'
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
- [x] #1 makeWebView() (or a shared helper) registers the web view with the extension context via didOpenWindow/didOpenTab so the worker can receive content-script messages
- [x] #2 The six XCTSkipIf guards and the 'missing entitlements' comment are removed
- [x] #3 All six tests pass under the normal DetourTests run (DETOUR_DATA_DIR set); the full-target summary reports 0 skipped in WKExtensionIntegrationTests
- [x] #4 sendMessageToBackground tolerates a sleeping worker (wakes it or retries) so the tests are not flaky on the first message
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Move the ProbeExtensionWindow/ProbeExtensionTab conformances out of ExtensionPolyfillIntegrationTests into the shared ExtensionTestSupport.swift so both suites use one probe pair.
2. Make makeWebView() in WKExtensionIntegrationTests register the web view as a tab before loading (didOpenWindow/didOpenTab/didActivateTab) and wait on the real navigation instead of sleeping; unregister every probe in an instance tearDown (didCloseTab/didCloseWindow) so tabs do not leak across cases.
3. Delete the six XCTSkipIf guards and replace the stale 'missing entitlements' MARK comment with the real precondition (the web view must be a registered tab).
4. Make sendMessageToBackground wake the worker (context.loadBackgroundContent) before sending and retry once on an empty reply; surface chrome.runtime.lastError in the failure message.
5. Run the WKExtensionIntegrationTests suite at least 3 times under an isolated DETOUR_DATA_DIR, fix any test whose assumption (not the registration) is wrong, and record the run results.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Findings and decisions (2026-09-12):

1. Tab registration was necessary but not sufficient. With the web view registered (didOpenWindow/didOpenTab/didActivateTab via the new shared registerProbeTab helper) the old helper still failed, because it evaluated chrome.runtime.sendMessage in the PAGE world of an https page: 'ReferenceError: Can't find variable: chrome'. WebKit puts chrome only in the extension's content-script world, and a test cannot evaluate JS in that world, so content.js now carries a small window.postMessage relay: the page posts { __detourTest: 'ask' }, the content script does the chrome.runtime.sendMessage round trip and posts the answer back. That is what makes the messaging tests real rather than no-ops.

2. sendMessageToBackground now wakes the worker with context.loadBackgroundContent() before each send and retries once (250 ms apart) if the reply comes back empty, then fails with the reply and chrome.runtime.lastError in the message. No flakiness observed across runs.

3. testAlarmsCreateAndGetAll was failing for its own reason: the background script did chrome.alarms.create(...).then(...), and WebKit's alarms.create does not return a promise, so the listener threw and never called sendResponse — the test saw an empty reply. The worker now dispatches every handler through one awaited wrapper that answers a throw as { error }, so a dying handler is reported instead of looking like a lost message.

4. testStorageOnInstalledFired's premise is false and cannot be fixed from the test: chrome.runtime.onInstalled is never delivered to a context loaded programmatically in the test process. Evidence: after the context is loaded and the worker started (it answers every other message), neither a new worker-global record nor the storage marker appears within ~5 s of polling, while a value written by testStorageLocalSetAndGet is still in storage.local — so storage persists across worker instances and the write was not simply lost with one. Setting context.uniqueIdentifier (as the app does) and setting controller.delegate = ExtensionManager.shared made no difference; both experiments were reverted. The test is therefore renamed testRuntimeOnInstalledIsNotDelivered and pins the measurement with the evidence in the failure message, in the style of the TASK-4 environment pins: if WebKit starts delivering the event it fails loudly and should be flipped to the Chrome expectation. Whether the app itself sees onInstalled on a real install is NOT answered by this and is worth checking separately (the polyfill's runtime.onInstalled emitter and anything in 1Password that relies on install-time setup depend on it).

5. Shared fixtures: ProbeExtensionWindow/ProbeExtensionTab moved out of ExtensionPolyfillIntegrationTests into ExtensionTestSupport.swift with registerProbeTab/unregisterProbeTab helpers; the polyfill frame test now uses them too. Probes registered by makeWebView are closed in an instance tearDown so tabs do not leak into later cases.

Validation: WKExtensionIntegrationTests run 3 consecutive times, each 'Executed 20 tests, with 0 failures (0 unexpected)', 0 skipped (~3.6 s each). ExtensionPolyfillIntegrationTests (touched by the fixture move): 21 tests, 0 failures. Runs used TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-task20 to isolate from other agents' parallel test runs; the log confirms '✓ Test data directory: ~/Library/Application Support/DetourTests-task20/', i.e. DETOUR_DATA_DIR was set, which is what the deleted skips keyed off.

Full-target validation: DetourTests as a whole ran 636 tests, 0 failures, 0 skipped (** TEST SUCCEEDED **), with WKExtensionIntegrationTests at 'Executed 20 tests, with 0 failures'. Note on AC #3 wording: five of the six named tests pass as written; the sixth (testStorageOnInstalledFired) is the one whose premise turned out false, so it is now testRuntimeOnInstalledIsNotDelivered and passes as a measurement pin. No test in the file is skipped.

Code review (medium) fixes: the onInstalled non-delivery test gained a positive control (a storage-set marker must appear in the same storage-dump) and XCTUnwraps both probe shapes, so a broken probe fails instead of passing silently; its polling loop and the stale 500 ms 'wait for onInstalled' sleep are gone; askWorker gained a transport parameter (direct | contentScriptRelay) so the content-script relay shares the one reply envelope, and the page-side timeout is cleared on answer; the worker dispatcher no longer synthesises {ok:true} for a handler that returns nothing; registerProbeTab now calls didFocusWindow like the app's bootstrap. 57 green across the three suites.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Un-skipped the six runtime-messaging tests in WKExtensionIntegrationTests by giving makeWebView a registered tab (shared registerProbeTab/unregisterProbeTab helpers in ExtensionTestSupport, with ProbeExtensionWindow/ProbeExtensionTab moved there from ExtensionPolyfillIntegrationTests), waiting on the real navigation instead of sleeping, and closing the probes in tearDown. Registration alone was not enough: the old helper called chrome.runtime.sendMessage in the page world of an https page, where chrome does not exist, so content.js now relays page->worker messages over window.postMessage. sendMessageToBackground wakes the worker with loadBackgroundContent() and retries once before failing with the reply and lastError. Two tests failed for their own reasons and were fixed at the source: the worker's alarms handler chained .then on chrome.alarms.create, which returns no promise (every handler now goes through one awaited dispatcher that answers a throw as { error }), and runtime.onInstalled is simply never delivered to a programmatically loaded context in the test process (measured; storage persists and another test's value is still there, so the write was not lost) - that test is now testRuntimeOnInstalledIsNotDelivered and pins the measurement loudly instead of skipping. Verified: WKExtensionIntegrationTests 3x at 20 tests / 0 failures / 0 skipped, ExtensionPolyfillIntegrationTests 21/0, full DetourTests target 636 tests / 0 failures / 0 skipped.
<!-- SECTION:FINAL_SUMMARY:END -->
