---
id: TASK-336
title: >-
  Settings: switches have one accessible name and VoiceOver reads each setting
  once
status: To Do
assignee: []
created_date: '2026-11-14T23:45:00Z'
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
- [ ] #1 Every switch in Settings (General, Quick Detour, Profiles, Extensions, Shortcuts, Content Blocking) has an accessible name equal to its visible label
- [ ] #2 VoiceOver (or the Accessibility hierarchy) presents each setting once, not as a label followed by a switch with the same text
- [ ] #3 Existing accessibility identifiers are unchanged; tests check names and the hierarchy; checked at runtime through Accessibility
<!-- AC:END -->
