---
id: TASK-373
title: 'Tests: guard that a Quick Detour window still cannot show an extension page'
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T09:55:00Z'
labels:
  - extensions
  - quick-detour
  - tests
dependencies: []
references:
  - wiki/extensions/extension-pages.md
priority: low
type: chore
ordinal: 454000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13). TASK-352 established (WebKit source + a probe) that WebKit refuses a main-frame extension page unless the configuration's _requiredWebExtensionBaseURL names the extension, so Quick Detour windows never show one and extensionPageLocations need not walk them. The probe (session scratchpad task-352/QuickDetourExtensionPageProbeTests.swift) printed rather than asserted. A guard test would catch a WebKit change that relaxes the gate.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A test asserts a Quick Detour page refuses an extension page (and fails if WebKit ever loads it)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
The TASK-352 probe (prints, does not assert) is kept at docs/harness/task352/QuickDetourExtensionPageProbeTests.swift; copy it into DetourTests and turn its prints into assertions.
<!-- SECTION:NOTES:END -->
