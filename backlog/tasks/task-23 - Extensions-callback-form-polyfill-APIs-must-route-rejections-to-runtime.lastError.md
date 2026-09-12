---
id: TASK-23
title: >-
  Extensions: callback-form polyfill APIs must route rejections to
  runtime.lastError
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 19:07'
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
- [ ] #1 A callback-style call whose native reply is an error invokes the callback with runtime.lastError set to the error message and clears it afterwards; no unhandled rejection is logged
- [ ] #2 The promise form is unchanged and still rejects
- [ ] #3 ExtensionPolyfillTests cover the callback path for at least offscreen.createDocument and one other wrapper, with positive and negative cases
<!-- AC:END -->
