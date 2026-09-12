---
id: TASK-15
title: >-
  Extensions: polyfill must not replace the chrome/browser globals in service
  workers (breaks all runtime.sendMessage to the worker)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 05:16'
updated_date: '2026-09-12 06:36'
labels:
  - extensions
  - 1password
  - bug
dependencies: []
priority: high
ordinal: 15000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Regression from TASK-2 (commit 718b627, 2026-09-11). The native-port keep-alive in ExtensionAPIPolyfill (nativePortKeepAliveJS) needs to wrap runtime.connectNative; WebKit's runtime object rejects the direct patch, so installByShadowingGlobals replaces globalThis.chrome and globalThis.browser with a Proxy in service worker contexts. WebKit's runtime message dispatcher (WebExtensionContextProxy::enumerateFramesAndNamespaceObjects) reads the worker's 'browser' then 'chrome' global and unwraps it with toWebExtensionAPINamespace to reach the native onMessage listener list; a Proxy cannot be unwrapped, so the worker frame is skipped and internalDispatchRuntimeMessageEvent replies with the default empty reply. Result: every chrome.runtime.sendMessage from a popup, options page, offscreen document or content script to the background worker resolves undefined with no lastError, for every extension with a service worker. 1Password's popup shows 'Oops, something went wrong while loading' because get-popup-config gets no reply. Diagnosed 2026-09-11 with a console-bridge tracer: page-side callbacks resolve undefined in ~2-20 ms, no worker listener is ever invoked, and WebKit source confirms the unwrap path. Fix: never reassign the globals. Pin a proxied runtime as an own property on the real namespace object instead (Object.defineProperty(chrome, 'runtime', ...), the technique docs/chrome-runtime-patching.md and missingStubsJS already use), so the namespace wrapper stays native while runtime.connectNative is still wrapped. Add a polyfill invariant test: after the polyfill runs against a namespace whose connectNative cannot be patched directly, globalThis.chrome and globalThis.browser are still the original objects, connectNative is wrapped, and onMessage.addListener reaches the real event object.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After the polyfill runs in a service worker context, globalThis.chrome and globalThis.browser are the same objects WebKit installed (identity preserved), with a unit test that forces the fallback path by making connectNative non-patchable
- [x] #2 runtime.connectNative is still wrapped on the fallback path (keep-alive livePorts tracking works) and runtime.onMessage.addListener registers on the real event object
- [x] #3 In the app, 1Password's popup gets past the 'Oops, something went wrong while loading' screen (get-popup-config is answered by the worker); documented in docs/1password-integration-plan.md
- [x] #4 An integration test with a real WKWebExtensionContext whose worker runs the polyfill sends runtime.sendMessage from an extension page and receives the worker's reply, or is skipped with the precise sandbox limitation recorded
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Unit test (ExtensionPolyfillTests): page with a fake chrome/browser namespace whose runtime.connectNative is non-writable+non-configurable (WebKit-like) and __detourForceNativePortKeepAlive=true to bypass the worker gate; assert globals keep identity, connectNative is wrapped (livePorts), onMessage.addListener reaches the real event. Run: must fail on current code.
2. Fix nativePortKeepAliveJS: replace installByShadowingGlobals with pinning a bound runtime proxy as an own property on the real namespace (defineProperty(chrome,'runtime')), never reassigning globalThis.chrome/browser; add the test-only force flag mirroring __detourForceWebSocketGuard.
3. Integration test (ExtensionPolyfillIntegrationTests): give the test extension's service worker the real polyfill + a ping listener; from a real webkit-extension:// page, runtime.sendMessage({type:'ping'}) must get pong (skip with recorded reason only if the sandbox cannot run it).
4. Remove the temporary messaging tracer and the temporary skip removal in WKExtensionIntegrationTests; run polyfill + integration suites; redeploy; user confirms the 1Password popup; disable ExtensionConsoleLogPublic; update docs/1password-integration-plan.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause confirmed at the WebKit level (sources: WebExtensionContextProxy::enumerateFramesAndNamespaceObjects unwraps the worker's browser/chrome global with toWebExtensionAPINamespace; internalDispatchRuntimeMessageEvent sends the empty default reply when no listener handled it). Reproduced in ExtensionPolyfillIntegrationTests with a real module worker + nativeMessaging: grafting the old global-swap fallback back in makes runtime.sendMessage from an extension page return reply=nil, lastError=nil, exactly the popup's symptom; with the fix the worker answers.
Design change from the plan: the 'pin a proxied runtime on the namespace' fallback was implemented and probed, and does not work either (defineProperty is accepted but reads keep returning the native runtime), and the direct patch never takes in WebKit because connectNative is re-materialized on every read (probe: assignment/defineProperty complete, read-back equals neither the written function nor a previous read). So the keep-alive is now direct-or-none, never touches the globals, and exposes installMode/installDetail plus one console.info line per worker start. In WebKit workers it is inert ('none'/'patch-rejected'); it was already ineffective before (workers cycled every 2 min with the old wrapper in place).
Tests: ExtensionPolyfillTests.testKeepAliveLeavesGlobalsUntouchedWhenConnectNativeIsNotPatchable (unit, unpatchable fake), installMode assertion in testKeepAliveStartsWithFirstRealNativePort, ExtensionPolyfillIntegrationTests.testRuntimeSendMessageReachesWorkerRunningThePolyfill (real worker; also asserts WebKit's 'none'/'patch-rejected' so a WebKit change is noticed). 101/101 pass. Docs updated: chrome-runtime-patching.md (Option 2 marked broken, Level 3 added), 1password-integration-plan.md (keep-alive status).

Live verification 2026-09-11 23:34 (user): with the fixed Release build in /Applications the 1Password popup shows the unlock screen, Apple Watch unlock completes, and the popup transitions to the entry for the current site. ExtensionConsoleLogPublic opt-in removed afterwards.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The TASK-2 keep-alive replaced the chrome/browser globals with a Proxy in service workers; WebKit's runtime-message dispatcher unwraps those globals to find worker listeners, cannot unwrap a Proxy, and answered every page->worker runtime.sendMessage with an empty reply, which is why 1Password's popup showed 'Oops, something went wrong while loading'. Removed that fallback (the keep-alive is now direct-or-none and never touches the globals; probing showed WebKit re-materializes runtime.connectNative per read so no JS patch can take, and pinning a substitute runtime is ignored on reads). Added a unit invariant test, an integration test against a real module worker that reproduces the bug when the old behaviour is grafted back, and docs updates. Verified live: the popup unlocks and shows site entries.
<!-- SECTION:FINAL_SUMMARY:END -->
