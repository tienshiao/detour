---
id: TASK-342
title: >-
  Settings: pop-ups, text fields and pickers have one accessible name, like the
  switches
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15T07:30:00Z'
updated_date: '2026-11-16T04:51:00Z'
labels:
  - settings
  - accessibility
dependencies: []
references:
  - TASK-336
  - TASK-338
  - Detour/Browser/Settings/SettingsForm.swift
  - wiki/features/settings.md
priority: low
type: bug
ordinal: 418000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-336 and left out of scope there (it covered switches only); TASK-338's grouped form then named the controls inside its rows. Remaining at the time: some pop-ups and fields read their visible label twice or have no accessible name: Links' "Open other links in" pop-up, Quick Detour's idle pop-up, the Spaces emoji and colour pickers, Profiles' Name / Search engine / Archive and Sleep tabs after / Identify as, Spaces' Name and Profile, and Quick Detour's "Shortcut" label beside a recorder named "Quick Detour shortcut"; a shortcut recorder also exposes its shortcut both as its value and as a child text. Re-check each after TASK-338 before changing anything: some may already be fixed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Every control in every Settings pane has an accessible name equal to its visible label (or a stated, more specific one), and no label is read separately from its control
- [x] #2 A shortcut recorder exposes its shortcut once
- [x] #3 Identifiers unchanged; the TASK-336 Accessibility-tree test covers every control type, not only switches; checked at runtime with the axsettings reader (docs/harness/task336)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Re-check after TASK-338 at runtime with the axsettings reader (docs/harness/task336), extended to every control type: UNNAMED controls (pop-ups, fields, search fields, buttons, radio groups, images), LABELS READ TOO (a text beside the control or in its container with the control's name, 'Name:' = 'Name'), READ TWICE (a control's value again as a child text); a 'choose' command to pick a pop-up item. Every pane, Profiles Private/Personal/Custom UA, Spaces, Links with routes and a new route, Search's Add/Edit sheets, Extensions with API Explorer.
2. Fix only what the re-check still shows: ShortcutRecorderView's inner label cell leaves the tree (the shortcut is its value once); Shortcuts rows: the title leaves the tree, the recorder keeps '<command> shortcut' (stated, more specific); the Shortcuts search field named 'Search Commands' (its placeholder); Links route rows: the line labels (URL, From app, Open in) and their icons leave the tree (the pop-ups and field already carry 'URL condition', 'Pattern', 'From app', 'Open in'); Search's site search sheet: Name:/Keyword:/Address: labels leave the tree, fields keep Name/Keyword/Address. Through SettingsSwitchRow.name; identifiers untouched.
3. Tests (SettingsSwitchRowTests, the TASK-336 tree test extended): every control of every type in every pane (plus a Personal profile, a space, route rows, the site search form, Shortcuts rows, the recorder) has a name, the tree has no text with a control's name in its row/container, a recorder's shortcut is read once; identifiers unchanged.
4. Runtime after: same reader, every state; wiki settings.md; review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Re-check after TASK-338 (runtime, before any change; Debug build 15:19, DETOUR_DATA_DIR=DetourVerify-342 seeded with 2 profiles, 2 spaces, 2 routes, API Explorer installed; docs/harness/task336/axsettings.swift extended to every control: CONTROLS with UNNAMED CONTROLS (images and radio groups included; window buttons and scroll bar parts left out), LABELS READ TOO (a text beside the control or in its container with the control's name, 'Name:' = 'Name'), READ TWICE (a control's value or name again as a child text), and 'choose' to pick a pop-up item). Already fixed by TASK-338's form rows (no change made): Links' 'Open other links in', Quick Detour's idle pop-up ('Close Quick Detour windows not used for'), Spaces' Name, Emoji grid, Profile, Color grid; Profiles' Name, Search engine, Archive tabs after, Sleep tabs after, Identify as, Custom string; Quick Detour's 'Shortcut' label (hidden; the recorder is 'Quick Detour shortcut', a stated more specific name). Still wrong: a recorder's shortcut as its value and again as its inner label's text (Quick Detour 1, every Shortcuts row); Shortcuts rows read the command's title and then '<command> shortcut'; the Shortcuts search field unnamed; Link Route rows read 'URL', 'From app', 'Open in' and their symbols ('link', 'notifications', one unnamed image) after the controls already named so; the site search sheet (Add and Edit) read 'Name:', 'Keyword:', 'Address:' before the fields.
Fixed: SettingsSwitchRow.hideFromAccessibility made internal (+ an NSImageView overload); the recorder hides its inner label's cell (value = shortcut once; while recording the value is what it shows, from the review); a Shortcuts row names its recorder through SettingsSwitchRow.name (title hidden, name '<command> shortcut' kept); the search field is named 'Search Commands' (its placeholder); a route row hides its line labels and symbols; the site search form names its fields by their labels without the colon and hides the labels. No identifier touched.
Chosen by Claude (not yet confirmed by the user): a Shortcuts row is read as its recorder ('Zoom In shortcut, ⌘+') with the title hidden, rather than the title followed by a recorder named 'Shortcut'; alternative: keep the title as the row's text and name the recorder 'Shortcut'. Value rows (General's Default web browser, Profiles' Saved permissions, Content Blocking's lists) stay name + value + button, all read: no control carries the name.
Tests: SettingsSwitchRowTests +2 (every control of every type in every pane, a user profile with a custom user agent, a route row, the site search sheet and Shortcuts rows of each kind: named, its name not read again as text, a recorder's shortcut read once; the Shortcuts search field and the Quick Detour recorder); checked that they fail with the source changes reverted (recorders' shortcuts, route labels, sheet labels, Shortcuts search). Runs: SettingsSwitchRowTests, ShortcutsSettingsPaneTests, SiteSearchPaletteTests, LinkRouteEditorTests, SettingsPanesFormTests, SettingsFormTests, SettingsProfilesExtensionsFormTests, SettingsPaneColumnsTests, SettingsPaneHeightTests, SettingsGuideLinkTests, QuickDetourHotKeyTests, HotKeyShortcutTests: 229 tests, 0 failures; after the review's fixes SettingsSwitchRowTests, ShortcutsSettingsPaneTests, SiteSearchPaletteTests 62/0 (and the reviewer's run of SettingsSwitchRowTests, ShortcutsSettingsPaneTests, SettingsFormTests, QuickDetourHotKeyTests 77/0).
Runtime after (Debug 15:31, DetourVerify-342b, same world): every pane, Profiles Private / Personal / Custom user agent, Spaces both rows, Links with routes and a new route, Search's Add and Edit sheets, Extensions with API Explorer: 0 unnamed controls, 0 labels read again, 0 read twice, 0 unnamed switches, 0 duplicates everywhere, except one expected hit: the Add sheet's title 'Add Site Search' beside the pane's button of that name. Every AXIdentifier per pane identical before and after (11 trees compared). Not verified at runtime: the review's recording value (tests only); VoiceOver itself (the Accessibility hierarchy stands in for it, as in TASK-336).
Review (code-review medium --fix): 6 findings, 5 fixed (recording value, the .quickDetour row kind added to the test, wrong command IDs in the test rows, one list of names for the site search labels and fields, axsettings choose cancels its menu on a miss); left: the test copies the Profiles pane's private profile-list filter to find the row (exposing it is outside this change).

User confirmed 2026-11-15: a Shortcuts row is read as its recorder ("Zoom In shortcut, ⌘+") with the title hidden.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Every control in Settings now has one accessible name, not only the switches. Re-checked at runtime first: TASK-338's form rows had already fixed the pop-ups, fields and grids TASK-336 listed. Fixed what the extended Accessibility reader still found: a shortcut recorder's shortcut read twice (its inner label is out of the tree; while recording its value is what it shows), Shortcuts rows read as their title then '<command> shortcut' (now the recorder alone), the Shortcuts search field's missing name, Link Route rows' line labels and symbols read after their controls, and the site search sheet's 'Name:' labels. Identifiers unchanged (compared at runtime). Tests: SettingsSwitchRowTests +2 covering every control type over every pane and the later states; 229 Settings-area tests pass. The reader (docs/harness/task336/axsettings.swift) now checks every control type and can pick pop-up items. Provisional: a Shortcuts row is read as its recorder with the title hidden.
<!-- SECTION:FINAL_SUMMARY:END -->
