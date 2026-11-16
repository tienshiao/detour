---
type: Component
title: Settings Profiles pane
description: "The Profiles pane of the Settings window: the profile list, the selected profile's grouped form (an untitled name section, then Search, Tabs, Content Blocking, Extensions, User Agent, External Apps), the pure ProfileSettingsLayout that decides which rows and sections show, deletion rules, the per-profile extension switch, and the notification every profile edit posts."
resource: ../../Detour/Browser/Settings/ProfilesSettingsViewController.swift
tags: [settings, profiles]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:14Z }
sources:
  - id: profiles
    resource: ../../Detour/Browser/Settings/ProfilesSettingsViewController.swift
    title: ProfilesSettingsViewController.swift
  - id: profile-layout
    resource: ../../Detour/Browser/Settings/ProfileSettingsLayout.swift
    title: ProfileSettingsLayout.swift (the Profiles pane's sections and rows)
  - id: profile-layout-tests
    resource: ../../DetourTests/ProfileSettingsLayoutTests.swift
    title: ProfileSettingsLayoutTests.swift
  - id: profiles-extensions-form-tests
    resource: ../../DetourTests/SettingsProfilesExtensionsFormTests.swift
    title: SettingsProfilesExtensionsFormTests.swift
  - id: task-189
    resource: backlog:TASK-189
    title: "Settings: fix the window's spacing and clipping"
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
---

# Role

A list of the profiles plus the built-in Private profile, and the selected
profile's settings as a [grouped form](./settings-grouped-form.md) in the
detail column: a section per `ProfileSettingsSection`, titled as below,
with "Learn more" as the header's accessory where the section has a
guide. Each control writes a property and calls
`TabStore.shared.updateProfile(profile)`. In the list a long profile name
truncates with an ellipsis and gives way before "N Spaces". A list pane of
the [Settings window](./settings.md): the list and the detail column
scroll on their own.

# Sections

| Section | Rows | Shown |
|---|---|---|
| (no title) | Name (a 260 pt field on the right); "This profile is used for Private Windows." and the Private Browsing guide as the group's footnote | the note only for Private; the name is not editable there |
| Search | Search engine (Google, DuckDuckGo, Bing, Yahoo, Ecosia, Kagi); Search suggestions | always. Suggestions gate the network row of the [suggestion pipeline](./suggestion-pipeline.md) |
| Tabs | Archive tabs after; Sleep tabs after; Per-tab isolation (each tab its own non-persistent data store) with the warning that sleeping tabs lose session data under isolation as its warning line | archive hidden for Private; the warning when isolation is on and tabs sleep |
| Content Blocking | Block content (the master switch); a row per filter list | always; the list rows are turned off (name dimmed) while blocking is off; each toggle calls `reapplyRuleLists()` |
| Extensions | a row per installed extension (`setRows` as they come and go) | when any extension is installed, Private included |
| User Agent | Identify as (Detour, Safari, Custom) with a preview of the resulting user agent as its help (selectable); Custom string (a 260 pt field on the right) | the string only for Custom |
| External Apps | Saved permissions: the count and Clear (`.value(count, button:)`) | hidden for Private (it never remembers one). See [external apps](./external-apps.md) |

Why this grouping (TASK-189 part 2, kept by TASK-338): the untitled first
section holds the name, which identifies the profile as an account name
heads a System Settings pane (a "Profile" title would repeat the pane);
per-tab isolation sits with the tab lifecycle rows because its warning is
about sleeping tabs, and the warning sits right under it; each other
section is one thing a person looks for by name. Row labels do not repeat
their section's title ("Block content", "Identify as", "Saved
permissions").[^task-189] The Private note as the first section's
footnote, the custom string as a field on the right and the preview as
Identify as's help were TASK-338's choices, approved by the user on
2026-11-14.[^task-338]

# ProfileSettingsLayout

The pure rule: which rows a `ProfileSettingsState` (Private, isolation,
sleeping, custom user agent, any extension installed) shows and which
sections have a visible row. The view controller keeps each row's form row
and each section by these enum values and sets their `isHidden` from the
rule (on selection, on the switches and pop-ups that change visibility,
and on extension changes), which also reports the height change; the
form's stacks leave no gap for a hidden row or section. The isolation
warning and the user-agent preview have no rows of their own: they drive
the isolation row's warning line and Identify as's help. Until TASK-338
the rule also gave the space above each row for the label-column grids
(`spacing(above:)`, removed with them); before TASK-189 part 2 the rows
were addressed by row number.

# Deleting a profile

A profile cannot be deleted while a space uses it ("Remove or reassign
those spaces first"), the Private profile cannot be deleted, and the last
profile cannot be deleted. What deleting does to the profile's data is on
[profile data removal](../architecture/profile-data-removal.md).

# The per-profile extension switch

It shows the profile's own saved choice. While the extension is turned off
globally the row is turned off (switch disabled, name dimmed, "Turned off
for all profiles in Extensions settings." as its help), rather than
hidden: it tells the user what turning the extension back on will restore.
For the Private profile it is the same opt-in as "Allow in Private" on the
[Extensions pane](./settings-extensions-pane.md); see
[private profile extensions](../extensions/private-profile-extensions.md).

# Gotchas

- **`TabStore.updateProfile` always posts `UserAgentDidChange`.** Every
  profile edit, whatever the field, saves the profile row and posts that
  notification with the profile's id; each `BrowserTab` observes it. The
  content-blocker toggles additionally call `reapplyRuleLists()`, which
  reaches only the selected tab's panes (see
  [content blocking](./content-blocking.md)).
- **Text that does not fit must truncate.** With the window's width
  locked, a label at compression 750 squeezes its neighbours instead of
  widening the window: a long extension name in Profiles took 5 pt from
  the "Search suggestions" label. Long names get `.byTruncatingTail` and
  low compression resistance.[^task-189]
- The pane reports its height from `viewWillAppear`, which can land
  mid-animation; see
  [Settings window height](./settings-window-height.md#applying-a-fit).

# Tests

`ProfileSettingsLayoutTests`: the sections and which rows show for a
normal and the Private profile.[^profile-layout-tests]
`SettingsProfilesExtensionsFormTests`: controls on the right edge, names
on the left, Profiles normal and Private, rows and sections hidden per
`ProfileSettingsState`, filter lists off while blocking is off, extension
rows turned off and rebuilt, identifiers, Learn more pages and switch
names, the first measurement equal to the laid-out height, and
`setRows`.[^profiles-extensions-form-tests]

# Related

- [Settings window](./settings.md) - the window and the pane list.
- [Profiles and spaces](../architecture/profiles-and-spaces.md) - the model the pane edits.
- [Settings Extensions pane](./settings-extensions-pane.md) - the global extension switches the per-profile rows follow.
- [External apps](./external-apps.md) - the saved permissions Clear removes.

[^task-189]: TASK-189
[^task-338]: TASK-338
[^profile-layout-tests]: ProfileSettingsLayoutTests.swift
[^profiles-extensions-form-tests]: SettingsProfilesExtensionsFormTests.swift
