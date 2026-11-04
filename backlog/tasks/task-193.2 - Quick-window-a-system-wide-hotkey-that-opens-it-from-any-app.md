---
id: TASK-193.2
title: 'Quick Detour: a system-wide hotkey that opens it from any app'
status: Done
assignee: []
created_date: '2026-10-24 10:11'
updated_date: '2026-10-26 05:27'
labels:
  - window
  - feature
dependencies:
  - TASK-193.1
parent_task_id: TASK-193
priority: medium
ordinal: 226000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Second part of TASK-193. A global hotkey (default Opt-Cmd-N, configurable, can be turned off in Settings) opens a new quick window from any app and brings Detour forward with only that window, not every Detour window. Proposed API: Carbon `RegisterEventHotKey` (needs no Accessibility permission, unlike an event tap); record the choice. A global shortcut takes the key from every other app, so the default must be easy to change or disable, and registration failure (another app owns it) is shown in Settings.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The hotkey opens a quick window from another app, activating Detour with that window in front and leaving other Detour windows where they were
- [x] #2 The shortcut can be changed and turned off in Settings; a registration conflict is reported
- [x] #3 The API choice and its permission needs are recorded in the wiki
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-25 implementation:
- Carbon RegisterEventHotKey with kEventHotKeyExclusive (no Accessibility permission). Default ⌥⌘N, on by default in the production data directory. Pressed from any app it shows the launcher panel (non-activating, takes typing at once); a second press while it is up closes it (Spotlight toggle). Choosing opens the window, then NSApp.activate(): only the Quick Detour window comes forward (CGWindowList: quick, other app, browser, browser); Escape/click away leaves the other app in front. Pitfall: while the non-activating panel is key NSApp.isActive is already true, so an isActive guard skipped activation.
- Conflicts (macOS 26.7, probed with two processes): plain+plain across processes both succeed and both fire; exclusive vs exclusive returns -9878; exclusive wins the key over plain. So a reported conflict means another app holds it exclusively; a plain holder isn't detected and loses the key. System shortcuts checked via CopySymbolicHotKeys.
- Settings > Links, Quick Detour section: checkbox + shortcut recorder (click to record, Escape cancels, Delete clears, needs ⌘/⌥/⌃, refuses Detour's menu shortcuts with the menu path, ⌃⇥/⇧⌃⇥ (recent-tab switcher) and macOS shortcuts; any click outside ends recording; hotkey suspended while recording); conflict warning keeps the choice; refused registrations retried on activation and when the pane appears. File > New Quick Detour Window mirrors the configured shortcut.
- Where it registers: Release yes; Debug only with DETOUR_GLOBAL_HOTKEY=1 (Settings says why otherwise), so a Debug build from Xcode can't take ⌥⌘N before the installed app; never in the test host.
- Known limits (wiki): a shifted menu character (Zoom In '+' vs ⇧⌘=) isn't detected as a conflict; the default is a fixed key code, so on Dvorak the label N and the physical key differ.
- TDD: red HotKeyShortcutTests 23/26 failing, HotKeyRegistrationTests 17/20, UserDefaultsScopeTests 2 new failing; green all. Follow-up: availability and click-elsewhere tests 6/7 red then green; menu-mirror test failed before its fix; monitor mutation fails the event-loop test.
- /code-review --fix: 10 findings, 6 fixed (Carbon handler never removed / dangling pointer -> deinit; InstallEventHandler error ignored; ⌃⇥ accepted; press callback via downcast -> protocol; duplicate defaults suite name; needless relayout). Then fixed by decision: Debug builds registering in the production data directory (opt-in now required); recorder staying active after a click elsewhere. Recorded as known limits: shifted menu characters, non-ANSI layouts. Bug found at runtime: the menu item didn't follow a changed shortcut when the hotkey wasn't started (observer now lives for the object's lifetime).
- Tests (final): HotKeyShortcut 27, HotKeyRegistration 20, QuickDetourHotKey 22, QuickDetourLauncher 12, UserDefaultsScope 8, ProductionDefaultsIsolation 2, ContentBlocker 11, ContentBlockerException 23, ContentBlockerWhitelist 22, ContentRuleListChunk 35, ContentRuleStoreThreading 9, SettingsPaneHeight 20, LinkRouteEditor 14, MenuKeyEquivalentMatcher 15 (240, all pass). Before the review: 250 across the Quick Detour, settings, menu and focus suites.
- Runtime (docs/harness/task193-2-harness.patch; keys and clicks posted at the HID event tap from a scratch CLI, only onto windows of PIDs the run owned; test shortcuts ⌃⌥⌘F12/F11; an unbundled scratch app as the other app): panel over another app takes typing; Return brings only the Quick Detour window forward; Escape and click away keep the other app in front; one press opens one panel with Detour in front; settings on/off/change/conflict; Debug without opt-in registers nothing; click-elsewhere ends recording (checkbox, empty space, toolbar item). Not verified: a person's key press, ⌥⌘N itself, multiple displays, full-screen apps, the recorder's live modifier display.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Quick Detour opens from any app: a system-wide hotkey (default ⌥⌘N, Carbon, exclusive, no permission needed) shows the launcher over the frontmost app, and choosing a page brings only the Quick Detour window forward. Settings > Links has an on/off switch and a shortcut recorder that refuses Detour's and macOS's shortcuts and reports conflicts; Debug builds don't register without DETOUR_GLOBAL_HOTKEY=1. 240 tests pass after review fixes; checked at runtime with HID-posted input.
<!-- SECTION:FINAL_SUMMARY:END -->
