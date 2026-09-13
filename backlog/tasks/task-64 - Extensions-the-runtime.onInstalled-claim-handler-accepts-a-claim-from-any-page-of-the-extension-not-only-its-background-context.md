---
id: TASK-64
title: >-
  Extensions: the runtime.onInstalled claim handler accepts a claim from any
  page of the extension, not only its background context
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 20:03'
updated_date: '2026-09-13 21:37'
labels:
  - extensions
  - security
dependencies: []
priority: low
ordinal: 64000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-43 work. The polyfill claims the pending runtime.onInstalled event with __detourPolyfillRequest("runtime.claimInstalledEvent") from the background context only (service worker or, since TASK-43, the background page). The native side, ExtensionPolyfillHandler case "runtime.claimInstalledEvent" (~line 519), verifies only that the sender belongs to the extension (its origin), not that the sender IS the background context. An extension page (popup, options, any webkit-extension:// document) could call __detourPolyfillRequest("runtime.claimInstalledEvent", {}) directly and consume its own extension event, so the background context never receives install/update. This is intra-extension only (a page can only claim its own extension event) and no extension is known to do it; the polyfill never did before TASK-43 either. Hardening: for a page sender, check message.frameInfo.request.url path against the manifest background path (background.page resolved against the extension root, or the WebKit generated page name _generated_background_page.html for background.scripts; see the TASK-43 comments in ExtensionAPIPolyfill.runtimeOnInstalledJS); for a worker sender there is no frame, which is the accepted case today. Decide whether a refused claim should log and leave the ledger pending (so the background context still gets the event) rather than error to the caller.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A claim sent from an ordinary extension page (popup/options) is refused, logged, and leaves the ledger pending; the background context still receives the event afterwards
- [x] #2 Claims from a service worker and from an MV3 background page (both background.scripts and background.page shapes) keep working; the existing RuntimeInstalledEvent and ExtensionPolyfillProfileWiringTests suites stay green
- [x] #3 Tests cover the refused page claim (negative) and the accepted background claims (positive)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionPolyfillHandler: introduce a sender kind (worker vs page with frame URL + isMainFrame) threaded from userContentController(didReceive:) (message.frameInfo) and handleNativeMessage into dispatch.
2. Pure function deciding whether a claim sender is the background context: page sender must be the main frame whose path equals the resolved background.page (relative to the extension root) or /_generated_background_page.html for background.scripts; native-message (worker) sender accepted only when the manifest declares background.service_worker.
3. runtime.claimInstalledEvent: refuse with an error reply and a warning log, without touching the ledger, when the sender is not the background context.
4. Tests: unit tests of the pure function in ExtensionPolyfillTests (positive: worker+service_worker manifest, main-frame background page for scripts/page/./page shapes; negative: popup path, iframe, worker path for a scripts-only manifest); wiring test: an ordinary extension page calling __detourPolyfillRequest('runtime.claimInstalledEvent') is refused, ledger still pending, background page then still receives the install. Existing RuntimeInstalledEvent and ExtensionPolyfillProfileWiringTests stay green.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: ExtensionPolyfillHandler.PolyfillSender (.nativeMessage | .frame(url:isMainFrame:)) threaded from both entry points into dispatch; pure ExtensionPolyfillHandler.senderIsBackgroundContext(_:background:) decides the claim: a frame sender must be the main frame at the resolved background.page path (page wins over scripts) or /_generated_background_page.html for background.scripts; a native-message sender is accepted only when the manifest declares a service_worker (a background page always has webkit.messageHandlers, so a native-path claim for a scripts/page extension can only be a non-background page). A refused claim logs a warning and replies with an error before the ledger call, so the event stays pending. Measured: frameInfo.request.url for the generated page is <baseURL>/_generated_background_page.html (existing TASK-43 wiring tests pass unchanged). Tests: 9 unit tests of the pure function + a refused native-path claim that then still delivers after re-registering with a service worker (ExtensionPolyfillTests), and ExtensionPolyfillProfileWiringTests.testAnOrdinaryExtensionPageCannotClaimTheInstalledEventThroughTheBridge (page claim rejected, background page still gets install once). The wiring test asserts the end state rather than 'ledger pending right after the refusal' because opening any extension web view also starts the background page, whose legitimate claim races. Residual gap, accepted: for a service_worker extension a page can still call chrome.runtime.sendNativeMessage('detourPolyfill', {type:'runtime.claimInstalledEvent'}) directly, which is indistinguishable from the worker on that path (WebKit's delegate carries no sender frame).

Review pass: the gate now models background.preferred_environment (ExtensionManifest.Background.mayRunAsServiceWorker / mayRunInGeneratedPage) so a scripts list WebKit hosts in a worker is not refused, and compares percent-encoded paths on both sides like the polyfill's location.pathname. Two limits are inherent to what WebKit hands the host and are documented on senderIsBackgroundContext: (1) runtime.sendNativeMessage reaches the controller delegate with the WKWebExtensionContext only, never the sending frame, so for a service-worker manifest an ordinary extension page calling sendNativeMessage('detourPolyfill', {type:'runtime.claimInstalledEvent'}) directly is indistinguishable from the worker; (2) a frame is identified by path, so a top-level extension page navigated to the background path passes (the polyfill's own contextKind classifies it the same way, pre-existing since TASK-43). Both can only take their own extension's event. No public WKWebExtensionContext API exposes the background web view or a native message's sender.

Review pass (code-review --fix): the native-message rule now uses ExtensionManifest.Background.mayRunAsServiceWorker and the generated-page rule mayRunInGeneratedPage, which honour WebKit's preferred_environment (a scripts list may be hosted in a worker, a service_worker in the generated document; string or array). Frame paths are compared percent-encoded (URLComponents.percentEncodedPath), matching location.pathname on the polyfill side, so 'my page.html' meets '/my%20page.html' and '/bg%2Ehtml' is refused. Extra unit tests for both. Second known limit recorded in the doc comment: a top-level extension page navigated to the background path passes the gate (the polyfill classifies it the same way).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
runtime.claimInstalledEvent now checks the sender, not only the extension identity: a frame sender must be the main frame at the background document's percent-encoded path (background.page resolved against the root, or the generated page for scripts / preferred_environment document); a native-message sender is accepted only when the background may run as a service worker. A refused claim logs, replies with an error, and leaves the ledger pending. Verified with 13 unit tests of senderIsBackgroundContext, a refused-then-delivered native-path test, and a wiring test where an ordinary page's claim is rejected and the background page still gets the install; all existing RuntimeInstalledEvent and wiring tests pass (276 tests across the affected suites).
<!-- SECTION:FINAL_SUMMARY:END -->
