---
id: TASK-262
title: >-
  Extensions: polyfill error envelope edge cases (browser.runtime.lastError
  identity, envelope key collision)
status: To Do
assignee: []
created_date: '2026-11-03T22:39:00Z'
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
- [ ] #1 Whether browser.runtime.lastError and chrome.runtime.lastError are the same object in a worker is measured; if not, both read the original text
- [ ] #2 Success and failure replies cannot be confused (e.g. both wrapped), with JS-level and real-context tests
<!-- AC:END -->
