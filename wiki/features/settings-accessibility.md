---
type: Concept
title: Settings accessibility
description: "The rule that every control in the Settings window has one accessible name and no label is read separately from the control it names (TASK-336 for switches, built into the grouped form's rows by TASK-338, every control type since TASK-342), how it is applied (SettingsSwitchRow.name, hiding a text field's cell), what was fixed, and how it was measured with an Accessibility reader."
tags: [settings, accessibility, appkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:14Z }
sources:
  - id: container
    resource: ../../Detour/Browser/Settings/SettingsPaneViewController.swift
    title: SettingsPaneViewController.swift (SettingsSwitchRow)
  - id: form
    resource: ../../Detour/Browser/Settings/SettingsForm.swift
    title: SettingsForm.swift (the grouped form)
  - id: task-336
    resource: backlog:TASK-336
    title: "Settings: switches have one accessible name and VoiceOver reads each setting once"
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
  - id: task-342
    resource: backlog:TASK-342
    title: "Settings: pop-ups, text fields and pickers have one accessible name, like the switches"
  - id: task336-axsettings
    resource: ../../docs/harness/task336/axsettings.swift
    title: TASK-336 Accessibility reader for the Settings window (reading order, switch names, duplicates; since TASK-342 every control)
  - id: switch-row-tests
    resource: ../../DetourTests/SettingsSwitchRowTests.swift
    title: SettingsSwitchRowTests.swift
---

# Summary

In the [Settings window](./settings.md) each setting is one Accessibility
element: the control carries the name of the label beside it, and the
label leaves the Accessibility tree, so VoiceOver reads "<label>, switch,
on" once instead of the label and then a control of the same name (or an
unnamed "switch"). The rule started with switches (TASK-336), is built
into every row of the [grouped form](./settings-grouped-form.md)
(TASK-338), and covers every control type since TASK-342. Every
`AXIdentifier` was left unchanged throughout.

# Rules

- **`SettingsSwitchRow.name(_:by:as:)`** gives the control the label's
  text (or `as:` where that says more) as its accessibility label and takes
  the label out of the tree. It is used by every form row and by the
  sidebar's page settings popover (`makeSwitchRow`).[^task-336]
- **Hide the cell, not the field.** A text field's Accessibility element is
  its cell, so `hideFromAccessibility` sets the label's cell to not be an
  element: on the field alone the text stayed in the tree (seen in the
  running app and in a unit probe; see
  [AppKit gotchas](../platform/appkit-gotchas.md#accessibility)). A
  decorative image is hidden on the view and its cell.
- **Not a title UI element.** The label is not made the control's title UI
  element: that would keep the label in the tree as text of its own, read
  before the control, and an ignored label could not serve as one.
- **Values are read as they are.** A value row (General's "Default web
  browser", Profiles' "Saved permissions", Content Blocking's lists) is
  name, value and an optional button, all read: there is no control to
  carry the name. A button keeps its own title, a value is text of its own
  and a custom container is not an element, so those rows keep their
  title.

## The form's rule

A `SettingsFormRow` names a switch, pop-up, shortcut recorder or custom
control by its title, or by `accessibilityName` where that says more
("Quick Detour shortcut" beside "Shortcut"), and its title leaves the
tree. The row orders its Accessibility children so the control comes right
after its name (first when the name is hidden) and before the help: AppKit
lists them in subview order, which read the help before the switch (seen
with the TASK-336 reader in the running app).[^task-338] A
`SettingsFormRow(content:)` row is read in its subviews' order (the
Extensions header puts "Settings…" after the text so the name comes
first). Decorative images are out of the tree: the extension icon in the
Extensions header and list rows (it was read as an unnamed image before
the name), and Link Route rows' line symbols.

# What was fixed

**TASK-336 (switches).** Before, a TASK-328 row was a static text followed
by a switch of the same name (read twice), and the Profiles and Extensions
switches had no name at all (read as "switch"). Measured with an
Accessibility client over every pane (`docs/harness/task336/axsettings.swift`),
before and after: General's 3 and Quick Detour's 2 duplicates gone,
Profiles' 8 and an extension's 23 unnamed switches named, the popover's 3
duplicates gone.[^task336-axsettings]

**TASK-338 (form rows)** fixed most of what TASK-336 left, as the reader
showed at runtime: Links' "Open other links in", Quick Detour's idle
pop-up, Spaces' Name, Emoji, Profile and Color (the emoji and colour grids
were read as a label and again as the grid), Profiles' Name, Search
engine, Archive and Sleep tabs after, Identify as and Custom string, and
Quick Detour's "Shortcut" row naming its recorder "Quick Detour
shortcut".[^task-342]

**TASK-342 (every control).** Each pop-up, field, search field, button,
grid, image, link and recorder has a name, and no label is read separately
from the control it names.[^task-342] What was still read twice or
unnamed, and how it was fixed:

- A shortcut recorder's shortcut was its value and again its inner label's
  text: the inner label's cell is out of the tree, so VoiceOver reads
  "Zoom In shortcut, ⌘+" once. While it records, its value is what it
  shows ("Type Shortcut", or the modifiers held), since the label no longer
  says it.
- A Shortcuts row read its command's title and then the recorder named
  "<command> shortcut": the title is hidden and the recorder, with the more
  specific name, carries the row. The row's note ("Used by macOS", "Set in
  System Settings") stays text.
- The Shortcuts search field had no name (a placeholder is not one): named
  "Search Commands", its placeholder.
- A Link Route row read its line labels (URL, From app, Open in) and their
  symbols ("link", "notifications", an unnamed image) after its controls,
  which already carried the names ("URL condition", "Pattern", "From app",
  "Open in"): labels and symbols are out of the tree.
- The site search sheet read "Name:", "Keyword:", "Address:" before fields
  named Name, Keyword and Address: the labels are hidden.

Measured with the reader extended to every control (CONTROLS, UNNAMED
CONTROLS, LABELS READ TOO, READ TWICE, and `choose` to pick a pop-up item),
over every pane, Profiles' Private, a user profile and a custom user agent,
Spaces, Links with routes and a new route, Search's Add and Edit sheets and
Extensions with API Explorer: before, Links 4 labels read again and 2
unnamed images, Quick Detour 1 and Shortcuts 3 visible shortcuts read
twice, Shortcuts' search field unnamed, each sheet's 3 labels read again;
after, none. The one hit left, "Add Site Search" text beside the pane's
button of that name, is the sheet's own title.[^task-342]

# Where it lives

`SettingsSwitchRow` in
[SettingsPaneViewController.swift](../../Detour/Browser/Settings/SettingsPaneViewController.swift);
the row ordering and naming in
[SettingsForm.swift](../../Detour/Browser/Settings/SettingsForm.swift).

# Tests

`SettingsSwitchRowTests` (since TASK-336): every switch in every pane and
in the page popover named by the label beside it, and the Accessibility
tree, walked as a client gets it, holding each switch and not its label;
since TASK-342 every control of every type named, no text in the tree
reading a control's name again, and a recorder's shortcut read once, over
every pane, a user profile with a custom user agent, a route row, the site
search sheet and Shortcuts rows of each kind; the Shortcuts search field
and the Quick Detour recorder named.[^switch-row-tests] `SettingsFormTests`
checks that each control is named by its row and read once;
`SettingsProfilesExtensionsFormTests` checks the switch names and that the
extension header's icon is not read as an unnamed image.

# Related

- [Settings grouped form](./settings-grouped-form.md) - the rows that apply the rule.
- [AppKit gotchas](../platform/appkit-gotchas.md#accessibility) - a text field's element is its cell.
- [UI probes](../playbooks/ui-probes.md) - Accessibility readers for the running app.

[^task-336]: TASK-336
[^task-338]: TASK-338
[^task-342]: TASK-342
[^task336-axsettings]: TASK-336 Accessibility reader for the Settings window
[^switch-row-tests]: SettingsSwitchRowTests.swift
