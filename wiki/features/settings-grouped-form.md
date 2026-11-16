---
type: Component
title: Settings grouped form
description: "SettingsForm (TASK-338), the System Settings–style grouped form every Settings pane is built from: sections, groups and rows, their metrics as measured from a SwiftUI grouped Form on macOS 26, switches as mini NSSwitches, refits and widths, and the two things AppKit does not give (System Settings' pop-up, a mini switch's size outside a window)."
resource: ../../Detour/Browser/Settings/SettingsForm.swift
tags: [settings, appkit, layout]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:14Z }
sources:
  - id: form
    resource: ../../Detour/Browser/Settings/SettingsForm.swift
    title: SettingsForm.swift (the grouped form)
  - id: metrics
    resource: ../../Detour/Browser/Settings/SettingsMetrics.swift
    title: SettingsMetrics.swift
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
  - id: task-328
    resource: backlog:TASK-328
    title: "Settings: use switches instead of checkboxes on every Settings pane"
  - id: form-tests
    resource: ../../DetourTests/SettingsFormTests.swift
    title: SettingsFormTests.swift
  - id: panes-form-tests
    resource: ../../DetourTests/SettingsPanesFormTests.swift
    title: SettingsPanesFormTests.swift (General, Spaces, Links, lists as groups)
  - id: switch-row-tests
    resource: ../../DetourTests/SettingsSwitchRowTests.swift
    title: SettingsSwitchRowTests.swift
  - id: capture-tests
    resource: ../../DetourTests/SettingsCaptureHarnessTests.swift
    title: SettingsCaptureHarnessTests.swift
---

# Role

System Settings' look, at the user's request (2026-11-14, with a
screenshot of System Settings > Apple Intelligence & Siri as the
reference): a bold header over an inset rounded group, one row per setting
with its name on the left and its control on the right, hairlines between
the rows, help text under the name, a footnote row closing the group and
buttons for the whole group under it on the right.[^task-338]
`SettingsForm.swift` holds it.

Quick Detour and Content Blocking were the pilot (phase 1); phase 2 put
every pane's settings in it: General, Spaces', Profiles' and Extensions'
detail columns, Links' Default. The lists (the master lists, Search's site
searches, Links' routes, the Shortcuts list) stay lists, drawn as groups by
`SettingsListContainerView` (see
[Settings pane container](./settings-pane-container.md#settingslistcontainerview)).
The user approved the pilot with its choices (mini switches, bordered
pop-ups, Quick Detour's two sections, Content Blocking's table as rows, the
form 20 pt under the Learn more link, the taller panes) and then phase 2 as
landed, both on 2026-11-14.[^task-338]

# How it works

- `SettingsForm(sections:estimatedWidth:)`: the sections in a vertical
  stack 30 pt apart (a hidden section leaves no gap). A pane hands it to
  `formBody(_:)`, which pins it to the body's top and sides with `<=` plus
  `bottomHug` at the bottom, as every scrolling body must. Under the pane's
  description or Learn more link it starts 8 pt lower (20 pt under the
  link), so the link does not read as the first section's.
- `SettingsFormSection(title:headerAccessory:rows:footnote:buttons:)`: the
  header (13 pt semibold, on the rows' text edge) with an optional
  accessory 8 pt after it on its baseline (Profiles' "Learn more"), 10 pt,
  the group, and the buttons 10 pt under it, ending on the group's right
  edge (not the rows' inset: that is where System Settings puts them).
  `isButtonRowHidden` takes the buttons and their room away (General's
  copy buttons while automation is off); `group.setRows` replaces the rows
  (General's allowed clients, Profiles' extension rows). Both refit the
  pane.
- `SettingsFormGroupView`: the rows in a stack with no spacing (a hidden
  row leaves no gap and no separator). It draws in `draw(_:)`, so its
  colours follow the appearance: a 12 pt rounded fill of black or white at
  3.1% (247 on the light window's 255, 37 on the dark one's 30, as
  measured; `quaternarySystemFill` is 2.7% and comes out a level lighter),
  and between the visible rows a hairline inset 10 pt on each side, one
  device pixel of the separator colour at half strength on a 1x screen and
  full on a 2x one (System Settings draws half a point). Under Increase
  Contrast (the appearance's high-contrast variants, or the workspace's
  flag) it adds a 1 pt separator-coloured border, and it clips its rows to
  its shape.
- `SettingsGroupStyle` holds the fill and the contrast rule for the groups
  and the lists, with `increaseContrastOverride` for tests and capture
  harnesses: a process cannot turn Increase Contrast on for itself, and
  `NSAppearance(named: .accessibilityHighContrastAqua)` resolves to plain
  Aqua while the setting is off (measured: same name, same colours). No
  pane draws a material of its own, so Reduce Transparency has nothing to
  change.
- `SettingsFormRow(title:help:accessory:accessibilityName:)`, or
  `SettingsFormRow(footnote:)`: a text column (the 13 pt name, 11 pt
  secondary help, `addDetail` lines such as a status, a `setWarning` line
  with the orange triangle, `addLink` Learn more links; 3 pt apart, hidden
  ones collapse) ending 16 pt before the control, which ends 10 pt from the
  group's edge. Text keeps 10 pt from the row's top and bottom and the
  control at least 7 (a push button, or a value with one, 10), and the row
  hugs its content (a priority-740 zero height, above a body's stretch), so
  a one-line switch row is 36 pt, a pop-up row 38 and a button row 44, as
  in System Settings.
  - The accessory is `.toggle` (a mini switch, 36 × 16, centred on the
    name's first line), `.popUp`, `.button`, `.value(text, button:)`,
    `.shortcut` (all on the name's first baseline) or `.custom` (centred).
    Help text under a control taller than the name's line starts below the
    control (System Settings' Keyboard shortcut row).
  - `isEnabled` off disables the control and dims the name (Profiles'
    filter lists while blocking is off), and re-enables only what it
    disabled; `isHighlighted` tints the row with the accent colour (Links'
    Default).
  - `SettingsFormRow(content:)` is a row of one view across its insets
    (Extensions' header), whose subview order is VoiceOver's.
- **Accessibility, built in.** A row names its control by its title (or
  `accessibilityName`) and takes the title out of the tree; see
  [Settings accessibility](./settings-accessibility.md#the-forms-rule).
- **Refits.** `setHelp` and `setWarning` call the pane's
  `contentHeightDidChange()` when they change something
  (`NSView.enclosingSettingsPane`), since a wrapping label reports only
  width changes; Content Blocking's details and footnote and Quick Detour's
  warning rely on it.
- **Widths.** A row reads its control's `fittingSize` when it is built, so
  a `.custom` field gets its width constraint first (Spaces' and Profiles'
  260 pt fields); rows added to a built form go through the section's
  `setRows`, which wraps them at the group's width. A row's help is not
  selectable unless the pane turns it on (Profiles' user-agent preview).
  The rows wrap at `estimatedWidth` (the body's 700 pt by default; a detail
  column passes its own) less the control until they are laid out, so the
  pane's first natural-height measurement is the laid-out height.

## Switches

Every on/off setting in the window is an `NSSwitch` (TASK-328, at the
user's request: General and Quick Detour used checkboxes until
2026-11-14).[^task-328] A switch has no title, so its label is the row's
name: since TASK-338 every switch in the window is a form row's mini
switch on the group's right edge, centred on the name's first line. A
click on a name does nothing, on every pane: the names are plain text
fields (making them toggle the switch was the alternative TASK-328
declined). The five switches converted from checkboxes keep the
checkboxes' identifiers (`peekEnabled`, `automationEnabled`,
`automationAllowPrivate`, `quickDetourHotKeyEnabled`,
`quickDetourOptionCommandClick`). Only the sidebar's page settings popover
keeps a label then a switch.

Between TASK-328 and TASK-338 there were four row forms: Profiles'
right-aligned 124 pt label column, a label then a regular switch 8 pt
after it (General, Quick Detour, Extensions' Enabled and Allow in Private:
`SettingsSwitchRow.make`, measured to match exactly: a 56 × 26 switch, its
frame 6 pt after the label's, one centre line), and a small switch then
its 12 pt name in a bordered box (`SettingsGroupBoxView.switchRow`).
`SettingsSwitchRow.make`, `SettingsGroupBoxView` and the label-column
metrics were removed with TASK-338.[^task-338]

# Metrics

The numbers come from a SwiftUI `Form` with `.formStyle(.grouped)` (what
System Settings is built with) rendered on macOS 26 and measured pixel by
pixel, checked against the user's screenshot. An AppKit form rendered the
same way gave the same header, first-row text, fill, separator colour and
corners; further down it drifts by 1 or 2 pt, because its separators
overlay the rows instead of taking a pixel of their own. Button rows were
38 pt in the pilot (SwiftUI's render: 40); phase 2 made them 44, as System
Settings' Voice and history rows measure.[^task-338]

| Metric (`SettingsMetrics.form…`) | Value |
|---|---|
| Header | 13 pt semibold, 10 pt above the group |
| Between sections | 30 (group or its buttons to the next header) |
| Below the pane's description or link | 12 + 8 |
| Group | the body's width (700), corner radius 12 |
| Row insets | 10 at the sides (text, control and separators), 10 above and below the text, 7 at least for a control, 10 for a push button |
| Name, help | 13 pt, 11 pt secondary, 3 pt apart |
| Text column to control | 16 |
| Buttons under a group | 10 below it, 8 apart |

# Gotchas

Two things AppKit does not give:

- **Pop-ups** stay the standard bordered `NSPopUpButton`: System Settings'
  borderless value with a round chevron button is SwiftUI's own cell
  (`SwiftUIPopupButtonCell`), with no AppKit API (borderless, every bezel
  style and the macOS 26 border shapes were tried).[^task-338]
- **A mini `NSSwitch` reports its regular size (54 × 24) until it is in a
  window, and keeps the size it first reported**; the pane is built and
  measured before it is in one. The row reads the real size once from a
  switch in a window that is never shown (`SettingsFormRow.switchSize`)
  and fixes the switch to it; see
  [AppKit gotchas](../platform/appkit-gotchas.md#layout).[^task-338]

# Tests

`SettingsFormTests`: every control on one right edge and every name on
one left edge at 443 and 700 pt, long names and help wrapping before the
control with no overlap, controls on the name's first line, row, section
and form heights, hidden rows and sections taking no room, the first
measurement equal to the laid-out height for the form and the two pilot
panes (`testTheFirstMeasurementIsTheLaidOutHeight`), each control named by
its row and read once, the warning line, header accessories, turned-off
rows, 44 pt button rows, the Increase Contrast border, and the Content
Blocking rows, buttons and texts.[^form-tests] `SettingsPanesFormTests`:
the lists drawn as groups with their titles on the text edge, and that no
pane draws a material of its own (its per-pane checks are on
[Settings panes](./settings-panes.md#tests)).[^panes-form-tests]
`SettingsSwitchRowTests`: no pane has a checkbox, the converted settings
are switches named by their labels, General's and Quick Detour's switches
on the form's right edge, the labels plain text.[^switch-row-tests]
`SettingsCaptureHarnessTests` is a capture harness, skipped unless
`TEST_RUNNER_SETTINGS_CAPTURE_DIR` names a folder: it draws every pane in
light and dark, and with Increase Contrast forced through
`SettingsGroupStyle.increaseContrastOverride`.[^capture-tests]

Not verified on screen when TASK-338 landed: real mouse clicks on the mini
switch, the recorder and the pop-up (every runtime action was an
Accessibility press), and Increase Contrast and Reduce Transparency with
the real system settings on (Increase Contrast was captured only through
the override, so the system colours' high-contrast variants were not
seen).[^task-338]

# Related

- [Settings window](./settings.md) - the window and its panes.
- [Settings accessibility](./settings-accessibility.md) - how rows name their controls.
- [Settings pane container](./settings-pane-container.md) - the body a form sits in, and the list groups.
- [AppKit gotchas](../platform/appkit-gotchas.md) - the mini switch size and `NSStackView` hugging in general form.

[^task-328]: TASK-328
[^task-338]: TASK-338
[^form-tests]: SettingsFormTests.swift
[^panes-form-tests]: SettingsPanesFormTests.swift
[^switch-row-tests]: SettingsSwitchRowTests.swift
[^capture-tests]: SettingsCaptureHarnessTests.swift
