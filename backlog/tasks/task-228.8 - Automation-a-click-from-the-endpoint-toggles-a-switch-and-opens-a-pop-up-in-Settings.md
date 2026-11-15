---
id: TASK-228.8
title: >-
  Automation: a click from the endpoint toggles a switch and opens a pop-up in
  Settings
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15T05:14:00Z'
updated_date: '2026-11-15T07:37:00Z'
labels:
  - automation
dependencies: []
references:
  - TASK-228.7
  - TASK-338
  - Detour/Automation/AutomationInput.swift
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: low
type: bug
ordinal: 416000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-338's runtime checks: in a test run, the endpoint's click on a Settings control hits the right view (hit_test and the click report NSSwitch / NSPopUpButton) but the switch does not toggle and the pop-up does not open. It behaved the same before TASK-338, so it is how the endpoint delivers clicks to controls that run their own tracking loop, not the form. TASK-228.7's runtime run reported a click on a Settings switch as completed; whether it toggled was not checked. Settings input stays test-run only (TASK-228.7); this is about making those test-run clicks real.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 In a test run, click on a Settings switch toggles it and click on a pop-up opens its menu (list_menu shows it), as a real click would
- [x] #2 The fix is in the input path (how the press and release reach a control's tracking loop), not a special case for Settings, and browser-window controls (sidebar buttons, address bar buttons) still work
- [x] #3 Settings input on the user's endpoint is still refused (gate_closed), and the Automation section still refused in test runs
- [x] #4 Tests cover a switch and a pop-up; checked at runtime
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Cause (measured in the test host with a nextEvent swizzle): AppKit's own controls (NSSwitch, NSButton, NSPopUpButton, not subclassed) track a click with a gesture recognizer that NSWindow's event routing feeds; their mouseDown: returns at once without a tracking loop unless a subclass needs the legacy fallback (a subclass overriding mouseDown tracks). The posted release stays queued, same window and point; the endpoint's leftover handling then gives it to view.mouseUp, which does nothing. Through window.sendEvent for press and release, a switch, checkbox, HoverButton and pop-up all act, with the app inactive and the window not key; a view whose acceptsFirstMouse is false gets nothing that way.
2. Fix in AutomationInput.click for a native view, left button: when the hit view accepts first mouse for the press, deliver the press with window.sendEvent (press current), after re-hit-testing inside the run-loop body: only if the window's hit is the same view the tool checked, else direct delivery to the checked view. The leftover release goes through window.sendEvent on that route. Views that do not accept first mouse and right clicks keep direct delivery. focus() stays. window.sendEvent, not NSApp.sendEvent (no local monitors, announce stays).
3. Tests: AutomationInputTests: a switch toggles and a pop-up opens (list_menu, choose_menu_item) in a window in the test host; Settings switch through the tool in a test run (AutomationWindowKindsTests), gates unchanged. Run all Automation* suites and MCPServerTests.
4. Runtime: test-run endpoint; Peek switch stored value changes; Quick Detour idle pop-up choose an item and stored value; background HoverButton/sidebar row; two windows active; drag strip; 326 and 228.7 scripts.
5. Wiki trap correction (the test host does not move posted events), log; review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-14 implementation (Claude):
- Cause, measured in the test host with a swizzle on NSApplication.nextEvent(matching:...) and in the running app with temporary logging: the release was NOT taken off the queue early, its window and location were not moved, and the press reached the right view. AppKit's own controls (NSSwitch, NSButton, NSPopUpButton, not subclassed) track a click with an NSControlGestureRecognizer that only NSWindow.sendEvent feeds; their mouseDown(with:) returns in about 1 ms and runs no tracking loop, so the queued release went to mouseUp(with:) and nothing happened. A subclass that overrides mouseDown (a test double, HoverButton's kind) still tracks the old way. Through window.sendEvent, press then release, the recognizer begins on the press and the control acts on the release, with the app inactive and the window not key. A view whose acceptsFirstMouse is false gets nothing through the window in that state.
- Fix (AutomationInput.click, native view, left button): AutomationInput.deliversThroughWindow decides inside the run-loop body. The press goes through window.sendEvent when the view accepts first mouse for it, does not delay window ordering for it (sidebar rows do) and is still the window's hit with the press current (so the press never reaches a view the Settings gates did not check). The leftover release then goes through window.sendEvent too. Otherwise the press goes to the view directly, as before. Right clicks are unchanged. focus() stays on both routes.
- The wiki trap 'the test host moves posted events' was wrong (probes: location unchanged) and is replaced by this cause.
- Runtime trap found: NSSwitch acts only for a press on its pill. A press at the view's left edge (inside its bounds, so hit_test reports NSSwitch) fails its private track hit test and does nothing, as a person's would. The first runtime runs aimed there and looked like failures; aim at the centre of hit_test's frame.
- Behaviour difference (for the lead): with Detour active (after open_ui settings), a routed click in a browser window that is not key made that window key (Settings stopped being key), as a person's click does. Direct delivery never did that. Seen in 2 runs; in later runs Detour was not activated by open_ui and the case did not arise.
- Found, not fixed (out of scope): a left click on a sidebar row selects nothing through the endpoint, with the old direct route (checked with routing turned off) and through the window. select_tab does it.
- Tests: new AutomationInputTests.testASwitchTogglesAndAPopUpOpensItsMenu (switch toggles both ways and sends its action; pop-up opens, list_menu lists One/Two/Three, choose_menu_item selects Two and sends the action; deliversThroughWindow refuses a covered view, a view without first mouse and a view that delays window ordering); AutomationWindowKindsTests' Settings test now checks the switch toggles and back in a test run, gates unchanged. All Automation* suites (16) and MCPServerTests: 211 tests, 0 failures.
- Runtime (/verify, Debug build of this worktree, dylib 21:54, DETOUR_DATA_DIR=DetourVerify-2288, DETOUR_MCP=1 test run, scratchpad task-228.8/verify2288.py): 18/19. Peek switch toggles PeekEnabled 1->0 and back 0->1; the Private switch is still gate_closed; Settings > Quick Detour idle pop-up opens (menu_open, list_menu lists Never/1 hour/6 hours/12 hours/1 day) and choose_menu_item changes QuickDetourIdleTimeout; Back (HoverButton) goes back with Detour in the background; a click on the WindowDragView strip completes and moves nothing; Detour stayed inactive and the window frame unchanged. The one failure is the sidebar row left click above (pre-existing). docs/harness/task326-copy-url-checks.py: ALL PASS (12). TASK-228.7's verify2287.py: all 21 checks pass. Defaults keys, suite plists and data folders of these runs removed.

2026-11-14, after rebasing on main b575692 (TASK-338's grouped Settings with mini switches, TASK-339/340):
- New test AutomationWindowKindsTests.testASettingsPopUpOpensForATestRunsClick: Settings > Quick Detour's idle pop-up opens for a test run's click (menu_open, list_menu lists the pop-up's own titles) and is gate_closed on the user's endpoint.
- All Automation* suites and MCPServerTests on the rebased tree: 212 tests, 0 failures. After the review fixes: AutomationInputTests, AutomationWindowKindsTests, AutomationToolsTests, AutomationPrivateAccessTests 46/0.
- Runtime on the rebased build (dylib 22:59, DetourVerify-2288 test run): the mini Peek switch toggles PeekEnabled to 0 and back to 1; the Private switch is gate_closed; the Quick Detour idle pop-up opens, lists its five items, and choose_menu_item stores never; Back (HoverButton) in the background, drag strip, app stayed inactive. 17/19: the pre-existing sidebar row left click, and the key-window difference (Detour was active this run: a routed click on the browser's Back button made the browser window key and Settings lost key). docs/harness/task326-copy-url-checks.py ALL PASS; verify2287.py 21/21. Defaults keys, suite plists and data folders removed.
- Review (/code-review medium --fix, forked, no build): 6 findings. Fixed: (1) the Settings switch test restores PeekSettings in a defer; (3) the route is decided before focus() moves (a field editor put over a text field would change the hit test). Left: (2) the routed click makes a non-key window key when Detour is active, as a person's click does; with two browser windows that moves web view ownership; recorded in the wiki, for the lead. (4) a window with a sheet may drop a routed press while click reports completed (speculative, not reproduced). (5) the direct route sends the original release, the routed one the dequeued copy (same time and place; left). (6) the test's queue check peeks in .eventTracking as the older test does (left).

2026-11-14 user decision: approved: while Detour is active, an endpoint click in a background window brings it forward as a person's click does (the ownership hand-off is tested in TASK-228.10).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A click from the endpoint now toggles a switch and opens a pop-up, in Settings and anywhere else. Cause: AppKit's own controls (NSSwitch, NSButton, NSPopUpButton, not subclassed) track a click with an NSControlGestureRecognizer that only NSWindow.sendEvent feeds; their mouseDown runs no tracking loop, so the press handed to the view did nothing and the queued release went to mouseUp. The release was not taken early and its location was not moved (the old wiki trap saying the test host moves it was wrong). Fix in AutomationInput: a left press goes through window.sendEvent, press and release, when the view takes a first click, does not delay window ordering, and is still the window's hit with the press current (so the Settings gates see every view a press can reach); other views and right clicks keep the direct route. Settings input stays test-run only, the Automation section stays refused. Tests: switch and pop-up in a browser window, Settings switch and pop-up in a test run; Automation* and MCPServerTests 212/0. Runtime: Peek (mini switch in the new layout) toggles its stored value both ways, the Quick Detour pop-up opens and stores a chosen item, background Back button and drag strip unchanged, 326 and 228.7 scripts pass. Behaviour difference for the lead: with Detour active, a routed click in a window that is not key makes it key, as a person's click does. Found, not fixed: a left click on a sidebar row selects nothing through the endpoint, before and after (select_tab does it).
<!-- SECTION:FINAL_SUMMARY:END -->
