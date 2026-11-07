---
id: TASK-282
title: >-
  Native messaging: manifest refusal edge cases (directory path, log volume,
  allowed_origins matching)
status: To Do
assignee: []
created_date: '2026-11-07T09:35:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - DetourTests/NativeHostManifestValidationTests.swift
  - wiki/extensions/native-messaging.md
priority: low
type: bug
ordinal: 329000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from the TASK-264..277 review-fix batch (2026-11-06/07). Found while doing TASK-266 and TASK-275.

- A manifest whose `path` is a directory passes the executable check and fails only at `run()`, with a raw POSIX error instead of `hostNotFound`. Rejecting it earlier means the spawn-failure test in TASK-275 needs another way to make `run()` fail.
- Each refused connect writes an error-level log line on every attempt, and one-shot `sendNativeMessage` has no rate limit, so a retrying extension can flood the log.
- `allowed_origins` entries are compared as exact strings. Check how Chrome parses and compares them (trailing slash, case) and match it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A manifest whose path is a directory is refused before spawning, with Chrome's host-not-found error, and the spawn-failure test still exercises a failing run()
- [ ] #2 Repeated refusals for the same extension and host do not write an error line per attempt
- [ ] #3 allowed_origins matching follows Chrome's rules, recorded in the wiki, with tests for the cases that differ from exact string comparison (if any)
<!-- AC:END -->
