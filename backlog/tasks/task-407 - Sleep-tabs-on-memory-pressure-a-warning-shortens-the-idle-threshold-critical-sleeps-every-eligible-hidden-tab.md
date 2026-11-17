---
id: TASK-407
title: >-
  Sleep tabs on memory pressure: a warning shortens the idle threshold, critical
  sleeps every eligible hidden tab
status: To Do
assignee: []
created_date: '2026-11-17T20:35:00Z'
labels:
  - sleeping
  - memory
  - gpu
dependencies: []
priority: medium
type: feature
ordinal: 488000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Detour does not react to macOS memory pressure at all. The only release paths are the profile's idle threshold (1 h default) and the TASK-104 show budget. A survey on 2026-11-17 of six open-source WebKit browsers (Search, Zigzag, Nook, Lilo, Zephium, Ora) found that all but Ora react to pressure, usually through DispatchSource.makeMemoryPressureSource:
- Search: a warning shortens the idle wait to 5 min, critical to 0.
- Zigzag: either level shortens it to 5 min for 2 min after the event; rescans at most once per 30 s; favourites sleep only on critical, because the first warning is common in everyday use.
- Nook: a warning unloads one tab; critical unloads up to half of the eligible tabs, at most once per 30 s.
- Lilo and Zephium: cap the number of live web views.

Fewer live web processes also means fewer per-connection IOSurface pools in the GPU process, so this helps with the TASK-104/403 limit as a side effect. The user decides the exact rule (thresholds, whether pinned/favourite tabs are included, at which level); the survey's numbers are starting points, not the decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A memory-pressure source drives sleeping; warning and critical levels are handled distinctly, per a rule the user has confirmed
- [ ] #2 The existing never-sleep guards still apply: the selected/hosted tab, audible or capturing tabs, split partners, and a profile set to never sleep
- [ ] #3 A burst of pressure events cannot cause repeated full sweeps (rate-limited), and sleeps do not stall the main thread
- [ ] #4 Policy tests in the existing sleep suites cover both levels, the guards and the rate limit, with an injected clock and a fake pressure source
- [ ] #5 Each pressure-driven sleep is logged at notice so a run can be reviewed
<!-- AC:END -->
