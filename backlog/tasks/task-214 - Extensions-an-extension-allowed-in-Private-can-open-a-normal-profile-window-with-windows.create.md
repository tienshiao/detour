---
id: TASK-214
title: >-
  Extensions: an extension allowed in Private can open a normal-profile window
  with windows.create
status: To Do
assignee: []
created_date: '2026-10-27 22:21'
labels:
  - extensions
  - security
  - private
dependencies: []
references:
  - Detour/Extensions/Runtime
priority: high
ordinal: 250000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the second high review of TASK-194 (Quarantine). An extension that is allowed to run in Private (and so also in quarantine windows) can call windows.create without incognito: true. That opens a normal window on the default profile, with the profile's cookies and history, at any URL the extension passes, including the address of the Private or quarantine page it is running in. This predates Quarantine and affects Private windows too.

Decide the rule (for example: a call from a Private/quarantine context opens a Private window unless the extension also has normal-profile access, matching Chrome's split/spanning incognito modes) and enforce it in the native windows.create handler.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A windows.create call from an extension context running in a Private window or a quarantine window cannot open a window on a normal profile unless the decided rule allows it
- [ ] #2 Calls from a normal-profile context behave as today
- [ ] #3 Tests in a real extension context (ExtensionPolyfillIntegrationTests style) cover both transports, both the promise and callback lastError forms, Private and quarantine sources, and a normal-profile source
- [ ] #4 The API Explorer extension and the extensions wiki describe the rule
<!-- AC:END -->
