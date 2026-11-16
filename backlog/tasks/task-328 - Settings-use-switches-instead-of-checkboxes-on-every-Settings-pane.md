---
id: TASK-328
title: 'Settings: use switches instead of checkboxes on every Settings pane'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T19:55:00Z'
updated_date: '2026-11-16T05:54:00Z'
labels:
  - settings
  - ui
dependencies: []
references:
  - Detour/Browser/Settings/GeneralSettingsViewController.swift
  - Detour/Browser/Settings/QuickDetourSettingsViewController.swift
  - Detour/Browser/Settings/ProfilesSettingsViewController.swift
  - Detour/Browser/Settings/ExtensionsSettingsViewController.swift
  - wiki/features/settings.md
priority: low
type: feature
ordinal: 402000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14 by the user: Settings panes mix two controls for on/off settings, and they should be consistent, with switches (NSSwitch) everywhere.

As of Nov 14 2026: General uses checkboxes (NSButton checkboxWithTitle) for "Open links from pinned tabs and favorites in a Peek", "Let AI agents and scripts control Detour (MCP)" and "Allow agents to use Private windows". Quick Detour uses checkboxes for the global hotkey ("Open … from any app with" followed by the shortcut recorder on the same line) and for the Option-Command-click option. Profiles (suggestions, per-tab isolation, content blocker lists) and Extensions (enabled, allowed in Private, per-profile) already use NSSwitch, as does the sidebar settings popover.

A checkbox carries its label as its title, while a switch has no title. So each converted row needs a label beside the switch, laid out like the rows that already use switches (ProfileSettingsLayout / SettingsMetrics). The hotkey row, a sentence that continues into the recorder, needs its own layout. Windows outside Settings (the Arc import window) are not in scope.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Every on/off setting in the Settings window (General, Quick Detour and any other pane) is an NSSwitch with a label, and no Settings pane uses a checkbox for an on/off setting
- [x] #2 Converted rows line up with the existing switch rows in Profiles and Extensions (label and switch positions, spacing), checked in light and dark mode
- [x] #3 Each converted setting still reads and writes the same stored value, and dependent controls still enable and disable as before (e.g. Private-windows access only while agent control is on; the shortcut recorder only while the hotkey is on)
- [x] #4 Clicking a row label toggles its switch or is deliberately inert, consistently across the panes, and the switches keep accessible names (the label text) and their existing accessibility identifiers
- [x] #5 Tests that address these controls (e.g. by accessibility identifier or as NSButton) are updated and pass; checked at runtime with /verify in both appearances
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add one shared switch-row helper beside SettingsGroupBoxView.switchRow: the Extensions pattern (13 pt label first, regular NSSwitch 8 pt after it, centred), the label a plain non-selectable text field (inert, as on Profiles and Extensions), the switch's accessibility label = the label text.
2. General: Peek, MCP and Private-windows checkboxes become switch rows; identifiers stay on the switches; help text and the Peek Learn more link stay 4 pt below.
3. Quick Detour: the hotkey becomes two rows, 'Open Quick Detour from any app [switch]' then 'Shortcut [recorder]' (alternative: the sentence '... with [recorder] [switch]'); the Opt-Cmd-click checkbox a switch row; warning and help anchored to the rows; the recorder's baseline comment updated.
4. Keep stored values, visibility dependencies, identifiers; comments in AutomationController.
5. Tests: a structural guard (no checkbox role in any pane, the five identifiers are NSSwitches with labels, the label sits 8 pt before its switch, centred), Peek and Opt-Cmd switch round trips; run Settings suites.
6. /verify: capture General, Quick Detour, Profiles, Extensions light and dark; AXPress each switch, read the defaults suite, check the visibility dependencies.
7. Wiki: settings.md (switch rows, General, Quick Detour, heights), quick-detour.md, automation-endpoint.md; log line.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (Nov 14 2026):
- Checkboxes found in the whole Settings folder (and what Settings hosts: Links' route rows, Search's SiteSearchForm sheet, the recorder): only the five the task names. The Arc import window's checkboxes are out of scope.
- New SettingsSwitchRow.make (SettingsPaneViewController.swift): 13 pt label, then a regular NSSwitch 8 pt after it, centred, the same form as Extensions' Enabled / Allow in Private rows (the Profiles label column cannot hold sentence labels; the switch-then-name form is for small switches in bordered groups). Extensions' own rows were left as they are.
- General: Peek, MCP and Private-windows switches; help text and the Peek Learn more link unchanged, 4 pt below.
- Quick Detour: 'Open Quick Detour from any app [switch]', then 'Shortcut [recorder]' on its own row (10 pt below), warning line and help under the recorder as before; Opt-Cmd-click switch row. PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): the two-row hotkey layout; alternative: keep the sentence '... from any app with [recorder] [switch]'. Flipping it is a small diff in QuickDetourSettingsViewController.makeBody.
- AC #4: label clicks are deliberately inert, as on Profiles and Extensions (their labels are plain NSTextFields too). Each converted switch gets setAccessibilityLabel(label text) and keeps its identifier.
- AC #3 note: the AC's examples describe dependencies the code does not have. The Private-windows checkbox was never disabled while automation is off (it is an independent saved setting, read per call), and the shortcut recorder was never disabled while the hotkey is off (the help says the shortcut is also File > New Quick Detour Window's 'also when this is off', so disabling it would be a regression). Kept as before; the dependencies that do exist (status line, copy buttons, client list hidden while automation is off; the warning line) still work.
- Found, not changed (out of scope): the existing Profiles and Extensions switches have no accessible name (AX description empty).

Verification (Nov 14 2026):
- Tests: SettingsSwitchRowTests (new, 8), SettingsPaneColumnsTests 22, SettingsGuideLinkTests 10, SettingsPaneHeightTests 20, ProfileSettingsLayoutTests 15, QuickDetourHotKeyTests 22, QuickDetourEntryPointsTests 21, AutomationHelperTests 8: 126 tests, 0 failures (after the review fix). No existing test addressed these controls as checkboxes (the docs/harness patches that did are historical and were left alone).
- /verify (Debug build, DETOUR_DATA_DIR=DetourVerify-328, DETOUR_MCP=1, API Explorer installed): General, Quick Detour, Profiles and Extensions captured with screencapture -l in light and dark and looked at. Accessibility frames: the converted rows match Extensions' Enabled and Profiles' Search suggestions exactly (56 x 26 switch, frame gap 6 pt = 8 pt between alignment rects, same centre line). AXPress on each of the five switches flipped its AX value and its key in the run's defaults suite (PeekEnabled, AutomationAllowPrivate, QuickDetourOptionCommandClickEnabled, QuickDetourHotKeyEnabled, AutomationEndpointEnabled) and back. Automation off: endpoint file removed, status 'Off.', copy buttons hidden, window shrank; on again: endpoint back, buttons shown. Real (HID) clicks: on the Peek, hotkey and Opt-Cmd labels changed nothing; on the Peek switch toggled it twice; on the hotkey switch while the recorder was recording ended the recording and toggled the switch. AX names: each converted switch's description is its label text, identifiers unchanged.
- Code review (medium, --fix): SettingsSwitchRow.make now returns only the row (applied, tests re-run; runtime not re-run for this return-type change). Skipped: moving Extensions' rows onto the helper and naming their switches (out of scope), the label and switch both being in the AX tree (the label text is read twice by VoiceOver; System Settings rows do the same; a titleUIElement link is the alternative), an observer the test's throwaway General pane leaves (General has no teardown, predates this change), the checkbox guard seeing only each pane's first state (selection-built details were checked at runtime).
- Not verified: VoiceOver itself; the global hotkey registering (Debug build without DETOUR_GLOBAL_HOTKEY=1).

2026-11-15, the user's decision: the Quick Detour hotkey's two rows (a switch row ending at 'any app', and a labelled Shortcut row with the recorder) are confirmed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Every on/off setting in Settings is now an NSSwitch. General (Peek, MCP, Private windows) and Quick Detour (hotkey, Opt-Cmd-click) use SettingsSwitchRow: the label, then the switch 8 pt after it, centred, the same form and measurements as the Extensions rows. Labels stay inert as on Profiles and Extensions; switches take the label text as their accessible name and keep their identifiers. The Quick Detour hotkey is a switch row plus a 'Shortcut [recorder]' row (provisional; alternative: one sentence ending in the recorder and the switch). Stored values and existing dependencies unchanged (the AC's two example dependencies never existed and were not added). New SettingsSwitchRowTests; wiki settings, quick-detour and automation-endpoint pages updated. Follow-up candidates: accessible names for the Profiles and Extensions switches.
<!-- SECTION:FINAL_SUMMARY:END -->
