---
id: TASK-239
title: >-
  Extensions: the notifications API is available without the notifications
  permission
status: To Do
assignee: []
created_date: '2026-11-03T07:58:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: medium
type: bug
ordinal: 283000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-234 (pre-existing). The native notifications handlers do no permission check, so an extension that does not declare "notifications" can still create, update, clear and list system notifications through the polyfill. Chrome exposes chrome.notifications only to extensions with the permission. CLAUDE.md requires permission work to carry positive and negative tests.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An extension without the notifications permission gets no chrome.notifications / browser.notifications API, and native requests from it are refused
- [ ] #2 An extension with the permission keeps working unchanged
- [ ] #3 Positive and negative tests in a real extension context, from both the service worker and an extension page; JS-level tests where the polyfill gates the namespace
- [ ] #4 The API Explorer extension still declares and exercises the permission
<!-- AC:END -->
