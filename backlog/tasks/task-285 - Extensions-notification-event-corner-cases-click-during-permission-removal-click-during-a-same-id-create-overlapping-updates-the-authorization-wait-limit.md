---
id: TASK-285
title: >-
  Extensions: notification event corner cases (click during permission removal,
  click during a same-id create, overlapping updates, the authorization wait
  limit)
status: To Do
assignee: []
created_date: '2026-11-07T09:35:00Z'
labels:
  - extensions
  - notifications
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
  - wiki/extensions/polyfill-layer.md
priority: low
type: bug
ordinal: 332000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from the TASK-264..277 review-fix batch (2026-11-06/07). Gaps reported by TASK-270, TASK-271, TASK-272 and TASK-273; all existed before those tasks.

1. After `permissions.remove`, WebKit posts its removal notice to the main queue after it has made the change. A notification click handled in that window still reaches onClicked. No earlier hook was found (TASK-270).
2. A click on the old banner while a `create` for the same id is being added also ends the new notification. Dismissals already behaved this way (TASK-272).
3. An update skipped during the authorization wait answers true, even if the later update then fails and falls back past it (TASK-271).
4. An update merges into the options of an earlier update whose add is still in flight; if that earlier update fails, its fields can still appear through the later update that succeeds (TASK-271).
5. A superseded update waiting on authorization keeps its place in the 32-per-owner wait limit (TASK-273), so a progress-bar extension updating more than 32 times while the prompt is up gets refusals.

Each item may be fixed or kept with its reason recorded.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each of the five cases is either fixed with a test against the fake notification center, or kept with the reason recorded in the polyfill-layer wiki page
- [ ] #2 A click that arrives after the extension's notifications permission is removed does not reach onClicked, or the remaining window is documented as unavoidable with WebKit's hooks
<!-- AC:END -->
