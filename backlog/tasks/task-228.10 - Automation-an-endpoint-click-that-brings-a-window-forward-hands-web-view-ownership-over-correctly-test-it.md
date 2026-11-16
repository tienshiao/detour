---
id: TASK-228.10
title: >-
  Automation: an endpoint click that brings a window forward hands web view
  ownership over correctly (test it)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15T07:30:00Z'
updated_date: '2026-11-16T00:14:00Z'
labels:
  - automation
  - windows
dependencies: []
references:
  - TASK-228.8
  - Detour/Automation/AutomationInput.swift
  - wiki/architecture/browser-window-controller.md
parent_task_id: TASK-228
priority: low
type: task
ordinal: 421000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-228.8. Since a left press on a control goes through NSWindow.sendEvent, a routed click in a window that is not key makes that window key while Detour is active, as a person's click does; direct delivery never did. Between two browser windows showing the same tab this moves web view ownership (the owning window shows the live web view, the other a snapshot). Nothing tests that path, and an agent's click causing an ownership hand-off the person did not expect is a behaviour to confirm, not assume.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A test with two browser windows showing the same tab: an endpoint click on a control in the non-owning window moves ownership exactly as a person's click would (or is deliberately kept from doing so), and both windows end consistent (one live web view, one snapshot)
- [x] #2 With Detour in the background the click does not activate Detour or change the key window
- [x] #3 The decision (agent clicks may or may not bring a window forward) is recorded in the automation wiki
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Record the user's decision (2026-11-15): with Detour active, an agent click in a non-key window makes it key (web view ownership follows, as for a person's click); with Detour in the background a click never activates Detour or changes the key window.
2. Check the current code against it: only a press routed through NSWindow.sendEvent can make a window key; page clicks, sidebar rows and Detour's own views go direct and never do.
3. Fix in one place in the click tool (and type_text's selector click): with Detour active and the window not key, make it key first (AutomationEnvironment.isAppActive / makeKey, injectable), then check the target again (the view tree changes when the web view moves in).
4. Tests: two browser windows showing the same tab; active (injected) clicks on a routed control and a direct target move ownership to the clicked window, exactly one live web view and one snapshot; background (the host is inactive) clicks change neither the key window, the app's activation nor the owner.
5. Runtime: two windows, Detour active then in the background; wiki (automation endpoint, decision) + log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
USER DECISION (2026-11-15, made today by the user): agent clicks behave like a person's. With Detour active, a click in a window that is not key makes it key and web view ownership moves there, as a person's click does. With Detour in the background, a click never activates Detour or changes the key window. Recorded in wiki/features/automation-endpoint.md (How input is delivered) and wiki/architecture/webview-ownership.md.
What the code did before: only a left press routed through NSWindow.sendEvent (TASK-228.8) could make a window key; page clicks, sidebar rows and Detour's own views (direct route) never did, so with Detour active the decision was not met for most clicks. Fix: AutomationTools.bringForward, in the click tool and type_text's selector click: after the glide and its checks, if Detour is active, the window is not key, can become key, is visible and on the active Space, makeKeyAndOrderFront, then retarget (the snapshot is replaced by the live web view). AutomationEnvironment.isAppActive / makeKey are injectable (the XCTest host is never active and cannot make a window key). BrowserWindowController.isShowingSnapshot added for the tests.
Chosen by Claude (not yet confirmed by the user): a window on another Space is not made key (a person could not click it; it would switch their desktop); alternative: make it key like any other. A click on a snapshot's place with Detour active reaches the live page that replaces it (a person's first click there would probably only bring the window forward); alternative: drop the press after making the window key.
Tests: AutomationInputTests 16/0 (new: testWithDetourActiveAClickInAWindowThatIsNotKeyMakesItKeyAndTakesTheWebView: two browser windows on one tab, active injected, a routed NSSwitch click in the snapshot window makes it key and moves the web view, a direct click in the other moves it back, a page click and type_text's selector click by tab make the hosting window key, exactly one live web view and one snapshot after each; testInTheBackgroundAClickChangesNeitherTheKeyWindowNorTheWebViewsOwner: the real environment, routed and direct clicks in the snapshot window, NSApp stays inactive, NSApp.keyWindow unchanged, ownership unchanged, both clicks still delivered), AutomationAgentPointerTests 12/0, AutomationPageTests 14/0, AutomationToolsTests 22/0, AutomationWindowKindsTests 10/0, WebViewHandoffFocusTests 7/0 (81/0).
Runtime (Debug build, DETOUR_MCP=1, isolated data dir, two browser windows showing the same tab, ownership read with hit_test on the page area: BrowserWebView vs NSImageView): in the background, clicks on window 2's snapshot and its row left app_active false, neither window key, the web view in window 1. After set_window_frame activate=true (window 1 key): a click on window 2's page made window 2 key, moved the web view there (window 1 now NSImageView) and reached the page (target web_view); a click on window 1's row made it key and moved the web view back. The runtime pass ran before the review's reorder (gates checked before the window is made key) and the other-Space guard; the tests cover those.

Correction to the note above: the tests do not cover the review's two late changes. The reorder (gates checked again after the glide before the window is made key) has no test: it needs a gate that flips during the glide (agent pointer on, a Private window whose opt-in turns off mid-glide); left to code order and review. The other-Space guard cannot be tested in the host (it cannot put a window on another Space). Final runtime pass on the committed code (rebuilt 16:12, active, two windows): a click on window 2's snapshot made it key and moved the web view there (target web_view); a click on another tab's row (Bravo) in window 1, not key, made window 1 key and selected Bravo; a click at the close button's place on Alpha's row in window 2, not key, made window 2 key and closed Alpha. activate=true took focus from the user's front app in each active run. The three tests that need an inactive host (row select, both 228.10 tests) now skip when the host is the active app; AutomationInputTests 16/0 after that.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Recorded the user's decision (2026-11-15): agent clicks behave like a person's; with Detour active a click in a window that is not key makes it key and the web view moves there; in the background a click never activates Detour or changes the key window. The code met it only for presses routed through the window, so the click tool and type_text's selector click now make the window key first when Detour is active (AutomationTools.bringForward; not for a window on another Space, chosen by Claude), then check the target again. Two tests with two browser windows on one tab (active injected through AutomationEnvironment; background as the host is) assert one live web view and one snapshot after each click; checked at runtime both ways. Wiki: automation endpoint (decision) and web view ownership.
<!-- SECTION:FINAL_SUMMARY:END -->
