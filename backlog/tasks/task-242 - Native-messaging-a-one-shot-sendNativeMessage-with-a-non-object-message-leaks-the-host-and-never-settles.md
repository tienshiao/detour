---
id: TASK-242
title: >-
  Native messaging: a one-shot sendNativeMessage with a non-object message leaks
  the host and never settles
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T17:45:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionManager.swift
priority: low
type: bug
ordinal: 286000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-233. In ExtensionManager, runtime.sendNativeMessage whose message is not a dictionary (a string, number, array or null) starts the host process but never writes to it; the request is never settled and the host is never released, so the process lives until Detour quits and the caller's promise hangs. Chrome sends any JSON-serialisable value. Whether Detour should send it or refuse it with an error is part of the task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A one-shot request with a non-object message either reaches the host (and its reply settles the request) or is refused with an error before any process is started; the choice is recorded
- [x] #2 No host process is left running in either case
- [x] #3 Tests cover a string, an array and null, from both the promise and the callback forms
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Chrome (extensions/common/api/runtime.json @ f0ba360: sendNativeMessage message is type object; argument_spec.cc rejects arrays, functions, null and primitives for OBJECT) refuses a non-object one-shot message at the signature check, before anything is sent. WebKit hands the delegate the JSON-parsed value (WebExtensionContextAPIRuntimeCocoa.mm runtimeSendNativeMessage: parseJSON FragmentsAllowed), and runtime.sendNativeMessage cannot be wrapped in JS, so Detour refuses in the delegate with an error before any host object exists.
2. Port.postMessage is type any in Chrome: a native port carries any JSON value both ways. Detour's port messageHandler dropped non-objects silently and the read loop dropped non-object replies. NativeMessagingHost.sendMessage/onMessage take any JSON value (fragments allowed, validated with isValidJSONObject so a bad value throws instead of raising).
3. Tests: one-shot string/number/array/null from promise and callback forms refused with no process (silent token host); port postMessage string/number/array/null round-trip through a token-carrying echo host, host gone after disconnect; framing test for a fragment's wire bytes.
4. Run Enforcement, Lifecycle, Framing, KeepAlive, ProfileWiring suites; /code-review --fix; /verify with fake hosts; wiki update.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (AC #1): refuse. Chrome declares sendNativeMessage's message `type: object` (extensions/common/api/runtime.json @ f0ba360) and argument_spec.cc's OBJECT check excludes arrays, functions, null and primitives, so Chrome throws 'No matching signature' before sending anything. Chrome does send any JSON value on a native port (Port.postMessage is `type: any`) and passes any JSON value back from the host. WebKit hands the delegate the JSON-parsed value faithfully (NSString / NSNumber / __NSCFBoolean / NSArray, measured), so serialization was not the obstacle; the one-shot is refused to match Chrome. Detour cannot throw synchronously (WebKit re-materializes runtime functions), so the refusal is a promise rejection / lastError: "Invalid call to runtime.sendNativeMessage(). The 'message' value is invalid, because an object is expected." It runs after the access gate (a non-object from an extension without the permission gets the permission error; Chrome would not expose the API at all), before any host object exists.

Port path had the same class of bug: port.messageHandler dropped non-objects without a word, and the read loop dropped non-object replies on both paths. NativeMessagingHost.sendMessage/onMessage now take any JSON value (fragments allowed); jsonBody(for:) validates with isValidJSONObject([value]) first so NaN/infinity/non-JSON types throw invalidMessage instead of raising an uncatchable ObjC exception. Object wire bytes unchanged. The port messageHandler ignores a call WebKit reports with an error (review fix).

WebKit itself throws for a JS null on port.postMessage and on sendNativeMessage's callback form ('The 'message' value is invalid, because an object is expected'); the promise form with null reaches the delegate with the host name as the message (argument shifting) and is refused there.

Verification. Tests: NativeMessagingEnforcementTests, NativeMessagingFramingTests, NativeMessagingHostLifecycleTests, NativeHostKeepAliveTests, ExtensionPolyfillProfileWiringTests: 127 run, 13 skipped (the TEST_RUNNER-gated measurement legs), 0 failures. New: enforcement (page) one-shot refusal for string/number/array/null x promise/callback with a .silent token host (0 processes, 0 pending), port round trip of string/number/array/boolean through the new .echoesCounted host (counted at 1 while open, 0 after disconnect; WebKit's null throw asserted), one-shot string and array replies settle; ProfileWiring worker test for the same from a service worker; framing tests for fragment JSON text, NaN/infinity/Date/non-string-key refusal, and a fragment echo round trip. /code-review (medium) --fix: fixed the port messageHandler writing null for a WebKit-reported error (now returns) and its indentation; added the worker-transport test it asked for; skipped reordering the shape check before the access gate (Chrome hides the API without the permission, so there is no Chrome order to match), the double graph walk in jsonBody (the guard is what prevents an uncatchable ObjC exception), and the per-iteration profile in the reply test (tearDown unloads every created profile). /verify: Debug build in an isolated DETOUR_DATA_DIR with a seeded MV3 worker extension and fake hosts: every non-object one-shot settled at once with the refusal (null callback thrown by WebKit), the silent host's token was seen 0 times across 25 s of sampling, the echo host echoed "hello", 42, [1,"two",null], true and {a:1} (log shows byte counts only), and its process was gone right after the page's disconnect; none left after quit. Data dir and the two window/split defaults keys removed. 1Password: it sends objects on ports and gets objects back; object bytes are unchanged and non-object values only flow where they used to be dropped, so no signed-build check is owed for this change.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A one-shot runtime.sendNativeMessage whose message is not an object is now refused with "The 'message' value is invalid, because an object is expected" before any host object exists, matching Chrome (runtime.json declares the message type object; argument_spec.cc rejects arrays, null and primitives). Before, the host was started, never written to, and the request and the process were left hanging. connectNative ports, and host replies on either path, now carry any JSON value as Chrome's Port.postMessage (any) does; they used to be dropped silently. NativeMessagingHost.sendMessage/onMessage take Any, with jsonBody(for:) validating before serializing. WebKit throws for a JS null on port.postMessage and the callback form itself. Tests from an extension page and a service worker; wiki native-messaging page updated.
<!-- SECTION:FINAL_SUMMARY:END -->
