---
id: TASK-359
title: >-
  Content blocking: an open Quick Detour window keeps the rule lists it was
  created with
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
labels:
  - content-blocking
  - quick-detour
dependencies: []
references:
  - wiki/features/content-blocking-per-site-switch.md
  - wiki/features/content-blocking-chunks.md
priority: low
type: bug
ordinal: 440000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 while splitting wiki/features/content-blocking.md (read from the code, not run). A Quick Detour page gets its rule lists through Space.makeWebViewConfiguration(for:inSpace:), but QuickDetourWindowController does not observe .contentBlockerRulesDidChange, so a list refresh, Clear Cache & Redownload or a list switched on/off does not reach an open Quick Detour page; browser windows do re-apply. Also noted: urlhaus-filter grew from 9,605 rules (2026-10-04) to 102,775 (2026-10-26), about two thirds of the 150,000 per-list cap (chunking handles lists over it since TASK-145).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An open Quick Detour (and quarantine) page uses the new rule lists after a refresh, a Clear Cache or a list toggle, with a test
- [ ] #2 Each list's current rule count is re-measured and recorded in wiki/features/content-blocking-chunks.md
<!-- AC:END -->
