---
id: TASK-255
title: >-
  Extensions: native polyfill errors read differently from the worker and from a
  page
status: To Do
assignee: []
created_date: '2026-11-03T17:09:00Z'
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
- [ ] #1 A native polyfill error reaches promise rejections and runtime.lastError with the same message text from the service worker and from an extension page, without the WebKit prefix
- [ ] #2 Tests in a real extension context compare the error text from both transports, in both forms
<!-- AC:END -->
