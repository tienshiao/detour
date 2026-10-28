---
id: TASK-226
title: >-
  Extensions: tabs.create adds its tab to the profile's first space, not the one
  in use
status: Done
assignee:
  - '@claude'
created_date: '2026-10-28T08:43:00Z'
updated_date: '2026-10-28T12:05:00Z'
labels:
  - extensions
  - profiles
dependencies: []
references:
  - wiki/extensions/tab-and-window-bridge.md
  - TASK-223
priority: low
ordinal: 262000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-223 (2026-10-28). Since TASK-223, windows.create opens a normal window on the caller's profile's most recently used space (TabStore.mostRecentlyUsedSpace(ofProfile:), the spaceUseOrder rule). tabs.create with no windowId still goes through ExtensionManager.space(for:), which picks the profile's first space in sidebar order. With two spaces on a profile and the second in use, an extension's new tab lands in the first space, possibly one no window shows, and the user never sees it. ExtensionPolyfillHandler.targetSpace (tabs created or restored by the polyfilled APIs, e.g. sessions.restore) uses a third rule: the global last active space if it is this profile's, else the profile's first. The three should agree.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 tabs.create without a windowId from a normal profile's context adds its tab to that profile's most recently used space, from both transports, in the promise and callback forms, with a test that fails before the change (two spaces on the profile, the second in use)
- [x] #2 ExtensionPolyfillHandler.targetSpace uses the same rule, or the task records why it should differ
- [x] #3 A profile with no space still gets no tab in another profile's space
- [x] #4 wiki/extensions/tab-and-window-bridge.md 'Opening a window' no longer lists the difference
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Callers of ExtensionManager.space(for:): only openNewTabUsing. ExtensionPolyfillHandler.targetSpace() serves sessions.restore and search.query.
2. Red: in ExtensionWindowsCreatePrivateTests one real-context test (one loaded profile): two spaces on the caller's profile, the second used last (windows shown first then second), another profile's window in front; tabs.create without windowId from worker and page, promise and callback, lands in the second space, never the first or the front one. Then the caller's spaces are removed: tabs.create is refused with an error and no tab lands in the other profile's space. In ExtensionPolyfillProfileWiringTests: search.query from profile B with two spaces, the second most recently used, and the global last active space A's -> the tab opens in B's second space.
3. Green: one rule, ExtensionManager.newTabSpace(for: Profile): a normal profile -> TabStore.mostRecentlyUsedSpace(ofProfile:) (the windows.create rule); an incognito profile (its Private spaces are never in spaceUseOrder) -> the global last active space if it is this profile's, else its first space (targetSpace's old rule). space(for:) and targetSpace() both use it. A profile with no space: tabs.create now rejects ('the profile has no space') instead of resolving with nothing.
4. Wiki: tab-and-window-bridge 'Opening a window' drops the difference; extension-manager; log.
5. /code-review --fix, /verify (probe: two spaces, second in use, tabs.create), suites, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Callers of space(for:): only openNewTabUsing (it is now replaced by newTabSpace(for:)). Red: testTabsCreateAddsToTheCallersMostRecentlyUsedSpaceAndIsRefusedWithoutOne failed 9 assertions (all four tabs.create calls landed in the profile's first space; with no space the call resolved with nothing instead of an error) and testSearchQueryOpensTabInTheProfilesMostRecentlyUsedSpace failed 2 (the tab went to the profile's first space). Green: ExtensionWindowsCreatePrivateTests 16/16, ExtensionPolyfillProfileWiringTests 51 (7 skipped, gated), 0 failures.
Choices: (1) targetSpace now uses the same rule (AC2). (2) An incognito profile keeps targetSpace's old rule (the global last active space when it is that profile's, else its first) for both, because Private spaces are never in spaceUseOrder and mostRecentlyUsedSpace skips them; for tabs.create from a Private context this changes 'first Private space' to 'the key Private window's space' - no test (two Private windows), stated here. (3) tabs.create from a profile with no space now rejects with 'Cannot open a tab: the profile has no space' (was a silent resolve with nothing), matching windows.create since TASK-223. Not done: tabs.create with a windowId still ignores configuration.window (follow-up candidate).

Code review (/code-review --fix, 7 findings): fixed - openNewTabUsing now resolves the profile first ('Cannot open a tab for an unknown profile'), then refuses detour:// and javascript: URLs, then looks up the space, as windows.create does; windows.create's normal branch now calls newTabSpace(for:) so the rule lives in one place; the comment on lastActiveSpaceID corrected (set when a window becomes key, not on a space switch inside it). Not taken: configuration.window still ignored (follow-up); incognito rule is not a true most-recently-used order (stated choice above); the new wiring test leaves its ids at the head of the in-memory spaceUseOrder (harmless, private(set)).
Tests after review: ExtensionWindowsCreatePrivateTests 16/16, ExtensionPolyfillProfileWiringTests 51 (7 skipped, gated), BrowserTabWakeTests 7/7, InternalPageTests 17/17 (91, 0 failures).
Runtime (/verify, DETOUR_DATA_DIR=DetourVerify226a, Debug build in .derived): Default profile seeded with spaces Home (sortOrder 0) and Work (1), appState lastActiveSpaceID = Work (launch records it as used); probe worker's tabs.create without windowId in promise and callback forms both resolved (lastError null) and the saved session put both tabs in Work, none in Home. The screen was locked, so no window became key during the run. Not verified at runtime: the no-space refusal and the polyfill search.query/sessions.restore path (covered by tests); the build checked at runtime predates the review's reordering, which does not change this path.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
tabs.create without a windowId, and the polyfill's search.query and sessions.restore, now add their tab to ExtensionManager.newTabSpace(for:): a normal profile's most recently used space (TabStore.mostRecentlyUsedSpace(ofProfile:), the rule windows.create also uses through the same function), and for an incognito profile the global last active space when it is that profile's, else its first (Private spaces are never in spaceUseOrder). space(for:) (profile's first space) and targetSpace's own rule are gone. A profile with no space now rejects tabs.create ('the profile has no space') instead of resolving with nothing; no tab ever lands in another profile's space. Tests: real-context tabs.create test (two spaces, second used last, other profile in front; then no space) over both transports and forms, plus a search.query wiring test; red 11 failures before, green after; runtime probe put both tabs in the second, in-use space. Wiki: tab-and-window-bridge 'Opening a tab', polyfill-layer, extension-manager, log. Follow-up: tabs.create({windowId}) ignores configuration.window.
<!-- SECTION:FINAL_SUMMARY:END -->
