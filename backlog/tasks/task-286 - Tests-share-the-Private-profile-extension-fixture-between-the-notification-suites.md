---
id: TASK-286
title: >-
  Tests: share the Private-profile extension fixture between the notification
  suites
status: To Do
assignee: []
created_date: '2026-11-07T09:35:00Z'
labels:
  - extensions
  - tests
dependencies: []
references:
  - DetourTests/ExtensionNotificationOrderingTests.swift
  - DetourTests/ExtensionNotificationEventTests.swift
priority: low
type: task
ordinal: 333000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from the TASK-264..277 review-fix batch (2026-11-06/07). Found while doing TASK-264.

The fixture that loads an extension into the Private profile now exists in both `ExtensionNotificationOrderingTests` and `ExtensionNotificationEventTests`. Two copies will drift, and the next Private-profile suite would add a third.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One Private-profile fixture in ExtensionTestSupport is used by both suites
- [ ] #2 Both suites pass with the same counts as before
<!-- AC:END -->
