---
type: Feature
title: Settings panes
description: "What the General, Spaces, Links, Quick Detour, Search, Shortcuts and Content Blocking panes of the Settings window show and edit, how each is laid out on the grouped form or as a list, and the layout choices the user decided (Profiles and Extensions have pages of their own)."
tags: [settings, spaces, links, shortcuts, content-blocking]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:59:43Z }
sources:
  - id: general
    resource: ../../Detour/Browser/Settings/GeneralSettingsViewController.swift
    title: GeneralSettingsViewController.swift
  - id: spaces
    resource: ../../Detour/Browser/Settings/SpacesSettingsViewController.swift
    title: SpacesSettingsViewController.swift
  - id: links
    resource: ../../Detour/Browser/Settings/LinksSettingsViewController.swift
    title: LinksSettingsViewController.swift (Link Routes, TASK-191.3)
  - id: quick-detour-pane
    resource: ../../Detour/Browser/Settings/QuickDetourSettingsViewController.swift
    title: QuickDetourSettingsViewController.swift
  - id: search
    resource: ../../Detour/Browser/Settings/SearchSettingsViewController.swift
    title: SearchSettingsViewController.swift
  - id: shortcuts-pane
    resource: ../../Detour/Browser/Settings/ShortcutsSettingsViewController.swift
    title: ShortcutsSettingsViewController.swift
  - id: content-blocker
    resource: ../../Detour/Browser/Settings/ContentBlockerSettingsViewController.swift
    title: ContentBlockerSettingsViewController.swift
  - id: task-211
    resource: backlog:TASK-211
    title: "Settings: keep a pane's list and details fixed; scroll only their contents (and the Quick Detour pane)"
  - id: task-193-2
    resource: backlog:TASK-193.2
    title: "Quick Detour: a system-wide hotkey that opens it from any app (the Links pane's Quick Detour section)"
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive (the Links pane's Quick Detour section)"
  - id: task-327
    resource: backlog:TASK-327
    title: "Keyboard shortcuts: assign and customize the shortcuts of browser commands in Settings"
  - id: task-328
    resource: backlog:TASK-328
    title: "Settings: use switches instead of checkboxes on every Settings pane"
  - id: task-337
    resource: backlog:TASK-337
    title: "Content blocking: a setting for the AdGuard URL Tracking list, so Detour does not fetch it when it is off"
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
  - id: panes-form-tests
    resource: ../../DetourTests/SettingsPanesFormTests.swift
    title: SettingsPanesFormTests.swift (General, Spaces, Links, lists as groups)
  - id: switch-row-tests
    resource: ../../DetourTests/SettingsSwitchRowTests.swift
    title: SettingsSwitchRowTests.swift
  - id: shortcuts-pane-tests
    resource: ../../DetourTests/ShortcutsSettingsPaneTests.swift
    title: ShortcutsSettingsPaneTests.swift
---

Seven of the [Settings window](./settings.md)'s nine panes, in toolbar
order; [Profiles](./settings-profiles-pane.md) and
[Extensions](./settings-extensions-pane.md) have pages of their own. Every
pane's settings are rows of the [grouped form](./settings-grouped-form.md)
and every list is drawn as one of its groups (TASK-338); the layout
choices Claude made while the user was away were approved by the user on
2026-11-14.[^task-338]

# General

Scrolls as one body; no description and no Learn more link.

- **Default Browser**: the row "Default web browser" with the app that
  opens web links now (asked with `https://example.com`: "Detour", or the
  other app's name) and "Set as Default Browser", turned off while it is
  Detour, which calls
  `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for `http`
  and `https`.
- **Peek** (TASK-307): the switch "Open links from pinned tabs and
  favorites in a Peek" (`PeekSettings`, app-wide, on by default) with the
  help "Off, links to other sites from pinned tabs and favorites open in
  new tabs. Shift-click still opens a Peek." and the Peek guide
  ([Peek](../tabs/peek.md#when-a-link-opens-in-a-peek)).
- **Automation** (TASK-228): the switches "Let AI agents and scripts
  control Detour (MCP)", "Allow agents to use Private windows" and
  (TASK-228.11) "Show where agents click and type" (the agent pointer, on
  by default, off by default in a test run), each with its help; the row
  "Disconnected agents [Allow Again]" while any are blocked (the button
  keeps the accessible name "Allow Disconnected Agents Again" of the
  full-width button it replaced); the endpoint's status as the group's
  footnote; and the copy buttons under the group, shown while it listens
  (Copy Token and Reset Token… in a test run only). The Private switch is
  not disabled while automation is off: it is a saved choice of its own,
  read at every check.
- **Allowed Clients**: a row per client (its name, when it was allowed and
  last used, Revoke), or "None yet", shown wherever clients are approved
  one by one.

Both Automation sections carry
`AutomationWindows.automationSettingsIdentifier`, so the endpoint's input
tools refuse every view in them (TASK-228.7); see
[automation endpoint](./automation-endpoint.md).

# Spaces

A list of the non-incognito spaces with name, emoji, colour and profile.
The selected space's settings are one form group in the detail column:
Name (the 260 pt field), Emoji (the curated grid and All Emoji…), Profile
and Color (the curated colours), each control on the group's right edge.
Edits go through `TabStore.updateSpace(id:name:emoji:colorHex:profileID:)`;
rows can be dragged to reorder (`TabStore.moveSpace(from:to:)`).

- Changing a space's **profile** asks first ("Changing the profile will
  change which cookies and login sessions this space uses") and restores
  the pop-up on Cancel.
- Add creates a space named "Space" on the first non-incognito profile.
- In a row, the space name gives way first and truncates; the profile name
  keeps its width up to 40% of the row and then truncates too, so both
  stay readable (the other way round, a long profile name squeezed the
  space name to nothing). The Profile pop-up is capped at 260 and
  truncates its title.
- The list scrolls to the selected space when the pane opens on it.
- Delete is disabled while only one space remains.

# Links

The link routes and the Default: "Routes" (a section header on the rows'
text edge) with New Route beside it, one list drawn as a form group of
three-line rows (URL, From app, Open in), then the Default as a form
section: the row "Open other links in [pop-up]" with its warning line,
tinted when the blocked space deletion points to it
(`SettingsFormRow.isHighlighted`), and the caption with the Quarantine
guide as the group's footnote. Not a master list with a detail column:
every route is edited in place, as in Arc's sheet.

Since TASK-211 the list fills the pane's height between "Routes" and the
Default, and its rows scroll inside it (a `SettingsColumnScrollView`, so a
list scrolled to its end stays at its end); the Default and its caption
stay at the bottom of the pane, 20 pt above the window's edge, at every
height.[^task-211] The list asks for the height of all its rows at
priority 250 (below the window's stay-put priority, so it never resizes the
window but does count in the natural height) and keeps at least the empty
list's 56 pt at priority 490. The Default and caption fit the 400 pt
minimum with room for about one and a half routes, so the minimum was not
raised. A highlighted route (the blocked-deletion alert) is scrolled into
view inside the list; a highlighted Default is always in view.

Until TASK-211 the list was as tall as its rows (its scroll view handed the
wheel to the pane's) and the pane scrolled as a whole, with the Quick
Detour section below the caption; that section is now the
[Quick Detour pane](#quick-detour). The behaviour, the validation (in
`LinkRouteStore`) and the choices made are on
[the Links pane](./link-routing-links-pane.md).

# Quick Detour

The controls for [Quick Detour](./quick-detour.md) (what each does and where it is stored: [Quick Detour settings](./quick-detour-settings.md)), moved out of the Links
pane by TASK-211 (user decision 2026-10-26: Links keeps the routes and the
Default only). The toolbar item sits after Links, labelled
`QuickDetour.displayName` with the SF Symbol `macwindow.on.rectangle` (a
window over another: the launcher opens over the app in front). No master
list, so it scrolls as one body, like General; no description (the toolbar
names it). A grouped form of two sections, below its Learn more link
(TASK-292.11):

- **Opening**: "Open Quick Detour from any app [switch]" with what the
  launcher does; "Shortcut [⌥⌘N]" (the `ShortcutRecorderView`, named
  "Quick Detour shortcut") with the help saying it is also File > New
  Quick Detour Window, also when the switch above is off, and the row's
  warning line when the shortcut is refused or not registered (a Debug
  build says it does not register without `DETOUR_GLOBAL_HOTKEY=1`)
  (TASK-193.2; see
  [the Settings control](./quick-detour-hotkey.md#the-settings-control));[^task-193-2]
  "Open links and sidebar tabs in Quick Detour with ⌥⌘-click [switch]" and
  its help; and a footnote pointing links from other apps to a route's
  Open in or the Default "on the Links pane".
- **Closing**: the idle auto-close pop-up ("Close Quick Detour windows not
  used for [Never, 1 hour, 6 hours, 12 hours, 1 day]", 6 hours by
  default) and its help (TASK-193.5; see
  [Quick Detour settings](./quick-detour-settings.md#closing)).[^task-193-5]

The recorder stays usable with the switch off: it is also File > New
Quick Detour Window's shortcut, which the help says. Until TASK-328 the
hotkey was one sentence, "[✓] Open Quick Detour from any app with [⌥⌘N]".
With a switch, which follows its label, the sentence would have run on
into two controls ("… with [⌥⌘N] [switch]"), so the switch row ends at
"any app" and the recorder has a labelled row under it.[^task-328] The
hotkey's help was one paragraph under the warning; in the form its first
sentence (the launcher) is the switch's help and its second (the menu
item) the Shortcut row's, and the section titles are new. Both choices
were Claude's while the user was away (the alternatives: the one-line
sentence with the switch at its end; one untitled group). The user
approved the pilot "as is" on 2026-11-14 and confirmed the hotkey's two
rows (the switch, then the Shortcut row) on 2026-11-15 (the user's
decision).[^task-328][^task-338]

The pane retries a refused shortcut when it appears
(`QuickDetourHotKey.retryIfFailed`) and ends a recording when it
disappears.

# Search

The site searches, one app-wide list (TASK-287): Name, Keyword and Address
columns in one list drawn as a form group under the "Site Search" header,
with a +, −, pencil bar; add and edit in an `NSAlert` sheet holding
`SiteSearchForm`, whose Save is off while the store would refuse the
entry. A list pane (400 pt minimum). Details on
[site search](./site-search.md).

# Shortcuts

Every menu command with its shortcut (TASK-327):[^task-327] a description,
a search field and Restore Defaults on one line, then one list drawn as a
form group that fills the pane (a list pane, 400 pt minimum; the list
scrolls on its own, and the pane opens at the 720 pt design maximum) with
the menus as floating group rows and a row per command (title, a note when
it is set elsewhere, the shortcut recorder, a reset button once it differs
from the built-in one), then a warning line under the list for a refused
shortcut.

The list stays a table inside the group rather than a form's rows: about
a hundred commands under floating menu headers, filtered as the search
field is typed in, are a list to scan and search, and a hundred form rows
would be as many views laid out at once. Claude chose it while the user
was away (the alternative: a form section per menu); the user decided on
2026-11-14 that it stays a searchable list in a group.[^task-338] No Learn
more link (see [Settings Learn more links](./settings-learn-more-links.md)).
What it lists, what it refuses and how the shortcuts apply are on
[keyboard shortcuts](./keyboard-shortcuts.md).

# Content Blocking

Scrolls as one body. **Filter Lists**: one row per list, its status on the
right ("Active" in green, "Not loaded", "Updating…": `filterListStatus`)
and under its name the rules in the list, the rules compiled and the last
fetch ("74,713 rules, 74,713 active, updated 12 sec. ago", "Never
updated": `filterListDetail`); a footnote with the total of active rules
and what is being fetched (`totalsText`); "Clear Cache & Redownload" and
"Update All Now" under the group. The rows refresh on
`.contentBlockerStatusDidChange` and `.contentBlockerRulesDidChange`. Which
lists are *enabled* is a per-profile setting on the
[Profiles pane](./settings-profiles-pane.md), not here.

Until TASK-338 the lists were a five-column table sized to its rows (name,
In List, Active, Status, Last Updated), with the total and the buttons
under it; the rows keep all five, in words. Claude chose rows while the
user was away (the alternative: the table inside the group as a custom
row); the user approved it with the pilot on 2026-11-14.[^task-338] Seen
at runtime with Clear Cache & Redownload in a fresh data directory: every
row read Updating…, the footnote "No active rules. Updating 4 lists…",
Update All Now disabled, then the totals came back as the lists
did.[^task-338]

**Tracking Parameters** (TASK-337; named "Copied Links" until 2026-11-15,
renamed by the user since its help also covers quarantine pages), a
section under the buttons, holds the one app-wide switch of the pane:
"Remove tracking parameters with the AdGuard URL Tracking filter"
(`trackingParameterListEnabled`, on by default), help saying Copy URL,
Copy Link, Share… and Quarantine leave out common tracking parameters,
that the list adds the ones particular sites use, and that it blocks
nothing, and a status line as a detail line of its row
(`trackingParameterListStatus`: "2,665 rules, updated 3 hr. ago", "Not
downloaded yet", or "Off: not downloaded or used", from
`trackingListStatus`). It is a section of its own rather than a fifth list,
since the lists are what blocks content. The switch calls
`ContentBlockerManager.setTrackingParameterListEnabled`; what off does is
on [Tracking parameters](./tracking-parameters.md#turning-it-off-task-337). The buttons
carry identifiers (`contentBlockerUpdateAll`, `contentBlockerClearCache`)
for Accessibility-driven checks.[^task-337]

# Tests

`SettingsPanesFormTests`: General (its controls on the form's edges, the
Automation sections' identifier, hidden button rows), Spaces' detail form
and its grids named once, Links' Default section.[^panes-form-tests]
`LinkRouteEditorTests`: the Links pane's rules (target menus, drag
destination, warnings, drafts). `SettingsSwitchRowTests`: the Shortcut row
right under the hotkey switch's, and the Peek, ⌥⌘-click and tracking-list
switches showing and writing their settings.[^switch-row-tests]
`ShortcutsSettingsPaneTests`: the Shortcuts list, search, recording,
refusals, resets and the Quick Detour row.[^shortcuts-pane-tests]
`SettingsFormTests` covers the Content Blocking rows, buttons and texts.
`SettingsPaneColumnsTests` covers the Quick Detour pane's natural height
and Links fitting the 400 pt minimum.

# Related

- [Settings window](./settings.md) - the window and the pane list.
- [Link routing](./link-routing.md) - what the Links pane edits.
- [Quick Detour](./quick-detour.md) - what the Quick Detour pane configures.
- [Keyboard shortcuts](./keyboard-shortcuts.md) - the Shortcuts pane's behaviour.
- [Site search](./site-search.md) - the Search pane's entries.
- [Content blocking](./content-blocking.md) - the filter lists.
- [Automation endpoint (MCP)](./automation-endpoint.md) - what General's Automation sections control.

[^task-193-2]: TASK-193.2
[^task-193-5]: TASK-193.5
[^task-211]: TASK-211
[^task-327]: TASK-327
[^task-328]: TASK-328
[^task-337]: TASK-337
[^task-338]: TASK-338
[^panes-form-tests]: SettingsPanesFormTests.swift
[^switch-row-tests]: SettingsSwitchRowTests.swift
[^shortcuts-pane-tests]: ShortcutsSettingsPaneTests.swift
