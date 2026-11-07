---
id: TASK-272
title: >-
  Extensions: notification entries outlive the banner when macOS takes it away
  without a dismiss
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - notifications
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 319000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`ExtensionNotificationManager.handleResponse` (~765-767) keeps the entry after a click, although macOS removes the banner. For an extension that uses create(null, ...) and never calls clear, `entries` grows for the whole session, `getAll` reports notifications that are no longer shown, and a later `update` brings the banner back. Not yet checked: whether Notification Center's "Clear All" reports a dismiss action.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After a click removes a banner, getAll no longer lists it and update of its id answers false (or the Chrome behaviour, recorded)
- [ ] #2 The task records what Clear All reports, measured in the running app
- [ ] #3 entries cannot grow without bound for an extension that never calls clear
- [ ] #4 Tests cover the click case
<!-- AC:END -->
