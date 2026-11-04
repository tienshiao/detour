---
id: TASK-221
title: 'Verification: re-take the light and dark screenshots for TASK-202 and TASK-209'
status: To Do
assignee: []
created_date: '2026-10-27 22:21'
labels:
  - verification
dependencies: []
references:
  - docs/harness/task202-harness.patch
  - docs/harness/task209-harness.patch
priority: low
ordinal: 257000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Both runtime checks ran while the screen was locked, so they logged state instead of capturing pixels. TASK-202: the Content Blocking settings during and after Clear Cache & Redownload. TASK-209: palettes in two profiles with overlapping history (rows, icons, labels), from the main window, a Quick Detour and a Private window. Re-run the saved harnesses with the screen unlocked and look at the captures.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Light and dark captures for both tasks are looked at, and anything wrong is reported or filed
- [ ] #2 The results are added to TASK-202's and TASK-209's notes
<!-- AC:END -->
