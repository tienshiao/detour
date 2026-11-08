---
id: TASK-132.16
title: >-
  Extensions: chrome.debugger console and network events
  (Runtime.consoleAPICalled, Network.*)
status: Done
assignee:
  - '@claude'
created_date: 2026-10-03 23:09
updated_date: '2026-11-08T07:53:00Z'
labels: []
dependencies:
  - TASK-132.13
parent_task_id: TASK-132
priority: medium
ordinal: 148000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Back the extension's read_console_messages and read_network_requests tools. After Runtime.enable: Runtime.consoleAPICalled ({type, args, timestamp, stackTrace}) and Runtime.exceptionThrown. After Network.enable({maxPostDataSize}): Network.requestWillBeSent, responseReceived (status, headers, mimeType) and loadingFailed; Network.disable stops them. WKWebView has no network observation API, so this comes from page-world instrumentation (fetch / XHR wrappers, resource timing) installed at document start on attached tabs; document and subresource coverage will be partial and the limits must be written down.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 console.log / warn / error / info / debug on an attached tab produce consoleAPICalled with the level and by-value arguments; an uncaught error produces exceptionThrown
- [x] #2 Messages logged before the page's own scripts finish loading are captured after a navigation while attached
- [x] #3 fetch and XHR requests produce requestWillBeSent and responseReceived with method, URL and status, and a failed one produces loadingFailed
- [x] #4 No events are sent before enable or after disable / detach, and the page's console and fetch behave unchanged
- [x] #5 The instrumentation is not detectable as a different function identity by simple page checks (toString) where practical, and is absent from tabs that are not attached
- [x] #6 docs/extensions.md lists which request types are and are not reported
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Read how the Claude extension 1.0.105 consumes the events (its debugger event handler): consoleAPICalled type/args value|description/timestamp/first frame; exceptionThrown exceptionDetails; requestWillBeSent requestId/request.url/method/documentURL; responseReceived status; loadingFailed -> 503.
2. Spike in a standalone WKWebView: Proxy toString (prints ProxyObject -> use disguised methods + toString map), user-script stack frames, CustomEvent detail across worlds, resource timing responseStatus (absent), failed loads (no entry), _removeUserScript: (present).
3. Instrument on attach (V8 keeps and replays console storage): page-world wrappers (console, fetch, XHR, error/unhandledrejection) + DetourDebugger-world half (token-named event channel, 1,000-message buffer replayed on Runtime.enable, resource timing, element errors, batched posts to a world-only handler). Remove on detach and restore the current document's originals. Skip extension-page tabs (shared controller).
4. Network domain: enable/disable with Chrome's parameter checks; page reports -> requestWillBeSent/responseReceived/loadingFailed/loadingFinished; main document natively from the navigation callbacks under its loader id.
5. Share the V8 describer with Runtime.evaluate (describerSource) and the V8 error description helper.
6. Tests: ExtensionDebuggerEventsTests (worker + page) and ExtensionDebuggerEventsUnitTests; regression suites for the debugger and polyfill.
7. API Explorer controls; docs/extensions.md (what is and is not reported); wiki debugger-api.md; runtime check with a harness.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Review (/code-review --fix): 10 findings, 8 fixed (instrumentation follows a replaced web view; document request kept to commit or failure, loadingFinished at DOMContentLoaded; oversized bodies left out rather than cut; back/forward-cache documents re-handshake or clean up; request-id leaks; browser-error: loads skipped; Network.enable error tests from an extension context, woken-tab and bfcache tests). Skipped: a page that tampered with dispatchEvent before the attach can learn the token in the attach-time document (it can already fake console output; a real fix needs another hand-off), and the duplicated integer helper across domain files.
AC #5 note: wrappers keep the originals' name/length and print as native code; still detectable via a user-script:N frame in a stack taken inside a wrapper and Function.prototype.toString's own frame when it throws — documented as the practical limit.
Tests: ExtensionDebuggerEventsTests + ExtensionDebuggerEventsUnitTests 16/16; with ExtensionDebugger{,Unit,Input,InputUnit,Runtime,RuntimeExtension,RuntimeUnit}Tests, WebKitDelegateReachabilityTests, ExtensionPolyfillTests, BrowserTabWakeTests, NavigationFailureURLTests: 334/334. Full suite not run.
Runtime (/verify, docs/harness/task132.16-harness.patch, isolated profile DetourVerify13216-1, local site): parked tab from the page context and selected tab from the worker; reload while attached then Runtime.enable replayed the early log and warning with the page as caller; console, uncaught TypeError with V8 stack, fetch 200 / POST 501 (python's server) / failure, XHR 200 + loadingFinished, the document under its loader id (200 + loadingFinished), pixel.gif finished and the unreachable image failed; the worker got the selected tab's events; the unattached tab stayed unwrapped; detach restored console/fetch, left 0 scripts and 0 installs, and no events followed. Window screenshots failed ('could not create image from window', as in 132.15), so nothing visual was checked — the change has no UI. Not checked: the real Claude extension (TASK-132.20).

Correction (2026-11-07): the screenshot failures were not a capture problem. The wait loop read the padded log line '[  16.129] SHOOT <name> <win>' with 'read -r _ _ name win', so screencapture -l got '<name> <win>' as the window id. With the last two fields taken, both captures succeed (window on screen, sharing allowed); a rerun of the harness (DetourVerify13216-2) captured the selected tab's window after detach, normal. The harness patch header now says how to parse SHOOT lines.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
chrome.debugger now reports Runtime.consoleAPICalled / exceptionThrown / exceptionRevoked and Network.requestWillBeSent / responseReceived / loadingFailed / loadingFinished for an attached tab, behind the Claude extension's read_console_messages and read_network_requests. WebKit offers neither, so an attached tab (and only it) is instrumented for the session: page-world wrappers for console, fetch and XHR disguised as native code, and a DetourDebugger-world half that buffers console messages (replayed on Runtime.enable, as V8 does), reads resource timing and element load errors, and posts over a world-only handler through a per-session token-named event; removed on detach with the originals restored. The main document's request is native, under its loader id, with its HTTP status. Network.enable/disable with Chrome's parameter checks; Runtime.discardConsoleEntries. Limits, listed in docs/extensions.md: main frame only, subresources from resource timing have no status (WebKit has no responseStatus), no bodies, no redirects, nothing from before the attach, extension-page tabs not instrumented. The V8 describer is now shared with Runtime.evaluate. API Explorer has the controls; wiki debugger-api.md has the design, the WebKit measurements and the rejected alternatives. Tests 334/334 across the debugger, polyfill and nearby suites; runtime check clean except screenshots. Follow-up still open: TASK-132.20 (real Claude extension).
<!-- SECTION:FINAL_SUMMARY:END -->
