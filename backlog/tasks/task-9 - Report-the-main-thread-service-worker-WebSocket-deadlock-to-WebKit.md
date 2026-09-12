---
id: TASK-9
title: Report the main-thread service worker WebSocket deadlock to WebKit
status: To Do
assignee: []
created_date: '2026-09-12 02:09'
labels:
  - webkit
  - upstream
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: low
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
File a bug at bugs.webkit.org for the deadlock found in TASK-2: an extension's background service worker runs on the content process main thread (WorkerMainRunLoop), and WebSocket::connect -> WorkerThreadableWebSocketChannel's constructor waits on a BinarySemaphore for the main thread to create the channel (Source/WebCore/Modules/websockets/WorkerThreadableWebSocketChannel.cpp, still present in main as of 2026-09-11). On a main-thread worker the wait never returns: the worker freezes, the process never processes WebKit's later page close, the SWServer never clears the registration, and every later wake reuses a registration with no worker. Include the sample stack from the 2026-09-11 plan doc, a minimal repro (WKWebExtension with a classic or module service worker whose script calls new WebSocket('wss://...') at startup; observe with sample that the WebContent main thread parks in __psynch_cvwait under WorkerThreadableWebSocketChannel), the WebKit version (WebContent 21624.5.1.11.3 on Darwin 25.6), and the related upstream change 4ce58a7ff7 (bug 322881) for context. Suggested fix direction for the report: ThreadableWebSocketChannel::create should use the document-style channel when the worker global scope runs on the main thread.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Bug filed on bugs.webkit.org with the repro extension attached and the sample stack; its URL is recorded in docs/1password-integration-plan.md and on this task
- [ ] #2 The repro extension lives under TestExtensions (or the plan doc points at the probe in scratch form) so the guard can be removed once a fixed WebKit ships
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Created 2026-09-11 after TASK-2. The Detour-side guard (ExtensionAPIPolyfill.webSocketGuardJS) stays until macOS ships the fix.
<!-- SECTION:NOTES:END -->
