---
id: TASK-18
title: >-
  Extensions: offscreen.createDocument must reply and unregister its host when
  the offscreen page fails to load
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 07:32'
updated_date: '2026-09-12 17:55'
labels:
  - extensions
dependencies: []
priority: low
ordinal: 18000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
ExtensionPolyfillHandler registers the OffscreenDocumentHost in offscreenHosts before loading, and its replyHandler is only invoked from OffscreenDocumentHost's didFinish or stop(). didFail and didFailProvisionalNavigation only log, so when the offscreen page 404s or is blocked the extension's createDocument promise pends forever, every later createDocument short-circuits with success because the dead host is still registered, and offscreen.hasDocument reports true for a document that never loaded, until an explicit closeDocument. Found by the 2026-09-12 code review of TASK-13 (pre-existing).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A failed offscreen page load (404 or blocked navigation) rejects the createDocument request with an error
- [x] #2 The failed host is removed from offscreenHosts so hasDocument returns false and a retry loads again
- [x] #3 Tests cover the failure path through handleNativeMessage with a missing offscreen page, plus the existing success path
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. OffscreenDocumentHost: Result-style load completion ((Result<Void, any Error>) -> Void) with a nested LoadError enum (.closedBeforeLoad, .navigationFailed(path:underlying:)); every load-ending path (didFinish, didFail, didFailProvisionalNavigation, stop) drains the pending completions exactly once through a private settleLoad(_:).
2. ExtensionPolyfillHandler offscreen.createDocument completion: keep the existing identity guard (a reply belonging to a stopped/replaced host never touches the newer one); on .failure with the host still registered, removeValue + host.stop() and reply with error.localizedDescription so hasDocument goes false and a retry loads again.
3. Tests in ExtensionPolyfillProfileWiringTests (the suite that drives handleNativeMessage through real Profile wiring): missing offscreen page rejects + hasDocument false + retry succeeds; pending create then closeOffscreenDocument rejects with the closed error (TASK-12 AC #3); existing success path unchanged.
4. Build Detour, run the affected suites, self-review the diff for double replies / late replies hitting a newer host / retain cycles.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented as planned. OffscreenDocumentHost.load now takes ((Result<Void, any Error>) -> Void); the new nested OffscreenDocumentHost.LoadError (LocalizedError) carries .closedBeforeLoad and .navigationFailed(path:underlying:), and a private settleLoad(_:) drains the pending completions from didFinish (.success), from both failure callbacks (.failure(.navigationFailed)) and from stop() (.failure(.closedBeforeLoad)). settleLoad clears before invoking and no-ops on an empty list, so no path can answer a request twice — the handler's own failure branch calls host.stop() and that second drain finds nothing.

In the handler's createDocument completion the identity guard (offscreenHosts[extensionID] === host) still runs first, so neither a success nor a failure belonging to a dead host can touch a newer one; only inside the identity-holding failure branch does it removeValue + host.stop() and reply with error.localizedDescription. host.load had exactly one caller, so no other adaptation was needed.

Note the real WebKit behaviour the test pins down: a missing page under webkit-extension:// does produce a genuine didFailProvisionalNavigation (NSURLErrorDomain -1100, file does not exist), so the failure test drives the production navigation path rather than a stub. Message seen: 'Offscreen document no-such-offscreen.html failed to load: The operation couldn't be completed. (NSURLErrorDomain error -1100.)'. The reply names the extension-relative path the extension itself asked for (not the resolved webkit-extension:// URL) — handleNativeMessage logs polyfill error strings publicly, and the relative path is the least sensitive thing that still identifies the failure.

Tests (DetourTests/ExtensionPolyfillProfileWiringTests.swift, the suite that drives handleNativeMessage through real Profile wiring): testOffscreenCreateDocumentFailsAndUnregistersWhenPageIsMissing (rejects, names the page, host unregistered, hasDocument false, retry with a real page loads, exactly one reply) and testLateOffscreenLoadFailureDoesNotUnregisterANewerHost (a failure delivered after a replacement host took the slot settles its own request and leaves the newer host registered).

Validation: xcodebuild -scheme Detour -configuration Debug build => BUILD SUCCEEDED. env TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-task18 xcodebuild -scheme DetourTests test -only-testing:DetourTests/ExtensionPolyfillProfileWiringTests => 13 tests, 0 failures; -only-testing ExtensionPolyfillTests + ExtensionPolyfillIntegrationTests => 133 tests, 0 failures.

Out of scope, noticed not changed: the JS callback form of these APIs (15 wrappers in ExtensionAPIPolyfill, incl. offscreen.createDocument/closeDocument) does promise.then(cb) with no .catch, so a rejection reaches a callback-style caller as an unhandled rejection instead of chrome.runtime.lastError. The promise form — what MV3 extensions actually use — rejects correctly through both bridges.

2026-09-12 code review (--fix): a createDocument arriving while the first load is in flight used to hit the 'already exists' short-circuit and resolve true for a document that had not loaded (and, with this task's failure path, might then be unregistered). OffscreenDocumentHost now exposes isLoading + addLoadCompletion; the handler joins a mid-load create onto the pending load via a shared offscreenLoadCompletion, hasDocument reports false while loading, the identity-guard exit reports the failure it waited on, and the failure branch calls closeOffscreenDocument (single teardown). didFail/didFailProvisionalNavigation go through failLoad, which ignores NSURLErrorCancelled / WebKitErrorDomain 102 via a shared Error.isIgnoredNavigationError (hoisted from BrowserWindowController+Navigation) so a self-navigating offscreen page is not torn down. New tests: testConcurrentOffscreenCreateDocumentJoinsTheLoadInFlight, testConcurrentOffscreenCreateDocumentBothFailWhenPageIsMissing, testCancelledOffscreenNavigationKeepsTheCreateDocumentPending; ExtensionPolyfillProfileWiringTests 16/16, ExtensionPolyfillTests + ExtensionPolyfillIntegrationTests 133/133.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
OffscreenDocumentHost.load now reports a Result and every load-ending path (didFinish, didFail, didFailProvisionalNavigation, stop) settles the pending completions exactly once through settleLoad; a failed offscreen page load therefore rejects the createDocument request and, with the host identity re-checked first, unregisters the dead host so hasDocument goes false and a retry loads again. Verified by two new tests in ExtensionPolyfillProfileWiringTests driving handleNativeMessage against a real missing webkit-extension:// page (a genuine didFailProvisionalNavigation, -1100) and against a failure arriving after a replacement host took the slot; Detour builds and the three polyfill suites pass (13 + 133 tests, 0 failures).
<!-- SECTION:FINAL_SUMMARY:END -->
