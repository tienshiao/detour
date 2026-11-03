---
id: TASK-255
title: >-
  Extensions: native polyfill errors read differently from the worker and from a
  page
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T17:09:00Z'
updated_date: '2026-11-03T22:38:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: low
type: bug
ordinal: 299000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-240. An error a native polyfill handler returns reaches a service worker wrapped by WebKit as "Invalid call to runtime.sendNativeMessage(). <message>", and the worker's callback runtime.lastError carries the prefix twice; an extension page sees the bare message. Extensions matching on error text behave differently by context. Applies to every native polyfill API, not only notifications.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A native polyfill error reaches promise rejections and runtime.lastError with the same message text from the service worker and from an extension page, without the WebKit prefix
- [x] #2 Tests in a real extension context compare the error text from both transports, in both forms
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Worker requests set errorEnvelope:true; ExtensionPolyfillHandler.replyFailure answers a failure as a successful reply {__detourPolyfillError: text} (handler failures and the delegate's pre-dispatch refusals), and __detourPolyfillRequest rejects with that text. WebKit's toErrorString rewrite (prefix, capital, trimmed dots, full stop) is lossy, so stripping alone cannot give the page's text. Errors WebKit still delivers lose only its exact 'Invalid call to runtime.sendNativeMessage(). ' prefix and appended full stop.
2. Callback form (native-relay, both transports): inside WebKit's relay callback, read runtime.lastError (a per-report JS Error) and redefine its message as the original text before running the extension's callback. Reading it marks it checked for WebKit; the polyfill does not report unchecked itself (it cannot see a truthiness check of WebKit's getter, and a false report on correct code is worse).
3. Tests: real-context test comparing page vs worker, promise vs callback, for a permission refusal and a bad-argument error (exact text); ExtensionHistoryScopeTests and ExtensionNotificationOrderingTests now assert exact text; JS-level tests in ExtensionPolyfillTests (prefix strip, envelope unwrap, relay rewrite, no unchecked report, handler envelope).
4. Wiki polyfill-layer section 'Error text from both transports', chrome-runtime-patching page, docs/chrome-runtime-patching.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Tests: ExtensionPolyfillTests 194, ExtensionHistoryScopeTests 63 (13 skipped), ExtensionNotificationOrderingTests 26, ExtensionPolyfillIntegrationTests 57, ExtensionPolyfillProfileWiringTests 25, ExtensionPermissionRestoreTests 20, NativeMessagingEnforcementTests 18: 403 run, 0 failures. New: ExtensionHistoryScopeTests.testANativeErrorReadsTheSameFromBothTransportsInBothForms (permission refusal + bad argument, page/worker x promise/callback, exact text, no prefix); exact-text assertions in HistoryScope and NotificationOrdering suites; ExtensionPolyfillTests: relay rewrite, no unchecked report, prefix strip, envelope unwrap, handler envelope.
Runtime (/verify): seeded MV3 module worker in an isolated DETOUR_DATA_DIR, -ExtensionConsoleLogPublic YES; the worker printed history.search refusal and notifications.clear() bad-argument errors in promise and callback form: all four read exactly 'history permission not declared' / 'notificationId required'; no Unchecked line. Data dir and defaults keys removed.
Review (/code-review --fix): fixed the chrome.runtime fallback's duplicated normalisation, renamed the helpers' containing: label to reading:, enveloped the delegate's pre-dispatch refusals, dropped polyfill-side unchecked reporting (it flagged callbacks that only test if (chrome.runtime.lastError)). Skipped: in-band envelope key collision (no handler returns user-keyed string maps), whether browser.runtime.lastError is the same object as chrome.runtime's (unconfirmed), the test-only global hook (precedent __detourCallbackLastError).
Not verified: an extension page in the running app (covered by the real-context tests only); signed build not needed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A native polyfill error now reads the same from an extension page and from the service worker, in the promise rejection and in runtime.lastError: the handler's text, without WebKit's 'Invalid call to runtime.sendNativeMessage().' prefix. Worker requests ask for the error in a success reply ({__detourPolyfillError}), because WebKit's rewrite is lossy (capital, trimmed dots); a WebKit-delivered error loses only that exact prefix and its full stop. The lastError relay redefines the message of WebKit's lastError Error to the original text; as a consequence native-relay no longer reports unchecked lastErrors (trade-off recorded in the wiki).
<!-- SECTION:FINAL_SUMMARY:END -->
