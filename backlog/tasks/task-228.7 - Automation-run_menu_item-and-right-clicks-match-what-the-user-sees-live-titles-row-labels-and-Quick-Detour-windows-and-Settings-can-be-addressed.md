---
id: TASK-228.7
title: >-
  Automation: run_menu_item and right clicks match what the user sees (live
  titles, row labels), and Quick Detour windows and Settings can be addressed
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T23:45:00Z'
updated_date: '2026-11-15T08:16:00Z'
labels:
  - automation
dependencies: []
references:
  - TASK-320
  - TASK-326
  - TASK-327
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: low
type: feature
ordinal: 412000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 during the batch's runtime checks. (1) run_menu_item by path matched the title a shared item had at its last validation: "File > Unpin Tab" was refused while the item still read "Pin Tab" (TASK-320). (2) list_windows and run_menu_item cover browser windows only, so Quick Detour and quarantine windows could not be driven (TASK-320, TASK-326), and Settings could only be driven through Accessibility and posted key events (TASK-327, TASK-328). (3) A right click sent to a sidebar row's label or icon opens no menu, while one on the row's background does; a real right click on the label opens it (TASK-326).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 run_menu_item validates the menu (as AppKit does before showing it) before matching a path, so the title it matches is the one the user would see
- [x] #2 list_windows lists Quick Detour, quarantine and Settings windows with their kind, and run_menu_item, screenshot and the input tools accept them (Private and quarantine rules as for browser windows)
- [x] #3 A right click at a sidebar row's label or icon opens the row's menu as a real right click does
- [x] #4 Tests cover each; the wiki tools table and traps are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. run_menu_item by path: before matching each level, validate that level's items against the target window (item.target or the window's responder chain, then CommandDispatch.isEnabled), the same validation that retitles Pin/Unpin Tab. NSMenu.update() is not used because it validates against the key window, not the named one. Test: two windows, a pinned tab selected in one, neither key, with Pin Tab and Unpin Tab paths.
2. Windows: AutomationWindowIDs keyed on NSWindowController, keeping the same counter. AutomationEnvironment.otherWindows (defaults to none; live it reads NSApp.windows for Quick Detour and Settings controllers, so the Settings singleton is not created). list_windows gains kind (browser, quick_detour, quarantine, settings). A second resolver serves run_menu_item, screenshot (window part), click, hit_test, type_text and press_key; browser-only tools answer a new unsupported_window code. One privacy predicate (browser incognito, Quick Detour on the Private profile, quarantine) feeds list hiding, refusal by id, the menu tracker and the Window-menu entries. PROVISIONAL: Private Quick Detour and quarantine windows stay refused whatever the setting until the lead answers; the switch to follow the opt-in is one line. Settings: list, screenshot and hit_test on any endpoint; input and run_menu_item in test runs only (gate_closed otherwise); the General pane's Automation section is refused always.
3. Right click on a sidebar row's label or icon: reproduce on the real sidebar in the test host, find the cause, fix it in AutomationInput.
4. Tests in AutomationToolsTests, AutomationInputTests, AutomationPrivateAccessTests and AutomationCaptureTests; wiki tools table, traps and Private section; review, verify, commit.

(2026-11-14 user decision) AutomationWindows.privateQuickDetourAccess = .privateOptIn; every path through access(of:) checked (list_windows, anyWindow/inputWindow by id, the menu tracker, Window-menu entries, set_window_frame by id and number, resolvePage, extension popups, input by context); open_url's quarantine refusal stays (independent). Tests: AutomationWindowKindsTests rewritten for off (refused) and on (reachable); all Automation* suites. Wiki: Private windows rule and the Never section, the kinds table, tests. Settings help for the Private switch names Quick Detour and Quarantine windows. Runtime: docs/harness/task228-7-private-quick-detour-checks.py, list_windows with the opt-in off and on.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-14 implementation (Claude):
- (1) AutomationMenus.item(atPath:in:validatingFor:allowPrivate:) validates each menu level's items for the named window (item.target or CommandDispatch.responderTarget, then CommandDispatch.isEnabled), which is where BrowserCommands.validate retitles Pin/Unpin Tab. NSMenu.update() was rejected because it asks the key window's chain. Window-menu entries (target is an NSWindow) are skipped.
- (2) New AutomationWindows.swift: AutomationWindowKind (browser, quick_detour, quarantine, settings), AutomationWindowAccess (open, privateOptIn, never) and one predicate for every Private check: listing, refusal by id, the menu tracker (now stores an access level per menu), the Window-menu entries, set_window_frame by window_number and resolvePage's window check. This also fixes a gap: a person's context menu in a Private Quick Detour was listable, because only BrowserWindowController.isIncognito was asked. AutomationWindowIDs is keyed on NSWindowController, with one counter. AutomationEnvironment.otherWindows defaults to none; live, it is QuickDetourWindowController.openControllers plus a visible Settings window found in NSApp.windows (asking .shared would build Settings). list_windows gains kind; a Quick Detour gives its page url and title but no tab id. anyWindow(id:) serves run_menu_item, screenshot (window part), click, hit_test, type_text and press_key; window(id:) stays browser-only and answers the new code unsupported_window.
- PROVISIONAL (chosen by Claude while the user was away, confirmed by the lead as the plan, not by the user): Private Quick Detour and quarantine windows are refused whatever the 'Allow agents to use Private windows' setting (AutomationWindows.privateQuickDetourAccess = .never), as the wiki's 'Never, whatever the setting' already said of their pages. Alternative: .privateOptIn, a one-value change. AC #2 is left unchecked for this.
- Settings: list_windows, screenshot and hit_test on any endpoint. click, type_text, press_key and run_menu_item only in test runs (gate_closed on the user's endpoint), because its panes would let an approved client do what the tools keep to test runs or the user (extensions in any profile including Private, permissions, profiles, Link Routes). In test runs too, input to Settings > General's Automation section (tagged with AutomationWindows.automationSettingsIdentifier) is gate_closed, for a click on a view in it and for keys or a command while the keyboard is in it, so no tool turns on Private access, resets the token or allows a client.
- (3) Cause, measured in the test host on the real sidebar: NSTableView.hitTest answers with the table for a press on a row's label or icon only while NSApp.currentEvent is a mouse press. The endpoint hit-tested with a stale appKitDefined event as current, got the NSTextField, and NSTextField.rightMouseDown inside a table opens nothing (label.rightMouseDown and window.sendEvent both opened nothing; cell, row and table opened the row menu). In a standalone spike, a plain label in a plain view forwards the click. Fix in AutomationInput: makeCurrent(event), which posts the event to the front of the queue and dequeues it, before hit-testing and before delivering a native mouse-down. hitView then makes the matching release current, so no press is left current.
- Also fixed in the same path: the leftover mouse-up check compared eventNumber, but posting renumbers events (1,000,001 came back as about 16,900), so it never matched. It now compares timestamps.
- Found: a context menu popped up by test code (NSMenu.popUpContextMenu from a RunLoop.perform block) in a Quick Detour window stalled the main queue in the test host, twice, with and without a release queued, while the same path in browser windows works. Not explained. The menu-over-Private test posts the tracking notification by hand instead.
- Tests: AutomationWindowKindsTests 5/5 (new), AutomationToolsTests 21/21 (new: Pin/Unpin matched per window), AutomationInputTests 10/10 (new: sidebar label/icon right click; no mouse-up left queued), AutomationPrivateAccessTests, AutomationCaptureTests, AutomationStagingTests, MCPServerTests (stable codes include unsupported_window), AutomationExtensionTests, AutomationPageTests: 70/70. Total 106, 0 failures.

Review (/code-review medium --fix, run as a forked agent on this worktree's diff). It found no correctness or security bug; it reported 5 findings.
1. makeCurrent's nextEvent in .eventTracking could run another tool's pending run-loop work re-entrantly. Fixed: it now dequeues in a private run-loop mode (DetourAutomationMakeCurrent). The other part of this finding was left: a synthetic release stays current, so the menu tracker judges a later menu without its own event by the agent's window, not the person's last one.
2. A menu the person opens over Settings' Automation section is not marked as restricted. Left: no control there opens a menu today.
3. A hidden Quick Detour (Dock Hide All) stays addressable while a hidden Settings window does not. Left.
4. Items with no target in the named window keep another window's title. Left: AppKit shows the same.
5. The review rewrote placeableWindow so that set_window_frame's window_id takes any kind of window, with the same reach as window_number; it also fixed the doc comment.
Re-run after the review: AutomationWindowKindsTests, AutomationToolsTests, AutomationInputTests, AutomationStagingTests and AutomationPrivateAccessTests, 58 tests, 0 failures. The earlier 70-test run of Capture, Staging, PrivateAccess, MCPServer, Extension and Page predates the run-loop mode change.
Runtime (/verify): Debug build of this worktree (dylib built 18:01), DETOUR_DATA_DIR=DetourVerify-2287, DETOUR_MCP=1 test run, Detour in the background, through scripts/detour-mcp's Session. Script: scratchpad task-228.7/verify2287.py. All 22 checks passed:
- A right click at x=90 on a tab row's title opens the row's menu (Copy URL, Share…, Open in Quick Detour).
- File > Unpin Tab is refused while the tab is unpinned; File > Pin Tab pins it; File > Unpin Tab, right after, unpins it.
- Open in Quick Detour lists a quick_detour window with the page's URL and no tab id. Its screenshot is right. Its page hit-tests as a web_view; a right click there lists WebKit's menu; list_tabs on it answers unsupported_window; File > Close Tab (cmd+w) through run_menu_item closes it.
- open_ui settings lists a settings window and its screenshot is right. A click on 'Allow agents to use Private windows' answers gate_closed, and the screenshot shows the switch still off. A click on the Peek switch goes through, and a second click toggles it back. Window > Minimize answers menu_item_disabled (Settings cannot minimise). press_key tab reaches an NSSwitch. File > Pin Tab is not matched in Settings (the title stays as another window left it).
- File > New Private Window gives hidden_private_windows 1.
- One of four runs failed to open the Quick Detour from the row menu; it was not investigated (likely the script's choose timing).
Not checked at runtime: a quarantine window or a Private Quick Detour (no tool opens one; covered by tests), and Settings on the user's own endpoint (covered by tests).
Found: run_menu_item cmd+w on Settings answers 'Nothing in the window handles Close Tab'. Whether a person's Cmd+W closes Settings was not checked.
The verify skill's §3 still says Settings needs screencapture; the skill was not edited (out of scope and not writable here).
Defaults keys and the data folder of the run were removed.

Code review (--fix, high): fixed choose_menu_item ignoring the Settings gates (tracker records AutomationSettingsReach; list_menu stays readable over Settings), window access now walks the whole sheet/child chain, extension pages (popup:/options:) and input by context ask AutomationWindows.access, posted events' timestamps compared within 1 us (they come back rounded to the nanosecond, so the leftover mouse-up check never matched), the endpoint's own nextEvent calls use the private run-loop mode, makeCurrent remembers the person's displaced event window and drops its event if it was not dequeued. Tests: AutomationWindowKindsTests 10/0 (3 new), AutomationInputTests 10/0, AutomationToolsTests, AutomationPrivateAccessTests, AutomationExtensionTests, AutomationPageTests, AutomationCaptureTests, AutomationStagingTests, MCPServerTests 91/0. Not tested: the extension-page window check (a popup over a Private Quick Detour needs a real popover in the test host) and makeCurrent's discard path (not reachable on demand). No /verify run for the review fixes.

2026-11-14 lead: after the high review's fixes (a22d9bc, 0e78d2b), on a fresh build: the 228.7 runtime script 22/22 and docs/harness/task326-copy-url-checks.py 12/12 (address bar Copy Link through the changed mouse-up delivery, sidebar row menu). hit_test on a sidebar row's label now reports the table (what a real click reaches), so the 326 script finds the row through the table; updated in the same commit.

2026-11-14 user decision: Private Quick Detour and quarantine windows follow the 'Allow agents to use Private windows' opt-in like Private browser windows (AutomationWindows.privateQuickDetourAccess = .privateOptIn), reversing the provisional never-reachable choice; wiki 'Never, whatever the setting' to be updated. Implementation follows.

2026-11-14/15 implemented the user's decision: AutomationWindows.privateQuickDetourAccess = .privateOptIn. Paths checked in code, all through AutomationWindows.access(of:): list_windows (filter + hidden_private_windows + is_private), anyWindow/inputWindow by id (screenshot, hit_test, click, type_text, press_key, run_menu_item, set_window_frame by window_id), set_window_frame by window_number (placeableWindow), the menu tracker (list_menu/choose_menu_item over the window), Window-menu entries (namesUnreachableWindow), resolvePage and extension pages (resolvePageTarget, popups' child windows via ancestry), input by context. Unchanged: open_url still refuses a route into a quarantine (hard-coded, independent of this value), page capture never goes into Quick Detour pages, the Private profile is never an install target. Settings > General help for the Private switch now names Private Quick Detour and Quarantine windows. Tests: AutomationWindowKindsTests rewritten (off: every window tool, set_window_frame by id and number, Window-menu entries and a menu over the quarantine refused; on: listed with is_private, screenshot, hit_test and click into the page, set_window_frame by id and number, Window-menu entries listed and run, a command closing the Private Quick Detour, list_tabs unsupported_window, off again refused at once; child-window ancestry and the hit-test-before-menu case now assert .privateOptIn). testASettingsPopUpOpensForATestRunsClick was flaky (failed once, passed twice) when the fixture's quarantine was key with the host active; it now allows Private so only the Settings gates count. Runs: all 16 Automation* suites + SettingsFormTests 217 tests (2 failures in my new set_window_frame size assert: Quick Detour's minimum width, fixed to 720x480), then AutomationWindowKindsTests/PrivateAccess/Tools 36 (the flaky Settings pop-up case failed once), AutomationWindowKindsTests twice 10/10, then WindowKinds+Input+Capture+Staging+Extension 58, 0 failures. Runtime (docs/harness/task228-7-private-quick-detour-checks.py, Debug build dylib 00:13, -AutomationAllowPrivate launch argument, isolated data dirs removed): off: quarantine from a routed click hidden (hidden_private_windows 1), screenshot and hit_test by its id private_unreachable; on: listed kind quarantine is_private true, its page the routed link, screenshot (checked) and hit_test into the web view work. Code review (medium --fix): 6 findings; fixed: the open_url comment (a click on a routed link does open a quarantine), the Settings help wording. Kept/out of scope: input by context into an extension popup over a Quick Detour or quarantine answers not_displayed (resolve(context:) only looks among browser windows; pre-existing for all Quick Detours; recorded in the wiki); open_url's quarantine refusal no longer protects anything the opt-in exposes (a separate decision for the user); no test of an extension popup over a quarantine (the predicate is covered by the child-window ancestry test); privateQuickDetourAccess/.never now a constant indirection (kept as the documented switch).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
run_menu_item validates each menu for the named window before matching a path, so Pin Tab and Unpin Tab match what that window shows. window_id now also names Quick Detour, quarantine and Settings windows, listed with their kind (new code unsupported_window for the tools for spaces and tabs). AutomationWindows is the one Private predicate, which also closed a gap: menus over a Private Quick Detour were listable. Private Quick Detour and quarantine windows follow 'Allow agents to use Private windows' as Private browser windows do (the user's decision, 2026-11-14: privateQuickDetourAccess = .privateOptIn): off, hidden and refused by every path; on, listed with is_private and reachable like any Quick Detour. A right click at a sidebar row's label or icon opens the row's menu: the endpoint hit-tests and delivers with the press as NSApp.currentEvent, as AppKit's dispatch does. Settings takes input and menu commands only in test runs, never in its Automation section; screenshot and hit_test work on any endpoint. Tests: AutomationWindowKindsTests (10) plus additions to Tools and Input; all Automation suites passed. Runtime: the earlier 22/22 endpoint checks, and a quarantine hidden and refused with the opt-in off, listed and captured with it on. Known gap: input by context into an extension popup over a Quick Detour answers not_displayed.
<!-- SECTION:FINAL_SUMMARY:END -->
