---
id: TASK-249
title: >-
  Tests: test runs post real notifications into the developer's Notification
  Center
status: To Do
assignee: []
created_date: '2026-11-03T16:33:00Z'
labels:
  - tests
  - extensions
dependencies: []
references:
  - DetourTests/ExtensionNotificationManagerTests.swift
priority: low
type: chore
ordinal: 293000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-238. The test host shares the app bundle id, and suites such as ExtensionPolyfillTests drive notifications.create through ExtensionNotificationManager.shared, so every run delivers real banners on the development machine (their v2 identifiers showed up in a later runtime check). Tests should use a fake ExtensionNotificationCenter (HeldNotificationCenter exists in ExtensionNotificationManagerTests).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 No test posts to the real UNUserNotificationCenter: notification-creating tests use a fake center, or a test-host-wide default does
- [ ] #2 The affected suites pass, and a full run leaves no new Detour notifications in Notification Center
<!-- AC:END -->
