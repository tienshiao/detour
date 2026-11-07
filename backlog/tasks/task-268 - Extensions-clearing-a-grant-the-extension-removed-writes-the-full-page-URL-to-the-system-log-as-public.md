---
id: TASK-268
title: >-
  Extensions: clearing a grant the extension removed writes the full page URL to
  the system log as public
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - privacy
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionManager.swift
priority: low
type: bug
ordinal: 315000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`ExtensionManager.clearRemovedGrants` (ExtensionManager.swift ~2238) logs `\(key, privacy: .public)` for every revoked record. For `.url` records the key is the page's full `absoluteString` from the site-access prompt (path and query included, which can carry tokens), so browsing data lands in the unified log readable by anyone with `log show`. The codebase's rule elsewhere is that schemes are public and hosts are not (e.g. `logRejectedOrigin`).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 No log line in the permission-decision paths prints a .url or match-pattern key with public privacy
- [ ] #2 The line still says which extension and which record type was cleared
<!-- AC:END -->
