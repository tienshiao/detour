---
id: TASK-336
title: >-
  Settings: switches have one accessible name and VoiceOver reads each setting
  once
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T23:45:00Z'
updated_date: '2026-11-15T01:00:00Z'
labels:
  - settings
  - accessibility
dependencies: []
references:
  - TASK-328
  - Detour/Browser/Settings/SettingsPaneViewController.swift
  - Detour/Browser/Settings/ProfilesSettingsViewController.swift
  - Detour/Browser/Settings/ExtensionsSettingsViewController.swift
priority: low
type: bug
ordinal: 410000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-328. The new switch rows (SettingsSwitchRow) expose both the label and the switch to Accessibility with the same text, so VoiceOver reads the setting twice. The older switches on Profiles and Extensions have no accessible name at all (empty description), so VoiceOver announces only "switch". The usual AppKit fix is to make the label the switch's title UI element (and keep the label out of the reading order), which the TASK-328 review left as a product call; this task takes the standard fix unless testing shows a reason not to.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Every switch in Settings (General, Quick Detour, Profiles, Extensions, Shortcuts, Content Blocking) has an accessible name equal to its visible label
- [x] #2 VoiceOver (or the Accessibility hierarchy) presents each setting once, not as a label followed by a switch with the same text
- [x] #3 Existing accessibility identifiers are unchanged; tests check names and the hierarchy; checked at runtime through Accessibility
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. One helper names a switch by its label: the switch takes the label's text as its accessibility label and the label leaves the Accessibility tree (setAccessibilityElement(false)), so the setting is one element (VoiceOver: '<label>, switch, on'). Chosen over AXTitleUIElement: the label stays a separate static text in the tree with a title UI element, and the ignored label could not be a title element.
2. Apply it to every switch row: SettingsSwitchRow (General, Quick Detour), SettingsGroupBoxView.switchRow (Profiles filter lists and extension switches, extension permissions), the Profiles grid's switch rows (Search suggestions, Per-tab isolation, Block content), Extensions' Enabled and Allow in Private; the sidebar settings popover's makeSwitchRow if it is the same one-line pattern.
3. Dump the Settings window's AX tree at runtime (before/after) to see what VoiceOver's object model gets; decide on the Shortcuts pane and the label+control pairs that already name the control by its label (Quick Detour idle pop-up, Shortcut recorder) from that dump.
4. Tests in SettingsSwitchRowTests: every NSSwitch in every pane (and the detail views built for a profile and an extension) has an accessibility label equal to its visible label; the pane's accessibility tree (accessibilityChildren walk) has no static text equal to a switch's name; identifiers unchanged.
5. Wiki settings.md (switch rows), log line; review, verify (AX dump), commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: SettingsSwitchRow.name(_:by:) names a switch by its label (accessibility label = the label's text) and takes the label out of the Accessibility tree. Every switch goes through it: SettingsSwitchRow.make (General, Quick Detour), SettingsGroupBoxView.switchRow (Profiles' filter lists and extension switches, an extension's permissions), the Profiles grid's switch rows (Search suggestions, Per-tab isolation, Block content), Extensions' Enabled and Allow in Private, and the sidebar page settings popover's makeSwitchRow (the same one-line pattern: it already named its switches but read each label again; fixed through the same helper).
Finding: a text field's Accessibility element is its cell. setAccessibilityElement(false) on the NSTextField left the text in the tree (seen in the running app and in a unit probe: the field already reports false, its cell true); the helper hides the cell. Title UI element rejected: it keeps the label in the tree as its own text.
Shortcuts pane: no switches; its recorders are named '<command> shortcut' inside a row titled by the command (a different name, not this issue), so unchanged. Content Blocking has no switch until TASK-337, whose row uses the helper.
Tests: SettingsSwitchRowTests +4 (every switch in every pane named by the label beside it; the Accessibility tree walked as a client gets it holds each switch and not its label, with a check that the walk sees text; the row helpers; the popover). Run: SettingsSwitchRowTests, DevModeSiteOverrideTests, QuickDetourTitleBarTests, SettingsGuideLinkTests, SettingsPaneColumnsTests, SettingsPaneHeightTests: 95 tests, 0 failures.
Runtime (Accessibility, docs/harness/task336/axsettings.swift, isolated DetourVerify-336 with API Explorer installed, every pane, Profiles for Private and Default, Extensions with the extension selected, and the sidebar popover): before, General 3 and Quick Detour 2 label+switch duplicates, Profiles 8 and Extensions 23 unnamed switches, popover 3 duplicates; after, 0 unnamed switches and 0 duplicates on switches anywhere; every AXIdentifier in every pane identical before and after. VoiceOver itself was not turned on: the Accessibility hierarchy check stands in for it.
Left as they were (not switches, out of scope; for the lead): label beside a control already named the same (Links 'Open other links in' pop-up, Quick Detour idle pop-up, Spaces Emoji and Color grids); unnamed pop-ups and fields beside grid labels (Profiles: Name, Search engine, Archive/Sleep tabs after, Identify as; Spaces: Name, Profile); the Quick Detour recorder's 'Shortcut' label beside a recorder named 'Quick Detour shortcut'; a recorder exposes its shortcut both as its value and as a child static text.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Every switch in Settings and in the sidebar's page settings popover is now one Accessibility element named by the label beside it: SettingsSwitchRow.name(_:by:) sets the switch's accessibility label to the label's text and hides the label's cell (a text field is read through its cell; hiding the field alone did nothing). VoiceOver's object model, read with an Accessibility client over every pane before and after, went from duplicated or unnamed switches (General 3, Quick Detour 2, Profiles 8 unnamed, an extension's 23 unnamed, popover 3) to none, with every identifier unchanged. Tests: 4 new in SettingsSwitchRowTests; 95 Settings-area tests pass. VoiceOver was not turned on; the hierarchy check stands in for it. Non-switch label pairs (pop-ups, fields, Spaces grids) left as they were and listed in the notes.
<!-- SECTION:FINAL_SUMMARY:END -->
