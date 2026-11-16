---
type: Component
title: Settings Extensions pane
description: "The Extensions pane of the Settings window: the installed-extension list and the selected extension's grouped-form detail column (header, source and staged update, pending permissions, Enabled / Profiles / Allow in Private, permission sections), Uninstall kept below the column, Add Extension…, and why the view controller holds the state a rebuild must keep."
resource: ../../Detour/Browser/Settings/ExtensionsSettingsViewController.swift
tags: [settings, extensions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:14Z }
sources:
  - id: extensions
    resource: ../../Detour/Browser/Settings/ExtensionsSettingsViewController.swift
    title: ExtensionsSettingsViewController.swift
  - id: profiles-extensions-form-tests
    resource: ../../DetourTests/SettingsProfilesExtensionsFormTests.swift
    title: SettingsProfilesExtensionsFormTests.swift
  - id: task-211
    resource: backlog:TASK-211
    title: "Settings: keep a pane's list and details fixed; scroll only their contents (and the Quick Detour pane)"
  - id: task-312
    resource: backlog:TASK-312
    title: "Extensions: on only in the profile they were installed from; a new profile starts with none"
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
---

# Role

A list of installed extensions (28 pt rows) and a detail column for the
selected one, in the [Settings window](./settings.md). It shows the
version, a "Settings…" button when the extension declares an options page,
Enabled, **Turn On in All Profiles** with a line saying which profiles have
it on, "Allow in Private", API permissions and site-access decisions with
their own switches, the install source with "Check for Updates" / "Reload"
/ "Install Now" and the permissions an update added, and Uninstall.

- TASK-312: an install is on only in its own profile and a new profile
  starts with none; Turn On in All Profiles is off when every normal
  profile has it on, and never touches Private.[^task-312]
- "Add Extension…" offers loading an unpacked extension or opening the
  Chrome Web Store; an unpacked load is turned on in the profile of the
  browser window behind Settings, and both alerts name it
  ([extensions on per profile](../decisions/extensions-on-per-profile.md)).

The behaviour behind these controls is covered by
[extension manager](../extensions/extension-manager.md),
[permissions](../extensions/permissions.md) and
[updates](../extensions/updates.md).

# The detail column

A [grouped form](./settings-grouped-form.md) (TASK-338) in a column scroll
view of its own (TASK-211; before, it was in the pane's scroll view, so
scrolling it moved the list too), as tall as its content:[^task-211]

- a top group, as System Settings' Wi-Fi pane opens: a header row
  (`SettingsFormRow(content:)`: the icon, the 13 pt bold name, the version
  and the description, "Settings…" on the right edge level with the icon,
  added after the text so VoiceOver reads the name first; the icon, here
  and in the list's rows, is decorative and out of the Accessibility tree,
  on the view and its cell, since the name follows it), the source row
  ("Loaded unpacked" or "Installed from…", the folder or the last check as
  a one-line detail ("Folder not recorded" when it is unknown), Reload or Check for Updates) and the staged update's
  row with Install Now ("Version X is downloaded", "It installs when the
  extension is idle.");
- the permissions an update added, as a row of their own group ("Version
  X needs new permissions", the permissions as its help, Accept and
  Enable, and the warning line "Turned off until you accept them."; before
  TASK-338, an orange banner);
- Enabled; "Profiles" (which profiles have it on, as help, and Turn On in
  All Profiles); Allow in Private (its note as help);
- Permissions, Optional Permissions, Requested Sites and Site Access, each
  a section of named switch rows (the switches' identifiers keep
  `id\tkey\ttype`). A section is left out when it has no rows, so
  Permissions is missing when only optional or saved rows exist; with no
  rows at all, a Permissions section holds only the footnote "No special
  permissions requested." Requested Sites and Site Access have footnotes
  saying where their decisions were made.

Permission names wrap instead of truncating (the per-permission tooltips
went with TASK-338), and the name, description and notes are not
selectable. These layout choices and wordings were Claude's while the
user was away; the user approved them as landed on 2026-11-14.[^task-338]

**Uninstall Extension** is not in the column: it sits under it, 20 pt
below the column's scroll view and level with the bottom of the list, so
it stays in view however far the details scroll (user request during
TASK-211; Spaces and Profiles have no comparable action at the end of
their details, since deleting goes through the list's − button, which is
always in view).[^task-211]

# Invariants

The detail column is **rebuilt** on every
`extensionsDidChangeNotification`, which an update itself posts. State
that must survive a rebuild therefore lives on the view controller, not in
the views: the selection is tracked by extension id (an update or reload
replaces the extension and appends the replacement, so an index would
jump to another extension), and so are the result of the last update
check and the set of checks still running. A rebuild for the same
extension keeps the column's scroll offset; another extension scrolls it
to the top (`shownExtensionID`).

# Tests

`SettingsProfilesExtensionsFormTests`: controls on the right edge and
names on the left, the pending permissions, identifiers, Learn more pages,
switch names, the first measurement equal to the laid-out height,
`SettingsFormRow(content:)`, and the header icon not read as an unnamed
image.[^profiles-extensions-form-tests] The options-page entry and the
update and permission behaviour are tested in
`ExtensionOptionsPageEntryTests` and the extension update and permission
suites.

# Related

- [Settings window](./settings.md) - the window and the pane list.
- [Settings Profiles pane](./settings-profiles-pane.md) - the per-profile extension rows.
- [Popup and options UI](../extensions/popup-and-options-ui.md) - the "Settings…" button.
- [Private profile extensions](../extensions/private-profile-extensions.md) - Allow in Private.

[^task-211]: TASK-211
[^task-312]: TASK-312
[^task-338]: TASK-338
[^profiles-extensions-form-tests]: SettingsProfilesExtensionsFormTests.swift
