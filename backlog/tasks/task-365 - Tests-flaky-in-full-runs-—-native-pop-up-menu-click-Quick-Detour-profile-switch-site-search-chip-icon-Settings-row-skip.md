---
id: TASK-365
title: >-
  Tests: flaky in full runs — native pop-up menu click, Quick Detour profile
  switch, site search chip icon, Settings row skip
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - tests
  - flaky
dependencies: []
references:
  - wiki/playbooks/build-and-test.md
priority: low
type: chore
ordinal: 446000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13). Each passes alone. (1) AutomationInputTests.testANativeButtonTakesTheClickAndANativeMenuCanBeChosenFrom failed once in a 12-suite run ('the earlier menu closed before this', no_open_menu). (2) QuickDetourProfileSwitchWindowTests.testSwitchingReloadsTheAddressUnderTheOtherProfilesCookies failed in the 4831-test full run ('the old web view is released'). (3) SiteSearchChipColorTests.testTheChipStartsInTheSpacesColorAndTakesTheSitesIcon failed in the full run (icon URL requested twice). (4) AutomationWindowKindsTests.testARowOfASettingsListSelectsForATestRunsClick skips in combined runs when the host comes to the front.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each flake's cause is found and fixed, or the test is made order-independent
- [ ] #2 A full run passes them
<!-- AC:END -->
