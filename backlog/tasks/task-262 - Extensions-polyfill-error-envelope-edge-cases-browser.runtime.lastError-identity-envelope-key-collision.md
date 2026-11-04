---
id: TASK-262
title: >-
  Extensions: polyfill error envelope edge cases (browser.runtime.lastError
  identity, envelope key collision)
status: Done
assignee: []
created_date: '2026-11-03T22:39:00Z'
updated_date: '2026-11-04T00:58:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: low
type: chore
ordinal: 306000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Left from TASK-255, which answers worker-side polyfill failures as {__detourPolyfillError: text} and rewrites runtime.lastError.message in the relay callback. Two gaps: (1) it is unconfirmed whether browser.runtime.lastError in a WebKit worker is the same object as chrome.runtime.lastError; if not, a callback reading browser.runtime still sees WebKit's prefixed, capitalised text. (2) A successful reply that is a string map with the key __detourPolyfillError would be misread as a failure; no handler returns user-keyed maps today. Also recorded: WebKit's "Unchecked runtime.lastError" report no longer fires on the relay path (TASK-255 decision).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Whether browser.runtime.lastError and chrome.runtime.lastError are the same object in a worker is measured; if not, both read the original text
- [x] #2 Success and failure replies cannot be confused (e.g. both wrapped), with JS-level and real-context tests
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured in the test host and in a seeded worker in the running app: in a worker browser.runtime === chrome.runtime and the relay callback's lastError is one object under both names, so browser.runtime.lastError.message already reads the original text; no relay change needed, the measurement is now asserted (ExtensionHistoryScopeTests). Envelope: requests with errorEnvelope get success wrapped as {__detourPolyfillOk: true, value} (value omitted for nil, reads undefined) via ExtensionPolyfillHandler.replySuccess; unwrapPolyfillReply returns value, rejects the error envelope's text, and rejects any other shape with 'Malformed polyfill reply'. Page transport unchanged.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Worker polyfill replies are now unambiguous: on the errorEnvelope path a success is {__detourPolyfillOk: true, value: result} and a failure {__detourPolyfillError: text}; anything else rejects as 'Malformed polyfill reply'. A handler result carrying either key (e.g. notification ids in getAll) passes through intact. browser.runtime.lastError in a worker was measured to be the same object as chrome.runtime.lastError (same runtime object), so both already read the original text in the relay callback.

Tests: ExtensionPolyfillTests (unwrap cases incl. success values holding the error/ok keys, nil result, malformed replies; native half wraps success only when asked; fallback stub updated), ExtensionHistoryScopeTests (worker callback reads the same text via browser.runtime, identity asserted), ExtensionNotificationOrderingTests (getAll with ids equal to the envelope keys, page and worker). Runs: ExtensionPolyfillTests 197, ExtensionHistoryScopeTests 36, ExtensionPolyfillIntegrationTests 65 (13 skipped, env-gated), ExtensionPolyfillProfileWiringTests 26, ExtensionNotificationOrderingTests 21: 345 run, 0 failures.

/verify: seeded worker probe in an isolated DETOUR_DATA_DIR (guard script): idle.queryState resolved 'active', getAll {}, clear() rejected 'notificationId required', callback lastError 'notificationId required' under both chrome and browser, same object. Code review: 3 findings, 2 fixed (assert the identity measurement; fake stub uses the key constant), 1 skipped (rename the errorEnvelope flag: naming only). Behaviour note: a nil handler result on the worker path now always resolves undefined.
<!-- SECTION:FINAL_SUMMARY:END -->
