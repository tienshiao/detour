---
type: Concept
title: Polyfill errors and runtime.lastError
description: How a polyfilled API's callback form sets runtime.lastError on WebKit's runtime, and how a native polyfill error reaches the extension verbatim from a page and a worker despite WebKit's rewrite of sendNativeMessage errors.
tags: [extensions, polyfill, errors, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:04Z }
sources:
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift
  - id: task-23
    resource: backlog:TASK-23
    title: Callback-form polyfill APIs must route rejections to runtime.lastError
  - id: task-138
    resource: backlog:TASK-138
    title: chrome.history.search returns history from every profile
  - id: task-255
    resource: backlog:TASK-255
    title: "Extensions: native polyfill errors read differently from the worker and from a page"
  - id: task-262
    resource: backlog:TASK-262
    title: "Extensions: polyfill error envelope edge cases (browser.runtime.lastError identity, envelope key collision)"
  - id: polyfill-tests
    resource: ../../DetourTests/ExtensionPolyfillTests.swift
    title: ExtensionPolyfillTests
  - id: history-scope-tests
    resource: ../../DetourTests/ExtensionHistoryScopeTests.swift
    title: ExtensionHistoryScopeTests
---
A polyfilled API that fails has to look to the extension as it would in
Chrome: a rejection with the native text in the promise form, and
`runtime.lastError` with the same text in the callback form. WebKit's runtime
makes both harder than they look, from a page and from a worker alike.

# Callback form and runtime.lastError

Every promise-backed polyfill API takes an optional trailing callback and
routes through `__detourSettle`. With no callback the promise is returned
untouched. With one, a rejection must run the callback with no arguments while
`chrome.runtime.lastError` is `{ message }`, as Chrome does. How that is
achieved depends on the runtime object (`__detourCallbackLastError.lastMode`):

| Mode | When | What happens |
|---|---|---|
| `js` | `lastError` can be redefined, verified by reading it back | A getter is installed for the callback and the original restored; an unread error is reported as `Unchecked runtime.lastError: …` |
| `native-relay` | WebKit's real runtime | The message is bounced off Detour through the callback form of `runtime.sendNativeMessage` with type `runtime.lastErrorRelay`. The native side always fails with that text, so WebKit runs the callback inside its own `lastError` scope; the relay's callback first puts the original text back on WebKit's `lastError` object ([the callback form](#error-text-from-both-transports), below) |
| `console` | Neither is possible | The callback runs without `lastError`; the message goes to `console.error` |

WebKit's `runtime.lastError` reports as a configurable data property, yet
`defineProperty`, assignment and `delete` all complete without effect and reads
stay `null`. A "configurable" check is therefore not enough; the write has to
be read back.[^task-23]

An exception thrown by the callback is rethrown on a fresh task, so it is an
uncaught error rather than an unhandled rejection.

# Error text from both transports

WebKit rewrites every error that crosses `runtime.sendNativeMessage`
(`toErrorString` in WebKit's `WebExtensionUtilities.cpp`): it trims dots from
both ends of the text, capitalises the first letter, and makes it
`Invalid call to runtime.sendNativeMessage(). <Text>.` Before TASK-255 the
extension saw that rewrite on three of the four legs. Measured with
`history.search` refused for want of the permission (native text
`history permission not declared`):[^task-138]

| Caller | Form | Text before TASK-255 |
|---|---|---|
| Extension page | promise | `history permission not declared` |
| Extension page | callback | `Invalid call to runtime.sendNativeMessage(). History permission not declared.` |
| Worker | promise | `Invalid call to runtime.sendNativeMessage(). History permission not declared.` |
| Worker | callback | `Invalid call to runtime.sendNativeMessage(). Invalid call to runtime.sendNativeMessage(). History permission not declared.` |

Now every leg reads `history permission not declared`, the handler's text
verbatim:[^task-255]

- **Worker requests** set `errorEnvelope: true`. `handleNativeMessage` then
  answers a failure as a *successful* reply
  `{ __detourPolyfillError: <text> }` (`ExtensionPolyfillHandler.errorEnvelopeKey`),
  and `__detourPolyfillRequest` rejects with that text. Stripping the prefix
  alone would not do: the capital letter and the trimmed dots cannot be undone.
  The relay ignores the flag, since it must fail for WebKit to set `lastError`.
- **A success on the envelope path is wrapped too**, as
  `{ __detourPolyfillOk: true, value: <result> }` (`successEnvelopeKey`,
  `replySuccess`; `value` is left out for a nil result, which reads as
  `undefined`). Otherwise a handler result that is a map with the error key
  (notification ids are the extension's own keys in `notifications.getAll`)
  would be read as a failure. The polyfill rejects a reply in neither shape
  with `Malformed polyfill reply`, so a test stub of the worker's
  `sendNativeMessage` must answer with the success envelope.[^task-262]
  The delegate's own refusals before the handler (`Unrecognized extension
  context`, `No polyfill handler for profile`) use the same
  `ExtensionPolyfillHandler.replyFailure`.
- **An error WebKit still delivers as one** (a non-object payload, WebKit's
  own limits such as too many active native message requests) loses exactly
  `Invalid call to runtime.sendNativeMessage(). ` and the full stop WebKit
  appended. Any other text is left as it is. The capital stays.
- **The callback form**: WebKit's `lastError` is a JS `Error` made per report
  (`makeErrorValue` in `WebExtensionAPIRuntime.cpp`) whose `message` is an own,
  configurable property. Inside the relay's callback the polyfill reads it and
  redefines `message` as the original text, then runs the extension's
  callback. In a worker `browser.runtime` is the same object as
  `chrome.runtime`, and both hand back the same `lastError` object, so
  `browser.runtime.lastError.message` reads the original text as well
  (measured in the test host, TASK-262). Reading `lastError` marks it checked for WebKit, so **in
  `native-relay` mode nothing reports an unchecked `lastError` any more**.
  Reporting it from the polyfill, keyed on reads of `message`, was tried and
  rejected: no read of WebKit's native getter can be observed, so a callback
  that handles the error with `if (chrome.runtime.lastError) return;` would be
  reported as unchecked. A false report on correct code was judged worse than
  no report on code that ignores the error; the handler still logs every
  failure on the Swift side.

Real `runtime.sendNativeMessage` and `connectNative` calls to native hosts do
not go through `__detourPolyfillRequest` and keep WebKit's text.

# Tests

| Suite | Proves |
|---|---|
| [ExtensionPolyfillTests](../../DetourTests/ExtensionPolyfillTests.swift) | The three modes, the relay's reply, the original text without WebKit's prefix, no unchecked report for a relayed error, a rethrown callback exception, the envelope and when a worker request asks for it |
| [ExtensionHistoryScopeTests](../../DetourTests/ExtensionHistoryScopeTests.swift) | One native error read the same from both transports in both forms, through the production wiring (`testANativeErrorReadsTheSameFromBothTransportsInBothForms`) |
| [ExtensionPolyfillProfileWiringTests](../../DetourTests/ExtensionPolyfillProfileWiringTests.swift) | `lastError` in a real extension page and a real worker (`offscreen.createDocument`) |

# Related

- [Chrome runtime patching](./chrome-runtime-patching.md#members-that-cannot-be-patched-at-all) — why `runtime.lastError` cannot be redefined, and what can be.
- [Native messaging](./native-messaging.md) — real native hosts, whose errors keep WebKit's text.
- [Polyfill layer](./polyfill-layer.md) — `__detourSettle` and `__detourPolyfillRequest` in the preamble.

[^task-23]: Callback-form polyfill APIs must route rejections to runtime.lastError
[^task-138]: chrome.history.search returns history from every profile
[^task-255]: Extensions: native polyfill errors read differently from the worker and from a page
[^task-262]: Extensions: polyfill error envelope edge cases (browser.runtime.lastError identity, envelope key collision)
