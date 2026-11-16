---
id: TASK-365
title: >-
  Tests: flaky in full runs — native pop-up menu click, Quick Detour profile
  switch, site search chip icon, Settings row skip
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T22:01:00Z'
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
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13). Each passes alone. (1) AutomationInputTests.testANativeButtonTakesTheClickAndANativeMenuCanBeChosenFrom failed once in a 12-suite run ('the earlier menu closed before this', no_open_menu). (2) QuickDetourProfileSwitchWindowTests.testSwitchingReloadsTheAddressUnderTheOtherProfilesCookies failed in the 4831-test full run ('the old web view is released'). (3) SiteSearchChipColorTests.testTheChipStartsInTheSpacesColorAndTakesTheSitesIcon failed in the full run (icon URL requested twice). (4) AutomationWindowKindsTests.testARowOfASettingsListSelectsForATestRunsClick skips in combined runs when the host comes to the front. (5) SpaceJumpTests.testAddReorderAndDeleteChangeWhatAShortcutOpensWithNoMenuRebuild failed once on 2026-11-16 while a group ran under load (TASK-375's notes).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each flake's cause is found and fixed, or the test is made order-independent
- [x] #2 A full run passes them
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce each in combined runs of its alphabetical neighbours (Automation*, QuickDetour*, Sidebar*/Site*/Space*, TASK-375's shortcut/automation group), with temporary logging of activation, menu tracking, fetch callers and wait times.
2. #1 native menu: the click tool's closeAll returns on didEndTracking while the closed menu's tracking loop (and the press that opened it) has not unwound; fix in AutomationMenuTracker.closeAll (also wait for the opening press to return).
3. #4 Settings row skip: the host is brought to the front by a Settings window (showWindow activates); a test helper hands activation away before the background-only tests instead of skipping.
4. #2 web view release: await the release (waitUntil) instead of spinning a nested run loop inside the async test.
5. #3 chip icon: two callers (history row cell, chip) share FaviconLoader; assert on the URL set, not the count.
6. #5 SpaceJump: argue from the code; timing-only fix if nothing else is found.
7. Wiki traps, Backlog notes, commit on lane-b.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
PAUSED 2026-11-16 (lead asked; user needs the machine). Uncommitted work in lane-b, debug code already removed.
Reproduction so far (combined runs of alphabetical neighbours, temporary logging):
- #1 native menu: REPRODUCED once in an Automation* group run (second menu began 26 ms after the first ended and ended 0.41 s later; no_open_menu). Cause: closeAll returned on didEndTracking while the first press's body (popUpContextMenu) had not returned; the click went on inside that loop. Fix: AutomationInput.bodiesRunning + closeAll also waits for it (1 s cap). New test testASecondRightClickOpensItsMenuWhileTheFirstStillUnwinds (slows unwinding with a didEnd observer): fails without the fix (bodiesRunning 2), passes with it.
- New flake seen in the first Automation group run: AutomationInputTests.testASwitchTogglesAndAPopUpOpensItsMenu (pop-up click completed, menu_open false). Not reproduced in 3 more group runs or 15 isolated loops; not explained.
- New flake seen once: AutomationPageTests.testEvaluateTimesOutAndRefusesBadArguments (script_error instead of timeout). Not investigated (out of scope).
- #4 Settings row skip: REPRODUCED in 3 of 3 Automation group runs. The host becomes active when a Settings window is shown (SettingsWindowController.showWindow calls NSApp.activate(ignoringOtherApps:)), e.g. in AutomationStagingTests.testASettingsPaneOpensWithARowSelected, and stays active. NSApp.deactivate() alone did not deactivate it. Fix: moveTestHostToBackground() in ExtensionTestSupport.swift (yieldActivation to the app behind / Finder + activate(from:) + deactivate); used in the Settings row test and the five background-only AutomationInputTests. Verified: group run 223 tests, 0 failures, 0 skipped, ResignActive logged in the test.
- #2 Quick Detour web view release: not reproduced (QuickDetour* 273 tests pass; released within the old spin). Changed the 2 s nested-run-loop spin in an async test to an awaited waitUntil (10 s).
- #3 chip icon twice: not reproduced (Sidebar*/Site*/Space* 298 pass). Stack logging showed two callers of FaviconLoader for the same URL (the history row cell and loadSiteColor); one fetch only because the second hits the cache, so an NSCache eviction gives two. Assert changed to the URL set.
- #5 SpaceJump: not reproduced (TASK-375 group, 248 tests pass); waits measured 0.08-0.17 s; spin default widened 2 to 10 s.
Left: run AutomationInputTests, AutomationWindowKindsTests, SiteSearchChipColorTests, QuickDetourProfileSwitchWindowTests, SpaceJumpTests once more after the cleanup; code-review; wiki (build-and-test traps: host comes to the front via Settings; webkit/test-host page or automation page: closeAll vs unwinding); Backlog notes/ACs; commit.

Resumed 2026-11-16 after the pause.
Two more flakes seen once each, NOT reproduced, not explained (left in this task): (6) AutomationInputTests.testASwitchTogglesAndAPopUpOpensItsMenu — in the first Automation* group run the pop-up click answered completed:true, menu_open:false (no menu; list/choose then no_open_menu); not seen in three more group runs or a 15-iteration isolated loop of pop-up and double right clicks. (7) AutomationPageTests.testEvaluateTimesOutAndRefusesBadArguments — once got script_error instead of timeout in a group run; not investigated (out of scope).
Reproduction summary: #1 reproduced 1 of 4 Automation* group runs; #4 reproduced 4 of 4 (the host was activated by a Settings window: AutomationStagingTests.testASettingsPaneOpensWithARowSelected, or the test's own showPane); #2 not reproduced (QuickDetour* 273 tests); #3 not reproduced (Sidebar*/Site*/Space* 298 tests; the two FaviconLoader callers found by stack logging); #5 not reproduced (TASK-375 group, 248 tests; waits 0.08–0.17 s).
Code review (medium --fix, on the uncommitted diff): 7 findings, 3 fixed. Fixed: closeAll waited on every running body and returned at once when the menu had already ended — now AutomationMenuTracker records pressDepth (bodies running when a menu opened by the endpoint's synthetic press begins tracking) and closeAll waits, also with no menu open, until fewer bodies run, clearing it after its 1 s cap (a body around the menu, such as an alert, is not waited for); moveTestHostToBackground picks only a regular app behind the host (an accessory's layer-0 window could not take activation); a redundant assert removed. Left: the new test's process-global bodiesRunning==1 assert (intentional), raw addObserver(queue:nil) in the test (must run synchronously inside the tracking loop), SpaceJump's widened wait (its failing line is not recorded, so the cause cannot be confirmed).
Tests after the review: AutomationInputTests, AutomationWindowKindsTests, AutomationToolsTests, AutomationPrivateAccessTests, SiteSearchChipColorTests, QuickDetourProfileSwitchWindowTests, SpaceJumpTests: 93 tests, 0 failures, 0 skipped. Before it: the five task suites plus SiteColorTests/SiteFaviconURLTests: 76 tests, 0 failures. Automation* group with the activation helper: 223 tests, 0 failures, 0 skipped (the Settings row test ran, the host left the front inside it).
No /verify: test-only changes apart from the endpoint's closeAll wait, which the new test and the Automation suites exercise in the test host. Not verified: a full run (AC #2, the lead's).
Chosen by Claude (not yet confirmed by the user): moveTestHostToBackground hands activation to the regular app whose window is frontmost behind the test host, else the Finder; alternative: leave the host active and keep skipping.

Full run on main 3223cd7d (2026-11-16): 4931 tests, 24 skipped, 2 failures, neither one of this task's tests (WindowCloseReleaseTests split freed = TASK-344, and a new PageOpenedWindowTests opener timeout, filed separately); both passed alone right after (32/0). All of this task's tests passed in the full run, including the Settings row test (not skipped).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Five full-run flakes looked at in combined runs of their neighbours. The native-menu click (#1, reproduced once) was the endpoint itself: AutomationMenuTracker.closeAll returned on didEndTrackingNotification while the closed menu's loop and the press that opened it were still unwinding, so the next click opened its menu inside that loop and it closed itself; closeAll now also waits for that press to return (pressDepth over AutomationInput.bodiesRunning), pinned by a test that slows the unwinding. The Settings-row skip (#4, reproduced every time) was the test host brought to the front by a Settings window; moveTestHostToBackground() hands activation back before the background-only tests. Not reproduced, fixed from the code: the Quick Detour web view release (awaited instead of a nested run loop in an async test), the chip icon count (two FaviconLoader callers, assert on the URL set), SpaceJump (wait widened to 10 s). Two more one-off flakes recorded, not reproduced. 93 + 76 + 223 tests pass; AC #2 needs the lead's full run.
<!-- SECTION:FINAL_SUMMARY:END -->
