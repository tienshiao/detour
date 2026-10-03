---
id: TASK-132.16
title: >-
  Extensions: chrome.debugger console and network events
  (Runtime.consoleAPICalled, Network.*)
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
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
- [ ] #1 console.log / warn / error / info / debug on an attached tab produce consoleAPICalled with the level and by-value arguments; an uncaught error produces exceptionThrown
- [ ] #2 Messages logged before the page's own scripts finish loading are captured after a navigation while attached
- [ ] #3 fetch and XHR requests produce requestWillBeSent and responseReceived with method, URL and status, and a failed one produces loadingFailed
- [ ] #4 No events are sent before enable or after disable / detach, and the page's console and fetch behave unchanged
- [ ] #5 The instrumentation is not detectable as a different function identity by simple page checks (toString) where practical, and is absent from tabs that are not attached
- [ ] #6 docs/extensions.md lists which request types are and are not reported
<!-- AC:END -->
