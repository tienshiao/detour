---
id: TASK-354
title: >-
  Verify skill: windows that are not browser windows are reachable through the
  automation endpoint
status: To Do
assignee:
  - '@tma'
created_date: '2026-11-16T05:37:00Z'
labels:
  - verification
  - automation
dependencies: []
references:
  - .claude/skills/verify/SKILL.md
  - wiki/playbooks/runtime-verification.md
  - wiki/features/automation-endpoint-windows.md
priority: low
type: chore
ordinal: 434000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in the wiki content lint. .claude/skills/verify/SKILL.md section 3 still says Settings and other windows that are not browser windows need screencapture -l; since TASK-228.7 the automation endpoint's window_id names Quick Detour, quarantine and Settings windows (Settings takes input only in test runs). The skill directory is write-protected for agents, so the edit is the user's. wiki/playbooks/runtime-verification.md already says it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 SKILL.md section 3 routes Settings, Quick Detour and quarantine windows through the endpoint, keeping screencapture -l only where the endpoint cannot reach
<!-- AC:END -->
