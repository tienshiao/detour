---
id: TASK-228.11
title: 'Automation: a visible agent pointer shows where the endpoint clicks and types'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T20:08:00Z'
updated_date: '2026-11-15T22:11:00Z'
labels:
  - automation
  - ui
dependencies: []
references:
  - Detour/Automation/AutomationInput.swift
  - Detour/Automation/AutomationCapture.swift
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: low
type: feature
ordinal: 424000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Proposed 2026-11-15 by the user, after Claude in Chrome's virtual cursor. The MCP endpoint delivers clicks and keys inside Detour without moving the person's mouse (wiki/features/automation-endpoint.md, 'how clicks, keys and menus are delivered'), so the person cannot see where an agent is acting; the connected-agent capsule only says an agent is there. Draw a visible agent pointer.

Design (the user approved these defaults on 2026-11-15):
- Native, not in the page: a click-through overlay window (ignoresMouseEvents, child of the target window) drawn by Detour. The endpoint also clicks sidebar rows, menus, switches and Settings, which an in-page DOM cursor cannot reach, and a DOM cursor would be visible to page scripts and to hit_test and the page tools.
- Every click route in AutomationInput already knows the window and point: the pointer glides from its last position to the target, shows a press ripple, then the event is delivered. Short glide (about 150 ms) by default; longer, slower motion while capture staging is in use, so a recording can be followed.
- Typing: a brief highlight on the element or field that receives the keys (there is no point to move to).
- Look: a tinted arrow with a small 'Agent' label, clearly distinct from the system pointer.
- Shown also when the target window is in the background and Detour is not frontmost (the case where the person most needs to see it).
- Scope: browser windows first; Quick Detour, quarantine and Settings windows if they come for free through the same window routing.
- A setting under Settings > General > Automation, on by default. Tests and harnesses turn it off with the Debug set_debug_override (like automation_indicator), so their clicks gain no delay.
- Agent screenshots: the screenshot tool captures one window through ScreenCaptureKit (AutomationCapture.swift), which should leave a separate overlay window out; confirm it. Full-screen recordings (website captures) are expected to show the pointer.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An endpoint click (by selector, page point or window point, left or right) in a browser window shows the agent pointer gliding to the point and a press ripple, then delivers the click; the person's own pointer does not move
- [x] #2 Typing through the endpoint briefly highlights the element or field that receives the keys
- [x] #3 The pointer is shown when the target window is in the background and Detour is not frontmost, and never takes clicks, focus or key status
- [x] #4 Settings > General > Automation has a switch for the pointer, on by default; off, endpoint input is delivered with no added delay (a test measures it)
- [ ] #5 The endpoint's screenshot tool leaves the pointer out of the image; a full-screen recording shows it (checked at runtime)
- [ ] #6 A Debug set_debug_override turns it off for tests and harnesses; existing automation tests and harnesses still pass
- [ ] #7 Checked at runtime with /verify (a recording of clicks in the sidebar, a Settings switch and a page); wiki updated (automation endpoint, capture staging)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. AutomationAgentPointer (new, Detour/Automation): per-target-window overlay (NSWindow subclass that can never be key/main, ignoresMouseEvents, child of the target, excluded from Windows menu, transient/ignoresCycle/fullScreenAuxiliary, no sharingType change), held by weak window key; arrow + 'Agent' label tinted orange like the capsule; glide (150 ms, slower once capture staging is used) via Core Animation with an injected pause; press ripple; typing highlight; linger then fade and order out; hidden on close/minimize; Reduce Motion: appear, no glide, no pause.
2. Setting AutomationAgentPointerEnabled in the data directory's defaults, on by default; PROVISIONAL default off in DETOUR_MCP=1 test runs so harnesses that never send the override keep their speed; Debug set_debug_override agent_pointer on/off/default, test runs only (like automation_indicator). AutomationEnvironment.showsAgentPointer defaults to false, so XCTest is off unless a test turns it on; live reads the setting per call.
3. Tool handlers (click, type_text with selector, press_key): pointer checked synchronously, glide once per call after validation and gates, then re-validate (window hit test + Automation-section gate, web view still in the window, Private access) and deliver as today. Off path: no await added. Popups (child windows) skipped. Typing highlight: field editor's control frame, or the page's activeElement rect from the isolated world, best-effort and never blocking keys.
4. set_window_frame window_number refuses the overlay.
5. Settings > General > Automation: switch 'Show where agents click and type'.
6. Tests: AutomationAgentPointerTests (never key/main/clicks, first responder and hit_test unchanged, off = no pause and no overlay, on = 150 ms pause, staging slower, Reduce Motion no pause, order of a click then keys, re-validation, highlight, screenshot source app excludes it, override + setting default); WindowCloseReleaseTests history showing the pointer; existing Automation* suites.
7. /verify with DETOUR_MCP=1: clicks on a sidebar row, Settings Peek switch, a page element, typing into a page field; full-screen capture sequence; endpoint screenshot (app and screen) without pointer; CGWindowList order unchanged; setting on/off.
8. Wiki (automation-endpoint, settings), Backlog notes, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (Nov 15 2026):
- AutomationAgentPointer.swift: AutomationAgentPointerSetting (AutomationAgentPointerEnabled, data-dir defaults, Debug override), AutomationAgentPointer (per-window overlay in a weak-keyed table, injected pause), AutomationAgentPointerWindow (borderless child window, never key/main, ignoresMouseEvents, out of the Windows menu, transient/ignoresCycle/fullScreenAuxiliary), AutomationAgentPointerOverlay (arrow + 'Agent' tag tinted systemOrange, glide, ripple, field outline, linger 3 s then fade and leave the parent's child windows; hides on minimize/screen loss, torn down on close), AutomationInputOrder (FIFO for click/type_text/press_key while the pointer is on).
- Tools: glide once per click after validation and gates, then retarget (window open and reachable, page still in the window, window point hit-tested again with the Automation-section gate). type_text/press_key outline the field (field editor's field, or the page's activeElement rect from the client world, else the web view), never waiting. set_window_frame window_number never finds the overlay. set_debug_override agent_pointer on/off/default (test runs only).
- AutomationCapture.screen: a desktop-independent window picture INCLUDES child windows (the pointer showed at runtime), so while an overlay is up the window is taken from its display with every other window excluded, cropped to its frame. SCContentFilter(display:including:[window]) still drew the overlay.
- Settings > General > Automation: 'Show where agents click and type' (in the gated section).

PROVISIONAL (chosen by Claude, not confirmed by the user; each a one-line flip):
1. In a test run (DETOUR_MCP=1) the setting defaults OFF (AutomationAgentPointerSetting.defaultValue), so docs/harness scripts and capture.py, which never send the override, keep their speed and their output; alternative: on in test runs too, with the harness scripts sending set_debug_override agent_pointer off. capture.py does not turn it on, so website media have no pointer unless asked.
2. 'Capture staging in use' = a client called seed_world or set_window_frame in this run (AutomationTools.stagingInUse); the glide is then 600 ms instead of 150. Alternative: an explicit override value.
3. The pointer lingers 3 s after the last click/key, then fades; the tag flips left near the window's right edge.
Not drawn over a window that hangs off another (extension popup popover, sheet).

Review (/code-review medium --fix, forked): fixed in the tree: screen screenshot keeps the window's other child windows; no display capture and no glide for a window on another Space (isOnActiveSpace); the page highlight re-checks the setting after the page answers; field-editor-to-field rule shared (AutomationWindows.view(for:)). The reviewer's switch to SCContentFilter(display:including:) was reverted to excludingWindows (including: drew the overlay at runtime, checked twice). I also fixed its cosmetic finding (a fade-out replaced through the animator, no flicker). Skipped: putting choose_menu_item/close_menu in the arrival order (would change how the menu tools wait for a menu; left for the user).

Tests: AutomationAgentPointerTests 12/12 (incl. a right click); first full pass of the affected suites (AutomationAgentPointer, Input, Capture, Tools, Staging, WindowKinds, PrivateAccess, MCPServer, Controller, Page, Endpoint, WindowCloseRelease, SettingsSwitchRow, SettingsPanesForm) 176 tests, 1 failure: WindowCloseReleaseTests.testAWindowShowingASplitIsFreed, whose retain tree held an ArcImportWindowController left by AutomationStagingTests in the same process and nothing of the pointer; WindowCloseReleaseTests alone 21/21. After the review: AutomationAgentPointer + Input + Capture + WindowKinds + SettingsSwitchRow + WindowCloseRelease 79/79. The order test fails (keydown before mousedown) with the queue disabled, so it is not vacuous.

Runtime (/verify, DETOUR_MCP=1, DetourVerify-22811/-22811b, Detour never brought forward except once): page click by selector and by page point, typing into a page field, two sidebar-row clicks (window point), Settings > General Peek switch (toggled; PeekEnabled 0) all showed the glide, ripple and outline in burst captures of the overlay window (screencapture -l, composited on the window). Detour stayed inactive and the window server order did not change through the browser-window clicks. Click call time through the CLI: ~160 ms off, ~320 ms on (150 ms glide), ~160-200 ms with Reduce Motion. The saved setting flipped with defaults write: on -> overlay window on screen, off -> none. The Settings switch showed On with the setting true; a click on it through the endpoint is gate_closed (Automation section). Endpoint screenshot source screen: before the fix the pointer was IN it (desktopIndependentWindow includes child windows); after, not, while screencapture -l of the overlay taken right after showed it. source app: unit test. Tag flips left at the right edge (checked).
Activations: 1 (open_ui settings), then Hide Detour through run_menu_item.

Not verified / owed:
- AC #5 second half: a full-screen recording showing the pointer. Two region recordings were made but the user's own windows covered Detour's window (deleted, they showed the user's screen). Evidence instead: the overlay is an on-screen layer-0 window right above the browser window in CGWindowList, and its own capture shows the arrow. A recording on an uncovered window (an idle Mac or Detour in front) is owed.
- AC #6: docs/harness scripts were not run; with the test-run default off they get no pointer and no delay.
- AC #7: the recording as worded (see #5); the checks were done with overlay frame bursts instead. Wiki updated.
- The Settings switch shown Off at runtime (Settings closed when the app was hidden); covered by testTheSettingsSwitch.
- Quick Detour and quarantine windows not exercised at runtime (same routing as Settings, which was).
- WebKit data under the test-run names may remain in ~/Library/WebKit (not removed).

2026-11-15 user decision: keep the pointer off by default in test runs (DETOUR_MCP=1), as built (no longer provisional); the website capture kit turns it on: docs/capture/capture.py calls set_debug_override agent_pointer on after seeding (Debug builds; a Release build logs and goes on), and --no-agent-pointer leaves it out. README and wiki updated. Checked: the script parses and lists the flag; the override's 'on' value is the one AutomationAgentPointerTests covers. Not run: a full capture.py take (needs the virtual display and an idle screen); the first website capture will show it. Still provisional: the 600 ms staging glide and the 3 s linger.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A visible agent pointer for the automation endpoint: a click-through child overlay window over the target window glides an orange 'Agent' arrow to each endpoint click (150 ms, 600 ms once capture staging is in use; Reduce Motion: no glide, no wait), ripples, then delivers the click; typing outlines the field. Checks run again after the glide; input calls keep arrival order while it is on. Settings > General > Automation switch, on by default (off by default in a test run, PROVISIONAL), Debug set_debug_override agent_pointer for test runs. Screenshots leave it out (source screen needed a display-based capture: a window's own SCK picture includes child windows). Remaining: user decisions on the provisional defaults, a full-screen recording on an uncovered window (AC #5/#7), harness scripts not run (AC #6).
<!-- SECTION:FINAL_SUMMARY:END -->
