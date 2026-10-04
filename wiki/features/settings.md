---
type: Component
title: Settings window
description: "The fixed-size Settings window and its five panes (General, Spaces, Profiles, Extensions, Content Blocking): what each one edits, how changes reach TabStore, and the layout traps of a non-resizable pane."
resource: ../../Detour/Browser/Settings
tags: [settings, appkit, profiles, spaces, layout]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:42:36Z }
sources:
  - id: window
    resource: ../../Detour/Browser/Settings/SettingsWindowController.swift
    title: SettingsWindowController.swift
  - id: general
    resource: ../../Detour/Browser/Settings/GeneralSettingsViewController.swift
    title: GeneralSettingsViewController.swift
  - id: spaces
    resource: ../../Detour/Browser/Settings/SpacesSettingsViewController.swift
    title: SpacesSettingsViewController.swift
  - id: profiles
    resource: ../../Detour/Browser/Settings/ProfilesSettingsViewController.swift
    title: ProfilesSettingsViewController.swift
  - id: extensions
    resource: ../../Detour/Browser/Settings/ExtensionsSettingsViewController.swift
    title: ExtensionsSettingsViewController.swift
  - id: content-blocker
    resource: ../../Detour/Browser/Settings/ContentBlockerSettingsViewController.swift
    title: ContentBlockerSettingsViewController.swift
  - id: layout-notes
    resource: "Agent session notes, 2026-09-25 and 2026-09-26: Settings pane layout (not in the repository)"
    title: Settings pane layout lessons
---

# Role

`SettingsWindowController.shared` is one window with a preference-style
toolbar and five panes. It holds no settings of its own: each pane reads and
writes model objects directly (`TabStore`, `Profile`, `ExtensionManager`,
`ContentBlockerManager`, `ExternalAppPermissionStore`), and persistence
happens in those owners. The only app-wide setting, the default browser, is
not stored by Detour at all.

There is a second, unrelated "settings" surface: the sidebar's settings
**popover** (`SettingsPopoverViewController`), which holds the per-site
content-blocking switch and the extension list for the current page. See
[content blocking](./content-blocking.md) and
[popup and options UI](../extensions/popup-and-options-ui.md).

# How it works

## The window

- Style mask `.titled, .closable`: **not resizable**. Width is fixed at 740.
- The five view controllers are created once in `init` and kept in `panes`;
  switching swaps `window.contentViewController`.
- `switchToPane` resizes the window to the pane's `preferredContentSize.height`
  plus the window chrome, keeping the top edge fixed and animating.
- `showWindow` re-centres the window and activates the app.

| Pane | Height | Opened by |
|---|---|---|
| General | 120 | Detour > Settings… (Cmd+,), which opens whatever pane was last shown |
| Spaces | 400 | the sidebar's add-space and edit-space actions (`showSpacesPane(selectSpaceID:)`), the Spaces menu's Manage Spaces… (`openSpacesSettings`) |
| Profiles | 580 | toolbar only |
| Extensions | 640 | Extensions > Manage Extensions…, the settings popover (`showExtensionsPane()`) |
| Content Blocking | 300 | toolbar only |

## General

One control: "Set as Default Browser". It calls
`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for `http` and
`https`, and reports the current state by asking which application would open
`https://example.com`.

## Spaces

A list of the non-incognito spaces with name, emoji, colour and profile.
Edits go through `TabStore.updateSpace(id:name:emoji:colorHex:profileID:)`;
rows can be dragged to reorder (`TabStore.moveSpace(from:to:)`).

- Changing a space's **profile** asks first ("Changing the profile will change
  which cookies and login sessions this space uses") and restores the popup
  on Cancel.
- Add creates a space named "Space" on the first non-incognito profile.
- Delete is disabled while only one space remains.

## Profiles

A list of the profiles plus the built-in Private profile, and a grid of the
selected profile's settings. Each control writes a property and calls
`TabStore.shared.updateProfile(profile)`.

| Row | Setting | Notes |
|---|---|---|
| 0 | Name | not editable for Private |
| 1 | a note shown only for Private | |
| 2 | Search engine | Google, DuckDuckGo, Bing, Yahoo, Ecosia, Kagi |
| 3 | Search suggestions | gates the network row of the [suggestion pipeline](./suggestion-pipeline.md) |
| 4 | Archive tabs after | hidden for Private |
| 5 | Sleep tabs after | |
| 6 | a warning shown when per-tab isolation and sleeping are both on | |
| 7 | Per-tab isolation | each tab gets its own non-persistent data store |
| 8 | Content blocking | the master switch |
| 9 | the four filter-list switches | disabled while the master switch is off; each toggle calls `reapplyRuleLists()` |
| 10 | User agent | Detour, Safari or Custom |
| 11 | Custom string | shown only for Custom |
| 12 | a preview of the resulting user agent | |
| 13 | Extensions | one switch per installed extension; hidden when none are installed |
| 14 | External apps | saved-permission count and Clear; hidden for Private. See [external apps](./external-apps.md) |

A profile cannot be deleted while a space uses it ("Remove or reassign those
spaces first"), the Private profile cannot be deleted, and the last profile
cannot be deleted. What deleting does to the profile's data is on
[profile data removal](../architecture/profile-data-removal.md).

The per-profile extension switch shows the profile's own saved choice. While
the extension is turned off globally the switch is disabled and the name
dimmed, rather than hidden: it tells the user what turning the extension back
on will restore. For the Private profile it is the same opt-in as "Allow in
Private" on the Extensions pane; see
[private profile extensions](../extensions/private-profile-extensions.md).

## Extensions

A list of installed extensions and a detail view for the selected one:
version, a "Settings…" button when the extension declares an options page,
Enabled and "Allow in Private" switches, API permissions and site-access
decisions with their own switches, the install source with "Check for
Updates" / "Reload" / "Install Now" and the banner for permissions an update
added, and Uninstall. "Add Extension…" offers loading an unpacked extension
or opening the Chrome Web Store. The behaviour behind those controls is
covered by [extension manager](../extensions/extension-manager.md),
[permissions](../extensions/permissions.md) and
[updates](../extensions/updates.md).

The detail view is **rebuilt** on every `extensionsDidChangeNotification`,
which an update itself posts. State that must survive a rebuild therefore
lives on the view controller, not in the views: the selection is tracked by
extension id (an update or reload replaces the extension and appends the
replacement, so an index would jump to another extension), and so are the
result of the last update check and the set of checks still running.

## Content Blocking

A table of the four filter lists (name, parsed rules, compiled rules, status,
last fetch), a total of active rules, "Update All Now" and "Clear Cache &
Redownload". It refreshes on `.contentBlockerStatusDidChange` and
`.contentBlockerRulesDidChange`. Which lists are *enabled* is a per-profile
setting on the Profiles pane, not here.

# Gotchas

- **The Profiles grid is addressed by row number.** Rows are hidden and shown
  with `gridView.row(at: N).isHidden` in several methods (`updateRightPane`,
  `sleepThresholdChanged`, `perTabIsolationToggled`, `userAgentModeChanged`,
  `updateExtensionToggles`). Inserting a row means renumbering every one of
  them; the `// row N` comments beside the grid literal are the map.
- **A pane that overflows does not scroll.** The window is fixed-size and each
  pane states its own height. On the Extensions pane, when the detail column
  overflows, the permissions scroll view (low compression resistance) is
  squeezed to zero first. Check that a pane fits at rest before judging its
  padding.[^layout-notes]
- **`NSStackView.edgeInsets` on the cross axis are soft.** They act at hugging
  priority only; in a height-constrained column the bottom inset collapses
  silently while the top one survives. Use your own required constraints for
  insets that must hold, pin the content's bottom to the container, and give
  the content required vertical compression resistance.[^layout-notes]
- **`NSBox` does not grow to an Auto Layout content view's fitting height.**
  The pending-permissions banner uses a custom view (`TintedBannerView`) for
  that reason.[^layout-notes]
- **Measure, do not eyeball.** Log `convert(bounds, to: nil)` gaps and search
  the log for "Unable to simultaneously satisfy".[^layout-notes] See
  [AppKit gotchas](../platform/appkit-gotchas.md).
- **Capturing the window**: `cacheDisplay` works in light mode; after forcing
  a dark appearance the window background rendered transparent in
  captures.[^layout-notes] See
  [in-process UI automation](../playbooks/in-process-ui-automation.md).
- **A shell-launched instance never becomes the key app**, so anything that
  depends on `NSApp.keyWindow` cannot be driven that way.[^layout-notes]
- **`TabStore.updateProfile` always posts `UserAgentDidChange`.** Every
  profile edit, whatever the field, saves the profile row and posts that
  notification with the profile's id; each `BrowserTab` observes it. The
  content-blocker toggles additionally call `reapplyRuleLists()`, which
  reaches only the selected tab's panes (see
  [content blocking](./content-blocking.md)).

# Tests

The panes have no dedicated UI tests. Their behaviour is tested through the
model code they call: `TabStoreTests` and the profile and space suites,
`ExternalAppPermissionTests`, `ContentBlockerWhitelistTests`,
`ExtensionOptionsPageEntryTests`, and the extension update and permission
suites.

# Related

- [Profiles and spaces](../architecture/profiles-and-spaces.md) - the model the Spaces and Profiles panes edit.
- [Content blocking](./content-blocking.md) - lists, toggles and the per-site switch.
- [External apps](./external-apps.md) - the saved permissions the Profiles pane can clear.
- [Extension manager](../extensions/extension-manager.md), [permissions](../extensions/permissions.md), [updates](../extensions/updates.md) - what the Extensions pane drives.
- [Popup and options UI](../extensions/popup-and-options-ui.md) - the "Settings…" button and the sidebar's settings popover.
- [App shell](../architecture/app-shell.md) - the menu items that open the window.
- [AppKit gotchas](../platform/appkit-gotchas.md) - the stack-view and layout traps in general form.

[^layout-notes]: Settings pane layout lessons
