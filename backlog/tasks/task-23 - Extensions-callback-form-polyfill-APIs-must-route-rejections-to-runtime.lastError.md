---
id: TASK-23
title: >-
  Extensions: callback-form polyfill APIs must route rejections to
  runtime.lastError
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 19:07'
updated_date: '2026-09-12 23:02'
labels:
  - extensions
  - polyfill
dependencies: []
priority: low
ordinal: 23000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-18 work (2f002d7): the callback wrappers in ExtensionAPIPolyfill.swift (about 15 of them, including offscreen.createDocument and closeDocument) do promise.then(cb) with no .catch, so when the native side rejects (now a real path for offscreen loads that fail) a callback-style caller gets an unhandled promise rejection and its callback never runs, instead of the callback running with chrome.runtime.lastError set as Chrome does. The promise form used by MV3 extensions rejects correctly through both bridges. Fix the wrapper generator once: on rejection set runtime.lastError for the duration of the callback, invoke it with undefined, then clear lastError, and report an unchecked lastError to the console the way Chrome does. Keep let/const in the polyfill.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A callback-style call whose native reply is an error invokes the callback with runtime.lastError set to the error message and clears it afterwards; no unhandled rejection is logged
- [x] #2 The promise form is unchanged and still rejects
- [x] #3 ExtensionPolyfillTests cover the callback path for at least offscreen.createDocument and one other wrapper, with positive and negative cases
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Probe WebKit's native chrome.runtime.lastError in a real extension page and module worker (descriptor, defineProperty/assign/delete read-back, native callback semantics).
2. Add one callback settler to the polyfill preamble (__detourSettle) and route all 15 promise-backed callback wrappers through it; the promise form is returned unchanged when no callback is passed.
3. On rejection: if runtime.lastError can be overridden from JS (verified by read-back), install a getter for the duration of the callback, restore after, and console.error 'Unchecked runtime.lastError: <msg>' when it was never read. If WebKit ignores the override (native runtime), relay the message through chrome.runtime.sendNativeMessage to a new native 'runtime.lastErrorRelay' type that always replies with that message as its error, so WebKit's own lastError machinery runs the callback. Last resort: callback with no args + console.error.
4. Callback exceptions are rethrown asynchronously, never left as unhandled rejections.
5. Tests: ExtensionPolyfillTests (JS path, offscreen.createDocument + history.search/notifications.create, positive/negative, promise form still rejects, no unhandledrejection, unchecked report); ExtensionPolyfillProfileWiringTests (real WebKit page through production wiring: offscreen.createDocument callback with a missing page gets native lastError, success path clean); handler test for the relay type.
6. Document the WebKit finding in docs/chrome-runtime-patching.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
WebKit probe (2026-09-12, temporary test in ExtensionPolyfillIntegrationTests, extension page + module service worker): chrome.runtime.lastError reports as an own data property {value:null, writable:false, configurable:true, enumerable:false}; defineProperty (getter or value), assignment and delete all complete without throwing but reads stay null and the descriptor never changes. browser.runtime === chrome.runtime; chrome.extension.lastError does not exist. WebKit's own failing callbacks (tabs.get(999999, cb), sendNativeMessage(..., cb)) get zero args, lastError {message: 'Invalid call to <api>(). <reason>.'} during the callback, null after. So a configurable check alone is insufficient: the JS override must be verified by read-back.

Design: one settler __detourSettle(promise, callback, passResult) in the preamble; all 15 promise-backed wrappers go through it. On rejection: (1) 'js' mode: install a lastError getter on every distinct chrome/browser runtime, verified by read-back, restore the original property after the callback, console.error 'Unchecked runtime.lastError: <msg>' if never read; (2) 'native-relay' mode (WebKit): call the callback-form runtime.sendNativeMessage('detourPolyfill', {type:'runtime.lastErrorRelay', params:{message}}) whose native handler always fails with that message, and run the extension callback from WebKit's callback, so WebKit sets/clears lastError (message gains WebKit's 'Invalid call to runtime.sendNativeMessage(). ' prefix); (3) 'console' mode fallback. Callback exceptions are rethrown on a fresh task (uncaught error, no unhandled rejection). __detourCallbackLastError.lastMode exposes the path taken. The relay needs no permission (echoes the sender's own text, capped at 2048 chars) and is logged at debug/private instead of the error log. Relay works for extensions that do not declare nativeMessaging because Profile grants it at the context level.

Build note: codesign --timestamp intermittently failed ('A timestamp was expected but was not found') and left .cstemp files that broke later runs; local test runs used OTHER_CODE_SIGN_FLAGS=--timestamp=none.

Validation: ExtensionPolyfillTests 131/131, ExtensionPolyfillProfileWiringTests 18/18 (incl. new real page + real service worker tests asserting mode 'native-relay'), full Extension*/WK* run 323/323 passed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Callback-style polyfill APIs now settle failures into runtime.lastError instead of leaving an unhandled rejection and never running the callback. All 15 promise-backed wrappers (idle, notifications, history, management, fontSettings, sessions, search, offscreen incl. createDocument/closeDocument) route through one preamble helper, __detourSettle; the promise form is returned untouched. WebKit's native runtime.lastError silently ignores defineProperty/assignment/delete (measured in a real extension page and module worker), so in real contexts the message is relayed through the callback form of runtime.sendNativeMessage to a new always-failing native type runtime.lastErrorRelay, letting WebKit set and clear lastError itself (message carries WebKit's 'Invalid call to runtime.sendNativeMessage(). ' prefix). Where lastError is writable (verified by read-back) a getter is installed for the callback and restored after, with Chrome's 'Unchecked runtime.lastError' console report. Documented in docs/chrome-runtime-patching.md. Verified: ExtensionPolyfillTests (JS path, relay/console fallbacks, relay handler; createDocument + history.search positive/negative, promise form rejects, no unhandledrejection), ExtensionPolyfillProfileWiringTests (real page and real service worker, createDocument missing page -> lastError, existing page -> clean); all Extension*/WK* classes 323/323.
<!-- SECTION:FINAL_SUMMARY:END -->
