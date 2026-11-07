---
id: TASK-281
title: >-
  Native messaging: a broken host manifest in Chrome's or Chromium's folder
  hides a valid one in Detour's own folder
status: To Do
assignee: []
created_date: '2026-11-07T09:35:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - wiki/extensions/native-messaging.md
priority: low
type: task
ordinal: 328000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from the TASK-264..277 review-fix batch (2026-11-06/07). Found while doing TASK-266.

Manifests are searched in Chrome's, Chromium's, Detour's, then /Library's folder, and since TASK-266 the first manifest file found decides (Chrome's rule): a file there that fails validation is a refusal, not a reason to keep looking. Chrome only searches its own folder, so the rule never makes one vendor's broken file hide another's; in Detour it does. A user who installs a host for Detour but has a stale or broken Chrome manifest for the same name gets a refusal. Decide whether Detour's own folder is searched first, or whether a refusal from another browser's folder falls through.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The search order and the first-file-decides rule are a deliberate choice, recorded with its reason in the native-messaging wiki page
- [ ] #2 If the behaviour changes: a valid manifest in Detour's folder is used when Chrome's folder holds a broken one for the same host name, with a test
- [ ] #3 1Password's real host manifest still connects (signed build, or recorded as owed)
<!-- AC:END -->
