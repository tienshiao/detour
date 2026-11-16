---
id: TASK-364
title: 'Automation: select_tab then Cmd+W closed a different tab once (investigate)'
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - automation
  - tabs
dependencies: []
references:
  - wiki/features/automation-endpoint-tools.md
priority: low
type: bug
ordinal: 445000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-228.12's runtime check: `select_tab` on "beta" followed by Cmd+W closed "gamma". The select_tab output was discarded, so whether it selected "beta" is unknown. Could be a wrong-tab close after an endpoint selection, or select_tab not selecting.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Reproduced or ruled out with a recorded script
- [ ] #2 If real: Cmd+W after select_tab closes the selected tab, with a test
<!-- AC:END -->
