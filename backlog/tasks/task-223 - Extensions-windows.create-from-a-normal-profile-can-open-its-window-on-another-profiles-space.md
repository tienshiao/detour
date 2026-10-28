---
id: TASK-223
title: >-
  Extensions: windows.create from a normal profile can open its window on
  another profile's space
status: Done
assignee:
  - '@claude'
created_date: '2026-10-28T07:56:00Z'
updated_date: '2026-10-28T15:15:00Z'
labels:
  - extensions
  - security
  - profiles
dependencies: []
references:
  - wiki/extensions/tab-and-window-bridge.md
  - TASK-214
  - TASK-132.23
priority: medium
ordinal: 259000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-214 (2026-10-28). openNewWindowUsing in ExtensionManager places a normal window with AppDelegate.assignDefaultSpace: the key normal window's space, else lastActiveSpaceID, else the first normal space. None of these looks at the calling extension's profile, so an extension enabled in profile A can open a window whose tabs load on a profile B space, with B's cookies, storage and history, and the window then belongs to B's extension contexts rather than A's. tabs.create does not have this problem: it adds the tab to the caller's own space (space(for:)). Open question for the user before work starts: where the window goes when the caller's profile has no space open in any window (its last active space, a new space on that profile, or refuse the call). TASK-132.23 (epic branch) proposes that windows.create yields a new space; the answer here should not contradict it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A windows.create call from a normal profile's extension context opens its window on a space of that same profile, from both transports, in the promise and callback forms
- [x] #2 The case where the caller's profile has no open space follows the user's recorded decision, with a test
- [x] #3 A test with two normal profiles fails before the fix (the window lands on the other profile's space) and passes after
- [x] #4 wiki/extensions/tab-and-window-bridge.md 'Opening a window' records the rule
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decision (user, 2026-10-28): when the caller's profile has no open space, the window goes to that profile's last active space.

1. Rule: a normal window from windows.create opens on the caller's profile's most recently used normal space: the first of TabStore.spaceUseOrder on that profile, else its first space in sidebar order. This is QuickDetour.mostRecentlyUsedSpace (TASK-193.3), exposed as TabStore.mostRecentlyUsedSpace(ofProfile:). The key window's space is always first in the use order, so when the front window shows the caller's profile nothing changes. When another profile is in front, the caller's most recently used space is picked whether or not a window shows it, which covers the 'no open space' decision without a separate rule.
2. A profile with no normal space at all: refuse with an error before any window opens. Today the window falls back to another profile's space.
3. Private windows (TASK-214 rule) are unchanged; they get their own space.
4. TDD in ExtensionWindowsCreatePrivateTests: another profile's window in front -> the caller's space (both transports x both forms); the caller's spaces all closed, its second space used last -> that space, not the first; a profile with no space -> refused, no window. Red first.
5. ExtensionManager.openNewWindowUsing: resolve the space before creating the window, setActiveSpace instead of AppDelegate.assignDefaultSpace.
6. API Explorer: no new API surface; the Create button already exercises it.
7. Wiki tab-and-window-bridge 'Opening a window', log line; review, verify, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Red (2026-10-28): the three new tests failed before the fix. With another profile in front, all 4 transport/form combinations opened on the front window's space. With the caller's spaces closed, the window opened on the front space, not the last active one. With no space, a window opened on the front space instead of an error. Green: ExtensionWindowsCreatePrivateTests 11/11.
Implementation: TabStore.mostRecentlyUsedSpace(ofProfile:) wraps QuickDetour.mostRecentlyUsedSpace over spaceUseOrder. openNewWindowUsing resolves the space before creating the window and calls setActiveSpace instead of AppDelegate.assignDefaultSpace. Error text: 'Cannot open a window: the profile has no space'.
API Explorer unchanged: no new API surface, and the Windows section's Create button already calls windows.create. tabs.create still uses the profile's first space in sidebar order (space(for:)); not changed, recorded in the wiki.

Code review (--fix): no correctness findings. Applied: openNewWindowUsing as a single if/else (Private window, or guard-let on the caller's space, then the normal window); the front-space test uses assertOpenedANormalWindow. Also fixed a skipped finding: the last-active test removes its spaces after each pass, so the 'not its first space' check still means that on the second pass. Not applied: moving tabs.create (space(for:), first space in sidebar order) to the same rule, which would change another API and is out of this task's scope; the gap is recorded in the wiki.
Tests: ExtensionWindowsCreatePrivateTests 11/11; with QuickDetourExtensionTests, QuickDetourOpenInTests, ExtensionPrivateDefaultTests, ExtensionPrivateStoreTests and WKExtensionIntegrationTests, 97/97.
Runtime (/verify, Debug build in .derived, DETOUR_DATA_DIR=DetourVerify223): seeded a Work profile with one space and a probe enabled only in Work (disabled in Default). At launch only the Home window (Default) was shown. The probe's worker called windows.create({url}), which resolved {incognito:false}. browser.db saved the tab in Work / Work Space. On screen: the Example Domain window plus the Home window. Afterwards I removed this run's defaults keys and data dir.
Not checked at runtime: the most-recently-used choice between two of the profile's spaces (needs space switching in the UI; covered by testFromANormalProfileWithNoOpenSpaceOpensOnItsLastActiveSpace) and the no-space refusal (covered by its test).

Runtime re-check 2026-10-28 (screen unlocked): (F) DetourVerifyRTF with profile ProfA (spaces A1 first in the sidebar, A2), ProfB (B1); probe enabled in ProfA only. A real click on the sidebar's A2 space button switched the launch window to A2 (spaceUseOrder A2, A1); a second window was opened on B1 and made key by a real click (A window clicked first, then B: spaceUseOrder B1, A2, A1). A tab added by the harness in A1 (no window shows A1, A's window not made key) triggered ProfA's worker to call windows.create({url}) with B in front: resolved {incognito:false}; the new window showed A2 with the URL, browser.db saved the tab in A2; nothing in B1 and nothing new in A1. Data dir and defaults keys removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
windows.create from a normal profile's extension context now opens its window on the caller's own profile: its most recently used space (TabStore.spaceUseOrder, the same rule as Quick Detour's Open in default), else its first space. If the profile has no space, the call is refused with an error before any window opens. Before, the window took the key window's space, which could belong to another profile, so the URL loaded with that profile's cookies and history and the window belonged to its extension contexts. The user's decision (2026-10-28): when the caller's profile has no open space, use its last active space. Private windows (TASK-214) are unchanged.
Changes: TabStore.mostRecentlyUsedSpace(ofProfile:); ExtensionManager.openNewWindowUsing resolves the space before creating the window. Three new real-context tests: another profile in front (both transports, both forms), no open space (last active, not first), no space (refused, no window). All three failed before the fix. Wiki: tab-and-window-bridge 'Opening a window' (the gap removed from the limits), extension-manager, app-shell, log.
Verified: 97/97 in the affected suites, code review clean. At runtime, a probe in a Work profile with Home in front opened its window and tab in Work Space.
Remaining gap: tabs.create still uses the profile's first space in sidebar order (no follow-up filed).
<!-- SECTION:FINAL_SUMMARY:END -->
